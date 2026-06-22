# Docs Index

This folder is organized as a small set of narrative tracks. Each track keeps one research thread together so you can read the problem, the experiment, and the follow-up without jumping across unrelated files.

## How To Read This

- `01` is for Gemma 4 detection failures and the fixes we tried.
- `02` is for candidate-rank sensitivity and the follow-on analyses around it.
- `03` is for the mechanistic Hugging Face follow-up on candidate-rank bias.
- Lower numbers are earlier or broader context.
- Inside a track, numbered files are meant to be read in order.
- Files with the same prefix but different suffixes usually compare variants of the same experiment.

## Current Direction

This section records where the work is heading and why, so the tracks below read as steps toward something rather than a set of unrelated experiments. It is expected to change as the direction gets clearer.

The main direction right now is on-device agentic behavior. The question is whether a small model can run its own identification loop: observe the image, form a hypothesis, call its own search and verification tools, judge the candidates, and revise over several passes.

This was not the plan at the start. It came out of the detection experiments. The native-vs-emulated tool-calling comparison in `01` was only meant to explain the baseline accuracy numbers, but it raised a better question. Most of the gap between the two runs came from control flow, meaning when the model calls a tool, whether it uses the result, and when it stops, rather than from how well it could see. That moved the focus from the answer to the loop that produces it.

Two things follow from this, and they are worth keeping straight.

First, the idea is still forming. The specific research questions are not settled yet: what keeps a tiny model's tool-use loop stable, where it breaks, and how much autonomy is worth the added latency. That is normal for a direction found by experiment instead of chosen in advance.

Second, it changes how to read the earlier work. Now that agentic behavior is the point, native function calling is not just an implementation detail. It is part of what is being studied, because the loop itself is the thing of interest and not only a way to reach an accuracy score. A footprint-first project would treat the same loop as plumbing.

The other tracks still stand on their own. Detection (`01`) is where the pivot came from. Candidate-rank sensitivity (`02`) and its mechanistic follow-up (`03`) look at how the model treats an ordered candidate list. The pipeline notes record which architecture choices are settled. Together they are the evidence behind the direction described here.

## Tracks

### `01` Gemma Improve Detection

This track collects the baseline failure analysis and the follow-up gating experiments for Gemma 4 species detection.

That question matters because the project needed to understand where detection breaks before adjusting ranking or confidence. This track covers the baseline, soft gate, follow-up analysis, and native-vs-emulated comparison.

#### File Guide

- [`01_gemma4-baseline-failure-analysis.md`](./01_gemma-improve-detection/01_gemma4-baseline-failure-analysis.md) is the starting point. It shows the baseline failure pattern and establishes the detection problem.
- [`02_gemma4-soft-gate.md`](./01_gemma-improve-detection/02_gemma4-soft-gate.md) introduces the soft-gate variant that changes how candidates are surfaced.
- [`03_gemma4-soft-gate-followup-analysis.md`](./01_gemma-improve-detection/03_gemma4-soft-gate-followup-analysis.md) checks what changed after the soft gate and which failure modes remained.
- [`tool-calling-vs-emulated.md`](./01_gemma-improve-detection/tool-calling-vs-emulated.md) compares the native and emulated tool-calling paths so the baseline numbers are interpreted correctly.

### `02` Candidate Rank Sensitivity

This track collects the experiments around a simple question: does the order of the candidate list change what Gemma 4 picks?

That question matters because Mero does not just show the model a set of candidates. It shows them in a ranked order, so rank is part of the product behavior. This track starts with the behavioral test, then follows up with confidence sensitivity, explanation faithfulness, and a merged LiteRT rank-bias analysis that covers both output-position behavior and token-score likelihood.

#### What Each File Answers

- [`01_candidate-rank-sensitivity.md`](./02_candidate-rank-sensitivity/01_candidate-rank-sensitivity.md) asks whether answer choice changes when the same candidates are reordered.
- [`02_confidence-score-sensitivity.md`](./02_candidate-rank-sensitivity/02_confidence-score-sensitivity.md) asks whether the displayed confidence values influence the answer.
- [`03_explanation-faithfulness.md`](./02_candidate-rank-sensitivity/03_explanation-faithfulness.md) checks whether the model’s short reason stays aligned with the answer under perturbation.
- [`04_litert-score-analysis.md`](./02_candidate-rank-sensitivity/04_litert-score-analysis.md) combines output-position bias and LiteRT token-score likelihood into one report.

The mechanistic backend plan is documented in the separate [Candidate Rank Mechanistic](./03_candidate-rank-mechanistic/) section below.

#### Why It Is Split This Way

The project needs two kinds of evidence.

- Behavioral evidence: does the answer change when we perturb the prompt?
- Output-surface evidence: is there a measurable preference for early positions even without internal hooks?

The first three docs focus on behavior. The LiteRT score analysis stays within the available runtime and explains what can still be measured there.

### `03` Candidate Rank Mechanistic

This folder holds the mechanistic Hugging Face follow-up for the candidate-rank work.

It is separated from the behavioral track on purpose. The LiteRT-backed reports answer what changes in the output. The mechanistic notes explain how the same Gemma 4 family can be analyzed with Hugging Face safetensors when hidden states, logits, and hooks are required.

#### File Guide

- [`00_plan.md`](./03_candidate-rank-mechanistic/00_plan.md) explains why the mechanistic backend uses Hugging Face Gemma 4 instead of LiteRT-LM.
- [`01_hf-logit-rank-bias.md`](./03_candidate-rank-mechanistic/01_hf-logit-rank-bias.md) describes the Hugging Face logit-level replication.
- [`02_prompt-format-controls.md`](./03_candidate-rank-mechanistic/02_prompt-format-controls.md) describes the prompt-format controls.
- [`03a_candidate-position-probing.md`](./03_candidate-rank-mechanistic/03a_candidate-position-probing.md) describes the main hidden-state probing plan, and [`03b_prompt-template-probing-controls.md`](./03_candidate-rank-mechanistic/03b_prompt-template-probing-controls.md) describes the probing robustness control.
- [`04_activation-patching-rank-bias.md`](./03_candidate-rank-mechanistic/04_activation-patching-rank-bias.md) describes the activation-patching plan.
- [`05_sae-inspection-plan.md`](./03_candidate-rank-mechanistic/05_sae-inspection-plan.md) describes the SAE compatibility gate and skip behavior.

## Why This Structure Exists

The goal is to make each research thread readable on its own.

- The pipeline track explains what architecture decisions are already settled.
- The detection track shows the baseline failure modes and the fixes that changed behavior.
- The candidate-rank track starts with behavioral sensitivity tests and the merged rank-bias report.
- The mechanistic backend plan lives in the separate `candidate-rank-mechanistic` folder.

If you are new to the project, start with the relevant track section above, then read the numbered docs in order.
