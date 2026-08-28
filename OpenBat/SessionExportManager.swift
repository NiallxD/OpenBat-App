//
//  SessionExportManager.swift
//  OpenBat
//
//  Owns session exports so they outlive the screen they were started from.
//
//  An export used to be a `Task.detached` inside `SessionDetailView`, which
//  meant its progress had nowhere to live once you navigated back: the view's
//  `@State` went with it, and the finished share sheet had no presenter. A
//  night's recordings can be several gigabytes, so "wait here staring at a
//  spinner" is the wrong shape for this. Exports run here instead, on an
//  app-lifetime object, with a banner over the tab bar (`SessionExportBanner`)
//  and the share sheet presented from the root.
//
//  ONE AT A TIME, IN ORDER
//  -----------------------
//  Two exports at once would be two multi-gigabyte copies competing for the
//  same disk, so a second request queues behind the first rather than starting
//  beside it. A request for a session already in the queue is ignored, not
//  duplicated — the button is easy to hit twice.
//

import SwiftUI
import UIKit

@MainActor
@Observable
final class SessionExportManager {
    static let shared = SessionExportManager()

    /// The finished zip, waiting to be shared. Held here rather than handed
    /// straight to a view so it survives whatever the user is looking at when
    /// the export lands.
    struct Ready: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    enum Phase: Equatable {
        case waiting
        case copying
        case compressing
    }

    /// What the banner draws. A value type so the whole thing is replaced on
    /// each update — `@Observable` then has exactly one property to track.
    struct Job: Identifiable, Equatable {
        let id: UUID              // the session's id, so a repeat tap is a no-op
        let title: String
        var phase: Phase
        /// 0...1 across both legs. Real during `.copying`, estimated during
        /// `.compressing` — see `compressionShare`.
        var fraction: Double
        /// Seconds left, or nil before there's enough of a rate to say. Never
        /// shown as an exact figure — see `SessionExportBanner.remainingText`.
        var remaining: TimeInterval?
    }

    private(set) var job: Job?
    private(set) var queued: [SessionExport.Input] = []
    var ready: Ready?
    /// Set when an export produced nothing (cancelled, or the zip failed).
    /// Cleared by the banner when the user dismisses it.
    var failure: String?

    private var task: Task<Void, Never>?

    /// Screens that draw the progress pill inline in their own layout — the
    /// globe footer, which shares its row with it — register while they're on
    /// screen, and the root chrome stands down so it isn't drawn twice in two
    /// places. A count rather than a flag: push/pop and tab changes can overlap,
    /// and a bool would be left stuck by whichever registration ended last.
    private(set) var inlineHosts = 0

    /// Whether the app-wide chrome should draw the pill. False while a screen is
    /// hosting it inline.
    var showsRootPill: Bool { job != nil && inlineHosts == 0 }

    func addInlineHost() { inlineHosts += 1 }
    func removeInlineHost() { inlineHosts = max(0, inlineHosts - 1) }

    /// How much of the total work the zip leg is assumed to be, by bytes moved.
    /// Compressing reads everything the copy just wrote and deflates it, so it
    /// is the slower of the two per byte — this is a measured-ish guess, and the
    /// only thing it affects is how the bar paces itself.
    private static let compressionShare = 0.55

    private init() {}

    // MARK: Starting

    /// Queues an export. Returns immediately — the work runs on `task`, which is
    /// owned by this object and so is unaffected by any view going away.
    func enqueue(_ input: SessionExport.Input) {
        guard job?.id != input.sessionID,
              !queued.contains(where: { $0.sessionID == input.sessionID })
        else { return }
        queued.append(input)
        startNextIfIdle()
    }

    /// True while this session is exporting or waiting to — so the menu can say
    /// "Exporting…" rather than offer the same export again.
    func isActive(sessionID: UUID) -> Bool {
        job?.id == sessionID || queued.contains { $0.sessionID == sessionID }
    }

    func cancel() {
        task?.cancel()
        // The zip leg can't be interrupted (see `SessionExport.makeShareItem`),
        // so this is what the user sees change; the work itself stops at the
        // next check.
        job = nil
        queued.removeAll()
    }

    // MARK: Running

    private func startNextIfIdle() {
        guard task == nil, !queued.isEmpty else { return }
        let input = queued.removeFirst()
        job = Job(id: input.sessionID, title: input.title, phase: .waiting, fraction: 0, remaining: nil)

        // No `[weak self]`: this is a `static let shared` that lives as long as
        // the app does, and a weak capture here would make `self` a var that the
        // progress closure below then captures across an isolation boundary.
        task = Task(priority: .utility) {
            // Keeps the export alive if the screen locks or the user switches
            // away mid-copy — without this the process is suspended and a long
            // export never finishes.
            let background = UIApplication.shared.beginBackgroundTask(withName: "SessionExport")
            defer { UIApplication.shared.endBackgroundTask(background) }

            let url = await Self.build(input)
            self.finish(url: url, title: input.title)
        }
    }

    /// Runs the export off the main thread, and lets `cancel()` reach it.
    ///
    /// **An explicit dispatch queue, not `Task.detached` and not a bare
    /// `nonisolated async` function.** Both of those were tried and both were
    /// wrong:
    ///
    ///  • `Task.detached` starts its own task tree, so `cancel()` on our task
    ///    never reached the work — Cancel hid the banner while the copy carried
    ///    on underneath.
    ///  • `nonisolated async` was meant to fix that by staying in the same task
    ///    while hopping off the actor. **It froze the entire app for the length
    ///    of the export.** A nonisolated async function does not reliably leave
    ///    the caller's executor — under Swift 6.2's caller-inherits default it
    ///    runs right where it was called from, which here is the main actor, and
    ///    the exporter's body is one long synchronous block of file IO.
    ///
    /// So: a queue we name, a continuation to await it, and cancellation carried
    /// by a flag the exporter polls rather than by task machinery. Nothing about
    /// where this runs is left to inference.
    nonisolated private static let queue = DispatchQueue(label: "uk.openbat.session-export", qos: .utility)

    /// Set from the cancellation handler, read on the export queue.
    nonisolated private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }

    private nonisolated static func build(_ input: SessionExport.Input) async -> URL? {
        let cancelled = CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Returns immediately; everything heavy happens on `queue`.
                queue.async {
                    let started = Date()
                    let url = SessionExport.makeShareItem(
                        input,
                        isCancelled: { cancelled.isSet },
                        onProgress: { progress in
                            Task { @MainActor in
                                SessionExportManager.shared.apply(progress, startedAt: started)
                            }
                        })
                    continuation.resume(returning: url)
                }
            }
        } onCancel: {
            cancelled.set()
        }
    }

    /// Turns a byte count into the bar's fraction and a time estimate.
    ///
    /// The copy leg is real: bytes done over bytes total, scaled into the first
    /// `1 - compressionShare` of the bar. The zip leg has no progress to report
    /// at all, so it is *predicted* — see `advanceCompression`.
    private func apply(_ progress: SessionExport.Progress, startedAt: Date) {
        guard var job else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        let total = Double(max(progress.bytesTotal, 1))
        let copied = Double(progress.bytesDone)

        switch progress.phase {
        case .copying:
            job.phase = .copying
            job.fraction = min(copied / total, 1) * (1 - Self.compressionShare)
            // Needs a little way in before the rate means anything — a first
            // sample taken over 20ms extrapolates to nonsense.
            if elapsed > 1.5, copied > 0 {
                let rate = copied / elapsed                       // bytes/sec
                let remainingBytes = (total - copied) + total     // copy left, then the zip's pass over the same bytes
                job.remaining = remainingBytes / rate
            }
            self.job = job

        case .compressing:
            job.phase = .compressing
            self.job = job
            compressionStartedAt = Date()
            // The copy's own throughput is the only measurement available, so
            // the zip's duration is guessed from it.
            compressionEstimate = elapsed > 0 && copied > 0 ? total / (copied / elapsed) : nil
            advanceCompression()
        }
    }

    /// Moves the bar through the zip leg against a clock rather than against
    /// real progress, because there is no real progress to be had: the
    /// coordinated read is one opaque call. Capped just short of full, so the
    /// bar can never claim to be finished before the file exists.
    private func advanceCompression() {
        guard var job, job.phase == .compressing, let startedAt = compressionStartedAt else { return }
        guard let estimate = compressionEstimate, estimate > 0 else {
            job.fraction = 1 - Self.compressionShare
            job.remaining = nil
            self.job = job
            return
        }
        let share = min(Date().timeIntervalSince(startedAt) / estimate, 1)
        job.fraction = min((1 - Self.compressionShare) + share * Self.compressionShare, 0.98)
        job.remaining = max(estimate - Date().timeIntervalSince(startedAt), 0)
        self.job = job
    }

    private var compressionStartedAt: Date?
    private var compressionEstimate: TimeInterval?

    private func finish(url: URL?, title: String) {
        task = nil
        compressionStartedAt = nil
        compressionEstimate = nil
        let wasCancelled = job == nil
        job = nil
        if let url {
            ready = Ready(title: title, url: url)
        } else if !wasCancelled {
            failure = "Couldn't build the export for \(title). There may not be room on the device for a copy of its recordings."
        }
        startNextIfIdle()
    }

    /// Drives the compression estimate forward while the zip runs — the exporter
    /// reports nothing during that leg, so without a tick the bar would freeze
    /// on the last copy update. Driven by the banner, which is the only thing
    /// that needs it to move.
    func tick() { advanceCompression() }
}

// MARK: - Banner

/// The export's progress pill, shown over the tab bar wherever the user is.
///
/// **A glass capsule, matching `SpeciesExplorerView.globeFooter`** — the "Tap
/// here to see bats near you" pill occupies this exact band above the tab bar,
/// and two different-looking floating objects fighting for it read as two
/// unrelated systems. Same font, same padding, same capsule. It sits trailing
/// and the globe footer collapses to a bat icon and moves leading while an
/// export runs, so they share the row rather than overlap (see `globeFooter`).
///
/// It was a 260pt card with a title and a Cancel button until 2026-08-27; at
/// that size it covered the footer outright.
struct SessionExportBanner: View {
    @Bindable var manager: SessionExportManager

    var body: some View {
        if let job = manager.job {
            HStack(spacing: 8) {
                ProgressView(value: job.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 54)
                Text(statusText(job))
                    .lineLimit(1)
                Button {
                    manager.cancel()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel export")
            }
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .liquidGlass(in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Exporting \(job.title). \(statusText(job))")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            // Only while zipping, and only 2 Hz: the copy leg pushes its own
            // updates, and this exists purely to keep an estimated bar moving.
            .task(id: job.phase) {
                guard job.phase == .compressing else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    manager.tick()
                }
            }
        }
    }

    /// A pill is not a card: there is room for the stage OR the time, not both,
    /// and the time is the one the user is actually waiting on. The stage word
    /// only shows before there's a rate to quote.
    private func statusText(_ job: SessionExportManager.Job) -> String {
        if let remaining = job.remaining, remaining.isFinite {
            return Self.remainingText(remaining)
        }
        return switch job.phase {
        case .waiting: "Preparing…"
        case .copying: "Copying…"
        case .compressing: "Compressing…"
        }
    }

    /// Deliberately coarse. The estimate is built from a throughput measurement
    /// and, for the zip leg, an outright guess (see `advanceCompression`), so
    /// "about 2 min left" is honest where "1:47 left" would not be.
    static func remainingText(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return "nearly done" }
        if seconds < 90 { return "about \(Int((seconds / 10).rounded()) * 10)s left" }
        return "about \(Int((seconds / 60).rounded())) min left"
    }
}
