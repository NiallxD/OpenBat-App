#!/usr/bin/env python3
"""Stitch the multi-species UK demo clip (`OpenBat/Demo/Demo-UK-Species-2026.wav`).

WHY THIS EXISTS
---------------
`make_uk_demo_clip.py` builds a two-species clip from BatDetect2's own example
recordings. Two species is enough to prove the pipeline runs; it is not enough
to show what the app is FOR, which is telling one bat from another. This clip
plays ten UK species back to back, one pass each.

SOURCE AUDIO
------------
Niall's own bat-walk recordings (`~/Downloads/BatRecordings`, 927 × 5 s at
384 kHz), the same library `tools/bd2_eval/` scores against. They are his, so
nothing here is licensed from anybody, and they are already at the one sample
rate the classifier can work at (`ModelInputSpec.nativeSampleRate`, 384 kHz) —
demo mode plays a file at its own rate, so a clip at any other rate detects
calls and names none of them.

HOW THE WINDOWS WERE CHOSEN
---------------------------
From `tools/bd2_eval/results/run1/reference.jsonl` — BatDetect2's own pipeline
over the whole library. For each species, the 2 s window that holds the most
detections of it at detection ≥ 0.4 AND class ≥ 0.4, and NO confident
detection of any other species. That last condition is the point: a window
where two bats overlap makes one pass with two answers in it, and a demo that
shows the app being ambiguous about a bat it got right is worse than no demo.

**These are BatDetect2's labels, not ground truth.** Nobody has confirmed by
ear or by hand that the Myotis blocks are the Myotis the model says. The
scores in the table below are what the reference pipeline gave, and the two
Myotis entries (0.52, 0.66) are the weak ones to distrust first.

WHAT IS NOT IN HERE, AND WHY
----------------------------
- **Lesser horseshoe (RHIHIP).** Present in five recordings, never once
  without a pipistrelle over the top of it. There is no clean window to cut.
- **NYCLEI, PIPNAT, MYOALC, MYOBRA, MYOBEC, PLEAUS.** No file in the library
  has five confident detections of them at ≥ 85% purity.

LEVELS ARE LEFT ALONE
---------------------
Same rule as `make_uk_demo_clip.py`, and it matters more here: the ten sources
span 32 dB of peak level (pipistrelle −8 dBFS, Natterer's −40). Normalising
would flatten a real difference — a bat 5 m away and a bat 40 m away — into a
uniform loudness the app will never meet in the field, and would lift the
quiet recordings' own hiss with it.

The consequence to watch is the one that script names: `PulseDetector`'s
trigger is an ABSOLUTE level on a fixed −90…−20 dB scale (`amplitudeThreshold`
0.5 → −55 dB), not a signal-to-noise ratio. If the Natterer's or the greater
horseshoe block detects nothing in the app, that is why, and the fix is a
louder recording of that species rather than a gain on this one.
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

RATE = 384_000
WINDOW_SECONDS = 2.0
GAP_SECONDS = 1.5   # > AutoIDSettings.defaultPassTimeoutSeconds (1.1), so every block is its own pass
LEAD_SECONDS = 1.5  # noise before the first call, for the noise-floor estimate to settle

# species, source file (relative to --library), window start (s), reference score
MANIFEST = [
    ("PIPPIP", "Bat_Walk_01_09_2026/Device000_20260901_203920.wav", 2.45, 0.823),
    ("PIPPYG", "Bat_Walk_01_09_2026/Device000_20260901_203503.wav", 2.70, 0.864),
    ("NYCNOC", "Bat_Walk_01_09_2026/Device000_20260901_202143.wav", 0.00, 0.764),
    ("CNESER", "Bat_Walk_01_09_2026/Device000_20260901_202220.wav", 0.15, 0.702),
    ("BARBAR", "Bat_Walk_25_07_2026/Device000_20260725_121759.wav", 0.00, 0.755),
    ("PLEAUR", "Bat_Walk_06_07_2026/Device000_20260706_222648.wav", 0.05, 0.727),
    ("MYODAU", "Bat_Walk_14_09_2026/Device000_20260914_202747.wav", 0.00, 0.668),
    ("MYONAT", "Bat_Walk_14_09_2026/Device000_20260914_202054.wav", 1.35, 0.659),
    ("MYOMYS", "Bat_Walk_01_09_2026/Device000_20260901_202254.wav", 0.00, 0.522),
    ("RHIFER", "Bat_Walk_10_07_2026/Device000_20260710_181325.wav", 0.60, 0.903),
]


def read_mono(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        if w.getframerate() != RATE:
            raise SystemExit(f"{path.name} is {w.getframerate()} Hz — this clip must stay at {RATE}")
        if w.getsampwidth() != 2:
            raise SystemExit(f"{path.name} is not 16-bit")
        data = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float32) / 32768
        if w.getnchannels() > 1:
            data = data.reshape(-1, w.getnchannels()).mean(axis=1)
    return data


def quietest_window(x: np.ndarray, seconds: float = 0.05) -> np.ndarray:
    """The least energetic stretch of `x` — the clip's own background."""
    n = int(seconds * RATE)
    step = max(1, n // 5)
    starts = range(0, max(1, len(x) - n), step)
    best = min(starts, key=lambda s: float(np.mean(x[s : s + n] ** 2)))
    return x[best : best + n]


def gap(noise: np.ndarray, seconds: float, rng: np.random.Generator) -> np.ndarray:
    """`seconds` of background that never repeats itself.

    Shaped noise, not a loop: tiling one quiet window puts an audible periodic
    artifact under the gap, and it reads on a spectrogram. White noise filtered
    to the average magnitude spectrum of the recording's own background, scaled
    to its level. Verbatim from `make_uk_demo_clip.py` — if one changes, change
    both, or the two demo clips stop sounding like each other.
    """
    n = int(seconds * RATE)
    window = min(4096, len(noise))
    frames = [noise[i : i + window] for i in range(0, len(noise) - window + 1, window // 2)]
    shape = np.mean([np.abs(np.fft.rfft(f * np.hanning(window))) for f in frames], axis=0)

    spectrum = np.fft.rfft(rng.standard_normal(n))
    stretched = np.interp(np.linspace(0, 1, len(spectrum)), np.linspace(0, 1, len(shape)), shape)
    out = np.fft.irfft(spectrum * stretched, n).astype(np.float32)
    target = float(np.sqrt(np.mean(noise**2)))
    actual = float(np.sqrt(np.mean(out**2)))
    return out * (target / actual) if actual > 0 else out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--library", type=Path,
                        default=Path.home() / "Downloads/BatRecordings",
                        help="root of the bat-walk recordings the manifest points into")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).parent.parent / "OpenBat/Demo/Demo-UK-Species-2026.wav")
    args = parser.parse_args()

    # Seeded: rebuilding from the same sources gives the same file, so a change
    # heard in the app is a change somebody made.
    rng = np.random.default_rng(20260921)
    n = int(WINDOW_SECONDS * RATE)

    pieces: list[np.ndarray] = []
    for index, (species, relative, start, score) in enumerate(MANIFEST):
        source = read_mono(args.library / relative)
        offset = int(start * RATE)
        clip = source[offset : offset + n]
        if len(clip) < n:
            raise SystemExit(f"{relative}: window {start}+{WINDOW_SECONDS}s runs past the end")
        if float(np.abs(clip).max()) <= 0:
            raise SystemExit(f"{relative}: window is silent")
        noise = quietest_window(source)
        # The gap BEFORE each block is cut from that block's own recording, so
        # the background the detector settles on is the one the calls arrive over.
        lead = LEAD_SECONDS if index == 0 else GAP_SECONDS
        pieces += [gap(noise, lead, rng), clip]
        peak = 20 * np.log10(float(np.abs(clip).max()))
        print(f"  {species}  {peak:6.1f} dBFS peak   BD2 {score:.3f}   {relative} @ {start:.2f}s")

    audio = np.concatenate(pieces)
    ceiling = float(np.abs(audio).max())
    if ceiling > 0.99:
        raise SystemExit(f"stitched clip would clip (peak {ceiling:.3f})")

    pcm = np.clip(audio * 32767, -32768, 32767).astype("<i2")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(args.output), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"wrote {args.output} — {len(pcm) / RATE:.1f} s, {RATE} Hz, "
          f"{len(MANIFEST)} species, peak {ceiling:.3f}")


if __name__ == "__main__":
    main()
