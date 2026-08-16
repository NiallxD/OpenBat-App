//
//  LiveTuningTabs.swift
//  OpenBat
//
//  The four tab bodies of the live tuning overlay. Each is a standalone leaf
//  `View` taking only the objects it edits — the usual @Observable-churn
//  discipline from Context.md §13, and doubly so here, since these are on screen
//  while the spectrogram's render loop is running behind them.
//
//  Every slider follows the same rule (see `TuningSlider`): drag writes to the
//  DSP object for immediate audible/visible effect, release writes to the
//  persisted settings object.
//

import SwiftUI

/// The overlay's five tabs. Raw value is the short label shown in the tab bar.
enum LiveTuningTab: String, CaseIterable, Identifiable {
    case heterodyne = "Het"
    case replay = "Replay"
    case haptics = "Haptic"
    case pulse = "Pulse"
    case display = "Disp"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heterodyne: "Heterodyne"
        case .replay: "Slow Replay"
        case .haptics: "Pulse Haptics"
        case .pulse: "Pulse Trigger"
        case .display: "Display"
        }
    }
}

// MARK: - Heterodyne

/// Gain, audible offset, and a manual/auto-tune readout for heterodyne.
struct HeterodyneTuningTab: View {
    let audio: AudioEngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Neither of these had any UI before the overlay. `gain` is a plain
            // lock-guarded scalar on the processor and `audibleOffsetHz` is read
            // on the next auto-tune tick, so both take effect immediately with
            // no settings-object counterpart to commit to — hence no onCommit.
            TuningSlider(
                label: "Output gain", explanation: TuningHelp.heterodyneGain,
                initial: Double(audio.heterodyne.gain),
                range: 0.5...30,
                format: { String(format: "%.1f×", $0) },
                onLive: { audio.heterodyne.gain = Float($0) },
                disabledReason: audio.listenMode == .heterodyne ? nil : "Heterodyne is not the active listen mode"
            )
            TuningSlider(
                label: "Audible offset", explanation: TuningHelp.audibleOffset,
                initial: audio.audibleOffsetHz,
                range: 200...6_000,
                step: 50,
                format: { String(format: "%.0f Hz", $0) },
                onLive: { audio.audibleOffsetHz = $0 },
                disabledReason: audio.listenMode == .heterodyne ? nil : "Heterodyne is not the active listen mode"
            )

            Divider().opacity(0.5)

            // The LO is driven by the auto-tuner, so it's a readout here rather
            // than a slider — dragging it is what the existing TunedPillView
            // gesture is for, and duplicating that control would give two places
            // that fight over `isAutoTune`.
            TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                VStack(alignment: .leading, spacing: 1) {
                    TuningReadout(
                        label: "LO frequency", explanation: TuningHelp.loFrequency,
                        value: audio.tunedFrequency > 0
                            ? String(format: "%.1f kHz", audio.tunedFrequency / 1000)
                            : "searching",
                        emphasis: audio.tunedFrequency > 0 ? .primary : .secondary
                    )
                    TuningReadout(
                        label: "Tuning", explanation: TuningHelp.tuningMode,
                        value: audio.isAutoTune ? "auto" : "manual",
                        emphasis: audio.isAutoTune ? .secondary : .orange
                    )
                }
            }
            if !audio.isAutoTune {
                Button("Return to auto-tune") { audio.enableAutoTune() }
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
    }
}

// MARK: - Slow replay (live snippet expansion)

/// Speed, buffer length and output routing for the D240x-pattern live mode.
///
/// **The number that matters is neither slider — it is their product.** Buffer
/// length × speed is how long a replay lasts, and the mode captures nothing new
/// for that whole time, so a generous buffer at a high factor quietly turns into
/// half a minute of deafness per trigger. It is shown as its own readout for
/// that reason rather than left for the user to multiply.
struct SnippetExpansionTuningTab: View {
    let audio: AudioEngineController
    let settings: SnippetExpansionSettings

    private var inactive: String? {
        audio.listenMode == .snippetExpansion ? nil : "Slow replay is not the active listen mode"
    }

    /// Taken from the processor so the slider cannot offer a value its setter
    /// would silently clamp.
    private static let memoryRange =
        SnippetExpansionProcessor.minMemorySeconds...SnippetExpansionProcessor.maxMemorySeconds

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TuningSlider(
                label: "Speed", explanation: TuningHelp.snippetExpansion,
                initial: settings.expansion,
                range: 4...20,
                step: 0.5,
                format: { String(format: "%.1f× slower", $0) },
                onLive: { audio.snippetExpansion.expansion = $0 },
                onCommit: { settings.expansion = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Buffer", explanation: TuningHelp.snippetMemory,
                initial: settings.memorySeconds,
                range: Self.memoryRange,
                step: 0.1,
                format: { String(format: "%.1f s", $0) },
                onLive: { audio.snippetExpansion.memorySeconds = $0 },
                onCommit: { settings.memorySeconds = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Hiss reduction", explanation: TuningHelp.snippetHiss,
                initial: settings.hissReductionDB,
                range: 0...40,
                step: 1,
                format: { $0 < 0.5 ? "off" : String(format: "−%.0f dB", $0) },
                onLive: { audio.snippetExpansion.hissReductionDB = $0 },
                onCommit: { settings.hissReductionDB = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Fade in/out", explanation: TuningHelp.snippetFade,
                initial: settings.fadeMS,
                range: 1...250,
                step: 1,
                format: { String(format: "%.0f ms", $0) },
                onLive: { audio.snippetExpansion.fadeMS = $0 },
                onCommit: { settings.fadeMS = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Replay gain", explanation: TuningHelp.snippetGain,
                initial: Double(settings.gain),
                range: 0.5...30,
                format: { String(format: "%.1f×", $0) },
                onLive: { audio.snippetExpansion.gain = Float($0) },
                onCommit: { settings.gain = Float($0) },
                disabledReason: inactive
            )

            Divider().opacity(0.5)

            TuningReadout(
                label: "Replay length", explanation: TuningHelp.snippetReplayLength,
                value: String(format: "%.0f s per trigger", settings.replaySeconds),
                emphasis: settings.replaySeconds > 20 ? .orange : .primary
            )

            Divider().opacity(0.5)

            // A picker rather than a slider: three named destinations, not a
            // continuum. Routing is an atomic on the controller, so this takes
            // effect on the next render block with no engine restart.
            VStack(alignment: .leading, spacing: 3) {
                TuningInfoLabel(
                    text: "Output",
                    explanation: TuningHelp.snippetRouting,
                    emphasis: inactive == nil ? .secondary : Color.secondary.opacity(0.5)
                )
                // Not the only writer of `routing`, and no longer the primary one:
                // ContentView's listen-mode cycle (`advanceListenMode`) sets
                // `.expansionOnly` every time it enters slow replay and `.both` on
                // the step after, so a choice made here survives only until the
                // next trip round that cycle. `.heterodyneOnly` is the one case
                // this picker alone can reach.
                Picker("Output", selection: Binding(
                    get: { settings.routing },
                    set: {
                        settings.routing = $0
                        audio.setSnippetRouting($0)
                    }
                )) {
                    ForEach(SnippetOutputRouting.allCases, id: \.rawValue) { r in
                        Text(r.label).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(inactive != nil)
            }
        }
    }
}

// MARK: - Pulse haptics

/// The call/buzz transition and the intensity/sharpness mapping, plus the pulse
/// rate trace that makes the thresholds tunable at all.
///
/// **The trace is the instrument.** Two rate thresholds cannot be set by
/// reasoning about them — you have to see where the actual pulse rate goes
/// during a real pass and put the pair around it. The sparkline draws both
/// thresholds as guide lines over the live rate, so "enter" is placed above
/// search-phase chatter and below the buzz rather than guessed.
///
/// Everything here is live and persisted, so a setting arrived at in the field
/// survives the trip home.
struct HapticsTuningTab: View {
    let haptics: PulseHaptics

    private var inactive: String? {
        if !haptics.isSupported { return "This device has no Taptic Engine" }
        if !haptics.isEnabled { return "Pulse haptics are switched off in Settings › Audio" }
        return haptics.unavailableReason
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            telemetry
            PulseRateSparkline(haptics: haptics)
            Divider().opacity(0.3)

            TuningSlider(
                label: "Buzz at", explanation: TuningHelp.hapticBuzzEnter,
                initial: haptics.buzzEnterHz,
                range: 3...40, step: 0.5,
                format: { String(format: "%.1f /s", $0) },
                onLive: { haptics.buzzEnterHz = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Back to taps at", explanation: TuningHelp.hapticBuzzExit,
                initial: haptics.buzzExitHz,
                range: 1...max(1.5, haptics.buzzEnterHz - 0.5), step: 0.5,
                format: { String(format: "%.1f /s", $0) },
                onLive: { haptics.buzzExitHz = $0 },
                disabledReason: inactive
            )
            .id(haptics.buzzEnterHz)
            TuningSlider(
                label: "Rate window", explanation: TuningHelp.hapticRateWindow,
                initial: haptics.rateWindow,
                range: 0.1...1.5, step: 0.05,
                format: { String(format: "%.2f s", $0) },
                onLive: { haptics.rateWindow = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Buzz hangover", explanation: TuningHelp.hapticHangover,
                initial: haptics.buzzHangover,
                range: 0.05...1.0, step: 0.05,
                format: { String(format: "%.2f s", $0) },
                onLive: { haptics.buzzHangover = $0 },
                disabledReason: inactive
            )

            Divider().opacity(0.3)

            TuningSlider(
                label: "Strength", explanation: TuningHelp.hapticStrength,
                initial: haptics.strength,
                range: 0.25...1.5, step: 0.05,
                format: { String(format: "%.0f%%", $0 * 100) },
                onLive: { haptics.strength = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Quiet call level", explanation: TuningHelp.hapticLevelFloor,
                initial: Double(haptics.levelFloor),
                range: 0.1...0.9, step: 0.01,
                format: { String(format: "%.2f", $0) },
                onLive: { haptics.levelFloor = Float($0) },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Loud call level", explanation: TuningHelp.hapticLevelCeiling,
                initial: Double(haptics.levelCeiling),
                range: 0.2...1.0, step: 0.01,
                format: { String(format: "%.2f", $0) },
                onLive: { haptics.levelCeiling = Float($0) },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Weakest tap", explanation: TuningHelp.hapticMinIntensity,
                initial: Double(haptics.minIntensity),
                range: 0...0.8, step: 0.05,
                format: { String(format: "%.2f", $0) },
                onLive: { haptics.minIntensity = Float($0) },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Dull below", explanation: TuningHelp.hapticFreqFloor,
                initial: haptics.freqFloorHz,
                range: 10_000...60_000, step: 1_000,
                format: { String(format: "%.0f kHz", $0 / 1000) },
                onLive: { haptics.freqFloorHz = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Crisp above", explanation: TuningHelp.hapticFreqCeiling,
                initial: haptics.freqCeilingHz,
                range: 20_000...140_000, step: 1_000,
                format: { String(format: "%.0f kHz", $0 / 1000) },
                onLive: { haptics.freqCeilingHz = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Min tap spacing", explanation: TuningHelp.hapticTapInterval,
                initial: haptics.minTapInterval,
                range: 0.02...0.2, step: 0.005,
                format: { String(format: "%.0f ms", $0 * 1000) },
                onLive: { haptics.minTapInterval = $0 },
                disabledReason: inactive
            )

            Button("Play a sample") { haptics.playPreview() }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(inactive != nil)
        }
    }

    /// Polled in its own `TimelineView` so the sliders above don't rebuild with
    /// it — same containment as the other tabs' telemetry.
    private var telemetry: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            VStack(alignment: .leading, spacing: 1) {
                TuningReadout(label: "Pulse rate", explanation: TuningHelp.hapticRate,
                              value: String(format: "%.0f /s", haptics.currentRateHz))
                TuningReadout(label: "Mode", explanation: TuningHelp.hapticMode,
                              value: haptics.isInBuzzMode ? "buzz" : "taps",
                              emphasis: haptics.isInBuzzMode ? .orange : .secondary)
                TuningReadout(label: "Events", explanation: TuningHelp.hapticEvents,
                              value: "\(haptics.eventCount)")
                if let reason = inactive {
                    Text(reason)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Pulse rate over the last ~12 s with both rate thresholds drawn across it.
///
/// Linear rather than log: the interesting range is a couple of octaves at most
/// and the thresholds have to read as positions, not ratios.
private struct PulseRateSparkline: View {
    let haptics: PulseHaptics

    @State private var history: [Double] = []
    private static let capacity = 120          // 12 s at 10 Hz

    private var ceiling: Double {
        max(haptics.buzzEnterHz * 1.4, (history.max() ?? 0) * 1.15, 6)
    }

    private func y(_ rate: Double, in h: CGFloat) -> CGFloat {
        h - CGFloat(min(max(rate / ceiling, 0), 1)) * h
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                ForEach([(haptics.buzzEnterHz, Color.orange),
                         (haptics.buzzExitHz, Color.secondary)], id: \.0) { level, tint in
                    Path { p in
                        let gy = y(level, in: h)
                        p.move(to: CGPoint(x: 0, y: gy))
                        p.addLine(to: CGPoint(x: w, y: gy))
                    }
                    .stroke(style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    .foregroundStyle(tint.opacity(0.6))
                }
                if history.count > 1 {
                    Path { p in
                        let dx = w / CGFloat(Self.capacity - 1)
                        for (i, v) in history.enumerated() {
                            let pt = CGPoint(x: CGFloat(i) * dx, y: y(v, in: h))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(.tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
        .frame(height: 38)
        .overlay(alignment: .topTrailing) {
            Text(String(format: "%.0f/s", ceiling))
                .font(.system(size: 8)).foregroundStyle(.secondary.opacity(0.6))
        }
        // Sampled here rather than in a TimelineView body: the trace must keep
        // moving when pulses stop, and appending during render is a mutation.
        .task {
            while !Task.isCancelled {
                history.append(haptics.currentRateHz)
                if history.count > Self.capacity { history.removeFirst() }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

// MARK: - Pulse trigger

/// Pulse trigger mode and its thresholds, plus the capture window and pulse
/// display floor. `PulseDetector` has no separate DSP object, so these
/// properties ARE the live values — every slider writes only via `onLive`.
struct PulseTuningTab: View {
    @Bindable var detector: PulseDetector

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TuningInfoLabel(text: "Trigger", explanation: TuningHelp.triggerMode)
                Spacer(minLength: 4)
            }
            Picker("Trigger", selection: $detector.triggerMode) {
                Text("Ultrasonic").tag(PulseDetector.TriggerMode.ultrasonic)
                Text("Amplitude").tag(PulseDetector.TriggerMode.amplitude)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)

            // No onCommit: there's nothing else to write to (see the type doc).
            if detector.triggerMode == .amplitude {
                TuningSlider(
                    label: "Amplitude", explanation: TuningHelp.amplitudeThreshold, initial: Double(detector.amplitudeThreshold),
                    range: 0.1...0.95, step: 0.05,
                    format: { String(format: "%.2f", $0) },
                    onLive: { detector.amplitudeThreshold = Float($0) })
            } else {
                TuningSlider(
                    label: "Min frequency", explanation: TuningHelp.minFrequency, initial: detector.minFrequencyHz,
                    range: 5_000...150_000, step: 1_000,
                    format: { String(format: "%.0f kHz", $0 / 1000) },
                    onLive: { detector.minFrequencyHz = $0 })
            }

            TuningSlider(
                label: "Min duration", explanation: TuningHelp.minDuration, initial: Double(detector.minConsecutiveColumns),
                range: 1...10, step: 1,
                format: { String(format: "%.0f col", $0) },
                onLive: { detector.minConsecutiveColumns = Int($0) })

            TuningSlider(
                label: "Bridge gaps", explanation: TuningHelp.bridgeGaps, initial: detector.maxGapMs, range: 0...30, step: 1,
                format: { String(format: "%.0f ms", $0) },
                onLive: { detector.maxGapMs = $0 })

            TuningSlider(
                label: "Hold-off", explanation: TuningHelp.holdOff, initial: detector.holdOffSeconds, range: 0.02...1.0, step: 0.01,
                format: { String(format: "%.0f ms", $0 * 1000) },
                onLive: { detector.holdOffSeconds = $0 })

            Divider().opacity(0.5)

            TuningSlider(
                label: "Capture window", explanation: TuningHelp.captureWindow, initial: detector.displayWindowMs, range: 6...40, step: 2,
                format: { String(format: "%.0f ms", $0) },
                onLive: { detector.displayWindowMs = $0 })

            TuningSlider(
                label: "Pulse noise floor", explanation: TuningHelp.pulseNoiseFloor, initial: Double(detector.pulseNoiseFloor),
                range: 0...0.9, step: 0.05,
                format: { String(format: "%.2f", $0) },
                onLive: { detector.pulseNoiseFloor = Float($0) })
        }
    }
}

// MARK: - Display

/// Frequency band, time window, spectrogram display floor, and colour palette.
struct DisplayTuningTab: View {
    @Bindable var detector: PulseDetector
    @Binding var bandLow: Double
    @Binding var bandHigh: Double
    @Binding var timeWindowSeconds: Double
    /// Nyquist for the current feed, so the band readout is in real kHz.
    let maxFrequency: Double
    /// Pushes the band into the processor and both listening DSPs — the
    /// overlay must not reimplement this, it's `ContentView.applyBand()`.
    let onBandChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TuningInfoLabel(text: "Band", explanation: TuningHelp.band)
                Spacer(minLength: 4)
                Text("\(kHz(bandLow))–\(kHz(bandHigh))")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            RangeSlider(low: $bandLow, high: $bandHigh)
                .controlSize(.mini)
                .onChange(of: bandLow) { _, _ in onBandChange() }
                .onChange(of: bandHigh) { _, _ in onBandChange() }

            TuningSlider(
                label: "Time window", explanation: TuningHelp.timeWindow, initial: timeWindowSeconds, range: 0.1...2.0, step: 0.1,
                format: { String(format: "%.1f s", $0) },
                onLive: { timeWindowSeconds = $0 })

            TuningSlider(
                label: "Spectrogram floor", explanation: TuningHelp.spectrogramFloor, initial: Double(detector.spectrogramNoiseFloor),
                range: 0...0.9, step: 0.05,
                format: { String(format: "%.2f", $0) },
                onLive: { detector.spectrogramNoiseFloor = Float($0) })

            Divider().opacity(0.5)

            HStack(spacing: 6) {
                TuningInfoLabel(text: "Palette", explanation: TuningHelp.palette)
                Spacer(minLength: 4)
                // Label hidden on the Picker itself — the tappable
                // TuningInfoLabel beside it is the label, and showing both
                // would print the name twice.
                Picker("Palette", selection: $detector.displayPalette) {
                    ForEach(Palette.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .font(.system(size: 11))
            }
        }
    }

    private func kHz(_ fraction: Double) -> String {
        String(format: "%.0f", fraction * maxFrequency / 1000)
    }
}
