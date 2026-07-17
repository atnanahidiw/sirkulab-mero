#!/usr/bin/env python3
"""Activation patching for candidate-rank bias with Hugging Face Gemma via plain PyTorch hooks.

This script tests whether moving activations from a clean prompt into a corrupted
prompt causally restores the target candidate's completion score.

Clean prompt:
    target candidate moved to --clean-position, default 1

Corrupted prompt:
    same target candidate moved to --corrupted-position, default 5

Main patch sites:
    candidate_span
    candidate_last_token
    answer_position
    matched_control
    self_patch

Main scientific caution:
    Activation patching is causal with respect to the intervention performed,
    but it does not by itself prove a complete circuit. Compare candidate-span
    recovery against matched_control and self_patch before making strong claims.
"""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any

import torch

from common_hf import (
    DEFAULT_EXAMPLES,
    DEFAULT_MODEL_ID,
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    build_scoring_tensors,
    candidate_completion_text,
    candidate_display_name,
    candidate_scientific_name,
    encode_text,
    load_hf_bundle,
    load_jsonl,
    locate_answer_position_span,
    locate_candidate_name_spans,
    make_candidate_prompt,
    move_candidate,
    safe_write_json,
    set_seed,
    strip_confidence,
    write_jsonl,
)


DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "activation_patching_rank_bias.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "activation_patching_rank_bias_summary.json"

DEFAULT_PATCH_SITES = (
    "candidate_span",
    "candidate_last_token",
    "answer_position",
    "matched_control",
    "self_patch",
)
ALLOWED_PATCH_SITES = set(DEFAULT_PATCH_SITES) | {"layout_prefix_control"}


def parse_csv_values(value: str) -> list[str]:
    items = [item.strip() for item in str(value or "").split(",") if item.strip()]
    if not items:
        raise ExperimentError("At least one value is required")
    return items


def append_jsonl(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if path.exists() else "w"
    with path.open(mode, encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def load_existing_keys(path: Path) -> set[tuple[str, str, str, str, int, int]]:
    if not path.exists():
        return set()

    keys: set[tuple[str, str, str, str, int, int]] = set()
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            keys.add(
                (
                    str(row.get("example_id")),
                    str(row.get("layer_name")),
                    str(row.get("patch_position")),
                    str(row.get("candidate_name")),
                    int(row.get("clean_position", 1)),
                    int(row.get("corrupted_position", 5)),
                )
            )
    return keys


def load_resume_state(path: Path, resume: bool) -> tuple[set[tuple[str, str, str, str, int, int]], int]:
    if not resume or not path.exists():
        return set(), 0

    keys = load_existing_keys(path)
    return keys, len(keys)


def select_patch_layers_by_spec(layer_names: list[str], selection: str) -> list[str]:
    if not layer_names:
        return []

    normalized = str(selection or "first,middle,last").strip().lower()
    if normalized == "all":
        return layer_names

    selected: list[str] = []
    seen: set[str] = set()

    for token in parse_csv_values(normalized):
        if token == "first":
            idx = 0
        elif token == "middle":
            idx = len(layer_names) // 2
        elif token == "last":
            idx = len(layer_names) - 1
        else:
            try:
                idx = int(token)
            except ValueError as exc:
                raise ExperimentError(
                    f"Unknown patch layer selector {token!r}. "
                    "Use first, middle, last, all, or comma-separated indices."
                ) from exc

            if idx < 0:
                idx = len(layer_names) + idx

        if idx < 0 or idx >= len(layer_names):
            raise ExperimentError(
                f"Patch layer index {idx} is out of range for {len(layer_names)} layers"
            )

        layer_name = layer_names[idx]
        if layer_name not in seen:
            selected.append(layer_name)
            seen.add(layer_name)

    return selected


def select_text_backbone_layers(layer_names: list[str]) -> list[str]:
    preferred_markers = (
        "language_model",
        "text_model",
        "languagemodel",
        "lm_model",
        "lm_head",  # fallback if the text stack exposes only a single transformer path
    )
    preferred = [name for name in layer_names if any(marker in name for marker in preferred_markers)]
    return preferred or layer_names


def layer_name_to_index(layer_name: str) -> int:
    parts = [part for part in layer_name.split(".") if part.isdigit()]
    if not parts:
        raise ExperimentError(f"Could not infer a numeric layer index from {layer_name!r}")
    return int(parts[-1])


def move_batch_to_device(
    batch: dict[str, torch.Tensor],
    device: torch.device,
) -> dict[str, torch.Tensor]:
    return {
        key: value.to(device) if isinstance(value, torch.Tensor) else value
        for key, value in batch.items()
    }


def resolve_module_by_name(model: Any, module_name: str) -> Any:
    modules = dict(model.named_modules())
    module = modules.get(module_name)
    if module is None:
        raise ExperimentError(f"Could not find hook module {module_name!r} on the model")
    return module


def hook_tensor_from_output(output: Any) -> torch.Tensor:
    if isinstance(output, torch.Tensor):
        return output
    if isinstance(output, (tuple, list)) and output and isinstance(output[0], torch.Tensor):
        return output[0]
    raise ExperimentError("Hook target did not return a tensor-like activation")


def rebuild_hook_output(original_output: Any, patched_tensor: torch.Tensor) -> Any:
    if isinstance(original_output, torch.Tensor):
        return patched_tensor
    if isinstance(original_output, tuple):
        return (patched_tensor, *original_output[1:])
    if isinstance(original_output, list):
        rebuilt = list(original_output)
        rebuilt[0] = patched_tensor
        return rebuilt
    raise ExperimentError("Unsupported hook output type")


def choose_target_candidate(candidates: list[dict], example: dict) -> int:
    target_names = [
        str(example.get("ground_truth_species") or "").strip(),
        str(example.get("baseline_answer_species") or "").strip(),
    ]

    for target in target_names:
        if not target:
            continue
        for idx, candidate in enumerate(candidates, 1):
            if candidate_scientific_name(candidate) == target:
                return idx

    return 1


def candidate_scores(
    bundle,
    prompt: str,
    candidates: list[dict],
    answer_format: str = "scientific_name_only",
) -> dict[str, dict[str, Any]]:
    scores: dict[str, dict[str, Any]] = {}

    for idx, candidate in enumerate(candidates, 1):
        completion = candidate_completion_text(candidate, answer_format, idx)
        score_info = bundle.score(prompt, completion)
        name = candidate_scientific_name(candidate) or candidate_display_name(candidate)

        scores[name] = {
            "completion_text": completion,
            "candidate_answer_logprob": float(score_info["candidate_answer_logprob"]),
            "candidate_answer_avg_logprob": float(score_info["candidate_answer_avg_logprob"]),
            "next_token_logprob_for_candidate_start": float(
                score_info["next_token_logprob_for_candidate_start"]
            ),
            "token_count": int(score_info["token_count"]),
            "full_candidate_sequence_logprob": float(score_info["full_candidate_sequence_logprob"]),
        }

    return scores


def candidate_scores_batched(
    bundle,
    prompt: str,
    candidates: list[dict],
    answer_format: str = "scientific_name_only",
) -> dict[str, dict[str, Any]]:
    prompt_completion_pairs: list[tuple[str, str]] = []
    ordered_names: list[str] = []

    for idx, candidate in enumerate(candidates, 1):
        completion = candidate_completion_text(candidate, answer_format, idx)
        prompt_completion_pairs.append((prompt, completion))
        ordered_names.append(candidate_scientific_name(candidate) or candidate_display_name(candidate))

    scores: dict[str, dict[str, Any]] = {}
    for name, score_info, (_, completion) in zip(ordered_names, bundle.score_batch(prompt_completion_pairs), prompt_completion_pairs):
        scores[name] = {
            "completion_text": completion,
            "candidate_answer_logprob": float(score_info["candidate_answer_logprob"]),
            "candidate_answer_avg_logprob": float(score_info["candidate_answer_avg_logprob"]),
            "next_token_logprob_for_candidate_start": float(
                score_info["next_token_logprob_for_candidate_start"]
            ),
            "token_count": int(score_info["token_count"]),
            "full_candidate_sequence_logprob": float(score_info["full_candidate_sequence_logprob"]),
        }

    return scores


def get_top_candidate(scores: dict[str, dict[str, Any]]) -> str | None:
    if not scores:
        return None
    return max(
        scores.items(),
        key=lambda item: item[1]["candidate_answer_avg_logprob"],
    )[0]


def score_logits(bundle, prompt: str, completion: str, logits: torch.Tensor) -> dict[str, Any]:
    full_input_ids, _attention_mask, prompt_len = build_scoring_tensors(
        bundle.tokenizer,
        prompt,
        completion,
    )
    full_len = int(full_input_ids.shape[1])

    if full_len <= prompt_len:
        raise ExperimentError("Full prompt did not add any completion tokens")

    shifted_logits = logits[:, prompt_len - 1 : full_len - 1, :]
    target_ids = full_input_ids[:, prompt_len:].to(logits.device)

    log_probs = torch.log_softmax(shifted_logits, dim=-1)
    token_log_probs = log_probs.gather(-1, target_ids.unsqueeze(-1)).squeeze(-1)

    token_scores = token_log_probs[0].detach().cpu().tolist()
    total_score = float(sum(token_scores))
    token_count = len(token_scores)
    mean_score = total_score / token_count if token_count else total_score
    next_token_lp = float(token_scores[0]) if token_scores else total_score

    return {
        "candidate_answer_logprob": total_score,
        "candidate_answer_avg_logprob": mean_score,
        "next_token_logprob_for_candidate_start": next_token_lp,
        "full_candidate_sequence_logprob": total_score,
        "token_count": token_count,
        "token_scores": token_scores,
        "total_logprob": total_score,
        "mean_token_logprob": mean_score,
    }


def score_candidate_set(
    bundle,
    prompt: str,
    candidates: list[dict],
) -> tuple[dict[str, dict[str, Any]], str | None]:
    scores = candidate_scores_batched(
        bundle,
        prompt,
        candidates,
        answer_format="scientific_name_only",
    )
    return scores, get_top_candidate(scores)


def capture_layer_activations(
    bundle,
    hook_module: Any,
    prompt: str,
) -> torch.Tensor:
    captured: dict[str, torch.Tensor] = {}

    def capture_hook(_module, _inputs, output):
        captured["tensor"] = hook_tensor_from_output(output).detach()
        return None

    handle = hook_module.register_forward_hook(capture_hook)
    try:
        with torch.inference_mode():
            inputs = move_batch_to_device(encode_text(bundle.tokenizer, prompt), bundle.model_device())
            bundle.model(**inputs, return_dict=True)
    finally:
        handle.remove()

    tensor = captured.get("tensor")
    if tensor is None:
        raise ExperimentError("Could not capture source activations")
    return tensor


def score_candidate_set_with_patch(
    bundle,
    hook_module: Any,
    corrupted_prompt: str,
    candidates: list[dict],
    source_tensor: torch.Tensor,
    src_positions: list[int],
    dst_positions: list[int],
    use_self_patch: bool = False,
    strict_prompt_length: bool = False,
) -> tuple[dict[str, dict[str, Any]], str | None]:
    scores: dict[str, dict[str, Any]] = {}
    top_candidate = None
    top_score = None

    if len(src_positions) != len(dst_positions):
        shared = min(len(src_positions), len(dst_positions))
        src_positions = src_positions[:shared]
        dst_positions = dst_positions[:shared]

    if not src_positions or not dst_positions:
        return scores, None

    source_positions = dst_positions if use_self_patch else src_positions
    corrupted_prompt_len = prompt_token_count(bundle.tokenizer, corrupted_prompt)

    if max(source_positions) >= source_tensor.shape[1] or max(dst_positions) >= corrupted_prompt_len:
        raise ExperimentError("Patch positions exceed the available prompt token length")

    bundle.model.eval()

    with torch.inference_mode():
        for idx, candidate in enumerate(candidates, 1):
            completion = candidate_completion_text(candidate, "scientific_name_only", idx)

            target_input_ids, target_attention_mask, target_prompt_len = build_scoring_tensors(
                bundle.tokenizer,
                corrupted_prompt,
                completion,
            )

            full_len = int(target_input_ids.shape[1])
            if full_len <= target_prompt_len:
                raise ExperimentError("Full prompt did not add completion tokens")

            target_inputs = move_batch_to_device(
                {
                    "input_ids": target_input_ids,
                    "attention_mask": target_attention_mask,
                },
                bundle.model_device(),
            )

            if target_prompt_len <= max(dst_positions):
                raise ExperimentError("Target activations are shorter than the requested destination positions")

            source_slice = source_tensor[:, source_positions, :].to(bundle.model_device())

            def patch_hook(_module, _inputs, output):
                tensor = hook_tensor_from_output(output)
                if tensor.shape[1] < max(dst_positions) + 1:
                    raise ExperimentError("Patched layer output is shorter than the destination positions")
                patched_tensor = tensor.clone()
                patched_tensor[:, dst_positions, :] = source_slice
                return rebuild_hook_output(output, patched_tensor)

            patch_handle = hook_module.register_forward_hook(patch_hook)
            try:
                outputs_for_logits = bundle.model(**target_inputs, return_dict=True)
            finally:
                patch_handle.remove()

            logits = outputs_for_logits.logits if hasattr(outputs_for_logits, "logits") else outputs_for_logits[0]
            score_info = score_logits(bundle, corrupted_prompt, completion, logits)

            name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
            scores[name] = {
                "completion_text": completion,
                "candidate_answer_logprob": float(score_info["candidate_answer_logprob"]),
                "candidate_answer_avg_logprob": float(score_info["candidate_answer_avg_logprob"]),
                "next_token_logprob_for_candidate_start": float(
                    score_info["next_token_logprob_for_candidate_start"]
                ),
                "token_count": int(score_info["token_count"]),
                "full_candidate_sequence_logprob": float(
                    score_info["full_candidate_sequence_logprob"]
                ),
            }

            score = float(score_info["candidate_answer_avg_logprob"])
            if top_score is None or score > top_score:
                top_score = score
                top_candidate = name

    return scores, top_candidate


def span_to_positions(span: tuple[int, int] | None) -> list[int]:
    if span is None:
        return []
    start, end = span
    if end <= start:
        return []
    return list(range(start, end))


def last_token_of_span(span: tuple[int, int] | None) -> list[int]:
    if span is None:
        return []
    start, end = span
    if end <= start:
        return []
    return [end - 1]


def prefix_token_of_span(span: tuple[int, int] | None) -> list[int]:
    if span is None:
        return []
    start, _end = span
    if start <= 0:
        return []
    return [start - 1]


def token_distance_to_answer(
    span_positions: list[int],
    answer_span: tuple[int, int] | None,
) -> int | None:
    if not span_positions or answer_span is None:
        return None
    return abs(answer_span[0] - span_positions[-1])


def contiguous_windows(
    *,
    token_count: int,
    width: int,
    forbidden_positions: set[int],
) -> list[list[int]]:
    if token_count <= 0 or width <= 0 or width > token_count:
        return []

    windows: list[list[int]] = []
    for start in range(0, token_count - width + 1):
        window = list(range(start, start + width))
        if any(pos in forbidden_positions for pos in window):
            continue
        windows.append(window)

    return windows


def choose_distance_matched_control_positions(
    *,
    token_count: int,
    width: int,
    target_distance: int | None,
    answer_span: tuple[int, int] | None,
    forbidden_spans: list[tuple[int, int] | None],
) -> list[int]:
    if width <= 0 or token_count <= 0:
        return []

    forbidden_positions: set[int] = set()

    for span in forbidden_spans:
        if span is None:
            continue
        forbidden_positions.update(range(span[0], span[1]))

    if answer_span is not None:
        forbidden_positions.update(range(answer_span[0], answer_span[1]))

    windows = contiguous_windows(
        token_count=token_count,
        width=width,
        forbidden_positions=forbidden_positions,
    )
    if not windows:
        return []

    if target_distance is None or answer_span is None:
        return windows[0]

    def window_score(window: list[int]) -> tuple[int, int]:
        distance = abs(answer_span[0] - window[-1])
        return abs(distance - target_distance), window[0]

    return min(windows, key=window_score)


def prompt_token_count(tokenizer, prompt: str) -> int:
    encoded = tokenizer(prompt, return_tensors="pt", add_special_tokens=False)
    return int(encoded["input_ids"].shape[1])


def make_patch_positions(
    site: str,
    clean_span: tuple[int, int] | None,
    corrupted_span: tuple[int, int] | None,
    clean_answer_span: tuple[int, int] | None,
    corrupted_answer_span: tuple[int, int] | None,
    clean_token_count: int,
    corrupted_token_count: int,
) -> tuple[list[int], list[int]]:
    if site == "candidate_span":
        src_positions = span_to_positions(clean_span)
        dst_positions = span_to_positions(corrupted_span)

    elif site == "candidate_last_token":
        src_positions = last_token_of_span(clean_span)
        dst_positions = last_token_of_span(corrupted_span)

    elif site == "answer_position":
        src_positions = last_token_of_span(clean_answer_span)
        dst_positions = last_token_of_span(corrupted_answer_span)

    elif site == "layout_prefix_control":
        src_positions = prefix_token_of_span(clean_span)
        dst_positions = prefix_token_of_span(corrupted_span)

    elif site == "matched_control":
        candidate_src_positions = span_to_positions(clean_span)
        candidate_dst_positions = span_to_positions(corrupted_span)
        width = min(len(candidate_src_positions), len(candidate_dst_positions))

        if width <= 0:
            return [], []

        clean_target_distance = token_distance_to_answer(
            candidate_src_positions,
            clean_answer_span,
        )
        corrupted_target_distance = token_distance_to_answer(
            candidate_dst_positions,
            corrupted_answer_span,
        )

        src_positions = choose_distance_matched_control_positions(
            token_count=clean_token_count,
            width=width,
            target_distance=clean_target_distance,
            answer_span=clean_answer_span,
            forbidden_spans=[clean_span, clean_answer_span],
        )
        dst_positions = choose_distance_matched_control_positions(
            token_count=corrupted_token_count,
            width=width,
            target_distance=corrupted_target_distance,
            answer_span=corrupted_answer_span,
            forbidden_spans=[corrupted_span, corrupted_answer_span],
        )

    elif site == "self_patch":
        src_positions = span_to_positions(corrupted_span)
        dst_positions = span_to_positions(corrupted_span)

    else:
        return [], []

    shared = min(len(src_positions), len(dst_positions))
    return src_positions[:shared], dst_positions[:shared]


def summarise(rows: list[dict]) -> dict:
    by_layer: dict[str, list[float]] = defaultdict(list)
    by_position: dict[str, list[float]] = defaultdict(list)
    by_site_and_layer: dict[str, list[float]] = defaultdict(list)

    all_recovery: list[float] = []
    control_recovery: list[float] = []
    noncontrol_recovery: list[float] = []

    patched_top_candidate_flip_rows = 0
    total_rows = len(rows)

    control_sites = {"matched_control", "self_patch", "layout_prefix_control"}

    for row in rows:
        layer = str(row["layer_name"])
        position = str(row["patch_position"])
        recovery = row.get("candidate_logprob_recovery")

        if recovery is not None:
            recovery_value = float(recovery)
            by_layer[layer].append(recovery_value)
            by_position[position].append(recovery_value)
            by_site_and_layer[f"{position}::{layer}"].append(recovery_value)
            all_recovery.append(recovery_value)

            if position in control_sites:
                control_recovery.append(recovery_value)
            else:
                noncontrol_recovery.append(recovery_value)

        if row.get("patched_top_candidate_flip_rate"):
            patched_top_candidate_flip_rows += 1

    def mean(values: list[float]) -> float | None:
        return sum(values) / len(values) if values else None

    best_patch = None
    for row in rows:
        recovery = row.get("candidate_logprob_recovery")
        if recovery is None:
            continue

        score = float(recovery)
        if best_patch is None or score > best_patch["candidate_logprob_recovery"]:
            best_patch = {
                "layer_name": row["layer_name"],
                "patch_position": row["patch_position"],
                "candidate_logprob_recovery": score,
                "example_id": row.get("example_id"),
                "candidate_name": row.get("candidate_name"),
                "num_patch_units": row.get("num_patch_units"),
            }

    mean_control = mean(control_recovery)
    mean_noncontrol = mean(noncontrol_recovery)

    return {
        "status": "ok" if rows else "no_data",
        "num_rows": total_rows,
        "patch_backend": "pytorch_hook",
        "mean_logprob_recovery_by_layer": {
            key: mean(value) for key, value in by_layer.items()
        },
        "mean_logprob_recovery_by_position": {
            key: mean(value) for key, value in by_position.items()
        },
        "mean_logprob_recovery_by_site_and_layer": {
            key: mean(value) for key, value in by_site_and_layer.items()
        },
        "overall_mean_candidate_logprob_recovery": mean(all_recovery),
        "mean_control_recovery": mean_control,
        "mean_noncontrol_recovery": mean_noncontrol,
        "noncontrol_minus_control_recovery": (
            None
            if mean_noncontrol is None or mean_control is None
            else mean_noncontrol - mean_control
        ),
        "patched_top_candidate_flip_rate": (
            patched_top_candidate_flip_rows / total_rows if total_rows else None
        ),
        "best_patch": best_patch,
        "best_patch_layer": best_patch["layer_name"] if best_patch else None,
        "best_patch_position": best_patch["patch_position"] if best_patch else None,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Per-row JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples")
    parser.add_argument("--max-examples", type=int, default=0, help="Alternative limit for convenience")
    parser.add_argument("--seed", type=int, default=7, help="Random seed")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID, help="Hugging Face model id")
    parser.add_argument("--device", default="auto", help="torch device to use")
    parser.add_argument("--dtype", default="auto", help="torch dtype to use")
    parser.add_argument("--resume", action="store_true", help="Resume from an existing JSONL output file")
    parser.add_argument(
        "--patch-sites",
        default=",".join(DEFAULT_PATCH_SITES),
        help="Comma-separated patch sites to run.",
    )
    parser.add_argument(
        "--patch-layers",
        default="first,middle,last",
        help="Patch layers: first,middle,last,all, or comma-separated layer indices.",
    )
    parser.add_argument(
        "--clean-position",
        type=int,
        default=1,
        help="Position used for the clean prompt.",
    )
    parser.add_argument(
        "--corrupted-position",
        type=int,
        default=5,
        help="Position used for the corrupted prompt.",
    )
    parser.add_argument(
        "--strict-prompt-length",
        action="store_true",
        help="Require clean and corrupted prompt+completion token lengths to match.",
    )
    return parser.parse_args()


def validate_patch_sites(patch_sites: list[str]) -> None:
    unknown_patch_sites = sorted(set(patch_sites) - ALLOWED_PATCH_SITES)
    if unknown_patch_sites:
        raise ExperimentError(
            "Unknown patch sites: "
            + ", ".join(unknown_patch_sites)
            + ". Allowed: "
            + ", ".join(sorted(ALLOWED_PATCH_SITES))
        )


def main() -> int:
    args = parse_args()

    set_seed(args.seed)

    examples = load_jsonl(Path(args.examples))
    limit = args.max_examples or args.limit
    if limit:
        examples = examples[:limit]

    output_path = Path(args.output)
    summary_path = Path(args.summary_output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)

    patch_sites = parse_csv_values(args.patch_sites)
    validate_patch_sites(patch_sites)

    existing_keys, num_resumed_rows = load_resume_state(output_path, args.resume)

    skipped = 0
    skipped_existing = 0
    skipped_missing_span = 0
    num_written_rows = 0

    bundle = load_hf_bundle(args.model_id, device=args.device, dtype=args.dtype)

    available_layer_names = bundle.transformer_block_names()
    text_layer_names = select_text_backbone_layers(available_layer_names)
    layer_names = select_patch_layers_by_spec(text_layer_names, args.patch_layers)

    if not layer_names:
        summary = {
            "status": "skipped",
            "reason": "No intervention-capable transformer block names were found on the model.",
            "model_id": args.model_id,
            "output": str(output_path),
            "summary_output": str(summary_path),
            "available_layer_names": available_layer_names,
            "text_layer_names": text_layer_names,
        }
        safe_write_json(summary_path, summary)
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0

    total_examples = len(examples)

    for index, example in enumerate(examples, 1):
        example_id = str(example.get("example_id") or "")
        candidates = [strip_confidence(c) for c in (example.get("original_candidates") or [])]

        if not example_id or not candidates:
            skipped += 1
            continue

        if len(candidates) < 2:
            skipped += 1
            continue

        target_rank = choose_target_candidate(candidates, example)
        if target_rank < 1 or target_rank > len(candidates):
            skipped += 1
            continue

        clean_position = min(args.clean_position, len(candidates))
        corrupted_position = min(args.corrupted_position, len(candidates))

        print(f"[{index}/{total_examples}] {example_id} ({len(candidates)} candidates)", flush=True)

        clean_candidates = move_candidate(candidates, target_rank, clean_position)
        corrupted_candidates = move_candidate(candidates, target_rank, corrupted_position)

        clean_prompt = make_candidate_prompt(
            clean_candidates,
            list_style="numbered",
            answer_format="scientific_name_only",
        )
        corrupted_prompt = make_candidate_prompt(
            corrupted_candidates,
            list_style="numbered",
            answer_format="scientific_name_only",
        )

        target_candidate = candidates[target_rank - 1]
        candidate_name = candidate_scientific_name(target_candidate) or candidate_display_name(target_candidate)

        clean_scores, clean_top = score_candidate_set(bundle, clean_prompt, clean_candidates)
        corrupted_scores, corrupted_top = score_candidate_set(bundle, corrupted_prompt, corrupted_candidates)

        clean_score = clean_scores.get(candidate_name)
        corrupted_score = corrupted_scores.get(candidate_name)

        if clean_score is None or corrupted_score is None:
            skipped += 1
            continue

        clean_hidden_positions = locate_candidate_name_spans(
            bundle.tokenizer,
            clean_prompt,
            clean_candidates,
        )
        corrupted_hidden_positions = locate_candidate_name_spans(
            bundle.tokenizer,
            corrupted_prompt,
            corrupted_candidates,
        )

        clean_span = clean_hidden_positions.get(candidate_name)
        corrupted_span = corrupted_hidden_positions.get(candidate_name)
        clean_answer_span = locate_answer_position_span(bundle.tokenizer, clean_prompt)
        corrupted_answer_span = locate_answer_position_span(bundle.tokenizer, corrupted_prompt)

        clean_token_count = prompt_token_count(bundle.tokenizer, clean_prompt)
        corrupted_token_count = prompt_token_count(bundle.tokenizer, corrupted_prompt)

        if args.strict_prompt_length and clean_token_count != corrupted_token_count:
            raise ExperimentError(
                "Clean and corrupted prompt lengths differ. "
                "Disable --strict-prompt-length if this is expected."
            )

        example_rows: list[dict[str, Any]] = []
        for layer_name in layer_names:
            hook_module = resolve_module_by_name(bundle.model, layer_name)
            for patch_position in patch_sites:
                row_key = (
                    example_id,
                    layer_name,
                    patch_position,
                    candidate_name,
                    clean_position,
                    corrupted_position,
                )

                if row_key in existing_keys:
                    skipped_existing += 1
                    continue

                src_positions, dst_positions = make_patch_positions(
                    patch_position,
                    clean_span,
                    corrupted_span,
                    clean_answer_span,
                    corrupted_answer_span,
                    clean_token_count,
                    corrupted_token_count,
                )

                if not src_positions or not dst_positions:
                    skipped_missing_span += 1
                    continue

                use_self_patch = patch_position == "self_patch"
                source_prompt = corrupted_prompt if use_self_patch else clean_prompt
                source_tensor = capture_layer_activations(bundle, hook_module, source_prompt)

                patched_scores, patched_top = score_candidate_set_with_patch(
                    bundle,
                    hook_module,
                    corrupted_prompt,
                    corrupted_candidates,
                    source_tensor,
                    src_positions,
                    dst_positions,
                    use_self_patch=use_self_patch,
                    strict_prompt_length=args.strict_prompt_length,
                )

                patched_score = patched_scores.get(candidate_name)
                if patched_score is None:
                    skipped += 1
                    continue

                clean_val = float(clean_score["candidate_answer_avg_logprob"])
                corrupted_val = float(corrupted_score["candidate_answer_avg_logprob"])
                patched_val = float(patched_score["candidate_answer_avg_logprob"])
                num_patch_units = len(dst_positions)

                denom = clean_val - corrupted_val
                normalized_recovery = (
                    None
                    if abs(denom) < 1e-8
                    else (patched_val - corrupted_val) / denom
                )

                patched_top_candidate_flip_rate = int(
                    patched_top == clean_top and corrupted_top != clean_top
                )

                row = {
                    "example_id": example_id,
                    "image_path": example.get("image_path"),
                    "image_id": example.get("image_id"),
                    "ground_truth_species": example.get("ground_truth_species"),
                    "ground_truth_common_name": example.get("ground_truth_common_name"),
                    "ground_truth_genus": example.get("ground_truth_genus"),
                    "candidate_name": candidate_name,
                    "target_rank": target_rank,
                    "clean_position": clean_position,
                    "corrupted_position": corrupted_position,
                    "clean_top_candidate": clean_top,
                    "corrupted_top_candidate": corrupted_top,
                    "patched_top_candidate": patched_top,
                    "layer_name": layer_name,
                    "patch_position": patch_position,
                    "src_positions": src_positions,
                    "dst_positions": dst_positions,
                    "num_patch_units": num_patch_units,
                    "clean_token_count": clean_token_count,
                    "corrupted_token_count": corrupted_token_count,
                    "clean_candidate_logprob": clean_val,
                    "corrupted_candidate_logprob": corrupted_val,
                    "patched_candidate_logprob": patched_val,
                    "logit_recovery": patched_val - corrupted_val,
                    "candidate_logprob_recovery": normalized_recovery,
                    "patched_top_candidate_flip_rate": patched_top_candidate_flip_rate,
                    "patch_backend": "pytorch_hook",
                    "model_id": args.model_id,
                    "seed": args.seed,
                }

                example_rows.append(row)
                existing_keys.add(row_key)

        if example_rows:
            append_jsonl(output_path, example_rows)
            num_written_rows += len(example_rows)

    if num_written_rows == 0 and not output_path.exists():
        write_jsonl(output_path, [])

    all_rows = load_jsonl(output_path) if output_path.exists() else []
    summary = summarise(all_rows)
    summary.update(
        {
            "num_written_rows": num_written_rows,
            "num_total_rows": len(all_rows),
            "num_skipped_rows": skipped,
            "num_skipped_existing_rows": skipped_existing,
            "num_skipped_missing_span_rows": skipped_missing_span,
            "num_resumed_rows": num_resumed_rows,
            "num_hook_layers_selected": len(layer_names),
            "output": str(output_path),
            "summary_output": str(summary_path),
            "patched_layers": layer_names,
            "available_layer_names": available_layer_names,
            "text_layer_names": text_layer_names,
            "patch_sites": patch_sites,
            "clean_position": args.clean_position,
            "corrupted_position": args.corrupted_position,
            "strict_prompt_length": args.strict_prompt_length,
            "model_id": args.model_id,
            "seed": args.seed,
        }
    )

    safe_write_json(summary_path, summary)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
