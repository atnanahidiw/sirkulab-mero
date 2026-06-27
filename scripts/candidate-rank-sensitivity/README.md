# Candidate Rank Sensitivity

This package measures whether Gemma 4 changes its final species answer when the **same image** and the **same candidate species set** are shown in a different **candidate order**.

The package is split into seven scripts:

- `build_rank_sensitivity_dataset.py` — freezes a candidate set per example
- `build_rank_sensitivity_dataset_more.py` — convenience wrapper with a larger default frozen set
- `eval_candidate_rank_sensitivity.py` — runs original-order and shuffled-order or reverse-order trials
- `run_reversed_rank_sensitivity.py` — runs the reverse-order experiment on a frozen set
- `summarize_rank_sensitivity.py` — computes aggregate metrics and prints a terminal summary
- `run_hightrial_rank_sensitivity.py` — samples a smaller balanced subset and runs a higher-shuffle robustness check
- `analyze_litert_candidate_likelihood.py` — uses LiteRT-LM token scores to compare candidate likelihood by rank position

## Purpose

The goal is to test whether rank position influences species identification decisions. If the answer changes when only the candidate order changes, that suggests the model is sensitive to presentation order rather than just image evidence and candidate identity.

## Hypothesis

Gemma 4 species identification is sensitive to candidate order. The same image and the same candidate list may produce different final species answers when the order changes.

## Expected inputs

The default dataset builder uses the repo’s authoritative baseline output:

- `scripts/gemma-improve-detection/outputs/gemma4_baseline.jsonl`
- `assets/data/species_data.sqlite`

The evaluator additionally needs the LiteRT-LM Gemma runtime bundle, usually available in the sibling `sirkulab-mero-data` environment.

## Commands

```bash
python scripts/candidate-rank-sensitivity/build_rank_sensitivity_dataset.py \
  --limit 50 \
  --output outputs/candidate-rank-sensitivity/examples.jsonl

python scripts/candidate-rank-sensitivity/eval_candidate_rank_sensitivity.py \
  --examples outputs/candidate-rank-sensitivity/examples.jsonl \
  --trials 5 \
  --output outputs/candidate-rank-sensitivity/rank_sensitivity_results.jsonl

python scripts/candidate-rank-sensitivity/summarize_rank_sensitivity.py \
  --results outputs/candidate-rank-sensitivity/rank_sensitivity_results.jsonl \
  --output outputs/candidate-rank-sensitivity/rank_sensitivity_summary.json
```

## Output files

- `outputs/candidate-rank-sensitivity/examples.jsonl`
- `outputs/candidate-rank-sensitivity/rank_sensitivity_results.jsonl`
- `outputs/candidate-rank-sensitivity/rank_sensitivity_summary.json`

## Metric definitions

- `answer_changed_rate` — fraction of shuffled trials whose final answer differs from the original-order answer
- `original_answer_retained_rate` — fraction of shuffled trials that preserve the original-order answer
- `unique_answers_per_image` — number of distinct answers observed per example across original + shuffled trials
- `first_candidate_selected_rate` — fraction of trials where the top-ranked candidate was selected
- `accuracy_original_order` — accuracy for the original candidate order, when ground truth is available
- `accuracy_shuffled_order` — accuracy across shuffled trials, when ground truth is available

## Notes

- The dataset builder and summarizer can run without the model runtime.
- The evaluator is runtime-dependent and will tell you when `litert_lm` is missing.
- Confidence scores are removed before the candidate list is shown to the model.
- Candidate order is preserved in the frozen dataset and shuffled deterministically during evaluation.

## Mechanistic backend

For Hugging Face-backed mechanistic analysis, see `scripts/03_candidate-rank-mechanistic/README.md`.

## Confidence-score sensitivity

This sub-workflow analyzes whether candidate position and uncertainty are tied to the model’s confidence pattern.

### Scripts

- `build_confidence_score_sensitivity_dataset.py` — freezes the confidence-sensitivity dataset from the same baseline inputs
- `eval_confidence_score_sensitivity.py` — legacy evaluator that checks whether the confidence-score package runs in the current runtime
- `analyze_confidence_sensitivity.py` — analyzes score-rich trial rows and computes PBM / confidence-gap diagnostics
- `extract_confidence_sensitivity_scores.py` — companion extractor that collects logits / probabilities from a score-capable backend
- `analyze_confidence_sensitivity_scores.py` — wrapper analysis step that reads extractor output and writes the summary JSON
- `summarize_confidence_score_sensitivity.py` — legacy summary script for the earlier score-display sensitivity workflow

## LiteRT token-score analysis

This Layer 2A workflow compares the token likelihood of the same candidate name when it appears at different list positions.

### Scripts

- `analyze_litert_candidate_likelihood.py` — scores candidate names with LiteRT-LM's `run_text_scoring(...)`

### Output files

- `outputs/candidate-rank-sensitivity/litert_candidate_likelihood_results.jsonl`
- `outputs/candidate-rank-sensitivity/litert_candidate_likelihood_summary.json`

### Pipeline

```bash
python scripts/candidate-rank-sensitivity/extract_confidence_sensitivity_scores.py   --examples outputs/candidate-rank-sensitivity/examples.jsonl   --output outputs/candidate-rank-sensitivity/confidence_score_trials.jsonl   --backend plugin   --backend-module your_backend_module   --backend-class YourBackend

python scripts/candidate-rank-sensitivity/analyze_confidence_sensitivity_scores.py   --results outputs/candidate-rank-sensitivity/confidence_score_trials.jsonl   --output outputs/candidate-rank-sensitivity/confidence_sensitivity_summary.json
```

## High-trial robustness check

When you want to increase shuffle count without re-running the full 50-example sweep, use the high-trial wrapper:

```bash
uv run --python .venv-export/bin/python scripts/candidate-rank-sensitivity/run_hightrial_rank_sensitivity.py \
  --examples outputs/candidate-rank-sensitivity/examples.jsonl \
  --limit-examples 6 \
  --trials 15 \
  --model-path /workspace/openclaw/workdir/sirkulab-mero-data/gemma-4-E2B-it.litertlm \
  --data-repo /workspace/openclaw/workdir/sirkulab-mero-data \
  --backend cpu
```

The wrapper keeps the far-separated setup but uses a smaller balanced subset so more shuffles are affordable on CPU-only runs. If GPU/NPU acceleration is available in your LiteRT-LM environment, you can pass `--backend gpu` or `--backend npu` to try it, but this host’s GPU backend is not available.

## Reverse-order experiment

To test whether reversing the candidate list produces a different effect from random shuffles, run the reverse-order wrapper on a frozen set:

```bash
uv run --python .venv-export/bin/python scripts/candidate-rank-sensitivity/run_reversed_rank_sensitivity.py \
  --examples outputs/candidate-rank-sensitivity/examples_big.jsonl \
  --model-path /workspace/openclaw/workdir/sirkulab-mero-data/gemma-4-E2B-it.litertlm \
  --data-repo /workspace/openclaw/workdir/sirkulab-mero-data \
  --backend cpu
```

The reverse-order run first shuffles a candidate set and then flips that shuffled order end-to-end, so it gives you a paired shuffle-vs-reverse comparison rather than a plain mirror of the original order.

### Dataset size ceiling

For the next robustness pass, `--limit 125` is the practical ceiling with the current source corpus: it stays within the current far-separated source pool, keeps the candidate set unchanged, and gives us a much larger sample than the original 50-example run without needing more source rows.

### Current corpus ceiling

With the current baseline JSONL, the far-separated builder can freeze **125 examples**. That is the maximum available today; a 200-example target would require a larger source pool.
