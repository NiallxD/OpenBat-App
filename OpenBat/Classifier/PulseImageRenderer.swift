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
//    • A 128-sample hop → 3 000 columns/sec, so a 10 ms window is ~30 columns
//      wide before the display upscales it. This was 32 samples (12 000/sec)
//      until 2026-09-07: four times the columns, four times the cost, and that
//      cost is what stopped the detector keeping up with a calling bat. See
//      `displayHop` for what the coarser spacing does and does not affect.
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

    /// Frame spacing used for the pulse view's own spectrogram, coarser than the
    /// shared native `hop`.
    ///
    /// The transform's cost is linear in the frame count, and this was the single
    /// biggest cost in the capture pipeline: 345 frames per pulse, measured at
    /// 129 ms uncontended on an iPad Air 4 (2026-09-07), against a capture queue
    /// that has ~230 ms per pulse to keep up with a real bat. At 128 samples the
    /// frame count drops four-fold.
    ///
    /// **What it costs is time resolution on two numbers, and nothing else.** A
    /// call's measured start and end land on a frame boundary, so duration
    /// quantises to 0.33 ms instead of 0.083 ms — against calls of 2–16 ms, and
    /// against displays that round it to 0.1 ms anyway. The recording itself is
    /// untouched by any of this: the WAV is written straight from the audio
    /// stream and carries the full detail for anyone who wants to measure
    /// properly. Frequency resolution is set by the window and the FFT size, and
    /// neither changes here.
    ///
    /// **128 was arrived at by looking, not by arithmetic.** The column count
    /// falls with the hop and the columns are the picture: a 10 ms view is 30
    /// columns here, about 12 points per column on screen, which the numbers say
    /// should look blocky. It was shipped at 64 first for exactly that reason,
    /// and Niall's answer on seeing 128 was that the images look fine — the
    /// display's own interpolation covers it. Do not "restore" this from the
    /// pixel count alone; if it needs to come back it should be because a person
    /// looked at a call and could not read its shape.
    static let displayHop = 128
    static var binCount: Int { STFTGrid.binCount }

    /// Dynamic range (dB below the window peak) mapped onto the colormap. 48 dB
    /// gives crisp contrast on a bat call while still showing harmonic structure.
    private static let dynamicRangeDB: Float = 48

    struct Result {
        /// `nil` when the caller asked for measurements only (`makeImage: false`).
        /// Everything else in this type is still filled: the analysis that produces
        /// peak frequency, duration, band and quality runs either way, and it is
        /// the pixel buffer — ~490 000 pixels, ~2 MB — that is skipped.
        let image: UIImage?
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
        /// Milliseconds spent in `STFTGrid.compute` alone, so a caller timing the
        /// whole render can say how much of it was the transform and how much was
        /// everything after. Added because the render's cost turned out to be
        /// identical in Debug and Release — which rules out the Swift scans and
        /// leaves the transform, but only measurement can say so.
        let stftMs: Double
        /// Frames the transform produced — the render's actual workload, which
        /// scales with the display span and was otherwise unknowable from a log.
        let stftFrames: Int
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
    /// Runs one render on synthetic audio of the size the detector actually
    /// captures, and reports what it cost with nothing else competing.
    ///
    /// The point is the comparison, not the number. A live render's wall clock
    /// includes whatever else the device was doing; this one is measured on a
    /// quiet queue before capture starts. If the live figure is several times
    /// this, the render is being descheduled and the DSP is not the problem —
    /// which is the question two rounds of per-pulse timing could not answer,
    /// because every one of those measurements was taken under load.
    static func benchmark(sampleRate: Double = 384_000,
                          displaySpanSeconds: Double) -> (wallMs: Double, cpuMs: Double, frames: Int) {
        let span = max(fftLen + displayHop, Int(displaySpanSeconds * sampleRate))
        let count = span * 3                       // lead + display + trail, as captured
        var rng = SystemRandomNumberGenerator()
        // Noise, not silence: a flat buffer can be optimised through and would
        // flatter the transform.
        let pcm = (0..<count).map { _ in Float.random(in: -0.5...0.5, using: &rng) }
        let m = ThreadClock.measure {
            render(pcm: pcm, sampleRate: sampleRate, noiseFloor: 0.35,
                   minFrequencyHz: 15_000, displaySpanSeconds: displaySpanSeconds,
                   onsetFraction: 0.30, expectedOnsetSample: span, makeImage: false)
        }
        return (m.wallMs, m.cpuMs, m.value?.stftFrames ?? 0)
    }

    static func render(pcm: [Float],
                       sampleRate: Double,
                       noiseFloor: Float,
                       minFrequencyHz: Double,
                       displaySpanSeconds: Double,
                       onsetFraction: Double,
                       expectedOnsetSample: Int,
                       palette: Palette = .inferno,
                       makeImage: Bool = true) -> Result? {
        let bins = binCount

        // ── 1-2. STFT → magnitude → dB, peak-normalized to [0,1], row-major
        //  [bin * nFrames + frame] — now shared with WavSpectrogramEngine via
        //  STFTGrid.compute (a `windowLen` Hann window zero-padded to `fftLen`,
        //  so the FFT interpolates to `bins` frequency points at full time res).
        let stftStart = DispatchTime.now()
        guard let (norm, nFrames) = STFTGrid.compute(pcm: pcm, scratch: &Self.sttfScratch,
                                                      dynamicRangeDB: dynamicRangeDB,
                                                      frameHop: displayHop)
        else { return nil }
        let stftMs = Double(DispatchTime.now().uptimeNanoseconds
                            - stftStart.uptimeNanoseconds) / 1e6

        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBinAllowed = max(1, Int(minFrequencyHz / hzPerBin))

        // ── 2b. Output geometry + search region ─────────────────────────────
        //  The displayed window is a fixed span. We find the call within a region
        //  around the detector's expected onset (so a neighbouring call/echo elsewhere
        //  in the wide capture can't hijack the lock), then crop that span with the
        //  call's onset placed at `onsetFraction`.
        let outFrames   = max(8, Int(displaySpanSeconds * sampleRate / Double(displayHop)))
        let onsetOutCol = min(max(Int(onsetFraction * Double(outFrames)), 0), outFrames - 1)
        let expectedFrame = min(max(expectedOnsetSample / displayHop, 0), nFrames - 1)
        let searchLo = max(0, expectedFrame - outFrames / 2)
        let searchHi = min(nFrames, expectedFrame + outFrames + outFrames / 2)



        // ── 3. Peak (dominant freq + loudest column) within the search region ──
        //  Column peaks are kept rather than recomputed: the duration walk below and
        //  the background mean both want them, and each `columnPeak` call is a scan
        //  over every bin.
        var peakValue: Float = 0
        var peakBin = minBinAllowed
        var peakCol = searchLo, peakColVal: Float = 0
        var colPeaks = [Float](repeating: 0, count: max(0, searchHi - searchLo))
        for col in searchLo..<searchHi {
            var colMax: Float = 0
            for bin in minBinAllowed..<bins {
                let v = norm[bin * nFrames + col]
                if v > colMax { colMax = v }
                if v > peakValue { peakValue = v; peakBin = bin }
            }
            colPeaks[col - searchLo] = colMax
            if colMax > peakColVal { peakColVal = colMax; peakCol = col }
        }

        // ── 4. Noise gate + contrast stretch ────────────────────────────────
        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // ── 5. Duration from the −12 dB energy envelope around the loudest col ──
        // Loudest in-band bin per column, from the scan above.
        func columnPeak(_ col: Int) -> Float {
            let i = col - searchLo
            return (i >= 0 && i < colPeaks.count) ? colPeaks[i] : 0
        }
        let durThreshold = max(floor, peakColVal - 12.0 / dynamicRangeDB)
        var durStart = peakCol, durEnd = peakCol
        while durStart - 1 >= searchLo,     columnPeak(durStart - 1) >= durThreshold { durStart -= 1 }
        while durEnd + 1 < searchHi,        columnPeak(durEnd + 1)   >= durThreshold { durEnd += 1 }
        let durationCols = durEnd - durStart + 1
        let secondsPerCol = Double(displayHop) / sampleRate

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

        // Quality: how far the loudest column stands above the BACKGROUND — the
        // columns of the search region the call does not occupy.
        //
        // **It used to average the whole region, the call included, and that made
        // it a measure of brevity rather than of cleanliness** (2026-09-07). A long
        // call fills more of the fixed ~20 ms region, which lifts the mean, which
        // pushes quality down: measured on the demo clip, MYYU at 2.1 ms scored
        // 0.90 and LANO at 13.3 ms scored 0.33 — under the 0.35 the pulse view
        // requires before it will show a call at all. The species it silently
        // refused to draw were the long, low-frequency ones (LACI, LANO, EPFU),
        // which is to say it hid whichever bats it was least able to describe.
        // Excluding the call's own columns makes the score independent of how long
        // the call is, which is what it was always supposed to mean.
        var bgSum: Float = 0
        var bgCols = 0
        for col in searchLo..<searchHi where col < durStart || col > durEnd {
            bgSum += colPeaks[col - searchLo]
            bgCols += 1
        }
        // A call filling the entire region leaves no background to compare against.
        // Nothing here can tell a very long call from a region of continuous noise,
        // so this stays deliberately unconfident rather than guessing either way.
        let meanBackground = bgCols > 0 ? bgSum / Float(bgCols) : peakColVal * 0.5
        let quality: Float = peakColVal > 0 ? 1.0 - (meanBackground / peakColVal) : 0

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

        // ── 7b. How much of the wide image the DEFAULT view shows ────────────
        //  The default view used to be exactly `outFrames` wide whatever the call
        //  did, with the onset pinned at `onsetFraction` from its left edge. That
        //  leaves only `(1 - onsetFraction)` of the window — 7 ms of a 10 ms
        //  setting — for the call itself, so anything longer ran off the right
        //  edge. Bats do not oblige: LANO averages 13 ms on the demo clip and LACI
        //  is longer still, so the species with the most structure to look at were
        //  the ones shown cut in half.
        //
        //  The audio was never missing — the rendered image is four windows wide
        //  for pan headroom — so this widens the *crop* rather than the capture,
        //  and costs nothing: no extra transform, no extra pixels. A call that
        //  already fits gets exactly the window it got before, so the familiar
        //  fixed scale is unchanged for most pulses; only a call that would have
        //  been clipped opens the view up, and only as far as it needs.
        let marginCols = max(2, Int(0.001 / secondsPerCol))       // ~1 ms of air each side
        let wantFrames = durationCols + 2 * marginCols
        // Keep the onset where the eye expects it, then take whatever width the
        // call needs, bounded by what was actually rendered.
        let tightFrames = min(wideOutFrames, max(outFrames, wantFrames))
        let tightOnsetCol = Int(onsetFraction * Double(tightFrames))
        let tightLeftCol = min(max(0, (durStart - tightOnsetCol) - wideSrcStart),
                               max(0, wideOutFrames - tightFrames))
        let tightRightCol = min(wideOutFrames, tightLeftCol + tightFrames)

        // One malloc handed straight to CoreGraphics, rather than filling a reused
        // scratch array and then copying the whole thing into a `Data` for the
        // provider. At ~490 000 pixels that copy was ~2 MB memcpy per captured
        // pulse, on the capture queue, several times a second during a busy pass —
        // and the allocation it was avoiding is one malloc. `releaseData` below
        // hands ownership to the provider, so this is not leaked.
        // The pulse view is a sample, not a running film: it refreshes on
        // `displayRefreshIntervalSeconds` (2 s) so a person can study one call, and
        // most captures were being drawn only to be discarded on arrival. Drawing
        // is also the slowest thing on the capture queue, and the queue gates
        // whether the NEXT pulse is looked at, so those discarded renders were
        // costing real detections. Everything above this point — peak frequency,
        // duration, band, quality — is already computed and is what the pulse
        // record actually needs; only the picture is optional.
        guard makeImage else {
            return Result(
                image: nil,
                freqMin: Double(tightMin) * hzPerBin,
                freqMax: Double(tightMax) * hzPerBin,
                wideFreqMin: Double(renderMin) * hzPerBin,
                wideFreqMax: Double(renderMax) * hzPerBin,
                timeTightLeftFrac: Double(tightLeftCol) / Double(wideOutFrames),
                timeTightRightFrac: Double(tightRightCol) / Double(wideOutFrames),
                peakFreq: Double(peakBin) * hzPerBin,
                durationMs: Double(durationCols) * secondsPerCol * 1000,
                cleanImage: nil,
                cleanFreqMinHz: Double(tightMin) * hzPerBin,
                cleanFreqMaxHz: Double(tightMax) * hzPerBin,
                cleanSpanMs: 0,
                quality: quality,
                stftMs: stftMs,
                stftFrames: nFrames)
        }

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
            timeTightLeftFrac: Double(tightLeftCol) / Double(wideOutFrames),
            timeTightRightFrac: Double(tightRightCol) / Double(wideOutFrames),
            peakFreq: Double(peakBin) * hzPerBin,
            durationMs: Double(durationCols) * secondsPerCol * 1000,
            cleanImage: cleanCG.map { UIImage(cgImage: $0) },
            cleanFreqMinHz: Double(tightMin) * hzPerBin,
            cleanFreqMaxHz: Double(tightMax) * hzPerBin,
            cleanSpanMs: Double(cleanX1 - cleanX0 + 1) * secondsPerCol * 1000,
            quality: quality,
            stftMs: stftMs,
            stftFrames: nFrames
        )
    }
}
