//
//  WavAxisOverlay.swift
//  OpenBat
//
//  Time (bottom edge) and frequency (left edge) axis ticks/labels over the WAV
//  player's spectrogram. The live Detector screen's scrolling SpectrogramView
//  has never needed these — it only ever shows "now" — but a static,
//  zoomable, whole-file view has no other way to tell what window of time or
//  frequency is currently on screen. Five evenly-spaced ticks per axis
//  (0/25/50/75/100% of the CURRENT viewport) rather than "nice round number"
//  tick placement — simpler, and correct at any zoom level/span without a
//  separate algorithm for choosing round step sizes.
//

import SwiftUI

struct WavAxisOverlay: View {
    let viewport: WavViewport
    let sampleRate: Double
    let geoSize: CGSize
    var logFrequency: Bool = false

    private static let tickFracs: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
    private static let timeLabelHalfWidth: CGFloat = 22
    private static let freqLabelHalfHeight: CGFloat = 8
    /// Vertical space the time axis (tick mark + label) occupies at the
    /// bottom edge. The lowest frequency tick is clamped to sit just ABOVE
    /// this — i.e. level with the TOP of the time ticks — rather than down
    /// among the time labels where the two used to collide.
    private static let timeAxisReservedHeight: CGFloat = 22
    /// Left edge the leftmost time label is held to, so it starts just RIGHT
    /// of the frequency tick column (drawn at x≈26) instead of colliding
    /// with the bottom frequency label in the corner. Only affects the 0%
    /// tick — every other time tick sits far enough right already.
    private static let timeAxisLeftInset: CGFloat = 36

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.tickFracs.enumerated()), id: \.offset) { _, frac in
                timeTick(frac: frac)
            }
            ForEach(Array(Self.tickFracs.enumerated()), id: \.offset) { _, frac in
                freqTick(frac: frac)
            }
        }
        .allowsHitTesting(false)
    }

    private func timeTick(frac: Double) -> some View {
        let sample = viewport.startSample + Int((frac * Double(viewport.sampleSpan)).rounded())
        let seconds = Double(sample) / max(sampleRate, 1)
        // Clamp the LABEL's x so it can't spill past the frame at the 0%/100%
        // ticks — the tick mark itself moves with it, a minor cosmetic
        // trade-off only at the very edges. The left clamp starts past the
        // frequency tick column (`timeAxisLeftInset`) so the corner labels
        // don't overlap.
        let x = min(max(CGFloat(frac) * geoSize.width, Self.timeAxisLeftInset + Self.timeLabelHalfWidth),
                    geoSize.width - Self.timeLabelHalfWidth)
        return VStack(spacing: 2) {
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1, height: 5)
            Text(Self.formatTime(seconds))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
        }
        .position(x: x, y: geoSize.height - 10)
    }

    private func freqTick(frac: Double) -> some View {
        // frac 0 = top of screen = HIGH frequency, matching every other
        // top=high-frequency convention in this codebase (PulseZoomView,
        // WavSpectrogramView's vertical pan). Log mode uses the same v-fraction->Hz mapping
        // LogFrequencyWarp.warp itself remaps rows by, so labels line up with
        // the (possibly warped) rendered image.
        let hz = LogFrequencyWarp.vFracToHz(frac, lo: viewport.minFreqHz, hi: viewport.maxFreqHz, log: logFrequency)
        // Bottom clamp leaves room for the time axis so the lowest frequency
        // tick lands level with the top of the time ticks, not among their
        // labels — see `timeAxisReservedHeight`.
        let y = min(max(CGFloat(frac) * geoSize.height, Self.freqLabelHalfHeight),
                    geoSize.height - Self.timeAxisReservedHeight)
        return HStack(spacing: 2) {
            Text(Self.formatFreq(hz))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
            Rectangle().fill(Color.white.opacity(0.6)).frame(width: 5, height: 1)
        }
        .position(x: 26, y: y)
    }

    private static func formatTime(_ seconds: Double) -> String {
        let s = max(0, seconds)
        if s < 1 { return String(format: "%.0fms", s * 1000) }
        if s < 60 { return String(format: "%.2fs", s) }
        let m = Int(s) / 60
        let rem = s - Double(m * 60)
        return String(format: "%d:%04.1f", m, rem)
    }

    private static func formatFreq(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1fk", hz / 1000) : String(format: "%.0f", hz)
    }
}
