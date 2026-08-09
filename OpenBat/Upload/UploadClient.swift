//
//  UploadClient.swift
//  OpenBat
//
//  Endpoint/URL construction for the Worker's PUT /upload route (see
//  backend/consent-worker/src/index.ts). Kept separate from RecordingUploader
//  (which owns the actual URLSession/upload orchestration) the same way
//  ConsentAPIClient is separate from ConsentStore.
//

import Foundation

/// `nonisolated`: stateless URL construction, called from `RecordingUploader`'s
/// off-main upload path.
nonisolated enum UploadClient {
    /// Deliberately severed for launch (see `ConsentStore.uploadContributionEnabled`):
    /// contribution can't be offered until reference-quality recordings can be
    /// verified by non-acoustic means, so the client is cut off from the Worker
    /// rather than merely gated by UI/consent. Empty makes RecordingUploader
    /// skip uploads entirely (the same no-op path it already has for "not
    /// deployed yet"). Restore to re-enable:
    /// "https://openbat-consent.niallbell.workers.dev"
    static var baseURL: String = ""

    /// `{bucketed_date}/{object_id}.flac`. The key is built by
    /// `AnonymizedUploadBuilder`, not here — this only prefixes the endpoint, so
    /// there is no second place where an object key gets assembled and could
    /// drift from what the anonymizer decided.
    ///
    /// The key used to lead with `{device_id}/`, making every uploaded object
    /// permanently attributable to the device that sent it, and letting the
    /// erase endpoint sweep a device's recordings. That prefix is gone — see
    /// `ConsentAPIClient.eraseConsentRecord` for what erasure covers instead.
    static func uploadURL(objectKey: String) -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/upload/\(objectKey)")
    }
}
