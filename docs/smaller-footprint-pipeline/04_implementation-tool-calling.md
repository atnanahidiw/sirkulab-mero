# 04 · Implementation — agentic tool calling

**Status:** 🔧 in progress · **Owns:** `model_runtime.dart`, `model_service.dart` (identify flow), `chat_prompts.dart`
**Theme:** getting a **0.6B** model to actually run the multi-step OBSERVE → SEARCH → VERIFY → CONCLUDE loop on-device.

This is a debugging log — each entry is *symptom → diagnosis → fix*, kept so we
can see why each lever exists and retry if a build regresses.

## Background: the 0.6B is the constraint, not a bug
Research check ([Qwen3-0.6B](https://huggingface.co/Qwen/Qwen3-0.6B), [Artificial
Analysis](https://artificialanalysis.ai/models/qwen3-0.6b-instruct)): Qwen3-0.6B
has *native* tool support and decent single-call tool benchmarks, but sits at the
**low end of reasoning/instruction-following** (Intelligence Index 6). Even
Qwen3-32B picks the right tool first-try only ~87% of the time. So the failures
below are the expected behaviour of a tiny model on a hard *multi-step ordering*
task — mitigations, not "fixes for a broken model."

## Step 1 — model skipped tools, emitted "Unknown" immediately
**Symptom:** pass 1 streamed a final `{"genus":"Unknown",...}` JSON, no tool calls;
runtime: *"Custom tool calling response did not match the expected protocol."*
**Diagnosis:** the **custom** (app-side) tool path injected a `<custom_tool_calling>`
envelope (`{"type":"tool_call",...}`) that **conflicted** with the system prompt's
final-JSON schema (`{genus,confidence,...}`). A 0.6B can't juggle two output
contracts → collapsed to the final schema and skipped tools.
**Fix:** switched identify to **native** tool calling (`useNativeToolCalling: true`).
Qwen3 emits real function calls via its chat template; the conflicting envelope is
not injected. → model now emits valid `search_similar_features(...)` calls.

## Step 2 — model called search first, with all-`none` traits
**Symptom:** `search_similar_features({color: none, ... visualGroup: none})` on
pass 1 — it **skipped `extract_visual_features`** (can't see the photo, so filled
blanks). Search found nothing → empty pass 2.
**Diagnosis:** native tool-calling fixed the *format*, but a 0.6B still won't pick
the right *first* tool. Tools are `final` per chat in `flutter_gemma`, so we can't
hide `search` on pass 1.
**Fix (tool ordering, two parts):**
1. **Search guardrail** (`model_service.dart`) — a `hasObserved` flag set when
   `extract` runs; `search` called before that returns *"call extract_visual_features
   FIRST … never 'none'"* instead of a bogus search.
2. **Prompt** (`chat_prompts.dart`) — `identifyInputPrompt` leads with *"YOUR FIRST
   TOOL CALL MUST BE `extract_visual_features` ({})"*; two new `<rules>` forbid
   search-before-extract and `none`/empty trait values.
→ model now calls `extract_visual_features({})` first.

## Step 3 — `extract` crashed on-device (latent Dart bug)
**Symptom:** as soon as `extract` actually ran:
`type 'Float32List' is not a subtype of type 'num' in type cast`.
**Diagnosis:** `OrtValue.asList()` returns the `[1,768]` output **nested**
(`[Float32List(768)]`); our `.map((v) => v as num)` hit the inner `Float32List`.
Never caught before because Python validation tests onnxruntime-Python directly,
and on-device `extract` had always been skipped.
**Fix:** use **`asFlattenedList()`** (1-D float data) in both `_embedImage` and the
text-encoder path.

## Step 4 — thinking mode for planning
**Lever:** Qwen3's **thinking mode** is its multi-step planning capability, and the
device log showed **0 thinking tokens** (it was off). Enabled via a new
`enableThinking` flag threaded `generateResponse → _generateWithToolCalling →
createChat(isThinking:)`; default **off** (Q&A/translate stay fast), **on** for
identify. Result: pass 1 now reasons (*"The first step is to call
extract_visual_features… require empty arguments"*) before acting.

## Step 5 — model observed correctly but discarded the result
**Symptom:** `extract` returned real traits
(`color:"dark blue, black", … visual_group:"Mollusk & marine invertebrate"`), then
`search_similar_features` was called with **`unknown` for all 7 fields**.
**Diagnosis:** copying a tool result's fields into the next tool's args is past a
0.6B's reliability ceiling. The guardrail passed (`extract` *had* run), the result
just wasn't *used*.
**Fix:** **backfill** in `model_service.dart` — store the observed traits; the
search executor replaces any field the model left blank/`none`/`unknown` with the
real observed value (taxonomy hints stay the model's own). A lazy arg-copy can no
longer throw away a good observation.

## Open items / things to watch
- **`toolChoice: required`** (current, per request) forces a tool call every pass —
  watch for passes maxing out with empty output instead of a final JSON. If so, the
  fix is `required` on pass 1 → `auto` after.
- **Latency:** with thinking on, pass 1 ≈ 65 s on CPU (~8 tok/s). Acceptable for
  identify; off for Q&A.
- **Sampling not yet aligned to Qwen3 spec** (`topK 20`, `topP 0.95`); currently
  `topK 100` / `topP 0.9`, which works against thinking-mode quality.
- **Synthesis laziness:** if the final pass outputs `"unknown"` genus despite real
  candidates, apply the same backfill trick to the final answer (fill from the top
  candidate).
- **Trait accuracy** (the "Mollusk" mislabel above) is a *vision* problem, not a
  tool-calling one → [05_implementation-accuracy-tuning.md](05_implementation-accuracy-tuning.md).
