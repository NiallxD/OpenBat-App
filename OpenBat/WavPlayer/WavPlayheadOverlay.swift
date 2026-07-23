//
//  WavPlayheadOverlay.swift
//  OpenBat
//
//  Draws the current playback position as a vertical line over the
//  spectrogram — a separate leaf View reading `engine.currentTimeSeconds`
//  inside its OWN `TimelineView`, per the same isolation rule
//  PlaybackScrubberView and PulseStatsViews.SpeciesStatCell already document:
//  `PlaybackDriver.onProgress` posts `currentTimeSeconds` at ~20-25 Hz during
//  playback, and reading it inline in a parent's `body` would invalidate that
//  ENTIRE body at that rate — poisoning the zoom/pan gesture state and
//  CallAnalysisPanel one level up. Only a distinct View struct with its own
//  independently-tracked body evaluation avoids that (see CLAUDE.md's
//  "@Observable churn bug class" note).
//

import SwiftUI

struct WavPlayheadOverlay: View {
    let engine: PlaybackEngine
    let viewport: WavViewport
    /// Non-nil while hide-silence is on: `viewport` is then in VIRTUAL
    /// (compressed-timeline) samples, and the engine's real playback
    /// position must be mapped into that domain before positioning the line.
    let silenceMap: SilenceMap?
    /// Display-domain total (virtual while hide-silence is on) — lets the
    /// pinned-centre playback line detect when the viewport is clamped at a
    /// file edge and can't actually be centred (see `playheadX`).
    let totalSamples: Int

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                if let x = playheadX(width: geo.size.width) {
                    Rectangle()
                        .fill(Color.batAccent)
                        .frame(width: 1.5)
                        .position(x: x, y: geo.size.height / 2)
                        .frame(height: geo.size.height)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func playheadX(width: CGFloat) -> CGFloat? {
        guard viewport.sampleSpan > 0, width > 0 else { return nil }
        // While playing, WavPlayerView's follow loop keeps the viewport
        // centred on the play position, so PIN the line to the exact centre.
        // Deriving it from `viewport` vs `currentTimeSeconds` (as the paused
        // case does) instead read a viewport that lags the play time by up
        // to one 20Hz follow tick, so the line sawtoothed around centre
        // every tick — that was the "playhead jitters" bug. Pinned, the line
        // is rock-steady and the spectrogram scrolls beneath it, and the
        // content passing under the centre line is exactly what's audible.
        // At the very start/end the viewport is clamped and genuinely can't
        // centre, so fall through to the true position there.
        if engine.isPlaying, viewport.startSample > 0, viewport.endSample < totalSamples {
            return width / 2
        }
        let realSample = engine.currentTimeSeconds * engine.sampleRate
        let currentSample = silenceMap.map { Double($0.realToVirtual(Int(realSample))) } ?? realSample
        let frac = (currentSample - Double(viewport.startSample)) / Double(viewport.sampleSpan)
        guard frac >= 0, frac <= 1 else { return nil }   // playhead outside the visible window
        return CGFloat(frac) * width
    }
}
