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

/// Last-ID readout, tappable to open the identified species' field-guide page.
///
/// The Button and its sheet sit OUTSIDE `SpeciesStatCellContent` on purpose —
/// same reasoning as `MicStatusPill` in LiveStatusViews: the readout itself
/// re-evaluates on a 1 Hz `TimelineView` (and on every pass), and a presenter
/// rebuilding underneath its own sheet can drop the tap that opened it. Nothing
/// in *this* body reads churning state; the guide lookup happens in the action
/// closure, at tap time, which is not a body dependency.
///
/// A tap with no guide page behind it does nothing, deliberately: guide coverage
/// is far thinner than what the models can name, and the content view only shows
/// the tap affordance when a page actually exists, so there's nothing to
/// contradict. See `SpeciesGuide.species(forCode:)`.
private struct SpeciesStatCell: View {
    let pulseDetector: PulseDetector
    let guide: SpeciesGuideStore
    let rangeStore: SpeciesRangeStore
    /// Forces a stand-in ID into the cell for the guided tour's species step —
    /// the tour is normally taken before detection has ever run, so the cell
    /// would otherwise read "–" while the card talks about tapping it. Same
    /// treatment as `SessionTimerPill`/`MicStatusPill` et al.
    var tourDemo: Bool = false
    @State private var profile: GuideSpecies?

    var body: some View {
        Button {
            guard let code = pulseDetector.lastPassResult?.species,
                  let match = guide.guide.species(forCode: code) else { return }
            profile = match
        } label: {
            SpeciesStatCellContent(pulseDetector: pulseDetector, guide: guide, tourDemo: tourDemo)
        }
        .buttonStyle(.plain)
        .sheet(item: $profile) { species in
            SpeciesProfileSheet(species: species, store: guide, rangeStore: rangeStore)
        }
        .tourTarget(.speciesID)
    }
}

/// The readout proper, with a stale-after-30s red tint. `TimelineView`
/// re-evaluates once a second so the ID turns red as it ages without needing a
/// pulse (or any other state change) to trigger a redraw — already
/// self-contained (the `pulseDetector.lastPassResult`/`lastPassDate` reads
/// happen inside the `TimelineView` content closure, not synchronously during
/// the parent's body).
private struct SpeciesStatCellContent: View {
    let pulseDetector: PulseDetector
    let guide: SpeciesGuideStore
    var tourDemo: Bool = false

    /// The tour's stand-in ID. Deliberately a species the bundled guide has a
    /// page for, so the book affordance the tour card describes is really
    /// showing — not a mocked-up glyph that wouldn't appear for this code in
    /// normal use.
    private static let demoCode = "MYLU"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let isStale = pulseDetector.lastPassDate
                .map { context.date.timeIntervalSince($0) > staleIDSeconds } ?? false
            VStack(spacing: 2) {
                Text("SPECIES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                if let pass = pulseDetector.lastPassResult {
                    idRow(code: pass.species,
                          pulses: pulseDetector.lastPassPulseCount,
                          confidence: Double(pass.confidence),
                          isStale: isStale)
                } else if tourDemo {
                    idRow(code: Self.demoCode, pulses: 8, confidence: 0.92, isStale: false)
                } else {
                    Text("–")
                        .font(.title3.weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            // The whole cell, including the padding around the text, is the tap
            // target — a 15 pt species code is too small to hit reliably in the
            // dark, which is when this app is used.
            .contentShape(Rectangle())
            .accessibilityHint(pulseDetector.lastPassResult
                .flatMap { guide.guide.species(forCode: $0.species) } != nil
                ? "Tap to open the field guide page" : "")
        }
    }

    /// Code + pulse count + confidence, plus the guide affordance when the code
    /// has a page behind it. Shared by the live readout and the tour stand-in so
    /// the two can't drift apart visually.
    private func idRow(code: String, pulses: Int, confidence: Double, isStale: Bool) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(code)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isStale ? .red : .primary)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(pulses)p")
                Text(String(format: "%.0f%%", confidence * 100))
            }
            .font(.system(size: 8))
            .foregroundStyle(.secondary)
            // The only cue that the cell is tappable, shown just for the species
            // that actually have a guide page. Small and tertiary on purpose:
            // this is a live readout first, and the numbers next to it are what
            // the cell is for.
            if guide.guide.species(forCode: code) != nil {
                Image(systemName: "book.closed")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
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
    /// Only used to resolve the identified species code to a guide page for
    /// `SpeciesStatCell` — held as a reference and never read in this body, so
    /// it adds no invalidation of its own.
    let guide: SpeciesGuideStore
    let rangeStore: SpeciesRangeStore
    /// Passed straight through to `SpeciesStatCell` — see its own doc comment.
    var tourDemo: Bool = false

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
                SpeciesStatCell(pulseDetector: pulseDetector, guide: guide,
                                rangeStore: rangeStore, tourDemo: tourDemo)
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
    /// See `PulseStatsRow`.
    let guide: SpeciesGuideStore
    let rangeStore: SpeciesRangeStore
    var tourDemo: Bool = false

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
                SpeciesStatCell(pulseDetector: pulseDetector, guide: guide,
                                rangeStore: rangeStore, tourDemo: tourDemo)
                    .frame(maxHeight: .infinity)
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
