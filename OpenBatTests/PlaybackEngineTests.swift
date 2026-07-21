//
//  PlaybackEngineTests.swift
//  OpenBatTests
//
//  Builds a WAV byte-for-byte like AudioRecorder's own header writer, then
//  drives PlaybackEngine exactly the way PlaybackPlayerView does (load → play →
//  wait) — regression coverage for the class of bug where load()/play() fail
//  silently and playback just looks inert (no error, no progress, no spectrogram).
//

import Testing
import Foundation
@testable import OpenBat

@MainActor
struct PlaybackEngineTests {

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Mirrors AudioRecorder.wavHeader + the closeAndKeep size patch exactly.
    private func makeTestWav(sampleRate: UInt32 = 384_000, seconds: Double = 1.0) -> URL {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let sampleCount = Int(Double(sampleRate) * seconds)
        let dataBytes = UInt32(sampleCount * 2)

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(Self.le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(Self.le32(16))
        d.append(Self.le16(1))
        d.append(Self.le16(channels))
        d.append(Self.le32(sampleRate))
        d.append(Self.le32(byteRate))
        d.append(Self.le16(blockAlign))
        d.append(Self.le16(bits))
        d.append(contentsOf: Array("data".utf8))
        d.append(Self.le32(dataBytes))

        // 40 kHz-ish tone scaled to 16-bit so there's real signal in the file.
        var pcm = [Int16](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            pcm[i] = Int16(sin(2 * .pi * 40_000 * t) * 20000)
        }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag_\(UUID().uuidString).wav")
        try? d.write(to: url)
        return url
    }

    @Test func wavHeaderParsesTestFile() {
        let url = makeTestWav()
        let header = WavHeader.read(url: url)
        #expect(header != nil, "WavHeader.read returned nil for a well-formed test WAV")
        if let header {
            #expect(header.sampleRate == 384_000)
            #expect(header.dataBytes == 384_000 * 2)
        }
        try? FileManager.default.removeItem(at: url)
    }

    @Test func engineLoadSetsDuration() {
        let url = makeTestWav(seconds: 2.0)
        let engine = PlaybackEngine()
        engine.load(url: url)
        #expect(engine.loadedURL != nil, "loadedURL is nil after load() — header read must have failed")
        #expect(engine.durationSeconds > 1.9 && engine.durationSeconds < 2.1,
                "durationSeconds = \(engine.durationSeconds), expected ~2.0")
        try? FileManager.default.removeItem(at: url)
    }

    @Test func loadMissingFileSetsLoadError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope_\(UUID().uuidString).wav")
        let engine = PlaybackEngine()
        engine.load(url: missing)
        #expect(engine.loadedURL == nil)
        #expect(engine.loadError != nil, "load() of a missing file should set loadError instead of failing silently")
    }

    @Test func playActuallyStartsAndProgresses() async {
        let url = makeTestWav(seconds: 2.0)
        let engine = PlaybackEngine()
        engine.load(url: url)
        #expect(engine.loadedURL != nil)
        #expect(engine.durationSeconds > 0)

        engine.listenMode = .off   // avoid any HeterodyneProcessor gate/state quirks for this check
        engine.play()
        #expect(engine.isPlaying == true, "isPlaying didn't flip true after play() — the guard in play() bailed")

        // Give the pacing thread real wall-clock time to advance.
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(engine.currentTimeSeconds > 0,
                "currentTimeSeconds still 0 after 400ms of playback — PlaybackDriver never fed a buffer")

        let cols = engine.spectrogramProcessor.drain()
        #expect(!cols.isEmpty,
                "spectrogramProcessor.drain() returned 0 columns after 400ms of playback — this is why the spectrogram shows nothing")

        engine.stop()
        try? FileManager.default.removeItem(at: url)
    }
}
