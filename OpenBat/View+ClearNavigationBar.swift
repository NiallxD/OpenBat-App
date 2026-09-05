//
//  View+ClearNavigationBar.swift
//  OpenBat
//
//  Per-screen opt-out from the app's flat navigation bar, for screens
//  whose own content should run all the way to the top of the window.
//
//  Worth knowing which lever actually controls that bar, because the obvious
//  one doesn't: **`toolbarBackground(_:for:)` is deprecated on iOS 26 and no
//  longer takes effect.** The `.toolbarBackground(…, for: .navigationBar)`
//  calls dotted around this app are inert there; the flat bar comes from the
//  UIKit appearance proxy in `OpenBatApp.configureNavigationBarAppearance`,
//  which sets an opaque background on every bar in the app. This is the
//  supported per-screen override of it.
//
//  Pair it with `.ignoresSafeArea(edges: .top)` on the screen's content —
//  clearing the bar's background only stops the bar painting, it doesn't move
//  the content up, so on its own it just swaps a painted bar for a bare gap in
//  the same colour.
//

import SwiftUI

extension View {
    /// Stops the navigation bar painting its own background, so the content
    /// behind it shows through.
    @ViewBuilder
    func clearNavigationBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        } else {
            toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}
