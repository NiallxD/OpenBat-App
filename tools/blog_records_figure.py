#!/usr/bin/env python3
"""
blog_records_figure.py

One figure for the "the gaps in bat data" post on openbat.app: how many GBIF
occurrence records exist for each of the 48 species OpenBat can name, on a log
scale, coloured by where the species lives.

The numbers are real — they come from presence_lab's own report, which is
written from the same GBIF density counts the range maps are built from. Run
presence_lab first, then point this at its report.

Usage:
    python3 tools/blog_records_figure.py \\
        --report ~/Desktop/"OpenBat Range Rebuild"/rebuild-report.md \\
        --out ~/Desktop/"OpenBat Figures"
"""

import argparse
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
import numpy as np

INK = "#333333"
MUTED = "#888888"
PANEL = "#f7f7f9"
RULE = "#bbbbbb"
EUROPE = "#7d4bd1"
AMERICAS = "#cbb3ec"
ELSEWHERE = "#1a9e5f"

EUROPEAN = {"BARBAR", "CNESER", "MYOALC", "MYOBEC", "MYOBRA", "MYODAU", "MYOMYS",
            "MYONAT", "NYCLEI", "NYCNOC", "PIPNAT", "PIPPIP", "PIPPYG", "PLEAUR",
            "PLEAUS", "RHIFER", "RHIHIP"}

# Species worth naming on the chart, and why they are the interesting ones.
CALLOUTS = {
    "PIPPIP": "Common pipistrelle",
    "MYLU": "Little brown bat",
    "EUMA": "Spotted bat",
}

ROW = re.compile(r"^\| (\S+) \| (.+?) \| ([\d,]+) \| ([\d,]+) \|")


def read_report(path):
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        m = ROW.match(line)
        if not m or not m.group(3)[0].isdigit():
            continue
        code, name, records = m.group(1), m.group(2).strip(), int(m.group(3).replace(",", ""))
        rows.append({"code": code, "name": name, "records": records})
    rows.sort(key=lambda r: r["records"])
    return rows


def figure(rows, path):
    fig, axes = plt.subplots(figsize=(22, 8.5))
    x = np.arange(len(rows))
    colours = [EUROPE if r["code"] in EUROPEAN
               else (ELSEWHERE if r["code"].islower() else AMERICAS) for r in rows]
    axes.bar(x, [r["records"] for r in rows], color=colours, width=0.72, zorder=3)
    axes.set_yscale("log")
    axes.set_ylim(80, 8_000_000)

    for i, row in enumerate(rows):
        label = CALLOUTS.get(row["code"])
        if not label:
            continue
        axes.annotate(f"{label}\n{row['records']:,} records",
                      xy=(i, row["records"]), xytext=(i, row["records"] * 4.2),
                      ha="center", fontsize=10.5, color=INK, linespacing=1.5,
                      arrowprops=dict(arrowstyle="-", color=MUTED, linewidth=0.9))

    axes.set_xticks([])
    axes.set_xlim(-1, len(rows))
    axes.set_ylabel("GBIF records held, log scale", fontsize=11, color="#555555")
    axes.set_facecolor(PANEL)
    axes.grid(True, axis="y", linewidth=0.3, color="#dedede")
    axes.set_axisbelow(True)
    axes.tick_params(labelsize=9, colors="#666666")
    for spine in axes.spines.values():
        spine.set_edgecolor(RULE)

    axes.legend(handles=[
        Line2D([], [], marker="s", linestyle="", markersize=10, color=EUROPE,
               label="European species"),
        Line2D([], [], marker="s", linestyle="", markersize=10, color=AMERICAS,
               label="North American species"),
        Line2D([], [], marker="s", linestyle="", markersize=10, color=ELSEWHERE,
               label="elsewhere"),
    ], loc="upper left", frameon=False, fontsize=10)

    fig.suptitle("Every bat OpenBat can name, by how much has been written down about it",
                 fontsize=15, fontweight="bold")
    fig.text(0.5, 0.915,
             "one bar per species, sorted — note the scale multiplies by ten each step",
             ha="center", fontsize=10.5, color=MUTED)
    fig.text(0.01, 0.02,
             "GBIF occurrence records, the same counts the app's range maps are built "
             "from · openbat.app", fontsize=7.5, color=MUTED)
    fig.tight_layout(rect=(0, 0.035, 1, 0.9))
    fig.savefig(path, dpi=130)
    plt.close(fig)
    print(f"wrote {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Figures")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    rows = read_report(args.report)
    print(f"{len(rows)} species, {rows[0]['records']:,} to {rows[-1]['records']:,} records")
    figure(rows, args.out / "records-per-species.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
