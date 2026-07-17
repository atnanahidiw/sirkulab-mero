#!/usr/bin/env python3
"""Analyze score-rich confidence-sensitivity trials.

This is the analysis companion to `extract_confidence_sensitivity_scores.py`.
It reads the extractor output JSONL, computes the confidence / PBM / gap /
default-order diagnostics, and writes a summary JSON.

The core implementation lives in `analyze_confidence_sensitivity.py`; this
wrapper exists so the pipeline has a clearly named analysis step.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from analyze_confidence_sensitivity import load_jsonl, summarize, write_json, print_report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, help="Score-rich extractor JSONL")
    parser.add_argument("--output", required=True, help="Summary JSON output path")
    parser.add_argument("--gap-threshold", type=float, default=0.1, help="Gap threshold for brittle examples")
    parser.add_argument("--max-examples", type=int, default=10, help="How many brittle examples to print")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    results_path = Path(args.results)
    output_path = Path(args.output)
    rows = load_jsonl(results_path)
    summary = summarize(rows, gap_threshold=args.gap_threshold)
    write_json(output_path, summary)
    print_report(summary, max_examples=args.max_examples)
    print(f"\nWrote summary JSON to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
