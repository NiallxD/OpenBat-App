//
//  HowlGuard.swift
//  OpenBat
//
//  Stops the listening path howling at itself when the output is the phone's
//  own speaker.
//
//  The loop is real and it is not the usual PA squeal. Heterodyne SHIFTS
//  frequency: what leaves the speaker is 0–4 kHz, and what the input band
//  filter lets back in starts at 15 kHz (`SimplifiedView.bandLowHz`), so the
//  two can only meet through the speaker's own distortion — a loud audible
//  tone sprays harmonics past 15 kHz, the mic (AGC-free, `.measurement`) hears
//  them, the mixer brings them back down to audio, and a gain of several
//  hundred puts them back out of the speaker far louder than they arrived, so
//  the whole audible band fills with hiss. (Several hundred, not the dozen an
//  earlier version of this comment claimed: the chain is
//  `HeterodyneProcessor.defaultGain` × the +24 dB default trim ×
//  `ListenOutputStage.makeupGain` — ×317 as it now stands, and ×190 when this
//  was written. The trim defaults to its maximum on purpose, so that the
//  phone's own volume control is the level control.) Two things make it self-sustaining rather than a one-off ring:
//  the soft clipper, which is what MANUFACTURES the >15 kHz harmonics once the
//  output is pinned, and the squelch gate, which the noise holds open by
//  looking like a detection (Niall's recording, 2026-09-10: a finger snap and
//  then four seconds of rising broadband hiss, +45 dB under 4 kHz and +32 dB
//  in 4–10 kHz, i.e. output sitting on the knee with the band above the
//  heterodyne low-pass full of clipper harmonics).
//
//  So this is a feedback stabiliser, not a limiter. It watches the level that
//  actually leaves the output stage and, when that level stays up for longer
//  than any bat pass does, pulls the output down hard and then brings it back
//  to a CEILING that is 6 dB below wherever the howl started. Each trip lowers
//  the ceiling again, so the gain converges on the loudest setting this phone,
//  in this position, at this volume can hold — instead of pumping between
//  silence and hiss. The ceiling climbs back on its own once the trips stop.
//
//  Armed only on the built-in speaker (`AudioEngineController.isOutputOnSpeaker`).
//  Through headphones there is no acoustic loop, and a long steady tone there
//  is a real signal that must not be ducked.
//
//  Threading: `process` runs on the realtime output thread and owns all the
//  state below it; `armed` is set from the main thread and `gainDB`/`isSuppressing`
//  are read from it, all through atomics. No locks, no allocation.
//

import Foundation
import Synchronization

nonisolated final class HowlGuard: @unchecked Sendable {

    // MARK: Tuning (hardcoded on purpose — see the note at the bottom)

    /// Output level that counts as "loud" for the sustain timer. The soft knee
    /// is at 0.7, so this is roughly 9 dB below where the clipper — the thing
    /// that closes the loop — starts working.
    static let triggerLevel: Float = 0.25
    /// How long the output has to stay above `triggerLevel` before this is a
    /// howl rather than a bat. A search-phase call is ~5–20 ms and even a
    /// feeding buzz is modulated; nothing in the live channel holds this level
    /// continuously for a third of a second except the loop.
    static let triggerSeconds: Float = 0.35
    /// Below this the output counts as quiet again and the sustain timer unwinds.
    static let releaseLevel: Float = 0.08
    /// How far down a trip pulls the output. Not zero: silence hides that
    /// anything is still being heard at all.
    static let floorGain: Float = 0.05
    /// Fast down (a howl doubles in level in tens of milliseconds), slow up.
    static let attackDBPerSecond: Float = 60
    static let recoverDBPerSecond: Float = 6
    /// Quiet time at the floor before the recovery ramp starts.
    static let holdSeconds: Float = 0.3
    /// What a trip does to the ceiling, and the lowest it may be driven to.
    static let ceilingDropPerTrip: Float = 0.5   // −6 dB
    static let minCeiling: Float = 0.08          // −22 dB
    /// Trip-free time before the ceiling starts climbing back, and how fast.
    static let ceilingHoldSeconds: Float = 20
    static let ceilingRecoverDBPerSecond: Float = 1
    /// Envelope follower time constant (one-pole on |x|).
    static let envelopeSeconds: Float = 0.02

    /// Where the output is band-limited on the speaker route, and how steeply.
    ///
    /// This is the other half of the fix, and the more fundamental one: the
    /// listening band starts at 15 kHz, so if nothing above ~8 kHz ever leaves
    /// the speaker, the app cannot hear its own output at all except through
    /// the speaker's own acoustic distortion. Four cascaded sections put 15 kHz
    /// about 44 dB down and 20 kHz about 63 dB down, which removes most of the
    /// electrical path rather than merely turning it down.
    ///
    /// It costs nothing on heterodyne, whose output is low-passed to 4 kHz
    /// anyway. It costs the 8x replay channel its top end — a 64 kHz call lands
    /// at 8 kHz — which is why it is armed with the guard rather than always on:
    /// through headphones there is no loop and the replay keeps its full band.
    /// 8 kHz whenever the slow replay can be heard, because that channel's
    /// content really does run that high. Heterodyne alone is low-passed to
    /// 4 kHz before it ever gets here, so on that mode everything above 5 kHz
    /// leaving the speaker is clipper harmonics and nothing else — and the mic
    /// records them: in the 2026-09-10 field capture, 4–10 kHz came back off the
    /// speaker at the same level as 1–4 kHz, under every single call.
    static let bandLimitHz: Double = 8_000
    static let bandLimitHeterodyneHz: Double = 5_000
    static let bandLimitSections = 4

    // MARK: Cross-thread

    private let armedA = Atomic<Bool>(false)
    private let suppressingA = Atomic<Bool>(false)
    /// Current attenuation in tenths of a dB (0 = no attenuation), for the UI
    /// and the tuning overlay. Integer so it fits an `Atomic`.
    private let gainTenthDBA = Atomic<Int>(0)
    /// Trips since the last `reset` — the number worth watching in the field.
    private let tripCountA = Atomic<Int>(0)

    /// Arm on the built-in speaker, disarm on headphones/Bluetooth/AirPlay.
    /// Disarming does not jump the gain back: `process` ramps it up like any
    /// other recovery, so unplugging headphones can't click.
    func setArmed(_ armed: Bool) { armedA.store(armed, ordering: .releasing) }
    var isArmed: Bool { armedA.load(ordering: .acquiring) }

    /// True while the guard is holding the output down. The auto-tuner reads
    /// this so the LO doesn't spend the runaway chasing the hiss and come back
    /// parked on it.
    var isSuppressing: Bool { suppressingA.load(ordering: .acquiring) }

    /// Attenuation currently applied, in dB (≤ 0).
    var attenuationDB: Float { Float(gainTenthDBA.load(ordering: .relaxed)) / 10 }

    /// How many times the guard has caught a runaway this capture.
    var tripCount: Int { tripCountA.load(ordering: .relaxed) }

    // MARK: Output-thread state

    private var sampleRate: Float = 48_000
    private var envCoef: Float = 0
    private var env: Float = 0
    private var sustained: Float = 0     // seconds above `triggerLevel`
    private var quiet: Float = 0         // seconds below `releaseLevel` while suppressing
    private var sinceTrip: Float = .greatestFiniteMagnitude
    private var gain: Float = 1
    private var ceiling: Float = 1
    private var suppressing = false
    private var bandLimit = [Biquad](repeating: Biquad(), count: HowlGuard.bandLimitSections)
    /// Ramped rather than switched, so plugging headphones in doesn't step the
    /// tone of the output mid-buffer.
    private var bandLimitMix: Float = 0
    private var appliedCutoff: Double = 0

    /// Call before the output node starts (no concurrent `process`).
    func reset(sampleRate: Double) {
        self.sampleRate = Float(sampleRate > 0 ? sampleRate : 48_000)
        envCoef = 1 - exp(-1 / (Self.envelopeSeconds * self.sampleRate))
        env = 0
        sustained = 0
        quiet = 0
        sinceTrip = .greatestFiniteMagnitude
        gain = 1
        ceiling = 1
        suppressing = false
        suppressingA.store(false, ordering: .releasing)
        gainTenthDBA.store(0, ordering: .relaxed)
        tripCountA.store(0, ordering: .relaxed)
        for i in bandLimit.indices {
            bandLimit[i] = .lowpass(cutoff: Self.bandLimitHz, sampleRate: Double(self.sampleRate))
        }
        appliedCutoff = Self.bandLimitHz
        bandLimitMix = armedA.load(ordering: .acquiring) ? 1 : 0
    }

    /// Strip everything the listening band could hear back, AFTER the soft
    /// clipper — the clipper is what creates those harmonics, so filtering
    /// ahead of it would only filter what it is about to recreate. Armed with
    /// the guard: speaker route only. See `bandLimitHz`.
    func bandLimitOutput(_ out: UnsafeMutablePointer<Float>, frames: Int,
                         cutoffHz: Double = HowlGuard.bandLimitHz) {
        let target: Float = armedA.load(ordering: .acquiring) ? 1 : 0
        // Recoefficiented in place on a mode change, keeping the filter state.
        // A listen-mode switch is already an audible event (the replay ducks,
        // the gate re-arms), so the small transient that costs is invisible
        // next to it, and it saves carrying two cascades and a crossfade.
        if cutoffHz != appliedCutoff {
            appliedCutoff = cutoffHz
            for i in bandLimit.indices {
                let b = Biquad.lowpass(cutoff: cutoffHz, sampleRate: Double(sampleRate))
                bandLimit[i].b0 = b.b0; bandLimit[i].b1 = b.b1; bandLimit[i].b2 = b.b2
                bandLimit[i].a1 = b.a1; bandLimit[i].a2 = b.a2
            }
        }
        // ~20 ms crossfade between filtered and unfiltered at 48 kHz.
        let step = 1 / (sampleRate * 0.02)
        if bandLimitMix == 0, target == 0 { return }
        for i in 0..<frames {
            var y = out[i]
            for s in bandLimit.indices { y = bandLimit[s].process(y) }
            if bandLimitMix < target { bandLimitMix = min(target, bandLimitMix + step) }
            else if bandLimitMix > target { bandLimitMix = max(target, bandLimitMix - step) }
            out[i] += (y - out[i]) * bandLimitMix
        }
    }

    /// Scale `out` in place by the current guard gain, tracking the level that
    /// results. Runs after the makeup gain and BEFORE the soft clipper, because
    /// the clipper is what generates the harmonics that close the loop —
    /// attenuating downstream of it would leave those harmonics in the signal.
    func process(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        let dt = 1 / sampleRate
        let armed = armedA.load(ordering: .acquiring)
        // Per-sample ramp steps from the dB/s rates (10^(dB/20) per second).
        let attackStep = exp(-Self.attackDBPerSecond * dt * 0.11512925)   // ln(10)/20
        let recoverStep = exp(Self.recoverDBPerSecond * dt * 0.11512925)
        let ceilingStep = exp(Self.ceilingRecoverDBPerSecond * dt * 0.11512925)

        for i in 0..<frames {
            let y = out[i] * gain
            out[i] = y

            let mag = abs(y)
            env += (mag - env) * envCoef

            if armed {
                if env > Self.triggerLevel { sustained += dt }
                else if env < Self.releaseLevel { sustained = max(0, sustained - dt) }

                if !suppressing, sustained >= Self.triggerSeconds {
                    // Latch. The gain we were at when the loop ran away is the
                    // most this route can carry, so cap below it.
                    suppressing = true
                    sustained = 0
                    quiet = 0
                    sinceTrip = 0
                    ceiling = max(Self.minCeiling, min(ceiling, gain * Self.ceilingDropPerTrip))
                    tripCountA.wrappingAdd(1, ordering: .relaxed)
                    suppressingA.store(true, ordering: .releasing)
                }
            } else if suppressing {
                // Disarmed mid-trip (headphones went in): stop holding down.
                suppressing = false
                suppressingA.store(false, ordering: .releasing)
                sustained = 0
            }

            if suppressing {
                gain = max(Self.floorGain, gain * attackStep)
                if env < Self.releaseLevel {
                    quiet += dt
                    if quiet >= Self.holdSeconds, gain <= Self.floorGain * 1.001 {
                        suppressing = false
                        suppressingA.store(false, ordering: .releasing)
                    }
                } else {
                    quiet = 0
                }
            } else {
                let target = armed ? ceiling : 1
                if gain < target { gain = min(target, gain * recoverStep) }
                else if gain > target { gain = max(target, gain * attackStep) }
            }

            // The ceiling itself climbs back once the trips stop, so a one-off
            // (a snap, someone's keys) doesn't cost the rest of the night's
            // loudness.
            if sinceTrip < Self.ceilingHoldSeconds {
                sinceTrip += dt
            } else if ceiling < 1 {
                ceiling = min(1, ceiling * ceilingStep)
            }
        }

        gainTenthDBA.store(Int(20 * log10(max(gain, 1e-4)) * 10), ordering: .relaxed)
    }
}

// Hardcoded rather than `Tunable`-backed: every number here is a property of
// the loop (how long a bat pass lasts, where the clipper is, how fast a howl
// grows), not a matter of taste, and a feedback stabiliser with a knob on it is
// a feedback stabiliser someone turns off in the field and then reports as
// "the hiss is back".
