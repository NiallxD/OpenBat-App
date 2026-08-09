# OpenBat — Claude Code Context

iOS bat detector app using the Griff ultrasonic USB microphone (384 kHz sample
rate, 192 kHz Nyquist). Targets iOS 18.6. Uses `@Observable` (iOS 17+)
throughout — no `@ObservableObject`/`@Published`.

> ## 📍 The project's context lives in `Context.md`
>
> **`Context.md` is where the history and reasoning live** — what was tried and
> rejected, what a measurement actually showed, why a constraint exists, and
> what is still open. This file holds only the rules and the operational
> details. If you are about to change anything in the audio pipeline, the
> upload path, or the Live Activity, **read the relevant section of
> `Context.md` first.** Most of what's in there was expensive to learn.
>
> When you discover something worth remembering — a failure and its cause, a
> measurement, a rejected approach — add it to `Context.md`, not to a code
> comment and not here.

Other documents:
- `CODEBASE_FUNCTIONS.md` — per-function reference.
- `README.md` — public-facing, including the field-guide contribution schema.
- `TimeExpansionTuning/FINDINGS.md` — raw measurement corpus for time expansion.
  Note the correction in `Context.md` §4: its §2 is measured with a broken
  instrument, and so is everything downstream of it.

---

## Project layout

```
OpenBat/
  Audio/            capture, recording, WAV/GUANO, storage, playback
  DSP/              Biquad, STFTGrid, resampler, calibration curve, log warp
  Heterodyne/       live heterodyne downmixer
  TimeExpansion/    live adaptive expansion + playback-only classic expansion
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
  ContentView.swift the detector screen; wires every subsystem together
OpenBatWiget/       widget extension target (note the missing 'd' — see below)
```

---

## Rules that must hold

Each of these has its reasoning in `Context.md`; the rule is here so it can't be
missed. Do not relax one without reading the section.

### Adaptive time expansion (`Context.md` §4, §5)

1. **Nothing is selected out or discarded within an event.** Emission runs
   through a delay line so the tail can be trimmed without ever retracting an
   emitted sample.
2. **Capture stops while the ring drains.** The processor is deaf for 8L after
   an event of length L. Do not make it keep up by capturing into a second
   buffer while draining the first.

`missedCount` is the honest cost of rule 2 — if it reads zero during a feeding
buzz, something has broken. The two-threshold (hysteresis) gate is required: a
single threshold clips the end off every call.

**Patent:** US 8,599,647 is active to 2032 and, on a plain reading, **both live
modes map onto all four elements of claim 1.** The two invariants above are
design rules, *not* a clearance argument. File playback is genuinely distinct
(nothing is selected). Read `Context.md` §5 in full before writing any
non-infringement claim anywhere in this repo.

### Live Activity (`Context.md` §12)

- It is a **budgeted message channel**, not a display. Never add a per-pulse or
  per-frame update path.
- The 15 s heartbeat is a budget decision, not a responsiveness one.
- Staleness is computed app-side and carried **in** the state — never computed
  in the widget from `Date()`.

### Upload and consent (`Context.md` §11)

- `AnonymizedUploadBuilder` is the single anonymisation boundary. Nothing
  derived from `DeviceIdentity` may appear in its output; it isn't a parameter
  on purpose.
- The GUANO key list is an **allowlist, never a denylist**.
- The on-device original is never reopened for writing.
- No lossy codec at any stage.
- Nothing uploads on its own — contribution is always a deliberate tap.

### Audio and display (`Context.md` §6, §7, §13)

- `AVAudioSession` configuration must run off the main actor.
- Detection uses a **fixed** dB scale; only the display's contrast is adaptive.
- PCM reads are anchored by **absolute sample index**, never "N back from now".
- `showTuningOverlay` must never be added to `ContentView.menuIsOpen` — that
  flag pauses the render loop, and the overlay exists to tune a *running*
  pipeline. Same for `showBand`/`showPulseView`.
- The colormap is defined twice (Metal shader + `DisplayPalette`). Keep in sync.
- Exactly one owner drains columns at a time: `draw(in:)` while active, the
  background pump otherwise.

### Concurrency (`Context.md` §13)

The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so types are
main-actor isolated unless marked otherwise. DSP types that run on the audio
thread carry an explicit `nonisolated` — don't remove it. `@Observable` tracks
at whole-property granularity, so high-churn state is mirrored into
equality-guarded properties and read from leaf views.

---

## Key constants

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

---

## Target and build wiring

- The widget target is named **`OpenBatWigetExtension`** and its folder is
  **`OpenBatWiget/`** — missing the `d`, a typo baked in when the target was
  created. Don't "correct" the path in the pbxproj without renaming the folder.
- `LiveActivity/BatDetectorAttributes.swift` and `BatActivityPalette.swift`
  reach the widget target through an explicit
  `PBXFileSystemSynchronizedBuildFileExceptionSet`. Moving or renaming either
  requires updating that list.
- The App Group `group.Niall.OpenBat` is declared in both entitlements files but
  **nothing reads it**. Don't take its presence as evidence of a dependency.

## SourceKit false positives

SourceKit frequently reports spurious errors — "Cannot find 'UIKit' in scope",
"Cannot find type 'SpectrogramProcessor' in scope", "unavailable in macOS",
"Reference to member 'shaderRead' cannot be resolved". These are **indexing
artifacts**. The project builds and runs correctly. Ignore them.

## Build/test policy

Don't boot a simulator or run `xcodebuild test` unless it's genuinely necessary
— the user runs actual builds and tests themselves. To check for compile errors,
use a **build-only** invocation that doesn't launch a simulator:

```
xcodebuild -project OpenBat.xcodeproj -scheme OpenBat -destination 'generic/platform=iOS Simulator' -configuration Debug build
```

Prefer this over a concrete `-destination ...,name:/id:`, which will boot one.
