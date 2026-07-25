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

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// `{device_id}/{date}/{recording_id}.flac` — matches the object key
    /// convention in the spec (§6) exactly, so the Worker can derive the R2
    /// key straight from the URL path.
    static func uploadURL(deviceID: String, date: Date, recordingID: String) -> URL? {
        guard !baseURL.isEmpty else { return nil }
        let dateString = dateFormatter.string(from: date)
        return URL(string: "\(baseURL)/upload/\(deviceID)/\(dateString)/\(recordingID).flac")
    }
}
