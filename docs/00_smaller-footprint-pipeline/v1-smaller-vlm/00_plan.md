# v1 · Plan — smaller single VLM (drop-in Gemma replacement)

**Status:** ❌ Retired (runtime walls) — but kept **open as a revisitable strategy**. This doc holds the generic bet, constraints, and the conditions that would reopen the search. The concrete attempts, ledgers, counts, and crash logs live in the era implementation logs and the evidence file (see References).
**Goal:** Replace **Gemma 4 E2B (2.58 GB)** with **one smaller multimodal model** that still sees the photo and reasons, keeping the existing Flutter app flow (function calling, SQLite tools, 4-pass loop) intact. A model swap, not an architecture change.
**Outcome:** No single small VLM survived the on-device runtime contract, so the project stopped looking for one and split "seeing" from "reasoning" into separate components. This is not a success story; its value is a precise account of what breaks first as the model shrinks.

---

## 1. Hypothesis

Mero has to be as accessible as possible: its students are in regions where internet is slow or intermittent, so the app is downloaded once and used offline. Gemma 4 E2B is roughly 2.6 GB as a `.litertlm` bundle, which is large for a low-cost Android phone whose storage is already shared across the OS, other apps, and local content. A smaller on-device model would mean a faster first download, less storage pressure, lower runtime memory, and faster startup, all of which widen the set of classroom phones Mero can realistically run on.

The aim is to shrink Gemma's footprint **substantially**, ideally into the few-hundred-megabyte band of the smallest VLMs (the SmolVLM class); anything under roughly a gigabyte is a loose ceiling, not the target. A candidate that only trims the download a little, or that shrinks it but drags in new build or maintenance cost, does not clear the bet.

But size is not the point by itself. The bet is that **a smaller model can keep enough of the learning flow to replace Gemma outright**: identify a species from a photo, explain its reasoning step by step, reach the local biodiversity data through tool calls, and answer in language a student can follow. If some sufficiently small multimodal model can do all four on-device, the footprint problem is solved with a one-line model swap, with no architecture change and no new failure surface. v1 is the attempt to prove that bet wrong before spending on anything larger.

## 2. Constraints

The three standing constraints for the whole footprint effort:

1. **No data dependency** — knowledge-guided, no per-species reference images, no trained classifier.
2. **Scale without retraining** — a new species is DB rows only.
3. **Model is the reasoning core** — a generative model interprets, reasons, verifies, explains.

Plus two that are **specific to v1** and are exactly what make it attractive and fragile:

4. **One multimodal model** — the model itself sees the image (no separate vision tool).
5. **Reuse the app flow unchanged** — the same function-calling + SQLite tool loop and 4-pass agentic prompts.

### The bar any replacement must clear

Gemma 4 E2B is the quality baseline because it delivers four things at once, and a smaller model has to preserve enough of all four to keep the learning flow intact.

1. **Multimodal input** — accepts the photo alongside text and reasons about both.
2. **On-device deployment** — runs fully on the phone, no data leaves the device.
3. **Structured tool use** — real function calls into the local SQLite species tools.
4. **Multi-step reasoning** — revisits its hypothesis across passes and explains why.

A candidate that drops any one of these (for example a model that cannot see, or a task model that cannot reason) fails the bar even if it loads and runs cleanly.

## 3. Method — an organic search, not a fixed list

This track was never a predetermined shortlist. Each candidate was wired into `model_service.dart`, run on a **real Android device**, hit a **specific wall**, and that wall pointed at the next candidate. The generic shape of the progression:

```
try a small preconverted multimodal model on the proven runtime ──► it crashes or
     rejects the app's generation contract ──► try a different packaging / native plugin
     ──► same class of contract or native failure ──► abandon the runtime, switch runtimes
     ──► new runtime runs, but hits native GPU crashes, size, or capability limits
     ──► (walls exhausted) ──► split vision from reasoning (next track)
```

The value of v1 is the **ledger of walls**, not any single model. Two runtime eras emerged on their own, each with its own append-only implementation log; a new candidate is a new row tagged with the wall it hit. The narrative never needs rewriting because the walls, not the order, are the finding. To add a candidate, append it to the relevant era log (which carries the ledger table and an append template), wire it in `lib/services/model_service.dart`, run it on a real Adreno-class device, and record the wall.

## 4. Where the detail lives

Two eras, each with its own living log holding the attempts ledger, dated entries, per-model links, and running lessons:

- **Era A — LiteRT-LM (keep the proven Gemma runtime):** [01_implementation-litert-lm-era.md](01_implementation-litert-lm-era.md).
- **Era B — GGUF / llama.cpp (abandon LiteRT-LM):** [02_implementation-gguf-llamacpp-era.md](02_implementation-gguf-llamacpp-era.md), which also carries the consolidated count across both eras and the periodic state-of-the-art check.

Verbatim stacktraces, git commits, and log sources for every attempt are in [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md).

## 5. Failure taxonomy — the walls

Every attempt died of one of four things. Which model hit which wall is recorded in the era logs; here they are as generic categories.

1. **Runtime contract (LiteRT-LM).** The model's graph does not match what the runtime executes: opcode, signature, or tensor mismatch, an `invoke` that never returns, a native segfault inside a running engine, or an unmet multimodal-vision contract.
2. **Native crash (GGUF/llama.cpp).** A `SIGSEGV` during model load in the tensor allocator, worst on the Adreno/Vulkan backend and unrecoverable from Dart, either because the GPU path is fragile or because the model's vision architecture is unsupported.
3. **Size.** The footprint stays too large: a model over roughly a gigabyte is a hard fail, and even a sub-gigabyte model can miss the target if it is far heavier than the few-hundred-megabyte SmolVLM class or drags in per-ABI native build weight (the GGUF runtime also inflates the APK itself).
4. **Capability mismatch.** The model cannot do the job even if it runs: effectively blind (only a text backbone loads), a vision task model that cannot reason, or a model small enough to run but too small to carry reliable species knowledge, so its output is ungrounded and gets rejected.

The meta-finding: **the runtime was the binding constraint here, though not the only wall**. Small VLMs exist; a small VLM that (a) exports to a runtime that loads on Android, (b) keeps a working GPU delegate, and (c) exposes function calling does not, at least not in this window. That runtime wall stopped most candidates first. But it was not the whole story: wall #4 (capability) is a model problem a perfect runtime would not fix — one GGUF candidate cleared the runtime, saw the image, and still emitted ungrounded taxonomy, and a task model could not reason at all. "Make the runtime work" and "the model is good enough" are two separate bars; the runtime was the one that bound first.

## 6. Revisit triggers — when to reopen v1

v1 is retired, not closed. A single small VLM becomes worth trying again the moment any of these holds (each becomes a new ledger row in the relevant era log):

- A **small multimodal model with a working LiteRT-LM export** that loads and invokes on Android with function calling (clears wall #1).
- A **pure-Dart multimodal runtime** (no per-ABI native build) that supports `mmproj` image input — this removes the GGUF native-build and Vulkan-crash surface (clears wall #2 and the build cost of Era B).
- A small VLM whose runtime **GPU delegate works on Adreno** (like LiteRT's OpenCL path) instead of the llama.cpp Vulkan path that SIGSEGVs (clears wall #2).
- Any **paper-survey candidate** shipping a confirmed on-device build that meets the above and lands **meaningfully under a gigabyte, ideally in the few-hundred-megabyte band** (clears wall #3).

### Open questions carried over from the migration draft

Three questions were never resolved here. They are the concrete form of the triggers above, and a "yes" to any of them reopens the search:

1. **Can a vision model in the ~300–500 MB range be reliable enough for classroom use?** The gap between the smallest candidates (SmolVLM class) and the runtime-viable but heavier ones (Qwen3.5-0.8B, which at least loaded, saw the image, and ran the tool loop, even if its taxonomy was not reliable enough to keep) is large in both size and capability. A better candidate in that band needs a GGUF or LiteRT export with a working `mmproj`/vision path and a confirmed Flutter integration.
2. **Can Dart-side visual-trait extraction compensate for a blind model?** Eagle2-1B ran small and clean but ended up blind (only its text backbone loaded), so vision was faked by extracting traits before inference. If that extraction is rich and accurate enough, a text-only model might feel grounded, but it moves the vision-quality problem into the extraction pipeline.
3. **Is there multimodal GGUF inference without native compilation?** Quaynor runs GGUF in pure Dart but has no multimodal input; LlamaDart supports multimodal GGUF but needs per-ABI native builds. A pure-Dart engine with `mmproj` image support would change the trade-off entirely.

If none of these change, the split-pipeline direction remains the answer and v1 stays closed.

## 7. Decision summary

- **v1 retired:** the on-device runtime was the binding wall, though not the only one. Six models across nine distinct model-and-runtime pairs (ten runs counting FastVLM's two attempts), plus one uncommitted, none survived (full accounting in the era logs).
- **Consequence:** stop looking for one small VLM; split vision from reasoning into a text reasoning core plus a separate on-device vision tool.
- **This doc stays open:** the era logs are append-only and §6 lists the conditions that would reopen the search, so a future candidate slots in as an organic finding without rewriting the history.

## References

- [01_implementation-litert-lm-era.md](01_implementation-litert-lm-era.md) — Era A ledger, dated entries, per-model links, lessons.
- [02_implementation-gguf-llamacpp-era.md](02_implementation-gguf-llamacpp-era.md) — Era B ledger, consolidated count, state-of-the-art check, per-model links.
- [on-device-model-migration-evidence.md](on-device-model-migration-evidence.md) — verbatim stacktraces, git commits, and log sources for every attempt.
- [on-device-model-migration-lessons.md](on-device-model-migration-lessons.md) — the full narrative account.
- `on-device-model-migration-lessons-draft.md` — early narrative post-mortem (superseded; kept as a historical artifact, corrections marked inline).
- Committed post-mortems `docs/reports/on-device-model-migration-lessons.md` / `-comparison.md` at commit `9187c7d` (branches `feature/eagle-bck`, `feature/eagagle-bck`).
