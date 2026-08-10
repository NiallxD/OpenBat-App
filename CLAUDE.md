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
  Haptics/          pulse haptics (accessibility channel)
  Heterodyne/       live heterodyne downmixer
  TimeExpansion/    playback-only classic expansion (no live expansion ships)
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

### Only the D240x pattern may be a live expansion mode (`Context.md` §3, §5)

Amended 2026-08-09, on Niall's call. The previous rule was an unconditional ban
on live time expansion pending a freedom-to-operate opinion. It is now narrowed
to a **shape** requirement, because one shape has a materially different patent
story from the rest.

**Permitted:** capture-a-snippet-and-replay-it-slowly, as the Pettersson D240x
does it — trigger on level, 50% pretrigger, replay the buffer once at a fixed
1/N, accept the deaf window, run heterodyne continuously alongside. The D240x
manual is the specification; follow it rather than reinventing the parameters.

**Still barred without the opinion `Context.md` §5 asks for:** any mode that
keeps up with a pass in real time by deciding what to keep — ATE, VTD, sampler
modes, anything that discards, dilates, or prioritises to avoid going deaf.
That is the family US 8,599,647 claims.

The reasoning, including what the amendment does and does not rest on, is in
`Context.md` §5. Two things it must not be read as saying: this is **not** a
clearance opinion, and the argument it rests on is **invalidity over prior art,
not non-infringement**. Do not restate it as either, in code comments least of
all.

Both previous live expansion modes remain gone: adaptive time expansion (ATE)
was replaced by variable time distortion (VTD) on 2026-08-08, and VTD was
withdrawn on 2026-08-09. VTD's code is intact but **outside every build
target**, in `Quarantine/VariableTimeDistortion/` — read that folder's
`README.md` before touching any of this. VTD is squarely in the barred family;
the amendment does not revive it.

- `OpenBat/OpenBat/` is a `PBXFileSystemSynchronizedRootGroup`: **any .swift file
  placed inside it is compiled into the app.** That is why the quarantine is a
  sibling directory and not a subfolder, and it is the thing to remember before
  moving a file "back where it belongs".
- **The quarantine is outside the repo root** (the repo root is this folder,
  `OpenBat/OpenBat/`; the quarantine is one level above it). So it is untracked —
  no backup, and it does not travel with a clone. The source is still in local
  history: `git show c035295:OpenBat/TimeExpansion/VariableTimeDistortionProcessor.swift`.
- **Branch `v1`'s history contains VTD** (commit `c035295`) and has never been
  pushed. Removing the mode from the working tree does not remove it from that
  history — pushing `v1` unrewritten publishes the full source.
- `PulseDetector.onPulseWindow` still fires but has no subscriber. It is
  detector output, not expansion machinery — leave it.
- `PulseDetector` is the only analysis a D240x-pattern mode may use, and only
  for "did something loud happen". A mode that measures what a call *is* —
  contour, duration, fundamental — is a different and worse thing; see
  `Context.md` §3 for two that were built and shelved.

File playback (`.timeExpansion`, `TimeExpansionProcessor`) is unaffected: it
plays every sample of the recording, which is the distinction §5 treats as real.

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
