//
//  PlaybackZoomTests.swift
//  OpenBatTests
//
//  The two playback zoom levels, and the promise that there are only two —
//  see PlaybackZoom's header for why that is the whole point.
//

import Testing
import Foundation
@testable import OpenBat

struct PlaybackZoomTests {

    private let sampleRate = 384_000.0
    private let totalSamples = 384_000 * 30      // 30 s file

    /// Heterodyne plays at the file's own rate, so the listening window and
    /// the span of recording on screen are the same number.
    @Test func heterodyneShowsTheWindowItself() {
        let seconds = PlaybackZoom.recordedSpanSeconds(windowSeconds: 1.5, mode: .heterodyne,
                                                       expansionFactor: 8)
        #expect(abs(seconds - 1.5) < 1e-9)
    }

    /// Time expansion takes N times longer to listen to, so the same window
    /// holds N times less recording — the second of the two zoom levels.
    @Test func timeExpansionDividesByTheSpeed() {
        for factor in [4.0, 8.0, 16.0] {
            let seconds = PlaybackZoom.recordedSpanSeconds(windowSeconds: 1.5, mode: .timeExpansion,
                                                           expansionFactor: factor)
            #expect(abs(seconds - 1.5 / factor) < 1e-9)
        }
    }

    /// Silent playback still scrolls at the file's own rate, so it zooms like
    /// heterodyne rather than like expansion.
    @Test func listeningOffScrollsAtRealTime() {
        let off = PlaybackZoom.recordedSpanSeconds(windowSeconds: 1.5, mode: .off, expansionFactor: 8)
        #expect(abs(off - 1.5) < 1e-9)
    }

    @Test func spanIsTheWindowInSamples() {
        let span = PlaybackZoom.spanSamples(windowSeconds: 1.5, mode: .heterodyne, expansionFactor: 8,
                                            sampleRate: sampleRate, totalSamples: totalSamples)
        #expect(span == 576_000)
    }

    /// The deepest window the slider reaches, at the fastest expansion, must
    /// still be a viewport the renderer will accept — a span below
    /// `minSampleSpan` produces a one-column tile stretched across the screen
    /// (see WavViewportMath.minSampleSpan).
    @Test func fastestExpansionAtShortestWindowStaysRenderable() {
        let span = PlaybackZoom.spanSamples(windowSeconds: PlaybackZoom.windowRange.lowerBound,
                                            mode: .timeExpansion, expansionFactor: 16,
                                            sampleRate: sampleRate, totalSamples: totalSamples)
        #expect(span >= WavViewportMath.minSampleSpan)
    }

    /// A file shorter than the window shows all of itself rather than a
    /// viewport running off either end.
    @Test func shortFileIsNotOverZoomed() {
        let short = Int(0.4 * sampleRate)
        let span = PlaybackZoom.spanSamples(windowSeconds: 1.5, mode: .heterodyne, expansionFactor: 8,
                                            sampleRate: sampleRate, totalSamples: short)
        #expect(span == short)
    }

    /// The clamp fixes the time span and leaves the frequency window exactly
    /// as the user set it — playback owns one axis, not both.
    @Test func clampKeepsTheFrequencyWindow() {
        let committed = WavViewport(startSample: 0, endSample: totalSamples,
                                    minFreqHz: 15_000, maxFreqHz: 80_000)
        let clamped = PlaybackZoom.clamped(committed, center: 5_000_000, spanSamples: 576_000,
                                           totalSamples: totalSamples)
        #expect(clamped.sampleSpan == 576_000)
        #expect(clamped.minFreqHz == 15_000)
        #expect(clamped.maxFreqHz == 80_000)
        #expect((clamped.startSample + clamped.endSample) / 2 == 5_000_000)
    }

    /// Near either end of the recording the span is preserved and the window
    /// slides inward, rather than the span shrinking against the boundary —
    /// the same "clamp both edges together" rule the rest of the viewport math
    /// follows.
    @Test func clampNearTheEndsKeepsTheSpan() {
        let committed = WavViewport(startSample: 0, endSample: totalSamples, minFreqHz: 0, maxFreqHz: 192_000)
        let atStart = PlaybackZoom.clamped(committed, center: 0, spanSamples: 576_000,
                                           totalSamples: totalSamples)
        #expect(atStart.startSample == 0)
        #expect(atStart.sampleSpan == 576_000)

        let atEnd = PlaybackZoom.clamped(committed, center: totalSamples, spanSamples: 576_000,
                                         totalSamples: totalSamples)
        #expect(atEnd.endSample == totalSamples)
        #expect(atEnd.sampleSpan == 576_000)
    }

    /// Both playback windows must land on ONE pyramid level for the whole
    /// play-through — that is what makes the prefill a bounded set of tiles
    /// rather than a moving target (see WavPlayerView.startPyramidPrefill).
    @Test func eachModeResolvesToASingleStableLevel() {
        let hetSpan = PlaybackZoom.spanSamples(windowSeconds: 1.5, mode: .heterodyne, expansionFactor: 8,
                                               sampleRate: sampleRate, totalSamples: totalSamples)
        let teSpan = PlaybackZoom.spanSamples(windowSeconds: 1.5, mode: .timeExpansion, expansionFactor: 8,
                                              sampleRate: sampleRate, totalSamples: totalSamples)
        let hetLevel = SpectrogramPyramid.level(forSpanSamples: hetSpan,
                                                targetColumns: WavSpectrogramView.targetColumns)
        let teLevel = SpectrogramPyramid.level(forSpanSamples: teSpan,
                                               targetColumns: WavSpectrogramView.targetColumns)
        #expect(hetLevel > teLevel)
        // And a whole recording at the heterodyne level is a handful of tiles,
        // not hundreds — the scale claim SpectrogramPyramid's header makes.
        let tiles = SpectrogramPyramid.tileIndices(level: hetLevel, startSample: 0, endSample: totalSamples)
        #expect(tiles.count <= 32)
    }
}
