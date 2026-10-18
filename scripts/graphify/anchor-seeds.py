#!/usr/bin/env python3
"""anchor-seeds.py -- start a graph query from the files and identifiers the question names.

graphify seeds on the question's words: it drops tokens of two letters or fewer (go.sh becomes
nothing), and a one-word label such as tail() or status() outranks the leg_tail_status the
question asked about. leg-graph.sh uses the two verbs below to fix that from outside graphify:

  seeds <graph.json> <question>
      Prints one node id per line for each anchor that resolves. An anchor is a question token
      carrying a path, an extension, '-' or '_'. It resolves to a file node by path, path
      suffix, basename or stem, else to a node whose label without '()' is the token (case
      ignored). A test file loses to a non-test one unless the token names a test. At most
      MAX_PER_ANCHOR ids per anchor. Prints nothing when nothing resolves.

  merge <given-answer> <keyword-answer> <budget>
      Merges a `graphify query --seed ...` answer with the plain keyword answer: header naming
      both start lists, the given answer's nodes first, no node or edge twice, and one
      TRUNCATED notice sized for both halves. Exits 1 on an answer shape it does not know, so
      the caller prints the keyword answer alone.

Fails open: an unreadable graph prints no seeds and says so on stderr.
ponytail: names only, not meaning; a question with no file or identifier keeps graphify's own
seeding (the HIMMEL-6143 follow-up on semantic retrieval is the upgrade path).
"""
import json
import re
import sys

MAX_PER_ANCHOR = 2
TOKEN = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./-]*[A-Za-z0-9_]")
TEST = re.compile(r"(^|/)(tests?|fixtures?)/|(^|/)test[-_]|[._-]test\.[a-z]+$|\.test\.")
HEADER = re.compile(r"^(?P<pre>.*?\| Start(?: \(given\))?: )(?P<start>\[.*\])(?P<rest>.*?) \| (?P<n>\d+) nodes found$")
NOTICE = re.compile(r"^\[!\] TRUNCATED: showing (\d+) of (\d+) nodes .*?--budget (\d+)")
END_MARK = re.compile(r"^\.\.\. \(truncated — (\d+) more nodes cut")


def anchors(question):
    out = []
    for t in TOKEN.findall(question):
        if ("/" in t or "_" in t or "-" in t or re.search(r"\.[A-Za-z]{1,4}$", t)) and t not in out:
            out.append(t)
    return out


def seeds(graph, question):
    nodes = graph.get("nodes", [])
    files = {}
    for n in nodes:
        src = n.get("source_file") or ""
        if src and n.get("label") == src.rsplit("/", 1)[-1]:
            files.setdefault(src, []).append(n)
    picked = []
    for a in anchors(question):
        al = a.lower()
        hits = []
        for src, ns in files.items():
            low = src.lower()
            base = low.rsplit("/", 1)[-1]
            if al in (low, base, base.rsplit(".", 1)[0]) or low.endswith("/" + al):
                hits.extend(ns)
        if not hits:
            hits = [n for n in nodes if n.get("source_file") and (n.get("label") or "").removesuffix("()").lower() == al]
        if "test" not in al:
            hits = [n for n in hits if not TEST.search(n.get("source_file") or "")] or hits
        hits.sort(key=lambda n: (len(n.get("source_file") or ""), str(n.get("id"))))
        for n in hits[:MAX_PER_ANCHOR]:
            if n.get("id") is not None and n["id"] not in picked:
                picked.append(n["id"])
    return picked


def parse(text):
    """Split a query answer into header match, NODE blocks, EDGE lines and cut counts."""
    lines = text.split("\n")
    header = HEADER.match(lines[0]) if lines else None
    if not header:
        return None
    blocks, edges, shown_total, cut, full = [], [], None, 0, 0
    for line in lines[1:]:
        if line.startswith("NODE "):
            blocks.append([line])
        elif line.startswith("  ") and blocks:
            blocks[-1].append(line)
        elif line.startswith("EDGE "):
            edges.append(line)
        elif m := NOTICE.match(line):
            shown_total, full = (int(m.group(1)), int(m.group(2))), int(m.group(3))
        elif m := END_MARK.match(line):
            cut = int(m.group(1))
        elif line.strip() and not line.startswith("[i] Complete answer over budget"):
            return None
    return header, blocks, edges, cut, full, shown_total


def merge(given_text, keyword_text, budget):
    given, keyword = parse(given_text), parse(keyword_text)
    if not keyword or not given:
        return None
    gh, gblocks, gedges, gcut, gfull, _ = given
    kh, kblocks, kedges, kcut, kfull, _ = keyword
    seen = {b[0] for b in gblocks}
    blocks = gblocks + [b for b in kblocks if b[0] not in seen]
    edges = list(dict.fromkeys(gedges + kedges))
    overlap = len(gblocks) + len(kblocks) - len(blocks)
    found = int(gh.group("n")) + int(kh.group("n")) - overlap
    head = f"{gh.group('pre')}{gh.group('start')}{gh.group('rest')} | Keyword start: {kh.group('start')} | {found} nodes found"
    out = [head, ""]
    cut = gcut + kcut
    if cut:
        # Each half gets half the budget, so a re-run needs twice the larger half's need.
        need = 2 * max(gfull, kfull, budget // 2)
        out += [f"[!] TRUNCATED: showing {len(blocks)} of {len(blocks) + cut} nodes (~{budget}-token budget). The answer "
                f"may be among the {cut} cut nodes — raise the token budget to {need} to get all {len(blocks) + cut} "
                f"(CLI: --budget {need}, MCP: token_budget={need}) or narrow the query.", ""]
    out += [line for b in blocks for line in b] + edges
    if cut:
        out.append(f"... (truncated — {cut} more nodes cut by ~{budget}-token budget. Narrow the query)")
    return "\n".join(out)


def main():
    verb = sys.argv[1] if len(sys.argv) > 1 else ""
    if verb == "seeds" and len(sys.argv) == 4:
        try:
            with open(sys.argv[2], encoding="utf-8") as fh:
                graph = json.load(fh)
        except Exception as exc:  # fail open: graphify's own seeding still answers
            print(f"anchor-seeds: {exc}; no anchor seeds", file=sys.stderr)
            return 0
        for nid in seeds(graph, sys.argv[3]):
            print(nid)
        return 0
    if verb == "merge" and len(sys.argv) == 5:
        with open(sys.argv[2], encoding="utf-8") as fa, open(sys.argv[3], encoding="utf-8") as fb:
            merged = merge(fa.read().rstrip("\n"), fb.read().rstrip("\n"), int(sys.argv[4]))
        if merged is None:
            return 1
        print(merged)
        return 0
    print("usage: anchor-seeds.py seeds <graph.json> <question> | merge <given> <keyword> <budget>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
