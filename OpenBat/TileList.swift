//
//  TileList.swift
//  OpenBat
//
//  The app's list material: rows drawn as glass tiles rather than as cells
//  inside a system list container.
//
//  It started in the field guide, where the card layout's species tiles and the
//  list layout's rows had to be the same object seen two ways (Niall,
//  2026-09-02). An inset-grouped `List` fought that in three ways at once: it
//  draws a rounded container of its own around each section, insets that
//  container by a margin only it knows — so a hand-built grid's gutter and a
//  list's rows never quite line up — and hands the row a material and a corner
//  radius the app does not control. Rows that carry their own tile need none of
//  it: the list becomes `.plain`, contributes nothing, and every surface
//  measures from the same numbers.
//
//  Sessions and recordings followed, for the same reason from the other
//  direction: they are the same kind of row — a picture, a name, a couple of
//  lines of detail — and they looked like a different app.
//
//  What a tiled list is made of:
//    • `.listStyle(.plain)`, and a `.tileRow()` on every row.
//    • `TileSectionHeading` for group titles, as ROWS not section headers — a
//      plain list pins its headers, and a pinned heading with no background of
//      its own rides over the tiles passing under it.
//    • `RowChevron` where a row pushes, drawn inside the tile: the system's
//      indicator lives in the row's trailing inset, which is outside the glass.
//

import SwiftUI

/// The measurements every tiled list is built to.
///
/// One set of numbers, because these surfaces are the same material in
/// different shapes — a region's species cards, its rows, the compare picker,
/// the sessions list — and the moment two of them keep their own copies the
/// gutters drift by a point or two and the headings stop lining up with the
/// content under them.
enum TileList {
    /// The gutter everything measures from: a grid's padding, and the leading
    /// and trailing inset of every row.
    static let contentInset: CGFloat = 14
    /// Gap between two tiles, whether they sit side by side or stacked.
    static let rowSpacing: CGFloat = 14
    /// Half of it — the gap a single tile carries above and below itself.
    ///
    /// Splitting the gap this way is what lets a heading sit CLOSER to its
    /// content than two tiles sit to each other: two stacked tiles contribute
    /// half each and add up to `rowSpacing`, while a heading meets only one
    /// half. Carrying the whole gap on a row's bottom edge made the space around
    /// a heading the same as the space between two cards, and the page read as
    /// mostly air (Niall, 2026-09-02).
    static var halfGap: CGFloat { rowSpacing / 2 }
    /// The air above and below a section heading. Applied by each layout — one
    /// is a list row's insets, another is padding on a stack — but always these
    /// two numbers.
    ///
    /// **Deliberately lopsided.** A heading belongs to the content UNDER it, so
    /// the gap that separates it from the previous family has to be clearly
    /// bigger than the gap to its own first tile; equal padding either side left
    /// every title floating midway between two groups, belonging to neither
    /// (Niall, 2026-09-02). These add to the `halfGap` each neighbouring tile
    /// already carries, so the space actually drawn is 14pt above a heading and
    /// half of 7 below it. The space a list needs at its very top, where there
    /// is no tile above, is `scrollTopMargin` — the scroll view's, not the
    /// heading's.
    ///
    /// **The bottom one is negative on purpose.** A heading's whole gap to its
    /// first card was the `halfGap` that card carries on its own top edge, and
    /// halving that (Niall, 2026-09-02: "half the distance it is now will do")
    /// means taking some of it back — the tile owns that inset, and the heading
    /// is the only thing in a position to cancel it. Applied by the heading
    /// itself rather than through `listRowInsets`, which does not reliably
    /// honour a negative.
    static let headerTopPadding: CGFloat = 7
    static let headerBottomPadding: CGFloat = -3.5
    /// Breathing room between a tiled list's first heading and the bar above it.
    static let scrollTopMargin: CGFloat = 8
    /// Corner radius of a tile, and of anything meant to read as one.
    static let cornerRadius: CGFloat = 18
}

/// The glass tile every row and card is drawn on: clipped to one radius, on one
/// material, under one hairline edge.
///
/// `clipShape` before the glass, not after: these tiles carry a photo running
/// full bleed to their edges, and glass applied to an unclipped tile would sit
/// under square corners of picture.
private struct GlassTile<S: Shape>: ViewModifier {
    /// Rows and cards take the standard radius; a small tile nested inside a
    /// card takes a tighter one, because the same radius on a 90pt tile reads
    /// rounder than on a full-width row. A caller with a shape of its own —
    /// a tile nested in a system section card, which has to answer to the
    /// corners of the card around it — passes that instead.
    let shape: S

    func body(content: Content) -> some View {
        content
            .clipShape(shape)
            .liquidGlass(in: shape)
            // `stroke` inset by half its width, not `strokeBorder`: the border
            // variant is `InsettableShape`-only, and this takes any shape a
            // caller hands it (the sessions row's concentric rectangle is one).
            .overlay { shape.stroke(Color.glassEdge, lineWidth: 1).padding(0.5) }
    }
}

/// What a row in a tiled list gives back to the list: nothing. No cell
/// background, no separator, and insets that are pure spacing.
private struct TileRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: TileList.halfGap, leading: TileList.contentInset,
                                      bottom: TileList.halfGap, trailing: TileList.contentInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

extension View {
    func glassTile(cornerRadius: CGFloat = TileList.cornerRadius) -> some View {
        glassTile(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// The same tile in a shape the caller supplies.
    func glassTile<S: Shape>(in shape: S) -> some View {
        modifier(GlassTile(shape: shape))
    }
    func tileRow() -> some View { modifier(TileRow()) }

    /// The page a list is drawn on: the app's own ground, not the white a
    /// `.plain` List paints for itself.
    ///
    /// **Never on a grouped `Form`** (Niall, 2026-09-02). A form's page and its
    /// section cards are a matched pair — `systemGroupedBackground` behind
    /// `secondarySystemGroupedBackground` — and in light mode those cards are
    /// white. Replacing the page with the app's own white left every settings
    /// card drawn white on white: still there, completely invisible. A form
    /// keeps the ground its own cards were cut to show against.
    ///
    /// Both halves are needed. Hiding the scroll content background is what
    /// stops the list painting `systemBackground` over the page; setting the
    /// colour is what puts the page back, since the window behind a list is not
    /// something the list's own container shows through to.
    func pageBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.appBackground)
    }
}

/// A section heading: a name, and optionally a smaller detail beside it — the
/// Latin a family files under, a date's recording count.
///
/// **Every bit of its styling lives here, and every tiled list uses it
/// verbatim.** These lists are the same page in different shapes, so a heading
/// that changes weight, colour or capitalisation between them reads as a
/// different screen — and a heading styled at each call site drifts the first
/// time one of them is touched.
struct TileSectionHeading: View {
    let title: String
    var detail: String?

    var body: some View {
        let text = detail.map { Text(title) + Text("  (\($0))").font(.caption2) }
            ?? Text(title)
        return text
            .font(.subheadline.weight(.semibold))
            // A concrete colour, not `.secondary`: a list section header resolves
            // the semantic style through its own vibrancy, so the same
            // `.secondary` came out visibly darker in a list than in a grid.
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The bottom gap is padding on the view, not a row inset — see
            // `headerBottomPadding` for why it has to be able to go negative.
            // Every layout gets it this way, so the sessions list and the
            // guide's card grid stay the same distance from their first card.
            .padding(.bottom, TileList.headerBottomPadding)
            .listRowInsets(EdgeInsets(top: TileList.headerTopPadding,
                                      leading: TileList.contentInset,
                                      bottom: 0,
                                      trailing: TileList.contentInset))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}

/// A row's own disclosure chevron, drawn inside the tile.
///
/// Styled to match the system's — same weight, same tertiary grey — because the
/// point is that nothing about the row looks hand-made; it just sits on the
/// glass rather than beside it. Hide the system's with
/// `.navigationLinkIndicatorVisibility(.hidden)` on the list wherever this is
/// used.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}
