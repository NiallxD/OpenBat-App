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
//  A FIXED LIST, WITH NO "OTHER"
//  -----------------------------
//  This string is written into every recording's metadata and posted publicly
//  to iNaturalist. A free-text box invites somebody to type something they did
//  not think of as public — people name their own equipment — and there is no
//  reliable way to sanitise a sentence a person wrote. So the only values are
//  the ones in `known`; a microphone that isn't on the list is a reason to add
//  it to the list.
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
    /// Short on purpose and not a placeholder — very few devices work as
    /// class-compliant USB audio at 384 kHz, so this is maintained by hand
    /// rather than fetched. Add to it as they turn up.
    ///
    /// The generic entry is what stands in for "Other" now that there is no
    /// text field. It says the one thing that is both true and useful about an
    /// unlisted mic — that a real ultrasonic microphone was used, rather than
    /// the phone's own — and it says it in the same words for everybody, which
    /// is exactly what a free-text box could not do.
    static let known = ["Griff Mini by Phil Atkin", "Generic Ultrasonic Mic"]

    private static let choiceKey = "detector.model"

    static var choice: String {
        get { UserDefaults.standard.string(forKey: choiceKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: choiceKey) }
    }

    /// What to actually write into a file or an observation, or nil when the
    /// user hasn't said.
    ///
    /// **Only ever a value from `known`.** There was briefly an "Other" option
    /// with a text field, removed on Niall's call the same day (2026-09-04),
    /// erring towards privacy: this string is written into the GUANO metadata
    /// of every recording and posted publicly to iNaturalist, and people put
    /// their own names on their equipment. A fixed list cannot leak anything a
    /// user did not realise they were publishing, and a name that isn't on the
    /// list is a reason to add it to the list. Anything stored by an older
    /// build that isn't in `known` is ignored rather than trusted.
    ///
    /// Read straight from `UserDefaults` rather than passed in, because the one
    /// caller that matters is on the recording queue building a GUANO chunk and
    /// this way it cannot go stale: a user who changes the setting mid-session
    /// has the next file written correctly. `UserDefaults` reads are
    /// thread-safe, and this happens once per file, not per buffer.
    static var current: String? {
        let choice = choice
        return known.contains(choice) ? choice : nil
    }
}
