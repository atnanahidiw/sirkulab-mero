# Track 04: agent-loop evaluation

Phase 1 (loop ablation, revision analysis, stopping-policy comparison) ran on 332
images/64 species. See
[`docs/04_agent-loop-evaluation/00_plan.md`](../../docs/04_agent-loop-evaluation/00_plan.md)
for the plan and [`01_loop-ablation.md`](../../docs/04_agent-loop-evaluation/01_loop-ablation.md)
etc. for results. Phase 2 (reflective iteration, scripts `03`/`04` below) is built and
validated through real-bundle GPU initialization, but has not completed inference or
run at full scale in the managed development sandbox. See
[`04_reflective-iteration-implementation.md`](../../docs/04_agent-loop-evaluation/04_reflective-iteration-implementation.md).

The scripts reuse `../gemma-improve-detection/eval_gemma4_baseline.py` (Track 01) for
search, JSON parsing, and scoring, so every condition is scored like the deployed
baseline. The current Phase 2 script is standalone: it does not import the Phase 1 or
archived Phase 2 runners. Its plain-two-call control preserves Phase 1's wire format
through Search 2 while adding a real execution cap afterward.

## Scripts

### Phase 1

- [`00_loop_ablation.py`](00_loop_ablation.py): the data-collection script. Runs five
  conditions on the same frozen images, from no tool use to the full adaptive loop, and
  writes a per-image JSONL and summary JSON per condition. Needs LiteRT-LM, the
  multimodal Gemma checkpoint, and the `sirkulab-mero-data` image set (see Runtime
  below). Also writes a combined `loop_ablation_summary.json` with a paired McNemar
  test and bootstrap CI of each condition against the `fixed-retrieval` control. Each
  row records `generated_tokens`, the final recorded turn's token count from
  `Engine.tokenize()`. Run with `--recompute-tokens` to backfill that field into an
  existing run's jsonl without re-scoring any image: it only needs the tokenizer, so
  CPU is enough.
- [`01_revision_analysis.py`](01_revision_analysis.py): offline analysis over
  `00_loop_ablation.py`'s multi-pass traces (one-call, two-call, four-call). No model
  needed. Replays each recorded search against the species DB to find the pass at which
  the true species first becomes available, and correlates that with final accuracy and
  whether the requested `visualGroup` changed between passes.
- [`02_stopping_policy_comparison.py`](02_stopping_policy_comparison.py): offline
  comparison of the current fixed pass-limit against two alternative stopping rules
  (unchanged-hypothesis, evidence-threshold), replayed on the four-call condition's own
  traces. No model needed.

### Phase 2

- [`03_reflective_iteration.py`](03_reflective_iteration.py): current standalone v2
  six-condition runner. Conditions 1–4 remain comparable controls; conditions 5–6 use
  staged native actions with required schemas, bounded repair, deterministic tool
  execution, and closed-pool selection by canonical species ID.
- [`04_reflective_iteration_analysis.py`](04_reflective_iteration_analysis.py):
  offline analysis shared by the manifest-compatible v2 script. No model needed. Computes the
  pre-registered primary comparison (structured-reflection-retained-pool vs. a fresh
  plain-two-call run) with an exact McNemar test and a species-clustered bootstrap
  interval, Holm-corrected secondary comparisons against the other conditions, the
  condition-3 parity check, candidate-availability and protocol-error breakdowns, and a
  cost summary and every promotion gate, including protocol-clean accuracy, paired
  latency, duplicate execution, schema validity, and two optional robustness-seed runs.

Every analysis script here is honest about a hard limit: litert_lm's native tool loop
only returns the model's answer after it stops for real, so an earlier, counterfactual
stop is never observed. None of them fabricate an accuracy figure for a stopping point
or a query the model did not actually reach. See each file's docstring for exactly
what is and is not derived from the traces.

## Runtime

Run from the app repository root:

```bash
UV_CACHE_DIR=/tmp/mero-litert-uv-cache \
uv run --python .venv/bin/python \
  scripts/agent-loop-evaluation/03_reflective_iteration.py \
  --model-path ../sirkulab-mero-data/gemma-4-E2B-it.litertlm \
  --backend gpu --vision-backend gpu \
  --cache-dir /tmp/mero-litert-lm-cache \
  --warmup-image /path/to/an/image/not/in/the/evaluation/set
```

Script `03` defaults both language and vision execution to CPU. Comparable measured
runs must explicitly pass `--backend gpu --vision-backend gpu`; the selected backends
are included in the manifest identity. Gemma 4 MTP speculative decoding remains enabled.
Initialization fails instead of silently changing the requested model backend. This matches the
official [LiteRT-LM Gemma 4 MTP example](https://github.com/google-ai-edge/LiteRT-LM#readme).
The managed development sandbox used to prepare this script reports `Found 0 adapters`
at WebGPU adapter discovery even though the host is an Apple M4 with Metal support;
run measured inference from a normal macOS Terminal session where Metal/WebGPU is
available. Reaching that error confirms model/MTP loading but is not an inference smoke
test.
Use `--seed` for the primary and two robustness runs. A measured run requires
`--warmup-image`, and the runner rejects images in the complete evaluation set.
`--skip-warmup` exists only for smoke/debug runs and becomes part of the run identity.
Use `--balanced-pilot` for the pre-scale pilot: it deterministically selects the first
deduplicated image for each of the 64 represented species. It cannot be combined with
`--limit`, and the selection policy is recorded in the manifest.

Conditions 5–6 intentionally use a fresh selection conversation so their only difference
is the candidate-pool retention policy. Conditions 1–4 retain their original continuous
conversation to preserve baseline comparability. Consequently, comparisons between
condition 4 and conditions 5–6 include a selection-context change and must not be
interpreted as isolating database grounding alone.

Sessions are one-at-a-time per engine (see the parallelism note in
`../gemma-improve-detection/README.md`), so this runs sequentially like the rest of
Track 01. `--shard i/n` is available for the same process-sharding tradeoff described
there. Every shard shares one full-set manifest and writes a tagged JSONL. Analyze a
completed three-shard run with `--shards 3` (not `--tag`) so script `04` verifies and
merges all images. Background runs in this environment have been observed to get cut off after
roughly 45 minutes regardless of progress. Both experiment scripts write resumable per-image
JSONL for exactly this reason; re-running the same command picks up where it left off
instead of redoing finished images.

`01_revision_analysis.py`, `02_stopping_policy_comparison.py`, and
`04_reflective_iteration_analysis.py` need only the species DB and the corresponding
experiment's JSONL outputs:

```bash
python3 scripts/agent-loop-evaluation/01_revision_analysis.py
python3 scripts/agent-loop-evaluation/02_stopping_policy_comparison.py
python3 scripts/agent-loop-evaluation/04_reflective_iteration_analysis.py \
  --run-dir outputs/agent-loop-evaluation/reflective-iteration/<run-id>

# For a completed three-shard Phase 2 run:
python3 scripts/agent-loop-evaluation/04_reflective_iteration_analysis.py \
  --run-dir outputs/agent-loop-evaluation/reflective-iteration/<run-id> --shards 3
```
