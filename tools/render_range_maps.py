#!/usr/bin/env python3
"""
render_range_maps.py

Draws every species' range TWICE — once as GBIF hands it over, once after the
filters in generate_species_presence_data.py have run — so the two can be put
side by side and the question "are we cutting species off?" answered by looking
rather than by arguing about thresholds.

WHY IT IMPORTS THE GENERATOR RATHER THAN REIMPLEMENTING IT
----------------------------------------------------------
The whole value of this tool is that the right-hand map is what the app really
ships. A second copy of drop_outliers/dilate here would drift from the real one
and then quietly lie about it — which is the exact failure it exists to catch.
So the pipeline functions, the thresholds and the species list all come from
`generate_species_presence_data` by import; nothing about the filtering is
restated in this file.

WHAT "RAW" MEANS
----------------
Every bin GBIF's density endpoint returns for the taxon (plus aliases),
accumulated into the same 1-degree cells, with NO floor, NO outlier removal and
NO dilation. It is the unedited input, misidentifications and museum-catalogue
artefacts included — that is the point of having it next to the other one.

OUTPUT
------
    <outdir>/01 Raw/         one PNG per species, unfiltered
    <outdir>/02 App Logic/   one PNG per species, exactly what ships
    <outdir>/03 Comparison/  both on one canvas, dropped cells in red
    <outdir>/range-map-report.md   what each filter removed, per species

Density responses are cached under --cache so re-runs and re-styling cost no
GBIF requests.

Usage:
    python3 render_range_maps.py --out ~/Desktop/"OpenBat Range Maps"
    python3 render_range_maps.py --only EUMA,MYLU --out ...
"""

import argparse
import json
import math
import os
import sys
import time
import urllib.request
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Rectangle
from matplotlib.collections import PatchCollection, LineCollection

sys.path.insert(0, str(Path(__file__).resolve().parent))
import generate_species_presence_data as gen

# Natural Earth via the canonical vector repo. Countries alone would not answer
# the question that prompted this tool — "does it reach BC?" needs the province
# line, so admin-1 is fetched too.
BASEMAP_URLS = {
    "countries": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
                 "master/geojson/ne_110m_admin_0_countries.geojson",
    "provinces": "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
                 "master/geojson/ne_110m_admin_1_states_provinces.geojson",
}

RAW_COLOUR = "#8c8c8c"
KEPT_COLOUR = "#7d4bd1"
DROPPED_COLOUR = "#d1344b"


# --------------------------------------------------------------------------
# Basemap


def load_basemap(cache: Path) -> dict[str, list]:
    """Coastlines/borders as flat lists of (lon, lat) rings, cached on disk."""
    segments: dict[str, list] = {}
    for name, url in BASEMAP_URLS.items():
        path = cache / f"ne_{name}.geojson"
        if not path.exists():
            print(f"fetching basemap: {name}")
            request = urllib.request.Request(
                url, headers={"User-Agent": "OpenBat-RangeMapRenderer/1.0"})
            with urllib.request.urlopen(request, timeout=60) as response:
                path.write_bytes(response.read())
        data = json.loads(path.read_text())
        rings: list = []
        for feature in data.get("features", []):
            geometry = feature.get("geometry") or {}
            kind = geometry.get("type")
            coords = geometry.get("coordinates") or []
            if kind == "Polygon":
                rings.extend(coords)
            elif kind == "MultiPolygon":
                for polygon in coords:
                    rings.extend(polygon)
        segments[name] = rings
    return segments


def draw_basemap(axes, basemap, extent):
    west, east, south, north = extent
    for name, width, colour in (("provinces", 0.4, "#c9c9c9"),
                                ("countries", 0.8, "#8a8a8a")):
        lines = []
        for ring in basemap[name]:
            # Cheap bbox reject: a ring wholly outside the frame costs nothing
            # to skip and most of them are, at these extents.
            lons = [p[0] for p in ring]
            lats = [p[1] for p in ring]
            if max(lons) < west or min(lons) > east:
                continue
            if max(lats) < south or min(lats) > north:
                continue
            lines.append([(p[0], p[1]) for p in ring])
        if lines:
            axes.add_collection(LineCollection(lines, linewidths=width,
                                               colors=colour, zorder=1))


# --------------------------------------------------------------------------
# Cells


def cell_corner(index: int) -> tuple[float, float]:
    """Cell index -> its south-west corner, matching the generator and the app."""
    _, cols = gen.grid_dimensions()
    row, col = divmod(index, cols)
    return (col * gen.CELL_DEGREES - 180, row * gen.CELL_DEGREES - 90)


def cell_patches(indices, colour, alpha, zorder):
    size = gen.CELL_DEGREES
    patches = [Rectangle(cell_corner(i), size, size) for i in indices]
    return PatchCollection(patches, facecolor=colour, edgecolor="none",
                           alpha=alpha, zorder=zorder)


def extent_for(indices, pad=4.0, minimum_span=14.0):
    """A frame both panels share, so the eye compares shapes and not zooms."""
    if not indices:
        return (-180, 180, -60, 80)
    corners = [cell_corner(i) for i in indices]
    west = min(c[0] for c in corners) - pad
    east = max(c[0] for c in corners) + gen.CELL_DEGREES + pad
    south = min(c[1] for c in corners) - pad
    north = max(c[1] for c in corners) + gen.CELL_DEGREES + pad
    if east - west < minimum_span:
        mid = (east + west) / 2
        west, east = mid - minimum_span / 2, mid + minimum_span / 2
    if north - south < minimum_span:
        mid = (north + south) / 2
        south, north = mid - minimum_span / 2, mid + minimum_span / 2
    return (max(-180, west), min(180, east), max(-89, south), min(89, north))


def style_axes(axes, extent, title, subtitle):
    west, east, south, north = extent
    axes.set_xlim(west, east)
    axes.set_ylim(south, north)
    # Equirectangular with latitude-corrected aspect: shapes stay recognisable
    # without pulling in a projection library for a diagnostic image.
    axes.set_aspect(1 / max(0.2, math.cos(math.radians((south + north) / 2))))
    axes.set_facecolor("#f7f7f9")
    axes.grid(True, linewidth=0.3, color="#dedede", zorder=0)
    axes.tick_params(labelsize=7, colors="#666666")
    for spine in axes.spines.values():
        spine.set_edgecolor("#bbbbbb")
    # Title padded clear of the subtitle rather than both drawn at the axes
    # edge — otherwise the two overprint each other and neither is readable.
    axes.set_title(title, fontsize=11, fontweight="bold", loc="left", pad=20)
    if subtitle:
        axes.text(0, 1.012, subtitle, transform=axes.transAxes, fontsize=8,
                  color="#666666", va="bottom")


# --------------------------------------------------------------------------
# Per-species pipeline


def fetch_raw_cells(code, names, cache, delay):
    """Merged density cells for a code, cached per code."""
    path = cache / f"density_{code}.json"
    if path.exists():
        blob = json.loads(path.read_text())
        return ({int(k): v for k, v in blob["cells"].items()},
                blob["total"], blob["keys"], blob["notes"])

    keys, notes = [], []
    for name in names:
        try:
            key, note = gen.resolve_species_key(name)
        except Exception as exc:
            notes.append(f"{name}: lookup failed: {exc}")
            continue
        time.sleep(delay)
        notes.append(f"{name}: {'key %d' % key if key else 'no species key'} — {note}")
        if key:
            keys.append(key)

    merged: dict[int, int] = {}
    total = 0
    for key in keys:
        try:
            cells, count = gen.fetch_density_cells(key)
        except Exception as exc:
            notes.append(f"key {key}: density fetch failed: {exc}")
            continue
        for index, records in cells.items():
            merged[index] = merged.get(index, 0) + records
        total += count
        time.sleep(delay)

    path.write_text(json.dumps({"cells": {str(k): v for k, v in merged.items()},
                                "total": total, "keys": keys, "notes": notes}))
    return merged, total, keys, notes


def app_logic(raw: dict[int, int]) -> dict:
    """Run the shipped pipeline over raw cells, keeping every intermediate.

    Mirrors main() in the generator step for step — the floor first, then the
    two outlier passes, then dilation — because WHERE a species falls out is
    the thing being diagnosed, and only the intermediates show that.
    """
    total = sum(raw.values())
    result = {"total": total, "raw": set(raw), "kept": set(), "dilated": set(),
              "dropped_isolated": set(), "dropped_disconnected": set(),
              "verdict": "mapped"}
    if total < gen.MIN_RECORDS_FOR_PRESENCE:
        result["verdict"] = f"unknown — only {total} records (floor {gen.MIN_RECORDS_FOR_PRESENCE})"
        return result

    cleaned, _ = gen.drop_outliers(raw)
    result["dropped_isolated"] = set(raw) - set(cleaned)
    if not cleaned:
        result["verdict"] = "unknown — every cell was an isolated outlier"
        return result

    connected, _ = gen.drop_disconnected_outliers(cleaned)
    result["dropped_disconnected"] = set(cleaned) - set(connected)
    result["kept"] = set(connected)
    result["dilated"] = set(gen.dilate({i: 0 for i in connected}, gen.DILATE_CELLS))
    return result


# --------------------------------------------------------------------------
# Rendering


def render_single(path, basemap, extent, indices, title, subtitle, colour,
                  footer):
    figure, axes = plt.subplots(figsize=(9, 8))
    draw_basemap(axes, basemap, extent)
    if indices:
        axes.add_collection(cell_patches(indices, colour, 0.6, 3))
    style_axes(axes, extent, title, subtitle)
    figure.text(0.01, 0.015, footer, fontsize=7, color="#888888")
    figure.tight_layout(rect=(0, 0.03, 1, 1))
    figure.savefig(path, dpi=140)
    plt.close(figure)


def render_comparison(path, basemap, extent, code, label, scientific, raw,
                      stages, footer):
    figure, axes_pair = plt.subplots(1, 2, figsize=(17, 8))
    for axes, side in zip(axes_pair, ("raw", "app")):
        draw_basemap(axes, basemap, extent)
        if side == "raw":
            axes.add_collection(cell_patches(raw, RAW_COLOUR, 0.65, 3))
            style_axes(axes, extent, "Raw GBIF — unfiltered",
                       f"{len(raw):,} cells · {stages['total']:,} records")
        else:
            dropped = stages["dropped_isolated"] | stages["dropped_disconnected"]
            if stages["dilated"]:
                axes.add_collection(cell_patches(stages["dilated"], KEPT_COLOUR, 0.30, 2))
                axes.add_collection(cell_patches(stages["kept"], KEPT_COLOUR, 0.75, 3))
            if dropped:
                axes.add_collection(cell_patches(dropped, DROPPED_COLOUR, 0.85, 4))
            style_axes(axes, extent, "App logic — what ships",
                       f"{len(stages['dilated']):,} cells after dilation · "
                       f"{len(dropped):,} dropped (red)")
    figure.suptitle(f"{label}  ({scientific})  ·  {code}",
                    fontsize=14, fontweight="bold")
    figure.text(0.01, 0.015, footer, fontsize=7, color="#888888")
    figure.tight_layout(rect=(0, 0.03, 1, 0.95))
    figure.savefig(path, dpi=140)
    plt.close(figure)


# --------------------------------------------------------------------------


def species_list(only: set[str] | None) -> dict[str, str]:
    """The same code -> scientific name table the generator builds."""
    codes: dict[str, str] = {}
    for source in gen.CLASSIFIER_SOURCES:
        codes.update(gen.parse_scientific_names(source))
    named = {n.strip().lower() for n in codes.values()}
    for slug, scientific in gen.load_guide_codes().items():
        if scientific.strip().lower() not in named and slug not in codes:
            codes[slug] = scientific
    if only:
        codes = {c: n for c, n in codes.items() if c.upper() in only}
    return codes


def common_names() -> dict[str, str]:
    """Scientific -> common name, for titles that read like bats not binomials."""
    for path in gen.GUIDE_PATHS:
        if path.exists():
            data = json.loads(path.read_text())
            return {e["scientificName"].strip().lower(): e.get("commonName", "")
                    for e in data.get("species", []) if e.get("scientificName")}
    return {}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Range Maps")
    parser.add_argument("--cache", type=Path,
                        default=Path(os.environ.get("TMPDIR", "/tmp")) / "openbat-range-cache")
    parser.add_argument("--only", help="comma-separated species codes")
    parser.add_argument("--delay", type=float, default=gen.REQUEST_DELAY_SECONDS)
    args = parser.parse_args()

    only = {c.strip().upper() for c in args.only.split(",")} if args.only else None
    args.cache.mkdir(parents=True, exist_ok=True)
    raw_dir = args.out / "01 Raw"
    app_dir = args.out / "02 App Logic"
    cmp_dir = args.out / "03 Comparison"
    for directory in (raw_dir, app_dir, cmp_dir):
        directory.mkdir(parents=True, exist_ok=True)

    basemap = load_basemap(args.cache)
    codes = species_list(only)
    commons = common_names()
    print(f"{len(codes)} species\n")

    footer = (f"GBIF density bins, {gen.DENSITY_SQUARE_SIZE}px · "
              f"{gen.CELL_DEGREES}° cells · floor {gen.MIN_RECORDS_FOR_PRESENCE} records · "
              f"cell outliers <{gen.MIN_CELL_RECORDS} · "
              f"disconnected clusters <{gen.MIN_COMPONENT_RECORDS} beyond "
              f"{gen.NEARBY_CLUSTER_KM:.0f} km · dilation {gen.DILATE_CELLS}")

    report = []
    for code in sorted(codes):
        scientific = codes[code]
        names = gen.TAXON_ALIASES.get(code, [scientific])
        if scientific not in names:
            names = [scientific] + names
        label = commons.get(scientific.strip().lower()) or scientific
        print(f"{code}  {label}")

        raw, total, keys, notes = fetch_raw_cells(code, names, args.cache, args.delay)
        if not raw:
            print("    ! no cells returned\n")
            report.append({"code": code, "name": label, "scientific": scientific,
                           "verdict": "no GBIF cells", "raw": 0, "shipped": 0,
                           "dropped_isolated": 0, "dropped_disconnected": 0,
                           "raw_north": None, "app_north": None, "notes": notes})
            continue

        stages = app_logic(raw)
        extent = extent_for(set(raw))
        stem = f"{code}_{label.replace(' ', '-').replace('/', '-')}"

        render_single(raw_dir / f"{stem}_raw.png", basemap, extent, set(raw),
                      f"{label} — raw GBIF, unfiltered",
                      f"{scientific} · {code} · {len(raw):,} cells · {total:,} records",
                      RAW_COLOUR, footer)
        render_single(app_dir / f"{stem}_app.png", basemap, extent,
                      stages["dilated"],
                      f"{label} — as the app ships it",
                      f"{scientific} · {code} · {len(stages['dilated']):,} cells · "
                      f"{stages['verdict']}",
                      KEPT_COLOUR, footer)
        render_comparison(cmp_dir / f"{stem}_compare.png", basemap, extent, code,
                          label, scientific, set(raw), stages, footer)

        raw_north = max(cell_corner(i)[1] for i in raw) + gen.CELL_DEGREES
        app_north = (max(cell_corner(i)[1] for i in stages["dilated"])
                     + gen.CELL_DEGREES) if stages["dilated"] else None
        report.append({
            "code": code, "name": label, "scientific": scientific,
            "verdict": stages["verdict"], "raw": len(raw),
            "shipped": len(stages["dilated"]),
            "dropped_isolated": len(stages["dropped_isolated"]),
            "dropped_disconnected": len(stages["dropped_disconnected"]),
            "raw_north": raw_north, "app_north": app_north, "notes": notes,
        })
        print(f"    {len(raw):,} raw cells -> {len(stages['dilated']):,} shipped "
              f"({len(stages['dropped_isolated'])} isolated, "
              f"{len(stages['dropped_disconnected'])} disconnected dropped)\n")

    write_report(args.out / "range-map-report.md", report, footer)
    print(f"wrote {args.out}")
    return 0


def write_report(path: Path, report: list[dict], footer: str) -> None:
    lines = ["# OpenBat range maps — raw GBIF vs. shipped presence data", "",
             f"Thresholds: {footer}", "",
             "`north` is the northernmost latitude the range reaches. Where the",
             "app's north is well short of the raw north, the filters have",
             "trimmed a range edge — the thing worth eyeballing in `03 Comparison`.",
             "",
             "| code | species | verdict | raw cells | shipped | isolated dropped | disconnected dropped | raw north | app north |",
             "|---|---|---|---|---|---|---|---|---|"]
    for row in sorted(report, key=lambda r: r["code"]):
        raw_north = f"{row['raw_north']:.0f}°" if row["raw_north"] is not None else "—"
        app_north = f"{row['app_north']:.0f}°" if row["app_north"] is not None else "—"
        lines.append(f"| {row['code']} | {row['name']} | {row['verdict']} | "
                     f"{row['raw']:,} | {row['shipped']:,} | "
                     f"{row['dropped_isolated']} | {row['dropped_disconnected']} | "
                     f"{raw_north} | {app_north} |")
    lines += ["", "## Taxonomy resolution", ""]
    for row in sorted(report, key=lambda r: r["code"]):
        lines.append(f"- **{row['code']}** {row['scientific']}")
        for note in row["notes"]:
            lines.append(f"  - {note}")
    path.write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
