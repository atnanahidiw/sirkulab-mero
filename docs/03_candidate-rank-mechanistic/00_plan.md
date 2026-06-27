# Mechanistic Backend Plan

## Summary

The deployed Mero app uses Gemma 4 through LiteRT-LM for on-device inference. That runtime is the right fit for shipping, but it does not expose hidden states, logits, or hook points through the public API. For mechanistic analysis, we therefore switch to the Hugging Face safetensors versions of Gemma 4 so the model family stays aligned while the analysis backend becomes inspectable.

## Why This Backend

Google's current Gemma 4 documentation says the family is available from Hugging Face, and the Hugging Face Transformers docs now include Gemma 4 model support. Google also provides a Hugging Face inference tutorial for Gemma that covers text and image input. That makes Hugging Face the cleanest analysis backend for mechanistic work on Gemma 4.

The important caveat is that this backend is not the same runtime as the Android or LiteRT deployment. It uses the same Gemma 4 family and weights format from Hugging Face, but not the same quantized on-device bundle. That difference should be stated explicitly whenever the analysis is described.

## Scope For The First Pass

Start with text-only analysis first.

That keeps the first mechanistic pass focused on a narrow question: does candidate list position change the model's decision behavior before any image-specific complications enter the picture?

The initial sequence is:

1. Recreate the same text prompt format used in the behavioral experiments.
2. Replicate the LiteRT token-score result with Hugging Face Gemma 4 logits.
3. Run prompt-format controls to separate rank effects from formatting and recency effects.
4. Move to hidden-state probing.
5. Add activation patching with PyTorch hooks.
6. Treat SAE or Gemma Scope-style inspection as optional, not required.

## Research Question

This plan asks whether the observed rank effects come from answer-generation dynamics, candidate-token likelihood, hidden-state position encoding, or prompt-format artifacts.

Earlier behavioral analyses showed that candidate order alone produces small but measurable answer instability, while displayed confidence scores produce much stronger instability. The LiteRT token-score analysis then showed a mismatch between generated answers and candidate-likelihood scoring: generated answers favor early candidates, while text-only LiteRT token scoring favors later candidate positions. That mismatch motivates a backend that exposes logits and hidden states.

## Method Details

### 1. Hugging Face Logit-Level Replication

The first script tests whether the LiteRT token-score result appears when the same candidate-ranking prompts are evaluated with Hugging Face Gemma 4 logits.

Main comparison:

- Same candidate at rank 1
- Same candidate at rank 3
- Same candidate at rank 5

Metrics:

- `candidate_answer_logprob`
- `same_candidate_logprob_delta`
- `rank_1_minus_rank_5_logprob`
- `rank_logprob_correlation`
- `next_token_probability_for_candidate_start`
- `full_candidate_sequence_logprob`

### 2. Prompt-Format Controls

The second script tests whether rank effects depend on candidate-list formatting.

Prompt variants:

- Numbered list
- Lettered list
- Bulleted list
- JSON list
- No rank markers
- Answer with scientific name only
- Answer with candidate number only
- Answer with JSON only

This matters because the recency-like effect may come from distance to the answer position, not candidate rank itself.

### 3. Hidden-State Probing

The probing script tests whether candidate position is linearly decodable from hidden states.

Extract hidden states from:

- Candidate-name token positions
- Final answer position

Probe target:

- Candidate rank

Controls:

- Majority baseline
- Random-label baseline
- Candidate-identity split
- Prompt-template split

Important guardrail:

Run probing both with and without visible rank markers. If the probe only succeeds when list numbers are visible, it may be reading the formatting token rather than a more general candidate-position representation.

### 4. Activation Patching

Activation patching should come after logit analysis and probing.

Clean prompt:

- Target species at rank 1

Corrupted prompt:

- Same target species at rank 5

Patch locations:

- Candidate-list token positions
- Separator tokens
- Final answer position
- Middle and late layers

Metrics:

- `logit_recovery`
- `candidate_logprob_recovery`
- `answer_flip_rate`
- `layer_position_effect`

### 5. SAE or Gemma Scope Inspection

SAE inspection is optional.

Only claim Gemma 4 SAE analysis if Gemma 4-compatible SAE artifacts are available. If not, any Gemma Scope-style work should be labeled as a surrogate analysis on a compatible Gemma 2 or Gemma 3 model.

## Planned Files

- `scripts/candidate-rank-mechanistic/README.md`
- `scripts/candidate-rank-mechanistic/common_hf.py`
- `scripts/candidate-rank-mechanistic/logit_rank_bias_hf.py`
- `scripts/candidate-rank-mechanistic/prompt_format_controls_hf.py`
- `scripts/candidate-rank-mechanistic/probe_candidate_position_hf.py`
- `scripts/candidate-rank-mechanistic/activation_patching_rank_bias_hf.py`
- `docs/03_candidate-rank-mechanistic/01_hf-logit-rank-bias.md`
- `docs/03_candidate-rank-mechanistic/02_prompt-format-controls.md`
- `docs/03_candidate-rank-mechanistic/03_candidate-position-probing.md`
- `docs/03_candidate-rank-mechanistic/04_activation-patching-rank-bias.md`

## Sources

- [Gemma 4 overview](https://ai.google.dev/gemma/docs/core)
- [Run Gemma with Hugging Face Transformers](https://ai.google.dev/gemma/docs/core/huggingface_inference)
- [Gemma 4 model card](https://ai.google.dev/gemma/docs/core/model_card_4)
- [Gemma 4 on Hugging Face](https://huggingface.co/google/gemma-4-E2B-it)
- [Transformers Gemma 4 docs](https://huggingface.co/docs/transformers/model_doc/gemma4)

## Next Steps

- Build the text-only logit rank-bias script first.
- Keep image inputs out until the scoring pipeline is stable.
- Add prompt-format controls before moving to probing.
- Add probing and patching only after the scoring path is validated.
