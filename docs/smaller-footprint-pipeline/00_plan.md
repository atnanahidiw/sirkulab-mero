# Plan — DINO Vision Pipeline (Qwen3-0.6B reasoning core + Talk2DINO vision tool)

**Status:** Design doc (stable). Build progress lives in the `0n_implementation-*` files.
**Goal:** Cut the on-device model download from **2.58 GB → ~0.7 GB** while *keeping* a generative reasoning model as the core, staying open-set (no retraining to add species), and preserving the conversational UX — without falling into the data-dependency and scalability traps the project writeup rejects.
**Scope:** A *beyond-hackathon* product direction. It treats the reasoning core as "any capable small model," not specifically Gemma.

> Working-name note: the planning text uses **"DINOclip"** for the text-aligned
> DINO vision tool. The implementation settled on **Talk2DINO**
> (`lorebianchi98/Talk2DINO-ViTB`). Read "DINOclip" as "Talk2DINO".

---

## 1. Background — what we have today

Mero currently runs **one** model, **Gemma 4 E2B (INT4, 2.58 GB)**, on-device via Google's **LiteRT-LM** runtime through the **`flutter_gemma`** plugin. That single model does three jobs:

1. **Visual reasoning** — looks at the photo and emits structured visual traits (colour, body shape, distinctive marks, texture, size class, pattern, visual group) via function calling.
2. **Agentic retrieval** — calls `search_similar_features`, which runs an FTS5 full-text search over a bundled SQLite DB (narrowed by *visual group*), reranked by a weighted Sørensen–Dice score, then **evaluates candidates against the image** and **revises its hypothesis over up to 4 passes**.
3. **Explanation / Q&A** — grounded, child-friendly answers, ground truth from the curated SQLite DB (not the model).

The agentic loop is in [`lib/models/chat_prompts.dart`](../../lib/models/chat_prompts.dart) — `identifySystemInstruction` (STEP 1–6) and `identifySynthesisPrompt` (CASE 1–3). Its engine is the model **re-examining the image on passes 2/3/4**.

**Why change?** Size. Gemma 4's smallest member is E2B (2.58 GB) — there is **no** small text-only Gemma 4. So "smaller, still multimodal Gemma" is impossible.

---

## 2. Constraints we must respect (from the writeup)

Any overhaul must satisfy all three:

1. **No data dependency.** Trained classifiers need large, balanced datasets per species/region/age/lighting; in biodiversity this overfits common species and fails on rare/endemic ones. The system must be **knowledge-guided** (pretrained features + curated metadata), not data-driven.
2. **Scalability without retraining.** Adding a species must require only new JSON/SQLite rows — no images, no retraining, no redeploy.
3. **Model is the reasoning core.** A generative model must interpret, reason across candidates, explain, and answer open-ended questions — not be reduced to a classifier sub-component.

> **Key insight:** these objections are arguments against *trained classifiers*, **not** against being *small* and **not** against splitting "seeing" from "reasoning." A self-supervised **embedding/retrieval** front-end (DINO) is knowledge-guided and open-set, and a **small generative LLM** stays the reasoning core. The combination satisfies all three.

---

## 3. Proposed architecture

Invert the design: make a **small text LLM the agentic reasoning core**, and demote vision to a **tool** the LLM calls — mirroring how the SQLite search is already a tool.

```
[photo]
   ├──► Tool 1: extract_visual_features(image)   ← DINO zero-shot attribute scoring
   │       image ↔ controlled trait vocabularies → structured trait TEXT
   │       {color, body_shape, distinctive_marks, texture, size_class, pattern, visual_group}
   ├──► Tool 2: search_similar_features(traits)   ← EXISTING FTS5 + Sørensen–Dice (UNCHANGED)
   │       matches trait text ↔ each species' stored visualFeatures text → ranked species
   └──► Tool 3: check_visual_evidence(image, claims[])  ← DINO text↔image similarity
                 per-claim scores (re-classify/verify traits on retry)
        ▼
  Qwen3-0.6B  (reasoning core, flutter_gemma / LiteRT-LM)
        · orchestrates tools via function calling · refines traits, pivots over ≤4 passes
        · produces the grounded JSON identification + conversational Q&A
  Curated SQLite DB  →  ground truth (per-species visualFeatures text, taxonomy, facts) — UNCHANGED
```

> **Retrieval mechanism (important).** The search is **text-trait → text-trait**: the model emits visual-feature *text*, and `searchSimilarByFeatures` matches it against each species' stored `visualFeatures` text via FTS5 (filtered by `visual_group`) + per-field token **Dice** overlap + taxonomy boosts. There are **no reference images or image embeddings** in the DB. DINO's job is **only** to replace the model's *"look at the image and describe the traits"* step — producing the trait text that feeds the **unchanged** search. This avoids any reference-image dataset (which would reintroduce the data-dependency the writeup rejects).

### 3.1 Reasoning core — Qwen3-0.6B
- **Size:** `qwen3_0_6b_mixed_int4.litertlm` ≈ **474 MB** ([litert-community/Qwen3-0.6B](https://huggingface.co/litert-community/Qwen3-0.6B)).
- **Why over Gemma 3 1B:** smaller (474 vs 554 MB), **stronger tool calling** (Gemma 3's tool calling is a documented weak spot), and a **reasoning/"thinking" mode**.
- **Runtime:** `flutter_gemma` already supports Qwen3-0.6B (`.litertlm`) with **function calling** — so we keep the proven runtime (LiteRT GPU delegate works, unlike the llamadart/Vulkan path that crashed). Swapping the model is a config change.
- **Reliability lever:** GBNF/structured-output constraints + (now) thinking mode for multi-step planning — see [04_implementation-tool-calling.md](04_implementation-tool-calling.md).

Step-up if reasoning is too light: Qwen2.5-1.5B (1.46 GB) or Qwen3-1.7B — still under 2.58 GB.

### 3.2 Vision — DINO (Talk2DINO) as a zero-shot visual-feature extractor
DINO replaces **only** the "look at the image and describe traits" step: for each attribute, score the image against that attribute's controlled text vocabulary (image↔text similarity) and pick the best label(s). Output = the same structured trait text Gemma produces, feeding the **unchanged** `search_similar_features`.

- **Fits the data model:** attributes are mostly **closed vocabularies** (`visual_group` is a fixed enum; `color`/`pattern`/`texture`/`size_class` are small sets). Image-vs-N-labels argmax is what CLIP-style models do.
- **DINOv2** is the recommended backbone for fine-grained, visually-similar classes (*"ideal for biological imaging… superior ability to distinguish visually similar classes"*). Best-in-class on **iNaturalist** embeddings (V-measure 0.908 vs CLIP 0.719).
- **Plain DINOv2 has no text encoder** → can't do image↔text scoring. The text-aligned variant is required: **dino.txt** (CVPR 2025, SOTA on iNaturalist zero-shot) or **Talk2DINO** (ICCV 2025). We use Talk2DINO.
- **Why not a trained classifier:** frozen/self-supervised → no per-species data (obj. 1 ✅); adding a species needs only DB text (obj. 2 ✅); LLM stays the reasoning core (obj. 3 ✅). Its text↔image alignment also powers the retry loop (§4).
- **Runtime — ONNX via [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime)** (CoreML on iOS, NNAPI on Android), a *separate* engine from `flutter_gemma`, bridged by the tool loop.
- **Export reality:** no turnkey small mobile build exists; we export it ourselves — see [01_implementation-vision-export.md](01_implementation-vision-export.md). Attribute-label text embeddings are **precomputed offline**, so the text encoder isn't needed at runtime for `extract_visual_features` (only for arbitrary-claim `check_visual_evidence` — see [02_implementation-verify-tool.md](02_implementation-verify-tool.md)).

### 3.3 Why DINO fits this use case
DINOv2 ([Oquab et al., 2023](https://arxiv.org/abs/2304.07193)) is a self-supervised backbone producing *"all-purpose visual features… without finetuning."* Five properties map onto Mero:
1. **Self-supervised, used frozen → no data dependency** (obj. 1 & 2).
2. **Best-in-class fine-grained, look-alike discrimination** (birds/cars/aircraft; biological imaging). Species ID *is* this.
3. **Top biodiversity embeddings** — iNaturalist-2021 V-measure 0.908 vs CLIP 0.719.
4. **Captures structure/texture/spatial detail** (global + patch) — exactly the trait fields.
5. **Robust across image distributions** → field/classroom photos.

The one thing vanilla DINOv2 lacks is **language** — added by the text-alignment heads (dino.txt/Talk2DINO), turning it into a zero-shot attribute scorer (§3.2) and enabling the text-conditioned retry loop (§4), at iNaturalist-SOTA zero-shot quality.

---

## 4. Reproducing the agentic "fix-on-retry" loop

The current loop depends on the model **re-examining the photo and revising its trait text** across passes. A blind text LLM can't look — but DINO's text↔image alignment turns "re-examine and re-describe" into callable, scored tools.

| Current step (`chat_prompts.dart`) | DINO-backed equivalent |
|---|---|
| STEP 1: look at image, extract trait text | `extract_visual_features(image)` → zero-shot attribute scoring → trait text |
| STEP 2: `search_similar_features(traits)` | **unchanged** — feeds FTS5 + Dice as today |
| STEP 4: compare top candidate against image | `check_visual_evidence(image, <candidate traits>)` → scores |
| CASE 2: re-examine, revise traits, search again | low match → re-call `extract_visual_features` focused on ambiguous attributes / `check_visual_evidence` on a corrected hypothesis → revised trait text → re-search |
| CASE 3: 4 passes exhausted → best guess | same cap; output best candidate + evidence scores |

**This is strictly more grounded than today:** every visual claim becomes a *measurable score* instead of an internal "does it match?" judgement — also delivering the writeup's Next Step #3 (expose evidence behind predictions).

---

## 5. Tool schemas (in `chat_prompts.dart`)

`extract_visual_features({focus?})` → `{color, body_shape, distinctive_marks, texture, size_class, pattern, visual_group}` (the SAME fields the search expects). `search_similar_features(...)` is UNCHANGED. `check_visual_evidence({claims[]})` → relative similarity score per claim. The photo bytes are held by the Dart tool handler; the model only supplies query parameters. (Final wired schemas — including the v2 verify tool and the prompt rewrite — are described in stages 02 and 04.)

### 5.1 Prompt rewrite — the model is blind, so it orchestrates tools
Every "look at the image" instruction becomes a tool call, and a hard rule forbids inventing visual evidence the tools didn't return. Workflow: OBSERVE (`extract_visual_features`) → SEARCH (`search_similar_features`) → VERIFY (`check_visual_evidence`) → FIX & PIVOT (re-observe with `focus`) → CONCLUDE (≤4 passes, JSON only). Unchanged: the 4-pass cap, "don't repeat parameters," DB-grounding (`is_endangered` only on a tool match), confidence thresholds, JSON-only output. (See stage 04 for how this prompt evolved against a 0.6B model's real behaviour.)

---

## 6. Sizes, trade-offs, and risks

### Size budget (as built)
| Component | Size |
|---|---|
| Qwen3-0.6B (int4, `.litertlm`) | ~0.47 GB (downloaded once) |
| DINO image encoder (dynamic int8 ONNX) | ~92 MB (bundled) |
| DINO text encoder (fp16 ONNX) | ~129 MB (bundled) |
| CLIP tokenizer + attribute embeddings | ~4 MB (bundled) |
| **Total on-device** | **~0.7 GB** (vs **2.58 GB**) |

### What we gain
- **~3.7× smaller on-device footprint.**
- Better tool-call reliability (text model + thinking mode).
- Lower latency than a 2 GB VLM image prefill; GPU/NPU-friendly DINO pass.
- Stronger grounding/explainability — visual claims become scores.
- Same LLM runtime (`flutter_gemma`) → working Adreno GPU, no native-build rabbit hole.

### Risks (and where they're addressed)
1. **Fixed-vocabulary "eyes."** Open-ended `distinctive_marks`/`body_shape` are hardest — stage 01.
2. **Zero-shot accuracy unproven for this taxa.** A wrong `visual_group` propagates into search — the *live open problem*, stage 05.
3. **We export/quantize the model ourselves.** No off-the-shelf small file — stages 01 & 03.
4. **No reference-image dataset needed** (search is text↔text) → open-set preserved for free.
5. **Two runtimes** (LiteRT-LM + ONNX Runtime) — bridged by the tool loop, both cross-platform.

---

## 7. Decision summary

- **Reasoning core:** Qwen3-0.6B (0.47 GB) on `flutter_gemma` — smaller than Gemma 1B, stronger tool calling, thinking mode, working GPU.
- **Vision:** Talk2DINO (DINOv2 ViT-B/14-reg + CLIP-text alignment), ONNX on `flutter_onnxruntime` (CoreML/NNAPI). Replaces only the "look & describe" step → trait text into the **unchanged** search.
- **Unchanged:** SQLite DB grounding, `search_similar_features` (FTS5 + Dice), 4-pass cap, confidence thresholds, offline-first. No reference-image dataset.
- **Outcome:** ~2.58 GB → ~0.7 GB on-device; satisfies all three writeup objections; improves tool-call reliability, latency, explainability.

---

## 8. Rollout phases (original plan)

1. **Vision spike (offline)** — export the image encoder → int8 ONNX; precompute per-attribute label embeddings; validate zero-shot scoring reproduces the DB's trait text. *(done — stage 01)*
2. **Flutter vision tool** — wire `flutter_onnxruntime`; implement `extract_visual_features` / `check_visual_evidence`. *(done — stages 01/02)*
3. **Swap the LLM** — point `flutter_gemma` at Qwen3-0.6B; confirm function calling. *(done; tool calling debugged in stage 04)*
4. **Rewrite the agentic prompts** — blind, tool-orchestrating. *(done — stage 04)*
5. **Evidence UI** — surface matched traits + scores (writeup Next Step #3). *(not started)*
6. **Benchmark** vs Gemma 4 E2B: accuracy, latency, size, hallucination. *(not started)*

## 9. Component shape (app lifecycle)

| Model | Size | Delivery | Runtime |
|---|---|---|---|
| Vision (DINO int8/fp16 ONNX) | ~225 MB | **bundled in `assets/`** | `flutter_onnxruntime` |
| Qwen3-0.6B | ~474 MB | **downloaded once** | `flutter_gemma` |

- **`lib/services/vision_runtime.dart`** — owns the ONNX vision model + all image↔text scoring; image embedding cached per photo; attribute label embeddings precomputed offline.
- **`model_runtime.dart`** — LLM goes text-only: **no `imageBytes` sent to the model**; the photo goes only to the vision tools.
- **`model_service.dart`** — owns both runtimes, wires the three tools whose `execute` closures capture the photo; `isModelLoaded = vision.isLoaded && llm.isLoaded`.
- **Unchanged:** `species_service.dart` (FTS5 + Dice), `model_download_service.dart`, `analyzing_page.dart`, SQLite DB, boot-state machine, l10n, Q&A flow.

## 10. Coverage beyond the curated DB (answering constraint §2)

The `dino_attribute_embeddings.json` labels are **DB-derived** (distinct trait values), so the closed `extract` path can only emit existing labels — but coverage still extends past the curated set:

- **`extract` is closed-vocab but compositional** — colour/shape/texture/pattern aren't species-specific, so a never-seen subject reuses labels other species contributed. It spans a *trait space*, not a *species list*.
- **`check_visual_evidence` is open-vocabulary** — its runtime text encoder + Dart CLIP tokenizer embed **arbitrary** claims, so the LLM can test hypotheses for species absent from the DB. Bounded by the open-world DINO/CLIP space, not `assets/data`.
- **The model is open-world; only the precomputed `extract` index is DB-bounded** (a caching choice, not a ceiling).
- **The LLM is the reasoning core; the DB is a grounding index.** On no DB match it still reports a best-effort answer (`is_endangered` false unless confirmed).
- **Scales without retraining** — new species = add DB rows + re-run `build_vocabularies` (frozen text encoder); `check` + LLM need no re-export.

So the derived-label caveat constrains only the closed `extract` path; the open `check` path + the LLM cover data beyond the curated set.

---

## References

**Models & runtime**
- Qwen3-0.6B (LiteRT) — https://huggingface.co/litert-community/Qwen3-0.6B
- Gemma 4 family (smallest is E2B 2.58 GB) — https://ai.google.dev/gemma/docs/core/model_card_4
- flutter_gemma (LiteRT-LM, function calling) — https://pub.dev/packages/flutter_gemma
- flutter_onnxruntime (CoreML/NNAPI) — https://pub.dev/packages/flutter_onnxruntime

**Vision (DINO / CLIP)**
- DINOv2 (Oquab et al., 2023) — https://arxiv.org/abs/2304.07193
- DINOv2 vs CLIP on iNaturalist-2021 (V-measure) — https://voxel51.com/blog/finding-the-best-embedding-model-for-image-classification
- dino.txt — "DINOv2 Meets Text" (CVPR 2025, iNaturalist zero-shot SOTA) — https://arxiv.org/html/2412.16334v1
- Talk2DINO (DINOv2 + CLIP-text alignment, ICCV 2025) — https://arxiv.org/html/2411.19331v3 · weights: https://huggingface.co/lorebianchi98/Talk2DINO-ViTB
- MobileCLIP TFLite (S1 ≈ 324 MB …) — https://huggingface.co/anton96vice/mobileclip2_tflite
