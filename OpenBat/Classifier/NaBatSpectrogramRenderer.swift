//
//  NaBatSpectrogramRenderer.swift
//  OpenBat
//
//  Replicates nabat-ml spectrogram_v2.py's _process_window() + make_training_spectrogram()
//  in Swift/vDSP, producing the same 100×100 spectrogram the NABat CNN expects.
//
//  Parameters exactly match the Python code:
//    n_fft  = int(0.001 * 384000) = 384   (Hamming window)
//    hop    = n_fft / 4            = 96
//    bandpass: 5 kHz < f < 100 kHz  (zeroed outside)
//    denoise: subtract row median, subtract col median, clip to 0
//    normalize: [0,1] using data min/max (mirrors matplotlib's auto-norm)
//    colormap: MAGMA. The model was trained on make_training_spectrogram() output,
//      which calls librosa.display.specshow() with no explicit cmap. librosa's default
//      for non-negative (sequential) data is magma — NOT viridis. Feeding viridis RGB
//      to a magma-trained CNN produces near-random, diffuse predictions (the cause of
//      the runaway LANO bias). Keep this in sync with librosa's magma default.
//    output: 100×100×3 float32 in [0,1], layout [height][width][RGB]
//

import Accelerate
import Foundation

enum NaBatSpectrogramRenderer {

    // ── NABat FFT parameters ─────────────────────────────────────────────────
    static let nFFT = 384                        // = int(0.001 * 384000)
    static let hop  = 96                         // = nFFT / 4
    // Freq resolution at 384 kHz: 384000/384 = 1000 Hz/bin
    // Bandpass: bins where f > 5000 Hz and f < 100000 Hz → bins 6..99

    static let outW = 100
    static let outH = 100

    /// Image plus the quality metrics the nabat-ml detector uses to gate pulses
    /// (`_process_window` in spectrogram_v2.py). Computed on the denoised dB spec
    /// exactly as the reference: verified to match the notebook's stored
    /// `Metadata.amplitude` / `.snr` / `.time` to within 0.3 on real recordings.
    struct RenderOutput {
        let image: [Float]            // outH × outW × 3, values in [0,1]
        let amplitude: Float          // peak-bin value at peak time, denoised dB
        let snr: Float                // peak-row mean (±5 cols) ÷ whole-window mean
        let peakTimeFraction: Float   // 0–1 position of the peak across the window
    }

    // ── One-time setup ───────────────────────────────────────────────────────

    // 384 = 3 × 2^7 — satisfies vDSP_DFT_zrop_CreateSetup constraints (f×2^n, f∈{1,3,5,15}).
    private static let dftSetup: vDSP_DFT_Setup = {
        guard let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD) else {
            fatalError("NaBatSpectrogramRenderer: DFT setup failed for n=\(nFFT)")
        }
        return s
    }()

    private static let hammingWindow: [Float] = {
        var w = [Float](repeating: 0, count: nFFT)
        vDSP_hamm_window(&w, vDSP_Length(nFFT), 0)
        return w
    }()

    // ── Public entry point ───────────────────────────────────────────────────

    /// Convert 50 ms of raw PCM (19 200 samples @ 384 kHz) into the 100×100×3
    /// float32 array the NABat CoreML model expects (values in [0,1]).
    /// Layout: result[row * 100 * 3 + col * 3 + channel], row 0 = top = high freq.
    /// Returns nil if `pcm` is shorter than one FFT window.
    static func render(pcm: [Float], sampleRate: Double = 384_000) -> RenderOutput? {
        guard pcm.count >= nFFT else { return nil }

        let nBins = nFFT / 2        // 192

        // Center-pad to match librosa default (n_fft//2 zeros each side).
        let pad     = nFFT / 2      // 192
        let padded  = [Float](repeating: 0, count: pad) + pcm + [Float](repeating: 0, count: pad)
        let nFrames = 1 + (padded.count - nFFT) / hop  // ≈201 for 19200 input samples

        // ── 1. STFT → power → dB ─────────────────────────────────────────
        // stft[bin * nFrames + frame]
        var stft = [Float](repeating: 0, count: nBins * nFrames)

        var realIn  = [Float](repeating: 0, count: nFFT / 2)
        var imagIn  = [Float](repeating: 0, count: nFFT / 2)
        var realOut = [Float](repeating: 0, count: nFFT / 2)
        var imagOut = [Float](repeating: 0, count: nFFT / 2)
        var windowed = [Float](repeating: 0, count: nFFT)

        padded.withUnsafeBufferPointer { pBuf in
            for frame in 0..<nFrames {
                let start = frame * hop
                // Apply Hamming window
                vDSP_vmul(pBuf.baseAddress! + start, 1, hammingWindow, 1,
                          &windowed, 1, vDSP_Length(nFFT))
                // Deinterleave: even samples → realIn, odd → imagIn (vDSP_DFT_zrop input format)
                for j in 0..<(nFFT / 2) {
                    realIn[j] = windowed[2 * j]
                    imagIn[j] = windowed[2 * j + 1]
                }
                // Execute DFT (real-to-complex, out-of-place)
                vDSP_DFT_Execute(dftSetup, realIn, imagIn, &realOut, &imagOut)
                // Power → dB  (10 * log10(r² + i²), amin = 1e-10 matches librosa)
                // Note: for bin 0, imagOut[0] holds the Nyquist component (DC has no imaginary
                // part); both are outside the bandpass and will be zeroed in step 2.
                for bin in 0..<nBins {
                    let r = realOut[bin], i = imagOut[bin]
                    stft[bin * nFrames + frame] = 10.0 * log10f(max(r * r + i * i, 1e-10))
                }
            }
        }

        // ── 2. Bandpass: zero bins ≤ 5 kHz or ≥ 100 kHz ─────────────────
        // At 1000 Hz/bin: bin ≤ 5 → ≤5000 Hz, bin ≥ 100 → ≥100000 Hz.
        // Python also gates against sr/2 - 2000 = 190 kHz but 100 < 190 so irrelevant.
        let sentinelDB: Float = -500
        for bin in 0...5 {
            let base = bin * nFrames
            for f in 0..<nFrames { stft[base + f] = sentinelDB }
        }
        for bin in 100..<nBins {
            let base = bin * nFrames
            for f in 0..<nFrames { stft[base + f] = sentinelDB }
        }

        // ── 2b. Peak (loudest bin/time) on the bandpassed dB spec, BEFORE denoise.
        // Mirrors np.unravel_index(stft.argmax()) in _process_window — used for the
        // quality-gate amplitude/SNR/peak-time below.
        var peakBin = 6, peakFrame = 0
        var peakDB = -Float.greatestFiniteMagnitude
        for bin in 6..<100 {
            let base = bin * nFrames
            for f in 0..<nFrames where stft[base + f] > peakDB {
                peakDB = stft[base + f]; peakBin = bin; peakFrame = f
            }
        }
        let peakTimeFraction = nFrames > 1 ? Float(peakFrame) / Float(nFrames - 1) : 0.5

        // ── 3. Denoise: subtract row median, subtract col median, clip ≥ 0 ─
        var tmp = [Float](repeating: 0, count: max(nBins, nFrames))

        // Row medians (each row = one frequency bin, columns = time frames)
        for bin in 0..<nBins {
            let base = bin * nFrames
            tmp.withUnsafeMutableBytes { ptr in
                stft.withUnsafeBytes { src in
                    ptr.copyMemory(from: UnsafeRawBufferPointer(
                        start: src.baseAddress!.advanced(by: base * MemoryLayout<Float>.stride),
                        count: nFrames * MemoryLayout<Float>.stride))
                }
            }
            let med = sortedMedian(&tmp, count: nFrames)
            for f in 0..<nFrames { stft[base + f] -= med }
        }

        // Column medians (each column = one time frame, rows = frequency bins)
        var colBuf = [Float](repeating: 0, count: nBins)
        for frame in 0..<nFrames {
            for bin in 0..<nBins { colBuf[bin] = stft[bin * nFrames + frame] }
            let med = sortedMedian(&colBuf, count: nBins)
            for bin in 0..<nBins { stft[bin * nFrames + frame] -= med }
        }

        // Clip negatives to 0
        var zero: Float = 0
        vDSP_vthres(stft, 1, &zero, &stft, 1, vDSP_Length(stft.count))

        // ── 3b. Quality metrics on the denoised+clipped spec (pre-normalize) ─
        // amplitude = denoised peak-bin value at peak time.
        // snr = mean of the peak row over ±5 cols around the peak ÷ whole-window mean.
        // (matches _process_window: rsig over [t-4, t+6), r_other = full-spec mean.)
        let peakRowBase = peakBin * nFrames
        let amplitude = stft[peakRowBase + peakFrame]
        var wholeMean: Float = 0
        vDSP_meanv(stft, 1, &wholeMean, vDSP_Length(stft.count))
        var rsig: Float = 0
        let lo = max(0, peakFrame - 4), hi = min(nFrames, peakFrame + 6)
        for f in lo..<hi { rsig += stft[peakRowBase + f] }
        rsig /= 10
        let snr = wholeMean > 0 ? rsig / wholeMean : 0

        // ── 4. Normalize [0, 1] (mirrors matplotlib specshow auto-norm) ───
        var minVal: Float = 0, maxVal: Float = 0
        vDSP_minv(stft, 1, &minVal, vDSP_Length(stft.count))
        vDSP_maxv(stft, 1, &maxVal, vDSP_Length(stft.count))
        let range = max(maxVal - minVal, 1e-6)
        var negMin = -minVal, invRange = 1.0 / range
        vDSP_vsadd(stft, 1, &negMin,    &stft, 1, vDSP_Length(stft.count))
        vDSP_vsmul(stft, 1, &invRange,  &stft, 1, vDSP_Length(stft.count))

        // ── 5. Crop to ylim(5000, 100000) and resize to 100×100 via NEAREST sampling ─
        // The training images come from matplotlib `specshow` (a pcolormesh QuadMesh),
        // which is piecewise-constant: each output pixel takes the value of the single
        // data cell it falls in — NOT bilinear interpolation. Bilinear smears the call
        // contour and the CNN (trained on the sharper pcolormesh texture) flips close
        // calls. Verified against the nabat-ml notebook: nearest sampling reproduces the
        // notebook's per-pulse scores almost exactly (17/18 winner agreement on a 384 kHz
        // field recording); bilinear only matched 10/18. Keep this nearest-neighbour.
        //
        // Mapping (matches specshow + ax.set_ylim(5000,100000), pixel-centre sampled):
        //   freq(row) = 100 kHz − (row+0.5)/outH · 95 kHz ; bin = round(freq / hzPerBin)
        //   frame(col) = floor((col+0.5)/outW · nFrames)
        // Row 0 = top = 100 kHz, row outH-1 = bottom = 5 kHz.
        let hzPerBin: Float = Float(sampleRate) / Float(nFFT)   // 1000 Hz/bin at 384 kHz
        let topHz: Float = 100_000
        let botHz: Float = 5_000
        let spanHz = topHz - botHz

        var result = [Float](repeating: 0, count: outH * outW * 3)

        for row in 0..<outH {
            let freq = topHz - (Float(row) + 0.5) / Float(outH) * spanHz
            let bin  = max(0, min(nBins - 1, Int((freq / hzPerBin).rounded())))
            let binBase = bin * nFrames

            for col in 0..<outW {
                let frame = max(0, min(nFrames - 1,
                                       Int((Float(col) + 0.5) / Float(outW) * Float(nFrames))))
                let (r, g, b) = magma(stft[binBase + frame])
                let idx = (row * outW + col) * 3
                result[idx]     = r
                result[idx + 1] = g
                result[idx + 2] = b
            }
        }

        return RenderOutput(image: result,
                            amplitude: amplitude,
                            snr: snr,
                            peakTimeFraction: peakTimeFraction)
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static func sortedMedian(_ buf: inout [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        var tmp = Array(buf.prefix(count))
        tmp.sort()
        return count % 2 == 1 ? tmp[count / 2] : (tmp[count / 2 - 1] + tmp[count / 2]) * 0.5
    }

    // Magma colormap — 17 key stops sampled from matplotlib's `magma` (linear interpolation).
    // This MUST match the colormap the NABat model was trained on (librosa specshow default
    // for non-negative data). See header note.
    private static func magma(_ t: Float) -> (Float, Float, Float) {
        let t = min(max(t, 0), 1)
        typealias RGB = (Float, Float, Float)
        let stops: [(Float, RGB)] = [
            (0.0000, (0.001462, 0.000466, 0.013866)),
            (0.0625, (0.039608, 0.031090, 0.133515)),
            (0.1250, (0.113094, 0.065492, 0.276784)),
            (0.1875, (0.211718, 0.061992, 0.418647)),
            (0.2500, (0.316654, 0.071690, 0.485380)),
            (0.3125, (0.414709, 0.110431, 0.504662)),
            (0.3750, (0.512831, 0.148179, 0.507648)),
            (0.4375, (0.613617, 0.181811, 0.498536)),
            (0.5000, (0.716387, 0.214982, 0.475290)),
            (0.5625, (0.816914, 0.255895, 0.436461)),
            (0.6250, (0.904281, 0.319610, 0.388137)),
            (0.6875, (0.960949, 0.418323, 0.359630)),
            (0.7500, (0.986700, 0.535582, 0.382210)),
            (0.8125, (0.996096, 0.653659, 0.446213)),
            (0.8750, (0.996898, 0.769591, 0.534892)),
            (0.9375, (0.992440, 0.884330, 0.640099)),
            (1.0000, (0.987053, 0.991438, 0.749504)),
        ]
        for i in 0..<stops.count - 1 {
            let (t0, c0) = stops[i]
            let (t1, c1) = stops[i + 1]
            if t <= t1 {
                let f = (t - t0) / (t1 - t0)
                return (c0.0 + (c1.0 - c0.0) * f,
                        c0.1 + (c1.1 - c0.1) * f,
                        c0.2 + (c1.2 - c0.2) * f)
            }
        }
        return stops.last!.1
    }
}
