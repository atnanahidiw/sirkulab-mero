
#!/usr/bin/env python3
"""Build a frozen JSONL dataset for the candidate-rank-sensitivity experiment.

The default mode is deliberately far-separated: keep the true species in the
candidate set, but choose distractors from visually and taxonomically distant
species so the test isolates order effects rather than look-alike confusion.
"""
from __future__ import annotations

import argparse
import collections
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
    load_candidate_ranking_module,
    load_jsonl,
    stable_int_seed,
    write_jsonl,
)

DEFAULT_SOURCE = BASELINE_OUTPUT
DEFAULT_TOP_K = 5


def load_species_catalog(db_path: Path) -> list[dict]:
    ensure_exists(db_path, "species database")
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    try:
        rows = con.execute(
            "SELECT id, common_name, latin_name, kingdom, \"class\" AS class, \"order\" AS \"order\", family, genus, visual_group, visual_features, description FROM species"
        ).fetchall()
    finally:
        con.close()
    return [dict(row) for row in rows]


def species_index(catalog: list[dict]) -> dict[str, dict]:
    return {str(row.get("latin_name") or "").strip(): row for row in catalog if str(row.get("latin_name") or "").strip()}


def taxonomic_distance(target: dict, candidate: dict) -> float:
    score = 0.0
    if target.get("visual_group") != candidate.get("visual_group"):
        score += 5.0
    if target.get("kingdom") != candidate.get("kingdom"):
        score += 3.0
    if target.get("class") != candidate.get("class"):
        score += 2.0
    if target.get("order") != candidate.get("order"):
        score += 1.5
    if target.get("family") != candidate.get("family"):
        score += 1.0
    if target.get("genus") != candidate.get("genus"):
        score += 0.5
    return score


def deterministic_tiebreak(seed: int, *parts: object) -> int:
    return stable_int_seed(seed, *parts)


def select_far_separated_candidates(target: dict, catalog: list[dict], top_k: int, seed: int) -> list[dict]:
    if top_k < 2:
        raise ExperimentError("candidate-top-k must be at least 2")

    target_latin = str(target.get("latin_name") or "").strip()
    if not target_latin:
        raise ExperimentError("Target species is missing latin_name")

    distractors = [row for row in catalog if str(row.get("latin_name") or "").strip() != target_latin]
    by_group: dict[str, list[dict]] = collections.defaultdict(list)
    for row in distractors:
        group = str(row.get("visual_group") or "").strip() or "Unknown"
        by_group[group].append(row)

    ranked_groups: list[tuple[float, int, str, dict]] = []
    for group, rows in by_group.items():
        best = max(
            rows,
            key=lambda row: (
                taxonomic_distance(target, row),
                -deterministic_tiebreak(seed, target_latin, group, row["latin_name"]),
                row["latin_name"],
            ),
        )
        ranked_groups.append(
            (
                taxonomic_distance(target, best),
                deterministic_tiebreak(seed, target_latin, group),
                group,
                best,
            )
        )

    ranked_groups.sort(key=lambda item: (-item[0], item[1], item[2]))
    chosen: list[dict] = [target]
    used_groups = {str(target.get("visual_group") or "").strip() or "Unknown"}
    used_species = {target_latin}
    for _, _, group, row in ranked_groups:
        if len(chosen) >= top_k:
            break
        if group in used_groups:
            continue
        if row["latin_name"] in used_species:
            continue
        chosen.append(row)
        used_groups.add(group)
        used_species.add(row["latin_name"])

    if len(chosen) < top_k:
        fallback = sorted(
            [row for row in distractors if row["latin_name"] not in used_species],
            key=lambda row: (
                -taxonomic_distance(target, row),
                deterministic_tiebreak(seed, target_latin, row["latin_name"]),
                row["latin_name"],
            ),
        )
        for row in fallback:
            if len(chosen) >= top_k:
                break
            chosen.append(row)
            used_species.add(row["latin_name"])

    if len(chosen) < top_k:
        raise ExperimentError(
            f"Could not assemble {top_k} far-separated candidates for {target_latin}; only {len(chosen)} available"
        )

    rng = random.Random(stable_int_seed(seed, target_latin, "far-separated-order"))
    rng.shuffle(chosen)
    return chosen


def make_candidate_row(row: dict, rank: int, target: dict) -> dict:
    return {
        "rank": rank,
        "scientific_name": str(row.get("latin_name") or "").strip(),
        "common_name": str(row.get("common_name") or "").strip(),
        "genus": str(row.get("genus") or "").strip(),
        "kingdom": str(row.get("kingdom") or "").strip(),
        "visual_group": str(row.get("visual_group") or "").strip(),
        "distance_to_target": round(taxonomic_distance(target, row), 2),
        "selection_mode": "far-separated",
        "visual_features": str(row.get("visual_features") or "").strip(),
        "prompt_text": (
            f"{row.get('common_name') or row.get('latin_name') or 'Unknown'} "
            f"[{row.get('latin_name') or ''}]"
        ).strip(),
    }


def baseline_original_candidates(baseline_module, db_path: Path, tool_args: dict, top_k: int) -> list[dict]:
    ensure_exists(db_path, "species database")
    con = sqlite3.connect(str(db_path))
    try:
        candidates = baseline_module._run_search(con, tool_args, top_k=top_k)
    finally:
        con.close()
    return candidates


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
    parser.add_argument("--limit", type=int, default=50, help="Maximum examples to freeze")
    parser.add_argument("--seed", type=int, default=42, help="Deterministic selection seed")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT_DIR / "examples.jsonl"), help="Output frozen JSONL")
    parser.add_argument("--candidate-top-k", type=int, default=DEFAULT_TOP_K, help="How many candidates to store per example")
    parser.add_argument(
        "--selection-mode",
        choices=["far-separated", "baseline-original"],
        default="far-separated",
        help="Candidate construction policy",
    )
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
        raise ExperimentError(
            "No eligible source rows were found. Try --allow-incorrect-source or a larger source JSONL."
        )

    catalog = load_species_catalog(DB_PATH)
    by_latin = species_index(catalog)
    baseline_module = load_candidate_ranking_module() if args.selection_mode == "baseline-original" else None

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

        if args.selection_mode == "baseline-original":
            original_candidates = baseline_original_candidates(baseline_module, DB_PATH, first_call, args.candidate_top_k)
            candidate_mode = "baseline-original"
        else:
            original_candidates = [
                make_candidate_row(candidate, rank, target)
                for rank, candidate in enumerate(
                    select_far_separated_candidates(target, catalog, args.candidate_top_k, seed=args.seed + source_index),
                    1,
                )
            ]
            candidate_mode = "far-separated"

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
                "candidate_selection_mode": candidate_mode,
                "original_candidates": original_candidates,
                "metadata": {
                    "source_jsonl": str(source_path),
                    "source_row_index": source_index,
                    "seed": args.seed,
                    "candidate_top_k": args.candidate_top_k,
                    "selection_mode": candidate_mode,
                    "tool_call_args": first_call,
                    "source_model_answer": final,
                    "source_model_text": row.get("final_text", ""),
                    "source_species_ok": row.get("species_ok"),
                    "source_genus_ok": row.get("genus_ok"),
                    "source_visual_group": tool_calls[0].get("visualGroup", ""),
                    "frozen_at": str(date.today()),
                    "byproduct_of": "gemma4-baseline-failure-analysis-native",
                },
            }
        )

    write_jsonl(output_path, frozen)
    notes = []
    if skipped_missing_species:
        notes.append(f"{skipped_missing_species} rows missing species catalog matches")
    if skipped_empty_candidates:
        notes.append(f"{skipped_empty_candidates} rows missing tool_call_args")
    suffix = f" ({'; '.join(notes)})" if notes else ""
    print(f"Wrote {len(frozen)} frozen examples to {output_path}{suffix}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
