# Agent-Loop Evaluation Plan

## Summary

At the time this plan was written, Mero's Gemma baseline let the model call
`search_similar_features` up to four times and revise its hypothesis between calls.
Tracks `01` and `02` showed that several interfaces inside that loop could fail on their
own: routing, retrieval breadth, candidate presentation, and stopping. None of the
existing tracks compared the adaptive loop against a non-agentic pipeline on the same
images, so it remained a hypothesis, not a result, that iteration was worth its
on-device cost. This document is the plan for both phases of this track: the original
loop ablation (below) and the reflective-iteration follow-up it motivated (Phase 2).

Results are not reported here. Each phase's numbers live in its own dated result
document, referenced from the relevant section below and from
[`README.md`](./README.md).

## Why This Track

The 332-image native baseline shows 260 cases with one tool call, 64 with two, 7 with three, and 1 with five, with observed accuracy of 38.8%, 34.4%, 28.6%, and 0% respectively. Read naively, more calls look worse. That reading is not supported: harder examples are more likely to trigger a second or third call in the first place, so pass count and example difficulty are confounded in the existing data. Only eight cases made more than two calls, which is too few to separate the two explanations. A controlled comparison, where the same examples are run under conditions that differ only in how much iteration is allowed, is needed before either conclusion is defensible.

## Research Question

Does letting Gemma iterate, meaning call the search tool more than once and revise its hypothesis, produce more reliable species identification than a fixed retrieval pipeline, once the pass limit is not runtime-enforced and stopping is not calibrated?

## Phase 1: Loop Ablation, Revision Analysis, Stopping Policy

### Scope For The First Pass

Start with the loop ablation, since it is the prerequisite for interpreting everything else. Revision analysis and stopping-policy comparison both depend on having pass-by-pass records from the ablation conditions rather than being separate data collection efforts.

The sequence was:

1. Freeze a fixed evaluation set of images, held constant across all conditions.
2. Run the five ablation conditions on that set and record full pass-by-pass traces.
3. Analyze revision behavior using the two signals recoverable from those traces: first-available pass and hypothesis stability (see §2 below).
4. Compare the current fixed pass-limit prompt against alternative stopping rules using the same traces.
5. Report cost alongside accuracy: latency, tool calls, generated tokens, memory use, energy use, device temperature.

### 1. Loop Ablation Against A Deterministic Baseline

Compare five conditions on the same frozen examples:

1. Direct VLM identification with no tool.
2. Fixed retrieval followed by one selection pass.
3. One model-selected tool call.
4. Up to two adaptive calls.
5. Up to four adaptive calls with explicit stopping.

Condition 2 is the critical control. It hands the model a strong candidate list without letting it choose the query, so it isolates whether the agent's adaptive tool choice adds anything beyond good retrieval. Conditions 3 through 5 vary how much adaptive iteration is allowed but, on their own, cannot show whether that iteration beats a non-agentic pipeline; only the comparison against condition 2 can.

Metrics: `accuracy`, `tool_calls`/`passes` per condition, and a paired accuracy comparison against condition 2 (matched McNemar test on discordant cases, following the same paired approach used for the soft-gate rerun in Track 01). Per-image `latency` and `generated_tokens` were not instrumented; see Cost Reporting below.

Implemented in [`scripts/agent-loop-evaluation/00_loop_ablation.py`](../../scripts/agent-loop-evaluation/00_loop_ablation.py). Results: [`01_loop-ablation.md`](./01_loop-ablation.md).

### 2. Revision Analysis

litert_lm's native `automatic_tool_calling` loop only returns the model's answer after
it stops for real. It does not expose an intermediate hypothesis or verdict after each
individual tool call, only the final identification and the sequence of tool-call
arguments the model actually sent. That rules out a direct wrong-to-correct /
correct-to-wrong trace between passes: an intermediate pass's would-be answer is never
observed, so it cannot be scored.

What is recoverable, by replaying each recorded call's traits through the same
deterministic search offline, from the pass-by-pass traces of conditions 3 through 5:

- The pass at which the true species first becomes available in the candidate list Gemma actually saw (top-5, matching the live tool's `top_k`).
- Whether the requested `visualGroup` changed between consecutive calls, the only
  available proxy for "the model revised its hypothesis."
- Whether the final answer was correct, correlated against both of the above.

Implemented in [`scripts/agent-loop-evaluation/01_revision_analysis.py`](../../scripts/agent-loop-evaluation/01_revision_analysis.py). Results: [`02_revision-analysis.md`](./02_revision-analysis.md).

### 3. Stopping-Policy Comparison

Compare the current prompt-only stopping instruction (stop after a match at or above 45% displayed confidence and visual agreement, or after four attempts, not runtime-enforced) against two alternatives:

- Stop when the hypothesis is unchanged across consecutive passes.
- Stop when retrieved evidence supports the current answer above a fixed threshold, evaluated independently of the model's self-reported confidence.

The one-call and two-call conditions from the loop ablation are prompt-enforced
*at-most-k* runs: the model can stop earlier, and the tool tells it to conclude when the
cap is reached. Their observed accuracy and pass count are read directly, with no
replay. The two alternatives are replayed offline on the
four-call prompt condition's own traces. Because an earlier, counterfactual stop is never
observed (see the revision-analysis limitation above), `accuracy_at_stop` for the two
alternatives is only reported over the subset of images where the policy's suggested
stop pass equals the pass the model actually stopped at; it is not assumed correct for
the rest.

Implemented in [`scripts/agent-loop-evaluation/02_stopping_policy_comparison.py`](../../scripts/agent-loop-evaluation/02_stopping_policy_comparison.py). Results: [`03_stopping-policy-comparison.md`](./03_stopping-policy-comparison.md).

### Cost Reporting

The plan called for reporting cost alongside accuracy for every condition: `latency`,
`tool_calls`, `generated_tokens`, `memory_use`, `energy_use`, `device_temperature`. What
was actually captured, recorded in [`01_loop-ablation.md`](./01_loop-ablation.md): tool-call
counts for every condition, and a coarse *session-level* mean seconds/image for the
two-call and four-call sessions only (not per-image, and not for the other three
conditions). Generated-token counts, memory use, energy use, and device temperature were
not instrumented. Phase 2 (below) commits to fixing the per-image latency gap.

## Phase 2: Reflective Iteration

### Motivation

Phase 1 found that a second adaptive search call could recover useful candidates, but
that allowing up to four calls did not improve on the two-call condition, and that the
two-call gain over fixed retrieval was descriptively real but not conventionally
significant. See [`01_loop-ablation.md`](./01_loop-ablation.md) for the numbers this
motivation rests on; they are not repeated here.

The working hypothesis is that the previous iteration pattern was insufficient because
the prompt only told Gemma to "pivot entirely" on a low-confidence result, with no
structured record of the provisional answer, no explicit contrast between realistic
candidates, no requirement that a changed query be justified by database evidence, and
no retained union of candidates across searches. A useful second pass should refine a
discriminating uncertainty, not erase the first pass and start over.

### Design decision

Evaluate reflection with the same Gemma 4 E2B LiteRT-LM baseline used by the completed
Phase 1 ablation (not Qwen3, Talk2DINO, the current Flutter vision tools, a critic
model, or a different retrieval implementation). The intervention is a bounded
**database-grounded contrastive reflection** step, capped at two executed searches (Phase
1 showed a third or fourth call added nothing), that asks the curated species database
which visual traits distinguish a provisional candidate from a plausible challenger
before Gemma revises its query.

Six conditions isolate the mechanism from its surface effects: a fresh fixed-retrieval
control and a fresh plain two-call re-run anchor the comparison; an instrumented
two-call condition isolates whether adding stable IDs and a different tool-response
format changes anything on its own; a prompt-only reflection condition isolates whether
self-feedback alone helps without database grounding; and two structured-reflection
conditions separate the value of database-grounded contrast from the value of keeping
first-search candidates available after revision.

### Statistical power

Phase 1's own two-call-vs-fixed-retrieval comparison is a concrete data point on how
hard significance is at this sample size: a +5.7pp difference (57 wrong→correct against
38 correct→wrong, 95 discordant pairs out of 332 images) produced McNemar `p = 0.0648`,
a real-looking effect that still missed the conventional 0.05 threshold. Using the
normal-approximation McNemar sample-size formula `n_discordant ≈ (z_{α/2}+z_β)² / (2r−1)²`
with `r = 57/95 ≈ 0.6`, 80% power at `α = 0.05` needs roughly **196 discordant pairs**,
about twice the 95 observed. At Phase 1's ≈29% discordance rate, matching that would take
on the order of **650–700 images**, or a discordant split further from 50/50 than 60/40
(i.e. a larger true effect) for 332 images to be adequately powered. This is an
approximation, not an exact-test power calculation, but it is a strong enough signal that
Phase 2 should not assume 332 images will yield a clean significant result even if the
reflective intervention genuinely helps by a similar margin. If the observed effect is
positive but underpowered, it should be reported as exploratory and used to size a
proper holdout, per the promotion-gate note below, not treated as a failed replication.

### Comparability, promotion gates, and execution requirements

The full method (the tool contracts, per-image state, prompt design, six-condition
table, statistical plan with a single pre-registered primary comparison against a *fresh*
plain two-call run rather than Phase 1's archived numbers, Holm correction on secondary
comparisons, and seven promotion gates) is specified in
[`04_reflective-iteration-implementation.md`](./04_reflective-iteration-implementation.md),
which also documents what was actually built. Two requirements added during review, on
top of the original design:

- **Condition-3 parity gate.** Condition 3 (instrumented plain two-call: Condition 2's
  prompt verbatim, only the tool's wire format changed) must reproduce Condition 2's
  accuracy closely before conditions 4–6 run. The existing "Search 1 output matches the
  baseline byte-for-byte" test checks the tool call itself but not full end-to-end
  accuracy parity; this closes that gap cheaply, before conditions with genuinely new
  logic are trusted.
- **Resumable execution.** Six conditions on 332 images, potentially across three seeds,
  is several times Phase 1's compute, and Phase 1 needed four relaunches because
  background runs in this environment are cut off after roughly 45 minutes regardless of
  progress. Per-image resumable JSONL writes, matching `00_loop_ablation.py`'s pattern,
  are a first-class requirement for the new runner, not an incidental property checked
  only by a hash-matching test.

### Files

- [`scripts/agent-loop-evaluation/03_reflective_iteration.py`](../../scripts/agent-loop-evaluation/03_reflective_iteration.py): the six-condition runner.
- [`scripts/agent-loop-evaluation/04_reflective_iteration_analysis.py`](../../scripts/agent-loop-evaluation/04_reflective_iteration_analysis.py): paired tests, transition analysis, protocol-failure and cost summary.
- [`04_reflective-iteration-implementation.md`](./04_reflective-iteration-implementation.md): full spec, implementation notes, and (once a real run completes) the results, appended rather than split into a separate file.

## Files (Phase 1)

- [`scripts/agent-loop-evaluation/README.md`](../../scripts/agent-loop-evaluation/README.md)
- [`scripts/agent-loop-evaluation/00_loop_ablation.py`](../../scripts/agent-loop-evaluation/00_loop_ablation.py)
- [`scripts/agent-loop-evaluation/01_revision_analysis.py`](../../scripts/agent-loop-evaluation/01_revision_analysis.py)
- [`scripts/agent-loop-evaluation/02_stopping_policy_comparison.py`](../../scripts/agent-loop-evaluation/02_stopping_policy_comparison.py)
- [`01_loop-ablation.md`](./01_loop-ablation.md), [`02_revision-analysis.md`](./02_revision-analysis.md), [`03_stopping-policy-comparison.md`](./03_stopping-policy-comparison.md): Phase 1 results.

## Next Steps

- Build and unit-test the Phase 2 runner and analyzer against synthetic traces and the real species database before any model run, matching how Phase 1's scripts were validated.
- Run the condition-3 parity check before trusting conditions 4–6.
- Run the 64-image pilot before the full 332-image run, per the recommended order in `04_reflective-iteration-implementation.md`.
- Append the results to `04_reflective-iteration-implementation.md` once a real run completes, not before.
