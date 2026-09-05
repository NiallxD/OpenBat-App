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
struct INatImageSources {
    let wavURL: URL
    let overviewRaw: WavSpectrogramEngine.RawTile?
    /// Length of the recording the overview covers, which the silence map needs
    /// to turn columns back into sample positions.
    let overviewTotalSamples: Int
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
    /// — see `pulsePlot`.
    let pulse: PulseRecord?
    let pulseImage: UIImage?
    /// Where the recording starts, to turn a pulse's timestamp into a sample
    /// offset.
    let recordingStart: Date
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

    /// The images to attach, in the order iNaturalist shows them — which is the
    /// order they are uploaded in.
    ///
    /// **Detail first, summary after** (Niall, 2026-09-04): the pass in
    /// consecutive slices, then the whole pass, then the one call in close-up.
    /// It reads the way somebody actually works through an acoustic record —
    /// walk the sequence, see where it sits as a whole, then look hard at one
    /// call — rather than the way a page thumbnail would prefer.
    ///
    /// Filenames are numbered to match, so a reader who downloads all of them
    /// gets them back in this order rather than alphabetically.
    static func render(sources: INatImageSources,
                       pulses: [PulseRecord],
                       fallbackPNG: Data?) async -> [Photo] {
        var images: [(name: String, data: Data)] = []

        for tile in await tiles(sources: sources, pulses: pulses) {
            images.append((tile.name, tile.data))
        }

        if let cropped = await croppedOverview(sources: sources, pulses: pulses),
           let data = cropped.pngData() {
            images.append(("whole-pass.png", data))
        } else if let fallbackPNG {
            // The uncropped overview is still worth sending. A picture that is
            // mostly black beats no picture at all.
            images.append(("whole-pass.png", fallbackPNG))
        }

        if let pulse = sources.pulse,
           let image = await closeUp(pulse: pulse, sources: sources) ?? sources.pulseImage,
           let plot = pulsePlot(pulse: pulse, image: image, band: closeUpBand(for: pulse)),
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
    private static func croppedOverview(sources: INatImageSources,
                                        pulses: [PulseRecord]) async -> UIImage? {
        guard let raw = sources.overviewRaw, sources.sampleRate > 0 else { return nil }
        let band = callBand(pulses: pulses, nyquist: sources.sampleRate / 2)
        let sampleRate = sources.sampleRate
        let palette = sources.palette
        let floor = sources.noiseFloor
        let total = sources.overviewTotalSamples
        let threshold = sources.silenceThresholdDB
        let padding = sources.silencePadding
        return await Task.detached(priority: .userInitiated) {
            let map = SilenceMap.compute(grid: raw.grid, nCols: raw.nCols,
                                         binCount: STFTGrid.binCount,
                                         totalSamples: total, sampleRate: sampleRate,
                                         thresholdAboveFloorDB: threshold,
                                         minFreqHz: minAnalysisFrequencyHz,
                                         padSeconds: padding)
            // A recording that is nearly all signal has nothing to gain and
            // something to lose — packing it would make the axis non-linear for
            // no benefit — so it is drawn as it is.
            let packed = map.keptFraction < 0.9
                ? WavSpectrogramEngine.compressedOverviewRawTile(from: raw, map: map)
                : raw
            return WavSpectrogramEngine.colorize(packed, sampleRate: sampleRate,
                                                 minFreqHz: band.lowerBound,
                                                 maxFreqHz: band.upperBound,
                                                 palette: palette, noiseFloor: floor)?.image
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

    /// The recording walked through in order, each tile a 16:9 frame.
    ///
    /// Skipped entirely for a recording short enough that the context view
    /// already shows it at full resolution — a single tile that duplicates the
    /// picture above it is just noise on the page.
    private static func tiles(sources: INatImageSources,
                              pulses: [PulseRecord]) async -> [Photo] {
        guard sources.sampleRate > 0, let raw = sources.overviewRaw else { return [] }
        let totalSeconds = Double(raw.endSample - raw.startSample) / sources.sampleRate
        guard totalSeconds > tileSeconds * 1.5 else { return [] }

        let band = callBand(pulses: pulses, nyquist: sources.sampleRate / 2)
        let count = min(maxTiles, Int((totalSeconds / tileSeconds).rounded(.up)))

        var photos: [Photo] = []
        for index in 0..<count {
            let from = Double(index) * tileSeconds
            let to = min(totalSeconds, from + tileSeconds)
            guard to > from else { break }
            guard let image = await tile(from: from, to: to, band: band, sources: sources),
                  let plot = tilePlot(image: image, band: band, from: from, to: to,
                                      index: index, of: count),
                  let data = plot.pngData()
            else { continue }
            photos.append(Photo(name: String(format: "part-%02d.png", index + 1), data: data))
        }
        return photos
    }

    /// One slice, rendered from the file at the user's own noise floor and
    /// stretched to 16:9.
    ///
    /// Rendered wide (1600 columns for two seconds) and then let the frame do
    /// the aspect: the tile's natural height is however many frequency bins the
    /// band covers, which is nothing like 9/16 of its width, so the picture is
    /// scaled into the frame rather than cropped to it. Stretching a
    /// spectrogram is normal — both axes are already arbitrary scales — and
    /// cropping would throw away the frequencies this is meant to show.
    private static func tile(from: Double, to: Double,
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
                                                  targetColumns: 1600,
                                                  palette: palette, noiseFloor: floor,
                                                  calibrationCurve: curve)?.image
        }.value
    }

    /// A tile with its axes and its place in the sequence.
    ///
    /// The position line matters more than it looks: without it a reader has no
    /// way to tell tile 4 from tile 5, and the seconds are absolute within the
    /// recording so a claim about one call can be pointed at.
    private static func tilePlot(image: UIImage, band: ClosedRange<Double>,
                                 from: Double, to: Double,
                                 index: Int, of count: Int) -> UIImage? {
        let view = VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                VStack(alignment: .trailing) {
                    axisText(String(format: "%.0f", band.upperBound / 1000))
                    Spacer()
                    axisText(String(format: "%.0f", (band.lowerBound + band.upperBound) / 2000))
                    Spacer()
                    axisText(String(format: "%.0f", band.lowerBound / 1000))
                }
                .frame(width: 34, height: 360 * 9 / 16, alignment: .trailing)
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(16.0 / 9.0, contentMode: .fill)
                    .frame(height: 360 * 9 / 16)
                    .clipped()
            }
            HStack {
                axisText("kHz")
                    .frame(width: 34, alignment: .trailing)
                axisText(String(format: "%.1f s", from))
                Spacer()
                axisText("part \(index + 1) of \(count)")
                Spacer()
                axisText(String(format: "%.1f s", to))
            }
        }
        .padding(12)
        .frame(width: 640)
        .background(Color.black)
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private static func axisText(_ string: String) -> some View {
        Text(string)
            .font(.system(size: 9, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
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
                                                         targetColumns: 600,
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
    static let closeUpPaddingHz: Double = 8_000
    static let closeUpTimeFactor: Double = 3

    private static func closeUpBand(for pulse: PulseRecord) -> ClosedRange<Double> {
        if let low = pulse.imageFreqMinHz, let high = pulse.imageFreqMaxHz, high > low {
            return max(0, low - closeUpPaddingHz)...(high + closeUpPaddingHz)
        }
        return max(0, pulse.peakFreqHz - 20_000)...(pulse.peakFreqHz + 20_000)
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

    /// One call, tightly clipped, with axes — `PulseImagePlot` rendered to a
    /// picture, plus a caption saying what is being measured.
    ///
    /// Rendered at 3× so the axis numbers survive iNaturalist's own
    /// downscaling; at 1× they turn to mush at the size the page shows.
    private static func pulsePlot(pulse: PulseRecord, image: UIImage,
                                  band: ClosedRange<Double>) -> UIImage? {
        let view = VStack(alignment: .leading, spacing: 6) {
            // The axes describe the picture, so they come from the band that
            // was actually rendered, not from the stored thumbnail's bounds —
            // those two are the same only when the re-render succeeded.
            PulseImagePlot(image: image,
                           freqMinHz: band.lowerBound,
                           freqMaxHz: band.upperBound,
                           spanMs: closeUpSpan(for: pulse) * 1000)
            Text(caption(for: pulse))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 460)
        .background(Color.black)
        // `PulseImagePlot` colours its labels with `.secondary` and backs the
        // image with `systemBackground`; rendered outside a window there is no
        // trait collection to resolve those against, and they come out for a
        // light appearance on top of the black. Forcing the scheme is what
        // makes the axis numbers legible.
        .environment(\.colorScheme, .dark)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }

    private static func caption(for pulse: PulseRecord) -> String {
        let name = SpeciesInfo.commonName[pulse.species] ?? pulse.species
        return String(format: "%@ · peak %.0f kHz · %.1f ms · OpenBat",
                      name, pulse.peakFreqHz / 1000, pulse.durationMs)
    }
}
