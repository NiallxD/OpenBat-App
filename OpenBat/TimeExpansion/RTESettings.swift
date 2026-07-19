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

    /// Minimum frequency (kHz) that can trigger expansion. Only energy above this
    /// drives the gate, so low-frequency handling noise (footsteps, clothing, wind)
    /// is ignored. Raise it if non-bat sounds are triggering RTE; lower it to catch
    /// lower-frequency bats. This is the primary user-facing "noise rejection" knob.
    var minFrequencyKHz: Float {
        didSet { UserDefaults.standard.set(minFrequencyKHz, forKey: Self.keyMinFreqKHz) }
    }

    /// How far (dB) a block must rise above the rolling noise floor to count as a
    /// call. The gate is relative, not absolute, so quiet calls still trigger while
    /// the floor auto-tracks conditions. Lower = more sensitive (also more noise).
    var marginDB: Float {
        didSet { UserDefaults.standard.set(marginDB, forKey: Self.keyMarginDB) }
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

    // Tuned against the Bat_Walk_27_06_2026 field corpus. The gate is now relative
    // (block RMS vs a rolling noise floor) rather than a fixed −38 dBFS threshold, so
    // quiet high-frequency species trigger without the absolute gate missing them. A
    // 12 dB margin sits comfortably below the ~18–25 dB call-to-floor spread of even
    // the quietest Myotis while rejecting the floor. A 15 kHz detection high-pass
    // keeps footsteps / clothing / wind (all sub-bat-band) from ever triggering.
    static let defaultMinFreqKHz: Float   = 15.0
    static let defaultMarginDB: Float     = 12.0
    static let defaultHoldMs: Float       = 15.0
    static let defaultGain: Float         = 4.0
    static let defaultGateBlockMs: Float  = 1.5

    // MARK: Persistence keys

    private static let keyMinFreqKHz  = "RTE.minFreqKHz"
    private static let keyMarginDB    = "RTE.marginDB"
    private static let keyHoldMs      = "RTE.holdMs"
    private static let keyGain        = "RTE.gain"
    private static let keyGateBlockMs = "RTE.gateBlockMs"

    init() {
        let d = UserDefaults.standard
        minFrequencyKHz = d.object(forKey: Self.keyMinFreqKHz) != nil
            ? d.float(forKey: Self.keyMinFreqKHz)  : Self.defaultMinFreqKHz
        marginDB    = d.object(forKey: Self.keyMarginDB)    != nil
            ? d.float(forKey: Self.keyMarginDB)    : Self.defaultMarginDB
        holdMs      = d.object(forKey: Self.keyHoldMs)      != nil
            ? d.float(forKey: Self.keyHoldMs)      : Self.defaultHoldMs
        gain        = d.object(forKey: Self.keyGain)        != nil
            ? d.float(forKey: Self.keyGain)        : Self.defaultGain
        gateBlockMs = d.object(forKey: Self.keyGateBlockMs) != nil
            ? d.float(forKey: Self.keyGateBlockMs) : Self.defaultGateBlockMs
    }

    // MARK: Apply

    func apply(to processor: TimeExpansionProcessor) {
        processor.minFrequencyHz = minFrequencyKHz * 1000
        processor.marginDB       = marginDB
        processor.holdMs         = holdMs
        processor.gain           = gain
        processor.gateBlockMs    = gateBlockMs
    }

    func reset() {
        minFrequencyKHz = Self.defaultMinFreqKHz
        marginDB        = Self.defaultMarginDB
        holdMs          = Self.defaultHoldMs
        gain            = Self.defaultGain
        gateBlockMs     = Self.defaultGateBlockMs
    }
}
