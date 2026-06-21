#!/usr/bin/env python3
"""Measure species-level image retrieval — the two halves of "cover all species".

Builds one BioCLIP centroid prototype per species from the labeled images in the
sibling `sirkulab-mero-data` repo, then evaluates:

  CLOSED-SET (all curated species known) — leave-one-out:
    - flat rank-1/5/MRR over all species
    - hierarchical: restrict candidates to the predicted `visual_group`
  OPEN-SET (out-of-distribution rejection) — K-fold over *species*:
    hold whole species out as "unknown", and check whether their images score
    lower (max cosine to known prototypes) than held-out images of KNOWN species.
    Reports AUROC + a reject threshold τ calibrated to keep 90% of known images.

Nothing is written to the app; this is a measurement to decide whether species
prototypes + an OOD threshold reach 70–90% rank-1 and reject unknowns cleanly.

USAGE
-----
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v2/comparison/eval_species_retrieval_bioclip.py
  #   --strategy mean|trimmed_80   --ood-folds 5   --keep-tpr 0.90
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

from export_vision_model_bioclip import DISPLAY_NAME, HF_MODEL, INPUT_SIZE, SUFFIX, load_bioclip

HERE = Path(__file__).resolve()
APP_REPO = HERE.parents[3]
WORKDIR = HERE.parents[4]
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def l2(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def image_embedding(enc, path):
    import torch

    input_size = getattr(enc, "input_size", INPUT_SIZE)
    mean = np.asarray(getattr(enc, "mean", MEAN), np.float32)
    std = np.asarray(getattr(enc, "std", STD), np.float32)
    img = Image.open(path).convert("RGB").resize((input_size, input_size), Image.BICUBIC)
    arr = (np.asarray(img, np.float32) / 255.0 - mean) / std
    with torch.no_grad():
        return l2(enc.image_module(torch.from_numpy(arr.transpose(2, 0, 1)[None])).cpu().numpy()[0])


def load_db(db_path):
    """{normalized latin/common name: (latin_name, visual_group)}."""
    con = sqlite3.connect(str(db_path))
    lut = {}
    for latin, common, vg in con.execute(
        "SELECT latin_name, common_name, visual_group FROM species WHERE TRIM(visual_group)!=''"
    ):
        for key in (latin, common):
            if key and key.strip():
                lut[key.strip().lower()] = (latin.strip(), vg)
    con.close()
    return lut


def centroid(embs, strategy):
    arr = np.stack(embs).astype(np.float32)
    if len(arr) == 1 or strategy == "mean":
        return l2(arr.mean(0))
    if strategy.startswith("trimmed_"):
        keep = max(1, int(np.ceil(len(arr) * float(strategy.split("_")[1]) / 100.0)))
        c = l2(arr.mean(0))
        idx = np.argsort(arr @ c)[::-1][:keep]
        return l2(arr[idx].mean(0))
    raise ValueError(strategy)


def rank_of(label, cand_labels, cand_protos, test):
    if label not in cand_labels:
        return None
    scores = np.stack(cand_protos) @ test
    order = [cand_labels[i] for i in scores.argsort()[::-1]]
    return order.index(label) + 1


def auroc(pos, neg):
    """P(in-set score > OOD score). pos = in-set max-cosine, neg = OOD."""
    pos, neg = np.asarray(pos), np.asarray(neg)
    if not len(pos) or not len(neg):
        return float("nan")
    allv = np.concatenate([pos, neg])
    ranks = allv.argsort().argsort().astype(np.float64) + 1
    r_pos = ranks[: len(pos)].sum()
    return (r_pos - len(pos) * (len(pos) + 1) / 2) / (len(pos) * len(neg))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--strategy", default="mean")
    ap.add_argument("--ood-folds", type=int, default=5)
    ap.add_argument("--keep-tpr", type=float, default=0.90)
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    data_repo = Path(args.data_repo)
    img_root = data_repo / args.images_subdir
    out_dir = data_repo / "data" / "processed"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_jsonl = out_dir / f"vision_eval_species_retrieval_{SUFFIX}.jsonl"
    db = load_db(Path(args.db))

    print(f"Loading {DISPLAY_NAME}: {args.hf_model}")
    enc = load_bioclip(args.hf_model)

    # collect + embed db-ground-truthed images (species via latin-folder join)
    seen, samples = set(), []
    for p in sorted(img_root.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in IMAGE_EXTS:
            continue
        key = (p.name, p.stat().st_size)
        if key in seen:
            continue
        seen.add(key)
        latin = vg = None
        for anc in p.relative_to(img_root).parts[:-1][::-1]:
            hit = db.get(anc.replace("_", " ").strip().lower())
            if hit:
                latin, vg = hit
                break
        if latin:
            samples.append({"rel": str(p.relative_to(img_root)), "sp": latin, "vg": vg, "path": p})
    print(f"Embedding {len(samples)} curated-species images …")
    for s in samples:
        s["emb"] = image_embedding(enc, str(s["path"]))

    by_sp = defaultdict(list)
    by_vg = defaultdict(list)
    for s in samples:
        by_sp[s["sp"]].append(s)
        by_vg[s["vg"]].append(s)
    species = sorted(by_sp)
    sp_vg = {sp: by_sp[sp][0]["vg"] for sp in species}
    emb_sp = {sp: np.stack([s["emb"] for s in by_sp[sp]]) for sp in species}
    full_sp = {sp: centroid(list(emb_sp[sp]), args.strategy) for sp in species}
    full_vg = {g: centroid([s["emb"] for s in by_vg[g]], args.strategy) for g in by_vg}
    vg_labels = sorted(full_vg)
    vg_mat = np.stack([full_vg[g] for g in vg_labels])
    print(f"{len(species)} species · {len(by_vg)} visual_groups · "
          f"{min(len(v) for v in by_sp.values())}-{max(len(v) for v in by_sp.values())} imgs/species")

    # ── CLOSED-SET: leave-one-out rank-1 (flat + hierarchical) ──
    rr_flat = rr_hier = r1_flat = r5_flat = r1_hier = r5_hier = vg_correct = n = 0
    rows = []
    for sp in species:
        for i, s in enumerate(by_sp[sp]):
            test = s["emb"]
            rest = np.delete(emb_sp[sp], i, axis=0)
            proto_self = centroid(list(rest), args.strategy)  # LOO (min 4 imgs → never empty)
            labels = species
            protos = [proto_self if t == sp else full_sp[t] for t in labels]
            rf = rank_of(sp, labels, protos, test)
            pred_vg = vg_labels[int((vg_mat @ test).argmax())]
            vg_correct += int(pred_vg == sp_vg[sp])
            hlabels = [t for t in species if sp_vg[t] == pred_vg]
            hprotos = [proto_self if t == sp else full_sp[t] for t in hlabels]
            rh = rank_of(sp, hlabels, hprotos, test)
            n += 1
            r1_flat += int(rf == 1); r5_flat += int(rf is not None and rf <= 5); rr_flat += (1.0 / rf if rf else 0)
            r1_hier += int(rh == 1); r5_hier += int(rh is not None and rh <= 5); rr_hier += (1.0 / rh if rh else 0)
            rows.append({"image": s["rel"], "species": sp, "visual_group": sp_vg[sp],
                         "pred_visual_group": pred_vg,
                         "rank_flat": rf, "rank_hier": rh})

    # ── OPEN-SET: K-fold leave-species-out → OOD rejection ──
    rng = np.random.default_rng(args.seed)
    shuf = list(species); rng.shuffle(shuf)
    folds = [shuf[i::args.ood_folds] for i in range(args.ood_folds)]
    in_scores, ood_scores = [], []
    for fold in folds:
        known = [sp for sp in species if sp not in fold]
        kmat = np.stack([full_sp[sp] for sp in known])
        for sp in fold:  # OOD: unknown species
            for s in by_sp[sp]:
                ood_scores.append(float((kmat @ s["emb"]).max()))
        for sp in known:  # in-set with LOO on own species
            for i, s in enumerate(by_sp[sp]):
                rest = np.delete(emb_sp[sp], i, axis=0)
                proto_self = centroid(list(rest), args.strategy)
                km = np.stack([proto_self if t == sp else full_sp[t] for t in known])
                in_scores.append(float((km @ s["emb"]).max()))
    roc = auroc(in_scores, ood_scores)
    tau = float(np.quantile(in_scores, 1 - args.keep_tpr))  # keep keep_tpr of in-set
    ood_reject = float(np.mean(np.asarray(ood_scores) < tau))
    in_keep = float(np.mean(np.asarray(in_scores) >= tau))

    print(f"\n── CLOSED-SET (all {len(species)} species known, leave-one-out, {n} images) ──")
    print(f"  flat          rank-1 {r1_flat/n:6.1%}  rank-5 {r5_flat/n:6.1%}  MRR {rr_flat/n:.3f}")
    print(f"  hierarchical  rank-1 {r1_hier/n:6.1%}  rank-5 {r5_hier/n:6.1%}  MRR {rr_hier/n:.3f}"
          f"   (visual_group predicted {vg_correct/n:.1%} correct)")
    print(f"\n── OPEN-SET (leave-species-out OOD, {len(in_scores)} in-set vs {len(ood_scores)} ood) ──")
    print(f"  AUROC (in-set vs OOD max-cosine): {roc:.3f}")
    print(f"  τ={tau:.3f} (keeps {in_keep:.0%} of known) → rejects {ood_reject:.0%} of unknowns")

    note = f"""# data/processed — species retrieval evaluation

Generated by `{Path(__file__).name}`. Measures image↔prototype species
retrieval (the proposed Tier-1) and open-set rejection (the OOD router).

## Closed-set (all {len(species)} curated species known, leave-one-out, {n} images)
- flat:          rank-1 {r1_flat/n:.1%} · rank-5 {r5_flat/n:.1%} · MRR {rr_flat/n:.3f}
- hierarchical:  rank-1 {r1_hier/n:.1%} · rank-5 {r5_hier/n:.1%} · MRR {rr_hier/n:.3f}
  (restrict to predicted visual_group; vg predicted {vg_correct/n:.1%} correct)
- strategy: `{args.strategy}` · imgs/species {min(len(v) for v in by_sp.values())}-{max(len(v) for v in by_sp.values())}

## Open-set (leave-species-out, {args.ood_folds}-fold)
- AUROC (separating known vs unknown by max prototype cosine): **{roc:.3f}**
- at τ={tau:.3f} (keeps {in_keep:.0%} of known): **rejects {ood_reject:.0%} of unknown species**

Compare to the current text-trait retrieval baseline (rank-1 19.6%).
"""
    summary_path = out_dir / f"summary_species_retrieval_{SUFFIX}.json"
    summary = {
        "display_name": DISPLAY_NAME,
        "suffix": SUFFIX,
        "species": len(species),
        "images": n,
        "closed_set": {
            "flat": {
                "rank1": r1_flat / n if n else 0.0,
                "rank5": r5_flat / n if n else 0.0,
                "mrr": rr_flat / n if n else 0.0,
            },
            "hierarchical": {
                "rank1": r1_hier / n if n else 0.0,
                "rank5": r5_hier / n if n else 0.0,
                "mrr": rr_hier / n if n else 0.0,
            },
            "visual_group_accuracy": vg_correct / n if n else 0.0,
        },
        "open_set": {
            "auroc": roc,
            "tau": tau,
            "in_keep": in_keep,
            "ood_reject": ood_reject,
        },
    }
    (out_dir / f"README_species_retrieval_{SUFFIX}.md").write_text(note)
    summary_path.write_text(json.dumps(summary, indent=2))
    with out_jsonl.open("w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    print(f"\nWrote {out_dir / f'README_species_retrieval_{SUFFIX}.md'} and the per-image jsonl")
    print(f"Wrote {out_jsonl}")
    print(f"Wrote {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
