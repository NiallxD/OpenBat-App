//
//  UnknownSpeciesThumbnail.swift
//  OpenBat
//
//  What stands in for a species photo when there is no species.
//
//  Every list that leads with a picture — the species feed, the recordings list,
//  a session's passes — is scanned rather than read, and the picture is what
//  carries the scan. A row that never resolved to a bat still needs something in
//  that slot, and what it had was whatever happened to be available: the pass's
//  own spectrogram where there was one, a grey tile with a waveform glyph where
//  there wasn't. So "we couldn't name this" looked different in three places and
//  looked, at a glance, like a species with an unusually dull photo.
//
//  Now it is one thing everywhere: a dark tile carrying the app's own bat mark in
//  orange (Niall, 2026-09-07). Orange because that is already the app's colour for
//  an unresolved identification — the "or MYYU" pill on an ambiguous pass uses it
//  — so the rows agree with the badges. Dark because it must not read as a
//  photograph at thumbnail size, which the old spectrogram fallback did.
//
//  Struck through when the model's answer was NOISE. "This wasn't a bat" is a
//  claim the app is making, not a question it is declining to answer, and the two
//  should not look identical — one is a result, the other is its absence.
//
//  This reverses a decision from 2026-09-02, which kept the spectrogram on those
//  rows on the grounds that it was "the only thing there is to show". It is still
//  the only thing there is to show; it was just not worth showing, because a
//  spectrogram at 44 points wide tells nobody anything and cost the list the one
//  cue that made it scannable. The spectrogram is still on the pass detail, at a
//  size where it can be read.
//

import SwiftUI

struct UnknownSpeciesThumbnail: View {

    /// Why there is no species — the two states look alike and mean opposite
    /// things, so the tile says which.
    enum Reason {
        /// Heard, and not named: NoID, UNID, or a pass declined because its top
        /// two species were too close to separate.
        case unidentified
        /// The model's confident "this wasn't a bat" — struck through, because
        /// the app is making a claim here rather than declining to.
        case notABat
    }

    var reason: Reason = .unidentified
    /// The tile's width. Height follows the host — `fillsHeight` stretches to it,
    /// otherwise the tile is square.
    var size: CGFloat = 50
    var cornerRadius: CGFloat = 10
    /// Matches `GuideSpeciesThumbnail`: the feed's photo runs full-bleed into the
    /// card's leading edge and takes its corners from the card's own clip.
    var fillsHeight: Bool = false
    /// Explicit width and height, for hosts that size the slot themselves rather
    /// than passing a single dimension (a session's pass row uses 56 × 40).
    var explicitSize: CGSize?

    var body: some View {
        Image("batIcon")
            .resizable()
            .scaledToFit()
            .foregroundStyle(Color.orange)
            .padding(padding)
            .frame(width: explicitSize?.width ?? size,
                   height: explicitSize?.height ?? (fillsHeight ? nil : size))
            .frame(maxHeight: fillsHeight && explicitSize == nil ? .infinity : nil)
            .background(Color.black.opacity(0.82))
            .overlay { if reason == .notABat { slash } }
            .clipShape(fillsHeight && explicitSize == nil
                       ? AnyShape(Rectangle())
                       : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
            .accessibilityLabel(reason == .notABat ? "Not a bat" : "Species not identified")
    }

    /// Drawn twice: a dark casing under an orange line, so the stroke stays
    /// legible where it crosses the mark instead of dissolving into it. Sized
    /// from the tile rather than fixed, because the same view is used at 40, 44
    /// and 50 points and a constant width reads heavy at the small end.
    private var slash: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let line = Path { p in
                p.move(to: CGPoint(x: w * 0.18, y: h * 0.82))
                p.addLine(to: CGPoint(x: w * 0.82, y: h * 0.18))
            }
            let weight = max(1.5, min(w, h) / 11)
            ZStack {
                line.stroke(Color.black.opacity(0.82),
                            style: StrokeStyle(lineWidth: weight + 3, lineCap: .round))
                line.stroke(Color.orange, style: StrokeStyle(lineWidth: weight, lineCap: .round))
            }
        }
    }

    /// Proportional, so the mark sits the same way in a 40pt session row and a
    /// 50pt guide row rather than being lost in one and crowded in the other.
    private var padding: CGFloat {
        (explicitSize.map { min($0.width, $0.height) } ?? size) / 4
    }
}
