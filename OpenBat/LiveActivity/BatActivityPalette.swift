//
//  BatActivityPalette.swift
//  OpenBat
//
//  ⚠️ ALSO A MEMBER OF BOTH TARGETS via the same pbxproj exception set — see the note
//  at the top of BatDetectorAttributes.swift.
//

import SwiftUI

/// The two OpenBat brand colours, sampled from `OpenBat_Logo.png`.
///
/// The app already has `Color.batAccent` (#E9831D) in ContentView.swift as the single
/// source of truth for the orange, but that lives in the app target and this file has to
/// compile in the widget process too. The values are kept deliberately close rather than
/// identical: `batAccent` is tuned to read against the app's dark spectrogram chrome,
/// while `logoOrange` is the literal logo ink, which holds up better against the navy
/// card. If you restyle one, look at the other.
enum BatActivityPalette {

    /// #22344E — the card's base navy, the darker of the two logo-derived blues.
    static let navy = Color(red: 0.133, green: 0.204, blue: 0.306)

    /// A touch lighter than `navy`, for the image well and stat chips so they read as
    /// inset rather than floating.
    static let navyRaised = Color(red: 0.180, green: 0.247, blue: 0.365)

    /// Black at the top fading into `navy`. Painted by the card itself rather than passed
    /// to `.activityBackgroundTint`, which only accepts a flat `Color` — so the tint is
    /// set to `navy` as well, and any sliver the content doesn't cover matches the
    /// gradient's bottom instead of showing a seam.
    ///
    /// `.top`→`.bottom` in a Live Activity is unaffected by the viewer's light/dark
    /// setting: the card always renders on the lock screen's dark chrome, so this is one
    /// of the rare places a fixed dark treatment is correct rather than lazy.
    static let cardBackground = LinearGradient(
        colors: [.black, navy],
        startPoint: .top,
        endPoint: .bottom
    )

    /// #E9831D — matches `Color.batAccent` in ContentView.swift.
    static let orange = Color(red: 0.914, green: 0.514, blue: 0.114)

    /// #D46B28 — the logo's own orange, a shade deeper. Used for strokes and the
    /// dimmed state of the live dot, where the brighter accent is too loud.
    static let orangeDeep = Color(red: 0.831, green: 0.420, blue: 0.157)

    /// Body text on navy.
    static let ink = Color.white
    /// Labels and units on navy. Not `.secondary` — that resolves against the system
    /// background, not our tint, and comes out muddy on the navy.
    static let inkMuted = Color.white.opacity(0.62)
    /// Stale/absent values.
    static let inkFaint = Color.white.opacity(0.38)
}
