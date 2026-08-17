//
//  GlassStyle.swift
//  OpenBat
//
//  Shared Liquid Glass helpers, ported from the same file in the ADHD app.
//
//  The deployment target is 18.0 while the SDK is 26.x, so every glass call has
//  to sit behind an availability check with a real fallback — not an
//  `if #available` that renders nothing on older systems. Centralising that here
//  means the check is written once instead of at every call site, and the
//  fallback stays consistent.
//
//  Note this is a DIFFERENT concern from the `GlassEffectContainer` +
//  `.glassEffect(.identity)` wrapping around the toolbar `Menu`s in
//  ContentView. That is a workaround for Liquid Glass hiding a Menu's label
//  while the menu is open; this is about having a material at all before
//  iOS 26. Don't merge them.
//

import SwiftUI

/// Groups adjacent glass elements so they sample and blend as one material.
/// Passthrough before iOS 26.
///
/// Deliberately NOT used to wrap the tab bar and the session button together —
/// a container unions the glass of everything inside it into a single shape,
/// which over the detector's spectrogram reads as one wide slab behind both
/// rather than the system's arrangement of a bar and a detached round button.
/// See `LegacyTabBar`'s call site.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Liquid Glass where it exists, a material of similar weight where it
    /// doesn't.
    ///
    /// `interactive` gives the glass its press-and-settle response — worth
    /// having on things you tap, wrong on things you merely look at.
    /// `interactive` ALSO makes the whole shape tappable, which is not cosmetic.
    /// `.frame(width:height:)` only sets layout size — the hit region stays
    /// whatever the content actually draws. A `.background(_:in:)` used to fill
    /// that gap incidentally; `.glassEffect` does not, so an icon inside a 58pt
    /// circle ends up with only the glyph responding to taps. Every interactive
    /// glass surface therefore gets an explicit `contentShape`.
    @ViewBuilder
    func liquidGlass(
        tinted tint: Color? = nil,
        interactive: Bool = false,
        in shape: some Shape
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(glass(tint: tint, interactive: interactive), in: shape)
                .contentShape(interactive ? AnyShape(shape) : AnyShape(.rect))
        } else {
            background(tint ?? Color.clear, in: shape)
                .background(.regularMaterial, in: shape)
                .contentShape(interactive ? AnyShape(shape) : AnyShape(.rect))
        }
    }

    @available(iOS 26.0, *)
    private func glass(tint: Color?, interactive: Bool) -> Glass {
        var result = Glass.regular
        if let tint { result = result.tint(tint) }
        if interactive { result = result.interactive() }
        return result
    }
}
