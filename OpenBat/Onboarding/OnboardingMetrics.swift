//
//  OnboardingMetrics.swift
//  OpenBat
//
//  Vertical metrics for the first-run flow, and the check for whether an
//  ultrasonic microphone is actually plugged in.
//
//  **Why metrics are a type and not literals.** Every onboarding step is meant
//  to fit on screen without scrolling — the ScrollView is a safety net for
//  large Dynamic Type, not the intended reading experience. On a 667pt phone
//  (iPhone SE, the shortest screen iOS 18 runs on) the regular spacing loses
//  that by roughly a card and a half, so the flow silently becomes scrollable
//  on exactly the devices whose users are least likely to scroll. Rather than
//  cut the copy down to what an SE fits — which would leave every other phone
//  looking sparse — the same copy is drawn tighter there.
//
//  Resolved once from the screen rather than per-frame from a `GeometryReader`:
//  the flow is full-screen on iPhone and a fixed 480×780 card on iPad, so the
//  answer cannot change while it is up, and a GeometryReader at the root would
//  hand the whole flow a layout dependency it does not otherwise have.
//

import SwiftUI
import AVFAudio

struct OnboardingMetrics: Equatable {
    /// Point size of a step header's SF Symbol.
    var symbolSize: CGFloat
    /// Edge length of the app logo in a step header.
    var logoSize: CGFloat
    /// Edge length of `SonarPulseHero`'s ring box.
    var heroSize: CGFloat
    /// Gap between a header's icon, title and message.
    var headerSpacing: CGFloat
    /// Gap between a step's header and its stack of cards.
    var sectionSpacing: CGFloat
    /// Gap between cards within that stack.
    var cardSpacing: CGFloat
    /// Padding inside one card.
    var cardPadding: CGFloat
    /// Padding above and below the scrolling column.
    var contentPadding: CGFloat
    /// Edge length of the glyph in a pinned caution footer.
    var footerGlyph: CGFloat
    /// Gap between a caution footer and the button bar beneath it.
    var footerBottomPadding: CGFloat

    static let regular = OnboardingMetrics(
        symbolSize: 56, logoSize: 64, heroSize: 128,
        headerSpacing: 16, sectionSpacing: 20, cardSpacing: 10, cardPadding: 12,
        contentPadding: 24, footerGlyph: 76, footerBottomPadding: 28)

    /// Same layout, ~110pt shorter over a three-card step. Nothing here changes
    /// a font size — text stays at the size the rest of the app uses it at, and
    /// only the air around it is taken back.
    static let compact = OnboardingMetrics(
        symbolSize: 42, logoSize: 52, heroSize: 96,
        headerSpacing: 10, sectionSpacing: 12, cardSpacing: 8, cardPadding: 10,
        contentPadding: 12, footerGlyph: 56, footerBottomPadding: 16)

    /// The shortest screen that still gets the roomy layout. iPhone SE (667pt)
    /// and its 2nd-generation twin fall below; every other iOS 18 device — the
    /// 13 mini's 812pt included — is above it.
    private static let compactBelowHeight: CGFloat = 700

    /// Resolved from the active window scene. Falls back to `.regular` when
    /// there is no scene to ask (previews, unit tests), which is the safe way
    /// round: too much air merely scrolls, too little is permanently cramped.
    static func forCurrentScreen() -> OnboardingMetrics {
        let height = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen.bounds.height
        guard let height else { return .regular }
        return height < compactBelowHeight ? .compact : .regular
    }
}

// MARK: - Environment

private struct OnboardingMetricsKey: EnvironmentKey {
    static let defaultValue = OnboardingMetrics.regular
}

extension EnvironmentValues {
    /// Read by the shared onboarding components (`OnboardingStepView`,
    /// `OnboardingCard`, the permission rows) so they size themselves without
    /// every call site passing metrics down by hand. `OnboardingView` injects
    /// the resolved value; the `.regular` default is what `AboutAppTour` and
    /// SwiftUI previews get, which is correct for both.
    var onboardingMetrics: OnboardingMetrics {
        get { self[OnboardingMetricsKey.self] }
        set { self[OnboardingMetricsKey.self] = newValue }
    }
}

// MARK: - Microphone presence

/// Whether a USB audio input — the ultrasonic microphone the app cannot work
/// without — is currently attached.
///
/// Onboarding says so on the welcome step, because "you need a microphone" as
/// a standing warning and "there isn't one plugged in" as a statement of fact
/// are very different messages, and the second is the one that stops a user
/// concluding the app is broken.
///
/// The category has to be set first: under the default playback-only category
/// `availableInputs` hides input devices entirely, so the microphone would be
/// invisible here even when connected — the same trap
/// `AudioEngineController.prepareInputMonitoring` documents. The session is
/// **not** activated, so this prompts for nothing, interrupts no other app's
/// audio, and works before the microphone permission has been granted.
enum UltrasonicMicProbe {
    static func isConnected() async -> Bool {
        await Task.detached(priority: .utility) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.record, mode: .measurement, options: [])
            return session.availableInputs?.contains { $0.portType == .usbAudio } ?? false
        }.value
    }

    /// Seconds between checks while onboarding is on screen.
    ///
    /// Polled rather than observed: `AVAudioSession.routeChangeNotification` is
    /// only delivered while the session is *active*, and activating it here is
    /// exactly what this must not do. Someone reading the welcome step and
    /// plugging their microphone in as they read is the case worth catching.
    static let pollInterval: Duration = .seconds(2)
}
