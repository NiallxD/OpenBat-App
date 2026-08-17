//
//  MicCalibrationView.swift
//  OpenBat
//
//  "Calibrate Microphone" sheet — reachable from Settings (reusing
//  ContentView's already-activated AudioEngineController) and from an
//  optional onboarding step (its own throwaway instance). Records ~15s
//  during a deliberately quiet period via `MicCalibrator`, then either saves
//  the resulting `MicCalibrationCurve` or explains why the run wasn't usable.
//

import SwiftUI
import AVFoundation

struct MicCalibrationView: View {
    let audio: AudioEngineController
    let settings: MicCalibrationSettings
    let onFinished: () -> Void

    private enum Stage {
        case intro
        case recording
        case result(MicCalibrator.Result)
    }

    /// Was 30 s. Shortened because nothing about the measurement needed it:
    /// the curve is an average over ~1500 columns/s, so 15 s still gives ~22k
    /// columns and an estimator standard error around 0.04 dB — against a
    /// curve that is only ever allowed to apply ±12 dB. The extra 15 s bought
    /// about 0.01 dB and cost the user half a minute of standing still. It
    /// also cut the other way: the longer the window, the more chance a
    /// transient intrudes and fails the run outright.
    private static let captureSeconds: Double = 15

    /// How long to wait before deciding no audio is arriving. Long enough for
    /// the engine to start and the first buffers to land on a slow route,
    /// short enough that a dead input fails while the user is still holding
    /// still rather than after they've stood in a quiet corner for a quarter
    /// of a minute.
    private static let deadInputCheckSeconds: Double = 2

    @State private var stage: Stage = .intro
    @State private var calibrator: MicCalibrator?
    @State private var elapsed: Double = 0
    @State private var countdownTask: Task<Void, Never>?
    @State private var previousBufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    @State private var startedEngineOurselves = false
    /// `teardownAudio()` is called both from the countdown Task's own
    /// completion and from `.onDisappear` (belt-and-suspenders, in case the
    /// sheet is dismissed some other way mid-capture) — without this guard,
    /// the second call would restore `previousBufferSink`, which the first
    /// call had already cleared to `nil`, silently wiping out the real
    /// `bufferSink` it had just correctly restored.
    @State private var hasTornDownAudio = false
    /// Quietest level seen so far this recording — the live meter's "green"
    /// reference point. Reset at the start of every attempt; tracks a
    /// running minimum rather than a fixed value since the room's true quiet
    /// floor isn't known until it's been observed.
    @State private var baselineDB: Float?

    // Same compact-sheet language as `SuggestedModelSheet` in ContentView: no NavigationStack, no title bar,
    // an accent circle for the glyph, centred title/subtitle, one prominent
    // action tinted `.batAccent`, and a plain text button out. The old
    // navigation chrome existed only to host a Cancel button, and every stage
    // now carries its own way out.
    var body: some View {
        VStack(spacing: 24) {
            switch stage {
            case .intro:               introContent
            case .recording:           recordingContent
            case .result(let result):  resultContent(result)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .background(BaselineTracker(audio: audio, baselineDB: $baselineDB))
        // Each stage is a different height, so the sheet resizes with it rather
        // than being fixed to the tallest — these sheets are compact by design,
        // and a single detent would leave the short stages padded out. Measured
        // rather than hand-fitted per stage: the hand-fitted numbers were right
        // when written and silently wrong once the copy changed, which is how
        // the intro's explanation came to be cut off at "It d…".
        .contentSizedDetent(min: 300)
        .presentationDragIndicator(isRecording ? .hidden : .visible)
        .interactiveDismissDisabled(isRecording)
        .onDisappear { teardownAudio() }
    }

    private var isRecording: Bool {
        if case .recording = stage { return true }
        return false
    }

    /// The accent-circle glyph these sheets open with.
    private func sheetIcon(_ systemImage: String, tint: Color = .batAccent) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 72, height: 72)
            .background(tint.opacity(0.15), in: Circle())
    }

    @ViewBuilder private var introContent: some View {
        VStack(spacing: 10) {
            sheetIcon("tuningfork")
            Text("Calibrate \(audio.diagnostics.micDisplayName)")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .wrapsFully()
            Text("Find a quiet spot — no bat calls, minimal wind or traffic noise — and we'll measure your microphone's natural response for about 15 seconds. This flattens the spectrogram's noise floor and sharpens frequency measurements. It doesn't change or upload any recording.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .wrapsFully()
        }
        .frame(maxWidth: .infinity)

        Spacer(minLength: 0)

        sheetPrimaryButton("Start") { start() }

        Button("Not Now", role: .cancel) { cancel() }
            .padding(.top, 4)
    }

    @ViewBuilder private var recordingContent: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: min(1, elapsed / Self.captureSeconds))
                    .stroke(Color.batAccent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: elapsed)
                Text("\(max(0, Int((Self.captureSeconds - elapsed).rounded(.up))))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 128, height: 128)
            Text("Recording — find somewhere quiet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            MicLevelMeterView(audio: audio, baselineDB: baselineDB)
        }
        .frame(maxWidth: .infinity)

        Spacer(minLength: 0)

        Button("Cancel", role: .cancel) { cancel() }
            .padding(.top, 4)
    }

    @ViewBuilder
    private func resultContent(_ result: MicCalibrator.Result) -> some View {
        switch result {
        case .success:
            VStack(spacing: 10) {
                sheetIcon("checkmark.circle.fill", tint: .green)
                Text("Calibration saved")
                    .font(.title2.weight(.semibold))
                Text(audio.diagnostics.micDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .wrapsFully()
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            sheetPrimaryButton("Done") { finish(saving: result) }

        case .failure(let reason):
            VStack(spacing: 10) {
                sheetIcon("exclamationmark.triangle.fill", tint: .orange)
                Text("Calibration didn't work")
                    .font(.title2.weight(.semibold))
                Text(reason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                .wrapsFully()
            }
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)

            sheetPrimaryButton("Try Again") { start() }

            Button("Cancel", role: .cancel) { finish(saving: result) }
                .padding(.top, 4)
        }
    }

    private func sheetPrimaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(.batAccent)
    }

    // MARK: Flow

    private func start() {
        elapsed = 0
        baselineDB = nil
        hasTornDownAudio = false
        stage = .recording

        let rate = audio.diagnostics.actualSampleRate > 0 ? audio.diagnostics.actualSampleRate : 384_000
        let cal = MicCalibrator(sampleRate: rate, captureSeconds: Self.captureSeconds)
        calibrator = cal

        previousBufferSink = audio.bufferSink
        // Must be installed BEFORE `audio.start()` below, not after:
        // `AudioEngineController.startEngine()` snapshots `bufferSink` once
        // into the tap closure at start time rather than reading it live, so
        // setting this any later would silently never reach the tap and the
        // calibrator would capture nothing.
        audio.bufferSink = { [weak cal] buffer in cal?.feed(buffer) }

        countdownTask = Task {
            if !audio.isRunning {
                startedEngineOurselves = true
                await audio.start()
            }
            let step = 0.2
            var t = 0.0
            // Buffer count at the moment capture began. If it hasn't moved by
            // `deadInputCheckSeconds` no audio is arriving at all, and the run
            // is already lost — the old behaviour counted down the full fifteen
            // seconds, told the user it was "nice and quiet" throughout, and
            // only then admitted failure.
            //
            // Deliberately counts BUFFERS, not level. A dead input and a genuinely
            // silent room look identical on a level meter, and failing someone
            // for finding somewhere quiet enough would be precisely backwards.
            let buffersAtStart = audio.diagnostics.bufferCount
            while t < Self.captureSeconds, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                t += step
                elapsed = t
                if t >= Self.deadInputCheckSeconds,
                   audio.diagnostics.bufferCount == buffersAtStart {
                    teardownAudio()
                    stage = .result(.failure(reason: "No audio is reaching OpenBat from \(audio.diagnostics.micDisplayName). Check it's firmly connected, then try again."))
                    return
                }
            }
            guard !Task.isCancelled else { return }
            // Read now, not at the top of this function: `diagnostics.
            // inputName` during idle monitoring can still read the
            // placeholder ("—") for some USB devices, but by now the engine
            // has been running the whole capture, so it reliably reflects
            // the actually-connected mic — see `MicCalibrator.finish`'s doc
            // comment for why that timing matters.
            let result = cal.finish(micName: audio.diagnostics.inputName)
            teardownAudio()
            stage = .result(result)
        }
    }

    private func cancel() {
        countdownTask?.cancel()
        countdownTask = nil
        teardownAudio()
        onFinished()
    }

    private func finish(saving result: MicCalibrator.Result) {
        if case .success(let curve) = result {
            settings.save(curve)
        }
        onFinished()
    }

    /// Restores whatever `bufferSink` this view temporarily replaced, and
    /// stops the engine again if this view is the one that started it —
    /// never touches audio state it didn't itself set up (Settings' entry
    /// point only opens this when the engine is already idle; either way,
    /// `startedEngineOurselves` tracks who's responsible for stopping it).
    private func teardownAudio() {
        guard !hasTornDownAudio else { return }
        hasTornDownAudio = true
        audio.bufferSink = previousBufferSink
        previousBufferSink = nil
        if startedEngineOurselves {
            audio.stop()
            startedEngineOurselves = false
        }
    }
}

/// Invisible leaf view isolating the 15 Hz `currentLevelDB` read that drives
/// `baselineDB` — without this, the `.onChange` would live on
/// `MicCalibrationView.body` itself, and `@Observable`'s whole-property
/// invalidation would re-render the entire sheet (including the toolbar
/// Cancel button) on every level update, risking dropped taps during the
/// 15-second capture. See Context.md §13.
private struct BaselineTracker: View {
    let audio: AudioEngineController
    @Binding var baselineDB: Float?

    var body: some View {
        Color.clear
            .onChange(of: audio.diagnostics.currentLevelDB, initial: true) { _, level in
                baselineDB = min(baselineDB ?? level, level)
            }
    }
}

private enum MeterState {
    case quiet, elevated, tooLoud

    var color: Color {
        switch self {
        case .quiet:    return .green
        case .elevated: return .orange
        case .tooLoud:  return .red
        }
    }

    var caption: String {
        switch self {
        case .quiet:    return "Nice and quiet"
        case .elevated: return "Getting a bit loud — try to stay still and quiet"
        case .tooLoud:  return "Too much sound — this run will likely fail"
        }
    }
}

/// Leaf view isolating the live level meter's 15 Hz reads so only this small
/// view re-renders per update, not the whole calibration sheet.
private struct MicLevelMeterView: View {
    let audio: AudioEngineController
    let baselineDB: Float?

    /// Green at the room's own observed quiet floor, sliding through orange
    /// and into red as the level climbs through `MicCalibrator`'s own
    /// elevated-level margin — so red here means "this is heading for the
    /// same 'too much sound' rejection the actual check applies," not an
    /// arbitrary separate scale.
    private var state: MeterState {
        let level = audio.diagnostics.currentLevelDB
        let baseline = baselineDB ?? level
        let fraction = min(1, max(0, (level - baseline) / MicCalibrator.transientMarginDB))
        if fraction < 1.0 / 3.0 { return .quiet }
        if fraction < 2.0 / 3.0 { return .elevated }
        return .tooLoud
    }

    var body: some View {
        let level = AudioLevel.normalized(audio.diagnostics.currentLevelDB)
        let state = state
        return VStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(state.color)
                        .frame(width: geo.size.width * level)
                        .animation(.easeInOut(duration: 0.15), value: state.color)
                }
            }
            .frame(height: 8)
            Text(state.caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: 240)
    }
}
