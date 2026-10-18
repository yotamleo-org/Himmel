#!/usr/bin/env python3
# semantic-metrics.py -- rationale coverage and cross-file semantic edges of a graphify graph.json.
#
# Definitions (the DoD bar for the semantic re-extraction is coverage >= 80):
#   semantic node  = file_type document, concept, rationale or paper
#   coverage       = semantic nodes with a non-empty `rationale` / semantic nodes, in percent (all nodes)
#   model_made_coverage_pct = the same over concept, rationale and paper nodes only: file-level document nodes
#                     are made by graphify itself and carry no rationale, so this is the DoD metric
#   cross-file edge = an edge not from the AST pass whose relation is one of SEMANTIC_RELATIONS and whose two
#                     ends have different source_file values
# --files a.md,b.md restricts both numbers to nodes (and edges starting at nodes) from those source files.
#
# Usage: semantic-metrics.py <graph.json> [--files a.md,b.md]
import argparse
import json
import sys

SEMANTIC_NODE_TYPES = ("document", "concept", "rationale", "paper")
SEMANTIC_RELATIONS = {"documents", "explains", "rationale_for", "references", "conceptually_related_to",
                      "semantically_similar_to", "shares_data_with", "cites"}


def measure(graph, files=None):
    nodes = graph["nodes"]
    edges = graph.get("links") or graph.get("edges") or []
    byid = {n["id"]: n for n in nodes}
    scope = None if files is None else set(files)

    def in_scope(n):
        return scope is None or n.get("source_file") in scope

    sem = [n for n in nodes if n.get("file_type") in SEMANTIC_NODE_TYPES and in_scope(n)]
    rat = [n for n in sem if str(n.get("rationale") or "").strip()]
    cross = [e for e in edges
             if e.get("_origin") != "ast" and e.get("relation") in SEMANTIC_RELATIONS
             and e.get("source") in byid and e.get("target") in byid
             and in_scope(byid[e["source"]])
             and byid[e["source"]].get("source_file") != byid[e["target"]].get("source_file")]
    made = [n for n in sem if n.get("file_type") != "document"]
    made_rat = [n for n in made if str(n.get("rationale") or "").strip()]
    return {
        "semantic_nodes": len(sem), "with_rationale": len(rat),
        "coverage_pct": round(100 * len(rat) / max(1, len(sem)), 1),
        "model_made_nodes": len(made), "model_made_with_rationale": len(made_rat),
        "model_made_coverage_pct": round(100 * len(made_rat) / max(1, len(made)), 1),
        "cross_file_semantic_edges": len(cross),
        "doc_to_code_edges": sum(1 for e in cross if e["relation"] in ("documents", "explains", "rationale_for")
                                 and byid[e["target"]].get("file_type") == "code"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("graph")
    ap.add_argument("--files", default="")
    a = ap.parse_args()
    with open(a.graph, encoding="utf-8") as f:
        g = json.load(f)
    files = [x for x in a.files.split(",") if x] if a.files else None
    print(json.dumps(measure(g, files), sort_keys=True))


if __name__ == "__main__":
    sys.exit(main())
