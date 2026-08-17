//
//  AudioEngineController.swift
//  OpenBat
//
//  Owns the AVAudioSession + AVAudioEngine and pulls the Griff microphone's
//  stream (or, in demo mode, a paced file) into the app, confirming along the
//  way that iOS actually delivers the device's native sample rate rather than
//  silently downsampling — see `AudioDiagnostics`.
//
//  @MainActor: all published state lives here. Session/engine setup that can
//  block for hundreds of ms runs on a detached task, never on the main actor —
//  see `configureSession`. Capture stats are accumulated on the realtime audio
//  thread under `statsLock` and flushed to `diagnostics` on a timer; don't touch
//  `diagnostics` directly from the tap closure. See Context.md §6.
//

import AVFoundation
import Observation
import Synchronization   // Atomic, for the realtime-thread-safe snippet routing

/// How the captured ultrasound is rendered to the speaker for listening.
/// `Int`-backed so it can live in an `Atomic` the realtime threads read — see
/// `AudioEngineController.liveMode`. Nothing persists these raw values, so the
/// numbering is free to change.
enum ListenMode: Int, CaseIterable {
    case off
    case heterodyne
    /// Classic time expansion of a FILE: play a recording back slower, preserving
    /// every sample (see TimeExpansionProcessor). Playback only — rendered by
    /// PlaybackEngine, and treated as `.off` by live capture, which can't pace
    /// itself slower than real time without falling permanently behind.
    case timeExpansion
    /// LIVE snippet expansion in the Pettersson D240x pattern: capture a window
    /// around a trigger, replay it once at 1/N, be deaf to new snippets until it
    /// finishes, with heterodyne continuing underneath. See
    /// SnippetExpansionProcessor, and Context.md §5 for which live expansion
    /// shapes are permitted and why this one is.
    ///
    /// This is how live expansion escapes the objection in `.timeExpansion`'s
    /// comment above: it does not try to keep pace with real time at all. It
    /// falls behind deliberately and then gives up the interval, rather than
    /// deciding what to keep in order to catch up.
    case snippetExpansion
}

@MainActor
@Observable
final class AudioEngineController {

    // MARK: Published state

    private(set) var diagnostics = AudioDiagnostics()
    /// Slow-changing mirrors of `diagnostics` fields, published as their own
    /// observable properties so views that only need these (ContentView.body's
    /// nyquist / onChange reads) aren't invalidated by the 15 Hz stats flush.
    /// @Observable tracks at whole-property granularity, so any body reading
    /// `diagnostics.<anything>` would re-render 15×/s while capturing. Only ever
    /// set via `syncSlowDiagnostics()` (equality-guarded, since @Observable
    /// notifies on every set, changed or not). See Context.md §13.
    private(set) var activeSampleRate: Double = 0
    private(set) var activeInputName = "—"
    /// Whether a USB (ultrasonic) mic is attached at all, active route or not.
    /// Same equality-guarded-mirror pattern as `activeInputName`, and it exists
    /// for the same reason: the first-connection calibration offer has to watch
    /// this from `ContentView`'s modifier chain, and reading
    /// `diagnostics.usbMicAvailable` there would re-render the whole detector
    /// 15×/s while capturing. Mirrors `diagnostics.usbMicAvailable` exactly —
    /// don't let the two definitions drift.
    private(set) var ultrasonicMicAttached = false
    /// True when the current output route is the built-in speaker rather than
    /// headphones/Bluetooth/AirPlay. Same equality-guarded-mirror pattern as
    /// `activeSampleRate` — set only from `updateInputDiagnostics()`. Drives the
    /// feedback-risk warning: listening audio played out the speaker gets picked
    /// back up by the mic and reprocessed as a spurious low-pitch "call". No
    /// software fix short of full echo cancellation, which risks degrading the
    /// ultrasonic capture path, so this only warns the user to wear headphones.
    /// See Context.md §6.
    private(set) var isOutputOnSpeaker = false
    private(set) var isRunning = false {
        didSet {
            guard oldValue != isRunning else { return }
            Self.isAnyInstanceRunning = isRunning
        }
    }
    /// True only while `setListenMode` is crossing the `.off` boundary, i.e. across
    /// the deliberate stop-and-start that a session-category change forces (see
    /// `setListenMode`). Capture really has stopped in that window — this does not
    /// pretend otherwise; it marks the stop as one the user did not ask for and is
    /// about to be undone.
    private(set) var isSwitchingListenMode = false

    /// What the UI should treat as "detecting": running, or briefly between the two
    /// halves of a listen-mode restart. `isRunning` alone makes the Start button
    /// flick back to its idle ear and the transport buttons disable themselves for
    /// a few hundred ms every time the mode crosses `.off` — reporting a stop the
    /// user did not ask for. Anything that acts on capture actually being down
    /// (finalizing a pass, stopping the pump) must keep using `isRunning`.
    var isActive: Bool { isRunning || isSwitchingListenMode }

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

    // MARK: Listening (heterodyne)

    /// The listening DSP. Fed from the capture tap; rendered to the speaker via a
    /// source node when `listenMode != .off`. Heterodyne is currently the only
    /// live listening mode — see ListenMode.
    let heterodyne = HeterodyneProcessor()
    /// Live snippet expansion (D240x pattern) — see SnippetExpansionProcessor,
    /// and Context.md §5's rule on which live expansion shapes are permitted.
    let snippetExpansion = SnippetExpansionProcessor()
    /// What reaches the speaker in `.snippetExpansion`, as an atomic rather than
    /// a read of the settings object: the output render block runs on the
    /// realtime thread and must not touch main-actor state, and changing routing
    /// has to take effect immediately, without the engine restart
    /// `setListenMode` performs.
    ///
    /// Boxed in a class because `Atomic` is non-copyable and so cannot be
    /// captured into the `AVAudioSourceNode` render closure directly; the
    /// closure captures this reference instead.
    private final class RoutingBox: @unchecked Sendable {
        let value = Atomic<Int>(SnippetOutputRouting.both.rawValue)
    }
    private let snippetRouting = RoutingBox()

    /// Set the live routing for `.snippetExpansion`. Safe to call while running.
    func setSnippetRouting(_ routing: SnippetOutputRouting) {
        snippetRouting.value.store(routing.rawValue, ordering: .releasing)
    }
    /// The listen mode as the realtime threads see it: read per capture buffer by
    /// the tap, and per callback by the output render block, rather than captured
    /// into those closures when they are built.
    ///
    /// That indirection is the whole reason switching between two *listening*
    /// modes no longer restarts the engine. Captured, the mode was baked into the
    /// tap closure and into the source node at install time, so changing it meant
    /// rebuilding both — i.e. a full stop-and-start. Read from here, one tap and
    /// one node serve every listening mode and the switch is a single atomic
    /// store. See `setListenMode`.
    ///
    /// Boxed for the same reason as `RoutingBox` above: `Atomic` is non-copyable
    /// and so can't be captured into a render closure directly.
    private final class ModeBox: @unchecked Sendable {
        let value = Atomic<Int>(ListenMode.off.rawValue)
    }
    private let liveMode = ModeBox()

    /// Mirrored into `liveMode` on every write, so the audio thread and the main
    /// actor can never disagree about which mode is running.
    private(set) var listenMode: ListenMode = .off {
        didSet { liveMode.value.store(listenMode.rawValue, ordering: .releasing) }
    }
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
    /// Scratch for summing replay + heterodyne in `.snippetExpansion`, so the
    /// realtime render block never allocates. Stored on `cleanup` rather than
    /// here because it is manually allocated and must survive into `deinit`.
    private var snippetMixBuffer: UnsafeMutableBufferPointer<Float>? {
        get { cleanup.snippetMixBuffer }
        set { cleanup.snippetMixBuffer = newValue }
    }
    /// How far heterodyne drops while a snippet is sounding. −6 dB: enough to put
    /// the replay in front without losing the live channel, which is the whole
    /// reason both are audible at once.
    private static let snippetHeterodyneDuck: Float = 0.5
    /// Per-sample slew for that duck — ~40 ms at 48 kHz, so the live channel
    /// steps back and returns smoothly around a replay instead of clicking.
    private static let snippetDuckSlew: Float = 1.0 / (48_000 * 0.04)

    /// Makeup gain applied to EVERYTHING leaving the listen output node, on top
    /// of each processor's own gain.
    ///
    /// Live listening was far quieter than file playback at the same system
    /// volume — quiet enough at maximum to be unusable in the field — while
    /// PlaybackEngine, playing the same calls through the same speaker, was
    /// loud. The two differ in exactly one relevant way: PlaybackEngine runs the
    /// session as `.playback`/`.default`, and live listening runs it as
    /// `.playAndRecord`/`.measurement`. `.measurement` attenuates the output
    /// path substantially — that is part of what "no signal processing" means,
    /// and it is not separately adjustable.
    ///
    /// The obvious fix — drop `.measurement` while listening — is barred:
    /// `.measurement` is what disables automatic gain control on the INPUT, and
    /// without it every amplitude number the app reports becomes a lie
    /// (Context.md §6, which calls it not optional). So the compensation is
    /// digital and lives here, on the output side only, where it cannot reach
    /// capture, the recorder, detection or calibration.
    ///
    /// `+12 dB`, with the soft clip below rather than a hard clamp so a close
    /// pass distorts gracefully instead of buzzing. The processors' own gains
    /// (heterodyne 6×, replay 4×) are unchanged and remain the knobs to tune per
    /// bat; this is a fixed correction for a fixed attenuation.
    private static let listenOutputMakeupGain: Float = 4.0
    /// Where the soft clip starts. Below this the makeup gain is exactly linear.
    private static let listenSoftClipThreshold: Float = 0.7

    /// Output-thread-only duck level, boxed so the render closure can carry it
    /// across callbacks without capturing `self` (main-actor) or allocating.
    private final class DuckBox: @unchecked Sendable { var level: Float = 1 }
    private let snippetDuck = DuckBox()

    // MARK: Private

    private var engine = AVAudioEngine()
    private var isConfigured = false
    /// Guards against overlapping engine restarts (e.g. a route change firing
    /// while a heterodyne toggle is already reconfiguring).
    private var isReconfiguring = false
    /// `stop()`'s session deactivation, tracked so a following `configureSession()`
    /// (e.g. `setListenMode`'s stop-then-restart) waits for it to finish rather
    /// than racing `setActive(true)` against an in-flight `setActive(false)`.
    /// See Context.md §6.
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

    // MARK: Delivered-rate debounce
    //
    // The delivered buffer rate is ground truth (see `consume`), but it is not
    // STABLE across a plug-in: attaching the Griff tears the engine down and
    // rebuilds it, and while iOS renegotiates the route the input node can hand
    // out 48 kHz buffers for a few hundred ms before the native 384 kHz stream
    // settles — and a USB device that enumerates more than once does that more
    // than once. Published straight through, that made the mic pill flick
    // between a red "48 kHz" and a green "384 kHz" while the user watched, which
    // reads as "the mic doesn't work" at exactly the moment it started to.
    //
    // So a CHANGED rate has to hold before it is published. Asymmetrically: a
    // rate at or above native is believed quickly, while a drop below native —
    // the alarming claim, and the one a route transient produces — has to
    // survive a full second and a half of flushes before the pill is allowed to
    // say it. A genuinely clamped feed still reports, just not instantly; a
    // transient during renegotiation never reaches the UI at all.
    private var pendingRate: Double = 0
    private var pendingRateTicks = 0
    /// ~0.33 s at 15 Hz.
    private let rateRiseConfirmTicks = 5
    /// ~1.5 s at 15 Hz.
    private let rateDropConfirmTicks = 23
    /// Idle-time poll for mic plug/unplug — see `prepareInputMonitoring()`.
    private var inputPollTimer: Timer?

    /// Run-loop- and NotificationCenter-retained resources, parked in their own
    /// object so they get torn down when this controller is released.
    ///
    /// `deinit` on a `@MainActor` class is nonisolated and so can't touch this
    /// controller's own isolated stored properties; a separate reference held as
    /// a `let` gets released alongside it and can clean up from its own deinit.
    /// A scheduled `Timer` is retained by the run loop regardless of what happens
    /// to this property, and a block-based notification observer is retained by
    /// the center — both need this explicit teardown or they outlive their owner.
    private final class Cleanup: @unchecked Sendable {
        // Named slots rather than an array: `startStatsTimer()` runs on every
        // start(), so appending would accumulate spent Timer objects for the
        // life of the controller.
        var pollTimer: Timer?
        var statsTimer: Timer?
        var tokens: [any NSObjectProtocol] = []
        /// The snippet mixing scratch. Parked here for the same reason as the
        /// timers: it is manually allocated and `deinit` on the @MainActor owner
        /// cannot reach an isolated stored property to free it.
        var snippetMixBuffer: UnsafeMutableBufferPointer<Float>?
        deinit {
            // A Timer must be invalidated on the run loop that scheduled it, and
            // deinit can run on any thread — hand both back to main.
            let timers = [pollTimer, statsTimer].compactMap { $0 }
            let tokens = self.tokens
            snippetMixBuffer?.deallocate()
            DispatchQueue.main.async {
                timers.forEach { $0.invalidate() }
                tokens.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }
    }
    private let cleanup = Cleanup()
    private var isActivated = false

    /// Deliberately empty — all setup lives in `activate()`. This type is
    /// constructed as a SwiftUI `@State` default value, an expression SwiftUI
    /// may re-evaluate any number of times per view identity, keeping the first
    /// result and discarding the rest. Registering observers or timers here
    /// would leak one per discarded evaluation. See Context.md §6.
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
            case .snippetExpansion:
                heterodyne.reset(inputSampleRate: rate)
                snippetExpansion.reset(inputSampleRate: rate)
            case .off, .timeExpansion:
                break
            }

            // Identical fan-out to the live tap closure in `startEngine()`,
            // including reading the mode per buffer — a demo is exactly where a
            // listen-mode switch gets tried repeatedly.
            let sink = bufferSink
            let hetero = heterodyne
            let snippet = snippetExpansion
            let modeBox = liveMode
            source.start { [weak self] buffer in
                sink?(buffer)
                let mode = ListenMode(rawValue: modeBox.value.load(ordering: .acquiring)) ?? .off
                if mode == .heterodyne || mode == .snippetExpansion { hetero.process(buffer) }
                if mode == .snippetExpansion { snippet.process(buffer) }
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
        // A half-counted rate change from the previous capture must not carry
        // into this one — the next flush would adopt it a tick or two later.
        pendingRate = 0
        pendingRateTicks = 0
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
        // advertised format set at startEngine can disagree with the real buffers)
        // — but only once it has held, see the debounce fields' comment.
        if rate > 0 { publishDeliveredRate(rate) }
        if channels > 0 { diagnostics.channelCount = channels }
        diagnostics.noiseFloorDB = noiseFloor
        diagnostics.peakLevelDB = peak
        diagnostics.dcOffsetPercent = dcOffset * 100
        diagnostics.clippedSampleCount = clipped
        diagnostics.totalSampleCount = totalSamples
        syncSlowDiagnostics()
        updateAutoTune()
    }

    /// Adopt a delivered buffer rate into `diagnostics.actualSampleRate` once it
    /// has held for long enough to be believed — see the debounce fields above
    /// for why this can't just be an assignment.
    ///
    /// The first rate of a capture is adopted immediately: there is nothing on
    /// screen yet for it to flicker against, and making the pill wait a third of
    /// a second to say anything at all would be its own regression.
    private func publishDeliveredRate(_ rate: Double) {
        guard rate != diagnostics.actualSampleRate else {
            pendingRate = 0
            pendingRateTicks = 0
            return
        }
        guard diagnostics.actualSampleRate > 0 else {
            diagnostics.actualSampleRate = rate
            pendingRate = 0
            pendingRateTicks = 0
            return
        }
        if rate == pendingRate {
            pendingRateTicks += 1
        } else {
            pendingRate = rate
            pendingRateTicks = 1
        }
        let needed = rate < diagnostics.actualSampleRate ? rateDropConfirmTicks : rateRiseConfirmTicks
        guard pendingRateTicks >= needed else { return }
        diagnostics.actualSampleRate = rate
        pendingRate = 0
        pendingRateTicks = 0
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
        if ultrasonicMicAttached != diagnostics.usbMicAvailable {
            ultrasonicMicAttached = diagnostics.usbMicAvailable
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
    /// can block for hundreds of milliseconds while iOS renegotiates routing —
    /// worse under `.playAndRecord` with Bluetooth options, which is exactly the
    /// category a listen-mode switch engages. So the actual session calls run on
    /// a detached task, never the main actor; only the quick `@Observable`
    /// diagnostics update happens back on main. See Context.md §6.
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
        //
        // Only written when nothing better is known, matching the same guard in
        // `updateInputDiagnostics`. Straight after a session-category change the
        // input node can advertise 48 kHz for the few ms before real buffers
        // arrive, and this drives `ContentView.nyquist` — so writing it
        // unconditionally collapsed the spectrogram's frequency axis to 24 kHz and
        // then snapped it back on the next stats flush, every time a listen-mode
        // change restarted the engine. A genuinely changed rate (a different mic)
        // still lands within one flush, ~67 ms later.
        if diagnostics.actualSampleRate == 0 {
            diagnostics.actualSampleRate = format.sampleRate
        }
        diagnostics.channelCount = Int(format.channelCount)
        syncSlowDiagnostics()

        switch listenMode {
        case .heterodyne:
            heterodyne.reset(inputSampleRate: format.sampleRate)
        case .snippetExpansion:
            heterodyne.reset(inputSampleRate: format.sampleRate)
            snippetExpansion.reset(inputSampleRate: format.sampleRate)
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
        let hetero = heterodyne
        let snippet = snippetExpansion
        let modeBox = liveMode
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            sink?(buffer)
            // Which processors to feed is decided PER BUFFER from the atomic, not
            // captured here — that is what lets a heterodyne↔slow-replay switch
            // happen under a running tap. `.snippetExpansion` feeds BOTH: heterodyne
            // is part of that mode, not an alternative to it, and the routing choice
            // between them is made at render time.
            let mode = ListenMode(rawValue: modeBox.value.load(ordering: .acquiring)) ?? .off
            if mode == .heterodyne || mode == .snippetExpansion { hetero.process(buffer) }
            if mode == .snippetExpansion { snippet.process(buffer) }
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
        let snippet = snippetExpansion
        let routingBox = snippetRouting
        let duckBox = snippetDuck
        let modeBox = liveMode
        // Mixing scratch for `.snippetExpansion`. Allocated here, on the main
        // thread at attach time — the render block below runs on the realtime
        // output thread and must not allocate. Sized well past any plausible
        // frameCount; the block clamps rather than trusting that.
        let mixCapacity = 4096
        let mixBuffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: mixCapacity)
        mixBuffer.initialize(repeating: 0)
        snippetMixBuffer?.deallocate()
        snippetMixBuffer = mixBuffer

        let node = AVAudioSourceNode(format: outFormat) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            let n = Int(frameCount)
            // Per callback, not captured at attach time — one node serves every
            // listening mode, so a mode switch needs no graph change.
            // Advance the replay state machine without anyone hearing it, by
            // rendering into the scratch and throwing the audio away.
            //
            // This exists because the phase machine's ONLY route back to
            // `.recording` is the tail of `SnippetExpansionProcessor.render`
            // (see the `produced < frames` branch there). `process()` refuses to
            // capture while the phase is `.replaying`, so a routing choice that
            // never calls `render` doesn't merely mute the replay — it parks the
            // processor in `.replaying` forever and the mode goes permanently
            // deaf, with no user-visible cause and no way back short of changing
            // routing again. Rendering-and-discarding keeps the machine on
            // exactly the same timeline as the audible path.
            //
            // Chunked, so a frameCount larger than the scratch can't reintroduce
            // the same freeze by skipping the call — the old `.both` path had
            // that edge in its `guard n <= mixCapacity` bail-out.
            func advanceSnippetSilently(frames: Int) {
                var remaining = frames
                while remaining > 0 {
                    let chunk = min(remaining, mixCapacity)
                    snippet.render(mixBuffer.baseAddress!, frames: chunk)
                    remaining -= chunk
                }
            }

            let mode = ListenMode(rawValue: modeBox.value.load(ordering: .acquiring)) ?? .off
            switch mode {
            case .heterodyne:
                hetero.render(out, frames: n)
            case .snippetExpansion:
                let routing = SnippetOutputRouting(rawValue: routingBox.value.load(ordering: .acquiring))
                    ?? .both
                switch routing {
                case .expansionOnly:
                    snippet.render(out, frames: n)
                case .heterodyneOnly:
                    // The snippet processor still runs its state machine on the
                    // capture thread; it simply isn't heard. That keeps switching
                    // routing mid-pass from restarting anything — but it only
                    // holds if the replay side keeps being advanced too, hence
                    // the discard render.
                    advanceSnippetSilently(frames: n)
                    hetero.render(out, frames: n)
                case .both:
                    guard n <= mixCapacity else {
                        advanceSnippetSilently(frames: n)
                        hetero.render(out, frames: n)
                        break
                    }
                    // Replay into the scratch, heterodyne into the output, then
                    // sum — ducking heterodyne only while a replay is actually
                    // sounding, so the live channel is at full level between
                    // snippets rather than permanently attenuated.
                    let sounding = snippet.render(mixBuffer.baseAddress!, frames: n)
                    hetero.render(out, frames: n)
                    // Ramp the duck rather than stepping it. Applied as a flat
                    // per-buffer factor it jumps 6 dB at the first and last
                    // buffer of every replay — a step on the live channel, i.e.
                    // an audible click at exactly the moment the replay is
                    // supposed to fade in.
                    let target: Float = sounding ? Self.snippetHeterodyneDuck : 1.0
                    var d = duckBox.level
                    let slew = Self.snippetDuckSlew
                    for i in 0..<n {
                        if d < target { d = min(d + slew, target) }
                        else if d > target { d = max(d - slew, target) }
                        out[i] = out[i] * d + mixBuffer[i]
                    }
                    duckBox.level = d
                }
            case .off, .timeExpansion:
                for i in 0..<n { out[i] = 0 }
                return noErr
            }
            // Applied once, to whatever the mode produced, so heterodyne, replay
            // and the mix of the two are corrected identically — see
            // `listenOutputMakeupGain`. `.off` returns above rather than
            // multiplying a buffer of zeroes.
            let makeup = Self.listenOutputMakeupGain
            let knee = Self.listenSoftClipThreshold
            for i in 0..<n {
                let x = out[i] * makeup
                let mag = abs(x)
                if mag <= knee {
                    out[i] = x
                } else {
                    // Quadratic soft knee: continuous in value and slope at
                    // `knee`, asymptotic to ±1, so loud passes compress instead
                    // of squaring off into a buzz.
                    let over = (mag - knee) / (1 - knee)
                    let shaped = knee + (1 - knee) * (over / (1 + over))
                    out[i] = x < 0 ? -shaped : shaped
                }
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: outFormat)
        sourceNode = node
    }

    // MARK: Listening control

    /// Switch listening mode.
    ///
    /// **Between two listening modes this is now in-place** — no stop, no restart,
    /// no gap in capture. The graph is identical for every listening mode: the tap
    /// feeds whichever processors `liveMode` names, and the one source node renders
    /// whichever output it names, so switching is a single atomic store.
    ///
    /// **Crossing `.off` still restarts**, and can't not. The session category
    /// itself differs — `.record`/`.measurement` while merely detecting, which is
    /// the proven 384 kHz path (Context.md §6), versus `.playAndRecord` to reach
    /// the speaker — and changing category means deactivating and reactivating the
    /// session, which tears the engine down with it. The visible artefacts of that
    /// restart (the Start button reverting to its idle ear, the spectrogram's
    /// frequency axis jumping while the rate is provisional) are covered by
    /// `isActive` and by `startEngine`'s guard on `actualSampleRate` respectively.
    ///
    /// The old behaviour restarted on EVERY switch, which besides looking broken
    /// dropped `isRunning` — and ContentView's `onChange(of: audio.isRunning)`
    /// finalizes the current pass and disarms the recorder when that happens. So
    /// cycling listen mode with recording armed used to silently disarm it. That
    /// is now true only for the two transitions that cross `.off`.
    func setListenMode(_ mode: ListenMode) {
        guard mode != listenMode else { return }
        // Read before `listenMode` is assigned: this is "was listening AND will be".
        let inPlace = isRunning && isListening && mode != .off

        if inPlace {
            // Entering slow replay hands the audio thread a processor that has been
            // idle, possibly since a different sample rate.
            //
            // **This must happen before the mode is published**, and that ordering
            // is a memory-safety requirement, not a nicety: `reset` deallocates and
            // reallocates the snippet ring buffer, so overlapping it with a
            // `process()` call on the capture thread is a use-after-free. While
            // `liveMode` still names the old mode, neither the tap nor the render
            // block touches `snippetExpansion` at all — which is exactly what makes
            // this reset safe here and unsafe one line later.
            //
            // Heterodyne is deliberately NOT reset: it is audible in both modes, and
            // resetting it mid-listen would click.
            if mode == .snippetExpansion {
                let rate = activeSampleRate > 0 ? activeSampleRate : diagnostics.actualSampleRate
                if rate > 0 { snippetExpansion.reset(inputSampleRate: rate) }
            }
            listenMode = mode      // didSet publishes to the realtime threads
            // The LO and auto-tune state are deliberately left alone. Heterodyne is
            // running and audible across this switch, so zeroing `tunedFrequency`
            // would drop it back to "searching" and re-acquire a bat it is already
            // tuned to — the audible equivalent of the restart this avoids.
            return
        }

        // Crossing `.off`: the restart below rebuilds the graph from `listenMode`,
        // so this assignment is what the new engine reads on the way up.
        listenMode = mode
        tunedFrequency = 0
        isAutoTune = true
        gateHoldTicks = 0
        if isRunning {
            isSwitchingListenMode = true
            stop()
            Task {
                await start()
                isSwitchingListenMode = false
            }
        }
    }

    /// Called by the pulse detector at the rising edge of each detected pulse.
    /// Opens the heterodyne gate immediately (without waiting for the 67 ms stats
    /// timer) and snaps the LO to the pulse frequency when the species shifts by
    /// more than 8 kHz — fixes silent Noctule calls when the LO is locked onto
    /// a Pipistrelle, and fixes isolated short calls that end before the timer fires.
    func notifyPulseDetected(frequency: Double) {
        // Arm a snippet on the rising edge. The processor ignores this unless it
        // is idle, so "replay once, no retrigger while replaying" needs no state
        // here. Trigger latency does not matter: the 50% pretrigger means the
        // pulse that armed the capture is already in the ring, so a main-actor
        // hop cannot clip its onset.
        if listenMode == .snippetExpansion {
            snippetExpansion.trigger()
        }
        guard listenMode == .heterodyne || listenMode == .snippetExpansion,
              isAutoTune, frequency > 0 else { return }
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
        // `.snippetExpansion` carries a live heterodyne bed, so it wants the same
        // auto-tune and squelch behaviour as `.heterodyne` itself.
        guard listenMode == .heterodyne || listenMode == .snippetExpansion,
              isAutoTune else { return }
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
    /// Only device add/remove warrants a restart — reacting to every route change
    /// risks a restart storm (a change triggering another change). See Context.md §6.
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
