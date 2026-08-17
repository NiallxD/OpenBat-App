//
//  PulseHaptics.swift
//  OpenBat
//
//  Renders each detected bat pulse as a haptic event, so a pass can be FELT —
//  its presence, its strength, roughly its frequency band, and whether it has
//  turned into a feeding buzz.
//
//  This is an accessibility channel first. For a deaf or hard-of-hearing user it
//  is not a supplement to heterodyne, it is the substitute for it, and that
//  drives three decisions that would otherwise look over-careful:
//
//    * Every way this can silently stop working is surfaced through
//      `unavailableReason` rather than left to fail quietly. Low Power Mode
//      disables Core Haptics outright — without a message that reads exactly
//      like "the bats stopped", which is the worst possible failure here.
//    * The two modes are behavioural rather than decorative. A feeding buzz is
//      the event a bat worker most wants to notice, and it has to feel like a
//      different *thing*, not merely like faster ticking.
//    * It runs off `PulseDetector` alone. No listening mode has to be active,
//      and it works identically in demo mode and while backgrounded (both feed
//      the same detector — see `SpectrogramRenderer` and
//      `BackgroundDetectionPump`).
//
//  === What the Taptic Engine can and cannot do ===
//  It is a resonant actuator with a fixed resonance (~150–230 Hz), so it has NO
//  pitch dimension. Call frequency cannot be reproduced at any scale, expanded
//  or otherwise. Core Haptics exposes two axes, and they carry one call property
//  each:
//
//      intensity  <-  pulse energy     "how close is it"
//      sharpness  <-  peak frequency   "what kind is it" — dull thud to crisp tick
//
//  Frequency deliberately does NOT drive intensity. That would spend the only
//  proximity cue on something sharpness carries natively, and leave a distant
//  high call and a close low one feeling identical.
//
//  === Rate is a hard physical budget, not a performance concern ===
//  The actuator needs ~30–50 ms between transients to be felt as two events; a
//  feeding buzz runs 100–200 pulses/s. Rendering one tap per pulse there is not
//  expensive, it is impossible — the same kind of limit that makes the Live
//  Activity a budgeted message channel rather than a display (Context.md §12).
//  So above `buzzEnterHz` this collapses to ONE continuous haptic whose
//  intensity follows the pulse rate. That is also simply what a buzz should feel
//  like: the channel does what the ear already does.
//
//  === Driven by detector metadata, never by audio samples ===
//  Intensity and sharpness are computed from `peakLevel` and `peakFrequency` —
//  derived parameters, not the recorded waveform. Resampling the call itself and
//  pushing it through the haptic engine at a slower rate would be a different
//  thing entirely, and would want reading against Context.md §5 first. This
//  never touches a sample, which is both cleaner on that question and simpler.
//

import CoreHaptics
import Foundation
import Observation
import UIKit   // UIApplication.didBecomeActiveNotification — see `activate()`

@MainActor
@Observable
final class PulseHaptics {

    // MARK: Settings (persisted)

    /// Off by default: it costs battery across a night, and a hearing user who
    /// doesn't want it should never have to discover why their phone is
    /// buzzing in their pocket.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Key.enabled)
            isEnabled ? startEngine() : stopEngine()
        }
    }

    /// Global strength trim, 0.25–1.5. Applied on top of the energy mapping, so
    /// it scales what the bat is doing rather than flattening it.
    var strength: Double {
        didSet { UserDefaults.standard.set(strength, forKey: Key.strength) }
    }

    private enum Key {
        static let enabled = "haptics.pulseEnabled"
        static let strength = "haptics.strength"
        static let levelFloor = "haptics.levelFloor"
        static let levelCeiling = "haptics.levelCeiling"
        static let minIntensity = "haptics.minIntensity"
        static let freqFloor = "haptics.freqFloor"
        static let freqCeiling = "haptics.freqCeiling"
        static let buzzEnter = "haptics.buzzEnter"
        static let buzzExit = "haptics.buzzExit"
        static let rateWindow = "haptics.rateWindow"
        static let buzzHangover = "haptics.buzzHangover"
        static let minTapInterval = "haptics.minTapInterval"
    }

    // MARK: Availability

    /// Hardware check. False on iPad and anything without a Taptic Engine — the
    /// settings row hides itself rather than offering a control that does
    /// nothing.
    let isSupported: Bool

    /// Mirrored from `ProcessInfo` and kept current by a notification, because
    /// Low Power Mode disables Core Haptics **completely and silently**. On a
    /// long night session the phone will reach it, and without this the feature
    /// simply stops with no explanation.
    private(set) var isLowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled

    /// Set when the engine itself failed (rare, but it can refuse to start).
    private(set) var engineFailure: String?

    /// Nil when haptics will actually fire. Otherwise a sentence to show the
    /// user, written to be actionable rather than diagnostic.
    var unavailableReason: String? {
        if !isSupported { return "This device doesn't have a Taptic Engine." }
        if isLowPowerMode {
            return "Low Power Mode switches off all vibration, so pulse haptics "
                 + "won't fire until you turn it off in Settings › Battery."
        }
        if let engineFailure { return engineFailure }
        return nil
    }

    // MARK: Tunables
    //
    // All live, all persisted, all editable from the overlay's Haptics tab while
    // the detector runs (see `HapticsTuningTab`). The defaults below are
    // engineering estimates, NOT measurements — they were reasoned from the
    // actuator's limits and `amplitudeThreshold`'s 0.5 default, and want
    // checking by hand against the demo clip on a real device.

    /// Peak level that maps to the weakest tap. `peakLevel` is the detector's
    /// normalised 0–1 column magnitude (the same scale as spectrogram
    /// brightness). Raise it if distant calls feel too strong; lower it if they
    /// vanish. The most likely of these to be wrong.
    var levelFloor: Float {
        didSet { UserDefaults.standard.set(levelFloor, forKey: Key.levelFloor) }
    }
    /// Peak level that maps to a full-strength tap. Lower it if everything pins
    /// to maximum and close and distant bats feel identical.
    var levelCeiling: Float {
        didSet { UserDefaults.standard.set(levelCeiling, forKey: Key.levelCeiling) }
    }
    /// Intensity given to a call sitting right on `levelFloor`. Not zero: a
    /// barely-detected bat still has to be felt, or a distant one reads as no
    /// bat at all.
    var minIntensity: Float {
        didSet { UserDefaults.standard.set(minIntensity, forKey: Key.minIntensity) }
    }

    /// Peak frequency mapping onto sharpness. The default 18–65 kHz spans the
    /// species that actually occur: Nyctalus ~20 kHz at the dull end, Myotis and
    /// Pipistrellus 40–55 kHz at the crisp end. Narrow the span to exaggerate
    /// the difference between species; widen it to calm it down. Clamped, so
    /// nothing outside ever falls silent.
    var freqFloorHz: Double {
        didSet { UserDefaults.standard.set(freqFloorHz, forKey: Key.freqFloor) }
    }
    var freqCeilingHz: Double {
        didSet { UserDefaults.standard.set(freqCeilingHz, forKey: Key.freqCeiling) }
    }

    // MARK: Rate gate — the call/buzz transition

    /// A buzz ends when the pulses stop, not when the rate calculation decays.
    var buzzHangover: TimeInterval {
        didSet { UserDefaults.standard.set(buzzHangover, forKey: Key.buzzHangover) }
    }

    /// Minimum spacing between discrete taps. Below roughly 30–50 ms the
    /// actuator cannot resolve two events, so extra taps only smear the
    /// envelope — a hardware limit being respected, not a preference.
    var minTapInterval: TimeInterval {
        didSet { UserDefaults.standard.set(minTapInterval, forKey: Key.minTapInterval) }
    }

    /// Pulse rate at which taps collapse into one continuous buzz.
    ///
    /// Setting it is a judgement about what counts as a buzz rather than a fast
    /// sequence. Too low and ordinary close-approach calls turn into a buzz that
    /// never resolves into individual bats; too high and a real feeding buzz
    /// arrives as a rattle of taps the actuator cannot separate anyway.
    var buzzEnterHz: Double {
        didSet {
            UserDefaults.standard.set(buzzEnterHz, forKey: Key.buzzEnter)
            if buzzExitHz >= buzzEnterHz { buzzExitHz = max(1, buzzEnterHz - 1) }
        }
    }

    /// Rate at which the buzz breaks back into taps. Held strictly below
    /// `buzzEnterHz`: a single threshold flips modes several times a second.
    var buzzExitHz: Double {
        didSet {
            if buzzExitHz >= buzzEnterHz { buzzExitHz = max(1, buzzEnterHz - 1) }
            UserDefaults.standard.set(buzzExitHz, forKey: Key.buzzExit)
        }
    }

    /// How long pulse rate is averaged over before comparing to the thresholds.
    /// Short reacts fast and jitters; long is steady but late.
    var rateWindow: TimeInterval {
        didSet { UserDefaults.standard.set(rateWindow, forKey: Key.rateWindow) }
    }

    /// Core Haptics caps a continuous event at 30 s; a buzz never approaches
    /// that. Not tunable.
    private static let buzzEventDuration: TimeInterval = 20

    // MARK: Defaults

    static let defaultLevelFloor: Float = 0.45
    static let defaultLevelCeiling: Float = 0.95
    static let defaultMinIntensity: Float = 0.35
    static let defaultFreqFloorHz: Double = 18_000
    static let defaultFreqCeilingHz: Double = 65_000
    static let defaultBuzzEnterHz: Double = 12
    static let defaultBuzzExitHz: Double = 8
    static let defaultRateWindow: TimeInterval = 0.4
    static let defaultBuzzHangover: TimeInterval = 0.25
    static let defaultMinTapInterval: TimeInterval = 0.045
    static let defaultStrength: Double = 1.0

    func resetToDefaults() {
        strength = Self.defaultStrength
        levelFloor = Self.defaultLevelFloor
        levelCeiling = Self.defaultLevelCeiling
        minIntensity = Self.defaultMinIntensity
        freqFloorHz = Self.defaultFreqFloorHz
        freqCeilingHz = Self.defaultFreqCeilingHz
        buzzEnterHz = Self.defaultBuzzEnterHz
        buzzExitHz = Self.defaultBuzzExitHz
        rateWindow = Self.defaultRateWindow
        buzzHangover = Self.defaultBuzzHangover
        minTapInterval = Self.defaultMinTapInterval
    }

    // MARK: Engine

    private var engine: CHHapticEngine?
    private var buzzPlayer: CHHapticAdvancedPatternPlayer?
    private var isBuzzing = false
    private var recentPulses: [TimeInterval] = []
    private var lastTapAt: TimeInterval = 0
    private var lastBuzzUpdateAt: TimeInterval = 0
    private var lastPulseAt: TimeInterval = 0
    private var buzzWatchdog: Timer?

    /// Live readouts for the settings screen and the tuning tab, so a user can
    /// confirm the feature is doing something without needing a bat.
    private(set) var eventCount = 0
    private(set) var isInBuzzMode = false

    /// Pulse rate over the last `rateWindow`, evaluated at read time.
    ///
    /// Deliberately computed rather than cached: `recentPulses` is only trimmed
    /// when a pulse arrives, so a cached value would freeze at the last rate
    /// when the bat stopped — which is exactly when the tuning tab's trace needs
    /// to show it falling back through the thresholds.
    var currentRateHz: Double {
        let now = CFAbsoluteTimeGetCurrent()
        let live = recentPulses.reduce(into: 0) { n, t in
            if now - t <= rateWindow { n += 1 }
        }
        return Double(live) / rateWindow
    }

    init() {
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        let d = UserDefaults.standard
        isEnabled = d.bool(forKey: Key.enabled)
        func f(_ k: String, _ fallback: Float) -> Float {
            d.object(forKey: k) != nil ? d.float(forKey: k) : fallback
        }
        func v(_ k: String, _ fallback: Double) -> Double {
            d.object(forKey: k) != nil ? d.double(forKey: k) : fallback
        }
        strength = v(Key.strength, Self.defaultStrength)
        levelFloor = f(Key.levelFloor, Self.defaultLevelFloor)
        levelCeiling = f(Key.levelCeiling, Self.defaultLevelCeiling)
        minIntensity = f(Key.minIntensity, Self.defaultMinIntensity)
        freqFloorHz = v(Key.freqFloor, Self.defaultFreqFloorHz)
        freqCeilingHz = v(Key.freqCeiling, Self.defaultFreqCeilingHz)
        buzzEnterHz = v(Key.buzzEnter, Self.defaultBuzzEnterHz)
        buzzExitHz = v(Key.buzzExit, Self.defaultBuzzExitHz)
        rateWindow = v(Key.rateWindow, Self.defaultRateWindow)
        buzzHangover = v(Key.buzzHangover, Self.defaultBuzzHangover)
        minTapInterval = v(Key.minTapInterval, Self.defaultMinTapInterval)

        // NOTHING with a cost or a side effect here — no observers, no engine.
        // This type is built as a SwiftUI `@State` default expression, which
        // SwiftUI may evaluate any number of times per view identity, keeping
        // the first result and discarding the rest. Registering observers here
        // leaked one per evaluation (the notification center retains the block
        // itself, so they outlive the object that made them), and starting a
        // CHHapticEngine here started one per evaluation too — several engines
        // contending for one actuator, all but one of them owned by an object
        // already thrown away. Setup lives in `activate()` now, called once
        // from the owning view. This is the same rule, and the same failure,
        // AudioEngineController documents — see Context.md §6.
    }

    private var isActivated = false

    /// Registers the power-state observer and starts the engine if the feature
    /// is on. Call once, from the owning view's `.onAppear`/`.task` — never from
    /// an initializer, for the reason `init` gives. Idempotent.
    func activate() {
        guard !isActivated else { return }
        isActivated = true

        cleanup.tokens.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                // Leaving Low Power Mode does not restart Core Haptics by
                // itself: the engine was stopped (or refused to start) while it
                // was on, and without this the feature stayed dead for the rest
                // of the run even though `unavailableReason` had gone back to
                // nil — the settings screen said it was working and it was not.
                if !self.isLowPowerMode, self.isEnabled { self.startEngine() }
            }
        })

        // iOS stops an app's haptic engine when the app is backgrounded, and
        // `stoppedHandler` is not guaranteed to have run by the time the first
        // pulse of the next pass arrives. Restarting on foreground is cheap
        // (`startEngine` returns immediately when an engine already exists) and
        // removes a whole class of "it stopped buzzing at some point tonight".
        cleanup.tokens.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled else { return }
                self.startEngine()
            }
        })

        if isEnabled { startEngine() }
    }

    /// Observer tokens, parked in a separate object for the same reason
    /// `AudioEngineController.Cleanup` exists: `deinit` on a `@MainActor` class
    /// is nonisolated and cannot touch this object's isolated stored properties,
    /// and the notification center retains a block-based observer until it is
    /// explicitly removed.
    private final class Cleanup: @unchecked Sendable {
        var tokens: [any NSObjectProtocol] = []
        deinit {
            let tokens = self.tokens
            DispatchQueue.main.async {
                tokens.forEach { NotificationCenter.default.removeObserver($0) }
            }
        }
    }
    private let cleanup = Cleanup()

    // MARK: Engine lifecycle

    private func startEngine() {
        guard isSupported, engine == nil else { return }
        do {
            let e = try CHHapticEngine()
            // The capture session owns the audio route (`.playAndRecord` with a
            // USB mic). Haptics-only keeps this engine off it entirely.
            e.playsHapticsOnly = true
            // Auto-shutdown would save a little power, but restarting costs tens
            // of ms and the cost lands on the FIRST pulse of a pass — the one
            // that matters most. Held open instead, and stopped outright when
            // the feature is switched off.
            e.isAutoShutdownEnabled = false
            // Both handlers are invoked by Core Haptics on an unspecified queue,
            // so they hop to the main actor rather than asserting they are on it.
            //
            // Neither restarts the engine. A stop can be caused by the very
            // thing that would cause the next one (an interruption that is still
            // in progress), and an eager restart there spins. `ensureEngine`
            // rebuilds on the next pulse instead — synchronously, so the pulse
            // that triggers the rebuild is still rendered.
            e.stoppedHandler = { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.engine = nil
                    self.discardBuzzState()
                }
            }
            e.resetHandler = { [weak self] in
                Task { @MainActor in
                    guard let self, self.isEnabled else { return }
                    self.discardBuzzState()
                    try? self.engine?.start()
                }
            }
            try e.start()
            engine = e
            engineFailure = nil
        } catch {
            engine = nil
            engineFailure = "Haptics couldn't start on this device."
        }
    }

    /// Drop player state without touching the engine — the players are invalid
    /// after a stop or reset, but the settings and counters are not.
    private func discardBuzzState() {
        buzzWatchdog?.invalidate()
        buzzWatchdog = nil
        buzzPlayer = nil
        isBuzzing = false
        isInBuzzMode = false
    }

    /// The engine, starting it first if it went away. Synchronous, so a pulse
    /// arriving just after an interruption still lands.
    private func ensureEngine() -> CHHapticEngine? {
        if engine == nil, isEnabled, isSupported { startEngine() }
        return engine
    }

    private func stopEngine() {
        endBuzz()
        engine?.stop()
        engine = nil
        recentPulses.removeAll()
        eventCount = 0
    }

    // MARK: Input

    /// Called from `PulseDetector.onPulseStart` on the main thread, at the
    /// rising edge of every pulse run.
    ///
    /// One tap per run, which is one tap per call. Deliberately NOT fed from the
    /// re-onsets inside a run: those fire when an FM call's level dips below
    /// threshold mid-sweep, and counting them inflated the live pulse rate from
    /// ~2/s to ~14/s. Measured on the demo clip, 70 of 71 re-onsets showed no
    /// frequency change at all — a real new call restarts at the top of its
    /// sweep and jumps up, so those were fragments of one call. Don't add them.
    func pulse(frequency: Double, level: Float) {
        guard isEnabled, isSupported, !isLowPowerMode,
              let engine = ensureEngine() else { return }

        let now = CFAbsoluteTimeGetCurrent()
        lastPulseAt = now
        recentPulses.append(now)
        recentPulses.removeAll { now - $0 > rateWindow }
        let rate = Double(recentPulses.count) / rateWindow

        let intensity = intensityFor(level)
        let sharpness = sharpnessFor(frequency)

        if isBuzzing {
            if rate < buzzExitHz {
                endBuzz()
                playTap(intensity: intensity, sharpness: sharpness, at: now, engine: engine)
            } else {
                updateBuzz(intensity: intensity, sharpness: sharpness)
            }
        } else if rate >= buzzEnterHz {
            beginBuzz(intensity: intensity, sharpness: sharpness, engine: engine)
        } else {
            playTap(intensity: intensity, sharpness: sharpness, at: now, engine: engine)
        }
    }

    /// Play a short representative sequence: three calls of rising strength and
    /// pitch, then a feeding buzz.
    ///
    /// Not a gimmick. A user who cannot hear the detector has no other way to
    /// learn what the two modes feel like, or to set `strength` against anything
    /// — waiting for a real bat to calibrate against is not a reasonable ask.
    /// The buzz is started directly rather than by feeding fake pulses, since
    /// the real trigger is a sustained pulse rate this can't fabricate.
    func playPreview() {
        guard isEnabled, isSupported, !isLowPowerMode,
              ensureEngine() != nil else { return }
        reset()

        // Three search-phase calls, spaced well clear of `minTapInterval` so
        // they read as separate events: quiet/low, mid, loud/high.
        let taps: [(TimeInterval, Float, Float)] = [
            (0.00, 0.40, 0.15),
            (0.35, 0.65, 0.50),
            (0.70, 1.00, 0.95),
        ]
        for (at, level, sharp) in taps {
            let scaled = min(max(level * Float(strength), 0), 1)
            Timer.scheduledTimer(withTimeInterval: at + 0.01, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let engine = self.ensureEngine() else { return }
                    self.playTap(intensity: scaled, sharpness: sharp,
                                 at: CFAbsoluteTimeGetCurrent(), engine: engine)
                }
            }
        }
        // Then the buzz, so the contrast between the two modes is the thing the
        // preview actually teaches.
        Timer.scheduledTimer(withTimeInterval: 1.15, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, let engine = self.ensureEngine() else { return }
                self.beginBuzz(intensity: min(Float(0.85 * self.strength), 1),
                               sharpness: 0.7, engine: engine)
                Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { _ in
                    Task { @MainActor in self.endBuzz() }
                }
            }
        }
    }

    /// Drop rate history so a new session doesn't inherit the last one's tail.
    func reset() {
        endBuzz()
        recentPulses.removeAll()
        eventCount = 0
    }

    // MARK: Mapping

    private func intensityFor(_ level: Float) -> Float {
        let span = levelCeiling - levelFloor
        let t = min(max((level - levelFloor) / span, 0), 1)
        let base = minIntensity + t * (1 - minIntensity)
        return min(max(base * Float(strength), 0), 1)
    }

    private func sharpnessFor(_ frequency: Double) -> Float {
        let span = freqCeilingHz - freqFloorHz
        let t = (frequency - freqFloorHz) / span
        return Float(min(max(t, 0), 1))
    }

    // MARK: Rendering

    private func playTap(intensity: Float, sharpness: Float,
                         at now: TimeInterval, engine: CHHapticEngine) {
        guard now - lastTapAt >= minTapInterval else { return }
        lastTapAt = now
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0)
        do {
            // A player per tap. Wasteful in principle, but capped at ~22/s by
            // `minTapInterval` and it is what keeps each tap's parameters
            // independent — a reused player would need a dynamic-parameter
            // round trip per pulse for no gain.
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
            eventCount += 1
        } catch {
            // A failed tap is not worth surfacing — the next one is milliseconds
            // away, and an error banner mid-pass would be worse than a gap.
        }
    }

    private func beginBuzz(intensity: Float, sharpness: Float, engine: CHHapticEngine) {
        let event = CHHapticEvent(
            eventType: .hapticContinuous,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0,
            duration: Self.buzzEventDuration)
        do {
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            let player = try engine.makeAdvancedPlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
            buzzPlayer = player
            isBuzzing = true
            isInBuzzMode = true
            eventCount += 1
            startBuzzWatchdog()
        } catch {
            isBuzzing = false
            isInBuzzMode = false
        }
    }

    /// Throttled to 60 Hz. The actuator cannot follow an envelope faster than
    /// that, so forwarding every pulse to the haptic engine would be pure
    /// traffic.
    private static let buzzUpdateInterval: TimeInterval = 1.0 / 60

    private func updateBuzz(intensity: Float, sharpness: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastBuzzUpdateAt >= Self.buzzUpdateInterval else { return }
        lastBuzzUpdateAt = now
        try? buzzPlayer?.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                     value: intensity, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl,
                                     value: sharpness, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
    }

    private func endBuzz() {
        buzzWatchdog?.invalidate()
        buzzWatchdog = nil
        try? buzzPlayer?.stop(atTime: CHHapticTimeImmediate)
        buzzPlayer = nil
        isBuzzing = false
        isInBuzzMode = false
    }

    /// A buzz ends because the bat stopped, and that arrives as the *absence* of
    /// pulses — nothing calls back to say so. Without this the actuator would
    /// keep running to `buzzEventDuration`.
    private func startBuzzWatchdog() {
        buzzWatchdog?.invalidate()
        buzzWatchdog = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isBuzzing else { return }
                if CFAbsoluteTimeGetCurrent() - self.lastPulseAt > self.buzzHangover {
                    self.endBuzz()
                }
            }
        }
    }
}
