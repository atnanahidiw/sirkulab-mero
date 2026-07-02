#!/usr/bin/env python3
"""Check for compatible SAE artifacts before any Gemma Scope-style analysis."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

from common_hf import DEFAULT_OUTPUT_DIR, safe_write_json

DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "sae_inspection_status.json"


def parse_paths(values: list[str]) -> list[Path]:
    return [Path(value) for value in values if str(value).strip()]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Status JSON output")
    parser.add_argument("--model-id", default="google/gemma-4-E2B-it", help="Hugging Face model id")
    parser.add_argument("--sae-weights", action="append", default=[], help="Path to SAE weights or feature artifact")
    parser.add_argument("--feature-activations", action="append", default=[], help="Path to precomputed feature activations")
    parser.add_argument("--notes", default="", help="Optional notes about the artifacts")
    args = parser.parse_args()

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    sae_weights = parse_paths(args.sae_weights)
    feature_activations = parse_paths(args.feature_activations)
    provided = [path for path in [*sae_weights, *feature_activations] if path.exists()]

    if not provided:
        summary = {
            "status": "skipped",
            "reason": "No Gemma 4-compatible SAE or Gemma Scope artifacts were provided.",
            "model_id": args.model_id,
            "notes": [
                "Gemma Scope-style analysis is optional.",
                "Do not claim Gemma 4 SAE analysis unless compatible artifacts are available.",
            ],
        }
        safe_write_json(output_path, summary)
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0

    summary = {
        "status": "ready_for_surrogate_review",
        "model_id": args.model_id,
        "provided_artifacts": [str(path) for path in provided],
        "notes": [
            "Confirm that the artifacts are compatible with Gemma 4 before interpreting any features.",
            "If only Gemma 2 or Gemma 3 artifacts are available, label the analysis as a surrogate study.",
            args.notes.strip(),
        ],
    }
    safe_write_json(output_path, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
