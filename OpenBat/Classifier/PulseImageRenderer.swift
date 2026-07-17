//
//  PulseImageRenderer.swift
//  OpenBat
//
//  High-resolution spectrogram render of a single captured pulse, used by the
//  Pulse View panel and the Sessions history thumbnails.
//
//  The live display HistoryBuffer is coarse (fftSize 1024 / hop 512 → 750
//  columns/sec), so a zoom window is only a handful of columns wide and looks
//  blurry once upscaled. This renderer instead works directly from the captured
//  raw PCM at high resolution:
//
//    • A 512-sample Hann window (1.33 ms — fine time resolution for FM sweeps)
//      is zero-padded to a 1024-point FFT, doubling the frequency bins to 187 Hz
//      each without sacrificing time resolution (interpolated, sharper display).
//    • A 32-sample hop → 12 000 columns/sec, so even a 10 ms window is ~120
//      columns wide before the display upscales it.
//
//  It also LOCKS the pulse's energy onset (−12 dB envelope start) to a fixed
//  fraction from the left, so successive captures pin the call to the same spot
//  regardless of trigger loudness or capture timing. Runs on a background queue
//  (no main-actor / @Observable access).
//

import Accelerate
import UIKit

enum PulseImageRenderer {

    // ── High-resolution STFT parameters (zoom view only) ─────────────────────
    static let windowLen = 512               // Hann analysis window (samples)
    static let fftLen    = 1024              // zero-padded FFT size
    static let hop       = 32                // 12 000 cols/sec @ 384 kHz
    static var binCount: Int { fftLen / 2 }  // 512

    /// Dynamic range (dB below the window peak) mapped onto the colormap. 48 dB
    /// gives crisp contrast on a bat call while still showing harmonic structure.
    private static let dynamicRangeDB: Float = 48

    struct Result {
        let image: UIImage
        let freqMin: Double      // Hz — low edge of the call band (the DEFAULT view's crop)
        let freqMax: Double      // Hz — high edge of the call band (the DEFAULT view's crop)
        /// Hz bounds of the actually-rendered image, which covers the full allowed
        /// band (not just the tight call crop above) so the pulse view can
        /// pinch-zoom OUT from the default crop to reveal surrounding spectral
        /// context, instead of being capped at the crop's own edges.
        let wideFreqMin: Double
        let wideFreqMax: Double
        /// Where the DEFAULT (tight) time window sits within the wider rendered
        /// image, as a 0…1 fraction of the image's width — lets the pulse view pan
        /// left/right into the extra captured context on either side of the call,
        /// the same way `wideFreqMin`/`wideFreqMax` let it zoom out in frequency.
        let timeTightLeftFrac: Double
        let timeTightRightFrac: Double
        let peakFreq: Double     // Hz — dominant frequency
        let durationMs: Double   // call length from the −12 dB energy envelope
        /// Tight crop for stored thumbnails / the pass-detail sheet: just the
        /// call band vertically (plus the same small margin the default view
        /// uses) and a few ms either side of the call horizontally — so saved
        /// pulses aren't a speck in a mostly-black full-spectrum frame. The
        /// bounds below let the UI draw labelled frequency/time axes on it.
        let cleanImage: UIImage?
        let cleanFreqMinHz: Double
        let cleanFreqMaxHz: Double
        let cleanSpanMs: Double
        /// 0–1 pulse quality score. Measures how much the loudest column stands
        /// above the mean — high (>0.5) for a clean concentrated bat call, low
        /// (<0.2) for broadband noise or echo where all columns are elevated.
        let quality: Float
    }

    // 1024 = 2^10 — radix-2 real FFT (window is zero-padded up to this length).
    private static let log2n = vDSP_Length(10)
    private static let fftSetup: FFTSetup = {
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("PulseImageRenderer: FFT setup failed")
        }
        return s
    }()
    private static let hannWindow: [Float] = {
        var w = [Float](repeating: 0, count: windowLen)
        vDSP_hann_window(&w, vDSP_Length(windowLen), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Render `pcm` (raw samples at `sampleRate`) into a sharp pulse spectrogram.
    ///
    /// The captured buffer is deliberately WIDER than the displayed span: this
    /// renderer finds the call's energy onset within it and crops a fixed-width
    /// `displaySpanSeconds` window with that onset at `onsetFraction` from the left,
    /// so every capture pins the pulse to the same spot (the dashed line in the UI).
    ///
    /// - `noiseFloor` (0–1) gates faint background energy and stretches the rest to
    ///   full contrast.
    /// - `minFrequencyHz` bounds the call-band search so low-frequency rumble never
    ///   defines the displayed frequency range.
    /// - `expectedOnsetSample` is the onset's approximate index in `pcm` (from the
    ///   detector); the envelope search is confined near it so a neighbouring call or
    ///   echo elsewhere in the wide buffer can't capture the lock.
    static func render(pcm: [Float],
                       sampleRate: Double,
                       noiseFloor: Float,
                       minFrequencyHz: Double,
                       displaySpanSeconds: Double,
                       onsetFraction: Double,
                       expectedOnsetSample: Int,
                       palette: Palette = .inferno) -> Result? {
        guard pcm.count >= windowLen else { return nil }

        let bins    = binCount
        let nFrames = 1 + (pcm.count - windowLen) / hop
        guard nFrames >= 2 else { return nil }

        // ── 1. STFT → magnitude → dB, row-major [bin * nFrames + frame] ──────
        //  A `windowLen` Hann window is copied into a zero-padded `fftLen` buffer,
        //  so the FFT interpolates to `bins` frequency points at full time res.
        var dB = [Float](repeating: 0, count: bins * nFrames)
        var windowed = [Float](repeating: 0, count: fftLen)   // tail stays zero (pad)
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var mags  = [Float](repeating: 0, count: bins)
        let scale: Float = 1.0 / Float(fftLen)

        pcm.withUnsafeBufferPointer { pBuf in
            for frame in 0..<nFrames {
                let start = frame * hop
                vDSP_vmul(pBuf.baseAddress! + start, 1, hannWindow, 1,
                          &windowed, 1, vDSP_Length(windowLen))
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

        // ── 2b. Output geometry + search region ─────────────────────────────
        //  The displayed window is a fixed span. We find the call within a region
        //  around the detector's expected onset (so a neighbouring call/echo elsewhere
        //  in the wide capture can't hijack the lock), then crop that span with the
        //  call's onset placed at `onsetFraction`.
        let outFrames   = max(8, Int(displaySpanSeconds * sampleRate / Double(hop)))
        let onsetOutCol = min(max(Int(onsetFraction * Double(outFrames)), 0), outFrames - 1)
        let expectedFrame = min(max(expectedOnsetSample / hop, 0), nFrames - 1)
        let searchLo = max(0, expectedFrame - outFrames / 2)
        let searchHi = min(nFrames, expectedFrame + outFrames + outFrames / 2)

        // Column energy envelope (loudest in-band bin per column).
        func columnPeak(_ col: Int) -> Float {
            var m: Float = 0
            for bin in minBinAllowed..<bins {
                let v = norm[bin * nFrames + col]
                if v > m { m = v }
            }
            return m
        }

        // ── 3. Peak (dominant freq + loudest column) within the search region ──
        var peakValue: Float = 0
        var peakBin = minBinAllowed
        var peakCol = searchLo, peakColVal: Float = 0
        var totalColPeak: Float = 0
        for col in searchLo..<searchHi {
            var colMax: Float = 0
            for bin in minBinAllowed..<bins {
                let v = norm[bin * nFrames + col]
                if v > colMax { colMax = v }
                if v > peakValue { peakValue = v; peakBin = bin }
            }
            totalColPeak += colMax
            if colMax > peakColVal { peakColVal = colMax; peakCol = col }
        }

        // ── 4. Noise gate + contrast stretch ────────────────────────────────
        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // ── 5. Duration from the −12 dB energy envelope around the loudest col ──
        let durThreshold = max(floor, peakColVal - 12.0 / dynamicRangeDB)
        var durStart = peakCol, durEnd = peakCol
        while durStart - 1 >= searchLo,     columnPeak(durStart - 1) >= durThreshold { durStart -= 1 }
        while durEnd + 1 < searchHi,        columnPeak(durEnd + 1)   >= durThreshold { durEnd += 1 }
        let durationCols = durEnd - durStart + 1
        let secondsPerCol = Double(hop) / sampleRate

        // ── 6. Frequency extent of the call, over its active columns only ────
        //  Scanning just [durStart, durEnd] keeps quiet inter-call frames from
        //  widening the band — so the crop hugs the call, "just above and below".
        let freqThreshold = max(floor, peakValue - 15.0 / dynamicRangeDB)
        var minBin = bins - 1, maxBin = minBinAllowed
        for bin in minBinAllowed..<bins {
            let base = bin * nFrames
            for col in durStart...durEnd where norm[base + col] >= freqThreshold {
                if bin < minBin { minBin = bin }
                if bin > maxBin { maxBin = bin }
                break
            }
        }
        if minBin > maxBin { minBin = minBinAllowed; maxBin = bins - 1 }

        // Quality: how much the peak column stands above the region's background mean.
        let regionCols = max(1, searchHi - searchLo)
        let meanColPeak = totalColPeak / Float(regionCols)
        let quality: Float = peakColVal > 0 ? 1.0 - (meanColPeak / peakColVal) : 0

        // ── 7. Tight crop (for the DEFAULT view + stats) vs. the wider RENDERED
        //  image (for pinch-zoom-out + pan headroom) ──────────────────────────
        //  Time: output col j samples source frame (durStart − onsetOutCol + j); off
        //  the ends renders as background so the onset lands exactly on the line.
        let binBuf  = max(4, (maxBin - minBin + 1) / 8)
        let tightMin = max(minBinAllowed, minBin - binBuf)
        let tightMax = min(bins - 1, maxBin + binBuf)

        // The image covers the FULL spectrum (bin 1 up to Nyquist) — NOT gated by
        // `minFrequencyHz`, which is a call-detection threshold (rejects wind/
        // handling rumble from the search above), not a display floor. Using it as
        // the render floor too was why pinch-zoom-out used to bottom out at
        // whatever the trigger's minimum frequency was set to (15 kHz default)
        // instead of reaching true full spectrum. Cheap either way: this
        // renderer's bin count is small (fftLen/2 = 512) and already runs off the
        // main thread.
        let renderMin = 1
        let renderMax = bins - 1
        let renderBins = renderMax - renderMin + 1

        // Time: render extra margin around what's displayed by default, so panning
        // has real captured content to reveal instead of hitting black past the
        // tight crop's own edges. More margin on the RIGHT than the left — the
        // call's content runs rightward from the onset (locked at `onsetFraction`
        // from the tight window's own left edge), and PulseDetector captures more
        // trailing than leading context (trail = 2 spans vs. lead = 1 span around
        // the onset) — so a symmetric pad left the call feeling pinned against the
        // right edge once zoomed out to full height, with barely any breathing
        // room on that side. Bounded by what was actually captured; short of that,
        // out-of-range columns render as background same as the tight crop does.
        let srcStart = durStart - onsetOutCol   // tight window's left edge (unchanged reference)
        let padLeft = outFrames
        let padRight = outFrames * 2
        let wideOutFrames = padLeft + outFrames + padRight
        let wideSrcStart = srcStart - padLeft

        var pixels = [UInt8](repeating: 255, count: wideOutFrames * renderBins * 4)
        for bin in renderMin...renderMax {
            let yFlipped = renderMax - bin     // row 0 = top = high freq
            let base = bin * nFrames
            for j in 0..<wideOutFrames {
                let srcFrame = wideSrcStart + j
                let v: Float = (srcFrame >= 0 && srcFrame < nFrames) ? norm[base + srcFrame] : 0
                let (r, g, b) = DisplayColormap.rgb(gate(v), palette: palette)
                let idx = (yFlipped * wideOutFrames + j) * 4
                pixels[idx]     = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let cgImage = CGImage(
                width: wideOutFrames, height: renderBins,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: wideOutFrames * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }

        // Clean crop off the same pixel buffer: rows = the tight call band
        // (tightMin/tightMax already carry the binBuf margin, i.e. "just above /
        // just below" the call), columns = the call's active span padded by a
        // few ms each side. CGImage rows run top-down, row 0 = renderMax.
        let cleanPadCols = Int(0.003 / secondsPerCol)        // ~3 ms each side
        let cleanX0 = max(0, (durStart - cleanPadCols) - wideSrcStart)
        let cleanX1 = min(wideOutFrames - 1, (durEnd + cleanPadCols) - wideSrcStart)
        let cleanRect = CGRect(x: cleanX0, y: renderMax - tightMax,
                               width: cleanX1 - cleanX0 + 1,
                               height: tightMax - tightMin + 1)
        let cleanCG = cgImage.cropping(to: cleanRect)

        return Result(
            image: UIImage(cgImage: cgImage),
            freqMin: Double(tightMin) * hzPerBin,
            freqMax: Double(tightMax) * hzPerBin,
            wideFreqMin: Double(renderMin) * hzPerBin,
            wideFreqMax: Double(renderMax) * hzPerBin,
            timeTightLeftFrac: Double(padLeft) / Double(wideOutFrames),
            timeTightRightFrac: Double(padLeft + outFrames) / Double(wideOutFrames),
            peakFreq: Double(peakBin) * hzPerBin,
            durationMs: Double(durationCols) * secondsPerCol * 1000,
            cleanImage: cleanCG.map { UIImage(cgImage: $0) },
            cleanFreqMinHz: Double(tightMin) * hzPerBin,
            cleanFreqMaxHz: Double(tightMax) * hzPerBin,
            cleanSpanMs: Double(cleanX1 - cleanX0 + 1) * secondsPerCol * 1000,
            quality: quality
        )
    }
}
