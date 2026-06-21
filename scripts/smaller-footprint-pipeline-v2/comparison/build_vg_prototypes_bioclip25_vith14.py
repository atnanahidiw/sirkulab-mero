#!/usr/bin/env python3
"""Build and auto-tune `visual_group` prototypes for the Mero vision pipeline.

This script computes one frozen image prototype per `visual_group` from labeled
images in the sibling `sirkulab-mero-data` repository, then evaluates a small
set of prototype aggregation strategies against the same labeled set and keeps
the best one.

Why this exists:
- `visual_group` is a weak attribute in zero-shot label matching.
- Frozen image features can work better with prototype / nearest-neighbor
  matching than with text-label matching for coarse visual groups.
- A prototype is the mean-like representative embedding for a group of example
  images.

Output:
  assets/models/visual_group_prototypes_bioclip25_vith14.pb

The script also writes suffixed eval reports to `<data-repo>/data/processed/`.

The protobuf schema lives in `assets/models/visual_group_prototypes.proto`.

USAGE
-----
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v2/comparison/build_vg_prototypes_bioclip25_vith14.py
  #   --data-repo ../sirkulab-mero-data
  #   --max-per-group 8
  #   --strategy auto|mean|medoid|trimmed_90|trimmed_80|trimmed_70|topk_5
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import struct
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from PIL import Image

from export_vision_model_bioclip25_vith14 import DISPLAY_NAME, HF_MODEL, SUFFIX, INPUT_SIZE, load_bioclip25_vith14


HERE = Path(__file__).resolve()
APP_REPO = HERE.parents[3]
WORKDIR = HERE.parents[4]
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

# Unambiguous taxonomic-class folder → visual_group (within the DB's 15 values).
# Ambiguous classes are intentionally left out; they are ground-truthed only via
# the exact DB latin/common-name join.
CLASS_MAP = {
    "aves": "Flying bird",
    "amphibia": "Frog & toad",
    "squamata": "Lizard",
    "testudines": "Turtle & tortoise",
    "anthozoa": "Mollusk & marine invertebrate",
    "bivalvia": "Mollusk & marine invertebrate",
    "polypodiopsida": "Fern",
    "actinopterygii": "Marine fish",
    "elasmobranchii": "Marine fish",
    "chondrichthyes": "Marine fish",
}

SUPPORTED_STRATEGIES = (
    "mean",
    "medoid",
    "trimmed_90",
    "trimmed_80",
    "trimmed_70",
    "topk_5",
)


def _varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("protobuf varints require non-negative integers")
    out = bytearray()
    while True:
        to_write = value & 0x7F
        value >>= 7
        if value:
            out.append(to_write | 0x80)
        else:
            out.append(to_write)
            return bytes(out)


def _key(field_no: int, wire_type: int) -> bytes:
    return _varint((field_no << 3) | wire_type)


def _field_varint(field_no: int, value: int) -> bytes:
    return _key(field_no, 0) + _varint(value)


def _field_fixed64(field_no: int, value: float) -> bytes:
    return _key(field_no, 1) + struct.pack("<d", float(value))


def _field_length_delimited(field_no: int, payload: bytes) -> bytes:
    return _key(field_no, 2) + _varint(len(payload)) + payload


def _field_string(field_no: int, value: str) -> bytes:
    return _field_length_delimited(field_no, value.encode("utf-8"))


def _field_packed_floats(field_no: int, values: list[float]) -> bytes:
    payload = b"".join(struct.pack("<f", float(v)) for v in values)
    return _field_length_delimited(field_no, payload)


def _field_repeated_strings(field_no: int, values: list[str]) -> bytes:
    return b"".join(_field_string(field_no, value) for value in values)


def _encode_candidate_score(strategy: str, accuracy: float) -> bytes:
    return _field_string(1, strategy) + _field_fixed64(2, accuracy)


def _encode_prototype(entry: dict) -> bytes:
    return (
        _field_string(1, entry["label"])
        + _field_varint(2, int(entry["count"]))
        + _field_packed_floats(3, [float(v) for v in entry["emb"]])
        + _field_repeated_strings(4, list(entry.get("examples", [])))
    )


def serialize_visual_group_prototypes(payload: dict) -> bytes:
    meta = payload["meta"]
    meta_bytes = (
        _field_string(1, meta["generated_at_utc"])
        + _field_string(2, meta["source_repo"])
        + _field_string(3, meta["images_subdir"])
        + _field_string(4, meta["db"])
        + _field_string(5, meta["hf_model"])
        + _field_varint(6, int(meta["input_size"]))
        + _field_string(7, meta["prototype_method"])
        + _field_varint(8, int(meta["max_per_group"]))
        + _field_varint(9, int(meta["min_per_group"]))
        + _field_varint(10, int(meta["groups"]))
        + _field_varint(11, int(meta["images_used"]))
        + _field_fixed64(12, float(meta["text_baseline_accuracy"]))
        + b"".join(
            _field_length_delimited(13, _encode_candidate_score(row["strategy"], row["accuracy"]))
            for row in meta["candidate_scores"]
        )
    )
    proto_bytes = b"".join(_field_length_delimited(2, _encode_prototype(row)) for row in payload["visual_group"])
    return _field_length_delimited(1, meta_bytes) + proto_bytes


def l2(v: np.ndarray) -> np.ndarray:
    return v / (np.linalg.norm(v, axis=-1, keepdims=True) + 1e-9)


def image_embedding(enc, path: str) -> np.ndarray:
    import torch

    input_size = getattr(enc, "input_size", INPUT_SIZE)
    mean = np.asarray(getattr(enc, "mean", MEAN), np.float32)
    std = np.asarray(getattr(enc, "std", STD), np.float32)
    img = Image.open(path).convert("RGB").resize((input_size, input_size), Image.BICUBIC)
    arr = (np.asarray(img, np.float32) / 255.0 - mean) / std
    with torch.no_grad():
        emb = enc.image_module(torch.from_numpy(arr.transpose(2, 0, 1)[None])).cpu().numpy()[0]
    return l2(emb)


def load_db_lookup(db_path: Path) -> dict[str, str]:
    """Return `{normalized species/common name: visual_group}`."""
    con = sqlite3.connect(str(db_path))
    lut: dict[str, str] = {}
    for col in ("latin_name", "common_name"):
        for name, vg in con.execute(
            f"SELECT {col}, visual_group FROM species "
            f"WHERE TRIM({col}) != '' AND TRIM(visual_group) != ''"
        ):
            lut[name.strip().lower()] = vg
    con.close()
    return lut


def load_text_baseline(path: Path):
    with path.open() as f:
        obj = json.load(f)
    rows = obj["visual_group"]
    return {
        row["label"]: np.asarray(row["emb"], dtype=np.float32)
        for row in rows
    }


def ground_truth(rel_path: Path, db_lut: dict[str, str]):
    """Return `(visual_group, source)` or `(None, 'unknown')`."""
    parts = list(rel_path.parts[:-1])
    for folder in reversed(parts):
        name = folder.replace("_", " ").strip().lower()
        if name in db_lut:
            return db_lut[name], "db"
    for folder in parts:
        if folder.lower() in CLASS_MAP:
            return CLASS_MAP[folder.lower()], "class_map"
    return None, "unknown"


def collect_samples(img_root: Path, db_lut: dict[str, str]):
    """Return deduped image samples with ground truth metadata."""
    samples = []
    seen: set[tuple[str, int]] = set()
    for path in sorted(img_root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTS:
            continue
        key = (path.name, path.stat().st_size)
        if key in seen:
            continue
        seen.add(key)
        rel = path.relative_to(img_root)
        gt, src = ground_truth(rel, db_lut)
        samples.append(
            {
                "path": path,
                "rel": str(rel),
                "gt": gt,
                "src": src,
                "emb": None,
            }
        )
    return samples


def embed_samples(enc, samples):
    for sample in samples:
        sample["emb"] = image_embedding(enc, str(sample["path"]))


def group_samples(samples):
    grouped: dict[str, list[dict]] = defaultdict(list)
    for sample in samples:
        if sample["gt"] is not None:
            grouped[sample["gt"]].append(sample)
    return grouped


def prototype_from_embeddings(embeddings: list[np.ndarray], strategy: str) -> np.ndarray:
    arr = np.stack(embeddings, axis=0).astype(np.float32)
    if len(arr) == 1:
        return l2(arr[0])

    if strategy == "mean":
        return l2(arr.mean(axis=0))

    if strategy == "medoid":
        sims = arr @ arr.T
        idx = int(np.argmax(sims.mean(axis=1)))
        return l2(arr[idx])

    if strategy.startswith("trimmed_"):
        keep_ratio = float(strategy.split("_", 1)[1]) / 100.0
        centroid = l2(arr.mean(axis=0))
        scores = arr @ centroid
        keep_n = max(1, int(np.ceil(len(arr) * keep_ratio)))
        idxs = np.argsort(scores)[::-1][:keep_n]
        return l2(arr[idxs].mean(axis=0))

    if strategy.startswith("topk_"):
        keep_n = max(1, int(strategy.split("_", 1)[1]))
        centroid = l2(arr.mean(axis=0))
        scores = arr @ centroid
        idxs = np.argsort(scores)[::-1][:min(keep_n, len(arr))]
        return l2(arr[idxs].mean(axis=0))

    raise ValueError(f"Unknown strategy: {strategy}")


def leave_one_out_accuracy(grouped, strategy: str):
    """Honest generalization: for each image, rebuild its group's prototype
    WITHOUT that image, keep other groups' (full) prototypes, then predict.
    A singleton group contributes a guaranteed miss (it can't generalize to
    itself), which is the correct signal. Returns (accuracy, correct, total)."""
    labels = sorted(grouped)
    embs = {g: [s["emb"] for s in grouped[g] if s["emb"] is not None] for g in labels}
    full = {g: prototype_from_embeddings(embs[g], strategy) for g in labels if embs[g]}
    correct = total = 0
    for g in labels:
        for i in range(len(embs[g])):
            test = embs[g][i]
            plabels, protos = [], []
            for h in labels:
                if h == g:
                    rest = embs[g][:i] + embs[g][i + 1:]
                    if not rest:
                        continue  # singleton group → cannot match its own group
                    protos.append(prototype_from_embeddings(rest, strategy))
                elif h in full:
                    protos.append(full[h])
                else:
                    continue
                plabels.append(h)
            if not protos:
                total += 1
                continue
            pred = plabels[int((l2(np.stack(protos)) @ test).argmax())]
            correct += int(pred == g)
            total += 1
    return (correct / total if total else 0.0), correct, total


def build_prototypes(grouped, strategy: str, include_examples: int):
    prototypes = []
    for label in sorted(grouped):
        samples = grouped[label]
        embeddings = [s["emb"] for s in samples if s["emb"] is not None]
        if not embeddings:
            continue
        proto = prototype_from_embeddings(embeddings, strategy)
        examples = [s["rel"] for s in samples[: max(0, include_examples)]]
        prototypes.append(
            {
                "label": label,
                "count": len(embeddings),
                "emb": [round(float(x), 6) for x in proto.tolist()],
                "examples": examples,
            }
        )
    return prototypes


def evaluate(samples, proto_labels, proto_embs, text_labels, text_embs):
    proto_correct = 0
    text_correct = 0
    evaluated = 0
    by_source = {"db": 0, "class_map": 0, "unknown": 0}
    rows = []

    for sample in samples:
        gt = sample["gt"]
        src = sample["src"]
        by_source[src] += 1
        emb = sample["emb"]
        if emb is None:
            continue

        proto_scores = proto_embs @ emb
        proto_idx = int(proto_scores.argmax())
        text_scores = text_embs @ emb
        text_idx = int(text_scores.argmax())

        row = {
            "image": sample["rel"],
            "ground_truth": gt,
            "gt_source": src,
            "prototype_prediction": {
                "label": proto_labels[proto_idx],
                "score": round(float(proto_scores[proto_idx]), 4),
            },
            "text_prediction": {
                "label": text_labels[text_idx],
                "score": round(float(text_scores[text_idx]), 4),
            },
        }

        if gt is not None:
            evaluated += 1
            proto_hit = proto_labels[proto_idx] == gt
            text_hit = text_labels[text_idx] == gt
            row["correct"] = {"prototype": proto_hit, "text": text_hit}
            proto_correct += int(proto_hit)
            text_correct += int(text_hit)

        rows.append(row)

    return {
        "proto_correct": proto_correct,
        "text_correct": text_correct,
        "evaluated": evaluated,
        "by_source": by_source,
        "rows": rows,
    }


def write_eval_report(out_dir: Path, args, n_images: int, metrics: dict, selected_strategy: str, proto_acc: float, text_acc: float, candidate_scores: dict, loo_acc: float):
    out_jsonl = out_dir / f"vision_eval_visual_group_prototypes_{SUFFIX}.jsonl"
    with out_jsonl.open("w") as f:
        for row in metrics["rows"]:
            f.write(json.dumps(row) + "\n")

    note = f"""# data/processed — visual_group prototype evaluation

Generated by `{Path(__file__).name}` in the **sirkulab-mero** app repo.
Re-run the script to regenerate.

## `vision_eval_visual_group_prototypes_{SUFFIX}.jsonl`
One JSON object per image:
- `image` — path relative to `{args.images_subdir}/`
- `ground_truth` — expected `visual_group` (`null` if undeterminable)
- `gt_source` — `db` (exact app-DB latin/common-name join) · `class_map`
  (unambiguous taxonomic-class folder) · `unknown` (excluded from accuracy)
- `prototype_prediction` — prototype matcher result: `{{label, score}}`
- `text_prediction` — current label-text baseline: `{{label, score}}`
- `correct` — per matcher, whether the prediction matched ground truth

## This run
- images scored: {n_images} (deduped) · ground-truthed: {metrics["evaluated"]}
  (db={metrics["by_source"]["db"]}, class_map={metrics["by_source"]["class_map"]}, unknown={metrics["by_source"]["unknown"]})
- **prototype accuracy (leave-one-out CV — honest)**: {loo_acc:.1%}
- prototype accuracy (resubstitution — optimistic, train==test): {proto_acc:.1%}
- text baseline (resubstitution): {text_acc:.1%}
- **selected strategy** (by LOO-CV): `{selected_strategy}`

The shipped prototypes are built from **all** labeled images; LOO-CV is the
held-out estimate of how they generalize. Resubstitution evaluates on the same
images used to build the prototypes, so it overstates accuracy.

## Candidate strategies (leave-one-out accuracy)
{chr(10).join(f"- {name}: {score:.1%}" for name, score in candidate_scores.items())}
"""
    readme_path = out_dir / f"README_prototypes_{SUFFIX}.md"
    summary_path = out_dir / f"summary_prototypes_{SUFFIX}.json"
    summary = {
        "display_name": DISPLAY_NAME,
        "suffix": SUFFIX,
        "images_scored": n_images,
        "ground_truthed": metrics["evaluated"],
        "source_counts": metrics["by_source"],
        "selected_strategy": selected_strategy,
        "prototype_loo_accuracy": loo_acc,
        "prototype_resub_accuracy": proto_acc,
        "text_resub_accuracy": text_acc,
        "candidate_loo_accuracy": candidate_scores,
    }
    readme_path.write_text(note)
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nWrote {out_jsonl}")
    print(f"Wrote {readme_path}")
    print(f"Wrote {summary_path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--output", default=str(APP_REPO / f"assets/models/visual_group_prototypes_{SUFFIX}.pb"))
    ap.add_argument("--text-embeddings", default=str(APP_REPO / f"assets/models/attribute_embeddings_{SUFFIX}.json"))
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--max-per-group", type=int, default=0,
                    help="cap labeled images per visual_group (0 = use all)")
    ap.add_argument("--min-per-group", type=int, default=1,
                    help="skip groups with fewer than this many labeled images")
    ap.add_argument("--include-examples", type=int, default=3,
                    help="store up to this many example image paths per group")
    ap.add_argument("--strategy", default="auto",
                    choices=("auto",) + SUPPORTED_STRATEGIES,
                    help="prototype aggregation strategy (auto picks the best eval score)")
    args = ap.parse_args()

    data_repo = Path(args.data_repo)
    img_root = data_repo / args.images_subdir
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_dir = data_repo / "data" / "processed"
    out_dir.mkdir(parents=True, exist_ok=True)

    db_lut = load_db_lookup(Path(args.db))
    samples = collect_samples(img_root, db_lut)
    if not samples:
        raise SystemExit(f"No labeled images found under {img_root}")

    print(f"Loading {DISPLAY_NAME}: {args.hf_model}")
    enc = load_bioclip25_vith14(args.hf_model)
    print(f"Embedding {len(samples)} unique images …")
    embed_samples(enc, samples)

    grouped = group_samples(samples)
    if not grouped:
        raise SystemExit("No labeled samples were ground-truthed; cannot build prototypes.")

    text_emb_map = load_text_baseline(Path(args.text_embeddings))
    candidate_order = [args.strategy] if args.strategy != "auto" else list(SUPPORTED_STRATEGIES)
    group_labels = sorted(grouped)
    missing_text_labels = [label for label in group_labels if label not in text_emb_map]
    if missing_text_labels:
        raise SystemExit(
            "Text embedding asset is missing visual_group labels: "
            + ", ".join(missing_text_labels)
        )
    text_labels = group_labels
    text_embs = l2(np.asarray([text_emb_map[label] for label in text_labels], dtype=np.float32))

    print(f"{'strategy':12} {'LOO-cv':>8} {'resub':>8}  (LOO = honest; resub = optimistic)")
    candidate_results = []
    for strategy in candidate_order:
        prototypes = build_prototypes(grouped, strategy, args.include_examples)
        proto_labels = [row["label"] for row in prototypes]
        proto_embs = l2(np.asarray([row["emb"] for row in prototypes], dtype=np.float32))
        metrics = evaluate(samples, proto_labels, proto_embs, text_labels, text_embs)
        resub_acc = metrics["proto_correct"] / metrics["evaluated"] if metrics["evaluated"] else 0.0
        loo_acc, loo_correct, loo_total = leave_one_out_accuracy(grouped, strategy)
        candidate_results.append(
            {
                "strategy": strategy,
                "accuracy": loo_acc,          # honest metric → drives selection
                "resub_accuracy": resub_acc,  # optimistic (train==test)
                "loo_correct": loo_correct,
                "loo_total": loo_total,
                "prototypes": prototypes,
                "metrics": metrics,
            }
        )
        print(f"{strategy:12} {loo_acc:8.1%} {resub_acc:8.1%}  "
              f"(LOO {loo_correct}/{loo_total})")

    # Select by leave-one-out (generalization), not resubstitution (memorization).
    selected = max(candidate_results, key=lambda row: row["accuracy"])
    selected_strategy = selected["strategy"]
    prototypes = selected["prototypes"]
    metrics = selected["metrics"]
    proto_labels = [row["label"] for row in prototypes]
    proto_embs = l2(np.asarray([row["emb"] for row in prototypes], dtype=np.float32))
    proto_acc = metrics["proto_correct"] / metrics["evaluated"] if metrics["evaluated"] else 0.0
    text_acc = metrics["text_correct"] / metrics["evaluated"] if metrics["evaluated"] else 0.0
    candidate_scores = {row["strategy"]: row["accuracy"] for row in candidate_results}
    candidate_score_rows = [
        {"strategy": row["strategy"], "accuracy": row["accuracy"]}
        for row in candidate_results
    ]

    payload = {
        "meta": {
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "source_repo": str(data_repo),
            "images_subdir": args.images_subdir,
            "db": str(Path(args.db)),
            "hf_model": args.hf_model,
            "input_size": getattr(enc, "input_size", INPUT_SIZE),
            "prototype_method": selected_strategy,
            "max_per_group": args.max_per_group,
            "min_per_group": args.min_per_group,
            "groups": len(prototypes),
            "images_used": len(samples),
            "text_baseline_accuracy": round(float(text_acc), 6),
            "candidate_scores": candidate_score_rows,
        },
        "visual_group": prototypes,
    }

    loo_acc = selected["accuracy"]
    out_path.write_bytes(serialize_visual_group_prototypes(payload))
    print(f"\nWrote {out_path}")
    print(f"Groups: {len(prototypes)} | images used: {len(samples)}")
    print(f"Selected strategy: {selected_strategy} (by leave-one-out)")
    print(f"Prototype LOO accuracy:   {loo_acc:.1%}   ← honest (generalization)")
    print(f"Prototype resub accuracy: {proto_acc:.1%}   (train==test; optimistic)")
    print(f"Text baseline (resub):    {text_acc:.1%}")

    write_eval_report(out_dir, args, len(samples), metrics, selected_strategy,
                      proto_acc, text_acc, candidate_scores, loo_acc)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
