//
//  OnboardingState.swift
//  OpenBat
//
//  The "has the welcome flow been completed" flag, backing the root view's
//  onboarding gate.
//
//  Deliberately NOT `@AppStorage`. SwiftUI's `@AppStorage` observes
//  `UserDefaults.didChangeNotification`, which is posted for a write to ANY
//  key — so a property wrapper watching this one key still invalidates its view
//  when something entirely unrelated (the display palette, the spectrogram
//  noise floor) is persisted. At the root of the view tree that was ruinous:
//  every such write re-evaluated the `WindowGroup` content closure, which
//  re-ran `ContentView()`'s initializer, which re-ran all of its `@State`
//  default-value expressions — reconstructing every store in the app, on the
//  main thread, several times a second while a settings slider was moving.
//
//  `@Observable` tracks this one property and nothing else, so an unrelated
//  `UserDefaults` write no longer reaches the root view at all.
//

import Foundation

@Observable
final class OnboardingState {
    /// Shared because the flag outlives any one screen — same reasoning as
    /// `ConsentStore.shared`. `@Observable` tracks property reads in `body`
    /// regardless of how the reference is held, so a plain `let` still updates
    /// the view.
    static let shared = OnboardingState()

    private static let key = "onboarding.hasCompletedWelcome"
    private static let tourKey = "onboarding.shouldAutoStartTour"

    var hasCompletedWelcome: Bool {
        didSet { UserDefaults.standard.set(hasCompletedWelcome, forKey: Self.key) }
    }

    /// Set by onboarding's last step ("Take the Tour") just before it hands off to
    /// `ContentView`; consumed once, there, to auto-launch the guided tour. A second
    /// flag rather than folding into `hasCompletedWelcome` so `RootView` — which only
    /// reads that one property — never re-evaluates when this one changes (see this
    /// file's header comment on why `@AppStorage` at the root is dangerous; a second
    /// plain `@Observable` property has the same one-property-at-a-time tracking,
    /// it just isn't read by the same view).
    var shouldAutoStartTour: Bool {
        didSet { UserDefaults.standard.set(shouldAutoStartTour, forKey: Self.tourKey) }
    }

    private init() {
        // Absent key reads as false — a fresh install starts at onboarding.
        hasCompletedWelcome = UserDefaults.standard.bool(forKey: Self.key)
        shouldAutoStartTour = UserDefaults.standard.bool(forKey: Self.tourKey)
    }
}
