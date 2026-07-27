//
//  FLACEncoder.swift
//  OpenBat
//
//  Real LosslessAudioEncoder backed by libFLAC, vendored as a precompiled
//  binary XCFramework via Stephen Booth's SPM wrappers (BSD-3-Clause):
//    https://github.com/sbooth/flac-binary-xcframework
//    https://github.com/sbooth/ogg-binary-xcframework  (required link-time dependency)
//  `import FLAC` exposes the C API directly (module map umbrella header
//  `all.h`) — this wraps the plain encode-a-16-bit-mono-file path
//  (`FLAC__stream_encoder_init_file`/`_process_interleaved`/`_finish`), which
//  is all UploadConversionPipeline's mono 16-bit WAVs need.
//

import Foundation
import FLAC

/// `nonisolated`: `encode` does the actual libFLAC encoding work, called from
/// `RecordingUploader`'s `Task.detached` background work — see
/// `UploadConversionPipeline`'s own `nonisolated` doc comment for why.
nonisolated struct FLACEncoder: LosslessAudioEncoder {
    enum EncoderError: Error {
        case cannotOpenSource
        case encoderInitFailed(FLAC__StreamEncoderInitStatus)
        case processFailed
        case finishFailed
    }

    /// 0-8, FLAC's own scale — 5 is libFLAC's default (good size/speed balance);
    /// nothing about this pipeline needs the slower, marginally smaller extremes.
    var compressionLevel: UInt32 = 5

    /// Samples per encode block — see `UploadConversionPipeline.blockSamples`
    /// for the same reasoning: bounded memory regardless of recording length.
    private static let blockSamples = 1 << 18

    func encode(wavURL: URL, outputURL: URL) throws {
        guard let header = WavHeader.read(url: wavURL) else { throw EncoderError.cannotOpenSource }
        let totalSamples = Int(header.dataBytes) / 2
        guard totalSamples > 0 else { throw EncoderError.cannotOpenSource }

        guard let encoder = FLAC__stream_encoder_new() else { throw EncoderError.cannotOpenSource }
        defer { FLAC__stream_encoder_delete(encoder) }

        FLAC__stream_encoder_set_channels(encoder, 1)
        FLAC__stream_encoder_set_bits_per_sample(encoder, 16)
        FLAC__stream_encoder_set_sample_rate(encoder, header.sampleRate)
        FLAC__stream_encoder_set_compression_level(encoder, compressionLevel)
        FLAC__stream_encoder_set_total_samples_estimate(encoder, UInt64(totalSamples))

        // The source WAV's GUANO fields ride along as Vorbis comments. Without
        // this the encoder silently dropped everything after the PCM, so the
        // uploaded file carried no timestamp, location, species or applied
        // high-pass cutoff at all — leaving R2 objects with no usable
        // provenance whatsoever.
        //
        // Note the source here is the DERIVED copy, not the on-device original:
        // by this point its GUANO has already been through
        // `AnonymizedUploadBuilder`'s allowlist, so this copies forward the
        // anonymized field set and cannot reintroduce anything stripped from it.
        let vorbisComment = Self.makeVorbisComment(from: GuanoMetadata.read(from: wavURL) ?? [:])
        defer { if let vorbisComment { FLAC__metadata_object_delete(vorbisComment) } }
        if let vorbisComment {
            // libFLAC keeps the pointer rather than copying, so the block must
            // outlive `finish()` — hence the deferred delete above, not here.
            var blocks: [UnsafeMutablePointer<FLAC__StreamMetadata>?] = [vorbisComment]
            _ = blocks.withUnsafeMutableBufferPointer {
                FLAC__stream_encoder_set_metadata(encoder, $0.baseAddress, 1)
            }
        }

        try? FileManager.default.removeItem(at: outputURL)
        let status = outputURL.withUnsafeFileSystemRepresentation { path -> FLAC__StreamEncoderInitStatus in
            FLAC__stream_encoder_init_file(encoder, path, nil, nil)
        }
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            throw EncoderError.encoderInitFailed(status)
        }

        var offset = 0
        while offset < totalSamples {
            let wanted = min(Self.blockSamples, totalSamples - offset)
            guard let pcm = WavPCMReader.readSamples(wavURL: wavURL, startSample: offset, count: wanted),
                  !pcm.isEmpty else {
                if offset == 0 { throw EncoderError.cannotOpenSource }
                break   // short read near EOF — encode what's actually there
            }

            // Float32 [-1,1] → Int32 (libFLAC's `process_interleaved` always takes
            // FLAC__int32 regardless of bits_per_sample; only the low 16 bits are
            // meaningful here since bits_per_sample is set to 16 above).
            var samples32 = [Int32](repeating: 0, count: pcm.count)
            for i in pcm.indices {
                let clipped = max(-1, min(1, pcm[i]))
                samples32[i] = Int32(clipped * 32767)
            }

            let ok = samples32.withUnsafeBufferPointer { buf in
                FLAC__stream_encoder_process_interleaved(encoder, buf.baseAddress, UInt32(pcm.count))
            }
            guard ok != 0 else { throw EncoderError.processFailed }

            offset += pcm.count
            if pcm.count < wanted { break }
        }

        guard FLAC__stream_encoder_finish(encoder) != 0 else { throw EncoderError.finishFailed }
    }

    /// GUANO's `Namespace|Key` field names map onto Vorbis comment names
    /// verbatim. Vorbis names may not contain `=` (the name/value separator) and
    /// are conventionally uppercase ASCII; GUANO keys here are all ASCII, so the
    /// only real constraint is dropping anything with an embedded `=`.
    private static func makeVorbisComment(from fields: [String: String]) -> UnsafeMutablePointer<FLAC__StreamMetadata>? {
        let usable = fields.filter { !$0.key.isEmpty && !$0.key.contains("=") }
        guard !usable.isEmpty,
              let object = FLAC__metadata_object_new(FLAC__METADATA_TYPE_VORBIS_COMMENT) else { return nil }

        // Sorted so the comment block is byte-identical for identical metadata
        // rather than varying with Dictionary iteration order.
        for key in usable.keys.sorted() {
            var entry = FLAC__StreamMetadata_VorbisComment_Entry()
            let appended = key.withCString { name in
                usable[key]!.withCString { value in
                    FLAC__metadata_object_vorbiscomment_entry_from_name_value_pair(&entry, name, value)
                }
            }
            guard appended != 0 else { continue }
            // copy: false transfers ownership of `entry`'s buffer to `object`,
            // which frees it in FLAC__metadata_object_delete.
            if FLAC__metadata_object_vorbiscomment_append_comment(object, entry, 0) == 0 {
                free(entry.entry)
            }
        }
        return object
    }
}
