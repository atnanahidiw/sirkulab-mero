#!/usr/bin/env python3
"""Stopping-policy comparison over the `00_loop_ablation.py` traces.

No model runs here — this is a pure-Python pass over the per-image JSONL that
`00_loop_ablation.py` already wrote, in the same "join prior runs and derive the rest
offline" style as `../gemma-improve-detection/analyze_soft_gate_failures.py`.

Two families of stopping policy are compared:

  FIXED-LIMIT policies (the current design). The one-call, two-call, and four-call
  conditions from `00_loop_ablation.py` already ARE "always stop after pass k" runs, so
  their recorded accuracy and mean pass count are read directly from those conditions'
  summaries — no replay needed.

  ADAPTIVE policies (proposed alternatives), replayed on the four-call condition's own
  traces:
    - unchanged-hypothesis: stop the first time the requested visualGroup repeats
      between two consecutive passes.
    - evidence-threshold: stop the first time the top retrieved candidate's confidence
      reaches `--evidence-threshold` (45% by default, the same value the deployed
      prompt already uses as its own gate).

IMPORTANT LIMIT ON WHAT CAN BE SIMULATED: litert_lm's native tool loop only returns the
model's answer after it decides to stop for real, so the model's would-be answer at an
earlier, counterfactual stopping pass is never observed. `accuracy_at_stop` for the two
adaptive policies is therefore only reported over the subset of images where the
policy's suggested stop pass equals the pass the model actually stopped at
(`agreement_rate` / `n_matched`) — earlier stops are not simulated, not assumed correct.

Writes `outputs/agent-loop-evaluation/stopping_policy_comparison_summary.json`.

Run (no GPU or model needed, only the traces and the species DB):
  python3 scripts/agent-loop-evaluation/02_stopping_policy_comparison.py
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
DEFAULT_EVIDENCE_THRESHOLD = 45.0
ADAPTIVE_POLICIES = ["unchanged-hypothesis", "evidence-threshold"]


def load_loop_ablation_module():
    spec = importlib.util.spec_from_file_location("loop_ablation", LOOP_ABLATION_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_jsonl(path):
    return [json.loads(line) for line in Path(path).open()] if Path(path).exists() else []


def replay_pass_signals(baseline, con, calls):
    """Per-pass requested visualGroup and top-candidate confidence, replayed offline
    against the same deterministic search the model's tool calls actually ran."""
    groups, top_confidences = [], []
    for call_args in calls:
        groups.append(str(call_args.get("visualGroup", "")).strip())
        ranked = baseline._run_search(con, call_args, top_k=1)
        top_confidences.append(ranked[0]["confidence"] if ranked else 0)
    return groups, top_confidences


def unchanged_hypothesis_stop(groups):
    for i in range(1, len(groups)):
        if groups[i] == groups[i - 1]:
            return i + 1  # 1-indexed pass at which the repeat is confirmed
    return len(groups)


def evidence_threshold_stop(top_confidences, threshold):
    for i, conf in enumerate(top_confidences, 1):
        if conf >= threshold:
            return i
    return len(top_confidences)


def evaluate_policies(baseline, con, row, threshold):
    calls = row.get("tool_call_args") or []
    passes = len(calls)
    if not calls:
        return None
    groups, confidences = replay_pass_signals(baseline, con, calls)
    suggested = {
        "unchanged-hypothesis": unchanged_hypothesis_stop(groups),
        "evidence-threshold": evidence_threshold_stop(confidences, threshold),
    }
    result = {
        "image": row["image"], "true": row["true"], "actual_passes": passes,
        "final_correct": bool(row.get("species_ok")),
        "final_confidence_label": (row.get("final") or {}).get("confidence", "") or "unknown",
    }
    for policy, stop_pass in suggested.items():
        matched = stop_pass == passes
        result[policy] = {
            "suggested_stop_pass": stop_pass,
            "matches_actual_stop": matched,
            "accuracy_at_stop": (bool(row.get("species_ok")) if matched else None),
        }
    return result


def summarize_policy(evaluated, policy):
    n = len(evaluated)
    matched = [r for r in evaluated if r[policy]["matches_actual_stop"]]
    return {
        "n": n,
        "n_matched": len(matched),
        "agreement_rate": len(matched) / n if n else 0.0,
        "mean_suggested_passes": sum(r[policy]["suggested_stop_pass"] for r in evaluated) / n if n else 0.0,
        "accuracy_at_stop_when_matched": (
            sum(r["final_correct"] for r in matched) / len(matched) if matched else None
        ),
    }


def confidence_label_agreement(evaluated, policy):
    counts = Counter()
    for r in evaluated:
        agrees = "agrees" if r[policy]["matches_actual_stop"] else "disagrees"
        counts[f"{r['final_confidence_label']}/{agrees}"] += 1
    return dict(counts)


def summarize_fixed_limit(out_dir, tag, condition):
    summary_path = out_dir / f"loop_ablation_{condition}{tag}.json"
    jsonl_path = out_dir / f"loop_ablation_{condition}{tag}.jsonl"
    if not summary_path.exists():
        return None
    summary = json.loads(summary_path.read_text())
    rows = load_jsonl(jsonl_path)
    mean_passes = sum(r.get("passes", 0) for r in rows) / len(rows) if rows else None
    return {"n": summary.get("images", 0), "accuracy_at_stop": summary.get("species_top1"),
             "mean_passes": mean_passes}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out-dir", default=str(OUT_DIR), help="Directory with 00_loop_ablation.py's jsonl files")
    ap.add_argument("--db", default=str(DB_PATH_DEFAULT))
    ap.add_argument("--tag", default="", help="Shard tag suffix, e.g. _shard0of3, matching 00_loop_ablation.py")
    ap.add_argument("--evidence-threshold", type=float, default=DEFAULT_EVIDENCE_THRESHOLD,
                     help="Top-candidate confidence %% the deployed prompt already uses as its own stop gate")
    args = ap.parse_args()

    mod = load_loop_ablation_module()
    baseline = mod.baseline
    baseline._DB_PATH = str(args.db)

    out_dir = Path(args.out_dir)
    fixed_limit = {
        "fixed-limit-1": summarize_fixed_limit(out_dir, args.tag, "one-call"),
        "fixed-limit-2": summarize_fixed_limit(out_dir, args.tag, "two-call"),
        "fixed-limit-4": summarize_fixed_limit(out_dir, args.tag, "four-call"),
    }

    four_call_path = out_dir / f"loop_ablation_four-call{args.tag}.jsonl"
    four_call_rows = load_jsonl(four_call_path)
    if not four_call_rows:
        print(f"no four-call trace at {four_call_path}; run 00_loop_ablation.py first")

    con = sqlite3.connect(str(args.db))
    con.row_factory = sqlite3.Row
    try:
        evaluated = [e for e in (evaluate_policies(baseline, con, r, args.evidence_threshold)
                                  for r in four_call_rows) if e is not None]
    finally:
        con.close()

    adaptive_policies = {policy: summarize_policy(evaluated, policy) for policy in ADAPTIVE_POLICIES} if evaluated else {}
    confidence_agreement = {policy: confidence_label_agreement(evaluated, policy) for policy in ADAPTIVE_POLICIES} if evaluated else {}

    payload = {
        "fixed_limit_policies": fixed_limit,
        "adaptive_policies_replayed_on_four_call_traces": adaptive_policies,
        "confidence_label_agreement": confidence_agreement,
        "evidence_threshold": args.evidence_threshold,
        "note": ("accuracy_at_stop for the adaptive policies is only reported over images "
                 "where the policy's suggested stop pass equals the pass the model actually "
                 "stopped at (agreement_rate / n_matched) — earlier stops are not simulated "
                 "because the model's answer at an intermediate pass is never observed."),
    }

    out_dir.mkdir(parents=True, exist_ok=True)
    summary_path = out_dir / "stopping_policy_comparison_summary.json"
    summary_path.write_text(json.dumps(payload, indent=2))

    detail_path = out_dir / "stopping_policy_comparison.jsonl"
    with detail_path.open("w") as f:
        for row in evaluated:
            f.write(json.dumps(row) + "\n")

    print("fixed-limit policies:")
    for policy, s in fixed_limit.items():
        if s is None:
            print(f"  {policy}: no trace on disk")
        elif s["mean_passes"] is not None:
            print(f"  {policy}: n={s['n']}  accuracy {s['accuracy_at_stop']:.1%}  mean passes {s['mean_passes']:.2f}")
        else:
            print(f"  {policy}: n={s['n']}  accuracy {s['accuracy_at_stop']:.1%}")

    print("\nadaptive policies replayed on four-call traces:")
    for policy, s in adaptive_policies.items():
        acc = s["accuracy_at_stop_when_matched"]
        acc_str = f"{acc:.1%}" if acc is not None else "n/a"
        print(f"  {policy}: n={s['n']}  agreement {s['agreement_rate']:.1%} ({s['n_matched']} matched)  "
              f"accuracy-when-matched {acc_str}  mean suggested passes {s['mean_suggested_passes']:.2f}")

    print(f"\nwrote {summary_path}")
    print(f"wrote {detail_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
