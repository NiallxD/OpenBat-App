//
//  SessionActivityTests.swift
//  OpenBatTests
//
//  Bucketing for the session activity chart. Worth testing on its own because the
//  chart cannot show that it dropped a detection — a bar one shorter than it should
//  be looks exactly like a correct bar — so "every detection lands in exactly one
//  bucket" is the property to pin down, not the drawing.
//

import Testing
import Foundation
@testable import OpenBat

struct SessionActivityTests {

    private let origin = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    /// Total across all buckets must equal the number of detections handed in, for
    /// every plausible session length — this is the one that catches an off-by-one
    /// at a bucket edge or a dropped final detection.
    @Test(arguments: [60.0, 600.0, 3600.0, 4 * 3600.0, 12 * 3600.0])
    func everyDetectionLandsInExactlyOneBucket(spanSeconds: Double) {
        let end = origin.addingTimeInterval(spanSeconds)
        // Deliberately includes both exact endpoints, which is where a naive
        // `Int(interval / width)` puts a detection one bucket past the end.
        let dates = (0...20).map { origin.addingTimeInterval(spanSeconds * Double($0) / 20) }

        guard let result = SessionActivity.buckets(at: dates, from: origin, to: end) else {
            Issue.record("no buckets for a \(spanSeconds)s session")
            return
        }
        #expect(result.buckets.reduce(0) { $0 + $1.count } == dates.count)
    }

    @Test func noDetectionsMeansNoChart() {
        #expect(SessionActivity.buckets(at: [], from: origin,
                                       to: origin.addingTimeInterval(3600)) == nil)
    }

    /// A session with detections but no measurable span — every ID inside the same
    /// second, which demo mode can produce — still draws, as one bar.
    @Test func zeroSpanStillProducesOneBucket() {
        let dates = [origin, origin, origin]
        guard let result = SessionActivity.buckets(at: dates, from: origin, to: origin) else {
            Issue.record("expected one bucket")
            return
        }
        #expect(result.buckets.count == 1)
        #expect(result.buckets[0].count == 3)
    }

    /// Bar count stays legible at any session length: never more than the target,
    /// and never a single bar for a long night.
    @Test(arguments: [300.0, 1800.0, 3600.0, 6 * 3600.0, 14 * 3600.0])
    func barCountStaysInARangeYouCanRead(spanSeconds: Double) {
        let end = origin.addingTimeInterval(spanSeconds)
        let dates = [origin, end]
        guard let result = SessionActivity.buckets(at: dates, from: origin, to: end) else {
            Issue.record("no buckets")
            return
        }
        // +1 for the partial bucket the anchoring can add at each end.
        #expect(result.buckets.count <= SessionActivity.targetBucketCount + 2)
        #expect(result.buckets.count >= 2)
    }

    /// Detections outside the session's own recorded bounds must still appear. A
    /// running session has `endDate == nil` (the view passes `Date()`), and a
    /// session whose clock disagrees with its records would otherwise silently clip
    /// bars off the chart.
    @Test func detectionsOutsideTheSessionBoundsAreStillCounted() {
        let claimedEnd = origin.addingTimeInterval(600)
        let dates = [origin.addingTimeInterval(-1800),   // before the session "started"
                     origin.addingTimeInterval(300),
                     origin.addingTimeInterval(5400)]    // long after it "ended"

        guard let result = SessionActivity.buckets(at: dates, from: origin, to: claimedEnd) else {
            Issue.record("no buckets")
            return
        }
        #expect(result.buckets.reduce(0) { $0 + $1.count } == 3)
        #expect(result.buckets.first!.start <= dates.first!)
        #expect(result.buckets.last!.start.addingTimeInterval(result.width) > dates.last!)
    }

    /// Buckets are contiguous, ascending, and exactly one width apart — an empty
    /// stretch of the night has to be a zero-count bar, not a missing one, or the
    /// x axis silently compresses and the shape of the night is a lie.
    @Test func bucketsAreContiguousIncludingEmptyStretches() {
        let end = origin.addingTimeInterval(4 * 3600)
        // A gap of hours in the middle with nothing in it.
        let dates = [origin, origin.addingTimeInterval(60),
                     end.addingTimeInterval(-60), end]

        guard let result = SessionActivity.buckets(at: dates, from: origin, to: end) else {
            Issue.record("no buckets")
            return
        }
        for (earlier, later) in zip(result.buckets, result.buckets.dropFirst()) {
            #expect(abs(later.start.timeIntervalSince(earlier.start) - result.width) < 0.001)
        }
        #expect(result.buckets.contains { $0.count == 0 })
    }

    /// Bucket edges land on round clock times rather than on whenever the session
    /// happened to start, so the axis labels read as times a person would say.
    @Test func bucketEdgesAreAlignedToTheChosenWidth() {
        // Start at a deliberately ugly offset — 07:43:17 past the hour.
        let ragged = origin.addingTimeInterval(43 * 60 + 17)
        let end = ragged.addingTimeInterval(3 * 3600)
        guard let result = SessionActivity.buckets(at: [ragged, end], from: ragged, to: end) else {
            Issue.record("no buckets")
            return
        }
        for bucket in result.buckets {
            // Measured in LOCAL time, which is where "a time a person would say"
            // lives. Testing the raw epoch remainder — as this did — passes in
            // London and fails in Delhi, because an epoch multiple is only a
            // round clock time where the UTC offset is a whole number of hours.
            // The assertion was quietly encoding the bug it was meant to catch.
            let offset = Double(TimeZone.current.secondsFromGMT(for: bucket.start))
            let remainder = (bucket.start.timeIntervalSince1970 + offset)
                .truncatingRemainder(dividingBy: result.width)
            #expect(abs(remainder) < 0.001, "bucket at \(bucket.start) is not aligned")
        }
    }

    /// The same property, forced through a half-hour zone — the case that made
    /// the epoch-remainder version of the test above wrong. Kolkata is +5:30, so
    /// nothing here can pass by accident on a machine set to UTC.
    ///
    /// **The span is load-bearing.** It has to be long enough to select an
    /// *hourly* bucket or longer: +5:30 is exactly 11 half-hours, so with a
    /// 30-minute width the old epoch anchoring lands on round local times by
    /// coincidence and this test passes against the bug. 12 hours picks 3600,
    /// where 19 800 s of offset leaves a remainder and the two anchorings
    /// genuinely disagree. Checked by running it against the old code.
    @Test func bucketEdgesAreAlignedInAHalfHourTimeZone() throws {
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let ragged = origin.addingTimeInterval(43 * 60 + 17)
        let end = ragged.addingTimeInterval(12 * 3600)
        let result = try #require(SessionActivity.buckets(at: [ragged, end], from: ragged, to: end,
                                                          timeZone: kolkata))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = kolkata
        for bucket in result.buckets {
            let seconds = calendar.component(.minute, from: bucket.start) * 60
                + calendar.component(.second, from: bucket.start)
            // Every candidate width divides an hour or is a whole number of them,
            // so a correctly aligned edge is always a whole number of bucket
            // widths past a local hour boundary — never a stray :30.
            #expect(Double(seconds).truncatingRemainder(dividingBy: min(result.width, 3600)) < 0.001,
                    "bucket at \(bucket.start) is not on a round local time")
        }
    }

    @Test func widthLabelReadsAsATime() {
        #expect(SessionActivity.widthLabel(60) == "1 min")
        #expect(SessionActivity.widthLabel(900) == "15 min")
        #expect(SessionActivity.widthLabel(3600) == "1 h")
        #expect(SessionActivity.widthLabel(7200) == "2 h")
    }
}
