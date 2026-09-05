//
//  Appearance.swift
//  OpenBat
//
//  Light, Dark, or whatever the phone is set to.
//
//  The app forced dark on everything until 2026-09-02 — the UI was drawn in
//  white at a dozen hard-coded call sites and light mode washed it out. Those
//  are semantic now (see `Color.appBackground`, `Color.glassEdge`), so the app
//  can follow the phone; this is the small amount on top of that, for the people
//  who want one or the other regardless of what the phone does at sunset.
//
//  **Device is the default and the honest answer.** The phone already has this
//  setting, including a schedule, and an app that quietly ignores it is the
//  thing being complained about. This exists for the two cases the phone's own
//  switch can't serve: someone who wants OpenBat dark in daylight because they
//  are about to go out with it, and someone who wants it light because the
//  spectrogram reads better that way for them.
//
//  Sits beside `SimplifiedView` deliberately: they are the two questions the app
//  asks about how it should look, they are asked together in the About tour's
//  view-mode step, and they sit together in Settings under Interface.
//

import SwiftUI

/// The app's appearance setting, persisted under one key.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// The `@AppStorage` key. Declared here rather than typed at each call site
    /// — the same rule `SimplifiedView.key` follows, and for the same reason: a
    /// mistyped key is a setting that silently stops being shared.
    static let key = "ui.appearance"

    var id: String { rawValue }

    /// "Device", not "System" or "Automatic". It names the thing the reader can
    /// point at, which is the phone in their hand.
    var label: String {
        switch self {
        case .system: "Device"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    /// What to hand `preferredColorScheme`. Nil means "don't express a
    /// preference", which is what lets the phone's own setting through.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light:  .light
        case .dark:   .dark
        }
    }
}

/// The picker itself, so Settings and the About tour show the same control
/// rather than two that drift apart.
///
/// Segmented, three options, in the order a reader expects to find them:
/// the two explicit choices either side of the default they are opting out of
/// would read as a scale from light to dark with "Device" as its middle, so
/// Device leads instead — it is the answer, and the other two are the
/// exceptions to it.
struct AppearancePicker: View {
    @AppStorage(AppAppearance.key) private var stored = AppAppearance.system.rawValue

    var body: some View {
        Picker("Appearance", selection: Binding(
            get: { AppAppearance(rawValue: stored) ?? .system },
            set: { stored = $0.rawValue }
        )) {
            ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("Appearance")
    }
}
