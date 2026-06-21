#!/usr/bin/env python3
"""Evaluate the shipped vision output with the exported prototype asset.

This simulates the app's current `extract_visual_features` path:
- `color`, `body_shape`, `distinctive_marks`, `texture`, `size_class`,
  `pattern` use the shipped text-embedding asset.
- `visual_group` uses the exported protobuf prototype asset.

The script compares that combined output against a baseline where `visual_group`
still uses the text-embedding asset, then writes per-image JSONL and a summary
note in the sibling `sirkulab-mero-data` repo.

Outputs:
  - `<data-repo>/data/processed/vision_eval_combined_visual_bioclip2.jsonl`
  - `<data-repo>/data/processed/README_combined_vision_bioclip2.md`
  - `<data-repo>/data/processed/summary_combined_vision_bioclip2.json`

USAGE
-----
  .venv-export/bin/python scripts/smaller-footprint-pipeline/comparison/eval_combined_vision_bioclip2.py
  #   --data-repo ../sirkulab-mero-data
  #   --limit 40
"""

from __future__ import annotations

import argparse
import json
import math
import sqlite3
import struct
import re
from collections import defaultdict
from pathlib import Path

import numpy as np
from PIL import Image

from export_vision_model_bioclip2 import DISPLAY_NAME, HF_MODEL, INPUT_SIZE, SUFFIX, load_bioclip2


HERE = Path(__file__).resolve()
APP_REPO = HERE.parents[3]
WORKDIR = HERE.parents[4]
DATA_REPO_DEFAULT = WORKDIR / "sirkulab-mero-data"

MEAN = np.array([0.485, 0.456, 0.406], np.float32)
STD = np.array([0.229, 0.224, 0.225], np.float32)

ATTRS = (
    "color",
    "body_shape",
    "distinctive_marks",
    "texture",
    "size_class",
    "pattern",
    "visual_group",
)

VF_KEYS = ("color", "body_shape", "distinctive_marks", "texture", "size_class", "pattern")
VF_WEIGHTS = {
    "distinctive_marks": 5.0,
    "pattern": 4.0,
    "color": 4.0,
    "body_shape": 3.0,
    "texture": 1.0,
    "size_class": 1.0,
}
TAX_BOOST = 2.0

_SYNONYMS = {
    "stripes": "striped",
    "striping": "striped",
    "stripy": "striped",
    "golden": "yellow",
    "bluish": "blue",
    "reddish": "red",
    "greenish": "green",
    "brownish": "brown",
    "whitish": "white",
    "blackish": "black",
    "greyish": "grey",
    "grayish": "grey",
    "yellowish": "yellow",
    "orangish": "orange",
    "purplish": "purple",
    "pinkish": "pink",
    "spotted": "spot",
    "spotty": "spot",
}
_STOP_WORDS = {"and", "with", "the", "appears", "somewhat", "but", "on", "of", "in"}

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}

# Ground-truth fallback: unambiguous taxonomic-class folder → visual_group.
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


def load_db_lookup(db_path: Path) -> dict[str, dict[str, str]]:
    """Return `{normalized species/common name: full species row}`."""
    con = sqlite3.connect(str(db_path))
    cur = con.execute(
        """
        SELECT latin_name, common_name, color, body_shape, distinctive_marks,
               texture, size_class, pattern, visual_group
        FROM species
        WHERE TRIM(visual_group) != ''
        """
    )
    lut: dict[str, dict[str, str]] = {}
    for row in cur:
        record = {
            "latin_name": row[0] or "",
            "common_name": row[1] or "",
            "color": row[2] or "",
            "body_shape": row[3] or "",
            "distinctive_marks": row[4] or "",
            "texture": row[5] or "",
            "size_class": row[6] or "",
            "pattern": row[7] or "",
            "visual_group": row[8] or "",
        }
        for col in ("latin_name", "common_name"):
            name = record[col].strip().lower()
            if name:
                lut[name] = record
    con.close()
    return lut


def load_db_rows(db_path: Path) -> list[dict[str, str]]:
    con = sqlite3.connect(str(db_path))
    cur = con.execute(
        """
        SELECT id, common_name, latin_name, kingdom, class, "order", family, genus,
               visual_features, visual_group, color, body_shape, distinctive_marks,
               texture, size_class, pattern, visual_blob
        FROM species
        """
    )
    rows = []
    for row in cur:
        rows.append(
            {
                "id": row[0],
                "common_name": row[1] or "",
                "latin_name": row[2] or "",
                "kingdom": row[3] or "",
                "class": row[4] or "",
                "order": row[5] or "",
                "family": row[6] or "",
                "genus": row[7] or "",
                "visual_features": row[8] or "",
                "visual_group": row[9] or "",
                "color": row[10] or "",
                "body_shape": row[11] or "",
                "distinctive_marks": row[12] or "",
                "texture": row[13] or "",
                "size_class": row[14] or "",
                "pattern": row[15] or "",
                "visual_blob": row[16] or "",
            }
        )
    con.close()
    return rows


def load_text_vocab(path: Path) -> dict[str, list[dict[str, np.ndarray]]]:
    with path.open() as f:
        obj = json.load(f)
    return {
        attr: [
            {"label": row["label"], "emb": np.asarray(row["emb"], dtype=np.float32)}
            for row in rows
        ]
        for attr, rows in obj.items()
    }


def _varint(data: bytes, offset: int) -> tuple[int, int]:
    result = 0
    shift = 0
    while True:
        if offset >= len(data):
            raise ValueError("Unexpected end of protobuf varint")
        b = data[offset]
        offset += 1
        result |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return result, offset
        shift += 7
        if shift > 63:
            raise ValueError("Protobuf varint overflow")


def _read_bytes(data: bytes, offset: int) -> tuple[bytes, int]:
    length, offset = _varint(data, offset)
    end = offset + length
    if end > len(data):
      raise ValueError("Truncated protobuf length-delimited field")
    return data[offset:end], end


def _read_string(data: bytes, offset: int) -> tuple[str, int]:
    raw, offset = _read_bytes(data, offset)
    return raw.decode("utf-8", errors="replace"), offset


def _read_float(data: bytes, offset: int) -> tuple[float, int]:
    end = offset + 4
    if end > len(data):
        raise ValueError("Truncated protobuf float")
    return struct.unpack("<f", data[offset:end])[0], end


def _read_double(data: bytes, offset: int) -> tuple[float, int]:
    end = offset + 8
    if end > len(data):
        raise ValueError("Truncated protobuf double")
    return struct.unpack("<d", data[offset:end])[0], end


def _tokens(text: str) -> set[str]:
    return {
        (_SYNONYMS.get(tok, tok)).lower().strip()
        for tok in re.split(r"\W+", text.lower())
        if len(tok) > 1 and tok not in _STOP_WORDS
    }


def _dice(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    inter = len(a.intersection(b))
    return 0.0 if inter == 0 else (2.0 * inter) / (len(a) + len(b))


def _skip_field(data: bytes, offset: int, wire_type: int) -> int:
    if wire_type == 0:
        _, offset = _varint(data, offset)
        return offset
    if wire_type == 1:
        return offset + 8
    if wire_type == 2:
        raw, offset = _read_bytes(data, offset)
        return offset
    if wire_type == 5:
        return offset + 4
    raise ValueError(f"Unsupported protobuf wire type: {wire_type}")


def load_prototypes(path: Path) -> list[dict]:
    raw = path.read_bytes()
    offset = 0
    prototypes: list[dict] = []
    while offset < len(raw):
        tag, offset = _varint(raw, offset)
        field_no = tag >> 3
        wire_type = tag & 0x7
        if field_no != 2 or wire_type != 2:
            offset = _skip_field(raw, offset, wire_type)
            continue
        msg, offset = _read_bytes(raw, offset)
        proto = {"label": "", "count": 0, "emb": [], "examples": []}
        moff = 0
        while moff < len(msg):
            tag, moff = _varint(msg, moff)
            fno = tag >> 3
            wty = tag & 0x7
            if fno == 1 and wty == 2:
                proto["label"], moff = _read_string(msg, moff)
            elif fno == 2 and wty == 0:
                proto["count"], moff = _varint(msg, moff)
            elif fno == 3 and wty == 2:
                packed, moff = _read_bytes(msg, moff)
                if len(packed) % 4 != 0:
                    raise ValueError("Packed float field has invalid length")
                emb = []
                for i in range(0, len(packed), 4):
                    emb.append(struct.unpack("<f", packed[i : i + 4])[0])
                proto["emb"] = emb
            elif fno == 3 and wty == 5:
                val, moff = _read_float(msg, moff)
                proto["emb"].append(val)
            elif fno == 4 and wty == 2:
                ex, moff = _read_string(msg, moff)
                proto["examples"].append(ex)
            else:
                moff = _skip_field(msg, moff, wty)
        prototypes.append(proto)
    return prototypes


def ground_truth(rel_path: Path, db_lut: dict[str, dict[str, str]]):
    """Return `(row, source)` or `(None, 'unknown')`."""
    parts = list(rel_path.parts[:-1])
    for folder in reversed(parts):
        name = folder.replace("_", " ").strip().lower()
        if name in db_lut:
            return db_lut[name], "db"
    for folder in parts:
        if folder.lower() in CLASS_MAP:
            return {"visual_group": CLASS_MAP[folder.lower()]}, "class_map"
    return None, "unknown"


def build_fts_query(traits: dict[str, str]) -> tuple[str, dict[str, set[str]], float]:
    query_parts = []
    obs_tokens = {}
    max_score = 0.0
    for k in VF_KEYS:
        v = (traits.get(k) or "").strip()
        if not v:
            continue
        query_parts.append(v)
        obs_tokens[k] = _tokens(v)
        max_score += VF_WEIGHTS.get(k, 1.0)
    clean_terms = (
        str(tok)
        for part in query_parts
        for tok in re.split(r"\s+", re.sub(r"[^\w\s]", " ", part))
    )
    normalized = {
        (_SYNONYMS.get(tok.lower(), tok.lower()))
        for tok in clean_terms
        if len(tok) > 1 and tok.lower() not in _STOP_WORDS
    }
    fts_query = " OR ".join(f'"{tok}"*' for tok in sorted(normalized))
    return fts_query, obs_tokens, max_score


def rank_species(
    db_conn: sqlite3.Connection,
    db_rows_by_id: dict[int, dict[str, str]],
    traits: dict[str, str],
    tax: dict[str, str],
):
    fts_query, obs_tokens, max_score = build_fts_query(traits)
    visual_group = (traits.get("visual_group") or "").strip()
    if not fts_query and not visual_group:
        return []

    if fts_query:
        if visual_group:
            rows = db_conn.execute(
                'SELECT s.* FROM species s JOIN species_fts f ON s.id = f.rowid '
                'WHERE species_fts MATCH ?1 AND s.visual_group = ?2 LIMIT ?3',
                (fts_query, visual_group, 42),
            ).fetchall()
            if not rows:
                rows = db_conn.execute(
                    'SELECT s.* FROM species s WHERE s.visual_group = ?1 LIMIT ?2',
                    (visual_group, 42),
                ).fetchall()
        else:
            rows = db_conn.execute(
                'SELECT s.* FROM species s JOIN species_fts f ON s.id = f.rowid '
                'WHERE species_fts MATCH ?1 LIMIT ?2',
                (fts_query, 42),
            ).fetchall()
    else:
        rows = db_conn.execute(
            'SELECT s.* FROM species s WHERE s.visual_group = ?1 LIMIT ?2',
            (visual_group, 42),
        ).fetchall()

    if not rows:
        return []

    scored = []
    for row in rows:
        data = db_rows_by_id[row[0]]
        score = 0.0
        for k in VF_KEYS:
            obs = obs_tokens.get(k)
            if obs is None:
                continue
            stored = (data.get(k) or "").strip()
            stored_tokens = _tokens(stored or data.get("visual_blob") or "")
            score += _dice(obs, stored_tokens) * VF_WEIGHTS.get(k, 1.0)
        if tax.get("family") and data.get("family", "").lower() == tax["family"].lower():
            score += TAX_BOOST
        if tax.get("genus") and data.get("genus", "").lower() == tax["genus"].lower():
            score += TAX_BOOST * 0.5
        if tax.get("class") and data.get("class", "").lower() == tax["class"].lower():
            score += TAX_BOOST * 0.3
        if tax.get("order") and data.get("order", "").lower() == tax["order"].lower():
            score += TAX_BOOST * 0.2
        confidence = (score / max_score * 100.0) if max_score > 0 else 0.0
        scored.append({"row": data, "score": score, "confidence": max(0.0, min(100.0, confidence))})
    scored.sort(key=lambda r: r["score"], reverse=True)
    return scored


def collect_images(img_root: Path):
    images = []
    seen: set[tuple[str, int]] = set()
    for path in sorted(img_root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in IMAGE_EXTS:
            continue
        key = (path.name, path.stat().st_size)
        if key in seen:
            continue
        seen.add(key)
        images.append(path)
    return images


def predict_attr(attr: str, emb: np.ndarray, text_vocab, proto_vocab):
    if attr == "visual_group":
        labels = [row["label"] for row in proto_vocab]
        embs = l2(np.asarray([row["emb"] for row in proto_vocab], dtype=np.float32))
    else:
        labels = [row["label"] for row in text_vocab[attr]]
        embs = l2(np.asarray([row["emb"] for row in text_vocab[attr]], dtype=np.float32))
    scores = embs @ emb
    idx = int(scores.argmax())
    return labels[idx], float(scores[idx])


def predict_combined(emb: np.ndarray, text_vocab, proto_vocab):
    out = {}
    for attr in ATTRS:
        label, score = predict_attr(attr, emb, text_vocab, proto_vocab)
        out[attr] = {"label": label, "score": round(score, 4)}
    return out


def predict_text_baseline(emb: np.ndarray, text_vocab):
    out = {}
    for attr in ATTRS:
        labels = [row["label"] for row in text_vocab[attr]]
        embs = l2(np.asarray([row["emb"] for row in text_vocab[attr]], dtype=np.float32))
        scores = embs @ emb
        idx = int(scores.argmax())
        out[attr] = {"label": labels[idx], "score": round(float(scores[idx]), 4)}
    return out


def as_trait_labels(predictions: dict[str, dict[str, object]]) -> dict[str, str]:
    return {attr: str(value.get("label", "")) for attr, value in predictions.items()}


def trait_query_payload(traits: dict[str, str]) -> dict[str, object]:
    fts_query, _, _ = build_fts_query(traits)
    return {
        "traits": {k: (traits.get(k) or "") for k in VF_KEYS},
        "fts_query": fts_query,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-repo", default=str(DATA_REPO_DEFAULT))
    ap.add_argument("--images-subdir", default="data/raw/species_data_img")
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument(
        "--embeddings",
        default=str(APP_REPO / f"assets/models/attribute_embeddings_{SUFFIX}.json"),
    )
    ap.add_argument(
        "--prototypes",
        default=str(APP_REPO / f"assets/models/visual_group_prototypes_{SUFFIX}.pb"),
    )
    ap.add_argument("--hf-model", default=HF_MODEL)
    ap.add_argument("--limit", type=int, default=0, help="cap images (quick test)")
    args = ap.parse_args()

    data_repo = Path(args.data_repo)
    img_root = data_repo / args.images_subdir
    out_dir = data_repo / "data" / "processed"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_jsonl = out_dir / f"vision_eval_combined_visual_{SUFFIX}.jsonl"

    text_vocab = load_text_vocab(Path(args.embeddings))
    proto_vocab = load_prototypes(Path(args.prototypes))
    if not proto_vocab:
        raise SystemExit(f"No prototypes found in {args.prototypes}")

    db_lut = load_db_lookup(Path(args.db))
    db_conn = sqlite3.connect(str(args.db))
    db_rows = load_db_rows(Path(args.db))
    db_rows_by_id = {row["id"]: row for row in db_rows}
    images = collect_images(img_root)
    if args.limit:
        images = images[: args.limit]

    print(f"Loading {DISPLAY_NAME}: {args.hf_model}")
    enc = load_bioclip2(args.hf_model)
    print(f"Scoring {len(images)} unique images ...")

    by_source = defaultdict(int)
    per_attr_combined = {attr: 0 for attr in ATTRS}
    per_attr_text = {attr: 0 for attr in ATTRS}
    exact_combined = 0
    exact_text = 0
    rank1_combined = 0
    rank1_text = 0
    rank5_combined = 0
    rank5_text = 0
    rr_combined = 0.0
    rr_text = 0.0
    evaluated = 0
    rows = []

    with out_jsonl.open("w") as f:
        for path in images:
            rel = path.relative_to(img_root)
            gt_row, src = ground_truth(rel, db_lut)
            by_source[src] += 1
            emb = image_embedding(enc, str(path))

            combined = predict_combined(emb, text_vocab, proto_vocab)
            text_only = predict_text_baseline(emb, text_vocab)
            combined_traits = as_trait_labels(combined)
            text_traits = as_trait_labels(text_only)
            combined_query = trait_query_payload(combined_traits)
            text_query = trait_query_payload(text_traits)
            tax = {
                "class": (gt_row or {}).get("class", ""),
                "order": (gt_row or {}).get("order", ""),
                "family": (gt_row or {}).get("family", ""),
                "genus": (gt_row or {}).get("genus", ""),
            }
            combined_ranked = rank_species(db_conn, db_rows_by_id, combined_traits, tax)
            text_ranked = rank_species(db_conn, db_rows_by_id, text_traits, tax)

            row = {
                "image": str(rel),
                "gt_source": src,
                "ground_truth": gt_row["latin_name"] if src == "db" and gt_row else None,
                "predictions": {
                    "combined": combined,
                    "text_baseline": text_only,
                },
                "retrieval": {
                    "combined": {
                        "input": combined_query,
                        "rank1": combined_ranked[0]["row"]["latin_name"] if combined_ranked else None,
                        "top5": [cand["row"]["latin_name"] for cand in combined_ranked[:5]],
                    },
                    "text_baseline": {
                        "input": text_query,
                        "rank1": text_ranked[0]["row"]["latin_name"] if text_ranked else None,
                        "top5": [cand["row"]["latin_name"] for cand in text_ranked[:5]],
                    },
                },
            }

            if src == "db" and gt_row is not None:
                evaluated += 1
                truth = {attr: (gt_row.get(attr) or "") for attr in ATTRS}
                row["correct"] = {
                    "combined": {},
                    "text_baseline": {},
                    "all_attrs": {
                        "combined": True,
                        "text_baseline": True,
                    },
                }
                for attr in ATTRS:
                    c_hit = combined[attr]["label"] == truth[attr]
                    t_hit = text_only[attr]["label"] == truth[attr]
                    row["correct"]["combined"][attr] = c_hit
                    row["correct"]["text_baseline"][attr] = t_hit
                    per_attr_combined[attr] += int(c_hit)
                    per_attr_text[attr] += int(t_hit)
                    row["correct"]["all_attrs"]["combined"] &= c_hit
                    row["correct"]["all_attrs"]["text_baseline"] &= t_hit
                exact_combined += int(row["correct"]["all_attrs"]["combined"])
                exact_text += int(row["correct"]["all_attrs"]["text_baseline"])

                gt_name = gt_row["latin_name"]
                combined_rank = next(
                    (i for i, cand in enumerate(combined_ranked, start=1) if cand["row"]["latin_name"] == gt_name),
                    None,
                )
                text_rank = next(
                    (i for i, cand in enumerate(text_ranked, start=1) if cand["row"]["latin_name"] == gt_name),
                    None,
                )
                row["retrieval"]["combined"]["rank"] = combined_rank
                row["retrieval"]["text_baseline"]["rank"] = text_rank
                if combined_rank == 1:
                    rank1_combined += 1
                if combined_rank is not None and combined_rank <= 5:
                    rank5_combined += 1
                if combined_rank is not None:
                    rr_combined += 1.0 / combined_rank
                if text_rank == 1:
                    rank1_text += 1
                if text_rank is not None and text_rank <= 5:
                    rank5_text += 1
                if text_rank is not None:
                    rr_text += 1.0 / text_rank
            rows.append(row)
            f.write(json.dumps(row) + "\n")

    combined_attr_acc = {
        attr: (per_attr_combined[attr] / evaluated if evaluated else 0.0) for attr in ATTRS
    }
    text_attr_acc = {
        attr: (per_attr_text[attr] / evaluated if evaluated else 0.0) for attr in ATTRS
    }
    combined_mean = sum(combined_attr_acc.values()) / len(ATTRS) if ATTRS else 0.0
    text_mean = sum(text_attr_acc.values()) / len(ATTRS) if ATTRS else 0.0
    combined_exact = exact_combined / evaluated if evaluated else 0.0
    text_exact = exact_text / evaluated if evaluated else 0.0
    combined_rank1 = rank1_combined / evaluated if evaluated else 0.0
    text_rank1 = rank1_text / evaluated if evaluated else 0.0
    combined_rank5 = rank5_combined / evaluated if evaluated else 0.0
    text_rank5 = rank5_text / evaluated if evaluated else 0.0
    combined_mrr = rr_combined / evaluated if evaluated else 0.0
    text_mrr = rr_text / evaluated if evaluated else 0.0

    print(
        f"\nCombined output over {evaluated} db-ground-truthed images "
        f"(db={by_source['db']}, class_map={by_source['class_map']}, unknown={by_source['unknown']}):"
    )
    print(
        f"  retrieval rank-1 combined: {combined_rank1:.1%} "
        f"rank-5: {combined_rank5:.1%} MRR: {combined_mrr:.3f}"
    )
    print(
        f"  retrieval rank-1 baseline: {text_rank1:.1%} "
        f"rank-5: {text_rank5:.1%} MRR: {text_mrr:.3f}"
    )
    print(f"  exact-match combined: {combined_exact:.1%} ({exact_combined}/{evaluated})")
    print(f"  exact-match baseline: {text_exact:.1%} ({exact_text}/{evaluated})")
    print(f"  mean attr accuracy combined: {combined_mean:.1%}")
    print(f"  mean attr accuracy baseline: {text_mean:.1%}")
    print("  per-attribute combined accuracy:")
    for attr in ATTRS:
        print(
            f"    - {attr:17} {combined_attr_acc[attr]:6.1%} "
            f"(baseline {text_attr_acc[attr]:6.1%})"
        )

    note = f"""# data/processed — combined vision evaluation

Generated by `{Path(__file__).name}` in the **sirkulab-mero** app repo.
Re-run the script to regenerate.

## `vision_eval_combined_visual_{SUFFIX}.jsonl`
One JSON object per image:
- `image` — path relative to `{args.images_subdir}/`
- `ground_truth` — ground-truth scientific name for `db`-matched samples, else `null`
- `predictions.combined` — shipped app path using text embeddings plus protobuf prototypes
- `predictions.text_baseline` — same path, but `visual_group` still uses text embeddings
- `retrieval` — rank-1 and top-5 species candidates for both modes, plus the
  exact trait payload and FTS query fed into SQLite
- `correct` — per-attribute booleans for both modes, plus `all_attrs`

## This run
- images scored: {len(images)} (deduped) · db-ground-truthed: {evaluated}
  (db={by_source['db']}, class_map={by_source['class_map']}, unknown={by_source['unknown']})
- **retrieval rank-1 combined**: {combined_rank1:.1%}
- **retrieval rank-5 combined**: {combined_rank5:.1%}
- **retrieval MRR combined**: {combined_mrr:.3f}
- **retrieval rank-1 baseline**: {text_rank1:.1%}
- **retrieval rank-5 baseline**: {text_rank5:.1%}
- **retrieval MRR baseline**: {text_mrr:.3f}
- **exact-match combined**: {combined_exact:.1%}
- **exact-match baseline**: {text_exact:.1%}
- **mean attr accuracy combined**: {combined_mean:.1%}
- **mean attr accuracy baseline**: {text_mean:.1%}

## Per-attribute accuracy
{chr(10).join(f"- {attr}: combined {combined_attr_acc[attr]:.1%} | baseline {text_attr_acc[attr]:.1%}" for attr in ATTRS)}
"""
    summary_path = out_dir / f"summary_combined_vision_{SUFFIX}.json"
    summary = {
        "display_name": DISPLAY_NAME,
        "suffix": SUFFIX,
        "images_scored": len(images),
        "db_ground_truthed": evaluated,
        "source_counts": dict(by_source),
        "combined": {
            "retrieval_rank1": combined_rank1,
            "retrieval_rank5": combined_rank5,
            "retrieval_mrr": combined_mrr,
            "exact_match": combined_exact,
            "mean_attr_accuracy": combined_mean,
            "per_attr_accuracy": combined_attr_acc,
        },
        "baseline": {
            "retrieval_rank1": text_rank1,
            "retrieval_rank5": text_rank5,
            "retrieval_mrr": text_mrr,
            "exact_match": text_exact,
            "mean_attr_accuracy": text_mean,
            "per_attr_accuracy": text_attr_acc,
        },
    }
    (out_dir / f"README_combined_vision_{SUFFIX}.md").write_text(note)
    summary_path.write_text(json.dumps(summary, indent=2))
    print(f"\nWrote {out_jsonl}")
    print(f"Wrote {out_dir / f'README_combined_vision_{SUFFIX}.md'}")
    print(f"Wrote {summary_path}")
    db_conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
