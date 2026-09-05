//
//  AppInfoView.swift
//  OpenBat
//
//  "Info" sheet (what the app does) launched from the Detector's options menu, plus
//  the guided spotlight tour it can kick off. The tour dims the whole screen and
//  cuts a hole over one real control at a time, with a caption explaining it.
//
//  The tour highlights live controls by their on-screen bounds: each control is
//  tagged with `.tourTarget(_:)`, ContentView collects the anchors via
//  `.overlayPreferenceValue`, and `TourOverlay` resolves them to rects. A step
//  whose target isn't on screen in the current orientation just shows a centred
//  card (no cutout) instead — so the tour degrades gracefully rather than
//  pointing at nothing.
//

import SwiftUI
import UIKit

// MARK: - Tour target plumbing

/// Stable IDs for the controls the tour can spotlight. A control that exists in
/// more than one layout tags every variant — only one is ever in the view tree,
/// so only one anchor is recorded.
enum TourID: Hashable {
    // The three panes, top to bottom.
    case stats, pulseView, spectrogram
    // Individual buttons, tagged on the shared button properties.
    case micStatus, resetStats                 // stats header
    case sessionStatus, feedbackWarning        // stats header
    case slowReplayStatus                      // stats header — slow-replay activity
    case sessionTimer                          // spectrogram header
    case pulseSpeciesToggle, pulseSettings     // pulse-view header
    case spectrogramSpeciesToggle, compressTimeline, batRange, palette, bandSettings
    case start, record, listen                 // session button + its transport menu
    /// The transport menu as a whole. The simplified tour covers Record, Listen
    /// and End in one step; the advanced tour keeps `record` and `listen`
    /// separate.
    case transportMenu
    case sunClock                              // nav bar
    /// The three ordinary tabs. Unlike every other case these are NOT published
    /// by `.tourTarget` — on iOS 26 a `Tab`'s label is drawn by the bar, outside
    /// the view tree the anchor preference travels through, so ContentView feeds
    /// these in from `SessionButtonLocator` instead. `.start` is fed the same way
    /// for the same reason.
    case tab(AppSection)
}

/// Accumulates one bounds anchor per tagged control (see `tourTarget(_:)`
/// below). `reduce` merges siblings; it can't reconcile parent/child overlap,
/// which is why `tourTarget` must use `transformAnchorPreference`.
struct TourTargetKey: PreferenceKey {
    static let defaultValue: [TourID: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourID: Anchor<CGRect>],
                       nextValue: () -> [TourID: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// Tag a control so the guided tour can spotlight it. Cheap and inert when no
    /// tour is running (it only publishes a bounds anchor).
    ///
    /// Must be `transformAnchorPreference`, not `anchorPreference`: targets nest
    /// (buttons tagged inside a pane that is itself tagged), and a plain
    /// `anchorPreference` on the outer view REPLACES the dictionary its descendants
    /// accumulated — the key's `reduce` only merges siblings, not parent/child —
    /// silently dropping every button anchor inside a tagged pane.
    func tourTarget(_ id: TourID) -> some View {
        transformAnchorPreference(key: TourTargetKey.self, value: .bounds) { dict, anchor in
            dict[id] = anchor
        }
    }
}

// MARK: - Tour script

/// One step in `TourScript`: a caption card, optionally spotlighting one
/// tagged control.
struct TourStep: Identifiable {
    let id = UUID()
    /// The control to spotlight, or nil for a centred, no-cutout card.
    let target: TourID?
    let symbol: String
    /// Rotation applied to the card's symbol, matching icons the UI itself renders
    /// rotated (the bat-range button draws its bracket at -90°).
    var symbolRotation: Angle = .zero
    /// Set on the steps whose target lives inside the session button's transport
    /// menu, which is closed unless the user opened it. ContentView watches the
    /// step index and opens the menu for exactly these, so the spotlight has
    /// something real to point at — see its `onChange(of: tourIndex)`.
    var opensTransportMenu: Bool = false
    // There used to be an `advancedOnly` flag here, filtering the one shared
    // script down for simplified view. The two scripts are separate lists now
    // (see `TourScript`), so a step's mode is decided by which list it is in —
    // there is no longer a flag that can disagree with that.
    let title: String
    let detail: String
}

/// The guided tour's script, driving `AppInfoView`'s `TourOverlay`.
///
/// **Two genuinely different tours, not one tour with gaps.**
///
/// The simplified tour used to be the advanced one with the advanced-only steps
/// filtered out, which left sixteen steps — every pill in the stats header, both
/// listening modes, the deaf-window trade-off — for someone who has not yet heard
/// a bat. It is now its own short script of five: the three panes, then the
/// session button and what its second tap opens.
///
/// The advanced tour is unchanged in shape and still walks the whole screen; it
/// remains the superset, which is what makes `OnboardingState.shouldOfferTour`
/// safe to retire the button on once it has been finished.
enum TourScript {
    static func steps(simplified: Bool) -> [TourStep] {
        simplified ? simplifiedSteps : advancedSteps
    }

    /// The short tour. No welcome card: the popover that offers the tour has
    /// already said what it is, and opening with a step that says "here is a
    /// tour" inside a tour is the kind of padding this rewrite exists to remove.
    private static let simplifiedSteps: [TourStep] = [
        TourStep(target: .stats, symbol: "chart.bar",
                 title: "Status and level",
                 detail: "How loud the microphone is hearing, and whether it's connected. If this stays flat when a bat goes over, check the mic rather than the sky."),

        TourStep(target: .pulseView, symbol: "sparkle.magnifyingglass",
                 title: "Species ID",
                 detail: "Every species identified this session, most recent first. Tap any one to see the calls behind it and how confident the identification was."),

        TourStep(target: .spectrogram, symbol: "waveform.badge.magnifyingglass",
                 title: "Spectrogram",
                 detail: "A picture of what the microphone is hearing: time across, pitch up the side. A bat call is a bright stroke sweeping downward. Drag it to look back at what just went past."),

        // The three tabs used to get a spotlight each here. They are labelled,
        // permanently on screen, and a beginner finds them by tapping them —
        // three steps to say "this is the Sessions tab" is the tour explaining
        // its own furniture. What actually needs explaining is the one control
        // that is not self-evident: a round button whose second tap does
        // something different from its first.
        //
        // `play.fill` because that is the glyph on the button being pointed at
        // (see `ContentView.sessionSymbol`) — a card showing a record dot beside
        // a spotlight on a play triangle asks the user to work out whether they
        // are looking at the right control.
        TourStep(target: .start, symbol: "play.fill",
                 title: "Start listening",
                 detail: "The round button starts a session. That's the whole thing: tap it, point the microphone at the open sky, and wait. Once it's running, tap it again to open the controls below."),

        TourStep(target: .transportMenu, symbol: "slider.horizontal.3", opensTransportMenu: true,
                 title: "Record, listen, end",
                 detail: "Record keeps a file of each pass. Listen brings the calls down into your hearing, tapping through the options. End stops the session and files it away. (Shown here for the tour.)"),
    ]

    // Walks the screen top-to-bottom: the nav bar, each pane first, then each
    // button inside it individually, then the session button and the controls in
    // its menu, then how to get around.
    //
    // No longer parameterised on `simplified` — every step here is shown, because
    // this script only ever runs in advanced view now. The simplified branches
    // each case used to carry moved out into `simplifiedSteps`, which no longer
    // has to describe the same control in two registers at once.
    private static let advancedSteps: [TourStep] = [
        TourStep(target: nil, symbol: "hand.wave",
                 title: "Welcome to OpenBat",
                 detail: "A real-time bat detector for the ultrasonic mic. Here's a quick tour of the screen — tap Next to step through, or End tour any time."),

        TourStep(target: .sunClock, symbol: "sunset",
                 title: "Sun clock",
                 detail: "Tonight's sunset, then how long it's been since, then the coming sunrise. A filled sun means you're inside one of the two windows bats are busiest in — the first and last sixth of the night. Tap it for both times."),

        TourStep(target: .stats, symbol: "chart.bar",
                 title: "Live stats",
                 detail: "Peak frequency, bandwidth, duration, pulse rate and count for the most recent pulse, plus the input level. They clear when activity goes stale."),
        // Left-to-right along the stats header, matching statsStrip's own order.
        TourStep(target: .slowReplayStatus, symbol: "ear",
                 title: "Slow replay status",
                 detail: "Only appears while the slow-replay listen mode is running. An ear means it's ready and waiting for a call, red means it's capturing one, and a tortoise means it's replaying — while that ring fills, no new call can be captured. (Shown here for the tour.)"),
        TourStep(target: .feedbackWarning, symbol: "exclamationmark.triangle.fill",
                 title: "Feedback warning",
                 detail: "Appears only while heterodyne or other captured audio is playing out of the phone's speaker — the mic hears that playback and shows it as a spurious second call. Wear headphones to clear it. (Shown here for the tour.)"),
        TourStep(target: .sessionStatus, symbol: "location.fill",
                 title: "What's running",
                 detail: "Off when nothing is detecting, and Session once a run is going and its IDs are being logged."),
        TourStep(target: .micStatus, symbol: "cable.connector",
                 title: "Mic status",
                 detail: "Shows whether the ultrasonic mic is attached and the sample rate it's running at — this should show 384 kHz."),
        TourStep(target: .resetStats, symbol: "arrow.counterclockwise",
                 title: "Reset stats",
                 detail: "Clears the pulse count, pulse rate and the level meter's peak-hold."),
        TourStep(target: .pulseView, symbol: "waveform.path.ecg",
                 title: "Pulse view & Species ID",
                 detail: "A zoomed, onset-aligned render of the latest call. Pinch and drag to inspect it. It can also show the live Species ID feed instead."),
        TourStep(target: .pulseSpeciesToggle, symbol: "sparkle.magnifyingglass",
                 title: "Species ID feed",
                 detail: "The bat glyph swaps this pane between the pulse close-up and the live Species ID feed. In the feed, tap any ID for the pulses and scores behind it."),
        TourStep(target: .pulseSettings, symbol: "slider.horizontal.3",
                 title: "Pulse view settings",
                 detail: "Display settings for the pulse close-up — zoom window span and noise floor."),

        TourStep(target: .spectrogram, symbol: "waveform.badge.magnifyingglass",
                 title: "Spectrogram",
                 detail: "The scrolling frequency-vs-time view. Drag to scroll back through history."),
        TourStep(target: .sessionTimer, symbol: "timer",
                 title: "Elapsed time",
                 detail: "How long the current run has been detecting, counting from when you started. It appears once detection is running and disappears when you stop. (Shown here for the tour.)"),
        TourStep(target: .spectrogramSpeciesToggle, symbol: "sparkle.magnifyingglass",
                 title: "Species ID here too",
                 detail: "Swaps this pane to the Species ID feed, same as in the pulse view — useful when you want the running list on the larger of the two panes."),
        TourStep(target: .compressTimeline, symbol: "lines.measurement.horizontal.aligned.bottom",
                 title: "Compress timeline",
                 detail: "Drops the silent gaps so the display shows just the detected pulses, back-to-back."),
        TourStep(target: .batRange, symbol: "minus.plus.lines.measurement.horizontal.aligned.bottom",
                 symbolRotation: .degrees(-90),
                 title: "Bat frequency band",
                 detail: "One-tap preset snapping the frequency axis to 15–90 kHz, where most bat calls live. Tap again to restore the full range. Custom ranges can be set also."),
        TourStep(target: .palette, symbol: "paintpalette",
                 title: "Colour palette",
                 detail: "Picks the colormap for the spectrogram and pulse view — Inferno, Viridis, Jet and friends."),
        TourStep(target: .bandSettings, symbol: "slider.horizontal.3",
                 title: "Display range",
                 detail: "Fine control over the displayed frequency range, time window and noise floor."),

        TourStep(target: .start, symbol: "record.circle",
                 title: "Start a session",
                 detail: "The round button beside the tab bar starts detecting. Every run is logged as a session — its IDs are grouped together and mapped where they were heard, and any recordings carry the full GUANO metadata. Tap it again once a run is going and it opens the controls below."),
        TourStep(target: .record, symbol: "record.circle", opensTransportMenu: true,
                 title: "Record",
                 detail: "Arms WAV recording — each detected pass is saved as its own file, with the species ID in its metadata. It arms itself when a session starts unless you've turned that off in Settings."),
        TourStep(target: .listen, symbol: "headphones", opensTransportMenu: true,
                 title: "Listen",
                 detail: "One button, four steps: off, heterodyne (tuned-down clicks and chirps), slow replay (a snippet around each call played back 8× slower, so its real shape is audible), then slow replay with heterodyne underneath it. The glyph shows which you're on — headphones, antenna, tortoise, filled tortoise."),
        TourStep(target: .listen, symbol: "tortoise.fill", opensTransportMenu: true,
                 title: "Slow replay, and going deaf",
                 detail: "While a snippet is replaying, no new call is being captured — that's the trade-off, and it's why the fourth step exists: heterodyne keeps playing underneath, so you can still hear the bat overhead while the last call is replayed. The status pill up in the stats header shows which of the two it's doing."),

        // Was one card claiming a Playback tab that no longer exists — playback
        // folded into Sessions (2026-08-16), so a recording now has exactly one
        // place to be. Split into a spotlight per tab so it points at each rather
        // than listing them.
        TourStep(target: .tab(.detector), symbol: "wave.3.up",
                 title: "Detector",
                 detail: "This screen — the live view, and where a session runs from."),
        TourStep(target: .tab(.sessions), symbol: "waveform.path.ecg.text.clipboard",
                 title: "Sessions",
                 detail: "Every run you've logged: the species heard, where they were heard, and any recordings kept — played back from the session itself."),
        TourStep(target: .tab(.species), symbol: "book.closed",
                 title: "Species",
                 detail: "The field guide: the bats in your region, their calls and measurements, and range maps."),

        TourStep(target: nil, symbol: "gearshape",
                 title: "The rest of it",
                 detail: "Top-right holds Settings and Help, and this Info & Tour screen — come back here any time to run the tour again. The switch between simplified and full view is the first thing in Settings, under General. That's the tour — happy detecting!"),
    ]
}

// MARK: - Tour offer

/// What the Detector's tour button opens: a short pitch for the tour and the
/// button that starts it.
///
/// Sized for a popover, so it says one thing. The mode-specific line is the
/// point of the two variants — someone in simplified view is being offered a
/// five-step walk round three panes and the session button, and someone in full
/// view a walk round every control on the screen. Promising the wrong one of
/// those is how a tour gets abandoned halfway.
struct TourOfferPopover: View {
    let simplified: Bool
    let start: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(Color.batAccent)
                Text("New here?")
                    .font(.headline)
            }

            Text(simplified
                 ? "A quick guided tour points out what's on the screen and how to start listening — five taps."
                 : "A guided tour walks you round every readout and control on the detector, one at a time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Says plainly that this offer goes away, and that the tour doesn't.
            // Without it, a user who dismisses the popover has no way to know
            // whether they have just lost something.
            Text("This button disappears once you've been through it. The tour stays available under Info & Tour.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: start) {
                Text("Start the tour")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(.batAccent)
        }
        .padding(18)
        .frame(width: 300)
    }
}

// MARK: - Info sheet

struct AppInfoView: View {
    /// Requests the guided tour. Called before the sheet dismisses itself; the
    /// host launches the tour from the sheet's onDismiss, once it's actually gone.
    var startTour: () -> Void
    /// For the demo picker's "Your Recordings" list — see `DemoModeView`.
    let classStore: ClassificationStore
    /// Feeds a file through the detector in place of the microphone. Owned by
    /// ContentView, which is the only place that can stop detection and clear
    /// the session first — see `startDemo` there.
    let startDemo: (URL, String) -> Void
    @Environment(\.dismiss) private var dismiss
    /// The second tour — the retired middle of onboarding. Presented from here
    /// rather than flagged-and-dismissed like the guided one: it has nothing to
    /// spotlight, so it has no reason to wait for this sheet to get out of the way.
    @State private var showAboutTour = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    // One paragraph, not three. The long "what it does" /
                    // "origin" / "getting started" run was the bulk of this
                    // sheet's length (Niall, 2026-09-02); the origin story is
                    // now behind the disclosure at the bottom, and getting
                    // started is what the guided tour is for.
                    Text("Turns an iOS-compatible ultrasonic USB microphone into a live bat detector: real-time spectrogram, per-pulse detection, and on-device species ID where an open model exists for your region.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    // The four things you can do from here, as a 2×2 grid of
                    // square tiles rather than four full-width buttons each
                    // trailing a caption paragraph. Four equal doors, not one
                    // offer with three footnotes — which is why they are all one
                    // material and one shape. That material used to be a flat
                    // accent fill and is now the guide's own card (Niall,
                    // 2026-09-02); artwork goes behind each one as it arrives.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                        GridItem(.flexible(), spacing: 12)],
                              spacing: 12) {
                        Button {
                            // Flag the tour, then dismiss; the host starts it from
                            // the sheet's onDismiss so the spotlight lands on the
                            // real, unobscured UI — no timing race with the
                            // dismiss animation.
                            startTour()
                            dismiss()
                        } label: {
                            infoTile("sparkles", "Guided tour",
                                     "Points at each control on the detector.",
                                     art: "infoCardTour")
                        }
                        .buttonStyle(.plain)

                        // **Demo lives here because this is the screen someone
                        // without a microphone reaches.** It used to be reachable
                        // only through the Debug sheet, behind a hidden
                        // fifteen-tap unlock — so the one feature that answers
                        // "what does this app do before I buy hardware?" was
                        // invisible to everyone who needed it, App Review
                        // included (an app that can't be evaluated without
                        // hardware is a Guideline 2.1 rejection).
                        //
                        // A NavigationLink rather than a sheet: this view already
                        // has a NavigationStack, and DemoModeView is written to be
                        // pushed onto an enclosing one (no stack, no Cancel, no
                        // title bar of its own).
                        NavigationLink {
                            DemoModeView(classStore: classStore) { url, name in
                                // Same order as the Debug sheet's picker: close the
                                // whole sheet first, because the demo runs on the
                                // detector behind it. `dismiss` is this view's, not
                                // the pushed page's, so it takes the sheet down
                                // rather than popping back to the About screen.
                                dismiss()
                                startDemo(url, name)
                            }
                        } label: {
                            infoTile("play.rectangle", "Try the demo",
                                     "A real night, played through the detector.",
                                     art: "infoCardDemo")
                        }
                        .buttonStyle(.plain)

                        // A sheet rather than a push, unlike What's New below.
                        // This is a paged flow with its own bottom bar and Back
                        // arrow, and pushing it would put a second Back in the
                        // nav bar pointing somewhere else entirely.
                        Button { showAboutTour = true } label: {
                            infoTile("book", "About the app",
                                     "Echolocation, listening modes, calibration.",
                                     art: "infoCardAbout")
                        }
                        .buttonStyle(.plain)

                        // Where What's New lives once the after-update sheet has
                        // been dismissed. A push rather than another sheet:
                        // stacking sheets is how a user loses track of what
                        // dismissing gets them back to.
                        NavigationLink {
                            WhatsNewContent()
                        } label: {
                            infoTile("clock.arrow.circlepath", "What's New",
                                     "What changed in this version.",
                                     art: "infoCardWhatsNew")
                        }
                        .buttonStyle(.plain)
                    }

                    featureList

                    // The origin story is worth keeping and worth not making
                    // everyone scroll past — collapsed, like the credits below.
                    DisclosureGroup("Why OpenBat exists") {
                        Text("Most tools for identifying bat calls are expensive, proprietary, and hard to get hold of, which puts the experience out of reach for a lot of people who'd genuinely enjoy it. Free apps that work with ultrasonic microphones exist, but as far as I know none of them use the open-source machine learning models trained on bat echolocation calls. Building that identification into the app helps people put a name to the call they just heard — and that small moment of recognition does a lot to build a real connection with bats, and with it a bit more respect for them too.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                    }
                    .font(.headline)
                    .tint(.batAccent)

                    attributionSection
                }
                .padding(20)
            }
            .navigationTitle("About OpenBat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showAboutTour) { AboutAppTour() }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenBat").font(.title2.bold())
                Text("Ultrasonic bat detector").font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    /// The real app icon, with the rounded-rect (squircle-ish) mask iOS gives icons.
    /// Falls back to the bat glyph if the icon image can't be loaded.
    @ViewBuilder private var appIcon: some View {
        Group {
            if let icon = Self.appIconImage {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                Image("batIcon")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    /// The primary app icon from the bundle. The asset-catalog app icon isn't
    /// reliably reachable by a fixed name, so resolve the actual filename from the
    /// Info.plist icon-files list and load that.
    private static let appIconImage: UIImage? = {
        guard
            let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
            let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
            let files = primary["CFBundleIconFiles"] as? [String],
            let name = files.last
        else { return nil }
        return UIImage(named: name)
    }()

    /// Five lines, one each. The detail sentences that used to sit under every
    /// title mostly restated it, and five of them was a screenful.
    private var featureList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Features").font(.headline)
            feature("waveform.badge.magnifyingglass", "Real-time spectrogram with scrollable history")
            feature("waveform.path.ecg", "Per-pulse detection and onset-aligned zoom")
            feature("sparkle.magnifyingglass", "On-device species ID, with runner-up and confidence")
            feature("headphones", "Heterodyne and 8× slow replay — live")
            feature("square.stack.3d.up", "Sessions logged and mapped automatically")
        }
    }

    private func feature(_ symbol: String, _ title: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.subheadline)
                // The app's orange, not `.tint` — the accent colour in the
                // asset catalog is unset, so `.tint` resolved to the system
                // blue and these were the only blue glyphs in the app.
                .foregroundStyle(Color.batAccent)
                .frame(width: 22)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One action tile — **built as a species card is built** (Niall,
    /// 2026-09-02): a square glass tile, artwork running full bleed inside it,
    /// and the name legible over a scrim along the bottom. See `GuideSpeciesCard`,
    /// which is the same object; these four are the guide's cards pointed at the
    /// app's own features rather than at a bat.
    ///
    /// `art` names an image in the asset catalog and is OPTIONAL, so the four
    /// tiles work now and get their pictures when the pictures exist. With no
    /// artwork the glass is the card — the icon takes the accent colour and the
    /// text takes the page's own ink; with artwork it all goes white over the
    /// scrim, exactly as a species card does.
    private func infoTile(_ symbol: String, _ title: String, _ subtitle: String,
                          art: String? = nil) -> some View {
        // Asked of UIKit rather than handed to `Image(_:)` blind: a missing
        // asset renders as a blank square with a console warning, and the whole
        // point of the fallback is that a tile with no art still looks finished.
        let artwork = art.flatMap { UIImage(named: $0) }
        return Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .topLeading) {
                Image(systemName: symbol)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(artwork == nil ? Color.batAccent : .white)
                    .shadow(color: .black.opacity(artwork == nil ? 0 : 0.5), radius: 4)
                    .padding(14)
            }
            .overlay(alignment: .bottom) { tileNameplate(title, subtitle, over: artwork != nil) }
            .glassTile()
    }

    /// The tile's name and line of explanation, in the species card's nameplate
    /// position. Over artwork it is white on a scrim; over bare glass it takes
    /// the page's ink and needs no scrim — a black gradient laid over glass
    /// reads as a smudge rather than as a photo caption.
    private func tileNameplate(_ title: String, _ subtitle: String,
                               over artwork: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .foregroundStyle(artwork ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(artwork ? AnyShapeStyle(.white.opacity(0.85))
                                         : AnyShapeStyle(.secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            if artwork {
                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    // MARK: Attribution

    private var attributionSection: some View {
        DataModelSourcesView()
    }
}

/// One entry per data source OpenBat actually depends on. Classifier models are
/// pulled straight from `ModelRegistry.all` (its `citation`/`sourceURL` are also
/// shown in the model detail screen) so a newly registered model is attributed
/// automatically — no separate list to keep in sync. BatDetect2's CC BY-NC
/// non-commercial licence surfaces here through that same `citation`. GBIF
/// (distribution maps) and Wikipedia (species photos/summaries) are fixed
/// entries since they're general data sources, not classifiers.
///
/// Shared (not private to AppInfoView) so the field guide credits the same
/// sources from its own sheet — see `SpeciesExplorerView`.
struct DataModelSourcesView: View {
    var body: some View {
        // Collapsed by default: every row underneath already carries its own
        // license-text disclosure, so an expanded credits list was two levels
        // of "extra info" showing at once. This outer group hides the whole
        // list behind one disclosure, leaving the per-item dropdowns as they
        // were.
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ModelRegistry.all) { model in
                    licenseRow(name: model.displayName, detail: model.citation, url: model.sourceURL,
                               licenseName: model.licenseName, licenseText: model.licenseNoticeText)
                }
                attributionRow(name: "GBIF",
                               detail: "Species distribution maps use occurrence data from the Global Biodiversity Information Facility (GBIF), licensed CC BY 4.0.",
                               url: URL(string: "https://www.gbif.org"))
                // CC BY-SA 4.0 requires attribution (title, author/source,
                // license). Species description text is written for the field
                // guide itself, cited to its own references (academic papers,
                // conservation bodies) rather than Wikipedia — only photos come
                // from there, so this only credits photos, not text.
                attributionRow(name: "Wikipedia",
                               detail: "Species photos in the field guide are sourced from Wikipedia's open media, licensed CC BY-SA 4.0. Individual photo authorship isn't tracked per-image. Description text is written for the field guide and cited to its own references, not Wikipedia.",
                               url: URL(string: "https://www.wikipedia.org"))

                Divider().padding(.vertical, 4)
                Text("Open Source Software").font(.subheadline.weight(.semibold))

                licenseRow(name: "FLAC", detail: "Recording contribution uses libFLAC for lossless audio encoding.",
                           url: URL(string: "https://github.com/sbooth/flac-binary-xcframework"),
                           licenseName: "BSD 3-Clause", licenseText: Self.xiphBSD3LicenseText(project: "FLAC", years: "2000-2009 Josh Coalson, 2011-2025", holder: "Xiph.Org Foundation"))
                licenseRow(name: "libogg", detail: "Ogg container support, bundled alongside FLAC.",
                           url: URL(string: "https://github.com/sbooth/ogg-binary-xcframework"),
                           licenseName: "BSD 3-Clause", licenseText: Self.xiphBSD3LicenseText(project: "libogg", years: "2002", holder: "Xiph.org Foundation"))
            }
            .padding(.top, 4)
        } label: {
            Text("Data & Model Sources").font(.headline)
        }
    }

    private func attributionRow(name: String, detail: String, url: URL?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                }
            } else {
                Text(name).font(.subheadline.weight(.semibold))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Same as `attributionRow`, plus the actual license text collapsed behind
    /// a disclosure — required to ship the notice to users, not just leave it
    /// in a source comment, without making every OSS credit permanently
    /// full-length on screen.
    private func licenseRow(name: String, detail: String, url: URL?, licenseName: String, licenseText: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let url {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Text(name).font(.subheadline.weight(.semibold))
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption2)
                    }
                }
            } else {
                Text(name).font(.subheadline.weight(.semibold))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("\(licenseName) license text") {
                Text(licenseText)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
            .font(.caption)
        }
    }

    /// Standard Xiph.Org-style BSD 3-Clause text — used verbatim (modulo
    /// project name/copyright line) by both FLAC and libogg.
    private static func xiphBSD3LicenseText(project: String, years: String, holder: String) -> String {
        """
        Copyright (c) \(years) \(holder)

        Redistribution and use in source and binary forms, with or without \
        modification, are permitted provided that the following conditions \
        are met:

        - Redistributions of source code must retain the above copyright \
        notice, this list of conditions and the following disclaimer.

        - Redistributions in binary form must reproduce the above copyright \
        notice, this list of conditions and the following disclaimer in the \
        documentation and/or other materials provided with the distribution.

        - Neither the name of the \(holder) nor the names of its \
        contributors may be used to endorse or promote products derived \
        from this software without specific prior written permission.

        THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \
        "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT \
        LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS \
        FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE \
        FOUNDATION OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, \
        INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES \
        (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR \
        SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) \
        HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, \
        STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) \
        ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED \
        OF THE POSSIBILITY OF SUCH DAMAGE.
        """
    }
}

// MARK: - Guided tour overlay

/// Full-screen dimming overlay with a spotlight cutout over the current step's
/// control and a caption card. Presented via `.overlayPreferenceValue` so it can
/// resolve the tagged controls' bounds. Binding-driven so ContentView owns the
/// step index and dismissal.
struct TourOverlay: View, Equatable {
    let targets: [TourID: CGRect]
    @Binding var index: Int
    let steps: [TourStep]
    /// Ends the tour. The flag says whether it was seen all the way through —
    /// true from the last step's Done, false from "End tour". The host uses it
    /// to decide whether to retire the button that offers the tour, so the two
    /// exits must stay distinguishable here.
    let finish: (_ completed: Bool) -> Void

    /// The detector UI relayouts many times a second while running (stats text,
    /// meters, button tints), and every pass republishes the anchor preferences,
    /// re-invoking the host's overlayPreferenceValue closure. Comparing the
    /// resolved rects + step index lets SwiftUI skip re-diffing this whole
    /// overlay (dim shape, material card, shadow) when nothing visible changed —
    /// paired with .equatable() at the call site.
    static func == (lhs: TourOverlay, rhs: TourOverlay) -> Bool {
        lhs.targets == rhs.targets && lhs.index == rhs.index
    }

    private var step: TourStep { steps[min(index, steps.count - 1)] }
    private var hole: CGRect {
        guard let id = step.target, let r = targets[id] else { return .null }
        return r.insetBy(dx: -6, dy: -6)
    }

    var body: some View {
        GeometryReader { geo in
            let hasHole = !hole.isNull && !hole.isEmpty
            // Steps with no target collapse the cutout to a zero-size rect at screen
            // centre rather than .null — SpotlightShape is animatable, and .null's
            // infinite coordinates interpolate to NaN geometry (flashing dim layer).
            // A degenerate rect instead animates the hole growing/shrinking smoothly.
            let shapeHole = hasHole
                ? hole
                : CGRect(x: geo.size.width / 2, y: geo.size.height / 2, width: 0, height: 0)
            ZStack {
                // Dim everything except the spotlight. No .ignoresSafeArea() here:
                // the host applies it to the whole overlay, so this view, the hole
                // rects, the ring and the caption all share one coordinate space.
                SpotlightShape(hole: shapeHole)
                    .fill(Color.black.opacity(0.82), style: FillStyle(eoFill: true))
                    .contentShape(Rectangle())
                    .onTapGesture { advance() }

                // Ring around the spotlighted control.
                if hasHole {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.9), lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .position(x: hole.midX, y: hole.midY)
                        .allowsHitTesting(false)
                }

                captionLayer(in: geo.size, hasHole: hasHole)
            }
            .animation(.easeInOut(duration: 0.35), value: index)
        }
        .transition(.opacity)
    }

    /// Places the caption card below the hole when it's in the top half of the
    /// screen, above it otherwise, and centred when there's no cutout.
    @ViewBuilder private func captionLayer(in size: CGSize, hasHole: Bool) -> some View {
        if hasHole {
            let below = hole.midY < size.height / 2
            // Clamp the spacer at 0: on a short landscape height (size.height < 200) the
            // `size.height - 200` cap goes negative, which snapped the card to the top/
            // bottom edge. max(0, …) keeps it a valid spacer height.
            VStack(spacing: 0) {
                if below {
                    Color.clear.frame(height: max(0, min(hole.maxY + 16, size.height - 200)))
                    card
                    Spacer(minLength: 0)
                } else {
                    Spacer(minLength: 0)
                    card
                    Color.clear.frame(height: max(0, min(size.height - hole.minY + 16, size.height - 200)))
                }
            }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: step.symbol)
                    .font(.title2)
                    .rotationEffect(step.symbolRotation)
                    .foregroundStyle(Color.batAccent)
                Text(step.title).font(.headline)
                Spacer()
                Text("\(index + 1)/\(steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(step.detail)
                .font(.subheadline)
                .foregroundStyle(.primary.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("End tour") { finish(false) }
                    .foregroundStyle(.secondary)
                Spacer()
                if index > 0 {
                    Button { withAnimation { index -= 1 } } label: {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                            .frame(width: 36, height: 36)
                            .background(Color.chromeFill(0.12), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back")
                }
                Button { advance() } label: {
                    // Checkmark on the last step (the old "Done").
                    Image(systemName: index == steps.count - 1 ? "checkmark" : "chevron.right")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.batAccent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(index == steps.count - 1 ? "Done" : "Next")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(maxWidth: 360)
        // Opaque fill, not a material: a material backdrop-blurs the live
        // spectrogram beneath it every frame, a per-frame GPU cost for the whole
        // tour. Over the 82% black dim an opaque dark grey looks the same.
        // The app's card material, same as everywhere else (Niall, 2026-09-02).
        //
        // Worth knowing what this costs, because it was deliberately opaque
        // before: a material backdrop-blurs whatever is under it every frame,
        // and what is under this is the live spectrogram — through an 82% black
        // dim, so the blur buys almost nothing visually. If the tour ever feels
        // heavy on an older phone, an opaque `Color(.systemGray6)` fill at the
        // same radius is the swap, and it looked near-identical.
        .glassTile()
        .shadow(radius: 20, y: 8)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
    }

    private func advance() {
        if index >= steps.count - 1 { finish(true) }
        else { withAnimation { index += 1 } }
    }
}

/// A full-rect path with an optional rounded-rect hole punched out; fill it with
/// `eoFill: true` to dim everything except the hole.
private struct SpotlightShape: Shape {
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>,
                                       AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(hole.minX, hole.minY), .init(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var p = Path(rect)
        if !hole.isNull && !hole.isEmpty {
            p.addRoundedRect(in: hole, cornerSize: CGSize(width: 14, height: 14))
        }
        return p
    }
}
