---
title: Mero as an On-Device Multimodal Agent
description: A map of Mero's identification loop, the points where evidence can be lost, what the experiments establish, and what remains untested.
type: article
url: /articles/agent-architecture-and-evaluation/
date: 2026-07-01
article_label: Synthesis
article_topic: On-device agent architecture
---

# Mero as an On-Device Multimodal Agent

[← Mero home](/sirkulab-mero/) · [Research notebook](/sirkulab-mero/research/) · [Source repository](https://github.com/atnanahidiw/sirkulab-mero)

A student can photograph a species, receive a confident answer, and never know that the correct species disappeared before the model compared candidates. That is the failure Mero investigates.

Mero is a bounded, tool-using multimodal agent. It interprets the photograph, sends structured queries to one local retrieval tool, observes the returned candidates, and may revise its decision. Unlike general-purpose autonomous agents, Mero operates within a bounded environment with one local tool, a fixed species database, and a narrow identification objective. Its action space is narrow, its species database is fixed, and its actions do not change the environment. The research question is whether adaptive observation, retrieval, revision, and stopping produce more reliable decisions than a fixed pipeline, at an acceptable cost on a phone.

This perceive-act-observe loop follows the broad pattern studied in [ReAct](https://arxiv.org/abs/2210.03629). Mero evaluates it using the diagnostic principle found in [AgentBoard](https://arxiv.org/abs/2401.13178) and [ToolSandbox](https://arxiv.org/abs/2408.04682): final accuracy alone cannot reveal where an agent succeeds or fails. The experiments therefore separate perception, routing, retrieval, candidate presentation, selection, and stopping.

## Research question

**Can a resource-constrained multimodal agent reliably identify a species by forming a hypothesis, retrieving local evidence, revising its answer, and stopping when the available evidence is sufficient?**

Each step can fail independently. The model can misread the image, search the wrong part of the database, receive an incomplete candidate set, follow an unreliable score, select the wrong candidate despite seeing the correct one, or stop with confidence that does not match correctness. Evaluating only final accuracy would hide where those failures enter the loop.

## Research contribution

> Mero contributes a deployment-grounded study of failure propagation in a small on-device multimodal agent. Its current results show that hard visual routing can discard recoverable evidence, retrieval scores influence final selection despite lacking calibration, and candidate-position information is linearly decodable from selected hidden states. The work does not yet establish that iterative tool use improves identification over a fixed retrieval pipeline.

The table separates supported findings from causal claims and deployment questions that remain untested.

| Claim | Status |
| --- | --- |
| Hard routing loses relevant candidates | Supported |
| Neighbor expansion increases in-sample retrieval recall | Supported |
| Expanded retrieval produced higher final accuracy in the current paired evaluation | Supported on the current dataset |
| Displayed scores causally affect selections | Supported by controlled permutations |
| Candidate rank affects likelihood | Supported in the HF text-only setting |
| Candidate-rank representation causes selection bias | Unconfirmed |
| Multiple tool calls improve identification | Untested |
| Current stopping policy is reliable | Untested |
| The loop is worth its device cost | Untested |
| Results generalize to unseen species or field conditions | Untested |

## Agent architecture

The baseline uses Gemma 4 E2B through LiteRT-LM. Instead of asking the model to identify a species in one response, Mero gives it a local tool named `search_similar_features`. The tool searches a curated SQLite database with FTS5 and reranks matches using weighted visual-feature similarity.

Gemma observes the photograph, proposes a coarse visual group and visible traits, calls the tool, reads the returned candidates, and decides whether to revise its hypothesis. The prompt tells Gemma to conclude after no more than four attempts. This is an instruction to the model, not a hard runtime limit. One recorded baseline case made five tool calls. After identification, the conversation is grounded in the selected species record.

The exact [baseline prompt and tool implementation](https://github.com/atnanahidiw/sirkulab-mero/blob/docs/scripts/gemma-improve-detection/eval_gemma4_baseline.py) are published with the evaluation code. This matters because the prompt defines the search procedure, the 45% candidate-score guidance, the requested attempt limit, and the final JSON format.

```mermaid
flowchart TD
    A["Photograph and current state"] --> B["Observe traits and form hypothesis"]
    B --> C["Call local search tool"]
    C --> D["Receive ranked candidates"]
    D --> E["Compare evidence and revise"]
    E --> F{"Model chooses to stop?"}
    F -->|No| B
    F -->|Yes| G["Return identification"]
    G --> H["Ground Q&A in species record"]
    I["Prompt requests at most four attempts"] -. "Not runtime-enforced" .-> F
```

| Agent component | Mero implementation                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------- |
| Environment     | A photograph and an on-device species database                                                                             |
| Objective       | Identify the photographed species and explain its conservation context                                                     |
| Observation     | Image evidence, conversation state, and retrieved candidates                                                               |
| Policy          | Observe, hypothesize, search, compare, revise, and decide whether to stop                                                  |
| Action          | Send structured visual and taxonomic fields to `search_similar_features`                                                   |
| Tool            | Local FTS5 retrieval followed by visual-feature reranking                                                                  |
| Feedback        | Candidate identities, ordering, descriptions, and displayed confidence values                                              |
| State           | Current hypothesis, previous tool calls, retrieved evidence, and pass count                                                |
| Termination     | Gemma is prompted to stop after a visually supported match or four attempts, but the runtime does not enforce that ceiling |
| Output          | A species prediction followed by Q&A grounded in its curated record                                                        |

This table describes the Gemma 4 baseline studied in [Track 01](/sirkulab-mero/01_gemma-improve-detection/). [Track 00](/sirkulab-mero/00_smaller-footprint-pipeline/) also studies alternative architectures that separate vision from reasoning so a smaller text model can use a dedicated vision tool. Those experiments should not be treated as measurements of the baseline loop above.

## Example execution

The baseline output records tool arguments and final structured answers, but not the candidate list returned after each call. The traces below show only recorded fields. They do not reconstruct hidden reasoning or unrecorded tool output.

### Successful revision

```text
Image: atelopus_varius_1.jpg
Ground truth: Atelopus varius

Call 1
Visual group: Lizard
Observed traits: dark skin with bright orange and yellow markings

Call 2
Revised visual group: Frog & toad

Final answer: Atelopus varius
Confidence: high
Result: correct
```

The second call repaired the coarse routing error and ended with the correct species. This shows that revision can work in an individual case. It does not measure how often revision helps across the dataset.

### Failed revision

```text
Image: cheilinus_undulatus_2.jpg
Ground truth: Cheilinus undulatus

Call 1: Marine mammal
Call 2: Marine fish
Call 3: Mollusk & marine invertebrate

Final answer: Tridacna gigas
Confidence: medium
Result: incorrect
```

This run reached the correct coarse group on its second call, then moved away from it and returned the wrong organism. More calls did not guarantee a better final decision. As with the successful trace, one case illustrates a path through the loop rather than its frequency.

## Where the loop can fail

Mero's clearest result is a decomposition of identification into interfaces that can fail separately.

The first boundary lies between visual interpretation and retrieval. In the original design, Gemma's predicted `visual_group` acts as a hard database filter. If that coarse group is wrong, the true species may disappear before the model compares individual candidates. Every later component can operate normally while reasoning over an incomplete candidate set.

The second boundary lies between retrieval and synthesis. Making the correct species available does not ensure that Gemma selects it. A broader search recovers missing evidence, but it also introduces more alternatives. The model must still distinguish the correct species from plausible look-alikes.

The third boundary lies between candidate presentation and the final decision. Candidate order and displayed confidence are part of what the model reads. They are therefore inputs to the policy, even when the application treats them as neutral retrieval metadata.

The fourth boundary lies between representation and causal use. Track 03 finds that candidate position is strongly recoverable from hidden states, but the first activation-patching study does not show that candidate-local activations drive the final score. Information can be present inside the model without serving as the causal mechanism first expected.

## What the experiments reveal

| Finding | Measured result | Evidence |
| --- | --- | --- |
| Hard routing often removes the true species | 157 of 332 surfaced, 47.3% retrieval recall | [Soft-gate evaluation](/sirkulab-mero/01_gemma-improve-detection/02_gemma4-soft-gate/) |
| Neighbor-expanded routing recovers evidence | 289 of 332 surfaced, 87.0% retrieval recall | [Soft-gate evaluation](/sirkulab-mero/01_gemma-improve-detection/02_gemma4-soft-gate/) |
| Better retrieval does not fully solve selection | Accuracy rose from 37.7% to 48.2% | [Soft-gate evaluation](/sirkulab-mero/01_gemma-improve-detection/02_gemma4-soft-gate/) |
| The requested attempt limit is not enforced | 1 of 332 cases made five tool calls | [Baseline failure analysis](/sirkulab-mero/01_gemma-improve-detection/01_gemma4-baseline-failure-analysis/) |
| Final confidence is an imperfect correctness signal | 81 of 156 high-confidence answers were correct, 51.9% | [Baseline failure analysis](/sirkulab-mero/01_gemma-improve-detection/01_gemma4-baseline-failure-analysis/) |
| Displayed confidence changes decisions | 33.1% of perturbed trials changed answer | [Confidence sensitivity](/sirkulab-mero/02_candidate-rank-sensitivity/02_confidence-score-sensitivity/) |
| Incorrect score assignment harms accuracy | Accuracy fell from 67.2% to 48.4% | [Confidence sensitivity](/sirkulab-mero/02_candidate-rank-sensitivity/02_confidence-score-sensitivity/) |
| Candidate position changes likelihood | Rank 1 minus rank 5 paired difference: 0.504 average log probability, 95% CI [0.415, 0.599] | [Logit rank-bias study](/sirkulab-mero/03_candidate-rank-mechanistic/01_hf-logit-rank-bias/) |
| Candidate position is linearly decodable | Candidate-identity split accuracy: 99.6% | [Candidate-position probing](/sirkulab-mero/03_candidate-rank-mechanistic/03a_candidate-position-probing/) |
| Candidate-local causality remains unconfirmed | Candidate-local patches did not clearly outperform matched controls | [Activation patching](/sirkulab-mero/03_candidate-rank-mechanistic/04_activation-patching-rank-bias/) |

The routing results show how much evidence the first hypothesis can discard. Replacing the hard gate with neighbor-expanded retrieval raised recall by 39.7 percentage points without losing any cases from the original route. That establishes the value of recoverable retrieval. It does not establish that the exact 87.0% recall will hold on unseen data because the neighbor map was built from the same run's confusion matrix.

The native rerun shows the next problem. The gain in retrieval recall produced a smaller gain in final accuracy. The follow-up counted 54 cases that changed from wrong to correct and 19 that changed from correct to wrong, a net gain of 35 (37.7% to 48.2%). Because the same 332 images were scored under both routing policies, the difference is a paired one: a McNemar test on the 73 discordant cases gives χ² ≈ 15.8 (p < 0.001), and the 10.5-percentage-point improvement carries an approximate 95% confidence interval of 5.6 to 15.5 points. Fourteen regressions were within-group congener errors, while three came from distractors introduced by neighboring groups. The broader route recovered more relevant evidence, but candidate discrimination and final selection limited the resulting accuracy gain.

Track 02 holds the photograph, candidate identities, and candidate order fixed while changing displayed confidence. The resulting answer changes show that retrieval scores are not passive annotations. Gemma treats them as evidence, although the scores are not calibrated probabilities of correctness. Rank also affects decisions, but less strongly in the far-separated candidate experiment.

Track 03 studies this effect through an inspectable Hugging Face backend. Moving the same candidate from rank 1 to rank 5 lowered its likelihood, and candidate position was nearly perfectly decodable from selected hidden-state features. Those findings do not prove how the deployed Android loop reaches its decisions. Tracks 01 and 02 primarily evaluate LiteRT-backed identification with images, while Track 03 uses text-only prompts and Hugging Face weights to inspect logits and activations. The mechanistic results constrain possible explanations, but they do not establish the decision mechanism used by the deployed multimodal system.

## What remains unknown

The existing research has not established that Mero's iterative loop outperforms a one-pass retrieval pipeline.

In the 332-image native baseline, 260 cases used one tool call, 64 used two, 7 used three, and 1 used five. Observed accuracy was 38.8%, 34.4%, 28.6%, and 0% in those groups. These figures do not show that extra calls reduce accuracy. Harder examples are more likely to trigger revision, and only eight cases made more than two calls. A controlled pass-count comparison is needed to separate the effect of revision from the difficulty that caused the model to continue.

Stopping also remains untested as a policy. The prompt tells Gemma to conclude when a retrieved candidate scores at least 45% and visually matches, or after four attempts. The runtime does not enforce that limit, and the model's final confidence label is not a calibrated stopping signal. High-confidence answers were correct in 51.9% of baseline cases. An explicit controller should be compared with alternatives such as stopping after an unchanged hypothesis or after retrieved evidence supports the current answer.

The full loop also needs direct robustness tests. Relevant cases include empty search results, malformed tool output, contradictory candidates, repeated calls, and confident synthesis after the correct species has been retrieved.

Because Mero runs on a phone, accuracy is only one part of the comparison. Each policy should also report latency, tool calls, generated tokens, memory use, energy use, and device temperature.

## Planned Track 04: Agent-loop evaluation

Track 04 should begin with three controlled experiments:

1. **Loop ablation against a deterministic baseline.** Compare five conditions on the same frozen examples, from no tool use to the full adaptive loop:
   1. Direct VLM identification with no tool.
   2. Fixed retrieval followed by one selection pass.
   3. One model-selected tool call.
   4. Up to two adaptive calls.
   5. Up to four adaptive calls with explicit stopping.

   > Condition 2 is the critical control. It hands the model a strong candidate list without letting it choose the query, so it isolates whether the agent's adaptive tool choice adds anything beyond good retrieval. Adaptive passes alone — zero, one, two, four — cannot answer that, because they never compare against a non-agentic pipeline.

2. **Revision analysis.** Measure wrong-to-correct recovery, correct-to-wrong degradation, unchanged decisions, and the pass where the true species first becomes available.
3. **Stopping-policy comparison.** Compare a fixed pass limit with unchanged-hypothesis and evidence-based stopping rules.

Each pass should record the current hypothesis, tool arguments, returned candidates, displayed confidence, selected species, and stopping reason. These records would connect the behavioral findings in Tracks 01 and 02 with the full control loop.

## How the research fits together

| Track                                                                            | Question                                                                          |
| -------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| [Track 00: Smaller footprint](/sirkulab-mero/00_smaller-footprint-pipeline/)     | Can Mero reduce its model and runtime footprint without losing its core behavior? |
| [Track 01: Detection failures](/sirkulab-mero/01_gemma-improve-detection/)       | Where do perception, routing, retrieval, and synthesis fail?                      |
| [Track 02: Candidate sensitivity](/sirkulab-mero/02_candidate-rank-sensitivity/) | How do candidate order, confidence, and explanations affect behavior?             |
| [Track 03: Mechanistic analysis](/sirkulab-mero/03_candidate-rank-mechanistic/)  | How is candidate position represented, and does it have a measurable causal role? |
| Track 04: Agent-loop evaluation, planned                                         | Does iteration improve decisions enough to justify its cost?                      |

The current evidence supports a narrow conclusion. Mero is an on-device multimodal agent whose result depends on a chain of fallible interfaces. The experiments show where evidence is lost and how candidate presentation can influence the final choice. Whether the adaptive loop is better than a simpler pipeline remains a hypothesis, not a result.
