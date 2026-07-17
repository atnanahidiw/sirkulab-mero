#!/usr/bin/env python3
"""Replicate candidate-rank likelihood with Hugging Face Gemma 4 logits."""
from __future__ import annotations

import argparse
import hashlib
import json
import random
from collections import defaultdict
from pathlib import Path

import torch

from common_hf import (
    DEFAULT_EXAMPLES,
    DEFAULT_MODEL_ID,
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    PROMPT_VARIANTS,
    build_prompt_variant_prompt,
    candidate_completion_text,
    candidate_display_name,
    candidate_scientific_name,
    load_hf_bundle,
    load_jsonl,
    make_candidate_prompt,
    move_candidate,
    safe_write_json,
    score_completion,
    set_seed,
    spearman_r,
    strip_confidence,
    write_jsonl,
)

DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "hf_logit_rank_bias.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "hf_logit_rank_bias_summary.json"
DEFAULT_POSITIONS = (1, 3, 5)
DEFAULT_PROMPT_VARIANT = "numbered_list"
DEFAULT_BOOTSTRAP_SAMPLES = 1000


def parse_positions(value: str) -> list[int]:
    positions = []
    for raw in value.split(","):
        raw = raw.strip()
        if raw:
            positions.append(int(raw))
    positions = sorted(set(positions))
    if not positions:
        raise ExperimentError("At least one target position is required")
    return positions


def apply_completion_prefix(completion: str, prefix_mode: str) -> str:
    if prefix_mode == "space":
        return f" {completion}"
    if prefix_mode == "newline":
        return f"\n{completion}"
    if prefix_mode == "none":
        return completion
    raise ExperimentError(f"Unknown completion prefix mode: {prefix_mode}")


def load_existing_keys(path: Path) -> set[tuple[str, str, int, int]]:
    if not path.exists():
        return set()
    keys = set()
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            keys.add(
                (
                    str(row.get("example_id")),
                    f"{int(row.get('source_rank', 0))}:{str(row.get('candidate_name'))}",
                    int(row.get("source_rank", 0)),
                    int(row.get("candidate_position", 0)),
                )
            )
    return keys


def build_prompt(candidates: list[dict], variant_name: str) -> str:
    if variant_name == "numbered_list":
        return make_candidate_prompt(candidates, list_style="numbered", answer_format="scientific_name_only")
    variant = next((v for v in PROMPT_VARIANTS if v.name == variant_name), None)
    if variant is None:
        raise ExperimentError(f"Unknown prompt variant: {variant_name}")
    return build_prompt_variant_prompt(candidates, variant)


def mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def percentile(sorted_values: list[float], fraction: float) -> float | None:
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    index = fraction * (len(sorted_values) - 1)
    lower = int(index)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = index - lower
    return float(sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight)


def bootstrap_example_level_ci(example_to_values: dict[str, list[float]], seed: int, samples: int = DEFAULT_BOOTSTRAP_SAMPLES) -> dict[str, float | None]:
    example_ids = sorted(example_to_values)
    if not example_ids:
        return {"mean": None, "ci_lower": None, "ci_upper": None, "bootstrap_samples": 0}
    rng = random.Random(seed)
    draws: list[float] = []
    for _ in range(samples):
        sampled_ids = [rng.choice(example_ids) for _ in example_ids]
        pooled: list[float] = []
        for example_id in sampled_ids:
            pooled.extend(example_to_values[example_id])
        if pooled:
            draws.append(sum(pooled) / len(pooled))
    draws.sort()
    observed = mean([value for values in example_to_values.values() for value in values])
    return {
        "mean": observed,
        "ci_lower": percentile(draws, 0.025),
        "ci_upper": percentile(draws, 0.975),
        "bootstrap_samples": len(draws),
    }


def build_null_rank_effect(by_candidate: dict[tuple[str, int, str], dict[int, dict]], positions: list[int], seed: int) -> dict[str, float | int | None]:
    rng = random.Random(seed)
    null_rows: list[tuple[int, float]] = []
    paired_rank1_vs_rank5: list[float] = []
    for traj in by_candidate.values():
        available_positions = sorted(pos for pos in traj if pos in positions)
        if not available_positions:
            continue
        shuffled_positions = available_positions[:]
        rng.shuffle(shuffled_positions)
        reassigned = {
            shuffled_pos: traj[original_pos]
            for original_pos, shuffled_pos in zip(available_positions, shuffled_positions)
        }
        for pos, row in reassigned.items():
            null_rows.append((pos, float(row["candidate_answer_avg_logprob"])))
        if 1 in reassigned and 5 in reassigned:
            paired_rank1_vs_rank5.append(
                float(reassigned[1]["candidate_answer_avg_logprob"]) - float(reassigned[5]["candidate_answer_avg_logprob"])
            )
    if not null_rows:
        return {
            "rank_1_minus_rank_5_mean_delta": None,
            "rank_logprob_correlation": None,
            "same_candidate_rank1_vs_rank5_mean_delta": None,
            "num_rows": 0,
        }
    null_rank_values = [float(pos) for pos, _ in null_rows]
    null_score_values = [score for _, score in null_rows]
    by_pos = defaultdict(list)
    for pos, score in null_rows:
        by_pos[pos].append(score)
    return {
        "rank_1_minus_rank_5_mean_delta": (
            (sum(by_pos[1]) / len(by_pos[1]) - sum(by_pos[5]) / len(by_pos[5]))
            if by_pos.get(1) and by_pos.get(5)
            else None
        ),
        "rank_logprob_correlation": spearman_r(null_rank_values, null_score_values),
        "same_candidate_rank1_vs_rank5_mean_delta": mean(paired_rank1_vs_rank5),
        "num_rows": len(null_rows),
    }


def summarise(rows: list[dict], positions: list[int], seed: int, bootstrap_samples: int) -> dict:
    by_position_avg = defaultdict(list)
    by_position_total = defaultdict(list)
    by_position_token_count = defaultdict(list)
    by_candidate: dict[tuple[str, int, str], dict[int, dict]] = defaultdict(dict)
    seen_examples: set[str] = set()
    pairwise_deltas = defaultdict(list)
    pairwise_example_deltas = defaultdict(lambda: defaultdict(list))
    candidate_centered_avg_by_rank = defaultdict(list)
    candidate_centered_total_by_rank = defaultdict(list)
    comparable_all_positions: dict[tuple[str, int, str], dict[int, dict]] = {}

    for row in rows:
        pos = int(row["candidate_position"])
        example_id = str(row["example_id"])
        candidate_name = str(row["candidate_name"])
        source_rank = int(row["source_rank"])
        avg_score = float(row["candidate_answer_avg_logprob"])
        total_score = float(row["candidate_answer_logprob"])
        seen_examples.add(example_id)
        by_position_avg[pos].append(avg_score)
        by_position_total[pos].append(total_score)
        by_position_token_count[pos].append(int(row["token_count"]))
        by_candidate[(example_id, source_rank, candidate_name)][pos] = row

    for traj_key, traj in by_candidate.items():
        avg_values = [float(row["candidate_answer_avg_logprob"]) for row in traj.values()]
        total_values = [float(row["candidate_answer_logprob"]) for row in traj.values()]
        avg_center = sum(avg_values) / len(avg_values)
        total_center = sum(total_values) / len(total_values)
        for pos, row in traj.items():
            candidate_centered_avg_by_rank[pos].append(float(row["candidate_answer_avg_logprob"]) - avg_center)
            candidate_centered_total_by_rank[pos].append(float(row["candidate_answer_logprob"]) - total_center)
        if all(pos in traj for pos in positions):
            comparable_all_positions[traj_key] = traj

    for left, right in [(1, 3), (1, 5), (3, 5)]:
        for traj_key, traj in by_candidate.items():
            if left in traj and right in traj:
                delta = float(traj[left]["candidate_answer_avg_logprob"]) - float(traj[right]["candidate_answer_avg_logprob"])
                pairwise_deltas[f"{left}_vs_{right}"].append(delta)
                pairwise_example_deltas[f"{left}_vs_{right}"][traj_key[0]].append(delta)

    rank_values = [float(row["candidate_position"]) for row in rows]
    avg_score_values = [float(row["candidate_answer_avg_logprob"]) for row in rows]
    total_score_values = [float(row["candidate_answer_logprob"]) for row in rows]
    token_count_values = [float(row["token_count"]) for row in rows]

    best_rank_counts = defaultdict(int)
    comparable_best_rank_counts = defaultdict(int)
    rank1_best = 0
    rank5_best = 0
    rank1_denominator = 0
    rank5_denominator = 0
    comparable_rank1_best = 0
    comparable_rank5_best = 0
    rank1_rank5_deltas = []
    rank5_beats_rank1 = 0
    rank5_vs_rank1_comparisons = 0
    for traj in by_candidate.values():
        available = {pos: row for pos, row in traj.items() if pos in positions}
        if not available:
            continue
        best_position = max(available.items(), key=lambda item: float(item[1]["candidate_answer_avg_logprob"]))[0]
        best_rank_counts[str(best_position)] += 1
        if 1 in available:
            rank1_denominator += 1
            if best_position == 1:
                rank1_best += 1
        if 5 in available:
            rank5_denominator += 1
            if best_position == 5:
                rank5_best += 1
        if 1 in available and 5 in available:
            left = float(available[1]["candidate_answer_avg_logprob"])
            right = float(available[5]["candidate_answer_avg_logprob"])
            rank1_rank5_deltas.append(left - right)
            rank5_vs_rank1_comparisons += 1
            if right > left:
                rank5_beats_rank1 += 1

    comparable_mean_by_rank = {}
    for pos in positions:
        vals = [
            float(traj[pos]["candidate_answer_avg_logprob"])
            for traj in comparable_all_positions.values()
            if pos in traj
        ]
        comparable_mean_by_rank[str(pos)] = mean(vals)

    for traj in comparable_all_positions.values():
        best_position = max(traj.items(), key=lambda item: float(item[1]["candidate_answer_avg_logprob"]))[0]
        comparable_best_rank_counts[str(best_position)] += 1
        if best_position == 1:
            comparable_rank1_best += 1
        if best_position == 5:
            comparable_rank5_best += 1

    bootstrap_rank1_vs_rank5 = bootstrap_example_level_ci(
        pairwise_example_deltas["1_vs_5"],
        seed=seed + len(rows),
        samples=bootstrap_samples,
    )
    null_baseline = build_null_rank_effect(by_candidate, positions, seed=seed + 10_000 + len(rows))

    summary = {
        "num_examples": len(seen_examples),
        "num_scored_rows": len(rows),
        "mean_logprob_by_rank": {
            str(pos): mean(by_position_avg[pos])
            for pos in positions
        },
        "mean_total_logprob_by_rank": {
            str(pos): mean(by_position_total[pos])
            for pos in positions
        },
        "mean_token_count_by_rank": {
            str(pos): mean([float(v) for v in by_position_token_count[pos]])
            for pos in positions
        },
        "same_candidate_logprob_delta": {
            key: {
                "comparisons": len(values),
                "mean_delta": mean(values),
            }
            for key, values in pairwise_deltas.items()
        },
        "same_candidate_rank1_vs_rank3_mean_delta": mean(pairwise_deltas["1_vs_3"]),
        "same_candidate_rank1_vs_rank5_mean_delta": mean(pairwise_deltas["1_vs_5"]),
        "same_candidate_rank3_vs_rank5_mean_delta": mean(pairwise_deltas["3_vs_5"]),
        "same_candidate_rank5_beats_rank1_rate": (
            rank5_beats_rank1 / rank5_vs_rank1_comparisons if rank5_vs_rank1_comparisons else None
        ),
        "same_candidate_rank1_vs_rank5_bootstrap_ci": bootstrap_rank1_vs_rank5,
        "rank_1_best_rate": rank1_best / rank1_denominator if rank1_denominator else None,
        "rank_5_best_rate": rank5_best / rank5_denominator if rank5_denominator else None,
        "rank_1_minus_rank_5_mean_delta": mean(rank1_rank5_deltas),
        "rank_logprob_correlation": spearman_r(rank_values, avg_score_values),
        "correlation_token_count_avg_logprob": spearman_r(token_count_values, avg_score_values),
        "correlation_token_count_total_logprob": spearman_r(token_count_values, total_score_values),
        "best_scoring_rank_counts": dict(sorted(best_rank_counts.items(), key=lambda item: int(item[0]))),
        "pairwise_deltas": {
            key: {
                "comparisons": len(values),
                "mean_delta": mean(values),
            }
            for key, values in pairwise_deltas.items()
        },
        "candidate_centered_avg_logprob_by_rank": {
            str(pos): mean(candidate_centered_avg_by_rank[pos])
            for pos in positions
        },
        "candidate_centered_total_logprob_by_rank": {
            str(pos): mean(candidate_centered_total_by_rank[pos])
            for pos in positions
        },
        "comparable_all_positions_count": len(comparable_all_positions),
        "comparable_mean_logprob_by_rank": comparable_mean_by_rank,
        "comparable_best_scoring_rank_counts": dict(sorted(comparable_best_rank_counts.items(), key=lambda item: int(item[0]))),
        "comparable_rank_1_best_rate": (
            comparable_rank1_best / len(comparable_all_positions) if comparable_all_positions else None
        ),
        "comparable_rank_5_best_rate": (
            comparable_rank5_best / len(comparable_all_positions) if comparable_all_positions else None
        ),
        "rank_effect_using_avg_logprob": mean(pairwise_deltas["1_vs_5"]),
        "rank_effect_using_total_logprob": (
            mean([
                float(traj[1]["candidate_answer_logprob"]) - float(traj[5]["candidate_answer_logprob"])
                for traj in by_candidate.values()
                if 1 in traj and 5 in traj
            ])
        ),
        "randomized_rank_label_null": null_baseline,
        "notes": [
            "Scores are computed with the Hugging Face model specified by model_id.",
            "Gemma 4 is the intended analysis backend; smoke tests may use a smaller model.",
            "This is not the LiteRT runtime used in deployment.",
            "Primary claim should rely on paired same-candidate deltas across positions.",
        ],
    }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Per-row JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--positions", default="1,3,5", help="Comma-separated target positions to score")
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples to score")
    parser.add_argument("--max-examples", type=int, default=0, help="Alternative limit for convenience")
    parser.add_argument("--seed", type=int, default=7, help="Random seed")
    parser.add_argument("--bootstrap-samples", type=int, default=DEFAULT_BOOTSTRAP_SAMPLES, help="Example-level bootstrap samples")
    parser.add_argument(
        "--completion-prefix",
        default="space",
        choices=["none", "space", "newline"],
        help="Prefix to prepend before the scored completion text",
    )
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID, help="Hugging Face model id")
    parser.add_argument("--device", default="auto", help="torch device to use")
    parser.add_argument("--dtype", default="auto", help="torch dtype to use")
    parser.add_argument("--resume", action="store_true", help="Resume from an existing JSONL output file")
    args = parser.parse_args()

    set_seed(args.seed)
    examples = load_jsonl(Path(args.examples))
    limit = args.max_examples or args.limit
    if limit:
        examples = examples[: limit]
    positions = parse_positions(args.positions)

    output_path = Path(args.output)
    summary_path = Path(args.summary_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    existing_keys = load_existing_keys(output_path) if args.resume else set()
    rows: list[dict] = []
    skipped = 0

    bundle = load_hf_bundle(args.model_id, device=args.device, dtype=args.dtype)
    try:
        import transformers

        transformers_version = transformers.__version__
    except Exception:
        transformers_version = "unknown"

    total_examples = len(examples)
    for index, example in enumerate(examples, 1):
        example_id = str(example.get("example_id") or "")
        candidates = [strip_confidence(c) for c in (example.get("original_candidates") or [])]
        if not example_id or not candidates:
            continue
        target_positions = [pos for pos in positions if pos <= len(candidates)]
        if not target_positions:
            continue
        print(f"[{index}/{total_examples}] {example_id} ({len(candidates)} candidates)", flush=True)

        for source_rank, candidate in enumerate(candidates, 1):
            completion = apply_completion_prefix(
                candidate_completion_text(candidate, "scientific_name_only", source_rank),
                args.completion_prefix,
            )
            candidate_name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
            for target_position in target_positions:
                key = (example_id, f"{source_rank}:{candidate_name}", source_rank, target_position)
                if key in existing_keys:
                    skipped += 1
                    continue
                candidate_order = move_candidate(candidates, source_rank, target_position)
                prompt = build_prompt(candidate_order, DEFAULT_PROMPT_VARIANT)
                prompt_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()[:16]
                score_info = score_completion(bundle, prompt, completion)
                rows.append(
                    {
                        "example_id": example_id,
                        "image_path": example.get("image_path"),
                        "image_id": example.get("image_id"),
                        "ground_truth_species": example.get("ground_truth_species"),
                        "ground_truth_common_name": example.get("ground_truth_common_name"),
                        "ground_truth_genus": example.get("ground_truth_genus"),
                        "source_rank": source_rank,
                        "candidate_position": target_position,
                        "candidate_count": len(candidates),
                        "candidate_name": candidate_name,
                        "prompt_variant": DEFAULT_PROMPT_VARIANT,
                        "completion_text": completion,
                        "full_prompt": prompt,
                        "prompt_hash": prompt_hash,
                        "scoring_mode": "completion_only_logprob",
                        "completion_prefix": args.completion_prefix,
                        "model_id": args.model_id,
                        "model_dtype": str(bundle.dtype),
                        "device": bundle.device,
                        "transformers_version": transformers_version,
                        "torch_version": torch.__version__,
                        "seed": args.seed,
                        **score_info,
                    }
                )

    if rows:
        if args.resume and output_path.exists():
            with output_path.open("a", encoding="utf-8") as fh:
                for row in rows:
                    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        else:
            write_jsonl(output_path, rows)

    combined_rows = load_jsonl(output_path) if output_path.exists() else rows
    summary = summarise(combined_rows, positions, seed=args.seed, bootstrap_samples=args.bootstrap_samples)
    summary.update(
        {
            "num_written_rows": len(rows),
            "num_skipped_rows": skipped,
            "bootstrap_samples": args.bootstrap_samples,
            "scoring_mode": "completion_only_logprob",
            "completion_prefix": args.completion_prefix,
            "model_dtype": str(bundle.dtype),
            "device": bundle.device,
            "transformers_version": transformers_version,
            "torch_version": torch.__version__,
            "output": str(output_path),
            "summary_output": str(summary_path),
        }
    )
    safe_write_json(summary_path, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
