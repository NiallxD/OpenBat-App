//
//  UploadConversionPipeline.swift
//  OpenBat
//
//  Builds the transient upload copy of a recording — high-pass filtered,
//  quality-gated, location-fuzzed-or-accurate per the OS Precise Location
//  toggle, and re-tagged with upload-specific GUANO fields. Operates entirely
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
    /// The coordinate that went into the derived copy's GUANO — fuzzed or
    /// accurate per `usedFuzzedLocation`. Returned (not just written into the
    /// file) because the upload request sends location as a header too, and that
    /// header MUST carry this value rather than the original coordinate:
    /// sending the raw one there bypassed the fuzzing entirely.
    let uploadCoordinate: CLLocationCoordinate2D?
    let usedFuzzedLocation: Bool
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

    /// Everything upload-prep needs about the requesting device/user — kept as
    /// one struct so the call site (wherever Phase 6 triggers a conversion)
    /// doesn't have to thread five separate parameters through.
    struct Context {
        let deviceID: String
        let consentVersion: String
        let recordistName: String
        let locationAuthorization: CLAccuracyAuthorization
        /// Used only when the original WAV carries no readable GUANO `Loc
        /// Position` — the `Recording`'s own stored coordinate. Goes through
        /// exactly the same fuzz decision as a GUANO-sourced one, so there's no
        /// path by which an unfuzzed coordinate reaches the upload.
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

        let shouldFuzz = LocationFuzzing.shouldFuzzForUpload(authorization: context.locationAuthorization)
        let uploadCoordinate = uploadCoordinate(
            originalFields: originalFields, fallback: context.fallbackCoordinate, shouldFuzz: shouldFuzz)

        let guano = buildDerivedGuano(
            originalFields: originalFields, context: context,
            cutoffHz: context.cutoffHz, quality: quality,
            uploadCoordinate: uploadCoordinate)

        let derivedURL = try writeDerivedWav(
            sourceURL: originalWavURL, totalSamples: totalSamples,
            sampleRate: header.sampleRate,
            filter: HighPassPrivacyFilter(sampleRate: sampleRate, cutoffHz: context.cutoffHz),
            guano: guano)

        return UploadConversionResult(
            derivedWavURL: derivedURL, quality: quality, cutoffHz: context.cutoffHz,
            uploadCoordinate: uploadCoordinate, usedFuzzedLocation: shouldFuzz)
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

    // MARK: Location

    /// The single place the uploaded location is decided, for both the GUANO
    /// field and the request header. An unparseable GUANO position is dropped
    /// rather than passed through verbatim (the old behaviour): a string this
    /// can't parse is one it also can't fuzz, so forwarding it would be a way
    /// for an exact position to reach the server despite the user having turned
    /// Precise Location off.
    private static func uploadCoordinate(originalFields: [String: String],
                                         fallback: CLLocationCoordinate2D?,
                                         shouldFuzz: Bool) -> CLLocationCoordinate2D? {
        let parts = (originalFields["Loc Position"] ?? "").split(separator: " ").compactMap { Double($0) }
        let source: CLLocationCoordinate2D
        if parts.count == 2 {
            source = CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
        } else if let fallback {
            source = fallback
        } else {
            return nil
        }
        return shouldFuzz ? LocationFuzzing.fuzz(source) : source
    }

    // MARK: GUANO

    /// Carries every field from the original untouched, then adds/overrides the
    /// upload-specific ones — device_id, consent_version, recordist name, the
    /// applied high-pass cutoff, a quality score, and the fuzzed-or-accurate
    /// location. Hardware/mic-module field stays whatever the original already
    /// has (best-effort, "unknown" fallback lives in AudioRecorder itself).
    private static func buildDerivedGuano(
        originalFields: [String: String], context: Context,
        cutoffHz: Double, quality: UploadQualityGateResult, uploadCoordinate: CLLocationCoordinate2D?
    ) -> Data {
        var fields: [GuanoMetadata.Field] = []
        for (key, value) in originalFields where key != "Loc Position" {
            fields.append(.init(key, value))
        }
        if let uploadCoordinate {
            let value = String(format: "%.6f %.6f", uploadCoordinate.latitude, uploadCoordinate.longitude)
            fields.append(.init("Loc Position", value, tightColon: true))
        }
        fields.append(.init("OpenBat|Device ID", context.deviceID))
        fields.append(.init("OpenBat|Consent Version", context.consentVersion))
        if !context.recordistName.isEmpty {
            fields.append(.init("OpenBat|Recordist", context.recordistName))
        }
        fields.append(.init("OpenBat|HighPass Cutoff Hz", String(Int(cutoffHz.rounded()))))
        fields.append(.init("OpenBat|Quality SNR dB", String(format: "%.1f", quality.snrDB)))
        fields.append(.init("OpenBat|Quality Clipping Fraction", String(format: "%.4f", quality.clippingFraction)))
        return GuanoMetadata.chunk(fields: fields)
    }

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
                pcm16[i] = Int16(clipped * 32767)
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
