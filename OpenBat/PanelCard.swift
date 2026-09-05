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
    /// Transparent rounded card with a hairline border — the "structural" panel
    /// look (ContentView's pulse/spectrogram/species panels; the WAV player's
    /// spectrogram panel).
    ///
    /// **Still transparent.** It takes the tile's radius and the tile's edge
    /// colour so the Detector reads as the same material as the rest of the app
    /// (Niall, 2026-09-02), but nothing is drawn behind it: what these panels
    /// contain is a live spectrogram and a species feed, and glass under either
    /// would be a grey wash over the thing the user is actually looking at. The
    /// backgrounds stay exactly as they were; only the frame changes.
    func panelCard(cornerRadius: CGFloat = TileList.cornerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape)
            .overlay(shape.strokeBorder(Color.glassEdge, lineWidth: 1))
    }

    /// Filled rounded card — the "readout" panel look (ContentView's STATS
    /// strip; the WAV player's call-analysis panel). A text-heavy numeric
    /// readout reads better against a visible surface than a purely structural
    /// grouping does, and that surface is now the app's glass rather than a bare
    /// `.ultraThinMaterial`: this is the same tile a session row is drawn on.
    func filledPanelCard(cornerRadius: CGFloat = TileList.cornerRadius) -> some View {
        glassTile(cornerRadius: cornerRadius)
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
