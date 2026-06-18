#!/usr/bin/env python3
"""Export the on-device vision model + attribute embeddings for Mero.

Produces the two bundled assets consumed by `lib/services/vision_runtime.dart`:

  assets/models/dino_image_encoder.onnx        # int8 image encoder
  assets/models/dino_attribute_embeddings.json # per-attribute label text embeddings

The vision tool does ZERO-SHOT ATTRIBUTE CLASSIFICATION: embed the photo, then
for each trait attribute score the image embedding against that attribute's
controlled vocabulary of label-text embeddings and pick the best label. The
vocabularies are derived from the species DB so the extracted trait text matches
exactly what `search_similar_features` (FTS5 + Dice) compares against.

Model — DINO + text (Talk2DINO)
-------------------------------
Talk2DINO aligns CLIP **text** into DINOv2's image-feature space (the projection
runs on the text side; the DINO image features stay native). It's a dense
open-vocabulary model whose published image representation uses multi-head
"disentangled self-attention" pooling — which does not cleanly ONNX-export and
needs forward hooks + an is_training branch.

We ship a tractable single-vector APPROXIMATION (decided in design review):
  • image  = DINOv2-ViT-B/14-reg `forward_features['x_norm_patchtokens']`,
             CLS-SALIENCY-weighted pooled → one 768-d vector, L2-normalised
             (each patch weighted by softmax cosine-sim to the CLS token, a
             cheap exportable saliency proxy that foregrounds the subject;
             plain mean lets background dominate — empirically much worse).
  • text   = the REAL Talk2DINO `encode_text` (CLIP text → project_clip_txt),
             L2-normalised — same 768-d space, so cosine is meaningful.
This drops the attention-weighted pooling (good enough for coarse attributes)
in exchange for a clean export and the single-vector cosine the Dart runtime
([vision_runtime.dart]) already implements.

Everything (DINOv2 backbone + CLIP + projection) comes from the HF model
`lorebianchi98/Talk2DINO-ViTB` via `AutoModel(trust_remote_code=True)`.

SETUP (uv)
----------
  uv venv && uv pip install -r scripts/requirements-export.txt

USAGE
-----
  python scripts/export_vision_model.py            # downloads HF weights itself
  python scripts/validate_vision_model.py          # validate the produced assets

After running, update the model constants printed at the end into
`lib/services/vision_runtime.dart` (input name/size, output name, mean/std).
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from dataclasses import dataclass

import numpy as np
from PIL import Image

# Trait attributes the LLM's `search_similar_features` tool expects, mapped to
# their DB columns. These must stay in sync with the tool's required params in
# lib/models/chat_prompts.dart — extract_visual_features can only emit what's
# scored here. distinctive_marks has ~63 enumerable DB values (on par with
# pattern/color), so it's a controlled vocab like the rest.
ATTRIBUTE_COLUMNS = {
    "color": "color",
    "body_shape": "body_shape",
    "distinctive_marks": "distinctive_marks",
    "texture": "texture",
    "size_class": "size_class",
    "pattern": "pattern",
    "visual_group": "visual_group",
}

# Input resolution shared by the export and the precomputed embeddings.
# 518 = Talk2DINO's config `resize_dim`; 518/14 = 37 patches/side (clean for the
# ViT-B/14 backbone). The text projection was aligned at this resolution.
INPUT_SIZE = 518

# HF model bundling DINOv2 backbone + CLIP + the text projection head.
HF_MODEL = "lorebianchi98/Talk2DINO-ViTB"


@dataclass
class VisionEncoder:
    """Uniform interface over the two backends."""

    name: str
    input_name: str
    output_name: str
    mean: tuple
    std: tuple
    # callables set by the loader
    image_module: object        # torch.nn.Module: preprocessed tensor -> embedding
    encode_text: object         # Callable[[list[str]], np.ndarray]  (L2-normalised)
    text_module: object         # torch.nn.Module: token_ids[B,77] -> 768-d L2-norm
    context_length: int         # CLIP token context length (77)
    tokenizer: object           # clip SimpleTokenizer (for dumping vocab/merges)


# ──────────────────────────────────────────────────────────────────────────
# Model: Talk2DINO (DINO + text)
# ──────────────────────────────────────────────────────────────────────────
def load_talk2dino(hf_model: str = HF_MODEL) -> VisionEncoder:
    """Load Talk2DINO from the HF Hub (bundles DINOv2 + CLIP + the projection).

    image  = DINOv2 `forward_features['x_norm_patchtokens']`, CLS-saliency-weighted
             pooled → 768-d.
    text   = the real `encode_text` (CLIP text → project_clip_txt) → 768-d.
    Both L2-normalised into DINO's space, so cosine is meaningful.
    """
    import torch
    import clip
    from transformers import AutoModel

    print(f"  loading {hf_model} (downloads DINOv2 + CLIP weights on first run) …")
    model = AutoModel.from_pretrained(hf_model, trust_remote_code=True).eval()
    # CLIP loads in fp16; cast to fp32 so the attribute embeddings and the
    # exported text encoder are numerically consistent and quantizable.
    model.clip_model.float()

    # The bundled DINOv2 backbone. `encode_image` calls `self.model.forward_features`.
    backbone = getattr(model, "model", None)
    if backbone is None:
        raise AttributeError(
            "Could not find the DINOv2 backbone at `model.model`; inspect the "
            "loaded Talk2DINO module and adjust.")

    class _ImageHead(torch.nn.Module):
        """DINOv2 patch tokens → CLS-saliency-weighted pool → L2-norm vector.

        A plain mean drags in background (grass/foliage), which dominates the
        cosine and lands on the wrong labels (a panda matched plant traits). We
        weight each patch by its cosine similarity to the CLS token (a cheap,
        ONNX-exportable saliency proxy that foregrounds the subject and stays in
        Talk2DINO's text-aligned space). Validated far better than mean/CLS on
        tiger/panda zero-shot."""

        def __init__(self, dino):
            super().__init__()
            self.dino = dino

        def forward(self, pixel_values):
            feats = self.dino.forward_features(pixel_values)
            patch = feats["x_norm_patchtokens"]          # (B, L, D)
            cls = feats["x_norm_clstoken"]               # (B, D)
            cls_n = cls / (cls.norm(dim=-1, keepdim=True) + 1e-6)
            sal = torch.softmax((patch * cls_n.unsqueeze(1)).sum(-1), dim=1)  # (B, L)
            pooled = (sal.unsqueeze(-1) * patch).sum(dim=1)                   # (B, D)
            return pooled / pooled.norm(dim=-1, keepdim=True)

    @torch.no_grad()
    def encode_text(texts):
        emb = model.encode_text(list(texts))             # (N, D), DINO space
        emb = emb / emb.norm(dim=-1, keepdim=True)
        return emb.detach().cpu().numpy().astype(np.float32)

    class _TextHead(torch.nn.Module):
        """token_ids[B,77] → CLIP text → project_clip_txt → L2-norm 768-d.

        Same path as `encode_text`, but tokenisation is lifted out so the graph
        takes integer token IDs (the Dart CLIP tokenizer produces them at
        runtime for arbitrary `check_visual_evidence` claims)."""

        def __init__(self, clip_model, proj):
            super().__init__()
            self.clip_model = clip_model
            self.proj = proj

        def forward(self, token_ids):
            t = self.clip_model.encode_text(token_ids)   # [B, 512]
            p = self.proj.project_clip_txt(t)            # [B, 768], DINO space
            return p / p.norm(dim=-1, keepdim=True)

    # DINOv2 uses ImageNet normalisation.
    return VisionEncoder(
        name="talk2dino-salpool(dinov2_vitb14_reg)",
        input_name="pixel_values",
        output_name="image_embeds",
        mean=(0.485, 0.456, 0.406),
        std=(0.229, 0.224, 0.225),
        image_module=_ImageHead(backbone).eval(),
        encode_text=encode_text,
        text_module=_TextHead(model.clip_model, model.proj).eval(),
        context_length=77,
        tokenizer=clip.simple_tokenizer.SimpleTokenizer(),
    )


# ──────────────────────────────────────────────────────────────────────────
# DB vocabulary
# ──────────────────────────────────────────────────────────────────────────
def build_vocabularies(db_path: str, max_per_attr: int = 256) -> dict:
    """Distinct, non-empty trait values per attribute, from the species DB."""
    con = sqlite3.connect(db_path)
    vocab: dict[str, list[str]] = {}
    for attr, column in ATTRIBUTE_COLUMNS.items():
        rows = con.execute(
            f"SELECT TRIM([{column}]) v, COUNT(*) c FROM species "
            f"WHERE TRIM([{column}]) != '' GROUP BY v ORDER BY c DESC "
            f"LIMIT ?",
            (max_per_attr,),
        ).fetchall()
        seen, labels = set(), []
        for v, _ in rows:
            key = v.lower()
            if key not in seen:
                seen.add(key)
                labels.append(v)
        vocab[attr] = labels
        print(f"  {attr:14} {len(labels):4} labels")
    con.close()
    return vocab


# ──────────────────────────────────────────────────────────────────────────
# Export
# ──────────────────────────────────────────────────────────────────────────
def export_onnx(enc: VisionEncoder, out_dir: str, quantize: bool) -> str:
    import torch

    fp32 = os.path.join(out_dir, "dino_image_encoder.fp32.onnx")
    final = os.path.join(out_dir, "dino_image_encoder.onnx")
    dummy = torch.randn(1, 3, INPUT_SIZE, INPUT_SIZE)
    torch.onnx.export(
        enc.image_module, dummy, fp32,
        input_names=[enc.input_name], output_names=[enc.output_name],
        opset_version=17, do_constant_folding=True,
        dynamo=False,  # stable TorchScript exporter (dynamo path needs onnxscript)
    )
    if quantize:
        from onnxruntime.quantization import quantize_dynamic, QuantType
        quantize_dynamic(fp32, final, weight_type=QuantType.QInt8)
        os.remove(fp32)
    else:
        os.replace(fp32, final)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB)")
    return final


def export_text_onnx(enc: VisionEncoder, out_dir: str, quantize: bool) -> str:
    """Export the runtime text encoder (token_ids → 768-d) for v2's
    check_visual_evidence (arbitrary-claim scoring)."""
    import torch

    fp32 = os.path.join(out_dir, "dino_text_encoder.fp32.onnx")
    final = os.path.join(out_dir, "dino_text_encoder.onnx")
    # int32 token IDs, [batch, context_length]; batch axis is dynamic.
    dummy = torch.zeros(1, enc.context_length, dtype=torch.int32)
    dummy[0, 0], dummy[0, 1] = 49406, 49407  # SOT, EOT
    torch.onnx.export(
        enc.text_module, dummy, fp32,
        input_names=["token_ids"], output_names=["text_embeds"],
        dynamic_axes={"token_ids": {0: "batch"}, "text_embeds": {0: "batch"}},
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    if quantize:
        from onnxruntime.quantization import quantize_dynamic, QuantType
        quantize_dynamic(fp32, final, weight_type=QuantType.QInt8)
        os.remove(fp32)
    else:
        os.replace(fp32, final)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB)")
    return final


def dump_tokenizer(enc: VisionEncoder, out_dir: str) -> None:
    """Dump the CLIP BPE vocab + merges so the Dart tokenizer can reproduce
    `clip.tokenize` exactly. byte↔unicode is recomputed in Dart (deterministic)."""
    tk = enc.tokenizer
    vocab_path = os.path.join(out_dir, "clip_vocab.json")
    with open(vocab_path, "w", encoding="utf-8") as f:
        json.dump(tk.encoder, f, ensure_ascii=False)  # token string -> id
    # merges ordered by BPE rank, "tokenA tokenB" per line (no literal spaces
    # inside tokens — space byte maps to a non-ASCII unicode char).
    merges = sorted(tk.bpe_ranks, key=tk.bpe_ranks.get)
    merges_path = os.path.join(out_dir, "clip_merges.txt")
    with open(merges_path, "w", encoding="utf-8") as f:
        f.write("\n".join(f"{a} {b}" for a, b in merges))
    print(f"  wrote {vocab_path} ({os.path.getsize(vocab_path)/1e6:.1f} MB), "
          f"{merges_path} ({os.path.getsize(merges_path)/1e6:.1f} MB)")


def export_embeddings(enc: VisionEncoder, vocab: dict, out_dir: str) -> str:
    table = {}
    for attr, labels in vocab.items():
        if not labels:
            continue
        embs = enc.encode_text(labels)  # [N, D], L2-normalised
        table[attr] = [
            {"label": lbl, "emb": [round(float(x), 6) for x in embs[i]]}
            for i, lbl in enumerate(labels)
        ]
    path = os.path.join(out_dir, "dino_attribute_embeddings.json")
    with open(path, "w") as f:
        json.dump(table, f)
    print(f"  wrote {path}  ({os.path.getsize(path) / 1e6:.1f} MB)")
    return path


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", default="assets/data/species_data.sqlite")
    ap.add_argument("--out", default="assets/models")
    ap.add_argument("--no-quantize", action="store_true",
                    help="skip int8 quantization (larger, debug)")
    ap.add_argument("--hf-model", default=HF_MODEL)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    print("[1/4] loading DINO (Talk2DINO: DINOv2 + text, CLS-saliency-pool) …")
    enc = load_talk2dino(args.hf_model)

    print("[2/4] building attribute vocabularies from DB …")
    vocab = build_vocabularies(args.db)

    print("[3/5] exporting image encoder → ONNX …")
    export_onnx(enc, args.out, quantize=not args.no_quantize)

    print("[4/5] encoding attribute labels → embeddings …")
    export_embeddings(enc, vocab, args.out)

    print("[5/5] exporting text encoder + tokenizer (v2: check_visual_evidence) …")
    export_text_onnx(enc, args.out, quantize=not args.no_quantize)
    dump_tokenizer(enc, args.out)

    print("\nDONE. Update lib/services/vision_runtime.dart constants to match:")
    print(f"  _inputName  = '{enc.input_name}'")
    print(f"  _outputName = '{enc.output_name}'")
    print(f"  _inputSize  = {INPUT_SIZE}")
    print(f"  _mean = {list(enc.mean)}")
    print(f"  _std  = {list(enc.std)}")
    print(f"  text encoder: token_ids[1,{enc.context_length}] int32 → text_embeds[1,768]")
    print(f"  (model: {enc.name})")


if __name__ == "__main__":
    main()
