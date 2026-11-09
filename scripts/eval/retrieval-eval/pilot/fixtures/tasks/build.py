#!/usr/bin/env python3
"""Writes a FIXTURE task world for the B8 suite into OUT/: two pinned export manifests
(himmel.json, luna.json), a valid 40-task fixture bank (bank.jsonl) with made-up questions
about made-up files, and two fixture session transcripts for the miner. No real task, no real
transcript: every string here is synthetic.
Usage: build.py OUT
"""
import hashlib, json, os, sys

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
KINDS = [("luna_lookup", 6), ("luna_meaning", 8), ("himmel_docs", 6), ("himmel_code", 8), ("two_files", 8), ("not_there", 4)]


def sha(s):
    return hashlib.sha256(s.encode()).hexdigest()


himmel, luna, bank = {}, {}, []
n = 0
for kind, count in KINDS:
    for i in range(count):
        n += 1
        tid = "t%02d" % n
        half = "real" if n % 2 else "harder"
        if kind.startswith("luna"):
            files = [{"repo": "luna", "path": "notes/%s-%d.md" % (kind, i)}]
            luna[files[0]["path"]] = sha(tid)
            stratum = "doc"
        elif kind == "himmel_docs":
            files = [{"repo": "himmel", "path": "docs/topic-%d.md" % i}]
            himmel[files[0]["path"]] = sha(tid)
            stratum = "doc"
        elif kind == "himmel_code":
            files = [{"repo": "himmel", "path": "scripts/tool-%d.sh" % i}]
            himmel[files[0]["path"]] = sha(tid)
            stratum = "code"
        elif kind == "two_files":
            files = [{"repo": "himmel", "path": "docs/pair-%d.md" % i}, {"repo": "himmel", "path": "scripts/pair-%d.py" % i}]
            for f in files:
                himmel[f["path"]] = sha(tid + f["path"])
            stratum = "mixed"
        else:
            files, stratum = [], "none"
        answerable = kind != "not_there"
        facts = [{"text": "fixture fact %d" % n, "variants": ["fact %d" % n], "files": [f["path"] for f in files]}] if answerable else []
        prov = {"method": "transcript" if half == "real" else "written", "discovery": "grep" if n % 3 else "read",
                "source": "fixture-session-%d" % (n % 2) if half == "real" else "fixture-writer"}
        if half == "real":
            prov["sampling_rule"] = "seeded sample of mined questions, seed 7"
        bank.append({"id": tid, "question": "Fixture question number %d?" % n, "kind": kind, "half": half,
                     "answerability": "answerable" if answerable else "not_there", "stratum": stratum,
                     "facts": facts, "files": files, "provenance": prov, "reachability": "fixture"})

for name, files in (("himmel", himmel), ("luna", luna)):
    files.setdefault("handovers-free.md", sha(name))
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump({"files": {p: {"sha256": h, "size": 1} for p, h in files.items()}, "symlinks": {}, "count": len(files)}, f)
with open(os.path.join(OUT, "bank.jsonl"), "w") as f:
    for t in bank:
        f.write(json.dumps(t) + "\n")

os.makedirs(os.path.join(OUT, "sessions"), exist_ok=True)
msgs = [
    ("user", "where is the fixture queue lock described?"),
    ("assistant", "In the docs."),
    ("user", "ok thanks"),
    ("user", "How does the fixture relay batch decide its size"),
    ("user", "Why did the fixture build fail?"),
    ("user", "<command-name>/clear</command-name>"),
    ("user", "where is the fixture queue lock described?"),
]
for k in range(2):
    with open(os.path.join(OUT, "sessions", "s%d.jsonl" % k), "w") as f:
        for role, text in msgs[k * 3:] if k else msgs:
            f.write(json.dumps({"type": role, "message": {"role": role, "content": text}}) + "\n")
