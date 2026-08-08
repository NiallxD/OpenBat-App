//
//  DemoModeView.swift
//  OpenBat
//
//  File picker for demo mode: choose what feeds the pipeline in place of the
//  microphone. The bundled clip sits at the top as the default — it's hand
//  picked to be representative, which no arbitrary user recording is — with the
//  user's own recordings listed below for demoing against real local species.
//
//  Tapping a row starts the demo immediately (see `onSelect` in ContentView):
//  the demo is the point of opening this sheet, so a separate confirm step
//  would just be a tap in the way.
//

import SwiftUI

/// The bundled representative clip. Absent from a build that hasn't had the
/// file added yet, in which case the sheet quietly shows only user recordings
/// rather than a broken row.
enum BundledDemoRecording {
    /// Any `Demo*.wav` under `OpenBat/` is picked up: the project uses
    /// filesystem-synchronized groups, so dropping the file in needs no
    /// `project.pbxproj` edit, and resources from such a group are copied flat
    /// to the bundle root — the `Demo/` subfolder is tidiness only.
    ///
    /// Discovered by prefix rather than matched against a hardcoded name so the
    /// clip can be re-stitched and renamed (`Demo-MYCA-2026.wav`,
    /// `Demo-mixed-2027.wav`, …) without touching code. Sorted so a build that
    /// somehow ships two is deterministic about which one it offers.
    ///
    /// Any sample rate/channel count AVAudioFile can open will work — 384 kHz
    /// mono 16-bit matches what the app records and gives the demo the same
    /// Nyquist as a live Griff capture.
    private static let prefix = "Demo"

    static let title = "Demo Recording"

    static var url: URL? {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) else { return nil }
        return urls
            .filter { $0.deletingPathExtension().lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    /// Filename without extension, shown as the row's subtitle and used as the
    /// name the status line and mic explainer report. Deliberately not parsed
    /// for a species code: a stitched clip may hold several species, and a title
    /// inferred from the filename would then be confidently wrong.
    static var stem: String? {
        url?.deletingPathExtension().lastPathComponent
    }
}

/// Pushed onto the Diagnostics sheet's own `NavigationStack` rather than
/// presented as a second sheet — a sheet over a sheet re-animates the one
/// underneath and reads as a glitch. So this deliberately carries no
/// `NavigationStack`, no `presentationDetents` and no Cancel button: the
/// enclosing stack supplies the bar and the back button, and dismissing the
/// whole sheet on selection is the caller's job (see `DiagnosticsView`).
struct DemoModeView: View {
    let classStore: ClassificationStore
    /// Called with the file to feed and the name to display for it.
    let onSelect: (URL, String) -> Void

    var body: some View {
            List {
                if let bundled = BundledDemoRecording.url {
                    Section {
                        Button {
                            onSelect(bundled, BundledDemoRecording.stem ?? BundledDemoRecording.title)
                        } label: {
                            row(
                                title: BundledDemoRecording.title,
                                subtitle: BundledDemoRecording.stem ?? "Representative bat activity",
                                icon: "star.fill"
                            )
                        }
                    } header: {
                        Text("Default")
                    } footer: {
                        Text("Feeds this file into the detector in place of the microphone. Everything else — spectrogram, pulse detection, species ID and listening — runs exactly as it does live. Recording is disabled while a demo is running.")
                    }
                }

                Section("Your Recordings") {
                    if playableRecordings.isEmpty {
                        Text("No recordings yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(playableRecordings) { recording in
                            Button {
                                let url = CloudStorage.baseDirectory
                                    .appendingPathComponent(recording.relativeWavPath)
                                onSelect(url, recording.commonName)
                            } label: {
                                row(
                                    title: recording.commonName,
                                    subtitle: subtitle(for: recording),
                                    icon: "waveform"
                                )
                            }
                        }
                    }
                }
            }
            .navigationTitle("Demo Mode")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// `classStore.recordings` is already newest-first. Capped rather than
    /// unbounded: this is a demo picker, not the Sessions browser, and a device
    /// with thousands of recordings shouldn't build a thousand rows to find the
    /// one from last night.
    private var playableRecordings: [Recording] {
        Array(classStore.recordings.prefix(50))
    }

    private func subtitle(for recording: Recording) -> String {
        let date = recording.date.formatted(date: .abbreviated, time: .shortened)
        return "\(date) · \(String(format: "%.0f s", recording.durationSeconds))"
    }

    private func row(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
