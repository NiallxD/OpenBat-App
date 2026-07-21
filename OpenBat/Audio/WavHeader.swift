//
//  WavHeader.swift
//  OpenBat
//
//  Reads the sample rate and PCM data size back out of a WAV that AudioRecorder
//  wrote (fixed 44-byte header: `RIFF...WAVEfmt ...data<size>`, no extra chunks
//  before `data`). Shared by every reader that only needs those two fields —
//  GuanoMetadata does its own parse of the trailing `guan` chunk afterwards.
//

import Foundation

enum WavHeader {
    static func read(url: URL) -> (sampleRate: UInt32, dataBytes: UInt32)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44 else { return nil }
        let sampleRate = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt32.self) }
        let dataBytes  = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt32.self) }
        guard sampleRate > 0, dataBytes > 0 else { return nil }
        return (sampleRate, dataBytes)
    }
}
