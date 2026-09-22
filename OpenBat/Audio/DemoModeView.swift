//
//  DemoModeView.swift
//  OpenBat
//
//  File picker for demo mode: choose what feeds the pipeline in place of the
//  microphone. The bundled clip sits at the top as the default — it's hand
//  picked to be representative, which no arbitrary user recording is — with
//  the user's own FAVOURITED recordings listed below for demoing against real
//  local species. Favouriting (a star in the WAV player, next to Share) is
//  what puts a recording here — every recording used to qualify, which meant
//  scrolling months of fieldwork to find the clip worth demoing.
//
//  Tapping a row starts the demo immediately (see `onSelect` in ContentView):
//  the demo is the point of opening this sheet, so a separate confirm step
//  would just be a tap in the way.
//

import SwiftUI

/// The clips bundled with the app. Absent from a build that hasn't had any
/// added yet, in which case the sheet quietly shows only user recordings
/// rather than a broken row.
enum BundledDemoRecording {
    /// Any bundled `.wav` with "demo" in its name is picked up: the project
    /// uses filesystem-synchronized groups, so dropping a file in needs no
    /// `project.pbxproj` edit, and resources from such a group are copied flat
    /// to the bundle root — the `Demo/` subfolder is tidiness only.
    ///
    /// Matched on the name rather than a hardcoded list so a clip can be
    /// re-stitched and renamed (`Demo-MYCA-2026.wav`, `uk_demo_bats.wav`, …)
    /// without touching code. Case-insensitive and unanchored so neither
    /// capitalisation nor a prefix like `uk_` hides a file. Sorted so the order
    /// of the rows doesn't depend on bundle enumeration order.
    ///
    /// Any sample rate/channel count AVAudioFile can open will work — 384 kHz
    /// mono 16-bit matches what the app records and gives the demo the same
    /// Nyquist as a live Griff capture.
    private static let marker = "demo"

    /// Every bundled clip, not just the first: more than one ships, and a clip
    /// the build contains but the sheet never offers is indistinguishable from
    /// a clip that failed to bundle.
    static var urls: [URL] {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) else { return [] }
        return urls
            .filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains(marker) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Filename without extension, shown as the row's title and used as the
    /// name the status line and mic explainer report. Deliberately not parsed
    /// for a species code: a stitched clip may hold several species, and a title
    /// inferred from the filename would then be confidently wrong.
    static func stem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}

/// Pushed onto an enclosing `NavigationStack` rather than presented as a second
/// sheet — a sheet over a sheet re-animates the one underneath and reads as a
/// glitch. So this deliberately carries no `NavigationStack`, no
/// `presentationDetents` and no Cancel button: the enclosing stack supplies the
/// bar and the back button, and dismissing the whole sheet on selection is the
/// caller's job.
///
/// Two callers push it, and the ordinary one is `AppInfoView` — Info & Tour is
/// where someone who hasn't got a microphone yet goes looking. `DiagnosticsView`
/// keeps its own entry for support work.
struct DemoModeView: View {
    let classStore: ClassificationStore
    /// Called with the file to feed and the name to display for it.
    let onSelect: (URL, String) -> Void

    var body: some View {
            List {
                let bundled = BundledDemoRecording.urls
                if !bundled.isEmpty {
                    Section {
                        ForEach(bundled, id: \.self) { url in
                            Button {
                                onSelect(url, BundledDemoRecording.stem(for: url))
                            } label: {
                                row(
                                    title: BundledDemoRecording.stem(for: url),
                                    subtitle: "Representative bat activity",
                                    icon: "star.fill"
                                )
                            }
                        }
                    } header: {
                        Text(bundled.count == 1 ? "Default" : "Bundled Clips")
                    } footer: {
                        Text("Feeds this file into the detector in place of the microphone. Everything else — spectrogram, pulse detection, species ID and listening — runs exactly as it does live. Recording is disabled while a demo is running.")
                    }
                }

                Section {
                    if playableRecordings.isEmpty {
                        Text("No favourite recordings yet. Star one in the player to add it here.")
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
                } header: {
                    Text("Favourite Recordings")
                } footer: {
                    Text("Only recordings you've favourited (⭐ in the player) show up here, so the list stays short enough to actually pick from.")
                }
            }
            .pageBackground()
            .navigationTitle("Demo Mode")
            .navigationBarTitleDisplayMode(.inline)
    }

    /// Favourited recordings only (see `Recording.isFavorite`) — this used to
    /// be every recording, which meant a season of fieldwork was one long
    /// scroll to find the clip worth demoing. `classStore.recordings` is
    /// already newest-first; capped on top of the filter for the same reason
    /// the old list was capped: a device with hundreds of favourites
    /// shouldn't build hundreds of rows for a demo picker.
    private var playableRecordings: [Recording] {
        Array(classStore.recordings.filter(\.isFavorite).prefix(50))
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
