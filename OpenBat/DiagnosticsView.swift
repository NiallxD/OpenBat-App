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
                VStack(spacing: 20) {
                    statusLine
                    diagnosticsCard
                    levelMeter
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

    private var statusLine: some View {
        Text(audio.status)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diagnosticsCard: some View {
        let d = audio.diagnostics
        return VStack(spacing: 12) {
            row("Input", d.inputName, badge: d.isUSBInput ? "USB" : nil)
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

    private var levelMeter: some View {
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

