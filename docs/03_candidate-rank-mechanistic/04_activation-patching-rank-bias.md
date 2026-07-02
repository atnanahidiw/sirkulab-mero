# Activation Patching Rank Bias

## Purpose

This report tests whether moving activations from a clean prompt into a corrupted prompt causally restores the target candidate's completion score.

It follows the score-level analyses in [`Hugging Face Logit Rank Bias`](./01_hf-logit-rank-bias.md), [`Prompt Format Controls`](./02_prompt-format-controls.md), and the internal-representation analysis in [`Candidate Position Probing`](./03a_candidate-position-probing.md). Those earlier analyses showed that candidate position affects completion likelihood and that candidate position is linearly decodable from hidden states. This report asks the next causal question: if candidate-position information is present in hidden states, does patching selected activations move the corrupted score toward the clean score?

## Research Question

Can activation patching from a clean prompt where the target candidate appears at position `1` into a corrupted prompt where the same target candidate appears at position `5` recover the target candidate's completion likelihood?

A stronger version of the question is whether candidate-local patches recover the score more than matched controls. This matters because recovery from arbitrary or matched control positions would weaken the interpretation that the candidate span itself is causally responsible.

## Summary

The completed run gives mixed causal evidence.

Across `1,770` patch rows, the overall mean candidate log-probability recovery was positive but small:

- overall mean `candidate_logprob_recovery`: `0.0740`
- mean non-control recovery: `0.0814`
- mean control recovery: `0.0627`
- non-control minus control recovery: `0.0187`
- patched top-candidate flip rate: `0.0548`

The strongest mean recovery came from `answer_position`, not from candidate-local sites:

- `answer_position`: `0.2909`
- `matched_control`: `0.1252`
- `self_patch`: `0.0002`
- `candidate_last_token`: `-0.0068`
- `candidate_span`: `-0.0398`

The most important caution is that `matched_control` recovered more than `candidate_span` and `candidate_last_token`. Therefore, this run does not support a strong claim that candidate-span activations are the main causal driver of the rank-bias effect.

The clearest positive signal was late-layer answer-position patching:

- `answer_position` at `model.language_model.layers.34`: `0.8437`

This suggests that the score-level rank effect may be more visible at the answer field or final decision context than at the candidate-local span. However, this conclusion should be treated as tentative because the matched control also produced non-trivial recovery.

## Hypothesis

If candidate-local position information is causally used to score the target candidate, then patching `candidate_span` or `candidate_last_token` from the clean prompt into the corrupted prompt should increase the target candidate's completion score.

If the effect is specific to candidate-local information, candidate-local patch recovery should exceed matched controls and self-patch controls.

If the model mainly expresses the rank effect near the answer field, then `answer_position` patches should recover more than candidate-local patches.

If recovery also appears in `matched_control`, then the patch may be exploiting prompt layout, distance-to-answer effects, or broader residual stream perturbations rather than a candidate-specific causal feature.

## Motivation and Method

The `03a` probing report showed that candidate position is linearly decodable from hidden states with near-ceiling accuracy, especially from candidate-span features. However, probing is correlational. A linear probe can show that information is available in the representation, but it cannot show that the model uses that information when producing an answer.

This report tests a causal intervention.

For each frozen example, the script:

- chooses a target candidate, preferring the ground-truth species when available
- builds a clean prompt where the target candidate appears at position `1`
- builds a corrupted prompt where the same target candidate appears at position `5`
- scores the target candidate under clean and corrupted prompts
- captures layer activations from the clean or control source prompt
- patches selected token positions into the corrupted forward pass
- scores the target candidate again after patching
- measures how much the patch recovers the clean score

The run used a plain PyTorch hook backend rather than pyvene. The hook backend patches the output of selected language-model layers directly. This was used because it gives explicit control over multi-token span patching and avoids uncertainty around pyvene `max_number_of_units` behavior for span interventions.

The patch sites are:

- `candidate_span`: all tokens in the target candidate name span
- `candidate_last_token`: the final token of the target candidate name span
- `answer_position`: the answer-field token position
- `matched_control`: a non-candidate span with the same width and roughly matched distance to the answer field
- `self_patch`: a control patch from the corrupted prompt back into itself

The main comparison is not only whether a patch has positive recovery. The stronger test is whether candidate-local patches outperform matched controls.

## What This Adds Beyond Probing

The probing report showed that candidate position is recoverable from hidden states. This report asks whether intervening on those hidden states changes the target candidate's score.

The result is more cautious than the probing result. Candidate position is strongly decodable, but the causal patching results do not clearly isolate candidate-span activations as the mechanism. The strongest patch effect appears at the answer position, and a matched control also recovers part of the score.

This means the current evidence supports the following interpretation:

Candidate position is available in the hidden state, but this activation patching run does not yet prove that candidate-local representations causally drive the final candidate score.

## Analysis Design

This setup improves the earlier activation-patching scaffold in several ways:

- uses explicit clean and corrupted prompts with target positions `1` and `5`
- patches selected language-model layers only
- records source and destination token positions for every patch row
- supports multi-token candidate-span patching through direct PyTorch hooks
- includes `matched_control` instead of only an arbitrary control position
- includes `self_patch` as a near-zero sanity control
- stores rows incrementally in JSONL so resume runs can continue without recomputing existing rows
- summarizes the complete output file after resume, not only newly written rows
- reports recovery by layer, patch site, and site-layer pair
- treats `candidate_logprob_recovery` as the primary metric rather than relying only on answer flips

The completed run used:

| Field | Value |
|---|---:|
| model | `google/gemma-4-E2B-it` |
| backend | Hugging Face |
| patch backend | `pytorch_hook` |
| seed | `7` |
| clean position | `1` |
| corrupted position | `5` |
| patch rows | `1,770` |
| written rows in last run | `0` |
| resumed rows | `1,755` |
| skipped existing rows | `1,755` |
| skipped missing-span rows | `0` |
| skipped rows | `2` |
| selected hook layers | `3` |
| strict prompt length | `false` |

The selected language-model layers were:

| Layer role | Layer name |
|---|---|
| early | `model.language_model.layers.0` |
| middle | `model.language_model.layers.17` |
| late | `model.language_model.layers.34` |

The patch sites were:

| Patch site | Role |
|---|---|
| `candidate_span` | candidate-local multi-token patch |
| `candidate_last_token` | candidate-local single-token patch |
| `answer_position` | answer-field patch |
| `matched_control` | distance-matched non-candidate control |
| `self_patch` | corrupted-to-corrupted sanity control |

## Metrics

- `clean_candidate_logprob`
- `corrupted_candidate_logprob`
- `patched_candidate_logprob`
- `logit_recovery`
- `candidate_logprob_recovery`
- `patched_top_candidate_flip_rate`
- `mean_logprob_recovery_by_layer`
- `mean_logprob_recovery_by_position`
- `mean_logprob_recovery_by_site_and_layer`
- `mean_control_recovery`
- `mean_noncontrol_recovery`
- `noncontrol_minus_control_recovery`
- `best_patch_layer`
- `best_patch_position`

The primary metric is `candidate_logprob_recovery`:

```text
candidate_logprob_recovery =
    (patched_candidate_logprob - corrupted_candidate_logprob)
    /
    (clean_candidate_logprob - corrupted_candidate_logprob)
```

Interpretation:

- `0` means no recovery beyond the corrupted prompt
- `1` means full recovery to the clean prompt score
- values above `1` mean the patch improved the score beyond the clean score
- negative values mean the patch moved the score away from the clean score

This metric is more informative than top-candidate flips because small but systematic score changes may not change the top answer.

## Results

The run should be read as a causal smoke test over selected layers and patch sites, not as a complete circuit discovery result.

### Main Summary

| Metric | Value |
|---|---:|
| patch rows | `1,770` |
| overall mean candidate log-probability recovery | `0.0740` |
| mean non-control recovery | `0.0814` |
| mean control recovery | `0.0627` |
| non-control minus control recovery | `0.0187` |
| patched top-candidate flip rate | `0.0548` |

The overall recovery is positive, but the control comparison is weak. Non-control recovery exceeds control recovery by only `0.0187`.

### Recovery by Patch Site

| Patch site | Mean recovery | Interpretation |
|---|---:|---|
| `answer_position` | `0.2909` | Strongest average recovery |
| `matched_control` | `0.1252` | Non-trivial control recovery |
| `self_patch` | `0.0002` | Near-zero sanity control |
| `candidate_last_token` | `-0.0068` | Weak negative recovery |
| `candidate_span` | `-0.0398` | Negative average recovery |

The strongest site is `answer_position`, not `candidate_span`. The matched control is also positive, which weakens a candidate-local causal interpretation.

### Recovery by Layer

| Layer | Mean recovery | Interpretation |
|---|---:|---|
| `model.language_model.layers.0` | `0.0471` | Small positive mean, driven partly by matched control |
| `model.language_model.layers.17` | `0.0059` | Near-zero mean |
| `model.language_model.layers.34` | `0.1688` | Largest mean recovery, driven by answer-position patching |

The layer-level result points most strongly to late-layer intervention effects.

### Recovery by Site and Layer

| Patch site | Layer | Mean recovery | Interpretation |
|---|---|---:|---|
| `answer_position` | `model.language_model.layers.34` | `0.8437` | Strongest systematic recovery |
| `matched_control` | `model.language_model.layers.0` | `0.3754` | Strong control recovery, caution needed |
| `answer_position` | `model.language_model.layers.17` | `0.0290` | Weak positive recovery |
| `candidate_span` | `model.language_model.layers.0` | `-0.1197` | Negative recovery |
| `candidate_last_token` | `model.language_model.layers.0` | `-0.0207` | Weak negative recovery |

Most site-layer combinations outside late `answer_position` are close to zero. The candidate-local sites do not recover the clean score in this run.

### Best Patch

| Field | Value |
|---|---|
| layer | `model.language_model.layers.0` |
| patch site | `matched_control` |
| recovery | `9.5701` |
| example | `data/raw/species_data_img/Mammalia/Primates/Hominidae/Pongo/pongo_pygmaeus/pongo_pygmaeus_1.jpg` |
| candidate | `Pongo pygmaeus` |
| patch width | `5` |

The best individual patch is a `matched_control` patch, not a candidate-local patch. This is an important warning against overinterpreting individual large recoveries.

## Interpretation Guide

A high positive `candidate_logprob_recovery` means the patch moved the corrupted score toward the clean score.

A top-candidate flip is stronger behavioral evidence than a small score movement, but flip rate should not be the main metric because many score changes do not change the top candidate.

If `candidate_span` or `candidate_last_token` strongly outperforms matched controls, that would support a candidate-local causal role.

If `answer_position` outperforms candidate-local sites, the rank effect may be expressed near the answer field or final scoring context rather than at the candidate span.

If `matched_control` recovers substantially, then recovery may reflect prompt layout, distance-to-answer effects, or broad residual-stream perturbation rather than candidate-specific information.

If `self_patch` is near zero, the patching machinery is less likely to create recovery merely from running the hook. In this run, `self_patch` is near zero, which is a useful sanity check.

## Decision Rule

The strongest evidence for a candidate-local causal mechanism would be:

1. positive `candidate_span` or `candidate_last_token` recovery,
2. candidate-local recovery larger than `matched_control`,
3. stable recovery across layers or across examples,
4. top-candidate flips toward the clean answer more often than controls.

This run does not meet that standard.

The strongest evidence for an answer-field causal effect would be high `answer_position` recovery, especially in late layers, with controls remaining low.

This run partially supports that pattern because `answer_position` at `model.language_model.layers.34` has high recovery. However, the positive `matched_control` result means this should remain a tentative interpretation.

The strongest evidence against overinterpreting the patching result is that the best individual patch is a matched control and the average candidate-local recovery is weak or negative. This run shows both.

## Conclusion

The activation-patching run provides limited causal support for the score-level rank-bias effect, but it does not support a strong candidate-span causal claim.

The main finding is that late-layer `answer_position` patching recovers the target candidate score more than candidate-local patching. The strongest site-layer result is `answer_position` at `model.language_model.layers.34`.

Candidate-local patches do not recover the clean score in this run. `candidate_span` has negative average recovery, and `candidate_last_token` is also slightly negative.

The matched control produces non-trivial recovery and contains the best individual patch. This means the current intervention is not specific enough to isolate candidate-local position information as the causal driver.

The safest conclusion is:

Candidate position is strongly decodable from hidden states, but the first activation-patching run does not show that candidate-local activations causally drive the final candidate score. The clearest causal signal is closer to the answer-position or late scoring context, and even that needs stronger controls.

## Limitations

- This analysis uses the Hugging Face backend, not the deployed LiteRT-LM runtime.
- The run uses text-only prompts and does not include image evidence from the original Mero deployment.
- The patch backend is a plain PyTorch hook backend, not pyvene.
- Only three language-model layers were patched: early, middle, and late.
- Hooking block outputs may miss effects that occur inside attention heads, MLPs, or residual stream subcomponents.
- Matched controls recover non-trivially, so candidate-local causal claims are not justified.
- Candidate spans depend on token-span alignment and species-name tokenization.
- Clean and corrupted prompts may differ in token layout unless strict prompt-length mode is enabled.
- `candidate_logprob_recovery` can be unstable when the clean-corrupted denominator is small.
- Top-candidate flip rate is useful but sparse, so it should not be treated as the only behavioral metric.
- The best individual patch is an outlier and should not be treated as the main result.

## Next Steps

- Run a larger layer sweep around late language layers, especially near `model.language_model.layers.34`.
- Add more answer-field controls, including answer-marker and answer-token neighborhood patches.
- Compare answer-position recovery against distance-matched answer-position controls.
- Report median and percentile recovery, not only mean recovery, because individual patches can be large outliers.
- Filter or stratify examples by the clean-corrupted score gap to reduce denominator instability.
- Add grouped summaries by example, species, and whether the clean prompt actually changes the top candidate.
- Test candidate-span patching in prompt templates where distance-to-answer is equalized.
- If returning to pyvene, validate span interventions with a small CollectIntervention or equivalent activation capture test before the full sweep.
- Keep the next report centered on recovery relative to matched controls, not only raw recovery.

## Relationship to 03a and 03b

The `03a` report showed that candidate position is linearly decodable from hidden states, especially from candidate-span features. The `03b` prompt-template controls test whether that decodability generalizes across prompt templates.

This report is the first causal follow-up. It tests whether patching selected activations changes the target candidate score. The result is more cautious than the probing result: decodability is strong, but the first patching run does not isolate a candidate-local causal mechanism.
