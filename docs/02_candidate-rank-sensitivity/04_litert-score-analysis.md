# LiteRT Rank Bias Analysis in Gemma 4 Species Identification

## Summary

This is the follow-up to the candidate-rank-sensitivity work. It combines two related but distinct measurements:

1. output-position bias from generated answers on confidence-perturbed trials
2. true LiteRT token-score candidate likelihood from `run_text_scoring(...)`

The point of merging them is simple: they answer the same rank-bias question from two different angles, and the docs are easier to follow when those angles live in one place.

The short version is:

- generated answers show a clear output-position effect
- LiteRT token scores expose a real candidate-likelihood signal
- the two surfaces are related, but they are not the same measurement

## Why This Exists

Mero presents Gemma 4 with ranked candidates. That makes rank part of the product behavior, not just an implementation detail. We therefore want to know both:

- whether the final answer tends to favor early positions
- whether LiteRT-LM's scoring surface assigns different likelihoods to the same candidate when its list position changes

This report stays inside LiteRT-LM's public surface. It does not claim hidden-state causality or internal circuit structure.

## Part 1: Output-Position Bias

### Method

We analyze `outputs/candidate-rank-sensitivity/confidence_score_results.jsonl` with the output-position summary script, `scripts/candidate-rank-sensitivity/analyze_score_rank_bias.py`.

The analysis is deliberately output-level:

- it reads the final answer and selected candidate rank from each trial
- it measures how often rank 1 is chosen
- it measures how often the selected candidate matches the highest-confidence candidate
- it compares the observed rank-1 rate with a uniform baseline adjusted for candidate-list length

Because the number of candidates varies across examples, a raw percentage is not enough by itself. The script therefore computes the expected uniform rank-1 rate over the actual candidate-count distribution and compares the observed rate against that baseline.

### Results

The output-position analysis covered 119 frozen examples and 595 confidence-perturbed variant rows. Across those variant rows, the model chose the first-listed candidate 53.9% of the time, the last-listed candidate 21.8% of the time, and either edge 74.1% of the time. The expected uniform rank-1 and rank-last rate for the actual dataset mix is 28.8%, so the top-slot preference is 25.2 percentage points higher than a uniform baseline, while the last-slot preference is 8.9 points above the same baseline.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 119 | This is the full frozen set used for the output-position analysis |
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

That combination is important. The output-position bias is not just a byproduct of a few pathological examples. It is a dataset-wide tendency that persists even though some examples are stable. The bottom candidate is not ignored completely, but the top slot is the stronger attractor.

### Interpretation

This analysis does not prove a hidden circuit or a causal internal mechanism. It does show that the model’s output behavior is strongly skewed toward earlier positions and that the selected candidate often lines up with the top displayed confidence. In other words, the output surface is rank-sensitive even before we ask where the computation lives internally.

That is exactly why this report keeps the two measurements separate. The generated-answer analysis tells us whether the answer changes under perturbation. The token-score analysis tells us whether the underlying completion likelihood is position-neutral. They are related, but they answer different questions.

## Part 2: LiteRT Token Scores

### Motivation

The output-position result is useful, but it still depends on generated answers. This second measurement asks a stricter question: if we score the same candidate name as a completion after the prompt, does the likelihood of that completion change when the candidate moves to different list positions?

That distinction matters. Output-position bias and token-score bias are related, but they are not the same measurement. The first looks at what the model picked. The second looks at how the model scores the candidate string itself.

### Method

We used `scripts/candidate-rank-sensitivity/analyze_litert_candidate_likelihood.py` with the frozen confidence-sensitivity examples in `outputs/candidate-rank-sensitivity/confidence_score_examples.jsonl`.

For each example:

1. Take the original candidate list.
2. Move each candidate to rank 1, rank 3, and rank 5 when those positions exist.
3. Build a text-only prompt that lists the candidates in that order.
4. Score the candidate's scientific name as the completion with `run_text_scoring(...)`.
5. Compare the same candidate's mean token log-likelihood across positions.

This gives a direct token-score comparison for the same candidate under different list positions.

### Results

The run covered 119 examples and produced 1,313 scored candidate-position rows. The observed pattern is not a simple primacy story. Rank 3 slightly outperformed rank 1 in pairwise comparisons, and rank 5 had the highest mean token score among the scored positions.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 119 | Full frozen set used for the token-score analysis |
| Scored rows | 1,313 | Candidate-position pairs scored with LiteRT-LM |
| Positions scored | 1, 3, 5 | The analysis targets the user-requested anchor positions |
| Mean token score, rank 1 | -1.417 | Lower than rank 5, which means rank 1 is not the most likely completion here |
| Mean token score, rank 3 | -1.506 | Slightly below rank 1 on average |
| Mean token score, rank 5 | -0.892 | Highest average likelihood in this text-only setup |
| Rank 1 beats rank 3 | 52.0% | Rank 1 is only a narrow winner over rank 3 |
| Rank 1 beats rank 5 | 16.6% | Rank 1 loses strongly to rank 5 in this scoring setup |
| Rank 1 best-candidate rate | 15.8% | For individual candidate trajectories, rank 1 is rarely the best position |
| Rank 1 best-example rate | 4.2% | At the example level, rank 1 is the best of the scored positions only rarely |

The main result is that the LiteRT token-score surface is not primacy-dominated. If anything, the text scorer shows a recency tilt on this prompt construction, with rank 5 receiving the strongest average token likelihood. That does not contradict the output-position analysis. It just means the generated answer behavior and the candidate-likelihood surface are measuring different things.

The strongest interpretation is therefore modest: LiteRT-LM can expose a real candidate-likelihood signal, but that signal is prompt-sensitive and not identical to the model's final selection behavior.

### Interpretation

This result is useful for two reasons.

1. It gives a direct token-score readout from LiteRT-LM, which is stronger evidence than inferring rank effects from generated answers alone.
2. It shows that the token-score surface can behave differently from the output surface, so the two measurements should not be conflated.

The recency tilt here may come from the prompt form, the candidate wording, or tokenization effects. The public text-scoring API does not let us isolate those causes further. So the correct claim is not "the model prefers the last option everywhere." The correct claim is "in this text-only candidate-likelihood setup, the last position had the highest average token likelihood."

## Synthesis

Taken together, the behavioral results point to two different rank-sensitive surfaces: candidate order has a small effect on the final answer, confidence display has a much larger effect, and LiteRT token scoring favors later positions rather than early ones. That tension is the reason the project needs a mechanistic backend rather than another behavioral pass.

LiteRT can show us output behavior and token likelihood, but it cannot expose the hidden states or hooks needed to test how the bias is computed. The next step therefore uses the Hugging Face Gemma 4 backend in the Candidate Rank Mechanistic folder to ask three narrower questions:

- Is the token-score mismatch real in Gemma 4 itself, or an artifact of the LiteRT scoring path?
- Does candidate position appear in the hidden states?
- Can rank-related activations be shifted causally with patching?

## Limitations

- The output-position analysis uses final output ranks and selected answers, not hidden states.
- The token-score analysis is text-only because LiteRT-LM's public scoring API does not take image inputs.
- Neither part proves a causal mechanism.
- The two measurements should be read together, but not merged conceptually.


## Next Steps

- Compare the token-score surface with the output-position bias report in a single table
- Test whether the recency tilt remains when the prompt template is simplified
- Try a candidate-likelihood variant that scores only the scientific name versus the common+scientific display string
- Replicate the token-score result with Hugging Face Gemma 4 logits to test whether the rank-5 advantage is a LiteRT scoring artifact or a model-level effect
