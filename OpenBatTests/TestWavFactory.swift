//
//  TestWavFactory.swift
//  OpenBatTests
//
//  Shared synthetic-WAV builder for WavPlayer test files (WavSpectrogramEngine,
//  CallAnalysis, WavPCMReader) — mirrors AudioRecorder's own header writer
//  exactly, same shape as PlaybackEngineTests' private `makeTestWav` (kept
//  separate there to avoid touching already-passing test code).
//

import Foundation

enum TestWavFactory {
    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Writes a mono 16-bit WAV containing a single sine tone, or (if
    /// `chirpToFrequency` is set) a linear FM sweep from `toneFrequency` to
    /// `chirpToFrequency` over the file's duration — used by CallAnalysisTests
    /// to exercise start/end-frequency and sweep-rate measurement.
    static func make(sampleRate: UInt32 = 384_000, seconds: Double = 1.0,
                     toneFrequency: Double = 40_000, chirpToFrequency: Double? = nil,
                     amplitude: Double = 20_000) -> URL {
        let channels: UInt16 = 1
        let bits: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
        let blockAlign = channels * (bits / 8)
        let sampleCount = Int(Double(sampleRate) * seconds)
        let dataBytes = UInt32(sampleCount * 2)

        var d = Data()
        d.append(contentsOf: Array("RIFF".utf8))
        d.append(le32(36 + dataBytes))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        d.append(le32(16))
        d.append(le16(1))
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bits))
        d.append(contentsOf: Array("data".utf8))
        d.append(le32(dataBytes))

        var pcm = [Int16](repeating: 0, count: sampleCount)
        var phase = 0.0
        for i in 0..<sampleCount {
            let t = Double(i) / Double(sampleRate)
            let freq: Double
            if let chirpToFrequency {
                freq = toneFrequency + (chirpToFrequency - toneFrequency) * (t / max(seconds, 1e-9))
            } else {
                freq = toneFrequency
            }
            phase += 2 * .pi * freq / Double(sampleRate)
            pcm[i] = Int16(sin(phase) * amplitude)
        }
        pcm.withUnsafeBufferPointer { d.append(Data(buffer: $0)) }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wavplayer_test_\(UUID().uuidString).wav")
        try? d.write(to: url)
        return url
    }
}
