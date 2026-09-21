#!/usr/bin/env python3
"""Stitch the bundled UK demo clip (`OpenBat/Demo/uk_demo_bats.wav`).

WHY THIS EXISTS
---------------
The clip it replaces was 500 kHz, and demo mode plays a file at its own rate.
`ModelInputSpec.nativeSampleRate` only lets a pulse be classified at 384 kHz, so
that clip detected calls, identified none of them, and wrote nothing to the
classifier log — which is indistinguishable from a broken classifier. Anything
stitched here must stay at 384 kHz.

SOURCE AUDIO
------------
BatDetect2's own `example_data/audio/`, which is CC BY-NC 4.0 like the rest of
that repo (see THIRD-PARTY.md). Two of its three examples are already 384 kHz:

  20180627_215323-RHIFER-LR_0_0.5.wav   greater horseshoe, ~82 kHz CF, quiet
  20180530_213516-EPTSER-LR_0_0.5.wav   serotine, four calls, loud

Both were checked through the app's real BatDetect2 path before being used here:
RHIFER identifies as RHIFER at 0.88, EPTSER as CNESER at 0.67 (the serotine's
current name — Eptesicus serotinus became Cnephaeus serotinus).

SHAPE, AND WHY
--------------
Each clip repeats with a gap LONGER than the 1.1 s pass timeout
(`AutoIDSettings.defaultPassTimeoutSeconds`), so every repeat closes as its own
pass instead of merging into one long one — twelve passes to look at, not two.
The gap is quiet audio taken from the source clip itself rather than digital
silence: a hard-zero gap collapses the detector's noise floor estimate and makes
the next call arrive against an unnaturally quiet background.

LEVELS ARE LEFT ALONE (Niall, 2026-09-20)
-----------------------------------------
An earlier version of this script peak-normalised both sources to 0.6. Do not do
that again. The horseshoe was recorded from much further away and has about 27 dB
of call-to-noise inherently, so an 18x gain cannot improve that ratio — it only
lifts the recording's own hiss to -40 dBFS and puts an 18 dB level step in the
middle of the file. Both sources go in at their native level, where their
backgrounds happen to sit within 2 dB of each other anyway.

The consequence to watch: `PulseDetector`'s trigger is an ABSOLUTE level on a
fixed -90..-20 dB scale, not a signal-to-noise ratio, so a quiet recording may
simply not trip it. If the horseshoe half of this clip detects nothing, that is
the reason, and the answer is a better recording rather than a bigger number.
"""

from __future__ import annotations

import argparse
import wave
from pathlib import Path

import numpy as np

RATE = 384_000
GAP_SECONDS = 1.5   # > AutoIDSettings.defaultPassTimeoutSeconds (1.1)
LEAD_SECONDS = 1.5  # noise before the first call, for the noise-floor estimate to settle
REPEATS = 6


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

    Shaped noise, not a loop. Tiling one quiet window — which this script used to
    do — puts a periodic artifact under the whole clip: 1.5 s of a 49 ms segment
    is that segment thirty times over, and it reads on a spectrogram, and it is
    audible. Here white noise is filtered to the average magnitude spectrum of
    the recording's own background and scaled to its level, so every gap is
    different and all of them sound like the recording they came from.
    """
    n = int(seconds * RATE)
    # Average magnitude spectrum of the real background, over whatever windows fit.
    window = min(4096, len(noise))
    frames = [noise[i : i + window] for i in range(0, len(noise) - window + 1, window // 2)]
    shape = np.mean([np.abs(np.fft.rfft(f * np.hanning(window))) for f in frames], axis=0)

    spectrum = np.fft.rfft(rng.standard_normal(n))
    # Stretch the measured shape across this gap's (longer) spectrum.
    stretched = np.interp(np.linspace(0, 1, len(spectrum)), np.linspace(0, 1, len(shape)), shape)
    out = np.fft.irfft(spectrum * stretched, n).astype(np.float32)
    target = float(np.sqrt(np.mean(noise**2)))
    actual = float(np.sqrt(np.mean(out**2)))
    return out * (target / actual) if actual > 0 else out


def block(path: Path, rng: np.random.Generator) -> np.ndarray:
    """One species: its clip, at the level it was recorded at, `REPEATS` times."""
    clip = read_mono(path)
    if float(np.abs(clip).max()) <= 0:
        raise SystemExit(f"{path.name} is silent")
    noise = quietest_window(clip)
    return np.concatenate(
        [np.concatenate([clip, gap(noise, GAP_SECONDS, rng)]) for _ in range(REPEATS)]
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--first", type=Path, required=True, help="384 kHz source, repeated first")
    parser.add_argument("--second", type=Path, required=True, help="384 kHz source, repeated second")
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).parent.parent / "OpenBat/Demo/uk_demo_bats.wav")
    args = parser.parse_args()

    # Seeded: rebuilding from the same sources gives the same file, so a change
    # heard in the app is a change somebody made.
    rng = np.random.default_rng(20260920)
    first, second = block(args.first, rng), block(args.second, rng)
    lead_noise = quietest_window(read_mono(args.first))
    audio = np.concatenate([gap(lead_noise, LEAD_SECONDS, rng), first, second])

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
    print(f"wrote {args.output} — {len(pcm) / RATE:.1f} s, {RATE} Hz, peak {ceiling:.3f}")


if __name__ == "__main__":
    main()
