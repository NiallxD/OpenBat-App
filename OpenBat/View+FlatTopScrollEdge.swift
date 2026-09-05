//
//  View+FlatTopScrollEdge.swift
//  OpenBat
//
//  iOS 26's Liquid Glass adds an automatic effect where scrollable content
//  (List, ScrollView, Map) meets a toolbar. Its `.soft` default blurs/fades the
//  content under a translucent bar; `.hard` cuts it flat — but both still paint
//  their own scrim above the nav bar's background, which on this app's all-black
//  screens reads as a grey header bar sitting above the content.
//
//  This app has nothing bright to blend under a bar, so the effect buys nothing.
//  `.flatTopScrollEdge()` removes it entirely, leaving the nav bar's own opaque
//  background (forced flat black in `OpenBatApp.configureNavigationBarAppearance`)
//  as the only thing drawn there.
//

import SwiftUI

extension View {
    /// `flatTopScrollEdge()`, unless a caller wants the effect left on — for a
    /// screen whose bar sits over a photo rather than over black, where the
    /// blur is what makes the title readable.
    @ViewBuilder
    func flatTopScrollEdgeUnless(_ keepEffect: Bool) -> some View {
        if keepEffect { self } else { flatTopScrollEdge() }
    }

    @ViewBuilder
    func flatTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .top)
        } else {
            self
        }
    }
}
