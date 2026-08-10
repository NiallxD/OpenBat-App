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
//  with no silent gaps — a triggered view in the classic bat-detector style.
//

import UIKit
import Observation
import CoreLocation

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
    /// Minimum gap between detections. Field data (Bat_Walk_27_06_2026) shows a
    /// median inter-pulse gap of ~79 ms, so the old 150 ms default silently dropped
    /// more than half of a normal pass's calls — starving both the pulse-rate readout
    /// and the classifier. 50 ms passes typical call spacing while still rejecting the
    /// closest echoes; amplitude does the rest (echoes return much quieter).
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
    /// always locked at `onsetFraction` from the left — one pulse, same place, every
    /// time. ~10 ms is the sweet spot for resolving a single bat call's structure.
    var displayWindowMs: Double = 10 {
        didSet { defaults.set(displayWindowMs, forKey: Key.displayWindowMs) }
    }
    /// Brightness gate applied to the captured pulse image (0–1). Pixels below this
    /// are rendered black; the remaining range is stretched to use the full
    /// colormap, so only the high-energy pulse shows and the background haze is
    /// removed. Raise to strip more noise; 0 disables the gate.
    var pulseNoiseFloor: Float = 0.35 {
        didSet { defaults.set(pulseNoiseFloor, forKey: Key.pulseNoiseFloor) }
    }
    /// Same brightness gate as `pulseNoiseFloor`, applied independently to the live
    /// scrolling spectrogram (Spectrogram.metal's noiseFloor uniform) instead of
    /// sharing one setting across both views — the pulse zoom and the live view
    /// often want different amounts of noise stripped (a tight pulse crop can take
    /// a higher floor than the live view without losing context).
    var spectrogramNoiseFloor: Float = 0.35 {
        didSet { defaults.set(spectrogramNoiseFloor, forKey: Key.spectrogramNoiseFloor) }
    }
    /// Display colormap, shared by the live spectrogram (GPU) and the pulse-view
    /// image + thumbnails (CPU) — see `DisplayPalette.swift`.
    var displayPalette: Palette = .inferno {
        didSet { defaults.set(displayPalette.rawValue, forKey: Key.displayPalette) }
    }
    /// When true the renderer skips uploading silent columns to the ring buffer,
    /// so the spectrogram fills with back-to-back pulses instead of continuous audio.
    var triggeredDisplayMode: Bool = false {
        didSet { defaults.set(triggeredDisplayMode, forKey: Key.triggeredDisplayMode) }
    }
    /// Minimum seconds between pulse display updates. Detection and rate counting
    /// still happen every pulse; this only throttles how often the zoom image and
    /// frequency stats refresh. 0 = update on every pulse.
    var displayRefreshIntervalSeconds: Double = 2.0 {
        didSet { defaults.set(displayRefreshIntervalSeconds, forKey: Key.displayRefreshIntervalSeconds) }
    }

    /// Pulse onset position within the fixed window (fraction from the left edge).
    /// Read by ContentView's pulse grid so the onset marker stays aligned.
    let onsetFraction = 0.25

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
        static let triggeredDisplayMode              = "pulse.triggeredDisplayMode"
        static let pulseNoiseFloor                   = "pulse.pulseNoiseFloor"
        static let spectrogramNoiseFloor             = "pulse.spectrogramNoiseFloor"
        static let displayPalette                    = "pulse.displayPalette"
        static let displayRefreshIntervalSeconds     = "pulse.displayRefreshIntervalSeconds"
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
            // Clamp: an older build saved 80 ms, outside the current 6–40 ms range.
            displayWindowMs = min(max(defaults.double(forKey: Key.displayWindowMs), 6), 40)
        }
        if defaults.object(forKey: Key.triggeredDisplayMode) != nil {
            triggeredDisplayMode = defaults.bool(forKey: Key.triggeredDisplayMode)
        }
        if defaults.object(forKey: Key.pulseNoiseFloor) != nil {
            pulseNoiseFloor = defaults.float(forKey: Key.pulseNoiseFloor)
        }
        if defaults.object(forKey: Key.spectrogramNoiseFloor) != nil {
            spectrogramNoiseFloor = defaults.float(forKey: Key.spectrogramNoiseFloor)
        }
        if defaults.object(forKey: Key.displayPalette) != nil,
           let p = Palette(rawValue: defaults.integer(forKey: Key.displayPalette)) {
            displayPalette = p
        }
        if defaults.object(forKey: Key.displayRefreshIntervalSeconds) != nil {
            displayRefreshIntervalSeconds = defaults.double(forKey: Key.displayRefreshIntervalSeconds)
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
    /// Hz bounds of the rendered `lastPulseImage` itself (the full allowed band) —
    /// wider than `capturedFreqMin`/`capturedFreqMax`, which is just the default
    /// view's tight crop. Lets the pulse view pinch-zoom out to reveal spectral
    /// context beyond the crop instead of being capped at the crop's own edges.
    private(set) var capturedWideFreqMin: Double = 0
    private(set) var capturedWideFreqMax: Double = 0
    /// Where the default time window sits within `lastPulseImage`'s width (0…1
    /// fraction) — lets the pulse view pan left/right into the extra captured
    /// context around the call, same idea as the wide-frequency pair above.
    private(set) var capturedTimeTightLeftFrac: Double = 0
    private(set) var capturedTimeTightRightFrac: Double = 1
    private(set) var capturedPeakFreq: Double = 0     // dominant frequency of the call
    private(set) var capturedDurationMs: Double = 0
    /// Wall-clock time of the most recent display update (image + freq stats refresh).
    /// Used to enforce displayRefreshIntervalSeconds.
    private var lastDisplayUpdate: Date? = nil
    /// Quality of the pulse currently on screen. Within the same refresh window,
    /// a new capture only updates the display if its quality exceeds this.
    private var displayWindowQuality: Float = 0
    private(set) var pulseCount: Int = 0              // total pulses detected this session
    private(set) var pulseRateHz: Double = 0          // recent calls per second
    private(set) var lastClassification: ClassificationResult? = nil

    /// The aggregated ID for the most recently completed pass (multi-pulse).
    /// Updated when silence exceeds `passTimeoutSeconds` after the last detected pulse.
    private(set) var lastPassResult: ClassificationResult? = nil
    /// How many pulses contributed to `lastPassResult`.
    private(set) var lastPassPulseCount: Int = 0
    /// When `lastPassResult` was produced — drives the stale-ID indicator in the UI.
    private(set) var lastPassDate: Date? = nil

    /// Silence gap (seconds) after the last pulse that closes a pass and fires the aggregated ID.
    var passTimeoutSeconds: Double = 2.0

    /// Detection timestamps within the rate window, used to compute `pulseRateHz`.
    private var recentDetections: [Date] = []
    private let rateWindowSeconds: TimeInterval = 5

    /// Supplier of raw PCM for capture/classification. Wire to
    /// `SpectrogramProcessor.pcmSnapshot(count:endingAtAbsolute:)`. Called on the main
    /// thread. Returns `count` samples ending at absolute stream index `endAbsolute`
    /// (exclusive). Absolute anchoring is what keeps the captured pulse rock-steady:
    /// the window is pinned to sample positions, not to how columns happen to batch.
    var pcmProvider: ((_ count: Int, _ endAbsolute: Int) -> [Float])?

    /// Called on the main thread at the rising edge of each new pulse run, with the
    /// peak frequency (Hz) and normalised peak level (0–1, the `amplitudeThreshold`
    /// scale) of the triggering column. Use this to open the heterodyne gate and
    /// snap the LO immediately — don't wait for the 67 ms stats timer.
    ///
    /// The level is here for `PulseHaptics`, which maps it to haptic intensity;
    /// the rising edge is the only callback early enough for a haptic to feel
    /// simultaneous with the call.
    var onPulseStart: ((Double, Float) -> Void)?


    /// Fires for EVERY valid pulse with the call's absolute sample window
    /// (onset, length). Unlike the capture path this is not rate-limited, so it
    /// keeps up with pulses that render+classify drops.
    ///
    /// The length is `contentLen` columns — the trailing silence of the run is
    /// already subtracted — so it can be used as a call boundary directly. A
    /// level gate cannot produce this: the echo after a call sits 10–30 dB above
    /// the noise floor and decays smoothly out of the call, so amplitude
    /// thresholds do not separate them.
    ///
    /// **Currently unset.** Its only subscriber was the withdrawn live variable
    /// time distortion mode (see `Quarantine/VariableTimeDistortion/`). Kept
    /// because the boundary it reports is detector output, not expansion
    /// machinery, and computing it costs nothing.
    var onPulseWindow: ((Int, Int) -> Void)?

    /// Called on the main thread whenever a single pulse finishes classification, with
    /// the full result (raw + prior-adjusted scores) and its capture date. Wire to
    /// `AudioRecorder.addClassifiedPulse` so recorded WAVs can carry a `Species Auto
    /// ID` in their GUANO chunk, computed with the same `PassAggregation` rule as
    /// in-app passes — classification is per-pulse and async, independent of the
    /// recorder's own segment boundaries.
    var onPulseClassified: ((ClassificationResult, Date) -> Void)?

    /// Called on the main thread whenever `isInPulse` changes. Wire to
    /// `AudioRecorder.setPulseActive` directly instead of observing `isInPulse` from a
    /// top-level SwiftUI `.onChange` — that would invalidate the whole view body on
    /// every pulse edge.
    var onPulseActiveChanged: ((Bool) -> Void)?

    /// AutoID settings — when set, the active model, prior weights and pass thresholds
    /// come from here. Assigning warm-loads the active model so the first pulse after
    /// wiring doesn't pay the CoreML load cost on the capture path.
    var autoIDSettings: AutoIDSettings? {
        didSet { _ = activeClassifier() }
    }

    /// Persistent history of completed passes (Sessions tab). Optional so the
    /// detector still works without it.
    var store: ClassificationStore?

    /// Active session a finished pass attaches to (nil = Listening bucket), and a
    /// supplier of the current GPS coordinate to pin it on the session map. Set from
    /// ContentView when a "New Session" run begins.
    var activeSessionID: UUID?
    var coordinateProvider: (() -> CLLocationCoordinate2D?)?

    /// Called on the main thread after a pass closes, whatever its outcome (species,
    /// NOISE, or NoID). Set by ContentView to push the lock-screen Live Activity.
    ///
    /// Deliberately a callback rather than the Live Activity observing this object: a
    /// pass ending is a discrete event, and the alternative — polling `@Observable`
    /// state on a timer — would either miss passes or burn the ActivityKit update
    /// budget guessing when one happened. Same shape as `coordinateProvider` above.
    var onPassFinalized: (() -> Void)?

    // MARK: Pass accumulator (main thread)

    private var passAggPulses: [PassAggregation.Pulse] = []   // raw + adjusted scores, one per pulse
    private var passPulseCount: Int = 0
    private var passPulses: [CapturedPulse] = []     // per-pulse detail for the history

    /// Count of pulses whose capture has fired but whose (slow, CoreML-driven)
    /// classification hasn't returned yet. `feed()`'s silence-timeout defers
    /// `finalizePass()` while this is nonzero — otherwise a classification that
    /// takes longer than `passTimeoutSeconds` (e.g. a cold model load, or a busy
    /// device) arrives AFTER its pass already finalized and reset `passAggPulses`,
    /// so it gets misattributed as the start of a new, usually-NOID pass instead
    /// of counting toward the pass it actually belongs to.
    private var pendingClassifications: Int = 0

    /// Record one classified pulse into the running pass: keep its raw + adjusted
    /// scores for pass-level aggregation, and its detail (species, confidence,
    /// thumbnail) for the Sessions history.
    private func accumulatePulse(_ captured: CapturedPulse, raw: [String: Float], adjusted: [String: Float]) {
        passAggPulses.append(.init(rawScores: raw, adjustedScores: adjusted))
        passPulseCount += 1
        passPulses.append(captured)
    }

    /// Close the current pass, if any (called on the silence timeout and on stop).
    /// Outcome (species / NOISE / nothing at all) is decided by `PassAggregation`,
    /// matching the NABat-ml reference pipeline's NoID/NOISE/species rule — see
    /// PassAggregation.swift. A pass that comes back nil (NoID: mean raw confidence
    /// below threshold) records nothing, same as before.
    func finalizePass() {
        defer {
            passAggPulses = []
            passPulseCount = 0
            passPulses = []
            // Let the next pass claim the zoom panel with its first good pulse instead
            // of being blocked by the quality of a pulse from the pass that just ended.
            displayWindowQuality = 0
        }
        guard passPulseCount > 0 else { return }

        // Fires on every exit below — the NoID early return as well as the normal end.
        // Both are real passes: even when the classifier declines to name one, the pulse
        // count and last-pulse stats have moved, and the Live Activity should say so.
        defer { onPassFinalized?() }

        let descriptor = activeClassifier()?.descriptor
        guard let outcome = PassAggregation.aggregate(
            passAggPulses,
            minAdjustedConfidence: autoIDSettings?.minPassConfidence ?? 0.05,
            minPulseCount: autoIDSettings?.minPassPulseCount ?? 1,
            rawConfidenceThreshold: descriptor?.noidRawConfidenceThreshold ?? PassAggregation.noidRawConfidenceThreshold,
            noiseClassName: descriptor?.noiseClassName
        ) else {
            // NoID: pulses were captured and classified, but the pass never cleared
            // the confidence gates for a species OR the noise class. Previously this
            // pass just vanished with no trace; recording it as its own "NOID" species
            // lets the ID list show "something triggered, we couldn't tell what" instead
            // of silently dropping evidence the user did see/hear.
            store?.addPass(species: "NOID", confidence: 0, pulses: passPulses,
                           sessionID: activeSessionID,
                           coordinate: activeSessionID != nil ? coordinateProvider?() : nil)
            return
        }

        let passResult = ClassificationResult(
            species: outcome.species,
            confidence: outcome.confidence,
            allScores: outcome.meanScores
        )
        lastPassResult = passResult
        lastPassPulseCount = passPulseCount
        lastPassDate = Date()
        ClassificationLogger.shared.logPass(passResult, pulseCount: passPulseCount,
                                            modelID: autoIDSettings?.activeModelID)

        // Second-place species by mean posterior — surfaced as a runner-up suggestion
        // in the species feed. Not meaningful for a NOISE outcome (its meanScores are
        // raw, not the prior-adjusted species pool), so skip it there.
        let runnerUp = outcome.species == "NOISE" ? nil
            : outcome.meanScores.filter { $0.key != outcome.species }.max(by: { $0.value < $1.value })

        // Complex membership: does the classifying model admit that the winning species
        // is one it can't cleanly separate? And is the runner-up a complex-mate running
        // close enough to make this an *active* ambiguity? Both are surfaced in the UI
        // so a confident-looking number isn't shown for a confusable species in silence.
        let complex = ModelRegistry.descriptor(id: autoIDSettings?.activeModelID)?
            .complex(for: outcome.species)
        let complexAmbiguous = complex.map { c in
            runnerUp.map { c.codes.contains($0.key)
                && (outcome.confidence - $0.value) < SpeciesComplex.ambiguityMargin } ?? false
        }

        // Persist to the Sessions history with per-pulse detail, tagged with the active
        // session and where it was heard (for the session map). Only attach a coordinate
        // for session passes — a Listening pass must never pick up a stale fix left in
        // the provider by a previous session (it also has no map to show it on).
        store?.addPass(species: outcome.species,
                       confidence: outcome.confidence,
                       pulses: passPulses,
                       sessionID: activeSessionID,
                       coordinate: activeSessionID != nil ? coordinateProvider?() : nil,
                       runnerUpSpecies: runnerUp?.key,
                       runnerUpConfidence: runnerUp?.value,
                       complexID: complex?.id,
                       complexAmbiguous: complexAmbiguous)
    }

    /// Clears the session counters (count, rate, last capture).
    func resetStats() {
        pulseCount = 0
        pulseRateHz = 0
        recentDetections.removeAll()
        lastPulseImage = nil
        lastDetectionDate = nil
        lastDisplayUpdate = nil
        displayWindowQuality = 0
        lastClassification = nil
        lastPassResult = nil
        lastPassPulseCount = 0
        lastPassDate = nil
        passAggPulses = []
        passPulseCount = 0
        passPulses = []
        capturedFreqMin = 0
        capturedFreqMax = 0
        capturedWideFreqMin = 0
        capturedWideFreqMax = 0
        capturedTimeTightLeftFrac = 0
        capturedTimeTightRightFrac = 1
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
    // PCM ring doesn't yet hold the trailing audio the display/classification windows
    // need. We record the onset's ABSOLUTE sample index (from the triggering column's
    // stamped `endSample`) and the absolute index we must wait for, then fire once the
    // stream has advanced past it. Anchoring by absolute sample — not by counting feeds
    // — removes the old jitter where the onset drifted with column-drain batching.
    private var pendingCapture = false
    private var pendingOnsetAbs = 0     // absolute sample index of the pulse onset
    private var pendingFireAbs = 0      // fire once columnEndSample reaches this
    private var pendingArmAbs = 0       // onset arm time, to bound how long we wait

    /// Trailing audio (seconds) held past the onset before a capture fires. Must cover
    /// every registered model's classification window (the trailing fraction after
    /// onset, `windowSeconds * (1 - onsetFraction)`) as well as the display window, so
    /// none of them are truncated — computed as a max over `ModelRegistry.all` (NABat:
    /// 50 ms @ 30% onset → 35 ms trailing; BatDetect2: 256 ms @ 30% onset → 179.2 ms
    /// trailing) rather than hardcoded, so adding a model with a longer window doesn't
    /// silently truncate its captures. ~5 ms slack on top.
    private var deferTrailSeconds: Double {
        let maxTrailing = ModelRegistry.all
            .map { $0.input.windowSeconds * (1 - $0.input.onsetFraction) }
            .max() ?? 0.055
        return maxTrailing + 0.005
    }

    // Active classifier, lazily built from the active model descriptor and cached
    // until the active model id changes.
    private var cachedModelID: String?
    private var cachedClassifier: SpeciesClassifier?

    /// Resolves (and caches) the classifier + descriptor for the active model, or nil
    /// when no model is active or it fails to load. Called on the main thread.
    private func activeClassifier() -> (classifier: SpeciesClassifier, descriptor: ModelDescriptor)? {
        guard let id = autoIDSettings?.activeModelID,
              let descriptor = ModelRegistry.descriptor(id: id) else {
            cachedModelID = nil
            cachedClassifier = nil
            return nil
        }
        if cachedModelID != id {
            cachedClassifier = descriptor.makeClassifier()
            cachedModelID = id
        }
        guard let classifier = cachedClassifier else { return nil }
        return (classifier, descriptor)
    }

    /// Warm-load the active model (e.g. after the user switches models in settings).
    func refreshModel() { _ = activeClassifier() }

    // MARK: Feed (main thread — called once per drained FFT column)

    func feed(peakLevel: Float,
              peakFrequency: Double,
              columnEndSample: Int,
              columnsPerSecond: Double,
              sampleRate: Double) {

        columnsSinceLastDetection += 1
        let samplesPerCol = max(1, Int(sampleRate / columnsPerSecond))
        let holdOffColumns = max(1, Int(holdOffSeconds * columnsPerSecond))
        let gapColumns = max(1, Int(maxGapMs / 1000 * columnsPerSecond))

        // Close the current pass once silence exceeds the timeout.
        let effectiveTimeout = autoIDSettings?.passTimeoutSeconds ?? passTimeoutSeconds
        let passTimeoutCols = Int(effectiveTimeout * columnsPerSecond)
        if passPulseCount > 0 && columnsSinceLastDetection > passTimeoutCols && pendingClassifications == 0 {
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
                onPulseStart?(peakFrequency, peakLevel)
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
                let isValidPulse = aboveColumns >= minConsecutiveColumns
                    && columnsSinceLastDetection >= holdOffColumns
                    && contentLen > 0
                if isValidPulse {
                    // Count EVERY real pulse and space detections by the holdoff —
                    // independent of whether the capture pipeline can keep up. A fast
                    // feeding buzz (100+/s) outruns render+classify, but the count and
                    // rate readouts must still reflect true pulse arrivals rather than
                    // capture throughput. See registerDetection().
                    registerDetection()
                    columnsSinceLastDetection = 0

                    // Publish the call window on the cheap path, before the
                    // capture rate-limit below can drop it.
                    if let onPulseWindow {
                        let stepsBack = belowRun + contentLen - 1
                        onPulseWindow(columnEndSample - stepsBack * samplesPerCol,
                                      contentLen * samplesPerCol)
                    }

                    // Only the EXPENSIVE work (deferred render + classify) is
                    // rate-limited: skip arming while a capture is already in flight,
                    // dropping frames on the thumbnail/classifier without dropping the
                    // count above.
                    if !pendingCapture, !isCapturing {
                        // Arm a deferred capture, anchored to the onset's absolute sample.
                        // The onset column sits `runColumns - 1` columns behind this one;
                        // each column advances the stream by `samplesPerCol` samples.
                        let onsetStepsBack = belowRun + contentLen - 1   // == runColumns - 1
                        pendingOnsetAbs = columnEndSample - onsetStepsBack * samplesPerCol
                        pendingFireAbs  = pendingOnsetAbs + Int(deferTrailSeconds * sampleRate)
                        pendingArmAbs   = columnEndSample
                        pendingCapture  = true
                    }
                }
                inPulseRun = false
                runColumns = 0
                aboveColumns = 0
                belowRun = 0
            }
        }

        // Fire the deferred capture once the stream has advanced past the onset by
        // `deferTrailSeconds`, so both the display and classification trailing windows
        // are fully present in the PCM ring. The escape hatch (waited far past the
        // target) guards against a stall if the stream hiccups.
        if pendingCapture {
            let waited = columnEndSample - pendingArmAbs
            if columnEndSample >= pendingFireAbs
                || waited > Int(deferTrailSeconds * sampleRate) + 8 * samplesPerCol {
                pendingCapture = false
                scheduleCapture(columnsPerSecond: columnsPerSecond,
                                sampleRate: sampleRate,
                                onsetAbs: pendingOnsetAbs)
            }
        }

        // Update for next column — renderer reads this before calling feed().
        // Stays true through bridged dips so those columns are still recorded.
        let wasInPulse = isInPulse
        isInPulse = inPulseRun
               || columnsSinceLastDetection <= holdOffColumns
        if isInPulse != wasInPulse { onPulseActiveChanged?(isInPulse) }
    }

    /// Records one detected pulse for the count + rate readouts. Called on the
    /// main thread for every validated trailing edge, whether or not a capture is
    /// armed for it — so the stats track true pulse arrivals, not the (much
    /// slower) render/classify throughput. Rate is detections per second over the
    /// trailing `rateWindowSeconds` window.
    private func registerDetection() {
        let now = Date()
        pulseCount += 1
        recentDetections.append(now)
        // Dates are appended in order, so expired entries are always a prefix —
        // scan only up to the first still-valid one instead of the full-array
        // predicate pass removeAll(where:) makes on every detection.
        let cutoff = now.addingTimeInterval(-rateWindowSeconds)
        let firstValid = recentDetections.firstIndex { $0 >= cutoff }
            ?? recentDetections.endIndex
        if firstValid > recentDetections.startIndex {
            recentDetections.removeFirst(firstValid)
        }
        if let first = recentDetections.first, recentDetections.count > 1 {
            let span = now.timeIntervalSince(first)
            pulseRateHz = span > 0 ? Double(recentDetections.count - 1) / span : 0
        } else {
            pulseRateHz = 0
        }
    }

    // MARK: Capture (main thread → background)

    private func scheduleCapture(columnsPerSecond: Double,
                                 sampleRate: Double,
                                 onsetAbs: Int) {
        guard !isCapturing else { return }
        isCapturing = true
        pendingClassifications += 1

        // This pulse's own wall-clock capture time — NOT `lastDetectionDate`, which is
        // display-only (gated by quality/refresh-window logic below) and can go several
        // pulses stale during a burst. `AudioRecorder.addClassifiedPulse` attributes
        // pulses to a WAV segment by this date, so a stale one would wrongly exclude
        // classified pulses from the segment's aggregate. See Context.md §8. Captured
        // once here so every consumer of this pulse's result agrees on when it happened.
        let captureDate = Date()

        let sr  = sampleRate
        let floor = pulseNoiseFloor
        let minFreq = minFrequencyHz
        let dispSpanSec = displayWindowMs / 1000
        let onsetFrac = onsetFraction
        let palette = displayPalette

        // Classification window: length + onset placement come from the model's input
        // spec (NABat: 50 ms, onset 30%). It ends `(1 − onsetFrac)·window` samples
        // after the onset. Anchored by absolute index so it lines up exactly with the
        // onset regardless of when this capture fired.
        let active = activeClassifier()
        let inputSpec = active?.descriptor.input ?? .nabat
        let clsCount = max(PulseImageRenderer.fftLen, Int(inputSpec.windowSeconds * sr))
        let clsEndAbs = onsetAbs + Int(Double(clsCount) * (1 - inputSpec.onsetFraction))
        let clsPCM    = pcmProvider?(clsCount, clsEndAbs) ?? []

        // Display capture: a window WIDER than the visible span, centred generously on
        // the onset, so the renderer has context to lock the pulse's energy onset to
        // the dashed line (it re-finds the −12 dB onset and crops the fixed span from
        // this buffer). Lead = 1 display span before the onset, trail = 2 spans after —
        // comfortably covers a long call plus the (1−onsetFrac) trailing display.
        let dispSpanSamples = max(PulseImageRenderer.fftLen + PulseImageRenderer.hop,
                                  Int(dispSpanSec * sr))
        let leadSamples  = dispSpanSamples
        let trailSamples = dispSpanSamples * 2
        let capCount  = leadSamples + trailSamples
        let capEndAbs = onsetAbs + trailSamples
        // Where the onset falls inside the captured buffer (index from its start).
        let onsetInBuf = leadSamples
        let dispPCM = pcmProvider?(capCount, capEndAbs) ?? []

        // Snapshot prior weights + quality gate on the main thread so the background
        // queue reads plain value types, not the @Observable settings object.
        let priorSnapshot: [String: Float]
        if let descriptor = active?.descriptor, let s = autoIDSettings {
            priorSnapshot = descriptor.classNames.reduce(into: [:]) { d, code in
                d[code] = s.effectivePrior(for: code)
            }
        } else {
            // No AutoIDSettings attached (shouldn't happen outside tests/previews) —
            // no static default prior exists anymore, so this just falls through to
            // `{ priorSnapshot[$0] ?? 1.0 }`'s neutral fallback below.
            priorSnapshot = [:]
        }
        let gate = autoIDSettings?.qualityGate ?? .disabled

        let cls = active?.classifier

        captureQueue.async { [weak self] in
            guard let self else { return }
            let result = PulseImageRenderer.render(pcm: dispPCM,
                                                   sampleRate: sr,
                                                   noiseFloor: floor,
                                                   minFrequencyHz: minFreq,
                                                   displaySpanSeconds: dispSpanSec,
                                                   onsetFraction: onsetFrac,
                                                   expectedOnsetSample: onsetInBuf,
                                                   palette: palette)

            // Release the capture gate as soon as the image is ready so that the next
            // pulse can be armed while classification (which is slow) still runs. Without
            // this, CoreML inference held isCapturing = true through the inter-pulse gap
            // and caused every other pulse to be skipped, halving the reported rate.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Count + rate are handled at detection time in registerDetection();
                // this completion only owns the (rate-limited) display refresh and
                // releasing the capture gate.
                let now = Date()

                if let r = result {
                    // Display gating: the zoom image and freq stats update only when
                    // both conditions are met:
                    //   1. Quality is high enough (concentrated energy, not broadband noise/echo)
                    //   2. The refresh window has expired OR this pulse is better quality than
                    //      whatever is currently shown (so we upgrade within a window).
                    // Never start a new refresh window on a low-quality capture.
                    let interval = self.displayRefreshIntervalSeconds
                    let windowExpired = interval <= 0
                        || self.lastDisplayUpdate.map { now.timeIntervalSince($0) >= interval } ?? true
                    let betterInWindow = !windowExpired && r.quality > self.displayWindowQuality
                    if r.quality >= 0.35 && (windowExpired || betterInWindow) {
                        self.lastPulseImage     = r.image
                        self.lastDetectionDate  = now
                        self.capturedFreqMin    = r.freqMin
                        self.capturedFreqMax    = r.freqMax
                        self.capturedWideFreqMin = r.wideFreqMin
                        self.capturedWideFreqMax = r.wideFreqMax
                        self.capturedTimeTightLeftFrac  = r.timeTightLeftFrac
                        self.capturedTimeTightRightFrac = r.timeTightRightFrac
                        self.capturedPeakFreq   = r.peakFreq
                        self.capturedDurationMs = r.durationMs
                        self.displayWindowQuality = r.quality
                        if windowExpired { self.lastDisplayUpdate = now }
                    }
                }
                self.isCapturing = false
            }

            // Classification continues after the gate is released. Posts its result
            // back to the main thread independently of the image/rate update above.
            let classification: ClassificationResult? = clsPCM.count >= clsCount
                ? cls?.classify(pcm: clsPCM, gate: gate, prior: { priorSnapshot[$0] ?? 1.0 })
                : nil
            guard let classification else {
                DispatchQueue.main.async { [weak self] in self?.pendingClassifications -= 1 }
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                defer { self.pendingClassifications -= 1 }
                // A classified pulse joins the pass even when the display render
                // failed — the ID shouldn't lose evidence over a missing thumbnail.
                self.lastClassification = classification
                let top = classification.allScores.sorted { $0.value > $1.value }
                    .prefix(6)
                    .map { ScoreEntry(species: $0.key, score: $0.value) }
                let captured = CapturedPulse(date: captureDate,
                                             species: classification.species,
                                             confidence: classification.confidence,
                                             peakFreqHz: result?.peakFreq ?? 0,
                                             durationMs: result?.durationMs ?? 0,
                                             topScores: top,
                                             // Stored thumbnails use the tight "clean" crop —
                                             // the wide render stays live-view-only.
                                             image: result?.cleanImage ?? result?.image,
                                             imageFreqMinHz: result?.cleanFreqMinHz,
                                             imageFreqMaxHz: result?.cleanFreqMaxHz,
                                             imageSpanMs: result?.cleanSpanMs)
                self.accumulatePulse(captured, raw: classification.rawScores, adjusted: classification.allScores)
                self.onPulseClassified?(classification, captured.date)
                ClassificationLogger.shared.logPulse(classification,
                                                     modelID: self.autoIDSettings?.activeModelID)
            }
        }
    }

}
