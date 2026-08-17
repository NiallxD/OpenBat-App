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

    /// Non-nil ONLY when `r` falls inside a hidden gap (or before the first
    /// segment): the real start of the next active segment, for playback to
    /// skip to. Nil when `r` is inside an active segment or past the last one.
    /// Binary search, like its two neighbours above — this was the one linear
    /// scan left in the file, and it runs from the playhead follow loop at ~30 Hz
    /// for the whole of playback whenever hide-silence is on, over a segment list
    /// that grows with the number of detected pulses in the recording.
    func nextActiveRealStart(after r: Int) -> Int? {
        guard !segments.isEmpty else { return nil }
        // First segment whose realEnd is strictly greater than `r` — i.e. the
        // first one not already entirely behind the playhead.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].realEnd <= r { lo = mid + 1 } else { hi = mid }
        }
        guard lo < segments.count else { return nil }   // past the last segment
        let seg = segments[lo]
        // Inside that segment already: nothing to skip. Otherwise `r` is in the
        // gap before it, and its start is where playback should jump to.
        return r < seg.realStart ? seg.realStart : nil
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

    /// Builds a map from a whole-file overview raw grid (bin-major
    /// `[bin*nCols+col]`, RAW dB — the layout `WavSpectrogramEngine.RawTile`
    /// stores). `sensitivity` (0...1) is turned into a dB threshold RELATIVE
    /// to this file's own column-peak distribution (see `thresholdDB`) —
    /// NOT an absolute dB value. The absolute approach an earlier version
    /// used silently did nothing whenever the fixed threshold happened to
    /// fall below a given recording's noise floor: every column then read as
    /// "active", so the whole file was one segment and the slider had no
    /// effect at any position. A relative threshold always sits between this
    /// file's own quiet floor and its loudest call, so every sensitivity
    /// value changes what's hidden.
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
                        sensitivity: Double, minFreqHz: Double,
                        padSeconds: Double = 0.02) -> SilenceMap {
        guard nCols > 0, totalSamples > 0, grid.count >= nCols * binCount else {
            return wholeFile(totalSamples: totalSamples)
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

        let thresholdDB = Self.thresholdDB(colPeak: colPeak, sensitivity: sensitivity)

        // Active runs, padded by padSeconds each side (in columns), merged
        // where the padding makes them touch.
        let samplesPerCol = Double(totalSamples) / Double(nCols)
        let padCols = max(1, Int((padSeconds * sampleRate / samplesPerCol).rounded()))
        var runs: [(start: Int, end: Int)] = []   // column ranges, end exclusive
        var runStart: Int? = nil
        for col in 0..<nCols {
            if colPeak[col] >= thresholdDB {
                if runStart == nil { runStart = col }
            } else if let start = runStart {
                runs.append((start, col)); runStart = nil
            }
        }
        if let start = runStart { runs.append((start, nCols)) }
        guard !runs.isEmpty else { return wholeFile(totalSamples: totalSamples) }

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
        guard !segments.isEmpty else { return wholeFile(totalSamples: totalSamples) }
        return SilenceMap(segments: segments, virtualTotal: virtualCursor, realTotal: totalSamples)
    }

    static func wholeFile(totalSamples: Int) -> SilenceMap {
        SilenceMap(segments: [Segment(realStart: 0, realEnd: totalSamples, virtualStart: 0)],
                   virtualTotal: totalSamples, realTotal: totalSamples)
    }

    /// Maps `sensitivity` (0...1) to an absolute dB threshold by
    /// interpolating between this file's own quiet floor (the 20th
    /// percentile of column peaks — robustly below typical noise) and its
    /// loudest column (the peak call). Higher sensitivity raises the cut
    /// toward call level, hiding more. Returns `+inf` when the distribution
    /// is flat (no range to separate), which makes every column read as
    /// silent and the caller fall back to a single whole-file segment.
    ///
    /// `hi` is the MAX, not a high percentile: bat recordings are typically
    /// sparse (mostly silence, calls in well under 5% of columns), so ANY
    /// percentile short of the very top still sits in the noise floor —
    /// making `hi ≈ lo`, collapsing the useful range, and (the reported bug)
    /// hiding nothing at any sensitivity. The single loudest column is a
    /// call by definition, so it's the one dependable "signal" anchor. A
    /// lone broadband glitch column would be an unusual artifact in a
    /// spectrogram and at worst nudges the threshold slightly high.
    static func thresholdDB(colPeak: [Float], sensitivity: Double) -> Float {
        guard let hi = colPeak.max() else { return .greatestFiniteMagnitude }
        let lo = percentile(colPeak.sorted(), 0.20)
        guard hi > lo else { return .greatestFiniteMagnitude }
        return lo + Float(min(max(sensitivity, 0), 1)) * (hi - lo)
    }

    private static func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(max(Int(p * Double(sorted.count)), 0), sorted.count - 1)
        return sorted[idx]
    }
}
