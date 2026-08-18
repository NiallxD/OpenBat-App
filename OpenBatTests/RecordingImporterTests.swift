//
//  RecordingImporterTests.swift
//  OpenBatTests
//
//  Imported files used to be byte-copied and renamed `.wav`, then read by four
//  separate readers that all assume PCM starts at byte 44, 16-bit, mono. Anything
//  else — a `LIST` chunk, stereo, 24-bit, float, AIFF — was read at the wrong
//  offset in the wrong format and shown as a noise spectrogram that played as
//  static, with NO error. Those were precisely the files the importer exists for.
//
//  `normalizeIfNeeded` now converts on the way in. The two properties worth
//  guarding are opposites, and both are easy to break:
//
//    * anything non-canonical must come out canonical AND still be the same audio;
//    * anything already canonical must be left byte-for-byte alone, because that
//      is what preserves the `guan` chunk on a re-imported OpenBat export.
//

import AVFoundation
import Foundation
import Testing
@testable import OpenBat

struct RecordingImporterTests {

    private let sampleRate = 48_000.0
    private let frames = 4_800

    // MARK: Builders

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(le32(UInt32(body.count)))
        d.append(body)
        if body.count % 2 == 1 { d.append(0) }
        return d
    }

    private func fmtChunk(channels: UInt16, bits: UInt16, tag: UInt16) -> Data {
        var body = Data()
        body.append(le16(tag))
        body.append(le16(channels))
        body.append(le32(UInt32(sampleRate)))
        body.append(le32(UInt32(sampleRate) * UInt32(channels) * UInt32(bits / 8)))
        body.append(le16(channels * (bits / 8)))
        body.append(le16(bits))
        return chunk("fmt ", body)
    }

    private func assemble(_ chunks: [Data], name: String = "import-test") throws -> URL {
        var body = Data("WAVE".utf8)
        for c in chunks { body.append(c) }
        var file = Data("RIFF".utf8)
        file.append(le32(UInt32(body.count)))
        file.append(body)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        try file.write(to: url)
        return url
    }

    /// A tone whose samples are known exactly, so the converted file can be checked
    /// against the audio that went in rather than merely "parses and isn't empty".
    private func tone(at i: Int, channel: Int = 0) -> Float {
        let t = Double(i) / sampleRate
        return Float(sin(2 * .pi * 1_000 * t) * 0.5) + Float(channel) * 0.0
    }

    private func monoPCM16() -> Data {
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = Int16(tone(at: i) * 32_767) }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func readSamples(_ url: URL) throws -> [Int16] {
        let f = try #require(WavHeader.describe(url: url))
        let raw = try Data(contentsOf: url)
        let start = Int(f.dataOffset)
        let count = Int(f.dataBytes) / 2
        var out = [Int16](repeating: 0, count: count)
        _ = out.withUnsafeMutableBytes { dst in
            raw.copyBytes(to: dst, from: start..<(start + count * 2))
        }
        return out
    }

    // MARK: Tests

    /// The headline case: a file whose audio does not start at byte 44 must end up
    /// with audio that does, carrying the same samples.
    @Test func listChunkFileIsConvertedToCanonicalWithItsAudioIntact() throws {
        let info = Data("INFOISFT".utf8) + Data("Audacity\0".utf8)
        let url = try assemble([fmtChunk(channels: 1, bits: 16, tag: 1),
                                chunk("LIST", info),
                                chunk("data", monoPCM16())])
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try #require(WavHeader.describe(url: url))
        #expect(!before.isCanonical, "test setup: this file should not start canonical")

        try RecordingImporter.normalizeIfNeeded(at: url)

        let after = try #require(WavHeader.describe(url: url))
        #expect(after.isCanonical)
        #expect(after.sampleRate == UInt32(sampleRate), "conversion must not change the rate")

        // Same audio, not just the same length. Tolerance covers the float
        // round-trip through AVAudioFile's processing format.
        let samples = try readSamples(url)
        #expect(samples.count == frames)
        for i in stride(from: 0, to: frames, by: 37) {
            let want = Int(tone(at: i) * 32_767)
            #expect(abs(Int(samples[i]) - want) <= 8, "sample \(i) changed during conversion")
        }
    }

    /// Dropping a channel would throw away half of a two-mic recording, so the
    /// downmix averages. A stereo file with one channel inverted must therefore
    /// come out near silent — which no "take the left channel" implementation does.
    @Test func stereoIsDownmixedByAveragingNotByDroppingAChannel() throws {
        var interleaved = [Int16](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let v = Int16(tone(at: i) * 32_767)
            interleaved[i * 2] = v
            interleaved[i * 2 + 1] = -v          // exactly out of phase
        }
        let pcm = interleaved.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = try assemble([fmtChunk(channels: 2, bits: 16, tag: 1), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        try RecordingImporter.normalizeIfNeeded(at: url)

        let after = try #require(WavHeader.describe(url: url))
        #expect(after.isCanonical)
        #expect(after.channels == 1)

        let samples = try readSamples(url)
        #expect(samples.count == frames, "frame count must survive the downmix")
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect(peak < 200, "channels were not averaged — peak \(peak) suggests one was taken whole")
    }

    /// A float WAV is not guaranteed to sit inside [-1, 1], and `vDSP_vfix16` wraps
    /// rather than saturates — so an out-of-range sample would become full-scale
    /// noise of the OPPOSITE sign. Clipping before scaling is what prevents that.
    @Test func outOfRangeFloatSamplesClipRatherThanWrap() throws {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = i % 2 == 0 ? 3.5 : -3.5 }   // way past full scale
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = try assemble([fmtChunk(channels: 1, bits: 32, tag: 3), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        try RecordingImporter.normalizeIfNeeded(at: url)

        let out = try readSamples(url)
        #expect(out.count == frames)
        // Every sample should be pinned at (or just inside) the rail it was pushed
        // past, and crucially should keep its sign.
        for i in stride(from: 0, to: frames, by: 41) {
            let expectedSign = i % 2 == 0 ? 1 : -1
            #expect(out[i].signum() == Int16(expectedSign) || out[i] == 0,
                    "sample \(i) flipped sign — wrapped instead of clipping")
            #expect(abs(Int(out[i])) > 30_000, "sample \(i) should be at full scale")
        }
    }

    /// The other half of the contract. A file already in the app's own shape must
    /// not be rewritten at all — rewriting drops the trailing `guan` chunk, and
    /// with it the species, confidence, date and position that make a re-imported
    /// export round-trip instead of arriving as a dateless NoID.
    @Test func alreadyCanonicalFileIsLeftByteForByteAlone() throws {
        let guano = Data("GUANO|Version: 1.0\nSpecies Manual ID: PIPPIP\n".utf8)
        let url = try assemble([fmtChunk(channels: 1, bits: 16, tag: 1),
                                chunk("data", monoPCM16()),
                                chunk("guan", guano)])
        defer { try? FileManager.default.removeItem(at: url) }

        let before = try Data(contentsOf: url)
        try RecordingImporter.normalizeIfNeeded(at: url)
        let after = try Data(contentsOf: url)

        #expect(before == after, "a canonical file was rewritten — its GUANO chunk is now lost")
    }

    /// Conversion must be idempotent: importing the output of a conversion again
    /// should be a no-op, not a second lossy pass.
    @Test func convertingTwiceChangesNothingTheSecondTime() throws {
        let url = try assemble([fmtChunk(channels: 2, bits: 16, tag: 1),
                                chunk("data", Data(repeating: 0x20, count: frames * 4))])
        defer { try? FileManager.default.removeItem(at: url) }

        try RecordingImporter.normalizeIfNeeded(at: url)
        let once = try Data(contentsOf: url)
        try RecordingImporter.normalizeIfNeeded(at: url)
        let twice = try Data(contentsOf: url)

        #expect(once == twice)
    }

    /// A file that cannot be read as audio must fail loudly here, so the caller can
    /// drop it — the whole point of converting on import is that failure surfaces
    /// at import time instead of as noise downstream.
    @Test func unreadableFileThrowsRatherThanSilentlySucceeding() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("garbage-\(UUID().uuidString).wav")
        try Data(repeating: 0xAB, count: 4_096).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: (any Error).self) {
            try RecordingImporter.normalizeIfNeeded(at: url)
        }
    }
}
