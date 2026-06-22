# Soft-gate follow-up analysis

## Artifacts

- Script: [`analyze_soft_gate_failures.py`](../../scripts/gemma-improve-detection/analyze_soft_gate_failures.py)
- Parent: [gemma4-soft-gate.md](gemma4-soft-gate.md) · source baseline: [gemma4-baseline-failure-analysis.md](gemma4-baseline-failure-analysis.md)

## What this is

The soft visual-group gate lifted **offline retrieval recall 47% → 87%**, but the
end-to-end native rerun only moved **species accuracy 37.7% → 48.2% (+10.5pp)**. Most of
the recovered retrieval did not convert. This analysis joins the three runs — baseline
native, offline soft-gate replay, and the full soft-gate rerun — to locate exactly where
the recovered retrieval leaks away and which neighbor edges are worth keeping. Each
section drills one step further toward an actionable next iteration.

Joined images: **332**. Net flips: **+54 gained, −19 regressed** (= +35 net, matching
125 → 160).

## 1. Recovered but not correct

Soft retrieval surfaced the true species, but Gemma still picked the wrong final species.
This is the synthesis leak, by group.

| true visual_group | n | surfaced | final correct | failed synthesis | failure rate when surfaced |
| --- | --: | --: | --: | --: | --: |
| Primate | 64 | 61 | 29 | 32 | 52.5% |
| Marine fish | 57 | 51 | 27 | 24 | 47.1% |
| Flying bird | 60 | 48 | 30 | 18 | 37.5% |
| Tall broadleaf tree | 30 | 25 | 11 | 14 | 56.0% |
| Small quadruped mammal | 24 | 21 | 11 | 10 | 47.6% |
| Shrub & bush | 10 | 9 | 2 | 7 | 77.8% |
| Turtle & tortoise | 10 | 10 | 4 | 6 | 60.0% |
| Mollusk & marine invertebrate | 15 | 15 | 9 | 6 | 40.0% |
| Mangrove | 10 | 8 | 3 | 5 | 62.5% |
| Vine & climber | 6 | 4 | 0 | 4 | 100.0% |
| Fern | 10 | 7 | 4 | 3 | 42.9% |
| Large quadruped mammal | 15 | 11 | 9 | 2 | 18.2% |
| Frog & toad | 5 | 5 | 4 | 1 | 20.0% |
| Palm tree | 6 | 4 | 4 | 0 | 0.0% |
| Lizard | 10 | 10 | 10 | 0 | 0.0% |

Main read: the largest remaining synthesis failures are Primate, Marine fish, Flying
bird, Tall broadleaf tree, and Small quadruped mammal. Soft routing fixed candidate
*availability*; Gemma still often picks a look-alike.

## 2. Baseline vs soft-gate flips

| flip bucket | count |
| --- | --: |
| baseline wrong → soft correct | 54 |
| baseline correct → soft wrong | 19 |
| both correct | 106 |
| both wrong | 153 |

### Positive flips by group

| visual_group | count |
| --- | --: |
| Flying bird | 17 |
| Marine fish | 11 |
| Small quadruped mammal | 10 |
| Tall broadleaf tree | 5 |
| Palm tree | 4 |
| Mangrove | 3 |
| Primate | 2 |
| Frog & toad | 1 |
| Fern | 1 |

### Regressions by group

| visual_group | count |
| --- | --: |
| Primate | 8 |
| Flying bird | 7 |
| Mollusk & marine invertebrate | 1 |
| Marine fish | 1 |
| Shrub & bush | 1 |
| Tall broadleaf tree | 1 |

### Regression cause

What actually went wrong in the cases the baseline got right and the soft gate lost:

| cause | count |
| --- | --: |
| within-group congener (right group, wrong species) | 14 |
| neighbor distractor (right group, lost to an injected neighbor) | 3 |
| mis-routed (predicted group ≠ true) | 1 |
| other | 1 |

Main read: the soft gate creates far more wins than losses (+54 / −19), and — correcting
the obvious hypothesis — the losses are **not** a neighbor-distractor tax. **14 of 19
regressions are within-group congener errors**: right group, wrong species. The larger
predicted-group budget (top-15 vs top-5) puts more same-group look-alikes in front of
Gemma, and the reranker doesn't float the true one to the top. Only 3 regressions are
genuine neighbor distractors. The neighbor edges are nearly innocent (see §6).

## 3. Candidate-rank sensitivity

Soft accuracy as a function of where the true species ranked in the candidate list
**Gemma actually saw in the soft run** (replay of the soft run's own first tool call, so
rank and outcome come from the same run).

| true species rank in soft candidates | n | soft correct | soft accuracy |
| --- | --: | --: | --: |
| rank 1 | 148 | 127 | 85.8% |
| rank 2-5 | 97 | 26 | 26.8% |
| rank 6-10 | 33 | 3 | 9.1% |
| rank 11+ | 11 | 1 | 9.1% |
| not surfaced | 43 | 3 | 7.0% |

Main read: Gemma succeeds when retrieval ranks the true species first (~86%) and falls off
a cliff the moment it doesn't (27% at rank 2–5, single digits below). Gemma faithfully
anchors on rank 1; the failure is the reranker burying the true species. The next lever is
**reranking**, not wider recall.

## 4. Neighbor contribution (retrieval)

Cases missed by hard_top5 but recovered by soft_neighbors — which edge surfaced them.

| predicted → recovered true group | recovered cases |
| --- | --: |
| Primate → Flying bird | 25 |
| Primate → Small quadruped mammal | 20 |
| Marine mammal → Marine fish | 12 |
| Primate → Primate (larger predicted-group budget) | 11 |
| Mollusk & marine invertebrate → Marine fish | 10 |
| Shrub & bush → Tall broadleaf tree | 8 |
| Tall broadleaf tree → Shrub & bush | 7 |
| Waterfowl → Flying bird | 5 |
| Shrub & bush → Mangrove | 5 |
| Tall broadleaf tree → Palm tree | 4 |
| Tall broadleaf tree → Vine & climber | 4 |
| Tall broadleaf tree → Tall broadleaf tree (larger predicted-group budget) | 4 |
| Tall broadleaf tree → Fern | 4 |
| Lizard → Frog & toad | 3 |
| Marine fish → Marine fish (larger predicted-group budget) | 3 |
| Ground herb → Mangrove | 3 |
| Aquatic plant → Mollusk & marine invertebrate | 2 |
| Flying bird → Flying bird (larger predicted-group budget) | 2 |

Main read: a few edges carry most of the recall gain (the Primate and marine edges). Some
recovery also comes purely from the larger predicted-group budget, not neighbor expansion.

## 5. Per-edge retrieval ablation

Retrieval recall lost if each edge is removed. **Retrieval-only** — it does not say whether
the edge helped end-to-end accuracy (that's §6).

| removed edge | recovered cases lost | recall without edge | recall loss |
| --- | --: | --: | --: |
| Primate → Flying bird | 25 | 79.5% | 7.5pp |
| Primate → Small quadruped mammal | 20 | 81.0% | 6.0pp |
| Marine mammal → Marine fish | 12 | 83.4% | 3.6pp |
| Primate → Primate (larger predicted-group budget) | 11 | 83.7% | 3.3pp |
| Mollusk & marine invertebrate → Marine fish | 10 | 84.0% | 3.0pp |
| Shrub & bush → Tall broadleaf tree | 8 | 84.6% | 2.4pp |
| Tall broadleaf tree → Shrub & bush | 7 | 84.9% | 2.1pp |
| Waterfowl → Flying bird | 5 | 85.5% | 1.5pp |
| Shrub & bush → Mangrove | 5 | 85.5% | 1.5pp |
| Tall broadleaf tree → Palm tree | 4 | 85.8% | 1.2pp |
| Tall broadleaf tree → Vine & climber | 4 | 85.8% | 1.2pp |
| Tall broadleaf tree → Tall broadleaf tree (larger predicted-group budget) | 4 | 85.8% | 1.2pp |
| Tall broadleaf tree → Fern | 4 | 85.8% | 1.2pp |
| Lizard → Frog & toad | 3 | 86.1% | 0.9pp |
| Marine fish → Marine fish (larger predicted-group budget) | 3 | 86.1% | 0.9pp |
| Ground herb → Mangrove | 3 | 86.1% | 0.9pp |
| Aquatic plant → Mollusk & marine invertebrate | 2 | 86.4% | 0.6pp |
| Flying bird → Flying bird (larger predicted-group budget) | 2 | 86.4% | 0.6pp |

Main read: a small number of edges carry most of the recall gain — but retrieval value
alone can't decide which to keep, because it ignores distractors. That's what §6 adds.

## 6. Net accuracy value per edge

The decision metric §5 can't give. For each neighbor edge `P → G`:

- **win** — true species is in group G, Gemma predicted P (only the edge surfaces it), and
  the final answer was correct. The edge earned an ID.
- **distractor loss** — routing was already correct (true group = predicted P), but Gemma's
  wrong final pick came from neighbor group G. The edge injected the distractor.
- **net = wins − losses.** Net ≤ 0 means the edge costs more than it earns and should be
  dropped or gated behind a low-confidence / out-of-vocab check on the predicted group.

| edge | wins | distractor losses | net | verdict |
| --- | --: | --: | --: | --- |
| Primate → Flying bird | 17 | 0 | +17 | keep |
| Primate → Small quadruped mammal | 10 | 0 | +10 | keep |
| Marine mammal → Marine fish | 6 | 0 | +6 | keep |
| Waterfowl → Flying bird | 5 | 0 | +5 | keep |
| Mollusk & marine invertebrate → Marine fish | 5 | 1 | +4 | keep |
| Tall broadleaf tree → Palm tree | 4 | 0 | +4 | keep |
| Shrub & bush → Tall broadleaf tree | 4 | 1 | +3 | keep |
| Ground herb → Mangrove | 3 | 0 | +3 | keep |
| Lizard → Frog & toad | 2 | 0 | +2 | keep |
| Aquatic plant → Mollusk & marine invertebrate | 1 | 0 | +1 | keep |
| Tall broadleaf tree → Shrub & bush | 1 | 0 | +1 | keep |
| Tall broadleaf tree → Fern | 1 | 2 | −1 | gate/drop |

Main read: only **4 distractor losses across every edge combined.** Nearly all edges are
net-positive; the lone exception is `Tall broadleaf tree → Fern` (−1, tiny n). The
distractor worry was misplaced — the edges are almost pure upside.

## Conclusion

**1. The reranker is the single biggest lever.** Soft accuracy is **85.8%** when the true
species is rank 1 but collapses to **26.8%** at rank 2–5 and near zero below (§3). Gemma
faithfully anchors on rank 1; the failure is the weighted-Dice reranker burying the true
species, not the model refusing to reason. Getting more true species to rank 1 is the
highest-value next change, and it is offline-testable (no model rerun).

**2. Neighbor expansion is almost pure upside — keep it.** Across every edge there are only
**4 distractor losses** total (§6); nearly all edges are net-positive, with at most
`Tall broadleaf tree → Fern` slightly negative. Gating expansion would buy almost nothing —
the earlier worry that the Primate edges inject distractors is **not** what the data shows.

**3. The regressions are congener confusion, not the neighbor edges.** Of the 19
regressions, **14 are within-group congener errors** (right group, wrong species) versus
only 3 neighbor distractors (§2). The soft gate's larger predicted-group budget (top-15 vs
top-5) surfaces more same-group look-alikes, and the reranker doesn't float the true one
up — so this is the **same reranker problem as §1**, seen from the regression side. The fix
is a stronger within-group reranker (and possibly a tighter predicted-group budget), not
gating neighbor expansion.

**Net:** one lever dominates — **rerank so the true species reaches rank 1**, especially
among same-group congeners. That converts the unrecovered retrieval (§3) and erases most
regressions (§2) at once. Neighbor expansion stays on as-is; optionally drop the lone
net-negative edge `Tall broadleaf tree → Fern`.

## Notes

- §3 rank is from the soft run's own first tool call, so rank and outcome are from the same
  run. Multi-pass images are scored on the first call's candidate list (an approximation).
- §4/§5 are retrieval-only and use the offline replay (baseline tool-call traits).
- §6 attributes a win/loss only in the clean cases (edge-surfaced correct; or
  correctly-routed group lost to a neighbor distractor); ambiguous mis-routings are not
  charged to any edge.

## Next development

Recommended order:

1. Run offline reranker ablation first to make more true species reach rank 1.
2. Then run the candidate-presentation A/B to see whether Gemma can better use candidates
   when the true species is not first.

### Reranker ablation

The next implementation task is offline reranker ablation. It should answer one question:

```text
Which ranking rule puts the true species at rank 1 most often without destroying recall?
```

Use the existing soft-gate candidate sets. No Gemma run is needed for this step.

Primary metric:

| metric | why |
| --- | --- |
| true species surfaced | must not reduce recall too much |
| true species rank 1 | primary success metric |
| MRR | captures rank movement below top-1 |
| rank 1 by visual_group | shows where the variant helps or hurts |
| congener rank 1 | tests same-genus/species look-alike failures |
| baseline rank1 → variant not-rank1 | regression risk |
| baseline not-rank1 → variant rank1 | gain |

Variants to test:

| variant | idea |
| --- | --- |
| current | existing weighted visual Dice + taxonomy boost |
| taxonomy_x2 / taxonomy_x4 | increase family/genus boost when Gemma gives tax hints |
| genus_first | if `taxGenus` exists, rank same-genus candidates first |
| distinctive_pattern_heavy | increase `distinctive_marks` and `pattern`, reduce generic color dependence |
| color_downweighted | reduce color weight because generic color causes plant/fish collisions |
| group_bonus_predicted_1 | add a small bonus for candidates from the predicted group |
| neighbor_penalty_1 | add a small penalty for neighbor-group candidates |
| text_similarity | compare candidate `visual_features` against Gemma's observed traits with token/BM25-style scoring |

Recommended first ablation set:

1. `current`
2. `taxonomy_x2`
3. `taxonomy_x4`
4. `genus_first`
5. `distinctive_pattern_heavy`
6. `color_downweighted`
7. `group_bonus_predicted_1`
8. `neighbor_penalty_1`
9. `text_similarity`

Output table:

| variant | recall | rank1 | MRR | rank1 gains | rank1 losses | congener rank1 | notes |
| --- | --: | --: | --: | --: | --: | --: | --- |

Decision rule:

```text
Pick the variant with the highest true-species rank1 rate,
while keeping recall within 1pp of current soft recall
and keeping rank1 regressions lower than rank1 gains.
```

The winner is not simply the highest MRR. The useful winner is the one that moves the
most true species into rank 1 while keeping recall stable.

### Candidate presentation ablation

Gemma currently sees the retrieval confidence score and the candidate rank. The tool
formatter returns candidates in this shape:

```text
1. Common name (Latin name) — confidence 73% — visual features...
```

That means Gemma sees rank, scientific name, common name, confidence %, and visual
features. Since §3 shows Gemma anchors strongly on rank 1, it may also be anchoring on
the confidence score even though the score is only a weighted-Dice retrieval score, not a
calibrated biological probability.

Test candidate-display variants:

| variant | candidate display |
| --- | --- |
| current | rank + confidence + visual traits |
| no-confidence | rank + visual traits, no confidence % |
| no-rank | unnumbered candidates, no confidence % |
| randomized-order | shuffled candidates, no confidence %, explicit instruction that order is arbitrary |

Prompt instruction to test:

```text
The candidate order is not a confidence ranking. Do not assume the first candidate is best.
Compare every candidate against the image evidence and choose the species whose visual traits best match.
```

Expected signal:

- If rank/confidence anchoring is causing errors, `no-confidence` or `no-rank` should
  improve the rank 2-5 bucket.
- It may hurt cases where rank 1 is already correct, so measure total species top-1 and
  the rank-bucket deltas together.
- This requires an end-to-end Gemma run because it changes synthesis behavior, not
  retrieval.
