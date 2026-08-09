//
//  ConsentSync.swift
//  OpenBat
//
//  Makes the consent record's server-side mirror eventually consistent.
//  `ConsentAPIClient.push` used to be fire-and-forget with no status check: a
//  grant made offline never created the D1 row (uploads 403'd forever with no
//  UI signal), and a revoke made offline could silently leave the server
//  holding "granted" indefinitely — the direction with compliance teeth. A
//  record now carries `syncedAt`, set only on a 2xx, and this retries
//  anything unconfirmed on launch, on network return, and on a
//  consent-rejected upload.
//
//  A standalone enum rather than a `ConsentStore` method: it must run with no
//  store alive (a background relaunch finishing an upload), and multiple
//  `ConsentStore` instances stay in step by refreshing from `recordDidChange`.
//

import Foundation
import Network

nonisolated enum ConsentSync {
    /// Posted after a successful sync updates the stored record, so every live
    /// `ConsentStore` can refresh its observable copy.
    static let recordDidChange = Notification.Name("openbat.consentRecordDidChange")

    /// Synchronous helpers rather than locking inline around the `await`:
    /// holding an `NSLock` across a suspension point can block a
    /// cooperative-pool thread, which Swift 6 rejects outright.
    /// Returns false when a sync is already running.
    private static func beginSyncing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSyncing, !isSuspended else { return false }
        isSyncing = true
        return true
    }

    /// Blocks new pushes and waits for any in-flight one to land, so a full
    /// erasure can't be followed moments later by a `POST /consent` that
    /// re-creates the D1 row it just deleted — the same race
    /// `RecordingUploader.cancelAllUploads` closes for recordings. Bounded:
    /// a wedged request must not hold the erase hostage, and once the local
    /// record is gone `syncIfNeeded` has nothing left to push anyway.
    static func suspend() async {
        setSuspended(true)
        for _ in 0..<50 {
            if !isCurrentlySyncing() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func setSuspended(_ suspended: Bool) {
        lock.lock()
        isSuspended = suspended
        lock.unlock()
    }

    private static func isCurrentlySyncing() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSyncing
    }

    /// Re-enables pushing. Called after an erasure regardless of outcome: on
    /// success there's no record left to sync, and on failure the user's
    /// existing consent state still needs to reach the server.
    static func resume() { setSuspended(false) }

    private static func endSyncing() {
        lock.lock()
        isSyncing = false
        lock.unlock()
    }

    private static let lock = NSLock()
    private static nonisolated(unsafe) var isSyncing = false
    private static nonisolated(unsafe) var isSuspended = false
    private static nonisolated(unsafe) var monitor: NWPathMonitor?

    /// Begins watching for connectivity and attempts any outstanding sync. Safe
    /// to call repeatedly; only the first call starts a monitor.
    static func start() {
        lock.lock()
        let alreadyStarted = monitor != nil
        if !alreadyStarted {
            let pathMonitor = NWPathMonitor()
            monitor = pathMonitor
            pathMonitor.pathUpdateHandler = { path in
                guard path.status == .satisfied else { return }
                syncIfNeeded()
            }
            pathMonitor.start(queue: DispatchQueue(label: "com.openbat.consentSync"))
        }
        lock.unlock()
        syncIfNeeded()
    }

    /// Pushes the stored record if the server hasn't confirmed it yet. A no-op
    /// when there's nothing to sync, and self-deduplicating so overlapping
    /// triggers (launch + network + a 403) can't stack up concurrent pushes.
    /// A push is due when the server hasn't confirmed the current record, OR
    /// when this device has a record but no API token. The second case is the
    /// migration path: a device that registered before tokens existed is
    /// already marked synced, so without it that device would never re-push,
    /// never be issued a token, and get 401 on every upload forever.
    private static func pushIsDue(_ record: ConsentRecord) -> Bool {
        record.needsSync || DeviceIdentity.currentToken == nil
    }

    static func syncIfNeeded() {
        guard let initial = ConsentRecordStorage.read(), pushIsDue(initial) else { return }
        guard beginSyncing() else { return }

        Task.detached(priority: .utility) {
            defer { endSyncing() }

            // Backoff rather than a single shot: a network-status change isn't
            // the only reason a push fails (a transient 5xx while perfectly
            // online wouldn't produce one at all), and without this the record
            // would sit unconfirmed until the app happened to relaunch.
            var delay = Duration.seconds(2)
            for attempt in 0..<6 {
                if attempt > 0 {
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 3, .seconds(120))
                }
                // Re-read every attempt: the record may have been erased
                // (`suspend()` + `ConsentRecordStorage.delete()`) or superseded
                // by a newer decision while this loop was sleeping, and pushing
                // the stale copy would resurrect state the user has moved past.
                guard !isSuspendedNow(), let current = ConsentRecordStorage.read(),
                      pushIsDue(current) else { return }

                guard await ConsentAPIClient.push(current, deviceID: DeviceIdentity.current) else { continue }

                // Re-read again before stamping: the user may have changed their
                // mind while THIS request was in flight, and marking a newer,
                // genuinely unsynced decision as confirmed would strand it.
                guard var confirmed = ConsentRecordStorage.read(),
                      confirmed.status == current.status,
                      confirmed.consentVersion == current.consentVersion,
                      confirmed.needsSync else { return }
                confirmed.syncedAt = Date()
                ConsentRecordStorage.write(confirmed)
                await MainActor.run {
                    NotificationCenter.default.post(name: recordDidChange, object: nil)
                }
                return
            }
        }
    }

    private static func isSuspendedNow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isSuspended
    }
}
