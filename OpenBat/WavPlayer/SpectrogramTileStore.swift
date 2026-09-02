//
//  SpectrogramTileStore.swift
//  OpenBat
//
//  Renders and caches the tiles `SpectrogramPyramid` addresses.
//
//  **Tiles hold quantised dB, not pixels.** 8 bits per cell across a 100 dB
//  range is 0.4 dB a step, against a 70 dB display range — invisible, and an
//  eighth the size of the Float grid the per-render path keeps. Storing the
//  measurement rather than the picture is what makes a palette change, a
//  noise-floor change or a frequency pan a recolour (milliseconds) instead of
//  a re-render (hundreds of milliseconds), and it is why the picture cache
//  below can be small and disposable while the data cache is the one that
//  matters.
//
//  Colouring is possible at all only because the contrast mapping is fixed
//  for the recording (see `SpectrogramContrast`); a tile's picture therefore
//  depends on nothing but the tile, the palette and the noise floor, so it is
//  identical for every viewport that shows it.
//
//  Threading: rendering happens off the main actor and is serialised per key
//  so two viewports asking for the same tile at once produce one render, not
//  two. The caches are lock-guarded and may be read from anywhere.
//

import UIKit
import Accelerate

nonisolated final class SpectrogramTileStore: @unchecked Sendable {

    /// The dB range quantisation spans. Wide enough to hold anything the STFT
    /// produces above the noise, and the floor is well below the display's own
    /// (`absoluteSignalFloorDB - dynamicRangeDB` = −110 dB).
    static let minStoredDB: Float = -120
    static let maxStoredDB: Float = 0

    /// One tile's measurements: `binCount x tileColumns` quantised dB,
    /// bin-major to match `WavSpectrogramEngine.RawTile`.
    struct DataTile {
        let key: SpectrogramPyramid.Key
        let quantised: [UInt8]
        let nCols: Int
        let startSample: Int
        let endSample: Int
    }

    private let wavURL: URL
    private let sampleRate: Double
    private let totalSamples: Int
    private let calibrationCurve: MicCalibrationCurve?
    private let contrast: SpectrogramContrast

    /// Budgets, in bytes. Data is the expensive, valuable cache — at a 30 s
    /// recording it holds the whole file at playback zoom, which is the point.
    /// Pictures are cheap to rebuild from data, so that cache is smaller and
    /// is thrown away wholesale whenever the palette or noise floor moves.
    ///
    /// The picture budget covers TWO levels now, not one: the view fills a
    /// coarse fallback level alongside the sharp one (see
    /// `assembleBestCovering`), and evicting the fallback to make room for
    /// the tiles it exists to cover for would defeat it.
    private let dataBudget: Int
    private let pictureBudget: Int

    /// A coloured tile, as PALETTE INDICES rather than as a `CGImage`.
    ///
    /// Bytes, because assembling several tiles into the one image the display
    /// wants is then a memcpy per bin row. Going through a graphics context
    /// instead would mean allocating and drawing a multi-megabyte RGBA canvas
    /// every time the view crossed a tile boundary, which is precisely the
    /// kind of per-frame cost this whole design exists to remove.
    struct ColouredTile {
        let indices: [UInt8]     // binCount rows x nCols, row 0 = top = high frequency
        let nCols: Int
        let startSample: Int
        let endSample: Int
    }

    /// A condition rather than a plain lock, purely so a caller asking for a
    /// tile someone else is already rendering can WAIT for it.
    ///
    /// It used to be handed back nil instead, on the reasoning that the caller
    /// would try again. With one filler that was true; with two — the view's
    /// own on-demand fill and the playback prefill (see
    /// `WavPlayerView.startPyramidPrefill`) — it meant the loser of the race
    /// dropped that tile from ITS batch, so `assemble` kept finding a hole and
    /// the view sat on the coarse overview crop until the next throttle tick
    /// came round. Waiting costs a blocked background thread for the length of
    /// one render and removes the hole entirely.
    private let lock = NSCondition()
    private var data: [SpectrogramPyramid.Key: DataTile] = [:]
    private var dataOrder: [SpectrogramPyramid.Key] = []      // oldest first
    private var pictures: [SpectrogramPyramid.Key: ColouredTile] = [:]
    private var pictureOrder: [SpectrogramPyramid.Key] = []
    private var inFlight: Set<SpectrogramPyramid.Key> = []
    /// The last image `assemble` built, and the tile set it was built from.
    ///
    /// **Without this the fixed grid still stuttered**, because the display
    /// asks for an image on every viewport change — including the ~30 Hz
    /// playback ticks — and joining the tiles allocated and copied a
    /// multi-megabyte buffer every single time, even though the covering
    /// tiles had not changed. The whole point of tile-aligned bounds is that
    /// they DON'T change as the view moves inside them, so the answer can
    /// simply be handed back.
    private var lastAssembly: (level: Int, lo: Int, hi: Int, tile: WavSpectrogramEngine.DetailTile)?

    init(wavURL: URL, sampleRate: Double, totalSamples: Int,
         calibrationCurve: MicCalibrationCurve?, contrast: SpectrogramContrast,
         dataBudgetBytes: Int = 96 << 20, pictureBudgetBytes: Int = 48 << 20) {
        self.wavURL = wavURL
        self.sampleRate = sampleRate
        self.totalSamples = totalSamples
        self.calibrationCurve = calibrationCurve
        self.contrast = contrast
        self.dataBudget = dataBudgetBytes
        self.pictureBudget = pictureBudgetBytes
    }

    // MARK: Lookup

    /// A tile if it is already coloured, without doing any work.
    func cachedPicture(_ key: SpectrogramPyramid.Key) -> ColouredTile? {
        lock.lock(); defer { lock.unlock() }
        if let tile = pictures[key] { touchPicture(key); return tile }
        return nil
    }

    func hasData(_ key: SpectrogramPyramid.Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return data[key] != nil
    }

    /// Marks every cached picture stale — call when the palette or noise
    /// floor changes. The measurements survive, so recolouring is cheap.
    func invalidatePictures() {
        lock.lock()
        pictures.removeAll(keepingCapacity: true)
        pictureOrder.removeAll(keepingCapacity: true)
        lastAssembly = nil
        lock.unlock()
    }

    // MARK: Producing a tile

    /// Renders `key` if it is not already cached, and colours it. Returns nil
    /// only if the tile lies outside the recording or the render fails.
    ///
    /// Safe to call from several places at once: a key already being rendered
    /// is not started twice.
    func picture(for key: SpectrogramPyramid.Key, palette: Palette, noiseFloor: Float) -> ColouredTile? {
        if let cached = cachedPicture(key) { return cached }
        guard let tile = dataTile(for: key) else { return nil }
        guard let coloured = colorize(tile, palette: palette, noiseFloor: noiseFloor) else { return nil }
        lock.lock()
        pictures[key] = coloured
        pictureOrder.append(key)
        trimPictures()
        lock.unlock()
        return coloured
    }

    /// Builds the one image the display wants, covering whole tiles across
    /// `[startSample, endSample)` at `level`, and reports the span it really
    /// covers — which is wider than asked for, because it is tile-aligned.
    /// That alignment IS the margin: the view can move anywhere inside these
    /// bounds without needing anything new.
    ///
    /// Returns nil if any covering tile is missing, so the caller can fall
    /// back to the overview and request the tiles in the background.
    func assemble(level: Int, startSample: Int, endSample: Int,
                  palette: Palette, noiseFloor: Float) -> WavSpectrogramEngine.DetailTile? {
        let indices = SpectrogramPyramid.tileIndices(level: level, startSample: startSample,
                                                     endSample: endSample)
        lock.lock()
        if let last = lastAssembly, last.level == level,
           last.lo == indices.lowerBound, last.hi == indices.upperBound {
            lock.unlock()
            return last.tile
        }
        lock.unlock()

        var parts: [ColouredTile] = []
        parts.reserveCapacity(indices.count)
        for index in indices {
            guard let tile = cachedPicture(SpectrogramPyramid.Key(level: level, index: index))
            else { return nil }
            parts.append(tile)
        }
        guard let first = parts.first, let last = parts.last else { return nil }
        let bins = STFTGrid.binCount
        let totalCols = parts.reduce(0) { $0 + $1.nCols }
        guard totalCols > 0 else { return nil }

        // One memcpy per bin row per tile — no drawing, no colour conversion.
        var joined = [UInt8](repeating: 0, count: totalCols * bins)
        joined.withUnsafeMutableBufferPointer { dst in
            var colOffset = 0
            for part in parts {
                part.indices.withUnsafeBufferPointer { src in
                    for bin in 0..<bins {
                        (dst.baseAddress! + bin * totalCols + colOffset)
                            .update(from: src.baseAddress! + bin * part.nCols, count: part.nCols)
                    }
                }
                colOffset += part.nCols
            }
        }

        let lut = DisplayColormap.makeLUT(palette: palette)
        var colorTable = [UInt8](repeating: 0, count: lut.count * 3)
        for i in 0..<lut.count {
            let (r, g, b) = lut[i]
            colorTable[i * 3] = r; colorTable[i * 3 + 1] = g; colorTable[i * 3 + 2] = b
        }
        let pixelData = joined.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let baseSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let indexed = CGColorSpace(indexedBaseSpace: baseSpace,
                                         last: lut.count - 1, colorTable: &colorTable),
              let provider = CGDataProvider(data: pixelData as CFData),
              let cg = CGImage(width: totalCols, height: bins, bitsPerComponent: 8, bitsPerPixel: 8,
                               bytesPerRow: totalCols, space: indexed,
                               bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        let assembled = WavSpectrogramEngine.DetailTile(
            image: UIImage(cgImage: cg),
            startSample: first.startSample, endSample: last.endSample,
            minFreqHz: 0, maxFreqHz: sampleRate / 2)
        lock.lock()
        lastAssembly = (level, indices.lowerBound, indices.upperBound, assembled)
        lock.unlock()
        return assembled
    }

    /// The tiles `[startSample, endSample)` needs at `level` that are not
    /// coloured yet, nearest-first from `startSample` — what a background
    /// fill should work through.
    func missingTiles(level: Int, startSample: Int, endSample: Int) -> [SpectrogramPyramid.Key] {
        SpectrogramPyramid.tileIndices(level: level, startSample: startSample, endSample: endSample)
            .map { SpectrogramPyramid.Key(level: level, index: $0) }
            .filter { cachedPicture($0) == nil }
    }

    /// The same list, but ordered outward from the tile `pivot` falls in and
    /// **forward first** — the order a playhead actually needs them in.
    ///
    /// Plain index order looks harmless and is not: a fill window that reaches
    /// behind the playhead as well as ahead of it renders all of the history
    /// before touching anything in front, so the first thing playback needs is
    /// the last thing built. That is worth a second of low resolution at every
    /// tile boundary in time expansion, where a tile is only a second or so of
    /// listening.
    func missingTilesFromPlayhead(level: Int, startSample: Int, endSample: Int,
                                  pivot: Int) -> [SpectrogramPyramid.Key] {
        let missing = missingTiles(level: level, startSample: startSample, endSample: endSample)
        let here = SpectrogramPyramid.tileIndex(level: level, sample: pivot)
        let ahead = missing.filter { $0.index >= here }.sorted { $0.index < $1.index }
        let behind = missing.filter { $0.index < here }.sorted { $0.index > $1.index }
        return ahead + behind
    }

    /// The widest run of ALREADY-CACHED tiles around `[requiredStart,
    /// requiredEnd)`, or nil if that required span is not fully cached itself.
    ///
    /// **`assemble` is all-or-nothing over whatever range it is handed, which
    /// makes a speculative lead a precondition rather than an optimisation.**
    /// Asked for the visible frame plus three screens of runway, it returned
    /// nothing at all until the last of that runway had rendered — so the view
    /// sat on the coarse overview crop while the tiles directly under it were
    /// sitting in the cache, ready. In time expansion, where a tile is a
    /// fraction of a second of recording and the runway is several tiles, that
    /// was most of the time.
    ///
    /// This separates the two: the required span is the visible frame and
    /// nothing more, so the picture goes sharp the moment it can, and the
    /// margin is whatever happens to be cached beyond it — growing on its own
    /// as a background fill lands, never blocking on it. `maxTiles` caps the
    /// join so a fully-cached recording doesn't rebuild a whole-file image on
    /// a tile boundary.
    func assembleCovering(level: Int, requiredStart: Int, requiredEnd: Int, maxTiles: Int,
                          palette: Palette, noiseFloor: Float) -> WavSpectrogramEngine.DetailTile? {
        let required = SpectrogramPyramid.tileIndices(level: level, startSample: requiredStart,
                                                      endSample: requiredEnd)
        for index in required where cachedPicture(SpectrogramPyramid.Key(level: level, index: index)) == nil {
            return nil
        }
        var lo = required.lowerBound, hi = required.upperBound
        // Forward first, so the margin that grows is the one playback will use.
        while hi - lo + 1 < maxTiles,
              cachedPicture(SpectrogramPyramid.Key(level: level, index: hi + 1)) != nil {
            hi += 1
        }
        while hi - lo + 1 < maxTiles, lo > 0,
              cachedPicture(SpectrogramPyramid.Key(level: level, index: lo - 1)) != nil {
            lo -= 1
        }
        let range = SpectrogramPyramid.sampleRange(level: level, index: lo).lowerBound
            ..< SpectrogramPyramid.sampleRange(level: level, index: hi).upperBound
        return assemble(level: level, startSample: range.lowerBound, endSample: range.upperBound,
                        palette: palette, noiseFloor: noiseFloor)
    }

    /// The best picture available for `[requiredStart, requiredEnd)`: the
    /// level asked for if its tiles are cached, otherwise the finest COARSER
    /// level that is.
    ///
    /// **This is what stops a late tile falling all the way to the whole-file
    /// overview.** `assembleCovering` is all-or-nothing, so one tile that has
    /// not landed yet used to drop the picture from a tile's ~2048 columns to
    /// whatever slice of a 4096-column whole-file image the viewport happened
    /// to cover — 77 columns stretched across the screen on a 5 s recording at
    /// 16x, which is the sudden blur. A level two steps coarser is 4x fewer
    /// samples per tile than the sharp one wants and still an order of
    /// magnitude finer than the overview, so the fallback is now a step rather
    /// than a cliff. The level actually used comes back so the caller can tell
    /// a fallback from the real thing and keep trying to upgrade.
    func assembleBestCovering(preferredLevel: Int, requiredStart: Int, requiredEnd: Int,
                              maxTiles: Int, coarserLevels: Int,
                              palette: Palette, noiseFloor: Float)
        -> (tile: WavSpectrogramEngine.DetailTile, level: Int)? {
        let last = min(preferredLevel + max(coarserLevels, 0), SpectrogramPyramid.levelCount - 1)
        for level in preferredLevel...max(preferredLevel, last) {
            if let tile = assembleCovering(level: level, requiredStart: requiredStart,
                                           requiredEnd: requiredEnd, maxTiles: maxTiles,
                                           palette: palette, noiseFloor: noiseFloor) {
                return (tile, level)
            }
        }
        return nil
    }

    /// Whether `key` is already coloured — the no-work question
    /// `refreshPyramidDisplay` asks before deciding a re-join would actually
    /// gain it anything.
    func hasPicture(_ key: SpectrogramPyramid.Key) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return pictures[key] != nil
    }

    /// The measurements for `key`, rendering them if needed.
    func dataTile(for key: SpectrogramPyramid.Key) -> DataTile? {
        lock.lock()
        // Someone else is on it — wait for them rather than racing or giving
        // up. On the way out of the wait the tile is normally in `data`; if
        // that render failed it is not, and this caller renders it itself.
        while inFlight.contains(key) { lock.wait() }
        if let tile = data[key] { touchData(key); lock.unlock(); return tile }
        inFlight.insert(key)
        lock.unlock()
        defer { lock.lock(); inFlight.remove(key); lock.broadcast(); lock.unlock() }

        guard let tile = render(key) else { return nil }
        lock.lock()
        data[key] = tile
        dataOrder.append(key)
        trimData()
        lock.unlock()
        return tile
    }

    private func render(_ key: SpectrogramPyramid.Key) -> DataTile? {
        let range = SpectrogramPyramid.sampleRange(level: key.level, index: key.index)
        let start = range.lowerBound
        let end = min(range.upperBound, totalSamples)
        guard start < end else { return nil }
        let spc = SpectrogramPyramid.samplesPerColumn(level: key.level)

        // **Read PAST the tile's end, by one analysis window less one hop.**
        //
        // An STFT frame starting at `s` covers `[s, s + windowLen)`, so the
        // last frame that fits inside a span starts `windowLen` short of its
        // end — the frames cover less audio than the span does. Rendering
        // each tile against its own bounds therefore made every tile slightly
        // time-compressed, and that error lands at each join: visible seams,
        // exactly what a fixed grid is supposed to avoid. `renderRawTile`
        // solves the same problem for the untiled path by reporting the real
        // covered span, but a tile cannot do that — its bounds are fixed by
        // the grid — so it has to read the overhang instead.
        //
        // With the overhang the frame grid spans the whole tile, every bucket
        // pools exactly `spc / hop` frames, and bucket b covers exactly
        // `[start + b*spc, start + (b+1)*spc)`. Tiles then abut sample-for-
        // sample. At the file's tail there is nothing to overhang into, so
        // the tile simply comes back narrower — hence reading `nCols` back
        // rather than assuming it.
        let readEnd = min(totalSamples, end + STFTGrid.windowLen - STFTGrid.hop)
        guard readEnd - start >= STFTGrid.windowLen else { return nil }
        var scratch = STFTGrid.Scratch()
        let columns = max(1, (end - start) / spc)
        guard let (grid, nCols) = STFTGrid.streamPooledGridFromFile(
            wavURL: wavURL, startSample: start, endSample: readEnd,
            targetColumns: columns, scratch: &scratch,
            frameHop: STFTGrid.hop, calibrationCurve: calibrationCurve)
        else { return nil }

        // Quantise: (dB - min) * 255 / (max - min), clipped.
        let bins = STFTGrid.binCount
        let cells = bins * nCols
        var scaled = [Float](repeating: 0, count: cells)
        var slope = 255 / (Self.maxStoredDB - Self.minStoredDB)
        var offset = -Self.minStoredDB * slope
        var lo: Float = 0, hi: Float = 255
        grid.withUnsafeBufferPointer { g in
            vDSP_vsmsa(g.baseAddress!, 1, &slope, &offset, &scaled, 1, vDSP_Length(cells))
        }
        vDSP_vclip(scaled, 1, &lo, &hi, &scaled, 1, vDSP_Length(cells))
        var quantised = [UInt8](repeating: 0, count: cells)
        scaled.withUnsafeBufferPointer { s in
            quantised.withUnsafeMutableBufferPointer { q in
                vDSP_vfixu8(s.baseAddress!, 1, q.baseAddress!, 1, vDSP_Length(cells))
            }
        }
        return DataTile(key: key, quantised: quantised, nCols: nCols,
                        startSample: start, endSample: start + nCols * spc)
    }

    // MARK: Colouring

    /// Full bin height, and independent of any viewport — see this file's
    /// header. The result is cropped, not re-rendered, to show any window.
    private func colorize(_ tile: DataTile, palette: Palette, noiseFloor: Float) -> ColouredTile? {
        let bins = STFTGrid.binCount
        let nCols = tile.nCols
        guard nCols > 0, tile.quantised.count >= bins * nCols else { return nil }

        let lut = DisplayColormap.makeLUT(palette: palette)

        // Undo quantisation and apply the same fused map `colorize` uses, with
        // the per-column floor coming from the recording-wide contrast track.
        let deq = (Self.maxStoredDB - Self.minStoredDB) / 255
        let floor = min(max(noiseFloor, 0), 0.99)
        let invSpan = 1 / max(0.01, 1 - floor)
        let invRange = 1 / SpectrogramContrast.dynamicRangeDB
        let steps = Float(lut.count - 1)

        var intercept = [Float](repeating: 0, count: nCols)
        contrast.fill(into: &intercept, count: nCols, startSample: tile.startSample,
                      samplesPerColumn: SpectrogramPyramid.samplesPerColumn(level: tile.key.level))
        // effMin -> the intercept the fused map wants.
        for i in 0..<nCols {
            intercept[i] = ((-intercept[i]) * invRange - floor) * invSpan * steps
        }
        var slope = deq * invRange * invSpan * steps
        var base = Self.minStoredDB * invRange * invSpan * steps
        var lo: Float = 0, hi = steps

        var row = [Float](repeating: 0, count: nCols)
        var pixels = [UInt8](repeating: 0, count: nCols * bins)
        tile.quantised.withUnsafeBufferPointer { q in
            pixels.withUnsafeMutableBufferPointer { px in
                for bin in 0..<bins {
                    let src = q.baseAddress! + bin * nCols
                    vDSP_vfltu8(src, 1, &row, 1, vDSP_Length(nCols))
                    vDSP_vsmsa(row, 1, &slope, &base, &row, 1, vDSP_Length(nCols))
                    vDSP_vadd(row, 1, intercept, 1, &row, 1, vDSP_Length(nCols))
                    vDSP_vclip(row, 1, &lo, &hi, &row, 1, vDSP_Length(nCols))
                    let dst = (bins - 1 - bin) * nCols     // row 0 = top = high frequency
                    row.withUnsafeBufferPointer { r in
                        vDSP_vfixu8(r.baseAddress!, 1, px.baseAddress! + dst, 1, vDSP_Length(nCols))
                    }
                }
            }
        }

        return ColouredTile(indices: pixels, nCols: nCols,
                            startSample: tile.startSample, endSample: tile.endSample)
    }

    // MARK: Cache bookkeeping (caller holds `lock`)

    private func touchData(_ key: SpectrogramPyramid.Key) {
        if let i = dataOrder.firstIndex(of: key) { dataOrder.remove(at: i) }
        dataOrder.append(key)
    }

    private func touchPicture(_ key: SpectrogramPyramid.Key) {
        if let i = pictureOrder.firstIndex(of: key) { pictureOrder.remove(at: i) }
        pictureOrder.append(key)
    }

    private func trimData() {
        let perTile = STFTGrid.binCount * SpectrogramPyramid.tileColumns
        while dataOrder.count * perTile > dataBudget, let oldest = dataOrder.first {
            dataOrder.removeFirst()
            data[oldest] = nil
        }
    }

    private func trimPictures() {
        let perTile = STFTGrid.binCount * SpectrogramPyramid.tileColumns
        while pictureOrder.count * perTile > pictureBudget, let oldest = pictureOrder.first {
            pictureOrder.removeFirst()
            pictures[oldest] = nil
        }
    }
}
