//
//  LiveStatusViews.swift
//  OpenBat
//
//  The always-on-screen status leaf views: the heterodyne tuning pill, the
//  mic-connection pill, and the amplitude meters — extracted from ContentView
//  once it passed 1900 lines. Each is a standalone View struct (not a
//  ContentView computed property) because the properties it reads update at
//  ~15 Hz; scoping the reads to a small leaf body keeps that churn from
//  invalidating all of ContentView.body — see the @Observable-churn note in
//  Context.md §13.
//

import SwiftUI

/// Shared sizing for the stats-header status pills (session status, mic status,
/// speaker-feedback warning) and the circular reset button beside them, so they
/// render at a consistent height regardless of each one's own icon/text content —
/// left to their own padding, the reset button's uniform 6pt padding around an
/// 11pt icon came out visibly taller than the pills' 7h/4v padding around a
/// 10pt icon + 9pt text.
enum StatusPillMetrics {
    static let height: CGFloat = 26
}

// MARK: - Heterodyne tuning pill

/// Draggable pill showing the heterodyne LO frequency. A standalone View struct:
/// `audio.tunedFrequency`/`isAutoTune` update at 15 Hz (the same stats timer that
/// drives the amplitude meter) while heterodyne listening is active, so this keeps
/// that churn from invalidating all of ContentView.body. Owns its own drag-gesture
/// state instead of borrowing @State from the parent.
struct TunedPillView: View {
    let audio: AudioEngineController
    let nyquist: Double

    @State private var dragBaseFrequency: Double?
    @State private var dragBaseHeight: CGFloat = 0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: audio.isAutoTune ? "a.circle.fill" : "hand.draw.fill")
                .font(.system(size: 11))
            Text(audio.tunedFrequency > 0
                 ? String(format: "%.1f kHz", audio.tunedFrequency / 1000)
                 : "tuning…")
                .font(.caption.monospacedDigit())
                // FIXED width, or the capsule resizes continuously and appears to
                // whizz about. `monospacedDigit` equalises digit widths but not the
                // character COUNT: "8.5 kHz", "48.3 kHz" and "123.4 kHz" are 7, 8
                // and 9 characters, and the auto-tuner slews the LO at ~15 Hz.
                // "tuning…" (shown whenever the squelch closes between passes) is a
                // bigger jump again. Sized for the widest real value at 192 kHz
                // Nyquist; `lineLimit` keeps a surprise from wrapping.
                .frame(width: 62, alignment: .leading)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(audio.isAutoTune ? .green : .orange)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
        .gesture(tuneGesture)
    }

    private var tuneGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dy = value.translation.height
                if dragBaseFrequency == nil {
                    guard abs(dy) > 6 else { return }
                    dragBaseFrequency = audio.tunedFrequency > 0 ? audio.tunedFrequency : nyquist * 0.25
                    dragBaseHeight = dy
                }
                guard let base = dragBaseFrequency else { return }
                let hzPerPoint = max(nyquist / 500, 50)
                audio.setManualTune(frequency: base - Double(dy - dragBaseHeight) * hzPerPoint)
            }
            .onEnded { _ in
                if dragBaseFrequency == nil { audio.enableAutoTune() }
                dragBaseFrequency = nil
            }
    }
}

// MARK: - Session status pill

/// Small always-visible indicator of what a currently-detecting run is: a logged
/// "Session", a bare "Listening" bucket (which now only the demo uses), or "Off"
/// when nothing is running — shown beside `MicStatusPill`. A standalone View struct for the same
/// reason as the other status pills — `audio.isRunning`/`classStore.activeSessionID`
/// are stored properties on churning `@Observable` objects, so scoping the read here
/// keeps it from invalidating ContentView.body (see the @Observable-churn note in
/// Context.md §13).
struct SessionStatusPillView: View {
    let audio: AudioEngineController
    let classStore: ClassificationStore
    /// Set while the guided tour is running: forces the pill to read
    /// "Listening" instead of "Off", since the tour is usually taken before
    /// the user ever starts detection. See `SessionTimerPill.tourDemo`.
    var tourDemo: Bool = false
    /// Leaves demo mode. **This pill is the badge Info & Tour tells the user to
    /// end the demo from** ("End it from the Demo badge on the detector"), and
    /// for a while that instruction was wrong: the exit was built on the mic
    /// pill next door, so the one thing on screen actually reading "Demo" did
    /// nothing when tapped. Both doors are kept — see `MicStatusExplainer`,
    /// which explains why the pill is the right home for this.
    ///
    /// Optional because not every host has a demo to end: the tour's stand-in
    /// pill passes nothing, and a pill with no handler stays inert rather than
    /// offering a button that can't work.
    var onEndDemo: (() -> Void)? = nil

    @State private var showDemoExit = false

    private var isRunning: Bool { tourDemo || audio.isRunning }
    private var isSession: Bool { audio.isRunning && classStore.activeSessionID != nil }
    /// Shown whenever demo mode is armed, running or not — the whole point is
    /// that nobody mistakes a file feed for live audio, and a paused demo is
    /// still not the microphone.
    private var isDemo: Bool { audio.isDemoMode }

    private var icon: String {
        if isDemo { return "play.rectangle.fill" }
        guard isRunning else { return "pause.circle" }
        return isSession ? "location.fill" : "ear"
    }

    private var label: String {
        if isDemo { return "Demo" }
        guard isRunning else { return "Off" }
        return isSession ? "Session" : "Listening"
    }

    private var tint: Color {
        if isDemo { return .orange }
        return isRunning ? .toggleOn : .secondary
    }

    @ViewBuilder var body: some View {
        // Only a button while there is a demo to end — outside demo mode this
        // pill is a readout with nothing to say when tapped, and a button that
        // opens nothing is worse than plain text.
        if isDemo, let onEndDemo {
            Button { showDemoExit = true } label: { pill }
                .buttonStyle(.plain)
                .popover(isPresented: $showDemoExit) {
                    DemoExitPopover(audio: audio) {
                        // Dismissed before the teardown for the same reason as
                        // the mic pill's copy of this button: ending a demo
                        // relays out the anchor underneath the popover.
                        showDemoExit = false
                        onEndDemo()
                    }
                    .presentationCompactAdaptation(.popover)
                }
        } else {
            pill
        }
    }

    private var pill: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: StatusPillMetrics.height)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if isDemo { return "Demo mode, audio from a file" }
        guard isRunning else { return "Not detecting" }
        return isSession ? "Recording a session" : "Listening, not in a session"
    }
}

/// What tapping the Demo badge opens: what a demo is, and the way out of it.
/// Deliberately shorter than `MicStatusExplainer`'s demo case — that one has to
/// explain why the *microphone* pill looks the way it does during a demo, while
/// this one is opened by a badge that already says "Demo".
private struct DemoExitPopover: View {
    let audio: AudioEngineController
    let onEndDemo: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Demo mode").font(.subheadline.weight(.semibold))
            Text("Audio is coming from \(audio.demoFileName ?? "a recording") instead of the microphone, through the same detection pipeline as a live capture. Recording is disabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button(role: .destructive, action: onEndDemo) {
                Label("End demo", systemImage: "stop.circle")
                    .font(.caption)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.top, 2)

            Text("Returns to the microphone. It does not start detecting.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}

// MARK: - Session timer pill

/// Elapsed-time readout for the active listening/session, shown as a small pill
/// in the spectrogram panel header. Renders nothing until `start` is set (i.e.
/// detection is actually running). A standalone View with its own
/// `TimelineView(.periodic)` tick so the once-a-second clock update stays
/// confined here and never invalidates `ContentView.body` — same scoping
/// rationale as the other status pills.
struct SessionTimerPill: View {
    /// When the current listening/session began; nil when not detecting.
    let start: Date?
    /// Set while the guided tour is running: forces the pill on with a stand-in
    /// elapsed time so the tour has something to spotlight even when detection
    /// isn't running (the tour is usually taken before the user ever starts).
    var tourDemo: Bool = false

    /// Fake start used only for `tourDemo`, seeded a couple of minutes back so
    /// the readout shows a plausible running clock rather than 0:00.
    @State private var demoStart = Date().addingTimeInterval(-125)

    var body: some View {
        if let start = start ?? (tourDemo ? demoStart : nil) {
            // Anchor the schedule to `start` so ticks land on whole elapsed
            // seconds, and read `context.date` (not Date()) so the label is
            // consistent with the schedule that woke it.
            TimelineView(.periodic(from: start, by: 1)) { context in
                let elapsed = max(0, context.date.timeIntervalSince(start))
                HStack(spacing: 4) {
                    Image(systemName: "timer")
                        .font(.system(size: 10, weight: .semibold))
                    Text(Self.timeString(elapsed))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
                // Hold intrinsic width so the elapsed digits can't be squeezed
                // to nothing (leaving just the icon) when the header row is
                // tight on a narrow iPhone — the whole point of the pill is the
                // number, so it wins the layout over compressing away.
                .fixedSize()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: StatusPillMetrics.height)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityLabel("Session running for \(Self.timeString(elapsed))")
            }
        }
    }

    /// h:mm:ss once past an hour, m:ss otherwise.
    static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Speaker feedback warning pill

/// Warns when heterodyne/time-expansion is playing out the built-in speaker: the mic picks
/// the playback back up acoustically and reprocesses it as a spurious low-pitch
/// "call" layered on the real one (confirmed fixed by wearing headphones — there's
/// no clean software fix for the acoustic coupling itself). Only shown while
/// audio is actually running out of the speaker, so it doesn't nag when capture
/// is stopped or headphones are already in. Same standalone-View-struct scoping as the other
/// status pills (`audio.isOutputOnSpeaker`/`listenMode` are on the churning
/// AudioEngineController).
struct SpeakerFeedbackWarningPill: View {
    let audio: AudioEngineController
    /// Set while the guided tour is running: forces the warning on so the tour
    /// can spotlight it without the user actually being in the speaker-feedback
    /// situation. See `SessionTimerPill.tourDemo`.
    var tourDemo: Bool = false
    @State private var showExplainer = false

    var body: some View {
        // `isRunning` matters as much as the other two: `listenMode` defaults to
        // `.heterodyne`, so `isListening` is true from construction, and the
        // speaker is the route on any phone without headphones in. Without this
        // the warning was up the moment the Detector appeared — before capture
        // had started and before a sample had been played — which is the state
        // the app now sits in on launch.
        if tourDemo || (audio.isRunning && audio.isListening && audio.isOutputOnSpeaker) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.yellow)
                .frame(width: StatusPillMetrics.height, height: StatusPillMetrics.height)
                .background(.ultraThinMaterial, in: Circle())
                .contentShape(Circle())
                .onTapGesture { showExplainer = true }
                .popover(isPresented: $showExplainer) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Feedback risk").font(.subheadline.weight(.semibold))
                        Text("When listening through the phone speaker OpenBat's sound output may be picked up by the mic, showing as a second, lower-pitched call. Wear headphones or move the mic away from the phone to avoid it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(width: 240, alignment: .leading)
                    .presentationCompactAdaptation(.popover)
                }
                .accessibilityLabel("Feedback risk: listening through the speaker")
                .accessibilityHint("Tap for details")
        }
    }
}

// MARK: - Mic status pill

/// External-mic connection indicator: a green connector icon that slowly pulses
/// while a USB mic (the Griff) is attached, or a red slashed connector when only
/// the built-in mic is available. While capturing, also shows the delivered feed
/// rate in kHz, flashing red if iOS hands us less than the required 384 kHz.
/// Tapping opens a popover explaining the current state — the red flash on its
/// own says "something's wrong" without saying what or what to do about it.
/// Required feed rate shared by the pill content and its explainer.
private let micStatusRequiredRate: Double = 384_000

struct MicStatusPill: View {
    let audio: AudioEngineController
    /// Leaves demo mode. Handed down to the explainer, which is where the only
    /// user-facing way out of a demo lives — see `MicStatusExplainer`.
    let onEndDemo: () -> Void
    @State private var showExplainer = false

    var body: some View {
        // The Button and its popover sit OUTSIDE MicStatusPillContent on purpose —
        // same reasoning as SpeakerFeedbackWarningPill above: `audio.diagnostics`
        // churns at 15 Hz (AudioEngineController.flushStats), and a presenter that
        // rebuilds that fast can drop its own popover/tap mid-gesture. Only the leaf
        // content (icon + rate text) reads diagnostics; this body doesn't.
        Button { showExplainer = true } label: { MicStatusPillContent(audio: audio) }
            .buttonStyle(.plain)
            .popover(isPresented: $showExplainer) {
                MicStatusExplainer(audio: audio, onEndDemo: onEndDemo)
                    .presentationCompactAdaptation(.popover)
            }
    }
}

private struct MicStatusPillContent: View {
    let audio: AudioEngineController
    @State private var slowPulse = false   // ~1.4 s breathe for the connected icon
    @State private var fastFlash = false   // ~0.4 s blink for a clamped feed rate

    var body: some View {
        let d = audio.diagnostics
        let demo = audio.isDemoMode
        let connected = d.usbMicAvailable
        // No mic is attached during a demo and none needs to be, so suppress
        // both alarms: the red "no ultrasonic mic" slash, and the clamped-rate
        // flash for a demo clip recorded below 384 kHz. Neither is a fault the
        // user can act on, and the Demo pill beside this one already says why.
        // isActive so the rate label doesn't blink out for the length of a
        // listen-mode restart — see AudioEngineController.isActive.
        let rateKnown = audio.isActive && d.actualSampleRate > 0
        let rateBad = !demo && rateKnown && d.actualSampleRate < micStatusRequiredRate
        // Computed here rather than inline so it can be the `value:` of its own
        // scoped `.animation` below — see the onAppear comment.
        let iconFaded = !demo && connected && slowPulse
        // What the icon is SAYING, as one value: demo / connected / no mic. Only
        // here so the inner `.animation(nil, value:)` below has something to key
        // on — see the comment under the HStack.
        let iconState = demo ? 2 : (connected ? 1 : 0)
        HStack(spacing: 4) {
            Image(systemName: demo ? "waveform" : (connected ? "cable.connector" : "cable.connector.slash"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(demo ? Color.orange : (connected ? .green : .red))
                .animation(nil, value: iconState)
                .opacity(iconFaded ? 0.35 : 1)
                .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: iconFaded)
                .geometryGroup()
            if rateKnown {
                // Branched rather than a single Text with a `rateFaded`-keyed
                // `.opacity`/`.animation(repeatForever)` pair: a `repeatForever`
                // animation stays live on the view it's attached to forever once
                // started (same mechanism as the icon's colour-cycling bug above),
                // so a single early moment of `rateBad` — before the feed rate
                // settles at launch — left the label oscillating opacity for the
                // rest of the run even after the rate was stable. Branching on
                // `rateBad` gives the pulsing view a different identity than the
                // stable one, so when the rate recovers, SwiftUI tears the whole
                // animated subview down instead of leaving its repeat running.
                if rateBad {
                    Text("\(Int((d.actualSampleRate / 1000).rounded())) kHz")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.red)
                        .opacity(fastFlash ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true), value: fastFlash)
                        .geometryGroup()
                } else {
                    Text("\(Int((d.actualSampleRate / 1000).rounded())) kHz")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        // The two inner `.animation(nil, value:)`s above are the COLOUR half of
        // the same containment, and the fix for the mic icon cycling red↔green
        // for the rest of the run after the Griff was plugged in (2026-08-17).
        // Cause is identical to the geometry bug below: the breathe animation is
        // installed at `onAppear` and stays live on that view forever, so when
        // `connected` later flips and the icon's foreground goes red→green, that
        // colour change is picked up by the still-running autoreversing repeat
        // and interpolates back and forth without end. `.geometryGroup()` doesn't
        // help — it contains position, not colour. An innermost `.animation(nil,
        // value:)` does: it wins over the outer repeat for changes driven by that
        // value, so the state change lands instantly while the repeat keeps
        // reaching `opacity`, which is all it was ever for. Same for the rate
        // label's secondary→red on `rateBad`. Keep the nil animations BELOW the
        // `.opacity` — above it they'd cancel the pulse itself.
        //
        // The two `.geometryGroup()`s above are the fix for the rate label flying
        // left and right across the status row while flashing red. A scoped
        // `.animation(_:value:)` carrying `repeatForever(autoreverses:)` stays
        // ACTIVE on that view forever once started — it doesn't only animate the
        // `value:` it was keyed to. So every later change to the label's resolved
        // geometry got picked up by that repeat too: when a neighbour in the row
        // relaid out (the session timer's text changing width once a second is
        // enough), the label's new x-position became one end of an autoreversing,
        // never-ending interpolation, and it slid back and forth out of its
        // capsule. `.geometryGroup()` makes each leaf take its position from the
        // parent's (unanimated) transaction as a rigid unit, so the repeat can
        // only reach `opacity`, which is all it was ever for.
        .padding(.horizontal, 7)
        .frame(height: StatusPillMetrics.height)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        // Flags flipped with NO animation of their own: the repeating animations are
        // scoped to the two views above instead. Starting a `repeatForever` here with
        // `withAnimation` would install it on the entire current transaction, and any
        // unrelated view updating in that same cycle — this pill sits directly under
        // the nav bar, whose Liquid Glass buttons re-lay-out constantly — inherits an
        // autoreversing repeat with nothing to end it, and throbs forever. Same fix as
        // the record button's pulse; see `RecordPulse` in AppTabBar.
        .onAppear {
            slowPulse = true
            fastFlash = true
        }
        .accessibilityLabel(demo ? "Demo mode, audio from a file"
                                 : (connected ? "External microphone connected" : "No external microphone"))
        .accessibilityHint("Tap for details")
    }
}

/// **Also the way out of demo mode**, which is why it takes `onEndDemo`.
/// Demo used to be started and ended entirely inside the Debug sheet, so the
/// message below could just point there — and once demo moved to Info & Tour
/// (2026-08-31) that instruction named a sheet most users can't see, stranding
/// them in a mode which, by design, never ends on its own.
///
/// The pill is the right home for the exit: it is the thing on screen that says
/// "Demo", so it is what someone taps to ask what that means and how to stop it.
/// The Debug sheet keeps its own End Demo button — two doors into one action,
/// which is fine; the failure mode being avoided is zero doors.
private struct MicStatusExplainer: View {
    let audio: AudioEngineController
    let onEndDemo: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let d = audio.diagnostics
        let connected = d.usbMicAvailable
        // isActive so the rate label doesn't blink out for the length of a
        // listen-mode restart — see AudioEngineController.isActive.
        let rateKnown = audio.isActive && d.actualSampleRate > 0
        let rateBad = rateKnown && d.actualSampleRate < micStatusRequiredRate
        let rate = d.actualSampleRate

        let (title, message): (String, String)
        if audio.isDemoMode {
            title = "Demo mode"
            let name = audio.demoFileName ?? "a recording"
            message = rateKnown
                ? "The microphone is not in use. Audio is coming from \(name), played at \(Int((rate / 1000).rounded())) kHz through the same detection pipeline as a live capture. Recording is disabled."
                : "The microphone is not in use. Audio will come from \(name) instead, through the same detection pipeline as a live capture. Recording is disabled."
        } else if !connected {
            title = "No ultrasonic microphone"
            message = "Only the built-in mic is available, which hears up to about 24 kHz — most bat calls are far above that. Plug in an ultrasonic USB microphone (such as the Griff) to detect bats."
        } else if rateBad {
            title = "Sample rate clamped"
            message = "iOS is delivering audio at \(Int((rate / 1000).rounded())) kHz instead of the mic's native 384 kHz, so sounds above \(Int((rate / 2000).rounded())) kHz are being cut off and many bat calls will be missed or distorted. Try unplugging and reconnecting the microphone, closing other audio apps, then stopping and restarting detection."
        } else if rateKnown {
            title = "Capturing at full rate"
            message = "The microphone is delivering \(Int((rate / 1000).rounded())) kHz, capturing ultrasound up to \(Int((rate / 2000).rounded())) kHz — the full range of bat echolocation."
        } else {
            title = "Microphone connected"
            message = "An ultrasonic USB microphone is attached. Start detecting to confirm iOS delivers its full 384 kHz sample rate — the delivered rate will appear here."
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                // Wrap to as many lines as needed instead of laying out on one line
                // and overflowing the popover — `.fixedSize(vertical)` lets the text
                // grow downward, and the fixed 240-pt content width gives it a real
                // wrapping boundary (a compact popover otherwise sizes to the text's
                // intrinsic single-line width).
                .fixedSize(horizontal: false, vertical: true)

            if audio.isDemoMode {
                // Dismissed first, then the teardown: ending a demo hands the
                // pipeline back to the microphone and churns `audio.diagnostics`,
                // and a popover still open over an anchor that is relaying out
                // can lose the interaction mid-tap.
                Button(role: .destructive) {
                    dismiss()
                    onEndDemo()
                } label: {
                    Label("End demo", systemImage: "stop.circle")
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)

                Text("Returns to the microphone. It does not start detecting.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}

// MARK: - Amplitude meter

/// Shared math for the amplitude meters. Free functions rather than View
/// methods so both meter View structs below can use them.
private enum MeterMath {
    /// Meter floor in dBFS. Higher than the −80 capture floor because the ambient
    /// noise floor sits near −60, so the useful swing is −60…0.
    static let floorDB: Double = -60

    /// Maps a dBFS value to 0…1 over the meter's [floorDB, 0] range.
    static func normalized(_ db: Double) -> Double {
        min(max((db - floorDB) / (0 - floorDB), 0), 1)
    }

    /// Samples the user-selected display palette so the meter matches the
    /// spectrogram. Skewed toward the bright end (t = 0.35…1) because most
    /// palettes start near-black, which would make the low segments invisible.
    ///
    /// `inverted` is passed IN rather than read from `DisplayColormap.inverted`
    /// (Niall, 2026-09-02). That global is not observable, so a meter that read
    /// it directly kept whichever polarity it was first drawn with and sat there
    /// in last night's colours after a light/dark switch. Handing it in from the
    /// view's own `@Environment(\.colorScheme)` makes the appearance a real
    /// dependency of the body, which is what makes the redraw happen at all.
    static func color(_ frac: Double, palette: Palette, inverted: Bool) -> Color {
        let f = min(max(frac, 0), 1)
        let (r, g, b) = DisplayColormap.rgb(Float(0.35 + 0.65 * f), palette: palette,
                                            inverted: inverted)
        return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

/// Owns the peak-hold position for the amplitude meters. Held as `@State` in
/// ContentView but only ever read/written from inside the meter leaf views below,
/// so its 15 Hz updates never invalidate ContentView.body.
@Observable
final class PeakHoldTracker {
    private(set) var peakHold: Double = 0    // 0–1 peak-hold position for the VU meter
    private var peakHoldAt: Date = .distantPast

    func update(db: Double) {
        let n = MeterMath.normalized(db)
        if n >= peakHold {
            peakHold = n                       // jump up to a new peak and hold
            peakHoldAt = Date()
        } else if Date().timeIntervalSince(peakHoldAt) > 0.8 {
            peakHold = max(n, peakHold - 0.02) // then fall back gradually (~0.3/s at 15 Hz)
        }
    }

    func reset() { peakHold = 0 }
}

/// Retro segmented level meter with a falling peak-hold dot, driven by the input
/// RMS level. Segments sample the selected display palette. A standalone
/// View (not a ContentView computed property) so reading `currentLevelDB` at
/// 15 Hz only invalidates this small view, not the whole screen.
struct AmplitudeMeterView: View {
    /// The meter is coloured from the spectrogram's palette, which flips with
    /// the appearance — see `MeterMath.color`.
    @Environment(\.colorScheme) private var colorScheme
    let audio: AudioEngineController
    let peakHold: PeakHoldTracker
    let detector: PulseDetector

    var body: some View {
        let palette = detector.displayPalette
        let inverted = colorScheme == .light
        let level = MeterMath.normalized(Double(audio.diagnostics.currentLevelDB))
        let segments = 40
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("AMPLITUDE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f dBFS", audio.diagnostics.currentLevelDB))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<segments, id: \.self) { i in
                            let frac = Double(i) / Double(segments - 1)
                            let lit = frac <= level
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(MeterMath.color(frac, palette: palette, inverted: inverted).opacity(lit ? 1 : 0.12))
                        }
                    }
                    if peakHold.peakHold > 0 {
                        Circle()
                            .fill(MeterMath.color(peakHold.peakHold, palette: palette, inverted: inverted))
                            .frame(width: 7, height: 7)
                            .shadow(color: MeterMath.color(peakHold.peakHold, palette: palette, inverted: inverted).opacity(0.8), radius: 2)
                            .position(x: max(3, min(geo.size.width - 3, geo.size.width * peakHold.peakHold)),
                                      y: geo.size.height / 2)
                    }
                }
            }
            .frame(height: 13)

            HStack {
                meterScaleLabel("-60")
                Spacer()
                meterScaleLabel("-30")
                Spacer()
                meterScaleLabel("0 dB")
            }
        }
        .onChange(of: audio.diagnostics.currentLevelDB) { _, db in
            peakHold.update(db: Double(db))
        }
    }

    private func meterScaleLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 8).monospacedDigit())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Slow replay status

/// Icon-only status pill for the live snippet expansion mode: armed and
/// listening, capturing, or replaying (and therefore deaf).
///
/// **Why this earns a pill.** Being deaf is the mode's whole trade-off and is
/// otherwise invisible — during a replay the output sounds busiest at exactly
/// the moment new calls are being ignored. The ring around the icon shows how
/// far through the replay is, which answers the question a user actually has:
/// how long until it is listening again.
///
/// Polled on a timeline rather than observed. `SnippetExpansionProcessor` is
/// `nonisolated` and its state lives in an atomic touched by two realtime
/// threads — there is nothing to observe, and nothing there should be made to
/// notify the main actor at audio rates.
struct SnippetStatusPill: View {
    let audio: AudioEngineController
    /// Forces the idle (ear) appearance so the guided tour's step has something to
    /// spotlight — the tour is normally taken with detection off and slow replay
    /// unselected, i.e. in the one state where this pill deliberately renders
    /// nothing. Same device as `SessionTimerPill.tourDemo`.
    var tourDemo: Bool = false
    @State private var showExplainer = false

    private var isLive: Bool { audio.listenMode == .snippetExpansion && audio.isRunning }

    var body: some View {
        if isLive {
            // 0.25 s, not 0.1: the only moving part is a progress ring on a
            // replay lasting seconds, and every tick re-lays out the stats
            // header row it sits in.
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                pill(audio.snippetExpansion.activity)
            }
        } else if tourDemo {
            // No TimelineView on this path: there is no live activity to poll, and
            // the tour already has a dim overlay and a moving spotlight to render.
            pill(.listening)
        }
    }

    private func pill(_ activity: SnippetExpansionProcessor.Activity) -> some View {
        ZStack {
            if activity == .replaying {
                Circle()
                    .trim(from: 0, to: audio.snippetExpansion.replayProgress)
                    .stroke(Color.orange, style: .init(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 18)
            }
            Image(systemName: icon(activity))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(activity))
        }
        .frame(width: StatusPillMetrics.height, height: StatusPillMetrics.height)
        .background(.ultraThinMaterial, in: Circle())
        .contentShape(Circle())
        .onTapGesture { showExplainer = true }
        .accessibilityLabel(label(activity))
        .popover(isPresented: $showExplainer) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Slow replay").font(.subheadline.weight(.semibold))
                // "Ready to capture", not "armed and recording": this pill
                // says nothing about the WAV recorder, and the old wording
                // was read as if it did.
                Text("Ear: ready, waiting for a call. Red: capturing the snippet around a call. Tortoise: replaying it slowly — while that ring fills, no new snippet is being captured. Live heterodyne keeps playing throughout, so you never lose the bat.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(width: 250, alignment: .leading)
            .presentationCompactAdaptation(.popover)
        }
    }

    private func icon(_ a: SnippetExpansionProcessor.Activity) -> String {
        switch a {
        case .listening: "ear"
        case .capturing: "record.circle"
        case .replaying: "tortoise.fill"
        }
    }

    // Orange for replaying — the app's existing "active, and costing you
    // something" colour, and the state worth noticing.
    private func color(_ a: SnippetExpansionProcessor.Activity) -> Color {
        switch a {
        case .listening: .secondary
        case .capturing: .red
        case .replaying: .orange
        }
    }

    private func label(_ a: SnippetExpansionProcessor.Activity) -> String {
        switch a {
        case .listening: "Slow replay: listening"
        case .capturing: "Slow replay: capturing"
        case .replaying: "Slow replay: replaying, not capturing"
        }
    }
}

// MARK: - Recording status

/// "Not recording" / "Recording" badge for the corner of the spectrogram.
///
/// The record button alone was not reading clearly enough: armed and unarmed
/// differ only by the button's tint, which is easy to miss in the field and
/// costly to get wrong — a whole session can be listened through without a
/// single file being written. This states it in words, in the place the user is
/// already looking.
///
/// **Static, with no pulsing dot.** The first version pulsed the dot with
/// `.repeatForever(autoreverses:)`. That is the one animation kind
/// `RecordPulse` documents as unsafe here: it can be picked up from the
/// transaction by unrelated views, and once inherited there is nothing to end
/// it, so they oscillate for the rest of the run. Adding a second one to the
/// hierarchy (the record glyph already has the one carefully scoped instance)
/// set the status pills and toolbar sliding around the screen. The badge's job
/// is legibility, not motion, so the motion is simply gone.
///
/// Tied to `isArmed` — the record BUTTON's state — not to `isWriting`.
///
/// Writing is the literally accurate signal, and was tried first: armed means
/// "will record when a call arrives", so between calls nothing is being written.
/// But that makes the pill flicker between "Recording" and "Not recording"
/// through every gap in a pass, which is worse than useless for the one job it
/// has. The user feedback this exists to answer is "it's easy to miss that
/// you're not recording", and against that question the honest answer is
/// whether recording is switched on, not whether a bat happens to be calling
/// this second.
struct RecordingStatusBadge: View {
    let recorder: AudioRecorder
    /// Forces the recording appearance for the guided tour, matching
    /// `SessionTimerPill.tourDemo`.
    var tourDemo: Bool = false

    private var isOn: Bool { tourDemo || recorder.isArmed }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? Color.primary : Color.secondary.opacity(0.7))
                .frame(width: 6, height: 6)
            Text(isOn ? "Recording" : "Not recording")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        // NO pulsing dot, deliberately — see the type's doc comment.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOn ? "Recording" : "Not recording")
    }
}
