//
//  PlaybackView.swift
//  OpenBat
//
//  Listen back to a saved Recording. Two screens:
//    • PlaybackListView   — every Recording, grouped by session ("Listening" pinned
//                           at the top as a pseudo-session, then real sessions
//                           newest-first) — same grouping shape as SessionsView.
//    • PlaybackPlayerView — spectrogram (top half, live-style scrolling Metal view
//                           fed by PlaybackEngine's own SpectrogramProcessor —
//                           same component the Detector screen uses) + transport
//                           controls (bottom half): play/pause, a Heterodyne/RTE/
//                           Off cycle button, and a colour-palette picker.
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
                                    PlaybackPlayerView(recording: recording, store: store, rteSettings: rteSettings)
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
                                        PlaybackPlayerView(recording: recording, store: store, rteSettings: rteSettings)
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

// MARK: - Player

struct PlaybackPlayerView: View {
    let recording: Recording
    @Bindable var store: ClassificationStore
    let rteSettings: RTESettings

    @State private var engine = PlaybackEngine()
    /// Shared with every other palette/log-scale control in the app (spectrogram/
    /// pulse view) — there's no live PulseDetector here to hang it off, so bind the
    /// same UserDefaults keys directly.
    @AppStorage("pulse.displayPalette") private var palette: Palette = .inferno
    @AppStorage("display.spectrogramLogFrequency") private var logFrequency = false
    /// Same frequency-band crop the live Heterodyne/RTE listening uses — applied to
    /// `engine.heterodyne`/`engine.timeExpansion` on load so a played-back file
    /// doesn't process the full spectrum when the user has narrowed the live band.
    @AppStorage("display.bandLow") private var bandLow = 0.0
    @AppStorage("display.bandHigh") private var bandHigh = 1.0

    var body: some View {
        VStack(spacing: 0) {
            spectrogramSection
                .frame(maxHeight: .infinity)

            Divider()

            PlaybackControlsView(engine: engine, palette: $palette)
                .frame(maxHeight: .infinity)
        }
        .navigationTitle(recording.commonName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.load(url: store.wavURL(for: recording))
            rteSettings.apply(to: engine.timeExpansion)
            engine.heterodyne.setBand(low: bandLow, high: bandHigh)
            engine.timeExpansion.setBand(low: bandLow, high: bandHigh)
        }
        .onDisappear { engine.stop() }
    }

    @ViewBuilder private var spectrogramSection: some View {
        if let loadError = engine.loadError {
            ContentUnavailableView("Can't play this recording", systemImage: "exclamationmark.triangle",
                                   description: Text(loadError))
                .padding(8)
        } else {
            SpectrogramView(processor: engine.spectrogramProcessor,
                            maxFrequency: max(engine.sampleRate / 2, 1),
                            pulseDetector: nil,
                            logFrequency: logFrequency,
                            palette: palette)
                .padding(8)
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
private struct PlaybackControlsView: View {
    @Bindable var engine: PlaybackEngine
    @Binding var palette: Palette

    var body: some View {
        VStack(spacing: 20) {
            PlaybackScrubberView(engine: engine)
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

/// Separate leaf, sibling to `PlaybackControlsView`'s buttons — NOT a computed
/// property on it. `PlaybackDriver.onProgress` posts `currentTimeSeconds` at
/// ~20-25 Hz during playback (once per ~43 ms audio chunk); reading it inside a
/// `body` invalidates that ENTIRE `body` at that rate. A computed property called
/// from another view's `body` still counts as part of that view's body — only a
/// distinct View struct gets its own independently-tracked `body` evaluation, so
/// this has to be its own type, not just its own computed var, or the play/pause
/// and palette-menu buttons one level up keep rebuilding out from under taps.
/// (Same bug class as ContentView's — see the openbat-observable-churn memory.)
private struct PlaybackScrubberView: View {
    @Bindable var engine: PlaybackEngine

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : engine.currentTimeSeconds },
                    set: { scrubValue = $0 }
                ),
                in: 0...max(engine.durationSeconds, 0.01),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { engine.seek(toSeconds: scrubValue) }
                }
            )
            HStack {
                Text(Self.timeString(isScrubbing ? scrubValue : engine.currentTimeSeconds))
                Spacer()
                Text(Self.timeString(engine.durationSeconds))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
