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
    private static let handoffKey = "onboarding.justFinishedOnboarding"
    private static let simplifiedTourKey = "tour.hasCompletedSimplified"
    private static let advancedTourKey = "tour.hasCompletedAdvanced"
    private static let nudgeKey = "tour.hasNudged"

    var hasCompletedWelcome: Bool {
        didSet { UserDefaults.standard.set(hasCompletedWelcome, forKey: Self.key) }
    }

    /// Set by onboarding's last step just before it hands off to `ContentView`;
    /// consumed once, there, to run whatever should happen on the very first
    /// arrival at the detector — currently only the recommended-model offer, if
    /// the location fix landed in time to find one. It used to also auto-launch
    /// the guided tour; that stopped when the last step became "Let's go!"
    /// rather than "Take the Tour".
    ///
    /// A second flag rather than folding into `hasCompletedWelcome` so `RootView`
    /// — which only reads that one property — never re-evaluates when this one
    /// changes (see this file's header comment on why `@AppStorage` at the root
    /// is dangerous; a second plain `@Observable` property has the same
    /// one-property-at-a-time tracking, it just isn't read by the same view).
    var justFinishedOnboarding: Bool {
        didSet { UserDefaults.standard.set(justFinishedOnboarding, forKey: Self.handoffKey) }
    }

    /// Whether the guided tour has been seen to the end, tracked separately for
    /// the two interface modes — see `shouldOfferTour(simplified:)` for why one
    /// flag would not do.
    var hasCompletedSimplifiedTour: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSimplifiedTour, forKey: Self.simplifiedTourKey) }
    }
    var hasCompletedAdvancedTour: Bool {
        didSet { UserDefaults.standard.set(hasCompletedAdvancedTour, forKey: Self.advancedTourKey) }
    }

    /// Whether the tour's popover has already opened itself once, unprompted.
    ///
    /// The tour button is easy to miss — it is one small glyph in a nav bar, and
    /// someone who has never used a bat detector does not know there is a tour to
    /// look for. So the popover opens itself a short while after the first arrival
    /// at the detector (`ContentView.nudgeTourAfterDelay`), which is the point at
    /// which the screen has stopped being new and started being confusing.
    ///
    /// **Exactly once, ever, per install.** A nudge that returns is nagging, and
    /// the button it points at stays put for anyone who dismissed it and changed
    /// their mind. Set the moment the popover is *shown*, not when the tour is
    /// taken or declined — the nudge has done its job either way.
    var hasNudgedTour: Bool {
        didSet { UserDefaults.standard.set(hasNudgedTour, forKey: Self.nudgeKey) }
    }

    /// Whether the Detector should still show its "take the tour" button.
    ///
    /// **Deliberately asymmetric, because the two tours are not peers.** The
    /// advanced tour is a superset: it covers everything the simplified one does
    /// and then every control that mode hides. So finishing the advanced tour
    /// means there is nothing left to be shown, in either mode, ever — the button
    /// goes for good. Finishing the *simplified* tour only means you have seen the
    /// short version, so switching to advanced brings the button back, offering
    /// the longer tour for the controls that just appeared.
    ///
    /// The button is the only thing this governs. The tour itself stays reachable
    /// from Info & Tour forever, for anyone who wants it again.
    func shouldOfferTour(simplified: Bool) -> Bool {
        if hasCompletedAdvancedTour { return false }
        return !(simplified && hasCompletedSimplifiedTour)
    }

    /// Records a tour seen all the way to its last step.
    ///
    /// Only a finished tour counts — ending one early leaves the button where it
    /// is. Someone who taps "End tour" after two steps has not been shown the
    /// screen, and taking the affordance away because they dismissed it is how a
    /// user ends up with no way back to something they meant to come back to.
    func recordTourCompleted(simplified: Bool) {
        if simplified { hasCompletedSimplifiedTour = true } else { hasCompletedAdvancedTour = true }
    }

    private init() {
        // Absent key reads as false — a fresh install starts at onboarding.
        hasCompletedWelcome = UserDefaults.standard.bool(forKey: Self.key)
        justFinishedOnboarding = UserDefaults.standard.bool(forKey: Self.handoffKey)
        hasCompletedSimplifiedTour = UserDefaults.standard.bool(forKey: Self.simplifiedTourKey)
        hasCompletedAdvancedTour = UserDefaults.standard.bool(forKey: Self.advancedTourKey)
        hasNudgedTour = UserDefaults.standard.bool(forKey: Self.nudgeKey)
    }
}
