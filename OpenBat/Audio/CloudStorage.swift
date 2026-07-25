//
//  CloudStorage.swift
//  OpenBat
//
//  Resolves where recordings/sessions/screen captures actually live on disk.
//  Backed by the "iCloud.openbat-doc-container" ubiquity container (see
//  OpenBat.entitlements) instead of the app's local sandboxed Documents
//  folder, so recordings survive a full app delete/reinstall — tied to the
//  user's iCloud account rather than the local install. Falls back to local
//  Documents if iCloud Drive isn't available (signed out, container not yet
//  provisioned, etc.) so recording never hard-fails on missing iCloud.
//
//  Every call site that used to read
//  `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]`
//  should use `CloudStorage.baseDirectory` instead — `Recording.relativeWavPath`
//  and friends stay relative to THIS directory, whichever one it resolved to.
//

import Foundation

nonisolated enum CloudStorage {
    static let containerIdentifier = "iCloud.openbat-doc-container"

    /// User preference: should the library live in iCloud (persists a delete /
    /// reinstall / new device, costs iCloud quota) or only on this device
    /// (nothing leaves the device, lost if the app is deleted)?
    ///
    /// Distinct from `rootChoiceKey` below, which records where the files
    /// ACTUALLY are. The two disagree only between a toggle change and the
    /// migration that acts on it — see `applyPendingStorageMigration`.
    static let keepInICloudKey = "storage.keepInICloud"

    /// Which root a previous launch settled on. `Recording.relativeWavPath` (and
    /// every other stored path) is relative to whichever root was chosen when it
    /// was written, so this MUST stay stable across launches: resolving
    /// per-launch meant a launch where iCloud happened to be unavailable
    /// (signed out, container not yet provisioned, low storage, or simply not
    /// ready this early) silently relocated the whole library to local
    /// Documents, and everything recorded under the other root read back as a
    /// missing file — broken playback, blank spectrograms, deletes that remove
    /// nothing, and two divergent `recordings.json` stores accumulating.
    private static let rootChoiceKey = "storage.usesUbiquityContainer"

    /// True when a previous launch stored its files in the iCloud container but
    /// that container can't be resolved right now, so this launch is reading and
    /// writing a *different* root than the library lives in. Nothing recovers
    /// automatically from this (files aren't moved), but recording still works
    /// and the choice is NOT re-recorded, so a later launch with iCloud back
    /// reunites with the original library. Surfaced for diagnostics/UI.
    private(set) nonisolated(unsafe) static var isUsingFallbackRoot = false

    /// Resolved once, on first access, honouring the root a previous launch
    /// already committed to (see `rootChoiceKey`).
    /// `url(forUbiquityContainerIdentifier:)` can block briefly the very first
    /// time it provisions a container for a given device/iCloud account —
    /// accepted here rather than building async prewarming plumbing across every
    /// call site, since it's a one-time cost and this app already does plenty of
    /// synchronous file I/O on its own queues.
    static let baseDirectory: URL = {
        let defaults = UserDefaults.standard
        let localDocs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let ubiquityDocs = ubiquityDocuments()

        // A recorded choice wins outright — including "local", which is NOT
        // upgraded to iCloud just because iCloud became available later: that
        // would strand every already-written file under the old root. Moving an
        // existing library between roots is a migration, not a resolution rule.
        if let previouslyUsedUbiquity = defaults.object(forKey: rootChoiceKey) as? Bool {
            guard previouslyUsedUbiquity else { return localDocs }
            guard let ubiquityDocs else {
                isUsingFallbackRoot = true
                return localDocs
            }
            try? FileManager.default.createDirectory(at: ubiquityDocs, withIntermediateDirectories: true)
            return ubiquityDocs
        }

        // No recorded choice, but local Documents already holds a library: this
        // is an upgrade from a build that predates the iCloud container, not a
        // fresh install. Staying local keeps every existing recording reachable —
        // switching would orphan the lot behind paths that no longer resolve.
        if hasExistingLibrary(under: localDocs) {
            defaults.set(false, forKey: rootChoiceKey)
            return localDocs
        }

        // First launch: honour the preference (which defaults to iCloud), and
        // record whichever root we settle on so every subsequent launch takes the
        // branch above instead of re-deciding.
        guard defaults.bool(forKey: keepInICloudKey) else {
            defaults.set(false, forKey: rootChoiceKey)
            return localDocs
        }
        if let ubiquityDocs {
            try? FileManager.default.createDirectory(at: ubiquityDocs, withIntermediateDirectories: true)
            defaults.set(true, forKey: rootChoiceKey)
            return ubiquityDocs
        }
        defaults.set(false, forKey: rootChoiceKey)
        return localDocs
    }()

    // MARK: Storage migration

    /// Outcome of this launch's migration attempt, set by `OpenBatApp.init`, so
    /// Settings can report a failure instead of the toggle silently snapping back.
    nonisolated(unsafe) static var lastMigrationResult: StorageMigration = .notNeeded

    enum StorageMigration: Equatable {
        /// Preference already matches reality (the common case, every launch).
        case notNeeded
        case moved(toICloud: Bool)
        /// iCloud was asked for but the container can't be resolved right now.
        /// The preference is left pending so a later launch retries.
        case iCloudUnavailable
        /// Moving OUT of iCloud was deferred because some files exist only as
        /// placeholders on this device. Downloads have been requested; a later
        /// launch retries. Carries how many files are still to come.
        case awaitingDownloads(Int)
        /// Nothing was moved — the library is intact where it was.
        case failed(String)
    }

    /// Moves the library between roots when the user's preference no longer
    /// matches where the files are.
    ///
    /// MUST be called from `OpenBatApp.init`, before `ClassificationStore` or
    /// `ClassificationLogger` exist. Both cache their absolute paths at `init`
    /// (`dir`, `imagesDir`, `jsonURL`, `fileURL`), so a root change part-way
    /// through a process can't be honoured — those objects would keep reading
    /// and writing the old location. Doing it at launch also means it can't race
    /// an in-progress recording or upload conversion.
    ///
    /// All-or-nothing: destinations are checked for collisions first, and a
    /// failure part-way through moves back what it already moved. A half-migrated
    /// library (some recordings under each root) is the one outcome worth real
    /// effort to avoid, since every stored path is root-relative and there'd be
    /// no way to tell which root a given entry belonged to.
    @discardableResult
    static func applyPendingStorageMigration() -> StorageMigration {
        let defaults = UserDefaults.standard
        let wantsICloud = defaults.bool(forKey: keepInICloudKey)
        // No recorded root yet = fresh install, nothing on disk to move; the
        // normal `baseDirectory` resolution below will honour the preference.
        guard let currentlyICloud = defaults.object(forKey: rootChoiceKey) as? Bool,
              currentlyICloud != wantsICloud else {
            return .notNeeded
        }
        guard let cloud = ubiquityDocuments() else { return .iCloudUnavailable }

        let local = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let source = currentlyICloud ? cloud : local
        let destination = wantsICloud ? cloud : local

        let manager = FileManager.default

        // Moving OUT of iCloud, the source may hold files that exist only as
        // placeholders on this device — recorded on another device, or evicted
        // under storage pressure, or not yet pulled down after a reinstall.
        // `setUbiquitous(false, ...)` on a placeholder is not guaranteed to
        // materialise the contents first, and a "successful" move that yields a
        // zero-length WAV would destroy the only copy: the iCloud original is
        // gone and the local file is empty. So refuse, request the downloads,
        // and let a later launch do it once the bytes are actually here.
        //
        // Only reached on the launch after the user changes the setting, so the
        // cost of walking the tree isn't paid on a normal launch.
        if currentlyICloud && !wantsICloud {
            let pending = undownloadedFiles(under: source)
            if !pending.isEmpty {
                for url in pending { try? manager.startDownloadingUbiquitousItem(at: url) }
                return .awaitingDownloads(pending.count)
            }
        }

        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let items = try? manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) else {
            return .failed("Couldn't read the current storage location.")
        }
        guard !items.isEmpty else {
            defaults.set(wantsICloud, forKey: rootChoiceKey)
            return .moved(toICloud: wantsICloud)
        }

        // Pre-flight: refuse rather than overwrite anything already at the
        // destination (e.g. a stale tree from an earlier switch).
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            if manager.fileExists(atPath: target.path) {
                return .failed("\(item.lastPathComponent) already exists in the destination.")
            }
        }

        var moved: [(from: URL, to: URL)] = []
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            do {
                // `setUbiquitous` rather than `moveItem`: it's the API that
                // understands ubiquity semantics in both directions, and it
                // moves rather than deep-copies.
                try manager.setUbiquitous(wantsICloud, itemAt: item, destinationURL: target)
                moved.append((item, target))
            } catch {
                for entry in moved.reversed() {
                    try? manager.setUbiquitous(currentlyICloud, itemAt: entry.to, destinationURL: entry.from)
                }
                return .failed(error.localizedDescription)
            }
        }

        defaults.set(wantsICloud, forKey: rootChoiceKey)
        return .moved(toICloud: wantsICloud)
    }

    /// Every file under `root` whose contents aren't on this device yet.
    ///
    /// `.notDownloaded` is the only status that means "no local contents" —
    /// `.downloaded` and `.current` both have the bytes (they differ only in
    /// whether a newer version exists remotely). A nil status means the item
    /// isn't ubiquitous at all, which is fine. Directories are skipped: only
    /// files carry contents worth losing.
    private static func undownloadedFiles(under root: URL) -> [URL] {
        let keys: [URLResourceKey] = [.ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys) else { return [] }

        var pending: [URL] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory != true,
                  let status = values.ubiquitousItemDownloadingStatus else { continue }
            if status == .notDownloaded { pending.append(url) }
        }
        return pending
    }

    private static func ubiquityDocuments() -> URL? {
        FileManager.default
            .url(forUbiquityContainerIdentifier: containerIdentifier)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    /// Whether a root already contains this app's own directories — the marker
    /// for "a previous build wrote its library here". Checks for existence
    /// rather than contents: `Classifications/` is created by
    /// `ClassificationStore.init` on every launch, so its presence under local
    /// Documents means some earlier launch resolved to that root.
    private static func hasExistingLibrary(under root: URL) -> Bool {
        let manager = FileManager.default
        return ["Classifications", "Recordings"].contains {
            manager.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    /// Best-effort nudge for an iCloud placeholder file that hasn't been
    /// downloaded to this device yet (e.g. a recording made on another device,
    /// or restored after a delete/reinstall) — fire-and-forget, since this
    /// app's files are read repeatedly (playback, spectrogram render, GUANO
    /// parse) rather than exactly once, so a request that arrives just before
    /// the download finishes isn't fatal, just retried on the next read.
    static func ensureDownloaded(_ url: URL) {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}
