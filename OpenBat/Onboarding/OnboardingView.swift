//
//  OnboardingView.swift
//  OpenBat
//
//  First-run flow: welcome → how bat detecting works → permissions soft-ask
//  (+ the real mic and location dialogs, in that order) → optional mic
//  calibration → AutoID caveats → done.
//
//  Two things this flow is built around:
//
//  1. No OS dialog ever fires cold. The permissions step explains both asks on
//     one screen *before* either dialog appears, and the button that triggers
//     them says so. Folding mic and location onto one page rather than one
//     each is deliberate: they are asked for the same reason (recording a bat
//     pass and knowing where it happened), and two near-identical soft-ask
//     screens back to back read as nagging.
//  2. It has to sell the hobby, not just the app. Most people arriving here
//     have never used a bat detector, so `.echolocation` explains what one
//     *is* before any permission is requested — the ask lands very differently
//     once you know what the microphone is for.
//
//  `OpenBatApp` mounts this instead of `ContentView` until
//  `hasCompletedOnboarding` is set, which also means `ContentView`'s own
//  `.onAppear` (which calls `location.requestRegionFix()` unconditionally)
//  never runs before onboarding has had a chance to explain why that's being
//  asked.
//

import SwiftUI
import UIKit
import AVFAudio
import CoreLocation

struct OnboardingView: View {
    let onComplete: () -> Void

    private enum Step: Int, CaseIterable {
        case welcome, echolocation, listening, permissions, calibrate, autoID, viewMode, done
    }

    @State private var step: Step = .welcome
    @State private var showPrivacyDetail = false
    // True while a permission request is in flight (soft-ask screen showing,
    // real OS dialog up) — disables the button so a double-tap can't fire a
    // second request or race the step transition.
    @State private var isAwaitingPermission = false
    // Mic authorization isn't observable the way `location.authorization` is,
    // so the permissions step's status row reads this instead, refreshed after
    // the request resolves.
    @State private var micStatus = AVAudioApplication.shared.recordPermission
    /// The interface mode, asked on its own step. Written straight through to
    /// the same key the detector and Settings read (`SimplifiedView.key`), so
    /// there is nothing to hand over at the end — whatever the switch is left
    /// at IS the setting.
    @AppStorage(SimplifiedView.key) private var simplifiedMode = true
    // Drives the direction of the step transition, so going Back slides the
    // opposite way to going forward rather than both looking like "forward".
    @State private var isMovingBackward = false
    // Owned here only long enough to drive the one-shot region-fix permission
    // request; ContentView creates its own instance afterwards. CLLocationManager
    // authorization is process-global, so requesting here doesn't cause a second
    // prompt later — by the time ContentView appears the status is already decided.
    @State private var location = LocationProvider()
    // Same throwaway-instance pattern as `location` above: this is only alive
    // long enough to drive the optional calibration capture; ContentView
    // creates its own instance afterwards. Saving through `micCalSettings`
    // writes the same UserDefaults keys ContentView's own instance later
    // reads, so no hand-off is needed beyond that.
    @State private var calibrationAudio = AudioEngineController()
    @State private var micCalSettings = MicCalibrationSettings()
    @State private var showMicCalibration = false

    // Deliberately NOT wrapped in a `NavigationStack`. The only thing it ever
    // hosted was a toolbar Back button, which existed on every step except the
    // first — so the navigation bar itself appeared on step 2 and shoved the
    // progress bar down the screen mid-transition. Back now lives in the
    // bottom bar next to the primary action, which keeps the top of the screen
    // fixed for the whole flow.
    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressBar(completed: step.rawValue, total: Step.allCases.count)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            // Top-aligned, not centred. Centring made every step's header sit
            // at a different height, because its position depended on how tall
            // that step's copy happened to be — the icon visibly jumped from
            // step to step. Anchoring to the top puts it in the same place
            // every time and lets the content grow downward underneath it.
            ScrollView {
                content
                    // Belt-and-braces against long copy truncating rather than
                    // scrolling: a ScrollView proposes the viewport height to
                    // its content, so anything flexible can be talked into
                    // compressing. Taking the ideal height instead pushes the
                    // column past the viewport, which is what makes it scroll.
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    // Keyed on the step so SwiftUI treats each step as
                    // a new view and actually runs the transition,
                    // rather than diffing one step's content into the
                    // next in place.
                    .id(step)
                    .transition(stepTransition)
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    // Clearance above the pinned footer and button bar. Without
                    // it the scrolled column ends flush against them, so the
                    // last row of a long step — the final species complex on
                    // "About the IDs" — reads as clipped underneath the buttons
                    // rather than as the end of a list.
                    .padding(.bottom, 24)
            }

            // Also outside the ScrollView, for the same reason — a step's
            // footer belongs at the bottom of the *screen*, which nothing
            // inside the scrolling column can achieve: that column is sized to
            // its content (floored at 400pt), so it has no spare height to
            // push anything down into.
            // Padding lives inside `stepFooter`'s own cases, not here: a
            // modified `EmptyView` still takes its padding as layout space, so
            // applying it at the call site would leave a dead band above the
            // buttons on every step that has no footer.
            stepFooter
                .id(step)
                .transition(.opacity)

            // Outside the ScrollView, so the primary action is pinned to the
            // bottom of the screen on every step regardless of how tall that
            // step's content is.
            controls
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .background(Color(.systemBackground))
        .sheet(isPresented: $showPrivacyDetail) { SafariView(url: PrivacyLinks.policyURL) }
        .sheet(isPresented: $showMicCalibration) {
            MicCalibrationView(audio: calibrationAudio, settings: micCalSettings) {
                showMicCalibration = false
                go(to: .autoID)
            }
        }
        .onAppear { calibrationAudio.activate() }
        // A light tap on each step change — the flow is a sequence of discrete
        // moves, and the feedback makes it feel like one.
        .sensoryFeedback(.selection, trigger: step)
        .interactiveDismissDisabled()
    }

    /// Forward pushes in from the trailing edge, Back from the leading edge.
    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: isMovingBackward ? .leading : .trailing).combined(with: .opacity),
            removal: .move(edge: isMovingBackward ? .trailing : .leading).combined(with: .opacity))
    }

    // MARK: - Step content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 20) {
                OnboardingStepView(
                    hero: { SonarPulseHero { OnboardingBranding.logo } },
                    title: "Welcome to OpenBat",
                    message: "A community driven initiative based in Squamish, BC, with a mission to make bat detecting and appreciation accessible and affordable to as many people as possible.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "waveform.badge.magnifyingglass",
                        title: "Detect",
                        detail: "Every call is drawn on a live spectrogram the moment it arrives, and recorded at full ultrasonic quality if you want to keep it.")
                    OnboardingCard(
                        systemImage: "sparkle.magnifyingglass",
                        title: "Identify",
                        detail: "Open-source machine learning names the species on-device as bats pass — nothing is sent anywhere to do it.")
                    OnboardingCard(
                        systemImage: "book.closed.fill",
                        title: "Learn",
                        detail: "A built-in, community-maintained field guide covers the species in your region, with range maps, call measurements and photos.")
                }
            }

        case .echolocation:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "waveform.badge.magnifyingglass",
                    title: "Echolocation",
                    message: "To navigate and hunt, a bat shouts dozens of times per second as it flies, then listens for the echo to build a picture of the world around it.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "arrow.up.right.circle.fill",
                        title: "Too high to hear",
                        detail: "Most calls sit between 20 and 120 kHz. Human hearing gives out around 20 kHz, so almost all of it passes by in silence — which is where a bat detector comes in.")
                    OnboardingCard(
                        systemImage: "metronome.fill",
                        title: "The rhythm tells you a lot",
                        detail: "A searching bat calls steadily. As it closes on an insect the calls speed up into a feeding buzz — the moment most bat workers listen for.")
                }
            }

        case .listening:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "waveform.and.person.filled",
                    title: "Hearing them",
                    message: "OpenBat brings each call down into your hearing range as it arrives — two ways round, and you can switch between them while you listen.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "headphones",
                        title: "Hear it",
                        detail: "Calls are shifted down into the audible range live, so a pass sounds like the characteristic clicks and warble bat workers listen for.")
                    OnboardingCard(
                        systemImage: "tortoise.fill",
                        title: "Slow it down",
                        detail: "Slow replay grabs a short snippet of a call and plays it back at a fraction of its speed, which brings out detail the shifted-down version glosses over. The detector is deaf while a snippet replays — a trade you choose in Settings.")
                    OnboardingCard(
                        systemImage: "hand.tap.fill",
                        title: "Feel it",
                        detail: "To make bat detecting accessible to all, each call can also be rendered as a vibration — its strength tracks how close the bat is, and its texture changes with the kind of call, so a feeding buzz feels different from a passing bat. Turn it on under Audio in Settings.")
                }
            }

        case .permissions:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "checkmark.shield.fill",
                    title: "Two things to allow",
                    message: "OpenBat needs both to record a pass and tell you what it was.")

                VStack(spacing: 10) {
                    PermissionRow(
                        systemImage: "mic.fill",
                        title: "Microphone",
                        detail: "Records calls above human hearing.",
                        state: micRowState)
                    PermissionRow(
                        systemImage: "location.fill",
                        title: "Location",
                        detail: "Tags where each call was heard, records a track for each session, picks the right species model for your region and weights the identification by what lives near you.",
                        state: locationRowState)
                }

                VStack(spacing: 8) {
                    // "Nothing is ever uploaded" was true when written and has an
                    // expiry date on it: the app already contains a full upload
                    // pipeline and a Settings toggle for contributing to
                    // community science, switched off only because no project is
                    // live yet. The day one is, everyone onboarded until then
                    // will have been told the opposite. This wording stays true
                    // either way, and promises the thing that actually matters —
                    // that it never happens without being asked.
                    Text("Recordings stay yours — on this device, and in your own iCloud if you leave that on in Settings. Nothing leaves your device unless you choose to contribute it, and you'll be asked first, every time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Read the full privacy notice") { showPrivacyDetail = true }
                        .font(.footnote)
                }
                .padding(.horizontal, 8)
            }

        case .calibrate:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "tuningfork",
                    title: "Calibrate your microphone",
                    message: "Optional, takes about 15 seconds, and you can do it any time later from Settings.")

                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "waveform.path.ecg",
                        title: "Why it helps",
                        detail: "Affordable ultrasonic microphones have an uneven frequency response, which shows up as fixed noise bands across the spectrogram and skews frequency measurements.")
                    OnboardingCard(
                        systemImage: "ear.badge.waveform",
                        title: "What happens",
                        detail: "Find somewhere quiet and OpenBat listens to your microphone's own noise floor for 15 seconds, then corrects for it. It doesn't change or upload any recording.")
                }
            }

        case .autoID:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "About the IDs",
                    message: "OpenBat names the species with on-device machine learning. It tries its best, and it can be wrong — some species simply cannot be told apart by sound.")

                // The two labels these cards teach are real, and the wording
                // here must track them exactly: see `ComplexIndicator.text` in
                // SessionsView, and `SpeciesComplex` / `PassAggregation` for
                // when each is shown. They say different things — one is a
                // standing caution about the species, the other is about this
                // one pass — and the cards exist because that distinction is
                // invisible from the pills alone.
                VStack(spacing: 10) {
                    OnboardingCard(
                        systemImage: "questionmark.circle.fill",
                        title: "\u{201C}sounds alike\u{201D}",
                        detail: "This species belongs to a group that overlaps too much to tell apart by sound alone. It's a standing caution about the species, not about this particular call — the ID is being honest about the group rather than guessing a name within it.")
                    OnboardingCard(
                        systemImage: "questionmark.diamond.fill",
                        title: "\u{201C}or SPECIES\u{201D}",
                        detail: "On this call, a second species scored almost as highly as the winner. Read it as “probably the first one, but don't bank on it” — tap the pass to see both scores and judge for yourself.")
                }

                complexList
            }

        case .viewMode:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "slider.horizontal.below.rectangle",
                    title: "How much do you want to see?",
                    message: "The detector can show a lot at once. Start simple — you can change this whenever you like.")

                // A real toggle rather than two choice cards: this is one
                // setting with two states, it lives in Settings as a toggle,
                // and showing it here in the same form it will take there is
                // what makes "you can change this later" a findable promise
                // rather than a vague one.
                VStack(spacing: 14) {
                    Toggle("Simplified view", isOn: $simplifiedMode)
                        .font(.headline)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))

                    OnboardingCard(
                        systemImage: simplifiedMode ? "eye" : "eye.trianglebadge.exclamationmark",
                        title: simplifiedMode ? "You'll see" : "You'll see everything",
                        detail: simplifiedMode
                            ? "A running list of every species heard, the input level, and the spectrogram. Enough to know which bat flew over."
                            : "Every readout and control: peak frequency, bandwidth, duration and pulse rate, the pulse close-up, and the timeline, palette and frequency-band controls.")
                    OnboardingCard(
                        systemImage: "gearshape.fill",
                        title: "Change it any time",
                        detail: "It's the first switch in Settings, under General. Nothing is lost by switching either way — anything you've adjusted is kept and comes back.")
                }
                .padding(.top, 4)
            }

        case .done:
            OnboardingStepView(
                hero: {
                    SonarPulseHero {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(Color.batAccent)
                    }
                },
                title: "You're all set",
                message: "Let's take a quick tour of the detector screen so you know what you're looking at.")

            VStack(spacing: 10) {
                OnboardingCard(
                    systemImage: "gearshape.fill",
                    title: "Everything is changeable",
                    detail: "Microphone and location access, listening mode, haptics and calibration all live in Settings, and none of these choices are permanent.")
                OnboardingCard(
                    systemImage: "questionmark.circle.fill",
                    title: "Stuck?",
                    detail: "Help — in the top-right options menu, alongside Settings — covers which microphones work, how to read the spectrogram, and what to do when nothing seems to be coming through.")
            }
            .padding(.top, 20)
        }
    }

    // MARK: - Pinned footer

    /// Content that belongs at the bottom of the screen rather than in the
    /// centred column — rendered below the ScrollView, above the buttons.
    @ViewBuilder
    private var stepFooter: some View {
        switch step {
        case .welcome:
            // The one piece of hardware the app can't work without, said
            // plainly and early. Leaving it to the Settings help page means a
            // user can finish onboarding, reach a silent detector screen, and
            // conclude the app is broken.
            HStack(spacing: 25) {
                PlugInAnimation(tint: .white)
                    .frame(width: 76, height: 76)
                Text("Our app works with USB microphones designed to be able to hear the ultra-high pitch calls which bats produce as they navigate the world. Visit the Help page in the top-right options menu to learn more.")
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 24)
            .padding(.top, 12)
            // The gap down to the buttons. Larger than the top gap on purpose:
            // this footer is a note about the app, and it shouldn't read as
            // being attached to the primary action.
            .padding(.bottom, 28)

        case .echolocation:
            EcholocationDiagram()
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 28)

        default:
            EmptyView()
        }
    }

    // MARK: - Controls

    /// The pinned bottom bar: Back as a compact arrow on the left, the step's
    /// primary action filling the rest. `.calibrate` is the one step with a
    /// second choice, and it hangs below rather than competing for the row —
    /// skipping is a legitimate answer there, but not an equal one.
    private var controls: some View {
        VStack(spacing: 10) {
            // Fixed-width slots on both sides, on every step. That is what
            // keeps the primary button identically sized and centred the whole
            // way through: its width is always (row − 2 × slot − 2 × spacing),
            // regardless of whether a slot currently holds anything. Letting
            // the side controls size themselves instead means the primary
            // button resizes and slides whenever one appears, changes, or is
            // wider than the other side — which is exactly what a "Skip" wider
            // than a chevron did.
            HStack(spacing: 12) {
                // Present on every step, just invisible on the first, where
                // there is nowhere to go back to.
                backArrowButton
                    .disabled(step == .welcome || isAwaitingPermission)
                    .opacity(step == .welcome ? 0 : 1)
                    .accessibilityLabel("Back")
                    .accessibilityHidden(step == .welcome)
                    .frame(width: Self.sideSlotWidth, alignment: .leading)

                // The width has to be applied to the LABEL, not the button. A
                // bordered button sizes its background to its label, so
                // `.frame(maxWidth: .infinity)` on the button itself only
                // stretches an invisible hit area and leaves the capsule
                // hugging the word — which is what left this sitting off
                // centre. Same reason `SuggestedModelSheet` expands its label.
                Button { advance() } label: {
                    Text(primaryLabel)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isAwaitingPermission)

                // Calibration is genuinely optional, so Skip sits beside it as
                // a real alternative — bordered rather than prominent, so it
                // doesn't compete with the action we'd rather you took.
                if step == .calibrate {
                    Button("Skip") { go(to: .autoID) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: Self.sideSlotWidth, alignment: .trailing)
                } else {
                    // A fixed-width Spacer, not an empty view with a `.frame`
                    // on it — an empty branch collapses to nothing in an
                    // HStack no matter what width is asked for, handing the
                    // slot back to the primary button and pushing it right.
                    Spacer()
                        .frame(width: Self.sideSlotWidth)
                }
            }
        }
        .animation(.snappy(duration: 0.28), value: step)
    }

    /// Width reserved on each side of the primary button. Sized for the widest
    /// thing either slot ever holds — "Skip" as a large bordered button — so
    /// the middle never has to give ground to it.
    private static let sideSlotWidth: CGFloat = 80

    private var backArrowButton: some View {
        Button { goBack() } label: {
            Image(systemName: "chevron.left")
                .font(.headline)
                .frame(height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome:      return "Continue"
        case .echolocation: return "Continue"
        case .listening:    return "Continue"
        // Once both dialogs have been answered the button stops offering to ask
        // again — re-tapping would be a no-op, since iOS only shows each of
        // these once.
        case .permissions:  return allPermissionsDecided ? "Continue" : "Allow Access"
        case .calibrate:    return "Calibrate"
        case .autoID:       return "Got it!"
        case .viewMode:     return "Continue"
        case .done:         return "Take the Tour"
        }
    }

    // MARK: - Permission state

    private var micRowState: PermissionRow.State {
        switch micStatus {
        case .granted:      return .granted
        case .denied:       return .denied
        default:            return .pending
        }
    }

    private var locationRowState: PermissionRow.State {
        switch location.authorization {
        case .authorizedAlways, .authorizedWhenInUse: return .granted
        case .denied, .restricted:                    return .denied
        default:                                      return .pending
        }
    }

    /// Whether there's an ultrasonic mic attached worth calibrating. Read from
    /// the throwaway controller this view activates in `onAppear`, which
    /// populates its diagnostics from the current audio route without needing
    /// capture to be running.
    private var canCalibrate: Bool { calibrationAudio.diagnostics.canCalibrate }

    /// Both dialogs answered, however they were answered. Denial is not a
    /// blocker — the app degrades rather than refuses — so this only asks
    /// whether iOS still has a prompt left to show.
    private var allPermissionsDecided: Bool {
        micStatus != .undetermined && location.authorization != .notDetermined
    }

    // MARK: - Species complexes

    /// All species complexes across every bundled model, deduped by *name* — the same
    /// grouping (e.g. "Myotis species") recurs under a different id per region/model,
    /// but it's one concept to explain to the user, not one row per model.
    private var allComplexes: [SpeciesComplex] {
        var seen = Set<String>()
        return ModelRegistry.all.flatMap(\.complexes).filter { seen.insert($0.name).inserted }
    }

    /// Deliberately terse: a name and a few words each, no sentences. This is a
    /// heads-up that certain groups are hard, not the place to teach why — the
    /// full `note` is one tap away on any ID that actually lands in a complex.
    private var complexList: some View {
        VStack(spacing: 6) {
            ForEach(allComplexes) { complex in
                HStack(spacing: 10) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text(complex.name)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(complex.shortNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    // MARK: - Navigation

    private func advance() {
        switch step {
        case .welcome:
            go(to: .echolocation)
        case .echolocation:
            go(to: .listening)
        case .listening:
            go(to: .permissions)
        case .permissions:
            if allPermissionsDecided {
                // Skipped entirely with no ultrasonic mic attached: there is
                // nothing to calibrate, and asking someone to calibrate hardware
                // they haven't plugged in yet is a step that can only fail. It
                // stays available in Settings, which is where someone who plugs
                // a mic in later has to go find it — offering it automatically
                // on first connection is still to do.
                go(to: canCalibrate ? .calibrate : .autoID)
            } else {
                requestPermissions()
            }
        case .calibrate:
            // "Skip for now", in the bottom bar, is the other way out of this step.
            showMicCalibration = true
        case .autoID:
            go(to: .viewMode)
        case .viewMode:
            go(to: .done)
        case .done:
            // Consumed once by ContentView's .onAppear, which clears it right back
            // to false — see OnboardingState.shouldAutoStartTour's doc comment.
            OnboardingState.shared.shouldAutoStartTour = true
            onComplete()
        }
    }

    /// Runs both OS dialogs back to back, mic first, and leaves the user on
    /// this screen when they're done rather than advancing automatically — the
    /// rows have just filled in with ticks, and skipping past that instantly
    /// hides the only confirmation they get that it worked.
    private func requestPermissions() {
        isAwaitingPermission = true
        Task {
            if micStatus == .undetermined {
                _ = await AVAudioApplication.requestRecordPermission()
                micStatus = AVAudioApplication.shared.recordPermission
            }
            // Waits for the real OS dialog to actually be resolved (granted, denied,
            // or restricted) before continuing — requestRegionFix() alone doesn't
            // await that decision, it only fires the request. Denial here just means
            // the app runs without location tagging; nothing to branch on
            // synchronously.
            if location.authorization == .notDetermined {
                _ = await location.requestAuthorizationDecision()
            }
            location.requestRegionFix()
            isAwaitingPermission = false
        }
    }

    private func go(to next: Step) {
        isMovingBackward = next.rawValue < step.rawValue
        withAnimation(.snappy(duration: 0.28)) { step = next }
    }

    // Steps are display-order-sequential, so stepping back is just the
    // previous raw value — no history stack needed. Re-showing the soft-ask
    // screen this way is safe: it's `advance()`'s button tap that fires the
    // real OS permission requests, not arriving at the step.
    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        go(to: previous)
    }
}

// MARK: - Progress indicator

/// Same shape as the ADHD app's onboarding progress bar: a capsule track with
/// a tinted fill sized to (completed step + 1) / total, so the first step
/// still shows a sliver of progress rather than an empty bar.
private struct OnboardingProgressBar: View {
    let completed: Int
    let total: Int

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.batAccent)
                        .frame(width: proxy.size.width * CGFloat(completed + 1) / CGFloat(max(total, 1)))
                }
        }
        .frame(height: 6)
        .animation(.easeInOut, value: completed)
        .accessibilityHidden(true)
    }
}

// MARK: - Info card

/// The shared card every step is built from: an accent glyph, a subheading and
/// a short explainer. Steps read as a short paragraph under the header followed
/// by a stack of these, so the flow has one rhythm rather than a different
/// layout per screen. `PermissionRow` is the same shape plus a status glyph,
/// since those cards describe something you're being asked to grant.
private struct OnboardingCard: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.batAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Permission row

/// One "here's what we'll ask for and why" row on the combined permissions
/// step, with a live status glyph so answering the OS dialogs visibly fills
/// the list in.
private struct PermissionRow: View {
    enum State { case pending, granted, denied }

    let systemImage: String
    let title: String
    let detail: String
    let state: State

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.batAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(state == .denied ? "\(detail) You can turn this on later in the Settings app." : detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            statusGlyph
                .font(.system(size: 18))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder private var statusGlyph: some View {
        switch state {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .denied:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared step header

/// Shared centered icon/title/message header used by every onboarding step
/// (including `ConsentView`), so the flow reads as one consistent design.
/// `hero` overrides the plain SF Symbol for steps that want something moving
/// up there instead — see `OnboardingVisuals.swift`.
struct OnboardingStepView<Hero: View>: View {
    var systemImage: String? = nil
    var showAppLogo: Bool = false
    @ViewBuilder var hero: () -> Hero
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            icon
            Text(title)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                // Never compress this to fit — see the note on `content` in
                // `body`. Repeated here so the component is safe to drop into
                // any layout, not just that one.
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var icon: some View {
        if Hero.self != EmptyView.self {
            hero()
        } else if showAppLogo {
            OnboardingBranding.logo
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: 56))
                .foregroundStyle(Color.batAccent)
                // A one-shot bounce as each step arrives, so the header reads
                // as having landed rather than having always been there.
                .symbolEffect(.bounce, options: .nonRepeating)
        }
    }
}

extension OnboardingStepView where Hero == EmptyView {
    init(systemImage: String? = nil, showAppLogo: Bool = false, title: String, message: String) {
        self.init(systemImage: systemImage, showAppLogo: showAppLogo,
                  hero: { EmptyView() }, title: title, message: message)
    }
}

extension OnboardingStepView {
    init(@ViewBuilder hero: @escaping () -> Hero, title: String, message: String) {
        self.init(systemImage: nil, showAppLogo: false, hero: hero, title: title, message: message)
    }
}

/// Namespace for onboarding's shared branding, so the logo isn't a loose
/// global. It can't live on `OnboardingStepView` itself any more: that type is
/// generic over its hero view, which would make every reference to a static
/// member need a concrete generic argument at the call site.
enum OnboardingBranding {
    /// The real app icon, squircle-masked the way iOS presents it — falls back to the
    /// bat glyph if it can't be resolved. Mirrors `AppInfoView.appIcon`.
    @ViewBuilder static var logo: some View {
        Group {
            if let icon = appIconImage {
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
