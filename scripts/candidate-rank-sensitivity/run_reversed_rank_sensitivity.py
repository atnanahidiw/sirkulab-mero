#!/usr/bin/env python3
"""Run the reverse-order rank-sensitivity experiment on a frozen dataset."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

EVAL_SCRIPT = Path(__file__).with_name("eval_candidate_rank_sensitivity.py")
SUMMARY_SCRIPT = Path(__file__).with_name("summarize_rank_sensitivity.py")
DEFAULT_OUTPUT_DIR = Path("outputs/candidate-rank-sensitivity/reverse")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", required=True, help="Frozen examples JSONL produced by the builder")
    parser.add_argument("--output-dir", default=str(DEFAULT_OUTPUT_DIR), help="Directory for reverse-order results")
    parser.add_argument("--model-path", required=True, help="Path to the Gemma 4 LiteRT-LM bundle")
    parser.add_argument("--data-repo", required=True, help="Path to the sibling sirkulab-mero-data repo")
    parser.add_argument("--backend", default="cpu", choices=["cpu", "gpu", "npu"], help="LiteRT backend to use")
    parser.add_argument("--trials", type=int, default=1, help="Shuffle/reverse pairs per example")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    results_path = output_dir / "reverse_rank_sensitivity_results.jsonl"
    summary_path = output_dir / "reverse_rank_sensitivity_summary.json"

    eval_cmd = [
        sys.executable,
        str(EVAL_SCRIPT),
        "--examples",
        args.examples,
        "--trials",
        str(getattr(args, "trials", 1)),
        "--order-mode",
        "shuffle_then_reverse",
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
    print(f"Reverse-order results: {results_path}")
    print(f"Reverse-order summary : {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
