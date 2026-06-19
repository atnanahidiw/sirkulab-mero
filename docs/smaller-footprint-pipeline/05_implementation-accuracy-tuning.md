# 05 · Implementation — trait accuracy tuning

**Status:** 🔬 open (active frontier) · **Owns:** `scripts/debug_vision.py`, the `export_embeddings` path, attribute vocab
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

## Candidate fixes (cheapest → heaviest)

### A. Prompt templating *(free, try first)*
Embed labels as `"a photo of a {label}"` instead of raw text. On the tiger demo,
`"a close-up photo of a {}"` widened the correct margin (0.177 vs 0.155 raw) and
pushed confusers down. **If a template wins on the lizard:** apply it in
`export_vision_model.py:export_embeddings` (`template.format(lbl)`) and re-export —
no app/Dart change.

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
1. **A (templates)** via `debug_vision.py` on the actual failing photos — may fix
   the coarse `visual_group` error alone.
2. Use a labeled photo set as an **eval set** (data for *measurement*, not
   training — constraint-safe) to pick the best template/pooling/wording.
3. **C (few-shot prototypes)** for the weak attributes if zero-shot plateaus.
4. **D (fine-tune projection)** only if 1–3 aren't enough.

## Possible scripts (not yet built)
- `build_prototypes.py` — average DINO embeddings per attribute value → prototype vectors (option C).
- `label_with_teacher.py` — run a VLM over a photo folder → `(image, traits)` JSON.
- `eval_vision.py` — score zero-shot/prototype configs against a labeled set (option 2).
