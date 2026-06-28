//
//  PulseImageRenderer.swift
//  OpenBat
//
//  High-resolution spectrogram render of a single captured pulse, used by the
//  Pulse View panel and the Sessions history thumbnails.
//
//  The live display HistoryBuffer is coarse (fftSize 1024 / hop 512 → 750
//  columns/sec), so an 80 ms zoom window is only ~60 columns wide and looks
//  blurry once upscaled. This renderer instead works directly from the captured
//  raw PCM with a much finer hop (fftSize 512 / hop 64 → 6000 columns/sec), so
//  an 80 ms window is ~480 columns — genuinely more detail, not just a smoother
//  upscale. Runs on a background queue (no main-actor / @Observable access).
//

import Accelerate
import UIKit

enum PulseImageRenderer {

    // ── High-resolution STFT parameters (zoom view only) ─────────────────────
    static let fftSize = 512
    static let hop     = 64
    static var binCount: Int { fftSize / 2 }   // 256

    /// Dynamic range (dB below the window peak) mapped onto the colormap.
    private static let dynamicRangeDB: Float = 55

    struct Result {
        let image: UIImage
        let freqMin: Double      // Hz — low edge of the call band
        let freqMax: Double      // Hz — high edge of the call band
        let peakFreq: Double     // Hz — dominant frequency
        let durationMs: Double   // call length from the −12 dB energy envelope
    }

    // 512 = 2^9 — radix-2 real FFT.
    private static let log2n = vDSP_Length(9)
    private static let fftSetup: FFTSetup = {
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("PulseImageRenderer: FFT setup failed")
        }
        return s
    }()
    private static let hannWindow: [Float] = {
        var w = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&w, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Render `pcm` (raw samples at `sampleRate`) into a sharp pulse spectrogram.
    /// `noiseFloor` (0–1) gates faint background energy and stretches the rest to
    /// full contrast — matches the live spectrogram / old pulse view behaviour.
    /// `minFrequencyHz` bounds the call-band search so low-frequency rumble below
    /// the detector's trigger band never defines the displayed frequency range.
    static func render(pcm: [Float],
                       sampleRate: Double,
                       noiseFloor: Float,
                       minFrequencyHz: Double) -> Result? {
        guard pcm.count >= fftSize else { return nil }

        let bins    = binCount
        let nFrames = 1 + (pcm.count - fftSize) / hop
        guard nFrames >= 2 else { return nil }

        // ── 1. STFT → magnitude → dB, row-major [bin * nFrames + frame] ──────
        var dB = [Float](repeating: 0, count: bins * nFrames)
        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var mags  = [Float](repeating: 0, count: bins)
        let scale: Float = 1.0 / Float(fftSize)

        pcm.withUnsafeBufferPointer { pBuf in
            for frame in 0..<nFrames {
                let start = frame * hop
                vDSP_vmul(pBuf.baseAddress! + start, 1, hannWindow, 1,
                          &windowed, 1, vDSP_Length(fftSize))
                windowed.withUnsafeBufferPointer { wBuf in
                    wBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cplx in
                        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
                        vDSP_ctoz(cplx, 2, &split, 1, vDSP_Length(bins))
                        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                    }
                }
                var s = scale
                vDSP_vsmul(mags, 1, &s, &mags, 1, vDSP_Length(bins))
                for bin in 0..<bins {
                    dB[bin * nFrames + frame] = 20.0 * log10f(max(mags[bin], 1e-9))
                }
            }
        }

        // ── 2. Normalize to [0,1] over [peakDB − dynamicRange, peakDB] ───────
        var maxDB: Float = -.greatestFiniteMagnitude
        vDSP_maxv(dB, 1, &maxDB, vDSP_Length(dB.count))
        let minDB = maxDB - dynamicRangeDB
        var negMin = -minDB
        var inv = 1.0 / dynamicRangeDB
        vDSP_vsadd(dB, 1, &negMin, &dB, 1, vDSP_Length(dB.count))
        vDSP_vsmul(dB, 1, &inv,    &dB, 1, vDSP_Length(dB.count))
        var lo: Float = 0, hi: Float = 1
        vDSP_vclip(dB, 1, &lo, &hi, &dB, 1, vDSP_Length(dB.count))   // → norm in [0,1]
        let norm = dB

        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBinAllowed = max(1, Int(minFrequencyHz / hzPerBin))

        // ── 3. Peak (dominant freq) across the whole window, above min freq ──
        var peakValue: Float = 0
        var peakBin = minBinAllowed
        for bin in minBinAllowed..<bins {
            let base = bin * nFrames
            for col in 0..<nFrames {
                let v = norm[base + col]
                if v > peakValue { peakValue = v; peakBin = bin }
            }
        }

        // ── 4. Noise gate + contrast stretch ────────────────────────────────
        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // ── 5. Frequency extent of the call (−15 dB below peak ≈ 0.27 in norm) ──
        let freqThreshold = max(floor, peakValue - 15.0 / dynamicRangeDB)
        var minBin = bins - 1, maxBin = minBinAllowed
        for bin in minBinAllowed..<bins {
            let base = bin * nFrames
            for col in 0..<nFrames where norm[base + col] >= freqThreshold {
                if bin < minBin { minBin = bin }
                if bin > maxBin { maxBin = bin }
                break
            }
        }
        if minBin > maxBin { minBin = minBinAllowed; maxBin = bins - 1 }

        // ── 6. Duration from the −12 dB energy envelope around the loudest col ──
        func columnPeak(_ col: Int) -> Float {
            var m: Float = 0
            for bin in minBinAllowed..<bins {
                let v = norm[bin * nFrames + col]
                if v > m { m = v }
            }
            return m
        }
        var peakCol = 0, peakColVal: Float = 0
        for col in 0..<nFrames {
            let m = columnPeak(col)
            if m > peakColVal { peakColVal = m; peakCol = col }
        }
        let durThreshold = max(floor, peakColVal - 12.0 / dynamicRangeDB)
        var durStart = peakCol, durEnd = peakCol
        while durStart - 1 >= 0,      columnPeak(durStart - 1) >= durThreshold { durStart -= 1 }
        while durEnd + 1 < nFrames,   columnPeak(durEnd + 1)   >= durThreshold { durEnd += 1 }
        let durationCols = durEnd - durStart + 1
        let secondsPerCol = Double(hop) / sampleRate

        // ── 7. Crop to the call band (with padding) and rasterize ───────────
        let binBuf  = max(6, (maxBin - minBin + 1) / 4)
        let cropMin = max(minBinAllowed, minBin - binBuf)
        let cropMax = min(bins - 1, maxBin + binBuf)
        let cropBins = cropMax - cropMin + 1

        var pixels = [UInt8](repeating: 255, count: nFrames * cropBins * 4)
        for bin in cropMin...cropMax {
            let yFlipped = cropMax - bin       // row 0 = top = high freq
            let base = bin * nFrames
            for col in 0..<nFrames {
                let (r, g, b) = InfernoColormap.rgb(gate(norm[base + col]))
                let idx = (yFlipped * nFrames + col) * 4
                pixels[idx]     = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let cgImage = CGImage(
                width: nFrames, height: cropBins,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: nFrames * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        return Result(
            image: UIImage(cgImage: cgImage),
            freqMin: Double(cropMin) * hzPerBin,
            freqMax: Double(cropMax) * hzPerBin,
            peakFreq: Double(peakBin) * hzPerBin,
            durationMs: Double(durationCols) * secondsPerCol * 1000
        )
    }
}

/// Inferno colormap (mirrors `Spectrogram.metal` on the GPU). 6-stop piecewise
/// linear, shared by the pulse renderer and the captured-pulse thumbnails.
enum InfernoColormap {
    static func rgb(_ t: Float) -> (UInt8, UInt8, UInt8) {
        let t = min(max(t, 0), 1)
        typealias RGB = (Float, Float, Float)
        let stops: [(Float, RGB)] = [
            (0.0, (0.001, 0.000, 0.014)),
            (0.2, (0.215, 0.036, 0.405)),
            (0.4, (0.575, 0.149, 0.404)),
            (0.6, (0.868, 0.288, 0.245)),
            (0.8, (0.988, 0.645, 0.040)),
            (1.0, (0.988, 0.998, 0.645)),
        ]
        for i in 0..<stops.count - 1 {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            guard t <= t1 else { continue }
            let f = (t - t0) / (t1 - t0)
            return (UInt8((c0.0 * (1-f) + c1.0 * f) * 255),
                    UInt8((c0.1 * (1-f) + c1.1 * f) * 255),
                    UInt8((c0.2 * (1-f) + c1.2 * f) * 255))
        }
        return (252, 254, 164)
    }
}
