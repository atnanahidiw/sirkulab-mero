#!/usr/bin/env python3
"""Analyze explanation faithfulness using output-level counterfactual consistency.

This treats the model's short_reason as the explanation signal and measures
whether it stays aligned with the selected answer under order perturbations.
The method is deliberately lightweight: it uses the already-collected original
and shuffled/reversed rows as counterfactual pairs, then scores

- answer/explanation coupling: does the explanation shift when the answer shifts?
- stance consistency: does the explanation mention the same coarse semantic
  bucket as the selected candidate?
- support alignment: does the explanation mention species/group terms that
  support the selected candidate?

The goal is not to prove causal faithfulness in the strict EDCT sense, but to
provide a proper, auditable counterfactual consistency audit for these self-
explanations without requiring image editing or a separate judge model.
"""
from __future__ import annotations

import argparse
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

from _common import (
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    candidate_common_name,
    candidate_genus,
    candidate_scientific_name,
    load_jsonl,
    normalize_text,
)


STOPWORDS = {
    "a",
    "an",
    "and",
    "as",
    "at",
    "based",
    "because",
    "but",
    "clear",
    "clearly",
    "consistent",
    "depicts",
    "displays",
    "for",
    "from",
    "general",
    "image",
    "in",
    "is",
    "it",
    "its",
    "like",
    "matches",
    "of",
    "on",
    "or",
    "others",
    "present",
    "reason",
    "selection",
    "shows",
    "some",
    "species",
    "the",
    "this",
    "to",
    "with",
}


ANIMAL_HINTS = {
    "animal",
    "animalia",
    "ape",
    "bird",
    "cuscus",
    "deer",
    "dog",
    "frog",
    "fish",
    "mammal",
    "monkey",
    "orangutan",
    "primate",
    "reptile",
    "shark",
    "snake",
    "turtle",
    "wombat",
}

PLANT_HINTS = {
    "plant",
    "plantae",
    "tree",
    "fern",
    "mangrove",
    "shrub",
    "bush",
    "vine",
    "climber",
    "foliage",
    "leaf",
    "breadfruit",
    "narra",
    "jati",
    "lempeni",
    "amugis",
}

MARINE_HINTS = {
    "marine",
    "sea",
    "reef",
    "underwater",
    "coral",
    "clam",
    "shell",
}


def parse_short_reason(raw_response: str) -> str:
    """Extract the short_reason from the model JSON response."""
    raw = str(raw_response or "").strip()
    if "```" in raw:
        if "```json" in raw:
            raw = raw.split("```json", 1)[1].split("```", 1)[0]
        else:
            raw = raw.split("```", 1)[1].split("```", 1)[0]
    match = re.search(r"\{.*\}", raw, re.DOTALL)
    payload = match.group(0) if match else raw
    try:
        parsed = json.loads(payload)
    except Exception:
        return ""
    if isinstance(parsed, dict):
        return str(parsed.get("short_reason") or parsed.get("reason") or "").strip()
    return ""


def candidate_terms(candidate: dict[str, Any]) -> list[str]:
    parts = [
        candidate_scientific_name(candidate),
        candidate_common_name(candidate),
        candidate_genus(candidate),
        str(candidate.get("kingdom") or "").strip(),
        str(candidate.get("visual_group") or "").strip(),
    ]
    terms: list[str] = []
    for part in parts:
        normalized = normalize_text(part)
        for token in normalized.split():
            token = token.strip()
            if token and len(token) > 2:
                terms.append(token)
    return list(dict.fromkeys(terms))


def selected_candidate(row: dict[str, Any]) -> dict[str, Any] | None:
    candidates = row.get("candidate_order") or []
    rank = row.get("selected_candidate_rank")
    if isinstance(rank, str) and rank.isdigit():
        rank = int(rank)
    if isinstance(rank, int) and 1 <= rank <= len(candidates):
        return candidates[rank - 1]

    answer = normalize_text(
        row.get("predicted_scientific_name")
        or row.get("predicted_common_name")
        or row.get("final_answer")
        or ""
    )
    for cand in candidates:
        names = [
            normalize_text(candidate_scientific_name(cand)),
            normalize_text(candidate_common_name(cand)),
            normalize_text(candidate_genus(cand)),
        ]
        if any(name and name in answer for name in names):
            return cand
    return None


def token_set(text: str) -> set[str]:
    words = {
        token
        for token in re.findall(r"[a-z0-9]+", normalize_text(text))
        if token not in STOPWORDS
    }
    return {token for token in words if len(token) > 2}


def jaccard(a: str, b: str) -> float:
    sa = token_set(a)
    sb = token_set(b)
    if not sa and not sb:
        return 1.0
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def bucket_for_reason(reason: str) -> str:
    t = normalize_text(reason)
    if any(h in t for h in MARINE_HINTS):
        return "marine"
    if any(h in t for h in PLANT_HINTS):
        return "plant"
    if any(h in t for h in ANIMAL_HINTS):
        return "animal"
    return "generic"


def bucket_for_candidate(candidate: dict[str, Any] | None) -> str:
    if candidate is None:
        return "generic"
    kingdom = normalize_text(candidate.get("kingdom") or "")
    visual_group = normalize_text(candidate.get("visual_group") or "")
    haystack = f"{kingdom} {visual_group}"
    if "plantae" in kingdom or any(h in haystack for h in PLANT_HINTS):
        return "plant"
    if any(h in haystack for h in MARINE_HINTS):
        return "marine"
    if "animalia" in kingdom or any(h in haystack for h in ANIMAL_HINTS):
        return "animal"
    return "generic"


def support_hit(reason: str, candidate: dict[str, Any] | None) -> bool:
    if candidate is None:
        return False
    reason_norm = normalize_text(reason)
    return any(term in reason_norm for term in candidate_terms(candidate))


def row_answer(row: dict[str, Any]) -> str:
    return normalize_text(
        row.get("predicted_scientific_name")
        or row.get("predicted_common_name")
        or row.get("final_answer")
        or ""
    )


def analyze(rows: list[dict[str, Any]]) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row.get("example_id"))].append(row)

    per_example = []
    support = Counter()
    stance = Counter()
    pair_similarity = Counter()
    flips = Counter()
    stale_examples = []

    for example_id, example_rows in grouped.items():
        original_rows = [r for r in example_rows if str(r.get("order_type")).lower() == "original"]
        variant_rows = [r for r in example_rows if str(r.get("order_type")).lower() != "original"]
        if not original_rows:
            raise ExperimentError(f"Example {example_id} has no original-order row.")
        original = original_rows[0]
        original_reason = parse_short_reason(original.get("raw_response") or "")
        original_answer = row_answer(original)
        original_candidate = selected_candidate(original)
        original_bucket = bucket_for_candidate(original_candidate)
        original_support = support_hit(original_reason, original_candidate)
        original_stance = bucket_for_reason(original_reason)

        support["original_total"] += 1
        support["original_supported"] += int(original_support)
        stance["original_total"] += 1
        stance["original_consistent"] += int(original_stance == original_bucket or original_stance == "generic")

        reason_similarities = []
        reason_similarities_flips = []
        reason_similarities_same = []

        for row in variant_rows:
            variant_reason = parse_short_reason(row.get("raw_response") or "")
            variant_answer = row_answer(row)
            variant_candidate = selected_candidate(row)
            variant_bucket = bucket_for_candidate(variant_candidate)
            variant_support = support_hit(variant_reason, variant_candidate)
            variant_stance = bucket_for_reason(variant_reason)

            sim = jaccard(original_reason, variant_reason)
            reason_similarities.append(sim)
            pair_similarity["variant_total"] += 1
            pair_similarity["sum"] += sim

            answer_changed = variant_answer != original_answer
            if answer_changed:
                flips["rows"] += 1
                reason_similarities_flips.append(sim)
                flips["answer_changed_and_reason_same"] += int(variant_reason == original_reason)
                flips["answer_changed_and_reason_similar"] += int(sim >= 0.8)
                flips["answer_changed_and_support_still_matches_original"] += int(support_hit(variant_reason, original_candidate))
                flips["answer_changed_and_variant_supported"] += int(variant_support)
                flips["answer_changed_and_stance_matches_variant"] += int(variant_stance == variant_bucket or variant_stance == "generic")
            else:
                reason_similarities_same.append(sim)

            support["variant_total"] += 1
            support["variant_supported"] += int(variant_support)
            stance["variant_total"] += 1
            stance["variant_consistent"] += int(variant_stance == variant_bucket or variant_stance == "generic")

        if reason_similarities_flips and all(sim >= 0.8 for sim in reason_similarities_flips):
            stale_examples.append(
                {
                    "example_id": example_id,
                    "original_answer": original.get("predicted_scientific_name") or original.get("final_answer"),
                    "original_reason": original_reason,
                    "flipped_variants": [
                        {
                            "trial_id": row.get("trial_id"),
                            "answer": row.get("predicted_scientific_name") or row.get("final_answer"),
                            "reason": parse_short_reason(row.get("raw_response") or ""),
                            "similarity_to_original_reason": jaccard(original_reason, parse_short_reason(row.get("raw_response") or "")),
                        }
                        for row in variant_rows
                        if row_answer(row) != original_answer
                    ],
                }
            )

        per_example.append(
            {
                "example_id": example_id,
                "original_answer": original.get("predicted_scientific_name") or original.get("final_answer"),
                "original_reason": original_reason,
                "original_reason_bucket": original_stance,
                "original_selected_bucket": original_bucket,
                "variant_rows": len(variant_rows),
                "variant_mean_similarity": sum(reason_similarities) / len(reason_similarities) if reason_similarities else 0.0,
                "variant_mean_similarity_same_answer": (
                    sum(reason_similarities_same) / len(reason_similarities_same)
                    if reason_similarities_same
                    else 0.0
                ),
                "variant_mean_similarity_flipped_answer": (
                    sum(reason_similarities_flips) / len(reason_similarities_flips)
                    if reason_similarities_flips
                    else 0.0
                ),
                "original_support": original_support,
                "original_stance_consistent": original_stance == original_bucket or original_stance == "generic",
                "flip_rows": sum(1 for row in variant_rows if row_answer(row) != original_answer),
            }
        )

    summary = {
        "n_examples": len(grouped),
        "n_rows": len(rows),
        "n_variant_rows": pair_similarity["variant_total"],
        "answer_flip_rate": (flips["rows"] / pair_similarity["variant_total"]) if pair_similarity["variant_total"] else 0.0,
        "mean_reason_jaccard": (pair_similarity["sum"] / pair_similarity["variant_total"]) if pair_similarity["variant_total"] else 0.0,
        "mean_reason_jaccard_same_answer": (
            sum(item["variant_mean_similarity_same_answer"] for item in per_example) / len(per_example)
            if per_example
            else 0.0
        ),
        "mean_reason_jaccard_flipped_answer": (
            sum(item["variant_mean_similarity_flipped_answer"] for item in per_example) / len(per_example)
            if per_example
            else 0.0
        ),
        "original_support_rate": (support["original_supported"] / support["original_total"]) if support["original_total"] else 0.0,
        "variant_support_rate": (support["variant_supported"] / support["variant_total"]) if support["variant_total"] else 0.0,
        "original_stance_consistency_rate": (
            stance["original_consistent"] / stance["original_total"] if stance["original_total"] else 0.0
        ),
        "variant_stance_consistency_rate": (
            stance["variant_consistent"] / stance["variant_total"] if stance["variant_total"] else 0.0
        ),
        "flip_reason_same_rate": (
            flips["answer_changed_and_reason_same"] / flips["rows"] if flips["rows"] else 0.0
        ),
        "flip_reason_similar_rate": (
            flips["answer_changed_and_reason_similar"] / flips["rows"] if flips["rows"] else 0.0
        ),
        "flip_variant_supported_rate": (
            flips["answer_changed_and_variant_supported"] / flips["rows"] if flips["rows"] else 0.0
        ),
        "flip_stance_matches_variant_rate": (
            flips["answer_changed_and_stance_matches_variant"] / flips["rows"] if flips["rows"] else 0.0
        ),
        "faithfulness_counterfactual_consistency_rate": (
            flips["answer_changed_and_variant_supported"] / flips["rows"] if flips["rows"] else 0.0
        ),
        "examples_with_stale_rationale": stale_examples,
        "per_example": per_example,
    }
    return summary


def print_report(summary: dict[str, Any], max_examples: int = 8) -> None:
    print("Explanation faithfulness audit")
    print(f"  examples                          : {summary['n_examples']}")
    print(f"  variant rows                      : {summary['n_variant_rows']}")
    print(f"  answer_flip_rate                  : {summary['answer_flip_rate']:.1%}")
    print(f"  mean_reason_jaccard               : {summary['mean_reason_jaccard']:.3f}")
    print(f"  mean_reason_jaccard_same_answer   : {summary['mean_reason_jaccard_same_answer']:.3f}")
    print(f"  mean_reason_jaccard_flipped_answer: {summary['mean_reason_jaccard_flipped_answer']:.3f}")
    print(f"  original_support_rate             : {summary['original_support_rate']:.1%}")
    print(f"  variant_support_rate              : {summary['variant_support_rate']:.1%}")
    print(f"  original_stance_consistency_rate  : {summary['original_stance_consistency_rate']:.1%}")
    print(f"  variant_stance_consistency_rate   : {summary['variant_stance_consistency_rate']:.1%}")
    print(f"  flip_reason_same_rate             : {summary['flip_reason_same_rate']:.1%}")
    print(f"  flip_reason_similar_rate          : {summary['flip_reason_similar_rate']:.1%}")
    print(f"  flip_variant_supported_rate       : {summary['flip_variant_supported_rate']:.1%}")
    print(f"  flip_stance_matches_variant_rate   : {summary['flip_stance_matches_variant_rate']:.1%}")
    print()

    if summary["examples_with_stale_rationale"]:
        print("Examples with stale rationale on answer flips:")
        for item in summary["examples_with_stale_rationale"][:max_examples]:
            print(f"- {item['example_id']}")
            print(f"  original: {item['original_answer']}")
            print(f"  reason  : {item['original_reason']}")
            for flip in item["flipped_variants"]:
                print(f"  {flip['trial_id']}: {flip['answer']} | sim={flip['similarity_to_original_reason']:.3f}")
                print(f"    {flip['reason']}")
    else:
        print("No stale-rationale examples found under the current heuristic.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, help="Rank-sensitivity results JSONL")
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUTPUT_DIR / "explanation_faithfulness_summary.json"),
        help="Output JSON summary",
    )
    parser.add_argument("--max-examples", type=int, default=8, help="How many stale examples to print")
    args = parser.parse_args()

    results_path = Path(args.results)
    if not results_path.exists():
        raise ExperimentError(f"Results JSONL not found: {results_path}")

    rows = load_jsonl(results_path)
    if not rows:
        raise ExperimentError(f"No rows found in results JSONL: {results_path}")

    summary = analyze(rows)
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print_report(summary, max_examples=args.max_examples)
    print(f"\nWrote summary JSON to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
