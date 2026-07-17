---
title: When Smaller Means Harder
description: A developer diary from ten on-device runs across six model families in the search for a smaller Mero runtime.
type: article
url: /articles/on-device-model-migration-lessons/
date: 2026-06-20
article_label: Developer diary
article_topic: On-device model migration
---

# When Smaller Means Harder: The Full Story of Trying to Shrink Mero - a Developer Diary

[← Mero home](https://atnanahidiw.github.io/sirkulab-mero/) · [Canonical research notebook and source logs](https://github.com/atnanahidiw/sirkulab-mero/tree/docs/docs/00_smaller-footprint-pipeline)

> This is the complete account of one question: can a smaller on-device model replace Gemma 4 E2B in Mero without giving up what makes the app work? Across ten runs on one Android phone and one Flutter stack, the answer was no. Six named model families were wired and tested across nine artifact-and-runtime configurations, a seventh was attempted off the record, and several more were reviewed on paper. Runtime compatibility caused most of the failures. Candidates that did run still hit limits in capability, context, maintenance, or total footprint. This is not evidence that small VLMs never work. It is a case study of what broke in this deployment stack as the model footprint shrank.
> 
> Part of the reason to write it all down, crash logs and all, is that someone else is probably about to walk a version of this same path: a small team wanting to shrink an on-device model without breaking what makes their app work. They shouldn't have to rediscover every one of these walls blind. If you're that person, this is the map as we actually found it, not the tidied-up version. And if you can see a better way through any of it, that's exactly the kind of feedback worth having. Question the calls made here, and say so.

Mero began with a simple goal: help children in Indonesia's remote, biodiversity-rich regions learn about the species living around them and why they need protecting. Many of these students grow up beside forests, coastlines, wetlands, and endemic wildlife, but far from reliable internet or updated materials. Mero closes that gap with an offline Android app that turns a phone into a local biodiversity tutor.

As the app grew, a second purpose appeared. If Mero shows how it reaches an answer, it teaches more than biodiversity. When the app observes visual clues, searches local data, compares candidates, checks evidence, and admits uncertainty, students can watch AI stop being magic and become what it actually is: reasoning from imperfect information.

Gemma 4 E2B is what made that flow possible, and it set the bar. Mero needs a model that can understand an image, reason over text across several steps, call local tools, explain science in plain language, and run on-device so no student data leaves the phone. Gemma does all five. Its one sin is size: roughly 2.6 GB as a `.litertlm` bundle. On the cheap Android phones Mero is built for, whose storage is already carved up between the OS, other apps, and downloaded content, that is a heavy ask. A smaller model would download faster, store smaller, start quicker, and reach more classroom phones.

Those requirements needed pinning down, or the bar stays abstract. What counted as passing, for every candidate in this account:

- Load reliably, without a native crash.
- Accept a real photo, not a canned description of one.
- Produce a valid, structured tool call the app can act on.
- Hold enough context for an image and a running conversation at the same time.
- Return taxonomy plausible enough to keep.
- Produce an explanation a student in the target age group can follow, grounded in the retrieved facts. (No candidate below got far enough for this bar to bite, but it is part of the replacement bar all the same.)
- Fit the storage budget of a low-cost classroom phone.

And the test environment behind every run, held constant so the failures are comparable:

- Runtimes as each era demanded: `flutter_gemma` 0.15.0 on the LiteRT-LM path, AI Edge LiteRT 2.1.0 for the hand-built SmolVLM plugin, then `llamadart` (llama.cpp over FFI) and Quaynor in the GGUF era.
- Roughly a 2,048-token context window once an image and a conversation share it.
- GGUF language models tested mostly at Q4_K_M (Q4_0 for Eagle2 and LFM2-VL); LiteRT and TFLite candidates used whatever quantization their published packages shipped, q8 in SmolVLM's case.

The test was worth running because size was only one requirement. A replacement also had to see a species, reason through the identification, call local tools, and explain the result to a teenager. A multimodal model in the few-hundred-megabyte range that could do all of that on-device would have solved the footprint problem without changing Mero's architecture. What follows is why none of these candidates cleared that bar.

## Era A: keep the trusted runtime, change only the model

The cheapest version of the bet keeps everything and just points the runtime at a smaller model. Gemma 4 E2B runs through Google's LiteRT-LM stack via the `flutter_gemma` plugin, a path that already works. If a small model could drop into that same flow, we were done. So the search started there, and it stayed there for three models before we accepted that the runtime, not the model, was the enemy.

### FastVLM first, and the wall it hit

FastVLM-0.5B was picked for a specific reason, not at random. The starting question was blunt: what is the smallest multimodal model that still ships as a `.litertlm` bundle, so the app can shrink its footprint without leaving the LiteRT runtime Gemma 4 already ran on? It also had a second point in its favor: `flutter_gemma` itself documents a short list of non-Gemma models it supports at all (FastVLM 0.5B, Qwen3 0.6B, Qwen 2.5, Phi-4 Mini, DeepSeek R1, SmolLM 135M). Its [version 0.15.0 capability table](https://github.com/DenisovAV/flutter_gemma/blob/v0.15.0/README.md#model-capabilities) marks FastVLM as vision-capable but without function calling. Of that whole list, FastVLM was the only non-Gemma model with a documented image path, which made it the safest first test despite the missing tool support.

It got far enough to test the idea: through the `.litertlm` path the engine initialized, took the image, and began generating. Then it died mid-generation, a native crash on the engine thread:

<details>
<summary>Log: FastVLM segfault mid-generation</summary>

```
05-31 03:26:54.918 I/flutter (21151): ── Custom generation pass 1 ──
05-31 03:26:54.921 I/flutter (21151): InferenceChat: Starting to iterate over native tokens...
05-31 03:27:04.471 F/libc    (21151): Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb400007313b4c000 in tid 22170 (engine/22170), pid 21151 (m.sirkulab.mero)
```

</details>
<br>

Loaded, started, gone: it built an engine, took the image, and segfaulted mid-sentence in the native `engine` thread. That was the first of two FastVLM attempts; it would come back later, once its image preprocessing was rebuilt. For now, rather than keep wrestling an unstable model, the search went looking for something smaller still.

### SmolVLM, off the documented path

SmolVLM-256M-Instruct was the smallest verifiable multimodal model still standing, a 256M-parameter vision-language model whose card said it could run a single image in under a gigabyte of GPU RAM. But unlike FastVLM, SmolVLM wasn't on `flutter_gemma`'s supported list at all, so this attempt meant stepping outside the plugin's documented models from the very first line of code.

That showed immediately. In the tested configuration the stock plugin routes simply did not fit this artifact: the MediaPipe route stopped at native-library loading, the LiteRT route hit an API mismatch. Both failures hang on the selected engine, package versions, model format, and native ABI — none of that, by itself, says anything about SmolVLM. A third build surfaced the problem that actually mattered for a vision app: the assembled graph had no image input.

<details>
<summary>Log: model does not expose a pixel_values input</summary>

```
05-31 19:46:20.343 22603 22603 I flutter : Progress: Tokenizing prompt... (0.2)
05-31 19:46:21.785 22603 22603 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Model does not expose a pixel_values input.
05-31 19:46:21.785 22603 22603 I flutter : [AnalyzingPage] identifySpecies failed: Exception: Model does not expose a pixel_values input.
```

</details>
<br>

Whatever the individual causes, the stock plugin routes never assembled a working vision path for this artifact. The next morning we stopped leaning on them and wired SmolVLM as a native Android plugin by hand (`53157e3`): a `.tflite` file and a separate tokenizer, Flutter talking to Kotlin over a method channel, the Android side owning model loading, tokenization, image packing, and inference. That plugin broke in a cascade that, in hindsight, was the whole era in miniature. The first real stop was the model's own tokenizer, which would not install because the SentencePiece native library was not built for the phone's architecture:

<details>
<summary>Log: SentencePiece JNI library missing for Android</summary>

```
06-01 07:57:46.392 23419 23419 I flutter : Model installation failed: PlatformException(native_error, Cannot copy jni files, java.lang.IllegalStateException: Cannot copy jni files
06-01 07:57:46.392 23419 23419 I flutter :  at ai.djl.sentencepiece.jni.LibUtils.copyJniLibraryFromClasspath(LibUtils.java:74)
06-01 07:57:46.392 23419 23419 I flutter : Caused by: java.io.IOException: Resource not found in classpath: native/lib/linux-aarch64/libsentencepiece_native.so
```

</details>
<br>

The DJL SentencePiece library only shipped a Linux JNI binary, not an Android one. The way out was to stop forcing that native library onto the phone at all: move tokenization into pure Dart via `dart_sentencepiece_tokenizer` and narrow the plugin's contract so the Android side never touches text, only token IDs, which deleted the bad JNI path entirely (`0ca1936`, hardened later in `4bd3b74`):

<details>
<summary>Fix: tokenize in Dart, hand the plugin token IDs only</summary>

```yaml
# pubspec.yaml — a pure-Dart tokenizer, no JNI to copy
dependencies:
  dart_sentencepiece_tokenizer: ^1.3.2
```

```diff
- fun installModel(modelPath: String, tokenizerPath: String)
- fun generate(modelPath: String, tokenizerPath: String, prompt: String, ...)
+ fun installModel(modelPath: String)
+ fun generate(modelPath: String, inputIds: IntArray, ...)
```

</details>
<br>

Past the tokenizer, later that same morning, came the hardest stretch. A run of ordinary mismatches got corrected one at a time, and what was left standing at the end was decode: this integration never saw the logits an autoregressive loop needs.

The prompt overflowed the model's prefill budget first:

<details>
<summary>Log: prompt too long for the fixed prefill signatures</summary>

```
SmolVLM prompt is too long for the available prefill signatures. Tokens=1531, max_supported=1280.
```

</details>
<br>

The exported graph only ships fixed-size prefill signatures, so anything past 1,280 tokens has nowhere to go. The fix was to measure the prompts against the real SmolVLM tokenizer and cut until a full identify transcript came in around 821 tokens, comfortably under the ceiling. Most of the fat was in the tool definitions (`3e50a4c`).

Then the picture arrived in the wrong tensor shape:

<details>
<summary>Log: 5D image tensor rejected</summary>

```
Unsupported image tensor shape: [1, 1, 3, 512, 512]
```

</details>
<br>

The graph declares a 5D image input with singleton leading dimensions, and the native code had been pattern-matching on the 4D shape it expected and rejecting everything else. The fix (`0f2b29b`) was to stop caring about the declared shape at all: size the buffer by the signature's element count and fill it as one flat channels-first array, letting the singleton dimensions collapse on their own:

<details>
<summary>Fix: fill the image buffer by element count, not declared shape</summary>

```kotlin
// SmolVlmNativePlugin.kt — a [1,1,3,512,512] tensor is just
// 3*512*512 floats in CHW order; write them flat
val required = elementCount(model, name, signature)
val floats = FloatArray(required)
val channelStride = side * side
for (y in 0 until side) {
    for (x in 0 until side) {
        val color = resized.getPixel(x, y)
        val r = (Color.red(color) / 255.0f - 0.5f) / 0.5f
        val g = (Color.green(color) / 255.0f - 0.5f) / 0.5f
        val b = (Color.blue(color) / 255.0f - 0.5f) / 0.5f
        val base = y * side + x
        floats[base] = r
        if (channelStride + base < floats.size) floats[channelStride + base] = g
        if (channelStride * 2 + base < floats.size) floats[channelStride * 2 + base] = b
    }
}
```

</details>
<br>

Then decode choked on an input the app had been passing unconditionally:

<details>
<summary>Log: decode rejects the mask input</summary>

```
Decode signature 'decode' has an unsupported input 'mask'.
```

</details>
<br>

Some exports of this graph declare a `mask` input and some do not. The fix (`4bd3b74`) was to inspect the signature and bind a mask only when that signature declares one.

A later log reflected another wrong assumption in the integration: it reached for logits from prefill, but the prefill signature returned KV caches instead:

<details>
<summary>Log: prefill signature missing the expected logits output</summary>

```
Prefill signature 'prefill_256_pixel' is missing logits output. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
```

</details>
<br>

That prefill behavior is not a model defect — a prefill signature may legitimately return only KV caches — so the integration was corrected to bind those outputs by name and ask decode, not prefill, for the token-selection logits. Decode still appeared to return only KV-cache tensors in this run, leaving the loop no logits to select the next token from:

<details>
<summary>Log: decode signature did not return logits</summary>

```
06-01 11:35:15.979 13253 13253 I flutter : [identifySpecies] Identification failed (model is fine): PlatformException(native_error, Decode signature 'decode' did not return logits. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
06-01 11:35:15.979 13253 13253 I flutter : 	at com.sirkulab.mero.SmolVlmNativeEngine.generate(SmolVlmNativePlugin.kt:186)
06-01 11:35:15.980 13253 13253 I flutter : [AnalyzingPage] identifySpecies failed: PlatformException(native_error, Decode signature 'decode' did not return logits. Available outputs: [kv_cache_k_0, kv_cache_k_1, ...]
```

</details>
<br>

The [official LiteRT Community runner](https://huggingface.co/litert-community/SmolVLM-256M-Instruct/blob/main/test_tflite.py) reads logits from every decode result and discards prefill logits if present. That makes the missing-logits observation a failure of this tested integration, not a demonstrated property of SmolVLM or the export in general. The file revision, output introspection, buffer binding, or runtime API could each explain the discrepancy. Prompt sizing, image layout, mask binding, and prefill handling were corrected; the decode path remained unresolved.

The second version, the next day, adopted the runtime's own packaging. It moved to the `.litertlm` bundle, pulled tokenizer handling into Dart, thinned the native glue, and switched Android from TensorFlow Lite to AI Edge LiteRT. This path failed differently. It first disagreed about how the bundle should be loaded:

<details>
<summary>Log: runtime disagrees on how to load the bundle</summary>

```
E flutter : [ERROR:flutter/runtime/dart_vm_initializer.cc(40)] Unhandled Exception: PlatformException(IllegalArgumentException,
java.lang.IllegalArgumentException: smalvlm-256m-instruct_q8_ekv2048_single_image.litertlm is a LiteRT-LM model — it should be handled by Dart FFI (LiteRtLmFfiClient), not by EngineFactory.,
Cause: null, Stacktrace: java.lang.IllegalArgumentException)
```

</details>
<br>

Routing the bundle the way the runtime asked, through the Dart FFI client, settled the disagreement, and both routes got tried in the process. Through the native engine, now on AI Edge LiteRT's `CompiledModel`, an earlier build could not even find the signature the app asked for; replacing the hardcoded signature names with the model's documented ones and binding named I/O buffers, the same contract-discovery work from v1, cleared that. It still would not invoke:

<details>
<summary>Log: signature not found, then failed to invoke compiled model</summary>

```
06-02 00:06:02.432 11778 11778 I flutter : └ Signature not found, com.google.ai.edge.litert.LiteRtException: ERROR: [./third_party/odml/litert/litert/cc/litert_compiled_model.h:197]
06-02 00:49:59.179 21597 21597 I flutter : [identifySpecies] Identification failed (model is fine): PlatformException(native_error, Failed to invoke the compiled model, com.google.ai.edge.litert.LiteRtException: Failed to invoke the compiled model
06-02 00:49:59.179 21597 21597 I flutter :  at com.google.ai.edge.litert.CompiledModel.nativeRun(Native Method)
06-02 00:49:59.179 21597 21597 I flutter :  at com.google.ai.edge.litert.CompiledModel.run(Model.kt:446)
06-02 00:49:59.179 21597 21597 I flutter :  at com.sirkulab.mero.SmolVlmNativeEngine.runModel(SmolVlmNativePlugin.kt:394)

```
</details>
<br>

A note on `(model is fine)`, since it appears in that log and on nearly every failure in this story: it is not a runtime verdict. It is a string hard-coded into Mero's own error logging, written back when the assumption was that any failure would be plumbing (a download, a path, a tokenizer) rather than the model itself. So the app prints its hopeful label, and the very next line shows a failure it had no way to predict. Read it as a small fossil of what we believed at the start.

The two versions did not fail the same way. The TFLite integration did not observe decode logits. The later LiteRT `CompiledModel` route found the documented signatures after its bindings were corrected, then failed while invoking the model. Both blocked generation, but the logs do not establish a single shared cause.

### FastVLM, one more time

FastVLM had not been abandoned. The image preprocessing was rebuilt around the square 1024-pixel crop expected by the model. A few days later it ran again through `flutter_gemma`'s LiteRT-LM engine (`ModelType.general`, `libLiteRtLm.so`). It segfaulted during prefill:

<details>
<summary>Log: FastVLM second crash, segfault during prefill attention-mask fill</summary>

```
06-02 15:06:59.328 29903       E/litert: No dispatch library found in /storage/emulated/0/Download
06-02 15:06:59.328 29903       E/litert: Failed to initialize Dispatch API
06-02 15:07:02.051 29903       F/libc: Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0xb4000073f40ed000 in tid 30407 (engine/30407), pid 29903 (m.sirkulab.mero)
06-02 15:07:02.469 30559      F/DEBUG: pid: 29903, tid: 30407, name: engine/30407  >>> com.sirkulab.mero <<<
06-02 15:07:02.469 30559      F/DEBUG: #00 libLiteRtLm.so
06-02 15:07:02.469 30559      F/DEBUG: #01 libLiteRtLm.so litert::lm::FillAttentionMask(...)
06-02 15:07:02.469 30559      F/DEBUG: #02 libLiteRtLm.so litert::lm::LlmLiteRtCompiledModelExecutorBase::PrefillInternal(...)
06-02 15:07:02.469 30559      F/DEBUG: #05 libLiteRtLm.so litert::lm::Prefill(...)
06-02 15:07:02.469 30559      F/DEBUG: #06 libLiteRtLm.so litert::lm::SessionBasic::PrefillInternal(...)
06-02 15:07:02.469 30559      F/DEBUG: #08 libLiteRtLm.so litert::lm::ThreadPool::RunWorker(...)
```

</details>
<br>

The crash surfaced on a worker thread inside `libLiteRtLm.so`, in `FillAttentionMask` during prefill. That stack shows where the failure surfaced, not whether the root cause was the runtime, the model file, or the integration. It was a native crash rather than a Dart exception the app could catch. We checked the dispatch-library warnings that appeared just before the segfault and forced the CPU backend, the same setting that would later let LFM2 load. Neither change stopped this FastVLM crash.

Mero was not the only project to report trouble with this combination. In `flutter_gemma` [issue #268](https://github.com/DenisovAV/flutter_gemma/issues/268), FastVLM-0.5B on a Mac Mini M4 and plugin version 0.15.0 produced garbled special-token strings such as `<start_of_9!!!<start_of_something!!!...` with both image and text-only prompts. Gemma 4 E2B worked on the same machine through the same plugin. Mero's log showed another possible mismatch: immediately before the segfault, the plugin wrapped the FastVLM prompt in Gemma chat-template tokens.

<details>
<summary>Log: Gemma chat-template tokens fed to FastVLM right before the crash</summary>

```
06-02 16:16:51.706 I/native  ( 9494): [InputImage]
06-02 16:16:51.706 I/native  ( 9494): <end_of_turn>
06-02 16:16:51.706 I/native  ( 9494): <start_of_turn>model
06-02 16:16:51.709 F/libc    ( 9494): Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 9563 (DefaultDispatch), pid 9494 (m.sirkulab.mero)
```

</details>
<br>

`<end_of_turn>` and `<start_of_turn>` are Gemma turn markers, not FastVLM turn markers. The timing makes template handling a plausible contributor, but the logs do not establish a cause. Image preparation, runtime dispatch, or an interaction among them could also be involved. The macOS report and Mero's Android runs make a device-specific explanation less likely. Both Mero attempts used `flutter_gemma`'s LiteRT-LM path and ended in native segfaults, one during generation and one during prefill.

### Qwen on LiteRT, the last straw

The final LiteRT attempt used `GabrieleConte/Qwen3.5-0.8B-LiteRT`, a preconverted multimodal `.litertlm` bundle (`qwen35_mm_q8_ekv2048.litertlm`, about 1.2 GB) containing the language model, vision components, and tokenizer. It ran on the device through a second plugin, `flutter_litert_lm`, but was not committed. The bundle downloaded and loaded. Attaching a photo then produced this error:

<details>
<summary>Log: configured conversation expected no image slots</summary>
```
06-02 18:04:57.787 2170 2170 I flutter : [AnalyzingPage] identifySpecies failed: PlatformException(MESSAGE_ERROR, Failed to call nativeSendMessage: INVALID_ARGUMENT: Provided more images than expected in the prompt., com.google.ai.edge.litertlm.LiteRtLmJniException: Failed to call nativeSendMessage: INVALID_ARGUMENT: Provided more images than expected in the prompt.
06-02 18:04:57.787 2170 2170 I flutter : at com.google.ai.edge.litertlm.LiteRtLmJni.nativeSendMessage(Native Method)
06-02 18:04:57.787 2170 2170 I flutter : at com.google.ai.edge.litertlm.Conversation.sendMessage(Conversation.kt:103)
06-02 18:04:57.787 2170 2170 I flutter : at com.songhieu.flutter_litert_lm.FlutterLitertLmPlugin$handleSendMessage$1.invokeSuspend(FlutterLitertLmPlugin.kt:174)
```
</details>
<br>

"Provided more images than expected" shows that the configured conversation expected zero image slots. It does not explain why. The [artifact card](https://huggingface.co/GabrieleConte/Qwen3.5-0.8B-LiteRT) says the bundle contains a language model, vision encoder, vision adapter, and tokenizer. Missing image placeholders, chat-template handling, multimodal metadata, or plugin routing could all produce the observed mismatch. This run establishes only that the selected plugin and conversation configuration could not attach an image to the bundle.

The three LiteRT attempts stopped at different points. FastVLM segfaulted twice, once during generation and once during prefill. The two SmolVLM integrations ended at decode and model invocation. The Qwen conversation expected no image slots. These results do not identify one common defect, but they do show that none of the tested non-Gemma routes produced a stable multimodal session in this Flutter and Android setup.

## Era B: if the runtime is the wall, change the runtime

After the LiteRT attempts failed, we switched runtimes. What made the decision concrete was finding `github.com/Finn-Technologies/flux`, an Android app already running Qwen 3.5 vision through llama.cpp — public, working proof that the same model family could process images on Android through GGUF weights and a multimodal projector. Mero adopted that runtime path. Vision worked; what stopped this era was a combination of unreliable output, incomplete artifacts, native instability, and deployment footprint.

### Qwen on GGUF: it finally sees

Qwen3.5-0.8B in GGUF, with its `mmproj` projector, run through LlamaDart (llama.cpp over FFI), did the thing no LiteRT attempt had managed. It looked at the photo and described what was actually in it, not a summary someone handed it. That was real.

The search focused on a practical question: had any Android project made Qwen 3.5 process an image? Flux had. It is an offline Android assistant built on `llamadart`, with GGUF downloads and `mmproj` vision projectors. Its README covered both Qwen 3.5 and a Gemma 4 build. The lightest configuration, "Flux Lite," paired Qwen 3.5 0.8B with a projector at a published size of about 533 MB. Mero tested a different combination: a Q4_K_M language model with an F16 projector, which brought its download to about 900 MB. Flux was still enough evidence to test the same runtime path in Mero.

Mero borrowed the runtime path, not Flux's full application architecture. We added `llamadart`, replaced LiteRT-LM with GGUF weights and a projector, and kept Mero's `ModelRuntime` interface. Flux also separates its catalog, downloads, selected-model state, inference, and chat session. Mero did not need that structure for a single-purpose species app. The smaller change was enough to get image input working and expose the next problems: footprint, output quality, and native stability.

Getting the model to run turned out to be only the entry fee. Once it was running, a new class of challenge opened up: what the model actually produced. Each difficulty got its own fix before the next one surfaced. The first was degenerate repetition: in thinking mode the model would collapse into emitting the same token forever, the canonical case being a model chanting `Quadri Quadri Quadri...` without end, which the app surfaced to the user as "Model entered a repetition loop. Please try again."

The answer was a repetition-loop detector, added specifically for Qwen's thinking mode at 0.8B: it watches the token stream, trips when it sees a run of six or more identical consecutive tokens, and throws the whole response away rather than letting the app hang:

<details>
<summary>Fix: detect a run of repeated tokens and bail out before it hangs the app</summary>

```dart
/// Returns true when [text] contains the same whitespace-separated token
/// at least [threshold] times in a row, for example "Quadri Quadri Quadri...".
bool _isRepetitionLoop(String text, {int threshold = 6}) {
  if (text.isEmpty) return false;
  final tokens = text.trim().split(RegExp(r'\s+'));
  if (tokens.length < threshold) return false;
  int run = 1;
  for (int i = 1; i < tokens.length; i++) {
    if (tokens[i] == tokens[i - 1]) {
      run++;
      if (run >= threshold) return true;
    } else {
      run = 1;
    }
  }
  return false;
}
```

</details>
<br>

That worked, and something else immediately took its place. The on-device context window, advertised in the app as roughly 2048 tokens, was often simply too small to hold an image and a running conversation at once:

<details>
<summary>Log: context window too small for image and history</summary>

```
06-02 22:09:44.094  9825  9825 I flutter : ── Native tool session pass 4 ──
06-02 22:09:44.094  9825  9825 I flutter : Progress: Generating result... (0.75)
06-02 22:09:52.448  9825  9825 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Multimodal prompt evaluation failed: 1. The active context window may be too small for this image and conversation history.
```

</details>
<br>

Two changes reduced the overflows. LlamaDart's [`ChatSession`](https://pub.dev/packages/llamadart/changelog) automatically managed history against the context window and used sliding-window truncation to drop older turns as the context filled. That controls the text history, but not the image token cost, which scales with pixel count in this runtime. Shrinking the picture made enough room for an image and a tool conversation. It also removed details such as scale texture and fur patterns, and identification quality dropped in these runs. The context failures became less frequent, but the model had less visual information to work with.

In this quantized, on-device configuration, Qwen3.5-0.8B did not produce taxonomy reliably enough for Mero. The experiment does not separate model capacity from quantization, prompting, sampling, and runtime effects. That distinction matters because the [official Qwen3.5-0.8B card](https://huggingface.co/Qwen/Qwen3.5-0.8B) positions the checkpoint for prototyping, task-specific fine-tuning, and research or development. In one run, a scaly, elongated, striped animal produced this tool call:

<details>
<summary>Log: confidently wrong taxonomy tool call</summary>

```
06-02 23:56:27.721 29205 29205 I flutter : [Pass 1] Native tool call: search_similar_features
06-02 23:56:27.721 29205 29205 I flutter :   "visualGroup": "Primate",
06-02 23:56:27.722 29205 29205 I flutter :   "taxOrder": "Primates",
06-02 23:56:27.722 29205 29205 I flutter :   "taxFamily": "Eupodidae",
06-02 23:56:27.722 29205 29205 I flutter :   "taxGenus": "Varanus"
```

</details>
<br>

The result is internally inconsistent. It puts a reptile under Primates, pairs `Varanus` with the wrong order, and assigns Eupodidae, a [real family of mites](https://gd.eppo.int/taxon/1EUPOF), to a vertebrate genus. A duplicate-call guard rejected repeated, unchanged queries instead of allowing the model to loop on the same result. The existing parser also discarded tool responses that were not valid JSON. On a later pass over the same animal, the model returned `Panthera` as the genus and repeated the query until the duplicate guard stopped it:

<details>
<summary>Fix: reject a repeated identical tool call instead of letting the model spin</summary>

```dart
bool _isDuplicateSpeciesSearchCall(
  Map<String, dynamic> args,
  Set<String> requiredKeys,
) {
  final previous = _lastSpeciesSearchArgs;
  if (previous == null) return false;
  for (final key in requiredKeys) {
    final currentValue = _normalizedToolValue(args[key]);
    final previousValue = _normalizedToolValue(previous[key]);
    if (currentValue != previousValue) return false;
  }
  return true;
}

// ...
if (isDuplicateSearchCall) {
  final rejection = <String, dynamic>{
    'error': 'duplicate_call',
    'message': 'Rejected duplicate search. Change at least one required parameter.',
    'required_change': matchedSpec.requiredParameterNames.toList(growable: false),
  };
  // send `rejection` back to the model as the tool result and continue the loop
}
```

</details>
<br>

<details>
<summary>Log: garbage result detected and rejected</summary>

```
06-03 01:17:02.717 9359 9359 I flutter : ── Native tool session round 5 ──
06-03 01:18:11.122 9359 9359 I flutter : Progress: Complete (1.0)
06-03 01:18:11.147 9359 9359 I flutter : [identifySpecies] Garbage result detected — rejecting response.
06-03 01:18:11.152 9359 9359 I flutter : [identifySpecies] Identification failed (model is fine): Exception: Model returned an unparseable response.
```

</details>
<br>

> The guards caught malformed, repeated, and internally inconsistent outputs, but they could not make the classifications reliable. In this tested configuration, rejecting those results was safer than showing them to students. These runs do not isolate the cause. Model capacity, quantization, prompts, sampling, image compression, and runtime behavior all remain possible contributors.

### Eagle2: the most accessible path, and blind

Eagle2-1B was the most accessible path and briefly looked promising. [Quaynor](https://pub.dev/packages/quaynor) exposed a comparatively simple Flutter API and handled the tool loop internally. It could support multimodal GGUF models when given a compatible projector, but the Eagle2-labelled artifact shipped no projector or vision tensors. The artifact was about 360 MB and started faster with less memory than the other candidates. After a missing pubspec dependency and a model path were fixed, the text path ran. The full Eagle2 model is a VLM with a SigLIP vision encoder and a Qwen2.5-0.5B language component under NVIDIA's custom `eagle_2_5_vl` architecture. A llama.cpp [feature request opened on October 21, 2025](https://github.com/ggml-org/llama.cpp/issues/16704) documented that mmproj conversion did not support this architecture. The issue was later closed as stale without an implementation. Mero never reached that architecture because both passes, Quaynor and LlamaDart, downloaded `Mungert/Eagle2-1B-GGUF`'s `Eagle2-1B-q4_0.gguf`, which was not the full vision model.

The repository is easy to misread. [`Mungert/Eagle2-1B-GGUF`](https://huggingface.co/Mungert/Eagle2-1B-GGUF) uses the Eagle2 name, model card, image examples, and an Image-Text-to-Text tag. Its GGUF metadata, however, identifies plain `qwen2` at about 0.6B parameters, and the repository has no `mmproj` vision projector. The 4-bit files are 360 to 429 MB, consistent with the artifacts Mero downloaded. The surviving files contain Eagle2's text backbone, not the complete VLM. The repository history was later squashed, so this claim applies only to the files that remain available.

The LlamaDart pass died once in the tensor allocator with a null-pointer SIGSEGV in `ggml_backend_alloc_ctx_tensors_from_buft`, the allocator function later mentioned in the LFM2 session notes. At the time, we blamed unsupported Eagle2 vision tensors. The artifact metadata rules that explanation out: the file identified itself as plain `qwen2` and contained no vision tensors. The cause of this crash remains unresolved. It does not show that `eagle_2_5_vl` broke the loader or that the mobile GPU caused the failure. The upstream conversion issue documents the architecture gap, but this phone did not execute that architecture.

<details>
<summary>Earlier Eagle2-labelled artifact crash, included only to illustrate the allocator signature mentioned in the LFM2 notes</summary>

```
06-07 14:31:15.690 F/libc    (27648): Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 27721 (DartWorker), pid 27648 (m.sirkulab.mero)
06-07 14:31:15.966 F/DEBUG   (27742): Cause: null pointer dereference
06-07 14:31:15.966 F/DEBUG   (27742): #06 ... base.apk!libggml-base.so ... ggml_backend_alloc_ctx_tensors_from_buft+116
06-07 14:31:15.966 F/DEBUG   (27742): #07 ... base.apk!libllama.so ... llama_model_base::load_tensors(...)
06-07 14:31:15.966 F/DEBUG   (27742): #09 ... base.apk!libllama.so ... llama_model_load_from_file+220
```

</details>
<br>

The runnable artifact was text-only. To retain some visual grounding, the app used `package:image` to extract colour, brightness, and texture in Dart, then passed those traits as text. That let the pipeline run, but the language model never saw the pixels and could not correct errors from trait extraction. The accessible path was blind because of the artifact, not because Quaynor was limited to text.

### InternVL3 and LFM2-VL: the footprint was never just the model

The search then moved to larger models with complete vision paths. InternVL3-2B loaded successfully from `ggml-org/InternVL3-2B-Instruct-GGUF`: about 1.0 GB for the Q4_K_M language model and 0.3 GB for the Q8_0 projector. The photo passed through the vision encoder and projector, and LlamaDart's native tool calling was wired in. The roughly 1.4 GB combined footprint exceeded the classroom-phone budget, so the model was removed within a day. No latency, memory, or taxonomy-quality measurements were recorded in that short test.

The two final candidates were more different under the hood than their sizes suggest. InternVL3-2B pairs a 300M InternViT vision encoder with Qwen2.5-1.5B through a pixel-unshuffle MLP projector. LFM2-VL-1.6B pairs a 400M SigLIP2 NaFlex encoder with Liquid AI's 1.2B hybrid convolution-attention language model through a similar compressed projector. Both are complete modular VLMs; neither is a simple Qwen GGUF with an interchangeable image projector. The difference matters for runtime risk: InternVL3's language half is standard Qwen2.5, which llama.cpp already speaks, so its risk sat mostly in the vision side, while LFM2-VL needs specialized support for both its vision path and its unusual language backbone. LFM2-VL-1.6B, around 1.2 GB in total (Q4_0 model about 0.65 GB plus a Q8_0 projector about 0.54 GB), was the last serious swing.

The GGUF path also increased the APK itself. In Mero's default configuration, LlamaDart included all runtime families available for the target, including `libggml-vulkan.so` at about 50 MB, `libLiteRtLm.so` at about 25 MB, and more than 50 MB of Qualcomm QNN/NPU libraries. The release APK approached 150 MB before the model download was counted. Current LlamaDart releases let applications select runtime families and llama.cpp backend modules, so these figures describe Mero's tested default bundle rather than unavoidable package overhead.

On top of the footprint, the LFM2 session notes record a native tensor-allocation crash with the Vulkan path enabled and report that forcing the CPU backend made it stop. They do not contain a fresh LFM2 tombstone, so they do not support presenting an exact LFM2 stack trace or claiming that its crash was identical to Eagle2's. The CPU result is still useful evidence: changing `gpuLayers` to zero stopped the crash, which points to the GPU-enabled path without proving a more specific root cause. Because the failure was native, no Dart try/catch could catch it. The practical recourse was to force the model onto the CPU backend, giving up the GPU acceleration that motivated the llama.cpp path in the first place.

And forcing CPU did work, in the narrow sense: the segfault stopped, the model loaded, and it ran. But it ran the way you'd expect a 1.2 GB vision-language model to run with its GPU path switched off, noticeably slower than the GPU-accelerated LiteRT path Gemma 4 E2B had been using all along, on top of a model that was still 1.2 GB and an APK still carrying the full native tail described above. So the CPU fix didn't rescue LFM2, it just moved the failure from "crashes" to "loads, but slower than the thing it was supposed to replace, in an APK that's still too big." That distinction mattered: it's what turned this from "try yet another model" into "stop trying to fix this runtime path at all."

The tests ended for different reasons. None of the LiteRT integrations produced a stable non-Gemma multimodal session. On llama.cpp, LFM2's GPU-enabled path crashed, the Eagle2-labelled text artifact hit an unresolved allocator failure, and InternVL3 exceeded the footprint budget. Qwen ran but was not reliable enough in the tested configuration. Runtime failures were common, but they were not the only reason candidates were rejected.

## The models we only read about

Other candidates were reviewed without being built: MobileVLM V2, Granite Vision 2B, MiniCPM-V 4.6, Aquila-VL-2B, InternVL3.5-2B, and others. They are not counted as attempts.

Florence-2-base received one uncommitted run. It is a vision task model for captioning, detection, segmentation, and OCR rather than a conversational reasoner. Mero also needs multi-step comparison, tool use, and explanations, so Florence-2 did not meet the capability requirements. It is recorded here but not counted with the fully integrated candidates.

## The honest count

Six named model families were attempted across nine artifact-and-runtime configurations, or ten runs once FastVLM's two attempts are counted: SmolVLM-256M, FastVLM-0.5B, Qwen3.5-0.8B, Eagle2-1B, InternVL3-2B, and LFM2-VL-1.6B. "Artifact-and-runtime configuration" is the useful unit because several repositories did not contain the complete model their names implied. SmolVLM was tried as a `.tflite` file and a `.litertlm` bundle. Qwen3.5 was tried as LiteRT and GGUF. Eagle2's two runs used the same Eagle2-labelled Qwen2.5 text backbone from `Mungert/Eagle2-1B-GGUF`, first on Quaynor and then on LlamaDart. Florence-2 was an uncommitted seventh family, and Gemma was briefly restored between eras. None replaced Gemma 4 E2B.

One definition keeps the count auditable: a "run" means the artifact was installed on the phone and exercised far enough to produce the outcome recorded here, whether that outcome was a failure or a successful load later rejected for footprint. All ten runs left logs behind; every failure quoted above traces to a session transcript or a commit.

The whole experiment, in one table:

| Candidate | Runtime | Artifact size | Image input | Tool calls | Final result |
|---|---|---|---|---|---|
| FastVLM-0.5B | LiteRT-LM (`flutter_gemma`) | ~899 MB NPU / ~1.1 GB GPU | Accepted; reached generation and prefill | Unsupported by documented plugin capability | Native SIGSEGV, twice |
| SmolVLM-256M | TFLite native plugin, then LiteRT-LM | 288 MB (q8 bundle) | Accepted in the custom TFLite path; stock plugin path lacked a usable image input | Never reached | Decode outputs unresolved in TFLite integration; separate LiteRT invocation failure |
| Qwen3.5-0.8B (LiteRT) | LiteRT-LM (`flutter_litert_lm`) | ~1.2 GB (q8 bundle) | Conversation expected zero image slots; cause unresolved | Never reached | `INVALID_ARGUMENT: Provided more images than expected` |
| Qwen3.5-0.8B (GGUF) | llama.cpp (LlamaDart) | ~900 MB (Q4_K_M + mmproj-F16) | Yes, genuine vision | Yes, unreliable in tested runs | Taxonomy reliability, repetition, size |
| Eagle2-1B (text backbone) | Quaynor, then LlamaDart | ~360 MB (Q4_0) | No; artifact ships no vision tensors | Yes (Quaynor `Chat.ask()`) | Text-only proxy; premise lost |
| InternVL3-2B | llama.cpp (LlamaDart) | ~1.4 GB (Q4_K_M + Q8_0 mmproj) | Yes | Wired, not deeply evaluated | Dropped for footprint within a day |
| LFM2-VL-1.6B | llama.cpp (LlamaDart) | ~1.2 GB (Q4_0 + Q8_0 mmproj) | GPU crash; CPU-only load | Not evaluated | Slow on CPU; footprint and APK bloat |

## Did the ecosystem catch up?

Runtime support changed after these tests, but the new options do not yet establish a smaller replacement for Mero.

- llama.cpp documents [`--no-mmproj-offload`](https://github.com/ggml-org/llama.cpp/blob/master/docs/multimodal.md) as a way to keep the multimodal projector off the GPU while leaving language-model offload enabled. The documentation does not say that it fixes this Adreno crash. It would be a useful diagnostic in a new test, not a demonstrated remedy for the failure recorded here.
- llama.cpp now has an [OpenCL backend](https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md) designed first for Qualcomm Adreno GPUs, with optimized kernels for supported devices and quantizations. The official documentation establishes backend support, but not stable multimodal behavior for Mero's models. It is another path to test rather than evidence that the recorded crashes have been fixed.
- Google's [MediaPipe LLM Inference guide for Android](https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference/android) documents image input for Gemma 3n by converting a bitmap to `MPImage` and enabling vision modality. Google now describes this API as maintenance-only and recommends LiteRT-LM for Android projects. It is a supported multimodal route, though still unvalidated in Mero, and the guide provides neither a Flutter binding nor Mero's tool-calling flow. The official Gemma 3n E2B repository lists the standard int4 LiteRT-LM file at [3.66 GB](https://huggingface.co/google/gemma-3n-E2B-it-litert-lm/tree/main), which is still above Mero's storage target.
- LLaVA ([llava-vl.github.io](https://llava-vl.github.io)), MobileVLM ([github.com/Meituan-AutoML/MobileVLM](https://github.com/Meituan-AutoML/MobileVLM)), SmolVLM ([huggingface.co/blog/smolvlm](https://huggingface.co/blog/smolvlm)), InternVL3, and LFM2-VL pair a vision encoder with a language model through a learned projector. Mero's next architecture uses a stricter boundary: the vision system runs independently and returns discrete traits and evidence scores through tools. Those VLMs support the general idea of separate components, but they do not validate Mero's tool-mediated design.

The experiment narrowed the design space without producing a smaller replacement for Gemma 4 E2B. A viable successor must clear three independent bars: a stable Android vision runtime, enough reasoning and domain knowledge for species identification, and a total deployment footprint suitable for low-cost classroom phones.

The failed model search also showed where to look next. Eagle2, InternVL3, and LFM2-VL all follow the same broad pattern: a dedicated vision encoder paired with a smaller language model. Their implementations join the two through a learned projector and run them as one integrated VLM. That shared pattern suggested a different direction for Mero, adapted to the constraints exposed by these Android experiments. The details belong to the next chapter. Whether that direction can replace Gemma 4 E2B remains an empirical question.
