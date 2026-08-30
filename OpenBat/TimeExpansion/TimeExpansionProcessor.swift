//
//  TimeExpansionProcessor.swift
//  OpenBat
//
//  Playback-only classic time expansion: literally play a previously recorded
//  WAV back slower, preserving EVERY sample — the oldest bat-detector
//  technique there is (originally done by physically slowing tape playback).
//  There is no per-sample selection or framing: `process` copies every input
//  sample straight into the output ring (band-limited + gained, nothing
//  more). The slowdown comes entirely from PlaybackDriver pacing its file
//  reads at this processor's OUTPUT rate instead of the file's native
//  384 kHz rate when this mode is active (see `start()`'s `paceRate`) — this
//  processor has no idea it's being fed slowly, it just passes through. Both
//  rates are chosen by PlaybackEngine.expansionFactor, so the factor is the
//  player's setting rather than the accident of a fixed 48 kHz it once was.
//
//  This is deliberately playback-only. Live capture can't do this: pacing a
//  live 384 kHz tap at 48 kHz-worth-per-second means falling permanently
//  behind real time, which a live monitor can't do — that's a fundamentally
//  different problem from playing back a file that's already fully on disk.
//  An earlier LIVE time-expansion processor — a different, continuous
//  frame-selection design aimed at that live problem — was removed over
//  exposure to an active third-party patent, US 8,599,647. Note the careful
//  wording: nobody in this repo has determined that anything infringes, and
//  no comment here should say otherwise. See Context.md §5.
//
//  What IS structurally true of this file: there is no content-based
//  selection anywhere in it, only a fixed pass-through at a slower clock. Every
//  sample of the recording is played, so the claim's "selecting a fraction of
//  the samples" element is not met — which is a real distinction, and the
//  reason this mode is untroubled where the live ones are not.
//
//  The output ring (see its own doc comment) is sized so that losing any
//  audio at all requires an actual technical failure — a multi-second output
//  stall — not the ordinary sub-second clock drift the variable playback
//  rate below already corrects losslessly. `overflowCount` ticks if that
//  failure threshold is ever crossed, so a real loss is reported rather than
//  silent, but it is not claimed to be structurally impossible the way
//  content-based selection is: a ring is finite, and an unbounded stall
//  would still exhaust it.
//
//  Threading: identical contract to HeterodyneProcessor
//  — `process(_:)` runs on the (paced) producer thread, `render(_:frames:)` on
//  the realtime output thread, lock-free SPSC ring between them.
//

import AVFoundation
import Synchronization

nonisolated final class TimeExpansionProcessor: @unchecked Sendable {

    /// The rate this processor's ring is DRAINED at by the output node — set
    /// by `reset`, because the player now chooses its own playback speed and
    /// that speed is precisely the ratio between this rate and the rate the
    /// pacing thread fills the ring at. It was a hardcoded 48 kHz, which is
    /// why 8× used to be the only speed there was.
    private(set) var outputSampleRate: Double = 48_000

    /// The actual slowdown factor for the file and output rate this processor
    /// was last `reset` for — computed rather than assumed, so a
    /// differently-rated file can't silently drift out of sync with the factor
    /// the player is showing. Read from the main thread (UI); set from
    /// `reset`, same cross-thread contract as `gain`.
    var slowdownFactor: Double {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return _slowdownFactor
    }

    // MARK: Control (main thread ↔ producer/output threads)

    private let ctrlLock = NSLock()
    private var _gain: Float = 4
    private var _bandLowFraction: Double = 0   // fraction of Nyquist
    private var _bandHighFraction: Double = 1
    private var _slowdownFactor: Double = 384_000 / 48_000

    /// Output makeup gain. Straight pass-through preserves the recording's own
    /// level, and bat calls are weak, so some makeup is normally wanted.
    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    /// Restrict playback to a frequency band (fractions of Nyquist): high-pass
    /// at `low`, low-pass at `high`. Matches the same viewport-derived band the
    /// other listening modes use.
    func setBand(low: Double, high: Double) {
        ctrlLock.lock()
        _bandLowFraction = low
        _bandHighFraction = high
        ctrlLock.unlock()
    }

    private func bandFractions() -> (Double, Double) {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return (_bandLowFraction, _bandHighFraction)
    }

    // MARK: DSP state (producer thread only)

    private var inputSampleRate: Double = 384_000
    private var bandHPa = Biquad(), bandHPb = Biquad()
    private var bandLPa = Biquad(), bandLPb = Biquad()
    private var applyHP = false
    private var applyLP = false
    private var appliedLowFraction = -1.0
    private var appliedHighFraction = -1.0
    /// Reused output scratch so `process` doesn't allocate on the producer thread.
    private var scratch = [Float]()

    // MARK: Output ring buffer

    // Lock-free SPSC ring, same contract as the sibling processors: the
    // producer only advances `writeIndexA`, the consumer only advances
    // `readIndexA`. Manually managed memory (not a Swift Array) because both
    // threads touch elements concurrently, which Array's exclusivity/CoW
    // rules don't permit.
    //
    // Sized for 25 s, not the ~2 s an earlier version used. Ordinary clock
    // drift between the pacing thread and the audio hardware never needs
    // this headroom at all — that's what the `softTarget`-seeking variable
    // playback rate below is for, and it's lossless (resampling, not
    // dropping). This capacity exists purely so that `enqueue`'s drop path
    // and `render`'s `hardMax` catch-up are unreachable by anything short of
    // a genuine multi-second stall (an audio session interruption, a truly
    // frozen output thread) — the failure this file's header comment means
    // by "discarding" is supposed to be an actual technical failure, not
    // routine jitter. 25 s of 48 kHz float32 is ~4.6 MB, cheap enough that
    // there's no reason to size this any tighter.
    private let ring: UnsafeMutableBufferPointer<Float>

    init() {
        ring = .allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: 0)
    }

    deinit { ring.deallocate() }

    private static let ringCapacity = 1_200_000   // 25 s at 48 kHz
    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)
    private var readFrac = 0.0 // fractional read position (consumer only)
    // The pacing thread's wall-clock reads and the audio hardware's output
    // clock aren't the same clock, so the queue slowly drifts even though
    // both are nominally paced to match — same reasoning as
    // HeterodyneProcessor's identical fields.
    private var softTarget = 4_800  // ~100 ms at 48 kHz
    private var hardMax = 960_000   // 20 s — see the ring's own doc comment

    /// Bumped once per overflow *event* (not per dropped sample) in either
    /// `enqueue`'s drop path or `render`'s `hardMax` catch-up — the two
    /// places this processor can actually lose audio. At the sizing above,
    /// hitting this at all means a real stall happened, not ordinary drift;
    /// surfaced so the UI can show an honest "audio was dropped" signal
    /// instead of the loss being silent.
    private let overflowCountA = Atomic<Int>(0)
    var overflowCount: Int { overflowCountA.load(ordering: .relaxed) }

    /// Samples sitting in the output ring: fed by the pacing thread but not
    /// yet rendered to the speaker. The ring deliberately holds a standing
    /// `softTarget` (~100 ms of listening time) so ordinary drift is absorbed
    /// losslessly — which also means the sample being FED is ~100 ms ahead of
    /// the sample being HEARD. PlaybackDriver subtracts this from the position
    /// it publishes, so the playhead sits on the call you are hearing rather
    /// than one that already went past. Readable from any thread (both indices
    /// are atomics); a snapshot is all a latency figure needs.
    var queuedFrames: Int {
        let cap = ring.count
        let w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .relaxed)
        return (w - r + cap) % cap
    }

    /// Asks the output thread to drop whatever is still queued, at its next
    /// `render`. Used when playback restarts from a new position (a seek, a
    /// speed or mode change): without it the first ~100 ms heard after the
    /// jump is leftover audio from where the playhead used to be.
    ///
    /// Deliberately a REQUEST rather than a direct `readIndexA` store: the
    /// consumer alone may move the read index, so a producer-side reset would
    /// race `render` and could leave the queue looking almost a full ring
    /// deep. Bumping a counter the consumer honours keeps the SPSC discipline
    /// intact.
    private let flushRequestA = Atomic<Int>(0)
    private var flushesHandled = 0   // consumer only
    func requestFlush() { flushRequestA.wrappingAdd(1, ordering: .relaxed) }

    /// Reconfigure for a file's sample rate and reset all DSP/ring state. Call
    /// before starting playback in this mode.
    func reset(inputSampleRate fs: Double, outputSampleRate outFs: Double = 48_000) {
        inputSampleRate = fs
        outputSampleRate = outFs
        // Both scale with the drain rate, or "100 ms of slack" would mean a
        // different amount of audio at every playback speed.
        softTarget = Int(outFs * 0.1)
        // 20 s of headroom where the ring can hold it — see the ring's own doc
        // comment for why this is deliberately far beyond ordinary drift. A
        // faster playback speed drains faster, so the same second count costs
        // more of a fixed-size ring; leave a second spare either way.
        hardMax = min(Int(outFs * 20), Self.ringCapacity - Int(outFs))
        ctrlLock.lock(); _slowdownFactor = fs / outFs; ctrlLock.unlock()
        let (low, high) = bandFractions()
        reconfigureBand(low: low, high: high)
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
        readFrac = 0
        overflowCountA.store(0, ordering: .relaxed)
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

    // MARK: Producer

    /// Copies every sample through untouched (bar band-limit + gain) — no
    /// framing, no counting, no discarding. `buffer` arrives at whatever pace
    /// PlaybackDriver's pacing thread has chosen; this code doesn't know or
    /// care what that pace is.
    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let (lowF, highF) = bandFractions()
        if lowF != appliedLowFraction || highF != appliedHighFraction {
            reconfigureBand(low: lowF, high: highF)
        }
        let g = gain

        scratch.removeAll(keepingCapacity: true)
        if scratch.capacity < n { scratch.reserveCapacity(n) }

        for i in 0..<n {
            var x = channel[i]
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }
            scratch.append(x * g)
        }

        enqueue(scratch)
    }

    private func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let cap = ring.count
        var w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .acquiring)
        for s in samples {
            let nextW = (w + 1) % cap
            // Ring genuinely full — at 25 s of headroom this means the output
            // thread has actually stalled, not just drifted. Drop the
            // remainder and count it as an overflow event rather than doing
            // it silently.
            if nextW == r {
                overflowCountA.wrappingAdd(1, ordering: .relaxed)
                break
            }
            ring[w] = s
            w = nextW
        }
        writeIndexA.store(w, ordering: .releasing)
    }

    // MARK: Consumer (output thread)

    func render(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let cap = ring.count
        let w = writeIndexA.load(ordering: .acquiring)
        var r = readIndexA.load(ordering: .relaxed)
        var available = (w - r + cap) % cap

        // Honoured here, on the consumer, for the reason `requestFlush` gives.
        let flushes = flushRequestA.load(ordering: .relaxed)
        if flushes != flushesHandled {
            flushesHandled = flushes
            r = w
            readFrac = 0
            available = 0
        }

        if available > hardMax {
            // Same story as `enqueue`'s drop above: `hardMax` is 20 s, so
            // getting here means the output thread was genuinely stalled for
            // seconds, not the ordinary sub-second drift the rate correction
            // below already absorbs losslessly.
            overflowCountA.wrappingAdd(1, ordering: .relaxed)
            r = (r + (available - softTarget)) % cap
            available = softTarget
        }

        let error = Double(available) - Double(softTarget)
        let rate = 1.0 + min(max(error / Double(softTarget) * 0.1, -0.03), 0.03)

        var produced = 0
        while produced < frames, available >= 2 {
            let next = (r + 1) % cap
            let s0 = ring[r]
            let s1 = ring[next]
            out[produced] = s0 + Float(readFrac) * (s1 - s0)
            produced += 1

            readFrac += rate
            let advance = Int(readFrac)
            if advance > 0 {
                r = (r + advance) % cap
                available -= advance
                readFrac -= Double(advance)
            }
        }
        readIndexA.store(r, ordering: .releasing)

        if produced < frames {
            for i in produced..<frames { out[i] = 0 }
        }
    }
}
