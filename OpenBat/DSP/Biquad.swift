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
/// real-time audio thread (HeterodyneProcessor, TimeExpansionProcessor). Every call from
/// there would be a synchronous nonisolated→main-actor hop, bridged by an implicit
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
}
