//
//  INatScrubTests.swift
//  OpenBatTests
//
//  The listening copy attached to an iNaturalist observation is scrubbed —
//  background removed — while the full-spectrum copy is not. Both halves of
//  that are load-bearing: hiss at 16× is what stops people listening to an
//  acoustic observation at all, and a scrubbed full-spectrum file would quietly
//  change every measurement anybody re-analysing it made.
//

import Testing
import Foundation
@testable import OpenBat

struct INatScrubTests {

    private static let rate: UInt32 = 384_000
    private static let seconds = 0.5
    /// Where the one call sits, and how long it lasts.
    private static let callAt = 0.25
    private static let callSeconds = 0.005

    /// A canonical WAV of steady broadband noise with a single tone burst in
    /// the middle — the shape of a bat pass reduced to the two things the
    /// scrub has to tell apart.
    private func makeNoisyCall() -> URL {
        let count = Int(Double(Self.rate) * Self.seconds)
        var pcm = [Int16](repeating: 0, count: count)
        // Deterministic: a test that fails one run in twenty is worse than no
        // test. A plain LCG, seeded the same every time.
        var seed: UInt64 = 0x5EED
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(Int32(truncatingIfNeeded: seed >> 33)) / Double(Int32.max)
        }
        let callStart = Int(Self.callAt * Double(Self.rate))
        let callEnd = callStart + Int(Self.callSeconds * Double(Self.rate))
        var phase = 0.0
        for i in 0..<count {
            var v = noise() * 400
            if i >= callStart && i < callEnd {
                phase += 2 * .pi * 45_000 / Double(Self.rate)
                v += sin(phase) * 9_000
            }
            pcm[i] = Int16(max(-32_767, min(32_767, v)))
        }
        return write(pcm)
    }

    private func write(_ pcm: [Int16]) -> URL {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataBytes = UInt32(pcm.count * 2)
        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8)); d.append(le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); d.append(le32(16))
        d.append(le16(1)); d.append(le16(1)); d.append(le32(Self.rate))
        d.append(le32(Self.rate * 2)); d.append(le16(2)); d.append(le16(16))
        d.append(contentsOf: Array("data".utf8)); d.append(le32(dataBytes))
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("scrub_test_\(UUID().uuidString).wav")
        try? d.write(to: url)
        return url
    }

    private func samples(of url: URL) -> [Int16] {
        guard let format = WavHeader.describe(url: url),
              let handle = try? FileHandle(forReadingFrom: url),
              (try? handle.seek(toOffset: format.dataOffset)) != nil,
              let data = try? handle.read(upToCount: Int(format.dataBytes))
        else { return [] }
        try? handle.close()
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    private func rms(_ s: ArraySlice<Int16>) -> Double {
        guard !s.isEmpty else { return 0 }
        return (s.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(s.count)).squareRoot()
    }

    private func peak(_ s: ArraySlice<Int16>) -> Double {
        s.reduce(0.0) { max($0, abs(Double($1))) }
    }

    /// The whole point: the background between calls has to go, because at 16×
    /// it is a continuous hiss under everything.
    @Test func scrubbingRemovesTheBackgroundBetweenCalls() throws {
        let url = makeNoisyCall()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = samples(of: url)

        let out = try #require(INatExport.scrubbed(url, baseName: "scrub-test"))
        defer { try? FileManager.default.removeItem(at: out) }
        let after = samples(of: out)
        #expect(after.count == before.count)

        // A quiet stretch well clear of the call, in samples.
        let quiet = 0..<Int(0.2 * Double(Self.rate))
        let dropped = rms(before[quiet]) / max(rms(after[quiet]), 0.001)
        #expect(dropped > 10, "background only fell by \(dropped)×")
    }

    /// And the call has to survive it. A scrub that silences the background by
    /// silencing everything is worse than no scrub at all.
    @Test func scrubbingKeepsTheCall() throws {
        let url = makeNoisyCall()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = samples(of: url)

        let out = try #require(INatExport.scrubbed(url, baseName: "scrub-test"))
        defer { try? FileManager.default.removeItem(at: out) }
        let after = samples(of: out)

        let start = Int(Self.callAt * Double(Self.rate))
        let call = start..<(start + Int(Self.callSeconds * Double(Self.rate)))
        #expect(peak(after[call]) > 0.5 * peak(before[call]))
    }

    /// The scrubbed file is what the 16× copy is made from, so it has to be the
    /// canonical layout `audibleCopy` reads, at the rate it came in at.
    @Test func theScrubbedFileIsCanonicalAndUnchangedInRate() throws {
        let url = makeNoisyCall()
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try #require(INatExport.scrubbed(url, baseName: "scrub-test"))
        defer { try? FileManager.default.removeItem(at: out) }

        let format = try #require(WavHeader.describe(url: out))
        #expect(format.isCanonical)
        #expect(format.sampleRate == Self.rate)

        let audible = try #require(INatExport.audibleCopy(of: out, baseName: "scrub-test"))
        defer { try? FileManager.default.removeItem(at: audible) }
        let expanded = try #require(WavHeader.describe(url: audible))
        #expect(expanded.sampleRate == Self.rate / UInt32(INatExport.expansionFactor))
        #expect(expanded.dataBytes == format.dataBytes)
    }

    /// Too short to measure anything from, and the caller falls back to the
    /// unscrubbed audio rather than attaching nothing.
    @Test func audioShorterThanOneWindowIsRefusedRatherThanMangled() throws {
        let url = write([Int16](repeating: 100, count: 128))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(INatExport.scrubbed(url, baseName: "scrub-test") == nil)
    }
}
