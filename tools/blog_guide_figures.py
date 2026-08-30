#!/usr/bin/env python3
"""
blog_guide_figures.py

Figures for the "contributing to the field guide" post on openbat.app, drawn in
the same palette as blog_autoid_figures.py and presence_lab.py so the site's
figures read as one family.

Both are diagrams of how contributing works, not measurements of anything. The
field names come from the guide's schema in the OpenBat-FieldGuide README; if
that schema changes, change these.

The post shows the editor itself for what an entry holds — a screenshot of the
real form beats a drawing of it. `entry()` survives as the post's hero and card
artwork, where it is wanted as texture rather than as something to read.

Usage:
    python3 tools/blog_guide_figures.py --out ~/Desktop/"OpenBat Guide Figures"
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch

PALE = "#ece2fb"
GREENPALE = "#e6f6ee"
PURPLES = ["#cbb3ec", "#a67fdc", "#7d4bd1", "#46228c"]
INK = "#333333"
MUTED = "#888888"


def _finish(figure, path, note):
    figure.text(0.01, 0.015, note, fontsize=7, color=MUTED)
    figure.savefig(path, dpi=130)
    plt.close(figure)
    print(f"wrote {path}")


def journey(path):
    """What happens between pressing Submit and the entry reaching phones."""
    steps = [
        ("You", "fill in the form at\nopenbat.app/guide-editor/", PURPLES[0]),
        ("A pull request", "opened on your behalf —\nno GitHub account needed", PURPLES[1]),
        ("Checks", "required fields, real regions,\nphoto credits, links", PURPLES[2]),
        ("Review", "a person reads it before\nanything goes live", PURPLES[2]),
        ("Everyone", "merged — every app picks it\nup at its next launch", None),
    ]
    figure, axes = plt.subplots(figsize=(22, 4.4))
    axes.set_xlim(0, len(steps) * 4)
    axes.set_ylim(0, 3)
    axes.axis("off")

    for i, (title, detail, colour) in enumerate(steps):
        x = i * 4 + 0.35
        last = colour is None
        axes.add_patch(FancyBboxPatch((x, 0.85), 3.3, 1.5,
                                      boxstyle="round,pad=0.06,rounding_size=0.12",
                                      linewidth=1.2,
                                      edgecolor="#1a9e5f" if last else colour,
                                      facecolor=GREENPALE if last else PALE))
        axes.text(x + 1.65, 1.95, f"{i + 1}. {title}", ha="center", va="center",
                  fontsize=13, fontweight="bold",
                  color="#106b40" if last else INK)
        axes.text(x + 1.65, 1.32, detail, ha="center", va="center",
                  fontsize=9.5, color="#555555", linespacing=1.5)
        if i < len(steps) - 1:
            axes.annotate("", xy=(x + 4.05, 1.6), xytext=(x + 3.52, 1.6),
                          arrowprops=dict(arrowstyle="-|>", color=MUTED,
                                          linewidth=1.4, mutation_scale=18))

    axes.text(len(steps) * 2, 0.35,
              "your edit is never applied straight to the guide — the review is the gate",
              ha="center", va="center", fontsize=10, color=MUTED, style="italic")
    figure.suptitle("From your edit to everyone's phone",
                    fontsize=15, fontweight="bold")
    figure.tight_layout(rect=(0, 0.02, 1, 0.94))
    _finish(figure, path, "openbat.app")


def entry(path):
    """Four fields are required; everything else is 'add what you know'."""
    required = ["id", "commonName", "scientificName", "regions"]
    optional = [
        ("Photo", ["imageURL", "imageCredit"]),
        ("Words", ["summary", "references", "contributors"]),
        ("Taxonomy", ["order", "family"]),
        ("Size", ["forearm", "wingspan", "weight", "colour"]),
        ("Features", ["ears", "tail", "nose", "other"]),
        ("Echolocation", ["call type", "peak freq", "char. freq",
                          "high/low freq", "duration", "notes"]),
        ("Status", ["IUCN status", "local status"]),
        ("Habits", ["roosting", "migration", "feeding", "reproduction"]),
    ]

    figure, axes = plt.subplots(figsize=(22, 6.6))
    axes.set_xlim(0, 24)
    axes.set_ylim(0, 7.4)
    axes.axis("off")

    axes.text(0.4, 6.8, "Required — four fields", fontsize=13, fontweight="bold",
              color=INK)
    axes.text(0.4, 6.35, "without these there is no entry", fontsize=9.5, color=MUTED)
    for i, field in enumerate(required):
        y = 5.5 - i * 0.95
        axes.add_patch(FancyBboxPatch((0.4, y), 4.6, 0.72,
                                      boxstyle="round,pad=0.04,rounding_size=0.1",
                                      linewidth=1.2, edgecolor=PURPLES[3],
                                      facecolor=PALE))
        axes.text(2.7, y + 0.36, field, ha="center", va="center", fontsize=11,
                  color=INK, fontweight="bold")

    axes.text(6.4, 6.8, "Optional — add what you know, leave the rest",
              fontsize=13, fontweight="bold", color=INK)
    axes.text(6.4, 6.35, "a sparse entry renders a shorter page, never empty boxes",
              fontsize=9.5, color=MUTED)
    for i, (group, fields) in enumerate(optional):
        col, row = divmod(i, 4)
        x = 6.4 + col * 8.9
        y = 5.05 - row * 1.42
        axes.add_patch(FancyBboxPatch((x, y - 0.28), 8.2, 1.15,
                                      boxstyle="round,pad=0.04,rounding_size=0.1",
                                      linewidth=1.1, edgecolor=PURPLES[0],
                                      facecolor="#f7f7f9"))
        axes.text(x + 0.3, y + 0.55, group, fontsize=11, fontweight="bold",
                  color=PURPLES[3], va="center")
        axes.text(x + 0.3, y + 0.06, " · ".join(fields), fontsize=9.5,
                  color="#555555", va="center")

    figure.suptitle("What one species entry holds", fontsize=15, fontweight="bold")
    figure.tight_layout(rect=(0, 0.02, 1, 0.95))
    _finish(figure, path, "openbat.app · full schema in the field guide repo")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Guide Figures")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    journey(args.out / "guide-journey.png")
    entry(args.out / "guide-entry.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
