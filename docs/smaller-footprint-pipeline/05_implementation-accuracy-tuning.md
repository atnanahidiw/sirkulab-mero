# 05 · Implementation — trait accuracy tuning

**Status:** 🔧 in progress — first fix (template the `visual_group` labels) measured & applied · **Owns:** `scripts/debug_vision.py`, `scripts/eval_vision.py`, the `export_embeddings` path
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
**per-attribute** template (`ATTR_TEMPLATES` in `export_vision_model.py`):
`visual_group` → `"a close-up photo of a {}"`; every other attribute stays raw
(`"{}"`). Re-export regenerates `dino_attribute_embeddings.json` only — the image
and text encoders are unchanged, and the Dart runtime needs no change.

Still ~30% wrong on `visual_group` even after the fix → the durable improvement is
image prototypes (option C below). But the template ships the easy +10 first.

## Candidate fixes (cheapest → heaviest)

### A. Prompt templating ✅ *(done — +10.3 pts on `visual_group`)*
Embed category labels with `"a close-up photo of a {}"` (measured winner above).
Applied per-attribute in `export_vision_model.py` (`visual_group` only; descriptive
attributes stay raw). No app/Dart change.

### B. Better label wording *(cheap)*
Some `visual_group` names are weak queries. `--probe` tests richer wordings
(e.g. "a reptile with scales and four legs" vs "Lizard") before changing the DB.

### C. Few-shot image prototypes *(no training, biggest gain)*
Play to DINOv2's image↔image strength: for each `visual_group` (~31 of them),
average the DINO embeddings of a handful of labeled example photos → a *prototype*
vector; at runtime match the photo to the nearest prototype. **No backprop.**
Sidesteps the weak text path entirely. Trade-off: reintroduces a small
reference-image dependency (per *group*, not per *species* — far smaller than the
writeup's rejected per-species data ask).

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
3. **C (few-shot prototypes)** for the weak attributes — next; `visual_group` is
   still ~30% wrong, and image↔image prototypes should beat the text path.
4. **D (fine-tune projection)** only if 1–3 aren't enough.

## Scripts
- `eval_vision.py` ✅ — per-template accuracy vs the labeled set (option 2).
- `debug_vision.py` ✅ — single-photo ranked predictions (interactive).
- `build_prototypes.py` — *(not built)* average DINO embeddings per attribute value → prototype vectors (option C).
- `label_with_teacher.py` — *(not built; a Gemma labeler already exists in `sirkulab-mero-data/notebooks/gemma_visual_features.py`)*.
