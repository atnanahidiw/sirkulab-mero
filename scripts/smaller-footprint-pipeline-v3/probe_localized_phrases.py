#!/usr/bin/env python3
"""v3 Q1 refinement — localized per-trait phrases + better text.

The first probe matched a whole-animal keyword *blob* against individual patches and
lost to global pooling. This tests the two refinements the plan actually proposes:

  #1 localized phrases — split a species into short trait phrases and max-match EACH
     phrase against the patches (a region-sized phrase vs a region-sized patch).
  #2 better text — use the Gemma structured visual fields (color, body_shape,
     distinctive_marks, texture, pattern) as the phrases, instead of the keyword blob.

Matrix: {text source} × {pooling}. Conformant zero-shot (image↔text, no reference
images, no LOO). Writes a JSON + Markdown report to ./outputs/.

  text sources : blob   (baseline keyword bag, 1 phrase)
                 traits (Gemma visual fields, several phrases)  ← the swap
  poolings     : global_sal        — saliency-pooled image · mean-of-phrases
                 dense_textmean_max — mean-of-phrases vs max over patches
                 dense_phrase_mean  — per-phrase max-over-patches, mean-aggregated  (#1)
                 dense_phrase_max   — per-phrase max-over-patches, best single phrase

USAGE
  .venv-export/bin/python scripts/smaller-footprint-pipeline-v3/probe_localized_phrases.py
"""
from __future__ import annotations

import argparse
import json
import sqlite3
from datetime import date
from pathlib import Path

import numpy as np
from PIL import Image

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
WORKDIR = APP_REPO.parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"
OUT_DIR = HERE.parent / "outputs"

HF_MODEL = "lorebianchi98/Talk2DINO-ViTB"
INPUT_SIZE = 518
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
TEXT_SOURCES = ["blob", "traits"]
POOLINGS = ["global_sal", "dense_textmean_max", "dense_phrase_mean", "dense_phrase_max"]


def l2(v, axis=-1):
    return v / (np.linalg.norm(v, axis=axis, keepdims=True) + 1e-9)


def cap(text, n=40):
    return " ".join(str(text or "").split()[:n])


def load_species(db_path):
    """{name: latin} lookup + {latin: {blob, fields[]}}."""
    con = sqlite3.connect(str(db_path))
    name2latin, latin2text = {}, {}
    rows = con.execute(
        "SELECT latin_name, common_name, visual_blob, color, body_shape, "
        "distinctive_marks, texture, pattern FROM species WHERE TRIM(visual_group)!=''"
    )
    for latin, common, blob, color, shape, marks, tex, pat in rows:
        latin = (latin or "").strip()
        if not latin:
            continue
        for key in (latin, common):
            if key and key.strip():
                name2latin[key.strip().lower()] = latin
        fields = [cap(t) for t in (color, shape, marks, tex, pat) if t and t.strip()]
        latin2text[latin] = {"blob": [cap(blob) or latin], "traits": fields or [cap(blob) or latin]}
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


def embed_phrases(model, phrases):
    import torch
    with torch.no_grad():
        emb = model.encode_text(list(phrases))
        emb = emb / emb.norm(dim=-1, keepdim=True)
    return emb.detach().cpu().numpy().astype(np.float32)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    import torch
    from transformers import AutoModel

    name2latin, latin2text = load_species(Path(args.db))
    samples = collect_images(Path(args.data_repo) / args.images_subdir, name2latin)
    if args.limit:
        samples = samples[: args.limit]
    species = sorted({s["sp"] for s in samples})
    sp_idx = {sp: i for i, sp in enumerate(species)}
    print(f"{len(species)} species · {len(samples)} images")

    print(f"Loading Talk2DINO ({args.hf_model}) …")
    model = AutoModel.from_pretrained(args.hf_model, trust_remote_code=True).eval()
    model.clip_model.float()
    backbone = model.model

    # ── per source: contiguous phrase bank + per-species slice + mean-of-phrases ──
    bank = {}
    for src in TEXT_SOURCES:
        flat, slices = [], []
        for sp in species:
            ph = latin2text[sp][src]
            slices.append((len(flat), len(flat) + len(ph)))
            flat.extend(ph)
        emb = embed_phrases(model, flat)                      # (P, D)
        tmean = np.stack([l2(emb[a:b].mean(0)) for a, b in slices])  # (S, D)
        bank[src] = {"emb": emb, "slices": slices, "tmean": tmean}

    acc = {src: {m: {"rr": 0.0, "r1": 0, "r5": 0} for m in POOLINGS} for src in TEXT_SOURCES}
    n = 0
    for s in samples:
        img = Image.open(s["path"]).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BICUBIC)
        arr = (np.asarray(img, np.float32) / 255.0 - MEAN) / STD
        with torch.no_grad():
            feats = backbone.forward_features(torch.from_numpy(arr.transpose(2, 0, 1)[None]))
            patch = feats["x_norm_patchtokens"][0]
            cls = feats["x_norm_clstoken"][0]
            cls_n = cls / (cls.norm() + 1e-6)
            sal = torch.softmax(patch @ cls_n, dim=0)
            pooled_sal = l2((sal[:, None] * patch).sum(0).numpy())
        X = l2(patch.numpy())                                  # (L, D)
        true = sp_idx[s["sp"]]
        n += 1
        for src in TEXT_SOURCES:
            b = bank[src]
            phrase_max = (b["emb"] @ X.T).max(axis=1)          # (P,)
            tm_sim = b["tmean"] @ X.T                           # (S, L)
            scores = {
                "global_sal": b["tmean"] @ pooled_sal,
                "dense_textmean_max": tm_sim.max(axis=1),
                "dense_phrase_mean": np.array([phrase_max[a:bb].mean() for a, bb in b["slices"]]),
                "dense_phrase_max": np.array([phrase_max[a:bb].max() for a, bb in b["slices"]]),
            }
            for m, sc in scores.items():
                rank = 1 + int((sc > sc[true]).sum())
                acc[src][m]["rr"] += 1.0 / rank
                acc[src][m]["r1"] += int(rank == 1)
                acc[src][m]["r5"] += int(rank <= 5)

    # ── report ──
    results = {}
    print(f"\n── conformant zero-shot species ID ({n} imgs × {len(species)} species) ──")
    print(f"  {'text':7s} {'pooling':20s} {'rank-1':>8s} {'rank-5':>8s} {'MRR':>7s}")
    for src in TEXT_SOURCES:
        results[src] = {}
        for m in POOLINGS:
            a = acc[src][m]
            row = {"rank1": a["r1"] / n, "rank5": a["r5"] / n, "mrr": a["rr"] / n}
            results[src][m] = row
            print(f"  {src:7s} {m:20s} {row['rank1']:8.1%} {row['rank5']:8.1%} {row['mrr']:7.3f}")

    base = results["blob"]["global_sal"]["rank1"]
    best = max((results[s][m]["rank1"], s, m) for s in TEXT_SOURCES for m in POOLINGS)
    print(f"\n  baseline (blob · global_sal) {base:.1%}  →  best {best[0]:.1%} ({best[1]} · {best[2]})  "
          f"Δ {best[0]-base:+.1%}")
    print("  ✅ a refinement beats the global baseline" if best[0] > base + 0.02 and "dense" in best[2]
          else "  ⚠ no dense refinement beats global — v3 premise still unsupported")

    # ── artifacts → outputs/ ──
    OUT_DIR.mkdir(exist_ok=True)
    summary = {"date": str(date.today()), "encoder": "talk2dino", "images": n,
               "species": len(species), "baseline_blob_global_sal": base,
               "best": {"rank1": best[0], "text": best[1], "pooling": best[2]},
               "results": results}
    (OUT_DIR / "q1_refined_results.json").write_text(json.dumps(summary, indent=2))
    lines = ["# Q1 refinement — localized phrases + better text", "",
             f"_{n} images · {len(species)} species · Talk2DINO · {date.today()}_", "",
             "| text | pooling | rank-1 | rank-5 | MRR |", "| --- | --- | ---: | ---: | ---: |"]
    for src in TEXT_SOURCES:
        for m in POOLINGS:
            r = results[src][m]
            lines.append(f"| {src} | {m} | {r['rank1']:.1%} | {r['rank5']:.1%} | {r['mrr']:.3f} |")
    lines += ["", f"Baseline (blob · global_sal): **{base:.1%}** · "
              f"best: **{best[0]:.1%}** ({best[1]} · {best[2]}, Δ {best[0]-base:+.1%})"]
    (OUT_DIR / "q1_refined_report.md").write_text("\n".join(lines) + "\n")
    print(f"\nWrote {OUT_DIR/'q1_refined_results.json'}")
    print(f"Wrote {OUT_DIR/'q1_refined_report.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
