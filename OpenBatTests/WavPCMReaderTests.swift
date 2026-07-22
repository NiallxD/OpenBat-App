//
//  WavPCMReaderTests.swift
//  OpenBatTests
//

import Testing
import Foundation
@testable import OpenBat

struct WavPCMReaderTests {

    @Test func readsRequestedCountAndDecodesToneAmplitude() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.5, toneFrequency: 40_000, amplitude: 20_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = WavPCMReader.readSamples(wavURL: url, startSample: 0, count: 1000)
        #expect(samples != nil)
        #expect(samples?.count == 1000)
        let peak = samples?.map({ abs($0) }).max() ?? 0
        // 20000/32767 ≈ 0.61 — decoded peak should land close to that.
        #expect(peak > 0.55 && peak < 0.65, "decoded peak \(peak) should be close to the encoded amplitude ratio")
    }

    @Test func readMidFileOffsetReturnsRequestedRange() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 1.0, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = WavPCMReader.readSamples(wavURL: url, startSample: 100_000, count: 5_000)
        #expect(samples?.count == 5_000)
    }

    @Test func requestBeyondFileEndReturnsNil() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.1, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let totalSamples = Int(0.1 * 384_000)
        let samples = WavPCMReader.readSamples(wavURL: url, startSample: totalSamples - 10, count: 1_000)
        #expect(samples == nil, "a read extending past EOF should fail rather than silently truncate")
    }

    @Test func missingFileReturnsNil() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).wav")
        #expect(WavPCMReader.readSamples(wavURL: missing, startSample: 0, count: 100) == nil)
    }
}
