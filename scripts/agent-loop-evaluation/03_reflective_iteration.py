#!/usr/bin/env python3
"""Phase 2 v2 — standalone staged native-tool reflection for Gemma 4 E2B.

This is a new standalone experiment script. It preserves the same six conditions,
retrieval, scorer, selectable CPU/GPU runtime, speculative decoding, manifests, resume
behavior, and analysis format. Only conditions 5/6 change: instead of exposing three
tools simultaneously in one automatic loop, Gemma receives one native action at each
explicit stage (search, inspect, revise), with one bounded repair attempt. Final selection
uses a candidate ID; canonical species fields are hydrated from SQLite.

The design follows the feedback-then-refine separation in Self-Refine/Reflexion and
LiteRT-LM's documented manual tool-calling API. The model still chooses every search
query, provisional/challenger pair, revision, and final candidate.

Run from the repository root:

  UV_CACHE_DIR=/tmp/mero-litert-uv-cache \\
  uv run --python .venv-export/bin/python \\
    scripts/agent-loop-evaluation/03_reflective_iteration.py \\
      --model-path ../sirkulab-mero-data/gemma-4-E2B-it.litertlm \\
      --backend gpu --vision-backend gpu \\
      --cache-dir /tmp/mero-litert-lm-cache \\
      --warmup-image web/icons/Icon-512.png
"""
from __future__ import annotations

import hashlib
import importlib.util
import inspect
import json
import os
import platform
import random
import sqlite3
import sys
import time
from datetime import date
from importlib import metadata
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
OUT_DIR = APP_REPO / "outputs" / "agent-loop-evaluation"
BASELINE_PATH = APP_REPO / "scripts" / "gemma-improve-detection" / "eval_gemma4_baseline.py"
ANALYSIS_PATH = HERE.parent / "old" / "04_reflective_iteration_analysis.py"
MODEL_DEFAULT = Path.home() / "Downloads/gemma-4-E2B-it.litertlm"


def load_baseline():
    spec = importlib.util.spec_from_file_location("gemma4_baseline_for_staged_reflection", BASELINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load baseline from {BASELINE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


baseline = load_baseline()

CONDITIONS = [
    "fixed-retrieval", "plain-two-call", "instrumented-two-call",
    "prompt-only-reflection", "structured-reflection",
    "structured-reflection-retained-pool",
]
MAX_SEARCHES = 2
MAX_TOOL_CALLS = 8
QUERY_KEYS = baseline.VF_KEYS + ["visualGroup", "taxClass", "taxOrder", "taxFamily", "taxGenus"]
FINAL_KEYS = {"genus", "common_name", "scientific_name", "confidence", "identification_notes", "is_endangered"}
CLEAR_VALUE = "__CLEAR__"
VALID_REVISION_REASONS = {
    "candidate_conflict", "visual_group_ambiguous", "retrieval_score_visual_mismatch", "retrieval_empty",
}

PROTOCOL_VERSION = "staged-reflection-v1"
MAX_STAGE_ATTEMPTS = 2
RESEARCH_SOURCES = {
    "litert_lm_manual_tool_calling":
        "https://github.com/google-ai-edge/LiteRT-LM/blob/main/docs/api/kotlin/getting_started.md",
    "self_refine": "https://arxiv.org/abs/2303.17651",
    "reflexion": "https://arxiv.org/abs/2303.11366",
    "react": "https://arxiv.org/abs/2210.03629",
}


def _coerce_int(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def sha256_file(path, chunk_size=1024 * 1024):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(chunk_size), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_json(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def package_version(name):
    try:
        return metadata.version(name)
    except metadata.PackageNotFoundError:
        return None


def version_tuple(value):
    return tuple(int(part) for part in str(value).split(".")[:3])


def runtime_backend(Backend, name):
    backend = getattr(Backend, name.upper())
    return backend() if isinstance(backend, type) else backend


def gpu_backend(Backend):
    """Compatibility helper retained for existing offline invariants."""
    return runtime_backend(Backend, "gpu")


def canonical_body_shape(body_shape, shape):
    return str(body_shape or shape or "").strip()


def balanced_species_samples(samples):
    """Select the first deterministic image for every species represented."""
    selected = []
    seen_species = set()
    for sample in samples:
        species = sample["sp"]
        if species in seen_species:
            continue
        seen_species.add(species)
        selected.append(sample)
    return selected


def normalize_query(args):
    return tuple(str(args.get(key, "")).strip().lower() for key in QUERY_KEYS)


def merge_query(previous, revision):
    merged = dict(previous)
    for key in QUERY_KEYS:
        if key not in revision:
            continue
        value = revision[key]
        merged[key] = "" if value is None or str(value).strip() == CLEAR_VALUE else str(value).strip()
    return merged


def changed_query_fields(previous, revised):
    return {key for key in QUERY_KEYS
            if str(previous.get(key, "")).strip().lower() != str(revised.get(key, "")).strip().lower()}


def attach_species_ids(connection, ranked):
    candidates = []
    for candidate in ranked:
        row = connection.execute("SELECT id FROM species WHERE latin_name = ?", (candidate["latin"],)).fetchone()
        candidates.append({**candidate, "species_id": row["id"] if row else None})
    return candidates


def compact_candidate(candidate):
    return {
        "species_id": candidate.get("species_id"),
        "scientific_name": candidate["latin"],
        "common_name": candidate["common"],
        "confidence": candidate["confidence"],
        "visual_features": candidate["visual_features"],
    }


def compute_discriminators(provisional, challenger, top_n=3):
    scored = []
    for field in baseline.VF_KEYS:
        left = (provisional[field] or "").strip()
        right = (challenger[field] or "").strip()
        if not left or not right:
            continue
        overlap = baseline.dice(baseline.tokens(left), baseline.tokens(right))
        scored.append({"field": field, "provisional": left, "challenger": right,
                       "difference_score": round((1.0 - overlap) * baseline.VF_WEIGHTS[field], 3)})
    scored.sort(key=lambda item: item["difference_score"], reverse=True)
    return scored[:top_n], len(scored)


class ReflectiveState:
    def __init__(self):
        self.executed_searches = 0
        self.attempted_tool_calls = 0
        self.attempted_reflections = 0
        self.searches = {}
        self.candidate_pool = {}
        self.inspections = {}
        self.provisional_answer = None
        self.reflection = None
        self.protocol_errors = []
        self.query_hashes = set()

    def record_search(self, args, candidates):
        self.executed_searches += 1
        search_id = f"s{self.executed_searches}"
        self.searches[search_id] = {"args": dict(args), "candidates": candidates}
        self.query_hashes.add(normalize_query(args))
        for rank, candidate in enumerate(candidates, 1):
            species_id = candidate.get("species_id")
            if species_id is None:
                continue
            entry = self.candidate_pool.setdefault(species_id, {
                "species_id": species_id, "scientific_name": candidate["latin"],
                "source_searches": [], "best_rank": rank,
                "best_confidence": candidate["confidence"],
            })
            entry["source_searches"].append(search_id)
            entry["best_rank"] = min(entry["best_rank"], rank)
            entry["best_confidence"] = max(entry["best_confidence"], candidate["confidence"])
        return search_id

    def to_trace(self):
        return {
            "searches": {search_id: {"args": search["args"],
                                      "candidates": [compact_candidate(c) for c in search["candidates"]]}
                         for search_id, search in self.searches.items()},
            "inspections": self.inspections,
            "provisional_answer_species_id": self.provisional_answer,
            "reflection": self.reflection,
            "protocol_errors": list(self.protocol_errors),
            "attempted_tool_calls": self.attempted_tool_calls,
            "attempted_reflections": self.attempted_reflections,
        }


def state_from_trace(row):
    trace = row.get("structured_deliberation_trace") or {}
    state = ReflectiveState()
    for expected_id, search in (trace.get("searches") or {}).items():
        candidates = [{"species_id": c.get("species_id"), "latin": c.get("scientific_name", ""),
                       "common": c.get("common_name", ""), "confidence": c.get("confidence", 0),
                       "visual_features": c.get("visual_features", "")}
                      for c in search.get("candidates", [])]
        if state.record_search(search.get("args") or {}, candidates) != expected_id:
            raise RuntimeError("non-contiguous structured search trace")
    state.inspections = dict(trace.get("inspections") or {})
    state.provisional_answer = trace.get("provisional_answer_species_id")
    state.reflection = trace.get("reflection")
    state.protocol_errors = list(trace.get("protocol_errors") or [])
    state.attempted_tool_calls = trace.get("attempted_tool_calls") or 0
    state.attempted_reflections = trace.get("attempted_reflections") or 0
    if not row.get("structured_trace_id") or sha256_json(state.to_trace()) != row["structured_trace_id"]:
        raise RuntimeError("completed row cannot reconstruct its structured trace")
    return state


def pool_response(state, retain_first):
    search_ids = list(state.searches)
    if not search_ids:
        return []

    def entry(candidate):
        aggregate = state.candidate_pool.get(candidate.get("species_id"), {})
        return {"species_id": candidate.get("species_id"), "scientific_name": candidate["latin"],
                "common_name": candidate["common"], "visual_features": candidate["visual_features"],
                "source_searches": aggregate.get("source_searches", []),
                "best_rank": aggregate.get("best_rank"),
                "best_confidence": aggregate.get("best_confidence")}

    latest = state.searches[search_ids[-1]]["candidates"]
    pool = [entry(candidate) for candidate in latest]
    if retain_first and len(search_ids) >= 2:
        seen = {candidate.get("species_id") for candidate in latest}
        for candidate in state.searches[search_ids[0]]["candidates"]:
            if candidate.get("species_id") is not None and candidate.get("species_id") not in seen:
                seen.add(candidate["species_id"])
                pool.append(entry(candidate))
    return pool


def final_schema_errors(final, allowed_pool=None):
    if not isinstance(final, dict):
        return ["final_not_object"]
    errors = []
    if set(final) != FINAL_KEYS:
        errors.append("final_keys_mismatch")
    for key in ("genus", "common_name", "scientific_name", "confidence", "identification_notes"):
        if not isinstance(final.get(key), str):
            errors.append(f"final_{key}_not_string")
    if final.get("confidence") not in {"high", "medium", "low"}:
        errors.append("final_confidence_invalid")
    if type(final.get("is_endangered")) is not bool:
        errors.append("final_is_endangered_not_boolean")
    if allowed_pool is not None:
        identity = (baseline.norm(final.get("scientific_name")), baseline.norm(final.get("common_name")))
        allowed = {(baseline.norm(c.get("scientific_name")), baseline.norm(c.get("common_name")))
                   for c in allowed_pool}
        if identity not in allowed:
            errors.append("final_species_outside_presented_pool")
    return errors


# Required parameters produce a required OpenAPI schema in LiteRT-LM 0.14. `shape` is
# intentional: the real Gemma 4 runtime emitted this name even when v1 exposed
# `body_shape`; it is canonicalized before retrieval.
def search_similar_features(color: str, shape: str, distinctive_marks: str,
                            texture: str, size_class: str, pattern: str,
                            visualGroup: str, taxClass: str, taxOrder: str,
                            taxFamily: str, taxGenus: str) -> str:
    """Search the endangered-species database once using visible traits.

    Args:
        color: Visible colors, or an empty string.
        shape: Visible body shape, or an empty string.
        distinctive_marks: Visible identifying marks, or an empty string.
        texture: Visible texture, or an empty string.
        size_class: Estimated size class, or an empty string.
        pattern: Visible pattern, or an empty string.
        visualGroup: One valid broad visual group.
        taxClass: Taxonomic class guess, or an empty string.
        taxOrder: Taxonomic order guess, or an empty string.
        taxFamily: Taxonomic family guess, or an empty string.
        taxGenus: Taxonomic genus guess, or an empty string.
    """
    raise RuntimeError("manual tool execution only")


def inspect_candidate_differences(provisional_species_id: int,
                                  challenger_species_id: int) -> str:
    """Choose two different Search-1 candidate IDs for database contrast.

    Args:
        provisional_species_id: Best current candidate ID from the supplied list.
        challenger_species_id: Plausible alternative candidate ID from the supplied list.
    """
    raise RuntimeError("manual tool execution only")


def reflect_and_revise_search(provisional_species_id: int, challenger_species_id: int,
                              revision_reason: str, evidence_summary: str,
                              evidence_1_assessment: str, evidence_2_assessment: str,
                              evidence_3_assessment: str,
                              color: str, shape: str, distinctive_marks: str,
                              texture: str, size_class: str, pattern: str,
                              visualGroup: str, taxClass: str, taxOrder: str,
                              taxFamily: str, taxGenus: str) -> str:
    """Revise the query once after comparing image evidence with database evidence.

    Args:
        provisional_species_id: Provisional candidate ID, or zero if Search 1 was empty.
        challenger_species_id: Challenger candidate ID, or zero when unavailable.
        revision_reason: candidate_conflict, visual_group_ambiguous,
            retrieval_score_visual_mismatch, or retrieval_empty.
        evidence_summary: Short visible comparison; do not provide hidden reasoning.
        evidence_1_assessment: supports_provisional, supports_challenger, unclear,
            or not_available.
        evidence_2_assessment: supports_provisional, supports_challenger, unclear,
            or not_available.
        evidence_3_assessment: supports_provisional, supports_challenger, unclear,
            or not_available.
        color: Revised color; empty retains Search 1 and __CLEAR__ removes it.
        shape: Revised body shape; empty retains Search 1 and __CLEAR__ removes it.
        distinctive_marks: Revised marks; empty retains Search 1 and __CLEAR__ removes it.
        texture: Revised texture; empty retains Search 1 and __CLEAR__ removes it.
        size_class: Revised size; empty retains Search 1 and __CLEAR__ removes it.
        pattern: Revised pattern; empty retains Search 1 and __CLEAR__ removes it.
        visualGroup: Revised valid visual group; empty retains and __CLEAR__ removes it.
        taxClass: Revised class; empty retains and __CLEAR__ removes it.
        taxOrder: Revised order; empty retains and __CLEAR__ removes it.
        taxFamily: Revised family; empty retains and __CLEAR__ removes it.
        taxGenus: Revised genus; empty retains and __CLEAR__ removes it.
    """
    raise RuntimeError("manual tool execution only")


STAGED_SYSTEM = """You are a precise biological identification agent.

You will receive exactly one available tool at each stage. Call that tool exactly once
using only IDs and values supplied or visible to you. Do not output a final species until
the separate selection stage. Keep evidence summaries short and observable; do not emit
private chain-of-thought."""

STAGED_SELECTION_SYSTEM = """You are selecting one species from a frozen candidate pool.

Compare the image only with the supplied candidates. Output ONLY this JSON:
{"species_id":123,"confidence":"high|medium|low","identification_notes":"short visible evidence"}
Never invent an ID and never select outside the supplied pool."""


def response_text(response):
    return response.get("content", [{}])[0].get("text", str(response))


def tool_call_arguments(response, expected_name):
    calls = response.get("tool_calls") or []
    if len(calls) != 1:
        return None, f"expected exactly one {expected_name} call, received {len(calls)}"
    function = calls[0].get("function") or {}
    if function.get("name") != expected_name:
        return None, f"expected {expected_name}, received {function.get('name')!r}"
    args = function.get("arguments")
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except json.JSONDecodeError:
            return None, "tool arguments were not valid JSON"
    if not isinstance(args, dict):
        return None, "tool arguments were not an object"
    return args, None


def request_valid_tool_call(engine, cfg, image_path, tool, expected_name, prompt, validate):
    """Request one native action, allowing one explicit feedback-and-repair attempt."""
    attempts = []
    error = None
    for attempt in range(MAX_STAGE_ATTEMPTS):
        attempt_prompt = prompt
        if error:
            attempt_prompt += ("\n\nYour previous action was rejected: " + error +
                               "\nCall the available tool once with corrected arguments.")
        with engine.create_conversation(system_message=STAGED_SYSTEM, tools=[tool],
                                        sampler_config=cfg, automatic_tool_calling=False) as conv:
            response = conv.send_message({"role": "user", "content": [
                {"type": "text", "text": attempt_prompt},
                {"type": "image", "path": str(image_path)},
            ]})
        args, parse_error = tool_call_arguments(response, expected_name)
        error = parse_error or (validate(args) if args is not None else parse_error)
        attempts.append({"attempt": attempt + 1, "response": response, "error": error})
        if error is None:
            return args, attempts
    return None, attempts


def canonical_query(args):
    visual_group = str(args.get("visualGroup", "")).strip()
    visual_group = {baseline.norm(group): group for group in baseline.VISUAL_GROUPS.split(", ")}.get(
        baseline.norm(visual_group), visual_group)
    return {
        "color": str(args.get("color", "")).strip(),
        "body_shape": canonical_body_shape(args.get("body_shape", ""), args.get("shape", "")),
        "distinctive_marks": str(args.get("distinctive_marks", "")).strip(),
        "texture": str(args.get("texture", "")).strip(),
        "size_class": str(args.get("size_class", "")).strip(),
        "pattern": str(args.get("pattern", "")).strip(),
        "visualGroup": visual_group,
        "taxClass": str(args.get("taxClass", "")).strip(),
        "taxOrder": str(args.get("taxOrder", "")).strip(),
        "taxFamily": str(args.get("taxFamily", "")).strip(),
        "taxGenus": str(args.get("taxGenus", "")).strip(),
    }


def run_search(query):
    con = sqlite3.connect(baseline._DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        return attach_species_ids(con, baseline._run_search(con, query, top_k=5))
    finally:
        con.close()


def apply_inspection(state, provisional_id, challenger_id):
    con = sqlite3.connect(baseline._DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        row_p = con.execute("SELECT * FROM species WHERE id = ?", (provisional_id,)).fetchone()
        row_c = con.execute("SELECT * FROM species WHERE id = ?", (challenger_id,)).fetchone()
    finally:
        con.close()
    discriminators, usable_fields = compute_discriminators(row_p, row_c)
    evidence = {}
    for index, discriminator in enumerate(discriminators, 1):
        evidence_id = f"db_ev_{index}"
        discriminator["evidence_id"] = evidence_id
        evidence[evidence_id] = {
            "field": discriminator["field"],
            "provisional": discriminator["provisional"],
            "challenger": discriminator["challenger"],
        }
    state.provisional_answer = provisional_id
    state.inspection_used = True
    state.inspections["i1"] = {
        "provisional_species_id": provisional_id,
        "challenger_species_id": challenger_id,
        "evidence": evidence,
        "contrast_sufficient": usable_fields >= 2,
    }
    return discriminators


def run_staged_deliberation(engine, cfg, image_path, unused_system_message):
    state = ReflectiveState()
    stage_log = {}

    def validate_search(args):
        if not isinstance(args, dict):
            return "missing search arguments"
        query = canonical_query(args)
        if query["visualGroup"] not in baseline.VISUAL_GROUPS.split(", "):
            return "visualGroup must exactly match one allowed label"
        if not any(query[key] for key in baseline.VF_KEYS + ["visualGroup"]):
            return "at least one visual trait or visualGroup is required"
        return None

    search_prompt = (
        "Observe the image and call search_similar_features once. Use empty strings for "
        "uncertain fields. visualGroup must be one of: " + baseline.VISUAL_GROUPS
    )
    search_args, attempts = request_valid_tool_call(
        engine, cfg, image_path, search_similar_features, "search_similar_features",
        search_prompt, validate_search)
    stage_log["search"] = attempts
    state.attempted_tool_calls += sum(bool((a["response"].get("tool_calls") or [])) for a in attempts)
    if search_args is None:
        state.protocol_errors.append("staged_search_action_failed")
        return state, json.dumps(stage_log, sort_keys=True)
    search1 = run_search(canonical_query(search_args))
    state.record_search(canonical_query(search_args), search1)

    provisional_id = challenger_id = 0
    discriminators = []
    if len(search1) >= 2:
        candidate_view = [compact_candidate(candidate) for candidate in search1]
        valid_ids = {candidate["species_id"] for candidate in candidate_view}

        def validate_inspection(args):
            if not isinstance(args, dict):
                return "missing candidate IDs"
            provisional = _coerce_int(args.get("provisional_species_id"))
            challenger = _coerce_int(args.get("challenger_species_id"))
            if provisional not in valid_ids or challenger not in valid_ids:
                return f"both IDs must come from this list: {sorted(valid_ids)}"
            if provisional == challenger:
                return "provisional and challenger IDs must differ"
            return None

        inspect_prompt = (
            "Choose the best provisional candidate and one plausible challenger from this "
            "Search-1 list, then call inspect_candidate_differences once:\n" +
            json.dumps(candidate_view, sort_keys=True)
        )
        inspect_args, attempts = request_valid_tool_call(
            engine, cfg, image_path, inspect_candidate_differences,
            "inspect_candidate_differences", inspect_prompt, validate_inspection)
        stage_log["inspect"] = attempts
        state.attempted_tool_calls += sum(bool((a["response"].get("tool_calls") or [])) for a in attempts)
        if inspect_args is None:
            state.protocol_errors.append("staged_inspection_action_failed")
            return state, json.dumps(stage_log, sort_keys=True)
        provisional_id = _coerce_int(inspect_args["provisional_species_id"])
        challenger_id = _coerce_int(inspect_args["challenger_species_id"])
        discriminators = apply_inspection(state, provisional_id, challenger_id)
    elif len(search1) == 1:
        provisional_id = _coerce_int(search1[0].get("species_id")) or 0
        state.provisional_answer = provisional_id

    revision_payload = {}
    previous_query = state.searches["s1"]["args"]
    inspection = state.inspections.get("i1") or {}
    discriminator_fields = ({item["field"] for item in discriminators}
                            if inspection.get("contrast_sufficient") else set())
    valid_assessments = {"supports_provisional", "supports_challenger", "unclear"}

    def validate_revision(args):
        if not isinstance(args, dict):
            return "missing revision arguments"
        provisional = _coerce_int(args.get("provisional_species_id")) or 0
        challenger = _coerce_int(args.get("challenger_species_id")) or 0
        if provisional != provisional_id or challenger != challenger_id:
            return f"candidate IDs must remain provisional={provisional_id}, challenger={challenger_id}"
        reason = str(args.get("revision_reason", "")).strip()
        if reason not in VALID_REVISION_REASONS:
            return "revision_reason must use one documented enum value"
        if not search1 and reason != "retrieval_empty":
            return "an empty Search 1 requires retrieval_empty"
        if search1 and reason == "retrieval_empty":
            return "retrieval_empty is valid only for an empty Search 1"
        if len(search1) >= 2 and not str(args.get("evidence_summary", "")).strip():
            return "a short visible evidence_summary is required"
        assessments = []
        for index, discriminator in enumerate(discriminators, 1):
            assessment = str(args.get(f"evidence_{index}_assessment", "")).strip()
            if inspection.get("contrast_sufficient") and assessment not in valid_assessments:
                return (f"evidence_{index}_assessment must be one of "
                        f"{sorted(valid_assessments)}")
            if assessment and assessment not in valid_assessments | {"not_available"}:
                return f"evidence_{index}_assessment has an invalid value"
            if assessment in valid_assessments:
                assessments.append({"evidence_id": discriminator["evidence_id"],
                                    "assessment": assessment})
        for index in range(len(discriminators) + 1, 4):
            if str(args.get(f"evidence_{index}_assessment", "")).strip() not in {
                    "", "not_available"}:
                return f"evidence_{index}_assessment must be not_available"
        proposed = canonical_query(args)
        # Required empty strings mean retain; __CLEAR__ explicitly removes a field.
        delta = {key: value for key, value in proposed.items() if value}
        merged = merge_query(previous_query, delta)
        changed = changed_query_fields(previous_query, merged)
        if not changed:
            return "the revised query must materially change"
        if discriminator_fields and not (changed & discriminator_fields):
            return f"change at least one database discriminator: {sorted(discriminator_fields)}"
        if normalize_query(merged) in state.query_hashes:
            return "the revised query duplicates Search 1"
        revision_payload.update({"query": merged, "reason": reason,
                                 "evidence_summary": str(args.get("evidence_summary", "")).strip(),
                                 "assessments": assessments})
        return None

    revision_prompt = (
        "Call reflect_and_revise_search once. Keep empty fields unchanged and use __CLEAR__ "
        "only to remove a wrong field. Assess each numbered database discriminator against "
        "the visible image; use not_available for unused assessment slots. Candidate IDs are fixed at "
        f"provisional={provisional_id}, challenger={challenger_id}. Search 1 was:\n"
        + json.dumps({"query": previous_query,
                      "candidates": [compact_candidate(candidate) for candidate in search1],
                      "database_discriminators": discriminators}, sort_keys=True)
    )
    revision_args, attempts = request_valid_tool_call(
        engine, cfg, image_path, reflect_and_revise_search, "reflect_and_revise_search",
        revision_prompt, validate_revision)
    stage_log["revise"] = attempts
    state.attempted_tool_calls += sum(bool((a["response"].get("tool_calls") or [])) for a in attempts)
    state.attempted_reflections += len(attempts)
    if revision_args is None:
        state.protocol_errors.append("staged_revision_action_failed")
        return state, json.dumps(stage_log, sort_keys=True)

    state.reflection = {
        "revision_reason": revision_payload["reason"],
        "unresolved_discriminator": revision_payload["evidence_summary"],
        "image_evidence_assessments": revision_payload["assessments"],
        "stage_attempt_counts": {name: len(items) for name, items in stage_log.items()},
    }
    state.reflection_used = True
    state.record_search(revision_payload["query"], run_search(revision_payload["query"]))
    return state, json.dumps(stage_log, sort_keys=True)


def parse_selection(text, allowed_ids):
    parsed = baseline.parse_json(text)
    if not isinstance(parsed, dict):
        return None, "selection must be a JSON object"
    species_id = _coerce_int(parsed.get("species_id"))
    if species_id not in allowed_ids:
        return None, f"species_id must be one of {sorted(allowed_ids)}"
    if parsed.get("confidence") not in {"high", "medium", "low"}:
        return None, "confidence must be high, medium, or low"
    if not isinstance(parsed.get("identification_notes"), str) or not parsed["identification_notes"].strip():
        return None, "identification_notes must be a nonempty string"
    return parsed, None


def hydrate_final(selection):
    con = sqlite3.connect(baseline._DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        row = con.execute("SELECT * FROM species WHERE id = ?", (selection["species_id"],)).fetchone()
    finally:
        con.close()
    if row is None:
        raise RuntimeError(f"selected species ID disappeared from database: {selection['species_id']}")
    status = (row["conservation_status"] or "").lower()
    return {
        "genus": row["genus"],
        "common_name": row["common_name"],
        "scientific_name": row["latin_name"],
        "confidence": selection["confidence"],
        "identification_notes": selection["identification_notes"].strip(),
        "is_endangered": "endangered" in status,
    }


def run_staged_selection(engine, cfg, image_path, state, deliberation_text, retain_first_search):
    pool = pool_response(state, retain_first_search)
    allowed_ids = {candidate.get("species_id") for candidate in pool if candidate.get("species_id") is not None}
    prompt = json.dumps({
        "candidate_pool": pool,
        "pool_policy": "search_2_then_unique_search_1" if retain_first_search else "latest_search_only",
    }, sort_keys=True)
    raw_texts = []
    selection = None
    error = None
    with engine.create_conversation(system_message=STAGED_SELECTION_SYSTEM, sampler_config=cfg,
                                    automatic_tool_calling=False) as conv:
        for attempt in range(MAX_STAGE_ATTEMPTS):
            attempt_prompt = prompt if attempt == 0 else (
                f"Your previous selection was rejected: {error}. Select again from IDs {sorted(allowed_ids)}."
            )
            response = conv.send_message({"role": "user", "content": [
                {"type": "text", "text": attempt_prompt},
                {"type": "image", "path": str(image_path)},
            ]})
            text = response_text(response)
            raw_texts.append(text)
            selection, error = parse_selection(text, allowed_ids)
            if error is None:
                break
    final = hydrate_final(selection) if selection is not None else None
    trace = state.to_trace()
    return final, {
        "final_text": json.dumps(final) if final is not None else raw_texts[-1] if raw_texts else "",
        "selection_raw_texts": raw_texts,
        "deliberation_text": deliberation_text,
        "presented_candidate_pool": pool,
        "structured_deliberation_trace": trace,
        "structured_trace_id": sha256_json(trace),
        "tool_calls": [search["args"] for search in state.searches.values()],
        "passes": state.executed_searches,
        **trace,
    }


TRAITS_SYSTEM = """You are a precise biological observation engine.
Extract visible traits without identifying the species. Output ONLY this JSON:
{"color":"string","body_shape":"string","distinctive_marks":"string","texture":"string","size_class":"string","pattern":"string","visualGroup":"string","taxClass":"string","taxOrder":"string","taxFamily":"string","taxGenus":"string"}
Use one exact visualGroup from: %s. Use empty strings when uncertain.""" % baseline.VISUAL_GROUPS
TRAITS_PROMPT = "Extract visible traits from this image and output only the traits JSON."
FIXED_SELECTION_SYSTEM = """Choose the best species from the supplied database candidates.
Output ONLY this JSON:
{"genus":"string","common_name":"string","scientific_name":"string","confidence":"high|medium|low","identification_notes":"string","is_endangered":boolean}"""


def capped_system(cap, reflective=False):
    prompt = baseline.SYSTEM.replace(
        "STEP 5: If the tool returns no match OR confidence is low, your assumptions are "
        "WRONG — do NOT repeat the same genus/family/traits; pivot your hypothesis entirely and search again.",
        f"STEP 5: You may execute at most {cap} searches. Revise materially before Search 2.")
    prompt = prompt.replace("STEP 6: After at most 4 attempts, output your best guess.",
                            f"STEP 6: After at most {cap} searches, output your best guess.")
    if reflective:
        prompt += ("\nBefore Search 2, state a provisional candidate, a challenger, one visible uncertainty, "
                   "and revise a query field based on that uncertainty.")
    return prompt


def make_auto_search_tool(state, cap, envelope):
    def search_similar_features(color: str = "", body_shape: str = "", shape: str = "",
                                distinctive_marks: str = "", texture: str = "",
                                size_class: str = "", pattern: str = "", visualGroup: str = "",
                                taxClass: str = "", taxOrder: str = "", taxFamily: str = "",
                                taxGenus: str = "") -> str:
        """Search the endangered-species database using visible traits."""
        state.attempted_tool_calls += 1
        if state.attempted_tool_calls > MAX_TOOL_CALLS:
            state.protocol_errors.append("tool_call_budget_exceeded")
            return json.dumps({"status": "error", "reason": "tool_call_budget_exceeded"})
        if state.executed_searches >= cap:
            state.protocol_errors.append("search_budget_exceeded")
            return json.dumps({"status": "error", "reason": "search_budget_exhausted"})
        args = canonical_query(dict(
            color=color, body_shape=body_shape, shape=shape,
            distinctive_marks=distinctive_marks, texture=texture, size_class=size_class,
            pattern=pattern, visualGroup=visualGroup, taxClass=taxClass, taxOrder=taxOrder,
            taxFamily=taxFamily, taxGenus=taxGenus))
        ranked = run_search(args)
        search_id = state.record_search(args, ranked)
        if envelope:
            result = {"search_id": search_id, "candidates": [compact_candidate(c) for c in ranked]}
            if state.executed_searches == cap:
                result["instruction"] = "Search budget exhausted; output final JSON now."
            return json.dumps(result)
        text = baseline.format_tool_result(ranked)
        if state.executed_searches == cap:
            text += "\n\nSearch budget exhausted; output final JSON now."
        return text

    search_similar_features.__doc__ += f"\nvisualGroup must be one of: {baseline.VISUAL_GROUPS}."
    return search_similar_features


def run_fixed_retrieval(engine, cfg, image_path):
    with engine.create_conversation(system_message=TRAITS_SYSTEM, sampler_config=cfg,
                                    automatic_tool_calling=False) as conversation:
        response = conversation.send_message({"role": "user", "content": [
            {"type": "text", "text": TRAITS_PROMPT}, {"type": "image", "path": str(image_path)}]})
    traits_text = response_text(response)
    traits = baseline.parse_json(traits_text) or {}
    traits = canonical_query(traits)
    ranked = run_search(traits)
    candidate_text = baseline.format_tool_result(ranked)
    with engine.create_conversation(system_message=FIXED_SELECTION_SYSTEM, sampler_config=cfg,
                                    automatic_tool_calling=False) as conversation:
        response = conversation.send_message({"role": "user", "content": [
            {"type": "text", "text": candidate_text}, {"type": "image", "path": str(image_path)}]})
    final_text = response_text(response)
    return baseline.parse_json(final_text), {
        "final_text": final_text, "tool_calls": [traits], "passes": 1,
        "observed_traits": traits, "search_result": candidate_text,
    }


def run_auto_condition(engine, cfg, image_path, system_message, envelope):
    state = ReflectiveState()
    tool = make_auto_search_tool(state, MAX_SEARCHES, envelope)
    with engine.create_conversation(system_message=system_message, tools=[tool], sampler_config=cfg) as conversation:
        response = conversation.send_message({"role": "user", "content": [
            {"type": "text", "text": baseline.INPUT_PROMPT},
            {"type": "image", "path": str(image_path)}]})
    final_text = response_text(response)
    trace = state.to_trace()
    return baseline.parse_json(final_text), {
        "final_text": final_text, "tool_calls": [s["args"] for s in state.searches.values()],
        "passes": state.executed_searches, **trace,
    }


def run_condition(engine, cfg, condition, image_path, prompts):
    if condition == "fixed-retrieval":
        return run_fixed_retrieval(engine, cfg, image_path)
    if condition == "plain-two-call":
        return run_auto_condition(engine, cfg, image_path, prompts["plain"], False)
    if condition == "instrumented-two-call":
        return run_auto_condition(engine, cfg, image_path, prompts["instrumented"], True)
    if condition == "prompt-only-reflection":
        return run_auto_condition(engine, cfg, image_path, prompts["prompt_only"], True)
    if condition == "structured-reflection":
        state, text = run_staged_deliberation(engine, cfg, image_path, STAGED_SYSTEM)
        return run_staged_selection(engine, cfg, image_path, state, text, False)
    if condition == "structured-reflection-retained-pool":
        state, text = run_staged_deliberation(engine, cfg, image_path, STAGED_SYSTEM)
        return run_staged_selection(engine, cfg, image_path, state, text, True)
    raise ValueError(f"unknown condition {condition!r}")


def build_manifest(args, conditions, samples, data_repo, prompts):
    model_path = Path(args.model_path).expanduser().resolve()
    db_path = Path(args.db).expanduser().resolve()
    if not model_path.is_file() or not db_path.is_file():
        raise FileNotFoundError(f"model and DB must exist: {model_path}, {db_path}")
    images = [{"image": str(sample["path"].relative_to(data_repo)), "true": sample["sp"],
               "sha256": sha256_file(sample["path"])} for sample in samples]
    contract = "\n".join(inspect.getsource(function) for function in (
        search_similar_features, inspect_candidate_differences, reflect_and_revise_search,
        make_auto_search_tool, request_valid_tool_call, run_staged_deliberation,
        run_staged_selection, pool_response))
    manifest = {
        "schema_version": 3,
        "model": {"path": str(model_path), "sha256": sha256_file(model_path)},
        "database": {"path": str(db_path), "sha256": sha256_file(db_path)},
        "images": images, "images_sha256": sha256_json(images), "conditions": conditions,
        "sample_selection": ("one_image_per_species" if args.balanced_pilot else
                             "first_n" if args.limit else "complete_set"),
        "sampler": {"temperature": 0.3, "top_k": 64, "top_p": 0.85, "seed": args.seed},
        "runtime": {"python": sys.version, "platform": platform.platform(),
                    "packages": {name: package_version(name) for name in
                                 ("litert-lm", "litert-lm-api", "litert-lm-builder", "ai-edge-litert")},
                    "backend": args.backend, "vision_backend": args.vision_backend,
                    "speculative_decoding": True},
        "sources": {str(path.relative_to(APP_REPO)): sha256_file(path)
                    for path in (HERE, ANALYSIS_PATH, BASELINE_PATH)},
        "prompt_hashes": {name: hashlib.sha256(text.encode()).hexdigest()
                          for name, text in {**prompts, "structured": STAGED_SYSTEM,
                                             "selection": STAGED_SELECTION_SYSTEM}.items()},
        "tool_contract_sha256": hashlib.sha256(contract.encode()).hexdigest(),
        "serializer_version": "candidate-pool-v3-id-selection",
        "staged_protocol_version": PROTOCOL_VERSION,
        "research_sources": RESEARCH_SOURCES,
        "max_searches": MAX_SEARCHES, "max_tool_calls": MAX_TOOL_CALLS,
        "cache_dir": str(Path(args.cache_dir).expanduser().resolve()),
        "warmup": ({"skipped": True} if args.skip_warmup else
                   {"skipped": False, "path": str(Path(args.warmup_image).expanduser().resolve()),
                    "sha256": sha256_file(Path(args.warmup_image).expanduser())}),
    }
    manifest["run_id"] = sha256_json(manifest)
    return manifest


def load_done(path, run_id, condition):
    path = Path(path)
    if not path.exists():
        return {}
    raw = path.read_bytes()
    lines = raw.splitlines(keepends=True)
    done, valid = {}, []
    repaired = False
    for index, line in enumerate(lines):
        try:
            row = json.loads(line)
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            if index != len(lines) - 1:
                raise RuntimeError(f"malformed interior JSONL row in {path}:{index + 1}") from exc
            repaired = True
            break
        image = row.get("image")
        if not image or image in done:
            raise RuntimeError(f"missing or duplicate image in {path}:{index + 1}")
        if row.get("run_id") != run_id or row.get("condition") != condition:
            raise RuntimeError(f"resume manifest mismatch in {path}:{index + 1}")
        done[image] = row
        valid.append(line if line.endswith(b"\n") else line + b"\n")
    normalized = b"".join(valid)
    if repaired or normalized != raw:
        path.write_bytes(normalized)
    return done


def main():
    import argparse
    from litert_lm import Backend, Engine
    from litert_lm.interfaces import SamplerConfig

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model-path", default=str(MODEL_DEFAULT))
    parser.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    parser.add_argument("--images-subdir", default="data/raw/species_data_img")
    parser.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--balanced-pilot", action="store_true",
                        help="select one deterministic image per represented species")
    parser.add_argument("--seed", type=int, default=31415926)
    parser.add_argument("--cache-dir", default="/tmp/mero-litert-lm-cache")
    parser.add_argument("--backend", choices=("gpu", "cpu"), default="cpu",
                        help="language-model execution backend (default: cpu)")
    parser.add_argument("--vision-backend", choices=("gpu", "cpu"), default="cpu",
                        help="vision-encoder execution backend (default: cpu)")
    parser.add_argument("--warmup-image", default="")
    parser.add_argument("--skip-warmup", action="store_true")
    parser.add_argument("--shard", default="", help="i/n, e.g. 0/3")
    parser.add_argument("--conditions", default=",".join(CONDITIONS))
    args = parser.parse_args()

    conditions = [item.strip() for item in args.conditions.split(",") if item.strip()]
    if not conditions or any(condition not in CONDITIONS for condition in conditions):
        raise SystemExit(f"--conditions must select from {CONDITIONS}")
    runtime_version = package_version("litert-lm")
    if runtime_version is None or version_tuple(runtime_version) < (0, 14, 0):
        raise RuntimeError("LiteRT-LM >=0.14 is required; use .venv-export/bin/python")

    name_to_latin, truth = baseline.load_db(Path(args.db))
    baseline._DB_PATH = str(Path(args.db).resolve())
    all_samples = baseline.collect_images(Path(args.data_repo) / args.images_subdir, name_to_latin)
    manifest_samples = list(all_samples)
    if args.balanced_pilot and args.limit:
        raise SystemExit("--balanced-pilot and --limit are mutually exclusive")
    if args.balanced_pilot:
        manifest_samples = balanced_species_samples(manifest_samples)
        represented = {sample["sp"] for sample in all_samples}
        selected = {sample["sp"] for sample in manifest_samples}
        if selected != represented:
            raise RuntimeError("balanced pilot did not retain every represented species")
    if args.limit:
        if args.limit < 0:
            raise SystemExit("--limit must be non-negative")
        manifest_samples = manifest_samples[:args.limit]
    samples = list(manifest_samples)
    tag = ""
    if args.shard:
        try:
            shard_index, shard_count = (int(value) for value in args.shard.split("/"))
        except ValueError:
            raise SystemExit("--shard must use i/n syntax") from None
        if shard_count < 2 or not 0 <= shard_index < shard_count:
            raise SystemExit("--shard requires n >= 2 and 0 <= i < n")
        samples = samples[shard_index::shard_count]
        tag = f"_shard{shard_index}of{shard_count}"

    if args.skip_warmup:
        warmup_path = None
    else:
        if not args.warmup_image:
            raise SystemExit("--warmup-image is required unless --skip-warmup is used")
        warmup_path = Path(args.warmup_image).expanduser().resolve()
        if not warmup_path.is_file():
            raise SystemExit(f"warmup image does not exist: {warmup_path}")
        if warmup_path in {sample["path"].resolve() for sample in all_samples}:
            raise SystemExit("warmup image must be outside the complete evaluation set")

    prompts = {"plain": capped_system(2), "instrumented": capped_system(2),
               "prompt_only": capped_system(2, reflective=True)}
    config = SamplerConfig(temperature=0.3, top_k=64, top_p=0.85, seed=args.seed)
    data_repo = Path(args.data_repo)
    manifest = build_manifest(args, conditions, manifest_samples, data_repo, prompts)
    run_dir = OUT_DIR / "reflective-iteration" / manifest["run_id"][:16]
    run_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = run_dir / "manifest.json"
    if manifest_path.exists() and json.loads(manifest_path.read_text()) != manifest:
        raise RuntimeError(f"existing manifest differs: {manifest_path}")
    temporary_manifest = manifest_path.with_name(f".{manifest_path.name}.{os.getpid()}.tmp")
    temporary_manifest.write_text(json.dumps(manifest, indent=2))
    os.replace(temporary_manifest, manifest_path)

    expected_local = {str(sample["path"].relative_to(data_repo)) for sample in samples}
    done = {}
    for condition in conditions:
        output = run_dir / f"{condition}{tag}.jsonl"
        done[condition] = load_done(output, manifest["run_id"], condition)
        if set(done[condition]) - expected_local:
            raise RuntimeError(f"rows outside this worker's sample set: {output}")

    engine = None
    if any(len(done[condition]) < len(samples) for condition in conditions):
        cache_dir = Path(args.cache_dir).expanduser().resolve()
        cache_dir.mkdir(parents=True, exist_ok=True)
        backend = runtime_backend(Backend, args.backend)
        vision_backend = runtime_backend(Backend, args.vision_backend)
        engine = Engine(str(Path(args.model_path).expanduser()), backend=backend,
                        vision_backend=vision_backend, cache_dir=str(cache_dir),
                        enable_speculative_decoding=True)
        if warmup_path is not None:
            for condition in conditions:
                run_condition(engine, config, condition, warmup_path, prompts)

    structured_pair = {"structured-reflection", "structured-reflection-retained-pool"}
    for block_index, sample in enumerate(samples):
        image_key = str(sample["path"].relative_to(data_repo))
        order = list(conditions)
        random.Random(args.seed ^ int(hashlib.sha256(image_key.encode()).hexdigest()[:16], 16)).shuffle(order)
        completed_pair = ([condition for condition in structured_pair if image_key in done[condition]]
                          if structured_pair.issubset(conditions) else [])
        share_trace = structured_pair.issubset(conditions) and len(completed_pair) < 2
        shared_state = shared_text = None
        shared_error = None
        shared_seconds = 0.0
        if len(completed_pair) == 1:
            prior = done[completed_pair[0]][image_key]
            shared_text = prior.get("deliberation_text")
            shared_seconds = prior.get("deliberation_seconds")
            if shared_seconds is None:
                raise RuntimeError("completed structured row lacks deliberation latency")
            if prior.get("runtime_error") and not prior.get("structured_trace_id"):
                shared_error = RuntimeError(
                    "paired structured deliberation previously failed: " + prior["runtime_error"])
            else:
                shared_state = state_from_trace(prior)

        for order_index, condition in enumerate(order):
            if image_key in done[condition]:
                continue
            start = time.monotonic()
            runtime_error = None
            selection_seconds = None
            try:
                if share_trace and condition in structured_pair:
                    if shared_state is None:
                        if shared_error is not None:
                            raise shared_error
                        deliberation_start = time.monotonic()
                        try:
                            shared_state, shared_text = run_staged_deliberation(
                                engine, config, sample["path"], STAGED_SYSTEM)
                        except Exception as exc:
                            shared_error = exc
                            raise
                        finally:
                            shared_seconds = time.monotonic() - deliberation_start
                    selection_start = time.monotonic()
                    final, info = run_staged_selection(
                        engine, config, sample["path"], shared_state, shared_text,
                        condition == "structured-reflection-retained-pool")
                    selection_seconds = time.monotonic() - selection_start
                    latency = shared_seconds + selection_seconds
                else:
                    final, info = run_condition(engine, config, condition, sample["path"], prompts)
                    latency = time.monotonic() - start
            except Exception as exc:
                runtime_error = f"{type(exc).__name__}: {exc}"
                final, info = None, {"final_text": f"<error: {runtime_error}>", "tool_calls": [], "passes": 0}
                latency = (shared_seconds if share_trace and condition in structured_pair and shared_error
                           else time.monotonic() - start)

            protocol_errors = list(info.get("protocol_errors") or [])
            allowed_pool = info.get("presented_candidate_pool") if condition in structured_pair else None
            schema_errors = final_schema_errors(final, allowed_pool)
            if "final_species_outside_presented_pool" in schema_errors:
                protocol_errors.append("final_species_outside_presented_pool")
            protocol_failure = bool(protocol_errors) or runtime_error is not None or bool(schema_errors)
            species_ok, genus_ok = baseline.score(final, sample["sp"], truth[sample["sp"]])
            if protocol_failure:
                species_ok = genus_ok = False
            tool_args = info.get("tool_calls") or []
            row = {
                "run_id": manifest["run_id"], "condition": condition, "image": image_key,
                "true": sample["sp"], "final": final, "schema_valid": not schema_errors,
                "schema_errors": schema_errors, "protocol_failure": protocol_failure,
                "runtime_error": runtime_error, "tool_calls": len(tool_args),
                "passes": info.get("passes", len(tool_args)), "species_ok": species_ok,
                "genus_ok": genus_ok, "final_text": info.get("final_text", ""),
                "deliberation_text": info.get("deliberation_text"),
                "presented_candidate_pool": info.get("presented_candidate_pool"),
                "structured_deliberation_trace": info.get("structured_deliberation_trace"),
                "structured_trace_id": info.get("structured_trace_id"),
                "tool_call_args": tool_args, "attempted_tool_calls": info.get("attempted_tool_calls"),
                "attempted_reflections": info.get("attempted_reflections"),
                "provisional_answer_species_id": info.get("provisional_answer_species_id"),
                "reflection": info.get("reflection"), "protocol_errors": protocol_errors,
                "searches": info.get("searches"), "inspections": info.get("inspections"),
                "latency_seconds": latency,
                "deliberation_seconds": shared_seconds if share_trace and condition in structured_pair else None,
                "selection_seconds": selection_seconds, "block_index": block_index,
                "condition_order": order, "condition_order_index": order_index,
            }
            done[condition][image_key] = row
            with (run_dir / f"{condition}{tag}.jsonl").open("a") as output:
                output.write(json.dumps(row) + "\n")
                output.flush()
        if (block_index + 1) % 10 == 0:
            print(f"completed matched block {block_index + 1}/{len(samples)}", flush=True)

    for condition, rows_by_image in done.items():
        rows = list(rows_by_image.values())
        count = len(rows)
        summary = {"date": str(date.today()), "run_id": manifest["run_id"],
                   "model": "gemma-4-E2B", "condition": condition, "images": count,
                   "species_top1": sum(bool(row.get("species_ok")) for row in rows) / count if count else 0.0,
                   "genus_acc": sum(bool(row.get("genus_ok")) for row in rows) / count if count else 0.0,
                   "schema_valid_rate": sum(bool(row.get("schema_valid")) for row in rows) / count if count else 0.0,
                   "protocol_failure_rate": sum(bool(row.get("protocol_failure")) for row in rows) / count if count else 0.0}
        (run_dir / f"{condition}{tag}.json").write_text(json.dumps(summary, indent=2))
        print(f"[{condition}] {count} images · species {summary['species_top1']:.1%}")
    print(f"wrote run artifacts to {run_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
