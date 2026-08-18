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

# A geographically disconnected cluster of cells whose combined records don't
# clear this floor is dropped as one outlier — UNLESS it's within
# NEARBY_CLUSTER_KM of the main cluster, in which case proximity itself is
# taken as the evidence and the record floor doesn't apply. See
# drop_disconnected_outliers. Same reasoning as MIN_CELL_RECORDS for why it's
# an absolute count: a proportional floor would erase real disjunct
# populations of a well-recorded species while doing nothing for a sparse one.
MIN_COMPONENT_RECORDS = 20

# How close a disconnected cluster has to sit to the main range before it's
# treated as part of the same range rather than a separate population. Sized
# to bridge a strait or a stretch of unsurveyed coastline the grid's adjacency
# check missed — the English Channel is ~34 km, the Strait of Gibraltar ~14 km
# — while still rejecting an ocean or a continent: the Bogota misidentification
# that motivated this file sits ~8,000 km from the common pipistrelle's real
# range. Nothing in between those two scales is a case this file has seen yet;
# narrow it if one turns up that should have been rejected.
NEARBY_CLUSTER_KM = 500.0

SCHEMA_VERSION = 1
# Bump on every regeneration intended to ship.
DATA_VERSION = 2

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
    """code -> scientificName for every field guide entry that sets `code`.

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
            entry["code"]: entry["scientificName"]
            for entry in data.get("species", [])
            if entry.get("code")
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


def cell_bounds(component: set[int], cols: int) -> tuple[float, float, float, float]:
    """A component's (south, north, west, east) extent in degrees."""
    lats = [(index // cols) * CELL_DEGREES - 90 for index in component]
    lons = [(index % cols) * CELL_DEGREES - 180 for index in component]
    return min(lats), max(lats) + CELL_DEGREES, min(lons), max(lons) + CELL_DEGREES


def bounds_gap_km(a: tuple[float, float, float, float],
                   b: tuple[float, float, float, float]) -> float:
    """Rough great-circle gap between two bounding boxes; 0 if they overlap.

    A bounding-box gap rather than true nearest-cell distance — cheap (no
    per-cell comparison between two potentially large components) and no less
    right for a yes/no "is this nearby" test, since it can only ever
    UNDERSTATE the true gap between the shapes themselves.
    """
    a_south, a_north, a_west, a_east = a
    b_south, b_north, b_west, b_east = b
    lat_gap_deg = max(0.0, max(a_south, b_south) - min(a_north, b_north))
    lon_gap_deg = max(0.0, max(a_west, b_west) - min(a_east, b_east))
    # Longitude degrees shrink towards the poles; use the latitude nearest the
    # gap (or the shared band, if the boxes already overlap in latitude) so a
    # high-latitude gap isn't overstated in km.
    mean_lat = min(a_north, b_north) if lat_gap_deg == 0 else max(a_south, b_south)
    lat_km = lat_gap_deg * 111.0
    lon_km = lon_gap_deg * 111.0 * math.cos(math.radians(mean_lat))
    return math.hypot(lat_km, lon_km)


def drop_disconnected_outliers(cells: dict[int, int]) -> tuple[dict[int, int], int]:
    """Remove whole clusters of cells that are geographically cut off from the
    species' main range — the failure mode drop_outliers cannot see.

    drop_outliers catches a single misidentified record sitting alone in a sea
    of unoccupied cells: it fails MIN_CELL_RECORDS and touches nothing that
    passes. It does NOT catch a cluster of a few *adjacent* cells that each
    clear MIN_CELL_RECORDS against each other — nine cells of GBIF records for
    the common pipistrelle sit around Bogota, Colombia, a continent away from
    its real Ireland-to-Central-Asia range, and every one of those nine cells
    touches another cell in the same block, so each looks locally fine. What's
    wrong with them is not density, it's distance from everything else, and
    per-cell density cannot see distance.

    So: flood-fill occupied cells into connected components, using the same
    8-neighbour, longitude-wrapping adjacency dilate() uses. The largest
    component is the main range and always survives regardless of its own
    total — a species can be real and still sparse, and dropping its only
    cluster would turn "too sparse" into "silently absent" rather than falling
    through to the unknown list, where the app can say "no opinion" honestly
    instead of a wrong one. Every other component survives if EITHER:

      * it sits within NEARBY_CLUSTER_KM of the main component — close enough
        that it reads as the same range with a survey gap or a strait in the
        middle, not a separate population, so no record count is required, or
      * it doesn't, but its own total record count clears
        MIN_COMPONENT_RECORDS on its own — a real, independently-supported
        disjunct population (an island subspecies, say) rather than a handful
        of stray records.

    A cluster failing both is what the Bogota block is: far away AND thin.
    """
    rows, cols = grid_dimensions()
    unassigned = set(cells)
    components: list[set[int]] = []
    while unassigned:
        start = next(iter(unassigned))
        unassigned.discard(start)
        component = {start}
        stack = [start]
        while stack:
            index = stack.pop()
            row, col = divmod(index, cols)
            for d_row in (-1, 0, 1):
                for d_col in (-1, 0, 1):
                    if d_row == 0 and d_col == 0:
                        continue
                    r = row + d_row
                    if not (0 <= r < rows):
                        continue
                    neighbour = r * cols + ((col + d_col) % cols)
                    if neighbour in unassigned:
                        unassigned.discard(neighbour)
                        component.add(neighbour)
                        stack.append(neighbour)
        components.append(component)

    components.sort(key=lambda component: sum(cells[i] for i in component),
                     reverse=True)
    main = components[0]
    main_bounds = cell_bounds(main, cols)

    kept: dict[int, int] = {}
    dropped = 0
    for n, component in enumerate(components):
        if n == 0:
            survives = True
        elif bounds_gap_km(cell_bounds(component, cols), main_bounds) <= NEARBY_CLUSTER_KM:
            survives = True
        else:
            survives = sum(cells[i] for i in component) >= MIN_COMPONENT_RECORDS
        if survives:
            for index in component:
                kept[index] = cells[index]
        else:
            dropped += len(component)
    return kept, dropped


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
    guide_codes = load_guide_codes()
    guide_only_count = 0
    for code, scientific in guide_codes.items():
        existing = codes.get(code)
        if existing is not None:
            if existing != scientific:
                print(f"error: code {code} means {existing!r} to a classifier and "
                      f"{scientific!r} in the field guide. Fix the guide entry's "
                      f"code or scientificName before generating.", file=sys.stderr)
                return 1
            continue  # guide just confirms a code a model already provides
        codes[code] = scientific
        guide_only_count += 1

    if wanted:
        codes = {c: n for c, n in codes.items() if c in wanted}

    print(f"{len(codes)} species codes across {len(CLASSIFIER_SOURCES)} models "
          f"({guide_only_count} guide-only, no ID model)")
    print(f"cell size {CELL_DEGREES} deg, dilation {DILATE_CELLS}, "
          f"density bins {DENSITY_SQUARE_SIZE} px, "
          f"outlier floor {MIN_CELL_RECORDS} records/cell, "
          f"{MIN_COMPONENT_RECORDS} records/disconnected cluster beyond "
          f"{NEARBY_CLUSTER_KM:.0f} km of the main range\n")

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

        cleaned, disconnected = drop_disconnected_outliers(cleaned)

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
              f"{dropped} isolated outliers dropped, {disconnected} more in "
              f"disconnected clusters, {len(ordered):,} after dilation\n")

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
