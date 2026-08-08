//
//  LiveActivityController.swift
//  OpenBat
//
//  App-side owner of the detection Live Activity. Target: OpenBat only.
//

import Foundation
import SwiftUI
import ActivityKit

/// Starts, feeds and tears down the lock-screen Live Activity for a detection session.
///
/// **Update budget is the whole design constraint here.** `Activity.update` is rate
/// limited by iOS, and an app that spends its budget gets its later updates silently
/// dropped — the card freezes with no error. So this class never updates on a pulse; it
/// updates on a *pass* (`PulseDetector.finalizePass`, i.e. a bat finished flying
/// through) plus a slow heartbeat for the running counters, and coalesces both behind
/// `minUpdateInterval`. A no-op update — nothing in `ContentState` changed — is dropped
/// before it reaches ActivityKit.
@MainActor
@Observable
final class LiveActivityController {

    /// Minimum wall-clock gap between two `Activity.update` calls. Passes during a busy
    /// feeding buzz can finalise faster than this; the extra ones are folded into the
    /// next send by `pendingState` rather than queued, so the card always shows the
    /// newest state and never replays a backlog. Same "jump to live, don't replay"
    /// reasoning as `SpectrogramProcessor.drain`.
    private static let minUpdateInterval: TimeInterval = 3.0

    /// Heartbeat that re-evaluates the state so time-based changes (the dot going out,
    /// the ID greying) reach the card at all — see `ContentState.isIDStale`.
    ///
    /// This is the *granularity* of those transitions, so `BatActivityShared`'s
    /// `activeDotSeconds` (20 s) is set above it — otherwise the dot can stay lit for the
    /// sum of the two.
    ///
    /// **This was 5 s and that was too fast.** The reasoning for a quick heartbeat was
    /// that the no-op guard makes it free — a tick matching the last send never reaches
    /// ActivityKit. True on a silent night, and wrong during actual detection:
    /// `pulseCount` increments with every pulse, so while bats are about, *every*
    /// heartbeat carries changed state and sends. At 5 s that is 12/min sustained on top
    /// of the pass-driven updates, which overruns the budget within a few minutes — after
    /// which iOS drops updates silently and the card freezes with no error anywhere. The
    /// visible symptom is a card that works for a while and then stops.
    private static let heartbeatInterval: TimeInterval = 15.0

    private(set) var isRunning = false

    private var activity: Activity<BatDetectorAttributes>?
    private var lastSentState: BatDetectorAttributes.ContentState?
    private var lastSentAt: Date = .distantPast
    private var pendingState: BatDetectorAttributes.ContentState?
    private var flushTask: Task<Void, Never>?
    private var heartbeat: Timer?
    private var tick = 0

    // MARK: Lifecycle

    /// Begin a Live Activity for a detection run. Safe to call when one is already
    /// running (ends it first) and when the user has Live Activities switched off
    /// (does nothing, reports why).
    func start(sessionTitle: String, isDemo: Bool, startDate: Date = Date()) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            // Not an error worth surfacing: Live Activities are off in Settings, or this
            // is a device/OS that won't show them. Detection is unaffected.
            return
        }
        if activity != nil { end() }

        tick = 0

        let attributes = BatDetectorAttributes(
            sessionTitle: sessionTitle,
            sessionStart: startDate,
            isDemo: isDemo
        )
        let initial = BatDetectorAttributes.ContentState.idle

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: initial, staleDate: nil),
                // No push token: everything is driven locally from the running app,
                // which is what `UIBackgroundModes: audio` keeps alive.
                pushType: nil
            )
            lastSentState = initial
            lastSentAt = Date()
            isRunning = true
            startHeartbeat()
        } catch {
            // `Activity.request` throws if the app is backgrounded at request time or the
            // activity limit is hit. Neither is recoverable here and neither should
            // interrupt detection, so this stays silent beyond the log.
            print("[LiveActivity] start failed: \(error)")
            activity = nil
            isRunning = false
        }
    }

    /// Tear down the card. `dismissalPolicy: .immediate` because a stale detector
    /// readout on the lock screen after the user has stopped is worse than no card —
    /// the default policy would leave it up for four hours.
    func end() {
        heartbeat?.invalidate()
        heartbeat = nil
        flushTask?.cancel()
        flushTask = nil
        pendingState = nil
        isRunning = false

        guard let activity else { return }
        self.activity = nil
        let final = lastSentState ?? .idle
        lastSentState = nil
        Task {
            await activity.end(.init(state: final, staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    /// Belt-and-braces cleanup for activities orphaned by a crash or a force-quit during
    /// a previous run — those survive in the system and would otherwise show a frozen
    /// readout from a session that ended days ago. Call once at launch.
    static func endOrphanedActivities() {
        Task {
            for activity in Activity<BatDetectorAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    // MARK: Feeding

    /// Push the detector's current state to the card. Call on every finalised pass
    /// (`force: true`) and let the heartbeat cover everything else.
    ///
    /// - Parameter force: bypasses the *change* check, not the rate limit. A pass with
    ///   identical numbers to the last one is still news (it's a second pass), so it has
    ///   to get through the equality guard — but it still waits its turn behind
    ///   `minUpdateInterval`.
    func update(from detector: PulseDetector, force: Bool = false) {
        guard isRunning, activity != nil else { return }

        var state = BatDetectorAttributes.ContentState.idle
        if let pass = detector.lastPassResult {
            state.speciesCode = pass.species
            state.commonName = SpeciesInfo.commonName[pass.species]
            state.confidence = Double(pass.confidence)
            state.passPulseCount = detector.lastPassPulseCount
            state.lastPassDate = detector.lastPassDate
        }
        state.fpeakKHz = detector.capturedPeakFreq / 1000
        state.durationMs = detector.capturedDurationMs
        state.pulseRateHz = detector.pulseRateHz
        state.pulseCount = detector.pulseCount
        state.lastDetectionDate = detector.lastDetectionDate

        // Staleness is decided here, not in the widget — see the long note on
        // `ContentState.isIDStale`. Crossing either threshold has to register as a state
        // *change*, or the no-op guard below suppresses the very update that would let
        // the card go quiet.
        let now = Date()
        state.isIDStale = detector.lastPassDate
            .map { now.timeIntervalSince($0) > BatActivityShared.staleIDSeconds } ?? true
        state.isPulseStale = detector.lastDetectionDate
            .map { now.timeIntervalSince($0) > BatActivityShared.staleIDSeconds } ?? true
        state.isDetectionRecent = detector.lastDetectionDate
            .map { now.timeIntervalSince($0) < BatActivityShared.activeDotSeconds } ?? false

        // Drop no-op updates, so a silent night costs no budget at all. Note this only
        // helps when nothing is happening — see `heartbeatInterval` for why that isn't
        // the same as making the heartbeat free.
        if !force, let last = lastSentState, sameIgnoringTick(last, state) { return }

        tick &+= 1
        state.updateTick = tick
        schedule(state)
    }

    /// `update(from:)` against the controller's own weak `detector`. Used by the
    /// `PulseDetector.onPassFinalized` hook, which can't capture the detector itself
    /// without forming a cycle.
    func updateFromDetector(force: Bool = false) {
        guard let detector else { return }
        update(from: detector, force: force)
    }

    /// Two states differ only by `updateTick` — i.e. nothing visible changed. The tick is
    /// excluded because it's a pure animation trigger and comparing it would make every
    /// state "different", defeating the guard.
    private func sameIgnoringTick(_ a: BatDetectorAttributes.ContentState,
                                  _ b: BatDetectorAttributes.ContentState) -> Bool {
        var lhs = a, rhs = b
        lhs.updateTick = 0
        rhs.updateTick = 0
        return lhs == rhs
    }

    /// Rate-limited send. If the last update was recent, the state is parked in
    /// `pendingState` (overwriting any earlier parked state — newest wins) and a single
    /// timer task flushes it when the window opens.
    private func schedule(_ state: BatDetectorAttributes.ContentState) {
        let elapsed = Date().timeIntervalSince(lastSentAt)
        guard elapsed >= Self.minUpdateInterval else {
            pendingState = state
            guard flushTask == nil else { return }   // one flusher is enough
            let wait = Self.minUpdateInterval - elapsed
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled, let self else { return }
                self.flushTask = nil
                if let queued = self.pendingState {
                    self.pendingState = nil
                    self.send(queued)
                }
            }
            return
        }
        send(state)
    }

    private func send(_ state: BatDetectorAttributes.ContentState) {
        guard let activity else { return }
        lastSentState = state
        lastSentAt = Date()
        Task {
            // `staleDate` tells the system to dim the card if we go quiet for a full
            // minute — which is the honest signal when the app has been suspended or
            // the pipeline has stopped feeding, rather than leaving a confident-looking
            // ID on screen indefinitely.
            await activity.update(
                .init(state: state, staleDate: Date().addingTimeInterval(60))
            )
        }
    }

    private func startHeartbeat() {
        heartbeat?.invalidate()
        heartbeat = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval,
                                         repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let detector = self.detector else { return }
                self.update(from: detector)
            }
        }
    }

    /// Set once by ContentView so the heartbeat has something to read. Weak because
    /// `PulseDetector` is owned by ContentView's `@State` and outlives this controller;
    /// holding it strongly here would be a retain cycle waiting to happen once the
    /// detector gains any reference back. `end()` stops the timer either way.
    weak var detector: PulseDetector?

}
