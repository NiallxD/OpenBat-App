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
17. [The 2026-09-10 bug comb](#17-the-2026-09-10-bug-comb)

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
| 2026-09-08 | **Onboarding trimmed to fit one screen, and it now checks for the microphone.** The ID step lost its two label cards (they taught pill wording for a screen the user has not reached); the welcome footer reports whether an ultrasonic mic is actually plugged in rather than warning in the abstract; a denied microphone says what it costs instead of sharing location's mild wording. `OnboardingMetrics` tightens spacing on 667pt screens so every step fits without scrolling. See §7. |
| 2026-09-10 | Systematic bug comb across every subsystem (`BUGCOMB.md`, in the git history). Capture/session, settings-reset, launch-presentation, identification-score and field-guide findings fixed — see §17; the listening-DSP and export findings are reviewed but unfixed. |

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
  The processors' own gains are NOT separate from this correction, and must not
  be described as if they were: everything downstream of them is multiplied by
  the makeup, so a processor gain of 6 was really 24. That sentence used to end
  this bullet, and it is what left both gains far too hot. Heterodyne came down
  6 → 1 on 2026-09-01 (measured: 0.78% of output samples pinned at full scale),
  and the replay path stopped naming a number at all — it normalises against
  `ListenOutputStage` so a snippet lands on the knee whatever the makeup is.
- **1 was then too quiet in the field, and the fix was the heterodyne gain, not
  the makeup.** Reported 2026-09-09 after a night out: "the audio from the phone
  wasn't very loud". The replay channel was never the quiet half — it is
  normalised to just under the clipper, median call at −6 dBFS — while the live
  heterodyne bed sat about 24 dB below it, because the 2026-09-01 cut was 15 dB
  in one step. Heterodyne's default is now **3**: −6 dB from the setting that
  pinned samples, ~+9.5 dB on where it had been, which puts the live bed at
  roughly the level the replays already arrive at. Raising the makeup instead
  would have been wrong twice over — it is a fixed correction for a fixed
  attenuation, and the replay path derives its own target from it, so raising it
  moves the correction without moving the replays. The device's own volume
  control is the level control; the point of a hotter default is that its full
  range is useful.
- **The live channel's level and background reduction are settings now, not
  live-only knobs.** `HeterodyneProcessor.gain` and `.denoiseMode` existed, but
  only in the tuning overlay behind the config menu's passcode, and neither
  survived a launch — so anyone who found them lost them. `HeterodyneSettings`
  persists a ±18 dB trim (against `HeterodyneProcessor.defaultGain`, which stays
  the one place the level itself is decided) and the background mode, applied at
  every capture start by `seedSnippetProcessor`. Settings ▸ Detecting shows both
  channels in one card, "Live listening", behind a two-pill switcher carrying the
  transport menu's own glyphs — one decision, not two, because under `.both`
  routing they are set against each other. The overlay still writes the
  processor directly and still doesn't persist: that is what a live knob is for.
  Heterodyne's background default stays **Off** where the replay's is Scrub —
  Scrub silences whatever doesn't clear the gate, and on the channel that tells
  you a bat exists at all, "missed bat" and "quiet night" must not sound alike.
- **Default VALUES can now be set remotely, in the same file as the kill
  switches.** `RemoteDefaults` + `Tunable` (2026-09-09). The flags scheme's
  promise — the worst a bad config can do is remove a feature — does not survive
  numbers, so this half carries its own guard rails: only the parameters listed
  in `Tunable` exist, each declares the range it may take, and a value outside
  that range is IGNORED rather than clamped so a typo fails visibly instead of
  half-applying in the field. Changes take effect at the next launch (the fetch
  lands after the stores are built), and the whole scheme rests on one property
  of every settings store in the app: absence of a stored value IS the record
  that the user never chose one, so a remote default replaces the compiled
  constant and never a person's choice. **Anything that writes a default the
  user did not choose silently freezes that parameter on every install** — three
  places did, and were fixed with this: the one-time amplitude repair, the band
  simplified view applies on entry (which now stamps WHICH band it applied, so a
  changed default reaches installs that have already been through it), and the
  recording timings, which turned out not to be persisted at all. Per-model
  AutoID values are deliberately excluded — they decide what a recording is
  identified as, and belong to a build. See `AUDIT-2026-09-09-parameters.md` in the git
  history for the full inventory, and `SettingsDump`, which now records which defaults the
  config file is setting so two dumps can be compared without ambiguity.
- **The config file has a second message that does not interrupt.** `notice`
  stands at the top of Settings for as long as it is non-empty — a known issue,
  a release note, a thank-you — with no alert and no once-per-message
  bookkeeping. The maintenance message keeps both, and its Settings card is
  headed "Maintenance" now that the two sit together.
- **The live snippet mode is called "Time expansion" in the UI, and the noise
  reduction is Off / Normal / High.** Two naming decisions, both 2026-09-09.
  "Slow replay" was the app's own coinage for the D240x pattern and nobody
  outside the app used it; time expansion is what bat workers call this, and the
  playback-only mode keeps the plain name too, distinguished as "Time expansion
  (file)" in the one place it can appear. The code keeps `snippetExpansion` /
  `SnippetExpansionProcessor` throughout — the type names say which of the two
  shapes it is, which is exactly the distinction Context.md §5 turns on, and
  renaming them would blur it. Likewise `SnippetDenoiseMode`'s cases stay
  `.reduce` / `.scrub` while the labels read Normal / High: a person is choosing
  an amount, a reader of `SpectralDenoiser` needs to know that one of them
  silences everything that isn't plainly a call.
- **Demo mode now runs the same session as a live capture, because level
  judgements were being made against a louder path.** It used
  `.playback`/`.default` — deliberately, to stay off the record path entirely:
  no permission prompt, no input negotiation, nothing to fail where there is no
  microphone. But that is the category *without* the measurement-mode output
  cut, so the demo was several dB louder than the thing it stands in for, and
  the demo is what levels get tuned against. `configureSessionForDemo` now takes
  the ordinary session and keeps `.playback` only as a fallback for a device
  that cannot open a record-capable one (the simulator, or a refused
  microphone), so the pipeline still runs there. Only when a listen mode is on:
  demo with listening off still touches the session not at all, which is what
  the documented "demo dies when backgrounded with listening off" behaviour
  rests on, and there is nothing to hear in that state anyway. The one
  difference that cannot be removed is that there is no input tap — the file is
  the input.
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
- **Acoustic feedback is not fully fixable in software, but the runaway is.**
  Listening audio played out the built-in speaker gets picked back up by the mic
  and reprocessed as a spurious low-pitch "call" layered on the real one. Full
  echo cancellation risks degrading the ultrasonic capture path, so the app
  warns and tells the user to wear headphones — which is confirmed to fix it.
  What the app does now fix (2026-09-10) is the *runaway*: a finger snap near
  the phone used to set off four seconds of rising broadband hiss, because the
  soft clipper turns a pinned output into >15 kHz harmonics the band filter
  passes straight back in, and the noise renews the squelch hold every tick so
  the gate never shuts. `HowlGuard` sits between the makeup gain and the
  clipper, collapses the output when its level stays up longer than a bat pass
  does (0.35 s), freezes the LO and closes the gate while it does, and brings
  the level back to a ceiling 6 dB under wherever it ran away — so the gain
  converges on the loudest this phone/position/volume can hold instead of
  pumping. Armed only on the built-in speaker.

  The stabiliser alone left audible interference (Niall, same evening), so the
  same speaker route now also **band-limits the output to 8 kHz after the
  clipper** — below the 15 kHz the input band starts at, so the app can no
  longer hear its own output through any electrical path; what is left is the
  speaker's own acoustic distortion, which no filter reaches. Free on
  heterodyne (already low-passed to 4 kHz); it costs the 8× replay channel
  calls above 64 kHz, which is why it lifts on headphones rather than being
  unconditional.

  And the loop that mattered most turned out not to involve an ultrasonic
  frequency at all. A 384 kHz capture from the field (2026-09-10, `LACI`, with
  a laptop playing FM sweeps at it) shows the sweeps steady at 37–43 dB the
  whole run while 0–8 kHz — the phone's own output, heard by the mic — climbs
  from 27 to 42 dB, as loud as the calls themselves, with the gaps between
  calls rising 24 dB over the last seconds. Advanced view's band starts at
  0.02 of Nyquist (3.8 kHz on the Griff), so the auto-tuner was free to call
  the speaker's own output the loudest thing around and park the LO a few kHz
  under it — after which the speaker is mixing its own output back down into
  the audible band. **Listening is now floored at 15 kHz whatever the display
  band says** (`HeterodyneProcessor.minimumListenHz`): the input high-pass, the
  auto-tune peak, the LO and manual tune are all clamped to it. The display
  band is unchanged — it is a reasonable thing for a spectrogram to show, and
  only listening had a feedback path through it. Niall's call, on the evidence
  above: "for listening we can safely ignore anything under 15 kHz".

  **The warning is now an alert, not only the pill.** Above half media volume,
  on the speaker route, the first capture raises "Feedback at this volume" —
  once per capture, held back while another presentation is up (an alert raised
  under a sheet is dropped silently) and re-offered when that clears. Volume is
  watched by KVO on `outputVolume`; there is no notification for it, and the
  15 Hz stats timer would report a button press up to 67 ms late. The reason it
  earns an alert rather than a quieter hint is that the cost is not just an
  unpleasant noise: the pickup is *in the saved recording*, under every call,
  and no later processing can take it out again.

  Both halves are switchable in Settings ▸ Detecting ▸ Live listening — "Hold
  back feedback" (the stabiliser and the output band-limit together, i.e.
  `HowlGuard`'s armed flag) and "Warn about feedback" (the alert). Both default
  on. The 15 kHz listening floor is deliberately not among them: it is not a
  trade-off, it is where bats start.

- **The receiver was the loudest feedback path the phone has, and the session
  was leaving the sound on it.** `.playAndRecord` is configured with
  `.defaultToSpeaker`, but that is a *default*: every route change re-decides
  it, and under `.measurement` iOS is content to leave output on the receiver —
  which on an iPhone 14 is two centimetres from where the mic is held (Niall,
  2026-09-10: "we play the sound loud through the ear piece speaker"). Listening
  now states it explicitly with `overrideOutputAudioPort(.speaker)` after
  activation and again after every route change, so the sound comes out of the
  bottom speaker, the one furthest from the mic. Never applied over headphones
  or anything external — `.speaker` would force the built-in speaker and take
  the sound off them.

  On top of that, **hold to ear**: while listening, proximity monitoring is on,
  so raising the phone blanks the screen (iOS does that itself) and the sound
  moves to the receiver at −12 dB, like a call; lowering it puts it back. The
  false positive is a phone left face down — the sensor is covered, so the
  screen goes off and the sound plays into the table — which is why it is a
  switch (Settings ▸ Detecting ▸ Live listening ▸ "Hold to ear", default on)
  rather than unconditional. An iPad has no sensor and reads the flag back
  false, so nothing there ever fires.

  **The first version of this stopped the Griff connecting**, and both causes
  are worth knowing. An output override posts a route change of its own
  (reason `.override`), and the re-apply was wired to *every* route change — so
  each override triggered another, and the route renegotiated in a loop while
  the engine was trying to bind the USB input. And on `.playAndRecord`,
  changing the output re-picks the input: an override can drop a preferred USB
  input back to the built-in mic, silently. So the override is now (a) skipped
  unless it would actually move the route, (b) not re-applied on `.override`,
  (c) followed by re-asserting the USB input, and (d) done inside
  `configureSession` after `setActive`, before the engine starts, rather than
  under a running tap.

  **And `.none` does not mean "the receiver".** It means "the category's
  default", and this category's default is `.defaultToSpeaker` — so overriding
  to `.none` to put the sound at the ear landed straight back on the speaker
  and hold-to-ear did nothing at all on its first outing. Reaching the receiver
  means restating the category *without* that option and then overriding, which
  is a renegotiation — hence the preferred sample rate and the preferred USB
  input are both restated alongside it.

  Diagnostics now carries the two rows this cost a round trip for want of:
  **Output** (the port's own name, badged with its channel count) and **Hold to
  ear** (whether the sensor is being watched, and what it reads). An iPhone
  reporting `Speaker · 2 ch` is driving the earpiece as part of that route, and
  no override available to an app fixes that.

  The screen blanking is iOS's, and it lags the sensor by about 1.5 s — long
  enough that raising the phone reads as nothing having happened, even though
  the sound has already moved. The app paints its own black over everything the
  instant `isOnEarpiece` goes true, so the gap is invisible; the system blank
  then arrives underneath it. The overlay also swallows touches, which at an
  ear are a cheek.

  Two more things the first field test found. **Moving the route kills the
  audio**: a route change invalidates `AVAudioEngine`'s connections, the source
  node stops being pulled, and the output goes silent with nothing reported
  anywhere — so `.AVAudioEngineConfigurationChange` is now observed and the
  listening output node is rebuilt on it (only the output half: the input's
  format doesn't change when the output port does, and re-making a running
  384 kHz tap is how a route change starts dropping buffers). The handler is
  debounced at 0.3 s, because rebuilding the graph can provoke the very
  notification it is handling.

  And **the phone drives both speakers**: on an iPhone 14 the bottom speaker
  and the receiver are a stereo pair for this route (`Speaker · 2 ch` in
  Diagnostics), and no port override picks one of a pair. Asking for mono —
  `setPreferredOutputNumberOfChannels(1)` — is the only lever an app has over
  it. Whether it takes is visible in the same Diagnostics row.

  It does not take: the row still reads `Speaker · 2 ch` on an iPhone 14, so
  the earpiece is driven at the hardware level whenever the speaker is, and
  that is the end of the line for an app. Hold-to-ear and headphones are the
  ways out of it, which is why the volume alert now names hold-to-ear as one of
  the answers.

  The earpiece level is **half** the speaker's (`earpieceTrim`), applied
  digitally on the output. It started at a quarter and the first field test
  came back "earpiece goes silent when holding up" — this path is already
  attenuated by `.measurement`, so a quarter of it was inaudible. Half is a
  level, not the system volume: an app cannot move the user's volume slider,
  and one that could should not, since it would still be moved after the phone
  came back down.

- **Heterodyne base gain 3 → 5 (2026-09-10)**, after a night on real bats came
  back "the volume could definitely be louder... but I don't think we have any
  more room". There was room, and the reason is the band-limit: clipping used
  to cost loudness *and* feed the loop, because the clipper's harmonics landed
  where the microphone was listening. Filtered below the listening band, it now
  only costs loudness, and the knee is soft. +4.4 dB, still 1.6 dB under the 6
  that pinned samples.

  Two things this turned up. The live chain is **×317**, not the dozen that
  `HowlGuard`'s header claimed: it is the base gain × the trim (which defaults
  to its +24 dB maximum, deliberately, so the phone's volume control is the
  level control) × the output stage's ×4. Both comments now say so. And the
  snippet duck moved with the bed — −6 dB became −10.5 dB, because a hotter
  live channel with the same duck would have left the replay only 1.6 dB in
  front of where it used to be. The relationship is the thing, not the number.

### 2026-09-10: the power log

"The app is power hungry for sure but it would be good to see if we can pin any
down" (Niall). Nothing on the device will tell an app how many joules it spent,
so `PowerLogger` does the only thing that can actually find a culprit: one row a
minute recording what was switched on *and* what it was costing — battery
percentage and state, low-power mode, thermal state, process CPU as a
percentage of one core over the interval, screen brightness — against the
running/recording/demo flags, the listen mode, the visible tab, the sample rate
and the session's pulse and pass counts. A night where the battery falls 9%/hour
with the spectrogram on screen and 4%/hour in a pocket is an answer; a single
number for "the app" is not. Capture start and stop write their own marked rows
so an interval isn't smeared across the minute either side of it.

Its own cost is a coalescable timer (60 s, 10 s tolerance — a power log that
wakes the phone on its own schedule is measuring itself) and ~60 kB a night.

A separate CSV, carried inside the same export: the classifier log is one row
per pulse and 48 score columns, and power samples share none of that shape.
`ClassificationLogger.makeShareItem` stages it alongside, so "send me the
classifier log" still fetches everything.

Process CPU comes from two `task_info` calls — `MACH_TASK_BASIC_INFO` for
threads that have exited and `TASK_THREAD_TIMES_INFO` for the ones still
running. `proc_pid_rusage` would do it in one, but libproc is not in the iOS
SDK's module map and is not reachable from Swift.

### 2026-09-10: two narrow-screen fixes, and the sun clock leaves the tour

The species ID row put a fixed-size score badge and an unabbreviated "sounds
alike" pill beside a species name that was free to shrink, so on a small phone
the name was the part that gave: "Little Brow…" next to a caveat with room to
spare. The row now offers a narrower shape before that happens (`ViewThatFits`,
with `ComplexIndicator(compact:)` dropping to its question-mark glyph), because
the species is what the row exists to say. The score chip's caption is pinned to
one line for the same reason — wrapped, it pushed the chip down and made the row
taller than the photo beside it. And `panelHeader`'s title takes one line now,
after SPECTROGRAM broke across two and carried the panel's controls down with
it.

The **sun clock step is gone from the tour**. Its spotlight sat too high over
the pill through two attempts at the anchor: the pill lives in a `ToolbarItem`,
and the tour's anchor preference travels the view tree while the navigation bar
hosts its items outside it. A step that highlights the wrong piece of screen is
worse than no step, and the pill explains itself on tap.

The player screen has the same shortage: the call-analysis grid, the GUANO card
and the spectrogram do not all fit on a phone. Both cards are fixed-height and
the spectrogram is the only element that stretches, so the metadata card's
height came straight out of the picture the screen exists to show. They swap
now — opening GUANO hides the analysis grid, and measuring a call closes GUANO,
since numbers appearing behind a card read as the selection having done nothing.
Phones only: an iPad has the height for both, and hiding a panel there would be
taking something away to solve a problem that device does not have.

Two more tour edits the same evening: **End has a step** (it was the only one of
the three transport controls without one, and it is the one that decides whether
a night is filed or left running), and the **two listening cards became one**.
The second spotlighted the same button a step later to finish a sentence the
first had started — the deaf window is the reason the fourth mode exists, so it
belongs in the paragraph that lists the modes, not in a card of its own.

### 2026-09-10: a recording cannot be opened while a session is running

Tapping into a recording mid-session crashed the app (Niall). The two halves are
two claims on one audio session: `PlaybackEngine` already declines to take the
category while `AudioEngineController.isAnyInstanceRunning`, so playback was
silently inaudible rather than destructive — but it still activated the session
and attached its own engine beside a live 384 kHz tap, and that is where it
came apart.

Rather than make two engines share a session, the route is closed: while a
session is running, a recording row raises the same "End this session?" prompt
the transport menu's End button does, instead of navigating. `SelectableRow`
grew a `blocked` closure for it — given one, it is a button rather than a
navigation link. The prompt itself stays in `ContentView`, which owns what
ending a session means beyond stopping the audio; `SessionsView` and
`SessionDetailView` only ask for it.

The crash itself has not been diagnosed, only made unreachable from the UI. If
it turns up on another path, the place to look is `PlaybackEngine.start`'s
`setActive(true)` and the source node it attaches to `mainMixerNode`.

### 2026-09-10: Classifier Analysis — showing the model's working

"I want to surface what the model is doing as part of our 'Open' philosophy"
(Niall). Every other surface in the app reports a conclusion; this one reports
the arithmetic, including the half that has never been written down anywhere:
the model's own softmax, before the location priors touch it. The store keeps
adjusted scores, and so does the classifier CSV — raw vectors exist only in
memory at classification time.

So it is a **re-run**, not a replay. Off the microphone there is no deadline, so
every call gets a picture (live, they are drawn a couple of seconds apart
because drawing holds the capture queue) and a full score vector, raw and
adjusted side by side. Nothing is stored: the inputs are fixed — same WAV, same
model, and the session's own `PriorSnapshot` rather than today's weights — so a
re-run is reproducible and caching would only be a way to serve a stale one.

It is reached by a **mode**, not a button per row: "Classifier Analysis" in the
Recordings heading switches what a recording opens, because one recording has
two things worth looking at and a button for each, on every row, would say twice
what one switch says once.

What it cannot show: calls the live path never captured. The onsets come from
stored pulses, so a pulse dropped because a capture was already in flight leaves
no timestamp. Finding those means re-running detection, not classification.

**A Swift compiler crash came out of this** (`ClosureLifetimeFixup`, on the
`analyse()` task closure) and only under the coverage instrumentation a test
build turns on — a plain build was clean, `xcodebuild test` was not. The fix is
`ClassifierAnalysis.Input`: one value crossing to the background task instead of
twelve captures.

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

### The config menu's kill switches work both ways (2026-09-09)

They only ever turned a remotely-disabled feature back ON — a feature the config
file left alone showed as on and could not be touched. So the one thing the menu
could not do was run the app WITHOUT a feature, which is most of what a kill
switch is for: seeing what a user sees on the day one is thrown, before throwing
it. Every switch now works in both directions, and `Clear device overrides` is
the way back to whatever the config file says.

The safety argument is unchanged, because it never rested on the direction: an
override can restore the compiled default or take something away, and neither
produces an app that does more than the one Apple reviewed. What changed shape is
the stored value — a set of "switched back on" became a per-feature true/false,
so a decision survives the config file changing its mind. The old array is still
read on first launch after the update, as "these were on", so an installed device
keeps what it had.

The two iNaturalist posting-limit switches moved off the posting feature and into
the Overrides card (Niall). The feature switches say whether a feature exists on
this device; the overrides change how one behaves while it does, and hanging them
off the posting switch made them read as part of that feature's definition rather
than as a rule being suspended for a test.

### The mic QA numbers were measuring the wrong things (2026-09-09)

Three of the four microphone quality figures in the configuration menu had never
been usable, which is why nobody trusted them.

- **Noise floor was a running minimum of buffer RMS.** One buffer in hundreds of
  thousands decided it, and a capture's first buffers are routinely exact
  digital silence while the input unit settles — so it snapped to the meter's
  −80 dBFS floor within a tenth of a second and stayed there, on every
  microphone, forever. It is now the tenth percentile of a 1 dB histogram of
  buffer levels, which is the number the label always claimed: what this mic
  sounds like when nothing is happening. Buffers of exact silence are excluded
  rather than counted as very quiet, and a capture that is *all* silence reports
  no floor at all (`hasNoiseFloor`) instead of a spectacular one.
- **DC offset was the latest buffer's mean**, published at 15 Hz. A single ~10 ms
  window of real audio has a nonzero mean whether or not the hardware has any
  offset, so the figure flickered and meant nothing. It is now the session mean
  (sum of per-buffer means weighted by length), where honest audio cancels and
  only a real offset survives.
- **Peak level and the clip count included the settling window.** The transient
  an input unit can emit as it opens set the session peak. The first
  `AudioLevel.micQASettleSeconds` (0.25 s) of every capture is now discarded
  before any QA figure starts, and `totalSampleCount` counts only what was
  measured, so all four numbers are quoted over the same span.

The numbers are only comparable between two microphones if both were asked the
same question, so there is now a "Start measuring again" button
(`AudioEngineController.resetMicQA`). Before it, the only way to begin a fixed
test run was to stop and start the detector, which on a real night means ending
the session you are in the middle of.

### Settings cards lost their grey notes (2026-09-09)

Niall's second note the same day, and the bigger one: "the small text inside the
cards... I just want a row with the option title, and the action item (toggle,
button, pill) whatever."

Every card carried a line of grey type above each of its controls. One is fine;
a card with four controls carried four, and a page of those cards read as a wall
of small text — which is what "it makes the settings menus look so messy" was
about. **A row is now the option's name and the thing you touch, and nothing
else.** The explanation lives behind an ⓘ on the name (`SettingInfo`,
`SettingName`, and the row types built on them in `SettingsView`). The card
header keeps its title and its one-line description, which is what he asked to
keep.

The old ten-word, one-line rule went with the notes. It existed because the text
sat under a control on the narrowest iPhone; a popover has room, and several
notes had been cut back to the point of saying nothing ("NABat uses 21 dB.").
Every one of them was rewritten to say the whole thing.

**Two exceptions, both deliberate.** A *reason a control is unavailable* stays on
screen — the calibration button's "Plug in your ultrasonic mic", the haptics
card's Low Power Mode line, the mic QA card's "a demo file is playing" — because
nobody taps an ⓘ to find out why nothing happened, and a greyed-out control with
no reason beside it reads as a bug. And `ControlNote` survives for the two
screens that are not settings cards and read as prose: the model detail page's
citation, and the iNaturalist observation sheet.

The ⓘ is `.buttonStyle(.borderless)`, which is load-bearing rather than
cosmetic: a row can hold it and a real button (Share Log, Delete NoID), and a
List makes two plain buttons in one row ambiguous — tapping either fires both.

### The configuration menu became a settings page (2026-09-09)

Niall's call, and the same complaint as the Settings cleanup of 2026-09-02: it
was hand-rolled `VStack` cards on a rounded rectangle — a settings form drawn
worse — with a description above and a paragraph below every control. It is now
`Form`/`Section` under the three-part card rule in `SettingsView`'s header.

Four things left. **Demo mode** is a real feature now (started from the app-info
sheet, ended from the mic pill), so its entry behind a passcode was the last
trace of it being a debug tool. **The session button card** had settled the
question it was built for. **The four microphone cards** — stream, level meter,
mic QA, and a loose status line — became one, because a reader should not have
to know which of three cards to believe about the same microphone. And the
**iNaturalist posting-limit overrides** moved onto the posting feature switch as
its sub-controls: they are that feature's own settings and mean nothing while it
is off. They stay out of Settings for the original reason — the rules they lift
protect iNaturalist from near-duplicate records, and there is deliberately no
user-facing "post anyway".

One thing was added: an **Overrides** card, holding a switch that starts every
launch at the welcome flow. Onboarding happens once by design, so until now the
only way to look at a change to it was to delete the app and reinstall — which
takes the recordings, the sessions and the iNaturalist sign-in with it. The flag
is read once per launch, after the release decision rather than instead of it,
so What's New still gets to explain a build that re-runs the intro for its own
reasons (`OnboardingState.applyEveryLaunchOverrideOnce`).

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
- **A demo still reached Sessions anyway, by the back door (found 2026-09-02).**
  Blocking the recorder and opening no session left the demo's IDs as
  session-less passes in the Listening bucket — and `adoptOrphanedListeningPasses`,
  the launch-time migration written for pre-2026-08-16 "Just Listening" history,
  runs on *every* launch over *any* session-less pass. So the next launch
  invented an outing around an evening's demo runs: a Sessions row full of
  species IDs with "No recordings in this session" under it, which is what it
  looks like from the outside. Two fixes, both needed. Demo passes are now
  in-memory only (`ClassificationStore.demoRun` / `PassRecord.isDemo`) — the
  live species feed still shows them, `endDemoRun` drops them and their
  thumbnails when the demo ends, and a pass whose thumbnail write finished after
  that is discarded rather than inserted. And the migration is now bounded to
  passes dated before 2026-08-16: a session-less pass after that date is a bug
  upstream, and inventing an outing around it hides the bug behind a plausible
  row. Note that nothing links a `PassRecord` to a `Recording`, so "IDs with no
  recordings" is not diagnosable from the data after the fact — it is equally
  what you get from a run with recording off, or from Settings ▸ Storage's
  "Delete NoID Recordings", which deliberately keeps the pass log.

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

### Two things the spotlight got wrong (2026-09-09)

- **The transport-menu step was cut around where the menu had been for one
  frame, not where it is.** `SessionButtonAttached` centred its content on the
  button with `.position`, which needs the content's height, which meant
  measuring it into `@State` and placing it correctly only on the *next* pass.
  The first pass therefore laid the menu out centred on the session button —
  about 85pt below where it settles — and although that frame is invisible
  (`.opacity(0)`), a hidden view still publishes its geometry, and the tour reads
  exactly that. Whether the overlay ever saw the corrected rect was a race: in
  the simulator the stale one was the last value logged as often as not, and it
  spotlights the bottom of the menu plus a strip of empty screen, so Record (and
  sometimes Listen) sits outside the hole.

  Placed by layout alone now — a bottom-aligned frame of the available height
  puts the menu's lower edge exactly above the button, a centre-aligned frame of
  twice the button's centre-x puts its middle on the button's — so there is one
  geometry, published once, with nothing to go stale. The measured-size state and
  the `.opacity(0)` first frame are both gone with it.

  Worth knowing for any future spotlight: **a target that is placed from measured
  state will publish a wrong anchor first.** Anything the tour points at wants to
  be placed by layout, or fed in from a window-space measurement the way the tab
  bar and session button already are.

- **The short tour ended mid-sentence.** Its last step was the spotlight on the
  transport menu, and the tick closed menu and tour together with nothing said.
  It now ends the way the long one does, on a card with no target: the menu
  closes, the screen is handed back, and it says where the tour lives afterwards.

  Not reproduced: Niall also reports the sun clock spotlight sitting too high on
  his phone. It measures correctly in the simulator on an iPhone 17 and a 14 Pro
  Max (26.5), an iPhone 16 Pro (18.0) and an 11-inch iPad, from all three entry
  paths (Info & Tour, the nudge popover, and cold), so whatever it is is not
  reproducible here yet.

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

### The permission rows' empty circles read as checkboxes (2026-09-09)

Tester feedback: each permission card carried a dotted empty circle on its right
while the answer was still to come, which is the shape of a checkbox — so the
three cards read as a list of things to tick rather than a list of what the next
tap will ask for. Worse, one of the three (iCloud) genuinely is a control, which
made the wrong reading look confirmed.

The pending glyph is gone; the slot stays, so the tick arriving doesn't re-wrap
the paragraph beside it, and the row now animates on `state` — the answer comes
from an OS dialog, outside any `withAnimation`, so the glyph's own transition had
never played.

The refused mark went the same afternoon, for the same reason at the other end: a
denied row already swaps its paragraph for `deniedNote`, which says what is lost,
so the grey slash beside it was a second, vaguer copy of a message already in
plain words. **A tick, or nothing.**

The step also gained the grey footer the ID step ends on, saying that refusing is
not final and either permission can be switched on later in Settings. The two
`deniedNote`s lost their own copies of that sentence with it — the row says what
is lost, the footer says where to change it, and neither says both.

### iOS never asks twice, so the refused rows do the asking (2026-09-09)

The step asked for a permission only when it believed the status was
undetermined, so one stale reading was enough to skip a dialog iOS would have
shown, and Continue appeared to do nothing. Both are now requested
unconditionally — an answer already given is returned without anything appearing
on screen, so there is no cost to asking — and each status is re-read from the
system afterwards rather than predicted.

That fixes the case where a dialog was owed. **It cannot fix the refused case,
because iOS puts its dialog up once per install and never again.** So a refused
row is now a button: a red cross for the answer, a chevron beside it, and a tap
that opens OpenBat's page in the Settings app — which is the whole of "ask
again". A row that says what was lost without offering the one way back is a
statement with no reply.

The three states are therefore: nothing while it is still to come, a green tick
for yes, and a red cross plus a chevron for no. The cross and the chevron are not
redundant — one is the answer, the other is what to do about it — and this is the
only tappable row on the screen, which is the opposite of the empty circles that
came off it the same day.

### The permission rows were believing a stale location status (2026-09-09)

Found by Niall testing the refused path: with Location set to Never and the
microphone off, the mic row said so and the location row still offered sunset
times — and Continue then appeared to do nothing, because with nothing left to
ask it asked for nothing and the step's "everything decided" test was reading the
same stale value.

`LocationProvider.authorization` is published state set in `init` and thereafter
only by the delegate, and a `CLLocationManager` read the instant it is created
can answer `.notDetermined` before its connection to the location daemon is up.
`refreshAuthorization()` re-reads it, and onboarding now calls that — along with
re-reading the microphone status — on appear and whenever the app becomes active,
since both can change outside the app and neither is observable.


### The ID step's cards are now about IDs (2026-09-09)

Under a heading reading "About the IDs", the step's one card explained where the
app's settings live — true, useful, and about a different subject, which made the
heading look like a mistake. The card and the footer swapped places: the caveat
that identifications are suggestions was the pinned warning at the bottom and is
now the first card, because it is the thing the step exists to say, and "nothing
here is permanent" is the closing note instead.

A second card was added beside it — OpenBat can post a recording to iNaturalist,
where other people can check it. It is the honest answer to the question the
first card raises ("then how do I ever know?"), and the only one the app can
give. It is deliberately not gated on the iNaturalist feature switch: onboarding
runs before `ContentView`, which is where the flag store lives, and the card is a
statement about the app rather than about tonight.

The footer went grey with a gear, rather than staying orange with a warning
triangle. It is a reassurance now, and an orange wash on a reassurance teaches a
user that the colour means nothing — which would cost the welcome step's
"no microphone connected" warning its force.

### Onboarding: one screen per step, and a microphone it can see (2026-09-08)

A review of the three-screen flow. The shape was right; two things were not.

- **The ID step was teaching vocabulary for a screen nobody had reached.** It
  carried a card each for the "sounds alike" and "or SPECIES" pills, explaining
  a distinction that is invisible until you are looking at a pass — which no
  first-run user is. Both cut. Each pill already explains itself where it
  appears, and that is the moment the difference is worth anything. The step is
  now the caveat, one card promising nothing is permanent, and the warning
  footer. This is the same mistake, at smaller scale, that the eight-screen cut
  of 2026-08-17 was fixing.
- **"You need a microphone" was a standing warning, so nobody it applied to
  read it.** The welcome footer now probes for a USB input every two seconds
  while onboarding is up (`UltrasonicMicProbe`) and says which of three things
  is true: not checked yet, none connected, or connected — the last in green,
  because orange for a satisfied condition is how a user learns to stop reading
  a colour. The probe sets an `AVAudioSession` category and reads
  `availableInputs`; it never activates the session, so it prompts for nothing
  and interrupts nothing. The category is required — under the default
  playback-only category `availableInputs` hides inputs entirely, the same trap
  `AudioEngineController.prepareInputMonitoring` documents.
- **A denied microphone and a denied location no longer say the same mild
  thing.** Both rows shared "You can turn this on later in the Settings app".
  Without location the app is slightly less helpful; without the microphone it
  shows a permanently empty spectrogram and reads as broken. Each row now
  carries its own `deniedNote`.
- **Every step is meant to fit without scrolling**, and two of them did not on a
  667pt phone. The ScrollView underneath is for large Dynamic Type — a card
  below the fold on a default install is a card nobody reads. Fixed from both
  ends: the copy is shorter (the location row was four one-shot uses spelled out
  in one 40-word sentence; it is now one clause naming three), and
  `OnboardingMetrics` supplies a second, tighter set of spacings below 700pt,
  resolved once from the window scene rather than per-frame from a
  `GeometryReader`. **No font size changes** — only the air around the text.
  The welcome step is the tightest at roughly 633pt of 647 available.

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

**Amended 2026-09-02: square was necessary but not sufficient.** The argument
above is about the *rect*, and it holds. What it assumed about MapKit does not:
that `.rect` frames a rect by matching whichever axis needs the wider view and
adding margin on the other. For a range much wider than it is tall the camera
came back framed to the view's HEIGHT instead, with the east and west ends of
the range off the map — common pipistrelle, whose padded rect is 1.5:1 (Niall).

So the card no longer relies on a fitting rule at all. The rect is squared off
before it reaches the camera — the short side grown around its own centre, slid
back inside the world where the range sits near a pole — and the card is drawn
in the shape that rect ends up. The two being the same shape leaves nothing to
fit. Measured against the presence data all 48 species square with room at both
poles (widest: greater horseshoe, 2.7:1 before framing), so the non-square
fallback only exists for data that doesn't exist yet.

### A bar that changes state breaks touches on a page that escaped its inset (2026-09-02)

Every control on the species page answered to a region 20–70pt ABOVE itself, on
iPad, and only after the page had been scrolled. It was drawn exactly where
SwiftUI said it was — a screenshot measured against the logged frames agreed to
the point — so the touches were the thing arriving in the wrong place.

The cause was the navigation bar being told to change while the page underneath
it had opted out of its safe area. The bar showed the species' name only once
the hero photo had scrolled out from under it, and that flip changes the top
safe area (measured swinging 140 ↔ 86). The page discards that inset with
`.ignoresSafeArea(edges: .top)` so the photo can run to the top of the window —
and when the inset moves, the content stays put while the touch mapping does
not. Both halves are needed for the bug: no other screen escapes its inset, and
before the title flip nothing moved it.

The title is now a principal toolbar item that is always present and always the
same size, and only its opacity changes — so it still appears when the photo has
scrolled away, and the bar's layout never moves. **Anything on this page that
makes the bar change SHAPE mid-scroll will bring this back.** Appearance is
fine: `toolbarColorScheme` flips on the same signal and always has been
harmless. It is content coming and going that costs a page its taps.

### The map has to be told twice, and the second time is the one that lands (2026-09-02)

Distribution maps were cropped on iPad, showing about three quarters of the
range. Nothing to do with the rect: the card is laid out at the full window
width and then narrowed to the reading column, and the map answers a resize by
holding its centre and its zoom — so a map framed for a 756pt view keeps that
zoom in a 592pt one and shows 592/756 of what it was given. iPhone never
narrows, which is why only iPad was wrong.

Two things had to be fixed to re-frame it, and the first is the trap:

- **Assigning the same camera position twice does nothing.** The re-frame ran on
  every size change and pushed `.rect(sameRect)`, and SwiftUI only sends a value
  that has changed. `reframed(_:)` nudges the rect by a ten-thousandth on
  alternate calls so no two re-frames are ever equal.
- **The map rescales itself LATER than any re-frame can be scheduled.** Framing
  in the same layout pass and again on the next tick were both overwritten by it
  (1116 → 585 landed on 0.082 of the world against 0.157 asked for). So the card
  answers the result instead of racing it: `onMapCameraChange` compares what the
  map settled on against the range and frames again if it falls short, capped
  per size change. Measured over rotations it takes one or two corrections and
  then reads settled.

### A zero-size drawable is not a frame (2026-09-02)

Rotating an iPad crashed on a Metal validation assertion — a display drawable
destroyed while a command buffer still needed it. A rotation takes the
spectrogram view through a zero drawable size on the way to the new one
(`CAMetalLayer ignoring invalid setDrawableSize width=0.000000`), and encoding
against the layer at that moment leaves the buffer holding a drawable the layer
then discards. `draw(in:)` now returns early on a zero drawable size.

Only Debug crashes — `MTLDebugDevice` is the validation layer — so a release
build would have carried the hazard silently.

### Range outlines must not pinch (2026-09-02)

Toggling Range/Records on the same species redrew the same cells differently
each time (Niall, spotted bat). The ring tracer closed a loop only on returning
to its *start*, so where two blocks of range meet corner to corner — one lattice
point, two ways out — the walk carried on through and traced both blocks as one
figure-of-eight. That is not a simple polygon and MapKit cannot fill one: it
abandons the tessellation part way (`Wrapped around the polygon without
finishing`, with the node count it had left) and not in the same place twice.

Closing a loop the moment the walk revisits *any* vertex splits a corner touch
into the two rings it always was, and makes the result independent of which exit
was taken first. Counted over the real data, pinched rings before the fix:
spotted bat 1 of 19, common pipistrelle 13 of 70, little brown 16 of 111 — and
zero after. **Records mode only.** Modelled ranges are solid and never pinch,
which is why this survived since 2026-08-17: the mode showing scattered single
cells is the one where diagonal touches are everywhere.

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

### The field guide's figures, in the Call Analysis card (2026-09-02)

The player measures eleven call parameters; the field guide publishes the same
kind of figures for the species the recording is filed under. Until now the two
lived on different screens, so checking a measured Fc against the book meant
leaving the recording.

The Call Analysis grid is four columns wide and holds eleven metrics, so its
last cell was blank. It is now a button naming the species code ("LACI") that
expands one reference row underneath: the guide's Pf, Cf and Duration, each
column-aligned with the measured metric it should be read against — Pf under
Peak, Cf under Char. Freq, Duration under Duration. The guide publishes no
bandwidth figure, so the third column carries the entry's call type and its
free-text notes behind the same info-popover gesture every other cell in the
grid already answers to.

Three things worth knowing:

- **This row is the one thing allowed to change the card's height.** Everything
  else about that card is fixed-height on purpose (a resizing card squashes the
  spectrogram it shares a VStack with — see `CallAnalysisPanel`'s header). Here
  the squash is the feature: it is a toggle the user opened, and it is why the
  comparison is a row you expand rather than a row that is always there.
- **The button appears only when there is something behind it.** The guide
  covers far fewer species than the models can name, so a code with no guide
  page — or an entry whose echolocation block has no figures filled in — leaves
  the cell blank rather than expanding four dashes. NoID recordings never show
  it.
- **It is gated on a measurement existing.** The grid is faded to zero opacity
  until a region has been selected, and an opacity-0 button is still tappable.

Reaching the guide from the player meant passing `SpeciesGuideStore` down
through Sessions; it is not constructed in the player, since it is a ~328 KB
JSON decode that already happens once at launch.

### Pages became columns on iPad, and compare no longer locks it up (2026-09-02)

Two changes to the guide, one cosmetic and one not.

**Pages read as a column.** A page took the full window width on iPad, which
put a line of body text across ~1300pt — about twice a comfortable reading
measure — and pushed a row of tiles out to opposite ends of the glass. Content
is now 80% of the width in portrait and 55% in landscape, centred, so the
margins are even. Two fractions rather than one because 80% of a landscape iPad
is wider than the portrait screen the number was chosen for. The rule lives in
one place, `PageColumn`, and applies to the species page, the guide's species
lists in both layouts, the sessions list, a session's page and a pass's page.

Nothing changes on a phone, or anywhere the container is narrower than 700pt (a
form sheet, a slim Split View pane — both can report a regular width class while
being no wider than a phone). Three screens are deliberately left full width
because their content is not reading matter: the globe, the WAV player's
spectrogram, and a **comparison pane** — those pass their width explicitly and
have already given up half the window to the pane beside them.

Two mechanics worth keeping straight:

- **Portrait versus landscape is decided on width alone**, not on an aspect
  ratio, so the rule can be applied to a view whose height is its content's
  rather than the window's. 1050pt splits them cleanly: the narrowest landscape
  iPad is 1080, the widest portrait one 1024.
- **Everything except the species page is inset with `contentMargins`, not by
  narrowing the view.** A list keeps its full-bleed background and leaves its
  scroll indicator at the screen edge that way; narrowing the view itself puts
  bare window down both sides of a page whose background is part of its look.
  The species page is the exception because it already pins its content width
  for a second reason — one over-wide card would otherwise let the whole page
  scroll sideways — and one pin does both jobs.

**`onScrollGeometryChange` was the wrong tool for measuring the viewport, and it
failed silently.** The first version of this read `containerSize` from it, and
the column never appeared: that modifier reports when the geometry CHANGES, and
a page opened, read and left without ever being resized never changes its
container size. Measuring the scroll view's own frame with `onGeometryChange`
reports at layout, which is when the answer is needed. Neither direction risks
the feedback the comparison view had to break with a `GeometryReader`: this is
the size the scroll view is GIVEN, which does not depend on what is inside it.

**Comparing from inside a species page locked the app up on iPad.** The compare
button opened a picker sheet *hosted by the species page*, and choosing a
species swapped that page out of the navigation path 350 ms later — asking
SwiftUI to finish dismissing a sheet whose host was being removed. On iPhone the
wait was long enough to get away with; on iPad, where the picker is a form sheet
over a live page, it was not, and what came out the other side was an invisible
modal that swallowed every touch. The app looked fine and answered nothing.

The fix is ownership, not another delay: the guide's stack now presents that
picker itself, and `SpeciesCompareMode.replacesPage` hands it the species being
read rather than receiving a pair back. **The sheet hangs off the
`NavigationStack`, not off anything inside it** — the stack's root content is no
good either, since it leaves the window the moment a page is pushed over it and
a sheet presented from an off-screen view never appears at all. The stack is the
one host in the chain a path change cannot disturb. The 350 ms wait stays; it
should now be belt to the fix's braces rather than the thing holding it up.

Worth remembering the shape of this, because it is the third time the same trap
has been hit here (see the notes in `SpeciesDetailView`): anything presented
from a view that a navigation change is about to remove is living on borrowed
time, and the phone forgives what the iPad does not.

The other route into a comparison — arming compare mode on a collection and
tapping two species — was never affected: it is a plain `NavigationLink` push
with no sheet and no path surgery.

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

### The detection floor was one serial queue, not the silicon (2026-09-07)

Three devices played the same 200 s demo clip and disagreed about which bat they
had heard. The disagreement was real and reproducible across two sessions, and
the cause was not the classifier.

**What was measured.** Each device had a hard floor on how close together two
detections could be: 0.32 s on an A16 (iPhone 14 Pro Max), 0.35 s on an A15
(13 Pro Max), 0.45 s on an A14 (iPad Air 4), the last drifting to exactly 0.50 s
by the fourth loop and never recovering. The A14 logged 19% fewer pulses than
the A16 — but not uniformly: **LANO −10%, MYYU −22%, MYCA −24%, MYLU −28%,
EPFU −100%.** Losses track *call rate*, not species. Within the clip LANO calls
every 0.73 s and clears any floor; MYLU calls every 0.42 s and MYYU every
0.35 s, and both fall under the A14's. Every EPFU call in the clip arrives
0.38–0.40 s after its predecessor, so the A14 scored zero EPFU in all seven
loops.

The floors line up almost exactly with Neural Engine throughput (17 / 15.8 / 11
TOPS), which is what made this look like a compute limit for two sessions. It
was not. **`captureQueue` was serial and ran draw-then-classify for every
pulse.** The capture gate is released between the two, but the *next* pulse's
drawing still queued behind the *previous* pulse's inference — so the gate could
not reopen until a model run had finished, and the detector accepted one pulse
per (draw + infer). It scaled with device speed because inference does.

Classification now has its own queue (`classifyQueue`), bounded at
`maxPendingClassifications = 8`. Bounded rather than unbounded on purpose: a
feeding buzz arrives far faster than any device classifies, and an unbounded
backlog does not lose pulses so much as answer minutes late, about a bat that
has gone. Past the cap the pulse is still counted, drawn, filed and logged —
only the species question is skipped.

**The losses used to leave no trace.** `pulseCount` and `pulseRateHz` come from
`registerDetection()` and were always right; everything downstream held only the
pulses that fit, and nothing said so. `capturesSkipped` and
`classificationsSkipped` now count the two failures separately — one means the
device cannot draw fast enough, the other that it cannot infer fast enough — and
both are written on every demo row as running totals. A demo row noted
`classifier behind` is a pulse the cap refused, distinct from `not classified`.

**What is still open.** The A14's drift from 0.449 to a pinned 0.500 s is not
explained by fixed hardware and was not addressed here; re-measure it now that
the queues are split. And the demo clip this was all measured on is
unrepresentative — its fastest species calls at 2.9/s against 5–17/s for real
search-phase echolocation and 100–200/s in a feeding buzz — so every number
above is a floor on the problem, not a measure of it.

### The floor was a fixed wait for the wrong model's window (2026-09-07)

Splitting classification onto its own queue (above) changed **nothing**: filed
pulses per second went 1.346→1.337 on the A14, 1.598→1.556 on the A15,
1.658→1.689 on the A16, and the minimum gaps did not move. The counters added
alongside it are what found the real cause, and they were worth more than the
change they shipped with.

**All three devices file about a third of what they hear.** 308/312/294 pulses
detected, 98/115/110 filed — 68% / 63% / 63% discarded, and **zero** discarded
by the classifier on any of them. The classifier was never the bottleneck; the
first fix was aimed at the wrong stage. Note also that the three agree the clip
triggers ~4.3 times a second, so the per-species "call rates" read out of
earlier logs (1.4–2.9/s) were each device's throughput, not the recording.

What actually gates the rate is the capture arming window. A pulse is armed and
then waits `deferTrailSeconds` for its trailing audio, and every pulse arriving
during that wait is discarded. That interval was a max over `ModelRegistry.all`
— BatDetect2's 179.2 ms — so a NABat run waited 184 ms to fill a 50 ms window.
Subtracting it from the measured floors leaves the drawing: 116 ms on A16,
149 ms on A15, 266 ms on A14.

Two changes followed. The wait is now the **active** model's (35 ms for NABat,
so 40 ms with slack). And the pulse image is drawn only when it will be used:
the pulse view is an intermittent sample on a 2 s refresh, so most captures were
building a 480×1023 pixel buffer (~2 MB, scalar loop) that was discarded on
arrival — while holding the queue that decides whether the next pulse is looked
at. The analysis those pulses need (peak frequency, duration, band, quality)
runs either way; only the picture is conditional, and a pass always draws at
least one so it has a thumbnail.

**Every stage is now timed in the demo log** (`t_wait_ms`, `t_image_ms`,
`t_classify_ms`). Two rounds of reasoning about this floor were wrong, and
neither could be checked because nothing was measured. Do not diagnose this path
again without reading those columns first.

### Pulse "quality" measured brevity, so low bats were never drawn (2026-09-07)

Niall noticed LACI pulses were never appearing in the pulse view. They were
being detected, classified and filed — just never shown.

The pulse view refuses to draw a call scoring below 0.35 on `quality`, which was
`1 - (mean column peak over the search region / peak column)`. The search region
is a fixed ~20 ms window, so a **longer** call fills more of it, lifts its own
denominator, and scores itself down. The metric meant "how brief and isolated is
this", not "how clean is this".

Duration tracks frequency, so the penalty fell entirely on the low species.
Measured on the demo clip: MYYU 2.1 ms → 0.90, MYLU 6.3 ms → 0.69, EPFU 7.3 ms →
0.63, LANO 13.3 ms → **0.33**. LACI calls are longer still. The view was hiding
whichever bats it was least able to describe, and had been since the metric was
written.

Quality is now measured against the **background** — the columns of the search
region outside `durStart...durEnd` — which makes it independent of call length.
A call filling the whole region leaves no background to compare against and
deliberately scores 0.5 rather than guessing, because nothing at that point can
separate a very long call from continuous noise.

Two things made this worse in passing and are worth remembering. The same-day
change that draws a picture only when the pulse view will use it added
`displayUpgradeQuality = 0.5`: once a short Myotis at 0.90 held the panel,
nothing else in the 2 s window was drawn at all, so a long call had even less
chance. And `PulseQualityTests` now pins the behaviour — it was checked in both
directions, and the duration-independence guard does fail against the old
metric. The first version of that test did NOT fail against it: a fully tapered
synthetic burst only clears the noise gate near its middle, so it reads as a much
shorter call than it is. Test calls need flat tops and short ramps to behave like
the real thing.

### The pulse spectrogram is drawn at half the column density (2026-09-07)

Measured, not assumed: the pulse render costs **129 ms uncontended** on an iPad
Air 4 over 345 frames, and the live figure is 96% on-CPU — so it is real work,
not a starved thread, which is what two earlier rounds of wall-clock timing
could not establish. The capture queue has about 230 ms per pulse to keep up
with a bat calling at 4.3/s, and was spending most of it here.

The transform's cost is linear in the frame count, so `PulseImageRenderer`
now asks `STFTGrid.compute` for a 64-sample hop rather than the shared native 32.
Half the frames, half the cost. Nothing else about the transform changes — same
window, same FFT size, same bins — so the grid stays compatible with every
consumer and frequency resolution is untouched.

**What it costs, and what it does not.** Duration quantises to 0.17 ms instead
of 0.083 ms; calls are 2–16 ms and every display rounds duration to 0.1 ms or
whole milliseconds, so this is invisible. Peak frequency is unaffected — that is
set by the window and FFT size. **The raw recording is untouched by any of
this**: the WAV is written straight from the audio stream with no dependency on
the render, so the full detail is always there to re-measure. The iNaturalist
notes now say the parameters are rounded and point at the recording.

**Shipped at 64 first, then 128 after someone looked.** The columns are the
picture: at 128 a 10 ms view is 30 columns, ~12 points per column on screen,
which the pixel count says should be blocky. It is not — the display's own
interpolation covers it, and Niall's verdict on seeing it was that the images
look fine. So the arithmetic was right about the pixels and wrong about the
outcome, in both directions on the same day: it would have taken 128 blind (bad
reason, right answer), and 64 was chosen from a number rather than from looking.
If this ever needs to go back, let it be because a person could not read a
call's shape, not because the column count looks low.

Measured after the change (build 210, hop 64, iPad Air 4): 2.961 pulses/s
against 1.346 at baseline, floor 0.100 s against 0.450, capture loss 31% against
68%. Per 100 s the fastest callers gained the most — MYYU +208%, MYLU +141%,
LANO +92% — which is the species bias running backwards, and the A14 now files
more of every species than the A16 managed before any of this work.

**It also broke the pass ties, which was not expected.** All four passes cleared
with a minimum margin of 0.0745, against two ties at 0.017 and 0.009 the run
before. The tie was being fed by the bias: averaging over a sample that had
dropped the fast callers disproportionately is what pushed LANO and MYLU
together. The segmentation problem below is still real, but it was never
independent of throughput the way this document previously implied.

### The pulse view cut long calls in half (2026-09-07)

The default view was a fixed window with the call's onset pinned at
`onsetFraction` (30%) from its left edge, so only the remaining 70% was
available for the call — 7 ms of the 10 ms default. Anything longer ran off the
right edge. LANO averages 13 ms on the demo clip and LACI is longer, so the
species with the most structure worth looking at were the ones shown clipped.

The audio was never missing: the rendered image is four windows wide, for pan
headroom. Only the *crop* was fixed. So the default crop now takes whatever
width the call needs, bounded by what was rendered, with the old fixed span as a
floor — a call that already fitted gets exactly the window it had before, which
keeps the constant scale that makes two pulses comparable by eye. Nothing is
captured or transformed that was not already; the change is free.

Note this is the second thing the same day that was hiding long calls, and they
were independent: `quality` refusing to draw them at all, and the crop clipping
the ones it did draw. Both were found by looking at the app rather than at the
logs, and neither would have shown up in any log column — worth remembering next
time the instinct is to add another one.

### The demo log became something other people send us (2026-09-07)

The demo plays one fixed clip, so it is the only input two devices can be given
identically — which makes it a benchmark, and the intention now is to ask other
people to run it and send the file back. That changes what the log has to carry:
a file you read yourself can rely on you remembering the circumstances, and a
file from a stranger cannot.

Three additions, each for a question a reader would otherwise have to guess at.

**`low_power_mode`.** It throttles the CPU, so a run made in it is
indistinguishable afterwards from a run on slower hardware — and the people most
likely to have it on are exactly the ones with no reason to think it matters.

**A footer** — `ended`, `elapsed_s`, and the thermal state and Low Power Mode as
they were at the end. Without it a run someone stopped after twenty seconds and
a run where the device stopped detecting look identical, because the rows simply
stop. The header's thermal reading is taken before any work happens and can only
ever say "nominal"; the end-of-run one is the one worth having.

**`memory_gb`**, for cohorting devices that share a chip but not a memory size.

`batbench report` reads all three and says so at the top of a file: a throttled
run, a device that got hot, or a log with no end marker are all called out before
any of its numbers are shown, because each makes those numbers mean something
different.

**Known limit, unfixed:** the filename carries the hardware model, not a unique
device id, so two devices of the same model produce the same filename. Harmless
when each person sends their own file, and the reason a third device went
missing from an export earlier today.

### First field evening, and the two things it could not answer (2026-09-07)

A 20-minute Squamish session, the first real audio through any of the day's
changes. 63 passes: 19 MYLU, 6 LACI, 1 MYVO, 35 NoID, 2 UNID.

**The margin gate holds up on real bats.** Every named pass cleared it with
room — minimum margin 0.193, median 0.666, against a gate of 0.10 — so it is not
over-suppressing. And the five tightest margins were all MYLU against MYVO, both
*Myotis*, which is where the confusion was predicted to be. It has still never
actually fired.

**LACI is being named at 0.95**, peak 21.2 kHz, 6.7 ms calls. That is the
species the old `quality` metric refused to draw at all, found in the field the
same evening it was fixed.

Two things the export could not answer, both now fixed.

**A NoID did not say why it was a NoID.** 26 of the 35 were honest — mean raw
confidence below the model's own threshold. But 9 had cleared it, one at 0.946
raw over 19 pulses, and nothing recorded what stopped them: the confidence
floor, the pulse-count minimum, or the margin gate. Those are opposite findings
sharing a label — "no evidence" against "good evidence, two species too close".
`PassAggregation.NoIDReason` now names which, persisted on the pass and exported
as `noid_reason`.

**Session exports timestamped pulses to the second.** Every inter-pulse gap in a
real session therefore quantised to 0 s or 1 s, so the field data could not be
used to check the pass timeout — the one question only field data can answer.
Now milliseconds, on every column rather than just the pulses, so a reader does
not have to know which timestamps in an export are precise.

**Still open: LACI passes ran 2–3 pulses each.** Hoary bats call slowly, often
0.5–1.5 s apart, which straddles the 0.8 s timeout, so their sequences are
probably being cut into fragments — and `minPassPulseCount` discards a fragment
of one. This is the failure predicted for 0.5 s, arriving at 0.8 s for the
slowest-calling species. **A per-model timeout cannot fix it: the right gap is
per-species.** Unmeasurable until an export with sub-second timestamps exists,
which is now the case.

### A pass was 26 seconds of four species, averaged (2026-09-07)

`finalizePass` averages the adjusted posteriors of every pulse in a pass, and a
pass closed only after `passTimeoutSeconds` of silence — which shipped at 2.0 s.
Nothing on the demo clip goes quiet for two seconds inside a loop, so one pass
held MYYU, LANO, MYLU and MYCA together and reported whichever of them had been
sampled best. **That made the species name a function of throughput rather than
of the audio**: across 19 loops of identical sound the LANO/MYLU margin never
exceeded 0.048 and was under 0.02 eight times, and the reported species changed
between builds while the recording never did. It read LANO while the fast
callers were being starved by the capture pipeline, and flipped to MYYU once
they were not — which was reported as a regression, reasonably, and was not one.

Two changes, both per-model and both adjustable in the model detail screen.

**The pass now closes after 0.8 s of quiet.** 0.5 was asked for first and the
gap data argued it down: within-species gaps reach 0.68 s at p90 for LANO, so
0.5 cuts inside a single slow bat's own call spacing and shatters one pass into
five. 0.8 and 1.1 segment this clip identically — there is a valley in the gap
distribution and both sit in it — so 0.8 was taken as the shorter of two equal
answers. Below ~0.75 is measurably wrong; above ~1.5 starts merging bats again.

**A pass whose top two species are within 0.10 is not named at all.** Deliberate
trade, made by Niall: two species genuinely calling at once now go unreported
rather than one of them being picked. Silence is the honest answer and the
pulses are still recorded — only the verdict is withheld. The number sits in an
empty band: correctly segmented passes separated their top two by 0.15 at the
tightest, the blended passes that kept flipping sat at 0.003–0.017, and nothing
was observed in between. Expect to loosen it for genuinely confusable species —
this clip's four are acoustically well separated, real *Myotis* are not.

**What the two together do, checked against three builds offline.** Builds 209,
210 and 211 — 53%, 69% and 93% pulse capture respectively — resegment to the
same species in the same places, with margins of 0.15–0.88 and nothing
suppressed by the gate. That agreement is the point: the label no longer moves
when throughput does.

The margin gate is off by default in `PassAggregation.aggregate` so callers that
predate it are unchanged, and it is passed explicitly by both the live detector
and the WAV tagging path — those two must agree, or a file's GUANO tag and the
pass in the history would name the same audio differently.

**An unnamed row shows the app's bat mark, not a spectrogram (2026-09-07).**
Every list that leads with a picture is scanned rather than read, and what a row
with no species had in that slot was whatever happened to exist: its own
spectrogram in two places, a grey tile with a waveform glyph in a third. At
thumbnail width a spectrogram reads as a species photo that happens to be dull,
which is the opposite of what the row is saying. All three now show one thing —
a dark tile with `batIcon` in orange, the colour the app already uses for an
unresolved ID on the "or MYYU" pill. `UnknownSpeciesThumbnail`.

NOISE gets the same tile with the mark struck through: "this wasn't a bat" is a
result the app is asserting, not a question it is declining to answer, and the
two must not look alike.

This reverses the 2026-09-02 decision to keep the spectrogram on those rows as
"the only thing there is to show". Still true, still not worth showing at 44
points; the full spectrogram is on the pass detail at a size where it can be
read. Two things fell out of it: the recordings list and the species feed were
each decoding a thumbnail per row that is now never drawn, so both decodes are
gone, and `RecordingThumbnailLoader` went with them. That type existed for the
reinstall case — a library that syncs back from iCloud before its JPEGs do, so a
first pass over a screenful of rows legitimately finds nothing and has to retry
on a backing-off clock. **Anything new that decodes on a list's behalf has to
handle that again**; the note survives on `ClassificationStore.ImageLoad`, whose
`awaitingDownload` case is the half of it that remains.

**NoID is recorded but no longer shown in the species feed.** The feed answers
one question — what have I heard tonight — and a row reading "Unidentified" does
not answer it. That was arguable before; the margin gate settles it, because a
NoID is now also what a deliberate refusal to guess looks like, so the better
the evidence gets the more of them there can be. They stay filed, keep their
pulses and measurements, and remain reachable from the session detail; only this
one panel is silent. Not gated on the `display.showNoID` toggle that hides NoID
in the recordings and pass lists — that control lives on the Sessions screens,
and a live panel changing for reasons nothing on it explains is worse than a
consistent rule. NOISE rows stay: "it wasn't a bat" is a positive finding and
the feed says so in as many words.

**Changing the default did nothing, and it took a build to notice.** `load()`
overlays the stored per-model payload on top of the descriptor defaults, so
every existing install kept its saved 2.0 s and the new value only ever reached
a fresh one. The run that followed looked exactly like the runs before it —
still four 26-second passes, 26.5 s apart — and read as the change having failed
rather than as never having been applied. There is now a one-time migration for
anyone still on the old default, and the pass timeout and margin are both
written into the demo header. **A setting that changes the output belongs in
that header**: the two that had just been changed were the two that were not
logged, and the log looked identical either way.

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

### Coverage picks the model; nobody is asked (2026-09-08)

`activeModelID` is now written by `AutoIDSettings.applyCoverage`, from the
location fix, on the same refreshes that derive priors. The "Suggested Model"
card, the "Suggested for your location" section with its Use button, the
per-model radios in AutoID settings and the "Use this model" toggle in
`ModelDetailView` are all gone. Niall's call, and the direction was "completely
automate this whole thing".

- **It was never a choice.** The two coverage boxes are disjoint — NABat is North
  America, BatDetect2 is the UK — so a fix yields exactly one answer or none.
  The card asked the user to confirm the only answer their coordinates allowed.
- **A fresh install has no model at all** (`init` sets `activeModelID = nil`), so
  that card was not offering an upgrade, it was the sole path to switching
  identification on. It was also one of five presentations racing for the
  first-launch slot, and losing that race left a new user with the app's headline
  feature silently off and nothing on screen to say so. See the ContentView
  first-launch queue problem, still open.
- **Out of coverage switches identification off**, rather than leaving the last
  model running. A North American classifier in Europe does not degrade, it names
  European bats after American ones with full confidence. `ModelChange.turnedOff`
  is what tells the user, and `AreaChangeSheet` says plainly that detecting and
  recording carry on.
- **The manual override went with it.** Any hand-picked model would have been
  overwritten by the next fix, and a control the app quietly undoes is worse than
  no control. The cost is real and accepted: someone just outside a box — France,
  say — can no longer force BatDetect2. If that comes back it has to come back as
  an override the automation *respects*, not as a switch that fights it.
- **Silent on the first fix, spoken on a move.** `pendingChangeSummary` is still
  never set on the first derivation, so first-run activation happens with no
  sheet at all. `AreaChangeSheet` (was `SuggestedModelSheet`) is now a notice with
  one button — by the time it appears the switch has already happened.
- **`speciesChanged` is suppressed when the model changed.** It is a diff against
  the model that was active before, and once that model is gone it counts
  something the user no longer has.
- `OnboardingState.justFinishedOnboarding` was deleted with this: the
  post-onboarding suggestion was its only consumer.
- Border crossings are covered by `ModelCoverageTests` — the transitions are pairs
  of coordinates thousands of km apart and unreachable by tapping.

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
deliberately-tapped contribution, which fuzzes it, or a deliberately-tapped
iNaturalist post, which does not — see below.

### Posting to iNaturalist (2026-09-04)

The second thing that can leave the phone, and the first that leaves it
*identified*: an observation on the user's own iNaturalist account, carrying the
call audio, a spectrogram, the timestamp, the coordinate and the classifier's
verdict. It happens only on a tap on `INatObservationSheet`, which shows all of
it first. There is no queue, no background post and no bulk action, by design —
see that file's header.

**Be precise about the coordinate, because "obscured" invites the wrong
summary.** OpenBat sends iNaturalist the *true* coordinate and asks for
`geoprivacy: obscured`; iNaturalist stores the real position and publishes only a
~0.2° cell. So the location is hidden from the public, not from iNaturalist. Any
privacy document that says OpenBat "only sends a fuzzed location" to iNat is
wrong. Obscured is the default because a precise bat record can disclose a roost,
and publishing at full precision is a choice the user makes on the sheet.

**What the app stores about it.** An OAuth access token in the Keychain (its own
service name, unrelated to `DeviceIdentity`'s), and a local ledger of what has
been posted — recording id, species, night, and a ~1 km rounded cell — which is
what the nightly cap counts. Neither is synced anywhere. The JWT that the v2 API
actually authenticates with is held in memory only.

**Three corrections to `iNaturalist-API-Application.txt`**, found by reading the
current specs rather than the draft: v1 has no `observation_sounds` endpoint at
all (so the integration is v2 throughout); v2 writes need a JWT from
`inaturalist.org/users/api_token`, not the OAuth token; and duplicates are
prevented by posting under a client-chosen UUID — the recording's own id — rather
than by the "same time and place" search the draft describes, which cannot tell a
retry from a second bat. Get the spec from `api.inaturalist.org/v2/api-docs`;
`/v2/swagger.json` 404s and the `/v2/docs/` JSON paths return the swagger-ui HTML
shell.

**The cap, and why it is shaped the way it is.** Two posts per species, per
night, per ~1 km cell, hard, with no override. Per *night* (noon to noon) and not
per day because a midnight boundary cuts a survey night in two and quietly
doubles the cap for anyone recording either side of it. Per *place* because
bat2inat's guidance is one or two per species from an *area*, and a flat nightly
cap would punish a transect, which is the most useful surveying there is. It can
afford to be hard because the manual web-uploader route needs no account and is
uncapped: what the cap removes is effortless bulk posting, not the ability to
post. Signing out deliberately does NOT reset the ledger — that would be a
one-tap bypass.

**One segment, and everything is made from it** (Niall, 2026-09-06). An
identifier reported that the uploaded audio did not match the spectrogram, and
they were right about something worse than they could see: the sounds were cut
out of the recording and the pictures were drawn from the whole file on disk, so
no picture and no sound shared a zero. "Part 1 of 6, 0–2 s" was the recorder's
PRE-ROLL — up to five seconds of dead air that appears in no attachment anybody
can download — and every later tile's clock was offset from the audio by however
much had been trimmed off the front.

So `INatExport.passSegment` now cuts the bat pass out of the recording once, as
a plain span of real time, and that segment is the only thing anything
downstream reads. The full-spectrum sound IS the segment. The audible copy is
the segment with its gaps spliced out. Every spectrogram is drawn from the
segment with its first sample as time zero — `INatImageSources.rebased(on:)`
does that, re-analysing the overview grid rather than cropping the player's,
since the player's covers the whole recording and its columns are that much
coarser. The pre-roll disappears for free, because it is outside the segment.

An observation therefore carries two views of one clip: the numbered tiles are
consecutive real-time slices of the full-spectrum file, and the whole-pass
picture is the silence-removed view that matches the 16× audio. Each still says
which timebase it is on, and the description now says they are the same clip.

**The span is the union of what the app HEARD and what the classifier KEPT.**
The trim this replaces ran from the first classified pulse to the last, and a
pulse list holds only the calls a model kept — so a pass opening with two calls
the classifier skipped had those two cut off the front of the upload, audio the
app had already decided was sound and had drawn on screen. The bound is now the
silence map's outermost kept region, widened by the pulses where they fall
outside it. Both opinions can only ever add.

**The margin is what the size budget can afford**, asked for at
`preferredPaddingSeconds` (1 s, up from 0.33) and shrunk — never below
`minimumPaddingSeconds` (0.15 s) — until the segment fits under 20 MB. A third
of a second was enough to prove a call was not clipped and not enough to HEAR a
pass, and the file is the thing people play; two seconds of 384 kHz audio is
1.5 MB out of 20. Padding is the first thing to go and the calls are the last,
which is the opposite of what a fixed margin does when a pass is long.

**The packed audio's margin has its own floor**,
`INatImages.minimumPackPaddingSeconds` (20 ms), above whatever the player's
slider says. The player defaults to 5 ms, which is right for looking at a
spectrogram and wrong for listening: the audible copy plays at 16×, so 5 ms of
air before a call is 80 ms of it and every call started abruptly enough to sound
clipped. 20 ms is `SilenceMap.compute`'s own documented default and is a third
of a second of room at 16×. A floor, not a replacement — a user asking for more
still gets more, and the seams stay the ones they were looking at.

**The manual route hands over the same files as the automatic one, and stops
there** (Niall, 2026-09-06). Two things were wrong with it.

It offered the untrimmed recording and not the segment, which was the last place
the mismatch an identifier reported still survived: every picture describes the
segment, so somebody building the observation by hand attached audio seconds
longer than the pictures, starting somewhere else. `Files.all` is now
`sounds + photos` — byte-for-byte what the automatic route posts — and the whole
recording is gone from it. Offering two files that both look like "the
recording" is also a choice nobody should have to make while standing in
iNaturalist's uploader. Anyone who wants the whole thing has Share Recording on
the player, which is where that belongs.

And it opened iNaturalist's web uploader for you. That assumed both the
destination and the moment: somebody in a field with no signal, or headed for a
local records centre rather than iNaturalist at all, got sent to a web page they
had not asked for and had to come back from. Saving to Files is also the step
that has to happen FIRST whichever way they are going, since the uploader needs
files that already exist on the device. So the screen hands over the files and
stops, and the destination stays the user's.

**The two sounds are now for two different jobs, and only one is evidence**
(Niall, 2026-09-06). The export had no denoising in it at all — nothing in
`INaturalist/` referenced `SpectralDenoiser`, so the player's background control
(Off / Reduce / Scrub, and it drives the app's own speaker) never reached the
file anybody actually plays. At 16× the hiss is continuous and under everything,
which is a large part of why acoustic observations go unlistened-to.

So the listening copy is now the segment put through three steps in order: the
gaps cut out, the background SCRUBBED, then slowed 16×. The full-spectrum copy
gets none of it and goes up exactly as recorded, because that file is what
somebody re-analyses and spectral subtraction would quietly change every
measurement made from it. The description says which is which and tells a reader
to measure the raw one.

Three details worth keeping:

- **Packed before scrubbed.** The scrub measures the noise it removes from the
  audio it is handed, and packing removes gaps, not background — a packed pass
  is still roughly 90% background by duration (thirty calls of 5 ms inside
  1.7 seconds), so the median `estimateNoiseOffline` takes still lands in the
  noise. It is also four times less audio to run an FFT over.
- **Slowed last, though it makes no difference to the samples.** Expansion is a
  header rewrite, so the denoiser sees the same buffer either way; doing it last
  keeps "nothing after the expansion touches the audio" true.
- **Scrub is fixed, not the player's setting.** The player defaults its
  background control to Off on purpose — a recording being reviewed is evidence
  — which is right for the screen and wrong here. Following it would mean almost
  every observation carried an untreated file, and the person it costs is a
  stranger on iNaturalist with no way to switch it on.

The doc comment on `expansionFactor` used to say the copy "sounds the same as it
did in the app". That was untrue in both directions even before this — the
player keeps its gaps and defaults its background to Off — and it is not the
goal. What the copy matches is the player's slowest SPEED.

⚠️ **`estimatedUploadBytes` cannot see the silence map, and the real cut can.**
The row badge has no map — computing one per row is an FFT over the file — so it
still estimates from the pulse span, and the real segment is sometimes bigger.
The consequence is bounded because the real cut shrinks its own margins to fit:
the only recording that can be over the limit on the sheet and under it on the
badge is one whose calls alone span more than 27 seconds, and that one gets its
blocker on the sheet before anything is posted.

**Echoes are measured, and cost 20 points** (Niall, 2026-09-06). A call recorded
beside a wall, a road surface or a rock face arrives again a few milliseconds
later and keeps arriving until the reflections smear into a tail — and that tail
sits at the call's own frequencies, so it fills in the sweeps and blurs the one
thing an identifier reads. `EchoAnalysis` measures, per call, how far the sound
in the call's own band has fallen 6–40 ms after the peak, against the peak, with
the recording's own background as zero; the recording's figure is the median
across calls. A call with another call closer than 60 ms behind it is skipped,
since the neighbour would be read as the echo — which excludes a feeding buzz
entirely, correctly, because its calls overlap their own echoes by design.

It is a deduction, not a component, so a recording with no measurement scores
exactly what it always did. **Ten points, revised down from twenty the same day**
(Niall: "a high quality recording with echo is still good"). Reflections blur the
sweep an identifier reads, so they belong in the score — but they are one
property among several, and at twenty they could outweigh the confidence term and
most of the call count together. A clean, confident, twelve-call pass recorded
beside a wall is still a better record than a quiet two-call one in the open, and
the score has to keep saying so. It is never a blocker either — a reverberant
recording is still a true presence record, and where the bat was is the half that
does not blur.

⚠️ **Its two thresholds are reasoned, not measured.** `cleanIndex` (0.30) and
`reverberantIndex` (0.65) come from what the arithmetic implies, not from a
corpus of known-reverberant recordings, because there isn't one. They are the
part of this most likely to be wrong, and the way to fix them is to record the
same bat in the open and against a wall and see what the two files report.

The row badge does not measure this — an FFT per call, times sixty rows — so it
passes nil and deducts nothing, which can leave a badge one grade more generous
than the sheet. Same direction the size estimate already errs in, and the sheet
is where the decision is made.

**Superseded 2026-09-06, kept for the trap in its last sentence:** trimming is
not a size optimisation, it is what makes the feature work.

iNaturalist rejects sound files over 20 MB, and at 384 kHz that is 27 seconds.
`INatExport.trimmedToCalls` cuts to the span the pulses occupy plus a third of a
second either side, using the classifier's own pulse timestamps rather than a
second energy-detection opinion in the export path. Note the trap this avoids:
`audibleCopy` rewrites the WAV header rather than resampling, so the audible copy
is *byte-identical in size* to what it was made from — trimming the original but
not the copy would have left the file people actually play still over the limit.
A recording that is still over 20 MB after trimming scores 0 and cannot be
posted, because an acoustic observation with no audio cannot be verified by
anyone.

**How a row shows it**, after trying three things in one afternoon
(2026-09-04): a leaf badge, in the trailing position the confidence percentage
used to occupy — and the percentage is gone.

The badge came first and sat NEXT TO the percentage; Niall read the two as one
thing, which they are: two small trailing marks that both look like a verdict on
the same recording. Moving the mark to a pulsing outline round the whole tile
fixed the collision but was too much for a list. So the collision is resolved by
deletion instead, and the percentage is what goes: it answers "how sure is the
model", which the row already implies and the detail screen states properly,
while the leaf answers "should I do anything with this one" — the question a
list of sixty recordings exists to answer.

Gold filled leaf for Excellent, green filled for Good, orange outline for Fair,
nothing below that, and a green seal once it has been posted. **Three tiers, not
two** (Niall, 2026-09-06): Excellent used to share the green leaf with Good, so
the best recording of a night looked exactly like a merely solid one and the list
could not answer "which is the BEST of these" — the question somebody with a cap
of two posts per species per night is actually asking. Gold rather than a
brighter green, because two greens a shade apart are not a distinction anybody
can make at caption size in a scrolling list, and not yellow, which reads as a
warning beside the orange tier. The colour is `Color.goldLeaf`. Only good news is drawn: a list
where every row carries a grade answers the question much worse than one where
four rows in sixty have a leaf.

**That rating** is the same score,**That rating** is the same score,
but it must never trim to get it: the trim copies tens of megabytes and a list is
sixty rows deep. `INatUploadAssessment.estimatedUploadBytes` does the same
arithmetic the trim does — call span over total duration, times the bytes on disk
— so the badge and the sheet cannot disagree about whether something fits under
20 MB. Only good news is drawn: a leaf on fair-and-above, a seal on what has been
posted, and nothing at all on the rest, because a list where every row carries a
grade answers "which of these is worth doing something with" much worse than one
where four rows out of sixty have a leaf. The ledger is cached and decoded once
(a JSON decode per row per scroll is a stutter for nothing), and
`INatPostSignal` exists so a row stops advertising a recording that was posted
from two screens away.

**The 404 on the first live post was ours, not iNaturalist's.** Every request
was built with `URL(string: "observations", relativeTo: apiBase)`, and relative
resolution REPLACES the base's last path segment unless the base ends in a
slash — so a base of `.../v2` produced `api.inaturalist.org/observations` and
every call 404'd. `INatClient.endpoint(_:)` appends instead, and exists so this
cannot come back. The general lesson is the one this file keeps relearning: a
status code with no URL beside it is not a diagnosis, which is why `INatLog`
now exists. It logs every request and reply in a memory ring, redacts tokens
outright and rounds coordinates to ~1 km so it is safe to hand to somebody, and
is copyable from the failure state on the sheet and from Settings → Privacy.

**Every exported picture is drawn in `INatExportPlot`** (2026-09-04): a log
frequency axis with real ticks on a 1-2-5 ladder, a time axis on the same
ladder, faint gridlines carrying both across the picture, and a line underneath
saying which timebase it is on. Three labelled frequencies and two labelled
times were enough to know roughly where you were and nowhere near enough to
MEASURE anything, which is what an identifier does with a bat call.

That caption is not decoration. Two of the three pictures run on real time and
the whole-pass one does not: its silence is cut, so its axis measures RETAINED
audio. The spacing is uniform — packed columns are the same duration as the ones
they came from, they simply are not adjacent in the recording — so regular ticks
are meaningful, but the jumps are real and a reader who assumes otherwise reads
a gap between two calls that never existed. So each plot says "Real time" or
"Silence removed" on the picture, where it cannot be separated from it.

Geometry is fixed constants rather than a `GeometryReader`: these are rendered
offscreen by `ImageRenderer` at a size nothing else depends on, so every tick
position is arithmetic, and a `GeometryReader` would be one more thing to get
wrong in a view nobody can watch being laid out. The close-up is 3:2 where the
slices are 16:9 — one shape being read rather than a sequence being counted —
and its band is deliberately lopsided, 18 kHz above the call and 6 kHz below,
because harmonics run upwards and a tight top edge cuts through one and leaves
the call looking truncated whether it was or not.

**Nothing goes to Photos any more** (Niall, 2026-09-04). The manual route had a
"Save spectrogram to Photos" button for anyone who would rather build the
observation in iNaturalist's own app, and it cost a photo-library permission
prompt to enable a route that posts the call WITHOUT its sound — the thing this
feature exists to fix. The Files app needs no permission and carries everything.
`NSPhotoLibraryAddUsageDescription` is gone from the build settings with it: an
unused permission string is a question App Review asks.

**Two pictures, and neither is the player's overview** (`INatImages`,
2026-09-04). The overview spans 0 to Nyquist — 192 kHz at 384 kHz sampling —
and a call occupies perhaps 30 kHz of it, so at the few hundred pixels
iNaturalist shows an observation photo at, the evidence is a sliver in a mostly
black rectangle. It also has no axes, and measuring the call is precisely what
an identifier does. So an observation carries a CONTEXT view (the whole pass,
cropped to the call band with 20 kHz of headroom either side) and a DETAIL view
(the strongest single call, with kHz and millisecond axes). The close-up is
deliberately NOT as tight as the stored thumbnail: that crop was cut to feed a
classifier, where a pixel that isn't the call is wasted input, and a picture for
a person is the opposite — a call filling its frame gives a reader no way to see
that nothing was cut off and no quiet to judge it against. Widened to three
times the call's own window and ±8 kHz.

The context view has its **silence cut out** as well as its band cropped (Niall,
2026-09-04): a bout is mostly gaps, so a ten-second recording with six calls in
it drew six hairlines in a field of black, and at the size iNaturalist shows an
observation photo those are a few pixels each. It reuses the player's own
`SilenceMap` + `compressedOverviewRawTile`, computed in `INatImages` rather than
taken from the player so the picture does not depend on whether the user
happened to have hide-silence switched on — but off the player's own threshold
and padding settings, so it cuts the same gaps they were looking at. Skipped
when `keptFraction` is above 0.9, where packing would make the axis non-linear
for no gain. The packed axis is why this picture carries no time axis while the
numbered tiles, which are linear slices of the real recording, do.

It is re-colorized from `Overview.rawTile` at a new band rather
than cropped out of the finished image — `colorize` already does the band crop,
so this is the same path the noise-floor slider takes and the export cannot
drift from what the user was looking at. The detail view is `PulseImagePlot`
— the same axis-drawing view the pulse detail screen uses — through an
`ImageRenderer` at 3×, forced to `.dark`: its labels are `.secondary` and its
backing is `systemBackground`, and rendered outside a window there is no trait
collection to resolve those against, so unforced they come out light-on-black.
The band comes from each pulse's stored thumbnail bounds where it has them
(they include the sweep and harmonics) and falls back to peak frequency, which
underestimates the band — hence 20 kHz of padding rather than 5.

**Every exported spectrogram is log-frequency, always** (Niall, 2026-09-04) —
the one setting in the export that does NOT follow the player. The player's log
toggle is a display post-process (`LogFrequencyWarp.warp` on the finished image,
default off), so until now everything posted was linear whatever the user was
looking at. A call's shape is what an identifier reads, and on a linear axis a
45 kHz pipistrelle and a 25 kHz noctule are drawn at completely different sizes
for the same gesture; the picture exists to be compared with other people's, so
the axis that makes them comparable wins over the one the user happens to prefer.

Two things the warp drags in. It floors at `LogFrequencyWarp.floorHz` (10 kHz),
so the band actually drawn is not always the band asked for — `logWarped`
returns the drawn one and every label comes from that. And the axis labels can
no longer be arithmetic: all three now come from `LogFrequencyWarp.vFracToHz`,
the same function the warp itself uses, in both the tiles and `PulseImagePlot`
(which gained a `logFrequency` flag, off for the pulse detail screen that still
shows a linear thumbnail). Labelling a log picture with a linear midpoint is the
kind of error nobody would catch by looking.

**Both pictures use the user's own noise floor.** The context view gets it for
free by re-colorizing. The close-up does not: the pulse thumbnail on disk was
colorized at whatever floor was in force the night it was detected, which is
frequently not the one the user settled on while reviewing — so the close-up is
re-rendered from the WAV via `renderDetailTile` at the current floor, palette
and calibration curve, and the stored thumbnail is only the fallback. Its axes
come from the band actually rendered rather than the thumbnail's stored bounds,
since those agree only when the re-render succeeded.

**What the description carries, and why each line is there.** The audible copy
is 16× (was 10×): it matches the slowest speed OpenBat's own player offers, so a
call sounds on iNaturalist the way it did in the app, and it divides 384 kHz
exactly to 24 kHz. Both audio attachments are the TRIMMED audio and the note
says so. Alongside the raw confidence, the description now states what the
location weighting actually did — the weight applied to the claimed species, and
how many of the model's species were pushed below 0.20 — because the headline
confidence is not comparable between observers and an identifier otherwise has
no way to tell how much of it was the model and how much was the place. It comes
from the session's `PriorSnapshot` in force at the recording's timestamp (a
transect can carry several), and says "not recorded" rather than staying silent
when there isn't one, since silence would read as "no weighting was applied".
And a closing line saying every measurement is automatic, unchecked by a person,
and to be treated as a starting point.

**Observation fields (2026-09-04).** Three, and they are existing community
fields rather than tidier ones of our own — fields on iNaturalist are global and
the useful thing is to use whatever the bat-recording community already searches
on. Looked up on iNaturalist directly, since the API application named none of
them: **567 Bat detector model** (19,385 uses — far and away the established one
for acoustic bat records), **578 Recording method** (478 uses, and it has a FIXED
value list: time expansion | heterodyne | frequency division | direct recording),
and **308 Echolocation call frequency** (1,252 uses, free text, "dominant
frequency of call (kHz)"). Posted via `POST /observation_field_values`, never
fatal — an observation without its fields is still a good record, just harder to
find.

Two traps in those. 578 must say **direct recording**: OpenBat captures full
spectrum at 384 kHz, and answering "time expansion" because the ATTACHED audio is
time-expanded would describe a different instrument — one that records in bursts
and goes deaf between them. And 567 names the app, not the microphone: OpenBat
works with any USB ultrasonic mic and does not record which one made a given
recording, so the live input name would be whatever is plugged in now. If a mic
model is ever stamped into a recording's metadata, that field should carry both.

**A pulse's timestamp is not a position in the file, and this bit.**
`CapturedPulse` stamps `Date()` when the classifier finishes, so it carries the
pipeline's latency — tens of milliseconds, unpredictably. The close-up cropped
straight to that offset and landed next to the call rather than on it, which at
those spans means its ECHO: a few milliseconds later, same frequency, and
completely convincing in a picture with no context (Niall spotted it in
testing). The timestamp is now a hint only — `loudestMoment` searches ±0.25 s of
raw grid for the strongest column in the call band and centres there, which
fixes the latency and the echo together, since a direct call is louder than its
own echo. Measured off the raw dB grid, not the colorized picture: the colouring
has a noise gate and a per-column adaptive ceiling in it, so brightest pixel and
loudest sound are different questions. The window can't go much past a quarter
second either way without wandering onto the next call.

**Posting runs in the background, like a session export** (Niall, 2026-09-04).
`INatUploadManager` is `SessionExportManager`'s shape down to the inline-host
count, so the two pills behave identically and neither knows about the other: an
app-lifetime object owns the task, takes a `beginBackgroundTask` so a locked
screen doesn't suspend a 15 MB upload half way through, and draws a pill over
the tab bar. The sheet now hands the work over and dismisses; it used to own the
task, so dismissing the screen killed a post the user had already decided about.

Unlike the exporter there is no dispatch queue and no cancel flag — `INatClient`
is `async` all the way down and `URLSession` does its own IO, so there is no long
synchronous block to keep off the main thread and task cancellation reaches the
session by itself. That whole apparatus in `SessionExportManager` exists for file
work; copying it here would have been cargo.

Progress is **weighted by bytes**, not by steps: the observation, its fields and
its annotation are four small JSON requests and one sound file is tens of
megabytes, so counting steps would put the bar at 60% before anything slow had
started.

Two things this does NOT change. Nothing starts without a tap — backgrounding the
work is not posting in the background — and only one post runs at a time, since
two would compete for the same field signal and the cap means there is never a
queue worth having.

The finished/failed alerts live in their own `ViewModifier` rather than inline on
the root view: `ContentView`'s body is at the edge of what the type-checker will
do, and adding two `.alert`s with their own bindings pushed it straight over
("unable to type-check this expression in reasonable time").

**The sheet is drawn on the app's own tiles, not a grouped list** (Niall,
2026-09-04). `TileCard` in `TileList.swift` is the Settings card SHAPE — a
name, a one-line description, then the controls — drawn on glass, and this sheet
is the first user. The two idioms had drifted apart: `Form`/`Section` with a
`CardHeader` in Settings, glass tiles everywhere else, so a screen wanting the
Settings shape had to use a grouped list and then looked like a different app
beside the sessions list it was pushed from. It was also sitting on the trap
`pageBackground()` documents for forms — a grouped list's card is
`secondarySystemGroupedBackground`, which in light mode is white on the app's
own white page.

**The sheet follows the Settings card shape** (Niall, 2026-09-04): a short
name, one line of description under it, then the controls, and *nothing*
underneath — every section footer on this screen is gone. What a footer was
carrying either compressed into the description, moved above its control as a
`ControlNote`, or went into the pre-post alert, which is the exception the rule
already allows because an alert is read before a decision rather than beside
one. The claim sentence — that OpenBat posts at genus and the species
identification is the user's to make — is the one that moved to the alert; it is
the most important sentence on the screen and would not survive being cut to ten
words.

**The sheet has two routes, chosen by a segmented control at the top** (Niall,
2026-09-04): post from OpenBat, or do it by hand in iNaturalist's uploader. By
hand is not a fallback — it needs no account, nothing about it can break, and
some people would rather build the observation themselves — but automatic is the
default, because it is the one that gets a record posted at the moment somebody
is standing in a field looking at the call. The choice is remembered: somebody
who prefers doing it by hand prefers it every time.

The automatic route shows a **preview of exactly what will be uploaded**, in
order, with the sound files and their sizes underneath. Every other confirmation
on the screen is text — a species, a time, a place — and the pictures are the
part a reader actually judges, so they are the part most worth looking at before
it becomes permanent. It also catches what text cannot describe: a close-up
centred on the wrong call, a tile of empty noise, a spectrogram cropped to the
wrong band. The previews are decoded once into `@State`; `UIImage(data:)` per
body pass would re-decode a dozen PNGs on every scroll.

Nothing manual survives on the automatic route: the per-row copy buttons, the
Copy Notes button and the fields that can only be added by hand are all gone
there. A copy button on every line implies work the user is supposed to do,
which is the exact thing that route removes. The description text stays on both,
because on the automatic route it is not something to copy — it is a preview of
the longest piece of text going onto a public record.

The numbered section headers ("1 · What it was") only appear on the manual
route. They exist so the page can be worked down beside iNaturalist's uploader;
on the automatic route they would read as a checklist of things the user has to
do, when the point is that they don't.

**Upload order** (Niall, 2026-09-04), and it is deliberate because
iNaturalist shows media in the order it was uploaded: the slices in sequence,
then the whole pass, then the one call in close-up, then the time-expanded audio,
then the recording at its own rate. Detail first and summary after, which is how
somebody actually works through an acoustic record — walk the sequence, see where
it sits, then look hard at one call. Filenames are numbered to match so a reader
who downloads them all gets them back in that order rather than alphabetically.
The audio order matters most: iNaturalist plays the first sound, and a 384 kHz
file plays in no browser, so leading with it would hand every visitor silence.

**Two raw confidences, and only one of them pairs with the weighted figure**
(2026-09-05). The description printed "Confidence: 76% (location-weighted)"
above "Raw model confidence: 81%", which reads as a weighting that pushed the
species DOWN. It hadn't: the species' prior was 1.00, 21 of 31 were below 0.20,
and posteriors are renormalised after weighting, so its score could only go up.
The two numbers were different measurements. `PassRecord.rawConfidence` is the
mean of each call's own TOP raw score — whatever that call was individually
taken for — so on a pass whose calls disagree it is a maximum across several
species and sits above any one of them. `PassAggregation.Outcome` now also
carries `rawSpeciesConfidence`, the reported species' own mean raw score over
the same calls, and it rides the same path the weighted figure does
(`AutoIDOutcome` → `RecordingReport` → `Recording.rawSpeciesConfidence`) so the
pair is computed from one pulse set and their difference is the weighting and
nothing else. Optional, and the line is simply absent on anything recorded
before today — the raw scores were never stored, so there is nothing to
recover. The pass-level number is untouched: the CSV export and the upload
assessment both want "were these calls decisive", which is exactly what it
measures.

**The audible copy is packed; the full-spectrum one is not** (Niall,
2026-09-05). Trimming to the outermost call leaves every gap inside the bout,
and the audible copy plays 16× slower — so a 24-second recording of 30 calls
arrived as six and a half minutes of mostly nothing. It is now spliced from the
player's own `SilenceMap` (`INatExport.packedToCalls`), with a 2 ms taper at
each seam because a splice is a step discontinuity and a step slowed 16× is an
audible thump between every call. The full-spectrum file deliberately keeps the
recording's real timing: pulse INTERVAL is an identification parameter, and
splicing would rewrite it silently for anyone re-analysing the file. The map is
computed once in the sheet and handed to both the audio and the whole-pass
picture, so the two cut at the same seams — the description claims they do, and
two independent answers to "where are the calls" would eventually disagree.

**The whole pass now leads** (Niall, 2026-09-05), reversing the picture half of
that order: the packed whole pass, then the slices in sequence, then the
close-up. The first image is the observation's thumbnail everywhere iNaturalist
lists it, and "part 1 of 9" is a poor thing to be identified by — the
silence-removed whole pass is the one frame that says what the observation is.
Detail-last is intact; only the summary moved to the front. The audio order is
unchanged.

**Why the packed picture was the blurry one** (2026-09-05). All three pictures
are drawn into a 600 pt frame at 3×, so the PNG holds 1800 pixels of spectrogram
across, and anything analysed at fewer columns than that was being upscaled to
fill it. The whole pass was the worst case by a wide margin: it was cut out of
the overview grid, and packing keeps only the columns that held sound, so a pass
that is 90% gaps left about 400 columns stretched across 1800 pixels. It is now
re-analysed from the WAV over the retained audio
(`renderRawTileStitched`) at `INatExportPlot.pixelWidth` columns, with the
silence map still computed from the overview so it cuts exactly the gaps the
player did; the tiles and the close-up ask for the same number instead of their
old 1600 and 600. Vertically there is no more resolution to be had — 1024 bins
over 192 kHz, so a 75 kHz band is 400 rows — but the log warp was *throwing some
away*: at 1:1 it has to drop source rows at the top of the band to make room for
the ones it duplicates at the bottom, and the top of the band is where the
harmonics are. `LogFrequencyWarp.warp` gained a `heightScale`, and the export
asks for enough rows to cover the pixels it will be drawn at. The live views
still warp 1:1, where it is invisible and the memory is not worth it.

**Tiled 16:9 walk-through.** One picture of a ten-second pass gives an identifier
a few pixels per call, and call SHAPE is what they read. So the pass is also
uploaded as consecutive 2-second 16:9 tiles (max 12, skipped entirely for a
recording short enough that the context view already shows it), each with a kHz
axis, absolute start/end seconds and a "part n of m" line so a claim can be
pointed at one call. The tiles are scaled into 16:9 rather than cropped to it —
a tile's natural height is however many frequency bins the band covers, and
cropping would throw away the frequencies the picture exists to show.

**The description is markdown, with two links out** (Niall, 2026-09-05).
iNaturalist renders markdown in a description and OpenBat was writing a flat
wall of lines, which is what it looked like on the page. It now has three
blocks — the AutoID suggestion, the call parameters, the caveats — and the
classifier's name links to *The Two Models OpenBat Uses* while every
"Location weighting" line links to *OpenBat Species Priors for Location
Weighting*. The links are the point: an identifier who has never heard of NABat
ML cannot weigh what it said, and the alternative to a link is explaining the
same thing on every observation or not explaining it at all. One trap — markdown
folds a single newline into a space, so a run of one-fact-per-line rows renders
as one paragraph; every line with another directly under it gets the two-space
hard break, and none before a blank line, or there is a stray `<br>` above each
heading.

**The detector is named by the user, not detected** (`DetectorModel`,
2026-09-04). iOS reports a USB audio device's port name, and that is firmware's
own identifier rather than a product name — the Griff announces itself as
`bat_detector_usb`, which was going into every recording's GUANO `Make` field
and telling a later reader nothing they could not already see. There is no
registry to look a real name up in, and the set of mics that work as
class-compliant USB audio at 384 kHz is small, so Settings → Detecting asks
once and remembers: a short hand-maintained list (one entry today, Griff Mini by
Phil Atkin, and a "Generic Ultrasonic Mic" entry standing in for anything
unlisted). It feeds GUANO `Make` and iNaturalist field 567, and unset falls back
to the port name — a vague name in an archive beats a wrong one.

**iNaturalist reads the detector back out of the recording, not out of the
setting** (Niall, 2026-09-04). The setting says which detector is in use *now*,
and plenty of people own two — reading it at post time stamped tonight's
microphone onto a recording made last month with the other one. GUANO `Make` was
written when the file was recorded and is the only per-recording answer there
is. Only a name from `DetectorModel.known` is used: a file recorded before the
setting existed has the USB port name in `Make`, and publishing `bat_detector_usb`
would be worse than publishing nothing, because it looks like a model name and
isn't one. The read is off the main actor — a bounded seek for a resident file,
an unbounded wait for an iCloud-evicted one.

**No free-text option, and that is the point** (Niall, same day, erring towards
privacy). An "Other" text field was built and removed within the hour: this
string goes into the metadata of every recording and onto a public iNaturalist
record, people put their own names on their equipment, and there is no reliable
way to sanitise a sentence somebody wrote. A fixed list cannot leak something a
user did not realise they were publishing, and a mic that is not on the list is
a reason to extend the list. `current` ignores any stored value not in `known`,
so a string written by the build that had the text field is dropped rather than
trusted. Read straight from `UserDefaults` at chunk-build time rather
than pushed onto the recording queue like `setInputName`, so changing it
mid-session takes effect on the next file.

**What rank gets claimed: genus, never species** (2026-09-04, Niall's call —
this replaced a same-day rule that claimed the species above 85% raw
confidence). First match wins: no ID or noise → Chiroptera; no scientific name
for the code → Chiroptera; ambiguous across more than one genus → Chiroptera;
otherwise → **genus**. The species, its confidence, the runner-up and every
measurement go in the description as a *suggestion*, with a line asking anyone
who can confirm it to add the identification.

**Why no threshold at all.** A model's confidence is a softmax output, not a
probability of being right, and both bundled models were trained on recordings
from dedicated detectors — a phone with a plug-in mic has a different noise
profile, which inflates confidence rather than deflating it. 85% did not mean
what a threshold needs it to mean, and any other number would have been equally
invented. The costs are also asymmetric: iNaturalist moves the community taxon
by agreement, so a wrong species ID needs two people to disagree before it
shifts, while a correct genus ID needs one person to refine it. Under-claiming
costs a refinement somebody was going to make anyway.

**And no per-taxon exceptions, ever** (Niall, 2026-09-04). There are genera
where the acoustics genuinely do separate the species and a cleverer rule could
claim more; that is precisely the change not to make. This runs on every
recording every user makes, so it has to be one rule they can state — a list of
special cases is unexplainable at scale, impossible to keep right as models and
regions are added, and every entry in it is an argument nobody can settle.
Whatever the flat rule gives up is recoverable by a human from the notes and the
pictures.

Most complexes turn out not to need special handling — Myotis, Pipistrellus,
Nyctalus and Plecotus are each a single genus, so "can't separate these" and
"genus" are the same answer. Only a complex spanning genera (`lowfreq`: Big
Brown / Silver-haired / Hoary) goes to Chiroptera, and that is computed from the
members' own scientific names rather than recorded on the complex, so adding a
species to a complex can't leave a stale answer. Genus itself is the first word
of the binomial, which is always a real iNaturalist taxon — unlike a complex's
display name ("Myotis species", "Low-frequency bats"), which resolved to nothing
and left the observation as Unknown.

**One annotation: Alive** (attribute 17, value 18 — looked up from
`/v1/controlled_terms`, not remembered). Safe to set without asking, which
almost no annotation is: the observation is a recording of an echolocation call,
and a bat that is echolocating is alive. It is not an inference about the
animal, it is a restatement of what the evidence is. Deliberately the only one —
Life Stage and Sex are unknowable from a call, and Evidence of Presence is for
records showing something OTHER than the organism (a track, scat, a feather), so
annotating a call "Organism" adds nothing a reader couldn't see. Non-fatal like
the fields.

**Still not done:** the rest of the fields — "Number of calls" and the source
filename have no established community field, so they stay copyable-only.

**The listening copy no longer goes** (Niall, 2026-09-06). An observation now
carries one sound, the full-spectrum pass exactly as recorded, on both routes —
the API post and the files the manual route hands over. Everything above about
the audible copy describes how it was BUILT, and all of that code is still
there, still tested, and still correct; what changed is that nothing calls it.
`INatExport.prepareFiles` leaves `Files.audible` nil, so `sounds` and `all`
carry the segment alone, and the observation description no longer promises a
second file or explains which one to measure from.

What it costs is real and was the reason the copy existed: iNaturalist plays the
first sound it has, no browser will play 384 kHz, and a visitor who presses play
now gets nothing. The judgement is that a processed file — packed, scrubbed and
slowed — sitting on a permanent public record as the thing most people will
actually hear is the worse of the two, and that a reader is better served by the
spectrograms plus a recording that is unambiguously evidence. Putting it back is
one line in `prepareFiles`; the upload order in `sounds` already leads with
`audible` for exactly that case.

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

### The remote kill switches were never reachable (2026-09-06)

`FeatureFlagStore` fetches `OpenBatConfig.json` from GitHub once per launch, and
the URL named `master`. **This repo has never had a `master` branch** — the
branches are `main` and the version branches — so every fetch 404'd, and the
failure is invisible by design: an unreadable config falls back to the compiled
defaults, which is the safe direction and also exactly what a working config of
all-`true` looks like. The file itself only ever existed on `v1.1`, unpushed, so
there was nothing to fetch either way.

The URL now names `main`, and `main` carries the file. **`main` is a June
checkpoint of the code and is meant to stay one.** A shipped build asks for that
URL forever, so the branch holding the config has to outlive every version
branch — pointing it at `v1.1` would strand v1.1 installs the day v1.2 became
the branch anybody edited. It is fetched as config, never as code, so the stale
source on it costs nothing.

The lesson worth keeping is the shape of the bug rather than the typo: a kill
switch that fails safe cannot be tested by looking at the app. `curl` the raw
URL before trusting one.

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

- **The echo deduction is live and its thresholds have never been measured
  (2026-09-06).** `EchoAnalysis.cleanIndex` (0.30) and `reverberantIndex` (0.65)
  come from what the arithmetic implies, not from recordings where the answer is
  known — OpenBat has no corpus of reverberant files. Too strict and good
  recordings lose points they should keep; too loose and the term never fires.
  It is deducting up to 10 points on real observations in the meantime, which
  Niall decided to leave running (2026-09-06).

  Settling it is one evening's work: record a bat in the open and again close to
  a wall or a hard road surface, and compare what the two files report. The
  measurement itself is not in doubt — the close-up exported on 2026-09-06 shows
  a textbook tail from 17 to 28 ms — only where the line between "clean" and
  "reverberant" belongs. See §11.

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

---

## 17. The 2026-09-10 bug comb

A systematic sweep of every subsystem (`BUGCOMB.md`, kept in the git history
rather than the working tree). What was fixed
that day, and the reasoning worth keeping.

### An interruption is not the end of a session

An incoming call silently disarmed the recorder. `isActive` — the flag that
exists precisely so a transient stop doesn't read as "session over" — covered
the listen-mode restart and nothing else, so `handleInterruption(.began)` took
the same path a user-initiated stop takes, and `ContentView`'s
`onChange(of: isRunning)` disarmed. Capture came back on `.ended`, the screen
looked normal, and nothing was recorded from then on.

`isInterrupted` now joins `isRunning` and `isSwitchingListenMode` in `isActive`.
It is cleared by a successful start and by `stop()` — ending the session by hand
is the one thing that outranks a held interruption. The general rule this is the
second instance of: **anything that ends a session must distinguish "the engine
stopped" from "the user is finished".**

Demo mode was fixed in the same place: `DemoFileSource` drives its own timer and
knew nothing about the session, so it kept feeding the pipeline under a screen
reading "Interrupted". It is stopped on `.began` and restarted with everything
else.

### The audio-session rule applies to playback too

`CLAUDE.md` has said "AVAudioSession configuration must run off the main actor"
since the live capture path froze on it (§6). `PlaybackDriver.startEngine` was
calling `setCategory`/`setActive` straight out of `play()` on the main actor
anyway — the rule was written about one file and read as being about that file.
Session configuration and the whole output-engine lifecycle now live on a serial
`sessionQueue`. Two details that had to come with it: `outputSampleRate` is still
published synchronously, because the pacing thread reads it and pacing must not
wait on a route negotiation; and `stopEngine` sets a mute flag synchronously, or
a stop issued while the queue is inside `setActive` would keep the ring's last
~100 ms playing until that returned.

### A reset has to clear memory as well as storage

"Reset all settings" is a denylist over the whole preferences domain
(`SettingsReset`), which is the right shape. Two things went wrong after it.

`AutoIDSettings.loadPersisted()` refuses to run twice, so the reset's call to it
was a no-op, and the sheet writes that object out on dismissal — the erasure was
undone before the user got back to the app. Re-reading storage is not enough
either: after an erase there is nothing to read, and `load()` leaves memory
alone. `reloadAfterReset()` rebuilds the defaults from the model descriptors
instead.

And every `reset()`/`resetToDefaults()` assigned outside `seeding {}`, so each
persisting `didSet` wrote back the key the erase had just removed. From then on
`reseedRemoteDefaults`'s "only touch a key nobody has set" test failed forever
for ~18 remotely-settable values. All four now assign inside `seeding`.

### Ranges validate a number; pairs need validating too

`Tunable.range` can only ask whether a value is sane on its own. Both halves of a
swapped floor/ceiling pair pass, and the config is accepted in full — which
inverts the haptic mapping, and an *equal* pair divides by zero and hands
`CHHapticEventParameter` a NaN that no clamp catches, because every comparison
against NaN is false. `RemoteDefaults.adopt` now cross-checks ordered pairs and
drops **both** halves, so a rejected pair falls back to the compiled numbers as a
pair. `PulseHaptics` also answers 1 rather than NaN for a degenerate span,
because the guard belongs at the consumer as well as at the door.

### One-shot presentations take turns

The re-consent prompt and What's New both became true inside one `.onAppear`,
before SwiftUI had drawn anything, so one presented and the other was dropped —
permanently, since each latches as seen when it is *raised*. Pairwise guards had
already been added twice and had already been forgotten twice (the calibration
offer's guard never learned about the re-consent prompt or the nearby-species
sheet). There is a queue now: `LaunchPresentation`, drained one at a time, each
advanced by the previous one's dismissal after a beat — a sheet raised from
inside a dismissing presentation is dropped, which is the trap this codebase
keeps rediscovering.

**Note for anyone adding to `ContentView`'s body:** its modifier chain is at the
type-checker's limit. Adding a single `.onChange` to it fails the build with
"unable to type-check this expression in reasonable time", reported against
whatever closure happens to be last. That is why the queue advances from inside
existing `onDismiss` closures rather than from an observer, and why the tail of
`.onAppear` now lives in `finishFirstAppearWiring()`.

### One pill, one quantity

`IDBadge` showed a species' precision where the model published one and fell back
to the call's own confidence where it didn't. Two quantities, different scales,
different colour bands, printed as the same bare "94%" — and in a Sessions list a
species with a track record sat one row from a species without one, wearing
identical badges. Only the accessibility label told them apart.

The badge is precision, always (Niall, 2026-09-10). Where there is none it is
replaced by an `ⓘ` naming which reason applies — the model publishes no table, or
the species was tested on too few recordings — because an absence that explains
itself is worth more than a number that means something else. A pulse row, which
is about one call rather than a recording, gets a labelled `PulseScoreChip`
instead of a bare pill.

Simplified view was hiding the numbers in the feed and showing them everywhere
else. Its rule now: **no percentages on any row, in the feed or in Sessions, and
the numbers one tap away** — the feed's "How we get to an ID" popover carries
what this call scored, what came second, and the winner's track record, in
sentences. It used to tell the reader to go and switch Advanced on.

### Location picks the model, so only list the models location can pick

The AutoID card listed every model the app ships, each openable through to its
own settings screen, which reads as a choice between them — someone in Canada saw
the European model listed beside the North American one. Coverage has decided the
model outright since 2026-09-08. The card lists only models covering the current
fix, and says "AutoID not available in your region" where none does; the species
feed's empty state said "Turn one on in Settings ▸ AutoID", naming a control that
was deleted in the same change, and says the same thing now.

### Two smaller ones

A failed Wikipedia photo fetch was cached as a permanent "no photo" — every
failure mode returned the same plain nil, including timeouts, 5xx and the 429s
Wikimedia answers a burst of parallel requests with. One offline visit to the
guide cost those species their photos forever. Only a genuine answer (a 404, or a
page with no usable image) is remembered now.

And a call selection narrower than one analysis window produced no measurement at
all — the STFT needs `windowLen + hop` samples, 1.4 ms at 384 kHz, which is easy
to box by hand when zoomed in. `CallAnalysis` widens the *read* around the middle
of the selection to that minimum while leaving the selection alone. The picture
path had solved this already (`STFTGrid.effectiveHop`); it was never carried
across.

### Measure the room before you clean it

The snippet path's two level protections were both taken on the *cleaned* window,
"because what matters is the level of what actually comes out". True of the peak;
fatal for everything else, because the shipped default background mode is `scrub`,
which multiplies rejected time-frequency cells by a hard zero. A cleaned window's
median sample is therefore not a quiet level, it is 0, and both protections
collapsed: the background clamped to 1e-9, so the crest of any window holding any
surviving transient came out at 100+ dB and cleared a gate calibrated at 24 dB
against the RAW distribution (noise-only windows 15–19 dB, windows with a call
32 dB and up); and `byBackground` came out at ~6×10⁵ and never bound, so the
constraint documented as "what makes replays sound alike" did nothing and a
residual click was matched up to `targetPeak` or the 32× ceiling. Niall heard
exactly this in the field: keys and footsteps replayed at full volume.

The gate and the background cap are now measured before the denoiser runs; the
peak still isn't, because the peak is what will be heard. Room tone measured
before cleanup is also the right denominator for the cap on principle — what it
bounds is how far the ROOM gets lifted, and that answer should not change with a
listening preference.

Worth being clear about what this does *not* do: the replay is already gated
behind the pulse detector's rising edge, and a key jingle is genuinely loud
ultrasound, so it passes that gate honestly. The crest test rejects windows with
no transient at all; it cannot reject a transient that isn't a bat. Doing better
means judging what a call *is*, which the D240x-pattern rule in `CLAUDE.md`
explicitly bars this mode from doing (§3, §5). The remaining lever is the
detector's own amplitude/frequency threshold, which is shared with recording.

### The heterodyne channel's output rate is derived, not asserted

`outputSampleRate` was a hard 48 kHz while the producer emitted
`inputSampleRate / decimation`. The two agree only for input rates that are a
whole multiple of 48 kHz — which every expected rate is, but the rate is whatever
the hardware negotiates and nothing checked it. A 44.1 kHz interface gave a
permanent 8% underfill that the ±3% drift correction cannot close, so the ring ran
dry every time and `render`'s zero-fill turned that into continuous crackle. Both
listening processors now derive the rate; they share one output node and have to
agree about what a second is.

### A calibration curve is bins, and bins are only frequencies at one rate

`MicCalibrationCurve.apply` documents its precondition as "binCount, fftSize and
sampleRate all equal" and checked only the counts — and the count is 1024 at every
rate, so the guard could never catch a rate mismatch. The one gate in front of it
compared the mic's *name*, which is a weak key precisely because USB mics do not
report a UID we can rely on. A curve measured at another rate would have applied
every correction at the wrong frequency, silently, on the realtime thread, into
both the picture and the trigger scan. Both lookups now require the rate to match,
and a live rate change re-asks rather than leaving the old curve installed.

### Two more from section L

Scroll-back had no end stop — past the buffer the view went black with no way back
but the button that exists because you are already lost. The renderer publishes how
far the history actually goes (`ScrollLimit`) and the gesture clamps to it.

And every session export left its zip in `tmp` for good, one per session title,
hundreds of megabytes each. Exports now live in their own `tmp` subdirectory,
swept at launch and before each new export — deliberately *not* on the share
sheet's dismissal, which happens the moment a destination is picked and before
some activities have finished reading the file. A cancel landing during the
uninterruptible zip leg also deletes the file instead of opening a share sheet for
an export the user cancelled.
