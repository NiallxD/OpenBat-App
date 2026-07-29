//
//  Biquad.swift
//  OpenBat
//
//  A single biquad filter section (transposed Direct Form II), shared by the
//  listening processors.
//

import Foundation

/// Explicitly `nonisolated`: the project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// so without this annotation `Biquad`'s init/static factories/`process` would inherit
/// `@MainActor` — but this type is constructed and driven entirely from the `nonisolated`
/// real-time audio thread (HeterodyneProcessor). Every call
/// from there would be a synchronous nonisolated→main-actor hop, bridged by an implicit
/// `unsafeForcedSync` (the runtime warning this fixes) — pure DSP math with no shared
/// state has no business being actor-isolated at all.
nonisolated struct Biquad {
    var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    var z1: Float = 0, z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    /// RBJ-cookbook low-pass coefficients (Q = 0.707 → Butterworth per section).
    static func lowpass(cutoff: Double, sampleRate: Double, q: Double = 0.70710678) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float((1 - cosw) / 2 / a0)
        b.b1 = Float((1 - cosw) / a0)
        b.b2 = Float((1 - cosw) / 2 / a0)
        b.a1 = Float(-2 * cosw / a0)
        b.a2 = Float((1 - alpha) / a0)
        return b
    }

    /// RBJ-cookbook high-pass coefficients.
    static func highpass(cutoff: Double, sampleRate: Double, q: Double = 0.70710678) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float((1 + cosw) / 2 / a0)
        b.b1 = Float(-(1 + cosw) / a0)
        b.b2 = Float((1 + cosw) / 2 / a0)
        b.a1 = Float(-2 * cosw / a0)
        b.a2 = Float((1 - alpha) / a0)
        return b
    }

    /// RBJ-cookbook notch (band-stop) coefficients.
    ///
    /// Added for a specific, measured artifact: the capture path injects a
    /// narrowband tone at **inputSampleRate / 4** — 96.0 kHz at 384 kHz, sitting
    /// +11 dB above the local noise floor in every recording checked, so it's the
    /// ADC or the USB audio path rather than anything in the environment. It is
    /// inaudible where it sits, but any mode that divides frequency maps it
    /// straight into the audible band as a steady whine (12 kHz at ÷8, 6 kHz at
    /// ÷16). A high Q keeps the notch narrow enough that no real call energy is
    /// touched.
    static func notch(center: Double, sampleRate: Double, q: Double = 30) -> Biquad {
        let w0 = 2 * Double.pi * center / sampleRate
        let cosw = cos(w0), sinw = sin(w0)
        let alpha = sinw / (2 * q)
        let a0 = 1 + alpha
        var b = Biquad()
        b.b0 = Float(1 / a0)
        b.b1 = Float(-2 * cosw / a0)
        b.b2 = Float(1 / a0)
        b.a1 = Float(-2 * cosw / a0)
        b.a2 = Float((1 - alpha) / a0)
        return b
    }
}
