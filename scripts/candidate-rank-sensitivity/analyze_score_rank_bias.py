#!/usr/bin/env python3
"""Analyze LiteRT-compatible score-level rank bias.

This script is the Layer 2A companion for the candidate-rank-sensitivity
package. It stays within the public LiteRT-LM result surface and analyzes
output-level score behavior rather than hidden states:

- how often the selected candidate is the first-listed candidate
- how often the selected candidate is the last-listed candidate
- how often the selected candidate lands on either edge of the list
- how often the selected candidate matches the highest-confidence candidate
- how selected ranks compare with a uniform baseline across varying list sizes
- which examples are most sensitive to confidence reassignment

Input format:
  JSONL rows from `eval_confidence_score_sensitivity.py`

Required fields per row:
- example_id
- trial_id
- candidate_order
- final_answer
- selected_candidate_rank
- highest_confidence_rank

The script is intentionally score-level, not mechanistic. It does not require
logits, activations, or a backend that exposes hidden tensors.
"""
from __future__ import annotations

import argparse
import json
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from _common import DEFAULT_OUTPUT_DIR, canonical_answer_from_text, load_jsonl


def normalize(text: Any) -> str:
    return " ".join(str(text or "").lower().replace("_", " ").split())


def load_rows(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"Results JSONL not found: {path}")
    return load_jsonl(path)


def write_json(path: Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False))


def int_or_none(value: Any) -> int | None:
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value)
    return None


def candidate_count(row: dict[str, Any]) -> int:
    candidates = row.get("candidate_order")
    return len(candidates) if isinstance(candidates, list) else 0


def expected_uniform_rank_rate(rows: list[dict[str, Any]], rank: int) -> float:
    total = 0.0
    for row in rows:
        n = candidate_count(row)
        if n >= rank and n > 0:
            total += 1.0 / n
    return total / len(rows) if rows else 0.0


def summarize(rows: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row.get("example_id"))].append(row)

    if not grouped:
        raise ValueError("No rows found in results JSONL.")

    example_summaries = []
    flip_examples = []
    all_variant_rows: list[dict[str, Any]] = []

    selected_rank_counts = Counter()
    last_rank_selected_count = 0
    edge_selected_count = 0
    top_confidence_rank_counts = Counter()
    agreement_count = 0
    selected_rank_values: list[int] = []
    top_confidence_rank_values: list[int] = []
    selected_minus_top: list[int] = []
    answer_changed_count = 0
    total_variant_rows = 0
    total_original_rows = 0

    for example_id, example_rows in grouped.items():
        original_rows = [
            r
            for r in example_rows
            if normalize(r.get("confidence_assignment") or r.get("trial_id")) == "original"
        ]
        variant_rows = [
            r
            for r in example_rows
            if normalize(r.get("confidence_assignment") or r.get("trial_id")) != "original"
        ]
        if not original_rows:
            raise ValueError(f"Example {example_id} has no original row.")

        original = original_rows[0]
        original_answer = canonical_answer_from_text(original.get("final_answer") or original.get("raw_response"))

        example_selected_ranks: list[int] = []
        example_top_ranks: list[int] = []
        example_changed = 0
        example_rank1_selected = 0
        example_last_selected = 0
        example_edge_selected = 0
        example_top_selected = 0
        example_rows_total = 0

        total_original_rows += 1

        for row in variant_rows:
            total_variant_rows += 1
            example_rows_total += 1
            all_variant_rows.append(row)

            selected_rank = int_or_none(row.get("selected_candidate_rank"))
            top_rank = int_or_none(row.get("highest_confidence_rank"))
            if selected_rank is not None:
                selected_rank_counts[selected_rank] += 1
                selected_rank_values.append(selected_rank)
                example_selected_ranks.append(selected_rank)
                if selected_rank == 1:
                    example_rank1_selected += 1
                n_candidates = candidate_count(row)
                if n_candidates and selected_rank == n_candidates:
                    last_rank_selected_count += 1
                    example_last_selected += 1
                if n_candidates and (selected_rank == 1 or selected_rank == n_candidates):
                    edge_selected_count += 1
                    example_edge_selected += 1
            if top_rank is not None:
                top_confidence_rank_counts[top_rank] += 1
                top_confidence_rank_values.append(top_rank)
                example_top_ranks.append(top_rank)

            if selected_rank is not None and top_rank is not None:
                selected_minus_top.append(selected_rank - top_rank)
                if selected_rank == top_rank:
                    agreement_count += 1
                    example_top_selected += 1

            variant_answer = canonical_answer_from_text(row.get("final_answer") or row.get("raw_response"))
            if variant_answer != original_answer:
                answer_changed_count += 1
                example_changed += 1

        example_summaries.append(
            {
                "example_id": example_id,
                "original_answer": original_answer,
                "variant_rows": example_rows_total,
                "answer_changed_rate": (example_changed / example_rows_total) if example_rows_total else 0.0,
                "rank1_selected_rate": (example_rank1_selected / example_rows_total) if example_rows_total else 0.0,
                "last_rank_selected_rate": (example_last_selected / example_rows_total) if example_rows_total else 0.0,
                "edge_selected_rate": (example_edge_selected / example_rows_total) if example_rows_total else 0.0,
                "top_confidence_selected_rate": (example_top_selected / example_rows_total) if example_rows_total else 0.0,
                "mean_selected_rank": statistics.fmean(example_selected_ranks) if example_selected_ranks else None,
                "mean_highest_confidence_rank": statistics.fmean(example_top_ranks) if example_top_ranks else None,
                "mean_selected_minus_top_rank": statistics.fmean([s - t for s, t in zip(example_selected_ranks, example_top_ranks)])
                if example_selected_ranks and example_top_ranks and len(example_selected_ranks) == len(example_top_ranks)
                else None,
            }
        )

        if example_changed:
            flip_examples.append(
                {
                    "example_id": example_id,
                    "original_answer": original_answer,
                    "change_count": example_changed,
                    "variant_rows": example_rows_total,
                    "rank1_selected_rate": (example_rank1_selected / example_rows_total) if example_rows_total else 0.0,
                    "last_rank_selected_rate": (example_last_selected / example_rows_total) if example_rows_total else 0.0,
                    "edge_selected_rate": (example_edge_selected / example_rows_total) if example_rows_total else 0.0,
                    "top_confidence_selected_rate": (example_top_selected / example_rows_total) if example_rows_total else 0.0,
                }
            )

    uniform_first_rate = expected_uniform_rank_rate(all_variant_rows, 1)
    uniform_second_rate = expected_uniform_rank_rate(all_variant_rows, 2)
    uniform_third_rate = expected_uniform_rank_rate(all_variant_rows, 3)
    uniform_fourth_rate = expected_uniform_rank_rate(all_variant_rows, 4)
    uniform_fifth_rate = expected_uniform_rank_rate(all_variant_rows, 5)

    selected_rank_mean = statistics.fmean(selected_rank_values) if selected_rank_values else None
    top_rank_mean = statistics.fmean(top_confidence_rank_values) if top_confidence_rank_values else None
    selected_minus_top_mean = statistics.fmean(selected_minus_top) if selected_minus_top else None

    summary = {
        "n_examples": len(grouped),
        "n_original_rows": total_original_rows,
        "n_variant_rows": total_variant_rows,
        "answer_changed_rate": (answer_changed_count / total_variant_rows) if total_variant_rows else 0.0,
        "rank1_selected_rate": (selected_rank_counts[1] / total_variant_rows) if total_variant_rows else 0.0,
        "last_rank_selected_rate": (last_rank_selected_count / total_variant_rows) if total_variant_rows else 0.0,
        "edge_selected_rate": (edge_selected_count / total_variant_rows) if total_variant_rows else 0.0,
        "top_confidence_selected_rate": (agreement_count / total_variant_rows) if total_variant_rows else 0.0,
        "mean_selected_rank": selected_rank_mean,
        "mean_highest_confidence_rank": top_rank_mean,
        "mean_selected_minus_top_rank": selected_minus_top_mean,
        "selected_rank_distribution": {str(rank): count for rank, count in sorted(selected_rank_counts.items())},
        "top_confidence_rank_distribution": {str(rank): count for rank, count in sorted(top_confidence_rank_counts.items())},
        "uniform_baseline_rank_rates": {
            "rank1": uniform_first_rate,
            "rank2": uniform_second_rate,
            "rank3": uniform_third_rate,
            "rank4": uniform_fourth_rate,
            "rank5": uniform_fifth_rate,
        },
        "rank1_bias_delta_vs_uniform": (selected_rank_counts[1] / total_variant_rows - uniform_first_rate)
        if total_variant_rows
        else 0.0,
        "last_rank_bias_delta_vs_uniform": (last_rank_selected_count / total_variant_rows - uniform_fifth_rate)
        if total_variant_rows
        else 0.0,
        "edge_selection_rate": (edge_selected_count / total_variant_rows) if total_variant_rows else 0.0,
        "edge_selection_delta_vs_uniform": (
            (edge_selected_count / total_variant_rows) - (uniform_first_rate + uniform_fifth_rate)
        )
        if total_variant_rows
        else 0.0,
        "top_confidence_agreement_rate": (agreement_count / total_variant_rows) if total_variant_rows else 0.0,
        "examples_with_any_flip": len(flip_examples),
        "example_summaries": example_summaries,
        "brittle_examples": sorted(flip_examples, key=lambda item: (-item["change_count"], item["example_id"]))[:10],
    }
    return summary


def print_report(summary: dict[str, Any], max_examples: int = 10) -> None:
    print("Score-rank bias summary")
    print(f"  examples                   : {summary['n_examples']}")
    print(f"  variant rows               : {summary['n_variant_rows']}")
    print(f"  answer_changed_rate        : {summary['answer_changed_rate']:.1%}")
    print(f"  rank1_selected_rate        : {summary['rank1_selected_rate']:.1%}")
    print(f"  last_rank_selected_rate    : {summary['last_rank_selected_rate']:.1%}")
    print(f"  edge_selected_rate         : {summary['edge_selected_rate']:.1%}")
    print(f"  top_confidence_selected    : {summary['top_confidence_selected_rate']:.1%}")
    if summary.get("mean_selected_rank") is not None:
        print(f"  mean_selected_rank         : {summary['mean_selected_rank']:.2f}")
    if summary.get("mean_highest_confidence_rank") is not None:
        print(f"  mean_highest_conf_rank     : {summary['mean_highest_confidence_rank']:.2f}")
    if summary.get("mean_selected_minus_top_rank") is not None:
        print(f"  mean_selected_minus_top    : {summary['mean_selected_minus_top_rank']:.2f}")
    print(f"  rank1_bias_delta_vs_uniform: {summary['rank1_bias_delta_vs_uniform']:+.1%}")
    print(f"  last_rank_bias_delta_vs_uniform: {summary['last_rank_bias_delta_vs_uniform']:+.1%}")
    print(f"  edge_selection_delta_vs_uniform: {summary['edge_selection_delta_vs_uniform']:+.1%}")
    print(f"  examples_with_any_flip     : {summary['examples_with_any_flip']}")
    print(f"  top_confidence_agreement   : {summary['top_confidence_agreement_rate']:.1%}")
    print()
    if summary["brittle_examples"]:
        print("Most confidence-sensitive examples:")
        for item in summary["brittle_examples"][:max_examples]:
            print(
                f"- {item['example_id']}\n"
                f"  original: {item['original_answer']}\n"
                f"  changed trials: {item['change_count']}/{item['variant_rows']}\n"
                f"  rank1_selected: {item['rank1_selected_rate']:.1%}\n"
                f"  top_conf_selected: {item['top_confidence_selected_rate']:.1%}"
            )
    else:
        print("No changed predictions found in the evaluated rows.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--results",
        default=str(DEFAULT_OUTPUT_DIR / "confidence_score_results.jsonl"),
        help="Result JSONL from eval_confidence_score_sensitivity.py",
    )
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT_DIR / "score_rank_bias_summary.json"),
        help="Output JSON summary",
    )
    parser.add_argument("--max-examples", type=int, default=10, help="How many brittle examples to print")
    args = parser.parse_args()

    rows = load_rows(Path(args.results))
    if not rows:
        raise ValueError(f"No rows found in results JSONL: {args.results}")

    summary = summarize(rows)
    output_path = Path(args.output)
    write_json(output_path, summary)
    print_report(summary, max_examples=args.max_examples)
    print(f"\nWrote summary JSON to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
