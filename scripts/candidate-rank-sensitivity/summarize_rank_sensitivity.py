#!/usr/bin/env python3
"""Summarize candidate-rank sensitivity results into a compact report."""
from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

from _common import (
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    canonical_answer_from_text,
    load_jsonl,
    normalize_text,
    same_answer,
)


def pct(num: int, den: int) -> float:
    return num / den if den else 0.0


def answer_signature(row: dict) -> str:
    return normalize_text(
        row.get("predicted_scientific_name")
        or row.get("predicted_common_name")
        or row.get("final_answer")
        or row.get("raw_response")
    )


def summarize(rows: list[dict]) -> dict:
    grouped: dict[str, list[dict]] = defaultdict(list)
    for row in rows:
        grouped[row["example_id"]].append(row)

    example_summaries = []
    flip_examples = []
    directional = Counter()
    all_changed = 0
    all_shuffled = 0
    all_original_correct = 0
    all_shuffled_correct = 0
    all_original = 0
    all_trials = 0
    all_first_rank = 0
    all_rank1_shuffled = 0
    original_accuracy_den = 0
    shuffled_accuracy_den = 0

    for example_id, example_rows in grouped.items():
        original_rows = [r for r in example_rows if r.get("order_type") == "original"]
        variant_rows = [r for r in example_rows if r.get("order_type") != "original"]
        if not original_rows:
            raise ExperimentError(f"Example {example_id} has no original-order row in the results file.")
        original = original_rows[0]
        original_signature = answer_signature(original)
        original_answer = canonical_answer_from_text(original.get("final_answer") or original.get("raw_response"))

        changed = 0
        first_rank = 0
        rank1_matches = 0
        shuffled_correct = 0
        valid_shuffled = 0
        unique_answers = {original_signature}
        changed_rows = []

        if original.get("is_correct_scientific_name") is not None:
            original_accuracy_den += 1
            if original.get("is_correct_scientific_name") is True:
                all_original_correct += 1
        all_original += 1

        for row in variant_rows:
            valid_shuffled += 1
            all_trials += 1
            row_signature = answer_signature(row)
            unique_answers.add(row_signature)
            if row_signature != original_signature:
                changed += 1
                changed_rows.append(
                    {
                        "trial_id": row.get("trial_id"),
                        "final_answer": row.get("final_answer"),
                        "predicted_scientific_name": row.get("predicted_scientific_name"),
                        "predicted_common_name": row.get("predicted_common_name"),
                        "selected_candidate_rank": row.get("selected_candidate_rank"),
                        "raw_response": row.get("raw_response"),
                    }
                )
            if row.get("selected_candidate_rank") == 1:
                first_rank += 1
                all_first_rank += 1
            if row.get("candidate_identity_order"):
                rank = row.get("selected_candidate_rank")
                if isinstance(rank, int) and 1 <= rank <= len(row["candidate_identity_order"]):
                    if normalize_text(row.get("predicted_scientific_name") or row.get("final_answer")) == normalize_text(row["candidate_identity_order"][rank - 1]):
                        rank1_matches += 1
                        all_rank1_shuffled += 1
            if row.get("is_correct_scientific_name") is not None:
                shuffled_accuracy_den += 1
                if row.get("is_correct_scientific_name") is True:
                    shuffled_correct += 1
                    all_shuffled_correct += 1
            all_shuffled += 1

        changed_rate = pct(changed, valid_shuffled)
        retained_rate = 1.0 - changed_rate if valid_shuffled else 0.0
        example_summaries.append(
            {
                "example_id": example_id,
                "original_answer": original_answer,
                "shuffled_trials": valid_shuffled,
                "answer_changed_rate": changed_rate,
                "original_answer_retained_rate": retained_rate,
                "unique_answers_per_image": len(unique_answers),
                "first_candidate_selected_rate": pct(first_rank, valid_shuffled),
                "accuracy_original_order": original.get("is_correct_scientific_name"),
                "accuracy_shuffled_order": pct(shuffled_correct, valid_shuffled) if valid_shuffled else None,
                "changed_trials": changed_rows,
            }
        )

        all_changed += changed
        if changed_rows:
            flip_examples.append(
                {
                    "example_id": example_id,
                    "original_answer": original_answer,
                    "changed_trials": changed_rows,
                    "change_count": len(changed_rows),
                }
            )

        if original.get("is_correct_scientific_name") is True:
            if any(r.get("is_correct_scientific_name") is True for r in variant_rows):
                directional["orig_correct_shuf_correct"] += 1
            else:
                directional["orig_correct_shuf_wrong"] += 1
        elif original.get("is_correct_scientific_name") is False:
            if any(r.get("is_correct_scientific_name") is True for r in variant_rows):
                directional["orig_wrong_shuf_correct"] += 1
            else:
                directional["orig_wrong_shuf_wrong"] += 1

    summary = {
        "n_examples": len(grouped),
        "n_original_rows": all_original,
        "n_variant_rows": all_shuffled,
        "answer_changed_rate": pct(all_changed, all_shuffled),
        "original_answer_retained_rate": 1.0 - pct(all_changed, all_shuffled) if all_shuffled else 0.0,
        "unique_answers_per_image_mean": (
            sum(item["unique_answers_per_image"] for item in example_summaries) / len(example_summaries)
            if example_summaries
            else 0.0
        ),
        "unique_answers_per_image_median": (
            sorted(item["unique_answers_per_image"] for item in example_summaries)[len(example_summaries) // 2]
            if example_summaries
            else 0.0
        ),
        "first_candidate_selected_rate": pct(all_first_rank, all_shuffled),
        "rank1_prediction_match_rate": pct(all_rank1_shuffled, all_shuffled),
        "accuracy_original_order": pct(all_original_correct, original_accuracy_den) if original_accuracy_den else None,
        "accuracy_shuffled_order": pct(all_shuffled_correct, shuffled_accuracy_den) if shuffled_accuracy_den else None,
        "examples_with_any_flip": len(flip_examples),
        "directional_flip_counts": dict(directional),
        "examples": example_summaries,
        "changed_examples": flip_examples,
    }
    return summary


def print_summary(summary: dict) -> None:
    print("Candidate-rank sensitivity summary")
    print(f"  examples                   : {summary['n_examples']}")
    print(f"  trial rows                 : {summary['n_variant_rows']}")
    print(f"  answer_changed_rate        : {summary['answer_changed_rate']:.1%}")
    print(f"  original_answer_retained   : {summary['original_answer_retained_rate']:.1%}")
    print(f"  unique_answers/image (μ)   : {summary['unique_answers_per_image_mean']:.2f}")
    print(f"  unique_answers/image (med) : {summary['unique_answers_per_image_median']:.2f}")
    print(f"  first_candidate_selected   : {summary['first_candidate_selected_rate']:.1%}")
    print(f"  rank1_prediction_match     : {summary['rank1_prediction_match_rate']:.1%}")
    if summary.get("accuracy_original_order") is not None:
        print(f"  accuracy_original_order    : {summary['accuracy_original_order']:.1%}")
    if summary.get("accuracy_shuffled_order") is not None:
        print(f"  accuracy_variant_order     : {summary['accuracy_shuffled_order']:.1%}")
    print(f"  examples_with_any_flip     : {summary['examples_with_any_flip']}")
    if summary.get("directional_flip_counts"):
        print(f"  directional_flip_counts    : {summary['directional_flip_counts']}")
    print()
    if summary["changed_examples"]:
        print("Examples with changed predictions after order perturbation:")
        for item in summary["changed_examples"][:10]:
            print(f"- {item['example_id']}")
            print(f"  original: {item['original_answer']}")
            for trial in item["changed_trials"]:
                print(
                    f"  {trial['trial_id']}: {trial['final_answer']} "
                    f"(rank={trial.get('selected_candidate_rank')})"
                )
    else:
        print("No changed predictions found in the evaluated rows.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, help="Result JSONL from eval_candidate_rank_sensitivity.py")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT_DIR / "rank_sensitivity_summary.json"), help="Output JSON")
    args = parser.parse_args()

    results_path = Path(args.results)
    if not results_path.exists():
        raise ExperimentError(f"Results JSONL not found: {results_path}")

    rows = load_jsonl(results_path)
    if not rows:
        raise ExperimentError(f"No rows found in results JSONL: {results_path}")

    summary = summarize(rows)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print_summary(summary)
    print(f"\nWrote summary JSON to {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
