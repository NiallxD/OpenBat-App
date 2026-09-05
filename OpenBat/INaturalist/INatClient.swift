//
//  INatClient.swift
//  OpenBat
//
//  The four calls OpenBat makes to iNaturalist, and nothing else.
//
//    GET  /taxa                 resolve a scientific name to a taxon id, cached
//    GET  /observations/{uuid}  has this recording already been posted?
//    POST /observations         create one, on the user's own account
//    POST /observation_photos   attach the spectrogram
//    POST /observation_sounds   attach the audible copy and the original
//
//  No background posting, no bulk upload of a night in one action, no writes to
//  anyone else's records, no crawling. Every call here is downstream of a tap
//  on `INatObservationSheet`.
//
//  DUPLICATES ARE PREVENTED BY UUID, NOT BY SEARCHING
//  --------------------------------------------------
//  v2 lets the client choose an observation's UUID, and OpenBat derives that
//  UUID from the recording — so the same recording is always the same
//  observation. A tap that times out and is retried re-sends the same UUID and
//  either creates the record or finds it already there; it cannot make two.
//  That is strictly better than the "search for something at the same time and
//  place" check, which cannot tell a retry from a genuine second bat.
//
//  WHY V2 AND WHY A JWT
//  --------------------
//  v1 has no sound endpoint at all, which for an acoustic app is the whole
//  point. v2 has one, and every write on v2 is `userJwtRequired` — the OAuth
//  access token is NOT accepted directly. `INatAuth.apiToken()` is the bridge.
//
//  UPLOADS ARE STREAMED FROM DISK
//  ------------------------------
//  A 384 kHz recording is tens of megabytes and the audible copy is exactly the
//  same size (it is a header rewrite, not a resample). Multipart bodies are
//  therefore assembled into a temporary file and handed to
//  `URLSession.upload(fromFile:)`, so a long recording never sits in memory
//  twice while the phone is also drawing a spectrogram.
//

import Foundation

nonisolated enum INatClient {

    enum Failure: LocalizedError {
        case http(Int, String?)
        case malformedResponse
        case soundTooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .http(422, let detail):
                // 422 is the one iNaturalist uses for "this observation isn't
                // acceptable", and its message is worth showing verbatim.
                return detail ?? "iNaturalist rejected the observation."
            case .http(let code, _):
                return "iNaturalist returned HTTP \(code)."
            case .malformedResponse:
                return "iNaturalist's reply wasn't in the expected form."
            case .soundTooLarge(let bytes):
                return String(format: "The recording is %.0f MB and iNaturalist's limit for sound is %d MB.",
                              Double(bytes) / 1_048_576, INatCredentials.maxSoundBytes / 1_048_576)
            }
        }
    }

    /// What actually happened, so the sheet can be honest about a partial
    /// success. An observation whose sound was too big is still a real
    /// observation and must not be reported as a failure — nor as a clean win.
    struct PostResult {
        let uuid: UUID
        let webURL: URL
        var attachedPhoto = false
        var attachedSounds = 0
        /// Human-readable, already user-facing. Empty on a clean post.
        var skipped: [String] = []
        var alreadyExisted = false
    }

    // MARK: Posting

    /// Creates the observation and attaches its media, in that order because
    /// the attachments need the observation's UUID.
    ///
    /// Media failures are collected rather than thrown: once the observation
    /// exists, throwing would tell the user their post failed when in fact it
    /// is on their account, and they would post it again.
    static func post(_ observation: INatObservation,
                     geoprivacy: INatGeoprivacy,
                     taxonID: Int?,
                     spectrogramPNG: Data?,
                     sounds: [URL]) async throws -> PostResult {
        let uuid = observation.observationUUID
        var result = PostResult(uuid: uuid, webURL: webURL(for: uuid))

        if try await observationExists(uuid: uuid) {
            // A retry after a timeout, or the same recording posted twice. The
            // record is already there; attaching its media again would just
            // duplicate the attachments.
            result.alreadyExisted = true
            return result
        }

        try await create(observation, uuid: uuid, geoprivacy: geoprivacy, taxonID: taxonID)

        if let spectrogramPNG {
            do {
                try await attach(data: spectrogramPNG,
                                 filename: "spectrogram.png",
                                 mimeType: "image/png",
                                 to: uuid,
                                 path: "observation_photos",
                                 field: "observation_photo")
                result.attachedPhoto = true
            } catch {
                result.skipped.append("The spectrogram didn't upload (\(error.localizedDescription))")
            }
        }

        for sound in sounds {
            let bytes = (try? FileManager.default.attributesOfItem(atPath: sound.path)[.size] as? Int) ?? nil
            if let bytes, bytes > INatCredentials.maxSoundBytes {
                result.skipped.append("\(sound.lastPathComponent) is \(bytes / 1_048_576) MB, over iNaturalist's \(INatCredentials.maxSoundBytes / 1_048_576) MB limit for sound")
                continue
            }
            do {
                try await attach(fileURL: sound,
                                 mimeType: "audio/wav",
                                 to: uuid,
                                 path: "observation_sounds",
                                 field: "observation_sound")
                result.attachedSounds += 1
            } catch {
                result.skipped.append("\(sound.lastPathComponent) didn't upload (\(error.localizedDescription))")
            }
        }

        return result
    }

    /// Where the user goes to look at what they just posted. UUIDs work in
    /// place of ids in iNaturalist's own URLs, which saves reading an id back.
    static func webURL(for uuid: UUID) -> URL {
        URL(string: "https://www.inaturalist.org/observations/\(uuid.uuidString.lowercased())")!
    }

    private static func create(_ observation: INatObservation,
                               uuid: UUID,
                               geoprivacy: INatGeoprivacy,
                               taxonID: Int?) async throws {
        var fields: [String: Any] = [
            "uuid": uuid.uuidString.lowercased(),
            "observed_on_string": observation.observedOn,
            "description": observation.notes,
            "geoprivacy": geoprivacy.rawValue,
            // The claim is the user's, and iNaturalist's own vision suggestions
            // set this flag; ours is not iNat's vision, so it stays false.
            "owners_identification_from_vision": false
        ]
        // `species_guess` goes along regardless: if the taxon id didn't
        // resolve, this is what a human reads to work out what was meant.
        fields["species_guess"] = observation.taxonName
        if let taxonID { fields["taxon_id"] = taxonID }
        if let latitude = observation.latitude, let longitude = observation.longitude {
            fields["latitude"] = latitude
            fields["longitude"] = longitude
        }

        var request = try await authorized(URL(string: "observations", relativeTo: INatCredentials.apiBase)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // v2 returns nothing but the id unless asked; `uuid` back confirms the
        // server kept the one we chose.
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "observation": fields,
            "fields": ["id": true, "uuid": true]
        ])

        _ = try await send(request)
    }

    private static func observationExists(uuid: UUID) async throws -> Bool {
        var components = URLComponents(url: URL(string: "observations/\(uuid.uuidString.lowercased())",
                                                relativeTo: INatCredentials.apiBase)!,
                                       resolvingAgainstBaseURL: true)!
        components.queryItems = [.init(name: "fields", value: "id")]
        let request = try await authorized(components.url!)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return false }
        guard status == 200 else { throw Failure.http(status, nil) }
        // v2 answers a missing record with 200 and an empty results array as
        // readily as with a 404, so the count is what actually decides.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let count = json["total_results"] as? Int else {
            throw Failure.malformedResponse
        }
        return count > 0
    }

    // MARK: Attachments

    private static func attach(data: Data,
                               filename: String,
                               mimeType: String,
                               to uuid: UUID,
                               path: String,
                               field: String) async throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("inat-\(UUID().uuidString)")
        try data.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await attach(fileURL: temporary, filename: filename, mimeType: mimeType,
                         to: uuid, path: path, field: field)
    }

    private static func attach(fileURL: URL,
                               filename: String? = nil,
                               mimeType: String,
                               to uuid: UUID,
                               path: String,
                               field: String) async throws {
        let boundary = "openbat.\(UUID().uuidString)"
        let body = try multipartFile(fileURL: fileURL,
                                     filename: filename ?? fileURL.lastPathComponent,
                                     mimeType: mimeType,
                                     boundary: boundary,
                                     fields: ["\(field)[observation_id]": uuid.uuidString.lowercased()])
        defer { try? FileManager.default.removeItem(at: body) }

        var request = try await authorized(URL(string: path, relativeTo: INatCredentials.apiBase)!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else { throw Failure.http(status, nil) }
    }

    /// Writes the multipart envelope around a file without reading the file
    /// into memory — see this file's header.
    private static func multipartFile(fileURL: URL,
                                      filename: String,
                                      mimeType: String,
                                      boundary: String,
                                      fields: [String: String]) throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("inat-body-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        var preamble = ""
        for (name, value) in fields {
            preamble += "--\(boundary)\r\n"
            preamble += "Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n"
            preamble += "\(value)\r\n"
        }
        preamble += "--\(boundary)\r\n"
        preamble += "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        preamble += "Content-Type: \(mimeType)\r\n\r\n"
        try handle.write(contentsOf: Data(preamble.utf8))

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let block = try input.read(upToCount: 1 << 20), !block.isEmpty {
            try handle.write(contentsOf: block)
        }
        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return output
    }

    // MARK: Taxa

    /// Scientific name to taxon id, so the observation carries a real
    /// identification rather than a string iNaturalist has to guess at.
    ///
    /// Cached in UserDefaults and never invalidated on purpose: taxon ids are
    /// stable, the mapping is tiny, and the alternative is a network round trip
    /// standing in a field at night. A rename would leave a stale id pointing
    /// at a taxon iNaturalist still resolves, which is the harmless direction.
    ///
    /// Returns nil rather than throwing: a post with `species_guess` and no id
    /// is a perfectly good observation, and failing the whole thing because a
    /// lookup timed out would be the wrong trade.
    static func taxonID(for scientificName: String) async -> Int? {
        let key = "openbat.inat.taxon.\(scientificName)"
        let defaults = UserDefaults.standard
        if let cached = defaults.object(forKey: key) as? Int { return cached }

        var components = URLComponents(url: URL(string: "taxa", relativeTo: INatCredentials.apiBase)!,
                                       resolvingAgainstBaseURL: true)!
        components.queryItems = [
            .init(name: "q", value: scientificName),
            .init(name: "per_page", value: "1"),
            .init(name: "is_active", value: "true"),
            .init(name: "fields", value: "id,name,rank")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(INatCredentials.userAgent, forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]],
              let first = results.first,
              let id = first["id"] as? Int else {
            return nil
        }
        // Only trust an exact name match. `q` is a fuzzy search, and the first
        // result for a name iNaturalist doesn't have is some other bat — an
        // observation posted under the wrong taxon is worse than one posted
        // with no taxon at all.
        guard (first["name"] as? String)?.caseInsensitiveCompare(scientificName) == .orderedSame else {
            return nil
        }
        defaults.set(id, forKey: key)
        return id
    }

    // MARK: Plumbing

    private static func authorized(_ url: URL) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await INatAuth.shared.apiToken())",
                         forHTTPHeaderField: "Authorization")
        request.setValue(INatCredentials.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    @discardableResult
    private static func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            throw Failure.http(status, errorDetail(from: data))
        }
        return data
    }

    /// iNaturalist's validation errors are the useful half of a 422 — "must
    /// have a date", "coordinates are outside the world" — and a user can act
    /// on them, which they cannot do with a status code.
    private static func errorDetail(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? String { return error }
        if let errors = json["errors"] as? [String], !errors.isEmpty {
            return errors.joined(separator: " ")
        }
        return nil
    }
}
