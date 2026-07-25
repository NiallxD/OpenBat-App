//
//  OpenBatApp.swift
//  OpenBat
//
//  Created by Niall Bell on 27/06/2026.
//

import SwiftUI

@main
struct OpenBatApp: App {
    @AppStorage("onboarding.hasCompletedWelcome") private var hasCompletedOnboarding = false
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // RecordingUploader reads these two keys directly from UserDefaults
        // (rather than through a captured @AppStorage snapshot — see its own
        // doc comment) so a Settings change takes effect on the very next
        // recording, not just after a relaunch. Registering the same defaults
        // SettingsView's @AppStorage declares keeps a fresh install's raw
        // UserDefaults read correct before either key has ever been written.
        UserDefaults.standard.register(defaults: [
            "community.uploadOverWiFiOnly": true,
            "community.autoUploadEnabled": false,
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

    var body: some Scene {
        WindowGroup {
            Group {
                // Gates ContentView (and its .onAppear side effects, including the
                // location region-fix request) behind first-run onboarding, so no
                // system permission dialog ever fires before its explanatory screen.
                if hasCompletedOnboarding {
                    ContentView()
                        .transition(.opacity)
                } else {
                    OnboardingView {
                        withAnimation(.easeInOut(duration: 0.4)) { hasCompletedOnboarding = true }
                    }
                    .transition(.opacity)
                }
            }
                // The UI (dark spectrogram backgrounds, white/orange/green icon
                // tints) is designed for dark mode only — force it regardless of
                // the system appearance setting so light mode never washes it out.
                .preferredColorScheme(.dark)
        }
    }
}
