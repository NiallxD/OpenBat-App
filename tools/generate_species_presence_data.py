#!/usr/bin/env python3
"""
generate_species_presence_data.py

Builds SpeciesPresenceData.json — a coarse, offline "where does this bat live"
map for every species the app's classifiers can name, used to decide which
species are plausible at the user's location without asking the network
anything.

WHY THIS EXISTS, AND WHY IT IS NOT generate_species_range_data.py
-----------------------------------------------------------------
That script builds the dot map on the species detail page: up to 500 raw
sightings per species, remote-only, cosmetic if missing. This one answers a
question the app has to get right, offline, on first launch — so it differs on
every axis that matters:

  * driven by the CLASSIFIERS' species lists, not the field guide's. The guide
    describes 19 species; the models name 47. Generating from the guide leaves
    the ID engine with no opinion about 29 of them.
  * taxonomy resolved ONCE, here, by taxon key, with the result printed for a
    human to check — see the alias table below for why that is not optional.
  * sightings binned into presence cells rather than kept as points. A sample of
    dots measures where recorders went; a filled cell grid is a usable answer to
    "is this bat here", and is small enough to ship inside the app.

THE ALIAS TABLE IS THE POINT
----------------------------
Querying GBIF by scientific name is fragile in BOTH directions, and the app is
currently wrong in both:

  * app's name older than GBIF's — "Lasiurus blossevillii" returns 0 records
    near San Francisco because western red bat records now sit under
    "Lasiurus frantzii" (90 nearby). A resident species gets switched off.
  * app's name newer than GBIF's — "Cnephaeus serotinus" does not resolve to a
    species at all. GBIF matches it to the GENUS Cnephaeus (a synonym of
    Eptesicus), so the serotine returns 0 records near London and gets switched
    off in southern England, while a naive range build would have covered every
    Eptesicus on earth.

So each code resolves to an explicit list of taxon keys whose occurrences are
UNIONED, and every resolution is verified to be rank=SPECIES before it is used.
A HIGHERRANK match is a hard error, not a warning: it silently produces a
genus-wide blob that looks like a plausible range.

Usage:
    python3 generate_species_presence_data.py [--dry-run] [--only CODE,CODE]

--dry-run resolves taxonomy and prints the report without fetching occurrences,
which is the cheap way to check the alias table after adding a model.
"""

import argparse
import json
import math
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import mvt_lite
import presence_algorithms

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent / "OpenBat"
CLASSIFIER_SOURCES = [
    APP / "Classifier" / "BatClassifier.swift",
    APP / "Classifier" / "BatDetect2Classifier.swift",
]
OUTPUT_PATH = ROOT / "SpeciesPresenceData.json"

# Field guide JSON, for the guide-only codes step in main(). Tried in order:
# the sibling FieldGuide repo clone first (freshest — what you have checked
# out if you're actively editing guide content), then the copy bundled in
# this app repo, which every checkout has but can lag behind (see
# CLAUDE.md's "Bundled seed data" note). Neither path is required to exist —
# see `load_guide_codes`.
GUIDE_PATHS = [
    ROOT.parent.parent / "FieldGuide" / "SpeciesGuideData.json",
    APP / "FieldGuide" / "SpeciesGuideData.json",
]

MATCH_URL = "https://api.gbif.org/v1/species/match"
SPECIES_URL = "https://api.gbif.org/v1/species"
# GBIF's density endpoint returns occurrences already aggregated into bins,
# server-side, over EVERY record — not a sample. See DENSITY_SQUARE_SIZE.
DENSITY_URL = "https://api.gbif.org/v2/map/occurrence/density/0/0/0.mvt"
REQUEST_TIMEOUT = 30
REQUEST_DELAY_SECONDS = 0.2

# Bin size in tile pixels at zoom 0. Measured against real tiles: 64 gives ~5.6
# degree bins, 32 ~2.8, 16 ~1.4, 8 ~0.7. Eight is the finest offered and lands
# comfortably below CELL_DEGREES, so several bins fall inside each presence cell
# rather than one bin straddling four.
DENSITY_SQUARE_SIZE = 8

# WHY TILES RATHER THAN PAGING THROUGH RECORDS
# The first version of this script paged /occurrence/search for up to 4000
# records per taxon. That was slow (GBIF's deep offsets take ~10 s a page, about
# an hour for the full species list) and, worse, it sampled: GBIF guarantees no
# ordering, so "the first 4000" can be dominated by one large national dataset
# and leave real parts of a range looking empty. The density endpoint aggregates
# every record — all 3.2 million for the common pipistrelle — into one ~2 KB
# response in well under a second. Same source, no sample, ~50x fewer requests.
#
# What it costs: the tiles carry no dates. `month=` is accepted and SILENTLY
# IGNORED (January and July return byte-identical tiles), so per-cell seasonality
# is not available this way. The months field is still written, as zero meaning
# "no seasonal information" — SpeciesPresenceStore treats a zero mask as "no
# opinion" and lets the species through, rather than hiding a resident bat
# because its records lacked dates.

# Degrees per presence cell. 1.0 deg is ~111 km north-south — deliberately
# coarse. The question being answered is "does this species live around here",
# not "was one caught in this field", and a coarse cell is both smaller to ship
# and less sensitive to where recorders happened to walk. Finer resolutions
# mostly encode survey effort.
CELL_DEGREES = 1.0

# THE FILTER CHAIN LIVES IN presence_algorithms NOW
# ---------------------------------------------------
# What used to sit here — DILATE_CELLS, MIN_CELL_RECORDS, MIN_COMPONENT_RECORDS,
# NEARBY_CLUSTER_KM and the four functions they drove — filtered raw cells by
# RECORD COUNT and only then buffered the survivors. Measured against the data
# in August 2026, that order was deleting real range at exactly the edges a
# detector user stands in:
#
#   * The spotted bat's run north into BC is four cells holding 1, 1, 2 and 3
#     records, one empty row from the cells at 47N. Judged before buffering they
#     touch nothing that clears the floor, so the shipped range stopped dead on
#     the 49th parallel.
#   * The Hawaiian hoary bat is seven cells holding 18 records against a
#     disconnected-cluster floor of 20. An entire island population was missing
#     by two records.
#
# Recording effort is thinnest where a range ends, so a per-cell record floor
# reads survey intensity as absence. presence_algorithms buffers and bridges
# FIRST and judges connected groups afterwards, which lets a thin edge inherit
# the credibility of the mass it attaches to. Its module docstring carries the
# measurements and the reasoning, including why a group is judged on cell count
# OR record count and never both.
#
# The species-level floor below stays here: it asks about the SPECIES ("do we
# know enough to hold any opinion at all"), not about a cell.

# Below this, a species' cells are too sparse to be a range rather than a
# scatter, and the app is told to hold no opinion (see "unknown" in the output)
# instead of inventing a boundary from a handful of dots.
MIN_RECORDS_FOR_PRESENCE = 50

SCHEMA_VERSION = 1
# Bump on every regeneration intended to ship.
DATA_VERSION = 4

# Extra taxon names to union into a code's range, beyond the scientific name the
# model itself uses. Every entry needs a reason: this table is the difference
# between a correct range and a confidently wrong one, and an unexplained line
# here is indistinguishable from a typo.
#
# Keyed by the app's own species code so it survives the app renaming a species.
TAXON_ALIASES: dict[str, list[str]] = {
    # Western red bat. The blossevillii complex was split; western North
    # American records — the population NABat's LABL class actually covers —
    # are filed under frantzii. Querying only blossevillii returns 0 near San
    # Francisco against 90 for frantzii. Both are unioned because the class
    # spans them.
    "LABL": ["Lasiurus blossevillii", "Lasiurus frantzii"],
    # Hoary bat. Moved to Aeorestes by some authorities; GBIF's name filter
    # currently follows the synonym, but pinning both keys means a future
    # tightening of that behaviour can't silently empty the range.
    "LACI": ["Lasiurus cinereus", "Aeorestes cinereus"],
    # Northern yellow bat, same story under Dasypterus.
    "LAIN": ["Lasiurus intermedius", "Dasypterus intermedius"],
    # Serotine. The app uses the newer Cnephaeus combination; GBIF has no
    # species under that name and matches it to the GENUS Cnephaeus, so the
    # app's own lookups return 0 everywhere and a naive build would cover all
    # of Eptesicus. Eptesicus serotinus is the name carrying the 180k records.
    "CNESER": ["Eptesicus serotinus", "Cnephaeus serotinus"],
}


def fetch_json(url: str, params: dict | None = None) -> dict:
    full = url if params is None else f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(
        full, headers={"User-Agent": "OpenBat-PresenceGenerator/1.0"}
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
        return json.load(response)


def parse_scientific_names(path: Path) -> dict[str, str]:
    """Pull `code: "Genus species"` pairs out of a Swift dictionary literal.

    Read from the source rather than copied here on purpose: those tables are
    the app's authority for what each model can name, and a duplicate would be a
    third list to keep in sync — precisely what SpeciesGuideLookup's join-on-
    scientific-name design exists to avoid.
    """
    text = path.read_text()
    start = text.find("static let scientificNames")
    if start == -1:
        return {}
    # Open at the literal's `= [`, not the first `[` after the name — that one
    # belongs to the `[String: String]` type annotation.
    opening = text.find("= [", start)
    if opening == -1:
        return {}
    end = text.find("\n    ]", opening)
    body = text[opening:end if end != -1 else len(text)]
    return dict(re.findall(r'"([A-Z]+)"\s*:\s*"([^"]+)"', body))


def load_guide_codes() -> dict[str, str]:
    """key -> scientificName for every field guide entry.

    The key is the entry's `id` slug ("myotis-nattereri"), NOT a classifier
    code — the guide no longer carries a `code` field. It used to: a
    contributor was asked to mint one for any species no bundled model names,
    and an entry that didn't got no range map at all. That was an unanswerable
    question (a classifier code is a fact about our models, not about the bat)
    and it scaled badly — the guide is heading for ~1500 species against the
    models' 47, and hand-minted codes collide (*Myotis nattereri* and
    *M. natalensis* both want MYONAT).

    Entries a model DOES name are skipped by the caller, since the classifier
    tables already supply those under the model's own code — which they must,
    because detections are stored, GUANO-tagged and exported under it.
    Everything else keys on its slug, which is already unique and already the
    guide's stable identity. Matches `GuideSpecies.presenceCode` in the app.

    Purely additive — see the caller in `main()`. Returns {} with a printed
    warning if no guide JSON is found at either `GUIDE_PATHS` entry, rather
    than failing the run: this step is a bonus on top of the classifier
    tables, not a dependency of it.
    """
    for path in GUIDE_PATHS:
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            print(f"warning: couldn't read guide JSON at {path}: {exc}", file=sys.stderr)
            continue
        print(f"reading guide-only codes from {path}")
        return {
            entry["id"]: entry["scientificName"]
            for entry in data.get("species", [])
            if entry.get("id") and entry.get("scientificName")
        }
    checked = ", ".join(str(p) for p in GUIDE_PATHS)
    print(f"warning: no field guide JSON found (checked {checked}) — "
          "guide-only codes skipped", file=sys.stderr)
    return {}


def resolve_species_key(name: str) -> tuple[int | None, str]:
    """Resolve a scientific name to a GBIF key that is genuinely a SPECIES.

    Returns (key, note). A HIGHERRANK match resolves to None: GBIF answering
    with a genus is not a near miss, it is a different question, and building a
    range from it produces a plausible-looking blob covering every species in
    that genus.
    """
    match = fetch_json(MATCH_URL, {"name": name})
    match_type = match.get("matchType")
    key = match.get("usageKey")
    if match_type == "NONE" or key is None:
        return None, "no GBIF match"
    if match_type == "HIGHERRANK":
        return None, f"matched only at higher rank ({match.get('rank')})"

    time.sleep(REQUEST_DELAY_SECONDS)
    detail = fetch_json(f"{SPECIES_URL}/{key}")
    rank = detail.get("rank")
    if rank != "SPECIES":
        return None, f"resolved to rank {rank}, not SPECIES"

    accepted = detail.get("accepted")
    status = detail.get("taxonomicStatus")
    note = f"{detail.get('scientificName')} ({status})"
    if accepted:
        note += f" -> accepted as {accepted}"
    return key, note


def fetch_density_cells(taxon_key: int) -> tuple[dict[int, int], int]:
    """One taxon's whole global distribution as (cell index -> record count).

    A single request. The response is every record GBIF holds for the taxon,
    aggregated into ~0.7 degree bins server-side, which are then accumulated into
    this script's presence cells.
    """
    query = urllib.parse.urlencode({
        "taxonKey": taxon_key,
        "bin": "square",
        "squareSize": DENSITY_SQUARE_SIZE,
    })
    request = urllib.request.Request(
        f"{DENSITY_URL}?{query}",
        headers={"User-Agent": "OpenBat-PresenceGenerator/1.0"},
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
        payload = response.read()

    cells: dict[int, int] = {}
    total = 0
    for lat, lon, count in mvt_lite.tile_bins(payload):
        index = cell_index(lat, lon)
        cells[index] = cells.get(index, 0) + count
        total += count
    return cells, total






def grid_dimensions() -> tuple[int, int]:
    return int(round(180 / CELL_DEGREES)), int(round(360 / CELL_DEGREES))


def cell_index(lat: float, lon: float) -> int:
    """Row-major index of the cell containing (lat, lon).

    Latitude row 0 is the south pole, longitude column 0 is -180, so the index
    is a single non-negative integer the app can decode back into a bounding box
    with two divisions. Values are clamped rather than wrapped: GBIF occasionally
    emits exactly 90.0 or 180.0, which would otherwise land one row past the end.
    """
    rows, cols = grid_dimensions()
    row = min(rows - 1, max(0, int((lat + 90) / CELL_DEGREES)))
    col = min(cols - 1, max(0, int((lon + 180) / CELL_DEGREES)))
    return row * cols + col



def density_breaks(counts: list[int]) -> list[int]:
    """Three record-count cut points splitting a species' cells into four tiers.

    Computed here, once, and shipped — rather than in the app — so the shading
    on the phone and the shading on the diagnostic maps cannot drift apart, and
    so a device never has to sort a species' cells to draw a map.

    PER SPECIES, never global. Per-cell counts differ by five orders of
    magnitude between species: the spotted bat's densest cell holds 10 records,
    the common pipistrelle's holds 187,356. One shared scale renders every
    sparse species as a single flat tone, which loses exactly the core-vs-edge
    structure the tiers exist to show.

    Quartiles by preference — they spread the four tones evenly over the cells,
    so the map shows structure rather than one dark dot in a pale field.

    Every break must sit STRICTLY ABOVE the smallest count. About a quarter of
    all cells hold exactly one record, so the lower quartiles tie at the
    minimum; a break equal to it leaves the palest tier matching nothing, and
    the map then draws four tiers' worth of data in three tones. Where the
    quartiles collapse that way, log-spaced cuts are used instead: they divide
    the RANGE rather than the cells, so they cannot tie.
    """
    if not counts:
        return []
    ordered = sorted(counts)
    smallest = ordered[0]

    def quantile(fraction: float) -> float:
        # Linear interpolation between order statistics, matching numpy's
        # default so the shipped breaks equal the ones the maps were tuned on.
        if len(ordered) == 1:
            return float(ordered[0])
        position = fraction * (len(ordered) - 1)
        low = int(math.floor(position))
        high = min(low + 1, len(ordered) - 1)
        return ordered[low] + (ordered[high] - ordered[low]) * (position - low)

    quartiles = sorted({math.ceil(quantile(f)) for f in (0.25, 0.50, 0.75)})
    quartiles = [b for b in quartiles if b > smallest]
    if len(quartiles) == 3:
        return quartiles

    low = math.log10(max(smallest, 1))
    high = math.log10(max(ordered[-1], smallest + 1))
    spaced = sorted({math.ceil(10 ** (low + (high - low) * f))
                     for f in (0.25, 0.50, 0.75)})
    return [b for b in spaced if b > smallest]


def delta_encode(indices: list[int]) -> list[int]:
    """Sorted absolute indices -> first value plus gaps.

    Occupied cells cluster, so the gaps are overwhelmingly small integers and
    this roughly halves the file against absolute indices. The app re-accumulates
    on load.
    """
    encoded = []
    previous = 0
    for index in indices:
        encoded.append(index - previous)
        previous = index
    return encoded


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true",
                        help="resolve taxonomy and report, fetch nothing")
    parser.add_argument("--only", help="comma-separated species codes")
    args = parser.parse_args()

    wanted = {c.strip().upper() for c in args.only.split(",")} if args.only else None

    # code -> scientific name, across every model. A code naming the same bat in
    # two models is the same range; the union is taken once.
    codes: dict[str, str] = {}
    for source in CLASSIFIER_SOURCES:
        if not source.exists():
            print(f"error: {source} not found", file=sys.stderr)
            return 1
        names = parse_scientific_names(source)
        if not names:
            print(f"error: no scientificNames table in {source.name}", file=sys.stderr)
            return 1
        # Codes are unique within a model but not reserved across models (see
        # SpeciesGuideLookup's note). Today's two models use 4- and 6-letter
        # codes and cannot collide, but a third model reusing a code for a
        # different bat would otherwise silently overwrite one range with the
        # other's — a wrong answer that looks like a right one.
        for code, scientific in names.items():
            existing = codes.get(code)
            if existing is not None and existing != scientific:
                print(f"error: code {code} means {existing!r} in one model and "
                      f"{scientific!r} in {source.name}. Presence data is keyed by "
                      f"code, so this must be resolved before generating.",
                      file=sys.stderr)
                return 1
        codes.update(names)

    # The classifier tables above are unconditional and always win: every
    # model-named species gets presence data regardless of what the guide
    # says or whether it says anything at all — see this file's module
    # doc comment for why that independence matters. This step only ADDS
    # codes for species no model names, from field guide entries that have
    # set their own `code` field (a species with no ID model can still get
    # a code assigned by a contributor purely so it can appear on the
    # distribution map / "bats near you" — see the field guide README).
    #
    # A guide code that collides with a classifier's is the same class of
    # error as two classifiers disagreeing, and fails the run the same way —
    # a silently wrong scientific name behind a code is worse than a
    # generation run that has to be fixed and re-run.
    # Guide entries a model already names are dropped here rather than added
    # under their slug: the app resolves those through the model's code (see
    # `GuideSpecies.presenceCode`), so a slug-keyed duplicate would be dead
    # weight in the file and a second range for the same bat to keep in sync.
    guide_codes = load_guide_codes()
    named_by_model = {name.strip().lower() for name in codes.values()}
    guide_only_count = 0
    for slug, scientific in guide_codes.items():
        if scientific.strip().lower() in named_by_model:
            continue
        if slug in codes:
            # A slug colliding with a classifier code needs a human: one of the
            # two has to give, and guessing which would silently file one
            # species' range under another's key.
            print(f"error: guide slug {slug!r} ({scientific}) collides with a "
                  f"classifier code meaning {codes[slug]!r}.", file=sys.stderr)
            return 1
        codes[slug] = scientific
        guide_only_count += 1

    if wanted:
        codes = {c: n for c, n in codes.items() if c in wanted}

    print(f"{len(codes)} species codes across {len(CLASSIFIER_SOURCES)} models "
          f"({guide_only_count} guide-only, no ID model)")
    print(f"cell size {CELL_DEGREES} deg, "
          f"density bins {DENSITY_SQUARE_SIZE} px, "
          f"species floor {MIN_RECORDS_FOR_PRESENCE} records\n"
          f"buffer {presence_algorithms.BUFFER_CELLS} cell, "
          f"bridge {presence_algorithms.BRIDGE_CELLS} cells, "
          f"group needs {presence_algorithms.MIN_GROUP_CELLS} observation cells "
          f"or {presence_algorithms.MIN_GROUP_RECORDS} records\n")

    presence: dict[str, dict] = {}
    unknown: list[str] = []
    failures: list[str] = []

    for code in sorted(codes):
        primary = codes[code]
        names = TAXON_ALIASES.get(code, [primary])
        if primary not in names:
            names = [primary] + names
        print(f"{code}  {primary}")

        keys: list[int] = []
        for name in names:
            try:
                key, note = resolve_species_key(name)
            except Exception as exc:
                print(f"    ! {name}: lookup failed: {exc}", file=sys.stderr)
                failures.append(f"{code} ({name}): {exc}")
                continue
            time.sleep(REQUEST_DELAY_SECONDS)
            if key is None:
                # Expected for the deliberately-included bad name in an alias
                # pair (Cnephaeus serotinus); a problem only if nothing resolves.
                print(f"    - {name}: {note}")
                continue
            print(f"    + {name}: key {key} — {note}")
            keys.append(key)

        if not keys:
            print("    ! no usable taxon key — species will carry no range\n")
            unknown.append(code)
            continue

        if args.dry_run:
            print()
            continue

        merged: dict[int, int] = {}
        total = 0
        for key in keys:
            try:
                cells, count = fetch_density_cells(key)
            except Exception as exc:
                print(f"    ! density fetch failed for {key}: {exc}", file=sys.stderr)
                failures.append(f"{code} (key {key}): {exc}")
                continue
            for index, records in cells.items():
                merged[index] = merged.get(index, 0) + records
            total += count
            time.sleep(REQUEST_DELAY_SECONDS)

        if total < MIN_RECORDS_FOR_PRESENCE:
            print(f"    ! only {total} records — too sparse, no opinion recorded\n")
            unknown.append(code)
            continue

        built = presence_algorithms.build_presence(merged)
        if not built["kept"]:
            print("    ! no group survived — no opinion recorded\n")
            unknown.append(code)
            continue

        ordered = sorted(built["kept"])
        # Only the OBSERVED cells carry record counts. The rest of the range is
        # buffer and bridge — inferred from what surrounds it, with nobody
        # having recorded a bat there — and the app draws that distinction
        # rather than filling the whole range one flat colour, which would
        # assert a uniform population it has no evidence for.
        observed = sorted(i for i in built["kept"] if i in merged)
        counts = [merged[i] for i in observed]
        presence[code] = {
            "cells": delta_encode(ordered),
            # Zero throughout: the density tiles carry no dates. Kept in the
            # format so seasonality can arrive without a schema break.
            "months": [0] * len(ordered),
            "records": total,
            "taxonKeys": keys,
            "observed": delta_encode(observed),
            "counts": counts,
            "breaks": density_breaks(counts),
        }
        dropped_groups = [g for g in built["groups"] if not g["kept"]]
        dropped = sum(g["seed_cells"] for g in dropped_groups)
        print(f"    -> {total:,} records, {len(merged):,} observed cells, "
              f"{len(built['groups']) - len(dropped_groups)}/{len(built['groups'])} "
              f"groups kept ({dropped} observation cells dropped), "
              f"{len(ordered):,} cells in the modelled range\n")

    if args.dry_run:
        print("--- dry run, nothing written ---")
    else:
        output = {
            "schemaVersion": SCHEMA_VERSION,
            "dataVersion": DATA_VERSION,
            "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "cellDegrees": CELL_DEGREES,
            # The shape of the range the app draws, so a reader of the file
            # can tell how much of it is inferred without rerunning anything.
            "buffer": presence_algorithms.BUFFER_CELLS,
            "bridge": presence_algorithms.BRIDGE_CELLS,
            # Codes the app must treat as "no information" rather than absent —
            # the distinction the live GBIF path never made, and the whole reason
            # a Tennessee cave bat could read as a full-confidence San Francisco
            # candidate.
            "unknown": sorted(unknown),
            "presence": presence,
        }
        OUTPUT_PATH.write_text(json.dumps(output, separators=(",", ":"), sort_keys=True))
        size_kb = OUTPUT_PATH.stat().st_size / 1024
        print(f"wrote {OUTPUT_PATH.name}: {len(presence)} species with ranges, "
              f"{len(unknown)} unknown, {size_kb:,.0f} KB")

    if failures:
        print(f"\n{len(failures)} failures:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        # A partial file is how the live path went wrong in the first place.
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
