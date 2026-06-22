# Smaller-footprint pipeline — versions & rejected alternatives

On-device species ID under 1 GB, fine-grained, with a generative LLM as the
reasoning core. This folder tracks each architecture version and — importantly — the
approaches we **explored and rejected**, so we don't re-investigate them.

## Versions

| Version | What it is | Status |
| --- | --- | --- |
| [v1 — smaller-vlm](v1-smaller-vlm/) | one unified small on-device VLM | ❌ retired (runtime walls) |
| [v2 — clip-and-text-llm](v2-clip-and-text-llm/00_plan.md) | text-aligned image encoder (tool) + text LLM + SQLite | ✅ concluded; shipped baseline |
| [v3 — dense-text-match](v3-dense-text-match/00_plan.md) | dense patch↔text matching | ❌ probe failed ([01](v3-dense-text-match/01_implementation-q1-dense-probe.md)) |

## ❌ Rejected alternatives — do **not** re-propose in the next search

External approaches evaluated (latest research pass) against the wall above and dropped:

1. **Geographic / habitat priors** — narrow the candidate set by species range.
   *Parked, not a fix:* a range prior only makes a weak matcher *tolerable* by shrinking
   the candidate set; it doesn't improve the visual matching. Revisit only if a usable
   conformant matcher exists.
   — [Geographical Distribution for Zero-Shot Species Recognition (PMC)](https://pmc.ncbi.nlm.nih.gov/articles/PMC11200704/)
2. **Attribute-centric / part-aware reasoning** — per-part attributes (head colour, tail
   pattern) + attribute experts. Published numbers (~**15% @top-1 / 45% @top-10**) are
   *worse* than what we already have, and it needs reliable **part-level visual
   grounding** we don't have on-device (the same wall that killed v3-dense).
   — [Attribute-Centric Fine-Grained ZSL](https://arxiv.org/html/2512.12219v1) ·
   [Zero-Shot Bird Recognition from Field Guides](https://www.researchgate.net/publication/361107841_Zero-Shot_Bird_Species_Recognition_by_Learning_from_Field_Guides)

Also dismissed in the same pass as infeasible on-device: **test-time prompt tuning**
(backprop at inference — [TPT](https://azshue.github.io/TPT/)) and the **diffusion
classifier** (Stable-Diffusion-scale model — [Diffusion Classifier](https://diffusion-classifier.github.io/)).

## Where this leaves us

The conformant search is **exhausted** — no mechanism that respects §2 reaches usable
accuracy. The remaining decision is **§2 itself**:

- **Amend §2** — allow **few-shot image prototypes** (frozen-encoder centroids; *not* a
  trained classifier, so the original "overfit/rare-species" objection doesn't bite) as
  a **Tier-1** booster, with the conformant **text + LLM** path as **Tier-2** for species
  without images. The system still scales by DB rows; prototypes just lift accuracy where
  images exist. *(The only honest+usable configuration.)*
- **Accept low conformant accuracy** — ship the ~20–45% text path and lean on the LLM's
  best-effort reasoning.
