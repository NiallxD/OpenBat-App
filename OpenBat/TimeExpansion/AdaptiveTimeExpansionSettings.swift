//
//  AdaptiveTimeExpansionSettings.swift
//  OpenBat
//
//  Persisted settings for LIVE adaptive time expansion. Unlike
//  TimeExpansionSettings (which WavPlayerView owns locally, because file
//  playback has no live counterpart), this one is owned by ContentView and
//  applied to AudioEngineController's processor — it's a live listening mode
//  and shares the screen's frequency band.
//

import Foundation

@Observable
final class AdaptiveTimeExpansionSettings {

    /// Output makeup gain.
    var gain: Float {
        didSet { UserDefaults.standard.set(gain, forKey: Self.keyGain) }
    }

    /// The one real tuning knob — see `AdaptiveTimeExpansionProcessor.hangoverMs`
    /// for what moving it trades off.
    var hangoverMs: Double {
        didSet { UserDefaults.standard.set(hangoverMs, forKey: Self.keyHangover) }
    }

    /// Hard cap on event length. Exposed because the right value depends on how
    /// much deaf time the user will tolerate to hear a buzz in full, but the
    /// default is small on purpose (see the processor's doc comment).
    var maxBufferMs: Double {
        didSet { UserDefaults.standard.set(maxBufferMs, forKey: Self.keyMaxBuffer) }
    }

    /// Trigger sensitivity for OPENING an event, in dB above the tracked noise
    /// floor.
    var thresholdDB: Double {
        didSet { UserDefaults.standard.set(thresholdDB, forKey: Self.keyThreshold) }
    }

    /// Level needed to HOLD an open event open, in dB above the noise floor.
    /// Lower than `thresholdDB` on purpose — see the processor's `releaseDB`.
    /// This is the knob to reach for if call endings sound clipped.
    var releaseDB: Double {
        didSet { UserDefaults.standard.set(releaseDB, forKey: Self.keyRelease) }
    }

    /// Pre-roll ahead of the trigger. Exposed for the live tuning overlay: its
    /// relationship to `rampMs` is what decides whether call onsets arrive at
    /// full level — see the processor's `preRollMs`.
    var preRollMs: Double {
        didSet { UserDefaults.standard.set(preRollMs, forKey: Self.keyPreRoll) }
    }

    /// Tail margin kept after the release point.
    var postRollMs: Double {
        didSet { UserDefaults.standard.set(postRollMs, forKey: Self.keyPostRoll) }
    }

    /// Fade in/out applied at each event's edges. The processor clamps this to
    /// `postRollMs` on write, so a value stored here may be reduced when it
    /// reaches the processor; that clamp is the invariant, not a UI nicety.
    var rampMs: Double {
        didSet { UserDefaults.standard.set(rampMs, forKey: Self.keyRamp) }
    }

    /// Background expander — pulls down the stretched hiss an event carries
    /// around the call. See the processor's "Background expander" section for
    /// why it's an expander rather than a gate.
    var expanderEnabled: Bool {
        didSet { UserDefaults.standard.set(expanderEnabled, forKey: Self.keyExpanderEnabled) }
    }

    /// dB above the tracked noise floor at which audio passes at full gain.
    var expanderThresholdDB: Double {
        didSet { UserDefaults.standard.set(expanderThresholdDB, forKey: Self.keyExpanderThreshold) }
    }

    /// How far the background is pushed down, in dB.
    var expanderDepthDB: Double {
        didSet { UserDefaults.standard.set(expanderDepthDB, forKey: Self.keyExpanderDepth) }
    }

    /// How fast the expander closes again, in captured ms (×8 as heard). The
    /// hiss-removal vs tail-preservation trade — see the processor's
    /// `expanderReleaseMs`.
    var expanderReleaseMs: Double {
        didSet { UserDefaults.standard.set(expanderReleaseMs, forKey: Self.keyExpanderRelease) }
    }

    /// Sampler mode — play one deliberately-chosen call per interval instead
    /// of chasing every pulse the trigger can catch. See the processor's
    /// "Sampler mode" section.
    var samplerEnabled: Bool {
        didSet { UserDefaults.standard.set(samplerEnabled, forKey: Self.keySamplerEnabled) }
    }

    /// How often a call is sampled, in seconds.
    var samplerIntervalSeconds: Double {
        didSet { UserDefaults.standard.set(samplerIntervalSeconds, forKey: Self.keySamplerInterval) }
    }

    /// How long candidates are collected before the loudest is chosen.
    var samplerScanMs: Double {
        didSet { UserDefaults.standard.set(samplerScanMs, forKey: Self.keySamplerScan) }
    }

    /// Where each call's edges are cut, as a fraction of the way from the
    /// noise floor to that call's own peak. Lower is more generous. See the
    /// processor's `samplerBoundary` — this replaced a fixed level above the
    /// floor, which cut faint calls far tighter than loud ones.
    var samplerEdgeFraction: Double {
        didSet { UserDefaults.standard.set(samplerEdgeFraction, forKey: Self.keySamplerEdge) }
    }

    static let defaultGain: Float = 4.0

    private static let keyGain = "AdaptiveTE.gain"
    private static let keyHangover = "AdaptiveTE.hangoverMs"
    private static let keyMaxBuffer = "AdaptiveTE.maxBufferMs"
    private static let keyThreshold = "AdaptiveTE.thresholdDB"
    private static let keyRelease = "AdaptiveTE.releaseDB"
    private static let keyPreRoll = "AdaptiveTE.preRollMs"
    private static let keyPostRoll = "AdaptiveTE.postRollMs"
    private static let keyRamp = "AdaptiveTE.rampMs"
    private static let keyExpanderEnabled = "AdaptiveTE.expanderEnabled"
    private static let keyExpanderThreshold = "AdaptiveTE.expanderThresholdDB"
    private static let keyExpanderDepth = "AdaptiveTE.expanderDepthDB"
    private static let keyExpanderRelease = "AdaptiveTE.expanderReleaseMs"
    private static let keySamplerEnabled = "AdaptiveTE.samplerEnabled"
    private static let keySamplerInterval = "AdaptiveTE.samplerIntervalSeconds"
    private static let keySamplerScan = "AdaptiveTE.samplerScanMs"
    private static let keySamplerEdge = "AdaptiveTE.samplerEdgeFraction"

    init() {
        let d = UserDefaults.standard
        gain = d.object(forKey: Self.keyGain) != nil
            ? d.float(forKey: Self.keyGain) : Self.defaultGain
        hangoverMs = d.object(forKey: Self.keyHangover) != nil
            ? d.double(forKey: Self.keyHangover) : AdaptiveTimeExpansionProcessor.defaultHangoverMs
        maxBufferMs = d.object(forKey: Self.keyMaxBuffer) != nil
            ? d.double(forKey: Self.keyMaxBuffer) : AdaptiveTimeExpansionProcessor.defaultMaxBufferMs
        thresholdDB = d.object(forKey: Self.keyThreshold) != nil
            ? d.double(forKey: Self.keyThreshold) : AdaptiveTimeExpansionProcessor.defaultThresholdDB
        releaseDB = d.object(forKey: Self.keyRelease) != nil
            ? d.double(forKey: Self.keyRelease) : AdaptiveTimeExpansionProcessor.defaultReleaseDB
        preRollMs = d.object(forKey: Self.keyPreRoll) != nil
            ? d.double(forKey: Self.keyPreRoll) : AdaptiveTimeExpansionProcessor.defaultPreRollMs
        postRollMs = d.object(forKey: Self.keyPostRoll) != nil
            ? d.double(forKey: Self.keyPostRoll) : AdaptiveTimeExpansionProcessor.defaultPostRollMs
        rampMs = d.object(forKey: Self.keyRamp) != nil
            ? d.double(forKey: Self.keyRamp) : AdaptiveTimeExpansionProcessor.defaultRampMs
        expanderEnabled = d.object(forKey: Self.keyExpanderEnabled) != nil
            ? d.bool(forKey: Self.keyExpanderEnabled) : AdaptiveTimeExpansionProcessor.defaultExpanderEnabled
        expanderThresholdDB = d.object(forKey: Self.keyExpanderThreshold) != nil
            ? d.double(forKey: Self.keyExpanderThreshold) : AdaptiveTimeExpansionProcessor.defaultExpanderThresholdDB
        expanderDepthDB = d.object(forKey: Self.keyExpanderDepth) != nil
            ? d.double(forKey: Self.keyExpanderDepth) : AdaptiveTimeExpansionProcessor.defaultExpanderDepthDB
        expanderReleaseMs = d.object(forKey: Self.keyExpanderRelease) != nil
            ? d.double(forKey: Self.keyExpanderRelease) : AdaptiveTimeExpansionProcessor.defaultExpanderReleaseMs
        samplerEnabled = d.object(forKey: Self.keySamplerEnabled) != nil
            ? d.bool(forKey: Self.keySamplerEnabled) : AdaptiveTimeExpansionProcessor.defaultSamplerEnabled
        samplerIntervalSeconds = d.object(forKey: Self.keySamplerInterval) != nil
            ? d.double(forKey: Self.keySamplerInterval) : AdaptiveTimeExpansionProcessor.defaultSamplerIntervalSeconds
        samplerScanMs = d.object(forKey: Self.keySamplerScan) != nil
            ? d.double(forKey: Self.keySamplerScan) : AdaptiveTimeExpansionProcessor.defaultSamplerScanMs
        samplerEdgeFraction = d.object(forKey: Self.keySamplerEdge) != nil
            ? d.double(forKey: Self.keySamplerEdge) : AdaptiveTimeExpansionProcessor.defaultSamplerEdgeFraction
    }

    /// Every tunable as one Equatable value, so ContentView can watch the whole
    /// settings object with a SINGLE `.onChange` instead of one per property.
    /// Not a micro-optimisation: five separate `.onChange` modifiers in that
    /// body pushed the Swift type-checker over its limit ("unable to type-check
    /// this expression in reasonable time"). Add new tunables here as well as
    /// above, or they won't reach the processor until the next `.task`.
    struct Snapshot: Equatable {
        var gain: Float
        var hangoverMs: Double
        var maxBufferMs: Double
        var thresholdDB: Double
        var releaseDB: Double
        var preRollMs: Double
        var postRollMs: Double
        var rampMs: Double
        var expanderEnabled: Bool
        var expanderThresholdDB: Double
        var expanderDepthDB: Double
        var expanderReleaseMs: Double
        var samplerEnabled: Bool
        var samplerIntervalSeconds: Double
        var samplerScanMs: Double
        var samplerEdgeFraction: Double
    }

    var snapshot: Snapshot {
        Snapshot(gain: gain, hangoverMs: hangoverMs, maxBufferMs: maxBufferMs,
                 thresholdDB: thresholdDB, releaseDB: releaseDB,
                 preRollMs: preRollMs, postRollMs: postRollMs, rampMs: rampMs,
                 expanderEnabled: expanderEnabled,
                 expanderThresholdDB: expanderThresholdDB,
                 expanderDepthDB: expanderDepthDB,
                 expanderReleaseMs: expanderReleaseMs,
                 samplerEnabled: samplerEnabled,
                 samplerIntervalSeconds: samplerIntervalSeconds,
                 samplerScanMs: samplerScanMs,
                 samplerEdgeFraction: samplerEdgeFraction)
    }

    func apply(to processor: AdaptiveTimeExpansionProcessor) {
        processor.gain = gain
        processor.hangoverMs = hangoverMs
        processor.maxBufferMs = maxBufferMs
        processor.thresholdDB = thresholdDB
        processor.releaseDB = releaseDB
        // Post-roll BEFORE ramp: the processor clamps `rampMs` to the current
        // `postRollMs` on write, so applying them the other way round would
        // clamp the new ramp against the OLD post-roll and quietly lose a
        // legitimate increase whenever both moved together.
        processor.postRollMs = postRollMs
        processor.preRollMs = preRollMs
        processor.rampMs = rampMs
        processor.expanderEnabled = expanderEnabled
        processor.expanderThresholdDB = expanderThresholdDB
        processor.expanderDepthDB = expanderDepthDB
        processor.expanderReleaseMs = expanderReleaseMs
        processor.samplerEnabled = samplerEnabled
        processor.samplerIntervalSeconds = samplerIntervalSeconds
        processor.samplerScanMs = samplerScanMs
        processor.samplerEdgeFraction = samplerEdgeFraction
    }

    func reset() {
        gain = Self.defaultGain
        hangoverMs = AdaptiveTimeExpansionProcessor.defaultHangoverMs
        maxBufferMs = AdaptiveTimeExpansionProcessor.defaultMaxBufferMs
        thresholdDB = AdaptiveTimeExpansionProcessor.defaultThresholdDB
        releaseDB = AdaptiveTimeExpansionProcessor.defaultReleaseDB
        preRollMs = AdaptiveTimeExpansionProcessor.defaultPreRollMs
        postRollMs = AdaptiveTimeExpansionProcessor.defaultPostRollMs
        rampMs = AdaptiveTimeExpansionProcessor.defaultRampMs
        expanderEnabled = AdaptiveTimeExpansionProcessor.defaultExpanderEnabled
        expanderThresholdDB = AdaptiveTimeExpansionProcessor.defaultExpanderThresholdDB
        expanderDepthDB = AdaptiveTimeExpansionProcessor.defaultExpanderDepthDB
        expanderReleaseMs = AdaptiveTimeExpansionProcessor.defaultExpanderReleaseMs
        samplerEnabled = AdaptiveTimeExpansionProcessor.defaultSamplerEnabled
        samplerIntervalSeconds = AdaptiveTimeExpansionProcessor.defaultSamplerIntervalSeconds
        samplerScanMs = AdaptiveTimeExpansionProcessor.defaultSamplerScanMs
        samplerEdgeFraction = AdaptiveTimeExpansionProcessor.defaultSamplerEdgeFraction
    }
}
