# v1 baseline — original Gemma 4 E2B pipeline

[`eval_gemma4_baseline.py`](eval_gemma4_baseline.py) reproduces the **pre-split Mero
pipeline** faithfully and scores it on the curated set, to give the reference number
the smaller-footprint work exists to beat.

- **Flow (duplicated exactly):** Gemma 4 E2B **sees the photo**, observes traits, calls
  `search_similar_features` (the only tool — the DINO observe/verify tools did not exist
  then), reasons over ranked candidates, and concludes the identification JSON — the
  ≤4-pass fix-and-pivot loop. Prompts = `main`-branch `chat_prompts.identify*`.
- **Search tool:** a Python reimplementation of `SpeciesService.searchSimilarByFeatures`
  — FTS5 prefix-match (filtered by `visual_group`) + per-field weighted Dice
  (`distinctive_marks×5, pattern×4, color×4, body_shape×3, texture×1, size_class×1`) +
  taxonomy boosts, over the curated SQLite DB.
- **Metric:** species top-1 + genus accuracy vs DB ground truth, same 64-species /
  332-image set as the other evals. Outputs → `outputs/gemma4_baseline*.json` + `.jsonl`
  (with the full per-image tool transcript).

## Runtime

Needs **LiteRT-LM + the multimodal Gemma checkpoint** — NOT the torch/onnx export venv.
Run with the **`sirkulab-mero-data/.venv`** (which has `litert_lm`); the search is stdlib.

```bash
cd ../sirkulab-mero-data && .venv/bin/python \
  ../sirkulab-mero/scripts/smaller-footprint-pipeline-v1/eval_gemma4_baseline.py \
  --model-path /Users/atnanahidiw/Downloads/gemma-4-E2B-it.litertlm   # --limit N to smoke
```

Measured throughput: **~7.9 s/image** (M-series GPU backend) → ~44 min for 332 images.

## Parallelism attempt — what we found (run it sequentially)

We tried to run multiple images concurrently. Findings:

- **Thread-parallel is impossible.** `litert_lm` enforces **one session per engine** —
  a 2nd concurrent `create_conversation` on a shared engine fails hard:
  > `FAILED_PRECONDITION: A session already exists. Only one session is supported at a
  > time. Please delete the existing session before creating a new one.`
  A `ThreadPoolExecutor` over one engine just fast-fails every worker but the first.
- **Process-sharding works but is bounded.** Each process needs its **own** engine, so
  `--shard i/n` launches N processes (`0/n`, `1/n`, …), each loading its own ~2.4 GB
  checkpoint. Two limits make it a poor trade here:
  - **RAM:** on a 16 GB machine, 3 × 2.4 GB engines (+ KV cache / activations / vision
    buffers / OS) overcommits → swapping makes it *slower*. **2 shards (~5 GB) is the
    safe ceiling on 16 GB.**
  - **One GPU:** all shards share it and the decode serializes, so the realistic win is
    **~1.3×**, not N×.
- **Decision: run sequentially.** The parallel ceiling isn't worth the OOM risk. The
  `--shard i/n` flag is kept for machines with more RAM/headroom; merge shards with:
  ```bash
  python -c "import json,glob; r=[json.loads(l) for f in glob.glob('outputs/gemma4_baseline_shard*of*.jsonl') for l in open(f)]; n=len(r); print(f'{n} imgs  species {sum(x[\"species_ok\"] for x in r)/n:.1%}  genus {sum(x[\"genus_ok\"] for x in r)/n:.1%}')"
  ```
