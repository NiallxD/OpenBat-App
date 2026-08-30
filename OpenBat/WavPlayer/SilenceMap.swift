//
//  SilenceMap.swift
//  OpenBat
//
//  The model behind the WAV player's "hide silence" mode: a set of ACTIVE
//  (non-silent) real-sample segments, concatenated into one compressed
//  VIRTUAL timeline with the silent gaps removed. Everything display-side
//  (viewport, tiles, minimap, ticker wheels) simply operates in virtual
//  samples as if the compressed timeline were the whole file; the only
//  places that translate between domains are the seams — seeks
//  (virtual -> real), the playhead (real -> virtual), detail-tile rendering
//  (a virtual span -> its real slices, see
//  WavSpectrogramEngine.renderRawTileStitched), and call analysis (a
//  virtual selection -> the real range it covers).
//
//  Detection runs on the whole-file overview raw dB grid that
//  WavSpectrogramEngine.Overview already keeps resident — no extra file IO
//  or FFT work: a column is "active" when its peak dB across the bins above
//  `minFreqHz` (excluding wind/handling rumble, same floor CallAnalysis
//  uses) clears the threshold. Active runs are padded by `padSeconds` on
//  each side so call onsets/tails never get clipped at a seam, which also
//  merges any gap shorter than twice the pad. Segments are quantized to
//  overview-column boundaries (~ms at typical file lengths) — display
//  granularity, deliberately not sample-accurate.
//
//  The same segments drive PLAYBACK, not just the display: PlaybackEngine
//  holds the map and its pacing thread walks these real ranges, so the
//  hidden audio is never fed to the audio path at all and every published
//  playback time is in the compressed domain. See PlaybackDriver.start.
//

import Foundation
import Accelerate

struct SilenceMap: Equatable {
    struct Segment: Equatable {
        let realStart: Int      // inclusive, real samples
        let realEnd: Int        // exclusive
        let virtualStart: Int   // prefix sum of preceding segment lengths
        var length: Int { realEnd - realStart }
        var virtualEnd: Int { virtualStart + length }
    }

    /// Always non-empty and sorted — `compute` falls back to one whole-file
    /// segment when nothing clears the threshold, so a map NEVER produces an
    /// empty timeline.
    let segments: [Segment]
    let virtualTotal: Int
    let realTotal: Int
    /// True when detection found nothing and `compute` fell back to a single
    /// whole-file segment — i.e. the map is real but it hides nothing. The UI
    /// needs to tell that apart from a map that genuinely kept everything,
    /// because to the user both look like the toggle doing nothing. See
    /// `WavPlayerView.silenceSummary`.
    var isFallback: Bool = false

    /// The kept ranges in REAL samples, in order — what the playback pacing
    /// thread walks (see PlaybackDriver.start's `regions`).
    var realRegions: [Range<Int>] { segments.map { $0.realStart..<$0.realEnd } }

    /// The share of the recording this map keeps, 0...1.
    var keptFraction: Double {
        realTotal > 0 ? Double(virtualTotal) / Double(realTotal) : 1
    }

    // MARK: Domain mapping

    /// The real sample a virtual position corresponds to. Clamped to the
    /// virtual timeline's bounds.
    func virtualToReal(_ v: Int) -> Int {
        let clamped = min(max(v, 0), virtualTotal)
        // Last segment whose virtualStart <= clamped (segments non-empty).
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].virtualStart <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let seg = segments[lo]
        return min(seg.realStart + (clamped - seg.virtualStart), seg.realEnd)
    }

    /// The virtual position a real sample corresponds to. A real position
    /// inside a hidden gap collapses to the seam (the end of the preceding
    /// segment) — that's where the playhead sits while real audio in a gap
    /// is playing (the follow loop normally skips those — see
    /// WavPlayerView's `followPlayheadTick`).
    func realToVirtual(_ r: Int) -> Int {
        guard let first = segments.first, r >= first.realStart else { return 0 }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].realStart <= r { lo = mid } else { hi = mid - 1 }
        }
        let seg = segments[lo]
        return seg.virtualStart + min(max(r - seg.realStart, 0), seg.length)
    }

    /// The real slices covering `[virtualStart, virtualEnd)`, each paired
    /// with the virtual sub-range it fills — what stitched tile rendering
    /// iterates (see WavSpectrogramEngine.renderRawTileStitched).
    func realSlices(virtualStart: Int, virtualEnd: Int) -> [(real: Range<Int>, virtual: Range<Int>)] {
        var slices: [(real: Range<Int>, virtual: Range<Int>)] = []
        for seg in segments {
            let v0 = max(virtualStart, seg.virtualStart)
            let v1 = min(virtualEnd, seg.virtualEnd)
            guard v1 > v0 else { continue }
            let r0 = seg.realStart + (v0 - seg.virtualStart)
            slices.append((real: r0..<(r0 + (v1 - v0)), virtual: v0..<v1))
        }
        return slices
    }

    // MARK: Detection

    /// How far a column's peak must fall BELOW the enter threshold before an
    /// active run is closed. Without it a call whose level dithers around a
    /// single threshold shatters into a burst of tiny runs, each of which then
    /// gets its own `padSeconds` and merges back messily; with it a run ends
    /// only once the signal has genuinely gone.
    static let hysteresisDB: Float = 6

    /// How long the ABOVE-ENTER part of a run must last to count as an event.
    /// A bat pulse is milliseconds; a broadband tick (a handling knock, a
    /// switch, a clipped sample) is shorter than one overview column. Without
    /// this floor a single stray column became a kept region — padded on both
    /// sides — so the compressed timeline filled up with noise the user could
    /// see was not a call. Expressed in seconds and converted using the file's
    /// own column density, since an overview column is ~1 ms on a short
    /// recording and ~70 ms on a long one; on files coarse enough that one
    /// column already exceeds this, the floor is one column and does nothing.
    static let minEventSeconds: Double = 0.003

    /// The narrowest and widest the threshold may sit above the file's own
    /// noise floor. The floor stops `thresholdAboveFloorDB == 0` from treating
    /// the noise itself as signal; the ceiling is a plain sanity bound on the
    /// slider.
    static let minThresholdAboveFloorDB: Double = 3
    static let maxThresholdAboveFloorDB: Double = 40

    /// Builds a map from a whole-file overview raw grid (bin-major
    /// `[bin*nCols+col]`, RAW dB — the layout `WavSpectrogramEngine.RawTile`
    /// stores).
    ///
    /// `thresholdAboveFloorDB` is exactly what it says: decibels above THIS
    /// FILE's own measured noise floor (see `noiseFloorDB`). That unit is the
    /// point. Two earlier versions were both unusable for the same underlying
    /// reason — the number the user set did not mean anything fixed:
    ///
    ///   • An ABSOLUTE dB threshold silently did nothing whenever it happened
    ///     to fall below a given recording's noise floor: every column read as
    ///     active, the whole file became one segment, and the control had no
    ///     effect at any position.
    ///   • A 0...1 "sensitivity" interpolated between the floor and the file's
    ///     LOUDEST column had no fixed meaning either, because the top anchor
    ///     moved with the file. One close pass, or one broadband knock, put the
    ///     midpoint 30 dB up and hid every real call in the recording; a file of
    ///     only faint calls hid nothing. Same slider position, opposite result,
    ///     and no way for the user to tell which they had got.
    ///
    /// Anchored to the noise floor alone, the setting is portable: 12 dB above
    /// the floor means the same thing on every recording, and no single loud
    /// artifact can move it, because the loudest column no longer participates.
    ///
    /// `padSeconds` is kept SMALL on purpose (each active run is widened by
    /// it on both sides before merging). It only needs to cover a call's
    /// onset/tail plus a little visual breathing room — a couple of tens of
    /// ms. An earlier 0.1s (100ms/side = 200ms/pulse) was larger than the
    /// typical inter-pulse gap in a real pass, so the padding bridged the
    /// silences and merged everything back into a handful of segments,
    /// compressing almost nothing (measured on a real MYCA file: 49 pulses
    /// -> 3 segments, 52% kept). At 20ms/side the same file keeps its 49
    /// pulses separate and compresses to ~19% — cutting the silence the way
    /// "hide silence" is meant to.
    static func compute(grid: [Float], nCols: Int, binCount: Int,
                        totalSamples: Int, sampleRate: Double,
                        thresholdAboveFloorDB: Double, minFreqHz: Double,
                        padSeconds: Double = 0.02) -> SilenceMap {
        guard nCols > 0, totalSamples > 0, grid.count >= nCols * binCount else {
            return wholeFile(totalSamples: totalSamples, isFallback: true)
        }
        let hzPerBin = (sampleRate / 2) / Double(binCount)
        let minBin = min(max(Int(minFreqHz / max(hzPerBin, 1)), 0), binCount - 1)

        // Per-column peak over the bins in scope — row-at-a-time vDSP_vmax
        // (rows are contiguous in the bin-major layout) rather than a
        // column-at-a-time scan striding the whole grid.
        var colPeak = [Float](repeating: -.greatestFiniteMagnitude, count: nCols)
        grid.withUnsafeBufferPointer { g in
            colPeak.withUnsafeMutableBufferPointer { peaks in
                for bin in minBin..<binCount {
                    vDSP_vmax(g.baseAddress! + bin * nCols, 1,
                              peaks.baseAddress!, 1,
                              peaks.baseAddress!, 1, vDSP_Length(nCols))
                }
            }
        }

        let enterDB = thresholdDB(colPeak: colPeak, aboveFloorDB: thresholdAboveFloorDB)
        let exitDB = enterDB - hysteresisDB

        let samplesPerCol = Double(totalSamples) / Double(nCols)
        let minCoreCols = max(1, Int((minEventSeconds * sampleRate / samplesPerCol).rounded()))

        // Active runs: a run OPENS on a column at or above `enterDB` and stays
        // open until one falls below `exitDB`; it is kept only if enough of its
        // columns cleared `enterDB` to be an event rather than a tick.
        var runs: [(start: Int, end: Int)] = []   // column ranges, end exclusive
        var runStart: Int? = nil
        var coreCols = 0
        func closeRun(at col: Int) {
            if let start = runStart, coreCols >= minCoreCols { runs.append((start, col)) }
            runStart = nil
            coreCols = 0
        }
        for col in 0..<nCols {
            let level = colPeak[col]
            if runStart == nil {
                if level >= enterDB { runStart = col; coreCols = 1 }
            } else if level >= exitDB {
                if level >= enterDB { coreCols += 1 }
            } else {
                closeRun(at: col)
            }
        }
        closeRun(at: nCols)
        guard !runs.isEmpty else { return wholeFile(totalSamples: totalSamples, isFallback: true) }

        // Pad each run by `padSeconds` a side, merging where the padding makes
        // neighbours touch.
        let padCols = max(1, Int((padSeconds * sampleRate / samplesPerCol).rounded()))
        var merged: [(start: Int, end: Int)] = []
        for run in runs {
            let padded = (start: max(0, run.start - padCols), end: min(nCols, run.end + padCols))
            if let last = merged.last, padded.start <= last.end {
                merged[merged.count - 1].end = max(last.end, padded.end)
            } else {
                merged.append(padded)
            }
        }

        var segments: [Segment] = []
        var virtualCursor = 0
        for run in merged {
            let realStart = Int((Double(run.start) * samplesPerCol).rounded())
            let realEnd = run.end == nCols ? totalSamples : Int((Double(run.end) * samplesPerCol).rounded())
            guard realEnd > realStart else { continue }
            segments.append(Segment(realStart: realStart, realEnd: realEnd, virtualStart: virtualCursor))
            virtualCursor += realEnd - realStart
        }
        guard !segments.isEmpty else { return wholeFile(totalSamples: totalSamples, isFallback: true) }
        return SilenceMap(segments: segments, virtualTotal: virtualCursor,
                          realTotal: totalSamples, isFallback: false)
    }

    static func wholeFile(totalSamples: Int, isFallback: Bool = false) -> SilenceMap {
        SilenceMap(segments: [Segment(realStart: 0, realEnd: totalSamples, virtualStart: 0)],
                   virtualTotal: totalSamples, realTotal: totalSamples, isFallback: isFallback)
    }

    /// The absolute dB a column must reach to open a run: the file's own noise
    /// floor plus `aboveFloorDB` (clamped to the supported range).
    static func thresholdDB(colPeak: [Float], aboveFloorDB: Double) -> Float {
        let margin = min(max(aboveFloorDB, minThresholdAboveFloorDB), maxThresholdAboveFloorDB)
        return noiseFloorDB(colPeak: colPeak) + Float(margin)
    }

    /// This file's own quiet floor: the 20th percentile of the per-column
    /// peaks. A percentile, not the minimum, so one anomalously dead column
    /// can't drag it down; low enough that in a sparse recording — which is
    /// most of them, calls in well under 5% of columns — it lands squarely in
    /// the noise rather than in the calls.
    static func noiseFloorDB(colPeak: [Float]) -> Float {
        percentile(colPeak.sorted(), 0.20)
    }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(max(Int(p * Double(sorted.count)), 0), sorted.count - 1)
        return sorted[idx]
    }
}
