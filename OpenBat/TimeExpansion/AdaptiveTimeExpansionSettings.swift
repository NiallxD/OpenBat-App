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

    static let defaultGain: Float = 4.0

    private static let keyGain = "AdaptiveTE.gain"
    private static let keyHangover = "AdaptiveTE.hangoverMs"
    private static let keyMaxBuffer = "AdaptiveTE.maxBufferMs"
    private static let keyThreshold = "AdaptiveTE.thresholdDB"
    private static let keyRelease = "AdaptiveTE.releaseDB"

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
    }

    var snapshot: Snapshot {
        Snapshot(gain: gain, hangoverMs: hangoverMs, maxBufferMs: maxBufferMs,
                 thresholdDB: thresholdDB, releaseDB: releaseDB)
    }

    func apply(to processor: AdaptiveTimeExpansionProcessor) {
        processor.gain = gain
        processor.hangoverMs = hangoverMs
        processor.maxBufferMs = maxBufferMs
        processor.thresholdDB = thresholdDB
        processor.releaseDB = releaseDB
    }

    func reset() {
        gain = Self.defaultGain
        hangoverMs = AdaptiveTimeExpansionProcessor.defaultHangoverMs
        maxBufferMs = AdaptiveTimeExpansionProcessor.defaultMaxBufferMs
        thresholdDB = AdaptiveTimeExpansionProcessor.defaultThresholdDB
        releaseDB = AdaptiveTimeExpansionProcessor.defaultReleaseDB
    }
}
