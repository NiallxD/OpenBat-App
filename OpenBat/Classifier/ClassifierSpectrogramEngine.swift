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

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`STFTGrid` — stateless
/// DSP called only from `PulseDetector`'s capture queue, never the main actor, but
/// it carried no isolation annotation and so inherited
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The single-caller, single-queue
/// invariant its scratch state relies on is now stated rather than assumed.
nonisolated enum ClassifierSpectrogramEngine {

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
        // vDSP_HANN_DENORM (peak 1.0) matches torch.hann_window's convention exactly —
        // vDSP_HANN_NORM instead produces an energy-normalized window (peak ≈1.633,
        // i.e. sqrt(8/3)), which would silently rescale PCEN's input (see below).
        // Only used by .hann (BatDetect2 today); NABat uses .hamming and is unaffected.
        case .hann:    vDSP_hann_window(&w, vDSP_Length(count), Int32(vDSP_HANN_DENORM))
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

        // ── 1. STFT → power → dB, plus a parallel linear-magnitude copy for PCEN ──
        // PCEN (see applyPCEN) needs the raw linear magnitude, matching
        // torchaudio.transforms.Spectrogram(power=1) exactly — it must NOT run on the
        // dB values. Kept as a second array (rather than deriving dB from magnitude
        // later) so NABat's already-verified dB path is untouched bit-for-bit: `stft`
        // below keeps vDSP's raw (uncorrected) packed-real-FFT scale exactly as before
        // (NABat's QualityGate compares `amplitude` against an ABSOLUTE dB threshold,
        // and its SNR ratio is not invariant under a constant dB shift, so this scale
        // must not change). `linearMag` gets an extra ×0.5, confirmed empirically
        // against torchaudio's rfft convention (see batdetect2_conversion.md) —
        // vDSP's zrop packed-real FFT returns magnitudes exactly 2× a standard
        // single-sided rfft, which PCEN's fixed absolute constants (eps, bias) are
        // NOT invariant to the way minMax-normalized dB values are.
        // Only PCEN (BatDetect2) reads `linearMag` (see applyPCEN below) — NABat's
        // `.db` scaling never touches it, so skip the extra nBins*nFrames buffer and
        // per-sample sqrtf for that path.
        var needsLinearMag = false
        if case .pcen = spec.scaling { needsLinearMag = true }

        var stft = [Float](repeating: 0, count: nBins * nFrames)
        var linearMag = needsLinearMag ? [Float](repeating: 0, count: nBins * nFrames) : []

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
                    let powerVal = r * r + i * i
                    stft[bin * nFrames + frame] = 10.0 * log10f(max(powerVal, 1e-10))
                    if needsLinearMag { linearMag[bin * nFrames + frame] = 0.5 * sqrtf(powerVal) }
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
                for f in 0..<nFrames {
                    stft[base + f] = sentinelDB
                    if needsLinearMag { linearMag[base + f] = 0 }
                }
            }
        }
        if hiBin < nBins - 1 {
            for bin in (hiBin + 1)..<nBins {
                let base = bin * nFrames
                for f in 0..<nFrames {
                    stft[base + f] = sentinelDB
                    if needsLinearMag { linearMag[base + f] = 0 }
                }
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

        // ── 3. Scale (must run BEFORE denoise for BatDetect2: its real pipeline is
        // PCEN → spectral-mean-subtraction, in that order. For NABat (.db) this switch
        // is a no-op — dB was already computed in step 1 — so moving it here doesn't
        // change NABat's output at all.
        switch spec.scaling {
        case .db:
            break // already in dB from step 1

        case .pcen(let timeConstant, let gain, let bias, let power):
            applyPCEN(&stft, linearMag: linearMag, nBins: nBins, nFrames: nFrames,
                     sampleRate: spec.sampleRate,
                     timeConstant: timeConstant, gain: gain, bias: bias, power: power)
        }

        // ── 4. Denoise ────────────────────────────────────────────────────
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

        // ── 4b. Quality metrics on the denoised spec (pre-normalize) ─────
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

        case .none:
            break
        }

        // ── 6. Crop to [minFreqHz, maxFreqHz] and resize to output dims ──
        let topHz = spec.maxFreqHz
        let botHz = spec.minFreqHz
        let spanHz = topHz - botHz
        let outW = spec.outputWidth, outH = spec.outputHeight
        let channels = spec.channels

        var result = [Float](repeating: 0, count: outH * outW * channels)

        // `.nearest` (NABat): frequency (row) axis rounds to nearest bin centre, time
        // (col) axis floors to the containing frame, and row 0 = TOP of the image =
        // highest frequency. These conventions are asymmetric on purpose — they match
        // the reference implementation's pcolormesh mapping exactly and must stay that
        // way for NABat parity.
        func binFracNearest(forRow row: Int) -> Float {
            let freq = topHz - (Float(row) + 0.5) / Float(outH) * spanHz
            return freq / hzPerBin
        }
        func frameFracNearest(forCol col: Int) -> Float {
            (Float(col) + 0.5) / Float(outW) * Float(nFrames)
        }

        // `.bilinear` (BatDetect2): the real pipeline physically crops the STFT to
        // [lowIndex, highIndex) bins BEFORE resizing that fixed-size tensor with
        // `torch.nn.functional.interpolate(..., align_corners=False)` — a genuinely
        // different algorithm from `.nearest`'s frequency-continuous sampling over the
        // full bin range, not just a different interpolation kernel. Two fidelity
        // points verified against the real pipeline (see batdetect2_conversion.md —
        // this fixed a correlation regression from ~0.99 pre-resize to ~0.71 when this
        // block still reused `.nearest`'s conventions):
        //  1. Row 0 = LOWEST frequency in the cropped band (the raw STFT/tensor's
        //     natural bin order, top-to-bottom in frequency — NOT flipped like
        //     `.nearest`, since nothing in the real pipeline flips the frequency axis).
        //  2. Both axes use torch's align_corners=False source-coordinate formula,
        //     `src = (dst + 0.5) * (srcSize / dstSize) - 0.5`, not the naive
        //     `(dst + 0.5) / dstSize * srcSize` `.nearest` uses.
        // bin = freq * nFFT / sampleRate = freq / (sampleRate/2) * nBins — the mapping
        // that actually matches `stft`'s layout (nBins = nFFT/2 entries, 0..<nBins).
        let lowIndex = Int((botHz * 2 / Float(spec.sampleRate) * Float(nBins)).rounded(.down))
        let highIndex = Int((topHz * 2 / Float(spec.sampleRate) * Float(nBins)).rounded(.down))
        let croppedBinCount = max(1, highIndex - lowIndex)

        func torchAlignCornersFalseSrc(dst: Int, dstSize: Int, srcSize: Int) -> Float {
            (Float(dst) + 0.5) * (Float(srcSize) / Float(dstSize)) - 0.5
        }

        func sampleValue(row: Int, col: Int) -> Float {
            switch spec.resize {
            case .nearest:
                let binF = binFracNearest(forRow: row)
                let frameF = frameFracNearest(forCol: col)
                let bin = max(0, min(nBins - 1, Int(binF.rounded())))
                let frame = max(0, min(nFrames - 1, Int(frameF.rounded(.down))))
                return stft[bin * nFrames + frame]

            case .bilinear:
                let binC = torchAlignCornersFalseSrc(dst: row, dstSize: outH, srcSize: croppedBinCount)
                let frameC = torchAlignCornersFalseSrc(dst: col, dstSize: outW, srcSize: nFrames)
                let b0 = max(0, min(croppedBinCount - 1, Int(binC.rounded(.down))))
                let b1 = max(0, min(croppedBinCount - 1, b0 + 1))
                let f0 = max(0, min(nFrames - 1, Int(frameC.rounded(.down))))
                let f1 = max(0, min(nFrames - 1, f0 + 1))
                let tb = max(0, min(1, binC - Float(b0))), tf = max(0, min(1, frameC - Float(f0)))
                // b0/b1 index into the CROPPED range — offset by lowIndex to reach the
                // true (uncropped) bin in `stft`, whose natural order is unflipped.
                let bin0 = max(0, min(nBins - 1, lowIndex + b0))
                let bin1 = max(0, min(nBins - 1, lowIndex + b1))
                let v00 = stft[bin0 * nFrames + f0], v01 = stft[bin0 * nFrames + f1]
                let v10 = stft[bin1 * nFrames + f0], v11 = stft[bin1 * nFrames + f1]
                let top = v00 + (v01 - v00) * tf
                let bot = v10 + (v11 - v10) * tf
                return top + (bot - top) * tb
            }
        }

        for row in 0..<outH {
            for col in 0..<outW {
                let value = sampleValue(row: row, col: col)
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

    /// Median of `buf[0..<count]`, computed in place.
    ///
    /// This used to allocate a fresh array and fully sort it, which undid the
    /// careful copy into a reusable scratch buffer its callers make and cost an
    /// allocation plus an O(n log n) sort per row AND per column — 393 of each for
    /// a single NABat pulse. A partial selection finds the median in O(n) without
    /// allocating, and the caller's buffer is scratch that is refilled before every
    /// use, so reordering it is free.
    ///
    /// `buf` is genuinely `inout` now: quickselect permutes it.
    private static func sortedMedian(_ buf: inout [Float], count: Int) -> Float {
        guard count > 0 else { return 0 }
        return buf.withUnsafeMutableBufferPointer { p -> Float in
            let base = p.baseAddress!
            if count % 2 == 1 {
                return select(base, count: count, k: count / 2)
            }
            // Even count: the upper of the two middles, then the max of what sits
            // below it — which quickselect has already partitioned to the left, so
            // this is a scan of the lower half rather than a second selection.
            let hi = select(base, count: count, k: count / 2)
            var lo = base[0]
            for i in 1..<(count / 2) where base[i] > lo { lo = base[i] }
            return (lo + hi) * 0.5
        }
    }

    /// Hoare-partition quickselect: returns the value that would sit at index `k`
    /// if the buffer were sorted, leaving everything below `k` to its left.
    /// Median-of-three pivoting keeps the already-sorted and constant runs common
    /// in a spectrogram row off quickselect's O(n²) path.
    private static func select(_ base: UnsafeMutablePointer<Float>, count: Int, k: Int) -> Float {
        func exchange(_ a: Int, _ b: Int) {
            let t = base[a]; base[a] = base[b]; base[b] = t
        }
        var lo = 0, hi = count - 1
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if base[mid] < base[lo] { exchange(mid, lo) }
            if base[hi] < base[lo] { exchange(hi, lo) }
            if base[hi] < base[mid] { exchange(hi, mid) }
            let pivot = base[mid]
            var i = lo, j = hi
            while i <= j {
                while base[i] < pivot { i += 1 }
                while base[j] > pivot { j -= 1 }
                if i <= j {
                    exchange(i, j)
                    i += 1
                    j -= 1
                }
            }
            if k <= j { hi = j } else if k >= i { lo = i } else { return base[k] }
        }
        return base[k]
    }

    /// PCEN exactly matching `batdetect2.preprocess.audio.PCEN` — runs on the LINEAR
    /// magnitude STFT (`linearMag`), writing its result into `stft` (replacing whatever
    /// was there, e.g. dB values from step 1) for the denoise/normalize/resize steps
    /// that follow. Two intentional fidelity points, both load-bearing:
    ///
    /// 1. The smoothing constant is derived from a FIXED hop of 512 samples and
    ///    `sampleRate / 10`, regardless of the STFT's actual `hop` — a legacy
    ///    compatibility quirk in the reference implementation (it originally used
    ///    `librosa.pcen(sr=samplerate/10, hop_length=512)`), not a mistake to "fix".
    /// 2. The AGC/compression formula has no final `- bias**power` term — the
    ///    reference implementation omits it (unlike some textbook PCEN formulations).
    private static func applyPCEN(_ stft: inout [Float], linearMag: [Float],
                                   nBins: Int, nFrames: Int, sampleRate: Double,
                                   timeConstant: Float, gain: Float, bias: Float, power: Float) {
        let referenceHop: Float = 512
        let referenceRate = Float(sampleRate) / 10
        let t = timeConstant * referenceRate / referenceHop
        let s = t > 0 ? (sqrtf(1 + 4 * t * t) - 1) / (2 * t * t) : 1
        let eps: Float = 1e-6
        let scale: Float = Float(1 << 31)
        let biasPow = powf(bias, power)

        var m = [Float](repeating: 0, count: nFrames)
        for bin in 0..<nBins {
            let base = bin * nFrames
            // Zero-history initial condition, matching torchaudio.functional.lfilter's
            // default (x[-1] = y[-1] = 0): m[0] = s·S[0] + (1-s)·0, NOT S[0] directly.
            // With s this small (~0.05 at BatDetect2's defaults), a wrong initial value
            // decays as (1-s)^n and corrupts ~100+ frames — verified against the real
            // pipeline's PCEN output (see batdetect2_conversion.md): this one-line fix
            // took bin-for-bin correlation from ~0.001 to ~0.99.
            var acc: Float = max(0, s * linearMag[base] * scale)
            m[0] = acc
            for f in 1..<nFrames {
                let S = linearMag[base + f] * scale
                acc = max(0, (1 - s) * acc + s * S)
                m[f] = acc
            }
            for f in 0..<nFrames {
                let S = linearMag[base + f] * scale
                let smooth = expf(-gain * (logf(eps) + log1pf(m[f] / eps)))
                stft[base + f] = biasPow * expm1f(power * log1pf(S * smooth / bias))
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
