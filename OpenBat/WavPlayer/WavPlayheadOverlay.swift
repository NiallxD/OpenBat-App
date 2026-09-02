//
//  WavPlayheadOverlay.swift
//  OpenBat
//
//  Draws the current playback position as a vertical line over the
//  spectrogram — a separate leaf View reading `engine.currentTimeSeconds`
//  inside its OWN `TimelineView`, per the same isolation rule
//  PlaybackScrubberView and PulseStatsViews.PulseStatsRow already document:
//  `PlaybackDriver.onProgress` posts `currentTimeSeconds` at ~20-25 Hz during
//  playback, and reading it inline in a parent's `body` would invalidate that
//  ENTIRE body at that rate — poisoning the zoom/pan gesture state and
//  CallAnalysisPanel one level up. Only a distinct View struct with its own
//  independently-tracked body evaluation avoids that (see Context.md §13).
//

import SwiftUI

struct WavPlayheadOverlay: View {
    let engine: PlaybackEngine
    let viewport: WavViewport
    /// Display-domain total (virtual while hide-silence is on) — lets the
    /// pinned-centre playback line detect when the viewport is clamped at a
    /// file edge and can't actually be centred (see `playheadX`).
    let totalSamples: Int
    /// The live playback position. Read HERE rather than by the parent for
    /// the reason `PlaybackFollowState` documents: the parent must not
    /// re-render at the follow loop's rate.
    let followState: PlaybackFollowState

    var body: some View {
        GeometryReader { geo in
            // Paused when not playing: this drove a 30 Hz redraw for the whole
            // life of the screen, including while nothing was moving. A seek
            // still updates the line, because reading `currentTimeSeconds`
            // below observes it directly.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !engine.isPlaying)) { _ in
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
        // **Everything below asks the LIVE viewport, not the committed one.**
        // `viewport` deliberately stops updating during playback — the follow
        // loop writes `followState` instead, so the parent doesn't re-render
        // at 30 Hz — so it describes where the view was before playback
        // started, not where it is. `WavAxisOverlay` was given this same fix;
        // this was missed.
        //
        // It matters for BOTH decisions here, which is the part I got wrong
        // first time by only fixing the second. Asking the committed viewport
        // whether the view is clamped answers for the wrong moment: if the
        // view happened to sit mid-recording when play was pressed, the pin
        // below applied for the whole playthrough — including at the start
        // and end, where the view genuinely cannot centre. The line then sat
        // frozen at the middle while the image stopped moving under it.
        let live = engine.isPlaying
            ? WavViewportMath.recentered(viewport, on: followState.displaySample,
                                         totalSamples: totalSamples)
            : viewport

        // Pinned only while the view can actually be centred on the play
        // position. At either end of the recording it cannot — the viewport
        // is clamped against the file edge — so the image holds still and the
        // line travels across it instead: in from the left at the start, out
        // to the right at the end.
        if engine.isPlaying, live.startSample > 0, live.endSample < totalSamples {
            return width / 2
        }
        // No domain mapping: the engine reports its position on whichever
        // timeline it is playing — compressed while silence removal is on —
        // and that is the same timeline `viewport` is in. See
        // PlaybackEngine.setSilenceMap.
        let currentSample = engine.currentTimeSeconds * engine.sampleRate
        let frac = (currentSample - Double(live.startSample)) / Double(live.sampleSpan)
        guard frac >= 0, frac <= 1 else { return nil }   // playhead outside the visible window
        return CGFloat(frac) * width
    }
}
