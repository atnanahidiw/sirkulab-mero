# 01 · Implementation — vision export (Talk2DINO → ONNX)

**Status:** ✅ done · **Owns:** `scripts/export_vision_model.py`, `validate_vision_model.py`, `lib/services/vision_runtime.dart`
**Produces:** `assets/models/image_encoder_talk2dino.onnx` (+ `attribute_embeddings_talk2dino.json`)

Turn the [plan](00_plan.md)'s "DINO zero-shot attribute scorer" into a real,
bundled ONNX asset. This stage is where most planning assumptions met reality.

## What ships
| Artifact | Size | Notes |
| --- | --- | --- |
| `image_encoder_talk2dino.onnx` | ~92 MB (dynamic int8) | DINOv2 **ViT-B/14-reg**, pooling baked into the graph |
| `attribute_embeddings_talk2dino.json` | ~2.5 MB | 7 attributes × controlled-vocab labels, each with its text embedding |

Binaries are **git-ignored**; regenerate with
`uv venv .venv-export && uv pip install -r scripts/requirements-export.txt && .venv-export/bin/python scripts/export_vision_model.py`.
Size revision vs plan: §6 budgeted a ViT-**S** (~22 MB), but the text-aligned
weights only exist for ViT-**B**.

---

## Challenge 1 — Talk2DINO is a *segmentation* model, not a whole-image classifier
The plan assumed a CLIP-style "embed image → cosine vs label text" encoder. Reality:
- **Projection direction is reversed** — Talk2DINO aligns **CLIP text → DINO space** (`project_clip_txt`); the image features stay native. So only the *labels* are projected. The exporter loads the HF `AutoModel` and uses its real `encode_text`.
- **`encode_image` returns patch tokens `(N, L, D)` at 518 px**, not one vector — it's built for dense open-vocabulary *segmentation*.
- **Whole-image representation uses multi-head "disentangled self-attention" pooling** (forward hooks + `is_training` branch + max-over-heads), which neither ONNX-exports cleanly nor matches a single-vector cosine runtime.

**Solution — single-vector approximation.** Pool the DINO patch tokens to one
768-d vector inside the ONNX graph, L2-normalise, cosine-match vs projected label
embeddings. Keeps `vision_runtime.dart` a simple embed-once-then-argmax engine.

## Challenge 2 — naïve mean-pooling matched the *background*
First export mean-pooled all 1369 patches → a **panda** scored **plant** traits
("various shades of green"), a **tiger**'s colour came back "grayish-brown". Flat
mean lets grass/foliage dominate, and Talk2DINO's text was aligned to its
*attention-weighted* pooling, not a plain mean.

**Approaches compared** (`scripts/compare_pooling.py`):
| Attribute | mean | CLS token | **CLS-saliency (shipped)** |
| --- | --- | --- | --- |
| Tiger colour | "grayish-brown" ✗ | green/foliage ✗ | **"yellow and black stripes…"** ✓ |
| Panda colour | "various shades of green" ✗ | green ✗ | **"white, dark brown, black"** ✓ |
| Both texture | "leafy/rough" ✗ | leafy ✗ | **"furry"** ✓ |

**Solution — CLS-saliency-weighted pooling.** Weight each patch by the softmax of
its cosine similarity to the CLS token (a cheap, ONNX-exportable saliency proxy
that foregrounds the subject and stays in the text-aligned space), then sum. Plain
CLS alone scored ~0.05 (outside the patch-aligned text space).

## Challenge 3 — `distinctive_marks` contract mismatch
The first exporter omitted `distinctive_marks` ("free-form"), but the
`search_similar_features` schema lists it **required** and the prompt forbids
inventing traits — the LLM would be forced to fabricate or stall.

**Solution.** It has **63 distinct DB values** (on par with `pattern` 54). Added it
to `ATTRIBUTE_COLUMNS`; the tool now emits all **7** attributes. Rule of thumb:
keep `ATTRIBUTE_COLUMNS` and the tool's `required` list in sync — `extract` can
only emit what's scored.

## Toolchain pitfalls (for re-runs)
- **`transformers` 5.x breaks Talk2DINO's remote code** (`all_tied_weights_keys`). Pin `transformers<5`.
- **torch ≥ 2.9 defaults `onnx.export` to the dynamo path** (needs `onnxscript`). Pass `dynamo=False`.
- DINOv2 loads via `torch.hub` on first run (needs network); xFormers warnings are harmless on CPU.

## Honest limitations
The single-vector approximation is **strong on coarse traits** (colour, texture,
distinctive_marks) but **noisier on fine ones** — the panda's `visual_group` came
back "Primate", `size_class` "small rodent". Expected cost of dropping the
attention-weighted multi-head pooling. The agentic retry loop (re-observe with
`focus`, then verify) is meant to recover from it; the durable accuracy fix is
tracked in [05_implementation-accuracy-tuning.md](05_implementation-accuracy-tuning.md).
Upgrade path if needed: reproduce Talk2DINO's `avg_self_attn` pooling exportably,
or move to its full disentangled matching.

## Validation
`scripts/validate_vision_model.py` checks every asset the way the app uses it
(tokenizer exactness, int8↔fp32 top-1 label agreement, text-encoder parity, claim
scoring) and exits non-zero on any hard failure. Quantization specifics →
[03_implementation-quantization.md](03_implementation-quantization.md).
