#!/usr/bin/env python3
"""Analyze LiteRT candidate likelihood by candidate position.

This is the Layer 2A token-score analysis for the candidate-rank-sensitivity
track. It uses LiteRT-LM's public text-scoring surface:

  - prefill a text prompt that lists the candidates in a particular order
  - score each candidate name as the completion with run_text_scoring(...)
  - compare the same candidate when it appears in rank 1, rank 3, or rank 5

Important limitation:
  LiteRT-LM's public scoring API is text-only. This script measures prompt-
  conditioned candidate likelihood, not image-conditioned likelihood. That
  still makes it a true token-score analysis, but it is not a full multimodal
  mechanistic probe.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

from _common import (
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    candidate_common_name,
    candidate_scientific_name,
    format_candidates_for_prompt,
    load_jsonl,
    strip_confidence,
    write_jsonl,
)

DEFAULT_EXAMPLES = DEFAULT_OUTPUT_DIR / "confidence_score_examples.jsonl"
DEFAULT_RESULTS = DEFAULT_OUTPUT_DIR / "litert_candidate_likelihood_results.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "litert_candidate_likelihood_summary.json"
DEFAULT_MODEL_PATH = str(Path.home() / "Downloads" / "gemma-4-E2B-it.litertlm")
DEFAULT_DATA_REPO = str(Path(__file__).resolve().parents[2].parent / "sirkulab-mero-data")
DEFAULT_POSITIONS = (1, 3, 5)

PROMPT_TEMPLATE = """You are evaluating candidate likelihood in species identification.

Task:
- Read the candidate list carefully.
- Choose the single best species.
- Use the candidate list as written; do not invent species outside the list.
- Return the species name only.

Candidates:
{candidates}

Answer:
"""


def load_runtime(model_path: str, backend_name: str = "cpu", enable_speculative_decoding: bool = False):
    try:
        from litert_lm import Backend, Engine
        from litert_lm.interfaces import SamplerConfig
    except Exception as exc:  # pragma: no cover - environment dependent
        raise ExperimentError(
            "The LiteRT-LM runtime is not available in this environment.\n"
            "Run this script inside the sirkulab-mero-data venv that has litert_lm installed."
        ) from exc

    backend_name = backend_name.lower().strip()
    if backend_name == "gpu":
        backend = Backend.GPU()
    elif backend_name == "npu":
        backend = Backend.NPU()
    else:
        backend = Backend.CPU()

    engine = Engine(
        model_path,
        backend=backend,
        vision_backend=backend,
        enable_speculative_decoding=enable_speculative_decoding,
    )
    sampler = SamplerConfig(temperature=0.0, top_k=1, top_p=1.0, seed=31415926)
    return engine, sampler


def candidate_label(candidate: dict) -> str:
    scientific = candidate_scientific_name(candidate)
    common = candidate_common_name(candidate)
    if scientific and common and scientific != common:
        return f"{common} [{scientific}]"
    return common or scientific or "Unknown"


def prompt_with_candidates(candidates: list[dict]) -> str:
    return PROMPT_TEMPLATE.format(candidates=format_candidates_for_prompt(candidates))


def move_candidate(candidates: list[dict], source_rank: int, target_position: int) -> list[dict]:
    if source_rank < 1 or source_rank > len(candidates):
        raise ExperimentError(f"source_rank {source_rank} is out of range for {len(candidates)} candidates")
    if target_position < 1 or target_position > len(candidates):
        raise ExperimentError(f"target_position {target_position} is out of range for {len(candidates)} candidates")

    copied = [dict(c) for c in candidates]
    picked = copied.pop(source_rank - 1)
    copied.insert(target_position - 1, picked)
    return copied


def completion_text(candidate: dict) -> str:
    text = candidate_scientific_name(candidate) or candidate_common_name(candidate)
    if not text:
        raise ExperimentError("Candidate is missing both scientific and common names")
    return text


def score_completion(session, prompt: str, target_text: str) -> dict:
    session.run_prefill([prompt])
    scored = session.run_text_scoring([target_text], store_token_lengths=True)
    token_scores = scored.token_scores[0] if scored.token_scores else []
    total_score = scored.scores[0] if scored.scores else sum(token_scores)
    token_count = scored.token_lengths[0] if scored.token_lengths else len(token_scores)
    mean_score = total_score / token_count if token_count else total_score
    return {
        "total_score": float(total_score),
        "mean_token_score": float(mean_score),
        "token_count": int(token_count),
        "token_scores": [float(x) for x in token_scores],
    }


def load_existing_keys(path: Path) -> set[tuple[str, int, int]]:
    if not path.exists():
        return set()
    keys: set[tuple[str, int, int]] = set()
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            keys.add(
                (
                    str(row.get("example_id")),
                    int(row.get("source_rank", 0)),
                    int(row.get("target_position", 0)),
                )
            )
    return keys


def aggregate_summary(rows: list[dict], positions: list[int]) -> dict:
    if not rows:
        return {
            "examples": 0,
            "rows": 0,
            "positions": positions,
        }

    by_position_total: dict[int, list[float]] = defaultdict(list)
    by_position_mean: dict[int, list[float]] = defaultdict(list)
    by_candidate: dict[tuple[str, int], dict[int, float]] = defaultdict(dict)
    by_example: dict[str, dict[int, list[float]]] = defaultdict(lambda: defaultdict(list))

    for row in rows:
        pos = int(row["target_position"])
        source_rank = int(row["source_rank"])
        example_id = str(row["example_id"])
        mean_score = float(row["mean_token_score"])
        total_score = float(row["total_score"])

        by_position_total[pos].append(total_score)
        by_position_mean[pos].append(mean_score)
        by_candidate[(example_id, source_rank)][pos] = mean_score
        by_example[example_id][pos].append(mean_score)

    def mean(values: list[float]) -> float | None:
        return sum(values) / len(values) if values else None

    def pairwise_rate(left: int, right: int) -> dict[str, float | int | None]:
        wins = 0
        total = 0
        deltas = []
        for trajectory in by_candidate.values():
            if left in trajectory and right in trajectory:
                total += 1
                delta = trajectory[left] - trajectory[right]
                deltas.append(delta)
                if delta > 0:
                    wins += 1
        return {
            "left": left,
            "right": right,
            "comparisons": total,
            "win_rate": wins / total if total else None,
            "mean_delta": mean(deltas),
        }

    rank1_best = 0
    rank1_comparable = 0
    for trajectory in by_candidate.values():
        available = {pos: score for pos, score in trajectory.items() if pos in positions}
        if 1 in available and len(available) >= 2:
            rank1_comparable += 1
            best_pos = max(available.items(), key=lambda kv: kv[1])[0]
            if best_pos == 1:
                rank1_best += 1

    example_rank1_best = 0
    example_comparable = 0
    for trajectory in by_example.values():
        available = {pos: mean(scores) for pos, scores in trajectory.items() if pos in positions}
        if 1 in available and len(available) >= 2:
            example_comparable += 1
            best_pos = max(available.items(), key=lambda kv: kv[1])[0]
            if best_pos == 1:
                example_rank1_best += 1

    position_stats = {}
    for pos in positions:
        position_stats[str(pos)] = {
            "mean_total_score": mean(by_position_total.get(pos, [])),
            "mean_token_score": mean(by_position_mean.get(pos, [])),
            "rows": len(by_position_mean.get(pos, [])),
        }

    pairwise_1_vs_3 = pairwise_rate(1, 3) if 3 in positions else {}
    pairwise_1_vs_5 = pairwise_rate(1, 5) if 5 in positions else {}

    summary = {
        "examples": len(by_example),
        "rows": len(rows),
        "positions": positions,
        "position_stats": position_stats,
        "rank1_best_candidate_rate": rank1_best / rank1_comparable if rank1_comparable else None,
        "rank1_best_example_rate": example_rank1_best / example_comparable if example_comparable else None,
        "rank1_vs_rank3": pairwise_1_vs_3,
        "rank1_vs_rank5": pairwise_1_vs_5,
        "most_rank1_positive_examples": [],
    }

    per_example_delta = []
    for example_id, trajectory in by_example.items():
        available = {pos: mean(scores) for pos, scores in trajectory.items() if pos in positions}
        if 1 in available:
            best_pos = max(available.items(), key=lambda kv: kv[1])[0]
            if 3 in available:
                per_example_delta.append((available[1] - available[3], example_id, available))
            elif 5 in available:
                per_example_delta.append((available[1] - available[5], example_id, available))
            if best_pos == 1:
                pass

    per_example_delta.sort(reverse=True, key=lambda item: item[0])
    summary["most_rank1_positive_examples"] = [
        {
            "example_id": example_id,
            "rank1_minus_comparator": delta,
            "position_scores": {str(k): v for k, v in sorted(available.items())},
        }
        for delta, example_id, available in per_example_delta[:10]
    ]

    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_RESULTS), help="Per-row JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--positions", default="1,3,5", help="Comma-separated target positions to score")
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples to score")
    parser.add_argument("--model-path", default=DEFAULT_MODEL_PATH, help="Path to the Gemma 4 LiteRT-LM bundle")
    parser.add_argument("--data-repo", default=DEFAULT_DATA_REPO, help="Kept for CLI symmetry; not used by the text-only scorer")
    parser.add_argument("--backend", default="cpu", choices=["cpu", "gpu", "npu"], help="LiteRT backend to use")
    parser.add_argument(
        "--enable-speculative-decoding",
        action="store_true",
        help="Enable speculative decoding when the model bundle supports it",
    )
    parser.add_argument("--resume", action="store_true", help="Resume from an existing JSONL output file")
    args = parser.parse_args()

    examples_path = Path(args.examples)
    if not examples_path.exists():
        raise ExperimentError(f"Examples JSONL not found: {examples_path}")

    examples = load_jsonl(examples_path)
    if not examples:
        raise ExperimentError(f"No examples found in {examples_path}")
    if args.limit:
        examples = examples[: args.limit]

    positions = [int(x.strip()) for x in args.positions.split(",") if x.strip()]
    if not positions:
        raise ExperimentError("At least one target position must be provided")
    positions = sorted(set(positions))

    output_path = Path(args.output)
    summary_path = Path(args.summary_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    existing_keys = load_existing_keys(output_path) if args.resume else set()
    rows = []
    skipped = 0

    engine, sampler = load_runtime(
        args.model_path,
        args.backend,
        enable_speculative_decoding=args.enable_speculative_decoding,
    )

    total_examples = len(examples)
    for index, example in enumerate(examples, 1):
        example_id = str(example.get("example_id") or "")
        if not example_id:
            raise ExperimentError(f"Example at index {index} is missing example_id")

        original_candidates = [strip_confidence(c) for c in (example.get("original_candidates") or [])]
        if not original_candidates:
            raise ExperimentError(f"Example {example_id} has no original_candidates")

        candidate_count = len(original_candidates)
        target_positions = [pos for pos in positions if pos <= candidate_count]
        if not target_positions:
            continue

        print(f"[{index}/{total_examples}] {example_id} ({candidate_count} candidates)", flush=True)

        for source_rank, candidate in enumerate(original_candidates, 1):
            completion = completion_text(candidate)
            candidate_common = candidate_common_name(candidate)
            candidate_scientific = candidate_scientific_name(candidate)
            for target_position in target_positions:
                key = (example_id, source_rank, target_position)
                if key in existing_keys:
                    skipped += 1
                    continue

                ordered_candidates = move_candidate(original_candidates, source_rank, target_position)
                prompt = prompt_with_candidates(ordered_candidates)
                with engine.create_session(apply_prompt_template=False, sampler_config=sampler) as session:
                    score_info = score_completion(session, prompt, completion)

                row = {
                    "example_id": example_id,
                    "image_path": example.get("image_path"),
                    "source_rank": source_rank,
                    "target_position": target_position,
                    "candidate_count": candidate_count,
                    "candidate_common_name": candidate_common,
                    "candidate_scientific_name": candidate_scientific,
                    "completion_text": completion,
                    "prompt_order": [candidate_scientific_name(c) for c in ordered_candidates],
                    **score_info,
                }
                rows.append(row)

    if rows:
        if args.resume and output_path.exists():
            with output_path.open("a", encoding="utf-8") as fh:
                for row in rows:
                    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        else:
            write_jsonl(output_path, rows)

    combined_rows = load_jsonl(output_path) if output_path.exists() else rows
    summary = aggregate_summary(combined_rows, positions)
    summary.update(
        {
            "examples_requested": len(examples),
            "target_positions": positions,
            "written_rows": len(rows),
            "skipped_rows": skipped,
            "output": str(output_path),
        }
    )
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))

    print(json.dumps({
        "examples": summary["examples"],
        "rows": summary["rows"],
        "rank1_best_candidate_rate": summary["rank1_best_candidate_rate"],
        "rank1_vs_rank3": summary["rank1_vs_rank3"],
        "rank1_vs_rank5": summary["rank1_vs_rank5"],
        "output": str(output_path),
        "summary": str(summary_path),
    }, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
