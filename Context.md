# OpenBat — Context

**This is where the project's history and reasoning live.** Code comments say
what the code does and which rules must hold; this file says *why*, what was
tried and rejected, and what a measurement actually showed.

Read the relevant section before changing anything in the audio pipeline, the
upload path, or the Live Activity. Most of what's here was expensive to learn.

**Companions:**
- `README.md` — public-facing description of the app.
- **"How OpenBat Works"** — the long plain-language explanation of every system,
  for learning the codebase. Lives in Obsidian (`Niall's Vault v2/002 - Notes/
  OpenBat Documentation.md`), *not* in this repo. It was once called
  `HOW_IT_WORKS.md`. Because it sits outside version control it drifts silently
  when the app changes.
- `TimeExpansionTuning/FINDINGS.md` — the raw measurement corpus behind §4.
  Lives outside the repo, alongside it, so a clone won't have it.

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
| 2026-08-08 | Variable time distortion (VTD) replaced adaptive time expansion as the live mode: rate ramping instead of gating, so nothing is discarded. Tuned by ear against the demo clip. |
| 2026-08-09 | **VTD withdrawn from the build** on patent proximity — quarantined to `Quarantine/VariableTimeDistortion/`, outside any target. Live listening is heterodyne only. See §3 and §5. |
| 2026-08-16 | Acceptance-review follow-up: bundled species presence grid replaces live GBIF lookups, every outing is a session, GPS tracks removed. |
| 2026-08-16 | **Bottom tab bar** replaces the leading logo menu; the transport controls move into a menu hanging off a session button beside it. iPhone is now portrait-only and the whole iPhone-landscape layout is deleted. See §7 and §14. |
| 2026-08-16 | **Simplified view** ships as the default, asked during onboarding and switchable in Settings; Settings itself folds from five tabs to three. See §7. |
| 2026-08-16 | **Detector-wide 1 Hz stutter** traced to a `TimelineView` in a `ToolbarItem` (the sun pill) and fixed; sun-time computation memoised and tab-icon resolution cached. See §7. |
| 2026-08-16 | **Tab glyphs** changed: Detector and Species are drawn artwork (bat-with-calls, bat-over-book), Sessions is `waveform.path.ecg.text.clipboard`. See §7. |
| 2026-08-16 | **Screen cleanup pass** on Niall's review notes: simplified view stops the spectrogram scrolling; the field guide's version card becomes a toolbar popover and its search field a glass pill; Sessions loses its filter button and the map's threshold caption; a session opens on its charts, now including detections-over-time. See §7. |
| 2026-08-16 | **Sun clock** in the detector's leading nav-bar slot: sunset time, then time since sunset, then sunrise time, then a countdown to sunrise. The two counting windows are each 15% of the night, not fixed hours. See §7. |
| 2026-08-17 | **Four bugs from the v1.1 scan fixed.** A session no longer goes deaf behind a full-screen sheet (the processor is never suspended while one is running, and the pump takes over draining); the detector is no longer paused by a *suppressed* sheet (`menuIsOpen` and the sheet's own binding now share one expression); `evaluateLaunch` is idempotent, since its caller is a `View.init` SwiftUI may run twice; activity-chart bucket edges are rounded on the local clock rather than the epoch. See §7 and §13. |
| 2026-08-17 | **Calibration is offered on first mic connection.** The offer that onboarding used to make before the hardware was plugged in now arrives the first time a given USB mic is actually seen, once per mic name, never over a running session or another sheet. See §7. |
| 2026-08-17 | **Onboarding cut from eight screens to three** — welcome, the permissions ask, the ID caveat — on Niall's call. The five removed pages (echolocation, listening modes, mic calibration, the view-mode switch, "you're all set") are kept whole as `AboutAppTour`, a second tour offered on the Info & Tour screen beside the guided one. See §7. |
| 2026-08-17 | **One card for "a model suits where you are", and the tour nudges.** The full-`Form` location-change sheet is deleted; both the post-onboarding offer and the after-a-move notice now use the same compact card. A clean install no longer raises that notice at all, and the tour's popover opens itself 15 s after the first arrival at the detector. See §7. |
| 2026-08-16 | **Playback folds into Sessions.** The Playback tab and the recording detail page are both gone: a recording opens the player wherever you tap it, and its per-pulse IDs are a sheet over the player. Sessions loses its Sessions/Recordings segmented picker. See §7. |
| 2026-09-01 | **The player stops stuttering, stops blurring and starts actually cutting silence.** Three unrelated causes: the pacing thread was running a whole live spectrogram to extract one number and re-tuning the oscillator 500×/s with a slew meant for 15 Hz; the detail-tile chain restarted every 0.3 s from a step that can never be used during playback; and silence detection measured no spread, padded in display columns, and inherited the overview's resolution (146 ms/column on a ten-minute recording). Measured on the demo file: kept share 43.6% → 17.4% with no call energy lost. See §3. |
| 2026-08-28 | **Playback speed becomes a control (4×/8×/16×), and hiding silence starts applying to playback.** The compressed timeline used to be torn down the moment you pressed play, and the gap-skipping written for that case was unreachable dead code; the pacing thread now walks the kept segments directly, so every time the engine publishes is in the packed timeline. Detection reworked alongside: the threshold is dB above the file's own noise floor, runs need hysteresis and a minimum duration, and a "found nothing" fallback is flagged instead of silently showing the whole file. See §3. |

---

## 2. Settled decisions

Originally from the onboarding/consent/upload handoff spec, which marked each
`[DECIDED]`. That spec has been implemented in full and removed; this section
is now the record. These are not open for casual revisiting.

- **No OS permission popup ever fires "cold" (out of nowhere).** iOS only lets
  an app ask for a permission — microphone, location — once without the user
  going into Settings to reset it, so that one ask is precious. OpenBat always
  shows its own explanation screen first ("we need your mic to detect bat
  calls") and only *then* triggers the real iOS popup. You should never see a
  system permission dialog appear before you've seen the welcome screen.
- **The device's identity is one OpenBat controls itself, not Apple's
  `identifierForVendor`.** Apple hands every app an ID for the device it's
  running on, but that ID *resets* if the app is deleted and reinstalled —
  which would make a reinstalled app look like a brand-new device with no
  consent history, or leave an old consent record pointing at nothing. Instead,
  OpenBat generates its own random ID the first time it's launched and stores
  it in the iPhone's **Keychain** (secure storage that, unlike ordinary app
  data, survives a delete-and-reinstall). Consent records are keyed against
  this ID, not Apple's.
- **A consent record stores your *current* answer, not a running list of every
  time you clicked yes.** A log that only ever records "granted" events can't
  represent someone changing their mind — if you later revoke consent, a
  pure event log still shows "granted" with nothing to contradict it. So the
  record instead stores current status (granted or revoked) alongside
  `device_id`, which version of the consent text you agreed to
  (`consent_version`), and the timestamps `granted_at`/`revoked_at`. The system
  can always answer "is this device opted in right now?" correctly.
- **The consent wording itself is versioned.** If the privacy text changes —
  say, a new way data might be used gets added — an old "I agree" tap
  shouldn't silently count as agreeing to the new text too. Every wording
  change bumps `consent_version`, so it's always knowable exactly which text a
  given device actually agreed to, and a user is re-asked rather than carried
  forward onto wording they never saw.
- **No lossy audio compression anywhere in the upload path.** "Lossy" formats
  like MP3, AAC or Opus (what most music files use) shrink a file by
  *permanently throwing away* audio detail assumed to be inaudible to humans —
  fine for a song, but these recordings are meant to become a reference
  library other researchers use to identify bat species by their calls, and
  the detail thrown away might be exactly what a correct identification needs.
  So the app uses **FLAC** only: smaller than the raw recording, but every bit
  of the original audio can be perfectly reconstructed from it — nothing is
  discarded.
- **Species identification always happens before any privacy filtering, on the
  full, unaltered recording.** To protect privacy, an uploaded recording gets
  its lowest frequencies filtered out before it leaves the device (a
  "high-pass filter" — think of a sieve that only lets the fine, high stuff
  through — because low frequencies are where audible human speech nearby
  could show up). But identifying the bat species from its call needs to work
  on the complete, untouched sound; feeding it filtered audio risks a wrong or
  weaker ID. So identification happens first, on-device, on the raw unfiltered
  audio — filtering is only ever applied afterward, to the copy about to be
  uploaded. This now holds automatically, by how the pipeline is built: ID
  happens live, upstream of any filtering step.
- **Anything identifying is stripped or blurred only at the very last moment,
  right before upload — the file saved on your phone is never touched.**
  "Strip" means deleting identifying metadata (device names, file paths) from
  the copy about to be sent. "Fuzz" means deliberately making something less
  precise — e.g., rounding an exact GPS coordinate down to a coarser area, so
  a recording can't be traced back to, say, your specific backyard. Both only
  happen to a derived copy created for upload; the original recording in your
  library is never reopened or modified.

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

### Withdrawn 2026-08-09: variable time distortion

The live mode that replaced adaptive time expansion on 2026-08-08 — a continuous
monotonic read pointer with a varying playback *rate* (1× through a call, ~1.9×
real through the gaps, faster still to repay accrued lag), so calls are expanded
8× and nothing is ever gated out or dropped. Measured on the demo clip: 167 of
171 pulses expanded, zero dropped windows, zero ring overflow, ~1.3 s of lag and
only during dense sequences.

It was **withdrawn from this version before shipping**, on Niall's call, because
§5's patent question was still open and unshipped code is the cheap place to
wait. The code is intact in `Quarantine/VariableTimeDistortion/` — outside the
synchronized folder group, so in no build target — with its call sites recorded
verbatim in `CALL-SITES.md` there. Note that VTD's non-infringement argument is
*stronger* than the mode it replaced (nothing is selected, which goes straight at
claim element 3) — withdrawing it is caution about an unanswered question, not a
finding against it.

**Consequence: live listening is heterodyne only.** `.timeExpansion` file
playback is untouched.

**2026-08-15 — the withdrawal was incomplete for six days.** Quarantining the
working-tree copy never removed VTD from git history, and branch `v1` — which
carried the source from commit `c035295` — had been pushed, so the code was
publicly readable in this source-available repo the entire time it was supposed
to be withdrawn. The quarantine README asserted `v1` "has never been pushed";
that was never checked against the remote. `v1` has since been
rewritten to drop the file from all 8 commits carrying it and force-pushed, and
the pre-rewrite history is preserved on the local-only branch
`archive/v1-with-vtd`. GitHub may still serve the old commits by SHA, and any
clone or fork taken before 2026-08-15 retains the source.

The general lesson, worth more than the incident: **removing a file from the
working tree is not removing it from a repo.** Withdrawing something for legal
reasons means checking `git log --all -- <path>` and what the remote actually
has, not just where the file sits today.

### Heterodyne enhancement: measured 2026-08-09 — retune, don't rebuild

Investigated whether a quadrature (single-sideband) mixer would beat the shipped
real mixer. **It would not be worth the code.** Harness: `TimeExpansionTuning/
het_ab.py` (`--selftest`, `--diag`, renders `audio/*__HET_*.wav`).

**The fold is real and total** — `--selftest` pushes a 60→30 kHz downsweep past a
fixed 45 kHz LO: classic traces `8.6 → 4.4 → 1.2 → 4.4 → 8.6 kHz`, a perfect V
(fold index 0.99); quadrature falls monotonically (0.02). Sweep direction is
destroyed by the shipped mixer, objectively and completely.

**And it barely matters, because nothing lasts long enough for it to.** Measured
audible dwell on the demo clip (104 calls) is **1.45 ms per call**. Heterodyne
only sounds while the call's instantaneous frequency is inside the LO's window,
and a steep FM sweep crosses an 8 kHz window in about a millisecond. Whatever the
mixer does, it does in that millisecond.

So the metric that matters is §3's own one — **cycles**, not bandwidth:

| config | dwell | cycles | pitch |
|---|---|---|---|
| classic, offset 1500, LPF 4k (**shipped**) | 1.45 ms | **2.6** | 1.79 kHz |
| classic, offset 4000, LPF 8k (**two constants**) | 1.79 ms | **7.7** | 4.28 kHz |
| classic, offset 6000, LPF 12k | 2.19 ms | 13.7 | 6.28 kHz |
| quadrature, offset 1500, LPF 4k | 1.47 ms | 8.5 | 5.78 kHz |
| quadrature, offset 1500, LPF 8k | 2.14 ms | 20.9 | 9.78 kHz |

Perception needs ~6–10 cycles to register a pitch at all. **The shipped
configuration delivers 2.6 — below that floor, so by this repo's own argument it
is a click, not a tone.** Retuning the *existing* mixer reaches 7.7. Quadrature
at the same width reaches 8.5: **+0.8 cycles for a new realtime DSP path, a
settings toggle and a mode to maintain.** Not worth it.

The quadrature win was mostly that it parks content at a higher pitch (`fc`), and
`audibleOffsetHz` already does that for free. Niall listened to the first A/B set
and reported the variants as near-indistinguishable apart from the wide ones
being "a bit higher pitch" — which was exactly right, and is what sent the
investigation here.

**Latent problem this exposed.** The Het tuning tab offers `audibleOffsetHz` up to
6000, but the output low-pass is fixed at 4 kHz — so the top third of that slider
pushes the call *out* of the passband and only makes things quieter. The two
numbers have to move together.

**Where quadrature would still win: CF species.** A horseshoe-bat call dwells at
one frequency for tens of ms, so the 1.45 ms argument doesn't apply and the fold
would genuinely wreck it. Untested — there is no CF material in the corpus.

**Also measured:** widening the low-pass *improves* call-to-gap ratio rather than
costing it (demo +2.3 dB, MYLU +3.1, MYCA +2.0, LANO +0.6) — a wider keyhole
admits more of the call's swept energy, and calls are concentrated where hiss is
spread. And quadrature does **not** buy the ~3 dB SNR the sideband argument
predicts (9.7 vs 9.6 dB): auto-tune parks the LO mid-sweep, so classic folds
signal along with noise and gains back what it loses.

Patent-wise all of this is safe ground: output rate equals input rate, continuous,
nothing selected, so elements 3 and 4 of §5's '647 are not met.

**Open:** the ear test on `classic` vs `retuned`, which is the actual decision.

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

### Playback speed became a control, and silence removal became audible (2026-08-28)

Two things the player believed that were wrong.

**It thought the playback speed belonged to the listening mode.** 8× was never
chosen — it fell out of the file being fed at 48 kHz into an output ring
hardcoded to 48 kHz, so the ratio was fixed and there was no way to ask for
anything else. The speed is now the ratio between two rates the player sets
together: the pace file samples are released at, and the rate the output node
declares. Both follow `PlaybackEngine.expansionFactor`, stopping at 4×, 8× and
16×, and it is the player's own persisted setting — the detector's expansion
settings still carry only gain. Nothing about the technique changed: every
sample of the recording still plays, in order, against a slower clock, and the
final conversion to the hardware rate is the OS mixer's.

The one thing to know before widening the stops: the node's rate is
`fileRate / factor`, clamped to 8–96 kHz. A *smaller* factor means a higher node
rate, and the mixer then discards everything above the hardware's Nyquist — at
4× on a 384 kHz file a 100 kHz harmonic lands at 25 kHz and is gone. That is
physics, not a defect, but it is why the stops start at 4×.

**It thought hiding silence was a way of drawing a recording, not of hearing
one.** The compressed timeline was torn down the instant playback began
(`rebuildSilenceMap` guarded on `!engine.isPlaying`), so the toggle stayed lit
while you listened to the whole file, gaps and all. The gap-skipping written for
that case — seek forward at 30 Hz whenever the playhead landed in a hidden
stretch — could never run at all, because it read the very map that had just
been set to nil. It was dead code from the day it was written and no test
covered the path, which is why nobody noticed.

Playback now walks the kept segments itself: `PlaybackEngine` holds the map, and
the pacing thread jumps its read position at each boundary, so hidden audio is
never read, never fed to a processor, and takes no time to play through. That
also fixes what the seek-based version would still have done wrong — a full
engine restart per gap, up to 33 ms of leaked silence before each jump, and the
recording's dead tail playing out in full because there is no "next segment" to
skip to after the last call.

Consequently **every time the engine publishes is now in the timeline it is
playing** — packed while silence removal is on. That is the contract worth
keeping: the playhead, the minimap, the scrub bar and the elapsed readout all
stopped mapping domains, because there is only one domain again. Only tile
stitching and call analysis still cross, and they always did.

Seams get a 2 ms crossfade. It has to stay well inside `SilenceMap`'s pulse
margin — a ramp longer than the pre-roll is exactly what put every call onset
part-way down the fade in the adaptive-expansion work. That margin is now
floored at 3 ms in `SilenceMap.minPadSeconds` rather than left to whatever the
slider allowed; see the 2026-09-01 entry below, which also moved padding out of
display columns and into samples.

**Detection was reworked at the same time**, because the tool was not
trustworthy enough to hand to playback:

- The threshold is now plain dB above the recording's own noise floor. Both
  previous versions failed for the same reason — the number the user set had no
  fixed meaning. An absolute dB threshold did nothing whenever it fell below a
  given file's floor. A 0–1 "sensitivity" interpolated between the floor and the
  file's *loudest* column moved with the file: one close pass or one broadband
  knock put the midpoint 30 dB up and hid every real call, while a file of only
  faint calls hid nothing. Anchored to the floor alone, 12 dB means the same
  thing everywhere and no single artifact can move it. **Superseded
  2026-09-01** — anchoring to the floor *alone* was still not enough, because
  the floor says nothing about how far the background wanders above it; the
  threshold now adds that measured spread. See the 2026-09-01 entry below.
- A run needs hysteresis to close and a minimum duration to count. A
  single-column blip is shorter than any bat call; each one used to become its
  own padded region, which is why the packed timeline filled with visible noise.
- `wholeFile` is flagged when it is a fallback. It was reachable three
  different ways and looked identical to a broken toggle in all of them; the
  panel now says what was kept, or why nothing was.

### The player was jittery, blurry and barely cut any silence — three unrelated causes (2026-09-01)

Reported together, so they looked like one performance problem. They were not,
and two of them had nothing to do with speed at all.

**Nothing on the playback path ever needed a spectrogram.** The pacing thread
ran the live Detector's whole `SpectrogramProcessor` — 1500 zero-padded
2048-point FFTs a second, every sample copied into a 15 MB PCM ring under a
lock, ~1500 freshly allocated 1024-float columns a second — and then drained
and discarded every column, because both players draw a static whole-file
spectrogram from disk. A search of the app finds no other reader of that
processor. All that survived of it was one number: the dominant frequency
heterodyne tunes to. `TuningPeakDetector` now measures exactly that, with the
same window, the same FFT size, the same band floor and the same −55 dBFS
gate, at 15 Hz instead of 1500 Hz.

**Detection and tuning are not the same job, and merging them broke each in
turn.** The fix below moved auto-tune onto a 15 Hz tick, correctly — but it
moved DETECTION there too, and looked at a single 1.33 ms window per tick.
That is a 2% duty cycle against a bat call lasting 2–5 ms, so the squelch gate
stopped opening and heterodyne playback went nearly silent ("really
insensitive, most calls don't trigger it"). On a synthetic pass of 89 calls
90 ms apart it caught **none of them** — the sampling and the call rate simply
never aligned.

The two rates are now separate, because they want opposite things. Detection
scans every fed block in full, at the same 256-sample hop the live Detector
examines its own input at: 89/89 on the same test, and it costs **0.3% of a
core** at `-Onone` — the expensive part of the old `SpectrogramProcessor` was
never the FFTs, it was the ring copy, the per-column allocation and the
display-column work. Tuning still runs at 15 Hz, easing toward the loudest
peak seen since the previous tick.

**Heterodyne's oscillator was chasing noise, not calls.** The 0.3 slew factor
was copied from `AudioEngineController.updateAutoTune`, where it runs on a
15 Hz timer. The pacing thread applied it once per fed block — about 500 times
a second — so instead of easing toward a call's frequency over ~200 ms the
oscillator snapped to whatever the last 1.3 ms of audio peaked at. That is
heard as the listening pitch warbling, and it is why "make it faster" never
fixed the jitter: there was no CPU cause. Tuning is now on a wall-clock tick at
the cadence the constant was chosen for.

**The playhead was published ~500 times a second, and could only move
forwards.** Three separate comments in the player describe `onProgress` as
"~20-25 Hz"; it never was — it fired once per fed block, each one a main-actor
hop invalidating the playhead, the minimap and the elapsed readout. Worse, the
position subtracts an estimate of what is queued in the output ring, that
estimate wobbles between two independently clocked threads, and clamping the
POSITION to its own maximum froze the playhead whenever the estimate dipped and
let it jump when it recovered. The scroll inherited that sawtooth directly.
Publishing is now 30 Hz and the LEAD is smoothed rather than the position
clamped.

**Feeding is now in 20 ms blocks**, not "whatever the clock says after a 2 ms
sleep", which also retires ~500 `AVAudioPCMBuffer` allocations a second.
Heterodyne's own slack went from 60 ms standing / 250 ms runaway to 120 / 500,
with a 1 s ring. That asymmetry was the whole reason the same hiccup stuttered
heterodyne and not time expansion: time expansion had 100 ms standing and 20 s
of runway while doing an eighth of the work per real second, because it feeds
the file at a slowed 48 kHz rather than its native 384 kHz.

**The blur was scheduling, not resolution.** During playback the detail-tile
chain restarted every 0.3 s from its zero-margin first step. That step is fine
for a gesture — the view is where the user left it — but useless under
playback: it lands 150–400 ms later, by which time the playhead has passed its
right edge, `tileCovers` rejects it, and the display falls back to the
whole-file overview crop, which at a typical zoom is a few dozen pixels
stretched across the screen. The later steps that would have carried a margin
mostly never ran, because the next throttle fire abandoned the chain. Playback
now renders the full planned margin in one bounded step (it is already capped
to `maxTileColumns`) and only re-renders when the playhead is running out of
runway inside the tile it has — the same question `maybePrefetchTile` already
asked for drags.

Worth keeping, because it came up while explaining this: **Audacity does the
same thing we do** — visible-window spectrogram, cached per clip, recomputed on
scroll. It feels effortless because its audio is 48 kHz rather than 384, its
columns are far coarser than our 32-sample hop, and its view does not chase a
playhead at all, so a cached picture stays valid for a whole playthrough.

**Hide silence kept 43.6% of a recording whose calls occupy 4.1% of it.**
Measured on the app's own demo file (26.5 s, 384 kHz) at the shipped defaults —
12 dB, 20 ms margin — 133 segments, 43.6% kept. Three causes, all
quantifiable:

- **The threshold had no idea how variable the background is.** Anchored to the
  20th percentile of the column peaks plus a fixed margin, it assumed the
  background sits tightly around that figure. On that file the peaks run
  −87.5 dB at the 20th percentile to −78.7 at the 80th, so 12 dB landed at
  roughly the **86th percentile of the file's own ordinary background**. The
  threshold now adds the measured 20-to-80 spread, capped at 12 dB so a busy
  recording (where the 80th percentile sits inside the calls) cannot have its
  threshold pushed above them.
- **Padding was applied in whole display columns with a floor of one.** A
  column is `duration / 4096` of the file, so the smallest margin the slider
  could produce was 15 ms on a one-minute recording, 73 ms on a five-minute one
  and 146 ms on a ten-minute one — per side, and a recording can run to ten
  minutes. Past a few minutes that is wider than the gap between a bat's
  pulses, so every pass merged into a single block whatever the slider said,
  and the toggle trimmed the ends of the recording and nothing else. Padding is
  now in samples, floored at 3 ms so the 2 ms seam crossfade still lands inside
  it.
- **Detection resolution was whatever the display overview happened to be** —
  a fixed 4096 columns for the whole file. 6.5 ms per column at 26 s, 146 ms at
  ten minutes, at which point inter-pulse gaps are not resolvable at all.
  Detection now takes its own scan at ~5 ms per column, capped at 24 576
  columns, and reuses the overview when that is already fine enough. It keeps
  only each column's peak rather than all 1024 bins, because the full grid at
  that width would be ~100 MB.

Measured after: **17.4% kept, with 100% of the call energy still inside a kept
region** — checked against both columns 35 dB over the floor and the fainter
25 dB set.

One thing that was tried and rejected: requiring two consecutive columns over
the threshold instead of one. It cuts a further 3 points off the kept share and
**loses 4–11% of real call energy**, because a 5 ms pulse can occupy a single
column. Fewer calls heard completely beats more calls heard partially, so the
minimum-duration floor stays where it is. Note it is inert at overview
resolution anyway — it works out to `round(12.3 / duration-in-seconds)`
columns, so it is ≥2 only on recordings under about six seconds.

Also checked and **not** a bug, so nobody re-chases it: the streaming denoiser
does not drop audio at block boundaries. Simulated across randomised block
sizes, the loss is a one-off 511 samples at startup, exactly as its comment
claims.

#### And then none of it helped, because the real cause was the build configuration

All of the above is real and all of it stands, but Niall reported the player
was **no better**: still stuttering in heterodyne, and disabling background
removal fixed it. Playback was "chugging", the spectrogram moving *slower than
real time*, and in Reduce or Scrub no sound came out at all — with the
severity ordering off < Reduce < Scrub.

"Slower than real time" is a throughput statement, so the denoiser had to be
missing its deadline. It measured at 2.2% of a core (Reduce) and 3.7% (Scrub),
which is why this was dismissed. **Those numbers were taken from an optimised
build.** Measured again at `-Onone`, which is what runs during development:

| | Release `-O` | Debug `-Onone` |
|---|---|---|
| Reduce | 2.2% of a core | **64.9%** |
| Scrub | 3.7% | **169%** |

A 30–45× penalty, on a Mac — so on a phone Scrub simply cannot run in real
time, which is exactly the reported symptom and exactly the reported ordering.
Nothing else on that thread showed it because everything else there is either
vDSP or trivial; this file was almost entirely scalar Swift loops over Swift
arrays, which is precisely what `-Onone` destroys (bounds checks, no inlining,
retain/release traffic).

**The lesson worth keeping: a DSP hot path that is scalar Swift has two
completely different performance characters, and the one you develop against
is the slow one.** vDSP is precompiled and does not care how this file is
optimised, so moving the per-bin arithmetic into it removes the cliff rather
than relocating it. The per-bin work is now `vDSP_zvmags`/`vdiv`/`vsmsma`/
`vthr` for the gain rule and the noise estimator, shifted `vDSP_vadd`s for the
scrub mask's neighbourhood counting, and `memmove` for the stream buffers.
Scrub also built a fresh Swift Array **per bin** (`for base in [a, b, c]`) —
about 768 000 heap allocations a second on the pacing thread.

After, on the demo file, with byte-identical output (same RMS, same 25.3%
non-zero for Scrub) and the gain maths verified equivalent to the scalar
version to within float rounding across 2000 frames:

| | Release `-O` | Debug `-Onone` |
|---|---|---|
| Reduce | 0.5% of a core | **1.1%** |
| Scrub | 0.5% | **14.1%** |

Two further things this pass found, both real independent of the above:

- **The blur fix above was inert as first written.** It only re-rendered when
  the resident tile stopped covering the playhead — but while no valid tile
  exists that condition is true on every tick, so it fired every 0.3 s and each
  fire abandoned the render in flight. A tile worth having takes longer than
  the throttle to build, so it was killed and restarted forever. A render
  already on its way now counts as coverage.
- **`seedNoise` raced the pacing thread.** It reached straight into the
  denoiser — documented as single-threaded, one set of FFT scratch buffers —
  from a detached `.utility` task, while the pacing thread could already be
  inside `denoiseStreaming` on the same instance. Opening a recording and
  pressing play straight away is the ordinary case. The seed is now stored and
  applied by the pacing thread itself.

#### Tile renders, and the one-second stall at the end of the buffer (2026-09-01)

With the audio fixed, what remained was the picture pausing for about a second
whenever playback reached the end of the buffered window. Measured at
`-Onone`, one tile (0.8 s span, 6144 columns) cost **140 ms of FFT and file IO
and 478 ms in `colorize`** — against roughly 0.45 s of runway ahead of the
playhead. A render that takes longer than the runway it replaces cannot ever
catch up.

- **`colorize` wrote one 32-bit RGBA value per pixel in a Swift loop** — 3.7
  million iterations for a 6144-column tile, and at `-Onone` each costs about
  100 ns however it is written (478 ms with array subscripts, 379 ms with raw
  pointers). It now emits an **8-bit indexed image**: `vDSP_vfixu8` already
  produces exactly the palette index, so it writes straight into the
  destination row and CoreGraphics does the colour lookup at draw time. No
  per-pixel Swift code, and a quarter of the bytes. **478 ms → 2 ms.**
  Verified: an indexed image drawn scaled 6× is pixel-identical to the RGBA
  equivalent, so CoreGraphics converts before interpolating rather than
  blending indices. `LogFrequencyWarp` needed no change — it copies whole rows
  by the image's own `bytesPerRow` and rebuilds from its own format.
- **A detail tile read every sample about sixteen times.** At native hop the
  windows are 32 samples apart and 512 long, one seek+read syscall each —
  ~9600 of them for a 0.8 s tile. Spans under 2M samples are now read once and
  windowed from memory. The per-frame path stays for whole-file overviews,
  which is what it was written for. 140 ms → 90 ms.
- **The re-render trigger asks a question about time, and measures both
  sides of it.** Every fixed threshold tried here was wrong on some axis. A
  fraction of the VIEWPORT fired with 0.1 s of runway left against a render
  that took longer than that. A fraction of the TILE was tuned against
  renders timed on a Mac, and a phone's are several times slower, so it still
  fired too late in heterodyne — the playhead visibly overran the buffered
  region on the minimap's red/green overlay, which is the instrument that
  found it (Niall, 2026-09-01). And neither could be right in both heterodyne
  and time expansion, where the same tile lasts eight or sixteen times longer
  in real time.

  So the view now measures how long the last playback render actually took on
  this device, and how fast the playhead is actually crossing the recording
  (from the follow position, smoothed), and starts the replacement when the
  runway left is down to about 2.5× the render it has to cover. Where renders
  are slow relative to the runway this chains back-to-back — which is exactly
  what Niall asked for, "once the line goes green we should start buffering
  the next chunk" — and where they are fast, or playback is slowed 8×, it
  stays idle instead of re-rendering for nothing. The static fractions remain
  as a floor for the first render, before there is anything to measure.
- **Playback puts 90% of its margin ahead**, not the 75% a pan gets. A
  recording never plays backwards and the view cannot be dragged while it
  does, so the trailing margin a reversal needs is wasted here.

Resolution went from 1536 to 2048 columns across the viewport. Two things
bound this, and neither is speed:

- **Memory.** The raw grid keeps all 1024 frequency bins so a frequency-only
  pan can recolor without re-rendering, so a tile is `columns × 1024 × 4`
  bytes — 33 MB at the 4× cap, briefly double while a replacement renders.
  That, not time, is what caps `maxTileColumns`.
- **The analysis window.** 512 samples is ~1.3 ms at 384 kHz, so a 0.2 s
  viewport holds only ~150 genuinely independent columns and anything past
  that is interpolation. More columns help at MEDIUM and WIDE zoom, where the
  native frame grid is pooled hardest (a 2 s viewport holds 24 000 native
  frames). Sharpening deep zoom means a shorter window, which costs frequency
  resolution — a different decision, not a column count.

### The 96 kHz capture artifact is real and does not matter (2026-08-18)

**Settled — do not re-open this without new measurements.**

The capture path injects a narrowband tone at a quarter of the input sample rate
(96.0 kHz at 384 kHz). `Biquad.notch` was written for it, never wired to
anything, and the 2026-08-18 audit flagged that as a defect. It wasn't. The
filter and the notch section have both been removed.

The original note said the tone sat **+11 dB above the local noise floor in every
recording checked**, and that reproduces exactly — measured across six real Griff
captures (the five 2026-08-05 passes plus a 2026-07-29 MYYU), it is +11.2 to
+11.6 dB in four of them. Dead consistent at **−83 dBFS** (−81.7 to −84.2 across
all six), which confirms it is the ADC or the USB audio path rather than anything
environmental.

**But "+11 dB above the local noise floor" is a true statement that leads
straight to the wrong conclusion**, and that is the lesson worth keeping. The
floor it is 11 dB above is the floor *at 96 kHz*, where there is almost nothing
to begin with. In absolute terms the tone sits **27–50 dB below the call peaks**
in the same recordings and 20–30 dB below their overall RMS. Divided into the
audible band it lands under the noise floor of the playback path, let alone a
field environment. Niall could not hear it, and the measurement says there is
nothing to hear — it is a spectrogram artifact, not an audible one.

Two things this also settles:

- **Mic calibration was never the answer either**, though it looks like it should
  be: every calibration site in the app corrects FFT magnitudes — the live
  spectrogram, the WAV player's tiles, `CallAnalysis` — and none of it touches
  the audio sample stream. Calibration fixes the picture, not the sound. Where it
  does matter is that a curve measured with the artifact present has a dip at
  96 kHz baked into it, so the tone can be *invisible* on a calibrated
  spectrogram while still being present in the file.
- **"Frequency division" in the old notch comment meant the arithmetic, not the
  detector mode.** OpenBat has no zero-crossing frequency-division mode. Time
  expansion and snippet replay both divide frequency as a consequence of playing
  samples out at 48 kHz instead of 384 kHz (÷8), which is what that comment was
  describing. Don't let the phrase into user-facing text — it names a different
  technique.

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

> **Status as of 2026-08-09:** no live expansion mode ships. Adaptive time
> expansion was replaced by VTD on 2026-08-08, and VTD was withdrawn on
> 2026-08-09 (see §3). The exposure discussed below is therefore historical for
> the shipping app — and live again the moment either mode is restored. The open
> question at the end of this section is still open.

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

### 2026-08-09: the rule narrowed from "no live expansion" to "D240x shape only"

The project's unconditional ban on live time expansion became a **shape**
requirement. The rule as it now stands:

> **Permitted:** capture-a-snippet-and-replay-it-slowly, as the Pettersson
> D240x does it — trigger on level, 50% pretrigger, replay the buffer once at a
> fixed 1/N, accept the deaf window, run heterodyne continuously alongside. The
> D240x manual is the specification; follow it rather than reinventing the
> parameters.
>
> **Still barred** without the FTO opinion this section asks for: any mode that
> keeps up with a pass in real time by deciding what to keep — ATE, VTD,
> sampler modes, anything that discards, dilates or prioritises to avoid going
> deaf. That is the family US 8,599,647 claims.

What changed is not the legal analysis — §5 already said the right thing, two paragraphs up: a
D240x-style detector may itself read on claim 1, and that is an **invalidity**
argument, "a defence to be funded, not a shield to rely on." That sentence still
stands and nothing below supersedes it.

What changed is that the Pettersson D240x manual was read
(`~/Downloads/d240x.pdf`, §"THE TIME EXPANSION SYSTEM"), which turns a general
recollection of 1990s practice into a specific, dated, documented product:

- Continuous recording into a circular memory; a level trigger interrupts it and
  the buffer is **replayed once** at 1/10 or 1/20. Memory 3.4 / 1.7 / 0.1 s.
- **50% pretrigger** — with 3.4 s of memory the capture starts 1.7 s *before* the
  trigger, so the window straddles it. Not a small pre-roll running forward.
- Deaf to expansion while replaying, and explicitly untroubled by it.
- **Heterodyne runs continuously alongside**, hard-panned: "the heterodyne signal
  is available on the left channel and the time expansion signal on the right,
  regardless of the setting of the HET/TIME EXP switch." Pairing live heterodyne
  with slow replay is the D240x's own design, not an OpenBat invention.
- Optional frequency-selective triggering, fed from the heterodyne output.

Why this shape and not the others: the '647 specification states its own
dichotomy as *discard some samples → monitor continuously* versus *output all
samples → reduced monitoring coverage*, and names the latter as what the
invention is distinguished from. The D240x pattern is squarely the distinguished
alternative. ATE, VTD and sampler mode are all the other branch.

**The decision was a commercial risk judgement, made by Niall, and is recorded as
one.** Free app, small user base, a mode strictly worse than WA's RTE, and a
design demonstrably predating the 2010 priority date by ~two decades — therefore
a poor enforcement target. That is a judgement about *likelihood of being sued*,
not a finding of non-infringement, and it is not clearance. The FTO opinion above
is still wanted. GB2480358B's claims are still unread.

Do not restate this section as a non-infringement argument. If a future reader
wants to widen the rule again, the thing to check first is whether the new mode
keeps up with a pass by deciding what to keep — if it does, it is the claimed
family regardless of how it is implemented.

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

### Pulse haptics (added 2026-08-09)

`Haptics/PulseHaptics.swift` renders each detected pulse as a haptic event.
Built as an **accessibility channel**: for a deaf or hard-of-hearing user it
replaces the listening modes rather than supplementing them, which is why it
does not depend on a listen mode being active and why every silent-failure path
is surfaced instead of swallowed.

**The Taptic Engine has no pitch dimension.** It is a resonant actuator with a
fixed resonance (~150–230 Hz), so call frequency cannot be reproduced at any
scale. Core Haptics offers exactly two axes and they carry one call property
each: **intensity ← pulse energy** ("how close"), **sharpness ← peak frequency**
("what kind", dull thud to crisp tick). Frequency must not drive intensity —
that spends the only proximity cue and makes a distant high call and a close low
one identical.

**Rate is a physical budget, and it is why there are two modes.** The actuator
needs ~30–50 ms between transients to be felt as two events; a feeding buzz runs
100–200 pulses/s. Per-pulse rendering there is impossible, not merely expensive —
the same class of limit as the Live Activity's message budget (§12). Above
`buzzEnterHz` (12 Hz, exiting at 8 Hz — hysteresis, for the same reason the
trigger needs it) the taps collapse into one continuous haptic whose intensity
follows the rate. The feeding buzz is the event a bat worker most wants to
notice, so it should feel like a different *thing*, not just faster ticking.

**Driven by detector metadata, never by samples.** Intensity and sharpness come
from `peakLevel`/`peakFrequency`. Resampling the call itself and pushing it
through the haptic engine at a slower rate would be a materially different thing
and would want reading against §5 first. Nothing here touches a sample.

Fed from `PulseDetector.onPulseStart`, which now carries `peakLevel` alongside
`peakFrequency`. The rising edge rather than `onPulseWindow`: the window callback
is already rate-limited to 20/s by `holdOffSeconds` and carries duration, which
looks like a free budget, but it only fires once the run has ended and it would
couple haptic behaviour to a detection knob the user can retune. Works in demo
mode and while backgrounded — both paths feed the same detector.

**Setup moved out of `init()` on 2026-08-15, and this is unfinished business.**
Reported symptom: haptics don't fire at all in the current build. Nothing yet
confirms a cause — the detector callback wiring is intact and the mapping is
unchanged — but `PulseHaptics` was violating the same rule §6 states for
`AudioEngineController`: it registered a notification observer *and started a
CHHapticEngine* in `init()`, and it is built as a SwiftUI `@State` default
expression, which SwiftUI may evaluate any number of times per view identity.
That was one leaked observer and one live engine per evaluation, all but one of
them owned by an object already discarded — several engines contending for one
actuator. Setup now lives in `activate()`, called once from ContentView's
`onAppear` beside `audio.activate()`, plus two restarts that were missing: on
leaving Low Power Mode (which had left the feature dead for the rest of the run
while `unavailableReason` reported it healthy) and on returning to the
foreground (iOS stops the engine when the app is backgrounded and
`stoppedHandler` is not guaranteed to have run before the next pulse).

**None of that is confirmed to be the reported failure**, and it wants checking
on a device before it is written off. If it still doesn't buzz, the next things
to check are whether `pulse()` is reached at all (the settings screen's live
`eventCount` answers that without needing a bat), and whether the
`.playAndRecord`/`.measurement` session is muting haptics despite
`playsHapticsOnly = true`.

**Known failure modes, all handled explicitly:**
- **Low Power Mode disables Core Haptics outright and silently.** A long night
  session will reach it. Untreated, this reads as "no bats tonight" to exactly
  the user who cannot check by ear. Mirrored from `ProcessInfo` and surfaced.
- No Taptic Engine (iPad): the settings section hides rather than offering a
  dead switch.
- The engine stops on interruption. Handlers hop to the main actor (Core Haptics
  calls them on an unspecified queue) and deliberately do **not** auto-restart —
  an interruption still in progress would spin. `ensureEngine()` rebuilds
  synchronously on the next pulse, so that pulse still renders.

**Untunable from the simulator** — `supportsHaptics` is false there, so the
feature is invisible and untestable. Everything below wants a device:

**The constants are engineering guesses, so all eleven are live.** A `Haptic` tab
in the tuning overlay edits every one of them against the running detector, and
they persist (unlike the VTD tab's knobs, which were live-only) — a value arrived
at in a field session survives the trip home. Defaults are reasoned from the
actuator's limits and `amplitudeThreshold`'s 0.5 default, not measured.

**The rate trace is the instrument, and the tab is built around it.** Two
thresholds cannot be set by reasoning — you have to see where pulse rate actually
goes during a pass and put the pair around it. The sparkline draws both
thresholds over the live rate, with the band between them showing the hysteresis
width directly. `currentRateHz` is computed at read time rather than cached,
because `recentPulses` is only trimmed when a pulse arrives: a cached value would
freeze at the last rate exactly when the trace needs to show it falling back
through the thresholds. Sampled from a `.task` loop rather than a `TimelineView`
body for the same reason — the trace has to keep moving when pulses stop.

`buzzExitHz` is held strictly below `buzzEnterHz` by both `didSet`s, and the exit
slider's range is capped by the enter value rather than letting the model clamp
silently — a slider showing a value the app has already overridden would be
lying. The gap between the pair is the real knob: wide commits and holds through
a dip, narrow tracks the bat closely but can flicker.

**Buzz mode is decided by pulse RATE** (`buzzEnterHz`/`buzzExitHz` with
hysteresis, over `rateWindow`), with a rate trace in the tuning tab carrying both
thresholds. Two measured findings sit under it, both from 2026-08-09
(`TimeExpansionTuning/haptic_rate.py`):

**Counting is one tap per pulse RUN, and that is correct. Do not count re-onsets
inside a run.** Tried, and it over-counted badly — live pulse rate went from ~2/s
to ~14/s — because an FM call's level dips below threshold mid-sweep. Of 71
re-onsets on the demo clip, **70 showed no frequency change at all** (−2 to
+2 kHz); a genuine new call restarts at the top of its sweep and jumps up, so
those were fragments of one call. Reverted, and `PulseDetector.onPulseRepeat` was
removed with them. This also invalidated an earlier "270–550 pulses/s bursts"
figure — that was fragmentation, not pulse rate.

**Rate does not find the demo clip's feeding buzzes, and this is unresolved.**
With correct counting the highest rates fall at 1.0, 3.6, 7.7, 23.7 and 24.7 s —
*not* at the buzzes (8.5, 9.2, 10.2, 11.2 s). A buzz's calls arrive closer
together than `maxGapMs` (6 ms), so they merge into ONE pulse run and the rate
reads *low*. Headroom over the 95th percentile never exceeds 2× at any window.
Niall hit this directly: he could tune the false buzzes out but never make a real
one fire.

Run length *does* separate them cleanly — over the clip's 139 runs ordinary calls
have a p95 of 17.3 ms and a longest of 19.3 ms, while the four buzzes are 34.0,
55.3, 60.7 and 64.7 ms, so any threshold from 20–30 ms picks exactly the buzzes.
That was built and then **removed at Niall's request**: it replaced controls he
had already tuned and understood, and the redesign was the wrong response to what
was reported as a counting bug. Recorded here as the measurement it is, not as a
plan. If the buzz case is picked up again, run length is where the signal is —
and the lesson is to add it beside the existing controls rather than in place of
them.

**Known limitation of any run-length approach:** a constant-frequency species
(horseshoe bats, calls of tens of ms) would read as a permanent buzz. No CF
material in the corpus.

> ⚠️ These knobs persist, so an existing install keeps its old values and must
> use **Haptic Defaults** to pick up the recalibrated ones.

**Still open:** the level window especially. `peakLevel` is normalised column
magnitude and the assumption that real calls land in 0.45–0.95 is inferred, not
measured — if quiet calls feel too weak or everything pins to maximum, that pair
moves first.

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
- **`.measurement` also attenuates the OUTPUT, and that is why live listening
  was quiet.** Reported 2026-08-15: live listening was near-inaudible at maximum
  system volume while file playback through the same speaker at the same volume
  was loud. The two paths differ in exactly one relevant way —
  `PlaybackEngine` runs the session as `.playback`/`.default`, live listening as
  `.playAndRecord`/`.measurement` — and disabling signal processing includes a
  substantial, non-adjustable cut to the output path. Dropping `.measurement`
  is barred (see the first bullet), so the compensation is digital and lives on
  the output side only: `AudioEngineController.listenOutputMakeupGain`, +12 dB
  with a quadratic soft knee from 0.7, applied once to whatever the listen mode
  produced. It cannot reach capture, the recorder, detection or calibration.
  The processors' own gains (heterodyne 6×, replay 4×) are unchanged and remain
  the per-bat knobs; this is a fixed correction for a fixed attenuation, and the
  figure is an estimate — it wants checking by ear against playback on a device.
- **A changed delivered rate has to hold before it is published.** Plugging the
  Griff in tears the engine down and rebuilds it, and while iOS renegotiates the
  route the input node hands out 48 kHz buffers for a few hundred ms before the
  native stream settles — more than once if the device enumerates more than
  once. Published straight through, that flicked the mic pill between a red
  "48 kHz" and a green "384 kHz" while the user watched, which reads as "the mic
  doesn't work" at the exact moment it started to.
  `AudioEngineController.publishDeliveredRate` debounces it asymmetrically: a
  rate at or above the current one is believed in ~0.33 s, a DROP below it — the
  alarming claim, and the one a transient produces — has to survive ~1.5 s. The
  first rate of a capture is still adopted immediately, since there is nothing
  on screen yet for it to flicker against.
- **Acoustic feedback has no software fix.** Listening audio played out the
  built-in speaker gets picked back up by the mic and reprocessed as a spurious
  low-pitch "call" layered on the real one. Full echo cancellation risks
  degrading the ultrasonic capture path, so the app only warns and tells the
  user to wear headphones — which is confirmed to fix it.

### 2026-08-09: a listen-mode switch no longer restarts the engine

Switching listen mode used to `stop()` then `start()` unconditionally. Three
things fell out of that, all visible: the Start button flicked back to its idle
ear, the spectrogram's frequency axis collapsed to 24 kHz and snapped back, and
— because `ContentView.onChange(of: audio.isRunning)` fires on the way down —
**an armed recorder was silently disarmed on every mode change.**

The restart was never required by the mode itself. It was required by how the
mode was *read*: the tap closure captured which processors to feed, and the
output source node captured which output to render, both fixed at install time.
Changing the mode therefore meant rebuilding both, i.e. a new engine.

Now `AudioEngineController.liveMode` is an `Atomic<Int>` mirroring `listenMode`,
read per capture buffer by the tap and per callback by the render block. One tap
and one node serve every listening mode, so **heterodyne ↔ slow replay is a
single atomic store** — no gap in capture, no `isRunning` transition, LO and
auto-tune left where they were.

Two things this does not change, and one hazard:

- **Crossing `.off` still restarts, and must.** The session category itself
  differs (`.record`/`.measurement` when merely detecting — the proven 384 kHz
  path above — versus `.playAndRecord` to reach the speaker), and changing
  category means deactivating and reactivating the session. `isActive`
  (`isRunning || isSwitchingListenMode`) covers the UI for that window;
  `startEngine` no longer overwrites a known `actualSampleRate` with the input
  node's provisional format rate, which is what moved the frequency axis.
- **Anything acting on capture genuinely being down must still read
  `isRunning`**, not `isActive` — finalizing a pass, stopping the background
  pump, session teardown.
- **`SnippetExpansionProcessor.reset` reallocates its ring buffer.** On an
  in-place switch it must be called *before* the new mode is published, while
  the audio thread still isn't touching that processor. The other order is a
  use-after-free, not a glitch.

### 2026-08-15 audit: a listening mode that goes deaf, and a recorder that lied

Both found by a full-codebase sweep, both fixed the same day.

- **`.heterodyneOnly` routing parked slow replay in `.replaying` forever.** The
  snippet phase machine's only route back to `.recording` is the tail of
  `SnippetExpansionProcessor.render`, and `process()` refuses to capture while
  the phase is `.replaying`. The `.heterodyneOnly` branch of the output node
  rendered heterodyne and never called `snippet.render` at all — so the first
  trigger after choosing that routing stopped capture permanently, silently,
  until the user changed routing again. The comment on that branch claimed it
  avoided a restart; it caused an indefinite freeze instead, which is worse. Now
  the branch renders the snippet into the mixing scratch and discards the audio,
  and the `.both` path's `n > mixCapacity` bail-out does the same rather than
  skipping the call. **The rule this leaves behind: a state machine driven from a
  render callback must be advanced on every path that callback can take, including
  the ones where nothing is audible.**
- **Failed PCM writes were still counted in the WAV's declared length.**
  `write()` used `try?` and advanced `dataBytes` regardless, so a disk that
  filled mid-bout produced a header claiming more PCM than existed, a GUANO
  chunk written past real EOF, and a `Recording` handed to the store as if it
  had saved normally. This is review item 5.5 in §15, which the table records as
  fixed and which was not — worth remembering when reading that table. Writes
  now advance the counter only on success, one failure condemns the segment, and
  the reason surfaces through `AudioRecorder.lastWriteError` rather than the
  recording simply never appearing.
- **`AudioRecorder.append` allocated on the realtime thread.** It copied each
  capture buffer into a fresh `Array` before handing it to the recorder queue —
  ~187 allocations a second at 384 kHz, on the thread this project bans
  allocation on, while every sibling DSP type already used a preallocated ring.
  It now writes into a lock-free SPSC ring (`captureRing`) and the queue drains
  it; `handle`/`write` take an `UnsafeBufferPointer` so the drain can coalesce
  several buffers into one pass.

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
- **The WAV player's GUANO card is collapsed by default** (2026-08-15,
  `display.wavPlayerShowFileInfo`). It is reference material consulted
  occasionally, not while reading a call, and it was taking a fifth of a small
  phone's screen permanently. The spectrogram is the only
  `frame(maxHeight: .infinity)` element in either layout's stack, so the space
  the card gives up goes to it directly and nothing else can absorb it — which
  is what makes closing the card fill the screen with spectrogram rather than
  leaving a gap.
- **Columns are batched before upload** — 1–2 `MTLTexture.replace()` calls per
  frame instead of 12–25.
- **The colormap is defined twice** (Metal shader for GPU, `DisplayPalette` for
  CPU-rendered images) and must be kept in sync by hand.
- **NABat's magma colormap is fixed and unrelated** to the user-selectable
  display palette — it has to match what the model was trained on.

### The species readout left the stats card (2026-08-16)

It had its own full-width row there, added earlier the same day so the code
wasn't rendering as "MY…" in a 60 pt cell. Once the pulse panel became a species
feed — permanently in simplified view, and by a toggle in advanced — the same
identification was on screen twice: once in a cell with no room for it, and once
in a pane with room for the common name, the pulse thumbnail and the runners-up.
The stats card is back to one row of five measurement cells (and, in simplified
view, no row at all).

`SpeciesStatCell`/`SpeciesStatCellContent` went with it, ~138 lines. The book
icon that opened a species' field-guide page without leaving the detector went
with them and was **immediately reinstated on the species feed's own rows**,
which is the better home for it: that row already *is* the species. It is a
separate tap target from the row, deliberately — the row opens the pass detail
(the evidence behind this identification) and the book opens the profile (the
animal itself), and one tap cannot serve both questions. The button is absent
when the guide has no page for the code, which is the common case: the models
name far more bats than the community guide describes, and a link to a page that
doesn't exist is worse than no link. `SpeciesGuide.species(forCode:)` is the
lookup, joined on scientific name — see `SpeciesGuideLookup.swift`.

### The stats card sizes to its content (2026-08-16)

It was a `RoundedRectangle` with the readouts in an `.overlay`, given a
hard-coded 126 pt frame. An overlay takes its host's size, so once the content
needed more than 126 pt it overflowed and the `.clipShape` cut it — and because
an overlay is *centred*, it cut the top and bottom at once, which reads as the
card being cropped rather than as content that doesn't fit. Advanced view had
quietly crossed the line when the species readout was given its own full-width
row earlier the same day; the tab-bar work is only what made it visible.

The card is now a `VStack` with a `.background`, so it is as tall as what it is
showing, and the 42/58 pane split is measured by a `GeometryReader` nested
*below* it rather than one wrapped around all three panes subtracting a guess at
the card's height. **Don't reintroduce a fixed height here**: every element in
the card (pills, stat cells, species row, meter) has a natural height, the
simplified/advanced difference then costs nothing, and Dynamic Type stops being
able to clip it.

### Navigation, and iPhone going portrait-only (2026-08-16)

- **A bottom tab bar replaced the leading logo menu.** Detector, Sessions,
  Species and Playback (Playback has since been folded into Sessions — see
  below) were two taps deep behind a menu whose icon was the
  current section — discoverable only if you already knew it was a menu. This is
  the change deferred at the acceptance review; it landed together with the
  landscape decision below, which is why the two are one entry.
- **The tab glyphs, and why two are not symbols** (2026-08-16). Detector and
  Species are **drawn artwork** (`batCall`, `batBook`) — a bat with call waves, and
  a solid book with a bat knocked out of it. Neither has an SF Symbol that says the
  right thing: `book.closed` says only "book", and Detector's previous glyphs said
  less each time (the generic `waveform`, which is *also* what the session button
  wears while a session is live so the bar carried one shape twice; then
  `wave.3.up`, ultrasound with no bat in it). Sessions stays a symbol —
  `waveform.path.ecg.text.clipboard`, a trace on a clipboard: a logged outing.
  - `AppSection.icon` therefore returns an `Icon` enum rather than a symbol name,
    resolved through `AppSection.iconImage` / `iconSized(_:)`. The two kinds size by
    *different means* and neither works on the other: a symbol takes its size from
    `font` and ignores a frame (overflowing it — `frame` does not clip), an asset
    carries pixel dimensions and ignores `font`.
  - **The two assets have opposite orientations**, so `iconSized` normalises on
    HEIGHT with the width derived from each image's own aspect ratio. Fitting a
    landscape glyph into a square box binds it on width, which drew the bat call
    around three-quarters the height of everything beside it.
  - **Resolving a glyph is cached, and has to be.** Deciding what to draw costs a
    `UIImage(named:)` or a `ProcessInfo.isOperatingSystemAtLeast`, and it first ran
    inside `body` — three image lookups per glyph per layout, on chrome present on
    every tab that re-lays out with the live audio stats. Nothing about the answer
    can change while the app runs.
  - **`waveform.path.ecg.text.clipboard` is iOS 18.1 and the deployment target is
    18.0**, hence `Icon.symbol`'s `fallback`/`since`. `Image(systemName:)` does not
    fail loudly for a symbol the running system has never heard of — it draws
    nothing — so without the fallback that tab would silently lose its glyph on an
    un-updated phone.
  - **`.asset` carries a fallback symbol for the same class of silent failure:** an
    imageset whose files are missing is only a build *warning*, and it renders a
    blank tab.
  - **Regenerating the artwork:** the masters (`bat_book.png`, `bat_call.png`,
    white-on-transparent) live **one level ABOVE the repo root**, beside
    `Quarantine/` — so they are untracked, absent from a fresh clone, and only the
    downsampled imageset PNGs travel with the repo. Both **bleed to all four canvas
    edges**. An SF Symbol carries optical padding inside its own box, so the export
    bakes in a 7% transparent margin and `iconSized(_:)` then uses the *same* box as
    a symbol's point size, not a larger one. Skip either half of that and the
    artwork renders visibly heavier than the symbol beside it. Exported to a fixed
    30 pt HEIGHT (30/60/90 px) — never a fixed width, see the note above —
    template rendering intent, so both bars tint it like a symbol.
- **Two implementations, split on iOS 26.** Above it, a real `TabView`: the
  glass, the travelling indicator, minimize-on-scroll and the way the bar hands
  its height to each screen's safe area are all the system's, and none of it is
  reproducible from outside. Below it there is no Liquid Glass to adopt and the
  stock bar is an opaque slab, so a hand-built floating bar is genuinely better
  there. Written once in `AppTabBar.swift`.
- **The session button is a tab that is never selected.** The design needs a
  control detached to the trailing side of the bar, which is not something you
  can add to a `TabView` — but `Tab(role: .search)` is rendered as its own
  circle beside the bar, which is exactly the arrangement. Selecting it is
  intercepted in `ContentView.tabSelection` and turned into an action, so the
  selection never moves off the section you were on.
- **That tab is painted by the bar, and it costs two things. Both measured in
  the simulator on 2026-08-16, both worth knowing before anyone tries to
  "improve" the button.**
  1. **The bar ignores every SwiftUI modifier on that label, so the glyph is a
     baked bitmap.** `Image(uiImage:)` built with an explicit
     `UIImage.SymbolConfiguration` and `.withTintColor(_, .alwaysOriginal)`:
     the colour is in the pixels and the point size is ours, so there is
     nothing left for the bar to override. It is a white play triangle when
     idle, orange waveform bars while live, a white cross when the menu is
     open — all bare glyphs, sized per symbol.

     What was tried first, and what each attempt proved, because every one of
     them looks like it should work:
     - A semantic colour (`.primary`) resolves in the *bar's* environment, which
       behaves as though its glass were light — it rendered near-black, leaving
       the button all but invisible on launch. `.preferredColorScheme(.dark)`
       does not reach inside the bar.
     - `.monochrome` is repainted white whatever concrete colour it is given.
     - `.palette` does hold a colour, but only for a symbol with a solid layer
       of its own: a bare `waveform` comes back white. Keeping the circle and
       painting it `.clear` works, at the price of a much smaller glyph, since
       the bars are inset inside an enclosure that is no longer visible.
     - Naming one palette layer leaves the others washed out.
     - `.imageScale` and `.font(.system(size:))` both do nothing at all.
  2. **Nothing inside that button can animate.** The bar renders a `Tab`'s label
     as a still image. `.symbolEffect(.variableColor)` on the live waveform —
     the obvious way to make "we are listening" read across a dark field, and
     what the pre-26 button gets from its Lottie ear — does nothing at all. The
     one route left is a timer that swaps the symbol or the tint on a tick,
     since a *value change* does re-render the label; it was judged not worth
     permanently invalidating system chrome for. So the live state rests on
     colour and shape — **and anything that has to move goes outside the
     button**, which is what the recording glow below is.
  3. **The recording glow is drawn by us, in our own view tree, and so it can
     animate.** A tight blurred ring hugging the button's edge while the
     recorder is armed: breathing while armed and waiting, steady once a
     segment is open — the same two states, from the same helpers, as the
     record glyph in the transport menu, so the two can't drift apart. In the
     session accent, matching the waveform glyph inside the button, so the two
     read as one object breathing rather than a light of one colour behind a
     glyph of another. Only its opacity animates: a `repeatForever` picks up any
     later change to its view's geometry (§13), and an opacity-only pulse gives
     it nothing to catch hold of.

     **It goes in the content layer, and the glass does the rest.** The glow is
     an overlay on each tab's *screen*, not on the tab host — everything drawn
     there is under the floating bar, so the bar's Liquid Glass ends up over the
     glow and occludes it, refracts it and picks up its colour, exactly as it
     does the spectrogram scrolling beneath it. What you see is the button
     itself lit from within. The element is a plain soft disc: no mask, no ring,
     no cut-out, sized to the button, because the glass spreads whatever is
     under it and anything larger reads as a cloud behind the bar rather than a
     glowing button.

     The first version was an overlay *on top* of the bar with the button's
     footprint punched out to fake the occlusion, and every problem it had came
     from re-implementing by hand what the glass gives for free: a square halo
     where the mask clipped the blur (a blur spreads past its view's frame, so a
     mask shape that merely fills that frame slices the spread off), and a
     bright crescent wherever the punched hole missed the button's real position
     by a point or two. It read as a ring stuck to the screen. **If something
     needs to appear behind system chrome, put it under the chrome rather than
     drawing a picture of being under it.**
  4. **Where the system puts that button is asked at runtime, never assumed —
     `SessionButtonLocator`.** It finds the button in the view hierarchy and
     publishes its frame in window coordinates; the glow, the transport menu and
     the tap catcher position themselves on it, and draw *nothing* until it is
     found.

     **How it identifies the button was wrong for a day, and the way it was
     wrong is the lesson (2026-08-17).** It matched on the accessibility
     identifier the Tab's label sets, falling back to that label's text —
     public API, ours, no private class names, and it worked in every
     simulator. It has never worked on a physical device. A hierarchy dump from
     an iPad on 26.6 holds 465 views and **not one accessibility identifier or
     label on any view**, including the ones the app sets them on: UIKit does
     not materialise accessibility attributes until an assistive technology asks
     for them, and a simulator has accessibility switched on for UI automation.
     So the glow, the transport menu, the tap catcher *and* the guided tour's
     tab spotlights were all correct in the simulator and all missing on
     hardware, with no error anywhere.

     Two things follow, and the second is the general one:
     - **The bar is not a `UITabBar`.** On iOS 26 it is a `_UIFloatingTabBar`,
       and `Tab(role: .search)` is not among the ordinary item cells — the bar
       puts it in a pinned-items view of its own beside the collection holding
       the rest. That is what now identifies it, by class *name*: introspection
       only, nothing private is called, and it can stop matching on any OS
       release. The accessibility match is kept ahead of it, for VoiceOver and
       UI tests. The cost of this backstop is accepted knowingly; the failure
       mode is the documented one, nothing found so nothing drawn.
     - **A frame found once is not a frame that stays true.** The probe that
       does the searching was a zero-sized background view, so its bounds never
       changed and UIKit never called `layoutSubviews` on it — meaning rotating
       an iPad never triggered a fresh look. The bar is centred, so a rotation
       moves the button by half the change in screen width: 180 points on an
       11-inch iPad, which is where the glow, the transport menu and the tour's
       spotlight all drew. Diagnostics caught the locator holding 535 while the
       live hierarchy said 715. The probe now fills its parent (a background
       affects no layout at any size) and re-checks in a short burst after every
       layout pass, because being told our own geometry changed does not mean the
       bar has moved to its new place yet.
     - **A simulator is not a device for anything that reads the view
       hierarchy.** Accessibility is one difference; layout timing is another
       (the search originally gave up after four tries in the first second,
       which a Mac always wins and an iPad launching Metal and the audio engine
       need not). Debug carries a **Session Button** card reporting the located
       frame — or "Not found" — and sharing the whole tree, because on a device
       there is no console to read.

     **This replaced three hand-measured constants, and the constants were not
     merely imprecise — they were unfixable.** What they cost, recorded so
     nobody reaches for them again:
     - Two attempts to derive the iPhone offset from the home-indicator inset
       were wrong in *opposite* directions, one pushing the glow off the bottom
       of the screen. The value is anchor-dependent: a tab page is inset by the
       bar's height, so it differs depending on whether the drawing hangs off
       the page or off the tab host.
     - **iPad has no detached button at all.** iPadOS 26 draws the bar as a
       centred floating pill at the *top* and renders the search-role tab as the
       last item **inside** it, at a position depending on the pill's width and
       so on the tab titles and the language. No constant can describe that.
       Positioned by the iPhone numbers the invisible tap catcher landed on the
       Settings gear, where it would have silently eaten every tap on it.
     - The button is **62pt on iPhone and 36pt on iPad**, not the 58pt the
       metrics assumed. Both the glow and the catcher now take their size from
       the measurement, which is why they fit on both.

     Verified on both simulators by rendering the catcher in a visible colour —
     `sessionTapCatcherTint` is left in place for exactly that, since a tap
     target cannot be checked by tapping in a simulator but a coloured disc that
     covers the button is the same proof.

     **The transport menu now hangs off the located frame too**, growing
     directly out of the button — above it on iPhone, below it on iPad. It was
     pinned to the window's trailing edge, which on iPad left it over at the
     screen's edge with nothing above it while the button sat in the middle of
     the pill. Its width matches the button rather than being a fixed 78pt,
     floored at `TransportMenuMetrics.minimumWidth` because the button is only
     ~36pt on iPad and the captions have to survive — they are not decoration,
     four listening states hide behind one glyph.

     **The "you're not recording" nudge is the last thing still positioned from
     the metrics**, so it is misplaced on iPad — it points at the session button
     while appearing at the top-trailing corner. Left alone rather than changed
     unasked; anchoring it needs clamping too, since it is a wide box and the
     button is near a screen edge.
  3. **The Detector indicator blinked off and back on every tap of the session
     button — fixed by taking the tap before the bar sees it.** The bar moves
     its own indicator to the tapped tab, our binding refuses to store the
     selection, and it animates back when the next read returns the section
     unchanged. Refusing the selection is always too late: intercepting it is
     the only hook a `TabView` gives us, and by the time the hook runs the
     indicator has already moved.

     The fix is an invisible disc laid over the system's button, taking the tap
     with a plain gesture and calling the same handler, so the touch never
     reaches the bar. It is sized to the button **exactly**, not generously: it
     sits next to the last tab (Playback at the time, Species now), and a
     catcher that overhangs would swallow
     taps meant for it, which is far worse than the blink. Erring small means a
     tap near the rim occasionally slips through and blinks, which is only what
     used to happen anyway. The `.sessionControl` case in `tabSelection` stays
     as the fallback for VoiceOver, keyboard activation, and anything the disc
     misses.

     Diagnosis note, since the obvious suspect was wrong: **it was never the
     transport menu.** With the menu opened programmatically, bypassing the tab
     entirely, the indicator holds a constant value for a whole capture — so the
     `repeatForever` pulse inside the menu (§13) is not leaking again.

  **How to measure any of this, because the obvious way silently lies.**
  `xcrun simctl io … screenshot` returns a byte-identical frame every time on a
  screen that is demonstrably animating: the transport menu's record pulse,
  which is unquestionably running, showed *zero* variation across a dozen
  screenshots. Any conclusion of the form "the animation isn't running" drawn
  that way is worthless, and one was drawn that way here before the control was
  run. Use `simctl io … recordVideo`, split it with `ffmpeg -vf fps=10`, and
  keep a known-animating region in frame as a control — the record pulse shows
  its full 1.8 s cycle that way, which is what makes the session button's
  stillness in the same capture mean something.
- **The transport controls moved into a menu on that button.** Start is the
  first tap; once a run is going, the second tap opens a vertical menu with
  Record, Listen and End. The control bar under the panes is gone. Roughly a
  wash on vertical space — the bar costs about what the control bar gave back —
  and it puts starting a session under the thumb rather than in a row of three
  equal-weight buttons where it read as no more important than the others.
- **Two of the three menu items dismiss it, and Listen does not.** Arming the
  recorder and ending the session are each a single decision, so the menu gets
  out of the way and hands the screen back. Listening mode is a cycle of four
  found by ear, and making the user reopen the menu between taps would be four
  times the work to choose between them, in the dark, mid-pass.
- **⚠️ `isRunning` is the engine, `isActive` is the session, and confusing them
  cost two bugs in one `onChange` block (2026-08-16).** Cycling listening mode
  across "off" stops and restarts the engine, so `isRunning` dips false
  *mid-session*. The block keyed to it treated that dip as "audio stopped" and
  did two things it should not have: it closed the transport menu — on the one
  control in it you are meant to tap repeatedly — and it **disarmed the
  recorder**, silently ending recording with nothing but `startDetecting` able
  to re-arm it. Both now test `audio.isActive`. Anything in that block that
  represents an intent about the *session* rather than bookkeeping about the
  *engine* belongs behind the same test; finalizing the open pass and stopping
  the drain pump correctly stay keyed to the engine.
- **The menu is deliberately NOT in `menuIsOpen`.** Same reasoning as the tuning
  overlay: it is opened mid-pass, with a bat overhead, to change what you are
  hearing. Pausing the render loop underneath it would stop the thing it exists
  to control.
- **iPhone is portrait-only; iPad keeps every orientation.** Set per-idiom in the
  build settings (see §14). The whole iPhone-landscape family — the three-column
  layout, the stats sidebar, `PulseStatsColumn`, `VerticalAmplitudeMeterView`,
  the floating transport panel and the full-screen-spectrogram mode — is
  deleted, not disabled. Niall's call, on two grounds: a bottom bar costs the
  vertical space landscape is shortest on, and that layout had never once been
  run against real bats, so there was no evidence it was worth keeping. iPad
  landscape is untouched — it has the width for its own two-panel arrangement.
  **If iPhone landscape is ever wanted back, it is a rebuild, not a revert:**
  the honest version is a rail along the device's bottom edge (so the bar keeps
  its position under the user's hands through a rotation), which means
  hand-building the bar on iOS 26 too and giving up the system one.
- **iPad landscape's middle row is fixed: species list left, pulse close-up
  right** (Niall's call, 2026-08-17). It used to be the other way round, and
  simplified view's override — which forces the pulse card to show species ID,
  because in the stacked layouts the toggle that would bring it back is hidden —
  then applied there too, so the row was the same species list twice. iPad
  landscape is the one place that override runs backwards: the pulse card shows
  the pulse, because the list already has a panel of its own beside it. That
  does not weaken the rule in `SimplifiedView`, whose whole point is that a
  hidden toggle must never leave the user with no route to species ID — here the
  route is the adjacent panel. Advanced view is untouched, since its toggle is
  visible and overriding a visible control makes it inert.

### The sun clock in the nav bar (2026-08-16)

The tab bar left the detector's leading nav-bar slot empty (the logo menu that
used to be there became the bar). It now holds a **sun pill**, because the single
most useful thing the app can tell someone standing outside with a detector is
whether they are in one of the two windows bats are actually busiest in: the few
hours after sunset, and the hours before sunrise.

- **Four states.** Daylight shows when the sun sets. Inside the first 15% of the
  night it counts *up* from sunset ("+1h 45m"). Through the middle it shows the
  sunrise *time*. Inside the last 15% it counts *down* to sunrise ("in 1h 45m").
  `SunWindow.Phase`.
- **The two windows are fractions of the night, not fixed hours** — Niall's
  revision within the hour of the first cut, and it is the better model. The first
  version counted up until *local midnight* and down for a fixed *two hours*.
  Midnight was doing the job badly, because it is a calendar accident rather than
  a fact about the night:
  - On a long midwinter night (16h 10m in London) the count-up ran from 15:54 to
    midnight — **eight hours** of "you are in the emergence window", which is
    simply false for most of it. It now stops at 18:20.
  - On a short midsummer night the same rule was the reason 00:30 fell into
    neither window while only three hours past sunset. That is now principled
    rather than accidental: it is the quiet middle, because the evening window
    closed at 22:28.
  - `activityWindowFraction = 0.15` lands close to the two hours it replaced where
    it matters most — 1h 46m at the equinox, 1h 24m in mid-August, 1h 06m at
    midsummer. Midwinter's 2h 25m is the outlier, and UK bats are hibernating
    then anyway.
  - **It also removed the calendar from the problem entirely.** No `Calendar`, no
    time zone and no DST question anywhere in `SunWindow` now — every boundary is
    a position within one measured night. The time-zone handling did not get
    better, it stopped being needed.
- **Orange sun glyph, white readout, and no background of its own** (Niall, same
  day, replacing a first pass that used the in-panel status pills' accent-vs-
  secondary colouring). Two things follow from it:
  - An `ultraThinMaterial` capsule — right for a pill sitting on the spectrogram,
    which is where every other status pill lives — composites over the nav bar's
    own material and reads as a **grey slab inside the glass**. A pill in the bar
    draws no background at all; the bar is the background.
  - Colour no longer separates an activity window from a reference state, so that
    signal rests entirely on the **filled-vs-hollow glyph** (the same
    active/inactive distinction SF Symbols uses system-wide). `SunWindowPill.icon`
    composes the fill from `Phase.isActivityWindow` rather than spelling it out
    per case, so the two cannot drift apart. The number stays white because it is
    the value being read, in the dark, at a glance.
- The clock states read "at 20:24" rather than a bare time, which beside a
  sunrise glyph is ambiguous about whether it has already happened.
- **Day and night are decided by which sun event happened most recently, never by
  clock hour.** And `SunTimes` resolves which solar day it means from the *UTC*
  date handed to it, so asking it for "today" gives the wrong night anywhere far
  from UTC — an evening in New York read as daylight. `SunWindow` reads a
  three-day window and picks the events bracketing *now* instead. There is a test
  for exactly that.
- **The open question the fraction does not settle:** whether an activity window
  *should* scale with the night at all. Emergence is triggered by light level, so
  a bat leaves the roost at roughly a fixed offset after sunset whatever the
  season — which argues for a fixed lead. The fraction is nonetheless the better
  of the two available rules, because the fixed lead it replaced was not that
  either (it was "until midnight", which scales the wrong way — longest window on
  the longest night). If this is ever revisited with real field observations, the
  shape to try is a fixed lead *capped* by a fraction of short nights.
- **Tapping it opens an explainer popover** (Niall's ask, same day). The pill on
  its own is a number beside a sun and never says why a *bat detector* is showing
  a sun clock; the popover answers that. It leads with tonight's real sunset and
  sunrise, then the reason those hours matter, because the times are the part a
  user acts on tonight. It also names the window length in minutes rather than as
  "15%" — the fraction is the implementation, and what the user wants is how long
  they have got.
  - `SunWindow.night(at:coordinate:)` exists for this: `phase` only ever carries
    the one event it is measuring against, and the popover shows the pair. It
    picks events the same way `phase` does, and a test pins the two to the same
    night from both sides of sunset — the one way they could drift.
- **Shown in simplified view too.** It is not instrumentation — knowing to go out
  at dusk is more use to a beginner than to anyone else.
- **No `tourDemo` stand-in**, unlike every other status pill. It used to be that
  the nav bar was hidden for the whole tour, so a forced phase had nowhere to
  appear; since 2026-08-17 the bar stays up and the tour spotlights the pill
  directly (`TourID.sunClock`), which is better than a demo phase anyway — it
  points at the real readout. A `.tourTarget` on a `ToolbarItem` does publish its
  anchor, unlike one inside a `Tab` label; both were checked in the simulator.
- Renders nothing at all with no location fix — there is no sensible default
  sunset.
- **⚠️ Never put a `TimelineView` in a `ToolbarItem`. This one did, and it broke
  the whole Detector screen.** Everything on that screen — the Metal spectrogram,
  the recording glow, the session button's glyph — dropped to roughly one update a
  second, while every other screen stayed perfectly smooth. A `TimelineView` in
  toolbar content pulls the navigation bar into its update cycle, and the nav bar
  is chrome the whole screen is laid out against.
  - **The symptom that identified it:** dragging the spectrogram also only redrew
    once a second. No amount of *work* inside a pill can throttle a gesture, so
    the fault had to be the update mechanism rather than its cost. Cost was the
    first thing suspected and it was the wrong tree entirely. The other half of the
    diagnosis was the scope — the pill is the only thing that exists on the
    Detector and nowhere else, which matched the boundary exactly.
  - **The shape that works:** plain `@State`, written by a `.task` loop that sleeps
    to the next wall-clock minute. A `@State` write invalidates the pill and
    nothing above it, which is the property a toolbar needs; the digits still turn
    over on the minute. `Detector`'s panel-header pills (`SessionTimerPill`,
    `MicStatusPill`) may keep their `TimelineView`s — they are in the *content*,
    not the bar.
  - ~~The `.task` lives on a `Group` wrapping the whole body rather than inside the
    `if let`: a `ToolbarItem` hosts one view, and the task has to stay mounted
    while there is nothing to draw, or the first location fix never gets picked up.~~
    **This was not enough, and the pill did not appear at all (2026-08-17).** The
    `Group` keeps the task attached to the *view*, but it cannot make SwiftUI host
    a toolbar item that renders empty — and if the item is never hosted, nothing
    on it runs. That closed a loop: the phase was stored `@State`, filled in only
    by the task, so the first render had nothing to draw → no item → no task → no
    phase, forever. The pill was never visible after the `TimelineView` rewrite;
    it read as "the fix removed it".
    - **The shape that actually works: derive the readout in `body`, store only
      the instant.** `asOf` is the sole `@State`, advanced by the tick loop;
      `phase` is a computed property off `asOf` and the coordinate. The first
      evaluation that has a coordinate already draws something, so the item is
      hosted, so the task runs — the dependency now points the safe way round.
      This is what the memoisation below was *for*.
    - **The general rule: never let a `ToolbarItem`'s content depend on state that
      only something attached to that item can set.** Compute it, pass it in, or
      hold it somewhere that stays alive when the item does not.
- **`SunWindow.phase` is memoised, and that is not an optimisation.** It is what
  makes it safe to call from a body at all: it ran three passes of the sunrise
  equation, and under them `SunTimes` was constructing a `Calendar` — an ICU setup
  — three times per call. The calendar is now a static built once, and the solar
  events are cached per day and per ~1 km of position. A `TimelineView` re-runs its
  content whenever its *parent* invalidates, not only when its schedule fires, so
  "once a minute" was never the real call rate even before the rewrite above.

`SunTimes` itself (the sunrise equation, and why it is on-device rather than
WeatherKit) came from separate work; it did not compile as delivered — the
`times(for:on:zenith:)` parameter named `date` shadowed the static
`date(fromJulianDay:)` helper, so both return values failed to resolve. Fixed by
qualifying with `Self.`.

### Screen cleanup pass: Species and Sessions (2026-08-16)

A round of Niall's own review notes, after the tab bar shook out what each screen
was actually carrying. Each item is small; the theme is that permanent chrome was
explaining the app's internals in the app's smallest type.

**Species tab.**
- **The guide's version/source/updated card is now an "i" popover in the toolbar.**
  It was a footer floating at the bottom of the globe and it was *colliding with
  the tab bar*: the globe carries `ignoresSafeArea(edges: .bottom)` for its
  imagery, and the footer overlay was applied BEFORE that modifier, so it expanded
  along with the map and sat under the bar. **Order matters there** — ignore the
  safe area first, overlay afterwards. Only the "Tap a region to explore its
  species" hint stays on the globe, since that is instruction rather than
  reference.
- The Sources sheet moved to the view root with it. It had been attached inside
  the footer, which only exists on the globe branch — so typing a search
  destroyed its presenter mid-flight.
- **Opening that sheet from the popover has to be deferred a beat.** Presenting a
  sheet while the popover it was tapped in is still dismissing gets silently
  dropped by SwiftUI, and the link read as completely dead. Same failure and same
  fix as the import-error alert being swallowed by the file importer's own
  dismissal (`SessionsView.reportImport`) — that is twice now.
- **The search field is a Liquid Glass capsule floating over the globe**, not a
  bare `TextField` in a black strip above it. The strip was pushing the globe down
  the screen for nothing. A `.onTapGesture` hands the whole capsule to the field:
  the glass shape is the hit target, but a `TextField` only takes focus from a tap
  landing on the field itself, so the padding around it would otherwise be dead.
  The *results* branch keeps a solid strip — a list scrolling under a floating
  pill is unreadable.

**Sessions.**
- **No unclassified-recordings filter in the toolbar.** It is a list of outings,
  not of classifications. The filter still exists inside a session, where the
  recordings are.
- **Which forced a real decision:** with no control on that screen, the "Not in a
  session" section must not filter either, or a recording could be hidden with
  nothing to tap to bring it back. It now shows everything. The old
  reveal-the-filter-on-NoID-import hack went too — an import lands in that
  unfiltered section, so flipping the setting would only have changed a filter
  somewhere the file never appears.
- **The "N pinned of M IDs (≥ 60% · ≥ 3 pulses)" caption under the map is gone.**
  It explained the map's own thresholds, in the language of the settings that
  cause them, to answer a question nobody had asked.
- **A session opens on its summary, then its files.** Species chart, then a new
  detections-over-time chart, then recordings — the two charts used to sit *below*
  the recordings list, which put the file list where the summary belongs.
- **Detections over time** is the new chart: one bar per slice of the session, time
  on the x axis. It answers a question the species chart cannot — a hundred IDs
  spread over four hours and the same hundred in one twenty-minute burst are an
  identical species chart and completely different nights.
  - Hand-built from `Capsule`s, not Swift Charts: the app has one visual idiom for
    a bar (`SessionSpeciesSummary`, `ScoreBar`, the pulse stats) and two would be
    worse than free axes are good.
  - Bucketing lives apart from the view in `SessionActivity` and **is tested**,
    because a chart cannot show that it dropped a detection — a bar one shorter
    than it should be looks exactly like a correct one. Width comes from a fixed
    list that divides an hour, so edges land on round clock times; empty stretches
    are zero-height bars, never missing ones, or the axis silently compresses and
    misstates the shape of the night; and detections outside the session's own
    recorded bounds still count, since a running session has no end date.
- **Both charts carry an "i" popover.** The species one earns it: those bars count
  *detections*, not individual bats — one bat circling a pond is logged many times,
  two overhead at once may be logged as one. No bar chart can say that, and the
  honest version is a paragraph, not a longer label. `SessionChartHeader` owns its
  own presentation state so each popover anchors to its own button; hoisting that
  state into `SessionDetailView` anchors both to the whole List and points the
  arrow at the middle of the screen.

### Playback folded into Sessions (2026-08-16)

Niall's call, a few hours after the tab bar landed. The bar made an existing
duplication impossible to ignore: **Playback and Sessions were listing the same
recordings, in the same session buckets, one tab apart.**

- **A recording had two different destinations, and which one you got depended on
  where you tapped it.** From Playback it opened the player — the zoomable
  spectrogram, transport, listening modes, call analysis. From Sessions it opened
  a static detail page: a stretched thumbnail of the same spectrogram, four
  labelled fields, and the per-pulse IDs. Neither screen could reach the other,
  so hearing a call and reading its evidence were two navigations from the list,
  not one from the other.
- **Now: every recording row opens the player, and the IDs are a sheet over it.**
  A plain "Pulses" text button sits beside the GUANO Metadata disclosure row.
  Both live in the same card because they are the same kind of thing — reference
  material consulted about the file you are listening to — but the IDs are a
  sheet rather than a second disclosure: the card's whole reason to collapse is
  to give the spectrogram its height back, and a list that pushes its own detail
  screens would take more of it than the metadata ever did.
- **The Sessions/Recordings segmented picker is gone too.** Every outing has been
  a session since the acceptance-review follow-up, so that second tab was showing
  an empty list to almost everyone, permanently, in exchange for a control at the
  top of the screen. Session-less recordings still exist — an import deliberately
  lands outside every session, and pre-sessions installs have leftovers — so they
  are a "Not in a session" section at the bottom of the one list, present only
  when there is something in it. The WAV importer moved to the Sessions toolbar
  with them.
- **What was lost, deliberately:** the recording detail page's stretched
  whole-file thumbnail. The player draws the same spectrogram, zoomable, behind
  the sheet that replaced the page.

### Simplified view (2026-08-16)

The last of the three items deferred at the acceptance review. The detector
carries a lot of instrumentation and most of it is only legible to someone who
already reads calls, so **simplified view is the default** and the full set is
one switch away.

- **What it hides.** The row of five measurement cells in the stats card
  (Fpeak, Bndwth, Dur, Rate, Pulses); the pulse panel's species-ID and settings
  buttons; and the spectrogram header's species-ID, compress-timeline, bat-range
  and palette buttons. **What stays:** the status pills along the top of the
  stats card, the level meter, and the spectrogram's frequency-band settings
  button — that last one deliberately, because which frequencies are shown is
  the one thing on that screen a beginner may genuinely need to change. So the
  simplified stats card is the pill row and the meter, nothing else.
- **It also disables drag-to-scroll on the live spectrogram** (Niall,
  2026-08-16). Scrolling back into the history buffer is a review gesture, and in
  simplified view it is only ever reached by accident: a finger resting on the
  spectrogram silently freezes the live feed, and the way out is a "Return to
  live" button that exists *because* you are already lost. A third mechanism
  beyond the two below, and deliberately the simplest one — the gesture is
  removed rather than overridden or defaulted, because there is no control to
  hide and no state to be stranded in. Passed as `SpectrogramView.scrollEnabled`
  and attached as `nil` rather than a disabled gesture: an attached-but-disabled
  `DragGesture` still claims the touch sequence and would swallow taps meant for
  the pills sitting over the spectrogram.
- **Two mechanisms, and the rule that picks between them.** Some of what the
  mode changes is a permanent override while it is on, some a default applied
  once on the way in. **The test is whether the control that would change it
  back is still visible.** The species-ID toggles are overridden (their buttons
  are hidden, so honouring the stored value could strand a user in a view with
  no exit); the 15–90 kHz band is applied once (its settings button IS still
  shown, so an override would fight the user every time they adjusted it).
  Getting this backwards either strands the user or makes a visible control
  inert. See `SimplifiedView.swift`, which is where both live.
- **Nothing is written over.** The override reads the stored value only in
  advanced mode, so a user's own choices survive being in simplified view and
  come back on switching. This is the answer to the question Niall flagged when
  deferring the feature — what happens to someone who has already changed an
  advanced value.
- **`simplifiedDefaultsApplied` is load-bearing.** Without it the band is either
  never applied (a fresh install that leaves onboarding's switch untouched fires
  no `onChange`) or re-applied on every launch, reverting the user's own tweak
  from the one settings button the mode still shows. It is cleared on the way
  out so a later return re-applies.
- **Existing installs get simplified too**, on Niall's call — one rule for
  everyone rather than grandfathering. They open to the reduced layout with the
  switch in Settings to get the rest back.
- **The session button reports a live session on its glyph, not only its
  colour.** On the pre-26 bar we draw the circle, so its tint is ours outright:
  red idle, orange running. On iOS 26 the circle is the system's, and a tab bar
  colours its own items — selected in the tint, everything else in a secondary
  grey — while this button is a `Tab(role: .search)` that is never selected. The
  tint is therefore *attempted* (`.symbolRenderingMode(.palette)` plus a
  `foregroundStyle`, which is the override's best chance) but the state is
  carried by the symbol swapping from an outline `record.circle` to a filled
  `waveform.circle.fill`. Shape is the half the system cannot overrule, and not
  resting state on colour alone is the accessible way round regardless.
- **The tour shortens with it.** ~~`TourScript.steps(simplified:)` drops the six
  steps whose controls the mode hides and rewords the stats, pulse-pane and
  reset steps for what is actually on screen.~~ **Not enough — filtering the
  advanced script still left sixteen steps (2026-08-17).** Every pill in the
  stats header, both listening modes and the deaf-window trade-off survived the
  filter, because none of those controls is hidden in simplified view; they are
  just not what someone who has never heard a bat needs first. The two scripts
  are now separate lists (`simplifiedSteps` / `advancedSteps`), and the short one
  is seven steps: the three panes, a pointer at each tab, and the session button.
  The `advancedOnly` flag is gone with the filter — a step's mode is now decided
  by which list it is in, so there is nothing left that can disagree.

### The tour's own affordance (2026-08-17)

The tour no longer opens itself after onboarding. It is offered instead by a
sparkles button in the Detector's nav bar, left of the gear, which opens a
popover explaining what the tour is before anything takes over the screen.

- **The button retires itself, asymmetrically** —
  `OnboardingState.shouldOfferTour(simplified:)`. Finishing the *advanced* tour
  hides it for good in both modes, because that tour is a superset and there is
  nothing left to show. Finishing the *simplified* one only hides it in
  simplified view: switching to advanced brings it back, offering the longer tour
  for the controls that just appeared. Niall's rule, and the reason one flag
  would not do.
- **Only a finished tour counts.** `TourOverlay.finish` carries a `completed`
  flag — true from the last step, false from "End tour" — so dismissing the tour
  early leaves the button where it is. Taking the affordance away because someone
  dismissed it is how a user ends up stranded from something they meant to
  return to.
- Info & Tour keeps the tour reachable forever, which is what makes retiring the
  button safe, and what the popover says.

### The tour nudges itself, once (2026-08-17)

The button was not enough on its own: one small glyph in a nav bar, and a
first-time user has no reason to suspect a tour is behind it. The popover now
**opens itself 15 s after the first arrival at the detector**
(`ContentView.nudgeTourAfterDelay`), which is when the screen has stopped being new
and started being confusing.

- **Once per install, ever** (`OnboardingState.hasNudgedTour`), and the flag is set
  when the popover is *shown*, not when the tour is taken — the nudge has done its
  job either way, and a nudge that returns is nagging. The button stays for anyone
  who dismissed it and changed their mind.
- **It waits for a clear moment rather than firing blind.** The Detector must be the
  visible section (the anchor lives in that nav bar), no sheet or menu may be up (a
  popover presented into a dismissing presentation is dropped silently), and the
  tour itself must not be running. A first-run user is quite likely to be inside a
  sheet or on another tab at exactly 15 s, so it re-checks every 2 s for two minutes
  and then gives up.
- Deliberately *not* blocked by a running session. A nav-bar popover pauses nothing
  and dismisses on any tap, and someone who has just pressed Start and is watching a
  screen they don't yet read is precisely who the tour is for.

### One card for a suggested model (2026-08-17)

There were two screens making the same offer in two visual languages: the compact
`SuggestedModelSheet` after onboarding, and `LocationChangeSummaryView` — a
`NavigationStack` + `Form` with a nav bar, a "Use" row and per-species sections —
after a move. **The `Form` one was also the one appearing on a clean install**, which
is how it was found. Niall's call: scrap it, use the card.

- **The clean-install appearance was a real bug, not just the wrong style.** The
  first fix on a fresh install derives priors for the first time, and every species
  the presence grid reports as absent counts as a change away from the factory
  default of `enabled, 1.0`. So a first fix raised a "location changed" summary
  listing dozens of species, plus a model suggestion the post-onboarding card was
  already making. `refreshPriors` now raises no summary at all on the first
  derivation: nothing *changed*, it was derived.
- **The card takes an optional model**, because a move can shift the species list
  without changing which model covers the area. With no model there is nothing to
  activate, so it reads as a notice with one button.
- **The species lists are gone, replaced by a count.** A card is the wrong place to
  reproduce a list of forty species, and the authoritative list is AutoID settings
  itself. What survives is the part that mattered — the user is told the list moved
  under them rather than finding out later.

### What's New, and letting a release re-run onboarding (2026-08-17)

`Resources/CHANGELOG.md` is bundled and parsed at runtime (`ChangeLog.swift`).
The newest `##` block becomes the What's New sheet, shown once per build; the
whole file is the change log screen behind it. Modelled on the same arrangement
in Niall's Birding_Data app, in OpenBat's own visual idiom rather than that
app's grouped `List`.

- **A release can re-run onboarding** by putting an HTML comment containing
  `openbat: reonboard` inside its `##` block. Honoured only *inside* a release
  block, which is what lets the file's own header comment document the directive
  without arming it — worth keeping if that header is ever rewritten.
- **Two separate stamps, and they are not interchangeable.** `lastSeenBuild`
  moves when What's New is dismissed; `reonboardedBuild` moves the moment
  re-onboarding is *triggered*. Stamping re-onboarding on completion instead
  puts anyone who quits mid-flow back through it on every launch.
- **A fresh install never sees What's New** — the first launch stamps the build
  and shows nothing. A changelog is a poor first screen.
- **`@Observable` read inside a `Binding` getter does not drive presentation.**
  The sheet was first written as `.sheet(isPresented: Binding(get: {
  ReleaseState.shared.shouldShowWhatsNew }, ...))` and never appeared: that read
  happens outside `body`'s observation scope, so no dependency is registered.
  ContentView copies the flag into plain `@State` in `.onAppear` instead.
- **Three sheets wanted the same moment on the first launch after an update**,
  and the loser is dropped silently — the location-change summary won and What's
  New vanished. Both it and the post-onboarding model suggestion are now gated on
  `showWhatsNew`, joining the `!tourActive` gate that was already there for the
  same reason. Anything else added to that screen needs to join the queue.

### Species search: results dropdown, not a screen swap (2026-08-17)

**The keyboard closed the instant you typed the first character**, and the whole
screen was replaced by a long unfiltered list. The explorer's `body` was a
`Group` with `if query.isEmpty`: empty drew the globe with the search pill
floating on it, non-empty drew a *different* stacked layout with a full-screen
`List`. That structural swap rebuilt the `TextField` in the other branch, so it
lost focus — nothing to do with the search itself.

- **One hierarchy now.** The globe and the pill stay in the same place in the
  tree whatever the query is, and matches hang below the pill in a glass card.
  The field is never rebuilt, so the keyboard stays up and the list narrows as
  you type.
- **The dropdown is a `ScrollView`/`LazyVStack`, not a `List`.** A `List` fills
  the height offered to it, so as a dropdown it draws a full-height slab with
  three rows at the top — and it carries its own background, which is why the
  old full-screen version needed a black strip behind the pill at all.
- **Its height is measured, not inferred.** `ScrollView` takes all the height
  offered rather than sizing to content; the `.fixedSize(vertical:)` trick for
  coaxing an ideal height out of one is unreliable. `onGeometryChange` measures
  the rows and the frame is `min(measured, 360)`.
- The globe's tap-to-dismiss-keyboard gesture no longer fights row taps: the
  results are in an overlay above it, so they are hit-tested first. The old
  warning about `simultaneousGesture` eating `NavigationLink` taps applied to
  the arrangement that is now gone.

### Distribution maps are square (2026-08-17)

Tall ranges were still being clipped top and bottom. The card grew its height as
needed but capped it at 340pt, and **the cap was the bug** — no cap short of
square can fit the tallest ranges.

**Square is provably sufficient, not just bigger.** Fitting a rect into a view
matches their aspect ratios, so a range that is tall relative to the view demands
more longitude than the world has; MapKit clamps the zoom and crops latitude
instead, and no amount of padding helps. But in Mercator map points the world is
*square*: every range's height is at most `MKMapRect.world.height`, which equals
`world.width`. At aspect 1 the longitude a range needs is exactly its height, so
it is never more than one world-width — for any range that can exist. Hence
`.aspectRatio(1, contentMode: .fit)` and no height maths at all.

`mapHeight` now sizes only the "no data" placeholder. `mapSize` survives purely
as a re-frame guard; there is no longer a size → height → size loop to converge.

### Distribution maps are drawn as outlines, not cells (2026-08-17)

Every version that drew the presence cells themselves showed seams inside the
range — first one polygon per cell, then merged into horizontal runs, and the
runs still striped at every row boundary. **The cause is anti-aliasing, not
strokes** (removing the stroke didn't fix it): MapKit anti-aliases each
polygon's edge independently, so a shared edge lands as two half-covered pixels
instead of one full one, and half-covered translucent fill is lighter than
full. Inflating each run by 6% of a cell so neighbours overlapped traded that
for the opposite artefact — two translucent fills stacked read *darker* — which
is what Niall saw as bars. No inflation fixes both; abutting is too light and
overlapping too dark.

So the interior edges are never drawn. The occupied region's boundary is traced
instead — keep a cell edge only where the cell across it is absent, chain the
survivors into closed rings — giving one polygon per connected area with holes
as `interiorPolygons`. Winding each cell anticlockwise makes outer rings come
out positive-area and holes negative, so a ring's sign classifies it and
containment is only needed to pair a hole with the smallest ring around it.
Fewer polygons than the run merging it replaced, and no internal edges at all.

### Species collections: cards or list, one remembered choice (2026-08-19)

Every "here is a set of species, browse it" page in the guide — a region, bats
near you from the globe, and the Detector's own nearby sheet — is now one view,
`SpeciesCollectionView`, with two layouts behind a toolbar toggle. **Cards are
the default**; the choice is stored under `guide.speciesLayout` and is global
rather than per-page, since the same toggle in the same corner meaning different
things on two identical-looking pages is worse than one setting that moves them
together.

- **Both layouts group by family**, so the toggle only changes how a species is
  drawn — never which ones appear or in what order. The card grid uses
  `LazyVGrid` sections with the family name as the header.
- **Three pages collapsed into one view.** `RegionSpeciesView` and the
  short-lived `NearbySpeciesGrid` are gone. The Detector sheet
  (`NearbySpeciesSheet`) is now just a `NavigationStack` wrapper that supplies
  the resolved species set and its own empty-state wording, so the guide's
  nearby page and the Detector's cannot drift apart — which they already had
  once, one being a family-grouped text list and the other a flat photo grid.
- **The toggle is hidden on an empty collection**, where it would offer a
  choice that changes nothing on screen.
- The button shows the icon for the layout you will *get*, not the one you are
  looking at: the page already tells you which layout is showing.

### The species page could be dragged sideways (2026-08-17)

A vertical `ScrollView` is backed by a `UIScrollView` whose `contentSize` is the
measured content in **both** axes, so one over-wide child makes the whole page
pan horizontally even though only `.vertical` was requested. Declaring the axis
is not enough — the content has to actually fit.

Fixed with `.containerRelativeFrame(.horizontal)` on the scroll content rather
than by finding the guilty child: the page assembles ~10 optional cards from
community-maintained JSON, so a long unbroken citation URL or a wide photo is one
bad entry away at any time. `cardHeroPhoto` documents a previous instance of
exactly this failure (a `scaledToFill` photo reporting ~500pt wide, which
`.clipped()` does not fix because it clips drawing, not layout). Over-wide
content is now clipped rather than scrollable.

### A URL interpolated into a `Text` markdown link is not a link (2026-08-17)

Both field-guide empty states offered "get started here" / "contribute range
data here" pointing at the guide repo, written as
`Text("… [get started here](\(fieldGuideRepoURL)).")`. Neither was tappable —
the `[label](…)` rendered as literal characters, brackets and all.

A string literal handed to `Text` is a `LocalizedStringKey`, and its
interpolations become substitution placeholders in a format string. Markdown is
parsed from that format string **before** the values are substituted back, so
the parser sees a link destination that is a placeholder rather than a URL and
never forms a link. The constant was fine; the interpolation was the bug.

Fixed by parsing an `AttributedString` from the markdown instead
(`markdownText` in `SpeciesExplorerView.swift`), where the URL is already in
the string before markdown is applied. Anything else that wants a link with a
non-literal destination needs the same treatment — a hardcoded destination in
the literal works, an interpolated one silently does not.

### Settings became cards, with a fixed shape (2026-08-18)

The three tabs had grown by absorption — five tabs folded into three over two
days — and every fold kept its sections' original headers and footers. The
result read as a heap: headers naming the subsystem a setting came from
("Playback thumbnails", "Activity bout", "Frequency gate"), and footers
explaining the implementation rather than the effect. "Normalised peak magnitude
(0–1)" and "above-threshold columns required before a pulse is accepted" are
accurate and useless to the person holding the phone.

Every card now follows one shape, enforced by two small views in `SettingsView`
(`CardHeader`, `ControlNote`) so a card added later can't quietly reintroduce the
old one: a short name in ordinary words, one line under it saying what the card
is for, then each control as label-and-value, its one-sentence note, and the
control itself. The note sits **above** the slider on purpose — read downwards you
get the name, what it does, then the thing you drag, so the explanation arrives
before you touch anything rather than after.

The register is **plain, not simple**, a distinction worth holding because the
first pass overshot into explaining-to-a-child and had to be pulled back. The
reader is an adult using an ultrasonic bat detector, so ordinary technical words
are fine: frequency, kHz, calibration, confidence. What is not fine is our own
vocabulary leaking out — no unit the reader hasn't met (columns, magnitude,
normalised), no internal noun (threshold, gate, floor, roll) unless the control
genuinely is that idea, and describe what changes on screen or in the recording
rather than in the maths. "Min duration: 3 columns" became "Shortest call: 2.0
ms", computed from the live sample rate — same control, a unit a person can
picture. Trigger modes are "Loudness" and "Loudness + pitch", not the "Loud" and
"Loud and high" the first pass tried.

Cards are still `Form`/`Section`. The native grouped inset styling already draws
a card, and hand-rolling one would trade Dynamic Type, keyboard avoidance and the
system's Liquid Glass for a rounded rectangle we would then own forever.

Three structural changes came with it. The Audio tab is **Detecting** — it holds
the mic, the taps, what counts as a call and what gets recorded, and only one of
those is about sound; it is ordered as the signal travels. **Map pins moved to
AutoID**, from a "Location" header that named where the setting came from rather
than what it decides. And two knobs were **removed rather than reworded**: the
playback-thumbnail noise floor (the WAV player has had its own live slider for it
for a while, so Settings was the second and worse copy) and the CF tail fraction,
a research parameter with no lay meaning and no calibration to tune it against.
Neither had a sentence that could be written honestly for a general user. The CF
tail is now a constant read rather than an `@AppStorage` — with no control left,
a value some earlier build stored would otherwise go on shifting every Fc
measurement with nothing on screen to reveal or reset it.

**What simplified view hides here, and why only one card.** The first instinct
was to gate every trigger card, which is wrong by `SimplifiedView`'s own
precedent: the band button stays visible in simplified view because it genuinely
needs tweaking in the field. Loudness and lowest pitch are the first things to
reach for when nothing is triggering, and recording length is plain English, so
all three stay. Only "Telling calls apart" (minimum duration, gap bridging,
hold-off) is advanced-only — those need a spectrogram in front of you to set.
Note this is a *third* mechanism alongside that file's override/apply-once pair,
and it is the one the iPad exception already implies: hide the control, and let
another route reach the state. The route is the Advanced switch at the top of the
same sheet. Overriding would be actively wrong here, because these values decide
what gets detected at all — substituting different ones in simplified mode would
change what the app hears without saying so.

`TriggerMode` gained a `label` separate from its `rawValue` ("Loud" / "Loud and
high" against "Amplitude only" / "Frequency + Amplitude"). The raw value is the
persisted key and appears in settings dumps; renaming it would silently reset
every existing install to the default. The live tuning overlay keeps the jargon
deliberately — different audience, and it is a developer tool.

---

### Mic calibration follows the recording, not the route (2026-08-18)

The per-bin microphone correction (`MicCalibrationCurve`) is display-and-analysis
only, and deliberately so: recorded PCM, classifier input and uploads all read
raw samples and never see it, so it cannot change what is saved, identified or
contributed. That part was right. How playback *found* a curve was not.

`MicCalibrationSettings.activeCurve` returned the curve for whatever mic was
plugged in at the moment you looked. Reviewing a recording is something you do
indoors with nothing attached, so the current input was the built-in mic, no
curve was stored for it, and the whole playback path — overview, detail tiles,
and the FmaxE that `CallAnalysis` measures — silently corrected nothing. The
same lookup would have applied a second mic's curve to the first mic's
recordings had anyone owned two.

The fix needed no new metadata, because the recorder already writes the
capturing mic's name into GUANO `Make` (`AudioRecorder.makeGuanoChunk`), and
curves are already stored per mic name. `WavPlayerView.load()` now reads that
one field off the file and resolves the curve from it once per recording, before
the overview render that bakes it into the grid. Consequences worth stating:
calibrating a mic later applies retroactively to everything it ever recorded;
a WAV imported from someone else's detector gets no correction at all, which is
correct, since a curve measured on the Griff describes the Griff.

Still uncorrected on purpose: the whole-file JPEG behind Sessions row thumbnails
(`RecordingSpectrogramRenderer`). It is rendered once at save time and cached, so
a correction baked into it could never be revised when the curve changed — the
same "don't bake calibration into a stored artifact" rule the WAV itself follows.
At 56 × 40 there is nothing in it a resonance band would misrepresent.

---

### Spotlighting anything the tab bar draws

`.tourTarget` does not work inside a `Tab` label: on iOS 26 the bar renders the
label outside the view tree the anchor preference travels through, so the anchor
never arrives and the step silently degrades to a centred card. The tab and
session-button steps take their rects from `SessionButtonLocator` instead —
the same UIKit search that already places the recording glow — and ContentView
merges them over the anchor-derived ones in `tabBarTargets(in:)`.

On a physical device none of the accessibility matching below ever runs — there
is no accessibility text on any view to match (see §7's `SessionButtonLocator`
entry), so the tabs are found by their position among the bar's item cells
instead. The rules below still govern the accessibility path, which is what runs
under VoiceOver and in UI tests.

- **Exclude `UILabel` and `UIImageView` when matching by accessibility label.**
  A `UILabel` derives its accessibility label from its own text, so the title
  inside the Sessions tab answers to "Sessions" exactly as the tab does; the
  smallest-match rule then drew the spotlight ring around the word and left the
  icon above it in the dark. Verified in the simulator before and after.
- The search is scoped to the `UITabBar` subtree where one exists. "Sessions"
  and "Species" are ordinary words that appear elsewhere on the Detector.
- **Settings folded from five tabs to three** (General / AutoID / Audio) in the
  same change. Location, Storage and Privacy were a tab each and none filled
  one; five segments were also too wide for a phone, which is why "Recordings"
  had already been shortened to "Storage" to stop it truncating.

### Playing a recording fixes the zoom (2026-09-01)

Niall: "currently not happy with this part of the app." The player's spectrogram
was smooth to pan and blurry to play, and every attempt to fix the playing half
was a fresh guess at a moving target.

**The false belief was that playback should scroll whatever zoom you happened to
leave behind.** It could be the whole file or a single call, so every mechanism
keeping a sharp picture under a moving playhead had to work at an unknown scale:
the pyramid level changed underfoot, a tile's span in real seconds changed with
it, and the race between "how long a render takes" and "how much runway is left"
had to be solved from live measurements taken on the device, because nothing
about the situation was known in advance (see the measured-threshold machinery in
`WavSpectrogramView.scheduleDetailRenderThrottled` — all of it was there to cope
with not knowing).

Playing now clamps the time axis to a fixed window of **listening**, default
1.5 s, adjustable from the player's tuning panel. That is one number and exactly
two zoom levels, because heterodyne plays at the file's own rate (1.5 s of
recording) and time expansion is N times slower (1.5/N seconds of recording,
which is the zoom you want there anyway). Pausing hands the zoom straight back —
analyse mode pans and zooms exactly as before, at whatever the playthrough left
you at.

What that buys, and the reason the clamp is worth having at all: a play-through
now sits at ONE pyramid level for its whole duration, so the tiles under it are a
bounded set that is rendered once and then only read — including on a replay, a
scrub back, or a second pass at the same speed. Playback therefore always takes
the tile pyramid, regardless of the A/B toggle (which still selects the path for
analyse mode — removed the same day, once there was nothing left for it to
select between), and a background prefill keeps a few spans' worth of tiles ahead
of and behind the playhead at `.utility`, below the render the view itself is
asking for.

Two smaller things fell out of it. The frequency axis is deliberately NOT
clamped — playback owns the time axis and nothing else, so a pinch still adjusts
the band while playing and simply has no effect on time. And with two fillers
now working the same grid, a caller asking for a tile another thread is already
rendering has to WAIT for it rather than be handed nil: dropping it from the
batch left `assemble` finding a hole, and the view fell back to the coarse
overview crop until the next throttle tick.

**The lead margin was a precondition, not an optimisation** (2026-09-01, same
day). Niall, on time expansion: "it only loads them right as it is about to need
it, which means we see low res." He was right, and the cause was not the fill
rate. `assemble` is all-or-nothing over whatever range it is handed, and the
display handed it the visible frame PLUS three screens of runway — so nothing
sharp appeared until the last of that runway had rendered, while the tiles
directly under the frame sat cached and unused. In time expansion, where a tile
is 0.17 s of recording (hop is 32 here, not the live view's 256) and the runway
is several tiles, that was most of the time.

Three things were wrong together and all three are fixed:
- **Display and fill are now separate questions.** The picture is assembled
  against the visible frame only (`assembleCovering`), and carries as margin
  whatever contiguous tiles happen to be cached beyond it — growing on its own
  as the fill lands, never waiting on it.
- **The fill ran in tile-index order**, so a window reaching behind the playhead
  as well as ahead rendered all of the history first: the thing needed next was
  built last. It now runs forward from the playhead's own tile
  (`missingTilesFromPlayhead`).
- **The pyramid was behind the per-render path's runway throttle**, which by
  design holds off until the buffer is nearly spent — sensible when a render is
  expensive and speculative, exactly wrong for a cache lookup. Playback ticks
  now refresh the pyramid directly.

The one thing to be careful of if this is touched again: joining tiles is memcpy
but it is megabytes of it, so the rebuild is gated on the showing picture having
actually stopped being good enough (no longer covers the frame, or less than a
tile of forward margin left). Re-joining on every tick, or on every tile that
lands, costs more than the coarse crop ever did.

**Both renderers stay, for now.** Hide-silence is the one thing still on the old
path, and — the correction that settled this — it PLAYS THROUGH: the pacing
thread walks the compressed timeline, so that path is still doing the full
moving-playhead job and cannot be stripped back to a static render. Losing it
means either teaching the pyramid the compressed timeline (a stitched assemble,
gathering cached tiles into a picture linear in virtual samples and aligned to
its own fixed grid so it still caches) or making hide-silence look-only. Niall's
call on 2026-09-01 was to leave both and see how the new playback zoom feels in
the field first.

The minimap's red/green buffer overlay moved behind `debugModeEnabled` in the
same change. It was the instrument for the A/B — it is how the playhead was
caught overrunning the buffered region — and it was being drawn for every user.

### The blur was a cliff, not a shortage of runway (2026-09-02)

Niall, on a screen recording at 16×: "we're still not buffering the next slice
till right at the end giving a sudden blurry view." The debug overlay showed the
green ready-region ending exactly at the playhead with red still rendering ahead
of it — so the fill *was* being asked for in advance, and the picture still
collapsed the moment the playhead crossed into it.

**The false belief was that a spectrogram either has its tiles or it doesn't.**
The player had a pyramid but only ever displayed one level of it: if any tile
under the visible frame was missing, the whole join failed and the view fell all
the way back to cropping the 4096-column whole-file overview. On a five-second
recording at 16× that is about 77 real columns stretched across the screen —
roughly a 25× collapse in detail, arriving in one frame. What looks like "it
buffers too late" is really "the only two states are sharp and hopeless."

There is now a ladder. A frame whose own level isn't ready comes back at the
finest *coarser* level that is, up to two steps out, and the fill renders that
coarse level **first** — one coarse tile covers four sharp ones at the same cost,
so a single render buys the whole window a floor. Falling behind now softens the
picture instead of destroying it, and the display keeps trying to climb back as
sharp tiles land. Two other things were making the tiles late:

- **A priority inversion between two fillers.** The view filled tiles at
  `.userInitiated`; a second, near-identical filler ran from the player screen at
  `.utility`. The tile store serialises per key on an `NSCondition`, which donates
  no priority — so whenever the background filler won the race for a tile, the
  foreground one *blocked behind a background-priority render of the very tile
  the playhead was about to reach.* The `.utility` filler is gone; it was doing
  duplicate work even when it wasn't inverting.
- **The picture only ever grew at the last moment.** A re-join was triggered only
  once the forward margin fell below one tile, so tiles that landed before then
  sat in the cache unused until the next cliff. It now also re-joins when there
  is a newly-cached tile ahead to gain by it.

Three things found in the same read and fixed alongside, all of the same shape as
the §13 isolation rule:

- The transport row claimed in its own doc comment not to read
  `currentTimeSeconds`, and then did — its replay-vs-play test compared the
  position against the duration, so the whole row re-evaluated 30 times a second
  while playing. The engine publishes a `didFinish` flag now.
- The minimap's playhead `TimelineView` had no `paused:` argument, so it drove a
  30 Hz redraw for the entire life of the screen whether or not anything was
  playing. `WavPlayheadOverlay` had been fixed for exactly this; this one was
  missed.
- A progress callback already handed to the main queue could land *after* a seek
  and put the old position back, snapping the playhead backwards. Each pacing run
  is stamped now and stale callbacks are discarded.

The player's unreachable iPhone-landscape layout went too — the app has been
portrait-only on iPhone since 2026-08-16 and iPad reports a regular vertical size
class in every orientation, so the branch selecting it could never be taken.

**Still open, and deliberately not touched here:** dragging the minimap calls
`engine.seek` on every gesture frame, and each seek stops and restarts the pacing
thread — a synchronous bounded wait on the main thread, a new `Thread`, a new
file handle, and a flushed output ring, sixty times a second. Throttling it is a
real UX trade (continuous audio under the finger versus silence until release),
so it is Niall's call, not a bug fix. Likewise the log-frequency warp, which
re-copies the whole displayed bitmap twice per frame during playback and only
costs anything for people who turn that toggle on.

---

## 8. Detection tuning

- **`holdOffSeconds` 150 ms → 50 ms.** Field data (`Bat_Walk_27_06_2026`) shows a
  median inter-pulse gap of ~79 ms, so the old default silently dropped more
  than half of a normal pass's calls, starving both the pulse-rate readout and
  the classifier. 50 ms passes typical spacing while still rejecting the closest
  echoes; amplitude does the rest, since echoes return much quieter.
  Field tuning on 2026-08-17 took it further still, to **30 ms**.
- **The shipped defaults were re-based on a field tuning session (2026-08-17).**
  A night's tuning was dumped with the Debug sheet's "Dump Settings to File" and
  the deltas folded into the code defaults, so a fresh install now starts where
  that session finished rather than at the original engineering estimates. What
  moved: the detector's amplitude threshold 0.5 → 0.3 and hold-off 50 → 30 ms;
  the live spectrogram's noise floor 0.35 → 0.40 (the pulse crop stayed at 0.35
  — the reverse of what that setting's own comment predicted); the display band
  0–192 kHz → roughly 3.8–86 kHz and the time window 0.5 → 0.75 s; the playback
  noise floor 0.25 → 0.30, and again to 0.40 on 2026-08-18 once the Settings
  duplicate was gone and the player's own live slider was the only one; and
  slow replay from 8× over a 1.5 s buffer to
  **16× over 0.5 s**, which slows each call twice as far while cutting the deaf
  window after a trigger from 12 s to 8 s, with hiss reduction 18 → 10 dB.
  Everything else in the dump was already at its default: all eleven haptics
  tunables, both heterodyne settings, and every AutoID pass/quality-gate
  threshold. The per-species enable flags and priors were deliberately NOT
  adopted — those are a function of where the phone is, and the app derives them
  from location.
  Two things to keep in mind when reading this list: a default only reaches an
  install that has never written the key, so none of it changes an existing
  device; and simplified view — the default mode — applies its own 15–90 kHz
  band once on entry, so the new band defaults are what ADVANCED view starts at.
- **The amplitude half of that session was measured through an inert slider, and
  has been rolled back (2026-09-01).** In `.ultrasonic` mode — the default — the
  detector tests level *and* peak frequency, and the frequency it was handed came
  from `SpectrogramProcessor.frequency(forBin:level:)`, which returns 0 Hz below
  `peakThreshold`. That constant is 0.5 and nothing has ever set it, so any
  column between 0.3 and 0.5 reported no pitch, failed the 15 kHz test, and was
  dropped. The threshold actually in force was 0.5 for the whole tuning session
  and the slider did nothing beneath it, so 0.3 records a preference nobody ever
  heard. Splitting out a level-free `frequency(forBin:)` removed the hidden gate
  and made 0.3 real for the first time — which is a 14 dB sensitivity increase on
  the fixed −90…−20 dB trigger scale, and it showed up immediately in the field
  as clothing rustle and footfall on stone triggering the detector. The pitch
  gate cannot help here: both are broadband and carry well past 15 kHz, so
  amplitude is the only thing that ever rejected them. The default is back to
  **0.5**, with a one-time `pulse.amplitudeGateRepaired` stamp that raises a
  saved sub-0.5 value on first launch — a stamp rather than a clamp, so a 0.3
  chosen deliberately *now* survives. The rest of the 2026-08-17 dump stands:
  nothing else in it was routed through the frequency gate.
- **0.5 is the measured knee, not a restored guess** (Squamish session
  `2026-09-01 21:06`, 35 recordings, 47 passes, 39 of them NoID). Re-running each
  recording's 15–90 kHz peak onto the trigger's own 0–1 scale puts every pass the
  classifier could name at 0.52 and above, and the great bulk of the junk below
  it. Sweeping the threshold over that night: 0.30 keeps 30 of 35 recordings,
  0.40 keeps 20, **0.50 keeps 14 and still keeps 4 of 4 named-species passes**,
  and 0.55 is where a real *Lasiurus cinereus* pass (peak 0.52) starts being cut.
  So 0.5 is the highest setting that loses no confirmed bat on this corpus — the
  knee, with the next step up already costing a real pass. Note what the junk was
  *not*: its energy sits genuinely above 15 kHz, at −63 to −78 dB, against −29 to
  −57 dB for the real calls. Rustle and footfall are not rejected here by being
  low-pitched. They are rejected by being quiet, which is why amplitude is the
  only gate that was ever doing the work.
- **The pitch half of the default trigger is a tautology in simplified view.**
  `applyBand` feeds the display band straight into `SpectrogramProcessor`'s
  `peakMinFraction`, so the peak search starts at the bottom of what is on
  screen. Simplified view — the default — sets that to 15 kHz
  (`SimplifiedView.bandLowHz`), which is exactly `minFrequencyHz`. The reported
  peak frequency therefore *cannot* come back below the gate, and
  `peakFrequency >= minFrequencyHz` is true for every column ever fed. The
  Squamish pulses show the fingerprint directly: the single most common peak
  frequency in the session is 15000.0 Hz on the nose — bin 80, the first bin the
  search is allowed to look at — where energy below the band piles up.
  So "Loudness + pitch" has been plain "Loudness" for every default install,
  and the setting's own help text ("15–20 kHz rejects wind and handling noise")
  describes something that cannot happen. Advanced view escapes it only by
  accident: the 2026-08-17 band starts at ~3.8 kHz, leaving the gate real room.
  This is the same shape of defect as the hidden `peakThreshold` above — one
  number quietly serving two consumers with opposite needs. Here the display
  band is a *viewing* preference and the detector's search floor is a *detection*
  parameter, and they must not be the same variable: as it stands, scrolling the
  spectrogram changes what the detector is able to reject.
  Left unfixed deliberately (2026-09-01). Widening the detector's search floor
  below the gate is not free — a call arriving over low-frequency rumble would
  have its peak bin land on the rumble and be rejected, trading tonight's false
  positives for false negatives on exactly the nights that matter. The honest
  fix is a concentration test (in-band peak versus sub-gate peak) rather than a
  wider search, and that wants measuring before it is built.
  The general lesson is that two independent-looking thresholds on the same
  scale, one of them a private constant, compose into a gate neither name
  describes — and a tuning session cannot see it, because the slider it is
  moving still displays the value it is not applying.
- **A one-pulse pass is discarded, not filed as NoID** (2026-09-01). Bats call in
  trains, so a lone trigger with silence either side is a knock, a footfall or a
  fabric snap — and it is unnameable anyway, there being nothing to aggregate
  over. In the Squamish session twenty of the thirty-nine NoID passes were
  single-pulse, while every pass the classifier could name carried two or more
  (2, 4, 4, 4, 8, 10, 30), so the rule drops half the clutter and none of the
  identifications. `PulseDetector.minRecordedPassPulseCount` (2).
  Three things about it that are easy to get wrong:
  **It is not `AutoIDSettings.minPassPulseCount`,** which looks like the same
  idea and isn't: that one gates whether a pass gets NAMED, so falling below it
  produces a NoID record — still written, still in the list. Raising that stepper
  would have removed none of those twenty entries. This gate decides whether the
  pass is written at all.
  **It has to be applied twice.** `AudioRecorder` aggregates over its own segment
  span, independently of the detector's pass, so dropping the pass from the
  history alone leaves the WAV on disk — the half the user actually sees. Hence
  `AudioRecorder.rejectsSegment`, sharing the detector's constant rather than
  copying it.
  **Zero classified pulses is KEPT.** In the recorder, `noID(pulseCount: 0)`
  means nothing was classified during the segment — no model active, or
  classification not keeping up — which is exactly what a feeding buzz does.
  Only an explicit count of 1 is evidence of a lone trigger. Simplifying the
  guard to `pulseCount < min` would silently delete real recordings on the
  busiest passes of the night, and nothing on screen would say so.
  The counters are deliberately untouched: `registerDetection()` runs on the
  detection path, so pulse count and rate still report that something fired. The
  detector did trigger; it just has nothing worth filing.
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
- **Priors start neutral**, and are then derived from a bundled presence grid —
  see below. They were suggested from live GBIF record counts until 2026-08-16.
- **BattyBirdNET was considered and rejected for licensing, not accuracy.** Its
  weights carry a share-alike term, which would have required releasing any
  model derived from it — the CoreML conversion included — under the same
  licence, obliging OpenBat to let others redistribute it freely. BatDetect2's
  CC BY-NC 4.0 is the opposite shape: non-commercial use only, but no
  obligation to share the derived model back. That fits a source-available,
  all-rights-reserved app; share-alike would not have. See `LICENSE` for what
  CC BY-NC actually requires of OpenBat (attribution, and staying
  non-commercial) — that constraint is why the app currently has no IAP or
  subscription of any kind.

### The quality gate is hidden for a model that ignores it (2026-08-18)

`BatDetect2Classifier.classify` takes a quality gate and documents that it
ignores it — it has no equivalent of NABat's per-window SNR/amplitude metrics.
The settings screen offered the toggle and both sliders anyway, so with
BatDetect2 active they were controls that did nothing. Now a descriptor declares
whether its model honours the gate and the section is hidden when it doesn't.

The stored setting is deliberately left untouched rather than forced off: it
lives in that model's own settings record, and switching to a model that does
honour the gate has to find it as the user left it. That's the "hidden control
must be overridden, not written" half of the simplified-view rule.

### Species ID is refused off the native capture rate (2026-08-18)

Found in the 2026-08-18 audit. The classifier protocol had no sample-rate
parameter, so the one object that knows the true capture rate — the pulse
detector — had no way to pass it on, and both models simply assumed 384 kHz:
BatDetect2 resamples `from: 384_000`, and NABat's spectrogram renderer takes its
384 kHz default because the single call site passes no rate. Meanwhile the
detector sizes the classification window from the *real* rate. So the two ends
disagreed: the detector handed over 50 ms of audio measured in real samples, and
the classifier read it as 50 ms of 384 kHz audio. At 48 kHz that is a frequency
axis wrong by 8×, and there was no guard and no warning — the app returned a
confident species name computed from a mis-scaled spectrogram.

**The detector now declines to classify when the delivered rate isn't the
model's native one** (`ModelInputSpec.nativeSampleRate`, 0.1% tolerance since a
delivered rate isn't guaranteed integral). Everything else about the pulse
proceeds normally — detection, the pulse image, the recording, the pass — only
the species name is withheld, and the pass closes as NoID.

Two things this deliberately is *not*:

- **Not a resample.** Threading the real rate into the models is mechanical, but
  it produces approximate results from pipelines validated at one rate — and for
  NABat the window length is itself derived from the rate (`nFFT = 0.001 ×
  384000`), so it isn't a one-line change either. A wrong species in the
  Sessions log is worse than none: it is indistinguishable from a right one
  after the fact, and it is eligible for upload to the community dataset.
- **Not user-facing.** Niall's call, and the reasoning is that the failure window
  is narrow rather than that it doesn't matter. The pulse detector already
  ignores anything under 15 kHz, and an iPhone's built-in mic at 48 kHz has a
  24 kHz Nyquist — so the band that could trigger at all is a sliver, and mostly
  noise. Off-rate classification was a real correctness hole but a rarely-reached
  one, and it isn't worth a message explaining a hardware requirement to someone
  who hasn't hit it.

Note that `ClassifierSpectrogramEngine`'s `for bin in loBin...hiBin` is a
`ClosedRange` that traps if `loBin > hiBin`. It stays unreachable *because* of
this decision — a real low rate would invert it. Anyone who later revisits this
and threads a rate through instead must guard that range in the same change.

### Species priors: from live record counts to a bundled range grid (2026-08-16)

Prompted by an acceptance review. The old path asked GBIF, at each new location,
how many occurrence records each species had within 100 km. **Three independent
faults, all shipping:**

1. **Record counts measure recording effort, not bats.** Museum specimens, old
   taxonomy and university field courses all count.
2. **Failure was indistinguishable from certainty.** ~50 requests fired at once;
   roughly half were throttled. A failed lookup left the species untouched, and
   untouched meant the factory default `enabled, prior 1.0`. Verified in San
   Francisco: the gray bat (Tennessee/Alabama caves), evening bat and
   southeastern myotis all sat at maximum weight with **zero** nearby records,
   alongside Yuma myotis with 515. Fifteen of the UK model's seventeen species
   sat at 1.0 in California.
3. **Name-based queries were wrong in both directions.** Measured, not inferred:
   `Lasiurus blossevillii` returns **0** records near San Francisco while
   `Lasiurus frantzii` — where western red bat records now sit — returns **90**,
   so a resident was switched off. And `Cnephaeus serotinus`, the newer
   combination the UK model uses, matches **only the genus** in GBIF, returning
   0 everywhere: the serotine was switched off near London, where
   `Eptesicus serotinus` has 1,684 records.

**Now:** `SpeciesPresenceData.json`, generated offline from the classifiers' own
species lists (not the guide's — the guide covers 19 species, the models name
47), bundled in the app and refreshable from the field guide repo. Taxonomy is
resolved once at generation time against an explicit alias table, and a match
that resolves to a genus is a hard error rather than a warning — that check is
what catches the serotine.

**Three states, not two.** `present` / `absent` / `unknown`, where unknown means
no range data exists for that species. Unknown stays enabled at half weight and
carries `resolved: false` so the settings screen says so. Conflating unknown
with certain was fault 2; conflating it with absent would silence a bat purely
because nobody has mapped it.

**Things learned building it, all of which cost time:**

- **GBIF's `/occurrence/search` does not guarantee ordering**, so paging the
  "first N" records is a biased sample, not a subset. The density tile endpoint
  aggregates every record server-side instead: ~50 requests total rather than
  ~700, about a minute rather than an hour, and no sampling question.
- **The density endpoint accepts `month=` and silently ignores it.** January and
  July return byte-identical tiles. Per-cell seasonality is therefore not
  available this way; the month masks ship as zero, meaning "no information".
- **Raw occurrence data needs outlier filtering.** Unfiltered, the gray bat
  claims a cell in Alaska on one record out of 283. The floor is absolute, not
  proportional: 0.5% of the common pipistrelle's 3.2 million records is 16,000,
  which would erase most of its real European range.
- **The refresh distance dropped from 100 km to 10 km.** The old figure existed
  to throttle network calls; a local lookup has no such cost, and 100 km was far
  too coarse to catch crossing a range boundary.

### The range grid should lean generous (2026-08-27)

Niall's framing, and it settles a whole class of threshold argument. The grid
serves two jobs, and **both prefer a range slightly too big to one slightly too
small**:

1. **It sets species priors.** Someone is most likely to be out recording
   somewhere nobody has recorded before — that is what a new detector is *for*.
   A range that stops at the edge of existing survey coverage suppresses the
   prior exactly where the user is standing, and the cost is a missed detection
   of a bat that was really there.
2. **It is a guide.** "We probably get this one here" is the useful thing for a
   reader to be able to say. A boundary drawn tight enough to exclude the
   plausible edge cannot support that sentence.

So where a threshold is genuinely uncertain it goes to the generous side, and an
over-inclusive edge is a known cost rather than a bug to be tuned out. The
counterweight is `unknown`: a species we know too little about is still held at
half weight rather than handed a confident range, so generosity applies to the
EDGES of a range we believe in, not to inventing one.

### Rejected 2026-08-27: judging observation clusters before buffering

The rebuilt chain leaves one wrong answer — the southeastern myotis reaching
Miami, off two single-record cells over Florida Bay. The obvious fix is to judge
raw observation clusters *first*, by whether they chain to neighbours, and buffer
only the survivors. It was built and measured, and it is a bad trade.

Linking observation cells at one cell's distance and requiring three per cluster
does remove Miami — and pulls **28 of 48 species' northern edges back**, Northern
Myotis from 62 N to 49 N, for a 22% overall shrink. Widening the link to 2 or 3
cells keeps the north but stops removing Miami, at every cluster size tested.

Why no setting does both: **the cells are the same object.** Miami's strays are
isolated single-record cells at a range margin, and so are the seven that carry
Northern Myotis into boreal Canada — same counts, same isolation, same position.
Geometry cannot separate a stray from a real under-surveyed edge, so no hop
distance, cluster size or record floor will.

⚠️ **The verification suite could not see this.** Its northernmost case is London
at 51.5 N, so the hop rule scored a clean 20/20 while truncating half the species
list. That gap is still open — the suite needs boreal cases before it can be
trusted on anything touching a northern edge.

What *would* work is geography rather than geometry: a land mask. The Miami
stray's buffer expands across open water; boreal Canada is solid ground. Not
built — it is a coastline raster in the generator for the sake of one cell.

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

### 2026-08-09: the reinstall case — a placeholder is not a file

Reported symptom, on a cloud-backed library after a delete/reinstall: Playback
shows no spectrogram thumbnails at all, and tapping a recording hangs for a
long time with no explanation. Two separate causes, both from code treating an
iCloud placeholder as if it were an ordinary local file.

**Thumbnails gave up permanently.** `ClassificationStore.load(file:)` already
checked `CloudStorage.isDownloaded` and reported `awaitingDownload` so
`RecordingThumbnailLoader` could retry — but that check can't see the case that
actually happens first. `recordings.json`/`passes.json` are tiny and sync back
almost immediately; iCloud hasn't enumerated `Classifications/images/` yet, so
the JPEG **doesn't exist at any path**. `resourceValues` throws for a missing
file, `isDownloaded` reads that (correctly, for its own purpose) as "not
ubiquitous, nothing to wait for", the decode then failed, and the row got
`.unavailable` — a terminal answer. Every row asked once, was told the
thumbnail didn't exist, and never asked again. Fixed with
`CloudStorage.mayArriveLater`, which distinguishes "gone" from "not here yet"
by asking whether the library is cloud-backed at all; a failed decode on a
cloud-backed library now returns `awaitingDownload` and the existing
backing-off retry does its job.

**Tapping a recording blocked on a whole-file download.** Nothing waited for
the WAV. `PlaybackEngine.load` reads the 44-byte header, and on a placeholder
`FileHandle`/`AVAudioFile` does not fail — it blocks while iCloud materialises
the entire multi-megabyte 384 kHz file. That call is on the main actor, so the
UI froze outright; `renderOverview`'s whole-file scan then paid the same cost
again. `WavPlayerView.load` now calls `CloudStorage.awaitDownload` first and
shows a "Downloading from iCloud…" state with progress, cancelled on
`onDisappear` so a five-minute wait doesn't outlive the screen.

The general rule this leaves: **before opening a library file for reading,
either confirm its bytes are local or be prepared to block for the length of a
network transfer.** `ensureDownloaded` alone does not give you that — it only
requests, it doesn't wait.

`downloadFraction` spells `NSURLUbiquitousItemPercentDownloadedKey` by raw
value on purpose: the typed `URLResourceKey` is unavailable in the iOS Swift
overlay (it redirects you to `NSMetadataQuery`, which is far too much machinery
for a progress number on one known file). It returns nil rather than 0 when
iCloud reports no figure, and the UI shows indeterminate progress for nil — a
transfer stuck at "0%" reads as broken.

### The bulk deletes are two, on purpose (2026-08-17)

Settings ▸ Storage offers exactly **Delete NoID Recordings** and **Delete All
Sessions**, in that order. Niall's call; there were three before.

- **"Delete Low-Confidence Recordings" is gone.** It destroyed everything under
  a 57% threshold that was hardcoded, invisible and unrelated to the 75% upload
  bar it sat next to. A number that decides what gets destroyed cannot be one
  the user can neither see nor change, and the fix is not to expose it — junk
  pruning is what NoID already does, and anything finer is a per-recording
  judgement, where the swipe already is.
- **"Delete All Recordings" became "Delete All Sessions".** The old one left
  sessions and the pass log standing, so a user who wanted their history gone
  cleared the WAVs and still saw every outing listed. Nothing in Settings could
  clear session history at all.
- **What "all sessions" does not include:** the "Not in a session" bucket —
  imported WAVs and anything recorded before every outing became a session. A
  bulk delete named for sessions must not take things that were never in one.
  Those rows swipe-delete in Sessions, and the footer says so.
- `deleteAllSessions()` loops `deleteSession` rather than clearing the arrays
  itself. That is the method that also removes pulse images and WAVs from disk;
  a wholesale clear is exactly the orphaning hazard §15's `clearAll()` entry
  warns about.

Both still sit below the fold, least destructive first, and "Delete All
Sessions" keeps the type-DELETE gate (`DeleteAllSessionsConfirmationView`).

### Imported files are converted, not just copied (2026-08-18)

Found in the 2026-08-18 audit. Four readers — the WAV player's PCM reader, the
STFT grid, the playback engine and the header parser — each seek straight to
byte 44 and read 16-bit mono samples. That is true of every file `AudioRecorder`
writes and of essentially nothing else. The importer meanwhile byte-copied
whatever the user picked and renamed it `.wav`, validating only that the system
audio API could open it — which succeeds for stereo files, 24-bit and float PCM,
extensible `fmt ` chunks, AIFF, m4a, and any WAV carrying a `LIST`/`INFO` chunk
before `data`, which Audacity, Wildlife Acoustics and Pettersson all commonly
write.

The result was a noise spectrogram that played as static, with **no error** —
and precisely for the files the importer exists for: a reference recording,
something from another detector, a call library download. It never showed up in
normal use because the app's own recordings are always canonical.

**Imports are now converted into that canonical shape on the way in** rather
than the four readers being taught to parse a chunk table: one place changes
instead of four, no stored geometry has to be back-filled onto existing
recordings, and anything unconvertible fails loudly at import instead of
silently downstream. Because conversion is real, the picker's AIFF and generic
`.audio` types are now honest rather than traps.

Three details that are load-bearing:

- **A file already in canonical shape is left byte-for-byte alone.** That is what
  preserves the trailing `guan` chunk when someone re-imports an OpenBat export,
  which the importer reads to round-trip species, confidence, pulse count, date
  and position. Rewriting the samples would silently cost that.
- **Conversion runs on the background task, not during the copy.** The copy must
  stay inside the `.fileImporter` completion handler because the sandbox
  extension is scoped to it; conversion reads a URL in our own container and is
  slow on a long file, so it sits with `renderOverview`. A file that fails to
  convert is deleted rather than left in the library to render as noise.
- **Stereo is downmixed by averaging, and floats are clipped before scaling.**
  Dropping a channel would throw away half a two-mic recording, and `vDSP_vfix16`
  wraps rather than saturates, so an out-of-range float sample would have become
  full-scale noise of the opposite sign.

`WavHeader` now walks the chunk table properly and clamps a declared `data`
length to what the file actually holds, so a truncated recording can't send a
reader off the end. `GuanoMetadata` was a fifth site assuming byte 44 — the
audit missed it — and now asks for the real data offset; it degraded safely
before (it simply failed to find the chunk), but it was the same latent bug.

---

## 11. Privacy, consent and upload

**What location is used for, in full** — the list every privacy document has to
match, and which has been wrong in both directions before: choosing which
classifier model suits the region, deciding which species are plausible nearby
(against the bundled presence grid, not a network call), stamping a coordinate on
each detection, naming a session after the place it happened, and computing local
sunset/sunrise for the detector's sun clock (§7). All on-device, all from
occasional one-shot fixes. Nothing sends a coordinate anywhere except a
deliberately-tapped contribution, which fuzzes it.

### GPS tracking removed, every run is a session (2026-08-16)

**No continuous location, and never "Always" authorization.** A "New Session"
used to record a GPS course: continuous updates, breadcrumbs every ~5 m / ~3 s,
escalating to Always so it kept recording with the phone locked, backed by the
`location` UIBackgroundMode. All of it is gone — provider, stored track, map
polyline, background mode, and the Info.plist entry.

**Why removed rather than made optional.** Niall's call, and the right one: every
detection already carries a coordinate and a timestamp, so a track can be
reconstructed from the exported points by any GIS tool. The track was a second,
much denser recording of the user's movements that duplicated data the app
already had, and cost battery and an Always-authorization prompt to collect.

**The start-up choice went with it.** "New Session" vs "Just Listening" was
presented as a filing decision, but the only thing it actually decided was
whether to record that track — a privacy and battery question, asked before the
user had heard a single bat. Worse, its own explanation was wrong ("Just
listening still tracks location but doesn't group the data" — listening never
tracked), and the "Just Listening" branch wrote passes with a nil `sessionID`
that **no screen in the app ever displayed**. The 2026-08-15 review ran the
detector twenty minutes, logged 1,450 pulses, opened Sessions and read "No
sessions yet". Every run is a session now; Start just starts.

**Two consequences that needed handling.** Old listening passes are adopted into
one session per night on first load (`adoptOrphanedListeningPasses`) — grouped
by night, not by calendar day, so an outing crossing midnight stays one session.
And since a stop/start now costs a whole row, a session restarted within 15
minutes resumes the previous one rather than creating another: a session is an
outing, not a tap.

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
- **Being on another tab counts as "not drawing" (2026-08-16).** The bottom tab
  bar made leaving the detector a second way for the render loop to stop, and
  one the old scene-phase test did not catch: the app is still foreground and
  active, so nothing handed the columns over, and a run kept capturing audio
  while quietly detecting nothing for as long as the user was reading Sessions.
  The condition is now "foreground **and** on the detector" — see
  `ContentView.updateColumnDrainOwner`, which is the single place that decides,
  and is called from the scene-phase change, the section change and
  `audio.isRunning` alike. The spectrogram's own `isPaused` takes the same
  condition, so the loop stops drawing at the moment the pump takes over.
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

### 2026-08-15 audit: the rest

- **Async work that outlives a reset needs a generation token, not just cleared
  state.** `PulseDetector.resetStats` cleared the accumulators but left
  `isCapturing`/`pendingCapture`/`pendingClassifications` and the pending
  absolute sample indices alone. A CoreML classification is slow enough (cold
  model load on a busy device) that a stop→start lands the previous run's pulse
  in the NEW session's `passAggPulses`, carrying the new session's ID and
  coordinate. `captureGeneration` is now snapshotted in `scheduleCapture` and
  checked in both completions — including around the `pendingClassifications`
  decrement, since a stale decrement against a zeroed counter drives it negative
  and the `== 0` pass-finalize gate then never opens again.
- **`startDetecting` was missing the `finalizePass()` its siblings had.**
  `stopDetecting` and `endDemo` both finalize before tearing down; `startDetecting`
  called `resetStats()` alone, so a pass orphaned by an audio interruption — the
  exact case its own next comment handles for sessions — was discarded instead of
  recorded as NoID, against §9. Three call sites, one of them different, and the
  odd one out was the one nobody had a reason to look at.
- **The tuning overlay's revert snapshot missed eight knobs.** All five Slow
  Replay sliders, the output routing picker, the trigger-mode picker and the
  palette picker. The replay sliders also commit to `UserDefaults`, so Revert
  appeared to work while having permanently changed persisted settings. The flat
  struct was chosen precisely so this couldn't happen and it happened anyway —
  the convention isn't enforced by anything. `LiveTuningSnapshot`'s header now
  carries the two greps that check it, and notes that **pickers are what slipped
  through**: a sweep looking only for sliders misses them.
- **Hide-silence translated the viewport's centre but not its span.** Real and
  virtual samples aren't 1:1, so `recentered` reusing `viewport.sampleSpan`
  across the domain switch reinterpreted the zoom level; the compressed timeline
  being shorter meant turning hide-silence on threw the user's zoom away. The
  span is now re-derived by mapping BOTH edges. General form: when translating
  between the two domains, translate every quantity that has units of samples,
  not just positions.
- **`?? array[0]` after `max(by:)` is a crash, not a fallback** — `max(by:)`
  returns nil exactly when the array is empty. Two sites had it. `?? .first`.

### A `repeatForever` animation needs BOTH containments, not one

This has now been diagnosed three times on three different views, so it is
written down as a rule rather than a comment.

An autoreversing `repeatForever` animation leaks in two independent ways, and
fixing one leaves the other:

1. **Through the transaction.** Started with `withAnimation`, it is installed on
   the whole current update, and any unrelated view that happens to change in
   the same cycle inherits it. An inherited `repeatForever(autoreverses:)` has
   nothing to end it, so whatever caught it oscillates for the rest of the run.
   *Fix:* flip the flag with no animation and attach the animation to the glyph
   itself with `.animation(_:value:)`.
2. **Through geometry, on the view it was correctly scoped to.** A scoped
   `.animation(_:value:)` carrying a repeat stays ACTIVE forever once started —
   it does not only animate the `value:` it was keyed to. Every later change to
   that view's resolved position is picked up by the repeat too, so a neighbour
   relaying out (a timer label changing width once a second is enough) makes the
   new position one end of a never-ending interpolation. *Fix:* `.geometryGroup()`
   on the same leaf, so it takes its position from the parent's unanimated
   transaction as a rigid unit.
3. **Through colour, by the same mechanism.** `.geometryGroup()` contains
   position and nothing else, so a still-live repeat goes on to capture the next
   `foregroundStyle` change on that leaf. This is what made the mic pill's
   connector icon cycle red↔green forever once the Griff was plugged in
   (2026-08-17): the breathe starts at `onAppear` with no mic attached, and the
   later red→green flip became one end of an autoreversing interpolation. It
   only reproduces if the state changes *after* the view appears — connect the
   mic before launch and the colour never changes, so nothing leaks, which is
   most of why it survived several passes over this file. *Fix:* an innermost
   `.animation(nil, value:)` keyed on the state that drives the colour, placed
   BELOW the `.opacity` (above it, it cancels the pulse itself). It wins over
   the outer repeat for changes driven by that value, so the state change lands
   instantly and the repeat is left with opacity, which is all it was ever for.

All three are needed. Fixing only (1) produced the mic pill's rate label sliding
out of its capsule, and later the record button zipping diagonally out of the
transport row and back — same bug, found six days apart, because the record
button had been given the transaction fix alone. Fixing (1) and (2) left the
colour leak above.

The general shape: a live `repeatForever` claims **every** animatable property
of its leaf, not the one it was keyed to. Containing them one property at a time
as each symptom shows up is why this has been diagnosed three times. When adding
a repeat, ask what else on that leaf can change — position, colour, scale, blur
— and contain all of it up front.

The app has exactly two `repeatForever` animations (`MicStatusPillContent`'s two
pill elements, and the record glyph's breathe). A third was tried on
`RecordingStatusBadge` and deleted rather than contained. Keep it that way:
adding one is adding a permanent source of this bug.

### The capture ring accepted nothing when empty (2026-08-18)

**The most serious bug this project has had, and it shipped.** Found within
minutes of writing the recorder's first-ever test.

`AudioRecorder.append` runs on the realtime audio thread and copies into an SPSC
ring, keeping one slot empty so "full" and "empty" stay distinguishable. It
computed the writable space as `((r - w + cap) % cap) - 1`. That is correct for
every state but one: with the ring **empty** (`w == r`) it evaluates to
`(cap % cap) - 1`, i.e. **−1**, so nothing was copied.

Empty is the steady state. `drainCapture` always takes everything available, so
the ring returns to `w == r` after every drain — including at startup, before the
first buffer. The ring therefore accepted no audio, ever. Recording produced
44-byte header-only WAVs: a file appears, `isWriting` goes true, no error is
reported anywhere, and there is not one sample in it.

Introduced by the 2026-08-18 audit's E2 — replacing a per-sample copy loop with
two block copies. The loop it replaced tested fullness per sample and so never
had this state; the rewrite derived the bound from the wrong end. It was reviewed,
reasoned about in a comment that described the intent correctly, and built clean.

Now `let used = (w - r + cap) % cap; let writable = cap - 1 - used`.

**The lesson is about coverage, not arithmetic.** This code path had no test.
Nothing else in the app notices — the spectrogram has its own PCM ring and kept
working, so the app looked completely healthy while recording silently produced
empty files. The first `AudioRecorder` test ever written caught it immediately,
which is the argument for the rest of `AudioRecorderPreRollTests` existing.

### Operation count is not the thing that matters here (2026-08-18)

Closing out the 2026-08-18 audit's efficiency findings produced one result worth
keeping, because it contradicts the obvious intuition and the audit itself.

**The resampler's "6× too much arithmetic" finding did not survive measurement.**
`PolyphaseResampler` zero-stuffs, convolves everything, then throws away two
thirds of the result — five sixths of its multiply-adds are against zeros the
zero-stuffing just inserted. A true polyphase decomposition (compute only the
kept outputs, using only the non-zero taps) was written and benchmarked against
it on the real workload, a 0.256 s window at 384→256 kHz:

| implementation | time per call |
|---|---|
| existing (zero-stuff → `vDSP_conv` → decimate) | 0.40 ms |
| polyphase, per-output `vDSP_dotpr` | 0.62 ms |
| polyphase, inlined scalar dot product | 1.59 ms |
| existing + cached reversed filter + single padded buffer | **0.37 ms** |

Both polyphase variants matched to 5e-7, so the maths was right — one long
`vDSP_conv` simply beats 65 536 short dot products, overheads and all. The
version kept is the last row: bit-identical output (difference exactly 0.0), two
fewer allocations, ~8% faster. **Don't rewrite this as a polyphase without
re-measuring.** The file carries the same warning.

The same audit's other allocation finding went the opposite way and is worth
contrasting. `PulseImageRenderer` reused a static pixel buffer to avoid a ~2 MB
allocation per pulse — but reuse meant the finished pixels had to be *copied*
into a `Data` for `CGDataProvider`, so it traded an allocation for a memcpy of
the same size. Allocating per pulse and handing the buffer to the provider
outright (with a `releaseData` callback) removes the copy. Pixels are also packed
as `UInt32` words now rather than four byte stores.

The general lesson, since this project keeps meeting it: on the capture queue,
**measure before restructuring**. Accelerate's vectorised kernels and the memory
traffic around them dominate; the arithmetic count on its own predicted the wrong
answer twice here.

---

## 14. Target and build wiring

### Project layout

```
OpenBat/
  Audio/            capture, recording, WAV/GUANO, storage, playback
  DSP/              Biquad, STFTGrid, resampler, calibration curve, log warp
  Haptics/          pulse haptics (accessibility channel)
  Heterodyne/       live heterodyne downmixer
  TimeExpansion/    playback-only classic expansion, plus D240x snippet mode
  Spectrogram/      audio-thread FFT, Metal renderer, history, calibration UI
  Classifier/       pulse detection, models, pass aggregation, persistence
  FieldGuide/       species reference, GBIF range maps, guide store
  WavPlayer/        offline review: static spectrogram, call analysis
  Consent/          consent record, device identity, sync
  Upload/           anonymisation boundary, conversion, FLAC, upload
  Location/         GPS track for sessions
  LiveActivity/     lock-screen card (app side)
  Tuning/           live tuning overlay
  Onboarding/       first-run flow
  AppTabBar.swift   the bottom bar, the session button and its transport menu
  SimplifiedView.swift  what simplified view hides, and the defaults it applies
  GlassStyle.swift  Liquid Glass helpers with pre-26 fallbacks
  ContentView.swift the detector screen; wires every subsystem together
OpenBatWidget/      widget extension target
```

**Supported orientations are set per-idiom**, not globally:
`INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` is portrait alone, while
the `_iPad` key keeps all four. Setting the plain, idiom-less key instead — which
is what the project had before 2026-08-16 — silently re-enables iPhone landscape,
for which no layout exists any more. See §7.

`OpenBat/OpenBat/` is a `PBXFileSystemSynchronizedRootGroup`: **any .swift file
placed inside it is compiled into the app.** That is why the VTD quarantine is a
sibling directory and not a subfolder, and it is the thing to remember before
moving a file "back where it belongs".

### Key constants

| Symbol | Value | Notes |
|--------|-------|-------|
| `windowLen` | 512 | Hann-windowed, raw samples per column |
| `fftSize` | 2048 | zero-padded from `windowLen` — drives bin count, not hop |
| `hopSize` | 256 | 50% overlap (of `windowLen`) |
| `binCount` | 1024 | `fftSize / 2` |
| `columnsPerSecond` | 1500 | at 384 kHz: `384000 / 256` (hop drives this) |
| `maxVisibleColumns` | 2048 | seek texture width |
| `ringTextureWidth` | 2560 | `maxVisibleColumns + 512` guard |
| `liveHistory` capacity | 90 000 | 60 s × 1500 cols |
| `minDB` / `maxDB` | −90 / −20 dB | display dynamic range |
| Metal max texture dim | 16 384 | limits single-texture history |

### Wiring

Easy to get silently wrong:

- **The widget target is `OpenBatWidgetExtension`, folder `OpenBatWidget/`.**
  Renamed 2026-08-17 — it was `OpenBatWigetExtension`/`OpenBatWiget/` (missing
  the `d`) from when the target was created until then. The bundle identifier
  (`Niall.OpenBat.OpenBatWiget`) was deliberately **not** renamed to match, to
  avoid invalidating the existing provisioning profile — so the identifier
  still carries the old typo even though the folder, target name, product
  name, and entitlements filename don't. Don't "fix" that mismatch without
  also rolling a new provisioning profile.
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

A sequential, area-by-area adversarial review across 7 areas. The standalone
review document has been removed now every finding is either fixed or listed
below; this section is the record. Most findings were marked "fix as per
suggestion"; the ones with substantive direction are noted.

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
| 3.1 Species range store pointed at the wrong repo | **Fixed 2026-08-15.** `SpeciesRangeStore.remoteURL` now points at `NiallxD/OpenBat-FieldGuide`, matching `SpeciesGuideStore` and the field guide README's promise to contributors. It had pointed at `NiallxD/OpenBat`, so range edits made in the field guide repo were a silent no-op. Both files were byte-identical at the time of the change, so no behaviour changed. `tools/generate_species_range_data.py` writes guide and range JSON side by side in one directory, which is what settles the field guide repo as the canonical home for both. |
| 5.5 Failed writes still counted in the WAV's declared length | **Was still unfixed; fixed 2026-08-15.** The table above records this as fixed and it was not — `write()` used `try?` and advanced `dataBytes` regardless of the result. See §6. |
| 5.2 Silent GPS failure with no user-facing signal | `LocationProvider.locationManager(_:didFailWithError:)` is still an empty body. |
| 3.2 Wikipedia photo carousel | The concurrency half (cache lock) is done. The "load several images and let the user swipe" half doesn't appear to exist — `fetchPhoto` still resolves a single `Photo`. |

---

## 16. Open questions

- **The presence verification suite has no boreal cases, and that hid a real
  regression (2026-08-27).** Its northernmost check is London at 51.5 N, so a
  candidate filter chain that pulled 28 species' northern edges back — Northern
  Myotis from 62 N to 49 N — still scored 20/20. Anything touching a northern
  edge cannot be trusted against this suite until it has cases up there. The
  ones worth adding, once Niall has confirmed the ranges: Northern Myotis around
  Yellowknife, Little Brown around Whitehorse, and spotted bat present in the
  Okanagan but absent at Prince Rupert — that last pair is what would have
  caught the bug that started the rebuild. See §9.

- **A land mask would fix the range grid's coastal over-reach, and nothing else
  will.** The one accepted wrong answer in the grid — southeastern myotis
  reaching Miami — comes of a buffer expanding across Florida Bay. Geometry
  cannot separate that from a genuine under-surveyed edge (§9), but geography
  can: the stray's buffer grows over open water and boreal Canada is solid
  ground. Costs a coastline raster in the generator. Not worth it for one cell
  alone; worth revisiting if loose coastal edges turn up elsewhere.

- **The session button is no longer a tab on iPad — 2026-08-30, and it settles
  the entry below.** `Tab(role: .search)` is drawn as a detached circle beside
  the bar on iPhone, which is the whole reason the button was ever a tab. On
  iPad the same tab is drawn as the last item *inside* the centred pill, where
  nothing distinguishes it from a fourth destination; App Review tapped it
  expecting a screen and refused the build. So on iPad the tab is not declared
  and the button is drawn by us, beside the pill.

  Three things that made this cheap, and are worth knowing before touching it:

  - **Place it against the pill, never against the bar's view.** The floating
    bar's own view is the full width of the window — measured 820×44 on an
    11-inch in portrait — while the glass it draws is 350 of that, centred.
    `barContentFrameInWindow` is the glass; `barFrameInWindow` is not.
  - **The bar passes touches through outside its pill**, which is what makes an
    overlay in that row workable at all. The Settings gear has always lived
    inside the bar view's bounds and has always been tappable. (The tap catcher
    below failed for the opposite reason: it sat *over* the bar's own item.)
  - **A glyph inside `glassEffect` is glass content and gets repainted.** Drawn
    the obvious way — glass applied to the image — the play triangle came out
    black on device while staying white in every simulator. Baking the colour
    into a `UIImage` does not save it. Draw the glyph as an overlay *over* the
    glass. The baked bitmap is gone with it: it only ever existed because a
    `Tab` label ignores SwiftUI styling, and this is no longer a `Tab` label.

  The tap catcher is deleted, and the indicator blink is gone with the tab.

- **The tab bar's indicator blinks when you tap the session button, and the
  fix for it does not work — left alone on Niall's call, 2026-08-17.
  RESOLVED 2026-08-30 by the entry above; kept for the reasoning.** The
  button is a `Tab`, so the bar moves its indicator there, the selection is
  refused, and it animates back. The invisible tap catcher written to stop the
  touch reaching the bar **cannot** do so: SwiftUI draws that overlay into the
  hosting view's layer rather than as a `UIView`, and a device hierarchy dump
  shows the hosting view's only subviews are the locator's probe, the TabView's
  host and a dimming view — so UIKit hit-tests past it to the bar's item cell
  every time. Nothing about the catcher's position or size changes that. It went
  unnoticed for a day because it could not be tested: taps prove nothing in a
  simulator, and on hardware the catcher was not being drawn at all (see §7).

  Left as-is because the blink is cosmetic — the menu opens, the tab never
  changes. The real fix is to stop the session button being a `Tab` and draw it
  ourselves, as the pre-26 bar already does: no selection to refuse, no
  indicator to move, no catcher. That trades away the system's glass rendering
  and morph on that circle, and the button being a real tab for VoiceOver and
  keyboard focus, which is why it wasn't taken. Note it would **not** remove the
  view-hierarchy search entirely: on iPad our own button would still need the
  bar's frame to sit beside that centred pill. It would make the failure mode
  benign, though — a visible button parked slightly wrong, rather than an
  invisible disc over a control.

  One symptom to watch: the catcher's tap gesture still fires alongside the
  bar's own handling, so if the transport menu ever starts flicking open and
  shut on a single tap, that is two toggles racing and deleting the catcher is
  the fix.
- **The App Review rejection of 2026-08-29, and what it actually was.** Apple
  refused 0.9.3 (111) under 2.1(a) with one line — "unable to review the 'Play
  button' tab", on an iPad Air 11-inch on iPadOS 26.6.1. It was not the tab bar,
  the tap catcher or anything iPad-specific. **With microphone access refused,
  the session button gave up after one attempt.** The alert was raised by
  watching `audio.status` for a *change* containing "permission denied", and a
  refused start always writes the same string — so the first tap explained
  itself and every tap after it did nothing whatsoever. Reproduced end to end on
  a simulator: fresh install → "Don't Allow" at onboarding's microphone prompt →
  tap, alert, cancel, tap, nothing, forever.

  Two things made it read as worse than a missing alert. Every dead tap still
  opened a Session row, armed the recorder ("● Recording" in the corner),
  started the session timer and fired a Live Activity, because `startDetecting`
  did all its bookkeeping before `audio.start()` found out capture could not
  run — so the screen claimed a session was live while the button still said
  "start". And a start that failed for any reason *other* than permission
  ("Failed to start: …") raised no alert at all, ever; it appeared only in
  Diagnostics.

  Fixed 2026-08-30: `AudioEngineController.StartFailure` carries an attempt
  number, so the second refusal differs from the first and the alert is a value
  to react to rather than a string to diff; session bookkeeping moved behind
  `guard audio.isRunning`. **The general rule worth keeping: never surface a
  repeatable failure by watching a status string change.** The second identical
  failure is silence.

- **The structural session-button search only ever knew the iPad's bar, and a
  simulator could not show that — fixed 2026-08-30.** There are two bar shapes
  on 26, not one. iPad gets a `_UIFloatingTabBar` with the session button as a
  *pinned item*; iPhone gets a plain `UITabBar` that looks identical and shares
  none of its class names, with the button as a `_UITabButton` inside a
  `_UITabBarAuxiliaryView`. Only the iPad shape was implemented, so on every
  real iPhone the search found nothing and the glow, the transport menu and the
  tour's tab spotlights were all silently absent.

  It survived because the accessibility match runs first and a simulator always
  answers it (see §7). `-locator.structuralOnly YES` now forces the device path
  in a simulator, which is the only way this class of bug is visible before
  hardware. **Turn it on whenever anything near that search changes.**

  The same run found the pre-26 bar had never been covered at all: it is
  hand-built SwiftUI, so there is no `UIView` carrying our identifier or label
  and no `UITabBar` either, and the search could never have found it on any
  system. On iOS 18–25 the transport menu therefore never opened — no way to arm
  recording, change listening mode or end a session from the button. That bar
  now reports its own geometry (`SessionButtonLocator.updateSelfDrawn`), which
  is exact rather than searched.

- **Where the bar is, is measured now, not inferred from the idiom.** The
  transport menu, the export banner and the not-recording nudge each have to
  grow away from the bar, and they asked `userInterfaceIdiom == .pad`. That is
  right for a full-screen iPad and wrong for the same iPad in Split View, Slide
  Over or a small window, where the width is compact and the bar drops to the
  bottom — the menu would have opened off the bottom of the screen. It now comes
  from the button's measured frame (`buttonIsInTopHalf`). Verified indirectly
  only: the same path is proven with the bar at the top (iPad) and at the bottom
  (iPhone), but Split View itself was not reachable through simulator
  automation. **Worth one check on a real iPad in Split View.**

- **IUCN Red List range polygons — ruled out on licensing, 2026-08-16.** Worth
  recording so nobody researches it twice. Their expert-drawn mammal maps carry
  exactly the attributes this app wants — `presence`, `origin` (including
  *vagrant*, which would settle the eastern red bat near San Francisco) and
  `seasonal` (which would answer the migration question outright). But the
  Red List Terms of Use prohibit redistribution "in their original format,
  either whole or in part, alone or combined with other data, **including
  within Derivative Works**", without prior written permission. Rasterising
  their polygons into a shipped presence grid is squarely that. Niall's call
  was to steer clear. Two routes remain if it ever matters enough: request a
  formal waiver from IUCN (free non-commercial conservation use is a
  sympathetic case), or use the data locally as a *check* on our GBIF-derived
  grid without shipping anything derived from it — the line being that finding
  our errors with it is fine, encoding their boundaries is not.
- **Migration timeline in the species guide — built and scrapped, 2026-08-16.**
  Niall's idea earlier the same day: show each species' seasonal movement as a
  timeline on its guide page — when it migrates, when it hibernates, when you
  can expect to hear it. It was built (a twelve-month bar, phases as explicit
  month spans so sedentary and tropical species could say so, all 19 bundled
  species populated) and then removed the same day, unshipped. **Niall's reason,
  which is the part to keep:** for most species it is not reliably known *when*
  they move, or *where* they go, and a bar drawn month by month asserts a
  precision the underlying knowledge doesn't have. Prose can say "largely
  sedentary, with some short-distance movement between summer and winter
  roosts" and be exactly as vague as the evidence is; a coloured band starting
  in March cannot. So migration stays where it was — alluded to in the
  `habits.migration` text, and nowhere else.

  Worth knowing before anyone revisits it: seasonality here was never blocked on
  the GBIF `month=` dead end (§9). That parameter is silently ignored, so
  per-cell month masks ship as zeroes, but a guide timeline needs per-species
  editorial content rather than per-cell data. The blocker was the content
  itself, not the data pipeline. Occurrence months *are* available per record
  from `/occurrence/search` if a data-driven version is ever wanted, and that —
  showing observed records by month, with their own sample size visible —
  would answer the objection above in a way a hand-written timeline can't.
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

### Orphaned by the presence-grid change — resolved 2026-08-16

The species map and the classifier both moved to the bundled presence grid,
which left the entire "ask GBIF at runtime" design with no consumer. **All
deleted**, on Niall's call:

- **`GBIFService.swift`** (321 lines) — taxon-key lookup, occurrence-point
  fetching, `suggestPriors` and its helpers. Its last consumer was
  `SpeciesRangeStore`, which was orphaned too: the two referenced only each
  other. **The app now makes no GBIF network request at any point**, which is
  why the privacy pages no longer say an approximate position is sent there.
- **`SpeciesRangeStore.swift`** (149 lines), its `SpeciesRangeData.json`, and
  `tools/generate_species_range_data.py` (154 lines) — the occurrence-point
  pipeline behind the old zoomable species map.
- **The SwiftyH3 package** — H3 hexagon binning went with that map. Removed
  from the project file, along with its licence row in `AppInfoView` and the
  Apache-2.0 notice text that only that row used.

Roughly 620 lines of Swift, a Python generator, and one third-party dependency.

If a fine-grained species map is ever wanted, note that the presence grid is
deliberately coarse (~100 km cells) and occurrence points are what would come
back — as a fresh fetch, not as this code.

### Orphaned code — resolved 2026-08-15

Raised by the 2026-08-08 documentation pass, decided during the 2026-08-15
cleanup:

- **`WavPlayer/TickerWheelControl.swift`** — **deleted.** Zoom and pan in the
  WAV player are gesture-driven; nothing referenced the type.
- **`ClassificationStore.clearAll()`** — **deleted.** `deleteAllRecordings()`
  and `clearListening()` cover the two flows the UI actually offers; nothing
  wiped both. (`deleteAllRecordings()` has since gone too — see the bulk-delete
  entry in §10. `clearListening()` now has no caller either, and is kept only as
  the worked example the paragraph below points at.) Its doc comment recorded a
  hazard worth keeping, so it is restated here: **`imagesDir` is shared between
  `passes` and `recordings`.**
  A wipe that clears one collection while removing that directory orphans the
  other's thumbnails, leaving a broken thumbnail plus a stranded WAV and JSON
  entry. `clearListening()` shows the correct "recordings own their WAVs"
  scoping — copy it rather than reinventing a wipe.
- **`WavViewportMath.viewportForFreqZoom`** — **kept deliberately.** Frequency
  zoom is pinch-driven, so it has no caller, but it is a pure function with
  three passing tests and is the one-shot alternative to the gesture. Its doc
  comment says so; don't re-raise it as an orphan.

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
