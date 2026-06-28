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
    /// Detection threshold in dBFS (band-limited RMS). Louder ⇒ call.
    private var _thresholdDB: Float = -50

    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    var thresholdDB: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _thresholdDB }
        set { ctrlLock.lock(); _thresholdDB = newValue; ctrlLock.unlock() }
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
    /// Samples still pushed after the level drops, to catch call tails / bridge dips.
    /// Sample-based (not buffer-based) so the queued audio tracks the actual call
    /// extent rather than whole 8 ms IO buffers — critical for keeping up at 8×.
    private var holdSamplesRemaining = 0
    private let holdSamples = 1536          // ~4 ms at 384 kHz
    private let gateBlock = 256             // RMS window for sub-buffer gating (~0.7 ms)
    private var scratch = [Float]()

    // MARK: Lock-free SPSC ring (push expanded call samples; silence between calls)

    private var ring = [Float](repeating: 0, count: 96_000) // ~2 s at 48 kHz
    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)
    private var hardMax = 24_000 // ~0.5 s of queued expansion before we skip ahead

    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        let (low, high) = bandFractions()
        reconfigureBand(low: low, high: high)
        holdSamplesRemaining = 0
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
        hardMax = Int(outputSampleRate * 0.5)
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

        let (lowF, highF) = bandFractions()
        if lowF != appliedLowFraction || highF != appliedHighFraction {
            reconfigureBand(low: lowF, high: highF)
        }
        let g = gain
        let threshold = thresholdDB

        scratch.removeAll(keepingCapacity: true)
        if scratch.capacity < n { scratch.reserveCapacity(n) }

        // Band-limit the whole buffer (filters must run continuously for stability).
        for i in 0..<n {
            var x = channel[i]
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }
            scratch.append(x)
        }

        // Sub-buffer gate: scan short blocks and only queue those at/after a call,
        // with a sample-based hold. This keeps the queued audio close to the real
        // call extent, so 8× expansion doesn't fall behind on whole 8 ms buffers.
        var i = 0
        while i < n {
            let end = min(i + gateBlock, n)
            let len = end - i
            var ss: Float = 0
            for j in i..<end { ss += scratch[j] * scratch[j] }
            let rms = sqrt(ss / Float(len))
            let db = rms > 0 ? 20 * log10(rms) : -120
            if db >= threshold { holdSamplesRemaining = holdSamples }
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
        // skip ahead so we don't drift seconds late.
        if available > hardMax {
            r = (r + (available - hardMax)) % cap
            available = hardMax
        }

        var produced = 0
        while produced < frames, available > 0 {
            out[produced] = ring[r]
            r = (r + 1) % cap
            available -= 1
            produced += 1
        }
        readIndexA.store(r, ordering: .releasing)

        if produced < frames {
            for i in produced..<frames { out[i] = 0 } // silence between calls
        }
    }
}
