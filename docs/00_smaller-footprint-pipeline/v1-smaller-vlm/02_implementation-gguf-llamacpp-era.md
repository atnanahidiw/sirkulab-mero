# 02 · Implementation log · Era B: GGUF / llama.cpp (abandon LiteRT-LM)

**Status:** 🔴 open log · currently exhausted, reopen by appending below.
**Owns (at the time):** `model_service.dart`, `model_runtime.dart` (moved to `LlamaDartModelRuntime` / Quaynor), Android native build (per-ABI llama.cpp)
**Theme:** if the runtime is the bottleneck ([Era A](01_implementation-litert-lm-era.md)'s conclusion), change the runtime instead of the model. GGUF via llama.cpp brings quantized weights, `mmproj` multimodal projectors, and a broad ecosystem.

**How to use this doc.** Running log, newest entry at the bottom. Append a dated entry per attempt, update **Where this stands** when the picture moves, and keep **Open threads** current. The last entry is a periodic state-of-the-art check, which is itself an appended result and should be re-run and re-appended over time. Verbatim log lines, commits, and sources are in [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md).

---

## Where this stands (updated 2026-07-14)

Four GGUF attempts (Qwen3.5-GGUF, Eagle2-1B, InternVL3-2B, LFM2-VL-1.6B). Vision grounding is achievable, but every candidate is disqualified: Qwen-GGUF ran and saw the image but was heavier than the target (~900 MB, versus the few-hundred-MB SmolVLM path) with per-ABI build cost and unreliable taxonomy; Eagle2's vision arch would not load, leaving only a blind text backbone; InternVL3 and LFM2-VL were over 1 GB and LFM2-VL also hit an uncatchable native GPU crash. Latest check (2026-07-14 entry below): the runtime ecosystem improved slightly but VLM-on-mobile-GPU is still fragile, and the only first-party multimodal path (MediaPipe / Gemma 3n) is both too big (~3.7 GB) and unvalidated in Mero's Flutter and tool-calling flow. Verdict unchanged: v1 stays retired.

---

## Attempts ledger (Era B)

Verdict key: ❌ blocked · ⚠️ ran but disqualified. Full stacktraces and sources live in [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md); the dated prose entries are under **Log** below.

| # | Date | Model | Size | Format / runtime | Branch / commit | Wall hit | Verdict |
|---|---|---|---|---|---|---|---|
| 5 | 06-02 | Qwen3.5-0.8B-GGUF (unsloth) | 0.8B | GGUF Q4_K_M + mmproj-F16 / LlamaDart | feature/qwen · 9187c7d, 95c3baa | runs and sees the image, but ~900 MB (heavier than the SmolVLM target), per-ABI native builds, manual tool loop, and unreliable taxonomy | ⚠️ |
| 6 | 06-07 | Eagle2-1B | 1B | GGUF q4_0 / Quaynor then LlamaDart | feature/eagle · 0617fbf, bc76af4 | one artifact (`Mungert` q4_0 — actually a plain `qwen2` Qwen2.5-0.5B text backbone under Eagle2's label, no vision tensors) on two runtimes; one LlamaDart load hit a SIGSEGV (`SEGV_MAPERR` null-deref) in `ggml_backend_alloc_ctx_tensors_from_buft`, cause unresolved; what runs is blind, so vision is faked | ❌ |
| 7 | 06-17 | InternVL3-2B | 2B | GGUF Q4_K_M + mmproj Q8_0 / LlamaDart | feature/internvlm · b090f1d | ~1.4 GB download, over 1 GB; APK also inflated by bundled native runtimes | ❌ |
| 8 | 06-17 → 06-18 | LFM2-VL-1.6B | 1.6B | GGUF Q4_0 + mmproj / LlamaDart | feature/lfm2-vl · 15cad16, 799b4c6 | native Adreno/Vulkan `SIGSEGV` (`SEGV_MAPERR` null-deref) in `ggml_backend_alloc_ctx_tensors_from_buft` tensor alloc, unrecoverable → forced CPU; ~1.2 GB | ❌ |

### Uncommitted / off-ledger

| # | Date | Model | Size | Note | Verdict |
|---|---|---|---|---|---|
| — | 06-06 | Florence-2-base | 230M | `feature/florence` branch; app pointed at it once (WhatsApp instruction), never committed. Task model (caption/detect/OCR), not a chat/reasoning VLM | ❌ |

**→ 06-19: walls exhausted, track retired.** The project stopped looking for one small VLM and split vision from reasoning: a text-only reasoning core plus a separate on-device vision tool.

**Models tried (Era B):** Qwen3.5-0.8B-GGUF (https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF), Eagle2-1B-GGUF (https://huggingface.co/Mungert/Eagle2-1B-GGUF), InternVL3-2B-Instruct-GGUF (https://huggingface.co/ggml-org/InternVL3-2B-Instruct-GGUF), LFM2-VL-1.6B-GGUF (https://huggingface.co/LiquidAI/LFM2-VL-1.6B-GGUF), Florence-2-base (https://huggingface.co/microsoft/Florence-2-base); runtimes LlamaDart / llama.cpp (https://github.com/leehack/llamadart) and Quaynor (pure-Dart GGUF, https://github.com/iBz-04/quaynor).

### Consolidated count (whole v1 search, both eras)

- **Distinct models wired and run: 6** — SmolVLM-256M, FastVLM-0.5B, Qwen3.5-0.8B, Eagle2-1B, InternVL3-2B, LFM2-VL-1.6B.
- **Integration runs: 10; distinct model-and-runtime pairs: 9** — SmolVLM ×2 runtimes, Qwen3.5 ×2 runtimes, Eagle2 ×2 runtimes, plus InternVL3 and LFM2-VL make nine distinct pairs; FastVLM ×2 (both on the same LiteRT-LM runtime, 05-31 and 06-02) adds a tenth run without adding a tenth pair.
- **Attempted uncommitted: 1** — Florence-2-base.
- **Considered on paper only (candidate survey, never wired):** MobileVLM V2 1.7B, Granite Vision 2B, MiniCPM-V 4.6, Aquila-VL-2B, InternVL3.5-2B. These graduate into a ledger row only when someone actually wires and runs them.

Update these numbers whenever a ledger (here or in [Era A](01_implementation-litert-lm-era.md)) grows.

---

## Log (append newest at the bottom)

### 2026-06-02 · Qwen3.5-0.8B-GGUF, the runtime pivot

**Model:** `unsloth/Qwen3.5-0.8B-GGUF`: `Qwen3.5-0.8B-Q4_K_M.gguf` plus `mmproj-F16.gguf`, via `LlamaDartModelRuntime` (llama.cpp over FFI). Commits `95c3baa`, `9187c7d`. Image passed with `LlamaImageContent`; both files required at inference.

**What worked:** genuine **vision-grounded** output. The model sees the image.
**What disqualified it:** ~**900 MB** combined download; **per-ABI native compilation**; a **manual tool loop** (~200 LOC llama.cpp does not do for you).
**Result:** ⚠️ worked but disqualified (size plus build cost).

### 2026-06-07 · Eagle2-1B, accessibility via Quaynor then LlamaDart

**Model:** `Mungert/Eagle2-1B-GGUF`, `Eagle2-1B-q4_0.gguf`. Commits `0617fbf` (Quaynor), `bc76af4` (moved to LlamaDart).
**Integration:** **Quaynor** is pure-Dart, no native FFI, no per-ABI binaries; `Chat.ask()` runs the **full tool loop internally** (about 200 LOC less than llamadart). ~**330 MB**, fastest startup, lowest memory.
**Blocker (artifact, then capability):** the real Eagle2-1B is a **VLM** (SigLIP vision encoder under a custom `eagle_2_5_vl` architecture, which llama.cpp does not support — the feature request opened 2025-10-21 was later closed as stale without implementation). But the full seeing model was never run: both passes pulled the same `Mungert` q4_0 artifact, whose GGUF metadata is plain **`qwen2`** — Eagle2's **Qwen2.5-0.5B text backbone** under Eagle2's label, ~330 MB, no `mmproj`, and blind. (One LlamaDart load of it did crash at `ggml_backend_alloc_ctx_tensors_from_buft`, the same signature as LFM2; the contemporaneous diagnosis blamed unsupported vision tensors, but the artifact has none, so that crash's cause is unresolved.) Vision was then faked by extracting traits on the Dart side and passing text into the prompt, which breaks grounding (reasoning over a proxy, not pixels). Quaynor is pure-Dart and does support multimodal GGUF when given a matching `mmproj` projector (per its pub.dev docs); with this projector-less artifact its pass was necessarily text-only.
**Result:** ❌ the most accessible path, but blind, because the only version that loads has no eyes.

### 2026-06-17 · InternVL3-2B, multimodal GGUF over budget

**Model:** `ggml-org/InternVL3-2B-Instruct-GGUF`: `...Q4_K_M.gguf` plus `mmproj-...Q8_0.gguf`, ~**1.4 GB**, on the inherited LlamaDart infra. Commit `b090f1d`.
**Result:** ❌ a real multimodal GGUF that worked, but ~1.4 GB download is over the footprint goal; dropped within a day.

**Footprint note (applies to this whole GGUF era).** The weight was not only the model download. `llamadart` bundles every native runtime family it supports, so the release APK itself inflated toward **~149 MB**, dominated by `libggml-vulkan.so` (~50.5 MB), `libLiteRtLm.so` (~24.7 MB), a Qualcomm QNN/NPU stack (~52-53 MB), and `libLiteRtGpuAccelerator.so` (~8 MB). Trimming the model did nothing to trim this; strip the unused NPU/QNN payloads to claw back the biggest chunk. [Codex 06-16, 06-18]

### 2026-06-17 → 06-18 · LFM2-VL-1.6B, native Vulkan/Adreno crash

**Model:** `LiquidAI/LFM2-VL-1.6B-GGUF`: `...Q4_0.gguf` plus `mmproj`, ~**1.2 GB**, `llamadart ^0.8.1` for LFM2-VL vision. Commits `15cad16`, `799b4c6`.
**Crash (native, unrecoverable):** a null-pointer dereference on the DartWorker thread during model load, not a catchable Flutter exception. LFM2's own 06-17/06-18 sessions describe this crash in prose (see the `799b4c6` commit note below) but never pasted a fresh tombstone; the stacktrace below is the one clean capture of this exact signature, from Eagle2's 06-07 session. Same `ggml_backend_alloc_ctx_tensors_from_buft` signature, different root cause (Eagle2 = unresolved, since the artifact run was a plain `qwen2` backbone with no vision tensors; LFM2 = Adreno/Vulkan backend):

```
06-07 14:31:15.690 F/libc    (27648): Fatal signal 11 (SIGSEGV), code 1 (SEGV_MAPERR), fault addr 0x0 in tid 27721 (DartWorker), pid 27648 (m.sirkulab.mero)
06-07 14:31:15.966 F/DEBUG   (27742): Cause: null pointer dereference
06-07 14:31:15.966 F/DEBUG   (27742): #00 pc 0000000000000000  <unknown>
06-07 14:31:15.966 F/DEBUG   (27742): #04 ... base.apk!libggml-base.so ...
06-07 14:31:15.966 F/DEBUG   (27742): #06 ... base.apk!libggml-base.so ... ggml_backend_alloc_ctx_tensors_from_buft+116
06-07 14:31:15.966 F/DEBUG   (27742): #07 ... base.apk!libllama.so ... llama_model_base::load_tensors(...)
06-07 14:31:15.966 F/DEBUG   (27742): #09 ... base.apk!libllama.so ... llama_model_load_from_file+220
```

From `799b4c6`: "The Adreno/Vulkan backend crashes with a native SIGSEGV in `ggml_backend_alloc_ctx_tensors_from_buft` ... Because it's a native crash, the try/catch CPU fallback can't recover. Default Android to the CPU backend (`gpuLayers=0`); iOS/desktop keep auto (Metal)."
**Result:** ❌ native GPU crash; ~1.2 GB even on CPU. GGUF era exhausted, so the project split vision from reasoning.

### 2026-07-14 · State-of-the-art / revisit check (re-run periodically)

A web pass to test whether any wall above has since been fixed, whether a better single-VLM path exists, or whether the split pivot was right. Re-run this and append a fresh dated entry when the ecosystem moves.

- **Adreno/Vulkan GGUF crash (LFM2 entry): no clean fix, and our mitigation was in the right spirit but blunter.** The targeted community workaround for the `mmproj` GPU-allocation crash is `--no-mmproj-offload`, which keeps only the vision projector off the GPU while the language model can still run its layers there. Mero's actual mitigation, `gpuLayers=0`, is heavier: it forces the entire model onto the CPU, surrendering GPU acceleration completely, not just the projector's share. Both get the crashing allocation off the GPU, so the direction was right, but the minimal fix would have kept GPU layers for the LLM; Mero gave all of them up. llama.cpp added an **OpenCL backend for Adreno GPUs** (optimized per Qualcomm for Snapdragon 8 Gen 1-3 and 8 Elite on mobile, plus X Elite on Windows), but its VLM track record on that backend has been rough rather than solid: a November 2025 regression (llama.cpp issue #17351, commit `4db5641`) made Qwen2.5-VL-3B emit garbled image descriptions on Adreno, and Adreno context-init crashes have been reported. That specific issue is now closed and fixed, so it is a historical data point, not proof the path is broken today; the honest read is that mobile-GPU VLM support has been unstable and only intermittently reliable, which is a reason to wait for it to settle rather than to revisit Era B now. Revisiting Era B buys nothing new.
- **Better single-VLM path: an officially supported Android multimodal API for Gemma 3n E2B/E4B.** Google's MediaPipe LLM Inference guide documents on-device image input on Android for Gemma 3n (convert the bitmap to an `MPImage`, set `EnableVisionModality(true)`, up to 10 images per session). That is a first-party, supported multimodal API, which is more than any candidate here had, and it would plausibly clear the runtime-contract wall that broke the LiteRT-LM attempts. Two caveats keep it a *candidate*, not a proven fix: the guide does not claim a working GPU delegate for this multimodal path (its GPU notes are about LoRA), and it shows no Flutter binding or drop-in function-calling flow, so clearing Mero's runtime-and-tool-calling walls is unvalidated and would need real integration testing. (Google also now marks the MediaPipe LLM Inference API as deprecated in favor of LiteRT-LM, so the exact API surface is in flux.) And on size it does not help: Gemma 3n E2B's standard int4 LiteRT-LM bundle is ~3.7 GB, so it clears "runs cleanly," not "runs small." It is only a revisit trigger if the footprint goal is relaxed and the integration is validated.
- **Is the split pivot correct? For on-device, yes.** Current VLM write-ups point the same way, in paraphrase (no direct quotes): a common production pattern is to **freeze the vision encoder** and train only the projector plus a few LLM layers, which the labelyourdata 2026 guide notes cuts fine-tuning compute by roughly 90%, and small "edge-capable" VLMs in the 1B-10B range are explicitly aimed at on-device and mobile use. The same guide frames early-fusion (concatenating all image tokens into the sequence) as the token-heavy, high-memory option, with hybrid designs as the "production sweet spot," which lines up with heavier end-to-end unified VLMs skewing cloud-oriented. So a frozen vision encoder feeding a small text LLM is where the field points for constrained devices, which is exactly the split Mero pivoted to.

**Result:** ➖ no change to the verdict. The runtime ecosystem improved slightly, but VLM-on-mobile-GPU is still fragile and the only first-party multimodal option (Gemma 3n) is too big and unproven in Mero's flow.

Sources:
- MediaPipe LLM Inference, Android multimodal (Gemma 3n image input): https://developers.google.com/edge/mediapipe/solutions/genai/llm_inference/android
- Qualcomm, OpenCL GPU backend in llama.cpp for Adreno: https://www.qualcomm.com/developer/blog/2024/11/introducing-new-opn-cl-gpu-backend-llama-cpp-for-qualcomm-adreno-gpu
- llama.cpp OpenCL backend docs: https://github.com/ggml-org/llama.cpp/blob/master/docs/backend/OPENCL.md
- llama.cpp #17351, VLM (Qwen2.5-VL-3B) garbled on Android Adreno — a Nov 2025 regression (commit `4db5641`), now **closed/fixed**, cited as a historical data point: https://github.com/ggml-org/llama.cpp/issues/17351
- llama.rn #229, Adreno OpenCL context-init crash: https://github.com/mybigday/llama.rn/issues/229
- Rethinking VLMs and LLMs for image classification (Nature Sci. Reports): https://www.nature.com/articles/s41598-025-04384-8
- VLM guide 2026, modular frozen-encoder vs end-to-end: https://labelyourdata.com/articles/machine-learning/vision-language-models

---

## Running lessons (revise as entries are added)

- `.litertlm`, `.tflite`, `.gguf` are not interchangeable containers: different runtimes, APIs, packaging, and risks.
- Multimodal GGUF needs a matching `mmproj` and a runtime that uses it; text-only models can be fast and clean but cannot see.
- The tool loop is a reliability surface (Quaynor automates it, llamadart does not), not just LOC.
- Mobile-GPU VLM via llama.cpp is fragile: the Adreno/Vulkan tensor-alloc SIGSEGV is native and uncatchable, and the only reliable mitigation surrenders the GPU that was the reason to use the path.

## Open threads (what could add the next entry)

- **A pure-Dart GGUF runtime with `mmproj` support, paired with a model that actually ships a projector.** Quaynor's current pub.dev docs already describe multimodal support via a matching `mmproj` projection model (verified 2026-07); what Mero lacked in the Eagle2 pass was an artifact with a projector to give it. A working Quaynor + projector combination removes the native-build and Vulkan-crash surface at once, the highest-value trigger.
- **A stable Adreno GPU path for VLMs** (OpenCL backend VLM regressions fixed). Re-test LFM2-VL or a small GGUF VLM on GPU.
- **A multimodal GGUF in the few-hundred-megabyte range** with a working `mmproj`; anything meaningfully under a gigabyte clears the hard size wall that killed InternVL3 and LFM2, but the smaller band is the actual target.
- **Re-run the state-of-the-art check** (append a new dated entry) whenever llama.cpp mobile-GPU VLM support or MediaPipe model coverage changes.

### Append template

```
### YYYY-MM-DD · <model + variant, or "state-of-the-art check">
**Model / scope:** <repo / files, or what was surveyed>. **Integration:** <runtime>.
<what worked, what broke, or what the check found>
**Result:** ✅ / ⚠️ / ❌ / ➖ <one line>
```

Wire it, run on a real Adreno-class Android device, append here, and update **Where this stands** plus the **Attempts ledger (Era B)** table and consolidated count above.
