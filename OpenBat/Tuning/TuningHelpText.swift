//
//  TuningHelpText.swift
//  OpenBat
//
//  Explanations shown when a parameter name is tapped in the live tuning
//  overlay. Kept together here rather than inline in the tab views: they're
//  prose, they get edited as wording rather than as code, and several of them
//  are the only place a real tradeoff is stated in words a user sees.
//
//  House style for these: say what moving the knob DOES, then what it COSTS.
//  A description that only names the parameter ("how long the hangover is")
//  tells the reader nothing they couldn't guess from the label.
//

/// Popover copy for every tuning knob, keyed by a static let per parameter.
/// Grouped by tab via `// MARK:` to match `LiveTuningTabs.swift`'s layout.
enum TuningHelp {

    // MARK: Heterodyne

    static let heterodyneGain = """
        Makeup gain on the heterodyne output. Bat calls are faint and the mix \
        preserves the input's own level, so some boost is normally wanted. Too \
        much brings the background up with the calls.
        """

    static let audibleOffset = """
        How far below the detected call the oscillator sits. The difference \
        between the two is what you actually hear, so this sets the pitch of \
        the tone — lower sounds deeper and muddier, higher sounds thin and \
        whistly. It changes only how calls sound, not which ones are found.
        """

    // MARK: Slow replay

    static let snippetExpansion = """
        How much slower the captured snippet is replayed. Bat calls last only a \
        few milliseconds, which is too short for the ear to resolve any detail; \
        slowing them stretches that structure out. It lowers the pitch by the \
        same factor, so a call heard at 8× also sounds three octaves down.
        """

    static let snippetMemory = """
        How much audio is captured around the trigger. Half of it is what \
        happened BEFORE the pulse that fired it, so the call that triggered the \
        capture is never clipped. Longer holds more of a pass; shorter gets you \
        back to listening sooner.
        """

    static let snippetHiss = """
        How far the background between calls is pushed down. Slowing a snippet \
        stretches its background hiss along with the calls, which is what makes \
        it noticeable. This lowers quiet material rather than cutting it out, so \
        faint calls and call tails survive instead of being chopped. Too much \
        makes the level pump between calls.
        """

    static let snippetFade = """
        How gently each replay starts and ends. Snippets arrive over the top of \
        the live channel, so a short fade stops them appearing and vanishing \
        abruptly. Very short values just prevent a click; longer ones are heard \
        as a fade.
        """

    static let snippetGain = """
        Makeup gain on the replayed snippet only — the live heterodyne channel \
        has its own. Raise it if replays sit too quietly under the live sound.
        """

    static let snippetReplayLength = """
        Buffer × speed: how long each replay takes. Nothing new is captured \
        while one plays, so this is also how long the mode is deaf after every \
        trigger. Live heterodyne keeps running throughout, so you never lose \
        the bat — but a long replay means fewer passes get one.
        """

    static let snippetRouting = """
        What reaches your ears. "Heterodyne" is the live channel alone, \
        "Replay" the slow snippets alone, "Both" mixes them with the live \
        channel stepping back while a replay plays.
        """

    static let loFrequency = """
        Where the oscillator is currently parked. Heterodyne only makes a \
        narrow band around this audible, which is why it has to follow the \
        call. "Searching" means nothing has been detected yet.
        """

    static let tuningMode = """
        Auto follows the detected call frequency. Manual holds the oscillator \
        where you put it — useful for listening to one species while another \
        is calling. Drag the tuning pill on the main screen to go manual.
        """

    // MARK: Pulse haptics

    static let hapticRate = """
    Detected pulses per second, averaged over the rate window. One count per \
    call.

    This is the number both buzz thresholds are compared against. Watch it \
    through a real pass before setting them.
    """
    static let hapticMode = """
    Which way pulses are being rendered right now: separate taps, or one \
    continuous buzz.
    """
    static let hapticEvents = "Haptic events played since the feature was switched on."
    static let hapticBuzzEnter = """
    Pulse rate at which taps collapse into a buzz.

    Catches a dense run of SEPARATE calls. It cannot catch a burst whose calls \
    arrive closer together than the detector's maximum gap — those merge into \
    one run and read as a LOW rate. "Buzz after" covers that case; the two \
    triggers are independent and either can start a buzz.
    """
    static let hapticBuzzExit = """
    Pulse rate at which the buzz breaks back into taps. Always held below the \
    buzz rate.

    The gap between the two is the real knob: wide commits and holds through a \
    dip, narrow tracks the bat closely but can flicker. No gap at all flips \
    modes several times a second and feels like a fault.
    """
    static let hapticRateWindow = """
    How long pulse rate is averaged over before it's compared to the thresholds.

    Short reacts quickly and jitters; long is steady but enters and leaves the \
    buzz late.
    """
    static let hapticHangover = """
    Silence after the last pulse before a buzz ends.

    A buzz stops because the bat stopped, and that arrives as an absence — \
    nothing announces it. Too short and a buzz stutters through natural gaps; \
    too long and the phone keeps buzzing after the bat has gone.
    """
    static let hapticStrength = """
    Overall strength trim, applied on top of the call's own energy. Scales what \
    the bat is doing rather than flattening it.
    """
    static let hapticLevelFloor = """
    The call level that maps to the weakest tap, on the detector's normalised \
    0–1 scale (the same one the amplitude threshold uses).

    The likeliest of these to need changing. Raise it if distant calls feel too \
    strong; lower it if they disappear entirely.
    """
    static let hapticLevelCeiling = """
    The call level that maps to a full-strength tap.

    Lower it if everything pins to maximum and a close bat feels the same as a \
    distant one.
    """
    static let hapticMinIntensity = """
    Strength given to a call sitting right on the quiet-call level.

    Deliberately not zero: a barely-detected bat still has to be felt, or a \
    distant one reads as no bat at all.
    """
    static let hapticFreqFloor = """
    Peak frequency at or below which a call feels as dull as it gets.

    Frequency drives sharpness, not strength — the Taptic Engine has no pitch, \
    so this is a dull-thud-to-crisp-tick axis rather than a musical one.
    """
    static let hapticFreqCeiling = """
    Peak frequency at or above which a call feels as crisp as it gets.

    Narrow the span between this and the dull end to exaggerate the difference \
    between species; widen it to calm that down.
    """
    static let hapticTapInterval = """
    Minimum spacing between separate taps.

    Below roughly 30–50 ms the actuator physically cannot render two events, \
    and extra taps only smear the envelope. This is a hardware limit being \
    respected rather than a preference.
    """

    // MARK: Pulse trigger

    static let triggerMode = """
        Ultrasonic requires energy above the minimum frequency as well as \
        loudness, so warm rooms, handling noise and speech don't trigger it. \
        Amplitude triggers on loudness alone — simpler, and much easier to \
        set off by accident.
        """

    static let amplitudeThreshold = """
        Trigger level as a fraction of full scale. Used only in Amplitude mode.
        """

    static let minFrequency = """
        Energy below this is ignored when deciding a pulse has started. Set it \
        under the lowest species you expect — too high and low-frequency calls \
        such as Noctules never trigger at all.
        """

    static let minDuration = """
        How many consecutive spectrogram columns must be over threshold before \
        it counts as a pulse. Raising it rejects single-column noise spikes; \
        too high and genuinely short calls are ignored.
        """

    static let bridgeGaps = """
        Gaps shorter than this don't end a pulse. Stops a call whose energy \
        briefly dips being counted as two.
        """

    static let holdOff = """
        Minimum time before another pulse can trigger. Stops one call \
        retriggering on its own echo or on a reverberant tail.
        """

    static let captureWindow = """
        How much time the captured pulse image spans. The onset is locked at \
        25% from the left, so this mostly decides how much tail you see after \
        the call.
        """

    static let pulseNoiseFloor = """
        Display threshold for the captured pulse image — anything below is \
        drawn as background. Affects only what you see, not what is detected \
        or identified.
        """

    // MARK: Display

    static let band = """
        The frequency range shown, and listened to. It also limits both \
        listening modes, so narrowing it removes noise outside the band from \
        what you hear, not just from the display.
        """

    static let timeWindow = """
        How many seconds of spectrogram fit across the screen. Shorter shows \
        the shape within a call; longer shows the shape of a whole pass.
        """

    static let spectrogramFloor = """
        Display threshold for the live spectrogram. Raise it to clean up a \
        noisy background; too high and faint calls vanish from view — though \
        they are still detected and identified, since this is display only.
        """

    static let palette = """
        Colour map for the spectrogram. Purely visual. Inferno and Viridis \
        keep detail visible across the whole range; Greyscale is the most \
        honest about relative loudness.
        """
}
