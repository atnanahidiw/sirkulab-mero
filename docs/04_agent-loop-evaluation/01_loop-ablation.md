# Loop ablation results

## Summary

The five-condition ablation ran on **332 images covering 64 species**. The two-call
condition had the highest observed species top-1 accuracy at **41.0% (136/332)**. The
fixed-retrieval control reached **35.2% (117/332)**, a difference of **+5.7 percentage
points**. That comparison was borderline but not conventionally significant
(`p = 0.0648`; paired bootstrap 95% CI **0.0 to +11.4 pp**).

The four-call prompt condition reached **37.7% (125/332)**. Its **+2.4 pp** difference
from fixed retrieval was not reliable (`p = 0.466`; 95% CI **−3.3 to +8.1 pp**).
This run therefore does not establish that the four-call prompt condition beats one fixed
retrieval pass.

## Artifacts

- Runner: [`00_loop_ablation.py`](../../scripts/agent-loop-evaluation/00_loop_ablation.py)
- Combined summary: [`loop_ablation_summary.json`](../../outputs/agent-loop-evaluation/loop_ablation_summary.json)
- Per-condition summaries and traces: [`outputs/agent-loop-evaluation/`](../../outputs/agent-loop-evaluation/)
- Run date: **2026-07-22**

## Conditions and results

All conditions used the same frozen images and Gemma 4 E2B LiteRT-LM sampler settings.
The fixed-retrieval control used one model observation pass, one app-driven database
search, and one model selection pass. The adaptive conditions let Gemma choose the
search arguments through native function calling.

| Condition | Species top-1 | Genus accuracy | Mean search calls | Mean final-turn tokens | Recorded timing |
| --- | ---: | ---: | ---: | ---: | ---: |
| Direct VLM, no database | 3.6% (12/332) | 7.5% (25/332) | 0.00 | 82.3 | not retained |
| Fixed retrieval + one selection | 35.2% (117/332) | 38.0% (126/332) | 1.00 | 91.5 | not retained |
| One-call adaptive | 33.7% (112/332) | 35.8% (119/332) | 1.00 | 98.9 | not retained |
| Two-call adaptive | **41.0% (136/332)** | **43.7% (145/332)** | 1.24 | 119.9 | 10.08 s/image, session mean |
| Four-call prompt condition | 37.7% (125/332) | 41.3% (137/332) | 1.25 | 118.6 | 11.71 s/image, session mean |

Search calls and token counts are both device-agnostic, so both were backfilled from the
existing traces with `00_loop_ablation.py --recompute-tokens`: it re-encodes each row's
saved final-turn text with the model's own tokenizer, since litert_lm's Python API
exposes no native usage counter. The token column is a lower bound for every condition
except direct: it counts only the last recorded turn, and litert_lm's
`automatic_tool_calling` loop never exposes the text of the search-time turns that came
before it. Direct is the only row where the final turn is the whole conversation, so its
82.3 is a true total rather than an undercount.

Direct identification is a deliberately weak open-label control: without the database,
Gemma is not constrained to Mero's 64 evaluated species. Its 3.6% result shows the
value of retrieval in this task, but it is not the main test of agentic iteration.

## Paired comparisons against fixed retrieval

| Condition | Accuracy difference | Wrong → correct | Correct → wrong | McNemar p | Paired bootstrap 95% CI |
| --- | ---: | ---: | ---: | ---: | ---: |
| Direct | −31.6 pp | 5 | 110 | 3.1×10⁻²² | −37.0 to −26.2 pp |
| One-call | −1.5 pp | 46 | 51 | 0.685 | −7.2 to +4.2 pp |
| Two-call | **+5.7 pp** | 57 | 38 | 0.0648 | 0.0 to +11.4 pp |
| Four-call prompt | +2.4 pp | 50 | 42 | 0.466 | −3.3 to +8.1 pp |

The script uses a continuity-corrected chi-square McNemar approximation. The bootstrap
interval resamples images, not species clusters, so both inferential summaries should
be read as image-level evidence. The evaluation contains four to eight images per
species.

## What the extra calls changed

The one-call condition was not better than fixed retrieval. Relative to the independent
one-call run, the two-call run produced **52 rescues and 28 regressions** on the paired
images, a net gain of 24 correct answers. It also made the true species available in
the top-five candidate list more often. The revision report tests whether candidate
recovery is a plausible explanation; it cannot prove mediation between independent
runs.

More allowed calls did not produce a better aggregate result. Relative to the two-call
run, the four-call run
had **23 rescues but 34 regressions**, a net loss of 11 correct answers. These are
independent model runs with different cap instructions, so they are not a literal
pass-by-pass trajectory, but they show that the additional allowance did not produce a
better aggregate policy.

The nominal four-call condition also made **five search calls on one image**. The cap
was expressed in the prompt rather than enforced by the Python runtime, so this is more
accurately a *four-call prompt condition* than a hard fixed limit.

## Interpretation

The strongest supported result is that retrieval is essential and that permitting a
second adaptive call can recover useful cases. The experiment does **not** support the
stronger claim that the full four-call agent loop outperforms fixed retrieval. The
two-call gain is promising but misses the conventional 0.05 threshold, while the
four-call gain is smaller and clearly inconclusive.

For this baseline, the practical next comparison should test a runtime-enforced
two-call cap as the leading candidate, with repeated seeds or runs. That would test
whether the observed +5.7 pp is stable
without allowing prompt wording or sampling variation to stand in for the effect of
iteration itself.

## Scope and limitations

- The harness reproduces the historical multimodal **Gemma 4 E2B** baseline from Track
  01. The current Flutter branch uses an experimental text-only Qwen3 model with
  separate vision tools, so these numbers are not measurements of that branch.
- The fixed-retrieval condition still uses Gemma to extract traits and select a result;
  "fixed" refers to app-driven search control, not a model-free classifier.
- Conditions change their cap instructions and run separately. The test is paired by
  image, but it is not a replay of one identical stochastic trajectory at successive
  cutoffs.
- Only the two-call and four-call sessions retained coarse session-level timing, and no
  condition recorded per-image latency, memory, energy, or temperature. Mean search
  calls and mean final-turn token counts are recorded for every condition and are
  device-agnostic, but the token counts undercount total generation for every condition
  except direct (see above).
- Two direct responses and three four-call responses failed JSON parsing; these count
  as incorrect under the common scorer.
