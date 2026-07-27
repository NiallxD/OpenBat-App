//
//  CallAnalysis.swift
//  OpenBat
//
//  Bioacoustic call-parameter measurement over an arbitrary sample range —
//  either an auto-detected pulse marker (padded window around a PulseRecord)
//  or a manual drag-to-select region in WavSpectrogramView. Reuses
//  PulseImageRenderer's proven threshold-based formulas (peak frequency,
//  duration from a -12dB envelope, frequency extent from a -15dB threshold),
//  generalized to a plain [0, nFrames) search range instead of an
//  onset-locked capture window — the caller is trusted to have already
//  bounded the selection to roughly one call, so no onset/search-region
//  narrowing is needed here.
//
//  Characteristic/knee frequency (CF) has NO existing algorithm anywhere in
//  this codebase (it only appears as a per-species REFERENCE value in the
//  static field guide JSON) — this is new work. Heuristic: the median of the
//  per-column dominant frequency over the last `cfTailFraction` of the call's
//  active duration, where FM sweeps typically flatten into a quasi-CF tail.
//  `cfTailFraction` is exposed as a tunable (SettingsView, same
//  "starting default, not a settled value" treatment as
//  `display.playbackThumbnailNoiseFloor`) since it will need calibration
//  against real recordings.
//

import Accelerate
import Foundation

nonisolated enum CallAnalysis {

    /// Which way a terminal toe turns, or `.none` if the call body runs
    /// straight to its end. A diagnostic feature in its own right (see
    /// *Identifying BC's Bats*, echolocation chapter — "toes, downward or
    /// upward turned").
    enum ToeDirection { case none, up, down }

    struct Result {
        let peakFreqHz: Double
        /// Characteristic frequency (Fc): the lowest frequency of the call
        /// BODY, EXCLUDING any toe. nil if the ridge was too short to segment.
        let characteristicFreqHz: Double?
        let bandwidthHz: Double
        let freqMinHz: Double
        let freqMaxHz: Double
        let durationMs: Double
        let startFreqHz: Double
        let endFreqHz: Double
        /// Signed: (endFreqHz - startFreqHz) / durationMs. Negative for a
        /// typical downward FM sweep. This is the WHOLE-pulse average slope
        /// (Kaleidoscope's S1-like figure), including the steep FM onset — for
        /// the diagnostic body slope use `bodySlopeHzPerMs`.
        let sweepRateHzPerMs: Double
        /// Knee/elbow frequency (Fk): where the steep FM leading edge bends
        /// into the flatter call body. nil if the ridge was too short/simple
        /// to find a knee.
        let kneeFreqHz: Double?
        /// Slope of the CALL BODY only (knee → toe start), Hz/ms — the
        /// diagnostic slope (Kaleidoscope's Sc), distinct from
        /// `sweepRateHzPerMs`. nil if there's no resolvable body.
        let bodySlopeHzPerMs: Double?
        /// Direction of the terminal toe, if any.
        let toeDirection: ToeDirection
        /// 0-1, same meaning as PulseImageRenderer's quality score: how much
        /// the loudest column stands out above the analyzed region's mean.
        let quality: Float
        /// Labelled call landmarks for on-spectrogram annotation (Hi f, Peak,
        /// Fc, Lo f). `sampleOffset` is in REAL samples relative to the
        /// analyzed range's first sample — the caller adds its own absolute
        /// start (and maps through the silence map, if any) to place them.
        let points: [Point]

        struct Point {
            let label: String
            let sampleOffset: Int
            let freqHz: Double
        }
    }

    /// Manual selections wider than this are clamped before analysis — a
    /// multi-second drag likely spans many calls, which doesn't have one
    /// meaningful PF/CF/duration anyway.
    static let maxAnalysisSpanSeconds: Double = 2.0
    static let defaultCFTailFraction: Double = 0.25
    private static let dynamicRangeDB: Float = 48

    // Duration is measured from the energy envelope around the loudest
    // column: how far either side the per-column peak stays within
    // `durationThresholdDB` of the call's own peak. dB BELOW peak; larger =
    // includes fainter energy = longer measurement.
    //
    // Frequency extent (Fmax/Fmin), Fc, the knee and the body slope are NOT
    // measured from a flat dB threshold any more — they come from the
    // dominant-frequency RIDGE (see the ridge decomposition below), which is
    // what *Identifying BC's Bats* / Kaleidoscope actually trace.
    private static let durationThresholdDB: Float = 22
    /// The measurement floor is CAPPED here rather than taken straight from
    /// the display noise-floor slider: a display floor of 0.5 (≈−24 dB) would
    /// otherwise cap analysis above the fainter call energy Kaleidoscope
    /// measures (~−33 dB). Analysis precision shouldn't depend on a display
    /// preference, so it uses its own (lower) floor.
    private static let maxAnalysisFloor: Float = 0.2

    // ── Fine-resolution extent tracer ────────────────────────────────────────
    // The main 512-sample (1.33 ms) STFT window smears fast frequency
    // excursions — a steep onset sweeps ~18 kHz WITHIN one window — so the grid
    // ridge reads Fmax several kHz low (verified against synthetic pulses of
    // exact known Fmax: 512-grid read 61.9 vs true 65.0; Kaleidoscope, with
    // finer time resolution, read 64.5). A much shorter window has the time
    // resolution to follow the onset; zero-padding to `extentFFTLen` + parabolic
    // peak interpolation keeps the frequency estimate precise for the locally
    // dominant tone. Used ONLY to sharpen Fmax/Fmin — the frequency-precise
    // 512-grid still drives the body/knee/slope/Fc (where the extra frequency
    // resolution matters and the smear doesn't).
    private static let extentWindowLen = 64          // 0.167 ms @ 384 kHz
    private static let extentHop = 16
    private static let extentFFTLen = 512            // zero-pad target (2^9)
    private static let extentLog2 = vDSP_Length(9)
    private static let extentTraceDB: Float = 36     // follow the trace to −36 dB
    private static let extentClimbHeadroomHz: Double = 15_000  // max lift above grid Fmax
    private static let extentSetup: FFTSetup = {
        guard let s = vDSP_create_fftsetup(extentLog2, FFTRadix(kFFTRadix2)) else {
            fatalError("CallAnalysis: extent FFT setup failed")
        }
        return s
    }()
    private static let extentHann: [Float] = {
        var w = [Float](repeating: 0, count: extentWindowLen)
        vDSP_hann_window(&w, vDSP_Length(extentWindowLen), Int32(vDSP_HANN_NORM))
        return w
    }()

    /// Fine Fmax over `pcm[loSample..<hiSample)` using a short window, or nil if
    /// the range is too short / silent. The peak search is BOUNDED to
    /// `minBin...maxBin` — on real (noisy) audio a short window has poor
    /// per-frame SNR and a broadband spike near Nyquist can otherwise win a
    /// frame's argmax and clear the gate (observed: a real pulse reading Fmax =
    /// 191 kHz). `maxBin` is set by the caller to just above the grid Fmax, so
    /// the tracer can only ever REFINE the onset a little higher, never leap to
    /// an out-of-band artifact. The time-ordered dominant-freq trace is then
    /// median-smoothed to drop any remaining isolated spikes.
    /// `fineHzPerBin`/`minBin`/`maxBin` are for the zero-padded
    /// `extentFFTLen/2`-bin grid.
    private static func traceExtent(pcm: [Float], loSample: Int, hiSample: Int,
                                    fineHzPerBin: Double, minBin: Int, maxBin: Int) -> Double? {
        let W = extentWindowLen, bins = extentFFTLen / 2
        let hiBin = min(maxBin, bins - 1)
        let lo = max(0, loSample), hi = min(pcm.count, hiSample)
        guard hi - lo >= W, minBin < hiBin else { return nil }
        var windowed = [Float](repeating: 0, count: extentFFTLen)   // tail stays zero (pad)
        var realp = [Float](repeating: 0, count: bins)
        var imagp = [Float](repeating: 0, count: bins)
        var mags  = [Float](repeating: 0, count: bins)
        var frames: [(freq: Double, mag: Float)] = []
        pcm.withUnsafeBufferPointer { p in
            var s = lo
            while s + W <= hi {
                vDSP_vmul(p.baseAddress! + s, 1, extentHann, 1, &windowed, 1, vDSP_Length(W))
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { cx in
                        realp.withUnsafeMutableBufferPointer { rp in
                            imagp.withUnsafeMutableBufferPointer { ip in
                                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                                vDSP_ctoz(cx, 2, &split, 1, vDSP_Length(bins))
                                vDSP_fft_zrip(extentSetup, &split, 1, extentLog2, FFTDirection(FFT_FORWARD))
                                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(bins))
                            }
                        }
                    }
                }
                var peakBin = minBin
                var peakMag: Float = 0
                for b in minBin...hiBin where mags[b] > peakMag { peakMag = mags[b]; peakBin = b }
                // Parabolic (log-magnitude) interpolation for sub-bin precision
                // — a single dominant tone's true peak sits between bins.
                var interp = Double(peakBin)
                if peakBin > minBin, peakBin < hiBin {
                    let a = mags[peakBin - 1], b0 = mags[peakBin], c = mags[peakBin + 1]
                    let denom = a - 2 * b0 + c
                    if denom != 0 { interp += Double(0.5 * (a - c) / denom) }
                }
                frames.append((interp * fineHzPerBin, peakMag))
                s += extentHop
            }
        }
        guard let gPeak = frames.map(\.mag).max(), gPeak > 0 else { return nil }
        let floorMag = gPeak * pow(10, -extentTraceDB / 20)
        // Median-of-5 smooth the time-ordered dominant-freq trace before taking
        // the max — a brief broadband transient (click) that survives the band
        // bound in a couple of frames still shouldn't set Fmax.
        let freqs = frames.map(\.freq)
        var fmax = -Double.greatestFiniteMagnitude
        for i in freqs.indices where frames[i].mag >= floorMag {
            let l = max(0, i - 2), r = min(freqs.count - 1, i + 2)
            let w = Array(freqs[l...r]).sorted()
            let sm = w[w.count / 2]
            if sm > fmax { fmax = sm }
        }
        return fmax > -Double.greatestFiniteMagnitude ? fmax : nil
    }

    /// Reads `[startSample, endSample)` (clamped to `maxAnalysisSpanSeconds`)
    /// from `wavURL` and analyzes it.
    static func analyze(wavURL: URL, sampleRate: Double,
                        startSample: Int, endSample: Int,
                        minFrequencyHz: Double,
                        maxFrequencyHz: Double = .greatestFiniteMagnitude,
                        noiseFloor: Float,
                        cfTailFraction: Double = defaultCFTailFraction) -> Result? {
        let maxSpanSamples = Int(maxAnalysisSpanSeconds * sampleRate)
        let clampedEnd = min(endSample, startSample + maxSpanSamples)
        guard clampedEnd > startSample else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: degenerate range \(startSample)-\(endSample), aborting")
            return nil
        }
        guard let pcm = WavPCMReader.readSamples(wavURL: wavURL, startSample: startSample,
                                                 count: clampedEnd - startSample)
        else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: WavPCMReader.readSamples FAILED for \(startSample)-\(clampedEnd)")
            return nil
        }
        WavPlayerDebugLog.log("CallAnalysis", "analyze: read \(pcm.count) samples (\(startSample)-\(clampedEnd), requested \(clampedEnd - startSample))")
        return WavPlayerDebugLog.time("CallAnalysis", "analyze") {
            analyze(pcm: pcm, sampleRate: sampleRate, minFrequencyHz: minFrequencyHz,
                   maxFrequencyHz: maxFrequencyHz,
                   noiseFloor: noiseFloor, cfTailFraction: cfTailFraction)
        }
    }

    /// Pure-data entry point (no file I/O) — what the file-based `analyze`
    /// above delegates to, and what tests drive directly.
    static func analyze(pcm: [Float], sampleRate: Double,
                        minFrequencyHz: Double,
                        maxFrequencyHz: Double = .greatestFiniteMagnitude,
                        noiseFloor: Float,
                        cfTailFraction: Double = defaultCFTailFraction) -> Result? {
        var scratch = STFTGrid.Scratch()
        guard let (norm, nFrames) = STFTGrid.compute(pcm: pcm, scratch: &scratch, dynamicRangeDB: dynamicRangeDB)
        else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: STFTGrid.compute FAILED (pcm.count=\(pcm.count), windowLen=\(STFTGrid.windowLen))")
            return nil
        }
        WavPlayerDebugLog.log("CallAnalysis", "analyze: STFTGrid.compute OK, nFrames=\(nFrames)")

        let bins = STFTGrid.binCount
        let hzPerBin = (sampleRate / 2) / Double(bins)
        let minBinAllowed = max(1, Int(minFrequencyHz / hzPerBin))
        guard minBinAllowed < bins else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: minBinAllowed=\(minBinAllowed) >= bins=\(bins), aborting")
            return nil
        }
        // Upper frequency bound (Kaleidoscope's selection-box top). Every bin
        // scan below is clamped to `minBinAllowed...maxBinAllowed` so a
        // persistent out-of-call-band interferer (a continuous ultrasonic tone,
        // or broadband noise up toward Nyquist) can't win a column's argmax and
        // corrupt the ridge — the failure mode that gave Fmax = 191 kHz and
        // pulled Fppeak onto a ~29 kHz tone on real, noisy passes. `.greatest-
        // FiniteMagnitude` (the default) means "no ceiling" → whole band, same
        // as before this parameter existed.
        // Converted defensively rather than with `isFinite ? Int(…) : …`, which
        // trapped on the parameter's own default value: `.greatestFiniteMagnitude`
        // IS finite, so that branch fed ~1.8e308 to `Int(_:)` and hit
        // "Double value cannot be converted to Int because it is outside the
        // representable range". Every caller that omitted `maxFrequencyHz`
        // crashed — which in practice meant the tests only, since WavPlayerView
        // always passes the selection box's top edge.
        //
        // Comparing in Double space before converting also covers any finite but
        // oversized ceiling (a nonsense value from a future caller), not just the
        // one default that happened to expose this.
        let maxBinAllowed: Int = {
            let raw = maxFrequencyHz / hzPerBin
            guard raw.isFinite, raw < Double(bins - 1) else { return bins - 1 }
            return max(0, Int(raw))
        }()
        guard maxBinAllowed > minBinAllowed else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: maxBinAllowed=\(maxBinAllowed) <= minBinAllowed=\(minBinAllowed), aborting")
            return nil
        }

        func columnPeak(_ col: Int) -> Float {
            var m: Float = 0
            for bin in minBinAllowed...maxBinAllowed {
                let v = norm[bin * nFrames + col]
                if v > m { m = v }
            }
            return m
        }

        func loudestBin(atCol col: Int) -> Int {
            var bBin = minBinAllowed
            var bVal: Float = -1
            for bin in minBinAllowed...maxBinAllowed {
                let v = norm[bin * nFrames + col]
                if v > bVal { bVal = v; bBin = bin }
            }
            return bBin
        }

        // Peak (dominant freq + loudest column) over the WHOLE passed-in
        // range — the caller already bounded the selection, so no onset-lock
        // / search-region narrowing (unlike PulseImageRenderer) is needed.
        var peakValue: Float = 0
        var peakBin = minBinAllowed
        var peakCol = 0
        var peakColVal: Float = 0
        var totalColPeak: Float = 0
        for col in 0..<nFrames {
            var colMax: Float = 0
            for bin in minBinAllowed...maxBinAllowed {
                let v = norm[bin * nFrames + col]
                if v > colMax { colMax = v }
                if v > peakValue { peakValue = v; peakBin = bin }
            }
            totalColPeak += colMax
            if colMax > peakColVal { peakColVal = colMax; peakCol = col }
        }
        guard peakColVal > 0 else {
            WavPlayerDebugLog.log("CallAnalysis", "analyze: peakColVal is 0 (silent/below-threshold selection), aborting")
            return nil
        }

        // Capped well below the display slider so faint call energy stays
        // measurable regardless of the visual noise gate (see maxAnalysisFloor).
        let floor = min(max(noiseFloor, 0), Self.maxAnalysisFloor)

        // Duration from the energy envelope around the loudest column.
        let durThreshold = max(floor, peakColVal - Self.durationThresholdDB / dynamicRangeDB)
        var durStart = peakCol, durEnd = peakCol
        while durStart - 1 >= 0,       columnPeak(durStart - 1) >= durThreshold { durStart -= 1 }
        while durEnd + 1 < nFrames,    columnPeak(durEnd + 1)   >= durThreshold { durEnd += 1 }
        let durationCols = durEnd - durStart + 1
        let secondsPerCol = Double(STFTGrid.hop) / sampleRate
        let durationMs = Double(durationCols) * secondsPerCol * 1000

        // ── Ridge decomposition: knee / call body / toe ─────────────────────
        // Everything below follows the call-parameter model in *Identifying
        // BC's Bats* (echolocation chapter) and mirrors Kaleidoscope's own
        // Fmax / Fk / Fc / Fmin / Sc fields. A pulse is a steep FM leading edge
        // that BENDS at a knee/elbow into a flatter, louder CALL BODY, which
        // may end in a short TOE turning up or down. The diagnostic
        // frequencies and slope are defined relative to that segmentation, NOT
        // from a flat dB threshold over the whole pulse — the old −27 dB
        // flood-fill dipped into the noise floor below the call (reading Fmin
        // too low) and clipped the faint HF onset (reading Fmax too low).
        //
        // The ridge = the loudest bin per column across the active duration —
        // the same dominant-frequency trace Kaleidoscope draws, and whose
        // extremes ARE its Fmax/Fmin.
        let ridgeCount = durEnd - durStart + 1
        var ridgeHz = [Double](repeating: 0, count: ridgeCount)
        for i in 0..<ridgeCount {
            ridgeHz[i] = Double(loudestBin(atCol: durStart + i)) * hzPerBin
        }
        // Median-of-3 smooth: one spurious column (noise winning a column's
        // argmax at the faint onset) shouldn't move a landmark by a whole bin.
        if ridgeCount >= 3 {
            var smoothed = ridgeHz
            for i in 1..<(ridgeCount - 1) {
                let a = ridgeHz[i - 1], b = ridgeHz[i], c = ridgeHz[i + 1]
                smoothed[i] = max(min(a, b), min(max(a, b), c))   // median of 3
            }
            ridgeHz = smoothed
        }
        func ridgeCol(_ i: Int) -> Int { durStart + i }

        // Fmax / Fmin from the ridge extremes. Fmin INCLUDES the toe (it's the
        // absolute lowest ridge frequency); Fc below excludes it.
        var fmaxIdx = 0, fminIdx = 0
        for i in 0..<ridgeCount {
            if ridgeHz[i] > ridgeHz[fmaxIdx] { fmaxIdx = i }
            if ridgeHz[i] < ridgeHz[fminIdx] { fminIdx = i }
        }
        var fmaxHz = ridgeHz[fmaxIdx]
        var fmaxCol = ridgeCol(fmaxIdx)
        let fminHz = ridgeHz[fminIdx]

        // Onset climb — Fmax only. The faint HF start of the FM sweep is often
        // below the duration envelope's −22 dB threshold, so the in-window
        // ridge clips Fmax (e.g. 57 vs Kaleidoscope's 65 kHz). Follow the ridge
        // LEFT of the active window, up the onset, while column energy stays
        // above a low trace floor (~−36 dB, roughly where Kaleidoscope's
        // dominant-frequency dots stop following the onset). This decouples the
        // frequency EXTENT from the (tighter) duration measurement, exactly as
        // Kaleidoscope does — its Dur can be shorter than ours while its Fmax
        // reads higher. Bounded so it can't wander into a preceding call.
        let onsetFloor = peakColVal - 36 / dynamicRangeDB
        let onsetLimit = max(0, durStart - max(8, ridgeCount))
        var oc = durStart - 1
        while oc >= onsetLimit, columnPeak(oc) >= onsetFloor {
            let f = Double(loudestBin(atCol: oc)) * hzPerBin
            if f > fmaxHz { fmaxHz = f; fmaxCol = oc }
            oc -= 1
        }

        // Fine-resolution extent tracer: re-measure Fmax with a short window
        // over the pulse's sample span and push it OUTWARD only (the 512-grid
        // smears the onset inward, never outward, so a better-resolved reading
        // can only correct upward). Fmax ONLY — the grid Fmin is already
        // accurate (validated on synthetic pulses: 44.4 vs true 44.0), and the
        // fine tracer would drag it ~0.5 kHz below the body's own Fc on a
        // toe-less call, spuriously implying a toe. Bounded to the active
        // region ±one main window so it can't pick up a neighbouring pulse.
        let hop512 = STFTGrid.hop
        let loSample = max(0, durStart * hop512 - STFTGrid.windowLen)
        let hiSample = durEnd * hop512 + STFTGrid.windowLen
        let fineHzPerBin = (sampleRate / 2) / Double(extentFFTLen / 2)
        let fineMinBin = max(1, Int(minFrequencyHz / fineHzPerBin))
        // Ceiling: the tracer may only lift Fmax a plausible onset's worth above
        // the (smeared) grid value — never into out-of-band noise. The grid
        // under-reads a fast onset by a few kHz, so `extentClimbHeadroomHz` of
        // headroom is ample. Also hard-capped at the box top (`maxFrequencyHz`),
        // so a user-drawn ceiling is respected exactly, not overshot by the
        // headroom.
        // Same defensive conversion as `maxBinAllowed` above, and for the same
        // reason: `.greatestFiniteMagnitude` (this parameter's default) IS
        // finite, so an `isFinite` guard alone let ~1.8e308 reach `Int(_:)` and
        // trap. Compare in Double space, convert only once known in range.
        let fineTopBin = extentFFTLen / 2 - 1
        let fineBoxMaxBin: Int = {
            let raw = maxFrequencyHz / fineHzPerBin
            guard raw.isFinite, raw < Double(fineTopBin) else { return fineTopBin }
            return max(0, Int(raw))
        }()
        let fineMaxBin = min(fineBoxMaxBin, Int((fmaxHz + extentClimbHeadroomHz) / fineHzPerBin))
        if let fineFmax = traceExtent(pcm: pcm, loSample: loSample, hiSample: hiSample,
                                      fineHzPerBin: fineHzPerBin, minBin: fineMinBin, maxBin: fineMaxBin),
           fineFmax > fmaxHz {
            fmaxHz = fineFmax
        }

        // Knee/elbow = point of maximum perpendicular distance from the chord
        // joining the ridge's first and last samples — a parameter-free
        // "kneedle"-style corner detector. The FM ridge is convex, so its
        // elbow is exactly where it bulges farthest from that chord. Guarded to
        // the first 75% of the ridge: a max-distance point in the final stretch
        // is a toe, not the knee.
        var kneeIdx: Int?
        if ridgeCount >= 4 {
            let y0 = ridgeHz[0]
            let x1 = Double(ridgeCount - 1), y1 = ridgeHz[ridgeCount - 1]
            let dx = x1, dy = y1 - y0
            let denom = (dx * dx + dy * dy).squareRoot()
            if denom > 0 {
                var best = -1.0, bestIdx = 0
                let lastAllowed = max(1, Int(Double(ridgeCount - 1) * 0.75))
                for i in 1...lastAllowed {
                    // |cross product| / |chord| = perpendicular distance.
                    let d = abs(dy * Double(i) - dx * (ridgeHz[i] - y0)) / denom
                    if d > best { best = d; bestIdx = i }
                }
                kneeIdx = bestIdx
            }
        }

        // Least-squares slope (Hz per column) + intercept over [lo, hi].
        func ridgeFit(_ lo: Int, _ hi: Int) -> (slope: Double, intercept: Double) {
            let n = Double(hi - lo + 1)
            var sx = 0.0, sy = 0.0, sxx = 0.0, sxy = 0.0
            for i in lo...hi {
                let x = Double(i), y = ridgeHz[i]
                sx += x; sy += y; sxx += x * x; sxy += x * y
            }
            let d = n * sxx - sx * sx
            guard d != 0 else { return (0, sy / n) }
            let b = (n * sxy - sx * sy) / d
            return (b, (sy - b * sx) / n)
        }

        // Body = knee → end. Detect a TOE: a terminal run deviating from the
        // body's linear trend by more than `toeThresholdHz` in a consistent
        // direction (below trend = downturned, above = upturned). Fc is the
        // body's low-frequency end EXCLUDING that toe.
        let toeThresholdHz = 3 * hzPerBin
        var toeDirection: ToeDirection = .none
        var characteristicFreqHz: Double?
        var fcIdx: Int?
        var kneeFreqHz: Double?
        var bodySlopeHzPerMs: Double?

        if let k = kneeIdx, k <= ridgeCount - 3 {
            kneeFreqHz = ridgeHz[k]
            let (trendSlope, trendIntercept) = ridgeFit(k, ridgeCount - 1)
            // Walk back from the end while the ridge stays on ONE consistent
            // side of the trend beyond threshold — that terminal run is the toe.
            var toeStart = ridgeCount   // exclusive: no toe yet
            var toeSign = 0
            var i = ridgeCount - 1
            while i > k {
                let resid = ridgeHz[i] - (trendIntercept + trendSlope * Double(i))
                let sign = resid > toeThresholdHz ? 1 : (resid < -toeThresholdHz ? -1 : 0)
                if sign == 0 { break }
                if toeSign == 0 { toeSign = sign }
                else if sign != toeSign { break }
                toeStart = i
                i -= 1
            }
            if toeStart < ridgeCount { toeDirection = toeSign > 0 ? .up : .down }
            let bodyEnd = min(ridgeCount - 1, toeStart - 1)   // last body-proper index
            if bodyEnd >= k {
                // Fc = lowest freq of the body proper: median of its last few
                // columns for robustness (its tail, for a downsweep).
                let fcFrom = max(k, bodyEnd - 2)
                let tail = Array(ridgeHz[fcFrom...bodyEnd]).sorted()
                characteristicFreqHz = tail[tail.count / 2]
                fcIdx = bodyEnd
                if bodyEnd > k { bodySlopeHzPerMs = ridgeFit(k, bodyEnd).slope / (secondsPerCol * 1000) }
            }
        }

        // Fallback when the ridge was too short to segment: the old tail-median
        // Fc heuristic, no knee / body slope.
        if characteristicFreqHz == nil {
            let tailCount = Int((Double(ridgeCount) * cfTailFraction).rounded())
            if tailCount >= 2 {
                let tailStart = ridgeCount - tailCount
                let freqs = Array(ridgeHz[tailStart..<ridgeCount]).sorted()
                let mid = freqs.count / 2
                characteristicFreqHz = freqs.count % 2 == 0 ? (freqs[mid - 1] + freqs[mid]) / 2 : freqs[mid]
                fcIdx = (tailStart + ridgeCount - 1) / 2
            }
        }

        // Start = Fmax, End = Fmin (both ridge-derived). Overall sweep = the
        // whole-pulse average slope (ridge start → end); the diagnostic body
        // slope is `bodySlopeHzPerMs` above.
        let startFreqHz = fmaxHz
        let endFreqHz = fminHz
        let sweepRateHzPerMs = durationMs > 0 ? (ridgeHz[ridgeCount - 1] - ridgeHz[0]) / durationMs : 0

        // Peak frequency = the peak of the call-AVERAGED power spectrum
        // (Kaleidoscope's Fppeak), not the single loudest time-frequency
        // point: sum each bin's energy across the active duration and take
        // the max — the frequency the call spends the most energy at.
        var fppeakBin = peakBin
        var fppeakSum: Float = -1
        for bin in minBinAllowed...maxBinAllowed {
            let base = bin * nFrames
            var sum: Float = 0
            for col in durStart...durEnd { sum += norm[base + col] }
            if sum > fppeakSum { fppeakSum = sum; fppeakBin = bin }
        }
        let peakFreqHz = Double(fppeakBin) * hzPerBin
        // Draw the Peak marker where the ridge actually crosses Fppeak, so it
        // sits on the call rather than floating at the (time-agnostic) Fppeak.
        var peakMarkerCol = peakCol
        var bestPeakDelta = Int.max
        for col in durStart...durEnd {
            let d = abs(loudestBin(atCol: col) - fppeakBin)
            if d < bestPeakDelta { bestPeakDelta = d; peakMarkerCol = col }
        }

        // Quality: how much the peak column stands above the analyzed
        // region's background mean.
        let meanColPeak = totalColPeak / Float(max(1, nFrames))
        let quality: Float = 1.0 - (meanColPeak / peakColVal)

        // Annotation landmarks (column -> real-sample offset from the range
        // start), all ridge-derived: Hi f / Lo f at the Fmax/Fmin ridge
        // columns, Peak where the ridge crosses Fppeak, Fc at the body end
        // (excluding toe), Fk at the knee.
        var points: [Result.Point] = [
            .init(label: "Hi f", sampleOffset: fmaxCol * STFTGrid.hop, freqHz: fmaxHz),
            .init(label: "Peak", sampleOffset: peakMarkerCol * STFTGrid.hop, freqHz: peakFreqHz),
            .init(label: "Lo f", sampleOffset: ridgeCol(fminIdx) * STFTGrid.hop, freqHz: fminHz),
        ]
        if let cf = characteristicFreqHz, let fcIdx {
            points.append(.init(label: "Fc", sampleOffset: ridgeCol(fcIdx) * STFTGrid.hop, freqHz: cf))
        }
        if let kneeFreqHz, let kneeIdx {
            points.append(.init(label: "Fk", sampleOffset: ridgeCol(kneeIdx) * STFTGrid.hop, freqHz: kneeFreqHz))
        }

        WavPlayerDebugLog.log("CallAnalysis", "analyze: Fppeak=\(Int(peakFreqHz))Hz Fmax=\(Int(fmaxHz)) Fmin=\(Int(fminHz)) Fk=\(kneeFreqHz.map { Int($0) } ?? -1) Fc=\(characteristicFreqHz.map { Int($0) } ?? -1) Sc=\(bodySlopeHzPerMs.map { String(format: "%.0f", $0) } ?? "nil")Hz/ms toe=\(toeDirection) durationCols=\(durationCols) (\(String(format: "%.1f", durationMs))ms)")
        return Result(
            peakFreqHz: peakFreqHz,
            characteristicFreqHz: characteristicFreqHz,
            bandwidthHz: fmaxHz - fminHz,
            freqMinHz: fminHz,
            freqMaxHz: fmaxHz,
            durationMs: durationMs,
            startFreqHz: startFreqHz,
            endFreqHz: endFreqHz,
            sweepRateHzPerMs: sweepRateHzPerMs,
            kneeFreqHz: kneeFreqHz,
            bodySlopeHzPerMs: bodySlopeHzPerMs,
            toeDirection: toeDirection,
            quality: quality,
            points: points
        )
    }
}
