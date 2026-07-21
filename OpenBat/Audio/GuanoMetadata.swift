//
//  GuanoMetadata.swift
//  OpenBat
//
//  Builds a GUANO metadata chunk for embedding in a WAV. GUANO is the bat-acoustics
//  metadata standard: a `guan` RIFF chunk holding UTF-8 `Key: Value` lines (newline
//  separated), the first of which must be `GUANO|Version: 1.0`. Downstream tools
//  (Kaleidoscope, Audacity, the NABat-ML pipeline) read this to recover the recording's
//  real timestamp, location, samplerate and device.
//
//  We emit the chunk bytes ourselves rather than via a library because AudioRecorder
//  writes the WAV manually to preserve the 384 kHz capture rate.
//

import Foundation

/// `nonisolated`: same reasoning as `Biquad`/`AudioLevel` — a stateless enum with no
/// isolation annotation inherits this project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` default, but this is called from `AudioRecorder`'s background queue
/// (`makeGuanoChunk`) and `RecordingMigration`'s detached background tasks
/// (`parseAndRender`) — plain data transformation with no reason to be actor-isolated.
nonisolated enum GuanoMetadata {

    /// One metadata line. `tightColon` writes `Key:Value` with no space after the colon —
    /// used for `Loc Position`, where a leading space before the latitude makes some apps
    /// (and the NABat notebook's reader) show a blank latitude.
    struct Field {
        let key: String
        let value: String
        let tightColon: Bool
        init(_ key: String, _ value: String, tightColon: Bool = false) {
            self.key = key; self.value = value; self.tightColon = tightColon
        }
    }

    /// Build the complete `guan` RIFF chunk (FOURCC + LE size + UTF-8 text + even pad).
    /// `fields` must lead with the GUANO version line.
    static func chunk(fields: [Field]) -> Data {
        let text = fields
            .map { "\($0.key)\($0.tightColon ? ":" : ": ")\($0.value)" }
            .joined(separator: "\n")
        let textBytes = Array(text.utf8)

        var data = Data()
        data.append(contentsOf: Array("guan".utf8))
        data.append(le32(UInt32(textBytes.count)))   // size excludes the pad byte
        data.append(contentsOf: textBytes)
        if textBytes.count % 2 != 0 { data.append(0) } // RIFF chunks are word-aligned
        return data
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    /// Reads the `guan` chunk back out of a WAV `AudioRecorder` wrote (see
    /// `AudioRecorder.closeAndKeep` for the exact layout: 44-byte header, `dataBytes`
    /// of PCM, then this chunk) — used by `RecordingMigration` to backfill `Recording`
    /// entries for WAVs saved before that model existed. Returns a plain key→value
    /// dictionary (last-line-wins on a duplicate key, which never happens in practice);
    /// nil if the file is too short or has no `guan` chunk where one's expected.
    static func read(from url: URL) -> [String: String]? {
        guard let header = WavHeader.read(url: url) else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(44) + UInt64(header.dataBytes))) != nil else { return nil }
        guard let chunkHeader = try? handle.read(upToCount: 8), chunkHeader.count == 8,
              String(decoding: chunkHeader.prefix(4), as: UTF8.self) == "guan"
        else { return nil }
        let size = chunkHeader.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        guard let textData = try? handle.read(upToCount: Int(size)), textData.count == Int(size) else { return nil }

        var fields: [String: String] = [:]
        for line in String(decoding: textData, as: UTF8.self).split(separator: "\n") {
            // `tightColon` fields ("Loc Position") have no space after the colon;
            // everything else does — try the space-separated form first.
            if let range = line.range(of: ": ") {
                fields[String(line[..<range.lowerBound])] = String(line[range.upperBound...])
            } else if let colon = line.firstIndex(of: ":") {
                fields[String(line[..<colon])] = String(line[line.index(after: colon)...])
            }
        }
        return fields
    }
}
