#!/usr/bin/env python3
"""The attribution arm: OpenBat's pulses and OpenBat's preprocessing, BatDetect2's weights.

Why a third arm exists. A gap between the app and the reference could come from
either of two places — the app finds different calls, or the app's Core ML
export answers differently from the PyTorch checkpoint it was converted from.
The second is known to be real: on identical input the converted model reported
0.883 where PyTorch said 0.711 (2026-09-20, `batdetect2-parity-harness`). Run
only two arms and those two causes are indistinguishable.

This arm removes the export from the picture. It takes the exact 128×256
tensors the app handed Core ML — dumped by the Swift harness with
`OPENBAT_EVAL_TENSORS=1`, from the same windows, through the same
preprocessing, which is already parity-verified to ~1e-07 — and runs the
PyTorch checkpoint over them, reading the result the way
`BatDetect2Classifier` reads Core ML's: the cell with the highest detection
probability, then that cell's class distribution.

So:
  app arm  vs  this  = what the Core ML conversion costs
  this     vs  reference = what OpenBat's own call-finding and windowing cost

Usage:
    python3 run_pytorch_arm.py --results results/run1 \\
        --batdetect2-source "~/Programming/Misc Projects/BatDetect2/batdetect2"
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

# The app's tensor shape, from BatDetect2SpectrogramRenderer.
OUT_H = 128
OUT_W = 256
TENSOR_FLOATS = OUT_H * OUT_W


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--results", required=True, type=Path,
                   help="directory holding app_arm.jsonl and tensors/ from the Swift harness")
    p.add_argument("--batdetect2-source", type=Path, default=None,
                   help="BatDetect2 v2 checkout (only needed if it is not importable)")
    p.add_argument("--checkpoint", default="uk_same", help="checkpoint alias or path")
    p.add_argument("--batch-size", type=int, default=32)
    p.add_argument("--delete-tensors", action="store_true",
                   help="remove each tensor blob once consumed; the dump is ~130 KB per "
                        "pulse and this library produces thousands")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if args.batdetect2_source:
        sys.path.insert(0, str(args.batdetect2_source.expanduser() / "src"))

    import torch
    from batdetect2.api_v2 import BatDetect2API

    results = args.results.expanduser()
    app_arm = results / "app_arm.jsonl"
    tensor_dir = results / "tensors"
    if not app_arm.exists():
        print(f"{app_arm} not found — run the Swift harness first", file=sys.stderr)
        return 1
    if not tensor_dir.exists():
        print(f"{tensor_dir} not found — re-run the Swift harness with OPENBAT_EVAL_TENSORS=1",
              file=sys.stderr)
        return 1

    api = BatDetect2API.from_checkpoint(args.checkpoint)
    model = api.model.detector if hasattr(api.model, "detector") else api.model
    model.eval()
    class_names = [name.upper() for name in api.targets.class_names]

    out_path = results / "pytorch_arm.jsonl"
    done: set[str] = set()
    if out_path.exists():
        with out_path.open() as handle:
            for line in handle:
                try:
                    done.add(json.loads(line)["file"])
                except (json.JSONDecodeError, KeyError):
                    continue

    written = 0
    with out_path.open("a") as sink:
        for line in app_arm.open():
            record = json.loads(line)
            name = record["file"]
            if name in done:
                continue
            blob = tensor_dir / (name.replace("/", "_") + ".f32")
            pulses = record.get("pulses", [])
            if not pulses:
                sink.write(json.dumps({"file": name, "pulses": []}) + "\n")
                written += 1
                continue
            if not blob.exists():
                print(f"[pytorch] no tensors for {name}, skipping", file=sys.stderr)
                continue

            raw = np.fromfile(blob, dtype=np.float32)
            expected = len(pulses) * TENSOR_FLOATS
            if raw.size != expected:
                # The Swift side writes one tensor per classified pulse, in
                # order, and pads a failed render rather than skipping it, so a
                # size mismatch means the two files are from different runs —
                # scoring them against each other would silently pair the wrong
                # pulse with the wrong tensor.
                print(f"[pytorch] {name}: {raw.size // TENSOR_FLOATS} tensors for "
                      f"{len(pulses)} pulses — stale dump, skipping", file=sys.stderr)
                continue
            stack = raw.reshape(len(pulses), 1, OUT_H, OUT_W)

            scored = []
            with torch.no_grad():
                for start in range(0, len(stack), args.batch_size):
                    batch = torch.from_numpy(stack[start : start + args.batch_size])
                    output = model(batch)
                    detection = output.detection_probs.numpy()   # (B, 1, H, W)
                    classes = output.class_probs.numpy()         # (B, C, H, W)
                    for i in range(detection.shape[0]):
                        # The same read BatDetect2Classifier performs on Core
                        # ML's output: strongest detection cell, then that
                        # cell's class vector. BatDetect2's own postprocessing
                        # (NMS, top-k, bounding boxes) is deliberately not used
                        # here — this arm is the app's pipeline with different
                        # weights, not the reference pipeline.
                        flat = detection[i, 0].reshape(-1)
                        cell = int(flat.argmax())
                        vector = classes[i].reshape(classes.shape[1], -1)[:, cell]
                        best = int(vector.argmax())
                        scored.append({
                            "species": class_names[best],
                            "confidence": float(vector[best]),
                            "detection_prob": float(flat[cell]),
                            "raw": {class_names[c]: float(vector[c])
                                    for c in range(len(class_names))},
                        })

            merged = []
            for pulse, score in zip(pulses, scored):
                merged.append({
                    "onset_seconds": pulse["onset_seconds"],
                    "species": score["species"],
                    "confidence": score["confidence"],
                    "detection_prob": score["detection_prob"],
                    "raw": score["raw"],
                })
            sink.write(json.dumps({"file": name, "pulses": merged}) + "\n")
            sink.flush()
            written += 1
            if args.delete_tensors:
                blob.unlink()
            if written % 25 == 0:
                print(f"[pytorch] {written} files", flush=True)

    print(f"wrote {written} records to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
