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

// MARK: - Adaptive time expansion

/// Every adaptive time-expansion knob: sampler mode, gain, gate thresholds,
/// hangover/max-event, pre-roll/post-roll/ramp, the background expander, and
/// live event telemetry.
struct AdaptiveTETuningTab: View {
    let audio: AudioEngineController
    @Bindable var settings: AdaptiveTimeExpansionSettings

    private var inactive: String? {
        audio.listenMode == .adaptiveTimeExpansion ? nil : "Adaptive TE is not the active listen mode"
    }

    /// The hangover only decides when a live-extending event closes, and a
    /// sampler event's boundaries come from its own level history instead — so
    /// the slider is disabled rather than left to look effective.
    private var hangoverInactive: String? {
        if let inactive { return inactive }
        return settings.samplerEnabled ? "Sampler mode ends events by call shape, not hangover" : nil
    }

    /// Real expansion factor, so "heard" durations aren't a hardcoded 8× that
    /// would be wrong if iOS negotiated something other than 384 kHz.
    private var expansion: Double {
        let f = audio.adaptiveTimeExpansion.slowdownFactor
        return f > 0 ? f : 8
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let proc = audio.adaptiveTimeExpansion

            // Sampler first: it changes what every knob below is doing, so
            // reading the tab top-down should establish which mode you're in
            // before it starts offering event-timing controls.
            Toggle(isOn: Binding(
                get: { settings.samplerEnabled },
                set: {
                    settings.samplerEnabled = $0
                    proc.samplerEnabled = $0
                }
            )) {
                TuningInfoLabel(text: "Sampler mode", explanation: TuningHelp.samplerEnabled)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(inactive != nil)

            if settings.samplerEnabled {
                TuningSlider(
                    label: "Sample every", explanation: TuningHelp.samplerInterval,
                    initial: settings.samplerIntervalSeconds, range: 1...30, step: 0.5,
                    format: { String(format: "%.1f s", $0) },
                    onLive: { proc.samplerIntervalSeconds = $0 },
                    onCommit: { settings.samplerIntervalSeconds = $0 }, disabledReason: inactive)

                // Heard-ms alongside captured, same reasoning as the expander
                // release: the scan is in captured time but the wait it adds
                // before you hear anything is wall-clock.
                TuningSlider(
                    label: "Candidate scan", explanation: TuningHelp.samplerScan,
                    initial: settings.samplerScanMs, range: 0...300, step: 10,
                    format: { $0 <= 0 ? "off (first wins)" : String(format: "%.0f ms", $0) },
                    onLive: { proc.samplerScanMs = $0 },
                    onCommit: { settings.samplerScanMs = $0 }, disabledReason: inactive)

                // The knob to reach for when calls sound clipped. Measured
                // against each call's own peak rather than a fixed level over
                // the noise floor, which is what made faint calls come out
                // tighter than loud ones.
                TuningSlider(
                    label: "Edge cut", explanation: TuningHelp.samplerEdge,
                    initial: settings.samplerEdgeFraction, range: 0.05...0.6, step: 0.01,
                    format: { String(format: "%.2f", $0) },
                    onLive: { proc.samplerEdgeFraction = $0 },
                    onCommit: { settings.samplerEdgeFraction = $0 }, disabledReason: inactive)

                Text("Picks the strongest call in the scan window, finds its own start and end, and plays all of it. Everything else is let through — the missed count below is that by design, not a fault.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)

            TuningSlider(
                label: "Output gain", explanation: TuningHelp.ateGain, initial: Double(settings.gain), range: 0.5...30,
                format: { String(format: "%.1f×", $0) },
                onLive: { proc.gain = Float($0) },
                onCommit: { settings.gain = Float($0) }, disabledReason: inactive)

            TuningSlider(
                label: "Open threshold", explanation: TuningHelp.openThreshold, initial: settings.thresholdDB, range: 3...30, step: 0.5,
                format: { String(format: "%.1f dB", $0) },
                onLive: { proc.thresholdDB = $0 },
                onCommit: { settings.thresholdDB = $0 }, disabledReason: inactive)

            TuningSlider(
                label: "Hold threshold", explanation: TuningHelp.holdThreshold, initial: settings.releaseDB, range: 0...30, step: 0.5,
                format: { String(format: "%.1f dB", $0) },
                onLive: { proc.releaseDB = $0 },
                onCommit: { settings.releaseDB = $0 }, disabledReason: inactive)

            TuningSlider(
                label: "Hangover", explanation: TuningHelp.hangover, initial: settings.hangoverMs, range: 5...250, step: 5,
                format: { String(format: "%.0f ms", $0) },
                onLive: { proc.hangoverMs = $0 },
                onCommit: { settings.hangoverMs = $0 }, disabledReason: hangoverInactive)

            TuningSlider(
                label: "Max event", explanation: TuningHelp.maxEvent, initial: settings.maxBufferMs, range: 20...500, step: 10,
                format: { String(format: "%.0f ms", $0) },
                onLive: { proc.maxBufferMs = $0 },
                onCommit: { settings.maxBufferMs = $0 }, disabledReason: inactive)

            Divider().opacity(0.5)

            // The onset group. Pre-roll vs ramp is the pair behind the dulled
            // call onsets: a ramp longer than the pre-roll is still fading in
            // when the call arrives. The processor clamps ramp ≤ post-roll, so
            // pushing the ramp slider past the post-roll simply stops.
            TuningSlider(
                label: "Pre-roll", explanation: TuningHelp.preRoll, initial: settings.preRollMs, range: 0.5...20, step: 0.5,
                format: { String(format: "%.1f ms", $0) },
                onLive: { proc.preRollMs = $0 },
                onCommit: { settings.preRollMs = $0 }, disabledReason: inactive)

            TuningSlider(
                label: "Post-roll", explanation: TuningHelp.postRoll, initial: settings.postRollMs, range: 1...50, step: 0.5,
                format: { String(format: "%.1f ms", $0) },
                onLive: { proc.postRollMs = $0 },
                onCommit: { settings.postRollMs = $0 }, disabledReason: inactive)

            TuningSlider(
                label: "Ramp", explanation: TuningHelp.ramp, initial: settings.rampMs, range: 0.1...50, step: 0.1,
                format: { String(format: "%.1f ms", $0) },
                onLive: { proc.rampMs = $0 },
                onCommit: {
                    // Store what the processor accepted, not what was asked for,
                    // so a ramp clamped against the post-roll doesn't persist a
                    // value the UI would then redisplay as if it had taken.
                    settings.rampMs = $0
                    settings.rampMs = proc.rampMs
                }, disabledReason: inactive)

            Divider().opacity(0.5)

            Toggle(isOn: Binding(
                get: { settings.expanderEnabled },
                set: {
                    settings.expanderEnabled = $0
                    proc.expanderEnabled = $0
                }
            )) {
                TuningInfoLabel(text: "Background expander", explanation: TuningHelp.expanderEnabled)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .disabled(inactive != nil)

            if settings.expanderEnabled {
                TuningSlider(
                    label: "Expander threshold", explanation: TuningHelp.expanderThreshold, initial: settings.expanderThresholdDB,
                    range: 0...40, step: 0.5,
                    format: { String(format: "%.1f dB", $0) },
                    onLive: { proc.expanderThresholdDB = $0 },
                    onCommit: { settings.expanderThresholdDB = $0 }, disabledReason: inactive)

                TuningSlider(
                    label: "Expander depth", explanation: TuningHelp.expanderDepth, initial: settings.expanderDepthDB,
                    range: 0...60, step: 1,
                    format: { $0 >= 60 ? "mute" : String(format: "−%.0f dB", $0) },
                    onLive: { proc.expanderDepthDB = $0 },
                    onCommit: { settings.expanderDepthDB = $0 }, disabledReason: inactive)

                // Shown in heard-ms as well as captured, because the captured
                // number is the one that's meaningless to the ear: 16 ms here
                // is over 130 ms of what you actually listen to.
                TuningSlider(
                    label: "Expander release", explanation: TuningHelp.expanderRelease, initial: settings.expanderReleaseMs,
                    range: 1...200, step: 1,
                    format: { String(format: "%.0f ms (%.0f heard)", $0, $0 * expansion) },
                    onLive: { proc.expanderReleaseMs = $0 },
                    onCommit: { settings.expanderReleaseMs = $0 }, disabledReason: inactive)

                Text("Short release removes more hiss but pulls down the call's decaying tail with it. Long release keeps tails intact and mainly cleans the pre-roll and the gaps inside a burst.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if settings.rampMs > settings.preRollMs {
                Text("Ramp exceeds pre-roll — call onsets arrive mid-fade, about \(onsetLossDB) dB down.")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)
            telemetry
        }
    }

    /// Attenuation at the call onset when the fade-in is still rising.
    ///
    /// The onset lands `preRollMs` into a `rampMs` fade, i.e. at position
    /// `preRoll/ramp` along it. The fade is smoothstep — `x²(3−2x)`, see
    /// `AdaptiveTimeExpansionProcessor.fadeWeight` — NOT linear, so the loss
    /// must be computed through that curve or the number is wrong: at the
    /// shipped 2 ms pre-roll against a 3 ms ramp, smoothstep gives 20/27 of
    /// full amplitude (−2.6 dB) where a linear fade would suggest −3.5 dB.
    private var onsetLossDB: String {
        let x = (settings.preRollMs / max(settings.rampMs, 0.001)).clamped(to: 0.0001...1)
        let weight = max(x * x * (3 - 2 * x), 0.0001)
        return String(format: "%.1f", -20 * log10(weight))
    }

    /// Live counters. Polled at 5 Hz in its own `TimelineView` so nothing else
    /// in the overlay rebuilds with it — same containment as
    /// `AdaptiveTimeExpansionStatePill`.
    private var telemetry: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let proc = audio.adaptiveTimeExpansion
            let missed = proc.missedCount
            let overflow = proc.ringOverflowCount
            VStack(alignment: .leading, spacing: 1) {
                TuningReadout(label: "State", explanation: TuningHelp.ateState, value: stateLabel(proc.state))
                TuningReadout(label: "Events", explanation: TuningHelp.ateEvents, value: "\(proc.eventCount)")
                // Not a fault: missing pulses while draining is invariant 2
                // doing its job. It's flagged because tuning hangover/max-event
                // without watching this is how you land on a setting that
                // silently drops half a pass.
                // In sampler mode passing calls over is the point, so the
                // orange stops meaning "look at this" and the label says
                // "passed" instead of "missed".
                TuningReadout(label: settings.samplerEnabled ? "Passed" : "Missed",
                              explanation: TuningHelp.ateMissed, value: "\(missed)",
                              emphasis: missed > 0 && !settings.samplerEnabled ? .orange : .secondary)
                TuningReadout(label: "Ring overflow", explanation: TuningHelp.ateOverflow, value: "\(overflow)",
                              emphasis: overflow > 0 ? .red : .secondary)
                TuningReadout(label: "Expansion", explanation: TuningHelp.ateExpansion,
                              value: String(format: "%.1f×", proc.slowdownFactor))
            }
        }
    }

    private func stateLabel(_ state: AdaptiveTimeExpansionProcessor.State) -> String {
        switch state {
        case .idle: "idle"
        case .capturing: "capturing"
        case .draining: "draining (deaf)"
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
