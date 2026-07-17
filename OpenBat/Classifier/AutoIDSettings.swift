//
//  AutoIDSettings.swift
//  OpenBat
//
//  Persisted AutoID configuration, organised per classifier model. Each model in
//  `ModelRegistry` carries its own `ModelSettings` (species toggles + priors, pass
//  detection thresholds, quality gate). `activeModelID` names the single model that
//  classifies (nil = AutoID off). Lives as @State in ContentView, injected where needed.
//

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
        !pass.isNoise
            && pass.coordinate != nil
            && pass.confidence >= mapPinMinConfidence
            && pass.pulseCount >= mapPinMinPulseCount
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

    /// Default settings for a model, derived from its descriptor: enabled when the
    /// default prior ≥ 0.75, prior stored either way, and the descriptor's gate.
    /// `minPassConfidence`/`minPassPulseCount` default to a real bar rather than
    /// "almost anything wins" — the old 0.05/1 defaults meant nearly every pulse
    /// produced *a* winning species regardless of how weak the margin over the
    /// runner-up actually was.
    static func defaultSettings(for d: ModelDescriptor) -> ModelSettings {
        var species: [String: SpeciesState] = [:]
        for code in d.classNames {
            let p = d.defaultPrior[code] ?? 1.0
            species[code] = SpeciesState(enabled: p >= 0.75, prior: max(0.01, p))
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
