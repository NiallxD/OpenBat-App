# OpenBat

An iOS bat detector: turn a compatible ultrasonic USB microphone into a live
detector that shows what you're hearing and names the species on-device.

This repo holds **the iOS app**. Two sibling repos hold the rest of the project:

| Repo | What's in it |
|---|---|
| [OpenBat-App](https://github.com/NiallxD/OpenBat-App) | This one — the iOS app source. |
| [OpenBat-FieldGuide](https://github.com/NiallxD/OpenBat-FieldGuide) | The species field guide data, and **how to contribute to it**. |
| [OpenBat-Website](https://github.com/NiallxD/OpenBat-website) | The website. |

## What is OpenBat?

OpenBat captures audio at up to 384 kHz, shows a real-time spectrogram, detects
individual echolocation pulses, and — where an openly available model exists for
the region — identifies the species on-device. Nothing is sent anywhere to do
it; the classifier runs on the phone.

## Why

Most tools for identifying bat calls are expensive, proprietary, and hard to get
hold of, which puts the experience out of reach for a lot of people who'd
genuinely enjoy it. Free apps that work with ultrasonic microphones already
exist, but as far as we know, none of them use the open-source machine learning
models that have been trained on bat echolocation calls. By building that
identification directly into the app, OpenBat helps people put a name to the
call they just heard — a small moment of recognition that builds a real
connection with bats, and a bit more respect for them too.

## Features

- **Real-time spectrogram** — high-resolution frequency-vs-time display, with
  drag-to-scroll history in the full view.
- **Pulse detection & zoom** — isolates each call and renders an onset-aligned
  close-up.
- **Species ID** — an on-device classifier names the species, with runner-up and
  confidence.
- **Listening** — two live modes: heterodyne tunes the ultrasound down to
  something audible, and slow replay captures a short snippet of a call and
  replays it at a fraction of speed (going deaf while it does). Recordings can
  also be played back slowed for time expansion.
- **Sessions & map** — every outing is logged automatically, with each pass mapped where it was heard.
- **Sun clock** — bats are busiest in the hours after sunset and before sunrise,
  so the detector screen always shows where in that night you are: time to
  sunset, then time since it, then the coming sunrise. Computed on-device from
  your latitude, so it works with no signal.
- **Offline review** — tap any recording in a session to open it in the WAV
  player: a static zoomable spectrogram, per-call measurements, and the
  per-pulse IDs behind the species it was given.
- **Species field guide** — a community-maintained species reference built into
  the app, covering morphology, echolocation, conservation status and habits.
- **Simplified view** — the default: species, level and spectrogram, and little
  else. One switch in Settings adds every measurement and control back, and
  nothing you've adjusted is lost either way.

## Requirements

- iPhone running **iOS 18** or later.
- A **compatible ultrasonic USB microphone**. The app is developed against the
  Griff (384 kHz sample rate, 192 kHz Nyquist).
- A USB-C connection to the phone.

## Getting started

Connect the microphone, tap the round button beside the tab bar, and point it at
the sky. Detected passes are logged with their species, confidence, and a
spectrogram of the pulses. Every outing is saved as a session, mapped where each
pass was heard. Tapping that button again during a run opens the session
controls — recording, listening mode, and ending the session.

No microphone to hand? The app bundles a demo clip and can run against it, which
also makes it usable in the simulator.

## Privacy

- **Recordings stay on your device.** Nothing leaves the phone unless you
  choose to contribute it, and you are asked first, every time. Identification
  runs entirely on device.
- **Location** is used to tag detections, to suggest the right species model for
  where you are, to name a session after the place it happened, and to work out
  your local sunset and sunrise for the detector's sun clock. These are
  occasional one-shot fixes — the app never tracks you continuously, never asks
  for "Always" access, and does not use location in the background.
- **No GPS tracks.** Sessions used to record a continuous course. That was
  removed: each detection already carries a coordinate and a timestamp, so a
  track can be rebuilt from exported data by any GIS tool without the app
  keeping a second, denser record of your movements.
- **Species ranges are decided on device**, from range data that ships with the
  app. Earlier versions asked GBIF, at your location, which species occurred
  nearby; that network lookup is gone.

## What the classifier can't do

Species ID is a suggestion, not a record — treat it the way you'd treat a
knowledgeable friend's guess, not a verified identification.

- **Confidence is per-model, not comparable across models.** BatDetect2 and
  NABat ML have very different score distributions (see `ModelRegistry.swift`
  and `Context.md` §9), so a "70%" from one doesn't mean the same thing as a
  "70%" from the other.
- **Some species pairs are routinely confused, and the app says so.** Each
  model's descriptor lists its known confusable groups — UK Myotis species,
  common vs. soprano pipistrelle, Leisler's vs. noctule, brown vs. grey
  long-eared, and several North American low-frequency and Myotis species —
  and a runner-up within that group is flagged as an active ambiguity rather
  than a confident call. See each species' page in-app for the specific note.
- **Coverage is regional, not global.** BatDetect2 covers 17 UK species;
  NABat ML covers North America. Outside those regions — or for a species
  neither model was trained on — the app has nothing to say, and won't
  pretend otherwise.
- **Headline accuracy hides per-species variance.** NABat ML's own published
  figures put overall accuracy around 92%, but that number is pulled down
  hardest by cryptic groups, Myotis especially — the acoustic ID is genuinely
  harder for those species, not just a model weakness.

## Species field guide

The app downloads and displays the field guide — a single community-editable
JSON file — in its Species section. **The data and the guide to contributing to
it live in [OpenBat-FieldGuide](https://github.com/NiallxD/OpenBat-FieldGuide),
including the schema, an example entry, and the versioning rules.** Open PRs
against that repo, not this one. Adding or editing a species needs no app code
change, and merged changes reach every install without an app update.

## Building

Open `OpenBat.xcodeproj` in Xcode and build the `OpenBat` scheme. There are no
package dependencies to fetch. Two Core ML models (`BatDetect2`, `NABatML`) are
bundled in `OpenBat/Classifier/`.

Note that `OpenBat/OpenBat/` is a synchronized folder group: **any `.swift` file
placed inside it is compiled into the app**, with no project-file edit required.

The two bundled models carry different licences: **NABat ML** is CC BY 4.0;
**BatDetect2** is **CC BY-NC 4.0 — non-commercial use only**. See
[THIRD-PARTY.md](./THIRD-PARTY.md) for the full terms and citations.

## Repo layout

```
OpenBat/          the app source, by subsystem (Audio, DSP, Classifier,
                  Spectrogram, FieldGuide, WavPlayer, Consent, Upload, …)
OpenBatWidget/    widget / Live Activity extension
OpenBatTests/     unit tests
backend/          Cloudflare Worker for consent records and uploads
tools/            offline scripts; not part of the app target
Context.md        why the app is built the way it is — decisions, measurements,
                  and approaches that were tried and rejected
```

## Licence

This repo is **source-available for transparency, not open source** — it exists
so anyone can read, inspect, and understand how the app works. See
[LICENSE](./LICENSE) for what that does and doesn't permit. The field guide data
is a separate repo with its own terms.
