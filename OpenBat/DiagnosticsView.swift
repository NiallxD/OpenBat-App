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
    @Environment(\.dismiss) private var dismiss
    @State private var logCleared = false

    var body: some View {
        NavigationStack {
            ScrollView {
                // Diagnostics/level meter read `audio.diagnostics`, which updates at
                // ~15 Hz — pulled into their own leaf views (below) rather than read
                // directly here, so that churn doesn't force this whole body (and the
                // Share/Clear/Done buttons/toolbar it contains) to re-render on every
                // update. Same @Observable-churn fix as ContentView's RecordButton —
                // see CLAUDE.md.
                VStack(spacing: 20) {
                    DiagnosticsStatusLine(audio: audio)
                    DiagnosticsCard(audio: audio, recorder: recorder)
                    DiagnosticsLevelMeter(audio: audio)
                    logSection
                }
                .padding()
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
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

