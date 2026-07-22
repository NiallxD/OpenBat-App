//
//  WavViewportTests.swift
//  OpenBatTests
//
//  Pure geometry tests for WavViewportMath — no rendering, no gestures, no
//  Views involved (an explicit improvement over PulseZoomView, whose
//  equivalent helpers are private methods on a View and untestable in
//  isolation today).
//

import Testing
import Foundation
@testable import OpenBat

struct WavViewportTests {

    private let totalSamples = 384_000 * 10   // 10s file
    private let nyquistHz = 192_000.0

    @Test func identityGestureLeavesViewportUnchanged() {
        let committed = WavViewport(startSample: 100_000, endSample: 200_000, minFreqHz: 10_000, maxFreqHz: 90_000)
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1, timeOffset: 0, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.startSample == committed.startSample)
        #expect(resolved.endSample == committed.endSample)
        #expect(abs(resolved.minFreqHz - committed.minFreqHz) < 1)
        #expect(abs(resolved.maxFreqHz - committed.maxFreqHz) < 1)
    }

    @Test func centeredZoomInHalvesSpanSymmetrically() {
        let committed = WavViewport(startSample: 100_000, endSample: 200_000, minFreqHz: 0, maxFreqHz: 192_000)
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 2, timeOffset: 0, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        let expectedSpan = committed.sampleSpan / 2
        #expect(abs(resolved.sampleSpan - expectedSpan) <= 1)
        let originalMid = (committed.startSample + committed.endSample) / 2
        let newMid = (resolved.startSample + resolved.endSample) / 2
        #expect(abs(newMid - originalMid) <= 1, "a centered pinch (offset=0) must not shift the midpoint")
    }

    @Test func panOffsetShiftsWindowWithoutChangingSpan() {
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 0, maxFreqHz: 192_000)
        // scale=2 (zoomed in 2x), offset shifted right by 0.1 of the frame.
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 2, timeOffset: -0.1, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        let noPanResolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 2, timeOffset: 0, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.sampleSpan == noPanResolved.sampleSpan)
        #expect(resolved.startSample > noPanResolved.startSample, "negative offset should pan the window forward in time")
    }

    @Test func clampsToFileBoundsWhenPanningPastTheEdge() {
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 0, maxFreqHz: 192_000)
        // Large negative offset tries to pan far left, past sample 0.
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 4, timeOffset: -10, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.startSample >= 0)
        #expect(resolved.endSample <= totalSamples)
    }

    @Test func panPastTheStartPreservesSpanInsteadOfShrinking() {
        // Regression test: clamping `newStart`/`newEnd` to [0, totalSamples]
        // INDEPENDENTLY (each via its own min/max) rather than shifting both
        // together silently shrank the span the moment a drag pushed either
        // edge out of bounds — the visible sample range narrowed while still
        // being stretched across the same screen width, reading as "the
        // spectrogram expands" when panning past the file's start/end.
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 0, maxFreqHz: 192_000)
        // offset=0.5 at scale=1 tries to pan half a window further left than
        // sample 0 allows.
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1, timeOffset: 0.5, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.startSample == 0)
        #expect(resolved.sampleSpan == committed.sampleSpan,
                "clamping at the file's start edge must preserve the span, not shrink it")
    }

    @Test func panPastTheEndPreservesSpanInsteadOfShrinking() {
        let committed = WavViewport(startSample: totalSamples - 384_000, endSample: totalSamples,
                                    minFreqHz: 0, maxFreqHz: 192_000)
        // offset=-0.5 pans toward later samples, past the file's own end.
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1, timeOffset: -0.5, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.endSample == totalSamples)
        #expect(resolved.sampleSpan == committed.sampleSpan,
                "clamping at the file's end edge must preserve the span, not shrink it")
    }

    @Test func extremeZoomInEnforcesMinimumSampleSpan() {
        let committed = WavViewport(startSample: 100_000, endSample: 100_100, minFreqHz: 0, maxFreqHz: 192_000)
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1000, timeOffset: 0, freqScale: 1, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.sampleSpan >= WavViewportMath.minSampleSpan)
    }

    @Test func extremeFrequencyZoomEnforcesMinimumFreqSpan() {
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 40_000, maxFreqHz: 40_600)
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1, timeOffset: 0, freqScale: 1000, freqOffset: 0,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.freqSpan >= WavViewportMath.minFreqSpanHz)
    }

    @Test func freqZoomTowardTopKeepsHighFrequencyEdgeAboveLowFrequencyEdge() {
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 0, maxFreqHz: 192_000)
        let resolved = WavViewportMath.resolvedViewport(
            committed: committed, timeScale: 1, timeOffset: 0, freqScale: 2, freqOffset: -0.25,
            totalSamples: totalSamples, nyquistHz: nyquistHz)
        #expect(resolved.maxFreqHz > resolved.minFreqHz)
        // Panning offset=-0.25 at scale 2 should shift toward the TOP (high
        // frequency) half of the original range.
        #expect(resolved.minFreqHz > committed.minFreqHz)
    }

    @Test func zoomFractionRoundTripsWithSampleSpan() {
        // 0 = whole file, 1 = the minimum span — endpoints should round-trip
        // exactly; a middle value should round-trip within a sample or two
        // (integer rounding in `sampleSpan`).
        #expect(WavViewportMath.zoomFraction(forSampleSpan: totalSamples, totalSamples: totalSamples) == 0)
        let minSpan = WavViewportMath.sampleSpan(forZoomFraction: 1, totalSamples: totalSamples)
        #expect(minSpan == WavViewportMath.minSampleSpan)

        let midSpan = WavViewportMath.sampleSpan(forZoomFraction: 0.5, totalSamples: totalSamples)
        let recovered = WavViewportMath.zoomFraction(forSampleSpan: midSpan, totalSamples: totalSamples)
        #expect(abs(recovered - 0.5) < 0.01)
    }

    @Test func zoomFractionIsMonotonicallyDecreasingSpan() {
        // Higher zoom fraction ("spread out more") must always mean a
        // SMALLER span, never larger or equal — a slider that occasionally
        // zoomed the wrong way at some fraction would be a real regression.
        let spans = stride(from: 0.0, through: 1.0, by: 0.1).map {
            WavViewportMath.sampleSpan(forZoomFraction: $0, totalSamples: totalSamples)
        }
        for i in 1..<spans.count {
            #expect(spans[i] <= spans[i - 1], "span must not increase as zoom fraction rises")
        }
    }

    @Test func viewportForTimeZoomKeepsCenterFixed() {
        let committed = WavViewport(startSample: 100_000, endSample: 200_000, minFreqHz: 0, maxFreqHz: 192_000)
        let originalCenter = (committed.startSample + committed.endSample) / 2
        let resolved = WavViewportMath.viewportForTimeZoom(committed: committed, zoomFraction: 0.8, totalSamples: totalSamples)
        let newCenter = (resolved.startSample + resolved.endSample) / 2
        #expect(abs(newCenter - originalCenter) <= 1)
        #expect(resolved.sampleSpan < committed.sampleSpan, "zoomFraction 0.8 should be a tighter span than the committed 100_000-sample window")
    }

    @Test func viewportForTimeZoomClampsAtFileEdge() {
        // Centered near sample 0 — zooming out should clamp the window to
        // start at 0 rather than going negative.
        let committed = WavViewport(startSample: 0, endSample: 1000, minFreqHz: 0, maxFreqHz: 192_000)
        let resolved = WavViewportMath.viewportForTimeZoom(committed: committed, zoomFraction: 0, totalSamples: totalSamples)
        #expect(resolved.startSample == 0)
        #expect(resolved.endSample == totalSamples)
    }

    @Test func viewportForFreqZoomKeepsCurrentCenter() {
        // Centered on 120kHz (not the file's 0-192kHz midpoint) — narrowing
        // the range must zoom around THAT center, not reset to 96kHz.
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 96_000, maxFreqHz: 144_000)
        let resolved = WavViewportMath.viewportForFreqZoom(committed: committed, spanHz: 20_000, nyquistHz: nyquistHz)
        #expect(abs(resolved.minFreqHz - 110_000) < 1)
        #expect(abs(resolved.maxFreqHz - 130_000) < 1)
        // Time axis must be untouched by a frequency-only control.
        #expect(resolved.startSample == committed.startSample)
        #expect(resolved.endSample == committed.endSample)
    }

    @Test func viewportForFreqZoomClampsTogetherAtNyquistEdge() {
        // Centered near Nyquist — widening the span should clamp by shifting
        // BOTH edges down together, not shrink independently at the top.
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 180_000, maxFreqHz: 192_000)
        let resolved = WavViewportMath.viewportForFreqZoom(committed: committed, spanHz: 40_000, nyquistHz: nyquistHz)
        #expect(abs(resolved.maxFreqHz - nyquistHz) < 1)
        #expect(abs(resolved.freqSpan - 40_000) < 1)
    }

    @Test func viewportForFreqZoomEnforcesMinimumSpan() {
        let committed = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 90_000, maxFreqHz: 102_000)
        let resolved = WavViewportMath.viewportForFreqZoom(committed: committed, spanHz: 10, nyquistHz: nyquistHz)
        #expect(resolved.freqSpan >= WavViewportMath.minFreqSpanHz)
    }

    @Test func fitScalesMatchWholeFileRatio() {
        let viewport = WavViewport(startSample: 0, endSample: 38_400, minFreqHz: 0, maxFreqHz: 192_000)
        let timeScale = WavViewportMath.timeFitScale(viewport: viewport, totalSamples: 384_000)
        #expect(abs(timeScale - 10) < 0.001)   // 384_000 / 38_400 == 10

        let freqViewport = WavViewport(startSample: 0, endSample: 384_000, minFreqHz: 0, maxFreqHz: 96_000)
        let freqScale = WavViewportMath.freqFitScale(viewport: freqViewport, nyquistHz: 192_000)
        #expect(abs(freqScale - 2) < 0.001)
    }
}
