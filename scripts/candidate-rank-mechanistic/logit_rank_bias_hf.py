#!/usr/bin/env python3
"""Score candidate-likelihood rank bias with Hugging Face Gemma 4.

This is the first text-only mechanistic pass for the candidate-rank-sensitivity
project. It uses the Hugging Face Gemma 4 safetensors model to score the same
candidate string when that candidate is moved to different list positions.

The script intentionally avoids image inputs. The goal is to test whether rank
bias is already visible in the text decision layer before moving to hidden-state
analysis and interventions.
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path

from common_hf import (
    DEFAULT_EXAMPLES,
    DEFAULT_MODEL_ID,
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    candidate_common_name,
    candidate_scientific_name,
    candidate_completion,
    load_hf_bundle,
    load_jsonl,
    make_candidate_prompt,
    move_candidate,
    pearson_r,
    spearman_r,
    strip_confidence,
    write_jsonl,
    score_completion,
)

DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "01_logit_rank_bias_hf_results.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "01_logit_rank_bias_hf_summary.json"
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


def load_existing_keys(path: Path) -> set[tuple[str, int, int]]:
    if not path.exists():
        return set()
    keys = set()
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            keys.add((str(row.get("example_id")), int(row.get("source_rank", 0)), int(row.get("target_position", 0))))
    return keys


def summarise(rows: list[dict], positions: list[int]) -> dict:
    by_position = defaultdict(list)
    by_candidate = defaultdict(dict)
    example_trajectories = defaultdict(dict)

    for row in rows:
        pos = int(row["target_position"])
        example_id = str(row["example_id"])
        source_rank = int(row["source_rank"])
        score = float(row["mean_token_logprob"])
        by_position[pos].append(score)
        by_candidate[(example_id, source_rank)][pos] = score
        example_trajectories[example_id][pos] = score

    pairwise = {}
    for left, right in [(1, 3), (1, 5), (3, 5)]:
        if left not in positions or right not in positions:
            continue
        deltas = []
        wins = 0
        total = 0
        for traj in by_candidate.values():
            if left in traj and right in traj:
                total += 1
                delta = traj[left] - traj[right]
                deltas.append(delta)
                if delta > 0:
                    wins += 1
        pairwise[f"{left}_vs_{right}"] = {
            "comparisons": total,
            "win_rate": wins / total if total else None,
            "mean_delta": sum(deltas) / len(deltas) if deltas else None,
        }

    rank_values = []
    score_values = []
    for row in rows:
        rank_values.append(float(row["target_position"]))
        score_values.append(float(row["mean_token_logprob"]))

    rank1_best = 0
    rank1_comparable = 0
    for traj in by_candidate.values():
        available = {pos: score for pos, score in traj.items() if pos in positions}
        if 1 in available and len(available) >= 2:
            rank1_comparable += 1
            if max(available.items(), key=lambda item: item[1])[0] == 1:
                rank1_best += 1

    summary = {
        "examples": len(example_trajectories),
        "rows": len(rows),
        "positions": positions,
        "mean_score_by_position": {
            str(pos): (sum(by_position[pos]) / len(by_position[pos]) if by_position.get(pos) else None)
            for pos in positions
        },
        "rank_position_pearson_r": pearson_r(rank_values, score_values),
        "rank_position_spearman_r": spearman_r(rank_values, score_values),
        "rank1_best_candidate_rate": rank1_best / rank1_comparable if rank1_comparable else None,
        "pairwise": pairwise,
    }

    positive_examples = []
    for example_id, traj in example_trajectories.items():
        if 1 in traj and len(traj) >= 2:
            best_position = max(traj.items(), key=lambda item: item[1])[0]
            if best_position == 1:
                positive_examples.append(
                    {
                        "example_id": example_id,
                        "position_scores": {str(k): v for k, v in sorted(traj.items())},
                    }
                )
    summary["rank1_best_examples"] = positive_examples[:10]
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Per-row JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--positions", default="1,3,5", help="Comma-separated target positions to score")
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples to score")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID, help="Hugging Face Gemma 4 model id")
    parser.add_argument("--device-map", default="auto", help="Transformers device_map value")
    parser.add_argument("--resume", action="store_true", help="Resume from an existing JSONL output file")
    args = parser.parse_args()

    examples = load_jsonl(Path(args.examples))
    if args.limit:
        examples = examples[: args.limit]
    positions = parse_positions(args.positions)

    output_path = Path(args.output)
    summary_path = Path(args.summary_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    existing_keys = load_existing_keys(output_path) if args.resume else set()
    rows: list[dict] = []
    skipped = 0

    bundle = load_hf_bundle(args.model_id, device_map=args.device_map)

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
            completion = candidate_completion(candidate)
            for target_position in target_positions:
                key = (example_id, source_rank, target_position)
                if key in existing_keys:
                    skipped += 1
                    continue
                candidate_order = move_candidate(candidates, source_rank, target_position)
                prompt = make_candidate_prompt(candidate_order)
                score_info = score_completion(bundle, prompt, completion)
                rows.append(
                    {
                        "example_id": example_id,
                        "image_path": example.get("image_path"),
                        "source_rank": source_rank,
                        "target_position": target_position,
                        "candidate_count": len(candidates),
                        "candidate_common_name": candidate_common_name(candidate),
                        "candidate_scientific_name": candidate_scientific_name(candidate),
                        "completion_text": completion,
                        "prompt_order": [candidate_scientific_name(c) for c in candidate_order],
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
    summary = summarise(combined_rows, positions)
    summary.update(
        {
            "written_rows": len(rows),
            "skipped_rows": skipped,
            "output": str(output_path),
            "summary_output": str(summary_path),
        }
    )
    summary_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False))
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
