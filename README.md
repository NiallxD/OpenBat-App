# OpenBat

OpenBat is an iOS app that turns a compatible ultrasonic USB microphone into
a live bat detector. It captures audio at up to 384 kHz, shows a real-time
spectrogram, detects individual echolocation pulses, and — where an openly
available model exists for the region — identifies the species on-device.

## Why

Most tools for identifying bat calls are expensive, proprietary, and hard to
get hold of, which puts the experience out of reach for a lot of people who'd
genuinely enjoy it. Free apps that work with ultrasonic microphones already
exist, but as far as we know, none of them use the open-source machine
learning models that have been trained on bat echolocation calls. By building
that identification directly into the app, OpenBat helps people put a name to
the call they just heard — a small moment of recognition that builds a real
connection with bats, and a bit more respect for them too.

## Features

- **Real-time spectrogram** — high-resolution frequency-vs-time display with
  drag-to-scroll history.
- **Pulse detection & zoom** — isolates each call and renders an
  onset-aligned close-up.
- **Species ID** — an on-device classifier names the species, with
  runner-up and confidence.
- **Heterodyne & time-expansion listening** — hear the ultrasound live,
  tuned down or slowed 10×.
- **Sessions & map** — log passes with a GPS track and see where each was
  heard.
- **Community field guide** — a species reference built into the app,
  covering morphology, echolocation, conservation status and habits (see
  below).

## Getting started

Connect a compatible ultrasonic USB microphone, press Start, and point it at
the sky. Detected passes are logged with their species, confidence, and a
spectrogram of the pulses. Start a Session to also record a GPS track and
map where each pass was heard.

## Species Field Guide

This repo also hosts the **Species Field Guide** data — a single
community-editable JSON file the app downloads and displays in its Species
section. The rest of this README covers how to contribute to that guide.

## Contributing a species or region

The field guide lives entirely in one file: [`SpeciesGuideData.json`](./SpeciesGuideData.json).
No app code changes are needed to add a species, edit an existing entry, or
add a new region — just edit the JSON and open a PR.

1. Fork the repo and edit `SpeciesGuideData.json`.
2. Add your species (or region) following the schema below.
3. **Bump `dataVersion` by 1** and set `updatedAt` to today's date — see
   [Versioning](#versioning). This is required for every content change,
   however small, or the app won't pick it up.
4. Open a PR. Once merged to `main`, every app install picks up the change
   automatically the next time it launches (no app update needed).

### Schema

Top level:

| Field | Type | Notes |
|---|---|---|
| `schemaVersion` | Int | **Don't change this.** See [Versioning](#versioning). |
| `dataVersion` | Int | Bump by 1 on every content edit. |
| `updatedAt` | String (ISO 8601) | e.g. `"2026-07-06T00:00:00Z"`. Set alongside every `dataVersion` bump. |
| `regions` | [Region] | Pins shown on the explorer globe. |
| `species` | [Species] | The field guide entries. |

**Region:**

| Field | Type | Notes |
|---|---|---|
| `id` | String | Stable slug, e.g. `"uk-ireland"`. Referenced by species' `regions` list — don't rename an existing one without updating every species that references it. |
| `name` | String | Display name, e.g. `"UK & Ireland"`. |
| `latitude` / `longitude` | Double | Where the pin sits on the globe. |

**Species:** only `id`, `commonName`, `scientificName`, and `regions` are
required — everything else is optional. Add what you know; leave the rest
out. The app only shows a section if its fields are present, so a sparse
entry just renders a shorter page rather than empty boxes.

| Field | Type | Notes |
|---|---|---|
| `id` | String | Stable slug, e.g. `"pipistrellus-pipistrellus"` (genus-species, lowercase, hyphenated). |
| `commonName` | String | e.g. `"Common Pipistrelle"`. |
| `scientificName` | String | e.g. `"Pipistrellus pipistrellus"`. Genus (for the taxonomy breadcrumb) is parsed from this automatically — don't add a separate genus field. |
| `order` | String? | Taxonomic order, e.g. `"Chiroptera"`. |
| `family` | String? | e.g. `"Vespertilionidae"`. |
| `regions` | [String] | List of region `id`s where this species occurs. |
| `summary` | String? | Short intro paragraph. |
| `measurements` | Object? | `forearmMmRange`, `wingspanCmRange`, `weightGRange` (each `{ "min": Double, "max": Double }`), `color` (free text). |
| `morphology` | Object? | `earType`, `tailType`, `noseType` (free text), `otherFeatures` (array of short strings). |
| `echolocation` | Object? | `callType` (e.g. `"FM"`, `"CF-FM"`), `peakFreqHzRange` (Pf), `characteristicFreqHzRange` (Cf/knee), `freqHighHzRange` (Fhigh), `freqLowHzRange` (Flow), `durationMsRange` — all `{ "min", "max" }` pairs in Hz/ms — plus free-text `notes` and an optional `exemplarImageName` (must match a bundled app image asset; leave unset if you don't have one). |
| `conservation` | Object? | `iucnStatus` (e.g. `"Least Concern"`), `localStatus` (free text, varies by region/authority). |
| `habits` | Object? | `roosting`, `migration`, `feeding`, `reproduction`, `other` — each free text. |
| `references` | [String]? | Citations, rendered verbatim in small type at the foot of the species page. Any format is fine as long as it's readable — e.g. `"Author, A. (Year) Title. Journal, Vol(Issue), pages."` |
| `contributors` | [Contributor]? | Edit history shown via a sheet at the top of the References section. **The first entry is treated as the page's creator; every entry after that is an editor.** Each is `{ "name": String, "date": String (ISO 8601), "note": String? }` — add one entry (with today's date and a short note on what you changed) every time you edit a species you didn't create. |

### Example entry

```json
{
  "id": "myotis-daubentonii",
  "commonName": "Daubenton's Bat",
  "scientificName": "Myotis daubentonii",
  "order": "Chiroptera",
  "family": "Vespertilionidae",
  "regions": ["uk-ireland", "continental-europe"],
  "summary": "A small, agile bat that trawls for insects low over still or slow-moving water, using its large feet and tail membrane.",
  "echolocation": {
    "callType": "FM",
    "peakFreqHzRange": { "min": 45000, "max": 50000 },
    "durationMsRange": { "min": 2.0, "max": 5.0 },
    "notes": "Steep, broadband FM sweep; often confused with other Myotis species without call context."
  },
  "conservation": {
    "iucnStatus": "Least Concern"
  },
  "references": [
    "Jones, G. & Rayner, J.M.V. (1988) Flight performance, foraging tactics and echolocation in free-living Daubenton's bats. Journal of Zoology, 215(1), 113–132."
  ],
  "contributors": [
    { "name": "Jane Doe", "date": "2026-07-01T00:00:00Z", "note": "Created species profile" },
    { "name": "John Smith", "date": "2026-07-06T00:00:00Z", "note": "Added echolocation measurements" }
  ]
}
```

The first `contributors` entry (Jane Doe here) is the creator; anyone else who
later edits the entry appends their own `{ name, date, note }` after it —
don't overwrite or remove earlier entries.

See existing entries in `SpeciesGuideData.json` for more complete, real
examples.

### Versioning

- **`dataVersion`**: bump this by 1 for *any* content change — new species,
  corrected text, a new reference, anything. The app compares this number
  to decide whether to adopt your update; if you forget to bump it, your
  change won't reach anyone's device even after merging.
- **`updatedAt`**: an ISO 8601 timestamp set alongside every `dataVersion`
  bump, shown in the app's guide footer so users can see how fresh the data
  is.
- **`schemaVersion`**: this is *not* a content-versioning field — leave it
  alone. It only changes when the JSON's *structure* changes in a way old
  app versions can't safely read (e.g. renaming or repurposing an existing
  field), and that requires a coordinated app release. Adding a new
  optional field (as most content contributions will) never needs a
  `schemaVersion` bump.

### What not to touch

Please don't rename or remove an existing region `id` or species `id` in
the same PR as unrelated content changes — other entries and, in the case
of species ids, potentially saved user data reference these by string, so a
rename should be its own deliberate PR.
