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

/// The remote kill switches, listed so they can be turned back on by hand.
///
/// Only a remotely-disabled feature has anything to override: a feature that is
/// simply on shows as on and cannot be switched off here. This menu restores
/// the app to what shipped — it does not configure it — which is what keeps
/// every switch in it incapable of producing an app that does more than the one
/// Apple reviewed.
struct ConfigFeatureSection: View {
    let flags: FeatureFlagStore

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Features")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(flags.source.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(Feature.allCases) { feature in
                VStack(alignment: .leading, spacing: 2) {
                    Toggle(feature.title, isOn: Binding(
                        get: { flags.isEnabled(feature) },
                        set: { flags.setLocalOverride(feature, on: $0) }
                    ))
                    .font(.callout)
                    .disabled(!flags.isRemotelyDisabled(feature))
                    Text(flags.isRemotelyDisabled(feature)
                         ? "Switched off remotely. This turns it back on for this device only."
                         : feature.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let message = flags.maintenanceMessage {
                Text(message)
                    .font(.caption2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = flags.lastRefreshError {
                Text("Last check: \(error)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Clear device overrides") { flags.clearLocalOverrides() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}
