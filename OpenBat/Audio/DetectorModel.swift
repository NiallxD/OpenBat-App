//
//  DetectorModel.swift
//  OpenBat
//
//  Which ultrasonic microphone the user is recording with.
//
//  WHY ASK RATHER THAN DETECT
//  --------------------------
//  iOS reports a USB audio device's own port name, and that name is written by
//  whoever built the firmware — it is an identifier, not a product name. The
//  Griff announces itself as `bat_detector_usb`, which went into every GUANO
//  file's `Make` field and is useless to anyone reading the recording later: it
//  says "a USB bat detector", which they could already see.
//
//  There is no lookup table that fixes this, because there is no registry to
//  look it up in. The set of microphones that work as standard USB audio at
//  384 kHz is small and known, so the honest way to get a real name into the
//  metadata is to ask once and remember it.
//
//  WHERE IT ENDS UP
//  ----------------
//    • GUANO `Make`, replacing the port name — see `AudioRecorder.makeGuanoChunk`.
//    • iNaturalist observation field 567, "Bat detector model", which is the
//      most-used field on acoustic bat records by a wide margin.
//
//  Both are read by other people's tools, which is the whole reason this is
//  worth a setting. Unset means unset: the recorder falls back to the port name
//  rather than guessing, because a wrong detector name in an archived recording
//  is worse than a vague one.
//

import Foundation

nonisolated enum DetectorModel {

    /// The microphones offered by name.
    ///
    /// One entry today, and that is not a placeholder — very few devices work
    /// as class-compliant USB audio at 384 kHz, so this list is expected to
    /// stay short and to be maintained by hand rather than fetched. Add to it
    /// as they turn up; `other` covers everything else in the meantime.
    static let known = ["Griff Mini by Phil Atkin"]

    /// The stored choice: one of `known`, or `otherKey` with a name typed into
    /// `customName`.
    static let otherKey = "other"

    private static let choiceKey = "detector.model"
    private static let customKey = "detector.customName"

    static var choice: String {
        get { UserDefaults.standard.string(forKey: choiceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

    static var customName: String {
        get { UserDefaults.standard.string(forKey: customKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: customKey) }
    }

    /// What to actually write into a file or an observation, or nil when the
    /// user hasn't said.
    ///
    /// Read straight from `UserDefaults` rather than passed in, because the one
    /// caller that matters is on the recording queue building a GUANO chunk and
    /// this way it cannot go stale: a user who changes the setting mid-session
    /// has the next file written correctly. `UserDefaults` reads are
    /// thread-safe, and this happens once per file, not per buffer.
    static var current: String? {
        let choice = choice
        if choice == otherKey {
            let typed = customName.trimmingCharacters(in: .whitespacesAndNewlines)
            return typed.isEmpty ? nil : typed
        }
        return choice.isEmpty ? nil : choice
    }
}
