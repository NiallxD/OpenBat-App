//
//  INatPassSegmentTests.swift
//  OpenBatTests
//
//  The segment is the one thing every iNaturalist attachment is made from —
//  the sound that goes up, the sound people play, and the span every exported
//  spectrogram measures. If it is cut in the wrong place, a picture is of audio
//  nobody was sent, which is exactly what an identifier reported in September
//  2026 and the reason this file exists.
//

import Testing
import Foundation
@testable import OpenBat

struct INatPassSegmentTests {

    private static let rate = 48_000.0
    private static let seconds = 10.0

    /// A silent canonical WAV of a known length. The content does not matter:
    /// `passSegment` cuts by the map and the pulse list it is handed, never by
    /// hunting for energy in the samples.
    private func makeWav() -> URL {
        TestWavFactory.make(sampleRate: UInt32(Self.rate), seconds: Self.seconds,
                            toneFrequency: 1_000, amplitude: 0)
    }

    /// One kept region, in samples.
    private func map(from: Double, to: Double) -> SilenceMap {
        let total = Int(Self.seconds * Self.rate)
        let start = Int(from * Self.rate), end = Int(to * Self.rate)
        return SilenceMap(segments: [.init(realStart: start, realEnd: end, virtualStart: 0)],
                          virtualTotal: end - start, realTotal: total)
    }

    private func pulse(at seconds: Double, from start: Date, durationMs: Double = 8) -> PulseRecord {
        PulseRecord(id: UUID(), date: start.addingTimeInterval(seconds), species: "MYLU",
                    confidence: 0.9, peakFreqHz: 45_000, durationMs: durationMs,
                    topScores: [ScoreEntry(species: "MYLU", score: 0.9)])
    }

    /// A generous budget: everything under test fits, so nothing is shrunk.
    private var wholeFileBudget: Int { Int(Self.seconds * Self.rate) * 2 + 44 }

    private func seconds(_ segment: INatExport.PassSegment, _ sample: Int) -> Double {
        Double(sample) / segment.sampleRate
    }

    // MARK: The cut

    /// The recorder keeps up to five seconds of pre-roll and runs on past the
    /// last call. None of it belongs in an observation, and before 2026-09-06
    /// the first exported spectrogram tile was made of it.
    @Test func preRollAndPostRollAreCutAway() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: start, pulses: [],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: wholeFileBudget, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        #expect(!segment.isWholeRecording)
        // One second of margin either side of the sound, which is what
        // `preferredPaddingSeconds` asks for and this budget can afford.
        #expect(abs(seconds(segment, segment.range.lowerBound) - 4.0) < 0.01)
        #expect(abs(segment.seconds - 3.0) < 0.02)
    }

    /// The span is the UNION of what the app heard and what the classifier
    /// kept. A call the model skipped is still a call, and cutting it off the
    /// front of the upload was the "we are trimming too much" complaint.
    @Test func callsOutsideTheSilenceMapStillWidenTheSpan() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: start,
            pulses: [pulse(at: 3.0, from: start), pulse(at: 7.0, from: start)],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: wholeFileBudget, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        // 3.0 to 7.008, plus a second either side.
        #expect(abs(seconds(segment, segment.range.lowerBound) - 2.0) < 0.01)
        #expect(abs(seconds(segment, segment.range.upperBound) - 8.01) < 0.02)
    }

    /// The margin is what the size limit can afford, and it is the first thing
    /// to go — never a call. Budgeted at 1.5 seconds against a 1-second pass,
    /// there is a quarter of a second of room each side.
    @Test func paddingShrinksToFitTheBudget() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: Date(), pulses: [],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: Int(1.5 * Self.rate) * 2 + 44, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        #expect(abs(segment.seconds - 1.5) < 0.02)
        #expect(abs(seconds(segment, segment.range.lowerBound) - 4.75) < 0.01)
    }

    /// A budget too small even for the calls keeps the calls. The recording is
    /// then over iNaturalist's limit and `INatUploadAssessment` blocks it —
    /// which is a better answer than an attachment with half a pass in it.
    @Test func aBudgetBelowTheCallsKeepsTheCalls() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: Date(), pulses: [],
            silence: map(from: 4.0, to: 7.0),
            byteBudget: Int(0.5 * Self.rate) * 2 + 44, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        // The three seconds of sound, plus the floor margin — never less.
        #expect(segment.seconds >= 3.0)
        #expect(abs(segment.seconds - (3.0 + 2 * INatExport.minimumPaddingSeconds)) < 0.02)
    }

    /// Pulse timestamps come from a different clock to the file's own length,
    /// and a bad one can point past the end of it. Forming the range that
    /// implies would trap, which is a crash on a screen the user opened to post
    /// a perfectly ordinary recording.
    @Test func aPulseTimestampPastTheEndOfTheFileDoesNotTrap() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: start,
            pulses: [pulse(at: 900.0, from: start)],
            silence: nil, byteBudget: wholeFileBudget, baseName: "test"))
        defer { if !segment.isWholeRecording { try? FileManager.default.removeItem(at: segment.url) } }

        #expect(segment.range.lowerBound >= 0)
        #expect(segment.range.upperBound <= Int(Self.seconds * Self.rate))
    }

    /// A pass that fills its recording has nothing to gain from a copy of it,
    /// and copying tens of megabytes to save five per cent is work for nothing.
    @Test func aPassFillingTheRecordingIsNotCopied() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: Date(), pulses: [],
            silence: map(from: 0.2, to: 9.8),
            byteBudget: wholeFileBudget, baseName: "test"))

        #expect(segment.isWholeRecording)
        #expect(segment.range.lowerBound == 0)
    }

    // MARK: What lands on disk

    /// The written file has to be the canonical layout every other reader in
    /// the app assumes, and its header has to state the length it really holds
    /// — a header that overstates plays as a truncated call.
    @Test func theSegmentFileIsCanonicalAndDeclaresItsOwnLength() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: Date(), pulses: [],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: wholeFileBudget, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        let format = try #require(WavHeader.describe(url: segment.url))
        #expect(format.isCanonical)
        #expect(format.sampleRate == UInt32(Self.rate))
        #expect(Int(format.dataBytes) == segment.range.count * 2)

        let onDisk = try #require((try? FileManager.default
            .attributesOfItem(atPath: segment.url.path)[.size] as? Int) ?? nil)
        #expect(onDisk == Int(format.dataBytes) + 44)
    }

    /// Pulse timestamps are turned into offsets into whatever file they are
    /// measured against, so a segment has to be able to say when its own first
    /// sample was recorded. Getting this wrong puts the close-up picture on
    /// the wrong call — or on an echo.
    @Test func theSegmentReportsItsOwnStartInstant() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }
        let start = Date()

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: start, pulses: [],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: wholeFileBudget, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        #expect(abs(segment.start(from: start).timeIntervalSince(start) - 4.0) < 0.01)
    }

    /// The map handed to the packer and the picture is the segment's own, so
    /// the seams inside it are where the sound is — not where it was in the
    /// recording this was cut from.
    @Test func theSegmentCarriesItsOwnSilenceMap() throws {
        let url = makeWav()
        defer { try? FileManager.default.removeItem(at: url) }

        let segment = try #require(INatExport.passSegment(
            wavURL: url, recordingStart: Date(), pulses: [],
            silence: map(from: 5.0, to: 6.0),
            byteBudget: wholeFileBudget, baseName: "test"))
        defer { try? FileManager.default.removeItem(at: segment.url) }

        let kept = try #require(segment.silence.soundSpan)
        #expect(abs(seconds(segment, kept.lowerBound) - 1.0) < 0.01)
        #expect(abs(seconds(segment, kept.upperBound) - 2.0) < 0.01)
    }
}

// MARK: - Tiling

struct INatTileSpanTests {

    /// Every frame covers the same duration, so a call's width means the same
    /// thing in every picture. The last one runs out of recording part way
    /// across and the rest of its frame is drawn black.
    @MainActor
    @Test func everyFrameIsTheSameDurationAndTheLastRunsOut() {
        let spans = INatImages.spans(count: 3, totalSeconds: 5.57)
        #expect(spans.count == 3)
        for span in spans {
            #expect(abs((span.to - span.from) - INatImages.tileSeconds) < 1e-9)
        }
        #expect(spans[0].audioEnd == spans[0].to)
        #expect(spans[1].audioEnd == spans[1].to)
        // The frame runs to 6 s; the recording stops at 5.57.
        #expect(abs(spans[2].from - 4.0) < 1e-9)
        #expect(abs(spans[2].to - 6.0) < 1e-9)
        #expect(abs(spans[2].audioEnd - 5.57) < 1e-9)
    }

    /// A pass that divides exactly has no black in it anywhere.
    @MainActor
    @Test func anExactMultipleLeavesNoEmptyFrame() {
        let spans = INatImages.spans(count: 3, totalSeconds: 6.0)
        #expect(spans.count == 3)
        #expect(spans.allSatisfy { $0.audioEnd == $0.to })
    }

    /// A pass longer than the tiles cover is truncated, not compressed — so the
    /// last frame is a full one from the middle of the recording, with no black.
    @MainActor
    @Test func aTruncatedPassEndsOnAFullFrame() {
        let spans = INatImages.spans(count: INatImages.maxTiles, totalSeconds: 60)
        #expect(spans.count == INatImages.maxTiles)
        #expect(spans.allSatisfy { $0.audioEnd == $0.to })
        #expect(abs(spans.last!.to - Double(INatImages.maxTiles) * INatImages.tileSeconds) < 1e-9)
    }
}
