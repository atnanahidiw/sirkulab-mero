# Vision model assets ("dino") — produced offline

These are NOT committed binaries. Generate them once with the exporter and they
land here automatically:

```bash
uv venv .venv-export && VIRTUAL_ENV=.venv-export \
  uv pip install -r scripts/requirements-export.txt
.venv-export/bin/python scripts/export_vision_model.py     # create the assets
.venv-export/bin/python scripts/validate_vision_model.py   # validate each asset
```

`validate_vision_model.py` checks every asset the way the app uses it (tokenizer
↔ `clip.tokenize` exact match, int8↔fp32 label agreement, text-encoder parity,
claim scoring) and exits non-zero on any hard failure.

Outputs (consumed by `lib/services/vision_runtime.dart`):

- `dino_image_encoder.onnx` — int8 image encoder. **Talk2DINO** (DINOv2 ViT-B/14
  + text alignment) loaded from HF `lorebianchi98/Talk2DINO-ViTB`. Image side is
  DINOv2 `x_norm_patchtokens` **CLS-saliency-weighted pooled** to one 768-d
  vector (each patch weighted by softmax cosine-sim to the CLS token — a
  tractable single-vector approximation of Talk2DINO's disentangled-attention
  pooling that foregrounds the subject; plain mean lets background dominate and
  is much worse). Exports cleanly and matches the runtime's cosine matching.
  Input 518px, ImageNet mean/std. Plain DINOv2 alone can't be used — no text
  encoder.
- `dino_attribute_embeddings.json` — per-attribute controlled vocabulary with
  each label's text embedding, derived from the species DB columns (color,
  body_shape, distinctive_marks, texture, size_class, pattern, visual_group) and
  encoded with the model's text encoder. Shape:
  `{ "color": [{"label":"...","emb":[..]}, ..], ... }`.
- `dino_text_encoder.onnx` — int8 runtime text encoder (CLIP text →
  Talk2DINO projection → 768-d). Powers `check_visual_evidence`: embeds
  arbitrary claim text on-device. Input `token_ids` int32 `[1,77]`.
- `clip_vocab.json` + `clip_merges.txt` — CLIP BPE vocab/merges so
  `lib/services/clip_tokenizer.dart` reproduces `clip.tokenize` exactly
  (the text encoder needs the same token IDs CLIP was trained on).

After exporting, copy the printed model constants (input/output names, input
size, mean/std) into `lib/services/vision_runtime.dart`.

See `docs/plans/smaller-footprint-architecture.md` (§3.2, §9) for the full design.
