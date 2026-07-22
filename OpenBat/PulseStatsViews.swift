//
//  PulseStatsViews.swift
//  OpenBat
//
//  The last-pulse stat readouts (Fpeak/Bndwth/Dur/Rate/Pulses/Species) as
//  standalone leaf views — extracted from ContentView once it passed 1900
//  lines. Being leaf views is also load-bearing: `pulseDetector`'s stat
//  properties update on essentially every detected pulse, and reading them
//  inline in ContentView.body invalidated (and froze the hit-testing of) the
//  whole screen — see the @Observable-churn note in CLAUDE.md.
//

import SwiftUI

/// One labelled stat readout (title, big value, small unit) — a leaf View so it
/// carries no dependencies of its own; used by `PulseStatsRow`/`PulseStatsColumn`
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

/// Last-ID readout with a stale-after-30s red tint. `TimelineView` re-evaluates
/// once a second so the ID turns red as it ages without needing a pulse (or any
/// other state change) to trigger a redraw — already self-contained (the
/// `pulseDetector.lastPassResult`/`lastPassDate` reads happen inside the
/// `TimelineView` content closure, not synchronously during the parent's body).
private struct SpeciesStatCell: View {
    let pulseDetector: PulseDetector

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isStale = pulseDetector.lastPassDate
                .map { context.date.timeIntervalSince($0) > staleIDSeconds } ?? false
            VStack(spacing: 2) {
                Text("SPECIES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let pass = pulseDetector.lastPassResult {
                    HStack(alignment: .center, spacing: 4) {
                        Text(pass.species)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isStale ? .red : .primary)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(pulseDetector.lastPassPulseCount)p")
                            Text(String(format: "%.0f%%", pass.confidence * 100))
                        }
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("–")
                        .font(.title3.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        }
    }
}

/// Horizontal stat row for portrait. A standalone View struct: `pulseDetector`'s
/// `pulseCount`/`pulseRateHz`/`capturedPeakFreq`/`capturedDurationMs`/
/// `capturedFreqMin`/`capturedFreqMax` update on essentially every detected pulse
/// (sometimes many times a second during an active pass) — reading them inline in
/// ContentView.body invalidated (and froze the hit-testing of) the whole screen,
/// the same failure mode the amplitude meter had before it was scoped down.
struct PulseStatsRow: View {
    let pulseDetector: PulseDetector

    var body: some View {
        // 1 Hz TimelineView so the last-pulse stats age out on their own —
        // without it they'd freeze at their final values until the next pulse.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let values = PulseStatValues(pulseDetector, now: context.date)
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
                statDivider
                SpeciesStatCell(pulseDetector: pulseDetector)
            }
        }
    }

    private var statDivider: some View {
        Divider().frame(height: 28)
    }
}

/// Vertical stat column for the landscape sidebar. Same scoping rationale as
/// `PulseStatsRow`.
struct PulseStatsColumn: View {
    let pulseDetector: PulseDetector

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let values = PulseStatValues(pulseDetector, now: context.date)
            VStack(spacing: 0) {
                StatCell(title: "Fpeak", value: values.fpeak, unit: "kHz").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Bndwth", value: values.bandwidth, unit: "kHz").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Dur", value: values.duration, unit: "ms").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Rate", value: values.rate, unit: "/s").frame(maxHeight: .infinity)
                Divider()
                StatCell(title: "Pulses", value: "\(pulseDetector.pulseCount)", unit: "").frame(maxHeight: .infinity)
                Divider()
                SpeciesStatCell(pulseDetector: pulseDetector).frame(maxHeight: .infinity)
            }
        }
    }
}

/// Display strings for the last-pulse stat cells (Fpeak/Bndwth/Dur/Rate),
/// shared by the portrait row and landscape column. All four describe the most
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
