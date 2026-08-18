//
//  PulseImageRenderer.swift
//  OpenBat
//
//  High-resolution spectrogram render of a single captured pulse, used by the
//  Pulse View panel and the Sessions history thumbnails.
//
//  The live display HistoryBuffer is coarse (fftSize 2048 / hop 256 → 1500
//  columns/sec), so a zoom window is only a handful of columns wide and looks
//  blurry once upscaled. This renderer instead works directly from the captured
//  raw PCM at high resolution:
//
//    • A 512-sample Hann window (1.33 ms — fine time resolution for FM sweeps)
//      is zero-padded to a 2048-point FFT, quadrupling the frequency bins to
//      187 Hz each without sacrificing time resolution (interpolated, sharper
//      display).
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

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`STFTGrid` — stateless
/// DSP called only from `PulseDetector`'s capture queue, never the main actor, but
/// it carried no isolation annotation and so inherited
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The single-caller, single-queue
/// invariant its scratch state relies on is now stated rather than assumed.
nonisolated enum PulseImageRenderer {

    // ── High-resolution STFT parameters (zoom view only) ─────────────────────
    // Mirrors of STFTGrid's own constants (the STFT loop itself now lives
    // there — see `STFTGrid.compute`, called from step 1-2 below) kept here
    // too since callers throughout this file reference them directly.
    static let windowLen = STFTGrid.windowLen
    static let fftLen    = STFTGrid.fftLen
    static let hop       = STFTGrid.hop
    static var binCount: Int { STFTGrid.binCount }

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

    // ── Scratch buffers reused across captures ───────────────────────────────
    //  `render` is only ever invoked from PulseDetector's serial captureQueue
    //  (gated by isCapturing), so one set of buffers can be recycled instead of
    //  reallocating ~4 MB per pulse. `sttfScratch` backs steps 1-2 (now
    //  STFTGrid.compute, below). It grows to the largest capture seen and is never
    //  shrunk; every used element is overwritten each call, so no zeroing is needed
    //  on reuse (windowed's zero-pad tail past windowLen is written once at
    //  allocation and never touched again — see STFTGrid.compute).
    //
    //  There was a `pixelScratch` here too, backing the RGBA buffer in step 7. It
    //  is gone: reusing it meant the finished pixels had to be COPIED into a `Data`
    //  for the CGDataProvider, so the reuse saved one 2 MB allocation and paid for
    //  it with one 2 MB memcpy. The buffer is now allocated per pulse and handed to
    //  the provider outright.
    private static var sttfScratch = STFTGrid.Scratch()

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
        let bins = binCount

        // ── 1-2. STFT → magnitude → dB, peak-normalized to [0,1], row-major
        //  [bin * nFrames + frame] — now shared with WavSpectrogramEngine via
        //  STFTGrid.compute (a `windowLen` Hann window zero-padded to `fftLen`,
        //  so the FFT interpolates to `bins` frequency points at full time res).
        guard let (norm, nFrames) = STFTGrid.compute(pcm: pcm, scratch: &Self.sttfScratch,
                                                      dynamicRangeDB: dynamicRangeDB)
        else { return nil }

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
        // instead of reaching true full spectrum.
        //
        // Note this is NOT cheap, which is what the comment here used to claim: it
        // said the bin count was 512, but `fftLen` is 2048 so it is 1024, and the
        // full-height image is ~490 000 pixels built one at a time to be displayed
        // at roughly 350×200 points. The full height is kept deliberately —
        // pinch-zoom-out reaching true full spectrum is a real feature — but the
        // cost is twice what the original reasoning assumed, so if this ever needs
        // to get cheaper, rendering lazily at the zoom level actually in use is
        // the thing to do, not clipping the range again.
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

        // One malloc handed straight to CoreGraphics, rather than filling a reused
        // scratch array and then copying the whole thing into a `Data` for the
        // provider. At ~490 000 pixels that copy was ~2 MB memcpy per captured
        // pulse, on the capture queue, several times a second during a busy pass —
        // and the allocation it was avoiding is one malloc. `releaseData` below
        // hands ownership to the provider, so this is not leaked.
        let pixelCount = wideOutFrames * renderBins
        let words = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
        // 256-entry table built once, O(1) lookup per pixel, instead of the
        // dictionary lookup + linear stop-search `DisplayColormap.rgb` does per
        // call. See `DisplayColormap.makeLUT`'s doc comment for the measurement
        // that motivated it: the same change took the offline recording renderer's
        // loop from 1.6–5.3 SECONDS to low tens of ms. Every other bulk pixel loop
        // in the app (RecordingSpectrogramRenderer, WavSpectrogramEngine) was
        // converted then; this one was missed, and it is on the hotter path — it
        // runs on every captured pulse, live, while detection continues.
        // Packed RGBA words rather than a (UInt8, UInt8, UInt8) tuple, so each pixel
        // is a single 32-bit store instead of four byte stores plus a constant alpha
        // write. Byte order: the bitmap below is premultipliedLast, i.e. R,G,B,A in
        // memory order, and this is little-endian, so R must occupy the low byte.
        let lut = DisplayColormap.makeLUT(palette: palette).map { rgb -> UInt32 in
            UInt32(rgb.0) | (UInt32(rgb.1) << 8) | (UInt32(rgb.2) << 16) | (0xFF << 24)
        }
        let lutMax = lut.count - 1
        let lutScale = Float(lutMax)
        lut.withUnsafeBufferPointer { lutBuf in
            for bin in renderMin...renderMax {
                let yFlipped = renderMax - bin     // row 0 = top = high freq
                let base = bin * nFrames
                let rowStart = yFlipped * wideOutFrames
                for j in 0..<wideOutFrames {
                    let srcFrame = wideSrcStart + j
                    let v: Float = (srcFrame >= 0 && srcFrame < nFrames) ? norm[base + srcFrame] : 0
                    words[rowStart + j] = lutBuf[min(lutMax, max(0, Int(gate(v) * lutScale)))]
                }
            }
        }

        // Constructed before the `guard` on purpose: once the provider exists it
        // owns `words` and frees it via `releaseData` (including when the CGImage
        // below fails and the provider is released unused). If the provider itself
        // can't be made, nothing has taken ownership yet, so free it here — that is
        // the one path that would otherwise leak 2 MB per pulse.
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: words,
            size: pixelCount * 4,
            releaseData: { _, data, _ in
                UnsafeMutableRawPointer(mutating: data)
                    .assumingMemoryBound(to: UInt32.self).deallocate()
            })
        else {
            words.deallocate()
            return nil
        }

        guard
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
