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

    /// What changed the last time a location move triggered a refresh — surfaced once
    /// so the app can tell the user "we updated X for your new location" instead of
    /// silently rewriting priors underneath them. `recommendedModel` is set only when
    /// it differs from the model that was active at refresh time (never re-suggests
    /// the model already in use). Species lists are codes for the *active* model only
    /// — a refresh touches every model's priors, but only the active one affects what
    /// the user sees classified right now. Cleared via `acknowledgeChangeSummary()`.
    private(set) var pendingChangeSummary: PriorRefreshSummary?

    struct PriorRefreshSummary {
        var recommendedModel: ModelDescriptor?
        var newlyEnabledSpecies: [String]
        var newlyDisabledSpecies: [String]

        var isEmpty: Bool {
            recommendedModel == nil && newlyEnabledSpecies.isEmpty && newlyDisabledSpecies.isEmpty
        }
    }

    func acknowledgeChangeSummary() {
        pendingChangeSummary = nil
    }

    /// True while a GBIF prior refresh is in flight — surfaced so a settings
    /// screen can show a spinner instead of looking like nothing happened.
    private(set) var isRefreshingPriors = false
    private let priorRefreshLock = NSLock()

    /// How far (km) the user needs to have moved since the last refresh before
    /// another one runs. Small enough to catch a real move to a different
    /// bioregion (e.g. Squamish → California), large enough that everyday
    /// movement around one town doesn't re-query GBIF on every launch.
    private static let priorRefreshDistanceKm: Double = 100

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

    /// Refreshes every registered model's species priors from GBIF occurrence
    /// data near `coordinate` — but only if this is the first fix ever, or the
    /// user has moved at least `priorRefreshDistanceKm` since the last refresh.
    /// Call this whenever a fresh location fix comes in (see
    /// `LocationProvider.requestRegionFix`); it no-ops harmlessly otherwise, so
    /// it's safe to call on every fix rather than needing its own trigger logic
    /// at each call site.
    ///
    /// Refreshes ALL models, not just the active one, so switching models later
    /// already has location-appropriate priors instead of the neutral default.
    /// Runs one model after another (not concurrently) — each one is already
    /// internally parallel (see GBIFService.suggestPriors), and the total
    /// species count across both bundled models today is small enough that
    /// serial-by-model isn't meaningfully slower, while keeping memory/network
    /// pressure lower than firing every model's every species query at once.
    ///
    /// `AutoIDSettings` isn't actor-isolated (PulseDetector's capture queue reads
    /// its properties synchronously off the main thread — see CLAUDE.md), so this
    /// method's own re-entrancy check needs its own lock rather than relying on
    /// isolation: repeated GPS fixes in quick succession (e.g. right after
    /// `LocationProvider.requestRegionFix()`, before a fix stabilizes) can each spawn
    /// a `Task` calling this concurrently, and a plain check-then-set on
    /// `isRefreshingPriors` is a real TOCTOU race between them. `perModel`/
    /// `lastPriorCheckCoordinate` drive SwiftUI, so the actual write-back is hopped
    /// onto the main actor regardless of which thread the awaits above resume on.
    func refreshPriorsFromGBIFIfNeeded(coordinate: CLLocationCoordinate2D) async {
        priorRefreshLock.lock()
        guard !isRefreshingPriors else { priorRefreshLock.unlock(); return }
        if let last = lastPriorCheckCoordinate {
            let moved = CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
            guard moved / 1000 >= Self.priorRefreshDistanceKm else { priorRefreshLock.unlock(); return }
        }
        isRefreshingPriors = true
        priorRefreshLock.unlock()
        defer { isRefreshingPriors = false }

        // Snapshot before overwriting, so the active model's changes can be reported
        // to the user afterwards — this is the only model whose priors affect what's
        // classified right now, so it's the only one worth diffing.
        let activeIDAtStart = activeModelID
        let previousActiveSpecies = activeIDAtStart.flatMap { perModel[$0]?.species } ?? [:]

        var updated = perModel
        for descriptor in ModelRegistry.all {
            guard !descriptor.scientificNames.isEmpty else { continue }
            let suggestions = await GBIFService.suggestPriors(scientificNames: descriptor.scientificNames,
                                                               near: coordinate)
            guard var settings = updated[descriptor.id] else { continue }
            for (code, suggestion) in suggestions {
                settings.species[code] = SpeciesState(enabled: suggestion.enabled, prior: suggestion.prior)
            }
            updated[descriptor.id] = settings
        }
        let suggestedModel = ModelRegistry.suggestedModel(for: coordinate)

        await MainActor.run {
            perModel = updated
            lastPriorCheckCoordinate = coordinate
            save()

            var newlyEnabled: [String] = []
            var newlyDisabled: [String] = []
            if let activeID = activeIDAtStart, let newSpecies = updated[activeID]?.species {
                for (code, newState) in newSpecies {
                    let wasEnabled = previousActiveSpecies[code]?.enabled ?? true
                    if newState.enabled && !wasEnabled { newlyEnabled.append(code) }
                    if !newState.enabled && wasEnabled { newlyDisabled.append(code) }
                }
            }
            // Never re-recommend the model already in use.
            let recommended = suggestedModel.flatMap { $0.id == activeIDAtStart ? nil : $0 }

            let summary = PriorRefreshSummary(recommendedModel: recommended,
                                              newlyEnabledSpecies: newlyEnabled.sorted(),
                                              newlyDisabledSpecies: newlyDisabled.sorted())
            if !summary.isEmpty {
                pendingChangeSummary = summary
            }
        }
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

        load()   // applies saved v2 state, or migrates legacy v1
    }

    // MARK: Active-model accessors (read by the classifier / pulse detector)

    var activeModel: ModelSettings? { activeModelID.flatMap { perModel[$0] } }

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
    /// `refreshPriorsFromGBIFIfNeeded`, which overwrites these from GBIF
    /// occurrence data as soon as a location fix is available). The descriptor's
    /// gate is used as-is. `minPassConfidence`/`minPassPulseCount` default to a
    /// real bar rather than "almost anything wins" — the old 0.05/1 defaults
    /// meant nearly every pulse produced *a* winning species regardless of how
    /// weak the margin over the runner-up actually was.
    static func defaultSettings(for d: ModelDescriptor) -> ModelSettings {
        var species: [String: SpeciesState] = [:]
        for code in d.classNames {
            species[code] = SpeciesState(enabled: true, prior: 1.0)
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
