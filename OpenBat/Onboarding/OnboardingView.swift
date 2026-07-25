//
//  OnboardingView.swift
//  OpenBat
//
//  First-run flow: welcome → mic soft-ask (+ real dialog) → location soft-ask
//  (+ real dialog) → done. Gates every permission prompt behind an explanatory
//  screen shown first, so no OS dialog ever fires cold. `OpenBatApp` mounts this
//  instead of `ContentView` until `hasCompletedOnboarding` is set, which also
//  means `ContentView`'s own `.onAppear` (which calls
//  `location.requestRegionFix()` unconditionally) never runs before onboarding
//  has had a chance to explain why that's being asked.
//

import SwiftUI
import UIKit
import AVFAudio
import CoreLocation

struct OnboardingView: View {
    let onComplete: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, mic, location, consent, autoID, done
    }

    @State private var step: Step = .welcome
    @State private var showPrivacyDetail = false
    // True while a permission request is in flight (soft-ask screen showing,
    // real OS dialog up) — disables the button so a double-tap can't fire a
    // second request or race the step transition.
    @State private var isAwaitingPermission = false
    // Owned here only long enough to drive the one-shot region-fix permission
    // request; ContentView creates its own instance afterwards. CLLocationManager
    // authorization is process-global, so requesting here doesn't cause a second
    // prompt later — by the time ContentView appears the status is already decided.
    @State private var location = LocationProvider()
    // Shared with ContentView — see ConsentStore.shared. Previously a separate
    // instance, which meant the consent granted here and the consent ContentView
    // read were two different objects agreeing only by luck of never coexisting.
    private let consent = ConsentStore.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            content
            Spacer()
            controls
        }
        .padding(24)
        .background(Color(.systemBackground))
        .sheet(isPresented: $showPrivacyDetail) { SafariView(url: PrivacyLinks.policyURL) }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingStepView(
                showAppLogo: true,
                title: "Welcome to OpenBat",
                message: """
                        OpenBat brings together bat detection and a field guide to help you get the most out of bat watching! If you don't have an ultrasonic USB microphone, visit the help page in the app settings.
                        
                        Unlike other free bat detector apps, OpenBat uses on-device machine learning to identify species as they pass.
                        
                        You can choose to join our community science project and start contributing recordings of the bats you detect.
                        """)
            Button("Read the full privacy notice") { showPrivacyDetail = true }
                .font(.footnote)
                .padding(.top, 8)
        case .mic:
            OnboardingStepView(
                systemImage: "mic.fill",
                title: "Microphone access",
                message: """
                        OpenBat needs access to you your device microphones to record bat calls above human hearing range. 
                        
                        If you later choose to contribute a recording to the community project, an irreversible filter removes the low frequencies human speech occupies before anything reaches us. Recordings you don't contribute are never filtered and never sent to us — they stay yours, on this device and in your own iCloud if you leave that on in settings. Full details in the privacy notice.
                        """)
            Button("Read the full privacy notice") { showPrivacyDetail = true }
                .font(.footnote)
                .padding(.top, 8)
        case .location:
            OnboardingStepView(
                systemImage: "location.fill",
                title: "Location access",
                message: "OpenBat uses your location to tag where each call was recorded and suggest an AutoID Model. The system permission dialog has its own \"Precise Location\" switch — leave it on for exact coordinates, or off if you'd rather share only an approximate area.")
            Button("Read the full privacy notice") { showPrivacyDetail = true }
                .font(.footnote)
                .padding(.top, 8)
        case .consent:
            ConsentView(consent: consent) { step = .autoID }
        case .autoID:
            ScrollView {
                VStack(spacing: 20) {
                    OnboardingStepView(
                        systemImage: "sparkle.magnifyingglass",
                        title: "AutoID",
                        message: "This app uses open-source machine learning to guess which species a bat call belongs to. It always tries its best, but it can be wrong — and some species are easy to confuse. Those IDs are flagged \u{201C}complex\u{201D}, or \u{201C}cf. SPECIES\u{201D} when one alternative is the closest match.")
                    complexList
                }
                .padding(.vertical, 8)
            }
        case .done:
            OnboardingStepView(
                systemImage: "checkmark.circle.fill",
                title: "You're all set",
                message: "You can change microphone or location access any time in the Settings app, or review your community-science participation from within OpenBat in settings.")
        }
    }

    // ConsentView owns its own two buttons (Contribute / Not Now) rather than a
    // single "continue" action, so it supplies none of these bottom controls.
    @ViewBuilder
    private var controls: some View {
        if step != .consent {
            Button(primaryLabel) { advance() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAwaitingPermission)
        }
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:  return "Continue"
        case .mic:      return "Allow Microphone Access"
        case .location: return "Allow Location Access"
        case .consent:  return ""
        case .autoID:   return "Got it!"
        case .done:     return "Get Started"
        }
    }

    /// All species complexes across every bundled model, deduped by *name* — the same
    /// grouping (e.g. "Myotis species") recurs under a different id per region/model,
    /// but it's one concept to explain to the user, not one row per model.
    private var allComplexes: [SpeciesComplex] {
        var seen = Set<String>()
        return ModelRegistry.all.flatMap(\.complexes).filter { seen.insert($0.name).inserted }
    }

    private var complexList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(allComplexes) { complex in
                VStack(alignment: .leading, spacing: 4) {
                    Label(complex.name, systemImage: "questionmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(Self.firstSentence(of: complex.note))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(.horizontal, 8)
    }

    /// Trims a complex's note down to its leading sentence — enough to convey why the
    /// species get confused without the full multi-sentence explanation shown elsewhere.
    private static func firstSentence(of note: String) -> String {
        guard let period = note.firstIndex(of: ".") else { return note }
        return String(note[...period])
    }

    private func advance() {
        switch step {
        case .welcome:
            step = .mic
        case .mic:
            isAwaitingPermission = true
            Task {
                _ = await AVAudioApplication.requestRecordPermission()
                isAwaitingPermission = false
                step = .location
            }
        case .location:
            // Waits for the real OS dialog to actually be resolved (granted, denied,
            // or restricted) before advancing — requestRegionFix() alone doesn't
            // await that decision, it only fires the request. Denial here just means
            // the note in §Denial handling below applies later; nothing to branch on
            // synchronously.
            isAwaitingPermission = true
            Task {
                _ = await location.requestAuthorizationDecision()
                location.requestRegionFix()
                isAwaitingPermission = false
                step = .consent
            }
        case .consent:
            break // ConsentView's own buttons drive this step.
        case .autoID:
            step = .done
        case .done:
            onComplete()
        }
    }
}

/// Shared centered icon/title/message header used by every onboarding step
/// (including `ConsentView`), so the flow reads as one consistent design.
struct OnboardingStepView: View {
    var systemImage: String? = nil
    var showAppLogo: Bool = false
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            icon
            Text(title)
                .font(.title2.bold())
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
    }

    @ViewBuilder private var icon: some View {
        if showAppLogo {
            appLogo
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(Color.batAccent)
        }
    }

    /// The real app icon, squircle-masked the way iOS presents it — falls back to the
    /// bat glyph if it can't be resolved. Mirrors `AppInfoView.appIcon`.
    @ViewBuilder private var appLogo: some View {
        Group {
            if let icon = Self.appIconImage {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image("batIcon")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(Color.batAccent)
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The primary app icon from the bundle, resolved from the Info.plist icon-files
    /// list since the asset-catalog icon isn't reliably reachable by a fixed name.
    private static let appIconImage: UIImage? = {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let name = files.last
        else { return nil }
        return UIImage(named: name)
    }()
}
