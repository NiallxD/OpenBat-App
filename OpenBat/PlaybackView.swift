//
//  PlaybackView.swift
//  OpenBat
//
//  Listen back to a saved Recording.
//    • PlaybackListView — every Recording, grouped by session ("Listening" pinned
//                         at the top as a pseudo-session, then real sessions
//                         newest-first) — same grouping shape as SessionsView.
//                         Pushes WavPlayerView (WavPlayer/WavPlayerView.swift) —
//                         the purpose-built static/zoomable spectrogram player,
//                         not the live Detector screen's scrolling view.
//
//  PlaybackControlsView below is engine-facing (not spectrogram-facing), so
//  WavPlayerView reuses it as-is for transport. Its scrub bar used to be a
//  separate Slider (PlaybackScrubberView) here; that's now WavMinimapView's
//  job instead (drag-to-scrub + playhead over the whole-file thumbnail).
//

import SwiftUI

// MARK: - List

struct PlaybackListView: View {
    @Bindable var store: ClassificationStore
    let rteSettings: RTESettings

    /// Shared with SessionsView/RecordingDetailView via the same UserDefaults key.
    @AppStorage("display.showNoID") private var showNoID = false

    private var listeningRecordings: [Recording] {
        store.listeningRecordings.filteredByNoID(showNoID: showNoID)
    }
    private func sessionRecordings(_ session: RecordingSession) -> [Recording] {
        store.recordings(inSession: session.id).filteredByNoID(showNoID: showNoID)
    }

    var body: some View {
        Group {
            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "play.circle",
                    description: Text("Recordings you make (see the record button, or a session's auto-record setting) appear here for playback.")
                )
            } else if listeningRecordings.isEmpty && store.sessions.allSatisfy({ sessionRecordings($0).isEmpty }) {
                ContentUnavailableView(
                    "No classified recordings",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Every recording is unclassified (NoID) — tap the filter icon to show them.")
                )
            } else {
                List {
                    if !listeningRecordings.isEmpty {
                        Section("Listening") {
                            ForEach(listeningRecordings.sorted { $0.date > $1.date }) { recording in
                                NavigationLink {
                                    WavPlayerView(recording: recording, store: store, rteSettings: rteSettings)
                                } label: {
                                    RecordingRow(recording: recording, store: store)
                                }
                            }
                        }
                    }
                    // `store.sessions` is already newest-first.
                    ForEach(store.sessions) { session in
                        let recordings = sessionRecordings(session).sorted { $0.date > $1.date }
                        if !recordings.isEmpty {
                            Section(session.title) {
                                ForEach(recordings) { recording in
                                    NavigationLink {
                                        WavPlayerView(recording: recording, store: store, rteSettings: rteSettings)
                                    } label: {
                                        RecordingRow(recording: recording, store: store)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Toggle(isOn: $showNoID) {
                    Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .toggleStyle(.button)
                .accessibilityLabel(showNoID ? "Hide unclassified recordings" : "Show unclassified recordings")
            }
        }
    }
}

// MARK: - Controls (leaf view)

/// The buttons row only — deliberately does NOT read `engine.currentTimeSeconds`
/// anywhere in its own `body`. `@Observable` tracks dependencies per `body`
/// evaluation, not per screen: a computed property that reads a high-rate field
/// still poisons whichever `body` calls it, even if that property lives
/// alongside other, unrelated views. `PlaybackScrubberView` below is a SEPARATE
/// View struct for exactly that reason — see its own doc comment.
struct PlaybackControlsView: View {
    @Bindable var engine: PlaybackEngine
    @Binding var palette: Palette

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 40) {
                listenModeButton
                playPauseButton
                paletteButton
            }
        }
        .padding(.vertical, 16)
    }

    private var playPauseButton: some View {
        Button {
            engine.togglePlaying()
        } label: {
            Image(systemName: engine.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 54))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.batAccent)
        .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")
    }

    /// Cycles Off → Heterodyne → Time expansion → Off, same order and icons as the
    /// live Detector screen's listen-mode button.
    private var listenModeButton: some View {
        Button {
            engine.listenMode = nextListenMode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: listenIcon).font(.title2)
                Text(listenModeName).font(.caption2)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .foregroundStyle(engine.listenMode == .off ? Color.secondary : Color.batAccent)
        .accessibilityLabel("Listen mode: \(listenModeName)")
    }

    /// Same iOS 26 FixedMenu workaround as the live Detector screen's palette
    /// Menu (ContentView.paletteButton): without the `GlassEffectContainer` +
    /// `.glassEffect(.identity)` wrapping, Liquid Glass hides this Menu's
    /// label the whole time it's open and then visibly fades/pulses it back
    /// in seconds after dismissal.
    private var paletteButton: some View {
        Group {
            if #available(iOS 26.0, *) {
                GlassEffectContainer {
                    paletteMenuContent {
                        paletteMenuLabel.glassEffect(.identity)
                    }
                    .clipped()
                }
            } else {
                paletteMenuContent { paletteMenuLabel }
            }
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel("Colour palette")
    }

    private var paletteMenuLabel: some View {
        VStack(spacing: 4) {
            Image(systemName: "paintpalette").font(.title2)
            Text("Palette").font(.caption2)
        }
        .frame(width: 64)
    }

    private func paletteMenuContent(@ViewBuilder label: () -> some View) -> some View {
        Menu {
            Picker("Palette", selection: $palette) {
                ForEach(Palette.allCases) { p in
                    Text(p.displayName).tag(p)
                }
            }
        } label: {
            label()
        }
    }

    private var nextListenMode: ListenMode {
        switch engine.listenMode {
        case .off:           .heterodyne
        case .heterodyne:    .timeExpansion
        case .timeExpansion: .off
        }
    }

    private var listenIcon: String {
        switch engine.listenMode {
        case .off:           "headphones"
        case .heterodyne:    "antenna.radiowaves.left.and.right"
        case .timeExpansion: "tortoise"
        }
    }

    // Spelled out (not "RTE") — same rationale as the live listen-mode button's
    // VoiceOver label: the visible cue is an icon, not text.
    private var listenModeName: String {
        switch engine.listenMode {
        case .off:           "Off"
        case .heterodyne:    "Heterodyne"
        case .timeExpansion: "Time expansion"
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
