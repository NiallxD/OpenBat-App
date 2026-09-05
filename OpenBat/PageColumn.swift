//
//  PageColumn.swift
//  OpenBat
//
//  The reading column: how wide a page's content is allowed to be on iPad.
//
//  A page took the full window width, which put a line of body text across
//  ~1300pt — about twice a comfortable measure — and pushed a row of tiles out
//  to opposite ends of the glass (Niall, 2026-09-02). Content is now a fraction
//  of the width, centred, so the margins are even.
//
//  Two fractions rather than one, because 80% of a landscape iPad is wider than
//  the whole portrait screen the number was chosen for.
//
//  Three ways to apply it, and which one a page wants depends on what its
//  background is made of:
//    • `.pageColumn()` — inset with `contentMargins`. The default. A list keeps
//      its full-bleed background and leaves its scroll indicator at the screen
//      edge this way; narrowing the view itself would put bare window down both
//      sides of a page whose background is part of its look.
//    • `.pageColumnFrame()` — narrow the view. For a page that is not a scroll
//      view, so has no content margins to give: the WAV player.
//
//  A page that pins its own content width further in does not need a modifier
//  at all — it asks `PageColumn.width` directly. See `SpeciesDetailView`.
//
//  Not every screen takes it. Content that is not reading matter is worth more
//  the wider it is, and three screens are deliberately full width: the
//  detector, the guide's globe, and a comparison pane — which has already given
//  half the window to the pane beside it, so narrowing each half again would
//  leave two thin ribbons.
//

import SwiftUI

/// The rule, in one place. Applied to the species page, the guide's species
/// lists in both layouts, the sessions list, a session's page and a pass's
/// page.
enum PageColumn {
    /// Below this the container is a phone in all but name — a form sheet, a
    /// slim Split View pane — and both of those can report a REGULAR width
    /// class while being no wider than a phone. So the size class alone is not
    /// enough to decide this on.
    static let minimumContainerWidth: CGFloat = 700

    /// Portrait versus landscape is decided on width alone, not on an aspect
    /// ratio, so the rule can be applied to a view whose height is its
    /// content's rather than the window's. This number splits them cleanly: the
    /// narrowest landscape iPad is 1080pt, the widest portrait one 1024.
    static let landscapeWidth: CGFloat = 1050

    static let portraitFraction: CGFloat = 0.80
    static let landscapeFraction: CGFloat = 0.55

    /// The width content should occupy in a container this wide, or nil where
    /// the column does not apply — a phone, or anything narrower than
    /// `minimumContainerWidth` — and the caller should fill the width as before.
    static func width(for containerWidth: CGFloat,
                      sizeClass: UserInterfaceSizeClass?) -> CGFloat? {
        guard sizeClass == .regular, containerWidth >= minimumContainerWidth else { return nil }
        let fraction = containerWidth >= landscapeWidth ? landscapeFraction : portraitFraction
        return containerWidth * fraction
    }

    /// What each side gives up, for the `contentMargins` spelling. Zero
    /// wherever the column does not apply, so the modifier is a no-op on a
    /// phone rather than something a call site has to guard.
    static func inset(for containerWidth: CGFloat,
                      sizeClass: UserInterfaceSizeClass?) -> CGFloat {
        guard let column = width(for: containerWidth, sizeClass: sizeClass) else { return 0 }
        return max(0, (containerWidth - column) / 2)
    }
}

/// Measures the width the view is GIVEN, which is what every one of these
/// modifiers needs.
///
/// `onGeometryChange`, not `onScrollGeometryChange`: the latter reports when
/// the geometry CHANGES, and a page that is opened, read and left without ever
/// being resized never changes its container size — so the column silently
/// never appeared (Niall, 2026-09-02). Measuring the view's own frame reports
/// at layout, which is when the answer is needed.
///
/// No feedback loop either, as long as this is attached OUTSIDE anything that
/// narrows: it is the size the view is offered, not the size of what is in it.
private struct MeasuredWidth: ViewModifier {
    @Binding var width: CGFloat

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measured in
            if width != measured { width = measured }
        }
    }
}

private extension View {
    func measuringWidth(into width: Binding<CGFloat>) -> some View {
        modifier(MeasuredWidth(width: width))
    }
}

/// `.pageColumn()` — the scroll-view spelling.
private struct PageColumnMargins: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // Horizontal only. Pages set their own top margin (see
            // `TileList.scrollTopMargin`), and the two edges compose.
            .contentMargins(.horizontal,
                            PageColumn.inset(for: containerWidth, sizeClass: sizeClass),
                            for: .scrollContent)
            .measuringWidth(into: $containerWidth)
    }
}

/// `.pageColumnFrame()` — the narrowing spelling.
private struct PageColumnFrame: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        // Two frames, and both are needed: the inner one is the column, the
        // outer one takes the full width so the column has something to be
        // centred in — and so the measurement below reads the container rather
        // than the narrowed content, which would shrink itself a step at a time.
        content
            .frame(maxWidth: PageColumn.width(for: containerWidth, sizeClass: sizeClass) ?? .infinity)
            .frame(maxWidth: .infinity)
            .measuringWidth(into: $containerWidth)
    }
}

extension View {
    /// The reading column, taken off both sides as a scroll content margin.
    func pageColumn() -> some View { modifier(PageColumnMargins()) }

    /// The reading column, applied by narrowing the view itself and centring it.
    func pageColumnFrame() -> some View { modifier(PageColumnFrame()) }
}
