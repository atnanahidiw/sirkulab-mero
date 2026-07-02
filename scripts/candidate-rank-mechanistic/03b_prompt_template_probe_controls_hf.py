#!/usr/bin/env python3
"""Prompt-template probing controls for candidate-position decodability.

This script runs 03a_probe_candidate_position_hf.py across multiple prompt
template conditions by importing 03a, patching its BASELINE_PROMPTS, and
calling its main() with separate output paths per condition.

Why this is needed:
03a does not expose --prompt-template. It hardcodes BASELINE_PROMPTS internally.
So 03b cannot pass --prompt-template through subprocess. Instead, 03b patches
03a.BASELINE_PROMPTS before each run.

The scientific purpose is to test whether candidate-position decodability
generalizes beyond the two baseline prompt formats used in 03a.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import traceback
from dataclasses import dataclass
from pathlib import Path
from typing import Any


HERE = Path(__file__).resolve().parent
PROBE_SCRIPT = HERE / "03a_probe_candidate_position_hf.py"


@dataclass(frozen=True)
class PromptTemplateControl:
    """One prompt-template control condition."""

    name: str
    list_format: str
    answer_format: str
    description: str


TEMPLATES: tuple[PromptTemplateControl, ...] = (
    PromptTemplateControl(
        name="numbered_list",
        list_format="numbered",
        answer_format="scientific_name_only",
        description="Numbered candidate list with visible rank markers.",
    ),
    PromptTemplateControl(
        name="semicolon_list",
        list_format="semicolon",
        answer_format="scientific_name_only",
        description="Semicolon candidate list without visible numerical rank markers.",
    ),
    PromptTemplateControl(
        name="bullet_list",
        list_format="bullet",
        answer_format="scientific_name_only",
        description="Bullet-list candidate format without visible numerical rank markers.",
    ),
    PromptTemplateControl(
        name="plain_sentences",
        list_format="plain_sentences",
        answer_format="scientific_name_only",
        description="Candidates written as plain sentence fragments.",
    ),
    PromptTemplateControl(
        name="distance_equalized",
        list_format="distance_equalized",
        answer_format="scientific_name_only",
        description="Template intended to reduce distance-to-answer confounds.",
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run 03a candidate-position probing across prompt-template controls."
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("outputs/03_candidate-rank-mechanistic/04prompt_template_controls"),
        help="Directory for 03b outputs.",
    )
    parser.add_argument(
        "--templates",
        nargs="+",
        default=[template.name for template in TEMPLATES],
        help="Template controls to run.",
    )
    parser.add_argument(
        "--summarize-only",
        action="store_true",
        help="Only summarize existing per-template summary files.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print planned 03a argv values without running or writing summaries.",
    )
    parser.add_argument(
        "--continue-on-error",
        action="store_true",
        help="Continue running later templates if one template fails.",
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help=(
            "Pass --resume to each 03a template run so existing feature rows are "
            "reused instead of deleting per-template outputs."
        ),
    )
    parser.add_argument(
        "probe_args",
        nargs=argparse.REMAINDER,
        help=(
            "Extra args passed through to 03a. Put them after --. "
            "Example: -- --model-id google/gemma-4-E2B-it --device mps --layers first,middle,last"
        ),
    )
    return parser.parse_args()


def strip_remainder_separator(args: list[str]) -> list[str]:
    if args and args[0] == "--":
        return args[1:]
    return args


def template_map() -> dict[str, PromptTemplateControl]:
    return {template.name: template for template in TEMPLATES}


def validate_templates(selected_templates: list[str]) -> None:
    known = set(template_map())
    unknown = sorted(set(selected_templates) - known)
    if unknown:
        raise ValueError(
            "Unknown templates: "
            + ", ".join(unknown)
            + ". Known templates: "
            + ", ".join(sorted(known))
        )


def load_03a_module() -> Any:
    if not PROBE_SCRIPT.exists():
        raise FileNotFoundError(f"Could not find 03a script: {PROBE_SCRIPT}")

    spec = importlib.util.spec_from_file_location(
        "candidate_position_probe_03a",
        PROBE_SCRIPT,
    )
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not import 03a from {PROBE_SCRIPT}")

    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    if not hasattr(module, "main"):
        raise RuntimeError(f"03a script at {PROBE_SCRIPT} has no main()")
    if not hasattr(module, "PromptVariant"):
        raise RuntimeError(f"03a script at {PROBE_SCRIPT} does not expose PromptVariant")
    if not hasattr(module, "BASELINE_PROMPTS"):
        raise RuntimeError(f"03a script at {PROBE_SCRIPT} does not expose BASELINE_PROMPTS")

    return module


def build_03a_argv(
    *,
    template: PromptTemplateControl,
    template_dir: Path,
    passthrough_args: list[str],
    resume: bool,
) -> list[str]:
    argv = [
        str(PROBE_SCRIPT),
        "--output",
        str(template_dir / "probe_candidate_position.jsonl"),
        "--features-output",
        str(template_dir / "probe_candidate_position_features.jsonl"),
        "--dataset-output",
        str(template_dir / "probe_candidate_position_dataset.jsonl"),
        "--table-output",
        str(template_dir / "probe_candidate_position_scores.csv"),
        "--summary-output",
        str(template_dir / "probe_candidate_position_summary.json"),
    ]
    if resume:
        argv.append("--resume")
    argv.extend(passthrough_args)
    return argv


def run_03a_for_template(
    *,
    template: PromptTemplateControl,
    template_dir: Path,
    passthrough_args: list[str],
    dry_run: bool,
    resume: bool,
) -> dict[str, Any]:
    argv = build_03a_argv(
        template=template,
        template_dir=template_dir,
        passthrough_args=passthrough_args,
        resume=resume,
    )

    print(" ".join([sys.executable, *argv]), flush=True)

    if dry_run:
        return {
            "template": template.name,
            "status": "dry_run",
            "argv": argv,
        }

    module = load_03a_module()

    # Important:
    # 03b is a prompt-template control. Each template should be one condition.
    # Do not create fake with_rank_markers / without_rank_markers conditions
    # here, because that duplicates the same prompt format and makes 03a's
    # condition-transfer metrics meaningless for 03b.
    module.BASELINE_PROMPTS = {
        template.name: module.PromptVariant(
            template.name,
            template.list_format,
            template.answer_format,
        )
    }

    old_argv = sys.argv[:]
    try:
        sys.argv = argv
        exit_code = int(module.main())
    finally:
        sys.argv = old_argv

    return {
        "template": template.name,
        "status": "ok" if exit_code == 0 else "failed",
        "exit_code": exit_code,
        "argv": argv,
    }


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)

    if not isinstance(value, dict):
        raise ValueError(f"Expected JSON object in {path}, got {type(value).__name__}")

    return value


def safe_get(summary: dict[str, Any], *keys: str, default: Any = None) -> Any:
    value: Any = summary
    for key in keys:
        if not isinstance(value, dict) or key not in value:
            return default
        value = value[key]
    return value


def summarize_template(
    *,
    template: PromptTemplateControl,
    template_dir: Path,
    run_result: dict[str, Any] | None,
) -> dict[str, Any]:
    summary_path = template_dir / "probe_candidate_position_summary.json"

    base = {
        "template": template.name,
        "list_format": template.list_format,
        "answer_format": template.answer_format,
        "description": template.description,
        "summary_path": str(summary_path),
        "run_result": run_result,
    }

    if not summary_path.exists():
        return {
            **base,
            "status": "missing_summary",
        }

    summary = read_json(summary_path)

    return {
        **base,
        "status": summary.get("status", "unknown"),
        "mode": summary.get("mode"),
        "model_id": summary.get("model_id"),
        "device": summary.get("device"),
        "dtype": summary.get("dtype"),
        "num_examples_requested": summary.get("num_examples_requested"),
        "num_processed_examples": summary.get("num_processed_examples"),
        "num_prompt_rows": summary.get("num_prompt_rows"),
        "num_feature_rows": summary.get("num_feature_rows"),
        "num_summary_rows": summary.get("num_summary_rows"),
        "labels_observed": summary.get("labels_observed"),
        "layers_selected": summary.get("layers_selected"),
        "feature_locations": summary.get("feature_locations"),
        "probe_accuracy": summary.get("probe_accuracy"),
        "macro_f1": summary.get("macro_f1"),
        "mean_probe_accuracy": summary.get("mean_probe_accuracy"),
        "majority_baseline_accuracy": summary.get("majority_baseline_accuracy"),
        "random_label_accuracy": summary.get("random_label_accuracy"),
        "accuracy_minus_majority_baseline": summary.get("accuracy_minus_majority_baseline"),
        "accuracy_minus_random_label_baseline": summary.get("accuracy_minus_random_label_baseline"),
        "best_layer": safe_get(
            summary,
            "layer_with_highest_probe_accuracy",
            "layer_index",
        ),
        "best_feature_location": safe_get(
            summary,
            "layer_with_highest_probe_accuracy",
            "feature_location",
        ),
        "best_layer_result": summary.get("layer_with_highest_probe_accuracy"),
        "candidate_identity_split_accuracy": summary.get("candidate_identity_split_accuracy"),
        "example_split_accuracy": summary.get("example_split_accuracy"),
        "primary_probe_result": summary.get("primary_probe_result"),
    }


def combined_status(rows: list[dict[str, Any]]) -> str:
    if not rows:
        return "missing"

    statuses = [row.get("status") for row in rows]
    if all(status == "missing_summary" for status in statuses):
        return "missing"
    if any(status in {"missing_summary", "failed"} for status in statuses):
        return "partial"
    return "ok"


def write_combined_summary(
    *,
    output_dir: Path,
    selected_templates: list[str],
    rows: list[dict[str, Any]],
) -> Path:
    descriptions = {template.name: template.description for template in TEMPLATES}

    combined = {
        "status": combined_status(rows),
        "analysis": "03b_prompt_template_probe_controls",
        "purpose": (
            "Check whether candidate-position decodability generalizes across "
            "prompt-template controls by patching 03a.BASELINE_PROMPTS."
        ),
        "selected_templates": selected_templates,
        "template_descriptions": {
            name: descriptions.get(name, "") for name in selected_templates
        },
        "results": rows,
        "interpretation": (
            "High probe accuracy across templates supports candidate-position "
            "decodability beyond one prompt format. It still does not prove "
            "causal model use. Lower accuracy in marker-free or "
            "distance-equalized templates would suggest that the original probe "
            "relied on visible markers, prompt layout, local separator cues, or "
            "distance-to-answer-field effects."
        ),
        "important_caveat": (
            "This runner depends on common_hf.build_prompt_variant_prompt and "
            "any underlying candidate-list renderer it calls, supporting each "
            "list_format used here. If a template fails, add the corresponding "
            "list_format implementation in common_hf."
        ),
    }

    output_path = output_dir / "prompt_template_probing_controls_summary.json"
    with output_path.open("w", encoding="utf-8") as handle:
        json.dump(combined, handle, indent=2, sort_keys=True)

    return output_path


def main() -> int:
    args = parse_args()

    output_dir: Path = args.output_dir
    output_dir.mkdir(parents=True, exist_ok=True)

    selected_templates = list(args.templates)
    validate_templates(selected_templates)

    passthrough_args = strip_remainder_separator(list(args.probe_args))
    templates = template_map()

    run_results: dict[str, dict[str, Any]] = {}

    if not args.summarize_only:
        for template_name in selected_templates:
            template = templates[template_name]
            template_dir = output_dir / template.name
            template_dir.mkdir(parents=True, exist_ok=True)

            try:
                run_results[template.name] = run_03a_for_template(
                    template=template,
                    template_dir=template_dir,
                    passthrough_args=passthrough_args,
                    dry_run=args.dry_run,
                    resume=args.resume,
                )
            except Exception as exc:
                run_results[template.name] = {
                    "template": template.name,
                    "status": "failed",
                    "error": str(exc),
                    "traceback": traceback.format_exc(),
                }
                if not args.continue_on_error:
                    raise

    if args.dry_run:
        print("Dry run complete. No combined summary was written.")
        return 0

    rows = [
        summarize_template(
            template=templates[template_name],
            template_dir=output_dir / template_name,
            run_result=run_results.get(template_name),
        )
        for template_name in selected_templates
    ]

    combined_path = write_combined_summary(
        output_dir=output_dir,
        selected_templates=selected_templates,
        rows=rows,
    )

    print(f"Wrote combined summary: {combined_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
