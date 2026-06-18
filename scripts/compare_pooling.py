#!/usr/bin/env python3
"""Compare DINO single-vector pooling strategies for zero-shot attributes.

This is the diagnostic behind the design choice in
`docs/plans/smaller-footprint-architecture.md` §10.3: Talk2DINO is a *dense*
model, so reducing its patch tokens to one vector needs a pooling. We compare
three exportable options against the precomputed attribute vocabulary on real
photos, so the winner is picked from evidence rather than intuition:

  mean        — average all patch tokens (background dominates → wrong labels)
  cls         — the CLS token alone (outside the text-aligned patch space → noise)
  cls_sim_w   — patches weighted by softmax cosine-sim to CLS (SHIPPED: foregrounds
                the subject, stays in the aligned space)

Re-run this if you want to revisit the pooling (e.g. try Talk2DINO's true
`avg_self_attn`). It needs the exported `dino_attribute_embeddings.json` and the
same venv as the exporter.

USAGE
-----
  .venv-export/bin/python scripts/compare_pooling.py
  #   --images tiger=/path/a.jpg,panda=/path/b.jpg   (skip built-in downloads)
  #   --attrs color,texture,pattern,visual_group,body_shape
"""
from __future__ import annotations

import argparse
import json
import os
import tempfile
import urllib.request

import numpy as np

INPUT_SIZE = 518
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
DEFAULT_IMAGE_URLS = {
    "tiger": "https://upload.wikimedia.org/wikipedia/commons/thumb/5/56/Tiger.50.jpg/500px-Tiger.50.jpg",
    "panda": "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Grosser_Panda.JPG/500px-Grosser_Panda.JPG",
}


def l2(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def preprocess(path: str) -> np.ndarray:
    from PIL import Image

    img = Image.open(path).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BICUBIC)
    a = (np.asarray(img, np.float32) / 255.0 - MEAN) / STD
    return a.transpose(2, 0, 1)[None]


def fetch_images(local, no_download):
    if local:
        return local
    if no_download:
        return {}
    out, cache = {}, os.path.join(tempfile.gettempdir(), "mero_validate_imgs")
    os.makedirs(cache, exist_ok=True)
    for name, url in DEFAULT_IMAGE_URLS.items():
        dst = os.path.join(cache, f"{name}.jpg")
        if not os.path.exists(dst):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (mero)"})
                with open(dst, "wb") as f:
                    f.write(urllib.request.urlopen(req, timeout=60).read())
            except Exception as e:  # noqa: BLE001
                print(f"   [warn] could not download {name}: {e}")
                continue
        out[name] = dst
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir", default="assets/models")
    ap.add_argument("--hf-model", default="lorebianchi98/Talk2DINO-ViTB")
    ap.add_argument("--images", default="")
    ap.add_argument("--no-download", action="store_true")
    ap.add_argument("--attrs", default="color,texture,pattern,visual_group,body_shape")
    ap.add_argument("--topk", type=int, default=1)
    args = ap.parse_args()

    import torch
    from transformers import AutoModel

    vocab = json.load(open(os.path.join(args.models_dir, "dino_attribute_embeddings.json")))
    attrs = [a for a in args.attrs.split(",") if a in vocab]
    model = AutoModel.from_pretrained(args.hf_model, trust_remote_code=True).eval()
    backbone = model.model

    @torch.no_grad()
    def poolings(x):
        f = backbone.forward_features(torch.from_numpy(x))
        patch, cls = f["x_norm_patchtokens"][0], f["x_norm_clstoken"][0]
        cls_n = cls / (cls.norm() + 1e-6)
        w = torch.softmax(patch @ cls_n, dim=0)
        return {
            "mean": patch.mean(0).numpy(),
            "cls": cls.numpy(),
            "cls_sim_w": (w[:, None] * patch).sum(0).numpy(),
        }

    def top(emb, attr, k):
        labels = vocab[attr]
        s = l2(np.array([x["emb"] for x in labels], np.float32)) @ l2(emb)
        order = s.argsort()[::-1][:k]
        return ", ".join(f"{labels[i]['label']!r}({s[i]:.3f})" for i in order)

    images = fetch_images(_parse_images(args.images), args.no_download)
    if not images:
        print("No images (use --images name=path,...).")
        return
    for name, path in images.items():
        pools = poolings(preprocess(path))
        print(f"\n########## {name} ##########")
        for pool, emb in pools.items():
            print(f"  --- pooling: {pool} ---")
            for attr in attrs:
                print(f"      {attr:13} -> {top(emb, attr, args.topk)}")


def _parse_images(spec):
    if not spec:
        return None
    out = {}
    for part in spec.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out or None


if __name__ == "__main__":
    main()
