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

/// The overlay's four tabs. Raw value is the short label shown in the tab bar.
enum LiveTuningTab: String, CaseIterable, Identifiable {
    case heterodyne = "Het"
    case distortion = "VTD"
    case pulse = "Pulse"
    case display = "Disp"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heterodyne: "Heterodyne"
        case .distortion: "Variable Time Distortion"
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

// MARK: - Variable Time Distortion

/// Gap speed, catch-up and lookahead for `VariableTimeDistortionProcessor`, plus the
/// telemetry that says whether it is actually working.
///
/// No settings object: the processor's knobs are lock-guarded scalars read once
/// per output buffer, so every slider here is `onLive` only, the same as the
/// heterodyne tab's gain. Nothing persists across launches yet.
///
/// **Dropped windows is the diagnostic that matters.** Call boundaries come
/// from `PulseDetector`, which can only report a window once the call's run has
/// ended — so the window always arrives after the audio it describes. If
/// Lookahead is smaller than that latency the windows land behind the read
/// pointer, every call plays unexpanded, and the mode sounds like it is doing
/// nothing at all while reporting no error.
struct VTDTuningTab: View {
    let audio: AudioEngineController

    private var inactive: String? {
        audio.listenMode == .variableTimeDistortion ? nil : "Variable Time Distortion is not the active listen mode"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let proc = audio.variableTimeDistortion

            telemetry
            RateSparkline(audio: audio)
            Divider().opacity(0.3)

            TuningSlider(
                label: "Gap speed", explanation: TuningHelp.vtdGapRate,
                initial: proc.gapRate,
                range: 1...32,
                step: 0.5,
                format: { String(format: "%.2f× real", $0 / 8) },
                onLive: { proc.gapRate = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Max catch-up rate", explanation: TuningHelp.vtdRateMax,
                initial: proc.rateMax,
                range: 8...128,
                step: 1,
                format: { String(format: "%.0f× real", $0 / 8) },
                onLive: { proc.rateMax = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Lookahead", explanation: TuningHelp.vtdLookahead,
                initial: proc.lookaheadMs,
                range: 20...1_000,
                step: 10,
                format: { String(format: "%.0f ms", $0) },
                onLive: { proc.lookaheadMs = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Catch up after", explanation: TuningHelp.vtdCatchupAfter,
                initial: proc.catchupAfterMs,
                range: 100...6_000,
                step: 50,
                format: { String(format: "%.2f s", $0 / 1000) },
                onLive: { proc.catchupAfterMs = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Transition", explanation: TuningHelp.vtdTransition,
                initial: proc.transitionMs,
                range: 0.5...40,
                step: 0.5,
                format: { String(format: "%.1f ms", $0) },
                onLive: { proc.transitionMs = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "High cut", explanation: TuningHelp.vtdHighCut,
                initial: proc.highCutHz,
                range: 20_000...192_000,
                step: 2_000,
                format: { $0 >= 191_000 ? "off (Nyquist)" : String(format: "%.0f kHz", $0 / 1000) },
                onLive: { proc.highCutHz = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Speed ducking", explanation: TuningHelp.vtdDuck,
                initial: proc.duckAlpha,
                range: 0...1.5,
                step: 0.05,
                format: { $0 <= 0.001 ? "off" : String(format: "%.2f", $0) },
                onLive: { proc.duckAlpha = $0 },
                disabledReason: inactive
            )
            TuningSlider(
                label: "Output gain", explanation: TuningHelp.heterodyneGain,
                initial: Double(proc.gain),
                range: 0.5...30,
                format: { String(format: "%.1f×", $0) },
                onLive: { proc.gain = Float($0) },
                disabledReason: inactive
            )
        }
    }

    /// Live counters, polled at 5 Hz in their own `TimelineView` so the sliders
    /// above don't rebuild with them — same containment as the ATE tab.
    private var telemetry: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let proc = audio.variableTimeDistortion
            let dropped = proc.droppedWindowCount
            let overflow = proc.overflowCount
            VStack(alignment: .leading, spacing: 1) {
                TuningReadout(label: "Lag", explanation: TuningHelp.vtdLag,
                              value: String(format: "%.2f s", proc.lagSeconds))
                TuningReadout(label: "Rate", explanation: TuningHelp.vtdRate,
                              value: String(format: "%.2f×", proc.currentRate))
                TuningReadout(label: "Expanded", explanation: TuningHelp.vtdExpanded,
                              value: "\(proc.expandedCount)")
                // The one to watch: non-zero means calls are going by
                // unexpanded because their window arrived too late to use.
                TuningReadout(label: "Dropped windows", explanation: TuningHelp.vtdDropped,
                              value: "\(dropped)",
                              emphasis: dropped > 0 ? .orange : .secondary)
                // Discarding input is a failure in this mode, not a trade-off.
                TuningReadout(label: "Ring overflow", explanation: TuningHelp.vtdOverflow,
                              value: "\(overflow)",
                              emphasis: overflow > 0 ? .red : .secondary)
            }
        }
    }
}

/// Playback rate over the last ~2.5 s, log-scaled.
///
/// Log rather than linear because the interesting range spans 1× to 64× and the
/// bottom of it is where the calls are. The two guide lines are the values worth
/// recognising by shape: 1× (full expansion, a call) and 8× (true speed).
private struct RateSparkline: View {
    let audio: AudioEngineController

    private let minRate: Double = 1
    private let maxRate: Double = 64

    private func y(_ rate: Double, in h: CGFloat) -> CGFloat {
        let r = min(max(rate, minRate), maxRate)
        let f = log2(r / minRate) / log2(maxRate / minRate)
        return h - CGFloat(f) * h                     // 1× at the bottom
    }

    var body: some View {
        // Faster than the counters above: at 5 Hz the trace visibly stutters.
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let samples = audio.variableTimeDistortion.rateHistorySnapshot()
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    ForEach([1.0, 8.0], id: \.self) { guide in
                        Path { p in
                            let gy = y(guide, in: h)
                            p.move(to: CGPoint(x: 0, y: gy))
                            p.addLine(to: CGPoint(x: w, y: gy))
                        }
                        .stroke(style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(.secondary.opacity(0.35))
                    }
                    if samples.count > 1 {
                        Path { p in
                            let dx = w / CGFloat(samples.count - 1)
                            for (i, v) in samples.enumerated() {
                                let pt = CGPoint(x: CGFloat(i) * dx, y: y(Double(v), in: h))
                                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                            }
                        }
                        .stroke(.tint, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                    }
                }
            }
            .frame(height: 34)
            .overlay(alignment: .topTrailing) {
                Text("64×").font(.system(size: 8)).foregroundStyle(.secondary.opacity(0.6))
            }
            .overlay(alignment: .bottomTrailing) {
                Text("1×").font(.system(size: 8)).foregroundStyle(.secondary.opacity(0.6))
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
