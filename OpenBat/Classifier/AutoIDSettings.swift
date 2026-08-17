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
final class AutoIDSettings {

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
        var qualityGateEnabled: Bool           // per-pulse quality gate (nabat-ml _process_window)
        var qualitySNThreshold: Float
        var qualityAmpThreshold: Float
    }

    /// The single active model. `nil` means AutoID is off (capture/stats still run).
    var activeModelID: String?
    /// Settings for every known model, keyed by model id.
    var perModel: [String: ModelSettings]

    // MARK: Map pins (global — a mapping concern, not per-model)

    /// A session pass drops a species pin only when its confidence and pulse count both
    /// clear these gates ("best of the best"). Persisted independently of the model blob.
    var mapPinMinConfidence: Float {
        didSet { UserDefaults.standard.set(mapPinMinConfidence, forKey: Self.keyMapConf) }
    }
    var mapPinMinPulseCount: Int {
        didSet { UserDefaults.standard.set(mapPinMinPulseCount, forKey: Self.keyMapPulses) }
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
    /// silently rewriting priors underneath them. `recommendedModel` is set only when
    /// it differs from the model that was active at refresh time (never re-suggests
    /// the model already in use). `speciesChanged` counts codes for the *active* model
    /// only — a refresh touches every model's priors, but only the active one affects
    /// what the user sees classified right now. Cleared via `acknowledgeChangeSummary()`.
    ///
    /// **Never set on the first derivation** (2026-08-17). Until then it was, and on a
    /// clean install that was a bug the user saw: every species the grid reports as
    /// absent counts as a change away from the factory default, so a first fix raised
    /// a summary listing dozens of species and a model suggestion the post-onboarding
    /// card was already making. Nothing *changed* on a first fix — the priors were
    /// derived for the first time — so there is nothing to report.
    private(set) var pendingChangeSummary: PriorRefreshSummary?

    struct PriorRefreshSummary {
        var recommendedModel: ModelDescriptor?
        /// How many of the active model's species were switched on or off by this
        /// refresh. A count rather than two lists: the sheet that showed the lists
        /// was scrapped on 2026-08-17 (see `SuggestedModelSheet`), and nothing else
        /// ever read them — the authoritative list is AutoID settings itself.
        var speciesChanged: Int

        var isEmpty: Bool { recommendedModel == nil && speciesChanged == 0 }
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
        let suggestedModel = ModelRegistry.suggestedModel(for: coordinate)

        await MainActor.run {
            perModel = updated
            lastPriorCheckCoordinate = coordinate
            save()
            isRefreshingPriors = false

            var speciesChanged = 0
            if let activeID = activeIDAtStart, let newSpecies = updated[activeID]?.species {
                for (code, newState) in newSpecies {
                    let wasEnabled = previousActiveSpecies[code]?.enabled ?? true
                    if newState.enabled != wasEnabled { speciesChanged += 1 }
                }
            }
            // Never re-recommend the model already in use.
            let recommended = suggestedModel.flatMap { $0.id == activeIDAtStart ? nil : $0 }

            let summary = PriorRefreshSummary(recommendedModel: recommended,
                                              speciesChanged: speciesChanged)
            if !summary.isEmpty && !isFirstDerivation {
                pendingChangeSummary = summary
            }
        }
        priorRefreshLock.lock(); refreshInFlight = false; priorRefreshLock.unlock()
    }

    // MARK: Init

    init() {
        // Seed defaults for every registered model from its descriptor.
        var pm: [String: ModelSettings] = [:]
        for d in ModelRegistry.all { pm[d.id] = Self.defaultSettings(for: d) }
        self.perModel = pm
        // No model active by default — auto-activating a model regardless of where the
        // phone is would risk quietly running a wrong-region classifier (e.g. a North
        // American model somewhere it has no business identifying calls) before the
        // location-suggestion flow in AutoIDSettingsView ever gets a say. `load()` below
        // restores a real saved choice if one exists.
        self.activeModelID = nil

        let defaults = UserDefaults.standard
        self.mapPinMinConfidence = defaults.object(forKey: Self.keyMapConf) != nil
            ? defaults.float(forKey: Self.keyMapConf) : 0.70
        self.mapPinMinPulseCount = defaults.object(forKey: Self.keyMapPulses) != nil
            ? defaults.integer(forKey: Self.keyMapPulses) : 3

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

    /// Prior to apply during classification. Disabled species are suppressed to 0.01.
    func effectivePrior(for code: String) -> Float {
        guard let s = activeModel?.species[code], s.enabled else { return 0.01 }
        return max(0.01, s.prior)
    }

    /// Snapshot of the active model's quality gate (plain value type, off the @Observable).
    var qualityGate: QualityGate {
        guard let m = activeModel else { return .disabled }
        return QualityGate(enabled: m.qualityGateEnabled,
                           snThreshold: m.qualitySNThreshold,
                           ampThreshold: m.qualityAmpThreshold)
    }

    var passTimeoutSeconds: Double { activeModel?.passTimeoutSeconds ?? 2.0 }
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
    static func defaultSettings(for d: ModelDescriptor) -> ModelSettings {
        var species: [String: SpeciesState] = [:]
        for code in d.classNames {
            species[code] = SpeciesState(enabled: true, prior: 1.0, resolved: false)
        }
        return ModelSettings(species: species,
                             passTimeoutSeconds: 2.0,
                             minPassConfidence: 0.15,
                             minPassPulseCount: 2,
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
