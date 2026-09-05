//
//  INatCredentials.swift
//  OpenBat
//
//  The registered OAuth application, and the endpoints it talks to.
//
//  WHY THERE IS NO CLIENT SECRET HERE
//  ----------------------------------
//  iNaturalist issued one, and it is deliberately not in this file. The
//  application is registered as a PUBLIC client (`Confidential: false`), which
//  is the correct registration for a native app: anything shipped inside an
//  iOS binary can be extracted from it, so a "secret" in an App Store app is
//  not a secret and must not be treated as one. PKCE is what actually protects
//  the flow — the authorization code is useless to anyone who did not generate
//  the verifier — and PKCE needs no secret.
//
//  If a secret is ever genuinely needed it means the exchange has moved to a
//  server, and it belongs there, not here.
//
//  TWO HOSTS, AND THEY ARE NOT INTERCHANGEABLE
//  -------------------------------------------
//    inaturalist.org      the Rails site: the OAuth dance, and the endpoint
//                         that turns an OAuth token into the API's JWT.
//    api.inaturalist.org  the API proper. v2, not v1 — see below.
//
//  V2, NOT V1
//  ----------
//  v1 has `POST /observation_photos` but no sound route at all, which for an
//  acoustic app is the whole point of the exercise. v2 documents
//  `/observations`, `/observation_photos` AND `/observation_sounds`, and
//  addresses observations by a UUID the client chooses, which is what makes a
//  retry safe (see `INatClient`).
//

import Foundation

nonisolated enum INatCredentials {

    /// Registered at inaturalist.org/oauth/applications. Public client.
    static let clientID = "9aKxf54z8Ne3LjGK08gueTyQQk7Xup10isfGfmpSYbs"

    /// Must match the registration character for character, and the scheme
    /// must be declared in CFBundleURLTypes or the callback never arrives.
    static let redirectURI = "openbat://oauth-callback"
    static let callbackScheme = "openbat"

    static let authorizeURL = URL(string: "https://www.inaturalist.org/oauth/authorize")!
    static let tokenURL = URL(string: "https://www.inaturalist.org/oauth/token")!

    /// Trades the OAuth access token for the JWT that api.inaturalist.org
    /// actually accepts. See `INatAuth.apiToken`.
    static let apiTokenURL = URL(string: "https://www.inaturalist.org/users/api_token")!

    static let apiBase = URL(string: "https://api.inaturalist.org/v2")!

    /// iNaturalist asks that API clients identify themselves, and a request
    /// they can attribute is one they can ask about rather than simply block.
    static let userAgent = "OpenBat/1.0 (iOS; +https://openbat.org)"

    /// iNaturalist rejects sound files over this size. It bites harder here
    /// than it looks: `INatExport.audibleCopy` rewrites the header rather than
    /// resampling, so the audible copy is exactly as many bytes as the
    /// original — if one is too big, both are.
    static let maxSoundBytes = 20 * 1024 * 1024
}
