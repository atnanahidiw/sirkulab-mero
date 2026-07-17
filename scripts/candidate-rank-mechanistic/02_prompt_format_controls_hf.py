#!/usr/bin/env python3
"""Test prompt-format controls with Hugging Face Gemma 4 logits."""
from __future__ import annotations

import argparse
import gc
import json
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
    locate_answer_position_span,
    locate_candidate_name_spans,
    move_candidate,
    prompt_variant_name,
    safe_write_json,
    score_completions,
    set_seed,
    spearman_r,
    strip_confidence,
)

DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "prompt_format_controls.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "prompt_format_controls_summary.json"
DEFAULT_POSITIONS = (1, 3, 5)


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


def parse_csv_names(value: str) -> list[str]:
    return [part.strip() for part in value.split(",") if part.strip()]


def parse_source_ranks(value: str) -> set[int] | None:
    if not value.strip():
        return None
    ranks = {int(part.strip()) for part in value.split(",") if part.strip()}
    if not ranks:
        return None
    return ranks


def clamp_example_bounds(total_examples: int, start_example: int, end_example: int) -> tuple[int, int]:
    if start_example < 1:
        raise ExperimentError("--start-example must be at least 1")
    if end_example and end_example < start_example:
        raise ExperimentError("--end-example must be >= --start-example")
    start_index = min(start_example - 1, total_examples)
    end_index = total_examples if end_example <= 0 else min(end_example, total_examples)
    return start_index, end_index


def append_jsonl(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    with path.open("a", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def scoring_group(answer_format: str) -> str:
    if answer_format == "candidate_number_only":
        return "answer_number_scoring"
    return "candidate_name_scoring"


def distance_bucket(distance: int | None) -> str | None:
    if distance is None:
        return None
    if distance <= 16:
        return "0-16"
    if distance <= 32:
        return "17-32"
    if distance <= 64:
        return "33-64"
    return "65+"


def select_prompt_variants(names: list[str]) -> list:
    if not names:
        return list(PROMPT_VARIANTS)
    by_name = {variant.name: variant for variant in PROMPT_VARIANTS}
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise ExperimentError(
            "Unknown prompt variant(s): "
            + ", ".join(unknown)
            + "\nAvailable variants: "
            + ", ".join(sorted(by_name))
        )
    return [by_name[name] for name in names]


def load_existing_keys(path: Path) -> set[tuple[str, str, str, int, int]]:
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
                    str(row.get("prompt_variant")),
                    str(row.get("answer_format")),
                    int(row.get("source_rank", 0)),
                    int(row.get("candidate_position", 0)),
                )
            )
    return keys


def summarise(rows: list[dict], positions: list[int]) -> dict:
    by_variant = defaultdict(lambda: defaultdict(list))
    by_variant_candidate = defaultdict(dict)
    scoring_group_by_variant: dict[str, str] = {}
    distance_by_variant = defaultdict(list)
    distance_score_by_variant = defaultdict(list)
    distance_bucket_by_variant = defaultdict(lambda: defaultdict(list))

    for row in rows:
        variant = str(row["prompt_variant"])
        pos = int(row["candidate_position"])
        example_id = str(row["example_id"])
        candidate_name = str(row["candidate_name"])
        source_rank = int(row["source_rank"])
        score = float(row["candidate_answer_avg_logprob"])
        by_variant[variant][pos].append(score)
        by_variant_candidate[(variant, example_id, source_rank, candidate_name)][pos] = row
        scoring_group_by_variant[variant] = str(row["scoring_group"])
        distance = row.get("distance_to_answer_tokens")
        if distance is not None:
            distance = int(distance)
            distance_by_variant[variant].append(float(distance))
            distance_score_by_variant[variant].append(score)
            bucket = distance_bucket(distance)
            if bucket is not None:
                distance_bucket_by_variant[variant][bucket].append(score)

    mean_logprob_by_rank_per_variant = {}
    pooled_rank_1_minus_rank_5_delta_by_variant = {}
    same_candidate_rank_1_minus_rank_5_delta_by_variant = {}
    rank_logprob_correlation_by_variant = {}
    best_scoring_rank_by_variant = {}
    distance_to_answer_correlation_by_variant = {}
    mean_logprob_by_distance_bucket_per_variant = {}
    comparable_summary_by_variant = {}

    for variant, rank_map in by_variant.items():
        mean_logprob_by_rank_per_variant[variant] = {
            str(pos): mean(rank_map[pos])
            for pos in positions
        }
        rank_values = []
        score_values = []
        for row in rows:
            if str(row["prompt_variant"]) != variant:
                continue
            rank_values.append(float(row["candidate_position"]))
            score_values.append(float(row["candidate_answer_avg_logprob"]))
        rank_logprob_correlation_by_variant[variant] = spearman_r(rank_values, score_values)
        distance_to_answer_correlation_by_variant[variant] = spearman_r(distance_by_variant[variant], distance_score_by_variant[variant])
        mean_logprob_by_distance_bucket_per_variant[variant] = {
            bucket: mean(values)
            for bucket, values in sorted(
                distance_bucket_by_variant[variant].items(),
                key=lambda item: item[0],
            )
        }

        deltas = []
        best_counts = defaultdict(int)
        comparable_best_counts = defaultdict(int)
        comparable_rank1_best = 0
        comparable_rank5_best = 0
        comparable_mean_by_rank = {}
        comparable_rows = []
        for traj_key, traj in by_variant_candidate.items():
            if traj_key[0] != variant:
                continue
            available = {pos: row for pos, row in traj.items() if pos in positions}
            if 1 in available and 5 in available:
                deltas.append(
                    float(available[1]["candidate_answer_avg_logprob"]) - float(available[5]["candidate_answer_avg_logprob"])
                )
            if available:
                best_position = max(available.items(), key=lambda item: float(item[1]["candidate_answer_avg_logprob"]))[0]
                best_counts[str(best_position)] += 1
            if all(pos in available for pos in positions):
                comparable_rows.append(available)
                comparable_best_position = max(
                    available.items(),
                    key=lambda item: float(item[1]["candidate_answer_avg_logprob"]),
                )[0]
                comparable_best_counts[str(comparable_best_position)] += 1
                if comparable_best_position == 1:
                    comparable_rank1_best += 1
                if comparable_best_position == 5:
                    comparable_rank5_best += 1
        pooled_rank_1_minus_rank_5_delta_by_variant[variant] = sum(deltas) / len(deltas) if deltas else None
        same_candidate_rank_1_minus_rank_5_delta_by_variant[variant] = sum(deltas) / len(deltas) if deltas else None
        best_scoring_rank_by_variant[variant] = dict(sorted(best_counts.items(), key=lambda item: int(item[0])))
        for pos in positions:
            comparable_mean_by_rank[str(pos)] = mean(
                [float(traj[pos]["candidate_answer_avg_logprob"]) for traj in comparable_rows if pos in traj]
            )
        comparable_summary_by_variant[variant] = {
            "num_comparable_trajectories": len(comparable_rows),
            "mean_logprob_by_rank": comparable_mean_by_rank,
            "rank_1_minus_rank_5_delta": (
                mean(
                    [
                        float(traj[1]["candidate_answer_avg_logprob"]) - float(traj[5]["candidate_answer_avg_logprob"])
                        for traj in comparable_rows
                    ]
                )
                if comparable_rows
                else None
            ),
            "best_scoring_rank_counts": dict(sorted(comparable_best_counts.items(), key=lambda item: int(item[0]))),
            "rank_1_best_rate": comparable_rank1_best / len(comparable_rows) if comparable_rows else None,
            "rank_5_best_rate": comparable_rank5_best / len(comparable_rows) if comparable_rows else None,
        }

    list_style_variants = [
        "numbered_list",
        "lettered_list",
        "bulleted_list",
        "json_list",
        "semicolon_list",
    ]
    answer_format_variants = [
        "answer_scientific_name_only",
        "answer_candidate_number_only",
        "answer_json_only",
    ]

    def std(values: list[float | None]) -> float | None:
        clean = [v for v in values if v is not None]
        if len(clean) < 2:
            return None
        mean = sum(clean) / len(clean)
        return (sum((v - mean) ** 2 for v in clean) / len(clean)) ** 0.5

    format_sensitivity_score = std([same_candidate_rank_1_minus_rank_5_delta_by_variant.get(name) for name in list_style_variants])
    answer_format_sensitivity_score = std([same_candidate_rank_1_minus_rank_5_delta_by_variant.get(name) for name in answer_format_variants])

    strongest = None
    weakest = None
    for variant, delta in same_candidate_rank_1_minus_rank_5_delta_by_variant.items():
        if delta is None:
            continue
        magnitude = abs(delta)
        if strongest is None or magnitude > strongest[1]:
            strongest = (variant, magnitude)
        if weakest is None or magnitude < weakest[1]:
            weakest = (variant, magnitude)

    summary = {
        "num_examples": len({row["example_id"] for row in rows}),
        "num_scored_rows": len(rows),
        "prompt_variants": sorted(mean_logprob_by_rank_per_variant.keys()),
        "scoring_group_by_variant": scoring_group_by_variant,
        "candidate_name_scoring_variants": sorted(
            [name for name, group in scoring_group_by_variant.items() if group == "candidate_name_scoring"]
        ),
        "answer_number_scoring_variants": sorted(
            [name for name, group in scoring_group_by_variant.items() if group == "answer_number_scoring"]
        ),
        "mean_logprob_by_rank_per_variant": mean_logprob_by_rank_per_variant,
        "pooled_rank_1_minus_rank_5_delta_by_variant": pooled_rank_1_minus_rank_5_delta_by_variant,
        "same_candidate_rank_1_minus_rank_5_delta_by_variant": same_candidate_rank_1_minus_rank_5_delta_by_variant,
        "rank_logprob_correlation_by_variant": rank_logprob_correlation_by_variant,
        "best_scoring_rank_by_variant": best_scoring_rank_by_variant,
        "distance_to_answer_correlation_by_variant": distance_to_answer_correlation_by_variant,
        "mean_logprob_by_distance_bucket_per_variant": mean_logprob_by_distance_bucket_per_variant,
        "comparable_summary_by_variant": comparable_summary_by_variant,
        "strongest_rank_bias_variant": strongest[0] if strongest else None,
        "weakest_rank_bias_variant": weakest[0] if weakest else None,
        "format_sensitivity_score": format_sensitivity_score,
        "answer_format_sensitivity_score": answer_format_sensitivity_score,
        "notes": [
            "List-format controls test whether rank effects survive after removing visible marker cues.",
            "Answer-format controls are evaluated with the numbered list baseline to isolate answer wording effects.",
            "Answer-number scoring should be interpreted separately from candidate-name scoring.",
            "Distance-to-answer measurements help separate list position from recency-to-answer effects.",
        ],
    }
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Per-row JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--positions", default="1,3,5", help="Comma-separated target positions to score")
    parser.add_argument(
        "--prompt-variants",
        default="",
        help="Comma-separated prompt variants; default runs all variants",
    )
    parser.add_argument(
        "--source-ranks",
        default="",
        help="Comma-separated original candidate ranks to score; default scores every candidate",
    )
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples to score")
    parser.add_argument("--max-examples", type=int, default=0, help="Alternative limit for convenience")
    parser.add_argument("--start-example", type=int, default=1, help="1-based start example index after limit/max-examples")
    parser.add_argument("--end-example", type=int, default=0, help="1-based inclusive end example index; 0 means all remaining")
    parser.add_argument("--batch-size", type=int, default=1, help="Number of prompt/completion pairs to score per forward pass")
    parser.add_argument(
        "--write-full-prompt",
        action="store_true",
        help="Store full prompt text in output JSONL for debugging",
    )
    parser.add_argument("--seed", type=int, default=7, help="Random seed")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID, help="Hugging Face model id")
    parser.add_argument("--device", default="auto", help="torch device to use")
    parser.add_argument("--dtype", default="auto", help="torch dtype to use")
    parser.add_argument("--resume", action="store_true", help="Resume from an existing JSONL output file")
    args = parser.parse_args()

    set_seed(args.seed)
    examples = load_jsonl(Path(args.examples))
    limit = args.max_examples or args.limit
    if limit:
        examples = examples[:limit]
    start_index, end_index = clamp_example_bounds(len(examples), args.start_example, args.end_example)
    examples = examples[start_index:end_index]
    positions = parse_positions(args.positions)
    prompt_variants = select_prompt_variants(parse_csv_names(args.prompt_variants))
    source_ranks = parse_source_ranks(args.source_ranks)
    if args.batch_size < 1:
        raise ExperimentError("--batch-size must be at least 1")

    output_path = Path(args.output)
    summary_path = Path(args.summary_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    existing_keys = load_existing_keys(output_path) if args.resume else set()
    skipped = 0
    written_rows = 0

    bundle = load_hf_bundle(args.model_id, device=args.device, dtype=args.dtype)

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

        for variant in prompt_variants:
            pending_rows: list[dict] = []
            pending_pairs: list[tuple[str, str]] = []
            for source_rank, candidate in enumerate(candidates, 1):
                if source_ranks is not None and source_rank not in source_ranks:
                    continue
                candidate_name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
                for target_position in target_positions:
                    key = (example_id, variant.name, variant.answer_format, source_rank, target_position)
                    if key in existing_keys:
                        skipped += 1
                        continue
                    candidate_order = move_candidate(candidates, source_rank, target_position)
                    prompt = build_prompt_variant_prompt(candidate_order, variant)
                    completion = candidate_completion_text(candidate, variant.answer_format, target_position)
                    candidate_spans = locate_candidate_name_spans(bundle.tokenizer, prompt, candidate_order)
                    target_display_name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
                    candidate_span = candidate_spans.get(target_display_name)
                    answer_span = locate_answer_position_span(bundle.tokenizer, prompt)
                    candidate_token_start = candidate_span[0] if candidate_span is not None else None
                    candidate_token_end = candidate_span[1] if candidate_span is not None else None
                    answer_token_start = answer_span[0] if answer_span is not None else None
                    distance_to_answer_tokens = None
                    if candidate_token_end is not None and answer_token_start is not None:
                        distance_to_answer_tokens = answer_token_start - candidate_token_end
                    pending_pairs.append((prompt, completion))
                    pending_rows.append(
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
                            "prompt_variant": prompt_variant_name(variant),
                            "answer_format": variant.answer_format,
                            "scoring_group": scoring_group(variant.answer_format),
                            "completion_text": completion,
                            "prompt_char_length": len(prompt),
                            "candidate_token_start": candidate_token_start,
                            "candidate_token_end": candidate_token_end,
                            "answer_token_start": answer_token_start,
                            "distance_to_answer_tokens": distance_to_answer_tokens,
                            "model_id": args.model_id,
                            "seed": args.seed,
                        }
                    )
                    if args.write_full_prompt:
                        pending_rows[-1]["full_prompt"] = prompt
                    if len(pending_pairs) >= args.batch_size:
                        score_infos = score_completions(bundle, pending_pairs)
                        batch_rows = [{**row, **score_info} for row, score_info in zip(pending_rows, score_infos)]
                        append_jsonl(output_path, batch_rows)
                        written_rows += len(batch_rows)
                        existing_keys.update(
                            (
                                str(row.get("example_id")),
                                str(row.get("prompt_variant")),
                                str(row.get("answer_format")),
                                int(row.get("source_rank", 0)),
                                int(row.get("candidate_position", 0)),
                            )
                            for row in batch_rows
                        )
                        pending_pairs = []
                        pending_rows = []
                        del score_infos
                        del batch_rows
                        gc.collect()
                        if torch.backends.mps.is_available():
                            torch.mps.empty_cache()
            if pending_pairs:
                score_infos = score_completions(bundle, pending_pairs)
                batch_rows = [{**row, **score_info} for row, score_info in zip(pending_rows, score_infos)]
                append_jsonl(output_path, batch_rows)
                written_rows += len(batch_rows)
                existing_keys.update(
                    (
                        str(row.get("example_id")),
                        str(row.get("prompt_variant")),
                        str(row.get("answer_format")),
                        int(row.get("source_rank", 0)),
                        int(row.get("candidate_position", 0)),
                    )
                    for row in batch_rows
                )
                del score_infos
                del batch_rows
                gc.collect()
                if torch.backends.mps.is_available():
                    torch.mps.empty_cache()

    combined_rows = load_jsonl(output_path) if output_path.exists() else []
    summary = summarise(combined_rows, positions)
    summary.update(
        {
            "num_written_rows": written_rows,
            "num_skipped_rows": skipped,
            "selected_prompt_variants": [variant.name for variant in prompt_variants],
            "selected_source_ranks": sorted(source_ranks) if source_ranks is not None else "all",
            "selected_positions": positions,
            "start_example": args.start_example,
            "end_example": args.end_example if args.end_example > 0 else None,
            "batch_size": args.batch_size,
            "write_full_prompt": args.write_full_prompt,
            "output": str(output_path),
            "summary_output": str(summary_path),
        }
    )
    safe_write_json(summary_path, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
