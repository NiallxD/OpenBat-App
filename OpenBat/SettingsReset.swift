//
//  SettingsReset.swift
//  OpenBat
//
//  Putting every preference back to the value a fresh install would have.
//
//  WHY IT IS A DENYLIST AND NOT A LIST OF SETTINGS
//  ----------------------------------------------
//  The obvious way to write this is to name every settings key and clear those.
//  It is also the way it silently stops working: the app has around sixty keys
//  across a dozen stores, a new one arrives with most features, and nobody
//  editing `AutoIDSettings` is going to remember a list living over here. A
//  reset that quietly misses the setting you just added is worse than no reset,
//  because it looks like it worked.
//
//  So this clears the app's whole preferences domain and names only what must
//  SURVIVE. A new preference is covered the day it is written, without anybody
//  doing anything, and the only thing a new key has to be checked against is
//  the short list below — which is not "settings", but "things that are not
//  settings at all".
//
//  WHAT SURVIVES, AND WHY EACH ONE
//  -------------------------------
//  Four kinds of thing, none of them a preference:
//
//    • Identity — `openbat.deviceID`. It ties this install to its uploads and
//      to the consent record held in the Keychain. A new id would orphan both.
//    • A record of what has already happened — `openbat.inat.posted` is the
//      ledger of observations posted. Clearing it would re-offer recordings
//      that are already on iNaturalist and undo the per-night posting cap,
//      which is somebody else's inbox.
//    • Where the files are — `storage.usesUbiquityContainer` decides whether
//      recordings live in iCloud or on the device. Resetting it does not move
//      anything; it points the app at the other place and the library looks
//      empty.
//    • Measurements and milestones — the mic calibration is a measurement of
//      hardware rather than a choice about it, and onboarding/What's New stamps
//      record something that happened. Wiping those would re-run the intro over
//      an app full of recordings.
//
//  Consent needs no entry here: it lives in the Keychain, not in defaults.
//
//  WHAT THIS DELIBERATELY DOES NOT DO
//  ----------------------------------
//  It does not touch recordings, sessions, passes, the classification log, or
//  the iNaturalist sign-in. Those are data and this is a settings button; a
//  control that quietly did both would be the last one anybody trusted.
//

import Foundation

enum SettingsReset {

    /// Keys that are not preferences, and must therefore outlive a reset. See
    /// this file's header for what each one is and what clearing it would cost.
    ///
    /// Prefix, not exact match, for `MicCal.` — the calibration writes a key per
    /// microphone it has met.
    static let preservedKeys: Set<String> = [
        "openbat.deviceID",
        "openbat.inat.posted",
        "storage.usesUbiquityContainer",
        "onboarding.hasCompletedWelcome",
        "onboarding.justFinishedOnboarding",
        "release.lastSeenBuild",
        "release.reonboardedBuild",
    ]

    static let preservedPrefixes: [String] = ["MicCal."]

    static func isPreserved(_ key: String) -> Bool {
        preservedKeys.contains(key) || preservedPrefixes.contains { key.hasPrefix($0) }
    }

    /// Clears every preference in the app's own domain.
    ///
    /// The app's domain and not `dictionaryRepresentation()`, which also carries
    /// the system's own keys — languages, keyboard state, the accessibility
    /// settings — inherited from other domains. Removing one of those from here
    /// does nothing useful and `persistentDomain(forName:)` never offers them.
    ///
    /// Returns what it cleared, so the confirmation can be honest about whether
    /// anything happened and the tests have something to assert on.
    @discardableResult
    static func eraseUserPreferences(in defaults: UserDefaults = .standard,
                                     domain: String = Bundle.main.bundleIdentifier ?? "") -> [String] {
        guard let contents = defaults.persistentDomain(forName: domain) else { return [] }
        let doomed = contents.keys.filter { !isPreserved($0) }
        for key in doomed { defaults.removeObject(forKey: key) }
        return doomed.sorted()
    }
}
