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

    // MARK: Variable Time Distortion

    static let vtdLag = """
    How far behind real time the output currently is.

    This mode never goes deaf and never drops a sample, so a dense pass is paid \
    for in lag rather than in lost calls. Expect a sawtooth: lag builds through \
    a pass and drains back toward zero in the quiet between passes.
    """
    static let vtdRate = """
    Current playback rate — input samples consumed per output sample.

    1× is full expansion (a call), 8× is true speed (a gap), above 8× is the \
    gaps being compressed to repay lag.
    """
    static let vtdExpanded = "Calls given an expansion window since this mode started."
    static let vtdDropped = """
    Call windows that arrived too late to use, so those calls played by \
    unexpanded.

    The detector reports a window only once the call's run has ended, so the \
    window always arrives after the audio it describes. If this climbs, raise \
    Lookahead until it stops — that is the single most likely reason the mode \
    sounds like it is doing nothing.
    """
    static let vtdOverflow = """
    Input ring overflows — the ONLY path in this mode that discards audio, and \
    a failure rather than a mode. Should stay at zero.

    Non-zero means lag exceeded the ring (about 10 s) and the read pointer had \
    to skip. Lower Gap speed or raise Max catch-up rate.
    """
    static let vtdGapRate = """
    How fast the silence between calls plays.

    8× is true speed, which keeps the rhythm between calls literally correct — \
    the thing event-triggered expansion cannot do, where between-event spacing \
    comes out 8× too fast. Higher values shorten the gaps and accrue less lag, \
    at the cost of a more hurried cadence.
    """
    static let vtdRateMax = """
    Ceiling on how fast the gaps may run while catching up after a pass.

    Only reached in sustained quiet. Higher drains lag faster; it also costs \
    more CPU, since the resampler's filter widens with rate.
    """
    static let vtdLookahead = """
    How far behind the live edge the read pointer starts, and the floor it holds.

    This is the budget for detector latency: a call window can only be used if \
    it arrives before the read pointer reaches it. Too low and windows are \
    dropped and calls play unexpanded — watch Dropped windows.
    """
    static let vtdCatchupAfter = """
    How much continuous quiet before the gaps start speeding up to repay lag.

    Long enough that gaps *inside* a pass never trigger it, so the rhythm there \
    stays at true speed; short enough that the quiet between passes is used.
    """
    static let vtdTransition = """
    How long the glide between gap speed and full expansion takes.

    The step at each boundary is large: expanding admits the whole ultrasonic \
    band into the audible one, while the gaps are filtered down to a few kHz, \
    and noise level goes with bandwidth. Crossed quickly that reads as a pop on \
    the way in and a cut on the way out. Longer turns the same step into a \
    swell. Braking starts proportionally earlier, so this cannot make calls \
    arrive before the rate has settled.
    """
    static let vtdHighCut = """
    Highest input frequency admitted while expanding.

    Everything above the loudest call frequency is noise, and at full expansion \
    all of it becomes audible hiss. Cutting it reduces the hiss without \
    touching the calls. Lower it until the hiss stops rather than until calls \
    thin out — raise it again if a high-frequency species sounds dull.
    """
    static let vtdDuck = """
    How hard the output is ducked as playback speeds up.

    Gain follows rate, so expanded calls stay at full level while rushed \
    background drops away. Also stops anything still sounding from being heard \
    sweeping upward in pitch as the rate ramps.
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
