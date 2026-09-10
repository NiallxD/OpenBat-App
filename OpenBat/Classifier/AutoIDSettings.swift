//
//  AutoIDSettings.swift
//  OpenBat
//
//  Persisted AutoID configuration, organised per classifier model. Each model in
//  `ModelRegistry` carries its own `ModelSettings` (species toggles + priors, pass
//  detection thresholds, quality gate). `activeModelID` names the single model that
//  classifies (nil = AutoID off). Lives as @State in ContentView, injected where needed.
//

import CoreLocation
import Foundation

@Observable
final class AutoIDSettings: Reseedable {

    struct SpeciesState: Codable {
        var enabled: Bool
        var prior: Float   // 0.01–1.0, used only when enabled = true
        /// Whether this state came from actual range data, or is just the
        /// factory default nobody has confirmed.
        ///
        /// This distinction is the whole point of the 2026-08-16 rework. Before
        /// it, a species the app had never successfully looked up was
        /// indistinguishable from one it had confirmed was underfoot: both sat
        /// at `enabled, 1.0`. Roughly half of every location refresh failed
        /// silently, so a Tennessee cave bat read as a maximum-confidence
        /// candidate in California. "I don't know" must never render as "I'm
        /// certain" — see Context.md §9.
        var resolved: Bool

        init(enabled: Bool, prior: Float, resolved: Bool) {
            self.enabled = enabled
            self.prior = prior
            self.resolved = resolved
        }

        /// Hand-written so settings saved before `resolved` existed decode as
        /// UNRESOLVED rather than failing or claiming confirmation they never
        /// had. Those old values came from the GBIF record-count path this
        /// replaced, so treating them as unconfirmed is not just safe, it is
        /// accurate — and the first location fix re-derives them anyway.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            prior = try c.decode(Float.self, forKey: .prior)
            resolved = try c.decodeIfPresent(Bool.self, forKey: .resolved) ?? false
        }
    }

    /// All settings for one model. Everything is per-model (decision: 2026-06-29).
    struct ModelSettings: Codable {
        var species: [String: SpeciesState]   // keyed by class code
        var passTimeoutSeconds: Double
        var minPassConfidence: Float           // mean adjusted score to report an ID
        var minPassPulseCount: Int             // minimum pulses to form a pass
        /// How far clear of the runner-up the winner must be, or the pass goes
        /// unnamed. See `PassAggregation.aggregate`. Optional in the stored form
        /// so settings written before this existed decode without loss.
        var minWinningMargin: Float?
        var qualityGateEnabled: Bool           // per-pulse quality gate (nabat-ml _process_window)
        var qualitySNThreshold: Float
        var qualityAmpThreshold: Float
    }

    /// The single active model. `nil` means AutoID is off (capture/stats still run).
    var activeModelID: String?

    /// Set from the remote config on every launch, and NEVER persisted — see
    /// `Feature.automaticID`.
    ///
    /// Deliberately separate from `activeModelID` rather than clearing it: a
    /// switch thrown while the app is off should not silently forget which
    /// model the user chose, or turning identification back on would leave
    /// everybody with nothing selected and no idea why.
    var remotelyDisabled = false

    /// Set from the remote config on every launch, and never persisted — see
    /// `Feature.locationWeighting`. Off, every species the user has left
    /// enabled is weighted equally; their own enable/disable choices still
    /// apply, because those are theirs and not the weighting's.
    var locationWeightingDisabled = false

    /// The model that will actually classify, which is nothing at all while
    /// identification is switched off remotely. Read this anywhere the answer
    /// decides whether classification HAPPENS; `activeModelID` is still the
    /// right thing to read and write where the answer is which model the user
    /// has picked.
    var effectiveModelID: String? { remotelyDisabled ? nil : activeModelID }
    /// Settings for every known model, keyed by model id.
    var perModel: [String: ModelSettings]

    // MARK: Map pins (global — a mapping concern, not per-model)

    /// A session pass drops a species pin only when its confidence and pulse count both
    /// clear these gates ("best of the best"). Persisted independently of the model blob.
    var mapPinMinConfidence: Float {
        didSet { persist(mapPinMinConfidence, Self.keyMapConf) }
    }
    var mapPinMinPulseCount: Int {
        didSet { persist(mapPinMinPulseCount, Self.keyMapPulses) }
    }
    private static let keyMapConf = "MapPinMinConfidence"
    private static let keyMapPulses = "MapPinMinPulseCount"

    /// True when a pass has a location, clears both map-pin gates, and is an actual
    /// bat call — a NOISE pass has nothing meaningful to pin (it's a non-event by
    /// definition), so it's excluded from the map even though it still appears in
    /// the species list.
    func isMappable(_ pass: PassRecord) -> Bool {
        !pass.isNoise && !pass.isNoID
            && pass.coordinate != nil
            && pass.confidence >= mapPinMinConfidence
            && pass.pulseCount >= mapPinMinPulseCount
    }

    // MARK: Location-based priors

    /// What changed the last time a location *move* triggered a refresh — surfaced once
    /// so the app can tell the user "we updated X for your new location" instead of
    /// silently rewriting priors underneath them. `modelChange` is set when the move
    /// crossed a coverage boundary and the active model was switched (or switched off)
    /// as a result — a statement of what happened, never a question. `speciesChanged`
    /// counts codes for the *active* model only — a refresh touches every model's
    /// priors, but only the active one affects what the user sees classified right
    /// now. Cleared via `acknowledgeChangeSummary()`.
    ///
    /// **Never set on the first derivation** (2026-08-17). Until then it was, and on a
    /// clean install that was a bug the user saw: every species the grid reports as
    /// absent counts as a change away from the factory default, so a first fix raised
    /// a summary listing dozens of species and a model suggestion the post-onboarding
    /// card was already making. Nothing *changed* on a first fix — the priors were
    /// derived for the first time — so there is nothing to report.
    private(set) var pendingChangeSummary: PriorRefreshSummary?

    struct PriorRefreshSummary {
        /// Set only when this refresh actually changed the model — see
        /// `applyCoverage`. Nil on a move within the same coverage.
        var modelChange: ModelChange?
        /// How many of the active model's species were switched on or off by this
        /// refresh. A count rather than two lists: the sheet that showed the lists
        /// was scrapped on 2026-08-17 (see `AreaChangeSheet`), and nothing else
        /// ever read them — the authoritative list is AutoID settings itself.
        ///
        /// Zero whenever `modelChange` is set: the count is a diff against the
        /// model that was active before, and once that model has been swapped out
        /// it is a number about something the user no longer has.
        var speciesChanged: Int

        var isEmpty: Bool { modelChange == nil && speciesChanged == 0 }
    }

    /// What the automatic switch did on a move that crossed a coverage boundary.
    ///
    /// Not `Equatable`: `ModelDescriptor` carries closures. Nothing compares these
    /// — the sheet reads them once and the summary is cleared on dismissal.
    enum ModelChange {
        /// Moved into an area a model covers; it is now identifying.
        case switchedTo(ModelDescriptor)
        /// Moved out of every model's coverage; identification is now off, and this
        /// is what was running until the move.
        case turnedOff(previous: ModelDescriptor)
    }

    func acknowledgeChangeSummary() {
        pendingChangeSummary = nil
    }

    /// True while a prior refresh is in flight — surfaced so a settings screen
    /// can show a spinner instead of looking like nothing happened.
    /// Only ever written on the main actor (see `refreshPriors`)
    /// so `@Observable`'s change tracking stays on the isolation SwiftUI expects;
    /// the ACTUAL re-entrancy gate is `refreshInFlight` below, a plain
    /// (non-Observable) Bool fully owned by `priorRefreshLock`.
    private(set) var isRefreshingPriors = false
    private let priorRefreshLock = NSLock()
    private var refreshInFlight = false

    /// How far (km) the user needs to have moved before the priors are
    /// re-derived.
    ///
    /// Was 100 km, because each refresh cost ~50 GBIF requests and throttling
    /// them was the point. Reading the bundled presence grid costs a dictionary
    /// lookup, so the throttle now exists only to avoid pointless churn, and it
    /// can be tight enough to catch crossing a real range boundary — which at
    /// 100 km it could not. A user driving one county over to a different
    /// habitat now gets the right species list.
    private static let priorRefreshDistanceKm: Double = 10

    private static let keyLastPriorCoordinate = "AutoIDSettings_lastPriorCoordinate"

    private var lastPriorCheckCoordinate: CLLocationCoordinate2D? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: Self.keyLastPriorCoordinate) else { return nil }
            let parts = stored.split(separator: ",")
            guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        set {
            let d = UserDefaults.standard
            if let newValue {
                d.set("\(newValue.latitude),\(newValue.longitude)", forKey: Self.keyLastPriorCoordinate)
            } else {
                d.removeObject(forKey: Self.keyLastPriorCoordinate)
            }
        }
    }

    /// Re-derives every registered model's species priors from the bundled
    /// presence grid for `coordinate` — but only on the first fix, or once the
    /// user has moved `priorRefreshDistanceKm`. Call it on every fresh location
    /// fix (see `LocationProvider.requestRegionFix`); it no-ops harmlessly
    /// otherwise, so call sites need no trigger logic of their own.
    ///
    /// WHAT THIS REPLACED (2026-08-16)
    /// It used to ask GBIF, live, how many occurrence records each species had
    /// within 100 km — around fifty requests fired at once, per location change.
    /// Three things were wrong with that, and the third was shipping:
    ///
    ///   1. Record counts measure recording effort, not bats.
    ///   2. Roughly half the requests were throttled and failed. A failed
    ///      lookup left the species untouched, and untouched meant the factory
    ///      default of `enabled, 1.0` — so "couldn't reach the internet" was
    ///      indistinguishable from "definitely here". A Tennessee cave bat read
    ///      as a maximum-confidence San Francisco candidate.
    ///   3. It queried by scientific name at runtime, which was wrong in both
    ///      directions: too old a name for the western red bat (0 records in
    ///      California under `Lasiurus blossevillii`, 90 under `frantzii`) and
    ///      too new a name for the serotine (`Cnephaeus serotinus` matches only
    ///      a GENUS in GBIF, so it returned 0 everywhere and the serotine was
    ///      switched off in southern England). Taxonomy is now resolved once, at
    ///      data-generation time, where a human reads the report.
    ///
    /// Refreshes ALL models, not just the active one, so switching models later
    /// already has location-appropriate priors instead of a neutral default.
    ///
    /// `AutoIDSettings` isn't actor-isolated (PulseDetector's capture queue reads
    /// its properties synchronously off the main thread — see Context.md §13), so this
    /// method's own re-entrancy check needs its own lock rather than relying on
    /// isolation: repeated GPS fixes in quick succession (e.g. right after
    /// `LocationProvider.requestRegionFix()`, before a fix stabilizes) can each spawn
    /// a `Task` calling this concurrently, and a plain check-then-set on
    /// `isRefreshingPriors` is a real TOCTOU race between them. `perModel`/
    /// `lastPriorCheckCoordinate` drive SwiftUI, so the actual write-back is hopped
    /// onto the main actor regardless of which thread the awaits above resume on.
    ///
    /// Still `async` and still locked despite the lookup now being local and
    /// instant: the call sites and the re-entrancy hazard are unchanged, and the
    /// presence store may not have finished loading when the first fix lands.
    func refreshPriors(at coordinate: CLLocationCoordinate2D,
                       using presence: SpeciesPresenceStore) async {
        // Nothing to derive from yet. Deliberately does NOT record the
        // coordinate, so the next fix retries rather than leaving every species
        // on its unresolved default until the user travels 10 km.
        guard await MainActor.run(body: { presence.isLoaded }) else { return }

        priorRefreshLock.lock()
        guard !refreshInFlight else { priorRefreshLock.unlock(); return }
        // Read inside the lock, with the same value the distance gate below uses:
        // a first derivation reports nothing (see `pendingChangeSummary`).
        let isFirstDerivation = lastPriorCheckCoordinate == nil
        if let last = lastPriorCheckCoordinate {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard moved / 1000 >= Self.priorRefreshDistanceKm else { priorRefreshLock.unlock(); return }
        }
        refreshInFlight = true
        priorRefreshLock.unlock()
        await MainActor.run { isRefreshingPriors = true }

        // Snapshot before overwriting, so the active model's changes can be reported
        // to the user afterwards — this is the only model whose priors affect what's
        // classified right now, so it's the only one worth diffing.
        let activeIDAtStart = activeModelID
        let previousActiveSpecies = activeIDAtStart.flatMap { perModel[$0]?.species } ?? [:]

        var updated = perModel
        for descriptor in ModelRegistry.all {
            guard !descriptor.scientificNames.isEmpty else { continue }
            guard var settings = updated[descriptor.id] else { continue }
            for code in descriptor.scientificNames.keys {
                let state = await MainActor.run {
                    presence.presence(forCode: code, at: coordinate)
                }
                settings.species[code] = Self.speciesState(for: state)
            }
            updated[descriptor.id] = settings
        }

        await MainActor.run {
            perModel = updated
            lastPriorCheckCoordinate = coordinate
            // Before `save()`, so the model this move switched to is persisted with
            // the priors it was derived alongside.
            let modelChange = applyCoverage(at: coordinate)
            save()
            isRefreshingPriors = false

            // Only worth counting when the model survived the move — see
            // `PriorRefreshSummary.speciesChanged`.
            var speciesChanged = 0
            if modelChange == nil, let activeID = activeIDAtStart,
               let newSpecies = updated[activeID]?.species {
                for (code, newState) in newSpecies {
                    let wasEnabled = previousActiveSpecies[code]?.enabled ?? true
                    if newState.enabled != wasEnabled { speciesChanged += 1 }
                }
            }

            let summary = PriorRefreshSummary(modelChange: modelChange,
                                              speciesChanged: speciesChanged)
            if !summary.isEmpty && !isFirstDerivation {
                pendingChangeSummary = summary
            }
        }
        priorRefreshLock.lock(); refreshInFlight = false; priorRefreshLock.unlock()
    }

    /// Points `activeModelID` at whichever model covers `coordinate`, or at nothing
    /// when none does.
    ///
    /// **Location owns the model** (Niall, 2026-09-08). This used to be a sheet:
    /// a fresh install starts with `activeModelID == nil`, and the one thing that
    /// ever turned identification on was a card asking the user to confirm the only
    /// answer their coordinates allowed — the coverage boxes are disjoint, so there
    /// is never a second option to weigh. Worse, it was one of five presentations
    /// racing for the first-launch slot, and losing that race left a brand-new user
    /// with the app's headline feature silently switched off and no sign of why.
    ///
    /// Moving out of coverage switches identification off rather than leaving the
    /// last model running: a North American classifier in Europe does not decline
    /// gracefully, it names European bats after American ones. Silence is the honest
    /// output there, and `ModelChange.turnedOff` is what tells the user so.
    ///
    /// Called only from `refreshPriors`, which already runs on exactly the fixes that
    /// can matter — the first one ever, and any that has moved
    /// `priorRefreshDistanceKm`. A coverage boundary cannot be crossed without
    /// moving vastly further than that.
    ///
    /// Internal rather than private so `ModelCoverageTests` can drive the
    /// transitions directly: every one of them is a border crossing, and none is
    /// reachable by tapping anything.
    @discardableResult
    func applyCoverage(at coordinate: CLLocationCoordinate2D) -> ModelChange? {
        let covering = ModelRegistry.suggestedModel(for: coordinate)
        guard covering?.id != activeModelID else { return nil }
        let previous = ModelRegistry.descriptor(id: activeModelID)
        activeModelID = covering?.id
        if let covering { return .switchedTo(covering) }
        // `previous` is nil only if the stored id names a model this build no longer
        // has, in which case there is nothing truthful to name in a notice.
        return previous.map { .turnedOff(previous: $0) }
    }

    // MARK: Init

    init() {
        // Seed defaults for every registered model from its descriptor.
        var pm: [String: ModelSettings] = [:]
        for d in ModelRegistry.all { pm[d.id] = Self.defaultSettings(for: d) }
        self.perModel = pm
        // No model active until a location fix says which one — running a
        // wrong-region classifier (a North American model somewhere it has no
        // business identifying calls) is worse than identifying nothing for the few
        // seconds a fix takes. `applyCoverage` is what fills this in, and `load()`
        // below restores the last coverage answer so a launch with no signal keeps
        // identifying with whatever covered the user last time.
        self.activeModelID = nil

        let defaults = UserDefaults.standard
        // The two map-pin thresholds are the only values in this type that may
        // be set remotely. Everything per-model — pass timeout, confidence,
        // pulses, margin, the quality gate — deliberately cannot: those decide
        // what a recording is identified AS, and belong to a build that was
        // tested with the model they go with. See `AUDIT-2026-09-09-parameters.md` in the git history.
        self.mapPinMinConfidence = defaults.object(forKey: Self.keyMapConf) != nil
            ? defaults.float(forKey: Self.keyMapConf)
            : Tunable.mapPinMinConfidence.value(Float(0.70))
        self.mapPinMinPulseCount = defaults.object(forKey: Self.keyMapPulses) != nil
            ? defaults.integer(forKey: Self.keyMapPulses)
            : Tunable.mapPinMinPulseCount.value(3)

        // NOT load() — see `loadPersisted()`. The two UserDefaults scalar reads
        // above are cheap enough to leave here; the JSON decode is not.
    }

    /// Applies saved v2 state (or migrates a legacy v1 blob). Call once from the
    /// owning view's `.task`, never from `init()`.
    ///
    /// `AutoIDSettings()` is a SwiftUI `@State` default value, so its initializer
    /// expression re-runs every time the enclosing view's initializer does —
    /// SwiftUI keeps the first result and discards the rest. Decoding the stored
    /// per-model species blob there meant paying that decode on every redundant
    /// construction, on the main thread, for a value thrown straight away.
    func loadPersisted() {
        guard !hasLoaded else { return }
        hasLoaded = true
        load()
    }

    /// Puts this object back to what a fresh install holds, after the stored keys
    /// have already been erased.
    ///
    /// Only "Reset all settings" needs it, and it needs it badly. `loadPersisted()`
    /// is a no-op by the time Settings can be opened at all, so the reset's call to
    /// it left every value sitting in memory — and the sheet writes this object out
    /// on the way to dismissal, so the erasure was undone before the user got back
    /// to the app. Re-reading storage isn't enough either: after an erase there is
    /// nothing there to read, and `load()` leaves whatever is already in memory
    /// alone. So the defaults are rebuilt here, from the same descriptors `init`
    /// seeds from.
    ///
    /// Assigning inside `seeding` matters as much as the values: the map-pin
    /// thresholds persist on write, and writing them back would pin them to today's
    /// number and stop this install ever receiving a remote change to either again.
    func reloadAfterReset() {
        hasLoaded = true
        var pm: [String: ModelSettings] = [:]
        for d in ModelRegistry.all { pm[d.id] = Self.defaultSettings(for: d) }
        perModel = pm
        // No model until coverage says which one, exactly as on a fresh install —
        // the next location fix refills it through `applyCoverage`.
        activeModelID = nil
        seeding {
            mapPinMinConfidence = Tunable.mapPinMinConfidence.value(Float(0.70))
            mapPinMinPulseCount = Tunable.mapPinMinPulseCount.value(3)
        }
    }

    // MARK: Active-model accessors (read by the classifier / pulse detector)

    var activeModel: ModelSettings? { activeModelID.flatMap { perModel[$0] } }

    /// The three states the presence grid can report, turned into a weight.
    ///
    /// `unknown` is the case that matters. It means the grid has no range for
    /// this species at all — too few records to draw one, or a taxon that
    /// couldn't be resolved. It must not read as "definitely here" (the bug this
    /// replaced) and it must not read as "definitely absent" either, which would
    /// silently stop the app naming a bat purely because nobody has mapped it.
    /// So it stays enabled at half weight and, crucially, `resolved: false` — so
    /// the settings screen can say plainly that it doesn't know.
    private static func speciesState(for presence: SpeciesPresenceStore.Presence) -> SpeciesState {
        switch presence {
        case .present:
            return SpeciesState(enabled: true, prior: 1.0, resolved: true)
        case .absent:
            return SpeciesState(enabled: false, prior: 0.01, resolved: true)
        case .unknown:
            return SpeciesState(enabled: true, prior: 0.5, resolved: false)
        }
    }

    /// The weights the classifier is applying right now, for the active model —
    /// what `ClassificationStore.recordPriorSnapshot` stamps onto a session.
    ///
    /// Reports `effectivePrior`'s answer for every species rather than the raw
    /// `prior` field, so what gets recorded is what classification actually used.
    var priorSnapshotData: (modelID: String, priors: [String: Float], disabled: [String])? {
        guard let id = activeModelID, let model = perModel[id] else { return nil }
        var priors: [String: Float] = [:]
        var disabled: [String] = []
        for (code, state) in model.species {
            priors[code] = effectivePrior(for: code)
            if !state.enabled { disabled.append(code) }
        }
        return (id, priors, disabled.sorted())
    }

    /// Prior to apply during classification. Disabled species are suppressed to 0.01.
    ///
    /// With location weighting switched off remotely every enabled species
    /// weighs the same. The user's own switches are still honoured: turning off
    /// a species is their decision about their own data, and has nothing to do
    /// with the range grid this flag governs.
    func effectivePrior(for code: String) -> Float {
        guard let s = activeModel?.species[code], s.enabled else { return 0.01 }
        return locationWeightingDisabled ? 1.0 : max(0.01, s.prior)
    }

    /// Snapshot of the active model's quality gate (plain value type, off the @Observable).
    var qualityGate: QualityGate {
        guard let m = activeModel else { return .disabled }
        return QualityGate(enabled: m.qualityGateEnabled,
                           snThreshold: m.qualitySNThreshold,
                           ampThreshold: m.qualityAmpThreshold)
    }

    var passTimeoutSeconds: Double { activeModel?.passTimeoutSeconds ?? Self.defaultPassTimeoutSeconds }
    var minWinningMargin: Float    { activeModel?.minWinningMargin ?? 0.10 }
    var minPassConfidence: Float   { activeModel?.minPassConfidence ?? 0.05 }
    var minPassPulseCount: Int     { activeModel?.minPassPulseCount ?? 1 }

    // MARK: Defaults

    /// Default settings for a model, derived from its descriptor: every species
    /// starts enabled with a neutral prior (no location-based bias yet — see
    /// `refreshPriors`, which overwrites these from the bundled presence grid as
    /// soon as a location fix is available). The descriptor's
    /// gate is used as-is. `minPassConfidence`/`minPassPulseCount` default to a
    /// real bar rather than "almost anything wins" — the old 0.05/1 defaults
    /// meant nearly every pulse produced *a* winning species regardless of how
    /// weak the margin over the runner-up actually was.
    /// Named rather than written twice: the seed below and the migration in
    /// `load()` have to agree, and a literal in each is how they stop agreeing.
    static let defaultPassTimeoutSeconds: Double = 1.1

    static func defaultSettings(for d: ModelDescriptor) -> ModelSettings {
        var species: [String: SpeciesState] = [:]
        for code in d.classNames {
            species[code] = SpeciesState(enabled: true, prior: 1.0, resolved: false)
        }
        return ModelSettings(species: species,
                             // 0.8 s, not the 2.0 this shipped with. The timeout is
                             // what separates one bat from the next, and 2 s is
                             // longer than the quiet between two passes: on the demo
                             // clip it produced a single 26-second "pass" holding
                             // four species, whose reported name was decided by
                             // whichever of them the pipeline had sampled best that
                             // run — it changed between builds without the audio
                             // changing. 0.8 sits in a valley in the gap
                             // distribution: 0.8 and 1.1 segment that clip
                             // identically, while 0.5 cuts inside a single LANO's
                             // own call spacing (p95 0.70 s) and shatters one bat
                             // into five passes.
                             passTimeoutSeconds: defaultPassTimeoutSeconds,
                             minPassConfidence: 0.15,
                             minPassPulseCount: 2,
                             minWinningMargin: 0.10,
                             qualityGateEnabled: d.defaultGate.enabled,
                             qualitySNThreshold: d.defaultGate.snThreshold,
                             qualityAmpThreshold: d.defaultGate.ampThreshold)
    }

    /// Reset one model to its descriptor defaults.
    func resetModel(_ id: String) {
        guard let d = ModelRegistry.descriptor(id: id) else { return }
        perModel[id] = Self.defaultSettings(for: d)
    }

    // MARK: Persistence

    /// Guards `loadPersisted()` against running more than once.
    private var hasLoaded = false

    private static let keyV2 = "AutoIDSettings_v2"
    private static let keyV1 = "AutoIDSettings_v1"   // legacy single-model blob

    /// One-time move of the pass timeout off its old shipped default.
    ///
    /// **Changing `defaultSettings` does nothing to anyone who already has the
    /// app** — `load()` overlays the stored per-model payload on top of the
    /// defaults, so an install carrying the old value keeps it forever. The 2.0 s
    /// default was not a preference anybody expressed, it was a number that made
    /// one pass out of a minute of bats and made the reported species depend on
    /// how much of the audio the device managed to keep, so it is moved rather
    /// than left.
    ///
    /// Only a model still sitting on exactly a superseded default is touched, and
    /// only once. Someone who had deliberately chosen one of those values loses
    /// that choice — accepted, because it is indistinguishable from never having
    /// touched the slider, and the slider is still right there.
    /// Bump the key when the default moves again — an install that has already
    /// run one migration will not run it a second time, so a later change to
    /// `defaultPassTimeoutSeconds` reaches nobody without a new key here. Both
    /// superseded values are listed: 2.0 shipped for a long time, and 0.8 was
    /// the default for a single day's builds before field data argued it up.
    private static let keyPassTimeoutMigration = "AutoIDSettings_passTimeout_1.1"
    private static let supersededPassTimeouts: Set<Double> = [2.0, 0.8]

    private struct StoredV2: Codable {
        var activeModelID: String?
        var perModel: [String: ModelSettings]
    }

    // Legacy v1 payload (flat, single model). Gate fields optional so the oldest
    // payloads still decode.
    private struct StoredV1: Codable {
        var species: [String: SpeciesState]
        var passTimeoutSeconds: Double
        var minPassConfidence: Float
        var minPassPulseCount: Int
        var qualityGateEnabled: Bool?
        var qualitySNThreshold: Float?
        var qualityAmpThreshold: Float?
    }

    /// See `keyPassTimeoutMigration`.
    private func migratePassTimeoutIfNeeded(_ defaults: UserDefaults) {
        guard !defaults.bool(forKey: Self.keyPassTimeoutMigration) else { return }
        var changed = false
        for (id, ms) in perModel where Self.supersededPassTimeouts.contains(ms.passTimeoutSeconds) {
            perModel[id]?.passTimeoutSeconds = Self.defaultPassTimeoutSeconds
            changed = true
        }
        defaults.set(true, forKey: Self.keyPassTimeoutMigration)
        if changed { save() }
    }

    /// Suppresses the persisting `didSet`s while a re-seed assigns — see
    /// `RemoteDefaultsReseed.swift`.
    var isSeeding = false

    private func persist(_ value: Any, _ key: String) {
        guard !isSeeding else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// The two map-pin thresholds, and nothing else. Per-model values are not
    /// remotely settable at all — see the note in `init`.
    func reseedRemoteDefaults() {
        let d = UserDefaults.standard
        seeding {
            if d.object(forKey: Self.keyMapConf) == nil {
                mapPinMinConfidence = Tunable.mapPinMinConfidence.value(Float(0.70))
            }
            if d.object(forKey: Self.keyMapPulses) == nil {
                mapPinMinPulseCount = Tunable.mapPinMinPulseCount.value(3)
            }
        }
    }

    func save() {
        let stored = StoredV2(activeModelID: activeModelID, perModel: perModel)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.keyV2)
        }
    }

    private func load() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: Self.keyV2),
           let stored = try? JSONDecoder().decode(StoredV2.self, from: data) {
            // Overlay saved per-model settings onto the descriptor-seeded defaults, so
            // models absent from the payload (e.g. added in a later build) keep defaults.
            for (id, ms) in stored.perModel { perModel[id] = ms }
            activeModelID = stored.activeModelID
            migratePassTimeoutIfNeeded(defaults)
            return
        }

        // Migrate a legacy v1 blob into the NABat model, then write forward as v2.
        if let data = defaults.data(forKey: Self.keyV1),
           let v1 = try? JSONDecoder().decode(StoredV1.self, from: data),
           var nabat = perModel[ModelRegistry.nabatID] {
            nabat.species            = v1.species
            nabat.passTimeoutSeconds = v1.passTimeoutSeconds
            nabat.minPassConfidence  = v1.minPassConfidence
            nabat.minPassPulseCount  = v1.minPassPulseCount
            nabat.qualityGateEnabled  = v1.qualityGateEnabled ?? nabat.qualityGateEnabled
            nabat.qualitySNThreshold  = v1.qualitySNThreshold ?? nabat.qualitySNThreshold
            nabat.qualityAmpThreshold = v1.qualityAmpThreshold ?? nabat.qualityAmpThreshold
            perModel[ModelRegistry.nabatID] = nabat
            activeModelID = ModelRegistry.nabatID
            save()
        }
    }
}
