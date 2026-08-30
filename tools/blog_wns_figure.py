#!/usr/bin/env python3
"""
blog_wns_figure.py

One figure for the white-nose syndrome post on openbat.app: why waking up too
often kills a hibernating bat.

The curves are ILLUSTRATIVE — a drawing of the mechanism, not measurements.
A hibernating bat rouses periodically through the winter and each arousal is
expensive; infection drives those arousals far more often, and the fat runs out
before the insects come back. The shape is the point.

Usage:
    python3 tools/blog_wns_figure.py --out ~/Desktop/"OpenBat Figures"
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

PURPLE = "#7d4bd1"
RED = "#d1344b"
GREEN = "#1a9e5f"
INK = "#333333"
MUTED = "#888888"
PANEL = "#f7f7f9"
RULE = "#bbbbbb"

MONTHS = ["Oct", "Nov", "Dec", "Jan", "Feb", "Mar", "Apr"]


def budget(arousals, cost, drift, days=210):
    """Fat reserve over a winter, as a percentage, given arousal timing."""
    reserve = np.full(days, 100.0)
    level = 100.0
    for day in range(days):
        level -= drift
        if day in arousals:
            level -= cost
        reserve[day] = max(level, 0.0)
    return reserve


def figure(path):
    days = 210
    x = np.arange(days)

    healthy_arousals = set(range(12, days, 16))     # roughly every two weeks
    sick_arousals = set(range(12, days, 5))         # far more often

    healthy = budget(healthy_arousals, cost=3.2, drift=0.09)
    sick = budget(sick_arousals, cost=3.2, drift=0.09)

    fig, axes = plt.subplots(figsize=(20, 8))
    axes.plot(x, healthy, color=PURPLE, linewidth=2.2, zorder=4,
              label="a healthy winter — a bat rouses now and then")
    axes.plot(x, sick, color=RED, linewidth=2.2, zorder=4,
              label="with the infection — it rouses far more often")

    empty = int(np.argmax(sick <= 0))
    axes.axvline(empty, color=RED, linestyle=(0, (4, 4)), linewidth=1.1, zorder=3)
    axes.annotate("reserves gone,\nweeks before there is\nanything to eat",
                  xy=(empty, 4), xytext=(empty + 8, 34), fontsize=10.5, color=RED,
                  linespacing=1.5,
                  arrowprops=dict(arrowstyle="->", color=RED, linewidth=1.1))

    spring = days - 12
    axes.axvspan(spring, days, color=GREEN, alpha=0.10, zorder=1)
    axes.text(spring + 4, 92, "spring —\ninsects return", fontsize=10.5,
              color="#106b40", va="top", linespacing=1.5)

    axes.annotate("each step down is one arousal:\na few days' worth of fat, spent in hours",
                  xy=(60, healthy[60]), xytext=(38, 52), fontsize=10.5, color=MUTED,
                  linespacing=1.5,
                  arrowprops=dict(arrowstyle="->", color=MUTED, linewidth=0.9))

    axes.set_xticks([i * 30 for i in range(len(MONTHS))])
    axes.set_xticklabels(MONTHS)
    axes.set_xlim(0, days)
    axes.set_ylim(0, 108)
    axes.set_ylabel("fat reserve", fontsize=11, color="#555555")
    axes.set_yticks([0, 25, 50, 75, 100])
    axes.set_yticklabels(["empty", "25%", "50%", "75%", "full"])
    axes.set_facecolor(PANEL)
    axes.grid(True, linewidth=0.3, color="#dedede")
    axes.set_axisbelow(True)
    axes.tick_params(labelsize=9.5, colors="#666666")
    for spine in axes.spines.values():
        spine.set_edgecolor(RULE)
    axes.legend(loc="lower left", frameon=False, fontsize=11)

    fig.suptitle("A hibernating bat has one tank of fuel and no way to refill it",
                 fontsize=15, fontweight="bold")
    fig.text(0.5, 0.915, "why waking up too often is fatal, even though the fungus "
             "itself is not",
             ha="center", fontsize=10.5, color=MUTED)
    fig.text(0.01, 0.02, "illustrative — a drawing of the mechanism, not measured "
             "data · openbat.app", fontsize=7.5, color=MUTED)
    fig.tight_layout(rect=(0, 0.035, 1, 0.9))
    fig.savefig(path, dpi=130)
    plt.close(fig)
    print(f"wrote {path}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat Figures")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    figure(args.out / "wns-fat-budget.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
