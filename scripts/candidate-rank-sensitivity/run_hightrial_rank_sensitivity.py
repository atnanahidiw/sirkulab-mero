#!/usr/bin/env python3
"""Run a higher-trial candidate-rank-sensitivity test on a smaller stratified subset.

This is meant to answer the "what if we push the shuffle count higher?" question
without paying the full 50-example cost again. It keeps the far-separated candidate
setup, but samples a smaller, balanced subset of examples and runs more shuffles per
example.
"""
from __future__ import annotations

import argparse
import collections
import subprocess
import sys
import time
from pathlib import Path

from _common import DEFAULT_OUTPUT_DIR, ExperimentError, load_jsonl, stable_int_seed, write_jsonl

EVAL_SCRIPT = Path(__file__).with_name("eval_candidate_rank_sensitivity.py")
SUMMARY_SCRIPT = Path(__file__).with_name("summarize_rank_sensitivity.py")
DEFAULT_OUTPUT_SUBDIR = DEFAULT_OUTPUT_DIR / "hightrial"


def example_group(example: dict) -> str:
    meta = example.get("metadata") or {}
    group = str(meta.get("source_visual_group") or meta.get("visual_group") or "Unknown").strip()
    return group or "Unknown"


def balanced_subset(examples: list[dict], limit: int, seed: int) -> list[dict]:
    if limit <= 0:
        raise ExperimentError("--limit-examples must be a positive integer")

    groups: dict[str, list[dict]] = collections.defaultdict(list)
    for ex in examples:
        groups[example_group(ex)].append(ex)

    group_names = sorted(groups, key=lambda g: (-len(groups[g]), g))
    for group in group_names:
        groups[group].sort(key=lambda ex: stable_int_seed(seed, group, ex["example_id"]))

    selected: list[dict] = []
    while len(selected) < limit and any(groups.values()):
        progressed = False
        for group in group_names:
            if groups[group]:
                selected.append(groups[group].pop(0))
                progressed = True
                if len(selected) >= limit:
                    break
        if not progressed:
            break

    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_OUTPUT_DIR / "examples.jsonl"), help="Frozen examples JSONL")
    parser.add_argument("--limit-examples", type=int, default=6, help="How many examples to sample for the high-trial run")
    parser.add_argument("--trials", type=int, default=15, help="Shuffled trials per example")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic selection seed")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_SUBDIR), help="Directory for subset/results/summary artifacts")
    parser.add_argument("--model-path", required=True, help="Path to the Gemma 4 LiteRT-LM bundle")
    parser.add_argument("--data-repo", required=True, help="Path to the sibling sirkulab-mero-data repo")
    parser.add_argument("--backend", default="cpu", choices=["cpu", "gpu", "npu"], help="LiteRT backend to use")
    args = parser.parse_args()

    examples_path = Path(args.examples)
    if not examples_path.exists():
        raise ExperimentError(f"Examples JSONL not found: {examples_path}")

    examples = load_jsonl(examples_path)
    if not examples:
        raise ExperimentError(f"No examples found in {examples_path}")

    subset = balanced_subset(examples, args.limit_examples, args.seed)
    if not subset:
        raise ExperimentError("No examples were selected for the high-trial subset")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    subset_path = output_dir / "hightrial_examples.jsonl"
    results_path = output_dir / "hightrial_results.jsonl"
    summary_path = output_dir / "hightrial_summary.json"
    write_jsonl(subset_path, subset)

    group_counts = collections.Counter(example_group(ex) for ex in subset)
    print(
        f"Selected {len(subset)} examples across {len(group_counts)} groups "
        f"for {args.trials} shuffles/example"
    )
    print(f"Subset written to {subset_path}")
    print(f"Group mix: {dict(group_counts)}")

    started = time.time()
    eval_cmd = [
        sys.executable,
        str(EVAL_SCRIPT),
        "--examples",
        str(subset_path),
        "--trials",
        str(args.trials),
        "--output",
        str(results_path),
        "--model-path",
        args.model_path,
        "--data-repo",
        args.data_repo,
        "--backend",
        args.backend,
    ]
    subprocess.run(eval_cmd, check=True)

    summarize_cmd = [
        sys.executable,
        str(SUMMARY_SCRIPT),
        "--results",
        str(results_path),
        "--output",
        str(summary_path),
    ]
    subprocess.run(summarize_cmd, check=True)

    elapsed = time.time() - started
    print(f"High-trial run complete in {elapsed:.1f}s")
    print(f"Results: {results_path}")
    print(f"Summary : {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
