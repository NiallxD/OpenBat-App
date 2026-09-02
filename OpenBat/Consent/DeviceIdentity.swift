//
//  DeviceIdentity.swift
//  OpenBat
//
//  The app-controlled device identifier and its Worker-issued API token. This
//  is what consent records and uploads key against — never let anything
//  derived from it reach `AnonymizedUploadBuilder`'s output.
//
//  **The id used to live in the Keychain specifically so it would outlive
//  deleting the app** (2026-08-31: it no longer does). Keychain items survive
//  app deletion, so a reinstall was handed back the same identifier — which is
//  the definition of a persistent cross-install device identifier, and reads
//  to App Review as fingerprinting no matter what it is actually used for
//  (Guideline 5.1.1/5.1.2). The old header said so in as many words:
//  "independent of identifierForVendor, which resets on reinstall; this one
//  survives".
//
//  It now lives in UserDefaults, which iOS *does* erase with the app. The
//  practical difference: deleting OpenBat now genuinely ends the identity, and
//  a reinstall is a new device as far as any future contribution backend is
//  concerned. Nothing else changes — every call site is unchanged, and the
//  contribution feature revives as-is when `uploadContributionEnabled` flips.
//
//  The token stays in the Keychain, which is what the Keychain is actually
//  for: it is a bearer credential, not an identifier. It cannot outlive the id
//  though — see `current`, which drops a stranded token the moment it finds
//  itself on a fresh install. A token that survived its id would authenticate
//  an id the server has never heard of, and 401 forever.
//
//  Note this is all dark at launch: `ConsentAPIClient`/`UploadClient` have
//  empty base URLs, so no id and no token ever leaves the device, and no token
//  is ever issued. This is about what the code would do the day that changes.
//
//  `nonisolated`: UserDefaults and Keychain access (`SecItem*`) are both
//  thread-safe; called from the main actor and from `RecordingUploader`'s
//  off-main upload path. Deliberately no UIKit here — `identifierForVendor`
//  would have been the other reasonable choice, but `UIDevice` is main-actor
//  isolated and this type has to answer off-main.
//

import Foundation
import Security

nonisolated enum DeviceIdentity {
    private static let service = "com.openbat.deviceIdentity"
    private static let tokenAccount = "deviceToken"
    private static let defaultsKey = "openbat.deviceID"

    /// Stable UUID string for this install, creating and persisting one on
    /// first access. Stable for as long as the app is installed; a delete and
    /// reinstall is a different device.
    ///
    /// Minting one is also how a fresh install is detected, and that is the
    /// only moment a leftover Keychain token can be caught — hence the delete
    /// on the mint path rather than somewhere in app startup.
    static var current: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: defaultsKey) {
            return existing
        }
        // No id: either genuinely first run, or a reinstall that took the id
        // with it. Either way any token still in the Keychain belongs to an id
        // that no longer exists.
        delete(account: tokenAccount)
        let generated = UUID().uuidString
        defaults.set(generated, forKey: defaultsKey)
        return generated
    }

    /// The Worker-issued API token for `current`, if this device has registered
    /// yet. Handed out exactly once, on the first `POST /consent` (see the
    /// Worker's `issueDeviceToken`), and required on every upload and on
    /// erasure — the device_id alone is no longer sufficient authority, since
    /// the app displays it with a Copy button and invites users to quote it.
    static var currentToken: String? { read(account: tokenAccount) }

    static func storeToken(_ token: String) {
        write(token, account: tokenAccount)
    }

    /// Called only after a successful `ConsentStore.eraseAllData()` — a fresh
    /// ID means no future recording/upload can be correlated back to the
    /// device_id that was just erased server-side. The old token is dropped
    /// with it: it authenticates the OLD id and is meaningless for the new one,
    /// which re-registers (and is issued a fresh token) on its next consent
    /// grant.
    static func regenerate() {
        UserDefaults.standard.set(UUID().uuidString, forKey: defaultsKey)
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
        // Clear defensively first: a reinstall can leave a Keychain item behind
        // (Keychain items outlive app deletion by default — which is the whole
        // reason the id moved out, see this file's header), and SecItemAdd on
        // an existing item fails with errSecDuplicateItem rather than replacing.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
}
