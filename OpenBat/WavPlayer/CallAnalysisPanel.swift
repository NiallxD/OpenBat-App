//
//  CallAnalysisPanel.swift
//  OpenBat
//
//  Displays a CallAnalysis.Result for the current manual drag-selection.
//  Reuses `StatCell` (PulseStatsViews.swift) for the same title/value/unit
//  look the live Detector screen's pulse stats already use, and the shared
//  `filledPanelCard`/`PanelTitle` (PanelCard.swift) for the same "STATS"
//  card look the Detector screen's own stats strip uses.
//
//  The stat grid and hint line are ALWAYS present, at a fixed height,
//  whether or not `result` is nil — cells show "–" placeholders and the hint
//  reads the same instructional text regardless (same "persist, don't
//  disappear" pattern PulseStatsViews.PulseStatValues already uses for a
//  stale/no-data pulse). Previously the whole panel collapsed to a single
//  short placeholder line when `result` was nil and expanded to the full
//  two-row grid once a selection was measured — since this panel sat in the
//  same VStack as the spectrogram (`frame(maxHeight: .infinity)`), that
//  height change visibly resized the spectrogram every time a selection was
//  made or cleared.
//

import SwiftUI

struct CallAnalysisPanel: View {
    let result: CallAnalysis.Result?

    var body: some View {
        VStack(spacing: 0) {
            PanelTitle("Call Analysis")
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)

            VStack(spacing: 8) {
                HStack(spacing: 0) {
                    StatCell(title: "Peak", value: values.peak, unit: "")
                    StatCell(title: "Char. Freq", value: values.charFreq, unit: "")
                    StatCell(title: "Bandwidth", value: values.bandwidth, unit: "")
                    StatCell(title: "Duration", value: values.duration, unit: "ms")
                }
                HStack(spacing: 0) {
                    StatCell(title: "Start", value: values.start, unit: "")
                    StatCell(title: "End", value: values.end, unit: "")
                    StatCell(title: "Sweep", value: values.sweep, unit: "Hz/ms")
                    StatCell(title: "Quality", value: values.quality, unit: "%")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .filledPanelCard()
    }

    private var values: Values { Values(result) }

    /// "–" for every field when there's no result yet, same convention
    /// `PulseStatValues` already uses for a stale/no-data pulse — keeps
    /// `StatCell`'s title/unit layout identical either way.
    private struct Values {
        let peak, charFreq, bandwidth, duration, start, end, sweep, quality: String

        init(_ result: CallAnalysis.Result?) {
            guard let result else {
                peak = "–"; charFreq = "–"; bandwidth = "–"; duration = "–"
                start = "–"; end = "–"; sweep = "–"; quality = "–"
                return
            }
            peak = Self.freqString(result.peakFreqHz)
            charFreq = result.characteristicFreqHz.map(Self.freqString) ?? "–"
            bandwidth = Self.freqString(result.bandwidthHz)
            duration = String(format: "%.1f", result.durationMs)
            start = Self.freqString(result.startFreqHz)
            end = Self.freqString(result.endFreqHz)
            sweep = String(format: "%.1f", result.sweepRateHzPerMs)
            quality = String(format: "%.0f", result.quality * 100)
        }

        private static func freqString(_ hz: Double) -> String {
            hz >= 1000 ? String(format: "%.1f kHz", hz / 1000) : String(format: "%.0f Hz", hz)
        }
    }
}
