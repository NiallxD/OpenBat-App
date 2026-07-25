//
//  ConsentAPIClient.swift
//  OpenBat
//
//  Talks to the Cloudflare Worker in backend/consent-worker/ — the read/write
//  consent endpoints from the implementation plan's Phase 4. Fire-and-forget:
//  ConsentStore's local Keychain record is the source of truth for gating the
//  app's own UI, this just mirrors it server-side so the upload pipeline
//  (Phase 6) can check consent before accepting a file.
//

import Foundation

/// `nonisolated`: stateless HTTP plumbing. `authorize(_:)` in particular is
/// called from `RecordingUploader`'s off-main upload path, and the pushes below
/// run on `ConsentSync`'s background retry.
nonisolated enum ConsentAPIClient {
    /// Deployed Worker (see backend/consent-worker/). Empty would mean "not
    /// deployed yet" — calls below no-op rather than failing loudly in that
    /// case, since consent still works locally without a backend either way.
    static var baseURL: String = "https://openbat-consent.niallbell.workers.dev"

    /// Returns whether the Worker actually accepted the record. Callers use this
    /// to decide whether the state is confirmed server-side or still needs
    /// retrying — see `ConsentSync`. This was previously fire-and-forget with
    /// the result discarded, which meant a consent change made offline was
    /// simply lost.
    @discardableResult
    static func push(_ record: ConsentRecord, deviceID: String) async -> Bool {
        guard !baseURL.isEmpty, let url = URL(string: "\(baseURL)/consent") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let formatter = ISO8601DateFormatter()
        let payload: [String: Any?] = [
            "device_id": deviceID,
            "consent_version": record.consentVersion,
            "status": record.status.rawValue,
            "granted_at": record.grantedAt.map(formatter.string),
            "revoked_at": record.revokedAt.map(formatter.string)
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload.compactMapValues { $0 }) else {
            return false
        }
        request.httpBody = body
        // Present on every push after the first: the Worker only lets an
        // already-registered device change its own record with a valid token.
        authorize(&request)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            return false
        }

        // First registration returns the device's API token, once and only
        // once. Persist it immediately — it can't be requested again, and
        // without it this device can't upload or erase.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = json["device_token"] as? String, !token.isEmpty {
            DeviceIdentity.storeToken(token)
        }
        return true
    }

    /// Attaches the device's bearer token when it has one. A request without it
    /// is rejected by every route except the first-registration `POST /consent`.
    static func authorize(_ request: inout URLRequest) {
        guard let token = DeviceIdentity.currentToken else { return }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    /// GDPR-style full erasure — deletes the D1 consent row AND every R2 object
    /// under this device_id (see the Worker's `handleErase`). Distinct from
    /// `push(_:deviceID:)` with `.revoked`, which only stops future uploads;
    /// this is the destructive action gated behind the app's type-to-confirm
    /// UI. Returns the number of objects deleted on success, nil on any
    /// failure (network error, non-200, Worker not deployed) so the caller can
    /// tell the user the request didn't go through rather than assuming success.
    static func eraseAllData(deviceID: String) async -> Int? {
        guard !baseURL.isEmpty, var components = URLComponents(string: "\(baseURL)/consent") else { return nil }
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        authorize(&request)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let deletedObjects = json["deletedObjects"] as? Int else {
            return nil
        }
        return deletedObjects
    }

    /// Phase 6 uploads call this before accepting a file for a given device.
    static func fetchStatus(deviceID: String) async -> ConsentStatus? {
        guard !baseURL.isEmpty,
              var components = URLComponents(string: "\(baseURL)/consent") else { return nil }
        components.queryItems = [URLQueryItem(name: "device_id", value: deviceID)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        authorize(&request)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let statusString = json["status"] as? String else {
            return nil
        }
        return ConsentStatus(rawValue: statusString)
    }
}
