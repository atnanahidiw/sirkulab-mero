# Candidate Position Probing

## Purpose

This report checks whether candidate position is linearly decodable from Hugging Face Gemma 4 hidden states.

It follows the score-level analyses in [`Hugging Face Logit Rank Bias`](./01_hf-logit-rank-bias.md) and [`Prompt Format Controls`](./02_prompt-format-controls.md). Those analyses showed that candidate completion likelihood is position-sensitive and format-dependent. This report asks a narrower internal-representation question: is candidate position available in hidden states strongly enough for a simple linear probe to recover it?

## Research Question

Can candidate position be linearly decoded from hidden states, and does that decodability persist when explicit rank markers are removed?

## Summary

The completed run shows that candidate position is linearly decodable from hidden states with near-ceiling accuracy.

Across `119` examples, `2,626` prompt rows, and `31,512` hidden-state feature rows, the strongest diagnostic probe reached perfect accuracy. Grouped splits also stayed near ceiling:

- overall best diagnostic `probe_accuracy`: `1.0000`
- primary example split accuracy: `0.9985`
- primary candidate-identity split accuracy: `0.9963`
- majority baseline accuracy: `0.3720`
- random-label baseline accuracy: `0.2134`

The strongest signal came from candidate-span features, not answer-field features:

- `candidate_span_mean`: `1.0000`
- `candidate_span_last`: `0.9985`
- `answer_position_token`: `0.4268`
- `answer_marker_span_mean`: `0.4223`

The result remained strong in both prompt conditions:

- with explicit rank markers: `1.0000`
- without explicit rank markers: `0.9970`

The strongest cross-condition transfer results were also high, though asymmetric:

- train on with-rank prompts, test on without-rank prompts: `0.9962`
- train on without-rank prompts, test on with-rank prompts: `0.9619`

This supports the narrow interpretation that candidate position is recoverable from the hidden-state representation. The signal is not limited to explicit rank markers. However, this still does not show that the model uses candidate position causally when selecting an answer.

## Hypothesis

If candidate position is represented in hidden states, then a linear probe should predict whether a candidate is at position 1, 3, or 5 above majority and random-label baselines.

If the representation mainly depends on explicit list markers, probe accuracy should drop sharply in the no-rank-marker condition.

If the representation contains a more general positional signal, or a position signal not limited to explicit numerical markers, decodability should remain above baseline even when explicit numerical markers are removed.

## Motivation and Method

The `01` analysis showed that the same candidate can receive different completion likelihood depending on where it appears in the candidate list. The `02` analysis showed that this score-level effect is shaped by prompt formatting, answer formatting, and distance to the answer field.

Those results leave an internal-representation question open. Is candidate position merely affecting the output score surface, or is candidate position recoverable from the hidden states themselves?

This report tests that question with a linear probe. The probe is intentionally simple. It asks whether candidate position is available in the representation, not whether the model causally uses that information to choose the answer.

For each frozen example, the script:

- keeps the candidate set fixed
- moves the same target candidate across positions 1, 3, and 5
- builds prompts with and without explicit rank markers
- extracts Hugging Face Gemma 4 hidden states
- pools hidden-state features at selected prompt locations
- trains a linear classifier to predict candidate position

The main prompt conditions are:

- `with_rank_markers`, using a numbered candidate list
- `without_rank_markers`, using a semicolon-style candidate list without explicit numerical markers

The main feature locations are:

- `candidate_span_mean`
- `candidate_span_last`
- `answer_position_token`
- `answer_marker_span_mean`

These locations separate candidate-local information from answer-field and prompt-layout information. That distinction matters because a probe that works only at the answer marker may be reading prompt structure rather than candidate representation.

Each stored feature row also records whether the candidate span, answer position span, and answer-marker span were actually found before feature pooling. Missing spans are skipped instead of being silently pooled.

## What This Adds Beyond Score-Level Analyses

The earlier analyses showed that candidate position changes completion likelihood and that the effect depends on prompt format. This report adds an internal-representation check: candidate position is not only visible at the score level, but also linearly recoverable from hidden states, especially at candidate-local spans. This still does not establish causal use, but it provides a stronger target for activation patching than score-level analysis alone.

## Analysis Design

This setup improves the earlier probing scaffold in several ways:

- feature rows are persisted separately from metadata so resume runs produce complete summaries
- the script supports chunked execution with `--start-example` and `--end-example`
- full prompts are not written by default, reducing output size and memory pressure
- label mapping is dynamic, so the analysis is not hardcoded to only one position set
- with-rank-marker and without-rank-marker conditions are reported separately
- candidate-identity and example-level splits help test whether the probe generalizes beyond memorized candidates or examples
- majority and random-label baselines help prevent overinterpreting probe accuracy
- missing candidate-span and answer-span rows are counted explicitly so span-alignment problems do not stay silent

The completed run used:

| Field | Value |
|---|---:|
| model | `google/gemma-4-E2B-it` |
| backend | Hugging Face |
| device | `mps` |
| dtype | `float16` |
| examples requested | `119` |
| examples processed | `119` |
| prompt rows | `2,626` |
| feature rows | `31,512` |
| summary rows | `12` |
| labels | `1`, `3`, `5` |
| layers selected | `0`, `18`, `35` |
| feature locations | `4` |
| full prompts written | `false` |

Feature collection integrity checks:

| Check | Value |
|---|---:|
| skipped existing feature rows | `22,164` |
| newly written feature rows | `9,348` |
| skipped missing candidate span | `0` |
| skipped missing answer span | `0` |
| skipped missing answer-marker span | `0` |

The resume behavior is important. The final summary should be read as a complete combined run over `31,512` feature rows, not only the `9,348` rows written during the last collection pass.

## Metrics

- `probe_accuracy`
- `macro_f1`
- `majority_baseline_accuracy`
- `random_label_accuracy`
- `accuracy_minus_majority_baseline`
- `accuracy_minus_random_label_baseline`
- `layer_with_highest_probe_accuracy`
- `accuracy_by_layer`
- `accuracy_by_feature_location`
- `best_with_rank_markers_result`
- `best_without_rank_markers_result`
- `candidate_identity_split_accuracy`
- `example_split_accuracy`
- `condition_transfer_accuracy`
- `primary_probe_result`
- `train_label_counts`
- `test_label_counts`

The most important values are the margins over baseline, not the raw accuracy alone. A high probe score is only meaningful if it beats majority and random-label baselines, and if it remains credible under grouped splits.

## Results

The run should be read in light of the collection settings:

- feature rows are stored in a separate file
- full prompts are omitted unless `--write-full-prompt` is enabled
- the default layer selection is a reduced set for safety, but the full sweep can still be requested explicitly
- label counts should be checked alongside grouped split accuracy to confirm the probe is not relying on accidental class coverage
- the `best_with_rank_markers_result` and `best_without_rank_markers_result` fields are diagnostic views, not the primary scientific result

All probe accuracies refer to three-way classification over candidate positions 1, 3, and 5.

### Main Summary

| Metric | Value |
|---|---:|
| probe accuracy | `1.0000` |
| mean probe accuracy across summary rows | `0.6038` |
| majority baseline accuracy | `0.3720` |
| random-label accuracy | `0.2134` |
| accuracy minus majority baseline | `0.6280` |
| accuracy minus random-label baseline | `0.7866` |
| macro F1 | `1.0000` |

### Primary Probe Result

The primary result should use grouped splits rather than a random row split.

I treat the example split as primary because it tests generalization across source examples, while the candidate-identity split tests whether the probe generalizes beyond repeated candidate names.

| Selection rule | Example split | Candidate-identity split |
|---|---:|---:|
| best example split; fallback to candidate-identity split | `0.9985` | `0.9963` |

### Overall Best Diagnostic Result

| Layer | Feature location | Accuracy | Macro F1 | Majority baseline | Random-label baseline | Interpretation |
|---:|---|---:|---:|---:|---:|---|
| `18` | `candidate_span_mean` | `1.0000` | `1.0000` | `0.3720` | `0.2134` | Strongest overall probe signal |

### Accuracy by Prompt Condition

| Condition | Best layer | Best feature location | Accuracy | Majority baseline | Random-label baseline | Interpretation |
|---|---:|---|---:|---:|---:|---|
| with rank markers | `18` | `candidate_span_last` | `1.0000` | `0.3628` | `0.5030` | Perfect decodability with explicit numbering |
| without rank markers | `18` | `candidate_span_last` | `0.9970` | `0.3628` | `0.3750` | Decodability remains near ceiling without explicit numbering |

The no-rank-marker condition still preserves candidate order and distance through the semicolon format. It should be described as decodability without visible numerical markers, not full formatting independence.

### Accuracy by Feature Location

| Feature location | Best layer | Accuracy | Macro F1 | Interpretation |
|---|---:|---:|---:|---|
| `candidate_span_mean` | `18` | `1.0000` | `1.0000` | Candidate-local pooled representation carries the clearest signal |
| `candidate_span_last` | `18` | `0.9985` | `0.9985` | Candidate-final-token representation is also highly decodable |
| `answer_position_token` | `35` | `0.4268` | `0.4218` | Weak signal at the answer field |
| `answer_marker_span_mean` | `35` | `0.4223` | `0.4219` | Weak signal at the answer marker |

### Accuracy by Layer

| Layer | Best feature location | Accuracy | Interpretation |
|---:|---|---:|---|
| `0` | `candidate_span_mean` | `0.5091` | Modest early-layer signal |
| `18` | `candidate_span_mean` | `1.0000` | Strongest layer for position decoding |
| `35` | `candidate_span_mean` | `0.9970` | Very strong late-layer signal |

### Group Split Results

| Evaluation split | Accuracy | Macro F1 | Majority baseline | Random-label baseline | Interpretation |
|---|---:|---:|---:|---:|---|
| random row split | `1.0000` | `1.0000` | `0.3720` | `0.2134` | Diagnostic upper bound |
| candidate-identity split | `0.9963` | `0.9959` | `0.3978` | `0.5520` | Strong generalization beyond repeated candidates |
| example split | `0.9985` | `0.9984` | `0.3705` | `0.2364` | Strong generalization across examples |
| with-rank to without-rank transfer | `0.9962` | `0.9959` | `0.3701` | `0.2468` | Strong transfer from numbered list to semicolon list |
| without-rank to with-rank transfer | `0.9619` | `0.9602` | `0.3701` | `0.3145` | Strong but lower reverse transfer |

A high random-label baseline in a grouped split can occur when class coverage is uneven under the grouping procedure, so the relevant comparison is the margin between probe accuracy and that grouped baseline.

## Interpretation Guide

A high probe score means candidate position is linearly decodable from the chosen hidden-state representation. It does not prove that the model uses that information causally when choosing an answer.

If the best result appears in `with_rank_markers` but collapses in `without_rank_markers`, then the probe may mostly be decoding explicit prompt markers such as list numbers.

If the no-rank-marker condition remains above baseline, then candidate position is decodable without explicit list numbers, although semicolon formatting still preserves ordering and distance.

If candidate-span features perform well, candidate position is decodable from features pooled at the candidate span.

If answer-position or answer-marker features dominate, the probe may be reading prompt layout or answer-field structure rather than candidate-local representation.

If candidate-identity or example-level grouped splits perform much worse than random row splits, then the probe result may depend on leakage through repeated candidates, examples, or prompt templates. In this run, grouped splits remained near ceiling.

## Decision Rule

The strongest evidence for hidden-state decodability of candidate position is a `primary_probe_result` clearly above majority and random-label baselines, especially under candidate-identity or example-level group splits.

The strongest evidence that explicit rank markers drive the signal would be high accuracy with rank markers and much lower accuracy without rank markers. That did not happen here.

The strongest evidence for a more general positional signal, or a position signal not limited to explicit numerical markers, is above-baseline accuracy in the no-rank-marker condition, with the caveat that semicolon formatting still preserves ordering and distance information.

The strongest evidence against overinterpreting the probe would be a high random-label baseline, poor grouped-split performance, or accuracy concentrated only at answer-marker features. This run does show a high random-label baseline in one grouped split, but grouped accuracy remains near ceiling and candidate-span features dominate.

## Conclusion

Candidate position is linearly decodable from Gemma hidden states with near-ceiling accuracy.

The strongest result comes from candidate-span features, especially layer `18`. Candidate-span mean is the best overall view, and candidate-span last is nearly as strong.

The signal remains near ceiling without visible numerical rank markers, but the semicolon prompt still preserves order and distance. The result should be read as decodability without explicit numbering, not formatting independence.

The answer-field and answer-marker features are much weaker than candidate-span features. This suggests the probe is reading candidate-local information rather than only prompt layout.

This is strong evidence that candidate position is decodable from hidden states. It does not show that the model uses that information causally when selecting an answer.

This provides a concrete target for causal follow-up experiments, especially activation patching on candidate-span features.

## Limitations

- This analysis uses the Hugging Face backend, not the deployed LiteRT-LM runtime.
- Probing is correlational, not causal.
- Linear decodability does not imply model use.
- Text-only prompts do not include image evidence from the original Mero deployment.
- Prompt layout may leak position information.
- The no-rank-marker condition still preserves candidate order and distance effects, so it tests decodability without visible list numbers rather than formatting independence.
- Candidate-span pooling may still capture local formatting and separator context around the candidate, not only the candidate name representation.
- Results depend on token-span alignment and feature-pooling choices.
- Grouped splits reduce leakage, but they do not remove every possible confound.

## Next Steps

- Use activation patching to test whether candidate-position information has a causal effect on candidate scores.
- Patch candidate-span features separately from answer-marker and answer-position features.
- Compare probing results against the format-dependence found in [`Prompt Format Controls`](./02_prompt-format-controls.md).
- Add stronger distance-equalized prompt controls if the probe appears to rely heavily on prompt layout.

## Relationship to 03b

This report is the main hidden-state probing analysis. It tests whether candidate position is linearly decodable under two core conditions: with explicit rank markers and without explicit rank markers.

The follow-up control report, [`Prompt-Template Probing Controls`](./03b_prompt-template-probing-controls.md), extends the same probing question across multiple prompt templates. That control checks whether position decodability generalizes beyond the two baseline prompt conditions used here.
