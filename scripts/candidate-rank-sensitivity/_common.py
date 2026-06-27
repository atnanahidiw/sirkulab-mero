#!/usr/bin/env python3
"""Shared helpers for the candidate-rank-sensitivity experiment package."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import re
from pathlib import Path
from typing import Iterable

HERE = Path(__file__).resolve()
REPO_ROOT = next(p for p in HERE.parents if (p / "assets" / "data" / "species_data.sqlite").exists())
BASELINE_SCRIPT = REPO_ROOT / "scripts" / "gemma-improve-detection" / "eval_gemma4_baseline.py"
BASELINE_OUTPUT = REPO_ROOT / "scripts" / "gemma-improve-detection" / "outputs" / "gemma4_baseline.jsonl"
DB_PATH = REPO_ROOT / "assets" / "data" / "species_data.sqlite"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "outputs" / "candidate-rank-sensitivity"

SYNONYMS = {
    "stripes": "striped",
    "striping": "striped",
    "stripy": "striped",
    "golden": "yellow",
    "bluish": "blue",
    "reddish": "red",
    "greenish": "green",
    "brownish": "brown",
    "whitish": "white",
    "blackish": "black",
    "greyish": "grey",
    "grayish": "grey",
    "yellowish": "yellow",
    "orangish": "orange",
    "purplish": "purple",
    "pinkish": "pink",
    "spotted": "spot",
    "spotty": "spot",
}
STOPWORDS = {"and", "with", "the", "appears", "somewhat", "but", "on", "of", "in"}


class ExperimentError(RuntimeError):
    """Raised for user-facing experiment configuration errors."""


def ensure_exists(path: Path, label: str) -> Path:
    if not path.exists():
        raise ExperimentError(
            f"Missing {label}: {path}\n"
            f"Expected repository file not found."
        )
    return path


def load_baseline_module():
    ensure_exists(BASELINE_SCRIPT, "baseline script")
    spec = importlib.util.spec_from_file_location("gemma4_baseline_reference", BASELINE_SCRIPT)
    if spec is None or spec.loader is None:
        raise ExperimentError(f"Could not import baseline module from {BASELINE_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_candidate_ranking_module():
    return load_baseline_module()


def load_jsonl(path: Path) -> list[dict]:
    ensure_exists(path, "JSONL file")
    rows: list[dict] = []
    with path.open() as fh:
        for line_no, line in enumerate(fh, 1):
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError as exc:
                raise ExperimentError(f"Failed to parse JSONL line {line_no} in {path}: {exc}") from exc
    return rows


def write_jsonl(path: Path, rows: Iterable[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def stable_int_seed(seed: int, *parts: object) -> int:
    payload = "::".join([str(seed), *[str(p) for p in parts]])
    digest = hashlib.sha256(payload.encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big", signed=False)


def normalize_text(text: object) -> str:
    return re.sub(r"[^a-z0-9 ]", " ", str(text or "").lower()).strip()


def candidate_scientific_name(candidate: dict) -> str:
    return str(candidate.get("scientific_name") or candidate.get("latin") or "").strip()


def candidate_common_name(candidate: dict) -> str:
    return str(candidate.get("common_name") or candidate.get("common") or "").strip()


def candidate_genus(candidate: dict) -> str:
    return str(candidate.get("genus") or "").strip()


def candidate_confidence_value(candidate: dict) -> float:
    raw = candidate.get("confidence", candidate.get("score", 0))
    try:
        return float(raw)
    except Exception:
        return 0.0


def strip_confidence(candidate: dict) -> dict:
    return {k: v for k, v in candidate.items() if k not in {"confidence", "score"}}


def format_candidates_for_prompt(candidates: list[dict]) -> str:
    lines = []
    for idx, cand in enumerate(candidates, 1):
        common = candidate_common_name(cand)
        scientific = candidate_scientific_name(cand)
        genus = candidate_genus(cand)
        parts = [f"{idx}. {common or scientific or genus or 'Unknown'}"]
        if scientific and scientific != common:
            parts.append(f"[{scientific}]")
        elif genus and genus not in {common, scientific}:
            parts.append(f"[{genus}]")
        lines.append(" ".join(parts).strip())
    return "\n".join(lines)


def format_candidates_with_confidence(candidates: list[dict]) -> str:
    lines = []
    for idx, cand in enumerate(candidates, 1):
        common = candidate_common_name(cand)
        scientific = candidate_scientific_name(cand)
        genus = candidate_genus(cand)
        confidence = candidate_confidence_value(cand)
        parts = [f"{idx}. {common or scientific or genus or 'Unknown'}"]
        if scientific and scientific != common:
            parts.append(f"[{scientific}]")
        elif genus and genus not in {common, scientific}:
            parts.append(f"[{genus}]")
        parts.append(f"confidence {int(round(confidence))}")
        lines.append(" ".join(parts).strip())
    return "\n".join(lines)


def parse_response_json(text: str) -> dict | None:
    raw = str(text or "").strip()
    if "```" in raw:
        if "```json" in raw:
            raw = raw.split("```json")[-1].split("```", 1)[0]
        else:
            raw = raw.split("```", 1)[-1].split("```", 1)[0]
    match = re.search(r"\{.*\}", raw, re.DOTALL)
    try:
        return json.loads(match.group(0) if match else raw)
    except Exception:
        return None


def canonical_answer_from_text(text: str) -> str:
    parsed = parse_response_json(text)
    if isinstance(parsed, dict):
        for key in ("scientific_name", "common_name", "genus", "answer"):
            value = parsed.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return str(text or "").strip()


def match_candidate_rank(answer_text: str, candidates: list[dict]) -> int | None:
    parsed = parse_response_json(answer_text)
    if isinstance(parsed, dict):
        rank = parsed.get("selected_candidate_rank") or parsed.get("rank")
        if isinstance(rank, int) and 1 <= rank <= len(candidates):
            return rank
        if isinstance(rank, str) and rank.isdigit():
            rank_i = int(rank)
            if 1 <= rank_i <= len(candidates):
                return rank_i
        answer_name = parsed.get("scientific_name") or parsed.get("common_name") or parsed.get("answer")
        if isinstance(answer_name, str) and answer_name.strip():
            answer_text = answer_name
    normalized = normalize_text(answer_text)
    for idx, cand in enumerate(candidates, 1):
        names = [candidate_scientific_name(cand), candidate_common_name(cand), candidate_genus(cand)]
        if any(normalize_text(name) and normalize_text(name) in normalized for name in names):
            return idx
    return None


def same_answer(a: str, b: str) -> bool:
    return normalize_text(canonical_answer_from_text(a)) == normalize_text(canonical_answer_from_text(b))
