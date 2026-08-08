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
    /// Classic time expansion of a FILE: play a recording back slower, preserving
    /// every sample (see TimeExpansionProcessor). Playback only — rendered by
    /// PlaybackEngine, and treated as `.off` by live capture, which can't pace
    /// itself slower than real time without falling permanently behind.
    case timeExpansion
    /// LIVE event-triggered time expansion (see AdaptiveTimeExpansionProcessor).
    /// Live-capture only — the counterpart to `.timeExpansion`, which is
    /// file-playback only.
    case adaptiveTimeExpansion
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
    /// feedback-risk warning: listening audio played out the speaker gets
    /// picked back up acoustically by the mic and reprocessed as a spurious
    /// low-pitch "call" layered on the real one. There's no software fix for
    /// acoustic coupling short of full echo cancellation, which risks degrading
    /// the ultrasonic capture path — so this only surfaces a warning telling the
    /// user to wear headphones, which is confirmed to fix it.
    private(set) var isOutputOnSpeaker = false
    private(set) var isRunning = false {
        didSet {
            guard oldValue != isRunning else { return }
            Self.isAnyInstanceRunning = isRunning
        }
    }
    /// Nonisolated, thread-safe mirror of `isRunning` — lets `PlaybackDriver`
    /// (which has no reference to this @MainActor instance, and whose own
    /// AVAudioEngine/session setup runs off-main) check whether the live
    /// Detector screen currently owns the shared AVAudioSession before forcing
    /// it into `.playback` category. See `PlaybackEngine.startEngineIfNeeded`'s
    /// doc comment for why clobbering the category while this is true would
    /// break live capture out from under it.
    nonisolated(unsafe) static var isAnyInstanceRunning = false
    /// User-facing status / error line.
    private(set) var status = "Idle"

    /// The rate we *ask* iOS for. The Griff samples at 384 kHz; iOS may or may not
    /// honour it (the central risk this milestone validates).
    /// `nonisolated`: an immutable Sendable constant read from `configureSession`'s
    /// detached (non-main-actor) task — without this it inherits this class's
    /// `@MainActor` isolation by the project's default and can't be read from there.
    nonisolated static let preferredSampleRate: Double = 384_000

    // MARK: Listening (heterodyne / adaptive time expansion)

    /// The listening DSPs. Fed from the capture tap; the active one is rendered to
    /// the speaker via a source node when `listenMode != .off`.
    let heterodyne = HeterodyneProcessor()
    let adaptiveTimeExpansion = AdaptiveTimeExpansionProcessor()
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

    // MARK: Demo mode

    /// Display name of the file currently feeding the pipeline in place of the
    /// microphone, or nil for normal capture. Set by `startDemo`, cleared by
    /// `endDemo` — there is deliberately no way to leave demo mode by accident,
    /// since a demo that silently reverted to the mic would be worse than one
    /// that has to be ended explicitly.
    private(set) var demoFileName: String?
    var isDemoMode: Bool { demoURL != nil }
    private var demoURL: URL?
    private var demoSource: DemoFileSource?

    // Capture stats are accumulated on the realtime audio thread (under a lock)
    // and flushed to the @Observable `diagnostics` at a modest rate. Updating the
    // UI on every callback (~90/s) floods the main thread and starves the
    // spectrogram's render loop, so we throttle to `statsFlushRate`.
    private let statsLock = NSLock()
    // The compiler suggests plain `nonisolated` over `nonisolated(unsafe)` here, but
    // that's wrong once `@Observable`'s macro expansion is in the picture: it turns
    // these into tracked accessors that plain `nonisolated` can't attach to ("cannot
    // be applied to mutable stored properties"). `(unsafe)` is the one that actually
    // works with the macro — `statsLock` is what makes concurrent access from the
    // audio thread + `flushStats()` safe, same as before.
    private nonisolated(unsafe) var pendingBufferCount = 0
    private nonisolated(unsafe) var latestLevelDB: Float = AudioLevel.minDB
    /// The actual rate/channel count of delivered buffers, captured on the audio
    /// thread and flushed to diagnostics — the only reliable source of the true rate.
    private nonisolated(unsafe) var latestBufferSampleRate: Double = 0
    private nonisolated(unsafe) var latestBufferChannels: Int = 0
    // Mic-QA running stats — accumulated since the current capture's start(),
    // reset by `resetSessionStats()`. See `AudioDiagnostics`'s doc comments for
    // what each one is for.
    private nonisolated(unsafe) var sessionNoiseFloorDB: Float = 0
    private nonisolated(unsafe) var sessionPeakDB: Float = AudioLevel.minDB
    private nonisolated(unsafe) var latestDCOffset: Float = 0
    private nonisolated(unsafe) var sessionClippedCount = 0
    private nonisolated(unsafe) var sessionTotalSamples: Int64 = 0
    private var statsTimer: Timer?
    private let statsFlushRate = 15.0 // Hz
    /// Idle-time poll for mic plug/unplug — see `prepareInputMonitoring()`.
    private var inputPollTimer: Timer?

    /// Run-loop- and NotificationCenter-retained resources, parked in their own
    /// object so they get torn down when this controller is released.
    ///
    /// `deinit` on a `@MainActor` class is nonisolated and so can't touch this
    /// controller's own isolated stored properties; a separate reference held as
    /// a `let` gets released alongside it and can clean up from its own deinit.
    /// Both resources genuinely outlive their owner otherwise: a scheduled
    /// `Timer` is retained by the run loop (nulling the property does NOT stop
    /// it), and a block-based notification observer is retained by the center.
    private final class Cleanup: @unchecked Sendable {
        // Named slots rather than an array: `startStatsTimer()` runs on every
        // start(), so appending would accumulate spent Timer objects for the
        // life of the controller.
        var pollTimer: Timer?
        var statsTimer: Timer?
        var tokens: [any NSObjectProtocol] = []
        deinit {
            // A Timer must be invalidated on the run loop that scheduled it, and
            // deinit can run on any thread — hand both back to main.
            let timers = [pollTimer, statsTimer].compactMap { $0 }
            let tokens = self.tokens
            DispatchQueue.main.async {
                timers.forEach { $0.invalidate() }
                tokens.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }
    }
    private let cleanup = Cleanup()
    private var isActivated = false

    /// Deliberately empty — all setup lives in `activate()`.
    ///
    /// This type is constructed as a SwiftUI `@State` default value, and that
    /// expression is re-evaluated every time the enclosing view's initializer
    /// runs, which SwiftUI may do any number of times per view identity (it
    /// keeps the first result and discards the rest). Registering observers or
    /// scheduling a repeating timer here therefore leaked one of each per
    /// re-evaluation — and because the run loop retains a scheduled Timer, the
    /// discarded controllers' 2 s poll timers kept firing on the main thread
    /// forever. That accumulation is what eventually wedged the UI.
    init() {}

    /// Begins idle mic monitoring. Call once from the owning view's `.task` —
    /// never from an initializer. Idempotent.
    func activate() {
        guard !isActivated else { return }
        isActivated = true
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
        let poll = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            // `[weak self]` on the Task itself, not just the outer Timer closure —
            // implicitly closing over the outer closure's captured `self` from inside
            // the Task reads as referencing a `var` across a concurrency boundary
            // (a real Swift 6 error), even though it's just a weak class reference.
            Task { @MainActor [weak self] in
                guard let self, !self.isRunning else { return }
                self.updateInputDiagnostics()
            }
        }
        inputPollTimer = poll
        cleanup.pollTimer = poll
    }

    // MARK: Lifecycle

    func start() async {
        guard !isRunning else { return }

        if let demoURL {
            await startDemoCapture(url: demoURL)
            return
        }

        guard await requestPermission() else {
            status = "Microphone permission denied. Enable it in Settings."
            return
        }

        do {
            resetSessionStats()
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
        demoSource?.stop()
        demoSource = nil
        // Never touch `inputNode` on the demo path: it was never tapped, and
        // merely accessing it instantiates the input unit — which under the
        // `.playback` category demo mode uses (and on a device with no input at
        // all, e.g. the simulator) is a needless way to fail.
        if !isDemoMode { engine.inputNode.removeTap(onBus: 0) }
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
        if status.hasPrefix("Capturing") || status.hasPrefix("Running") || status.hasPrefix("Demo") {
            status = "Stopped"
        }
    }

    // MARK: Demo mode

    /// Point the pipeline at `url` instead of the microphone and start feeding.
    /// A running capture is stopped first, the same as a listen-mode switch.
    /// `name` is what the UI shows (the bundled clip's title, or a recording's
    /// species/date label) — `url.lastPathComponent` is a UUID for app-made
    /// recordings and means nothing to a viewer.
    func startDemo(url: URL, name: String) async {
        if isRunning { stop() }
        demoURL = url
        demoFileName = name
        await start()
    }

    /// Return to the microphone. Stops the demo feed; does NOT resume live
    /// capture — the user starts that themselves, so ending a demo can't
    /// surprise anyone by opening the mic.
    func endDemo() {
        if isRunning { stop() }
        demoURL = nil
        demoFileName = nil
        demoSource = nil
        status = "Demo ended"
        // Demo mode suppressed these (see `updateInputDiagnostics`); refresh now
        // rather than waiting up to 2 s for the idle poll to correct the panel.
        updateInputDiagnostics()
    }

    /// The demo counterpart to `startEngine()`. Deliberately never touches
    /// `engine.inputNode`: with no tap and no input unit, this path needs no
    /// microphone permission and no record-capable session, which is what lets
    /// the whole pipeline run in the simulator.
    private func startDemoCapture(url: URL) async {
        do {
            resetSessionStats()
            let source = try DemoFileSource(url: url)
            let rate = source.sampleRate

            // The engine only exists here to carry the listening source node to
            // the speaker. With listening off there is no graph to build at all.
            if isListening {
                try await configureSession(playbackOnly: true)
                engine = AVAudioEngine()
                sourceNode = nil
                attachListenOutput()
                engine.prepare()
                try engine.start()
            }

            // Same fields `startEngine()`/`updateInputDiagnostics()` fill from
            // the hardware, sourced from the file instead. Everything downstream
            // is rate-parametric, so a demo clip at a rate other than 384 kHz
            // still drives the pipeline correctly — it just has a lower Nyquist.
            diagnostics.sessionSampleRate = rate
            diagnostics.actualSampleRate = rate
            diagnostics.channelCount = source.channelCount
            diagnostics.inputName = "Demo — \(demoFileName ?? url.lastPathComponent)"
            diagnostics.inputUID = "demo"
            diagnostics.isUSBInput = false
            diagnostics.usbMicAvailable = false
            syncSlowDiagnostics()

            switch listenMode {
            case .heterodyne:
                heterodyne.reset(inputSampleRate: rate)
            case .adaptiveTimeExpansion:
                adaptiveTimeExpansion.reset(inputSampleRate: rate)
            case .off, .timeExpansion:
                break
            }

            // Identical fan-out to the live tap closure in `startEngine()`.
            let sink = bufferSink
            let hetero: HeterodyneProcessor? = (listenMode == .heterodyne) ? heterodyne : nil
            let adaptive: AdaptiveTimeExpansionProcessor? = (listenMode == .adaptiveTimeExpansion) ? adaptiveTimeExpansion : nil
            source.start { [weak self] buffer in
                sink?(buffer)
                hetero?.process(buffer)
                adaptive?.process(buffer)
                self?.consume(buffer)
            }
            demoSource = source

            startStatsTimer()
            isRunning = true
            status = "Demo: \(demoFileName ?? url.lastPathComponent) at \(Int(rate)) Hz"
        } catch {
            status = "Demo failed to start: \(error.localizedDescription)"
            stop()
        }
    }

    // MARK: Stats flushing

    /// Zeroes the mic-QA running stats for a fresh test run. Called at the top
    /// of `start()` so every capture gives a clean set of numbers to read after
    /// `stop()` — not reset by `stop()` itself, so those numbers stay on screen
    /// to be read/copied after the test finishes.
    private func resetSessionStats() {
        statsLock.lock()
        sessionNoiseFloorDB = 0
        sessionPeakDB = AudioLevel.minDB
        latestDCOffset = 0
        sessionClippedCount = 0
        sessionTotalSamples = 0
        statsLock.unlock()
        diagnostics.noiseFloorDB = 0
        diagnostics.peakLevelDB = AudioLevel.minDB
        diagnostics.dcOffsetPercent = 0
        diagnostics.clippedSampleCount = 0
        diagnostics.totalSampleCount = 0
    }

    private func startStatsTimer() {
        statsTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / statsFlushRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushStats() }
        }
        statsTimer = timer
        cleanup.statsTimer = timer
    }

    /// Copy accumulated audio-thread stats into the published diagnostics.
    private func flushStats() {
        statsLock.lock()
        let count = pendingBufferCount
        let level = latestLevelDB
        let rate = latestBufferSampleRate
        let channels = latestBufferChannels
        let noiseFloor = sessionNoiseFloorDB
        let peak = sessionPeakDB
        let dcOffset = latestDCOffset
        let clipped = sessionClippedCount
        let totalSamples = sessionTotalSamples
        statsLock.unlock()
        diagnostics.bufferCount = count
        diagnostics.currentLevelDB = level
        // Correct the reported rate to what's actually being delivered (the node's
        // advertised format set at startEngine can disagree with the real buffers).
        if rate > 0 { diagnostics.actualSampleRate = rate }
        if channels > 0 { diagnostics.channelCount = channels }
        diagnostics.noiseFloorDB = noiseFloor
        diagnostics.peakLevelDB = peak
        diagnostics.dcOffsetPercent = dcOffset * 100
        diagnostics.clippedSampleCount = clipped
        diagnostics.totalSampleCount = totalSamples
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
    /// - Parameter playbackOnly: demo mode with listening on — the engine needs
    ///   an active session to reach the speaker, but no input. `.playback`
    ///   keeps demo mode entirely off the record path: no permission prompt, no
    ///   input route negotiation, nothing to go wrong where there's no mic.
    private func configureSession(playbackOnly: Bool = false) async throws {
        // Let a just-fired stop() finish deactivating before we reactivate —
        // otherwise setActive(true) here can race setActive(false) still in
        // flight from stop(), which made the session get stuck renegotiating.
        await pendingDeactivation?.value
        if playbackOnly {
            try await Task.detached(priority: .userInitiated) {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default, options: [])
                try session.setActive(true)
            }.value
            isConfigured = true
            return
        }
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
        // In demo mode the "input" is a file, and `startDemoCapture` has already
        // written the right values here. Letting the idle poll or a route change
        // overwrite them would put the real mic's name back in the diagnostics
        // panel and the mic pill while a file is actually feeding the pipeline.
        guard !isDemoMode else { return }
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.inputs.first
        diagnostics.inputName = port?.portName ?? "—"
        diagnostics.inputUID = port?.uid ?? "—"
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
        let adaptive: AdaptiveTimeExpansionProcessor? = (listenMode == .adaptiveTimeExpansion) ? adaptiveTimeExpansion : nil
        switch listenMode {
        case .heterodyne:
            heterodyne.reset(inputSampleRate: format.sampleRate)
        case .adaptiveTimeExpansion:
            adaptiveTimeExpansion.reset(inputSampleRate: format.sampleRate)
        case .off, .timeExpansion:
            // .timeExpansion is playback-only (see ListenMode's doc comment) and
            // never reaches here in practice — ContentView doesn't offer it as a
            // live listen mode — but is handled explicitly rather than falling
            // through a `default:` so a future live mode addition can't silently
            // land in the wrong bucket.
            break
        }
        if isListening { attachListenOutput() }

        let sink = bufferSink
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            sink?(buffer)
            hetero?.process(buffer)
            adaptive?.process(buffer)
            self?.consume(buffer)
        }

        engine.prepare()
        try engine.start()
    }

    /// Accumulate one buffer's capture stats. Called on the realtime audio
    /// thread from the tap, and on `DemoFileSource`'s queue in demo mode —
    /// `nonisolated` because neither is the main actor. Everything it touches is
    /// either a `let` or guarded by `statsLock`.
    private nonisolated func consume(_ buffer: AVAudioPCMBuffer) {
        let level = AudioLevel.rmsDB(of: buffer)
        let analysis = AudioLevel.analyze(buffer)
        // Cheap, lock-guarded accumulation only — the UI flush happens on a
        // timer (see `flushStats`) to keep the main thread free for rendering.
        statsLock.lock()
        pendingBufferCount += 1
        latestLevelDB = level
        // The buffer's own format is the ground truth for the delivered rate.
        latestBufferSampleRate = buffer.format.sampleRate
        latestBufferChannels = Int(buffer.format.channelCount)
        sessionNoiseFloorDB = min(sessionNoiseFloorDB, level)
        sessionPeakDB = max(sessionPeakDB, analysis.peakDB)
        latestDCOffset = analysis.dcOffset
        sessionClippedCount += analysis.clipped
        sessionTotalSamples += Int64(analysis.sampleCount)
        statsLock.unlock()
    }

    /// Attach a source node that pulls the active listening processor's 48 kHz
    /// audio to the speaker. Only called under `.playAndRecord`, so touching
    /// `mainMixerNode` is safe.
    private func attachListenOutput() {
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: heterodyne.outputSampleRate, channels: 1) else { return }
        let hetero = heterodyne
        let adaptive = adaptiveTimeExpansion
        let mode = listenMode
        let node = AVAudioSourceNode(format: outFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            switch mode {
            case .heterodyne: hetero.render(out, frames: Int(frameCount))
            case .adaptiveTimeExpansion: adaptive.render(out, frames: Int(frameCount))
            case .off, .timeExpansion: for i in 0..<Int(frameCount) { out[i] = 0 }
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

        // Both handlers below take Sendable enum/primitive values, not the
        // `Notification` itself — `Notification` isn't Sendable, and capturing it
        // into the `Task` closure (which crosses into `@MainActor` from this
        // `@Sendable` NotificationCenter callback) is a real Swift 6 concurrency
        // error, not just a strictness warning. Extracting the needed values here,
        // before the `Task` is created, keeps everything crossing the boundary
        // Sendable.
        // Tokens are retained (see `Cleanup`) so these registrations are removed
        // when the controller goes away — the center holds block-based observers
        // itself, so they otherwise survive their owner.
        cleanup.tokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: raw)
            else { return }
            Task { @MainActor in await self?.handleRouteChange(reason) }
        })

        cleanup.tokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: raw)
            else { return }
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in self?.handleInterruption(type, optionsRaw: optionsRaw) }
        })
    }

    /// The Griff being plugged/unplugged shows up as a route change; rebind input
    /// and restart capture so the stream survives a reconnect.
    ///
    /// Only device add/remove warrants a restart. Reacting to *every* route change
    /// (category change, override, configuration change) caused a restart storm
    /// once heterodyne enabled the speaker output — the change itself triggered
    /// another change, hanging the app.
    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) async {
        updateInputDiagnostics()

        // A demo feed has no input to rebind, and the restart below would tear
        // down the file source to re-tap a mic it never used. Plugging the Griff
        // in mid-demo is a route change worth ignoring.
        guard !isDemoMode else { return }

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

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, optionsRaw: UInt) {
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
            if AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume) {
                Task { await start() }
            } else {
                status = "Interrupted — tap Start to resume"
            }
        @unknown default:
            break
        }
    }
}
