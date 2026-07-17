# SAE Inspection Plan

## Purpose

This note defines the gate for sparse autoencoder or Gemma Scope-style inspection.

## Method

The script checks whether Gemma 4-compatible SAE weights or precomputed feature activations are available. If none are provided, it writes a skipped status instead of inventing feature analysis.

## Metrics

- `status`
- `provided_artifacts`
- `reason`

## Results

Placeholder for the compatibility check output from `05_sae_inspection_plan.py`.

## Interpretation Guide

- Only treat the analysis as real SAE work if the artifacts are compatible with the model being studied.
- If only Gemma 2 or Gemma 3 artifacts exist, label the result as a surrogate study.
- Do not claim Gemma 4 SAE findings without Gemma 4-compatible artifacts.

## Limitations

- This script does not perform SAE feature discovery by itself.
- It is intentionally conservative and may skip when no valid artifacts are present.
- Feature interpretation should wait until the artifacts are validated on this dataset.
