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
final class PulseDetector: Reseedable {

    // MARK: Settings

    enum TriggerMode: String, CaseIterable, Identifiable {
        case amplitude   = "Amplitude only"
        case ultrasonic  = "Frequency + Amplitude"
        var id: String { rawValue }

        /// What the user sees. Separate from `rawValue`, which is the persisted
        /// key (`pulse.triggerMode`) and appears in settings dumps — renaming
        /// that would silently reset every existing install to the default.
        var label: String {
            switch self {
            case .amplitude:  "Loudness"
            case .ultrasonic: "Loudness + pitch"
            }
        }

        var description: String {
            switch self {
            case .amplitude:
                "Anything loud enough counts, whatever its pitch. Useful for testing, but wind and handling noise will set it off."
            case .ultrasonic:
                "A sound must be both loud enough and high-pitched enough. Normally the one to use — it ignores most everyday noise."
            }
        }
    }

    // Each setting persists to UserDefaults on change (didSet) and is restored in
    // init(), so trigger tuning survives app relaunch instead of resetting.

    var triggerMode: TriggerMode = .ultrasonic {
        didSet { persist(triggerMode.rawValue, Key.triggerMode) }
    }
    /// Normalised peak magnitude (0–1) on the fixed −90…−20 dB trigger scale, so
    /// 0.05 here is 3.5 dB. Matches spectrogram brightness — 0.5 = medium-bright.
    ///
    /// **0.5, and the 2026-08-17 field tuning that said 0.3 does not apply.**
    /// That session moved this slider in `.ultrasonic` mode, where the detector
    /// also tested peak frequency — and the frequency it was handed was itself
    /// gated at level 0.5 (`SpectrogramProcessor.peakThreshold`), so every column
    /// between 0.3 and 0.5 reported 0 Hz and was dropped on the pitch test. The
    /// threshold actually in force was 0.5 the whole time and the slider was
    /// inert below it, so the session never heard what 0.3 sounds like.
    ///
    /// Removing that hidden gate (2026-09-01) made 0.3 real for the first time
    /// and took the trigger 14 dB more sensitive, which is not a tuning choice
    /// anyone made: clothing rustle and footfall on stone are broadband and carry
    /// well past the 15 kHz pitch gate, so amplitude is the only thing rejecting
    /// them. 0.5 is what the field-tested build ran at, and re-measuring the
    /// Squamish session of 2026-09-01 says it is also the right number rather
    /// than merely the old one: every pass the classifier could name peaks at
    /// 0.52 or above, so 0.5 is the highest threshold that loses none of them,
    /// and 0.55 already cuts a real *Lasiurus cinereus* pass. See `Context.md`
    /// §8. Re-tune downward from here deliberately, now that moving the slider
    /// does something.
    ///
    /// The property initialiser here — and on every tunable below it — is the
    /// COMPILED default, which `Tunable` may replace with a remotely-set one.
    /// `init` then overwrites it from storage if the user has ever chosen a
    /// value, so the precedence is: the user's choice, else the config file,
    /// else this number. See `RemoteDefaults`.
    var amplitudeThreshold: Float = Tunable.pulseAmplitudeThreshold.value(Float(0.5)) {
        didSet { persist(amplitudeThreshold, Key.amplitudeThreshold) }
    }
    /// Minimum peak frequency (Hz) required in .ultrasonic mode. Default 15 kHz
    /// rejects wind and handling noise without cutting off any bat species.
    var minFrequencyHz: Double = Tunable.pulseMinFrequencyHz.value(15_000.0) {
        didSet { persist(minFrequencyHz, Key.minFrequencyHz) }
    }
    var minConsecutiveColumns: Int = Tunable.pulseMinColumns.value(3) {
        didSet { persist(minConsecutiveColumns, Key.minConsecutiveColumns) }
    }
    /// Minimum gap between detections. Field data (Bat_Walk_27_06_2026) shows a
    /// median inter-pulse gap of ~79 ms, so the old 150 ms default silently dropped
    /// more than half of a normal pass's calls — starving both the pulse-rate readout
    /// and the classifier. 50 ms passes typical call spacing while still rejecting the
    /// closest echoes; amplitude does the rest (echoes return much quieter).
    /// Field tuning took it further, to 30 ms (2026-08-17 dump).
    var holdOffSeconds: Double = Tunable.pulseHoldOffSeconds.value(0.03) {
        didSet { persist(holdOffSeconds, Key.holdOffSeconds) }
    }
    /// Bridges brief amplitude dips *within* a single call (FM sweeps have nulls).
    /// A pulse only ends once this many consecutive columns fall below threshold,
    /// so one call yields exactly one capture instead of fragmenting. Default 6 ms.
    var maxGapMs: Double = Tunable.pulseMaxGapMs.value(6.0) {
        didSet { persist(maxGapMs, Key.maxGapMs) }
    }
    /// Fixed time span of the captured zoom window. Because every capture uses the
    /// SAME width, the pulse always renders at the same scale and the onset is
    /// always locked at `onsetFraction` from the left — one pulse, same place, every
    /// time. ~10 ms is the sweet spot for resolving a single bat call's structure.
    var displayWindowMs: Double = Tunable.pulseDisplayWindowMs.value(10.0) {
        didSet { persist(displayWindowMs, Key.displayWindowMs) }
    }
    /// Brightness gate applied to the captured pulse image (0–1). Pixels below this
    /// are rendered black; the remaining range is stretched to use the full
    /// colormap, so only the high-energy pulse shows and the background haze is
    /// removed. Raise to strip more noise; 0 disables the gate.
    var pulseNoiseFloor: Float = 0.35 {
        didSet { persist(pulseNoiseFloor, Key.pulseNoiseFloor) }
    }
    /// Same brightness gate as `pulseNoiseFloor`, applied independently to the live
    /// scrolling spectrogram (Spectrogram.metal's noiseFloor uniform) instead of
    /// sharing one setting across both views — the pulse zoom and the live view
    /// often want different amounts of noise stripped (a tight pulse crop can take
    /// a higher floor than the live view without losing context).
    ///
    /// Field tuning (2026-08-17 dump) landed the other way round — 0.40 live
    /// against 0.35 for the crop — which is the reverse of what the sentence
    /// above predicted. The two being independent is what matters; which one
    /// ends up higher is a matter of taste and was settled by looking.
    var spectrogramNoiseFloor: Float = 0.40 {
        didSet { persist(spectrogramNoiseFloor, Key.spectrogramNoiseFloor) }
    }
    /// Display colormap, shared by the live spectrogram (GPU) and the pulse-view
    /// image + thumbnails (CPU) — see `DisplayPalette.swift`.
    var displayPalette: Palette = .inferno {
        didSet { persist(displayPalette.rawValue, Key.displayPalette) }
    }
    /// When true the renderer skips uploading silent columns to the ring buffer,
    /// so the spectrogram fills with back-to-back pulses instead of continuous audio.
    var triggeredDisplayMode: Bool = false {
        didSet { persist(triggeredDisplayMode, Key.triggeredDisplayMode) }
    }
    /// Minimum seconds between pulse display updates. Detection and rate counting
    /// still happen every pulse; this only throttles how often the zoom image and
    /// frequency stats refresh. 0 = update on every pulse.
    var displayRefreshIntervalSeconds: Double = 2.0 {
        didSet { persist(displayRefreshIntervalSeconds, Key.displayRefreshIntervalSeconds) }
    }

    /// Pulse onset position within the fixed window (fraction from the left edge).
    /// Read by ContentView's pulse grid so the onset marker stays aligned.
    let onsetFraction = 0.25

    // MARK: Persistence

    /// `UserDefaults.standard` in the app — the initialiser takes a suite only so
    /// tests can exercise the one-time amplitude repair below without writing to
    /// the real domain, where a stamp set once would make the test unrepeatable.
    private let defaults: UserDefaults
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
        /// Stamp for the one-time amplitude repair below. A stamp rather than a
        /// clamp because the point is to undo a value the user never chose —
        /// once it has run, a deliberate 0.3 must survive every later launch.
        static let amplitudeGateRepaired             = "pulse.amplitudeGateRepaired"
    }

    /// Suppresses the persisting `didSet`s while a re-seed assigns — see
    /// `RemoteDefaultsReseed.swift` for why that matters more than it looks.
    var isSeeding = false

    /// Write unless a re-seed is in progress.
    private func persist(_ value: Any, _ key: String) {
        guard !isSeeding else { return }
        defaults.set(value, forKey: key)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Restore saved settings; absent keys leave the property defaults above.
        if let raw = defaults.string(forKey: Key.triggerMode),
           let mode = TriggerMode(rawValue: raw) { triggerMode = mode }
        let hadStoredAmplitude = defaults.object(forKey: Key.amplitudeThreshold) != nil
        if hadStoredAmplitude {
            amplitudeThreshold = defaults.float(forKey: Key.amplitudeThreshold)
        }
        // One-time repair, once per install. A saved threshold below 0.5 was set
        // while the hidden frequency gate made it unreachable (see the property's
        // note), so it records a preference that was never audible — restoring it
        // now would hand the user 14 dB of extra sensitivity they never asked for.
        // Written straight to `defaults` as well as to the property so the repair
        // sticks whether or not `didSet` fires for this assignment.
        //
        // **Only when there is something to repair** (2026-09-09). It used to
        // write the threshold unconditionally, which meant every install that
        // had ever launched held a stored value — including the ones that had
        // never touched the slider. A stored value is the app's record of "the
        // user chose this", so writing one here froze the threshold on every
        // phone and put it permanently out of reach of a remotely-set default.
        // The stamp is still written unconditionally: it says the repair has
        // been considered, which is true either way.
        //
        // `hadStoredAmplitude` gates it as well, and that matters more than it
        // looks: the repair exists to undo a value the USER's install saved, and
        // the compiled default it compares against can now itself be set
        // remotely. Without the gate, a config file trying 0.4 would be clamped
        // straight back to 0.5 on every fresh install and then written down as
        // the user's own choice — the config defeated and the parameter frozen,
        // in one line.
        if !defaults.bool(forKey: Key.amplitudeGateRepaired) {
            if hadStoredAmplitude, amplitudeThreshold < 0.5 {
                amplitudeThreshold = 0.5
                defaults.set(amplitudeThreshold, forKey: Key.amplitudeThreshold)
            }
            defaults.set(true, forKey: Key.amplitudeGateRepaired)
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

    /// Pick up remotely-set defaults for every value the user has never set.
    /// Only those: a stored key is this user's own choice and is left alone.
    func reseedRemoteDefaults() {
        seeding {
            if defaults.object(forKey: Key.amplitudeThreshold) == nil {
                amplitudeThreshold = Tunable.pulseAmplitudeThreshold.value(Float(0.5))
            }
            if defaults.object(forKey: Key.minFrequencyHz) == nil {
                minFrequencyHz = Tunable.pulseMinFrequencyHz.value(15_000.0)
            }
            if defaults.object(forKey: Key.minConsecutiveColumns) == nil {
                minConsecutiveColumns = Tunable.pulseMinColumns.value(3)
            }
            if defaults.object(forKey: Key.holdOffSeconds) == nil {
                holdOffSeconds = Tunable.pulseHoldOffSeconds.value(0.03)
            }
            if defaults.object(forKey: Key.maxGapMs) == nil {
                maxGapMs = Tunable.pulseMaxGapMs.value(6.0)
            }
            if defaults.object(forKey: Key.displayWindowMs) == nil {
                displayWindowMs = Tunable.pulseDisplayWindowMs.value(10.0)
            }
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
    /// Passes closed this session. Counted for the power log, which needs to
    /// know how much work a sample interval actually contained — an hour with
    /// 400 passes and an hour with none cost very different amounts.
    private(set) var passCount: Int = 0
    private(set) var pulseRateHz: Double = 0          // recent calls per second
    private(set) var lastClassification: ClassificationResult? = nil

    /// Pulses the detector found and the capture pipeline never looked at, because
    /// a capture was already in flight when they arrived.
    ///
    /// **These used to leave no trace at all.** Count and rate come from
    /// `registerDetection()` and were right; everything downstream — thumbnails,
    /// species, the demo log — silently held only the pulses that happened to fit.
    /// Three devices listening to one recording disagreed about what they had
    /// heard and no log said so. A device dropping a fifth of its calls should be
    /// able to say it is.
    private(set) var capturesSkipped: Int = 0

    /// Pulses captured and drawn but never put to the model, because the
    /// classifier was already `maxPendingClassifications` behind. Counted apart
    /// from `capturesSkipped`: one means the device cannot draw fast enough, the
    /// other that it cannot infer fast enough, and the fixes differ.
    private(set) var classificationsSkipped: Int = 0

    /// Pulses kept with their measurements but no picture, because the pulse view
    /// already had one to show. Not a loss — nothing about the pulse's evidence is
    /// missing — but it is the difference between "how many calls did we draw" and
    /// "how many did we keep", and a run should be able to say so.
    private(set) var picturesSkipped: Int = 0

    /// Below this quality, a pulse already on the panel can still be replaced by a
    /// better one inside the same refresh window, so a later pulse is worth
    /// drawing. Above it, the panel is showing something good and the rest of the
    /// window can be spent detecting instead of drawing.
    nonisolated static let displayUpgradeQuality: Float = 0.5

    /// True while the current pass has no pulse carrying an image. Every pass needs
    /// one — the history picks a pass's thumbnail from its best-scoring pulse, and
    /// a pass where nothing was drawn would have none at all.
    private var passHasNoImageYet = true

    /// The aggregated ID for the most recently completed pass (multi-pulse).
    /// Updated when silence exceeds `passTimeoutSeconds` after the last detected pulse.
    private(set) var lastPassResult: ClassificationResult? = nil
    /// How many pulses contributed to `lastPassResult`.
    private(set) var lastPassPulseCount: Int = 0
    /// When `lastPassResult` was produced — drives the stale-ID indicator in the UI.
    private(set) var lastPassDate: Date? = nil

    /// Silence gap (seconds) after the last pulse that closes a pass and fires the aggregated ID.
    var passTimeoutSeconds: Double = 2.0

    /// Pulses a pass needs before it is written to the history at all — see the
    /// discard in `finalizePass()` for the measurement behind the 2.
    ///
    /// A constant rather than a setting on purpose. The alternative is a second
    /// "minimum pulses" control sitting next to `minPassPulseCount`, which means
    /// something different, and no user could be expected to tell the two apart
    /// from their names. If this ever needs to move it should move for everyone,
    /// with a measurement attached.
    ///
    /// Static because `AudioRecorder` applies the same rule to its own segments
    /// from its own queue — see the rejection in `closeSegment`. The two must
    /// agree, or a pass dropped from the history leaves its WAV behind.
    nonisolated static let minRecordedPassPulseCount = 2

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
    /// Every pulse the detector keeps, classified or not — the recorder counts
    /// these so a segment knows how many calls are in it even when nothing was
    /// asked to name them. Fires alongside `onPulseClassified`, never instead
    /// of it, so the two are not an either/or at the receiving end.
    var onPulseDetected: ((Date) -> Void)?

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
            // The next pass needs its own thumbnail — see `passHasNoImageYet`.
            passHasNoImageYet = true
            // Let the next pass claim the zoom panel with its first good pulse instead
            // of being blocked by the quality of a pulse from the pass that just ended.
            displayWindowQuality = 0
        }
        guard passPulseCount > 0 else { return }

        // Fires on every exit below — the NoID early return and the single-pulse
        // discard as well as the normal end. All three are real triggers: even when
        // the classifier declines to name one, the pulse count and last-pulse stats
        // have moved, and the Live Activity should say so.
        defer { onPassFinalized?() }

        // One pulse is not a pass. Bats call in trains, so a lone trigger with
        // silence either side is a knock, a footfall or a fabric snap — and it is
        // unnameable in any case, since there is nothing to aggregate over.
        //
        // Measured against the Squamish session of 2026-09-01: twenty of its
        // thirty-nine NoID passes were single-pulse, while every pass the
        // classifier could name carried two or more (2, 4, 4, 4, 8, 10, 30). So
        // this drops half the clutter and none of the identifications.
        //
        // Deliberately NOT `autoIDSettings.minPassPulseCount`, which looks like
        // the same idea and is not: that one gates whether a pass gets NAMED, so
        // falling below it produces a NoID record — still written, still in the
        // list. This gate decides whether the pass is written at all, which is
        // the thing that was actually wanted. Raising the other one would have
        // removed none of those twenty entries.
        //
        // The discard is silent in the history but not in the counters: the pulse
        // count and rate come from `registerDetection()` on the detection path and
        // are untouched here, so the readouts still say something triggered. That
        // is the honest split — the detector did fire, it just has nothing worth
        // filing.
        guard passPulseCount >= Self.minRecordedPassPulseCount else { return }

        // Nothing was ever put to a model — identification is switched off, or
        // none is active. There is nothing to aggregate and no verdict to
        // report, but the pulses carry their measurements and the pass is a
        // real one, so it is filed under its own species rather than as NOID.
        // See `PassRecord.isUnidentified` for why that distinction matters.
        if passAggPulses.isEmpty {
            store?.addPass(species: "UNID", confidence: 0, pulses: passPulses,
                           sessionID: activeSessionID,
                           coordinate: activeSessionID != nil ? coordinateProvider?() : nil)
            DemoLogger.shared.logUnclassifiedPass(pulseCount: passPulseCount, species: "UNID",
                                                  skippedCapture: capturesSkipped,
                                                  skippedClassify: classificationsSkipped,
                                                  skippedPicture: picturesSkipped)
            return
        }

        let descriptor = activeClassifier()?.descriptor
        let verdict = PassAggregation.aggregate(
            passAggPulses,
            minAdjustedConfidence: autoIDSettings?.minPassConfidence ?? 0.05,
            minPulseCount: autoIDSettings?.minPassPulseCount ?? 1,
            rawConfidenceThreshold: descriptor?.noidRawConfidenceThreshold ?? PassAggregation.noidRawConfidenceThreshold,
            noiseClassName: descriptor?.noiseClassName,
            minWinningMargin: autoIDSettings?.minWinningMargin ?? 0
        )
        guard let outcome = verdict.outcome else {
            // NoID: pulses were captured and classified, but the pass never cleared
            // the confidence gates for a species OR the noise class. Previously this
            // pass just vanished with no trace; recording it as its own "NOID" species
            // lets the ID list show "something triggered, we couldn't tell what" instead
            // of silently dropping evidence the user did see/hear.
            // The raw confidence is recorded even here — especially here. It is
            // the number that failed the gate, so it is the difference between
            // "nothing much happened" and "a strong call the settings rejected".
            // ...and WHY it failed, which "NOID" alone never said. A pass the
            // model had no confidence in and a pass it was confident about but
            // could not choose within are opposite findings wearing one label.
            store?.addPass(species: "NOID", confidence: 0, pulses: passPulses,
                           sessionID: activeSessionID,
                           coordinate: activeSessionID != nil ? coordinateProvider?() : nil,
                           rawConfidence: PassAggregation.meanRawConfidence(passAggPulses),
                           noIDReason: verdict.noIDReason)
            // Logged as its own kind: a pass that WAS classified and came back
            // inconclusive is a different result from one nothing was asked
            // about, and a comparison that conflated them would be reading two
            // failures as one.
            DemoLogger.shared.logUnclassifiedPass(pulseCount: passPulseCount, species: "NOID",
                                                  skippedCapture: capturesSkipped,
                                                  skippedClassify: classificationsSkipped,
                                                  skippedPicture: picturesSkipped)
            return
        }

        let passResult = ClassificationResult(
            species: outcome.species,
            confidence: outcome.confidence,
            allScores: outcome.meanScores
        )
        lastPassResult = passResult
        lastPassPulseCount = passPulseCount
        passCount += 1
        lastPassDate = Date()
        ClassificationLogger.shared.logPass(passResult, pulseCount: passPulseCount,
                                            modelID: autoIDSettings?.effectiveModelID)
        DemoLogger.shared.logPass(passResult, pulseCount: passPulseCount,
                                  modelID: autoIDSettings?.effectiveModelID,
                                  skippedCapture: capturesSkipped,
                                  skippedClassify: classificationsSkipped,
                                  skippedPicture: picturesSkipped)

        // Second-place species by mean posterior — surfaced as a runner-up suggestion
        // in the species feed. Not meaningful for a NOISE outcome (its meanScores are
        // raw, not the prior-adjusted species pool), so skip it there.
        // Same deterministic tiebreak as the winner — see `highestScoring`.
        let runnerUp = outcome.species == "NOISE" ? nil
            : outcome.meanScores.filter { $0.key != outcome.species }.highestScoring()

        // Complex membership: does the classifying model admit that the winning species
        // is one it can't cleanly separate? And is the runner-up a complex-mate running
        // close enough to make this an *active* ambiguity? Both are surfaced in the UI
        // so a confident-looking number isn't shown for a confusable species in silence.
        let complex = ModelRegistry.descriptor(id: autoIDSettings?.effectiveModelID)?
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
                       complexAmbiguous: complexAmbiguous,
                       rawConfidence: outcome.meanRawConfidence)
    }

    /// Clears the session counters (count, rate, last capture) AND invalidates any
    /// capture or classification still in flight.
    ///
    /// The invalidation is the load-bearing half. Clearing the accumulators alone
    /// left the capture state machine running: a CoreML classification is a slow,
    /// background path (cold model load on a busy device — Context.md §9), and
    /// `ContentView.startDetecting` calls this with no wait, so a stop→start lands
    /// the previous run's pulse in the NEW session's `passAggPulses` seconds later,
    /// carrying the new session's ID and coordinate. Bumping `captureGeneration`
    /// makes both completions in `scheduleCapture` drop themselves instead.
    ///
    /// The pending-capture fields are cleared as a defensive measure, not because
    /// the sample clock moves under them. This comment used to claim an engine
    /// restart rebases that counter, leaving a stale `pendingArmAbs` comparing
    /// against the new stream as a wildly negative wait — that is false.
    /// `SpectrogramProcessor.pcmTotalWritten` is never reset and the processor
    /// outlives every engine restart (it's `@State` in `ContentView`), so the
    /// absolute clock is monotonic for the whole process lifetime. Clearing these
    /// is still right — a pending capture from the previous run belongs to a pass
    /// that no longer exists — but don't build on the rebasing story.
    func resetStats() {
        captureGeneration &+= 1
        isCapturing = false
        pendingCapture = false
        pendingOnsetAbs = 0
        pendingFireAbs = 0
        pendingArmAbs = 0
        pendingClassifications = 0
        pulseCount = 0
        passCount = 0
        pulseRateHz = 0
        capturesSkipped = 0
        classificationsSkipped = 0
        picturesSkipped = 0
        passHasNoImageYet = true
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
    /// Bumped by `resetStats` so in-flight captures/classifications from a previous
    /// run can recognise themselves as stale and drop out. `&+=` because it only
    /// ever needs to differ from the value a completion snapshotted, not to count.
    private var captureGeneration = 0
    private var isCapturing = false
    private let captureQueue = DispatchQueue(label: "bat.PulseDetector.capture",
                                             qos: .userInitiated)

    /// Inference runs here, not on `captureQueue`.
    ///
    /// **Both were one serial queue until 2026-09-07, and that was the whole of
    /// the detection floor.** A pulse's work is draw-then-classify, and the
    /// capture gate is released between the two — but the *next* pulse's drawing
    /// still had to wait behind the *previous* pulse's inference, because they
    /// shared a queue. So the gate could not reopen until an inference had
    /// finished, and the detector accepted one pulse per (draw + infer) no matter
    /// how fast the bat was calling. Measured floors were 0.32 s on an A16, 0.35
    /// on an A15 and 0.45–0.50 on an A14 — a whole generation apart, which read
    /// like a compute limit and was not one.
    ///
    /// Separating them lets the capture queue return as soon as the image is
    /// drawn. Inference then runs behind, up to `maxPendingClassifications` deep.
    /// See `Context.md` §9.
    private let classifyQueue = DispatchQueue(label: "bat.PulseDetector.classify",
                                              qos: .userInitiated)

    /// How far the classifier may fall behind before pulses stop being sent to it.
    ///
    /// Bounded on purpose. An unbounded backlog does not lose pulses, it defers
    /// them without limit: a feeding buzz arrives far faster than any device can
    /// classify, and the queue would still be draining minutes later, attributing
    /// answers to a bat that had long gone. Past this depth the pulse is still
    /// counted, drawn, filed and logged — only the species question is skipped,
    /// and `classificationsSkipped` records it.
    nonisolated static let maxPendingClassifications = 8

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
    /// the trailing fraction of the ACTIVE model's classification window
    /// (`windowSeconds * (1 - onsetFraction)`) as well as the display window, so
    /// neither is truncated. ~5 ms slack on top.
    ///
    /// **This is a hard floor on the detection rate, and it used to be the wrong
    /// model's floor (fixed 2026-09-07).** Every arriving pulse is skipped while a
    /// capture is armed and waiting, so this interval sets the closest two
    /// detections can be, before any work happens at all. It was a max over
    /// `ModelRegistry.all` — reasoning that a longer window must never be
    /// truncated — which is right about the requirement and wrong about whose:
    /// only the model actually running has to be satisfied. BatDetect2 needs
    /// 179.2 ms, NABat needs 35 ms, and *every* run paid BatDetect2's, so a NABat
    /// user waited 184 ms per capture to fill a 50 ms window. Measured floors
    /// were 0.30 / 0.33 / 0.45 s on A16 / A15 / A14, of which 0.184 s was this.
    ///
    /// With no active model there is nothing to fill, but a capture is still
    /// drawn, so this falls back to the display window's own trailing need.
    private var deferTrailSeconds: Double {
        let trailing = activeClassifier().map {
            $0.descriptor.input.windowSeconds * (1 - $0.descriptor.input.onsetFraction)
        } ?? (displayWindowMs / 1000)
        return trailing + 0.005
    }

    // Active classifier, lazily built from the active model descriptor and cached
    // until the active model id changes.
    private var cachedModelID: String?
    private var cachedClassifier: SpeciesClassifier?

    /// Resolves (and caches) the classifier + descriptor for the active model, or nil
    /// when no model is active or it fails to load. Called on the main thread.
    private func activeClassifier() -> (classifier: SpeciesClassifier, descriptor: ModelDescriptor)? {
        // `effectiveModelID`, not `activeModelID`: identification switched off
        // remotely means no classifier is built and none runs, which is what a
        // kill switch on this has to mean. Detection, recording, spectrograms
        // and playback are all upstream of here and continue untouched.
        guard let id = autoIDSettings?.effectiveModelID,
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
                    } else {
                        // A real call, found and then not looked at. Recorded so the
                        // gap between "pulses heard" and "pulses filed" is visible
                        // instead of having to be inferred from two devices
                        // disagreeing.
                        capturesSkipped += 1
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
        // Snapshotted so both completions below can tell whether the run they
        // belong to is still the current one — see `resetStats`.
        let generation = captureGeneration

        // This pulse's own wall-clock capture time — NOT `lastDetectionDate`, which is
        // display-only (gated by quality/refresh-window logic below) and can go several
        // pulses stale during a burst. `AudioRecorder.addClassifiedPulse` attributes
        // pulses to a WAV segment by this date, so a stale one would wrongly exclude
        // classified pulses from the segment's aggregate. See Context.md §8. Captured
        // once here so every consumer of this pulse's result agrees on when it happened.
        let captureDate = Date()
        // How long this pulse sat armed waiting for its trailing audio — the fixed
        // cost that gates the detection rate before any work is done. See
        // `deferTrailSeconds`.
        let waitMs = deferTrailSeconds * 1000

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
        let dispSpanSamples = max(PulseImageRenderer.fftLen + PulseImageRenderer.displayHop,
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

        // Does this pulse need its picture drawn? Decided here, on the main actor,
        // where the display's state lives — the completion below re-checks against
        // the same rules before actually showing it.
        //
        // The pulse view is an intermittent sample, not a feed: it holds one call
        // for `displayRefreshIntervalSeconds` so a person can look at it. Drawing
        // every capture to satisfy a panel that changes every 2 s meant most
        // renders were discarded on arrival, and since drawing is what holds the
        // capture queue, each discarded one cost the detections that arrived
        // while it ran.
        //
        // Three reasons to draw:
        //   · the display window has expired, so this pulse can claim the panel
        //   · the window is still open but what is on it is poor, so a better
        //     pulse may still replace it (the existing upgrade path)
        //   · nothing in this pass has an image yet, so the pass would otherwise
        //     have no thumbnail to represent it in the history
        let windowOpen = displayRefreshIntervalSeconds > 0
            && lastDisplayUpdate.map { Date().timeIntervalSince($0) < displayRefreshIntervalSeconds } ?? false
        let wantsImage = !windowOpen
            || displayWindowQuality < Self.displayUpgradeQuality
            || passHasNoImageYet

        // Species ID only runs at the model's native rate — see
        // `ModelInputSpec.nativeSampleRate`. Off-rate audio would be read as if it
        // were 384 kHz and produce a confident species name from a frequency axis
        // wrong by the rate ratio, so nothing is classified instead. Everything else
        // about this pulse proceeds normally; leaving `cls` nil falls through the
        // existing no-result path below, which decrements `pendingClassifications`
        // and closes the pass as NoID. Tolerance is fractional rather than absolute
        // because a delivered rate isn't guaranteed integral.
        let rateIsNative = abs(sr - inputSpec.nativeSampleRate)
                         <= inputSpec.nativeSampleRate * 0.001
        let rateReady = rateIsNative ? active?.classifier : nil

        // `pendingClassifications` already counts this pulse (incremented above), so
        // the comparison is against a backlog that includes it. Past the cap the
        // pulse keeps everything except its species — it falls through the same
        // no-result path as a pulse with no model at all, which decrements the
        // counter and files it as unclassified.
        let backlogFull = pendingClassifications > Self.maxPendingClassifications
        if backlogFull, rateReady != nil { classificationsSkipped += 1 }
        let cls = backlogFull ? nil : rateReady
        let skippedForBacklog = backlogFull && rateReady != nil

        if !wantsImage { picturesSkipped += 1 } else { passHasNoImageYet = false }

        // Captured as a local so the background block never reaches back through
        // `self` for it — the queue is a plain value and this stays off the actor.
        let classifyQueue = self.classifyQueue

        captureQueue.async { [weak self] in
            guard let self else { return }
            let imageStart = DispatchTime.now()
            let imageCPUStart = ThreadClock.cpuNanoseconds()
            let result = PulseImageRenderer.render(pcm: dispPCM,
                                                   sampleRate: sr,
                                                   noiseFloor: floor,
                                                   minFrequencyHz: minFreq,
                                                   displaySpanSeconds: dispSpanSec,
                                                   onsetFraction: onsetFrac,
                                                   expectedOnsetSample: onsetInBuf,
                                                   palette: palette,
                                                   makeImage: wantsImage)
            let imageMs = Double(DispatchTime.now().uptimeNanoseconds
                                 - imageStart.uptimeNanoseconds) / 1e6
            // Wall minus CPU is time this thread spent not running. If that gap is
            // most of `imageMs`, the render is being descheduled rather than being
            // slow, and tuning the DSP would achieve nothing.
            let imageCPUMs = ThreadClock.cpuMillisecondsSince(imageCPUStart)

            // Release the capture gate as soon as the image is ready so that the next
            // pulse can be armed while classification (which is slow) still runs. Without
            // this, CoreML inference held isCapturing = true through the inter-pulse gap
            // and caused every other pulse to be skipped, halving the reported rate.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Dropped if the detector was reset while this was in flight —
                // `resetStats` has already cleared the gate and the counters, so
                // touching them here would resurrect state from the previous run.
                guard self.captureGeneration == generation else { return }
                // Count + rate are handled at detection time in registerDetection();
                // this completion only owns the (rate-limited) display refresh and
                // releasing the capture gate.
                let now = Date()

                // A pulse drawn without a picture cannot claim the panel — but it is
                // still a pulse, and its measurements are filed below exactly as any
                // other's. `wantsImage` was decided when this capture was scheduled;
                // by now the window may have turned over, which only means this
                // pulse misses its turn rather than that anything was lost.
                if let r = result, let image = r.image {
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
                        self.lastPulseImage     = image
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

            // Classification runs on its OWN queue, not the tail of this one. The
            // gate release above is what lets the next pulse be armed; keeping the
            // model here meant the next pulse's *drawing* still queued behind this
            // pulse's inference, so the gate could not actually reopen until the
            // model had finished. That, not the silicon, was the detection floor —
            // see `classifyQueue`.
            classifyQueue.async {
                // Classification posts its result back to the main thread
                // independently of the image/rate update above.
                let classifyStart = DispatchTime.now()
                let classification: ClassificationResult? = clsPCM.count >= clsCount
                    ? cls?.classify(pcm: clsPCM, gate: gate, prior: { priorSnapshot[$0] ?? 1.0 })
                    : nil
                let classifyMs = cls == nil ? nil
                    : Double(DispatchTime.now().uptimeNanoseconds
                             - classifyStart.uptimeNanoseconds) / 1e6
                guard let classification else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.captureGeneration == generation else { return }
                        defer { self.pendingClassifications -= 1 }
                        // **A pulse nobody classified is still a pulse** (Niall,
                        // 2026-09-06). This used to drop it here, which meant a
                        // recording made with no model active kept its audio and
                        // none of its measurements — no timestamps, no peak
                        // frequencies, no durations — and the iNaturalist sheet
                        // refused it outright with "No calls were detected". The
                        // detector had found the calls, drawn them, and counted
                        // them; only the record of them was thrown away.
                        //
                        // So the measurements are kept and the species is left
                        // unfilled. `passAggPulses` is deliberately NOT appended
                        // to: there are no scores to aggregate, and its emptiness
                        // is what tells `finalizePass` this pass was never
                        // classified rather than classified inconclusively.
                        //
                        // Only when the render succeeded — without it there is no
                        // frequency, no duration and no thumbnail, so the pulse
                        // would be a bare timestamp claiming to be evidence.
                        guard let r = result else { return }
                        self.passPulseCount += 1
                        self.passPulses.append(CapturedPulse(
                            date: captureDate,
                            species: "UNID",
                            confidence: 0,
                            peakFreqHz: r.peakFreq,
                            durationMs: r.durationMs,
                            topScores: [],
                            image: r.cleanImage ?? r.image,
                            imageFreqMinHz: r.cleanFreqMinHz,
                            imageFreqMaxHz: r.cleanFreqMaxHz,
                            imageSpanMs: r.cleanSpanMs))
                        self.onPulseDetected?(captureDate)
                        // The row the field log has no way of writing: a call the
                        // detector kept and nothing was asked about. Two devices
                        // differing here differ in what they HEARD, which is a
                        // different finding from differing in what they named.
                        // Three different silences, told apart. "classifier behind"
                        // is the one that means the device could not keep up —
                        // reading it as "not classified" would hide exactly the
                        // shortfall these counters exist to expose.
                        let note: String
                        if skippedForBacklog                    { note = "classifier behind" }
                        else if self.activeClassifier() == nil  { note = "no active model" }
                        else                                    { note = "not classified" }
                        DemoLogger.shared.logUnclassifiedPulse(
                            peakFreqHz: r.peakFreq, durationMs: r.durationMs,
                            note: note,
                            at: captureDate,
                            skippedCapture: self.capturesSkipped,
                            skippedClassify: self.classificationsSkipped,
                            skippedPicture: self.picturesSkipped,
                            timings: .init(waitMs: waitMs, imageMs: imageMs,
                                           stftMs: result?.stftMs,
                                           classifyMs: classifyMs,
                                           stftFrames: result?.stftFrames,
                                           imageCPUMs: imageCPUMs))
                    }
                    return
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    // The important one: without this, a classification still running
                    // when the user stops and immediately restarts lands its pulse in
                    // the NEW session's accumulator, attributed to that session's ID
                    // and coordinate. The decrement is inside the guard too —
                    // `resetStats` zeroes `pendingClassifications`, so a stale
                    // decrement would drive it negative and the `== 0` gate in
                    // `feed()` would never let a pass finalize again.
                    guard self.captureGeneration == generation else { return }
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
                    self.onPulseDetected?(captured.date)
                    self.onPulseClassified?(classification, captured.date)
                    ClassificationLogger.shared.logPulse(classification,
                                                         modelID: self.autoIDSettings?.activeModelID)
                    // Silent unless a demo is being logged — see `DemoLogger`.
                    DemoLogger.shared.logClassifiedPulse(
                        classification,
                        peakFreqHz: result?.peakFreq ?? 0,
                        durationMs: result?.durationMs ?? 0,
                        modelID: self.autoIDSettings?.activeModelID,
                        at: captureDate,
                        skippedCapture: self.capturesSkipped,
                        skippedClassify: self.classificationsSkipped,
                        skippedPicture: self.picturesSkipped,
                        timings: .init(waitMs: waitMs, imageMs: imageMs,
                                       stftMs: result?.stftMs,
                                       classifyMs: classifyMs,
                                       stftFrames: result?.stftFrames,
                                       imageCPUMs: imageCPUMs))
                }
            }
        }
    }

}
