//
//  ReleaseState.swift
//  OpenBat
//
//  What the app remembers about which build the user has already met: whether
//  to show What's New, and whether this release asked for onboarding to be run
//  again.
//
//  Both questions are decided ONCE, at launch, in `evaluateLaunch()` — before
//  `RootView` chooses between onboarding and the detector, because one of the
//  answers changes that choice. Everything after that reads a stored decision
//  rather than re-deriving it, so nothing can flip mid-session.
//
//  Two rules that are easy to get wrong and unpleasant when you do:
//
//  1. **A fresh install never sees What's New.** There is nothing "new" about
//     the app to someone who has never run it, and a changelog is a poor first
//     screen. The first launch stamps the build as seen and shows nothing.
//  2. **Re-onboarding is stamped the moment it is triggered, not when it
//     finishes.** Those look equivalent and are not: stamping on completion
//     means someone who quits the app halfway through the flow is put back
//     through it on the next launch, and again after that. It fires once per
//     build, whatever the user does with it.
//

import Foundation

@Observable
final class ReleaseState {
    /// Shared for the same reason `OnboardingState` is — the answer outlives any
    /// one screen, and `RootView` and `ContentView` both need it.
    static let shared = ReleaseState()

    private static let lastSeenBuildKey = "release.lastSeenBuild"
    private static let reonboardedBuildKey = "release.reonboardedBuild"

    /// The build whose What's New the user has already dismissed.
    private var lastSeenBuild: String {
        didSet { UserDefaults.standard.set(lastSeenBuild, forKey: Self.lastSeenBuildKey) }
    }

    /// The build that has already had its chance to re-run onboarding. See rule
    /// 2 in this file's header for why this is separate from `lastSeenBuild`.
    private var reonboardedBuild: String {
        didSet { UserDefaults.standard.set(reonboardedBuild, forKey: Self.reonboardedBuildKey) }
    }

    /// Set by `evaluateLaunch()`, read by `ContentView` once it appears.
    private(set) var shouldShowWhatsNew = false

    /// Whether `evaluateLaunch` has already run this process.
    ///
    /// **Its caller is a `View.init`, which SwiftUI may run more than once** —
    /// a view struct is re-created whenever its parent's body is re-evaluated,
    /// and nothing about `RootView` promises that happens exactly once. Without
    /// this guard the second run saw a world the first run had already changed:
    /// `hasCompletedOnboarding` was now false (the first run cleared it to
    /// re-show the intro), so it took the fresh-install branch and stamped the
    /// build as seen. Quit partway through that re-run intro and What's New
    /// never appeared for the update at all — the exact outcome rule 2 in this
    /// file's header exists to prevent, arriving by a different road.
    private var hasEvaluated = false

    /// `CFBundleVersion` — the build number, not the marketing version. A
    /// TestFlight build that fixes something without moving the version string
    /// is still a new build to the person installing it.
    static var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private init() {
        lastSeenBuild = UserDefaults.standard.string(forKey: Self.lastSeenBuildKey) ?? ""
        reonboardedBuild = UserDefaults.standard.string(forKey: Self.reonboardedBuildKey) ?? ""
    }

    /// Decides what this launch owes the user. Call exactly once, before the
    /// root view picks a screen.
    ///
    /// `hasCompletedOnboarding` is passed in rather than read from
    /// `OnboardingState` here so this stays a pure decision with one caller —
    /// and so the "fresh install" case is decided by whether onboarding has ever
    /// been completed, not by guessing from an empty build string alone. The two
    /// disagree exactly once: someone who installed an old build, never finished
    /// onboarding, and has now updated. They get onboarding, and no changelog,
    /// which is the right answer.
    func evaluateLaunch(hasCompletedOnboarding: Bool) -> LaunchDecision {
        // Idempotent, because the caller cannot promise to call it once — see
        // `hasEvaluated`.
        //
        // A repeat answers `.nothing` rather than replaying the first answer,
        // and that is the important half. `.runOnboardingAgain` is a one-shot
        // instruction the caller has already carried out; handing it back a
        // second time — after the user has since finished the intro — would
        // clear `hasCompletedWelcome` and drop them into onboarding again, and
        // again, for as long as the view kept being re-created. `.showWhatsNew`
        // is not lost by staying quiet here either: it lives in
        // `shouldShowWhatsNew`, which `ContentView` reads when it appears.
        guard !hasEvaluated else { return .nothing }
        hasEvaluated = true

        let build = Self.currentBuild
        guard build != lastSeenBuild else { return .nothing }

        // Never run onboarding, never met a build: stamp and stay quiet.
        guard hasCompletedOnboarding else {
            lastSeenBuild = build
            return .nothing
        }

        // Existing user on a new build. What's New waits until something is on
        // screen to present it over — ContentView reads `shouldShowWhatsNew`.
        shouldShowWhatsNew = true

        if ChangeLog.latest.requiresReonboarding, reonboardedBuild != build {
            reonboardedBuild = build
            return .runOnboardingAgain
        }
        return .showWhatsNew
    }

    /// Called when What's New is dismissed. Deliberately NOT called when it is
    /// presented: an app killed while the sheet is up should show it again, not
    /// swallow the one notice the user gets about what changed.
    func markWhatsNewSeen() {
        shouldShowWhatsNew = false
        lastSeenBuild = Self.currentBuild
    }

    enum LaunchDecision: Equatable {
        case nothing
        case showWhatsNew
        /// The release asked for onboarding to be shown again. What's New still
        /// follows it — the changelog is what explains why the intro reappeared.
        case runOnboardingAgain
    }

    #if DEBUG
    /// Puts the app back to "never seen this build", for checking the flow
    /// without reinstalling. Debug menu only.
    func resetForTesting() {
        lastSeenBuild = ""
        reonboardedBuild = ""
        shouldShowWhatsNew = false
        // Or the next `evaluateLaunch` short-circuits and the reset does nothing
        // visible until the app is relaunched — which is most of what this is
        // for.
        hasEvaluated = false
    }
    #endif
}
