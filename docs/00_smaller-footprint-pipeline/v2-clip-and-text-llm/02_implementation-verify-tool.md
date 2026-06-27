# 02 · Implementation — verify tool (`check_visual_evidence`)

**Status:** ✅ done · **Owns:** `lib/services/clip_tokenizer.dart`, the text-encoder path in `vision_runtime.dart`, the v2 export in `export_vision_model.py`
**Produces:** `assets/models/text_encoder_talk2dino.onnx`, `clip_vocab_talk2dino.json`, `clip_merges_talk2dino.txt`

v1 ([stage 01](01_implementation-vision-export.md)) only `extract`s attributes.
The retry loop also wants `check_visual_evidence` — scoring **free-text claims**
against the photo. Unlike the attribute path (labels precomputed offline),
arbitrary claims must be embedded **at runtime**, which needs the text encoder
*and* a tokenizer on-device.

## What we added
- **`text_encoder_talk2dino.onnx`** (~129 MB fp16) — exported wrapper around CLIP text + `project_clip_txt` (the same path as the attribute embeddings, tokenisation lifted out). Input `token_ids` int32 `[1,77]` → 768-d L2-norm in DINO space. CLIP loads fp16; we cast to fp32 before export so the text encoder and the precomputed attribute embeddings stay numerically consistent.
- **`clip_tokenizer.dart`** — a faithful Dart port of CLIP's byte-level BPE (`SimpleTokenizer` + `clip.tokenize`), driven by two dumped assets (`clip_vocab_talk2dino.json`, `clip_merges_talk2dino.txt`). `check_visual_evidence` tokenises each claim → text encoder → cosine vs the cached image embedding.
- **Wiring** — `VisionRuntime.checkVisualEvidence`, plus `ModelService` registers the tool **only when `canVerify`** (text encoder loaded), so the prompt never advertises a tool the runtime can't back. If the text encoder fails to load, the runtime degrades to v1 cleanly.

## Challenge — on-device tokenisation must be exact
The text encoder is useless without the *exact* CLIP token IDs; a mismatch
silently produces garbage embeddings. Re-implementing byte-level BPE (byte↔unicode
table, the pre-tokenisation regex, rank-ordered merges, 77-length SOT/EOT padding)
in Dart is the error-prone part.

**Solution + validation.** Mirrored the Dart algorithm in Python and diffed it
against real `clip.tokenize` — **9/9 test strings exact** (punctuation, digits,
hyphenated words included). The check lives in `validate_vision_model.py`.

## Challenge — scores aren't a clean 0–1
Cosine in the aligned space is small (good matches ~0.15–0.35, wrong ones
~−0.05–0.03), so a fixed 0–1 threshold misleads.

**Solution.** Return the raw similarity and frame it as **relative** in the tool
description; the prompt's VERIFY step tells the model to include a deliberately-
wrong **control claim** and compare against it, not a fixed cutoff.

## Validation (tiger / panda)
Text-encoder ONNX↔torch parity mean 0.962; claim scoring is correctly
discriminative — tiger "a large striped cat" **+0.34** ≫ "an aquatic fish" +0.02;
panda "a bear-like body" **+0.29** ≫ "green leafy plant" **−0.02**.

## Notes
- `flutter_onnxruntime` maps `Int32List` → an int32 tensor (matches `token_ids`).
- The text encoder also enables the **open-vocabulary coverage** argument in
  [plan §10](00_plan.md#10-coverage-beyond-the-curated-db-answering-constraint-2):
  arbitrary claims aren't limited to the DB-derived label set.
- Precision choice (fp16 vs int8 for the text encoder) →
  [03_implementation-quantization.md](03_implementation-quantization.md).
