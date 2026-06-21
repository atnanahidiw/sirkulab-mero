#!/usr/bin/env python3
"""Export the on-device vision model + attribute embeddings for Mero.

Produces the bundled assets consumed by `lib/services/vision_runtime.dart`:

  assets/models/image_encoder_mobileclip2_s2.onnx        # image encoder
  assets/models/attribute_embeddings_mobileclip2_s2.json # per-attribute label text embeddings

The vision tool does ZERO-SHOT ATTRIBUTE CLASSIFICATION: embed the photo, then
for each trait attribute score the image embedding against that attribute's
controlled vocabulary of label-text embeddings and pick the best label. The
vocabularies are derived from the species DB so the extracted trait text matches
exactly what `search_similar_features` (FTS5 + Dice) compares against.

Model — CLIP-style image/text encoder (MobileCLIP2-S2)
-------------------------------
MobileCLIP2-S2 is loaded through open_clip from
`MobileCLIP2-S2` with pretrained weights `dfndr2b`. The model already exposes a standard
`encode_image` / `encode_text` interface, so the export is now a straight
image-text pair with no saliency-pooling approximation.

The exporter uses the model's own preprocessing, tokenizer, and embedding
dimension. The resulting ONNX graphs are therefore model-native rather than a
Talk2DINO-style reconstruction.

SETUP (uv)
----------
  uv venv && uv pip install -r scripts/requirements-export.txt

USAGE
-----
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v2/comparison/export_vision_model_mobileclip2_s2.py   # downloads weights itself
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v2/comparison/validate_vision_model_mobileclip2_s2.py # validate the produced assets

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

# Model suffix used in exported artifact names.
SUFFIX = "mobileclip2_s2"
INPUT_SIZE = 256  # mobileclip2_s2 native size (import fallback); runtime resolves enc.input_size dynamically

# Human-readable label used in logs / summaries.
DISPLAY_NAME = "MobileCLIP2 (S2)"

# open_clip model id and pretrained tag.
HF_MODEL = "MobileCLIP2-S2"
OPEN_CLIP_PRETRAINED = "dfndr2b"

# Prompt ensembles applied to label TEXT before embedding (the stored label
# string stays raw — only the embedding changes). We keep multiple prompts
# around so the exporter can choose the strongest prompt-specific embedding.
#
# visual_group gets image-like prompts because it is a coarse category label.
# The other attributes are phrase-like trait descriptions, so they get a small
# generic ensemble that keeps the wording flexible without forcing awkward
# grammar.
ATTR_PROMPT_ENSEMBLES = {
    "visual_group": (
        "{}",
        "a photo of a {}",
        "a close-up photo of a {}",
        "an image of a {}",
        "a field guide photo of a {}",
    ),
}
DEFAULT_PROMPT_ENSEMBLE = (
    "{}",
    "trait: {}",
    "appearance: {}",
)


def _max_prompt_index(vectors: np.ndarray) -> int:
    """Return the prompt embedding with the largest average similarity."""
    if len(vectors) == 1:
        return 0
    sims = vectors @ vectors.T
    scores = sims.mean(axis=1)
    return int(np.argmax(scores))


@dataclass
class VisionEncoder:
    """Uniform interface over the two backends."""

    name: str
    input_size: int
    input_name: str
    output_name: str
    embed_dim: int
    mean: tuple
    std: tuple
    # callables set by the loader
    image_module: object        # torch.nn.Module: preprocessed tensor -> embedding
    encode_text: object         # Callable[[list[str]], np.ndarray]  (L2-normalised)
    text_module: object         # torch.nn.Module: token_ids[B,77] -> 768-d L2-norm
    context_length: int         # CLIP token context length (77)
    tokenizer: object           # clip SimpleTokenizer (for dumping vocab/merges)


# ──────────────────────────────────────────────────────────────────────────
# Model: MobileCLIP2-S2
# ──────────────────────────────────────────────────────────────────────────
def load_mobileclip2_s2(hf_model: str = HF_MODEL) -> VisionEncoder:
    """Load MobileCLIP2-S2 via open_clip."""
    import torch
    import open_clip

    print(f"  loading {hf_model} via open_clip …")
    model, _, preprocess = open_clip.create_model_and_transforms(
        hf_model, pretrained=OPEN_CLIP_PRETRAINED
    )
    model = model.float().eval()
    tokenizer = open_clip.get_tokenizer(hf_model)

    input_size = getattr(getattr(model, "visual", None), "image_size", None)
    if isinstance(input_size, (tuple, list)):
        input_size = int(input_size[0])
    if input_size is None:
        for t in getattr(preprocess, "transforms", []):
            size = getattr(t, "size", None)
            if size is not None:
                input_size = int(size[0] if isinstance(size, (tuple, list)) else size)
                break
    if input_size is None:
        raise AttributeError("Could not infer the image size from open_clip.")

    mean = std = None
    for t in getattr(preprocess, "transforms", []):
        if t.__class__.__name__ == "Normalize":
            mean = tuple(float(x) for x in t.mean)
            std = tuple(float(x) for x in t.std)
            break
    if mean is None or std is None:
        raise AttributeError("Could not infer the normalization from open_clip.")

    embed_dim = int(getattr(model, "embed_dim", 0) or 0)
    if embed_dim <= 0:
        embed_dim = int(getattr(getattr(model, "visual", None), "output_dim", 0) or 0)
    if embed_dim <= 0:  # robust: a dummy forward yields the dim for any open_clip model
        with torch.no_grad():
            embed_dim = int(model.encode_image(
                torch.zeros(1, 3, input_size, input_size)).shape[-1])

    class _ImageHead(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.clip_model = clip_model

        def forward(self, pixel_values):
            emb = self.clip_model.encode_image(pixel_values)
            return emb / (emb.norm(dim=-1, keepdim=True) + 1e-6)

    @torch.no_grad()
    def encode_text(texts):
        token_ids = tokenizer(list(texts))
        emb = model.encode_text(token_ids)
        emb = emb / (emb.norm(dim=-1, keepdim=True) + 1e-6)
        return emb.detach().cpu().numpy().astype(np.float32)

    class _TextHead(torch.nn.Module):
        def __init__(self, clip_model):
            super().__init__()
            self.clip_model = clip_model

        def forward(self, token_ids):
            token_ids = token_ids.to(dtype=torch.long)
            emb = self.clip_model.encode_text(token_ids)
            return emb / (emb.norm(dim=-1, keepdim=True) + 1e-6)

    return VisionEncoder(
        name=DISPLAY_NAME,
        input_size=input_size,
        input_name="pixel_values",
        output_name="image_embeds",
        embed_dim=embed_dim,
        mean=mean,
        std=std,
        image_module=_ImageHead(model).eval(),
        encode_text=encode_text,
        text_module=_TextHead(model).eval(),
        context_length=int(getattr(tokenizer, "context_length", getattr(model, "context_length", 77))),
        tokenizer=tokenizer,
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


def _calib_image_feeds(input_name: str, input_size: int, mean: tuple, std: tuple):
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
            img = Image.open(tmp).convert("RGB").resize((input_size, input_size))
            arr = (np.asarray(img, np.float32) / 255.0 - np.array(mean, np.float32)) \
                / np.array(std, np.float32)
            feeds.append({input_name: arr.transpose(2, 0, 1)[None]})
        except Exception as e:  # noqa: BLE001
            print(f"    [warn] calib image skipped ({e})")
    return feeds


def _calib_text_feeds(input_name: str, tokenizer):
    """Tokenised sample claims for static calibration (offline)."""
    phrases = [
        "orange and black stripes", "a large striped cat", "black and white fur",
        "a bear-like body", "green leafy plant", "bright red scales",
        "long curved casque on the bill", "iridescent blue feathers",
        "smooth grey skin", "spiky projections along the body",
        "a small brown rodent", "webbed feet and a flat bill",
        "elongated serpentine body", "translucent fins", "furry and round",
        "dark facial markings", "a tall wading bird", "rough bark texture",
    ]
    return [{input_name: tokenizer([p]).cpu().numpy().astype(np.int32)} for p in phrases]


def _remove_onnx_with_external(path: str) -> None:
    """Remove an .onnx file *and* the external-data sidecar files it spilled.
    torch.onnx.export writes each weight as a loose file next to the .onnx when
    the model exceeds the 2 GB protobuf limit (e.g. the ViT-H/14 fp32 image
    tower). A bare os.remove(path) would orphan hundreds of those weight files
    in the output dir, so read the references first and delete them too."""
    if not os.path.exists(path):
        return
    try:
        import onnx
        model = onnx.load(path, load_external_data=False)
        base = os.path.dirname(path)
        for tensor in model.graph.initializer:
            for d in tensor.external_data:
                if d.key == "location":
                    sidecar = os.path.join(base, d.value)
                    if os.path.exists(sidecar):
                        os.remove(sidecar)
    except Exception:
        pass
    os.remove(path)


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
        _remove_onnx_with_external(fp32)
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
        _remove_onnx_with_external(fp32)
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
        _remove_onnx_with_external(p)


def export_onnx(enc: VisionEncoder, out_dir: str, quant: str) -> str:
    import torch

    fp32 = os.path.join(out_dir, f"image_encoder_{SUFFIX}.fp32.onnx")
    final = os.path.join(out_dir, f"image_encoder_{SUFFIX}.onnx")
    dummy = torch.randn(1, 3, enc.input_size, enc.input_size)
    torch.onnx.export(
        enc.image_module, dummy, fp32,
        input_names=[enc.input_name], output_names=[enc.output_name],
        opset_version=17, do_constant_folding=True,
        dynamo=False,  # stable TorchScript exporter (dynamo path needs onnxscript)
    )
    calib = _calib_image_feeds(enc.input_name, enc.input_size, enc.mean, enc.std) if quant == "qdq" else None
    _quantize(fp32, final, quant, enc.input_name, calib)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB, quant={quant})")
    return final


def export_text_onnx(enc: VisionEncoder, out_dir: str, quant: str) -> str:
    """Export the runtime text encoder (token_ids → 768-d) for v2's
    check_visual_evidence (arbitrary-claim scoring)."""
    import torch

    fp32 = os.path.join(out_dir, f"text_encoder_{SUFFIX}.fp32.onnx")
    final = os.path.join(out_dir, f"text_encoder_{SUFFIX}.onnx")
    # int32 token IDs, fixed [1, context_length] — the runtime scores one claim
    # per run, and a static shape lets QDQ shape-inference/quantization succeed.
    dummy = torch.zeros(1, enc.context_length, dtype=torch.int32)
    sot = int(getattr(enc.tokenizer, "sot_token_id", 49406))
    eot = int(getattr(enc.tokenizer, "eot_token_id", 49407))
    dummy[0, 0], dummy[0, 1] = sot, eot
    torch.onnx.export(
        enc.text_module, dummy, fp32,
        input_names=["token_ids"], output_names=["text_embeds"],
        opset_version=17, do_constant_folding=True, dynamo=False,
    )
    calib = _calib_text_feeds("token_ids", enc.tokenizer) if quant == "qdq" else None
    _quantize(fp32, final, quant, "token_ids", calib)
    print(f"  wrote {final}  ({os.path.getsize(final) / 1e6:.1f} MB, quant={quant})")
    return final


def dump_tokenizer(enc: VisionEncoder, out_dir: str) -> None:
    """Persist tokenizer assets when the tokenizer exposes BPE tables.

    CLIP-style tokenizers still get the vocab/merges pair used by the Dart
    mirror. If the tokenizer is HuggingFace-based, we keep a small manifest and
    try to save the tokenizer in its native format as a fallback.
    """
    tk = enc.tokenizer
    if hasattr(tk, "encoder") and hasattr(tk, "bpe_ranks"):
        vocab_path = os.path.join(out_dir, f"clip_vocab_{SUFFIX}.json")
        with open(vocab_path, "w", encoding="utf-8") as f:
            json.dump(tk.encoder, f, ensure_ascii=False)
        merges = sorted(tk.bpe_ranks, key=tk.bpe_ranks.get)
        merges_path = os.path.join(out_dir, f"clip_merges_{SUFFIX}.txt")
        with open(merges_path, "w", encoding="utf-8") as f:
            f.write("\n".join(f"{a} {b}" for a, b in merges))
        print(
            f"  wrote {vocab_path} ({os.path.getsize(vocab_path)/1e6:.1f} MB), "
            f"{merges_path} ({os.path.getsize(merges_path)/1e6:.1f} MB)"
        )
        return

    manifest_path = os.path.join(out_dir, f"tokenizer_{SUFFIX}.json")
    manifest = {
        "model": DISPLAY_NAME,
        "tokenizer_class": tk.__class__.__name__,
        "context_length": enc.context_length,
    }
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    if hasattr(tk, "save_pretrained"):
        tok_dir = os.path.join(out_dir, f"tokenizer_{SUFFIX}")
        os.makedirs(tok_dir, exist_ok=True)
        tk.save_pretrained(tok_dir)
    print(f"  wrote {manifest_path} ({os.path.getsize(manifest_path)/1e6:.1f} MB)")


def export_embeddings(enc: VisionEncoder, vocab: dict, out_dir: str) -> str:
    table = {}
    for attr, labels in vocab.items():
        if not labels:
            continue
        templates = ATTR_PROMPT_ENSEMBLES.get(attr, DEFAULT_PROMPT_ENSEMBLE)
        prompt_embs = []
        for tmpl in templates:
            prompt_embs.append(enc.encode_text([tmpl.format(lbl) for lbl in labels]))
        prompt_stack = np.stack(prompt_embs, axis=0)  # [T, N, D]
        fused_embs = []
        for i, _lbl in enumerate(labels):
            label_prompts = prompt_stack[:, i, :]
            fused_embs.append(label_prompts[_max_prompt_index(label_prompts)])
        embs = np.asarray(fused_embs, dtype=np.float32)
        if templates != DEFAULT_PROMPT_ENSEMBLE:
            print(f"    prompt-max {attr!r} labels with {len(templates)} templates")
        table[attr] = [
            # store the RAW label (the runtime/search use it); only the emb is templated
            {"label": lbl, "emb": [round(float(x), 6) for x in embs[i]]}
            for i, lbl in enumerate(labels)
        ]
    path = os.path.join(out_dir, f"attribute_embeddings_{SUFFIX}.json")
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

    print(f"[1/4] loading {DISPLAY_NAME} via open_clip …")
    enc = load_mobileclip2_s2(args.hf_model)

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
    print(f"  _inputSize  = {enc.input_size}")
    print(f"  _mean = {list(enc.mean)}")
    print(f"  _std  = {list(enc.std)}")
    print(f"  _embedDim = {enc.embed_dim}")
    print(f"  text encoder: token_ids[1,{enc.context_length}] int32 → text_embeds[1,{enc.embed_dim}]")
    print(f"  (model: {enc.name})")


if __name__ == "__main__":
    main()
