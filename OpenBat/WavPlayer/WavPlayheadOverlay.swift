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

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                if let x = playheadX(width: geo.size.width) {
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
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
        let currentSample = engine.currentTimeSeconds * engine.sampleRate
        let frac = (currentSample - Double(viewport.startSample)) / Double(viewport.sampleSpan)
        guard frac >= 0, frac <= 1 else { return nil }   // playhead outside the visible window
        return CGFloat(frac) * width
    }
}
