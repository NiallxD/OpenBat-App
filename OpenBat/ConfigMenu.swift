//
//  ConfigMenu.swift
//  OpenBat
//
//  The controls that are in the app for situations that need them, behind a
//  passcode because they can break it.
//
//  WHY IT IS VISIBLE RATHER THAN HIDDEN
//  ------------------------------------
//  This replaces a menu reached by tapping the version number fifteen times.
//  A hidden menu that unlocks functionality is the exact shape of Apple's
//  guideline on undocumented features, and hiding it was buying nothing: the
//  people it kept out were the people it was for. It now sits in Settings where
//  a reviewer will find it, says plainly what it is, and asks for a passcode —
//  which is a much better answer to "should a user be in here" than a gesture
//  nobody can perform by accident but anybody can perform on purpose.
//
//  The ten-tap bat swarm on the version number stays. It was always the better
//  half of that gesture.
//
//  THE PASSCODE IS A SPEED BUMP, AND THAT IS ALL IT IS
//  ---------------------------------------------------
//  It is derived from the device's own date by code in a public repository, so
//  anyone who reads the source can produce today's. Deriving it from the date
//  buys one thing only, and it is the thing that matters: a code passed to a
//  tester, or posted in a forum, stops working tomorrow.
//
//  What makes that acceptable is `Feature.configMenu` — every switch in here
//  can only restore what Apple already reviewed, and the one control with a
//  cost outside this app (the posting-cap bypass) disappears along with the
//  whole menu the moment the config file says so. See `FeatureFlags.swift`.
//

import SwiftUI

/// Today's passcode.
///
/// `Bats` plus the device's own date as ddmmyyyy. The DEVICE's date, in its own
/// timezone — a tester in another country uses their date, not ours, which is
/// the answer that needs no explaining when somebody says the code doesn't
/// work.
nonisolated enum ConfigPasscode {
    static func today(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ddMMyyyy"
        return "Bats" + formatter.string(from: date)
    }

    static func accepts(_ entered: String, on date: Date = Date()) -> Bool {
        // Case-insensitive: this gets typed on a phone keyboard that
        // capitalises the first letter of a field whether you want it to or
        // not, and rejecting `bats06092026` would be a puzzle with no purpose.
        entered.trimmingCharacters(in: .whitespaces)
            .compare(today(date), options: .caseInsensitive) == .orderedSame
    }
}

/// The configuration menu's shared pieces. The menu itself is
/// `DiagnosticsView` — it already holds the demo feed, the tuning overlay and
/// the settings dump, which are exactly the "controls that can break the app"
/// this is about, so a second screen beside it would have split one idea in
/// two.
nonisolated enum ConfigMenu {
    /// Niall's words, and they are the right ones: they say what the risk is
    /// and why the controls are in the app at all, which is what somebody who
    /// has just found this screen wants to know.
    static let explanation = "This menu is locked because its controls can break the app if not used correctly. We leave these in the app for situations where more control is needed"
}

/// The kill switches, listed so this device can decide them for itself.
///
/// **Both directions** (Niall, 2026-09-09). This was a list of switches that
/// were dead unless the config file had turned something off — so the one thing
/// the menu could not do was try the app WITHOUT a feature, which is most of
/// what a kill switch is for: seeing what a user sees the day it is thrown.
/// Every switch here now works, and `Clear device overrides` is the way back to
/// whatever the config file says.
///
/// It still cannot produce an app that does more than the one Apple reviewed:
/// on restores the compiled default and off takes something away. See
/// `FeatureFlagStore.setLocalOverride`.
struct ConfigFeatureSection: View {
    let flags: FeatureFlagStore

    var body: some View {
        Section {
            ForEach(Feature.allCases) { feature in
                SettingToggle(feature.title, note(for: feature), isOn: Binding(
                    get: { flags.isEnabled(feature) },
                    set: { flags.setLocalOverride(feature, on: $0) }
                ))
            }

            if let message = flags.maintenanceMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
            }
            if let error = flags.lastRefreshError {
                Text("Last check: \(error)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Clear device overrides") { flags.clearLocalOverrides() }
        } header: {
            CardHeader("Features", "What this device does, and what it doesn't") {
                Text(flags.source.rawValue)
                    .font(.caption)
                    .textCase(nil)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What the feature is, plus where its current answer is coming from — the
    /// two questions a switch in here raises, and neither of them fits on a row.
    private func note(for feature: Feature) -> String {
        var note = feature.detail
        if flags.isRemotelyDisabled(feature) {
            note += "\n\nSwitched off remotely by the OpenBat team."
        }
        if flags.isLocallyOverridden(feature) {
            note += "\n\nThis device is deciding it for itself. Clear device overrides puts it back to "
                  + "what the config file says."
        }
        return note
    }
}
