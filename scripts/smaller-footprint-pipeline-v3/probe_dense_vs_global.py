#!/usr/bin/env python3
"""v3 Q1 probe — does dense patch↔text matching beat global pooling?

Conformant zero-shot species ID: score each species image against **all** species'
*visual text* (no reference images, no leave-one-out — the text is the species'
description, never derived from the test image). Four scoring strategies share the
exact same Talk2DINO patch tokens and text embeddings:

  global_sal   — CLS-saliency pooled patch vector (the SHIPPED v2 pooling) · cosine vs text
  global_mean  — mean-pooled patch vector · cosine vs text
  dense_max    — max over patches of cosine(patch, text)        (the v3 thesis)
  dense_top{k} — mean of the top-k patch cosines

Reports rank-1 / rank-5 / MRR per strategy over the curated species set. If
`dense_*` clears `global_*`, v3 is worth building; if not, it isn't.

USAGE
  .venv-export/bin/python scripts/smaller-footprint-pipeline-v3/probe_dense_vs_global.py
  #   --text blob|traits|name   --topk 5   --limit 0
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

# ── locate repo root robustly (survives folder moves) ──
HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"

HF_MODEL = "lorebianchi98/Talk2DINO-ViTB"
INPUT_SIZE = 518
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}


def l2(v, axis=-1):
    return v / (np.linalg.norm(v, axis=axis, keepdims=True) + 1e-9)


def load_species_text(db_path, kind):
    """{normalized name: latin} lookup + {latin: visual text}."""
    con = sqlite3.connect(str(db_path))
    name2latin, latin2text = {}, {}
    rows = con.execute(
        "SELECT latin_name, common_name, visual_blob, color, body_shape, "
        "distinctive_marks, texture, pattern FROM species "
        "WHERE TRIM(visual_group)!=''"
    )
    for latin, common, blob, color, shape, marks, tex, pat in rows:
        latin = (latin or "").strip()
        if not latin:
            continue
        for key in (latin, common):
            if key and key.strip():
                name2latin[key.strip().lower()] = latin
        if kind == "name":
            text = common or latin
        elif kind == "traits":
            text = ", ".join(t for t in (color, shape, marks, pat) if t and t.strip())
        else:  # blob
            text = blob or ", ".join(t for t in (color, shape, marks) if t)
        # keep within CLIP's 77-token budget — cap words
        latin2text[latin] = " ".join(str(text).split()[:40]) or latin
    con.close()
    return name2latin, latin2text


def collect_images(img_root, name2latin):
    seen, samples = set(), []
    for p in sorted(img_root.rglob("*")):
        if not p.is_file() or p.suffix.lower() not in IMAGE_EXTS:
            continue
        key = (p.name, p.stat().st_size)
        if key in seen:
            continue
        seen.add(key)
        for anc in p.relative_to(img_root).parts[:-1][::-1]:
            latin = name2latin.get(anc.replace("_", " ").strip().lower())
            if latin:
                samples.append({"path": p, "sp": latin})
                break
    return samples


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--text", default="blob", choices=["blob", "traits", "name"])
    ap.add_argument("--topk", type=int, default=5)
    ap.add_argument("--limit", type=int, default=0, help="cap #images for a quick run")
    args = ap.parse_args()

    import torch
    from transformers import AutoModel

    name2latin, latin2text = load_species_text(Path(args.db), args.text)
    img_root = Path(args.data_repo) / args.images_subdir
    samples = collect_images(img_root, name2latin)
    if args.limit:
        samples = samples[: args.limit]
    species = sorted({s["sp"] for s in samples})
    sp_idx = {sp: i for i, sp in enumerate(species)}
    print(f"Text source: {args.text!r} · {len(species)} species · {len(samples)} images")

    print(f"Loading Talk2DINO ({args.hf_model}) …")
    model = AutoModel.from_pretrained(args.hf_model, trust_remote_code=True).eval()
    model.clip_model.float()
    backbone = model.model

    # ── species text embeddings (DINO space, L2) ──
    with torch.no_grad():
        T = model.encode_text([latin2text[sp] for sp in species])
        T = T / T.norm(dim=-1, keepdim=True)
    T = T.detach().cpu().numpy().astype(np.float32)  # (S, D)

    # ── per-image patch tokens → four score vectors over species ──
    methods = ["global_sal", "global_mean", "dense_max", f"dense_top{args.topk}"]
    rr = {m: 0.0 for m in methods}
    r1 = {m: 0 for m in methods}
    r5 = {m: 0 for m in methods}
    n = 0
    for s in samples:
        img = Image.open(s["path"]).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BICUBIC)
        arr = (np.asarray(img, np.float32) / 255.0 - MEAN) / STD
        with torch.no_grad():
            feats = backbone.forward_features(torch.from_numpy(arr.transpose(2, 0, 1)[None]))
            patch = feats["x_norm_patchtokens"][0]   # (L, D)
            cls = feats["x_norm_clstoken"][0]         # (D,)
            cls_n = cls / (cls.norm() + 1e-6)
            sal = torch.softmax(patch @ cls_n, dim=0)
            pooled_sal = (sal[:, None] * patch).sum(0)
            pooled_mean = patch.mean(0)
        patch_n = l2(patch.numpy())                   # (L, D)
        pooled_sal = l2(pooled_sal.numpy())
        pooled_mean = l2(pooled_mean.numpy())
        sim = T @ patch_n.T                           # (S, L)
        scores = {
            "global_sal": T @ pooled_sal,
            "global_mean": T @ pooled_mean,
            "dense_max": sim.max(axis=1),
            f"dense_top{args.topk}": np.sort(sim, axis=1)[:, -args.topk:].mean(axis=1),
        }
        true = sp_idx[s["sp"]]
        n += 1
        for m, sc in scores.items():
            rank = 1 + int((sc > sc[true]).sum())     # rank of the true species
            rr[m] += 1.0 / rank
            r1[m] += int(rank == 1)
            r5[m] += int(rank <= 5)

    print(f"\n── conformant zero-shot species ID ({n} images, vs {len(species)} species' text) ──")
    print(f"  {'method':14s} {'rank-1':>8s} {'rank-5':>8s} {'MRR':>7s}")
    for m in methods:
        print(f"  {m:14s} {r1[m]/n:8.1%} {r5[m]/n:8.1%} {rr[m]/n:7.3f}")
    best_global = max(r1["global_sal"], r1["global_mean"]) / n
    best_dense = max(r1["dense_max"], r1[f"dense_top{args.topk}"]) / n
    print(f"\n  dense best rank-1 {best_dense:.1%}  vs  global best {best_global:.1%}  "
          f"→ Δ {best_dense - best_global:+.1%}")
    print("  ✅ v3 worth building" if best_dense > best_global + 0.02 else
          "  ⚠ dense ≈/< global — re-think before building")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
