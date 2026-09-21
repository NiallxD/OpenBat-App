#!/usr/bin/env python3
"""Compare OpenBat's Swift BatDetect2 preprocessing against the reference pipeline.

Oisin Mac Aodha (BatDetect2, 2026-09-14): "The correct pre-processing is essential to
make BD2 work. Best thing to do would be to test that your app generates the exact
same outputs as BD2's Python code." This is that test.

The two sides are handed the *same* float32 samples — this script cuts the window from
the WAV and writes it to a raw .f32 file — so a disagreement can only come from the
transform, never from differing input.

    ./build.sh                       # compile the Swift dumper once
    python3 compare.py --input capture.wav --batdetect2-source ~/src/batdetect2 \
        --output ../../../benchmarks/batdetect2-preprocessing-parity.json

Run it inside the official BatDetect2 v2 environment (it needs torch, soundfile and
the checkpoint). Mirrors OpenBat-Android's compare_batdetect2_preprocessing.py so the
two ports are judged by the same numbers.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np

# BatDetect2's expected rate, and OpenBat's capture rate. Kept here rather than read
# from the Swift source so a silent change on either side shows up as a failure.
TARGET_RATE = 256_000
WINDOW_SECONDS = 0.256
SHAPE = (128, 256)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True, help="WAV to cut the window from")
    parser.add_argument("--start-seconds", type=float, default=0.5)
    parser.add_argument("--batdetect2-source", type=Path, required=True,
                        help="checkout of macaodha/batdetect2 holding batdetect2_uk_same.ckpt")
    parser.add_argument("--dump-bin", type=Path, default=Path(__file__).parent / "dump_tensor")
    parser.add_argument("--output", type=Path, help="write the JSON report here as well as stdout")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    try:
        import soundfile as sf
        import torch
        from batdetect2.train import load_model_from_checkpoint
    except ImportError as exc:
        raise SystemExit("run this script in the official BatDetect2 environment") from exc

    if not args.dump_bin.exists():
        raise SystemExit(f"{args.dump_bin} not built — run ./build.sh first")

    checkpoint = args.batdetect2_source / "src/batdetect2/models/checkpoints/batdetect2_uk_same.ckpt"
    if not checkpoint.exists():
        raise SystemExit(f"checkpoint not found at {checkpoint}")

    audio, sample_rate = sf.read(args.input, dtype="float32", always_2d=True)
    mono = audio.mean(axis=1)
    start = round(args.start_seconds * sample_rate)
    count = round(WINDOW_SECONDS * sample_rate)
    capture = np.ascontiguousarray(mono[start : start + count])
    if capture.size != count:
        raise SystemExit("selected 256 ms window extends beyond the input WAV")

    # Two things can be measured, and they are worth keeping apart. At 256 kHz the
    # numbers are the spectrogram transform alone. At any other rate both sides must
    # resample first — OpenBat with PolyphaseResampler, the reference with
    # scipy.signal.resample_poly, which PolyphaseResampler deliberately does not match
    # bit-for-bit (see its NAME NOTICE) — so the error floor is higher by design.
    if sample_rate == TARGET_RATE:
        reference_input = capture
        stage = "transform only (native 256 kHz)"
    else:
        from math import gcd
        from scipy.signal import resample_poly

        divisor = gcd(int(TARGET_RATE), int(sample_rate))
        reference_input = resample_poly(capture, TARGET_RATE // divisor, sample_rate // divisor
                                        ).astype("float32")
        stage = f"resample {sample_rate} Hz to 256 kHz, then transform"

    model, _ = load_model_from_checkpoint(checkpoint)
    with torch.inference_mode():
        reference = model.preprocessor(torch.from_numpy(reference_input.copy())).numpy()
    if reference.shape != SHAPE:
        raise SystemExit(f"unexpected reference tensor shape: {reference.shape}")

    with tempfile.TemporaryDirectory(prefix="openbat-bd2-parity-") as temporary:
        capture_path = Path(temporary) / "capture.f32"
        tensor_path = Path(temporary) / "swift.f32"
        capture.tofile(capture_path)
        subprocess.run(
            [str(args.dump_bin), "--input", str(capture_path),
             "--output", str(tensor_path), "--rate", str(sample_rate)],
            check=True, capture_output=True, text=True,
        )
        native = np.fromfile(tensor_path, dtype="<f4").reshape(SHAPE)

    difference = native - reference
    report = {
        "schema_version": 1,
        "port": "openbat-ios-swift",
        "backend": "batdetect2-uk-same-v2",
        "input": str(args.input),
        "start_seconds": args.start_seconds,
        "sample_rate_hz": int(sample_rate),
        "stage": stage,
        "shape": list(SHAPE),
        "mean_absolute_error": float(np.mean(np.abs(difference))),
        "maximum_absolute_error": float(np.max(np.abs(difference))),
        "root_mean_square_error": float(np.sqrt(np.mean(difference**2))),
        "pearson_correlation": float(np.corrcoef(native.ravel(), reference.ravel())[0, 1]),
        "reference_mean": float(reference.mean()),
        "native_mean": float(native.mean()),
        "note": ("This compares the tensor handed to the model, not model accuracy. "
                 "The two sides are given identical input samples."),
    }
    serialized = json.dumps(report, indent=2) + "\n"
    print(serialized, end="")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(serialized)


if __name__ == "__main__":
    main()
