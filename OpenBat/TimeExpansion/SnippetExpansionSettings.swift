//
//  SnippetExpansionSettings.swift
//  OpenBat
//
//  Persisted settings for the LIVE snippet expansion mode (see
//  SnippetExpansionProcessor). Unlike TimeExpansionSettings — which is owned
//  locally by WavPlayerView because file playback has no live counterpart —
//  this one is threaded down from ContentView like the other live listen modes'
//  settings, because the live tuning overlay writes to it while capture runs.
//

import Foundation

/// What reaches the speaker while the snippet mode is the active listen mode.
enum SnippetOutputRouting: Int, CaseIterable {
    /// Live heterodyne only — the snippet still captures and replays silently,
    /// so switching to one of the other two mid-pass isn't jarring.
    case heterodyneOnly = 0
    /// Slow replay only; silence between snippets.
    case expansionOnly = 1
    /// Both, summed to mono, heterodyne ducking while a replay sounds.
    case both = 2

    var label: String {
        switch self {
        case .heterodyneOnly: "Heterodyne"
        case .expansionOnly:  "Replay"
        case .both:           "Both"
        }
    }
}

@Observable
final class SnippetExpansionSettings {

    /// Slowdown factor. 8× is the natural 384/48 ratio and costs no filtering;
    /// below it the processor installs an anti-alias low-pass (see
    /// `SnippetExpansionProcessor.expansion`), above it interpolates.
    var expansion: Double {
        didSet { UserDefaults.standard.set(expansion, forKey: Self.keyExpansion) }
    }

    /// Capture window. The replay occupies `memorySeconds × expansion` seconds,
    /// during which no new snippet can be captured — so this and `expansion`
    /// together set how much of the night the mode is deaf for.
    var memorySeconds: Double {
        didSet { UserDefaults.standard.set(memorySeconds, forKey: Self.keyMemory) }
    }

    var routing: SnippetOutputRouting {
        didSet { UserDefaults.standard.set(routing.rawValue, forKey: Self.keyRouting) }
    }

    /// Output makeup gain for the replay path.
    var gain: Float {
        didSet { UserDefaults.standard.set(gain, forKey: Self.keyGain) }
    }

    /// Depth of the background expander, in dB. 0 plays the snippet exactly as
    /// captured. See SnippetExpansionProcessor's expander section and
    /// Context.md §3 — expander, not gate, so quiet material is pushed down
    /// rather than cut out.
    var hissReductionDB: Double {
        didSet { UserDefaults.standard.set(hissReductionDB, forKey: Self.keyHiss) }
    }

    /// Fade in/out at each end of a replay, ms of output time.
    var fadeMS: Double {
        didSet { UserDefaults.standard.set(fadeMS, forKey: Self.keyFade) }
    }

    static let defaultExpansion: Double = 8
    static let defaultMemorySeconds: Double = 1.5
    static let defaultGain: Float = 4
    static let defaultRouting: SnippetOutputRouting = .both
    static let defaultHissReductionDB: Double = 18
    static let defaultFadeMS: Double = 30

    /// How long a replay lasts at the current settings — shown next to the
    /// sliders, because the cost of a long buffer or a high factor is not the
    /// buffer or the factor, it is this number.
    var replaySeconds: Double { memorySeconds * expansion }

    private static let keyExpansion = "SnippetExp.expansion"
    private static let keyMemory = "SnippetExp.memorySeconds"
    private static let keyRouting = "SnippetExp.routing"
    private static let keyGain = "SnippetExp.gain"
    private static let keyHiss = "SnippetExp.hissReductionDB"
    private static let keyFade = "SnippetExp.fadeMS"

    init() {
        let d = UserDefaults.standard
        expansion = d.object(forKey: Self.keyExpansion) != nil
            ? d.double(forKey: Self.keyExpansion) : Self.defaultExpansion
        memorySeconds = d.object(forKey: Self.keyMemory) != nil
            ? d.double(forKey: Self.keyMemory) : Self.defaultMemorySeconds
        gain = d.object(forKey: Self.keyGain) != nil
            ? d.float(forKey: Self.keyGain) : Self.defaultGain
        hissReductionDB = d.object(forKey: Self.keyHiss) != nil
            ? d.double(forKey: Self.keyHiss) : Self.defaultHissReductionDB
        fadeMS = d.object(forKey: Self.keyFade) != nil
            ? d.double(forKey: Self.keyFade) : Self.defaultFadeMS
        routing = d.object(forKey: Self.keyRouting) != nil
            ? (SnippetOutputRouting(rawValue: d.integer(forKey: Self.keyRouting))
               ?? Self.defaultRouting)
            : Self.defaultRouting
    }

    func apply(to processor: SnippetExpansionProcessor) {
        processor.expansion = expansion
        processor.memorySeconds = memorySeconds
        processor.gain = gain
        processor.hissReductionDB = hissReductionDB
        processor.fadeMS = fadeMS
    }

    func reset() {
        expansion = Self.defaultExpansion
        memorySeconds = Self.defaultMemorySeconds
        gain = Self.defaultGain
        hissReductionDB = Self.defaultHissReductionDB
        fadeMS = Self.defaultFadeMS
        routing = Self.defaultRouting
    }
}
