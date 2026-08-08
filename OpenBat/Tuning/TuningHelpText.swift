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

    // MARK: Adaptive time expansion

    static let ateGain = """
        Makeup gain on the expanded audio. Playback preserves the input's own \
        level and bat calls are weak, so some boost is normally wanted.
        """

    static let openThreshold = """
        How far above the background a sound must rise to START an event. \
        Raise it if the mode keeps triggering on nothing; lower it if faint or \
        distant calls are missed. Higher means fewer false events but more \
        missed passes.
        """

    static let holdThreshold = """
        How far above the background the sound must stay to KEEP an event \
        open. Deliberately lower than the open threshold: a call's decaying \
        tail drops well below the level that opened it while still being real \
        signal, so a single threshold clips the end off every call. Lower this \
        if endings sound truncated; raise it if events run on into noise.
        """

    static let hangover = """
        How long after a pulse the event stays open waiting for another. Short \
        splits a burst into choppy fragments; long merges them into one \
        stretch — but every extra millisecond here costs eight of playback, \
        all of it deaf. Search-phase gaps are mostly longer than this on \
        purpose, so isolated calls each get their own tight event.
        """

    static let maxEvent = """
        Hard ceiling on one event's length, whatever the hangover is doing. \
        200 ms of capture is 1.6 s of playback and the whole of it is deaf — \
        so raising this to hear a long buzz in full costs you everything that \
        happens while it drains.
        """

    static let samplerEnabled = """
        Plays ONE call every few seconds instead of chasing every pulse. When a \
        call arrives it keeps listening for a moment longer, picks the \
        strongest one it heard, works out where that call actually began and \
        ended, and plays the whole of it. Everything else goes by. Use it when \
        the normal mode is catching pulses raggedly — one call heard properly \
        beats five heard in pieces.
        """

    static let samplerInterval = """
        How often a call is sampled, timed from the last one played. Between \
        samples the mode is deliberately quiet, so the interval also sets how \
        much of the pass you let through untouched. It can't go below the \
        playback time of the sample itself — a 200 ms capture takes 1.6 s to \
        play.
        """

    static let samplerScan = """
        How long to keep listening for a better call before committing to the \
        one it plays. Search-phase calls come 50–150 ms apart, so 150 ms \
        usually offers two or three from the same pass to pick between. Zero \
        means the first pulse always wins, which is what the normal mode does. \
        The cost is only latency, and you are already listening to the past.
        """

    static let preRoll = """
        How much audio from before the trigger is included, so the call's \
        onset isn't lost. Detection can only report a call once the block \
        containing its start has finished, so without pre-roll the attack is \
        already gone. Keep it tight — every millisecond here is eight more of \
        playback.
        """

    static let postRoll = """
        Margin kept after the call has decayed past the hold threshold. This \
        is margin, not the mechanism that finds the call's end — the hold \
        threshold does that. It only has to cover the detection block and the \
        fade, so it stays short.
        """

    static let ramp = """
        Fade applied at each end of an event so it never starts or stops on a \
        step. It cannot exceed the post-roll — the slider stops there — or the \
        fade-out would eat call signal instead of tail margin. Watch the \
        pre-roll too: a ramp longer than the pre-roll is still fading in when \
        the call arrives, so every onset comes in attenuated.
        """

    static let expanderEnabled = """
        Pulls down the background an event carries around the call — the \
        pre-roll, the gaps inside a merged burst, the tail. Slowed down, that \
        background is stretched too, which is what turns it into audible hiss \
        instead of a passing click. Nothing is removed: it is a volume change \
        only, and every sample is still played.
        """

    static let expanderThreshold = """
        How far above the background a sound must sit to pass at full volume. \
        Between the background and this, volume slides down smoothly rather \
        than switching off, so a decaying tail fades instead of cutting out.
        """

    static let expanderDepth = """
        How far down the background is pushed. Zero turns the expander off. \
        Deeper is quieter between calls, but past a point the sense of the \
        space goes with it and calls start to sound disembodied.
        """

    static let expanderRelease = """
        How quickly the expander closes once a sound has ended. It cannot cut \
        a tail short: the expander is held fully open for as long as the hold \
        threshold says the signal is still real, so this only starts counting \
        after that. Short is usually what you want — the few milliseconds of \
        background after each call become tens of milliseconds once slowed \
        down, and that is most of the hiss. Lengthen it only if call endings \
        start to sound like they are being ducked. The second figure is what \
        it becomes once slowed down.
        """

    static let ateState = """
        Idle — waiting. Capturing — an event is open and recording. Draining — \
        the event is playing out, and capture is deaf until it finishes.
        """

    static let ateEvents = "Events played since this listen mode started."

    static let ateMissed = """
        Pulses that arrived while a previous event was still playing out. Not \
        a fault — the mode is deaf while draining, deliberately, and that is \
        what keeps it a simple slowed-down recording rather than something \
        cleverer. Treat this as the honest cost of that: if it reads zero \
        during a feeding buzz, something has broken.

        In sampler mode this counts calls deliberately let through, including \
        the runners-up in each scan window, so it climbs fast and means \
        nothing is wrong.
        """

    static let ateOverflow = """
        The output buffer filled before it could drain. Should stay at zero. \
        A non-zero count means the audio output stalled, not that a setting is \
        wrong.
        """

    static let ateExpansion = """
        How much slower the audio plays than it was captured, computed from \
        the real capture rate rather than assumed. 384 kHz in and 48 kHz out \
        gives 8×.
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
