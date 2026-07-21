//
//  AudioEngineController.swift
//  OpenBat
//
//  Owns the audio session + engine and pulls the Griff microphone's stream into
//  the app. v1 goal: confirm we receive buffers at the device's *native* sample
//  rate (target 384 kHz) — see OpenBat plan / AudioDiagnostics.
//

import AVFoundation
import Observation

/// How the captured ultrasound is rendered to the speaker for listening.
enum ListenMode: CaseIterable {
    case off
    case heterodyne
    case timeExpansion // "RTE": per-call time expansion that keeps the tempo
}

@MainActor
@Observable
final class AudioEngineController {

    // MARK: Published state

    private(set) var diagnostics = AudioDiagnostics()
    /// Slow-changing mirrors of `diagnostics` fields, published as their own
    /// observable properties so views that only need these (ContentView.body's
    /// nyquist / onChange reads) aren't invalidated by the 15 Hz stats flush —
    /// `flushStats()` mutates the `diagnostics` struct every tick (bufferCount /
    /// currentLevelDB), and @Observable tracks at whole-property granularity, so
    /// any body reading `diagnostics.<anything>` re-renders 15×/s while capturing.
    /// That churn was rebuilding the toolbar Menus mid-tap and dropping their
    /// actions. Only ever set via `syncSlowDiagnostics()` (equality-guarded,
    /// since @Observable notifies on every set, changed or not).
    private(set) var activeSampleRate: Double = 0
    private(set) var activeInputName = "—"
    /// True when the current output route is the built-in speaker rather than
    /// headphones/Bluetooth/AirPlay. Same equality-guarded-mirror pattern as
    /// `activeSampleRate` — set only from `updateInputDiagnostics()`. Drives the
    /// feedback-risk warning: heterodyne/RTE audio played out the speaker gets
    /// picked back up acoustically by the mic and reprocessed as a spurious
    /// low-pitch "call" layered on the real one. There's no software fix for
    /// acoustic coupling short of full echo cancellation, which risks degrading
    /// the ultrasonic capture path — so this only surfaces a warning telling the
    /// user to wear headphones, which is confirmed to fix it.
    private(set) var isOutputOnSpeaker = false
    private(set) var isRunning = false
    /// User-facing status / error line.
    private(set) var status = "Idle"

    /// The rate we *ask* iOS for. The Griff samples at 384 kHz; iOS may or may not
    /// honour it (the central risk this milestone validates).
    static let preferredSampleRate: Double = 384_000

    // MARK: Listening (heterodyne / time expansion)

    /// The listening DSPs. Fed from the capture tap; the active one is rendered to
    /// the speaker via a source node when `listenMode != .off`.
    let heterodyne = HeterodyneProcessor()
    let timeExpansion = TimeExpansionProcessor()
    private(set) var listenMode: ListenMode = .off
    var isListening: Bool { listenMode != .off }
    /// How far below the detected call frequency to park the LO, so the call lands
    /// at a comfortable audible tone.
    var audibleOffsetHz: Double = 1_500
    /// The LO frequency in use (for display); 0 = searching. In auto mode the
    /// tuner sets it; in manual mode the user drags it.
    private(set) var tunedFrequency: Double = 0
    /// Whether the LO is following the detected call (true) or held where the user
    /// set it (false).
    private(set) var isAutoTune = true
    /// Squelch hold: keeps the gate open for this many auto-tune ticks (~67 ms
    /// each) after the last confident detection, so brief silent gaps between
    /// pulses don't chop the audio.
    private var gateHoldTicks = 0
    private let gateHoldDuration = 8  // ≈ 530 ms at 15 Hz timer
    /// Supplies the current dominant frequency (Hz) for auto-tune, or 0 if none.
    /// Wired to the spectrogram processor's peak detector.
    var autoTunePeakProvider: (() -> Double)?
    private var sourceNode: AVAudioSourceNode?

    // MARK: Private

    private var engine = AVAudioEngine()
    private var isConfigured = false
    /// Guards against overlapping engine restarts (e.g. a route change firing
    /// while a heterodyne toggle is already reconfiguring).
    private var isReconfiguring = false
    /// `stop()`'s session deactivation, tracked so a following `configureSession()`
    /// (e.g. `setListenMode`'s stop-then-restart) can wait for it to actually finish
    /// instead of racing a `setActive(true)` against an in-flight `setActive(false)`
    /// on the session — that race was making mode switches unpredictably slow/stuck
    /// even after moving both calls off the main actor.
    private var pendingDeactivation: Task<Void, Never>?

    /// Optional sink for raw capture buffers, so later phases (FFT/spectrogram,
    /// recording) can subscribe without touching capture code. Called on a
    /// realtime audio thread — keep work minimal and non-blocking.
    var bufferSink: (@Sendable (AVAudioPCMBuffer) -> Void)?

    // Capture stats are accumulated on the realtime audio thread (under a lock)
    // and flushed to the @Observable `diagnostics` at a modest rate. Updating the
    // UI on every callback (~90/s) floods the main thread and starves the
    // spectrogram's render loop, so we throttle to `statsFlushRate`.
    private let statsLock = NSLock()
    private nonisolated(unsafe) var pendingBufferCount = 0
    private nonisolated(unsafe) var latestLevelDB: Float = AudioLevel.minDB
    /// The actual rate/channel count of delivered buffers, captured on the audio
    /// thread and flushed to diagnostics — the only reliable source of the true rate.
    private nonisolated(unsafe) var latestBufferSampleRate: Double = 0
    private nonisolated(unsafe) var latestBufferChannels: Int = 0
    private var statsTimer: Timer?
    private let statsFlushRate = 15.0 // Hz
    /// Idle-time poll for mic plug/unplug — see `prepareInputMonitoring()`.
    private var inputPollTimer: Timer?

    init() {
        registerForNotifications()
        Task { await prepareInputMonitoring() }
    }

    /// Makes the mic-connection pill work before the first start(). The session's
    /// default category is playback-only, under which `availableInputs` hides input
    /// devices entirely — the Griff would be invisible (and route-change
    /// notifications for it unreliable) until capture first configured the session.
    /// Setting a record-capable category up front fixes that; the session is NOT
    /// activated here, so this doesn't touch other apps' audio or prompt for
    /// permission.
    private func prepareInputMonitoring() async {
        await Task.detached {
            try? AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement, options: [])
        }.value
        updateInputDiagnostics()

        // Route-change notifications are only delivered while the session is
        // active, i.e. while capturing. To catch the Griff being plugged in or
        // pulled while idle — without activating the session (permission prompt,
        // interrupts other apps' audio) — poll the available inputs on a slow
        // timer. The running engine's route-change handler covers the active case.
        inputPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                self.updateInputDiagnostics()
            }
        }
    }

    // MARK: Lifecycle

    func start() async {
        guard !isRunning else { return }

        guard await requestPermission() else {
            status = "Microphone permission denied. Enable it in Settings."
            return
        }

        do {
            try await configureSession()
            try startEngine()
            startStatsTimer()
            isRunning = true
            status = diagnostics.isNativeRate
                ? "Capturing at \(Int(diagnostics.actualSampleRate)) Hz"
                : "Running, but rate clamped to \(Int(diagnostics.actualSampleRate)) Hz"
        } catch {
            status = "Failed to start: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        sourceNode = nil
        // Deactivation is a courtesy to other apps and doesn't need to block the
        // caller — off the main actor, same rationale as configureSession()'s
        // activation call (setActive can block for a while). Tracked in
        // `pendingDeactivation` so a following configureSession() (stop-then-
        // restart, e.g. setListenMode) waits for it instead of racing.
        pendingDeactivation?.cancel()
        pendingDeactivation = Task.detached(priority: .utility) {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        isRunning = false
        // Drop the meter to silence — otherwise it freezes at the last live value.
        statsLock.lock(); latestLevelDB = AudioLevel.minDB; statsLock.unlock()
        diagnostics.currentLevelDB = AudioLevel.minDB
        if status.hasPrefix("Capturing") || status.hasPrefix("Running") {
            status = "Stopped"
        }
    }

    // MARK: Stats flushing

    private func startStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / statsFlushRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushStats() }
        }
    }

    /// Copy accumulated audio-thread stats into the published diagnostics.
    private func flushStats() {
        statsLock.lock()
        let count = pendingBufferCount
        let level = latestLevelDB
        let rate = latestBufferSampleRate
        let channels = latestBufferChannels
        statsLock.unlock()
        diagnostics.bufferCount = count
        diagnostics.currentLevelDB = level
        // Correct the reported rate to what's actually being delivered (the node's
        // advertised format set at startEngine can disagree with the real buffers).
        if rate > 0 { diagnostics.actualSampleRate = rate }
        if channels > 0 { diagnostics.channelCount = channels }
        syncSlowDiagnostics()
        updateAutoTune()
    }

    /// Re-publish the slow-changing diagnostics fields to their standalone
    /// mirrors. Equality-guarded so the 15 Hz flush doesn't notify observers
    /// of `activeSampleRate`/`activeInputName` when nothing actually changed.
    private func syncSlowDiagnostics() {
        if activeSampleRate != diagnostics.actualSampleRate {
            activeSampleRate = diagnostics.actualSampleRate
        }
        if activeInputName != diagnostics.inputName {
            activeInputName = diagnostics.inputName
        }
    }

    // MARK: Permission

    private func requestPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    // MARK: Session

    /// `AVAudioSession.setCategory`/`setActive` are synchronous system calls that
    /// can block the calling thread for hundreds of milliseconds while iOS
    /// renegotiates routing — worse under `.playAndRecord` with Bluetooth options,
    /// which is exactly the category a listen-mode switch engages. Running that on
    /// the main actor (this class's default isolation) froze the whole UI for the
    /// duration, which is why switching listen mode mid-session felt unresponsive.
    /// The actual session calls are pushed onto a detached task; only the quick
    /// `@Observable` diagnostics update happens back on the main actor.
    private func configureSession() async throws {
        // Let a just-fired stop() finish deactivating before we reactivate —
        // otherwise setActive(true) here can race setActive(false) still in
        // flight from stop(), which made the session get stuck renegotiating.
        await pendingDeactivation?.value
        let listening = isListening
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()

            // `.record` keeps us off the output mixer path and is the proven 384 kHz
            // path; `.measurement` disables automatic gain control so ultrasonic
            // levels aren't reshaped. Listening needs simultaneous output, so it
            // upgrades to `.playAndRecord` (verify the rate stays native on device).
            if listening {
                try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            } else {
                try session.setCategory(.record, mode: .measurement, options: [])
            }
            try session.setPreferredSampleRate(Self.preferredSampleRate)
            // Modest IO buffer: low latency without starving the output (5 ms was tight
            // enough to risk playback underruns).
            try session.setPreferredIOBufferDuration(0.008)

            // Prefer the USB input (the Griff) over the built-in mic, if present.
            if let usbInput = session.availableInputs?.first(where: { $0.portType == .usbAudio }) {
                try session.setPreferredInput(usbInput)
            }

            try session.setActive(true)
        }.value
        isConfigured = true
        updateInputDiagnostics()
    }

    private func updateInputDiagnostics() {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.inputs.first
        diagnostics.inputName = port?.portName ?? "—"
        diagnostics.isUSBInput = port?.portType == .usbAudio
        diagnostics.usbMicAvailable = diagnostics.isUSBInput
            || session.availableInputs?.contains { $0.portType == .usbAudio } ?? false
        diagnostics.sessionSampleRate = session.sampleRate
        // Provisional until the first real buffer arrives and flushStats corrects it.
        if diagnostics.actualSampleRate == 0 { diagnostics.actualSampleRate = session.sampleRate }
        let outputPort = session.currentRoute.outputs.first
        isOutputOnSpeaker = outputPort?.portType == .builtInSpeaker
        syncSlowDiagnostics()
    }

    // MARK: Engine

    private func startEngine() throws {
        // Fresh engine each start guarantees a clean graph regardless of whether
        // the previous session attached the heterodyne output node.
        engine = AVAudioEngine()
        sourceNode = nil

        let input = engine.inputNode
        // The input node's own hardware format carries the negotiated native rate
        // for a tap that is not wired into the main mixer.
        let format = input.inputFormat(forBus: 0)

        diagnostics.sessionSampleRate = AVAudioSession.sharedInstance().sampleRate
        // Provisional from the node's advertised format; flushStats overwrites it with
        // the real delivered-buffer rate (the gap between the two is the bug we surface).
        diagnostics.actualSampleRate = format.sampleRate
        diagnostics.channelCount = Int(format.channelCount)
        syncSlowDiagnostics()

        // Feed the active listening processor from the tap, and attach its output.
        let hetero: HeterodyneProcessor? = (listenMode == .heterodyne) ? heterodyne : nil
        let timeExp: TimeExpansionProcessor? = (listenMode == .timeExpansion) ? timeExpansion : nil
        switch listenMode {
        case .heterodyne:
            heterodyne.reset(inputSampleRate: format.sampleRate)
        case .timeExpansion:
            timeExpansion.reset(inputSampleRate: format.sampleRate)
        case .off:
            break
        }
        if isListening { attachListenOutput() }

        let sink = bufferSink
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            sink?(buffer)
            hetero?.process(buffer)
            timeExp?.process(buffer)
            guard let self else { return }
            let level = AudioLevel.rmsDB(of: buffer)
            // Cheap, lock-guarded accumulation only — the UI flush happens on a
            // timer (see `flushStats`) to keep the main thread free for rendering.
            self.statsLock.lock()
            self.pendingBufferCount += 1
            self.latestLevelDB = level
            // The buffer's own format is the ground truth for the delivered rate.
            self.latestBufferSampleRate = buffer.format.sampleRate
            self.latestBufferChannels = Int(buffer.format.channelCount)
            self.statsLock.unlock()
        }

        engine.prepare()
        try engine.start()
    }

    /// Attach a source node that pulls the active listening processor's 48 kHz
    /// audio to the speaker. Only called under `.playAndRecord`, so touching
    /// `mainMixerNode` is safe.
    private func attachListenOutput() {
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: heterodyne.outputSampleRate, channels: 1) else { return }
        let hetero = heterodyne
        let timeExp = timeExpansion
        let mode = listenMode
        let node = AVAudioSourceNode(format: outFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            switch mode {
            case .heterodyne: hetero.render(out, frames: Int(frameCount))
            case .timeExpansion: timeExp.render(out, frames: Int(frameCount))
            case .off: for i in 0..<Int(frameCount) { out[i] = 0 }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFormat)
        sourceNode = node
    }

    // MARK: Listening control

    /// Switch listening mode. Because it changes the session category and the
    /// engine graph, a running capture is restarted to apply it.
    func setListenMode(_ mode: ListenMode) {
        guard mode != listenMode else { return }
        listenMode = mode
        tunedFrequency = 0
        isAutoTune = true
        gateHoldTicks = 0
        if isRunning {
            stop()
            Task { await start() }
        }
    }

    /// Called by the pulse detector at the rising edge of each detected pulse.
    /// Opens the heterodyne gate immediately (without waiting for the 67 ms stats
    /// timer) and snaps the LO to the pulse frequency when the species shifts by
    /// more than 8 kHz — fixes silent Noctule calls when the LO is locked onto
    /// a Pipistrelle, and fixes isolated short calls that end before the timer fires.
    func notifyPulseDetected(frequency: Double) {
        guard listenMode == .heterodyne, isAutoTune, frequency > 0 else { return }
        if tunedFrequency <= 0 || abs(frequency - tunedFrequency) > 8_000 {
            tunedFrequency = frequency          // snap for large species shifts
        } else {
            tunedFrequency += (frequency - tunedFrequency) * 0.3   // slew within species
        }
        heterodyne.loFrequency = max(tunedFrequency - audibleOffsetHz, 100)
        gateHoldTicks = gateHoldDuration
        heterodyne.setGate(true)
    }

    /// Switch to manual tuning and park the LO at `frequency` (clamped to the
    /// usable ultrasonic range). The squelch gate is held open in manual mode —
    /// the user has explicitly chosen a frequency to monitor.
    func setManualTune(frequency: Double) {
        isAutoTune = false
        let nyquist = diagnostics.actualSampleRate > 0 ? diagnostics.actualSampleRate / 2 : 192_000
        let clamped = min(max(frequency, 1_000), nyquist)
        tunedFrequency = clamped // the frequency we're listening at
        heterodyne.loFrequency = max(clamped - audibleOffsetHz, 100)
        heterodyne.setGate(true)
    }

    /// Hand control back to the auto-tuner.
    func enableAutoTune() {
        isAutoTune = true
    }

    /// Auto-tune: park the LO just below the detected call frequency and slew
    /// toward it. Called from the stats timer (~15 Hz). Also drives the squelch
    /// gate: opens on detection, holds for ~530 ms after the last pulse, then
    /// closes so background noise is silenced between calls.
    private func updateAutoTune() {
        guard listenMode == .heterodyne, isAutoTune else { return }
        let peak = autoTunePeakProvider?() ?? 0

        if peak > 0 {
            // `tunedFrequency` is the frequency we're listening at (the detected call);
            // the LO sits `audibleOffsetHz` below it so the call becomes audible.
            if tunedFrequency <= 0 {
                tunedFrequency = peak
            } else {
                tunedFrequency += (peak - tunedFrequency) * 0.3 // slew for stability
            }
            heterodyne.loFrequency = max(tunedFrequency - audibleOffsetHz, 100)
            gateHoldTicks = gateHoldDuration
            heterodyne.setGate(true)
        } else {
            // No detection — count down the hold; close the gate only after it expires.
            if gateHoldTicks > 0 {
                gateHoldTicks -= 1
            } else {
                heterodyne.setGate(false)
            }
        }
    }

    // MARK: Notifications

    private func registerForNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in await self?.handleRouteChange(note) }
        }

        center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleInterruption(note) }
        }
    }

    /// The Griff being plugged/unplugged shows up as a route change; rebind input
    /// and restart capture so the stream survives a reconnect.
    ///
    /// Only device add/remove warrants a restart. Reacting to *every* route change
    /// (category change, override, configuration change) caused a restart storm
    /// once heterodyne enabled the speaker output — the change itself triggered
    /// another change, hanging the app.
    private func handleRouteChange(_ note: Notification) async {
        updateInputDiagnostics()

        guard
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
            let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
        else { return }

        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            break // a device (the Griff) appeared/disappeared — rebind below
        default:
            return // category/override/config changes: ignore
        }

        guard isRunning, !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        do {
            try await configureSession()
            try startEngine()
            status = "Re-bound input: \(diagnostics.inputName)"
        } catch {
            status = "Route change error: \(error.localizedDescription)"
            stop()   // engine is in an unknown state — full stop, session preserved
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
        else { return }

        switch type {
        case .began:
            statsTimer?.invalidate()
            statsTimer = nil
            isRunning = false
            status = "Interrupted"
        case .ended:
            // Only auto-restart when iOS says the session may resume (e.g. after a
            // phone call). Restarting against the system's advice can fail or fight
            // another app for the session.
            let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            if AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                Task { await start() }
            } else {
                status = "Interrupted — tap Start to resume"
            }
        @unknown default:
            break
        }
    }
}
