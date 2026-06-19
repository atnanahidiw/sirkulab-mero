# Smaller-Footprint Architecture — Qwen3-0.6B (reasoning core) + DINOclip (vision tool)

**Status:** Proposal / design doc
**Goal:** Cut the on-device model download from **2.58 GB → ~0.55 GB** (~4.7×) while *keeping* a generative reasoning model as the core, staying open-set (no retraining to add species), and preserving the conversational UX — i.e. without falling into the data-dependency and scalability traps the project writeup correctly rejects.
**Scope:** This is a *beyond-hackathon* product direction. It deliberately treats the reasoning core as "any capable small model," not specifically Gemma.

---

## 1. Background — what we have today

Mero currently runs **one** model, **Gemma 4 E2B (INT4, 2.58 GB)**, on-device via Google's **LiteRT-LM** runtime through the **`flutter_gemma`** plugin. That single model does three jobs:

1. **Visual reasoning** — looks at the photo and emits structured visual traits (colour, body shape, distinctive marks, texture, size class, pattern, visual group) via function calling.
2. **Agentic retrieval** — calls `search_similar_features`, which runs an FTS5 full-text search over a bundled SQLite DB (narrowed by *visual group*), reranked by a weighted Sørensen–Dice score, then **evaluates the candidates against the image** and **revises its hypothesis over up to 4 passes**.
3. **Explanation / Q&A** — grounded, child-friendly answers, with ground truth coming from the curated SQLite DB (not the model).

The agentic loop is defined in [`lib/models/chat_prompts.dart`](../../lib/models/chat_prompts.dart) — `identifySystemInstruction` (STEP 1–6) and `identifySynthesisPrompt` (CASE 1–3). Its engine is the model **re-examining the image on passes 2/3/4** ("*Compare the returned species against the image*", "*Re-examine the image… focus on hard structural details… pivot… search again*").

**Why change anything?** Size. Gemma 4's smallest member is E2B (2.58 GB) — there is **no** small text-only Gemma 4 (270M/1B exist only in Gemma 3). See [Gemma 4 family overview](https://artificialanalysis.ai/articles/gemma-4-everything-you-need-to-know) and the [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4). So "smaller, still multimodal Gemma" is impossible.

---

## 2. Constraints we must respect (from the writeup)

The writeup explicitly rejects naïve "small classifier" approaches for three sound reasons. Any overhaul must satisfy all three:

1. **No data dependency.** Trained classifiers need large, balanced datasets per species/region/age/lighting; in biodiversity this overfits common species and fails on rare/endemic ones. The system must be **knowledge-guided** (pretrained features + curated metadata), not data-driven.
2. **Scalability without retraining.** Adding a species must require only new JSON/SQLite rows — no images, no retraining, no redeploy.
3. **Model is the reasoning core.** A generative model must interpret, reason across candidates, explain, and answer open-ended questions — not be reduced to a classifier sub-component.

> **Key insight:** these objections are arguments against *trained classifiers*, **not** against being *small* and **not** against splitting "seeing" from "reasoning." A self-supervised **embedding/retrieval** front-end (DINO) is knowledge-guided and open-set, and a **small generative LLM** can remain the reasoning core. The combination satisfies all three.

---

## 3. Proposed architecture

Invert the design: make a **small text LLM the agentic reasoning core**, and demote vision to a **tool** the LLM calls — exactly mirroring how the SQLite search is already a tool.

```
[photo]
   │
   ├──► Tool 1: extract_visual_features(image)      ← DINOclip zero-shot attribute scoring
   │         image ↔ controlled trait vocabularies → returns structured trait TEXT
   │         {color, body_shape, distinctive_marks, texture, size_class, pattern, visual_group}
   │
   ├──► Tool 2: search_similar_features(traits)      ← EXISTING FTS5 + Sørensen–Dice (UNCHANGED)
   │         matches trait text ↔ each species' stored visualFeatures text → ranked species
   │
   └──► Tool 3: check_visual_evidence(image, claims[])  ← DINOclip text↔image similarity
                 returns per-claim 0–1 scores (used to re-classify/verify traits on retry)

        ▼
  Qwen3-0.6B  (reasoning core, runs on flutter_gemma / LiteRT-LM)
        · orchestrates the tools via function calling
        · reasons across candidates, refines traits, pivots over ≤4 passes
        · produces the grounded JSON identification + conversational Q&A

  Curated SQLite DB  →  ground truth (per-species visualFeatures text, taxonomy, facts) — UNCHANGED
```

> **Note on the retrieval mechanism (corrected).** The search is **text-trait → text-trait**: the model emits visual-feature *text*, and `searchSimilarByFeatures` matches it against each species' stored `visualFeatures` text via FTS5 (filtered by `visual_group`) + per-field token **Dice** overlap + taxonomy boosts. There are **no reference images or image embeddings** in the DB. So DINOclip's job is **only** to replace the model's *"look at the image and describe the traits"* step — producing the trait text that feeds the **unchanged** search. This keeps the DB, FTS5, and Dice reranker exactly as they are, and avoids any reference-image dataset (which would reintroduce the data-dependency the writeup rejects).

### 3.1 Reasoning core — **Qwen3-0.6B**

- **Size:** `qwen3_0_6b_mixed_int4.litertlm` ≈ **474 MB** ([litert-community/Qwen3-0.6B](https://huggingface.co/litert-community/Qwen3-0.6B)).
- **Why Qwen3-0.6B over Gemma 3 1B:** it is *smaller* (474 MB vs 554 MB), has **stronger tool calling** (Gemma 3's tool calling is the documented weak spot — *"if your workload routes to tools or builds agents, look elsewhere"*, [Ollama models cheat sheet 2026](https://computingforgeeks.com/ollama-models-cheat-sheet/)), and has a **reasoning/"thinking" mode**.
- **Runtime:** **`flutter_gemma`** already supports Qwen3-0.6B (`.litertlm`) with **function calling** ([flutter_gemma pub](https://pub.dev/packages/flutter_gemma), [repo](https://github.com/DenisovAV/flutter_gemma)). So we **keep the proven runtime** — including its LiteRT GPU delegate (OpenCL on Adreno), which *works*, unlike the llamadart/Vulkan path that crashed on-device. Swapping the model is a config change, not a runtime migration.
- **Reliability lever:** GBNF/structured-output constraints keep the tool-call JSON valid even at 0.6B — directly addressing the writeup's "malformed JSON / unstable tool calls" challenge.

If real-world reasoning proves too light, the same runtime can step up to **Qwen2.5-1.5B (q8, 1.46 GB)** or **Qwen3-1.7B** — still well under 2.58 GB.

### 3.2 Vision — **DINOclip** as a zero-shot *visual-feature extractor*

DINOclip replaces **only** the model's "look at the image and describe the traits" step. It does **zero-shot attribute classification**: for each attribute, score the image against that attribute's controlled text vocabulary (image↔text similarity) and pick the best-matching label(s). The output is the same structured trait text Gemma produces today, which feeds the **unchanged** `search_similar_features`.

- **Why this fits the data model:** your attributes are mostly **closed vocabularies** — `visual_group` is a fixed 31-label enum in the tool def; `color`, `pattern`, `texture`, `size_class` are small label sets. Image-vs-N-text-labels → argmax is exactly what CLIP-style models do. Open-ended fields (`distinctive_marks`, `body_shape`) use a curated candidate set or top-N matches.
- **DINOv2** is the recommended backbone for fine-grained, visually-similar classes — *"superior ability to distinguish visually similar classes… ideal for biological imaging"* ([Towards AI: DINOv2 embeddings](https://towardsai.net/p/computer-vision/harness-dinov2-embeddings-for-accurate-image-classification)). DINOv2-small (ViT-S/14) ≈ 21 M params → ~**20–90 MB** quantized.
- **Plain DINOv2 alone is not enough — it has no text encoder** (image embeddings only), so it cannot do the image↔text attribute scoring this design needs. The text-aligned variant is required: **dino.txt / "DINOv2 Meets Text"** ([CVPR 2025](https://arxiv.org/html/2412.16334v1)) or **Talk2DINO** ([ICCV 2025](https://arxiv.org/html/2411.19331v3)). They add a CLIP-style text alignment on top of the frozen DINOv2 backbone → DINOv2-quality visual discrimination **plus** the text matching needed for zero-shot attribute scoring.
- **dino.txt is the *preferred* vision model for this app** because it is **state-of-the-art on the iNaturalist zero-shot classification benchmark** — our exact domain — and *"on par or better than CLIP-like models on classification"* generally, at a fraction of CLIP's training cost ([DINOv2 Meets Text](https://arxiv.org/html/2412.16334v1)). Combined with DINOv2's fine-grained edge (Food-101 93% vs CLIP 88%), it should beat MobileCLIP at telling look-alike species apart.
- **Why this, not a trained classifier:** it is frozen/self-supervised — no per-species training data (objection 1 ✅); adding a species needs only new DB text, no new images or retraining (objection 2 ✅); and the LLM stays the reasoning core (objection 3 ✅). Its **text↔image alignment is also what powers the retry loop** (see §4).
- **Runtime — ONNX (cross-platform Android + iOS):** the vision model does **not** run through `flutter_gemma` (that only runs LiteRT-LM language models). It runs as a **separate** inference engine, invoked from the Dart tool handler; the two runtimes coexist and the function-call loop bridges them. **Use ONNX via [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime)** rather than TFLite: DINOv2 and MobileCLIP are PyTorch models (so `torch.onnx.export` is the natural path, vs fiddly TF→TFLite conversion), and ONNX Runtime accelerates on **both** platforms — **CoreML on iOS**, NNAPI/QNN on Android — from a single `.onnx`. (flutter_gemma already covers iOS for the LLM via LiteRT-LM/Metal, so the whole stack is iOS-capable.) `tflite_flutter` is a viable fallback but offers no portability advantage here.
- **Export reality (important).** Neither option ships as a ready *small* mobile file, so we produce the ONNX export ourselves:
  - **dino.txt / Talk2DINO (preferred):** 2025 research releases, **no turnkey ONNX/mobile build**. You export the frozen DINOv2 backbone (DINOv2→ONNX is well-trodden) + the small text-alignment head + text encoder → ONNX → int8. More work, but iNaturalist-SOTA quality. DINOv2-small image side ≈ **~22 MB** int8.
  - **MobileCLIP (turnkey prototype / fallback):** the published TFLite files are *full-precision combined* and **large** — S1 ≈ 324 MB, S2 ≈ 379 MB, B ≈ 572 MB ([anton96vice/mobileclip2_tflite](https://huggingface.co/anton96vice/mobileclip2_tflite)) — but MobileCLIP exports to ONNX cleanly (Apple model) and int8 image-encoder-only is ≈ **12–21 MB** (S0/S1).
  - Either way, attribute-label text embeddings are **precomputed offline**, so the text encoder isn't needed at runtime for `extract_visual_features` (only for arbitrary-claim `check_visual_evidence` — see §8.3.8). "Tiny, bundled vision model" is achievable, but it's a **one-time quantization/export step**, not an off-the-shelf file.

### 3.3 Why DINO's capabilities fit *this* use case

DINOv2 ([Oquab et al., 2023, arXiv:2304.07193](https://arxiv.org/abs/2304.07193)) is a self-supervised vision backbone that produces *"all-purpose visual features that work across image distributions and tasks without finetuning."* Five of its documented properties map directly onto Mero's requirements:

1. **Self-supervised, transfers without fine-tuning → no data dependency.** DINOv2 is trained on unlabeled images and used *frozen*; it was never trained on your species and needs no per-species labels. This is exactly the "knowledge-guided, not data-driven" property the writeup demands (objections 1 & 2). ([DINOv2 paper](https://arxiv.org/abs/2304.07193))
2. **Best-in-class fine-grained, look-alike discrimination.** DINOv2 *"sets new records for self-supervised methods"* on fine-grained benchmarks — explicitly **birds, cars, aircraft** — and is *"ideal for fine-grained image classification… in biological imaging"* with *"superior ability to distinguish visually similar classes."* Species ID *is* fine-grained look-alike discrimination. ([DINOv2 paper](https://arxiv.org/abs/2304.07193) · [Towards AI](https://towardsai.net/p/computer-vision/harness-dinov2-embeddings-for-accurate-image-classification))
3. **Top embeddings for biodiversity specifically.** On **iNaturalist-2021** (3.8 M images, 10 k species), DINOv2 reaches a clustering V-measure of **0.908 vs 0.719 for CLIP and 0.708 for ResNet-18** — i.e. its embeddings separate species far better than CLIP's. ([Voxel51: best embedding model](https://voxel51.com/blog/finding-the-best-embedding-model-for-image-classification))
4. **Captures structure, texture, and spatial detail (global *and* patch features).** DINOv2 evaluates *"both global and local image representations"* and excels at structure/texture — precisely Mero's trait fields (`body_shape`, `distinctive_marks`, `texture`, `pattern`) and the prompt's instruction to *"focus on hard structural details."* ([DINOv2 paper](https://arxiv.org/abs/2304.07193))
5. **Robust across image distributions → field photos.** Features hold up under the lighting, pose, and occlusion variation of real field/classroom photos — the writeup's "low-light visual reliability" challenge — without per-condition training data. ([DINOv2 paper](https://arxiv.org/abs/2304.07193))

The one thing vanilla DINOv2 lacks for us is **language**: it produces vectors, not the trait *text* the search needs, and can't be queried in words. That is exactly what the text-alignment heads (**dino.txt**, **Talk2DINO**) add — CLIP-style text matching on top of DINOv2's fine-grained features — turning it into a zero-shot **attribute scorer** (§3.2) and enabling the text-conditioned retry loop (§4). Crucially, this isn't a quality compromise: **dino.txt sets SOTA on iNaturalist zero-shot classification and matches/beats CLIP on classification benchmarks** ([DINOv2 Meets Text](https://arxiv.org/html/2412.16334v1)) — so adding language keeps DINOv2's fine-grained edge *and* gives best-in-class zero-shot text matching for species.

---

## 4. Reproducing the agentic "fix-on-retry" loop with DINOclip

The current loop depends on the model **re-examining the photo and revising its trait text** across passes. A blind text LLM cannot look — but **DINOclip's text↔image alignment turns "re-examine and re-describe" into callable, scored tools.** Plain DINOv2 (embedding only, no text) cannot; this is the specific reason DINOclip (or CLIP-style text alignment) is required.

| Current step (`chat_prompts.dart`) | DINOclip-backed equivalent |
|---|---|
| STEP 1: look at image, **extract visual-feature text** | `extract_visual_features(image)` → DINOclip zero-shot attribute scoring → structured trait text |
| STEP 2: call `search_similar_features(traits)` | **unchanged** — the trait text feeds FTS5 + Dice exactly as today |
| STEP 4: compare top candidate **against the image** | `check_visual_evidence(image, <candidate's distinctive traits>)` → 0–1 scores |
| CASE 1: confident + visual match → conclude | tool confidence high **and** evidence scores high → emit final JSON |
| **CASE 2: re-examine, revise traits, search again (pass 2,3,4)** | low match → LLM re-calls `extract_visual_features` focused on the ambiguous attributes (alternative `pattern`/`texture` labels, a different `visual_group` hypothesis) and/or `check_visual_evidence` on a corrected hypothesis → **revised trait text** → re-run `search_similar_features` |
| "focus on hard structural details, ignore glare" | the LLM re-scores **structural** attributes (shape/silhouette/markings) — DINOv2's strength — rather than colour |
| CASE 3: 4 passes exhausted → best guess | same cap; output best candidate + evidence scores in `identification_notes` |

**Net effect:** the "fix on the 2nd/3rd attempt" becomes *"pass N matches poorly → re-classify the ambiguous attributes against the image via DINOclip → revised trait text → re-search → converge."* Same iterative trait-correction Gemma does today, with the eyes as a tool and the search unchanged.

**This is strictly more grounded than today.** The current `identifySynthesisPrompt` asks the model to judge *"does it visually match?"* internally — unverifiable and a hallucination source. DINOclip makes every visual claim a **measurable score**, which also delivers the writeup's own *Next Step #3*: "expose the evidence behind each prediction — matched traits, supporting observations, and confidence scores."

---

## 5. Tool schemas (to add to `chat_prompts.dart`)

```jsonc
// Tool 1 — DINOclip visual-feature extractor (replaces the model's "look & describe")
{
  "name": "extract_visual_features",
  "description": "Look at the photo and return observed visual traits as text, by scoring the image against controlled attribute vocabularies. Optionally focus on specific attributes to re-examine on a retry.",
  "parameters": {
    "type": "object",
    "properties": {
      "focus": {
        "type": "array", "items": { "type": "string" },
        "description": "Optional: which attributes to (re)examine, e.g. ['pattern','visual_group']. Empty = all."
      }
    }
  }
  // returns: { color, body_shape, distinctive_marks, texture, size_class, pattern, visual_group }
  // — the SAME structured fields the existing search expects.
}

// Tool 2 — EXISTING FTS5 + Dice trait search (UNCHANGED)
// search_similar_features(color, body_shape, distinctive_marks, texture,
//                         size_class, pattern, visualGroup, taxClass, taxGenus, ...)
//   → matches the trait text against each species' stored visualFeatures text.

// Tool 3 — DINOclip trait verification (per-pass "re-look", drives the retry fix)
{
  "name": "check_visual_evidence",
  "description": "Score 0–1 how well each text claim matches the photo. Use it to verify a candidate's distinctive traits, or to decide between competing trait hypotheses on a retry.",
  "parameters": {
    "type": "object",
    "properties": {
      "claims": {
        "type": "array", "items": { "type": "string" },
        "description": "Visual claims to test, e.g. ['long curved casque on bill','rows of pale spots']"
      }
    },
    "required": ["claims"]
  }
}
```

The photo bytes are held by the Dart tool handler and passed to DINOclip for Tools 1 & 3; the model only supplies the query parameters. `extract_visual_features` and `check_visual_evidence` share the same DINOclip inference under the hood (image↔text scoring) — the difference is Tool 1 scores against *attribute vocabularies* and returns the best labels, while Tool 3 scores arbitrary *claims* and returns raw scores.

### 5.1 Prompt rewrite — the model is now blind, so it *orchestrates tools* instead of *looking*

The current `identifySystemInstruction` opens with *"STEP 1: Look at the image. Extract visual traits…"* — Qwen3 has no eyes, so this must change. The core edit: **every "look at the image" instruction becomes a tool call**, and a hard rule forbids the model from inventing visual evidence the tools didn't return.

**`identifyInputPrompt` (before → after):**
- *Before:* "…Start by extracting visual traits from the image and calling `search_similar_features`…"
- *After:* "…You cannot see the photo directly. Start by calling **`extract_visual_features`** to observe it, then call `search_similar_features` with what it reports."

**`identifySystemInstruction` workflow (rewritten):**
```
STEP 1 — OBSERVE: Call `extract_visual_features`. It returns colour, body shape,
  distinctive marks, texture, size class, pattern, and visual group as seen in the
  photo. You have NO other access to the image — never invent a trait it did not report.
STEP 2 — SEARCH: Call `search_similar_features` with those traits (use the returned
  `visual_group` verbatim).
STEP 3 — WAIT: Receive ranked species with similarity/confidence.
STEP 4 — VERIFY: For the top candidate, call `check_visual_evidence` with that species'
  distinctive traits and read the 0–1 scores against the photo.
STEP 5 — FIX & PIVOT (passes 2–4): If there is no match, low confidence, OR low evidence
  scores, you are FORBIDDEN from repeating the same traits. Re-observe with
  `extract_visual_features({focus:[...ambiguous attributes...]})` (e.g. pattern, visual_group),
  or test a competing hypothesis with `check_visual_evidence`, then SEARCH again with the
  revised traits. Pivot the biological hypothesis (genus/family).
STEP 6 — CONCLUDE: After at most 4 attempts, output best-guess JSON.
```

**`identifySynthesisPrompt` (CASE 2) — the retry "fix":** today it says *"Re-examine the image… focus on hard structural details."* Rewritten: *"You cannot re-open the image; instead re-observe via `extract_visual_features` focused on the structural attributes (shape, silhouette, markings), or score a corrected hypothesis with `check_visual_evidence`, then re-search."*

**Unchanged in the prompt:** the ≤4-pass cap, "don't repeat the same parameters," DB-grounding rules (`is_endangered` only on a tool match), confidence thresholds, and **JSON-only final output**. The `<language>` block and final JSON schema are untouched.

**Net:** the prompt shifts from *"perceive then act"* to *"act through tools, never perceive directly,"* and the anti-hallucination rule strengthens from "don't make things up" to "you have no eyes — only tool outputs are real."

---

## 6. Sizes, trade-offs, and risks

### Size budget
| Component | Size |
|---|---|
| Qwen3-0.6B (int4, `.litertlm`) | ~0.47 GB |
| DINOv2-small / DINOclip head (TFLite/ONNX, quantized) | ~0.02–0.09 GB |
| **Total on-device model footprint** | **~0.5–0.6 GB** (vs **2.58 GB**) |
| SQLite species DB | unchanged (bundled asset) |

Step-up option if reasoning is insufficient: Qwen2.5-1.5B (1.46 GB) + DINO ≈ 1.55 GB — still ~1.7× smaller.

### What we gain
- **~4.7× smaller download.**
- **Better tool-call reliability** (text model + GBNF) — fixes a named challenge.
- **Lower latency** — DINO is one fast forward pass vs a 2 GB VLM image prefill (helps the "multi-step latency" challenge), and is GPU/NPU-friendly.
- **Stronger grounding / explainability** — visual claims become scores → enables the evidence-display next step.
- **Same runtime** (`flutter_gemma` / LiteRT) → working Adreno GPU, no native-build rabbit hole.

### What we trade away / risks
1. **The "eyes" only describe via a fixed vocabulary.** DINOclip extracts traits by scoring the image against attribute label sets; it can't surface a trait that isn't in the vocabulary, and `distinctive_marks`/`body_shape` are open-ended (hardest to enumerate). Mitigation: curate a reasonable candidate-label set per attribute, use top-N matches, and lean on structural attributes (DINOv2's strength) — which the prompt already prioritizes.
2. **Zero-shot attribute accuracy is unproven for *this* taxa.** CLIP/DINOclip attribute scoring for fine-grained, regional/endemic species needs validation — a wrong `visual_group` or `pattern` propagates into the search. Mitigation: validate against the curated DB's own `visualFeatures` text; keep the LLM's 4-pass re-classification + confidence thresholds as the safety net.
3. **The vision model must be exported/quantized ourselves.** No off-the-shelf *small* mobile file exists for either option. **dino.txt / Talk2DINO** (preferred, iNaturalist-SOTA) are 2025 research releases with no ready ONNX/mobile build → self-export (DINOv2 backbone + text head → ONNX → int8); the research-code maturity is the main risk. **MobileCLIP** is the lower-risk prototype/fallback (Apple, exports to ONNX cleanly). Mitigation: keep `VisionRuntime` model-agnostic (just an ONNX image+text scorer) → validate the pipeline with MobileCLIP-ONNX, then swap in dino.txt-ONNX for production quality. A zero-shot DINO captioner ([One Patch to Caption Them All](https://arxiv.org/pdf/2510.02898)) is a richer-but-riskier alternative for the `distinctive_marks` free-text.
4. **No reference-image dataset is needed** (the search is text↔text), so the open-set property is preserved *for free*: adding a species is still just a JSON/SQLite row. The only new authored asset is the per-attribute **label vocabulary** (small, curated text).
5. **Two runtimes to manage** (LiteRT-LM for the LLM + ONNX Runtime for vision). Acceptable; bridged by the tool loop. Both run cross-platform (Android + iOS).

---

## 7. Decision summary

- **Reasoning core:** **Qwen3-0.6B** (0.47 GB) on `flutter_gemma` — smaller than Gemma 1B, stronger tool calling, reasoning mode, working GPU. *(There is no small Gemma 4 to use here; the smallest Gemma 4 is E2B at 2.58 GB.)*
- **Vision:** **a zero-shot visual-feature extractor — dino.txt preferred (iNaturalist-SOTA), MobileCLIP as the turnkey prototype/fallback** — int8 ONNX (~12–22 MB, bundled in assets), running on **`flutter_onnxruntime`** (CoreML on iOS, NNAPI on Android). *(Plain DINOv2 can't be used — it has no text encoder; the text-aligned dino.txt/Talk2DINO is required.)* It replaces only the model's "look & describe" step, producing the trait *text* that feeds the **unchanged** text-based search. Knowledge-guided, open-set, and its text↔image scoring is what reproduces the iterative "fix-on-retry."
- **Unchanged:** SQLite DB grounding, **`search_similar_features` (FTS5 + Sørensen–Dice text matching)**, 4-pass cap, confidence thresholds, offline-first. No reference-image dataset.
- **Outcome:** ~2.58 GB → ~0.7 GB on-device (~0.47 GB LLM download + ~225 MB bundled vision assets; see §8.3.1/§8.3.10), satisfies all three writeup objections, and improves tool-call reliability, latency, and explainability.

---

## 8. Implementation

One narrative in three parts: the **rollout plan** (§8.1), the **component design**
(§8.2), and **what actually got built** with its challenges (§8.3).

### 8.1 Rollout phases

1. **Vision spike (offline).** Export the image encoder → **int8 ONNX** (~12–22 MB) — **MobileCLIP first** to validate the pipeline quickly, **dino.txt** as the production target (iNaturalist-SOTA). Precompute the per-attribute **label-text embeddings** (start from the `visual_group` enum + values already in the DB's `visualFeatures`) and ship them as an asset table. Validate that zero-shot attribute scoring reproduces the DB's curated trait text on a held-out set; measure how often the extracted traits retrieve the correct species through the existing search; **A/B MobileCLIP vs dino.txt** on the same set. (Cross-platform target: one `.onnx` for Android + iOS.)
2. **Flutter vision tool.** Wire [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime) (CoreML on iOS, NNAPI on Android); implement `extract_visual_features(image[, focus])` and `check_visual_evidence(image, claims)` Dart handlers (shared image↔text scoring + per-photo embedding cache).
3. **Swap the LLM.** Point `flutter_gemma` at Qwen3-0.6B (`.litertlm`); confirm function calling + GBNF-constrained tool args.
4. **Rewrite the agentic prompts.** Recast `identifySystemInstruction` / `identifySynthesisPrompt`: STEP 1 "look & describe" → `extract_visual_features`; STEP 2 → existing `search_similar_features` (unchanged); STEP 4/CASE 2 retry → re-extract focused attributes / `check_visual_evidence` → re-search; keep the 4-pass cap, DB grounding, confidence thresholds.
5. **Evidence UI.** Surface matched traits + DINOclip scores (the writeup's Next Step #3).
6. **Benchmark** vs current Gemma 4 E2B: accuracy, latency, size, hallucination rate.

### 8.2 Component shape (app lifecycle & components)

#### 8.2.1 Delivery — what ships where
| Model | Size | Delivery | Runtime |
|---|---|---|---|
| Vision (MobileCLIP/DINOclip, int8 image-encoder ONNX) | ~12–22 MB | **bundled in `assets/`** | `flutter_onnxruntime` |
| Qwen3-0.6B (reasoning) | ~474 MB | **downloaded once** (existing flow) | `flutter_gemma` |

Boot: load the vision model from assets (instant, offline) **and** check/download Qwen3 → ready ⇔ both loaded. `ModelBootPhase` is unchanged; "downloading/installing" now refers only to Qwen3 (5× smaller than today). This preserves the "download once, then fully offline" deployment story.

#### 8.2.2 New — `lib/services/vision_runtime.dart`
Owns the ONNX vision model and all image↔text scoring:
```dart
class VisionRuntime {
  Future<void> loadFromAssets();                                  // int8 image encoder
  Future<Map<String,String>> extractVisualFeatures(Uint8List image, {List<String>? focus});
  Future<Map<String,double>> checkVisualEvidence(Uint8List image, List<String> claims);
  void disposeImageCache();                                       // per-photo embedding
}
```
- Image embedding computed **once per photo and cached** → `extract` + multiple `check` calls reuse it.
- Attribute label-text embeddings are **precomputed offline** and shipped as an asset table → `extract` needs only the image encoder at runtime.

#### 8.2.3 `model_runtime.dart` — LLM goes text-only
flutter_gemma runtime stays structurally the same (function-call loop), minus the image: **no `imageBytes` is sent to the model** (Qwen3 is text-only; the photo goes only to the vision tools). Simpler than today — no multimodal session / image prefill.

#### 8.2.4 `model_service.dart` — owns both runtimes, wires the tools
Holds the LLM runtime **and** `VisionRuntime` (+ existing `SpeciesService`, `DownloadService`). `identifySpecies(imageBytes, …)` builds three tools whose `execute` closures capture the photo + backend, then runs the LLM loop **without passing the image to the model**:
```dart
final tools = [
  ToolSpec('extract_visual_features',  (a) => vision.extractVisualFeatures(image, focus: a['focus'])),
  ToolSpec('search_similar_features',  (a) => species.searchSimilarByFeatures(...a)),   // UNCHANGED
  ToolSpec('check_visual_evidence',    (a) => vision.checkVisualEvidence(image, a['claims'])),
];
await _llm.generateResponse(ChatPrompts.identifyInputPrompt,
    systemInstruction: ChatPrompts.identifySystemInstruction(lang),
    toolSpecs: tools, languageName: lang, onTrace: onTrace, onProgress: onProgress);
```
`isModelLoaded = vision.isLoaded && llm.isLoaded`; `downloadSizeLabel='0.47GB'`; `modelUrl→Qwen3-0.6B.litertlm`. `askQuestion`/`translate` unchanged. Image embedding disposed when identification ends.

#### 8.2.5 Assets & pubspec
```
assets/models/
  vision_image_encoder.int8.onnx   # ~12–22 MB  (dino.txt preferred; MobileCLIP to prototype)
  attribute_embeddings.bin         # precomputed label-text embeddings
  attribute_vocab.json             # label sets per attribute
# vision_text_encoder.onnx         # only if check_visual_evidence (arbitrary claims) is enabled
```
Deps: `flutter_onnxruntime` (+ `image` already present for resize/normalize). The `VisionRuntime` is model-agnostic, so MobileCLIP↔dino.txt is a file swap behind the same interface.

#### 8.2.6 Unchanged
`species_service.dart` (FTS5 + Dice), `model_download_service.dart` (single-model, just URL/size), `analyzing_page.dart` (same `identifySpecies` signature + `onTrace` streaming), SQLite DB, boot-state machine, l10n, Q&A flow.

#### 8.2.7 Phasing note
**v1 = `extract_visual_features` + existing search** (one bundled model file, image encoder only). **v2** adds `check_visual_evidence` (arbitrary-claim scoring → also ship the text encoder). Both are now implemented — see §8.3.8.

---

### 8.3 What we built — challenges & solutions

This section records the real v1 build of the vision tool: the exporter, the two
shipped assets, and the problems that surfaced once we touched the real models
(several invalidated assumptions in §3.2/§8.2).

> **Terminology — "DINOclip" → Talk2DINO.** The planning sections (title, §3.2)
> use the working name *DINOclip* for the text-aligned DINO vision tool. The
> implementation settled on a concrete model: **Talk2DINO**
> (`lorebianchi98/Talk2DINO-ViTB`, DINOv2 ViT-B/14-reg + CLIP-text alignment).
> Wherever the earlier text says "DINOclip", read "Talk2DINO" — and note it is a
> *segmentation*-oriented model, which drove the approximations below (§8.3.2).

#### 8.3.1 What ships

| Artifact | Size | Notes |
| --- | --- | --- |
| `assets/models/dino_image_encoder.onnx` | ~92 MB (dynamic int8) | DINOv2 **ViT-B/14-reg** image encoder with pooling baked into the graph |
| `assets/models/dino_text_encoder.onnx` | ~129 MB (fp16) | CLIP text → Talk2DINO projection (v2 `check_visual_evidence`) |
| `assets/models/dino_attribute_embeddings.json` | ~2.5 MB | 7 attributes × controlled-vocab labels, each with its text embedding |
| `assets/models/clip_vocab.json` + `clip_merges.txt` | ~1.5 MB | CLIP BPE tables for the Dart tokenizer |
| `scripts/export_vision_model.py` / `validate_vision_model.py` | — | Create + validate; pull Talk2DINO from HF, run via `uv` |

Binaries are **git-ignored** (`assets/models/`) and regenerated on demand —
`uv venv .venv-export && uv pip install -r scripts/requirements-export.txt &&
.venv-export/bin/python scripts/export_vision_model.py`.

Two size revisions from the plan: (1) §6 budgeted a ViT-**S** (~22 MB int8), but
the text-aligned weights only exist for ViT-**B**; (2) precision is per-encoder —
**image = dynamic int8 (~92 MB, verified on-device), text = fp16 (~129 MB)** — see
§8.3.10. Net bundled vision assets ≈ **225 MB**, well under the ~474 MB LLM + the
2.58 GB model this replaces.

#### 8.3.2 Challenge — Talk2DINO is a *segmentation* model, not a whole-image classifier

§3.2 assumed a CLIP-style "embed the image → cosine vs label text" encoder. The
real model is different in three ways that broke that assumption:

- **Projection direction is reversed.** Talk2DINO aligns **CLIP text → DINO
  space** (`project_clip_txt`); the DINO image features stay native. So the
  image side is *not* projected — only the text labels are. The exporter now
  loads the HF `AutoModel` (which bundles DINOv2 + CLIP + the projection) and
  uses its real `encode_text` for the label embeddings.
- **`encode_image` returns patch tokens `(N, L, D)` at 518 px**, not one vector —
  it's built for dense open-vocabulary *segmentation*.
- **Its whole-image representation uses multi-head "disentangled self-attention"
  pooling** (forward hooks + an `is_training` branch + max-over-heads matching),
  which neither ONNX-exports cleanly nor matches our single-vector cosine
  runtime.

**Solution — a tractable single-vector approximation (design-reviewed).** We pool
the DINO patch tokens to one 768-d vector inside the ONNX graph, L2-normalise,
and cosine-match against the projected label embeddings (same space). This keeps
[vision_runtime.dart](../../lib/services/vision_runtime.dart) as a simple
embed-once-then-argmax engine and avoids the un-exportable attention machinery.

#### 8.3.3 Challenge — naïve mean-pooling matched the *background*

The first export mean-pooled all 1369 patches. Validation on real photos exposed
the failure: a **panda** matched **plant** traits ("various shades of green",
"bushy foliage") and a **tiger**'s colour came back "grayish-brown". A flat mean
lets grass/foliage patches dominate the embedding, and Talk2DINO's text was
aligned to its *attention-weighted* pooling, not a plain mean.

**Solution — CLS-saliency-weighted pooling.** Weight each patch by the softmax of
its cosine similarity to the CLS token (a cheap, fully ONNX-exportable saliency
proxy that foregrounds the subject and stays in the text-aligned space), then sum.
We compared three poolings on tiger/panda; the winner is decisive:

| Attribute | mean (background-dominated) | **CLS-saliency (shipped)** |
| --- | --- | --- |
| Tiger colour | "grayish-brown" ✗ | **"yellow and black stripes with white spots"** ✓ |
| Panda colour | "various shades of green" ✗ | **"white, dark brown, black"** ✓ |
| Both texture | "leafy/rough" ✗ | **"furry"** ✓ |

Plain CLS token alone scored ~0.05 (it's outside the patch-aligned text space) —
confirming the saliency-over-patches formulation is the right one.

#### 8.3.4 Challenge — int8 quantization perturbs a softmax-sensitive output

After switching to saliency pooling, the int8 encoder's raw embedding diverged
from fp32 (cosine parity fell from ~0.997 to **0.53–0.82**) — the softmax
amplifies small weight perturbations into different patch weightings.

**Solution — measure the metric that matters.** The tool emits the *argmax* label,
not the raw vector. Across both validation images, the int8 **top-1 label is
identical to fp32 for every attribute** — quantization moves the vector within a
region that doesn't change which vocabulary label is nearest. So int8 (90 MB) is
safe; no fp16/fp32 upsize needed.

#### 8.3.5 Challenge — `distinctive_marks` contract mismatch

The first exporter omitted `distinctive_marks` as "free-form / hard to
enumerate", but the `search_similar_features` schema lists it **required** and the
system prompt forbids inventing traits a tool didn't report — so the LLM would be
forced to either fabricate or stall.

**Solution.** It has **63 distinct DB values** (on par with `pattern` 54, `color`
50) — no more free-form than columns we already include. Added it to the
exporter's `ATTRIBUTE_COLUMNS`; the vision tool now emits all **7** attributes the
search tool expects. Keep the exporter's `ATTRIBUTE_COLUMNS` and the tool's
`required` list in sync — `extract_visual_features` can only emit what's scored.

#### 8.3.6 Toolchain pitfalls (for whoever re-runs the export)

- **`transformers` 5.x breaks Talk2DINO's remote code** (`all_tied_weights_keys`
  in the weight-finalize path). Pin `transformers<5`.
- **torch ≥ 2.9 defaults `onnx.export` to the dynamo path**, which needs
  `onnxscript`. We pass `dynamo=False` to use the stable TorchScript exporter.
- DINOv2 loads via `torch.hub` on first run (needs network); xFormers warnings
  are harmless on CPU.

#### 8.3.7 Honest limitations

The single-vector approximation is **strong on coarse traits** (colour, texture,
distinctive_marks) but **noisier on fine ones** — e.g. the panda's `visual_group`
came back "Primate" and `size_class` "small rodent". This is the expected cost of
dropping the attention-weighted multi-head pooling, and it is exactly what the
agentic retry loop (§4: re-observe with `focus`, then `check_visual_evidence` in
v2) is designed to recover from. If fine-attribute accuracy proves limiting,
the upgrade path is to reproduce Talk2DINO's `avg_self_attn` pooling in an
exportable form, or move to its full disentangled matching (§8.3.2).

#### 8.3.8 v2 — `check_visual_evidence` (arbitrary-claim scoring), implemented

v1 only `extract`s attributes; the prompt's retry loop also calls
`check_visual_evidence` to score free-text claims against the photo. Unlike the
attribute path (labels precomputed offline), arbitrary claims must be embedded
**at runtime**, which needs the text encoder *and* a tokenizer on-device.

**What we added**
- **`dino_text_encoder.onnx`** (~129 MB fp16) — exported wrapper around CLIP text
  + `project_clip_txt` (the same path as the attribute embeddings, just with
  tokenisation lifted out). Input `token_ids` int32 `[1,77]` → 768-d L2-norm in
  DINO space. CLIP loads fp16; we cast to fp32 before export so the text encoder
  and the precomputed attribute embeddings stay numerically consistent.
- **`clip_tokenizer.dart`** — a faithful Dart port of CLIP's byte-level BPE
  (`SimpleTokenizer` + `clip.tokenize`), driven by two dumped assets
  (`clip_vocab.json`, `clip_merges.txt`). `check_visual_evidence`
  tokenises each claim → text encoder → cosine vs the cached image embedding.
- **Wiring** — `VisionRuntime.checkVisualEvidence`, plus `ModelService`
  registers the tool **only when `canVerify`** (text encoder loaded), so the
  prompt never advertises a tool the runtime can't back. If the text encoder
  fails to load, the runtime degrades to v1 cleanly.

**Challenge — on-device tokenisation.** The text encoder is useless without the
*exact* CLIP token IDs; a mismatch silently produces garbage embeddings.
Re-implementing byte-level BPE (byte↔unicode table, the pre-tokenisation regex,
rank-ordered merges, 77-length SOT/EOT padding) in Dart is the error-prone part.
**Solution + validation:** we mirrored the Dart algorithm in Python and diffed it
against real `clip.tokenize` — **9/9 test strings exact** (punctuation, digits,
hyphenated words included).

**Challenge — scores aren't a clean 0–1.** Cosine in the aligned space is small
(good matches ~0.15–0.35, wrong ones ~−0.05–0.03), so a fixed 0–1 threshold
misleads. **Solution:** return the raw similarity and frame it as **relative** in
the tool description; the prompt's STEP 4 instructs the model to include a
deliberately-wrong **control claim** and compare against it rather than a fixed
cutoff.

**Validation (tiger / panda).** Text-encoder ONNX↔torch parity mean 0.962; claim
scoring is correctly discriminative — tiger "a large striped cat" **+0.34** ≫
"an aquatic fish" +0.02; panda "a bear-like body" **+0.29** ≫ "green leafy
plant" **−0.02**.

**Size.** ~129 MB (fp16 text encoder) + ~1.5 MB (vocab/merges) on top of the
~92 MB int8 image encoder — ~225 MB of bundled vision assets total, still far
under the 2.58 GB model this architecture replaces.

#### 8.3.9 Covering data beyond the curated DB (answering constraint §2)

A fair objection: `dino_attribute_embeddings.json` labels are **derived from the
species DB** (`build_vocabularies` takes the distinct, trimmed, first-seen-casing
trait values), so they are canonicalised labels, not raw source text — and they
only span traits the DB already contains. If that were the whole system, it could
never describe anything outside `assets/data`. It isn't, and here's why coverage
extends past the curated set:

- **`extract_visual_features` is closed-vocabulary — but traits are shared and
  compositional.** Its labels are DB-derived, so it emits the nearest *existing*
  label. That still generalises across species because colour / shape / texture /
  pattern are not species-specific — a never-seen bird reuses labels other species
  contributed. The vocabulary spans a *trait space*, not a *species list*, so the
  first-pass observation degrades gracefully on novel subjects instead of failing.

- **`check_visual_evidence` is open-vocabulary — the real escape hatch.** Its text
  encoder + Dart CLIP tokenizer (§8.3.8) embed **arbitrary free text at runtime**,
  not the precomputed labels. The LLM can propose any hypothesis for a species
  absent from the DB ("long curved casque on the bill", "bioluminescent flank
  spots") and have DINO score it against the photo. Coverage here is bounded by
  the open-world DINO/CLIP space, not by `assets/data`.

- **The model is open-world; only the precomputed `extract` index is DB-bounded.**
  Talk2DINO/CLIP align *any* text to image space (web-scale training). Precomputing
  a DB subset for the cheap first pass is a caching choice, not a capability
  ceiling.

- **The LLM is the reasoning core; the DB is a grounding index, not the limit.**
  When `search_similar_features` returns no match (a novel species), the flow
  doesn't dead-end — the model still has coarse `extract` traits + open-vocab
  `check`, and reports a best-effort identification in `identification_notes`
  (`is_endangered` stays false unless a DB match is confirmed).

- **Scales without retraining (§2).** New species = add DB rows + re-run
  `build_vocabularies` (re-embed labels with the **frozen** text encoder, seconds)
  for the `extract` index; the open-vocab `check` path + LLM reasoning need no
  re-export at all. Weights never change.

So the derived-label caveat constrains only the closed `extract` path; the open
`check` path and the LLM are exactly the mechanism that satisfies "covers data
beyond the curated set."

#### 8.3.10 Challenge — on-device quantization (the int8 trap)

The first device run surfaced a failure no Python validation could: the int8
image encoder **failed to load** on Android —
`ORT_NOT_IMPLEMENTED: Could not find an implementation for ConvInteger(10)`.
`flutter_onnxruntime`'s ORT-Android build has no `ConvInteger` kernel. And
because `isModelLoaded` ANDs `vision.isLoaded`, a vision-load failure doesn't
just disable a tool — it **blocks boot entirely** (the Qwen text model loaded
fine; the app still never went ready). Lesson: validate the *runtime/op support*
on-device, not just numerics on desktop.

Working through the quantization options showed int8 is a dead end for these
**embedding** models specifically:

| Mode | Loads on ORT-Android? | Accuracy | Size (img) | Why |
| --- | --- | --- | --- | --- |
| dynamic int8 (full) | ❌ | good | ~90 MB | emits `ConvInteger` (no kernel) |
| static int8 (QDQ) | ✅ | **destroyed** | ~88 MB | int8 *activations* collapse the 768-d cosine geometry — tiger→"green", text parity ≈ 0 |
| **dynamic int8, MatMul-only** ✅ (shipped) | ✅ **verified** | good (~0.99) | ~92 MB | excludes Conv → `MatMulInteger`, which the ARM build *does* implement |
| fp16 | ✅ | ~1.000 | ~173 MB | standard `Conv`/`MatMul` + `Cast`; safe but ~2× the size |

Key insight: dynamic int8 keeps **activations in fp32** (so cosine angles
survive) but full dynamic quant produces `ConvInteger`, which ORT-Android lacks;
static int8 uses the mobile-supported `QLinearConv`/`QLinearMatMul` but
**quantises activations**, which destroys a normalised-embedding model.

**Solution — dynamic int8, MatMul-only (image) + fp16 (text).** Excluding the lone
patch-embed Conv from dynamic quant drops `ConvInteger` and emits only
`MatMulInteger` — and an on-device test (Settings → Model info indicator)
**confirmed the ARM build implements `MatMulInteger`**, so the ~92 MB int8 image
encoder loads and is accurate. The **text** encoder ships **fp16** (~129 MB):
dynamic int8 is *larger* for the text transformer, and static int8 collapses it.
fp16 stayed available as a no-risk fallback (`onnxruntime.transformers`'s
converter, not `onnxconverter_common`, which left mixed-type `Div` nodes ORT
rejects). Exporter defaults: `--image-quant dynamic --text-quant fp16`.

> The A/B probe + the "Vision engine" settings indicator that confirmed
> `MatMulInteger` support were removed once verified; the runtime now loads the
> single int8 image encoder directly.

**Follow-up (not yet done):** the AND-gate boot dependency means any future vision
failure bricks startup — consider degrading to a vision-disabled mode instead.

---

## References

**Models & sizes**
- Qwen3-0.6B (LiteRT, ~474 MB int4) — https://huggingface.co/litert-community/Qwen3-0.6B
- Gemma 3 1B (LiteRT, ~554 MB int4) — https://huggingface.co/litert-community/Gemma3-1B-IT
- Gemma 4 family (E2B/E4B/12B/26B/31B; smallest is E2B) — https://artificialanalysis.ai/articles/gemma-4-everything-you-need-to-know · https://ai.google.dev/gemma/docs/core/model_card_4
- Gemma 3 tool-calling weakness; SLM landscape — https://computingforgeeks.com/ollama-models-cheat-sheet/ · https://localaimaster.com/blog/small-language-models-guide-2026

**Runtime**
- flutter_gemma (LiteRT-LM, supported models, function calling) — https://pub.dev/packages/flutter_gemma · https://github.com/DenisovAV/flutter_gemma
- LiteRT (on-device runtime, OpenCL GPU on Android) — https://ai.google.dev/edge/litert
- On-device function calling with flutter_gemma — https://medium.com/easy-flutter/on-device-function-calling-in-flutter-using-flutter-gemma-7cf58a92ec15

**Vision (DINO / DINOclip / CLIP)**
- DINOv2: Learning Robust Visual Features without Supervision (Oquab et al., 2023) — https://arxiv.org/abs/2304.07193
- DINOv2 for fine-grained classification (biological imaging, look-alike classes) — https://towardsai.net/p/computer-vision/harness-dinov2-embeddings-for-accurate-image-classification
- DINOv2 vs CLIP vs ResNet on iNaturalist-2021 (embedding quality / V-measure) — https://voxel51.com/blog/finding-the-best-embedding-model-for-image-classification
- **dino.txt — "DINOv2 Meets Text" (CVPR 2025): SOTA on iNaturalist zero-shot, ≥ CLIP on classification** — https://arxiv.org/html/2412.16334v1 · https://openaccess.thecvf.com/content/CVPR2025/papers/Jose_DINOv2_Meets_Text_A_Unified_Framework_for_Image-_and_Pixel-Level_CVPR_2025_paper.pdf
- Talk2DINO (DINOv2 + CLIP text alignment, ICCV 2025) — https://arxiv.org/html/2411.19331v3
- Note: plain DINOv2 has **no text encoder** — the text-aligned variant (dino.txt/Talk2DINO) is required for zero-shot attribute scoring.
- One Patch to Caption Them All (zero-shot DINO captioning) — https://arxiv.org/pdf/2510.02898
- MobileCLIP TFLite files (S1 ≈ 324 MB, S2 ≈ 379 MB, B ≈ 572 MB — full precision; quantize for bundling) — https://huggingface.co/anton96vice/mobileclip2_tflite

**Vision runtime — cross-platform (Android + iOS)**
- flutter_onnxruntime (CoreML on iOS, NNAPI/QNN on Android) — **recommended** — https://pub.dev/packages/flutter_onnxruntime
- ONNX Runtime mobile deployment (iOS/Android) — https://onnxruntime.ai/docs/tutorials/mobile/
- tflite_flutter (Android NNAPI/GPU, iOS Metal/CoreML) — fallback — https://pub.dev/packages/tflite_flutter
