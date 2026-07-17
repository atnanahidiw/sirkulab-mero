---
title: On-device model migration evidence log
description: Source provenance, device failures, and the auditable attempt ledger behind When Smaller Means Harder.
type: article
url: /articles/on-device-model-migration-evidence/
aliases:
  - /publications/on-device-model-migration-evidence/
date: 2026-06-20
article_label: Evidence log
article_topic: On-device model migration
---

# On-device model migration: evidence log (2026-05-29 to 2026-06-20)

Purpose: reconstruct, as accurately as the records allow, exactly which smaller on-device models were tried to replace Gemma 4 E2B, in what order, and how each one failed, including the actual on-device crash stacktraces. This is the source of record behind the narrative in `on-device-model-migration-lessons.md` (and the older `-draft.md`, which recorded fewer attempts than actually happened). Every quote below is tagged with its log source (session file and in-app timestamp) and, where applicable, the git commit.

## Sources and how far each could be checked

- **Git history of this repo** is the authoritative source for what was wired and when. Each committed attempt is tied to a commit, a branch, and an author date, with the model file and runtime read from `lib/services/model_service.dart` / `lib/models/model_spec.dart` at that commit.
- **Two committed post-mortems**, `docs/reports/on-device-model-migration-lessons.md` and `docs/reports/on-device-model-migration-lessons-comparison.md`, written at commit `9187c7d` (2026-06-02) and still present on branches `feature/eagle-bck` and `feature/eagagle-bck`. These are the developer's own contemporaneous write-up of the LiteRT phase and are the richest source for the SmolVLM, FastVLM, and Qwen-LiteRT failures. They are quoted directly below.
- **Codex CLI logs** (`~/.codex/sessions/2026/...`), **openclaw logs** (`~/.openclaw/agents/main/sessions/`), and **Hermes logs** (`~/.hermes/sessions/`) were mounted and parsed directly. The GGUF-era crash stacktraces come from these transcripts, where the developer pasted on-device `flutter`/`logcat` output while debugging. Each quote is attributed to its source and its in-app timestamp.

Two categories of evidence are kept distinct throughout: **wired and run on device** (git build config or a committed post-mortem with crash logs) versus **discussed only** (chat, surveys, or uncommitted working-tree edits).

## Timeline of attempts (wired and run)

The migration split into two runtime eras. **FastVLM-0.5B was the first model reached for** (earliest session mention 2026-05-30 10:29; first git commit 05-31, ahead of the SmolVLM commits on 06-01). The **LiteRT-LM era** (FastVLM, then SmolVLM, then Qwen-LiteRT) failed on the runtime contract; the **GGUF/llama.cpp era** (Qwen, Eagle2, InternVL3, LFM2-VL), whose runtime path was adopted from the Flux app (`github.com/Finn-Technologies/flux`, "refactor using flux" in the 06-02 logs), failed on native crashes, unusable output, and size. Test device for the pasted crashes: a Samsung SM-F936B (Snapdragon 8+ Gen 1, Adreno 730 GPU, 12 GB RAM), Android 16.

| Date | Model | Format / runtime | Branch / commit | Outcome |
| --- | --- | --- | --- | --- |
| 05-31 & 06-02 | FastVLM-0.5B (FIRST, tried twice) | `.litertlm` / FlutterLiteRtLm | feature/fastvlm-migration; 5be49f4, f295754, c0c2cfc | Engine initializes, then native SIGSEGV (SEGV_ACCERR): attempt 1 mid-generation (05-31), attempt 2 mid-prefill in `FillAttentionMask` (06-02) |
| 05-31 to 06-01 | SmolVLM-256M v1 | `.tflite` + separate tokenizer / native Kotlin plugin (TFLite) | feature/smaller-model; 53157e3, 86f489d | Operator, tensor-shape, and signature contract mismatches |
| 06-01 to 06-02 | SmolVLM-256M v2 | `.litertlm` / LiteRT-LM, Dart tokenizer | smaller-model-2; 0f2b29b, b58c2cc, 4bd3b74 | Failed differently from v1: file-routing conflict, then `Failed to invoke the compiled model` via `SmolVlmNativeEngine` |
| 06-02 (18:04) | Qwen3.5-0.8B-LiteRT (GabrieleConte) | `.litertlm` / LiteRT-LM (`flutter_litert_lm`) | (working tree; not committed in code) | Engine loaded; image send refused: `INVALID_ARGUMENT: Provided more images than expected in the prompt`; the configured conversation expected zero image slots, but the cause is unresolved |
| 06-02 | Qwen3.5-0.8B-GGUF (unsloth) | GGUF Q4_K_M + mmproj-F16 / LlamaDart (Flux Lite path) | feature/qwen; 9187c7d, 95c3baa | Vision works; disqualified by ~900 MB, native builds, plus repetition loops, context-window-too-small, and garbage output |
| 06-07 | Eagle2-1B | GGUF q4_0 / Quaynor then LlamaDart | feature/eagle; 0617fbf, bc76af4 | One artifact (`Mungert` q4_0, actually a plain `qwen2` text backbone under Eagle2's label) on two runtimes; one LlamaDart load crashed at `ggml_backend_alloc_ctx_tensors_from_buft` (cause unresolved — no vision tensors in the file to blame); what ran is blind; ~360 MB |
| 06-16 | Gemma 4 E2B (revert) | `.litertlm` / flutter_gemma | feature/smaller-gemma; 49c6827 | Fallback to the working baseline |
| 06-17 | InternVL3-2B | GGUF Q4_K_M + mmproj Q8_0 / LlamaDart | feature/internvlm; b090f1d | ~1.4 GB, dropped within a day |
| 06-17 to 06-18 | LFM2-VL-1.6B | GGUF Q4_0 + mmproj / LlamaDart | feature/lfm2-vl; 15cad16, 799b4c6 | Native Vulkan/Adreno crash, forced CPU, ~1.2 GB |
| 06-19 | Qwen3-0.6B + Talk2DINO (v2 split) | `.litertlm` LLM + ONNX vision | feature/mero-short; b6cbf0a | Text-only reasoning core plus vision tool, current trial |

## Verbatim crash evidence

### SmolVLM early load failures (stock flutter_gemma engines)

Before the native plugin, SmolVLM was tried through `flutter_gemma`'s stock engines, which could not assemble on the device. Both are 05-31 11:07 and 06-01, i.e. after FastVLM's first crash (05-31 03:27), and both are SmolVLM (the MediaPipe line is loading `donotdelete_smalvlm-256m...`, the jni failure is SmolVLM's SentencePiece tokenizer).

**MediaPipe engine could not load its native library.** Loading `donotdelete_smalvlm-256m-instruct...` through `flutter_gemma`'s MediaPipe engine, whose JNI `.so` was not in the APK. Source: openclaw `main--sessions/562bf137-1311-455a-ba36-b87070e13033...jsonl` (05-31 11:07):

```
05-31 11:07:26.672 E/AndroidRuntime(25741): FATAL EXCEPTION: DefaultDispatcher-worker-1
05-31 11:07:26.672 E/AndroidRuntime(25741): java.lang.UnsatisfiedLinkError: dlopen failed: library "libllm_inference_engine_jni.so" not found
05-31 11:07:26.672 E/AndroidRuntime(25741):  at com.google.mediapipe.tasks.genai.llminference.LlmInference.<clinit>(LlmInference.java:45)
05-31 11:07:26.672 E/AndroidRuntime(25741):  at dev.flutterberlin.flutter_gemma.engines.mediapipe.MediaPipeEngine.initialize(MediaPipeEngine.kt:75)
```

**Install step could not copy the SentencePiece JNI library.** The SmolVLM v1 path needed `ai.djl.sentencepiece`, whose native lib for `linux-aarch64` was missing. Source: Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38` (06-01 07:57) and Hermes `request_dump_20260604_170959_ec61d6b2_*`:

```
06-01 07:57:46.392 23419 23419 I flutter : Model installation failed: PlatformException(native_error, Cannot copy jni files, java.lang.IllegalStateException: Cannot copy jni files
06-01 07:57:46.392 23419 23419 I flutter :  at ai.djl.sentencepiece.jni.LibUtils.copyJniLibraryFromClasspath(LibUtils.java:74)
06-01 07:57:46.392 23419 23419 I flutter : Caused by: java.io.IOException: Resource not found in classpath: native/lib/linux-aarch64/libsentencepiece_native.so
```

### LiteRT-LM era

**SmolVLM-256M (v1 `.tflite`, then v2 `.litertlm`).**
Provenance: `litert-community/SmolVLM-256M-Instruct` on Hugging Face; the implementation followed its `smalvlm_notebook.ipynb` pipeline (source of the `smalvlm` filename spelling) with native conversion scripts from `github.com/dragynir/ai-edge-torch-smalvlm`. The user instruction is in the logs verbatim: "follow the pipeline in https://huggingface.co/litert-community/SmolVLM-256M-Instruct/blob/main/smalvlm_notebook.ipynb". Git: `53157e3`, `86f489d` (2026-06-01, v1 native plugin + manifest); `0f2b29b`, `b58c2cc`, `4bd3b74` (2026-06-02, v2 Dart tokenizer, stabilize prefill/decode I/O). v1 used `smalvlm-256m-instruct_q8_ekv2048_single_image.tflite` (288 MB on the HF file listing, plus an 882 KB `tokenizer.model`) through a native Kotlin plugin (`SpTokenizer` from `ai.djl.sentencepiece`); v2 switched to the `.litertlm` bundle with Dart-side `SentencePieceTokenizer`. Both blocked generation, but they did not fail the same way: v1 did not observe decode logits, while v2 reached the documented signatures after binding corrections and then failed during model invocation. Source: committed post-mortem `on-device-model-migration-lessons.md` (9187c7d), corroborated by Codex `2026/06/01`.

It first failed at interpreter creation, dying inside `NativeInterpreterWrapper.createInterpreter` before any inference ran (Codex `2026/06/01`):

```
06-01 07:28:38.360 18657 18657 I flutter : Model installation failed: PlatformException(native_error, Internal error: Cannot create interpreter: Op builtin_code out of range: 206. Are you using old TFLite binary with newer model?
06-01 07:28:38.360 18657 18657 I flutter : Registration failed.
06-01 07:28:38.360 18657 18657 I flutter : , java.lang.IllegalArgumentException: Internal error: Cannot create interpreter: Op builtin_code out of range: 206. Are you using old TFLite binary with newer model?
06-01 07:28:38.360 18657 18657 I flutter :  at org.tensorflow.lite.NativeInterpreterWrapper.createInterpreter(Native Method)
06-01 07:28:38.360 18657 18657 I flutter :  at org.tensorflow.lite.NativeInterpreterWrapper.init(NativeInterpreterWrapper.java)
```

After the TFLite bump cleared the opcode wall, the plugin's contract checks (`SmolVlmNativePlugin.kt`) rejected the model's I/O:

```
Unsupported image tensor shape: [1, 1, 3, 512, 512]
Prefill signature 'prefill_256_pixel' is missing logits output. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
SmolVLM prompt is too long for the available prefill signatures. Tokens=1531, max_supported=1280. Available prefill signatures: [prefill_256_pixel, prefill_256]
Decode signature 'decode' has an unsupported input 'mask'.
```

The decode failure surfaced as:

```
06-01 11:35:15.979 13253 13253 I flutter : [identifySpecies] Identification failed (model is fine): PlatformException(native_error, Decode signature 'decode' did not return logits. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
06-01 11:35:15.979 13253 13253 I flutter : 	at com.sirkulab.mero.SmolVlmNativeEngine.generate(SmolVlmNativePlugin.kt:186)
06-01 11:35:15.980 13253 13253 I flutter : [AnalyzingPage] identifySpecies failed: PlatformException(native_error, Decode signature 'decode' did not return logits. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
```

The model exposed KV-cache-style outputs while the app expected a logits-style generation flow, the image tensor layout did not match, and once image tokens plus instructions were combined the prompt exceeded the prefill budget (1531 > 1280). Two other builds refused in still different ways (Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38`): a LiteRT API version mismatch (05-31 19:05), and, for a vision app, no way to feed a picture (05-31 19:46):

```
05-31 19:05:01.224 18261 18261 I flutter : Existing model installation failed: NoSuchMethodError: Class 'SignatureRunner' has no instance method 'getInputDetails'.
05-31 19:05:01.224 18261 18261 I flutter : Receiver: Instance of 'SignatureRunner'
05-31 19:05:01.224 18261 18261 I flutter : Tried calling: getInputDetails()
05-31 19:46:20.343 22603 22603 I flutter : Progress: Tokenizing prompt... (0.2)
05-31 19:46:21.785 22603 22603 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Model does not expose a pixel_values input.
05-31 19:46:21.785 22603 22603 I flutter : [AnalyzingPage] identifySpecies failed: Exception: Model does not expose a pixel_values input.
```

v2 moved to the `.litertlm` bundle on AI Edge LiteRT (`com.google.ai.edge.litert:litert:2.1.0`). The runtime disagreed with itself about how to load the file (one path wanted the engine factory, another the Dart FFI client):

```
E flutter : [ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: PlatformException(IllegalArgumentException,
java.lang.IllegalArgumentException: /storage/emulated/0/Download/donotdelete_smalvlm-256m-instruct_q8_ekv2048_single_image.litertlm is a LiteRT-LM model — it should be handled by Dart FFI (LiteRtLmFfiClient), not by EngineFactory.,
Cause: null, Stacktrace: java.lang.IllegalArgumentException)
```

(Raw source: openclaw `562bf137...trajectory`, logged at 05-31 14:12 when the downloaded file was renamed to `.litertlm`; the v2 work then made that packaging official.)

Through the native engine (`SmolVlmNativeEngine`, `CompiledModel`) the model could not be invoked, and an earlier build could not find the signature at all. Source: Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38` (06-02 00:06 and 00:49):

```
06-02 00:06:02.432 11778 11778 I flutter : └ Signature not found, com.google.ai.edge.litert.LiteRtException: ERROR: [./third_party/odml/litert/litert/cc/litert_compiled_model.h:197]
06-02 00:49:59.179 21597 21597 I flutter : [identifySpecies] Identification failed (model is fine): PlatformException(native_error, Failed to invoke the compiled model, com.google.ai.edge.litert.LiteRtException: Failed to invoke the compiled model
06-02 00:49:59.179 21597 21597 I flutter :  at com.google.ai.edge.litert.CompiledModel.nativeRun(Native Method)
06-02 00:49:59.179 21597 21597 I flutter :  at com.google.ai.edge.litert.CompiledModel.run(Model.kt:446)
06-02 00:49:59.179 21597 21597 I flutter :  at com.sirkulab.mero.SmolVlmNativeEngine.runModel(SmolVlmNativePlugin.kt:394)
```

The routing conflict and the invoke failure are the same verdict as v1: the model's runtime contract never fit the app's generation flow. (The `06-02 15:07` `FillAttentionMask` dispatch crash on the `libLiteRtLm.so` / `ModelType.general` path is FastVLM's second attempt, below, not SmolVLM.)

**FastVLM-0.5B (the first model tried, and revisited).**
Provenance: model from Apple's `github.com/apple/ml-fastvlm`; wired as `litert-community/FastVLM-0.5B` (`.litertlm`) via `flutter_gemma`'s LiteRT-LM FFI. Git: `5be49f4` (2026-05-31, "update localization and model references for FastVLM migration"), `c0c2cfc` (2026-06-02, "migrate from FlutterGemma to FlutterLiteRtLm"), `f295754` (2026-06-02, "implement FastVLM image preprocessing"). Earliest session mention: 2026-05-30 10:29 (before any SmolVLM mention at 2026-05-30 19:43).

Why it was chosen (openclaw Codex `2026/05/30/rollout-2026-05-30T17-23-42`): the selection question was "smallest multimodal model still packaged as `.litertlm`" so the swap stays on the LiteRT runtime Gemma already used. No Google-official option fit: Gemma 3n E2B is multimodal but its standard int4 LiteRT-LM bundle is ~3.7 GB (no smaller than the existing Gemma 4 E2B baseline), and nothing first-party existed near ~500 MB. FastVLM-0.5B in the LiteRT Community was the nearest verifiable step down: multimodal, `.litertlm`, ~899 MB on NPU / ~1103 MB on GPU, roughly half of Gemma. Source card: https://huggingface.co/litert-community/FastVLM-0.5B.

Plugin context: at `5be49f4` the app's `pubspec.lock` pins `flutter_gemma` **0.15.0** (bumped to 0.16.3 in the current tree). The plugin's own documentation ([pub.dev/packages/flutter_gemma](https://pub.dev/packages/flutter_gemma)) lists its supported non-Gemma models as FastVLM 0.5B, FunctionGemma 270M, Qwen3 0.6B, Qwen 2.5, Phi-4 Mini, DeepSeek R1, and SmolLM 135M — with FastVLM the only non-Gemma entry flagged as vision-capable. That list is why FastVLM was the safest documented first swap, and why SmolVLM (not on the list) meant leaving the documented path entirely.

FastVLM was tried **twice**, both times on `flutter_gemma`'s LiteRT-LM FFI path, both times ending in an uncatchable native segfault inside a running engine. The second attempt came around the GGUF pivot, after image preprocessing was reworked (`f295754`).

**First attempt (05-31), mid-generation.** Through the `.litertlm` FFI path (`ModelType.general`) the engine initialized (`Engine initialized successfully` at 05-31 03:17), took the image, and began generating, then crashed natively on the engine thread mid-generation. So the accurate description is not "could not create an engine" (as the committed post-mortem phrases it) but "created an engine and segfaulted during generation." Active model confirmed in the same log: `Set active inference model: donotdelete_FastVLM-0.5B` / `Creating engine from ...donotdelete_FastVLM-0.5B.litertlm`. Source: Codex `sessions/2026/05/30/rollout-2026-05-30T18-28-58-019e78a4-...jsonl` (device log pasted 2026-05-30T20:27Z; device clock GMT+7):

```
05-31 03:17:44.353 16258 16258 I flutter : ✅ Set active inference model: donotdelete_FastVLM-0.5B
05-31 03:26:54.918 I/flutter (21151): ── Custom generation pass 1 ──
05-31 03:26:54.921 I/flutter (21151): InferenceChat: Starting to iterate over native tokens...
05-31 03:27:04.471 F/libc    (21151): Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb400007313b4c000 in tid 22170 (engine/22170), pid 21151 (m.sirkulab.mero)
```

**Second attempt (06-02), mid-prefill.** Reloaded on the same `libLiteRtLm.so` FFI path (`06-02 15:06:52` context shows `modelType=ModelType.general, fileType=ModelFileType.litertlm`); this time it segfaulted earlier, during prefill, inside `litert::lm::FillAttentionMask`. Source: Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38` (06-02 15:07):

```
06-02 15:06:59.328 29903       E/litert: No dispatch library found in /storage/emulated/0/Download
06-02 15:06:59.328 29903       E/litert: Failed to initialize Dispatch API
06-02 15:07:02.051 29903       F/libc: Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb4000073f40ed000 in tid 30407 (engine/30407), pid 29903 (m.sirkulab.mero)
06-02 15:07:02.469 30559      F/DEBUG: pid: 29903, tid: 30407, name: engine/30407  >>> com.sirkulab.mero <<<
06-02 15:07:02.469 30559      F/DEBUG: #01 libLiteRtLm.so litert::lm::FillAttentionMask(...)
06-02 15:07:02.469 30559      F/DEBUG: #02 libLiteRtLm.so litert::lm::LlmLiteRtCompiledModelExecutorBase::PrefillInternal(...)
06-02 15:07:02.469 30559      F/DEBUG: #05 libLiteRtLm.so litert::lm::Prefill(...)
06-02 15:07:02.469 30559      F/DEBUG: #06 libLiteRtLm.so litert::lm::SessionBasic::PrefillInternal(...)
06-02 15:07:02.469 30559      F/DEBUG: #08 libLiteRtLm.so litert::lm::ThreadPool::RunWorker(...)
```

**Gemma chat-template tokens fed to FastVLM before a crash (06-02 16:16).** The same day's logcat also shows the plugin wrapping FastVLM's prompt in Gemma's turn markers (`<end_of_turn>` / `<start_of_turn>model`) immediately before a SIGSEGV on the `DefaultDispatch` thread. The same model on the same plugin version (0.15.0) is reported upstream producing garbled `<start_of_...>` token output on macOS ([DenisovAV/flutter_gemma#268](https://github.com/DenisovAV/flutter_gemma/issues/268)). Template handling is therefore a plausible contributor, but the two reports have different symptoms and neither establishes the crash's cause. Source: Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38`:

```
06-02 16:16:51.706 I/native  ( 9494): [InputImage]
06-02 16:16:51.706 I/native  ( 9494): <end_of_turn>
06-02 16:16:51.706 I/native  ( 9494): <start_of_turn>model
06-02 16:16:51.709 F/libc    ( 9494): Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 9563 (DefaultDispatch), pid 9494 (m.sirkulab.mero)
```

FastVLM also needed model-specific image preprocessing and a file-backed image transport, so it was never a drop-in for the Gemma tool-calling flow. Note the distinct 06-02 `Failed to invoke the compiled model` crash (00:49) routes through `SmolVlmNativeEngine.runModel` and belongs to SmolVLM v2 above, not FastVLM; the committed post-mortem's grouping of a 06-02 crash under FastVLM refers to this prefill `FillAttentionMask` segfault, which the logcat does support.

**Qwen3.5-0.8B-LiteRT (`GabrieleConte/Qwen3.5-0.8B-LiteRT`).** The last LiteRT-LM attempt, on the `flutter_litert_lm ^0.3.0` plugin (`songhieu/flutter_litert_lm`), bundle `qwen35_mm_q8_ekv2048.litertlm` (1.2 GB). Provenance of the wiring: the 06-02 rewire (Codex `2026/06/01/...02-18-38`) first pointed `model_service.dart:115` at a nonexistent `litert-community` repo/filename; the same-day review in openclaw `49c29ded` flagged it as a 404 and corrected it to the `GabrieleConte` repo and real filename. **The corrected bundle then ran on-device and its failure is logged**: at 06-02 18:04 the engine had loaded the bundle, and the image send was refused because the configured conversation expected zero image slots. The log does not explain why. Source: openclaw `49c29ded...trajectory` (user-pasted logcat, 06-02 18:08):

```
06-02 18:04:57.787 2170 2170 I flutter : [AnalyzingPage] identifySpecies failed: PlatformException(MESSAGE_ERROR, Failed to call nativeSendMessage: INVALID_ARGUMENT: Provided more images than expected in the prompt., com.google.ai.edge.litertlm.LiteRtLmJniException: Failed to call nativeSendMessage: INVALID_ARGUMENT: Provided more images than expected in the prompt.
06-02 18:04:57.787 2170 2170 I flutter : at com.google.ai.edge.litertlm.LiteRtLmJni.nativeSendMessage(Native Method)
06-02 18:04:57.787 2170 2170 I flutter : at com.google.ai.edge.litertlm.Conversation.sendMessage(Conversation.kt:103)
06-02 18:04:57.787 2170 2170 I flutter : at com.songhieu.flutter_litert_lm.FlutterLitertLmPlugin$handleSendMessage$1.invokeSuspend(FlutterLitertLmPlugin.kt:174)
```

The in-session diagnosis said the native library did not recognize the bundle as a vision model. The later artifact-card check does not support that as a settled conclusion: the published bundle contains vision components, and the observed zero-slot conversation could also result from placeholders, templates, metadata, or plugin routing. The log still timestamps the attempt at 18:04, after FastVLM's second crash (15:07) and before the GGUF migration commit (22:11), confirming the ordering in the reconciliation section. Never committed to `model_service.dart`, so a working-tree attempt. Its failure is what triggered abandoning LiteRT-LM for GGUF. Source: committed post-mortem (9187c7d); Codex 06-01/06-02; openclaw `49c29ded`; no `-S GabrieleConte` hit in tracked code.

### GGUF / llama.cpp era

Provenance: the GGUF-era architecture was adopted from the **Flux** app, `github.com/Finn-Technologies/flux`, an offline Android assistant running Gemma 4 and Qwen 3.5 through `llamadart` with GGUF models and auto-downloaded `mmproj` projectors; its "Flux Lite" tier is Qwen 3.5 0.8B GGUF + mmproj at a published ~533 MB, which is the **same runtime path and model family** Mero adopted, not the exact same packaging: Mero wired the `unsloth` `Qwen3.5-0.8B-Q4_K_M.gguf` model with an unquantized `mmproj-F16.gguf` projector, and that heavier F16 projector is why Mero's combined download came to ~900 MB rather than Flux Lite's 533 MB. User instruction, verbatim: "refactor using https://github.com/Finn-Technologies/flux" (Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38`, 06-02 11:24). Weights/runtimes: `unsloth/Qwen3.5-0.8B-GGUF`; `Mungert/Eagle2-1B-GGUF` (model `github.com/NVlabs/EAGLE`); `ggml-org/InternVL3-2B-Instruct-GGUF`; `LiquidAI/LFM2-VL-1.6B-GGUF`; runtime `llamadart` (`github.com/leehack/llamadart`) and Quaynor (`github.com/iBz-04/quaynor`); a second LiteRT-LM plugin `github.com/songhieu/flutter_litert_lm` was also tried.

**Run-but-fail: even when Qwen-GGUF ran, the output was unusable.** Three modes, all Codex `sessions/2026/06/01/rollout-2026-06-01T02-18-38`.

Context window too small to hold image plus history, on tool-session pass 4 (06-02 22:09):

```
06-02 22:09:44.094  9825  9825 I flutter : ── Native tool session pass 4 ──
06-02 22:09:44.094  9825  9825 I flutter : Progress: Generating result... (0.75)
06-02 22:09:52.448  9825  9825 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Multimodal prompt evaluation failed: 1. The active context window may be too small for this image and conversation history.
```

Degenerate repetition in thinking mode, caught by the `ModelRepetitionLoopException` guard (canonical example "Quadri Quadri Quadri..."; a Hermes `request_dump_20260604_*` note records "Added repetition loop detection for Qwen's thinking mode at 0.8B"). No raw logcat of the chanting itself survives; the surviving artifacts are the user-facing message ("Model entered a repetition loop. Please try again.") and the guard code itself: `_isRepetitionLoop` in `lib/services/model_runtime.dart` (still in the current tree), which trips on a run of 6+ identical consecutive tokens.

Hallucinated, self-contradictory tool call, repeated until rejected (06-02 23:56 through 06-03 01:18). The duplicate-call guard is `_isDuplicateSpeciesSearchCall`, introduced in the same migration commit (9187c7d): it compares the required parameters of each `search_similar_features` call against the previous call and returns a `duplicate_call` rejection ("Rejected duplicate search. Change at least one required parameter.") as the tool result. The unparseable-response catch-all predates the GGUF era (introduced at 99fe6b8):

```
06-02 23:56:27.721 29205 29205 I flutter : [Pass 1] Native tool call: search_similar_features
06-02 23:56:27.721 29205 29205 I flutter :   "visualGroup": "Primate",
06-02 23:56:27.722 29205 29205 I flutter :   "taxOrder": "Primates",
06-02 23:56:27.722 29205 29205 I flutter :   "taxFamily": "Eupodidae",
06-02 23:56:27.722 29205 29205 I flutter :   "taxGenus": "Varanus"
06-03 01:17:02.717 9359 9359 I flutter : ── Native tool session round 5 ──
06-03 01:18:11.122 9359 9359 I flutter : Progress: Complete (1.0)
06-03 01:18:11.147 9359 9359 I flutter : [identifySpecies] Garbage result detected — rejecting response.
06-03 01:18:11.152 9359 9359 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Model returned an unparseable response.
```

**Native tensor-alloc crash captured for Eagle2; LFM2 notes describe a GPU-path crash; InternVL3 did not crash.** The clean tombstone below belongs only to the Eagle2-labelled artifact. It is a null-pointer dereference on the `DartWorker` thread, not a recoverable Flutter exception. Its cause remains unresolved: the in-session diagnosis blamed the unsupported `eagle_2_5_vl` vision architecture, but the artifact actually run was a plain `qwen2` text backbone with no vision tensors. The LFM2-VL session notes mention the same allocator function and say that setting `gpuLayers=0` stopped its crash, but they do not contain a fresh LFM2 tombstone and cannot establish an identical stack or root cause. **InternVL3-2B did not hit this crash**: it was a real multimodal GGUF that was dropped on 06-16 for its footprint (`~1.0 GB model + ~0.3 GB projector`, swapped for the smaller LFM2-VL in the same session, git comment verbatim), never for a load failure. Source: openclaw `2026-06-07T07-35-04` (Eagle2 day):

```
06-07 14:31:15.690 F/libc    (27648): Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 27721 (DartWorker), pid 27648 (m.sirkulab.mero)
06-07 14:31:15.966 F/DEBUG   (27742): Cause: null pointer dereference
06-07 14:31:15.966 F/DEBUG   (27742): #00 pc 0000000000000000  <unknown>
06-07 14:31:15.966 F/DEBUG   (27742): #04 ... base.apk!libggml-base.so ...
06-07 14:31:15.966 F/DEBUG   (27742): #06 ... base.apk!libggml-base.so ... ggml_backend_alloc_ctx_tensors_from_buft+116
06-07 14:31:15.966 F/DEBUG   (27742): #07 ... base.apk!libllama.so ... llama_model_base::load_tensors(...)
06-07 14:31:15.966 F/DEBUG   (27742): #09 ... base.apk!libllama.so ... llama_model_load_from_file+220
```

The fatal Eagle2 frame is the tensor allocation during model load. For LFM2-VL-1.6B, the session notes attribute a native crash to the GPU-enabled path and record that forcing Android onto the CPU backend (`gpuLayers=0`) in commit 799b4c6 stopped it. Because the notes contain no fresh tombstone, they do not establish that the LFM2 crash used the same allocator stack as Eagle2. The commit message records the outcome of the switch: "Because it's a native crash, the try/catch CPU fallback can't recover. Default Android to the CPU backend (gpuLayers=0); iOS/desktop keep auto (Metal)" — with the in-code comment adding "CPU is slower but stable." CPU eliminated the recorded crash behavior but not the disqualifiers (speed, 1.2 GB model, APK bloat).

**Eagle2 first pass via Quaynor (before LlamaDart).** The Quaynor attempt failed twice before any inference: the package was referenced but not yet a dependency (flutter analyze), then the model would not load. Sources: openclaw `13f77617` checkpoint (analyze output) and Codex `2026/06/07` (the `activateFromFile` guard that throws the load error):

```
error • Target of URI doesn't exist: 'package:quaynor/quaynor.dart' • lib/main.dart:5:8 • uri_does_not_exist
error • Target of URI doesn't exist: 'package:quaynor/quaynor.dart' • lib/models/model_spec.dart:1:8 • uri_does_not_exist
error • Target of URI doesn't exist: 'package:quaynor/quaynor.dart' • lib/services/model_runtime.dart:5:8 • uri_does_not_exist
Exception: Quaynor failed to load model from <path>
```

### Adjacent (v2, not a v1 VLM): ONNX int8 vision export

While preparing the Talk2DINO vision tool (v2), the int8 ONNX encoder hit a missing mobile kernel for `ConvInteger` (Codex `2026/06/18`):

```
VisionRuntime load failed:
PlatformException(ORT_ERROR, Error code - ORT_NOT_IMPLEMENTED
Could not find an implementation for ConvInteger(10) node with name '/patch_embed/proj/Conv_quant'
```

The fix landed in two commits. `1f6032f` ("load the vision encoder on ORT-Android and surface the active backend") first made fp16 the safe default and kept int8 as an unverified fallback. `b646c28` ("load the ORT-Android-safe vision encoder and enforce observe-first tools") then made dynamic int8 the shipped default for the image encoder by excluding the single `Conv` op (the patch-embed layer) from quantization, so the graph never emits `ConvInteger` at all — only `MatMulInteger`, which the target ORT-Android build does support. Root fix, in `scripts/smaller-footprint-pipeline-v2/export_vision_model.py` (formerly `scripts/export_vision_model.py`):

```python
if quant == "dynamic":
    # Exclude Conv (the single patch-embed) so we DON'T emit ConvInteger,
    # which ORT-Android lacks. Only MatMul is quantized → MatMulInteger,
    # activations stay fp32 so accuracy is preserved (~cosine 0.99). ~half
    # the fp16 size, but MatMulInteger support on the target build is not
    # guaranteed — verify on-device before relying on it.
    from onnxruntime.quantization import QuantType, quantize_dynamic

    quantize_dynamic(fp32, final, weight_type=QuantType.QInt8,
                     op_types_to_quantize=["MatMul"])
    os.remove(fp32)
    return
```

The text encoder stayed on fp16 instead, for the opposite reason: CLIP's ~49k-token embedding table is a `Gather`, not a `MatMul`, so MatMul-only quantization would leave it fp32 anyway while fp16 halves it. Noted only so this crash class is not confused with a v1 model failure.

## How each attempt failed (summary with sources)

- **SmolVLM-256M v1 (`.tflite`, native Kotlin)**: operator out of range (206), unsupported image tensor shape `[1,1,3,512,512]`, prefill/decode signature mismatch (KV-cache outputs, no logits, unsupported `mask` input), prompt over budget (1531 > 1280), tokenizer `filesDir` path bug. [post-mortem 9187c7d; Codex 06-01; git 53157e3, 86f489d]
- **SmolVLM-256M v2 (`.litertlm`, Dart tokenizer)**: file-routing conflict (EngineFactory vs Dart FFI); via the native `CompiledModel` (`SmolVlmNativeEngine`), `Signature not found` (06-02 00:06) then `Failed to invoke the compiled model` (06-02 00:49). The 06-02 15:07 `FillAttentionMask` prefill segfault on the `libLiteRtLm.so` path is FastVLM's second attempt, not SmolVLM. [post-mortem 9187c7d; Codex 06-01/06-02; git 0f2b29b, b58c2cc, 4bd3b74]
- **FastVLM-0.5B (first model tried, twice)**: both attempts on `flutter_gemma`'s LiteRT-LM FFI, both native `SIGSEGV` (`SEGV_ACCERR`) inside a running engine. Attempt 1 (05-31 03:27) crashed mid-generation on the engine thread; attempt 2 (06-02 15:07), after preprocessing rework, crashed mid-prefill inside `litert::lm::FillAttentionMask`. Needs model-specific preprocessing and file-backed image input. Model from `github.com/apple/ml-fastvlm`. (The separate 06-02 00:49 `Failed to invoke` crash via `SmolVlmNativeEngine` is SmolVLM v2, not FastVLM.) [Codex 05-30, 06-01; git 5be49f4, f295754, c0c2cfc]
- **Qwen3.5-0.8B-LiteRT (GabrieleConte)**: engine loaded the 1.2 GB multimodal bundle, but the configured conversation expected zero image slots and refused the image (`INVALID_ARGUMENT: Provided more images than expected in the prompt`, 06-02 18:04). The log does not show why. The artifact card says the bundle contains a language model, vision encoder, vision adapter, and tokenizer, leaving image placeholders, chat-template handling, multimodal metadata, and plugin routing as possible causes. This was the failure that ended the LiteRT era. Not committed in code. [post-mortem 9187c7d; openclaw 49c29ded]
- **Qwen3.5-0.8B-GGUF (unsloth)**: runtime adopted from Flux (`github.com/Finn-Technologies/flux`, "refactor using flux", 06-02 11:24); real vision grounding via GGUF + mmproj, but ~900 MB and per-ABI native builds, manual tool loop; and even when it ran it produced repetition loops, context-window-too-small errors, and hallucinated/unparseable tool output. [git 9187c7d, 95c3baa; Codex 06-02/06-03/06-07]
- **Eagle2-1B**: the real model is a VLM (SigLIP encoder under a custom `eagle_2_5_vl` architecture, unsupported by llama.cpp — feature request opened 2025-10-21 documenting the failed mmproj conversion, later closed as stale without implementation, github.com/ggml-org/llama.cpp/issues/16704), but the full seeing model was never run: both commits (0617fbf Quaynor, bc76af4 LlamaDart) wire the same single artifact, `Mungert/Eagle2-1B-GGUF`'s `Eagle2-1B-q4_0.gguf`. One LlamaDart load on 06-07 crashed with a null-deref SIGSEGV at `ggml_backend_alloc_ctx_tensors_from_buft`; the in-session diagnosis blamed unallocatable `eagle_2_5_vl` vision tensors, but later verification (2026-07) contradicts that reading: the repository, despite carrying Eagle2's model card and Image-Text-to-Text tag, has GGUF metadata identifying the architecture as plain `qwen2` at ~0.6B params, ships **no `mmproj` projector**, and its 4-bit files are 360-429 MB (matching what was run) — no vision tensors to trip on, so that crash's cause is unresolved. What ran was the text backbone under Eagle2's label, about 360 MB for Q4_0 and blind, so vision was faked from Dart-side trait extraction. Correction (2026-07): Quaynor itself does support multimodal GGUF models when given a matching `mmproj` projection model (per its pub.dev docs), so the blindness was the artifact's, not the engine's — the Eagle2-labelled repository ships no projector to give it. (Caveat: the repo's history was super-squashed around 2025-09, so only its surviving files can be inspected; claims about what it "ever" contained are not supportable.) Counting note: Eagle2's two runs were one artifact on two runtimes, Quaynor then LlamaDart. [git 0617fbf, bc76af4; openclaw 06-07]
- **Gemma 4 E2B revert**: checkpoint back to the known-good baseline. [git 49c6827]
- **InternVL3-2B**: multimodal GGUF that worked, ~1.4 GB download (Q4_K_M ~1.0 GB + Q8_0 mmproj ~0.3 GB), over goal, dropped within a day. The in-code doc comment at b090f1d/`model_service.dart` records the wiring: "a true multimodal VLM: the photo is fed to the vision encoder through the paired mmproj projector, and the model uses LlamaDart's native tool calling." No latency/memory/taxonomy measurements were recorded before the swap to LFM2-VL. [git b090f1d; Codex 06-16]
- **LFM2-VL-1.6B**: session notes record a native crash with the GPU-enabled path and say forcing the CPU backend stopped it; no fresh LFM2 tombstone survives, so the exact stack and root cause are not established. Total footprint was ~1.2 GB (Q4_0 model ~0.65 GB + Q8_0 mmproj ~0.54 GB, per the 06-16 session's config comment). [git 15cad16, 799b4c6; Codex 06-16, 06-18]
- **Footprint was not only the model (InternVL3 / LFM2 era).** Mero's tested default `llamadart` configuration included all runtime families available for the Android target. The release APK was dominated by `libggml-vulkan.so` (~50.5 MB) and `libLiteRtLm.so` (~24.7 MB) plus a Qualcomm QNN/NPU stack (`libQnnHtpV8x/V7x Skel` ~52-53 MB total) and `libLiteRtGpuAccelerator.so` (~8 MB), pushing the APK toward ~149 MB before the model download. Current LlamaDart releases allow applications to select runtime families and llama.cpp backend modules, so this is evidence about Mero's tested default bundle, not unavoidable LlamaDart overhead. [Codex 06-16, 06-18]

## Attempted but not committed to git

- **Florence-2-base**. The `feature/florence` branch (created 05-31) is named for this, and on 2026-06-06 the openclaw agent received an explicit instruction ("change again the code to use Florence-2-base"), so the app code was pointed at Florence-2 at least once. It was never committed (the branch tip still has FastVLM wired) and was dropped because Florence-2 is a caption / detection / OCR task model, not a chat or reasoning VLM. Microsoft designed it as a seq2seq model driven by task prompts (detection, segmentation, captioning, OCR, region grounding), "for vision tasks rather than general conversational chat," and Florence-2-base is only ~230M parameters ([microsoft/Florence-2-base](https://huggingface.co/microsoft/Florence-2-base)). It cannot drive the observe, hypothesise, and explain flow. [openclaw checkpoint 13f77617, 2026-06-06; Codex 06-19]
- **Qwen3.5-0.8B-LiteRT** (above) was also working-tree only, documented in the committed post-mortem but not preserved in `model_service.dart`.

## Considered on paper, never wired

A sub-1.5 GB VLM candidate survey was maintained in the working tree (`docs/reports/sub-1.5gb-vlm-candidate-survey.md`, referenced in the Codex 06-16 and 06-19 sessions but never committed to git). It compared candidates ruled out without a build, including MobileVLM V2 1.7B, Granite Vision 3.x 2B, MiniCPM-V 4.6, Aquila-VL-2B, and InternVL3.5-2B. These are research entries, not attempts.

Excluded as false positives when scanning the logs and code by name: "cactus" (a filename in an unrelated `kaggle-gemma4-judging` project, not an inference runtime), "gemma-3" / "gemma-3n" (flutter_gemma runtime and reference mentions), some "Qwen2.5-VL" / "LLaVA" hits that belong to the separate candidate-rank interpretability research, and `google/gemma-4-31B-it`, which appears only as a reference in code comments and model notes (a 31B model cannot run on the 8 GB target), not as an on-device attempt.

A full history scan of `model_service.dart` / `model_spec.dart` confirms the complete set of model URLs ever wired in code: `litert-community/{gemma-4-E2B-it-litert-lm, SmolVLM-256M-Instruct, FastVLM-0.5B, Qwen3-0.6B}`, `unsloth/Qwen3.5-0.8B-GGUF`, `Mungert/Eagle2-1B-GGUF`, `ggml-org/InternVL3-2B-Instruct-GGUF`, and `LiquidAI/LFM2-VL-1.6B-GGUF`. Neither `GabrieleConte/Qwen3.5-0.8B-LiteRT` nor Florence-2 appears there, confirming both were working-tree-only attempts.

## Count

- **Distinct models wired and run: six** — SmolVLM-256M, FastVLM-0.5B, Qwen3.5-0.8B, Eagle2-1B, InternVL3-2B, LFM2-VL-1.6B.
- **Distinct artifact-and-runtime configurations: nine** — SmolVLM v1 (.tflite native), SmolVLM v2 (.litertlm Dart), FastVLM (.litertlm), Qwen3.5-0.8B-LiteRT, Qwen3.5-0.8B-GGUF, Eagle2 text backbone (Quaynor), Eagle2 text backbone (LlamaDart), InternVL3-2B (GGUF), LFM2-VL-1.6B (GGUF). "Artifact-and-runtime" is the accurate unit: SmolVLM and Qwen3.5 were each attempted as two different artifacts/runtimes, while Eagle2's two runs used one artifact on two runtimes (see the Eagle2 bullet above). FastVLM was run **twice on the same LiteRT-LM runtime** (05-31 and 06-02), so counting distinct runs the total is ten.
- **Attempted in the app but not committed: one model** — Florence-2-base (dropped as a task model, not a reasoning VLM).
- **Considered on paper only: several** — MobileVLM V2 1.7B, Granite Vision 2B, MiniCPM-V 4.6, Aquila-VL-2B, InternVL3.5-2B.
- Then one revert to Gemma 4, and the v2 split (Qwen3-0.6B + Talk2DINO).

Runtimes/stacks exercised: flutter_gemma (Gemma baseline), native TFLite/Kotlin (SmolVLM v1), FlutterLiteRtLm (SmolVLM v2, FastVLM, Qwen-LiteRT), Quaynor (Eagle2 first pass), LlamaDart / llama.cpp (Qwen-GGUF, Eagle2, InternVL3, LFM2-VL), and flutter_onnxruntime for the Talk2DINO vision tool in v2.

The failures group by runtime era. LiteRT-LM failed on the model/runtime contract three different ways: TFLite operator and signature mismatch plus an `invoke` that never returned (SmolVLM), a native SIGSEGV inside a running engine twice, mid-generation then mid-prefill (FastVLM), and a conversation configured with zero image slots (Qwen-LiteRT, cause unresolved). GGUF/llama.cpp then hit an unresolved Eagle2 allocator SIGSEGV, a GPU-path crash described in the LFM2 notes, unreliable Qwen output, incomplete Eagle2 artifacts, and size limits (Qwen-GGUF ~900 MB, InternVL3 ~1.4 GB, LFM2-VL ~1.2 GB).

## Web verification pass (2026-07-17)

This pass checked the narrative against public sources after the on-device sessions. Primary documentation, model cards, repository file listings, and source code were preferred. GitHub issues and project READMEs are retained as reports or implementation evidence, not treated as independent proof. Current documentation is also kept separate from the versions used in June 2026: it can show what exists now, but it cannot retroactively establish what the tested package did.

### Baseline and test environment

- The standard Gemma 4 E2B LiteRT-LM file is currently listed at 2.59 GB, supporting the narrative's “roughly 2.6 GB” baseline: [LiteRT Community Gemma 4 E2B files](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/tree/main). The same model card reports a 2,583 MB on-disk model in its benchmark table: [Gemma 4 E2B LiteRT-LM card](https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm).
- The experiment ran on a Samsung SM-F936B with Snapdragon 8+ Gen 1, Adreno 730, 12 GB RAM, and Android 16. That fact comes from the local logs, not the web. It should be preserved whenever native GPU, ABI, memory, or low-cost-device implications are discussed. This was a capable reference phone, not one of the low-cost classroom devices that motivate the storage target.
- Exact tested LlamaDart and Quaynor versions or revisions were not recovered in this web pass. Current documentation must not be substituted for those missing historical pins.

### FastVLM

- Apple's official repository describes FastVLM as a VLM built around the FastViTHD vision encoder and provides the reference implementation: [apple/ml-fastvlm](https://github.com/apple/ml-fastvlm).
- The official model configuration names the vision tower `mobileclip_l_1024`, which supports the 1024-resolution preprocessing detail but does not, by itself, prove every crop operation performed in Mero: [FastVLM-0.5B config](https://huggingface.co/apple/FastVLM-0.5B/blob/main/config.json).
- `flutter_gemma` 0.15.0 documented FastVLM as vision-capable and without function calling. That supports “unsupported by documented plugin capability,” not “never reached,” in the tool-call summary: [flutter_gemma 0.15.0 capability table](https://github.com/DenisovAV/flutter_gemma/blob/v0.15.0/README.md#model-capabilities).
- The LiteRT Community artifact lists approximately 899 MB for the NPU build and 1,103 MB for the GPU build: [FastVLM-0.5B LiteRT artifact](https://huggingface.co/litert-community/FastVLM-0.5B).
- `flutter_gemma` issue #268 reports garbled special tokens with FastVLM-0.5B and plugin 0.15.0 on a Mac Mini M4, while Gemma 4 worked in the same setup: [issue #268](https://github.com/DenisovAV/flutter_gemma/issues/268). This is one open, unassigned user report. It records a different symptom from Mero's Android SIGSEGVs, so it supports only the narrow statement that another project reported trouble with the same model/plugin combination. It does not rule out a device-specific cause for Mero's crashes.
- The Mero tombstone places the second crash in `libLiteRtLm.so`, inside `FillAttentionMask` during prefill. A stack trace establishes where a failure surfaced, not whether the root cause was the runtime, model file, prompt template, image preparation, or their interaction.

### SmolVLM

- The official SmolVLM-256M card says one-image inference can use less than 1 GB of GPU RAM: [HuggingFaceTB/SmolVLM-256M-Instruct](https://huggingface.co/HuggingFaceTB/SmolVLM-256M-Instruct).
- The LiteRT Community repository lists two 288 MB TFLite files and an 882 KB tokenizer: [SmolVLM LiteRT files](https://huggingface.co/litert-community/SmolVLM-256M-Instruct/tree/main).
- Its canonical runner chooses among fixed prefill signatures, adds `mask` only when the selected signature declares it, discards prefill logits only when present, and unconditionally reads `logits` from each decode result: [official `test_tflite.py`](https://huggingface.co/litert-community/SmolVLM-256M-Instruct/blob/main/test_tflite.py). Therefore:
  - prefill may legitimately return only KV caches;
  - decode must return logits for autoregressive token selection;
  - Mero's missing-decode-logits observation is a failure of the tested integration, not a demonstrated property of SmolVLM or of every revision of the export;
  - possible explanations include the exact file revision, output introspection, buffer binding, and runtime API.
- The two Mero integrations did not fail the same way. The TFLite path did not observe decode logits. The later LiteRT `CompiledModel` path found the documented signatures after binding corrections and then failed during invocation.
- The stock plugin's native-library and API failures do not by themselves establish a limitation of SmolVLM. They show that the selected plugin routes, engine versions, format, and ABI did not form a working path for this artifact.
- The DJL log proves only that `ai.djl.sentencepiece` attempted to copy `native/lib/linux-aarch64/libsentencepiece_native.so` and could not find that resource in the classpath. The web pass did not find a primary source proving the broader claim that DJL “only shipped a Linux JNI binary, not an Android one.” The evidence should stay at the resource-lookup level unless the exact Maven artifact is inspected.

### Qwen3.5 and Flux

- The Qwen LiteRT artifact card says its bundle contains a language model, vision encoder, vision adapter, and tokenizer: [GabrieleConte/Qwen3.5-0.8B-LiteRT](https://huggingface.co/GabrieleConte/Qwen3.5-0.8B-LiteRT). The error “Provided more images than expected” proves that the configured conversation expected zero image slots. It does not prove that the runtime loaded a text-only model. Missing image placeholders, chat-template handling, multimodal metadata, and plugin routing remain possible causes.
- Qwen's official 0.8B card positions the checkpoint for prototyping, task-specific fine-tuning, and research or development: [Qwen3.5-0.8B](https://huggingface.co/Qwen/Qwen3.5-0.8B). A few poor generations in one quantized runtime and sampling configuration establish unreliability for Mero's tested setup, not an inherent knowledge ceiling. Quantization, prompting, sampling, image compression, and runtime behavior remain confounders.
- Eupodidae is a real mite family: [EPPO taxonomy entry](https://gd.eppo.int/taxon/1EUPOF). The recorded output is still nonsensical because Eupodidae is unrelated to `Varanus` and cannot make the Primates/reptile combination coherent.
- Flux's README documents an offline Android assistant using LlamaDart, Qwen vision, GGUF models, and projectors, with “Flux Lite” at about 533 MB: [Finn-Technologies/flux](https://github.com/Finn-Technologies/flux). This is public implementation evidence from the project itself, not an independently reproduced run. Mero tested a different Q4_K_M language-model and F16-projector combination at about 900 MB, so the two size figures are not measurements of the same package.

### Quaynor and Eagle2

- Current Quaynor documentation lists Metal/Vulkan acceleration, dependencies on `ffi` and `flutter_rust_bridge`, and vision support when a compatible `mmproj` is supplied: [Quaynor package documentation](https://pub.dev/packages/quaynor). The tested Eagle2 path was blind because the artifact lacked a projector and vision tensors, not because Quaynor was pure Dart or text-only by design.
- `Mungert/Eagle2-1B-GGUF` currently exposes plain `qwen2` GGUF metadata at about 0.6B parameters, no visible `mmproj`, and 4-bit variants ranging from roughly 360 to 429 MB: [Eagle2-labelled GGUF repository](https://huggingface.co/Mungert/Eagle2-1B-GGUF). The tested `Eagle2-1B-q4_0.gguf` is approximately 360 MB.
- llama.cpp issue #16704 was opened on October 21, 2025, documented unsupported `eagle_2_5_vl` projector conversion, and was later closed as stale without implementation: [llama.cpp issue #16704](https://github.com/ggml-org/llama.cpp/issues/16704). It establishes an upstream architecture gap, but Mero's downloaded file did not contain that architecture.
- The Eagle2 allocator tombstone therefore cannot be attributed to Eagle2 vision tensors or to the mobile GPU. Its cause remains unresolved.

### InternVL3 and LFM2-VL

- The official InternVL3 card describes InternVL3-2B as InternViT-300M plus Qwen2.5-1.5B, connected through an MLP projector with pixel unshuffle: [InternVL3-2B](https://huggingface.co/OpenGVLab/InternVL3-2B-Pretrained).
- The tested GGUF files are currently listed at 1.12 GB for the Q4_K_M language model and 337 MB for the Q8_0 projector: [InternVL3 Q4_K_M](https://huggingface.co/ggml-org/InternVL3-2B-Instruct-GGUF/blob/f763aa88f2ad2dbd5246350660fec7d50a20a7b0/InternVL3-2B-Instruct-Q4_K_M.gguf), [InternVL3 Q8_0 projector](https://huggingface.co/ggml-org/InternVL3-2B-Instruct-GGUF/blob/main/mmproj-InternVL3-2B-Instruct-Q8_0.gguf). Their combined size is about 1.46 GB; “roughly 1.4 GB” is acceptable coarse rounding, while approximately 1.5 GB is closer to the listed total.
- Liquid AI documents LFM2-VL-1.6B as a 1.2B hybrid convolution-attention language model plus a 400M SigLIP2 NaFlex encoder. It uses a two-layer MLP connector with pixel unshuffle: [official LFM2-VL card](https://huggingface.co/LiquidAI/LFM2-VL-1.6B), [Transformers LFM2-VL documentation](https://huggingface.co/docs/transformers/model_doc/lfm2_vl).
- The official Q8_0 projector is currently listed at 564 MB: [LFM2-VL Q8_0 projector](https://huggingface.co/LiquidAI/LFM2-VL-1.6B-GGUF/blob/main/mmproj-LFM2-VL-1.6B-Q8_0.gguf). This is consistent with the session's approximate 0.54 GB figure after rounding and possible revision differences.
- Only the Eagle2-labelled run has a clean allocator tombstone in the evidence collected here. The LFM2 notes say the GPU-enabled path crashed and that forcing `gpuLayers=0` stopped it. That supports pointing to the GPU-enabled path, but not presenting Eagle2's stack as an LFM2 log or claiming an identical root cause.

### Runtime packaging and current ecosystem

- Current LlamaDart documentation confirms automatic chat-history and context-window management through `ChatSession`: [LlamaDart API documentation](https://pub.dev/documentation/llamadart/latest/llamadart/). Its published documentation did not verify the previously claimed exact 10% context reserve, so that number was removed from the narrative.
- Current LlamaDart releases allow applications to select whole runtime families and llama.cpp backend modules. Unset configuration includes all runtime families available for the target, while `llamadart_native_runtimes` and `llamadart_native_backends` can trim them: [LlamaDart 0.8.12 documentation](https://pub.dev/packages/llamadart/versions/0.8.12). Mero's approximately 149 MB APK is therefore a measurement of its tested default configuration, not an unavoidable package floor.
- llama.cpp documents `--no-mmproj-offload` as keeping the multimodal projector off the GPU: [multimodal documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md). The documentation does not say it fixes Mero's Adreno crash. It is a possible diagnostic, not a demonstrated workaround.
- llama.cpp's OpenCL documentation establishes an Adreno-oriented backend and optimized kernels: [OpenCL backend documentation](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md). The search did not find a primary source for the earlier anecdote that this backend garbled Qwen2.5-VL and was subsequently fixed, so that anecdote should remain excluded.
- Google's Android LLM Inference guide marks the MediaPipe API as maintenance-only, recommends LiteRT-LM for new Android work, and documents image input for Gemma 3n via `MPImage`: [Android multimodal guide](https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference/android). This offers a supported multimodal route but remains unvalidated in Mero.
- Google's standard Gemma 3n E2B int4 LiteRT-LM file is approximately 3.66 GB: [Gemma 3n E2B files](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/tree/main). It does not solve Mero's storage target.

### Scope and wording conclusions supported by the pass

- The article can say that runtime compatibility caused many failures in this stack. It cannot reduce the full result to “the runtime, not the model,” because the recorded blockers also include unreliable output, incomplete artifacts, native instability, and deployment footprint.
- Flux should be described as public implementation evidence unless its run was independently reproduced.
- The FastVLM macOS report and Mero's Android crashes should not be combined into a claim that device-specific causation is unlikely; their symptoms differ.
- “Those failures do not by themselves establish a limitation of SmolVLM” is supported. “None of that says anything about SmolVLM” is too categorical because the failures still describe compatibility in a particular route and version.
- Exact tested package versions, artifact filenames, revisions, device hardware, Android version, and backend settings should accompany native-runtime conclusions. Current documentation can ground capability and present-day status but cannot fill historical version gaps.

## Reconciliation with the drafts

- The **committed post-mortems** (06-02) cover only the LiteRT era plus the first GGUF fallback, because they were written on 06-02. They do not include Eagle2, InternVL3, or LFM2-VL, which came later.
- The **`v1-smaller-vlm` draft** covers FastVLM, SmolVLM, Qwen3.5-0.8B, and Eagle2-1B, but flattens SmolVLM into one attempt (it was v1 + v2), merges the two Qwen3.5 runtime attempts into one, and omits Qwen3.5-0.8B-LiteRT, InternVL3-2B, LFM2-VL-1.6B, the Gemma revert, and Florence-2.
- Ordering: **FastVLM was actually the first model reached for** (session mention 2026-05-30 10:29 and first git commit `5be49f4` 05-31, both ahead of the SmolVLM commits on 06-01). The committed post-mortem narrates SmolVLM first, but the true sequence is FastVLM attempt 1 (05-31, engine created then mid-generation segfault) → SmolVLM v1 (native TFLite plugin: opcode/tensor/signature) → SmolVLM v2 (06-02: file-routing conflict, then `CompiledModel` invoke failure via `SmolVlmNativeEngine` at 00:49) → FastVLM attempt 2 (06-02 15:07, after preprocessing rework, dispatch `SIGSEGV` in `FillAttentionMask` during prefill on `libLiteRtLm.so`) → Qwen-LiteRT (06-02 18:04, image send refused) → GGUF (migration commit 22:11). The two crashes on 06-02 belong to different models: the 00:49 `Failed to invoke` crash routes through `SmolVlmNativeEngine` (SmolVLM v2), while the 15:07 `FillAttentionMask` dispatch segfault is on `flutter_gemma`'s LiteRT-LM path (`ModelType.general`, FastVLM's second run). The two eras overlap on 06-02: FastVLM's second attempt at 15:07 lands after the 11:24 flux pivot to GGUF, which is why in memory it sits almost inside the next era.

The conclusion in all versions holds and is stronger than any single draft states: six distinct models across nine distinct model-and-runtime pairs (ten runs counting FastVLM's two attempts), plus one uncommitted attempt, none replaced Gemma 4 E2B, and the project reverted to Gemma before pivoting to the v2 split.

## Log and branch index for deeper follow-up

- **Committed post-mortems**: `docs/reports/on-device-model-migration-lessons.md` and `...-comparison.md` at commit `9187c7d`, on branches `feature/eagle-bck` and `feature/eagagle-bck`.
- **Codex**: `2026/06/01/...02-18-38` (SmolVLM opcode/signature/`invoke` crash plus FastVLM's second-attempt `FillAttentionMask` prefill SIGSEGV, richest single file), `2026/06/05/...11-40-52` (FastVLM/TFLite), `2026/06/18/...23-26-17` and `2026/06/19/...18-47-10` (LFM2 Vulkan/Adreno, runtime decision, candidate survey, and the Talk2DINO `ConvInteger` fix landing as `1f6032f` then `b646c28`).
- **openclaw**: `2026-06-07T07-35-04...trajectory` (Eagle2 GGUF `ggml_backend_alloc` SIGSEGV), `2026-05-30T19-34-28 / 19-42-22 / 19-58-17` checkpoints and `d8332e41...` (early PlatformException/SIGSEGV/Vulkan/llama), `052c4164...` (the 06-02 `Failed to invoke` crash, labelled "FastVLM" in-session but routed through `SmolVlmNativeEngine`, i.e. SmolVLM v2), `13f77617...checkpoint` (Florence-2 request; also the Quaynor `uri_does_not_exist` analyze output), `49c29ded...trajectory` (06-02: the Qwen-LiteRT session, containing both the "Model URL is dead (404)" review with the correct `GabrieleConte` repo and `qwen35_mm_q8_ekv2048.litertlm` filename/size, and the 18:04 on-device logcat where the image send is refused).
- **Hermes**: the `request_dump_20260604_170959_ec61d6b2_*` cluster (a 2026-06-04 analysis session on the 06-02 `Failed to invoke` crash plus Vulkan/llama/mmproj; the crash is SmolVLM v2's, though the session discussed it under the FastVLM heading).
