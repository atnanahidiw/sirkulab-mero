# Revision analysis results

## Summary

The two-call trace shows a plausible retrieval mechanism: putting the true species into
the candidate list when the first call missed it. In that condition, the true species
first appeared in the actual top-five list on the final call for **39 images**;
**26 of those 39 (66.7%)** ended correctly. In the four-call prompt condition, 34 images
first had the true species available on their final call and **21 (61.8%)** ended
correctly.

This is evidence for retrieval revision, not a direct wrong-to-correct reasoning trace.
LiteRT-LM exposes the final answer and tool arguments but not the answer Gemma would
have emitted after each intermediate call.

## Artifacts

- Analyzer: [`01_revision_analysis.py`](../../scripts/agent-loop-evaluation/01_revision_analysis.py)
- Generated summary: [`revision_analysis_summary.json`](../../outputs/agent-loop-evaluation/revision_analysis_summary.json)
- Per-image trace: [`revision_analysis.jsonl`](../../outputs/agent-loop-evaluation/revision_analysis.jsonl)
- Source calls: `loop_ablation_{one-call,two-call,four-call}.jsonl`

## Candidate availability in the list Gemma saw

The tables below replay each saved call with `top_k=5`, matching the actual tool output.

| First top-five availability | One-call | Two-call | Four-call prompt |
| --- | ---: | ---: | ---: |
| Available at pass 1 | 156; 70.5% correct | 158; 68.4% correct | 157; 65.6% correct |
| First available at an intermediate pass | n/a | n/a | 1; 0.0% correct |
| First available only at final pass | n/a | 39; 66.7% correct | 34; 61.8% correct |
| Never available | 176; 1.1% correct | 135; 1.5% correct | 140; 0.7% correct |
| Available on any pass | 156 (47.0%) | **197 (59.3%)** | 192 (57.8%) |

The main bottleneck is visible in the last two rows. Final accuracy is almost zero when
the true species never enters the top five. Relative to the independent one-call run,
the two-call run has 12.3 percentage points higher top-five availability, and 26 of its
39 final-pass recoveries end correctly. The four-call prompt condition does not improve
further; its availability is slightly lower than the independently run two-call condition.

## Visual-group revision proxy

The only recorded hypothesis-like field at every call is `visualGroup`. A case counts
as changed when consecutive calls request different groups.

| Condition | No second call | Accuracy | Multi-call, group unchanged | Accuracy | Multi-call, group changed | Accuracy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Two-call | 253 | 42.7% | 17 | 5.9% | 62 | 43.5% |
| Four-call prompt | 260 | 38.8% | 23 | 13.0% | 49 | 42.9% |

Among images that continued, changed-group cases are descriptively more accurate than
same-group retries. This is not a causal comparison: difficult images decide whether
to continue, the groups are small, and a model can revise traits or taxonomy without
changing the broad visual group. Separating one-call stops from genuine same-group
retries avoids treating "no opportunity to change" as an unchanged hypothesis.

## Candidate-limit consistency

The analyzer replays `_run_search(..., top_k=5)`, matching the candidate limit used by
the live tool in `eval_gemma4_baseline.py`. The generated summary and this report
therefore measure availability in the candidate list Gemma actually saw.

## Interpretation

The two-call run is consistent with a concrete mechanism: broader retrieval
availability followed by a correct final answer in many recovered cases. What the trace
cannot show is whether Gemma held an incorrect final answer after pass one and then
reasoned itself to the correct one. The evidence is therefore best stated as:

> Adaptive revision recovered the true species into the top-five list on 39 two-call
> cases and 26 ended correctly; intermediate answer transitions were not observable.

The four-call allowance added no aggregate benefit over two calls. Combined with the
ablation, the result nominates one retrieval-revision opportunity for a confirmatory
run; it does not prove that revision caused the gain.

## Limitations

- Conditions are separate runs, not checkpoints from one shared trajectory.
- `visualGroup` change is a coarse proxy and misses within-group hypothesis revisions.
- Final correctness when the true species is absent from the top five can come from
  model prior knowledge or name matching; it does not mean retrieval succeeded.
- Candidate availability is necessary but not sufficient. Even when the true species
  appeared, selection still failed in roughly one-third of cases.
