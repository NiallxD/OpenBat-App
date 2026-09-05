//
//  INatAuth.swift
//  OpenBat
//
//  Signing in to iNaturalist, and holding the credential afterwards.
//
//  THE SHAPE OF THE FLOW
//  ---------------------
//  Three steps, and the third one is the part that surprises people:
//
//    1. OAuth 2 authorization code + PKCE, in ASWebAuthenticationSession, so
//       the user types their password into iNaturalist's own page in a browser
//       OpenBat cannot read. We never see a password.
//    2. Exchange the code for an OAuth ACCESS TOKEN. Long-lived; this is the
//       thing worth keeping, and the only thing in the Keychain.
//    3. Exchange the access token for a JWT at /users/api_token. THIS is what
//       api.inaturalist.org/v2 wants in its Authorization header — the OAuth
//       token on its own is rejected there. The JWT lasts about a day, so it
//       is cached in memory only and re-minted whenever it is missing or old.
//
//  PKCE MATTERS MORE THAN USUAL HERE
//  ---------------------------------
//  The redirect is a custom scheme (`openbat://`), and iOS does not guarantee
//  scheme uniqueness — another app can claim it and receive the code. PKCE is
//  what makes that harmless: the code cannot be exchanged without the verifier,
//  which never leaves this process. `state` is checked too, so a callback that
//  did not originate from a sign-in this app started is discarded.
//
//  WHO PRESENTS THE BROWSER
//  ------------------------
//  The view does, via SwiftUI's `\.webAuthenticationSession` environment value
//  rather than an ASWebAuthenticationSession we build ourselves — that avoids
//  needing a presentation-anchor delegate and a UIWindow reference, and it is
//  the reason sign-in is split into `beginSignIn()` / `finishSignIn(...)`
//  instead of being one call. See `INatSignInSection`.
//
//  WHAT IS STORED, AND WHERE
//  -------------------------
//  The access token, in the Keychain, `AfterFirstUnlock` so a post can finish
//  on a locked phone in a field bag. Nothing else persists: no username, no
//  profile, no observation history. Signing out deletes the item and forgets
//  the JWT, and the user can additionally revoke OpenBat from their iNaturalist
//  account settings, which invalidates it server-side.
//

import Foundation
import CryptoKit
import Security

/// One in-flight sign-in. Carries the verifier and state that the callback
/// will be checked against, so two overlapping attempts cannot be confused.
struct INatSignInRequest {
    let url: URL
    fileprivate let verifier: String
    fileprivate let state: String
}

enum INatAuthError: LocalizedError {
    case cancelled
    case denied(String)
    case badCallback
    case stateMismatch
    case tokenExchangeFailed(Int)
    case apiTokenFailed(Int)
    case notSignedIn

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Sign-in was cancelled."
        case .denied(let reason):
            return "iNaturalist declined the sign-in: \(reason)"
        case .badCallback:
            return "iNaturalist sent back something OpenBat couldn't read."
        case .stateMismatch:
            // Worth its own message rather than folding into badCallback: this
            // one means the callback didn't come from the sign-in we started.
            return "That sign-in didn't match the one OpenBat started, so it was ignored."
        case .tokenExchangeFailed(let code):
            return "Couldn't complete sign-in with iNaturalist (HTTP \(code))."
        case .apiTokenFailed(let code):
            return "Signed in, but couldn't get permission to post (HTTP \(code)). Try signing out and back in."
        case .notSignedIn:
            return "You're not signed in to iNaturalist."
        }
    }
}

@Observable
final class INatAuth {

    static let shared = INatAuth()

    /// Drives the UI. Mirrors "is there an access token in the Keychain",
    /// which is read once at init and then kept in step by hand — a Keychain
    /// query per view update would be wasteful and, worse, not observable.
    private(set) var isSignedIn: Bool

    /// The JWT and when it stops being usable. Memory only: it lives about 24
    /// hours, minting a fresh one costs a single request, and keeping a
    /// bearer credential no longer than needed is free.
    private var cachedAPIToken: (value: String, expires: Date)?

    private init() {
        isSignedIn = Self.accessToken != nil
    }

    // MARK: Signing in

    /// Step 1: build the authorization URL. The caller opens it in a web
    /// authentication session and hands the callback back to `finishSignIn`.
    func beginSignIn() -> INatSignInRequest {
        let verifier = Self.randomURLSafeString()
        let state = Self.randomURLSafeString()
        let challenge = Self.challenge(for: verifier)

        var components = URLComponents(url: INatCredentials.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "client_id", value: INatCredentials.clientID),
            .init(name: "redirect_uri", value: INatCredentials.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        return INatSignInRequest(url: components.url!, verifier: verifier, state: state)
    }

    /// Steps 2 and 3: exchange the callback's code for an access token, store
    /// it, and immediately mint a JWT — so a sign-in that looks like it worked
    /// but cannot actually post fails here, on the sign-in button, rather than
    /// later on the user's first attempt to post an observation.
    func finishSignIn(callback: URL, request: INatSignInRequest) async throws {
        guard let components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              let items = components.queryItems else {
            throw INatAuthError.badCallback
        }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        if let error = value("error") {
            throw error == "access_denied" ? INatAuthError.cancelled : INatAuthError.denied(error)
        }
        guard value("state") == request.state else { throw INatAuthError.stateMismatch }
        guard let code = value("code") else { throw INatAuthError.badCallback }

        INatLog.shared.note("callback received, state matched; exchanging the code")
        let token = try await exchange(code: code, verifier: request.verifier)
        Self.store(accessToken: token)
        isSignedIn = true
        do {
            _ = try await apiToken()
        } catch {
            // A token we can't turn into an API credential is worse than none:
            // it would leave the UI claiming a working connection.
            signOut()
            throw error
        }
    }

    func signOut() {
        Self.deleteAccessToken()
        cachedAPIToken = nil
        isSignedIn = false
    }

    // MARK: The credential the API actually wants

    /// The JWT for api.inaturalist.org, minting one if there isn't a live one.
    ///
    /// Re-minted a few minutes before it actually expires: an upload of a
    /// 20 MB sound file can be in flight for a while, and a token that dies
    /// mid-request fails the whole attachment.
    func apiToken() async throws -> String {
        if let cached = cachedAPIToken, cached.expires > .now {
            return cached.value
        }
        guard let access = Self.accessToken else { throw INatAuthError.notSignedIn }

        var request = URLRequest(url: INatCredentials.apiTokenURL)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        request.setValue(INatCredentials.userAgent, forHTTPHeaderField: "User-Agent")

        INatLog.shared.request("GET", INatCredentials.apiTokenURL, authorized: true)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        INatLog.shared.response("GET", INatCredentials.apiTokenURL,
                                status: status, seconds: 0, body: data)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["api_token"] as? String else {
            // 401 here means the user revoked OpenBat from their iNaturalist
            // settings. Dropping the access token turns that into a plain
            // "signed out" rather than an error they can only clear by
            // reinstalling.
            if status == 401 {
                INatLog.shared.note("401 minting the API token — access revoked on iNaturalist's side; signing out")
                signOut()
            }
            throw INatAuthError.apiTokenFailed(status)
        }
        INatLog.shared.note("minted a fresh API token, good for 20 hours")
        cachedAPIToken = (token, .now.addingTimeInterval(20 * 60 * 60))
        return token
    }

    private func exchange(code: String, verifier: String) async throws -> String {
        var request = URLRequest(url: INatCredentials.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(INatCredentials.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Self.formEncoded([
            "client_id": INatCredentials.clientID,
            "code": code,
            "redirect_uri": INatCredentials.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ])

        INatLog.shared.request("POST", INatCredentials.tokenURL, authorized: false,
                               body: "grant_type=authorization_code, PKCE S256")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        INatLog.shared.response("POST", INatCredentials.tokenURL,
                                status: status, seconds: 0, body: data)
        guard status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw INatAuthError.tokenExchangeFailed(status)
        }
        return token
    }

    // MARK: PKCE

    /// 32 random bytes, base64url. Long enough to be a valid verifier and
    /// short enough to sit in a URL; the same generator serves `state`.
    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        // A failure here would mean a predictable verifier, which is exactly
        // the thing PKCE exists to prevent — so it is fatal rather than
        // silently falling back to something weaker.
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed")
        }
        return base64URL(Data(bytes))
    }

    private static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ pairs: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = pairs.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` is a literal plus in a query but means space in a form body, and
        // an unescaped one in a PKCE verifier would break the exchange.
        return Data((components.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B").utf8)
    }

    // MARK: Keychain

    // Deliberately its own service name rather than sharing DeviceIdentity's:
    // that one is about the consent backend, this is a third-party credential,
    // and "erase all my consent data" must not silently sign the user out of
    // iNaturalist (or the reverse).
    private static let service = "com.openbat.inaturalist"
    private static let account = "oauthAccessToken"

    private static var accessToken: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func store(accessToken: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // SecItemAdd refuses a duplicate rather than replacing it, and a
        // Keychain item outlives app deletion — so a reinstall can find a
        // stale token sitting here.
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(accessToken.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func deleteAccessToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
