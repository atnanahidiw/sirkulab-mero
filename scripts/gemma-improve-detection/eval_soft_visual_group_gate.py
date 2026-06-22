#!/usr/bin/env python3
"""Offline counterfactual for replacing the hard visual_group gate.

This script replays the native Gemma 4 E2B baseline output without rerunning Gemma.
It tests whether deterministic neighbor expansion would have made the true species
available in the tool candidates more often.

Compared modes:
  - hard_top5: current production-like gate, first predicted visualGroup only, top 5.
  - hard_top15: same single group, but with a larger candidate budget.
  - soft_neighbors: predicted group plus inverse-confusion neighbors, capped by budget.
  - oracle_top15: true visual_group only, upper bound for group routing.

Run:
  uv run --python .venv-export/bin/python scripts/smaller-footprint-pipeline-v1/eval_soft_visual_group_gate.py

Writes:
  scripts/smaller-footprint-pipeline-v1/outputs/gemma4_soft_visual_group_gate.json
  scripts/smaller-footprint-pipeline-v1/outputs/gemma4_soft_visual_group_gate.jsonl
  scripts/smaller-footprint-pipeline-v1/outputs/gemma4_soft_visual_group_gate.md
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections import Counter, defaultdict
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve()
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
OUT_DIR = HERE.parent / "outputs"

SYNONYMS = {
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
STOPWORDS = {"and", "with", "the", "appears", "somewhat", "but", "on", "of", "in"}
VF_KEYS = ["color", "body_shape", "distinctive_marks", "texture", "size_class", "pattern"]
VF_WEIGHTS = {
    "distinctive_marks": 5.0,
    "pattern": 4.0,
    "color": 4.0,
    "body_shape": 3.0,
    "texture": 1.0,
    "size_class": 1.0,
}
TAX_BOOST = 2.0

PREDICTED_GROUP_NEIGHBORS = {
    "Primate": ["Flying bird", "Small quadruped mammal"],
    "Tall broadleaf tree": ["Fern", "Palm tree", "Vine & climber", "Shrub & bush"],
    "Marine mammal": ["Marine fish"],
    "Mollusk & marine invertebrate": ["Marine fish"],
    "Shrub & bush": ["Mangrove", "Tall broadleaf tree"],
    "Ground herb": ["Mangrove"],
    "Waterfowl": ["Flying bird"],
    "Lizard": ["Frog & toad"],
    "Aquatic plant": ["Mollusk & marine invertebrate"],
}

SOFT_BUDGETS = [15, 8, 5, 3, 3, 3]
SOFT_MAX_TOTAL = 35


def tokens(text):
    out = set()
    for t in re.split(r"\W+", str(text or "").lower()):
        t = SYNONYMS.get(t, t)
        if len(t) > 1 and t not in STOPWORDS:
            out.add(t)
    return out


def dice(a, b):
    if not a or not b:
        return 0.0
    i = len(a & b)
    return 0.0 if i == 0 else (2.0 * i) / (len(a) + len(b))


def run_search(con, args, top_k=5):
    """Mirror the v1 SpeciesService-style FTS5 + weighted-Dice search."""
    traits = {k: str(args.get(k, "")).strip() for k in VF_KEYS if str(args.get(k, "")).strip()}
    vg = str(args.get("visualGroup", "")).strip()
    tax = {t: str(args.get(t, "")).strip() for t in ("taxClass", "taxOrder", "taxFamily", "taxGenus")}
    if not traits and not vg:
        return []

    clean = set()
    for w in re.split(r"\s+", re.sub(r"[^\w\s]", " ", " ".join(traits.values()))):
        w = SYNONYMS.get(w.lower().strip(), w.lower().strip())
        if len(w) > 1 and w not in STOPWORDS:
            clean.add(w)

    rows = []
    fts = " OR ".join(f'"{w}"*' for w in clean)
    try:
        if traits and vg:
            rows = con.execute(
                "SELECT s.* FROM species s JOIN species_fts f ON s.id=f.rowid "
                "WHERE species_fts MATCH ? AND s.visual_group=? LIMIT 42",
                (fts, vg),
            ).fetchall()
            if not rows:
                rows = con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
        elif traits:
            rows = con.execute(
                "SELECT s.* FROM species s JOIN species_fts f ON s.id=f.rowid "
                "WHERE species_fts MATCH ? LIMIT 42",
                (fts,),
            ).fetchall()
        elif vg:
            rows = con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
    except sqlite3.OperationalError:
        rows = (
            con.execute("SELECT * FROM species WHERE visual_group=? LIMIT 42", (vg,)).fetchall()
            if vg
            else con.execute("SELECT * FROM species LIMIT 200").fetchall()
        )
    if not rows:
        return []

    obs = {k: tokens(v) for k, v in traits.items()}
    max_obs = sum(VF_WEIGHTS[k] for k in obs)
    if tax["taxFamily"]:
        max_obs += TAX_BOOST
    if tax["taxGenus"]:
        max_obs += TAX_BOOST * 0.5
    if tax["taxClass"]:
        max_obs += TAX_BOOST * 0.3
    if tax["taxOrder"]:
        max_obs += TAX_BOOST * 0.2

    scored = []
    for r in rows:
        sc = 0.0
        for k in VF_KEYS:
            if k not in obs:
                continue
            stored = (r[k] or "").strip() if r[k] is not None else ""
            sc += dice(obs[k], tokens(stored) if stored else tokens(r["visual_blob"])) * VF_WEIGHTS[k]
        for field, key, weight in [
            ("family", "taxFamily", TAX_BOOST),
            ("genus", "taxGenus", TAX_BOOST * 0.5),
            ("class", "taxClass", TAX_BOOST * 0.3),
            ("order", "taxOrder", TAX_BOOST * 0.2),
        ]:
            if tax[key] and (r[field] or "").lower() == tax[key].lower():
                sc += weight
        conf = min(100.0, sc / max_obs * 100.0) if max_obs > 0 else 0.0
        scored.append((sc, conf, r))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [
        {
            "common": r["common_name"],
            "latin": r["latin_name"],
            "genus": r["genus"],
            "confidence": round(conf),
            "score": sc,
            "visual_group": r["visual_group"],
            "visual_features": r["visual_features"],
        }
        for sc, conf, r in scored[:top_k]
    ]


def search_with_group(con, base_args, visual_group, top_k):
    args = dict(base_args)
    args["visualGroup"] = visual_group
    return run_search(con, args, top_k=top_k)


def dedupe_rank(candidates):
    best = {}
    for cand in candidates:
        latin = cand["latin"]
        if latin not in best or cand["score"] > best[latin]["score"]:
            best[latin] = cand
    return sorted(best.values(), key=lambda c: (c["score"], c["confidence"]), reverse=True)


def soft_neighbor_search(con, base_args):
    predicted = str(base_args.get("visualGroup", "")).strip()
    if not predicted:
        return []

    groups = [predicted] + PREDICTED_GROUP_NEIGHBORS.get(predicted, [])
    candidates = []
    for idx, group in enumerate(groups):
        budget = SOFT_BUDGETS[idx] if idx < len(SOFT_BUDGETS) else SOFT_BUDGETS[-1]
        for cand in search_with_group(con, base_args, group, budget):
            cand = dict(cand)
            cand["retrieval_source_group"] = group
            cand["retrieval_source_rank"] = idx + 1
            candidates.append(cand)
    return dedupe_rank(candidates)[:SOFT_MAX_TOTAL]


def load_truth(con):
    truth = {}
    for r in con.execute("SELECT latin_name, visual_group FROM species WHERE TRIM(visual_group)!=''"):
        truth[r["latin_name"]] = r["visual_group"]
    return truth


def contains_true(candidates, true_latin):
    return any(c["latin"] == true_latin for c in candidates)


def candidate_rank(candidates, true_latin):
    for idx, cand in enumerate(candidates, 1):
        if cand["latin"] == true_latin:
            return idx
    return None


def pct(num, den):
    return num / den if den else 0.0


def fmt_pct(x):
    return f"{x:.1%}"


def summarize_rows(rows):
    n = len(rows)
    modes = ["hard_top5", "hard_top15", "soft_neighbors", "oracle_top15"]
    summary = {"n": n, "modes": {}}
    for mode in modes:
        hits = sum(1 for r in rows if r[mode]["hit"])
        avg_candidates = sum(r[mode]["candidate_count"] for r in rows) / n if n else 0.0
        summary["modes"][mode] = {
            "hits": hits,
            "recall": pct(hits, n),
            "avg_candidates": avg_candidates,
        }

    summary["soft_recovered_from_hard_top5"] = sum(
        1 for r in rows if not r["hard_top5"]["hit"] and r["soft_neighbors"]["hit"]
    )
    summary["soft_lost_from_hard_top5"] = sum(
        1 for r in rows if r["hard_top5"]["hit"] and not r["soft_neighbors"]["hit"]
    )
    summary["oracle_recovered_from_hard_top5"] = sum(
        1 for r in rows if not r["hard_top5"]["hit"] and r["oracle_top15"]["hit"]
    )
    return summary


def group_breakdown(rows):
    by_group = defaultdict(list)
    for row in rows:
        by_group[row["true_visual_group"]].append(row)

    out = []
    for group, group_rows in sorted(by_group.items()):
        n = len(group_rows)
        hard = sum(1 for r in group_rows if r["hard_top5"]["hit"])
        soft = sum(1 for r in group_rows if r["soft_neighbors"]["hit"])
        oracle = sum(1 for r in group_rows if r["oracle_top15"]["hit"])
        recovered = sum(1 for r in group_rows if not r["hard_top5"]["hit"] and r["soft_neighbors"]["hit"])
        out.append(
            {
                "visual_group": group,
                "n": n,
                "hard_top5_hits": hard,
                "soft_hits": soft,
                "oracle_hits": oracle,
                "soft_recovered": recovered,
                "hard_top5_recall": pct(hard, n),
                "soft_recall": pct(soft, n),
                "oracle_recall": pct(oracle, n),
            }
        )
    out.sort(key=lambda r: (r["soft_recovered"], r["soft_recall"] - r["hard_top5_recall"]), reverse=True)
    return out


def write_markdown(path, summary, groups, config):
    modes = summary["modes"]
    lines = [
        "# Soft visual-group gate counterfactual",
        "",
        "Offline replay of the native Gemma 4 baseline tool calls. This measures retrieval recall only:",
        "whether the true species appears in the candidate list returned to Gemma.",
        "",
        "## Config",
        "",
        f"- input: `{config['input']}`",
        f"- predicted group budget: {SOFT_BUDGETS[0]}",
        f"- neighbor budgets: {SOFT_BUDGETS[1:]}",
        f"- max soft candidates: {SOFT_MAX_TOTAL}",
        "",
        "## Overall",
        "",
        "| mode | true species surfaced | retrieval recall | avg candidates |",
        "| --- | --: | --: | --: |",
    ]
    for mode in ["hard_top5", "hard_top15", "soft_neighbors", "oracle_top15"]:
        m = modes[mode]
        lines.append(f"| {mode} | {m['hits']} / {summary['n']} | {fmt_pct(m['recall'])} | {m['avg_candidates']:.1f} |")

    lines += [
        "",
        f"- soft_neighbors recovered {summary['soft_recovered_from_hard_top5']} cases missed by hard_top5.",
        f"- soft_neighbors lost {summary['soft_lost_from_hard_top5']} cases that hard_top5 had surfaced.",
        f"- oracle_top15 recovered {summary['oracle_recovered_from_hard_top5']} cases missed by hard_top5.",
        "",
        "## By true visual group",
        "",
        "| true visual_group | n | hard_top5 | soft_neighbors | oracle_top15 | soft recovered |",
        "| --- | --: | --: | --: | --: | --: |",
    ]
    for g in groups:
        lines.append(
            "| {visual_group} | {n} | {hard_top5_hits} ({hard_top5_recall}) | "
            "{soft_hits} ({soft_recall}) | {oracle_hits} ({oracle_recall}) | {soft_recovered} |".format(
                visual_group=g["visual_group"],
                n=g["n"],
                hard_top5_hits=g["hard_top5_hits"],
                hard_top5_recall=fmt_pct(g["hard_top5_recall"]),
                soft_hits=g["soft_hits"],
                soft_recall=fmt_pct(g["soft_recall"]),
                oracle_hits=g["oracle_hits"],
                oracle_recall=fmt_pct(g["oracle_recall"]),
                soft_recovered=g["soft_recovered"],
            )
        )
    path.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=str(OUT_DIR / "gemma4_baseline.jsonl"))
    ap.add_argument("--db", default=str(APP_REPO / "assets/data/species_data.sqlite"))
    ap.add_argument("--out-prefix", default=str(OUT_DIR / "gemma4_soft_visual_group_gate"))
    args = ap.parse_args()

    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    truth = load_truth(con)

    rows = []
    skipped = Counter()
    with Path(args.input).open() as f:
        for line in f:
            src = json.loads(line)
            true_latin = src["true"]
            tool_args = src.get("tool_call_args") or []
            if true_latin not in truth:
                skipped["missing_truth"] += 1
                continue
            if not tool_args:
                skipped["no_tool_call"] += 1
                continue

            first_args = tool_args[0]
            predicted_group = str(first_args.get("visualGroup", "")).strip()
            true_group = truth[true_latin]

            hard_top5 = search_with_group(con, first_args, predicted_group, 5)
            hard_top15 = search_with_group(con, first_args, predicted_group, 15)
            soft = soft_neighbor_search(con, first_args)
            oracle_top15 = search_with_group(con, first_args, true_group, 15)

            row = {
                "image": src["image"],
                "true": true_latin,
                "true_visual_group": true_group,
                "predicted_visual_group": predicted_group,
                "baseline_species_ok": bool(src.get("species_ok")),
                "neighbor_groups": PREDICTED_GROUP_NEIGHBORS.get(predicted_group, []),
                "hard_top5": {
                    "hit": contains_true(hard_top5, true_latin),
                    "rank": candidate_rank(hard_top5, true_latin),
                    "candidate_count": len(hard_top5),
                },
                "hard_top15": {
                    "hit": contains_true(hard_top15, true_latin),
                    "rank": candidate_rank(hard_top15, true_latin),
                    "candidate_count": len(hard_top15),
                },
                "soft_neighbors": {
                    "hit": contains_true(soft, true_latin),
                    "rank": candidate_rank(soft, true_latin),
                    "candidate_count": len(soft),
                    "returned_groups": sorted({c["visual_group"] for c in soft}),
                },
                "oracle_top15": {
                    "hit": contains_true(oracle_top15, true_latin),
                    "rank": candidate_rank(oracle_top15, true_latin),
                    "candidate_count": len(oracle_top15),
                },
            }
            rows.append(row)

    con.close()

    summary = summarize_rows(rows)
    groups = group_breakdown(rows)
    config = {
        "date": str(date.today()),
        "input": str(Path(args.input)),
        "db": str(Path(args.db)),
        "neighbor_map": PREDICTED_GROUP_NEIGHBORS,
        "soft_budgets": SOFT_BUDGETS,
        "soft_max_total": SOFT_MAX_TOTAL,
        "skipped": dict(skipped),
    }
    payload = {"config": config, "summary": summary, "by_true_visual_group": groups}

    out_prefix = Path(args.out_prefix)
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    out_prefix.with_suffix(".json").write_text(json.dumps(payload, indent=2))
    with out_prefix.with_suffix(".jsonl").open("w") as f:
        for row in rows:
            f.write(json.dumps(row) + "\n")
    write_markdown(out_prefix.with_suffix(".md"), summary, groups, config)

    print("Soft visual-group gate counterfactual")
    print(f"Rows evaluated: {summary['n']}  skipped: {dict(skipped)}")
    for mode in ["hard_top5", "hard_top15", "soft_neighbors", "oracle_top15"]:
        m = summary["modes"][mode]
        print(f"{mode:16s} {m['hits']:3d}/{summary['n']}  {fmt_pct(m['recall']):>6s}  avg candidates {m['avg_candidates']:.1f}")
    print(f"soft recovered from hard_top5: {summary['soft_recovered_from_hard_top5']}")
    print(f"soft lost from hard_top5     : {summary['soft_lost_from_hard_top5']}")
    print(f"wrote {out_prefix.with_suffix('.json')}")
    print(f"wrote {out_prefix.with_suffix('.jsonl')}")
    print(f"wrote {out_prefix.with_suffix('.md')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
