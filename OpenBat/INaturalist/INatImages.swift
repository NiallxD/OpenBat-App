//
//  INatImages.swift
//  OpenBat
//
//  The pictures attached to an iNaturalist observation.
//
//  WHY TWO, AND WHY NEITHER IS THE SCREENSHOT
//  ------------------------------------------
//  The spectrogram is the evidence an identifier actually reads, and the one
//  the player draws is the wrong picture to send:
//
//    1. It spans the whole frequency axis — 0 to 192 kHz at 384 kHz sampling —
//       and a bat call occupies perhaps 30 kHz of that. The rest is a large
//       black rectangle. On iNaturalist's observation page the image is shown
//       a few hundred pixels wide, so the call is squeezed into a sliver of a
//       picture that is mostly nothing.
//    2. It has no axes at all. A spectrogram without a frequency scale can't be
//       measured, and measuring it is exactly what an identifier does.
//
//  EVERY PICTURE IS OF THE SEGMENT
//  -------------------------------
//  Not of the recording on disk. `INatExport.passSegment` cuts the bat pass
//  out of the file, that segment is what gets uploaded as the full-spectrum
//  sound, and `INatImageSources.rebased(on:)` points these renderers at it —
//  so a tile's time axis and the audio's clock are the same number, and the
//  recorder's pre-roll (up to five seconds of dead air, in no attachment
//  anybody can download) never appears in a picture. An identifier reported
//  the mismatch before this held (Niall, 2026-09-06).
//
//  So an observation carries two:
//
//    • A CONTEXT view — the recording with its silence cut out and cropped to
//      the call band with 20 kHz of headroom either side, so the calls fill the
//      frame instead of being six hairlines in a field of black. Its time axis
//      is therefore not linear, which is why it carries no time axis and the
//      numbered tiles, which are linear slices, do.
//    • A DETAIL view — the strongest single call, tightly clipped, with kHz and
//      millisecond axes drawn on it. This is the one somebody zooms into to
//      argue about a species.
//
//  BUILT FROM THE MEASUREMENTS, NOT FROM PIXELS
//  --------------------------------------------
//  The cropped context view is re-colorized from the overview's own `rawTile`
//  at a new frequency band, not cropped out of the finished image. That is the
//  same path the player's noise-floor slider takes (`colorize` does the band
//  crop itself), so the export cannot drift from what the user was looking at,
//  and there is no resampling.
//
//  The detail view reuses `PulseImagePlot` — the same axis-drawing view the
//  pulse detail screen uses — rather than a second, subtly different one. Its
//  labels are environment-coloured, so it is rendered forced to dark on black
//  to match the spectrogram it sits next to.
//
//  BOTH RESPECT THE USER'S NOISE FLOOR
//  -----------------------------------
//  The context view gets it for free, since it re-colorizes. The detail view
//  does NOT: the pulse thumbnail on disk was colorized at whatever floor was in
//  force the night it was detected, which is frequently not the one the user
//  settled on while reviewing the recording. So the close-up is re-rendered
//  from the WAV at the current floor, and the stored thumbnail is only the
//  fallback. The picture somebody decided was worth posting should be the
//  picture that gets posted.
//

import SwiftUI

/// Everything needed to build the pictures, gathered by the player where these
/// values live and rendered later by the sheet. Cheap to construct — no
/// rendering happens until `INatImages.render`.
///
/// Gathered against the whole recording and then pointed at the pass segment
/// by `rebased(on:)` before anything is drawn, so every picture measures the
/// audio that actually gets uploaded.
struct INatImageSources {
    var wavURL: URL
    var overviewRaw: WavSpectrogramEngine.RawTile?
    /// Length of the recording the overview covers, which the silence map needs
    /// to turn columns back into sample positions.
    var overviewTotalSamples: Int
    let sampleRate: Double
    let palette: Palette
    /// The user's own noise-floor setting, so both pictures look like what they
    /// were looking at when they decided the call was worth posting.
    let noiseFloor: Float
    let calibrationCurve: MicCalibrationCurve?
    /// The player's own silence settings, so the exported picture cuts the
    /// same gaps the user was looking at.
    let silenceThresholdDB: Double
    let silencePadding: Double
    /// Which call to draw in detail. Its stored thumbnail is the fallback only
    /// — see `closeUp`.
    let pulse: PulseRecord?
    let pulseImage: UIImage?
    /// Where the audio in `wavURL` starts, to turn a pulse's timestamp into a
    /// sample offset. This is the SEGMENT's start once `rebased` has run, not
    /// the recording's — the two differ by however much pre-roll was cut.
    var recordingStart: Date

    /// The same sources pointed at one pass segment instead of at the whole
    /// recording.
    ///
    /// Every picture is then drawn from the file that actually gets uploaded,
    /// with its first sample as time zero — which is the whole point of the
    /// segment. The overview grid has to be re-analysed rather than cropped
    /// out of the player's, because the player's covers the whole recording
    /// and its columns are that much coarser; re-running the STFT over the
    /// segment alone gives every column of the exported picture its own
    /// measurements.
    ///
    /// Off the main actor: an STFT over a few seconds of 384 kHz audio, while
    /// a sheet is animating in.
    func rebased(on segment: INatExport.PassSegment) async -> INatImageSources {
        guard !segment.isWholeRecording else { return self }
        let url = segment.url
        let samples = segment.range.count
        let curve = calibrationCurve
        let columns = INatExportPlot.pixelWidth
        let raw = await Task.detached(priority: .userInitiated) {
            WavSpectrogramEngine.renderRawTile(wavURL: url, startSample: 0, endSample: samples,
                                               targetColumns: columns, calibrationCurve: curve)
        }.value
        // A segment too short for one STFT window has no grid to draw. Keeping
        // the whole-recording sources would put the pictures back on a
        // different timeline to the sound, so the pictures are dropped
        // instead: the observation still carries its audio, and the sheet's
        // fallback overview covers the thumbnail.
        var rebased = self
        rebased.wavURL = url
        rebased.overviewRaw = raw
        rebased.overviewTotalSamples = samples
        rebased.recordingStart = segment.start(from: recordingStart)
        return rebased
    }
}

@MainActor
enum INatImages {

    /// How much quiet to leave above and below the calls in the context view.
    ///
    /// Not zero: a band clipped to exactly the call is unreadable, because the
    /// eye needs to see that there is nothing above and below it — a
    /// harmonic-rich call and a clipped one look identical without the margin.
    /// 20 kHz is roughly half a call's width, which reads as breathing room
    /// rather than as a crop.
    static let bandPaddingHz: Double = 20_000

    struct Photo {
        let name: String
        let data: Data
    }

    /// Turns one of the export plots into a picture.
    ///
    /// 3× so the tick numbers survive iNaturalist's own downscaling; at 1×
    /// they turn to mush at the size the observation page shows. Every
    /// spectrogram that goes into a plot is analysed at
    /// `INatExportPlot.pixelWidth` columns so it fills those pixels with
    /// measurements rather than with an upscale.
    private static func render(_ plot: INatExportPlot) -> UIImage? {
        let renderer = ImageRenderer(content: plot)
        renderer.scale = INatExportPlot.renderScale
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// How many pixels tall the picture is at a given aspect — what a
    /// spectrogram has to supply to be drawn 1:1 rather than stretched.
    private nonisolated static func pixelHeight(aspect: CGFloat) -> Int {
        Int((CGFloat(INatExportPlot.pixelWidth) / aspect).rounded())
    }

    /// Every exported spectrogram is log-frequency, whatever the player is set
    /// to (Niall, 2026-09-04).
    ///
    /// Not a preference here, unlike the noise floor and the palette. A bat
    /// call's shape — the sweep, how steeply it drops, where it flattens into a
    /// tail — is what an identifier reads, and on a linear axis a 45 kHz
    /// pipistrelle and a 25 kHz noctule are drawn at completely different sizes
    /// for what is the same gesture. A log axis makes them comparable, and the
    /// picture is being posted for people who will compare it with others.
    ///
    /// The axis floors at `LogFrequencyWarp.floorHz`, so the returned band is
    /// what was actually drawn rather than what was asked for — the labels have
    /// to come from this, not from the requested range.
    /// `nonisolated` so the row remap runs wherever it is called from — the
    /// context view warps a full-width overview, and that is not main-actor work.
    ///
    /// `targetHeight` is how many pixels tall the picture will be drawn. The
    /// warp is asked for enough rows to cover it, because at 1:1 the log
    /// stretch drops source rows at the top of the band to make room for the
    /// ones it duplicates at the bottom — and the top of the band is where a
    /// call's harmonics are. See `LogFrequencyWarp.warp`.
    private nonisolated static func logWarped(_ image: UIImage,
                                              band: ClosedRange<Double>,
                                              targetHeight: Int) -> (image: UIImage, band: ClosedRange<Double>) {
        let lo = LogFrequencyWarp.lowerBound(band.lowerBound)
        let rows = max(image.cgImage?.height ?? Int(image.size.height.rounded()), 1)
        // Capped: past a few times over there is nothing left to recover, and
        // the buffer is width × rows × 4 bytes.
        let scale = min(8, max(1, Int((Double(targetHeight) / Double(rows)).rounded(.up))))
        guard band.upperBound > lo,
              let warped = LogFrequencyWarp.warp(image, loHz: band.lowerBound, hiHz: band.upperBound,
                                                 heightScale: scale)
        else { return (image, band) }
        return (warped, lo...band.upperBound)
    }

    /// The images to attach, in the order iNaturalist shows them — which is the
    /// order they are uploaded in.
    ///
    /// **The whole pass first** (Niall, 2026-09-05), then the pass in
    /// consecutive slices, then the one call in close-up. The first image is
    /// the observation's thumbnail everywhere the site lists it, and the
    /// silence-removed whole pass is the one picture that says at a glance
    /// what this observation is: every call in the recording, packed together,
    /// in one frame. A reader who wants more then walks the slices and ends on
    /// the close-up, which is still detail-last.
    ///
    /// This reverses the order shipped on 2026-09-04, where the slices led.
    ///
    /// Filenames are numbered to match, so a reader who downloads all of them
    /// gets them back in this order rather than alphabetically.
    static func render(sources: INatImageSources,
                       pulses: [PulseRecord],
                       fallbackPNG: Data?,
                       silence: SilenceMap?) async -> [Photo] {
        var images: [(name: String, data: Data)] = []

        if let whole = await croppedOverview(sources: sources, pulses: pulses, silence: silence),
           let plot = render(INatExportPlot(image: whole.image, band: whole.band,
                                            timeStart: 0, timeEnd: whole.seconds,
                                            timebase: whole.packed ? .silenceRemoved : .realTime,
                                            title: whole.packed
                                                ? "The whole pass — as the slowed-down audio plays it"
                                                : "The whole pass")),
           let data = plot.pngData() {
            images.append(("whole-pass.png", data))
        } else if let fallbackPNG {
            // The uncropped overview is still worth sending. A picture that is
            // mostly black beats no picture at all.
            images.append(("whole-pass.png", fallbackPNG))
        }

        for tile in await tiles(sources: sources, pulses: pulses) {
            images.append((tile.name, tile.data))
        }

        if let pulse = sources.pulse,
           let linear = await closeUp(pulse: pulse, sources: sources) ?? sources.pulseImage,
           case let aspect = CGFloat(3.0 / 2.0),
           case let warped = logWarped(linear, band: closeUpBand(for: pulse),
                                       targetHeight: pixelHeight(aspect: aspect)),
           let plot = render(INatExportPlot(image: warped.image, band: warped.band,
                                            timeStart: 0, timeEnd: closeUpSpan(for: pulse),
                                            timebase: .realTime,
                                            title: caption(for: pulse),
                                            aspect: aspect)),
           let data = plot.pngData() {
            images.append(("call-close-up.png", data))
        }

        return images.enumerated().map { index, image in
            Photo(name: String(format: "%02d-%@", index + 1, image.name), data: image.data)
        }
    }

    // MARK: The context view

    /// The recording with its silence taken out, cropped to the band the calls
    /// occupy.
    ///
    /// **Silence removed, not just trimmed at the ends** (Niall, 2026-09-04).
    /// A bout is mostly gaps: a ten-second recording with six calls in it draws
    /// six hairlines in a field of black, and at the size iNaturalist shows an
    /// observation photo those hairlines are a few pixels each. Cutting the
    /// gaps out packs the calls together, which is the same thing the player's
    /// own hide-silence does and the reason it exists.
    ///
    /// It is computed here rather than taken from the player, so the picture
    /// does not depend on whether the user happened to have hide-silence
    /// switched on — but from the player's own threshold and padding settings,
    /// so it cuts the same gaps they were looking at.
    ///
    /// The time axis of the result is therefore NOT linear, which is why this
    /// picture carries no time axis and the numbered tiles — which are linear
    /// slices of the real recording — do.
    ///
    /// Runs off the main actor: bounded array maths over a grid already in
    /// memory, but a full pass over it, while a sheet is animating in.
    private static func croppedOverview(sources: INatImageSources, pulses: [PulseRecord],
                                        silence: SilenceMap?)
        async -> (image: UIImage, band: ClosedRange<Double>, seconds: Double, packed: Bool)? {
        guard let raw = sources.overviewRaw, sources.sampleRate > 0 else { return nil }
        let band = callBand(pulses: pulses, nyquist: sources.sampleRate / 2)
        let sampleRate = sources.sampleRate
        let palette = sources.palette
        let floor = sources.noiseFloor
        let total = sources.overviewTotalSamples
        let threshold = sources.silenceThresholdDB
        let padding = sources.silencePadding
        let url = sources.wavURL
        let curve = sources.calibrationCurve
        let columns = INatExportPlot.pixelWidth
        let height = pixelHeight(aspect: 16.0 / 9.0)
        let precomputed = silence
        return await Task.detached(priority: .userInitiated) {
            let map = precomputed ?? SilenceMap.compute(grid: raw.grid, nCols: raw.nCols,
                                                        binCount: STFTGrid.binCount,
                                                        totalSamples: total, sampleRate: sampleRate,
                                                        thresholdAboveFloorDB: threshold,
                                                        minFreqHz: minAnalysisFrequencyHz,
                                                        padSeconds: padding)
            // A recording that is nearly all signal has nothing to gain and
            // something to lose — packing it would make the axis discontinuous
            // for no benefit — so it is drawn as it is.
            let packed = map.keptFraction < 0.9
            // **Re-analysed from the file, not cut out of the overview grid.**
            // Packing keeps only the columns that held sound, so a pass that is
            // 90% gaps leaves a tenth of the overview's columns to fill the
            // whole width of the picture — the calls are then stretched ten
            // times over, which is what "a bit blurry" was and why the packed
            // picture was the blurriest of the three. Re-running the STFT over
            // the retained audio alone gives every one of those columns its own
            // measurements. The silence map still comes from the overview, so
            // the picture cuts exactly the gaps the player did.
            let tile = packed
                ? (WavSpectrogramEngine.renderRawTileStitched(wavURL: url, virtualStart: 0,
                                                              virtualEnd: map.virtualTotal, map: map,
                                                              targetColumns: columns,
                                                              calibrationCurve: curve)
                   ?? WavSpectrogramEngine.compressedOverviewRawTile(from: raw, map: map))
                : raw
            guard let linear = WavSpectrogramEngine.colorize(tile, sampleRate: sampleRate,
                                                            minFreqHz: band.lowerBound,
                                                            maxFreqHz: band.upperBound,
                                                            palette: palette, noiseFloor: floor)?.image
            else { return nil }
            let warped = logWarped(linear, band: band, targetHeight: height)
            // The axis measures what the picture actually contains: the whole
            // recording when nothing was cut, the retained audio when it was.
            let seconds = Double(packed ? map.virtualTotal : total) / sampleRate
            return (warped.image, warped.band, seconds, packed)
        }.value
    }

    /// The least margin the export leaves round a kept run, whatever the
    /// player's own slider says.
    ///
    /// The player defaults to 5 ms, which is right for looking at a
    /// spectrogram and wrong for listening: the audible copy plays at 16×, so
    /// 5 ms of air before a call is 80 ms of it, and every call in the packed
    /// file started abruptly enough to sound clipped (Niall, 2026-09-06). 20 ms
    /// is `SilenceMap.compute`'s own documented default, measured to keep a
    /// real pass's pulses separate rather than merging them, and at 16× it is
    /// a third of a second of room either side of each call.
    ///
    /// A floor, not a replacement: a user who has asked for MORE padding than
    /// this still gets what they asked for, and the seams stay the ones they
    /// were looking at.
    static let minimumPackPaddingSeconds = 0.02

    /// Where the calls are, by the player's own rule.
    ///
    /// Computed once over the whole recording and used for two things that
    /// have to agree: where the pass segment starts and ends, and where the
    /// whole-pass picture's gaps are cut. It is also what `packedToCalls`
    /// splices on, if the audible copy is ever built again. Two independent
    /// computations of "where the calls are" would
    /// eventually disagree. Off the main actor: a full pass over the overview
    /// grid while a sheet is animating in.
    static func silenceMap(sources: INatImageSources) async -> SilenceMap? {
        guard let raw = sources.overviewRaw, sources.sampleRate > 0 else { return nil }
        let sampleRate = sources.sampleRate
        let total = sources.overviewTotalSamples
        let threshold = sources.silenceThresholdDB
        let padding = max(sources.silencePadding, minimumPackPaddingSeconds)
        return await Task.detached(priority: .userInitiated) {
            SilenceMap.compute(grid: raw.grid, nCols: raw.nCols,
                               binCount: STFTGrid.binCount,
                               totalSamples: total, sampleRate: sampleRate,
                               thresholdAboveFloorDB: threshold,
                               minFreqHz: minAnalysisFrequencyHz,
                               padSeconds: padding)
        }.value
    }

    /// Matches `WavPlayerView.minAnalysisFrequencyHz`: silence detection ignores
    /// everything below this, so a rumble in the recording can't count as sound.
    private static let minAnalysisFrequencyHz = 5_000.0

    /// The frequency range worth showing, from where the calls actually are.
    ///
    /// Prefers the bounds stored with each pulse thumbnail — those are the
    /// renderer's own idea of the call's extent, so they include the harmonics
    /// and the sweep, not just the peak. Falls back to peak frequency where a
    /// record predates them, which underestimates the band and is why the
    /// padding is generous.
    private static func callBand(pulses: [PulseRecord], nyquist: Double) -> ClosedRange<Double> {
        var low = Double.greatestFiniteMagnitude
        var high = -Double.greatestFiniteMagnitude
        for pulse in pulses {
            low = min(low, pulse.imageFreqMinHz ?? pulse.peakFreqHz)
            high = max(high, pulse.imageFreqMaxHz ?? pulse.peakFreqHz)
        }
        guard low <= high else { return 0...nyquist }
        return max(0, low - bandPaddingHz)...min(nyquist, high + bandPaddingHz)
    }

    // MARK: The tiled walk-through

    /// How long a slice of recording each tile covers.
    ///
    /// The whole point of tiling is horizontal resolution: one picture of a ten-
    /// second pass gives an identifier a few pixels per call, and the shape of a
    /// call — whether it sweeps, how steeply, where it flattens out — is the
    /// thing they are trying to read. Two seconds across a 16:9 frame is enough
    /// to see individual calls with their structure intact.
    static let tileSeconds: Double = 2

    /// Hard ceiling on how many go up.
    ///
    /// Twelve tiles is a 24-second pass, already far more than an observation
    /// needs, and every one is another upload from a phone in a field and
    /// another image on a page somebody has to scroll. A recording longer than
    /// this gets its first 24 seconds tiled and the context view carries the
    /// rest.
    static let maxTiles = 12

    /// Where each tile starts and ends, in seconds from the segment's start.
    ///
    /// **Every tile covers the same duration, including the last one** (Niall,
    /// 2026-09-06). The final slice used to be whatever was left over — 1.57
    /// seconds against the others' 2 — and it was drawn in the same 16:9 frame,
    /// so every call in it came out about a quarter wider than the same call in
    /// the tile before. Nothing on the page said so, and reading call shape off
    /// these pictures is the whole reason they are numbered slices rather than
    /// one wide strip.
    ///
    /// So every frame covers a full `tileSeconds` and the last one simply runs
    /// out of recording part way across, leaving the rest of it black (Niall,
    /// 2026-09-06). Black is the honest answer — there is no audio there — and
    /// it costs nothing to read, where either alternative costs something: a
    /// short frame silently changes the scale, and stretching the last tile
    /// back to a full span would repeat calls the reader has already counted.
    ///
    /// `audioEnd` is where the recording stops inside the frame. It equals `to`
    /// for every tile but the last, and for that one the difference is how much
    /// of the picture is empty.
    ///
    /// A pass longer than `maxTiles` covers is truncated, not compressed: the
    /// last tile is then a full frame in the middle of the recording, with no
    /// black in it at all, and the context view carries the rest.
    static func spans(count: Int, totalSeconds: Double) -> [(from: Double, to: Double, audioEnd: Double)] {
        (0..<count).compactMap { index in
            let from = Double(index) * tileSeconds
            let to = from + tileSeconds
            let audioEnd = min(totalSeconds, to)
            return audioEnd > from ? (from, to, audioEnd) : nil
        }
    }

    /// Puts a short tile at the left of a full-width frame and leaves the rest
    /// black.
    ///
    /// `filled` is how much of the frame the picture occupies, 0–1. The canvas
    /// is sized from the image's own pixels rather than from a point size, so
    /// nothing here depends on the screen scale of a device that is not
    /// involved — these are rendered offscreen.
    private static func inFullWidthFrame(_ image: UIImage, filled: Double) -> UIImage {
        guard filled > 0, filled < 1, let cg = image.cgImage else { return image }
        let height = cg.height
        let full = Int((Double(cg.width) / filled).rounded())
        guard full > cg.width, height > 0 else { return image }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: full, height: height)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(x: 0, y: 0, width: cg.width, height: height))
        }
    }

    /// The pass walked through in order, each tile a 16:9 frame.
    ///
    /// **Slices of the SEGMENT, not of the recording** (Niall, 2026-09-06).
    /// These used to be cut from the file on disk starting at its first
    /// sample, so "Part 1 of 6, 0–2 s" was the recorder's pre-roll — dead air
    /// that appears in no attachment anybody can download — and every later
    /// tile's clock was offset from the audio by however much was trimmed off
    /// the front. Cut from the segment, tile time and audio time are the same
    /// number, and the pre-roll drops out because it is outside the segment.
    ///
    /// Skipped entirely for a pass short enough that the context view already
    /// shows it at full resolution — a single tile that duplicates the picture
    /// above it is just noise on the page.
    private static func tiles(sources: INatImageSources,
                              pulses: [PulseRecord]) async -> [Photo] {
        guard sources.sampleRate > 0, let raw = sources.overviewRaw else { return [] }
        let totalSeconds = Double(raw.endSample - raw.startSample) / sources.sampleRate
        guard totalSeconds > tileSeconds * 1.5 else { return [] }

        let band = callBand(pulses: pulses, nyquist: sources.sampleRate / 2)
        let count = min(maxTiles, Int((totalSeconds / tileSeconds).rounded(.up)))

        var photos: [Photo] = []
        for (index, span) in spans(count: count, totalSeconds: totalSeconds).enumerated() {
            // Analysed at as many columns as the picture will actually occupy,
            // so a part-empty last tile is drawn at the same density as the
            // full ones rather than at a finer one stretched to fit.
            let filled = (span.audioEnd - span.from) / tileSeconds
            let columns = max(1, Int((Double(INatExportPlot.pixelWidth) * filled).rounded()))
            guard let linear = await tile(from: span.from, to: span.audioEnd, columns: columns,
                                          band: band, sources: sources) else { continue }
            let warped = logWarped(linear, band: band, targetHeight: pixelHeight(aspect: 16.0 / 9.0))
            // Framed after the warp, so the warp only ever sees real audio.
            let framed = inFullWidthFrame(warped.image, filled: filled)
            guard let plot = render(INatExportPlot(image: framed, band: warped.band,
                                                   timeStart: span.from, timeEnd: span.to,
                                                   timebase: .realTime,
                                                   title: "Part \(index + 1) of \(count)")),
                  let data = plot.pngData()
            else { continue }
            photos.append(Photo(name: String(format: "part-%02d.png", index + 1), data: data))
        }
        return photos
    }

    /// One slice, rendered from the file at the user's own noise floor and
    /// stretched to 16:9.
    ///
    /// Rendered at exactly as many columns as the finished PNG has pixels
    /// across (`INatExportPlot.pixelWidth`), and then let the frame do the
    /// aspect: the tile's natural height is however many frequency bins the
    /// band covers, which is nothing like 9/16 of its width, so the picture is
    /// scaled into the frame rather than cropped to it. Stretching a
    /// spectrogram is normal — both axes are already arbitrary scales — and
    /// cropping would throw away the frequencies this is meant to show.
    private static func tile(from: Double, to: Double, columns: Int,
                             band: ClosedRange<Double>,
                             sources: INatImageSources) async -> UIImage? {
        let url = sources.wavURL, rate = sources.sampleRate
        let palette = sources.palette, floor = sources.noiseFloor
        let curve = sources.calibrationCurve
        let start = Int(from * rate), end = Int(to * rate)
        guard end > start else { return nil }
        return await Task.detached(priority: .userInitiated) {
            WavSpectrogramEngine.renderDetailTile(wavURL: url, sampleRate: rate,
                                                  startSample: start, endSample: end,
                                                  minFreqHz: band.lowerBound,
                                                  maxFreqHz: band.upperBound,
                                                  targetColumns: columns,
                                                  palette: palette, noiseFloor: floor,
                                                  calibrationCurve: curve)?.image
        }.value
    }

    // MARK: The detail view

    /// Re-renders the call from the WAV at the noise floor the user currently
    /// has set, rather than reusing the thumbnail stored when it was detected.
    ///
    /// The thumbnail was colorized at whatever floor was in force that night,
    /// which is often not what the user settled on while reviewing — and the
    /// picture they decided was worth posting is the one they were looking at.
    /// Falls back to the stored thumbnail when the file can't be re-read.
    ///
    /// **A pulse's timestamp is not a position in the file.** `CapturedPulse`
    /// stamps `Date()` at the moment the classifier finished, so it carries
    /// whatever latency the capture and classification pipeline had — tens of
    /// milliseconds, unpredictably. Cropping straight to that offset lands next
    /// to the call rather than on it, and at these spans "next to the call" is
    /// usually its echo off the ground or a wall: a few milliseconds later,
    /// same frequency, and completely convincing as a call in a picture with no
    /// context. That is what this looked like before (Niall, 2026-09-04).
    ///
    /// So the timestamp is treated as a hint, and the picture is centred on
    /// what is actually there: the loudest moment in the call band within a
    /// quarter-second of the estimate. That fixes the latency and the echo in
    /// one go, because a direct call is louder than its own echo.
    private static func closeUp(pulse: PulseRecord, sources: INatImageSources) async -> UIImage? {
        guard sources.sampleRate > 0 else { return nil }
        let band = closeUpBand(for: pulse)
        let span = closeUpSpan(for: pulse)
        let estimate = pulse.date.timeIntervalSince(sources.recordingStart) + (pulse.durationMs / 2000)

        let url = sources.wavURL, rate = sources.sampleRate
        let palette = sources.palette, floor = sources.noiseFloor
        let curve = sources.calibrationCurve
        let columns = INatExportPlot.pixelWidth
        return await Task.detached(priority: .userInitiated) {
            let centre = loudestMoment(near: estimate, band: band, wavURL: url,
                                       sampleRate: rate, calibrationCurve: curve) ?? estimate
            let start = max(0, Int((centre - span / 2) * rate))
            let end = Int((centre + span / 2) * rate)
            guard end > start else { return nil }
            return WavSpectrogramEngine.renderDetailTile(wavURL: url, sampleRate: rate,
                                                         startSample: start, endSample: end,
                                                         minFreqHz: band.lowerBound,
                                                         maxFreqHz: band.upperBound,
                                                         targetColumns: columns,
                                                         palette: palette, noiseFloor: floor,
                                                         calibrationCurve: curve)?.image
        }.value
    }

    /// How far either side of a pulse's timestamp to look for the call itself.
    ///
    /// Has to cover the pipeline latency described in `closeUp` with room to
    /// spare, and stay narrow enough that it can't wander onto the NEXT call —
    /// bats call several times a second, so a quarter-second each way is close
    /// to the most that is safe.
    private static let searchWindowSeconds = 0.25

    /// The moment of most energy in the call band, near `estimate`.
    ///
    /// Measured off the raw dB grid rather than the colorized picture: the
    /// colouring has a noise gate and an adaptive per-column ceiling in it, so
    /// the brightest pixel and the loudest sound are not the same question.
    ///
    /// nil when the window can't be read, and the caller falls back to the
    /// estimate — a slightly mis-centred picture beats no picture.
    private nonisolated static func loudestMoment(near estimate: TimeInterval,
                                                  band: ClosedRange<Double>,
                                                  wavURL: URL,
                                                  sampleRate: Double,
                                                  calibrationCurve: MicCalibrationCurve?) -> TimeInterval? {
        let from = max(0, estimate - searchWindowSeconds)
        let to = estimate + searchWindowSeconds
        let startSample = Int(from * sampleRate)
        let endSample = Int(to * sampleRate)
        guard endSample > startSample,
              let raw = WavSpectrogramEngine.renderRawTile(wavURL: wavURL,
                                                           startSample: startSample,
                                                           endSample: endSample,
                                                           targetColumns: 512,
                                                           calibrationCurve: calibrationCurve),
              raw.nCols > 0
        else { return nil }

        let bins = STFTGrid.binCount
        let hzPerBin = (sampleRate / 2) / Double(bins)
        let lowBin = min(max(Int(band.lowerBound / hzPerBin), 0), bins - 1)
        let highBin = min(max(Int(band.upperBound / hzPerBin), lowBin), bins - 1)

        var bestColumn = 0
        var bestEnergy = -Double.greatestFiniteMagnitude
        for col in 0..<raw.nCols {
            var peak = -Double.greatestFiniteMagnitude
            for bin in lowBin...highBin {
                peak = max(peak, Double(raw.grid[bin * raw.nCols + col]))
            }
            if peak > bestEnergy { bestEnergy = peak; bestColumn = col }
        }

        // `renderRawTile` pools to at most `targetColumns`, so a column is a
        // fraction of the window rather than a fixed hop — the position has to
        // come from the ratio, not from a column count times a hop size.
        let progress = (Double(bestColumn) + 0.5) / Double(raw.nCols)
        return from + progress * (to - from)
    }

    /// Room around the call in the close-up.
    ///
    /// The stored crop is as tight as it can be — it was cut to feed a
    /// classifier, where every pixel that isn't the call is wasted input. A
    /// picture for a person is the opposite: a call filling its frame edge to
    /// edge gives a reader no way to see that nothing was cut off, and no quiet
    /// to judge the call against. Widened on both axes (Niall, 2026-09-04).
    ///
    /// Still far tighter than the context view's 20 kHz, because this picture
    /// exists to be measured.
    /// Lopsided on purpose (Niall, 2026-09-04: "this one looks just clipped").
    ///
    /// A call's harmonics run UPWARDS, and the stored crop stops at the highest
    /// energy the classifier cared about — so a tight top edge cuts through a
    /// harmonic and leaves the call looking truncated whether it was or not.
    /// The bottom needs far less: below the fundamental there is nothing to cut
    /// through, only quiet, and the log axis is already giving the low end more
    /// of the picture than the high end.
    static let closeUpPaddingAboveHz: Double = 18_000
    static let closeUpPaddingBelowHz: Double = 6_000
    static let closeUpTimeFactor: Double = 3

    private static func closeUpBand(for pulse: PulseRecord) -> ClosedRange<Double> {
        if let low = pulse.imageFreqMinHz, let high = pulse.imageFreqMaxHz, high > low {
            return max(0, low - closeUpPaddingBelowHz)...(high + closeUpPaddingAboveHz)
        }
        return max(0, pulse.peakFreqHz - closeUpPaddingBelowHz)...(pulse.peakFreqHz + closeUpPaddingAboveHz)
    }

    /// How much recording the close-up covers, in seconds.
    ///
    /// Three times the call's own window. Bats call several times a second, so
    /// at these lengths that is still comfortably inside the gap to the next
    /// call — it buys silence either side, not a second bat.
    private static func closeUpSpan(for pulse: PulseRecord) -> TimeInterval {
        let base = pulse.imageSpanMs ?? max(pulse.durationMs * 3, 8)
        return base * closeUpTimeFactor / 1000
    }

    private static func caption(for pulse: PulseRecord) -> String {
        let name = SpeciesInfo.commonName[pulse.species] ?? pulse.species
        return String(format: "%@ (AutoID) · peak %.0f kHz · %.1f ms · OpenBat",
                      name, pulse.peakFreqHz / 1000, pulse.durationMs)
    }
}
