//
//  DiagnosticsView.swift
//  OpenBat
//
//  The capture diagnostics panel, presented as a sheet from the main screen's
//  toolbar. Confirms the Griff stream is live at its native rate and shows the
//  input level meter.
//

import SwiftUI

struct DiagnosticsView: View {
    let audio: AudioEngineController
    let recorder: AudioRecorder
    let classStore: ClassificationStore
    /// Start a demo feed with the chosen file. Owned by ContentView, which also
    /// has to stop detection and clear the session — see `startDemo` there.
    let onStartDemo: (URL, String) -> Void
    let onEndDemo: () -> Void
    /// Opens the floating live tuning card over the detector screen. Dismisses
    /// this sheet on the way — the card is useless behind a sheet, which also
    /// pauses the render loop it needs running.
    let onOpenTuning: () -> Void
    /// Captures every live tunable + persisted setting and writes it to a file,
    /// returning the URL. Owned by ContentView, which is the only place holding
    /// all the processors and the AutoID settings at once — see `dumpSettings`
    /// there.
    let onDumpSettings: () -> URL?
    @Environment(\.dismiss) private var dismiss
    @State private var logCleared = false
    @State private var showDemoPicker = false
    /// Last file written by the dump button, so it can be shared without
    /// re-capturing (a second capture would be a different moment in time).
    @State private var dumpedFile: URL?
    @State private var dumpFailed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // Diagnostics/level meter read `audio.diagnostics`, which updates at
                // ~15 Hz — pulled into their own leaf views (below) rather than read
                // directly here, so that churn doesn't force this whole body (and the
                // Share/Clear/Done buttons/toolbar it contains) to re-render on every
                // update. Same @Observable-churn fix as ContentView's RecordButton —
                // see Context.md §13.
                VStack(spacing: 20) {
                    DiagnosticsStatusLine(audio: audio)
                    DiagnosticsCard(audio: audio, recorder: recorder)
                    DiagnosticsLevelMeter(audio: audio)
                    DiagnosticsMicQualityCard(audio: audio)
                    demoSection
                    tuningSection
                    settingsDumpSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(isPresented: $showDemoPicker) {
                DemoModeView(classStore: classStore) { url, name in
                    // Close the whole sheet, not just this pushed page — the
                    // demo runs on the main screen behind it. `dismiss` here is
                    // the one from DiagnosticsView (the stack's root), so it
                    // takes the sheet down rather than popping the picker.
                    showDemoPicker = false
                    dismiss()
                    onStartDemo(url, name)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Demo mode entry/exit. A single button that swaps to "End Demo" while a
    /// demo is running — the only in-app way out (short of quitting), which is
    /// deliberate: demo mode should never end by itself and leave someone
    /// believing they're looking at live audio.
    @ViewBuilder
    private var demoSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Demo Mode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let name = audio.demoFileName {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if audio.isDemoMode {
                Button(role: .destructive) {
                    onEndDemo()
                } label: {
                    Label("End Demo", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("The microphone is not in use. Ending the demo returns to live capture; it does not restart detection.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    showDemoPicker = true
                } label: {
                    Label("Demo", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                Text("Feed a recording through the detector instead of the microphone.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Entry point for the live tuning card. Available during a demo and during
    /// live capture — tuning against real bats matters as much as tuning against
    /// the demo clip; the demo is just the repeatable case.
    private var tuningSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Live Tuning")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                dismiss()
                onOpenTuning()
            } label: {
                Label("Open Tuning Panel", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Text("A floating panel of live controls over the detector. The spectrogram and audio keep running, so changes are heard and seen as you make them. Drag it out of the way; close it from its own ✕.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Writes the current value of every slider, toggle and per-species prior to
    /// a JSON file so a tuning session can be turned into code defaults without
    /// transcribing knob positions by hand. Deliberately captures on tap rather
    /// than continuously — the file is meant to be a dated record of one
    /// configuration, not a live mirror.
    private var settingsDumpSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Settings Snapshot")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Button {
                dumpFailed = false
                if let url = onDumpSettings() {
                    dumpedFile = url
                } else {
                    dumpedFile = nil
                    dumpFailed = true
                }
            } label: {
                Label("Dump Settings to File", systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            if let dumpedFile {
                ShareLink(item: dumpedFile) {
                    Label(dumpedFile.lastPathComponent, systemImage: "square.and.arrow.up")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Text(dumpFailed
                 ? "Couldn't write the file."
                 : "Every tuning slider, display preference and per-species prior, as JSON in Documents. Tap again for a fresh, separately-timestamped capture.")
                .font(.caption2)
                .foregroundStyle(dumpFailed ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private var logSection: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Classifier Log")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(logFileSize())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ShareLink(item: ClassificationLogger.shared.fileURL) {
                    Label("Share CSV", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(role: .destructive) {
                    ClassificationLogger.shared.clearLog()
                    logCleared = true
                } label: {
                    Label(logCleared ? "Cleared" : "Clear Log", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func logFileSize() -> String {
        let url = ClassificationLogger.shared.fileURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return "no log yet" }
        return size < 1024 ? "\(size) B" : String(format: "%.1f KB", Double(size) / 1024)
    }

}

/// Leaf view isolating `audio.status` reads — see the churn note in `DiagnosticsView.body`.
private struct DiagnosticsStatusLine: View {
    let audio: AudioEngineController

    var body: some View {
        Text(audio.status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Leaf view isolating `audio.diagnostics`/`recorder.lastWrittenSampleRate` reads — see
/// the churn note in `DiagnosticsView.body`.
private struct DiagnosticsCard: View {
    let audio: AudioEngineController
    let recorder: AudioRecorder

    var body: some View {
        let d = audio.diagnostics
        return VStack(spacing: 12) {
            row("Input", d.inputName, badge: d.isUSBInput ? "USB" : nil)
            Divider()
            // Both shown raw, unsanitized, so the values a real microphone
            // reports can be inspected directly — the only reliable way to
            // confirm a given mic doesn't put a serial in its product string.
            // Neither is ever contributed in this form (see
            // AnonymizedUploadBuilder.sanitizedHardwareName); the UID is never
            // contributed at all.
            row("Input contributed as", AnonymizedUploadBuilder.sanitizedHardwareName(d.inputName))
            Divider()
            row("Input UID (local only)", d.inputUID)
            Divider()
            row(
                "Session rate",
                d.sessionSampleRate > 0 ? "\(Int(d.sessionSampleRate)) Hz" : "—",
                emphasis: d.sessionSampleRate >= 60_000 ? .green : (d.sessionSampleRate > 0 ? .orange : .secondary)
            )
            Divider()
            row(
                "Capture rate",
                d.actualSampleRate > 0 ? "\(Int(d.actualSampleRate)) Hz" : "—",
                emphasis: d.isNativeRate ? .green : (d.actualSampleRate > 0 ? .orange : .secondary)
            )
            Divider()
            row("Channels", d.channelCount > 0 ? "\(d.channelCount)" : "—")
            Divider()
            row("Buffers", "\(d.bufferCount)")
            if recorder.lastWrittenSampleRate > 0 {
                Divider()
                row(
                    "Written rate",
                    "\(Int(recorder.lastWrittenSampleRate)) Hz",
                    emphasis: recorder.lastWrittenSampleRate >= 192_000 ? .green : .orange
                )
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(
        _ label: String,
        _ value: String,
        badge: String? = nil,
        emphasis: Color = .primary
    ) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.2), in: Capsule())
            }
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(emphasis)
        }
    }
}

/// Leaf view isolating the mic-QA fields of `audio.diagnostics` — see the churn
/// note in `DiagnosticsView.body`. Numbers accumulate since the current
/// capture started (`AudioEngineController.resetSessionStats()`), so run a
/// fixed, repeatable test (e.g. N seconds quiet, then N seconds of a known
/// loud source) per unit to keep readings comparable across microphones.
private struct DiagnosticsMicQualityCard: View {
    let audio: AudioEngineController

    var body: some View {
        let d = audio.diagnostics
        return VStack(spacing: 12) {
            HStack {
                Text("Mic QA (this session)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            row(
                "Noise floor",
                d.totalSampleCount > 0 ? String(format: "%.0f dBFS", d.noiseFloorDB) : "—",
                emphasis: d.totalSampleCount == 0 ? .secondary : (d.noiseFloorDB <= -50 ? .green : .orange)
            )
            Divider()
            row(
                "Peak level",
                d.totalSampleCount > 0 ? String(format: "%.0f dBFS", d.peakLevelDB) : "—",
                emphasis: d.totalSampleCount == 0 ? .secondary : (d.peakLevelDB < -3 ? .green : .orange)
            )
            Divider()
            row(
                "DC offset",
                d.totalSampleCount > 0 ? String(format: "%.2f%%", d.dcOffsetPercent) : "—",
                emphasis: d.totalSampleCount == 0 ? .secondary : (abs(d.dcOffsetPercent) < 1 ? .green : .red)
            )
            Divider()
            row(
                "Clipped samples",
                d.totalSampleCount > 0
                    ? "\(d.clippedSampleCount) (\(String(format: "%.3f%%", d.clipRate * 100)))"
                    : "—",
                emphasis: d.clippedSampleCount == 0 ? .green : .red
            )
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ label: String, _ value: String, emphasis: Color = .primary) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(emphasis)
        }
    }
}

/// Leaf view isolating `audio.diagnostics.currentLevelDB` reads — see the churn note
/// in `DiagnosticsView.body`.
private struct DiagnosticsLevelMeter: View {
    let audio: AudioEngineController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Input level")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: AudioLevel.normalized(audio.diagnostics.currentLevelDB))
                .tint(.green)
            Text(String(format: "%.0f dBFS", audio.diagnostics.currentLevelDB))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

