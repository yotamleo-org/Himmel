#!/usr/bin/env python3
"""Writes the B10 fixture world into OUT/: two small source repos (src-himmel, src-luna, not
yet committed), a synthetic 40-task bank (bank.jsonl) whose facts live in those files, an
old-75-style legacy bank (legacy.jsonl, gold file names only) and hits.json, the fixed answers
fake-qmd-lists gives per question marker. Every string is synthetic.
Usage: build.py OUT
"""
import hashlib, json, os, sys

OUT = sys.argv[1]
KINDS = [("luna_lookup", 6), ("luna_meaning", 8), ("himmel_docs", 6), ("himmel_code", 8), ("two_files", 8), ("not_there", 4)]
files = {}
bank, hits = [], []


def add(repo, path, text):
    files[(repo, path)] = text
    return {"repo": repo, "path": path}


n = 0
for kind, count in KINDS:
    for i in range(count):
        n += 1
        tid, marker, fact = "t%02d" % n, "qid-%02d" % n, "token%02dx" % n
        if kind.startswith("luna"):
            fl = [add("luna", "notes/%s-%d.md" % (kind, i), "# Note %d\nThe answer for %s is %s.\n" % (n, marker, fact))]
            stratum = "doc"
        elif kind == "himmel_docs":
            fl = [add("himmel", "docs/topic-%d.md" % i, "# Topic %d\nThe answer for %s is %s.\n" % (n, marker, fact))]
            stratum = "doc"
        elif kind == "himmel_code":
            fl = [add("himmel", "scripts/tool-%d.sh" % i, "#!/bin/sh\n# answer for %s: %s\n" % (marker, fact))]
            stratum = "code"
        elif kind == "two_files":
            fl = [add("himmel", "docs/pair-%d.md" % i, "# Pair %d\nSee scripts/pair-%d.py for %s.\n" % (n, i, marker)),
                  add("himmel", "scripts/pair-%d.py" % i, "ANSWER = '%s'  # %s\n" % (fact, marker))]
            stratum = "mixed"
        else:
            fl, stratum = [], "none"
        facts = [{"text": fact, "variants": [], "files": [f["path"] for f in fl if fact in files[(f["repo"], f["path"])]]}] if fl else []
        bank.append({"id": tid, "question": "Which token answers %s?" % marker, "kind": kind, "half": "real" if n % 2 else "harder",
                     "answerability": "answerable" if fl else "not_there", "stratum": stratum, "facts": facts, "files": fl,
                     "provenance": {"method": "written", "discovery": "read", "source": "fixture"}, "reachability": "fixture"})
        if kind == "two_files":
            ret = [fl[0]]
        elif n == 3:
            ret = [{"repo": "luna", "path": "notes/luna_lookup-0.md"}]
        elif fl:
            ret = fl
        else:
            ret = [{"repo": "luna", "path": "notes/luna_lookup-1.md"}]
        hits.append({"match": marker, "files": ret})
add("himmel", "docs/unrelated.md", "# Unrelated\nNothing here.\n")

for (repo, path), text in files.items():
    full = os.path.join(OUT, "src-" + repo, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(text)
for h in hits:
    h["files"] = [{"file": "qmd://%s/%s?index=eval" % (f["repo"], f["path"]),
                   "docid": "#" + hashlib.sha256(files[(f["repo"], f["path"])].encode()).hexdigest()[:6]} for f in h["files"]]
with open(os.path.join(OUT, "hits.json"), "w") as f:
    json.dump(hits, f)
with open(os.path.join(OUT, "bank.jsonl"), "w") as f:
    f.writelines(json.dumps(t) + "\n" for t in bank)
with open(os.path.join(OUT, "legacy.jsonl"), "w") as f:
    for t in bank[:6]:
        f.write(json.dumps({"id": "old-" + t["id"], "q": t["question"], "gold": [x["path"] for x in t["files"]]}) + "\n")
