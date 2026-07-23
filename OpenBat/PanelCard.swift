//
//  PanelCard.swift
//  OpenBat
//
//  Shared card chrome for grouping a screen into titled sections. Originally
//  lived as a private extension on ContentView (the Detector screen's own
//  stats/pulse/spectrogram/species panels) — pulled out here so other
//  screens (the WAV player's call-analysis stats + spectrogram) can present
//  identically instead of inventing their own look.
//

import SwiftUI

extension View {
    /// Transparent rounded card with a thin hairline border — the
    /// "structural" panel look (ContentView's pulse/spectrogram/species
    /// panels; the WAV player's spectrogram panel).
    func panelCard(cornerRadius: CGFloat = 10) -> some View {
        clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
            )
    }

    /// Filled `.ultraThinMaterial` rounded card — the "readout" panel look
    /// (ContentView's STATS strip; the WAV player's call-analysis panel).
    /// Distinct from `panelCard()` (transparent, hairline-only): a
    /// text-heavy numeric readout reads better against a visible surface
    /// than a purely structural grouping does.
    func filledPanelCard(cornerRadius: CGFloat = 10) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// Small-caps section title row — same look as ContentView's private
/// `panelHeader`, reusable outside that file. `trailing` defaults to nothing
/// for the common case of a title with no header-row controls.
struct PanelTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 4)
    }
}
