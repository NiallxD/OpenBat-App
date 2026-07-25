//
//  DeviceIdentity.swift
//  OpenBat
//

import Foundation
import Security

/// App-controlled device identifier, independent of `identifierForVendor` (which resets on
/// reinstall). Generated once and persisted in the Keychain so it survives reinstalls — this
/// is the identifier consent records and recording metadata key against.
/// `nonisolated`: stateless Keychain access (`SecItem*` is thread-safe), read
/// from `RecordingUploader`'s off-main upload path as well as the main actor.
nonisolated enum DeviceIdentity {
    private static let service = "com.openbat.deviceIdentity"
    private static let account = "deviceID"
    private static let tokenAccount = "deviceToken"

    /// Stable UUID string for this device, creating and persisting one on first access.
    static var current: String {
        if let existing = read(account: account) {
            return existing
        }
        let generated = UUID().uuidString
        write(generated, account: account)
        return generated
    }

    /// The Worker-issued API token for `current`, if this device has registered
    /// yet. Handed out exactly once, on the first `POST /consent` (see the
    /// Worker's `issueDeviceToken`), and required on every upload and on
    /// erasure — the device_id alone is no longer sufficient authority, since
    /// the app displays it with a Copy button and invites users to quote it.
    ///
    /// Stored beside the device id so the two survive (and are lost) together:
    /// both live in the Keychain across reinstalls.
    static var currentToken: String? { read(account: tokenAccount) }

    static func storeToken(_ token: String) {
        write(token, account: tokenAccount)
    }

    /// Called only after a successful `ConsentStore.eraseAllData()` — a fresh
    /// ID means no future recording/upload can be correlated back to the
    /// device_id that was just erased server-side. The old token is dropped
    /// with it: it authenticates the OLD id and is meaningless for the new one,
    /// which re-registers (and is issued a fresh token) on its next consent grant.
    static func regenerate() {
        write(UUID().uuidString, account: account)
        delete(account: tokenAccount)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    @discardableResult
    private static func write(_ value: String, account: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Reinstall can leave a Keychain item behind (Keychain items outlive app deletion by
        // default), so this only ever runs when read() found nothing — clear defensively first.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
