//
//  RemoteDefaults.swift
//  OpenBat
//
//  Default VALUES, held in the same GitHub file as the kill switches, so a
//  number that turns out to be wrong can be changed without another review.
//
//  WHY THIS IS SEPARATE FROM FeatureFlags
//  --------------------------------------
//  The flags scheme rests on a promise: the worst a bad config file can do is
//  remove a feature, because a flag can only ever turn something OFF and the
//  binary Apple reviewed is the most the app can do. Numbers break that
//  promise — a bad threshold removes nothing, it makes the app quietly deaf
//  while still looking like it works. So this half carries its own guard rails:
//
//    * only the parameters listed in `Tunable` can be set at all;
//    * each one declares the range it is allowed to take, and a value outside
//      that range is IGNORED rather than clamped, so a typo fails visibly in
//      the config rather than half-applying in the field;
//    * nothing here decides what a recording is identified AS. Per-model AutoID
//      settings are deliberately absent and belong to a build — see
//      `AUDIT-2026-09-09-parameters.md`.
//
//  THE RULE ABOUT WHOSE VALUE IT IS
//  --------------------------------
//  A value the user has chosen is theirs; a value they never touched is ours to
//  move. Every settings store in the app already reads "is there a stored
//  value? use it; otherwise use the compiled default", so a remote default
//  slots in where the compiled constant was and the rule falls out for free.
//
//  That holds only while nothing writes a value the user did not choose. Three
//  places used to, and were fixed alongside this (the one-time amplitude
//  repair, simplified view's frequency band, and the recording timings, which
//  were not persisted at all). **If you add a `didSet`-free write of a default
//  anywhere, you have quietly frozen that parameter on every install.**
//
//  WHEN A CHANGE TAKES EFFECT
//  --------------------------
//  It depends on how the parameter is read, and the split is worth knowing
//  because it is not the one you would assume:
//
//    * The levels — heterodyne gain, the makeup gain and clip knee, the duck,
//      the replay's crest gate and level targets — are computed properties read
//      at CAPTURE START. So a file downloaded a second into launch is already in
//      force the next time somebody presses Start. Same launch, no restart.
//    * Everything with a Settings slider behind it is read once, in its store's
//      `init`, so it takes effect at the NEXT launch. Re-seeding those live is
//      possible but not free: assigning to one fires the `didSet` that persists
//      it, which would write down a value the user never chose and freeze the
//      parameter forever — the exact trap this whole scheme is built to avoid.
//      Any live re-seed must suppress persistence and must not run mid-session.
//
//  The cache is what makes both work offline, and what makes a first read cheap.
//
//  NOTHING HERE MAY BE READ ON A REALTIME THREAD.
//  ---------------------------------------------
//  A read takes a lock. On the audio render or capture thread that is an
//  unbounded wait, i.e. a glitch. Read at construction, at capture start, or at
//  attach time, and capture the result — `AudioEngineController.attachListenOutput`
//  and `SnippetExpansionProcessor.reset` both show the pattern, both because
//  they were briefly written the other way.
//
//  ⚠️ Same branch warning as `FeatureFlags.swift`: the file is on `main`.
//

import Foundation

/// Every parameter that may be set remotely, with the range it may take.
///
/// **Adding a case is the whole job.** The consumer reads
/// `Tunable.x.value(compiledDefault)` in place of its constant, and the config
/// file gains a key. A parameter that is not a case here cannot be set, which
/// is the point.
nonisolated enum Tunable: String, CaseIterable, Sendable {

    // MARK: Levels — no user control at all, so no value of anyone's to respect

    /// `HeterodyneProcessor.defaultGain`.
    case heterodyneGain          = "heterodyne.gain"
    /// `ListenOutputStage.makeupGain` — everything leaving the listen output.
    case listenMakeupGain        = "listen.makeupGain"
    /// `ListenOutputStage.softClipKnee` — where that output starts compressing.
    case listenSoftClipKnee      = "listen.softClipKnee"
    /// How far the live channel drops while a replay sounds, and how fast.
    case snippetDuckLevel        = "listen.snippetDuckLevel"
    case snippetDuckSeconds      = "listen.snippetDuckSeconds"
    /// How far a snippet's peak must stand above its own background before it
    /// is worth replaying — `SnippetExpansionProcessor.minCallCrestDB`.
    case snippetMinCallCrestDB   = "snippet.minCallCrestDB"
    /// The ceiling on a replay's background, at the output.
    case snippetMaxBackground    = "snippet.maxBackgroundLevel"
    /// The band simplified view applies on entry, in Hz.
    case simplifiedBandLowHz     = "simplified.bandLowHz"
    case simplifiedBandHighHz    = "simplified.bandHighHz"

    // MARK: Detection — user-settable, so this only moves an UNTOUCHED default

    case pulseAmplitudeThreshold = "pulse.amplitudeThreshold"
    case pulseMinFrequencyHz     = "pulse.minFrequencyHz"
    case pulseMinColumns         = "pulse.minConsecutiveColumns"
    case pulseHoldOffSeconds     = "pulse.holdOffSeconds"
    case pulseMaxGapMs           = "pulse.maxGapMs"
    case pulseDisplayWindowMs    = "pulse.displayWindowMs"

    // MARK: Time expansion

    case snippetExpansion        = "snippet.expansion"
    case snippetMemorySeconds    = "snippet.memorySeconds"
    case snippetTrimDB           = "snippet.trimDB"
    case snippetRearmSeconds     = "snippet.rearmSeconds"
    case snippetFadeMS           = "snippet.fadeMS"

    // MARK: Heterodyne

    case heterodyneTrimDB        = "heterodyne.trimDB"

    // MARK: Recording

    case recordingPreRoll        = "recording.preRollSeconds"
    case recordingPostRoll       = "recording.postRollSeconds"
    case recordingMaxSegment     = "recording.maxSegmentSeconds"

    // MARK: Map pins

    case mapPinMinConfidence     = "map.minConfidence"
    case mapPinMinPulseCount     = "map.minPulseCount"

    // MARK: Haptics

    case hapticStrength          = "haptics.strength"
    case hapticLevelFloor        = "haptics.levelFloor"
    case hapticLevelCeiling      = "haptics.levelCeiling"
    case hapticMinIntensity      = "haptics.minIntensity"
    case hapticFreqFloorHz       = "haptics.freqFloorHz"
    case hapticFreqCeilingHz     = "haptics.freqCeilingHz"
    case hapticBuzzEnterHz       = "haptics.buzzEnterHz"
    case hapticBuzzExitHz        = "haptics.buzzExitHz"
    case hapticRateWindow        = "haptics.rateWindow"
    case hapticBuzzHangover      = "haptics.buzzHangover"
    case hapticMinTapInterval    = "haptics.minTapInterval"

    /// What this parameter is allowed to be.
    ///
    /// Wider than the matching Settings slider in several cases, deliberately:
    /// the slider's range is what a user may choose by hand, and part of why
    /// this exists is to try a value outside it before committing a build to
    /// offering it. Never wider than what the code downstream can survive.
    var range: ClosedRange<Double> {
        switch self {
        case .heterodyneGain:          0.1...12
        case .listenMakeupGain:        1...24
        case .listenSoftClipKnee:      0.2...0.95
        case .snippetDuckLevel:        0.05...1
        case .snippetDuckSeconds:      0.005...0.5
        case .snippetMinCallCrestDB:   6...48
        case .snippetMaxBackground:    0.00001...0.05
        case .simplifiedBandLowHz:     0...100_000
        case .simplifiedBandHighHz:    1_000...192_000
        case .pulseAmplitudeThreshold: 0.05...0.99
        case .pulseMinFrequencyHz:     0...180_000
        case .pulseMinColumns:         1...20
        case .pulseHoldOffSeconds:     0.005...2
        case .pulseMaxGapMs:           0...100
        case .pulseDisplayWindowMs:    6...40
        case .snippetExpansion:        2...32
        case .snippetMemorySeconds:    0.05...2
        case .snippetTrimDB:           -24...24
        case .snippetRearmSeconds:     0...5
        case .snippetFadeMS:           0...200
        case .heterodyneTrimDB:        -24...24
        case .recordingPreRoll:        0...5
        case .recordingPostRoll:       0.5...30
        case .recordingMaxSegment:     10...3_600
        case .mapPinMinConfidence:     0...1
        case .mapPinMinPulseCount:     1...50
        case .hapticStrength:          0...1
        case .hapticLevelFloor:        0...1
        case .hapticLevelCeiling:      0...1
        case .hapticMinIntensity:      0...1
        case .hapticFreqFloorHz:       0...200_000
        case .hapticFreqCeilingHz:     0...200_000
        case .hapticBuzzEnterHz:       0...200
        case .hapticBuzzExitHz:        0...200
        case .hapticRateWindow:        0.05...10
        case .hapticBuzzHangover:      0...5
        case .hapticMinTapInterval:    0.001...1
        }
    }

    /// The remote value if there is a valid one, and the compiled default
    /// otherwise. **This is the only call site pattern** — a consumer that
    /// reads `RemoteDefaults` directly has skipped the range check.
    func value(_ compiled: Double) -> Double {
        RemoteDefaults.value(for: self) ?? compiled
    }

    func value(_ compiled: Float) -> Float {
        RemoteDefaults.value(for: self).map(Float.init) ?? compiled
    }

    func value(_ compiled: Int) -> Int {
        RemoteDefaults.value(for: self).map { Int($0.rounded()) } ?? compiled
    }
}

/// The store behind `Tunable.value`.
///
/// `nonisolated` and lock-guarded because the audio processors read their
/// constants from the capture and output threads, and the project isolates
/// types to the main actor by default. Reads are one dictionary lookup behind
/// an uncontended lock, and every consumer reads at construction or at capture
/// start — never per buffer.
nonisolated enum RemoteDefaults {

    private static let storageKey = "config.remoteDefaults"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Double]?

    /// The validated value for one parameter, or nil to use the compiled one.
    static func value(for tunable: Tunable) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        if cache == nil {
            cache = (UserDefaults.standard.dictionary(forKey: storageKey) as? [String: Double]) ?? [:]
        }
        guard let raw = cache?[tunable.rawValue] else { return nil }
        // Checked on the way out as well as on the way in: a value stored by an
        // older build, whose range has since narrowed, must not survive.
        return tunable.range.contains(raw) ? raw : nil
    }

    /// Adopt what the config file said. Called by `FeatureFlagStore` for both
    /// the cached and the freshly downloaded file.
    ///
    /// Takes effect at the NEXT launch, by design: the values are written to
    /// storage, not pushed into the objects already built from them. Pushing
    /// them live would mean a threshold changing under a session in progress,
    /// with the spectrogram, the detector and the recorder disagreeing about
    /// which value was in force for which second of it.
    @discardableResult
    static func adopt(_ values: [String: Double]?) -> Bool {
        var accepted: [String: Double] = [:]
        var rejected: [String] = []
        for tunable in Tunable.allCases {
            guard let raw = values?[tunable.rawValue] else { continue }
            if tunable.range.contains(raw) {
                accepted[tunable.rawValue] = raw
            } else {
                rejected.append("\(tunable.rawValue)=\(raw) outside \(tunable.range)")
            }
        }
        if !rejected.isEmpty {
            // Config errors are for whoever wrote the file, and the config menu
            // shows the same list — this is for the case where nobody is
            // looking at a phone yet.
            print("[RemoteDefaults] ignored: \(rejected.joined(separator: ", "))")
        }
        lock.lock()
        let changed = cache.map { $0 != accepted } ?? !accepted.isEmpty
        cache = accepted
        lock.unlock()
        UserDefaults.standard.set(accepted, forKey: storageKey)
        // Whether anything actually moved, so a launch that downloads the same
        // file it already had — which is most launches — doesn't re-seed for
        // nothing. See `RemoteDefaultsReseed.swift`.
        return changed
    }

    /// Every value currently in force, for the config menu's own listing.
    static func active() -> [(Tunable, Double)] {
        Tunable.allCases.compactMap { tunable in
            value(for: tunable).map { (tunable, $0) }
        }
    }

    /// Forget every remotely-set default. Used by the settings reset, which
    /// erases the stored key underneath this cache.
    static func clearCache() {
        lock.lock()
        cache = nil
        lock.unlock()
    }
}
