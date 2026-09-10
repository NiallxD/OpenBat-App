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

/// The balance between the two live channels, as one number.
///
/// **There is only one volume control now, and it is on the side of the phone**
/// (Niall, 2026-09-10). Both channels default to the top of their range, so the
/// app is as loud as its output stage allows and the device buttons cover the
/// whole useful range. What was left was two sliders that no longer set loudness
/// — the only thing they could still do was set the two channels against each
/// other, which is one decision wearing two controls.
///
/// So they became this: centre is both channels at full, and moving off centre
/// holds the *other* one down by up to 24 dB. Expressed to the reader as "+n dB to
/// this side", which is what it sounds like and is true relative to the other
/// channel; it has to be an attenuation underneath because there is nothing above
/// full scale to give away.
///
/// Stored as the two existing per-channel trims rather than as a new preference,
/// so the reset, the remote-default re-seed and the tuning overlay all keep
/// working on exactly the values they already knew about.
enum ListenMixer {
    /// How far off centre the mixer goes, in dB.
    static let maxOffsetDB: Double = 24
    static var range: ClosedRange<Double> { -maxOffsetDB...maxOffsetDB }

    /// Each channel's "full" level — the trim it sits at when the mixer is
    /// centred, which is also its default.
    static var expansionFull: Double { SnippetExpansionSettings.defaultTrimDB }
    static var heterodyneFull: Double { HeterodyneSettings.defaultTrimDB }

    /// Negative favours time expansion (the slider's left), positive heterodyne.
    static func balance(expansionTrim: Double, heterodyneTrim: Double) -> Double {
        let held = (expansionFull - expansionTrim) - (heterodyneFull - heterodyneTrim)
        return min(max(held, -maxOffsetDB), maxOffsetDB)
    }

    /// The two trims a balance implies. Only ever one side is held down.
    static func trims(forBalance balance: Double) -> (expansion: Double, heterodyne: Double) {
        let b = min(max(balance, -maxOffsetDB), maxOffsetDB)
        return (expansionFull - max(0, b), heterodyneFull - max(0, -b))
    }
}

/// How much of the background a replay keeps.
///
/// **The case names and the labels deliberately differ** (Niall, 2026-09-09).
/// "Reduce" and "Scrub" describe the mechanism, and a person setting noise
/// reduction is choosing an amount, not an algorithm — so the control reads Off
/// / Normal / High, which is a scale, while the code keeps the names that say
/// what each one actually does. Do not rename the cases to match: `.scrub`
/// silences everything that isn't plainly a call, and a case called `.high`
/// would hide that from the next person to read `SpectralDenoiser`.
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
        case .reduce: "Normal"
        case .scrub:  "High"
        }
    }

    /// What the LIVE heterodyne channel offers: Off and Normal, no High.
    ///
    /// Not a default, a restriction (Niall, 2026-09-09). High silences whatever
    /// doesn't clear the gate, which on a replay is a feature — you already know
    /// a call is in the buffer, so the gaps are only gaps. Live, this is the
    /// channel that tells you a bat is there at all, and a gate a shade too
    /// tight makes "missed bat" and "quiet night" the same sound. There is no
    /// setting of it that is worth that, so it isn't offered.
    static let liveChoices: [SnippetDenoiseMode] = [.off, .reduce]

    var strength: DenoiseStrength { self == .scrub ? .scrub : .reduce }
}

@Observable
final class SnippetExpansionSettings: Reseedable {

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
            persist(expansion, Self.keyExpansion)
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
        didSet { persist(memorySeconds, Self.keyMemory) }
    }

    var routing: SnippetOutputRouting {
        didSet { persist(routing.rawValue, Self.keyRouting) }
    }

    /// Volume trim in dB, on top of the automatic snippet-to-snippet level
    /// match. **Stored under a new key**, deliberately: the value this
    /// replaced was a raw multiplier defaulting to 4, and reading that back as
    /// a dB trim would give every existing install +4 dB on top of an already
    /// correct level.
    var trimDB: Double {
        didSet { persist(trimDB, Self.keyTrim) }
    }

    /// How much background a replay keeps — see `SpectralDenoiser`. Replaced a
    /// `hissReductionDB` depth, which was a broadband expander and had to be
    /// tuned because it was always a compromise between hiss and artefacts.
    /// These are not points on that dial: each is a different decision about
    /// what counts as a call.
    var denoiseMode: SnippetDenoiseMode {
        didSet { persist(denoiseMode.rawValue, Self.keyDenoise) }
    }

    /// Deliberate pause after each replay before the mode will trigger again —
    /// see `SnippetExpansionProcessor.rearmSeconds`.
    var rearmSeconds: Double {
        didSet { persist(rearmSeconds, Self.keyRearm) }
    }

    /// Fade in/out at each end of a replay, ms of output time.
    var fadeMS: Double {
        didSet { persist(fadeMS, Self.keyFade) }
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
    static var defaultExpansion: Double { Tunable.snippetExpansion.value(16.0) }
    static var defaultMemorySeconds: Double { Tunable.snippetMemorySeconds.value(0.1) }
    /// **The top of the range, from a night in the field** (Niall, 2026-09-09/10:
    /// "the sound last night was too low"; then "default both to +24 and allow the
    /// user to control volume with their device buttons").
    ///
    /// The default IS the maximum, deliberately, and that is what makes the phone's
    /// own volume control the level control: its full range is useful, with full
    /// volume a little louder than anyone wants and silence at the bottom. The
    /// slider below it is then what it should have been all along — a way to back
    /// one channel off, and to set the two against each other under "time
    /// expansion with heterodyne", where both are heard at once and the device
    /// buttons move them together.
    ///
    /// Worth understanding what the last few dB actually buy, because it is not
    /// loudness on a close pass. A replay is already peak-matched to
    /// `SnippetExpansionProcessor.targetPeak`, which is 0.8 × the soft clipper's
    /// knee, and the knee to the ceiling is another 3 dB — so a replay whose peak
    /// really is a close call can only rise about 5 dB no matter what is put in
    /// front of it, and +24 rather than +18 moves that peak by a tenth of a dB.
    ///
    /// What DOES gain is everything else: `maxBackground` deliberately holds a
    /// window with loud room tone below the peak target, and those — the distant
    /// bats, the ones that were inaudible outdoors — take the full difference. The
    /// price is that the soft knee is now doing heavy compression on the loudest
    /// replays, so a bat overhead and a bat across the field arrive closer in
    /// level than they really are. That is a real loss of a real cue, accepted
    /// because a call you cannot hear carries no cue at all.
    static var defaultTrimDB: Double { Tunable.snippetTrimDB.value(24.0) }
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
    static var defaultRearmSeconds: Double { Tunable.snippetRearmSeconds.value(0.5) }
    static var defaultFadeMS: Double { Tunable.snippetFadeMS.value(30.0) }

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

    /// Suppresses the persisting `didSet`s while a re-seed assigns — see
    /// `RemoteDefaultsReseed.swift`.
    var isSeeding = false

    private func persist(_ value: Any, _ key: String) {
        guard !isSeeding else { return }
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Remote defaults for everything the user has never set. See
    /// `RemoteDefaultsReseed.swift`.
    func reseedRemoteDefaults() {
        let d = UserDefaults.standard
        seeding {
            if d.object(forKey: Self.keyExpansion) == nil { expansion = Self.defaultExpansion }
            if d.object(forKey: Self.keyMemory) == nil { memorySeconds = Self.defaultMemorySeconds }
            if d.object(forKey: Self.keyTrim) == nil { trimDB = Self.defaultTrimDB }
            if d.object(forKey: Self.keyRearm) == nil { rearmSeconds = Self.defaultRearmSeconds }
            if d.object(forKey: Self.keyFade) == nil { fadeMS = Self.defaultFadeMS }
        }
    }

    func apply(to processor: SnippetExpansionProcessor) {
        processor.expansion = expansion
        processor.memorySeconds = memorySeconds
        processor.trimDB = trimDB
        processor.denoiseMode = denoiseMode
        processor.rearmSeconds = rearmSeconds
        processor.fadeMS = fadeMS
    }

    /// Inside `seeding` — see `PulseHaptics.resetToDefaults` for why. The reset has
    /// already erased these keys; writing them back would pin them to today's
    /// numbers and stop this install ever picking up a remote change to them.
    func reset() {
        seeding {
            expansion = Self.defaultExpansion
            memorySeconds = Self.defaultMemorySeconds
            trimDB = Self.defaultTrimDB
            denoiseMode = Self.defaultDenoiseMode
            rearmSeconds = Self.defaultRearmSeconds
            fadeMS = Self.defaultFadeMS
            routing = Self.defaultRouting
        }
    }
}
