# 05 · Implementation — trait accuracy tuning

**Status:** 🔧 in progress — `visual_group` templated (+10 pts) and replaced by image **prototypes** (+39 pts LOO); descriptive attributes still weak · **Owns:** `scripts/{debug_vision,eval_vision,build_prototypes,eval_combined_vision}.py`, `export_embeddings`, the prototype path in `vision_runtime.dart`
**Problem:** zero-shot traits are sometimes *class-level* wrong — e.g. a **lizard**
scored `visual_group = "Mollusk & marine invertebrate"`, with several other traits
off too.

This is the most important remaining quality gap. It is a **vision** problem
(image↔label matching), distinct from the tool-calling work in
[stage 04](04_implementation-tool-calling.md).

## Why it happens
The shipped pipeline matches the DINO **image** embedding against **label *text***
(Talk2DINO-projected). That image↔text path is the *weakest* part: in the harness,
"Lizard" scores 0.14–0.15 even for a *tiger*. DINOv2's actual strength is
**image↔image** similarity; we're using its weaker text-alignment for the hardest
field (`visual_group`). Contributing factors:
- **Raw category labels** ("Lizard") are poor CLIP-style queries vs templated text
  ("a photo of a lizard").
- The **single-vector saliency approximation** (stage 01) drops Talk2DINO's
  attention pooling, costing fine-grained discrimination.

## The harness: `scripts/debug_vision.py`
Runs the **exact shipped pipeline** on one photo and prints ranked predictions, so
fixes can be tried **without rebuilding the app**:
```bash
.venv-export/bin/python scripts/debug_vision.py --image lizard.jpg --compare-templates
.venv-export/bin/python scripts/debug_vision.py --image lizard.jpg --attrs visual_group,color --topk 8
.venv-export/bin/python scripts/debug_vision.py --image lizard.jpg --probe "a lizard|a sea slug|a reptile with scales"
```

## Eval harness + dataset (`scripts/eval_vision.py`)
`debug_vision.py` judges one photo; to choose a fix we need **numbers across many
photos**. The sibling **`sirkulab-mero-data`** repo has ~467 labeled species
images (`data/raw/species_data_img/`, organised by taxonomy). `eval_vision.py`
(in this repo, referencing the data repo by a **relative** path):
- derives ground-truth `visual_group` per image — exact **join to the app DB** by
  latin/common name (the folders nest down to species), with an unambiguous
  taxonomic-class fallback;
- runs the shipped pipeline under each prompt template;
- writes per-image results → `sirkulab-mero-data/data/processed/vision_eval_visual_group.jsonl`
  (+ a generated `README.md` note) and prints per-template accuracy.

```bash
.venv-export/bin/python scripts/eval_vision.py            # ~340 deduped images, ~6 min CPU
```

## Combined eval harness (`scripts/eval_combined_vision.py`)
`eval_vision.py` measures only the `visual_group` label-text path. Once the
prototype asset exists, the useful question becomes: **how does the shipped
vision output behave when `visual_group` comes from prototypes and the other
traits still come from text embeddings?**

`eval_combined_vision.py` does that. It:
- loads the same Talk2DINO image encoder;
- uses `dino_attribute_embeddings.json` for `color`, `body_shape`,
  `distinctive_marks`, `texture`, `size_class`, `pattern`;
- uses `visual_group_prototypes.pb` for `visual_group`;
- compares the combined output against the text-only `visual_group` baseline;
- reports per-attribute accuracy plus exact-match accuracy across all 7 traits.

```bash
.venv-export/bin/python scripts/eval_combined_vision.py
```

## Prompt-fusion experiments on the exporter
After the prototype work, we revisited the `dino_attribute_embeddings.json`
export path to see whether the label-text side could recover more variation
before the model ever reaches SQLite. We tried three fusion strategies over a
small prompt ensemble:

- `mean` over prompt embeddings
- `medoid` prompt selection
- `max` prompt selection

The prompt sets used were:

- `visual_group`: `{}`, `a photo of a {}`, `a close-up photo of a {}`, `an image of a {}`, `a field guide photo of a {}`
- descriptive traits: `{}`, `trait: {}`, `appearance: {}`

Observed results on the full 332-image combined eval:

| fusion | rank-1 | rank-5 | MRR | note |
| --- | --- | --- | --- | --- |
| **mean** | **36.7%** | **76.5%** | **0.543** | best of the three |
| medoid | 35.5% | 75.6% | 0.537 | slightly worse |
| max | 35.5% | 75.6% | 0.537 | essentially tied with medoid |

Conclusion:
- Prompt ensembling helps a bit, but the gain is small compared with the
prototype jump on `visual_group`.
- `mean` was the best fusion rule for this prompt set.
- The remaining errors are not just a fusion problem; the trait schema itself is
still too coarse / repetitive across species.
- If we revisit this layer again, the next useful step is probably attribute-
specific prompt sets or storing multiple embeddings per label and scoring them
at inference, rather than trying more global fusion metrics.

## Results — `visual_group` template sweep (332 ground-truthed images)
| template | accuracy |
| --- | --- |
| **`"a close-up photo of a {}"`** | **69.9%** (232/332) ← winner |
| `"this is a {}"` | 62.3% |
| `"{}"` (raw — what shipped) | 59.6% |
| `"an image of a {}"` | 57.5% |
| `"a photo of a {}"` | 56.6% |
| `"a photo of {}"` | 56.0% |

Two lessons:
1. **`"a close-up photo of a {}"` gives +10.3 points** over raw labels — a free win
   on the worst attribute (no Dart change; only the precomputed embeddings change).
2. **Measuring mattered.** A single-image `debug_vision` run on a Komodo dragon had
   pointed at `"a photo of a {}"` — which the full set shows is *worse than raw*
   (56.6% < 59.6%). Only "close-up" and "this is a" beat raw. One image overfits.

## Fix applied — template `visual_group` only (per-attribute)
Templating helps **category** labels ("Lizard" → "a close-up photo of a lizard")
but would **break descriptive** ones (`color: "yellow and black stripes"` →
"a close-up photo of a yellow and black stripes"). So the exporter now applies a
**per-attribute** prompt ensemble (`ATTR_PROMPT_ENSEMBLES` in `export_vision_model.py`):
`visual_group` → `"a close-up photo of a {}"`; every other attribute stays raw
(`"{}"`). Re-export regenerates `dino_attribute_embeddings.json` only — the image
and text encoders are unchanged, and the Dart runtime needs no change.

Still ~30% wrong on `visual_group` even after the fix → the durable improvement is
image prototypes (next). But the template ships the easy +10 first.

## Prototypes — `visual_group` via image↔image (option C, shipped)
The text template plateaued; the real fix plays to DINOv2's **image↔image**
strength. `scripts/build_prototypes.py` builds **one frozen prototype vector per
`visual_group`** by aggregating the DINO embeddings of that group's labeled images
(from `sirkulab-mero-data`), and ships it as a protobuf asset
(`assets/models/visual_group_prototypes.pb`, schema `*.proto`). At runtime,
`vision_runtime.dart` scores the photo against the **prototypes** for
`visual_group` and against text labels for the other six attributes — so
`extract_visual_features` is now a hybrid (image-prototype + text-label) matcher.
No backprop; the DINO encoders are unchanged.

**Honest evaluation (leave-one-out CV).** First-pass accuracy was measured on the
same images used to build the prototypes (resubstitution) — optimistic. The script
now does **leave-one-out**: rebuild each image's group prototype *without* it, then
predict. It also auto-selects the aggregation strategy by **LOO** (not resub), so
it picks what *generalizes*, not what memorizes.

| strategy | LOO-CV (honest) | resub (optimistic) |
| --- | --- | --- |
| **`trimmed_80`** ← selected | **96.1%** | 96.7% |
| `trimmed_90` | 95.8% | 96.4% |
| `mean` | 95.5% | 97.3% |
| `topk_5` | 90.7% | 91.9% |
| `medoid` | 86.4% | 87.7% |

So the leakage was tiny (−0.6 pts) — the prototypes genuinely generalize. Net
`visual_group`: **56.9% (text) → 96.1% (prototype, LOO)** — **+39 points**.

**End-to-end (`scripts/eval_combined_vision.py`).** Beyond `visual_group`, this
runs the *full* shipped retrieval (predicted traits → FTS5 + Dice + taxonomy →
ranked species) for the prototype-hybrid vs the text-only baseline, over the same
332 images. The better `visual_group` filter roughly **doubles** species retrieval:

| metric | text baseline | **prototype hybrid** |
| --- | --- | --- |
| retrieval rank-1 | 19.6% | **35.5%** |
| retrieval rank-5 | 40.4% | **75.3%** |
| MRR | 0.295 | **0.535** |

(Retrieval is resubstitution-flavoured too, but the prototype's LOO leakage is
small, so the lift is real. The descriptive attributes' *exact-match* accuracy
stays low — the DB strings are specific — but retrieval uses Dice token overlap,
which is what actually matters.)

## Candidate fixes (cheapest → heaviest)

### A. Prompt templating ✅ *(done — +10.3 pts on `visual_group`)*
Embed category labels with `"a close-up photo of a {}"` (measured winner above).
Applied per-attribute in `export_vision_model.py` (`visual_group` only; descriptive
attributes stay raw). No app/Dart change.

### A1. Prompt ensembles / fusion *(tested, small gain)*
Tried a 3-template descriptive ensemble and a 5-template `visual_group`
ensemble, then compared `mean`, `medoid`, and `max` fusion in the exporter.
`mean` won on the current data. This is now documented as an experiment result,
not the preferred direction.

### B. Better label wording *(cheap)*
Some `visual_group` names are weak queries. `--probe` tests richer wordings
(e.g. "a reptile with scales and four legs" vs "Lizard") before changing the DB.

### C. Few-shot image prototypes ✅ *(done — `visual_group` 56.9% → 96.1% LOO)*
Built, cross-validated, and shipped (see "Prototypes" section above):
`build_prototypes.py` → `visual_group_prototypes.pb`, wired into
`vision_runtime.dart`. Trade-off accepted: a small reference-image dependency
(per *group*, not per *species* — far smaller than the writeup's rejected
per-species data ask). Only `visual_group` uses prototypes today; the other six
attributes could get the same treatment next if their accuracy proves limiting.

### D. Fine-tune the projection head *(real training, last resort)*
Use Gemma-4-labeled `(photo, traits)` pairs to fine-tune **only** the small
Talk2DINO projection MLP (never the DINOv2 backbone). Reintroduces a training
dependency; teacher quality (Gemma 4 E2B is itself a noisy 2B VLM) caps the result.

## On "use Gemma 4 to label photos, then retrain DINO"
Feasible (knowledge distillation), but:
- You would **not** retrain DINOv2 (the backbone) — only a probe / the projection
  head, or build prototypes (C, no training).
- It **relaxes writeup constraint §2** (no-data / no-retraining). Acceptable for a
  "beyond-hackathon" direction, but a real architectural shift — go in eyes open.
- **Gemma 4 E2B is a noisy teacher**; hand-verify a sample, or use a stronger VLM
  for the offline labeling step to raise the ceiling.

## Recommended order
1. ✅ **A (templates)** — measured (`eval_vision.py`) and applied (+10.3 pts).
2. ✅ **Eval set** — `eval_vision.py` over `sirkulab-mero-data` (constraint-safe:
   data for *measurement*, not training).
3. ✅ **C (few-shot prototypes)** for `visual_group` — built, LOO-cross-validated,
   shipped (+39 pts; near-doubles species retrieval).
4. **Next — descriptive attributes.** `color`/`texture`/… are still weak. Options:
   prototypes for them too (per attribute-value), or richer DB label wording (B).
5. **D (fine-tune projection)** only if the above aren't enough.

## Scripts
- `eval_vision.py` ✅ — per-template `visual_group` accuracy vs the labeled set.
- `debug_vision.py` ✅ — single-photo ranked predictions (interactive).
- `build_prototypes.py` ✅ — per-`visual_group` frozen image prototypes (multi-
  strategy, **leave-one-out** selection) → protobuf asset (option C).
- `eval_combined_vision.py` ✅ — full hybrid pipeline → FTS5/Dice retrieval
  rank-1/5/MRR vs the text-only baseline.
- `label_with_teacher.py` — *(not built; a Gemma labeler already exists in `sirkulab-mero-data/notebooks/gemma_visual_features.py`)*.
