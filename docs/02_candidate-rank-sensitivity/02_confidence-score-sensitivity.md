# Confidence Score Sensitivity in Gemma 4 Species Identification

## Summary

This experiment is a follow-on to the earlier Gemma 4 species-identification failure analysis. The rank-sensitivity work asked whether list position matters when the candidate identities stay fixed. This note asks a narrower question: does the answer change when the same candidate list is shown with the same order but different confidence values attached to the candidates? If the prediction moves under that intervention, then confidence is not just metadata. It is part of the model’s decision context.

## Motivation

Mero surfaces a ranked candidate list to Gemma 4, and that list may also carry confidence values from retrieval. That matters because a confidence score can behave like a soft recommendation signal even when the candidate identities are unchanged. If the model reads those scores as evidence, then a noisy or miscalibrated backend can change the final answer without changing the underlying retrieval set.

The point of this experiment is to isolate that effect cleanly. We keep the image fixed, keep the candidate identities fixed, and keep the candidate order fixed. The only variable is the displayed confidence assignment. That gives us a direct read on whether confidence is influencing the model’s choice rather than just sitting in the prompt.

## Hypothesis

Candidate confidence may affect the final prediction. If the same image and same candidate set produce different species answers after confidence values are permuted, then confidence is influencing the decision.

## Methodology

We froze a set of baseline examples from the repo’s authoritative Gemma 4 outputs. Each frozen row preserves the image path, the ground-truth fields when available, and the original candidate list with confidence values intact. During evaluation, the model sees the same image and the same candidate identities in the same order, but the confidence values are shuffled across those candidates.

For each example, the evaluator runs one original-confidence trial and five confidence-permutation trials. The responses are parsed into canonical scientific/common-name fields when possible, and the evaluator records whether the answer matches the original run and whether it matches ground truth. That lets us separate three questions:

- does the answer change when only confidence moves?
- does the model tend to follow the highest displayed confidence?
- does the score perturbation improve or degrade correctness?

## Results

The completed sweep covered 119 frozen examples and produced 595 confidence-permutation trials, plus 119 original-confidence rows. The answer changed in 33.1% of the perturbed trials, so the original answer was retained in 66.9% of the cases. That is still a substantial effect, not a marginal one.

| Metric | Value | Why it matters |
|---|---:|---|
| Examples | 119 | This is the full frozen set used for the confidence-sensitivity sweep |
| Original rows | 119 | One baseline answer per example |
| Variant rows | 595 | Five confidence permutations per example |
| Answer-changed rate | 33.1% | Confidence changes the answer in a large minority of trials |
| Original-answer retained rate | 66.9% | The model is not fully unstable, but the answer is far from invariant |
| Unique answers per image, mean | 1.92 | The model often explores more than one answer for the same image |
| Unique answers per image, median | 2.00 | A typical image yields at least two distinct answers across the trials |
| Highest-confidence selected rate | 53.3% | The model frequently follows the top displayed score, but not always |
| Accuracy, original confidence display | 67.2% | Baseline correctness before score permutation |
| Accuracy, permuted confidence display | 48.4% | Correctness drops materially when confidence is reshuffled |
| Examples with any flip | 74 | Most examples show at least one changed answer |

The main signal is straightforward: confidence is not passive. A 33.1% change rate is high enough that the displayed scores are clearly part of the prompt contract from the model’s perspective. The mean unique-answer count of 1.92 and the median of 2.00 show that this is not just a one-off artifact in a few rows. The model often shifts between at least two candidate answers for the same image when the score assignment changes.

The accuracy change matters too. Original-order accuracy is 67.2%, while accuracy under permuted confidence drops to 48.4%. That means score permutation is not just moving the model between equally good options. It is often pushing it away from the correct species.

The directional counts point in the same direction. Most of the examples are either stable in both conditions or wrong in both conditions, but the important part is that confidence permutations almost never rescue a wrong answer and do frequently disturb a correct one.

| Direction | Count |
|---|---:|
| Correct in both original and variant order | 78 |
| Wrong in both conditions | 35 |
| Wrong to correct after permutation | 4 |
| Correct to wrong after permutation | 2 |

That asymmetry is the cautionary detail. Confidence can help the model lock onto a candidate, but in this run it more often acts as a destabilizer than as a corrective signal.

The flipped examples are especially useful because they show that the model is not simply reading the image and ignoring the score field. In several cases, the response jumps across unrelated candidates when the confidence assignment changes. A few representative cases:

| Example | Original answer | Changed trial(s) | Insight |
|---|---|---|---|
| `pongo_abelii_c.jpg` | `Pongo abelii` | `permute-04` -> `Macaca nigra` | The confidence shuffle moved the answer to a different primate candidate |
| `artocarpus_altilis_1.jpg` | `Amugis [Koordersiodendron pinnatum]` | `permute-02` -> `Eucalyptus urophylla`, `permute-03` -> `Vitex quinata` | The model drifted across unrelated plant candidates when the score assignment changed |
| `bolbometopon_muricatum_2.jpg` | `Bolbometopon muricatum` | multiple permutes -> `Mobula alfredi`, `Cheilinus undulatus`, `Carcharhinus melanopterus` | This is a strong example of score-driven instability across marine candidates |
| `aulacorhynchus_prasinus_c.jpg` | `Psittacara raptor` | multiple permutes -> `Crested Macaque`, `Cacatua galerita`, `Trachypithecus auratus`, `Nymphicus hollandicus` | Confidence display can dominate the prompt context badly enough to produce cross-group errors |

The example table is not meant to imply that every flip is the same failure mode. Some are within-group confusions, some are cross-group jumps, and some look like the model is latching onto whichever candidate has the most appealing score cue. The common thread is that confidence assignment is clearly influencing the output.

## Conclusion

The main conclusion is that Gemma 4 is materially sensitive to displayed confidence values in this species-identification setup. The effect is much larger than the rank-sensitivity effect described in the companion note: changing only the confidence assignment moved the answer in 33.1% of the perturbed trials and reduced accuracy from 67.2% to 48.4%. That makes confidence a real behavioral input, not just annotation.

For Mero, that means the retrieval backend’s confidence output should be treated as part of the user-facing prompt contract. If the scores are noisy, overconfident, or simply poorly calibrated, they can steer the final answer even when the candidate list itself is unchanged. This does not mean confidence is always harmful, but it does mean it is operationally meaningful and should be validated as carefully as ranking.

## Relation to Prior Work

The result fits the broader multiple-choice and VLM bias literature. Work on option-order bias and shortcut cues in multiple-choice vision-language tasks has already shown that models can use non-semantic presentation features as decision signals. This experiment extends that concern to candidate confidence values in an image-based species-identification workflow.

| Work | What it tests | How this experiment differs |
|---|---|---|
| *Benchmarking and Mitigating MCQA Selection Bias of Large Vision-Language Models* | Option-order and token-position bias in MCQA | This note keeps the candidate order fixed and changes only confidence values |
| *Mitigating Easy Option Bias in Multiple-Choice Question Answering* | Shortcut cues from the option set itself | Here the cue is not an easy/difficult option token but the displayed confidence attached to each candidate |
| This confidence-score study | Confidence sensitivity under fixed candidate identity and order | It isolates the effect of score display in a species-identification setting |

## Limitations

This is a behavioral evaluation, not a mechanistic explanation. It can show that confidence display matters, but it cannot by itself explain why the model uses it. It also depends on the specific frozen candidate set and the way the baseline scores were generated. The result should therefore be read as sensitivity to the displayed scores in this dataset, not as a universal calibration claim about all retrieval systems.

## Next Steps

- Compare confidence permutation against a confidence-flattening baseline
- Test whether confidence sensitivity is stronger on visually ambiguous groups
- Compare score sensitivity with rank sensitivity on the same frozen examples
- Add a follow-up where all candidate scores are set equal to isolate pure identity effects
