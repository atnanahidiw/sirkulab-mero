# Explanation Faithfulness in Gemma 4 Species Identification

## Summary

This analysis asks a narrower question than candidate-rank sensitivity: when Gemma 4 gives a short natural-language reason for its species answer, does that reason stay aligned with the answer when we perturb only the candidate order? The goal is not to prove causal faithfulness in a strict mechanistic sense. Instead, it is to run a concrete counterfactual consistency audit on the model's own self-explanations using the same frozen rank-sensitivity examples that already exist in the repo.

The key idea is simple. If the model changes its answer after we reorder the same candidates, the explanation should change in a way that tracks the new answer. If the answer changes but the explanation stays basically the same, that is a stale-rationale signal. If the answer stays the same and the explanation stays close, that is weaker evidence of consistency, though not proof of causality.

## Why This Matters

Candidate rank sensitivity tells us whether the final answer is order-sensitive. Explanation faithfulness asks something slightly different: when the model explains itself, does the explanation behave like a real justification for the chosen answer, or does it read like a generic post-hoc caption?

That distinction matters for Mero because the UI does not only show an answer. It also surfaces the model's justification. If the justification is stable even when the answer moves, then the explanation is not tightly coupled to the decision. If the justification shifts with the answer, that is a better sign, though still only behavioral evidence.

This is also why the analysis is separated from the rank report. Rank sensitivity is about output stability. Faithfulness is about explanation-output coupling. They are related, but they should not be merged into one result section.

## Hypothesis

The model's short explanation should change when the answer changes, and it should stay broadly aligned with the selected candidate when the answer stays fixed. If the explanation remains similar across answer flips, then the rationale is stale rather than decision-linked.

## Method

We reused the frozen rank-sensitivity run from `outputs/candidate-rank-sensitivity/reverse_big/checkpointed_results.jsonl`. That file contains the original-order row plus the shuffled and reverse-order rows for each example. The new analyzer, `scripts/candidate-rank-sensitivity/01n-analyze_explanation_faithfulness.py`, reads those rows and extracts the `short_reason` field from the model's JSON response.

The audit is intentionally lightweight. It does not generate new counterfactual images, and it does not call a separate judge model. Instead, it treats the already-collected original and perturbed rows as paired observations and measures how the explanation changes under those paired perturbations.

### What the analyzer checks

| Check | What it asks |
|---|---|
| Answer flip rate | Did the species answer change under the order perturbation? |
| Reason similarity | How similar is the short reason before and after the perturbation? |
| Support alignment | Does the reason mention candidate-specific or taxonomy-specific terms from the selected answer? |
| Stance consistency | Does the reason stay in the same coarse semantic bucket, such as animal, plant, or marine? |

### Implementation notes

The analyzer uses a few simple heuristics:

1. It parses `short_reason` from the JSON response.
2. It identifies the selected candidate from `selected_candidate_rank` when present, or falls back to the predicted species name.
3. It computes token-level Jaccard similarity between the original and perturbed reasons.
4. It checks whether the reason contains terms that support the selected candidate, such as the scientific name, common name, genus, or coarse group labels.
5. It records examples where answer flips occur but the explanation stays highly similar.

This is not a full causal faithfulness test. It is a practical consistency audit that works with the artifacts already produced by the rank experiment.

## Metrics

| Metric | Meaning |
|---|---|
| `answer_flip_rate` | Fraction of perturbed rows where the answer differs from the original-order answer |
| `mean_reason_jaccard` | Average token overlap between the original reason and the perturbed reason |
| `mean_reason_jaccard_same_answer` | Average reason overlap when the answer stays the same |
| `mean_reason_jaccard_flipped_answer` | Average reason overlap when the answer changes |
| `original_support_rate` | Fraction of original rows whose reason mentions candidate-supporting terms |
| `variant_support_rate` | Same support check on perturbed rows |
| `original_stance_consistency_rate` | Fraction of original rows where the reason bucket matches the selected candidate bucket |
| `variant_stance_consistency_rate` | Same stance check on perturbed rows |
| `flip_reason_same_rate` | Fraction of answer flips where the reason text is exactly unchanged |
| `flip_reason_similar_rate` | Fraction of answer flips where the reason similarity is very high |
| `flip_variant_supported_rate` | Fraction of answer flips where the perturbed reason still supports the perturbed answer |
| `flip_stance_matches_variant_rate` | Fraction of answer flips where the perturbed reason bucket matches the perturbed candidate bucket |

## Results

The audit was run on the same 125-example reverse-order checkpointed rank-sensitivity set. That produced 250 perturbed rows, because each example contributes one shuffled row and one reverse-order row.

| Metric | Value | Reading |
|---|---:|---|
| Examples | 125 | Full frozen set used by the rank experiment |
| Perturbed rows | 250 | One shuffled and one reverse-order row per example |
| Answer flip rate | 5.2% | A small number of order changes altered the answer |
| Mean reason Jaccard | 0.537 | On average, reasons remained somewhat similar across perturbations |
| Mean reason Jaccard, same answer | 0.533 | Similarity stays high when the answer stays fixed |
| Mean reason Jaccard, flipped answer | 0.010 | When the answer changes, the reason usually changes too |
| Original support rate | 99.2% | Original reasons usually mention supporting candidate terms |
| Variant support rate | 99.6% | Perturbed reasons are still usually grounded in candidate terms |
| Original stance consistency rate | 81.6% | Most original reasons stay in the right coarse semantic bucket |
| Variant stance consistency rate | 80.0% | Perturbed reasons behave similarly |
| Flip reason same rate | 0.0% | We did not see exact explanation reuse on answer flips |
| Flip reason similar rate | 0.0% | We also did not see near-duplicate reasons on flips |
| Flip variant supported rate | 92.3% | Most flipped answers still have a reason that mentions the new candidate |
| Flip stance matches variant rate | 69.2% | Coarse bucket alignment is common, but not perfect |

The main result is the separation between same-answer and flipped-answer cases. The reasons stay moderately similar when the answer does not move, but the similarity collapses when the answer flips. That is the behavior we would want from an explanation that is at least partly tied to the chosen answer.

The result is still only behavioral. It does not prove that the explanation caused the answer or that the model used the explanation internally. It does show that the explanation is not obviously static text pasted across different answers.

## Example Patterns

The per-example audit shows a few distinct patterns.

| Pattern | Example | What happened |
|---|---|---|
| Stable answer, stable reason | `pongo_abelii_b.jpg` | The answer stayed fixed and the reason remained closely aligned |
| Stable answer, different but still aligned reason | `aulacorhynchus_prasinus_2.jpg` | The wording shifted, but it stayed on the same bird description |
| Answer flip with reason shift | `artocarpus_altilis_1.jpg` | The answer changed and the explanation moved with it |
| Multi-way instability | `koordersiodendron_pinnatum_1.jpg` | Both perturbations produced different behavior, showing a brittle case |
| Stance mismatch | `tectona_grandis_1.jpg` | The explanation described a habitat cue that was only weakly tied to the selected answer |

The most important signal is not that every explanation is perfect. It is that the explanation usually moves with the answer rather than remaining frozen. That makes the audit useful as a sanity check on self-explanations, even though it does not certify causality.

## Interpretation

The numbers support a cautious but useful conclusion. The model's explanations are not fully static, and they usually track the answer change when the order perturbation changes the answer. The near-zero mean similarity on flipped answers is especially important: it suggests that answer flips are typically accompanied by a substantive change in the reason text, not just a minor wording edit.

At the same time, the support and stance metrics show that the reasons are still coarse. Many explanations are generic, and some rely on broad cues like "bird," "plant," or "coral" rather than precise candidate-specific evidence. So the explanation is behaving like a weak justification, not a strong mechanistic trace.

This is why the correct framing is "counterfactual consistency audit" rather than "proof of faithfulness." The model passes a basic behavioral consistency check, but the explanation quality is still limited by how generic the generated reason can be.

## Limitations

This analysis has three important limits.

1. It is a post-hoc behavioral check, not a causal intervention study.
2. It depends on short free-text rationales, which can be generic even when they are aligned.
3. The support and stance heuristics are coarse, so they can undercount or overcount alignment when the model uses unusual wording.

Because of those limits, the audit should be read as a useful screen for stale rationales, not as a final proof that the explanation is truly faithful.

## Sources

### Local artifacts

- [scripts/candidate-rank-sensitivity/01n-analyze_explanation_faithfulness.py](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/scripts/candidate-rank-sensitivity/01n-analyze_explanation_faithfulness.py)
- [outputs/candidate-rank-sensitivity/reverse_big/checkpointed_results.jsonl](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/outputs/candidate-rank-sensitivity/reverse_big/checkpointed_results.jsonl)
- [outputs/candidate-rank-sensitivity/explanation_faithfulness_summary.json](/Users/atnanahidiw/.openclaw/workspace/workdir/sirkulab-mero/outputs/candidate-rank-sensitivity/explanation_faithfulness_summary.json)

### Related work

- [A Necessary Step toward Faithfulness: Measuring and Improving Consistency in Free-Text Explanations](https://arxiv.org/abs/2505.19299)
- [Are self-explanations from Large Language Models faithful?](https://arxiv.org/abs/2401.07927)
- [Explanation-Driven Counterfactual Testing for Faithfulness in Vision-Language Model Explanations](https://arxiv.org/abs/2510.00047)

## Next Steps

- Tighten the explanation parser for edge cases where the response omits `short_reason`
- Replace the heuristic support check with a stricter candidate-evidence classifier
- Add a second faithfulness pass on the confidence-sensitivity run
- Compare faithfulness on examples that are stable in answer versus examples that flip
