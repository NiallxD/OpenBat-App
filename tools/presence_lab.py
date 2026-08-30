#!/usr/bin/env python3
"""
presence_lab.py

Renders raw GBIF against BOTH filter chains — the one that ships and the
candidate in presence_algorithms — so the rewrite can be judged by looking at
it rather than by reading threshold numbers.

Three panels per species, read left to right as the pipeline runs:

    1 RAW        every GBIF density bin, unfiltered
    2 OUTLIERS   the same observations, with the groups that fail both floors
                 ringed and filled in red — what is about to be thrown away
    3 RANGE      the buffer -> bridge -> group result as the app ships it,
                 with everything INFERRED (no records of its own) ringed green

The middle panel is the one to argue with: every red cell is a judgement that
a cluster of real records is not a distribution.

Also runs the four cases that decide the thresholds (Hawaii and the BC run must
survive; Bogota and Alaska must not) and fails loudly if any of them regress —
those are the regression tests for this rewrite, and they live here rather than
in a comment so that changing a threshold has to answer to them.

Usage:
    python3 presence_lab.py --out ~/Desktop/"OpenBat Range Rebuild"
    python3 presence_lab.py --only EUMA,LACI --bridge 2 --out ...
    python3 presence_lab.py --only EUMA --stages --out ...
"""

import argparse
import json
import math
import os
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.collections import LineCollection
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_species_presence_data as gen
import presence_algorithms as pa
import render_range_maps as rr

# Four shades of purple for four density tiers, plus a pale wash for cells that
# hold no observation at all.
#
# The wash is doing real work, not decoration. Buffer and bridge cells are
# INFERRED — the algorithm put them there because of what surrounds them, not
# because anyone recorded a bat in them — so a map that fills them the same
# purple as a well-recorded cell asserts a uniform population across the whole
# range, which is the thing this shading exists to stop claiming.
INFERRED_COLOUR = "#ece2fb"
DENSITY_COLOURS = ["#cbb3ec", "#a67fdc", "#7d4bd1", "#46228c"]
GAINED_COLOUR = "#1a9e5f"
LOST_COLOUR = "#d1344b"


def tier_breaks(values):
    """Integer cut points splitting a species' per-cell record counts into tiers.

    Per species, never global. Record counts differ by five orders of magnitude
    between species — the spotted bat's densest cell holds 10 records, the
    common pipistrelle's holds 187,356 — so one fixed scale renders every
    sparse species as a single flat tone, losing exactly the core/edge
    structure this is for.

    Quartiles by preference: they spread the four tones evenly over the cells
    and so show structure, rather than one dark dot in a pale field.

    Every break must sit STRICTLY ABOVE the smallest count, and that is the
    subtle one. 24% of all cells hold exactly one record, so the lower
    quartiles tie at the minimum; a break equal to it leaves the palest tier
    matching nothing at all, and the map then draws four tiers' worth of data
    in three tones while the legend names the same range twice. Where the
    quartiles collapse that way, log-spaced cuts are used instead — they
    divide the RANGE rather than the cells, so they cannot tie.

    Returned as integers so the legend can state exact, gap-free record spans.
    """
    values = np.asarray(values, dtype=float)
    smallest = values.min()

    quartiles = np.unique(np.ceil(np.percentile(values, [25, 50, 75])))
    quartiles = quartiles[quartiles > smallest]
    if len(quartiles) == 3:
        return quartiles.astype(int)

    low = np.log10(max(smallest, 1))
    high = np.log10(max(values.max(), smallest + 1))
    spaced = np.unique(np.ceil(
        10 ** (low + (high - low) * np.array([0.25, 0.5, 0.75]))))
    return spaced[spaced > smallest].astype(int)


def tier_label(breaks, smallest, index):
    """Exact record span for one tier, for the legend."""
    edges = [int(smallest)] + [int(b) for b in breaks] + [None]
    low, high = edges[index], edges[index + 1]
    if high is None:
        return f"{low:,}+ records"
    if high - 1 <= low:
        return f"{low:,} record" + ("" if low == 1 else "s")
    return f"{low:,}\u2013{high - 1:,} records"


def shade_by_density(axes, cells, raw, breaks, base_zorder=2):
    """Draw cells tinted by how many records each holds.

    Cells with no record of their own are the inferred ones — buffer and bridge
    fill — and get the pale wash.
    """
    inferred = [i for i in cells if i not in raw]
    if inferred:
        axes.add_collection(
            rr.cell_patches(inferred, INFERRED_COLOUR, 0.9, base_zorder))
    tiers: dict[int, list[int]] = {}
    for index in cells:
        count = raw.get(index)
        if count is None:
            continue
        tiers.setdefault(int(np.searchsorted(breaks, count, side="right")),
                         []).append(index)
    for tier, indices in sorted(tiers.items()):
        axes.add_collection(
            rr.cell_patches(indices, DENSITY_COLOURS[min(tier, 3)], 0.95,
                            base_zorder + 1 + tier))


def boundary_segments(cells):
    """The outline of a set of cells — only edges with nothing on the far side.

    Used to ring what the rewrite ADDS. A filled green overlay would hide the
    density shading underneath it, which is the one thing these maps now exist
    to show, so the gain is drawn as a line around it instead.
    """
    segments = []
    for index in cells:
        row, col = divmod(index, pa.COLS)
        lat, lon = row - 90, col - 180
        if (row - 1) * pa.COLS + col not in cells:
            segments.append([(lon, lat), (lon + 1, lat)])
        if (row + 1) * pa.COLS + col not in cells:
            segments.append([(lon, lat + 1), (lon + 1, lat + 1)])
        if row * pa.COLS + ((col - 1) % pa.COLS) not in cells:
            segments.append([(lon, lat), (lon, lat + 1)])
        if row * pa.COLS + ((col + 1) % pa.COLS) not in cells:
            segments.append([(lon + 1, lat), (lon + 1, lat + 1)])
    return segments

def group_centres(groups, raw):
    """Mid-point of each group's observation cells, as (lons, lats) for scatter."""
    lons, lats = [], []
    for group in groups:
        inside = [i for i in group["cells"] if i in raw] or list(group["cells"])
        lons.append(sum(i % pa.COLS - 180 for i in inside) / len(inside) + 0.5)
        lats.append(sum(i // pa.COLS - 90 for i in inside) / len(inside) + 0.5)
    return lons, lats


# The cases that decide the thresholds. (code, lat/lon box, must-survive).
REGRESSION_CASES = [
    ("LACI", (15, 25, -165, -150), True, "Hawaiian hoary bat"),
    ("EUMA", (48, 56, -130, -112), True, "Spotted bat's run into BC"),
    ("PIPPIP", (0, 12, -80, -70), False, "Bogota pipistrelle"),
    ("MYGR", (55, 72, -170, -130), False, "Alaskan gray bat"),
]


def current_chain(raw: dict[int, int]) -> set[int]:
    """The cells that actually hold records — the observations the rules judge.

    This used to run the old filter chain so the rewrite could be compared
    against what shipped. That chain is gone — presence_algorithms replaced it —
    so this is now simply the seed set, drawn in panel 2 with the groups about
    to be dropped ringed in red, and differenced against the final range to get
    `gained` and `lost`.
    """
    if sum(raw.values()) < gen.MIN_RECORDS_FOR_PRESENCE:
        return set()
    return set(raw)


def load_raw(cache: Path, code: str) -> dict[int, int]:
    path = cache / f"density_{code}.json"
    if not path.exists():
        return {}
    return {int(k): v for k, v in json.loads(path.read_text())["cells"].items()}


def render(path, basemap, extent, code, label, scientific, raw, old, new, params):
    # Figure height follows the DATA's shape rather than being fixed. The axes
    # hold a latitude-corrected aspect, so a fixed canvas leaves a species
    # spanning Ireland to China as a thin strip marooned in white space, at a
    # fraction of the size it could be drawn. Clamped at both ends so a very
    # tall or very wide range still lands on a sane page.
    west, east, south, north = extent
    panel_width = 24 / 3
    scale = 1 / max(0.2, math.cos(math.radians((south + north) / 2)))
    panel_height = panel_width * ((north - south) * scale) / (east - west)
    panel_height = min(9.0, max(3.5, panel_height))
    figure, axes_row = plt.subplots(1, 3, figsize=(24, panel_height + 2.4))
    gained = new["kept"] - old
    lost = old - new["kept"]
    # One set of breaks for all three panels. Per-panel breaks would retint the
    # same cell differently between them and make the comparison meaningless.
    breaks = tier_breaks(list(raw.values()))

    dropped_groups = [g for g in new["groups"] if not g["kept"]]
    panels = [
        ("raw", new["seeds"], "1 · Raw GBIF — every record",
         f"{len(new['seeds']):,} cells · {new['total_records']:,} records"),
        ("outliers", old, "2 · Outliers identified — under both floors",
         (f"{len(dropped_groups)} group{'' if len(dropped_groups) == 1 else 's'} "
          f"dropped · {len(lost):,} cell{'' if len(lost) == 1 else 's'}")
         if dropped_groups else "no outlying groups — every cluster survives"),
        ("range", new["kept"], "3 · Range — buffered, bridged, as the app ships it",
         f"{len(new['kept']):,} cells · {len(gained):,} inferred · "
         f"{sum(1 for g in new['groups'] if g['kept'])}/{len(new['groups'])} groups kept"),
    ]

    for axes, (panel, cells, title, subtitle) in zip(axes_row, panels):
        shade_by_density(axes, cells, raw, breaks)
        if panel == "outliers" and lost:
            # Filled red, then ringed. A dropped group is usually a single
            # cell, which at continental zoom is a few pixels and invisible
            # unless something circles it.
            axes.add_collection(rr.cell_patches(lost, LOST_COLOUR, 0.95, 9))
            axes.scatter(*group_centres(dropped_groups, raw),
                         s=260, facecolors="none", edgecolors=LOST_COLOUR,
                         linewidths=1.2, zorder=10)
        if panel == "range" and gained:
            axes.add_collection(LineCollection(
                boundary_segments(gained), linewidths=1.4,
                colors=GAINED_COLOUR, zorder=8))
        # Basemap LAST and above the fills: a border under a dark tier is
        # invisible, and these maps are read by asking which side of a border a
        # cell sits on.
        rr.draw_basemap(axes, basemap, extent)
        for collection in axes.collections:
            if collection.get_zorder() == 1:
                collection.set_zorder(7)
        rr.style_axes(axes, extent, title, subtitle)

    handles = [Line2D([], [], marker="s", linestyle="", markersize=10,
                      color=INFERRED_COLOUR,
                      label="inferred — buffer/bridge, no records")]
    smallest = min(raw.values())
    handles += [Line2D([], [], marker="s", linestyle="", markersize=10,
                       color=DENSITY_COLOURS[i],
                       label=tier_label(breaks, smallest, i))
                for i in range(len(breaks) + 1)]
    if gained:
        handles.append(Line2D([], [], color=GAINED_COLOUR, linewidth=2,
                              label="inferred — buffer and bridge"))
    if lost:
        handles.append(Line2D([], [], marker="s", linestyle="", markersize=10,
                              color=LOST_COLOUR, label="outlier — dropped as too small and too thin"))
    total_height = panel_height + 2.4
    figure.legend(handles=handles, loc="lower center", ncol=len(handles),
                  fontsize=8, frameon=False,
                  bbox_to_anchor=(0.5, 0.30 / total_height))

    figure.suptitle(f"{label}  ({scientific})  ·  {code}",
                    fontsize=15, fontweight="bold")
    figure.text(0.01, 0.10 / total_height, params, fontsize=7, color="#888888")
    figure.tight_layout(rect=(0, 0.85 / total_height, 1,
                              1 - 0.55 / total_height))
    figure.savefig(path, dpi=130)
    plt.close(figure)


def render_stages(path, basemap, code, label, scientific, raw, new, params):
    """The algorithm itself, one step per panel: raw -> buffered -> bridged.

    The comparison figure answers "what changed"; this one answers "how", which
    is the question anyone meeting buffer/bridge/group for the first time
    actually has. Each panel rings in green what THAT step added, so the two
    morphological operations can be told apart — buffering thickens an outline
    everywhere, bridging only fills between things.

    Group judging is deliberately not a fourth panel: it removes rather than
    adds, and the comparison figure already shows it.
    """
    seeds, buffered, mass = new["seeds"], new["buffered"], new["mass"]
    extent = rr.extent_for(mass)
    west, east, south, north = extent
    panel_width = 24 / 3
    scale = 1 / max(0.2, math.cos(math.radians((south + north) / 2)))
    panel_height = min(9.0, max(3.5,
        panel_width * ((north - south) * scale) / (east - west)))
    figure, axes_row = plt.subplots(1, 3, figsize=(24, panel_height + 2.4))
    breaks = tier_breaks(list(raw.values()))

    panels = [
        (seeds, None, "1 · Raw — cells holding records",
         f"{len(seeds):,} cells · {new['total_records']:,} records"),
        (buffered, buffered - seeds, "2 · Buffered — one cell in every direction",
         f"{len(buffered):,} cells · +{len(buffered - seeds):,} added (~111 km)"),
        (mass, mass - buffered, "3 · Bridged — short gaps closed",
         f"{len(mass):,} cells · +{len(mass - buffered):,} added"
         if mass - buffered else f"{len(mass):,} cells · nothing left to bridge"),
    ]

    for axes, (cells, added, title, subtitle) in zip(axes_row, panels):
        shade_by_density(axes, cells, raw, breaks)
        if added:
            axes.add_collection(LineCollection(
                boundary_segments(added), linewidths=1.4,
                colors=GAINED_COLOUR, zorder=8))
        rr.draw_basemap(axes, basemap, extent)
        for collection in axes.collections:
            if collection.get_zorder() == 1:
                collection.set_zorder(7)
        rr.style_axes(axes, extent, title, subtitle)

    handles = [Line2D([], [], marker="s", linestyle="", markersize=10,
                      color=INFERRED_COLOUR, label="inferred — no records of its own")]
    smallest = min(raw.values())
    handles += [Line2D([], [], marker="s", linestyle="", markersize=10,
                       color=DENSITY_COLOURS[i],
                       label=tier_label(breaks, smallest, i))
                for i in range(len(breaks) + 1)]
    handles.append(Line2D([], [], color=GAINED_COLOUR, linewidth=2,
                          label="added by this step"))
    total_height = panel_height + 2.4
    figure.legend(handles=handles, loc="lower center", ncol=len(handles),
                  fontsize=8, frameon=False,
                  bbox_to_anchor=(0.5, 0.30 / total_height))
    figure.suptitle(f"{label}  ({scientific})  ·  {code}  —  how the range is built",
                    fontsize=15, fontweight="bold")
    figure.text(0.01, 0.10 / total_height, params, fontsize=7, color="#888888")
    figure.tight_layout(rect=(0, 0.85 / total_height, 1, 1 - 0.55 / total_height))
    figure.savefig(path, dpi=130)
    plt.close(figure)


def check_regressions(cache: Path, kwargs: dict) -> list[str]:
    """The four cases the thresholds exist to get right."""
    lines = []
    ok = True
    for code, box, must_survive, description in REGRESSION_CASES:
        raw = load_raw(cache, code)
        if not raw:
            lines.append(f"  SKIP  {code} — no cached density")
            continue
        result = pa.build_presence(raw, **kwargs)
        south, north, west, east = box
        target = {i for i in raw
                  if south <= (i // pa.COLS - 90) < north
                  and west <= (i % pa.COLS - 180) < east}
        survived = bool(target & result["kept"])
        passed = survived == must_survive
        ok &= passed
        lines.append(
            f"  {'PASS' if passed else 'FAIL'}  {description:<30} "
            f"must {'survive' if must_survive else 'be dropped':<11} "
            f"-> {len(target & result['kept'])}/{len(target)} cells kept")
    lines.append(f"  {'all regression cases pass' if ok else '*** REGRESSIONS ***'}")
    return lines


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Range Rebuild")
    parser.add_argument("--cache", type=Path,
                        default=Path(os.environ.get("TMPDIR", "/tmp")) / "openbat-range-cache")
    parser.add_argument("--only", help="comma-separated species codes")
    parser.add_argument("--stages", action="store_true",
                        help="also write <species>_stages.png — raw, buffered, "
                             "bridged, one panel per step of the algorithm")
    parser.add_argument("--buffer", type=int, default=pa.BUFFER_CELLS)
    parser.add_argument("--bridge", type=int, default=pa.BRIDGE_CELLS)
    parser.add_argument("--min-group-cells", type=int, default=pa.MIN_GROUP_CELLS)
    parser.add_argument("--min-group-records", type=int, default=pa.MIN_GROUP_RECORDS)
    args = parser.parse_args()

    kwargs = dict(buffer_cells=args.buffer, bridge_cells=args.bridge,
                  min_group_cells=args.min_group_cells,
                  min_group_records=args.min_group_records)
    params = (f"buffer {args.buffer} cell · bridge {args.bridge} cells "
              f"(~{args.bridge * 2 * 111:.0f} km gaps closed) · "
              f"group needs {args.min_group_cells} observation cells"
              + (f", {args.min_group_records} records" if args.min_group_records else "")
              + f" · {pa.CELL_DEGREES}° cells")

    print("regression cases:")
    for line in check_regressions(args.cache, kwargs):
        print(line)
    print(f"\nparameters: {params}\n")

    args.out.mkdir(parents=True, exist_ok=True)
    basemap = rr.load_basemap(args.cache)
    only = {c.strip().upper() for c in args.only.split(",")} if args.only else None
    codes = rr.species_list(only)
    commons = rr.common_names()

    report = []
    for code in sorted(codes):
        raw = load_raw(args.cache, code)
        if not raw:
            print(f"{code}: no cached density, skipping")
            continue
        scientific = codes[code]
        label = commons.get(scientific.strip().lower()) or scientific
        old = current_chain(raw)
        new = pa.build_presence(raw, **kwargs)
        extent = rr.extent_for(new["seeds"])
        stem = f"{code}_{label.replace(' ', '-').replace('/', '-')}"
        render(args.out / f"{stem}.png", basemap, extent, code, label,
               scientific, raw, old, new, params)
        if args.stages:
            render_stages(args.out / f"{stem}_stages.png", basemap, code, label,
                          scientific, raw, new, params)

        gained, lost = new["kept"] - old, old - new["kept"]
        report.append({
            "code": code, "name": label, "raw": len(new["seeds"]),
            "records": new["total_records"], "old": len(old),
            "new": len(new["kept"]), "gained": len(gained), "lost": len(lost),
            "groups": new["groups"],
        })
        print(f"{code:<22} {len(old):>6} -> {len(new['kept']):>6} cells "
              f"(+{len(gained):,} / -{len(lost):,})")

    write_report(args.out / "rebuild-report.md", report, params,
                 check_regressions(args.cache, kwargs))
    print(f"\nwrote {args.out}")
    return 0


def write_report(path, report, params, regressions):
    lines = ["# Presence rebuild — current chain vs. buffer/bridge/group", "",
             f"Parameters: {params}", "", "## Regression cases", "", "```"]
    lines += regressions
    lines += ["```", "",
              "## Per species", "",
              "`lost` is cells the rewrite removes that ship today — worth a look",
              "whenever it is not zero. `gained` is range the app currently denies.",
              "",
              "| code | species | records | raw cells | current | proposed | gained | lost |",
              "|---|---|---|---|---|---|---|---|"]
    for row in report:
        lines.append(f"| {row['code']} | {row['name']} | {row['records']:,} | "
                     f"{row['raw']:,} | {row['old']:,} | {row['new']:,} | "
                     f"+{row['gained']:,} | -{row['lost']:,} |")
    lines += ["", "## Groups the rewrite dropped", "",
              "Every one of these is a cluster too small to be a distribution.",
              "If a real population appears here, `min_group_cells` is too high.", ""]
    for row in report:
        dropped = [g for g in row["groups"] if not g["kept"]]
        if not dropped:
            continue
        lines.append(f"- **{row['code']}** {row['name']}")
        for group in sorted(dropped, key=lambda g: -g["seed_cells"]):
            lines.append(f"  - {group['seed_cells']} observation cells, "
                         f"{group['records']} records — {group['why']}")
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
