# 05b · Implementation — species retrieval & open-set (covering all species)

**Status:** 🔬 measured, not yet wired · **Owns:** `scripts/eval_species_retrieval.py`
**Continues:** [05](05_implementation-accuracy-tuning.md) (which got `visual_group` to 96% via prototypes). This stage targets the **species** level and the **open-world** requirement.

## Why
Two gaps remained after stage 05:
1. **Species retrieval rank-1 was 35.5%** — because identification is
   `image → noisy text traits → FTS5/Dice string overlap → species`, which throws
   away the DINO embedding. The descriptive traits are only ~8–14% accurate.
2. **"Cover all species, not just threatened."** A child photographs a house cat,
   not one of the 64 endangered species. The app must identify the curated set
   precisely *and* gracefully handle everything else.

## Architecture — two tiers + a router
You can't prototype "all species" (~2.1 M described; can't get images for all).
The answer is tiered, with the open-world half already in the pipeline:

```
photo → DINO embedding
  ├─ Tier 1: nearest species PROTOTYPE (curated set, image↔image)
  │     score ≥ τ ? → curated species (+ endangered status from DB)
  │                 → below τ → OUT OF DISTRIBUTION ↓
  └─ Tier 2 (open world): zero-shot visual_group + LLM world knowledge
        → names anything ("a domestic cat — not in the endangered database")
```

- **Tier 1 (prototypes)** covers the curated slice (the app's job) at high accuracy.
- **Open-set router** = a threshold on the prototype similarity → routes unknowns out.
- **Tier 2** is the open-vocabulary LLM + zero-shot path ([00_plan §10](00_plan.md)) — unbounded coverage, coarse/name-level, not DB-grounded.

`visual_group` still classifies *any* species (broad categories transfer), so even an unknown animal gets a sensible coarse identity.

## Result 1 — closed-set rank-1: **80.4%** ✅ (vs 35.5% today)
One DINO centroid per species (64 species, 4–8 images each), leave-one-out:

| matcher | rank-1 | rank-5 | MRR |
| --- | --- | --- | --- |
| **species prototypes, flat (LOO)** | **80.4%** | 96.4% | 0.875 |
| species prototypes, hierarchical (within predicted `visual_group`) | 78.6% | 96.1% | 0.862 |
| *text-trait retrieval (current shipped path)* | *19.6%* | *40.4%* | *0.295* |

- **4× the current rank-1**, squarely in the 70–90% goal; rank-5 96%.
- **Flat beats hierarchical at 64 species** — restricting to the predicted
  `visual_group` only *hurts* (a wrong vg, 2.7% of the time, excludes the true
  species). The hierarchy pays off at *large* scale (hundreds+ species/query);
  ship **flat** now, add the hierarchy as the DB grows.

## Result 2 — open-set (OOD) rejection: the harder half ⚠️
Leave-whole-species-out (treat held-out species as "unknown"), 5-fold:

| OOD scorer | AUROC | reject @ 90% known kept |
| --- | --- | --- |
| **`max − group median`** ← best | **0.824** | 57% |
| `max` (raw cosine) | 0.805 | 56% |
| `(max−group) + margin` | 0.760 | 55% |
| `margin (top1−top2)` | 0.594 | 16% |

- **Score-formula tuning gave little** (0.805 → 0.824). Per-group normalization
  helped marginally; **`margin` failed** — in fine-grained species the 2nd-nearest
  is also similar (two seahorses), so a *correct* match often has a small margin
  too. Fusing margin in hurt.
- **Context: this is the *worst-case* OOD test** — the "unknowns" are other
  *endangered species in the same visual groups* (near-OOD). The everyday case
  (a kid photographs a cat / pigeon / car — *far*-OOD) lands nowhere near any
  prototype and rejects far more cleanly. So 57% here is a conservative floor.

**Takeaway:** near-OOD isn't solvable by a better cosine threshold. The router
should be **good enough to send obvious non-curated subjects to Tier 2**, and
near-OOD (a non-DB endangered species) gets caught by the **LLM verify tier**:
`check_visual_evidence` + the model can reject "nearest curated species" when the
traits don't actually match.

## Scalability ("how many species")
- **Storage/compute is not the limit** — a prototype is one 768-d vector (~3 KB
  fp32). 1 k species ≈ 3 MB, 10 k ≈ 30 MB; retrieval is a sub-10 ms matvec.
- **The limit is reference-image availability** (the per-species cost) and
  **accuracy at scale** — keep accuracy by going hierarchical
  (`visual_group` → species-in-group) once the flat candidate set gets crowded.

## Next steps (not yet built)
1. **Build the shippable species-prototype asset** (same protobuf pattern as
   `visual_group_prototypes.pb`) + a `search_species_by_image` tool.
2. **Wire flat retrieval** as the primary candidate generator; keep text-trait
   search as a complement / fallback for species without reference images.
3. **OOD router**: ship `max − group median` with a per-group τ; route below-τ to
   the LLM/zero-shot tier.
4. **Catch near-OOD with `check_visual_evidence`** rather than the threshold alone.
5. **Far-OOD sanity check** — re-run with non-species images to confirm easy
   rejection (expected AUROC ≫ 0.82).
6. Optional rank-1 boosters: k-reciprocal re-ranking, local+global feature fusion.

## Scripts
- `eval_species_retrieval.py` ✅ — closed-set LOO rank-1 (flat + hierarchical) +
  open-set leave-species-out OOD across multiple scorers. Writes
  `data/processed/README_species_retrieval.md` + per-image JSONL.
