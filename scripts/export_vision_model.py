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
# Export + mobile-safe quantization
# ──────────────────────────────────────────────────────────────────────────
# Quantization modes. For these *embedding* models the int8 paths both fail:
#   fp16    — float16 weights via onnxruntime.transformers (Casts to fp32 where
#             no fp16 kernel exists; standard Conv/MatMul only). Near-fp32
#             accuracy (cosine ~1.0) AND always runs on ORT-Android. DEFAULT.
#   qdq     — static int8 → QLinearConv/QLinearMatMul (mobile-supported), but
#             int8 *activations* crush the 768-d embedding direction → cosine
#             geometry collapses (tiger→"green", parity≈0). Unusable here.
#   dynamic — int8 dynamic, MatMul-only (Conv excluded → no ConvInteger).
#             Activations stay fp32 so accuracy is fine (~0.99), ~half fp16 size,
#             but emits MatMulInteger — verify it loads on the target ORT-Android
#             build before relying on it (full quantize_dynamic also hits the
#             unsupported ConvInteger; that's why Conv is excluded here).
#   none    — fp32 (largest; reference).
# Net: fp16 always works + is accurate (default); dynamic is smaller but unverified.
QUANT_MODES = ("fp16", "qdq", "dynamic", "none")

# Varied subjects so static calibration sees a representative activation range.
CALIB_IMAGE_URLS = [
    "https://upload.wikimedia.org/wikipedia/commons/thumb/5/56/Tiger.50.jpg/500px-Tiger.50.jpg",
    "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0f/Grosser_Panda.JPG/500px-Grosser_Panda.JPG",
    "https://upload.wikimedia.org/wikipedia/commons/thumb/4/45/Eopsaltria_australis_-_Mogo_Campground.jpg/500px-Eopsaltria_australis_-_Mogo_Campground.jpg",
    "https://upload.wikimedia.org/wikipedia/commons/thumb/8/84/Red_eyed_tree_frog_edit2.jpg/500px-Red_eyed_tree_frog_edit2.jpg",
    "https://upload.wikimedia.org/wikipedia/commons/thumb/6/68/Orchid_-_Phalaenopsis.jpg/500px-Orchid_-_Phalaenopsis.jpg",
    "https://upload.wikimedia.org/wikipedia/commons/thumb/3/3a/Acporcellus.jpg/500px-Acporcellus.jpg",
]


def _calib_image_feeds(input_name: str):
    """Preprocessed image tensors for static calibration. Best-effort download;
    returns whatever succeeds (None if the network is unavailable)."""
    import tempfile
    import urllib.request

    feeds = []
    for url in CALIB_IMAGE_URLS:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (mero)"})
            data = urllib.request.urlopen(req, timeout=60).read()
            tmp = os.path.join(tempfile.gettempdir(), os.path.basename(url))
            with open(tmp, "wb") as f:
                f.write(data)
            img = Image.open(tmp).convert("RGB").resize((INPUT_SIZE, INPUT_SIZE))
            arr = (np.asarray(img, np.float32) / 255.0 - np.array([0.485, 0.456, 0.406], np.float32)) \
                / np.array([0.229, 0.224, 0.225], np.float32)
            feeds.append({input_name: arr.transpose(2, 0, 1)[None]})
        except Exception as e:  # noqa: BLE001
            print(f"    [warn] calib image skipped ({e})")
    return feeds


def _calib_text_feeds(input_name: str):
    """Tokenised sample claims for static calibration (offline)."""
    import clip

    phrases = [
        "orange and black stripes", "a large striped cat", "black and white fur",
        "a bear-like body", "green leafy plant", "bright red scales",
        "long curved casque on the bill", "iridescent blue feathers",
        "smooth grey skin", "spiky projections along the body",
        "a small brown rodent", "webbed feet and a flat bill",
        "elongated serpentine body", "translucent fins", "furry and round",
        "dark facial markings", "a tall wading bird", "rough bark texture",
    ]
    return [
        {input_name: clip.tokenize([p]).numpy().astype(np.int32)} for p in phrases
    ]


def _quantize(fp32: str, final: str, quant: str, input_name: str, calib_feeds) -> None:
    """Apply the chosen quantization, writing `final` and removing `fp32`."""
    if quant == "none":
        os.replace(fp32, final)
        return
    if quant == "fp16":
        # onnxruntime.transformers' fp16 converter inserts Casts correctly for
        # this graph (onnxconverter_common leaves mixed-type Div nodes that ORT
        # rejects at load). keep_io_types → fp32 I/O, so Dart sends fp32 as-is.
        import onnx
        from onnxruntime.transformers.onnx_model import OnnxModel

        om = OnnxModel(onnx.load(fp32))
        om.convert_float_to_float16(keep_io_types=True)
        om.save_model_to_file(final)
        os.remove(fp32)
        return
    if quant == "dynamic":
        # Exclude Conv (the single patch-embed) so we DON'T emit ConvInteger,
        # which ORT-Android lacks. Only MatMul is quantized → MatMulInteger,
        # activations stay fp32 so accuracy is preserved (~cosine 0.99). ~half
        # the fp16 size, but MatMulInteger support on the target build is not
        # guaranteed — verify on-device before relying on it.
        from onnxruntime.quantization import QuantType, quantize_dynamic

        quantize_dynamic(fp32, final, weight_type=QuantType.QInt8,
                         op_types_to_quantize=["MatMul"])
        os.remove(fp32)
        return
    # qdq — static int8, mobile-safe
    from onnxruntime.quantization import (CalibrationDataReader, QuantFormat,
                                          QuantType, quantize_static)
    from onnxruntime.quantization.shape_inference import quant_pre_process

    if not calib_feeds:
        raise RuntimeError(
            "qdq needs calibration data but none was available (offline?). "
            "Re-run with --quant fp16 for a no-calibration mobile-safe export.")

    class _Reader(CalibrationDataReader):
        def __init__(self, feeds):
            self._it = iter(feeds)

        def get_next(self):
            return next(self._it, None)

    pre = fp32 + ".pre.onnx"
    try:
        quant_pre_process(fp32, pre, skip_symbolic_shape=True)
        src = pre
    except Exception as e:  # noqa: BLE001 — some graphs defeat shape inference
        print(f"    [warn] quant_pre_process failed ({e}); quantizing raw fp32")
        src = fp32
    quantize_static(
        src, final, _Reader(calib_feeds),
        quant_format=QuantFormat.QDQ, per_channel=True,
        weight_type=QuantType.QInt8, activation_type=QuantType.QUInt8,
    )
    for p in (fp32, pre):
        if os.path.exists(p):
            os.remove(p)


def export_onnx(enc: VisionEncoder, out_dir: str, quant: str) -> str:
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
    calib = _calib_image_feeds(enc.input_name) if quant == "qdq" else None
    _quantize(fp32, final, quant, enc.input_name, calib)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB, quant={quant})")
    return final


def export_text_onnx(enc: VisionEncoder, out_dir: str, quant: str) -> str:
    """Export the runtime text encoder (token_ids → 768-d) for v2's
    check_visual_evidence (arbitrary-claim scoring)."""
    import torch

    fp32 = os.path.join(out_dir, "dino_text_encoder.fp32.onnx")
    final = os.path.join(out_dir, "dino_text_encoder.onnx")
    # int32 token IDs, fixed [1, context_length] — the runtime scores one claim
    # per run, and a static shape lets QDQ shape-inference/quantization succeed.
    dummy = torch.zeros(1, enc.context_length, dtype=torch.int32)
    dummy[0, 0], dummy[0, 1] = 49406, 49407  # SOT, EOT
    torch.onnx.export(
        enc.text_module, dummy, fp32,
        input_names=["token_ids"], output_names=["text_embeds"],
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    calib = _calib_text_feeds("token_ids") if quant == "qdq" else None
    _quantize(fp32, final, quant, "token_ids", calib)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB, quant={quant})")
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
    # Per-encoder defaults pick each encoder's best option:
    #   image = dynamic int8 (MatMul-only → MatMulInteger, verified on ORT-Android;
    #           ~92 MB — far smaller than fp16's ~173 MB, no big embedding table)
    #   text  = fp16 (~129 MB, lossless). dynamic int8 is LARGER here (~141 MB):
    #           CLIP's 49k-token embedding is a Gather, not a MatMul, so MatMul-only
    #           quant leaves it fp32 while fp16 halves it.
    ap.add_argument("--image-quant", choices=QUANT_MODES, default="dynamic",
                    help="image encoder precision (default: dynamic int8, verified on ORT-Android)")
    ap.add_argument("--text-quant", choices=QUANT_MODES, default="fp16",
                    help="text encoder precision (default: fp16; smaller AND more accurate than int8 here)")
    ap.add_argument("--hf-model", default=HF_MODEL)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)

    print("[1/4] loading DINO (Talk2DINO: DINOv2 + text, CLS-saliency-pool) …")
    enc = load_talk2dino(args.hf_model)

    print("[2/4] building attribute vocabularies from DB …")
    vocab = build_vocabularies(args.db)

    print(f"[3/5] exporting image encoder → ONNX (quant={args.image_quant}) …")
    export_onnx(enc, args.out, args.image_quant)

    print("[4/5] encoding attribute labels → embeddings …")
    export_embeddings(enc, vocab, args.out)

    print(f"[5/5] exporting text encoder (quant={args.text_quant}) + tokenizer …")
    export_text_onnx(enc, args.out, args.text_quant)
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
