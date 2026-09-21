#!/usr/bin/env python3
"""Scores the arms against each other and writes the numerical report.

There are no species labels on this library, so nothing here is accuracy in
the absolute sense. BatDetect2's own full pipeline is the reference, and every
number says how far OpenBat's answer is from BatDetect2's answer on the same
audio — which is the question the app has to answer anyway, since it is
BatDetect2's model it ships.

Three things are measured, in descending order of how much they matter to
someone using the app:

1. FILE VERDICT. One species per recording from each arm, the way a user reads
   the app's list. Agreement, top-1 and top-3, a confusion matrix, and per
   species where the disagreement is.
2. CALL DETECTION. Does OpenBat's trigger find the calls BatDetect2 finds?
   Matched on time, since OpenBat discards BatDetect2's bounding boxes, so
   recall and precision here are about the trigger, not the model.
3. WHOSE FAULT. With the PyTorch arm present, the app-vs-reference gap splits
   into the part the Core ML export causes and the part OpenBat's own
   call-finding causes.

Usage:
    python3 compare.py --results results/run1 [--threshold 0.3] [--sweep]
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from collections import Counter, defaultdict
from pathlib import Path

# PassAggregation's gate for this model (ModelRegistry's
# noidRawConfidenceThreshold for BatDetect2). A pass whose mean top-raw score
# falls below it is filed as NoID and never shows a species.
NOID_GATE = 0.4
# PulseDetector.minRecordedPassPulseCount — a lone trigger is not a pass.
MIN_RECORDED_PASS_PULSES = 2


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--results", required=True, type=Path,
                   help="directory holding reference.jsonl, app_arm.jsonl and "
                        "optionally pytorch_arm.jsonl")
    p.add_argument("--threshold", type=float, default=0.3,
                   help="reference detection score below which a BatDetect2 detection is "
                        "ignored (default 0.3). BatDetect2 emits everything above 0.01, "
                        "which on quiet recordings is mostly heatmap texture")
    p.add_argument("--match-tolerance-ms", type=float, default=15.0,
                   help="a reference detection and an OpenBat pulse are the same call if "
                        "their onsets are within this (default 15 ms; a UK call is "
                        "2-10 ms long and the median gap between calls is ~79 ms)")
    p.add_argument("--app-scores", choices=("app", "coreml", "pytorch"), default="coreml",
                   help="where the app arm's per-pulse class scores come from. 'app' is the "
                        "Swift harness's own in-process Core ML result, which is only "
                        "trustworthy from a run on real hardware — on a simulator Core ML "
                        "returns zeros. 'coreml' (default) is the same .mlpackage run on the "
                        "host, 'pytorch' is the checkpoint it was converted from. Detection, "
                        "windowing and preprocessing are the app's own Swift in every case")
    p.add_argument("--sweep", action="store_true",
                   help="also report file-verdict agreement across reference thresholds")
    p.add_argument("--output", type=Path, default=None,
                   help="write the report as JSON here as well as printing it")
    return p.parse_args()


# ---------------------------------------------------------------- loading


def load_jsonl(path: Path) -> dict[str, dict]:
    records: dict[str, dict] = {}
    if not path.exists():
        return records
    with path.open() as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            record = json.loads(line)
            # A resumed run can append a file twice; the last one wins, which
            # is the one whose tensors the PyTorch arm also has.
            records[record["file"]] = record
    return records


def rescore(record: dict, source: dict | None) -> dict | None:
    """Replace a recording's per-pulse scores, then re-derive its passes.

    The pass grouping is the app's — the harness already cut it with the same
    silence timeout — so only the verdicts are recomputed, following
    `PassAggregation.aggregate` with priors of 1: the NoID gate on the mean of
    each pulse's own top raw score, then the winner by summed raw score. With
    no priors, adjusted and raw are the same vector, so the second half of that
    function (the prior-adjusted species choice) collapses into the first.
    """
    if source is None:
        return None
    by_time = {round(p["onset_seconds"], 6): p for p in source.get("pulses", [])}
    pulses = []
    for pulse in record.get("pulses", []):
        replacement = by_time.get(round(pulse["onset_seconds"], 6))
        if replacement is None:
            return None
        pulses.append({
            "onset_seconds": pulse["onset_seconds"],
            "species": replacement["species"],
            "confidence": replacement["confidence"],
            "raw": replacement["raw"],
        })

    passes = []
    for pass_ in record.get("passes", []):
        members = [p for p in pulses
                   if pass_["start_seconds"] <= p["onset_seconds"] <= pass_["end_seconds"]]
        entry = dict(pass_)
        entry["pulse_count"] = len(members)
        entry["recorded"] = len(members) >= MIN_RECORDED_PASS_PULSES
        if not members:
            entry["species"] = "NOID"
            entry["noid_reason"] = "noPulses"
            passes.append(entry)
            continue
        raw_confidence = sum(max(p["raw"].values()) for p in members) / len(members)
        entry["mean_raw_confidence"] = raw_confidence
        if raw_confidence < NOID_GATE:
            entry["species"] = "NOID"
            entry["noid_reason"] = "weakEvidence"
            entry.pop("confidence", None)
        else:
            totals: dict[str, float] = defaultdict(float)
            for p in members:
                for species, score in p["raw"].items():
                    totals[species] += score
            winner = max(totals, key=lambda k: totals[k])
            entry["species"] = winner
            entry["confidence"] = totals[winner] / len(members)
        passes.append(entry)

    out = dict(record)
    out["pulses"] = pulses
    out["passes"] = passes
    return out


# ------------------------------------------------------- file-level verdict


def reference_verdict(record: dict, threshold: float) -> tuple[str, float, dict[str, float]]:
    """BatDetect2's species for one recording.

    Its detections are per call, so the recording's answer is the sum of the
    class vectors of every detection that clears `threshold`, which is the same
    shape of arithmetic `PassAggregation` applies to OpenBat's pulses — a
    recording is named by the weight of evidence across its calls, not by its
    single loudest one.
    """
    kept = [d for d in record["detections"] if d["detection_score"] >= threshold]
    if not kept:
        return "NONE", 0.0, {}
    totals: dict[str, float] = defaultdict(float)
    for det in kept:
        for species, score in det["raw"].items():
            totals[species] += score
    n = len(kept)
    means = {k: v / n for k, v in totals.items()}
    best = max(means, key=lambda k: means[k])
    return best, means[best], means


def app_verdict(record: dict, covered_seconds: float | None) -> tuple[str, float, dict[str, float], int]:
    """OpenBat's species for one recording, from the passes it filed.

    Only passes the app would actually record count (`recorded`) — a lone
    trigger with silence either side is not a pass, and the app never shows
    one. A recording with several named passes is reported by its
    highest-confidence one, which is what the species list leads with.
    """
    pulses = [p for p in record.get("pulses", [])
              if covered_seconds is None or p["onset_seconds"] <= covered_seconds]
    named = []
    for pass_ in record.get("passes", []):
        if not pass_.get("recorded"):
            continue
        if covered_seconds is not None and pass_.get("start_seconds", 0) > covered_seconds:
            continue
        if pass_["species"] not in ("NOID", "UNID"):
            named.append(pass_)
    if not named:
        # Distinguish "nothing triggered" from "triggered, would not name it":
        # they are different failures and the report separates them.
        return ("NONE" if not pulses else "NOID"), 0.0, {}, len(pulses)
    best = max(named, key=lambda p: p.get("confidence", 0.0))
    totals: dict[str, float] = defaultdict(float)
    for pulse in pulses:
        for species, score in pulse.get("raw", {}).items():
            totals[species] += score
    means = {k: v / len(pulses) for k, v in totals.items()} if pulses else {}
    return best["species"], float(best.get("confidence", 0.0)), means, len(pulses)


def top_k(means: dict[str, float], k: int) -> list[str]:
    return [s for s, _ in sorted(means.items(), key=lambda kv: -kv[1])[:k]]


# --------------------------------------------------------- call-level match


def match_calls(reference: list[dict], pulses: list[dict], tolerance: float,
                covered: float | None) -> dict:
    """Greedy nearest-onset matching between the two arms' calls.

    Greedy rather than optimal (Hungarian): with a tolerance far smaller than
    the gap between calls, the two agree, and greedy is readable.
    """
    ref_times = [d["start_seconds"] for d in reference
                 if covered is None or d["start_seconds"] <= covered]
    app_times = [p["onset_seconds"] for p in pulses
                 if covered is None or p["onset_seconds"] <= covered]
    used = [False] * len(app_times)
    matched = 0
    offsets = []
    for t in ref_times:
        best_i, best_d = None, tolerance
        for i, u in enumerate(app_times):
            if used[i]:
                continue
            d = abs(u - t)
            if d <= best_d:
                best_i, best_d = i, d
        if best_i is not None:
            used[best_i] = True
            matched += 1
            offsets.append(app_times[best_i] - t)
    return {
        "reference_calls": len(ref_times),
        "app_pulses": len(app_times),
        "matched": matched,
        "offsets": offsets,
    }


# ----------------------------------------------------------------- report


def main() -> int:
    args = parse_args()
    results = args.results.expanduser()
    reference = load_jsonl(results / "reference.jsonl")
    app = load_jsonl(results / "app_arm.jsonl")

    # Swap in host-computed scores for the app's pulses when asked. The
    # pulses themselves — which calls, cut where — stay the app's.
    if args.app_scores != "app":
        source = load_jsonl(results / f"{args.app_scores}_arm.jsonl")
        if not source:
            print(f"--app-scores {args.app_scores} needs "
                  f"{args.app_scores}_arm.jsonl; run that arm first", file=sys.stderr)
            return 1
        app = {name: rescore(record, source.get(name)) for name, record in app.items()}
        app = {name: record for name, record in app.items() if record is not None}
    # The attribution arm: the SAME pulses, scored by the other set of weights
    # and put through the SAME verdict rule, so the only difference between the
    # two agreement figures is the model that produced the numbers.
    alt_name = "pytorch" if args.app_scores != "pytorch" else "coreml"
    alt_source = load_jsonl(results / f"{alt_name}_arm.jsonl")
    alt = {}
    if alt_source:
        raw_app = load_jsonl(results / "app_arm.jsonl")
        alt = {name: rescore(record, alt_source.get(name)) for name, record in raw_app.items()}
        alt = {name: record for name, record in alt.items() if record is not None}

    shared = sorted(set(reference) & set(app))
    if not shared:
        print("no recordings present in both arms", file=sys.stderr)
        return 1

    report: dict = {
        "recordings": {
            "reference": len(reference),
            "app": len(app),
            "compared": len(shared),
        },
        "settings": {
            "reference_detection_threshold": args.threshold,
            "match_tolerance_ms": args.match_tolerance_ms,
            "app_scores_from": args.app_scores,
            # The trigger the app arm ran with, taken from the records
            # themselves. Two runs at different thresholds are two different
            # experiments and every number below moves with this one.
            "app_trigger": next((r.get("settings") for r in app.values()
                                 if r.get("settings")), None),
        },
    }

    agree = agree_top3 = 0
    both_named = 0
    confusion: Counter = Counter()
    per_species_ref: Counter = Counter()
    per_species_app: Counter = Counter()
    per_species_hit: Counter = Counter()
    app_states: Counter = Counter()
    ref_states: Counter = Counter()
    conf_gap: list[float] = []

    detection = {"reference_calls": 0, "app_pulses": 0, "matched": 0}
    offsets: list[float] = []

    noid_reasons: Counter = Counter()
    pass_raw_confidences: list[float] = []
    coreml_vs_torch_same = coreml_vs_torch_total = 0
    conf_delta: list[float] = []
    alt_agree = alt_total = 0

    for name in shared:
        ref_record = reference[name]
        app_record = app[name]
        covered = ref_record.get("covered_seconds")

        ref_species, _, ref_means = reference_verdict(ref_record, args.threshold)
        app_species, app_conf, app_means, app_pulse_count = app_verdict(app_record, covered)

        # Why the app would not name a pass is the actionable half of a
        # disagreement: "the model was not confident enough" and "the top two
        # species were too close" are different problems.
        for pass_ in app_record.get("passes", []):
            if not pass_.get("recorded"):
                continue
            if pass_["species"] in ("NOID", "UNID"):
                noid_reasons[pass_.get("noid_reason", "unknown")] += 1
            else:
                noid_reasons["named"] += 1
            # The harness records this only on a named pass, so recompute it
            # the way PassAggregation.meanRawConfidence does — the mean, over
            # the pass's pulses, of each pulse's own top raw score. It is the
            # number the NoID gate tests, so a refused pass is exactly where
            # it is worth reading.
            members = [p for p in app_record.get("pulses", [])
                       if pass_["start_seconds"] <= p["onset_seconds"] <= pass_["end_seconds"]]
            tops = [max(p["raw"].values()) for p in members if p.get("raw")]
            if tops:
                pass_raw_confidences.append(sum(tops) / len(tops))

        ref_states[ref_species if ref_species in ("NONE",) else "named"] += 1
        app_states[app_species if app_species in ("NONE", "NOID") else "named"] += 1

        if ref_species != "NONE" and app_species not in ("NONE", "NOID"):
            both_named += 1
            per_species_ref[ref_species] += 1
            per_species_app[app_species] += 1
            if ref_species == app_species:
                agree += 1
                per_species_hit[ref_species] += 1
            confusion[(ref_species, app_species)] += 1
            if ref_species in top_k(app_means, 3):
                agree_top3 += 1
            if ref_means and app_means:
                conf_gap.append(app_means.get(ref_species, 0.0) - ref_means.get(ref_species, 0.0))

        # Only detections above the threshold count as calls to find: the
        # reference arm writes everything down to 0.05, and scoring recall
        # against that floor would measure OpenBat against heatmap texture.
        filtered = [d for d in ref_record["detections"] if d["detection_score"] >= args.threshold]
        m = match_calls(filtered, app_record.get("pulses", []),
                        args.match_tolerance_ms / 1000.0, covered)
        detection["reference_calls"] += m["reference_calls"]
        detection["app_pulses"] += m["app_pulses"]
        detection["matched"] += m["matched"]
        offsets.extend(m["offsets"])

        alt_record = alt.get(name)
        if alt_record is not None:
            alt_pulses = {round(p["onset_seconds"], 6): p for p in alt_record.get("pulses", [])}
            for pulse in app_record.get("pulses", []):
                counterpart = alt_pulses.get(round(pulse["onset_seconds"], 6))
                if counterpart is None:
                    continue
                coreml_vs_torch_total += 1
                if counterpart["species"] == pulse["species"]:
                    coreml_vs_torch_same += 1
                conf_delta.append(pulse["confidence"] - counterpart["confidence"])
            alt_species, _, _, _ = app_verdict(alt_record, covered)
            if ref_species != "NONE" and alt_species not in ("NONE", "NOID"):
                alt_total += 1
                if alt_species == ref_species:
                    alt_agree += 1

    report["file_verdict"] = {
        "both_named": both_named,
        "top1_agreement": ratio(agree, both_named),
        "top3_agreement": ratio(agree_top3, both_named),
        "reference_found_nothing": ref_states.get("NONE", 0),
        "app_found_nothing": app_states.get("NONE", 0),
        "app_refused_to_name": app_states.get("NOID", 0),
        "mean_confidence_gap_on_reference_species": mean(conf_gap),
    }

    report["refusals"] = {
        "passes_the_app_would_file": sum(noid_reasons.values()),
        "by_outcome": dict(noid_reasons.most_common()),
        "median_pass_raw_confidence": round(median(pass_raw_confidences), 4) if pass_raw_confidences else None,
        "max_pass_raw_confidence": round(max(pass_raw_confidences), 4) if pass_raw_confidences else None,
        # The gate a pass has to clear before BatDetect2's name is used at all
        # (ModelRegistry's noidRawConfidenceThreshold for this model). It was
        # set as a placeholder, never against labelled data.
        "noid_gate": NOID_GATE,
        "passes_above_gate": sum(1 for c in pass_raw_confidences if c >= NOID_GATE),
    }

    report["per_species"] = {
        species: {
            "reference_files": per_species_ref[species],
            "app_files": per_species_app[species],
            "agreed": per_species_hit[species],
            "recall_of_reference": ratio(per_species_hit[species], per_species_ref[species]),
            "precision_of_app": ratio(per_species_hit[species], per_species_app[species]),
        }
        for species in sorted(set(per_species_ref) | set(per_species_app))
    }

    report["confusions"] = [
        {"reference": r, "app": a, "files": n}
        for (r, a), n in confusion.most_common(20) if r != a
    ]

    report["call_detection"] = {
        "reference_calls": detection["reference_calls"],
        "app_pulses": detection["app_pulses"],
        "matched": detection["matched"],
        "recall": ratio(detection["matched"], detection["reference_calls"]),
        "precision": ratio(detection["matched"], detection["app_pulses"]),
        "median_onset_offset_ms": 1000 * median(offsets),
        "mean_abs_onset_offset_ms": 1000 * mean([abs(o) for o in offsets]),
    }

    if alt:
        report["attribution"] = {
            "scored_by": args.app_scores,
            "compared_against": alt_name,
            "pulses_compared": coreml_vs_torch_total,
            "same_species_per_pulse": ratio(coreml_vs_torch_same, coreml_vs_torch_total),
            "mean_confidence_delta": mean(conf_delta),
            "max_abs_confidence_delta": round(max((abs(d) for d in conf_delta), default=0.0), 6),
            "top1_vs_reference_scored_by": ratio(agree, both_named),
            "top1_vs_reference_alt": ratio(alt_agree, alt_total),
            "files_named_scored_by": both_named,
            "files_named_alt": alt_total,
        }

    if args.sweep:
        sweep = []
        for threshold in (0.1, 0.2, 0.3, 0.4, 0.5, 0.6):
            hits = total = 0
            for name in shared:
                covered = reference[name].get("covered_seconds")
                ref_species, _, _ = reference_verdict(reference[name], threshold)
                app_species, _, _, _ = app_verdict(app[name], covered)
                if ref_species != "NONE" and app_species not in ("NONE", "NOID"):
                    total += 1
                    hits += ref_species == app_species
            sweep.append({"threshold": threshold, "both_named": total,
                          "top1_agreement": ratio(hits, total)})
        report["threshold_sweep"] = sweep

    print(render(report))
    if args.output:
        args.output.expanduser().write_text(json.dumps(report, indent=2))
        print(f"\nJSON report: {args.output}")
    return 0


def ratio(numerator: int, denominator: int) -> float | None:
    return round(numerator / denominator, 4) if denominator else None


def mean(values: list[float]) -> float | None:
    return round(sum(values) / len(values), 4) if values else None


def median(values: list[float]) -> float:
    if not values:
        return math.nan
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[mid]
    return (ordered[mid - 1] + ordered[mid]) / 2


def render(report: dict) -> str:
    lines: list[str] = []
    add = lines.append
    r = report["recordings"]
    add("OpenBat vs BatDetect2 — reference: BatDetect2's own pipeline")
    add("=" * 62)
    add(f"recordings compared: {r['compared']} "
        f"(reference {r['reference']}, app {r['app']})")
    s = report["settings"]
    add(f"reference detection threshold {s['reference_detection_threshold']}, "
        f"call match tolerance {s['match_tolerance_ms']} ms")
    add(f"app pulses: OpenBat's own detector; app scores: {s['app_scores_from']}")
    if s.get("app_trigger"):
        t = s["app_trigger"]
        add(f"app trigger: amplitude {t['amplitude_threshold']}, "
            f"pitch gate {t['min_frequency_hz'] / 1000:.0f} kHz, "
            f"{t['trigger_mode']}, band {t['band_low']}-{t['band_high']} of Nyquist")
    add("")

    v = report["file_verdict"]
    add("FILE VERDICT — one species per recording")
    add(f"  both arms named a species   {v['both_named']}")
    add(f"  top-1 agreement             {pct(v['top1_agreement'])}")
    add(f"  reference species in app's top 3  {pct(v['top3_agreement'])}")
    add(f"  reference found nothing     {v['reference_found_nothing']}")
    add(f"  app found nothing           {v['app_found_nothing']}")
    add(f"  app triggered but refused   {v['app_refused_to_name']}")
    add(f"  mean confidence gap on the reference's species  "
        f"{v['mean_confidence_gap_on_reference_species']}")
    add("")

    f = report["refusals"]
    add("WHY THE APP REFUSED")
    add(f"  passes it would file        {f['passes_the_app_would_file']}")
    for outcome, n in f["by_outcome"].items():
        add(f"    {outcome:<24}{n}")
    add(f"  pass raw confidence         median {f['median_pass_raw_confidence']}, "
        f"best {f['max_pass_raw_confidence']}")
    add(f"  NoID gate for this model    {f['noid_gate']}  "
        f"({f['passes_above_gate']} passes above it)")
    add("")

    add("PER SPECIES (reference's label as the truth)")
    add(f"  {'species':<10}{'ref':>6}{'app':>6}{'agreed':>8}{'recall':>9}{'precision':>11}")
    for species, row in sorted(report["per_species"].items(),
                               key=lambda kv: -kv[1]["reference_files"]):
        add(f"  {species:<10}{row['reference_files']:>6}{row['app_files']:>6}"
            f"{row['agreed']:>8}{pct(row['recall_of_reference']):>9}"
            f"{pct(row['precision_of_app']):>11}")
    add("")

    if report["confusions"]:
        add("TOP DISAGREEMENTS (reference → app)")
        for row in report["confusions"][:10]:
            add(f"  {row['reference']:<8} → {row['app']:<8} {row['files']} files")
        add("")

    d = report["call_detection"]
    add("CALL DETECTION — does OpenBat's trigger find the same calls?")
    add(f"  reference calls             {d['reference_calls']}")
    add(f"  OpenBat pulses              {d['app_pulses']}")
    add(f"  matched                     {d['matched']}")
    add(f"  recall of reference calls   {pct(d['recall'])}")
    add(f"  precision of OpenBat pulses {pct(d['precision'])}")
    add(f"  onset offset                median {d['median_onset_offset_ms']:.2f} ms, "
        f"mean abs {d['mean_abs_onset_offset_ms']} ms")
    add("")

    if "attribution" in report:
        a = report["attribution"]
        add(f"WHAT THE EXPORT COSTS ({a['scored_by']} vs {a['compared_against']}, "
            f"same pulses, same verdict rule)")
        add(f"  pulses compared             {a['pulses_compared']}")
        add(f"  same species per pulse      {pct(a['same_species_per_pulse'])}")
        add(f"  mean confidence delta       {a['mean_confidence_delta']}")
        add(f"  largest single delta        {a['max_abs_confidence_delta']}")
        add(f"  files named / top-1 vs ref  {a['scored_by']}: {a['files_named_scored_by']} "
            f"/ {pct(a['top1_vs_reference_scored_by'])}")
        add(f"                              {a['compared_against']}: {a['files_named_alt']} "
            f"/ {pct(a['top1_vs_reference_alt'])}")
        add("  (these two differ only in which weights scored the pulses, so any")
        add("   gap here is the Core ML conversion and nothing else)")
        add("")

    if "threshold_sweep" in report:
        add("THRESHOLD SWEEP (reference detection score)")
        for row in report["threshold_sweep"]:
            add(f"  {row['threshold']:<5} both named {row['both_named']:>5}   "
                f"top-1 {pct(row['top1_agreement'])}")
    return "\n".join(lines)


def pct(value: float | None) -> str:
    return "—" if value is None else f"{100 * value:.1f}%"


if __name__ == "__main__":
    raise SystemExit(main())
