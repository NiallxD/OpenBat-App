//
//  WavHeaderTests.swift
//  OpenBatTests
//
//  `WavHeader` used to read the sample rate and data size from fixed byte offsets
//  (24 and 40), correct only for the canonical 44-byte header AudioRecorder
//  writes. Four other readers still assume that layout, so `describe` is what the
//  importer uses to decide whether a file HAS it — get this wrong and a file is
//  either converted when it shouldn't be (losing its GUANO chunk) or read at the
//  wrong offset and shown as noise.
//
//  The shapes below are the ones that actually arrive: Audacity, Wildlife
//  Acoustics and Pettersson all commonly write a `LIST`/`INFO` chunk before
//  `data`, and WAVE_FORMAT_EXTENSIBLE is what most 24-bit recorders emit.
//

import Foundation
import Testing
@testable import OpenBat

struct WavHeaderTests {

    // MARK: Builders

    private func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    private func chunk(_ id: String, _ body: Data) -> Data {
        var d = Data(id.utf8)
        d.append(le32(UInt32(body.count)))
        d.append(body)
        // RIFF chunks are word-aligned: an odd body carries a pad byte.
        if body.count % 2 == 1 { d.append(0) }
        return d
    }

    private func fmtChunk(channels: UInt16 = 1, sampleRate: UInt32 = 384_000,
                          bits: UInt16 = 16, tag: UInt16 = 1, extra: Data = Data()) -> Data {
        var body = Data()
        body.append(le16(tag))
        body.append(le16(channels))
        body.append(le32(sampleRate))
        body.append(le32(sampleRate * UInt32(channels) * UInt32(bits / 8)))
        body.append(le16(channels * (bits / 8)))
        body.append(le16(bits))
        body.append(extra)
        return chunk("fmt ", body)
    }

    private func write(_ chunks: [Data], truncatingBy: Int = 0) throws -> URL {
        var body = Data("WAVE".utf8)
        for c in chunks { body.append(c) }
        var file = Data("RIFF".utf8)
        file.append(le32(UInt32(body.count)))
        file.append(body)
        if truncatingBy > 0 { file = file.prefix(file.count - truncatingBy) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavheader-\(UUID().uuidString).wav")
        try file.write(to: url)
        return url
    }

    private var pcm: Data { Data(repeating: 0x11, count: 200) }

    // MARK: Tests

    @Test func canonicalFileIsRecognisedAsCanonical() throws {
        let url = try write([fmtChunk(), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.dataOffset == 44)
        #expect(f.dataBytes == 200)
        #expect(f.sampleRate == 384_000)
        #expect(f.isCanonical)
    }

    /// The case that mattered: a `LIST` chunk pushes the audio past byte 44, and
    /// every reader that assumed 44 read noise. It must not be treated as canonical.
    @Test func listChunkBeforeDataMovesTheOffsetAndIsNotCanonical() throws {
        let info = Data("INFOISFT".utf8) + Data("Audacity\0".utf8)
        let url = try write([fmtChunk(), chunk("LIST", info), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.dataOffset > 44, "LIST chunk should push the audio past byte 44")
        #expect(f.dataBytes == 200)
        #expect(f.sampleRate == 384_000)
        #expect(!f.isCanonical)
    }

    @Test func extensibleFormatIsParsedAndNotCanonical() throws {
        let extra = Data([22, 0]) + Data(repeating: 0, count: 22)
        let url = try write([fmtChunk(tag: 0xFFFE, extra: extra), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.formatTag == 0xFFFE)
        #expect(f.dataOffset == 68, "a 40-byte fmt chunk moves data 24 bytes later")
        #expect(!f.isCanonical)
    }

    @Test func stereoAndWideSamplesAreNotCanonical() throws {
        let stereo = try write([fmtChunk(channels: 2), chunk("data", pcm)])
        let float32 = try write([fmtChunk(bits: 32, tag: 3), chunk("data", pcm)])
        defer {
            try? FileManager.default.removeItem(at: stereo)
            try? FileManager.default.removeItem(at: float32)
        }

        let s = try #require(WavHeader.describe(url: stereo))
        #expect(s.channels == 2)
        #expect(!s.isCanonical)

        let f = try #require(WavHeader.describe(url: float32))
        #expect(f.bitsPerSample == 32)
        #expect(f.formatTag == 3)
        #expect(!f.isCanonical)
    }

    /// An odd-sized chunk carries a pad byte. Miss it and every subsequent chunk
    /// offset is out by one, which finds no `data` at all or finds it misaligned —
    /// and a misaligned 16-bit read is byte-swapped noise, not slightly-off audio.
    @Test func oddSizedChunkPadByteIsSkipped() throws {
        let url = try write([fmtChunk(), chunk("LIST", Data("ABC".utf8)), chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.dataBytes == 200, "pad byte mishandled — data chunk not found intact")
        #expect(f.dataOffset % 2 == 0)
    }

    /// A recording cut short by a crash or an interrupted copy still declares its
    /// intended length. Trusting it sends every reader off the end of the file.
    @Test func truncatedFileClampsToWhatIsActuallyThere() throws {
        let url = try write([fmtChunk(), chunk("data", pcm)], truncatingBy: 50)
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.dataBytes == 150, "declared 200 bytes, only 150 present — must clamp")
    }

    /// An OpenBat export carries a `guan` chunk after the audio. It must still read
    /// as canonical, because that is what stops the importer rewriting the samples
    /// and dropping the metadata that makes a re-import round-trip.
    @Test func guanoChunkAfterDataKeepsTheFileCanonical() throws {
        let url = try write([fmtChunk(), chunk("data", pcm),
                             chunk("guan", Data("GUANO|Version: 1.0\n".utf8))])
        defer { try? FileManager.default.removeItem(at: url) }

        let f = try #require(WavHeader.describe(url: url))
        #expect(f.isCanonical)
        #expect(f.dataBytes == 200, "the guan chunk must not be counted as audio")
    }

    @Test func nonRiffFileIsRejectedRatherThanGuessedAt() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("notawav-\(UUID().uuidString).bin")
        try Data("this is not a wav file, just some bytes".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(WavHeader.describe(url: url) == nil)
    }

    /// `read` is the narrow API most callers use; it must agree with `describe`
    /// rather than keeping its own idea of where the fields are.
    @Test func readAgreesWithDescribeOnAnAwkwardFile() throws {
        let url = try write([fmtChunk(sampleRate: 256_000),
                             chunk("LIST", Data("INFOtest".utf8)),
                             chunk("data", pcm)])
        defer { try? FileManager.default.removeItem(at: url) }

        let described = try #require(WavHeader.describe(url: url))
        let read = try #require(WavHeader.read(url: url))
        #expect(read.sampleRate == described.sampleRate)
        #expect(read.dataBytes == described.dataBytes)
        #expect(read.sampleRate == 256_000)
    }
}
