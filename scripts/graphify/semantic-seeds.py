#!/usr/bin/env python3
"""semantic-seeds.py -- start a graph query from the files whose content matches the question's meaning.

graphify seeds on the question's words matched against node labels, so a plain-language question
that names no file or identifier ("who closes the ticket after a merge") starts from one-word labels
such as Need or Token and the file that answers it is missing. leg-graph.sh uses these verbs:

  seeds <graph.json> <question>
      Prints one node id per line: the file node of each of the TOP_FILES files that score best
      against the question. A file is scored as one document: its path words, its document,
      concept and rationale labels, its rationale text and its code labels, TF-IDF weighted
      across all files. Prints nothing when no file scores or the graph cannot be read.
      Files under EVAL_DIR are never candidates.

  scored <graph.json> <question>
      The same ids, preceded by one line "<weak|strong> <top score> <top file>". A match is weak
      when the best file scores under WEAK_IDF x ln(1 + files), about what one shared word earns:
      a seed that weak starts graphify from a common word, not from the answer.

Fails open: an unreadable graph prints no seeds and says so on stderr.
ponytail: word overlap with stemming over graph.json text, no embeddings; a paraphrase sharing no
word with the file stays missed, qmd vectors over the same per-file text are the upgrade path.
"""
import json
import math
import re
import sys
from collections import Counter

TOP_FILES = 3
K1, B = 1.2, 0.75
PATH_BONUS = 10.0
TEST_FACTOR = 0.4
WEAK_IDF = 1.6
EVAL_DIR = "scripts/eval/retrieval-eval/"
TEST = re.compile(r"(^|/)(tests?|fixtures?)/|(^|/)test[-_]|[._-]test\.[a-z]+$|\.test\.")
GENERIC = {"doc", "script", "internal", "test", "src", "lib", "md", "sh", "py", "json", "marketplace", "plugin"}
WEIGHT = {"path": 3.0, "doc": 2.0, "rationale": 1.0, "code": 0.4}
WORD = re.compile(r"[a-z][a-z0-9]+")
STOP = set("""a an and are as at be by can do does for from has have how i in is it its of on or that
the this to was what when where which who whom why will with without while into than then them there
their not no my me we our you your did should would could any every each one only same need needs
work works used use uses""".split())


def stem(w):
    for suf in ("ing", "ed", "s"):
        if w.endswith(suf) and not w.endswith("ss") and len(w) - len(suf) >= 3:
            return w[: -len(suf)]
    return w


def terms(text):
    return [stem(w) for w in WORD.findall(text.lower()) if w not in STOP and len(w) > 2]


def file_docs(graph):
    docs, filenode = {}, {}
    for n in graph.get("nodes", []):
        src = n.get("source_file")
        if not src or n.get("id") is None or src.removeprefix("./").startswith(EVAL_DIR):
            continue
        d = docs.setdefault(src, Counter())
        label = n.get("label") or ""
        if label == src.rsplit("/", 1)[-1]:
            filenode.setdefault(src, n["id"])
        kind = "doc" if n.get("file_type") in ("document", "concept", "rationale", "paper") else "code"
        for t in terms(label):
            d[t] += WEIGHT[kind]
        for t in terms(n.get("rationale") or ""):
            d[t] += WEIGHT["rationale"]
    paths = {}
    for src, d in docs.items():
        paths[src] = set(terms(re.sub(r"[/_.-]", " ", src))) - GENERIC
        for t in paths[src]:
            d[t] += WEIGHT["path"]
    return docs, filenode, paths


def ranked(graph, question):
    """The TOP_FILES best files as (score, file, node id), and the score under which a match is weak."""
    docs, filenode, paths = file_docs(graph)
    q = set(terms(question))
    if not q:
        return [], 0.0
    df = Counter(t for d in docs.values() for t in d)
    n = len(docs)
    avg = sum(sum(d.values()) for d in docs.values()) / max(n, 1)
    scored = []
    for src, d in docs.items():
        if src not in filenode:
            continue
        hit = [t for t in q if t in d]
        if not hit:
            continue
        norm = 1 - B + B * sum(d.values()) / avg
        s = sum(math.log(1 + n / df[t]) * d[t] * (K1 + 1) / (d[t] + K1 * norm) for t in hit)
        pt = paths[src]
        if pt:
            cov = sum(math.log(1 + n / df[t]) for t in pt & q) / sum(math.log(1 + n / df[t]) for t in pt)
            s += PATH_BONUS * cov * len(pt & q) / len(q)
        if TEST.search(src) and "test" not in q:
            s *= TEST_FACTOR
        scored.append((s, src))
    scored.sort(key=lambda x: (-x[0], x[1]))
    return [(s, src, filenode[src]) for s, src in scored[:TOP_FILES]], WEAK_IDF * math.log(1 + n)


def main():
    if len(sys.argv) == 4 and sys.argv[1] in ("seeds", "scored"):
        try:
            with open(sys.argv[2], encoding="utf-8") as fh:
                graph = json.load(fh)
        except Exception as exc:  # fail open: graphify's own seeding still answers
            print(f"semantic-seeds: {exc}; no semantic seeds", file=sys.stderr)
            return 0
        top, weak_under = ranked(graph, sys.argv[3])
        if top and sys.argv[1] == "scored":
            print("weak" if top[0][0] < weak_under else "strong", f"{top[0][0]:.1f}", top[0][1])
        for _, _, nid in top:
            print(nid)
        return 0
    print("usage: semantic-seeds.py seeds|scored <graph.json> <question>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
