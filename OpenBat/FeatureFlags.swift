//
//  FeatureFlags.swift
//  OpenBat
//
//  A switch, held in GitHub, for turning shipped features off after release.
//
//  WHY THIS EXISTS
//  ---------------
//  Once a build is on the App Store, the only way to change it is another
//  review. That is days, and it is days during which everybody who downloads
//  the app gets whatever is wrong with it. This file is the alternative: a
//  small JSON file in the app's own repo that every launch reads, and that can
//  take a feature out of the app without a release.
//
//  THE ONE RULE: THIS CAN ONLY EVER TURN THINGS OFF
//  ------------------------------------------------
//  Every flag is compiled ON. The remote file's only power is to override a
//  default to `false`; a file saying `true` changes nothing, because `true` is
//  what the binary already says. That is deliberate and it is what keeps the
//  scheme honest with App Review: the version Apple approved is the most the
//  app can ever do, and the worst a bad flags file can achieve is an app with
//  a feature missing.
//
//  It also means "turning a feature back on" is not the file enabling
//  anything — it is the file no longer overriding it, and the app returning to
//  exactly the state that was reviewed.
//
//  THREE TIERS, LIKE THE FIELD GUIDE
//  ---------------------------------
//    1. Compiled  — the defaults below, always present, always ON.
//    2. Cached    — the last file successfully fetched, in Application Support.
//    3. Remote    — the JSON on GitHub, checked once per launch.
//
//  So a phone that has been online once keeps its answer offline afterwards,
//  and a fresh install that has never connected runs the full app. That last
//  case is the scheme's only gap and it is the safe direction to fail in.
//
//  ⚠️ THE BRANCH MATTERS
//  ---------------------
//  `remoteURL` names a branch, and the repo's default branch is `master` while
//  development happens on version branches. A flag edited on the wrong branch
//  changes nothing and looks exactly like a bug in this file. Commit config
//  changes straight to the branch named below.
//
//  SEQUENCING A RELEASE
//  --------------------
//  Apple's reviewer fetches this file too. Leave everything on while a build is
//  in review — a reviewer who sees a build missing features the App Store
//  description mentions is a rejection. Flip a switch AFTER approval and BEFORE
//  release, using manual release in App Store Connect, so the first launch of
//  the first download already has the answer.
//

import Foundation

/// One switch, and what to say when it is off.
///
/// Every feature that can be turned off is a case here, so the config menu can
/// list them without a second table to keep in step.
enum Feature: String, CaseIterable, Identifiable, Sendable {
    /// Posting an observation to iNaturalist from inside the app, both the
    /// signed-in route and the save-the-files route.
    case iNaturalistUpload = "inaturalistUpload"
    /// On-device species identification. Off means the classifier does not run
    /// at all — recording, spectrograms, playback and export all continue.
    case automaticID = "automaticID"
    /// The distribution maps drawn in the field guide.
    case rangeMaps = "rangeMaps"
    /// Weighting a species' confidence by whether it lives where the phone is
    /// standing. Shares its data with `rangeMaps` and is switched separately,
    /// because hiding a map is cosmetic and changing how a call is scored is
    /// not.
    case locationWeighting = "locationWeighting"

    var id: String { rawValue }

    /// What this is called in the config menu.
    var title: String {
        switch self {
        case .iNaturalistUpload: "iNaturalist posting"
        case .automaticID:       "Automatic identification"
        case .rangeMaps:         "Distribution maps"
        case .locationWeighting: "Location weighting"
        }
    }

    /// One line under the title, in the config menu.
    var detail: String {
        switch self {
        case .iNaturalistUpload:
            "Turning a recording into an observation, by posting or by saving the files."
        case .automaticID:
            "Naming the species on device. Off, nothing is classified — recording and playback are unaffected."
        case .rangeMaps:
            "The maps in the field guide showing where a species lives."
        case .locationWeighting:
            "Adjusting a species' confidence by whether it lives where you are standing."
        }
    }

    /// What the app tells a user where the feature used to be. Short, and never
    /// a reason — the reason belongs in the maintenance message, which can be
    /// changed without a release.
    var unavailableNote: String {
        switch self {
        case .iNaturalistUpload: "Posting to iNaturalist is temporarily unavailable."
        case .automaticID:       "Species identification is temporarily switched off."
        case .rangeMaps:         "Distribution maps are temporarily unavailable."
        case .locationWeighting: "Location weighting is temporarily switched off."
        }
    }
}

/// The file's shape. Every field optional, so a file written for a later
/// version of the app decodes here rather than failing shut.
private struct RemoteConfig: Decodable {
    /// Bumped only for a change this app could not understand. A file declaring
    /// a schema past `supportedSchemaVersion` is ignored entirely — better the
    /// compiled defaults than a half-read config.
    var schemaVersion: Int?
    /// Flags, keyed by `Feature.rawValue`. A key this app does not know is
    /// ignored; a feature not mentioned keeps its compiled default.
    ///
    /// One key here is not a `Feature`: `configMenu`, which locks the config
    /// menu itself — see `FeatureFlagStore.configMenuAvailable`. It is kept out
    /// of the enum precisely so it cannot appear in the menu's own list of
    /// switches, where it would be overridable and the lock would be
    /// decorative.
    var features: [String: Bool]?
    /// Shown once, on launch, when `maintenanceMessage` is non-empty.
    var maintenance: Bool?
    var maintenanceMessage: String?

    static let supportedSchemaVersion = 1

    /// The key that locks the config menu. Not a `Feature` — see `features`.
    static let configMenuKey = "configMenu"
}

@MainActor
@Observable
final class FeatureFlagStore {

    /// Raw content URL, not the `github.com/.../blob/...` viewer page — that
    /// serves HTML. Tracks a branch rather than a commit so an edit takes
    /// effect on the next launch. See the branch warning in this file's header.
    static let remoteURL = URL(string:
        "https://raw.githubusercontent.com/NiallxD/OpenBat-App/master/OpenBatConfig.json")!

    /// What the remote file has switched OFF. Absent means on.
    private var remoteOff: Set<Feature> = []
    /// What the config menu has switched back on locally, by hand.
    private var localOverrides: Set<Feature> = []

    /// Whether the config menu can be opened at all.
    ///
    /// **The one switch the menu cannot override, and the reason it exists**
    /// (Niall, 2026-09-06). The passcode is derived from the date by code in a
    /// public repository, so anyone who reads the source can generate today's.
    /// That is fine for switches that only restore what Apple reviewed, and it
    /// is fine for the one control behind the menu with a cost outside this app
    /// — the debug bypass of the two-per-species-per-night posting cap, which
    /// iNaturalist's volunteers would pay for — precisely BECAUSE this exists.
    /// If the passcode ever circulates, turning `configMenu` off in the config
    /// file closes the menu and, with it, everything the menu had switched.
    ///
    /// Locking it therefore does three things at once: the menu will not open,
    /// every local override stops applying, and the posting-cap bypass returns
    /// to its compiled state, which in a release build is off.
    private(set) var configMenuAvailable = true

    private(set) var maintenanceMessage: String?
    private(set) var isRefreshing = false
    private(set) var lastRefreshError: String?
    /// Where the current answers came from, for the config menu's footer.
    private(set) var source: Source = .compiled

    enum Source: String {
        case compiled = "app defaults"
        case cached = "last downloaded"
        case remote = "downloaded just now"
    }

    // MARK: Asking

    /// Whether a feature is available right now.
    ///
    /// Read this where the feature is USED, not once at startup: the remote
    /// answer can arrive a moment after launch, and a screen that decided
    /// before it landed would keep offering something that has been turned off
    /// until the app was restarted.
    func isEnabled(_ feature: Feature) -> Bool {
        !remoteOff.contains(feature) || (configMenuAvailable && localOverrides.contains(feature))
    }

    /// Whether the remote file is what is switching this off — so the config
    /// menu can show a switch as overridden rather than merely on.
    func isRemotelyDisabled(_ feature: Feature) -> Bool { remoteOff.contains(feature) }
    func isLocallyOverridden(_ feature: Feature) -> Bool {
        configMenuAvailable && localOverrides.contains(feature)
    }

    /// Turn a remotely-disabled feature back on for this device only.
    ///
    /// It can only ever restore the compiled default, never exceed it, so an
    /// override cannot produce an app that does more than the one Apple
    /// reviewed. That is why this is safe to put behind a passcode rather than
    /// behind an account.
    func setLocalOverride(_ feature: Feature, on: Bool) {
        if on { localOverrides.insert(feature) } else { localOverrides.remove(feature) }
        UserDefaults.standard.set(localOverrides.map(\.rawValue), forKey: Self.overridesKey)
    }

    func clearLocalOverrides() {
        localOverrides = []
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
    }

    // MARK: Loading

    private static let overridesKey = "config.localFeatureOverrides"
    /// `INatUploadAssessment.overrideLimits` reads this key directly. Named here
    /// as well so locking the menu can clear it — see `configMenuAvailable`.
    static let postingCapOverrideKey = "openbat.inat.debugIgnoreLimits"
    private static let seenMessageKey = "config.lastSeenMaintenanceMessage"

    nonisolated private static let cacheURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("Config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("OpenBatConfig.json")
    }()

    /// Cheap, for the same reason `SpeciesGuideStore.init` is: this is built as
    /// a `@State` default inside the window's content closure, which
    /// re-evaluates more often than once.
    init() {}

    /// Adopts the cached file, if there is one. Call before `refreshFromRemote`
    /// so a phone with no signal still gets the last answer it was given.
    func loadCached() {
        localOverrides = Set((UserDefaults.standard.stringArray(forKey: Self.overridesKey) ?? [])
            .compactMap(Feature.init(rawValue:)))
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let config = decode(data)
        else { return }
        adopt(config, from: .cached)
    }

    /// Checks GitHub. Offline, or on any failure, whatever is already loaded
    /// stays exactly as it is — this can never make the app less available than
    /// the last answer it had.
    func refreshFromRemote() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefreshError = nil
        do {
            var request = URLRequest(url: Self.remoteURL)
            // Bypass URLCache: the whole point is to see the latest commit.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            guard let config = decode(data) else {
                lastRefreshError = "The config file could not be read."
                return
            }
            try? data.write(to: Self.cacheURL, options: .atomic)
            adopt(config, from: .remote)
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    private func decode(_ data: Data) -> RemoteConfig? {
        guard let config = try? JSONDecoder().decode(RemoteConfig.self, from: data) else { return nil }
        // A file from the future is ignored whole rather than half-read: a
        // partial understanding of a config that turns things off is worse than
        // not reading it at all.
        guard (config.schemaVersion ?? 1) <= RemoteConfig.supportedSchemaVersion else { return nil }
        return config
    }

    private func adopt(_ config: RemoteConfig, from source: Source) {
        // Only `false` does anything. A missing key, an unknown key, or `true`
        // all leave the compiled default alone — see this file's header.
        remoteOff = Set(Feature.allCases.filter { config.features?[$0.rawValue] == false })
        configMenuAvailable = config.features?[RemoteConfig.configMenuKey] != false
        // Locking the menu has to take away what the menu already did, or
        // somebody who flipped a switch before the lock landed keeps it. The
        // overrides are dropped rather than merely ignored so the state on disk
        // matches the state in force, and the posting-cap bypass is cleared
        // outright — it is read straight from defaults by
        // `INatUploadAssessment.overrideLimits`, which knows nothing about any
        // of this and should not have to.
        if !configMenuAvailable {
            clearLocalOverrides()
            UserDefaults.standard.removeObject(forKey: Self.postingCapOverrideKey)
        }
        let message = config.maintenanceMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        maintenanceMessage = (config.maintenance == true && !(message ?? "").isEmpty) ? message : nil
        self.source = source
    }

    // MARK: The maintenance notice

    /// The message to show on this launch, or nil.
    ///
    /// **Once per message, not once per launch** (Niall, 2026-09-06). A
    /// three-week outage is twenty-one alerts for somebody who opens the app
    /// every night, and an alert that appears every time stops being read. The
    /// text stays permanently visible in Settings, so it is always findable —
    /// this only decides when to interrupt.
    func pendingMaintenanceMessage() -> String? {
        guard let message = maintenanceMessage else { return nil }
        let seen = UserDefaults.standard.string(forKey: Self.seenMessageKey)
        return message == seen ? nil : message
    }

    func markMaintenanceMessageSeen() {
        UserDefaults.standard.set(maintenanceMessage, forKey: Self.seenMessageKey)
    }
}
