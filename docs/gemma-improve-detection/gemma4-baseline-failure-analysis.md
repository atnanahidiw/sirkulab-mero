# Gemma 4 baseline: merged failure analysis (native + emulated)

Both tool-calling implementations of the same Gemma 4 E2B pipeline, scored on the same
332-image / 64-species curated set. Tables merge both runs side-by-side; native (N) is
authoritative, while emulated (E) is reference only. Its absolute numbers undercount due to a 28%
stall artefact.

| run | n | species top-1 | genus | no-final stalls |
| --- | --: | --: | --: | --: |
| **native** (authoritative) | 332 | **37.7% (125)** | 41.3% (137) | **0.9% (3)** |
| emulated | 332 | 17.2% (57) | 19.0% (63) | 28.3% (94) |

The native jump is mostly the stall artefact disappearing: emulated parsed tool calls
from free text, so many images never reached a valid final answer; native `litert_lm`
function calling reduces no-final cases from **94 → 3**. That makes **37.7%** the real
v1 baseline. The sections below show where the remaining failures go once the
tool-calling noise is gone.

---

## Plants harder than animals

| kingdom | n | E: species-ok | E: no-final | N: species-ok | N: no-final |
| --- | --: | --: | --: | --: | --: |
| Plantae | 72 | **8%** | 33% | **19%** | 3% |
| Animalia | 260 | **20%** | 27% | **43%** | 0% |

Plants remain ~2× harder once stalls are removed (2.5× emulated → 2.3× native). The
high emulated stall rate on plants (33%) was partly parse artefact and partly genuine
looping. Species accuracy stays low in native even with stalls gone.

---

## By visual group

Ordered by native species-ok ascending.

| visual_group | n | E: species-ok | E: no-final | N: species-ok | N: no-final |
| --- | --: | --: | --: | --: | --: |
| Palm tree | 6 | 0% | 0% | **0%** | 33% |
| Mangrove | 10 | 0% | 60% | **0%** | 0% |
| Vine & climber | 6 | 0% | 67% | **0%** | 0% |
| Small quadruped mammal | 24 | 0% | 38% | **4%** | 0% |
| Tall broadleaf tree | 30 | 7% | 23% | **23%** | 0% |
| Shrub & bush | 10 | 20% | 50% | **30%** | 0% |
| Marine fish | 57 | 12% | 19% | **32%** | 0% |
| Flying bird | 60 | 15% | 33% | **35%** | 2% |
| Fern | 10 | 20% | 20% | **40%** | 0% |
| Turtle & tortoise | 10 | 60% | 10% | **40%** | 0% |
| Primate | 64 | 30% | 22% | **55%** | 0% |
| Frog & toad | 5 | 20% | 20% | **60%** | 0% |
| Large quadruped mammal | 15 | 13% | 40% | **60%** | 0% |
| Mollusk & marine invertebrate | 15 | 40% | 13% | **67%** | 0% |
| Lizard | 10 | 10% | 60% | **100%** | 0% |

Notable shifts: Lizard jumps from 10% to 100% and Large quadruped mammal from 13% to
60%. Both were stall-dominated in emulated. Turtle & tortoise drops from 60% to 40%
(emulated high was partly artefactual). Bottom three (Palm, Mangrove, Vine) stay at 0%
in both runs.

---

## Species never identified correctly

All 35 species that scored 0% in the emulated run, with their native accuracy. Grouped by
visual_group, ordered by N:ok ascending within each group. **Bold = still 0% in native**
(17 truly hard cases).

| visual_group | species | n | E: ok | N: ok |
| --- | --- | --: | --: | --: |
| Fern | ***Stenochlaena palustris*** | 5 | 0% | **0%** |
| Flying bird | ***Aythya affinis*** | 5 | 0% | **0%** |
| Flying bird | ***Macrocephalon maleo*** | 5 | 0% | **0%** |
| Flying bird | *Acridotheres javanicus* | 5 | 0% | 20% |
| Flying bird | *Aythya valisineria* | 5 | 0% | 20% |
| Flying bird | *Lophura erythrophthalma* | 5 | 0% | 40% |
| Flying bird | *Leucopsar rothschildi* | 5 | 0% | 80% |
| Flying bird | *Mycteria cinerea* | 5 | 0% | 80% |
| Flying bird | *Aulacorhynchus prasinus* | 5 | 0% | 100% |
| Large quadruped mammal | *Sus barbatus* | 5 | 0% | 80% |
| Lizard | *Varanus komodoensis* | 5 | 0% | 100% |
| Mangrove | ***Avicennia germinans*** | 5 | 0% | **0%** |
| Mangrove | ***Avicennia marina*** | 5 | 0% | **0%** |
| Marine fish | ***Hippocampus histrix*** | 7 | 0% | **0%** |
| Marine fish | ***Hippocampus kuda*** | 8 | 0% | **0%** |
| Marine fish | *Cheilinus undulatus* | 8 | 0% | 38% |
| Marine fish | *Mobula alfredi* | 5 | 0% | 40% |
| Marine fish | *Triaenodon obesus* | 5 | 0% | 40% |
| Marine fish | *Bolbometopon muricatum* | 7 | 0% | 43% |
| Mollusk & marine invertebrate | *Tridacna gigas* | 5 | 0% | 60% |
| Palm tree | ***Pandanus benstoneoides*** | 6 | 0% | **0%** |
| Primate | *Symphalangus syndactylus* | 5 | 0% | 20% |
| Primate | *Presbytis melalophos* | 5 | 0% | 40% |
| Primate | *Trachypithecus auratus* | 5 | 0% | 40% |
| Primate | *Tarsius spectrumgurskyae* | 5 | 0% | 100% |
| Small quadruped mammal | ***Ailurops ursinus*** | 5 | 0% | **0%** |
| Small quadruped mammal | ***Helarctos malayanus*** | 5 | 0% | **0%** |
| Small quadruped mammal | ***Neofelis diardi*** | 5 | 0% | **0%** |
| Small quadruped mammal | ***Spilocuscus papuensis*** | 5 | 0% | **0%** |
| Small quadruped mammal | *Maxomys whiteheadi* | 4 | 0% | 25% |
| Tall broadleaf tree | ***Eucalyptus urophylla*** | 5 | 0% | **0%** |
| Tall broadleaf tree | ***Vitex quinata*** | 5 | 0% | **0%** |
| Tall broadleaf tree | *Pterocarpus indicus* | 5 | 0% | 20% |
| Tall broadleaf tree | *Tectona grandis* | 5 | 0% | 60% |
| Vine & climber | ***Atragene grahamii*** | 6 | 0% | **0%** |

The 18 that native recovered are mostly iconic or distinctive species the emulated stalls
never reached (*Varanus komodoensis* 100%, *Tarsius spectrumgurskyae* 100%,
*Leucopsar rothschildi* 80%, *Sus barbatus* 80%). The 17 that remain 0% are the genuinely
hard cases: all mangroves, all vines, all palm trees, seahorses, most small quadruped
mammals.

---

## Pipeline decomposition

| failure point | E: count | E: share | N: count | N: share |
| --- | --: | --: | --: | --: |
| **Wrong `visual_group` bucket** → FTS5 filter excludes true species | 110 | 40% | 114 | **55%** |
| **Synthesis:** true species in candidates, Gemma picked wrong | 83 | 30% | 68 | **33%** |
| Stall / no parseable tool call (emulation artefact) | 71 | 26% | - | - |
| Right bucket, search still didn't surface it | 11 | 4% | 25 | 12% |

⚠️ **The shares are not directly comparable across runs.** The jump from 40% → 55%
on wrong-VG is a denominator artefact, not a model behaviour change. The denominator
shrinks in native for two reasons:

- **Stall bucket disappears:** 71 images that were their own failure category ("stall,
  26%") are now resolved into real tool calls in native.
- **More images succeed:** native gets 125 correct vs 57 in emulated.

Remove stalls from the emulated denominator to make a fair comparison:

`110 / (275 - 71) = 110 / 204 = 54%`. That is basically the same as native's 55%.

The absolute wrong-VG count also barely moves (110 → 114). The +4 comes from those 71
formerly-stalled images now firing a tool call in native: they cluster in the hardest
groups (mangrove, vine, small quadruped mammal) where VG accuracy is ~0%, so they
mostly land in the wrong-VG bucket rather than anywhere else.

---

## Visual-group confusion

Bucket accuracy overall depends on the denominator:

| run | denominator | correct / total | bucket accuracy | why this denominator matters |
| --- | --- | --: | --: | --- |
| emulated | parseable first tool calls only | 148 / 261 | **56.7%** | Measures Gemma's visual-group choice only when the emulated parser successfully extracted a first tool call. This excludes the 71 stalled/no-parse images, so it is the fairest estimate of the model's bucket choice conditional on a usable tool call. |
| emulated | all images, counting no-parse as wrong | 148 / 332 | **44.6%** | Measures end-to-end v1 reliability under the emulated harness. This is lower because ~21% of all images never produced a parseable first tool call, so no valid DB-filter bucket existed. |
| native | all images | 176 / 332 | **53.0%** | Native function calling removes the parse artefact, so every image gets a real tool call. This is the authoritative v1 number for first-pass `visualGroup` reliability. |

Use the native **53.0%** when judging the real app-like pipeline. Use the emulated
**56.7% parseable-only** number only for comparing the model's behaviour on cases where
the emulated tool-call parser worked. Do **not** compare native 53.0% to emulated 44.6%
as a pure model-behaviour change; the latter includes parser failures as bucket misses.

### Per-group accuracy

Ordered by N:correct ascending. "correct" = predicted visual_group matched the true label.

| true visual_group | n | E: correct | N: correct | E: top wrong | N: top wrong |
| --- | --: | --: | --: | --- | --- |
| Palm tree | 6 | 0% | 0% | Tall broadleaf tree 4 | Tall broadleaf tree 4 |
| Mangrove | 10 | 0% | 0% | Shrub & bush 2, Ground herb 2 | Shrub & bush 5, Ground herb 3 |
| Vine & climber | 6 | 33% | 0% | Grass & bamboo 2 | Tall broadleaf tree 4, Shrub & bush 2 |
| Small quadruped mammal | 24 | 4% | 4% | Primate 13 | Primate 20 |
| Shrub & bush | 10 | 10% | 20% | Tall broadleaf tree 4 | Tall broadleaf tree 7 |
| Flying bird | 60 | 28% | 30% | Primate 16 | Primate 26 |
| Fern | 10 | 30% | 30% | Tall broadleaf tree 5 | Tall broadleaf tree 4 |
| Frog & toad | 5 | 20% | 40% | Lizard 3 | Lizard 3 |
| Marine fish | 57 | 47% | 51% | Mollusk 10, Marine mammal 8 | Marine mammal 12, Mollusk 10 |
| Tall broadleaf tree | 30 | 40% | 57% | Shrub & bush 8 | Shrub & bush 9 |
| Large quadruped mammal | 15 | 47% | 73% | - | Mammal 2 |
| Mollusk & marine invertebrate | 15 | 73% | 87% | Aquatic plant 3 | Aquatic plant 2 |
| Primate | 64 | 77% | 95% | Tall broadleaf tree 2 | Tall broadleaf tree 2 |
| Lizard | 10 | 80% | 100% | - | - |
| Turtle & tortoise | 10 | 90% | 100% | - | - |

The emulated "correct %" for groups like Vine & climber (33% E vs 0% N) and Lizard (80%
E vs 100% N) look inconsistent. They are: emulated VG accuracy is computed only on
parseable tool calls. The stalls in those groups tend to be the wrong-VG cases, so
excluding them inflates the emulated "correct" rate.

### Most frequent wrong-predicted groups

| predicted wrong group | E: count | N: count |
| --- | --: | --: |
| no parse / stall | 71 | - |
| Primate | 31 | **47** |
| Tall broadleaf tree | 16 | **26** |
| Shrub & bush | 10 | **17** |
| Marine mammal | 8 | **14** |
| Mollusk & marine invertebrate | 11 | 11 |
| Ground herb | - | 5 |
| Waterfowl | - | 5 |
| Lizard | 4 | 5 |
| Flying mammal | 4 | 2 |
| Aquatic plant | 4 | 3 |
| Aroid & giant herb | 4 | - |

Once "no parse / stall" is removed in native, the Primate pull and plant collapse become
more visible. They did not grow; the stall noise no longer dilutes them.

### Top confusion pairs

Real misclassifications (E "no parse" rows listed separately below).

| true | predicted | E: count | N: count |
| --- | --- | --: | --: |
| Flying bird | Primate | 16 | **26** |
| Small quadruped mammal | Primate | 13 | **20** |
| Marine fish | Marine mammal | 8 | **12** |
| Marine fish | Mollusk & marine invertebrate | 10 | 10 |
| Tall broadleaf tree | Shrub & bush | 8 | 9 |
| Shrub & bush | Tall broadleaf tree | 4 | 7 |
| Fern | Tall broadleaf tree | 5 | 4 |
| Mangrove | Shrub & bush | 2 | 5 |
| Flying bird | Waterfowl | 2 | 5 |
| Palm tree | Tall broadleaf tree | 4 | 4 |
| Vine & climber | Tall broadleaf tree | - | 4 |
| Flying bird | Flying mammal | 4 | 2 |
| Frog & toad | Lizard | 3 | 3 |
| Mollusk & marine invertebrate | Aquatic plant | 3 | 2 |
| Mangrove | Ground herb | 2 | 3 |
| Flying bird | Tall broadleaf tree | - | 3 |
| Primate | Tall broadleaf tree | 2 | 2 |
| Palm tree | Aroid & giant herb | 2 | 2 |

Emulated-only no-parse / stall rows. These disappear in native:

| true | E: count |
| --- | --: |
| Flying bird | 17 |
| Primate | 12 |
| Small quadruped mammal | 9 |
| Marine fish | 7 |
| Tall broadleaf tree | 6 |
| Large quadruped mammal | 6 |
| Mangrove | 4 |
| Shrub & bush | 3 |

The structural pairs (bird→Primate, mammal→Primate, fish→Marine mammal, tree→tree) all
persist and grow in native once parse noise is removed. They are model behaviours, not
artefacts.

---

## Per-category: vg-sel and accuracy

Each visual group has two rows: E (emulated) then N (native). The numbers for the
same group are directly comparable.

Column legend:
- **vg-sel:** did the first tool call name the correct visual_group? This is the bucket the DB search filters on.
- **retrieval:** did the FTS5 search return the true species when replaying the first tool call?
- **synth|surf:** when the true species was in the results, did Gemma pick it? This measures synthesis ability independently of retrieval. `-` means the true species never appeared in search results, so synthesis was never tested.
- **species-ok:** final predicted species was correct (end-to-end accuracy for this group)

E:n = images with a parseable tool call · N:n = all images · groups ordered by N:species-ok ascending.

| visual_group | run | n | vg-sel | retrieval | synth\|surf | species-ok |
| --- | --- | --: | --: | --: | --: | --: |
| **Palm tree** | E | 6 | 0% | 0% | - | 0% |
| | N | 6 | 0% | 0% | - | 0% |
| **Mangrove** | E | 6 | 0% | 0% | - | 0% |
| | N | 10 | 0% | 0% | - | 0% |
| **Vine & climber** | E | 4 | 50% | 50% | 0% | 0% |
| | N | 6 | 0% | 0% | - | 0% |
| **Small quadruped mammal** | E | 15 | 7% | 7% | 0% | 0% |
| | N | 24 | 4% | 4% | 100% | 4% |
| **Tall broadleaf tree** | E | 24 | 50% | 50% | 17% | 7% |
| | N | 30 | 57% | 43% | 46% | 23% |
| **Shrub & bush** | E | 7 | 14% | 14% | 100% | 20% |
| | N | 10 | 20% | 20% | 100% | 30% |
| **Marine fish** | E | 50 | 54% | 48% | 29% | 12% |
| | N | 57 | 51% | 46% | 58% | 32% |
| **Flying bird** | E | 43 | 40% | 40% | 53% | 15% |
| | N | 60 | 30% | 27% | 44% | 35% |
| **Fern** | E | 9 | 33% | 33% | 33% | 20% |
| | N | 10 | 30% | 30% | 100% | 40% |
| **Turtle & tortoise** | E | 9 | 100% | 100% | 67% | 60% |
| | N | 10 | 100% | 100% | 40% | 40% |
| **Primate** | E | 52 | 94% | 79% | 46% | 30% |
| | N | 64 | 95% | 78% | 70% | 55% |
| **Frog & toad** | E | 4 | 25% | 25% | 100% | 20% |
| | N | 5 | 40% | 40% | 100% | 60% |
| **Large quadruped mammal** | E | 9 | 78% | 78% | 29% | 13% |
| | N | 15 | 73% | 73% | 82% | 60% |
| **Mollusk & marine invertebrate** | E | 15 | 73% | 73% | 55% | 40% |
| | N | 15 | 87% | 87% | 69% | 67% |
| **Lizard** | E | 8 | 100% | 100% | 12% | 10% |
| | N | 10 | 100% | 100% | 100% | 100% |

The table separates failure into four patterns:

1. **Retrieval-gate problem:** low vg-sel means Gemma picked the wrong bucket. v1
   hard-filters search by visual group, so the true species is excluded before synthesis
   even starts. Fix: softer or fallback visual-group routing.
   - *Small quadruped mammal*: N vg-sel 4%, retrieval 4% → species-ok 4%. Almost never
     routed correctly; the one image where it was, Gemma picked correctly (synth|surf 100%).
   - *Flying bird*: N vg-sel 30%, species-ok 35%. Two-thirds of failures never reach the search.
   - *Palm tree / Mangrove / Vine & climber*: vg-sel 0% in both runs. These groups are blocked at routing.

2. **Synthesis problem:** high vg-sel and high retrieval but lower species-ok means the
   correct bucket and true candidate are available, yet Gemma still picks wrong. Fix:
   better candidate selection or reranking, not visual-group routing.
   - *Turtle & tortoise*: N vg-sel/retrieval 100%, synth|surf **40%**, species-ok 40%.
     This is pure synthesis failure; routing is perfect, Gemma still misses 60% of cases.
   - *Primate*: N vg-sel 95%, retrieval 78%, synth|surf 70%, species-ok 55%. This is mostly a
     synthesis bottleneck, not a routing one.
   - *Mollusk & marine invertebrate*: N vg-sel 87%, retrieval 87%, synth|surf 69%, species-ok 67%.

3. **Both problems:** moderate vg-sel, lower retrieval, and low species-ok means routing
   and synthesis are both weak. Fix: needs both improvements.
   - *Tall broadleaf tree*: N vg-sel 57%, retrieval 43%, synth|surf 46%, species-ok 23%
     because routing fails on 43% of images, and even when retrieved synthesis only converts 46%.
   - *Marine fish*: N vg-sel 51%, retrieval 46%, synth|surf 58%, species-ok 32%. Neither
     routing nor synthesis is reliable.

4. **Emulated vs native reveals parser artefacts:** where E and N diverge sharply on
   the same group, the emulated number was depressed by stalls, not real model failure.
   Always use N for app-like performance.
   - *Lizard*: E vg-sel 100%, E synth|surf **12%**, N species-ok **100%**. The bad
     emulated result was entirely stall artefact; once stalls are removed the model
     identifies lizards perfectly.
   - *Frog & toad* (E n=4) and *Shrub & bush* (E n=7): both show E synth|surf=100%,
     but the parseable n is too small to be meaningful. Those E numbers should not be trusted.

v1 does not have one failure mode. Each group needs a different fix:

| failure pattern | signal | fix |
| --- | --- | --- |
| Low vg-sel | routing | softer/fallback visual-group search |
| High vg-sel/retrieval, low species-ok | synthesis | better candidate reranking |
| Low/moderate vg-sel/retrieval and low species-ok | both | routing + synthesis |

---

## Pivot effectiveness

| # tool calls | E: n | E: species-ok | N: n | N: species-ok |
| --- | --: | --: | --: | --: |
| 1 | 230 | 24% | 260 | 39% |
| 2 | 12 | 8% | 64 | 34% |
| 3+ | 19 | 0% | 8 | 25% |

More passes correlate with lower accuracy in both runs. Native attempts far more pivots
(64 two-pass vs 12 emulated) because stalls no longer absorb the hard cases, but the
recovery rate remains negligible. The fix-and-pivot loop is not a meaningful accuracy
lever.

---

## Confidence & hedging

| stated confidence | E: n | E: correct | N: n | N: correct |
| --- | --: | --: | --: | --: |
| high | 75 | 40% | 156 | 52% |
| medium | 131 | 17% | 153 | 28% |
| low | 19 | 0% | 20 | 5% |

Hedged predictions ("spp.", "various"...): **41% emulated → 7% native**. The large drop
is entirely the stall / loop artefact collapsing, not improved decisiveness. The underlying
overconfidence pattern remains: "high" confidence is wrong roughly half the time in both
runs.

---

## External evidence

The web finding was: our Gemma failures match known VLM/VQA failure modes. It is not just a local bug or a Gemma-only issue.
```text
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                VLMs can infer scene/context from object cues, but object identity, scene, 
                         and coarse context predictions can be partially disconnected.
  source                 Contextual inference from single objects in Vision-Language models
                         https://arxiv.org/abs/2603.26731
  why it matters for us  Gemma may be classifying context instead of the organism. Example: 
                         underwater images drift to marine buckets; birds and small mammals drift to 
                         Primate.
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                LVLMs can describe images plausibly but still fail fine-grained visual
                         categorization.
  source                 Finer: Investigating and Enhancing Fine-Grained Visual Concept Recognition
                         in Large Vision Language Models
                         https://arxiv.org/abs/2402.16315
  why it matters for us  Gemma can say “fish”, “bird”, or “green plant”, but that does not mean it 
                         can choose the correct controlled visual_group or species.
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                Object hallucination is affected by class distribution, salience, 
                         frequency, and spurious correlations.
  source                 Multi-Object Hallucination in Vision-Language Models
                         https://arxiv.org/abs/2407.06192
  why it matters for us  Gemma’s wrong groups are not random. They collapse into attractive priors 
                         like Primate, Tall broadleaf tree, and Marine mammal.
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                Hallucination is worse for fine-grained object attributes than coarse object
                         existence.
  source                 H-POPE: Hierarchical Polling-based Probing Evaluation of Hallucinations in
                         Large Vision-Language Models
                         https://arxiv.org/abs/2411.04077
  why it matters for us  Our task is attribute-heavy and fine-grained. Gemma is not just detecting 
                         “animal vs plant”; it must bind visual traits to a controlled taxonomy.
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                Benchmark accuracy can overstate whether VLMs actually rely on fine-grained
                         visual evidence.
  source                 Seeing without Looking: Do Vision-Language Benchmarks Really Test Vision?
                         https://arxiv.org/abs/2605.22903
  why it matters for us  Even when Gemma gives confident visual explanations, its visualGroup may be
                         weakly grounded. Confidence alone is unsafe for routing.
─────────────────────────────────────────────────────────────────────────────────────────────────────
  finding                VQA models often rely on language priors and superficial correlations 
                         instead of image evidence.
  source                 Overcoming Language Priors in Visual Question Answering with Adversarial
                         Regularization
                         https://arxiv.org/abs/1810.03649
  why it matters for us  This supports the pattern where familiar labels get over-selected even when 
                         the image points elsewhere.
─────────────────────────────────────────────────────────────────────────────────────────────────────
```
The hard visual_group gate is fragile because it assumes Gemma’s first coarse visual label is reliable. The literature says that is exactly where VLMs are weak: fine-grained visual grounding, attribute binding, and prior-driven category selection. So the fix should not be “trust Gemma confidence more”; it should be deterministic retrieval design, like neighbor-expanded search with a candidate budget.

## Conclusion

**1. The hard visual_group gate is the single biggest lever. It accounts for 55% of failures.**

Bucket accuracy is only 53% (native). Because v1 filters the DB search strictly on
visual_group, a wrong coarse prediction completely blocks the true species before
fine-grained ID even begins. Groups like Small quadruped mammal (vg-sel 4%), Flying bird
(30%), and all plant groups (0% to 30%) are essentially retrieval-locked. This is not because the
model cannot describe them, but because the architecture hard-gates on a prediction the
model gets wrong half the time. Fix the gate, and you eliminate more than half the
failures immediately.

**2. Synthesis is a real, separate problem that persists even after routing is fixed.**

Groups with near-perfect routing still fail substantially: Turtle & tortoise
vg-sel/retrieval 100% → synth|surf only 40%. Primate vg-sel 95% → synth|surf 70%. The
look-alike problem is genuine. When the right candidates are in front of Gemma, it still
picks the wrong one roughly 30% to 60% of the time depending on the group. Fixing routing alone will
not get past roughly 60% to 70% on these groups.

**3. The native 37.7% is a pipeline architecture ceiling, not a model capability ceiling.**

The Lizard result makes this concrete: emulated synth|surf 12% → native species-ok 100%.
The model was not failing on lizards; the stall artefact was. More broadly, the
emulated/native gap (17% → 38%) was almost entirely tooling noise, not model improvement.
The true remaining failures are structural: a single coarse VG prediction used as a hard
search gate, single-pass synthesis with no reranking, and a fix-and-pivot loop that
doesn't recover missed species. These are architecture decisions, not model limitations.
