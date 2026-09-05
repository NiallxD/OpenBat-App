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
//    • A CONTEXT view — the whole recording, cropped to the call band with
//      20 kHz of headroom either side, so the shape of the pass and the number
//      of calls are visible and the calls fill the frame.
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

import SwiftUI

/// Everything needed to build the pictures, gathered by the player where these
/// values live and rendered later by the sheet. Cheap to construct — no
/// rendering happens until `INatImages.render`.
struct INatImageSources {
    let overviewRaw: WavSpectrogramEngine.RawTile?
    let sampleRate: Double
    let palette: Palette
    let noiseFloor: Float
    /// The call to draw in detail, with its stored thumbnail, if there is one.
    let pulse: PulseRecord?
    let pulseImage: UIImage?
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

    /// The images to attach, in the order iNaturalist should show them: context
    /// first, because it is what a page thumbnail will be cropped from.
    static func render(sources: INatImageSources,
                       pulses: [PulseRecord],
                       fallbackPNG: Data?) async -> [Photo] {
        var photos: [Photo] = []

        if let cropped = await croppedOverview(sources: sources, pulses: pulses),
           let data = cropped.pngData() {
            photos.append(Photo(name: "spectrogram.png", data: data))
        } else if let fallbackPNG {
            // The uncropped overview is still worth sending. A picture that is
            // mostly black beats no picture at all.
            photos.append(Photo(name: "spectrogram.png", data: fallbackPNG))
        }

        if let pulse = sources.pulse, let image = sources.pulseImage,
           let plot = pulsePlot(pulse: pulse, image: image),
           let data = plot.pngData() {
            photos.append(Photo(name: "call-detail.png", data: data))
        }

        return photos
    }

    // MARK: The context view

    /// The whole recording, cropped to the band the calls occupy.
    ///
    /// Runs the colorize pass off the main actor: it is bounded array maths
    /// over a grid that is already in memory, but it is a full pass over that
    /// grid and this is happening while a sheet is animating in.
    private static func croppedOverview(sources: INatImageSources,
                                        pulses: [PulseRecord]) async -> UIImage? {
        guard let raw = sources.overviewRaw, sources.sampleRate > 0 else { return nil }
        let band = callBand(pulses: pulses, nyquist: sources.sampleRate / 2)
        let sampleRate = sources.sampleRate
        let palette = sources.palette
        let floor = sources.noiseFloor
        return await Task.detached(priority: .userInitiated) {
            WavSpectrogramEngine.colorize(raw, sampleRate: sampleRate,
                                          minFreqHz: band.lowerBound,
                                          maxFreqHz: band.upperBound,
                                          palette: palette, noiseFloor: floor)?.image
        }.value
    }

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

    // MARK: The detail view

    /// One call, tightly clipped, with axes — `PulseImagePlot` rendered to a
    /// picture, plus a caption saying what is being measured.
    ///
    /// Rendered at 3× so the axis numbers survive iNaturalist's own
    /// downscaling; at 1× they turn to mush at the size the page shows.
    private static func pulsePlot(pulse: PulseRecord, image: UIImage) -> UIImage? {
        let view = VStack(alignment: .leading, spacing: 6) {
            PulseImagePlot(image: image,
                           freqMinHz: pulse.imageFreqMinHz,
                           freqMaxHz: pulse.imageFreqMaxHz,
                           spanMs: pulse.imageSpanMs)
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
