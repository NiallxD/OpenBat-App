//
//  MicCalibrationSettings.swift
//  OpenBat
//
//  Persisted microphone calibration curve — one `MicCalibrationCurve` per mic
//  model, so switching microphones doesn't silently apply the wrong
//  correction. Mirrors the listen-mode settings' persistence pattern.
//

import Foundation

@Observable
final class MicCalibrationSettings {

    /// Whether the stored curve (if any, and if it matches the currently
    /// connected mic) is actually applied. Lets a user A/B compare or back
    /// out without losing a calibration they already did.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.keyEnabled) }
    }

    private(set) var curve: MicCalibrationCurve?

    private static let keyEnabled = "MicCal.enabled"
    private static func curveKey(forMicName micName: String) -> String {
        "MicCal.\(micName).curve"
    }

    init() {
        let d = UserDefaults.standard
        isEnabled = d.object(forKey: Self.keyEnabled) != nil ? d.bool(forKey: Self.keyEnabled) : true
    }

    /// Loads (if present) the stored curve for `micName` into `curve` — call
    /// once the connected mic's name is known (e.g. from
    /// `AudioDiagnostics.inputName`), since curves are stored per mic model.
    func load(forMicName micName: String) {
        guard let data = UserDefaults.standard.data(forKey: Self.curveKey(forMicName: micName)),
              let loaded = try? JSONDecoder().decode(MicCalibrationCurve.self, from: data)
        else {
            curve = nil
            return
        }
        curve = loaded
    }

    /// Saves a freshly-measured curve and makes it the active one.
    func save(_ newCurve: MicCalibrationCurve) {
        guard let data = try? JSONEncoder().encode(newCurve) else { return }
        UserDefaults.standard.set(data, forKey: Self.curveKey(forMicName: newCurve.micName))
        curve = newCurve
        isEnabled = true
    }

    /// The curve to actually apply right now, or `nil` if calibration is off,
    /// there's no stored curve, or the stored curve doesn't match the
    /// currently-connected mic.
    func currentCurve(forMicName micName: String) -> MicCalibrationCurve? {
        guard isEnabled, let curve, curve.micName == micName else { return nil }
        return curve
    }

    /// The curve already resolved for whichever mic is currently connected —
    /// `ContentView` keeps `curve` current via `load(forMicName:)` every time
    /// the input changes, so a consumer that isn't itself tracking live audio
    /// (WavPlayer, reviewing a past recording) can just use this rather than
    /// re-deriving a mic name it has no way to know. Recordings aren't
    /// tagged with which mic captured them, so this is a deliberate
    /// simplification: apply today's calibration to everything, not a
    /// per-recording historical match.
    var activeCurve: MicCalibrationCurve? {
        isEnabled ? curve : nil
    }
}
