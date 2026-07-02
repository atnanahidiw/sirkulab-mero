# Soft visual-group gate — recoverable routing

The native baseline analysis found that **wrong `visual_group` bucket causes 55% of
failures**: v1 hard-filters the DB search on Gemma's first predicted group, so one wrong
coarse call excludes the true species before fine-grained ID begins. The fix is not to
drop the group narrowing (it keeps the candidate list small enough that Gemma's context
isn't swamped) but to make the gate **recoverable** — search the predicted group plus a
few inverse-confusion neighbors, with per-group budgets so the total stays bounded.

This doc reports two tests, in order:

1. **Offline counterfactual** — replay every native tool call, re-run the search under
   different gate policies, and measure whether the true species *reaches Gemma's
   candidate list* (retrieval recall). Isolates the retrieval gate from synthesis.
2. **End-to-end A/B** — actually re-run Gemma natively with the expanded search tool, and
   measure whether the recall gain converts into species accuracy.

> **Headline:** retrieval recall jumps **47% → 87%** offline, but end-to-end species
> accuracy only rises **37.7% → 48.2% (+10.5pp)**. The gate fix is real and worth
> shipping, but synthesis eats most of the recovered retrieval — exactly the separate
> bottleneck the failure analysis predicted.

## Policies compared

| mode | what it does |
| --- | --- |
| **hard_top5** | current production gate — first predicted group only, top 5 |
| **hard_top15** | same single group, larger budget (isolates budget vs routing) |
| **soft_neighbors** | predicted group + inverse-confusion neighbors, budgeted |
| **oracle_top15** | true group only — the routing ceiling |

Neighbor map (predicted group → groups to *also* search; direction is
predicted→recover, derived from the native confusion matrix):

```
Primate                        → Flying bird, Small quadruped mammal
Tall broadleaf tree            → Fern, Palm tree, Vine & climber, Shrub & bush
Marine mammal                  → Marine fish
Mollusk & marine invertebrate  → Marine fish
Shrub & bush                   → Mangrove, Tall broadleaf tree
Ground herb                    → Mangrove
Waterfowl                      → Flying bird
Lizard                         → Frog & toad
Aquatic plant                  → Mollusk & marine invertebrate
```

Budgets: predicted group 15, neighbors 8 / 5 / 3 / 3 / 3, capped at 35 total.

## Result — retrieval recall

| mode | true species surfaced | recall | avg candidates |
| --- | --: | --: | --: |
| hard_top5 (production) | 157 / 332 | **47.3%** | 3.6 |
| hard_top15 | 177 / 332 | 53.3% | 6.9 |
| **soft_neighbors** | 289 / 332 | **87.0%** | 13.3 |
| oracle_top15 | 331 / 332 | 99.7% | 7.6 |

- **+39.7pp recall** over production (47.3% → 87.0%), recovering **132 cases**.
- **0 cases lost** — soft is a superset of the predicted group, so it can only add.
- Context stays small: **13.3 avg candidates** vs the 35 cap (production was 3.6).
- Enlarging the budget alone (hard_top15) buys only +6pp — the gain is **routing
  recovery, not budget**.

## Recall gain by visual group

Ordered by cases recovered. `hard` = hard_top5, `soft` = soft_neighbors,
`oracle` = oracle_top15.

| true visual_group | n | hard | soft | oracle | recovered |
| --- | --: | --: | --: | --: | --: |
| Flying bird | 60 | 26.7% | 80.0% | 98.3% | 32 |
| Marine fish | 57 | 45.6% | 89.5% | 100% | 25 |
| Small quadruped mammal | 24 | 4.2% | 87.5% | 100% | 20 |
| Tall broadleaf tree | 30 | 43.3% | 83.3% | 100% | 12 |
| Primate | 64 | 78.1% | 95.3% | 100% | 11 |
| Mangrove | 10 | 0.0% | 80.0% | 100% | 8 |
| Shrub & bush | 10 | 20.0% | 90.0% | 100% | 7 |
| Palm tree | 6 | 0.0% | 66.7% | 100% | 4 |
| Vine & climber | 6 | 0.0% | 66.7% | 100% | 4 |
| Fern | 10 | 30.0% | 70.0% | 100% | 4 |
| Frog & toad | 5 | 40.0% | 100% | 100% | 3 |
| Mollusk & marine invertebrate | 15 | 86.7% | 100% | 100% | 2 |
| Large quadruped mammal | 15 | 73.3% | 73.3% | 100% | 0 |
| Lizard | 10 | 100% | 100% | 100% | 0 |
| Turtle & tortoise | 10 | 100% | 100% | 100% | 0 |

The groups the baseline analysis flagged as retrieval-gated are exactly the ones that
recover most: Small quadruped mammal 4%→88%, Mangrove 0%→80%, Flying bird 27%→80%.

## End-to-end result (native re-run with the expanded tool)

The offline test only proves the answer reaches the candidate list. To see whether that
converts to accuracy, the same Gemma 4 E2B native pipeline was re-run on all 332 images
with the search tool swapped for the soft-gate version (predicted group + budgeted
neighbors).

| pipeline | species top-1 | genus |
| --- | --: | --: |
| hard-gate baseline (v1) | 37.7% (125) | 41.3% |
| **soft-gate (neighbor expansion)** | **48.2% (160)** | **52.1%** |
| **delta** | **+10.5pp** | **+10.8pp** |

**Retrieval recall rose +40pp (47%→87%) but species accuracy only +10.5pp.** Synthesis
absorbed roughly three-quarters of the recovered retrieval: putting the true species on
the table is necessary but far from sufficient — Gemma still has to pick it out of a now
larger candidate list, and often picks a look-alike. This is the synthesis bottleneck the
[failure analysis](gemma4-baseline-failure-analysis.md) flagged as the separate, residual
problem.

### Where the gain came from — and where it cost

Per group, baseline species-ok vs soft-gate species-ok, alongside the offline retrieval
recall. Sorted by accuracy delta.

| visual_group | n | base sp% | soft retrieval% | soft sp% | Δ sp |
| --- | --: | --: | --: | --: | --: |
| Palm tree | 6 | 0% | 67% | 67% | **+67** |
| Small quadruped mammal | 24 | 4% | 88% | 46% | **+42** |
| Mangrove | 10 | 0% | 80% | 30% | **+30** |
| Frog & toad | 5 | 60% | 100% | 80% | +20 |
| Marine fish | 57 | 32% | 90% | 49% | +18 |
| Flying bird | 60 | 35% | 80% | 52% | +17 |
| Tall broadleaf tree | 30 | 23% | 83% | 37% | +13 |
| Fern | 10 | 40% | 70% | 50% | +10 |
| Vine & climber | 6 | 0% | 67% | 0% | +0 |
| Large quadruped mammal | 15 | 60% | 73% | 60% | +0 |
| Lizard | 10 | 100% | 100% | 100% | +0 |
| Turtle & tortoise | 10 | 40% | 100% | 40% | +0 |
| Mollusk & marine invertebrate | 15 | 67% | 100% | 60% | −7 |
| Primate | 64 | 55% | 95% | 45% | **−9** |
| Shrub & bush | 10 | 30% | 90% | 20% | −10 |

Three patterns:

- **Retrieval-gated groups convert well.** Palm tree, Small quadruped mammal, Mangrove,
  Marine fish, Flying bird — the groups that were blocked at routing — account for nearly
  all the gain. This is the soft gate working as intended.
- **Expansion has a real cost: distractors.** **Primate regresses −9pp on n=64
  (~6 images)** — the only material regression. When Gemma already routes a group
  correctly (Primate retrieval was 95% under hard-gate), adding neighbor candidates
  (Flying bird, Small quadruped mammal) injects look-alikes that pull synthesis off the
  true answer. Shrub & bush (−10pp) and Mollusk (−7pp) are 1-image swings on n=10–15, i.e.
  noise; Primate is the one to take seriously.
- **High retrieval, zero conversion.** Vine & climber reaches 67% retrieval but **still
  0% species-ok** — synthesis never picks it. Turtle & tortoise: 100% retrieval, 40%
  accuracy unchanged. These are pure synthesis failures that no routing change can fix.

The net is positive (+10.5pp), but the Primate regression motivates the next refinement:
**expand conditionally**, not always — e.g. only widen when the predicted group is
low-confidence or out-of-vocab, so well-routed groups don't pay the distractor tax.

## Caveats

1. **This is an in-sample number.** The neighbor map was built from this same native
   run's confusion matrix, so 87% is fit-to-data. It proves the *mechanism* (a
   recoverable gate beats a hard gate) — not that the exact percentage holds on unseen
   species.

2. **The soft → oracle gap (87% → 99.7%) is two separate things:**
   - **Missing symmetric / real edges** the map doesn't yet have — e.g.
     `Small quadruped mammal` isn't even a key (so Large↔Small quadruped mammal
     confusions don't recover), `Aroid & giant herb → Palm tree`, `Grass & bamboo → Fern`.
   - **Out-of-vocab predictions** — Gemma emits non-schema groups (`Bird`, `Plant`,
     `Snake`, `Mammal`, and one literal "None of the provided visual groups are suitable
     for a skull…"). No neighbor map can route these; they need a **closed-list
     validator** that snaps the predicted group to the nearest schema value *before*
     expansion.

3. **One case is unrecoverable even with the oracle group:** *Acridotheres javanicus* —
   Gemma described it as "Tall broadleaf tree", and its traits are so far off that even
   searching the true Flying-bird group with those traits won't surface it. That's a
   synthesis/description failure, not routing.

## Faithfulness

The replay's `hard_top5` reproduces the production `_run_search` **exactly** on all 332
cases (0 mismatches), so the baseline column is a true control, not an approximation.

## Artifacts

- Offline script: [`eval_soft_visual_group_gate.py`](../../../scripts/gemma-improve-detection/eval_soft_visual_group_gate.py)
  · outputs `scripts/gemma-improve-detection/outputs/gemma4_soft_visual_group_gate.{json,jsonl,md}`
- End-to-end script: [`eval_gemma4_soft_gate.py`](../../../scripts/gemma-improve-detection/eval_gemma4_soft_gate.py)
  · outputs `scripts/gemma-improve-detection/outputs/gemma4_soft_gate.{json,jsonl}`
- Source failure analysis: [gemma4-baseline-failure-analysis.md](gemma4-baseline-failure-analysis.md)
