//
//  OnboardingView.swift
//  OpenBat
//
//  First-run flow, all three screens of it: welcome → permissions soft-ask
//  (+ the real mic and location dialogs, in that order) → AutoID caveats, and
//  straight into the app.
//
//  **It was eight screens until 2026-08-17** — echolocation, listening modes,
//  microphone calibration and the view-mode switch sat in the middle, and a
//  "you're all set" screen closed it. Niall cut it to these three. The removed
//  pages were not bad, they were early: they explain the hobby and the app's
//  options to someone who has not yet been allowed to open either. They are
//  kept, whole, in `AboutAppTour` — the second tour on the Info & Tour screen —
//  where the same words land on someone who went looking for them.
//
//  What is left is only what has to happen before the app can be used at all:
//
//  1. No OS dialog ever fires cold. The permissions step explains both asks on
//     one screen *before* either dialog appears. Folding mic and location onto
//     one page rather than one each is deliberate: they are asked for the same
//     reason (recording a bat pass and knowing where it happened), and two
//     near-identical soft-ask screens back to back read as nagging.
//  2. The caveat about identifications is said before the app has a chance to
//     make one. That is the one claim the app makes that a user could be misled
//     by, so it does not get to be optional reading.
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

    /// The whole flow. See this file's header for the five screens that used to
    /// sit between these and where they went.
    private enum Step: Int, CaseIterable {
        case welcome, permissions, autoID
    }

    /// iPad only (an iPhone always reports `.compact` here — landscape is
    /// disabled on iPhone, and portrait is compact on every iPhone size). See
    /// `body`: full-width edge-to-edge suits a phone screen, where the column
    /// is already close to the screen's own width, but on an iPad stretching
    /// the same layout across a much wider screen leaves the two side
    /// permission/caveat cards absurdly long single lines. A centred, capped
    /// card reads as a deliberate screen at any width instead.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isCenteredCard: Bool { horizontalSizeClass == .regular }

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
    // Drives the direction of the step transition, so going Back slides the
    // opposite way to going forward rather than both looking like "forward".
    @State private var isMovingBackward = false
    // Owned here only long enough to drive the one-shot region-fix permission
    // request; ContentView creates its own instance afterwards. CLLocationManager
    // authorization is process-global, so requesting here doesn't cause a second
    // prompt later — by the time ContentView appears the status is already decided.
    @State private var location = LocationProvider()

    // The interface mode is no longer asked here — the view-mode step moved to
    // `AboutAppTour`. Nothing has to be written on the way out for that to be
    // safe: every reader of `SimplifiedView.key` declares the same `true`
    // default, so an untouched install is in simplified view, which is the
    // answer that step defaulted to anyway.
    //
    // Microphone calibration moved with it. It was an offer to calibrate
    // hardware most first-run users have not plugged in yet, and it lives under
    // Microphone in Settings, which is where someone who plugs one in later has
    // to go anyway. `AudioEngineController` and `MicCalibrationSettings` are no
    // longer constructed here as a result — onboarding now touches no audio at
    // all before ContentView does.

    // Deliberately NOT wrapped in a `NavigationStack`. The only thing it ever
    // hosted was a toolbar Back button, which existed on every step except the
    // first — so the navigation bar itself appeared on step 2 and shoved the
    // progress bar down the screen mid-transition. Back now lives in the
    // bottom bar next to the primary action, which keeps the top of the screen
    // fixed for the whole flow.
    var body: some View {
        ZStack {
            // The backdrop behind the card on iPad. Without a colour distinct
            // from the card's own background here, "centred" would just mean
            // "surrounded by empty margins of the same colour" — there'd be
            // nothing for the eye to register as a card's edge.
            if isCenteredCard {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
            flowContent
                .frame(maxWidth: isCenteredCard ? 480 : .infinity)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: isCenteredCard ? 28 : 0, style: .continuous))
                .shadow(color: .black.opacity(isCenteredCard ? 0.15 : 0), radius: 24, y: 8)
                // Capped, not just centred: on an iPad screen this flow's own
                // content (floored at 400pt by the ScrollView below) rarely
                // needs anywhere near full height, and without a cap the card
                // would still stretch top-to-bottom looking for a reason to.
                .frame(maxHeight: isCenteredCard ? 780 : .infinity)
                .padding(.vertical, isCenteredCard ? 40 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isCenteredCard ? Color(.systemGroupedBackground) : Color(.systemBackground))
        .sheet(isPresented: $showPrivacyDetail) { SafariView(url: PrivacyLinks.policyURL) }
        // A light tap on each step change — the flow is a sequence of discrete
        // moves, and the feedback makes it feel like one.
        .sensoryFeedback(.selection, trigger: step)
        .interactiveDismissDisabled()
    }

    /// The flow itself — progress bar, scrolling step content, pinned footer
    /// and controls — unchanged by `isCenteredCard`. Only how `body` frames
    /// and backgrounds this differs between iPhone and iPad.
    private var flowContent: some View {
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
                    // The same two drawn glyphs the tab bar wears for Detector
                    // and Species, so the three things promised here are already
                    // recognisable as the tabs they land on.
                    OnboardingCard(
                        glyph: .asset("batCall"),
                        title: "Detect",
                        detail: "Every call is drawn on a live spectrogram the moment it arrives, and recorded at full ultrasonic quality if you want to keep it.")
                    OnboardingCard(
                        systemImage: "sparkle.magnifyingglass",
                        title: "Identify",
                        detail: "Open-source machine learning names the species on-device as bats pass — nothing is sent anywhere to do it.")
                    OnboardingCard(
                        glyph: .asset("batBook"),
                        title: "Learn",
                        detail: "A built-in, community-maintained field guide covers the species in your region, with range maps, call measurements and photos.")
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
                        // NO mention of a track: GPS courses were removed on
                        // 2026-08-16 along with the background location mode,
                        // and this line still promised one. Location is now four
                        // one-shot uses, all of them listed here.
                        detail: "Shows tonight's sunset and sunrise times so you know when to head out, tags where each call was heard, picks the right species model for your region and weights the identification by what lives near you.",
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

        case .autoID:
            VStack(spacing: 20) {
                OnboardingStepView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "About the IDs",
                    message: "OpenBat offers ID on the bats it detects with on-device machine learning. While it tries its best to offer an accurate ID, some species simply cannot be told apart by sound.")

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
                    // The last thing said before the app opens, and the only
                    // thing left of the five screens that used to follow this
                    // one: none of what they asked about is being asked any
                    // more, so the promise that it is all still reachable is
                    // the part that has to survive. It names the two places by
                    // name — a vague "in Settings somewhere" is not a findable
                    // promise.
                    OnboardingCard(
                        systemImage: "gearshape.fill",
                        title: "You can change all these settings in the app",
                        detail: "Listening mode, haptics, microphone calibration and how much of the detector you see all live in Settings, and nothing here is permanent. Info & Tour, in the same top-right menu, has a guided tour of the screen and a longer walk through how bat detecting works.")
                }
            }
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
            cautionFooter {
                PlugInAnimation(tint: .white)
                    .frame(width: 76, height: 76)
            } text: {
                "Our app works with USB microphones designed to be able to hear the ultra-high pitch calls which bats produce as they navigate the world. Visit the Help page in the top-right options menu to learn more."
            }

        case .autoID:
            // A warning triangle rather than the plug animation this reused at
            // first: the animation says "connect your microphone", which is a
            // different message from the one the paragraph beside it is making,
            // and a footer whose picture and words disagree is worse than one
            // with no picture at all.
            // No fixed frame, and a tighter gap than the welcome step's. The
            // 76×76 slot is sized for `PlugInAnimation`, which fills it; a
            // symbol does not, so the box added ~19pt of dead space on each side
            // on top of the 25pt gap and left the triangle marooned.
            cautionFooter(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
            } text: {
                "Identifying bats with acoustics alone is very difficult. The calls can change depending on the environment, sound pollution, other bats, insects, and more. Identifications are suggestions, and will usually get you somewhere near, but further analysis is needed to confirm. Consider submitting to community science platforms."
            }

        // The echolocation step's diagram footer went to `AboutAppTour` with the
        // step itself.
        default:
            EmptyView()
        }
    }

    /// The orange note a step can hang at the bottom of the screen: a glyph on
    /// the left, a paragraph beside it.
    ///
    /// Shared rather than written out per step, which is how it started — two
    /// copies of the same twelve lines, differing only in the picture and the
    /// words. Everything about the shape (the tint, the corner radius, and
    /// particularly the asymmetric padding below, which keeps the note from
    /// reading as attached to the primary action) has to stay identical between
    /// them for the flow to look like one thing.
    ///
    /// `spacing` is the one thing callers vary: a glyph that fills its own box
    /// needs less room beside it than one carrying optical padding.
    private func cautionFooter(
        spacing: CGFloat = 25,
        @ViewBuilder leading: () -> some View,
        text: () -> String
    ) -> some View {
        HStack(spacing: spacing) {
            leading()
            Text(text())
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 12)
        // The gap down to the buttons. Larger than the top gap on purpose: this
        // footer is a note about the app, and it shouldn't read as being
        // attached to the primary action.
        .padding(.bottom, 28)
    }

    // MARK: - Controls

    /// The pinned bottom bar: Back as a compact arrow on the left, the step's
    /// primary action filling the rest.
    ///
    /// The trailing slot is always empty now. It used to hold "Skip" on the
    /// calibration step — the one step with a second, unequal choice — which is
    /// what the slot was sized for; that step moved to `AboutAppTour`. The slot
    /// stays because the geometry below depends on it: it is what keeps the
    /// primary button centred.
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

                // A fixed-width Spacer, not an empty view with a `.frame` on it
                // — an empty branch collapses to nothing in an HStack no matter
                // what width is asked for, handing the slot back to the primary
                // button and pushing it right.
                Spacer()
                    .frame(width: Self.sideSlotWidth)
            }
        }
        .animation(.snappy(duration: 0.28), value: step)
    }

    /// Width reserved on each side of the primary button. Sized for the widest
    /// thing either slot has ever held — "Skip" as a large bordered button — so
    /// the middle never has to give ground to it. Kept at that width now the
    /// Skip is gone, so the button sits where it always has.
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
        case .welcome:     return "Continue"
        // "Continue" either way, deliberately. It used to read "Allow Access"
        // until both dialogs had been answered, which described the button
        // honestly but made the flow look like it had a gate in it — and the
        // step advances on the second tap regardless. Whether a tap opens a
        // system dialog or moves on is `advance()`'s business, not the label's.
        case .permissions: return "Continue"
        // The last step, so this is the button that opens the app.
        case .autoID:      return "Let's go!"
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

    /// Both dialogs answered, however they were answered. Denial is not a
    /// blocker — the app degrades rather than refuses — so this only asks
    /// whether iOS still has a prompt left to show.
    private var allPermissionsDecided: Bool {
        micStatus != .undetermined && location.authorization != .notDetermined
    }

    // Onboarding used to end this step with a list of every species complex
    // across every bundled model, one orange row each. It was the longest thing
    // in the flow and it named groups the user has no reason to care about
    // before hearing their first bat — the two cards above teach the labels,
    // which is the part that has to land here. The full note is still one tap
    // away on any ID that actually falls in a complex.

    // MARK: - Navigation

    private func advance() {
        switch step {
        case .welcome:
            go(to: .permissions)
        case .permissions:
            // The first tap fires the two OS dialogs and leaves the user here to
            // watch the rows tick; the second moves on. See `requestPermissions`.
            if allPermissionsDecided {
                go(to: .autoID)
            } else {
                requestPermissions()
            }
        case .autoID:
            // Consumed once by ContentView's .onAppear, which clears it right back
            // to false — see OnboardingState.justFinishedOnboarding's doc comment.
            // It does not open the tour: dropping someone straight out of
            // onboarding into another guided thing, on a detector that has
            // nothing on it yet, is more onboarding at exactly the point they
            // were promised it had ended. Both tours are under Info & Tour,
            // which is where the card above points.
            OnboardingState.shared.justFinishedOnboarding = true
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
///
/// Internal rather than private because `AboutAppTour` — which is the retired
/// middle of this flow — draws the same bar. Two bars that only look alike is
/// what a shared component is for.
struct OnboardingProgressBar: View {
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
///
/// Internal rather than private: `AboutAppTour` is built from these too, and it
/// holds the pages this flow used to end with — they have to keep looking like
/// the same app.
struct OnboardingCard: View {
    /// Either an SF Symbol or a drawn glyph from the asset catalog. The two size
    /// by different means and neither works on the other — a symbol takes its
    /// size from `font`, artwork carries its own pixel dimensions — which is the
    /// same split `AppSection.Icon` makes for the tab bar.
    enum Glyph {
        case symbol(String)
        case asset(String)
    }

    let glyph: Glyph
    let title: String
    let detail: String

    init(systemImage: String, title: String, detail: String) {
        self.init(glyph: .symbol(systemImage), title: title, detail: detail)
    }

    init(glyph: Glyph, title: String, detail: String) {
        self.glyph = glyph
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
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

    /// Artwork is height-matched to the symbols beside it rather than fitted to
    /// the 28pt box: `batCall` is landscape, so binding it on width would draw it
    /// noticeably shorter than every symbol in the column — the same trap
    /// `AppSection.iconSized(_:)` documents for the tab bar.
    @ViewBuilder private var icon: some View {
        switch glyph {
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 20))
        case .asset(let name):
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 20)
        }
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
