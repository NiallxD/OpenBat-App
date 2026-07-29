//
//  TimeExpansionSettings.swift
//  OpenBat
//
//  Persisted gain for playback-only classic time expansion. Owned locally by
//  WavPlayerView (@State) rather than threaded down from ContentView like
//  the other listen modes' settings — file time expansion has no live-listening
//  counterpart to stay in sync with, it only ever applies to file playback.
//

import Foundation

@Observable
final class TimeExpansionSettings {

    /// Output makeup gain. Straight pass-through preserves the recording's own
    /// level, and bat calls are weak, so some makeup is normally wanted.
    var gain: Float {
        didSet { UserDefaults.standard.set(gain, forKey: Self.keyGain) }
    }

    static let defaultGain: Float = 4.0

    private static let keyGain = "TimeExp.gain"

    init() {
        let d = UserDefaults.standard
        gain = d.object(forKey: Self.keyGain) != nil
            ? d.float(forKey: Self.keyGain) : Self.defaultGain
    }

    func apply(to processor: TimeExpansionProcessor) {
        processor.gain = gain
    }

    func reset() {
        gain = Self.defaultGain
    }
}
