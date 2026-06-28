//
//  HeterodyneProcessor.swift
//  OpenBat
//
//  Classic heterodyne bat-detection: multiply the ultrasonic input by a local
//  oscillator (LO), low-pass the product to keep the difference frequency, and
//  decimate to an audible 48 kHz stream. With the LO parked just below the bat's
//  call frequency (see auto-tune in AudioEngineController), the call lands in the
//  audible band and you hear the characteristic warble.
//
//  Threading: `process(_:)` runs on the realtime capture thread (producer);
//  `render(_:frames:)` runs on the realtime output thread (consumer). They meet
//  through a *lock-free* single-producer/single-consumer ring buffer (atomic
//  indices) — a lock here let the two realtime threads block each other, which
//  caused periodic output clicks. `loFrequency`/`gain` are set from the main
//  thread and read under `ctrlLock`.
//

import AVFoundation
import Synchronization

nonisolated final class HeterodyneProcessor: @unchecked Sendable {

    let outputSampleRate: Double = 48_000

    // MARK: Control (main thread ↔ audio thread)

    private let ctrlLock = NSLock()
    private var _loFrequency: Double = 40_000
    private var _gain: Float = 6
    private var _bandLowFraction: Double = 0   // fraction of Nyquist
    private var _bandHighFraction: Double = 1

    /// Restrict heterodyne listening to a frequency band (fractions of Nyquist):
    /// high-pass at `low`, low-pass at `high`. So you only hear in-band calls.
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

    /// Local-oscillator frequency in Hz (the "tuning knob"). Set by auto-tune.
    var loFrequency: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _loFrequency }
        set { ctrlLock.lock(); _loFrequency = newValue; ctrlLock.unlock() }
    }

    /// Output makeup gain (mixing halves amplitude and bat signals are weak).
    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    // MARK: DSP state (capture thread only)

    private var inputSampleRate: Double = 384_000
    private var decimation = 8
    private var phase: Double = 0
    private var lp1 = Biquad()
    private var lp2 = Biquad()
    private var decimCounter = 0
    /// Reused output scratch so `process` doesn't allocate on the realtime thread.
    private var scratch = [Float]()

    // Input band-limit (4th-order high-pass + low-pass), applied before mixing so
    // only in-band ultrasound is heterodyned. Recomputed when the band changes.
    private var bandHPa = Biquad(), bandHPb = Biquad()
    private var bandLPa = Biquad(), bandLPb = Biquad()
    private var applyHP = false
    private var applyLP = false
    private var appliedLowFraction = -1.0
    private var appliedHighFraction = -1.0

    // MARK: Output ring buffer

    // Lock-free SPSC ring: the producer only advances `writeIndexA`, the consumer
    // only advances `readIndexA`. No lock → the two realtime threads never block
    // each other.
    private var ring = [Float](repeating: 0, count: 24_000) // ~0.5 s at 48 kHz
    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)
    private var readFrac = 0.0 // fractional read position (consumer only)
    // Latency control. The USB input and speaker output run on independent clocks,
    // so the queue slowly drifts. The consumer reads at a slightly varying
    // fractional rate (linear interpolation) to steer the queue toward
    // `softTarget` — inaudible. `hardMax` is a runaway safety net.
    private var softTarget = 2_880 // ~60 ms at 48 kHz
    private var hardMax = 12_000   // ~250 ms

    /// Reconfigure for a capture sample rate and reset all DSP/ring state. Call
    /// before installing the tap (no concurrent `process`/`render` at this point).
    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        decimation = max(1, Int((fs / outputSampleRate).rounded()))
        // Cutoff below the decimation Nyquist (24 kHz) — also the heterodyne LPF.
        let cutoff = min(9_000, outputSampleRate * 0.45)
        lp1 = .lowpass(cutoff: cutoff, sampleRate: fs)
        lp2 = .lowpass(cutoff: cutoff, sampleRate: fs)
        phase = 0
        decimCounter = 0
        let (low, high) = bandFractions()
        reconfigureBand(low: low, high: high)
        // Safe to reset directly: called before the tap starts, so neither
        // realtime thread is running yet.
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
        readFrac = 0
        softTarget = Int(outputSampleRate * 0.06)
        hardMax = Int(outputSampleRate * 0.25)
    }

    /// Rebuild the input band-limit filters for the given band (fractions of
    /// Nyquist). Runs on the capture thread (per buffer, only when the band
    /// changes) so the filter state stays single-threaded.
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

        let lo = loFrequency
        let g = gain
        let inc = 2 * Double.pi * lo / inputSampleRate
        var ph = phase
        var dc = decimCounter

        // Pick up band changes (cheap; only recomputes when the band moved).
        let (lowF, highF) = bandFractions()
        if lowF != appliedLowFraction || highF != appliedHighFraction {
            reconfigureBand(low: lowF, high: highF)
        }

        scratch.removeAll(keepingCapacity: true)
        if scratch.capacity < n / decimation + 1 {
            scratch.reserveCapacity(n / decimation + 1)
        }

        for i in 0..<n {
            // Band-limit the input so only in-band ultrasound is heterodyned.
            var x = channel[i]
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }

            let mixed = Float(Double(x) * cos(ph))
            ph += inc
            if ph >= 2 * Double.pi { ph -= 2 * Double.pi }

            let filtered = lp2.process(lp1.process(mixed))

            dc += 1
            if dc >= decimation {
                dc = 0
                scratch.append(filtered * g)
            }
        }

        phase = ph
        decimCounter = dc
        enqueue(scratch)
    }

    private func enqueue(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let cap = ring.count
        var w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .acquiring)
        for s in samples {
            let nextW = (w + 1) % cap
            if nextW == r { break } // full (consumer behind) → drop remainder; rare
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

        // Runaway safety: if we've fallen way behind, jump forward.
        if available > hardMax {
            r = (r + (available - softTarget)) % cap
            available = softTarget
        }

        // Steer the queue toward `softTarget` by reading slightly faster/slower
        // than real time. The adjustment is small and continuous (linear
        // interpolation), so it's inaudible — no sample drops, no ticks.
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
            for i in produced..<frames { out[i] = 0 } // underrun → silence
        }
    }
}
