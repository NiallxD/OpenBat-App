# OpenBat — Context

**This is where the project's history and reasoning live.** Code comments say
what the code does and which rules must hold; this file says *why*, what was
tried and rejected, and what a measurement actually showed.

Read the relevant section before changing anything in the audio pipeline, the
upload path, or the Live Activity. Most of what's here was expensive to learn.

**Companions:**
- `CLAUDE.md` — the short list of rules that must hold, and build/test policy.
- `HOW_IT_WORKS.md` — plain-language explanation of each system, for learning
  the codebase.
- `CODEBASE_FUNCTIONS.md` — per-function reference.
- `TimeExpansionTuning/FINDINGS.md` — the raw measurement corpus behind §4.

---

## Contents

1. [Timeline](#1-timeline)
2. [Settled decisions](#2-settled-decisions)
3. [Listening modes: what was tried](#3-listening-modes-what-was-tried)
4. [Adaptive time expansion: the measurements](#4-adaptive-time-expansion-the-measurements)
5. [Patent notes](#5-patent-notes)
6. [Capture and audio session](#6-capture-and-audio-session)
7. [Spectrogram and display](#7-spectrogram-and-display)
8. [Detection tuning](#8-detection-tuning)
9. [Classification](#9-classification)
10. [Recording and storage](#10-recording-and-storage)
11. [Privacy, consent and upload](#11-privacy-consent-and-upload)
12. [Live Activity and background](#12-live-activity-and-background)
13. [Concurrency and SwiftUI performance](#13-concurrency-and-swiftui-performance)
14. [Target and build wiring](#14-target-and-build-wiring)
15. [The 2026-07-27 review](#15-the-2026-07-27-review)
16. [Open questions](#16-open-questions)

---

## 1. Timeline

Reconstructed from git history. Dates are commit dates.

| When | What |
|---|---|
| Early | Capture validation — prove iOS hands us the Griff's native 384 kHz rather than silently downsampling. `AudioDiagnostics` exists for this and still does. |
| — | Live Metal spectrogram; pulse detection; NABat CoreML classifier. |
| — | AutoID v2: per-model settings, BatDetect2 CoreML model, field-guide range maps, `ContentView` split up, first unit tests. |
| — | Playback engine for saved recordings. |
| — | Review backlog work: GBIF error caching, pulse double-counting, off-main mutation, O(1) history snapshot, deferred pass finalize, zero-byte segment discard, stale GPS rejection. |
| — | WAV player rebuilt: static zoomable spectrogram, call analysis, ticker-wheel controls; unified onto one `STFTGrid` pipeline; calibrated against Kaleidoscope. |
| — | Privacy hardening: consent versioning, anonymous upload architecture, erasure, iCloud→local migration guard. |
| 2026-07-27 | Full adversarial codebase review (7 areas) — see §15. Frequency division, phase vocoder and the first triggered time expansion all removed the same day; adaptive time expansion added. |
| 2026-08-05 | ATE listening-mode tuning investigation (`TimeExpansionTuning/`). Parked: none of the candidates was right by ear. |
| 2026-08-07 | Sampler mode shipped behind a setting; live tuning overlay; demo mode; Live Activity spectrogram built and then dropped. |

---

## 2. Settled decisions

From `openbat-onboarding-consent-upload-spec.md`, which was written for handoff
and marks decisions `[DECIDED]`. These are not open for casual revisiting.

- **No OS permission dialog ever fires cold.** Every one is preceded by an
  in-app screen explaining why. Nothing is requested before the welcome screen
  has been seen.
- **Device identity is app-controlled**, not `identifierForVendor` (which resets
  on reinstall). A UUID generated on first launch and kept in the Keychain, so
  it survives reinstalls. This is what consent records key against.
- **Consent is current state, not an append-only log.** A log of "granted"
  events alone cannot represent withdrawal. Schema: `device_id`,
  `consent_version`, `status`, `granted_at`, `revoked_at`.
- **Consent copy is versioned.** If the wording changes, bump `consent_version`
  so it's always knowable which text a given device actually agreed to.
- **No lossy codec at any stage** of the upload path. MP3/AAC/Opus would defeat
  the purpose of a reference library. FLAC only.
- **Classify before filtering.** The privacy high-pass must never be what the
  classifier sees. (This now holds by construction: ID happens live, upstream,
  on unfiltered audio.)
- **Strip and fuzz at the edge**, and never touch the on-device original.

---

## 3. Listening modes: what was tried

### Why time expansion is the mode that matters

Every frequency-only mode maps pitch down and leaves duration alone, and that
sounds worse than it should for a *temporal* reason, not a spectral one. An
EPFU call is ~5 ms, so transposed to 5 kHz it is ~25 cycles. Pitch and timbre
perception needs ~6–10 cycles just to register a pitch, and far more to resolve
structure within a sweep — so a perfectly transposed call still lands as a
click. Stretching 5 ms to 40 ms puts that structure inside the ear's temporal
resolution.

**No amount of frequency-domain work substitutes for this.** Don't go looking
for a cleverer transposition.

### Removed, and why

All removed 2026-07-27.

- **Frequency division.** A working classic technique, but redundant next to the
  vocoder for continuous monitoring, and it sounded no better on real
  recordings.
- **Phase vocoder** (`.phaseVocoder`).
- **Triggered time expansion** (`TriggeredTimeExpansionProcessor`, the first live
  snapshot attempt). Live time expansion returned the same day in its current
  form as `.adaptiveTimeExpansion`.

### The live/playback split

`.timeExpansion` is playback-only and `.adaptiveTimeExpansion` is live-only, and
they are genuinely different techniques rather than two settings of one thing:

- **Playback** can play every sample of the file, just slower, because the whole
  file already exists on disk. The processor is a dumb pass-through with no idea
  it's being fed slowly; the pacing lives in `PlaybackDriver.start`'s `paceRate`.
  This is the old, unpatented technique the WA patent's own background section
  describes.
- **Live capture** cannot pace itself slower than real time without falling
  permanently behind, so it must select *when* to listen. That's what makes it a
  different thing legally as well as technically — see §5.

---

## 4. Adaptive time expansion: the measurements

Source: `TimeExpansionTuning/FINDINGS.md`, against five real Griff passes at
384 kHz (MYCA ×2, MYLU, LANO, MYVO; 44–114 pulses each; median inter-pulse
intervals 62–215 ms; median calls 1.3–9.0 ms).

The Python scripts there are block-accurate ports of the real processor: same
128-sample detection blocks, same two-threshold gate, same hangover/post-roll/
max-buffer close logic, same deafness rule, same 8× arithmetic.

### ⚠️ §2 of FINDINGS is measured with a broken instrument

`clip.true_extent` thresholds a 32-sample envelope against a level derived from
the 128-sample *block* RMS, then takes the last frame above it in a 60 ms
window. Those scales don't match, so it returns ~59.5–60.0 ms — its own window
cap — for essentially every call, 1.3 ms ones included, against a documented
median of 3.0 ms.

**Everything downstream of §2 is therefore suspect**, including the "decay kept"
column of the candidate table and the `E/F/G/H` rankings. In particular its
recommendation of a 30 ms post-roll is wrong: measured properly, the shipped
5 ms already captures the whole call, and `post30` only adds background (call
content 37% → 8%).

Use `extent.py` instead — floor is the median of the *same* 32-sample envelope,
and the call ends where the envelope stays below threshold for 8 consecutive
frames. It returns 1.1–3.8 ms calls, consistent with the census.

### What holds

- **The gate must have two thresholds (hysteresis).** Opening needs
  `thresholdDB` (12) over the floor; staying open needs only `releaseDB` (6). A
  single threshold clipped the end off every call — the decaying tail of a
  downsweep drops below the attack threshold while still being real, audible
  signal. `postRollMs` (5 ms) is margin around the release point, not the
  mechanism that finds the call end.
- **Lowering `releaseDB` is not a fix for anything.** At `rel3` the median event
  length becomes *exactly* `maxBufferMs`: the gate latches open on background
  noise and only the cap closes it.
- **Physics ceiling.** At 8× only 12.5% of elapsed time can ever be captured.
  Event overhead floors an event at ~10 ms, so ~12 calls/s is the hard tracking
  limit. The fastest file calls at ~16/s and can never be fully tracked at 8×.
  But sparse clean listening needs only ~4% of elapsed time, so deafness is
  *not* the binding constraint for the mode actually wanted — the old parameters
  were simply tuned as if coverage were the goal.
- **Between-event cadence is real-time, not expanded.** Measured ratio of output
  spacing to 8×-expanded true spacing is exactly 1/8. Within an event the rhythm
  is perfect; between events it is 8× too fast. Not tunable away — it's what the
  deafness costs.

### Rejected by data

- **"Snapshot" philosophy** (cap 500 ms, hangover 80, whole phrases): call
  content collapses to 7–25%, miss runs to 46. At 8× a 500 ms phrase costs 4 s
  of deafness and is ~90% stretched silence.
- **Proportional rest** (rest = k × last playback): regularity CV 0.78 vs 0.41
  for a fixed 200–250 ms rest. Playback lengths vary too much to feel steady.
- **4× expansion**: best coverage (64%) but halves call duration — 1.3 ms calls
  become 5 ms, back in click territory per the cycles argument in §3. Viable as
  a *setting* for long-call species (Nyctalus), not as a default.
- **`hangoverMs = 60` is the worst of both worlds** on this corpus: median IPIs
  of 62–100 ms straddle it, so it repeatedly swallows a whole inter-call gap
  (60 ms of silence played as 480 ms of dead air while deaf) and merges only
  1.1–2.2 calls per event. Full cost of merging, almost none of the benefit.

### Sampler mode (shipped 2026-08-07, off by default)

Play one call every `samplerIntervalSeconds` (5) and let the rest go by. The
first pulse after the interval arms a `samplerScanMs` (150) scan; the loudest
block in the scan is the specimen; its boundaries are found by walking outward
through `blockLevels`; the whole span is emitted as a fixed-close event.

Result: **100% of sampled calls arrive complete**, at 19 ms of capture per
sample, 37% of which is call rather than background.

Three mechanisms get it there, each measured, none of them relaxable:

| Mechanism | With | Without |
|---|---|---|
| Commit only once the specimen has stopped sounding | 86% whole (even at scan 0) | **7%** |
| Two consecutive quiet blocks end the walk, not one | 100% | 79% (one block) |
| Boundary `max(peak − 40 dB, noiseFloor × releaseFactor)` | 100% at 6 dB over floor | 57–64% at 9–15 dB |

The peak-relative drop is insensitive (20/30/40 dB within a few percent), which
is why it's a constant rather than a knob. The floor term does the work.

`missedCount` in this mode counts calls deliberately let through, including
runners-up in each scan window, so it climbs fast and means nothing is wrong.
The tuning overlay relabels it "Passed" and drops the orange.

### The background expander

An event carries the background it was recorded against — pre-roll, gaps inside
a merged burst, tail — and at 8× that background is stretched too, which is what
makes it audible as hiss rather than passing as a click.

- **Expander, not gate, deliberately.** A hard gate would silence anything under
  threshold, which is the amplitude-domain version of the truncation the
  hysteresis exists to prevent.
- **Attack is instant; only release is smoothed.** A smoothed attack (0.35/block)
  measured 5 blocks — 1.67 ms captured — to reach −1 dB, against a MYCA call of
  ~1.3 ms. It would still have been opening when the call ended.
- **The envelope is interpolated between block centres.** Held piecewise
  constant, gain would step by the full depth at a block boundary — a true
  discontinuity between two output samples, which time expansion does *not*
  soften. Measured worst adjacent-sample jump after interpolation: 0.059 dB.
- **Gains are stored one block early** (one block of lookahead). Detection can
  only report a call after the block containing its onset has finished, so
  without it the first block of every call sits under the previous closed gain.
- **Held fully open while the event's own hold condition is true.** The first
  version used an independent threshold with a slow (16 ms) release to protect
  tails, which left the post-roll at about **−2 dB** — that was the audible
  hiss. With hold-open, release drops to 2 ms captured and the same point
  measures **−16.3 dB**.

---

## 5. Patent notes

### US 8,599,647 — "Method for listening to ultrasonic animal sounds"

Wildlife Acoustics, filed 2011-05-10, priority 2010-05-10, **active, expires
2032-08-07**. Claim 1 (claim 2 is the same thing worded for echolocation
specifically) reads, in full:

> obtaining a plurality of input samples at an input sample rate, the plurality
> of input samples including at least one sequence of samples corresponding to
> an instance of an intermittently occurring animal sound signal; receiving a
> frame including at least two of the plurality of input samples; selecting a
> fraction of the samples as output samples, the fraction of the samples
> including a sample containing the at least one sequence of samples
> corresponding to an instance of an intermittently occurring animal sound
> signal; and transmitting the output samples at an output sample rate slower
> than the input sample rate.

**Read this before repeating any non-infringement claim.** Until 2026-08-07 the
notes in this repo rested on a one-line paraphrase ("real-time frame-based
sample selection"), and the paraphrase is narrower than the claim:

- **Claim 1 has no "within an event" limitation.** Invariant 1 below avoids one
  narrow reading, but the claim asks only whether a *fraction* of the samples
  was selected as output. Opening a gate and emitting only that span is
  selecting a fraction.
- **Claim 1 has no real-time limitation.** Invariant 2's deafness distinguishes
  the mode from the patent's *background* discussion, not from its claims, and
  background statements don't limit claims absent a clear disclaimer.
- On a plain reading **both live modes — the default ATE trigger and sampler
  mode — map onto all four elements** (384 kHz in; 128-sample detection block as
  the frame; a selected span containing the call; 48 kHz out). Sampler mode is
  not the exposure; live event-triggered expansion is.

What survives the actual text: **`.timeExpansion` file playback plays every
sample of the recording, so element 3 is not met — nothing is selected.** That
is a real distinction. Heterodyne is untouched (no slower output rate).

The D240x-style detector described in the patent's own background may itself
read on claim 1, but that is an *invalidity* argument — a defence to be funded,
not a shield to rely on.

**Open, not resolved:** this wants a freedom-to-operate opinion from a patent
attorney covering the existing ATE mode, not just sampler mode. Nobody in this
repo is qualified to close it, and no code comment should be written as though
it has been.

### The two ATE invariants

These are design rules the code must keep. They are *not*, on their own, a
clearance argument — see above.

1. **Nothing is selected out or discarded within an event.** Emission runs
   through a delay line (`emitDelaySamples = hangover − postRoll`) so the tail
   can be trimmed without ever retracting an emitted sample. An eager emitter
   that trims by dropping would click.
2. **Capture stops while the ring drains.** The processor is deaf for 8L after
   an event of length L. Making it keep up (capturing into a second buffer while
   draining the first) would turn it into continuous real-time monitoring with
   selective retention.

The background expander does **not** breach invariant 1: it's a gain envelope —
every sample still emitted, in order, same count, same time base. Sampler mode
doesn't either: choosing *which* event to play is the same kind of choice the
trigger already makes, and every sample between the chosen boundaries is still
emitted in order.

### US 8,995,230 (FFT → zero-crossing conversion)

Not currently relevant: `CallAnalysis`'s Fmax/Fmin refinement uses only a
forward, zero-padded FFT with parabolic-interpolation peak sharpening, no
inverse FFT. Worth a targeted look *if* an inverse-FFT-based refinement is ever
added there.

---

## 6. Capture and audio session

- **`.measurement` mode is not optional.** It disables automatic gain control.
  Without it, iOS reshapes ultrasonic levels and every amplitude number in the
  app becomes a lie.
- **`.record` when not listening, `.playAndRecord` when listening.** `.record`
  is the proven 384 kHz path and keeps us off the output mixer; listening needs
  simultaneous output so it has to upgrade, which is a slightly riskier path for
  the rate.
- **Never trust the requested rate.** The delivered buffer's own format is the
  only ground truth; the node's advertised format can disagree with the real
  buffers. Surfacing that gap is the whole point of `AudioDiagnostics`.
- **Session calls must run off the main actor.** `setCategory`/`setActive` are
  synchronous system calls that can block for hundreds of ms while iOS
  renegotiates routing — worse under `.playAndRecord` with Bluetooth options,
  which is exactly what a listen-mode switch engages. On the main actor this
  froze the whole UI, which is why switching mode felt unresponsive.
- **Deactivation must be awaited before reactivating.** `setActive(true)` racing
  an in-flight `setActive(false)` from a just-fired `stop()` made the session get
  stuck renegotiating; mode switches were unpredictably slow or wedged.
- **Only react to device add/remove route changes.** Reacting to *every* route
  change (category, override, configuration) caused a restart storm once
  heterodyne enabled the speaker — the change triggered another change and the
  app hung.
- **Never construct the controller's observers/timers in `init()`.** It's built
  as a SwiftUI `@State` default, an expression SwiftUI may evaluate any number
  of times per view identity, keeping the first result and discarding the rest.
  Registering observers there leaked one per evaluation, and because the run
  loop retains a scheduled `Timer`, the discarded controllers' poll timers kept
  firing forever. That accumulation is what eventually wedged the UI. Setup
  lives in `activate()`, called once from the owning view's `.task`.
- **A record-capable category is set up front, before first start.** The
  session's default playback-only category hides input devices entirely from
  `availableInputs`, so the Griff was invisible (and route notifications
  unreliable) until capture first configured the session.
- **Idle mic plug/unplug is polled, not observed.** Route-change notifications
  are only delivered while the session is active. Polling avoids activating the
  session while idle, which would prompt for permission and interrupt other
  apps' audio.
- **Acoustic feedback has no software fix.** Listening audio played out the
  built-in speaker gets picked back up by the mic and reprocessed as a spurious
  low-pitch "call" layered on the real one. Full echo cancellation risks
  degrading the ultrasonic capture path, so the app only warns and tells the
  user to wear headphones — which is confirmed to fix it.

### Demo mode

- **Demo mode with listening OFF cannot run in the background**, and this is not
  a bug. With no listen mode there is no graph and no reason to touch the audio
  session — and no *active* session means `UIBackgroundModes: audio` grants
  nothing, so iOS suspends the app on lock. The file source, detection pump and
  Live Activity updates all stop and resume on return to foreground. To exercise
  anything background-related, turn on a listen mode first or use the mic.
- **The demo path never touches `engine.inputNode`.** No tap, no input unit, no
  mic permission, and a `.playback` session only when listening needs the
  speaker. That's what makes the whole pipeline runnable in the simulator, which
  is the main reason to reach for it beyond demos.
- **Pacing is load-bearing.** ATE's drain-deafness and `missedCount` are
  wall-clock behaviours, so feeding faster than real time would make that mode
  look better than it is. The tick derives its target from elapsed time rather
  than counting timer fires, so jitter can't accumulate into drift and a
  main-thread stall can't be followed by a burst.
- **Recording is blocked and no session is opened in demo mode.** A demo pass
  isn't field data; saving one would put a synthetic `Recording` in Sessions,
  eligible for upload and re-feedable into the demo.

---

## 7. Spectrogram and display

- **Window (512) shorter than FFT (2048), on purpose.** The window sets time
  smearing, the FFT sets bin count. Zero-padding interpolates a sharp-looking
  frequency axis without costing time resolution, which is the axis that matters
  for a 3 ms call.
- **50% overlap is what makes it look smooth.** An earlier revision briefly ran
  hop == windowLen, and that lost overlap was the main reason the live view
  looked visibly rougher than the zoomed pulse view.
- **Two scales per column, deliberately.** Detection uses a *fixed* −90/−20 dB
  range so trigger sensitivity never silently shifts; the display uses an
  adaptive ceiling that tracks recent loudness. A fixed −20 dBFS ceiling looked
  muted whenever real levels sat well below it.
- **The adaptive ceiling needs a hard floor** (−40 dB). Without one it decays all
  the way down to track ambient noise, stretching the contrast window across
  near-silence and making background hiss look like activity.
- **Backpressure drops the oldest columns.** A main-thread stall (the display
  link can pause mid-frame during UIKit gesture tracking — e.g. dragging the
  noise-floor slider, which is deliberately *not* in the pause list) otherwise
  left the pending array growing unbounded at several MB/s, and `draw()` would
  then synchronously catch up through the whole backlog. Dropping means the
  display jumps straight back to live.
- **PCM reads are anchored by absolute sample index.** "N samples back from now"
  moved with drain batching, which was the old onset-jitter bug. One lock is
  held across the whole mapping: reading the total, releasing, then re-locking
  to read the head let the audio thread advance between the two reads and
  shifted the window by up to an IO buffer.
- **The ring texture is never shifted or copied** — the shader does wrap-around
  UV maths. `displayHead` glides with a feed-forward + feedback smoothing loop
  (~30 ms latency) so scrolling doesn't stutter as audio arrives in lumps.
- **History snapshots are copy-on-write and O(1)**, so starting a scroll-back
  drag doesn't memcpy 90 MB.
- **Columns are batched before upload** — 1–2 `MTLTexture.replace()` calls per
  frame instead of 12–25.
- **The colormap is defined twice** (Metal shader for GPU, `DisplayPalette` for
  CPU-rendered images) and must be kept in sync by hand.
- **NABat's magma colormap is fixed and unrelated** to the user-selectable
  display palette — it has to match what the model was trained on.

---

## 8. Detection tuning

- **`holdOffSeconds` 150 ms → 50 ms.** Field data (`Bat_Walk_27_06_2026`) shows a
  median inter-pulse gap of ~79 ms, so the old default silently dropped more
  than half of a normal pass's calls, starving both the pulse-rate readout and
  the classifier. 50 ms passes typical spacing while still rejecting the closest
  echoes; amplitude does the rest, since echoes return much quieter.
- **`maxGapMs` (6 ms) bridges nulls inside one call.** FM sweeps have amplitude
  nulls; without bridging, one call yielded three fragmented captures.
- **`minFrequencyHz` 15 kHz** rejects wind and handling noise without cutting off
  any bat species.
- **Counting and capturing are deliberately separate.** A feeding buzz (100+/s)
  outruns render-and-classify, but the count and rate readouts must reflect true
  pulse arrivals rather than capture throughput, so only the expensive work is
  rate-limited.
- **The capture gate is released as soon as the image is ready**, before
  classification finishes. When it wasn't, CoreML inference held the gate through
  the inter-pulse gap and every second pulse was skipped, halving the reported
  rate.
- **Captures are deferred and absolutely anchored.** On the trailing edge the
  detector records the onset's absolute sample index and waits for enough
  trailing PCM, rather than snapshotting immediately.
- **`deferTrailSeconds` is computed over `ModelRegistry.all`**, not hardcoded, so
  adding a model with a longer window can't silently truncate its captures.
- **Frequency crop uses a relative threshold** (50% of peak across pulse columns).
  The absolute-threshold version failed whenever a broadband noise floor filled
  all bins.
- **Display refresh is quality-gated and rate-limited.** Within a refresh window
  a better capture can replace a worse one, but a low-quality capture never
  starts a new window. Otherwise the zoom panel strobes unreadably.
- **The pulse's own capture date is used for attribution**, not the display-only
  `lastDetectionDate`, which is gated by quality/refresh logic and can go several
  pulses stale during a burst. A stale date silently excluded real classified
  pulses from a WAV segment's aggregate, reporting NOID even though the in-app
  pass showed a confident species.
- **`isInPulse` is set at the END of `feed()`** so the renderer reads it one
  column ahead (~1 ms lag, negligible) for triggered display mode.

---

## 9. Classification

- **Priors are applied then renormalised.** Without renormalisation the reported
  confidence understates the true posterior and the minimum-confidence threshold
  compares against an arbitrary scale.
- **Raw and adjusted scores are both kept.** The "is this a real, confidently
  classified sound at all" gate uses the model's *unbiased* output; priors only
  decide *which* of the user's enabled species to report once raw evidence has
  established it's a bat call. Letting priors influence the first question would
  let user settings invent evidence.
- **NoID is recorded, not dropped.** A pass whose pulses never clear the
  confidence gates used to vanish with no trace. Recording it as `"NOID"` lets
  the list show "something triggered, we couldn't tell what" instead of silently
  dropping evidence the user did see and hear.
- **Pass finalisation is deferred while classifications are in flight.** A
  classification slower than `passTimeoutSeconds` (cold model load, busy device)
  otherwise arrived after its pass had finalised and reset, and got misattributed
  as the start of a new, usually-NOID pass.
- **BatDetect2's NoID threshold (0.4) is a documented starting point, not a
  verified number.** NABat's 0.57 was verified against the reference pipeline;
  BatDetect2's classifier head is a per-pixel softmax with very different
  dynamics and has not been checked against a labelled noise dataset. Revisit
  when field data exists.
- **BatDetect2 has no noise class, and that's correct, not a gap.** Its
  background probability is summed away into `detection_probs` before OpenBat
  sees per-class scores, so passing `nil` for the noise class name is right.
- **Class orders come from the checkpoints, not from prose.** BatDetect2's
  17-class list was read from the checkpoint's stored `hyper_parameters`; NABat's
  from `training_history_m-1.p`. Scientific names came from NABat's official
  code table and BatDetect2's stored `dwc:scientificName` tags, cross-checked
  rather than guessed — a wrong mapping silently queries GBIF for the wrong
  species, a class of bug this project has hit before.
- **Species complexes are a property of the model**, not of the species, so
  membership lives with the descriptor. A runner-up within 0.20 of the winner
  and inside the same complex marks an *active* ambiguity. Deliberately generous
  — the point is honesty.
- **`LABL` (Lasiurus blossevillii)** isn't in NABat's current code sheet — it's
  been superseded there, but is independently confirmed as the classifier's own
  code for the western red bat.
- **Priors start neutral.** No model ships with baked-in priors; real ones are
  suggested from GBIF occurrence data near the user's location.

---

## 10. Recording and storage

- **Segments are bouts, not calls.** Post-roll resets on every new pulse, so a
  bat giving several passes with short gaps lands in one file rather than
  fragmenting into many.
- **The WAV header is written by hand** (fixed 44 bytes) specifically to preserve
  the 384 kHz rate, which is why every reader in the codebase can assume that
  layout.
- **GUANO is what makes recordings useful elsewhere** — Kaleidoscope, Audacity
  and the NABat pipeline all read it. `Loc Position` is written with no space
  after the colon because a leading space makes some readers show a blank
  latitude.
- **`Species Auto ID` uses the same `PassAggregation` rule as in-app passes**, so
  the file and the app can't disagree about whether a burst was noise,
  unidentifiable, or a species.
- **The storage root is resolved once and stays stable across launches.** Every
  stored path is relative to whichever root was chosen when it was written.
  Resolving per-launch meant a launch where iCloud happened to be unavailable
  (signed out, container not provisioned, or simply not ready that early)
  silently relocated the whole library to local Documents: broken playback,
  blank spectrograms, deletes that removed nothing, and two divergent stores
  accumulating.
- **iCloud→local migration is refused until files are downloaded**, or it would
  move placeholders.
- **The whole-file spectrogram is rendered once when a segment closes** and
  cached as a JPEG, so opening a recording is instant.

---

## 11. Privacy, consent and upload

- **Anonymisation spread across four files is anonymisation nobody can audit.**
  It used to be four pieces — a coordinate helper in the conversion pipeline, a
  GUANO builder beside it, request headers in the uploader, and an object key in
  the client — and *each one independently* had a path that leaked something:
  the header sent the raw coordinate, the GUANO builder copied every source
  field forward, and the object key led with the device id. It is now one module
  with one entry point.
- **Nothing derived from `DeviceIdentity` may appear in upload output.** The
  device id is used exactly once in the whole path — a transient request header
  the Worker checks consent against and discards. It is deliberately not even a
  parameter to the builder.
- **The GUANO key list is an allowlist, never a denylist.** A denylist's failure
  mode is silent disclosure of the field nobody remembered to add.
- **Consent is re-read fresh at retry time**, not cached, since it can change
  between a failed attempt and the network returning.
- **A device token is required, not just the device id.** The app displays the
  device id with a Copy button and invites users to quote it in support
  requests, so it can't also be authority. The token is issued once on first
  `POST /consent`.
- **Erasure mints a fresh device id**, so no future recording can be correlated
  back to what was just erased.
- **Uploads use a background `URLSession`**, which is why the app has a
  `UIApplicationDelegate` at all — SwiftUI apps have none by default, and iOS
  needs somewhere to hand a relaunch that finishes a transfer. It's also why the
  uploader is a singleton rather than something recreated per screen.
- **The derived copy is deleted only once the upload actually succeeds**, and the
  on-device original is never reopened for writing at any step.
- **Nothing uploads on its own.** Contribution is always a deliberate tap;
  retries only re-attempt what the user already asked to contribute.
- **Upload quality-gate thresholds are placeholders**, per the spec — they need
  real data before being treated as tuned.

### ⚠️ Contribution is currently switched OFF

`ConsentStore.uploadContributionEnabled = false`. This is the shipped state, not
a debug flag left on by accident.

The reason: a recording can only be verified as *reference* quality by
non-acoustic identification — visual, or in the hand — and this app has no way
to provide that. Every species tag it produces is its own acoustic AutoID guess,
so contributed recordings would enter a reference library labelled by the very
thing the library is meant to validate.

While it's false: onboarding's consent step is removed, Settings' toggle is
forced off and disabled, and the network clients (`UploadClient`,
`ConsentAPIClient`) are **severed from the Worker as a second, independent
safeguard** — the base URLs are emptied, so even a logic error can't reach the
endpoint. Turning contribution back on means addressing the verification gap
*and* restoring those base URLs.

### Consent versioning

`currentConsentVersion` is `"3.0"`.

- **2.0** made contributions fully anonymous — no device identifier, no display
  name, unconditional location and time fuzzing — and disclosed the consequence
  up front: contributed recordings can no longer be identified or deleted on
  request.
- **3.0** dropped the commercial/licensing use case entirely (research use only)
  and removed the second consent toggle that gated it.

Two rules around it:

- **Bumping the version requires bumping `CURRENT_CONSENT_VERSION` in
  `backend/consent-worker/src/index.ts` in the same deploy.** There's a test
  pinning this (`ConsentVersionTests.currentVersionIsTheExpectedValue`).
- **The check is an exact match, not an ordering comparison.** Any bump is by
  definition a material change, and a stored version that isn't the current one
  — older, or newer through a downgrade — is one this build cannot claim the
  user agreed to. A record saying "granted, version 1.0" while the app presents
  3.0 describes agreement to text this build no longer shows. Recording the
  version and then ignoring it is *worse* than not recording it, because it
  looks like a safeguard.

A user who consented under older wording is re-asked rather than carried
forward, and the UI owes them an explanation that their contributions have
quietly stopped.

### Identity in the upload path — what changed

- **The R2 object key used to lead with `{device_id}/`**, which made every
  uploaded object permanently attributable to the device that sent it (and let
  the erase endpoint sweep a device's recordings). That prefix is gone. Erasure
  now covers what `ConsentAPIClient.eraseConsentRecord` describes instead.
- **`objectID` is a fresh UUID per attempt**, unrelated to the device id *and*
  unrelated to the local `Recording.id` — an earlier version used the latter,
  which is a join waiting to happen between a local library and an anonymous
  archive.
- **`objectKey` is `{YYYY-MM-DD}/{objectID}.flac`, and its date comes from the
  *bucketed* timestamp in UTC**, so the key cannot disagree with the metadata
  inside the file. A retry can leave a duplicate second object (R2 `put` is
  atomic; rare), deduplicated server-side by content hash — a much smaller
  problem than a persistent identifier.
- **Auto-upload and Wi-Fi-only settings were removed.** Contribution is a
  deliberate tap; there is no longer a setting that can upload on your behalf.

### ConsentSync exists because fire-and-forget broke in both directions

`ConsentAPIClient.push` originally had no status check and no retry:

- **Granting while offline** left the server with no record, so uploads were
  refused for a user who had consented.
- **Revoking while offline** left the server still holding "granted" — the
  compliance-relevant direction, and the reason `syncedAt` is tracked per record
  rather than assumed.

### One instance of ConsentStore

There used to be two (one for onboarding, one for `ContentView`). Two live
instances can disagree while offline: `grant()`/`revoke()` on one leaves the
other stale, because the refresh notification only fires when a sync completes.
Consent state has exactly one source of truth (the Keychain), so it now has
exactly one observable representation — `ConsentStore.shared`.

---

## 12. Live Activity and background

- **A Live Activity is not a display — it's a budgeted message channel.**
  `Activity.update` is rate-limited by iOS, and overspending gets later updates
  dropped silently, with the card simply freezing. So the card tracks *passes*,
  not columns: a pass finalising pushes an update, a 15 s heartbeat covers
  running counters, both coalesced behind a 3 s minimum, and states differing
  only in `updateTick` are dropped before reaching ActivityKit. **Never add a
  per-pulse or per-frame update path — there is no version of that which works.**
- **The no-op guard does not make the heartbeat free.** `pulseCount` increments
  on every pulse, so while bats are about every heartbeat sends. A 5 s heartbeat
  (the original) overran the budget within minutes of real detection and the
  card froze with no error. 15 s is the compromise; treat any proposal to
  shorten it as a budget decision, not a responsiveness one.
- **Staleness is computed app-side and put into the state**, never computed in
  the widget from `Date()`. This is the non-obvious consequence of the no-op
  guard: once the bats stop, nothing changes, so every heartbeat state compares
  equal and is correctly dropped — meaning the widget never re-renders, and a
  body that computed "am I stale?" itself would never get the chance to notice.
  The card would sit there with a lit dot and live-looking numbers indefinitely.
- **ID and stats age on separate clocks** (`lastPassDate` vs
  `lastDetectionDate`). Collapsing them blanks live stats during a run of pulses
  that never clear the pass confidence gates.
- **There is no animation loop.** WidgetKit disables repeating animations, so
  `.repeatForever` silently does nothing. The two liveness cues are
  `Text(timerInterval:)`, which ticks in the widget process for free, and
  transitions keyed off `updateTick`, which fire only when an update lands.
- **No spectrogram on the card (built, then dropped 2026-08-07).** It worked —
  PNG into the App Group container, filename in `ContentState`, alternating
  slots — and was removed for two reasons: at lock-screen size a pulse render
  told a glance almost nothing, and `PulseImageRenderer` emits a *wide, short*
  image, so any well that isn't that shape crops the call rather than showing
  the sweep. If it ever returns: use `.fit`, never `.fill`, and give the well a
  definite size so the image can't drive the card's height.
- **Detection while backgrounded is the pump's job.** Before
  `BackgroundDetectionPump` existed, the card froze the moment the screen locked,
  which looked like a Live Activity bug and wasn't: `feed()` is normally called
  from inside `draw(in:)`, off the display link, which the system pauses.
- **Exactly one owner drains at a time.** `drain()` is lock-guarded and hands out
  disjoint batches, so the brief overlap on a scene-phase transition costs at
  most a few columns going to one owner instead of the other — never a
  double-feed. The pump also stops on `audio.isRunning` changing, which covers
  the interruption path that deliberately bypasses `stopDetecting()`.
- **The pump's `feed()` call is duplicated from `draw(in:)` on purpose**, rather
  than factored into a shared helper, because the render path also batches
  magnitudes for the ring upload and merging them would put Metal bookkeeping on
  the background path. If one call's argument list changes, change both.

---

## 13. Concurrency and SwiftUI performance

- **The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** Types are
  main-actor isolated *unless marked otherwise*, which is why so many DSP types
  carry an explicit `nonisolated`. Without it they'd be silently main-actor-bound
  while actually running on the audio thread.
- **`@Observable` tracks at whole-property granularity.** Any view body reading
  `diagnostics.<anything>` re-renders 15×/s while capturing. That churn was
  rebuilding toolbar menus mid-tap and dropping their actions. Slow-changing
  fields are mirrored into their own equality-guarded properties (`@Observable`
  notifies on every set, changed or not).
- **`nonisolated(unsafe)` rather than plain `nonisolated`** on `@Observable`
  stored properties: the macro expansion turns them into tracked accessors that
  plain `nonisolated` can't attach to.
- **Leaf views are load-bearing, not stylistic.** High-churn readouts are
  separate `View` structs so their updates don't invalidate a large body. Same
  reasoning behind `PlaybackFollowState` and the playhead's own `TimelineView`.
- **The tuning overlay's two-closure sliders**: live writes go to the DSP
  object's lock-guarded scalar (heard next buffer); commit writes go to the
  persisted settings object. Binding straight to settings would do a
  `UserDefaults.set` plus an observation invalidation *per drag frame*, on the
  main thread, with the render loop live behind it.
- **`showTuningOverlay` must never join `ContentView.menuIsOpen`.** That flag
  pauses the render loop and suspends the processor; the overlay exists
  precisely to tune against a *running* pipeline. Same deliberate exclusion as
  `showBand`/`showPulseView`.
- **Revert snapshots everything as one flat struct**, so a knob can't be added to
  a tab and silently not captured. Restoring bumps `revertToken` to re-`id` the
  subtree, because `heterodyne.gain` isn't `@Observable` and restoring it changes
  nothing SwiftUI watches.
- **`apply(to:)` writes post-roll before ramp.** The reverse order clamps a new
  ramp against the old post-roll and silently loses a legitimate increase.
- **Anchor preferences use `transformAnchorPreference`**, not
  `anchorPreference`, so anchors from nested child views aren't dropped when a
  parent pane is also tagged.
- **`OnboardingState` is deliberately not `@AppStorage`.**
- **`LazyDestination` exists because `NavigationLink { Destination() }` builds
  its destination eagerly**, not on tap — which meant every row in a list
  allocated the WAV player's ~15 MB PCM ring up front.

---

## 14. Target and build wiring

Easy to get silently wrong:

- **The widget target is named `OpenBatWigetExtension` and its folder is
  `OpenBatWiget/`** — missing the `d`, a typo baked in when the target was
  created. Cosmetic, but don't "correct" the path in the pbxproj without
  renaming the folder to match.
- **`BatDetectorAttributes.swift` and `BatActivityPalette.swift` live in the
  app's synchronized folder** and reach the widget target only through an
  explicit `PBXFileSystemSynchronizedBuildFileExceptionSet`. Moving or renaming
  either requires updating that list.
- **The App Group `group.Niall.OpenBat` is declared in both entitlements files
  but nothing reads it** now the pulse image is gone. Harmless, left in place
  because re-provisioning is churn for no benefit — but don't take its presence
  as evidence something depends on it.
- **SourceKit false positives.** "Cannot find 'UIKit' in scope", "Cannot find
  type 'SpectrogramProcessor' in scope", "Reference to member 'shaderRead'
  cannot be resolved" and similar are indexing artifacts. The project builds.
- **The bundled demo clip is discovered by prefix** (`Demo*.wav` under
  `OpenBat/`), not by a hardcoded name, so it can be re-stitched and renamed
  freely.

---

## 15. The 2026-07-27 review

A sequential, area-by-area adversarial review across 7 areas, recorded with
verdicts in `openbat-full-review-2607.md`. Summary of what it found and what was
decided. Most were marked "fix as per suggestion"; the ones with substantive
direction are noted.

| # | Finding | Verdict |
|---|---|---|
| 1.1 | Playback stop/restart race could corrupt shared DSP state — a 200 ms semaphore timeout let two producer threads run against the same lock-free processors when a WAV read blocked on an iCloud fetch | Fix |
| 1.2 | Realtime audio thread allocating per callback | Fix |
| 1.3 | No output limiter on listening gain | Fix |
| 2.1 | Per-hop heap allocation on the realtime thread | Fix |
| 3.1 | Species range store pointed at the wrong GitHub repo | Fix |
| 3.2 | Unsynchronized concurrent writes to the Wikipedia photo cache | Fix — **plus** load several images and let the user swipe, since a single random pick often lands on a poor photo |
| 3.3 | Wrong contribute-link URL in the empty region view | Fix |
| 3.4 | No antimeridian handling in the GBIF bounding box | Fix |
| 3.5 | Family colour tint not actually stable across launches | Fix |
| 3.6 | Non-unique `ForEach` IDs on duplicate content | Fix |
| 4.1 | NOISE class could appear as a runner-up species | **Kept, conditionally** — a sound genuinely close to a bat pulse *could* be noise, and showing that is honest. Only a problem if NOISE displaces a genuine runner-up |
| 4.2 | No NaN guard in classifier normalisation | Fix |
| 4.3 | Renormalisation safety implicit rather than enforced | Fix |
| 5.1 | Listening-mode WAVs got exact GPS despite a no-location rule | **Rule was the oversight, not the code.** Session and listening recordings should hold the same fields at the same accuracy — a session is just a grouping/viewing device, not a different privacy class |
| 5.2 | Silent GPS failure mid-session with no user-facing signal | Fix — surface it where the headphone warning sits; yellow for one warning, red for two or more, tap for a popover listing all of them |
| 5.3 | Killed sessions never got an end date and were never reconciled | Fix — **and** keep running when backgrounded, so someone can pocket the phone with headphones in while the detector hangs on a long wire |
| 5.4 | GUANO session label never updated after a rename | Fix |
| 5.5 | Failed writes still counted in the WAV's declared length | Fix |
| 6.1 | Pre/post-roll recording settings didn't persist | Fix |
| 6.2 | Settings view not isolated from `AppStorage` churn | Fix |
| 7.1 | README described a removed, contradictory design | Fix |
| 7.2 | TOCTOU race on upload overwrite protection | Fix |
| 7.3 | Declared upload size never checked against actual bytes | Fix |
| 7.4 | `db:migrate` script skipped three later migrations | Fix |

Each area also has a "Checked and found sound" list in the original document,
which is worth reading before re-auditing the same ground.

### ⚠️ Review items that appear to be still unfixed

Spotted during the 2026-08-08 documentation pass, by reading the code against
the verdicts above. **Not verified against a build or a test run** — treat as
leads to check, not as confirmed regressions.

| Review item | What the code looks like now |
|---|---|
| 3.5 Family colour tint not stable across launches | `SpeciesExplorerView.GuideSpeciesThumbnail.tint` still uses `family.hashValue % palette.count`, and comments it as deterministic. Swift randomises `hashValue` per process, so it isn't. |
| 3.4 No antimeridian handling in the GBIF bounding box | `GBIFService.region(for:)` still takes a plain `.min()`/`.max()` over longitudes, so a range straddling ±180° yields a near-global box. |
| 3.1 Species range store pointed at the wrong repo | `SpeciesRangeStore.remoteURL` points at `NiallxD/OpenBat`, while `SpeciesGuideStore.remoteURL` and `SpeciesRangeStore`'s own header both say `NiallxD/OpenBat-FieldGuide`. The two disagree. |
| 5.2 Silent GPS failure with no user-facing signal | `LocationProvider.locationManager(_:didFailWithError:)` is still an empty body. |
| 3.2 Wikipedia photo carousel | The concurrency half (cache lock) is done. The "load several images and let the user swipe" half doesn't appear to exist — `fetchPhoto` still resolves a single `Photo`. |

---

## 16. Open questions

- **Freedom to operate on live ATE.** Wants a patent attorney's opinion covering
  the existing mode, not just sampler mode. See §5.
- **What is still wrong with candidate `G`.** It was the closest ATE tuning
  candidate and still not right by ear. Next session should get a more specific
  description than "not my favourite", or A/B it against `REF_full8x` to isolate
  whether the complaint is the ending, the spacing, or the 8× pitch itself.
- **`rampMs` (3.0) > `preRollMs` (2.0) still attenuates every call onset by
  −2.6 dB.** Unfixed. The onset lands `preRoll/ramp` along a *smoothstep* fade,
  not a linear one — at 2 ms/3 ms that's 20/27 → −2.6 dB (computing it linearly
  would wrongly say −3.5 dB). In sampler mode the fix is free, since deaf time
  isn't scarce at one call per 5 s, but the default is shared with the mode being
  A/B'd by ear.
- **Sampler specimens rank only ~34th percentile by peak.** The scan arms on the
  first pulse after the interval, biasing toward the quiet start of a pass rather
  than its loud middle. Arming on level instead is the obvious next idea and is
  untested.
- **10% of `G`'s events still hit the 120 ms cap**, and a cap hit is itself a
  truncation — those are the feeding buzzes. Raising the cap to 200 fixes it at
  the price of a 1.6 s drain per buzz.
- **384 kHz capture verification.** Confirm iOS hands the Griff's native rate and
  doesn't silently downsample. Check `diagnostics.isNativeRate` and
  `actualSampleRate`.
- **BatDetect2's NoID threshold** needs verifying against labelled field data.
- **Upload quality-gate thresholds** are placeholders and need real data.

### Apparently orphaned code

Found during the 2026-08-08 documentation pass. Each is fully implemented and
looks maintained, but nothing appears to call it. Needs a decision — delete, or
keep deliberately and say why.

- **`WavPlayer/TickerWheelControl.swift`** — the whole control. Zoom and pan in
  the WAV player are gesture-driven now; `grep` finds only self-references. Its
  header claimed to be wired into the player and has been corrected.
- **`WavViewportMath.viewportForFreqZoom`** — same cause, smaller stakes:
  frequency zoom is pinch-driven.
- **`ClassificationStore.clearAll()`** — its own doc comment already notes
  nothing calls it.

**Related drift to watch for:** the ticker-wheel → gesture migration left
several `WavPlayer/` headers describing controls that no longer exist, and they
contradicted correct inline comments further down the same files. If that
rebuild touched other subsystems, expect the same pattern there.

### Planned work

- **NABat ML v2.0 integration** — convert the USGS Python model to CoreML; notes
  in `mlconversion.md`. Prior-based filtering: disabled species → weight 0 →
  renormalize remaining softmax outputs.
- **Pulse log** — store the last N captures as a scrollable history in the pulse
  zoom panel.
- **Taxonomy browser** — an explorable order → family → genus → species tree for
  the field guide, complementing the region-grouped list.
- **Illustrated morphology icons** — `SpeciesDetailView`'s morphology section is
  text-only.
