# 01 · Implementation — Q1 probe: dense vs global matching

**Status:** 🔬 measured · gates the rest of [the plan](00_plan.md)

The plan's first gate (Q1): *does dense patch↔text matching beat global pooling?*
Script: [`scripts/smaller-footprint-pipeline-v3/probe_dense_vs_global.py`](../../../scripts/smaller-footprint-pipeline-v3/probe_dense_vs_global.py).

## Setup

Conformant **zero-shot text↔image** species ID — no reference images, no leave-one-out:
score each species image against **all 64 species' visual text**, rank the true one.
All strategies share the same Talk2DINO patch tokens + text embeddings; only the
pooling differs.

- Encoder: Talk2DINO (DINOv2 ViT-B/14-reg, text projected into DINO space), 518px.
- Text per species: the DB `visual_blob` (normalised visual keywords).
- Data: 332 curated images · 64 species (`sirkulab-mero-data/.../species_data_img`).

## Result — dense **loses** to global ⚠️

| method | rank-1 | rank-5 | MRR |
| --- | ---: | ---: | ---: |
| **global_sal** (shipped CLS-saliency pooling) | **20.2%** | 53.6% | 0.351 |
| global_mean | 9.9% | 30.1% | 0.216 |
| dense_max | 8.7% | 30.7% | 0.206 |
| dense_top5 | 9.6% | 30.1% | 0.209 |

**Dense best 9.6% vs global best 20.2% → Δ −10.5%.** The opposite of the hypothesis.

Two readings:
1. **Simple dense max-sim doesn't clear the bar.** `max` over ~1.4k patches latches
   onto a single noisy/background patch that spuriously matches a wrong species
   (top-5 mean ≥ max is consistent with that), and Talk2DINO's patch alignment is
   *segmentation-coarse* (object/part), not species-fine.
2. **Conformant zero-shot text↔image is weak overall (~20%)** — far below the
   non-conformant image-prototype path. Text-matching, in this crude form, is not it.

**Caveat — the probe tested the *crudest* variant:** a whole-animal keyword **blob**
matched against individual **patches**. That's a semantic mismatch (a patch is a
*region*; the blob describes the *whole animal*). It did **not** yet test what the
plan actually proposes — *localized per-trait phrases* — nor better text.

## Next — two cheap refinements before judging v3

### 1. Localized per-trait phrases
Split each species' descriptors into short phrases ("orange-red hair", "long arms",
"webbed feet"), max-match **each phrase** against the patches, then aggregate
(sum / mean of per-phrase maxes). A region-sized phrase vs a region-sized patch is the
match dense matching is actually for — unlike the whole-animal blob.

### 2. Better text — swap the DB blob for richer descriptions

**What the `blob` is today.** The DB's `visual_blob` (and the `color` / `body_shape` /
`distinctive_marks` / … columns it's built from) were produced by **Gemma 4 E2B
*vision*** looking at each species image (`gemma_visual_features.py`, prompt:
*"Describe the visual features of the species in the image"*), then **stripped to a
flat keyword bag** for FTS5. As matching text that's doubly weak: it's denatured of
sentence structure, and it mixes discriminative cues with generic ones ("smooth",
"medium-sized") that match almost anything.

**The swap.** Use **fuller, discriminative descriptions** instead of the keyword blob —
short natural-language phrases that name the *distinguishing* traits, CuPL/DCLIP-style
("a slender marine fish with bold black-and-white vertical bars and a forked tail").
Probe candidates, in order of effort:
1. **Free swap:** the existing richer Gemma text already in the repo — the
   `visual_features` JSON / `description` field / `notebooks/exports/visual_features_similarity_v3.json`
   — instead of `visual_blob`. Tests whether *text quality alone* moves the needle.
2. **Regenerate for matching:** prompt an LLM to emit 3–5 *discriminative* visual
   phrases per species (what separates it from look-alikes), not a generic description.

**What model we plan to use — and the conformance nuance.**

| Stage | Model | Grounded on | Conformant? |
| --- | --- | --- | --- |
| Existing DB text (baseline to swap in) | **Gemma 4 E2B (vision)** | the species **image** | borderline — authoring used images |
| Production descriptions (target) | **offline text LLM** (Gemma-class or stronger; one-time, off-device) | species **name + taxonomy + curated facts** (no image) | ✅ scales by text |

- For the **probe**, reuse the **existing Gemma 4 E2B** features as an *upper-bound*
  text-quality check — they're already written, image-grounded, and the best text we
  have. If even these don't help dense matching, the problem isn't text.
- For **production**, descriptions must be generated **without images** to satisfy §2
  (a new species = text only). So the plan is an **offline LLM pass** that writes
  discriminative visual phrases from the species **name + taxonomy + curated DB facts**
  (CuPL/DCLIP-style). It runs once per species off-device, so capability matters more
  than size — Gemma 4 (text) or a stronger offline model; the *on-device* model
  (Qwen3-0.6B) is unaffected.

> Image-grounded authoring of the *curated* set is fine (the shipped system ships no
> images); the constraint is that *scaling to a new species* must not require images —
> hence the knowledge-based offline generation for the production path.

## Refinement result — both refinements fail ⚠️

Full run ([`probe_localized_phrases.py`](../../../scripts/smaller-footprint-pipeline-v3/probe_localized_phrases.py);
artifacts in [`outputs/`](../../../scripts/smaller-footprint-pipeline-v3/outputs/)):

| text | pooling | rank-1 | rank-5 | MRR |
| --- | --- | ---: | ---: | ---: |
| blob | **global_sal** | **20.2%** | 53.6% | 0.351 |
| blob | dense_phrase_max | 8.7% | 30.7% | 0.206 |
| traits | global_sal | 15.4% | 46.1% | 0.306 |
| traits | dense_phrase_max | 11.1% | 30.4% | 0.226 |
| traits | dense_phrase_mean | 7.2% | 32.2% | 0.208 |

(Full 2×4 matrix in `outputs/q1_refined_report.md`.)

- **Localized per-trait phrases don't help** — every dense variant (7–11%) stays far
  below global pooling (20.2%).
- **Better text didn't help either** — blob→traits *lowered* global_sal (15.4% < 20.2%);
  the best dense variant (traits·phrase_max, 11.1%) is still ~half of global.
- The 87% smoke number was small-sample (2-species) noise.

## Verdict — Q1 gate FAILS; the dense premise is unsupported

Dense patch↔text matching does **not** beat global pooling for fine-grained species ID —
not with localization, not with better text. The cause looks structural: **Talk2DINO's
per-patch alignment is segmentation-coarse** (object/part level), so matching patches to
species phrases adds noise, not discrimination. And the whole **conformant text↔image
ceiling is ~20%** here — far below the non-conformant image-prototype path (~80%).

**v3-as-drafted (dense text-match on Talk2DINO) is not viable.** What's still untested:

- **A species-specialized encoder for *global* zero-shot text↔image** (BioCLIP-2 is
  +18–30% over CLIP on zero-shot naming) — a *different* thesis (global, not dense),
  conformant, but a bigger encoder (~308 MB) and unmeasured on our taxa.
- **Relaxing §2** to allow few-shot image prototypes (the ~80% path) as a deliberate,
  documented constraint amendment.

The probe did its job: it killed a plausible-but-wrong idea for the cost of two runs,
before any build.

## Reflection — this is a §2 decision now, not a v3/v4 question

Stepping back: **global image↔text matching is the v2 family.** v2's whole
`extract_visual_features` step is global-pooled image ↔ text — so a BioCLIP-2 "global
zero-shot" isn't a new architecture, it's v2's mechanism with a different encoder.
**v3 (dense) was the one genuinely-new mechanism on the table, and it just failed.**

What was vs wasn't measured, precisely:

- v2 measured image↔image **prototypes** (80–93%, non-conformant) and the **two-hop**
  conformant path: image↔trait-label text → text↔text FTS5 → species (~30–45%).
- It never measured the **one-hop direct** version: image ↔ *species-description* text
  with a species-specialized encoder (BioCLIP-2), which skips the lossy trait→FTS5 hop.

So BioCLIP-2 direct zero-shot is an **untested v2 *variant*, not a new version** — and
this probe already showed the direct version with Talk2DINO tops out at 20.2%. BioCLIP-2
(species-specialized) would likely beat 20%, but it's the same global-text family v2
already showed lands far below the ~80% prototype path.

The honest conclusion is harder than "try one more probe":

- the only genuinely-new conformant mechanism (**dense**) is **dead**;
- everything else conformant is **global image↔text = v2's family**, already weak (~20–45%);
- the thing that **works (~80%) is prototypes**, which **violate §2**.

So this isn't really a v3/v4 question anymore — it's the **§2 decision**. Two live paths:

1. **One last v2-variant probe** — BioCLIP-2 *direct* image↔species-description zero-shot,
   to put a real number on the best-case conformant text path. Cheap, but unlikely to
   reach prototype territory.
2. **Amend §2** — accept few-shot prototypes (~80%) as a deliberate, documented
   relaxation, since no conformant mechanism reaches usable accuracy.

> A later scan surfaced a possible **third, orthogonal lever**: non-visual **priors**
> (geographic range / habitat) that shrink the candidate set so even a weak conformant
> matcher suffices — conformant by construction and on-device-trivial. Worth a probe
> before committing to the §2 amendment.
