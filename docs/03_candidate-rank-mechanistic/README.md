# Candidate Rank Mechanistic Interpretability

The behavioral work in Mero established a simple but uncomfortable fact: the model can change its species answer when the image stays fixed and only the candidate order changes.

That result is enough to show rank sensitivity, but it is not enough to explain it.

This document is the research story for the mechanistic follow-up. It asks where the rank effect enters the model's computation, what kind of internal signal carries it, and how careful we need to be before calling that signal a real mechanism instead of a prompt artifact.

This project uses Mero as a bounded entry point into mechanistic interpretability: one real model failure mode, studied through progressively stronger evidence about scoring, representation, and causal intervention.

## The anomaly

The earlier LiteRT analysis produced a mismatch.

At the final-answer level, the model often behaved as if earlier candidates were favored. At the token-score level, the same candidate could sometimes receive better likelihood when it appeared later in the list.

That gap matters because it suggests the system is not just showing a trivial "first item wins" or "last item wins" heuristic. Something in the interaction between prompt layout, answer generation, candidate scoring, and internal representation is shaping the result.

The deployed LiteRT runtime is the right runtime for shipping Mero, but it is not the right runtime for this internal analysis. It does not expose the logits, hidden states, or hook points needed for inspection.

So the mechanistic investigation switches to an inspectable Hugging Face Gemma 4 backend. The model family stays aligned, but the analysis becomes observable. Any writeup should state that caveat plainly: this is a mechanistic backend matched to the same model family, not a byte-for-byte reproduction of the mobile runtime.

## The research question

The central question is:

Does candidate rank matter because it changes the output scoring surface, because it becomes represented inside hidden states, because that representation causally affects candidate likelihood, or because the prompt format leaks the answer through shallow structure?

That question is deliberately narrower than "how does Gemma 4 work?" It is a local investigation into one concrete failure mode.

## Purpose

This folder is organized around five questions:

- Can candidate order change the final answer?
- Does the same candidate receive different likelihood at different ranks?
- Does that effect survive changes in the prompt surface?
- Is candidate rank available in hidden states?
- Can any valid Gemma-family SAE evidence support feature-level interpretation?

## Evidence ladder

The work is organized as an evidence ladder. Each stage earns a stronger claim than the one before it.

1. **Score-level replication** — Check whether the same candidate receives different likelihood at different positions under Hugging Face scoring. If the effect disappears, the broader interpretation weakens immediately.

2. **Prompt-format controls** — Vary the prompt surface to separate position-related effects from layout, recency, or answer-template artifacts.

3. **Hidden-state probing** — Ask whether candidate position is decodable from the representation. Use marker/no-marker and prompt-template controls so the result is not mistaken for a prompt-surface artifact.

4. **Activation patching** — Patch activations from a clean prompt into a corrupted one that differs only in target-candidate position. If scores recover or the answer flips back, that is stronger evidence of causal participation.

5. **Optional feature inspection** — Treat SAE or Gemma Scope-style inspection as optional. Only use it if compatible artifacts exist; otherwise skip it or label it as surrogate analysis.

## How the reports fit together

This is the reading order and the report map.

Current status:

- The behavioral anomaly is established from the earlier LiteRT work.
- The mechanistic backend is Hugging Face Gemma 4, used because it exposes logits and hidden states needed for inspection.
- TransformerLens is background tooling context, not the assumed implementation path for this Gemma 4 workflow.
- NNsight and pyvene are the most plausible future upgrades for intervention tooling.
- SAE or Gemma Scope-style analysis remains optional and should not be treated as Gemma 4 evidence without compatible artifacts.

Read the reports in this order:

- [`01_hf-logit-rank-bias.md`](./01_hf-logit-rank-bias.md): score-level replication under the inspectable Hugging Face backend
- [`02_prompt-format-controls.md`](./02_prompt-format-controls.md): prompt-format and answer-format controls
- [`03a_candidate-position-probing.md`](./03a_candidate-position-probing.md): hidden-state probing for candidate position
- [`03b_prompt-template-probing-controls.md`](./03b_prompt-template-probing-controls.md): probing robustness across template controls
- [`04_activation-patching-rank-bias.md`](./04_activation-patching-rank-bias.md): causal intervention on the rank effect
- [`05_sae-inspection-plan.md`](./05_sae-inspection-plan.md): optional feature-level analysis, only if compatible artifacts exist

The intended story is simple:

Behavior shows that rank sensitivity exists.  
Scoring shows that candidate likelihood moves with rank.  
Prompt controls show that formatting matters.  
Probing asks whether rank information is represented.  
Patching asks whether that representation matters causally.  
SAE inspection is optional and only valid if the artifacts match the model.

## Claim strength and falsification

This line of work supports bounded claims, but each stage supports a different level of evidential strength.

A score-level result supports the claim that the same candidate receives systematically different likelihood as its rank changes. This does not identify an internal mechanism, but it anchors the behavioral anomaly to a concrete model quantity.

A prompt-control result supports the claim that the score-level effect is not merely a surface artifact. If the effect survives some formatting changes, the evidence is stronger than if it collapses under small prompt variations.

A probing result supports the claim that candidate rank is recoverable from hidden states. That is evidence of internal representation, but it still falls short of showing that the model uses that representation causally when selecting the answer.

A causal-intervention result supports the stronger claim that selected activations participate in the rank-sensitive computation. If patching moves candidate scores or answer identity, the evidence extends beyond observation and into intervention.

A feature-level result supports interpretive claims only when the artifacts are compatible with the model under study. Without that compatibility, SAE or Gemma Scope-style inspection should be treated as future work or as a clearly labeled surrogate analysis rather than direct evidence about Gemma 4.

This distinction does not weaken the project; it makes the claim more precise. The project moves from a controlled behavioral anomaly toward internal representations and causal interventions. The caution concerns evidential scope, not project value.

## What would change our mind

Each stage should have a falsification condition before the decisive run.

- Score-level replication:
  We should stop treating rank as a score-level effect if same-candidate likelihood differences disappear or become unstable under the matched Hugging Face setup.
- Prompt-format controls:
  We should weaken the rank-effect interpretation if small prompt-surface changes remove the effect entirely or reveal that it is mostly a numbered-list or answer-field artifact.
- Hidden-state probing:
  We should stop trusting the probe if shuffled-label baselines perform similarly, grouped splits collapse, or signal only survives visible rank markers.
- Activation patching:
  We should stop claiming causal involvement for a patched site if clean-to-corrupt intervention does not reliably move candidate scores or answer identity beyond nearby or random patch baselines.
- SAE or Gemma Scope-style inspection:
  We should not make Gemma 4 feature claims unless compatible Gemma 4 artifacts are verified or trained explicitly for this model family.

## Literature review

This project sits at the intersection of four strands of mechanistic-interpretability work.

The first strand is research methodology. Neel Nanda's "How To Become A Mechanistic Interpretability Researcher" argues that the field is best learned through short empirical loops rather than long reading-only phases. That framing is directly relevant here: the candidate-rank question is small enough to support a sequence of bounded experiments, and the key discipline is not to jump from an interesting pattern to a strong claim without passing through baselines, ablations, and failure analysis.

The same methodological stance also appears in current field-overview work such as Lee Sharkey et al.'s "Open Problems in Mechanistic Interpretability," which frames the field as an effort to understand computational mechanisms for concrete scientific and engineering goals, while emphasizing that existing methods still face conceptual and practical limits.

The second strand is circuits-style interpretability. Anthropic's Transformer Circuits thread established the core research program of reverse-engineering learned computations into features and circuits, and it helped normalize causal tests rather than purely descriptive ones. That matters for Mero because a rank effect that is only visible in output behavior is weaker than a rank effect that survives a controlled internal intervention. For this reason, activation patching is not treated here as an optional flourish; it is the step that can move the work from "rank is represented" toward "rank participates in the computation."

The third strand is tooling. TransformerLens remains an important reference point for the field because it standardized much of the current activation-patching and small-model workflow vocabulary. But this project should not assume TransformerLens-native support for the exact Gemma 4 workflow. For a Hugging Face Gemma 4 path, the more relevant implementation direction is direct PyTorch intervention, NNsight, or pyvene. The reason these tools matter is that the next step is not only to observe hidden states, but to intervene on them. These tools define the practical backdrop for work that needs intervention tooling while staying close to the current Gemma 4 stack.

The fourth strand is sparse feature analysis. SAELens has become a standard open-source route for loading, training, and analyzing sparse autoencoders. Google DeepMind's Gemma Scope 2 extends this style of analysis to the Gemma 3 family with SAEs and transcoders trained across the model stack, and Neuronpedia provides an interactive interface for exploring those released artifacts. That ecosystem matters for Mero because it shows a plausible path from rank-sensitive behavior to feature-level inspection, but it also imposes a clear constraint: Gemma Scope-style analysis can inform the method, but direct feature-level claims about Gemma 4 require Gemma 4-compatible artifacts or newly trained artifacts for the model under study.

Taken together, this literature suggests a disciplined progression for the present project. A behavioral anomaly should first be reproduced at the score level, then stress-tested against formatting controls, then examined for linear decodability, and only then subjected to causal intervention and optional feature-level analysis.

That progression is conservative by design. It reflects the current best practice in mechanistic interpretability: use the smallest falsifying experiment that can test the strongest claim you are tempted to make.

## Selected sources

- Neel Nanda. "How To Become A Mechanistic Interpretability Researcher." LessWrong, September 2, 2025. https://www.lesswrong.com/posts/jP9KDyMkchuv6tHwm/how-to-become-a-mechanistic-interpretability-researcher
- Lee Sharkey et al. "Open Problems in Mechanistic Interpretability." arXiv:2501.16496, January 27, 2025. https://arxiv.org/abs/2501.16496
- Anthropic. "Transformer Circuits Thread." https://transformer-circuits.pub/
- TransformerLens documentation. "Getting Started in Mechanistic Interpretability." https://transformerlensorg.github.io/TransformerLens/content/getting_started_mech_interp.html
- TransformerLens documentation. "Model Properties Table." https://transformerlensorg.github.io/TransformerLens/generated/model_properties_table.html
- Zhengxuan Wu, Atticus Geiger, Aryaman Arora, Jing Huang, Zheng Wang, Noah Goodman, Christopher Manning, and Christopher Potts. "pyvene: A Library for Understanding and Improving PyTorch Models via Interventions." NAACL 2024 System Demonstrations. https://stanfordnlp.github.io/pyvene/
- NNsight documentation. https://nnsight.net/
- SAELens repository and documentation. https://github.com/decoderesearch/SAELens
- Google DeepMind Language Model Interpretability Team. "Gemma Scope 2: Helping the AI Safety Community Deepen Understanding of Complex Language Model Behavior." December 19, 2025. https://deepmind.google/blog/gemma-scope-2-helping-the-ai-safety-community-deepen-understanding-of-complex-language-model-behavior/
- Neuronpedia. "Gemma Scope 2: Suite of SAEs and Transcoders for Gemma 3." https://www.neuronpedia.org/gemma-scope-2
