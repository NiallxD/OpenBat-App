#!/usr/bin/env python3
"""
generate_species_range_data.py

Builds SpeciesRangeData.json — a bundled/committed snapshot of each field-guide
species' GBIF occurrence points, so the distribution map on the species detail
page works offline and loads instantly instead of hitting GBIF live.

Reads species from SpeciesGuideData.json (scientificName field), resolves each
to a GBIF taxon key via /v1/species/match, then pages through
/v1/occurrence/search (hasCoordinate=true) collecting up to MAX_RECORDS raw
lat/lon points per species — the same shape and cap GBIFService.swift already
uses for its live on-device fetch/cache, so the app-side store can consume this
file with no format translation.

Usage:
    python3 generate_species_range_data.py

Run manually whenever you want to refresh range data (new species added to the
guide, or just to pick up newer GBIF occurrence records). Commit the output
JSON alongside SpeciesGuideData.json. Bump DATA_VERSION when you do.
"""

import json
import sys
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
GUIDE_PATH = ROOT / "SpeciesGuideData.json"
OUTPUT_PATH = ROOT / "SpeciesRangeData.json"

MATCH_URL = "https://api.gbif.org/v1/species/match"
OCCURRENCE_SEARCH_URL = "https://api.gbif.org/v1/occurrence/search"
PAGE_SIZE = 300
# Kept well below GBIFService's live-fetch cap (3000) — this file has to scale
# to ~1500 species, and a coarse distribution map only ever renders these
# binned into a few hundred H3 hexagons, so most of a larger sample would just
# collapse into the same bins anyway.
MAX_RECORDS = 500
REQUEST_TIMEOUT = 20
REQUEST_DELAY_SECONDS = 0.2  # be polite to GBIF's public API
# ~111m at the equator — far finer than meaningful at range-map scale, but
# cuts JSON size substantially versus full float precision.
COORDINATE_DECIMAL_PLACES = 3

SCHEMA_VERSION = 1
# Bump manually on every regeneration you intend to ship.
DATA_VERSION = 2


def fetch_json(url: str, params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    full_url = f"{url}?{query}"
    request = urllib.request.Request(full_url, headers={"User-Agent": "OpenBat-RangeGenerator/1.0"})
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
        return json.load(response)


def resolve_taxon_key(scientific_name: str) -> int | None:
    data = fetch_json(MATCH_URL, {"name": scientific_name})
    if data.get("matchType") == "NONE":
        return None
    return data.get("usageKey")


def fetch_occurrence_points(taxon_key: int) -> list[list[float]]:
    # [lat, lon] pairs rather than {"lat":...,"lon":...} objects — saves the
    # repeated key names, which dominate a compact JSON point's byte count
    # once coordinates are rounded down to a few digits. Swift-side decode
    # (SpeciesRangeStore.CompactPoint) expects exactly this shape.
    points = []
    offset = 0
    while offset < MAX_RECORDS:
        data = fetch_json(OCCURRENCE_SEARCH_URL, {
            "taxonKey": taxon_key,
            "hasCoordinate": "true",
            "limit": PAGE_SIZE,
            "offset": offset,
        })
        results = data.get("results", [])
        for record in results:
            lat = record.get("decimalLatitude")
            lon = record.get("decimalLongitude")
            if lat is None or lon is None:
                continue
            points.append([
                round(lat, COORDINATE_DECIMAL_PLACES),
                round(lon, COORDINATE_DECIMAL_PLACES),
            ])
        offset += PAGE_SIZE
        time.sleep(REQUEST_DELAY_SECONDS)
        if data.get("endOfRecords") or not results:
            break
    return points


def main() -> int:
    if not GUIDE_PATH.exists():
        print(f"error: {GUIDE_PATH} not found", file=sys.stderr)
        return 1

    guide = json.loads(GUIDE_PATH.read_text())
    species_list = guide.get("species", [])
    if not species_list:
        print("error: no species found in SpeciesGuideData.json", file=sys.stderr)
        return 1

    ranges: dict[str, list[list[float]]] = {}

    for entry in species_list:
        scientific_name = entry.get("scientificName")
        if not scientific_name:
            continue
        print(f"Resolving {scientific_name}...")
        try:
            taxon_key = resolve_taxon_key(scientific_name)
        except Exception as exc:
            print(f"  ! failed to resolve taxon key: {exc}", file=sys.stderr)
            continue
        if taxon_key is None:
            print("  ! no GBIF match, skipping")
            continue

        try:
            points = fetch_occurrence_points(taxon_key)
        except Exception as exc:
            print(f"  ! failed to fetch occurrence points: {exc}", file=sys.stderr)
            continue

        print(f"  -> {len(points)} points (taxonKey {taxon_key})")
        if points:
            ranges[scientific_name] = points

    output = {
        "schemaVersion": SCHEMA_VERSION,
        "dataVersion": DATA_VERSION,
        "updatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "ranges": ranges,
    }

    # Compact, unindented separators — pretty-printing roughly doubled file
    # size for no benefit (nobody hand-reads this file; the generator script
    # and SpeciesGuideData.json are the human-editable sources of truth).
    OUTPUT_PATH.write_text(json.dumps(output, separators=(",", ":"), sort_keys=True))
    print(f"\nWrote {OUTPUT_PATH} ({len(ranges)} species)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
