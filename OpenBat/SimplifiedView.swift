//
//  SimplifiedView.swift
//  OpenBat
//
//  The app-wide interface mode: what "Simplified view" hides, and the defaults
//  it applies on the way in.
//
//  The detector screen carries a lot of instrumentation, and most of it is only
//  legible to someone who already knows what a bat call looks like. "Fpeak",
//  "Bndwth" and a compressed-timeline toggle are the tools of someone reading
//  calls; they are noise to someone who wants to know which bat just flew over.
//  Simplified view is the default for that reason — the full set is one switch
//  away in Settings, and nothing is deleted by turning it on.
//
//  ## Two different mechanisms, and why
//
//  Some of what this mode changes is a *permanent override* while it is on, and
//  some is a *default applied once* on the way in. The rule is whether the
//  control that would change it back is still visible:
//
//  • **Overridden** — the species-ID toggles on both panels. Their buttons are
//    hidden in simplified view, so if the stored value were honoured a user
//    could be stuck looking at a pulse close-up with no way back. `effective…`
//    below forces them, reading the stored value only in advanced mode, so the
//    user's own choice survives untouched and returns when they switch back.
//
//  • **Applied once** — the 15–90 kHz frequency band. The band settings button
//    IS still shown in simplified view (it is the one control there that
//    genuinely needs tweaking in the field), so forcing it would fight the user
//    every time they adjusted it. `applyDefaults` writes it on the way in
//    instead, and then leaves it alone.
//
//  Getting this backwards in either direction is the bug to watch for: an
//  override on the band makes the visible slider inert, and a write-once on the
//  species toggles strands the user in a view with no exit.
//
//  ## The one exception
//
//  iPad landscape shows the species list in a panel of its own, permanently.
//  Forcing the pulse card to species ID there gave the user the same list twice,
//  side by side — so in that layout the override runs the other way and the
//  pulse card shows the pulse. The rule still holds: the reason for the override
//  is that a hidden toggle must never leave the user with no route to species
//  ID, and there the route is the panel next door. See
//  `padLandscapePulseShowsSpeciesID` in `ContentView.swift`.
//

import SwiftUI

enum SimplifiedView {
    /// `true` by default, deliberately: the first run of a bat detector should
    /// show the bat, not the instrumentation. Onboarding asks, so a new user
    /// makes the call themselves; existing installs land here too (Niall's
    /// call, 2026-08-16) rather than being grandfathered into advanced.
    static let key = "ui.simplifiedMode"

    /// Which band `applyDefaults` last applied, and empty on the way out of
    /// simplified view so re-entering re-applies. Without it, the band would
    /// either never be applied (a fresh install that leaves the onboarding
    /// toggle untouched fires no `onChange`) or be re-applied on every launch,
    /// reverting the user's own tweak from the one settings button simplified
    /// view still shows.
    ///
    /// **The band it applied, not a bare "done" flag** (2026-09-09). The two
    /// numbers below can now be set remotely, and a flag could not tell "this
    /// stint has been set up" from "set up with the band we no longer use" — so
    /// a changed default would have reached only installs that had never
    /// entered simplified view, which is almost none of them. Storing what was
    /// applied makes the question answerable: same band, leave the user's
    /// tweak alone; different band, apply the new one.
    static let defaultsAppliedKey = "ui.simplifiedDefaultsApplied"

    /// The stamp written to `defaultsAppliedKey`, and the thing compared
    /// against it.
    static var bandStamp: String { "\(Int(bandLowHz)),\(Int(bandHighHz))" }

    /// Most bat calls fall in this band, and it is what the bat-range button
    /// sets in advanced mode — that button is hidden here, so simplified view
    /// starts there instead of at the full 0–192 kHz, where a phone's own
    /// low-frequency noise dominates the picture.
    static var bandLowHz: Double { Tunable.simplifiedBandLowHz.value(15_000) }
    static var bandHighHz: Double { Tunable.simplifiedBandHighHz.value(90_000) }
}

extension View {
    /// Hides a control that only exists in advanced view. `.hidden()` would keep
    /// its space in the layout; this removes it from the tree entirely, which is
    /// what the panel headers need — a row of pills with gaps where buttons used
    /// to be is worse than a shorter row.
    @ViewBuilder
    func advancedOnly(_ simplified: Bool) -> some View {
        if !simplified { self }
    }
}
