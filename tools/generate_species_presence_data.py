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
import re
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

import mvt_lite

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent / "OpenBat"
CLASSIFIER_SOURCES = [
    APP / "Classifier" / "BatClassifier.swift",
    APP / "Classifier" / "BatDetect2Classifier.swift",
]
OUTPUT_PATH = ROOT / "SpeciesPresenceData.json"

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

# A cell with at least one sighting is occupied; DILATE_CELLS then marks its
# immediate neighbours occupied too. This closes the checkerboard holes left by
# uneven recording effort — a bat recorded either side of a county is not
# absent from the middle of it. Set to 0 if ranges start looking implausibly
# generous; that is the first knob to reach for.
DILATE_CELLS = 1

# Below this, a species' cells are too sparse to be a range rather than a
# scatter, and the app is told to hold no opinion (see "unknown" in the output)
# instead of inventing a boundary from a handful of dots.
MIN_RECORDS_FOR_PRESENCE = 50

# A cell holding fewer records than this, and touching no cell that holds more,
# is treated as an error rather than a range edge. See drop_outliers for why
# this is an absolute count and not a percentage.
MIN_CELL_RECORDS = 3

SCHEMA_VERSION = 1
# Bump on every regeneration intended to ship.
DATA_VERSION = 1

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


def drop_outliers(cells: dict[int, int]) -> tuple[dict[int, int], int]:
    """Remove isolated cells holding a handful of records.

    Raw occurrence data contains misidentifications, transposed coordinates and
    specimens catalogued at the museum that holds them rather than where they
    were collected. Unfiltered, the gray bat — a Tennessee and Alabama cave
    species — claims a cell in Alaska on the strength of ONE record out of 283.

    The rule is absolute, not proportional, and deliberately so. A proportional
    threshold scales with how well studied a species is: 0.5% of the common
    pipistrelle's 3.2 million records is 16,000, which would erase most of its
    genuine European range, while 0.5% of the gray bat's 283 is one record,
    which erases nothing. So: a cell survives if it holds at least
    MIN_CELL_RECORDS, or if it touches a cell that does. The second clause is
    what keeps the thin edges of a real range, which is exactly where a bat
    detector user is most likely to be standing and most likely to be doubted.
    """
    rows, cols = grid_dimensions()
    strong = {index for index, count in cells.items() if count >= MIN_CELL_RECORDS}
    kept: dict[int, int] = {}
    for index, count in cells.items():
        if index in strong:
            kept[index] = count
            continue
        row, col = divmod(index, cols)
        touches = False
        for d_row in (-1, 0, 1):
            for d_col in (-1, 0, 1):
                r = row + d_row
                if not (0 <= r < rows):
                    continue
                if r * cols + ((col + d_col) % cols) in strong:
                    touches = True
                    break
            if touches:
                break
        if touches:
            kept[index] = count
    return kept, len(cells) - len(kept)


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


def dilate(cells: dict[int, int], radius: int) -> dict[int, int]:
    """Mark cells adjacent to an occupied cell occupied, inheriting its months.

    Longitude wraps at the antimeridian; latitude does not (there is no cell
    north of the north pole). Without this, unevenly surveyed regions come out
    as a checkerboard and a user standing in an unsurveyed gap is told their
    local bat does not live there.
    """
    if radius <= 0:
        return cells
    rows, cols = grid_dimensions()
    grown = dict(cells)
    for index, months in cells.items():
        row, col = divmod(index, cols)
        for d_row in range(-radius, radius + 1):
            for d_col in range(-radius, radius + 1):
                r = row + d_row
                if not (0 <= r < rows):
                    continue
                c = (col + d_col) % cols
                neighbour = r * cols + c
                grown[neighbour] = grown.get(neighbour, 0) | months
    return grown


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

    if wanted:
        codes = {c: n for c, n in codes.items() if c in wanted}

    print(f"{len(codes)} species codes across {len(CLASSIFIER_SOURCES)} models")
    print(f"cell size {CELL_DEGREES} deg, dilation {DILATE_CELLS}, "
          f"density bins {DENSITY_SQUARE_SIZE} px, "
          f"outlier floor {MIN_CELL_RECORDS} records/cell\n")

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

        cleaned, dropped = drop_outliers(merged)
        if not cleaned:
            print(f"    ! every cell was an isolated outlier — no opinion recorded\n")
            unknown.append(code)
            continue

        grown = dilate({index: 0 for index in cleaned}, DILATE_CELLS)
        ordered = sorted(grown)
        presence[code] = {
            "cells": delta_encode(ordered),
            # Zero throughout: the density tiles carry no dates. Kept in the
            # format so seasonality can arrive without a schema break.
            "months": [0] * len(ordered),
            "records": total,
            "taxonKeys": keys,
        }
        print(f"    -> {total:,} records, {len(merged):,} cells, "
              f"{dropped} outliers dropped, {len(ordered):,} after dilation\n")

    if args.dry_run:
        print("--- dry run, nothing written ---")
    else:
        output = {
            "schemaVersion": SCHEMA_VERSION,
            "dataVersion": DATA_VERSION,
            "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "cellDegrees": CELL_DEGREES,
            "dilation": DILATE_CELLS,
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
