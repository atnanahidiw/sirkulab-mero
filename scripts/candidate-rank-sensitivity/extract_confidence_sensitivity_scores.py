#!/usr/bin/env python3
"""Collect score-rich trials for confidence-sensitivity analysis."""
from __future__ import annotations

import argparse
import importlib
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from _common import (
    candidate_common_name,
    candidate_scientific_name,
    format_candidates_for_prompt,
    load_jsonl,
    write_jsonl,
)


class ScoreBackend(Protocol):
    def score_trial(self, example: dict[str, Any], trial_index: int) -> dict[str, Any]:
        ...


@dataclass
class PluginBackend:
    impl: Any

    def score_trial(self, example: dict[str, Any], trial_index: int) -> dict[str, Any]:
        return self.impl.score_trial(example, trial_index)


@dataclass
class JsonlBackend:
    score_map: dict[tuple[str, int], dict[str, Any]]

    def score_trial(self, example: dict[str, Any], trial_index: int) -> dict[str, Any]:
        key = (str(example.get("example_id")), trial_index)
        if key not in self.score_map:
            raise KeyError(f"Missing score row for {key[0]} trial {key[1]}")
        return self.score_map[key]


def softmax(values: list[float]) -> list[float]:
    if not values:
        return []
    peak = max(values)
    exps = [math.exp(v - peak) for v in values]
    denom = sum(exps)
    return [v / denom for v in exps] if denom else [0.0 for _ in values]


def normalize(text: Any) -> str:
    return " ".join(str(text or "").lower().replace("_", " ").split())


def candidate_label(candidate: dict[str, Any]) -> str:
    return candidate_scientific_name(candidate) or candidate_common_name(candidate) or str(candidate.get("label") or candidate.get("name") or "").strip()


def option_id(candidate: dict[str, Any], idx: int) -> str:
    raw = candidate.get("option_id") or candidate.get("option") or candidate.get("letter") or candidate.get("id")
    if raw is not None and str(raw).strip():
        return str(raw).strip()
    return chr(ord("A") + idx) if idx < 26 else str(idx + 1)


def infer_selected_rank(example: dict[str, Any], candidates: list[dict[str, Any]], logits: list[float], final_answer: str | None) -> int | None:
    if isinstance(example.get("selected_candidate_rank"), int):
        return int(example["selected_candidate_rank"])
    if isinstance(example.get("selected_option_id"), str):
        want = normalize(example["selected_option_id"])
        for i, cand in enumerate(candidates, 1):
            if normalize(option_id(cand, i - 1)) == want:
                return i
    if final_answer:
        want = normalize(final_answer)
        for i, cand in enumerate(candidates, 1):
            if normalize(candidate_label(cand)) == want:
                return i
    return (max(range(len(logits)), key=lambda i: logits[i]) + 1) if logits else None


def extract_logits(row: dict[str, Any], candidate_count: int) -> list[float]:
    logits = row.get("candidate_logits") or row.get("logits") or row.get("candidate_scores")
    if logits is None and isinstance(row.get("option_logits"), dict):
        opt = row["option_logits"]
        logits = [float(opt.get(chr(ord("A") + i), opt.get(chr(ord("a") + i), 0.0))) for i in range(candidate_count)]
    if logits is None:
        raise ValueError("Backend response missing candidate logits/scores")
    logits = [float(x) for x in logits]
    if len(logits) != candidate_count:
        raise ValueError(f"Expected {candidate_count} logits, got {len(logits)}")
    return logits


def build_prompt(example: dict[str, Any]) -> str:
    if isinstance(example.get("prompt"), str) and example["prompt"].strip():
        return example["prompt"]
    candidates = example.get("candidate_order") or example.get("original_candidates") or example.get("candidates") or []
    base = example.get("question") or example.get("instruction") or "Choose the single best species from the candidate list."
    return f"{base}\n\nCandidates:\n{format_candidates_for_prompt(candidates)}\n"


def derive_row(example: dict[str, Any], trial_index: int, backend_row: dict[str, Any]) -> dict[str, Any]:
    candidates = backend_row.get("candidate_order") or example.get("candidate_order") or example.get("original_candidates") or example.get("candidates") or []
    logits = extract_logits(backend_row, len(candidates))
    probs = backend_row.get("candidate_probabilities")
    if not isinstance(probs, list) or len(probs) != len(logits):
        probs = softmax(logits)
    final_answer = backend_row.get("final_answer")
    selected_rank = backend_row.get("selected_candidate_rank") or infer_selected_rank(example, candidates, logits, final_answer)
    selected_option = backend_row.get("selected_option_id")
    if selected_option is None and isinstance(selected_rank, int) and 1 <= selected_rank <= len(candidates):
        selected_option = option_id(candidates[selected_rank - 1], selected_rank - 1)
    selected_label = backend_row.get("selected_candidate_label")
    if selected_label is None and isinstance(selected_rank, int) and 1 <= selected_rank <= len(candidates):
        selected_label = candidate_label(candidates[selected_rank - 1])
    option_logits = backend_row.get("option_logits")
    if not isinstance(option_logits, dict):
        option_logits = {option_id(c, i): logits[i] for i, c in enumerate(candidates)}
    return {
        **example,
        "trial_index": trial_index,
        "order_type": backend_row.get("order_type") or ("original" if trial_index == 0 else "shuffled"),
        "prompt": backend_row.get("prompt") or build_prompt(example),
        "candidate_order": candidates,
        "candidate_logits": logits,
        "candidate_probabilities": probs,
        "option_logits": option_logits,
        "raw_response": backend_row.get("raw_response"),
        "final_answer": final_answer,
        "selected_candidate_rank": selected_rank,
        "selected_option_id": selected_option,
        "selected_candidate_label": selected_label,
        "model_metadata": backend_row.get("model_metadata") or {},
    }


def load_backend(args: argparse.Namespace) -> ScoreBackend:
    if args.backend == "plugin":
        if not args.backend_module or not args.backend_class:
            raise SystemExit("--backend plugin requires --backend-module and --backend-class")
        module = importlib.import_module(args.backend_module)
        cls = getattr(module, args.backend_class)
        return PluginBackend(cls(model_path=args.model_path, data_repo=args.data_repo, device=args.device))
    if args.backend == "jsonl":
        if not args.backend_scores:
            raise SystemExit("--backend jsonl requires --backend-scores")
        score_rows = load_jsonl(Path(args.backend_scores))
        score_map = {(str(r.get("example_id")), int(r.get("trial_index", 0))): r for r in score_rows}
        return JsonlBackend(score_map)
    raise SystemExit(f"Unsupported backend: {args.backend}")


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--examples", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--trials", type=int, default=1)
    p.add_argument("--backend", choices=["plugin", "jsonl"], default="plugin")
    p.add_argument("--backend-module", default="")
    p.add_argument("--backend-class", default="")
    p.add_argument("--backend-scores", default="")
    p.add_argument("--model-path", default="")
    p.add_argument("--data-repo", default="")
    p.add_argument("--device", default="cpu")
    p.add_argument("--resume", action="store_true")
    return p.parse_args()


def load_existing_keys(path: Path) -> set[tuple[str, int]]:
    if not path.exists():
        return set()
    keys: set[tuple[str, int]] = set()
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if line:
                row = json.loads(line)
                keys.add((str(row.get("example_id")), int(row.get("trial_index", 0))))
    return keys


def main() -> int:
    args = parse_args()
    examples = load_jsonl(Path(args.examples))
    backend = load_backend(args)
    out_path = Path(args.output)
    existing = load_existing_keys(out_path) if args.resume else set()
    rows: list[dict[str, Any]] = []
    skipped = 0
    for example in examples:
        example_id = str(example.get("example_id"))
        for trial_index in range(args.trials):
            key = (example_id, trial_index)
            if key in existing:
                skipped += 1
                continue
            backend_row = backend.score_trial(example, trial_index)
            rows.append(derive_row(example, trial_index, backend_row))
    if rows:
        if args.resume and out_path.exists():
            with out_path.open("a") as fh:
                for row in rows:
                    fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        else:
            write_jsonl(out_path, rows)
    print(json.dumps({"examples": len(examples), "trials_per_example": args.trials, "written_rows": len(rows), "skipped_rows": skipped, "output": str(out_path)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
