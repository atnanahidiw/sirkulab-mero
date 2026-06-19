# Smaller-footprint on-device species ID — Qwen3 reasoning core + DINO vision tool

**Why this exists:** shrink Mero's on-device footprint from **2.58 GB → ~0.7 GB**
without losing the generative reasoning core. We replace the single multimodal
model (Gemma 4 E2B) with a **split pipeline**: a small **text-only reasoning LLM
(Qwen3-0.6B)** that orchestrates a **DINO vision tool (Talk2DINO via ONNX)** and a
**curated SQLite DB** — so the model stays the reasoning core while vision becomes
a callable, scored tool.

```
[photo] → extract_visual_features (DINO)  → trait text
        → search_similar_features (FTS5)  → ranked species
        → check_visual_evidence  (DINO)   → per-claim scores (retry/verify)
   Qwen3-0.6B orchestrates the tools · SQLite DB = ground truth
```

## How these docs are organized

- **[00_plan.md](00_plan.md)** — the design & decision (stable): constraints,
  architecture, tool schemas, sizes/trade-offs, component shape, coverage. Read
  this first.
- **`0n_implementation-*.md`** — one file per build stage. Each is a living log:
  append "tried A → failed → tried B" as approaches are retried.

| Stage | Status | What it covers |
| --- | --- | --- |
| [01 — vision export](01_implementation-vision-export.md) | ✅ done | Talk2DINO → ONNX, CLS-saliency pooling, attribute vocab, `distinctive_marks` |
| [02 — verify tool](02_implementation-verify-tool.md) | ✅ done | v2 `check_visual_evidence`: runtime text encoder + Dart CLIP tokenizer |
| [03 — quantization](03_implementation-quantization.md) | ✅ done | on-device int8/fp16 (ConvInteger → fp16 → MatMul-only int8) |
| [04 — tool calling](04_implementation-tool-calling.md) | 🔧 in progress | agentic loop: native vs custom, thinking mode, tool ordering, runtime bugs |
| [05 — accuracy tuning](05_implementation-accuracy-tuning.md) | 🔬 open | trait mislabels: prompt templates, prompt fusion, few-shot prototypes, Gemma-4 distillation |

## Current state (top of mind)

- Pipeline runs end-to-end on-device: Qwen3 calls `extract_visual_features` →
  DINO returns traits → search → synthesis.
- **Open problem:** zero-shot trait accuracy. We improved `visual_group`
  materially with prompt templating and then prototypes, but the descriptive
  traits are still weak and repetitive across species. Being worked in
  **stage 05** (`scripts/debug_vision.py`, `scripts/eval_combined_vision.py`).

## Code & tooling pointers
- Runtime: `lib/services/vision_runtime.dart`, `clip_tokenizer.dart`,
  `model_runtime.dart`, `model_service.dart`; prompts in `lib/models/chat_prompts.dart`.
- Offline tools: `scripts/` (`export_vision_model.py`, `validate_vision_model.py`,
  `debug_vision.py`, `compare_pooling.py` — see `scripts/README.md`).
