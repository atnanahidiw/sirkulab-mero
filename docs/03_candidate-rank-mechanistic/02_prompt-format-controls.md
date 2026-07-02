# Prompt Format Controls

## Purpose

This report checks whether the score-level rank effect reported in [`Hugging Face Logit Rank Bias`](./01_hf-logit-rank-bias.md) survives changes in prompt formatting and answer formatting.

The previous report showed that the same candidate often receives higher completion likelihood when placed earlier in a numbered candidate list. That result made the score surface look position-sensitive. The question here is whether that effect is robust, or whether it depends on the particular way the candidates and answer field are written.

## Research Question

Does the score-level rank effect observed in Hugging Face Gemma 4 candidate completion likelihood survive when visible list markers, answer format, and distance to the answer field are changed?

## Summary

The short answer is: partly yes, but the effect is format-dependent.

The rank-1 advantage is strong in numbered and lettered lists, remains moderate in JSON formatting, nearly disappears in the bulleted format, and becomes very strong in the semicolon format. This means the rank effect is not only a numbered-list artifact, but it is also not a format-invariant property of the candidate identity alone.

The strongest candidate-name scoring effect appears in the semicolon format, where rank 1 minus rank 5 reaches `1.771` and the distance-to-answer correlation is `0.504`. That combination suggests that candidate position and recency-to-answer are entangled in this prompt family.

The answer-number condition is much larger, with a rank 1 minus rank 5 delta of `12.312`, but it should not be interpreted as species likelihood. It measures number-token preference under the answer format, not the model’s likelihood for the candidate species text.

The main result from `02` is therefore more nuanced than `01`: the score surface is position-sensitive, but the shape of that sensitivity depends strongly on formatting and answer representation.

## Hypothesis

If the rank effect is a general position effect, then the same-candidate rank 1 versus rank 5 advantage should remain visible across multiple prompt formats, including formats without explicit numerical rank markers.

If the rank effect is mainly a formatting artifact, then it should be strong in numbered or lettered lists but shrink substantially when visible list markers are removed.

If the rank effect is mainly driven by recency-to-answer, then candidate score should correlate with the distance between the candidate span and the answer field.

## Motivation and Method

The `01` analysis established that candidate likelihood changes when the same candidate is moved across list positions. However, that experiment used one fixed numbered-list prompt. That leaves several possible explanations open.

The observed effect could reflect a general position bias. It could reflect visible rank markers such as `1.` or `A.`. It could reflect the distance between the candidate text and the answer field. It could also be partly caused by the answer format itself.

This report tests those possibilities by keeping the candidate set fixed, moving the same target candidate across rank positions, and varying the prompt format.

For each frozen example, the script:

- keeps the candidate set fixed
- moves the same target candidate across rank positions
- evaluates multiple prompt variants
- scores only the completion associated with the target answer
- records candidate-span and answer-span metadata
- computes distance from the candidate span to the answer field

The analysis keeps three cases distinct:

- candidate-name scoring, where the same species text is scored across positions
- answer-number scoring, where the scored completion is the answer number rather than the species name
- distance-to-answer analysis, where each row records how far the candidate span is from the answer field

That separation matters because number-token preference is not the same phenomenon as species-likelihood preference. A model can strongly prefer answering `1` without necessarily assigning higher likelihood to the species name in position 1.

## Analysis Design

This setup improves the earlier scaffold in four ways:

- candidate-name scoring and answer-number scoring are separated instead of being mixed into one rank-bias interpretation
- each row records candidate-span and answer-span metadata so distance-to-answer effects can be measured directly
- variant summaries include comparable-only trajectories where all target positions exist, so pooled rank means do not quietly benefit from short candidate lists
- the report distinguishes visible list-marker effects from recency-to-answer effects more cleanly

The practical consequence is that `02` can answer a sharper question than `01`: whether the observed position effect is mainly about visible ranking markers, answer formatting, closeness to the answer field, or a broader position-sensitive score surface.

## Metrics

- `mean_logprob_by_rank_per_prompt_variant`
- `pooled_rank_1_minus_rank_5_delta_by_variant`
- `same_candidate_rank_1_minus_rank_5_delta_by_variant`
- `rank_logprob_correlation_by_variant`
- `best_scoring_rank_by_variant`
- `distance_to_answer_correlation_by_variant`
- `mean_logprob_by_distance_bucket_per_variant`
- `comparable_summary_by_variant`
- `format_sensitivity_score`
- `answer_format_sensitivity_score`

The paired same-candidate delta is the main comparison to read. It compares the same candidate against itself across positions, which makes it stronger than pooled rank means.

In this run, the pooled and same-candidate rank 1 minus rank 5 deltas are numerically identical in the summary output for each variant. The interpretation should still emphasize the same-candidate framing because that is the causal contrast the experiment is trying to approximate.

## Results

The completed run used `119` frozen examples and produced `10,504` scored rows across the prompt variants.

| Prompt variant | Scoring type | Rank 1 minus rank 5 delta | Distance correlation | Comparable trajectories | Interpretation |
|---|---:|---:|---:|---:|---|
| numbered list | candidate name | 0.567 | 0.215 | 385 | strong rank-1 advantage |
| lettered list | candidate name | 0.775 | 0.306 | 385 | strong rank-1 advantage |
| bulleted list | candidate name | 0.023 | 0.035 | 385 | weak rank effect |
| JSON list | candidate name | 0.305 | 0.309 | 385 | moderate rank effect |
| semicolon list | candidate name | 1.771 | 0.504 | 385 | strong rank and recency signal |
| `answer_scientific_name_only` | candidate name | 0.567 | 0.215 | 385 | matches numbered list |
| `answer_json_only` | candidate name | -0.119 | -0.043 | 385 | flatter, slightly rank-5 leaning |
| `answer_candidate_number_only` | answer number | 12.312 | 0.619 | 385 | interpret separately |

The candidate-name scoring results show that the rank effect is not limited to numbered lists. It appears in numbered, lettered, JSON, and semicolon formats. However, it is not stable across all formats. The bulleted condition is nearly flat, and the JSON answer condition slightly reverses the rank 1 versus rank 5 direction.

This means the safest conclusion is not “Gemma has a universal rank-1 bias.” A more accurate reading is that Gemma’s candidate likelihood is sensitive to candidate position, but the strength and direction of that sensitivity depend on prompt structure and answer representation.

## Comparable-Only Summary

The comparable-only view is the stricter one because it only uses trajectories where ranks 1, 3, and 5 all exist.

| Prompt variant | Comparable trajectories | Rank 1 minus rank 5 delta | Rank 1 best rate | Rank 5 best rate |
|---|---:|---:|---:|---:|
| numbered list | 385 | 0.567 | 81.8% | 13.2% |
| lettered list | 385 | 0.775 | 81.0% | 13.5% |
| bulleted list | 385 | 0.023 | 52.5% | 40.5% |
| JSON list | 385 | 0.305 | 85.2% | 14.5% |
| semicolon list | 385 | 1.771 | 99.7% | 0.3% |
| `answer_scientific_name_only` | 385 | 0.567 | 81.8% | 13.2% |
| `answer_json_only` | 385 | -0.119 | 28.3% | 39.5% |
| `answer_candidate_number_only` | 385 | 12.312 | 100.0% | 0.0% |

The comparable-only results strengthen the interpretation because every reported trajectory has all three target positions available. The numbered and lettered formats reproduce the top-slot advantage from `01`. The JSON list keeps a moderate rank effect, suggesting that visible human-style numbering is not required. The semicolon list produces the strongest effect, but it also has the strongest distance correlation among candidate-name formats, so it should be interpreted as a combined position and recency signal.

The bulleted list is the key counterexample. It weakens the claim that rank bias is format-invariant. In that format, rank 1 is only slightly better than rank 5, and the rank 5 best rate rises to `40.5%`.

The `answer_json_only` condition is also important. It suggests that changing only the answer representation can flatten or slightly reverse the score pattern. This means downstream answer formatting is part of the phenomenon, not just a neutral output wrapper.

### Distance-To-Answer

Distance-to-answer summaries help separate rank position from simple closeness to the answer field.

| Prompt variant | Distance correlation | Mean logprob bucket pattern |
|---|---:|---|
| numbered list | 0.215 | `33-64` is highest, then `0-16`, then `17-32` |
| lettered list | 0.306 | `33-64` is highest, then `0-16`, then `17-32` |
| bulleted list | 0.035 | comparatively flat |
| JSON list | 0.309 | `33-64` is highest, then `65+`, then `17-32` |
| semicolon list | 0.504 | very strong distance signal |
| `answer_scientific_name_only` | 0.215 | same as numbered list |
| `answer_json_only` | -0.043 | weak reverse trend |
| `answer_candidate_number_only` | 0.619 | strongest distance signal, but separate from candidate-name scoring |

The key point is that recency-to-answer is not a tiny effect in all formats. It is especially visible in semicolon formatting, where visible numbering cues are removed but candidate order is still preserved.

The semicolon result should therefore be interpreted carefully. It is evidence against a purely visible-marker explanation, because the effect survives without list numbers. But it is also evidence that distance and ordering are entangled. The semicolon format does not isolate “rank” in a clean symbolic sense. It creates a compact ordered sequence where the location of a candidate relative to the answer field can strongly affect scoring.

## Interpretation Guide

- `numbered_list` and `lettered_list` both show a clear rank-1 advantage, so the rank effect survives common visible list markers.
- `bulleted_list` is much weaker, which suggests the formatting itself matters.
- `json_list` still shows a moderate rank effect even without human-style numbering.
- `semicolon_list` is the strongest case for a position and recency signal, because it removes visible numbering cues but keeps order.
- `answer_scientific_name_only` matches `numbered_list`, which supports the species-likelihood interpretation.
- `answer_json_only` is flatter and slightly rank-5 leaning, so answer formatting can change the score shape.
- `answer_candidate_number_only` is separate answer-number preference, not species scoring, and should not be merged into the species rank-bias result.
- Distance-to-answer summaries help check whether rank effects are partly driven by recency to the answer field rather than by the semantic meaning of being first or fifth in the list.
- Comparable-only summaries are the stricter view when rank 1, rank 3, and rank 5 must all exist in the same trajectory.

The answer-number condition is the clearest reminder that answer token choice is a different phenomenon from species-name scoring.

## Decision Rule

The strongest evidence for a formatting artifact would be a large rank effect in numbered or lettered lists that shrinks under semicolon or JSON formatting.

The strongest evidence for a recency effect would be a strong correlation between candidate distance to the answer field and candidate log probability.

The strongest evidence for a more general position effect would be a stable same-candidate rank delta across multiple list formats, including formats without visible rank markers.

## Conclusion

The prompt-format controls show that the score-level rank effect is real but not format-invariant.

The result is not explained by numbered-list markers alone, because the effect remains in JSON and semicolon formats. At the same time, it is not a universal rank-1 effect, because the bulleted and JSON-answer conditions weaken or reverse the pattern.

The safest conclusion is that Hugging Face Gemma 4’s candidate-likelihood surface is sensitive to candidate position, but that sensitivity is mediated by prompt structure, answer representation, and distance to the answer field. This makes `02` a useful bridge between the score-level result in `01` and the later mechanistic probes: it narrows the question from “is there rank bias?” to “which parts of the prompt make rank information available or useful to the model?”

## Limitations

- This analysis uses the Hugging Face backend, not LiteRT-LM.
- It cannot by itself establish causality.
- It only tests the prompt patterns included in the script.
- Text-only scoring does not include image evidence from the original Mero deployment.
- Distance-to-answer is measured from token spans in the prompt and should be interpreted as a proxy for recency, not as a complete causal explanation.
- The semicolon format removes visible list markers, but it does not remove ordering or distance effects.
- Answer-number scoring measures number-token preference and should not be interpreted as species likelihood.

## Next Steps

- Use the `03` probing analysis to test whether candidate position is linearly decodable from hidden states.
- Treat the bulleted and JSON-answer conditions as important counterexamples when interpreting rank bias.
- In activation patching, distinguish candidate-span patches from answer-field or marker-span patches.
- Consider an additional control that equalizes candidate-to-answer distance more directly.
