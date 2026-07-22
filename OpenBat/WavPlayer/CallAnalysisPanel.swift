//
//  CallAnalysisPanel.swift
//  OpenBat
//
//  Displays a CallAnalysis.Result for the current manual drag-selection.
//  Reuses `StatCell` (PulseStatsViews.swift) for the same title/value/unit
//  look the live Detector screen's pulse stats already use.
//

import SwiftUI

struct CallAnalysisPanel: View {
    let result: CallAnalysis.Result?
    /// Drives the placeholder text below — dragging on the spectrogram only
    /// measures a call while "Select Region" (the toolbar toggle) is on;
    /// otherwise the same drag pans/seeks instead. Tapping a call directly
    /// (the old marker-dot selection) was removed in favour of this
    /// explicit mode — without naming it here, a drag that does nothing
    /// because selection mode is off reads identically to the analysis
    /// itself being broken.
    let isSelecting: Bool

    var body: some View {
        if let result {
            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    StatCell(title: "Peak", value: Self.freqString(result.peakFreqHz), unit: "")
                    StatCell(title: "Char. Freq", value: result.characteristicFreqHz.map(Self.freqString) ?? "–", unit: "")
                    StatCell(title: "Bandwidth", value: Self.freqString(result.bandwidthHz), unit: "")
                    StatCell(title: "Duration", value: String(format: "%.1f", result.durationMs), unit: "ms")
                }
                HStack(spacing: 0) {
                    StatCell(title: "Start", value: Self.freqString(result.startFreqHz), unit: "")
                    StatCell(title: "End", value: Self.freqString(result.endFreqHz), unit: "")
                    StatCell(title: "Sweep", value: String(format: "%.1f", result.sweepRateHzPerMs), unit: "Hz/ms")
                    StatCell(title: "Quality", value: String(format: "%.0f", result.quality * 100), unit: "%")
                }
            }
            .padding(.vertical, 8)
        } else {
            Text(isSelecting
                 ? "Drag over a call to measure it"
                 : "Tap Select Region above, then drag over a call to measure it")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
    }

    private static func freqString(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }
}
