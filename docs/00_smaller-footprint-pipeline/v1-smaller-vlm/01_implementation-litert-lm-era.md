# 01 · Implementation log · Era A: LiteRT-LM (keep the proven Gemma runtime)

**Status:** 🔴 open log · currently exhausted, reopen by appending below.
**Owns (at the time):** `model_service.dart`, `model_runtime.dart`, `android/app/src/main/kotlin/com/sirkulab/mero/SmolVlmNativePlugin.kt`, `lib/services/smolvlm_plugin.dart`
**Theme:** keep the model on the same runtime family as Gemma (LiteRT / LiteRT-LM through `flutter_gemma`) and only swap the model file.

**How to use this doc.** It is a running log, not a post-mortem. Each attempt is a dated entry under **Log**, newest at the bottom. When a new result changes the picture, append an entry and update **Where this stands**. Things that could produce the next entry live under **Open threads**. Verbatim log lines and commits are in [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md); the earliest entries below are reconstructed from the committed post-mortem at `9187c7d` (branches `feature/eagle-bck` / `feature/eagagle-bck`).

---

## Where this stands (updated 2026-07-14)

Three model families on the LiteRT-LM path (FastVLM, SmolVLM, Qwen-LiteRT), across five integration runs: FastVLM twice (both `.litertlm`, 05-31 and 06-02), SmolVLM twice (v1 native TFLite, v2 `.litertlm`), and Qwen-LiteRT once. Each failed at a different point (native segfault mid-generation then mid-prefill for FastVLM, post-load signature/tensor/invoke for SmolVLM, unmet multimodal contract for Qwen). Working conclusion: on this runtime, across non-Gemma families, the **runtime contract was the binding constraint** (capability limits showed up later, in Era B). The search moved to GGUF/llama.cpp in [Era B](02_implementation-gguf-llamacpp-era.md). This log stays open in case a runtime change (see Open threads) makes a listed model worth retrying.

---

## Attempts ledger (Era A)

Verdict key: ❌ blocked. Full stacktraces and sources live in [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md); the dated prose entries are under **Log** below.

| # | Date | Model | Size | Format / runtime | Branch / commit | Wall hit | Verdict |
|---|---|---|---|---|---|---|---|
| 1 | 05-31 & 06-02 | FastVLM-0.5B (first model, tried twice) | 0.5B | `.litertlm` / FlutterLiteRtLm | feature/fastvlm-migration · 5be49f4, c0c2cfc, f295754 | engine initializes, then native `SIGSEGV` (`SEGV_ACCERR`): attempt 1 mid-generation (05-31), attempt 2 mid-prefill in `FillAttentionMask` (06-02) | ❌ |
| 2 | 05-31 → 06-01 | SmolVLM-256M v1 | 256M | `.tflite` + tokenizer / native Kotlin (TFLite) | feature/smaller-model · 53157e3, 86f489d | `Op builtin_code out of range: 206`; unsupported image tensor `[1,1,3,512,512]`; prefill/decode signature mismatch (KV-cache, no logits, `mask`); prompt over budget (1531 > 1280) | ❌ |
| 3 | 06-01 → 06-02 | SmolVLM-256M v2 | 256M | `.litertlm` / LiteRT-LM, Dart tokenizer | smaller-model-2 · 0f2b29b, b58c2cc, 4bd3b74 | file-routing conflict (EngineFactory vs Dart FFI); `Failed to invoke the compiled model` via `SmolVlmNativeEngine` (the `FillAttentionMask` prefill segfault belongs to FastVLM, row 1) | ❌ |
| 4 | ~06-02 | Qwen3.5-0.8B-LiteRT (GabrieleConte) | 0.8B | `.litertlm` / LiteRT-LM | working tree (not committed) | bad HF URL, then runtime failed the multimodal-vision contract | ❌ |

**Models tried (Era A):** SmolVLM-256M (https://huggingface.co/litert-community/SmolVLM-256M-Instruct), FastVLM-0.5B (https://huggingface.co/litert-community/FastVLM-0.5B), Qwen3.5-0.8B-LiteRT (https://huggingface.co/GabrieleConte/Qwen3.5-0.8B-LiteRT); runtime `flutter_gemma` (LiteRT-LM, https://pub.dev/packages/flutter_gemma), plus the `github.com/songhieu/flutter_litert_lm` plugin.

---

## Log (append newest at the bottom)

### 2026-05-31 → 06-01 · SmolVLM-256M v1, native TFLite plugin

**Model:** `litert-community/SmolVLM-256M-Instruct`, `.tflite` build `smalvlm-256m-instruct_q8_ekv2048_single_image.tflite` plus a separate `tokenizer.model`.
**Why chosen:** the next step down in size after FastVLM's GPU build came in over 1 GB. SmolVLM-256M-Instruct is the smallest verifiable multimodal option, a 256M-parameter VLM whose card claims a single image runs in under 1 GB of GPU RAM (openclaw Codex `2026/05/30/...17-23-42`).
**Integration:** native **Kotlin plugin** (`SmolVlmNativePlugin.kt`), Flutter to Android over a method channel; Android owns model load, tokenizer load (`SpTokenizer` from `ai.djl.sentencepiece`), image packing, inference. Classic TFLite contract: model plus tokenizer plus glue.

Symptom, diagnosis, fix, in order:

1. `Op builtin_code out of range: 206. Are you using old TFLite binary with newer model?` It died as a `java.lang.IllegalArgumentException` inside `org.tensorflow.lite.NativeInterpreterWrapper.createInterpreter` (a `Registration failed.` before any inference ran). The operator set was newer than the interpreter, so bump the Gradle TFLite artifact and make interpreter creation explicit.
2. `Unsupported image tensor shape: [1, 1, 3, 512, 512]`. Pixel packing did not match the expected layout, so rewrite preprocessing to the exact channel and dimension order.
3. Signature and generation contract mismatch:

   ```
   Prefill signature 'prefill_256_pixel' is missing logits output. Available outputs: [kv_cache_k_0, ...]
   SmolVLM prompt is too long for the available prefill signatures. Tokens=1531, max_supported=1280.
   Decode signature 'decode' did not return logits. Available outputs: [kv_cache_k_0, ...]
   Decode signature 'decode' has an unsupported input 'mask'.
   ```

   The model exposed KV-cache outputs while the app expected logits-style generation, and image tokens plus instructions blew the prefill budget (1531 > 1280). Fixes: trim the prompt, change output selection, adjust decode handling.
4. Tokenizer path bug: it downloaded into the Flutter documents directory while Android resolved from `filesDir`, so reconcile the paths.

**Result:** ❌ the runtime contract was not aligned with the native TFLite path. Small model, opinionated architecture.

### 2026-06-01 → 06-02 · SmolVLM-256M v2, LiteRT-LM packaging plus Dart tokenizer

**Model:** same repo, `smalvlm-256m-instruct_q8_ekv2048.tflite` (no `_single_image`, pinned rev), moving to the `.litertlm` bundle.
**Change:** the native tokenizer bridge moved to the **Dart side** (`resolveLocalTokenizerPath()` then `SentencePieceTokenizer.fromModelFile(...)`); Android deps moved off TensorFlow Lite to `com.google.ai.edge.litert:litert:2.1.0` (the point the app became a LiteRT app).

**Result:** ❌ cleaner package, same design mismatch. The runtime disagreed with itself about the load path (EngineFactory vs Dart FFI). Via the native `CompiledModel` (`SmolVlmNativeEngine`) the model could not be invoked at all:

```
06-02 00:49:59.179 21597 21597 I flutter : PlatformException(native_error, Failed to invoke the compiled model, com.google.ai.edge.litert.LiteRtException: Failed to invoke the compiled model
06-02 00:49:59.179 21597 21597 I flutter :  at com.google.ai.edge.litert.CompiledModel.run(Model.kt:446)
06-02 00:49:59.179 21597 21597 I flutter :  at com.sirkulab.mero.SmolVlmNativeEngine.runModel(SmolVlmNativePlugin.kt:394)
```

(The `06-02 15:07` `FillAttentionMask` prefill segfault on the `libLiteRtLm.so` path belongs to FastVLM's second attempt, next entry, not to SmolVLM v2.)

### 2026-05-31 and 06-02 · FastVLM-0.5B, preconverted `.litertlm` (the first model tried, twice)

Chronologically first (earliest mention 2026-05-30, ahead of SmolVLM), logged here out of order. Tried **twice**, both on the LiteRT-LM path: once at the very start, once again around the GGUF pivot after image preprocessing was reworked.
**Model:** `litert-community/FastVLM-0.5B` (preconverted; model from `github.com/apple/ml-fastvlm`).
**Why chosen:** the smallest verifiable multimodal `.litertlm` model, so the swap stays on Gemma's LiteRT runtime. No Google-official model fit (Gemma 3n E2B's standard int4 LiteRT-LM bundle is ~3.7 GB, nothing first-party near ~500 MB); FastVLM-0.5B is ~899 MB NPU / ~1.1 GB GPU, about half of Gemma, its only caveat being community-converted rather than Google-branded.
**Integration:** `flutter_gemma` LiteRT-LM FFI (`ModelType.general`); runtime switch `FlutterGemmaModelRuntime` → `FlutterLiteRtLmModelRuntime` in `c0c2cfc`. Needed model-specific image preprocessing and file-backed image input (`f295754`, "implement FastVLM image preprocessing").

**First attempt (05-31).** The engine initialized and began generating, then segfaulted mid-generation on the native `engine` thread. Not "could not create an engine": it created one and crashed during generation.

```
05-31 03:17:44 I/flutter (16258): ✅ Set active inference model: donotdelete_FastVLM-0.5B
05-31 03:26:54 I/flutter (21151): InferenceChat: Starting to iterate over native tokens...
05-31 03:27:04 F/libc    (21151): Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb400007313b4c000 in tid 22170 (engine/22170), pid 21151 (m.sirkulab.mero)
```

**Second attempt (06-02).** Reloaded on the same `libLiteRtLm.so` FFI path after preprocessing was reworked; this time it segfaulted earlier, during prefill, inside `FillAttentionMask`. Same class of uncatchable native crash, different spot in the pipeline.

```
06-02 15:06:59 E/litert: Failed to initialize Dispatch API
06-02 15:07:02 F/libc : Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb4000073f40ed000 in tid 30407 (engine/30407) [libLiteRtLm.so litert::lm::FillAttentionMask → PrefillInternal]
```

**Result:** ❌ two attempts, two native segfaults on the LiteRT-LM engine, once mid-generation and once mid-prefill.

### ~2026-06-02 · Qwen3.5-0.8B-LiteRT, the last LiteRT attempt

**Model:** `GabrieleConte/Qwen3.5-0.8B-LiteRT` (preconverted `.litertlm` multimodal bundle). Working-tree only, never committed to `model_service.dart`.
**Sequence:** the wrong model URL in config was caught and corrected (a sign the LiteRT ecosystem around non-Gemma models is unpolished); even with the correct URL the runtime failed the app's multimodal-vision contract.

**Result:** ❌ it confirmed the pattern rather than fixing it. This ended the LiteRT era and the search moved to GGUF ([Era B](02_implementation-gguf-llamacpp-era.md)).

---

## Running lessons (revise as entries are added)

- `.litertlm` is a packaging contract, not a conversion shortcut; it aligns the artifact, not the architecture.
- The tokenizer work never disappears, it changes shape (native `SpTokenizer`, then Dart `SentencePieceTokenizer`).
- Image preprocessing is model-specific, not shared plumbing.
- A valid Hugging Face page is not a working Android engine. Three models, three different failure points, one bottleneck: the runtime.

## Open threads (what could add the next entry)

- **MediaPipe/LiteRT-LM broadening multimodal support beyond Gemma.** If arbitrary `.litertlm` VLMs (or a SmolVLM/FastVLM re-export) become first-class on the supported Android path, retry the smallest ones and append the result.
- **A corrected SmolVLM LiteRT export** that ships matching prefill/decode signatures (logits output, no `mask` input) and a sane prompt budget would remove the entry-3 wall, worth one more spike.
- Any other preconverted `.litertlm` VLM with a confirmed Flutter engine that is meaningfully under a gigabyte, ideally in the few-hundred-megabyte range.

### Append template

```
### YYYY-MM-DD · <model + variant>, <one-line framing>
**Model:** <repo / file>. **Integration:** <runtime / plugin>.
<symptom, diagnosis, fix, or what worked>
**Result:** ✅ / ⚠️ / ❌ <one line>
```

Wire it in `lib/services/model_service.dart`, run on a real Adreno-class Android device, append the entry here, and update **Where this stands** plus the **Attempts ledger (Era A)** table above.
