//
//  ContentSizedSheet.swift
//  OpenBat
//
//  Sizes a compact sheet to what it actually says, instead of to a height
//  guessed when it was written.
//
//  The app's small custom sheets (StartDetectingSheet, SuggestedModelSheet,
//  MicCalibrationView) each pinned themselves to a hand-fitted
//  `.presentationDetents([.height(N)])`. That number was correct for the copy
//  present on the day, and silently wrong afterwards: an acceptance review found
//  the "Start Detection" sheet explaining the one thing a new user needs to know
//  — the difference between a Session and Just Listening — and cutting it off at
//  "Just listening still tracks loc…", with an empty half-screen underneath. The
//  calibration sheet did the same at "It d…".
//
//  Two halves to the fix, and both are needed:
//
//    1. `fixedSize(vertical:)` on the text, so it reports the height it wants
//       rather than shrinking to fit the box. Without this the measurement below
//       just reads back the too-small height and nothing changes.
//    2. Measuring that height and feeding it to the detent.
//
//  The loop converges because the height only ever grows to the content's
//  natural size and then stops changing.
//

import SwiftUI

extension View {
    /// Presents this sheet at whatever height its content needs, clamped to
    /// `minHeight...maxHeight`.
    ///
    /// `maxHeight` is a backstop, not a target: a sheet whose text somehow grows
    /// past it should scroll or be redesigned, not silently truncate again, so
    /// keep it generous.
    func contentSizedDetent(min minHeight: CGFloat = 240,
                            max maxHeight: CGFloat = 560) -> some View {
        modifier(ContentSizedDetent(minHeight: minHeight, maxHeight: maxHeight))
    }

    /// Text that grows vertically instead of truncating. Named for the intent
    /// rather than the mechanism — `fixedSize(horizontal: false, vertical: true)`
    /// reads like the opposite of what it does.
    func wrapsFully() -> some View {
        fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContentSizedDetent: ViewModifier {
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measured in
                guard measured > 0 else { return }
                let clamped = Swift.min(maxHeight, Swift.max(minHeight, measured))
                // Ignore sub-point noise, which would otherwise re-enter this
                // action on every layout pass.
                guard height.map({ abs($0 - clamped) > 0.5 }) ?? true else { return }
                height = clamped
            }
            // Before the first measurement there is no detent, which lets the
            // sheet lay out at its natural size — that first pass is what
            // produces an honest measurement.
            .presentationDetents(height.map { [.height($0)] } ?? [])
            .animation(.snappy(duration: 0.25), value: height)
    }
}
