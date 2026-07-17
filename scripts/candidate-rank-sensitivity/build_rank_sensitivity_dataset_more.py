#!/usr/bin/env python3
"""Convenience wrapper that builds a larger frozen candidate-rank dataset.

The main builder already supports arbitrary limits. This wrapper just picks a
larger default so we can freeze more examples for robustness checks without
retyping the full command every time.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

BUILD_SCRIPT = Path(__file__).with_name("build_rank_sensitivity_dataset.py")
DEFAULT_OUTPUT = Path("outputs/candidate-rank-sensitivity/examples_big.jsonl")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=200, help="How many frozen examples to build")
    parser.add_argument("--seed", type=int, default=42, help="Selection seed")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Output JSONL path")
    parser.add_argument("--selection-mode", default="far-separated", choices=["far-separated", "baseline-original"], help="Candidate selection mode")
    args = parser.parse_args()

    cmd = [
        sys.executable,
        str(BUILD_SCRIPT),
        "--limit",
        str(args.limit),
        "--seed",
        str(args.seed),
        "--selection-mode",
        args.selection_mode,
        "--output",
        args.output,
    ]
    subprocess.run(cmd, check=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
