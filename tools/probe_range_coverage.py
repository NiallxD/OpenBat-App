#!/usr/bin/env python3
"""
probe_range_coverage.py

A read-only survey, not a generator. Answers two questions before we commit to
building presence data:

  1. COVERAGE — which species the classifiers can name have usable GBIF range
     data, and which the field guide already covers. The guide shipped in the
     app describes 19 species worldwide; the two models between them name ~47.
     Range data driven off the guide's list therefore leaves the ID engine with
     no opinion about most of what it can say.

  2. TAXONOMY — whether the scientific name the app queries is the name GBIF
     files the records under. This is the LABL failure: the app asks about
     Lasiurus blossevillii, western North American records now sit under
     Lasiurus frantzii, the count comes back near zero, and a resident bat gets
     switched off while an eastern vagrant stays on. GBIF's /species/match
     reports the accepted name for a synonym, so a mismatch here is visible
     without guessing.

Two requests per species (match + a count-only occurrence search), so this is
cheap and safe to re-run. Writes nothing except a report.

Usage:
    python3 probe_range_coverage.py [--json report.json]
"""

import argparse
import json
import re
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
APP = ROOT.parent / "OpenBat"
GUIDE_PATH = APP / "FieldGuide" / "SpeciesGuideData.json"
CLASSIFIER_SOURCES = [
    APP / "Classifier" / "BatClassifier.swift",
    APP / "Classifier" / "BatDetect2Classifier.swift",
]

MATCH_URL = "https://api.gbif.org/v1/species/match"
OCCURRENCE_SEARCH_URL = "https://api.gbif.org/v1/occurrence/search"
REQUEST_TIMEOUT = 20
REQUEST_DELAY_SECONDS = 0.2

# Enough occurrence records to be worth binning into presence cells. Below this
# a species' "range" would be a handful of dots and a lot of empty map, which is
# exactly the sparse-sample problem that makes record counts a bad membership
# test in the first place.
USABLE_RECORD_FLOOR = 50


def fetch_json(url: str, params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    request = urllib.request.Request(
        f"{url}?{query}", headers={"User-Agent": "OpenBat-RangeProbe/1.0"}
    )
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
        return json.load(response)


def parse_scientific_names(path: Path) -> dict[str, str]:
    """Pull the `code: "Genus species"` pairs out of a Swift dictionary literal.

    Deliberately a regex over the source rather than a hand-copied list: these
    tables are the app's own authority for what each model can name (see
    SpeciesGuideLookup's note on joining the two vocabularies on scientific
    name), and a copy here would be a third list to keep in sync — the exact
    thing that file's design avoids.
    """
    text = path.read_text()
    start = text.find("static let scientificNames")
    if start == -1:
        return {}
    # Open at the literal's own `= [`, not at the first `[` after the name —
    # that one belongs to the `[String: String]` type annotation, and closing on
    # its `]` yields an empty body.
    opening = text.find("= [", start)
    if opening == -1:
        return {}
    end = text.find("\n    ]", opening)
    body = text[opening:end if end != -1 else len(text)]
    return {
        code: name
        for code, name in re.findall(r'"([A-Z]+)"\s*:\s*"([^"]+)"', body)
    }


def guide_scientific_names() -> set[str]:
    if not GUIDE_PATH.exists():
        return set()
    guide = json.loads(GUIDE_PATH.read_text())
    return {
        entry["scientificName"].strip().lower()
        for entry in guide.get("species", [])
        if entry.get("scientificName")
    }


def probe(scientific_name: str) -> dict:
    result = {
        "queried": scientific_name,
        "matchType": None,
        "acceptedName": None,
        "taxonKey": None,
        "records": 0,
        "error": None,
    }
    try:
        match = fetch_json(MATCH_URL, {"name": scientific_name})
    except Exception as exc:
        result["error"] = f"match failed: {exc}"
        return result

    result["matchType"] = match.get("matchType")
    # `species` is the accepted name GBIF resolved to; when it differs from what
    # we asked for, the app is querying a synonym and its live record counts are
    # measuring the wrong taxon.
    result["acceptedName"] = match.get("species")
    result["taxonKey"] = match.get("usageKey")

    if result["taxonKey"] is None:
        return result

    time.sleep(REQUEST_DELAY_SECONDS)
    try:
        counted = fetch_json(
            OCCURRENCE_SEARCH_URL,
            {"taxonKey": result["taxonKey"], "hasCoordinate": "true", "limit": 0},
        )
        result["records"] = counted.get("count", 0)
    except Exception as exc:
        result["error"] = f"count failed: {exc}"
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", type=Path, help="also write the raw report here")
    args = parser.parse_args()

    models = {}
    for source in CLASSIFIER_SOURCES:
        if not source.exists():
            print(f"error: {source} not found", file=sys.stderr)
            return 1
        names = parse_scientific_names(source)
        if not names:
            print(f"error: no scientificNames table in {source.name}", file=sys.stderr)
            return 1
        models[source.stem] = names

    in_guide = guide_scientific_names()

    # One species can be named by more than one model; probe it once.
    everything: dict[str, list[str]] = {}
    for model, names in models.items():
        for code, scientific in names.items():
            everything.setdefault(scientific, []).append(f"{model}:{code}")

    print(f"{len(everything)} distinct species across {len(models)} models")
    print(f"{len(in_guide)} species in the bundled field guide\n")

    rows = []
    for scientific in sorted(everything):
        row = probe(scientific)
        row["codes"] = sorted(everything[scientific])
        row["inGuide"] = scientific.strip().lower() in in_guide
        rows.append(row)

        flags = []
        if row["error"]:
            flags.append(f"ERROR {row['error']}")
        if row["matchType"] not in (None, "EXACT"):
            flags.append(f"match={row['matchType']}")
        accepted = row["acceptedName"]
        if accepted and accepted.strip().lower() != scientific.strip().lower():
            flags.append(f"GBIF calls this {accepted}")
        if row["records"] < USABLE_RECORD_FLOOR:
            flags.append("TOO FEW RECORDS")
        if not row["inGuide"]:
            flags.append("no guide page")

        print(
            f"{scientific:<34} {row['records']:>8,} records"
            + (f"   [{'; '.join(flags)}]" if flags else "")
        )
        time.sleep(REQUEST_DELAY_SECONDS)

    print("\n--- summary ---")
    renamed = [r for r in rows if r["acceptedName"]
               and r["acceptedName"].strip().lower() != r["queried"].strip().lower()]
    thin = [r for r in rows if r["records"] < USABLE_RECORD_FLOOR]
    unmatched = [r for r in rows if r["taxonKey"] is None]
    print(f"species the app queries under a name GBIF has superseded: {len(renamed)}")
    for r in renamed:
        print(f"  {r['queried']} -> {r['acceptedName']}  ({', '.join(r['codes'])})")
    print(f"species with too few records to build a range from: {len(thin)}")
    for r in thin:
        print(f"  {r['queried']}  {r['records']} records  ({', '.join(r['codes'])})")
    print(f"species GBIF could not match at all: {len(unmatched)}")
    for r in unmatched:
        print(f"  {r['queried']}  ({', '.join(r['codes'])})")
    print(f"species with no field-guide page: {sum(1 for r in rows if not r['inGuide'])}"
          f" of {len(rows)}")

    if args.json:
        args.json.write_text(json.dumps(rows, indent=2, sort_keys=True))
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
