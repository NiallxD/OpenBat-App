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

/// How much of the background a replay keeps.
enum SnippetDenoiseMode: Int, CaseIterable, Identifiable {
    /// The snippet exactly as captured.
    case off = 0
    /// Measure the noise per frequency band and subtract it, leaving a quiet
    /// steady bed. Nothing is silenced outright.
    case reduce = 1
    /// Keep only what is plainly a call and silence everything else.
    case scrub = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .off:    "Off"
        case .reduce: "Reduce"
        case .scrub:  "Scrub"
        }
    }

    var strength: DenoiseStrength { self == .scrub ? .scrub : .reduce }
}

@Observable
final class SnippetExpansionSettings {

    /// Slowdown factor. 8× is the natural 384/48 ratio and costs no filtering;
    /// below it the processor installs an anti-alias low-pass (see
    /// `SnippetExpansionProcessor.expansion`), above it interpolates.
    ///
    /// Only the three values in `expansionSteps` are reachable (Niall,
    /// 2026-08-28) — the setter snaps anything else to the nearest. Snapping
    /// here rather than in the Settings card is what makes that true of every
    /// writer: a tuning snapshot restored from before this change, or a value
    /// left in UserDefaults by the old free 4–20 slider, lands on a step too,
    /// so the card can never display a position the stored value isn't at.
    var expansion: Double {
        didSet {
            let snapped = Self.snap(expansion)
            // Assigning inside didSet doesn't re-enter it, so this settles in
            // one pass and only the snapped value is ever persisted.
            if snapped != expansion { expansion = snapped; return }
            UserDefaults.standard.set(expansion, forKey: Self.keyExpansion)
        }
    }

    /// The speeds offered, slowest replay first. 8× is the free 384/48 ratio,
    /// 16× is the shipped default (see `defaultExpansion`), 10× is the middle
    /// step for anyone who finds 16× too far down in pitch.
    static let expansionSteps: [Double] = [8, 10, 16]

    static func snap(_ value: Double) -> Double {
        expansionSteps.min(by: { abs($0 - value) < abs($1 - value) }) ?? defaultExpansion
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

    /// Volume trim in dB, on top of the automatic snippet-to-snippet level
    /// match. **Stored under a new key**, deliberately: the value this
    /// replaced was a raw multiplier defaulting to 4, and reading that back as
    /// a dB trim would give every existing install +4 dB on top of an already
    /// correct level.
    var trimDB: Double {
        didSet { UserDefaults.standard.set(trimDB, forKey: Self.keyTrim) }
    }

    /// How much background a replay keeps — see `SpectralDenoiser`. Replaced a
    /// `hissReductionDB` depth, which was a broadband expander and had to be
    /// tuned because it was always a compromise between hiss and artefacts.
    /// These are not points on that dial: each is a different decision about
    /// what counts as a call.
    var denoiseMode: SnippetDenoiseMode {
        didSet { UserDefaults.standard.set(denoiseMode.rawValue, forKey: Self.keyDenoise) }
    }

    /// Deliberate pause after each replay before the mode will trigger again —
    /// see `SnippetExpansionProcessor.rearmSeconds`.
    var rearmSeconds: Double {
        didSet { UserDefaults.standard.set(rearmSeconds, forKey: Self.keyRearm) }
    }

    /// Fade in/out at each end of a replay, ms of output time.
    var fadeMS: Double {
        didSet { UserDefaults.standard.set(fadeMS, forKey: Self.keyFade) }
    }

    // Field tuning session, 2026-08-17: 16x over a 0.5 s buffer. Deliberately
    // NOT the 8x that costs no filtering — the pair is chosen for the product
    // this type's own doc calls the number that matters.
    //
    // The buffer came down again to 0.1 s (Niall, 2026-09-01). The window
    // straddles the trigger, so 0.5 s wrapped a 2–20 ms call in half a second
    // of room tone and then stretched all of it 16× — most of what a listener
    // heard was the gap, not the bat. 0.1 s keeps 50 ms either side, and the
    // replay drops from 8 s to 1.6 s, so the mode is deaf for a fifth as long
    // per trigger. "Fewer calls heard completely beats more calls heard
    // partially" cuts this way too: the call is still whole, there is simply
    // less nothing around it.
    static let defaultExpansion: Double = 16
    static let defaultMemorySeconds: Double = 0.1
    static let defaultTrimDB: Double = 0
    /// Scrub, not Reduce. Measured against the demo file the two are
    /// indistinguishable on every figure that describes the CALL — peak within
    /// 0.0 dB, total call energy within 0.3 dB, onset frame within 0.02 dB —
    /// and they differ only in what happens to the gap between calls, which
    /// Scrub makes digitally silent (2026-09-01). Given that, the quieter one
    /// is the better default and Reduce is there for anyone who finds silence
    /// between calls disconcerting.
    static let defaultDenoiseMode: SnippetDenoiseMode = .scrub
    static let defaultRouting: SnippetOutputRouting = .both
    /// Half a second, which at the 0.1 s buffer is five buffer-lengths of quiet
    /// after each replay. Long enough that the echoes of the call just played
    /// have died away; short enough that a bat working an area still gets
    /// caught two or three times a pass.
    static let defaultRearmSeconds: Double = 0.5
    static let defaultFadeMS: Double = 30

    /// How long a replay lasts at the current settings — shown next to the
    /// sliders, because the cost of a long buffer or a high factor is not the
    /// buffer or the factor, it is this number.
    var replaySeconds: Double { memorySeconds * expansion }

    private static let keyExpansion = "SnippetExp.expansion"
    private static let keyMemory = "SnippetExp.memorySeconds"
    private static let keyRouting = "SnippetExp.routing"
    private static let keyTrim = "SnippetExp.trimDB"
    /// New key: the old one held a Bool and `integer(forKey:)` would read a
    /// stored `true` as 1, which happens to be Reduce — right by luck, but only
    /// by luck, and a stored `false` would read as 0/Off which is wrong for
    /// someone who never touched the setting.
    private static let keyDenoise = "SnippetExp.denoiseMode"
    private static let keyRearm = "SnippetExp.rearmSeconds"
    private static let keyFade = "SnippetExp.fadeMS"

    init() {
        let d = UserDefaults.standard
        // Snapped explicitly: property observers don't run during init, so a
        // value stored by the old free slider would otherwise survive here
        // unsnapped and the card would show a step the value isn't on.
        expansion = Self.snap(d.object(forKey: Self.keyExpansion) != nil
            ? d.double(forKey: Self.keyExpansion) : Self.defaultExpansion)
        memorySeconds = d.object(forKey: Self.keyMemory) != nil
            ? d.double(forKey: Self.keyMemory) : Self.defaultMemorySeconds
        trimDB = d.object(forKey: Self.keyTrim) != nil
            ? d.double(forKey: Self.keyTrim) : Self.defaultTrimDB
        denoiseMode = d.object(forKey: Self.keyDenoise) != nil
            ? (SnippetDenoiseMode(rawValue: d.integer(forKey: Self.keyDenoise))
               ?? Self.defaultDenoiseMode)
            : Self.defaultDenoiseMode
        rearmSeconds = d.object(forKey: Self.keyRearm) != nil
            ? d.double(forKey: Self.keyRearm) : Self.defaultRearmSeconds
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
        processor.trimDB = trimDB
        processor.denoiseMode = denoiseMode
        processor.rearmSeconds = rearmSeconds
        processor.fadeMS = fadeMS
    }

    func reset() {
        expansion = Self.defaultExpansion
        memorySeconds = Self.defaultMemorySeconds
        trimDB = Self.defaultTrimDB
        denoiseMode = Self.defaultDenoiseMode
        rearmSeconds = Self.defaultRearmSeconds
        fadeMS = Self.defaultFadeMS
        routing = Self.defaultRouting
    }
}
