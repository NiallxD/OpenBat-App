#!/usr/bin/env python3
"""BatDetect2's own detector, over the same library the app arm sees.

This is the reference arm of the comparison (see README.md). It runs the full
published pipeline — audio loading, preprocessing, model, non-maximum
suppression, peak extraction — through BatDetect2's `BatDetect2API`, so nothing
about detection or decoding is re-implemented here. Every detection BatDetect2
will emit at its own default threshold (0.01) is written out; thresholding is
left to `compare.py`, so a threshold sweep costs no extra inference.

Output is JSON lines, one object per recording, appended as it goes: a run over
a thousand files is restartable, and a crash keeps what it had.

Usage:
    python3 run_reference.py --input ~/Downloads/BatRecordings \\
        --output results/run1 \\
        --batdetect2-source "~/Programming/Misc Projects/BatDetect2/batdetect2"
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

# Forced onto the CPU. BatDetect2's peak extraction calls `aten::take`, which
# Metal does not implement, so an MPS run dies partway through postprocessing —
# and CPU is also the arithmetic the Core ML arm is closest to. Lightning takes
# the accelerator through the Trainer, which `batdetect2.inference.batch` builds
# itself with no way to pass one in, so the default is patched here.
def _force_cpu() -> None:
    import lightning.pytorch as pl

    original = pl.Trainer.__init__

    def patched(self, *args, **kwargs):
        kwargs.setdefault("accelerator", "cpu")
        kwargs.setdefault("devices", 1)
        original(self, *args, **kwargs)

    pl.Trainer.__init__ = patched


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", required=True, type=Path,
                   help="directory of .wav recordings, searched recursively")
    p.add_argument("--output", required=True, type=Path,
                   help="directory for reference.jsonl")
    p.add_argument("--batdetect2-source", type=Path, default=None,
                   help="BatDetect2 v2 checkout (only needed if it is not importable)")
    p.add_argument("--checkpoint", default="uk_same",
                   help="checkpoint alias or path (default: uk_same, the UK model OpenBat ships)")
    p.add_argument("--limit", type=int, default=None, help="stop after N files")
    p.add_argument("--batch-size", type=int, default=4,
                   help="files per inference batch (default 4)")
    p.add_argument("--detection-threshold", type=float, default=None,
                   help="override BatDetect2's own 0.01; leave unset so compare.py can sweep")
    p.add_argument("--keep-threshold", type=float, default=0.05,
                   help="detections below this score are counted but not written out "
                        "(default 0.05). BatDetect2 emits its top-k per clip down to 0.01, "
                        "which is ~450 detections per 5 s recording and a gigabyte of JSON "
                        "over this library; nothing below 0.05 survives any threshold "
                        "compare.py would sweep")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    if args.batdetect2_source:
        sys.path.insert(0, str(args.batdetect2_source.expanduser() / "src"))

    _force_cpu()
    from batdetect2.api_v2 import BatDetect2API

    input_dir = args.input.expanduser()
    files = sorted(p for p in input_dir.rglob("*.wav") if not p.name.startswith("."))
    if args.limit:
        files = files[: args.limit]
    if not files:
        print(f"no .wav files under {input_dir}", file=sys.stderr)
        return 1

    out_dir = args.output.expanduser()
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "reference.jsonl"

    done: set[str] = set()
    if out_path.exists():
        with out_path.open() as handle:
            for line in handle:
                try:
                    done.add(json.loads(line)["file"])
                except (json.JSONDecodeError, KeyError):
                    continue
    pending = [f for f in files if str(f.relative_to(input_dir)) not in done]
    print(f"{len(files)} files, {len(done)} already done, {len(pending)} to go")

    api = BatDetect2API.from_checkpoint(args.checkpoint)
    class_names = list(api.targets.class_names)
    (out_dir / "reference_meta.json").write_text(json.dumps({
        "arm": "batdetect2_python",
        "checkpoint": args.checkpoint,
        "class_names": class_names,
        "detection_threshold": args.detection_threshold,
        "keep_threshold": args.keep_threshold,
        "input": str(input_dir),
        "files": len(files),
    }, indent=2))

    started = time.time()
    written = 0
    with out_path.open("a") as sink:
        for chunk_start in range(0, len(pending), args.batch_size):
            chunk = pending[chunk_start : chunk_start + args.batch_size]
            predictions = api.process_files(
                [str(p) for p in chunk],
                batch_size=args.batch_size,
                detection_threshold=args.detection_threshold,
            )
            # One ClipDetections per CLIP, not per file: BatDetect2 cuts every
            # recording into 0.5 s clips and predicts on each. Detection times
            # are already offset to the recording's own timeline
            # (`to_clip_detections` adds `clip.start_time`), so regrouping by
            # recording path is all that is needed — but doing it by position
            # in the list, as if there were one result per file, silently
            # attributes one clip's detections to the wrong recording.
            grouped: dict[str, list] = {}
            for clip_detections in predictions:
                key = str(clip_detections.clip.recording.path)
                grouped.setdefault(key, []).append(clip_detections)
            for path in chunk:
                clips = grouped.get(str(path.resolve()), grouped.get(str(path), []))
                sink.write(json.dumps(record(path, input_dir, clips, class_names,
                                             args.keep_threshold)) + "\n")
                written += 1
            sink.flush()
            elapsed = time.time() - started
            print(f"[reference] {written}/{len(pending)} files, "
                  f"{written / elapsed:.2f} files/s", flush=True)

    print(f"wrote {written} records to {out_path}")
    return 0


def record(path: Path, root: Path, clips: list, class_names: list[str],
           keep_threshold: float) -> dict:
    """One recording's detections, flattened across its clips to plain JSON.

    Species codes are upper-cased to match OpenBat's own spelling of
    BatDetect2's six-letter codes; the order is the checkpoint's, which is the
    same order `BatDetect2Classifier.classNames` hard-codes.
    """
    detections = []
    duration = None
    covered = 0.0
    dropped = 0
    for clip_detections in clips:
        recording = clip_detections.clip.recording
        duration = float(getattr(recording, "duration", 0.0)) or duration
        covered = max(covered, float(clip_detections.clip.end_time))
        for det in clip_detections.detections:
            if float(det.detection_score) < keep_threshold:
                dropped += 1
                continue
            box = det.geometry.coordinates  # [start_time, low_freq, end_time, high_freq]
            scores = [float(v) for v in det.class_scores]
            best = max(range(len(scores)), key=lambda i: scores[i]) if scores else None
            detections.append({
                "start_seconds": float(box[0]),
                "end_seconds": float(box[2]),
                "low_hz": float(box[1]),
                "high_hz": float(box[3]),
                "detection_score": float(det.detection_score),
                "species": class_names[best].upper() if best is not None else None,
                "class_score": scores[best] if best is not None else 0.0,
                "raw": {class_names[i].upper(): scores[i] for i in range(len(scores))},
            })
    detections.sort(key=lambda d: d["start_seconds"])
    return {
        "file": str(path.relative_to(root)),
        "duration_seconds": duration,
        # What BatDetect2 actually looked at. Its clipper discards the trailing
        # partial clip (`discard_empty`), so the last ~0.5 s of a 5 s recording
        # is never seen — and the app arm, which streams the whole file, does
        # see it. compare.py truncates to this so the two arms are scored over
        # the same audio.
        "covered_seconds": covered,
        "clips": len(clips),
        "detections_below_keep_threshold": dropped,
        "detections": detections,
    }


if __name__ == "__main__":
    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
    raise SystemExit(main())
