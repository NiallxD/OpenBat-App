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
/// The ordered real-sample ranges one playback run will actually read, and
/// the concatenated ("virtual") timeline they form. Playing the whole file is
/// just the one-region case, so the pacing thread has a single code path
/// whether or not silence is being removed.
nonisolated struct PlayPlan: Sendable {
    let regions: [Range<Int>]
    /// Prefix sums: `virtualStarts[i]` is where `regions[i]` begins in the
    /// concatenated timeline.
    let virtualStarts: [Int]
    let virtualTotal: Int

    init(regions: [Range<Int>], totalSamples: Int) {
        let usable = regions.filter { !$0.isEmpty }
        // Never empty — an empty plan would be a timeline with no audio in it
        // and nothing downstream is prepared for that.
        let resolved = usable.isEmpty ? [0..<max(totalSamples, 0)] : usable
        var starts: [Int] = []
        starts.reserveCapacity(resolved.count)
        var cursor = 0
        for region in resolved {
            starts.append(cursor)
            cursor += region.count
        }
        self.regions = resolved
        self.virtualStarts = starts
        self.virtualTotal = cursor
    }

    /// The region a virtual position falls in — the last one starting at or
    /// before it. Clamped, so an out-of-range position lands on an end rather
    /// than off the array.
    func regionIndex(forVirtual v: Int) -> Int {
        guard regions.count > 1 else { return 0 }
        let clamped = min(max(v, 0), max(virtualTotal - 1, 0))
        var lo = 0, hi = regions.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if virtualStarts[mid] <= clamped { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func realSample(forVirtual v: Int, regionIndex i: Int) -> Int {
        guard i < regions.count else { return regions.last?.upperBound ?? 0 }
        let offset = min(max(v - virtualStarts[i], 0), regions[i].count)
        return regions[i].lowerBound + offset
    }
}

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
    /// followed by `start()` (e.g. dragging the scrub slider) can't leave the
    /// OLD thread's last buffer racing the NEW thread on the shared, single-
    /// producer Heterodyne/SpectrogramProcessor instances. See Context.md §15
    /// (review finding 1.1).
    private var stopSemaphore: DispatchSemaphore?
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?

    // MARK: Heterodyne auto-tune (mirrors AudioEngineController)
    //
    // There's no PulseDetector on the playback path to drive the LO, so
    // `start()`'s pacing loop runs the same auto-tune math as
    // AudioEngineController.updateAutoTune, driven by this thread's own
    // SpectrogramProcessor reading instead of a live pulse trigger. Without it,
    // heterodyne stays parked at its class-default 40 kHz LO and any recorded
    // call outside that narrow passband plays back as near-silence.
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
    /// The rate the output node is currently running at — the rate the
    /// active mode's ring is DRAINED at, and therefore (together with the
    /// pacing thread's `paceRate`, which fills it) the thing that sets
    /// playback speed. Rebuilding the node is the only way to change it.
    private(set) var outputSampleRate: Double = 0

    /// Brings the output graph up at `sampleRate`, rebuilding it if it is
    /// already running at a different one. Idempotent at an unchanged rate,
    /// so this is safe to call before every `start()`.
    func configureOutput(sampleRate: Double) {
        if engine != nil, outputSampleRate == sampleRate { return }
        if engine != nil { stopEngine() }
        startEngine(outputRate: sampleRate)
    }

    private func startEngine(outputRate: Double) {
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        // The shared session's category is whatever AudioEngineController last
        // left it in — `.record` (no output route at all) whenever the live
        // Detector screen isn't actively listening. This engine must explicitly
        // claim a playback-capable category itself rather than assume one is
        // already active, or this source node has no audible route. Nothing
        // needs restoring afterwards: AudioEngineController fully reconfigures
        // the session on its own next `start()` regardless of what this leaves.
        //
        // EXCEPT while AudioEngineController is currently running (checked via
        // its nonisolated static mirror, since this driver has no reference to
        // that @MainActor instance) — its input tap depends on the session
        // staying in `.record`/`.playAndRecord`, and `.playback` doesn't support
        // input at all. Forcing the category here would kill live capture out
        // from under it, so the override is skipped and playback audio simply
        // stays inaudible for as long as live capture is active.
        if !AudioEngineController.isAnyInstanceRunning {
            try? session.setCategory(.playback, mode: .default, options: [])
        }
        try? session.setActive(true)
        // NOT the hardware rate: the node declares the rate its own samples
        // are at and the engine's mixer resamples to whatever the hardware is
        // running. That indirection is what lets time expansion play at a
        // speed other than the one its ring was hardcoded to — see
        // PlaybackEngine.expansionFactor.
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 1)
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
            // `.snippetExpansion` is live-only: it captures from the microphone
            // tap around a trigger, which has no counterpart in file playback
            // (where `.timeExpansion` already expands the whole recording).
            // PlaybackView never selects it; silence rather than a `default:` so
            // a future mode still has to be considered here.
            case .off, .snippetExpansion:
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
        outputSampleRate = outputRate
    }

    func stopEngine() {
        engine?.stop()
        engine = nil
        sourceNode = nil
        outputSampleRate = 0
        // No session category/mode restore needed — AudioEngineController
        // unconditionally sets its own category/mode fresh every time IT
        // starts (see configureSession()), regardless of what this engine
        // leaves the shared session in.
    }

    // MARK: Pacing thread

    /// The splice window at each kept region's edge — long enough that
    /// joining two non-adjacent parts of the recording doesn't click,
    /// deliberately far shorter than the margin `SilenceMap` pads around
    /// every pulse (5 ms at its tightest) so it always lands in that margin
    /// and can never reach the call itself — the failure the
    /// adaptive-expansion work hit, where a ramp longer than the pre-roll put
    /// every call onset part-way down the fade.
    ///
    /// What happens INSIDE the window is a crossfade with the hidden audio
    /// leading into the next region, not a fade to silence — see
    /// `applySeamEnvelope`. Fading out and back in was the audible defect:
    /// the recording's background hiss dropped to nothing for the length of
    /// the splice, twice per gap, which at 8x expansion is a ~32 ms hole
    /// shortly before every call.
    private static let seamFadeSeconds = 0.002

    /// Reads `url`'s PCM, pacing reads to real elapsed wall-clock time
    /// (catch-up/slow-down each tick rather than a fixed per-timer-tick sample
    /// count, which drifts).
    ///
    /// `paceRate` is how many FILE samples are released per real second, and
    /// it is the entire mechanism behind playing slower: the processors are
    /// dumb pass-throughs with no idea they are being fed slowly (see
    /// TimeExpansionProcessor's doc comment). Feeding at `paceRate` while the
    /// output node drains at `outputSampleRate` gives a slowdown of
    /// `outputSampleRate / paceRate` — the caller sets both, which is why the
    /// speed is now a control rather than a consequence of the ring's
    /// hardcoded 48 kHz.
    ///
    /// `regions` are the real-sample ranges to actually play, in order — the
    /// whole file as a single range normally, or the kept segments of a
    /// `SilenceMap` when silence removal is on. The thread jumps its read
    /// position at each boundary, so hidden audio is never read, never fed to
    /// any processor, and takes no time to "play through". `fromVirtual` and
    /// every `onProgress` value are therefore positions in the CONCATENATED
    /// timeline these regions form, not raw file offsets.
    ///
    /// `mode` is captured once per `start()` call, not re-read per tick —
    /// PlaybackEngine restarts playback from the current position on any mode
    /// or speed change specifically so this pacing rate can never go stale
    /// mid-run. Feeds every buffer to `spectrogramProcessor` (display) and to
    /// heterodyne/timeExpansion regardless of which `mode` currently selects
    /// for audible output (keeps heterodyne warm so switching into it is
    /// instant); `.off` still advances the spectrogram, just renders silence.
    func start(url: URL, sampleRate: Double, totalSamples: Int,
               fromVirtual: Int, paceRate: Double, regions: [Range<Int>]) {
        stop()
        let box = StopBox()
        stopBox = box
        let semaphore = DispatchSemaphore(value: 0)
        stopSemaphore = semaphore
        let hetero = heterodyne
        let timeExp = timeExpansion
        let paceMode = mode
        let spec = spectrogramProcessor
        let onProgress = onProgress
        let onFinished = onFinished
        let onOpenFailed = onOpenFailed
        let plan = PlayPlan(regions: regions, totalSamples: totalSamples)
        let seamFade = max(1, Int(sampleRate * Self.seamFadeSeconds))
        // What separates the sample being FED from the sample being HEARD:
        // the active processor's output ring (which deliberately holds a
        // standing ~100 ms so drift can be corrected losslessly — see
        // TimeExpansionProcessor's `softTarget`) plus the output hardware's
        // own buffering. Published positions correct for both; without that
        // the playhead ran a tenth of a second ahead of the speaker, so every
        // call was heard just AFTER it had passed under the playhead, with
        // what looked like a silent gap in front of it.
        let drainRate = outputSampleRate > 0 ? outputSampleRate : sampleRate
        let session = AVAudioSession.sharedInstance()
        let hardwareLatency = session.outputLatency + session.ioBufferDuration

        let t = Thread {
            defer { semaphore.signal() }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                if !box.stopped { onOpenFailed?() }
                return
            }
            defer { try? handle.close() }
            guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
            else {
                if !box.stopped { onOpenFailed?() }
                return
            }

            // Whatever is still queued belongs to where the playhead used to
            // be — this run starts somewhere else (a play, a seek, a mode or
            // speed change all come through here), so drop it rather than
            // play the old position's last ~100 ms first.
            switch paceMode {
            case .heterodyne:               hetero.requestFlush()
            case .timeExpansion:            timeExp.requestFlush()
            case .off, .snippetExpansion:   break
            }

            /// Output samples fed but not yet rendered — 0 in the modes that
            /// render nothing, where fed and heard are the same thing.
            func queuedFrames() -> Int {
                switch paceMode {
                case .heterodyne:               hetero.queuedFrames
                case .timeExpansion:            timeExp.queuedFrames
                case .off, .snippetExpansion:   0
                }
            }
            /// File samples between the last one fed and the one currently
            /// reaching the speaker.
            func audibleLead() -> Int {
                let queued = queuedFrames()
                guard queued > 0 else { return 0 }
                return Int((Double(queued) / drainRate + hardwareLatency) * paceRate)
            }
            // Monotonic guard on top of that estimate: the queue depth is a
            // snapshot of two independently-clocked threads, so a tick where
            // it happens to grow faster than the feed would otherwise walk the
            // playhead backwards.
            var lastPublished = 0
            func publishHeard(fed: Int) {
                let heard = max(fed - audibleLead(), 0)
                lastPublished = max(lastPublished, heard)
                onProgress?(Double(lastPublished) / sampleRate)
            }

            var virtualFed = min(max(fromVirtual, 0), plan.virtualTotal)
            // Where in the file that position actually is, and which region
            // it belongs to. Everything below advances these together.
            var regionIndex = plan.regionIndex(forVirtual: virtualFed)
            var realCursor = plan.realSample(forVirtual: virtualFed, regionIndex: regionIndex)
            try? handle.seek(toOffset: UInt64(44 + realCursor * 2))

            // The hidden audio leading INTO the next region — what the current
            // region's tail crossfades with instead of dropping to silence
            // (see `applySeamEnvelope`). Read through a second handle so the
            // sequential playback read position is never disturbed, and
            // refreshed once per region rather than per chunk. Only silence
            // removal ever produces more than one region; playing the whole
            // file skips all of this.
            let preRollHandle: FileHandle? = plan.regions.count > 1
                ? try? FileHandle(forReadingFrom: url) : nil
            defer { try? preRollHandle?.close() }
            var incoming = [Float](repeating: 0, count: seamFade)
            var hasIncoming = false
            /// Loads the run-up to the region AFTER `index`, if there is one.
            func loadIncoming(forRegionAfter index: Int) {
                hasIncoming = false
                guard index + 1 < plan.regions.count, let preRollHandle else { return }
                let end = plan.regions[index + 1].lowerBound
                let begin = max(0, end - seamFade)
                let wanted = end - begin
                guard wanted > 0,
                      (try? preRollHandle.seek(toOffset: UInt64(44 + begin * 2))) != nil,
                      let data = try? preRollHandle.read(upToCount: wanted * 2), data.count == wanted * 2
                else { return }
                // Right-aligned: the buffer's LAST sample is the one
                // immediately before the next region's first, which is the end
                // the crossfade lines up against.
                let pad = seamFade - wanted
                for i in 0..<pad { incoming[i] = 0 }
                data.withUnsafeBytes { raw in
                    let src = raw.bindMemory(to: Int16.self)
                    for i in 0..<wanted { incoming[pad + i] = Float(src[i]) / 32767.0 }
                }
                hasIncoming = true
            }
            loadIncoming(forRegionAfter: regionIndex)
            // Only the region this run STARTS in has no outgoing audio to
            // arrive from, so only it fades up from silence.
            var isFirstRegionOfRun = true

            let startWall = Date()
            let maxChunk = 1 << 14   // ~16k samples (~43 ms @ 384 kHz) per read
            var int16Buf = [Int16](repeating: 0, count: maxChunk)
            // Heterodyne auto-tune state — local to this pacing run, same as
            // `virtualFed` above, so every fresh play()/seek() restart re-tunes
            // from scratch rather than carrying over a stale target.
            var tunedFrequency: Double = 0
            var gateHoldSamplesRemaining = 0
            // ~530 ms, matching AudioEngineController's gateHoldDuration (8 ticks @ ~67 ms).
            let gateHoldSamples = Int(sampleRate * 0.53)

            while !box.stopped, virtualFed < plan.virtualTotal, regionIndex < plan.regions.count {
                let region = plan.regions[regionIndex]
                let elapsed = Date().timeIntervalSince(startWall)
                let shouldHaveFed = fromVirtual + Int(elapsed * paceRate)
                guard shouldHaveFed > virtualFed else { usleep(2_000); continue }
                // Never read past the end of the region being played — the
                // rest of it is silence that is not going to be heard.
                let want = min(shouldHaveFed - virtualFed,
                               min(maxChunk, region.upperBound - realCursor))
                // Unreachable as written (the region is advanced the moment
                // its cursor reaches the end, and the pace guard above already
                // rules out a zero from the other term) — but sleep rather
                // than spin if it ever does become reachable.
                guard want > 0 else { usleep(2_000); continue }
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
                incoming.withUnsafeBufferPointer { inc in
                    Self.applySeamEnvelope(floatCh, count: n, at: realCursor, in: region, fade: seamFade,
                                           fadeInFromSilence: isFirstRegionOfRun,
                                           incoming: hasIncoming ? inc.baseAddress : nil)
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

                virtualFed += n
                realCursor += n
                // Region exhausted: step to the next kept range and move the
                // read head there. This is where the silence is actually
                // removed — the skipped bytes are never read at all.
                if realCursor >= region.upperBound {
                    regionIndex += 1
                    isFirstRegionOfRun = false
                    if regionIndex < plan.regions.count {
                        realCursor = plan.regions[regionIndex].lowerBound
                        try? handle.seek(toOffset: UInt64(44 + realCursor * 2))
                        loadIncoming(forRegionAfter: regionIndex)
                    }
                }
                if !box.stopped { publishHeard(fed: virtualFed) }
            }
            // Everything is fed but not everything has been heard yet: let the
            // ring drain before declaring the file finished, or the playhead
            // snaps to the end (and the transport to stopped) while the last
            // call is still sounding. Bounded — a stalled output thread must
            // not hold this thread open.
            // `render` stops consuming with one sample left (it interpolates
            // between two), so wait for "essentially empty" rather than
            // exactly zero, which never arrives.
            let drainDeadline = Date().addingTimeInterval(2)
            while !box.stopped, queuedFrames() > 64, Date() < drainDeadline {
                publishHeard(fed: plan.virtualTotal)
                usleep(20_000)
            }
            if !box.stopped { onFinished?() }
        }
        t.qualityOfService = .userInitiated
        t.name = "bat.PlaybackDriver"
        t.start()
        thread = t
    }

    /// Shapes a region's edges so the splice to the next one is inaudible.
    /// `buf` holds `count` samples starting at real sample `at`; only the
    /// parts of it inside an edge window are touched, so the common case (a
    /// chunk in the middle of a long region) costs one comparison.
    ///
    /// The region END is CROSSFADED into `incoming` — the `fade` samples of
    /// real audio immediately preceding the next region's first sample, i.e.
    /// the hidden run-up to it. Both sides of that mix are the recording's own
    /// background at the same two moments the join is made between, so the
    /// hiss stays continuous through the splice and the next region's first
    /// sample follows its own run-up seamlessly. Equal-power (`sqrt`) weights,
    /// because the two sides are uncorrelated noise: linear weights would dip
    /// ~3 dB in the middle, which is a smaller version of exactly the hole
    /// this replaces.
    ///
    /// `incoming` is nil for the LAST region of a run — nothing follows, so
    /// that edge fades to silence as before. Likewise `fadeInFromSilence` is
    /// true only for the run's FIRST region, where there is no outgoing audio
    /// to come from. Every other region start is left completely untouched:
    /// its opening samples are what the previous region's crossfade already
    /// arrived at.
    /// Internal rather than private so `PlaybackEngineTests` can assert the
    /// property that matters here — that a seam never goes quiet.
    static func applySeamEnvelope(_ buf: UnsafeMutablePointer<Float>, count: Int,
                                          at start: Int, in region: Range<Int>, fade: Int,
                                          fadeInFromSilence: Bool,
                                          incoming: UnsafePointer<Float>?) {
        // A region shorter than four fades would be more ramp than content.
        let ramp = min(fade, max(1, region.count / 4))
        let fadeInEnd = region.lowerBound + ramp
        let fadeOutStart = region.upperBound - ramp
        guard (fadeInFromSilence && start < fadeInEnd) || start + count > fadeOutStart else { return }
        for i in 0..<count {
            let p = start + i
            if fadeInFromSilence, p < fadeInEnd {
                buf[i] *= Float(max(p - region.lowerBound, 0)) / Float(ramp)
            } else if p >= fadeOutStart, p < region.upperBound {
                let k = p - fadeOutStart
                let outWeight = 1 - Float(k) / Float(ramp)
                if let incoming {
                    // `incoming` ends exactly where the next region begins, so
                    // its LAST `ramp` samples are the ones that line up here.
                    let j = (fade - ramp) + k
                    buf[i] = buf[i] * outWeight.squareRoot()
                        + incoming[j] * (1 - outWeight).squareRoot()
                } else {
                    buf[i] *= outWeight
                }
            }
        }
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
            // Both the pacing rate and the output node's rate differ between
            // modes, and each is fixed for the life of one `start()` call, so
            // any mode change restarts playback from the current position.
            restartIfPlaying()
        }
    }

    /// How much slower than real time `.timeExpansion` plays — the player's
    /// own control, not the detector's. It used to be neither: 8× fell out of
    /// the file being fed at 48 kHz into an output ring hardcoded to 48 kHz,
    /// and there was no way to ask for anything else.
    ///
    /// Every sample of the recording still plays, in order — the factor only
    /// changes the clock both ends run at (see PlaybackDriver.start's
    /// `paceRate`). Ignored in the other listening modes: heterodyne's
    /// downconversion is a real-time operation and means nothing paced slowly.
    var expansionFactor: Double = 8 {
        didSet {
            guard oldValue != expansionFactor else { return }
            // Unconditionally, not just in `.timeExpansion`: the processor is
            // where the achieved factor is computed from the file's real rate,
            // and a stale one would be reported to the UI the moment the speed
            // was changed from another mode.
            timeExpansion.reset(inputSampleRate: sampleRate, outputSampleRate: expansionOutputRate)
            restartIfPlaying()
        }
    }

    /// The kept regions of the recording while silence removal is on — nil
    /// plays the file whole.
    ///
    /// Setting this switches the whole public surface of this engine into the
    /// COMPRESSED timeline: `currentTimeSeconds`, `durationSeconds` and
    /// `seek(toSeconds:)` are then positions in the packed audio, matching
    /// what the compressed spectrogram draws, so no caller has to map domains
    /// to place a playhead or scrub. The hidden audio is not skipped over as
    /// it arrives — it is never read (see PlaybackDriver.start's `regions`).
    private(set) var silenceMap: SilenceMap?

    func setSilenceMap(_ map: SilenceMap?) {
        guard map != silenceMap else { return }
        // Hold the position by the audio it is actually on, not by its number,
        // which means something different either side of this change.
        let realNow = currentRealSample
        silenceMap = map
        durationSeconds = sampleRate > 0 ? Double(virtualTotal) / sampleRate : 0
        seekVirtual(map?.realToVirtual(realNow) ?? realNow)
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
        timeExpansion.reset(inputSampleRate: sr, outputSampleRate: expansionOutputRate)
        WavPlayerDebugLog.log("PlaybackEngine", "load: OK \(url.lastPathComponent) sampleRate=\(sr) duration=\(String(format: "%.1f", durationSeconds))s")
    }

    func togglePlaying() { isPlaying ? pause() : play() }

    /// File samples released per real second. In `.timeExpansion` this is the
    /// output rate, so the file plays back at `expansionFactor` slower; the
    /// other modes run at the file's own rate, i.e. real time.
    private var paceRate: Double {
        listenMode == .timeExpansion ? expansionOutputRate : sampleRate
    }

    /// The rate the output node must run at for the active mode. Clamped to a
    /// range AVAudioEngine will actually build a node for — at the clamp the
    /// achieved slowdown is whatever the clamped rate gives rather than the
    /// requested factor, which only bites on files far off the 384 kHz the app
    /// records at.
    private var expansionOutputRate: Double {
        min(max(sampleRate / max(expansionFactor, 1), 8_000), 96_000)
    }

    private var outputRate: Double {
        listenMode == .timeExpansion ? expansionOutputRate : heterodyne.outputSampleRate
    }

    /// Length of the timeline this engine is presenting — the packed total
    /// while silence removal is on, the whole file otherwise.
    private var virtualTotal: Int { silenceMap?.virtualTotal ?? totalSamples }

    /// The playhead's position in the FILE, whatever timeline it is being
    /// reported in.
    private var currentRealSample: Int {
        let v = Int(currentTimeSeconds * sampleRate)
        return silenceMap?.virtualToReal(v) ?? v
    }

    func play() {
        guard loadedURL != nil, !isPlaying else { return }
        // Playback finished (currentTimeSeconds sits at durationSeconds via
        // onFinished) — treat play() as "play again" rather than a silent no-op
        // that leaves the button looking unresponsive once a file has ended.
        if currentTimeSeconds >= durationSeconds { currentTimeSeconds = 0 }
        WavPlayerDebugLog.log("PlaybackEngine", "play: from \(String(format: "%.2f", currentTimeSeconds))s, mode=\(listenMode), \(expansionFactor)x, regions=\(playRegions.count)")
        isPlaying = true
        startDriver()
    }

    func pause() {
        WavPlayerDebugLog.log("PlaybackEngine", "pause: at \(String(format: "%.2f", currentTimeSeconds))s")
        isPlaying = false
        driver.stop()
    }

    /// Scrubs to `t` seconds ON THE TIMELINE THIS ENGINE IS PRESENTING —
    /// packed seconds while silence removal is on, file seconds otherwise —
    /// restarting the pacing thread from there (resumes playing if it was
    /// already playing).
    func seek(toSeconds t: Double) {
        WavPlayerDebugLog.log("PlaybackEngine", "seek: to \(String(format: "%.2f", t))s (wasPlaying=\(isPlaying))")
        currentTimeSeconds = min(max(0, t), durationSeconds)
        restartIfPlaying()
    }

    private func seekVirtual(_ sample: Int) {
        seek(toSeconds: sampleRate > 0 ? Double(sample) / sampleRate : 0)
    }

    func stop() {
        pause()
        driver.stopEngine()
        loadedURL = nil
        currentTimeSeconds = 0
        durationSeconds = 0
        silenceMap = nil
    }

    private var playRegions: [Range<Int>] {
        silenceMap?.realRegions ?? [0..<totalSamples]
    }

    /// The one place the pacing thread is launched. Both the pace and the
    /// output node's rate are fixed for the life of a run, so everything that
    /// changes either — the listening mode, the speed, the silence map, a
    /// seek — comes back through here.
    private func startDriver() {
        guard let url = loadedURL else { return }
        driver.configureOutput(sampleRate: outputRate)
        driver.start(url: url, sampleRate: sampleRate, totalSamples: totalSamples,
                     fromVirtual: Int(currentTimeSeconds * sampleRate),
                     paceRate: paceRate, regions: playRegions)
    }

    private func restartIfPlaying() {
        guard isPlaying, loadedURL != nil else { return }
        // `driver.start` stops the previous pacing thread itself before
        // starting the new one — no need to call `driver.stop()` here too.
        startDriver()
    }

    private static func readHeader(url: URL) -> (sampleRate: Double, totalSamples: Int)? {
        guard let header = WavHeader.read(url: url) else { return nil }
        return (Double(header.sampleRate), Int(header.dataBytes) / 2)
    }
}
