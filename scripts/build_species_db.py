#!/usr/bin/env python3
"""
Build the pre-computed species SQLite database from individual JSON files
under assets/data/species_data/, applying the same token normalisation that
the Dart reranker uses at query time so the FTS5 index and runtime queries
are consistent.

Usage:
    python tool/build_species_db.py \
        --data-dir assets/data/species_data \
        --output assets/data/species_data.sqlite
"""

import argparse
import json
import os
import re
import sqlite3
import sys

# ── Synonym map — MUST match lib/services/species_service.dart ──────────
_SYNONYMS = {
    "stripes": "striped",
    "striping": "striped",
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
    "stripy": "stripe",
}

_STOP_WORDS = frozenset(
    {"and", "with", "the", "appears", "somewhat", "but", "on", "of", "in"}
)

# ── Visual feature field keys ──────────────────────────────────────────
VF_KEYS = ["color", "body_shape", "distinctive_marks", "texture", "size_class", "pattern"]


def normalise_token(t: str) -> str:
    """Normalise a single token via synonym lookup."""
    t = t.lower()
    return _SYNONYMS.get(t, t)


def normalise_text(text: str) -> str:
    """
    Tokenise, synonym‑normalise, and rejoin.
    Removes stop‑words and single‑character tokens — same as Dart _tokens().
    """
    tokens = re.findall(r"\w+", text.lower())
    out = [
        normalise_token(t)
        for t in tokens
        if len(t) > 1 and t not in _STOP_WORDS
    ]
    return " ".join(out)


def json_val(val) -> str:
    """Serialise a list to a JSON string for TEXT storage."""
    return json.dumps(val, ensure_ascii=False) if val else "[]"


def build_visual_blob(species: dict) -> str:
    """
    Build a consolidated, synonym‑normalised visual description blob
    for FTS5 indexing — consistent with the Dart reranker's _tokens().
    """
    vf = species.get("visual_features", {})
    if not isinstance(vf, dict):
        vf = {}
    parts = []
    for k in VF_KEYS:
        raw = str(vf.get(k, "")).strip()
        if raw:
            parts.append(normalise_text(raw))
    return "  ".join(parts)


def walk_json_files(data_dir: str):
    """Yield every JSON file path under data_dir recursively."""
    for root, _dirs, files in os.walk(data_dir):
        for fname in files:
            if fname.endswith(".json"):
                yield os.path.join(root, fname)


def build_db(data_dir: str, output_path: str) -> int:
    """Build the SQLite DB and return the number of species inserted."""

    if os.path.exists(output_path):
        os.remove(output_path)

    conn = sqlite3.connect(output_path)
    conn.execute("PRAGMA journal_mode=WAL;")
    conn.execute("PRAGMA synchronous=OFF;")

    cur = conn.cursor()

    # ── Schema ──────────────────────────────────────────────────────────
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
            visual_group    TEXT NOT NULL DEFAULT '',
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

            -- Consolidated FTS5 blob (normalised at build time).
            visual_blob        TEXT NOT NULL DEFAULT ''
        )
    """)

    cur.execute("""
        CREATE VIRTUAL TABLE species_fts USING fts5(
            visual_blob,
            content='species',
            content_rowid='id',
            tokenize='porter'
        )
    """)

    # ── Data ────────────────────────────────────────────────────────────
    inserted = 0

    for filepath in sorted(walk_json_files(data_dir)):
        with open(filepath) as f:
            sp = json.load(f)

        blob = build_visual_blob(sp)

        vf = sp.get("visual_features", {})
        if not isinstance(vf, dict):
            vf = {}

        cur.execute(
            """
            INSERT INTO species (
                common_name, latin_name, kingdom, "class", "order",
                family, genus, visual_features, visual_group, description,
                fun_fact, ecosystem_role, what_students_can_do,
                human_connection, threats, habitat, habitat_tags,
                conservation_status, population_estimate,
                population_estimate_source_uri,
                color, body_shape, distinctive_marks,
                texture, size_class, pattern,
                visual_blob
            ) VALUES (
                ?, ?, ?, ?, ?,
                ?, ?, ?, ?, ?,
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
                json.dumps(vf),
                sp.get("visual_group", ""),
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

    # Set user_version for Drift compatibility (must match schemaVersion = 1).
    cur.execute("PRAGMA user_version = 1")
    conn.commit()

    total = cur.execute("SELECT COUNT(*) FROM species").fetchone()[0]
    print(f"✅  {total} species inserted")
    print(f"📁  Output: {os.path.abspath(output_path)}")
    print(f"💾  Size:   {os.path.getsize(output_path) / 1024:.1f} KB")

    conn.close()
    return total


def main():
    parser = argparse.ArgumentParser(
        description="Build the pre-computed species retrieval DB from JSON files."
    )
    parser.add_argument(
        "--data-dir",
        default="assets/data/species_data",
        help="Directory containing species JSON files",
    )
    parser.add_argument(
        "--output",
        default="assets/data/species_data.sqlite",
        help="Output path for the SQLite DB",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.data_dir):
        print(f"❌  Data dir not found: {args.data_dir}")
        sys.exit(1)

    build_db(args.data_dir, args.output)


if __name__ == "__main__":
    main()
