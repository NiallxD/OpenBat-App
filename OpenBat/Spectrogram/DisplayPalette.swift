//
//  DisplayPalette.swift
//  OpenBat
//
//  User-selectable display colormap for the live spectrogram and the captured
//  pulse view. Distinct from `NaBatSpectrogramRenderer`'s magma colormap, which
//  is fixed — it must match what the NABat model was trained on and is never
//  user-configurable. This is purely a display choice.
//
//  Stop tables are duplicated between here (CPU — pulse view / thumbnails) and
//  `Spectrogram.metal` (GPU — live view) because MSL can't import Swift. Keep
//  the two in sync when editing either.
//

import Foundation

/// User-selectable display colormaps. `rawValue` is read directly by
/// `Spectrogram.metal`'s `paletteIndex` uniform, so ordering/values here and
/// the shader's `if (p == …)` chain must stay in step.
///
/// Values are pinned explicitly (rather than left to auto-increment) because
/// `rawValue` is also what gets persisted (`pulse.displayPalette`, and the
/// `@AppStorage` in `WavPlayerView`) — magma (2) and plasma (5) were removed
/// by retiring their numbers rather than renumbering the rest, so an install
/// that had e.g. jet (4) saved doesn't wake up on neon after the update.
enum Palette: Int, CaseIterable, Identifiable {
    case inferno = 0
    case viridis = 1
    case greyscale = 3
    case jet = 4
    case neon = 6

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .inferno:   "Inferno"
        case .viridis:   "Viridis"
        case .greyscale: "Greyscale"
        case .jet:       "Jet"
        case .neon:      "Neon"
        }
    }
}

/// CPU-side colormap sampling, used by `PulseImageRenderer` for the pulse-view
/// image and Sessions thumbnails. Mirrors the GPU stop tables in Spectrogram.metal.
/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`GuanoMetadata` — pure
/// math with no isolation annotation, called from `PulseImageRenderer`'s capture
/// pipeline and `RecordingSpectrogramRenderer`'s off-main render path.
nonisolated enum DisplayColormap {
    /// Whether every colormap is drawn upside down — silence white, calls dark
    /// — because the phone is in light mode (Niall, 2026-09-02).
    ///
    /// **A global, deliberately.** The colouring happens in half a dozen places
    /// that have no view context to read a colour scheme from: the live Metal
    /// shader, the pulse-view renderer, session thumbnails, the player's tile
    /// store and its overview. Threading an environment value through all of
    /// them would put the same flag in six initialisers and guarantee that one
    /// of them eventually disagrees with the others — and two spectrograms in
    /// opposite polarities on one screen is worse than any of the alternatives.
    /// `RootView` sets it, once, from the scheme.
    ///
    /// Written from the main actor and read from render threads. It is a `Bool`
    /// that flips at most when the user changes appearance, and a torn read is
    /// not a thing a single-word load can produce — the worst case is one frame
    /// coloured with the old value.
    nonisolated(unsafe) static var inverted = false

    private typealias RGB = (Float, Float, Float)
    private typealias Stop = (Float, RGB)

    private static let stops: [Palette: [Stop]] = [
        .inferno: [
            (0.0, (0.001, 0.000, 0.014)),
            (0.2, (0.215, 0.036, 0.405)),
            (0.4, (0.575, 0.149, 0.404)),
            (0.6, (0.868, 0.288, 0.245)),
            (0.8, (0.988, 0.645, 0.040)),
            (1.0, (0.988, 0.998, 0.645)),
        ],
        .viridis: [
            (0.00, (0.267, 0.005, 0.329)),
            (0.25, (0.231, 0.322, 0.545)),
            (0.50, (0.128, 0.565, 0.551)),
            (0.75, (0.369, 0.788, 0.384)),
            (1.00, (0.993, 0.906, 0.144)),
        ],
        .greyscale: [
            (0.0, (0, 0, 0)),
            (1.0, (1, 1, 1)),
        ],
        // Classic "thermal camera" rainbow — nostalgic, high-contrast, genuinely funky.
        .jet: [
            (0.000, (0.000, 0.000, 0.500)),
            (0.125, (0.000, 0.000, 1.000)),
            (0.375, (0.000, 1.000, 1.000)),
            (0.625, (1.000, 1.000, 0.000)),
            (0.875, (1.000, 0.000, 0.000)),
            (1.000, (0.500, 0.000, 0.000)),
        ],
        // Synthwave-style neon — black → magenta → cyan → white.
        .neon: [
            (0.00, (0.000, 0.000, 0.050)),
            (0.30, (0.850, 0.000, 0.850)),
            (0.60, (0.000, 0.850, 0.950)),
            (1.00, (1.000, 1.000, 1.000)),
        ],
    ]

    /// `inverted` defaults to the global, so every existing call site follows
    /// the appearance without being touched; pass it explicitly only to render
    /// a picture whose polarity must not depend on the phone.
    static func rgb(_ t: Float, palette: Palette,
                    inverted: Bool = DisplayColormap.inverted) -> (UInt8, UInt8, UInt8) {
        let t = min(max(t, 0), 1)
        let c = sample(t, palette: palette)
        // Fade the bottom of every palette to black so silence renders dark even
        // for palettes whose t=0 stop is a saturated colour (viridis, jet).
        // Mirrors the identical fade in Spectrogram.metal's colormap().
        let fade = min(t / 0.12, 1)
        var rgb = (c.0 * fade, c.1 * fade, c.2 * fade)
        // A straight photographic negative, taken AFTER the fade — which is why
        // it lands on white rather than on some palette's own t=0 colour. Every
        // map then reads the same way up: silence is the page, energy is ink.
        // Mirrors the identical inversion in Spectrogram.metal's colormap().
        if inverted { rgb = (1 - rgb.0, 1 - rgb.1, 1 - rgb.2) }
        return (UInt8(rgb.0 * 255), UInt8(rgb.1 * 255), UInt8(rgb.2 * 255))
    }

    /// Precomputes `rgb(_:palette:)` at `steps` evenly-spaced points — for any
    /// caller about to call `rgb` in a bulk per-pixel loop (a colorize pass
    /// over a whole spectrogram image, easily several million pixels).
    /// Measured on-device: `rgb` itself is dominated by a dictionary lookup
    /// (`stops[palette]`) plus a linear stop-search, repeated per pixel — a
    /// 4096x1024 colorize pass (the WavPlayer overview) took 1.6–5.3 SECONDS
    /// doing that per-pixel, the actual cause behind the "shows the coarse
    /// overview for ages before the sharp tile pops in" complaint, not a
    /// resolution/design issue. Build this ONCE per colorize call (256
    /// iterations through the slow path, negligible) and index into it
    /// per-pixel (O(1), no dictionary, no search) instead.
    static func makeLUT(palette: Palette, steps: Int = 256,
                        inverted: Bool = DisplayColormap.inverted) -> [(UInt8, UInt8, UInt8)] {
        (0..<steps).map { i in rgb(Float(i) / Float(steps - 1), palette: palette,
                                   inverted: inverted) }
    }

    private static func sample(_ t: Float, palette: Palette) -> RGB {
        let table = stops[palette] ?? stops[.inferno]!
        for i in 0..<table.count - 1 {
            let (t0, c0) = table[i]
            let (t1, c1) = table[i + 1]
            guard t <= t1 else { continue }
            let f = t1 > t0 ? (t - t0) / (t1 - t0) : 0
            return (c0.0 * (1-f) + c1.0 * f,
                    c0.1 * (1-f) + c1.1 * f,
                    c0.2 * (1-f) + c1.2 * f)
        }
        return table.last!.1
    }
}
