//
//  UploadConversionPipeline.swift
//  OpenBat
//
//  Builds the transient upload copy of a recording: high-pass filtered and
//  quality-gated here, anonymized by `AnonymizedUploadBuilder` (location,
//  timestamp, metadata allowlist, object identity). This file owns the
//  audio/IO half of that job only — every privacy-relevant decision lives in
//  the builder, so there is exactly one place to audit. Operates entirely
//  on a NEW file; the on-device original `AudioRecorder` wrote is never
//  reopened for writing. Classification (species Auto ID) already happened
//  upstream, live, on unfiltered audio via PulseDetector — independent of
//  both the original and this derived copy — so the spec's "classify before
//  filtering" ordering (§5 point 5) is satisfied by construction, not by
//  anything done here.
//
//  FLAC compression (the spec's final step) is NOT done here — this produces
//  the filtered, fuzzed, re-tagged intermediate WAV; RecordingUploader then
//  hands it to FLACEncoder (see LosslessAudioEncoder.swift) before upload.
//

import Foundation
import CoreLocation

struct UploadConversionResult {
    let derivedWavURL: URL
    let quality: UploadQualityGateResult
    let cutoffHz: Double
    /// Everything the transmission needs — object key and request headers
    /// included — already anonymized. Returned whole (rather than just the
    /// coordinate) so the upload call site has nothing left to decide: it sends
    /// exactly what `AnonymizedUploadBuilder` produced. The request headers used
    /// to be assembled separately in `RecordingUploader`, which is how the
    /// unfuzzed coordinate ended up being sent in one place while the fuzzed one
    /// went into the file.
    let anonymized: AnonymizedUpload
}

enum UploadConversionError: Error {
    case cannotReadOriginal
    case qualityGateFailed(UploadQualityGateResult)
}

/// `nonisolated`: this project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` would
/// otherwise make `convert` (and the heavy per-sample filtering/quality-gate work it
/// does) implicitly MainActor-isolated — called from `RecordingUploader`'s
/// `Task.detached` background work, that would force a synchronous, blocking
/// `unsafeForcedSync` hop onto the main actor for the entire conversion (reading a
/// multi-megabyte WAV, running it through the cascaded high-pass filter sample by
/// sample), freezing the UI for however long that takes. Same reasoning as
/// `Biquad`/`GuanoMetadata`/`WavHeader`.
nonisolated enum UploadConversionPipeline {

    /// What upload-prep needs about the recording being contributed.
    ///
    /// Deliberately carries no device id, no consent version, and no recordist
    /// name. Those used to be here purely to be written into the uploaded file's
    /// GUANO; removing the fields removed the reason to thread them through, and
    /// the type not having a `deviceID` at all is what makes it structurally
    /// impossible for one to reach `AnonymizedUploadBuilder`. Consent is checked
    /// before conversion starts (`RecordingUploader.handleRecordingSaved`) and
    /// again server-side at upload — it is not a property of the file.
    struct Context {
        /// The recording's true start time. Bucketed downstream by
        /// `AnonymizedUploadBuilder`; never bucketed here.
        let recordedAt: Date
        let species: String
        let confidence: Float?
        /// Used only when the original WAV carries no readable GUANO `Loc
        /// Position` — the `Recording`'s own stored coordinate. Goes through
        /// exactly the same grid-snap as a GUANO-sourced one, so there's no
        /// path by which a precise coordinate reaches the upload.
        var fallbackCoordinate: CLLocationCoordinate2D? = nil
        var cutoffHz: Double = HighPassPrivacyFilter.defaultCutoffHz
    }

    /// Samples per streamed block — 256 K samples is 1 MB as `[Float]`, small
    /// enough that peak footprint is flat regardless of recording length, large
    /// enough that per-block read overhead is irrelevant next to the filter work.
    private static let blockSamples = 1 << 18

    /// Two passes, both streamed, neither holding the whole recording:
    /// pass 1 accumulates the quality gate (cheap — read + histogram), pass 2
    /// filters and writes. Splitting them means a recording the gate rejects
    /// never gets filtered or written at all; the alternative (one pass, discard
    /// on failure) would write out a file the size of the original before
    /// finding out it wasn't wanted.
    static func convert(originalWavURL: URL, context: Context) throws -> UploadConversionResult {
        guard let header = WavHeader.read(url: originalWavURL) else {
            throw UploadConversionError.cannotReadOriginal
        }
        let sampleRate = Double(header.sampleRate)
        let totalSamples = Int(header.dataBytes) / 2
        guard totalSamples > 0 else { throw UploadConversionError.cannotReadOriginal }

        let originalFields = GuanoMetadata.read(from: originalWavURL) ?? [:]
        let pulseCount = originalFields["OpenBat|Species Pulse Count"].flatMap(Int.init) ?? 0

        var accumulator = UploadQualityGate.Accumulator()
        var sawSamples = false
        try streamSamples(from: originalWavURL, totalSamples: totalSamples) { block in
            sawSamples = true
            accumulator.add(block)
        }
        guard sawSamples else { throw UploadConversionError.cannotReadOriginal }

        let quality = accumulator.result(pulseCount: pulseCount)
        guard quality.passed else { throw UploadConversionError.qualityGateFailed(quality) }

        // Every anonymizing decision — coordinate, timestamp, which metadata
        // survives, what object the result is stored as — is made in this one
        // call. Nothing below re-derives any of it.
        let anonymized = AnonymizedUploadBuilder.build(
            originalFields: originalFields,
            recordedAt: context.recordedAt,
            fallbackCoordinate: context.fallbackCoordinate,
            species: context.species,
            confidence: context.confidence,
            cutoffHz: context.cutoffHz,
            quality: quality)

        let derivedURL = try writeDerivedWav(
            sourceURL: originalWavURL, totalSamples: totalSamples,
            sampleRate: header.sampleRate,
            filter: HighPassPrivacyFilter(sampleRate: sampleRate, cutoffHz: context.cutoffHz),
            guano: anonymized.guanoChunk)

        return UploadConversionResult(
            derivedWavURL: derivedURL, quality: quality, cutoffHz: context.cutoffHz,
            anonymized: anonymized)
    }

    /// Feeds `body` consecutive blocks of the source's PCM. Stops early on a
    /// short read (`WavPCMReader` returns a shorter array near EOF rather than
    /// failing), so a `dataBytes` that overstates what's actually on disk
    /// truncates cleanly instead of throwing.
    private static func streamSamples(from url: URL, totalSamples: Int,
                                      _ body: (inout [Float]) throws -> Void) throws {
        var offset = 0
        while offset < totalSamples {
            let wanted = min(blockSamples, totalSamples - offset)
            guard var block = WavPCMReader.readSamples(wavURL: url, startSample: offset, count: wanted),
                  !block.isEmpty else {
                if offset == 0 { throw UploadConversionError.cannotReadOriginal }
                return
            }
            try body(&block)
            offset += block.count
            if block.count < wanted { return }
        }
    }

    /// Deletes a derived copy — called once its upload succeeds (Phase 6), or
    /// if conversion produced a file that ends up not being uploaded at all.
    /// Never touches the original recording.
    static func discardDerivedCopy(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    // Location and GUANO construction used to live here. Both moved wholesale to
    // `AnonymizedUploadBuilder` — see that file's header for why they belong in
    // one auditable place rather than beside the streaming/filtering code.

    // MARK: WAV write

    /// Where derived (filtered, pre-FLAC) copies live. Exposed so a launch-time
    /// sweep can clear anything a crash or an interrupted upload left behind.
    static var derivedCopyDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UploadPrep", isDirectory: true)
    }

    /// Same 44-byte-header + PCM + trailing `guan` chunk layout AudioRecorder
    /// itself writes (see `AudioRecorder.closeAndKeep`/`wavHeader`) — kept as a
    /// local, self-contained writer here rather than reaching into
    /// AudioRecorder's private helpers, since this runs on a completely
    /// separate, already-closed file.
    ///
    /// Streams source → filter → disk a block at a time via a `FileHandle`. The
    /// header's two size fields are patched at the end from the count actually
    /// written, so a source that reads short (see `streamSamples`) still
    /// produces a valid WAV rather than one whose header overstates its data.
    private static func writeDerivedWav(sourceURL: URL, totalSamples: Int, sampleRate: UInt32,
                                        filter: HighPassPrivacyFilter, guano: Data) throws -> URL {
        let dir = derivedCopyDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).wav")

        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw UploadConversionError.cannotReadOriginal
        }
        // Any throw past this point leaves a partial file behind — remove it, so
        // a failed conversion can't masquerade as a valid derived copy.
        var succeeded = false
        defer {
            try? handle.close()
            if !succeeded { discardDerivedCopy(at: url) }
        }

        try handle.write(contentsOf: wavHeader(sampleRate: sampleRate, dataBytes: totalSamples * 2,
                                               guanoBytes: guano.count))

        var filter = filter
        var written = 0
        try streamSamples(from: sourceURL, totalSamples: totalSamples) { block in
            filter.process(&block)
            var pcm16 = [Int16](repeating: 0, count: block.count)
            for i in block.indices {
                let clipped = max(-1, min(1, block[i]))
                pcm16[i] = Int16((clipped * 32767).rounded())
            }
            try pcm16.withUnsafeBufferPointer { try handle.write(contentsOf: Data(buffer: $0)) }
            written += block.count
        }

        try handle.write(contentsOf: guano)

        if written != totalSamples {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: wavHeader(sampleRate: sampleRate, dataBytes: written * 2,
                                                   guanoBytes: guano.count))
        }

        succeeded = true
        return url
    }

    private static func wavHeader(sampleRate: UInt32, dataBytes: Int, guanoBytes: Int) -> Data {
        var header = Data()
        header.append(contentsOf: Array("RIFF".utf8))
        header.append(le32(UInt32(36 + dataBytes + guanoBytes)))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        header.append(le32(16))
        header.append(le16(1))
        header.append(le16(1))
        header.append(le32(sampleRate))
        header.append(le32(sampleRate * 2))
        header.append(le16(2))
        header.append(le16(16))
        header.append(contentsOf: Array("data".utf8))
        header.append(le32(UInt32(dataBytes)))
        return header
    }

    private static func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private static func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
}
