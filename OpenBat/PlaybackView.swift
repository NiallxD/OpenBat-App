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
import UniformTypeIdentifiers

// MARK: - List

struct PlaybackListView: View {
    @Bindable var store: ClassificationStore
    let micCalSettings: MicCalibrationSettings
    let consent: ConsentStore

    /// Shared with SessionsView/RecordingDetailView via the same UserDefaults key.
    @AppStorage("display.showNoID") private var showNoID = false
    @State private var showImporter = false
    @State private var importError: String?
    @State private var isImporting = false

    /// Every visible recording, bucketed by session (nil = the Listening
    /// pseudo-session) and sorted newest-first within each bucket.
    ///
    /// Grouped in ONE pass rather than per-section: this used to filter the whole
    /// `store.recordings` array once per session (plus once more for the
    /// "everything is NoID" check), which is O(sessions × recordings) of main-thread
    /// work on every single redraw of this screen — and it re-ran for each of the
    /// dozens of `@Observable` recordings changes an upload sweep or a fresh sync
    /// produces.
    private var grouped: [UUID?: [Recording]] {
        Dictionary(grouping: store.recordings.filteredByNoID(showNoID: showNoID),
                   by: \.sessionID)
            .mapValues { $0.sorted { $0.date > $1.date } }
    }

    var body: some View {
        let grouped = grouped
        Group {
            if store.recordings.isEmpty {
                ContentUnavailableView(
                    "No recordings yet",
                    systemImage: "play.circle",
                    description: Text("Recordings you make (see the record button, or a session's auto-record setting) appear here for playback.")
                )
            // Dictionary lookups, not another filtering pass — and keyed the same
            // way the sections below are, so a recording orphaned behind a
            // sessionID with no session still counts as "nothing to show" rather
            // than suppressing this message for a list that renders empty.
            } else if grouped[nil] == nil && store.sessions.allSatisfy({ grouped[$0.id] == nil }) {
                ContentUnavailableView(
                    "No classified recordings",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Every recording is unclassified (NoID) — tap the filter icon to show them.")
                )
            } else {
                List {
                    if let recordings = grouped[nil], !recordings.isEmpty {
                        Section("Listening") {
                            ForEach(recordings) { recording in
                                NavigationLink {
                                    // Lazy: WavPlayerView's `@State` engine is
                                    // expensive to construct — see LazyDestination.
                                    LazyDestination {
                                        WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings)
                                    }
                                } label: {
                                    RecordingRow(recording: recording, store: store, consent: consent)
                                }
                            }
                            .onDelete { offsets in offsets.map { recordings[$0] }.forEach(store.delete) }
                        }
                    }
                    // `store.sessions` is already newest-first.
                    ForEach(store.sessions) { session in
                        let recordings = grouped[session.id] ?? []
                        if !recordings.isEmpty {
                            Section(session.title) {
                                ForEach(recordings) { recording in
                                    NavigationLink {
                                        LazyDestination {
                                            WavPlayerView(recording: recording, store: store, micCalSettings: micCalSettings)
                                        }
                                    } label: {
                                        RecordingRow(recording: recording, store: store, consent: consent)
                                    }
                                }
                                .onDelete { offsets in offsets.map { recordings[$0] }.forEach(store.delete) }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        // See SessionsView's identical fix: forces an opaque nav bar instead of the
        // default translucent Liquid Glass material sampling this List's background.
        .toolbarBackground(Color(.systemBackground), for: .navigationBar)
        .flatTopScrollEdge()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // Import an external WAV — the only way to audition a known bat
                // call through the listening modes without a live bat, since
                // WavPlayerView drives the real DSP from the file at its native
                // rate. See RecordingImporter.
                Button {
                    showImporter = true
                } label: {
                    if isImporting {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(isImporting)
                .accessibilityLabel("Import a recording")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showNoID.toggle()
                } label: {
                    Image(systemName: showNoID ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        .foregroundStyle(showNoID ? .blue : .primary)
                }
                .accessibilityLabel(showNoID ? "Hide unclassified recordings" : "Show unclassified recordings")
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.wav, .aiff, .audio],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importAll(urls)
            case .failure(let error): importError = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: .init(get: { importError != nil },
                                                  set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    /// Copies each picked file, then renders thumbnails and registers them.
    ///
    /// The copy runs RIGHT HERE, synchronously, still inside the `.fileImporter`
    /// completion handler — the sandbox extension the picker grants doesn't
    /// survive a hop onto another task, and doing the copy there instead made
    /// every import fail with a permissions error. Only the FFT-heavy overview
    /// render is deferred, and by then the file is in our own container.
    private func importAll(_ urls: [URL]) {
        var copied: [RecordingImporter.Copied] = []
        var failures: [String] = []
        for url in urls {
            do {
                copied.append(try RecordingImporter.copyIntoLibrary(source: url))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // A NOID recording is hidden by the list's own filter, so an import
        // would otherwise land invisibly with the filter off. Reveal it rather
        // than leaving the user to wonder where the file went — but only when
        // something actually came in unclassified, since a file whose GUANO
        // named a species is visible anyway and silently changing the user's
        // filter preference for it would be gratuitous. Set before the async
        // work so the row is visible the moment it is inserted.
        if copied.contains(where: { $0.species == "NOID" }) { showNoID = true }

        guard !copied.isEmpty else {
            reportImport(failures: failures)
            return
        }

        isImporting = true
        Task {
            for file in copied {
                let image = await Task.detached(priority: .userInitiated) {
                    RecordingImporter.renderOverview(at: file.url)
                }.value
                // Species/confidence/pulses/coordinate come from the file's own
                // GUANO chunk when it has one, so re-importing an OpenBat export
                // round-trips rather than arriving as a dateless "NoID".
                //
                // `sessionID: nil` regardless: an import always lands in the
                // Listening bucket. Filing it into whichever survey session's time
                // window happens to contain its timestamp — which is what
                // RecordingMigration does, correctly, for WAVs this app recorded —
                // would silently alter that session's species list and map pins
                // using a file the user merely opened.
                store.addRecording(date: file.date,
                                   durationSeconds: file.durationSeconds,
                                   species: file.species,
                                   confidence: file.confidence,
                                   pulseCount: file.pulseCount,
                                   sessionID: nil, coordinate: file.coordinate,
                                   relativeWavPath: file.relativeWavPath,
                                   spectrogramImage: image)
            }
            isImporting = false
            reportImport(failures: failures)
        }
    }

    /// Surfaces import failures after a short delay. Presenting an alert while
    /// `.fileImporter` is still dismissing gets silently dropped by SwiftUI, so
    /// a failure reported immediately never reaches the user at all — which is
    /// how the first version of this managed to fail completely silently.
    private func reportImport(failures: [String]) {
        guard !failures.isEmpty else { return }
        let message = failures.joined(separator: "\n\n")
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            importError = message
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

    /// Cycles Off → Heterodyne → Time expansion → Off. Time expansion is
    /// playback-only (see ListenMode's doc comment), so it only appears in
    /// this cycle, not the live Detector's off/heterodyne toggle.
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
        case .off:                  .heterodyne
        case .heterodyne:           .timeExpansion
        case .timeExpansion:        .off
        // Live-only mode; never reached from this playback cycle, but handled
        // explicitly rather than via `default:` so ListenMode stays exhaustively
        // checked here too.
        case .adaptiveTimeExpansion: .off
        }
    }

    private var listenIcon: String {
        switch engine.listenMode {
        case .off:                  "headphones"
        case .heterodyne:           "antenna.radiowaves.left.and.right"
        case .timeExpansion:        "tortoise"
        case .adaptiveTimeExpansion: "tortoise"
        }
    }

    private var listenModeName: String {
        switch engine.listenMode {
        case .off:                  "Off"
        case .heterodyne:            "Heterodyne"
        case .timeExpansion:        "Time exp"
        case .adaptiveTimeExpansion: "Time exp"
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
