#!/usr/bin/env python3
"""Evaluate candidate-rank sensitivity with fixed images and shuffled candidates."""
from __future__ import annotations

import argparse
import json
import random
import re
import time
from pathlib import Path

from _common import (
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    candidate_common_name,
    candidate_scientific_name,
    format_candidates_for_prompt,
    load_jsonl,
    match_candidate_rank,
    parse_response_json,
    stable_int_seed,
    strip_confidence,
    write_jsonl,
)

DEFAULT_TRIALS = 5
DEFAULT_MODEL_PATH = str(Path.home() / "Downloads" / "gemma-4-E2B-it.litertlm")
DEFAULT_DATA_REPO = str(Path(__file__).resolve().parents[2].parent / "sirkulab-mero-data")

PROMPT_TEMPLATE = """You are evaluating candidate-rank sensitivity in species identification.

Task:
- Inspect the image carefully.
- Choose the single best species from the candidate list.
- Do not invent species outside the list.
- Ignore any confidence scores; they are intentionally removed from the prompt.
- Preserve the candidate order exactly as shown.
- Return JSON only with keys: scientific_name, common_name, selected_candidate_rank, short_reason.

Candidate order matters for this experiment.

Candidates:
{candidates}
"""


def normalize_species_name(text: object) -> str:
    return re.sub(r"[^a-z0-9 ]", " ", str(text or "").lower()).strip()


def load_runtime(model_path: str, backend_name: str = "cpu", enable_speculative_decoding: bool = False):
    try:
        from litert_lm import Backend, Engine
        from litert_lm.interfaces import SamplerConfig
    except Exception as exc:  # pragma: no cover - import failure is environment dependent
        raise ExperimentError(
            "The LiteRT-LM runtime is not available in this environment.\n"
            "Run this script inside the sirkulab-mero-data venv that has litert_lm installed,\n"
            "or use the build and summarize scripts independently."
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
    sampler = SamplerConfig(temperature=0.3, top_k=64, top_p=0.85, seed=31415926)
    return engine, sampler


def resolve_image_path(image_path: str, data_repo: str) -> str:
    path = Path(image_path)
    if path.is_absolute() and path.exists():
        return str(path)
    candidate = Path(data_repo) / image_path
    if candidate.exists():
        return str(candidate)
    return str(path)


def prompt_candidates(example: dict) -> list[dict]:
    out = []
    for cand in example.get("original_candidates", []):
        out.append(strip_confidence(cand))
    return out


def run_trial(engine, sampler, image_path: str, candidates: list[dict], data_repo: str) -> str:
    prompt = PROMPT_TEMPLATE.format(candidates=format_candidates_for_prompt(candidates))
    resolved_image = resolve_image_path(image_path, data_repo)
    with engine.create_conversation(system_message="You are a careful biological identification evaluator.", sampler_config=sampler) as conv:
        response = conv.send_message(
            {
                "role": "user",
                "content": [
                    {"type": "text", "text": prompt},
                    {"type": "image", "path": resolved_image},
                ],
            }
        )
    return response.get("content", [{}])[0].get("text", str(response))


def extract_prediction(raw_text: str, candidates: list[dict]) -> dict:
    parsed = parse_response_json(raw_text)
    if not isinstance(parsed, dict):
        parsed = {}
    sci = str(parsed.get("scientific_name") or "").strip()
    common = str(parsed.get("common_name") or "").strip()
    rank = parsed.get("selected_candidate_rank")
    if isinstance(rank, str) and rank.isdigit():
        rank = int(rank)
    if not isinstance(rank, int):
        rank = None

    if rank is None:
        rank = match_candidate_rank(raw_text, candidates)

    if not sci and rank and 1 <= rank <= len(candidates):
        sci = candidate_scientific_name(candidates[rank - 1])
    if not common and rank and 1 <= rank <= len(candidates):
        common = candidate_common_name(candidates[rank - 1])

    answer_text = sci or common or str(parsed.get("answer") or raw_text).strip()
    return {
        "parsed": parsed,
        "predicted_scientific_name": sci,
        "predicted_common_name": common,
        "selected_candidate_rank": rank,
        "predicted_answer": answer_text,
        "predicted_answer_normalized": normalize_species_name(answer_text),
    }


def is_correct(prediction: dict, ground_truth_species: str, ground_truth_common_name: str) -> bool:
    gt_species = normalize_species_name(ground_truth_species)
    gt_common = normalize_species_name(ground_truth_common_name)
    pred_species = normalize_species_name(prediction.get("predicted_scientific_name"))
    pred_common = normalize_species_name(prediction.get("predicted_common_name"))
    pred_answer = normalize_species_name(prediction.get("predicted_answer"))
    return any(
        candidate and candidate in {gt_species, gt_common}
        for candidate in (pred_species, pred_common, pred_answer)
    )


def ordered_candidates(candidates: list[dict], seed: int, example_id: str, trial_id: str, order_mode: str) -> list[dict]:
    copied = [dict(c) for c in candidates]
    if order_mode == "reverse":
        copied = list(reversed(copied))
    else:
        rng = random.Random(stable_int_seed(seed, example_id, trial_id))
        rng.shuffle(copied)
    for i, cand in enumerate(copied, 1):
        cand["rank"] = i
    return copied


def expected_rows_per_example(order_mode: str, trials: int) -> int:
    if order_mode == "reverse":
        return 2
    if order_mode == "shuffle_then_reverse":
        return 1 + 2 * trials
    return 1 + trials


def append_jsonl(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as f:
        for row in rows:
            f.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", required=True, help="Frozen examples JSONL from the build step")
    parser.add_argument("--trials", type=int, default=DEFAULT_TRIALS, help="Number of shuffled trials per example")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic shuffle seed")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT_DIR / "rank_sensitivity_results.jsonl"), help="Output JSONL")
    parser.add_argument("--model-path", default=DEFAULT_MODEL_PATH, help="Path to the Gemma 4 LiteRT-LM bundle")
    parser.add_argument("--data-repo", default=DEFAULT_DATA_REPO, help="Path to the sibling sirkulab-mero-data repo")
    parser.add_argument("--backend", default="cpu", choices=["cpu", "gpu", "npu"], help="LiteRT backend to use")
    parser.add_argument(
        "--enable-speculative-decoding",
        action="store_true",
        help="Enable speculative decoding when the model bundle supports it",
    )
    parser.add_argument("--order-mode", default="shuffle", choices=["shuffle", "reverse", "shuffle_then_reverse"], help="How to order the candidate list for non-original trials")
    args = parser.parse_args()

    examples_path = Path(args.examples)
    if not examples_path.exists():
        raise ExperimentError(f"Examples JSONL not found: {examples_path}")

    examples = load_jsonl(examples_path)
    if not examples:
        raise ExperimentError(f"No examples found in {examples_path}")

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    existing_rows = load_jsonl(output_path) if output_path.exists() else []
    expected_rows = expected_rows_per_example(args.order_mode, args.trials)
    existing_counts = {}
    completed_example_ids = set()
    for row in existing_rows:
        ex_id = row.get("example_id")
        if not ex_id:
            continue
        existing_counts[ex_id] = existing_counts.get(ex_id, 0) + 1
    for ex_id, count in existing_counts.items():
        if count >= expected_rows:
            completed_example_ids.add(ex_id)
        else:
            print(f"Discarding partial checkpoint for {ex_id}: {count}/{expected_rows} rows", flush=True)
    results = [row for row in existing_rows if row.get("example_id") in completed_example_ids]
    if len(results) != len(existing_rows):
        # Rewrite to a clean checkpoint before resuming.
        from _common import write_jsonl
        write_jsonl(output_path, results)
    if completed_example_ids:
        print(f"Resuming from {len(completed_example_ids)} completed examples", flush=True)

    engine, sampler = load_runtime(
        args.model_path,
        args.backend,
        enable_speculative_decoding=args.enable_speculative_decoding,
    )

    total_examples = len(examples)
    started = time.time()
    for index, example in enumerate(examples, 1):
        image_path = str(example.get("image_path") or "")
        if not image_path:
            raise ExperimentError(f"Example {example.get('example_id')} is missing image_path")

        if example["example_id"] in completed_example_ids:
            print(f"[{index}/{total_examples}] {example['example_id']} (checkpointed, skipping)", flush=True)
            continue

        original_candidates = prompt_candidates(example)
        if not original_candidates:
            raise ExperimentError(f"Example {example.get('example_id')} has no original_candidates")

        example_start = time.time()
        print(f"[{index}/{total_examples}] {example['example_id']}", flush=True)

        gt_species = str(example.get("ground_truth_species") or "").strip()
        gt_common = str(example.get("ground_truth_common_name") or "").strip()
        example_rows = []

        original_raw = run_trial(engine, sampler, image_path, original_candidates, args.data_repo)
        original_prediction = extract_prediction(original_raw, original_candidates)
        original_is_correct = is_correct(original_prediction, gt_species, gt_common) if gt_species or gt_common else None
        original_row = {
            "example_id": example["example_id"],
            "trial_id": "original",
            "order_type": "original",
            "candidate_order": original_candidates,
            "candidate_identity_order": [candidate_scientific_name(c) for c in original_candidates],
            "final_answer": original_prediction["predicted_answer"],
            "predicted_scientific_name": original_prediction["predicted_scientific_name"],
            "predicted_common_name": original_prediction["predicted_common_name"],
            "selected_candidate_rank": original_prediction["selected_candidate_rank"],
            "raw_response": original_raw,
            "ground_truth_species": gt_species,
            "ground_truth_common_name": gt_common,
            "is_correct": original_is_correct,
            "is_correct_scientific_name": original_is_correct,
            "metadata": example.get("metadata", {}),
        }
        results.append(original_row)
        example_rows.append(original_row)

        variant_trials = 1 if args.order_mode in {"reverse", "shuffle_then_reverse"} else args.trials
        for trial_idx in range(1, variant_trials + 1):
            shuffle_trial_id = f"shuffle-{trial_idx:02d}"
            if args.order_mode == "reverse":
                candidates = [dict(c) for c in original_candidates]
                candidates.reverse()
                for i, cand in enumerate(candidates, 1):
                    cand["rank"] = i
                candidate_sets = [("reversed", "reverse", candidates)]
            elif args.order_mode == "shuffle_then_reverse":
                shuffled = ordered_candidates(original_candidates, args.seed, example["example_id"], shuffle_trial_id, "shuffle")
                reversed_candidates = [dict(c) for c in reversed(shuffled)]
                for i, cand in enumerate(reversed_candidates, 1):
                    cand["rank"] = i
                candidate_sets = [
                    ("shuffled", shuffle_trial_id, shuffled),
                    ("reversed", f"reverse-{trial_idx:02d}", reversed_candidates),
                ]
            else:
                candidates = ordered_candidates(original_candidates, args.seed, example["example_id"], shuffle_trial_id, "shuffle")
                candidate_sets = [("shuffled", shuffle_trial_id, candidates)]

            for order_type, trial_id, candidates in candidate_sets:
                raw = run_trial(engine, sampler, image_path, candidates, args.data_repo)
                prediction = extract_prediction(raw, candidates)
                correct = is_correct(prediction, gt_species, gt_common) if gt_species or gt_common else None
                row = {
                    "example_id": example["example_id"],
                    "trial_id": trial_id,
                    "order_type": order_type,
                    "candidate_order": candidates,
                    "candidate_identity_order": [candidate_scientific_name(c) for c in candidates],
                    "final_answer": prediction["predicted_answer"],
                    "predicted_scientific_name": prediction["predicted_scientific_name"],
                    "predicted_common_name": prediction["predicted_common_name"],
                    "selected_candidate_rank": prediction["selected_candidate_rank"],
                    "raw_response": raw,
                    "ground_truth_species": gt_species,
                    "ground_truth_common_name": gt_common,
                    "is_correct": correct,
                    "is_correct_scientific_name": correct,
                    "metadata": example.get("metadata", {}),
                }
                results.append(row)
                example_rows.append(row)

        append_jsonl(output_path, example_rows)
        completed_example_ids.add(example["example_id"])

        elapsed = time.time() - example_start
        rate = len(results) / max(time.time() - started, 1e-6)
        print(f"  done in {elapsed:.1f}s; rows so far: {len(results)}; throughput: {rate:.2f} rows/s", flush=True)

    print(f"Wrote {len(results)} result rows to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
