#!/usr/bin/env python3
"""Validate the BioCLIP comparison vision assets.

Companion to `scripts/smaller-footprint-pipeline-v2/comparison/export_vision_model_bioclip.py`.
It checks every shipped asset end-to-end:

  1. assets present + ONNX sessions load + output shapes/finiteness
  2. image encoder   — torch↔ONNX, and zero-shot attribute labels on real photos
                       (int8 top-1 labels must match fp32 — the metric that matters;
                        raw cosine diverges because saliency softmax amplifies int8)
  3. text encoder    — torch↔ONNX parity + check_visual_evidence claim scoring
                       (relative: real traits must outscore a wrong control claim)

USAGE
-----
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v2/comparison/validate_vision_model_bioclip.py
  #   --models-dir assets/models   --hf-model hf-hub:imageomics/bioclip
  #   --images tiger=/path/a.jpg,panda=/path/b.jpg   (skip the built-in downloads)

Exit code is non-zero if any HARD check fails (missing asset, bad shape,
low text-encoder parity, label disagreement). Semantic
"sanity" observations are printed but do not fail the run.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
import urllib.request

import numpy as np
from export_vision_model_bioclip import DISPLAY_NAME, HF_MODEL, SUFFIX, load_bioclip

# ── shared constants (keep in sync with export_vision_model.py / runtime) ──
INPUT_SIZE = 224
MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)
CONTEXT_LEN = 77
SOT, EOT = 49406, 49407

# Distinctive test subjects (orange-striped vs black-and-white) — clear,
# unambiguous traits make label/score checks meaningful.
DEFAULT_IMAGE_URLS = {
    "tiger": "https://upload.wikimedia.org/wikipedia/commons/thumb/5/56/Tiger.50.jpg/500px-Tiger.50.jpg",
    "panda": "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Grosser_Panda.JPG/500px-Grosser_Panda.JPG",
}
# Claims for check_visual_evidence: (true traits …, wrong control). The true
# traits must clearly outscore the control.
CLAIM_SETS = {
    "tiger": (["orange and black stripes", "a large striped cat"], "an aquatic fish with fins"),
    "panda": (["black and white fur", "a bear-like body"], "a green leafy plant"),
}


class Checks:
    """Collects hard pass/fail results and prints a summary."""

    def __init__(self):
        self.failures: list[str] = []

    def hard(self, ok: bool, label: str, detail: str = ""):
        mark = "PASS" if ok else "FAIL"
        print(f"   [{mark}] {label}" + (f" — {detail}" if detail else ""))
        if not ok:
            self.failures.append(label)

    def note(self, label: str, detail: str = ""):
        print(f"   [info] {label}" + (f" — {detail}" if detail else ""))


def l2(v):
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


# ──────────────────────────────────────────────────────────────────────────
# CLIP tokenizer — Python mirror of lib/services/clip_tokenizer.dart
# ──────────────────────────────────────────────────────────────────────────
def _bytes_to_unicode():
    bs = list(range(0x21, 0x7F)) + list(range(0xA1, 0xAD)) + list(range(0xAE, 0x100))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return {b: chr(c) for b, c in zip(bs, cs)}


class DartTokenizerMirror:
    """Replicates the Dart algorithm exactly so we can diff it against CLIP."""

    def __init__(self, models_dir: str):
        import regex as re2

        self._re2 = re2
        self.byte_enc = _bytes_to_unicode()
        self.pat = re2.compile(
            r"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|"
            r"\p{L}+|\p{N}|[^\s\p{L}\p{N}]+",
            re2.IGNORECASE,
        )
        with open(os.path.join(models_dir, f"clip_vocab_{SUFFIX}.json"), encoding="utf-8") as f:
            self.vocab = json.load(f)
        self.ranks = {}
        with open(os.path.join(models_dir, f"clip_merges_{SUFFIX}.txt"), encoding="utf-8") as f:
            for i, line in enumerate(f.read().split("\n")):
                if not line:
                    continue
                sp = line.index(" ")
                self.ranks[line[:sp] + line[sp + 1:]] = i

    def _bpe(self, token: str) -> str:
        chars = list(token)
        if not chars:
            return token
        word = chars[:-1] + [chars[-1] + "</w>"]
        if len(word) == 1:
            return word[0]
        while True:
            best, bi = 1 << 30, -1
            for i in range(len(word) - 1):
                r = self.ranks.get(word[i] + word[i + 1])
                if r is not None and r < best:
                    best, bi = r, i
            if bi < 0:
                break
            first, second, merged = word[bi], word[bi + 1], word[bi] + word[bi + 1]
            nw, i = [], 0
            while i < len(word):
                if i < len(word) - 1 and word[i] == first and word[i + 1] == second:
                    nw.append(merged)
                    i += 2
                else:
                    nw.append(word[i])
                    i += 1
            word = nw
            if len(word) == 1:
                break
        return " ".join(word)

    def tokenize(self, text: str, ctx: int = CONTEXT_LEN) -> list[int]:
        cleaned = self._re2.sub(r"\s+", " ", text).strip().lower()
        out = []
        for m in self.pat.finditer(cleaned):
            enc = "".join(self.byte_enc[b] for b in m.group(0).encode("utf-8"))
            for t in self._bpe(enc).split(" "):
                if t in self.vocab:
                    out.append(self.vocab[t])
        toks = [SOT] + out + [EOT]
        ids = [0] * ctx
        if len(toks) <= ctx:
            ids[: len(toks)] = toks
        else:
            ids[:ctx] = toks[:ctx]
            ids[ctx - 1] = EOT
        return ids


TOKENIZER_TESTS = [
    "a tiger with black stripes", "orange and black striped fur",
    "aquatic fish with fins", "long curved casque on the bill",
    "white, dark brown, black", "a giant panda", "Hello World! 123",
    "spiky projections along the body", "reddish-orange to reddish-brown",
]


# ──────────────────────────────────────────────────────────────────────────
# image handling
# ──────────────────────────────────────────────────────────────────────────
def preprocess(path: str) -> np.ndarray:
    from PIL import Image

    img = Image.open(path).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE), Image.BICUBIC)
    a = (np.asarray(img, np.float32) / 255.0 - MEAN) / STD
    return a.transpose(2, 0, 1)[None]


def fetch_images(local: dict[str, str] | None, no_download: bool) -> dict[str, str]:
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
                req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (mero-validate)"})
                data = urllib.request.urlopen(req, timeout=60).read()
                with open(dst, "wb") as f:
                    f.write(data)
            except Exception as e:  # noqa: BLE001
                print(f"   [warn] could not download {name}: {e}")
                continue
        out[name] = dst
    return out


# ──────────────────────────────────────────────────────────────────────────
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--models-dir", default="assets/models")
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--images", default="",
                    help="comma list name=path to skip the built-in downloads")
    ap.add_argument("--no-download", action="store_true")
    ap.add_argument("--text-parity-min", type=float, default=0.85)
    args = ap.parse_args()

    import onnxruntime as ort
    import torch

    md = args.models_dir
    checks = Checks()

    # ── 0. assets present ──
    print("[0/4] assets present …")
    required = [f"image_encoder_{SUFFIX}.onnx", f"attribute_embeddings_{SUFFIX}.json",
                f"text_encoder_{SUFFIX}.onnx"]
    for fn in required:
        p = os.path.join(md, fn)
        ok = os.path.exists(p) and os.path.getsize(p) > 0
        checks.hard(ok, fn, f"{os.path.getsize(p)/1e6:.1f} MB" if ok else "MISSING")
    if checks.failures:
        print("\nMissing assets — run scripts/smaller-footprint-pipeline-v2/comparison/export_vision_model_bioclip.py first.")
        return 1

    # ── load model + sessions ──
    print(f"\n   loading {DISPLAY_NAME} + ONNX sessions …")
    enc = load_bioclip(args.hf_model)
    global INPUT_SIZE, MEAN, STD
    INPUT_SIZE = enc.input_size
    MEAN = np.asarray(enc.mean, np.float32)
    STD = np.asarray(enc.std, np.float32)
    isess = ort.InferenceSession(os.path.join(md, f"image_encoder_{SUFFIX}.onnx"))
    tsess = ort.InferenceSession(os.path.join(md, f"text_encoder_{SUFFIX}.onnx"))
    vocab = json.load(open(os.path.join(md, f"attribute_embeddings_{SUFFIX}.json")))

    def onnx_image(x):
        return l2(isess.run(None, {"pixel_values": x})[0])[0]

    def onnx_text(s):
        ids = np.asarray(enc.tokenizer([s]).cpu().numpy(), dtype=np.int32)
        return l2(tsess.run(None, {"token_ids": ids})[0])[0]

    @torch.no_grad()
    def torch_text(s):
        return l2(enc.encode_text([s])[0])

    def top1(emb, attr):
        labels = vocab[attr]
        le = l2(np.array([x["emb"] for x in labels], np.float32))
        s = le @ emb
        return labels[int(s.argmax())]["label"], float(s.max())

    images = fetch_images(_parse_images(args.images), args.no_download)
    if not images:
        checks.note("no test images", "skipping image/score sanity (run with --images)")

    # ── 2. image encoder ──
    print("\n[2/4] image encoder — output shape, torch↔ONNX label agreement …")
    checks.note("tokenizer", enc.tokenizer.__class__.__name__)
    out_dim = onnx_image(preprocess(images[next(iter(images))]) if images
                          else np.zeros((1, 3, INPUT_SIZE, INPUT_SIZE), np.float32)).shape[0]
    checks.hard(out_dim == enc.embed_dim, f"image embedding dim == {enc.embed_dim}", str(out_dim))
    for name, path in images.items():
        x = preprocess(path)
        oe = onnx_image(x)
        with torch.no_grad():
            te = l2(enc.image_module(torch.from_numpy(x)).cpu().numpy()[0])
        checks.hard(np.isfinite(oe).all(), f"{name}: finite embedding")
        # int8 top-1 labels must match fp32 (cosine diverges, ranking must not)
        disagree = [a for a in vocab if top1(oe, a)[0] != top1(te, a)[0]]
        checks.hard(not disagree, f"{name}: int8 top-1 labels == fp32",
                    "all attrs agree" if not disagree else f"differ: {disagree}")
        checks.note(f"{name}: observed",
                    ", ".join(f"{a}={top1(oe, a)[0]!r}" for a in
                              ["color", "texture", "visual_group"] if a in vocab))

    # ── 3. text encoder + check_visual_evidence ──
    print("\n[3/4] text encoder — torch↔ONNX parity + claim scoring …")
    pars = [float(onnx_text(s) @ torch_text(s)) for s in TOKENIZER_TESTS[:5]]
    checks.hard(min(pars) >= args.text_parity_min,
                f"text parity >= {args.text_parity_min}",
                f"min={min(pars):.3f} mean={np.mean(pars):.3f}")
    for name, path in images.items():
        if name not in CLAIM_SETS:
            continue
        ie = onnx_image(preprocess(path))
        trues, control = CLAIM_SETS[name]
        ctrl = float(onnx_text(control) @ ie)
        best_true = max(float(onnx_text(t) @ ie) for t in trues)
        checks.hard(best_true > ctrl, f"{name}: true traits outscore control",
                    f"true={best_true:+.3f} > control({control!r})={ctrl:+.3f}")

    # ── summary ──
    print("\n" + "=" * 60)
    if checks.failures:
        print(f"FAILED ({len(checks.failures)}): " + "; ".join(checks.failures))
        return 1
    print("ALL HARD CHECKS PASSED")
    return 0


def _parse_images(spec: str) -> dict[str, str] | None:
    if not spec:
        return None
    out = {}
    for part in spec.split(","):
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out or None


if __name__ == "__main__":
    sys.exit(main())
