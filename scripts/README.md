# `scripts/` — offline build & validation tools

Python tooling that produces the assets the Flutter app bundles. Nothing here
runs on-device or at app runtime; these are one-shot generators you run on a dev
machine, then commit/ship their outputs.

Two asset pipelines live here:

- **Species database** — `build_species_db.py` → `assets/data/species_data.sqlite`
- **Vision model** (Talk2DINO + tokenizer) — `export_vision_model.py` →
  `assets/models/*`, checked by `validate_vision_model.py`, with
  `compare_pooling.py` as the design diagnostic.

---

## Setup (vision scripts)

The vision scripts need PyTorch + Talk2DINO deps. Use a throwaway `uv` venv:

```bash
uv venv .venv-export
VIRTUAL_ENV=.venv-export uv pip install -r scripts/requirements-export.txt
```

Run them with that interpreter, e.g. `.venv-export/bin/python scripts/<name>.py`.
First run downloads the Talk2DINO / DINOv2 / CLIP weights from Hugging Face
(needs network). `build_species_db.py` has **no** third-party deps (stdlib only).

---

## Scripts

### `build_species_db.py` — create the species DB
Builds the FTS5 SQLite retrieval DB from the per-species JSON files, applying the
same token normalisation the Dart reranker uses at query time (so the index and
runtime queries agree).

```bash
python scripts/build_species_db.py \
  --data-dir assets/data/species_data \
  --output   assets/data/species_data.sqlite
```
Defaults are the paths above, so bare `python scripts/build_species_db.py` works.

### `export_vision_model.py` — create the vision assets
Pulls **Talk2DINO** (`lorebianchi98/Talk2DINO-ViTB`) from HF and writes five
assets to `assets/models/`:

| Asset | What it is |
| --- | --- |
| `dino_image_encoder.onnx` | int8 DINOv2 image encoder, CLS-saliency pooled → 768-d |
| `dino_attribute_embeddings.json` | per-attribute controlled-vocab label embeddings |
| `dino_text_encoder.onnx` | int8 CLIP-text→DINO encoder for `check_visual_evidence` |
| `clip_vocab.json` + `clip_merges.txt` | CLIP BPE tables for the Dart tokenizer |

```bash
.venv-export/bin/python scripts/export_vision_model.py
#   --hf-model lorebianchi98/Talk2DINO-ViTB   --out assets/models
#   --db assets/data/species_data.sqlite      --no-quantize
```
Prints the model constants (`_inputSize`, `_mean`/`_std`, tensor names) to paste
into `lib/services/vision_runtime.dart` if they ever change.

### `validate_vision_model.py` — validate the vision assets
Checks every exported asset the way the app uses it; **exits non-zero on any hard
failure**. Run it after every export.

```bash
.venv-export/bin/python scripts/validate_vision_model.py
#   --images tiger=/path/a.jpg,panda=/path/b.jpg   (skip built-in downloads)
#   --no-download   --models-dir assets/models   --text-parity-min 0.85
```
Hard checks: assets present · CLIP tokenizer ↔ `clip.tokenize` exact (9/9) ·
image embedding dim 768 & finite · **int8 top-1 labels == fp32** · text-encoder
torch↔ONNX parity ≥ threshold · true claims outscore a wrong control claim.

### `compare_pooling.py` — pooling diagnostic (design tool)
Compares DINO single-vector poolings (`mean` / `cls` / `cls_sim_w`) on real
photos — the evidence behind the shipped CLS-saliency choice
(`docs/plans/smaller-footprint-architecture.md` §10.3). Re-run it if you revisit
pooling. Not a pass/fail check; it just prints top labels per attribute.

```bash
.venv-export/bin/python scripts/compare_pooling.py
#   --attrs color,texture,pattern,visual_group,body_shape   --topk 3
#   --images tiger=/path/a.jpg,panda=/path/b.jpg
```

### `requirements-export.txt`
Pinned deps for all three vision scripts (`transformers<5`, OpenAI CLIP, etc.).

---

## Typical flow

```bash
# species DB (stdlib only)
python scripts/build_species_db.py

# vision assets (in the uv venv)
.venv-export/bin/python scripts/export_vision_model.py
.venv-export/bin/python scripts/validate_vision_model.py   # must pass
```

The species DB (`assets/data/species_data.sqlite`) is committed; the vision
assets (`assets/models/`) are git-ignored — regenerate them on demand. See
`assets/models/README.md` and `docs/plans/smaller-footprint-architecture.md`.
