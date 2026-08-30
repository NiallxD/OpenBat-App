#!/usr/bin/env python3
"""
blog_autoid_figures.py

The three explanatory figures for the "how auto ID works" post on openbat.app.
Kept beside presence_lab.py, and drawn in the same palette, so the site's
figures read as one family.

Nothing here reads the app or the models: the pulse envelope and the score
tables are ILLUSTRATIVE, chosen to show the shape of each step at values the
real thresholds actually sit at (0.3 trigger, 30 ms hold-off, 0.57 NoID,
priors of 1.0 / 0.5 / 0.01). They are drawings of the algorithm, not
measurements of a night's recording, and the captions on the post say so.

Usage:
    python3 tools/blog_autoid_figures.py --out ~/Desktop/"OpenBat AutoID Figures"
"""

import argparse
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch
import numpy as np

# Same palette as presence_lab.py.
PALE = "#ece2fb"
PURPLES = ["#cbb3ec", "#a67fdc", "#7d4bd1", "#46228c"]
GREEN = "#1a9e5f"
RED = "#d1344b"
INK = "#333333"
MUTED = "#888888"
PANEL = "#f7f7f9"
RULE = "#bbbbbb"


def _finish(figure, path, note):
    figure.text(0.01, 0.012, note, fontsize=7, color=MUTED)
    figure.savefig(path, dpi=130)
    plt.close(figure)
    print(f"wrote {path}")


# ---------------------------------------------------------------- figure 1
def pipeline(path):
    """The chain, one box per stage."""
    stages = [
        ("Sound", "the microphone hears\n384,000 samples a second", PURPLES[0]),
        ("Pulse", "a call is loud enough AND\nhigh enough — 30 ms hold-off", PURPLES[0]),
        ("Window", "a slice of audio cut around it,\nonset placed 30% in", PURPLES[1]),
        ("Picture", "drawn as the spectrogram\nimage the model expects", PURPLES[1]),
        ("Model", "on-device network scores\nevery class it knows", PURPLES[2]),
        ("Where", "scores weighted by what\nlives here, then renormalised", PURPLES[2]),
        ("Verdict", "pulses pooled into a pass:\nspecies, noise, or no ID", PURPLES[3]),
    ]
    figure, axes = plt.subplots(figsize=(22, 4.6))
    axes.set_xlim(0, len(stages) * 3)
    axes.set_ylim(0, 3)
    axes.axis("off")

    for i, (title, detail, colour) in enumerate(stages):
        x = i * 3 + 0.25
        axes.add_patch(FancyBboxPatch((x, 0.85), 2.5, 1.5,
                                      boxstyle="round,pad=0.06,rounding_size=0.12",
                                      linewidth=1.2, edgecolor=colour,
                                      facecolor=PALE if i < 6 else "#e6f6ee"))
        axes.text(x + 1.25, 1.95, f"{i + 1}. {title}", ha="center", va="center",
                  fontsize=13, fontweight="bold",
                  color=INK if i < 6 else "#106b40")
        axes.text(x + 1.25, 1.35, detail, ha="center", va="center",
                  fontsize=9.5, color="#555555", linespacing=1.5)
        if i < len(stages) - 1:
            axes.annotate("", xy=(x + 3.15, 1.6), xytext=(x + 2.62, 1.6),
                          arrowprops=dict(arrowstyle="-|>", color=MUTED,
                                          linewidth=1.4, mutation_scale=18))

    axes.text(len(stages) * 1.5, 0.35,
              "every step runs on the phone — no audio and no location ever leaves it",
              ha="center", va="center", fontsize=10, color=MUTED, style="italic")
    figure.suptitle("How one bat call becomes an identification",
                    fontsize=15, fontweight="bold")
    figure.tight_layout(rect=(0, 0.02, 1, 0.94))
    _finish(figure, path, "illustrative diagram · openbat.app")


# ---------------------------------------------------------------- figure 2
def pulses(path):
    """Pulses are detected one at a time; a pass is judged as a whole."""
    rng = np.random.default_rng(7)
    seconds = 0.98
    t = np.linspace(0, seconds, 4000)
    onsets = [0.10, 0.19, 0.28, 0.37, 0.47, 0.56, 0.66, 0.76]
    peaks = [0.42, 0.63, 0.81, 0.74, 0.88, 0.59, 0.66, 0.38]
    envelope = 0.045 + 0.02 * rng.random(t.size)
    for onset, peak in zip(onsets, peaks):
        envelope += peak * np.exp(-((t - onset) / 0.006) ** 2)
    # An echo of the loudest call, arriving inside the hold-off and much quieter.
    envelope += 0.26 * np.exp(-((t - 0.487) / 0.005) ** 2)

    figure, (top, bottom) = plt.subplots(
        2, 1, figsize=(22, 8), gridspec_kw={"height_ratios": [1.35, 1], "hspace": 0.42})

    top.plot(t, envelope, color=PURPLES[2], linewidth=1.4)
    top.axhline(0.3, color=RED, linestyle="--", linewidth=1.2)
    top.text(seconds - 0.01, 0.325, "trigger level 0.3", ha="right", fontsize=9,
             color=RED)
    for onset in onsets:
        top.axvspan(onset, onset + 0.03, color=PALE, zorder=0)
        top.plot([onset], [0.98], marker="v", color=PURPLES[3], markersize=8)
    top.text(0, 1.02, "each ▼ is one captured call · shaded band is the 30 ms "
             "hold-off that rejects its echo", transform=top.transAxes,
             fontsize=9.5, color=MUTED)
    # Sits just under the echo it names: a label this far from its subject
    # needs a long leader line, and the leader crosses two other pulses.
    top.annotate("echo — inside the hold-off,\nand quieter anyway",
                 xy=(0.494, 0.19), xytext=(0.512, 0.085), fontsize=9, color=MUTED,
                 arrowprops=dict(arrowstyle="->", color=MUTED, linewidth=0.9))
    top.annotate("", xy=(0.09, 1.09), xytext=(0.80, 1.09),
                 arrowprops=dict(arrowstyle="<->", color=INK, linewidth=1.1))
    top.text(0.445, 1.115, "one pass", ha="center", fontsize=10, color=INK,
             fontweight="bold")
    top.text(0.89, 1.02, "…and 2 s of silence\nfrom here closes it",
             fontsize=9, color=MUTED, ha="center", va="center")
    top.set_xlim(0, seconds)
    top.set_ylim(-0.02, 1.2)
    top.set_ylabel("loudness", fontsize=10, color="#555555")
    top.set_title("1 · Detection — pulses are found one at a time",
                  fontsize=13, fontweight="bold", loc="left", pad=26)

    scores = [0.44, 0.71, 0.83, 0.76, 0.88, 0.62, 0.69, 0.41]
    mean = float(np.mean(scores))
    # One colour on purpose: the no-ID test is on the MEAN, so a single pulse
    # under the line is not itself rejected and must not look rejected.
    bottom.bar(range(1, len(scores) + 1), scores, color=PURPLES[2], width=0.55)
    bottom.axhline(0.57, color=RED, linestyle="--", linewidth=1.2)
    bottom.text(len(scores) + 0.42, 0.50, "no-ID line 0.57", ha="right",
                fontsize=9, color=RED)
    bottom.axhline(mean, color=GREEN, linewidth=1.4)
    bottom.text(len(scores) + 0.42, mean + 0.03,
                f"mean {mean:.2f} — the pass gets a name",
                ha="right", fontsize=9.5, color=GREEN, fontweight="bold")
    bottom.set_xticks(range(1, len(scores) + 1))
    bottom.set_xlabel("pulse", fontsize=10, color="#555555")
    bottom.set_ylabel("model's own confidence", fontsize=10, color="#555555")
    bottom.set_ylim(0, 1.0)
    bottom.set_xlim(0.4, len(scores) + 0.6)
    bottom.set_title("2 · Aggregation — the pass is judged on all of them together",
                     fontsize=13, fontweight="bold", loc="left", pad=26)
    bottom.text(0, 1.02, "no single pulse has to clear the line — the average of "
                "them does, or the pass is recorded as \u201cno ID\u201d",
                transform=bottom.transAxes, fontsize=9.5, color=MUTED)

    for axes in (top, bottom):
        axes.set_facecolor(PANEL)
        axes.grid(True, linewidth=0.3, color="#dedede")
        axes.set_axisbelow(True)
        axes.tick_params(labelsize=8, colors="#666666")
        for spine in axes.spines.values():
            spine.set_edgecolor(RULE)

    figure.suptitle("A pass is the unit that gets a name, not a single call",
                    fontsize=15, fontweight="bold")
    figure.tight_layout(rect=(0, 0.03, 1, 0.95))
    _finish(figure, path,
            "illustrative · real thresholds (0.3 trigger, 30 ms hold-off, "
            "0.57 no-ID for NABat ML) · openbat.app")


# ---------------------------------------------------------------- figure 3
def priors(path):
    """What the range grid does to a set of scores, and what it deliberately can't do."""
    codes = ["MYODAU", "MYOBRA", "PIPPIP", "MYONAT", "PIPPYG", "BARBAR"]
    names = ["Daubenton's", "Brandt's", "Common pip", "Natterer's",
             "Soprano pip", "Barbastelle"]
    raw = np.array([0.38, 0.23, 0.16, 0.11, 0.08, 0.04])
    weights = np.array([1.0, 0.01, 1.0, 1.0, 1.0, 0.5])
    labels = ["in range", "out of range", "in range", "in range", "in range",
              "no range data"]
    adjusted = raw * weights
    adjusted = adjusted / adjusted.sum()

    figure, axes_row = plt.subplots(1, 3, figsize=(22, 6.4))
    y = np.arange(len(codes))[::-1]

    panels = [
        (raw, "1 · What the model heard",
         "one pulse, scores as the network produced them", PURPLES[1], None),
        (weights, "2 · What lives here",
         "weight from the bundled range grid at your location", None, labels),
        (adjusted, "3 · What gets reported",
         "weighted, then renormalised back to a total of 1", PURPLES[3], None),
    ]

    for axes, (values, title, subtitle, colour, notes) in zip(axes_row, panels):
        if colour is None:
            bar_colours = [RED if w < 0.1 else (PURPLES[0] if w < 1 else PURPLES[2])
                           for w in values]
        else:
            bar_colours = [colour] * len(values)
        axes.barh(y, values, color=bar_colours, height=0.62)
        for i, value in enumerate(values):
            text = f"{value:.2f}" if notes is None else f"{value:g}  ({notes[i]})"
            axes.text(value + (0.02 if notes is None else 0.03), y[i], text,
                      va="center", fontsize=9,
                      color=INK if notes is None else "#555555")
        axes.set_yticks(y)
        axes.set_yticklabels([f"{n}\n{c}" for n, c in zip(names, codes)],
                             fontsize=9.5)
        axes.set_xlim(0, 1.32 if notes is not None else 0.72)
        axes.set_facecolor(PANEL)
        axes.grid(True, axis="x", linewidth=0.3, color="#dedede")
        axes.set_axisbelow(True)
        axes.tick_params(labelsize=8, colors="#666666")
        for spine in axes.spines.values():
            spine.set_edgecolor(RULE)
        axes.set_title(title, fontsize=13, fontweight="bold", loc="left", pad=24)
        axes.text(0, 1.02, subtitle, transform=axes.transAxes, fontsize=9.5,
                  color=MUTED)

    axes_row[2].annotate("the winner gains confidence because a\n"
                         "rival was ruled out, not because the\nmodel heard more",
                         xy=(adjusted[0], y[0] - 0.35), xytext=(0.33, 2.7),
                         fontsize=9, color=MUTED,
                         arrowprops=dict(arrowstyle="->", color=MUTED, linewidth=0.9))

    figure.suptitle("Where you are changes which species are plausible — "
                    "never whether it was a bat at all",
                    fontsize=15, fontweight="bold")
    figure.tight_layout(rect=(0, 0.03, 1, 0.93))
    _finish(figure, path,
            "illustrative scores · weights are the real ones: 1.0 in range, "
            "0.5 unmapped, 0.01 out of range · openbat.app")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path,
                        default=Path.home() / "Desktop" / "OpenBat AutoID Figures")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    pipeline(args.out / "autoid-pipeline.png")
    pulses(args.out / "autoid-pulses.png")
    priors(args.out / "autoid-priors.png")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
