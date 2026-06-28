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
    private(set) var lastClassification: ClassificationResult? = nil

    /// The aggregated ID for the most recently completed pass (multi-pulse).
    /// Updated when silence exceeds `passTimeoutSeconds` after the last detected pulse.
    private(set) var lastPassResult: ClassificationResult? = nil
    /// How many pulses contributed to `lastPassResult`.
    private(set) var lastPassPulseCount: Int = 0

    /// Silence gap (seconds) after the last pulse that closes a pass and fires the aggregated ID.
    var passTimeoutSeconds: Double = 2.0

    /// Detection timestamps within the rate window, used to compute `pulseRateHz`.
    private var recentDetections: [Date] = []
    private let rateWindowSeconds: TimeInterval = 5

    /// Supplier of raw PCM for the classifier. Wire to SpectrogramProcessor.pcmSnapshot.
    /// Called on the main thread. Parameters: (sampleCount, startSamplesBack).
    var pcmProvider: ((_ count: Int, _ startSamplesBack: Int) -> [Float])?

    /// AutoID settings — when set, prior weights and pass thresholds come from here.
    var autoIDSettings: AutoIDSettings?

    /// Persistent history of completed passes (Sessions tab). Optional so the
    /// detector still works without it.
    var store: ClassificationStore?

    // MARK: Pass accumulator (main thread)

    private var passScores: [String: Float] = [:]   // running sum across pulses in current pass
    private var passPulseCount: Int = 0
    private var passPulses: [CapturedPulse] = []     // per-pulse detail for the history

    /// Record one classified pulse into the running pass: accumulate its scores and
    /// keep its detail (species, confidence, thumbnail) for the Sessions history.
    private func accumulatePulse(_ captured: CapturedPulse, scores: [String: Float]) {
        for (species, score) in scores {
            passScores[species, default: 0] += score
        }
        passPulseCount += 1
        passPulses.append(captured)
    }

    /// Close the current pass, if any (called on the silence timeout and on stop).
    func finalizePass() {
        defer {
            passScores = [:]
            passPulseCount = 0
            passPulses = []
        }
        guard passPulseCount > 0 else { return }

        // Pick winner from summed adjusted scores, excluding NOISE unless it's the only option.
        let candidates = passScores.filter { $0.key != "NOISE" }
        let pool = candidates.isEmpty ? passScores : candidates
        guard let best = pool.max(by: { $0.value < $1.value }) else { return }

        // Mean posterior across pulses. passScores are per-pulse renormalized posteriors
        // (each pulse sums to 1), so dividing the running sum by the pulse count yields a
        // proper mean posterior — and the full vector still sums to 1.
        let n = Float(passPulseCount)
        let meanConf = best.value / n

        // Suppress very low-confidence results (noise floor bleed across pulses).
        let minConf = autoIDSettings?.minPassConfidence ?? 0.05
        guard passPulseCount >= (autoIDSettings?.minPassPulseCount ?? 1) else { return }
        guard meanConf >= minConf else { return }

        let meanScores = passScores.mapValues { $0 / n }
        let passResult = ClassificationResult(
            species: best.key,
            confidence: meanConf,
            allScores: meanScores
        )
        lastPassResult = passResult
        lastPassPulseCount = passPulseCount
        ClassificationLogger.shared.logPass(passResult, pulseCount: passPulseCount)

        // Persist to the Sessions history with per-pulse detail.
        store?.addPass(species: best.key,
                       confidence: meanConf,
                       pulses: passPulses)
    }

    /// Clears the session counters (count, rate, last capture).
    func resetStats() {
        pulseCount = 0
        pulseRateHz = 0
        recentDetections.removeAll()
        lastPulseImage = nil
        lastDetectionDate = nil
        lastClassification = nil
        lastPassResult = nil
        lastPassPulseCount = 0
        passScores = [:]
        passPulseCount = 0
        passPulses = []
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

    // Deferred capture: when a pulse ends we don't snapshot immediately, because the
    // PCM ring doesn't yet hold the trailing audio needed to place the onset at exactly
    // `onsetFraction`. We remember how many columns back the onset was *at arm time* and
    // count feeds since, then snapshot once enough trailing context exists — so the onset
    // lands in the same spot every time instead of drifting with pulse length.
    //
    // Distance is tracked in FEEDS (one feed = one drained FFT column = `samplesPerCol`
    // samples), NOT in `history.totalWritten`. feed() is called per column regardless of
    // triggered-display mode, but the history stops growing during silence in that mode;
    // the PCM ring (which the pulse image is rendered from) keeps advancing, so the
    // feed counter is the unit that stays consistent with it.
    private var pendingCapture = false
    private var pendingOnsetStepsBack = 0   // columns from newest back to the onset, at arm time
    private var pendingContentLength = 0
    private var pendingWaitFeeds = 0        // feeds elapsed since arming

    private let classifier = try? BatClassifier()

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

        // Close the current pass once silence exceeds the timeout.
        let effectiveTimeout = autoIDSettings?.passTimeoutSeconds ?? passTimeoutSeconds
        let passTimeoutCols = Int(effectiveTimeout * columnsPerSecond)
        if passPulseCount > 0 && columnsSinceLastDetection > passTimeoutCols {
            finalizePass()
        }

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
                    // behind the newest right now; we then count feeds until enough
                    // trailing context exists to place it at `onsetFraction`.
                    pendingOnsetStepsBack = belowRun + contentLen - 1   // == runColumns - 1
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

        // Fire a deferred capture once the onset has scrolled far enough back that the
        // window's trailing portion ((1 − onsetFraction) of it) is fully available.
        if pendingCapture {
            // Feeds since the onset = its arm-time distance plus feeds waited. This
            // advances every column even in triggered mode, staying in lockstep with
            // the PCM ring the image is rendered from.
            let feedsSinceOnset = pendingOnsetStepsBack + pendingWaitFeeds
            let totalCols = max(16, Int(displayWindowMs / 1000 * columnsPerSecond))
            let leadCols  = Int(onsetFraction * Double(totalCols))
            // totalCols − leadCols (NOT −1): makes feedsSinceOnset*samplesPerCol reach
            // exactly (1−onsetFraction)*windowSamples so the onset lands precisely at
            // onsetFraction with no clamp drift.
            let targetTrailing = max(0, totalCols - leadCols)
            if feedsSinceOnset >= targetTrailing || pendingWaitFeeds > targetTrailing + 8 {
                pendingCapture = false
                scheduleCapture(history: history,
                                columnsPerSecond: columnsPerSecond,
                                sampleRate: sampleRate,
                                dbRange: dbRange,
                                onsetStepsBack: feedsSinceOnset,
                                contentLength: pendingContentLength)
            } else {
                pendingWaitFeeds += 1
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

        guard history.binCount > 0 else { isCapturing = false; return }

        let cps = columnsPerSecond
        let sr  = sampleRate
        let floor = pulseNoiseFloor
        let minFreq = minFrequencyHz
        let samplesPerCol = max(1, Int(sr / cps))
        // Samples from the current write head back to the pulse onset.
        let onsetBackSamples = onsetStepsBack * samplesPerCol

        // pcmSnapshot(count, startBack) returns `count` samples ENDING `startBack`
        // samples before the head. To place the onset at fraction `frac` from the
        // window's left edge, the window must end `(1-frac)*count` samples after the
        // onset, i.e. startBack = onsetBack - (1-frac)*count.  (The previous code
        // omitted the `- count` term and captured the window *before* the call.)
        func startBack(count: Int, onsetFrac: Double) -> Int {
            max(0, onsetBackSamples - Int(Double(count) * (1 - onsetFrac)))
        }

        // Classification window: 50 ms NABat window with the onset ~30% in, so the
        // call peak lands well within the model's expected 20–80% band.
        let clsCount = max(19_200, Int(0.05 * sr))
        let clsPCM   = pcmProvider?(clsCount, startBack(count: clsCount, onsetFrac: 0.30)) ?? []

        // Display window: the full zoom span, onset locked at `onsetFraction`, rendered
        // at high resolution from PCM (much sharper than the coarse display history).
        let dispCount = max(PulseImageRenderer.fftSize + PulseImageRenderer.hop,
                            Int(displayWindowMs / 1000 * sr))
        let dispPCM   = pcmProvider?(dispCount, startBack(count: dispCount, onsetFrac: onsetFraction)) ?? []

        // Snapshot prior weights + quality gate on the main thread so the background
        // queue reads plain value types, not the @Observable settings object.
        let priorSnapshot: [String: Float]
        if let s = autoIDSettings {
            priorSnapshot = BatClassifier.classNames.reduce(into: [:]) { d, code in
                d[code] = s.effectivePrior(for: code)
            }
        } else {
            priorSnapshot = BatClassifier.bcPrior
        }
        let gate = autoIDSettings?.qualityGate ?? QualityGate()

        let cls = classifier

        captureQueue.async { [weak self] in
            guard let self else { return }
            let result = PulseImageRenderer.render(pcm: dispPCM,
                                                   sampleRate: sr,
                                                   noiseFloor: floor,
                                                   minFrequencyHz: minFreq)
            // Classification runs in parallel with image rendering on the same queue.
            let classification: ClassificationResult? = clsPCM.count >= clsCount
                ? cls?.classify(pcm: clsPCM, gate: gate, prior: { priorSnapshot[$0] ?? 1.0 })
                : nil

            DispatchQueue.main.async {
                if let r = result {
                    let now = Date()
                    self.lastPulseImage     = r.image
                    self.lastDetectionDate  = now
                    self.capturedFreqMin    = r.freqMin
                    self.capturedFreqMax    = r.freqMax
                    self.capturedPeakFreq   = r.peakFreq
                    self.capturedDurationMs = r.durationMs
                    self.pulseCount += 1

                    if let c = classification {
                        self.lastClassification = c
                        let top = c.allScores.sorted { $0.value > $1.value }
                            .prefix(6)
                            .map { ScoreEntry(species: $0.key, score: $0.value) }
                        let captured = CapturedPulse(date: now,
                                                     species: c.species,
                                                     confidence: c.confidence,
                                                     peakFreqHz: r.peakFreq,
                                                     durationMs: r.durationMs,
                                                     topScores: top,
                                                     image: r.image)
                        self.accumulatePulse(captured, scores: c.allScores)
                        ClassificationLogger.shared.logPulse(c)
                    }

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

}
