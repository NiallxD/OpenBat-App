//
//  SnippetExpansionProcessor.swift
//  OpenBat
//
//  LIVE time expansion in the Pettersson D240x pattern: record continuously into
//  a circular memory, and when a pulse triggers, replay that memory ONCE at
//  1/N speed while capture into it stops. Every sample inside the captured
//  window is played, in order, at a fixed slower clock — there is no
//  content-based selection anywhere in this file. What it gives up instead is
//  coverage: while a snippet replays, this mode is not capturing a new one.
//
//  The design is taken from the D240x manual rather than invented (see
//  Context.md §5 for the quoted text and the dated rule change):
//
//    * 50% PRETRIGGER. The capture window straddles the trigger — half the
//      memory is what happened BEFORE it. That is why the ring records
//      continuously: the pre-trigger half is already in hand when the pulse
//      arrives, so "the onset of the pulse that triggered the detector will not
//      be cut off". Trigger latency is therefore irrelevant here, which is why
//      arming from the main actor is fine.
//    * REPLAY ONCE, then re-arm. The D240x's automatic mode replays a captured
//      sequence a single time; looping is its manual mode and is not offered.
//    * DEAF WHILE REPLAYING, accepted rather than engineered around. Heterodyne
//      keeps running alongside (AudioEngineController mixes them), so the
//      listener never loses the live channel — that pairing is also the D240x's
//      own design, not an OpenBat addition.
//
//  Nobody in this repo has determined that anything infringes or is clear of
//  any patent, and no comment here should be written as though they had. The
//  reasoning behind the rule that permits this shape — and the fact that it
//  rests on an invalidity argument, not a non-infringement one — is recorded in
//  Context.md §5 and nowhere else.
//
//  Threading: identical contract to HeterodyneProcessor — `process(_:)` on the
//  realtime capture thread (producer), `render(_:frames:)` on the realtime
//  output thread (consumer), `ctrlLock` for main-thread settings. The state
//  machine is an Atomic so neither realtime thread ever takes a lock to read it.
//

import AVFoundation
import Synchronization

nonisolated final class SnippetExpansionProcessor: @unchecked Sendable {

    let outputSampleRate: Double = 48_000

    /// Capture memory bounds, in seconds — continuous, not the D240x's three
    /// switch positions (3.4 / 1.7 / 0.1). Deliberate deviation, recorded in
    /// Context.md §5 alongside the continuous expansion factor.
    ///
    /// **The floor was 0.5 s, and that was the single biggest source of the
    /// hiss** (Niall, 2026-09-01). The window straddles the trigger, so 0.5 s
    /// means 250 ms of room tone before the call and 250 ms after it, around a
    /// call lasting 2–20 ms — better than 95% of every replay was empty air,
    /// stretched 16×. The old comment here dismissed the D240x's own 0.1 s MIN
    /// position as "really a different feature (catch one pulse)". Catching one
    /// pulse is the feature; 0.1 s leaves 50 ms either side, which is still
    /// twenty times the ~2 ms the detector needs to make up its mind.
    static let minMemorySeconds = 0.1
    static let maxMemorySeconds = 3.5

    // MARK: State machine

    /// Deliberately a plain Int in an Atomic rather than an enum: both realtime
    /// threads read it every buffer, and this keeps that a single load.
    private enum Phase {
        static let recording = 0   // circular capture, waiting for a trigger
        static let arming    = 1   // triggered; filling the post-trigger half
        static let preparing = 3   // window captured; the worker is cleaning it up
        static let replaying = 2   // draining slowly; capture into the ring stops
    }
    private let phaseA = Atomic<Int>(Phase.recording)

    /// True once the circular memory holds a full window again — see
    /// `trigger()`, which refuses while this is false. Written by the capture
    /// thread, read by the main thread, so it is an atomic rather than one of
    /// that thread's private counters.
    private let readyA = Atomic<Bool>(false)

    /// True while a snippet is replaying — drives the heterodyne duck and any UI.
    var isReplaying: Bool { phaseA.load(ordering: .acquiring) == Phase.replaying }

    /// What the mode is doing right now, for display. A single atomic load, so a
    /// view can poll it on a timer without touching either realtime thread.
    ///
    /// This is worth showing: "deaf" is the mode's central trade-off and is
    /// otherwise completely invisible — during a replay the audio sounds busy
    /// precisely when the detector is ignoring the live world.
    enum Activity {
        /// Armed: recording into the circular memory, waiting for a pulse.
        case listening
        /// Triggered; filling the post-trigger half of the buffer.
        case capturing
        /// Replaying, and not capturing anything new.
        case replaying
    }

    var activity: Activity {
        switch phaseA.load(ordering: .acquiring) {
        // `preparing` reads as capturing: it is a few milliseconds long and,
        // like arming, it is the state between the trigger and the sound.
        case Phase.arming, Phase.preparing: .capturing
        case Phase.replaying: .replaying
        default:              .listening
        }
    }

    /// How far through the current replay, 0–1, or 0 when not replaying. Read
    /// without synchronisation on purpose: it is a display value, a torn read is
    /// at worst one frame stale, and locking would put the UI on the audio
    /// thread's critical path.
    var replayProgress: Double {
        guard isReplaying, replayCount > 0 else { return 0 }
        return min(max(replayPos / Double(replayCount), 0), 1)
    }

    // MARK: Control (main thread ↔ realtime threads)

    private let ctrlLock = NSLock()
    private var _expansion: Double = 8
    /// 1.5 s default: long enough to hold a typical pass, and at the default 8×
    /// it replays in 12 s rather than the 27 s a full buffer would cost — the
    /// mode is deaf to new snippets for that whole time, so the default trades
    /// buffer length for getting back to armed sooner.
    private var _memorySeconds: Double = 1.5
    private var _trimDB: Double = 0
    private var _rearmSeconds: Double = 0.5
    private var _denoiseMode: SnippetDenoiseMode = .scrub
    /// What a prepared snippet's loudest sample is scaled to.
    ///
    /// **Derived from the output stage, never written as a number.** This was
    /// 0.7, then 0.5, both picked as "full scale with headroom" — and both
    /// wrong by 12 dB, because everything here passes through a fixed ×4 makeup
    /// gain afterwards (`ListenOutputStage`). Replays were arriving at the soft
    /// clipper at twice full scale and being crushed flat: 2.4% of all output
    /// samples sat at the ceiling. Landing on the knee instead is as loud as
    /// this path goes without distorting.
    ///
    /// A little under the knee, because a snippet can be summed with the live
    /// heterodyne bed under `.both` routing and the two should not add their way
    /// into the clipper.
    private static let targetPeak: Float = ListenOutputStage.peakBeforeMakeup * 0.8

    /// **The background is capped as well as the peak, and that is the whole
    /// fix for "some replays are all hiss".** Matching every snippet to the
    /// same PEAK is right when the peak is a call and catastrophic when it
    /// isn't: a window holding only background got its background lifted to
    /// full scale. Measured across one demo run, replay-to-replay background
    /// level varied over a 47 dB range, which is what the constant swing from
    /// hiss to silence was. Taking the smaller of "peak reaches target" and
    /// "background stays under this" gives a loud call a consistent level and
    /// leaves a quiet window quiet.
    ///
    /// Expressed against the output stage for the same reason as `targetPeak`:
    /// this is "the background never gets louder than −52 dBFS at the speaker",
    /// which is a statement about what a listener hears rather than a number in
    /// a buffer.
    ///
    /// **This constraint, not the peak, is what makes replays sound alike.**
    /// It was first set 14 dB higher, and at that setting replays carrying the
    /// same call level came back with backgrounds anywhere from −67 to −35 dBFS
    /// — the same bat, wildly different hiss, which is what "some are quiet
    /// noise, some are very loud noise" was (Niall, 2026-09-01). Chosen by
    /// simulating candidate values against the replays measured off that run:
    /// −52 halves the spread (33 dB → 18) while still landing the median call
    /// at −6 dBFS and the quietest at −22, both comfortably audible. Going
    /// lower keeps tightening the spread but starts making calls themselves
    /// quiet, which is the wrong thing to trade for it.
    private static let maxBackground: Float = 0.0025 / ListenOutputStage.makeupGain

    /// Ceiling on the automatic match, so nothing gets lifted absurdly far.
    private static let maxAutoGain: Float = 32

    /// How far a snippet's peak must stand above its own background before it
    /// is worth replaying at all, in dB. Below this the window holds no call
    /// and is discarded — the mode re-arms immediately instead of spending
    /// 1.6 s playing amplified room tone, which is both quieter to listen to
    /// and less time deaf.
    ///
    /// 24 dB from the demo file's own distribution, which is strongly bimodal:
    /// noise-only windows sit at 15–19 dB, windows holding a call at 32 dB and
    /// up. 24 is in the empty gap between them, and the exact value barely
    /// matters — 20 dB keeps 68% of windows, 24 keeps 66%, 30 keeps 62%.
    private static let minCallCrestDB: Float = 24

    /// At most this many samples are sorted to find a snippet's background
    /// level. A median needs a representative sample, not every sample, and
    /// this keeps the cost flat across buffer lengths.
    private static let maxLevelProbe = 8192
    private var levelProbe = [Float](repeating: 0, count: maxLevelProbe)
    private var _fadeMS: Double = 30

    /// Slowdown factor N: the captured audio is replayed at 1/N speed.
    ///
    /// Note the interaction with aliasing, which is why this is clamped rather
    /// than free. Input frequency f lands at f/N, so the 24 kHz output band
    /// holds everything below 24 kHz × N. At N = 8 (the 384/48 ratio) that is
    /// 192 kHz — the entire input Nyquist, so nothing can fold. Below 8 we are
    /// decimating and content above 24 kHz × N aliases back into the audible
    /// band, so `reset` installs a low-pass at that corner. Above 8 we are
    /// interpolating and no filter is needed.
    var expansion: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expansion }
        set {
            let clamped = min(max(newValue, 4), 20)
            ctrlLock.lock(); _expansion = clamped; ctrlLock.unlock()
        }
    }

    /// Capture window length. Changing it takes effect at the next trigger, not
    /// mid-replay.
    var memorySeconds: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _memorySeconds }
        set {
            let clamped = min(max(newValue, Self.minMemorySeconds), Self.maxMemorySeconds)
            ctrlLock.lock(); _memorySeconds = clamped; ctrlLock.unlock()
        }
    }

    /// Listener's volume trim, in dB, on top of the automatic level match.
    ///
    /// **Replaced a fixed ×4 makeup gain** (Niall, 2026-09-01), which was the
    /// same +12 dB on every snippet regardless of how loud the pass had been —
    /// so a bat overhead clipped and a bat at 40 m stayed inaudible, and the
    /// only way to either was the tuning overlay. Each snippet is now matched
    /// to `targetPeak` from its own measured peak (see `prepareSnippet`) and
    /// this is the taste knob on top of that.
    var trimDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _trimDB }
        set {
            let clamped = min(max(newValue, -18), 18)
            ctrlLock.lock(); _trimDB = clamped; ctrlLock.unlock()
        }
    }

    /// How much background a captured snippet keeps before replay — see
    /// `SpectralDenoiser`. Hiss is what makes this mode unpleasant to listen to
    /// for an evening, and the cost of removing it is a few milliseconds of
    /// preparation inside a gap that was previously idle.
    var denoiseMode: SnippetDenoiseMode {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _denoiseMode }
        set { ctrlLock.lock(); _denoiseMode = newValue; ctrlLock.unlock() }
    }

    /// A deliberate pause after each replay before this will trigger again.
    ///
    /// Distinct from the refill guard in `trigger()`, which is a correctness
    /// requirement of fixed length (one buffer, because that is when the
    /// pre-trigger half exists again). This is a listening choice on top of it:
    /// re-arming the instant the memory is ready means the very next thing
    /// loud enough — very often an echo of the call just played, or a later
    /// call of the same pass — takes the slot immediately. A pause gives the
    /// air time to go quiet again (Niall, 2026-09-01: "we can try not be giving
    /// the thing room to breath").
    ///
    /// It does not claim to reject echoes. An echo IS a call, just a reflected
    /// one, and telling the two apart means looking at timing and amplitude,
    /// which is a different piece of work. This only reduces how often one
    /// lands in the slot.
    var rearmSeconds: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _rearmSeconds }
        set {
            let clamped = min(max(newValue, 0), 3)
            ctrlLock.lock(); _rearmSeconds = clamped; ctrlLock.unlock()
        }
    }

    /// Fade applied to the start and end of each replay, in ms of OUTPUT time.
    /// Long enough to be heard as a fade rather than a de-click.
    var fadeMS: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _fadeMS }
        set {
            let clamped = min(max(newValue, 1), 250)
            ctrlLock.lock(); _fadeMS = clamped; ctrlLock.unlock()
        }
    }

    // MARK: Capture ring (producer: capture thread; frozen during replay)

    /// Circular capture memory at the INPUT rate. Allocated once for the maximum
    /// memory setting — manual memory rather than an Array because both realtime
    /// threads touch it and Array's exclusivity rules don't permit that.
    private var ring: UnsafeMutableBufferPointer<Float>
    private var ringCapacity: Int
    private var inputSampleRate: Double = 384_000

    /// Write cursor, and how many samples have ever been written. The counter is
    /// what makes the pre-trigger safe: at a trigger we need to know whether the
    /// ring has actually been filled yet, so a snippet taken seconds after
    /// launch cannot replay uninitialised memory. (The D240x has this exact
    /// failure and documents it as a user workaround — "the memory is filled
    /// with a random signal which may sound like white noise... allow at least
    /// the chosen memory time to elapse". Here it is simply enforced.)
    private var writeCursor = 0
    private var totalWritten = 0

    /// Set at the trigger: how many more input samples to capture before replay.
    private var postTriggerRemaining = 0

    // Anti-alias low-pass for N < 8, see `expansion`. Two cascaded biquads.
    private var aaA = Biquad(), aaB = Biquad()
    private var applyAA = false
    private var appliedAAExpansion = -1.0

    /// Input high-pass, always on. Rumble, handling noise and wind sit below the
    /// bat band and slow down into the most audible part of the output, so they
    /// are removed on the way IN — before the ring, so the replay never contains
    /// them. 12 kHz matches the detector's own front end; the lowest UK call
    /// (noctule sweep tail, ~17 kHz) stays well clear.
    private var hpA = Biquad(), hpB = Biquad()

    // MARK: Preparation (background worker)
    //
    // Between the window closing and the first sample reaching the speaker there
    // is now a short third phase. It exists because a captured snippet is a
    // FINITE buffer wholly in hand, and the replay it feeds lasts 8–20× longer
    // than the capture did — so there is a large budget here that used to be
    // spent doing nothing, and cleaning the audio up once, offline, is strictly
    // better than trying to do it sample-by-sample on the way out.
    //
    // What this replaced: a broadband expander driven by a 0.33 ms RMS block.
    // See `SpectralDenoiser`'s header for why that could never separate hiss
    // from call, and why slowing its gain down 16× made calls squeaky. The
    // §3 findings that expander was built on ("attack instant, release
    // smoothed", "envelope interpolated between block centres") were sound
    // advice about expanders and are simply no longer load-bearing — there is
    // no envelope here to step or smooth.
    //
    // Still true, and still the point §5 turns on: every captured sample is
    // emitted, in order, at one fixed slower clock. Filtering changes what a
    // sample is worth, never which samples are played or when.

    /// The window to replay, linearised out of the ring and cleaned up. Separate
    /// from `ring` so the capture side can be reading and writing its circular
    /// buffer while this one is played from — and so the replay side indexes a
    /// flat array with no modulo, which is what lets `SpectralDenoiser` work on
    /// it as one contiguous signal.
    private var prepared: UnsafeMutableBufferPointer<Float>

    /// A `var` only so `reset` can rebuild it if a capture rate ever appears
    /// that needs a bigger buffer than 384 kHz did — it holds scratch sized to
    /// the longest snippet it will be asked for.
    private var denoiser: SpectralDenoiser
    /// Signalled by the capture thread when a window is ready to prepare.
    private let workReady = DispatchSemaphore(value: 0)
    /// Signalled by the worker as it returns, so `deinit` can wait for it. Not
    /// optional politeness: `deinit` frees the very buffers the worker may be
    /// part-way through denoising.
    private let workerDone = DispatchSemaphore(value: 0)
    private var worker: Thread?
    private let stopping = Atomic<Bool>(false)

    // MARK: Replay (consumer: output thread)

    /// Where in the ring the captured window begins, and how long it is. Written
    /// by the capture thread as it closes the window, read by the worker; the
    /// phase store/load pair is what publishes them in both directions.
    private var replayStart = 0
    private var replayCount = 0
    private var replayPos = 0.0
    /// Input samples per output sample, and output gain — both settled before
    /// `replaying` is published, so the output thread never takes `ctrlLock` and
    /// the rate cannot change part-way through a replay.
    private var replayStep = 1.0
    private var replayGain: Float = 1
    private var replayFadeSeconds = 0.03
    /// Ramp to keep a replay from starting or ending on a step.
    private var replayEnvelope: Float = 0
    /// Capture-thread-only latch for spotting the replay→recording transition.
    private var wasReplaying = false
    /// Capture-thread-only mirror of `readyA`, so the atomic is written on the
    /// transition rather than on every sample.
    private var ringReady = false

    init() {
        ringCapacity = Int(Self.maxMemorySeconds * 384_000)
        ring = .allocate(capacity: ringCapacity)
        ring.initialize(repeating: 0)
        prepared = .allocate(capacity: ringCapacity)
        prepared.initialize(repeating: 0)
        denoiser = SpectralDenoiser(maxOfflineSamples: ringCapacity)

        let t = Thread { [weak self] in self?.workerLoop() }
        t.name = "SnippetExpansion.prepare"
        // Above default but below the realtime threads it sits between: a
        // replay cannot start until this finishes, so it should not wait behind
        // ordinary work — but it must never compete with capture or output.
        t.qualityOfService = .userInitiated
        worker = t
        t.start()
    }

    deinit {
        stopping.store(true, ordering: .releasing)
        workReady.signal()
        workerDone.wait()
        ring.deallocate()
        prepared.deallocate()
    }

    /// Clean up and level the captured window, then release it to the output
    /// thread. Runs on the worker — never on a realtime thread.
    private func workerLoop() {
        defer { workerDone.signal() }
        while true {
            workReady.wait()
            if stopping.load(ordering: .acquiring) { return }
            guard phaseA.load(ordering: .acquiring) == Phase.preparing else { continue }
            prepareSnippet()
            // Compare-exchange, not a plain store: `cancel()` can land while
            // this snippet is being prepared, and a store would resurrect a
            // snippet the caller has already abandoned. Losing the exchange
            // means the phase moved on without us, and the right thing to do
            // is drop the work on the floor.
            //
            // A rejected snippet goes straight back to recording rather than
            // being played — see `minCallCrestDB`. That is the one path where
            // a trigger produces no sound at all, and it is deliberate.
            _ = phaseA.compareExchange(expected: Phase.preparing,
                                       desired: accepted ? Phase.replaying : Phase.recording,
                                       ordering: .acquiringAndReleasing)
        }
    }

    /// Whether the last prepared snippet was worth playing. Worker-thread only,
    /// read by `workerLoop` immediately after `prepareSnippet` returns.
    private var accepted = false

    private func prepareSnippet() {
        let count = replayCount
        accepted = false
        guard count > 0 else { return }

        // Straighten the circular window out into `prepared`. Done here rather
        // than on the capture thread — which is why `process` freezes the ring
        // for `preparing` too — so a realtime thread never has to move
        // megabytes, and so everything downstream sees one contiguous signal.
        let firstRun = min(count, ringCapacity - replayStart)
        prepared.baseAddress!.update(from: ring.baseAddress! + replayStart, count: firstRun)
        if firstRun < count {
            (prepared.baseAddress! + firstRun).update(from: ring.baseAddress!, count: count - firstRun)
        }

        let mode = denoiseMode
        if mode != .off {
            denoiser.denoiseOffline(prepared.baseAddress!, count: count,
                                    strength: mode.strength)
        }

        // Both measured AFTER cleanup, not before: what matters is the level of
        // what actually comes out, and denoising changes both of these.
        var peak: Float = 0
        for i in 0..<count { peak = max(peak, abs(prepared[i])) }

        // The background, as the median of the snippet's own sample magnitudes.
        // A median rather than an RMS precisely because a call is in here: the
        // call is a couple of percent of the window, so it cannot move the
        // median, but it dominates an RMS.
        let probeCount = min(count, Self.maxLevelProbe)
        let step = max(1, count / probeCount)
        for i in 0..<probeCount { levelProbe[i] = abs(prepared[min(count - 1, i * step)]) }
        levelProbe[0..<probeCount].sort()
        let background = max(levelProbe[probeCount / 2], 1e-9)

        // Nothing worth hearing in this window — drop it and get back to
        // listening. Caller sees the phase go straight back to recording.
        let crestDB = 20 * log10(peak / background)
        guard crestDB >= Self.minCallCrestDB else {
            accepted = false
            return
        }
        accepted = true

        // Match every snippet to the same output level, so a bat at 40 m and a
        // bat overhead replay equally loud — but never at the cost of lifting
        // the background, which is what `maxBackground` bounds.
        let byPeak = Self.targetPeak / max(peak, 1e-9)
        let byBackground = Self.maxBackground / background
        let auto = min(min(byPeak, byBackground), Self.maxAutoGain)
        replayGain = auto * Float(pow(10, trimDB / 20))
        replayPos = 0
        replayEnvelope = 0
    }

    /// Reconfigure for a capture sample rate and reset all state. Call before
    /// installing the tap — no concurrent `process`/`render` at this point.
    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        let needed = Int(Self.maxMemorySeconds * fs)
        if needed > ringCapacity {
            ring.deallocate()
            prepared.deallocate()
            ringCapacity = needed
            ring = .allocate(capacity: ringCapacity)
            prepared = .allocate(capacity: ringCapacity)
            denoiser = SpectralDenoiser(maxOfflineSamples: ringCapacity)
        }
        ring.initialize(repeating: 0)
        prepared.initialize(repeating: 0)
        hpA = .highpass(cutoff: min(12_000, fs / 2 * 0.9), sampleRate: fs)
        hpB = .highpass(cutoff: min(12_000, fs / 2 * 0.9), sampleRate: fs)
        writeCursor = 0
        totalWritten = 0
        postTriggerRemaining = 0
        ringReady = false
        readyA.store(false, ordering: .releasing)
        replayCount = 0
        replayPos = 0
        replayEnvelope = 0
        replayStep = 1
        replayGain = 1
        replayFadeSeconds = _fadeMS / 1000
        wasReplaying = false
        appliedAAExpansion = -1
        reconfigureAntiAlias(expansion)
        phaseA.store(Phase.recording, ordering: .releasing)
    }

    /// Install (or remove) the decimation guard for the current factor.
    /// Capture-thread only, and only when the factor actually moved.
    private func reconfigureAntiAlias(_ n: Double) {
        let naturalRatio = inputSampleRate / outputSampleRate
        applyAA = n < naturalRatio
        if applyAA {
            let corner = min(outputSampleRate / 2 * n, inputSampleRate / 2 * 0.98)
            aaA = .lowpass(cutoff: corner, sampleRate: inputSampleRate)
            aaB = .lowpass(cutoff: corner, sampleRate: inputSampleRate)
        }
        appliedAAExpansion = n
    }

    // MARK: Trigger (main thread)

    /// Arm a capture. Called at a pulse's rising edge; ignored unless idle, which
    /// is what gives "replay once, no retrigger while replaying" for free.
    ///
    /// Returns true if this call armed a snippet, so the caller can drive UI
    /// without having to poll.
    @discardableResult
    func trigger() -> Bool {
        // **Refuse until the circular memory has refilled.** A replay discards
        // the recorded history behind it (see `process`), so for one window's
        // length afterwards there is no pre-trigger half to draw on — and the
        // pre-trigger half is the entire reason the onset of the call that
        // fired the trigger is never clipped. Triggering during that gap gave a
        // half-length replay that began part-way through a call.
        //
        // Measured off a demo run before this guard existed: 39% of replays
        // came back under 1 s where a full 0.1 s buffer at 16× is always 1.6 s,
        // and 26% had their loudest moment inside the first tenth of the
        // replay — a call already in progress when the recording started
        // (Niall, 2026-09-01, "starting listening mid pulse and picking up half
        // a pulse").
        //
        // Deliberately NOT a setting. Its right value is not a matter of taste:
        // it is exactly one buffer length, because that is when the guarantee
        // this mode is built on becomes true again. A shorter wait re-admits
        // the bug and a longer one is just deafness with no argument for it.
        guard readyA.load(ordering: .acquiring) else { return false }
        let (exchanged, _) = phaseA.compareExchange(expected: Phase.recording,
                                                    desired: Phase.arming,
                                                    ordering: .acquiringAndReleasing)
        return exchanged
    }

    /// Abandon any capture or replay in progress and return to recording.
    func cancel() {
        phaseA.store(Phase.recording, ordering: .releasing)
    }

    // MARK: Producer (capture thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let phase = phaseA.load(ordering: .acquiring)
        // Frozen while a snippet is being prepared or replayed. `preparing` has
        // to be here as well as `replaying`: the worker is reading the window
        // out of the ring, and letting capture run on over it would hand the
        // listener a snippet spliced together from two different moments.
        guard phase != Phase.replaying, phase != Phase.preparing else {
            wasReplaying = true
            return
        }
        // First buffer after a replay ended: discard the recorded history, so the
        // next snippet cannot contain audio from before the replay — which would
        // be tens of seconds stale by then. Done here, on the capture thread,
        // because `totalWritten` and `writeCursor` belong to this thread alone.
        if wasReplaying {
            wasReplaying = false
            totalWritten = 0
            postTriggerRemaining = 0
            ringReady = false
            readyA.store(false, ordering: .releasing)
        }

        let factor = expansion
        if factor != appliedAAExpansion { reconfigureAntiAlias(factor) }

        let memSamples = min(Int(memorySeconds * inputSampleRate), ringCapacity)
        // The ring only holds `memSamples`, but `totalWritten` counts every
        // sample since the last replay — so a hangover longer than the buffer
        // is simply a larger count to reach, with no extra storage.
        let readyThreshold = max(memSamples, Int(rearmSeconds * inputSampleRate))

        if phase == Phase.arming && postTriggerRemaining == 0 {
            // 50% pretrigger: capture half the memory from here, which leaves the
            // other half — already in the ring — sitting before the trigger.
            postTriggerRemaining = memSamples / 2
        }

        for i in 0..<n {
            // High-pass first: rumble is removed before it ever enters the ring,
            // so no replay can contain it and no later stage has to deal with it.
            var x = hpB.process(hpA.process(channel[i]))
            if applyAA { x = aaB.process(aaA.process(x)) }
            ring[writeCursor] = x

            writeCursor += 1
            if writeCursor == ringCapacity { writeCursor = 0 }
            totalWritten += 1
            // Allowed to trigger once BOTH conditions hold: a whole window of
            // history exists again (correctness — see `trigger()`), and any
            // requested breathing space has elapsed (taste — see
            // `rearmSeconds`). Guarded by a capture-thread-private mirror so the
            // atomic is written once per re-arm rather than once per sample, and
            // `>=` rather than `==` so that changing either length mid-run
            // cannot step over the equality and leave the mode permanently
            // unable to trigger.
            if !ringReady && totalWritten >= readyThreshold {
                ringReady = true
                readyA.store(true, ordering: .releasing)
            }

            if phase == Phase.arming {
                postTriggerRemaining -= 1
                if postTriggerRemaining <= 0 {
                    // Window is [writeCursor - memSamples, writeCursor), clamped
                    // to what has actually been recorded since reset so a trigger
                    // in the first seconds cannot replay uninitialised memory.
                    let usable = min(memSamples, totalWritten)
                    replayCount = usable
                    replayStart = ((writeCursor - usable) % ringCapacity + ringCapacity) % ringCapacity
                    postTriggerRemaining = 0
                    // Snapshot the playback rate HERE rather than reading it per
                    // render call. Two reasons: it keeps `ctrlLock` off the
                    // realtime output thread entirely, and it stops a slider
                    // drag mid-replay from warping the rate (and so the pitch)
                    // part-way through a call. Settings changes take effect at
                    // the next trigger, which is also how the D240x's switches
                    // behave.
                    replayStep = (inputSampleRate / outputSampleRate) / factor
                    replayFadeSeconds = fadeMS / 1000

                    // Hand the window to the worker. The gain is settled there,
                    // after cleanup, because it is measured from what will
                    // actually be heard. `signal()` is the only call this
                    // thread makes into the preparation path and it neither
                    // blocks nor allocates.
                    phaseA.store(Phase.preparing, ordering: .releasing)
                    workReady.signal()
                    return
                }
            }
        }
    }

    // MARK: Consumer (output thread)

    /// Render `frames` of replay audio, or silence when idle. Returns true if
    /// anything non-silent was produced, so the caller can duck heterodyne only
    /// while a snippet is actually sounding.
    @discardableResult
    func render(_ out: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard phaseA.load(ordering: .acquiring) == Phase.replaying else {
            for i in 0..<frames { out[i] = 0 }
            return false
        }

        // Input samples consumed per output sample, snapshotted at the trigger
        // (see `process`) so this thread takes no lock and the rate cannot move
        // mid-replay. At the natural 384/48 ratio with N = 8 it is exactly 1.0;
        // below 8 it decimates (guarded by the anti-alias filter installed at
        // capture), above 8 it interpolates.
        let step = replayStep
        let g = replayGain

        // Fade in and out of each replay, in output time. `fadeSeconds` is a
        // proper fade rather than the de-click a couple of ms would give: a
        // snippet arrives out of the live heterodyne bed and should not appear
        // and vanish abruptly against it.
        let fadeSeconds = replayFadeSeconds
        let slew = Float(1.0 / (outputSampleRate * fadeSeconds))
        let fadeOutFrom = Double(replayCount) - step * outputSampleRate * fadeSeconds

        var produced = 0
        while produced < frames {
            if replayPos >= Double(replayCount) - 1 {
                break
            }
            // A flat read, not a modulo one: `prepared` holds the window
            // straightened out (see `prepareSnippet`), which is both faster here
            // and what let the whole expander — envelope ring, block index and
            // its off-by-a-wrap bug included — be deleted.
            let idx = Int(replayPos)
            let frac = Float(replayPos - Double(idx))
            let s = prepared[idx] + frac * (prepared[idx + 1] - prepared[idx])

            let target: Float = replayPos >= fadeOutFrom ? 0 : 1
            if replayEnvelope < target { replayEnvelope = min(replayEnvelope + slew, target) }
            else { replayEnvelope = max(replayEnvelope - slew, target) }

            out[produced] = s * g * replayEnvelope
            produced += 1
            replayPos += step
        }

        if produced < frames {
            for i in produced..<frames { out[i] = 0 }
            // Replay finished: re-arm. The "ring restarts empty" part is done by
            // the CAPTURE thread when it observes this transition — see
            // `process`. Resetting `totalWritten` from here would be a plain
            // (non-atomic) write to a variable the capture thread also writes,
            // i.e. a data race between two realtime threads. The phase store is
            // the only cross-thread signal.
            phaseA.store(Phase.recording, ordering: .releasing)
        }
        return produced > 0
    }
}
