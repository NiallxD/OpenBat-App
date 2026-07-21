//
//  TimeExpansionProcessor.swift
//  OpenBat
//
//  Real-time time expansion that keeps the bat's natural tempo. Bats are silent
//  most of the time, so we only expand the brief *calls*: a detector gates the
//  stream, and detected (band-limited) samples are pushed into the 48 kHz output
//  at full 384 kHz resolution. Replaying high-rate samples at 48 kHz is an 8×
//  expansion (pitch ÷8, duration ×8); since each call is short and the gaps are
//  long, the stretched calls still land at roughly their real arrival times — so
//  you hear expanded call detail without losing the rhythm of the pass.
//
//  Threading mirrors HeterodyneProcessor: `process` on the capture thread feeds a
//  lock-free SPSC ring drained by `render` on the output thread.
//

import AVFoundation
import Synchronization

nonisolated final class TimeExpansionProcessor: @unchecked Sendable {

    let outputSampleRate: Double = 48_000

    // MARK: Control (main ↔ audio)

    private let ctrlLock = NSLock()
    private var _gain: Float = 4
    private var _bandLowFraction: Double = 0
    private var _bandHighFraction: Double = 1
    /// How far (dB) a gate block's detection-band RMS must sit ABOVE the rolling
    /// noise floor to count as a call. Relative rather than absolute (the old fixed
    /// −38 dBFS) so quiet high-frequency species (e.g. California Myotis, which sit
    /// ~18–25 dB over the floor but only −32…−39 dBFS absolute) still open the gate,
    /// while the floor auto-tracks conditions to keep duty bounded. Default kept in
    /// sync with RTESettings.defaultMarginDB (apply() overwrites it on launch).
    private var _marginDB: Float = 12
    /// Detection high-pass cutoff (Hz). Only energy above this drives the gate, so
    /// low-frequency handling noise (footsteps, clothing, wind — all well below the
    /// bat band) can't trigger expansion. The enqueued (listened) audio is unchanged;
    /// this filter feeds the gate DECISION only. Matches PulseDetector.minFrequencyHz.
    private var _minFrequencyHz: Float = 15_000
    /// How long to keep the gate open after the signal drops below threshold (ms).
    private var _holdMs: Float = 15.0
    /// RMS window size for the sub-buffer gate (ms). Smaller = more responsive; larger = smoother.
    private var _gateBlockMs: Float = 1.5

    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    var marginDB: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _marginDB }
        set { ctrlLock.lock(); _marginDB = newValue; ctrlLock.unlock() }
    }

    var minFrequencyHz: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _minFrequencyHz }
        set { ctrlLock.lock(); _minFrequencyHz = newValue; ctrlLock.unlock() }
    }

    var holdMs: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _holdMs }
        set { ctrlLock.lock(); _holdMs = newValue; ctrlLock.unlock() }
    }

    var gateBlockMs: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gateBlockMs }
        set { ctrlLock.lock(); _gateBlockMs = newValue; ctrlLock.unlock() }
    }

    func setBand(low: Double, high: Double) {
        ctrlLock.lock(); _bandLowFraction = low; _bandHighFraction = high; ctrlLock.unlock()
    }

    private func bandFractions() -> (Double, Double) {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return (_bandLowFraction, _bandHighFraction)
    }

    // MARK: DSP state (capture thread only)

    private var inputSampleRate: Double = 384_000
    private var bandHPa = Biquad(), bandHPb = Biquad()
    private var bandLPa = Biquad(), bandLPb = Biquad()
    private var applyHP = false
    private var applyLP = false
    private var appliedLowFraction = -1.0
    private var appliedHighFraction = -1.0
    /// Detection high-pass (4th-order = two cascaded biquads) at `minFrequencyHz`.
    /// Runs continuously (like the band filters) so its state stays stable; the
    /// filtered signal is used only to measure per-block RMS for the gate decision.
    private var detHPa = Biquad(), detHPb = Biquad()
    private var appliedMinFreq = -1.0
    /// Rolling estimate of the detection-band noise floor (dB). Tracks down fast to
    /// the quiet background and rises slowly, so a short call doesn't inflate it but
    /// a sustained loud section gradually does (bounding gate duty). The gate opens
    /// when a block sits `marginDB` above this.
    private var noiseFloorDB: Float = -60
    /// Fast envelope follower over the detection-band signal, used only to drive the
    /// per-sample noise gate below — separate from `noiseFloorDB` (which tracks slowly
    /// over whole blocks) so the gate can react within a call, not just between them.
    private var gateEnvDB: Float = -80
    /// Samples still pushed after the level drops, to catch call tails / bridge dips.
    /// Sample-based so the gate tracks the real call extent rather than whole IO buffers.
    private var holdSamplesRemaining = 0
    private var scratch = [Float]()
    /// Parallel to `scratch`: the detection-high-passed signal, used for gate RMS only.
    private var detScratch = [Float]()

    // MARK: Lock-free SPSC ring (push expanded call samples; silence between calls)

    // Manually managed memory (not a Swift Array): the producer and consumer
    // realtime threads touch elements concurrently, which Array's exclusivity/CoW
    // rules don't permit. Mirrors HeterodyneProcessor.
    private let ring: UnsafeMutableBufferPointer<Float>  // ~2 s at 48 kHz

    init() {
        ring = .allocate(capacity: 96_000)
        ring.initialize(repeating: 0)
    }

    deinit { ring.deallocate() }

    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)
    private var hardMax = 24_000 // ~0.5 s of queued expansion before we skip ahead

    // MARK: Output soft-gate envelope (output thread only)

    // Ramps 0→1 when ring has data, 1→0 when ring is empty. Eliminates gate-open /
    // gate-close clicks by replacing instantaneous amplitude steps with a short linear
    // ramp. lastSample is held during the fade-out so the signal decays to zero rather
    // than cutting to it — important when the instantaneous sample value is non-zero.
    private var outputEnvelope: Float = 0
    private var lastSample: Float = 0
    // 4 ms at 48 kHz = 192 samples → rate = 1/192 per sample. Gentler than the old
    // 2 ms ramp so gate open/close transitions don't click on short calls.
    private let envelopeRate: Float = 1.0 / 192.0

    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        let (low, high) = bandFractions()
        reconfigureBand(low: low, high: high)
        reconfigureDetection(minFreq: Double(minFrequencyHz))
        noiseFloorDB = -60
        gateEnvDB = -80
        holdSamplesRemaining = 0
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
        hardMax = Int(outputSampleRate * 0.5)
        outputEnvelope = 0
        lastSample = 0
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

    /// (Re)build the detection high-pass at `minFreq`. Two cascaded biquads give a
    /// 4th-order roll-off (~24 dB/oct), so content an octave or more below the cutoff
    /// — footsteps, clothing, wind — is knocked well under the floor before the gate
    /// measures it. A cutoff at/below 100 Hz disables it (pass everything).
    private func reconfigureDetection(minFreq: Double) {
        let nyquist = inputSampleRate / 2
        let cutoff = max(0, min(minFreq, nyquist * 0.98))
        if cutoff > 100 {
            detHPa = .highpass(cutoff: cutoff, sampleRate: inputSampleRate)
            detHPb = .highpass(cutoff: cutoff, sampleRate: inputSampleRate)
        }
        appliedMinFreq = minFreq
    }

    // MARK: Producer (capture thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let (lowF, highF) = bandFractions()
        if lowF != appliedLowFraction || highF != appliedHighFraction {
            reconfigureBand(low: lowF, high: highF)
        }
        let minFreq = Double(minFrequencyHz)
        if minFreq != appliedMinFreq { reconfigureDetection(minFreq: minFreq) }
        let applyDetHP = appliedMinFreq > 100
        let g = gain
        let margin = marginDB
        // Compute sample counts from the ms settings each buffer — cheap and avoids
        // a separate "applied" tracking for these two values.
        let holdSamples = max(1, Int(Double(holdMs) / 1000.0 * inputSampleRate))
        let gateBlock   = max(1, Int(Double(gateBlockMs) / 1000.0 * inputSampleRate))

        scratch.removeAll(keepingCapacity: true)
        detScratch.removeAll(keepingCapacity: true)
        if scratch.capacity < n { scratch.reserveCapacity(n) }
        if detScratch.capacity < n { detScratch.reserveCapacity(n) }

        // Band-limit the whole buffer for LISTENING (filters must run continuously for
        // stability), and separately high-pass it for the gate DECISION. Both filter
        // chains run every sample so their state stays valid across buffers.
        for i in 0..<n {
            var x = channel[i]
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }
            let d = applyDetHP ? detHPb.process(detHPa.process(channel[i])) : channel[i]
            detScratch.append(d)

            // Per-sample noise gate/expander, sidechained off the detection-band
            // envelope: the block-level gate below decides WHEN to enqueue audio, but
            // a whole enqueued block still carries its between-call hiss at full level.
            // This knocks that hiss down (not to full silence, to avoid a choppy
            // digital-silence texture) while leaving loud call transients untouched,
            // so 8x time expansion doesn't also stretch the noise floor into an
            // audible hiss under the call.
            let mag = abs(d)
            let instDB = mag > 0 ? 20 * log10(mag) : -120
            let attack: Float = instDB > gateEnvDB ? 0.35 : 0.02
            gateEnvDB += attack * (instDB - gateEnvDB)
            let aboveFloor = gateEnvDB - noiseFloorDB
            let knee: Float = 6 // dB soft-knee width
            let floorGain: Float = 0.12 // -18 dB, not full mute — avoids abrupt cutoff
            let gateGain: Float
            if aboveFloor >= knee { gateGain = 1 }
            else if aboveFloor <= 0 { gateGain = floorGain }
            else { gateGain = floorGain + (1 - floorGain) * (aboveFloor / knee) }
            x *= gateGain

            scratch.append(x)
        }

        // Sub-buffer gate: scan short blocks, measure the detection-band RMS, and open
        // only when it rises `margin` dB above the rolling noise floor. Relative gating
        // catches quiet calls that a fixed threshold misses; the high-passed detection
        // signal keeps low-frequency handling noise from ever reaching the decision.
        // A sample-based hold keeps the queued audio close to the real call extent, so
        // 8× expansion doesn't fall behind on whole IO buffers.
        var i = 0
        while i < n {
            let end = min(i + gateBlock, n)
            let len = end - i
            var ss: Float = 0
            for j in i..<end { ss += detScratch[j] * detScratch[j] }
            let rms = sqrt(ss / Float(len))
            let db = rms > 0 ? 20 * log10(rms) : -120

            // Track the floor: fall fast toward a quieter block, rise slowly toward a
            // louder one. A brief call barely nudges it; sustained loudness lifts it,
            // which raises the effective threshold and bounds duty on dense passes.
            let alpha: Float = db < noiseFloorDB ? 0.2 : 0.002
            noiseFloorDB += alpha * (db - noiseFloorDB)

            if db >= noiseFloorDB + margin { holdSamplesRemaining = holdSamples }
            if holdSamplesRemaining > 0 {
                enqueue(scratch, range: i..<end, gain: g)
                holdSamplesRemaining = max(0, holdSamplesRemaining - len)
            }
            i = end
        }
    }

    private func enqueue(_ samples: [Float], range: Range<Int>, gain: Float) {
        let cap = ring.count
        var w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .acquiring)
        for k in range {
            let nextW = (w + 1) % cap
            if nextW == r { break } // full → drop remainder
            ring[w] = samples[k] * gain
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

        // If expansion has fallen too far behind real time (a sustained buzz),
        // skip ahead so we don't drift seconds late. We deliberately DON'T reset the
        // envelope here: the ring still has data, so the output should keep flowing.
        // Zeroing the envelope forced a full fade-out/fade-in at every skip, and under
        // a saturated ring (dense activity) skips fire constantly — that repeated
        // re-ramp WAS the popping. Jumping the read cursor alone leaves a single-sample
        // discontinuity, far less audible than a 4 ms gate cycle.
        if available > hardMax {
            r = (r + (available - hardMax)) % cap
            available = hardMax
        }

        // Per-sample soft gate: envelope ramps to 1 while ring has data, ramps to 0
        // when silent. lastSample is held during the ramp-down so we decay from the
        // real signal rather than cutting to 0 from a non-zero instantaneous value.
        for i in 0..<frames {
            if available > 0 {
                lastSample = ring[r]
                r = (r + 1) % cap
                available -= 1
                outputEnvelope = min(1, outputEnvelope + envelopeRate)
            } else {
                outputEnvelope = max(0, outputEnvelope - envelopeRate)
            }
            out[i] = lastSample * outputEnvelope
        }

        readIndexA.store(r, ordering: .releasing)
    }
}
