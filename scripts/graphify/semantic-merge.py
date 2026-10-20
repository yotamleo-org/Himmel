#!/usr/bin/env python3
# semantic-merge.py -- the stdlib half of semantic-update.sh.
# Owns the content-hash manifest (<out>/semantic-manifest.json) and the merge of
# a scratch semantic extraction into the live <out>/graph.json. Never imports
# the `graphify` package (not importable from system python3; see
# harden-graph.py's header).
#
#   plan  --root R --out O --max-files N --plan P   diff corpus vs manifest
#   seed  --root R --out O                          stamp current hashes only
#   merge --out O --scratch S --plan P --runtime-s T --tokens-in I --tokens-out J
#   restore --out O --before B     put back the semantic items an AST rebuild
#                                  (ast-update.sh) dropped from B's snapshot
#   status --root R --out O        backed-off, unstamped and oldest-unstamped counts
#
# A batch file that fails or is shrink-refused gets a manifest "stuck" record
# {hash, attempts, reason, since}. After MAX_ATTEMPTS on the same content it is
# backed off: plan skips it until its content changes, so it is not re-billed.
#
# Ownership rule for the merge: the AST pass (`graphify update`, hourly) owns
# every `_origin: ast` node/edge; this step owns only `_origin: semantic` ones.
# For each re-extracted or deleted file it drops that file's semantic nodes,
# edges and hyperedges, then adds the scratch extraction's semantic items.
# Clustering is left to the next AST pass, which reclusters the whole graph
# and keeps semantic nodes.
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

MANIFEST = "semantic-manifest.json"
RUNS = "semantic-runs.jsonl"
# Sonnet list price per 1M tokens (in, out): the GRAPHIFY_CLAUDE_CLI_MODEL pin.
# A cost EQUIVALENT only -- claude-cli bills the subscription bank, not dollars.
PRICE_IN, PRICE_OUT = 3.0, 15.0
MAX_ATTEMPTS = 3
# Directory names graphify's detect never scans: a .md under one is never
# extracted, so listing it would fail it on every run.
# ponytail: a copy of graphify detect._SKIP_DIRS (graphifyy at 2026-10-19), re-sync on a graphify bump.
GRAPHIFY_SKIP_DIRS = {
    "venv", ".venv", "node_modules", "__pycache__", ".git", "dist", "build", "target",
    "site-packages", "lib64", ".pytest_cache", ".mypy_cache", ".ruff_cache", ".tox", ".nox", ".eggs",
    "graphify-out", "lcov-report", "visual-tests", "visual-test", "__snapshots__", "storybook-static",
    "dist-protected", ".next", ".nuxt", ".turbo", ".angular", ".idea", ".cache", ".parcel-cache",
    ".svelte-kit", ".terraform", ".serverless", ".graphify", ".obsidian", ".smart-env", ".worktrees",
}
# Test fixtures are data for a suite, not knowledge; a large mirror of them crowds every chunk.
SEMANTIC_SKIP_DIRS = GRAPHIFY_SKIP_DIRS | {"fixtures"}


def die(msg, rc=1):
    print("semantic-merge: " + msg, file=sys.stderr)
    sys.exit(rc)


def load_json(path, default=None):
    if not os.path.exists(path):
        if default is not None:
            return default
        die("missing " + path)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ignored_dirs(root):
    # Same file + dialect as refresh-graph-map.sh: one
    # corpus-relative directory per line, `#` comments, no `..` components.
    path = os.path.join(root, ".graphify-corpus-ignore")
    dirs = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip().strip("/")
                if not line or line.startswith("#"):
                    continue
                if ".." in line.split("/") or line.startswith("/"):
                    print("semantic-merge: ignoring unsafe .graphify-corpus-ignore entry '%s'" % line, file=sys.stderr)
                    continue
                dirs.append(line + "/")
    return dirs


def corpus_files(root, out_name):
    # git ls-files when the root is a work tree: honours .gitignore and skips
    # nested worktrees (.claude/worktrees/) a bare walk would graph N times.
    try:
        raw = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
            capture_output=True, check=True).stdout.decode("utf-8")
        files = [p for p in raw.split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        files = []
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in (".git", out_name, "graphify-out")]
            for fn in fns:
                if fn.endswith(".md"):
                    files.append(os.path.relpath(os.path.join(dp, fn), root))
    skip = ignored_dirs(root) + [out_name + "/", "graphify-out/"]
    keep = []
    for rel in files:
        rel = rel.replace(os.sep, "/")
        if any(rel.startswith(d) for d in skip) or SEMANTIC_SKIP_DIRS & set(rel.split("/")[:-1]):
            continue
        full = os.path.join(root, rel)
        if os.path.isfile(full) and not os.path.islink(full):
            keep.append(rel)
    return sorted(set(keep))


def load_manifest(out):
    return load_json(os.path.join(out, MANIFEST), {"version": 1, "files": {}})


def manifest_files(out):
    return load_manifest(out).get("files", {})


def backed_off(rec, digest):
    return bool(rec) and rec.get("hash") == digest and rec.get("attempts", 0) >= MAX_ATTEMPTS


def unstamped(a):
    # (corpus hashes, unstamped files, backed-off files) against the manifest.
    m = load_manifest(a.out)
    old, stuck = m.get("files", {}), m.get("stuck", {})
    now = {rel: sha256(os.path.join(a.root, rel)) for rel in corpus_files(a.root, os.path.basename(a.out))}
    changed = [rel for rel in sorted(now) if old.get(rel) != now[rel]]
    return now, changed, [rel for rel in changed if backed_off(stuck.get(rel), now[rel])]


def cmd_plan(a):
    now, changed, skipped = unstamped(a)
    changed = [rel for rel in changed if rel not in skipped]
    deleted = sorted(rel for rel in manifest_files(a.out) if rel not in now)
    batch = changed[:a.max_files]
    plan = {"changed_total": len(changed), "batch": batch, "deleted": deleted,
            "backlog": len(changed) - len(batch), "backed_off": skipped}
    write_json_atomic(a.plan, plan)
    print("plan: changed=%d batch=%d deleted=%d backlog=%d backed_off=%d"
          % (len(changed), len(batch), len(deleted), plan["backlog"], len(skipped)))


def cmd_status(a):
    _, changed, skipped = unstamped(a)
    now = time.time()
    oldest = max((now - os.path.getmtime(os.path.join(a.root, rel)) for rel in changed), default=0)
    print("backed_off=%d unstamped=%d oldest_unstamped=%dd" % (len(skipped), len(changed), oldest // 86400))


def cmd_seed(a):
    files = {rel: sha256(os.path.join(a.root, rel)) for rel in corpus_files(a.root, os.path.basename(a.out))}
    write_json_atomic(os.path.join(a.out, MANIFEST), {"version": 1, "files": files})
    print("seed: stamped %d files as the semantic baseline" % len(files))


def norm_src(src, scratch):
    if not isinstance(src, str):
        return src
    s = src.replace(os.sep, "/")
    prefix = scratch.replace(os.sep, "/").rstrip("/") + "/"
    return s[len(prefix):] if s.startswith(prefix) else s


SHRINK_RATIO = 0.5


def count_semantic(nodes, rel):
    return sum(1 for n in nodes if n.get("_origin", "semantic") == "semantic" and n.get("source_file") == rel)


def shrinks(old_nodes, new_nodes, rel):
    # The one shrink guard: the merge path and the AST-restore path (below) both
    # decide "this file lost too much" here. A single old node cannot shrink.
    old = count_semantic(old_nodes, rel)
    return old >= 2 and count_semantic(new_nodes, rel) < old * SHRINK_RATIO


def evict_cache(dirs, rels, scratch):
    # graphify caches one entry per source file: drop the entries that hold only
    # these files, so their retry is a fresh extraction, not a cached replay.
    for d in dirs:
        for dp, _, fns in os.walk(d):
            for fn in fns:
                p = os.path.join(dp, fn)
                try:
                    with open(p, encoding="utf-8") as f:
                        entry = json.load(f)
                except (OSError, ValueError):
                    continue
                if not isinstance(entry, dict):
                    continue
                srcs = {norm_src(i.get("source_file"), scratch) for b in ("nodes", "edges", "hyperedges")
                        for i in entry.get(b) or [] if isinstance(i, dict) and i.get("source_file")}
                if len(srcs) == 1 and srcs <= rels:
                    os.remove(p)
                    print("semantic-merge: evicted cache entry %s for %s" % (p, srcs.pop()), file=sys.stderr)


def edge_key(e):
    return (e.get("source"), e.get("target"), e.get("relation"), e.get("source_file"))


def cmd_restore(a):
    # After an AST rebuild (`graphify update`, which re-extracts code files and
    # replaces their nodes): put back every semantic node, edge and hyperedge the
    # rebuilt graph lost. The AST pass owns `_origin: ast`; semantic items are
    # never its to drop.
    before = load_json(a.before)
    graph_path = os.path.join(a.out, "graph.json")
    g = load_json(graph_path)
    ekey = "edges" if "edges" in g and "links" not in g else "links"
    old_ekey = "edges" if "edges" in before and "links" not in before else "links"
    g.setdefault(ekey, [])
    live_ids = {n.get("id") for n in g.get("nodes", [])}
    restored_n = restored_e = restored_h = 0
    for n in before.get("nodes", []):
        if n.get("_origin") == "semantic" and n.get("id") not in live_ids:
            g["nodes"].append(n)
            live_ids.add(n.get("id"))
            restored_n += 1
    have = {edge_key(e) for e in g[ekey]}
    for e in before.get(old_ekey, []):
        if e.get("_origin") == "semantic" and edge_key(e) not in have \
                and e.get("source") in live_ids and e.get("target") in live_ids:
            g[ekey].append(e)
            have.add(edge_key(e))
            restored_e += 1
    have_h = {h.get("id") for h in g.get("hyperedges") or []}
    for h in before.get("hyperedges") or []:
        if h.get("_origin") == "semantic" and h.get("id") not in have_h:
            members = [m for m in h.get("nodes", []) if m in live_ids]
            if len(members) >= 2:
                g.setdefault("hyperedges", []).append(dict(h, nodes=members))
                restored_h += 1
    if not (restored_n or restored_e or restored_h):
        return
    write_json_atomic(graph_path, g)
    run = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "name": "ast-update",
           "ast_restored_nodes": restored_n, "ast_restored_edges": restored_e, "ast_restored_hyperedges": restored_h}
    with open(os.path.join(a.out, RUNS), "a", encoding="utf-8") as f:
        f.write(json.dumps(run) + "\n")
    print("semantic-merge: restored %d semantic node(s), %d edge(s), %d hyperedge(s) the AST rebuild dropped"
          % (restored_n, restored_e, restored_h), file=sys.stderr)


def cmd_merge(a):
    plan = load_json(a.plan)
    graph_path = os.path.join(a.out, "graph.json")
    g = load_json(graph_path)
    ekey = "links" if "links" in g else "edges"
    batch = set(plan["batch"])

    sg = {"nodes": [], ekey: [], "hyperedges": []}
    if batch:
        sg = load_json(os.path.join(a.scratch, "graphify-out", "graph.json"))
    s_edges = sg.get("links", sg.get("edges", []))

    def semantic(item):
        return item.get("_origin", "semantic") != "ast"

    new_nodes = [n for n in sg.get("nodes", []) if semantic(n)]
    new_edges = [e for e in s_edges if semantic(e)]
    new_hyper = [h for h in sg.get("hyperedges", []) or [] if semantic(h)]
    for item in new_nodes + new_edges + new_hyper:
        item["source_file"] = norm_src(item.get("source_file"), a.scratch)
        item["_origin"] = "semantic"
    # A scratch path anywhere in what we are about to promote is a host-path
    # leak (same class refresh-graph-map.sh's promote scan refuses).
    if a.scratch in json.dumps(new_nodes + new_edges + new_hyper, ensure_ascii=False):
        die("REFUSING merge: the scratch path %s leaks into the extraction" % a.scratch, 2)

    # A batch file the extraction produced nothing for is a failed chunk (the
    # model omitted it): it keeps its old semantic items and stays unstamped,
    # so the next run retries it (up to MAX_ATTEMPTS, see the stuck record
    # below). Only produced and deleted files are replaced.
    #
    # Shrink guard: a produced file whose extraction holds under
    # SHRINK_RATIO of its old semantic nodes is refused like a failed chunk --
    # old items kept, file unstamped, retried next run. A model that returns a
    # thin subset must not silently erase real facts (pr-check doc 25 to 1).
    # ponytail: nodes between 50 and 100 percent of the old count still replace the file's items, add a per-node union if semantic-runs.jsonl shows losses there.
    produced = {n.get("source_file") for n in new_nodes}
    refused = sorted(f for f in batch & produced if shrinks(g["nodes"], new_nodes, f))
    reasons = {}
    for f in refused:
        reasons[f] = "shrink guard: new %d vs old %d semantic nodes" % (count_semantic(new_nodes, f), count_semantic(g["nodes"], f))
        print("semantic-merge: shrink guard REFUSED %s: new extraction has %d semantic nodes, old has %d; keeping the old ones, file stays unstamped"
              % (f, count_semantic(new_nodes, f), count_semantic(g["nodes"], f)), file=sys.stderr)
    produced -= set(refused)
    new_nodes = [n for n in new_nodes if n.get("source_file") not in refused]
    new_edges = [e for e in new_edges if e.get("source_file") not in refused]
    new_hyper = [h for h in new_hyper if h.get("source_file") not in refused]
    failed = sorted(batch - produced - set(refused))
    for f in failed:
        reasons[f] = "not extracted: graphify skipped the file or the model omitted it"
    touched = (batch & produced) | set(plan["deleted"])

    def owned(item):
        return item.get("_origin") == "semantic" and item.get("source_file") in touched

    # Remove the owned items, add the new nodes, and only THEN prune edges
    # against the final node set: an untouched file's edge to a node the
    # re-extraction restores must survive.
    before_n, before_e = len(g["nodes"]), len(g[ekey])
    g["nodes"] = [n for n in g["nodes"] if not owned(n)]
    live_ids = {n["id"] for n in g["nodes"]}
    nodes_removed = before_n - len(g["nodes"])
    g["hyperedges"] = [h for h in g.get("hyperedges") or [] if not owned(h)]

    nodes_added = 0
    for n in new_nodes:
        if n["id"] not in live_ids:
            g["nodes"].append(n)
            live_ids.add(n["id"])
            nodes_added += 1
    g[ekey] = [e for e in g[ekey] if not owned(e) and e["source"] in live_ids and e["target"] in live_ids]
    edges_removed = before_e - len(g[ekey])
    edges_added = 0
    for e in new_edges:
        if e.get("source") in live_ids and e.get("target") in live_ids:
            g[ekey].append(e)
            edges_added += 1
    # Hyperedge members follow their nodes: prune removed ids, and drop a
    # hyperedge left with fewer than two members.
    hyper = []
    for h in g["hyperedges"] + new_hyper:
        h["nodes"] = [m for m in h.get("nodes", []) if m in live_ids]
        if len(h["nodes"]) >= 2:
            hyper.append(h)
    g["hyperedges"] = hyper

    # The manifest dict is computed (files hashed) first, so a hashing failure
    # leaves graph.json untouched. graph.json is then written BEFORE the
    # manifest: a file is stamped only once its graph content landed, and a
    # crash between the two leaves it unstamped, so the next run re-replaces it
    # by source_file (idempotent).
    m = load_manifest(a.out)
    files, stuck = m.get("files", {}), m.get("stuck", {})
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    for rel in plan["deleted"]:
        files.pop(rel, None)
        stuck.pop(rel, None)
    newly_backed_off = []
    for rel in sorted(batch):
        digest = sha256(os.path.join(a.scratch, rel))
        if rel not in reasons:
            files[rel] = digest
            stuck.pop(rel, None)
            continue
        rec = stuck.get(rel)
        if not rec or rec.get("hash") != digest:
            rec = {"hash": digest, "attempts": 0, "since": ts}
        rec["attempts"] += 1
        rec["reason"] = reasons[rel]
        stuck[rel] = rec
        if rec["attempts"] == MAX_ATTEMPTS:
            newly_backed_off.append(rel)
            print("semantic-merge: BACKED OFF %s after %d attempts (%s); not retried until its content changes"
                  % (rel, MAX_ATTEMPTS, reasons[rel]), file=sys.stderr)
    write_json_atomic(graph_path, g)
    write_json_atomic(os.path.join(a.out, MANIFEST), {"version": 1, "files": files, "stuck": stuck})
    if reasons:
        evict_cache(a.evict_cache, set(reasons), a.scratch)

    run = {
        "ts": ts,
        "name": a.name, "changed_total": plan["changed_total"], "batch": len(batch),
        "deleted": len(plan["deleted"]), "backlog": plan["backlog"], "failed": len(failed),
        "shrink_refused": len(refused), "failed_files": failed, "refused_files": refused,
        "backed_off": len(plan.get("backed_off", [])) + len(newly_backed_off),
        "backed_off_files": sorted(set(plan.get("backed_off", [])) | set(newly_backed_off)),
        "nodes_added": nodes_added, "nodes_removed": nodes_removed,
        "edges_added": edges_added, "edges_removed": edges_removed,
        "runtime_s": a.runtime_s, "tokens_in": a.tokens_in, "tokens_out": a.tokens_out,
        "cost_eq_usd": round(a.tokens_in / 1e6 * PRICE_IN + a.tokens_out / 1e6 * PRICE_OUT, 4),
        "backend": a.backend, "cost_usd": round(a.cost_usd, 6), "cap_usd": a.cap_usd,
    }
    with open(os.path.join(a.out, RUNS), "a", encoding="utf-8") as f:
        f.write(json.dumps(run) + "\n")
    print("merge: " + json.dumps(run))


def cmd_failrow(a):
    # An extraction that died after billing lane calls: the spend still gets a row, nothing else changes.
    run = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "name": a.name, "extract_rc": a.rc,
           "backend": a.backend, "cost_usd": round(a.cost_usd, 6)}
    with open(os.path.join(a.out, RUNS), "a", encoding="utf-8") as f:
        f.write(json.dumps(run) + "\n")
    print("failrow: " + json.dumps(run))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--root", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--max-files", type=int, required=True)
    p.add_argument("--plan", required=True)
    s = sub.add_parser("seed")
    s.add_argument("--root", required=True)
    s.add_argument("--out", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--name", required=True)
    m.add_argument("--out", required=True)
    m.add_argument("--scratch", required=True)
    m.add_argument("--plan", required=True)
    m.add_argument("--runtime-s", type=int, default=0)
    m.add_argument("--tokens-in", type=int, default=0)
    m.add_argument("--tokens-out", type=int, default=0)
    m.add_argument("--backend", default="")
    m.add_argument("--cost-usd", type=float, default=0.0)
    m.add_argument("--cap-usd", type=float, default=0.0)
    m.add_argument("--evict-cache", action="append", default=[])
    f = sub.add_parser("failrow")
    f.add_argument("--name", required=True)
    f.add_argument("--out", required=True)
    f.add_argument("--backend", default="")
    f.add_argument("--cost-usd", type=float, default=0.0)
    f.add_argument("--rc", type=int, default=0)
    r = sub.add_parser("restore")
    r.add_argument("--out", required=True)
    r.add_argument("--before", required=True)
    st = sub.add_parser("status")
    st.add_argument("--root", required=True)
    st.add_argument("--out", required=True)
    a = ap.parse_args()
    {"plan": cmd_plan, "seed": cmd_seed, "merge": cmd_merge, "failrow": cmd_failrow, "restore": cmd_restore,
     "status": cmd_status}[a.cmd](a)


if __name__ == "__main__":
    main()
