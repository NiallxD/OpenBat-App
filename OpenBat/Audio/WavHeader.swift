//
//  WavHeader.swift
//  OpenBat
//
//  Reads the sample rate and PCM data size back out of a WAV. Shared by every
//  reader that only needs those two fields — GuanoMetadata does its own parse of
//  the trailing `guan` chunk afterwards.
//
//  This used to read both fields from fixed byte offsets (24 and 40), which is
//  true only of the 44-byte canonical header `AudioRecorder` writes. Every other
//  reader in the app still assumes that layout, so `describe` exists to tell the
//  importer whether a file actually HAS it — anything else is transcoded on the
//  way in rather than being read at the wrong offset and shown as noise. See
//  `RecordingImporter.normalizeIfNeeded`.
//

import Foundation

/// Where the audio actually lives in a RIFF file, and in what format. Produced by
/// walking the chunk table rather than assuming offsets.
///
/// `nonisolated` for the same reason `WavHeader` is: a plain value type read by
/// off-main file parsing, which would otherwise inherit
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and make `isCanonical`
/// unreachable from the very callers that need it.
nonisolated struct WavFormat {
    var sampleRate: UInt32
    var channels: UInt16
    var bitsPerSample: UInt16
    /// `fmt ` audio format tag: 1 = integer PCM, 3 = IEEE float, 0xFFFE = extensible.
    var formatTag: UInt16
    /// Byte offset of the first PCM sample.
    var dataOffset: UInt64
    /// Length of the `data` chunk in bytes.
    var dataBytes: UInt32

    /// The exact shape every other reader in this app hardcodes: PCM starting at
    /// byte 44, 16-bit, mono. Anything else has to be converted before those
    /// readers see it.
    var isCanonical: Bool {
        dataOffset == 44 && bitsPerSample == 16 && channels == 1 && formatTag == 1
    }
}

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel`/`GuanoMetadata` — stateless
/// file parsing called from `AudioRecorder`'s background queue and
/// `RecordingSpectrogramRenderer`'s off-main render path, but had no explicit
/// isolation annotation, so it inherited `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
nonisolated enum WavHeader {

    /// Sample rate + PCM byte count. Kept as the narrow API almost every caller
    /// wants; now answered by a real chunk walk, so it is also correct for a file
    /// with a `LIST` chunk or an extensible `fmt ` — which the fixed-offset
    /// version silently mis-read.
    static func read(url: URL) -> (sampleRate: UInt32, dataBytes: UInt32)? {
        guard let f = describe(url: url) else { return nil }
        return (f.sampleRate, f.dataBytes)
    }

    /// Walks the RIFF chunk table and reports the real geometry of the file.
    /// Returns nil if this isn't a RIFF/WAVE file at all, or if either of the two
    /// chunks that matter is missing.
    ///
    /// Chunk sizes are read as declared, but `data`'s is clamped to what the file
    /// actually holds: a truncated recording (a crash mid-write, an interrupted
    /// copy) declares its intended length in the header and every reader that
    /// trusts it would run off the end.
    static func describe(url: URL) -> WavFormat? {
        CloudStorage.ensureDownloaded(url)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileBytes = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0

        guard let riff = try? handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4).elementsEqual(Array("RIFF".utf8)),
              riff.dropFirst(8).prefix(4).elementsEqual(Array("WAVE".utf8))
        else { return nil }

        var sampleRate: UInt32 = 0
        var channels: UInt16 = 0
        var bits: UInt16 = 0
        var tag: UInt16 = 0
        var dataOffset: UInt64 = 0
        var dataBytes: UInt32 = 0
        var haveFmt = false

        var cursor: UInt64 = 12
        // A malformed file could otherwise loop here; the bound is generous
        // enough that no real recording reaches it.
        var guardCount = 0
        while cursor + 8 <= fileBytes, guardCount < 512 {
            guardCount += 1
            guard (try? handle.seek(toOffset: cursor)) != nil,
                  let head = try? handle.read(upToCount: 8), head.count == 8
            else { break }
            let id = String(decoding: head.prefix(4), as: UTF8.self)
            let size = head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
            let body = cursor + 8

            if id == "fmt " {
                guard let fmt = try? handle.read(upToCount: 16), fmt.count == 16 else { break }
                tag        = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0,  as: UInt16.self) }
                channels   = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 2,  as: UInt16.self) }
                sampleRate = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4,  as: UInt32.self) }
                bits       = fmt.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 14, as: UInt16.self) }
                haveFmt = true
            } else if id == "data" {
                dataOffset = body
                // Clamp to what's really there — see the doc comment.
                let available = fileBytes > body ? UInt32(min(fileBytes - body, UInt64(UInt32.max))) : 0
                dataBytes = min(size, available)
            }

            // Chunks are word-aligned: an odd size carries a pad byte.
            cursor = body + UInt64(size) + (size % 2 == 1 ? 1 : 0)
        }

        guard haveFmt, dataOffset > 0, sampleRate > 0, dataBytes > 0, channels > 0, bits > 0
        else { return nil }
        return WavFormat(sampleRate: sampleRate, channels: channels, bitsPerSample: bits,
                         formatTag: tag, dataOffset: dataOffset, dataBytes: dataBytes)
    }
}
