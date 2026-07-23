//
//  TickerWheelControl.swift
//  OpenBat
//
//  A horizontal "ruler" picker — a pill-shaped strip of tick marks that
//  scrolls under a fixed center pointer as you drag, snapping to `step`.
//  Replaces the player's plain `Slider`s (time-zoom) and the two-thumb
//  `VerticalRangeSlider` (frequency range) with a single reusable control
//  shared by both, per the "two pills at the bottom" request.
//
//  Drag direction is "content follows finger": dragging right slides the
//  strip right (as if pulling a physical tape measure toward you), which
//  DECREASES the read value — the tick at any given screen position moves
//  right as `value` drops, same relationship a real ruler has.
//
//  Live-drags its OWN internal state instantly (cheap: just redrawing tick
//  positions), but only writes to `value` at drag end AND on every settled
//  intermediate step — see `onChanged`. Callers that feed `value` into
//  something expensive (a detail-tile re-render) are expected to debounce
//  THAT side themselves, same "live UI, debounced work" split already used
//  throughout WavPlayerView/WavSpectrogramView — this control has no opinion
//  on what's expensive downstream.
//

import SwiftUI

struct TickerWheelControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    /// Screen points of drag travel per `step` — larger feels "heavier"
    /// (more precise, more finger travel needed per increment).
    var pointsPerStep: CGFloat = 14

    @State private var liveValue: Double?
    @State private var dragStartValue: Double = 0

    private var displayValue: Double { liveValue ?? value }

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            ZStack {
                Capsule()
                    .fill(.thinMaterial)
                TickerStrip(value: displayValue, range: range, step: step, pointsPerStep: pointsPerStep)
                    .clipShape(Capsule())
                Capsule()
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 6)
                    .allowsHitTesting(false)
            }
            .frame(width: 150, height: 40)
            .contentShape(Rectangle())
            .gesture(drag)
            Text(format(displayValue))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                if liveValue == nil { dragStartValue = value }
                // See file doc comment for the sign convention.
                let deltaSteps = Self.acceleratedSteps(forTranslation: -drag.translation.width, pointsPerStep: pointsPerStep)
                let raw = dragStartValue + deltaSteps * step
                let clamped = min(max(raw, range.lowerBound), range.upperBound)
                liveValue = clamped
                // Commit on every settled step during the drag too (not just
                // at release) — matches how the old Slider felt: a value the
                // caller can watch change continuously, not just once at the
                // end of a gesture.
                value = (clamped / step).rounded() * step
            }
            .onEnded { _ in
                if let liveValue {
                    value = min(max((liveValue / step).rounded() * step, range.lowerBound), range.upperBound)
                }
                liveValue = nil
            }
    }

    /// Translation-to-steps mapping with mild quadratic acceleration: the
    /// per-point rate right at the start of a drag matches `pointsPerStep`
    /// exactly (fine control for a small nudge is unchanged), but each
    /// additional point of travel counts for progressively more. A pure
    /// linear mapping (the original `translation / pointsPerStep`) made
    /// reaching the far end of a wide, fine-grained range — the Range
    /// wheel's 500Hz steps across 0.5–192kHz — take several dozen
    /// screen-widths of dragging to reach a commonly-used value like 20kHz.
    /// The 0.24 coefficient was picked so a single ~3–4-width swipe (roughly
    /// 400–500pts, one comfortable continuous thumb drag) comfortably
    /// crosses that wheel's full span, while a short drag still moves in
    /// fine single/double steps.
    private static func acceleratedSteps(forTranslation t: CGFloat, pointsPerStep: CGFloat) -> Double {
        guard pointsPerStep > 0 else { return 0 }
        let accelerationFactor = 0.24
        let sign: Double = t < 0 ? -1 : 1
        let mag = Double(abs(t)) / Double(pointsPerStep)
        return sign * (mag + accelerationFactor * mag * mag)
    }
}

/// Draws the scrolling tick marks — a `Canvas` rather than N individual
/// views, since a wide range at a fine step (the frequency range control:
/// ~380 steps from 0.5 to 192kHz) would otherwise mean hundreds of view
/// instances for ticks mostly outside the visible strip.
private struct TickerStrip: View {
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let pointsPerStep: CGFloat

    var body: some View {
        Canvas { context, size in
            guard step > 0 else { return }
            let midX = size.width / 2
            let visibleSteps = Int((size.width / pointsPerStep).rounded(.up)) + 2
            let centerStepIndex = (value / step).rounded()
            for offset in -visibleSteps...visibleSteps {
                let stepIndex = centerStepIndex + Double(offset)
                let tickValue = stepIndex * step
                guard tickValue >= range.lowerBound - step, tickValue <= range.upperBound + step else { continue }
                let dx = CGFloat((tickValue - value) / step) * pointsPerStep
                let x = midX + dx
                guard x > -2, x < size.width + 2 else { continue }
                // Every 5th tick is major (taller, more opaque) — purely a
                // visual rhythm aid, not tied to any semantic grouping.
                let isMajor = Int(stepIndex.rounded()) % 5 == 0
                let h = size.height * (isMajor ? 0.6 : 0.35)
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height / 2 - h / 2))
                path.addLine(to: CGPoint(x: x, y: size.height / 2 + h / 2))
                context.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.8 : 0.4)), lineWidth: 1)
            }
        }
    }
}
