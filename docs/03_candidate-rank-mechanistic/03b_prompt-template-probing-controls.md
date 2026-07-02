# Prompt-Template Probing Controls

## Purpose

This report extends [`Candidate Position Probing`](./03a_candidate-position-probing.md) by testing whether candidate-position decodability generalizes across multiple prompt templates.

The main `03a` report tests two core conditions: with explicit rank markers and without explicit rank markers. This report adds a stronger robustness control by probing hidden states across several prompt formats used in the prompt-format analysis.

## Research Question

Does candidate-position decodability remain above baseline when the same probing setup is evaluated across multiple prompt templates?

## Summary

Placeholder for the measured results from `03b_prompt_template_probe_controls_hf.py`.

The main readout here is whether the candidate-position probe stays above majority and random-label baselines across prompt-template variations.

This is a robustness control for `03a`, not a causal intervention.

## Method

Use the same hidden-state probing setup as `03a`, but vary the prompt template rather than only the rank-marker condition.

The control should compare probe behavior across multiple templates that differ in list formatting and answer formatting.

## Analysis Design

- This report is a probing control, not a score-level effect report.
- It asks whether the position code survives template changes.
- It should be interpreted alongside `03a`, not instead of it.
- If performance collapses in certain templates, those templates likely weaken the position signal.

## Metrics

- `probe_accuracy`
- `macro_f1`
- `majority_baseline_accuracy`
- `random_label_accuracy`
- `accuracy_minus_majority_baseline`
- `accuracy_minus_random_label_baseline`
- `accuracy_by_layer`
- `accuracy_by_feature_location`
- `primary_probe_result`

## Results

Placeholder for the measured results from `03b_prompt_template_probe_controls_hf.py`.

## Interpretation Guide

- If the probe stays above baseline across templates, candidate position is robustly decodable.
- If the probe varies sharply by template, prompt structure likely carries part of the signal.
- Do not treat this as a causal test.

## Relationship to 03a

This report is the control companion to [`Candidate Position Probing`](./03a_candidate-position-probing.md).

`03a` is the main hidden-state probing analysis. It tests whether candidate position is linearly decodable under two core conditions: with explicit rank markers and without explicit rank markers.

`03b` extends the same probing question across multiple prompt templates. That control checks whether position decodability generalizes beyond the two baseline prompt conditions used in `03a`.

## Limitations

- This analysis uses the Hugging Face backend, not LiteRT-LM.
- Probing is correlational, not causal.
- Text-only prompts do not include image evidence from the original Mero deployment.

