# v3 · Plan — dense text↔image matching (conformant fine-grained ID)

**Status:** 📝 DRAFT · not started

## Goal

On-device species identification under a small footprint (target ≤ ~0.7 GB), with
**fine-grained** accuracy on visually similar species — without losing the
generative reasoning core. Three hard constraints must hold:

1. **No data dependency** — knowledge-guided (frozen pretrained features + curated
   text), no per-species reference images, no trained classifier.
2. **Scale without retraining** — a new species = new DB rows only (no images, no
   re-export, no redeploy).
3. **Model is the reasoning core** — a generative LLM interprets, reasons across
   candidates, verifies, and explains; vision is a callable tool.

## The core challenge

Fine-grained species differ by *local* detail — a crest, a throat patch, webbed feet.
Two failure modes bound the design:

- **Global single-vector matching loses that detail.** Pooling an image to one
  embedding (CLS / mean) and comparing against text or labels optimizes *holistic*
  similarity; the subtle local cues that separate look-alikes wash out. This caps
  the conformant text-matching path at mediocre accuracy.
- **Reference-image approaches break the constraints.** Few-shot prototypes /
  nearest-neighbour galleries score very well, but each species needs example images
  — a reference-image dataset that violates constraints #1 and #2.

So the target is: **fine-grained discrimination from a small frozen encoder, using
only text per species.**

## Key insight

A text-aligned vision encoder (e.g. Talk2DINO — an open-vocabulary *segmentation*
model) emits **text-aligned patch tokens**, a grid of local features each comparable
to text. Pooling to a single vector **discards** them. v3 keeps the patch grid and
matches it against species/trait **text**, recovering the local signal for free —
the tokens come from the same forward pass.

## Proposed architecture

```
[photo] → image encoder (ONNX, flutter_onnxruntime) → patch tokens  (NOT pooled)
   │
   ├─ Tier-0  visual_group: dense max-sim(patches, group text) → coarse prune / gate
   ├─ Tier-1  species shortlist: dense max-sim(patches, candidate species
   │            descriptions within the predicted group) → top-K + score
   │            └─ max-score < τ ? → OUT-OF-DISTRIBUTION → open-world (LLM)
   └─ Evidence  traits: dense max-sim(patches, controlled-vocab trait phrases)
        ▼
  Qwen3-0.6B  (reasoning core, flutter_gemma / LiteRT)
        · decides among the top-K using retrieved DB descriptions (RAG)
        · checks trait evidence against the matched species' DB record (verify)
        · narrates the ID + answers follow-ups
  Curated SQLite DB → species names, descriptions, taxonomy, facts (ground truth)
```

**Matching is image↔text, never image↔image.** Candidate text — species names, short
discriminative descriptions, trait phrases — is **DB-derived**, so adding a species is
a row edit. That is what keeps #1 and #2 satisfied while reaching for fine-grained
accuracy.

**Scoring — dense max-similarity (lead approach):** for a phrase, score `max` (or
top-k mean) over patches of `cosine(patch, phrase)` — *"does **any** region strongly
match this discriminative phrase?"* No multi-vector index, no training; a cheap reduce
over the patch grid the encoder already produced. `visual_group` (a reliable coarse
signal) gates the candidate set first, so species-level matching runs on few candidates.

## Tool schemas

The LLM is blind; it drives the photo through three tools. The Dart handler holds the
patch tokens — the model supplies only query parameters:

- `extract_visual_features({focus?})` → `{color, body_shape, distinctive_marks,
  texture, size_class, pattern, visual_group}` via dense max-sim(patches, trait
  phrases). `focus` narrows to specific attributes and can report *where* each cue fired.
- `search_species({group?, top_k})` → dense max-sim(patches, species descriptions),
  gated by the predicted `visual_group` → ranked species + scores; below τ → OOD.
- `check_visual_evidence({claims[]})` → dense max-sim(patches, arbitrary claim text)
  → per-claim localized score, for verifying or pivoting to a competing hypothesis.

Closed-set text (trait phrases, species descriptions) is embedded **offline**;
`check_visual_evidence` embeds arbitrary claims at **runtime** — the one component that
needs the runtime text encoder.

## Why a frozen encoder + text LLM

The architecture plays to each component's strengths:

- **Mature, hardware-accelerated runtimes.** A frozen image encoder exports cleanly
  to **ONNX** and runs on the native mobile paths (CoreML on iOS, NNAPI on Android via
  `flutter_onnxruntime`); the small text LLM runs on its own proven LiteRT path with
  function calling. Two specialized, well-supported runtimes, each doing what it's
  good at.
- **Separation of concerns.** Vision is a deterministic, *scored tool* — embed, match,
  return candidates — while reasoning, candidate weighing, and explanation live in the
  LLM. Each side can be tuned, swapped, or quantized independently.
- **The model stays the reasoning core** (constraint #3): the LLM orchestrates the
  vision tool, decides across candidates, verifies against the DB, and narrates —
  vision never collapses into the classifier.
- **The accuracy lever is nearly free.** The patch tokens are already produced by the
  same forward pass; dense max-sim adds only a cheap reduce — **no new model, no extra
  footprint, no new runtime**. Fine-grained gains come at essentially zero cost.
- **Headroom to grow.** Because matching is text↔image, every lever — candidate
  descriptions, the hierarchy gate, the OOD threshold, even the encoder — improves
  independently, with no retraining and no re-architecting.

(The on-device runtime exploration behind this choice lives in [v1](../v1-smaller-vlm/).)

## Potential — a natural substrate for the agentic loop

The app's fix-and-pivot loop (on a failed or low-confidence match, re-observe and
**pivot** the hypothesis rather than repeat it) maps directly onto dense matching.

The image is deterministic — same photo → same patch tokens — so a re-observation
yields no new *pixels*. The agentic "different result" instead comes from **querying
the fixed patch tokens with different text**, which is exactly what the pivot does:

- **Focused re-observation** (`extract_visual_features {"focus":["pattern","visual_group"]}`)
  → dense max-sim of the patches against *only* those trait phrases — same tokens,
  narrowed query, a different focused score.
- **Competing hypothesis** (e.g. Gorilla → Pongo) → score the patches against the
  rival's discriminative phrases ("orange-red hair, very long arms, no sagittal
  crest"); `check_visual_evidence` *is* this same dense-max-sim op.

Why it fits well:

- **One unified primitive** — primary matching, focused re-observation, and hypothesis
  testing are all "dense max-sim of patches vs text"; the pivot is a first-class query,
  not a separate mechanism.
- **Localized evidence** — max-over-patches reveals *which region* matched a phrase, so
  "re-observe limb proportions / hair pattern" returns spatially-grounded signal a pivot
  can act on. Global pooling cannot localize.
- **Open-vocabulary** — any hypothesis the LLM forms can be scored; no fixed label set.

Dependencies (folded into the open questions):

- The pivot only surfaces something new if the candidate text **contains** the
  discriminating cues to query — so discriminative descriptions (Q3) are on the
  critical path.
- Because the image is fixed, the LLM must issue a *genuinely different* query; the
  STEP-5 prompt rule + thinking mode drive that, while the vision tool enables it.

## Coverage beyond the curated DB (answering §2)

Species descriptions are DB-derived, so the closed `search_species` index is bounded by
`assets/data` — but coverage extends past the curated set:

- **`check_visual_evidence` is open-vocabulary** — it embeds arbitrary claim text at
  runtime, so the LLM can test hypotheses for species absent from the DB (bounded by the
  open-world encoder space, not the DB).
- **OOD routing** — when the best species score is below τ, the subject is treated as
  unknown and handed to the LLM's open-world reasoning (with `visual_group` + traits as
  evidence) rather than forced onto a wrong curated match.
- **The model is open-world; only the precomputed `search` index is DB-bounded** — a
  caching choice, not a ceiling.
- **Scales without retraining** — a new species = add its description row + precompute its
  embedding with the frozen encoder; the open-vocab path needs nothing re-exported.

## Design at a glance

| | global single-vector | **dense text-match** |
| --- | --- | --- |
| Image features | pooled → 1 vector | **patch tokens** (no pooling) |
| Match target | trait labels / reference vectors | species/trait **text** (DB) |
| Fine-grained signal | washed out | **localized** (max over patches) |
| Per-species data | — / reference images | **none** — DB text only |
| Footprint | encoder | **same** encoder |

## Sizes, trade-offs, and risks

### Footprint (projected)
| Component | Size |
|---|---|
| Qwen3-0.6B (int4, `.litertlm`) | ~0.47 GB (downloaded once) |
| Image encoder (int8 ONNX) — emits patch tokens | ~90 MB (bundled) |
| Text encoder (fp16 ONNX) — runtime open-vocab claims | ~129 MB (bundled) |
| Precomputed description + phrase embeddings | ~few MB (bundled) |
| **Total on-device** | **~0.7 GB** |

Same footprint as a single-vector design — the patch tokens come from the same image
forward pass; dense matching adds compute, not parameters.

### Why the text encoder won't shrink below ~129 MB
fp16 is already the floor for this encoder — it's structural, not a missed quant:

- **The cost is the ~49k-vocab token-embedding table — a `Gather`, not a `MatMul`.**
  Our dynamic int8 path is MatMul-only (the one int kernel that loads on Android), so it
  *skips* the embedding table → **int8 is actually *larger* (~141 MB) than fp16 (~129 MB)**.
- **Static int8/QDQ does shrink it, but collapses the embedding geometry** — and this
  encoder's whole job is to land text in the image's space for cosine matching.
- **The vocab can't be pruned** — the open-vocab path (`check_visual_evidence` / the
  STEP-5 pivot) embeds *arbitrary* claim text at runtime, so any token may be hit.

The only genuine reduction is to **drop it entirely** and rely on precomputed closed-set
text — which saves the full ~129 MB but removes the open-vocab / agentic pivot. That
trade (not a quantization trick) is risk #4.

### Risks (and where they're addressed)
1. **Dense-matching lift unproven on our taxa** — gated by the Q1 probe before any build.
2. **Description quality is on the critical path** — weak/non-discriminative species text
   caps both accuracy and the agentic pivot (Q3; LLM-enrich offline).
3. **Patch-token memory/latency on-device** — ~1k transient tokens per image (Q4).
4. **The runtime text encoder stays** — open-vocab hypothesis testing needs it, so this is
   not a pure image-only build.
5. **Two runtimes** (LiteRT-LM + ONNX) — bridged by the tool loop, both cross-platform.

## Open questions — validate before building

1. **The lift (first probe):** does dense max-sim(patch, text) beat global pooling on
   our species set, and by how much? Offline experiment on patch tokens — **this gates
   the plan.**
2. **Encoder choice:** Talk2DINO (native dense alignment) vs a CLIP-family encoder
   (e.g. BioCLIP for species priors). Dense-match quality *and* §2 both matter.
3. **Description quality:** text matching needs *discriminative* species descriptions;
   the LLM can enrich DB facts into them offline (conformant, text-only).
4. **On-device cost:** keeping ~1k patch tokens transiently per image; the reduce is
   cheap, but confirm memory/latency on target hardware.
5. **OOD threshold** τ for the open-world tier.

## Alternatives considered

| Approach | mechanism | cost | note |
| --- | --- | ---: | --- |
| **Dense max-sim** ← lead | max/top-k over aligned patches × text | lightest | uses the encoder as designed; no index |
| Region pooling | K region descriptors × text | medium | fewer vectors than per-patch |
| Global + local rerank | global shortlist, local re-rank | low | composes with the Tier-0 gate |
| ColPali late-interaction | per-token MaxSim, multi-vector index | heavy | strongest, needs a multi-vector store |

All are conformant (text from DB, no reference images), ONNX-friendly, and composable.

## Component shape (app lifecycle)

| Model | Size | Delivery | Runtime |
|---|---|---|---|
| Vision encoders (int8 image + fp16 text ONNX) | ~220 MB | bundled in `assets/` | `flutter_onnxruntime` |
| Qwen3-0.6B | ~474 MB | downloaded once | `flutter_gemma` |

- **`vision_runtime.dart`** — owns the ONNX encoders + all dense patch↔text scoring;
  patch tokens cached per photo; closed-set text embeddings precomputed offline.
- **`model_runtime.dart`** — LLM is text-only; the photo goes only to the vision tools.
- **`model_service.dart`** — owns both runtimes, wires the three tools whose closures
  capture the photo.

## Rollout (proposed)

1. **Probe** — offline dense max-sim vs global pooling (Q1).
2. **Export** — emit patch tokens (or a dense-sim op) from the encoder; size stays flat.
3. **Runtime** — dense match + Tier-0 gate + OOD τ in `vision_runtime.dart`.
4. **DB** — add/enrich discriminative species descriptions (LLM-assisted, offline).
5. **Eval** — rank-1/5/MRR + OOD AUROC, scored **image↔text** (conformant).

## Decision summary

- **Matching:** dense max-sim of the image's patch tokens against species/trait **text**
  — fine-grained, zero-shot, no reference images.
- **Vision:** frozen text-aligned encoder, ONNX (CoreML/NNAPI); patch tokens kept, not
  pooled — same footprint as a single-vector design.
- **Reasoning core:** Qwen3-0.6B on `flutter_gemma`; orchestrates the tools, decides
  across candidates, verifies, narrates.
- **Conformance:** scales by DB text rows; no per-species images; model stays the core.
- **First gate:** the Q1 dense-vs-global probe decides whether to proceed.

## References

- DINOv2 (Oquab et al., 2023) — https://arxiv.org/abs/2304.07193
- Talk2DINO (DINOv2 + CLIP-text, ICCV 2025) — https://arxiv.org/html/2411.19331v3
- Exploring Regional Clues in CLIP (CVPR 2024) — https://cg.cs.tsinghua.edu.cn/papers/CVPR-2024-CLIP.pdf
- RegionCLIP (CVPR 2022) — https://openaccess.thecvf.com/content/CVPR2022/papers/Zhong_RegionCLIP_Region-Based_Language-Image_Pretraining_CVPR_2022_paper.pdf
- DenseVLM — https://arxiv.org/html/2412.06244v1
- RegionMed-CLIP (2025) — https://arxiv.org/html/2508.05244v1
- ColPali — late-interaction retrieval (ICLR 2025) — https://arxiv.org/abs/2407.01449
