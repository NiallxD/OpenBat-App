//
//  AppTabBar.swift
//  OpenBat
//
//  The bottom bar and the session button beside it.
//
//  Two implementations, chosen by OS version, exactly as the ADHD app does it:
//
//    • iOS 26+  — a real `TabView`. Everything that makes the iOS 26 bar look
//      like the iOS 26 bar (the glass and how it samples the spectrogram
//      scrolling under it, the indicator travelling between tabs, the way it
//      hands its height to each screen's safe area) is the system's. The
//      session button is `Tab(role: .search)`, which the system renders as its
//      own detached circle beside the bar rather than as another item inside
//      it — the arrangement the App Store uses, and the only way to get a
//      detached control without giving up the real bar.
//
//    • iOS 18–25 — `LegacyTabBar` below, a hand-built floating bar. There is no
//      Liquid Glass to adopt on those systems and the stock bar is an opaque
//      slab, which over a live spectrogram is worse than a material.
//
//  The session button is not a destination. Selecting it is intercepted in
//  ContentView's `tabSelection` binding and turned into either starting a
//  session or opening `TransportMenu`, so the selection never moves off the
//  section you were on.
//

import SwiftUI

// MARK: - Sections

/// The app's three real destinations. The session button is deliberately not in
/// here — see `TabSelection`.
///
/// There was a fourth, Playback, listing every recording grouped by session —
/// the same recordings Sessions already showed, in the same buckets. It is gone;
/// a recording is opened from Sessions and plays there.
enum AppSection: String, CaseIterable, Hashable {
    case detector  = "Detector"
    case sessions  = "Sessions"
    case species   = "Species"

    /// Where a tab's glyph comes from. Not a bare symbol name any more, because
    /// two of the three are drawn artwork that no SF Symbol approximates. Resolving
    /// one into something drawable is not free, so it happens once — see
    /// `Icon.Resolved`, and use `AppSection.iconImage` / `iconSized(_:)`.
    enum Icon {
        /// An SF Symbol, with a `fallback` used when `name` needs a newer iOS than
        /// the 18.0 deployment target. `Image(systemName:)` does not fail loudly for
        /// a symbol the running system has never heard of — it just draws nothing,
        /// so a tab would silently lose its glyph on an un-updated phone.
        case symbol(String, fallback: String? = nil, since: (major: Int, minor: Int)? = nil)
        /// A template image in the asset catalog, with a symbol to fall back on if
        /// the imageset turns out to have no artwork in it.
        ///
        /// The fallback is not defensive padding: an imageset whose files are
        /// missing is only a *build warning*, and it draws a blank tab rather than
        /// failing, so nothing but this would tell you the artwork had gone.
        ///
        /// **Every custom glyph must be exported to the same intrinsic HEIGHT
        /// (30 pt: 30/60/90 px), never to a fixed width.** The iOS 26 bar sizes a
        /// `Tab` label from the image's own intrinsic size, so `iconSized(_:)` never
        /// runs there and the export IS the size. `batCall` is landscape and was
        /// first exported to a fixed width, which made it 22 pt tall against the
        /// portrait `batBook`'s 30 — visibly the runt of the row, and invisible in
        /// the legacy bar, which normalises height itself.
        case asset(String, fallback: String)
    }

    var icon: Icon {
        switch self {
        case .detector:
            // Drawn artwork: a bat with three call waves coming off it. Replaced
            // `wave.3.up` — itself a replacement for the generic `waveform`, which
            // was also the glyph the session button wears while a session is live,
            // so the bar carried the same shape twice.
            //
            // NOTE this glyph is LANDSCAPE where `batBook` is portrait — see
            // `iconSized(_:)`, which normalises both on height for that reason.
            .asset("batCall", fallback: "wave.3.up")
        case .sessions:
            // A trace on a clipboard: a logged outing, which is what a session is.
            // iOS 18.1, hence the fallback — see `Icon.symbol`.
            .symbol("waveform.path.ecg.text.clipboard",
                    fallback: "list.bullet.clipboard", since: (18, 1))
        case .species:
            // Drawn artwork — a bat over an open book. No SF Symbol says "field
            // guide to bats", and `book.closed` (what this replaces, and what it
            // still falls back to) says only "book".
            .asset("batBook", fallback: "book.closed")
        }
    }
}

extension AppSection.Icon {
    /// Everything a bar needs to draw a glyph, worked out ONCE.
    ///
    /// **This is resolved eagerly and cached on purpose.** Deciding what to draw
    /// costs a `UIImage(named:)` (for the asset case) or a
    /// `ProcessInfo.isOperatingSystemAtLeast` (for the availability fallback), and
    /// both used to run inside `body` — three image lookups per glyph per layout,
    /// on chrome that is on screen on every tab and re-lays out with the live audio
    /// stats. `isOperatingSystemAtLeast` in particular is not a cheap accessor.
    /// None of it can change while the app runs: the artwork is in the bundle and
    /// the OS version does not move under us.
    struct Resolved {
        let image: Image
        /// A symbol either by choice or because the artwork was missing. The two
        /// kinds size by different means, so the bar has to know which it has.
        let isSymbol: Bool
        /// Width ÷ height of the artwork, 1 for a symbol. Read from the image
        /// rather than hard-coded per case, so a re-export at a different crop
        /// can't silently distort the glyph.
        let aspectRatio: CGFloat
    }

    /// A custom asset is rendered as a template (declared in the imageset, and
    /// asserted here by `.renderingMode`) so both bars can tint it the way they
    /// tint a symbol — the selected/unselected `foregroundStyle` on the legacy bar,
    /// and the system's own tinting above iOS 26.
    private func resolve() -> Resolved {
        switch self {
        case .symbol(let name, let fallback, let since):
            if let fallback, let since,
               !ProcessInfo.processInfo.isOperatingSystemAtLeast(
                    OperatingSystemVersion(majorVersion: since.major,
                                           minorVersion: since.minor, patchVersion: 0)) {
                return Resolved(image: Image(systemName: fallback), isSymbol: true, aspectRatio: 1)
            }
            return Resolved(image: Image(systemName: name), isSymbol: true, aspectRatio: 1)
        case .asset(let name, let fallback):
            guard let art = UIImage(named: name), art.size.height > 0 else {
                return Resolved(image: Image(systemName: fallback), isSymbol: true, aspectRatio: 1)
            }
            return Resolved(image: Image(name).renderingMode(.template), isSymbol: false,
                            aspectRatio: art.size.width / art.size.height)
        }
    }

    /// The cache. Keyed by section rather than by `Icon` so the enum needs no
    /// `Hashable` conformance (its `since` tuple has none), and built in one pass
    /// at first use.
    private static let cache: [AppSection: Resolved] = Dictionary(
        uniqueKeysWithValues: AppSection.allCases.map { ($0, $0.icon.resolve()) })

    static func resolved(for section: AppSection) -> Resolved {
        // The fallback can only be reached by a section whose icon is not in
        // `allCases`, which cannot happen — but resolving on the spot is a better
        // answer than a crash if that ever changes.
        cache[section] ?? section.icon.resolve()
    }
}

extension AppSection {
    /// The glyph as an `Image`, for a host that does its own sizing — the iOS 26
    /// bar sizes a `Tab` label itself.
    var iconImage: Image { AppSection.Icon.resolved(for: self).image }

    /// Sized for a hand-built bar. The two kinds size by different means and
    /// neither works on the other: a symbol takes its size from `font` and would
    /// ignore a frame (overflowing it, since `frame` doesn't clip), while an
    /// asset carries its own pixel dimensions and ignores `font` entirely.
    @ViewBuilder func iconSized(_ points: CGFloat) -> some View {
        let resolved = AppSection.Icon.resolved(for: self)
        if resolved.isSymbol {
            resolved.image.font(.system(size: points, weight: .regular))
        } else {
            // **Height-normalised, with the width derived from the artwork's own
            // aspect** — not fitted into a square box. The two custom glyphs have
            // opposite orientations (`batBook` portrait, `batCall` landscape), and
            // a square box binds a landscape glyph on WIDTH, which drew the bat
            // call around three-quarters the height of everything beside it.
            // Matching heights is what makes a row of glyphs read as one set.
            //
            // The point size is used as-is rather than enlarged: a symbol carries
            // optical padding inside its own box, and both exports bake in an
            // equivalent transparent margin (the masters bleed to every canvas
            // edge), so adding more here would make the artwork the heaviest thing
            // in the bar.
            resolved.image.resizable()
                .frame(width: points * resolved.aspectRatio, height: points)
        }
    }
}

/// What the `TabView`'s selection can hold. A `Tab` needs a value and every tab
/// in a `TabView` has to share one type, so the session button needs a case —
/// but it is never actually stored as the selection, which is what keeps it
/// from being a destination.
enum TabSelection: Hashable {
    case section(AppSection)
    case sessionControl
}

// MARK: - Metrics

/// Geometry shared between the session button, the transport menu and the
/// legacy bar, so the three stay aligned as one arrangement.
enum SessionButtonMetrics {
    /// Shared height of the session button and the bar beside it, so the two
    /// read as one row. Comfortably above the 44pt minimum — this gets hit in
    /// the dark, one-handed, often without being looked at.
    static let diameter: CGFloat = 58
    /// Space between the bar and the session button.
    static let gap: CGFloat = 10
    /// Inset of the whole row from the screen edges.
    static let horizontalPadding: CGFloat = 16
    /// How far the row floats above the bottom safe area.
    static let bottomPadding: CGFloat = 8

    // Nothing here describes where the *system* draws the session button on
    // iOS 26, and nothing should. Three hand-measured constants used to: they
    // were wrong twice on iPhone before they were right, they could not
    // describe iPad at all — where the bar is a centred pill at the top with
    // the button inside it — and the iPhone numbers put an invisible tap
    // catcher on the Settings gear there. `SessionButtonLocator` asks the view
    // hierarchy instead, which is right on every device and every orientation
    // without a parameter per device. The metrics above still stand: they
    // describe the bar *we* build, below iOS 26.

    /// Reserved bottom space so scroll content can clear the row entirely.
    ///
    /// Zero from iOS 26, where the bar is the system's: a real tab bar already
    /// contributes its own height to every screen's bottom safe area, and
    /// adding this on top reserves the space twice — a visible band of dead
    /// scroll under the last row.
    static var clearance: CGFloat {
        if #available(iOS 26.0, *) { 0 } else { diameter + bottomPadding + 12 }
    }
}

enum TransportMenuMetrics {
    /// Narrowest the menu may be drawn. It matches the width of the button it
    /// grows out of, but not below this: every item carries a caption, and
    /// captions are not decoration here — four listening states hide behind one
    /// glyph (see `ContentView.listenIcon`), and this menu is where the user
    /// chooses between them, so an icon alone would ask them to remember which
    /// tortoise is which. This is what "Record" needs at the caption's size.
    ///
    /// It only binds on iPad, where the button measures ~36pt; on iPhone the
    /// button is wider than this and the menu simply matches it.
    static let minimumWidth: CGFloat = 54
    static let itemHeight: CGFloat = 56
    /// Space between the menu and the session button it grows out of.
    static let gap: CGFloat = 10
}

/// Which way the transport menu opens. The system puts the tab bar at the
/// bottom of the window on iPhone and at the top on iPad, so the menu has to
/// grow away from the bar in each case rather than off the screen.
enum TransportMenuPlacement {
    case above
    case below
}

// MARK: - Session button

/// The detached circle beside the bar: start a session, then open the transport
/// menu.
///
/// Three states, because it is three things in sequence:
///   • idle          — a record glyph, red. It starts a session, and with
///                     auto-record on (the default) that does start recording,
///                     so the glyph is not a lie.
///   • session live  — the listening-ear animation, orange. The same "we are
///                     live" idiom the old play/stop button used.
///   • menu open     — a close glyph, orange, so the second tap has somewhere
///                     obvious to undo itself.
struct SessionButton: View {
    let isSessionActive: Bool
    let isMenuOpen: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon
                .frame(width: SessionButtonMetrics.diameter,
                       height: SessionButtonMetrics.diameter)
                .liquidGlass(tinted: tint, interactive: true, in: .circle)
                .overlay { Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .tourTarget(.start)
    }

    @ViewBuilder private var icon: some View {
        if isMenuOpen {
            Image(systemName: "xmark")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
        } else if isSessionActive {
            ListeningEarIcon(isListening: true, size: 26)
        } else {
            Image(systemName: "record.circle")
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.white)
        }
    }

    /// Orange while a session runs, red when idle and offering to start one —
    /// the same pairing the iOS 26 button attempts on its glyph, so the two
    /// bars say the same thing wherever the system lets them.
    ///
    /// Here the colour is ours outright: this button is drawn by us, not by a
    /// tab bar, so unlike `ContentView.sessionSymbolTint` it always lands.
    private var tint: Color {
        isSessionActive ? .batAccent : .red
    }

    private var accessibilityLabel: String {
        if isMenuOpen { return "Close session controls" }
        return isSessionActive ? "Session controls" : "Start session"
    }
}

// MARK: - Transport menu

/// The vertical stack that replaces the old control bar: record, listen mode,
/// end session. Same construction as a tab-bar item (glyph over caption) turned
/// on its side, so it reads as the bar's own vocabulary rather than a popover
/// borrowed from somewhere else.
///
/// Only reachable while a session is running, which is why there is no "start"
/// item in it — starting is the button this grows out of.
struct TransportMenu: View {
    let recorder: AudioRecorder
    /// Matched to the session button this grows out of, floored at
    /// `TransportMenuMetrics.minimumWidth` so the captions still fit.
    let width: CGFloat
    /// Precomputed by ContentView, which owns both halves of the listen state
    /// (the engine's mode and the snippet routing) — see `advanceListenMode`.
    let listenIcon: String
    let listenName: String
    let isListening: Bool
    let onToggleRecord: () -> Void
    let onCycleListen: () -> Void
    let onEndSession: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TransportMenuRecordItem(recorder: recorder, action: onToggleRecord)

            divider

            TransportMenuItem(
                symbol: listenIcon,
                caption: "Listen",
                tint: isListening ? .toggleOn : .toggleOff,
                accessibilityLabel: "Listening mode: \(listenName)",
                action: onCycleListen
            )
            .tourTarget(.listen)
            // The glyph swaps between four symbols of different widths; without
            // this the swap animates its own geometry independently of the
            // item's chrome. Same fix, same reason as the old control bar's.
            .geometryGroup()

            divider

            TransportMenuItem(
                symbol: "stop.circle",
                caption: "End",
                tint: .red,
                accessibilityLabel: "End session",
                action: onEndSession
            )
        }
        .frame(width: width)
        .liquidGlass(in: .rect(cornerRadius: width / 2))
        .overlay {
            RoundedRectangle(cornerRadius: width / 2)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        // The whole menu as one target, alongside the per-item ones above. The
        // simplified tour introduces the three controls in a single step rather
        // than three, so it needs to spotlight the group; the advanced tour
        // still takes them one at a time.
        .tourTarget(.transportMenu)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.10))
            .frame(height: 1)
            .padding(.horizontal, 12)
    }
}

/// One row of the transport menu. Kept deliberately dumb — anything that reads
/// high-churn recorder state gets its own struct (see below) so the churn can't
/// invalidate the whole menu.
struct TransportMenuItem<Glyph: View>: View {
    let caption: String
    let tint: Color
    let accessibilityLabel: String
    let action: () -> Void
    @ViewBuilder let glyph: Glyph

    init(symbol: String,
         caption: String,
         tint: Color,
         accessibilityLabel: String,
         action: @escaping () -> Void) where Glyph == Image {
        self.caption = caption
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.glyph = Image(systemName: symbol)
    }

    init(caption: String,
         tint: Color,
         accessibilityLabel: String,
         action: @escaping () -> Void,
         @ViewBuilder glyph: () -> Glyph) {
        self.caption = caption
        self.tint = tint
        self.accessibilityLabel = accessibilityLabel
        self.action = action
        self.glyph = glyph()
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                glyph
                    .font(.system(size: 19, weight: .regular))
                    .frame(height: 22)
                Text(caption)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: TransportMenuMetrics.itemHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

/// The record row. A standalone `View` struct, not a row built inline in
/// `TransportMenu` — `recorder.isWriting` flips on every WAV pass open/close
/// during active detection, and reading it in the menu's own body would
/// invalidate the whole menu at that rate. Same rule as Context.md §13.
struct TransportMenuRecordItem: View {
    let recorder: AudioRecorder
    let action: () -> Void
    @State private var pulseBright = false

    var body: some View {
        TransportMenuItem(
            caption: "Record",
            tint: recorder.isArmed ? .red : .toggleOff,
            accessibilityLabel: recorder.isArmed ? "Stop recording" : "Record",
            action: action
        ) {
            Image(systemName: "record.circle")
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    RecordButtonTone.ring(armed: recorder.isArmed,
                                          writing: recorder.isWriting,
                                          pulseBright: pulseBright),
                    RecordButtonTone.dot(armed: recorder.isArmed,
                                         writing: recorder.isWriting)
                )
                .animation(recordPulseAnimation(armed: recorder.isArmed,
                                                writing: recorder.isWriting),
                           value: pulseBright)
                // See `recordPulseAnimation`'s note on containment — a
                // repeatForever animation stays live on the view forever and
                // will pick up any later geometry change unless it is grouped.
                .geometryGroup()
        }
        .disabled(recorder.isBlocked)
        // `.disabled` alone is not a visible state here: the glyph is already
        // dim when idle, so a blocked button looked exactly like a working one
        // and tapping it did nothing, with no explanation.
        .opacity(recorder.isBlocked ? 0.35 : 1)
        .accessibilityHint(recorder.isBlocked ? "Unavailable during a demo" : "")
        .tourTarget(.record)
        .onAppear { syncRecordPulse(armed: recorder.isArmed, writing: recorder.isWriting, pulseBright: $pulseBright) }
        .onChange(of: recorder.isArmed) { _, armed in
            syncRecordPulse(armed: armed, writing: recorder.isWriting, pulseBright: $pulseBright)
        }
        .onChange(of: recorder.isWriting) { _, writing in
            syncRecordPulse(armed: recorder.isArmed, writing: writing, pulseBright: $pulseBright)
        }
    }
}

// MARK: - Recording glow

/// The pulsing light behind the session button while the recorder is armed —
/// breathing while armed and waiting, steady once a segment is actually being
/// written. Same two states, from the same helpers, as the record glyph in the
/// transport menu, so the two can never drift out of step.
///
/// **This sits in the content layer, underneath the bar, and that is the whole
/// design.** It is a plain soft disc: no mask, no ring, no cut-out. The bar's
/// Liquid Glass is over it and does the rest — occluding it, refracting it,
/// picking up its colour the same way it picks up the spectrogram scrolling
/// under it. What you see is the button itself glowing.
///
/// The first version was an overlay *on top* of the bar with the button's
/// footprint punched out of it, faking the occlusion. It read as a ring stuck
/// to the screen rather than a lit button, and every problem it had — a square
/// halo from a mask that clipped the blur, a bright crescent wherever the
/// punched hole missed the button's real position by a point or two — came from
/// re-implementing by hand what the glass does for free.
///
/// **It is also the one part of this button that can move.** On iOS 26 the
/// button is a `Tab` label, which the bar renders as a still image — no symbol
/// effect inside it ever runs (see `ContentView.sessionGlyph`). Anything that
/// needs to animate has to live out here, under the glass.
struct SessionGlow: View {
    let audio: AudioEngineController
    let recorder: AudioRecorder
    /// The button's real, measured size — the glow matches it rather than
    /// assuming `SessionButtonMetrics.diameter`, because the system draws that
    /// button at whatever size it likes and it is not the same on every idiom.
    let buttonSize: CGSize
    @State private var pulseBright = false

    /// The session accent, matching the waveform glyph inside the button, so
    /// the two read as one object breathing rather than as a light of one
    /// colour behind a glyph of another.
    private let glowColor = Color.batAccent

    var body: some View {
        // Sized to the button itself, not wider. The glass spreads and softens
        // whatever is under it, so a disc any bigger than the button stops
        // reading as the button glowing and starts reading as a cloud sitting
        // behind the bar — which is what the first attempt looked like.
        Circle()
            .fill(glowColor)
            .frame(width: buttonSize.width, height: buttonSize.height)
            .blur(radius: 8)
            .opacity(opacity)
            // Only opacity is animated, deliberately. A `repeatForever`
            // animation stays live on its view forever and picks up any later
            // change to that view's resolved *geometry* — which is how the
            // record button once slid diagonally out of the row and back, for
            // the rest of the run (see `recordPulseAnimation`). An opacity-only
            // pulse has no geometry for the repeat to catch hold of.
            .animation(recordPulseAnimation(listening: audio.isActive,
                                            writing: recorder.isWriting),
                       value: pulseBright)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { syncRecordPulse(listening: audio.isActive, writing: recorder.isWriting, pulseBright: $pulseBright) }
            .onChange(of: audio.isActive) { _, listening in
                syncRecordPulse(listening: listening, writing: recorder.isWriting, pulseBright: $pulseBright)
            }
            .onChange(of: recorder.isWriting) { _, writing in
                syncRecordPulse(listening: audio.isActive, writing: writing, pulseBright: $pulseBright)
            }
    }

    /// Steady and bright while a segment is open, breathing while listening
    /// and not currently writing — the same reading as the record glyph's
    /// ring, so a glance at either tells you the same thing. Deliberately not
    /// keyed on `recorder.isArmed`: this glow says "the session is live," and
    /// listening can run with recording stopped, so it must keep breathing
    /// through that state rather than going dark.
    private var opacity: Double {
        if recorder.isWriting { return 0.85 }
        return pulseBright ? 0.7 : 0.18
    }
}

// MARK: - Record button colour + pulse

/// Ring/dot colour math for the record glyph. The two layers of `record.circle`
/// (outer ring, inner dot — palette-rendered, not the single flat tint the
/// plain glyph gets by default) swap which one is "faded" depending on state:
/// armed-and-waiting pulses the ring between faded and full red (using the
/// dot's own resting colour as the pulse's peak), so the static dot reads as
/// the reference tone the ring is breathing towards. Once a detection actually
/// opens a WAV segment, the ring settles solid at that same full red and the
/// dot flips to faded instead, for contrast against the now-solid ring.
/// Disarmed uses `.secondary` for both.
enum RecordButtonTone {
    static let faded = Color.red.opacity(0.35)

    static func ring(armed: Bool, writing: Bool, pulseBright: Bool) -> Color {
        guard armed else { return .secondary }
        if writing { return .red }
        return pulseBright ? .red : faded
    }

    static func dot(armed: Bool, writing: Bool) -> Color {
        guard armed else { return .secondary }
        return writing ? faded : .red
    }
}

/// Starts/stops the ring's breathing pulse to match armed/writing state — active
/// only while armed and waiting (not yet writing); frozen (no visible jump, since
/// `RecordButtonTone.ring` ignores `pulseBright` whenever `writing` is true) once
/// a segment opens, and restarts when it closes but the recorder is still armed.
///
/// Sets the flag with NO animation of its own. The repeating animation is attached
/// to the glyph itself via `.animation(_:value:)` (see `recordPulseAnimation`) —
/// it must NOT be started with `withAnimation`, for the reason documented there.
func syncRecordPulse(armed: Bool, writing: Bool, pulseBright: Binding<Bool>) {
    pulseBright.wrappedValue = armed && !writing
}

/// Same shape as `syncRecordPulse`, for `SessionGlow`: active while listening
/// and not currently writing a segment, so the glow keeps breathing through
/// "recording stopped, still listening" instead of going dark — see the note
/// on `SessionGlow.opacity`.
func syncRecordPulse(listening: Bool, writing: Bool, pulseBright: Binding<Bool>) {
    pulseBright.wrappedValue = listening && !writing
}

/// The pulse's animation, applied to the record glyph's own subtree.
///
/// This deliberately isn't a `withAnimation(.repeatForever(autoreverses: true))`
/// wrapped around the state change. `withAnimation` installs its animation on the
/// WHOLE current transaction, so every other view that happens to change in that
/// same update cycle inherits it too — and an inherited `repeatForever` +
/// `autoreverses` has nothing to end it, so whatever caught it oscillates for the
/// rest of the run. That's what put the nav-bar Menu buttons into a permanent slow
/// throb while detecting: `syncRecordPulse` fires on every `isArmed`/`isWriting`
/// flip, i.e. on every WAV pass opened by a passing bat, and the toolbar's Liquid
/// Glass chrome re-lays-out constantly, so sooner or later a toolbar update lands
/// in the same transaction as one of those flips and latches the repeat. Scoping
/// the animation here means the transaction never carries it.
///
/// **Scoping alone is not enough, and the glyph needs `.geometryGroup()` too.**
/// A scoped `.animation(_:value:)` carrying `repeatForever(autoreverses:)` stays
/// ACTIVE on that view forever once started — it does not only animate the
/// `value:` it was keyed to. So every later change to the glyph's resolved
/// geometry was picked up by that repeat as well, and the record button slid
/// diagonally out of the row and back, forever. `.geometryGroup()` makes the
/// glyph take its position from the parent's unanimated transaction as a rigid
/// unit, so the repeat can only reach the palette colours, which is all it was
/// ever for. Same failure and same fix as the mic pill's rate label — see
/// `MicStatusPillContent` in LiveStatusViews.swift.
func recordPulseAnimation(armed: Bool, writing: Bool) -> Animation {
    armed && !writing
        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        : .easeInOut(duration: 0.2)
}

/// Same shape as `recordPulseAnimation(armed:writing:)`, for `SessionGlow` —
/// see `syncRecordPulse(listening:writing:pulseBright:)` for why this is keyed
/// on listening rather than armed.
func recordPulseAnimation(listening: Bool, writing: Bool) -> Animation {
    listening && !writing
        ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
        : .easeInOut(duration: 0.2)
}

// MARK: - Legacy bar (iOS 18–25)

/// The pre-26 bar: a hand-built floating glass capsule with the session button
/// beside it. Only ever mounted below iOS 26 — above it, the system's own bar
/// does this job.
struct LegacyTabBar: View {
    @Binding var selection: AppSection

    /// Shared by the selection highlight across all tabs so it *travels* from one
    /// to the next rather than fading out and in. The same element moving is
    /// what the system bar does, and it is most of why that bar feels liquid.
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppSection.allCases, id: \.self) { tab in
                let isSelected = tab == selection
                Button {
                    // The travel is driven by this animation. Without an
                    // explicit `withAnimation` the highlight teleports.
                    withAnimation(.bouncy(duration: 0.4)) { selection = tab }
                } label: {
                    VStack(spacing: 2) {
                        tab.iconSized(18)
                        Text(tab.rawValue)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    // The padding here is the indicator's inset: the highlight
                    // wraps the padded label, so these numbers are the margin
                    // of bare glass left showing around it. The system bar
                    // leaves exactly that margin, and it is what makes the
                    // indicator read as a separate object riding on the bar
                    // rather than the bar being repainted in sections.
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(.white.opacity(0.14))
                                .matchedGeometryEffect(id: "tabSelection", in: selectionNamespace)
                        }
                    }
                    // Applied *after* the background on purpose. The indicator
                    // hugs its label — a capsule stretched across the full
                    // quarter of the bar is the giveaway that this isn't a
                    // system bar — while the tap target still fills the slot.
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: SessionButtonMetrics.diameter)
        .liquidGlass(in: .capsule)
        // Untinted glass over a dark spectrogram has no edge of its own, and
        // the bar dissolves into the image at its ends without this.
        .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
    }
}
