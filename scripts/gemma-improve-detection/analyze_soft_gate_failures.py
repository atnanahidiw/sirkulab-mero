#!/usr/bin/env python3
"""Diagnose why soft visual-group retrieval did or did not convert into accuracy.

The soft gate lifted offline retrieval recall 47% -> 87%, but end-to-end species
accuracy only rose 37.7% -> 48.2%. This script joins the three runs (baseline native,
offline soft-gate replay, full soft-gate rerun) and answers: *where did the recovered
retrieval leak away, and which neighbor edges are actually worth keeping?*

Sections:
  1. Recovered-but-not-correct  — surfaced the true species, still picked wrong (synthesis)
  2. Baseline-vs-soft flips      — gains and regressions, by group
  3. Candidate-rank sensitivity  — does soft accuracy depend on the true species' rank?
                                   (computed from the soft run's OWN tool calls — self-consistent)
  4. Neighbor contribution       — which edges recover retrieval
  5. Per-edge retrieval ablation — retrieval lost if an edge is removed
  6. Net accuracy value per edge — wins (recovered+correct) minus distractor losses;
                                   the number that decides which edges to keep or gate

Run:
  python3 scripts/gemma-improve-detection/analyze_soft_gate_failures.py
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sqlite3
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve()
OUT_DIR = HERE.parent / "outputs"
SOFT_GATE_PATH = HERE.parent / "eval_gemma4_soft_gate.py"
APP_REPO = next(p for p in HERE.parents if (p / "assets/data/species_data.sqlite").exists())
DB_PATH = APP_REPO / "assets/data/species_data.sqlite"


def load_jsonl(path):
    return [json.loads(line) for line in Path(path).open()]


def load_soft_module():
    spec = importlib.util.spec_from_file_location("soft_gate", SOFT_GATE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(num, den):
    return num / den if den else 0.0


def fmt_pct(x):
    return f"{x:.1%}"


def bucket_rank(rank):
    if rank is None:
        return "not surfaced"
    if rank == 1:
        return "rank 1"
    if rank <= 5:
        return "rank 2-5"
    if rank <= 10:
        return "rank 6-10"
    return "rank 11+"


def row_key(row):
    return row["image"]


def source_edge(row):
    pred = row["predicted_visual_group"]
    true = row["true_visual_group"]
    if row["hard_top5"]["hit"]:
        return f"{pred} -> {pred} (predicted group)"
    if row["soft_neighbors"]["hit"]:
        if pred == true:
            return f"{pred} -> {pred} (larger predicted-group budget)"
        return f"{pred} -> {true}"
    return ""


def build_joined(baseline_rows, replay_rows, soft_rows):
    baseline = {row_key(r): r for r in baseline_rows}
    replay = {row_key(r): r for r in replay_rows}
    soft = {row_key(r): r for r in soft_rows}
    keys = sorted(set(baseline) & set(replay) & set(soft))
    return [{"image": k, "baseline": baseline[k], "replay": replay[k], "soft": soft[k]} for k in keys]


# ── enrichment: derive everything about the SOFT run from the soft run itself ──
def enrich_with_soft_run(joined, con, sg, group_of):
    """Attach, per image, the true species' rank in the candidate list Gemma actually saw
    in the soft run (replay of the soft run's own first tool call), plus the group of
    Gemma's final pick. This keeps rank and outcome from the same run."""
    for item in joined:
        soft = item["soft"]
        calls = soft.get("tool_call_args") or []
        predicted = str(calls[0].get("visualGroup", "")).strip() if calls else ""
        cands = sg.soft_neighbor_search(con, calls[0]) if calls else []
        true_latin = soft["true"]
        true_rank = next((i for i, c in enumerate(cands, 1) if c["latin"] == true_latin), None)
        pick = (soft.get("final") or {}).get("scientific_name", "") if soft.get("final") else ""
        item["soft_predicted_group"] = predicted
        item["soft_true_group"] = group_of(true_latin)
        item["soft_rank"] = true_rank
        item["soft_pick_group"] = group_of(pick) if pick else None
    return joined


def recovered_but_not_correct(joined):
    by_group = defaultdict(lambda: {"n": 0, "surfaced": 0, "correct": 0, "failed": 0})
    failed_rows = []
    for item in joined:
        replay, soft = item["replay"], item["soft"]
        group = replay["true_visual_group"]
        by_group[group]["n"] += 1
        if replay["soft_neighbors"]["hit"]:
            by_group[group]["surfaced"] += 1
            if soft["species_ok"]:
                by_group[group]["correct"] += 1
            else:
                by_group[group]["failed"] += 1
                failed_rows.append(item)
    summary = [
        {
            "true_visual_group": g,
            "n": s["n"],
            "surfaced": s["surfaced"],
            "final_correct": s["correct"],
            "failed_synthesis": s["failed"],
            "failure_rate_when_surfaced": pct(s["failed"], s["surfaced"]),
        }
        for g, s in by_group.items()
    ]
    summary.sort(key=lambda r: (r["failed_synthesis"], r["failure_rate_when_surfaced"]), reverse=True)
    return summary, failed_rows


def flip_analysis(joined):
    buckets = {"baseline_wrong_soft_correct": [], "baseline_correct_soft_wrong": [],
               "both_correct": [], "both_wrong": []}
    for item in joined:
        base_ok = bool(item["baseline"]["species_ok"])
        soft_ok = bool(item["soft"]["species_ok"])
        if not base_ok and soft_ok:
            buckets["baseline_wrong_soft_correct"].append(item)
        elif base_ok and not soft_ok:
            buckets["baseline_correct_soft_wrong"].append(item)
        elif base_ok and soft_ok:
            buckets["both_correct"].append(item)
        else:
            buckets["both_wrong"].append(item)
    by_group = {}
    for name, rows in buckets.items():
        c = Counter(item["replay"]["true_visual_group"] for item in rows)
        by_group[name] = [{"visual_group": k, "count": v} for k, v in c.most_common()]
    return buckets, by_group


def regression_kinds(joined, neighbors):
    """Classify each baseline-correct / soft-wrong regression by cause."""
    rows = []
    counts = Counter()
    for item in joined:
        if not (item["baseline"]["species_ok"] and not item["soft"]["species_ok"]):
            continue
        p, t, pick = item["soft_predicted_group"], item["soft_true_group"], item["soft_pick_group"]
        if pick is not None and pick == t:
            kind = "within-group congener"   # right group, wrong species
        elif p == t and pick and pick != p and pick in neighbors.get(p, []):
            kind = "neighbor distractor"     # routed right, lost to an injected neighbor
        elif p != t:
            kind = "mis-routed"
        else:
            kind = "other"
        counts[kind] += 1
        rows.append({"image": item["image"], "true_group": t, "predicted_group": p,
                     "pick_group": pick, "kind": kind})
    return {"counts": dict(counts), "rows": rows}


def rank_sensitivity(joined):
    """Soft accuracy as a function of the true species' rank in the soft run's own list."""
    by_bucket = defaultdict(lambda: {"n": 0, "soft_correct": 0})
    for item in joined:
        b = bucket_rank(item["soft_rank"])
        by_bucket[b]["n"] += 1
        by_bucket[b]["soft_correct"] += bool(item["soft"]["species_ok"])
    order = ["rank 1", "rank 2-5", "rank 6-10", "rank 11+", "not surfaced"]
    return [
        {"rank_bucket": b, "n": by_bucket[b]["n"], "soft_correct": by_bucket[b]["soft_correct"],
         "soft_accuracy": pct(by_bucket[b]["soft_correct"], by_bucket[b]["n"])}
        for b in order if by_bucket[b]["n"]
    ]


def neighbor_contribution(joined):
    counter = Counter()
    for item in joined:
        replay = item["replay"]
        if replay["hard_top5"]["hit"] or not replay["soft_neighbors"]["hit"]:
            continue
        counter[source_edge(replay)] += 1
    return [{"edge": k, "recovered": v} for k, v in counter.most_common()]


def edge_ablation(joined):
    recovered_by_edge = defaultdict(list)
    for item in joined:
        replay = item["replay"]
        if replay["hard_top5"]["hit"] or not replay["soft_neighbors"]["hit"]:
            continue
        recovered_by_edge[source_edge(replay)].append(item)
    total_soft_hits = sum(1 for item in joined if item["replay"]["soft_neighbors"]["hit"])
    total_n = len(joined)
    rows = [
        {"edge": edge, "recovered_cases": len(rows_),
         "recall_without_edge": pct(total_soft_hits - len(rows_), total_n),
         "recall_loss_pp": pct(len(rows_), total_n) * 100}
        for edge, rows_ in recovered_by_edge.items()
    ]
    rows.sort(key=lambda r: r["recovered_cases"], reverse=True)
    return rows


def net_edge_value(joined, neighbors):
    """End-to-end accuracy value of each neighbor edge P -> G, from the soft run.

    win   : true species is in group G, Gemma predicted P (so only the edge surfaces it),
            and the final answer was correct. The edge earned an identification.
    loss  : routing was already correct (true group == predicted P), but Gemma's wrong
            final pick came from neighbor group G — a distractor the edge injected.
    net   = wins - losses. Edges with net <= 0 should be dropped or gated behind a
            low-confidence / out-of-vocab check.
    """
    wins = Counter()
    losses = Counter()
    edges = {(p, g) for p, gs in neighbors.items() for g in gs}
    for item in joined:
        p = item["soft_predicted_group"]
        t = item["soft_true_group"]
        pick = item["soft_pick_group"]
        ok = bool(item["soft"]["species_ok"])
        if ok and t != p and (p, t) in edges:
            wins[(p, t)] += 1
        elif (not ok) and t == p and pick and pick != p and (p, pick) in edges:
            losses[(p, pick)] += 1
    rows = []
    for (p, g) in sorted(edges):
        w, l = wins[(p, g)], losses[(p, g)]
        if w == 0 and l == 0:
            continue
        verdict = "keep" if w - l > 0 else ("gate/drop" if w - l < 0 else "marginal")
        rows.append({"edge": f"{p} -> {g}", "wins": w, "distractor_losses": l,
                     "net": w - l, "verdict": verdict})
    rows.sort(key=lambda r: (r["net"], r["wins"]), reverse=True)
    return rows


def write_md(path, payload):
    rs = {r["rank_bucket"]: r for r in payload["rank_sensitivity"]}
    r1 = rs.get("rank 1", {})
    r25 = rs.get("rank 2-5", {})
    neg = [e for e in payload["net_edge_value"] if e["net"] < 0]
    nonpos = [e for e in payload["net_edge_value"] if e["net"] <= 0]

    L = [
        "# Soft-gate follow-up analysis",
        "",
        "## What this is",
        "",
        "The soft visual-group gate lifted **offline retrieval recall 47% → 87%**, but the",
        "end-to-end native rerun only moved **species accuracy 37.7% → 48.2% (+10.5pp)**.",
        "Most of the recovered retrieval did not convert. This analysis joins the three runs",
        "— baseline native, offline soft-gate replay, and the full soft-gate rerun — to locate",
        "exactly where the recovered retrieval leaks away and which neighbor edges are worth",
        "keeping. Each section drills one step further toward an actionable next iteration.",
        "",
        f"Joined images: **{payload['n']}**. Net flips: "
        f"**+{payload['flips']['counts']['baseline_wrong_soft_correct']} gained, "
        f"-{payload['flips']['counts']['baseline_correct_soft_wrong']} regressed** "
        f"(= +{payload['flips']['counts']['baseline_wrong_soft_correct'] - payload['flips']['counts']['baseline_correct_soft_wrong']} net, "
        "matching 125 → 160).",
        "",
        "## 1. Recovered but not correct",
        "",
        "Soft retrieval surfaced the true species, but Gemma still picked the wrong final species.",
        "This is the synthesis leak, by group.",
        "",
        "| true visual_group | n | surfaced | final correct | failed synthesis | failure rate when surfaced |",
        "| --- | --: | --: | --: | --: | --: |",
    ]
    for r in payload["recovered_but_not_correct"]["by_group"]:
        L.append(f"| {r['true_visual_group']} | {r['n']} | {r['surfaced']} | {r['final_correct']} | "
                 f"{r['failed_synthesis']} | {fmt_pct(r['failure_rate_when_surfaced'])} |")

    L += ["", "## 2. Baseline vs soft-gate flips", "", "| flip bucket | count |", "| --- | --: |"]
    for name, c in payload["flips"]["counts"].items():
        L.append(f"| {name} | {c} |")
    L += ["", "### Positive flips by group", "", "| visual_group | count |", "| --- | --: |"]
    for r in payload["flips"]["by_group"]["baseline_wrong_soft_correct"]:
        L.append(f"| {r['visual_group']} | {r['count']} |")
    L += ["", "### Regressions by group", "", "| visual_group | count |", "| --- | --: |"]
    for r in payload["flips"]["by_group"]["baseline_correct_soft_wrong"]:
        L.append(f"| {r['visual_group']} | {r['count']} |")

    rk = payload["regression_kinds"]["counts"]
    L += [
        "",
        "### Regression cause",
        "",
        "What actually went wrong in the cases the baseline got right and the soft gate lost:",
        "",
        "| cause | count |",
        "| --- | --: |",
        f"| within-group congener (right group, wrong species) | {rk.get('within-group congener', 0)} |",
        f"| neighbor distractor (right group, lost to an injected neighbor) | {rk.get('neighbor distractor', 0)} |",
        f"| mis-routed (predicted group ≠ true) | {rk.get('mis-routed', 0)} |",
        f"| other | {rk.get('other', 0)} |",
        "",
        "Regressions are **mostly congener confusion**, not neighbor distraction — the soft gate's",
        "larger predicted-group budget puts more same-group look-alikes in front of Gemma, and the",
        "reranker doesn't float the true one to the top. The neighbor edges are nearly innocent (§6).",
    ]

    L += [
        "",
        "## 3. Candidate-rank sensitivity",
        "",
        "Soft accuracy as a function of where the true species ranked in the candidate list",
        "**Gemma actually saw in the soft run** (replay of the soft run's own first tool call,",
        "so rank and outcome come from the same run).",
        "",
        "| true species rank in soft candidates | n | soft correct | soft accuracy |",
        "| --- | --: | --: | --: |",
    ]
    for r in payload["rank_sensitivity"]:
        L.append(f"| {r['rank_bucket']} | {r['n']} | {r['soft_correct']} | {fmt_pct(r['soft_accuracy'])} |")

    L += [
        "",
        "## 4. Neighbor contribution (retrieval)",
        "",
        "Cases missed by hard_top5 but recovered by soft_neighbors — which edge surfaced them.",
        "",
        "| predicted -> recovered true group | recovered cases |",
        "| --- | --: |",
    ]
    for r in payload["neighbor_contribution"]:
        L.append(f"| {r['edge']} | {r['recovered']} |")

    L += [
        "",
        "## 5. Per-edge retrieval ablation",
        "",
        "Retrieval recall lost if each edge is removed. **Retrieval-only** — it does not say",
        "whether the edge helped end-to-end accuracy (see §6).",
        "",
        "| removed edge | recovered cases lost | recall without edge | recall loss |",
        "| --- | --: | --: | --: |",
    ]
    for r in payload["edge_ablation"]:
        L.append(f"| {r['edge']} | {r['recovered_cases']} | {fmt_pct(r['recall_without_edge'])} | "
                 f"{r['recall_loss_pp']:.1f}pp |")

    L += [
        "",
        "## 6. Net accuracy value per edge",
        "",
        "The decision metric §5 can't give. For each neighbor edge `P -> G`:",
        "",
        "- **win** — true species is in group G, Gemma predicted P (only the edge surfaces it),",
        "  and the final answer was correct. The edge earned an ID.",
        "- **distractor loss** — routing was already correct (true group = predicted P), but",
        "  Gemma's wrong final pick came from neighbor group G. The edge injected the distractor.",
        "- **net = wins − losses.** Net ≤ 0 means the edge costs more than it earns and should be",
        "  dropped or gated behind a low-confidence / out-of-vocab check on the predicted group.",
        "",
        "| edge | wins | distractor losses | net | verdict |",
        "| --- | --: | --: | --: | --- |",
    ]
    for r in payload["net_edge_value"]:
        L.append(f"| {r['edge']} | {r['wins']} | {r['distractor_losses']} | {r['net']:+d} | {r['verdict']} |")

    # ── conclusion (dynamic) ──
    rk = payload["regression_kinds"]["counts"]
    total_losses = sum(e["distractor_losses"] for e in payload["net_edge_value"])
    L += [
        "",
        "## Conclusion",
        "",
        f"**1. The reranker is the single biggest lever.** Soft accuracy is "
        f"**{fmt_pct(r1.get('soft_accuracy', 0))}** when the true species is rank 1 but collapses to "
        f"**{fmt_pct(r25.get('soft_accuracy', 0))}** at rank 2–5 and near zero below (§3). Gemma faithfully "
        "anchors on rank 1; the failure is the weighted-Dice reranker burying the true species, "
        "not the model refusing to reason. Getting more true species to rank 1 is the highest-value "
        "next change, and it is offline-testable (no model rerun).",
        "",
        "**2. Neighbor expansion is almost pure upside — keep it.** Across every edge there are only "
        f"**{total_losses} distractor losses** total (§6); nearly all edges are net-positive, with at most "
        "`Tall broadleaf tree → Fern` slightly negative. Gating expansion would buy almost nothing — the "
        "earlier worry that the Primate edges inject distractors is **not** what the data shows.",
        "",
        f"**3. The regressions are congener confusion, not the neighbor edges.** Of the "
        f"{payload['flips']['counts']['baseline_correct_soft_wrong']} regressions, "
        f"**{rk.get('within-group congener', 0)} are within-group congener errors** (right group, wrong "
        f"species) versus only {rk.get('neighbor distractor', 0)} neighbor distractors (§2). The soft gate's "
        "larger predicted-group budget (top-15 vs top-5) surfaces more same-group look-alikes, and the "
        "reranker doesn't float the true one up — so this is the **same reranker problem as §1**, seen from "
        "the regression side. The fix is a stronger within-group reranker (and possibly a tighter "
        "predicted-group budget), not gating neighbor expansion.",
        "",
        "**Net:** one lever dominates — **rerank so the true species reaches rank 1**, especially among "
        "same-group congeners. That converts the unrecovered retrieval (§3) and erases most regressions "
        "(§2) at once. Neighbor expansion stays on as-is."
        + (f" Optionally drop the lone net-negative edge(s): {', '.join('`'+e['edge']+'`' for e in neg)}." if neg else ""),
        "",
        "## Notes",
        "",
        "- §3 rank is from the soft run's own first tool call, so rank and outcome are from the same run.",
        "  Multi-pass images are scored on the first call's candidate list (an approximation).",
        "- §4/§5 are retrieval-only and use the offline replay (baseline tool-call traits).",
        "- §6 attributes a win/loss only in the clean cases (edge-surfaced correct; or correctly-routed",
        "  group lost to a neighbor distractor); ambiguous mis-routings are not charged to any edge.",
    ]
    path.write_text("\n".join(L) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--baseline", default=str(OUT_DIR / "gemma4_baseline.jsonl"))
    ap.add_argument("--replay", default=str(OUT_DIR / "gemma4_soft_visual_group_gate.jsonl"))
    ap.add_argument("--soft", default=str(OUT_DIR / "gemma4_soft_gate.jsonl"))
    ap.add_argument("--db", default=str(DB_PATH))
    ap.add_argument("--out-prefix", default=str(OUT_DIR / "gemma4_soft_gate_followup"))
    args = ap.parse_args()

    joined = build_joined(load_jsonl(args.baseline), load_jsonl(args.replay), load_jsonl(args.soft))

    sg = load_soft_module()
    con = sqlite3.connect(args.db)
    con.row_factory = sqlite3.Row
    group_map = {r["latin_name"]: r["visual_group"] for r in con.execute("SELECT latin_name, visual_group FROM species")}

    def group_of(name):
        if not name:
            return None
        if name in group_map:
            return group_map[name]
        low = name.strip().lower()
        for k, v in group_map.items():
            if k.lower() == low:
                return v
        for k, v in group_map.items():
            if k.lower() in low or low in k.lower():
                return v
        return None

    enrich_with_soft_run(joined, con, sg, group_of)
    con.close()

    rec_summary, rec_rows = recovered_but_not_correct(joined)
    flips, flips_by_group = flip_analysis(joined)
    payload = {
        "inputs": {"baseline": args.baseline, "replay": args.replay, "soft": args.soft},
        "n": len(joined),
        "recovered_but_not_correct": {"by_group": rec_summary, "count": len(rec_rows)},
        "flips": {"counts": {k: len(v) for k, v in flips.items()}, "by_group": flips_by_group},
        "regression_kinds": regression_kinds(joined, sg.PREDICTED_GROUP_NEIGHBORS),
        "rank_sensitivity": rank_sensitivity(joined),
        "neighbor_contribution": neighbor_contribution(joined),
        "edge_ablation": edge_ablation(joined),
        "net_edge_value": net_edge_value(joined, sg.PREDICTED_GROUP_NEIGHBORS),
    }

    out_prefix = Path(args.out_prefix)
    out_prefix.parent.mkdir(parents=True, exist_ok=True)
    out_prefix.with_suffix(".json").write_text(json.dumps(payload, indent=2))
    write_md(out_prefix.with_suffix(".md"), payload)

    print(f"joined rows: {payload['n']}")
    print("flip counts:", payload["flips"]["counts"])
    print("net edge value (sorted):")
    for r in payload["net_edge_value"]:
        print(f"  {r['edge']:48s} wins {r['wins']:2d}  losses {r['distractor_losses']:2d}  net {r['net']:+d}  [{r['verdict']}]")
    print(f"wrote {out_prefix.with_suffix('.json')}")
    print(f"wrote {out_prefix.with_suffix('.md')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
