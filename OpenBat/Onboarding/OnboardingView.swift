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
//  3. The user finds out they need a microphone *before* meeting a silent
//     detector. The welcome step's footer polls for one (`UltrasonicMicProbe`)
//     and says whether it can see it, which is a far stronger message than a
//     standing warning that a user with a microphone already plugged in reads
//     as not applying to them.
//
//  **Every step is meant to fit on screen without scrolling.** The ScrollView
//  underneath is for large Dynamic Type, not for ordinary reading — a step
//  whose last card is below the fold has a last card nobody reads. Two things
//  keep that true: the copy is kept to a header plus at most three short cards
//  (the "About the IDs" step lost its two label cards on 2026-09-08 for this
//  reason — see there), and `OnboardingMetrics` tightens the spacing on the
//  short screens where even that would not fit.
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

    /// Resolved once per view, not per frame — see `OnboardingMetrics`.
    private let metrics = OnboardingMetrics.forCurrentScreen()

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
    @Environment(\.scenePhase) private var scenePhase
    /// The same key as Settings › Storage and the default registered in
    /// `OpenBatApp.init` — this screen is just the first place it gets asked.
    /// Nothing needs migrating when it changes here (there are no recordings
    /// yet), so unlike Settings this doesn't raise the restart alert.
    @AppStorage(CloudStorage.keepInICloudKey) private var keepInICloud = true
    // Drives the direction of the step transition, so going Back slides the
    // opposite way to going forward rather than both looking like "forward".
    @State private var isMovingBackward = false
    // Owned here only long enough to drive the one-shot region-fix permission
    // request; ContentView creates its own instance afterwards. CLLocationManager
    // authorization is process-global, so requesting here doesn't cause a second
    // prompt later — by the time ContentView appears the status is already decided.
    @State private var location = LocationProvider()
    /// `nil` until the first probe answers, which is the state the welcome
    /// footer must also be able to speak in: claiming "no microphone" in the
    /// half-second before anything has been checked would be a lie shown to
    /// every user, including the ones holding a connected microphone.
    @State private var usbMicConnected: Bool?

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
    // longer constructed here as a result. The only audio onboarding touches is
    // `UltrasonicMicProbe`, which sets a session category and reads the input
    // list — it never activates the session, so it starts no capture, prompts
    // for nothing and interrupts no other app.

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
                .background(Color.appBackground)
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
        // The shared components (`OnboardingStepView`, `OnboardingCard`,
        // `PermissionRow`) size themselves from this rather than being handed
        // it at every call site.
        .environment(\.onboardingMetrics, metrics)
        .task { await watchForMicrophone() }
        // Both statuses are read once, into state, and then only updated by the
        // dialogs this flow puts up — so a status that changed outside the app
        // (Settings, or a previous run's refusal) has to be picked up here or
        // the permission rows describe a device that no longer exists. See
        // `LocationProvider.refreshAuthorization`.
        .onAppear(perform: refreshPermissionStatuses)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshPermissionStatuses() }
        }
    }

    /// Jumps to OpenBat's own page in the Settings app, which is where a
    /// refused permission is turned back on. The statuses are re-read when the
    /// app becomes active again, so the rows are right on the way back.
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func refreshPermissionStatuses() {
        micStatus = AVAudioApplication.shared.recordPermission
        location.refreshAuthorization()
    }

    /// Keeps `usbMicConnected` current for as long as onboarding is on screen.
    /// The loop ends with the view — `.task` cancels it — so nothing polls on
    /// into the app's life.
    private func watchForMicrophone() async {
        while !Task.isCancelled {
            usbMicConnected = await UltrasonicMicProbe.isConnected()
            try? await Task.sleep(for: UltrasonicMicProbe.pollInterval)
        }
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
                    .padding(.top, metrics.contentPadding)
                    // Clearance above the pinned footer and button bar. Without
                    // it the scrolled column ends flush against them, so the
                    // last row of a step reads as clipped underneath the
                    // buttons rather than as the end of a list.
                    .padding(.bottom, metrics.contentPadding)
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
            // Three cards, roughly a line of detail each. The longer versions
            // read well on paper and pushed the third card off the bottom of a
            // 667pt screen — see this file's header on why that is a failure
            // rather than a scroll.
            VStack(spacing: metrics.sectionSpacing) {
                OnboardingStepView(
                    hero: { SonarPulseHero(size: metrics.heroSize) { OnboardingBranding.logo(size: metrics.logoSize) } },
                    title: "Welcome to OpenBat",
                    message: "Bat detecting made affordable, from a community project in Squamish, BC.")

                VStack(spacing: metrics.cardSpacing) {
                    // The same two drawn glyphs the tab bar wears for Detector
                    // and Species, so the three things promised here are already
                    // recognisable as the tabs they land on.
                    OnboardingCard(
                        glyph: .asset("batCall"),
                        title: "Detect",
                        detail: "Calls drawn live as they arrive, and recorded in full ultrasonic quality.")
                    OnboardingCard(
                        systemImage: "sparkle.magnifyingglass",
                        title: "Identify",
                        detail: "Machine learning names the species here on your phone. Nothing is sent away.")
                    OnboardingCard(
                        glyph: .asset("batBook"),
                        title: "Learn",
                        detail: "A field guide to the bats near you — range maps, calls and photos.")
                }
            }

        case .permissions:
            VStack(spacing: metrics.sectionSpacing) {
                OnboardingStepView(
                    systemImage: "checkmark.shield.fill",
                    title: "Two things to allow",
                    message: "And one choice about where your recordings live.")

                VStack(spacing: metrics.cardSpacing) {
                    PermissionRow(
                        systemImage: "mic.fill",
                        title: "Microphone",
                        detail: "Records calls above human hearing.",
                        // Denial is survivable for location and fatal for the
                        // microphone, so the two rows must not say the same
                        // mild thing about it. With no mic access the detector
                        // shows a permanently empty spectrogram, which reads as
                        // a broken app rather than as a choice the user made.
                        // Where to fix it is the footer's job now, and saying it
                        // in both places says it twice on one screen.
                        deniedNote: "Without this OpenBat can't hear anything.",
                        state: micRowState,
                        openSettings: openAppSettings)
                    PermissionRow(
                        systemImage: "location.fill",
                        title: "Location",
                        // NO mention of a track: GPS courses were removed on
                        // 2026-08-16 along with the background location mode,
                        // and this line still promised one. Four one-shot uses,
                        // grouped rather than enumerated — the original spelled
                        // all four out in one 40-word sentence.
                        detail: "Tonight's sunset and sunrise, where each call was heard, and which species to expect nearby.",
                        deniedNote: "Sunset times and nearby-species hints will be off.",
                        state: locationRowState,
                        openSettings: openAppSettings)
                    StorageChoiceRow(keepInICloud: $keepInICloud)
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
                    Text("Recordings stay yours. Nothing leaves this device unless you choose to contribute it, and you'll be asked first, every time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Read the full privacy notice") { showPrivacyDetail = true }
                        .font(.footnote)
                }
                .padding(.horizontal, 8)
            }

        case .autoID:
            VStack(spacing: metrics.sectionSpacing) {
                OnboardingStepView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "About the IDs",
                    message: "OpenBat names the bats it hears with machine learning, on this device. Some species simply cannot be told apart by sound.")

                // **This step used to teach two labels here** — the
                // "sounds alike" and "or SPECIES" pills, one card each, worded
                // to stay in step with `ComplexIndicator.text` in SessionsView.
                // Cut on 2026-09-08, for the same reason the eight-screen flow
                // was cut in the first place: they taught vocabulary for a
                // screen the user has not reached, about a pass they have not
                // heard. Both pills explain themselves on the pass they appear
                // on, which is the moment that distinction is worth anything,
                // so the teaching was moved rather than lost.
                //
                // **The cards on a step have to be about the step** (Niall,
                // 2026-09-09). Under a heading that says "About the IDs", the
                // one card here talked about where the app's settings live —
                // true, useful, and about a different subject, which made the
                // heading read as a mistake. It has swapped places with the
                // footer: the caveat that was pinned at the bottom is the first
                // card, because it IS the thing this step exists to say, and the
                // promise that nothing is a one-way door is now the closing note.
                VStack(spacing: metrics.cardSpacing) {
                    OnboardingCard(
                        systemImage: "exclamationmark.triangle.fill",
                        title: "Every ID is a suggestion",
                        detail: "Calls change with the environment, other bats and insects, so confirming a species takes further analysis.")
                    // The honest answer to "then how do I ever know?", and the
                    // only one the app can offer: other people. Not gated on
                    // the iNaturalist feature switch — onboarding runs before
                    // `ContentView`, which is where the flag store lives, and
                    // the promise is about the app rather than about tonight.
                    OnboardingCard(
                        systemImage: "person.2.fill",
                        title: "Get a second opinion",
                        detail: "OpenBat can post a recording to iNaturalist, where other people can check it — the surest route to an identification a person has confirmed.")
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
            //
            // It reports what is actually plugged in rather than warning in the
            // abstract (`UltrasonicMicProbe`, polled while this view is up).
            // A generic "you will need a microphone" is read as not applying by
            // the user who already has one and skimmed past by the one who
            // doesn't; "no microphone connected", checked and stated, is neither.
            if usbMicConnected == true {
                cautionFooter(spacing: 14, tint: .green) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: metrics.footerGlyph * 0.5))
                        .foregroundStyle(.green)
                } text: {
                    "Ultrasonic microphone connected. You're ready to hear bats."
                }
            } else {
                cautionFooter {
                    PlugInAnimation(tint: .primary)
                        .frame(width: metrics.footerGlyph, height: metrics.footerGlyph)
                } text: {
                    // `nil` (not yet probed) gets the neutral wording: stating
                    // "no microphone" before anything has been checked would be
                    // a claim shown briefly to every user, connected or not.
                    usbMicConnected == false
                        ? "No ultrasonic microphone connected. OpenBat needs one to hear bats — see Help in the top-right menu."
                        : "OpenBat needs a USB microphone that can hear ultrasound — see Help in the top-right menu."
                }
            }

        case .permissions:
            // The same grey note the last step ends on, and it answers the same
            // worry one step earlier: neither of these is a door that closes.
            // Deliberately not a fourth card in the column above — the cards
            // there are the three things being asked for, and a fourth that
            // asks for nothing would dilute that.
            cautionFooter(spacing: 14, tint: .secondary) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: metrics.footerGlyph * 0.5))
                    .foregroundStyle(.secondary)
            } text: {
                "Refusing either is fine, and it isn't final — Microphone and Location can be switched on whenever you like, in the Settings app under OpenBat."
            }

        case .autoID:
            // Grey rather than orange, and a gear rather than a warning
            // triangle: this is the last thing said before the app opens and it
            // is a reassurance, not a caution. An orange wash here would teach a
            // user that the colour means nothing, which costs the welcome step's
            // microphone warning its force.
            //
            // No fixed frame, and a tighter gap than the welcome step's. The
            // 76×76 slot is sized for `PlugInAnimation`, which fills it; a
            // symbol does not, so the box added ~19pt of dead space on each side
            // on top of the 25pt gap and left the glyph marooned.
            //
            // It names its two destinations — a vague "in Settings somewhere" is
            // not a findable promise.
            cautionFooter(spacing: 14, tint: .secondary) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: metrics.footerGlyph * 0.5))
                    .foregroundStyle(.secondary)
            } text: {
                "Nothing here is permanent. Settings holds the rest of the app's controls, and Info & Tour, in the same menu, walks you round the screen when you're ready."
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
    ///
    /// `tint` exists for one case: the welcome footer turns green once a
    /// microphone is actually detected. Orange there would be a warning about a
    /// condition that has been satisfied, which is how users learn to stop
    /// reading a colour.
    private func cautionFooter(
        spacing: CGFloat = 25,
        tint: Color = .orange,
        @ViewBuilder leading: () -> some View,
        text: () -> String
    ) -> some View {
        HStack(spacing: spacing) {
            leading()
            Text(text())
                .font(.footnote)
                // Not white: this sits on a 20%-orange wash, which is a pale
                // wash on a light page.
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .padding(.top, 12)
        // The gap down to the buttons. Larger than the top gap on purpose: this
        // footer is a note about the app, and it shouldn't read as being
        // attached to the primary action.
        .padding(.bottom, metrics.footerBottomPadding)
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
                // centre. Same reason `AreaChangeSheet` expands its label.
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
        // **"Next" once both have been answered** (Niall, 2026-09-09). It was
        // "Continue" either way, on the reasoning that whether a tap opens a
        // system dialog or moves on is `advance()`'s business and not the
        // label's. That holds right up until the dialogs are done, when the
        // same word on the same button does a different thing — and a button
        // that looked like it had already been pressed, with no dialog
        // appearing, reads as an app that has frozen rather than one waiting to
        // be told to move on. It is NOT the old "Allow Access", which described
        // the button honestly but made the flow look like it had a gate in it:
        // this changes at the end, not the beginning.
        case .permissions: return allPermissionsDecided ? "Next" : "Continue"
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
            // Straight into the app, with nothing handed forward. It does not open
            // the tour: dropping someone straight out of onboarding into another
            // guided thing, on a detector that has nothing on it yet, is more
            // onboarding at exactly the point they were promised it had ended.
            // Both tours are under Info & Tour, which is where the card above
            // points. It no longer arranges a model suggestion either — the model
            // is picked from the first location fix (`AutoIDSettings.applyCoverage`).
            onComplete()
        }
    }

    /// Runs both OS dialogs back to back, mic first, and leaves the user on
    /// this screen when they're done rather than advancing automatically — the
    /// rows have just filled in with ticks, and skipping past that instantly
    /// hides the only confirmation they get that it worked.
    ///
    /// **Both are asked unconditionally** (Niall, 2026-09-09). They used to be
    /// asked only when this screen believed the status was undetermined, which
    /// meant one stale reading was enough to skip a dialog iOS would have shown
    /// — and the user watched Continue do nothing. Asking when the answer is
    /// already in costs nothing: iOS returns the existing answer without
    /// putting anything on screen. The status is re-read from the system after
    /// each, so what the rows show is what iOS says rather than what we
    /// predicted it would say.
    private func requestPermissions() {
        isAwaitingPermission = true
        Task {
            _ = await AVAudioApplication.requestRecordPermission()
            micStatus = AVAudioApplication.shared.recordPermission
            // Waits for the real OS dialog to actually be resolved (granted, denied,
            // or restricted) before continuing — requestRegionFix() alone doesn't
            // await that decision, it only fires the request. Denial here just means
            // the app runs without location tagging; nothing to branch on
            // synchronously.
            _ = await location.requestAuthorizationDecision()
            location.refreshAuthorization()
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

    @Environment(\.onboardingMetrics) private var metrics

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
        .padding(metrics.cardPadding)
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
    /// What is lost by refusing, appended to `detail` once the answer is no.
    /// Per-row rather than one shared sentence, because the two permissions do
    /// not cost the same: without location the app is slightly less helpful,
    /// without the microphone it does nothing at all.
    let deniedNote: String
    let state: State
    /// Opens OpenBat's page in the Settings app. Shown only on a refused row,
    /// because that is the only state where anything can be done from here:
    /// **iOS never puts its dialog up twice**, so once a permission has been
    /// refused there is nothing left for Continue to ask — the switch in
    /// Settings is the whole of "ask again", and a row that says what was lost
    /// without offering the one way back is a dead end.
    let openSettings: () -> Void

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        if state == .denied {
            Button(action: openSettings) { card }
                .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.batAccent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(state == .denied ? deniedNote : detail)
                    .font(.caption)
                    .foregroundStyle(state == .denied ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // The slot is kept even when it draws nothing, so the answer
            // appearing doesn't re-wrap the paragraph beside it.
            statusGlyph
                .font(.system(size: 18))
                // A minimum rather than a fixed width: the slot is reserved so
                // an answer arriving doesn't re-wrap the paragraph beside it,
                // and a refused row needs more of it than a tick does.
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        // Makes the glyph's own transition actually play: the answer arrives
        // from an OS dialog, outside any `withAnimation`, so without this the
        // tick appeared instantly and the transition below was dead code.
        .animation(.snappy(duration: 0.25), value: state)
    }

    /// An answer, or nothing — and when the answer is no, a way out of it.
    ///
    /// **Nothing while the answer is still to come** (2026-09-09, from a
    /// tester). The dotted empty circle this drew was the shape of a checkbox,
    /// so the rows read as three things to tick — and one of them, the iCloud
    /// row, genuinely is a control, which made the wrong reading look confirmed.
    ///
    /// **A cross AND a chevron once it is refused** (Niall, same day). The two
    /// say different things and both are needed: the cross is the answer, which
    /// is the same thing the tick is on the row above it, and the chevron is the
    /// way to change it. iOS shows its dialog once per install, so without the
    /// second half a refusal is a statement with no reply — which is the loop
    /// this closes.
    @ViewBuilder private var statusGlyph: some View {
        switch state {
        case .pending:
            EmptyView()
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .transition(.scale.combined(with: .opacity))
        case .denied:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }
}

/// The iCloud storage choice, styled to sit in the same list as `PermissionRow`
/// but deliberately not one: nothing is being asked of iOS here, and there is no
/// status glyph to fill in because the answer is whatever the switch says.
///
/// **It is on this screen because it was previously never asked at all.** The
/// default is on, a night of 384 kHz audio runs to several GB, and the container
/// is not document-scope public — so recordings were silently consuming a user's
/// iCloud quota in a place they could not see, browse or clear from the Files
/// app. Defaulting to on is defensible; doing it without ever saying so is what
/// wasn't. The same toggle stays in Settings › Storage for changing it later.
private struct StorageChoiceRow: View {
    @Binding var keepInICloud: Bool

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $keepInICloud) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "icloud.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.batAccent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep recordings in iCloud")
                            .font(.subheadline.weight(.semibold))
                        // Both halves of the trade, the cost included — same
                        // reasoning as the Settings footer this mirrors.
                        Text(keepInICloud
                             ? "They follow you to a new device. Bat audio is large — a busy night can use several GB."
                             : "They stay on this phone, and are lost if you delete OpenBat.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(.batAccent)
        }
        .padding(metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
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

    @Environment(\.onboardingMetrics) private var metrics

    var body: some View {
        VStack(spacing: metrics.headerSpacing) {
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
            OnboardingBranding.logo(size: metrics.logoSize)
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.system(size: metrics.symbolSize))
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
    @ViewBuilder static func logo(size: CGFloat = 64) -> some View {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
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
