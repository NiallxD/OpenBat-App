//
//  TwoAxisPinchView.swift
//  OpenBat
//
//  A transparent UIKit overlay providing PER-AXIS pinch-to-zoom for
//  WavSpectrogramView: spreading the fingers horizontally stretches the TIME
//  axis, vertically the FREQUENCY axis, diagonally both — each axis's scale
//  is the ratio of the current to the initial finger separation ALONG THAT
//  AXIS, which no stock recognizer provides (UIPinchGestureRecognizer and
//  SwiftUI's MagnifyGesture both reduce the gesture to one uniform scale).
//
//  UIKit rather than SwiftUI for two reasons:
//   1. Per-axis separation needs the two raw touch locations, which SwiftUI
//      gestures don't expose.
//   2. A composed SwiftUI MagnifyGesture + DragGesture previously caused the
//      momentum "stops dead" bug — two recognizers arbitrating the same touch
//      made the drag spuriously re-fire onEnded mid-swipe (see
//      WavSpectrogramView.panGesture's doc comment). This recognizer avoids
//      that: it never fires on fewer than two touches, never cancels touches
//      (`cancelsTouchesInView = false`), and always recognizes
//      simultaneously, so the single-finger pan/tap/momentum path is
//      untouched — WavSpectrogramView just suppresses its own drag handling
//      while `isPinching` (see its panGesture guards).
//
//  Each axis's AUTHORITY ramps smoothly with its initial separation (see
//  `axisScale`): below `axisDeadZonePt` the axis is inert, at
//  `axisFullWeightPt`+ it responds fully, and in between the scale is damped
//  via `pow(ratio, weight)`. A hard threshold isn't enough: two fingertips
//  stacked nearly vertically have only a few noisy points of horizontal
//  separation (dividing by it explodes the scale — the dead zone kills that,
//  and lets a deliberate single-axis pinch leave the other axis alone), and a
//  hard cutoff made a natural diagonal pinch erratic (whichever axis started
//  just past it had a tiny ratio denominator and zoomed hypersensitively).
//  The ramp instead makes authority proportional to how clearly the gesture
//  expresses intent along each axis.
//

import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reported continuously while a two-finger pinch is active. Scales are
/// current/initial separation per axis (1 = unchanged, >1 = fingers spread =
/// zoom in); offsets and the anchor are fractions of the view's size, in the
/// same screen-fraction space `WavViewportMath.resolvedViewport` works in.
struct TwoAxisPinchValue {
    var scaleX: Double
    var scaleY: Double
    /// Centroid movement since the pinch began (view-size fractions) — lets a
    /// two-finger drag pan while it zooms, same convention as the one-finger
    /// pan's gestureOffsetX/Y.
    var centroidDXFrac: Double
    var centroidDYFrac: Double
    /// The pinch's INITIAL centroid (view-size fractions) — the zoom anchor:
    /// the content point under it stays put as the scale changes.
    var anchorXFrac: Double
    var anchorYFrac: Double
}

struct TwoAxisPinchView: UIViewRepresentable {
    /// Below this initial finger separation an axis contributes nothing…
    static let axisDeadZonePt: CGFloat = 24
    /// …and at this separation (or more) it responds at full strength, with
    /// a linear authority ramp in between — see `axisScale` and the header
    /// doc comment for why a smooth ramp replaced a hard threshold.
    static let axisFullWeightPt: CGFloat = 120

    /// Per-axis scale: the current/initial separation ratio along one axis,
    /// raised to that axis's authority weight. `pow(ratio, 0) = 1` (inert),
    /// `pow(ratio, 1) = ratio` (full effect); between the two, small initial
    /// separations get proportionally damped instead of amplifying every
    /// point of movement through a tiny denominator.
    static func axisScale(startSeparation: CGFloat, currentSeparation: CGFloat) -> Double {
        guard startSeparation > 1 else { return 1 }
        let ratio = min(max(Double(currentSeparation / startSeparation), 0.05), 20)
        let weight = min(max((Double(startSeparation) - Double(axisDeadZonePt))
                             / Double(axisFullWeightPt - axisDeadZonePt), 0), 1)
        return pow(ratio, weight)
    }

    var onBegan: () -> Void
    var onChanged: (TwoAxisPinchValue) -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        let recognizer = TwoAxisPinchGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TwoAxisPinchView
        init(_ parent: TwoAxisPinchView) { self.parent = parent }

        @objc func handle(_ recognizer: TwoAxisPinchGestureRecognizer) {
            guard let view = recognizer.view,
                  view.bounds.width > 0, view.bounds.height > 0 else { return }
            switch recognizer.state {
            case .began:
                WavPlayerDebugLog.log("TwoAxisPinch", "recognizer -> BEGAN")
                parent.onBegan()
                parent.onChanged(value(for: recognizer, in: view.bounds.size))
            case .changed:
                // Ignore a `.changed` delivered once a tracked touch has
                // already lifted: within the finger-up UIEvent, UIKit
                // dispatches the pending `.changed` AFTER `touchesEnded` has
                // nil'd the touches, so `value(for:)` would fall back to the
                // start positions and compute a bogus scale 1.0 — which then
                // overwrote the real zoom right before `.ended` committed it
                // (the "pinch snaps back / refuses to zoom" bug, confirmed in
                // the gesture log). Skipping it keeps the last VALID scale, so
                // the commit zooms to where the fingers actually were.
                guard recognizer.isTrackingBoth else {
                    WavPlayerDebugLog.log("TwoAxisPinch", "recognizer .changed IGNORED (a touch already lifted — keeping last valid scale)")
                    break
                }
                parent.onChanged(value(for: recognizer, in: view.bounds.size))
            case .ended, .cancelled, .failed:
                WavPlayerDebugLog.log("TwoAxisPinch", "recognizer -> \(recognizer.state == .ended ? "ENDED" : recognizer.state == .cancelled ? "CANCELLED" : "FAILED")")
                parent.onEnded()
            default:
                break
            }
        }

        private func value(for r: TwoAxisPinchGestureRecognizer, in size: CGSize) -> TwoAxisPinchValue {
            let a0 = r.startA, b0 = r.startB
            let a1 = r.pointA, b1 = r.pointB
            let scaleX = TwoAxisPinchView.axisScale(startSeparation: abs(a0.x - b0.x),
                                                    currentSeparation: abs(a1.x - b1.x))
            let scaleY = TwoAxisPinchView.axisScale(startSeparation: abs(a0.y - b0.y),
                                                    currentSeparation: abs(a1.y - b1.y))
            let c0 = CGPoint(x: (a0.x + b0.x) / 2, y: (a0.y + b0.y) / 2)
            let c1 = CGPoint(x: (a1.x + b1.x) / 2, y: (a1.y + b1.y) / 2)
            return TwoAxisPinchValue(
                scaleX: scaleX, scaleY: scaleY,
                centroidDXFrac: Double((c1.x - c0.x) / size.width),
                centroidDYFrac: Double((c1.y - c0.y) / size.height),
                anchorXFrac: Double(c0.x / size.width),
                anchorYFrac: Double(c0.y / size.height))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }
}

/// Tracks exactly two touches and exposes their start + current locations.
/// Begins the moment the second touch lands, ends when either lifts; a
/// single touch that comes and goes without a partner fails silently
/// (leaving the one-finger pan/tap path, which runs simultaneously, alone).
final class TwoAxisPinchGestureRecognizer: UIGestureRecognizer {
    private weak var touchA: UITouch?
    private weak var touchB: UITouch?
    private(set) var startA: CGPoint = .zero
    private(set) var startB: CGPoint = .zero

    var pointA: CGPoint { touchA?.location(in: view) ?? startA }
    var pointB: CGPoint { touchB?.location(in: view) ?? startB }

    /// True only while BOTH pinch touches are still down — the guard that
    /// stops a post-finger-lift `.changed` from computing a degenerate
    /// scale (see the coordinator's `.changed` handling).
    var isTrackingBoth: Bool { touchA != nil && touchB != nil }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            if touchA == nil || touchA === touch {
                touchA = touch
            } else if touchB == nil || touchB === touch {
                touchB = touch
            } else {
                ignore(touch, for: event)   // third+ fingers play no part
            }
        }
        if let a = touchA, let b = touchB, state == .possible {
            startA = a.location(in: view)
            startB = b.location(in: view)
            state = .began
        }
        WavPlayerDebugLog.log("TwoAxisPinch", "touchesBegan: +\(touches.count) now tracking A=\(touchA != nil) B=\(touchB != nil) state=\(state.rawValue)")
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touchA != nil, touchB != nil,
              state == .began || state == .changed else { return }
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        endIfTracked(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        endIfTracked(touches)
    }

    private func endIfTracked(_ touches: Set<UITouch>) {
        let liftedTracked = touches.contains(where: { $0 === touchA || $0 === touchB })
        WavPlayerDebugLog.log("TwoAxisPinch", "touchesEnded/Cancelled: -\(touches.count) liftedTracked=\(liftedTracked) state=\(state.rawValue)")
        guard liftedTracked else { return }
        if state == .began || state == .changed {
            state = .ended
        } else {
            state = .failed
        }
        touchA = nil
        touchB = nil
    }

    override func reset() {
        super.reset()
        touchA = nil
        touchB = nil
    }
}
