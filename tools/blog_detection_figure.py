#!/usr/bin/env python3
"""
blog_detection_figure.py

One figure for the "why bats are hard to watch" post on openbat.app: how far a
detector hears different bats, drawn to scale.

The distances are the approximate, widely-published figures used in survey
guidance (Barataud and the standard UK/EU survey handbooks). They are rules of
thumb, not measurements — real detection distance moves with habitat, weather,
microphone and how the bat is flying — and the caption on the post says so. The
point of the drawing is the ratio, not the number.

Usage:
    python3 tools/blog_detection_figure.py --out ~/Desktop/"OpenBat Figures"
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Circle
import numpy as np

PALE = "#ece2fb"
PURPLES = ["#cbb3ec", "#a67fdc", "#7d4bd1", "#46228c"]
INK = "#333333"
MUTED = "#888888"
PANEL = "#f7f7f9"
RULE = "#bbbbbb"

# (label, call frequency note, approximate detection distance in metres)
SPECIES = [
    ("Noctule", "~20 kHz, loud and low", 100, PURPLES[0]),
    ("Serotine", "~25 kHz", 40, PURPLES[1]),
    ("Common pipistrelle", "~45 kHz", 25, PURPLES[2]),
    ("Daubenton's", "~45 kHz, quieter", 15, PURPLES[3]),
    ("Brown long-eared", "faint, broadband", 6, "#d1344b"),
]


def figure(path):
    """Circles to scale on the left, the same distances as bars on the right.

    Leader lines from a circle to a label cross every other circle on the way
    out, so the two halves are kept apart: the rings carry the shock, the bars
    carry the reading.
    """
    fig, (rings, bars) = plt.subplots(
        1, 2, figsize=(20, 9), gridspec_kw={"width_ratios": [1, 1], "wspace": 0.08})
    limit = 112

    for label, note, radius, colour in SPECIES:
        rings.add_patch(Circle((0, 0), radius, facecolor=colour, alpha=0.09, zorder=2))
        rings.add_patch(Circle((0, 0), radius, facecolor="none", edgecolor=colour,
                               linewidth=1.8, zorder=3))

    for metres in (25, 50, 75, 100):
        rings.add_patch(Circle((0, 0), metres, facecolor="none", edgecolor="#d2d2d8",
                               linewidth=0.7, linestyle=(0, (4, 4)), zorder=1))
        rings.text(metres * 0.7, -metres * 0.72, f"{metres} m", fontsize=8.5,
                   color=MUTED, ha="left", va="top", zorder=4)

    rings.plot([0], [0], marker="o", markersize=9, color=INK, zorder=5)
    rings.text(-limit + 7, limit - 9, "every circle is centred on you",
               fontsize=10, color=MUTED, ha="left", va="top", zorder=5)

    rings.set_xlim(-limit, limit)
    rings.set_ylim(-limit, limit)
    rings.set_aspect("equal")
    rings.set_facecolor(PANEL)
    rings.set_xticks([])
    rings.set_yticks([])
    for spine in rings.spines.values():
        spine.set_edgecolor(RULE)

    top = len(SPECIES)
    for i, (label, note, radius, colour) in enumerate(SPECIES):
        y = top - i - 1
        bars.barh([y], [radius], height=0.34, color=colour, zorder=3)
        bars.text(0, y + 0.32, label, fontsize=13, fontweight="bold", color=INK,
                  va="bottom")
        bars.text(radius + 3, y, f"{radius} m", fontsize=11.5, color=colour,
                  va="center", fontweight="bold")
        # Notes in a fixed column rather than trailing each bar, so the longest
        # bar's distance label can't collide with its own note.
        bars.text(132, y, note, fontsize=10, color=MUTED, va="center")

    bars.set_xlim(0, 205)
    bars.set_ylim(-0.9, top - 0.1)
    bars.set_yticks([])
    bars.set_xticks([0, 25, 50, 75, 100])
    bars.set_xticklabels(["0", "25 m", "50 m", "75 m", "100 m"])
    bars.tick_params(labelsize=9, colors="#666666")
    bars.grid(True, axis="x", linewidth=0.3, color="#dedede")
    bars.set_axisbelow(True)
    bars.set_facecolor(PANEL)
    for spine in bars.spines.values():
        spine.set_edgecolor(RULE)

    fig.suptitle("The same night, five different bats", fontsize=16, fontweight="bold")
    fig.text(0.5, 0.905, "how far away a detector hears each one, drawn to scale",
             ha="center", fontsize=11, color=MUTED)
    fig.text(0.01, 0.02,
             "approximate distances from survey guidance — real range moves with "
             "habitat, weather, microphone and how the bat is flying · openbat.app",
             fontsize=7.5, color=MUTED)
    fig.tight_layout(rect=(0, 0.035, 1, 0.89))
    fig.savefig(path, dpi=130)
    plt.close(fig)
    print(f"wrote {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Figures")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    figure(args.out / "detection-distance.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
