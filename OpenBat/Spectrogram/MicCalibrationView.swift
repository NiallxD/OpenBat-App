//
//  MicCalibrationView.swift
//  OpenBat
//
//  "Calibrate Microphone" sheet — reachable from Settings (reusing
//  ContentView's already-activated AudioEngineController) and from an
//  optional onboarding step (its own throwaway instance). Records ~30s
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

    private static let captureSeconds: Double = 30

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

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch stage {
                case .intro:               introContent
                case .recording:           recordingContent
                case .result(let result):  resultContent(result)
                }
            }
            .padding()
            .navigationTitle("Calibrate Microphone")
            .navigationBarTitleDisplayMode(.inline)
            .background(BaselineTracker(audio: audio, baselineDB: $baselineDB))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
            }
        }
        .interactiveDismissDisabled(isRecording)
        .onDisappear { teardownAudio() }
    }

    private var isRecording: Bool {
        if case .recording = stage { return true }
        return false
    }

    @ViewBuilder private var introContent: some View {
        Spacer()
        Image(systemName: "tuningfork")
            .font(.system(size: 56))
            .foregroundStyle(Color.batAccent)
        Text("Calibrate \(audio.diagnostics.inputName)")
            .font(.title2.bold())
            .multilineTextAlignment(.center)
        Text("Find a quiet spot — no bat calls, minimal wind or traffic noise — and we'll measure your microphone's natural response for about 30 seconds. This flattens the spectrogram's noise floor and sharpens frequency measurements. It doesn't change or upload any recording.")
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
        Spacer()
        Button("Start") { start() }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var recordingContent: some View {
        Spacer()
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
        .frame(width: 140, height: 140)
        Text("Recording — find somewhere quiet")
            .font(.headline)
        MicLevelMeterView(audio: audio, baselineDB: baselineDB)
        Spacer()
        Button("Cancel") { cancel() }
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func resultContent(_ result: MicCalibrator.Result) -> some View {
        Spacer()
        switch result {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Calibration saved for \(audio.diagnostics.inputName)")
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Spacer()
            Button("Done") { finish(saving: result) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        case .failure(let reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(reason)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Spacer()
            VStack(spacing: 12) {
                Button("Try Again") { start() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                Button("Cancel") { finish(saving: result) }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
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
            while t < Self.captureSeconds, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(step))
                t += step
                elapsed = t
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
/// 30-second capture. See Context.md §13.
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
