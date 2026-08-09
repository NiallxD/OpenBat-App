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

    /// Flat black nav bar on every screen, in every scroll state.
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
        appearance.backgroundColor = .black
        appearance.backgroundEffect = nil          // drop the glass/blur material
        appearance.shadowColor = .clear            // and the hairline separator
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.white]

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
        // The UI (dark spectrogram backgrounds, white/orange/green icon tints)
        // is designed for dark mode only — force it regardless of the system
        // appearance setting so light mode never washes it out.
        .preferredColorScheme(.dark)
    }
}
