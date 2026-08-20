//
//  View+TopEdgeBlur.swift
//  OpenBat
//
//  A progressive blur across the top of a screen — full strength behind the
//  navigation bar, dissolving to nothing a little way below it — so bright
//  content recedes under the chrome instead of being cut off by a flat black
//  strip.
//
//  Two halves, and BOTH are needed. Applying only one is why the first two
//  attempts at this changed nothing visible:
//    * `clearNavigationBarBackground()` on the screen, so the bar stops
//      painting its own opaque background and the content flows up underneath
//      it. Without this there is nothing in the bar's region to blur — the
//      strip just sits below the bar softening content that was never the
//      problem.
//    * `topEdgeBlur()` on the content, to draw the fade.
//
//  ## Why a material is the right tool here, and wasn't in the ADHD app
//
//  `.ultraThinMaterial` is a BACKDROP filter: it blurs whatever is rendered
//  beneath it. The ADHD app's `GlassList.swift` carries a four-attempt post
//  mortem concluding that "any `.background(.someMaterial)`-shaped idea" is
//  wrong — but that is a conclusion about a different goal. There the backdrop
//  was the wallpaper photograph, which had to stay sharp, and the LIST ROWS on
//  top of it were what needed to dissolve; a material filtered the wrong layer
//  and frosted the photo instead. Here the backdrop IS the content that should
//  soften, so the same primitive does exactly the right thing. Don't "fix" this
//  into a per-view `.blur()` on the strength of that note.
//
//  ## The geometry, which is the part that bites
//
//  `.mask` and `.ignoresSafeArea` applied to the SAME view do not compose
//  safely — the two disagree about which coordinate space the gradient's 0...1
//  range covers, and the fade computes itself against a region far taller than
//  the strip's declared height, washing blur across most of the screen. That
//  was the ADHD app's first attempt, and it is a tempting shape to write.
//
//  The arrangement that works: `.ignoresSafeArea` on an OUTER, non-drawing
//  `GeometryReader`, with the mask on a fixed-height strip INSIDE it, and the
//  height taken from the safe-area inset the reader reports. A view that
//  ignores the safe area still reports how much chrome overlaps it, which is
//  what makes the bar's real height available without hard-coding it.
//

import SwiftUI

extension View {
    /// Stops the navigation bar painting its own background, so content flows
    /// up underneath it.
    ///
    /// The app-wide default is the opposite — `OpenBatApp
    /// .configureNavigationBarAppearance` pins every bar to opaque flat black
    /// via the UIKit appearance proxy. Note that the `.toolbarBackground(
    /// Color.black, for: .navigationBar)` calls dotted around the app are NOT
    /// what does that: `toolbarBackground(_:for:)` is deprecated on iOS 26 and
    /// no longer takes effect, so the proxy is the only thing painting the bar.
    /// This is the per-screen override of it.
    @ViewBuilder
    func clearNavigationBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        } else {
            toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    /// Draws the fade. Pair with `clearNavigationBarBackground()` on the same
    /// screen, and make sure the content itself reaches the top of the window
    /// (`.ignoresSafeArea(edges: .top)`), or there is nothing up there to blur.
    ///
    /// - Parameter falloff: how far below the bar the blur takes to disappear.
    func topEdgeBlur(falloff: CGFloat = 32) -> some View {
        overlay(alignment: .top) {
            TopEdgeBlur(falloff: falloff)
        }
    }
}

private struct TopEdgeBlur: View {
    let falloff: CGFloat

    var body: some View {
        // The reader draws nothing and exists only to ignore the safe area and
        // report its size — see this file's header for why the mask must not
        // sit on the same view as the `ignoresSafeArea`.
        GeometryReader { proxy in
            Rectangle()
                .fill(.ultraThinMaterial)
                // Solid for the bar's own height so the toolbar buttons keep a
                // consistent surface behind them, then out to nothing across
                // `falloff`. A gradient that starts fading immediately leaves
                // the buttons sitting on a half-strength wash, which is harder
                // to read than either extreme.
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: barFraction(in: proxy)),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .frame(height: proxy.safeAreaInsets.top + falloff)
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Where the solid part ends, as a fraction of the strip — i.e. the bottom
    /// of the navigation bar. Guarded against a zero-height report (which does
    /// happen on the first layout pass) so the gradient never divides by zero.
    private func barFraction(in proxy: GeometryProxy) -> Double {
        let total = proxy.safeAreaInsets.top + falloff
        guard total > 0 else { return 0 }
        return min(max(proxy.safeAreaInsets.top / total, 0), 1)
    }
}
