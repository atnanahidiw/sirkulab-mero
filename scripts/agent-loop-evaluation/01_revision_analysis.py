#!/usr/bin/env python3
"""Revision analysis over the `00_loop_ablation.py` traces.

No model runs here — this is a pure-Python pass over the per-image JSONL that
`00_loop_ablation.py` already wrote for the one-call, two-call, and four-call
conditions, in the same "join prior runs and derive the rest offline" style as
`../gemma-improve-detection/analyze_soft_gate_failures.py`.

WHAT IS AND IS NOT RECOVERABLE FROM THESE TRACES

litert_lm's native tool loop only returns the model's final text after all of its
internal tool calls resolve — it does not expose the model's intermediate hypothesis
or verdict after each individual call. The recorded trace has, per image: the final
identification, whether it was correct, and the sequence of `search_similar_features`
argument dicts the model actually sent (one per pass). That means:

  RECOVERABLE offline, by replaying each pass's recorded traits through the same
  deterministic search (`baseline._run_search`):
    - the pass at which the true species first appears in the candidate list
      (`pass_true_species_first_available`)
    - whether the requested `visualGroup` changed between consecutive passes, the
      only available proxy for "the model revised its hypothesis"

  NOT RECOVERABLE from these traces:
    - whether the model's answer would have been correct at an intermediate pass —
      only the final pass's answer is ever observed, so wrong-to-correct /
      correct-to-wrong transitions BETWEEN passes cannot be measured directly here.

This script reports the first kind of evidence honestly and does not fabricate the
second. It correlates final correctness with retrieval-side signals (first-available
pass, hypothesis stability) rather than claiming a pass-by-pass correctness trace that
the data does not contain.

Writes `outputs/agent-loop-evaluation/revision_analysis_summary.json`.

Run (no GPU or model needed, only the traces and the species DB):
  python3 scripts/agent-loop-evaluation/01_revision_analysis.py
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sqlite3
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
OUT_DIR = APP_REPO / "outputs" / "agent-loop-evaluation"
LOOP_ABLATION_PATH = HERE.parent / "00_loop_ablation.py"
DB_PATH_DEFAULT = APP_REPO / "assets/data/species_data.sqlite"
MULTI_PASS_CONDITIONS = ["one-call", "two-call", "four-call"]


def load_loop_ablation_module():
    spec = importlib.util.spec_from_file_location("loop_ablation", LOOP_ABLATION_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_jsonl(path):
    return [json.loads(line) for line in Path(path).open()] if Path(path).exists() else []


def true_species_rank(baseline, con, call_args, true_latin, top_k=5):
    ranked = baseline._run_search(con, call_args, top_k=top_k)
    return next((i for i, c in enumerate(ranked, 1) if c["latin"] == true_latin), None)


def analyze_row(baseline, con, row):
    """Replay each recorded call against the DB and derive the retrieval-side signals
    described in the module docstring. Returns None for rows with fewer than 1 call."""
    calls = row.get("tool_call_args") or []
    if not calls:
        return None

    first_available = None
    for pass_idx, call_args in enumerate(calls, 1):
        rank = true_species_rank(baseline, con, call_args, row["true"])
        if rank is not None:
            first_available = pass_idx
            break

    groups = [str(c.get("visualGroup", "")).strip() for c in calls]
    hypothesis_changed = any(a != b for a, b in zip(groups, groups[1:]))

    return {
        "image": row["image"],
        "true": row["true"],
        "passes": len(calls),
        "final_correct": bool(row.get("species_ok")),
        "pass_true_species_first_available": first_available,
        "hypothesis_changed": hypothesis_changed,
        "final_matches_first_available_pass": (
            first_available is not None and row.get("species_ok")
            and first_available == len(calls)
        ),
    }


def bucket_first_available(first_available, passes):
    if first_available is None:
        return "never available"
    if first_available == 1:
        return "available at pass 1"
    if first_available == passes:
        return "available only at the final pass"
    return "available at an intermediate pass"


def summarize(rows):
    by_first_available = Counter()
    correct_by_first_available = Counter()
    by_hypothesis_stability = Counter()
    correct_by_hypothesis_stability = Counter()

    for r in rows:
        bucket = bucket_first_available(r["pass_true_species_first_available"], r["passes"])
        by_first_available[bucket] += 1
        correct_by_first_available[bucket] += int(r["final_correct"])

        stability = "hypothesis changed" if r["hypothesis_changed"] else "hypothesis unchanged"
        by_hypothesis_stability[stability] += 1
        correct_by_hypothesis_stability[stability] += int(r["final_correct"])

    def rate_table(counts, correct):
        return {
            key: {"n": n, "final_correct": correct[key], "accuracy": correct[key] / n if n else 0.0}
            for key, n in counts.items()
        }

    n = len(rows)
    return {
        "n": n,
        "final_accuracy": sum(r["final_correct"] for r in rows) / n if n else 0.0,
        "mean_passes": sum(r["passes"] for r in rows) / n if n else 0.0,
        "accuracy_by_first_available_pass": rate_table(by_first_available, correct_by_first_available),
        "accuracy_by_hypothesis_stability": rate_table(by_hypothesis_stability, correct_by_hypothesis_stability),
        "never_available_count": by_first_available.get("never available", 0),
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=str(OUT_DIR), help="Directory with 00_loop_ablation.py's jsonl files")
    ap.add_argument("--db", default=str(DB_PATH_DEFAULT))
    ap.add_argument("--tag", default="", help="Shard tag suffix, e.g. _shard0of3, matching 00_loop_ablation.py")
    ap.add_argument("--conditions", default=",".join(MULTI_PASS_CONDITIONS),
                     help="Comma-separated subset of: " + ", ".join(MULTI_PASS_CONDITIONS))
    args = ap.parse_args()

    mod = load_loop_ablation_module()
    baseline = mod.baseline
    baseline._DB_PATH = str(args.db)

    out_dir = Path(args.out_dir)
    conditions = [c.strip() for c in args.conditions.split(",") if c.strip()]

    con = sqlite3.connect(str(args.db))
    con.row_factory = sqlite3.Row

    per_condition = {}
    per_condition_rows = {}
    try:
        for condition in conditions:
            jsonl_path = out_dir / f"loop_ablation_{condition}{args.tag}.jsonl"
            rows = load_jsonl(jsonl_path)
            if not rows:
                print(f"[{condition}] no trace at {jsonl_path}, skipping")
                continue
            analyzed = [a for a in (analyze_row(baseline, con, r) for r in rows) if a is not None]
            per_condition_rows[condition] = analyzed
            per_condition[condition] = summarize(analyzed)
    finally:
        con.close()

    payload = {"conditions": per_condition}

    out_dir.mkdir(parents=True, exist_ok=True)
    summary_path = out_dir / "revision_analysis_summary.json"
    summary_path.write_text(json.dumps(payload, indent=2))

    detail_path = out_dir / "revision_analysis.jsonl"
    with detail_path.open("w") as f:
        for condition, rows in per_condition_rows.items():
            for r in rows:
                f.write(json.dumps({**r, "condition": condition}) + "\n")

    for condition, s in per_condition.items():
        print(f"\n[{condition}] n={s['n']}  final accuracy {s['final_accuracy']:.1%}  "
              f"mean passes {s['mean_passes']:.2f}  never-available {s['never_available_count']}")
        for bucket, r in s["accuracy_by_first_available_pass"].items():
            print(f"    {bucket:36s} n={r['n']:3d}  accuracy {r['accuracy']:.1%}")
        for bucket, r in s["accuracy_by_hypothesis_stability"].items():
            print(f"    {bucket:36s} n={r['n']:3d}  accuracy {r['accuracy']:.1%}")

    print(f"\nwrote {summary_path}")
    print(f"wrote {detail_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
