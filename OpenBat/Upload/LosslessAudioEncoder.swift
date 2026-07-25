//
//  LosslessAudioEncoder.swift
//  OpenBat
//
//  FLAC compression of the filtered/trimmed upload copy — the spec is explicit
//  that no lossy codec (MP3/AAC/Opus) may be used at any stage, since that
//  would defeat the reference-library's purpose. AVFoundation/Core Audio can
//  DECODE FLAC on Apple platforms but cannot ENCODE it. `FLACEncoder.swift` is
//  the real conforming type, backed by libFLAC (vendored as a binary
//  XCFramework — see its doc comment). Kept as a protocol rather than calling
//  libFLAC directly from UploadConversionPipeline/RecordingUploader so a
//  different encoder is a one-line swap if this dependency ever needs replacing.
//

import Foundation

/// `nonisolated`: conforming encoders do heavy synchronous work (see
/// `FLACEncoder`) called from `RecordingUploader`'s `Task.detached` background
/// work — without this, the project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` default makes the requirement (and so every witness, regardless
/// of the conforming type's own isolation) implicitly MainActor-isolated,
/// forcing a blocking hop onto the main actor for the whole encode.
nonisolated protocol LosslessAudioEncoder {
    /// Encode the 16-bit mono PCM WAV at `wavURL` to a FLAC file at `outputURL`.
    func encode(wavURL: URL, outputURL: URL) throws
}
