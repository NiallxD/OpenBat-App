//
//  View+HardTopScrollEdge.swift
//  OpenBat
//
//  iOS 26's Liquid Glass adds an automatic soft blur/fade where scrollable content
//  (List, ScrollView, Map) meets a toolbar — designed to blend bright content under
//  a translucent bar. This app's all-dark aesthetic has nothing bright to blend, so
//  that fade just reads as a washed-out grey header instead of the flat black used
//  everywhere else. `.hardTopScrollEdge()` swaps it for a hard cut.
//

import SwiftUI

extension View {
    @ViewBuilder
    func hardTopScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            self
        }
    }
}
