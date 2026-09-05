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
import UIKit

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

extension Color {
    /// The page every screen in this app is drawn on.
    ///
    /// **The detector's ground, and every other screen is matched to it**
    /// (Niall, 2026-09-02). It briefly was a few percent of grey, on the
    /// reasoning that glass tiles need something to stand against — and that is
    /// what exposed the real problem: the detector never showed it. A root-level
    /// background sits UNDER the `TabView`, which paints `systemBackground`
    /// itself, so the grey reached every list that opted into it and nothing
    /// else. The detector stayed white and the Sessions tab went visibly darker
    /// than it, which is the bug that got reported.
    ///
    /// So it is `systemBackground` — pure white in light, true black in dark —
    /// and the detector paints it explicitly rather than inheriting it, so no
    /// screen can quietly be a different colour from the rest again. **This
    /// constant is the whole page palette: change it here and every screen
    /// follows, including the detector.**
    ///
    /// A spectrogram's own ground is `systemBackground` too, on purpose: the
    /// plot is a picture, and it reading as continuous with the page is right
    /// when silence and the page are the same colour.
    static let appBackground = Color(uiColor: .systemBackground)

    /// The same hue, dropped in brightness for light mode; untouched in dark.
    ///
    /// The status pills — a confidence percentage, the "sounds alike" flag —
    /// are a saturated colour on a 20% wash of itself. Against black that is a
    /// bright mark on a dark ground and reads at a glance; against white the
    /// wash is nearly the page and the orange text sits on it at almost no
    /// contrast (Niall, 2026-09-02). Darkening the ink rather than deepening the
    /// wash keeps the pill light, which is what it is for.
    ///
    /// Resolved through a dynamic `UIColor` so one call site serves both
    /// appearances and follows a switch made while the app is running.
    func darkenedInLightMode(brightness: CGFloat = 0.62,
                             saturation: CGFloat = 1.15) -> Color {
        let base = UIColor(self)
        return Color(uiColor: UIColor { trait in
            let resolved = base.resolvedColor(with: trait)
            guard trait.userInterfaceStyle != .dark else { return resolved }
            var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            guard resolved.getHue(&h, saturation: &sat, brightness: &b, alpha: &a) else {
                return resolved
            }
            return UIColor(hue: h, saturation: min(sat * saturation, 1),
                           brightness: b * brightness, alpha: a)
        })
    }

    /// The hairline edge every glass surface in this app is drawn with — tiles,
    /// panels, the tab bar, the tuning overlay, the info cards.
    ///
    /// It was `.white.opacity(0.12)` at a dozen call sites, which is exactly
    /// right on a dark ground and invisible on a light one — so when the app
    /// stopped forcing dark mode (2026-09-02) every card lost its outline at
    /// once. `.primary` resolves to white in dark mode and black in light, so
    /// dark is unchanged to the value and light gets the same edge the other way
    /// up.
    ///
    /// **This is for chrome only.** White drawn ON a photo, a spectrogram or a
    /// map — the axis labels, a photo credit, a pin's glyph — stays literally
    /// white: what it sits on doesn't change with the appearance setting.
    static let glassEdge = Color.primary.opacity(0.12)

    /// The same idea for a filled chrome surface — a selected tab's pill, a
    /// slider's track behind the glass.
    static func chromeFill(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }
}

/// A `Label` whose glyph is the app's orange and whose text is ordinary ink.
///
/// The default takes the accent colour for the glyph, and this project's
/// AccentColor asset carries no colour — so every unstyled `Label` icon in the
/// app came out the system blue. Naming the colour is the fix; setting the asset
/// would be the other one, but that repaints every default-tinted control in the
/// app and is a bigger decision than a glyph.
struct BatAccentIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label {
            configuration.title
        } icon: {
            configuration.icon.foregroundStyle(Color.batAccent)
        }
    }
}

extension LabelStyle where Self == BatAccentIconLabelStyle {
    static var batAccentIcon: BatAccentIconLabelStyle { BatAccentIconLabelStyle() }
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
