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

- **Real-time spectrogram** — high-resolution frequency-vs-time display with
  drag-to-scroll history.
- **Pulse detection & zoom** — isolates each call and renders an onset-aligned
  close-up.
- **Species ID** — an on-device classifier names the species, with runner-up and
  confidence.
- **Listening** — heterodyne tunes the ultrasound down to something audible
  live; recordings can be played back slowed for time expansion.
- **Sessions & map** — log passes with a GPS track and see where each was heard.
- **Offline review** — open a recording in the WAV player for a static zoomable
  spectrogram and per-call measurements.
- **Species field guide** — a community-maintained species reference built into
  the app, covering morphology, echolocation, conservation status and habits.

## Requirements

- iPhone running **iOS 18** or later.
- A **compatible ultrasonic USB microphone**. The app is developed against the
  Griff (384 kHz sample rate, 192 kHz Nyquist).
- A USB-C connection to the phone.

## Getting started

Connect the microphone, press Start, and point it at the sky. Detected passes
are logged with their species, confidence, and a spectrogram of the pulses.
Start a Session to also record a GPS track and map where each pass was heard.

No microphone to hand? The app bundles a demo clip and can run against it, which
also makes it usable in the simulator.

## Privacy

- **Recordings stay on your device.** They are yours; nothing is uploaded in the
  background, and identification never leaves the phone.
- **Location** is used to tag recordings, to suggest the right species model for
  where you are, and — during a Session — to record the session's GPS track. An
  approximate location is also sent to GBIF to look up which species occur near
  you; nothing identifying goes with it.

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

## Repo layout

```
OpenBat/          the app source, by subsystem (Audio, DSP, Classifier,
                  Spectrogram, FieldGuide, WavPlayer, Consent, Upload, …)
OpenBatWiget/     widget / Live Activity extension
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
