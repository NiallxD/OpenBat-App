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

import Foundation

nonisolated enum CallAnalysis {

    struct Result {
        let peakFreqHz: Double
        /// nil if the active duration is too short to have a measurable tail
        /// (fewer than 2 columns).
        let characteristicFreqHz: Double?
        let bandwidthHz: Double
        let freqMinHz: Double
        let freqMaxHz: Double
        let durationMs: Double
        let startFreqHz: Double
        let endFreqHz: Double
        /// Signed: (endFreqHz - startFreqHz) / durationMs. Negative for a
        /// typical downward FM sweep.
        let sweepRateHzPerMs: Double
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

    // Measurement thresholds, calibrated toward Wildlife Acoustics
    // Kaleidoscope on real MYCA/MYYU/MYLU calls. All are dB BELOW the call's
    // own peak; larger = includes fainter energy = wider/longer measurement.
    // The earlier −12/−15 dB pair matched Kaleidoscope's peak/Fc well but
    // clipped the faint high-frequency ONSET of the FM sweep, so start-freq,
    // bandwidth and duration all read low (e.g. 52.5 vs 61 kHz, 8.6 vs 15.4
    // kHz, 3.8 vs 5.2 ms). Widening captures the onset Kaleidoscope does.
    private static let durationThresholdDB: Float = 18
    private static let freqExtentThresholdDB: Float = 27
    /// The measurement floor is CAPPED here rather than taken straight from
    /// the display noise-floor slider: a display floor of 0.5 (≈−24 dB) would
    /// otherwise cap analysis above the fainter call energy Kaleidoscope
    /// measures (~−33 dB). Analysis precision shouldn't depend on a display
    /// preference, so it uses its own (lower) floor.
    private static let maxAnalysisFloor: Float = 0.2

    /// Reads `[startSample, endSample)` (clamped to `maxAnalysisSpanSeconds`)
    /// from `wavURL` and analyzes it.
    static func analyze(wavURL: URL, sampleRate: Double,
                        startSample: Int, endSample: Int,
                        minFrequencyHz: Double, noiseFloor: Float,
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
                   noiseFloor: noiseFloor, cfTailFraction: cfTailFraction)
        }
    }

    /// Pure-data entry point (no file I/O) — what the file-based `analyze`
    /// above delegates to, and what tests drive directly.
    static func analyze(pcm: [Float], sampleRate: Double,
                        minFrequencyHz: Double, noiseFloor: Float,
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

        func columnPeak(_ col: Int) -> Float {
            var m: Float = 0
            for bin in minBinAllowed..<bins {
                let v = norm[bin * nFrames + col]
                if v > m { m = v }
            }
            return m
        }

        func loudestBin(atCol col: Int) -> Int {
            var bBin = minBinAllowed
            var bVal: Float = -1
            for bin in minBinAllowed..<bins {
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
            for bin in minBinAllowed..<bins {
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

        // Frequency extent (bandwidth) from a -15dB threshold, scanned only
        // over the active duration columns — keeps quiet inter-call frames
        // from widening the band.
        let freqThreshold = max(floor, peakValue - Self.freqExtentThresholdDB / dynamicRangeDB)
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

        // Start/end frequency: the loudest in-band bin at the first/last
        // active column.
        let startFreqHz = Double(loudestBin(atCol: durStart)) * hzPerBin
        let endFreqHz = Double(loudestBin(atCol: durEnd)) * hzPerBin
        let sweepRateHzPerMs = durationMs > 0 ? (endFreqHz - startFreqHz) / durationMs : 0

        // Characteristic/knee frequency: median dominant-bin frequency over
        // the last `cfTailFraction` of the active duration.
        let tailCount = Int((Double(durationCols) * cfTailFraction).rounded())
        var characteristicFreqHz: Double?
        var fcCol: Int?
        if tailCount >= 2 {
            let tailStart = durEnd - tailCount + 1
            var freqs = (tailStart...durEnd).map { Double(loudestBin(atCol: $0)) * hzPerBin }
            freqs.sort()
            let mid = freqs.count / 2
            characteristicFreqHz = freqs.count % 2 == 0 ? (freqs[mid - 1] + freqs[mid]) / 2 : freqs[mid]
            fcCol = (tailStart + durEnd) / 2   // draw the Fc marker at the tail's midpoint
        }

        // Quality: how much the peak column stands above the analyzed
        // region's background mean.
        let meanColPeak = totalColPeak / Float(max(1, nFrames))
        let quality: Float = 1.0 - (meanColPeak / peakColVal)

        // Annotation landmarks (column -> real-sample offset from the range
        // start). Hi f / Lo f sit at the first/last active columns, Peak at
        // the loudest column, Fc at the tail midpoint.
        var points: [Result.Point] = [
            .init(label: "Hi f", sampleOffset: durStart * STFTGrid.hop, freqHz: startFreqHz),
            .init(label: "Peak", sampleOffset: peakCol * STFTGrid.hop, freqHz: Double(peakBin) * hzPerBin),
            .init(label: "Lo f", sampleOffset: durEnd * STFTGrid.hop, freqHz: endFreqHz),
        ]
        if let cf = characteristicFreqHz, let fcCol {
            points.append(.init(label: "Fc", sampleOffset: fcCol * STFTGrid.hop, freqHz: cf))
        }

        WavPlayerDebugLog.log("CallAnalysis", "analyze: peak=\(Int(Double(peakBin) * hzPerBin))Hz durationCols=\(durationCols) (\(String(format: "%.1f", durationMs))ms) quality=\(String(format: "%.2f", quality))")
        return Result(
            peakFreqHz: Double(peakBin) * hzPerBin,
            characteristicFreqHz: characteristicFreqHz,
            bandwidthHz: Double(maxBin - minBin + 1) * hzPerBin,
            freqMinHz: Double(minBin) * hzPerBin,
            freqMaxHz: Double(maxBin + 1) * hzPerBin,
            durationMs: durationMs,
            startFreqHz: startFreqHz,
            endFreqHz: endFreqHz,
            sweepRateHzPerMs: sweepRateHzPerMs,
            quality: quality,
            points: points
        )
    }
}
