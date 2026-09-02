//
//  ConsentStore.swift
//  OpenBat
//
//  Current consent state for uploading recordings to the community science
//  project — stored as a single current record (granted/revoked), not an
//  append-only log, since a log of "granted" events alone can't represent
//  withdrawal. Persisted in the Keychain, so it survives reinstall — a
//  withdrawal in particular must not be forgotten by deleting the app.
//
//  It no longer survives *alongside* the device id, which moved to UserDefaults
//  on 2026-08-31 (see `DeviceIdentity`) and so is now erased with the app. A
//  reinstall therefore has a record but a new id and no token, which is exactly
//  the case `ConsentSync.pushIsDue` already treats as due: it re-pushes, the
//  Worker registers the new id, and a fresh token comes back.
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
    /// Two live instances (there used to be one each for onboarding and
    /// `ContentView`) can disagree while offline: `grant()`/`revoke()` on one
    /// leaves the other stale, since the refresh notification only fires when
    /// a sync completes.
    static let shared = ConsentStore()

    /// Bump whenever the consent copy (PrivacyNoticeView / ConsentView) changes
    /// materially, so a stored record always says which text a device actually
    /// agreed to. A device that agreed to an older version is re-shown the
    /// current one rather than being silently carried forward — see
    /// `needsReconsent`.
    ///
    /// 2.0 made contributions fully anonymous (no device identifier or display
    /// name; unconditional location/time fuzzing) and disclosed that the
    /// consequence — contributed recordings can no longer be identified or
    /// deleted on request — up front. 3.0 dropped the commercial/licensing use
    /// case entirely (research use only) and removed the second consent toggle
    /// that gated it.
    ///
    /// Bumping this requires bumping `CURRENT_CONSENT_VERSION` in
    /// `backend/consent-worker/src/index.ts` in the same deploy — see
    /// `ConsentVersionTests.currentVersionIsTheExpectedValue`.
    static let currentConsentVersion = "3.0"

    /// Contribution is temporarily disabled for launch: a recording can only be
    /// verified as "reference" quality via non-acoustic ID (visual/in-hand),
    /// which this app has no way to provide — every species tag it produces is
    /// its own acoustic AutoID guess. Onboarding's consent step is removed and
    /// Settings' toggle is forced off/disabled while this is false; the network
    /// clients (`UploadClient`, `ConsentAPIClient`) are also severed from the
    /// Worker as a second, independent safeguard. Flip this back on only once
    /// that verification gap is addressed, and restore the severed base URLs.
    static let uploadContributionEnabled = false

    private(set) var record: ConsentRecord?

    /// Refreshes this observable copy when `ConsentSync` confirms a push. The
    /// Keychain is the source of truth; this observable only mirrors it, and a
    /// push can complete from a background retry with no UI involved.
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

    /// Whether this device has an active grant **for the terms currently in the
    /// app**. Gates every upload path.
    ///
    /// Version-aware, not just status-aware. `currentConsentVersion` is bumped
    /// whenever the consent wording changes materially — so a record saying
    /// "granted, version 1.0" while the app presents 2.0 describes agreement to
    /// text this build no longer shows. Treating that as live consent would mean
    /// contributing recordings under terms the user never saw, which is exactly
    /// the failure the version field exists to prevent. Recording the version and
    /// then ignoring it is worse than not recording it, because it looks like a
    /// safeguard.
    ///
    /// Exact match rather than an ordering comparison: any bump is by definition
    /// a material change, and a stored version that isn't the current one — older
    /// or, through a downgrade, newer — is one this build cannot claim the user
    /// agreed to.
    ///
    /// Fails closed. A stale record stops uploads immediately and silently; it is
    /// `needsReconsent` that makes the situation visible and recoverable.
    var isGranted: Bool {
        guard let record, record.status == .granted else { return false }
        return record.consentVersion == Self.currentConsentVersion
    }

    /// True when the user *did* agree, under wording that has since changed, and
    /// hasn't been asked about the new wording yet.
    ///
    /// Distinct from simply never having consented: this person opted in and
    /// their contributions have now quietly stopped, so the UI owes them an
    /// explanation and a way to opt back in — see `SettingsView`'s review banner
    /// and the launch-time prompt in `ContentView`. Someone who declined, or who
    /// never decided, is not nagged.
    var needsReconsent: Bool {
        guard let record, record.status == .granted else { return false }
        return record.consentVersion != Self.currentConsentVersion
    }

    /// The wording this device actually agreed to, if any — shown alongside the
    /// review prompt so the change isn't asserted without saying what changed.
    var agreedConsentVersion: String? { record?.consentVersion }

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

    /// Erases the consent record held for this device — distinct from
    /// `revoke()`, which only flips status. Deletes the server-side D1 row, the
    /// local Keychain copy, and rotates the device ID so no future activity can
    /// be correlated back to the identity just erased. The UI gates this behind
    /// an explicit type-to-confirm step before ever calling it.
    ///
    /// Scope: the consent record only. Already-contributed recordings are not
    /// deleted and cannot be — see `ConsentAPIClient.eraseConsentRecord`. Callers
    /// must not tell the user otherwise.
    ///
    /// Returns false if the request failed (network error, Worker unreachable) —
    /// callers must NOT clear any of their own local state on false, since
    /// nothing was actually erased.
    func eraseConsentRecord() async -> Bool {
        // Fence first. Any upload still in flight was authorised against the
        // consent row about to be deleted; letting it land afterwards would mean
        // accepting a contribution for a device that, as far as the server is
        // then concerned, never consented. Cancelling closes that window rather
        // than relying on the Worker's consent check to 403 the straggler.
        //
        // Note this is about consent hygiene, not about clawing anything back:
        // an upload that already completed is anonymous and stays where it is.
        await RecordingUploader.shared.cancelAllUploads()
        // Same fence for the consent mirror: an unconfirmed push still in flight
        // would otherwise re-create the D1 row straight after the erase removed it.
        await ConsentSync.suspend()
        defer { ConsentSync.resume() }

        guard await ConsentAPIClient.eraseConsentRecord(deviceID: DeviceIdentity.current) else {
            return false
        }
        ConsentRecordStorage.delete()
        record = nil
        DeviceIdentity.regenerate()
        return true
    }
}
