#!/usr/bin/env python3
"""
Build the pre-computed species SQLite database from species_data.zip
and (optionally) visual_features_embeddings.json.

Usage:
    python tool/build_species_db.py \
        --zip assets/data/species_data.zip \
        --embeddings build/app/intermediates/flutter/release/flutter_assets/assets/data/visual_features_embeddings.json \
        --output assets/data/species_retrieval.db
"""

import argparse
import json
import os
import sqlite3
import sys
import zipfile
from typing import Any, Dict, List, Optional

# ── Visual feature field keys (from the structured embeddings JSON) ──
VF_KEYS = ["color", "body_shape", "distinctive_marks", "texture", "size_class", "pattern"]

# ── All top-level fields from the species JSON ──
ALL_FIELDS = [
    "common_name",
    "latin_name",
    "kingdom",
    "class",        # "class" is a SQL reserved word — quoted in DDL
    "order",
    "family",
    "genus",
    "visual_features",
    "description",
    "fun_fact",
    "ecosystem_role",
    "what_students_can_do",
    "human_connection",
    "threats",
    "habitat",
    "habitat_tags",
    "conservation_status",
    "population_estimate",
    "population_estimate_source_uri",
]


def load_species_from_zip(zip_path: str) -> List[Dict[str, Any]]:
    """Read all JSON files from species_data.zip and return a list of dicts."""
    species = []
    with zipfile.ZipFile(zip_path) as z:
        for name in z.namelist():
            if not name.endswith(".json"):
                continue
            data = json.loads(z.read(name))
            species.append(data)
    return species


def load_structured_vf(embeddings_path: Optional[str]) -> Dict[str, Dict[str, str]]:
    """
    Load the structured visual features from the embeddings JSON.
    Returns a dict keyed by latin_name (lowercased).
    """
    if embeddings_path is None or not os.path.isfile(embeddings_path):
        return {}

    with open(embeddings_path) as f:
        data = json.load(f)

    result: Dict[str, Dict[str, str]] = {}
    for sp in data.get("species", []):
        latin = (sp.get("latin_name") or "").strip().lower()
        if not latin:
            continue
        raw_vf = sp.get("visual_features", {})
        if isinstance(raw_vf, dict):
            result[latin] = {k: (raw_vf.get(k) or "") for k in VF_KEYS}
    return result


def json_val(val: Any) -> str:
    """Serialise a JSON value to a JSON string for TEXT storage."""
    return json.dumps(val, ensure_ascii=False) if val is not None else ""


def build_visual_blob(species: Dict[str, Any],
                      structured_vf: Optional[Dict[str, str]]) -> str:
    """
    Build a consolidated visual description blob for FTS5 indexing.

    If structured visual features are available (color, body_shape, …),
    concatenate their values. Otherwise fall back to the raw visual_features
    description text.
    """
    if structured_vf:
        parts = [v for v in structured_vf.values() if v.strip()]
        if parts:
            return "  ".join(parts)
    raw = species.get("visual_features")
    return raw.strip() if isinstance(raw, str) and raw.strip() else ""


def build_db(zip_path: str,
             embeddings_path: Optional[str],
             output_path: str) -> int:
    """Build the SQLite DB and return the number of species inserted."""

    if os.path.exists(output_path):
        os.remove(output_path)

    conn = sqlite3.connect(output_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=OFF;")  # faster offline build

    cur = conn.cursor()

    # ── Schema ──────────────────────────────────────────────────────────
    # Single table mirroring all JSON fields.
    cur.execute("""
        CREATE TABLE species (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            common_name     TEXT NOT NULL DEFAULT '',
            latin_name      TEXT NOT NULL DEFAULT '',
            kingdom         TEXT NOT NULL DEFAULT '',
            "class"         TEXT NOT NULL DEFAULT '',
            "order"         TEXT NOT NULL DEFAULT '',
            family          TEXT NOT NULL DEFAULT '',
            genus           TEXT NOT NULL DEFAULT '',
            visual_features TEXT NOT NULL DEFAULT '',
            description     TEXT NOT NULL DEFAULT '',

            fun_fact                TEXT NOT NULL DEFAULT '[]',
            ecosystem_role          TEXT NOT NULL DEFAULT '',
            what_students_can_do    TEXT NOT NULL DEFAULT '[]',
            human_connection        TEXT NOT NULL DEFAULT '',
            threats                 TEXT NOT NULL DEFAULT '[]',
            habitat                 TEXT NOT NULL DEFAULT '',
            habitat_tags            TEXT NOT NULL DEFAULT '[]',
            conservation_status     TEXT NOT NULL DEFAULT '',
            population_estimate     TEXT NOT NULL DEFAULT '',
            population_estimate_source_uri TEXT NOT NULL DEFAULT '',

            -- Structured visual feature sub-fields (for weighted reranker).
            color              TEXT NOT NULL DEFAULT '',
            body_shape         TEXT NOT NULL DEFAULT '',
            distinctive_marks  TEXT NOT NULL DEFAULT '',
            texture            TEXT NOT NULL DEFAULT '',
            size_class         TEXT NOT NULL DEFAULT '',
            pattern            TEXT NOT NULL DEFAULT '',

            -- Consolidated FTS5 blob (built from structured fields or fallback).
            visual_blob        TEXT NOT NULL DEFAULT ''
        )
    """)

    # FTS5 on visual_blob with porter stemmer.
    cur.execute("""
        CREATE VIRTUAL TABLE species_fts USING fts5(
            visual_blob,
            content='species',
            content_rowid='id',
            tokenize='porter'
        )
    """)

    # ── Data ────────────────────────────────────────────────────────────
    species_list = load_species_from_zip(zip_path)
    structured_map = load_structured_vf(embeddings_path)

    inserted = 0
    for sp in species_list:
        latin = (sp.get("latin_name") or "").strip().lower()
        structured = structured_map.get(latin)

        blob = build_visual_blob(sp, structured)

        # Extract structured VF sub-fields.
        vf = {}
        if structured:
            vf = structured
        else:
            raw_vf = sp.get("visual_features")
            if isinstance(raw_vf, dict):
                for k in VF_KEYS:
                    vf[k] = (raw_vf.get(k) or "").strip()

        cur.execute(
            """
            INSERT INTO species (
                common_name, latin_name, kingdom, "class", "order",
                family, genus, visual_features, description,
                fun_fact, ecosystem_role, what_students_can_do,
                human_connection, threats, habitat, habitat_tags,
                conservation_status, population_estimate,
                population_estimate_source_uri,
                color, body_shape, distinctive_marks,
                texture, size_class, pattern,
                visual_blob
            ) VALUES (
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?, ?,
                ?, ?, ?, ?,
                ?, ?,
                ?,
                ?, ?, ?,
                ?, ?, ?,
                ?
            )
            """,
            (
                sp.get("common_name", ""),
                sp.get("latin_name", ""),
                sp.get("kingdom", ""),
                sp.get("class", ""),
                sp.get("order", ""),
                sp.get("family", ""),
                sp.get("genus", ""),
                sp.get("visual_features", ""),
                sp.get("description", ""),
                json_val(sp.get("fun_fact", [])),
                sp.get("ecosystem_role", ""),
                json_val(sp.get("what_students_can_do", [])),
                sp.get("human_connection", ""),
                json_val(sp.get("threats", [])),
                sp.get("habitat", ""),
                json_val(sp.get("habitat_tags", [])),
                sp.get("conservation_status", ""),
                sp.get("population_estimate", ""),
                sp.get("population_estimate_source_uri", ""),
                vf.get("color", ""),
                vf.get("body_shape", ""),
                vf.get("distinctive_marks", ""),
                vf.get("texture", ""),
                vf.get("size_class", ""),
                vf.get("pattern", ""),
                blob,
            ),
        )

        cid = cur.lastrowid
        cur.execute(
            "INSERT INTO species_fts(rowid, visual_blob) VALUES (?, ?)",
            (cid, blob),
        )
        inserted += 1

    conn.commit()

    # Set user_version for Drift compatibility (matches schemaVersion = 1).
    cur.execute("PRAGMA user_version = 1")
    conn.commit()

    # ── Verify ──────────────────────────────────────────────────────────
    total = cur.execute("SELECT COUNT(*) FROM species").fetchone()[0]
    with_vf = cur.execute(
        "SELECT COUNT(*) FROM species WHERE visual_blob != ''"
    ).fetchone()[0]

    print(f"✅  {total} species inserted ({with_vf} with visual_blob)")
    print(f"📁  Output: {os.path.abspath(output_path)}")
    print(f"💾  Size:   {os.path.getsize(output_path) / 1024:.1f} KB")

    conn.close()
    return total


def main():
    parser = argparse.ArgumentParser(
        description="Build the pre-computed species retrieval DB."
    )
    parser.add_argument(
        "--zip",
        default="assets/data/species_data.zip",
        help="Path to species_data.zip (default: assets/data/species_data.zip)",
    )
    parser.add_argument(
        "--embeddings",
        default=None,
        help=(
            "Optional path to visual_features_embeddings.json for structured "
            "visual feature fields"
        ),
    )
    parser.add_argument(
        "--output",
        default="assets/data/species_data.sqlite",
        help="Output path for the SQLite DB (default: assets/data/species_data.sqlite)",
    )
    args = parser.parse_args()

    if not os.path.isfile(args.zip):
        print(f"❌  Zip not found: {args.zip}")
        sys.exit(1)

    build_db(args.zip, args.embeddings, args.output)


if __name__ == "__main__":
    main()
