//
//  LiveTuningSnapshot.swift
//  OpenBat
//
//  Everything the live tuning overlay can change, captured as one value so
//  Revert can put it all back. One flat struct rather than per-tab snapshots
//  is deliberate — a knob added to a tab and not added here fails silently
//  under Revert, so there is exactly one place to remember it. See
//  Context.md §13. Plain value type, not `@Observable`; no threading contract
//  of its own, since `capture`/`restore` both run on the main actor via the
//  main-actor-isolated objects they read and write.
//

import Foundation

/// A point-in-time copy of every tunable the live overlay exposes, taken on
/// open and put back by Revert.
struct LiveTuningSnapshot {

    // Heterodyne
    var heterodyneGain: Float
    var audibleOffsetHz: Double

    // Pulse haptics. Like the heterodyne knobs these live on the object itself
    // rather than behind a separate settings type, so Revert writes them back
    // there directly.
    var hapticStrength: Double
    var hapticLevelFloor: Float
    var hapticLevelCeiling: Float
    var hapticMinIntensity: Float
    var hapticFreqFloorHz: Double
    var hapticFreqCeilingHz: Double
    var hapticBuzzEnterHz: Double
    var hapticBuzzExitHz: Double
    var hapticRateWindow: TimeInterval
    var hapticBuzzHangover: TimeInterval
    var hapticMinTapInterval: TimeInterval

    // Pulse detector
    var amplitudeThreshold: Float
    var minFrequencyHz: Double
    var minConsecutiveColumns: Int
    var maxGapMs: Double
    var holdOffSeconds: Double
    var displayWindowMs: Double
    var pulseNoiseFloor: Float
    var spectrogramNoiseFloor: Float

    // Display
    var bandLow: Double
    var bandHigh: Double
    var timeWindowSeconds: Double

    /// Reads the current value of every tunable from its live source of truth.
    static func capture(audio: AudioEngineController,
                        pulse: PulseDetector,
                        haptics: PulseHaptics,
                        bandLow: Double,
                        bandHigh: Double,
                        timeWindowSeconds: Double) -> LiveTuningSnapshot {
        LiveTuningSnapshot(
            heterodyneGain: audio.heterodyne.gain,
            audibleOffsetHz: audio.audibleOffsetHz,
            hapticStrength: haptics.strength,
            hapticLevelFloor: haptics.levelFloor,
            hapticLevelCeiling: haptics.levelCeiling,
            hapticMinIntensity: haptics.minIntensity,
            hapticFreqFloorHz: haptics.freqFloorHz,
            hapticFreqCeilingHz: haptics.freqCeilingHz,
            hapticBuzzEnterHz: haptics.buzzEnterHz,
            hapticBuzzExitHz: haptics.buzzExitHz,
            hapticRateWindow: haptics.rateWindow,
            hapticBuzzHangover: haptics.buzzHangover,
            hapticMinTapInterval: haptics.minTapInterval,
            amplitudeThreshold: pulse.amplitudeThreshold,
            minFrequencyHz: pulse.minFrequencyHz,
            minConsecutiveColumns: pulse.minConsecutiveColumns,
            maxGapMs: pulse.maxGapMs,
            holdOffSeconds: pulse.holdOffSeconds,
            displayWindowMs: pulse.displayWindowMs,
            pulseNoiseFloor: pulse.pulseNoiseFloor,
            spectrogramNoiseFloor: pulse.spectrogramNoiseFloor,
            bandLow: bandLow,
            bandHigh: bandHigh,
            timeWindowSeconds: timeWindowSeconds
        )
    }

    /// Put everything back. Every value here lives on a processor or the pulse
    /// detector rather than behind a settings object, so each is written
    /// directly to its source of truth.
    func restore(audio: AudioEngineController,
                 pulse: PulseDetector,
                 haptics: PulseHaptics,
                 bandLow: inout Double,
                 bandHigh: inout Double,
                 timeWindowSeconds: inout Double) {
        audio.heterodyne.gain = heterodyneGain
        audio.audibleOffsetHz = audibleOffsetHz

        haptics.strength = hapticStrength
        haptics.levelFloor = hapticLevelFloor
        haptics.levelCeiling = hapticLevelCeiling
        haptics.minIntensity = hapticMinIntensity
        haptics.freqFloorHz = hapticFreqFloorHz
        haptics.freqCeilingHz = hapticFreqCeilingHz
        // Enter before exit: enter's didSet drags a too-high exit down with it.
        haptics.buzzEnterHz = hapticBuzzEnterHz
        haptics.buzzExitHz = hapticBuzzExitHz
        haptics.rateWindow = hapticRateWindow
        haptics.buzzHangover = hapticBuzzHangover
        haptics.minTapInterval = hapticMinTapInterval

        pulse.amplitudeThreshold = amplitudeThreshold
        pulse.minFrequencyHz = minFrequencyHz
        pulse.minConsecutiveColumns = minConsecutiveColumns
        pulse.maxGapMs = maxGapMs
        pulse.holdOffSeconds = holdOffSeconds
        pulse.displayWindowMs = displayWindowMs
        pulse.pulseNoiseFloor = pulseNoiseFloor
        pulse.spectrogramNoiseFloor = spectrogramNoiseFloor

        bandLow = self.bandLow
        bandHigh = self.bandHigh
        timeWindowSeconds = self.timeWindowSeconds
    }
}
