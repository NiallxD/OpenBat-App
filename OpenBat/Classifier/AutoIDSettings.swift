//
//  AutoIDSettings.swift
//  OpenBat
//
//  Persisted AutoID configuration: per-species prior weights, pass detection
//  thresholds.  Lives as @State in ContentView and injected wherever needed.
//

import Foundation

@Observable
final class AutoIDSettings {

    struct SpeciesState: Codable {
        var enabled: Bool
        var prior: Float   // 0.01–1.0, used only when enabled = true
    }

    // Per-species state.  Keyed by 4-letter NABat code.
    var species: [String: SpeciesState]

    // Pass-level detection thresholds.
    var passTimeoutSeconds: Double
    var minPassConfidence: Float   // mean adjusted score to report an ID
    var minPassPulseCount: Int     // minimum pulses to form a pass

    // Per-pulse quality gate (mirrors nabat-ml _process_window). Pulses that fail
    // are still shown in the Pulse View but are not classified or counted in a pass.
    var qualityGateEnabled: Bool
    var qualitySNThreshold: Float
    var qualityAmpThreshold: Float

    /// Snapshot of the gate for the classifier (plain value type, off the @Observable).
    var qualityGate: QualityGate {
        QualityGate(enabled: qualityGateEnabled,
                    snThreshold: qualitySNThreshold,
                    ampThreshold: qualityAmpThreshold)
    }

    // MARK: Init

    init() {
        // Derive defaults from the built-in BC prior: enabled when prior ≥ 0.75,
        // disabled (but prior still stored) for the rest.
        var s: [String: SpeciesState] = [:]
        for (code, p) in BatClassifier.bcPrior {
            s[code] = SpeciesState(enabled: p >= 0.75, prior: max(0.01, p))
        }
        self.species            = s
        self.passTimeoutSeconds = 2.0
        self.minPassConfidence  = 0.05
        self.minPassPulseCount  = 1
        self.qualityGateEnabled = true
        self.qualitySNThreshold = 7
        self.qualityAmpThreshold = 21
        load()
    }

    // MARK: Effective prior

    /// Returns the prior to apply during classification.
    /// When disabled the species is suppressed to 0.01 regardless of the stored prior.
    func effectivePrior(for code: String) -> Float {
        guard let s = species[code], s.enabled else { return 0.01 }
        return max(0.01, s.prior)
    }

    // MARK: Defaults

    func resetToDefaults() {
        for (code, p) in BatClassifier.bcPrior {
            species[code] = SpeciesState(enabled: p >= 0.75, prior: max(0.01, p))
        }
        passTimeoutSeconds = 2.0
        minPassConfidence  = 0.05
        minPassPulseCount  = 1
        qualityGateEnabled = true
        qualitySNThreshold = 7
        qualityAmpThreshold = 21
    }

    // MARK: Persistence

    private static let key = "AutoIDSettings_v1"

    // Gate fields are optional so older saved payloads still decode (then fall back
    // to the property defaults).
    private struct Stored: Codable {
        var species: [String: SpeciesState]
        var passTimeoutSeconds: Double
        var minPassConfidence: Float
        var minPassPulseCount: Int
        var qualityGateEnabled: Bool?
        var qualitySNThreshold: Float?
        var qualityAmpThreshold: Float?
    }

    func save() {
        let stored = Stored(species: species,
                            passTimeoutSeconds: passTimeoutSeconds,
                            minPassConfidence: minPassConfidence,
                            minPassPulseCount: minPassPulseCount,
                            qualityGateEnabled: qualityGateEnabled,
                            qualitySNThreshold: qualitySNThreshold,
                            qualityAmpThreshold: qualityAmpThreshold)
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        self.species            = stored.species
        self.passTimeoutSeconds = stored.passTimeoutSeconds
        self.minPassConfidence  = stored.minPassConfidence
        self.minPassPulseCount  = stored.minPassPulseCount
        self.qualityGateEnabled  = stored.qualityGateEnabled ?? qualityGateEnabled
        self.qualitySNThreshold  = stored.qualitySNThreshold ?? qualitySNThreshold
        self.qualityAmpThreshold = stored.qualityAmpThreshold ?? qualityAmpThreshold
    }
}
