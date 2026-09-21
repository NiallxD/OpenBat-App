#!/usr/bin/env python3
"""The app's own Core ML export, run on the host over the app's own tensors.

WHY THIS EXISTS RATHER THAN USING THE SIMULATOR'S ANSWER
--------------------------------------------------------
The Swift harness classifies each pulse in-process, which is the ideal
measurement — the shipping code, end to end. On a simulator it is also wrong:
Core ML there returns an all-zero output for `.cpuOnly` and `.cpuAndGPU`, and
the app asks for `.all`, whose behaviour is not stable across runs. A whole
927-file run came back with every class probability exactly 0.0 (2026-09-21),
which is not a quiet inaccuracy — it is no computation at all, and it would
have scored as "OpenBat can identify nothing".

So the split is: everything up to the model's input comes from the app's real
Swift code — `PulseDetector` finds the calls, `ClassifierAnalysis`'s windowing
cuts them, `BatDetect2SpectrogramRenderer` builds the tensor — and the tensor
is handed to the same `BatDetect2.mlpackage` the app ships, executed here by
macOS Core ML. On a real spectrogram this agrees with the PyTorch checkpoint
(0.1738 against 0.1750 on the first pulse of the library), so the host's Core
ML is computing; the simulator's was not.

The one thing it does not measure is iOS Core ML's own arithmetic on device.
For that, run the Swift harness on hardware — `run_app_arm.sh` with a device
destination — and use its `app_arm.jsonl` scores directly.

Reads the tensors dumped with OPENBAT_EVAL_TENSORS=1; writes the same schema
as run_pytorch_arm.py, so compare.py can take either as the app's scores.

Usage:
    python3 run_coreml_arm.py --results results/run1
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

OUT_H = 128
OUT_W = 256
TENSOR_FLOATS = OUT_H * OUT_W

# BatDetect2's class order, as the checkpoint stores it and
# BatDetect2Classifier.classNames hard-codes it.
CLASS_NAMES = [
    "MYOMYS", "MYOALC", "CNESER", "PIPNAT", "BARBAR", "MYONAT", "MYODAU",
    "MYOBRA", "PIPPIP", "MYOBEC", "PIPPYG", "RHIHIP", "NYCLEI", "RHIFER",
    "PLEAUR", "NYCNOC", "PLEAUS",
]


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--results", required=True, type=Path,
                   help="directory holding app_arm.jsonl and tensors/")
    p.add_argument("--model", type=Path,
                   default=Path(__file__).resolve().parent.parent.parent
                   / "OpenBat" / "Classifier" / "BatDetect2.mlpackage",
                   help="the .mlpackage the app bundles")
    p.add_argument("--delete-tensors", action="store_true",
                   help="remove each blob once consumed (the PyTorch arm needs them too, "
                        "so pass this only on the last arm you run)")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    import coremltools as ct

    results = args.results.expanduser()
    app_arm = results / "app_arm.jsonl"
    tensor_dir = results / "tensors"
    if not app_arm.exists() or not tensor_dir.exists():
        print("run the Swift harness with OPENBAT_EVAL_TENSORS=1 first", file=sys.stderr)
        return 1

    model = ct.models.MLModel(str(args.model))
    out_path = results / "coreml_arm.jsonl"
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
            pulses = record.get("pulses", [])
            if not pulses:
                sink.write(json.dumps({"file": name, "pulses": []}) + "\n")
                written += 1
                continue
            blob = tensor_dir / (name.replace("/", "_") + ".f32")
            if not blob.exists():
                print(f"[coreml] no tensors for {name}, skipping", file=sys.stderr)
                continue
            raw = np.fromfile(blob, dtype=np.float32)
            if raw.size != len(pulses) * TENSOR_FLOATS:
                print(f"[coreml] {name}: {raw.size // TENSOR_FLOATS} tensors for "
                      f"{len(pulses)} pulses — stale dump, skipping", file=sys.stderr)
                continue
            stack = raw.reshape(len(pulses), 1, OUT_H, OUT_W)

            scored = []
            for i in range(len(stack)):
                out = model.predict({"input": stack[i : i + 1]})
                detection = np.asarray(out["detection_probs"]).reshape(-1)
                classes = np.asarray(out["class_probs"]).reshape(len(CLASS_NAMES), -1)
                # Exactly BatDetect2Classifier's read: the strongest detection
                # cell, then its class vector. Its bounding boxes are discarded
                # by the app, so they are discarded here too.
                cell = int(detection.argmax())
                vector = classes[:, cell]
                best = int(vector.argmax())
                scored.append({
                    "onset_seconds": pulses[i]["onset_seconds"],
                    "species": CLASS_NAMES[best],
                    "confidence": float(vector[best]),
                    "detection_prob": float(detection[cell]),
                    "raw": {CLASS_NAMES[c]: float(vector[c]) for c in range(len(CLASS_NAMES))},
                })

            sink.write(json.dumps({"file": name, "pulses": scored}) + "\n")
            sink.flush()
            written += 1
            if args.delete_tensors:
                blob.unlink()
            if written % 50 == 0:
                print(f"[coreml] {written} files", flush=True)

    print(f"wrote {written} records to {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
