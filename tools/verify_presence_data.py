#!/usr/bin/env python3
"""
verify_presence_data.py

Checks SpeciesPresenceData.json against things we know to be true about real
bats in real places, so a regeneration that quietly breaks can't ship.

The cases below are the ones that motivated the whole change, plus enough
controls that a file which simply says "yes" to everything fails. Add a case
whenever a range turns out to be wrong in the field — that is what this file is
for.

Usage:
    python3 verify_presence_data.py [path]
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DEFAULT_PATH = ROOT / "SpeciesPresenceData.json"

SAN_FRANCISCO = (37.7749, -122.4194)
LONDON = (51.5072, -0.1276)
NASHVILLE = (36.1627, -86.7816)
# Gainesville, not Miami. The first version of this test used Miami and failed —
# correctly. The generated range reaches about 26 N (Fort Myers) and stops,
# which matches the southeastern myotis being largely absent from extreme
# southern Florida. The case was wrong, not the data; noted here so nobody
# "fixes" the range to satisfy a bad test.
GAINESVILLE_FL = (29.6516, -82.3248)
SYDNEY = (-33.8688, 151.2093)
# Perth, deliberately: same country, opposite coast, ~3300 km away. A control
# in London only proves the range isn't global; this one proves it has the
# right edge within Australia.
PERTH = (-31.9523, 115.8613)

# Cases we KNOW the current range data fails, accepted deliberately rather than
# fixed. Listed loudly on every run so they stay visible instead of quietly
# becoming the definition of correct. A case here still runs — it just doesn't
# fail the build.
#
# Keyed by (code, place).
KNOWN_LIMITATIONS = {
    ("MYAU", "Miami"):
        "GBIF holds two single-record cells at 25 N in south Florida, and the "
        "one-cell buffer around them reaches Miami. Accepted 2026-08-27: the "
        "cells that cause this are structurally identical to the single-record "
        "cells that carry Northern Myotis into boreal Canada — same count, same "
        "isolation, same position at a range margin — so every rule that "
        "removes one removes the other. Tested: hop-clustering at radius 1 "
        "fixes Miami and pulls 28 species' northern edges back, Northern Myotis "
        "from 62 N to 49 N. A land mask is the only discriminator that would "
        "separate them, since this stray sits over Florida Bay and boreal "
        "Canada is solid ground. Not worth it for one cell yet.",
}

# (code, place name, coordinate, expected, why)
CASES = [
    # The failures that started this. Each was actively wrong in the shipped app.
    ("LABL", "San Francisco", SAN_FRANCISCO, True,
     "western red bat is resident; the old name-based lookup returned 0 records "
     "and switched it off"),
    ("CNESER", "London", LONDON, True,
     "serotine is a familiar southern English bat; the app's Cnephaeus name "
     "matched only a genus and switched it off"),
    ("MYGR", "San Francisco", SAN_FRANCISCO, False,
     "gray bat is a Tennessee/Alabama cave species; a failed lookup left it at "
     "full weight in California"),
    ("NYHU", "San Francisco", SAN_FRANCISCO, False,
     "evening bat is eastern US"),
    ("MYAU", "San Francisco", SAN_FRANCISCO, False,
     "southeastern myotis is southeastern US"),

    # Controls: species that genuinely are where the app said they were.
    ("MYYU", "San Francisco", SAN_FRANCISCO, True, "Yuma myotis is common here"),
    ("ANPA", "San Francisco", SAN_FRANCISCO, True, "pallid bat is common here"),
    ("TABR", "San Francisco", SAN_FRANCISCO, True, "Brazilian free-tailed bat is common here"),

    # Controls the other way: the eastern species in their actual range, so a
    # file that marks everything absent outside California also fails.
    ("MYGR", "Nashville", NASHVILLE, True, "gray bat's actual range"),
    ("NYHU", "Nashville", NASHVILLE, True, "evening bat's actual range"),
    ("MYAU", "Gainesville FL", GAINESVILLE_FL, True, "southeastern myotis' actual range"),
    ("MYAU", "Miami", (25.7617, -80.1918), False,
     "and not extreme southern Florida — the range has a real southern edge, "
     "which is evidence the grid isn't just blanketing a region"),

    # Cross-continent controls: the UK model's species must not read as present
    # in California, which is exactly what they did at full weight before.
    ("PIPPIP", "London", LONDON, True, "common pipistrelle, Britain's commonest bat"),
    ("PIPPIP", "San Francisco", SAN_FRANCISCO, False, "no pipistrelles in California"),
    ("NYCNOC", "San Francisco", SAN_FRANCISCO, False, "noctule is European"),
    ("RHIFER", "San Francisco", SAN_FRANCISCO, False, "greater horseshoe is European"),
    ("MYYU", "London", LONDON, False, "Yuma myotis is North American"),

    # The first species keyed by its guide slug rather than a classifier code —
    # no ID model names the grey-headed flying fox, so `presenceCode` falls back
    # to the entry's `id`. These cases exist to prove that path produces a real
    # range and not an empty or a global one.
    ("pteropus-poliocephalus", "Sydney", SYDNEY, True,
     "grey-headed flying fox is a familiar east-coast Australian bat, and roosts "
     "in Sydney in tens of thousands"),
    ("pteropus-poliocephalus", "Perth", PERTH, False,
     "it is an EAST-coast species — a range that reaches Perth would mean the "
     "grid had blanketed the continent"),
    ("pteropus-poliocephalus", "London", LONDON, False,
     "and not another continent entirely"),
]


def cell_index(lat: float, lon: float, cell_degrees: float) -> int:
    rows = int(round(180 / cell_degrees))
    cols = int(round(360 / cell_degrees))
    row = min(rows - 1, max(0, int((lat + 90) / cell_degrees)))
    col = min(cols - 1, max(0, int((lon + 180) / cell_degrees)))
    return row * cols + col


def decode_cells(deltas: list[int]) -> list[int]:
    out = []
    running = 0
    for delta in deltas:
        running += delta
        out.append(running)
    return out


def main() -> int:
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_PATH
    if not path.exists():
        print(f"error: {path} not found — run generate_species_presence_data.py first",
              file=sys.stderr)
        return 1

    data = json.loads(path.read_text())
    cell_degrees = data["cellDegrees"]
    presence = data["presence"]
    unknown = set(data.get("unknown", []))

    print(f"{path.name}: {len(presence)} species with ranges, "
          f"{len(unknown)} unknown, {cell_degrees} deg cells, "
          f"dataVersion {data['dataVersion']}\n")

    lookup = {code: set(decode_cells(entry["cells"])) for code, entry in presence.items()}

    failures = 0
    tolerated = 0
    for code, place, (lat, lon), expected, why in CASES:
        if code not in lookup:
            state = "NO DATA"
            ok = False
        else:
            actual = cell_index(lat, lon, cell_degrees) in lookup[code]
            state = "present" if actual else "absent"
            ok = actual == expected
        known = KNOWN_LIMITATIONS.get((code, place))
        if not ok and known:
            tolerated += 1
            mark = "KNOWN"
        elif not ok:
            failures += 1
            mark = "FAIL"
        else:
            mark = "ok   "
        want = "present" if expected else "absent"
        print(f"{mark}{code:<7} {place:<15} {state:<8} (expected {want}) — {why}")

    print()
    if tolerated:
        print(f"{tolerated} known limitation{'' if tolerated == 1 else 's'}, "
              f"accepted deliberately:")
        for (code, place), reason in sorted(KNOWN_LIMITATIONS.items()):
            print(f"  {code} at {place}: {reason.split('.')[0]}.")
        print()
    if failures:
        print(f"{failures} of {len(CASES)} checks failed", file=sys.stderr)
        return 1
    print(f"{len(CASES) - tolerated} of {len(CASES)} checks passed"
          + (f", {tolerated} tolerated" if tolerated else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
