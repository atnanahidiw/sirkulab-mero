#!/usr/bin/env python3
"""Shared helpers for Hugging Face-backed candidate-rank mechanistic analysis."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import math
import random
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Sequence

import numpy as np
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

DEFAULT_OUTPUT_DIR = REPO_ROOT / "outputs" / "03_candidate-rank-mechanistic"
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
    tokenizer: Any
    processor: Any | None
    device: str
    dtype: torch.dtype
    device_map: str | None

    def model_device(self) -> torch.device:
        return _model_device(self)

    def run(
        self,
        input_ids: torch.Tensor,
        attention_mask: torch.Tensor | None = None,
        output_hidden_states: bool = False,
    ):
        return _run_model(self, input_ids, attention_mask=attention_mask, output_hidden_states=output_hidden_states)

    def score(self, prompt: str, completion: str) -> dict[str, Any]:
        return score_completion(self, prompt, completion)

    def score_batch(self, prompt_completion_pairs: Sequence[tuple[str, str]]) -> list[dict[str, Any]]:
        return score_completions(self, prompt_completion_pairs)

    def hidden_states_for_prompt(self, prompt: str, layer_indices: Sequence[int] | None = None) -> Any:
        return extract_hidden_states(self, prompt, layer_indices=layer_indices)

    def layer_tensor(self, hidden_states: Any, layer_index: int) -> torch.Tensor:
        return hidden_state_tensor(hidden_states, layer_index)

    def transformer_block_names(self) -> list[str]:
        return locate_transformer_block_names(self.model)


@dataclass(frozen=True)
class PromptVariant:
    name: str
    list_style: str
    answer_format: str
    include_confidence: bool = False


PROMPT_VARIANTS: list[PromptVariant] = [
    PromptVariant("numbered_list", "numbered", "scientific_name_only"),
    PromptVariant("lettered_list", "lettered", "scientific_name_only"),
    PromptVariant("bulleted_list", "bulleted", "scientific_name_only"),
    PromptVariant("json_list", "json", "scientific_name_only"),
    PromptVariant("semicolon_list", "semicolon", "scientific_name_only"),
    PromptVariant("answer_scientific_name_only", "numbered", "scientific_name_only"),
    PromptVariant("answer_candidate_number_only", "numbered", "candidate_number_only"),
    PromptVariant("answer_json_only", "numbered", "json_only"),
]


def set_seed(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed % (2**32 - 1))
    torch.manual_seed(seed)
    if torch.cuda.is_available():  # pragma: no cover - environment dependent
        torch.cuda.manual_seed_all(seed)


def stable_int_seed(seed: int, *parts: object) -> int:
    payload = "::".join([str(seed), *[str(p) for p in parts]])
    digest = hashlib.sha256(payload.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big", signed=False)


def deterministic_shuffle(items: Sequence[Any], seed: int, *parts: object) -> list[Any]:
    rng = random.Random(stable_int_seed(seed, *parts))
    copied = list(items)
    rng.shuffle(copied)
    return copied


def safe_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False))


def ensure_exists(path: Path, label: str) -> Path:
    if not path.exists():
        raise ExperimentError(
            f"Missing {label}: {path}\n"
            f"Expected repository file not found."
        )
    return path


def candidate_display_name(candidate: dict) -> str:
    return candidate_scientific_name(candidate) or candidate_common_name(candidate) or candidate_genus(candidate) or "Unknown"


def candidate_name_variants(candidate: dict) -> list[str]:
    variants = [
        candidate_scientific_name(candidate),
        candidate_common_name(candidate),
        candidate_genus(candidate),
    ]
    seen = set()
    cleaned = []
    for name in variants:
        name = str(name or "").strip()
        if name and name not in seen:
            cleaned.append(name)
            seen.add(name)
    return cleaned


def candidate_completion_text(candidate: dict, answer_format: str = "scientific_name_only", candidate_position: int | None = None) -> str:
    scientific = candidate_scientific_name(candidate) or candidate_display_name(candidate)
    if answer_format == "candidate_number_only":
        return str(candidate_position or candidate.get("rank") or "")
    if answer_format == "json_only":
        payload = {"answer": scientific}
        return json.dumps(payload, ensure_ascii=False)
    return scientific


def candidate_tokenization(tokenizer: Any, candidate: dict, answer_format: str = "scientific_name_only", candidate_position: int | None = None) -> list[int]:
    return _tokenize_ids(tokenizer, candidate_completion_text(candidate, answer_format, candidate_position))


def answer_instruction(answer_format: str) -> str:
    if answer_format == "candidate_number_only":
        return "the candidate number only"
    if answer_format == "json_only":
        return "JSON only"
    return "the scientific name only"


def render_candidate_list(
    candidates: list[dict],
    list_style: str = "numbered",
    include_confidence: bool = False,
) -> str:
    if list_style == "json":
        payload = {
            "candidates": [
                {
                    "name": candidate_display_name(c),
                    "scientific_name": candidate_scientific_name(c),
                    "common_name": candidate_common_name(c),
                    "rank": idx,
                    **({"confidence": candidate_confidence_value(c)} if include_confidence else {}),
                }
                for idx, c in enumerate(candidates, 1)
            ]
        }
        return json.dumps(payload, ensure_ascii=False)

    lines: list[str] = []
    for idx, cand in enumerate(candidates, 1):
        display = candidate_display_name(cand)
        if list_style == "lettered":
            prefix = f"{chr(64 + idx)}."
        elif list_style in {"bulleted", "bullet"}:
            prefix = "*"
        elif list_style == "distance_equalized":
            prefix = f"{idx:02d}."
        elif list_style == "plain_sentences":
            prefix = "Candidate"
        else:
            prefix = f"{idx}."
        if list_style == "plain_sentences":
            item = f"{prefix} {idx}: {display}."
        else:
            item = f"{prefix} {display}"
        if list_style == "semicolon":
            item = display
        if include_confidence:
            item = f"{item} (confidence {int(round(candidate_confidence_value(cand)))})"
        lines.append(item)

    if list_style == "semicolon":
        return "; ".join(lines)
    return "\n".join(lines)


def make_candidate_prompt(
    candidates: list[dict],
    instruction: str = "",
    list_style: str = "numbered",
    answer_format: str = "scientific_name_only",
    include_confidence: bool = False,
) -> str:
    header = instruction.strip() or "You are evaluating candidate likelihood in species identification."
    list_text = render_candidate_list(candidates, list_style=list_style, include_confidence=include_confidence)
    return (
        f"{header}\n\n"
        "Task:\n"
        "- Read the candidate list carefully.\n"
        "- Choose the single best species.\n"
        f"- Return {answer_instruction(answer_format)}.\n\n"
        f"Candidates:\n{list_text}\n\n"
        "Answer:\n"
    )


def build_prompt_variant_prompt(candidates: list[dict], variant: PromptVariant, instruction: str = "") -> str:
    return make_candidate_prompt(
        candidates,
        instruction=instruction,
        list_style=variant.list_style,
        answer_format=variant.answer_format,
        include_confidence=variant.include_confidence,
    )


def prompt_variant_name(variant: PromptVariant) -> str:
    return variant.name


def parse_prompt_variant(name: str) -> PromptVariant:
    for variant in PROMPT_VARIANTS:
        if variant.name == name:
            return variant
    raise ExperimentError(f"Unknown prompt variant: {name}")


def move_candidate(candidates: list[dict], source_rank: int, target_position: int) -> list[dict]:
    if source_rank < 1 or source_rank > len(candidates):
        raise ExperimentError(f"source_rank {source_rank} is out of range for {len(candidates)} candidates")
    if target_position < 1 or target_position > len(candidates):
        raise ExperimentError(f"target_position {target_position} is out of range for {len(candidates)} candidates")
    copied = [dict(c) for c in candidates]
    picked = copied.pop(source_rank - 1)
    copied.insert(target_position - 1, picked)
    return copied


def _tokenize_ids(tokenizer: Any, text: str) -> list[int]:
    encoded = tokenizer(text, return_tensors=None, add_special_tokens=False)
    if isinstance(encoded, dict):
        ids = encoded.get("input_ids")
        if isinstance(ids, list) and ids and isinstance(ids[0], list):
            return list(ids[0])
        if isinstance(ids, list):
            return list(ids)
    if hasattr(encoded, "input_ids"):
        ids = encoded.input_ids
        if isinstance(ids, list) and ids and isinstance(ids[0], list):
            return list(ids[0])
        if isinstance(ids, list):
            return list(ids)
    raise ExperimentError("Tokenizer did not return input ids")


def find_subsequence(haystack: Sequence[int], needle: Sequence[int]) -> tuple[int, int] | None:
    if not needle or len(needle) > len(haystack):
        return None
    for start in range(0, len(haystack) - len(needle) + 1):
        if list(haystack[start : start + len(needle)]) == list(needle):
            return start, start + len(needle)
    return None


def locate_text_span(tokenizer: Any, text: str, target: str) -> tuple[int, int] | None:
    candidates = [target, f" {target}", f"\n{target}", f"\n {target}"]
    haystack = _tokenize_ids(tokenizer, text)
    for variant in candidates:
        if not variant.strip():
            continue
        needle = _tokenize_ids(tokenizer, variant)
        span = find_subsequence(haystack, needle)
        if span is not None:
            return span
    return None


def locate_candidate_name_spans(tokenizer: Any, prompt: str, candidates: list[dict]) -> dict[str, tuple[int, int] | None]:
    spans: dict[str, tuple[int, int] | None] = {}
    for cand in candidates:
        name = candidate_scientific_name(cand) or candidate_display_name(cand)
        spans[name] = locate_text_span(tokenizer, prompt, name)
    return spans


def locate_answer_position_span(tokenizer: Any, prompt: str) -> tuple[int, int] | None:
    ids = _tokenize_ids(tokenizer, prompt)
    if not ids:
        return None
    return max(len(ids) - 1, 0), len(ids)


def encode_text(tokenizer: Any, text: str) -> dict[str, torch.Tensor]:
    inputs = tokenizer(text, return_tensors="pt", add_special_tokens=False)
    if not hasattr(inputs, "items"):
        raise ExperimentError("Tokenizer did not return a mapping of tensors")
    return {k: v for k, v in inputs.items() if torch.is_tensor(v)}


def encode_text_batch(tokenizer: Any, texts: Sequence[str]) -> dict[str, torch.Tensor]:
    inputs = tokenizer(list(texts), return_tensors="pt", padding=True, add_special_tokens=False)
    if not hasattr(inputs, "items"):
        raise ExperimentError("Tokenizer did not return a mapping of tensors")
    return {k: v for k, v in inputs.items() if torch.is_tensor(v)}


def sequence_lengths(input_ids: torch.Tensor, attention_mask: torch.Tensor | None, pad_token_id: int | None) -> list[int]:
    if attention_mask is not None:
        return [int(v) for v in attention_mask.sum(dim=1).detach().cpu().tolist()]
    if pad_token_id is None:
        return [int(input_ids.shape[1])] * int(input_ids.shape[0])
    return [int(v) for v in (input_ids != pad_token_id).sum(dim=1).detach().cpu().tolist()]


def _build_scoring_tensors(
    tokenizer: Any,
    prompt: str,
    completion: str,
) -> tuple[torch.Tensor, torch.Tensor, int]:
    prompt_ids = _tokenize_ids(tokenizer, prompt)
    completion_ids = _tokenize_ids(tokenizer, completion)
    if not completion_ids:
        raise ExperimentError("Completion did not add any tokens")
    full_ids = prompt_ids + completion_ids
    if len(full_ids) <= len(prompt_ids):
        raise ExperimentError("Full prompt did not add any completion tokens")
    input_ids = torch.tensor([full_ids], dtype=torch.long)
    attention_mask = torch.ones_like(input_ids)
    return input_ids, attention_mask, len(prompt_ids)


def _build_scoring_tensors_batch(
    tokenizer: Any,
    prompt_completion_pairs: Sequence[tuple[str, str]],
) -> tuple[torch.Tensor, torch.Tensor, list[int]]:
    rows: list[list[int]] = []
    prompt_lengths: list[int] = []
    for prompt, completion in prompt_completion_pairs:
        prompt_ids = _tokenize_ids(tokenizer, prompt)
        completion_ids = _tokenize_ids(tokenizer, completion)
        if not completion_ids:
            raise ExperimentError("Completion did not add any tokens")
        row_ids = prompt_ids + completion_ids
        if len(row_ids) <= len(prompt_ids):
            raise ExperimentError("Full prompt did not add any completion tokens")
        rows.append(row_ids)
        prompt_lengths.append(len(prompt_ids))

    pad_token_id = getattr(tokenizer, "pad_token_id", None)
    if pad_token_id is None:
        pad_token_id = 0
    max_len = max(len(row) for row in rows)
    input_ids = torch.full((len(rows), max_len), int(pad_token_id), dtype=torch.long)
    attention_mask = torch.zeros((len(rows), max_len), dtype=torch.long)
    for row_index, row_ids in enumerate(rows):
        row_len = len(row_ids)
        input_ids[row_index, :row_len] = torch.tensor(row_ids, dtype=torch.long)
        attention_mask[row_index, :row_len] = 1
    return input_ids, attention_mask, prompt_lengths


def build_scoring_tensors(
    tokenizer: Any,
    prompt: str,
    completion: str,
) -> tuple[torch.Tensor, torch.Tensor, int]:
    return _build_scoring_tensors(tokenizer, prompt, completion)


def build_scoring_tensors_batch(
    tokenizer: Any,
    prompt_completion_pairs: Sequence[tuple[str, str]],
) -> tuple[torch.Tensor, torch.Tensor, list[int]]:
    return _build_scoring_tensors_batch(tokenizer, prompt_completion_pairs)


def choose_torch_dtype(dtype: str, device: str) -> torch.dtype:
    normalized = str(dtype or "auto").lower()
    if normalized in {"auto", ""}:
        if device.startswith("cuda") or device == "mps":
            return torch.bfloat16 if device.startswith("cuda") else torch.float16
        return torch.float32
    mapping = {
        "bf16": torch.bfloat16,
        "bfloat16": torch.bfloat16,
        "fp16": torch.float16,
        "float16": torch.float16,
        "half": torch.float16,
        "fp32": torch.float32,
        "float32": torch.float32,
    }
    if normalized not in mapping:
        raise ExperimentError(f"Unknown dtype {dtype!r}; use auto, bf16, fp16, or fp32.")
    return mapping[normalized]


def choose_device(device: str) -> str:
    normalized = str(device or "auto").lower()
    if normalized == "auto":
        if torch.cuda.is_available():  # pragma: no cover - environment dependent
            return "cuda"
        if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():  # pragma: no cover
            return "mps"
        return "cpu"
    return normalized


def _model_load_error(model_id: str, device: str, dtype: torch.dtype, original: Exception) -> ExperimentError:
    try:
        import transformers

        transformers_version = transformers.__version__
    except Exception:  # pragma: no cover - environment dependent
        transformers_version = "unknown"
    return ExperimentError(
        f"Failed to load Hugging Face model {model_id!r} with device={device!r} and dtype={dtype}.\n"
        f"Transformers version: {transformers_version}\n"
        f"This may mean the model is gated and needs authentication, the transformers version is too old,\n"
        f"or the model id should be changed with --model-id.\n"
        f"Original error: {original}"
    )


def _load_tokenizer(model_id: str) -> Any:
    try:
        from transformers import AutoProcessor, AutoTokenizer

        try:
            processor = AutoProcessor.from_pretrained(model_id)
            tokenizer = getattr(processor, "tokenizer", None)
            if tokenizer is not None:
                if getattr(tokenizer, "pad_token_id", None) is None and getattr(tokenizer, "eos_token", None) is not None:
                    tokenizer.pad_token = tokenizer.eos_token
                return tokenizer, processor
        except Exception:
            processor = None
        tokenizer = AutoTokenizer.from_pretrained(model_id)
        if getattr(tokenizer, "pad_token_id", None) is None and getattr(tokenizer, "eos_token", None) is not None:
            tokenizer.pad_token = tokenizer.eos_token
        return tokenizer, processor
    except Exception as exc:  # pragma: no cover - environment dependent
        raise _model_load_error(model_id, "unknown", torch.float32, exc) from exc


def _load_model_class(model_id: str, torch_dtype: torch.dtype, device_map: str | None) -> Any:
    model_errors: list[Exception] = []
    class_candidates = [
        "AutoModelForCausalLM",
        "AutoModelForImageTextToText",
        "AutoModelForMultimodalLM",
    ]
    for class_name in class_candidates:
        try:
            module = __import__("transformers", fromlist=[class_name])
            model_class = getattr(module, class_name)
        except Exception as exc:  # pragma: no cover - environment dependent
            model_errors.append(exc)
            continue
        try:
            kwargs: dict[str, Any] = {
                "torch_dtype": torch_dtype,
                "trust_remote_code": False,
            }
            if device_map is not None:
                kwargs["device_map"] = device_map
            model = model_class.from_pretrained(model_id, **kwargs)
            return model
        except Exception as exc:  # pragma: no cover - environment dependent
            model_errors.append(exc)
    raise model_errors[-1] if model_errors else RuntimeError("No model class candidates were available")


def load_hf_bundle(
    model_id: str = DEFAULT_MODEL_ID,
    device: str = "auto",
    dtype: str = "auto",
    device_map: str | None = None,
) -> HFBundle:
    try:
        import transformers  # noqa: F401
    except Exception as exc:  # pragma: no cover - environment dependent
        raise ExperimentError(
            "Transformers is not available in this environment. Install a compatible Hugging Face stack first."
        ) from exc

    normalized_device = choose_device(device)
    torch_dtype = choose_torch_dtype(dtype, normalized_device)
    # Only infer device_map="auto" when auto-selection lands on CUDA.
    # On this stack, using device_map="auto" for CPU fallback leaves meta tensors
    # in Gemma 4 and breaks the first forward pass.
    inferred_device_map = (
        device_map
        if device_map is not None
        else ("auto" if device == "auto" and normalized_device.startswith("cuda") else None)
    )

    tokenizer, processor = _load_tokenizer(model_id)

    try:
        model = _load_model_class(model_id, torch_dtype, inferred_device_map)
        if inferred_device_map is None:
            model.to(normalized_device)
        model.eval()
    except Exception as exc:  # pragma: no cover - environment dependent
        raise _model_load_error(model_id, normalized_device, torch_dtype, exc) from exc

    return HFBundle(
        model=model,
        tokenizer=tokenizer,
        processor=processor,
        device=normalized_device,
        dtype=torch_dtype,
        device_map=inferred_device_map,
    )


def _model_device(bundle: HFBundle) -> torch.device:
    try:
        return next((p.device for p in bundle.model.parameters() if p is not None), torch.device(bundle.device))
    except Exception:
        return torch.device(bundle.device)


def _run_model(bundle: HFBundle, input_ids: torch.Tensor, attention_mask: torch.Tensor | None = None, output_hidden_states: bool = False):
    model_inputs = {"input_ids": input_ids.to(_model_device(bundle))}
    if attention_mask is not None:
        model_inputs["attention_mask"] = attention_mask.to(_model_device(bundle))
    with torch.no_grad():
        outputs = bundle.model(
            **model_inputs,
            output_hidden_states=output_hidden_states,
            return_dict=True,
        )
    return outputs


def run_model(
    bundle: HFBundle,
    input_ids: torch.Tensor,
    attention_mask: torch.Tensor | None = None,
    output_hidden_states: bool = False,
):
    return _run_model(bundle, input_ids, attention_mask=attention_mask, output_hidden_states=output_hidden_states)


def _score_completion_tensors(
    bundle: HFBundle,
    full_input_ids: torch.Tensor,
    prompt_lengths: Sequence[int],
    attention_mask: torch.Tensor | None = None,
) -> list[dict[str, Any]]:
    outputs = _run_model(bundle, full_input_ids, attention_mask=attention_mask, output_hidden_states=False)
    logits = outputs.logits
    model_device = _model_device(bundle)
    full_lengths = sequence_lengths(
        full_input_ids.detach().cpu(),
        attention_mask.detach().cpu() if attention_mask is not None else None,
        getattr(bundle.tokenizer, "pad_token_id", None),
    )
    results: list[dict[str, Any]] = []

    for row_index, (prompt_len, full_len) in enumerate(zip(prompt_lengths, full_lengths)):
        shifted_logits = logits[row_index : row_index + 1, prompt_len - 1 : full_len - 1, :]
        target_ids = full_input_ids[row_index : row_index + 1, prompt_len:full_len].to(model_device)
        log_probs = torch.log_softmax(shifted_logits.float(), dim=-1)
        token_log_probs = log_probs.gather(-1, target_ids.unsqueeze(-1)).squeeze(-1)
        token_scores = token_log_probs[0].detach().cpu().tolist()
        total_score = float(sum(token_scores))
        token_count = len(token_scores)
        mean_score = total_score / token_count if token_count else total_score
        next_token_lp = float(token_scores[0]) if token_scores else total_score
        results.append(
            {
                "candidate_answer_logprob": total_score,
                "candidate_answer_avg_logprob": mean_score,
                "next_token_logprob_for_candidate_start": next_token_lp,
                "full_candidate_sequence_logprob": total_score,
                "token_count": token_count,
                "token_scores": token_scores,
                "total_logprob": total_score,
                "mean_token_logprob": mean_score,
            }
        )

    return results


def next_token_logprob(bundle: HFBundle, prompt: str, completion: str) -> float:
    scores = score_completion(bundle, prompt, completion)
    token_scores = scores["token_scores"]
    return float(token_scores[0]) if token_scores else float(scores["candidate_answer_logprob"])


def score_completion(bundle: HFBundle, prompt: str, completion: str) -> dict[str, Any]:
    full_input_ids, attention_mask, prompt_len = _build_scoring_tensors(bundle.tokenizer, prompt, completion)
    return _score_completion_tensors(bundle, full_input_ids, [prompt_len], attention_mask=attention_mask)[0]


def score_completions(bundle: HFBundle, prompt_completion_pairs: Sequence[tuple[str, str]]) -> list[dict[str, Any]]:
    if not prompt_completion_pairs:
        return []
    full_input_ids, attention_mask, prompt_lengths = _build_scoring_tensors_batch(bundle.tokenizer, prompt_completion_pairs)
    return _score_completion_tensors(bundle, full_input_ids, prompt_lengths, attention_mask=attention_mask)


def full_sequence_logprob(bundle: HFBundle, prompt: str, completion: str) -> float:
    return float(score_completion(bundle, prompt, completion)["full_candidate_sequence_logprob"])


def extract_hidden_states(bundle: HFBundle, prompt: str, layer_indices: Sequence[int] | None = None) -> Any:
    inputs = encode_text(bundle.tokenizer, prompt)
    input_ids = inputs.get("input_ids")
    if input_ids is None:
        raise ExperimentError("Tokenizer inputs are missing input_ids")
    outputs = _run_model(bundle, input_ids, attention_mask=inputs.get("attention_mask"), output_hidden_states=True)
    return outputs.hidden_states


def model_device(bundle: HFBundle) -> torch.device:
    return _model_device(bundle)


def hidden_state_tensor(hidden_states: Any, layer_index: int) -> torch.Tensor:
    if hidden_states is None:
        raise ExperimentError("Model did not return hidden states")
    if isinstance(hidden_states, dict):
        if layer_index in hidden_states:
            return hidden_states[layer_index]
        raise ExperimentError(f"Requested hidden state index {layer_index} was not captured")
    if not isinstance(hidden_states, (list, tuple)):
        raise ExperimentError("Hidden states are not a sequence")
    if layer_index < 0:
        layer_index = len(hidden_states) + layer_index
    if layer_index < 0 or layer_index >= len(hidden_states):
        raise ExperimentError(f"layer_index {layer_index} is out of bounds for {len(hidden_states)} hidden state tensors")
    return hidden_states[layer_index]


def pool_hidden_state(hidden_tensor: torch.Tensor, span: tuple[int, int] | None, mode: str = "mean") -> torch.Tensor:
    if hidden_tensor.dim() == 2:
        hidden_tensor = hidden_tensor.unsqueeze(0)
    if span is None:
        return hidden_tensor.mean(dim=1).squeeze(0)
    start, end = span
    if end <= start:
        return hidden_tensor[:, start, :].squeeze(0)
    region = hidden_tensor[:, start:end, :]
    if mode == "last":
        return region[:, -1, :].squeeze(0)
    return region.mean(dim=1).squeeze(0)


def locate_transformer_block_names(model: Any) -> list[str]:
    names: list[str] = []
    pattern = re.compile(r"(?:^|\.)((?:layers|h|blocks|decoder\.layers|encoder\.layers))\.(\d+)$")
    for name, module in model.named_modules():
        match = pattern.search(name)
        if match:
            names.append(name)
    names = sorted(set(names), key=lambda item: [int(x) if x.isdigit() else x for x in re.split(r"(\d+)", item)])
    return names


def rank_positions(rows: list[dict]) -> list[int]:
    positions = sorted({int(row["candidate_position"]) for row in rows})
    return positions


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
