//
//  OpenBatApp.swift
//  OpenBat
//
//  App entry point. Owns the background-URLSession app delegate, the
//  once-at-launch storage migration gate, and the global nav-bar appearance
//  override. `RootView` is the onboarding gate in front of `ContentView`; keep
//  it a separate `View` rather than inlining it in the `WindowGroup` closure
//  (see its own doc comment for why that matters for re-evaluation cost).
//

import SwiftUI
import UIKit

@main
struct OpenBatApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.configureNavigationBarAppearance()

        // RecordingUploader reads these two keys directly from UserDefaults
        // (rather than through a captured @AppStorage snapshot — see its own
        // doc comment) so a Settings change takes effect on the very next
        // recording, not just after a relaunch. Registering the same defaults
        // SettingsView's @AppStorage declares keeps a fresh install's raw
        // UserDefaults read correct before either key has ever been written.
        UserDefaults.standard.register(defaults: [
            // iCloud storage on by default: the point of the container is that a
            // library survives an app delete or a new device.
            CloudStorage.keepInICloudKey: true
        ])

        // Before ANY store is constructed — see applyPendingStorageMigration's
        // doc comment for why this can't happen later in the process. Run off
        // the main thread (`setUbiquitous` is documented as not-for-main-thread)
        // but waited on, because ClassificationStore must not be built against a
        // root that's about to move. Only does work on the launch after the
        // user changes the setting, and moves are renames rather than copies.
        let migration = DispatchQueue.global(qos: .userInitiated).sync {
            CloudStorage.applyPendingStorageMigration()
        }
        CloudStorage.lastMigrationResult = migration
    }

    /// Flat nav bar on every screen, in every scroll state, in the ground colour
    /// of whichever appearance the phone is in.
    ///
    /// SwiftUI's `.toolbarBackground(Color…)` only supplies a background *colour*
    /// — under iOS 26 Liquid Glass the bar still composites its own translucent
    /// material and separator over the top, and on this app's black content that
    /// stack reads as a distinct grey bar rather than blending away. The UIKit
    /// appearance proxy is the only place the material itself can be removed
    /// (`backgroundEffect = nil`), so it's set here once for the whole app.
    ///
    /// All four appearances are assigned: `scrollEdge` is what shows with content
    /// at the top (the state the grey bar was most obvious in), `standard` once
    /// scrolled, and the two compact variants in landscape.
    private static func configureNavigationBarAppearance() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        // Dynamic UIColors, not `.black`/`.white`. An appearance proxy is
        // configured once at launch, but these resolve against the trait
        // collection at draw time, so the bar follows a light/dark switch made
        // while the app is running rather than needing a relaunch.
        // The page's colour, not `systemBackground` — see `Color.appBackground`
        // for why the light-mode page is a few percent of grey. A pure-white bar
        // over a grey page is a header strip nobody asked for.
        appearance.backgroundColor = UIColor(Color.appBackground)
        appearance.backgroundEffect = nil          // drop the glass/blur material
        appearance.shadowColor = .clear            // and the hairline separator
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]

        let bar = UINavigationBar.appearance()
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
        bar.compactScrollEdgeAppearance = appearance
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// The onboarding gate, in a `View` rather than inline in the `WindowGroup`
/// content closure.
///
/// Keeping it out of the Scene closure matters: whatever is written there is
/// re-evaluated whenever the `App`'s own body is, and that closure's job is to
/// construct `ContentView` — an initializer that seeds a dozen `@State` stores.
/// Inside a `View`, SwiftUI's own identity tracking means an unrelated
/// invalidation re-runs this `body` rather than the app's, and `ContentView`'s
/// initializer is only re-run when this view's is.
private struct RootView: View {
    private let onboarding = OnboardingState.shared
    /// Decided once, here, because one of its outcomes changes which branch
    /// below is taken. `init` rather than `.onAppear`: by the time `onAppear`
    /// runs, `body` has already chosen a screen, and re-running onboarding after
    /// the detector has been shown would be a visible flip rather than a
    /// decision. See `ReleaseState.evaluateLaunch`.
    init() {
        let decision = ReleaseState.shared.evaluateLaunch(
            hasCompletedOnboarding: OnboardingState.shared.hasCompletedWelcome)
        if decision == .runOnboardingAgain {
            OnboardingState.shared.hasCompletedWelcome = false
        }
    }

    var body: some View {
        Group {
            // Gates ContentView (and its .onAppear side effects, including the
            // location region-fix request) behind first-run onboarding, so no
            // system permission dialog ever fires before its explanatory screen.
            if onboarding.hasCompletedWelcome {
                ContentView()
                    .transition(.opacity)
            } else {
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.4)) { onboarding.hasCompletedWelcome = true }
                }
                .transition(.opacity)
            }
        }
        // The app forced dark mode on everything until 2026-09-02, because its
        // own chrome was white at a dozen hard-coded call sites and light mode
        // washed all of it out. Those are semantic now — see `Color.glassEdge` —
        // so the app follows the phone, or the Light/Dark/Device setting when
        // one is picked.
        //
        // The spectrogram follows too: in light mode every colormap is drawn as
        // a negative, so silence is white and calls are ink. That is one flag —
        // `DisplayColormap.inverted` — read by the Metal shader and by every CPU
        // colouring path. Everything drawn OVER a spectrogram (axis labels, grid
        // lines, cursors, annotation pills) moved to `.primary` with it: white
        // ink on a white plot is the obvious failure and the only reason those
        // were ever literal white.
        //
        // Under everything, so any screen that doesn't paint its own ground
        // gets the page colour rather than the window's flat white.
        .background(Color.appBackground.ignoresSafeArea())
        // Light / Dark / Device, applied by a LEAF and never read here — see
        // `AppearanceApplier` for the launch-time runaway that caused.
        .background(AppearanceApplier())
    }
}

/// Applies the app's appearance setting, and keeps the spectrogram's polarity in
/// step with whatever the app ends up drawn in.
///
/// **A leaf view, and it has to be** (Niall, 2026-09-02: the app stopped
/// launching, killed by the OS for using too much memory). `RootView` held both
/// halves of this: it applied `.preferredColorScheme` AND read
/// `@Environment(\.colorScheme)`. Applying the preference changes the window's
/// style, which changes that environment value, which re-evaluates the view that
/// read it — and `RootView`'s body constructs `ContentView`, whose initializer
/// seeds a dozen stores including the spectrogram's history buffers. Round and
/// round, allocating on every pass, until the OS stepped in. See `RootView`'s own
/// doc comment, which is about exactly this cost and predates the loop.
///
/// Here the two halves are in a view that draws nothing and builds nothing. The
/// environment can flip under it as often as it likes.
private struct AppearanceApplier: View {
    @AppStorage(AppAppearance.key) private var appearanceRaw = AppAppearance.system.rawValue
    /// The phone's own setting. Only consulted for "Device".
    @Environment(\.colorScheme) private var colorScheme

    private var appearance: AppAppearance {
        AppAppearance(rawValue: appearanceRaw) ?? .system
    }

    /// What the app is ACTUALLY drawn in, which is not always what this view's
    /// environment says: the stored choice wins where it has one, and the
    /// environment answers for "Device".
    private var effectiveScheme: ColorScheme {
        appearance.colorScheme ?? colorScheme
    }

    var body: some View {
        // Nil for Device, which is what lets the phone through — see
        // `AppAppearance`. The preference travels up from here to the window
        // just as it would from anywhere else in the tree.
        Color.clear
            .preferredColorScheme(appearance.colorScheme)
            .onAppear { DisplayColormap.inverted = effectiveScheme == .light }
            .onChange(of: effectiveScheme) { _, new in
                DisplayColormap.inverted = new == .light
            }
    }
}
