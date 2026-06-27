#!/usr/bin/env python3
"""Shared helpers for Hugging Face Gemma 4 mechanistic analyses."""
from __future__ import annotations

import importlib.util
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import torch

HERE = Path(__file__).resolve()
REPO_ROOT = next(p for p in HERE.parents if (p / "assets" / "data" / "species_data.sqlite").exists())
BASE_COMMON_PATH = REPO_ROOT / "scripts" / "candidate-rank-sensitivity" / "_common.py"


def _load_base_common():
    spec = importlib.util.spec_from_file_location("candidate_rank_common", BASE_COMMON_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not import shared helpers from {BASE_COMMON_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


BASE = _load_base_common()

DEFAULT_OUTPUT_DIR = REPO_ROOT / "outputs" / "candidate-rank-mechanistic"
DEFAULT_EXAMPLES = REPO_ROOT / "outputs" / "candidate-rank-sensitivity" / "confidence_score_examples.jsonl"
DEFAULT_MODEL_ID = "google/gemma-4-E2B-it"

candidate_scientific_name = BASE.candidate_scientific_name
candidate_common_name = BASE.candidate_common_name
candidate_genus = BASE.candidate_genus
candidate_confidence_value = BASE.candidate_confidence_value
format_candidates_for_prompt = BASE.format_candidates_for_prompt
load_jsonl = BASE.load_jsonl
write_jsonl = BASE.write_jsonl
strip_confidence = BASE.strip_confidence
normalize_text = BASE.normalize_text
ExperimentError = BASE.ExperimentError


@dataclass
class HFBundle:
    model: Any
    processor: Any
    tokenizer: Any


def load_hf_bundle(model_id: str = DEFAULT_MODEL_ID, device_map: str = "auto") -> HFBundle:
    try:
        from transformers import AutoProcessor
    except Exception as exc:  # pragma: no cover - environment dependent
        raise ExperimentError(
            "Transformers is not available in this environment. Install the HF stack "
            "used for Gemma 4 analysis first."
        ) from exc

    try:
        from transformers import AutoModelForImageTextToText as ModelClass
    except Exception:
        try:
            from transformers import AutoModelForMultimodalLM as ModelClass
        except Exception as exc:  # pragma: no cover - environment dependent
            raise ExperimentError(
                "This Transformers build does not expose a Gemma 4 multimodal model class."
            ) from exc

    processor = AutoProcessor.from_pretrained(model_id)
    model = ModelClass.from_pretrained(
        model_id,
        torch_dtype=torch.bfloat16,
        device_map=device_map,
    )
    model.eval()
    tokenizer = getattr(processor, "tokenizer", None)
    if tokenizer is None:
        try:
            from transformers import AutoTokenizer

            tokenizer = AutoTokenizer.from_pretrained(model_id)
        except Exception as exc:  # pragma: no cover - environment dependent
            raise ExperimentError("Unable to load a tokenizer for the Gemma 4 model.") from exc
    return HFBundle(model=model, processor=processor, tokenizer=tokenizer)


def make_candidate_prompt(candidates: list[dict], instruction: str = "") -> str:
    header = instruction.strip() or "You are evaluating candidate likelihood in species identification."
    return (
        f"{header}\n\n"
        "Task:\n"
        "- Read the candidate list carefully.\n"
        "- Choose the single best species.\n"
        "- Return the scientific name only.\n\n"
        f"Candidates:\n{format_candidates_for_prompt(candidates)}\n\n"
        "Answer:\n"
    )


def candidate_completion(candidate: dict) -> str:
    completion = candidate_scientific_name(candidate) or candidate_common_name(candidate)
    if not completion:
        raise ExperimentError("Candidate is missing both scientific and common names")
    return completion


def move_candidate(candidates: list[dict], source_rank: int, target_position: int) -> list[dict]:
    if source_rank < 1 or source_rank > len(candidates):
        raise ExperimentError(f"source_rank {source_rank} is out of range for {len(candidates)} candidates")
    if target_position < 1 or target_position > len(candidates):
        raise ExperimentError(f"target_position {target_position} is out of range for {len(candidates)} candidates")
    copied = [dict(c) for c in candidates]
    picked = copied.pop(source_rank - 1)
    copied.insert(target_position - 1, picked)
    return copied


def _encode_text(processor: Any, text: str) -> dict[str, torch.Tensor]:
    inputs = processor(text=text, return_tensors="pt", padding=False)
    if not hasattr(inputs, "items"):
        raise ExperimentError("Processor did not return a mapping of tensors")
    return {k: v for k, v in inputs.items() if torch.is_tensor(v)}


def score_completion(bundle: HFBundle, prompt: str, completion: str) -> dict[str, Any]:
    prompt_inputs = _encode_text(bundle.processor, prompt)
    full_inputs = _encode_text(bundle.processor, prompt + completion)
    prompt_ids = prompt_inputs.get("input_ids")
    full_ids = full_inputs.get("input_ids")
    attention_mask = full_inputs.get("attention_mask")
    if prompt_ids is None or full_ids is None:
        raise ExperimentError("Tokenizer inputs are missing input_ids")

    prompt_len = int(prompt_ids.shape[1])
    full_len = int(full_ids.shape[1])
    if full_len <= prompt_len:
        raise ExperimentError("Full prompt did not add any completion tokens")

    model_device = next((p.device for p in bundle.model.parameters() if p is not None), torch.device("cpu"))
    model_inputs = {"input_ids": full_ids.to(model_device)}
    if attention_mask is not None:
        model_inputs["attention_mask"] = attention_mask.to(model_device)

    with torch.no_grad():
        outputs = bundle.model(**model_inputs, return_dict=True)

    logits = outputs.logits
    shifted_logits = logits[:, prompt_len - 1 : full_len - 1, :]
    target_ids = full_ids[:, prompt_len:].to(model_device)
    log_probs = torch.log_softmax(shifted_logits, dim=-1)
    token_log_probs = log_probs.gather(-1, target_ids.unsqueeze(-1)).squeeze(-1)
    token_scores = token_log_probs[0].detach().cpu().tolist()
    total_score = float(sum(token_scores))
    mean_score = total_score / len(token_scores) if token_scores else total_score
    return {
        "total_logprob": total_score,
        "mean_token_logprob": mean_score,
        "token_count": len(token_scores),
        "token_scores": token_scores,
    }


def pearson_r(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    mean_x = sum(xs) / len(xs)
    mean_y = sum(ys) / len(ys)
    cov = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys))
    var_x = sum((x - mean_x) ** 2 for x in xs)
    var_y = sum((y - mean_y) ** 2 for y in ys)
    if not var_x or not var_y:
        return None
    return cov / math.sqrt(var_x * var_y)


def rankdata(values: list[float]) -> list[float]:
    indexed = sorted(enumerate(values), key=lambda item: item[1])
    ranks = [0.0] * len(values)
    i = 0
    while i < len(indexed):
        j = i
        while j + 1 < len(indexed) and indexed[j + 1][1] == indexed[i][1]:
            j += 1
        avg_rank = (i + j + 2) / 2.0
        for k in range(i, j + 1):
            ranks[indexed[k][0]] = avg_rank
        i = j + 1
    return ranks


def spearman_r(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) != len(ys) or len(xs) < 2:
        return None
    return pearson_r(rankdata(xs), rankdata(ys))
