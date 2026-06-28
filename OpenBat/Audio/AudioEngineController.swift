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
    private var statsTimer: Timer?
    private let statsFlushRate = 15.0 // Hz

    init() {
        registerForNotifications()
    }

    // MARK: Lifecycle

    func start() async {
        guard !isRunning else { return }

        guard await requestPermission() else {
            status = "Microphone permission denied. Enable it in Settings."
            return
        }

        do {
            try configureSession()
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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
        statsLock.unlock()
        diagnostics.bufferCount = count
        diagnostics.currentLevelDB = level
        updateAutoTune()
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

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()

        // `.record` keeps us off the output mixer path and is the proven 384 kHz
        // path; `.measurement` disables automatic gain control so ultrasonic
        // levels aren't reshaped. Listening needs simultaneous output, so it
        // upgrades to `.playAndRecord` (verify the rate stays native on device).
        if isListening {
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
        isConfigured = true
        updateInputDiagnostics()
    }

    private func updateInputDiagnostics() {
        let session = AVAudioSession.sharedInstance()
        let port = session.currentRoute.inputs.first
        diagnostics.inputName = port?.portName ?? "—"
        diagnostics.isUSBInput = port?.portType == .usbAudio
        diagnostics.actualSampleRate = session.sampleRate
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

        diagnostics.actualSampleRate = format.sampleRate
        diagnostics.channelCount = Int(format.channelCount)

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
        if isRunning {
            stop()
            Task { await start() }
        }
    }

    /// Switch to manual tuning and park the LO at `frequency` (clamped to the
    /// usable ultrasonic range).
    func setManualTune(frequency: Double) {
        isAutoTune = false
        let nyquist = diagnostics.actualSampleRate > 0 ? diagnostics.actualSampleRate / 2 : 192_000
        let clamped = min(max(frequency, 1_000), nyquist)
        tunedFrequency = clamped // the frequency we're listening at
        heterodyne.loFrequency = max(clamped - audibleOffsetHz, 100)
    }

    /// Hand control back to the auto-tuner.
    func enableAutoTune() {
        isAutoTune = true
    }

    /// Auto-tune: park the LO just below the detected call frequency and slew
    /// toward it. Called from the stats timer (~15 Hz). Holds the last value when
    /// there's no confident detection.
    private func updateAutoTune() {
        guard listenMode == .heterodyne, isAutoTune, let peak = autoTunePeakProvider?(), peak > 0 else { return }
        // `tunedFrequency` is the frequency we're listening at (the detected call);
        // the LO sits `audibleOffsetHz` below it so the call becomes audible.
        if tunedFrequency <= 0 {
            tunedFrequency = peak
        } else {
            tunedFrequency += (peak - tunedFrequency) * 0.3 // slew for stability
        }
        heterodyne.loFrequency = max(tunedFrequency - audibleOffsetHz, 100)
    }

    // MARK: Notifications

    private func registerForNotifications() {
        let center = NotificationCenter.default

        center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            Task { @MainActor in self?.handleRouteChange(note) }
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
    private func handleRouteChange(_ note: Notification) {
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
            try configureSession()
            try startEngine()
            status = "Re-bound input: \(diagnostics.inputName)"
        } catch {
            status = "Route change error: \(error.localizedDescription)"
            isRunning = false
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
            isRunning = false
            status = "Interrupted"
        case .ended:
            Task { await start() }
        @unknown default:
            break
        }
    }
}
