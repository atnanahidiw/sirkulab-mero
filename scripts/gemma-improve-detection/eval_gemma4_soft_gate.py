#!/usr/bin/env python3
"""Gemma 4 E2B baseline with a deterministic soft visual_group search gate.

Same flow as the native baseline (Gemma sees the image, predicts one visualGroup,
calls the search tool), but the search tool no longer hard-filters on that single
group. It expands the predicted group through a fixed inverse-confusion neighbor map
and searches each group under a candidate budget, keeping the returned list small so
Gemma's context is not swamped.

Search policy:
  predicted visualGroup : top 15
  first neighbor        : top 8
  second neighbor       : top 5
  remaining neighbors   : top 3 each
  returned list         : deduped, ranked by search score, capped at 35

Robustness:
  These long GPU runs can die in native code with no Python traceback. Each per-image
  result is flushed to the jsonl as soon as it is produced, and re-running skips images
  already on disk, so a crash never loses progress and the run is resumable.

Run with the LiteRT-LM environment:
  ../sirkulab-mero-data/.venv/bin/python \
      scripts/smaller-footprint-pipeline-v1/eval_gemma4_soft_gate.py \
      --model-path ~/Downloads/gemma-4-E2B-it.litertlm

Writes:
  scripts/smaller-footprint-pipeline-v1/outputs/gemma4_soft_gate.json   (summary)
  scripts/smaller-footprint-pipeline-v1/outputs/gemma4_soft_gate.jsonl  (per image)
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sqlite3
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
OUT_DIR = HERE.parent / "outputs"
BASELINE_PATH = HERE.parent / "eval_gemma4_baseline.py"
MODEL_DEFAULT = Path.home() / "Downloads/gemma-4-E2B-it.litertlm"

# predicted group -> groups to ALSO search (direction is predicted->recover, taken from
# the native run's confusion matrix: when Gemma predicts the key, the true group is
# often one of the values).
PREDICTED_GROUP_NEIGHBORS = {
    "Primate": ["Flying bird", "Small quadruped mammal"],
    "Tall broadleaf tree": ["Fern", "Palm tree", "Vine & climber", "Shrub & bush"],
    "Marine mammal": ["Marine fish"],
    "Mollusk & marine invertebrate": ["Marine fish"],
    "Shrub & bush": ["Mangrove", "Tall broadleaf tree"],
    "Ground herb": ["Mangrove"],
    "Waterfowl": ["Flying bird"],
    "Lizard": ["Frog & toad"],
    "Aquatic plant": ["Mollusk & marine invertebrate"],
}
SOFT_BUDGETS = [15, 8, 5, 3, 3, 3]   # predicted group first, then neighbors in order
SOFT_MAX_TOTAL = 35


def load_baseline_module():
    """Import eval_gemma4_baseline.py so we can reuse its search, prompts and runtime."""
    spec = importlib.util.spec_from_file_location("gemma4_baseline_v1", BASELINE_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load baseline module from {BASELINE_PATH}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


baseline = load_baseline_module()


def _score_of(cand):
    return float(cand.get("score", cand.get("confidence", 0.0)))


def search_one_group(con, base_args, visual_group, top_k):
    args = dict(base_args)
    args["visualGroup"] = visual_group
    return baseline._run_search(con, args, top_k=top_k)


def soft_neighbor_search(con, base_args):
    """Predicted group + budgeted neighbor groups, deduped and capped."""
    predicted = str(base_args.get("visualGroup", "")).strip()
    if not predicted:
        return []

    groups = [predicted] + PREDICTED_GROUP_NEIGHBORS.get(predicted, [])
    best = {}
    for idx, group in enumerate(groups):
        budget = SOFT_BUDGETS[idx] if idx < len(SOFT_BUDGETS) else SOFT_BUDGETS[-1]
        for rank, cand in enumerate(search_one_group(con, base_args, group, budget), 1):
            cand = dict(cand)
            cand.setdefault("retrieval_source_group", group)
            cand["retrieval_source_group_order"] = idx + 1
            cand["retrieval_source_rank"] = rank
            latin = cand["latin"]
            if latin not in best or _score_of(cand) > _score_of(best[latin]):
                best[latin] = cand

    ranked = sorted(best.values(), key=lambda c: (_score_of(c), c.get("confidence", 0)), reverse=True)
    return ranked[:SOFT_MAX_TOTAL]


def search_similar_features(color: str = "", body_shape: str = "", distinctive_marks: str = "",
                            texture: str = "", size_class: str = "", pattern: str = "",
                            visualGroup: str = "", taxClass: str = "", taxOrder: str = "",
                            taxFamily: str = "", taxGenus: str = "") -> str:
    """Search the endangered-species database by observed visual traits and taxonomy hints.

    Fill in as many fields as you can. The search expands the chosen visualGroup to
    deterministic neighbor groups when that group has known confusion patterns.
    """
    args = dict(color=color, body_shape=body_shape, distinctive_marks=distinctive_marks,
                texture=texture, size_class=size_class, pattern=pattern, visualGroup=visualGroup,
                taxClass=taxClass, taxOrder=taxOrder, taxFamily=taxFamily, taxGenus=taxGenus)
    baseline._TOOL_CALLS.append(args)
    con = sqlite3.connect(baseline._DB_PATH)
    con.row_factory = sqlite3.Row
    try:
        return baseline.format_tool_result(soft_neighbor_search(con, args))
    finally:
        con.close()


search_similar_features.__doc__ += f"\n    visualGroup must be ONE of: {baseline.VISUAL_GROUPS}."


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
    args = ap.parse_args()

    from litert_lm import Backend, Engine
    from litert_lm.interfaces import SamplerConfig

    # swap the baseline's native search tool for the soft-gate version; run_one looks the
    # name up in the baseline module's globals, so this override is what the engine calls.
    baseline.search_similar_features = search_similar_features
    name2latin, gt = baseline.load_db(Path(args.db))
    baseline._DB_PATH = str(args.db)

    samples = baseline.collect_images(Path(args.data_repo) / args.images_subdir, name2latin)
    if args.limit:
        samples = samples[: args.limit]
    tag = ""
    if args.shard:
        i, m = (int(x) for x in args.shard.split("/"))
        samples, tag = samples[i::m], f"_shard{i}of{m}"

    OUT_DIR.mkdir(exist_ok=True)
    out_json = OUT_DIR / f"gemma4_soft_gate{tag}.json"
    out_jsonl = OUT_DIR / f"gemma4_soft_gate{tag}.jsonl"

    done = load_done(out_jsonl)
    todo = [s for s in samples if str(s["path"].relative_to(Path(args.data_repo))) not in done]

    print(f"{len({s['sp'] for s in samples})} species · {len(samples)} images"
          f"{' · ' + tag if tag else ''} · soft visual_group gate · {Path(args.model_path).name}", flush=True)
    if done:
        print(f"resume: {len(done)} already on disk, {len(todo)} left to run", flush=True)
    if not todo:
        print("nothing to do — all images already on disk.", flush=True)

    def create_engine():
        print("Loading Gemma 4 E2B (LiteRT-LM, GPU + vision) …", flush=True)
        return Engine(args.model_path, backend=Backend.GPU, vision_backend=Backend.GPU)

    engine = create_engine() if todo else None
    cfg = SamplerConfig(temperature=0.3, top_k=64, top_p=0.85, seed=31415926)

    rows = list(done.values())
    sp_ok = sum(1 for r in rows if r.get("species_ok"))
    ge_ok = sum(1 for r in rows if r.get("genus_ok"))
    n = len(rows)
    processed, t0 = 0, time.time()

    with out_jsonl.open("a") as jf:
        for sample in todo:
            runtime_error = None
            for attempt in range(2):
                try:
                    final, info = baseline.run_one(engine, cfg, sample["path"])
                    runtime_error = None
                    break
                except Exception as exc:
                    runtime_error = exc
                    if attempt == 0:
                        print(f"  runtime error at image {n + 1}; recreating engine and retrying once: {exc}", flush=True)
                        try:
                            del engine
                        except Exception:
                            pass
                        engine = create_engine()
                        continue
                    final, info = None, {"final_text": f"<error after retry: {exc}>", "tool_calls": []}

            species_ok, genus_ok = baseline.score(final, sample["sp"], gt[sample["sp"]])
            n += 1
            processed += 1
            sp_ok += species_ok
            ge_ok += genus_ok
            row = {
                "image": str(sample["path"].relative_to(Path(args.data_repo))),
                "true": sample["sp"],
                "final": final,
                "tool_calls": len(info["tool_calls"]),
                "species_ok": species_ok,
                "genus_ok": genus_ok,
                "final_text": info["final_text"],
                "tool_call_args": info["tool_calls"],
                "runtime_error": str(runtime_error) if runtime_error else "",
            }
            rows.append(row)
            jf.write(json.dumps(row) + "\n")
            jf.flush()
            if n % 10 == 0:
                print(f"  {n}/{len(samples)}  species {sp_ok/n:.1%}  genus {ge_ok/n:.1%}", flush=True)

    dt = time.time() - t0
    print(f"\nSOFT-GATE Gemma 4 E2B ({n} images, sees image + expanded search tool)")
    print(f"  species top-1 : {sp_ok/n:.1%}" if n else "  species top-1 : n/a")
    print(f"  genus acc     : {ge_ok/n:.1%}" if n else "  genus acc     : n/a")
    if processed:
        print(f"  {dt/processed:.1f}s/image · {dt/60:.1f} min this session")

    summary = {
        "date": str(date.today()),
        "model": "gemma-4-E2B",
        "flow": "original-sees-image+soft-visual-group-search",
        "tool_calling": "native",
        "images": n,
        "species_top1": sp_ok / n if n else 0.0,
        "genus_acc": ge_ok / n if n else 0.0,
        "sec_per_image_this_session": dt / processed if processed else 0.0,
        "soft_gate": {
            "neighbor_map": PREDICTED_GROUP_NEIGHBORS,
            "budgets": SOFT_BUDGETS,
            "max_total": SOFT_MAX_TOTAL,
        },
    }
    out_json.write_text(json.dumps(summary, indent=2))
    print(f"\nWrote {out_json} ({n} rows in {out_jsonl.name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
