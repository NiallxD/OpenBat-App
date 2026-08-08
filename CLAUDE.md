# OpenBat — Claude Code Context

iOS bat detector app using the Griff ultrasonic USB microphone (384 kHz sample rate, 192 kHz Nyquist). Targets iOS 18.6. Uses `@Observable` (iOS 17+) throughout — no `@ObservableObject`/`@Published`.

## Project layout

```
OpenBat/
  Audio/
    AudioEngineController.swift   @MainActor @Observable — AVAudioEngine wrapper
    AudioDiagnostics.swift        Published stats struct (sample rate, level, input name)
    DemoFileSource.swift          Demo mode — paced WAV playback standing in for the mic tap
    DemoModeView.swift            Demo file picker (bundled clip + the user's recordings)
  DSP/
    Biquad.swift                  Biquad filter (used by heterodyne)
  Heterodyne/
    HeterodyneProcessor.swift     Real-time heterodyne downmixer
  TimeExpansion/
    TimeExpansionProcessor.swift  Playback-only classic time expansion (pass-through, no framing/selection)
    TimeExpansionSettings.swift   Persisted gain setting, owned locally by WavPlayerView
    AdaptiveTimeExpansionProcessor.swift  LIVE event-triggered time expansion, hangover-delimited events
    AdaptiveTimeExpansionSettings.swift   Persisted gain/hangover/cap/threshold, owned by ContentView
  Spectrogram/
    SpectrogramProcessor.swift    Audio-thread FFT → normalised 0–1 columns via vDSP
    SpectrogramRenderer.swift     MTKViewDelegate — ring texture + seek texture + HistoryBuffer
    SpectrogramView.swift         SwiftUI wrapper with drag-to-scroll gesture
    HistoryBuffer.swift           UInt8 ring buffer, 60 s @ ~90 MB; COW snapshot in O(1)
    FrequencyBandControl.swift    Popover: frequency range + time-window sliders
    RangeSlider.swift             Custom dual-thumb slider
    Spectrogram.metal             Full-screen pass, inferno colormap, ring-buffer UV math
  Classifier/
    PulseDetector.swift           @Observable pulse trigger + background image renderer
    PulseSettingsView.swift       Settings sheet for trigger/display options
    BackgroundDetectionPump.swift Keeps feed() running when the render loop is paused
  FieldGuide/
    SpeciesGuide.swift             Codable schema — GuideSpecies + measurements/morphology/echolocation/conservation/habits
    SpeciesGuideStore.swift        bundled → cached → GitHub raw-JSON resolution, dataVersion-gated
    SpeciesExplorerView.swift      Search bar + globe explorer + region species list (grouped by family)
    SpeciesDetailView.swift        Full species page — header/taxonomy breadcrumb, description, distribution, measurements, echolocation, conservation, habits
    GBIFService.swift              Scientific-name → taxon-key resolution (cached) + tile-overlay factory
    GBIFRangeMapView.swift          MKTileOverlay-backed interactive distribution map
  ContentView.swift               Main screen — GeometryReader proportional layout
  PulseZoomView.swift             Pinch-zoom + pan leaf view over the captured pulse render
  PulseStatsViews.swift           Stat row/column leaf views + shared staleIDSeconds
  LiveStatusViews.swift           Tuning pill, mic-status pill, amplitude meters
  LiveActivity/
    BatDetectorAttributes.swift   ActivityAttributes + ContentState — BOTH targets
    BatActivityPalette.swift      Logo navy/orange — BOTH targets
    LiveActivityController.swift  Start/update/end + update-budget coalescing (app only)
  DiagnosticsView.swift           Debug sheet
OpenBatWiget/                    Widget extension target
  OpenBatLiveActivity.swift       Lock screen + Dynamic Island views
  OpenBatWidgetBundle.swift       @main WidgetBundle
```

## Architecture

### Audio pipeline
`AudioEngineController.start()` configures an `AVAudioSession` (.playAndRecord, category needed for heterodyne output) at 384 kHz, installs a tap, and calls `bufferSink` for each buffer. `SpectrogramProcessor.process()` runs on the realtime audio thread — no main-actor work there.

`ListenMode`: `.off` / `.heterodyne` / `.adaptiveTimeExpansion` (live capture only) / `.timeExpansion` (file playback only). The live cycle is off → heterodyne → adaptive time expansion → off. Frequency division was **removed** (2026-07-27) — it was a working classic technique but redundant next to the vocoder for continuous monitoring, and it sounded no better on real recordings. The phase vocoder (`.phaseVocoder`) and the first live snapshot time expansion (`.triggeredTimeExpansion`, `TriggeredTimeExpansionProcessor`) were both **removed** (2026-07-27); live time expansion returned the same day as `.adaptiveTimeExpansion` (see below).

**Live adaptive time expansion** (`AdaptiveTimeExpansionProcessor`, 2026-07-27): states idle → capturing → draining → idle. An on-thread energy trigger (12 kHz detection high-pass, tracked noise floor) opens an event; every sample from a 2 ms pre-roll onward is emitted in order into the 48 kHz ring, which at 384 kHz input is 8× expansion with no resampling. Further pulses arriving within `hangoverMs` (default 60) extend the same event, so bursts and feeding buzzes merge into one contiguous stretch instead of fragments. The event closes 5 ms after the level last exceeded the release threshold, or at `maxBufferMs` (default 200), whichever comes first.

**The gate is two-threshold (hysteresis), and it has to be.** Opening needs `thresholdDB` (default 12) over the floor; *staying open* needs only `releaseDB` (default 6). A single threshold clipped the end off every call — the decaying tail of a downsweep drops below the attack threshold while still being real, audible signal, so the close point landed early and no plausible fixed post-roll covered it. `postRollMs` is 5 ms of margin around the release point, not the mechanism that finds the call end. If endings still sound truncated, lower `releaseDB`; if events run on into background noise, raise it.

Two invariants in that file are load-bearing and documented there at length — read them before touching it:
1. **Nothing is selected out or discarded within an event.** Emission runs through a delay line (`emitDelaySamples = hangover − postRoll`) so the tail can be trimmed without ever retracting an emitted sample. An eager emitter that trims by dropping would click *and* would be the thing the patent covers.
2. **Capture stops while the ring drains.** An event of length L takes 8L to play and the processor is deaf throughout. Under sustained calling it falls behind and misses material — deliberately, like a Pettersson D240x. Making it keep up (capturing into a second buffer while draining the first) would turn it into continuous real-time monitoring with selective retention, i.e. US 8,599,647's subject matter. The deafness is the feature.

Because search-phase inter-pulse intervals (~50–150 ms) exceed the hangover, isolated search pulses each get their own tight event that drains inside the following gap; the hangover only merges approach phase and buzzes.

**Sampler mode** (`samplerEnabled`, off by default, added 2026-08-07) replaces the trigger half of that with "play one call every `samplerIntervalSeconds` (5) and let the rest go by". The first pulse after the interval doesn't open an event — it arms a `samplerScanMs` (150) scan; the loudest block in the scan is the specimen; its boundaries are found by walking outward through `blockLevels` (a per-block RMS history parallel to `blockGains`); the whole span is emitted as a **fixed-close** event (`eventFixedClose`, which also bypasses `emitDelaySamples` — nothing can extend it, so there is nothing for the delay line to hold back).

Measured over the five-pass corpus in `TimeExpansionTuning/`: **100% of sampled calls arrive complete** (emission starts at or before the onset and ends at or after the true end), at 19 ms of capture per sample, 37% of which is call rather than background. Three things get it there, each with a number behind it — see `FINDINGS.md`'s 2026-08-07 addendum, and don't relax any of them:
- **Commit only once the specimen has stopped sounding.** The forward walk can only reach blocks already written, so committing when the scan window expires clips the tail systematically: 86% whole with the wait, **7%** without.
- **Two consecutive quiet blocks end the walk, not one** (`samplerQuietBlocks`). Calls dip inside themselves: one block gives 79%, two gives 100%.
- **Boundary is `max(peak − 40 dB, noiseFloor × releaseFactor)`.** The floor term does the work; raising its multiplier truncates the call's quiet edges (57–64% whole at 9–15 dB over floor) rather than tightening the capture.

Both invariants hold. Selecting *which* event to play is the same kind of choice the trigger already makes, over the same delay line the pre-roll already reads backwards from — invariant 1 forbids selecting samples *within* an event, and every sample between the chosen boundaries is still emitted in order. Invariant 2 holds a fortiori: the mode is deaf while draining and idle by design for the rest of the interval.

`missedCount` in this mode counts calls deliberately let through, including the runners-up in each scan window, so it climbs fast and means nothing is wrong — the tuning overlay relabels it "Passed" and drops the orange, and the pill's explainer gains a sampler-specific paragraph. `hangoverMs` is unused here and its slider is disabled.

**A caution about `TimeExpansionTuning/FINDINGS.md`.** Its §2 (and anything downstream of §2, including the `E/F/G/H` candidate rankings' "decay kept" column) rests on `clip.true_extent`, which thresholds a 32-sample envelope against a level derived from the 128-sample *block* RMS and then takes the last frame above it in a 60 ms window. Those scales don't match, so it returns ~60 ms — its window cap — for essentially every call, 1.3 ms ones included. Use `extent.py` instead. In particular §2's recommendation of a 30 ms post-roll is wrong: measured properly, the shipped 5 ms already captures the whole call, and `post30` only adds background (call content 37% → 8%).

`missedCount` tallies pulses that triggered while the ring was still draining (debounced by `missedPulseGapMs` = 5 ms, or it would tick once per 0.33 ms detection block). `AdaptiveTimeExpansionStatePill` shows it in red once non-zero and is tappable for a plain-language explainer of why the mode isn't real-time. Treat that counter as the honest cost of invariant 2 — if it ever reads zero during a buzz, something has broken.

**Why time expansion is the mode that matters.** Every frequency-only mode maps pitch down while leaving duration alone, and that sounds worse than it should for a *temporal* reason, not a spectral one: an EPFU call is ~5 ms, so transposed to 5 kHz it is ~25 cycles. Pitch/timbre perception needs ~6-10 cycles just to register a pitch and far more to resolve structure within a sweep, so a perfectly transposed call still lands as a click. Stretching 5 ms to 40 ms puts that structure inside the ear's temporal resolution. No amount of frequency-domain work substitutes — don't go looking for a cleverer transposition.

`.timeExpansion` is `TimeExpansionProcessor` (`TimeExpansion/`), used **playback-only**, in `PlaybackEngine`/`WavPlayerView` — never in `AudioEngineController`, which treats this case identically to `.off`. It's classic time expansion done the safe way: every sample of the recording is played back untouched, just slower (8×, since the file's native 384 kHz gets paced out at the 48 kHz output rate — see `PlaybackDriver.start`'s `paceRate`). No framing, no selection, no discarding — the processor itself is a dumb pass-through with no idea it's being fed slowly. This is exactly the OLD, unpatented technique the WA patent's own background section describes; it only works for playback because the whole file already exists on disk, unlike live capture, which can't pace itself slower than real time without falling permanently behind.

### Demo mode

**Demo mode with listening OFF cannot run in the background.** `startDemoCapture` only
calls `configureSession` when `isListening` — with no listen mode there is no graph and no
reason to touch the audio session. But no *active* audio session means
`UIBackgroundModes: audio` grants nothing, so iOS suspends the app on background/lock: the
`DemoFileSource` timer, `BackgroundDetectionPump` and Live Activity updates all stop, and
resume on return to foreground. It looks exactly like a broken background path and isn't.
To exercise anything background-related from a demo, turn on heterodyne or ATE first, or
test with the mic.


`DemoFileSource` feeds a WAV into the pipeline in place of the microphone tap, wall-clock paced at the file's own sample rate. Entered from Diagnostics → Demo (picker: the bundled clip at the top, then the user's recordings), left via Diagnostics → End Demo or by quitting. The bundled clip is any `Demo*.wav` under `OpenBat/` — discovered by prefix, not a hardcoded name, so it can be re-stitched and renamed freely (currently `Demo/Demo-MYCA-2026.wav`, 11.3 s, 384 kHz mono, 8.7 MB). The status pill reads "Demo" whenever demo mode is armed, running or not.

`AudioEngineController.start()` branches to `startDemoCapture()` when `demoURL` is set. That path **never touches `engine.inputNode`** — no tap, no input unit, no mic permission, and a `.playback` session only when listening needs the speaker. That's what makes the whole pipeline runnable in the simulator, which is the main reason to reach for this beyond demos. The live tap and the demo source share `consume(_:)` for stats; everything below the tap already reads `buffer.format.sampleRate` off the buffer, so a demo clip at any rate drives the pipeline correctly (just with that file's Nyquist).

Two things are deliberately off in demo mode:
- **Recording is blocked** (`AudioRecorder.setBlocked`) — a demo pass isn't field data, and saving one would put a synthetic `Recording` in Sessions, eligible for upload and re-feedable into the demo. The queue-local `blockedQ` drops audio before the pre-roll so demo audio can't leak into the next real recording.
- **No session is opened** — `startDetecting` refuses one while `isDemoMode`, so a demo leaves no GPS track and no Session row.

Pacing is load-bearing, not cosmetic: `AdaptiveTimeExpansionProcessor`'s drain-deafness and `missedCount` are wall-clock behaviours, so feeding faster than real time would make that mode look better than it is. `tick()` derives its target from elapsed time rather than counting timer fires, capped at `maxBuffersPerTick`, so jitter can't accumulate into drift and a main-thread stall can't be followed by a burst.

### ATE background expander

An event carries the background it was recorded against — the pre-roll, the gaps inside a merged burst, the tail — and at 8× that background is stretched too, which is what makes it audible as hiss rather than passing as a click. `AdaptiveTimeExpansionProcessor`'s expander pulls it down. On by default (threshold 8 dB over the tracked floor, depth −18 dB, release 16 ms captured).

**It does not breach invariant 1.** That invariant forbids *selecting or discarding* samples within an event, because sample selection is what US 8,599,647 covers. This is a gain envelope: every sample still emitted, in order, same count, same time base. `emitAvailable` already multiplies by `fadeWeight` for the ramps — same kind of operation, different curve.

**Expander, not gate, deliberately.** A hard gate would silence anything under threshold, which is the amplitude-domain version of the truncation `releaseDB`'s hysteresis exists to prevent — a decaying tail falls below any fixed threshold while still being real signal. Gain slides between full and `expanderDepthDB` instead.

Three things here are load-bearing and were each established by measurement:

- **Attack is instant; only release is smoothed.** A smoothed attack (0.35/block) measured 5 blocks — 1.67 ms captured — to reach −1 dB, against a MYCA call of ~1.3 ms. It would have been still opening when the call ended: the same defect as a ramp longer than the pre-roll. Anything that fades in over the length of a bat call is wrong.
- **The envelope is interpolated between block centres** (`expanderGain(at:)`). This is what makes the instant attack safe: held piecewise-constant, the gain would step by the full depth at a block boundary — a true discontinuity between two output samples, which time expansion does *not* soften. Interpolation spreads any change over ~2.7 ms heard. Measured worst adjacent-sample jump: 0.059 dB.
- **Gains are stored one block early** (`totalWritten/detectBlock - 2`), i.e. one block of lookahead. Detection can only report a call after the block containing its onset has finished, so without it the first block of every call sits under the previous closed gain.

**The expander is held fully open while the event's own hold condition (`releaseFactor`) is true**, and only then starts releasing. This is what resolves the hiss-vs-tail tension rather than trading it off. The hysteresis behind `releaseDB` is already tuned to the exact question the expander needs answered — is this still real signal, or background? — so reusing it means the expander can never be more aggressive about a call's end than the event logic is, and how fast it closes afterwards becomes a free choice.

That freedom is the point: the first version used an independent threshold with a slow (16 ms) release to protect tails, which left the post-roll — a few ms of captured background sitting directly after every call, tens of ms once stretched — at about **−2 dB**, i.e. barely attenuated. That was the audible hiss. With hold-open, the release drops to 2 ms captured and the same point measures **−16.3 dB**, while every block above the hold threshold stays at full gain.

### Live Activity (lock screen)

`LiveActivity/` holds the lock-screen card: last captured pulse image on the left, species
ID and stats on the right, in the logo's navy (`#24334D`) and orange (`#E9831D`).
`BatDetectorAttributes.swift` and `BatActivityPalette.swift` are members of **both** the
app and widget targets; `LiveActivityController.swift` is app-only and `OpenBatWiget/` is
widget-only.

Target wiring, all of which is easy to get silently wrong:
- The widget target is named **`OpenBatWigetExtension`** and its folder is
  **`OpenBatWiget/`** — missing the `d`, a typo baked in when the target was created.
  Cosmetic (it only shows in the target list and the `.appex` name), but don't "correct"
  the path in the pbxproj without renaming the folder to match.
- `LiveActivity/BatDetectorAttributes.swift` and `BatActivityPalette.swift` live in the
  app's synchronized folder and reach the widget target only through an explicit
  `PBXFileSystemSynchronizedBuildFileExceptionSet`. Moving or renaming either file
  requires updating that list.
- The App Group `group.Niall.OpenBat` is still declared in both entitlements files but
  **nothing reads it** now the pulse image is gone. Harmless, and left in place because
  re-provisioning to remove it is churn for no benefit — but don't take its presence as
  evidence something depends on it.

**A Live Activity is not a display — it's a budgeted message channel.** `Activity.update`
is rate-limited by iOS and over-spending gets later updates dropped silently, with the card
simply freezing. So the card tracks **passes**, not columns: `PulseDetector.onPassFinalized`
pushes an update, a 15 s heartbeat covers the running counters, and both are coalesced
behind a 3 s minimum in `LiveActivityController.schedule`. States that differ only in
`updateTick` are dropped before reaching ActivityKit. Don't add a per-pulse or per-frame
update path — there is no version of that which works.

**The no-op guard does not make the heartbeat free.** It only drops ticks where nothing
changed, and `pulseCount` increments on every pulse — so while bats are about, every
heartbeat sends. A 5 s heartbeat (the original value) overran the budget within minutes of
real detection and the card froze with no error. 15 s is the compromise; treat any proposal
to shorten it as a budget decision, not a responsiveness one.

**Staleness is computed app-side (`isIDStale`/`isPulseStale`/`isDetectionRecent`), never
in the widget from `Date()`.** This is the non-obvious consequence of the no-op guard: once
the bats stop, `lastDetectionDate` stops changing, so every heartbeat state compares equal
and is correctly dropped — meaning the widget never re-renders and a body that computed
"is this stale?" itself would never get the chance to notice. The card would sit there with
a lit dot and live-looking numbers indefinitely. Putting staleness *in* the state makes
crossing the threshold a change, which produces exactly one update at the moment it
matters. `heartbeatInterval` (5 s) is therefore the granularity of those transitions, and
wants to stay below `activeDotSeconds` (8 s).

The ID and the stats age on **separate clocks** — `lastPassDate` and `lastDetectionDate`
respectively — mirroring the split between `SpeciesStatCellContent` and `PulseStatValues`
in the app. Collapsing them blanks live stats during a run of pulses that never clear the
pass confidence gates.

**There is no animation loop.** WidgetKit disables repeating animations, so a genuinely
throbbing "live" icon isn't available. The two liveness cues are `Text(timerInterval:)`
in the header, which ticks in the widget process for free, and transitions keyed off
`updateTick`, which fire only when an update actually lands. `.repeatForever` here
silently does nothing.

**No spectrogram on the card, deliberately (dropped 2026-08-07).** It was built — PNG into
the App Group container, filename in `ContentState`, alternating slots — and removed. Two
reasons. At lock-screen size a pulse render told a glance almost nothing; and
`PulseImageRenderer` emits a *wide, short* image, so any well that isn't that shape crops
the call rather than showing the sweep. If it ever comes back: use `.fit`, never `.fill`,
and give the well a definite size so the image can't drive the card's height.

**Detection while backgrounded is `BackgroundDetectionPump`'s job** — see its own section
below. Before it existed the card froze the moment the screen locked, which looked like a
Live Activity bug and wasn't.

### Background detection pump

`Classifier/BackgroundDetectionPump.swift` — a 20 Hz main-thread timer that runs the same
drain-and-feed loop as `SpectrogramRenderer.draw(in:)`, minus the drawing, while the app is
backgrounded or the screen is locked.

It exists because `PulseDetector.feed()` is normally called *from inside* `draw(in:)`, off
the MTKView's CADisplayLink, which the system pauses on background/lock. Audio keeps
flowing and `SpectrogramProcessor.process()` keeps producing columns, but with nobody
draining them they hit `maxPendingColumns` and are discarded — so detection silently
stopped the moment the screen went off.

It can be this small because `feed()` reads audio only through `pcmProvider`; it never
touches the renderer's `liveHistory`, which serves the display and scrollback. So no Metal,
no textures, no renderer handle. The spectrogram simply has a gap for the backgrounded
stretch, which is correct — there was no screen.

**Exactly one owner drains at a time**, keyed off `scenePhase` in ContentView: `draw(in:)`
while `.active`, the pump otherwise. `drain()` is lock-guarded and hands out disjoint
batches, so the brief overlap on a phase transition costs at most a few columns going to
one instead of the other — never a double-feed. The pump also stops on
`onChange(of: audio.isRunning)`, which covers the interruption path that deliberately
bypasses `stopDetecting()`.

If the argument list in `draw(in:)`'s `feed()` call changes, change it here too — the two
are duplicated on purpose rather than factored into a shared helper, because the render
path also batches magnitudes for the ring upload and merging them would put Metal
bookkeeping on the background path.

### Live tuning overlay

`Tuning/LiveTuningOverlay.swift` — a floating, draggable, tabbed card (Het / ATE / Pulse / Disp) that sits over the detector screen while everything keeps running. Opened from Diagnostics → Open Tuning Panel. Position and collapsed state persist in `@AppStorage`.

**`showTuningOverlay` must never be added to `ContentView.menuIsOpen`.** That flag pauses the Metal render loop and sets `processor.suspended`; the overlay exists precisely to tune against a *running* pipeline. Same deliberate exclusion as `showBand`/`showPulseView`.

`TuningSlider` takes two closures, and the split is the design: `onLive` fires every drag frame and writes the **DSP object's** lock-guarded scalar (picked up next buffer — you hear it under your thumb); `onCommit` fires once on release and writes the **persisted settings object**. Binding straight to the settings object would do a `UserDefaults.set` plus an `@Observable` invalidation per frame, on the main thread, with the render loop live behind it — the cost `FrequencyBandControl.localNoiseFloor` exists to avoid.

Revert snapshots everything on open (`LiveTuningSnapshot`, one flat struct so a knob can't be added to a tab and silently not captured). Restoring bumps `revertToken`, which re-`id`s the tab subtree — necessary because `heterodyne.gain` is not `@Observable`, so restoring it changes nothing SwiftUI watches.

**ATE `preRollMs`/`postRollMs`/`rampMs` are now live-tunable** (`AdaptiveTimeExpansionProcessor`, previously `private static let`). The `rampMs ≤ postRollMs` invariant was hand-maintained while both were compile-time constants; it is now enforced in the setters *and* in `recomputeDerived`. `apply(to:)` writes post-roll **before** ramp — the reverse order clamps a new ramp against the old post-roll and silently loses a legitimate increase.

The overlay warns when `rampMs > preRollMs`, which attenuates every call onset: the onset lands `preRoll/ramp` along a **smoothstep** fade (`x²(3−2x)`, `fadeWeight`), not a linear one. At the shipped 2 ms / 3 ms that is 20/27 → −2.6 dB; computing it linearly would wrongly say −3.5 dB.

### Patent notes

- **US 8,599,647** — "Method for listening to ultrasonic animal sounds",
  Wildlife Acoustics, filed 2011-05-10, priority 2010-05-10, **active, expires
  2032-08-07**. Claim 1 (claim 2 is the same thing worded for echolocation
  specifically) reads, in full:

  > obtaining a plurality of input samples at an input sample rate, the
  > plurality of input samples including at least one sequence of samples
  > corresponding to an instance of an intermittently occurring animal sound
  > signal; receiving a frame including at least two of the plurality of input
  > samples; selecting a fraction of the samples as output samples, the
  > fraction of the samples including a sample containing the at least one
  > sequence of samples corresponding to an instance of an intermittently
  > occurring animal sound signal; and transmitting the output samples at an
  > output sample rate slower than the input sample rate.

  **Read this before repeating any non-infringement claim in this repo.** Until
  2026-08-07 the notes here and in `AdaptiveTimeExpansionProcessor` rested on a
  one-line paraphrase ("real-time frame-based sample selection"), and the
  paraphrase is narrower than the claim:

  - **Claim 1 has no "within an event" limitation.** Invariant 1 (nothing
    selected or discarded *inside* an event) avoids one narrow reading, but the
    claim asks only whether a *fraction* of the samples was selected as output.
    Opening a gate and emitting only that span is selecting a fraction.
  - **Claim 1 has no real-time limitation.** Invariant 2's deafness distinguishes
    the mode from the patent's *background* discussion, not from its claims, and
    background statements don't limit claims absent a clear disclaimer.
  - On a plain reading **both live modes — the default ATE trigger and sampler
    mode — map onto all four elements** (384 kHz in; 128-sample detection block
    as the frame; a selected span containing the call; 48 kHz out). Sampler mode
    is not the exposure; live event-triggered expansion is.

  What survives the actual text: **`.timeExpansion` file playback plays every
  sample of the recording, so element 3 is not met — nothing is selected.** That
  is a real distinction, and it's the reasoning in the audio-pipeline section
  above. Heterodyne is untouched (no slower output rate).

  The D240x-style detector described in the patent's own background may itself
  read on claim 1, but that is an *invalidity* argument — a defence to be
  funded, not a shield to rely on.

  **Open, not resolved:** this wants a freedom-to-operate opinion from a patent
  attorney covering the existing ATE mode, not just sampler mode. Nobody in this
  repo is qualified to close it, and no code comment here should be written as
  though it has been.
- **US 8,995,230** (FFT→zero-crossing conversion) — not currently relevant:
  `CallAnalysis.swift`'s Fmax/Fmin refinement uses only a forward, zero-padded
  FFT with parabolic-interpolation peak sharpening, no inverse FFT. Worth a
  targeted look *if* an inverse-FFT-based Fmax refinement is ever added there.

### Spectrogram rendering — dual-path Metal

**Live path** (`ringTexture`, 2560 × 512, ~5 MB):  
Columns written incrementally via `uploadToRing()`. `displayHead` glides forward with a feed-forward + feedback smoothing loop (latency ≈ 30 ms) for stutter-free scrolling. Ring wraps with `fmod` UV math in the Metal shader.

**Scroll path** (`seekTexture`, 2048 × 512, ~4 MB):  
When the user drags, `liveHistory.snapshot()` freezes a COW copy (O(1)). `uploadSeekSlice()` fills seekTexture from the snapshot for the current scroll position. New audio keeps writing to `liveHistory`. Return-to-live discards snapshot.

**HistoryBuffer** stores UInt8 columns (0–255) in ring layout `[col * binCount + bin]`. `rowMajorSlice(offset:count:)` returns `[Float]` in Metal row-major layout `[bin * count + col]` for single `texture.replace()` uploads.

### Triggered display mode
`PulseDetector.triggeredDisplayMode = true` → `SpectrogramRenderer` skips `uploadToRing` / `liveHistory.append` when `pulseDetector.isInPulse == false`. Silent gaps are dropped; the ring fills with back-to-back pulses (classic triggered-view style). `isInPulse` is set at the END of `feed()` so the renderer reads it one column ahead (≈1 ms lag — negligible).

### Pulse detector
`PulseDetector.feed()` is called per drained column on the main thread. On the trailing edge it:
1. Reads `liveHistory.rowMajorSlice()` on the main thread (safe, produces a value-type `[Float]`)
2. Dispatches heavy computation (peak scan, pixel render, `CGImage` creation) to `captureQueue` (background)
3. Posts results back on `DispatchQueue.main` to update `@Observable` properties

Capture geometry: captures are *deferred* — on the trailing edge the detector arms a pending capture and waits until enough trailing PCM exists, then renders a fixed `displayWindowMs` window from the raw PCM ring (`PulseImageRenderer`, fftSize 512 / hop 64) with the onset locked at `onsetFraction` = **25% from the left**. The classification window is cut separately per the model's `ModelInputSpec` (NABat: 50 ms, onset 30%).

Frequency crop uses **relative threshold** (50% of peak value across pulse columns). Avoids the absolute-threshold failure where broadband noise floor fills all bins.

### Inferno colormap
Defined identically in `Spectrogram.metal` (GPU) and `DisplayPalette.swift`'s `DisplayColormap` enum (CPU). 6-stop piecewise linear: near-black → dark purple → medium purple → dark orange → bright orange → pale yellow. Keep these in sync.

## Key constants

| Symbol | Value | Notes |
|--------|-------|-------|
| `windowLen` | 512 | Hann-windowed, raw samples per column |
| `fftSize` | 2048 | zero-padded from `windowLen` — drives bin count, not hop |
| `hopSize` | 256 | 50% overlap (of `windowLen`) |
| `binCount` | 1024 | `fftSize / 2` |
| `columnsPerSecond` | 1500 | at 384 kHz: `384000 / 256` (hop drives this, not fftSize) |
| `maxVisibleColumns` | 2048 | seek texture width |
| `ringTextureWidth` | 2560 | `maxVisibleColumns + 512 guard` |
| `liveHistory capacity` | 90 000 | 60 s × 1500 cols (`historySeconds` default in `SpectrogramRenderer`) |
| `minDB / maxDB` | −90 / −20 dB | display dynamic range |
| Metal max texture dim | 16 384 | limits single-texture history |

## SourceKit false positives

SourceKit frequently reports spurious errors like "Cannot find 'UIKit' in scope", "Cannot find type 'SpectrogramProcessor' in scope", "Reference to member 'shaderRead' cannot be resolved", etc. These are **indexing artifacts** — the project builds and runs correctly. Ignore them.

## Build/test policy

Don't boot a simulator or run `xcodebuild test` unless it's genuinely necessary (e.g. no other way to check a fix) — the user runs actual builds/tests themselves on-device or in their own simulator session. To check for compile errors, use a **build-only** invocation that doesn't launch a simulator instance:

```
xcodebuild -project OpenBat.xcodeproj -scheme OpenBat -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

This compiles against the simulator SDK without booting one. Prefer this over picking a concrete `-destination ... ,name:/id:` simulator, which will boot it.

## Pending / future work

- **NABat ML v2.0 integration**: Convert USGS Python model to CoreML. Notes in `mlconversion.md`. Prior-based species filtering: disabled species → weight=0 → renormalize remaining softmax outputs.
- **Stats panel** (top 18% of screen): placeholder for species ID output.
- **Pulse log**: store last N captures as a scrollable history in the pulse zoom panel.
- **384 kHz capture verification**: confirm iOS hands the Griff mic's native rate and doesn't silently downsample. Check `diagnostics.isNativeRate` and `diagnostics.actualSampleRate`.
- **Taxonomy browser**: an explorable full taxonomic tree (order → family → genus → species) for the field guide, replacing/complementing the region-grouped-by-family list in `RegionSpeciesView`.
- **Illustrated morphology icons**: `SpeciesDetailView`'s morphology section is text-only; see its own TODO comment.
