# Hugging Face Logit Rank Bias

## Purpose

This report checks whether the same candidate receives different completion likelihood under Hugging Face Gemma 4 when it is moved to different list positions.

This is the first score-level Hugging Face follow-up to the candidate-rank-sensitivity work. The earlier behavioral experiments showed that reordering the same candidate set can sometimes change the final answer. The question here is narrower: if we hold the candidate identity fixed and move that same candidate to a different list position, does its scored completion likelihood move with the position?

## Research Question

When the exact same candidate is moved between rank 1, rank 3, and rank 5, does its completion likelihood change in a systematic way under the Hugging Face Gemma 4 backend?

## Summary

The short answer is yes. In the Hugging Face Gemma 4 E2B backend, the same candidate is usually scored more favorably when it appears earlier in the list.

The strongest statistic is the paired within-candidate comparison: when the exact same candidate is moved between rank 1 and rank 5, the mean average-logprob advantage for rank 1 is `0.504`, with a 95% example-level bootstrap interval of `[0.415, 0.599]`. Rank 5 beats rank 1 in only `15.6%` of directly comparable trajectories.

That is the main result from this step: the score surface itself is position-sensitive even before we ask where that effect is implemented internally.

## Hypothesis

If Gemma 4 is position-sensitive at the scoring level, then the same candidate should receive higher completion likelihood when it appears earlier in the list than when it appears later.

## Motivation and Method

The earlier behavioral study established that answer changes can happen when the candidate list is reordered. That tells us there is behavioral sensitivity, but it does not tell us whether the effect is already visible in the scoring geometry of the model or whether it only appears at the final decision boundary.

If the score changes systematically with position, then rank sensitivity is already present at the candidate-likelihood level. That is a stronger and cleaner claim than just saying the final answer sometimes flips.

We use the frozen examples from the candidate-rank-sensitivity pipeline and run a text-only Hugging Face scoring backend with `google/gemma-4-E2B-it`.

For each example:

- keep the candidate identities fixed
- move the same target candidate to rank 1, rank 3, and rank 5 when those positions exist
- keep the prompt template fixed as a numbered candidate list
- score only the completion tokens for the candidate answer

The current scoring implementation uses corrected boundary alignment:

- tokenize `prompt` and `completion` separately
- concatenate the token ids directly
- score only the completion-token slice

This matters because this score-level analysis depends on candidate completion likelihood. A looser `prompt` versus `prompt + completion` boundary can drift at the tokenizer join and contaminate the completion slice.

The scored completion also uses an explicit prefix:

- `completion_prefix = "space"`

That choice is recorded in every output row along with:

- `prompt_hash`
- `scoring_mode`
- `completion_prefix`
- `model_dtype`
- `device`
- `transformers_version`
- `torch_version`

The full rerun completed on Apple GPU (`mps`) with:

- `model_id = google/gemma-4-E2B-it`
- `scoring_mode = completion_only_logprob`
- `completion_prefix = space`
- `model_dtype = torch.float16`
- `transformers_version = 5.12.1`
- `torch_version = 2.12.1`

## Analysis Design

Several additional changes make the analysis stronger:

- the completion prefix is explicit and recorded in each row
- paired same-candidate deltas are treated as the primary statistic instead of only pooled mean rank effects
- example-level bootstrap confidence intervals are included for the main paired rank 1 versus rank 5 effect
- comparable-only summaries are included so pooled rank means do not quietly benefit from examples that lack all target positions
- candidate-centered score views and token-length audits are included to reduce confusion from species-name ease and length effects
- a randomized-rank null baseline is included as a simple sanity check

The practical consequence is straightforward: the old full `01` result should be treated as provisional, and the current rerun should replace it in the main research story.

## Metrics

- `mean_logprob_by_rank`
- `mean_total_logprob_by_rank`
- `mean_token_count_by_rank`
- `same_candidate_rank1_vs_rank3_mean_delta`
- `same_candidate_rank1_vs_rank5_mean_delta`
- `same_candidate_rank3_vs_rank5_mean_delta`
- `same_candidate_rank5_beats_rank1_rate`
- `same_candidate_rank1_vs_rank5_bootstrap_ci`
- `candidate_centered_avg_logprob_by_rank`
- `candidate_centered_total_logprob_by_rank`
- `rank_logprob_correlation`
- `correlation_token_count_avg_logprob`
- `correlation_token_count_total_logprob`
- `randomized_rank_label_null`
- `comparable_all_positions_count`
- `comparable_mean_logprob_by_rank`
- `comparable_best_scoring_rank_counts`
- `comparable_rank_1_best_rate`
- `comparable_rank_5_best_rate`

## Results

The corrected full run completed on `119` frozen examples and produced `1,313` scored candidate-position rows. Most rows come from 5-candidate examples, with smaller contributions from 3-candidate and 2-candidate cases.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 119 | Full frozen set used for the corrected `01` run |
| Scored rows | 1,313 | All candidate-position scoring rows written by the rerun |
| Mean avg logprob at rank 1 | -3.325 | Earlier positions are better if they are less negative |
| Mean avg logprob at rank 3 | -4.203 | The middle position is notably worse than rank 1 |
| Mean avg logprob at rank 5 | -3.896 | Rank 5 is also worse than rank 1, but less bad than rank 3 |
| Same-candidate rank 1 minus rank 3 | +0.799 | Within-candidate early-position advantage |
| Same-candidate rank 1 minus rank 5 | +0.504 | Main paired score-level result |
| Same-candidate rank 3 minus rank 5 | -0.307 | Rank 5 modestly beats rank 3 on average |
| Rank-5 beats rank-1 rate | 15.6% | The late-position win case exists, but is a minority |
| Rank-1 best rate | 82.3% | Rank 1 is the best-scoring slot most often |
| Rank-5 best rate | 15.1% | Rank 5 can win, but much less often |
| Rank/logprob correlation | -0.210 | Later positions trend downward in score |
| Rank-1 vs rank-5 bootstrap CI | [0.415, 0.599] | The paired effect is not a fragile point estimate |

The main result is the paired same-candidate comparison. When the exact same candidate is moved from rank 1 to rank 5, its mean average-logprob decreases by `0.504`. The 95% example-level bootstrap interval stays positive, which is the cleanest evidence in this report that the score surface is not position-neutral.

The aggregate rank means point in the same direction:

- rank 1: `-3.325`
- rank 3: `-4.203`
- rank 5: `-3.896`

That pattern is not perfectly monotonic, because rank 5 still scores better than rank 3 on average. So the effect is better described as a strong top-slot advantage plus a weaker, uneven late-position behavior rather than a simple linear drop from top to bottom.

One caveat is that these pooled rank means are computed over all available rows, including examples that do not have every target position. That does not affect the paired same-candidate conclusions, but it can make the pooled rank block look less strict than the directly comparable subset.

### Comparable-Only Subset

To address that concern, we can restrict the summary to trajectories where all target positions `{1, 3, 5}` exist. That comparable-only subset contains `385` trajectories.

| Metric | Value |
|---|---:|
| Comparable trajectories with ranks 1, 3, 5 | 385 |
| Comparable mean avg logprob at rank 1 | -3.391 |
| Comparable mean avg logprob at rank 3 | -4.203 |
| Comparable mean avg logprob at rank 5 | -3.896 |
| Comparable rank-1 best count | 309 |
| Comparable rank-3 best count | 18 |
| Comparable rank-5 best count | 58 |
| Comparable rank-1 best rate | 80.3% |
| Comparable rank-5 best rate | 15.1% |

These comparable-only values support the same conclusion as the pooled summary. Rank 1 remains the strongest slot, rank 5 remains a minority win case, and the strict subset does not remove the early-position advantage.

### Paired Deltas

The paired deltas are the most defensible numbers because they compare the same candidate against itself:

| Pair | Comparisons | Mean delta |
|---|---:|---:|
| Rank 1 minus rank 3 | 442 | +0.799 |
| Rank 1 minus rank 5 | 385 | +0.504 |
| Rank 3 minus rank 5 | 385 | -0.307 |

The rank 1 versus rank 5 comparison is the central result. A positive `0.504` mean delta means the same candidate is usually more likely when listed first than when listed fifth.

The bootstrap interval confirms that this is not just a few extreme rows:

| Statistic | Mean | 95% CI |
|---|---:|---:|
| Same-candidate rank 1 minus rank 5 | 0.504 | [0.415, 0.599] |

### Candidate-Centered View

One reasonable concern is that some species names are simply easier for the model to score. The candidate-centered view reduces that concern by subtracting each candidate’s own mean score across tested positions.

| Rank | Candidate-centered avg logprob |
|---|---:|
| 1 | +0.389 |
| 3 | -0.371 |
| 5 | -0.066 |

That centered pattern still favors rank 1. So the effect is not just that easy species happen to appear more often in one slot.

### Token-Length Audit

Full sequence log probability can be misleading because longer names accumulate more negative logprob. That is why average token logprob is the preferred metric here.

The token-length audit helps show how much that matters:

| Metric | Value |
|---|---:|
| Mean token count at rank 1 | 5.391 |
| Mean token count at rank 3 | 5.398 |
| Mean token count at rank 5 | 5.444 |
| Token count vs avg logprob correlation | +0.796 |
| Token count vs total logprob correlation | -0.094 |
| Rank effect using avg logprob | +0.504 |
| Rank effect using total logprob | +2.415 |

The near-equal mean token counts by rank are helpful because rank is not trivially proxying name length. But the large gap between the average-logprob rank effect and the total-logprob rank effect is still a warning: total logprob exaggerates the magnitude of the rank effect, so the average-logprob view is the one to trust for cross-candidate interpretation.

### Null Baseline

The randomized-rank null baseline is a lightweight sanity check. After shuffling the rank labels post hoc, the effect becomes much smaller:

| Null metric | Value |
|---|---:|
| Null rank 1 minus rank 5 mean delta | +0.117 |
| Null same-candidate rank 1 minus rank 5 delta | -0.003 |
| Null rank/logprob correlation | -0.049 |

That is exactly what we want from the null. The real paired rank effect is substantially larger than the shuffled-label baseline.

### Representative Examples

The aggregate trend is clear, but the example-level spread matters because it shows the effect is not uniform across all images and candidates.

Some candidate trajectories show very strong rank-1 advantage:

| Example | Candidate | Rank 1 minus rank 5 avg-logprob delta | Reading |
|---|---|---:|---|
| `pongo_pygmaeus_1.jpg` | `Macaca fascicularis` | +6.036 | Very strong top-slot lift for the same distractor |
| `macaca_nigra_c.jpg` | `Macaca fascicularis` | +5.688 | Strong early-position preference |
| `lophura_erythrophthalma_a.jpg` | `Macaca maura` | +4.702 | Large within-candidate position effect |
| `macaca_nemestrina_b.jpg` | `Macaca maura` | +3.952 | Strong rank-1 gain for the same species name |

There are also counterexamples where rank 5 beats rank 1:

| Example | Candidate | Rank 5 minus rank 1 avg-logprob gain | Reading |
|---|---|---:|---|
| `macaca_nigra_1.jpg` | `Pongo pygmaeus` | +2.111 | Clear late-position win case |
| `fregata_andrewsi_2.jpg` | `Aythya affinis` | +1.815 | Another substantial rank-5 preference |
| `lophura_erythrophthalma_a.jpg` | `Macaca nigra` | +1.153 | The effect is not one-directional on every row |

That mixture is important. The model is not rigidly “always choose rank 1.” Instead, the score landscape is biased toward early positions overall, but there are real late-position wins in a minority of trajectories.

## Interpretation Guide

This run supports a stronger claim than the earlier behavioral baseline, but still a bounded one.

What it does support:

- the same candidate’s completion likelihood depends on list position
- the strongest and cleanest effect is a top-slot advantage
- that effect survives paired within-candidate comparison, candidate-centering, and a simple null baseline

What it does not support:

- a claim about internal causal circuitry
- a claim that rank bias is always monotonic from top to bottom
- a claim that the deployed LiteRT runtime behaves identically to this Hugging Face backend

The rank 3 versus rank 5 relationship is especially worth noting. Rank 5 beats rank 3 on average, which means the effect is not just “later is worse.” The safer reading is:

- rank 1 is the strongest attractor
- middle positions are weaker
- late positions can sometimes recover relative to the middle

That pattern may end up mattering when we interpret prompt-format controls and later activation-patching results.

## Decision Rule

The strongest evidence for a real score-level position effect is a positive same-candidate rank 1 versus rank 5 delta that remains positive under example-level bootstrap and is clearly larger than the randomized-rank null baseline.

The strongest evidence against a trivial short-list artifact is agreement between the pooled summary and the comparable-only subset where ranks 1, 3, and 5 all exist.

The strongest evidence against a pure candidate-name-ease explanation is a rank effect that remains visible after candidate-centering.

## Conclusion

The corrected `01` rerun shows a real score-level position effect in the Hugging Face Gemma 4 E2B backend. The main evidence is the paired same-candidate result: moving the same candidate from rank 1 to rank 5 lowers its mean average-logprob by `0.504`, with a 95% bootstrap interval of `[0.415, 0.599]`. Rank 5 beats rank 1 in only `15.6%` of directly comparable trajectories.

So the score-level story is now defensible: position sensitivity is visible before we appeal to hidden-state probes or activation patching. That does not yet explain the mechanism, but it is enough to justify continuing to the next interpretability step.

## Limitations

- This is a Hugging Face mechanistic backend, not the LiteRT runtime used in deployment.
- The result reflects token likelihood under the analysis backend, not causal activation evidence.
- Moving a candidate changes both its rank and its surrounding candidate context. The paired comparison controls candidate identity, but not all local-context effects.
- A stronger future version should randomize or counterbalance the surrounding candidates as an additional control.
- The result is text-only; image evidence is intentionally excluded at this stage.
- The null baseline is deliberately simple. It is a sanity check, not a full hypothesis test.

## Next Steps

- Run the prompt-format control analysis on top of this corrected `01` baseline.
- Fix the probe persistence and label-handling issues before trusting `03a_probe_candidate_position_hf.py`.
- Add activation-patching sanity baselines before trusting `04_activation_patching_rank_bias_hf.py`.
- Compare the Hugging Face score-level pattern against the earlier LiteRT score analysis in one compact cross-backend table.
