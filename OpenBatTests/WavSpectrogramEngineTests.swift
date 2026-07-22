//
//  WavSpectrogramEngineTests.swift
//  OpenBatTests
//

import Testing
import Foundation
@testable import OpenBat

struct WavSpectrogramEngineTests {

    @Test func renderOverviewReturnsWholeFileMetadata() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.5, toneFrequency: 30_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let overview = WavSpectrogramEngine.renderOverview(wavURL: url, maxWidth: 512)
        #expect(overview != nil)
        #expect(overview?.sampleRate == 384_000)
        #expect(overview?.totalSamples == Int(0.5 * 384_000))
        #expect((overview?.image.size.width ?? 0) > 0)
    }

    @Test func renderDetailTileNarrowSpanProducesBoundedImage() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.05, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let tile = WavSpectrogramEngine.renderDetailTile(
            wavURL: url, sampleRate: 384_000,
            startSample: 0, endSample: Int(0.05 * 384_000),
            minFreqHz: 0, maxFreqHz: 192_000,
            targetColumns: 512, palette: .inferno, noiseFloor: 0.1)
        #expect(tile != nil)
        #expect((tile?.image.size.width ?? 0) <= 512)
        #expect((tile?.image.size.width ?? 0) > 0)
    }

    /// The load-bearing memory-bound invariant: a viewport spanning several
    /// seconds (many more native STFT columns than the screen could ever show)
    /// must still pool down to `targetColumns`, not balloon to native
    /// resolution — this is the whole reason `streamPooledGrid` exists instead
    /// of `STFTGrid.compute` for detail tiles.
    @Test func renderDetailTileWideSpanStillBoundsToTargetColumns() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 3.0, toneFrequency: 35_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let tile = WavSpectrogramEngine.renderDetailTile(
            wavURL: url, sampleRate: 384_000,
            startSample: 0, endSample: Int(3.0 * 384_000),
            minFreqHz: 0, maxFreqHz: 192_000,
            targetColumns: 256, palette: .inferno, noiseFloor: 0.1)
        #expect(tile != nil)
        #expect((tile?.image.size.width ?? 0) <= 256)
    }

    @Test func renderDetailTileFrequencyCropClampsToValidRange() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.05, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        // Request a crop wider than Nyquist — should clamp, not crash/return nil.
        let tile = WavSpectrogramEngine.renderDetailTile(
            wavURL: url, sampleRate: 384_000,
            startSample: 0, endSample: Int(0.05 * 384_000),
            minFreqHz: -1000, maxFreqHz: 999_999,
            targetColumns: 128, palette: .inferno, noiseFloor: 0.1)
        #expect(tile != nil)
        #expect((tile?.minFreqHz ?? -1) >= 0)
        #expect((tile?.maxFreqHz ?? .infinity) <= 192_000)
    }

    @Test func renderDetailTileInvalidRangeReturnsNil() {
        let url = TestWavFactory.make(sampleRate: 384_000, seconds: 0.05, toneFrequency: 40_000)
        defer { try? FileManager.default.removeItem(at: url) }

        let tile = WavSpectrogramEngine.renderDetailTile(
            wavURL: url, sampleRate: 384_000,
            startSample: 100, endSample: 100,   // zero-length
            minFreqHz: 0, maxFreqHz: 192_000,
            targetColumns: 128, palette: .inferno, noiseFloor: 0.1)
        #expect(tile == nil)
    }
}
