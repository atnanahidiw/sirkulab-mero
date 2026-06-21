#!/usr/bin/env python3
"""Baseline — the ORIGINAL Gemma 4 E2B pipeline, duplicated faithfully.

Pre-split Mero: Gemma 4 E2B **sees the photo directly**, observes traits, calls the
`search_similar_features` tool (FTS5 + weighted-Dice over the curated SQLite DB),
reasons over the ranked candidates, and concludes a final identification JSON — the
agentic <=4-pass fix-and-pivot loop. Reproduces `chat_prompts.identify*` (the
`main`-branch, image-seeing version) and `SpeciesService.searchSimilarByFeatures`.

The DINO tools (`extract_visual_features` / `check_visual_evidence`) did NOT exist in
this version — Gemma saw the image itself — so only the search tool is wired.

Scores the final identification (species top-1 + genus) against DB ground truth on the
same curated image set the other evals use.

RUNTIME: LiteRT-LM + the multimodal Gemma checkpoint (NOT the torch/onnx venv). Run
with the **sirkulab-mero-data** env (it has `litert_lm`); the SQLite search is stdlib:

  cd ../sirkulab-mero-data && .venv/bin/python \\
      ../sirkulab-mero/scripts/smaller-footprint-pipeline-v1/eval_gemma4_baseline.py \\
      --model-path models/gemma-4-E2B-it.litertlm   # --limit 30 for a quick run

Writes a summary JSON + per-image JSONL (incl. the tool transcript) to ./outputs/.
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
OUT_DIR = HERE.parent / "outputs"
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
MAX_PASSES = 4

# ── search tool internals — mirror SpeciesService (species_service.dart) ──
SYNONYMS = {
    "stripes": "striped", "striping": "striped", "stripy": "striped",
    "golden": "yellow", "bluish": "blue", "reddish": "red", "greenish": "green",
    "brownish": "brown", "whitish": "white", "blackish": "black", "greyish": "grey",
    "grayish": "grey", "yellowish": "yellow", "orangish": "orange", "purplish": "purple",
    "pinkish": "pink", "spotted": "spot", "spotty": "spot",
}
STOPWORDS = {"and", "with", "the", "appears", "somewhat", "but", "on", "of", "in"}
VF_KEYS = ["color", "body_shape", "distinctive_marks", "texture", "size_class", "pattern"]
VF_WEIGHTS = {"distinctive_marks": 5.0, "pattern": 4.0, "color": 4.0,
              "body_shape": 3.0, "texture": 1.0, "size_class": 1.0}
TAX_BOOST = 2.0
VISUAL_GROUPS = (
    "Primate, Flying bird, Large quadruped mammal, Small quadruped mammal, Marine fish, "
    "Marine mammal, Flying mammal, Flightless bird, Lizard, Turtle & tortoise, Snake, "
    "Crocodilian, Frog & toad, Freshwater fish, Insect, Mollusk & marine invertebrate, "
    "Tall broadleaf tree, Palm tree, Cycad, Mangrove, Shrub & bush, Vine & climber, "
    "Grass & bamboo, Ground herb, Aroid & giant herb, Aquatic plant, Fern, Orchid, "
    "Pitcher plant, Epiphyte, Stemless giant flower"
)


def tokens(text):
    out = set()
    for t in re.split(r"\W+", str(text or "").lower()):
        t = SYNONYMS.get(t, t)
        if len(t) > 1 and t not in STOPWORDS:
            out.add(t)
    return out


def dice(a, b):
    if not a or not b:
        return 0.0
    i = len(a & b)
    return 0.0 if i == 0 else (2.0 * i) / (len(a) + len(b))


def _run_search(con, args, top_k=5):
    """FTS5 prefix-match (filtered by visualGroup) + weighted-Dice rerank + tax boost."""
    traits = {k: str(args.get(k, "")).strip() for k in VF_KEYS if str(args.get(k, "")).strip()}
    vg = str(args.get("visualGroup", "")).strip()
    tax = {t: str(args.get(t, "")).strip() for t in ("taxClass", "taxOrder", "taxFamily", "taxGenus")}
    if not traits and not vg:
        return []
    clean = set()
    for w in re.split(r"\s+", re.sub(r"[^\w\s]", " ", " ".join(traits.values()))):
        w = SYNONYMS.get(w.lower().strip(), w.lower().strip())
        if len(w) > 1 and w not in STOPWORDS:
            clean.add(w)

    con.row_factory = sqlite3.Row
    rows = []
    fts = " OR ".join(f'"{w}"*' for w in clean)
    try:
        if traits and vg:
            rows = con.execute("SELECT s.* FROM species s JOIN species_fts f ON s.id=f.rowid "
                               "WHERE species_fts MATCH ? AND s.visual_group=? LIMIT 42", (fts, vg)).fetchall()
            if not rows:
                rows = con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
        elif traits:
            rows = con.execute("SELECT s.* FROM species s JOIN species_fts f ON s.id=f.rowid "
                               "WHERE species_fts MATCH ? LIMIT 42", (fts,)).fetchall()
        elif vg:
            rows = con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
    except sqlite3.OperationalError:  # no FTS5 module → fall back to group / all
        rows = (con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
                if vg else con.execute("SELECT * FROM species LIMIT 200").fetchall())
    if not rows:
        return []

    obs = {k: tokens(v) for k, v in traits.items()}
    max_obs = sum(VF_WEIGHTS[k] for k in obs)
    if tax["taxFamily"]: max_obs += TAX_BOOST
    if tax["taxGenus"]: max_obs += TAX_BOOST * 0.5
    if tax["taxClass"]: max_obs += TAX_BOOST * 0.3
    if tax["taxOrder"]: max_obs += TAX_BOOST * 0.2

    scored = []
    for r in rows:
        sc = 0.0
        for k in VF_KEYS:
            if k not in obs:
                continue
            stored = (r[k] or "").strip() if r[k] is not None else ""
            sc += dice(obs[k], tokens(stored) if stored else tokens(r["visual_blob"])) * VF_WEIGHTS[k]
        for field, key, w in [("family", "taxFamily", TAX_BOOST), ("genus", "taxGenus", TAX_BOOST * 0.5),
                              ("class", "taxClass", TAX_BOOST * 0.3), ("order", "taxOrder", TAX_BOOST * 0.2)]:
            if tax[key] and (r[field] or "").lower() == tax[key].lower():
                sc += w
        conf = min(100.0, sc / max_obs * 100.0) if max_obs > 0 else 0.0
        scored.append((sc, conf, r))
    scored.sort(key=lambda x: x[0], reverse=True)
    return [{"common": r["common_name"], "latin": r["latin_name"], "genus": r["genus"],
             "confidence": round(conf), "visual_features": r["visual_features"]}
            for sc, conf, r in scored[:top_k]]


def format_tool_result(ranked):
    if not ranked:
        return "search_similar_features result: No matching endangered species found."
    lines = ["search_similar_features result (ranked species with confidence %):"]
    for i, c in enumerate(ranked, 1):
        lines.append(f"{i}. {c['common']} ({c['latin']}) — confidence {c['confidence']}% — {c['visual_features']}")
    return "\n".join(lines)


# ── native tool — litert_lm builds the tool schema from this callable's signature ──
_DB_PATH = None        # set in main()
_TOOL_CALLS = []        # the args of each call in the current image (reset per image)


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
    _TOOL_CALLS.append(args)
    con = sqlite3.connect(_DB_PATH); con.row_factory = sqlite3.Row
    try:
        return format_tool_result(_run_search(con, args))
    finally:
        con.close()


search_similar_features.__doc__ += f"\n    visualGroup must be ONE of: {VISUAL_GROUPS}."


# ── prompts — the main-branch (image-seeing) Gemma identify flow ──
SYSTEM = """You are a high-precision biological identification engine. Reconcile visual evidence with tool data.

WORKFLOW
STEP 1: Look at the image. Extract visual traits: colour, body shape, distinctive marks, pattern, size class, texture. Hypothesise the likely Class, Order, Family, Genus. Keep visual fields to observable physical attributes only. Determine the broad visual group.
STEP 2: Call `search_similar_features` with the traits you observed. Fill in as many fields as you can. Fill visualGroup with ONE valid label from this list: [%s].
STEP 3: Receive ranked species with similarity scores and confidence %%.
STEP 4: Compare the returned species against the image. The top result is your best candidate.
STEP 5: If the tool returns no match OR confidence is low, your assumptions are WRONG — do NOT repeat the same genus/family/traits; pivot your hypothesis entirely and search again.
STEP 6: After at most 4 attempts, output your best guess.

When you have a confident match (or after 4 attempts), conclude by outputting ONLY this JSON — no other text, no markdown:
{"genus":"string","common_name":"string","scientific_name":"string","confidence":"high|medium|low","identification_notes":"string","is_endangered":boolean}

RULES: never conclude before a search result; is_endangered only on a confirmed match; do not invent traits not seen in the image.""" % VISUAL_GROUPS

INPUT_PROMPT = ("Identify the species in this image following the workflow. Start by extracting visual "
                "traits and calling `search_similar_features` with what you observe. If the tool returns "
                "zero matches, do not repeat the same parameters — pivot to another family/genus entirely.")
SYNTHESIS = ("Evaluate the tool output against the image. If the top candidate confidence >=45% and it "
             "visually matches, output ONLY the final identification JSON. Otherwise pivot and call "
             "`search_similar_features` again with REVISED traits (never repeat previous parameters), "
             "or, if certain despite a low score, conclude with your best guess and note the discrepancy.")


# ── scoring ──
def norm(s):
    return re.sub(r"[^a-z0-9 ]", " ", str(s or "").lower()).strip()


def parse_json(text):
    raw = str(text or "").strip()
    if "```" in raw:
        raw = raw.split("```json")[-1].split("```")[0] if "```json" in raw else raw.split("```")[1]
    m = re.search(r"\{.*\}", raw, re.DOTALL)
    try:
        return json.loads(m.group(0) if m else raw)
    except Exception:
        return None


def load_db(db_path):
    con = sqlite3.connect(str(db_path)); con.row_factory = sqlite3.Row
    name2latin, gt = {}, {}
    for r in con.execute("SELECT latin_name, common_name, genus, family FROM species WHERE TRIM(visual_group)!=''"):
        latin = (r["latin_name"] or "").strip()
        if not latin:
            continue
        for key in (latin, r["common_name"]):
            if key and key.strip():
                name2latin[norm(key)] = latin
        gt[latin] = {"common": r["common_name"] or "", "genus": r["genus"] or latin.split(" ")[0]}
    con.close()
    return name2latin, gt


def collect_images(img_root, name2latin):
    seen, samples = set(), []
    for p in sorted(img_root.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in IMAGE_EXTS:
            continue
        k = (p.name, p.stat().st_size)
        if k in seen:
            continue
        seen.add(k)
        for anc in p.relative_to(img_root).parts[:-1][::-1]:
            latin = name2latin.get(norm(anc.replace("_", " ")))
            if latin:
                samples.append({"path": p, "sp": latin}); break
    return samples


def score(final, true_latin, truth):
    f = final or {}
    pl, pc, pg = norm(f.get("scientific_name", "")), norm(f.get("common_name", "")), norm(f.get("genus", ""))
    tl, tc, tg = norm(true_latin), norm(truth["common"]), norm(truth["genus"])
    hit = lambda a, b: bool(a) and bool(b) and (a == b or b in a or a in b)
    species_ok = hit(pl, tl) or hit(pc, tc)
    genus_ok = (bool(pg) and pg.split(" ")[0] == tg.split(" ")[0]) or hit(pl.split(" ")[0], tg) or species_ok
    return species_ok, genus_ok


def run_one(engine, cfg, image_path):
    """One image — NATIVE tool calling. The runtime invokes `search_similar_features`
    itself (automatic_tool_calling) and returns the model's final text. Returns
    (final_json, info)."""
    _TOOL_CALLS.clear()
    with engine.create_conversation(system_message=SYSTEM, tools=[search_similar_features],
                                    sampler_config=cfg) as conv:
        resp = conv.send_message({"role": "user", "content": [
            {"type": "text", "text": INPUT_PROMPT}, {"type": "image", "path": str(image_path)}]})
    text = resp.get("content", [{}])[0].get("text", str(resp))
    return parse_json(text), {"final_text": text, "tool_calls": list(_TOOL_CALLS)}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model-path", default=str(DATA_REPO_DEFAULT / "models/gemma-4-E2B-it.litertlm"))
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--shard", default="", help="run one shard for process-parallelism, e.g. 0/3 "
                    "(launch 0/3, 1/3, 2/3 as separate processes — each loads its own ~2.4 GB engine)")
    args = ap.parse_args()

    from litert_lm import Engine, Backend
    from litert_lm.interfaces import SamplerConfig

    name2latin, gt = load_db(Path(args.db))
    globals()["_DB_PATH"] = str(args.db)   # the native search tool reads this
    samples = collect_images(Path(args.data_repo) / args.images_subdir, name2latin)
    if args.limit:
        samples = samples[: args.limit]
    tag = ""
    if args.shard:
        i, m = (int(x) for x in args.shard.split("/"))
        samples, tag = samples[i::m], f"_shard{i}of{m}"
    print(f"{len({s['sp'] for s in samples})} species · {len(samples)} images{' · ' + tag if tag else ''} "
          f"· {Path(args.model_path).name}")

    print("Loading Gemma 4 E2B (LiteRT-LM, GPU + vision) …")
    engine = Engine(args.model_path, backend=Backend.GPU, vision_backend=Backend.GPU)
    cfg = SamplerConfig(temperature=0.3, top_k=64, top_p=0.85, seed=31415926)

    rows, sp_ok, ge_ok, n, t0 = [], 0, 0, 0, time.time()
    for s in samples:
        try:
            final, info = run_one(engine, cfg, s["path"])
        except Exception as e:
            final, info = None, {"final_text": f"<error: {e}>", "tool_calls": []}
        species_ok, genus_ok = score(final, s["sp"], gt[s["sp"]])
        n += 1; sp_ok += species_ok; ge_ok += genus_ok
        rows.append({"image": str(s["path"].relative_to(Path(args.data_repo))), "true": s["sp"],
                     "final": final, "tool_calls": len(info["tool_calls"]),
                     "species_ok": species_ok, "genus_ok": genus_ok,
                     "final_text": info["final_text"], "tool_call_args": info["tool_calls"]})
        if n % 10 == 0:
            print(f"  {n}/{len(samples)}  species {sp_ok/n:.1%}  genus {ge_ok/n:.1%}")

    dt = time.time() - t0
    print(f"\n── ORIGINAL Gemma 4 E2B baseline ({n} images, sees image + search tool) ──")
    print(f"  species top-1 : {sp_ok/n:.1%}")
    print(f"  genus acc     : {ge_ok/n:.1%}")
    print(f"  {dt/n:.1f}s/image · {dt/60:.1f} min total")

    OUT_DIR.mkdir(exist_ok=True)
    summary = {"date": str(date.today()), "model": "gemma-4-E2B", "flow": "original-sees-image+search",
               "tool_calling": "native", "images": n, "species_top1": sp_ok / n if n else 0.0,
               "genus_acc": ge_ok / n if n else 0.0, "sec_per_image": dt / n if n else 0.0}
    (OUT_DIR / f"gemma4_baseline{tag}.json").write_text(json.dumps(summary, indent=2))
    with (OUT_DIR / f"gemma4_baseline{tag}.jsonl").open("w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"\nWrote {OUT_DIR / f'gemma4_baseline{tag}.json'} and the per-image jsonl")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
