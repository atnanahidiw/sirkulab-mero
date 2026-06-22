# AGENTS.md — Mero

Orientation for coding agents working in this repository. It covers what Mero is, how the code is laid out, and where the research context lives.

## What Mero is

Mero ("Empowering the Guardians of Tomorrow") is an offline-first, on-device Flutter app that identifies endangered Indonesian species from a photo and teaches conservation related knowledge. It targets schools in remote parts of Indonesia (Papua, Maluku, Kalimantan, Flores, and similar regions) where students live alongside endangered and endemic species but lack the connectivity and up-to-date materials to learn about them. That is the reason for the offline design: after a one-time model download, all inference runs locally, so the app works in the field with no signal. It ships full Bahasa Indonesia and English localization and was built in partnership with Sirkula Indonesia. Licensed MIT.

The pitch, motivation, and product narrative live in `docs/mero - kaggle writeup.md`. Read that first for the why.

## Research context and current direction

Mero is a research prototype, not a finished product: it works, but much of it is still open ground for improvement and research. The `docs/` folder is a lab notebook: an append-only record of what was tried, in the order it was tried. Keep it that way. Do not rewrite, merge, or delete past experiments to make the story read cleaner. Add new entries instead. The cross-cutting "where this is going and why" note lives in `docs/README.md` under "Current Direction".

There are two research directions. The first is on-device agentic behavior: whether a small model can run its own identification loop, meaning observe the image, form a hypothesis, call its own search and verification tools, judge the candidates, and revise over several passes. The second is mechanistic interpretability: understanding why the model behaves as it does, for example the candidate-rank bias work in tracks `02` and `03`. Both were found by experiment rather than chosen up front, so they are still forming.

One consequence matters for anyone touching the code: some implementation details are load-bearing for the research, not just plumbing, so do not quietly change them for convenience. For the agentic work, native function calling and the tool-use loop are the object of study, so do not replace the loop with a fixed app-side pipeline even though that would be more robust for shipping (see `docs/01_gemma-improve-detection/tool-calling-vs-emulated.md`). For the interpretability work, the analysis needs access to hidden states, logits, and hooks, which LiteRT-LM does not expose, so that track runs on Hugging Face Gemma safetensors instead of the on-device runtime (see `docs/03_candidate-rank-mechanistic/00_plan.md`). If you change either for a build, say so in the relevant doc.

## How identification works

The app centers on **Gemma 4 E2B** (int4, `.litertlm`, ~2.4–2.58 GB) run on-device via LiteRT-LM through the `flutter_gemma` package. It is the authoritative baseline: nothing smaller has matched it yet, so it stays the intended design even where a branch leaves an unreverted trial running (if `model_service.dart` shows something other than Gemma, e.g. `ModelType.qwen3`, that is an experiment, not the architecture — see `docs/00_smaller-footprint-pipeline/`). The pipeline:

1. Student takes a photo. Gemma observes structured visual traits (color, body shape, marks, texture, size class, pattern, visual group) via function calling. On smaller-model trial branches the reasoning LLM is text-only and a bundled Talk2DINO vision tool does this observing instead.
2. Gemma calls the on-device `search_similar_features` tool, which runs an FTS5 full-text search against a bundled SQLite species database (narrowed by visual group) and reranks with a weighted Sørensen–Dice score.
3. Gemma evaluates the ranked candidates against the image, revises its hypothesis, and loops up to **four passes**, gated by a confidence check (high/medium → continue, low/empty → retry).
4. Once confirmed, the full curated species record is injected into Gemma's context for grounded, age-appropriate Q&A. Ground truth always comes from the curated database, not the model, to limit hallucination.

## Repository layout

- **`lib/`** — the Flutter app (Dart).
  - `main.dart` — entry point; initializes FlutterGemma, sets up `ModelService` + `LocaleService` providers, launches `StartupGate`.
  - `services/` — core logic. `model_service.dart` (orchestration, JSON repair), `model_runtime.dart` (inference loop, repetition-loop detection, progress/trace emission), `model_download_service.dart` + `model_boot_state.dart` + `model_download_notification_service.dart` (model lifecycle), `species_service.dart` (SpeciesDetail domain model over the Drift DB), `vision_runtime.dart` + `clip_tokenizer.dart` (Talk2DINO ONNX vision/text tools), `analysis_story_formatter.dart`, `locale_service.dart`, `permission_service.dart`.
  - `pages/` — `home_page`, `analyzing_page`, `result_page`, `settings_page`.
  - `widgets/` — `startup_gate`, `model_boot_splash`, `loading_overlay`.
  - `models/` — `chat_prompts.dart` (tool defs, Q&A hint chips, prompt templates), `model_spec.dart`.
  - `database/` — `species_database.dart` (+ generated `.g.dart`), Drift over `assets/data/species_data.sqlite`.
  - `l10n/` — ARB files (`app_en.arb`, `app_id.arb`) + generated localizations.
  - `core/` — theme and navigation.
- **`assets/`** — bundled `species_data.sqlite`, per-species JSON under `assets/data/species_data/<Class>/<Order>/…`, and ONNX models + embeddings/vocab under `assets/models/`.
- **`test/`** — Dart unit/widget tests (model service, boot state/splash, download service, widget test).
- **`scripts/`** — offline Python research/build tooling (not shipped in the app), grouped by research track: `build_species_db.py`, `candidate-rank-sensitivity/`, `candidate-rank-mechanistic/`, `gemma-improve-detection/`, `smaller-footprint-pipeline-v2/`, `smaller-footprint-pipeline-v3/`.
- **`outputs/`** — JSON result summaries from those experiments.
- **`docs/`** — research narrative (see below).
- Platform dirs (`android/`, `ios/`, `web/`), plus `.venv-export/` and `.uv-cache/` (large local Python env caches — ignore, not source).

## Research docs (`docs/`)

`docs/README.md` is the index. Read it for the per-track descriptions, reading order, and the "Current Direction" note. Tracks: `00_smaller-footprint-pipeline/` (smaller on-device model search), `01_gemma-improve-detection/` (detection failures and fixes), `02_candidate-rank-sensitivity/` (behavioral rank-bias), `03_candidate-rank-mechanistic/` (mechanistic rank-bias). Also `docs/reports/` and `docs/logs/`.

## Working notes for agents

- The app is the deliverable in `lib/`. `scripts/` and `outputs/` are offline research and should not be assumed to run inside the app.
- Ground-truth species facts belong in the SQLite DB and per-species JSON, not in model prompts. Adding a species means new JSON and a DB entry, with no retraining.
- Localization is real. User-facing strings go through ARB files, not hardcoded text.
- When touching the identification pipeline, respect the four-pass cap and the confidence gate. Both are deliberate stability constraints for 8 GB Android devices.
- If vision behavior seems to contradict the "Gemma-only" writeup, trust the code and `docs/00_smaller-footprint-pipeline/`.
