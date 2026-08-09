//
//  WavViewport.swift
//  OpenBat
//
//  What's currently visible in WavSpectrogramView, plus the pure geometry
//  math for turning a live pan/pinch gesture into a new viewport. Deliberately
//  hoisted out of any View (unlike PulseZoomView's equivalent private
//  methods) so this is unit-testable in isolation — see WavViewportTests.swift.
//
//  Panning reuses PulseZoomView's proven `screen(v) = 0.5 + (v−0.5)·scale +
//  offset` identity (both axes — time and frequency, see `resolvedViewport`'s
//  `freqOffset`). Zoom is driven the same way, via `TwoAxisPinchView`'s
//  per-axis scale. Context.md has the history of what this replaced (a
//  composed MagnifyGesture and a two-thumb frequency-trim slider).
//

import Foundation

/// The time/frequency window currently on screen — the single source of
/// truth WavSpectrogramView renders against and every gesture ultimately
/// updates.
struct WavViewport: Equatable {
    var startSample: Int
    var endSample: Int          // exclusive
    var minFreqHz: Double
    var maxFreqHz: Double

    var sampleSpan: Int { endSample - startSample }
    var freqSpan: Double { maxFreqHz - minFreqHz }

    static func wholeFile(totalSamples: Int, maxFreqHz: Double) -> WavViewport {
        WavViewport(startSample: 0, endSample: totalSamples, minFreqHz: 0, maxFreqHz: maxFreqHz)
    }
}

/// Pure functions turning a gesture or a committed viewport into a new
/// `WavViewport` — see the file doc comment for why this lives outside any
/// View.
enum WavViewportMath {

    /// Minimum viewport spans — prevents a degenerate zoom (e.g. pinching in
    /// on a single sample or a fraction of a Hz). The sample-span floor is
    /// tied to `STFTGrid.windowLen`/`hop`: `WavSpectrogramEngine.renderDetailTile`
    /// requires at least `windowLen` PCM samples to produce even a single STFT
    /// frame, so a smaller floor let the deepest zoom levels silently fall
    /// back to a blown-up crop of the overview image forever (no detail tile
    /// ever renders for a span `renderDetailTile` immediately rejects).
    ///
    /// Sitting at EXACTLY `windowLen`, though, produces exactly ONE STFT
    /// frame — `streamPooledGrid` returns a 1-pixel-wide image, which
    /// `.resizable()` then stretches across the whole view width: no time
    /// detail at all, just flat horizontal color bands (one solid color per
    /// frequency bin). The extra 128-hop margin guarantees a genuinely
    /// useful number of columns even at the deepest zoom, at the cost of a
    /// floor of ~12 ms @ 384 kHz instead of ~1.3 ms — still comfortably
    /// narrower than a typical echolocation call.
    static let minSampleSpan = STFTGrid.windowLen + 128 * STFTGrid.hop
    static let minFreqSpanHz = 500.0

    /// `viewport`'s span/frequency window, re-centered on `center` (a
    /// display-domain sample) — the shared "recenter" math WavPlayerView's
    /// playback follow loop, WavSpectrogramView's live playback preview, and
    /// WavMinimapView's position rectangle all need to agree on, so a
    /// playback session's live preview lands EXACTLY where the eventual
    /// one-shot commit into `viewport` (on pause) does, instead of visibly
    /// snapping. Clamps both edges together against `[0, totalSamples)`
    /// rather than independently — same "balloon outward" reasoning
    /// `resolvedViewport` documents.
    static func recentered(_ viewport: WavViewport, on center: Int, totalSamples: Int) -> WavViewport {
        let span = min(viewport.sampleSpan, totalSamples)
        var start = center - span / 2
        var end = start + span
        if start < 0 { end -= start; start = 0 }
        if end > totalSamples { start -= (end - totalSamples); end = totalSamples }
        return WavViewport(startSample: max(0, start), endSample: min(totalSamples, end),
                           minFreqHz: viewport.minFreqHz, maxFreqHz: viewport.maxFreqHz)
    }

    /// Inverts `screen(v) = 0.5 + (v-0.5)*scale + offset` to recover the
    /// [leftFrac, rightFrac] window of the COMMITTED viewport that's
    /// currently visible on screen, given a scale/offset — same solved form
    /// as PulseZoomView.visibleVRange. `resolvedViewport` below only ever
    /// calls this with `scale == 1` now (a pure pan translation; zoom is
    /// slider-driven, not gestured), but the general form costs nothing to
    /// keep and stays covered by this file's existing zoom-related tests.
    static func visibleFracRange(scale: Double, offset: Double) -> (left: Double, right: Double) {
        guard scale > 0 else { return (0, 1) }
        return (left: 0.5 - (0.5 + offset) / scale,
                right: 0.5 + (0.5 - offset) / scale)
    }

    /// Given the currently committed viewport and a live gesture's
    /// scale/offset (per axis), returns the new viewport that gesture
    /// implies — clamped to `[0, totalSamples]` / `[0, nyquistHz]` and to the
    /// minimum spans above. This is what gets committed once a pan drag
    /// settles (see WavSpectrogramView's debounce) and when a two-axis pinch
    /// ends (TwoAxisPinchView supplies per-axis scales; a plain pan passes
    /// scale 1 on both axes).
    static func resolvedViewport(committed: WavViewport,
                                 timeScale: Double, timeOffset: Double,
                                 freqScale: Double, freqOffset: Double,
                                 totalSamples: Int, nyquistHz: Double) -> WavViewport {
        let (leftT, rightT) = visibleFracRange(scale: timeScale, offset: timeOffset)
        let (topF, bottomF) = visibleFracRange(scale: freqScale, offset: freqOffset)

        let span = Double(committed.sampleSpan)
        var newStart = Double(committed.startSample) + (leftT * span).rounded()
        var newEnd   = Double(committed.startSample) + (rightT * span).rounded()
        // Clamp to the file's bounds WITHOUT changing the span: shift BOTH
        // edges back into range together (same pattern `viewportForTimeZoom`/
        // `WavPlayerView.recenter` already use), not each edge independently.
        // Independent clamping — `newStart = min(max(newStart,0),total)`,
        // ditto for `newEnd`, done separately — silently SHRINKS the span
        // the instant a drag pushes either edge out of bounds (e.g. panning
        // past the start of the file): the visible sample range narrows
        // while still being stretched across the same screen width, so
        // whatever's on screen balloons outward. That was the "dragging
        // past the edge makes the spectrogram expand" bug.
        let total = Double(totalSamples)
        if newStart < 0 { newEnd -= newStart; newStart = 0 }
        if newEnd > total { newStart -= (newEnd - total); newEnd = total }
        newStart = max(0, newStart)
        newEnd = min(total, newEnd)
        var newStartInt = Int(newStart)
        var newEndInt = Int(newEnd)
        if newEndInt - newStartInt < minSampleSpan {
            let mid = (newStartInt + newEndInt) / 2
            newStartInt = max(0, mid - minSampleSpan / 2)
            newEndInt   = min(totalSamples, newStartInt + minSampleSpan)
        }

        // Frequency axis: top of screen (frac 0) = HIGH frequency, matching
        // PulseZoomView's top=high convention — so `topF` maps to maxFreqHz
        // and `bottomF` maps to minFreqHz. Clamped the SAME "shift both
        // edges together" way the time axis just above does (and
        // `viewportForFreqZoom` already does): clamping `newMin`/`newMax`
        // INDEPENDENTLY — as this used to — silently SHRINKS the span the
        // instant a vertical pan pushes either edge past 0 or Nyquist,
        // which is exactly the "panning changes the Range value" bug: any
        // drag with even a small vertical component (real touches are never
        // perfectly horizontal) could clip one edge without the other,
        // narrowing the frequency window it committed.
        let freqRange = committed.freqSpan
        var newMax = committed.maxFreqHz - topF * freqRange
        var newMin = committed.maxFreqHz - bottomF * freqRange
        if newMin < 0 { newMax -= newMin; newMin = 0 }
        if newMax > nyquistHz { newMin -= (newMax - nyquistHz); newMax = nyquistHz }
        newMin = max(0, newMin)
        newMax = min(nyquistHz, newMax)
        if newMax - newMin < minFreqSpanHz {
            let mid = (newMin + newMax) / 2
            newMin = max(0, mid - minFreqSpanHz / 2)
            newMax = min(nyquistHz, newMin + minFreqSpanHz)
        }

        return WavViewport(startSample: newStartInt, endSample: newEndInt, minFreqHz: newMin, maxFreqHz: newMax)
    }

    /// Log-scale mapping from a 0...1 "zoom slider" fraction to a sample
    /// span: 0 = whole file, 1 = `minSampleSpan`. Log-scale, not linear,
    /// because the usable range spans many orders of magnitude (a
    /// multi-minute recording zoomed to a single ~1ms echolocation call) — a
    /// linear slider would spend the vast majority of its range zooming from
    /// 100% down to ~90% of the file, leaving almost no room to reach the
    /// spans a call actually needs.
    static func sampleSpan(forZoomFraction f: Double, totalSamples: Int) -> Int {
        guard totalSamples > minSampleSpan else { return totalSamples }
        let clamped = min(max(f, 0), 1)
        let minFrac = Double(minSampleSpan) / Double(totalSamples)
        let span = Double(totalSamples) * pow(minFrac, clamped)
        return min(max(Int(span.rounded()), minSampleSpan), totalSamples)
    }

    /// Inverse of `sampleSpan(forZoomFraction:)` — recovers the slider
    /// position that would currently show `span`, so the zoom slider reads
    /// the right value on load and after any OTHER change to the viewport's
    /// span (e.g. the minimap's recenter, which preserves span).
    static func zoomFraction(forSampleSpan span: Int, totalSamples: Int) -> Double {
        guard totalSamples > minSampleSpan, span > 0 else { return 0 }
        let minFrac = Double(minSampleSpan) / Double(totalSamples)
        guard minFrac > 0, minFrac < 1 else { return 0 }
        let frac = Double(span) / Double(totalSamples)
        return min(max(log(frac) / log(minFrac), 0), 1)
    }

    /// New viewport keeping the CURRENT CENTER sample fixed while changing
    /// just the span. Used by `WavPlayerView.load()` to open on a
    /// half-zoomed view rather than the whole file.
    static func viewportForTimeZoom(committed: WavViewport, zoomFraction: Double, totalSamples: Int) -> WavViewport {
        let span = sampleSpan(forZoomFraction: zoomFraction, totalSamples: totalSamples)
        let center = (committed.startSample + committed.endSample) / 2
        var start = center - span / 2
        var end = start + span
        if start < 0 { end -= start; start = 0 }
        if end > totalSamples { start -= (end - totalSamples); end = totalSamples }
        start = max(0, start)
        end = min(totalSamples, end)
        return WavViewport(startSample: start, endSample: end,
                           minFreqHz: committed.minFreqHz, maxFreqHz: committed.maxFreqHz)
    }

    /// New viewport applying a frequency span (in Hz) directly, keeping the
    /// CURRENT CENTER frequency fixed — a pure zoom around wherever the user
    /// has already panned to, rather than resetting to the midpoint between 0
    /// and Nyquist. Not currently called from anywhere in the WAV player
    /// (frequency zoom is pinch-driven — see `resolvedViewport`); kept for
    /// its test coverage and as the one-shot alternative to a gesture.
    static func viewportForFreqZoom(committed: WavViewport, spanHz: Double, nyquistHz: Double) -> WavViewport {
        let span = min(max(spanHz, minFreqSpanHz), nyquistHz)
        let center = (committed.minFreqHz + committed.maxFreqHz) / 2
        var minHz = center - span / 2
        var maxHz = center + span / 2
        // Shift both edges together if the centered window runs past either
        // bound — same "clamp together, not independently" pattern used
        // throughout this file (see `resolvedViewport`'s own doc comment for
        // why independent clamping silently shrinks the span instead).
        if minHz < 0 { maxHz -= minHz; minHz = 0 }
        if maxHz > nyquistHz { minHz -= (maxHz - nyquistHz); maxHz = nyquistHz }
        minHz = max(0, minHz)
        maxHz = min(nyquistHz, maxHz)
        return WavViewport(startSample: committed.startSample, endSample: committed.endSample,
                           minFreqHz: minHz, maxFreqHz: maxHz)
    }

    /// The scale that exactly fits `viewport` within `wholeFile` on a given
    /// axis — used as the "1×" reference a fresh detail tile starts at
    /// (gesture scale resets to 1 whenever a new tile commits, per
    /// WavSpectrogramView), and to decide whether the overview alone
    /// (effective scale <= 1) is enough to display, with no detail-tile
    /// fetch needed.
    static func timeFitScale(viewport: WavViewport, totalSamples: Int) -> Double {
        guard viewport.sampleSpan > 0 else { return 1 }
        return Double(totalSamples) / Double(viewport.sampleSpan)
    }

    static func freqFitScale(viewport: WavViewport, nyquistHz: Double) -> Double {
        guard viewport.freqSpan > 0 else { return 1 }
        return nyquistHz / viewport.freqSpan
    }
}
