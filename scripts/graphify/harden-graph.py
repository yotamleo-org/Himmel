#!/usr/bin/env python3
# harden-graph.py -- idempotent post-update step that bridges
# doc-extracted concept nodes whose label literally names a code file to that
# file's AST node (relation "references"), and adds allowlisted subprocess-exec
# code-fact edges (relation "calls"). With --root, also resolves shell
# calls/sources between shell files (harden_shell_calls.py). Writes only <out>/graph.json;
# stdlib only -- never imports the `graphify` package (not importable from
# system python3; see refresh-graph-map.sh's own venv note).
#
# Matching rule (never guessed): a doc node's label must be EXACTLY a code-file
# token optionally followed by " script"/" file"/" router"/" module" -- full
# path match against an AST file node's source_file first; if the token has a
# directory component, it must then match by PATH SUFFIX (never fall through
# to a bare-basename guess -- a token naming a directory that contradicts the
# only same-named file must not fabricate a confidence-1.0 edge);
# only a token with no directory component falls back to a basename match, and
# only if it is unique across AST file nodes. An ambiguous match (two+ files)
# is skipped and counted; a directory-qualified token matching zero files is
# skipped and counted separately -- never resolved by guessing.
#
# Canonical identity (runs first): graphify ids are file-scoped, so one entity
# named in several files is several nodes and `graphify path` refuses the
# label as ambiguous. A semantic node whose label is exactly a code-file token
# (resolved by the rule above), a `name()` symbol defined by exactly one AST
# node, or a term defined in docs/glossary.md is merged into that canonical
# node: its edges and hyperedge memberships are redirected and the canonical
# node lists it in `merged_ids`. A symbol with no AST node, and a registry name
# (`/command`, `<name> plugin|skill|hook`, unique by construction), merges its
# semantic copies into the smallest id. Never merged: AST nodes (two same-name
# symbols in different files are distinct entities), a token or symbol
# matching two+ AST nodes, a code-file token with no AST file node named from
# two+ files (YAML/JSON/TOML get no AST node, and two docs naming
# .pre-commit-config.yaml may mean two different files) -- both counted
# identity-ambiguous -- and other prose labels outside the glossary
# ("Precedence ladder" names a different ladder in two docs).
# ponytail: a merged-away node's own edges are pruned by semantic-merge.py if its canonical semantic node disappears before its own file is re-extracted; re-extract the merged_ids files if semantic-runs.jsonl shows that loss.
import argparse
import json
import os
import re
import sys
from collections import defaultdict

from harden_shell_calls import find_shell_edges

CODE_EXT = r"[\w./-]+\.(?:mjs|js|ts|sh|py|json|yaml|yml|ps1|toml)\b"
GHOST_LABEL_RE = re.compile(r"(" + CODE_EXT + r")(?: script| file| router| module)?")
DOC_SUFFIXES = (".md", ".txt", ".png", ".yaml", ".yml")
CODE_TOKEN_RE = re.compile(CODE_EXT)
CALLABLE_RE = re.compile(r"[A-Za-z_][\w.]*\(\)")
REGISTRY_NAME_RE = re.compile(r"/[a-z][\w:-]*|[\w:.-]+ (?:plugin|skill|(?:pre-commit )?hook)")
GLOSSARY = "docs/glossary.md"


def edge_list_key(graph):
    return "links" if "links" in graph else "edges"


def is_ast_file_node(node):
    sf = node.get("source_file") or ""
    return (
        node.get("file_type") == "code"
        and node.get("source_location") == "L1"
        and node.get("label") == os.path.basename(sf)
    )


def build_ast_index(nodes):
    by_path = {}
    by_base = defaultdict(list)
    for node_id, node in nodes.items():
        if not is_ast_file_node(node):
            continue
        sf = node.get("source_file") or ""
        by_path[sf] = node_id
        by_base[os.path.basename(sf)].append(node_id)
    return by_path, by_base


def strip_leading_dot_slash(path):
    # str.lstrip("./") strips a CHARACTER CLASS, not the literal prefix -- it
    # would mangle ".config/tool.sh" into "config/tool.sh".
    # Only a literal leading "./" is ever meant to be dropped here.
    return path[2:] if path.startswith("./") else path


def resolve_code_file(token, by_path, by_base):
    """(node_id, ambiguous, path_mismatch) for a code-file token: full path ->
    (if the token has a directory component) unique path-suffix match, never a
    basename fallback -> (bare token only) unique basename -> ambiguous (skip,
    counted) or, for a directory-qualified token matching nothing, a
    path-mismatch (skip, counted separately)."""
    token = strip_leading_dot_slash(token)
    if token in by_path:
        return by_path[token], False, False
    if "/" in token:
        suffix = "/" + token
        candidates = [node_id for sf, node_id in by_path.items() if sf == token or sf.endswith(suffix)]
        if len(candidates) == 1:
            return candidates[0], False, False
        if len(candidates) > 1:
            return None, True, False
        return None, False, True
    candidates = by_base.get(os.path.basename(token), [])
    if len(candidates) == 1:
        return candidates[0], False, False
    if len(candidates) > 1:
        return None, True, False
    return None, False, False


def find_canonical_ids(nodes, by_path, by_base):
    """({alias_id: canonical_id}, ambiguous_count) per the canonical-identity
    rule in the header."""
    ast_callables = defaultdict(list)
    glossary = {}
    for node_id in sorted(nodes):
        node = nodes[node_id]
        label = node.get("label") or ""
        if node.get("_origin") == "ast" and node.get("file_type") == "code" and CALLABLE_RE.fullmatch(label):
            ast_callables[label].append(node_id)
        elif node.get("_origin") == "semantic" and node.get("source_file") == GLOSSARY:
            glossary.setdefault(label, node_id)

    aliases = {}
    unanchored = defaultdict(list)
    ambiguous = 0
    for node_id in sorted(nodes):
        node = nodes[node_id]
        if node.get("_origin") != "semantic":
            continue
        label = node.get("label") or ""
        target = None
        if CODE_TOKEN_RE.fullmatch(label):
            target, is_ambiguous, _ = resolve_code_file(label, by_path, by_base)
            if is_ambiguous:
                ambiguous += 1
                continue
        elif CALLABLE_RE.fullmatch(label):
            hits = ast_callables.get(label, [])
            if len(hits) > 1:
                ambiguous += 1
                continue
            target = hits[0] if hits else None
        elif label in glossary and node.get("source_file") != GLOSSARY:
            target = glossary[label]
        elif not REGISTRY_NAME_RE.fullmatch(label):
            continue
        if target is None:
            unanchored[label].append(node_id)
        elif target != node_id:
            aliases[node_id] = target
    for label, ids in unanchored.items():
        if len({nodes[i].get("source_file") for i in ids}) > 1:
            if CODE_TOKEN_RE.fullmatch(label):
                ambiguous += len(ids)
                continue
            for alias in ids[1:]:
                aliases[alias] = ids[0]
    return aliases, ambiguous


def apply_canonical_ids(graph, ekey, nodes, aliases):
    """Drop the alias nodes, record them on their canonical node, and redirect
    their edges and hyperedge memberships; an edge that becomes a self-loop or
    duplicates an existing (source, target, relation, source_file) is dropped."""
    for alias, canon in aliases.items():
        node = nodes[canon]
        absorbed = set(nodes[alias].get("merged_ids") or []) | {alias}
        node["merged_ids"] = sorted(set(node.get("merged_ids") or []) | absorbed)
    graph["nodes"] = [n for n in graph.get("nodes", []) if n["id"] not in aliases]

    def key(e):
        return (e.get("source"), e.get("target"), e.get("relation"), e.get("source_file"))

    edges = graph.get(ekey, [])
    seen = {key(e) for e in edges if e.get("source") not in aliases and e.get("target") not in aliases}
    out = []
    for e in edges:
        src, tgt = aliases.get(e.get("source"), e.get("source")), aliases.get(e.get("target"), e.get("target"))
        if src == e.get("source") and tgt == e.get("target"):
            out.append(e)
            continue
        e = dict(e, source=src, target=tgt)
        if src == tgt or key(e) in seen:
            continue
        seen.add(key(e))
        out.append(e)
    graph[ekey] = out
    for h in graph.get("hyperedges") or []:
        members = []
        for m in h.get("nodes", []):
            m = aliases.get(m, m)
            if m not in members:
                members.append(m)
        h["nodes"] = members


def find_ghost_bridges(nodes, by_path, by_base):
    bridges = []
    skipped_ambiguous = 0
    skipped_path_mismatch = 0
    for doc_id, node in nodes.items():
        sf = node.get("source_file") or ""
        if not sf.endswith(DOC_SUFFIXES):
            continue
        m = GHOST_LABEL_RE.fullmatch(node.get("label") or "")
        if not m:
            continue
        target_id, ambiguous, path_mismatch = resolve_code_file(m.group(1), by_path, by_base)
        if ambiguous:
            skipped_ambiguous += 1
            continue
        if path_mismatch:
            skipped_path_mismatch += 1
            continue
        if target_id is None or target_id == doc_id:
            continue
        bridges.append(
            {
                "source": doc_id,
                "target": target_id,
                "relation": "references",
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": sf,
                "source_location": None,
                "weight": 1.0,
                "hardened": "doc-label-names-code-file",
            }
        )
    return bridges, skipped_ambiguous, skipped_path_mismatch


def load_allowlist(path):
    if not path or not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def find_code_facts(by_path, allowlist):
    # Allowlist entries carry a full path the operator curated -- unlike a doc
    # ghost's bare-basename label, there is no ambiguity to resolve here, so
    # this requires an EXACT source_file match and never falls back to
    # resolve_code_file's basename heuristic (a corpus missing the allowlisted
    # file but containing an unrelated same-named one would otherwise get a
    # false, confidence-1.0 "calls" edge).
    facts = []
    for entry in allowlist:
        src_id = by_path.get(strip_leading_dot_slash(entry["source_file"]))
        tgt_id = by_path.get(strip_leading_dot_slash(entry["target_file"]))
        if src_id is None or tgt_id is None:
            continue
        facts.append(
            {
                "source": src_id,
                "target": tgt_id,
                "relation": entry.get("relation", "calls"),
                "confidence": "EXTRACTED",
                "confidence_score": 1.0,
                "source_file": entry["source_file"],
                "source_location": entry.get("source_location"),
                "weight": 1.0,
                "hardened": "subprocess-exec",
            }
        )
    return facts


def append_cost_note(out_dir, summary):
    cost_path = os.path.join(out_dir, "cost.json")
    if not os.path.exists(cost_path):
        return
    try:
        with open(cost_path, "r", encoding="utf-8") as f:
            cost = json.load(f)
    except (OSError, ValueError):
        return
    runs = cost.get("runs")
    if not runs:
        return
    prior = runs[-1].get("note") or ""
    runs[-1]["note"] = f"{prior}; {summary}" if prior else summary
    tmp_path = cost_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(cost, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, cost_path)


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True, help="graphify-out directory containing graph.json")
    ap.add_argument("--allowlist", default=None, help="defaults to harden-allowlist.json next to this script")
    ap.add_argument("--root", default=None, help="corpus root the graph's source_file paths are relative to; enables shell call resolution")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(argv)

    graph_path = os.path.join(args.out, "graph.json")
    try:
        with open(graph_path, "r", encoding="utf-8") as f:
            graph = json.load(f)
    except (OSError, ValueError) as exc:
        print(f"harden-graph: cannot read {graph_path}: {exc}", file=sys.stderr)
        return 1

    nodes = {n["id"]: n for n in graph.get("nodes", [])}
    ekey = edge_list_key(graph)

    by_path, by_base = build_ast_index(nodes)
    aliases, identity_ambiguous = find_canonical_ids(nodes, by_path, by_base)
    if aliases:
        apply_canonical_ids(graph, ekey, nodes, aliases)
        nodes = {n["id"]: n for n in graph["nodes"]}
    edges = graph.get(ekey, [])
    bridges, skipped_ambiguous, skipped_path_mismatch = find_ghost_bridges(nodes, by_path, by_base)

    # An explicitly-supplied --allowlist that doesn't exist is a typo, not the
    # normal "no allowlist for this corpus yet" case (only the DEFAULT path is
    # allowed to be silently absent) -- reporting success while a typo
    # suppresses every code-fact edge would hide the failure.
    if args.allowlist and not os.path.exists(args.allowlist):
        print(f"harden-graph: --allowlist path not found: {args.allowlist}", file=sys.stderr)
        return 1
    allowlist_path = args.allowlist or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "harden-allowlist.json"
    )
    facts = find_code_facts(by_path, load_allowlist(allowlist_path))
    shell_edges, shell_unresolved = find_shell_edges(nodes, args.root) if args.root else ([], 0)

    # graph.json is "directed": false, "multigraph": false -- (u, v) and (v, u)
    # are the SAME edge, so dedup keys must be order-independent or a pre-existing reverse-order edge between the
    # same two nodes would not be recognized as a duplicate.
    existing_pairs = {frozenset((e.get("source"), e.get("target"))) for e in edges}
    seen = set()
    new_edges = []
    for e in bridges + facts + shell_edges:
        pair = frozenset((e["source"], e["target"]))
        if pair in existing_pairs or pair in seen:
            continue
        if e["source"] not in nodes or e["target"] not in nodes:
            continue
        seen.add(pair)
        new_edges.append(e)

    bridge_count = sum(1 for e in new_edges if e["hardened"] == "doc-label-names-code-file")
    fact_count = sum(1 for e in new_edges if e["hardened"] == "subprocess-exec")
    shell_calls = sum(1 for e in new_edges if e["hardened"] == "shell-call" and e["relation"] == "calls")
    shell_sources = sum(1 for e in new_edges if e["hardened"] == "shell-call" and e["relation"] == "sources")
    unchanged = 0 if new_edges or aliases else 1
    summary = (
        f"harden-graph: bridges={bridge_count} code-facts={fact_count} "
        f"skipped-ambiguous={skipped_ambiguous} skipped-path-mismatch={skipped_path_mismatch} "
        f"unchanged={unchanged} shell-calls={shell_calls} shell-sources={shell_sources} "
        f"shell-unresolved={shell_unresolved} "
        f"identity-merged={len(aliases)} identity-ambiguous={identity_ambiguous}"
    )
    print(summary)

    if unchanged or args.dry_run:
        return 0

    graph[ekey] = edges + new_edges
    tmp_path = graph_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(graph, f)
    os.replace(tmp_path, graph_path)
    append_cost_note(args.out, summary)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
