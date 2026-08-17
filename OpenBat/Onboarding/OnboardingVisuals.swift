//
//  OnboardingVisuals.swift
//  OpenBat
//
//  The animated headers onboarding uses in place of a static SF Symbol. Two
//  of them, both self-contained and both only alive while their step is on
//  screen:
//
//    • `SonarPulseHero`     — expanding rings behind a glyph (welcome, done).
//    • `EcholocationDiagram`— a miniature spectrogram that teaches, in one
//                             picture, the thing the whole app rests on: bat
//                             calls sweep downward, and they start well above
//                             where human hearing stops.
//
//  Both drive themselves from `TimelineView(.animation)` rather than a
//  `repeatForever` animation on state, so there is no animation left running
//  against a view that has been swapped out — the timeline stops with the
//  view. Both honour Reduce Motion by rendering a still frame instead: the
//  diagram is drawn from a phase value, so "still" is just phase 0, and it
//  stays fully legible without moving.
//

import SwiftUI

// MARK: - Sonar rings

/// Concentric rings expanding outward from a centred glyph, on a loop — the
/// visual shorthand for "this thing is listening". Used behind the app icon on
/// the welcome step and behind the tick on the final step.
struct SonarPulseHero<Center: View>: View {
    var ringCount: Int = 3
    /// Seconds for one ring to travel from the centre to fully faded.
    var period: Double = 2.6
    var tint: Color = .batAccent
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if reduceMotion {
                // One static ring rather than a frozen stack of three at
                // arbitrary phases, which would just look like a mistake.
                Circle()
                    .stroke(tint.opacity(0.35), lineWidth: 2)
                    .scaleEffect(1.1)
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    ZStack {
                        ForEach(0..<ringCount, id: \.self) { index in
                            // Rings are evenly staggered across the period, so
                            // one leaves the centre just as another fades out.
                            let phase = ((t / period) + Double(index) / Double(ringCount))
                                .truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(tint.opacity((1 - phase) * 0.5), lineWidth: 2)
                                .scaleEffect(0.5 + phase * 1.3)
                        }
                    }
                }
            }
            center()
        }
        .frame(width: 128, height: 128)
        .accessibilityHidden(true)
    }
}

// MARK: - Drawn-artwork hero

/// A step header built from asset-catalog artwork instead of an SF Symbol,
/// landing with the same one-shot bounce `OnboardingStepView` gives a symbol.
///
/// The bounce has to be hand-rolled: `.symbolEffect(.bounce)` only does anything
/// to an SF Symbol, and applied to a raster template image it fails silently —
/// the glyph simply sits there while every other step's header lands. Reduce
/// Motion skips straight to the resting state.
struct BounceInGlyph: View {
    let assetName: String
    var height: CGFloat = 60
    var tint: Color = .batAccent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var landed = false

    var body: some View {
        Image(assetName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(tint)
            .scaleEffect(landed ? 1 : 0.7)
            .opacity(landed ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { landed = true; return }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.52)) { landed = true }
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Echolocation diagram

/// A small looping spectrogram showing a run of downward-sweeping echolocation
/// calls against a shaded "you can hear this" band, on the same axes the live
/// detector screen uses (time across, frequency up). It is deliberately drawn
/// in the same idiom as the real spectrogram — bright trace on a dark panel —
/// so the first real pass a user sees looks like something they have already
/// been shown.
///
/// The numbers are illustrative rather than a specific species: a sweep from
/// ~105 kHz down to ~45 kHz is a fair cartoon of a typical FM call, and the
/// 20 kHz hearing line is the point the accompanying copy actually makes.
struct EcholocationDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Top of the frequency axis. 120 kHz keeps a typical FM sweep comfortably
    /// inside the panel while still reading as "far above the hearing line".
    private let maxKHz: Double = 120
    private let hearingKHz: Double = 20
    /// Horizontal gap between successive calls, in points.
    private let spacing: CGFloat = 74
    /// Seconds for the run of calls to advance by one `spacing`.
    private let period: Double = 1.5

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, size in draw(context, size: size, phase: 0) }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let phase = (t / period).truncatingRemainder(dividingBy: 1)
                    Canvas { ctx, size in draw(ctx, size: size, phase: phase) }
                }
            }
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel(
            "Diagram: bat calls sweep downward from about 105 to 45 kilohertz, "
            + "well above the 20 kilohertz limit of human hearing.")
    }

    /// `phase` is 0…1 through one `spacing` of leftward travel.
    private func draw(_ context: GraphicsContext, size: CGSize, phase: Double) {
        func y(_ kHz: Double) -> CGFloat {
            size.height * (1 - CGFloat(kHz / maxKHz))
        }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))

        // The audible band, shaded from the hearing line down to 0 kHz. Drawn
        // first so the calls stroke over it.
        let hearingY = y(hearingKHz)
        context.fill(
            Path(CGRect(x: 0, y: hearingY, width: size.width, height: size.height - hearingY)),
            with: .color(Color.white.opacity(0.07)))

        var line = Path()
        line.move(to: CGPoint(x: 0, y: hearingY))
        line.addLine(to: CGPoint(x: size.width, y: hearingY))
        context.stroke(line, with: .color(Color.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        // One extra call off each edge so calls enter and leave rather than
        // popping into existence at the boundary.
        let visible = Int(ceil(size.width / spacing))
        let offset = CGFloat(phase) * spacing
        for index in -1...(visible + 1) {
            let x = CGFloat(index) * spacing - offset
            let path = callSweep(startX: x, y: y)
            // Stroked twice: a wide soft pass for the bloom a real call has in
            // the spectrogram, then a narrow bright core on top.
            context.stroke(path, with: .color(Color.batAccent.opacity(0.28)),
                           style: StrokeStyle(lineWidth: 9, lineCap: .round))
            context.stroke(path, with: .color(Color.batAccent),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }

        context.draw(
            context.resolve(
                Text("20 kHz: the limit of human hearing.")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))),
            at: CGPoint(x: 8, y: hearingY + 6), anchor: .topLeading) // Shift these x and y values to move the lable on the animation.

        context.draw(
            context.resolve(
                Text("Example bat calls")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.batAccent)),
            at: CGPoint(x: 8, y: 8), anchor: .topLeading)
    }

    /// One call: a steep downward sweep, curving as it falls the way a real FM
    /// call does (fast through the top of its range, flattening at the bottom).
    private func callSweep(startX: CGFloat, y: (Double) -> CGFloat) -> Path {
        let topKHz = 90.0
        let bottomKHz = 40.0
        let width: CGFloat = 45
        var path = Path()
        let steps = 17
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            // Hyperbolic-ish fall: most of the drop happens early.
            let kHz = bottomKHz + (topKHz - bottomKHz) * pow(1 - u, 2)
            let point = CGPoint(x: startX + width * CGFloat(u), y: y(kHz))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Heterodyne shift diagram

/// Continues `EcholocationDiagram`'s picture onto the next screen: the same
/// frequency axis, the same call shape, now sliding down past the hearing line
/// into the audible band, then ringing out as sound you actually receive.
///
/// The geometry is the real operation rather than a hand-wave. Heterodyne
/// multiplies the input by a local oscillator and keeps the difference, so a
/// call is shifted down by a *constant* — its shape and bandwidth survive, only
/// its position on the axis changes. That is exactly what the moving glyph
/// does: a 60→44 kHz sweep against a 42 kHz oscillator arrives as 18→2 kHz,
/// the same sweep, now inside hearing range. Nothing is stretched in time.
struct HeterodyneShiftDiagram: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let maxKHz: Double = 120
    private let hearingKHz: Double = 20
    /// The local oscillator, and so the distance everything drops.
    private let loKHz: Double = 42
    private let callTopKHz: Double = 60
    private let callBottomKHz: Double = 44

    private let travelStart: Double = 0.15
    private let travelEnd: Double = 1.35
    private let ringEnd: Double = 2.30
    private let cycle: Double = 2.60

    var body: some View {
        Group {
            if reduceMotion {
                // Parked at the moment of arrival: both positions visible and
                // the shift already made, which is the whole point of the
                // picture.
                Canvas { context, size in draw(context, size: size, time: travelEnd) }
            } else {
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: cycle)
                    Canvas { ctx, size in draw(ctx, size: size, time: t) }
                }
            }
        }
        .frame(height: 168)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
        )
        .accessibilityElement()
        .accessibilityLabel(
            "Diagram: an ultrasonic bat call is shifted down below the 20 kilohertz "
            + "limit of human hearing, keeping its shape, so it can be heard.")
    }

    private func draw(_ context: GraphicsContext, size: CGSize, time: Double) {
        func y(_ kHz: Double) -> CGFloat { size.height * (1 - CGFloat(kHz / maxKHz)) }

        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.07)))

        let hearingY = y(hearingKHz)
        context.fill(
            Path(CGRect(x: 0, y: hearingY, width: size.width, height: size.height - hearingY)),
            with: .color(Color.white.opacity(0.07)))

        var line = Path()
        line.move(to: CGPoint(x: 0, y: hearingY))
        line.addLine(to: CGPoint(x: size.width, y: hearingY))
        context.stroke(line, with: .color(Color.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

        let startX = size.width * 0.30
        let sweepWidth = size.width * 0.30

        // Where the call starts, and where it lands — both drawn faintly the
        // whole time so the move reads as "from here to there".
        let origin = sweep(drop: 0, startX: startX, width: sweepWidth, y: y)
        let target = sweep(drop: loKHz, startX: startX, width: sweepWidth, y: y)
        let ghost = StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        context.stroke(origin, with: .color(Color.batAccent.opacity(0.3)), style: ghost)
        context.stroke(target, with: .color(Color.batAccent.opacity(0.2)), style: ghost)

        let travel = easeInOut(progress(time, travelStart, travelEnd))
        let moving = sweep(drop: loKHz * travel, startX: startX, width: sweepWidth, y: y)
        context.stroke(moving, with: .color(Color.batAccent.opacity(0.3)),
                       style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
        context.stroke(moving, with: .color(Color.batAccent),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

        // Arrival: rings out from the landing point, the sound reaching you.
        let ring = progress(time, travelEnd, ringEnd)
        if ring > 0 && ring < 1 {
            let centre = CGPoint(x: startX + sweepWidth, y: y(callBottomKHz - loKHz))
            for index in 0..<2 {
                let staggered = min(max(ring - Double(index) * 0.18, 0), 1)
                guard staggered > 0 else { continue }
                let radius = 8 + staggered * 42
                let box = CGRect(x: centre.x - radius, y: centre.y - radius,
                                 width: radius * 2, height: radius * 2)
                context.stroke(
                    Path(ellipseIn: box),
                    with: .color(Color.batAccent.opacity((1 - staggered) * 0.5)),
                    style: StrokeStyle(lineWidth: 2))
            }
        }

        context.draw(
            context.resolve(
                Text("Bat call: too high to hear")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.batAccent)),
            at: CGPoint(x: 8, y: 8), anchor: .topLeading)

        context.draw(
            context.resolve(
                Text("Shifted down into hearing range")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.75))),
            at: CGPoint(x: 8, y: hearingY + 6), anchor: .topLeading)
    }

    /// The call sweep, moved down the axis by `drop` kHz — a constant offset,
    /// so the shape is untouched.
    private func sweep(drop: Double, startX: CGFloat, width: CGFloat,
                       y: (Double) -> CGFloat) -> Path {
        var path = Path()
        let steps = 17
        for step in 0...steps {
            let u = Double(step) / Double(steps)
            let kHz = callBottomKHz + (callTopKHz - callBottomKHz) * pow(1 - u, 2) - drop
            let point = CGPoint(x: startX + width * CGFloat(u), y: y(kHz))
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }

    private func progress(_ time: Double, _ start: Double, _ end: Double) -> Double {
        guard end > start else { return time >= end ? 1 : 0 }
        return min(max((time - start) / (end - start), 0), 1)
    }

    private func easeInOut(_ x: Double) -> Double {
        x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2
    }
}
