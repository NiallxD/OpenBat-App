//
//  PlaybackZoom.swift
//  OpenBat
//
//  The one thing playback is allowed to say about the viewport: how much
//  time is across the screen.
//
//  **Why playback clamps the zoom at all.** Before this, playing a recording
//  scrolled whatever zoom the user happened to have left behind — anything
//  from the whole file to a single call. Every part of the machinery that
//  keeps a sharp picture under a moving playhead therefore had to work at an
//  arbitrary, unknown scale: the pyramid level changed underfoot, the tile
//  span in real seconds changed with it, and the render-vs-runway race in
//  `WavSpectrogramView.scheduleDetailRenderThrottled` had to be solved from
//  measurements taken live because nothing about the situation was known in
//  advance. Fixing the span to one number turns all of that into two
//  situations that can be prepared for.
//
//  **The number is wall-clock seconds of LISTENING, not of recording.** In
//  heterodyne the two are the same thing: the file plays at its own rate, so
//  a 1.5 s window is 1.5 s of recording. In time expansion the recording is
//  played `expansionFactor` times slower, so the same 1.5 s of listening is
//  1.5/N seconds of recording — which is the zoom you want there anyway,
//  since the whole reason to slow a pass down is to look at the calls in it.
//  One setting, two zoom levels, and the picture scrolls past the ear at the
//  same speed in both.
//

import Foundation

enum PlaybackZoom {

    /// Seconds of listening across the screen while playing. 1.5 s is enough
    /// to hold several pulses of a typical pass at real time, and — divided
    /// by the expansion factor — lands on a single call in time expansion.
    /// Adjustable from the player's tuning panel; see `windowRange`.
    static let defaultWindowSeconds: Double = 1.5

    /// What the tuning slider spans. The floor is well clear of
    /// `WavViewportMath.minSampleSpan` at every supported rate, and the
    /// ceiling is about as much as can be on screen before individual calls
    /// stop being resolvable at all.
    static let windowRange: ClosedRange<Double> = 0.25...6.0

    /// Seconds of RECORDING across the screen for a given listening window —
    /// the conversion the whole file exists for (see the header).
    ///
    /// Only `.timeExpansion` slows the file down. `.heterodyne` mixes down in
    /// real time, `.off` doesn't play at all (the view still scrolls at the
    /// file's own rate), and `.snippetExpansion` is a live-capture mode that
    /// never reaches this player — all three run at 1:1.
    static func recordedSpanSeconds(windowSeconds: Double, mode: ListenMode,
                                    expansionFactor: Double) -> Double {
        let slowdown = mode == .timeExpansion ? max(expansionFactor, 1) : 1
        return max(windowSeconds, windowRange.lowerBound) / slowdown
    }

    /// The same thing in display-domain samples, clamped to what a viewport
    /// can actually hold. Works unchanged on the compressed (hide-silence)
    /// timeline: playback walks the kept regions at the file's own rate, so a
    /// virtual sample still lasts `1/sampleRate` of a second.
    static func spanSamples(windowSeconds: Double, mode: ListenMode, expansionFactor: Double,
                            sampleRate: Double, totalSamples: Int) -> Int {
        guard sampleRate > 0, totalSamples > 0 else { return max(totalSamples, 0) }
        let seconds = recordedSpanSeconds(windowSeconds: windowSeconds, mode: mode,
                                          expansionFactor: expansionFactor)
        let raw = Int((seconds * sampleRate).rounded())
        return min(max(raw, WavViewportMath.minSampleSpan), totalSamples)
    }

    /// `viewport` re-centred on `center` at exactly the playback span — the
    /// single call every clamp in the player goes through, so the value the
    /// follow loop displays, the value a gesture is snapped back to, and the
    /// value the tile prefill is levelled against are the same by
    /// construction rather than by three agreeing calculations.
    ///
    /// The frequency window is deliberately left alone: playback fixes the
    /// TIME axis only, and how much of the band you're looking at stays the
    /// user's to set, playing or not.
    static func clamped(_ viewport: WavViewport, center: Int, spanSamples: Int,
                        totalSamples: Int) -> WavViewport {
        WavViewportMath.recentered(viewport, on: center, totalSamples: totalSamples,
                                   span: spanSamples)
    }
}
