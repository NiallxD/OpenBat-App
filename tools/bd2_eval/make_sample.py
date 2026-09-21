#!/usr/bin/env python3
"""Builds a stratified sample of the library as a tree of symlinks.

Why symlinks rather than a file list: the Swift harness takes a directory and
walks it, and the path each record is filed under is relative to that
directory. Mirroring the walk subdirectories means a sample's keys are
identical to the full library's, so its records line up with a reference run
made over everything — and no Xcode rebuild is needed to change the sample.

Deterministic: same seed, same files, so two threshold runs are scored over
exactly the same audio.

Usage:
    python3 make_sample.py --input ~/Downloads/BatRecordings \\
        --output sample --per-group 25
"""
from __future__ import annotations

import argparse
import random
from collections import defaultdict
from pathlib import Path


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--input", required=True, type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--per-group", type=int, default=25,
                   help="recordings per immediate subdirectory (one bat walk each)")
    p.add_argument("--seed", type=int, default=20260921)
    args = p.parse_args()

    root = args.input.expanduser().resolve()
    out = args.output.expanduser().resolve()
    files = sorted(f for f in root.rglob("*.wav") if not f.name.startswith("."))
    groups: dict[str, list[Path]] = defaultdict(list)
    for f in files:
        groups[f.relative_to(root).parts[0]].append(f)

    rng = random.Random(args.seed)
    picked = 0
    for group, members in sorted(groups.items()):
        chosen = sorted(rng.sample(members, min(args.per_group, len(members))))
        (out / group).mkdir(parents=True, exist_ok=True)
        for source in chosen:
            link = out / source.relative_to(root)
            if link.is_symlink() or link.exists():
                link.unlink()
            link.symlink_to(source)
            picked += 1
        print(f"{group}: {len(chosen)} of {len(members)}")
    print(f"{picked} recordings linked under {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
