# Stopping-policy comparison results

## Summary

The observed runs favor a short cap. The two-call condition achieved **41.0%** accuracy
at **1.24 mean search calls**, while the four-call prompt condition achieved **37.7%** at
**1.25 mean calls**. The four-call allowance therefore added no measured accuracy and
almost no average call budget because most images already stopped after one call.

Offline replay of unchanged-hypothesis and 45%-evidence rules would have changed only a
handful of the recorded four-call trajectories. It cannot establish their
counterfactual accuracy because the model's earlier answers were not captured.

## Artifacts

- Analyzer: [`02_stopping_policy_comparison.py`](../../scripts/agent-loop-evaluation/02_stopping_policy_comparison.py)
- Summary: [`stopping_policy_comparison_summary.json`](../../outputs/agent-loop-evaluation/stopping_policy_comparison_summary.json)
- Per-image replay: [`stopping_policy_comparison.jsonl`](../../outputs/agent-loop-evaluation/stopping_policy_comparison.jsonl)

## Observed prompt-cap conditions

| Condition | Species accuracy | Mean calls | Call-count distribution |
| --- | ---: | ---: | --- |
| One-call | 33.7% | 1.00 | 332×1 |
| Two-call | **41.0%** | 1.24 | 253×1, 79×2 |
| Four-call prompt | 37.7% | 1.25 | 260×1, 64×2, 7×3, 1×5 |

There was no four-call trace: no image made exactly four calls, and one made five. The
Python harness asks the model to stop through prompt text and tool-result text but does
not reject a fifth call. This is a failure of enforcement, not evidence for a useful
fifth reasoning pass.

The two-call and four-call session means were 10.08 and 11.71 seconds per image,
respectively. They were sequential, session-level measurements rather than interleaved
per-image timings, so the apparent 16% latency increase should not be treated as a
precise causal estimate.

## Offline adaptive-policy replay

The replay tested:

- **unchanged hypothesis:** stop when consecutive calls use the same `visualGroup`;
- **evidence threshold:** stop when the top retrieved confidence reaches 45%.

| Policy | Agreement with actual stop | Mean suggested calls | Accuracy when stop matched |
| --- | ---: | ---: | ---: |
| Unchanged hypothesis | 98.8% (328/332) | 1.23 | 37.5% (matched subset only) |
| Evidence ≥45% | 98.5% (327/332) | 1.23 | 37.9% (matched subset only) |

These high agreement rates are mostly mechanical: **260 of 332** four-call-condition
images stopped after one call, and neither replay can suggest an earlier call than one.
On the 72 genuinely multi-call images, agreement was **94.4% (68/72)** for unchanged
hypothesis and **93.1% (67/72)** for evidence threshold. Each policy saved only five
total calls across that subset.

The replay functions also default to the actual final pass when their trigger never
fires. Agreement therefore means "the rule did not request an earlier stop" as often as
it means "the rule positively selected this stopping point." It should not be read as a
98% validation of either rule.

## Confidence labels

Model confidence did not cleanly distinguish the few replay disagreements. Under the
evidence rule, the matched rows included 154 high-, 150 medium-, 20 low-, and 3
unknown-confidence answers. Because the label is attached only to the final answer,
this cross-tab cannot tell whether an earlier confidence label would have agreed with
the proposed stop.

## Interpretation

The defensible stopping result is empirical rather than counterfactual: **the two-call
condition was more accurate than the four-call prompt condition while using essentially
the same mean number of calls**. The alternative replay rules barely changed the traces
and lack intermediate answers, so they do not provide enough evidence to replace the
cap.

For the evaluated Gemma baseline, the next confirmatory experiment should test a
hard-enforced two-search-call cap and record a candidate choice after every call. The
current run nominates that cap; it does not settle the two-versus-four comparison.
Repeated runs would show whether the advantage survives sampling and prompt variation,
while intermediate choices would make wrong-to-correct transitions and genuine
counterfactual stopping accuracy measurable.

## Relation to the current Flutter runtime

The current app branch is not the runtime evaluated here. It uses Qwen3 plus separate
vision tools and allows five **generation passes**, which are not the same as five
search calls: observation, verification, and search can each consume a pass, and one
pass may contain parallel calls. If Track 04 is repeated on that branch, the trace must
record tool type and search-call count separately rather than treating generation
passes as identification attempts.
