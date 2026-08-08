//
//  AdaptiveTimeExpansionProcessor.swift
//  OpenBat
//
//  LIVE time expansion, event-triggered with an adaptive (hangover-delimited)
//  event boundary. States: idle → capturing → draining → idle.
//
//  Idle, nothing is emitted. When the trigger fires, emission starts from a
//  short pre-roll (so the onset isn't clipped by detector latency) and every
//  captured sample is emitted, in order, into the 48 kHz output ring. Because
//  the input runs at 384 kHz and the ring drains at 48 kHz, that IS 8×
//  expansion with no resampling at all — the same arithmetic as the
//  playback-only TimeExpansionProcessor, just sourced live.
//
//  Further pulses arriving before `hangoverMs` expires extend the same event,
//  so a burst or feeding buzz merges into one contiguous stretch of audio
//  rather than a string of fragments. The event closes `postRollMs` after the
//  last trigger, or at `maxBufferMs`, whichever comes first.
//
//  === Two invariants that are load-bearing. Do not "optimise" either away. ===
//
//  1. NOTHING IS SELECTED OUT OR DISCARDED WITHIN AN EVENT. Every sample from
//     the pre-roll to the close point is emitted, in order. The hangover
//     decides *when the event ends*; it never punches gaps into audio already
//     inside one. This is why emission is run through a delay line (see
//     `emitDelaySamples`) rather than emitted eagerly and retracted: an eager
//     emitter that later wants to trim its tail can only do so by dropping
//     samples, which is both an audible click and the thing we must not do.
//     The one exception is `ringOverflowCount`: the output ring is sized well
//     above the largest possible event (see its own doc comment) specifically
//     so that exception requires an actual output-thread stall, not routine
//     operation — and it's counted, not silent, if it ever happens.
//
//  2. CAPTURE STOPS WHILE THE RING DRAINS. An event of length L takes 8L to
//     play, and during that drain this processor is deaf — new calls are not
//     captured. That is deliberate. It means the mode cannot stay current with
//     a continuous stream of activity; under sustained calling it falls behind
//     and misses material, exactly like a 1980s Pettersson D240x. Making it
//     keep up (e.g. capturing into a second buffer while draining the first)
//     would turn this into continuous real-time monitoring with selective
//     retention — which is the subject matter of an active third-party patent,
//     US 8,599,647 (see CLAUDE.md's patent notes). The deafness is the feature.
//
//  === Sampler mode (opt-in) ===
//
//  The default behaviour above tries to catch every call it can, which makes
//  the quality of any one playback hostage to the trigger firing at the right
//  instant on the right pulse. Sampler mode inverts that bargain: play ONE call
//  every `samplerIntervalSeconds` and let everything else go by. See
//  `samplerEnabled` for the mechanism and why the two-stage scan is what makes
//  "a clean call" achievable where a single threshold isn't.
//
//  Threading: same contract as HeterodyneProcessor — `process(_:)` on the
//  realtime capture thread, `render(_:frames:)` on the realtime output thread,
//  lock-free SPSC ring between them, NSLock only for main-thread control
//  changes (read once per buffer, never per sample).
//

import AVFoundation
import Synchronization

nonisolated final class AdaptiveTimeExpansionProcessor: @unchecked Sendable {

    /// What the state machine is doing, for the live UI pill.
    enum State: Int, Sendable {
        case idle = 0
        /// An event is open — capturing and feeding the ring.
        case capturing = 1
        /// Event closed, ring still playing out. Capture is deaf here (see
        /// invariant 2 in the file header).
        case draining = 2
    }

    let outputSampleRate: Double = 48_000

    // MARK: Control (main thread ↔ audio threads)

    private let ctrlLock = NSLock()
    private var _gain: Float = 4
    private var _hangoverMs: Double = defaultHangoverMs
    private var _maxBufferMs: Double = defaultMaxBufferMs
    private var _thresholdDB: Double = defaultThresholdDB
    private var _releaseDB: Double = defaultReleaseDB
    private var _preRollMs: Double = defaultPreRollMs
    private var _postRollMs: Double = defaultPostRollMs
    private var _rampMs: Double = defaultRampMs
    private var _expanderEnabled: Bool = defaultExpanderEnabled
    private var _expanderThresholdDB: Double = defaultExpanderThresholdDB
    private var _expanderDepthDB: Double = defaultExpanderDepthDB
    private var _expanderReleaseMs: Double = defaultExpanderReleaseMs
    private var _samplerEnabled: Bool = defaultSamplerEnabled
    private var _samplerIntervalSeconds: Double = defaultSamplerIntervalSeconds
    private var _samplerScanMs: Double = defaultSamplerScanMs
    private var _bandLowFraction: Double = 0
    private var _bandHighFraction: Double = 1
    private var _slowdownFactor: Double = 384_000 / 48_000

    static let defaultHangoverMs: Double = 60
    static let defaultMaxBufferMs: Double = 200
    static let defaultThresholdDB: Double = 12
    static let defaultReleaseDB: Double = 6

    static let defaultPreRollMs: Double = 2.0
    static let defaultPostRollMs: Double = 5.0
    static let defaultRampMs: Double = 3.0
    static let defaultExpanderEnabled = true
    static let defaultExpanderThresholdDB: Double = 8
    static let defaultExpanderDepthDB: Double = 18
    static let defaultExpanderReleaseMs: Double = 2

    static let defaultSamplerEnabled = false
    static let defaultSamplerIntervalSeconds: Double = 5
    static let defaultSamplerScanMs: Double = 150

    /// Detection block. 128 samples ≈ 0.33 ms at 384 kHz — fine enough to place
    /// an onset well inside the pre-roll.
    private static let detectBlock = 128
    /// Minimum gap between triggers for `missedCount` to treat them as separate
    /// pulses. Without it the counter would tick once per 0.33 ms detection
    /// block — a single 5 ms call arriving while deaf would read as ~15 misses.
    /// 5 ms is below the tightest real inter-pulse interval (a feeding buzz),
    /// so genuine buzz pulses still count individually.
    private static let missedPulseGapMs: Double = 5.0
    /// Detection high-pass. Rejects handling noise, wind and speech so they
    /// can't open an event; bat energy is far above this.
    private static let detectHighpassHz: Double = 12_000

    /// How far below the specimen's peak sampler mode still counts as call, as
    /// a linear ratio — −40 dB. Not exposed as a knob because it doesn't
    /// behave like one: the tail-truncation measurements in
    /// `TimeExpansionTuning/FINDINGS.md` were run at −30, −40 and −50 dB and
    /// returned the same call boundary at all three, so the useful range is
    /// wide and flat. What actually binds is the background floor and
    /// `maxBufferMs`, both of which are already tunable.
    private static let samplerDecayFactor: Float = 0.01

    /// Output makeup gain. Bat calls are weak and pass-through preserves the
    /// input's own level, so some makeup is normally wanted.
    var gain: Float {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _gain }
        set { ctrlLock.lock(); _gain = newValue; ctrlLock.unlock() }
    }

    /// How long after the last trigger the event stays open for a further
    /// pulse to extend it. The one real tuning knob.
    ///
    /// Too short and natural bursts split into choppy fragments; too long and
    /// it degenerates toward "wait for a long silence", which at 8× means very
    /// long drains and a correspondingly long deaf window. Note that search-
    /// phase inter-pulse intervals (~50–150 ms) are mostly *longer* than this,
    /// by design: isolated search pulses should each get their own tight event,
    /// which drains inside the following gap. The hangover exists to merge
    /// approach phase and feeding buzzes, where intervals collapse to 5–20 ms.
    var hangoverMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _hangoverMs }
        set { ctrlLock.lock(); _hangoverMs = min(max(newValue, 5), 250); ctrlLock.unlock() }
    }

    /// Hard cap on event length regardless of hangover state — prevents
    /// unbounded growth during continuous activity.
    ///
    /// Deliberately small. At 8× a 200 ms cap already costs a 1.6 s drain, and
    /// the whole of that is deaf time. A multi-second cap would mean missing
    /// the rest of the pass (and everything after it) to hear one buzz in full.
    ///
    /// A change here only takes effect for the NEXT event — an open event
    /// keeps the cap it started with (`eventMaxBufferSamples`), so dragging
    /// this down mid-capture can't truncate the event already in flight
    /// without its ramp-out fade.
    var maxBufferMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _maxBufferMs }
        set { ctrlLock.lock(); _maxBufferMs = min(max(newValue, 20), 500); ctrlLock.unlock() }
    }

    /// How far above the tracked noise floor a block must sit to OPEN an event.
    var thresholdDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _thresholdDB }
        set { ctrlLock.lock(); _thresholdDB = min(max(newValue, 3), 30); ctrlLock.unlock() }
    }

    /// How far above the noise floor the level must stay to hold an open event
    /// open — the hysteresis half of the gate, always ≤ `thresholdDB`.
    ///
    /// This exists because a bat call does not end where it stops being loud
    /// enough to notice. The tail of a downsweep decays well below the attack
    /// threshold while still being real, audible signal, so closing on the
    /// attack threshold clips the end of every call — which is exactly what a
    /// single-threshold gate did here before this was added. Opening needs
    /// confidence (high threshold, few false events); staying open needs only
    /// evidence the call is still going (low threshold). Lower it if call ends
    /// still sound truncated; raise it if events run on into background noise.
    var releaseDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _releaseDB }
        set { ctrlLock.lock(); _releaseDB = min(max(newValue, 0), 30); ctrlLock.unlock() }
    }

    /// Pre-roll ahead of the trigger, so the call onset survives detector
    /// latency. Kept tight: 5 ms of roll would nearly double a 5 ms pulse
    /// before expansion, and expanded length is what has to fit the gap.
    ///
    /// Worth knowing while tuning: if `rampMs` exceeds this, the fade-in is
    /// still rising when the call onset arrives, so every onset is attenuated —
    /// at the shipped 3 ms ramp against a 2 ms pre-roll that costs about
    /// 2.6 dB on the leading edge of every call.
    var preRollMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _preRollMs }
        set { ctrlLock.lock(); _preRollMs = min(max(newValue, 0.5), 20); ctrlLock.unlock() }
    }

    /// Tail kept after the level last exceeded the *release* threshold. The
    /// hangover is only a close decision — the audio is trimmed back to this,
    /// so an event doesn't ship `hangoverMs` of silence (at 8× that would be
    /// ~half a second of dead air per event, extending the deaf window for
    /// nothing).
    ///
    /// This is margin, not the mechanism: the end of a call is found by the
    /// level decaying past `releaseDB`, not by a fixed time. It only has to
    /// cover the detection block plus the ramp, so it stays short.
    ///
    /// Lowering this below the current `rampMs` re-clamps the ramp with it —
    /// see `rampMs`.
    var postRollMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _postRollMs }
        set {
            ctrlLock.lock()
            _postRollMs = min(max(newValue, 1), 50)
            // Keep the invariant from the other direction too: shrinking the
            // post-roll under an already-set ramp would otherwise leave the
            // pair invalid until the ramp happened to be written again.
            _rampMs = min(_rampMs, _postRollMs)
            ctrlLock.unlock()
        }
    }

    /// Fade applied at the start and end of each event, so emission never
    /// begins or ends on a step discontinuity. At 8× this is heard as a ~24 ms
    /// fade — long enough not to read as an abrupt stop, still well under the
    /// ~40 ms an expanded 5 ms call occupies, so it shapes the tail rather than
    /// swallowing the call.
    ///
    /// Clamped to `postRollMs` on write rather than trusted to the caller: the
    /// fade-out has to live inside the tail margin, or it eats call signal
    /// instead. This was a documented hand-maintained invariant while both were
    /// compile-time constants; now that both are live-tunable from the tuning
    /// overlay, the clamp has to be enforced here — the same way `releaseFactor`
    /// is clamped to never exceed the attack threshold in `recomputeDerived`.
    var rampMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _rampMs }
        set {
            ctrlLock.lock()
            _rampMs = min(max(newValue, 0.1), _postRollMs)
            ctrlLock.unlock()
        }
    }

    // MARK: Background expander
    //
    // An event carries the background it was recorded against — the pre-roll,
    // the gaps inside a merged burst, the tail after the call has decayed — and
    // at 8× that background is stretched along with everything else, which is
    // what makes it audible as hiss rather than passing as a click. The
    // expander pulls it down without touching the call.
    //
    // **This does not breach invariant 1** (see the file header). That invariant
    // forbids *selecting or discarding* samples within an event, because sample
    // selection is what the time-expansion patent covers. This is a gain
    // envelope: every sample is still emitted, in order, in the same position,
    // and the count is unchanged. `emitAvailable` already multiplies each
    // sample by `fadeWeight` for the event ramps — this is the same kind of
    // operation with a different curve. Attenuating is not selecting.
    //
    // It is a downward *expander*, not a gate, and deliberately so. A hard gate
    // would silence anything under the threshold — which is exactly the failure
    // `releaseDB`'s hysteresis exists to prevent, since the decaying tail of a
    // downsweep falls below any fixed threshold while still being real signal.
    // A gate would chop that tail in amplitude having just been careful not to
    // chop it in time. The gain instead slides smoothly between full and
    // `expanderDepthDB`, so a decaying tail fades rather than disappearing.

    /// Whether the background expander is applied at all.
    var expanderEnabled: Bool {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expanderEnabled }
        set { ctrlLock.lock(); _expanderEnabled = newValue; ctrlLock.unlock() }
    }

    /// How far above the tracked noise floor a block must sit to pass at full
    /// gain, in dB. Below this the gain slides down toward `expanderDepthDB`;
    /// at the floor itself it is fully attenuated.
    ///
    /// Measured against the same adaptive `noiseFloor` the trigger uses — which
    /// is frozen while an event is open, so it reflects the background as it was
    /// just before the call rather than being dragged up by the call itself.
    var expanderThresholdDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expanderThresholdDB }
        set { ctrlLock.lock(); _expanderThresholdDB = min(max(newValue, 0), 40); ctrlLock.unlock() }
    }

    /// How far down the background is pushed, in dB. 0 disables the effect;
    /// 60 is effectively a mute if that's what the ear prefers.
    var expanderDepthDB: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expanderDepthDB }
        set { ctrlLock.lock(); _expanderDepthDB = min(max(newValue, 0), 60); ctrlLock.unlock() }
    }

    /// How quickly the expander closes again after signal stops, as a time
    /// constant in CAPTURED milliseconds — so at 8× it is heard as eight times
    /// this.
    ///
    /// Because the expander is held fully open for as long as the event's own
    /// hold threshold says the signal is real (see `recordExpanderGain`), this
    /// only ever starts counting once the call is over by that same standard —
    /// so it can be short without endangering tails.
    ///
    /// It needs to be short. The post-roll is a few ms of captured background
    /// sitting directly after every call, and at 8× that is tens of ms of
    /// audible hiss. A 16 ms constant left it around −2 dB there, i.e. barely
    /// attenuated at all, which is what "there is still a strong hiss" sounded
    /// like. The default is now 2 ms captured (~16 ms heard), which reaches
    /// most of the way to full depth inside a 5 ms post-roll.
    var expanderReleaseMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _expanderReleaseMs }
        set { ctrlLock.lock(); _expanderReleaseMs = min(max(newValue, 0.5), 200); ctrlLock.unlock() }
    }

    // MARK: Sampler mode
    //
    // "Play one clean call every N seconds" instead of "play every call the
    // trigger can catch".
    //
    // The default mode's quality problem is not the expansion — it's that the
    // event boundary is decided by a threshold crossing *as it happens*, with
    // no way to know whether the pulse that crossed it was a good specimen or
    // a distant fragment, an echo, or a click. It commits to the first thing
    // that trips the gate, and under invariant 2 that commitment costs it the
    // next 8L of listening, so a bad pick is expensive as well as unpleasant.
    //
    // Sampler mode makes the pick deliberately, in two stages:
    //
    //   1. WAIT. Nothing may open until `samplerIntervalSeconds` has elapsed
    //      since the last selection *and* the ring has drained. Between
    //      samples the mode is idle by choice, not deaf by arithmetic.
    //   2. SCAN, then COMMIT. The first pulse after the interval does not open
    //      an event; it starts a `samplerScanMs` window over which every
    //      detection block's level is recorded. When the window closes, the
    //      LOUDEST block in it is taken as the specimen, its call boundaries
    //      are found by walking outward through that per-block history until
    //      the level drops under the hold threshold, and the whole span — from
    //      pre-roll to post-roll — is emitted.
    //
    // Stage 2 is the part that produces "a nice clean call". Selection runs
    // over history rather than live, so the decision is made knowing how the
    // candidates compare and where each one actually ended, which is exactly
    // what a forward-only threshold cannot know. It's also what lets the
    // boundaries be found by looking at the call itself rather than by
    // hangover timing.
    //
    // Both invariants above still hold: within the selected event every sample
    // between the boundaries is emitted, in order, at 1/8 rate, with only the
    // ramp and expander envelopes applied; and the mode is deaf while draining
    // and idle by design for the rest of the interval.
    //
    // **That is NOT a non-infringement argument, and an earlier version of this
    // comment wrongly presented it as one.** US 8,599,647's claim 1 contains
    // neither a "within an event" limitation nor a real-time limitation — it
    // asks only whether a *fraction* of the input samples was selected as
    // output and transmitted at a slower rate, which both this mode and the
    // default trigger above do. See CLAUDE.md's patent notes for the full claim
    // text and the mapping. The open question there covers the whole of live
    // event-triggered expansion, not this mode specifically; don't re-derive a
    // clearance argument from the two invariants, because they don't reach it.
    //
    // What this does NOT do is improve detection. It makes detection matter
    // less: at one event per 5 s you can afford a large `maxBufferMs` and a
    // generous post-roll, so a mistimed or over-long boundary costs playback
    // time you weren't using anyway rather than the calls that follow.

    /// Whether to sample one call per interval instead of chasing every pulse.
    var samplerEnabled: Bool {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _samplerEnabled }
        set { ctrlLock.lock(); _samplerEnabled = newValue; ctrlLock.unlock() }
    }

    /// How often a call is sampled, measured from the previous selection.
    ///
    /// The floor is 1 s, not lower: a sample is only worth taking once the
    /// previous one has drained, and at 8× a 200 ms event already takes 1.6 s
    /// to play. Setting this below the drain time doesn't speed anything up —
    /// the ring-empty precondition still gates it — it just makes the interval
    /// stop meaning anything.
    var samplerIntervalSeconds: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _samplerIntervalSeconds }
        set { ctrlLock.lock(); _samplerIntervalSeconds = min(max(newValue, 1), 30); ctrlLock.unlock() }
    }

    /// How long to keep collecting candidates after the first pulse before
    /// committing to the loudest of them.
    ///
    /// This is latency traded for specimen quality, and the trade is cheap
    /// here — you are already listening to something that happened a moment
    /// ago. The useful range is set by inter-pulse intervals: search-phase
    /// gaps are ~50–150 ms, so 150 ms typically offers two or three calls from
    /// the same pass to choose between. Zero would reduce this to "first pulse
    /// wins", i.e. the default mode's behaviour with a duty cycle on it.
    ///
    /// Capped at 300 ms because the scan window plus the selected event must
    /// both fit inside the 683 ms delay line — past that the walk-back would
    /// start being clamped and clip the onset it exists to protect.
    var samplerScanMs: Double {
        get { ctrlLock.lock(); defer { ctrlLock.unlock() }; return _samplerScanMs }
        set { ctrlLock.lock(); _samplerScanMs = min(max(newValue, 0), 300); ctrlLock.unlock() }
    }

    /// The actual slowdown factor for the rate this processor was last reset
    /// for — 8× at 384 kHz, computed rather than assumed so a different
    /// negotiated rate can't silently drift out of sync with a hardcoded label.
    var slowdownFactor: Double {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return _slowdownFactor
    }

    /// Restrict listening to a frequency band (fractions of Nyquist), matching
    /// the same viewport-derived band the other listening modes use.
    func setBand(low: Double, high: Double) {
        ctrlLock.lock()
        _bandLowFraction = low
        _bandHighFraction = high
        ctrlLock.unlock()
    }

    /// One snapshot of every control value, read under the lock once per buffer.
    ///
    /// A struct rather than the tuple this used to be: the tuple was already 14
    /// labelled elements and adding the sampler's three pushed it into the
    /// territory CLAUDE.md warns about, where the type-checker starts costing
    /// real build time for no expressive gain. Field names are unchanged, so
    /// `c.low` etc. still read the same at the call sites.
    private struct Controls {
        var gain: Float
        var hangover: Double
        var maxBuffer: Double
        var threshold: Double
        var release: Double
        var preRoll: Double
        var postRoll: Double
        var ramp: Double
        var low: Double
        var high: Double
        var expand: Bool
        var expandThreshold: Double
        var expandDepth: Double
        var expandRelease: Double
        var sampler: Bool
        var samplerInterval: Double
        var samplerScan: Double
    }

    private func controls() -> Controls {
        ctrlLock.lock(); defer { ctrlLock.unlock() }
        return Controls(gain: _gain, hangover: _hangoverMs, maxBuffer: _maxBufferMs,
                        threshold: _thresholdDB, release: _releaseDB,
                        preRoll: _preRollMs, postRoll: _postRollMs, ramp: _rampMs,
                        low: _bandLowFraction, high: _bandHighFraction,
                        expand: _expanderEnabled, expandThreshold: _expanderThresholdDB,
                        expandDepth: _expanderDepthDB, expandRelease: _expanderReleaseMs,
                        sampler: _samplerEnabled, samplerInterval: _samplerIntervalSeconds,
                        samplerScan: _samplerScanMs)
    }

    // MARK: Observable-ish state (any thread → main)

    private let stateA = Atomic<Int>(State.idle.rawValue)
    /// Number of events emitted since the last reset, for diagnostics.
    private let eventCountA = Atomic<Int>(0)
    /// Pulses that triggered while the ring was still draining and so were
    /// never captured — the running cost of invariant 2, surfaced so the user
    /// can see it rather than wondering why a busy pass sounds sparse.
    private let missedCountA = Atomic<Int>(0)
    /// Times `emitAvailable` hit a full ring mid-event and had to truncate it
    /// (see the `pushToRing` guard there). `ringCapacity` is sized well above
    /// the largest possible event at the hard-clamped `maxBufferMs`/`hangoverMs`
    /// maxima, so this should only ever tick if the output thread has
    /// genuinely stalled for seconds — same idea as
    /// `TimeExpansionProcessor.overflowCount`, kept separate from
    /// `missedCount` because it's a different failure (an event that DID open
    /// losing its own tail, vs. a pulse that never got to open one at all).
    private let ringOverflowCountA = Atomic<Int>(0)

    /// Current state. `draining` is derived: the event has closed but the ring
    /// still holds audio.
    var state: State {
        let raw = stateA.load(ordering: .relaxed)
        if raw == State.capturing.rawValue { return .capturing }
        return ringAvailable > 0 ? .draining : .idle
    }

    var eventCount: Int { eventCountA.load(ordering: .relaxed) }
    var missedCount: Int { missedCountA.load(ordering: .relaxed) }
    var ringOverflowCount: Int { ringOverflowCountA.load(ordering: .relaxed) }

    // MARK: DSP + state machine (capture thread only)

    private var inputSampleRate: Double = 384_000

    private var bandHPa = Biquad(), bandHPb = Biquad()
    private var bandLPa = Biquad(), bandLPb = Biquad()
    private var applyHP = false
    private var applyLP = false
    private var appliedLowFraction = -1.0
    private var appliedHighFraction = -1.0
    /// Notch for a measured hardware artifact: a tone at inputSampleRate/4
    /// (96 kHz), ~+11 dB over the local noise floor in every recording checked,
    /// so it's the ADC or USB path rather than the acoustic scene. Any mode
    /// that maps frequency down puts it in the audible band; expansion at 8×
    /// lands it at 12 kHz.
    private var artifactNotch = Biquad()
    /// Detection-only high-pass — a separate filter chain from the listening
    /// band, so widening the band to include audible frequencies doesn't start
    /// triggering events on handling noise.
    private var detHPa = Biquad(), detHPb = Biquad()

    /// Delay line holding band-limited, gained input at the capture rate.
    /// Emission reads from here `emitDelaySamples` behind the write head, which
    /// is what lets an event's tail be trimmed to `postRollMs` without ever
    /// retracting or dropping a sample that was already emitted (invariant 1).
    private let delay: UnsafeMutableBufferPointer<Float>
    private static let delayCapacity = 262_144   // 683 ms at 384 kHz
    private static let delayMask = delayCapacity - 1

    /// Expander gain per detection block, parallel to `delay` but one entry per
    /// `detectBlock` samples rather than per sample — 2048 entries covering the
    /// same span for 8 KB instead of 1 MB.
    ///
    /// It has to be a history, not a single current value: `emitAvailable`
    /// reads `emitDelaySamples` behind the write head, so the gain that belongs
    /// to the sample being emitted was computed some blocks ago. Applying the
    /// *current* gain to an older sample would put the envelope out of step with
    /// the audio — attenuating the start of a call because the background
    /// afterwards happened to be quiet.
    private let blockGains: UnsafeMutableBufferPointer<Float>
    private static let blockGainCount = delayCapacity / detectBlock
    private static let blockGainMask = blockGainCount - 1
    /// Index of the newest block with a computed gain, so emission can clamp to
    /// it when `emitDelaySamples` is short enough that `emitPos` reaches into
    /// the block still being filled (which happens whenever hangover ≤ post-roll).
    private var lastGainBlock = -1
    /// Smoothed expander gain, carried block to block.
    private var expanderGain: Float = 1

    /// Detection RMS per block, one entry per `detectBlock` samples, covering
    /// the same span as `delay`. Written for every block whether or not an
    /// event is open.
    ///
    /// This is what sampler mode selects over. Choosing the best of several
    /// candidates, and finding where the chosen one actually started and
    /// ended, are both questions about the recent past; a forward-only trigger
    /// has no way to answer either, which is why the default mode has to
    /// commit to the first crossing and take what it gets.
    private let blockLevels: UnsafeMutableBufferPointer<Float>

    /// Absolute count of samples written to `delay`. Absolute (not modular)
    /// because every position comparison below is an ordering question; at
    /// 384 kHz an Int takes ~760 000 years to overflow.
    private var totalWritten = 0

    private var isCapturing = false
    /// Absolute position where the open event began emitting (its pre-roll).
    private var eventStart = 0
    /// Next absolute position to emit.
    private var emitPos = 0
    /// Absolute position of the most recent triggering block's end.
    private var lastTrigger = 0
    /// `maxBufferSamples` as it was at the moment THIS event opened, snapshot
    /// rather than read live from `emitAvailable`. `maxBufferMs` is a live
    /// settings knob (`process()` recomputes `maxBufferSamples` every buffer),
    /// so reading it live in `closeAt` would let a mid-event slider drag pull
    /// the close point backward past `emitPos` — an instant truncation with no
    /// ramp-out, since the fade-out only ever applies to samples that pass
    /// through the emission loop. Snapshotting means a live change only takes
    /// effect for the *next* event.
    private var eventMaxBufferSamples = 0
    /// Absolute close point for an event whose end is already known when it
    /// opens — i.e. every sampler event, since those are committed backwards
    /// from history. 0 means "no fixed close", and `emitAvailable` falls back
    /// to the live `lastTrigger + postRoll` rule.
    ///
    /// A fixed-close event also needs no `emitDelaySamples`: the delay line
    /// exists so a still-open event's tail can be trimmed without retracting
    /// emitted samples, and there is nothing to trim when the boundary was
    /// decided before the first sample went out.
    private var eventFixedClose = 0

    // Sampler mode state (capture thread only). `samplerScanning` is the
    // second stage described in the `samplerEnabled` doc comment — armed by a
    // pulse, resolved when `samplerScanEnd` passes.
    private var samplerScanning = false
    /// Earliest absolute position at which a new sample may be armed.
    private var samplerArmAt = 0
    private var samplerScanEnd = 0
    private var samplerBestRMS: Float = 0
    private var samplerBestBlock = -1
    /// Distinct pulses seen in the current scan window. All but the winner are
    /// added to `missedCount` at commit — in this mode passing calls over is
    /// the whole design, so the counter should say so rather than read zero.
    private var samplerCandidates = 0

    // Derived from the control values, recomputed when they change.
    private var preRollSamples = 0
    private var postRollSamples = 0
    private var rampSamples = 1
    private var hangoverSamples = 0
    private var maxBufferSamples = 0
    private var missedGapSamples = 0
    /// How far behind the write head emission runs: `hangover - postRoll`. At
    /// the moment an event's hangover expires, emission has therefore reached
    /// exactly `lastTrigger + postRoll` and can simply stop.
    private var emitDelaySamples = 0
    private var thresholdFactor: Float = 4
    private var releaseFactor: Float = 2
    private var expanderOn = defaultExpanderEnabled
    /// Linear amplitude ratio above the floor at which the expander is fully open.
    private var expanderFactor: Float = 2.5
    /// Linear gain applied at (and below) the noise floor.
    private var expanderFloorGain: Float = 0.126
    /// Per-block one-pole release coefficient, derived from `expanderReleaseMs`.
    private var expanderReleaseCoeff: Float = 0.02
    private var samplerOn = defaultSamplerEnabled
    private var samplerIntervalSamples = 0
    private var samplerScanSamples = 0

    // Detection accumulator, carried across buffers so a tap buffer that isn't
    // a multiple of `detectBlock` doesn't reset the analysis.
    private var blockSumSquares: Float = 0
    private var blockFilled = 0
    private var noiseFloor: Float = 1e-4

    // MARK: Output ring

    // Lock-free SPSC ring, same contract as the sibling processors: the
    // producer only advances `writeIndexA`, the consumer only advances
    // `readIndexA`.
    // Sized well above the largest possible single event (500 ms maxBufferMs
    // → ~192 000 samples plus pre-roll, at the hard-clamped maximum) so
    // hitting `ringOverflowCount` requires the output thread to have
    // genuinely stalled mid-drain, not just an event running at its own cap —
    // same reasoning as `TimeExpansionProcessor`'s ring sizing.
    private let ring: UnsafeMutableBufferPointer<Float>
    private static let ringCapacity = 524_288    // ~10.9 s at 48 kHz
    private let writeIndexA = Atomic<Int>(0)
    private let readIndexA = Atomic<Int>(0)

    private var ringAvailable: Int {
        let w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .relaxed)
        return (w - r + Self.ringCapacity) % Self.ringCapacity
    }

    init() {
        delay = .allocate(capacity: Self.delayCapacity)
        delay.initialize(repeating: 0)
        ring = .allocate(capacity: Self.ringCapacity)
        ring.initialize(repeating: 0)
        blockGains = .allocate(capacity: Self.blockGainCount)
        blockGains.initialize(repeating: 1)
        blockLevels = .allocate(capacity: Self.blockGainCount)
        blockLevels.initialize(repeating: 0)
        recomputeDerived(controls())
    }

    deinit {
        delay.deallocate()
        ring.deallocate()
        blockGains.deallocate()
        blockLevels.deallocate()
    }

    /// Reconfigure for the capture rate and clear all state. Call before
    /// starting capture in this mode.
    func reset(inputSampleRate fs: Double) {
        inputSampleRate = fs
        ctrlLock.lock(); _slowdownFactor = fs / outputSampleRate; ctrlLock.unlock()

        let c = controls()
        reconfigureBand(low: c.low, high: c.high)
        artifactNotch = .notch(center: fs / 4, sampleRate: fs)
        detHPa = .highpass(cutoff: min(Self.detectHighpassHz, fs / 2 * 0.9), sampleRate: fs)
        detHPb = .highpass(cutoff: min(Self.detectHighpassHz, fs / 2 * 0.9), sampleRate: fs)
        recomputeDerived(c)

        totalWritten = 0
        isCapturing = false
        eventStart = 0
        emitPos = 0
        lastTrigger = 0
        eventMaxBufferSamples = 0
        eventFixedClose = 0
        // `samplerArmAt` at 0 means the first call heard after a mode switch is
        // sampled immediately rather than after a silent interval — switching
        // in and hearing nothing for five seconds would read as broken.
        samplerScanning = false
        samplerArmAt = 0
        samplerScanEnd = 0
        samplerBestRMS = 0
        samplerBestBlock = -1
        samplerCandidates = 0
        blockSumSquares = 0
        blockFilled = 0
        noiseFloor = 1e-4
        blockGains.update(repeating: 1)
        blockLevels.update(repeating: 0)
        lastGainBlock = -1
        expanderGain = 1
        stateA.store(State.idle.rawValue, ordering: .relaxed)
        eventCountA.store(0, ordering: .relaxed)
        missedCountA.store(0, ordering: .relaxed)
        ringOverflowCountA.store(0, ordering: .relaxed)
        writeIndexA.store(0, ordering: .relaxed)
        readIndexA.store(0, ordering: .relaxed)
    }

    private func recomputeDerived(_ c: Controls) {
        expanderOn = c.expand
        expanderFactor = Float(pow(10.0, c.expandThreshold / 20.0))
        expanderFloorGain = Float(pow(10.0, -c.expandDepth / 20.0))
        // Per-block one-pole coefficient for the requested time constant, derived
        // from the real block duration so the release means the same number of
        // milliseconds whatever rate iOS negotiated.
        let blockMs = Double(Self.detectBlock) / inputSampleRate * 1000
        expanderReleaseCoeff = Float(1 - exp(-blockMs / max(c.expandRelease, 0.001)))
        let perMs = inputSampleRate / 1000
        // Toggling the mode abandons any scan in flight rather than letting it
        // resolve later against a `samplerBestBlock` that may by then have
        // aged out of `blockLevels`. Re-arming at the current position (not at
        // `+ interval`) keeps the "switch on, hear the next call" behaviour
        // `reset` establishes.
        if c.sampler != samplerOn {
            samplerScanning = false
            samplerCandidates = 0
            samplerBestBlock = -1
            samplerArmAt = totalWritten
        }
        samplerOn = c.sampler
        samplerIntervalSamples = Int(c.samplerInterval * inputSampleRate)
        samplerScanSamples = Int(c.samplerScan * perMs)
        let preRoll = c.preRoll, postRoll = c.postRoll, ramp = c.ramp
        let hangover = c.hangover, maxBuffer = c.maxBuffer
        let threshold = c.threshold, release = c.release
        preRollSamples = Int(preRoll * perMs)
        postRollSamples = Int(postRoll * perMs)
        // Belt and braces on the ramp ≤ post-roll invariant. The setters clamp
        // it already, but this is the one place both values are turned into the
        // sample counts the audio thread actually uses, so it's also the one
        // place a future caller could bypass them.
        rampSamples = max(min(Int(ramp * perMs), postRollSamples), 1)
        hangoverSamples = Int(hangover * perMs)
        maxBufferSamples = Int(maxBuffer * perMs)
        missedGapSamples = Int(Self.missedPulseGapMs * perMs)
        // The hangover is never shorter than the tail we keep, or the delayed
        // emitter would need to run ahead of the write head.
        emitDelaySamples = max(hangoverSamples - postRollSamples, 0)
        thresholdFactor = Float(pow(10.0, threshold / 20.0))
        // Release never above attack, or the gate would have inverted
        // hysteresis and chatter open/closed on a steady tone.
        releaseFactor = Float(pow(10.0, min(release, threshold) / 20.0))
    }

    private func reconfigureBand(low: Double, high: Double) {
        let nyquist = inputSampleRate / 2
        let lowCut = low * nyquist
        let highCut = high * nyquist
        applyHP = lowCut > 100
        if applyHP {
            bandHPa = .highpass(cutoff: lowCut, sampleRate: inputSampleRate)
            bandHPb = .highpass(cutoff: lowCut, sampleRate: inputSampleRate)
        }
        applyLP = highCut < nyquist * 0.98
        if applyLP {
            bandLPa = .lowpass(cutoff: highCut, sampleRate: inputSampleRate)
            bandLPb = .lowpass(cutoff: highCut, sampleRate: inputSampleRate)
        }
        appliedLowFraction = low
        appliedHighFraction = high
    }

    // MARK: Producer (capture thread)

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        let c = controls()
        if c.low != appliedLowFraction || c.high != appliedHighFraction {
            reconfigureBand(low: c.low, high: c.high)
        }
        recomputeDerived(c)
        let g = c.gain

        for i in 0..<n {
            let raw = channel[i]

            // Listening chain: notch the hardware artifact, apply the band,
            // apply makeup gain. Filter state runs continuously whether or not
            // an event is open, so an event never starts mid-transient.
            var x = artifactNotch.process(raw)
            if applyHP { x = bandHPb.process(bandHPa.process(x)) }
            if applyLP { x = bandLPb.process(bandLPa.process(x)) }
            delay[totalWritten & Self.delayMask] = x * g

            // Detection chain: independent of the listening band.
            let d = detHPb.process(detHPa.process(raw))
            blockSumSquares += d * d

            totalWritten += 1
            blockFilled += 1

            if blockFilled == Self.detectBlock {
                let rms = (blockSumSquares / Float(Self.detectBlock)).squareRoot()
                blockSumSquares = 0
                blockFilled = 0
                evaluate(blockRMS: rms)
                emitAvailable()
            }
        }
    }

    /// Decide whether the block just finished counts as signal, and open an
    /// event if it does. `totalWritten` is the block's end position.
    ///
    /// Two thresholds, not one. Opening an event requires the full
    /// `thresholdDB` over the floor; holding one open requires only
    /// `releaseDB`. See `releaseDB` for why — a single threshold clips the
    /// decaying tail off the end of every call.
    private func evaluate(blockRMS: Float) {
        // The floor adapts down quickly (so moving to a quieter spot re-arms
        // the trigger promptly) and creeps up slowly. It is frozen while an
        // event is open, or a long buzz would raise the floor high enough to
        // close itself.
        if !isCapturing {
            if blockRMS < noiseFloor {
                noiseFloor += (blockRMS - noiseFloor) * 0.2
            } else {
                noiseFloor += (blockRMS - noiseFloor) * 0.0005
            }
        }

        recordExpanderGain(blockRMS: blockRMS)

        // Level history, written unconditionally so sampler mode can look back
        // over a whole scan window. `totalWritten` is always a multiple of
        // `detectBlock` here (the caller only fires on a full block), so the
        // block that just finished is the one ending at this position.
        let block = totalWritten / Self.detectBlock - 1
        if block >= 0 { blockLevels[block & Self.blockGainMask] = blockRMS }

        if samplerOn {
            evaluateSampler(blockRMS: blockRMS, block: block)
            return
        }

        // The absolute terms keep a near-silent input (where the floor decays
        // toward zero) from triggering on its own dither.
        if isCapturing {
            // Hold open on the release threshold. `lastTrigger` is what
            // `emitAvailable` measures the tail from, so tracking the decay
            // here is what keeps the end of the call intact.
            if blockRMS > max(noiseFloor * releaseFactor, 3e-6) {
                lastTrigger = totalWritten
            }
        } else {
            guard blockRMS > max(noiseFloor * thresholdFactor, 1e-5) else { return }
            // Read the gap back to the previous trigger before overwriting it —
            // it's what distinguishes a new pulse from further blocks of one
            // already counted.
            let gapSinceLastTrigger = totalWritten - lastTrigger
            lastTrigger = totalWritten

            // Deaf while the previous event is still playing out — see
            // invariant 2 in the file header. This is where sustained activity
            // gets dropped, deliberately.
            guard ringAvailable == 0 else {
                if gapSinceLastTrigger > missedGapSamples {
                    missedCountA.wrappingAdd(1, ordering: .relaxed)
                }
                return
            }

            isCapturing = true
            let blockStart = totalWritten - Self.detectBlock
            eventStart = max(blockStart - preRollSamples, totalWritten - Self.delayCapacity + Self.detectBlock)
            emitPos = eventStart
            eventMaxBufferSamples = maxBufferSamples
            stateA.store(State.capturing.rawValue, ordering: .relaxed)
            eventCountA.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Sampler mode's replacement for the trigger half of `evaluate`: wait out
    /// the interval, scan for candidates, commit to the best one.
    ///
    /// Nothing here opens an event directly — `commitSamplerEvent` does, and
    /// only ever backwards over material already in the delay line.
    private func evaluateSampler(blockRMS: Float, block: Int) {
        let isTrigger = blockRMS > max(noiseFloor * thresholdFactor, 1e-5)
        var isNewPulse = false
        if isTrigger {
            // Same debounce as the default path: without it a single 5 ms call
            // would read as ~15 separate pulses, one per detection block.
            isNewPulse = (totalWritten - lastTrigger) > missedGapSamples
            lastTrigger = totalWritten
        }

        if isCapturing {
            // Sampler events are emitted whole in the same call that commits
            // them, so this is all but unreachable; counted rather than
            // ignored so it can't hide if that ever stops being true.
            if isNewPulse { missedCountA.wrappingAdd(1, ordering: .relaxed) }
            return
        }

        if samplerScanning {
            if isNewPulse { samplerCandidates += 1 }
            if blockRMS > samplerBestRMS {
                samplerBestRMS = blockRMS
                samplerBestBlock = block
            }
            guard totalWritten >= samplerScanEnd else { return }
            // Never commit while the specimen is still sounding. The boundary
            // walk can only reach blocks already written, so committing
            // mid-call clips the tail by construction — and it is a
            // *systematic* clip, not an occasional one. Simulated over the
            // five-pass corpus: with this wait, even a 0 ms scan delivers 86%
            // of sampled calls complete; without it, 7%.
            //
            // Bounded by `maxBufferSamples` so continuous noise above the
            // boundary can't hold the commit off indefinitely.
            if blockRMS > samplerBoundary(), totalWritten - samplerScanEnd < maxBufferSamples {
                return
            }
            commitSamplerEvent(newestBlock: block)
            return
        }

        // Waiting. The ring-empty test is not redundant with the interval: a
        // short interval against a long event would otherwise re-arm mid-drain,
        // and capturing while the previous sample is still playing is the one
        // thing invariant 2 forbids.
        guard totalWritten >= samplerArmAt, ringAvailable == 0 else {
            if isNewPulse { missedCountA.wrappingAdd(1, ordering: .relaxed) }
            return
        }
        guard isTrigger else { return }

        samplerScanning = true
        samplerScanEnd = totalWritten + samplerScanSamples
        samplerBestRMS = blockRMS
        samplerBestBlock = block
        samplerCandidates = 1
    }

    /// Resolve a finished scan into an event: take the loudest block as the
    /// specimen, find that call's own boundaries in `blockLevels`, and open a
    /// fixed-close event over the whole of it.
    ///
    /// Level at or below which a block is no longer part of the specimen.
    ///
    /// Two terms, and the walk stops at whichever is HIGHER. `noiseFloor *
    /// releaseFactor` is the existing hold threshold and does the work almost
    /// everywhere; the peak-relative term only binds for a call loud enough
    /// that 40 dB down is still above the background, where it stops a walk
    /// from running on through loud noise. Sweeping the floor multiplier over
    /// the corpus, this pairing is what delivers whole calls: at 6 dB over the
    /// floor (i.e. `releaseFactor`) 100% of sampled calls arrive complete,
    /// while at 9–15 dB only 57–64% do, because the call's own quiet edges get
    /// cut. Raising the multiplier does not tighten the capture, it truncates
    /// it.
    ///
    /// The peak-relative drop is insensitive by comparison — 20, 30 and 40 dB
    /// all land within a few percent — which is why `samplerDecayFactor` is a
    /// constant rather than a knob.
    private func samplerBoundary() -> Float {
        max(samplerBestRMS * Self.samplerDecayFactor, noiseFloor * releaseFactor, 3e-6)
    }

    /// Number of consecutive blocks below the boundary needed to end the walk.
    ///
    /// One is not enough: a call's envelope dips inside itself, and stopping
    /// on the first quiet block ends the specimen early. Measured over the
    /// corpus, requiring one block drops completeness to 79%; requiring two
    /// gives 100%, and three adds nothing. This is the same reasoning as the
    /// hold-frames rule in `TimeExpansionTuning/extent.py`, which is what the
    /// ground-truth call boundaries are measured with.
    private static let samplerQuietBlocks = 2

    private func commitSamplerEvent(newestBlock: Int) {
        samplerScanning = false
        samplerArmAt = totalWritten + samplerIntervalSamples

        // Every candidate but the one being played is a call gone by. That is
        // the mode working as intended, not a fault — but it should still show
        // up in the tally, or the counter would read zero while the user could
        // plainly hear it passing calls over.
        let passedOver = max(samplerCandidates - 1, 0)
        if passedOver > 0 { missedCountA.wrappingAdd(passedOver, ordering: .relaxed) }
        samplerCandidates = 0

        guard samplerBestBlock >= 0 else { return }

        let boundary = samplerBoundary()
        let maxBlocks = max(maxBufferSamples / Self.detectBlock, 1)
        // Never walk out of the history's own window — it covers exactly the
        // delay line, so staying inside it is also what keeps `eventStart`
        // from being clamped and clipping the onset.
        let oldestBlock = max(0, newestBlock - Self.blockGainCount + 2)

        // Walk out from the peak in both directions, remembering the last
        // block that was above the boundary and stopping only after
        // `samplerQuietBlocks` consecutive blocks below it.
        var startBlock = samplerBestBlock
        var quiet = 0
        var j = samplerBestBlock
        while j > oldestBlock, samplerBestBlock - j < maxBlocks {
            if blockLevels[(j - 1) & Self.blockGainMask] > boundary {
                quiet = 0
                startBlock = j - 1
            } else {
                quiet += 1
                if quiet >= Self.samplerQuietBlocks { break }
            }
            j -= 1
        }

        var endBlock = samplerBestBlock
        quiet = 0
        j = samplerBestBlock
        while j < newestBlock, j - startBlock < maxBlocks {
            if blockLevels[(j + 1) & Self.blockGainMask] > boundary {
                quiet = 0
                endBlock = j + 1
            } else {
                quiet += 1
                if quiet >= Self.samplerQuietBlocks { break }
            }
            j += 1
        }

        let onset = startBlock * Self.detectBlock
        let decayEnd = (endBlock + 1) * Self.detectBlock

        eventStart = max(onset - preRollSamples, totalWritten - Self.delayCapacity + Self.detectBlock)
        emitPos = eventStart
        eventMaxBufferSamples = maxBufferSamples
        // Clamped to `totalWritten` because the post-roll can reach past the
        // last block written — those samples don't exist yet, and a
        // fixed-close event emits in one pass rather than waiting for them.
        eventFixedClose = min(min(decayEnd + postRollSamples, totalWritten),
                              eventStart + maxBufferSamples)
        guard eventFixedClose > eventStart else { return }

        isCapturing = true
        stateA.store(State.capturing.rawValue, ordering: .relaxed)
        eventCountA.wrappingAdd(1, ordering: .relaxed)
    }

    /// Compute and store the background-expander gain for the block that just
    /// finished. Called for every block, event or not, so the history is
    /// already populated when an event opens and reaches back over its pre-roll.
    ///
    /// The curve is proportional rather than a switch: gain slides from
    /// `expanderFloorGain` at the noise floor up to 1 at `expanderFactor` above
    /// it, shaped by the same smoothstep the event ramps use. A binary
    /// open/shut decision here would chatter on any block sitting near the
    /// threshold — a decaying tail crosses it repeatedly — and each flip would
    /// be a step in the gain, i.e. a click.
    private func recordExpanderGain(blockRMS: Float) {
        let target: Float
        if !expanderOn {
            target = 1
        } else {
            // Same absolute guard as the trigger: with a near-silent input the
            // floor decays toward zero, and a ratio against ~0 is meaningless.
            let floor = max(noiseFloor, 3e-6)
            let openAt = floor * expanderFactor
            // HOLD FULLY OPEN while the event's own hold condition is true.
            //
            // This is what makes a fast release safe, and it's why the expander
            // reuses `releaseFactor` rather than deciding for itself where a
            // call ends. That hysteresis is already tuned to the one question
            // that matters here — is this still real signal, or is it
            // background? — and it was tuned precisely because a decaying tail
            // stays real long after it stops being loud. Letting the expander
            // apply its own, stricter opinion would re-chop exactly the tails
            // `releaseDB` protects, in volume instead of in time.
            //
            // The consequence: the expander can never be more aggressive about
            // the end of a call than the event logic is. It only starts closing
            // once the call is over by that same standard, so how fast it
            // closes after that is a free choice.
            let holdOpen = blockRMS > max(noiseFloor * releaseFactor, 3e-6)
            if holdOpen || blockRMS >= openAt {
                target = 1
            } else if openAt <= floor {
                target = 1   // threshold of 0 dB — expander effectively off
            } else {
                let t = (blockRMS - floor) / (openAt - floor)
                target = expanderFloorGain + (1 - expanderFloorGain) * Self.fadeWeight(t)
            }
        }

        // Attack is INSTANT; only the release is smoothed.
        //
        // A first pass smoothed the attack too (0.35 per block) and measured
        // 5 blocks — 1.67 ms of captured audio — to recover to −1 dB. A MYCA
        // call is around 1.3 ms, so the expander would still have been opening
        // when the call ended: the same defect as a ramp longer than the
        // pre-roll, arrived at from a different direction. Anything that fades
        // in over the length of a bat call is wrong here.
        //
        // Instant attack is safe because the envelope is INTERPOLATED between
        // block centres on the way out (see `expanderGain(at:)`), so even a
        // full-depth jump is heard as a smooth transition over one block —
        // 0.33 ms captured, ~2.7 ms at 8×. Storing a piecewise-constant
        // envelope and stepping between blocks is what would click.
        //
        // Release stays slow, in the capture domain and therefore stretched
        // with the audio: it is what stops a decaying tail from being pumped.
        if target > expanderGain {
            expanderGain = target
        } else {
            expanderGain += (target - expanderGain) * expanderReleaseCoeff
        }

        // Stored one block EARLY, i.e. with a block of lookahead. Detection
        // can only report a call after the block containing its onset has
        // finished, so without this the first block of every call is still
        // under the previous (closed) gain. The delay line runs far enough
        // behind that the slot being back-filled has not normally been emitted
        // yet — and where it has (a zero `emitDelaySamples`, i.e. hangover ≤
        // post-roll), the cost is that one block of onset misses the lookahead,
        // not a glitch.
        let block = (totalWritten / Self.detectBlock) - 2
        guard block >= 0 else { return }
        blockGains[block & Self.blockGainMask] = expanderGain
        lastGainBlock = block
    }

    /// The expander gain belonging to an absolute sample position, linearly
    /// interpolated between the two nearest block gains.
    ///
    /// The interpolation is what makes an instant attack safe. Held
    /// piecewise-constant, the envelope would step by up to the full depth at a
    /// block boundary — an instantaneous discontinuity in the output, i.e. a
    /// click, and time expansion does not soften it because the step happens
    /// between two output samples however slowly the audio is paced.
    /// Interpolating spreads any change across a whole block, ~2.7 ms at 8×.
    ///
    /// Clamped to `lastGainBlock` because emission can reach into the block
    /// currently being filled whenever `emitDelaySamples` is small (hangover ≤
    /// post-roll makes it zero), and that block has no gain yet.
    private func expanderGain(at position: Int) -> Float {
        guard expanderOn, lastGainBlock >= 0 else { return 1 }
        // Block gains are treated as sitting at block CENTRES, so a position is
        // interpolated between the block it falls in and its neighbour.
        let shifted = position - Self.detectBlock / 2
        let block = shifted >= 0 ? shifted / Self.detectBlock : -1
        guard block >= 0 else { return blockGains[0 & Self.blockGainMask] }
        let lo = min(block, lastGainBlock)
        let hi = min(block + 1, lastGainBlock)
        let a = blockGains[lo & Self.blockGainMask]
        let b = blockGains[hi & Self.blockGainMask]
        if a == b { return a }
        let t = Float(shifted - block * Self.detectBlock) / Float(Self.detectBlock)
        return a + (b - a) * t
    }

    /// Emit everything the delay line has made final, up to whichever limit
    /// closes the event first.
    private func emitAvailable() {
        guard isCapturing else { return }

        // `closeAt` is where the event ends if nothing further triggers. A new
        // trigger raises `lastTrigger` and therefore moves it later — which is
        // exactly how a burst merges into one contiguous event, with no gap
        // punched into what was already emitted.
        //
        // A sampler event has its close point already: it was committed
        // backwards over history, so it cannot be extended and there is
        // nothing for the delay line to hold back. Emitting it straight
        // through is what makes it land as one whole call rather than trickling
        // out over the following `hangover − postRoll` of capture.
        let fixed = eventFixedClose > 0
        let closeAt = fixed
            ? eventFixedClose
            : min(lastTrigger + postRollSamples, eventStart + eventMaxBufferSamples)
        let limit = fixed ? closeAt : min(totalWritten - emitDelaySamples, closeAt)

        while emitPos < limit {
            // Every sample the delay line holds is emitted, in order — the
            // expander only scales it. Invariant 1 is about not *selecting*
            // samples; this loop still writes one output sample per delay-line
            // sample, exactly as before.
            var s = delay[emitPos & Self.delayMask] * expanderGain(at: emitPos)

            // Ramp in and out so emission never starts or stops on a step.
            let sinceStart = emitPos - eventStart
            if sinceStart < rampSamples {
                s *= Self.fadeWeight(Float(sinceStart) / Float(rampSamples))
            }
            let untilEnd = closeAt - emitPos
            if untilEnd <= rampSamples {
                s *= Self.fadeWeight(Float(max(untilEnd, 0)) / Float(rampSamples))
            }

            guard pushToRing(s) else {
                // Ring full. The cap should prevent this, but if it happens the
                // event is over — better a truncated event than a wrapped one.
                ringOverflowCountA.wrappingAdd(1, ordering: .relaxed)
                closeEvent()
                return
            }
            emitPos += 1
        }

        if emitPos >= closeAt {
            closeEvent()
        }
    }

    /// Fade curve for the event ramps: smoothstep, `t²(3−2t)`, for `t` in 0…1.
    ///
    /// Not linear. A linear fade reaches its endpoints with non-zero slope, so
    /// the gain has a corner at both ends of the ramp — audible as an abrupt
    /// stop even though nothing is being clipped, which is exactly how the
    /// first version sounded. Smoothstep is flat at both ends, so the fade
    /// eases in and out of full gain instead of hinging into it. Chosen over a
    /// raised cosine purely to keep a transcendental off the audio thread; the
    /// two are perceptually indistinguishable here.
    private static func fadeWeight(_ t: Float) -> Float {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private func closeEvent() {
        isCapturing = false
        eventFixedClose = 0
        stateA.store(State.idle.rawValue, ordering: .relaxed)
        // The floor tracker resumes from where it was; it was frozen, not
        // reset, so it still reflects the pre-event background.
    }

    /// Returns false if the ring is full.
    private func pushToRing(_ s: Float) -> Bool {
        let cap = Self.ringCapacity
        let w = writeIndexA.load(ordering: .relaxed)
        let r = readIndexA.load(ordering: .acquiring)
        let nextW = (w + 1) % cap
        if nextW == r { return false }
        ring[w] = s
        writeIndexA.store(nextW, ordering: .releasing)
        return true
    }

    // MARK: Consumer (output thread)

    /// Straight drain at the output rate, zero-filled when empty.
    ///
    /// Deliberately no rate/drift correction, unlike the continuously-fed
    /// sibling processors: there is no steady producer to stay matched to, the
    /// silence between events is the intended output, and each event restarts
    /// from an empty ring so drift has nothing to accumulate across.
    func render(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let cap = Self.ringCapacity
        let w = writeIndexA.load(ordering: .acquiring)
        var r = readIndexA.load(ordering: .relaxed)
        var available = (w - r + cap) % cap

        var produced = 0
        while produced < frames, available > 0 {
            out[produced] = ring[r]
            r = (r + 1) % cap
            available -= 1
            produced += 1
        }
        readIndexA.store(r, ordering: .releasing)

        if produced < frames {
            for i in produced..<frames { out[i] = 0 }
        }
    }
}
