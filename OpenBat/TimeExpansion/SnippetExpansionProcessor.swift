//
//  SnippetExpansionProcessor.swift
//  OpenBat
//
//  LIVE time expansion in the Pettersson D240x pattern: record continuously into
//  a circular memory, and when a pulse triggers, replay that memory ONCE at
//  1/N speed while capture into it stops. Every sample inside the captured
//  window is played, in order, at a fixed slower clock — there is no
//  content-based selection anywhere in this file. What it gives up instead is
//  coverage: while a snippet replays, this mode is not capturing a new one.
//
//  The design is taken from the D240x manual rather than invented (see
//  Context.md §5 for the quoted text and the dated rule change):
//
//    * 50% PRETRIGGER. The capture window straddles the trigger — half the
//      memory is what happened BEFORE it. That is why the ring records
//      continuously: the pre-trigger half is already in hand when the pulse
//      arrives, so "the onset of the pulse that triggered the detector will not
//      be cut off". Trigger latency is therefore irrelevant here, which is why
//      arming from the main actor is fine.
//    * REPLAY ONCE, then re-arm. The D240x's automatic mode replays a captured
//      sequence a single time; looping is its manual mode and is not offered.
//    * DEAF WHILE REPLAYING, accepted rather than engineered around. Heterodyne
//      keeps running alongside (AudioEngineController mixes them), so the
//      listener never loses the live channel — that pairing is also the D240x's
//      own design, not an OpenBat addition.
//
//  Nobody in this repo has determined that anything infringes or is clear of
//  any patent, and no comment here should be written as though they had. The
//  reasoning behind the rule that permits this shape — and the fact that it
//  rests on an invalidity argument, not a non-infringement one — is recorded in
//  Context.md §5 and nowhere else.
//
//  Threading: identical contract to HeterodyneProcessor — `process(_:)` on the
//  realtime capture thread (producer), `render(_:frames:)` on the realtime
//  output thread (consumer), `ctrlLock` for main-thread settings. The state
//  machine is an Atomic so neither realtime thread ever takes a lock to read it.
//

import AVFoundation
import Synchronization

nonisolated final class SnippetExpansionProcessor: @unchecked Sendable {

    let outputSampleRate: Double = 48_000

    /// Capture memory bounds, in seconds — continuous, not the D240x's three
    /// switch positions (3.4 / 1.7 / 0.1). Deliberate deviation, recorded in
    /// Context.md §5 alongside the continuous expansion factor: 0.5–3.5 s is the
    /// range TE detectors generally work over, and the D240x's 0.1 s "MIN" is
    /// really a different feature (catch one pulse) rather than the short end of
    /// this one. The ring is allocated for `maxMemorySeconds` so the setting can
    /// change without reallocating on or near a realtime thread.
    static let minMemorySeconds = 0.5
    static let maxMemorySeconds = 3.5

    // MARK: State machine

    /// Deliberately a plain Int in an Atomic rather than an enum: both realtime
    /// threads read it every buffer, and this keeps that a single load.
    private enum Phase {
        static let recording = 0   // circular capture, waiting for a trigger
        static let arming    = 1   // triggered; filling the post-trigger half
        static let replaying = 2   // draining slowly; capture into the ring stops
    }
    private let phaseA = Atomic<Int>(Phase.recording)

    /// True while a snippet is replaying — drives the heterodyne duck and any UI.
    var isReplaying: Bool { phaseA.load(ordering: .acquiring) == Phase.replaying }

    /// What the mode is doing right now, for display. A single atomic load, so a
    /// view can poll it on a timer without touching either realtime thread.
    ///
    /// This is worth showing: "deaf" is the mode's central trade-off and is
    /// otherwise completely invisible — during a replay the audio sounds busy
    /// precisely when the detector is ignoring the live world.
    enum Activity {
        /// Armed: recording into the circular memory, waiting for a pulse.
        case listening
        /// Triggered; filling the post-trigger half of the buffer.
        case capturing
        /// Replaying, and not capturing anything new.
        case replaying
    }

    var activity: Activity {
        switch phaseA.load(ordering: .acquiring) {
        case Phase.arming:    .capturing
        case Phase.replaying: .replaying
        default:              .listening
        }
    }

    /// How far through the current replay, 0–1, or 0 when not replaying. Read
    /// without synchronisation on purpose: it is a display value, a torn read is
    /// at worst one frame stale, and locking would put the UI on the audio
    /// thread's critical path.
    var replayProgress: Double {
        guard isReplaying, replayCount > 0 else { return 0 }
        return min(max(replayPos / Double(replayCount), 0), 1)
    }

    // MARK: Control (main thread ↔ realtime threads)

    private let ctrlLock = NSLock()
    private var _expansion: Double = 8
    /// 1.5 s default: long enough to hold a typical pass, and at the default 8×
    /// it replays in 12 s rather than the 27 s a full buffer would cost — the
    /// mode is deaf to new snippets for that whole time, so the default trades
    /// buffer length for getting back to armed sooner.
    private var _memorySeconds: Double = 1.5
    private var _gain: Float = 4
    /// 18 dB by default. §3's expander landed the post-roll at −16.3 dB once it
    /// was working, so this is the same order — enough to put the background
    /// well under the calls without the pumping a deeper setting produces.
    private var _hissReductionDB: Double = 18
    private var _fadeMS: Double = 30

    /// Slowdown factor N: the captured audio is replayed at 1/N speed.
    ///
    /// Note the interaction with aliasing, which is why this is clamped rather
    /// than free. Input frequency f lands at f/N, so the 24 kHz output band
    /// holds everything below 24 kHz × N. At N = 8 (the 384/48 ratio) that is
    /// 192 kHz — the entire input Nyquist, so nothing can fold. Below 8 we are
    /// decimating and content above 24 kHz × N aliases back into the audible
    /// band, so `reset` installs a low-pass at that corner. Above 8 we are
    /// interpolating and no filter is needed.
    var expansion: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expansion }
        set {
            let clamped = min(max(newValue, 4), 20)
            ctrlLock.lock(); _expansion = clamped; ctrlLock.unlock()
        }
    }

    /// Capture window length. Changing it takes effect at the next trigger, not
    /// mid-replay.
    var memorySeconds: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _memorySeconds }
        set {
            let clamped = min(max(newValue, Self.minMemorySeconds), Self.maxMemorySeconds)
            ctrlLock.lock(); _memorySeconds = clamped; ctrlLock.unlock()
        }
    }

    /// Output makeup gain — bat calls are weak and this path applies no other.
    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    /// How far the background is pushed down between calls, in dB. 0 disables
    /// the expander entirely (the snippet plays exactly as captured); the useful
    /// range is roughly 6–30 dB. This is depth, not a threshold: quiet material
    /// is attenuated by up to this much, never removed.
    var hissReductionDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _hissReductionDB }
        set {
            let clamped = min(max(newValue, 0), 40)
            ctrlLock.lock(); _hissReductionDB = clamped; ctrlLock.unlock()
        }
    }

    /// Fade applied to the start and end of each replay, in ms of OUTPUT time.
    /// Long enough to be heard as a fade rather than a de-click.
    var fadeMS: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _fadeMS }
        set {
            let clamped = min(max(newValue, 1), 250)
            ctrlLock.lock(); _fadeMS = clamped; ctrlLock.unlock()
        }
    }

    // MARK: Capture ring (producer: capture thread; frozen during replay)

    /// Circular capture memory at the INPUT rate. Allocated once for the maximum
    /// memory setting — manual memory rather than an Array because both realtime
    /// threads touch it and Array's exclusivity rules don't permit that.
    private var ring: UnsafeMutableBufferPointer<Float>
    private var ringCapacity: Int
    private var inputSampleRate: Double = 384_000

    /// Write cursor, and how many samples have ever been written. The counter is
    /// what makes the pre-trigger safe: at a trigger we need to know whether the
    /// ring has actually been filled yet, so a snippet taken seconds after
    /// launch cannot replay uninitialised memory. (The D240x has this exact
    /// failure and documents it as a user workaround — "the memory is filled
    /// with a random signal which may sound like white noise... allow at least
    /// the chosen memory time to elapse". Here it is simply enforced.)
    private var writeCursor = 0
    private var totalWritten = 0

    /// Set at the trigger: how many more input samples to capture before replay.
    private var postTriggerRemaining = 0

    // Anti-alias low-pass for N < 8, see `expansion`. Two cascaded biquads.
    private var aaA = Biquad(), aaB = Biquad()
    private var applyAA = false
    private var appliedAAExpansion = -1.0

    /// Input high-pass, always on. Rumble, handling noise and wind sit below the
    /// bat band and slow down into the most audible part of the output, so they
    /// are removed on the way IN — before the ring, so the replay never contains
    /// them. 12 kHz matches the detector's own front end; the lowest UK call
    /// (noctule sweep tail, ~17 kHz) stays well clear.
    private var hpA = Biquad(), hpB = Biquad()

    // MARK: Background expander (see Context.md §3, "The background expander")
    //
    // A snippet carries the background it was recorded against, and at 8-20×
    // that background is stretched too — which is exactly what turns it from an
    // unnoticed click into audible hiss. §3's findings from the withdrawn ATE
    // mode are followed here rather than re-derived:
    //
    //   * EXPANDER, NOT GATE. A hard gate silences everything under threshold,
    //     which is the amplitude-domain version of truncating the call.
    //   * ATTACK INSTANT, RELEASE SMOOTHED. A smoothed attack measured 1.67 ms
    //     to reach −1 dB, against a MYCA call of ~1.3 ms — it would still be
    //     opening when the call had ended.
    //   * ENVELOPE INTERPOLATED between block centres. Held piecewise constant,
    //     gain steps by the full depth at a block boundary, and time expansion
    //     does not soften a true sample-to-sample discontinuity.
    //
    // This is a GAIN ENVELOPE: every captured sample is still emitted, in order,
    // same count, same time base. §5 records that distinction explicitly.

    /// Block RMS of the captured audio, one entry per `envBlock` input samples,
    /// tracking the capture ring. Written on the capture thread as the ring
    /// fills, so no pass over the buffer is needed at the trigger.
    private var envRing: UnsafeMutableBufferPointer<Float>
    private var envCapacity: Int
    private static let envBlock = 128

    /// Round up to a whole number of envelope blocks — see `ringCapacity`.
    private static func blockAligned(_ n: Int) -> Int {
        (n + envBlock - 1) / envBlock * envBlock
    }
    private var envAccum: Float = 0
    private var envCount = 0
    /// Threshold and depth for the replay in flight, snapshotted at the trigger
    /// alongside the other replay parameters.
    /// Threshold is set from the snippet's OWN peak rather than an absolute
    /// level, so a distant pass expands the same way a close one does. 34 dB
    /// below peak sits under the quietest real call in a pass while staying
    /// above a typical noise floor.
    private static let thresholdBelowPeakDB: Float = 34
    private var replayThreshold: Float = 0
    private var replayDepth: Float = 1
    /// Release smoothing state, output-thread only.
    private var expanderGain: Float = 1

    // MARK: Replay (consumer: output thread)

    /// Snapshot of the window to replay, taken when the ring freezes. Both are
    /// only written in `arming → replaying`, and only read while `replaying`,
    /// so the phase store/load pair is what publishes them.
    private var replayStart = 0
    private var replayCount = 0
    private var replayPos = 0.0
    /// Input samples per output sample, and output gain — both snapshotted at the
    /// trigger so the output thread never takes `ctrlLock` and the rate cannot
    /// change part-way through a replay.
    private var replayStep = 1.0
    private var replayGain: Float = 4
    private var replayFadeSeconds = 0.03
    /// Ramp to keep a replay from starting or ending on a step.
    private var replayEnvelope: Float = 0
    /// Capture-thread-only latch for spotting the replay→recording transition.
    private var wasReplaying = false

    init() {
        // Rounded to a whole number of envelope blocks. The replay side derives
        // the envelope index as `ringIndex / envBlock`, which only wraps in step
        // with the sample ring if the ring holds an exact number of blocks.
        ringCapacity = Self.blockAligned(Int(Self.maxMemorySeconds * 384_000))
        ring = .allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0)
        envCapacity = ringCapacity / Self.envBlock
        envRing = .allocate(capacity: envCapacity)
        envRing.initialize(repeating: 0)
    }

    deinit {
        ring.deallocate()
        envRing.deallocate()
    }

    /// Reconfigure for a capture sample rate and reset all state. Call before
    /// installing the tap — no concurrent `process`/`render` at this point.
    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        let needed = Int(Self.maxMemorySeconds * fs)
        if needed > ringCapacity {
            ring.deallocate()
            envRing.deallocate()
            ringCapacity = Self.blockAligned(needed)
            ring = .allocate(capacity: ringCapacity)
            envCapacity = ringCapacity / Self.envBlock
            envRing = .allocate(capacity: envCapacity)
        }
        ring.initialize(repeating: 0)
        envRing.initialize(repeating: 0)
        envAccum = 0
        envCount = 0
        expanderGain = 1
        hpA = .highpass(cutoff: min(12_000, fs / 2 * 0.9), sampleRate: fs)
        hpB = .highpass(cutoff: min(12_000, fs / 2 * 0.9), sampleRate: fs)
        writeCursor = 0
        totalWritten = 0
        postTriggerRemaining = 0
        replayStart = 0
        replayCount = 0
        replayPos = 0
        replayEnvelope = 0
        replayStep = 1
        replayGain = _gain
        replayFadeSeconds = _fadeMS / 1000
        wasReplaying = false
        appliedAAExpansion = -1
        reconfigureAntiAlias(expansion)
        phaseA.store(Phase.recording, ordering: .releasing)
    }

    /// Install (or remove) the decimation guard for the current factor.
    /// Capture-thread only, and only when the factor actually moved.
    private func reconfigureAntiAlias(_ n: Double) {
        let naturalRatio = inputSampleRate / outputSampleRate
        applyAA = n < naturalRatio
        if applyAA {
            let corner = min(outputSampleRate / 2 * n, inputSampleRate / 2 * 0.98)
            aaA = .lowpass(cutoff: corner, sampleRate: inputSampleRate)
            aaB = .lowpass(cutoff: corner, sampleRate: inputSampleRate)
        }
        appliedAAExpansion = n
    }

    // MARK: Trigger (main thread)

    /// Arm a capture. Called at a pulse's rising edge; ignored unless idle, which
    /// is what gives "replay once, no retrigger while replaying" for free.
    ///
    /// Returns true if this call armed a snippet, so the caller can drive UI
    /// without having to poll.
    @discardableResult
    func trigger() -> Bool {
        let (exchanged, _) = phaseA.compareExchange(expected: Phase.recording,
                                                    desired: Phase.arming,
                                                    ordering: .acquiringAndReleasing)
        return exchanged
    }

    /// Abandon any capture or replay in progress and return to recording.
    func cancel() {
        phaseA.store(Phase.recording, ordering: .releasing)
    }

    // MARK: Producer (capture thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let phase = phaseA.load(ordering: .acquiring)
        // While replaying, the ring is the replay source and must not move.
        guard phase != Phase.replaying else {
            wasReplaying = true
            return
        }
        // First buffer after a replay ended: discard the recorded history, so the
        // next snippet cannot contain audio from before the replay — which would
        // be tens of seconds stale by then. Done here, on the capture thread,
        // because `totalWritten` and `writeCursor` belong to this thread alone.
        if wasReplaying {
            wasReplaying = false
            totalWritten = 0
            postTriggerRemaining = 0
        }

        let factor = expansion
        if factor != appliedAAExpansion { reconfigureAntiAlias(factor) }

        let memSamples = min(Int(memorySeconds * inputSampleRate), ringCapacity)

        if phase == Phase.arming && postTriggerRemaining == 0 {
            // 50% pretrigger: capture half the memory from here, which leaves the
            // other half — already in the ring — sitting before the trigger.
            postTriggerRemaining = memSamples / 2
        }

        for i in 0..<n {
            // High-pass first: rumble is removed before it ever enters the ring,
            // so no replay can contain it and no later stage has to deal with it.
            var x = hpB.process(hpA.process(channel[i]))
            if applyAA { x = aaB.process(aaA.process(x)) }
            ring[writeCursor] = x

            // Block RMS for the expander, accumulated as we go so the trigger
            // needs no pass over the buffer. Indexed by the block the sample
            // lands in, so `envRing[p / envBlock]` is the level around input
            // position p on the replay side.
            envAccum += x * x
            envCount += 1
            if envCount == Self.envBlock {
                envRing[writeCursor / Self.envBlock] = (envAccum / Float(Self.envBlock)).squareRoot()
                envAccum = 0
                envCount = 0
            }

            writeCursor += 1
            if writeCursor == ringCapacity { writeCursor = 0 }
            totalWritten += 1

            if phase == Phase.arming {
                postTriggerRemaining -= 1
                if postTriggerRemaining <= 0 {
                    // Window is [writeCursor - memSamples, writeCursor), clamped
                    // to what has actually been recorded since reset so a trigger
                    // in the first seconds cannot replay uninitialised memory.
                    let usable = min(memSamples, totalWritten)
                    replayCount = usable
                    replayStart = ((writeCursor - usable) % ringCapacity + ringCapacity) % ringCapacity
                    replayPos = 0
                    replayEnvelope = 0
                    postTriggerRemaining = 0
                    // Snapshot the playback parameters HERE rather than reading
                    // them per render call. Two reasons: it keeps `ctrlLock` off
                    // the realtime output thread entirely, and it stops a slider
                    // drag mid-replay from warping the rate (and so the pitch)
                    // part-way through a call. Settings changes take effect at
                    // the next trigger, which is also how the D240x's switches
                    // behave.
                    replayStep = (inputSampleRate / outputSampleRate) / factor
                    replayGain = gain
                    replayFadeSeconds = fadeMS / 1000

                    // Expander threshold, from this snippet's own peak so a
                    // distant pass expands like a close one. Scanning the block
                    // envelope is ~10k comparisons at the largest buffer, which
                    // is cheap enough for the capture thread and happens once
                    // per trigger — the alternative, tracking a running peak,
                    // could not be windowed to the replay range.
                    var peak: Float = 0
                    var b = replayStart / Self.envBlock
                    let blocks = max(usable / Self.envBlock, 1)
                    for _ in 0..<blocks {
                        peak = max(peak, envRing[b])
                        b += 1
                        if b >= envCapacity { b = 0 }
                    }
                    replayThreshold = peak * pow(10, -Self.thresholdBelowPeakDB / 20)
                    replayDepth = Float(pow(10, -hissReductionDB / 20))
                    expanderGain = 1
                    // Publishes the replay parameters to the output thread.
                    phaseA.store(Phase.replaying, ordering: .releasing)
                    return
                }
            }
        }
    }

    // MARK: Consumer (output thread)

    /// Render `frames` of replay audio, or silence when idle. Returns true if
    /// anything non-silent was produced, so the caller can duck heterodyne only
    /// while a snippet is actually sounding.
    @discardableResult
    func render(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard phaseA.load(ordering: .acquiring) == Phase.replaying else {
            for i in 0..<frames { out[i] = 0 }
            return false
        }

        // Input samples consumed per output sample, snapshotted at the trigger
        // (see `process`) so this thread takes no lock and the rate cannot move
        // mid-replay. At the natural 384/48 ratio with N = 8 it is exactly 1.0;
        // below 8 it decimates (guarded by the anti-alias filter installed at
        // capture), above 8 it interpolates.
        let step = replayStep
        let g = replayGain

        // Fade in and out of each replay, in output time. `fadeSeconds` is a
        // proper fade rather than the de-click a couple of ms would give: a
        // snippet arrives out of the live heterodyne bed and should not appear
        // and vanish abruptly against it.
        let fadeSeconds = replayFadeSeconds
        let slew = Float(1.0 / (outputSampleRate * fadeSeconds))
        let fadeOutFrom = Double(replayCount) - step * outputSampleRate * fadeSeconds

        // Expander release, in output time. Attack is instant (the envelope is
        // taken straight), release is smoothed — Context.md §3 measured that a
        // smoothed attack was still opening 1.67 ms in, against a 1.3 ms call.
        let releaseSlew = Float(1.0 / (outputSampleRate * 0.020))
        let threshold = replayThreshold
        let depth = replayDepth
        let expanding = depth < 0.999 && threshold > 0

        var produced = 0
        while produced < frames {
            if replayPos >= Double(replayCount) - 1 {
                break
            }
            let idx = Int(replayPos)
            let frac = Float(replayPos - Double(idx))
            let i0 = (replayStart + idx) % ringCapacity
            let i1 = (i0 + 1) % ringCapacity
            let s = ring[i0] + frac * (ring[i1] - ring[i0])

            if expanding {
                // Block envelope, INTERPOLATED between block centres. Held
                // piecewise constant it would step by the full depth at a block
                // boundary — a true sample-to-sample discontinuity, which
                // slowing the audio down does nothing to soften (§3).
                // From `i0`, which is already wrapped into the ring. Deriving it
                // from the unwrapped `replayStart + idx` is wrong once the window
                // crosses the end of the ring: integer division and the modulo do
                // not commute, so the envelope was being read from an unrelated
                // block — which both defeated the expander and injected the
                // artefacts it was supposed to remove.
                let e = i0 / Self.envBlock
                let ePos = Float(i0 % Self.envBlock) / Float(Self.envBlock)
                let e0 = envRing[e]
                let e1 = envRing[(e + 1) % envCapacity]
                let level = e0 + ePos * (e1 - e0)

                // Expander, not gate: below threshold the gain falls smoothly
                // toward `depth` in proportion to how far under it the level is,
                // and never past it. Quiet material is pushed down, not removed.
                let ratio = min(max(level / threshold, 0), 1)
                let target = depth + (1 - depth) * ratio
                if target >= expanderGain {
                    expanderGain = target                        // instant attack
                } else {
                    expanderGain = max(expanderGain - releaseSlew, target)
                }
            } else {
                expanderGain = 1
            }

            let target: Float = replayPos >= fadeOutFrom ? 0 : 1
            if replayEnvelope < target { replayEnvelope = min(replayEnvelope + slew, target) }
            else { replayEnvelope = max(replayEnvelope - slew, target) }

            out[produced] = s * g * replayEnvelope * expanderGain
            produced += 1
            replayPos += step
        }

        if produced < frames {
            for i in produced..<frames { out[i] = 0 }
            // Replay finished: re-arm. The "ring restarts empty" part is done by
            // the CAPTURE thread when it observes this transition — see
            // `process`. Resetting `totalWritten` from here would be a plain
            // (non-atomic) write to a variable the capture thread also writes,
            // i.e. a data race between two realtime threads. The phase store is
            // the only cross-thread signal.
            phaseA.store(Phase.recording, ordering: .releasing)
        }
        return produced > 0
    }
}
