//
//  UploadStatus.swift
//  OpenBat
//
//  Per-recording upload state, persisted on `Recording` (ClassificationStore)
//  so the app can show a real "pending uploads" view instead of the pipeline
//  being entirely fire-and-forget. `nil` on a `Recording` means no upload was
//  ever attempted for it (recorded before this field existed, or while
//  contribution was off) — displayed as `.notContributing`.
//

import Foundation

/// `nonisolated`: a pure value type with no shared state, constructed from
/// `RecordingUploader`'s background conversion/encode work and its background
/// session delegate as well as from the main actor.
nonisolated struct UploadStatus: Codable, Equatable {
    enum Phase: String, Codable {
        /// Consent wasn't granted when this recording was saved — no attempt made.
        case notContributing
        /// Eligible and waiting — auto-upload off, or Wi-Fi-only and not on Wi-Fi.
        case queued
        /// Reading the original WAV, running the quality gate, applying the
        /// irreversible high-pass privacy filter, fuzzing/keeping location.
        case converting
        /// Compressing the filtered copy to FLAC.
        case encoding
        case uploading
        case uploaded
        /// Quality gate rejected it, or the file couldn't be read — permanent,
        /// not retried automatically (the input itself is the problem).
        case rejected
        /// Network/Worker/encoder error — transient, retried on the next
        /// Wi-Fi-available event or manual retry.
        case failed
    }

    var phase: Phase
    var reason: String?
    var updatedAt: Date
    /// Consecutive automatic failures. Maintained by
    /// `ClassificationStore.updateUploadStatus` (which can see the previous
    /// value), reset the moment a fresh attempt gets past `.failed`. Optional so
    /// records written before this field existed decode as "never counted".
    var failureCount: Int?

    // Computed, not `static let`: a stored static is initialised lazily ONCE, so
    // every recording that ever reached a given phase shared a single
    // `updatedAt` frozen at whenever the app first touched that constant.
    static var notContributing: UploadStatus { .init(phase: .notContributing, reason: nil, updatedAt: Date()) }
    static var converting: UploadStatus { .init(phase: .converting, reason: nil, updatedAt: Date()) }
    static var encoding: UploadStatus { .init(phase: .encoding, reason: nil, updatedAt: Date()) }
    static var uploading: UploadStatus { .init(phase: .uploading, reason: nil, updatedAt: Date()) }
    static var uploaded: UploadStatus { .init(phase: .uploaded, reason: nil, updatedAt: Date()) }

    static func queued(_ reason: String) -> UploadStatus {
        UploadStatus(phase: .queued, reason: reason, updatedAt: Date())
    }

    static func rejected(_ reason: String) -> UploadStatus {
        UploadStatus(phase: .rejected, reason: reason, updatedAt: Date())
    }

    static func failed(_ reason: String) -> UploadStatus {
        UploadStatus(phase: .failed, reason: reason, updatedAt: Date())
    }

    /// After this many consecutive failures the automatic sweep gives up. Some
    /// failures are effectively permanent ("Upload service not configured yet",
    /// "FLAC encoding failed") but still land in `.failed`, so without a cap
    /// every Wi-Fi change re-ran a full convert + encode for each of them,
    /// forever. A manual tap still retries regardless — see `uploadNow`.
    static let maxAutomaticRetries = 5

    /// Whether this recording should be swept up by `RecordingUploader`'s
    /// automatic retry when Wi-Fi becomes available.
    var isRetryEligible: Bool {
        switch phase {
        case .queued: return true
        case .failed: return (failureCount ?? 0) < Self.maxAutomaticRetries
        default: return false
        }
    }

    /// True when the automatic sweep has given up and only an explicit tap will
    /// try again — surfaced so the UI can say so rather than looking idle.
    var hasExhaustedRetries: Bool {
        phase == .failed && (failureCount ?? 0) >= Self.maxAutomaticRetries
    }
}
