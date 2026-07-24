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
//  CLAUDE.md.
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
/// "Session" (IDs + GPS track) vs a bare "Listening" bucket, or "Off" when nothing
/// is running — shown beside `MicStatusPill`. A standalone View struct for the same
/// reason as the other status pills — `audio.isRunning`/`classStore.activeSessionID`
/// are stored properties on churning `@Observable` objects, so scoping the read here
/// keeps it from invalidating ContentView.body (see the @Observable-churn note in
/// CLAUDE.md).
struct SessionStatusPillView: View {
    let audio: AudioEngineController
    let classStore: ClassificationStore

    private var isSession: Bool { classStore.activeSessionID != nil }

    private var icon: String {
        guard audio.isRunning else { return "pause.circle" }
        return isSession ? "location.fill" : "ear"
    }

    private var label: String {
        guard audio.isRunning else { return "Off" }
        return isSession ? "Session" : "Listening"
    }

    private var tint: Color {
        audio.isRunning ? .toggleOn : .secondary
    }

    var body: some View {
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
        .accessibilityLabel(audio.isRunning ? (isSession ? "Recording a session" : "Listening, not in a session") : "Not detecting")
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

    var body: some View {
        if let start {
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

/// Warns when heterodyne/RTE is playing out the built-in speaker: the mic picks
/// the playback back up acoustically and reprocesses it as a spurious low-pitch
/// "call" layered on the real one (confirmed fixed by wearing headphones — there's
/// no clean software fix for the acoustic coupling itself). Only shown while
/// actually listening on the speaker, so it doesn't nag when detection is silent
/// or headphones are already in. Same standalone-View-struct scoping as the other
/// status pills (`audio.isOutputOnSpeaker`/`listenMode` are on the churning
/// AudioEngineController).
struct SpeakerFeedbackWarningPill: View {
    let audio: AudioEngineController
    @State private var showExplainer = false

    var body: some View {
        if audio.isListening && audio.isOutputOnSpeaker {
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
struct MicStatusPill: View {
    let audio: AudioEngineController
    @State private var slowPulse = false   // ~1.4 s breathe for the connected icon
    @State private var fastFlash = false   // ~0.4 s blink for a clamped feed rate
    @State private var showExplainer = false

    private static let requiredRate: Double = 384_000

    var body: some View {
        let d = audio.diagnostics
        let connected = d.usbMicAvailable
        let rateKnown = audio.isRunning && d.actualSampleRate > 0
        let rateBad = rateKnown && d.actualSampleRate < Self.requiredRate
        HStack(spacing: 4) {
            Image(systemName: connected ? "cable.connector" : "cable.connector.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(connected ? Color.green : .red)
                .opacity(connected && slowPulse ? 0.35 : 1)
            if rateKnown {
                Text("\(Int((d.actualSampleRate / 1000).rounded())) kHz")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(rateBad ? Color.red : .secondary)
                    .opacity(rateBad && fastFlash ? 0.25 : 1)
            }
        }
        .padding(.horizontal, 7)
        .frame(height: StatusPillMetrics.height)
        .background(.ultraThinMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture { showExplainer = true }
        .popover(isPresented: $showExplainer) {
            explainer(connected: connected, rateKnown: rateKnown, rateBad: rateBad,
                      rate: d.actualSampleRate)
                .presentationCompactAdaptation(.popover)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { slowPulse = true }
            withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: true)) { fastFlash = true }
        }
        .accessibilityLabel(connected ? "External microphone connected" : "No external microphone")
        .accessibilityHint("Tap for details")
    }

    private func explainer(connected: Bool, rateKnown: Bool, rateBad: Bool,
                           rate: Double) -> some View {
        let (title, message): (String, String)
        if !connected {
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
    static func color(_ frac: Double, palette: Palette) -> Color {
        let f = min(max(frac, 0), 1)
        let (r, g, b) = DisplayColormap.rgb(Float(0.35 + 0.65 * f), palette: palette)
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
    let audio: AudioEngineController
    let peakHold: PeakHoldTracker
    let detector: PulseDetector

    var body: some View {
        let palette = detector.displayPalette
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
                                .fill(MeterMath.color(frac, palette: palette).opacity(lit ? 1 : 0.12))
                        }
                    }
                    if peakHold.peakHold > 0 {
                        Circle()
                            .fill(MeterMath.color(peakHold.peakHold, palette: palette))
                            .frame(width: 7, height: 7)
                            .shadow(color: MeterMath.color(peakHold.peakHold, palette: palette).opacity(0.8), radius: 2)
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

/// Vertical amplitude meter for the landscape sidebar. Same scoping rationale as
/// `AmplitudeMeterView`.
struct VerticalAmplitudeMeterView: View {
    let audio: AudioEngineController
    let peakHold: PeakHoldTracker
    let detector: PulseDetector

    var body: some View {
        let palette = detector.displayPalette
        let level = MeterMath.normalized(Double(audio.diagnostics.currentLevelDB))
        let segments = 20
        VStack(spacing: 2) {
            Text(String(format: "%.0f", audio.diagnostics.currentLevelDB))
                .font(.system(size: 6).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { geo in
                ZStack {
                    VStack(spacing: 1) {
                        ForEach((0..<segments).reversed(), id: \.self) { i in
                            let frac = Double(i) / Double(segments - 1)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(MeterMath.color(frac, palette: palette).opacity(frac <= level ? 1 : 0.12))
                        }
                    }
                    if peakHold.peakHold > 0 {
                        Circle()
                            .fill(MeterMath.color(peakHold.peakHold, palette: palette))
                            .frame(width: 6, height: 6)
                            .shadow(color: MeterMath.color(peakHold.peakHold, palette: palette).opacity(0.8), radius: 2)
                            .position(x: geo.size.width / 2,
                                      y: geo.size.height * (1.0 - CGFloat(peakHold.peakHold)))
                    }
                }
            }
            Text("dB")
                .font(.system(size: 6))
                .foregroundStyle(.secondary)
        }
        .onChange(of: audio.diagnostics.currentLevelDB) { _, db in
            peakHold.update(db: Double(db))
        }
    }
}
