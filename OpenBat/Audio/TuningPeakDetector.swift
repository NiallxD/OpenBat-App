//
//  TuningPeakDetector.swift
//  OpenBat
//
//  The one measurement file playback needs from a spectrogram: which
//  frequency is loudest right now, so heterodyne can park its oscillator just
//  below it.
//
//  It used to get that by running the live Detector's entire
//  `SpectrogramProcessor` on the playback pacing thread — 1500 zero-padded
//  2048-point FFTs a second, a copy of every sample into a 15 MB PCM ring
//  under a lock, and ~1500 freshly allocated 1024-float display columns a
//  second (~6 MB/s of churn) — all of which were then drained and thrown
//  away, because nothing on the player's screen draws them. The WAV player
//  renders a static whole-file spectrogram from disk instead; a search of the
//  whole app for a second reader of that processor turns up none. So the most
//  expensive thing on the thread whose only job is to hand the audio path
//  samples on time existed to produce one `Double` (found 2026-09-01).
//
//  The analysis geometry here is deliberately identical to
//  `SpectrogramProcessor`'s — the same 512-sample Hann window, the same
//  2048-point zero-padded FFT, the same `peakMinFraction` band floor and the
//  same −55 dBFS confidence gate that `peakThreshold = 0.5` works out to on
//  its fixed −90/−20 dB scale. A frequency measured here therefore means
//  exactly what one measured there means, and auto-tune behaves the same on a
//  file as it does live.
//
//  What differs is the cadence: one window per tuning tick (~15 Hz, matching
//  the live path's stats timer) rather than one per 256-sample hop.
//
//  Threading: `nonisolated` and allocation-free after `init`, like every
//  other DSP type here. One instance is single-threaded — it holds scratch —
//  so give each caller its own.
//

import Accelerate

nonisolated final class TuningPeakDetector {

    /// Raw samples per measurement, Hann-windowed. Matches
    /// `SpectrogramProcessor.windowLen`.
    static let windowLen = 512
    /// Zero-padded FFT length — matches `SpectrogramProcessor.fftSize`, which
    /// is what makes a bin index here mean the same frequency as one there.
    private static let fftSize = 2048
    private static let binCount = fftSize / 2

    /// The same fixed detection scale `SpectrogramProcessor` uses for
    /// triggering and auto-tune (deliberately not the adaptive display
    /// contrast), collapsed into the one number it actually implies: a peak
    /// must reach this many dBFS to count as a confident detection.
    /// `minDB = −90`, `maxDB = −20`, `peakThreshold = 0.5` → −90 + 0.5 × 70.
    private static let confidenceFloorDB: Float = -55

    /// Keeps the search off the very lowest bins, where rumble lives — the
    /// same fraction-of-Nyquist floor `SpectrogramProcessor.peakMinFraction`
    /// defaults to.
    private static let minBinFraction = 0.05

    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var window: [Float]

    // Scratch, sized once and never resized.
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var magnitudes: [Float]

    init() {
        log2n = vDSP_Length(log2(Double(Self.fftSize)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("TuningPeakDetector: FFT setup failed")
        }
        setup = s
        window = [Float](repeating: 0, count: Self.windowLen)
        vDSP_hann_window(&window, vDSP_Length(Self.windowLen), Int32(vDSP_HANN_NORM))
        // Only the first `windowLen` entries are ever written, so the tail
        // stays zero for every transform — that tail IS the zero padding.
        windowed = [Float](repeating: 0, count: Self.fftSize)
        realp = [Float](repeating: 0, count: Self.binCount)
        imagp = [Float](repeating: 0, count: Self.binCount)
        magnitudes = [Float](repeating: 0, count: Self.binCount)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// How far apart the analysis windows are when scanning a block. Matches
    /// `SpectrogramProcessor.hopSize`, so the recording is examined at exactly
    /// the density the live Detector examines its own input at.
    ///
    /// **Scanning the whole block, rather than one window of it, is the
    /// difference between hearing bat calls and missing them.** A single
    /// window per tuning tick is 1.33 ms of every 66.7 ms — a 2% duty cycle,
    /// which a 3 ms call clears about one time in sixteen. That is what
    /// "heterodyne is really insensitive in playback, most calls don't
    /// trigger it" was (Niall, 2026-09-01): not a stricter threshold, just
    /// barely looking. The code it replaced evaluated a peak once per fed
    /// buffer — every ~2 ms — and caught nearly everything.
    private static let scanHop = 256

    /// The strongest confident peak anywhere in `x`, in Hz.
    ///
    /// Returns 0 when there is audio to measure but nothing in the band is
    /// loud enough to be worth tuning to — the same sentinel
    /// `SpectrogramProcessor.frequency(forBin:level:)` returns, and what the
    /// squelch gate reads as "no call here".
    ///
    /// Returns nil when there is not a full window to measure, which is a
    /// different thing entirely: it means this block had nothing to say, not
    /// that the recording went quiet. A caller must not let that close the
    /// gate — playing the tail of a short kept region would otherwise mute
    /// the start of the next one.
    func strongestPeak(_ x: UnsafePointer<Float>, count: Int, sampleRate: Double) -> Double? {
        guard count >= Self.windowLen, sampleRate > 0 else { return nil }
        var bestDB = -Float.greatestFiniteMagnitude
        var bestBin = 0
        var offset = 0
        while offset + Self.windowLen <= count {
            let (db, bin) = measure(x + offset)
            if db > bestDB { bestDB = db; bestBin = bin }
            offset += Self.scanHop
        }
        guard bestDB >= Self.confidenceFloorDB else { return 0 }
        return Double(bestBin) * sampleRate / Double(Self.fftSize)
    }

    /// One window's loudest in-band bin, and its level in dBFS.
    private func measure(_ start: UnsafePointer<Float>) -> (db: Float, bin: Int) {
        vDSP_vmul(start, 1, window, 1, &windowed, 1, vDSP_Length(Self.windowLen))
        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let interleaved = raw.bindMemory(to: DSPComplex.self).baseAddress!
                    vDSP_ctoz(interleaved, 2, &split, 1, vDSP_Length(Self.binCount))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(Self.binCount))
            }
        }

        // Same normalisation `SpectrogramProcessor.makeColumn` applies before
        // its dB conversion, so `confidenceFloorDB` is comparable.
        var scale = 1.0 / Float(Self.fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(Self.binCount))

        // Bin 0 is DC and Nyquist packed together, not a bin pair — the live
        // trigger scan skips it and so does this. Everything below
        // `minBinFraction` goes with it.
        let minBin = max(1, Int(Double(Self.binCount) * Self.minBinFraction))
        guard minBin < Self.binCount else { return (-.greatestFiniteMagnitude, 0) }
        var peak: Float = 0
        var peakIndex: vDSP_Length = 0
        magnitudes.withUnsafeBufferPointer { m in
            vDSP_maxvi(m.baseAddress! + minBin, 1, &peak, &peakIndex,
                       vDSP_Length(Self.binCount - minBin))
        }
        return (20 * log10(max(peak, 1e-9)), minBin + Int(peakIndex))
    }
}
