#!/usr/bin/env python3
"""Interactive harness to debug + tune the DINO vision tool's zero-shot traits.

The on-device `extract_visual_features` sometimes mislabels (e.g. a lizard scored
as "Mollusk & marine invertebrate"). This script runs the SAME pipeline the app
uses (Talk2DINO CLS-saliency-pooled image embedding ↔ attribute label text) on a
real photo, so you can see the ranked predictions and iterate on the two levers
that move accuracy WITHOUT rebuilding the app:

  1. Prompt templates — raw category text ("Lizard") is weak for CLIP-style
     zero-shot; "a photo of a lizard" is much stronger. `--template` /
     `--compare-templates` test this. If a template wins, bake it into
     export_vision_model.py:export_embeddings and re-export.
  2. Label wording — `--probe` scores arbitrary candidate strings against the
     photo, so you can A/B better descriptions before changing the DB.

Setup (same venv as the exporter):
  uv venv .venv-export && VIRTUAL_ENV=.venv-export \
    uv pip install -r scripts/requirements-export.txt

USAGE
-----
  .venv-export/bin/python scripts/debug_vision.py --image photo.jpg
  #   --attrs visual_group,color,body_shape   --topk 8
  #   --template "a photo of a {}"
  #   --compare-templates                       # sweep templates on visual_group
  #   --probe "a lizard|a snake|a sea slug|a fish"   # score custom labels
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
from PIL import Image

# Reuse the EXACT shipped pipeline (saliency-pooled image head + encode_text).
from export_vision_model import (ATTRIBUTE_COLUMNS, INPUT_SIZE,  # noqa: E402
                                 build_vocabularies, load_talk2dino)

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)

DEFAULT_TEMPLATES = [
    "{}",
    "a photo of a {}",
    "a photo of {}",
    "a close-up photo of a {}",
    "this is a {}",
    "an image of a {}",
]


def l2(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def image_embedding(enc, path: str) -> np.ndarray:
    import torch

    img = Image.open(path).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BICUBIC)
    arr = (np.asarray(img, np.float32) / 255.0 - MEAN) / STD
    x = torch.from_numpy(arr.transpose(2, 0, 1)[None])
    with torch.no_grad():
        emb = enc.image_module(x).cpu().numpy()[0]
    return l2(emb)


def encode_labels(enc, labels, template: str) -> np.ndarray:
    texts = [template.format(lbl) for lbl in labels]
    return l2(enc.encode_text(texts))  # encode_text already L2-normalises


def rank(img_emb, label_embs, labels, topk):
    scores = label_embs @ img_emb
    order = scores.argsort()[::-1][:topk]
    return [(labels[i], float(scores[i])) for i in order]


def show(title, ranked):
    print(f"\n  {title}")
    for i, (lbl, sc) in enumerate(ranked):
        mark = "►" if i == 0 else " "
        print(f"    {mark} {sc:+.3f}  {lbl}")


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--image", required=True, help="photo to analyse")
    ap.add_argument("--db", default="assets/data/species_data.sqlite")
    ap.add_argument("--attrs", default=",".join(ATTRIBUTE_COLUMNS),
                    help="comma list of attributes to rank (default: all)")
    ap.add_argument("--template", default="{}",
                    help='label prompt template, e.g. "a photo of a {}"')
    ap.add_argument("--topk", type=int, default=6)
    ap.add_argument("--compare-templates", action="store_true",
                    help="sweep DEFAULT_TEMPLATES on visual_group to find the best")
    ap.add_argument("--probe", default="",
                    help='score custom "label|label|..." strings against the photo')
    ap.add_argument("--hf-model", default="lorebianchi98/Talk2DINO-ViTB")
    args = ap.parse_args()

    print(f"[1/3] loading Talk2DINO …")
    enc = load_talk2dino(args.hf_model)
    print(f"[2/3] embedding image: {args.image}")
    img_emb = image_embedding(enc, args.image)
    vocab = build_vocabularies(args.db)

    # Arbitrary-label probe — quickest way to test wording/hypotheses.
    if args.probe:
        labels = [s.strip() for s in args.probe.split("|") if s.strip()]
        embs = encode_labels(enc, labels, args.template)
        show(f"probe (template={args.template!r})", rank(img_emb, embs, labels, len(labels)))

    # Template sweep on visual_group (the field that mislabels most).
    if args.compare_templates:
        labels = vocab["visual_group"]
        print("\n[3/3] visual_group under each template (top-3):")
        for tmpl in DEFAULT_TEMPLATES:
            embs = encode_labels(enc, labels, tmpl)
            show(f"template={tmpl!r}", rank(img_emb, embs, labels, 3))
        return

    print(f"[3/3] ranked traits (template={args.template!r}):")
    for attr in [a.strip() for a in args.attrs.split(",") if a.strip() in vocab]:
        embs = encode_labels(enc, vocab[attr], args.template)
        show(attr, rank(img_emb, embs, vocab[attr], args.topk))


if __name__ == "__main__":
    sys.exit(main())
