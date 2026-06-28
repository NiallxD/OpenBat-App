//
//  PulseDetector.swift
//  OpenBat
//
//  Watches per-column peak values from SpectrogramRenderer. When a pulse is
//  detected (trailing edge of a run of above-threshold columns) it grabs a
//  history slice on the main thread then offloads image rendering to a
//  background queue — so `draw()` is never stalled.
//
//  isInPulse reflects the previous column's state and drives the renderer's
//  triggered-display mode: when true, the renderer records to the ring; when
//  false, it skips, so the scrolling spectrogram shows pulses back-to-back
//  with no silent gaps — the Wildlife Acoustics-style triggered view.
//

import UIKit
import Observation

@Observable
final class PulseDetector {

    // MARK: Settings

    enum TriggerMode: String, CaseIterable, Identifiable {
        case amplitude   = "Amplitude only"
        case ultrasonic  = "Frequency + Amplitude"
        var id: String { rawValue }
        var description: String {
            switch self {
            case .amplitude:
                "Fires on any loud sound in the analysis band — useful for testing but susceptible to wind and handling noise."
            case .ultrasonic:
                "Requires both high amplitude AND a peak frequency above the minimum. Rejects low-frequency noise."
            }
        }
    }

    // Each setting persists to UserDefaults on change (didSet) and is restored in
    // init(), so trigger tuning survives app relaunch instead of resetting.

    var triggerMode: TriggerMode = .ultrasonic {
        didSet { defaults.set(triggerMode.rawValue, forKey: Key.triggerMode) }
    }
    /// Normalised peak magnitude (0–1). Matches spectrogram brightness — 0.5 = medium-bright.
    var amplitudeThreshold: Float = 0.5 {
        didSet { defaults.set(amplitudeThreshold, forKey: Key.amplitudeThreshold) }
    }
    /// Minimum peak frequency (Hz) required in .ultrasonic mode. Default 15 kHz
    /// rejects wind and handling noise without cutting off any bat species.
    var minFrequencyHz: Double = 15_000 {
        didSet { defaults.set(minFrequencyHz, forKey: Key.minFrequencyHz) }
    }
    var minConsecutiveColumns: Int = 3 {
        didSet { defaults.set(minConsecutiveColumns, forKey: Key.minConsecutiveColumns) }
    }
    /// Minimum gap between detections. Kept short (50 ms → up to ~20 calls/sec) because
    /// gap-bridging already prevents one call from re-triggering; a long hold-off would
    /// cap the detected call rate well below what bats actually produce.
    var holdOffSeconds: Double = 0.05 {
        didSet { defaults.set(holdOffSeconds, forKey: Key.holdOffSeconds) }
    }
    /// Bridges brief amplitude dips *within* a single call (FM sweeps have nulls).
    /// A pulse only ends once this many consecutive columns fall below threshold,
    /// so one call yields exactly one capture instead of fragmenting. Default 6 ms.
    var maxGapMs: Double = 6 {
        didSet { defaults.set(maxGapMs, forKey: Key.maxGapMs) }
    }
    /// Fixed time span of the captured zoom window. Because every capture uses the
    /// SAME width, the pulse always renders at the same scale and the onset is
    /// always locked at 20% from the left — one pulse, same place, every time.
    var displayWindowMs: Double = 80 {
        didSet { defaults.set(displayWindowMs, forKey: Key.displayWindowMs) }
    }
    /// Brightness gate applied to the captured pulse image (0–1). Pixels below this
    /// are rendered black; the remaining range is stretched to use the full
    /// colormap, so only the high-energy pulse shows and the background haze is
    /// removed. Raise to strip more noise; 0 disables the gate.
    var pulseNoiseFloor: Float = 0.35 {
        didSet { defaults.set(pulseNoiseFloor, forKey: Key.pulseNoiseFloor) }
    }
    /// When true the renderer skips uploading silent columns to the ring buffer,
    /// so the spectrogram fills with back-to-back pulses instead of continuous audio.
    var triggeredDisplayMode: Bool = false {
        didSet { defaults.set(triggeredDisplayMode, forKey: Key.triggeredDisplayMode) }
    }

    /// Pulse onset position within the fixed window (0.1 = 10% from the left).
    private let onsetFraction = 0.1

    // MARK: Persistence

    private let defaults = UserDefaults.standard
    private enum Key {
        static let triggerMode          = "pulse.triggerMode"
        static let amplitudeThreshold   = "pulse.amplitudeThreshold"
        static let minFrequencyHz       = "pulse.minFrequencyHz"
        static let minConsecutiveColumns = "pulse.minConsecutiveColumns"
        static let holdOffSeconds       = "pulse.holdOffSeconds"
        static let maxGapMs             = "pulse.maxGapMs"
        static let displayWindowMs      = "pulse.displayWindowMs"
        static let triggeredDisplayMode = "pulse.triggeredDisplayMode"
        static let pulseNoiseFloor      = "pulse.pulseNoiseFloor"
    }

    init() {
        // Restore saved settings; absent keys leave the property defaults above.
        if let raw = defaults.string(forKey: Key.triggerMode),
           let mode = TriggerMode(rawValue: raw) { triggerMode = mode }
        if defaults.object(forKey: Key.amplitudeThreshold) != nil {
            amplitudeThreshold = defaults.float(forKey: Key.amplitudeThreshold)
        }
        if defaults.object(forKey: Key.minFrequencyHz) != nil {
            minFrequencyHz = defaults.double(forKey: Key.minFrequencyHz)
        }
        if defaults.object(forKey: Key.minConsecutiveColumns) != nil {
            minConsecutiveColumns = defaults.integer(forKey: Key.minConsecutiveColumns)
        }
        if defaults.object(forKey: Key.holdOffSeconds) != nil {
            holdOffSeconds = defaults.double(forKey: Key.holdOffSeconds)
        }
        if defaults.object(forKey: Key.maxGapMs) != nil {
            maxGapMs = defaults.double(forKey: Key.maxGapMs)
        }
        if defaults.object(forKey: Key.displayWindowMs) != nil {
            displayWindowMs = defaults.double(forKey: Key.displayWindowMs)
        }
        if defaults.object(forKey: Key.triggeredDisplayMode) != nil {
            triggeredDisplayMode = defaults.bool(forKey: Key.triggeredDisplayMode)
        }
        if defaults.object(forKey: Key.pulseNoiseFloor) != nil {
            pulseNoiseFloor = defaults.float(forKey: Key.pulseNoiseFloor)
        }
    }

    // MARK: Live pulse state (read by renderer on the main thread)

    /// True while a pulse is actively above threshold OR within the hold-off window.
    /// The renderer checks this BEFORE calling feed() so it lags by one column (~1 ms).
    private(set) var isInPulse: Bool = false

    // MARK: Output

    private(set) var lastPulseImage: UIImage? = nil
    private(set) var lastDetectionDate: Date? = nil
    private(set) var capturedFreqMin: Double = 0
    private(set) var capturedFreqMax: Double = 0
    private(set) var capturedPeakFreq: Double = 0     // dominant frequency of the call
    private(set) var capturedDurationMs: Double = 0
    private(set) var pulseCount: Int = 0              // total pulses detected this session
    private(set) var pulseRateHz: Double = 0          // recent calls per second

    /// Detection timestamps within the rate window, used to compute `pulseRateHz`.
    private var recentDetections: [Date] = []
    private let rateWindowSeconds: TimeInterval = 5

    /// Clears the session counters (count, rate, last capture).
    func resetStats() {
        pulseCount = 0
        pulseRateHz = 0
        recentDetections.removeAll()
        lastPulseImage = nil
        lastDetectionDate = nil
        capturedFreqMin = 0
        capturedFreqMax = 0
        capturedPeakFreq = 0
        capturedDurationMs = 0
    }

    // MARK: Private state

    // Pulse-run state machine. A "run" begins on the first above-threshold column
    // and survives short dips (up to maxGapMs) until `belowRun` exceeds the gap.
    private var inPulseRun = false
    private var runColumns = 0      // total columns since the run started (incl. bridged dips)
    private var aboveColumns = 0    // above-threshold columns in the run (validates min duration)
    private var belowRun = 0        // current streak of consecutive below-threshold columns
    private var columnsSinceLastDetection: Int = Int.max / 2
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "bat.PulseDetector.capture",
                                             qos: .userInitiated)

    // Deferred capture: when a pulse ends we don't snapshot immediately, because
    // the buffer doesn't yet hold the trailing columns needed to place the onset
    // at exactly `onsetFraction`. We remember the onset's absolute column index and
    // wait until enough columns have been recorded, THEN snapshot — so the onset
    // lands in the same spot every time instead of drifting with pulse length.
    private var pendingCapture = false
    private var pendingOnsetIndex = 0     // absolute index (totalWritten-based) of the onset column
    private var pendingContentLength = 0
    private var pendingWaitFeeds = 0      // safety: force capture if appends stall (triggered mode)

    // MARK: Feed (main thread — called once per drained FFT column)

    func feed(peakLevel: Float,
              peakFrequency: Double,
              history: HistoryBuffer,
              columnsPerSecond: Double,
              sampleRate: Double,
              dbRange: Double) {

        columnsSinceLastDetection += 1
        let holdOffColumns = max(1, Int(holdOffSeconds * columnsPerSecond))
        let gapColumns = max(1, Int(maxGapMs / 1000 * columnsPerSecond))

        let aboveThreshold: Bool
        switch triggerMode {
        case .amplitude:
            aboveThreshold = peakLevel >= amplitudeThreshold
        case .ultrasonic:
            aboveThreshold = peakLevel >= amplitudeThreshold
                          && peakFrequency >= minFrequencyHz
        }

        if aboveThreshold {
            if !inPulseRun {            // rising edge — start a new run
                inPulseRun = true
                runColumns = 0
                aboveColumns = 0
            }
            runColumns += 1
            aboveColumns += 1
            belowRun = 0
        } else if inPulseRun {
            runColumns += 1
            belowRun += 1
            if belowRun > gapColumns {  // gap too long — the run has ended
                // The trailing `belowRun` columns are silent tail; the call content
                // spans `contentLen` columns ending `belowRun` columns back.
                let contentLen = runColumns - belowRun
                if aboveColumns >= minConsecutiveColumns,
                   columnsSinceLastDetection >= holdOffColumns,
                   contentLen > 0,
                   !pendingCapture, !isCapturing {
                    // Arm a deferred capture. The onset sits `onsetStepsBack` columns
                    // behind the newest; record its absolute index so we can snapshot
                    // once enough trailing columns exist.
                    let onsetStepsBack = belowRun + contentLen - 1   // == runColumns - 1
                    pendingOnsetIndex = history.totalWritten - 1 - onsetStepsBack
                    pendingContentLength = contentLen
                    pendingWaitFeeds = 0
                    pendingCapture = true
                    columnsSinceLastDetection = 0
                }
                inPulseRun = false
                runColumns = 0
                aboveColumns = 0
                belowRun = 0
            }
        }

        // Fire a deferred capture once the trailing context has accumulated (or the
        // append stream stalls, e.g. in triggered display mode after the hold-off).
        if pendingCapture {
            pendingWaitFeeds += 1
            let totalCols = max(16, Int(displayWindowMs / 1000 * columnsPerSecond))
            let leadCols  = Int(onsetFraction * Double(totalCols))
            let targetTrailing = max(0, totalCols - 1 - leadCols)
            let onsetStepsBack = (history.totalWritten - 1) - pendingOnsetIndex
            // Ready when the onset is far enough back, or as a safety net if appends
            // have stalled (triggered mode) so we don't wait forever. The +8 margin
            // keeps the normal path winning in continuous mode.
            if onsetStepsBack >= targetTrailing || pendingWaitFeeds > targetTrailing + 8 {
                pendingCapture = false
                scheduleCapture(history: history,
                                columnsPerSecond: columnsPerSecond,
                                sampleRate: sampleRate,
                                dbRange: dbRange,
                                onsetStepsBack: onsetStepsBack,
                                contentLength: pendingContentLength)
            }
        }

        // Update for next column — renderer reads this before calling feed().
        // Stays true through bridged dips so those columns are still recorded.
        isInPulse = inPulseRun
               || columnsSinceLastDetection <= holdOffColumns
    }

    // MARK: Capture (main thread → background)

    private func scheduleCapture(history: HistoryBuffer,
                                 columnsPerSecond: Double,
                                 sampleRate: Double,
                                 dbRange: Double,
                                 onsetStepsBack: Int,
                                 contentLength: Int) {
        guard !isCapturing else { return }
        isCapturing = true

        let bins = history.binCount
        guard bins > 0 else { isCapturing = false; return }

        // Fixed-width window: every capture is the same number of columns, so the
        // pulse always renders at the same scale and lands at the same place.
        let totalCols = max(16, Int(displayWindowMs / 1000 * columnsPerSecond))
        let leadCols  = Int(onsetFraction * Double(totalCols))   // target onset column

        // `rowMajorSlice` counts `offset` columns back from the newest sample.
        // The pulse onset sits `onsetStepsBack` columns back; choose `offset` so it
        // falls at `leadCols` from the window's left edge. The deferred-capture logic
        // waits until there's enough trailing context that `offset` resolves to ~0
        // and the onset lands exactly at `leadCols`. Clamps only in the rare stall case.
        let offset = max(0, onsetStepsBack + leadCols - (totalCols - 1))

        // Read the ring on the main thread — produces a plain [Float] safe
        // to hand to the background queue.
        let floats = history.rowMajorSlice(offset: offset, count: totalCols)
        guard floats.count == totalCols * bins else { isCapturing = false; return }

        // Window-relative pulse extent (= leadCols..leadCols+contentLength when unclamped).
        let pulseStart = max(0, (offset + totalCols - 1) - onsetStepsBack)
        let pulseEnd   = min(totalCols, pulseStart + contentLength)
        let cps = columnsPerSecond
        let sr  = sampleRate
        let floor = pulseNoiseFloor
        let range = dbRange

        captureQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.renderImage(floats: floats,
                                         totalCols: totalCols,
                                         bins: bins,
                                         pulseColStart: pulseStart,
                                         pulseColEnd: pulseEnd,
                                         columnsPerSecond: cps,
                                         sampleRate: sr,
                                         noiseFloor: floor,
                                         dbRange: range)
            DispatchQueue.main.async {
                if let r = result {
                    let now = Date()
                    self.lastPulseImage    = r.image
                    self.lastDetectionDate = now
                    self.capturedFreqMin   = r.freqMin
                    self.capturedFreqMax   = r.freqMax
                    self.capturedPeakFreq  = r.peakFreq
                    self.capturedDurationMs = r.durationMs
                    self.pulseCount += 1

                    // Rate = detections per second over the trailing window.
                    self.recentDetections.append(now)
                    self.recentDetections.removeAll { now.timeIntervalSince($0) > self.rateWindowSeconds }
                    if let first = self.recentDetections.first,
                       self.recentDetections.count > 1 {
                        let span = now.timeIntervalSince(first)
                        self.pulseRateHz = span > 0 ? Double(self.recentDetections.count - 1) / span : 0
                    } else {
                        self.pulseRateHz = 0
                    }
                }
                self.isCapturing = false
            }
        }
    }

    // MARK: Image rendering (background thread — no @Observable access)

    private struct RenderResult {
        let image: UIImage
        let freqMin, freqMax, peakFreq, durationMs: Double
    }

    private static func renderImage(floats: [Float],
                                    totalCols: Int,
                                    bins: Int,
                                    pulseColStart: Int,
                                    pulseColEnd: Int,
                                    columnsPerSecond: Double,
                                    sampleRate: Double,
                                    noiseFloor: Float,
                                    dbRange: Double) -> RenderResult? {

        // Values in `floats` are normalised in dB space over `dbRange` (maxDB−minDB),
        // so a fixed dB-below-peak threshold is a *fractional* offset in [0,1] space.
        // Using a ratio (×0.5) instead would correspond to ~half the dB range below
        // peak (e.g. −35 dB) and would sweep in reverberation/echo tails.
        let range = Float(max(dbRange, 1))
        func normOffset(_ dbDown: Float) -> Float { dbDown / range }
        let freqDbDown: Float = 15   // bandwidth crop extent below peak
        let durDbDown:  Float = 12   // call-duration extent below peak

        // Noise gate + contrast stretch: values below `noiseFloor` become 0; the
        // [floor, 1] range is rescaled to [0, 1] so the pulse uses the full colormap.
        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        func gate(_ t: Float) -> Float { max(0, (t - floor) * invSpan) }

        // Find peak value (and its bin → dominant frequency) across pulse columns.
        var peakValue: Float = 0
        var peakBin = 0
        for bin in 0..<bins {
            for col in pulseColStart..<pulseColEnd {
                let v = floats[bin * totalCols + col]
                if v > peakValue { peakValue = v; peakBin = bin }
            }
        }
        // Crop to bins within `freqDbDown` of the peak, never below the noise floor.
        let freqThreshold = max(0.05, max(peakValue - normOffset(freqDbDown), floor))

        // Find the frequency extent of the call.
        var minBin = bins - 1
        var maxBin = 0
        for bin in 0..<bins {
            for col in pulseColStart..<pulseColEnd {
                if floats[bin * totalCols + col] >= freqThreshold {
                    if bin < minBin { minBin = bin }
                    if bin > maxBin { maxBin = bin }
                }
            }
        }
        if minBin > maxBin { minBin = 0; maxBin = bins - 1 }

        // Measure call duration from the energy envelope, not the trigger count.
        // Find the loudest column, then expand left/right while the column's peak
        // stays within `durDbDown` of the call peak. dB-relative (not a ratio in the
        // compressed 0–1 space) so a 10 ms pulse reads ~10 ms instead of sweeping in
        // its reverb tail; independent of the amplitude trigger threshold.
        func columnPeak(_ col: Int) -> Float {
            var m: Float = 0
            for bin in 0..<bins {
                let v = floats[bin * totalCols + col]
                if v > m { m = v }
            }
            return m
        }
        var peakCol = pulseColStart
        var peakColVal: Float = 0
        for col in pulseColStart..<pulseColEnd {
            let m = columnPeak(col)
            if m > peakColVal { peakColVal = m; peakCol = col }
        }
        let durThreshold = max(0.05, max(peakColVal - normOffset(durDbDown), floor))
        var durStart = peakCol, durEnd = peakCol
        while durStart - 1 >= 0, columnPeak(durStart - 1) >= durThreshold { durStart -= 1 }
        while durEnd + 1 < totalCols, columnPeak(durEnd + 1) >= durThreshold { durEnd += 1 }
        let durationCols = durEnd - durStart + 1

        let binBuf  = max(8, (maxBin - minBin + 1) / 4)
        let cropMin = max(0, minBin - binBuf)
        let cropMax = min(bins - 1, maxBin + binBuf)
        let cropBins = cropMax - cropMin + 1

        var pixels = [UInt8](repeating: 255, count: totalCols * cropBins * 4)
        for bin in cropMin...cropMax {
            let yFlipped = cropMax - bin
            for col in 0..<totalCols {
                let t = gate(floats[bin * totalCols + col])
                let (r, g, b) = colormap(t)
                let idx = (yFlipped * totalCols + col) * 4
                pixels[idx]     = r
                pixels[idx + 1] = g
                pixels[idx + 2] = b
                pixels[idx + 3] = 255
            }
        }

        guard
            let provider = CGDataProvider(data: Data(pixels) as CFData),
            let cgImage = CGImage(
                width: totalCols, height: cropBins,
                bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: totalCols * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent)
        else { return nil }

        let hzPerBin = (sampleRate / 2) / Double(bins)
        return RenderResult(
            image: UIImage(cgImage: cgImage),
            freqMin: Double(cropMin) * hzPerBin,
            freqMax: Double(cropMax) * hzPerBin,
            peakFreq: Double(peakBin) * hzPerBin,
            // Call length from the energy envelope (−6 dB extent around the peak),
            // not the trigger column count which jitters with the amplitude threshold.
            durationMs: Double(durationCols) / columnsPerSecond * 1000
        )
    }

    // MARK: Inferno colormap (mirrors Spectrogram.metal)

    private static func colormap(_ t: Float) -> (UInt8, UInt8, UInt8) {
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
