# Candidate Rank Sensitivity in Gemma 4 Species Identification

## Summary

This experiment is a byproduct of the earlier Gemma 4 species-identification failure analysis. The earlier work already showed that candidate handling matters, so here we isolate a narrower question: does the final species pick change when we reshuffle the same candidate set? To keep that signal clean, we use far-separated candidates rather than look-alike-heavy ones. The setup keeps the image, candidate identity, model, and prompt format fixed, while shuffling only the candidate order and removing confidence scores from presentation. If answers change across shuffles, then list position is influencing the choice even when the options are diverse.

## Motivation

Mero presents Gemma 4 with a ranked candidate list from local retrieval. That makes the ranking itself part of the product behavior, so we want to know whether order alone can sway the answer once the candidate identities are fixed. The follow-on uses far-separated options on purpose, because that gives a cleaner read on position bias than a list full of look-alikes.

The reason is that the earlier Gemma 4 soft-gate follow-up showed the soft-gate problem was mostly *not* that the extra neighbor groups were bad. The bigger issue was that, when the true species was already in the right broad group, Gemma still often picked a different species from the same group. In other words, the model was getting tripped up by within-group look-alikes, and the reranker was not placing the true one at the top.

So for this rank-sensitivity note, we want to test something narrower:

- does order alone nudge the answer?
- not whether the model can tell apart very similar species
- not whether the reranker can sort look-alikes correctly

If we used look-alike-heavy candidates, then a changed answer could be caused by confusion between similar species rather than by list order. That would muddy the result. The clean idea is to use diverse, far-separated candidates so the only thing changing is position, which makes it easier to see whether ordering itself matters. That is the brittle behavior we care about here.

## Hypothesis

Candidate rank may affect the final prediction. If the same image and same candidate set produce different species answers after shuffling, then order is influencing the decision.

## Plan

1. Reframe the dataset around far-separated candidate lists so the test isolates order bias instead of look-alike confusion. The candidate set should still contain the true species, but the distractors should come from clearly different visual groups, so any answer flip is more likely to come from position than from similarity.
2. Tighten the frozen dataset so each example stores canonical ground-truth fields, cleaned candidate identities, and explicit skip reasons for unusable rows.
3. Fix correctness scoring in the evaluator to compare canonical scientific names first, then common-name aliases only when needed.
4. Add a small progress indicator to the evaluator so long CPU runs are easier to monitor.
5. Update the summary to report flip rates, rank-1 bias, and per-example stability more clearly.
6. Keep the package runnable with the repo’s documented `uv run --python .venv-export/bin/python ...` workflow and verify with a smoke test before any full sweep.

## Methodology

We built the frozen evaluation set from the repo’s existing Gemma 4 baseline outputs and the species database, then filtered the rows so that the true species was present in the candidate list. For the main experiment, we kept the candidate set deliberately far-separated: distractors were selected from visually and taxonomically distant species so that the model was not being asked to resolve a tight cluster of look-alikes. That choice was important because the earlier soft-gate follow-up already suggested that same-group confusions and reranking mistakes are a separate failure mode. Here, the goal was to make the rank test cleaner by reducing that confound.

Each frozen example preserves the same image, the same candidate identities, and the same decoding setup. The only variable we changed during evaluation was the candidate order. For every example, we ran one original-order pass and then five shuffled passes. Confidence scores were removed before the prompt was shown, so the model saw the candidate names without an extra confidence cue that could influence selection. The evaluator compared the model’s answer after each shuffle against the original-order answer, and it also checked accuracy against the hidden ground-truth species when that label was available.

The robustness run used the largest eligible far-separated set available in the current baseline corpus: 125 examples. That is the present ceiling for this construction unless the source pool is expanded, so the follow-up analysis is bounded by the data we have rather than by a chosen pass count. This is the set reported below.

## Results

The completed robustness run used 125 examples with one original-order pass plus one shuffled pass and one reverse-order pass per example, which produced 250 non-original evaluation rows. We include reverse order because it is a stronger check for primacy and recency effects than a single random shuffle: if the model only reacts to the top or bottom of the list, reversing the list should expose that. Changing only the presentation order moved the answer in 8 of the 125 examples, for an average answer-change rate of 5.2%. In other words, the model kept the original answer in 94.8% of non-original trials.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 125 | This is the full robustness set, not just a pilot sweep |
| Non-original trial rows | 250 | Two order perturbations per example, so the comparison is broad enough to be meaningful |
| Answer-changed rate | 5.2% | Only a small share of perturbations changed the final answer |
| Original-answer retained rate | 94.8% | Most answers survived the order change unchanged |
| Unique answers per image, mean | 1.08 | Across the whole run, the model rarely wandered into many different species for the same image |
| Unique answers per image, median | 1.00 | For a typical image, the answer never changed at all |
| First candidate selected rate | 19.2% | The top slot did not dominate selection, even though the model saw the list in rank order |
| Rank-1 prediction match rate | 98.8% | When the model chose the first candidate, it almost always truly meant that candidate rather than a nearby alias |
| Accuracy, original order | 95.2% | Baseline correctness before any order perturbation |
| Accuracy, shuffled/reversed | 95.6% | Accuracy barely moved after the list was reordered |
| Examples with any flip | 8 | Only a small subset of images were order-sensitive at all |

Taken together, the metrics say the same thing from a few angles. A 5.2% change rate is low, but not zero, so order has a measurable effect without making the model broadly brittle. The mean unique-answer count of 1.08 and median of 1.00 show that most images never changed answer at all, and the instability was concentrated in a small number of examples rather than spread evenly across the set.

The accuracy row helps interpret the result correctly. Accuracy was 95.2% in the original order and 95.6% after shuffling and reversing, which is essentially flat. So the perturbation is changing a few labels, but it is not degrading the model overall. This is mostly a stability question, not a correctness collapse.

The directional counts reinforce that the model was mostly stable rather than erratic. Most examples stayed correct in both conditions, a few moved from wrong to correct, and only 2 moved from correct to wrong. That is the clearest caution: order can still knock a right answer off track, but only on a small subset of cases.

| Direction | Count |
|---|---:|
| Correct in both original and perturbed order | 117 |
| Wrong to correct after perturbation | 4 |
| Correct to wrong after perturbation | 2 |
| Wrong in both conditions | 2 |

The 95.2% versus 95.6% split shows the order effect is not simply making the model worse. The main effect is label instability, not a performance drop.

The eight flipped examples are informative because they show that order can still perturb the outcome even when candidates are far apart. The table below shows where the original answer and the changed answer diverged.

| Example | Original answer | Changed trial result | Insight |
|---|---|---|---|
| `artocarpus_altilis_1.jpg` | `Artocarpus altilis` | `Trachypithecus cristatus` under shuffle | A correct plant answer drifted to a primate when the list moved |
| `trachypithecus_auratus_a.jpg` | `Avicennia germinans` | `Trachypithecus auratus` under reverse | The reversed list recovered the correct species from an initially wrong guess |
| `tectona_grandis_1.jpg` | `Maxomys whiteheadi` | `Jati [Tectona grandis]` under reverse | Reordering exposed that the model was already in a brittle state on this example |
| `tectona_grandis_2.jpg` | `Isopora palifera` | `Tectona grandis` under shuffle | The same image could move from a coral to the correct tree depending on order |
| `koordersiodendron_pinnatum_1.jpg` | `Koordersiodendron pinnatum` | `Ailurops ursinus` under shuffle and `Eretmochelys imbricata` under reverse | This is the clearest multi-way instability case in the set |
| `koordersiodendron_pinnatum_b.jpg` | `Amugis [Koordersiodendron pinnatum]` | `N/A` under shuffle and `Amugis` under reverse | One perturbation exposed parsing fragility rather than a clean species switch |
| `pterocarpus_indicus_1.jpg` | `Chelonia mydas` | `Pterocarpus indicus` under both shuffle and reverse | Both perturbations moved the answer toward the target species, showing that order can also help |
| `ardisia_elliptica_b.jpg` | `Atelopus varius` | `Ardisia elliptica` under both shuffle and reverse | The model consistently shifted to the correct species once the order changed |

The point of the example table is that the flips are not all the same kind of mistake. Some are classic order sensitivity, some are recovery cases, and some are brittle multi-way confusions. The examples are also spread across different taxonomic corners, so this does not look like a one-off quirk from a single family or visual group.

## Conclusion

The main conclusion is that Gemma 4 shows a real but relatively small order effect in this far-separated species-identification setup. Candidate order is not irrelevant, because the model did flip on a small subset of examples and did so in a way that is not random. However, the effect is clearly secondary: the answer-change rate is low, the accuracy gap between original and perturbed order is tiny, and most examples remain stable across the shuffled and reversed presentations. That means order can nudge the final pick, but it does not look like the main driver of species choice in this regime.

For Mero, that is a useful result. It says candidate ranking should still be treated as part of the product behavior, but in this cleaner far-separated setting the larger risk is still the underlying retrieval and synthesis quality rather than the order of the list alone. The result also fits the related work better than it contradicts it: the prior MCQA and VLM position-bias papers show that order sensitivity is real in general, while our experiment shows that when the candidate set is deliberately diverse, the position effect is measurable but modest. That makes our setup a cleaner estimate of pure rank sensitivity rather than a test entangled with look-alike confusion.

## Relation to prior work

The closest prior work is on multiple-choice vision-language selection bias and position bias, not LLM judges or recommendation ranking. In particular, *Benchmarking and Mitigating MCQA Selection Bias of Large Vision-Language Models* (EMNLP 2025) studies option-order and token-position effects in MCQA, and *Mitigating Easy Option Bias in Multiple-Choice Question Answering* studies how VLMs can exploit shortcut cues from the option set itself. Those papers show that VLMs can be sensitive to option order, token choice, and task difficulty, which is broadly consistent with what we are testing here.

| Work | What it tests | How this experiment differs |
|---|---|---|
| *Benchmarking and Mitigating MCQA Selection Bias of Large Vision-Language Models* | Option-order and token-position bias in MCQA | This experiment uses image-based species identification rather than text-only multiple choice, and it keeps the candidate identities fixed while changing only order |
| *Mitigating Easy Option Bias in Multiple-Choice Question Answering* | Shortcut cues from the option set itself | This experiment removes confidence scores from the prompt and uses far-separated candidates to reduce similarity confounds |
| This candidate-rank study | Pure rank sensitivity under far-separated candidates | It asks whether order still matters when the options are intentionally diverse and only the presentation order changes |

Our note is narrower: instead of asking whether option order can matter in general, we ask whether order still matters when the candidate set is intentionally far-separated. That makes our setup cleaner for isolating pure rank sensitivity, because it removes much of the look-alike confounding that can mix similarity effects into the order effect. In that sense, our result is not a contradiction of the related work; it is a more controlled measurement of the same underlying vulnerability in a species-identification setting.

## Limitations

This is a behavioral evaluation, not a full mechanistic interpretability study. It can show that rank order affects the output, but it cannot by itself explain *why* the effect occurs inside the model. It also depends on the quality of the frozen candidate set and on how faithfully the prompt reflects Mero’s real usage. Because the candidate set was intentionally far-separated, this result should be read as a test of **order bias under diverse options**, not as a general statement about look-alike-heavy candidate lists.

## Next Steps

- Confidence score sensitivity
- Candidate count sensitivity
- Explanation faithfulness tests
