//
//  PulseStatsViews.swift
//  OpenBat
//
//  The last-pulse stat readouts (Fpeak/Bndwth/Dur/Rate/Pulses/Species) as
//  standalone leaf views — extracted from ContentView once it passed 1900
//  lines. Being leaf views is also load-bearing: `pulseDetector`'s stat
//  properties update on essentially every detected pulse, and reading them
//  inline in ContentView.body invalidated (and froze the hit-testing of) the
//  whole screen — see the @Observable-churn note in Context.md §13.
//

import SwiftUI

/// One labelled stat readout (title, big value, small unit) — a leaf View so it
/// carries no dependencies of its own; used by `PulseStatsRow`
/// and (not `private` for this reason) `CallAnalysisPanel` in the WavPlayer.
struct StatCell: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .minimumScaleFactor(0.6)
        .lineLimit(1)
    }
}

/// the same failure mode the amplitude meter had before it was scoped down.
struct PulseStatsRow: View {
    let pulseDetector: PulseDetector

    var body: some View {
        // 1 Hz TimelineView so the last-pulse stats age out on their own —
        // without it they'd freeze at their final values until the next pulse.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let values = PulseStatValues(pulseDetector, now: context.date)
            // One row, five cells. The species readout used to sit under these
            // in a full-width row of its own; it was removed once the pulse
            // panel became a species feed in both modes (2026-08-16), because
            // the same identification was then on screen twice, once in a cell
            // too small to say much and once in a pane with room for the common
            // name, the pulse thumbnail and the runners-up.
            HStack(spacing: 0) {
                StatCell(title: "Fpeak", value: values.fpeak, unit: "kHz")
                statDivider
                StatCell(title: "Bndwth", value: values.bandwidth, unit: "kHz")
                statDivider
                StatCell(title: "Dur", value: values.duration, unit: "ms")
                statDivider
                StatCell(title: "Rate", value: values.rate, unit: "/s")
                statDivider
                StatCell(title: "Pulses", value: "\(pulseDetector.pulseCount)", unit: "")
            }
        }
    }

    private var statDivider: some View {
        Divider().frame(height: 28)
    }
}

/// Display strings for the last-pulse stat cells (Fpeak/Bndwth/Dur/Rate),
/// used by the stats row. All four describe the most
/// recent pulse (or, for Rate, the window around it), so once nothing has been
/// captured for `staleIDSeconds` — the same threshold that turns the species ID
/// red — they revert to "–" instead of freezing at values from a long-gone pass.
/// The Pulses counter is cumulative and deliberately exempt.
private struct PulseStatValues {
    let fpeak: String
    let bandwidth: String
    let duration: String
    let rate: String

    init(_ d: PulseDetector, now: Date) {
        let stale = d.lastDetectionDate
            .map { now.timeIntervalSince($0) > staleIDSeconds } ?? true
        fpeak = !stale && d.capturedPeakFreq > 0
            ? String(format: "%.0f", d.capturedPeakFreq / 1000) : "–"
        let bw = d.capturedFreqMax - d.capturedFreqMin
        bandwidth = !stale && bw > 0 ? String(format: "%.0f", bw / 1000) : "–"
        duration = !stale && d.capturedDurationMs > 0
            ? String(format: "%.0f", d.capturedDurationMs) : "–"
        rate = !stale && d.pulseRateHz > 0
            ? String(format: "%.1f", d.pulseRateHz) : "–"
    }
}

/// An ID/capture older than this is stale: the species cell turns red, the
/// last-pulse stat cells clear, and species-feed rows dim (SpeciesFeedView) —
/// it's from a previous pass, not whatever is flying now. Shared (not private)
/// so every surface ages IDs out on the same clock.
let staleIDSeconds: TimeInterval = 30
