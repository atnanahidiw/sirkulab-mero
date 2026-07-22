#!/usr/bin/env python3
"""Analysis over `03_reflective_iteration.py`'s six-condition traces.

No model runs here — pure Python over the per-condition JSONL, in the same
"join prior runs and derive the rest offline" style as
`../gemma-improve-detection/analyze_soft_gate_failures.py` and `01_revision_analysis.py`.

Primary comparison (pre-registered per the plan): structured-reflection-retained-pool
versus a *fresh* plain-two-call run from this same session, using an exact two-sided
McNemar test and a bootstrap interval clustered by species (resampling species, not
images, so images from the same species do not count as independent evidence). All
other condition pairs against plain-two-call are secondary and Holm-corrected.

Also reports, where the traces contain it: candidate availability in Search 1, Search 2,
and their union; accuracy conditional on union availability; revision-reason and
protocol-error breakdowns; whether Gemma's final answer kept its own provisional pick;
and mean searches, tool calls, and per-image latency per condition.

Writes `analysis_summary.json` inside the manifest-pinned run directory.

Run (no GPU or model needed, only the traces from 03_reflective_iteration.py):
  python3 scripts/agent-loop-evaluation/04_reflective_iteration_analysis.py \
      --run-dir outputs/agent-loop-evaluation/reflective-iteration/<run-id>
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import random
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
OUT_DIR = APP_REPO / "outputs" / "agent-loop-evaluation"
RUNNER_PATH = HERE.parent / "03_reflective_iteration.py"
PRIMARY_CONDITION = "structured-reflection-retained-pool"
CONTROL_CONDITION = "plain-two-call"
SECONDARY_CONDITIONS = ["instrumented-two-call", "prompt-only-reflection", "structured-reflection"]
DEFAULT_BOOTSTRAP_SAMPLES = 10000


def sha256_file(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with Path(path).open("rb") as f:
        for chunk in iter(lambda: f.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_recorded_sources(manifest):
    mismatches = []
    for relative, expected in manifest.get("sources", {}).items():
        path = APP_REPO / relative
        if not path.is_file() or sha256_file(path) != expected:
            mismatches.append(relative)
    if mismatches:
        raise RuntimeError(f"current analysis/code differs from run manifest: {mismatches}")


def validate_robustness_identities(primary_manifest, robustness_manifests):
    run_ids = [primary_manifest["run_id"]] + [m["run_id"] for m in robustness_manifests]
    seeds = [primary_manifest["sampler"]["seed"]] + [m["sampler"]["seed"] for m in robustness_manifests]
    if len(set(run_ids)) != len(run_ids):
        raise ValueError("primary and robustness run IDs must be distinct")
    if len(set(seeds)) != len(seeds):
        raise ValueError("primary and robustness seeds must be distinct")


def load_runner_module():
    spec = importlib.util.spec_from_file_location("reflective_iteration", RUNNER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_jsonl(path, run_id=None, condition=None):
    if not Path(path).exists():
        return []
    by_image = {}
    with Path(path).open() as f:
        for line_number, line in enumerate(f, 1):
            row = json.loads(line)
            if run_id and row.get("run_id") != run_id:
                raise RuntimeError(f"run mismatch in {path}:{line_number}")
            if condition and row.get("condition") != condition:
                raise RuntimeError(f"condition mismatch in {path}:{line_number}")
            image = row["image"]
            if image in by_image:
                raise RuntimeError(f"duplicate image {image!r} in {path}")
            by_image[image] = row
    return list(by_image.values())


def load_condition_rows(run_dir, condition, run_id, tag="", shards=0):
    """Load one condition from either an unsharded/tagged file or every shard."""
    if shards:
        rows = []
        for index in range(shards):
            rows.extend(load_jsonl(Path(run_dir) / f"{condition}_shard{index}of{shards}.jsonl",
                                   run_id, condition))
        images = [row["image"] for row in rows]
        if len(images) != len(set(images)):
            raise RuntimeError(f"duplicate images across {condition} shard files")
        return rows
    return load_jsonl(Path(run_dir) / f"{condition}{tag}.jsonl", run_id, condition)


def validate_rows_against_manifest(rows, manifest):
    expected_labels = {row["image"]: row["true"] for row in manifest["images"]}
    for row in rows:
        if expected_labels.get(row["image"]) != row.get("true"):
            raise RuntimeError(f"trace label differs from manifest for {row.get('image')!r}")


def percentile(sorted_values, fraction):
    if not sorted_values:
        return None
    if len(sorted_values) == 1:
        return float(sorted_values[0])
    index = fraction * (len(sorted_values) - 1)
    lower = int(index)
    upper = min(lower + 1, len(sorted_values) - 1)
    weight = index - lower
    return float(sorted_values[lower] * (1.0 - weight) + sorted_values[upper] * weight)


def mcnemar_exact(control_correct, condition_correct):
    """Exact two-sided McNemar (sign test on discordant pairs) — no scipy dependency."""
    b01 = sum(1 for a, b in zip(control_correct, condition_correct) if not a and b)
    b10 = sum(1 for a, b in zip(control_correct, condition_correct) if a and not b)
    n = b01 + b10
    if n == 0:
        return {"b01": b01, "b10": b10, "n_discordant": 0, "p_value": 1.0}
    k = min(b01, b10)
    p = min(1.0, 2.0 * sum(math.comb(n, i) for i in range(k + 1)) * (0.5 ** n))
    return {"b01": b01, "b10": b10, "n_discordant": n, "p_value": p}


def species_clustered_bootstrap_diff_ci(paired_rows, seed, samples):
    """Resample species (not images) with replacement, so same-species images are not
    treated as independent evidence."""
    by_species = defaultdict(list)
    for r in paired_rows:
        by_species[r["species"]].append(r)
    species_list = sorted(by_species)
    n = len(paired_rows)
    if not species_list or n == 0:
        return {"diff": None, "ci_lower": None, "ci_upper": None, "bootstrap_samples": 0}
    rng = random.Random(seed)
    diffs = []
    for _ in range(samples):
        pooled = []
        for _ in species_list:
            pooled.extend(by_species[rng.choice(species_list)])
        if not pooled:
            continue
        control_acc = sum(r["control_correct"] for r in pooled) / len(pooled)
        condition_acc = sum(r["condition_correct"] for r in pooled) / len(pooled)
        diffs.append(condition_acc - control_acc)
    diffs.sort()
    observed = (sum(r["condition_correct"] for r in paired_rows) / n
                - sum(r["control_correct"] for r in paired_rows) / n)
    return {"diff": observed, "ci_lower": percentile(diffs, 0.025), "ci_upper": percentile(diffs, 0.975),
            "bootstrap_samples": len(diffs)}


def holm_correction(named_pvalues):
    """Holm-Bonferroni step-down adjustment. named_pvalues: list of (name, p)."""
    ordered = sorted(named_pvalues, key=lambda item: item[1])
    m = len(ordered)
    adjusted = {}
    running_max = 0.0
    for i, (name, p) in enumerate(ordered):
        running_max = max(running_max, min(1.0, (m - i) * p))
        adjusted[name] = running_max
    return adjusted


def paired_comparison(control_rows, condition_rows):
    control_by_image = {r["image"]: r for r in control_rows}
    condition_by_image = {r["image"]: r for r in condition_rows}
    shared = sorted(set(control_by_image) & set(condition_by_image))
    paired_rows = [{
        "image": k, "species": control_by_image[k]["true"],
        "control_correct": bool(control_by_image[k]["species_ok"]),
        "condition_correct": bool(condition_by_image[k]["species_ok"]),
    } for k in shared]
    if not paired_rows:
        return None
    n = len(paired_rows)
    control_acc = sum(r["control_correct"] for r in paired_rows) / n
    condition_acc = sum(r["condition_correct"] for r in paired_rows) / n
    valid_pairs = [r for r in paired_rows if not control_by_image[r["image"]].get("protocol_failure")
                   and not condition_by_image[r["image"]].get("protocol_failure")]
    valid_diff = None
    if valid_pairs:
        valid_diff = (sum(r["condition_correct"] for r in valid_pairs) / len(valid_pairs)
                      - sum(r["control_correct"] for r in valid_pairs) / len(valid_pairs)) * 100
    latency_ratios = []
    for key in shared:
        control_latency = control_by_image[key].get("latency_seconds")
        condition_latency = condition_by_image[key].get("latency_seconds")
        if control_latency and condition_latency is not None:
            latency_ratios.append(condition_latency / control_latency)
    return {
        "n": n, f"{CONTROL_CONDITION}_accuracy": control_acc, "condition_accuracy": condition_acc,
        "accuracy_diff_pp": (condition_acc - control_acc) * 100,
        "mcnemar": mcnemar_exact([r["control_correct"] for r in paired_rows],
                                 [r["condition_correct"] for r in paired_rows]),
        "species_clustered_bootstrap": species_clustered_bootstrap_diff_ci(paired_rows, seed=31415926,
                                                                            samples=DEFAULT_BOOTSTRAP_SAMPLES),
        "protocol_clean": {"n": len(valid_pairs), "accuracy_diff_pp": valid_diff},
        "paired_median_latency_increase_pct": ((percentile(sorted(latency_ratios), 0.5) - 1) * 100
                                                if latency_ratios else None),
    }


# ── reflection-specific analysis (conditions with tool-call "searches" traces) ──
def true_in_candidates(candidates, true_latin):
    return any(c.get("scientific_name") == true_latin for c in (candidates or []))


def availability_breakdown(rows):
    counts = Counter()
    correct_counts = Counter()
    for r in rows:
        searches = r.get("searches") or {}
        search_ids = list(searches.keys())
        s1_candidates = searches.get(search_ids[0], {}).get("candidates") if search_ids else []
        s2_candidates = searches.get(search_ids[1], {}).get("candidates") if len(search_ids) > 1 else []
        true_latin = r["true"]
        in_s1 = true_in_candidates(s1_candidates, true_latin)
        in_s2 = true_in_candidates(s2_candidates, true_latin)
        bucket = "available in union" if (in_s1 or in_s2) else "never available"
        counts[bucket] += 1
        correct_counts[bucket] += int(bool(r.get("species_ok")))
        counts["available in search 1"] += int(in_s1)
        correct_counts["available in search 1"] += int(in_s1 and r.get("species_ok"))
        if search_ids and len(search_ids) > 1:
            counts["available in search 2"] += int(in_s2)
            correct_counts["available in search 2"] += int(in_s2 and r.get("species_ok"))
    return {
        key: {"n": n, "correct": correct_counts[key], "accuracy": correct_counts[key] / n if n else 0.0}
        for key, n in counts.items()
    }


def revision_reason_breakdown(rows):
    counts = Counter()
    correct_counts = Counter()
    for r in rows:
        reflection = r.get("reflection")
        reason = (reflection or {}).get("revision_reason") if reflection else "no_revision"
        counts[reason] += 1
        correct_counts[reason] += int(bool(r.get("species_ok")))
    return {
        key: {"n": n, "correct": correct_counts[key], "accuracy": correct_counts[key] / n if n else 0.0}
        for key, n in counts.items()
    }


def contrast_sufficiency_breakdown(rows):
    counts = Counter()
    correct_counts = Counter()
    challenger_ranks = Counter()
    for row in rows:
        inspections = row.get("inspections") or {}
        if not inspections:
            bucket = "not_inspected"
        else:
            inspection = next(iter(inspections.values()))
            bucket = "sufficient" if inspection.get("contrast_sufficient") else "insufficient"
            searches = row.get("searches") or {}
            first = next(iter(searches.values()), {})
            candidate_ids = [candidate.get("species_id") for candidate in first.get("candidates", [])]
            challenger = inspection.get("challenger_species_id")
            rank = candidate_ids.index(challenger) + 1 if challenger in candidate_ids else None
            challenger_ranks[str(rank) if rank is not None else "missing"] += 1
        counts[bucket] += 1
        correct_counts[bucket] += int(bool(row.get("species_ok")))
    return {
        "accuracy": {key: {"n": n, "correct": correct_counts[key],
                           "accuracy": correct_counts[key] / n if n else 0.0}
                     for key, n in counts.items()},
        "challenger_rank_counts": dict(challenger_ranks),
    }


def provisional_kept_breakdown(runner, rows, db_path):
    """Whether the final answer matches Gemma's own provisional species pick, where one
    was recorded. Descriptive only — this is not a pass-by-pass correctness trace."""
    import sqlite3
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    try:
        id_to_latin = {row["id"]: row["latin_name"] for row in con.execute("SELECT id, latin_name FROM species")}
    finally:
        con.close()

    counts = Counter()
    correct_counts = Counter()
    transitions = Counter()
    for r in rows:
        provisional_id = r.get("provisional_answer_species_id")
        if not provisional_id:
            counts["no_provisional_recorded"] += 1
            correct_counts["no_provisional_recorded"] += int(bool(r.get("species_ok")))
            continue
        provisional_latin = id_to_latin.get(provisional_id)
        final = r.get("final") or {}
        final_latin = final.get("scientific_name", "")
        kept = bool(provisional_latin) and provisional_latin.strip().lower() == str(final_latin).strip().lower()
        bucket = "final_matches_provisional" if kept else "final_differs_from_provisional"
        counts[bucket] += 1
        correct_counts[bucket] += int(bool(r.get("species_ok")))
        provisional_correct = bool(provisional_latin) and provisional_latin.strip().lower() == str(r["true"]).strip().lower()
        final_correct = bool(r.get("species_ok"))
        transitions[f"provisional_{'correct' if provisional_correct else 'wrong'}_to_final_{'correct' if final_correct else 'wrong'}"] += 1
    return {"final_choice": {
        key: {"n": n, "correct": correct_counts[key], "accuracy": correct_counts[key] / n if n else 0.0}
        for key, n in counts.items()
    }, "provisional_to_final": dict(transitions)}


def protocol_error_summary(rows):
    error_counts = Counter()
    rows_with_any_error = 0
    for r in rows:
        errors = r.get("protocol_errors") or []
        if errors:
            rows_with_any_error += 1
        for e in errors:
            error_counts[e] += 1
    n = len(rows)
    return {"rows_with_any_protocol_error": rows_with_any_error,
            "protocol_error_rate": rows_with_any_error / n if n else 0.0,
            "error_counts": dict(error_counts)}


def cost_summary(rows):
    n = len(rows)
    if not n:
        return {"n": 0}
    latencies = [r["latency_seconds"] for r in rows if r.get("latency_seconds") is not None]
    return {
        "n": n,
        "mean_passes": sum(r.get("passes", 0) for r in rows) / n,
        "mean_tool_calls": sum(r.get("tool_calls", 0) for r in rows) / n,
        "mean_attempted_tool_calls": sum(r.get("attempted_tool_calls") or 0 for r in rows) / n,
        "mean_latency_seconds": sum(latencies) / len(latencies) if latencies else None,
        "median_latency_seconds": percentile(sorted(latencies), 0.5) if latencies else None,
        "latency_n": len(latencies),
        "schema_valid_rate": sum(bool(r.get("schema_valid")) for r in rows) / n,
        "schema_and_protocol_clean_rate": sum(bool(r.get("schema_valid")) and
                                               not bool(r.get("protocol_failure")) for r in rows) / n,
        "protocol_failure_rate": sum(bool(r.get("protocol_failure")) for r in rows) / n,
        "max_executed_searches": max((r.get("passes", 0) for r in rows), default=0),
    }


def revision_quality_summary(runner, rows):
    revised = [r for r in rows if len((r.get("searches") or {})) >= 2]
    materially_changed = 0
    duplicate_executed = 0
    for r in revised:
        searches = list((r.get("searches") or {}).values())
        hashes = [runner.normalize_query(s.get("args") or {}) for s in searches]
        duplicate_executed += int(len(hashes) != len(set(hashes)))
        materially_changed += int(len(hashes) >= 2 and hashes[0] != hashes[1])
    return {"attempted_revisions": sum(r.get("attempted_reflections") or 0 for r in rows),
            "executed_revisions": len(revised),
            "materially_changed_rate": materially_changed / len(revised) if revised else None,
            "duplicate_executed_searches": duplicate_executed,
            "duplicate_executed_rate": duplicate_executed / len(revised) if revised else 0.0}


def paired_transitions(rows_a, rows_b, name_a, name_b):
    a = {r["image"]: r for r in rows_a}; b = {r["image"]: r for r in rows_b}
    counts = Counter()
    for image in set(a) & set(b):
        counts[f"{name_a}_{'correct' if a[image].get('species_ok') else 'wrong'}_to_{name_b}_{'correct' if b[image].get('species_ok') else 'wrong'}"] += 1
    return dict(counts)


def assert_shared_structured_traces(rows_a, rows_b):
    a = {r["image"]: r for r in rows_a}; b = {r["image"]: r for r in rows_b}
    mismatches = [image for image in set(a) & set(b)
                  if not a[image].get("structured_trace_id")
                  or a[image].get("structured_trace_id") != b[image].get("structured_trace_id")]
    if mismatches:
        raise RuntimeError(f"retention conditions do not share identical deliberation traces: {mismatches[:5]}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--run-dir", required=True, help="Manifest-pinned run directory written by runner 03")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--tag", default="", help="Shard tag suffix, matching 03_reflective_iteration.py")
    ap.add_argument("--shards", type=int, default=0,
                    help="Merge all i/n runner outputs for n shards, e.g. --shards 3")
    ap.add_argument("--allow-partial", action="store_true", help="Analyze a smoke/partial run as exploratory")
    ap.add_argument("--robustness-run-dir", action="append", default=[],
                    help="Additional complete run directory; pass exactly twice for promotion gate 3")
    args = ap.parse_args()
    if args.shards and args.tag:
        raise SystemExit("use either --shards to merge a full run or --tag for one exploratory shard, not both")
    if args.shards == 1 or args.shards < 0:
        raise SystemExit("--shards must be 0 (unsharded) or at least 2")

    runner = load_runner_module()
    out_dir = Path(args.run_dir)
    manifest_path = out_dir / "manifest.json"
    if not manifest_path.exists():
        raise SystemExit(f"missing manifest: {manifest_path}")
    manifest = json.loads(manifest_path.read_text())
    verify_recorded_sources(manifest)
    db_path = Path(args.db).expanduser().resolve()
    if not db_path.is_file() or sha256_file(db_path) != manifest["database"]["sha256"]:
        raise SystemExit("--db does not match the database recorded in the run manifest")
    run_id = manifest["run_id"]
    expected_images = {r["image"] for r in manifest["images"]}

    all_conditions = [PRIMARY_CONDITION, CONTROL_CONDITION] + SECONDARY_CONDITIONS + ["fixed-retrieval"]
    rows_by_condition = {}
    for condition in all_conditions:
        rows = load_condition_rows(out_dir, condition, run_id, args.tag, args.shards)
        if rows:
            validate_rows_against_manifest(rows, manifest)
            actual_images = {r["image"] for r in rows}
            if actual_images != expected_images and not args.allow_partial:
                raise SystemExit(f"incomplete {condition}: {len(actual_images)}/{len(expected_images)} images; "
                                 "use --allow-partial only for exploratory smoke analysis")
            rows_by_condition[condition] = rows
        else:
            print(f"[{condition}] no trace, skipping")
    if not args.allow_partial and (CONTROL_CONDITION not in rows_by_condition or PRIMARY_CONDITION not in rows_by_condition):
        raise SystemExit(f"complete analysis requires {CONTROL_CONDITION} and {PRIMARY_CONDITION}")

    payload = {"run_id": run_id, "exploratory_partial": bool(args.allow_partial),
               "cost_summary": {c: cost_summary(rows) for c, rows in rows_by_condition.items()}}

    if CONTROL_CONDITION in rows_by_condition:
        control_rows = rows_by_condition[CONTROL_CONDITION]

        primary = None
        if PRIMARY_CONDITION in rows_by_condition:
            primary = paired_comparison(control_rows, rows_by_condition[PRIMARY_CONDITION])
        payload["primary_comparison"] = {"condition": PRIMARY_CONDITION, "control": CONTROL_CONDITION, "result": primary}

        secondary = {}
        for condition in SECONDARY_CONDITIONS:
            if condition in rows_by_condition:
                secondary[condition] = paired_comparison(control_rows, rows_by_condition[condition])
        named_pvalues = [(name, r["mcnemar"]["p_value"]) for name, r in secondary.items() if r]
        holm_adjusted = holm_correction(named_pvalues) if named_pvalues else {}
        for name, r in secondary.items():
            if r:
                r["mcnemar"]["holm_adjusted_p_value"] = holm_adjusted.get(name)
        payload["secondary_comparisons"] = secondary

        if "instrumented-two-call" in secondary and secondary["instrumented-two-call"]:
            diff_pp = secondary["instrumented-two-call"]["accuracy_diff_pp"]
            payload["condition_3_parity_gate"] = {
                "accuracy_diff_pp": diff_pp,
                "note": ("Condition 3 changes only the tool's wire format relative to Condition 2; "
                         "this should be close to zero. Investigate before trusting conditions 4-6 if not."),
            }

    reflection_conditions = ["instrumented-two-call", "prompt-only-reflection",
                              PRIMARY_CONDITION, "structured-reflection"]
    payload["reflection_specific"] = {}
    for condition in reflection_conditions:
        if condition not in rows_by_condition:
            continue
        rows = rows_by_condition[condition]
        payload["reflection_specific"][condition] = {
            "candidate_availability": availability_breakdown(rows),
            "protocol_errors": protocol_error_summary(rows),
            "revision_quality": revision_quality_summary(runner, rows),
        }
        if condition in ("structured-reflection", PRIMARY_CONDITION):
            payload["reflection_specific"][condition]["revision_reason"] = revision_reason_breakdown(rows)
            payload["reflection_specific"][condition]["provisional_kept"] = provisional_kept_breakdown(runner, rows, args.db)
            payload["reflection_specific"][condition]["contrast_sufficiency"] = contrast_sufficiency_breakdown(rows)

    if "structured-reflection" in rows_by_condition and PRIMARY_CONDITION in rows_by_condition:
        assert_shared_structured_traces(rows_by_condition["structured-reflection"],
                                        rows_by_condition[PRIMARY_CONDITION])
        payload["retention_transitions"] = paired_transitions(
            rows_by_condition["structured-reflection"], rows_by_condition[PRIMARY_CONDITION],
            "second_only", "retained")

    robustness_diffs = []
    robustness_manifests = []
    for robustness_dir_text in args.robustness_run_dir:
        robustness_dir = Path(robustness_dir_text)
        robustness_manifest = json.loads((robustness_dir / "manifest.json").read_text())
        robustness_manifests.append(robustness_manifest)
        verify_recorded_sources(robustness_manifest)
        comparable_keys = ("model", "database", "images_sha256", "sources", "prompt_hashes",
                           "tool_contract_sha256", "serializer_version", "max_searches", "max_tool_calls",
                           "runtime", "warmup")
        differences = [key for key in comparable_keys if robustness_manifest.get(key) != manifest.get(key)]
        sampler_a = {k: v for k, v in manifest["sampler"].items() if k != "seed"}
        sampler_b = {k: v for k, v in robustness_manifest["sampler"].items() if k != "seed"}
        if sampler_a != sampler_b:
            differences.append("sampler")
        if differences:
            raise SystemExit(f"non-comparable robustness run {robustness_dir}: {differences}")
        robustness_control = load_condition_rows(robustness_dir, CONTROL_CONDITION,
                                                 robustness_manifest["run_id"], shards=args.shards)
        robustness_primary = load_condition_rows(robustness_dir, PRIMARY_CONDITION,
                                                 robustness_manifest["run_id"], shards=args.shards)
        validate_rows_against_manifest(robustness_control, robustness_manifest)
        validate_rows_against_manifest(robustness_primary, robustness_manifest)
        expected = {r["image"] for r in robustness_manifest["images"]}
        if {r["image"] for r in robustness_control} != expected or {r["image"] for r in robustness_primary} != expected:
            raise SystemExit(f"incomplete robustness run: {robustness_dir}")
        result = paired_comparison(robustness_control, robustness_primary)
        robustness_diffs.append({"run_id": robustness_manifest["run_id"],
                                 "seed": robustness_manifest["sampler"]["seed"],
                                 "accuracy_diff_pp": result["accuracy_diff_pp"]})
    if robustness_manifests:
        validate_robustness_identities(manifest, robustness_manifests)
    payload["robustness_runs"] = robustness_diffs

    primary_result = payload.get("primary_comparison", {}).get("result")
    primary_cost = payload.get("cost_summary", {}).get(PRIMARY_CONDITION, {})
    revision_quality = payload.get("reflection_specific", {}).get(PRIMARY_CONDITION, {}).get("revision_quality", {})
    if primary_result:
        ci = primary_result["species_clustered_bootstrap"]
        clean_diff = primary_result["protocol_clean"]["accuracy_diff_pp"]
        latency_increase = primary_result["paired_median_latency_increase_pct"]
        gates = {
            "accuracy": primary_result["accuracy_diff_pp"] >= 5 and primary_result["mcnemar"]["p_value"] < 0.05
                        and ci["ci_lower"] is not None and ci["ci_lower"] > 0,
            "protocol_clean_gain": clean_diff is not None and clean_diff >= 3,
            "robustness": len(robustness_diffs) == 2 and all(r["accuracy_diff_pp"] > 0 for r in robustness_diffs),
            "schema_and_protocol_clean": primary_cost.get("schema_and_protocol_clean_rate", 0) >= 0.95,
            "search_budget": primary_cost.get("max_executed_searches", 999) <= 2,
            "duplicate_search": revision_quality.get("duplicate_executed_rate", 1) < 0.01,
            "latency": latency_increase is not None and latency_increase <= 35,
        }
        payload["promotion_gates"] = {"gates": gates, "all_pass": all(gates.values()) and not args.allow_partial}

    out_dir.mkdir(parents=True, exist_ok=True)
    summary_path = out_dir / "analysis_summary.json"
    payload["analysis_source_sha256"] = sha256_file(HERE)
    summary_path.write_text(json.dumps(payload, indent=2))

    print("cost summary:")
    for condition, s in payload["cost_summary"].items():
        if s.get("n"):
            lat = f"{s['mean_latency_seconds']:.2f}s" if s["mean_latency_seconds"] is not None else "n/a"
            print(f"  {condition:38s} n={s['n']:3d}  mean passes {s['mean_passes']:.2f}  mean latency {lat}")

    if payload.get("primary_comparison", {}).get("result"):
        r = payload["primary_comparison"]["result"]
        print(f"\nprimary: {CONTROL_CONDITION} {r[f'{CONTROL_CONDITION}_accuracy']:.1%} -> "
              f"{PRIMARY_CONDITION} {r['condition_accuracy']:.1%}  "
              f"({r['accuracy_diff_pp']:+.1f}pp, exact McNemar p={r['mcnemar']['p_value']:.4f})")
    else:
        print(f"\nno primary comparison yet — need both {CONTROL_CONDITION} and {PRIMARY_CONDITION} traces")

    for name, r in payload.get("secondary_comparisons", {}).items():
        if r:
            print(f"secondary {name}: {r['accuracy_diff_pp']:+.1f}pp  "
                  f"p={r['mcnemar']['p_value']:.4f}  holm-adjusted={r['mcnemar']['holm_adjusted_p_value']:.4f}")

    print(f"\nwrote {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
