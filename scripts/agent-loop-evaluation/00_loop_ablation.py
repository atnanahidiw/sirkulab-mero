#!/usr/bin/env python3
"""Track 04 loop ablation — five conditions from no tool use to the full adaptive loop.

Reuses `eval_gemma4_baseline.py` (Track 01) for search, prompts, JSON parsing, and
scoring, so every condition below is scored the same way as the deployed baseline.

Conditions:
  1. direct           — no tool. One VLM pass on the image alone.
  2. fixed-retrieval   — the critical control. One non-agentic observation pass extracts
                         traits, a deterministic (Python-driven, not model-chosen) search
                         runs once, then one selection pass picks from the fixed result.
                         This isolates whether the agent's adaptive tool choice adds
                         anything beyond good retrieval — no other condition can, because
                         they never compare against a non-agentic pipeline.
  3. one-call          — native tool loop, forced to conclude after 1 search.
  4. two-call          — native tool loop, forced to conclude after 2 searches.
  5. four-call         — the deployed baseline, reused unmodified via `baseline.run_one`:
                         native tool loop, up to 4 searches, current production prompt.

litert_lm's automatic_tool_calling loop is not controllable from outside — the runtime,
not this script, decides how many times it calls the tool within one `send_message`.
Conditions 3 and 4 enforce their cap the same way the deployed prompt already asks for a
stop after 4 attempts: the tool's own returned text tells the model, once the cap is hit,
that this was the last allowed attempt and it must conclude now.

Writes one summary JSON and one per-image JSONL per condition, plus a combined summary
with a paired McNemar test and bootstrap CI against the fixed-retrieval control, to
`outputs/agent-loop-evaluation/`.

Per-image rows are resumable: re-running skips images already present in that
condition's jsonl, matching `eval_gemma4_soft_gate.py`.

RUNTIME: LiteRT-LM + the multimodal Gemma checkpoint. Run with the sirkulab-mero-data
env (it has `litert_lm`); the SQLite search is stdlib:

  cd ../sirkulab-mero-data && .venv/bin/python \\
      ../sirkulab-mero/scripts/agent-loop-evaluation/00_loop_ablation.py \\
      --model-path ~/Downloads/gemma-4-E2B-it.litertlm \\
      --limit 30                      # quick smoke
      --conditions direct,fixed-retrieval,four-call   # run a subset
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import random
import sqlite3
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
OUT_DIR = APP_REPO / "outputs" / "agent-loop-evaluation"
BASELINE_PATH = APP_REPO / "scripts" / "gemma-improve-detection" / "eval_gemma4_baseline.py"
MODEL_DEFAULT = Path.home() / "Downloads/gemma-4-E2B-it.litertlm"

CONDITIONS = ["direct", "fixed-retrieval", "one-call", "two-call", "four-call"]
CALL_CAPS = {"one-call": 1, "two-call": 2, "four-call": 4}
CONTROL_CONDITION = "fixed-retrieval"
DEFAULT_BOOTSTRAP_SAMPLES = 10000


def load_baseline_module():
    """Import eval_gemma4_baseline.py so search, prompts, parsing and scoring stay
    identical to the deployed baseline (Track 01), the same pattern eval_gemma4_soft_gate.py
    uses to reuse it."""
    spec = importlib.util.spec_from_file_location("gemma4_baseline", BASELINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load baseline module from {BASELINE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


baseline = load_baseline_module()

# ── condition 1: direct, no tool ──
DIRECT_SYSTEM = """You are a high-precision biological identification engine.

Look at the image and identify the species directly from what you can see. You do not
have access to any search tool or database in this task.

Conclude by outputting ONLY this JSON — no other text, no markdown:
{"genus":"string","common_name":"string","scientific_name":"string","confidence":"high|medium|low","identification_notes":"string","is_endangered":boolean}

RULES: is_endangered only on a confirmed match; do not invent traits not seen in the image."""

DIRECT_PROMPT = "Identify the species in this image. Output ONLY the final identification JSON."

# ── condition 2: fixed-retrieval, the deterministic control ──
TRAITS_SYSTEM = """You are a high-precision biological identification engine.

Look at the image and extract visual traits only. Do not identify the species yet.

Output ONLY this JSON — no other text, no markdown:
{"color":"string","body_shape":"string","distinctive_marks":"string","texture":"string","size_class":"string","pattern":"string","visualGroup":"string","taxClass":"string","taxOrder":"string","taxFamily":"string","taxGenus":"string"}

visualGroup must be ONE of: %s. Leave a field empty ("") if you are not confident about
it. Keep fields to observable physical attributes only.""" % baseline.VISUAL_GROUPS

TRAITS_PROMPT = "Extract the visual traits from this image following the schema. Output ONLY the traits JSON."

SELECTION_SYSTEM = """You are a high-precision biological identification engine.

A species database was already searched once with your observed traits. You will not
search again — evaluate the candidates below against the image and pick the best match,
even if the top confidence is low.

Conclude by outputting ONLY this JSON — no other text, no markdown:
{"genus":"string","common_name":"string","scientific_name":"string","confidence":"high|medium|low","identification_notes":"string","is_endangered":boolean}

RULES: is_endangered only on a confirmed match; do not invent traits not seen in the image."""


def selection_prompt(tool_result_text):
    return ("%s\n\nEvaluate the candidates against the image and output ONLY the final "
            "identification JSON." % tool_result_text)


def run_direct(engine, cfg, image_path):
    with engine.create_conversation(system_message=DIRECT_SYSTEM, sampler_config=cfg,
                                     automatic_tool_calling=False) as conv:
        resp = conv.send_message({"role": "user", "content": [
            {"type": "text", "text": DIRECT_PROMPT}, {"type": "image", "path": str(image_path)}]})
    text = resp.get("content", [{}])[0].get("text", str(resp))
    return baseline.parse_json(text), {"final_text": text, "tool_calls": [], "passes": 0}


def run_fixed_retrieval(engine, cfg, image_path):
    """One non-agentic observation pass, one deterministic search, one selection pass.
    The two model calls are sequential conversations — litert_lm allows only one live
    session per engine, so the traits conversation must close before the selection one
    opens (see the parallelism note in ../gemma-improve-detection/README.md)."""
    with engine.create_conversation(system_message=TRAITS_SYSTEM, sampler_config=cfg,
                                     automatic_tool_calling=False) as conv:
        traits_resp = conv.send_message({"role": "user", "content": [
            {"type": "text", "text": TRAITS_PROMPT}, {"type": "image", "path": str(image_path)}]})
    traits_text = traits_resp.get("content", [{}])[0].get("text", str(traits_resp))
    traits = baseline.parse_json(traits_text) or {}

    con = sqlite3.connect(baseline._DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        ranked = baseline._run_search(con, traits)
    finally:
        con.close()
    tool_text = baseline.format_tool_result(ranked)

    with engine.create_conversation(system_message=SELECTION_SYSTEM, sampler_config=cfg,
                                     automatic_tool_calling=False) as conv:
        final_resp = conv.send_message({"role": "user", "content": [
            {"type": "text", "text": selection_prompt(tool_text)},
            {"type": "image", "path": str(image_path)}]})
    final_text = final_resp.get("content", [{}])[0].get("text", str(final_resp))
    return baseline.parse_json(final_text), {
        "final_text": final_text, "tool_calls": [traits], "passes": 1,
        "observed_traits": traits, "search_result": tool_text,
    }


# ── conditions 3-4: native loop, forced to conclude after 1 or 2 calls ──
def make_capped_system(cap):
    if cap == 1:
        pivot_step = ("STEP 5: You have exactly ONE search attempt in this task. Do not "
                       "search again once the result comes back.")
    else:
        pivot_step = ("STEP 5: If the tool returns no match OR confidence is low, your "
                       "assumptions are WRONG — do NOT repeat the same genus/family/traits; "
                       "pivot your hypothesis entirely and search again, up to %d attempts "
                       "total." % cap)
    conclude_step = "STEP 6: After at most %d attempt%s, output your best guess." % (
        cap, "" if cap == 1 else "s")
    text = baseline.SYSTEM
    text = text.replace(
        "STEP 5: If the tool returns no match OR confidence is low, your assumptions are "
        "WRONG — do NOT repeat the same genus/family/traits; pivot your hypothesis "
        "entirely and search again.",
        pivot_step,
    )
    text = text.replace("STEP 6: After at most 4 attempts, output your best guess.", conclude_step)
    return text


def make_capped_tool(cap):
    calls = []

    def search_similar_features(color: str = "", body_shape: str = "", distinctive_marks: str = "",
                                 texture: str = "", size_class: str = "", pattern: str = "",
                                 visualGroup: str = "", taxClass: str = "", taxOrder: str = "",
                                 taxFamily: str = "", taxGenus: str = "") -> str:
        """Search the endangered-species database by observed visual traits and taxonomy hints.

        Fill in as many fields as you can. Returns ranked species with confidence %.
        """
        args = dict(color=color, body_shape=body_shape, distinctive_marks=distinctive_marks,
                    texture=texture, size_class=size_class, pattern=pattern, visualGroup=visualGroup,
                    taxClass=taxClass, taxOrder=taxOrder, taxFamily=taxFamily, taxGenus=taxGenus)
        calls.append(args)
        con = sqlite3.connect(baseline._DB_PATH)
        con.row_factory = sqlite3.Row
        try:
            result = baseline.format_tool_result(baseline._run_search(con, args))
        finally:
            con.close()
        if len(calls) >= cap:
            result += ("\n\nThis was attempt %d of %d, the last one allowed. You must "
                       "conclude now: output ONLY the final identification JSON, even if "
                       "confidence is low." % (len(calls), cap))
        return result

    search_similar_features.__doc__ += f"\n    visualGroup must be ONE of: {baseline.VISUAL_GROUPS}."
    return search_similar_features, calls


def run_capped(engine, cfg, image_path, cap, system_cache):
    tool, calls = make_capped_tool(cap)
    with engine.create_conversation(system_message=system_cache[cap], tools=[tool],
                                     sampler_config=cfg) as conv:
        resp = conv.send_message({"role": "user", "content": [
            {"type": "text", "text": baseline.INPUT_PROMPT}, {"type": "image", "path": str(image_path)}]})
    text = resp.get("content", [{}])[0].get("text", str(resp))
    return baseline.parse_json(text), {"final_text": text, "tool_calls": list(calls), "passes": len(calls)}


def run_condition(engine, cfg, condition, image_path, system_cache):
    if condition == "direct":
        return run_direct(engine, cfg, image_path)
    if condition == CONTROL_CONDITION:
        return run_fixed_retrieval(engine, cfg, image_path)
    cap = CALL_CAPS[condition]
    if cap == 4:
        # condition 5 is the deployed baseline, reused byte-for-byte.
        return baseline.run_one(engine, cfg, image_path)
    return run_capped(engine, cfg, image_path, cap, system_cache)


# ── paired significance testing (stdlib only, mirrors the bootstrap-CI style used in
# scripts/candidate-rank-mechanistic/01_hf_logit_rank_bias.py) ──
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


def mcnemar_test(control_correct, condition_correct):
    """Continuity-corrected McNemar's test on paired binary outcomes. The chi-square
    statistic has 1 degree of freedom, so its exact p-value is erfc(sqrt(chi2 / 2)) —
    no scipy dependency needed."""
    b01 = sum(1 for a, b in zip(control_correct, condition_correct) if not a and b)
    b10 = sum(1 for a, b in zip(control_correct, condition_correct) if a and not b)
    n_discordant = b01 + b10
    if n_discordant == 0:
        return {"b01": b01, "b10": b10, "n_discordant": 0, "chi2": 0.0, "p_value": 1.0}
    chi2 = ((abs(b01 - b10) - 1) ** 2) / n_discordant
    return {"b01": b01, "b10": b10, "n_discordant": n_discordant, "chi2": chi2,
             "p_value": math.erfc(math.sqrt(chi2 / 2.0))}


def bootstrap_paired_diff_ci(control_correct, condition_correct, seed, samples):
    n = len(control_correct)
    if n == 0:
        return {"diff": None, "ci_lower": None, "ci_upper": None, "bootstrap_samples": 0}
    rng = random.Random(seed)
    diffs = []
    for _ in range(samples):
        idx = [rng.randrange(n) for _ in range(n)]
        control_acc = sum(control_correct[i] for i in idx) / n
        condition_acc = sum(condition_correct[i] for i in idx) / n
        diffs.append(condition_acc - control_acc)
    diffs.sort()
    observed = sum(condition_correct) / n - sum(control_correct) / n
    return {"diff": observed, "ci_lower": percentile(diffs, 0.025), "ci_upper": percentile(diffs, 0.975),
             "bootstrap_samples": len(diffs)}


def load_done(out_jsonl):
    """Read any rows from a previous (possibly crashed) run, keyed by image."""
    done = {}
    if out_jsonl.exists():
        with out_jsonl.open() as f:
            for line in f:
                try:
                    r = json.loads(line)
                    done[r["image"]] = r
                except Exception:
                    pass
    return done


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-path", default=str(MODEL_DEFAULT))
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shard", default="", help="run one shard for process-parallelism, e.g. 0/3")
    ap.add_argument("--conditions", default=",".join(CONDITIONS),
                     help="Comma-separated subset of: " + ", ".join(CONDITIONS))
    ap.add_argument("--seed", type=int, default=7, help="Bootstrap CI seed")
    ap.add_argument("--bootstrap-samples", type=int, default=DEFAULT_BOOTSTRAP_SAMPLES)
    args = ap.parse_args()

    conditions = [c.strip() for c in args.conditions.split(",") if c.strip()]
    for c in conditions:
        if c not in CONDITIONS:
            raise SystemExit(f"unknown condition {c!r}; choose from {CONDITIONS}")

    from litert_lm import Backend, Engine
    from litert_lm.interfaces import SamplerConfig

    name2latin, gt = baseline.load_db(Path(args.db))
    baseline._DB_PATH = str(args.db)  # the deterministic search and the native tools read this
    samples = baseline.collect_images(Path(args.data_repo) / args.images_subdir, name2latin)
    if args.limit:
        samples = samples[: args.limit]
    tag = ""
    if args.shard:
        i, m = (int(x) for x in args.shard.split("/"))
        samples, tag = samples[i::m], f"_shard{i}of{m}"

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"{len({s['sp'] for s in samples})} species · {len(samples)} images{' · ' + tag if tag else ''} "
          f"· conditions: {', '.join(conditions)}", flush=True)

    system_cache = {cap: make_capped_system(cap) for cap in (1, 2)}
    cfg = SamplerConfig(temperature=0.3, top_k=64, top_p=0.85, seed=31415926)

    engine = None
    all_rows = {}
    for condition in conditions:
        out_json = OUT_DIR / f"loop_ablation_{condition}{tag}.json"
        out_jsonl = OUT_DIR / f"loop_ablation_{condition}{tag}.jsonl"
        done = load_done(out_jsonl)
        todo = [s for s in samples if str(s["path"].relative_to(Path(args.data_repo))) not in done]

        if done:
            print(f"[{condition}] resume: {len(done)} already on disk, {len(todo)} left", flush=True)
        if todo and engine is None:
            print("Loading Gemma 4 E2B (LiteRT-LM, GPU + vision) …", flush=True)
            engine = Engine(args.model_path, backend=Backend.GPU, vision_backend=Backend.GPU)

        rows = list(done.values())
        sp_ok = sum(1 for r in rows if r.get("species_ok"))
        ge_ok = sum(1 for r in rows if r.get("genus_ok"))
        n = len(rows)
        t0 = time.time()

        with out_jsonl.open("a") as jf:
            for sample in todo:
                try:
                    final, info = run_condition(engine, cfg, condition, sample["path"], system_cache)
                except Exception as exc:
                    final, info = None, {"final_text": f"<error: {exc}>", "tool_calls": [], "passes": 0}
                species_ok, genus_ok = baseline.score(final, sample["sp"], gt[sample["sp"]])
                n += 1
                sp_ok += species_ok
                ge_ok += genus_ok
                tool_call_args = info.get("tool_calls", [])
                row = {
                    "condition": condition,
                    "image": str(sample["path"].relative_to(Path(args.data_repo))),
                    "true": sample["sp"], "final": final,
                    # "passes" defaults to len(tool_call_args): baseline.run_one's info dict
                    # (reused unmodified for the four-call condition) has no "passes" key.
                    "tool_calls": len(tool_call_args), "passes": info.get("passes", len(tool_call_args)),
                    "species_ok": species_ok, "genus_ok": genus_ok,
                    "final_text": info.get("final_text", ""), "tool_call_args": tool_call_args,
                }
                rows.append(row)
                jf.write(json.dumps(row) + "\n")
                jf.flush()
                if n % 10 == 0:
                    print(f"  [{condition}] {n}/{len(samples)}  species {sp_ok/n:.1%}  genus {ge_ok/n:.1%}", flush=True)

        dt = time.time() - t0
        if n:
            print(f"\n[{condition}] {n} images  species {sp_ok/n:.1%}  genus {ge_ok/n:.1%}")
        else:
            print(f"\n[{condition}] no images")
        summary = {
            "date": str(date.today()), "model": "gemma-4-E2B", "condition": condition,
            "images": n, "species_top1": sp_ok / n if n else 0.0, "genus_acc": ge_ok / n if n else 0.0,
            "sec_per_image_this_session": dt / len(todo) if todo else None,
        }
        out_json.write_text(json.dumps(summary, indent=2))
        all_rows[condition] = rows
        print(f"wrote {out_json} and {out_jsonl.name}")

    # ── paired comparison against the fixed-retrieval control ──
    # Pull in any condition's jsonl already on disk (this session's or an earlier one) so
    # the comparison is not limited to whatever subset --conditions ran this time.
    for condition in CONDITIONS:
        out_jsonl = OUT_DIR / f"loop_ablation_{condition}{tag}.jsonl"
        if condition not in all_rows and out_jsonl.exists():
            all_rows[condition] = list(load_done(out_jsonl).values())

    comparisons = {}
    if CONTROL_CONDITION in all_rows:
        control_by_image = {r["image"]: r for r in all_rows[CONTROL_CONDITION]}
        for condition, rows in all_rows.items():
            if condition == CONTROL_CONDITION or not rows:
                continue
            by_image = {r["image"]: r for r in rows}
            shared = sorted(set(control_by_image) & set(by_image))
            if not shared:
                continue
            control_correct = [bool(control_by_image[k]["species_ok"]) for k in shared]
            condition_correct = [bool(by_image[k]["species_ok"]) for k in shared]
            comparisons[condition] = {
                "n": len(shared),
                f"{CONTROL_CONDITION}_accuracy": sum(control_correct) / len(shared),
                f"{condition}_accuracy": sum(condition_correct) / len(shared),
                "mcnemar": mcnemar_test(control_correct, condition_correct),
                "bootstrap_diff_ci": bootstrap_paired_diff_ci(
                    control_correct, condition_correct, args.seed, args.bootstrap_samples),
            }

    if comparisons:
        combined_path = OUT_DIR / f"loop_ablation_summary{tag}.json"
        combined_path.write_text(json.dumps({
            "date": str(date.today()), "control_condition": CONTROL_CONDITION,
            "comparisons": comparisons,
        }, indent=2))
        print(f"\nwrote {combined_path}")
        for condition, c in comparisons.items():
            print(f"  {CONTROL_CONDITION} vs {condition}: n={c['n']}  "
                  f"{c[f'{CONTROL_CONDITION}_accuracy']:.1%} -> {c[f'{condition}_accuracy']:.1%}  "
                  f"McNemar p={c['mcnemar']['p_value']:.3f}")
    else:
        print("\nno paired comparison yet — run the fixed-retrieval control and at least "
              "one other condition to get one.")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
