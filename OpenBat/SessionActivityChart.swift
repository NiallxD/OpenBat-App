//
//  SessionActivityChart.swift
//  OpenBat
//
//  When the bats were about, across one session — a bar per time bucket, time on
//  the x axis (Niall, 2026-08-16).
//
//  It answers a different question from the species summary sitting above it in
//  SessionDetailView. That one is "what was out"; this is "when". Both matter in
//  the field and neither substitutes for the other: a hundred IDs spread evenly
//  over four hours and the same hundred in one twenty-minute burst are the same
//  species chart and completely different nights.
//
//  Built by hand from `Capsule`s rather than with Swift Charts, to match the
//  chart language already in the app (`SessionSpeciesSummary`, `ScoreBar`,
//  PulseStatsViews). Swift Charts would give axes for free, but the app has one
//  visual idiom for a bar today and two would be worse than the axes are good.
//
//  One series, so no legend and no palette question: the bars are the app accent
//  and the title says what they count. NOISE and NoID passes are excluded, the
//  same filter `SessionSpeciesSummary` applies — they are triggers, not detections,
//  and counting them here would put a spike on the chart wherever the wind got up.
//

import SwiftUI

// MARK: - Section header with explainer

/// A chart section's title with an "i" beside it, opening a popover that says what
/// the chart under it actually shows (Niall, 2026-08-16).
///
/// Its own View struct, holding its own presentation state, so the popover anchors
/// to the button that opened it. Hoisting the state into `SessionDetailView` and
/// presenting from there — the first shape this took — anchors the popover to the
/// whole List instead, which points the arrow at the middle of the screen.
///
/// Both charts need one, and so does the map — none of the three is self-evident,
/// and all of them count *detections* rather than individual bats, which is the most
/// misreadable thing on the screen: nothing in a chart says so, and the honest answer
/// needs a paragraph, not a longer axis label. The map's explainer is also where the
/// pin thresholds are stated, now that the caption under the map is gone.
struct SessionChartHeader: View {
    let title: String
    let kind: Kind

    enum Kind { case map, species, timeline }

    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("About \(title.lowercased())")
            .popover(isPresented: $showInfo) {
                explainer.presentationCompactAdaptation(.popover)
            }
            Spacer()
        }
    }

    @ViewBuilder private var explainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch kind {
            case .map:
                Text("Map & species").font(.subheadline.weight(.semibold))
                Text("Every detection from this session that had a location fix and cleared the map's quality gates, pinned where it was recorded.")
                    .font(.caption)
                Text("Those gates are a minimum confidence and a minimum number of pulses, both set in AutoID settings — the map shows the best of the best, so it will usually hold fewer pins than the session holds IDs. A detection recorded without a location never appears.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The list beside the map counts detections per species across the whole session, pinned or not. A detection is one bat pass, **not** one bat. Noise and unclassified triggers are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .species:
                Text("Species detected").font(.subheadline.weight(.semibold))
                Text("One bar per species, as long as the number of separate detections logged for it during this session.")
                    .font(.caption)
                Text("A detection is one bat pass — a run of calls close enough together to be treated as a single animal going by. It is **not** a count of individual bats: one bat circling a pond can be logged many times over, and two bats overhead at once may be logged as one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Triggers that never resolved to a species, and anything the model called noise, are left out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .timeline:
                Text("Detections over time").font(.subheadline.weight(.semibold))
                Text("The same detections placed on the clock, so you can see when the activity happened rather than only how much of it there was.")
                    .font(.caption)
                Text("One busy stretch and a steady trickle add up to an identical species chart and mean very different nights. Bats are usually busiest in the couple of hours after sunset, so a peak early in an evening session is the ordinary shape.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 290, alignment: .leading)
    }
}

// MARK: - Bucketing (pure)

/// Splits a session's detections into time buckets. Separate from the view and
/// free of any `View` types so `SessionActivityTests` can drive it directly —
/// picking a bucket width is the only part with judgement in it.
enum SessionActivity {

    struct Bucket: Equatable {
        let start: Date
        let count: Int
    }

    /// Bucket widths we are willing to use, in seconds, coarsest last. All of them
    /// divide an hour (or are whole hours), so a bucket edge lands on a round
    /// clock time and the axis labels read as times a person would say.
    static let candidateWidths: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600, 7200, 14400]

    /// Roughly how many bars to aim for. Enough to show shape, few enough that
    /// each one is still wide enough to see on a phone.
    static let targetBucketCount = 18

    /// Buckets covering `start...end`, and the width chosen.
    ///
    /// `nil` when there is nothing to draw — no detections at all. A session with
    /// detections but no measurable span (every ID inside one second, which a
    /// demo-mode run can produce) still returns one bucket rather than nil, so the
    /// chart shows a single bar instead of vanishing.
    /// `timeZone` is a parameter only so the tests can drive a half-hour offset
    /// (see `bucketEdgesAreAlignedInAHalfHourTimeZone`). Callers in the app want
    /// the default: the buckets are labelled on the user's own clock.
    static func buckets(at dates: [Date], from start: Date, to end: Date,
                        timeZone: TimeZone = .current)
        -> (buckets: [Bucket], width: TimeInterval)? {
        guard !dates.isEmpty else { return nil }

        // Trust the detections over the session's own bounds. A session whose
        // endDate is nil (still running) or whose clock disagrees with its own
        // records would otherwise clip bars off the chart entirely.
        let lower = min(start, dates.min()!)
        let upper = max(end, dates.max()!)
        let span = upper.timeIntervalSince(lower)

        let width = candidateWidths.first { span / $0 <= Double(targetBucketCount) }
            ?? candidateWidths.last!

        // Anchored to a whole multiple of the width, so edges land on round clock
        // times rather than on whenever the session happened to start.
        //
        // **Measured in local time, not epoch time.** Epoch multiples are round
        // in UTC, which is only the same thing where the offset is a whole number
        // of hours. In India (+5:30) or Newfoundland (−3:30) an hourly bucket
        // anchored to the epoch starts at half past, so every label on the axis
        // read :30 — the one property this anchoring exists to provide. Shifting
        // by the offset before rounding and back after puts the edges on the
        // clock the user is actually reading.
        let offset = Double(timeZone.secondsFromGMT(for: lower))
        let originEpoch = ((lower.timeIntervalSince1970 + offset) / width).rounded(.down)
            * width - offset
        let origin = Date(timeIntervalSince1970: originEpoch)
        let count = max(1, Int(((upper.timeIntervalSince(origin)) / width).rounded(.down)) + 1)

        var counts = [Int](repeating: 0, count: count)
        for date in dates {
            let index = Int(date.timeIntervalSince(origin) / width)
            // Clamped rather than skipped: floating-point division at the exact
            // upper edge can land one past the end, and dropping a real detection
            // to rounding would be worse than putting it in the last bucket.
            counts[min(max(index, 0), count - 1)] += 1
        }

        return (counts.enumerated().map { index, count in
            Bucket(start: origin.addingTimeInterval(Double(index) * width), count: count)
        }, width)
    }

    /// "5 min", "2 h" — for the caption naming what one bar is worth.
    static func widthLabel(_ width: TimeInterval) -> String {
        let minutes = Int(width / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        return hours == 1 ? "1 h" : "\(hours) h"
    }
}

// MARK: - Chart

struct SessionActivityChart: View {
    let passes: [PassRecord]
    let start: Date
    let end: Date

    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; return f
    }()

    private static let plotHeight: CGFloat = 96

    /// Same exclusion as `SessionSpeciesSummary` — see the file header.
    private var detectionDates: [Date] {
        passes.filter { !$0.isNoise && !$0.isNoID }.map(\.date)
    }

    var body: some View {
        if let result = SessionActivity.buckets(at: detectionDates, from: start, to: end) {
            let peak = max(result.buckets.map(\.count).max() ?? 1, 1)
            VStack(alignment: .leading, spacing: 6) {
                plot(result.buckets, peak: peak)
                axis(result.buckets)
                caption(result, peak: peak)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilityLabel(result, peak: peak))
        }
    }

    private func plot(_ buckets: [SessionActivity.Bucket], peak: Int) -> some View {
        // A shared 2pt gap between bars, and bars that grow from a common
        // baseline. `.bottom` alignment is what makes the row a bar chart rather
        // than a set of centred lozenges.
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, bucket in
                bar(bucket, peak: peak)
            }
        }
        .frame(height: Self.plotHeight)
        // A recessive baseline, so an empty stretch of the night still reads as
        // part of the chart rather than as missing data.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.quaternary)
                .frame(height: 1)
        }
    }

    private func bar(_ bucket: SessionActivity.Bucket, peak: Int) -> some View {
        // Rounded top, square bottom: the data end is rounded and the baseline end
        // is anchored flat to it. A fully rounded capsule would lift short bars
        // off the axis and make one detection look like none.
        UnevenRoundedRectangle(cornerRadii: .init(topLeading: 3, bottomLeading: 0,
                                                 bottomTrailing: 0, topTrailing: 3))
            .fill(bucket.count == 0 ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.batAccent))
            .frame(maxWidth: .infinity)
            // An empty bucket keeps a 2pt stub so the timeline stays continuous —
            // a gap you can see is the point, but a gap you can't distinguish from
            // the chart's own padding is not.
            .frame(height: bucket.count == 0
                   ? 2
                   : max(3, Self.plotHeight * CGFloat(bucket.count) / CGFloat(peak)))
    }

    /// First and last bucket only. Labelling every bar is the anti-pattern here —
    /// on a phone they would collide long before they were useful, and the two ends
    /// plus the "one bar = N min" caption are enough to place anything in between.
    private func axis(_ buckets: [SessionActivity.Bucket]) -> some View {
        HStack {
            Text(Self.clock.string(from: buckets.first?.start ?? start))
            Spacer()
            Text(Self.clock.string(from: buckets.last?.start ?? end))
        }
        .font(.system(size: 9).monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// Names the bar width and calls out the busiest bucket — one direct label
    /// rather than a number on every bar.
    private func caption(_ result: (buckets: [SessionActivity.Bucket], width: TimeInterval),
                         peak: Int) -> some View {
        let busiest = result.buckets.first { $0.count == peak }
        return Text(busiest.map { bucket in
            "Each bar = \(SessionActivity.widthLabel(result.width)) · busiest around \(Self.clock.string(from: bucket.start)) (\(peak) ID\(peak == 1 ? "" : "s"))"
        } ?? "Each bar = \(SessionActivity.widthLabel(result.width))")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// VoiceOver gets the shape as a sentence — a row of 18 unlabelled bars is
    /// nothing to it otherwise.
    private static func accessibilityLabel(
        _ result: (buckets: [SessionActivity.Bucket], width: TimeInterval), peak: Int) -> String {
        let total = result.buckets.reduce(0) { $0 + $1.count }
        let busiest = result.buckets.first { $0.count == peak }
        var out = "Detections over time. \(total) ID\(total == 1 ? "" : "s") in \(SessionActivity.widthLabel(result.width)) steps"
        if let busiest {
            out += ", busiest around \(clock.string(from: busiest.start)) with \(peak)"
        }
        return out + "."
    }
}
