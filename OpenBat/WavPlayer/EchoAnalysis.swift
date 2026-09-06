//
//  EchoAnalysis.swift
//  OpenBat
//
//  How much of what was recorded is the bat, and how much is the room.
//
//  WHY THIS EXISTS
//  ---------------
//  A call recorded in the open is a few milliseconds long and then gone. The
//  same call recorded beside a wall, a road surface, a barn or a rock face
//  arrives again a few milliseconds later, quieter, and again after that, until
//  the reflections smear into a tail. On a spectrogram that tail sits directly
//  under the call's own frequencies, so it fills in the gaps between the sweeps
//  and blurs the one thing an identifier reads: the SHAPE of a call — how
//  steeply it drops, where it flattens, whether it has a tail of its own.
//
//  A reverberant recording is still a true presence record, so this is never a
//  blocker. It is a deduction on the upload score and a note saying why, which
//  is the same treatment "the calls vary a lot in frequency" gets: the app
//  saying, before anybody's time is spent, that this one will be hard to
//  verify. It is also why the close-up picture centres on the loudest moment
//  rather than on the classifier's timestamp — see `INatImages.closeUp`, where
//  an echo was convincing enough to be posted as the call itself.
//
//  WHAT IS ACTUALLY MEASURED
//  -------------------------
//  For each call, how far the sound in the call's own frequency band has fallen
//  by the time the call itself is over — the level 6 to 40 ms after the peak,
//  measured against the peak, with the recording's own background as the zero.
//  A call in the open is back at the background inside a millisecond or two and
//  scores near 0; one in a reverberant place is still 10 dB up and scores near
//  1. The recording's figure is the median across the calls, so one call that
//  happened to be measured across a neighbour cannot decide it.
//
//  Three things it deliberately does NOT do. It does not try to separate an
//  echo from a second bat, because it cannot and neither can the identifier.
//  It does not measure calls with another call close behind them, since the
//  neighbour would be read as the echo. And it does not run at detection time:
//  it is a property of the recording, cheap enough to measure when somebody
//  actually asks, and doing it live would put an FFT in the capture path for a
//  number nothing in the capture path uses.
//
//  ⚠️ THE THRESHOLDS ARE REASONED, NOT MEASURED
//  --------------------------------------------
//  `cleanIndex` and `reverberantIndex` come from what the arithmetic implies,
//  not from a corpus of known-reverberant recordings — OpenBat does not have
//  one. They are the part of this file most likely to be wrong, and the way to
//  fix them is to record the same bat in the open and against a wall and see
//  what the two files report. Until that happens, the deduction is capped
//  where a wrong answer costs a grade rather than a post.
//

import Foundation

nonisolated enum EchoAnalysis {

    /// A recording's reverberation, and how much evidence it rests on.
    struct Result {
        /// 0 = every call is back at the background before the next moment;
        /// 1 = the tail after a call is as loud as the call.
        let index: Double
        /// How many calls were actually measurable. Below `minimumCalls` there
        /// is no `Result` at all rather than a figure resting on one call.
        let callsMeasured: Int
    }

    /// Where a call's own energy is assumed to have finished and its
    /// reflections to have begun.
    ///
    /// A bat pulse here is 5–15 ms, but its LOUD part is much shorter, and the
    /// reflection that matters arrives from a surface a metre or two away —
    /// 6 ms is sound travelling about two metres and back. Starting earlier
    /// measures the call itself; starting later misses the reflections that do
    /// the damage.
    static let tailStartSeconds = 0.006

    /// Where the tail stops being measured. Past 40 ms a reflection has
    /// travelled seven metres and is inaudible under the next call anyway, and
    /// the window has to stay clear of the next pulse.
    static let tailEndSeconds = 0.040

    /// A call with another call closer than this behind it is not measured: the
    /// neighbour would land inside the tail window and be read as an echo of
    /// the first. Bats in search phase call two to ten times a second, so this
    /// keeps most of them; a feeding buzz is excluded entirely, which is
    /// correct — its calls overlap their own echoes by design.
    static let minimumCallGapSeconds = 0.060

    /// How far a call must stand above the background to be worth measuring.
    /// Below this the ratio is dominated by how the background happened to
    /// wander, not by the room.
    static let minimumCallLevelDB: Float = 12

    /// Calls measured before stopping. The median stabilises long before this,
    /// and each one is an FFT over half a second of 384 kHz audio.
    static let maximumCallsMeasured = 12

    /// The fewest calls that can produce a figure at all. Two calls agreeing is
    /// a median; one call is an anecdote, and the deduction it would drive is
    /// twenty points.
    static let minimumCalls = 3

    /// Where the deduction starts and where it maxes out — see the warning in
    /// this file's header. Provisional.
    static let cleanIndex = 0.30
    static let reverberantIndex = 0.65

    /// How wide either side of a call's estimated position to analyse.
    ///
    /// A pulse's timestamp is stamped when the classifier finished, so it
    /// carries the pipeline's latency — tens of milliseconds, unpredictably —
    /// and the call has to be found rather than assumed. Same window and same
    /// reasoning as `INatImages.loudestMoment`.
    private static let searchWindowSeconds = 0.25

    /// Columns to analyse the window at. 1024 over half a second is ~0.5 ms
    /// each, which resolves a 6 ms onset and a 34 ms tail with room to spare,
    /// and keeps the grid it allocates to a few megabytes.
    private static let analysisColumns = 1024

    /// Measures one recording.
    ///
    /// `wavURL` and `segmentStart` must describe the SAME audio — the pass
    /// segment and the instant its first sample was recorded — since pulse
    /// timestamps are turned into offsets into that file.
    ///
    /// Returns nil when there is nothing measurable: too few calls with clear
    /// air behind them, a file that can't be read, or calls too faint to judge.
    /// The caller then scores the recording without this term rather than
    /// assuming the best or the worst.
    static func measure(wavURL: URL,
                        sampleRate: Double,
                        segmentStart: Date,
                        pulses: [PulseRecord],
                        calibrationCurve: MicCalibrationCurve?) -> Result? {
        guard sampleRate > 0, pulses.count >= minimumCalls else { return nil }

        // Sorted by time, and the band comes from the pulse at the same
        // position — so the two must be the same sequence, not two separately
        // ordered ones.
        let ordered = pulses.sorted { $0.date < $1.date }
        let offsets = ordered.map { $0.date.timeIntervalSince(segmentStart) }
        var indices: [Double] = []

        for (i, offset) in offsets.enumerated() {
            guard indices.count < maximumCallsMeasured else { break }
            // Clear air behind it, or the neighbour becomes the echo.
            if i + 1 < offsets.count, offsets[i + 1] - offset < minimumCallGapSeconds { continue }
            guard let index = measureCall(near: offset, wavURL: wavURL, sampleRate: sampleRate,
                                          band: band(for: ordered[i]),
                                          calibrationCurve: calibrationCurve)
            else { continue }
            indices.append(index)
        }

        guard indices.count >= minimumCalls else { return nil }
        return Result(index: median(indices.sorted()), callsMeasured: indices.count)
    }

    /// One call's tail, as a fraction of its own height above the background.
    private static func measureCall(near estimate: TimeInterval,
                                    wavURL: URL,
                                    sampleRate: Double,
                                    band: ClosedRange<Double>,
                                    calibrationCurve: MicCalibrationCurve?) -> Double? {
        let from = max(0, estimate - searchWindowSeconds)
        let to = estimate + searchWindowSeconds
        let startSample = Int(from * sampleRate)
        let endSample = Int(to * sampleRate)
        guard endSample > startSample,
              let raw = WavSpectrogramEngine.renderRawTile(wavURL: wavURL,
                                                           startSample: startSample,
                                                           endSample: endSample,
                                                           targetColumns: analysisColumns,
                                                           calibrationCurve: calibrationCurve),
              raw.nCols > 0
        else { return nil }

        // Per-column peak across the call's own band. Measured on the raw dB
        // grid, not on a colorized picture: the colouring has a noise gate and
        // a per-column adaptive ceiling in it, so brightest pixel and loudest
        // sound are different questions — the same trap `loudestMoment`
        // documents.
        let binCount = STFTGrid.binCount
        guard raw.grid.count >= raw.nCols * binCount else { return nil }
        let hzPerBin = (sampleRate / 2) / Double(binCount)
        let loBin = min(max(Int(band.lowerBound / max(hzPerBin, 1)), 0), binCount - 1)
        let hiBin = min(max(Int(band.upperBound / max(hzPerBin, 1)), loBin), binCount - 1)

        var peaks = [Float](repeating: -.greatestFiniteMagnitude, count: raw.nCols)
        for bin in loBin...hiBin {
            let row = bin * raw.nCols
            for col in 0..<raw.nCols { peaks[col] = max(peaks[col], raw.grid[row + col]) }
        }

        // The window's own background, by the same rule `SilenceMap` uses: a
        // low percentile rather than the minimum, so one dead column can't
        // define it.
        let sorted = peaks.sorted()
        let floor = sorted[min(max(Int(0.20 * Double(sorted.count)), 0), sorted.count - 1)]

        guard let call = peaks.indices.max(by: { peaks[$0] < peaks[$1] }) else { return nil }
        let peak = peaks[call]
        guard peak - floor >= minimumCallLevelDB else { return nil }

        // Columns are uniform in time across the span the tile actually covers,
        // which is not quite what was asked for — see `renderRawTile`.
        let covered = Double(raw.endSample - raw.startSample) / sampleRate
        guard covered > 0 else { return nil }
        let columnsPerSecond = Double(raw.nCols) / covered
        let tailFrom = call + Int((tailStartSeconds * columnsPerSecond).rounded())
        let tailTo = min(raw.nCols, call + Int((tailEndSeconds * columnsPerSecond).rounded()))
        guard tailTo > tailFrom, tailFrom < raw.nCols else { return nil }

        let tail = peaks[tailFrom..<tailTo].max() ?? floor
        return Double(min(max((tail - floor) / (peak - floor), 0), 1))
    }

    /// The band to listen for the echo in: the call's own, since a reflection
    /// arrives at the frequencies it left at. Falls back to a window round the
    /// peak frequency for a pulse recorded before the renderer stored its
    /// bounds, and to the whole ultrasonic range for no pulse at all.
    private static func band(for pulse: PulseRecord) -> ClosedRange<Double> {
        if let low = pulse.imageFreqMinHz, let high = pulse.imageFreqMaxHz, high > low {
            return low...high
        }
        let peak = pulse.peakFreqHz
        guard peak > 0 else { return 10_000...150_000 }
        return max(5_000, peak - 10_000)...(peak + 10_000)
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
