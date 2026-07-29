//
//  PlaybackEngine.swift
//  OpenBat
//
//  Plays back a saved Recording WAV through the SAME listening DSPs the live
//  detector uses (HeterodyneProcessor) — a raw ultrasonic
//  WAV played straight through the speaker is inaudible (and gets lowpassed by the
//  hardware's DAC anyway), same reason live listening needs downconversion. Also
//  feeds a SpectrogramProcessor so PlaybackView can show the SAME live-style
//  scrolling Metal spectrogram the Detector screen uses, just fed from file
//  playback instead of the mic tap.
//
//  Split into two pieces, mirroring AudioEngineController's own split between a
//  @MainActor wrapper and the nonisolated, audio-thread-safe processors it owns:
//    • PlaybackEngine — @MainActor, @Observable UI-facing state (play/pause,
//      position, listen mode).
//    • PlaybackDriver — nonisolated, owns the file-reading thread that paces PCM
//      to real time and the AVAudioEngine output graph.
//

import AVFoundation
import Accelerate
import Observation

/// Nonisolated: owns the background pacing thread and the output AVAudioEngine, so
/// it can be driven independent of the main actor. `mode` is `nonisolated(unsafe)` —
/// a plain enum read/written from two threads with no sync, same benign-race
/// pattern SpectrogramProcessor's `suspended`/`peakBin` already use elsewhere.
nonisolated final class PlaybackDriver: @unchecked Sendable {
    private let heterodyne: HeterodyneProcessor
    private let timeExpansion: TimeExpansionProcessor
    private let spectrogramProcessor: SpectrogramProcessor

    nonisolated(unsafe) var mode: ListenMode = .heterodyne

    /// Called off the main thread as playback advances; the caller hops to main.
    var onProgress: ((Double) -> Void)?
    /// Called off the main thread once the file's last sample has been fed.
    var onFinished: (() -> Void)?
    /// Called off the main thread if the pacing thread can't open `url` at all —
    /// distinct from `onFinished` so the caller can tell "played to the end" apart
    /// from "never actually started" and surface the latter as an error instead of
    /// silently sitting at isPlaying == true with no progress.
    var onOpenFailed: (() -> Void)?

    private final class StopBox { var stopped = false }
    private var stopBox = StopBox()
    private var thread: Thread?
    /// Signaled by the pacing thread right before it returns. `stop()` waits on
    /// this (briefly, bounded) before returning, so a `stop()` immediately
    /// followed by `start()` (e.g. dragging the scrub slider, which calls
    /// `seek` → `stop()` then `start()` on every drop) can't leave the OLD
    /// thread's last buffer still calling `process()` on the shared Heterodyne/
    /// SpectrogramProcessor instances concurrently with the NEW
    /// thread doing the same — those are single-producer processors, and two
    /// concurrent producers racing on the same ring buffer/filter state is a
    /// real (if narrow, ~1-2ms) data race without this.
    private var stopSemaphore: DispatchSemaphore?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // MARK: Heterodyne auto-tune (mirrors AudioEngineController)
    //
    // Playback's HeterodyneProcessor was never retuned away from its class default
    // (a fixed 40 kHz LO) — the live Detector screen tunes it continuously from
    // PulseDetector triggers, but there's no PulseDetector here. For any recorded
    // call whose frequency isn't within the ~4 kHz IF passband around 40 kHz, that
    // left heterodyne played back as near-silence: this is the "listening
    // playback stopped working" bug. Fixed in `start()`'s pacing loop by running
    // the SAME auto-tune math AudioEngineController.updateAutoTune uses, driven by
    // this thread's own SpectrogramProcessor instead of a live pulse trigger —
    // both are just a dominant-frequency-in-Hz reading, so the same math applies.
    /// Matches AudioEngineController.audibleOffsetHz's default.
    private static let audibleOffsetHz: Double = 1_500

    init(heterodyne: HeterodyneProcessor,
        timeExpansion: TimeExpansionProcessor, spectrogramProcessor: SpectrogramProcessor) {
        self.heterodyne = heterodyne
        self.timeExpansion = timeExpansion
        self.spectrogramProcessor = spectrogramProcessor
    }

    // MARK: Output engine

    /// Attaches a source node pulling the active listen-mode's rendered audio to
    /// the speaker — same shape as `AudioEngineController.attachListenOutput`, just
    /// a dedicated engine instead of sharing the live capture engine's graph.
    /// Claims its own playback-capable session category below (see the doc
    /// comment there) rather than assuming the shared session is already in a
    /// state that supports output — it usually isn't. Idempotent — a second
    /// call while already running is a no-op.
    func startEngineIfNeeded() {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // AudioEngineController's shared session category is `.record` (no
        // output route at all) whenever the live Detector screen isn't
        // actively listening, or `.playAndRecord` + `.measurement` when it
        // is — this engine previously only switched MODE, never CATEGORY, so
        // whenever the session was still `.record` this source node had no
        // audible route whatsoever: that's the real cause of BOTH "can't hear
        // anything" and the greyed-out system volume slider (iOS disables the
        // volume HUD when the active category doesn't support output at all
        // — not, as a previous fix here assumed, something `.measurement`
        // mode itself disables). Explicitly claim a playback-capable category
        // for the lifetime of this engine; AudioEngineController fully
        // reconfigures the session again on its own next `start()` regardless
        // of whatever this leaves behind, so nothing needs restoring here.
        //
        // EXCEPT while the live Detector screen's AudioEngineController is
        // currently running (checked via its nonisolated static mirror, since
        // this driver has no reference to that @MainActor instance) — its own
        // input tap depends on the session staying in `.record`/`.playAndRecord`,
        // and `.playback` doesn't support input at all. Forcing the category
        // here would silently kill live capture/recording out from under it.
        // Skipping the override just means playback audio stays inaudible for
        // as long as live capture is active — the spectrogram/analysis views
        // are unaffected, since those read the WAV directly off disk rather
        // than through this session/engine.
        if !AudioEngineController.isAnyInstanceRunning {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setActive(true)
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: heterodyne.outputSampleRate, channels: 1)
        else { return }
        let hetero = heterodyne
        let timeExp = timeExpansion
        let node = AVAudioSourceNode(format: outFormat) { [weak self] _, _, frameCount, audioBufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = buffers[0].mData else { return noErr }
            let out = data.assumingMemoryBound(to: Float.self)
            switch self.mode {
            case .heterodyne:        hetero.render(out, frames: Int(frameCount))
            case .timeExpansion:     timeExp.render(out, frames: Int(frameCount))
            // Live-only mode; PlaybackDriver never has this set (see ListenMode's
            // doc comment) but is handled explicitly to keep the switch exhaustive.
            case .off, .adaptiveTimeExpansion:
                for i in 0..<Int(frameCount) { out[i] = 0 }
            }
            return noErr
        }
        let e = AVAudioEngine()
        e.attach(node)
        e.connect(node, to: e.mainMixerNode, format: outFormat)
        e.prepare()
        try? e.start()
        engine = e
        sourceNode = node
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        sourceNode = nil
        // No session category/mode restore needed — AudioEngineController
        // unconditionally sets its own category/mode fresh every time IT
        // starts (see configureSession()), regardless of what this engine
        // leaves the shared session in.
    }

    // MARK: Pacing thread

    /// Reads `url`'s PCM starting at `fromSample`, pacing reads to real elapsed
    /// wall-clock time (catch-up/slow-down each tick rather than a fixed
    /// per-timer-tick sample count, which drifts). Normally paced at the file's
    /// own sample rate, so the processors — and the listener — get audio in
    /// real time. In `.timeExpansion` it's paced at `timeExpansion.outputSampleRate`
    /// (48 kHz) instead of the file's native rate (384 kHz) — i.e. only
    /// 1/8th as many file-samples are released per real second — which is the
    /// ENTIRE mechanism behind that mode's 8× slowdown: TimeExpansionProcessor
    /// itself is a dumb pass-through that has no idea it's being fed slowly (see
    /// its own doc comment). `mode` is captured once per `start()` call, not
    /// re-read per tick — PlaybackEngine.listenMode's didSet restarts playback
    /// from the current position on any mode change specifically so this pacing
    /// rate can never go stale mid-run. Feeds every buffer to
    /// `spectrogramProcessor` (display) and to heterodyne/timeExpansion
    /// regardless of which `mode` currently selects for audible
    /// output (keeps heterodyne warm so switching into it is instant);
    /// `.off` still advances the spectrogram, just renders silence.
    func start(url: URL, sampleRate: Double, totalSamples: Int, fromSample: Int) {
        stop()
        let box = StopBox()
        stopBox = box
        let semaphore = DispatchSemaphore(value: 0)
        stopSemaphore = semaphore
        let hetero = heterodyne
        let timeExp = timeExpansion
        let paceMode = mode
        let paceRate: Double = (paceMode == .timeExpansion) ? timeExp.outputSampleRate : sampleRate
        let spec = spectrogramProcessor
        let onProgress = onProgress
        let onFinished = onFinished
        let onOpenFailed = onOpenFailed

        let t = Thread {
            defer { semaphore.signal() }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                if !box.stopped { onOpenFailed?() }
                return
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(44 + fromSample * 2))
            guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            else {
                if !box.stopped { onOpenFailed?() }
                return
            }

            var samplesFed = fromSample
            let startWall = Date()
            let maxChunk = 1 << 14   // ~16k samples (~43 ms @ 384 kHz) per read
            var int16Buf = [Int16](repeating: 0, count: maxChunk)
            // Heterodyne auto-tune state — local to this pacing run, same as
            // `samplesFed` above, so every fresh play()/seek() restart re-tunes
            // from scratch rather than carrying over a stale target.
            var tunedFrequency: Double = 0
            var gateHoldSamplesRemaining = 0
            // ~530 ms, matching AudioEngineController's gateHoldDuration (8 ticks @ ~67 ms).
            let gateHoldSamples = Int(sampleRate * 0.53)

            while !box.stopped, samplesFed < totalSamples {
                let elapsed = Date().timeIntervalSince(startWall)
                let shouldHaveFed = fromSample + Int(elapsed * paceRate)
                guard shouldHaveFed > samplesFed else { usleep(2_000); continue }
                let want = min(shouldHaveFed - samplesFed, min(maxChunk, totalSamples - samplesFed))
                guard want > 0 else { continue }
                guard let data = try? handle.read(upToCount: want * 2), !data.isEmpty else { break }
                let n = data.count / 2
                guard n > 0 else { continue }
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    int16Buf.withUnsafeMutableBufferPointer { dst in
                        for i in 0..<n { dst[i] = src[i] }
                    }
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(n)),
                      let floatCh = buffer.floatChannelData?[0]
                else { break }
                buffer.frameLength = AVAudioFrameCount(n)
                int16Buf.withUnsafeBufferPointer { srcBuf in
                    vDSP_vflt16(srcBuf.baseAddress!, 1, floatCh, 1, vDSP_Length(n))
                    var scale: Float = 1.0 / 32767.0
                    vDSP_vsmul(floatCh, 1, &scale, floatCh, 1, vDSP_Length(n))
                }

                spec.process(buffer)
                // Nothing drains `spec`'s pending FFT columns here (unlike the live
                // Detector screen, whose SpectrogramView.drain()s every frame to feed
                // the Metal renderer) — WavPlayerView shows a static, whole-file
                // spectrogram instead, so `pending` would otherwise grow forever
                // (~6 MB/sec) for the lifetime of playback. `peakBin`/`peakLevel`
                // (read via `spec.peakFrequency` below) are written directly inside
                // `process()`/`makeColumn`, not sourced from `pending`, so discarding
                // the drained columns doesn't affect auto-tune.
                _ = spec.drain()

                // Auto-tune the heterodyne LO from this same buffer's dominant
                // frequency — see the doc comment on `Self.audibleOffsetHz` above.
                // Only matters while `mode == .heterodyne`, but cheap enough to
                // skip unconditionally rather than add another mode branch.
                let peak = spec.peakFrequency
                if peak > 0 {
                    tunedFrequency = tunedFrequency <= 0
                        ? peak
                        : tunedFrequency + (peak - tunedFrequency) * 0.3
                    hetero.loFrequency = max(tunedFrequency - Self.audibleOffsetHz, 100)
                    gateHoldSamplesRemaining = gateHoldSamples
                    hetero.setGate(true)
                } else if gateHoldSamplesRemaining > 0 {
                    gateHoldSamplesRemaining -= n
                } else {
                    hetero.setGate(false)
                }

                hetero.process(buffer)       // kept warm regardless of `mode`, so
                                              // switching mid-playback doesn't cold-start
                // timeExp is NOT kept warm the same way: it's only ever fed while
                // paceMode == .timeExpansion, because its ring assumes samples
                // arrive at the (slowed) pace this run committed to — feeding it
                // at the native real-time pace of the other two modes would just
                // build up a backlog it's never asked to render.
                if paceMode == .timeExpansion { timeExp.process(buffer) }

                samplesFed += n
                if !box.stopped { onProgress?(Double(samplesFed) / sampleRate) }
            }
            if !box.stopped { onFinished?() }
        }
        t.qualityOfService = .userInitiated
        t.name = "bat.PlaybackDriver"
        t.start()
        thread = t
    }

    func stop() {
        stopBox.stopped = true
        // Bounded wait (not indefinite — never risk hanging the caller, which is
        // typically the main actor via PlaybackEngine): the thread checks
        // `box.stopped` at least every 2ms (see the pacing loop's usleep), so a
        // 200ms timeout is generous headroom, not a real limit in practice.
        _ = stopSemaphore?.wait(timeout: .now() + 0.2)
        stopSemaphore = nil
        thread = nil
    }
}

@MainActor
@Observable
final class PlaybackEngine {

    private(set) var isPlaying = false
    private(set) var currentTimeSeconds: Double = 0
    private(set) var durationSeconds: Double = 0
    /// Which Recording is loaded — nil when nothing's been picked yet.
    private(set) var loadedURL: URL?
    /// Set whenever `load()` or the pacing thread itself can't actually get audio
    /// out of the file — surfaced by PlaybackView instead of leaving play() a
    /// silent no-op (see the WavHeader/FileHandle guards below).
    private(set) var loadError: String?

    var listenMode: ListenMode = .heterodyne {
        didSet {
            guard oldValue != listenMode else { return }
            driver.mode = listenMode
            // The squelch gate is driven per-buffer by the pacing thread's own
            // auto-tune (see PlaybackDriver.start()) — it opens/closes from the
            // file's actual detected content, same as the live Detector screen's
            // pulse-triggered gate, so no explicit setGate here.
            //
            // Time expansion paces file reads at a different rate than
            // heterodyne (see PlaybackDriver.start's
            // `paceRate`), and that rate is fixed for the life of one `start()`
            // call. Restart the pacing thread from the current position on ANY
            // mode change so a switch into or out of `.timeExpansion` picks up
            // the right pace immediately instead of running at whatever rate was
            // captured when playback began.
            if isPlaying, let url = loadedURL {
                if listenMode == .timeExpansion { timeExpansion.reset(inputSampleRate: sampleRate) }
                // `driver.start` stops the previous pacing thread itself before
                // starting the new one — no need to call `driver.stop()` here too.
                driver.start(url: url, sampleRate: sampleRate, totalSamples: totalSamples,
                            fromSample: Int(currentTimeSeconds * sampleRate))
            }
        }
    }

    let heterodyne = HeterodyneProcessor()
    let timeExpansion = TimeExpansionProcessor()
    let spectrogramProcessor = SpectrogramProcessor()

    // Not part of the @Observable-tracked UI state — an internal implementation
    // detail SwiftUI never reads directly, so it's excluded from observation.
    @ObservationIgnored private var driver: PlaybackDriver!
    /// The loaded file's sample rate — read by PlaybackView to size the
    /// spectrogram's frequency axis (`maxFrequency = sampleRate / 2`).
    private(set) var sampleRate: Double = 384_000
    private var totalSamples: Int = 0

    init() {
        driver = PlaybackDriver(heterodyne: heterodyne,
                                timeExpansion: timeExpansion, spectrogramProcessor: spectrogramProcessor)
        driver.mode = listenMode
        driver.onProgress = { [weak self] t in
            DispatchQueue.main.async { self?.currentTimeSeconds = t }
        }
        driver.onFinished = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                WavPlayerDebugLog.log("PlaybackEngine", "onFinished: reached end of file")
                self.isPlaying = false
                self.currentTimeSeconds = self.durationSeconds
            }
        }
        driver.onOpenFailed = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                WavPlayerDebugLog.log("PlaybackEngine", "onOpenFailed: pacing thread couldn't open the file")
                self.isPlaying = false
                self.loadError = "Couldn't open the recording for playback."
            }
        }
    }

    /// Loads a Recording's WAV — resets playback to the start. Call `play()`
    /// afterward to start listening.
    func load(url: URL) {
        stop()
        guard FileManager.default.fileExists(atPath: url.path) else {
            WavPlayerDebugLog.log("PlaybackEngine", "load: file missing at \(url.path)")
            loadError = "Recording file is missing on disk: \(url.lastPathComponent)"
            return
        }
        guard let (sr, total) = Self.readHeader(url: url) else {
            WavPlayerDebugLog.log("PlaybackEngine", "load: header read FAILED for \(url.lastPathComponent)")
            loadError = "Recording's WAV header couldn't be read: \(url.lastPathComponent)"
            return
        }
        loadError = nil
        loadedURL = url
        sampleRate = sr
        totalSamples = total
        durationSeconds = sr > 0 ? Double(total) / sr : 0
        currentTimeSeconds = 0
        spectrogramProcessor.sampleRate = sr
        heterodyne.reset(inputSampleRate: sr)
        timeExpansion.reset(inputSampleRate: sr)
        WavPlayerDebugLog.log("PlaybackEngine", "load: OK \(url.lastPathComponent) sampleRate=\(sr) duration=\(String(format: "%.1f", durationSeconds))s")
    }

    func togglePlaying() { isPlaying ? pause() : play() }

    func play() {
        guard let url = loadedURL, !isPlaying else { return }
        // Playback finished (currentTimeSeconds sits at durationSeconds via
        // onFinished) — treat play() as "play again" rather than a silent no-op
        // that leaves the button looking unresponsive once a file has ended.
        if currentTimeSeconds >= durationSeconds { currentTimeSeconds = 0 }
        WavPlayerDebugLog.log("PlaybackEngine", "play: from \(String(format: "%.2f", currentTimeSeconds))s, mode=\(listenMode)")
        isPlaying = true
        driver.startEngineIfNeeded()
        driver.start(url: url, sampleRate: sampleRate, totalSamples: totalSamples,
                    fromSample: Int(currentTimeSeconds * sampleRate))
    }

    func pause() {
        WavPlayerDebugLog.log("PlaybackEngine", "pause: at \(String(format: "%.2f", currentTimeSeconds))s")
        isPlaying = false
        driver.stop()
    }

    /// Scrubs to `t` seconds, restarting the pacing thread from there (resumes
    /// playing if it was already playing).
    func seek(toSeconds t: Double) {
        WavPlayerDebugLog.log("PlaybackEngine", "seek: to \(String(format: "%.2f", t))s (wasPlaying=\(isPlaying))")
        let wasPlaying = isPlaying
        driver.stop()
        isPlaying = false
        currentTimeSeconds = min(max(0, t), durationSeconds)
        if wasPlaying { play() }
    }

    func stop() {
        pause()
        driver.stopEngine()
        loadedURL = nil
        currentTimeSeconds = 0
        durationSeconds = 0
    }

    private static func readHeader(url: URL) -> (sampleRate: Double, totalSamples: Int)? {
        guard let header = WavHeader.read(url: url) else { return nil }
        return (Double(header.sampleRate), Int(header.dataBytes) / 2)
    }
}
