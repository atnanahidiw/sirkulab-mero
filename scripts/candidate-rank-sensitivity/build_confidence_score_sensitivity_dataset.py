#!/usr/bin/env python3
"""Build a frozen JSONL dataset for the confidence-score-sensitivity experiment.

This freezes the baseline candidate set that Gemma originally saw, including the
candidate confidence values, so we can later perturb only the displayed scores.

We keep this as a separate frozen dataset from the rank-sensitivity set because
the confidence experiment changes the displayed score signal, not the candidate
order. Reusing the rank frozen set would mix two different interventions.
"""
from __future__ import annotations

import argparse
import random
import sqlite3
from datetime import date
from pathlib import Path

from _common import (
    BASELINE_OUTPUT,
    DB_PATH,
    DEFAULT_OUTPUT_DIR,
    ExperimentError,
    ensure_exists,
    load_baseline_module,
    load_jsonl,
    write_jsonl,
)

DEFAULT_SOURCE = BASELINE_OUTPUT
DEFAULT_TOP_K = 5
# Use the same practical ceiling as the rank experiment so the confidence sweep
# can cover the largest frozen slice the current corpus can support.
DEFAULT_LIMIT = 125


def load_species_catalog(db_path: Path) -> list[dict]:
    ensure_exists(db_path, "species database")
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            'SELECT id, common_name, latin_name, kingdom, "class" AS class, "order" AS "order", family, genus, visual_group, visual_features, description FROM species'
        ).fetchall()
    finally:
        con.close()
    return [dict(row) for row in rows]


def species_index(catalog: list[dict]) -> dict[str, dict]:
    return {str(row.get("latin_name") or "").strip(): row for row in catalog if str(row.get("latin_name") or "").strip()}


def make_example_id(row: dict, index: int) -> str:
    image = str(row.get("image") or "").strip()
    if image:
        return image
    true_species = str(row.get("true") or row.get("ground_truth_species") or "").strip()
    if true_species:
        return f"{true_species}-{index:04d}"
    return f"example-{index:04d}"


def choose_source_rows(rows: list[dict], limit: int, seed: int, require_correct: bool) -> list[int]:
    indices = list(range(len(rows)))
    rng = random.Random(seed)
    rng.shuffle(indices)
    selected: list[int] = []
    for idx in indices:
        row = rows[idx]
        if require_correct and not row.get("species_ok"):
            continue
        tool_calls = row.get("tool_call_args") or []
        if not tool_calls:
            continue
        selected.append(idx)
        if limit > 0 and len(selected) >= limit:
            break
    return selected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-jsonl", default=str(DEFAULT_SOURCE), help="Source baseline JSONL to freeze")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT, help="Maximum examples to freeze")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic selection seed")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT_DIR / "examples.jsonl"), help="Output frozen JSONL")
    parser.add_argument("--candidate-top-k", type=int, default=DEFAULT_TOP_K, help="How many candidates to store per example")
    parser.add_argument(
        "--allow-incorrect-source",
        action="store_true",
        help="Also keep baseline rows where the source run missed the true species",
    )
    args = parser.parse_args()

    source_path = Path(args.source_jsonl)
    output_path = Path(args.output)

    ensure_exists(source_path, "source baseline JSONL")
    ensure_exists(DB_PATH, "species database")

    rows = load_jsonl(source_path)
    if not rows:
        raise ExperimentError(f"No rows found in source JSONL: {source_path}")

    selected_indices = choose_source_rows(rows, args.limit, args.seed, require_correct=not args.allow_incorrect_source)
    if not selected_indices:
        raise ExperimentError("No eligible source rows were found. Try --allow-incorrect-source or a larger source JSONL.")

    catalog = load_species_catalog(DB_PATH)
    by_latin = species_index(catalog)
    baseline_module = load_baseline_module()

    frozen: list[dict] = []
    skipped_missing_species = 0
    skipped_empty_candidates = 0

    for source_index in selected_indices:
        if args.limit > 0 and len(frozen) >= args.limit:
            break
        row = rows[source_index]
        tool_calls = row.get("tool_call_args") or []
        if not tool_calls:
            skipped_empty_candidates += 1
            continue

        first_call = dict(tool_calls[0])
        true_latin = str(row.get("true") or row.get("ground_truth_species") or "").strip()
        target = by_latin.get(true_latin)
        if target is None:
            skipped_missing_species += 1
            continue

        con = sqlite3.connect(str(DB_PATH))
        con.row_factory = sqlite3.Row
        try:
            original_candidates = baseline_module._run_search(con, first_call, top_k=args.candidate_top_k)
        finally:
            con.close()

        if not original_candidates:
            skipped_empty_candidates += 1
            continue

        final = row.get("final") or {}
        gt_species = true_latin or str(row.get("ground_truth_species") or final.get("scientific_name") or "").strip()
        gt_common = str(final.get("common_name") or "").strip()
        gt_genus = str(final.get("genus") or (gt_species.split()[0] if gt_species else "")).strip()

        frozen.append(
            {
                "example_id": make_example_id(row, len(frozen) + 1),
                "image_path": row.get("image", ""),
                "image_id": Path(str(row.get("image", ""))).stem,
                "ground_truth_species": gt_species,
                "ground_truth_common_name": gt_common,
                "ground_truth_genus": gt_genus,
                "baseline_answer_species": str(final.get("scientific_name") or "").strip(),
                "baseline_answer_common_name": str(final.get("common_name") or "").strip(),
                "baseline_answer_genus": str(final.get("genus") or "").strip(),
                "candidate_count": len(original_candidates),
                "original_candidates": original_candidates,
                "metadata": {
                    "source_jsonl": str(source_path),
                    "source_row_index": source_index,
                    "seed": args.seed,
                    "candidate_top_k": args.candidate_top_k,
                    "tool_call_args": first_call,
                    "source_model_answer": final,
                    "source_model_text": row.get("final_text", ""),
                    "source_species_ok": row.get("species_ok"),
                    "source_genus_ok": row.get("genus_ok"),
                    "source_visual_group": tool_calls[0].get("visualGroup", ""),
                    "frozen_at": str(date.today()),
                    "byproduct_of": "gemma4-baseline-failure-analysis-native",
                    "experiment": "confidence-score-sensitivity",
                },
            }
        )

    write_jsonl(output_path, frozen)
    notes = []
    if skipped_missing_species:
        notes.append(f"{skipped_missing_species} rows missing species catalog matches")
    if skipped_empty_candidates:
        notes.append(f"{skipped_empty_candidates} rows missing usable candidate data")
    suffix = f" ({'; '.join(notes)})" if notes else ""
    print(f"Wrote {len(frozen)} frozen examples to {output_path}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
