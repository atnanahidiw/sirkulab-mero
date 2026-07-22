# Agent-Loop Evaluation

This track ran on **2026-07-22** over **332 images from 64 species**. The result does
not show a reliable win for the four-call prompt condition over fixed retrieval. A two-call
prompt cap produced the highest observed species accuracy, **41.0%**, versus **35.2%**
for the fixed-retrieval control, but the paired comparison was borderline rather than
conclusive (`p = 0.0648`). The four-call prompt condition reached **37.7%**
(`p = 0.466` versus fixed retrieval).

Tracks `01` and `02` established that Mero's identification loop can fail at several separate interfaces: coarse visual routing can discard the true species before retrieval runs, retrieval scores and candidate order causally affect the final selection, and the model's confidence label is not a reliable correctness signal. What none of the existing tracks show is whether letting Gemma iterate, meaning call the search tool more than once and revise its hypothesis, actually produces better identifications than handing it one good candidate list and asking it to choose once.

That is the question this track tests. It is described in more depth, alongside the
rest of the evidence it builds on, in [Mero as an On-Device Multimodal Agent](/sirkulab-mero/articles/agent-architecture-and-evaluation/).

## The research question

Does iteration improve decisions enough to justify its cost?

In the 332-image native baseline, most cases used a single tool call, and observed accuracy did not clearly improve with additional calls. That is not evidence against the loop, because harder examples are more likely to trigger revision in the first place. It only shows that pass count and difficulty are confounded in the data collected so far. Separating them requires a controlled comparison, which is what this track plans to run.

## Why a deterministic baseline matters

A run of the adaptive loop with zero, one, two, or four passes cannot answer this question on its own, because none of those conditions hand the model a strong candidate list without letting it choose the query. Without that control, a gain from more passes could just as easily be a gain from a better final candidate set that happened to arrive after more tool calls.

The design adds a fixed-retrieval condition: Gemma extracts one structured trait set,
the app invokes the deterministic search exactly once with those traits, and Gemma gets
one selection pass. The observation still comes from the model; what is fixed is that
the app, rather than the model's tool policy, decides to perform exactly one search.
This isolates adaptive search control from the benefit of receiving a candidate list.

## Reports

1. **[Loop ablation](./01_loop-ablation.md)**: five conditions on the same frozen
   examples, from no tool use to the four-call prompt condition, including the
   fixed-retrieval control.
2. **[Revision analysis](./02_revision-analysis.md)**: when the true species first
   entered the actual top-five candidate list and whether the requested visual group
   changed between calls.
3. **[Stopping-policy comparison](./03_stopping-policy-comparison.md)**: the prompt
   caps against unchanged-hypothesis and evidence-threshold replay policies.
4. **[Reflective iteration implementation](./04_reflective-iteration-implementation.md)**:
   the Phase 2 follow-up, a database-grounded candidate-contrast step that preserves the
   completed ablation's model, retrieval, sampler, and scoring. Not run yet; results will
   be appended to this same document's "Results" section once a real run completes.

The full plan for both phases lives in [`00_plan.md`](./00_plan.md); it points to each
phase's implementation and results rather than repeating numbers. Scripts live in
[`scripts/agent-loop-evaluation/`](../../scripts/agent-loop-evaluation/), and their
saved artifacts live in [`outputs/agent-loop-evaluation/`](../../outputs/agent-loop-evaluation/).

litert_lm's native tool loop only returns the model's answer after it stops for real.
It does not expose what the model would have concluded at an earlier pass. The reports
therefore use retrieval-side availability and visual-group changes as proxies and do
not claim counterfactual accuracy for an unobserved stopping point.

## What this track does not cover

The run captured accuracy, genus accuracy, tool calls, and coarse session timing for
only the two-call and four-call sessions. It did not capture per-image latency,
generated tokens, memory, energy, or device temperature. It evaluates the historical
multimodal Gemma 4 native-tool baseline used by the Track 01 harness, not the current
Flutter branch's experimental Qwen3 + vision-tool pipeline.

## How this fits with the other tracks

| Track | Question |
| --- | --- |
| [Track 00: Smaller footprint](/sirkulab-mero/00_smaller-footprint-pipeline/) | Can Mero reduce its model and runtime footprint without losing its core behavior? |
| [Track 01: Detection failures](/sirkulab-mero/01_gemma-improve-detection/) | Where do perception, routing, retrieval, and synthesis fail? |
| [Track 02: Candidate sensitivity](/sirkulab-mero/02_candidate-rank-sensitivity/) | How do candidate order, confidence, and explanations affect behavior? |
| [Track 03: Mechanistic analysis](/sirkulab-mero/03_candidate-rank-mechanistic/) | How is candidate position represented, and does it have a measurable causal role? |
| Track 04: Agent-loop evaluation (this track) | A second call helped descriptively, but the four-call prompt condition did not reliably beat fixed retrieval. |
