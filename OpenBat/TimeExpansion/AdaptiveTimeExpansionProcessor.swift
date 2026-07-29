//
//  AdaptiveTimeExpansionProcessor.swift
//  OpenBat
//
//  LIVE time expansion, event-triggered with an adaptive (hangover-delimited)
//  event boundary. States: idle → capturing → draining → idle.
//
//  Idle, nothing is emitted. When the trigger fires, emission starts from a
//  short pre-roll (so the onset isn't clipped by detector latency) and every
//  captured sample is emitted, in order, into the 48 kHz output ring. Because
//  the input runs at 384 kHz and the ring drains at 48 kHz, that IS 8×
//  expansion with no resampling at all — the same arithmetic as the
//  playback-only TimeExpansionProcessor, just sourced live.
//
//  Further pulses arriving before `hangoverMs` expires extend the same event,
//  so a burst or feeding buzz merges into one contiguous stretch of audio
//  rather than a string of fragments. The event closes `postRollMs` after the
//  last trigger, or at `maxBufferMs`, whichever comes first.
//
//  === Two invariants that are load-bearing. Do not "optimise" either away. ===
//
//  1. NOTHING IS SELECTED OUT OR DISCARDED WITHIN AN EVENT. Every sample from
//     the pre-roll to the close point is emitted, in order. The hangover
//     decides *when the event ends*; it never punches gaps into audio already
//     inside one. This is why emission is run through a delay line (see
//     `emitDelaySamples`) rather than emitted eagerly and retracted: an eager
//     emitter that later wants to trim its tail can only do so by dropping
//     samples, which is both an audible click and the thing we must not do.
//     The one exception is `ringOverflowCount`: the output ring is sized well
//     above the largest possible event (see its own doc comment) specifically
//     so that exception requires an actual output-thread stall, not routine
//     operation — and it's counted, not silent, if it ever happens.
//
//  2. CAPTURE STOPS WHILE THE RING DRAINS. An event of length L takes 8L to
//     play, and during that drain this processor is deaf — new calls are not
//     captured. That is deliberate. It means the mode cannot stay current with
//     a continuous stream of activity; under sustained calling it falls behind
//     and misses material, exactly like a 1980s Pettersson D240x. Making it
//     keep up (e.g. capturing into a second buffer while draining the first)
//     would turn this into continuous real-time monitoring with selective
//     retention — which is the subject matter of an active third-party patent,
//     US 8,599,647 (see CLAUDE.md's patent notes). The deafness is the feature.
//
//  Threading: same contract as HeterodyneProcessor — `process(_:)` on the
//  realtime capture thread, `render(_:frames:)` on the realtime output thread,
//  lock-free SPSC ring between them, NSLock only for main-thread control
//  changes (read once per buffer, never per sample).
//

import AVFoundation
import Synchronization

nonisolated final class AdaptiveTimeExpansionProcessor: @unchecked Sendable {

    /// What the state machine is doing, for the live UI pill.
    enum State: Int, Sendable {
        case idle = 0
        /// An event is open — capturing and feeding the ring.
        case capturing = 1
        /// Event closed, ring still playing out. Capture is deaf here (see
        /// invariant 2 in the file header).
        case draining = 2
    }

    let outputSampleRate: Double = 48_000

    // MARK: Control (main thread ↔ audio threads)

    private let ctrlLock = NSLock()
    private var _gain: Float = 4
    private var _hangoverMs: Double = defaultHangoverMs
    private var _maxBufferMs: Double = defaultMaxBufferMs
    private var _thresholdDB: Double = defaultThresholdDB
    private var _releaseDB: Double = defaultReleaseDB
    private var _bandLowFraction: Double = 0
    private var _bandHighFraction: Double = 1
    private var _slowdownFactor: Double = 384_000 / 48_000

    static let defaultHangoverMs: Double = 60
    static let defaultMaxBufferMs: Double = 200
    static let defaultThresholdDB: Double = 12
    static let defaultReleaseDB: Double = 6

    /// Pre-roll ahead of the trigger, so the call onset survives detector
    /// latency. Kept tight: 5 ms of roll would nearly double a 5 ms pulse
    /// before expansion, and expanded length is what has to fit the gap.
    private static let preRollMs: Double = 2.0
    /// Tail kept after the level last exceeded the *release* threshold. The
    /// hangover is only a close decision — the audio is trimmed back to this,
    /// so an event doesn't ship `hangoverMs` of silence (at 8× that would be
    /// ~half a second of dead air per event, extending the deaf window for
    /// nothing).
    ///
    /// This is margin, not the mechanism: the end of a call is found by the
    /// level decaying past `releaseDB`, not by a fixed time. It only has to
    /// cover the detection block plus the ramp, so it stays short.
    private static let postRollMs: Double = 5.0
    /// Fade applied at the start and end of each event, so emission never
    /// begins or ends on a step discontinuity. At 8× this is heard as a ~24 ms
    /// fade — long enough not to read as an abrupt stop, still well under the
    /// ~40 ms an expanded 5 ms call occupies, so it shapes the tail rather than
    /// swallowing the call.
    ///
    /// MUST stay ≤ `postRollMs`, or the fade-out eats into call signal instead
    /// of the tail margin — lengthening this means lengthening the post-roll
    /// too, which lengthens every event and therefore the deaf drain after it.
    private static let rampMs: Double = 3.0
    /// Detection block. 128 samples ≈ 0.33 ms at 384 kHz — fine enough to place
    /// an onset well inside the pre-roll.
    private static let detectBlock = 128
    /// Minimum gap between triggers for `missedCount` to treat them as separate
    /// pulses. Without it the counter would tick once per 0.33 ms detection
    /// block — a single 5 ms call arriving while deaf would read as ~15 misses.
    /// 5 ms is below the tightest real inter-pulse interval (a feeding buzz),
    /// so genuine buzz pulses still count individually.
    private static let missedPulseGapMs: Double = 5.0
    /// Detection high-pass. Rejects handling noise, wind and speech so they
    /// can't open an event; bat energy is far above this.
    private static let detectHighpassHz: Double = 12_000

    /// Output makeup gain. Bat calls are weak and pass-through preserves the
    /// input's own level, so some makeup is normally wanted.
    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    /// How long after the last trigger the event stays open for a further
    /// pulse to extend it. The one real tuning knob.
    ///
    /// Too short and natural bursts split into choppy fragments; too long and
    /// it degenerates toward "wait for a long silence", which at 8× means very
    /// long drains and a correspondingly long deaf window. Note that search-
    /// phase inter-pulse intervals (~50–150 ms) are mostly *longer* than this,
    /// by design: isolated search pulses should each get their own tight event,
    /// which drains inside the following gap. The hangover exists to merge
    /// approach phase and feeding buzzes, where intervals collapse to 5–20 ms.
    var hangoverMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _hangoverMs }
        set { ctrlLock.lock(); _hangoverMs = min(max(newValue, 5), 250); ctrlLock.unlock() }
    }

    /// Hard cap on event length regardless of hangover state — prevents
    /// unbounded growth during continuous activity.
    ///
    /// Deliberately small. At 8× a 200 ms cap already costs a 1.6 s drain, and
    /// the whole of that is deaf time. A multi-second cap would mean missing
    /// the rest of the pass (and everything after it) to hear one buzz in full.
    ///
    /// A change here only takes effect for the NEXT event — an open event
    /// keeps the cap it started with (`eventMaxBufferSamples`), so dragging
    /// this down mid-capture can't truncate the event already in flight
    /// without its ramp-out fade.
    var maxBufferMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _maxBufferMs }
        set { ctrlLock.lock(); _maxBufferMs = min(max(newValue, 20), 500); ctrlLock.unlock() }
    }

    /// How far above the tracked noise floor a block must sit to OPEN an event.
    var thresholdDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _thresholdDB }
        set { ctrlLock.lock(); _thresholdDB = min(max(newValue, 3), 30); ctrlLock.unlock() }
    }

    /// How far above the noise floor the level must stay to hold an open event
    /// open — the hysteresis half of the gate, always ≤ `thresholdDB`.
    ///
    /// This exists because a bat call does not end where it stops being loud
    /// enough to notice. The tail of a downsweep decays well below the attack
    /// threshold while still being real, audible signal, so closing on the
    /// attack threshold clips the end of every call — which is exactly what a
    /// single-threshold gate did here before this was added. Opening needs
    /// confidence (high threshold, few false events); staying open needs only
    /// evidence the call is still going (low threshold). Lower it if call ends
    /// still sound truncated; raise it if events run on into background noise.
    var releaseDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _releaseDB }
        set { ctrlLock.lock(); _releaseDB = min(max(newValue, 0), 30); ctrlLock.unlock() }
    }

    /// The actual slowdown factor for the rate this processor was last reset
    /// for — 8× at 384 kHz, computed rather than assumed so a different
    /// negotiated rate can't silently drift out of sync with a hardcoded label.
    var slowdownFactor: Double {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return _slowdownFactor
    }

    /// Restrict listening to a frequency band (fractions of Nyquist), matching
    /// the same viewport-derived band the other listening modes use.
    func setBand(low: Double, high: Double) {
        ctrlLock.lock()
        _bandLowFraction = low
        _bandHighFraction = high
        ctrlLock.unlock()
    }

    private func controls() -> (gain: Float, hangover: Double, maxBuffer: Double, threshold: Double, release: Double, low: Double, high: Double) {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return (_gain, _hangoverMs, _maxBufferMs, _thresholdDB, _releaseDB, _bandLowFraction, _bandHighFraction)
    }

    // MARK: Observable-ish state (any thread → main)

    private let stateA = Atomic<Int>(State.idle.rawValue)
    /// Number of events emitted since the last reset, for diagnostics.
    private let eventCountA = Atomic<Int>(0)
    /// Pulses that triggered while the ring was still draining and so were
    /// never captured — the running cost of invariant 2, surfaced so the user
    /// can see it rather than wondering why a busy pass sounds sparse.
    private let missedCountA = Atomic<Int>(0)
    /// Times `emitAvailable` hit a full ring mid-event and had to truncate it
    /// (see the `pushToRing` guard there). `ringCapacity` is sized well above
    /// the largest possible event at the hard-clamped `maxBufferMs`/`hangoverMs`
    /// maxima, so this should only ever tick if the output thread has
    /// genuinely stalled for seconds — same idea as
    /// `TimeExpansionProcessor.overflowCount`, kept separate from
    /// `missedCount` because it's a different failure (an event that DID open
    /// losing its own tail, vs. a pulse that never got to open one at all).
    private let ringOverflowCountA = Atomic<Int>(0)

    /// Current state. `draining` is derived: the event has closed but the ring
    /// still holds audio.
    var state: State {
        let raw = stateA.load(ordering: .relaxed)
        if raw == State.capturing.rawValue { return .capturing }
        return ringAvailable > 0 ? .draining : .idle
    }

    var eventCount: Int { eventCountA.load(ordering: .relaxed) }
    var missedCount: Int { missedCountA.load(ordering: .relaxed) }
    var ringOverflowCount: Int { ringOverflowCountA.load(ordering: .relaxed) }

    // MARK: DSP + state machine (capture thread only)

    private var inputSampleRate: Double = 384_000

    private var bandHPa = Biquad(), bandHPb = Biquad()
    private var bandLPa = Biquad(), bandLPb = Biquad()
    private var applyHP = false
    private var applyLP = false
    private var appliedLowFraction = -1.0
    private var appliedHighFraction = -1.0
    /// Notch for a measured hardware artifact: a tone at inputSampleRate/4
    /// (96 kHz), ~+11 dB over the local noise floor in every recording checked,
    /// so it's the ADC or USB path rather than the acoustic scene. Any mode
    /// that maps frequency down puts it in the audible band; expansion at 8×
    /// lands it at 12 kHz.
    private var artifactNotch = Biquad()
    /// Detection-only high-pass — a separate filter chain from the listening
    /// band, so widening the band to include audible frequencies doesn't start
    /// triggering events on handling noise.
    private var detHPa = Biquad(), detHPb = Biquad()

    /// Delay line holding band-limited, gained input at the capture rate.
    /// Emission reads from here `emitDelaySamples` behind the write head, which
    /// is what lets an event's tail be trimmed to `postRollMs` without ever
    /// retracting or dropping a sample that was already emitted (invariant 1).
    private let delay: UnsafeMutableBufferPointer<Float>
    private static let delayCapacity = 262_144   // 683 ms at 384 kHz
    private static let delayMask = delayCapacity - 1

    /// Absolute count of samples written to `delay`. Absolute (not modular)
    /// because every position comparison below is an ordering question; at
    /// 384 kHz an Int takes ~760 000 years to overflow.
    private var totalWritten = 0

    private var isCapturing = false
    /// Absolute position where the open event began emitting (its pre-roll).
    private var eventStart = 0
    /// Next absolute position to emit.
    private var emitPos = 0
    /// Absolute position of the most recent triggering block's end.
    private var lastTrigger = 0
    /// `maxBufferSamples` as it was at the moment THIS event opened, snapshot
    /// rather than read live from `emitAvailable`. `maxBufferMs` is a live
    /// settings knob (`process()` recomputes `maxBufferSamples` every buffer),
    /// so reading it live in `closeAt` would let a mid-event slider drag pull
    /// the close point backward past `emitPos` — an instant truncation with no
    /// ramp-out, since the fade-out only ever applies to samples that pass
    /// through the emission loop. Snapshotting means a live change only takes
    /// effect for the *next* event.
    private var eventMaxBufferSamples = 0

    // Derived from the control values, recomputed when they change.
    private var preRollSamples = 0
    private var postRollSamples = 0
    private var rampSamples = 1
    private var hangoverSamples = 0
    private var maxBufferSamples = 0
    private var missedGapSamples = 0
    /// How far behind the write head emission runs: `hangover - postRoll`. At
    /// the moment an event's hangover expires, emission has therefore reached
    /// exactly `lastTrigger + postRoll` and can simply stop.
    private var emitDelaySamples = 0
    private var thresholdFactor: Float = 4
    private var releaseFactor: Float = 2

    // Detection accumulator, carried across buffers so a tap buffer that isn't
    // a multiple of `detectBlock` doesn't reset the analysis.
    private var blockSumSquares: Float = 0
    private var blockFilled = 0
    private var noiseFloor: Float = 1e-4

    // MARK: Output ring

    // Lock-free SPSC ring, same contract as the sibling processors: the
    // producer only advances `writeIndexA`, the consumer only advances
    // `readIndexA`.
    // Sized well above the largest possible single event (500 ms maxBufferMs
    // → ~192 000 samples plus pre-roll, at the hard-clamped maximum) so
    // hitting `ringOverflowCount` requires the output thread to have
    // genuinely stalled mid-drain, not just an event running at its own cap —
    // same reasoning as `TimeExpansionProcessor`'s ring sizing.
    private let ring: UnsafeMutableBufferPointer<Float>
    private static let ringCapacity = 524_288    // ~10.9 s at 48 kHz
    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)

    private var ringAvailable: Int {
        let w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .relaxed)
        return (w - r + Self.ringCapacity) % Self.ringCapacity
    }

    init() {
        delay = .allocate(capacity: Self.delayCapacity)
        delay.initialize(repeating: 0)
        ring = .allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: 0)
        recomputeDerived(hangover: Self.defaultHangoverMs,
                         maxBuffer: Self.defaultMaxBufferMs,
                         threshold: Self.defaultThresholdDB,
                         release: Self.defaultReleaseDB)
    }

    deinit {
        delay.deallocate()
        ring.deallocate()
    }

    /// Reconfigure for the capture rate and clear all state. Call before
    /// starting capture in this mode.
    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        ctrlLock.lock(); _slowdownFactor = fs / outputSampleRate; ctrlLock.unlock()

        let c = controls()
        reconfigureBand(low: c.low, high: c.high)
        artifactNotch = .notch(center: fs / 4, sampleRate: fs)
        detHPa = .highpass(cutoff: min(Self.detectHighpassHz, fs / 2 * 0.9), sampleRate: fs)
        detHPb = .highpass(cutoff: min(Self.detectHighpassHz, fs / 2 * 0.9), sampleRate: fs)
        recomputeDerived(hangover: c.hangover, maxBuffer: c.maxBuffer,
                         threshold: c.threshold, release: c.release)

        totalWritten = 0
        isCapturing = false
        eventStart = 0
        emitPos = 0
        lastTrigger = 0
        eventMaxBufferSamples = 0
        blockSumSquares = 0
        blockFilled = 0
        noiseFloor = 1e-4
        stateA.store(State.idle.rawValue, ordering: .relaxed)
        eventCountA.store(0, ordering: .relaxed)
        missedCountA.store(0, ordering: .relaxed)
        ringOverflowCountA.store(0, ordering: .relaxed)
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
    }

    private func recomputeDerived(hangover: Double, maxBuffer: Double, threshold: Double, release: Double) {
        let perMs = inputSampleRate / 1000
        preRollSamples = Int(Self.preRollMs * perMs)
        postRollSamples = Int(Self.postRollMs * perMs)
        rampSamples = max(Int(Self.rampMs * perMs), 1)
        hangoverSamples = Int(hangover * perMs)
        maxBufferSamples = Int(maxBuffer * perMs)
        missedGapSamples = Int(Self.missedPulseGapMs * perMs)
        // The hangover is never shorter than the tail we keep, or the delayed
        // emitter would need to run ahead of the write head.
        emitDelaySamples = max(hangoverSamples - postRollSamples, 0)
        thresholdFactor = Float(pow(10.0, threshold / 20.0))
        // Release never above attack, or the gate would have inverted
        // hysteresis and chatter open/closed on a steady tone.
        releaseFactor = Float(pow(10.0, min(release, threshold) / 20.0))
    }

    private func reconfigureBand(low: Double, high: Double) {
        let nyquist = inputSampleRate / 2
        let lowCut = low * nyquist
        let highCut = high * nyquist
        applyHP = lowCut > 100
        if applyHP {
            bandHPa = .highpass(cutoff: lowCut, sampleRate: inputSampleRate)
            bandHPb = .highpass(cutoff: lowCut, sampleRate: inputSampleRate)
        }
        applyLP = highCut < nyquist * 0.98
        if applyLP {
            bandLPa = .lowpass(cutoff: highCut, sampleRate: inputSampleRate)
            bandLPb = .lowpass(cutoff: highCut, sampleRate: inputSampleRate)
        }
        appliedLowFraction = low
        appliedHighFraction = high
    }

    // MARK: Producer (capture thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let c = controls()
        if c.low != appliedLowFraction || c.high != appliedHighFraction {
            reconfigureBand(low: c.low, high: c.high)
        }
        recomputeDerived(hangover: c.hangover, maxBuffer: c.maxBuffer,
                         threshold: c.threshold, release: c.release)
        let g = c.gain

        for i in 0..<n {
            let raw = channel[i]

            // Listening chain: notch the hardware artifact, apply the band,
            // apply makeup gain. Filter state runs continuously whether or not
            // an event is open, so an event never starts mid-transient.
            var x = artifactNotch.process(raw)
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }
            delay[totalWritten & Self.delayMask] = x * g

            // Detection chain: independent of the listening band.
            let d = detHPb.process(detHPa.process(raw))
            blockSumSquares += d * d

            totalWritten += 1
            blockFilled += 1

            if blockFilled == Self.detectBlock {
                let rms = (blockSumSquares / Float(Self.detectBlock)).squareRoot()
                blockSumSquares = 0
                blockFilled = 0
                evaluate(blockRMS: rms)
                emitAvailable()
            }
        }
    }

    /// Decide whether the block just finished counts as signal, and open an
    /// event if it does. `totalWritten` is the block's end position.
    ///
    /// Two thresholds, not one. Opening an event requires the full
    /// `thresholdDB` over the floor; holding one open requires only
    /// `releaseDB`. See `releaseDB` for why — a single threshold clips the
    /// decaying tail off the end of every call.
    private func evaluate(blockRMS: Float) {
        // The floor adapts down quickly (so moving to a quieter spot re-arms
        // the trigger promptly) and creeps up slowly. It is frozen while an
        // event is open, or a long buzz would raise the floor high enough to
        // close itself.
        if !isCapturing {
            if blockRMS < noiseFloor {
                noiseFloor += (blockRMS - noiseFloor) * 0.2
            } else {
                noiseFloor += (blockRMS - noiseFloor) * 0.0005
            }
        }

        // The absolute terms keep a near-silent input (where the floor decays
        // toward zero) from triggering on its own dither.
        if isCapturing {
            // Hold open on the release threshold. `lastTrigger` is what
            // `emitAvailable` measures the tail from, so tracking the decay
            // here is what keeps the end of the call intact.
            if blockRMS > max(noiseFloor * releaseFactor, 3e-6) {
                lastTrigger = totalWritten
            }
        } else {
            guard blockRMS > max(noiseFloor * thresholdFactor, 1e-5) else { return }
            // Read the gap back to the previous trigger before overwriting it —
            // it's what distinguishes a new pulse from further blocks of one
            // already counted.
            let gapSinceLastTrigger = totalWritten - lastTrigger
            lastTrigger = totalWritten

            // Deaf while the previous event is still playing out — see
            // invariant 2 in the file header. This is where sustained activity
            // gets dropped, deliberately.
            guard ringAvailable == 0 else {
                if gapSinceLastTrigger > missedGapSamples {
                    missedCountA.wrappingAdd(1, ordering: .relaxed)
                }
                return
            }

            isCapturing = true
            let blockStart = totalWritten - Self.detectBlock
            eventStart = max(blockStart - preRollSamples, totalWritten - Self.delayCapacity + Self.detectBlock)
            emitPos = eventStart
            eventMaxBufferSamples = maxBufferSamples
            stateA.store(State.capturing.rawValue, ordering: .relaxed)
            eventCountA.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Emit everything the delay line has made final, up to whichever limit
    /// closes the event first.
    private func emitAvailable() {
        guard isCapturing else { return }

        // `closeAt` is where the event ends if nothing further triggers. A new
        // trigger raises `lastTrigger` and therefore moves it later — which is
        // exactly how a burst merges into one contiguous event, with no gap
        // punched into what was already emitted.
        let closeAt = min(lastTrigger + postRollSamples, eventStart + eventMaxBufferSamples)
        let limit = min(totalWritten - emitDelaySamples, closeAt)

        while emitPos < limit {
            var s = delay[emitPos & Self.delayMask]

            // Ramp in and out so emission never starts or stops on a step.
            let sinceStart = emitPos - eventStart
            if sinceStart < rampSamples {
                s *= Self.fadeWeight(Float(sinceStart) / Float(rampSamples))
            }
            let untilEnd = closeAt - emitPos
            if untilEnd <= rampSamples {
                s *= Self.fadeWeight(Float(max(untilEnd, 0)) / Float(rampSamples))
            }

            guard pushToRing(s) else {
                // Ring full. The cap should prevent this, but if it happens the
                // event is over — better a truncated event than a wrapped one.
                ringOverflowCountA.wrappingAdd(1, ordering: .relaxed)
                closeEvent()
                return
            }
            emitPos += 1
        }

        if emitPos >= closeAt {
            closeEvent()
        }
    }

    /// Fade curve for the event ramps: smoothstep, `t²(3−2t)`, for `t` in 0…1.
    ///
    /// Not linear. A linear fade reaches its endpoints with non-zero slope, so
    /// the gain has a corner at both ends of the ramp — audible as an abrupt
    /// stop even though nothing is being clipped, which is exactly how the
    /// first version sounded. Smoothstep is flat at both ends, so the fade
    /// eases in and out of full gain instead of hinging into it. Chosen over a
    /// raised cosine purely to keep a transcendental off the audio thread; the
    /// two are perceptually indistinguishable here.
    private static func fadeWeight(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func closeEvent() {
        isCapturing = false
        stateA.store(State.idle.rawValue, ordering: .relaxed)
        // The floor tracker resumes from where it was; it was frozen, not
        // reset, so it still reflects the pre-event background.
    }

    /// Returns false if the ring is full.
    private func pushToRing(_ s: Float) -> Bool {
        let cap = Self.ringCapacity
        let w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .acquiring)
        let nextW = (w + 1) % cap
        if nextW == r { return false }
        ring[w] = s
        writeIndexA.store(nextW, ordering: .releasing)
        return true
    }

    // MARK: Consumer (output thread)

    /// Straight drain at the output rate, zero-filled when empty.
    ///
    /// Deliberately no rate/drift correction, unlike the continuously-fed
    /// sibling processors: there is no steady producer to stay matched to, the
    /// silence between events is the intended output, and each event restarts
    /// from an empty ring so drift has nothing to accumulate across.
    func render(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let cap = Self.ringCapacity
        let w = writeIndexA.load(ordering: .acquiring)
        var r = readIndexA.load(ordering: .relaxed)
        var available = (w - r + cap) % cap

        var produced = 0
        while produced < frames, available > 0 {
            out[produced] = ring[r]
            r = (r + 1) % cap
            available -= 1
            produced += 1
        }
        readIndexA.store(r, ordering: .releasing)

        if produced < frames {
            for i in produced..<frames { out[i] = 0 }
        }
    }
}
