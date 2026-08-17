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
    /// Mic names the first-connection offer has already been made for.
    private static let keyOffered = "MicCal.offeredMics"

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

    // MARK: First-connection offer

    /// Whether the app should offer to calibrate `micName` on sight.
    ///
    /// Two conditions, and the second is the one that matters. There must be no
    /// stored curve for this mic — obviously — **and the offer must not already
    /// have been made for it.** Without that second half, "Not now" is not an
    /// answer: the offer would come back on the next reconnect, and on the one
    /// after that, which turns a helpful nudge into something a user learns to
    /// dismiss without reading.
    ///
    /// Keyed by mic name rather than a single global flag, so someone who
    /// declines for one microphone and later attaches a different one is asked
    /// about the new one. The curve is stored per mic name too — a calibration
    /// measures a particular piece of hardware's response, so a second mic
    /// genuinely is a new question.
    func shouldOfferCalibration(forMicName micName: String) -> Bool {
        guard !micName.isEmpty, micName != "—" else { return false }
        guard UserDefaults.standard.data(forKey: Self.curveKey(forMicName: micName)) == nil
        else { return false }
        return !offeredMics.contains(micName)
    }

    /// Records that the offer has been made, however it was answered.
    ///
    /// Called when the prompt is *shown*, not when it is accepted. Someone who
    /// taps Calibrate and then abandons the capture has still been told this
    /// exists and where to find it; re-asking them is the same nagging the
    /// name-keyed check above exists to prevent. Settings is the way back.
    func recordCalibrationOffered(forMicName micName: String) {
        guard !micName.isEmpty, micName != "—" else { return }
        var mics = offeredMics
        guard mics.insert(micName).inserted else { return }
        UserDefaults.standard.set(Array(mics), forKey: Self.keyOffered)
    }

    private var offeredMics: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.keyOffered) ?? [])
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
