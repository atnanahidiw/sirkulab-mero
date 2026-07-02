#!/usr/bin/env python3
"""Probe whether candidate position is linearly decodable from hidden states."""
from __future__ import annotations

import argparse
import csv
import gc
import json
import random
from collections import defaultdict
from pathlib import Path
from typing import Any

import numpy as np
import torch

from common_hf import (
    DEFAULT_EXAMPLES,
    DEFAULT_MODEL_ID,
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    PromptVariant,
    build_prompt_variant_prompt,
    candidate_display_name,
    candidate_scientific_name,
    deterministic_shuffle,
    load_hf_bundle,
    load_jsonl,
    locate_answer_position_span,
    locate_text_span,
    make_candidate_prompt,
    move_candidate,
    safe_write_json,
    set_seed,
    strip_confidence,
)

DEFAULT_OUTPUT = DEFAULT_OUTPUT_DIR / "probe_candidate_position.jsonl"
DEFAULT_FEATURES = DEFAULT_OUTPUT_DIR / "probe_candidate_position_features.jsonl"
DEFAULT_SUMMARY = DEFAULT_OUTPUT_DIR / "probe_candidate_position_summary.json"
DEFAULT_TABLE = DEFAULT_OUTPUT_DIR / "probe_candidate_position_scores.csv"
DEFAULT_DATASET = DEFAULT_OUTPUT_DIR / "probe_candidate_position_dataset.jsonl"
DEFAULT_POSITIONS = (1, 3, 5)
DEFAULT_FEATURE_LOCATIONS = (
    "candidate_span_mean",
    "candidate_span_last",
    "answer_position_token",
    "answer_marker_span_mean",
)
GC_EVERY_EXAMPLES = 10

BASELINE_PROMPTS = {
    "with_rank_markers": PromptVariant("with_rank_markers", "numbered", "scientific_name_only"),
    "without_rank_markers": PromptVariant("without_rank_markers", "semicolon", "scientific_name_only"),
}


def parse_csv_values(value: str) -> list[str]:
    items = [item.strip() for item in str(value or "").split(",") if item.strip()]
    if not items:
        raise ExperimentError("At least one value is required")
    return items


def parse_positions(value: str) -> list[int]:
    positions = sorted({int(item) for item in parse_csv_values(value)})
    if not positions:
        raise ExperimentError("At least one target position is required")
    return positions


def parse_feature_locations(value: str) -> list[str]:
    allowed = set(DEFAULT_FEATURE_LOCATIONS)
    locations = parse_csv_values(value)
    for location in locations:
        if location not in allowed:
            raise ExperimentError(
                f"Unknown feature location {location!r}. "
                f"Allowed values: {', '.join(DEFAULT_FEATURE_LOCATIONS)}"
            )
    return locations


def text_hidden_state_count(bundle) -> int:
    try:
        return len(bundle.model.model.language_model.layers) + 1
    except Exception as exc:
        raise ExperimentError("Could not determine Gemma text-layer count from the loaded model") from exc


def label_counts_from_y(y: np.ndarray, labels: list[int]) -> dict[str, int]:
    return {str(label): int(np.sum(y == idx)) for idx, label in enumerate(labels)}


def select_hidden_state_indices(selection: str, total_layers: int) -> list[int]:
    normalized = str(selection or "all").strip().lower()
    if normalized in {"", "all"}:
        return list(range(total_layers))

    indices: list[int] = []
    seen: set[int] = set()
    for token in parse_csv_values(selection):
        token_lc = token.lower()
        if token_lc == "first":
            idx = 0
        elif token_lc == "last":
            idx = total_layers - 1
        elif token_lc == "middle":
            idx = total_layers // 2
        else:
            try:
                idx = int(token)
            except ValueError as exc:
                raise ExperimentError(
                    f"Unknown layer selector {token!r}. Use all, last, middle, or comma-separated indices."
                ) from exc
            if idx < 0:
                idx = total_layers + idx
        if idx < 0 or idx >= total_layers:
            raise ExperimentError(f"Layer index {idx} is out of range for {total_layers} hidden states")
        if idx not in seen:
            indices.append(idx)
            seen.add(idx)
    return indices


def append_jsonl(path: Path, rows: list[dict]) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = "a" if path.exists() else "w"
    with path.open(mode, encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def maybe_release_memory(example_index: int, gc_every_examples: int = GC_EVERY_EXAMPLES) -> None:
    if gc_every_examples <= 0 or example_index % gc_every_examples != 0:
        return
    gc.collect()
    if getattr(torch.backends, "mps", None) is not None and torch.backends.mps.is_available():  # pragma: no cover
        torch.mps.empty_cache()


def load_existing_feature_keys(path: Path) -> set[tuple[str, str, str, int, int, int, str]]:
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
                    str(row.get("condition")),
                    str(row.get("candidate_name")),
                    int(row.get("source_rank", 0)),
                    int(row.get("candidate_position", 0)),
                    int(row.get("layer_index", 0)),
                    str(row.get("feature_location")),
                )
            )
    return keys


def _flatten_feature(hidden: torch.Tensor, span: tuple[int, int] | None, mode: str) -> np.ndarray:
    from common_hf import pool_hidden_state

    vec = pool_hidden_state(hidden, span, mode=mode)
    if isinstance(vec, torch.Tensor):
        vec = vec.detach().cpu().numpy()
    return np.asarray(vec, dtype=np.float32)


def standardize_fit(X: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    mean = X.mean(axis=0)
    std = X.std(axis=0)
    std[std == 0] = 1.0
    return mean, std


def standardize_apply(X: np.ndarray, mean: np.ndarray, std: np.ndarray) -> np.ndarray:
    return (X - mean) / std


class LinearProbe:
    def __init__(self, num_features: int, num_classes: int, seed: int):
        torch.manual_seed(seed)
        self.model = torch.nn.Linear(num_features, num_classes)

    def fit(self, X: np.ndarray, y: np.ndarray, epochs: int = 300, lr: float = 0.05) -> None:
        x = torch.tensor(X, dtype=torch.float32)
        target = torch.tensor(y, dtype=torch.long)
        opt = torch.optim.Adam(self.model.parameters(), lr=lr, weight_decay=1e-4)
        loss_fn = torch.nn.CrossEntropyLoss()
        self.model.train()
        for _ in range(epochs):
            opt.zero_grad()
            logits = self.model(x)
            loss = loss_fn(logits, target)
            loss.backward()
            opt.step()

    def predict(self, X: np.ndarray) -> np.ndarray:
        self.model.eval()
        with torch.no_grad():
            logits = self.model(torch.tensor(X, dtype=torch.float32))
            return logits.argmax(dim=-1).cpu().numpy()


def macro_f1(y_true: np.ndarray, y_pred: np.ndarray, labels: list[int]) -> float:
    scores = []
    for label in labels:
        tp = int(np.sum((y_true == label) & (y_pred == label)))
        fp = int(np.sum((y_true != label) & (y_pred == label)))
        fn = int(np.sum((y_true == label) & (y_pred != label)))
        precision = tp / (tp + fp) if (tp + fp) else 0.0
        recall = tp / (tp + fn) if (tp + fn) else 0.0
        if precision + recall == 0:
            scores.append(0.0)
        else:
            scores.append(2 * precision * recall / (precision + recall))
    return float(sum(scores) / len(scores)) if scores else 0.0


def deterministic_group_split(rows: list[dict], group_key: str, seed: int, test_fraction: float = 0.25) -> tuple[list[dict], list[dict]]:
    groups = sorted({str(row[group_key]) for row in rows})
    shuffled = deterministic_shuffle(groups, seed, group_key)
    if len(shuffled) <= 1:
        return rows, []
    test_count = max(1, int(round(len(shuffled) * test_fraction)))
    test_groups = set(shuffled[:test_count])
    train_rows = [row for row in rows if str(row[group_key]) not in test_groups]
    test_rows = [row for row in rows if str(row[group_key]) in test_groups]
    if not train_rows or not test_rows:
        midpoint = max(1, len(shuffled) // 2)
        test_groups = set(shuffled[:midpoint])
        train_rows = [row for row in rows if str(row[group_key]) not in test_groups]
        test_rows = [row for row in rows if str(row[group_key]) in test_groups]
    return train_rows, test_rows


def build_label_map(rows: list[dict]) -> tuple[list[int], dict[int, int]]:
    labels = sorted({int(row["candidate_position"]) for row in rows})
    return labels, {label: idx for idx, label in enumerate(labels)}


def prepare_xy(rows: list[dict], label_map: dict[int, int]) -> tuple[np.ndarray, np.ndarray]:
    X = np.stack([np.asarray(row["features"], dtype=np.float32) for row in rows])
    y = np.asarray([label_map[int(row["candidate_position"])] for row in rows], dtype=np.int64)
    return X, y


def probe_split(train_rows: list[dict], test_rows: list[dict], labels: list[int], label_map: dict[int, int], seed: int) -> dict[str, Any]:
    if len(train_rows) < 4 or len(test_rows) < 2 or len(labels) < 2:
        return {
            "accuracy": None,
            "macro_f1": None,
            "majority_baseline_accuracy": None,
            "random_label_accuracy": None,
            "accuracy_minus_majority_baseline": None,
            "accuracy_minus_random_label_baseline": None,
            "num_train": len(train_rows),
            "num_test": len(test_rows),
            "train_label_counts": None,
            "test_label_counts": None,
            "status": "insufficient_data",
            "labels": labels,
        }

    X_train, y_train = prepare_xy(train_rows, label_map)
    X_test, y_test = prepare_xy(test_rows, label_map)

    mean, std = standardize_fit(X_train)
    X_train = standardize_apply(X_train, mean, std)
    X_test = standardize_apply(X_test, mean, std)

    num_classes = len(labels)
    probe = LinearProbe(X_train.shape[1], num_classes, seed)
    probe.fit(X_train, y_train)
    preds = probe.predict(X_test)

    rng = np.random.default_rng(seed)
    shuffled_y_train = y_train.copy()
    rng.shuffle(shuffled_y_train)
    random_probe = LinearProbe(X_train.shape[1], num_classes, seed + 1)
    random_probe.fit(X_train, shuffled_y_train)
    random_preds = random_probe.predict(X_test)

    majority_idx = int(np.bincount(y_train, minlength=num_classes).argmax())
    accuracy = float(np.mean(preds == y_test))
    random_accuracy = float(np.mean(random_preds == y_test))
    majority_accuracy = float(np.mean(y_test == majority_idx))
    f1 = macro_f1(y_test, preds, list(range(num_classes)))

    return {
        "accuracy": accuracy,
        "macro_f1": f1,
        "majority_baseline_accuracy": majority_accuracy,
        "random_label_accuracy": random_accuracy,
        "accuracy_minus_majority_baseline": accuracy - majority_accuracy,
        "accuracy_minus_random_label_baseline": accuracy - random_accuracy,
        "num_train": len(train_rows),
        "num_test": len(test_rows),
        "train_label_counts": label_counts_from_y(y_train, labels),
        "test_label_counts": label_counts_from_y(y_test, labels),
        "status": "ok",
        "labels": labels,
    }


def run_probe(rows: list[dict], seed: int, group_key: str | None = None) -> dict[str, Any]:
    if len(rows) < 6:
        return {
            "accuracy": None,
            "macro_f1": None,
            "majority_baseline_accuracy": None,
            "random_label_accuracy": None,
            "accuracy_minus_majority_baseline": None,
            "accuracy_minus_random_label_baseline": None,
            "num_rows": len(rows),
            "status": "insufficient_data",
            "labels": [],
            "train_label_counts": None,
            "test_label_counts": None,
        }

    labels, label_map = build_label_map(rows)
    if len(labels) < 2:
        return {
            "accuracy": None,
            "macro_f1": None,
            "majority_baseline_accuracy": None,
            "random_label_accuracy": None,
            "accuracy_minus_majority_baseline": None,
            "accuracy_minus_random_label_baseline": None,
            "num_rows": len(rows),
            "status": "insufficient_labels",
            "labels": labels,
            "train_label_counts": None,
            "test_label_counts": None,
        }

    if group_key is None:
        rng = random.Random(seed)
        indices = list(range(len(rows)))
        rng.shuffle(indices)
        split = max(1, int(round(len(indices) * 0.25)))
        test_indices = set(indices[:split])
        train_rows = [row for i, row in enumerate(rows) if i not in test_indices]
        test_rows = [row for i, row in enumerate(rows) if i in test_indices]
    else:
        train_rows, test_rows = deterministic_group_split(rows, group_key, seed)

    if not train_rows or not test_rows:
        return {
            "accuracy": None,
            "macro_f1": None,
            "majority_baseline_accuracy": None,
            "random_label_accuracy": None,
            "accuracy_minus_majority_baseline": None,
            "accuracy_minus_random_label_baseline": None,
            "num_rows": len(rows),
            "status": "insufficient_split",
            "labels": labels,
            "train_label_counts": None,
            "test_label_counts": None,
        }

    result = probe_split(train_rows, test_rows, labels, label_map, seed)
    result["num_rows"] = len(rows)
    result["split_type"] = "random_row_split" if group_key is None else f"group_split:{group_key}"
    return result


def transfer_probe(rows: list[dict], seed: int, train_condition: str, test_condition: str) -> dict[str, Any]:
    train_rows = [row for row in rows if row["condition"] == train_condition]
    test_rows = [row for row in rows if row["condition"] == test_condition]
    labels, label_map = build_label_map(rows)
    if len(train_rows) < 4 or len(test_rows) < 2 or len(labels) < 2:
        return {
            "accuracy": None,
            "macro_f1": None,
            "majority_baseline_accuracy": None,
            "random_label_accuracy": None,
            "accuracy_minus_majority_baseline": None,
            "accuracy_minus_random_label_baseline": None,
            "num_train": len(train_rows),
            "num_test": len(test_rows),
            "status": "insufficient_data",
            "labels": labels,
            "train_label_counts": None,
            "test_label_counts": None,
        }
    result = probe_split(train_rows, test_rows, labels, label_map, seed)
    result["train_condition"] = train_condition
    result["test_condition"] = test_condition
    return result


def condition_summary_rows(rows: list[dict], seed: int, layer_index: int, feature_location: str) -> dict[str, Any]:
    row: dict[str, Any] = {
        "layer_index": layer_index,
        "feature_location": feature_location,
        "num_rows": len(rows),
        "candidate_identity_split_accuracy": None,
        "example_split_accuracy": None,
        "with_rank_markers_accuracy": None,
        "without_rank_markers_accuracy": None,
        "with_rank_markers_to_without_rank_markers_accuracy": None,
        "without_rank_markers_to_with_rank_markers_accuracy": None,
    }

    labels, _ = build_label_map(rows)
    row["labels"] = labels

    overall = run_probe(rows, seed=seed)
    candidate_identity = run_probe(rows, seed=seed, group_key="candidate_name")
    example_split = run_probe(rows, seed=seed, group_key="example_id")
    with_rank_rows = [r for r in rows if r["condition"] == "with_rank_markers"]
    without_rank_rows = [r for r in rows if r["condition"] == "without_rank_markers"]
    with_rank = run_probe(with_rank_rows, seed=seed)
    without_rank = run_probe(without_rank_rows, seed=seed)
    transfer_forward = transfer_probe(rows, seed, "with_rank_markers", "without_rank_markers")
    transfer_reverse = transfer_probe(rows, seed, "without_rank_markers", "with_rank_markers")

    row.update(
        {
            "accuracy": overall["accuracy"],
            "macro_f1": overall["macro_f1"],
            "majority_baseline_accuracy": overall["majority_baseline_accuracy"],
            "random_label_accuracy": overall["random_label_accuracy"],
            "accuracy_minus_majority_baseline": overall["accuracy_minus_majority_baseline"],
            "accuracy_minus_random_label_baseline": overall["accuracy_minus_random_label_baseline"],
            "status": overall["status"],
            "num_train": overall.get("num_train"),
            "num_test": overall.get("num_test"),
            "train_label_counts": overall.get("train_label_counts"),
            "test_label_counts": overall.get("test_label_counts"),
            "split_type": overall.get("split_type"),
            "candidate_identity_split_accuracy": candidate_identity["accuracy"],
            "candidate_identity_split_macro_f1": candidate_identity["macro_f1"],
            "candidate_identity_split_majority_baseline_accuracy": candidate_identity["majority_baseline_accuracy"],
            "candidate_identity_split_random_label_accuracy": candidate_identity["random_label_accuracy"],
            "candidate_identity_split_accuracy_minus_majority_baseline": candidate_identity["accuracy_minus_majority_baseline"],
            "candidate_identity_split_accuracy_minus_random_label_baseline": candidate_identity["accuracy_minus_random_label_baseline"],
            "candidate_identity_split_status": candidate_identity["status"],
            "candidate_identity_split_num_train": candidate_identity.get("num_train"),
            "candidate_identity_split_num_test": candidate_identity.get("num_test"),
            "candidate_identity_split_train_label_counts": candidate_identity.get("train_label_counts"),
            "candidate_identity_split_test_label_counts": candidate_identity.get("test_label_counts"),
            "example_split_accuracy": example_split["accuracy"],
            "example_split_macro_f1": example_split["macro_f1"],
            "example_split_majority_baseline_accuracy": example_split["majority_baseline_accuracy"],
            "example_split_random_label_accuracy": example_split["random_label_accuracy"],
            "example_split_accuracy_minus_majority_baseline": example_split["accuracy_minus_majority_baseline"],
            "example_split_accuracy_minus_random_label_baseline": example_split["accuracy_minus_random_label_baseline"],
            "example_split_status": example_split["status"],
            "example_split_num_train": example_split.get("num_train"),
            "example_split_num_test": example_split.get("num_test"),
            "example_split_train_label_counts": example_split.get("train_label_counts"),
            "example_split_test_label_counts": example_split.get("test_label_counts"),
            "with_rank_markers_accuracy": with_rank["accuracy"],
            "with_rank_markers_macro_f1": with_rank["macro_f1"],
            "with_rank_markers_majority_baseline_accuracy": with_rank["majority_baseline_accuracy"],
            "with_rank_markers_random_label_accuracy": with_rank["random_label_accuracy"],
            "with_rank_markers_accuracy_minus_majority_baseline": with_rank["accuracy_minus_majority_baseline"],
            "with_rank_markers_accuracy_minus_random_label_baseline": with_rank["accuracy_minus_random_label_baseline"],
            "with_rank_markers_status": with_rank["status"],
            "with_rank_markers_num_train": with_rank.get("num_train"),
            "with_rank_markers_num_test": with_rank.get("num_test"),
            "with_rank_markers_train_label_counts": with_rank.get("train_label_counts"),
            "with_rank_markers_test_label_counts": with_rank.get("test_label_counts"),
            "without_rank_markers_accuracy": without_rank["accuracy"],
            "without_rank_markers_macro_f1": without_rank["macro_f1"],
            "without_rank_markers_majority_baseline_accuracy": without_rank["majority_baseline_accuracy"],
            "without_rank_markers_random_label_accuracy": without_rank["random_label_accuracy"],
            "without_rank_markers_accuracy_minus_majority_baseline": without_rank["accuracy_minus_majority_baseline"],
            "without_rank_markers_accuracy_minus_random_label_baseline": without_rank["accuracy_minus_random_label_baseline"],
            "without_rank_markers_status": without_rank["status"],
            "without_rank_markers_num_train": without_rank.get("num_train"),
            "without_rank_markers_num_test": without_rank.get("num_test"),
            "without_rank_markers_train_label_counts": without_rank.get("train_label_counts"),
            "without_rank_markers_test_label_counts": without_rank.get("test_label_counts"),
            "with_rank_markers_to_without_rank_markers_accuracy": transfer_forward["accuracy"],
            "with_rank_markers_to_without_rank_markers_macro_f1": transfer_forward["macro_f1"],
            "with_rank_markers_to_without_rank_markers_majority_baseline_accuracy": transfer_forward["majority_baseline_accuracy"],
            "with_rank_markers_to_without_rank_markers_random_label_accuracy": transfer_forward["random_label_accuracy"],
            "with_rank_markers_to_without_rank_markers_accuracy_minus_majority_baseline": transfer_forward["accuracy_minus_majority_baseline"],
            "with_rank_markers_to_without_rank_markers_accuracy_minus_random_label_baseline": transfer_forward["accuracy_minus_random_label_baseline"],
            "with_rank_markers_to_without_rank_markers_status": transfer_forward["status"],
            "with_rank_markers_to_without_rank_markers_num_train": transfer_forward.get("num_train"),
            "with_rank_markers_to_without_rank_markers_num_test": transfer_forward.get("num_test"),
            "with_rank_markers_to_without_rank_markers_train_label_counts": transfer_forward.get("train_label_counts"),
            "with_rank_markers_to_without_rank_markers_test_label_counts": transfer_forward.get("test_label_counts"),
            "without_rank_markers_to_with_rank_markers_accuracy": transfer_reverse["accuracy"],
            "without_rank_markers_to_with_rank_markers_macro_f1": transfer_reverse["macro_f1"],
            "without_rank_markers_to_with_rank_markers_majority_baseline_accuracy": transfer_reverse["majority_baseline_accuracy"],
            "without_rank_markers_to_with_rank_markers_random_label_accuracy": transfer_reverse["random_label_accuracy"],
            "without_rank_markers_to_with_rank_markers_accuracy_minus_majority_baseline": transfer_reverse["accuracy_minus_majority_baseline"],
            "without_rank_markers_to_with_rank_markers_accuracy_minus_random_label_baseline": transfer_reverse["accuracy_minus_random_label_baseline"],
            "without_rank_markers_to_with_rank_markers_status": transfer_reverse["status"],
            "without_rank_markers_to_with_rank_markers_num_train": transfer_reverse.get("num_train"),
            "without_rank_markers_to_with_rank_markers_num_test": transfer_reverse.get("num_test"),
            "without_rank_markers_to_with_rank_markers_train_label_counts": transfer_reverse.get("train_label_counts"),
            "without_rank_markers_to_with_rank_markers_test_label_counts": transfer_reverse.get("test_label_counts"),
        }
    )
    return row


def summarize_all(feature_rows: list[dict], seed: int) -> tuple[dict[str, Any], list[dict]]:
    if not feature_rows:
        return (
            {
                "status": "no_data",
                "probe_accuracy": None,
                "mean_probe_accuracy": None,
                "majority_baseline_accuracy": None,
                "random_label_accuracy": None,
                "accuracy_minus_majority_baseline": None,
                "accuracy_minus_random_label_baseline": None,
                "macro_f1": None,
                "layer_with_highest_probe_accuracy": None,
                "accuracy_by_layer": {},
                "accuracy_by_feature_location": {},
                "best_with_rank_markers_result": None,
                "best_without_rank_markers_result": None,
                "candidate_identity_split_accuracy": None,
                "example_split_accuracy": None,
                "condition_transfer_accuracy": None,
                "primary_probe_result": None,
                "num_examples": 0,
                "num_feature_rows": 0,
                "labels_observed": [],
            },
            [],
        )

    summary_rows: list[dict[str, Any]] = []
    all_accuracies: list[float] = []
    all_majorities: list[float] = []
    all_randoms: list[float] = []
    all_f1s: list[float] = []
    accuracy_by_layer: dict[str, float] = {}
    accuracy_by_feature_location: dict[str, float] = {}
    best_with_rank = None
    best_without_rank = None
    best_candidate_identity = None
    best_example_split = None
    best_transfer_forward = None
    best_transfer_reverse = None

    feature_locations = sorted({str(row["feature_location"]) for row in feature_rows})
    layer_indices = sorted({int(row["layer_index"]) for row in feature_rows})

    for layer_index in layer_indices:
        layer_rows = [row for row in feature_rows if int(row["layer_index"]) == layer_index]
        best_layer_accuracy = None
        for feature_location in feature_locations:
            subset = [row for row in layer_rows if str(row["feature_location"]) == feature_location]
            if len(subset) < 6:
                continue
            row = condition_summary_rows(subset, seed, layer_index, feature_location)
            summary_rows.append(row)

            if row["accuracy"] is not None:
                all_accuracies.append(float(row["accuracy"]))
                all_majorities.append(float(row["majority_baseline_accuracy"]))
                all_randoms.append(float(row["random_label_accuracy"]))
                all_f1s.append(float(row["macro_f1"]))
                if best_layer_accuracy is None or row["accuracy"] > best_layer_accuracy:
                    best_layer_accuracy = float(row["accuracy"])
            if row["accuracy"] is not None:
                current = accuracy_by_feature_location.get(feature_location)
                if current is None or row["accuracy"] > current:
                    accuracy_by_feature_location[feature_location] = float(row["accuracy"])

            if best_with_rank is None or _better_condition_result(row, "with_rank_markers", best_with_rank):
                best_with_rank = row
            if best_without_rank is None or _better_condition_result(row, "without_rank_markers", best_without_rank):
                best_without_rank = row
            if best_candidate_identity is None or _better_condition_result(row, "candidate_identity_split", best_candidate_identity):
                best_candidate_identity = row
            if best_example_split is None or _better_condition_result(row, "example_split", best_example_split):
                best_example_split = row
            if best_transfer_forward is None or _better_condition_result(row, "with_rank_markers_to_without_rank_markers", best_transfer_forward):
                best_transfer_forward = row
            if best_transfer_reverse is None or _better_condition_result(row, "without_rank_markers_to_with_rank_markers", best_transfer_reverse):
                best_transfer_reverse = row

        if best_layer_accuracy is not None:
            accuracy_by_layer[str(layer_index)] = best_layer_accuracy

    best_row = max((row for row in summary_rows if row["accuracy"] is not None), key=lambda row: float(row["accuracy"]), default=None)
    labels_observed = sorted({int(row["candidate_position"]) for row in feature_rows})
    condition_transfer_accuracy = None
    if best_transfer_forward or best_transfer_reverse:
        condition_transfer_accuracy = {
            "with_rank_markers_to_without_rank_markers": _transfer_summary(best_transfer_forward, "with_rank_markers_to_without_rank_markers"),
            "without_rank_markers_to_with_rank_markers": _transfer_summary(best_transfer_reverse, "without_rank_markers_to_with_rank_markers"),
        }

    primary_probe_result = None
    if best_example_split is not None:
        primary_probe_result = {
            "selection_rule": "best example_split_accuracy; fallback to candidate_identity_split_accuracy",
            "example_split": _transfer_summary(best_example_split, "example_split"),
            "candidate_identity_split": _transfer_summary(best_candidate_identity, "candidate_identity_split"),
        }
    elif best_candidate_identity is not None:
        primary_probe_result = {
            "selection_rule": "best example_split_accuracy; fallback to candidate_identity_split_accuracy",
            "example_split": None,
            "candidate_identity_split": _transfer_summary(best_candidate_identity, "candidate_identity_split"),
        }

    summary = {
        "status": "ok",
        "probe_accuracy": best_row["accuracy"] if best_row else None,
        "mean_probe_accuracy": float(np.mean(all_accuracies)) if all_accuracies else None,
        "majority_baseline_accuracy": best_row["majority_baseline_accuracy"] if best_row else None,
        "random_label_accuracy": best_row["random_label_accuracy"] if best_row else None,
        "accuracy_minus_majority_baseline": best_row["accuracy_minus_majority_baseline"] if best_row else None,
        "accuracy_minus_random_label_baseline": best_row["accuracy_minus_random_label_baseline"] if best_row else None,
        "macro_f1": best_row["macro_f1"] if best_row else None,
        "layer_with_highest_probe_accuracy": {
            "layer_index": best_row["layer_index"] if best_row else None,
            "feature_location": best_row["feature_location"] if best_row else None,
            "accuracy": best_row["accuracy"] if best_row else None,
            "macro_f1": best_row["macro_f1"] if best_row else None,
            "majority_baseline_accuracy": best_row["majority_baseline_accuracy"] if best_row else None,
            "random_label_accuracy": best_row["random_label_accuracy"] if best_row else None,
        },
        "accuracy_by_layer": accuracy_by_layer,
        "accuracy_by_feature_location": accuracy_by_feature_location,
        "best_with_rank_markers_result": _transfer_summary(best_with_rank, "with_rank_markers"),
        "best_without_rank_markers_result": _transfer_summary(best_without_rank, "without_rank_markers"),
        "candidate_identity_split_accuracy": _transfer_summary(best_candidate_identity, "candidate_identity_split"),
        "example_split_accuracy": _transfer_summary(best_example_split, "example_split"),
        "condition_transfer_accuracy": condition_transfer_accuracy,
        "primary_probe_result": primary_probe_result,
        "num_examples": len({row["example_id"] for row in feature_rows}),
        "num_feature_rows": len(feature_rows),
        "num_summary_rows": len(summary_rows),
        "labels_observed": labels_observed,
        "feature_locations": feature_locations,
        "layers_selected": layer_indices,
        "mean_majority_baseline_accuracy": float(np.mean(all_majorities)) if all_majorities else None,
        "mean_random_label_accuracy": float(np.mean(all_randoms)) if all_randoms else None,
        "mean_macro_f1": float(np.mean(all_f1s)) if all_f1s else None,
    }
    return summary, summary_rows


def _transfer_summary(row: dict[str, Any] | None, prefix: str) -> dict[str, Any] | None:
    if row is None:
        return None
    return {
        "layer_index": row["layer_index"],
        "feature_location": row["feature_location"],
        "accuracy": row.get(f"{prefix}_accuracy"),
        "macro_f1": row.get(f"{prefix}_macro_f1"),
        "majority_baseline_accuracy": row.get(f"{prefix}_majority_baseline_accuracy"),
        "random_label_accuracy": row.get(f"{prefix}_random_label_accuracy"),
        "accuracy_minus_majority_baseline": row.get(f"{prefix}_accuracy_minus_majority_baseline"),
        "accuracy_minus_random_label_baseline": row.get(f"{prefix}_accuracy_minus_random_label_baseline"),
        "train_label_counts": row.get(f"{prefix}_train_label_counts"),
        "test_label_counts": row.get(f"{prefix}_test_label_counts"),
        "status": row.get(f"{prefix}_status"),
        "num_train": row.get(f"{prefix}_num_train"),
        "num_test": row.get(f"{prefix}_num_test"),
    }


def _better_condition_result(row: dict[str, Any], field_prefix: str, current_best: dict[str, Any] | None) -> bool:
    field = f"{field_prefix}_accuracy"
    value = row.get(field)
    if value is None:
        return False
    if current_best is None:
        return True
    current_value = current_best.get(field)
    if current_value is None:
        return True
    return float(value) > float(current_value)


def build_prompt_rows(feature_rows: list[dict], write_full_prompt: bool) -> list[dict]:
    rows_by_key: dict[tuple[str, str, str, int, int], dict[str, Any]] = {}
    counts: dict[tuple[str, str, str, int, int], int] = defaultdict(int)
    for row in feature_rows:
        key = (
            str(row["example_id"]),
            str(row["condition"]),
            str(row["prompt_variant"]),
            int(row["source_rank"]),
            int(row["candidate_position"]),
        )
        counts[key] += 1
        if key in rows_by_key:
            continue
        prompt_row = {
            "example_id": row.get("example_id"),
            "image_path": row.get("image_path"),
            "image_id": row.get("image_id"),
            "ground_truth_species": row.get("ground_truth_species"),
            "ground_truth_common_name": row.get("ground_truth_common_name"),
            "ground_truth_genus": row.get("ground_truth_genus"),
            "condition": row.get("condition"),
            "prompt_variant": row.get("prompt_variant"),
            "source_rank": row.get("source_rank"),
            "candidate_position": row.get("candidate_position"),
            "candidate_name": row.get("candidate_name"),
            "candidate_count": row.get("candidate_count"),
            "label": row.get("label"),
            "coarse_position": row.get("coarse_position"),
            "prompt_char_length": row.get("prompt_char_length"),
        }
        if write_full_prompt and row.get("full_prompt") is not None:
            prompt_row["full_prompt"] = row["full_prompt"]
        rows_by_key[key] = prompt_row

    rows = list(rows_by_key.values())
    for row in rows:
        key = (
            str(row["example_id"]),
            str(row["condition"]),
            str(row["prompt_variant"]),
            int(row["source_rank"]),
            int(row["candidate_position"]),
        )
        row["feature_row_count"] = counts[key]
    return rows


def collect_feature_rows(
    bundle,
    examples: list[dict],
    positions: list[int],
    layer_indices: list[int],
    feature_locations: list[str],
    seed: int,
    features_output: Path,
    existing_keys: set[tuple[str, str, str, int, int, int, str]],
    write_full_prompt: bool,
) -> dict[str, int]:
    written_feature_rows = 0
    skipped_existing_rows = 0
    skipped_missing_candidate_span = 0
    skipped_missing_answer_span = 0
    skipped_missing_answer_marker_span = 0
    processed_examples = 0
    total_examples = len(examples)
    prompt_variants = BASELINE_PROMPTS
    for index, example in enumerate(examples, 1):
        example_id = str(example.get("example_id") or "")
        candidates = [strip_confidence(c) for c in (example.get("original_candidates") or [])]
        if not example_id or not candidates:
            continue
        target_positions = [pos for pos in positions if pos <= len(candidates)]
        if not target_positions:
            continue
        processed_examples += 1
        print(f"[{index}/{total_examples}] {example_id} ({len(candidates)} candidates)", flush=True)

        example_rows: list[dict[str, Any]] = []
        for condition_name, variant in prompt_variants.items():
            for source_rank, candidate in enumerate(candidates, 1):
                candidate_name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
                for target_position in target_positions:
                    candidate_order = move_candidate(candidates, source_rank, target_position)
                    prompt = build_prompt_variant_prompt(candidate_order, variant)
                    prompt_char_length = len(prompt)
                    hidden_states = bundle.hidden_states_for_prompt(prompt, layer_indices=layer_indices)
                    try:
                        target_display_name = candidate_scientific_name(candidate) or candidate_display_name(candidate)
                        target_span = locate_text_span(bundle.tokenizer, prompt, target_display_name)
                        answer_span = locate_answer_position_span(bundle.tokenizer, prompt)
                        marker_span = locate_text_span(bundle.tokenizer, prompt, "Answer:")

                        batch_rows: list[dict[str, Any]] = []
                        for layer_index in layer_indices:
                            try:
                                layer_tensor = bundle.layer_tensor(hidden_states, layer_index)
                            except ExperimentError:
                                continue
                            feature_specs = {
                                "candidate_span_mean": ("mean", target_span),
                                "candidate_span_last": ("last", target_span),
                                "answer_position_token": ("last", answer_span),
                                "answer_marker_span_mean": ("mean", marker_span),
                            }
                            for feature_location in feature_locations:
                                mode, span = feature_specs[feature_location]
                                if feature_location in {"candidate_span_mean", "candidate_span_last"} and target_span is None:
                                    skipped_missing_candidate_span += 1
                                    continue
                                if feature_location == "answer_position_token" and answer_span is None:
                                    skipped_missing_answer_span += 1
                                    continue
                                if feature_location == "answer_marker_span_mean" and marker_span is None:
                                    skipped_missing_answer_marker_span += 1
                                    continue
                                key = (
                                    example_id,
                                    condition_name,
                                    candidate_name,
                                    source_rank,
                                    target_position,
                                    layer_index,
                                    feature_location,
                                )
                                if key in existing_keys:
                                    skipped_existing_rows += 1
                                    continue
                                vec = _flatten_feature(layer_tensor, span, mode)
                                batch_rows.append(
                                    {
                                        "example_id": example_id,
                                        "image_path": example.get("image_path"),
                                        "image_id": example.get("image_id"),
                                        "ground_truth_species": example.get("ground_truth_species"),
                                        "ground_truth_common_name": example.get("ground_truth_common_name"),
                                        "ground_truth_genus": example.get("ground_truth_genus"),
                                        "condition": condition_name,
                                        "prompt_variant": variant.name,
                                        "source_rank": source_rank,
                                        "candidate_position": target_position,
                                        "candidate_count": len(candidates),
                                        "candidate_name": candidate_name,
                                        "label": target_position,
                                        "coarse_position": {1: "early", 3: "middle", 5: "late"}.get(target_position, "other"),
                                        "prompt_char_length": prompt_char_length,
                                        "candidate_span_found": target_span is not None,
                                        "answer_span_found": answer_span is not None,
                                        "answer_marker_span_found": marker_span is not None,
                                        "layer_index": layer_index,
                                        "feature_location": feature_location,
                                        "features": vec.tolist(),
                                    }
                                )
                                if write_full_prompt:
                                    batch_rows[-1]["full_prompt"] = prompt
                                existing_keys.add(key)
                                written_feature_rows += 1
                        example_rows.extend(batch_rows)
                    finally:
                        del hidden_states
        append_jsonl(features_output, example_rows)
        maybe_release_memory(processed_examples)
    return {
        "num_processed_examples": processed_examples,
        "num_skipped_existing_feature_rows": skipped_existing_rows,
        "num_skipped_missing_candidate_span": skipped_missing_candidate_span,
        "num_skipped_missing_answer_span": skipped_missing_answer_span,
        "num_skipped_missing_answer_marker_span": skipped_missing_answer_marker_span,
        "num_written_feature_rows": written_feature_rows,
    }


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("")
        return
    with path.open("w", newline="") as fh:
        fieldnames = list(rows[0].keys())
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def select_examples(examples: list[dict], start_example: int, end_example: int, limit: int) -> list[dict]:
    if start_example < 1:
        raise ExperimentError("--start-example must be at least 1")
    if end_example and end_example < start_example:
        raise ExperimentError("--end-example must be >= --start-example")

    selected = examples
    if start_example > 1 or end_example > 0:
        start_idx = start_example - 1
        end_idx = end_example if end_example > 0 else None
        selected = selected[start_idx:end_idx]
    if limit:
        selected = selected[:limit]
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--examples", default=str(DEFAULT_EXAMPLES), help="Frozen examples JSONL")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT), help="Row-level metadata JSONL output")
    parser.add_argument("--features-output", default=str(DEFAULT_FEATURES), help="Feature-vector JSONL output")
    parser.add_argument("--summary-output", default=str(DEFAULT_SUMMARY), help="Summary JSON output")
    parser.add_argument("--table-output", default=str(DEFAULT_TABLE), help="CSV table output")
    parser.add_argument("--dataset-output", default=str(DEFAULT_DATASET), help="Compact metadata dataset JSONL output")
    parser.add_argument("--positions", default="1,3,5", help="Comma-separated candidate positions")
    parser.add_argument("--feature-locations", default=",".join(DEFAULT_FEATURE_LOCATIONS), help="Comma-separated feature locations")
    parser.add_argument("--layers", default="first,middle,last", help="Hidden-state layers to probe: all, first, last, middle, or comma-separated indices")
    parser.add_argument("--start-example", type=int, default=1, help="1-based inclusive example start index")
    parser.add_argument("--end-example", type=int, default=0, help="1-based inclusive example end index; 0 means no upper bound")
    parser.add_argument("--limit", type=int, default=0, help="Limit the number of examples")
    parser.add_argument("--max-examples", type=int, default=0, help="Alternative limit for convenience")
    parser.add_argument("--seed", type=int, default=7, help="Random seed")
    parser.add_argument("--model-id", default=DEFAULT_MODEL_ID, help="Hugging Face model id")
    parser.add_argument("--device", default="auto", help="torch device to use")
    parser.add_argument("--dtype", default="auto", help="torch dtype to use")
    parser.add_argument("--resume", action="store_true", help="Resume from existing JSONL files")
    parser.add_argument("--collect-only", action="store_true", help="Only collect feature rows, do not run probe summary")
    parser.add_argument("--summarize-only", action="store_true", help="Only summarize existing feature rows, do not load model")
    parser.add_argument("--write-full-prompt", action="store_true", help="Store the full prompt text in output JSONL for debugging")
    args = parser.parse_args()

    if args.collect_only and args.summarize_only:
        raise ExperimentError("--collect-only and --summarize-only cannot be used together")

    set_seed(args.seed)
    examples_path = Path(args.examples).expanduser().resolve()
    examples = load_jsonl(examples_path)
    limit = args.max_examples or args.limit
    if limit:
        examples = examples[:limit]
    examples = select_examples(examples, args.start_example, args.end_example, 0)
    positions = parse_positions(args.positions)
    feature_locations = parse_feature_locations(args.feature_locations)

    output_path = Path(args.output).expanduser().resolve()
    features_output = Path(args.features_output).expanduser().resolve()
    summary_path = Path(args.summary_output).expanduser().resolve()
    table_path = Path(args.table_output).expanduser().resolve()
    dataset_path = Path(args.dataset_output).expanduser().resolve()
    for path in (output_path, features_output, summary_path, table_path, dataset_path):
        path.parent.mkdir(parents=True, exist_ok=True)

    if args.summarize_only:
        if not features_output.exists():
            raise ExperimentError(f"--summarize-only requires an existing feature file: {features_output}")
        feature_rows = load_jsonl(features_output)
        summary, table_rows = summarize_all(feature_rows, args.seed)
        summary.update(
            {
                "mode": "summarize_only",
                "num_examples_requested": len(examples),
                "num_processed_examples": None,
                "num_skipped_existing_feature_rows": None,
                "num_written_feature_rows": None,
                "num_prompt_rows": None,
                "features_output": str(features_output),
                "output": str(output_path),
                "summary_output": str(summary_path),
                "table_output": str(table_path),
                "dataset_output": str(dataset_path),
                "positions": positions,
                "feature_locations_requested": feature_locations,
                "layers_requested": args.layers,
                "layers_selected": sorted({int(row["layer_index"]) for row in feature_rows}),
                "write_full_prompt": args.write_full_prompt,
                "model_id": args.model_id,
            }
        )
        safe_write_json(summary_path, summary)
        write_csv(table_path, table_rows)
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0

    if not args.resume:
        for path in (output_path, features_output, dataset_path):
            if path.exists():
                path.unlink()

    bundle = load_hf_bundle(args.model_id, device=args.device, dtype=args.dtype)
    hidden_state_count = text_hidden_state_count(bundle)

    layer_indices = select_hidden_state_indices(args.layers, hidden_state_count)
    if not layer_indices:
        raise ExperimentError("No layers were selected for probing")

    existing_keys = load_existing_feature_keys(features_output) if args.resume else set()
    collection_stats = collect_feature_rows(
        bundle=bundle,
        examples=examples,
        positions=positions,
        layer_indices=layer_indices,
        feature_locations=feature_locations,
        seed=args.seed,
        features_output=features_output,
        existing_keys=existing_keys,
        write_full_prompt=args.write_full_prompt,
    )

    if args.collect_only:
        summary = {
            "status": "collected",
            "mode": "collect_only",
            "num_examples_requested": len(examples),
            "num_processed_examples": collection_stats["num_processed_examples"],
            "num_skipped_existing_feature_rows": collection_stats["num_skipped_existing_feature_rows"],
            "num_skipped_missing_candidate_span": collection_stats["num_skipped_missing_candidate_span"],
            "num_skipped_missing_answer_span": collection_stats["num_skipped_missing_answer_span"],
            "num_skipped_missing_answer_marker_span": collection_stats["num_skipped_missing_answer_marker_span"],
            "num_written_feature_rows": collection_stats["num_written_feature_rows"],
            "features_output": str(features_output),
            "summary_output": str(summary_path),
            "positions": positions,
            "feature_locations_requested": feature_locations,
            "layers_requested": args.layers,
            "layers_selected": layer_indices,
            "write_full_prompt": args.write_full_prompt,
            "model_id": args.model_id,
            "device": bundle.device,
            "dtype": str(bundle.dtype),
        }
        safe_write_json(summary_path, summary)
        print(json.dumps(summary, indent=2, ensure_ascii=False))
        return 0

    feature_rows = load_jsonl(features_output) if features_output.exists() else []
    prompt_rows = build_prompt_rows(feature_rows, write_full_prompt=args.write_full_prompt)
    if args.resume and output_path.exists():
        output_path.unlink()
    if args.resume and dataset_path.exists():
        dataset_path.unlink()
    append_jsonl(output_path, prompt_rows)
    append_jsonl(dataset_path, prompt_rows)

    summary, table_rows = summarize_all(feature_rows, args.seed)
    summary.update(
        {
            "mode": "full",
            "num_examples_requested": len(examples),
            "num_processed_examples": collection_stats["num_processed_examples"],
            "num_skipped_existing_feature_rows": collection_stats["num_skipped_existing_feature_rows"],
            "num_skipped_missing_candidate_span": collection_stats["num_skipped_missing_candidate_span"],
            "num_skipped_missing_answer_span": collection_stats["num_skipped_missing_answer_span"],
            "num_skipped_missing_answer_marker_span": collection_stats["num_skipped_missing_answer_marker_span"],
            "num_written_feature_rows": collection_stats["num_written_feature_rows"],
            "num_prompt_rows": len(prompt_rows),
            "features_output": str(features_output),
            "output": str(output_path),
            "summary_output": str(summary_path),
            "table_output": str(table_path),
            "dataset_output": str(dataset_path),
            "positions": positions,
            "feature_locations_requested": feature_locations,
            "layers_requested": args.layers,
            "layers_selected": layer_indices,
            "write_full_prompt": args.write_full_prompt,
            "model_id": args.model_id,
            "device": bundle.device,
            "dtype": str(bundle.dtype),
        }
    )
    safe_write_json(summary_path, summary)
    write_csv(table_path, table_rows)
    print(json.dumps(summary, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
