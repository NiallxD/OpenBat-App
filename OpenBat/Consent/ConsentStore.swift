//
//  ConsentStore.swift
//  OpenBat
//
//  Current consent state for uploading recordings to the community science
//  project — stored as a single current record (granted/revoked), not an
//  append-only log, since a log of "granted" events alone can't represent
//  withdrawal. Persisted in the Keychain next to DeviceIdentity so it survives
//  reinstall the same way the device ID does.
//

import Foundation
import Security
import Observation

/// `nonisolated`: persisted and pushed from `ConsentSync`'s background retry,
/// so its `Codable` conformance has to be usable off the main actor.
nonisolated enum ConsentStatus: String, Codable {
    case granted
    case revoked
}

/// `nonisolated`: same reasoning as `ConsentStatus` — encoded/decoded by
/// `ConsentRecordStorage` from whichever thread a retry happens to run on.
nonisolated struct ConsentRecord: Codable {
    var consentVersion: String
    var status: ConsentStatus
    var grantedAt: Date?
    var revokedAt: Date?
    /// When the Worker last confirmed (2xx) that it holds *this exact* state.
    /// `nil` means unconfirmed — the push failed, never ran, or the device was
    /// offline at the time. Optional rather than a defaulted `Bool` so records
    /// written before this field existed decode as "unconfirmed" and get
    /// re-pushed once; the endpoint is an idempotent upsert, so a redundant
    /// push costs nothing and a missed one is a compliance problem.
    var syncedAt: Date?

    var needsSync: Bool { syncedAt == nil }
}

/// Keychain persistence for the consent record, shared by `ConsentStore` (which
/// owns the observable copy the UI binds to) and `ConsentSync` (which retries
/// unconfirmed pushes in the background, possibly with no `ConsentStore` alive).
/// `kSecAttrAccessibleAfterFirstUnlock` so a retry can run while the device is
/// locked.
nonisolated enum ConsentRecordStorage {
    private static let service = "com.openbat.deviceIdentity"
    private static let account = "consentRecord"

    static func read() -> ConsentRecord? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ConsentRecord.self, from: data)
    }

    @discardableResult
    static func write(_ record: ConsentRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@Observable
final class ConsentStore {
    /// The single instance. Consent state has exactly one source of truth (the
    /// Keychain), so it should have exactly one observable representation too.
    ///
    /// There used to be two — one owned by `OnboardingView`, one by
    /// `ContentView`. That worked only because `OpenBatApp` never shows both at
    /// once: with two live instances, a `grant()`/`revoke()` on one left the
    /// other reporting the old value, because the refresh notification only
    /// fires when a *sync* completes. Offline, the stale one would never catch
    /// up. `ConsentView`'s own header comment already describes a Settings entry
    /// point that would create exactly that situation, so this closes it before
    /// someone adds that screen and inherits a consent toggle showing the wrong
    /// state.
    static let shared = ConsentStore()

    /// Bump whenever the consent copy (PrivacyNoticeView / ConsentView) changes materially,
    /// so a stored record always says which text a device actually agreed to.
    static let currentConsentVersion = "1.0"

    private(set) var record: ConsentRecord?

    /// Refreshes this observable copy when `ConsentSync` confirms a push —
    /// there are two `ConsentStore` instances in this app (onboarding and
    /// ContentView), and the Keychain is the single source of truth both follow.
    @ObservationIgnored private var syncObserver: NSObjectProtocol?

    private init() {
        record = ConsentRecordStorage.read()
        syncObserver = NotificationCenter.default.addObserver(
            forName: ConsentSync.recordDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.record = ConsentRecordStorage.read() }
            }
        // Anything left unconfirmed by a previous run (offline at the time, app
        // killed mid-request) gets another attempt as soon as there's a network.
        ConsentSync.start()
    }

    deinit {
        if let syncObserver { NotificationCenter.default.removeObserver(syncObserver) }
    }

    var isGranted: Bool { record?.status == .granted }

    /// True when the user's current choice hasn't been confirmed by the server
    /// yet. Surfaced in Settings so a withdrawal that hasn't propagated isn't
    /// silently presented as complete.
    var isAwaitingServerConfirmation: Bool { record?.needsSync == true }

    func grant() {
        apply(ConsentRecord(consentVersion: Self.currentConsentVersion,
                            status: .granted,
                            grantedAt: Date(),
                            revokedAt: record?.revokedAt,
                            syncedAt: nil))
    }

    func revoke() {
        // Revoking with no prior record still creates one — an explicit
        // "never consented" is more useful downstream than silence.
        var updated = record ?? ConsentRecord(consentVersion: Self.currentConsentVersion,
                                              status: .revoked, grantedAt: nil,
                                              revokedAt: nil, syncedAt: nil)
        updated.consentVersion = Self.currentConsentVersion
        updated.status = .revoked
        updated.revokedAt = Date()
        apply(updated)
    }

    /// Persists a new decision as unconfirmed, then asks `ConsentSync` to push
    /// it. `syncedAt` is deliberately cleared here rather than set optimistically
    /// on send: until the Worker returns 2xx, the server's copy does NOT reflect
    /// this choice, and a retry has to keep happening until it does.
    private func apply(_ updated: ConsentRecord) {
        var updated = updated
        updated.syncedAt = nil
        record = updated
        ConsentRecordStorage.write(updated)
        ConsentSync.syncIfNeeded()
    }

    /// GDPR-style full erasure — distinct from `revoke()`, which only stops
    /// future uploads. Deletes the D1 row and every past R2 recording for this
    /// device (see the Worker's `handleErase`), then wipes the local consent
    /// record and rotates the device ID, so no future activity can be
    /// correlated back to what was just erased. The app's UI gates this
    /// behind an explicit type-to-confirm step before ever calling it.
    ///
    /// Returns the number of recordings deleted on success, nil if the
    /// request failed (network error, Worker unreachable) — callers must NOT
    /// clear any of their own local state on nil, since nothing was actually erased.
    func eraseAllData() async -> Int? {
        // Fence first. Any upload still in flight was authorised under the
        // device_id about to be erased, and a transfer that lands AFTER the
        // Worker's list-and-delete sweep re-creates an object under the very
        // prefix just cleared — leaving data behind that the user was told was
        // gone, and (since the D1 row goes too) that the app can no longer see.
        // Cancelling before the request closes that window rather than relying
        // on the Worker's consent check to 403 the straggler.
        await RecordingUploader.shared.cancelAllUploads()
        // Same fence for the consent mirror: an unconfirmed push still in flight
        // would otherwise re-create the D1 row straight after the erase removed it.
        await ConsentSync.suspend()
        defer { ConsentSync.resume() }

        guard let deletedObjects = await ConsentAPIClient.eraseAllData(deviceID: DeviceIdentity.current) else {
            return nil
        }
        ConsentRecordStorage.delete()
        record = nil
        DeviceIdentity.regenerate()
        return deletedObjects
    }
}
