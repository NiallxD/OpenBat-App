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

enum Palette: Int, CaseIterable, Identifiable {
    case inferno
    case viridis
    case magma
    case greyscale
    case jet
    case plasma
    case neon

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .inferno:   "Inferno"
        case .viridis:   "Viridis"
        case .magma:     "Magma"
        case .greyscale: "Greyscale"
        case .jet:       "Jet"
        case .plasma:    "Plasma"
        case .neon:      "Neon"
        }
    }
}

/// CPU-side colormap sampling, used by `PulseImageRenderer` for the pulse-view
/// image and Sessions thumbnails. Mirrors the GPU stop tables in Spectrogram.metal.
enum DisplayColormap {
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
        .magma: [
            (0.00, (0.001, 0.000, 0.016)),
            (0.25, (0.316, 0.071, 0.485)),
            (0.50, (0.716, 0.215, 0.475)),
            (0.75, (0.988, 0.538, 0.380)),
            (1.00, (0.988, 0.992, 0.749)),
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
        // Matplotlib plasma — vivid purple → magenta → orange → yellow.
        .plasma: [
            (0.00, (0.050, 0.030, 0.528)),
            (0.25, (0.494, 0.012, 0.658)),
            (0.50, (0.798, 0.280, 0.469)),
            (0.75, (0.973, 0.585, 0.253)),
            (1.00, (0.940, 0.975, 0.131)),
        ],
        // Synthwave-style neon — black → magenta → cyan → white.
        .neon: [
            (0.00, (0.000, 0.000, 0.050)),
            (0.30, (0.850, 0.000, 0.850)),
            (0.60, (0.000, 0.850, 0.950)),
            (1.00, (1.000, 1.000, 1.000)),
        ],
    ]

    static func rgb(_ t: Float, palette: Palette) -> (UInt8, UInt8, UInt8) {
        let t = min(max(t, 0), 1)
        let c = sample(t, palette: palette)
        // Fade the bottom of every palette to black so silence renders dark even
        // for palettes whose t=0 stop is a saturated colour (viridis, jet,
        // plasma). Mirrors the identical fade in Spectrogram.metal's colormap().
        let fade = min(t / 0.12, 1)
        return (UInt8(c.0 * fade * 255), UInt8(c.1 * fade * 255), UInt8(c.2 * fade * 255))
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
