//
//  PlaybackView.swift
//  OpenBat
//
//  Transport controls for playing back a saved Recording.
//
//  This file used to open with PlaybackListView — a whole Playback tab listing
//  every Recording grouped by session. That was the same recordings in the same
//  buckets Sessions already showed, one tab over, and it is gone: a recording is
//  reached from Sessions now, and opens WavPlayerView
//  (WavPlayer/WavPlayerView.swift) — the purpose-built static/zoomable
//  spectrogram player, not the live Detector screen's scrolling view.
//
//  PlaybackControlsView below is engine-facing (not spectrogram-facing), so
//  WavPlayerView reuses it as-is for transport. Its scrub bar used to be a
//  separate Slider (PlaybackScrubberView) here; that's now WavMinimapView's
//  job instead (drag-to-scrub + playhead over the whole-file thumbnail).
//

import SwiftUI

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
    /// Prepares the hand-off to iNaturalist (`INatObservationSheet`). Optional
    /// so the older `PlaybackView` call site, which has no recording context to
    /// build an observation from, keeps a plain Share button.
    var onAddToINaturalist: (() -> Void)? = nil
    /// Landscape uses a tighter vertical footprint so the short-height
    /// spectrogram keeps as much room as possible; portrait keeps the roomier
    /// spacing.
    var compact: Bool = false

    /// The slowdowns the speed button cycles. Discrete stops rather than a
    /// slider: each is a clean ratio, and a stop you can tap through beats a
    /// value you have to aim at while listening.
    static let expansionFactors: [Double] = [4, 8, 16]

    var body: some View {
        // The speed stop only appears in time expansion, which is the only
        // mode a slowdown means anything in — heterodyne's downconversion is a
        // real-time operation. Spacing tightens when it does, so a four-item
        // row still fits a small phone.
        let showsSpeed = engine.listenMode == .timeExpansion
        HStack(spacing: showsSpeed ? 24 : 40) {
            listenModeButton
            if showsSpeed { speedButton }
            playPauseButton
            shareButton
        }
        .padding(.vertical, compact ? 6 : 16)
    }

    /// Cycles 4× → 8× → 16×. Changing it while playing is fine: the engine
    /// restarts its pacing from the current position (see
    /// PlaybackEngine.expansionFactor).
    private var speedButton: some View {
        Button {
            let factors = Self.expansionFactors
            let index = factors.firstIndex(of: engine.expansionFactor) ?? factors.firstIndex(of: 8) ?? 0
            engine.expansionFactor = factors[(index + 1) % factors.count]
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title2)
                Text(Self.speedLabel(engine.expansionFactor)).font(.caption2)
                    .monospacedDigit()
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.batAccent)
        .accessibilityLabel("Playback speed: \(Self.speedLabel(engine.expansionFactor)) slower than real time. Tap to change.")
    }

    /// Short enough for the 64pt button slot — the full phrase goes to
    /// VoiceOver instead.
    static func speedLabel(_ factor: Double) -> String {
        factor == factor.rounded() ? "\(Int(factor))×" : String(format: "%.1f×", factor)
    }

    /// A menu once there are two destinations for a recording: the raw bundle
    /// that has always been here, and the iNaturalist hand-off. Falls back to a
    /// plain button where only the former applies.
    @ViewBuilder
    private var shareButton: some View {
        if let onAddToINaturalist {
            Menu {
                Button {
                    onShare()
                } label: {
                    Label("Share Recording", systemImage: "waveform")
                }
                Button {
                    onAddToINaturalist()
                } label: {
                    Label("Add to iNaturalist…", systemImage: "leaf")
                }
            } label: {
                shareLabel
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Share recording")
        } else {
            Button(action: onShare) { shareLabel }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Export recording")
        }
    }

    private var shareLabel: some View {
        VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.up").font(.title2)
            Text("Share").font(.caption2)
        }
        .frame(width: 64)
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

    // `.snippetExpansion` is live-only — it captures from the microphone tap and
    // has no meaning against a file, which can already be expanded in full by
    // `.timeExpansion`. It is handled explicitly (rather than via `default:`) so
    // a future mode addition still has to be considered here, per the same
    // convention as `AudioEngineController.startEngine`.
    private var nextListenMode: ListenMode {
        switch engine.listenMode {
        case .off:                  .heterodyne
        case .heterodyne:           .timeExpansion
        case .timeExpansion:        .off
        case .snippetExpansion:     .off
        }
    }

    private var listenIcon: String {
        switch engine.listenMode {
        case .off:                  "headphones"
        case .heterodyne:           "antenna.radiowaves.left.and.right"
        case .timeExpansion:        "tortoise"
        case .snippetExpansion:     "tortoise"
        }
    }

    private var listenModeName: String {
        switch engine.listenMode {
        case .off:                  "Off"
        case .heterodyne:            "Heterodyne"
        case .timeExpansion:        "Time exp"
        case .snippetExpansion:     "Time exp"
        }
    }

    private static func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
