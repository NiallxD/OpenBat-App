//
//  RecordingUploader.swift
//  OpenBat
//
//  Orchestrates the last mile from a finished recording to an uploaded FLAC
//  in R2: consent check → UploadConversionPipeline (transient copy) → FLAC
//  encode → background URLSession upload → delete the derived copy once the
//  upload actually succeeds. Never touches the on-device original at any
//  step. Wired from ContentView's `recorder.onRecordingSaved`, alongside the
//  existing `classStore.addRecording` call.
//
//  Every phase reports back to ClassificationStore via `updateUploadStatus`
//  (see UploadStatus.swift) so `RecordingRow`'s eligibility badge and
//  `UploadQueueView` can show real pending/uploading/failed state instead of
//  the pipeline being entirely invisible.
//  `retryFailedUploads()` re-attempts anything left `.failed` after the user
//  asked to contribute it — called automatically when Wi-Fi becomes available.
//  Nothing else uploads on its own: contribution is always a deliberate tap.
//
//  Uses `URLSessionConfiguration.background` so an upload can complete even
//  if the app is backgrounded or the system needs to relaunch it — that
//  relaunch path is why `AppDelegate.application(_:handleEventsForBackgroundURLSession:completionHandler:)`
//  exists (this SwiftUI app otherwise has no reason to keep one) and why
//  this class is a singleton rather than something recreated per screen.
//

import Foundation
import Network
import CoreLocation
import UIKit

/// Pulled fresh at retry time rather than cached, since consent can change
/// between a failed attempt and the network coming back — mirrors the
/// pull-based provider pattern used elsewhere in this app (e.g.
/// `PulseDetector.pcmProvider`). Only consent is left: the settings that used
/// to live here (auto-upload, Wi-Fi-only) no longer exist.
struct UploadRetryContext {
    let consent: ConsentStore
}

/// `nonisolated ... @unchecked Sendable`: this genuinely runs on three
/// execution contexts — the main actor (call sites, `classStore` updates), a
/// `Task.detached` for conversion/encoding, and the background session's own
/// delegate queue. Under the project's `SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor` it was implicitly main-actor-isolated while doing none of that on
/// the main actor, which Swift 5 language mode downgrades to a warning — so
/// `pendingUploads` was being mutated from two non-main threads with no
/// synchronisation at all. State is now split explicitly: everything under
/// `lock` is reachable from any thread, everything in the "main actor only"
/// section is touched solely from `DispatchQueue.main`.
nonisolated final class RecordingUploader: NSObject, @unchecked Sendable {
    static let shared = RecordingUploader()

    /// Minimum species-ID confidence for a recording to be *offered* as ready to
    /// contribute. Below this it's still kept locally and can still be sent by an
    /// explicit tap — it just isn't surfaced as eligible by default.
    static let minUploadConfidence: Float = 0.75

    /// Longest capture eligible to be contributed. A genuine pass is a few
    /// seconds; the recorder's own `maxSegmentSeconds` (600 s) is a safety valve
    /// for a trigger that never released, not a description of a real pass, so
    /// anything near it is a stuck gate or continuous noise rather than a bat.
    /// Recordings over this stay on the device untouched — this only decides
    /// what's eligible for upload.
    static let maxUploadDurationSeconds: Double = 30

    /// Hard ceiling on the encoded file, mirroring the Worker's own
    /// `MAX_UPLOAD_BYTES` (which in turn matches Cloudflare's per-request body
    /// cap). Checked against the actual FLAC on disk rather than estimated from
    /// duration, since compression ratio on ultrasonic noise varies too much to
    /// predict. A 30 s capture is ~22 MB before compression, so this should
    /// never trip — it's insurance against the duration limit being raised, or a
    /// future higher sample rate, silently producing uploads the server refuses.
    static let maxUploadBytes = 100 * 1024 * 1024

    /// How recently a derived copy must have been written to be spared by
    /// `purgeOrphanedDerivedCopies` even though nothing references it yet.
    private let freshDerivedCopyGrace: TimeInterval = 300

    /// Upper bound on the random hold-off applied before a transfer starts — see
    /// the `earliestBeginDate` note in `upload`. Ten minutes is enough to
    /// decouple the stored object's creation time from the moment of capture
    /// without the upload appearing stuck.
    static let maxUploadJitterSeconds: TimeInterval = 600

    // MARK: Main-actor-only state

    /// Set once from ContentView.onAppear so upload phases can be reported
    /// back onto the same Recording entries the Sessions/Playback lists show.
    /// Read and written only on the main queue. Assigning it flushes anything
    /// that finished before the UI existed — see `bufferedReports`.
    @MainActor weak var classStore: ClassificationStore? {
        didSet { flushBufferedReports() }
    }
    @MainActor var retryContextProvider: (() -> UploadRetryContext)?

    /// Statuses produced while `classStore` was still nil. iOS can relaunch this
    /// app straight into `AppDelegate.handleEventsForBackgroundURLSession` with
    /// no UI, so uploads routinely complete before ContentView.onAppear has run;
    /// without this buffer those completions were dropped on the floor and the
    /// recording stayed "Uploading" forever.
    @MainActor private var bufferedReports: [(recordingID: UUID, status: UploadStatus)] = []

    // MARK: Lock-guarded state

    private let lock = NSLock()
    /// Keyed by request URL: background session delegate callbacks only hand back
    /// the task/response, not anything we attached ourselves, so this is how
    /// `urlSession(_:task:didCompleteWithError:)` finds the file (and Recording) to update.
    private var pendingUploads: [URL: PendingUpload] = [:]
    private var isOnWiFiStorage = false
    private var hasReconciled = false

    var isOnWiFi: Bool {
        lock.lock(); defer { lock.unlock() }
        return isOnWiFiStorage
    }

    private let pathMonitor = NWPathMonitor()

    /// Assigned exactly once, in `init`, and never again — the implicitly
    /// unwrapped `var` exists only because the session takes `self` as its
    /// delegate, which isn't available until after `super.init()`. It was a
    /// `lazy var` before, which can't be `nonisolated` (a lazy property mutates
    /// on first read, so concurrent first access is a race in its own right);
    /// creating it eagerly on the one thread that constructs the singleton
    /// removes that hazard entirely.
    private nonisolated(unsafe) var backgroundSession: URLSession!

    override private init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "com.openbat.upload")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        pendingUploads = Self.loadPendingUploads()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowOnWiFi = path.usesInterfaceType(.wifi)
            lock.lock()
            let wasOnWiFi = isOnWiFiStorage
            isOnWiFiStorage = nowOnWiFi
            lock.unlock()
            if !wasOnWiFi && nowOnWiFi {
                DispatchQueue.main.async { self.retryFailedUploads() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.openbat.upload.pathMonitor"))
    }

    /// Call once at launch (see OpenBatApp) so `backgroundSession` exists to
    /// pick back up any in-flight background transfers after a relaunch, and so
    /// anything that did NOT survive that relaunch gets reconciled rather than
    /// being left mid-flight forever.
    func activate() {
        // Explicitly typed: `backgroundSession` is implicitly unwrapped, so
        // inference would otherwise make this an `URLSession?`.
        let session: URLSession = backgroundSession
        // ContentView.onAppear calls this too, and that re-fires whenever the
        // view comes back — reconciliation must happen once per process, not
        // every time, or a later pass could tidy up a transfer set up by an
        // earlier one.
        lock.lock()
        let alreadyReconciled = hasReconciled
        hasReconciled = true
        lock.unlock()
        guard !alreadyReconciled else { return }

        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let live = Set(tasks.compactMap(\.originalRequest?.url))

            lock.lock()
            let orphaned = pendingUploads.filter { !live.contains($0.key) }
            for key in orphaned.keys { pendingUploads.removeValue(forKey: key) }
            if !orphaned.isEmpty { persistPendingUploadsLocked() }
            lock.unlock()

            // No live task and no completion callback means the transfer died
            // with the previous process. Drop the derived copy and mark the
            // recording retry-eligible — a retry re-derives it from the
            // untouched original, so keeping the stale intermediate buys nothing.
            for pending in orphaned.values {
                UploadConversionPipeline.discardDerivedCopy(at: pending.fileURL)
                report(pending.recordingID, .failed("Upload interrupted"))
            }
            purgeOrphanedDerivedCopies()
        }
    }

    /// Cancels every in-flight transfer and drops the derived copies behind
    /// them. Called before a full erasure (see `ConsentStore.eraseAllData`) so
    /// nothing can land in R2 after the server-side sweep has already run.
    ///
    /// Bookkeeping is cleared BEFORE cancelling: cancellation delivers
    /// `didCompleteWithError`, and with the entries already gone that delegate
    /// call finds nothing and writes no status — which is what we want, since
    /// the erase path resets every recording's upload status wholesale
    /// afterwards.
    func cancelAllUploads() async {
        let cancelled = takeAllPendingUploads()
        for task in await backgroundSession.allTasks { task.cancel() }
        for pending in cancelled {
            UploadConversionPipeline.discardDerivedCopy(at: pending.fileURL)
        }
    }

    /// Cancels the in-flight transfer for one recording, if any — used when a
    /// recording is deleted locally, so a file the user just removed can't go
    /// on to finish uploading.
    func cancelUpload(recordingID: UUID) {
        lock.lock()
        let matches = pendingUploads.values.filter { $0.recordingID == recordingID }
        for match in matches { pendingUploads.removeValue(forKey: match.requestURL) }
        if !matches.isEmpty { persistPendingUploadsLocked() }
        lock.unlock()
        guard !matches.isEmpty else { return }

        let requestURLs = Set(matches.map(\.requestURL))
        backgroundSession.getAllTasks { tasks in
            for task in tasks where task.originalRequest?.url.map(requestURLs.contains) == true {
                task.cancel()
            }
        }
        for match in matches { UploadConversionPipeline.discardDerivedCopy(at: match.fileURL) }
    }

    /// Removes anything in the derived-copy directory that no pending upload
    /// still refers to. Conversion writes there before a transfer starts, so a
    /// crash, a kill, or a rejected upload used to leave multi-megabyte
    /// intermediates in Caches with nothing left to ever delete them.
    private func purgeOrphanedDerivedCopies() {
        lock.lock()
        let live = Set(pendingUploads.values.map(\.fileURL.standardizedFileURL))
        lock.unlock()
        let directory = UploadConversionPipeline.derivedCopyDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        // A conversion writes its derived copy before registering a pending
        // upload for it, so a file that young may belong to one still running.
        let cutoff = Date().addingTimeInterval(-freshDerivedCopyGrace)
        for url in contents where !live.contains(url.standardizedFileURL) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            guard (modified ?? .distantPast) < cutoff else { continue }
            UploadConversionPipeline.discardDerivedCopy(at: url)
        }
    }

    /// Attempt to convert and upload a just-saved recording. Fully async and
    /// best-effort: any failure (consent not granted, quality gate rejection,
    /// no FLAC encoder yet, Worker not deployed) just skips the upload — the
    /// on-device recording and its species ID are entirely unaffected either way.
    ///
    /// `forceAttempt` bypasses the auto-upload and Wi-Fi-only gates (but never
    /// the consent gate) — set by the manual "Upload Now" action in
    /// UploadStatusView, since tapping that button is itself the user opting
    /// this one recording in right now, regardless of their standing settings.
    @MainActor
    func handleRecordingSaved(
        recordingID: UUID,
        originalWavURL: URL,
        date: Date,
        durationSeconds: Double,
        species: String,
        confidence: Float?,
        coordinate: (lat: Double, lon: Double)?,
        consent: ConsentStore,
        forceAttempt: Bool = false
    ) {
        guard consent.isGranted else {
            report(recordingID, .notContributing)
            return
        }
        // Not bypassable by `forceAttempt`, unlike the confidence and Wi-Fi
        // gates below: this is a property of the file, not of the user's
        // enthusiasm for it. A capture running this long means the trigger never
        // released — a stuck gate or a continuous noise source — so it isn't one
        // pass and isn't useful as a reference call. `.rejected` rather than
        // `.notContributing` because the input itself is the problem and no
        // retry will change it (see UploadStatus.Phase).
        if durationSeconds > Self.maxUploadDurationSeconds {
            report(recordingID, .rejected("Longer than \(Int(Self.maxUploadDurationSeconds))s — likely not a single pass"))
            return
        }
        // NoID captures (didn't clear the model's own NoID/NOISE gate, or the
        // user's minPassConfidence/minPassPulseCount gate — see AudioRecorder's
        // classify(outcome:)) are mostly noise triggers, not real calls, and
        // flooded the queue with junk needing a manual decision on every one.
        // Treated the same as consent-off: kept locally, excluded from the
        // queue by default, still uploadable one at a time via UploadStatusView's
        // per-row action (forceAttempt) if the user really wants to send one anyway.
        if species == "NOID" && !forceAttempt {
            report(recordingID, .notContributing)
            return
        }
        // Same idea, one step further: even a real species ID can be a low-confidence
        // call away from an outright NoID. Only the high-confidence tail is queued
        // automatically — starting point, tune via `minUploadConfidence` as real
        // contribution volume comes in. Manual per-row upload still bypasses this.
        if !forceAttempt, (confidence ?? 0) < Self.minUploadConfidence {
            report(recordingID, .notContributing)
            return
        }
        guard !UploadClient.baseURL.isEmpty else {
            report(recordingID, .failed("Upload service not configured yet"))
            return
        }
        // Everything above decided whether this recording is ELIGIBLE to be
        // contributed. Actually sending it is always a deliberate tap
        // (`uploadNow`, which passes `forceAttempt`), so a recording that has
        // just been saved stops here and waits to be chosen.
        //
        // There used to be an "upload automatically" setting and a "Wi-Fi only"
        // setting that qualified it. Both are gone: automatic contribution sat
        // awkwardly beside a consent model built on per-recording choice, and
        // the Wi-Fi setting existed only to make automatic uploads less costly —
        // it never applied to a manual tap, so it had nothing left to qualify.
        if !forceAttempt {
            report(recordingID, .queued("Ready to contribute"))
            return
        }

        report(recordingID, .converting)
        let context = UploadConversionPipeline.Context(
            recordedAt: date,
            species: species,
            confidence: confidence,
            fallbackCoordinate: coordinate.map {
                CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
            })

        Task.detached(priority: .utility) {
            let result: UploadConversionResult
            do {
                result = try UploadConversionPipeline.convert(originalWavURL: originalWavURL, context: context)
            } catch UploadConversionError.qualityGateFailed(let quality) {
                self.report(recordingID, .rejected("Quality gate: SNR \(String(format: "%.1f", quality.snrDB)) dB, clipping \(String(format: "%.1f", quality.clippingFraction * 100))%"))
                return
            } catch {
                self.report(recordingID, .rejected("Recording couldn't be read"))
                return
            }

            self.report(recordingID, .encoding)
            let flacURL = result.derivedWavURL.deletingPathExtension().appendingPathExtension("flac")
            do {
                try FLACEncoder().encode(wavURL: result.derivedWavURL, outputURL: flacURL)
            } catch {
                UploadConversionPipeline.discardDerivedCopy(at: result.derivedWavURL)
                self.report(recordingID, .failed("FLAC encoding failed"))
                return
            }
            UploadConversionPipeline.discardDerivedCopy(at: result.derivedWavURL)

            // Exact size of what would actually be sent — better to refuse here
            // than to spend a transfer discovering the server's 413.
            let encodedBytes = (try? FileManager.default.attributesOfItem(atPath: flacURL.path)[.size] as? Int) ?? nil
            if let encodedBytes, encodedBytes > Self.maxUploadBytes {
                UploadConversionPipeline.discardDerivedCopy(at: flacURL)
                self.report(recordingID, .rejected("Too large to upload (\(encodedBytes / 1_048_576) MB)"))
                return
            }

            await self.upload(recordingID: recordingID, flacURL: flacURL,
                               anonymized: result.anonymized)
        }
    }

    /// Re-attempts every Recording left `.failed`, when the network comes back.
    ///
    /// `.failed` only, and that distinction matters: it means the user already
    /// tapped to contribute and the transfer didn't make it, so finishing what
    /// they asked for is expected. A `.queued` recording is merely *eligible* and
    /// has never been chosen — sweeping those would upload things nobody asked to
    /// send, which is precisely what removing the auto-upload setting was meant
    /// to rule out. See `UploadStatus.isRetryEligible`.
    @MainActor
    func retryFailedUploads() {
        guard let classStore, let context = retryContextProvider?() else { return }
        for recording in classStore.recordings where recording.uploadStatus?.isRetryEligible == true {
            let originalURL = CloudStorage.baseDirectory.appendingPathComponent(recording.relativeWavPath)
            handleRecordingSaved(
                recordingID: recording.id, originalWavURL: originalURL, date: recording.date,
                durationSeconds: recording.durationSeconds,
                species: recording.species, confidence: recording.confidence,
                coordinate: recording.coordinate.map { ($0.latitude, $0.longitude) },
                consent: context.consent, forceAttempt: true)
        }
    }

    /// The primary way anything actually uploads: tapping a recording's own
    /// eligible badge in the Playback list (RecordingRow.uploadBadge, shown only
    /// for `.queued`/`.failed` recordings) calls this directly, one recording at
    /// a time, bypassing the auto-upload/Wi-Fi-only gates since tapping it IS the
    /// user's explicit choice to send this one right now. Re-checks CURRENT
    /// consent (not whatever it was when the recording was made), so it only
    /// actually proceeds if Contribute is on now.
    @MainActor
    func uploadNow(_ recording: Recording) {
        guard let context = retryContextProvider?() else { return }
        let originalURL = CloudStorage.baseDirectory.appendingPathComponent(recording.relativeWavPath)
        handleRecordingSaved(
            recordingID: recording.id, originalWavURL: originalURL, date: recording.date,
            durationSeconds: recording.durationSeconds,
            species: recording.species, confidence: recording.confidence,
            coordinate: recording.coordinate.map { ($0.latitude, $0.longitude) },
            consent: context.consent, forceAttempt: true)
    }

    private func report(_ recordingID: UUID, _ status: UploadStatus) {
        DispatchQueue.main.async { @MainActor [weak self] in
            guard let self else { return }
            guard let classStore else {
                bufferedReports.append((recordingID, status))
                return
            }
            classStore.updateUploadStatus(recordingID: recordingID, status: status)
        }
    }

    @MainActor
    private func flushBufferedReports() {
        guard let classStore, !bufferedReports.isEmpty else { return }
        let queued = bufferedReports
        bufferedReports.removeAll()
        for entry in queued {
            classStore.updateUploadStatus(recordingID: entry.recordingID, status: entry.status)
        }
    }

    private func upload(recordingID: UUID, flacURL: URL, anonymized: AnonymizedUpload) async {
        // The object key comes from the anonymizer, whole. Nothing is appended
        // to it or derived from it here.
        guard let url = UploadClient.uploadURL(objectKey: anonymized.objectKey) else {
            UploadConversionPipeline.discardDerivedCopy(at: flacURL)
            report(recordingID, .failed("Upload service not configured yet"))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        // ------------------------------------------------------------------
        // The one place in this codebase where a personal identifier and an
        // anonymous record touch. Read this before changing anything here.
        //
        // The Worker has to confirm this device currently has consent granted
        // before accepting a contribution, and consent is keyed by device_id —
        // so the device_id must travel with the request. It travels as a HEADER,
        // is used server-side only to look up `consent_records.status`, and is
        // then discarded: it is never written onto the stored object, its key,
        // or its customMetadata (see handleUpload in the Worker).
        //
        // The bearer token can't substitute for it: the token is
        // HMAC(secret, device_id), which isn't reversible, so the Worker can't
        // recover an id from it to do the lookup.
        //
        // What would break the model: putting `deviceID` into the URL, into any
        // `x-openbat-*` header (those get mirrored into R2 customMetadata), or
        // into the GUANO. `AnonymizedUploadBuilder` is not given the device id
        // at all, specifically so that a refactor can't route one there by
        // accident.
        // ------------------------------------------------------------------
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "x-openbat-device-id")
        // Required by the Worker — an upload without a valid device token is
        // rejected 401 regardless of consent state.
        ConsentAPIClient.authorize(&request)

        // Already anonymized: the location here is the grid-snapped coordinate,
        // identical to the one in the file's GUANO. Assembling these headers by
        // hand at this call site is how the raw coordinate previously came to be
        // sent alongside a fuzzed one in the file.
        for (name, value) in anonymized.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        report(recordingID, .uploading)
        // background uploadTask(fromFile:) requires the file to persist until the
        // system has read it — deletion happens in the delegate callback below,
        // once the transfer actually finishes, not here.
        registerPendingUpload(PendingUpload(recordingID: recordingID, fileURL: flacURL, requestURL: url))
        let task = backgroundSession.uploadTask(with: request, fromFile: flacURL)
        // Random hold-off before the transfer actually goes out.
        //
        // The stored object's creation time is recorded by the storage layer and
        // is not something the app can strip. Sending the instant the user taps
        // would make that creation time a proxy for "this device did something
        // right now", which is the last remaining thing correlatable against the
        // consent database. In normal use the gap is already hours (record on a
        // walk, upload later), so this mainly protects the auto-upload path,
        // where a file would otherwise be sent seconds after it was recorded —
        // making the object's creation time a good estimate of the true capture
        // time, and quietly undoing the 5-minute bucketing applied to it.
        //
        // `earliestBeginDate` rather than a sleep: the system owns the schedule,
        // it survives the app being suspended or killed, and it costs nothing
        // while waiting. The window is deliberately short — this is a smearing
        // measure, not a queue, and a contribution the user expects to have sent
        // shouldn't sit around long enough to look broken.
        task.earliestBeginDate = Date().addingTimeInterval(
            .random(in: 0...Self.maxUploadJitterSeconds))
        task.resume()
    }

    /// `Codable` because it has to outlive the process: iOS can suspend or
    /// terminate the app mid-transfer and relaunch it purely to deliver the
    /// completion, at which point an in-memory-only map is empty and the
    /// delegate has no way to tell which Recording a finished task belonged to.
    private struct PendingUpload: Codable {
        let recordingID: UUID
        let fileURL: URL
        let requestURL: URL
    }

    /// Application Support, not Caches: iOS may evict Caches under storage
    /// pressure, and losing this map while a transfer is still live puts the
    /// delegate right back to not knowing which Recording a completion belongs
    /// to — the exact failure persisting it exists to prevent.
    private static var pendingUploadsURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("pending-uploads.json")
    }

    private static func loadPendingUploads() -> [URL: PendingUpload] {
        guard let data = try? Data(contentsOf: pendingUploadsURL),
              let entries = try? JSONDecoder().decode([PendingUpload].self, from: data) else { return [:] }
        return Dictionary(entries.map { ($0.requestURL, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    /// Empties the pending map and returns what was in it. Synchronous for the
    /// same reason as `registerPendingUpload` — `cancelAllUploads` is `async`.
    private func takeAllPendingUploads() -> [PendingUpload] {
        lock.lock()
        defer { lock.unlock() }
        let cancelled = Array(pendingUploads.values)
        pendingUploads.removeAll()
        persistPendingUploadsLocked()
        return cancelled
    }

    /// A plain synchronous helper rather than locking inline in `upload()`:
    /// taking an `NSLock` directly inside an `async` function risks blocking a
    /// cooperative-pool thread across a suspension, which Swift 6 rejects outright.
    private func registerPendingUpload(_ pending: PendingUpload) {
        lock.lock()
        defer { lock.unlock() }
        pendingUploads[pending.requestURL] = pending
        persistPendingUploadsLocked()
    }

    /// Caller must hold `lock`.
    private func persistPendingUploadsLocked() {
        let entries = Array(pendingUploads.values)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.pendingUploadsURL, options: .atomic)
    }
}

/// `nonisolated`: these fire on the background session's own delegate queue
/// (`delegateQueue: nil`), never the main actor. Without this the extension
/// inherits the project's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` default
/// and the conformance quietly claims main-actor isolation it doesn't have —
/// the compiler says as much ("crosses into main actor-isolated code and can
/// cause data races"), and in Swift 6 language mode it's an error.
nonisolated extension RecordingUploader: URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let requestURL = task.originalRequest?.url else { return }
        lock.lock()
        let pending = pendingUploads.removeValue(forKey: requestURL)
        if pending != nil { persistPendingUploadsLocked() }
        lock.unlock()
        guard let pending else { return }
        let succeeded = error == nil && (task.response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } == true
        // Discarded either way. Keeping it on failure was meant to let a retry
        // re-send without regenerating, but no retry path ever reuses it:
        // `retryFailedUploads` goes back through `handleRecordingSaved`, which
        // re-converts from the untouched original into a NEW uniquely-named
        // file — so the kept copy was unreachable, and leaked once per failure.
        UploadConversionPipeline.discardDerivedCopy(at: pending.fileURL)
        if succeeded {
            report(pending.recordingID, .uploaded)
            return
        }

        // 403 = the Worker won't accept this device's contributions: either it
        // holds no `granted` row (usually because the consent push never made
        // it, having been granted while offline) or the row names superseded
        // consent wording. 401 = no valid device token, which the same push is
        // what obtains.
        //
        // A sync fixes the first and third; only re-consenting fixes the second,
        // so the two are reported differently rather than both claiming to be
        // waiting on the network. Which one it is has to be decided on the main
        // actor, where `ConsentStore` can be read — the response body isn't
        // available here (`didCompleteWithError` carries no data).
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        if statusCode == 401 || statusCode == 403 {
            let recordingID = pending.recordingID
            DispatchQueue.main.async { @MainActor [weak self] in
                if ConsentStore.shared.needsReconsent {
                    self?.report(recordingID, .failed("Terms updated — review them in Settings"))
                } else {
                    ConsentSync.syncIfNeeded()
                    self?.report(recordingID, .failed("Waiting for consent to sync"))
                }
            }
            return
        }
        report(pending.recordingID, .failed(error?.localizedDescription ?? "Upload failed"))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                     didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                     totalBytesExpectedToSend: Int64) { }

    /// Signals the OS-provided completion handler AppDelegate stashed when it
    /// woke the app to handle background transfer events — required for
    /// background URLSession uploads to actually finish per Apple's contract.
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            (UIApplication.shared.delegate as? AppDelegate)?.backgroundCompletionHandler?()
        }
    }
}
