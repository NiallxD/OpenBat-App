//
//  RTESettings.swift
//  OpenBat
//
//  Persisted RTE (real-time time expansion) parameters. Lives as @State in
//  ContentView; changes are applied to TimeExpansionProcessor via onChange.
//

import Foundation

@Observable
final class RTESettings {

    // MARK: Settings

    /// Gate threshold in dBFS. Blocks whose band-limited RMS exceeds this value
    /// are treated as a bat call and pushed into the expansion ring.
    /// Lower = more sensitive (picks up quiet calls, also more noise).
    var thresholdDB: Float {
        didSet { UserDefaults.standard.set(thresholdDB, forKey: Self.keyThreshold) }
    }

    /// How long after the signal drops below threshold to keep the gate open (ms).
    /// Bridges brief dips mid-call and captures the call tail cleanly.
    var holdMs: Float {
        didSet { UserDefaults.standard.set(holdMs, forKey: Self.keyHoldMs) }
    }

    /// Output makeup gain (the 8× expansion halves perceived loudness).
    var gain: Float {
        didSet { UserDefaults.standard.set(gain, forKey: Self.keyGain) }
    }

    /// RMS window size for the sub-buffer gate (ms). Smaller = more responsive but
    /// noisier gate decisions; larger = smoother gate but can clip the call onset.
    var gateBlockMs: Float {
        didSet { UserDefaults.standard.set(gateBlockMs, forKey: Self.keyGateBlockMs) }
    }

    // MARK: Defaults

    // Tuned against the Bat_Walk_27_06_2026 field corpus. RTE is only sustainable
    // when (gate duty × 8× expansion) stays under 100%; the old −50 dB threshold
    // passed ~25% of the audio → 200% playback → the ring saturated and the
    // skip-ahead thrashed continuously (the popping). −38 dB keeps duty near ~35%,
    // and the longer hold keeps each call coherent instead of fragmenting.
    static let defaultThresholdDB: Float  = -38.0
    static let defaultHoldMs: Float       = 15.0
    static let defaultGain: Float         = 4.0
    static let defaultGateBlockMs: Float  = 1.5

    // MARK: Persistence keys

    private static let keyThreshold   = "RTE.thresholdDB"
    private static let keyHoldMs      = "RTE.holdMs"
    private static let keyGain        = "RTE.gain"
    private static let keyGateBlockMs = "RTE.gateBlockMs"

    init() {
        let d = UserDefaults.standard
        thresholdDB = d.object(forKey: Self.keyThreshold)   != nil
            ? d.float(forKey: Self.keyThreshold)   : Self.defaultThresholdDB
        holdMs      = d.object(forKey: Self.keyHoldMs)      != nil
            ? d.float(forKey: Self.keyHoldMs)      : Self.defaultHoldMs
        gain        = d.object(forKey: Self.keyGain)        != nil
            ? d.float(forKey: Self.keyGain)        : Self.defaultGain
        gateBlockMs = d.object(forKey: Self.keyGateBlockMs) != nil
            ? d.float(forKey: Self.keyGateBlockMs) : Self.defaultGateBlockMs
    }

    // MARK: Apply

    func apply(to processor: TimeExpansionProcessor) {
        processor.thresholdDB = thresholdDB
        processor.holdMs      = holdMs
        processor.gain        = gain
        processor.gateBlockMs = gateBlockMs
    }

    func reset() {
        thresholdDB = Self.defaultThresholdDB
        holdMs      = Self.defaultHoldMs
        gain        = Self.defaultGain
        gateBlockMs = Self.defaultGateBlockMs
    }
}
