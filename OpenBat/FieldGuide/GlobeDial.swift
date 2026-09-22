//
//  GlobeDial.swift
//  OpenBat
//
//  The tuning dial over the globe: drag around its edge to change which pins the
//  map is showing. Species is position zero and always present; the rest come
//  from the blog feed's declared categories, so a new one appears without an app
//  release (see `BlogFeedSpec.md`).
//
//  **Small until asked for.** The map is what this screen is for, so at rest the
//  dial is a knob in the corner and nothing else. Tapping opens the full face over
//  the middle of the globe; the knob stays where it is and becomes the way out.
//
//  **A ring with a real hole in it.** The face was a filled disc, which put a
//  surface between the finger and the pins it was filtering — visible underneath
//  and impossible to tap. Only the rim is drawn and only the rim takes touches, so
//  the map inside the dial behaves exactly as the map outside it does.
//
//  The legend rides just above the ring rather than inside it — see `DialLegend`
//  for where it has been and why it ended up there.
//
//  **The ring is `liquidGlass`, nothing added to it.** It used to fill a whole
//  circle with glass and `.mask` that down to a ring — but `.mask` forces an
//  offscreen render pass, and doing that to a `glassEffect` view rasterises its
//  live sampling of the map behind it into a flat, noticeably more opaque blur.
//  The fix is the one every other glass surface in the app already uses: hand
//  the SHAPE you want straight to `liquidGlass(in:)` (`RingShape`, below)
//  instead of drawing a bigger shape and cutting it down afterwards.
//
//  The legend sits in its own row directly above the ring, not layered over it —
//  see `DialLegend`.
//
//  The metaphor is a heterodyne detector's frequency dial, and the part worth
//  imitating is not the look: it is that you can find a station by feel. Hence
//  detents and a tick at each one, rather than a free spin landing anywhere.
//

import SwiftUI

/// A glass annulus — the ring itself, as a real `Shape` rather than a circle
/// masked down afterward. Two subpaths wound in OPPOSITE directions (the
/// `clockwise:` flags below) is what gives the inner circle a hole under
/// SwiftUI's default nonzero fill rule; two circles wound the same way would
/// just overlap and fill solid.
///
/// Existing only so `liquidGlass(in:)` can be handed the ring directly — see
/// the file header for why that matters here and not just as tidiness.
private struct RingShape: Shape {
    let lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let outerRadius = min(rect.width, rect.height) / 2
        let innerRadius = max(0, outerRadius - lineWidth)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: center.x + outerRadius, y: center.y))
        path.addArc(center: center, radius: outerRadius,
                    startAngle: .zero, endAngle: .degrees(360), clockwise: false)
        path.move(to: CGPoint(x: center.x + innerRadius, y: center.y))
        path.addArc(center: center, radius: innerRadius,
                    startAngle: .zero, endAngle: .degrees(360), clockwise: true)
        return path
    }
}

struct GlobeDial: View {
    let categories: [DialCategory]
    @Binding var selection: Int
    /// What is actually on the map at this position, already worded — "12 regions",
    /// "1 story". The caller words it because only the caller knows what the
    /// position is showing: Species draws the guide's region shapes and their
    /// pins, and calling those "on the map" told the user nothing about what they
    /// were counting. A position with nothing in it says so, rather than leaving
    /// someone wondering whether the map is still loading.
    let countDescription: String

    @State private var expanded = false
    /// Tracked continuously and snapped on release, so the face follows the
    /// finger rather than jumping between detents underneath it.
    @State private var angle: Double = 0
    @State private var dragging = false
    @State private var lastTickedIndex: Int?
    /// The angle the face was at when this drag began.
    ///
    /// **Not an angle derived from `selection`, which is what made the dial
    /// oscillate.** The drag sets `selection` every time it
    /// crosses a detent — so the origin it was measuring from moved by a whole
    /// step mid-gesture, which threw the angle back across the detent it had just
    /// passed, which changed the selection again. Held still for the duration of
    /// the gesture, the rotation is simply where you started plus how far you have
    /// turned.
    @State private var dragBase: Double = 0
    /// The category this drag started on, so release can tell "moved a little
    /// but not far enough to tick over" from "never moved at all" — see
    /// `faceDrag`.
    @State private var dragStartIndex = 0

    private static let faceFraction: CGFloat = 0.74
    private static let maxFace: CGFloat = 380
    private static let knob: CGFloat = 46
    /// Width of the glass rim. Also the hit area for turning the dial, so it has
    /// to stay comfortably thicker than a fingertip is precise.
    private static let rimWidth: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let face = min(min(geo.size.width, geo.size.height) * Self.faceFraction,
                           Self.maxFace)
            ZStack {
                if expanded {
                    // **A stack, not an overlay-plus-offset.** The legend used to
                    // sit inside `dialFace` at a hand-tuned negative offset
                    // guessing how far "just above the ring" was, which drifted
                    // out of true whenever either view's size changed. Stacking
                    // them with an explicit gap makes "above" a fact about the
                    // layout rather than a number someone eyeballed.
                    VStack(spacing: 12) {
                        // No `.fixedSize()` needed here any more: the pill
                        // declares its own fixed width internally now.
                        DialLegend(categories: categories,
                                   selection: $selection,
                                   countDescription: countDescription)
                        dialFace(diameter: face)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                // **The knob never leaves.** It was the thing tapped to open the
                // dial, so it is the first place a hand goes to put it away —
                // and closing used to be a long press on the readout, which is
                // to say there was no way to close it that anyone would find.
                // Staying in one place through both states makes it a switch
                // rather than two different controls.
                knob
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 104)
            }
            .onChange(of: selection) { syncAngleToSelection() }
        }
    }

    // MARK: At rest

    private var knob: some View {
        Button {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) { expanded.toggle() }
        } label: {
            Image(systemName: expanded ? "xmark" : "dial.medium")
                .font(.system(size: expanded ? 16 : 20, weight: .medium))
                .foregroundStyle(expanded ? Color.accentColor : .primary)
                // The two glyphs are a different size and a different aspect
                // ratio (dial.medium is 27×24pt, xmark is 17×16pt), and without
                // this the toggle crossfades between them as plain content —
                // which interpolates the OLD glyph's bounding box into the NEW
                // one rather than replacing symbol-for-symbol, and can leave the
                // glyph looking like it's settled off-centre for a moment
                // rather than snapping cleanly to its own centred position.
                // `.symbolEffect(.replace)` is the system's own transition for
                // exactly this case.
                .contentTransition(.symbolEffect(.replace))
                .frame(width: Self.knob, height: Self.knob)
                .liquidGlass(interactive: true, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Close map filter" : "Map filter")
        .accessibilityValue(currentLabel)
        .accessibilityHint(expanded ? "Closes the dial."
                                    : "Opens the dial for choosing what the map shows.")
    }

    // MARK: Open

    private func dialFace(diameter: CGFloat) -> some View {
        // The hole has to be a real hole. A filled face — even a faint one — sits
        // between the finger and the pins it is filtering, so a pin under the dial
        // could be seen and not touched. `RingShape` (top of file) IS the ring, so
        // there is nothing to mask afterward — see the file header for why that
        // used to make the glass look more opaque than every other glass surface
        // in the app, not just leave a gap.
        let ring = RingShape(lineWidth: Self.rimWidth)
        let innerFraction = (diameter - Self.rimWidth * 2) / diameter
        return ZStack {
            ring
                .fill(.clear)
                .liquidGlass(interactive: true, in: ring)

            milling(diameter: diameter)
            detentMarks(diameter: diameter)

            // Fixed index mark at twelve o'clock — the thing the categories turn
            // past, as on the detector's own dial.
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 3, height: 14)
                .offset(y: -diameter / 2 + Self.rimWidth / 2)
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle().subtracting(Circle().scale(innerFraction)))
        .gesture(faceDrag(diameter: diameter))
    }

    /// The milled edge. It turns with the drag, which is the only thing that
    /// shows the dial moving — a circle in a fixed position gives no feedback at
    /// all, however precisely it is tracking the finger.
    private func milling(diameter: CGFloat) -> some View {
        let count = 72
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Color.glassEdge)
                    .frame(width: 1.2, height: 10)
                    .offset(y: -diameter / 2 + Self.rimWidth / 2)
                    .rotationEffect(.degrees(Double(i) / Double(count) * 360))
            }
        }
        .rotationEffect(.degrees(angle))
    }

    /// One longer mark per category, so the detents can be seen as well as felt
    /// and the spacing around the ring is legible.
    ///
    /// **No words on the wheel.** Each mark carried its category's name, which
    /// meant six labels small enough to fit the rim and each counter-rotated to
    /// stay upright — a lot of moving type to say what the pill above the ring
    /// already says, once, at a readable size. The marks now only say where the
    /// detents are, which is the one thing the pill cannot show.
    private func detentMarks(diameter: CGFloat) -> some View {
        ZStack {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, _ in
                Capsule()
                    .fill(index == selection ? Color.accentColor : .primary.opacity(0.5))
                    .frame(width: 2, height: 15)
                    .offset(y: -diameter / 2 + Self.rimWidth / 2)
                    .rotationEffect(.degrees(degreesPerStep * Double(index) + angle))
            }
        }
    }

    // MARK: State

    private var currentLabel: String {
        categories.indices.contains(selection) ? categories[selection].label : ""
    }

    private var degreesPerStep: Double {
        categories.isEmpty ? 360 : 360 / Double(categories.count)
    }

    /// The resting angle for `index` that is closest to where the dial already is.
    ///
    /// **There is more than one right answer, and picking the wrong one spins the
    /// dial the long way round.** Every category sits at `-index · step`, but also
    /// at that angle plus or minus any whole turn — and the canonical value is
    /// often most of a revolution from where the finger actually left off. Turning
    /// a little anticlockwise from Species to reach Stories, the last of six, ended
    /// at about +60° while the canonical value for Stories is −300°, so releasing
    /// wound the ring a full turn forwards to land in the place it was already in.
    ///
    /// Choosing the nearest equivalent keeps the rotation continuous: the dial only
    /// ever moves as far as the detent it is snapping to, whichever way that is.
    private func nearestAngle(for index: Int, to current: Double) -> Double {
        Self.nearestAngle(for: index, to: current, degreesPerStep: degreesPerStep)
    }

    /// Pure, and `static` so it can be tested: the rotation maths has been wrong
    /// twice — once oscillating mid-drag, once winding a whole turn on release —
    /// and neither showed up as anything but "the dial feels odd".
    static func nearestAngle(for index: Int, to current: Double,
                             degreesPerStep: Double) -> Double {
        let base = -degreesPerStep * Double(index)
        // How many whole turns to add to `base` to sit closest to `current`.
        let turns = ((current - base) / 360).rounded()
        return base + turns * 360
    }

    /// Below this, a released drag is a jiggle rather than a flick and stays on
    /// the category it started on. Above it, release commits — see `onEnded`.
    /// Fixed rather than scaled to `degreesPerStep`: it is standing in for "did
    /// the finger clearly move", which is a fact about the finger, not about how
    /// many categories happen to be on the dial.
    private static let flickThresholdDegrees: Double = 6

    private func faceDrag(diameter: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    dragBase = angle
                    dragStartIndex = selection
                }
                let centre = CGPoint(x: diameter / 2, y: diameter / 2)
                let from = atan2(value.startLocation.y - centre.y,
                                 value.startLocation.x - centre.x)
                let to = atan2(value.location.y - centre.y,
                               value.location.x - centre.x)
                // Shortest way round, so a drag across the 180° seam does not
                // spin the face the long way about.
                var delta = (to - from) * 180 / .pi
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                angle = dragBase + delta

                let index = indexFor(angle: angle)
                if index != lastTickedIndex {
                    lastTickedIndex = index
                    selection = index
                    // The tick is what makes the detents findable without looking,
                    // which is the point of imitating a dial rather than drawing one.
                    UISelectionFeedbackGenerator().selectionChanged()
                }
            }
            .onEnded { _ in
                dragging = false
                lastTickedIndex = nil

                // **Off the start point commits forward; it does not spring
                // back.** The old release animation carried the drag's speed
                // into a bouncy settle — physically correct, and it still read
                // as "sticky", because a small drag that never reached the
                // halfway point to the next detent would always return to where
                // it started. That return read as the dial resisting a flick
                // it should have honoured.
                //
                // `selection` already tracks every halfway crossing live (set
                // above, in `onChanged`), so if the drag went far enough to tick
                // over at all, `selection` already disagrees with
                // `dragStartIndex` and this only has to confirm it. The branch
                // that matters is the one below: a small flick that never
                // crossed the halfway line still moved the angle, and that
                // movement is the only evidence needed of which way it was
                // headed — no further distance is required.
                let netAngle = angle - dragBase
                let target: Int
                if selection != dragStartIndex {
                    target = selection
                } else if abs(netAngle) > Self.flickThresholdDegrees, categories.count > 1 {
                    // Index rises as angle falls — see `nearestAngle`'s base —
                    // so a negative turn is a step forward.
                    let count = categories.count
                    let step = netAngle < 0 ? 1 : -1
                    target = ((dragStartIndex + step) % count + count) % count
                } else {
                    target = dragStartIndex
                }
                if target != selection {
                    selection = target
                    UISelectionFeedbackGenerator().selectionChanged()
                }

                // A quick, critically-damped settle — no overshoot, no bounce.
                // This is a snap to the category the release just committed to,
                // not a fling with momentum; see the comment above for why the
                // commit decision is what needed to change, not the physics of
                // the landing.
                withAnimation(.spring(response: 0.28, dampingFraction: 0.92)) {
                    angle = nearestAngle(for: target, to: angle)
                }
            }
    }

    private func indexFor(angle: Double) -> Int {
        guard !categories.isEmpty else { return 0 }
        let steps = (-angle / degreesPerStep).rounded()
        let count = categories.count
        // Swift's `%` keeps the sign, so a leftward spin past zero would index
        // backwards out of the array.
        return ((Int(steps) % count) + count) % count
    }

    /// Follows `selection` when something else changes it — the legend's tap, or
    /// VoiceOver's adjustable action. Without this the category would change and
    /// the ring would sit still, which reads as the dial having failed.
    ///
    /// Skipped while dragging: there the finger is the source of truth and the
    /// angle is already being set directly.
    private func syncAngleToSelection() {
        guard !dragging else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            angle = nearestAngle(for: selection, to: angle)
        }
    }
}

/// A dial position. `categoryID` is `nil` for Species, which is the app's own
/// position rather than one of the website's categories.
struct DialCategory: Identifiable, Hashable {
    let categoryID: String?
    let label: String
    var id: String { categoryID ?? "__species" }

    static let species = DialCategory(categoryID: nil, label: "Species")
}

/// The dial's readout, stacked directly above the ring with a fixed gap — see
/// `GlobeDial.body`.
///
/// It has been in three places before this: in the middle of the face, where it
/// covered the very pins the ring was opened to expose; under the search row,
/// which is a long way from the hand turning the dial; and layered over the top
/// of the ring at a hand-tuned offset, which drifted out of true whenever either
/// view's size changed. A `VStack` with the ring makes "just above" a fact about
/// the layout instead of a number someone eyeballed.
struct DialLegend: View {
    let categories: [DialCategory]
    @Binding var selection: Int
    let countDescription: String

    /// **Fixed, not sized to the current label.** "Species" and "Conservation"
    /// are different widths, and a pill that resized with every detent made the
    /// two chevrons either side of it shuffle sideways as you turned the dial —
    /// the one thing either side of a stepper should NOT do while you're
    /// reading it. Wide enough for the longest label this app ships with room
    /// to spare; the count line below gets a shrink-to-fit safety net instead of
    /// its own width budget, since it is the more variable of the two.
    private static let width: CGFloat = 210

    var body: some View {
        HStack(spacing: 8) {
            // **Left and right, not just forward.** A single tap on the whole
            // pill only ever advanced — there was no way to turn back except
            // spinning the ring itself all the way round. Two chevrons make
            // "back one" and "forward one" separate, visible targets either
            // side of the reading, the way a stepper control normally works.
            chevronButton(systemName: "chevron.backward") { step(to: selection - 1) }
            // Centred, not leading — leading alignment reads fine when the pill
            // sizes itself to the text, but against a FIXED width it left every
            // label hugging the left chevron with empty space on the right.
            VStack(alignment: .center, spacing: 1) {
                Text(currentLabel)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // A crossfade, not a snap. Turning the ring steps the name
                    // through every category it passes, and hard cuts at that
                    // rate read as flicker; a short dissolve reads as tuning
                    // through them, which is what the gesture is.
                    .id(currentLabel)
                    .transition(.opacity)
                Text(countDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .id(countDescription)
                    .transition(.opacity)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            chevronButton(systemName: "chevron.forward") { step(to: selection + 1) }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: Self.width)
        .liquidGlass(interactive: true, in: Capsule())
        // Driven from `selection` rather than from a `withAnimation` around the
        // drag: the drag sets the ring's angle directly and animating THAT would
        // put a spring between the finger and the glass.
        .animation(.easeInOut(duration: 0.18), value: selection)
        .animation(.easeInOut(duration: 0.18), value: countDescription)
        // **One VoiceOver element, not three.** The two chevron buttons below
        // are real `Button`s so a sighted, non-VoiceOver tap has a proper target
        // on each side — but each is `accessibilityHidden`, so VoiceOver still
        // sees a single adjustable control it can swipe up/down through, rather
        // than three separate stops (button, value, button) to navigate past.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Map filter")
        .accessibilityValue(currentLabel)
        .accessibilityHint("Swipe up or down for the next or previous category.")
        .accessibilityAdjustableAction { direction in
            step(to: direction == .increment ? selection + 1 : selection - 1)
        }
    }

    /// A comfortable tap target either side of the reading — bigger than the
    /// glyph itself, so this is a real stepper button and not a fiddly icon.
    /// Hidden from VoiceOver; see the accessibility note on `body`.
    private func chevronButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHidden(true)
    }

    private var currentLabel: String {
        categories.indices.contains(selection) ? categories[selection].label : ""
    }

    private func step(to index: Int) {
        guard !categories.isEmpty else { return }
        let count = categories.count
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            selection = ((index % count) + count) % count
        }
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
