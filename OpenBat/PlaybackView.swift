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
    /// Called when the share button is tapped — the palette control moved to
    /// the spectrogram header pill (see WavPlayerView), and this slot now
    /// exports the recording.
    let onShare: () -> Void
    /// Landscape uses a tighter vertical footprint so the short-height
    /// spectrogram keeps as much room as possible; portrait keeps the roomier
    /// spacing.
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 40) {
            listenModeButton
            playPauseButton
            shareButton
        }
        .padding(.vertical, compact ? 6 : 16)
    }

    private var shareButton: some View {
        Button(action: onShare) {
            VStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up").font(.title2)
                Text("Share").font(.caption2)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Export recording")
    }

    /// True once playback has run to the end and stopped — the transport
    /// button then offers "replay" (tapping `togglePlaying`/`play` restarts
    /// from 0, see PlaybackEngine.play) rather than a plain play.
    private var atEnd: Bool {
        !engine.isPlaying && engine.durationSeconds > 0
            && engine.currentTimeSeconds >= engine.durationSeconds
    }

    private var playPauseButton: some View {
        Button {
            engine.togglePlaying()
        } label: {
            Image(systemName: engine.isPlaying
                  ? "pause.circle.fill"
                  : (atEnd ? "arrow.counterclockwise.circle.fill" : "play.circle.fill"))
                .font(.system(size: 54))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.batAccent)
        .accessibilityLabel(engine.isPlaying ? "Pause" : (atEnd ? "Replay" : "Play"))
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

    // Shown as the visible label under the mode icon (unlike the live
    // Detector button, which is icon-only), so the compact "RTE" keeps the
    // row neat and matches the "Heterodyne / RTE" wording in this screen's
    // tuning popover and Settings.
    private var listenModeName: String {
        switch engine.listenMode {
        case .off:           "Off"
        case .heterodyne:    "Heterodyne"
        case .timeExpansion: "RTE"
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
