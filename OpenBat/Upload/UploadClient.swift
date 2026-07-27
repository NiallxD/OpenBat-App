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
    /// Deployed Worker, R2-bound (see backend/consent-worker/). Empty would
    /// mean "not ready yet" — RecordingUploader skips uploads entirely rather
    /// than failing loudly in that case.
    static var baseURL: String = "https://openbat-consent.niallbell.workers.dev"

    /// `{bucketed_date}/{object_id}.flac`. The key is built by
    /// `AnonymizedUploadBuilder`, not here — this only prefixes the endpoint, so
    /// there is no second place where an object key gets assembled and could
    /// drift from what the anonymizer decided.
    ///
    /// The key used to lead with `{device_id}/`, which made every uploaded
    /// object permanently attributable to the device that sent it (and was what
    /// let the erase endpoint sweep a device's recordings). That prefix is gone:
    /// see the notes' §4, and `ConsentAPIClient.eraseAllData` for what erasure
    /// now covers instead.
    static func uploadURL(objectKey: String) -> URL? {
        guard !baseURL.isEmpty else { return nil }
        return URL(string: "\(baseURL)/upload/\(objectKey)")
    }
}
