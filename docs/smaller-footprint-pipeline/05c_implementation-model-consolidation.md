# 05c · Implementation — model comparison cleanup & canonical scripts

**Status:** ✅ done · **Owns:** the canonical `scripts/{export_vision_model,validate_vision_model,build_prototypes,eval_vision,eval_combined_vision,eval_species_retrieval}.py` flow plus the model-specific copies under `scripts/smaller-footprint-pipeline/`

## What we did

- Kept the original Talk2DINO scripts as the canonical baseline.
- Restored the model-specific script copies for the other backbones so they stay
  separate entrypoints, but grouped them in `scripts/smaller-footprint-pipeline/`.
- Kept the comparison scripts explicit and self-contained under
  `scripts/smaller-footprint-pipeline/comparison/` instead of wrapping them
  through a shared helper.
- Renamed the on-disk assets to suffix form so the filenames stay model-specific
  (`image_encoder_talk2dino.onnx`, `text_encoder_talk2dino.onnx`,
  `attribute_embeddings_talk2dino.json`, etc.).
- Removed only the Talk2DINO duplicate layer when it was redundant.

## Done

- The canonical export, validation, prototype-building, and eval scripts remain
  the baseline entrypoints.
- The other backbone-specific suffixed scripts now live in the
  `scripts/smaller-footprint-pipeline/` subtree.
- The comparison scripts are per-model and self-contained.
- The docs and asset paths agree on suffix-based filenames.

## Exported ONNX sizes

Total = the **image encoder** only — species retrieval is image↔image, so the
photo encoder is the bundled/run footprint; the text encoder powers only
`check_visual_evidence` and isn't part of the comparison.

| Model | arch | fine-grained species | zero-shot naming | estimated size | actual image | actual text | actual total | notes |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| `talk2dino` *(current)* | ViT-B/14 | good | weak | ~12–22 MB int8 | 91.7 MB | 129.2 MB | 220.9 MB | what we have |
| `dinov2_small` | ViT-S/14 | best fine-grained image (70% on 10k species) | ✗ none | ~22 MB int8 | 88.4 MB | — | 88.4 MB | drops text → LLM does the naming |
| `bioclip` | ViT-B/16 | very good | good (species) | ~86 MB int8 | 89.2 MB | 127.2 MB | 216.4 MB | smaller species-specialized option |
| `bioclip2` | ViT-L/14 | best (species FM) | best — knows the tree of life | ~300 MB int8 (heavy) | 308.3 MB | 247.6 MB | 555.9 MB | +18% zero-shot species over BioCLIP; NeurIPS'25 spotlight |
| `bioclip25_vith14` | ViT-H/14 | best (species FM, larger) | best | ~630 MB int8 | 638.0 MB | 708.7 MB | 1346.7 MB | ViT-H BioCLIP 2.5 — well over budget |
| `siglip2_b16` | ViT-B/16 | good (general) | good | | 95.8 MB | 564.8 MB | 660.6 MB | DINOv2 beats it on fine-grained |
| `mobileclip2_s2` | hybrid | decent (general) | good | ~36 MB int8 (S2) | 122.2 MB | 127.1 MB | 249.2 MB | fast/small but not species-tuned |

Caveats — where **estimated ≠ actual**:
- `dinov2_small`: the ~22 MB estimate assumed int8, but the script exports **fp32**
  (no `_quantize`) → 88 MB. Quantizing closes the gap and makes it the smallest by far.
- `mobileclip2_s2`: the ~12–36 MB family figures are the small variants under full
  int8; our S2 export is conv-heavy and MatMul-only dynamic quant leaves the Convs
  fp32 → 122 MB.
- `talk2dino`: the early plan figure (~12–22 MB) was written as "DINO"/"DINOclip"
  — a generic small int8 image encoder assuming the small backbone; the chosen
  DINOv2 **ViT-B/14-reg** backbone is actually ~92 MB (the family was later pegged
  at ~20–90 MB quantized).
- `bioclip`, `bioclip2` landed within ~1–10 MB of estimate; `bioclip25_vith14`
  (~638 MB) ~blows the ~0.7 GB budget on its own.

## Performance — species retrieval

Image↔image nearest-centroid, **64 species · 332 images**, leave-one-out (flat
prototypes). Talk2DINO is the current baseline (from
[05b](05b_implementation-species-retrieval.md)).

| Model | rank-1 | rank-5 | MRR | visual_group | OOD AUROC | combined rank-1 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `talk2dino` *(current)* | 80.4% | 96.4% | 0.875 | ~96% | 0.805 † | 35.5% |
| `dinov2_small` | 79.2% | 95.5% | 0.868 | 95.8% | **0.814** | n/a (image-only) |
| `bioclip` | 78.9% | 94.6% | 0.861 | 95.8% | 0.767 | 29.2% |
| `bioclip2` | 87.3% | 98.2% | 0.926 | 98.5% | 0.888 | 35.8% |
| `bioclip25_vith14` | **93.1%** | **98.8%** | **0.957** | 98.5% | **0.909** | **44.6%** |
| `siglip2_b16` | 69.9% | 92.8% | 0.803 | 94.6% | 0.753 | 45.5% |
| `mobileclip2_s2` | 70.8% | 92.8% | 0.807 | 92.8% | 0.727 | 42.8% |

- `rank-1/5/MRR/visual_group/AUROC` = species-prototype retrieval (image↔image,
  the comparison's core metric). `combined rank-1` = the full app pipeline (text
  traits + `visual_group` → FTS5/Dice rerank). Talk2DINO's value is from its
  `README_combined_vision.md` (the base script writes no summary JSON);
  `dinov2_small` has no text encoder so combined is n/a.
- **Combined ≠ species-prototype ranking.** Note the inversion: `siglip2_b16`
  (45.5%) and `mobileclip2_s2` (42.8%) *beat* `bioclip` (29.2%) on combined despite
  *losing* on species prototypes (69.9/70.8% vs 78.9%). The combined path leans on
  the text-trait + `visual_group` FTS5 match, where the general CLIP models align
  the controlled-vocab attributes better — but the whole path tops out ~45% vs
  ~80–93% for image prototypes, reinforcing that **image-prototype ID is the
  metric to optimize, not the text-trait combined path.**
- † Talk2DINO AUROC is raw max-cosine (0.805) for apples-to-apples; its tuned
  `max − group median` scorer reached 0.824.
- **Ladder by backbone size:** bioclip25 (ViT-H) > bioclip2 (ViT-L) > talk2dino ≈
  dinov2_small ≈ bioclip (ViT-B/S) > mobileclip2 ≈ siglip2. Reading it against the
  size table:
  - `dinov2_small` is the surprise: **~88 MB fp32 (~22 MB if int8), no text encoder**,
    yet it matches Talk2DINO on rank-1 (79.2%) and posts the **best OOD AUROC of the
    small models (0.814)** — pure image↔image is its strength. Trade-off: zero-shot
    naming must come entirely from the LLM (no text tower).
  - `bioclip` (~89 MB) ≈ Talk2DINO accuracy at the **same size class**, but with a
    clean export and a usable text encoder for zero-shot naming — a drop-in upgrade.
  - `bioclip2` (~308 MB) buys **+7 pts rank-1** and a big AUROC jump (0.81→0.89)
    for ~3× the image-encoder size.
  - `bioclip25_vith14` leads every metric (93.1%) but ~638 MB is over budget.
  - `siglip2_b16` is the weakest fine-grained option (69.9%, ≈ mobileclip2) — as
    expected, DINOv2/BioCLIP beat it on species, and its text tower is huge (565 MB).

## Image-only option (drop the text encoder)

The species/`visual_group`/OOD numbers above are **already image-only for every
model** — species-prototype retrieval is image↔image (embed photo → nearest
centroid); the text encoder never participates. `dinov2_small` just makes it
literal by having no text tower, but bioclip2's 87.3%, bioclip25's 93.1%, etc. are
all pure image-encoder results too. So we can **ship the image encoder alone for
any backbone** and this pipeline is unchanged.

What dropping the text encoder costs:
- **`check_visual_evidence`** — the verify tool embeds arbitrary *claim text* to
  score against the image; this is the one runtime feature that needs the text encoder.
- **Open-vocabulary zero-shot naming** — matching a photo directly to an arbitrary
  *species-name string* (BioCLIP's headline strength). Without it, naming of
  unknown/open-world species falls entirely to the LLM (the Tier-2 path in 05b).
- The legacy **text-trait attribute matching** — but that's the weak `combined`
  path (29–44%) we're already moving away from in favor of prototypes.

Implications:
- **Footprint = the `actual image` column, not `actual total`.** Image-only makes
  `dinov2_small` (~22 MB int8) and `bioclip` (~89 MB) very attractive and removes
  `siglip2_b16`'s 565 MB text-tower problem entirely.
- **It pushes toward the stronger metric, not a compromise** — leaning on species
  prototypes (~80% rank-1) instead of the text-trait `combined` path (~35%, the
  bottleneck anyway).

Net: if we commit to the **prototype-retrieval + LLM-naming** architecture,
image-only is the right call for *any* of these backbones; the text encoder is
optional and only earns its size if we keep `check_visual_evidence` or CLIP-style
open-vocab naming.

## Proposed architecture — image match + traits as evidence

This folds verification into the image-only design and removes the runtime text
encoder entirely. The shift is **demoting traits from *matcher* to *evidence*.**

- **Identification = image↔species prototype** (the strong 80–93% signal). That is
  the answer, not the trait→FTS5 path.
- **`extract_visual_features` = supporting evidence**, used two ways, both
  text-encoder-free at runtime:
  1. **Agreement / confidence check** (this replaces `check_visual_evidence`):
     compare the image-extracted traits to the *matched species' DB record* —
     `visual_group` agrees? color/body_shape consistent? High agreement → confident;
     disagreement → lower confidence, retry, or route to OOD. Verification by
     trait↔DB overlap instead of runtime text↔image scoring.
  2. **Narration**: the LLM explains the ID from the extracted traits ("elongated,
     scaled, green → consistent with *X*").

Why the demotion matters: today the FTS5-trait path *is* the matcher (29–44%), so
its weakness caps accuracy. As evidence, the weak descriptive traits (color/texture)
no longer have to discriminate species — they just corroborate a match the strong
image prototype already made, and `visual_group` (95.8%, the one reliable trait)
becomes a solid cross-check / hierarchical prior.

Resulting runtime (no text encoder):

```
image ─► species prototype ─► top-K species   (primary ID)
        └─ max-cosine < τ ? ─► OUT-OF-DISTRIBUTION ─► Tier-2 (visual_group + LLM world knowledge)
extract_visual_features (precomputed embeddings) ─► traits
        ├─ agreement vs matched species' DB record  → confidence / verify
        └─ LLM narration
```

This is the 05b tiered design with verification folded in and the text encoder
removed. Backbone nuance: text-equipped backbones (bioclip, talk2dino) precompute
`attribute_embeddings.json` offline and still drop the *runtime* text encoder;
`dinov2_small` has no text at all, so its evidence is just `species + visual_group`
(both image-prototype based) — a bit thinner, but the primary ID is unaffected.

## Conformance check — does this satisfy 00_plan §2? ⚠️ **No (as proposed)**

The proposal above optimizes accuracy/size but **fails the §2 constraints**. Logging
this honestly so the trade-off is a deliberate decision, not a quiet drift.

- **Obj 1 — no data dependency → VIOLATED by *species* prototypes.** The plan chose
  DINO precisely because "frozen/self-supervised → no per-species data"
  ([00_plan §3.2](00_plan.md), :75, :81). A species prototype *is* per-species data
  (4–8 example images → centroid). Not a *trained* classifier, but a **reference-image
  dataset**, which the plan explicitly rejects: "no reference images or image
  embeddings… avoids any reference-image dataset (which would reintroduce the
  data-dependency the writeup rejects)" ([00_plan §3](00_plan.md), :59).
- **Obj 2 — scale by JSON rows, no images → VIOLATED.** "adding a species needs only
  DB text" (:75); "new species = add DB rows" (:181). Species prototypes need example
  **images** per new species. Direct conflict.
- **Obj 3 — model is the reasoning core → soft tension.** Making image-prototype the
  *primary ID* nudges the LLM toward consuming a classifier verdict; the plan wants
  vision as a trait-describer feeding LLM reasoning. The LLM still narrates/handles
  OOD, so it's drift, not a hard break.

Two distinctions that matter:
- **`visual_group` prototypes (already shipped) DO conform** — per-broad-group
  (~31 fixed enums), so a new species maps to an existing group with **no new images**.
  Only **species** prototypes cross the line.
- **Dropping the runtime text encoder conflicts with §10** — the plan leans on
  `check_visual_evidence` (runtime text encoder) as the **open-world coverage**
  mechanism for species beyond the curated DB (:178, :181). Removing it deletes the
  §2 escape hatch.

**Implication — the check flips the recommendation:**
- The 80–93% prototype rank-1 measures a mechanism the plan **disallows**.
- The constraint-*compliant* accuracy lever is **zero-shot text↔image species naming**
  (image vs species-name/description text from the DB — BioCLIP's headline strength):
  new species = new text, no images, frozen encoder → satisfies all three. But it
  **needs the text encoder**, so "drop the text encoder" is also against the grain.
- We never measured that conformant metric — our numbers are prototype retrieval
  (disallowed) and trait→FTS5 (the weak conformant `combined`, 29–44%). BioCLIP
  zero-shot naming would likely land between.

**Fork (deliberate decision required):**
- **(a) Stay conformant** — drop species prototypes; measure + pursue zero-shot
  text↔image species naming (BioCLIP), keep the text encoder. Comparison gains a
  "zero-shot species rank-1" column.
- **(b) Amend the constraint** — accept that *few-shot, training-free* prototypes
  (no backprop, **optional** enhancement over a text baseline that still scales by
  JSON) are a tolerable relaxation, and rewrite the §2 principle in 00_plan to say so.
  System still scales by text for species without images; prototypes only boost those
  that have images.

## Will do

- Re-run the canonical scripts per chosen backbone when comparison numbers are
  needed.
- Keep the artifact naming consistent across exports, eval summaries, and the
  Flutter runtime.
