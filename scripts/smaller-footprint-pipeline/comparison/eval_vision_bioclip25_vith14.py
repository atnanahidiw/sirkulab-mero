#!/usr/bin/env python3
"""Evaluate BioCLIP 2.5 (ViT-H/14) zero-shot `visual_group` accuracy across prompt templates.

Uses the labeled image set in the **sibling** `sirkulab-mero-data` repo (resolved
relative to this file — no absolute paths), runs the comparison pipeline for this
model (image embedding ↔ label text embeddings), and measures how often the
predicted `visual_group` matches ground truth under each prompt template. This is
how we decide whether templating (e.g. "a photo of a {}") fixes class-level
mislabels like lizard→"Mollusk"/"Turtle".

Ground truth per image (best first):
  1. DB join — normalize the path's folder names to latin/common names and look
     them up in the app species DB → exact `visual_group`.
  2. CLASS_MAP — top taxonomic-class folder → `visual_group` (unambiguous classes
     only; Mammalia/plant classes are left to the DB join).
  3. else "unknown" — recorded in the JSONL but excluded from accuracy.

Outputs:
  - per-image JSONL → `<data-repo>/data/processed/vision_eval_visual_group_bioclip25_vith14.jsonl`
  - a note          → `<data-repo>/data/processed/README_vision_visual_group_bioclip25_vith14.md`
  - per-template accuracy printed to stdout.

USAGE
-----
  .venv-export/bin/python scripts/smaller-footprint-pipeline/comparison/eval_vision_bioclip25_vith14.py
  #   --limit 40                                            # quick smoke test
  #   --data-repo ../sirkulab-mero-data  --attr visual_group
"""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path

import numpy as np
from PIL import Image

from export_vision_model_bioclip25_vith14 import DISPLAY_NAME, HF_MODEL, SUFFIX, INPUT_SIZE, load_bioclip25_vith14  # noqa: E402

# Paths resolved relative to THIS file, so the two repos just need to be siblings.
HERE = Path(__file__).resolve()
APP_REPO = HERE.parents[3]                       # sirkulab-mero
WORKDIR = HERE.parents[4]                         # common parent
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)

TEMPLATES = ["{}", "a photo of a {}", "a photo of {}", "a close-up photo of a {}",
             "this is a {}", "an image of a {}"]

# Unambiguous taxonomic-class folder → visual_group (within the DB's 15 values).
# Ambiguous classes (Mammalia, Magnoliopsida, Liliopsida) are intentionally left
# out — they're only ground-truthed via the exact DB latin-name join.
CLASS_MAP = {
    "aves": "Flying bird", "amphibia": "Frog & toad", "squamata": "Lizard",
    "testudines": "Turtle & tortoise", "anthozoa": "Mollusk & marine invertebrate",
    "bivalvia": "Mollusk & marine invertebrate", "polypodiopsida": "Fern",
    "actinopterygii": "Marine fish", "elasmobranchii": "Marine fish",
    "chondrichthyes": "Marine fish",
}


def l2(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def image_embedding(enc, path: str) -> np.ndarray:
    import torch

    input_size = getattr(enc, "input_size", INPUT_SIZE)
    mean = np.asarray(getattr(enc, "mean", MEAN), np.float32)
    std = np.asarray(getattr(enc, "std", STD), np.float32)
    img = Image.open(path).convert("RGB").resize((input_size, input_size), Image.BICUBIC)
    arr = (np.asarray(img, np.float32) / 255.0 - mean) / std
    with torch.no_grad():
        emb = enc.image_module(torch.from_numpy(arr.transpose(2, 0, 1)[None])).cpu().numpy()[0]
    return l2(emb)


def load_db_lookup(db_path: Path):
    """{normalized name: visual_group} for both latin_name and common_name."""
    con = sqlite3.connect(str(db_path))
    lut = {}
    for col in ("latin_name", "common_name"):
        for name, vg in con.execute(
            f"SELECT {col}, visual_group FROM species "
            f"WHERE TRIM({col})!='' AND TRIM(visual_group)!=''"
        ):
            lut[name.strip().lower()] = vg
    con.close()
    return lut


def ground_truth(rel_path: Path, db_lut: dict):
    """(visual_group, source) or (None, 'unknown')."""
    parts = [p for p in rel_path.parts[:-1]]  # folders only
    # 1) DB join — deepest folder first (most specific = species)
    for folder in reversed(parts):
        name = folder.replace("_", " ").strip().lower()
        if name in db_lut:
            return db_lut[name], "db"
    # 2) class map — top taxonomic folder
    for folder in parts:
        if folder.lower() in CLASS_MAP:
            return CLASS_MAP[folder.lower()], "class_map"
    return None, "unknown"


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--embeddings",
                    default=str(APP_REPO / f"assets/models/attribute_embeddings_{SUFFIX}.json"))
    ap.add_argument("--attr", default="visual_group")
    ap.add_argument("--limit", type=int, default=0, help="cap images (quick test)")
    ap.add_argument("--hf-model", default=HF_MODEL)
    args = ap.parse_args()

    data_repo = Path(args.data_repo)
    img_root = data_repo / args.images_subdir
    out_dir = data_repo / "data" / "processed"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_jsonl = out_dir / f"vision_eval_{args.attr}_{SUFFIX}.jsonl"

    # Label set = exactly what the app ships (from the precomputed embeddings).
    vocab = json.load(open(args.embeddings))
    labels = [e["label"] for e in vocab[args.attr]]
    db_lut = load_db_lookup(Path(args.db))

    print(f"[1/4] loading {DISPLAY_NAME} …")
    enc = load_bioclip25_vith14(args.hf_model)

    print(f"[2/4] encoding {len(labels)} '{args.attr}' labels × {len(TEMPLATES)} templates …")
    tmpl_embs = {t: l2(enc.encode_text([t.format(x) for x in labels])) for t in TEMPLATES}

    # gather + dedupe images (the nested species_data_img/ duplicates some files)
    exts = {".jpg", ".jpeg", ".png"}
    images, seen = [], set()
    for p in sorted(img_root.rglob("*")):
        if p.suffix.lower() in exts and p.is_file():
            key = (p.name, p.stat().st_size)
            if key not in seen:
                seen.add(key)
                images.append(p)
    if args.limit:
        images = images[: args.limit]
    print(f"[3/4] scoring {len(images)} unique images …")

    correct = {t: 0 for t in TEMPLATES}
    evaluated = 0
    by_source = {"db": 0, "class_map": 0, "unknown": 0}
    with open(out_jsonl, "w") as f:
        for i, p in enumerate(images):
            rel = p.relative_to(img_root)
            gt, src = ground_truth(rel, db_lut)
            by_source[src] += 1
            try:
                emb = image_embedding(enc, str(p))
            except Exception as e:  # noqa: BLE001
                continue
            preds = {}
            for t, le in tmpl_embs.items():
                s = le @ emb
                j = int(s.argmax())
                preds[t] = {"label": labels[j], "score": round(float(s[j]), 4)}
            row = {"image": str(rel), "ground_truth": gt, "gt_source": src,
                   "predictions": preds}
            if gt is not None:
                evaluated += 1
                row["correct"] = {t: (preds[t]["label"] == gt) for t in TEMPLATES}
                for t in TEMPLATES:
                    correct[t] += row["correct"][t]
            f.write(json.dumps(row) + "\n")
            if (i + 1) % 50 == 0:
                print(f"   … {i + 1}/{len(images)}")

    # summary
    print(f"\n[4/4] {args.attr} accuracy over {evaluated} ground-truthed images "
          f"(db={by_source['db']}, class_map={by_source['class_map']}, "
          f"unknown={by_source['unknown']}):")
    ranked = sorted(TEMPLATES, key=lambda t: correct[t], reverse=True)
    for t in ranked:
        acc = correct[t] / evaluated if evaluated else 0
        mark = "►" if t == ranked[0] else " "
        print(f"   {mark} {acc:6.1%}  ({correct[t]}/{evaluated})  template={t!r}")
    print(f"\n   wrote {out_jsonl}")
    _write_note(out_dir, args, len(images), evaluated, by_source, ranked, correct)


def _write_note(out_dir, args, n_images, evaluated, by_source, ranked, correct):
    best = ranked[0]
    note = f"""# data/processed — vision template evaluation

Generated by `{Path(__file__).name}` in the **sirkulab-mero** app repo.
Not hand-authored — re-run the script to regenerate.

## `vision_eval_{args.attr}_{SUFFIX}.jsonl`
One JSON object per image:
- `image` — path relative to `{args.images_subdir}/`
- `ground_truth` — expected `{args.attr}` (`null` if undeterminable)
- `gt_source` — `db` (exact app-DB latin/common-name join) · `class_map`
  (unambiguous taxonomic-class folder) · `unknown` (excluded from accuracy)
- `predictions` — per prompt template: `{{label, score}}` (cosine)
- `correct` — per template, whether the prediction matched ground truth

## This run
- images scored: {n_images} (deduped) · ground-truthed: {evaluated}
  (db={by_source['db']}, class_map={by_source['class_map']}, unknown={by_source['unknown']})
- **best template: `{best}` → {correct[best] / evaluated:.1%}** accuracy
- raw labels `"{{}}"`: {correct['{}'] / evaluated:.1%}

## Caveats
- Ground truth leans on the curated app DB; species not in it fall back to the
  class map, and ambiguous classes (Mammalia, plant classes) are only labeled via
  the DB join (others → `unknown`, excluded from the metric).
- Pixel-identical duplicates across the nested `species_data_img/` folder are
  de-duplicated by (filename, size).
"""
    summary_path = out_dir / f"summary_vision_{args.attr}_{SUFFIX}.json"
    summary = {
        "display_name": DISPLAY_NAME,
        "suffix": SUFFIX,
        "attribute": args.attr,
        "images_scored": n_images,
        "ground_truthed": evaluated,
        "source_counts": by_source,
        "best_template": best,
        "best_accuracy": correct[best] / evaluated if evaluated else 0.0,
        "template_accuracy": {
            template: correct[template] / evaluated if evaluated else 0.0
            for template in ranked
        },
    }
    readme_path = out_dir / f"README_vision_{args.attr}_{SUFFIX}.md"
    readme_path.write_text(note)
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"   wrote {readme_path}")
    print(f"   wrote {summary_path}")


if __name__ == "__main__":
    main()
