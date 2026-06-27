# LiteRT Score Analysis for Candidate Rank Bias in Gemma 4

## Summary

This report is the LiteRT-compatible Layer 2A follow-up to the candidate-rank-sensitivity work. The earlier behavioral experiment asked whether the final answer changes when the same candidate set is reordered. This score-level analysis asks a narrower question: when we keep the same frozen examples and the same confidence-perturbed trials, does the model’s output behavior still show a strong preference for earlier list positions?

The short answer is yes. Even without hidden states or activation access, the output-level score surface is not neutral. The model selected the first-listed candidate in 53.9% of variant trials, the last-listed candidate in 21.8%, and either edge in 74.1%. Relative to the varying candidate-list sizes in the dataset, that is a large primacy bias plus a smaller but still visible recency effect.

## Motivation

This report stays inside the public LiteRT-LM surface. It does not try to claim hidden-state causality or internal circuit structure. Instead, it uses the already-collected confidence-sensitivity results to measure whether the model’s choice distribution is skewed toward earlier positions and whether the selected candidate tends to line up with the highest-confidence candidate shown in the prompt.

That is worth measuring because rank bias can exist even when the model is not wildly unstable. A model can be mostly correct, yet still show a strong default toward the first item in the list. For Mero, that matters because the candidate list itself is part of the product behavior, so a systematic preference for the front of the list is a real design risk even if the final accuracy stays acceptable.

## Hypothesis

If candidate order is influencing the model’s output behavior, then the selected candidate rank should be skewed toward the edges in a structured way: primacy at the top, recency at the bottom, or both. The model should also often agree with the highest-confidence candidate when confidence and order coincide.

## Method

We analyze the current `outputs/candidate-rank-sensitivity/confidence_score_results.jsonl` file with the new LiteRT-compatible score summary script, `scripts/candidate-rank-sensitivity/01i-analyze_score_rank_bias.py`.

The analysis is deliberately output-level:

- it reads the final answer and selected candidate rank from each trial
- it measures how often rank 1 is chosen
- it measures how often the selected candidate matches the highest-confidence candidate
- it compares the observed rank-1 rate with a uniform baseline adjusted for candidate-list length

Because the number of candidates varies across examples, a raw 20% or 50% rate is not enough by itself. The baseline has to account for the fact that some examples have only two candidates, while others have five. The script therefore computes the expected uniform rank-1 rate over the actual candidate-count distribution and compares the observed rate against that baseline.

## Results

The score-level analysis covered 119 frozen examples and 595 confidence-perturbed variant rows. Across those variant rows, the model chose the first-listed candidate 53.9% of the time, the last-listed candidate 21.8% of the time, and either edge 74.1% of the time. The expected uniform rank-1 and rank-last rate for the actual dataset mix is 28.8%, so the top-slot preference is 25.2 percentage points higher than a uniform baseline, while the last-slot preference is 8.9 points above the same baseline.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 119 | This is the full frozen set used for the score analysis |
| Original rows | 119 | One baseline answer per example |
| Variant rows | 595 | Five confidence permutations per example |
| Answer-changed rate | 33.1% | Confidence perturbation still changes a meaningful share of outputs |
| Rank-1 selected rate | 53.9% | The first candidate is selected far more often than chance |
| Last-rank selected rate | 21.8% | The bottom candidate is chosen less often than the first |
| Edge selected rate | 74.1% | The model disproportionately lands on either edge of the list |
| Highest-confidence agreement rate | 53.3% | The selected candidate often matches the top displayed confidence |
| Mean selected rank | 2.14 | The model is not always choosing rank 1, but it is skewed early |
| Mean highest-confidence rank | 2.36 | The highest-confidence item is also often near the front, but not always |
| Mean selected minus top rank | -0.21 | On average, selected rank is slightly earlier than the highest-confidence rank |
| Rank-1 bias vs uniform | +25.2 pp | The rank-1 preference is large relative to the dataset baseline |
| Last-rank bias vs uniform | +8.9 pp | The bottom-slot preference is present but weaker than primacy |
| Edge-selection bias vs uniform | +32.4 pp | Both edges together are preferred much more than chance |
| Examples with any flip | 74 | Confidence perturbation still changes many examples at least once |

The main signal here is the edge effect, with a stronger primacy component than recency. A 53.9% first-candidate selection rate is not subtle. Even after correcting for the fact that some examples only have two candidates, the observed rank-1 rate is still much higher than the 28.8% uniform baseline. The last-candidate rate is also elevated relative to chance, but not nearly as much as the top slot. That means the model’s output behavior is not evenly distributed across candidate positions, and it is not symmetric across the list.

The highest-confidence agreement rate is also informative. At 53.3%, it is almost identical to the rank-1 selection rate, which suggests that confidence and position are interacting rather than competing. In this dataset, the top confidence candidate is frequently near the front, and the model often converges on that early item.

The per-example summaries show that the bias is not identical across all images. Some examples are strongly rank-1 locked, while others are much more sensitive to confidence reassignment and can move away from the first item. But the aggregate pattern is still clear: earlier positions dominate.

The most confidence-sensitive examples illustrate the spread in behavior:

| Example | Original answer | Changed trial behavior | Reading |
|---|---|---|---|
| `bolbometopon_muricatum_1.jpg` | `Carcharhinus melanopterus` | changed in all 5 perturbed trials | Strong instability and no rank-1 lock |
| `argusianus_argus_1.jpg` | `Nasalis larvatus` | changed in all 5 perturbed trials | Highly brittle, with weak top-candidate stability |
| `echinopora_lamellosa_b.jpg` | `Echinopora lamellosa` | changed in 3 of 5 trials | Mixed stability, but still sensitive to score reassignment |
| `chelonia_mydas_b.jpg` | `Chelonia mydas` | never changed | A stable example, but still not enough to remove the aggregate bias |

That combination is important. The score-level bias is not just a byproduct of a few pathological examples. It is a dataset-wide tendency that persists even though some examples are stable. The bottom candidate is not ignored completely, but the top slot is the stronger attractor.

## Interpretation

This analysis does not prove a hidden circuit or a causal internal mechanism. It does show that the model’s output behavior is strongly skewed toward earlier positions and that the selected candidate often lines up with the top displayed confidence. In other words, the output surface is rank-sensitive even before we ask where the computation lives internally.

That is exactly why this report belongs in Layer 2A rather than Layer 1. Layer 1 tells us whether the answer changes under perturbation. Layer 2A tells us that the resulting output distribution itself is not position-neutral. The next step, if we want a mechanistic explanation, is a backend that exposes logits or activations.

## Limitations

This is still not mechanistic interpretability.

- It uses final output scores and selected ranks, not hidden states.
- It cannot separate “the model prefers rank 1” from “the prompt format or dataset structure makes rank 1 easier to adopt.”
- It does not explain why edge positions are preferred more often than middle positions.
- It does not support activation patching, probing, or SAE inspection.

So the correct claim is modest but useful: LiteRT-LM is enough to show score-level rank bias, but not enough to explain the internal mechanism behind it.

## Sources

### Local Artifacts

- [scripts/candidate-rank-sensitivity/analyze_score_rank_bias.py](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/scripts/candidate-rank-sensitivity/analyze_score_rank_bias.py)
- [outputs/candidate-rank-sensitivity/confidence_score_results.jsonl](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/outputs/candidate-rank-sensitivity/confidence_score_results.jsonl)
- [outputs/candidate-rank-sensitivity/score_rank_bias_summary.json](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/outputs/candidate-rank-sensitivity/score_rank_bias_summary.json)

## Next Steps

- Compare score-level rank bias against the rank-sensitivity summary on the same frozen examples
- Move the mechanistic Layer 2B work to a backend that exposes logits and hidden states
- Add a compact table that compares rank bias, confidence bias, and answer-change rate in one place
