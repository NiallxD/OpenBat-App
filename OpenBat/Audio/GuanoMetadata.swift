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

enum GuanoMetadata {

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
}
