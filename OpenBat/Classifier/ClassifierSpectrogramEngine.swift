//
//  ClassifierSpectrogramEngine.swift
//  OpenBat
//
//  Config-driven STFT → denoise → normalize → resize → colorize pipeline, shared by
//  every classifier's spectrogram renderer. Each model renderer (e.g.
//  NaBatSpectrogramRenderer) supplies a SpectrogramRenderSpec and gets back the image
//  tensor plus generic pulse-quality metrics (amplitude/SNR/peak time), computed the
//  same way regardless of spec — a model that doesn't need a quality gate can just
//  ignore them (see QualityGate.disabled).
//

import Accelerate
import Foundation

enum ClassifierSpectrogramEngine {

    struct RenderOutput {
        let image: [Float]            // outH × outW × channels, values in [0,1]
        let channels: Int
        let amplitude: Float          // peak-bin value at peak time, post-denoise
        let snr: Float                // peak-row mean (±5 cols) ÷ whole-window mean
        let peakTimeFraction: Float   // 0–1 position of the peak across the window
    }

    // DFT setups are keyed by nFFT so multiple specs (different models) can share the
    // engine without recreating vDSP state on every call.
    private static var dftSetups: [Int: vDSP_DFT_Setup] = [:]
    private static let dftSetupsLock = NSLock()

    private static func dftSetup(nFFT: Int) -> vDSP_DFT_Setup {
        dftSetupsLock.lock()
        defer { dftSetupsLock.unlock() }
        if let existing = dftSetups[nFFT] { return existing }
        guard let s = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(nFFT), .FORWARD) else {
            fatalError("ClassifierSpectrogramEngine: DFT setup failed for n=\(nFFT)")
        }
        dftSetups[nFFT] = s
        return s
    }

    private static func windowTable(_ fn: SpectrogramWindowFunction, count: Int) -> [Float] {
        var w = [Float](repeating: 0, count: count)
        switch fn {
        case .hamming: vDSP_hamm_window(&w, vDSP_Length(count), 0)
        case .hann:    vDSP_hann_window(&w, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        }
        return w
    }

    /// Render `pcm` per `spec`. Returns nil if `pcm` is shorter than one FFT window.
    static func render(pcm: [Float], spec: SpectrogramRenderSpec) -> RenderOutput? {
        let nFFT = spec.nFFT
        let hop = spec.hop
        guard pcm.count >= nFFT else { return nil }

        let nBins = nFFT / 2
        let pad = nFFT / 2
        let padded = [Float](repeating: 0, count: pad) + pcm + [Float](repeating: 0, count: pad)
        let nFrames = 1 + (padded.count - nFFT) / hop

        // ── 1. STFT → power → dB ─────────────────────────────────────────
        var stft = [Float](repeating: 0, count: nBins * nFrames)

        let setup = dftSetup(nFFT: nFFT)
        let window = windowTable(spec.window, count: nFFT)
        var realIn  = [Float](repeating: 0, count: nFFT / 2)
        var imagIn  = [Float](repeating: 0, count: nFFT / 2)
        var realOut = [Float](repeating: 0, count: nFFT / 2)
        var imagOut = [Float](repeating: 0, count: nFFT / 2)
        var windowed = [Float](repeating: 0, count: nFFT)

        padded.withUnsafeBufferPointer { pBuf in
            for frame in 0..<nFrames {
                let start = frame * hop
                vDSP_vmul(pBuf.baseAddress! + start, 1, window, 1,
                          &windowed, 1, vDSP_Length(nFFT))
                for j in 0..<(nFFT / 2) {
                    realIn[j] = windowed[2 * j]
                    imagIn[j] = windowed[2 * j + 1]
                }
                vDSP_DFT_Execute(setup, realIn, imagIn, &realOut, &imagOut)
                for bin in 0..<nBins {
                    let r = realOut[bin], i = imagOut[bin]
                    stft[bin * nFrames + frame] = 10.0 * log10f(max(r * r + i * i, 1e-10))
                }
            }
        }

        // ── 2. Bandpass: zero bins outside [minFreqHz, maxFreqHz] ────────
        // Strict inequality on both ends (bin*hzPerBin must be > minFreqHz and <
        // maxFreqHz), matching the original NABat bandpass semantics exactly.
        let hzPerBin = Float(spec.sampleRate) / Float(nFFT)
        let loBin = max(0, Int((spec.minFreqHz / hzPerBin).rounded(.down)) + 1)
        let hiBin = min(nBins - 1, Int((spec.maxFreqHz / hzPerBin).rounded(.up)) - 1)
        let sentinelDB: Float = -500
        if loBin > 0 {
            for bin in 0..<loBin {
                let base = bin * nFrames
                for f in 0..<nFrames { stft[base + f] = sentinelDB }
            }
        }
        if hiBin < nBins - 1 {
            for bin in (hiBin + 1)..<nBins {
                let base = bin * nFrames
                for f in 0..<nFrames { stft[base + f] = sentinelDB }
            }
        }

        // ── 2b. Peak (loudest bin/time) on the bandpassed dB spec, before denoise —
        // generic pulse-quality metrics, independent of denoise/scaling mode.
        var peakBin = loBin, peakFrame = 0
        var peakDB = -Float.greatestFiniteMagnitude
        for bin in loBin...hiBin {
            let base = bin * nFrames
            for f in 0..<nFrames where stft[base + f] > peakDB {
                peakDB = stft[base + f]; peakBin = bin; peakFrame = f
            }
        }
        let peakTimeFraction = nFrames > 1 ? Float(peakFrame) / Float(nFrames - 1) : 0.5

        // ── 3. Denoise ────────────────────────────────────────────────────
        switch spec.denoise {
        case .none:
            break

        case .rowThenColumnMedian:
            var tmp = [Float](repeating: 0, count: max(nBins, nFrames))
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
            var colBuf = [Float](repeating: 0, count: nBins)
            for frame in 0..<nFrames {
                for bin in 0..<nBins { colBuf[bin] = stft[bin * nFrames + frame] }
                let med = sortedMedian(&colBuf, count: nBins)
                for bin in 0..<nBins { stft[bin * nFrames + frame] -= med }
            }
            var zero: Float = 0
            vDSP_vthres(stft, 1, &zero, &stft, 1, vDSP_Length(stft.count))

        case .spectralMeanSubtraction:
            var rowBuf = [Float](repeating: 0, count: nFrames)
            for bin in 0..<nBins {
                let base = bin * nFrames
                for f in 0..<nFrames { rowBuf[f] = stft[base + f] }
                var mean: Float = 0
                vDSP_meanv(rowBuf, 1, &mean, vDSP_Length(nFrames))
                for f in 0..<nFrames { stft[base + f] -= mean }
            }
            var zero: Float = 0
            vDSP_vthres(stft, 1, &zero, &stft, 1, vDSP_Length(stft.count))
        }

        // ── 3b. Quality metrics on the denoised spec (pre-normalize) ─────
        let peakRowBase = peakBin * nFrames
        let amplitude = stft[peakRowBase + peakFrame]
        var wholeMean: Float = 0
        vDSP_meanv(stft, 1, &wholeMean, vDSP_Length(stft.count))
        // Nominal window size (10 = ±5 cols) matches the reference exactly, including
        // its behavior of NOT renormalizing when the window clips near an edge.
        var rsig: Float = 0
        let lo = max(0, peakFrame - 4), hi = min(nFrames, peakFrame + 6)
        for f in lo..<hi { rsig += stft[peakRowBase + f] }
        rsig /= 10
        let snr = wholeMean > 0 ? rsig / wholeMean : 0

        // ── 4. Scale (PCEN happens on the raw power domain — applied here as an
        // alternative to the dB conversion in step 1 would require restructuring;
        // since dB is already computed above, PCEN mode instead runs a per-row AGC
        // directly on the dB-domain values, which is what step 5's normalize expects.)
        switch spec.scaling {
        case .db:
            break // already in dB from step 1

        case .pcen(let timeConstant, let gain, let bias, let power):
            applyPCEN(&stft, nBins: nBins, nFrames: nFrames,
                     hop: hop, sampleRate: spec.sampleRate,
                     timeConstant: timeConstant, gain: gain, bias: bias, power: power)
        }

        // ── 5. Normalize ──────────────────────────────────────────────────
        switch spec.normalize {
        case .minMax:
            var minVal: Float = 0, maxVal: Float = 0
            vDSP_minv(stft, 1, &minVal, vDSP_Length(stft.count))
            vDSP_maxv(stft, 1, &maxVal, vDSP_Length(stft.count))
            let range = max(maxVal - minVal, 1e-6)
            var negMin = -minVal, invRange = 1.0 / range
            vDSP_vsadd(stft, 1, &negMin,    &stft, 1, vDSP_Length(stft.count))
            vDSP_vsmul(stft, 1, &invRange,  &stft, 1, vDSP_Length(stft.count))

        case .peak:
            var peakAbs: Float = 0
            vDSP_maxmgv(stft, 1, &peakAbs, vDSP_Length(stft.count))
            let inv = peakAbs > 0 ? 1 / peakAbs : 1
            var invVar = inv
            vDSP_vsmul(stft, 1, &invVar, &stft, 1, vDSP_Length(stft.count))
        }

        // ── 6. Crop to [minFreqHz, maxFreqHz] and resize to output dims ──
        let topHz = spec.maxFreqHz
        let botHz = spec.minFreqHz
        let spanHz = topHz - botHz
        let outW = spec.outputWidth, outH = spec.outputHeight
        let channels = spec.channels

        var result = [Float](repeating: 0, count: outH * outW * channels)

        // Frequency (row) axis: `round` to nearest bin centre. Time (col) axis: `floor`
        // to the containing frame. These conventions are asymmetric on purpose — they
        // match the reference implementation's pcolormesh mapping exactly (round for
        // bin, floor for frame) and must stay that way for NABat parity.
        func binFrac(forRow row: Int) -> Float {
            let freq = topHz - (Float(row) + 0.5) / Float(outH) * spanHz
            return freq / hzPerBin
        }
        func frameFrac(forCol col: Int) -> Float {
            (Float(col) + 0.5) / Float(outW) * Float(nFrames)
        }

        func sampleValue(binF: Float, frameF: Float) -> Float {
            switch spec.resize {
            case .nearest:
                let bin = max(0, min(nBins - 1, Int(binF.rounded())))
                let frame = max(0, min(nFrames - 1, Int(frameF.rounded(.down))))
                return stft[bin * nFrames + frame]
            case .bilinear:
                // Continuous pixel-centre convention for interpolation (no parity
                // constraint here — bilinear is new, used only by non-NABat models).
                let binC = binF - 0.5, frameC = frameF - 0.5
                let b0 = max(0, min(nBins - 1, Int(binC.rounded(.down))))
                let b1 = max(0, min(nBins - 1, b0 + 1))
                let f0 = max(0, min(nFrames - 1, Int(frameC.rounded(.down))))
                let f1 = max(0, min(nFrames - 1, f0 + 1))
                let tb = binC - Float(b0), tf = frameC - Float(f0)
                let v00 = stft[b0 * nFrames + f0], v01 = stft[b0 * nFrames + f1]
                let v10 = stft[b1 * nFrames + f0], v11 = stft[b1 * nFrames + f1]
                let top = v00 + (v01 - v00) * tf
                let bot = v10 + (v11 - v10) * tf
                return top + (bot - top) * tb
            }
        }

        for row in 0..<outH {
            let binF = binFrac(forRow: row)
            for col in 0..<outW {
                let frameF = frameFrac(forCol: col)
                let value = sampleValue(binF: binF, frameF: frameF)
                let idx = (row * outW + col) * channels
                switch spec.color {
                case .colormap(let map):
                    let (r, g, b) = colorize(value, map: map)
                    result[idx] = r; result[idx + 1] = g; result[idx + 2] = b
                case .grayscale:
                    result[idx] = value
                }
            }
        }

        return RenderOutput(image: result, channels: channels,
                            amplitude: amplitude, snr: snr,
                            peakTimeFraction: peakTimeFraction)
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private static func sortedMedian(_ buf: inout [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        var tmp = Array(buf.prefix(count))
        tmp.sort()
        return count % 2 == 1 ? tmp[count / 2] : (tmp[count / 2 - 1] + tmp[count / 2]) * 0.5
    }

    /// Standard PCEN (Wang et al. / librosa): per frequency bin, smooth the (already
    /// dB-converted — see call site note) energy with a one-pole IIR filter, then apply
    /// the gain/bias/power AGC curve. `timeConstant` sets the smoothing coefficient the
    /// same way librosa derives it from `time_constant` and the frame hop.
    private static func applyPCEN(_ stft: inout [Float], nBins: Int, nFrames: Int,
                                   hop: Int, sampleRate: Double,
                                   timeConstant: Float, gain: Float, bias: Float, power: Float) {
        let framesPerSecond = Float(sampleRate) / Float(hop)
        let t = timeConstant * framesPerSecond
        let s = t > 0 ? (sqrtf(1 + 4 * t * t) - 1) / (2 * t * t) : 1
        var smoothed = [Float](repeating: 0, count: nFrames)
        for bin in 0..<nBins {
            let base = bin * nFrames
            var m = stft[base]
            smoothed[0] = m
            for f in 1..<nFrames {
                m = (1 - s) * m + s * stft[base + f]
                smoothed[f] = m
            }
            for f in 0..<nFrames {
                let denom = powf(bias + smoothed[f], gain)
                stft[base + f] = powf(stft[base + f] / denom + bias, power) - powf(bias, power)
            }
        }
    }

    // Magma colormap — 17 key stops sampled from matplotlib's `magma` (linear interpolation).
    private static func colorize(_ t: Float, map: SpectrogramColormap) -> (Float, Float, Float) {
        switch map {
        case .magma: return magma(t)
        }
    }

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
