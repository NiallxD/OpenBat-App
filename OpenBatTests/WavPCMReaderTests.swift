//
//  WavPCMReaderTests.swift
//  OpenBatTests
//
//  `WavPCMReader.readSamples` is the single point every WAV player feature
//  (call analysis, spectrogram tiles, playback) reads raw PCM through, so its
//  edge behaviour — short reads at file boundaries rather than nil, and never
//  handing back more than asked — has to be right once, here, rather than
//  independently assumed by each caller.
//

import Testing
import Foundation
@testable import OpenBat

struct WavPCMReaderTests {

    /// A read within the file must decode to the correct sample count and
    /// amplitude, not just the correct byte count.
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

    /// A read starting well into the file returns exactly the requested count.
    @Test func readMidFileOffsetReturnsRequestedRange() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 1.0, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = WavPCMReader.readSamples(wavURL: url, startSample: 100_000, count: 5_000)
        #expect(samples?.count == 5_000)
    }

    /// A read that overruns the end of the file returns the samples that DO
    /// exist, not nil.
    ///
    /// This test previously asserted the opposite, and was wrong rather than
    /// merely outdated: returning nil for a range that runs one sample past the
    /// data means a selection dragged to the very end of a recording produces an
    /// empty analysis, which is indistinguishable to the user from the analysis
    /// being broken. `UploadConversionPipeline.streamSamples` also relies on the
    /// short read to terminate cleanly when a WAV's header overstates its data.
    /// See the reasoning in `WavPCMReader.readSamples`' own doc comment.
    @Test func requestOverrunningEndOfFileReturnsWhatExists() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.1, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let totalSamples = Int(0.1 * 384_000)
        let samples = WavPCMReader.readSamples(wavURL: url, startSample: totalSamples - 10, count: 1_000)

        #expect(samples?.count == 10, "should return exactly the 10 samples that exist past that offset")
    }

    /// The other half of the contract: a short read is only ever short, never
    /// long. A caller sizing a buffer from `count` must not be handed more.
    @Test func neverReturnsMoreThanRequested() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.5, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        for count in [1, 7, 1_000, 50_000] {
            let samples = WavPCMReader.readSamples(wavURL: url, startSample: 0, count: count)
            #expect((samples?.count ?? 0) <= count, "asked for \(count), got \(samples?.count ?? 0)")
        }
    }

    /// Short read for a range that *partially* exists; nil for one that doesn't
    /// exist at all. That boundary is what stops "truncate rather than fail"
    /// from quietly becoming "never fail".
    @Test func startingEntirelyPastEndOfFileReturnsNil() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.1, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let totalSamples = Int(0.1 * 384_000)
        #expect(WavPCMReader.readSamples(wavURL: url, startSample: totalSamples + 1_000, count: 100) == nil)
    }

    /// Negative start, zero count, and negative count must all be rejected
    /// rather than read as if they meant something else.
    @Test func invalidRangeReturnsNil() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.1, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(WavPCMReader.readSamples(wavURL: url, startSample: -1, count: 100) == nil)
        #expect(WavPCMReader.readSamples(wavURL: url, startSample: 0, count: 0) == nil)
        #expect(WavPCMReader.readSamples(wavURL: url, startSample: 0, count: -5) == nil)
    }

    /// A nonexistent file must fail cleanly rather than crash.
    @Test func missingFileReturnsNil() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).wav")
        #expect(WavPCMReader.readSamples(wavURL: missing, startSample: 0, count: 100) == nil)
    }
}
