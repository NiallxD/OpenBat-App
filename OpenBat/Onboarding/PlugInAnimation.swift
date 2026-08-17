//
//  PlugInAnimation.swift
//  OpenBat
//
//  The "plug the microphone into your phone" illustration, drawn as a line
//  animation: the cable snakes out of the detector, across to the phone, and
//  the connector seats itself into the port.
//
//  Split in two on purpose. The static half — phone, detector body, bat glyph
//  — is `plugDiagram` in the asset catalogue, a template SVG (the source art
//  is a single near-black stroke colour, so template rendering lets it take
//  the surrounding foreground style and stay legible in dark mode). Three
//  strokes are *not* in that asset — the detector-end connector, the cable and
//  the phone-end connector — because they're redrawn here and animated. That
//  is why the whole view is locked to a square aspect ratio: it's what keeps
//  the overlay registered against the artwork.
//
//  If the source SVG is ever re-exported, all three paths have to be stripped
//  from it again and its viewBox re-cropped, or they'll show through
//  underneath the animated copies — see `Assets.xcassets/plugDiagram.imageset`
//  and the `designOrigin`/`designSide` note below.
//

import SwiftUI

struct PlugInAnimation: View {
    var tint: Color = .primary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Geometry, in the source SVG's coordinate space

    /// The asset's viewBox: the original 2000×2000 art cropped to its content
    /// bounds and squared up. The uncropped square carried ~19% dead margin on
    /// the right and bottom, which showed up as a gap between the illustration
    /// and whatever sat beside it. Coordinates below are still the original
    /// design values, so they're translated by this origin before drawing —
    /// **these two constants must match the SVG's viewBox exactly.**
    private static let designOrigin = CGPoint(x: 102.31, y: 154.35)
    private static let designSide: Double = 1518.68

    // All three strokes are *drawn* rather than slid into place, so each one's
    // point order is its drawing direction — first point is where the stroke
    // starts, and `trimmedPath` grows it from there.

    /// The detector-end connector, drawn left → right into the cable.
    private static let micPlugFrom = CGPoint(x: 659.829, y: 611.91)
    private static let micPlugTo = CGPoint(x: 708.895, y: 611.91)
    /// The cable, from where it leaves the detector to the phone's port.
    private static let cablePoints: [CGPoint] = [
        CGPoint(x: 733.626, y: 611.91),
        CGPoint(x: 803.321, y: 611.91),
        CGPoint(x: 803.321, y: 1608.38),
        CGPoint(x: 1299.04, y: 1608.38),
        CGPoint(x: 1299.04, y: 1471.76),
    ]
    /// The phone-end connector, drawn bottom → top into the port. In the source
    /// SVG this is a horizontal segment carried onto the port by a 90° rotation
    /// matrix; these are the resulting points, pre-multiplied so no transform is
    /// needed here. Larger y is lower on screen, so `from` is the bigger value.
    private static let phonePlugFrom = CGPoint(x: 1299.04, y: 1484.768)
    private static let phonePlugTo = CGPoint(x: 1299.04, y: 1426.731)

    private static let cableWidth: Double = 45.83
    private static let plugWidth: Double = 83.33

    // MARK: Timeline, in seconds through one cycle

    // Beats overlap slightly so the sequence reads as one continuous action:
    // the connector seats, the cable pays out behind it, the far end plugs in.
    private static let micPlugEndTime: Double = 0.45
    private static let drawStart: Double = 0.40
    private static let drawEnd: Double = 1.60
    private static let plugStartTime: Double = 1.55
    private static let plugEndTime: Double = 1.95
    private static let fadeStart: Double = 3.9
    private static let fadeEnd: Double = 4.4
    private static let cycle: Double = 4.8

    var body: some View {
        ZStack {
            Image("plugDiagram")
                .resizable()
                .scaledToFit()
                .foregroundStyle(tint)

            if reduceMotion {
                // The finished state: cable fully drawn, connector seated. The
                // illustration still says everything it needs to say standing
                // still.
                Canvas { context, size in
                    draw(context, size: size, micSeated: 1, drawn: 1, plugSeated: 1, opacity: 1)
                }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: Self.cycle)
                    Canvas { ctx, size in
                        draw(ctx, size: size,
                             micSeated: easeOut(progress(t, 0, Self.micPlugEndTime)),
                             drawn: easeOut(progress(t, Self.drawStart, Self.drawEnd)),
                             plugSeated: easeOut(progress(t, Self.plugStartTime, Self.plugEndTime)),
                             opacity: 1 - progress(t, Self.fadeStart, Self.fadeEnd))
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("An ultrasonic microphone connected to a phone by a cable.")
    }

    // MARK: Drawing

    private func draw(_ context: GraphicsContext, size: CGSize,
                      micSeated: Double, drawn: Double, plugSeated: Double, opacity: Double) {
        // The asset's viewBox is square and fills the square frame, so design
        // units map to points by a single scalar once the crop origin is
        // subtracted.
        let scale = size.width / Self.designSide
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: (p.x - Self.designOrigin.x) * scale,
                    y: (p.y - Self.designOrigin.y) * scale)
        }
        /// A two-point stroke grown from its first point to its second.
        func segment(_ from: CGPoint, _ to: CGPoint, _ amount: Double) -> Path {
            var path = Path()
            path.move(to: point(from))
            path.addLine(to: point(to))
            return path.trimmedPath(from: 0, to: amount)
        }

        var context = context
        context.opacity = opacity

        let plugStyle = StrokeStyle(lineWidth: Self.plugWidth * scale, lineCap: .round)

        // Detector end, drawn left → right.
        if micSeated > 0 {
            context.stroke(segment(Self.micPlugFrom, Self.micPlugTo, micSeated),
                           with: .color(tint), style: plugStyle)
        }

        var cable = Path()
        for (index, p) in Self.cablePoints.enumerated() {
            let scaled = point(p)
            if index == 0 { cable.move(to: scaled) } else { cable.addLine(to: scaled) }
        }
        context.stroke(
            cable.trimmedPath(from: 0, to: drawn),
            with: .color(tint),
            style: StrokeStyle(lineWidth: Self.cableWidth * scale, lineCap: .round, lineJoin: .round))

        // Phone end, drawn bottom → top into the port.
        if plugSeated > 0 {
            context.stroke(segment(Self.phonePlugFrom, Self.phonePlugTo, plugSeated),
                           with: .color(tint), style: plugStyle)
        }
    }

    // MARK: Timing helpers

    /// `time`'s position within the window `start...end`, clamped to 0…1.
    private func progress(_ time: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }

    private func easeOut(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}
