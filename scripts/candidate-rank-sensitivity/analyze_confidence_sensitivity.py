#!/usr/bin/env python3
"""Analyze confidence-score sensitivity from score-rich trial results.

This script analyzes a JSONL file where each row represents one trial of a frozen
example. It expects per-trial candidate logits (or equivalent scores) so it can
compute probability-based diagnostics for candidate-rank sensitivity.

Required row fields (minimum):
- example_id
- trial_id
- order_type (original / shuffled / reversed / etc.)
- candidate_order: list of candidate dicts (each with scientific_name / common_name)
- one of: candidate_logits, logits, option_logits

Optional row fields:
- selected_candidate_rank
- selected_option_id
- final_answer
- ground_truth_species
- ground_truth_common_name
- raw_response
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


def load_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise FileNotFoundError(f"Results JSONL not found: {path}")
    rows: list[dict[str, Any]] = []
    with path.open() as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ValueError(f"Failed to parse JSONL line {line_no} in {path}: {exc}") from exc
    return rows


def write_json(path: Path, obj: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False))


def normalize(text: Any) -> str:
    return " ".join(str(text or "").lower().replace("_", " ").split())


def canonical_answer(text: Any) -> str:
    return normalize(text)


def softmax(values: list[float]) -> list[float]:
    if not values:
        return []
    m = max(values)
    exps = [math.exp(v - m) for v in values]
    denom = sum(exps)
    return [v / denom for v in exps]


def extract_candidate_label(candidate: dict[str, Any]) -> str:
    return str(
        candidate.get("scientific_name")
        or candidate.get("latin")
        or candidate.get("common_name")
        or candidate.get("common")
        or candidate.get("label")
        or candidate.get("name")
        or ""
    ).strip()


def extract_option_id(candidate: dict[str, Any], index: int) -> str:
    raw = candidate.get("option_id") or candidate.get("option") or candidate.get("letter") or candidate.get("id")
    if raw is not None and str(raw).strip():
        return str(raw).strip()
    # default to A/B/C/D style if the row has no explicit option id.
    if index < 26:
        return chr(ord('A') + index)
    return str(index + 1)


def candidate_labels_and_logits(row: dict[str, Any]) -> tuple[list[str], list[str], list[float]]:
    candidates = row.get("candidate_order") or []
    labels = [extract_candidate_label(c) for c in candidates]
    option_ids = [extract_option_id(c, i) for i, c in enumerate(candidates)]

    logits = None
    if isinstance(row.get("candidate_logits"), list):
        logits = row["candidate_logits"]
    elif isinstance(row.get("logits"), list):
        logits = row["logits"]
    elif isinstance(row.get("option_logits"), dict):
        opt = row["option_logits"]
        logits = []
        for oid in option_ids:
            if oid in opt:
                logits.append(float(opt[oid]))
            elif oid.upper() in opt:
                logits.append(float(opt[oid.upper()]))
            elif oid.lower() in opt:
                logits.append(float(opt[oid.lower()]))
            else:
                raise ValueError(f"Missing logit for option {oid} in row {row.get('example_id')} / {row.get('trial_id')}")
    elif isinstance(row.get("candidate_scores"), list):
        logits = row["candidate_scores"]

    if logits is None:
        raise ValueError(
            f"Row {row.get('example_id')} / {row.get('trial_id')} is missing candidate logits/scores. "
            "Expected candidate_logits, logits, option_logits, or candidate_scores."
        )
    if len(logits) != len(labels):
        raise ValueError(
            f"Row {row.get('example_id')} / {row.get('trial_id')} has {len(logits)} logits but {len(labels)} candidates."
        )
    return labels, option_ids, [float(x) for x in logits]


def selected_index(row: dict[str, Any], labels: list[str], logits: list[float]) -> int:
    if isinstance(row.get("selected_candidate_rank"), int) and row["selected_candidate_rank"] >= 1:
        idx = row["selected_candidate_rank"] - 1
        if idx < len(labels):
            return idx
    if isinstance(row.get("selected_option_id"), str):
        wanted = normalize(row["selected_option_id"])
        for i, cand in enumerate(row.get("candidate_order") or []):
            oid = normalize(extract_option_id(cand, i))
            if oid == wanted:
                return i
    if row.get("final_answer"):
        ans = canonical_answer(row["final_answer"])
        for i, label in enumerate(labels):
            if canonical_answer(label) == ans:
                return i
    return max(range(len(logits)), key=lambda i: logits[i])


def confidence_value(logits: list[float]) -> float:
    return max(logits) - (sum(logits) / len(logits)) if logits else 0.0


def confidence_gap(probabilities: list[float]) -> float:
    if len(probabilities) < 2:
        return 0.0
    top_two = sorted(probabilities, reverse=True)[:2]
    return top_two[0] - top_two[1]


def variance(values: list[float]) -> float:
    if len(values) < 2:
        return 0.0
    return statistics.pvariance(values)


def summarize(rows: list[dict[str, Any]], gap_threshold: float = 0.1, ambiguous_topk: int = 3) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row.get("example_id"))].append(row)

    per_image = []
    confidence_stable: list[float] = []
    confidence_flipped: list[float] = []
    brittle_images = []
    default_bias = Counter()
    default_bias_ambiguous = Counter()
    default_option_bias = Counter()
    default_option_bias_ambiguous = Counter()
    ambiguous_row_count = 0
    total_variant_rows = 0
    total_flips = 0

    for example_id, example_rows in grouped.items():
        original_rows = [r for r in example_rows if str(r.get("order_type")).lower() == "original"]
        variant_rows = [r for r in example_rows if str(r.get("order_type")).lower() != "original"]
        if not original_rows:
            raise ValueError(f"Example {example_id} has no original row.")
        original = original_rows[0]
        original_labels, original_option_ids, original_logits = candidate_labels_and_logits(original)
        original_probs = softmax(original_logits)
        original_answer = canonical_answer(original.get("final_answer") or original_labels[selected_index(original, original_labels, original_logits)])
        original_sel = selected_index(original, original_labels, original_logits)
        original_conf = confidence_value(original_logits)

        # Probability variance per candidate species across shuffles.
        species_to_probs: dict[str, list[float]] = defaultdict(list)
        row_details = []
        example_flip_count = 0
        example_ambiguous = []
        example_default_counts = Counter()
        example_option_counts = Counter()

        for row in variant_rows:
            labels, option_ids, logits = candidate_labels_and_logits(row)
            probs = softmax(logits)
            sel_idx = selected_index(row, labels, logits)
            sel_label = canonical_answer(labels[sel_idx])
            gap = confidence_gap(probs)
            conf = confidence_value(logits)
            total_variant_rows += 1
            if canonical_answer(row.get("final_answer") or labels[sel_idx]) != original_answer:
                total_flips += 1
                example_flip_count += 1
                confidence_flipped.append(conf)
            else:
                confidence_stable.append(conf)

            if gap < gap_threshold:
                ambiguous_row_count += 1
                example_ambiguous.append(
                    {
                        "trial_id": row.get("trial_id"),
                        "selected_candidate_rank": row.get("selected_candidate_rank") or (sel_idx + 1),
                        "selected_option_id": row.get("selected_option_id") or option_ids[sel_idx],
                        "gap": gap,
                        "confidence": conf,
                        "final_answer": row.get("final_answer") or labels[sel_idx],
                    }
                )
                default_bias_ambiguous[str(row.get("selected_candidate_rank") or (sel_idx + 1))] += 1
                default_option_bias_ambiguous[str(row.get("selected_option_id") or option_ids[sel_idx])] += 1
            default_bias[str(row.get("selected_candidate_rank") or (sel_idx + 1))] += 1
            default_option_bias[str(row.get("selected_option_id") or option_ids[sel_idx])] += 1
            example_default_counts[str(row.get("selected_candidate_rank") or (sel_idx + 1))] += 1
            example_option_counts[str(row.get("selected_option_id") or option_ids[sel_idx])] += 1

            row_details.append(
                {
                    "trial_id": row.get("trial_id"),
                    "confidence": conf,
                    "gap": gap,
                    "selected_candidate_rank": row.get("selected_candidate_rank") or (sel_idx + 1),
                    "selected_option_id": row.get("selected_option_id") or option_ids[sel_idx],
                    "final_answer": row.get("final_answer") or labels[sel_idx],
                }
            )

            for label, prob in zip(labels, probs):
                species_to_probs[canonical_answer(label)].append(prob)

        pbm_by_species = {sp: variance(vals) for sp, vals in species_to_probs.items()}
        pbm_mean = sum(pbm_by_species.values()) / len(pbm_by_species) if pbm_by_species else 0.0
        mean_gap = statistics.fmean([r["gap"] for r in row_details]) if row_details else 0.0
        mean_conf = statistics.fmean([r["confidence"] for r in row_details]) if row_details else 0.0

        brittle = [r for r in row_details if r["gap"] < gap_threshold]
        if brittle:
            brittle_images.append(
                {
                    "example_id": example_id,
                    "brittle_rows": brittle,
                    "mean_gap": mean_gap,
                    "mean_confidence": mean_conf,
                    "pbm_mean": pbm_mean,
                    "flip_rate": (example_flip_count / len(variant_rows)) if variant_rows else 0.0,
                }
            )

        per_image.append(
            {
                "example_id": example_id,
                "n_variant_rows": len(variant_rows),
                "flip_count": example_flip_count,
                "flip_rate": (example_flip_count / len(variant_rows)) if variant_rows else 0.0,
                "original_confidence": original_conf,
                "mean_variant_confidence": mean_conf,
                "mean_variant_gap": mean_gap,
                "pbm_mean": pbm_mean,
                "pbm_by_species": pbm_by_species,
                "ambiguous_rows": example_ambiguous,
                "ambiguous_row_count": len(example_ambiguous),
                "default_rank_histogram": dict(example_default_counts),
                "default_option_histogram": dict(example_option_counts),
                "original_selected_candidate_rank": original.get("selected_candidate_rank") or (original_sel + 1),
                "original_selected_option_id": original.get("selected_option_id") or original_option_ids[original_sel],
            }
        )

    mean_conf_stable = statistics.fmean(confidence_stable) if confidence_stable else 0.0
    mean_conf_flipped = statistics.fmean(confidence_flipped) if confidence_flipped else 0.0
    pbm_overall = statistics.fmean([item["pbm_mean"] for item in per_image]) if per_image else 0.0
    gap_buckets = Counter()
    for item in per_image:
        if item["mean_variant_gap"] < gap_threshold:
            gap_buckets["brittle"] += 1
        else:
            gap_buckets["stable"] += 1

    evidence = {
        "rank_histogram_all": dict(default_bias),
        "rank_histogram_ambiguous": dict(default_bias_ambiguous),
        "option_histogram_all": dict(default_option_bias),
        "option_histogram_ambiguous": dict(default_option_bias_ambiguous),
        "ambiguous_row_count": ambiguous_row_count,
        "total_variant_rows": total_variant_rows,
        "rank1_share_ambiguous": (default_bias_ambiguous.get("1", 0) / ambiguous_row_count) if ambiguous_row_count else 0.0,
        "rank1_share_all": (default_bias.get("1", 0) / total_variant_rows) if total_variant_rows else 0.0,
        "top_option_share_ambiguous": (max(default_option_bias_ambiguous.values()) / ambiguous_row_count) if ambiguous_row_count and default_option_bias_ambiguous else 0.0,
    }

    return {
        "n_examples": len(grouped),
        "n_rows": len(rows),
        "n_variant_rows": total_variant_rows,
        "flip_rate": (total_flips / total_variant_rows) if total_variant_rows else 0.0,
        "mean_confidence_stable": mean_conf_stable,
        "mean_confidence_flipped": mean_conf_flipped,
        "pbm_overall_mean": pbm_overall,
        "gap_threshold": gap_threshold,
        "gap_buckets": dict(gap_buckets),
        "brittle_images": brittle_images,
        "per_image": per_image,
        "default_order_evidence": evidence,
    }


def print_report(summary: dict[str, Any], max_examples: int = 10) -> None:
    print("Confidence-score sensitivity report")
    print(f"  examples                 : {summary['n_examples']}")
    print(f"  rows                     : {summary['n_rows']}")
    print(f"  variant rows             : {summary['n_variant_rows']}")
    print(f"  flip_rate                : {summary['flip_rate']:.1%}")
    print(f"  mean_confidence_stable   : {summary['mean_confidence_stable']:.4f}")
    print(f"  mean_confidence_flipped  : {summary['mean_confidence_flipped']:.4f}")
    print(f"  pbm_overall_mean         : {summary['pbm_overall_mean']:.6f}")
    print(f"  gap_threshold            : {summary['gap_threshold']:.3f}")
    print(f"  brittle_images           : {len(summary['brittle_images'])}")
    print(f"  gap_buckets              : {summary['gap_buckets']}")
    print(f"  default_order_evidence   : {summary['default_order_evidence']}")
    print()
    if summary["brittle_images"]:
        print("Brittle images (top examples):")
        for item in summary["brittle_images"][:max_examples]:
            print(
                f"- {item['example_id']} | mean_gap={item['mean_gap']:.4f} | "
                f"mean_conf={item['mean_confidence']:.4f} | pbm_mean={item['pbm_mean']:.6f} | "
                f"flip_rate={item['flip_rate']:.1%}"
            )
    else:
        print("No brittle images found below the configured gap threshold.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", required=True, help="Score-rich trial results JSONL")
    parser.add_argument("--output", required=True, help="Output summary JSON")
    parser.add_argument("--gap-threshold", type=float, default=0.1, help="Confidence gap threshold for brittle cases")
    parser.add_argument("--max-examples", type=int, default=10, help="How many brittle examples to print")
    args = parser.parse_args()

    rows = load_jsonl(Path(args.results))
    summary = summarize(rows, gap_threshold=args.gap_threshold)
    out = Path(args.output)
    write_json(out, summary)
    print_report(summary, max_examples=args.max_examples)
    print(f"\nWrote summary JSON to {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
