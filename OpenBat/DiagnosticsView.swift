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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    statusLine
                    diagnosticsCard
                    levelMeter
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
                "Sample rate",
                d.actualSampleRate > 0 ? "\(Int(d.actualSampleRate)) Hz" : "—",
                emphasis: d.isNativeRate ? .green : (d.actualSampleRate > 0 ? .orange : .secondary)
            )
            Divider()
            row("Channels", d.channelCount > 0 ? "\(d.channelCount)" : "—")
            Divider()
            row("Buffers", "\(d.bufferCount)")
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
