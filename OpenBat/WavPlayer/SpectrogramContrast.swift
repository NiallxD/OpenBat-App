//
//  SpectrogramContrast.swift
//  OpenBat
//
//  How loud "white" is, computed ONCE for a whole recording instead of
//  separately for every render.
//
//  The display maps dB to colour against a ceiling that tracks recent
//  loudness and decays — an AGC, so a quiet stretch still uses the full
//  contrast range instead of rendering as flat black. That is worth keeping.
//  What is not worth keeping is recomputing it per render over whatever
//  frequency band happened to be on screen, which is what
//  `WavSpectrogramEngine.colorize` does: the ceiling then depends on the
//  viewport, so the same call is drawn at different brightness depending on
//  how you got to it, and — fatally for a fixed tile grid — the decay would
//  restart at every tile boundary and show as seams.
//
//  Measured once across the file, the mapping becomes a property of the
//  RECORDING rather than of the view. Two consequences, both wanted:
//
//    • A tile's rendered picture no longer depends on the viewport at all.
//      It can be rendered once and cropped for any view, at any zoom, with
//      any frequency window — which is what makes the tile cache worth
//      having (see `SpectrogramPyramid`).
//    • Brightness stops changing as you zoom and pan. Today it does, and
//      that is a real if quiet source of confusion when judging a call's
//      strength by eye.
//
//  The cost, stated plainly because it is a genuine loss: a faint call in a
//  quiet stretch no longer gets its own local contrast lift from being
//  looked at closely. The decay below still gives it one relative to the
//  loud parts of the recording — it just no longer depends on what else is
//  in frame. Niall's call, 2026-09-01.
//

import Accelerate

nonisolated struct SpectrogramContrast {

    /// Same constants the per-render version uses, so the look is unchanged
    /// where the two agree. See `WavSpectrogramEngine` for what each is for.
    static let dynamicRangeDB: Float = 70
    private static let absoluteSignalFloorDB: Float = -40
    private static let ceilingReleaseDBPerSecond: Float = 22.5
    private static let ceilingHeadroomDB: Float = 3

    /// The bottom of the display range for each column of the OVERVIEW grid
    /// this was measured from. Everything else is interpolated out of it.
    private let effMinDB: [Float]
    /// The real-sample span `effMinDB` covers, so any tile at any level can
    /// find its own place in it.
    private let startSample: Int
    private let endSample: Int

    var columnCount: Int { effMinDB.count }

    /// Measures the track from the whole-file overview grid that is already
    /// resident — no extra file IO and no extra FFT work.
    ///
    /// Deliberately over ALL bins above the DC/Nyquist packed bin, not over a
    /// visible band: a fixed mapping has to be fixed with respect to the
    /// frequency window too, or panning vertically would change it and the
    /// tile pictures would stop being reusable.
    init(overview raw: WavSpectrogramEngine.RawTile, sampleRate: Double, binCount: Int) {
        let nCols = max(raw.nCols, 1)
        var colMaxDB = [Float](repeating: Self.absoluteSignalFloorDB, count: nCols)
        if raw.grid.count >= nCols * binCount, binCount > 1 {
            raw.grid.withUnsafeBufferPointer { g in
                for bin in 1..<binCount {
                    vDSP_vmax(g.baseAddress! + bin * nCols, 1, colMaxDB, 1,
                              &colMaxDB, 1, vDSP_Length(nCols))
                }
            }
        }

        let spanSeconds = sampleRate > 0
            ? Double(raw.endSample - raw.startSample) / sampleRate : 0
        let secondsPerColumn = spanSeconds / Double(nCols)
        let decayPerColumn = Float(Double(Self.ceilingReleaseDBPerSecond) * secondsPerColumn)

        var track = [Float](repeating: 0, count: nCols)
        var runningCeiling = Self.absoluteSignalFloorDB
        for col in 0..<nCols {
            let colMax = colMaxDB[col]
            runningCeiling = colMax > runningCeiling
                ? colMax
                : max(colMax, runningCeiling - decayPerColumn)
            runningCeiling = max(runningCeiling, Self.absoluteSignalFloorDB)
            let ceilingDB = min(runningCeiling + Self.ceilingHeadroomDB, 0)
            track[col] = ceilingDB - Self.dynamicRangeDB
        }
        effMinDB = track
        startSample = raw.startSample
        endSample = max(raw.endSample, raw.startSample + 1)
    }

    /// The display floor at a real sample position, interpolated between
    /// overview columns.
    ///
    /// Interpolated, not nearest. The track only DECAYS at a bounded rate —
    /// it rises instantly, by design, so that a call is never dimmed by the
    /// silence before it. A nearest-column lookup therefore turns that
    /// instant rise into a hard step at whichever tile column happens to
    /// straddle it, drawn as a vertical edge across the full height of the
    /// image. An overview column is several milliseconds and a tile column is
    /// a fraction of one, so the step was tens of tile columns wide and read
    /// as a seam.
    func effectiveMinDB(atSample sample: Int) -> Float {
        guard !effMinDB.isEmpty else { return Self.absoluteSignalFloorDB - Self.dynamicRangeDB }
        guard effMinDB.count > 1 else { return effMinDB[0] }
        let frac = Double(sample - startSample) / Double(endSample - startSample)
        let x = frac * Double(effMinDB.count - 1)
        let lo = Int(x.rounded(.down))
        guard lo >= 0 else { return effMinDB[0] }
        guard lo < effMinDB.count - 1 else { return effMinDB[effMinDB.count - 1] }
        let t = Float(x - Double(lo))
        return effMinDB[lo] * (1 - t) + effMinDB[lo + 1] * t
    }

    /// Fills `into` with the display floor for `count` columns starting at
    /// `startSample` and stepping `samplesPerColumn` — the per-column
    /// intercept vector a tile's colouring needs.
    func fill(into out: inout [Float], count: Int, startSample: Int, samplesPerColumn: Int) {
        if out.count != count { out = [Float](repeating: 0, count: count) }
        for i in 0..<count {
            out[i] = effectiveMinDB(atSample: startSample + i * samplesPerColumn)
        }
    }
}
