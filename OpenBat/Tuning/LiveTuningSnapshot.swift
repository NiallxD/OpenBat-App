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

    // Adaptive time expansion
    var ateGain: Float
    var ateThresholdDB: Double
    var ateReleaseDB: Double
    var ateHangoverMs: Double
    var ateMaxBufferMs: Double
    var atePreRollMs: Double
    var atePostRollMs: Double
    var ateRampMs: Double
    var ateExpanderEnabled: Bool
    var ateExpanderThresholdDB: Double
    var ateExpanderDepthDB: Double
    var ateExpanderReleaseMs: Double
    var ateSamplerEnabled: Bool
    var ateSamplerIntervalSeconds: Double
    var ateSamplerScanMs: Double
    var ateSamplerEdgeFraction: Double

    // Variable Time Distortion. Read straight off the processor: unlike ATE there is
    // no settings object behind these yet, so the processor IS the source of
    // truth and Revert has to put them back there.
    var vtdGain: Float
    var vtdGapRate: Double
    var vtdRateMax: Double
    var vtdLookaheadMs: Double
    var vtdCatchupAfterMs: Double
    var vtdDuckAlpha: Double
    var vtdTransitionMs: Double
    var vtdHighCutHz: Double

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
                        ate: AdaptiveTimeExpansionSettings,
                        pulse: PulseDetector,
                        bandLow: Double,
                        bandHigh: Double,
                        timeWindowSeconds: Double) -> LiveTuningSnapshot {
        LiveTuningSnapshot(
            heterodyneGain: audio.heterodyne.gain,
            audibleOffsetHz: audio.audibleOffsetHz,
            ateGain: ate.gain,
            ateThresholdDB: ate.thresholdDB,
            ateReleaseDB: ate.releaseDB,
            ateHangoverMs: ate.hangoverMs,
            ateMaxBufferMs: ate.maxBufferMs,
            atePreRollMs: ate.preRollMs,
            atePostRollMs: ate.postRollMs,
            ateRampMs: ate.rampMs,
            ateExpanderEnabled: ate.expanderEnabled,
            ateExpanderThresholdDB: ate.expanderThresholdDB,
            ateExpanderDepthDB: ate.expanderDepthDB,
            ateExpanderReleaseMs: ate.expanderReleaseMs,
            ateSamplerEnabled: ate.samplerEnabled,
            ateSamplerIntervalSeconds: ate.samplerIntervalSeconds,
            ateSamplerScanMs: ate.samplerScanMs,
            ateSamplerEdgeFraction: ate.samplerEdgeFraction,
            vtdGain: audio.variableTimeDistortion.gain,
            vtdGapRate: audio.variableTimeDistortion.gapRate,
            vtdRateMax: audio.variableTimeDistortion.rateMax,
            vtdLookaheadMs: audio.variableTimeDistortion.lookaheadMs,
            vtdCatchupAfterMs: audio.variableTimeDistortion.catchupAfterMs,
            vtdDuckAlpha: audio.variableTimeDistortion.duckAlpha,
            vtdTransitionMs: audio.variableTimeDistortion.transitionMs,
            vtdHighCutHz: audio.variableTimeDistortion.highCutHz,
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

    /// Put everything back. The settings objects persist on `didSet` and the
    /// adaptive-TE group reaches the processor through ContentView's single
    /// `.onChange(of: adaptiveTESettings.snapshot)`, so restoring the settings
    /// object is enough for that group — but the heterodyne values live only on
    /// the processor, so those are written directly.
    func restore(audio: AudioEngineController,
                 ate: AdaptiveTimeExpansionSettings,
                 pulse: PulseDetector,
                 bandLow: inout Double,
                 bandHigh: inout Double,
                 timeWindowSeconds: inout Double) {
        audio.heterodyne.gain = heterodyneGain
        audio.audibleOffsetHz = audibleOffsetHz

        ate.gain = ateGain
        ate.thresholdDB = ateThresholdDB
        ate.releaseDB = ateReleaseDB
        ate.hangoverMs = ateHangoverMs
        ate.maxBufferMs = ateMaxBufferMs
        // Post-roll before ramp, for the clamp ordering reason documented in
        // `AdaptiveTimeExpansionSettings.apply(to:)`.
        ate.postRollMs = atePostRollMs
        ate.preRollMs = atePreRollMs
        ate.rampMs = ateRampMs
        ate.expanderEnabled = ateExpanderEnabled
        ate.expanderThresholdDB = ateExpanderThresholdDB
        ate.expanderDepthDB = ateExpanderDepthDB
        ate.expanderReleaseMs = ateExpanderReleaseMs
        ate.samplerEnabled = ateSamplerEnabled
        ate.samplerIntervalSeconds = ateSamplerIntervalSeconds
        ate.samplerScanMs = ateSamplerScanMs
        ate.samplerEdgeFraction = ateSamplerEdgeFraction

        audio.variableTimeDistortion.gain = vtdGain
        audio.variableTimeDistortion.gapRate = vtdGapRate
        audio.variableTimeDistortion.rateMax = vtdRateMax
        audio.variableTimeDistortion.lookaheadMs = vtdLookaheadMs
        audio.variableTimeDistortion.catchupAfterMs = vtdCatchupAfterMs
        audio.variableTimeDistortion.duckAlpha = vtdDuckAlpha
        audio.variableTimeDistortion.transitionMs = vtdTransitionMs
        audio.variableTimeDistortion.highCutHz = vtdHighCutHz

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
