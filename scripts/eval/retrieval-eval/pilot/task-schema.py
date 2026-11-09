#!/usr/bin/env python3
"""task-schema.py -- validate and seal the RAG pilot's private 40-task bank (design section 5).

  task-schema.py validate BANK.jsonl --manifest himmel=M --manifest luna=M
  task-schema.py seal BANK.jsonl --manifest himmel=M --manifest luna=M --out SEAL.json

A bank holds exactly 40 tasks: 6 luna_lookup, 8 luna_meaning, 6 himmel_docs, 8 himmel_code,
8 two_files, 4 not_there; 20 real and 20 harder. Each task has a question, 1 to 3 required
facts (none for not_there), each with at most 3 accepted variants and the task files that hold
it; its files exist in the pinned export manifests, outside handovers/ and the pilot dir; one
task per source file; a doc/code/mixed source stratum that matches its files; provenance with
the discovery method (and the sampling rule for a real task); answerability and reachability.

`seal` writes the private seal (bank sha256, the sorted ids, all counts; mode 600) and prints
only the public counts: never a question, fact, path or id. The bank itself stays private and
outside every repo, qmd collection and graph; this tool never writes it.
Exit 0 ok, 3 invalid (every problem on stderr), 2 usage.
"""
import argparse, collections, hashlib, json, os, sys

KINDS = {"luna_lookup": 6, "luna_meaning": 8, "himmel_docs": 6, "himmel_code": 8, "two_files": 8, "not_there": 4}
HALVES = {"real": 20, "harder": 20}
DISCOVERY = {"read", "grep", "qmd", "graph", "transcript"}
EXCLUDED = ("handovers/", "scripts/eval/retrieval-eval/pilot/")


def stratum_of(files):
    kinds = {"doc" if f["path"].endswith(".md") else "code" for f in files}
    return "none" if not kinds else ("mixed" if len(kinds) > 1 else kinds.pop())


def problems(bank, manifests):
    out = []
    if len(bank) != 40:
        out.append("the bank has %d tasks, the protocol needs exactly 40 tasks" % len(bank))
    ids = collections.Counter(t.get("id") for t in bank)
    out += ["duplicate id %s" % i for i, c in ids.items() if c > 1]
    kinds = collections.Counter(t.get("kind") for t in bank)
    for t in bank:
        tid = t.get("id")
        k = t.get("kind")
        if k not in KINDS:
            out.append("%s: unknown kind %s" % (tid, k))
        if t.get("half") not in HALVES:
            out.append("%s: unknown half %s" % (tid, t.get("half")))
        if not str(t.get("question", "")).strip():
            out.append("%s: no question" % tid)
        files = t.get("files") or []
        facts = t.get("facts") or []
        not_there = k == "not_there"
        if not_there != (t.get("answerability") == "not_there"):
            out.append("%s: not_there kind and answerability disagree" % tid)
        if not_there and (facts or files):
            out.append("%s: a not_there task holds no facts or files" % tid)
        if not not_there and not 1 <= len(facts) <= 3:
            out.append("%s: %d required facts, 1 to 3 allowed" % (tid, len(facts)))
        if k == "two_files" and len(files) < 2:
            out.append("%s: a two_files task needs two files" % tid)
        repos = {f.get("repo") for f in files}
        if k and k.startswith("luna") and repos - {"luna"}:
            out.append("%s: a %s task sources luna only" % (tid, k))
        if k in ("himmel_docs", "himmel_code") and repos - {"himmel"}:
            out.append("%s: a %s task sources himmel only" % (tid, k))
        paths = {f.get("path") for f in files}
        for fact in facts:
            if not str(fact.get("text", "")).strip():
                out.append("%s: an empty fact" % tid)
            if len(fact.get("variants") or []) > 3:
                out.append("%s: a fact has %d variants, at most 3" % (tid, len(fact["variants"])))
            if not fact.get("files") or set(fact["files"]) - paths:
                out.append("%s: a fact file is not one of the task files" % tid)
        for f in files:
            p = f.get("path", "")
            if p.startswith(EXCLUDED) or "/handovers/" in p:
                out.append("%s: source %s is in an excluded path" % (tid, p))
            elif p not in (manifests.get(f.get("repo")) or {}):
                out.append("%s: source %s:%s is not at the pin" % (tid, f.get("repo"), p))
        if t.get("stratum") != stratum_of(files):
            out.append("%s: source stratum %s does not match its files (%s)" % (tid, t.get("stratum"), stratum_of(files)))
        prov = t.get("provenance")
        if not isinstance(prov, dict) or not prov.get("method") or prov.get("discovery") not in DISCOVERY or not prov.get("source"):
            out.append("%s: missing or incomplete provenance" % tid)
        elif t.get("half") == "real" and not prov.get("sampling_rule"):
            out.append("%s: a real task records its sampling_rule" % tid)
        if not t.get("reachability"):
            out.append("%s: no reachability record" % tid)
    seen = {}
    for t in bank:
        for f in t.get("files") or []:
            key = (f.get("repo"), f.get("path"))
            if key in seen and seen[key] != t.get("id"):
                out.append("%s: reused source %s:%s (also %s)" % (t.get("id"), key[0], key[1], seen[key]))
            seen.setdefault(key, t.get("id"))
    if all(t.get("kind") in KINDS for t in bank) and dict(kinds) != KINDS:
        out.append("kind counts %s, the protocol needs %s" % (dict(kinds), KINDS))
    halves = collections.Counter(t.get("half") for t in bank)
    if all(t.get("half") in HALVES for t in bank) and dict(halves) != HALVES:
        out.append("halves %s, the protocol needs 20 real and 20 harder" % dict(halves))
    return out


def counts(bank):
    c = lambda key: dict(sorted(collections.Counter(key(t) for t in bank).items()))
    return {"tasks": len(bank), "kinds": c(lambda t: t["kind"]), "halves": c(lambda t: t["half"]),
            "strata": c(lambda t: t["stratum"]), "discovery": c(lambda t: t["provenance"]["discovery"]),
            "provenance_methods": c(lambda t: t["provenance"]["method"])}


def main(argv):
    p = argparse.ArgumentParser(prog="task-schema.py")
    p.add_argument("cmd", choices=["validate", "seal"])
    p.add_argument("bank")
    p.add_argument("--manifest", action="append", default=[], required=True)
    p.add_argument("--out")
    a = p.parse_args(argv)
    manifests = {}
    for m in a.manifest:
        name, path = m.split("=", 1)
        with open(path) as f:
            mf = json.load(f)
        manifests[name] = set(mf["files"]) | set(mf.get("symlinks", {}))
    raw = open(a.bank, "rb").read()
    try:
        bank = [json.loads(l) for l in raw.decode().splitlines() if l.strip()]
    except ValueError as e:
        print("task-schema: invalid: unparseable bank line: %s" % e, file=sys.stderr)
        return 3
    bad = problems(bank, manifests)
    if bad:
        for b in bad:
            print("task-schema: invalid: %s" % b, file=sys.stderr)
        return 3
    summary = counts(bank)
    if a.cmd == "seal":
        if not a.out:
            print("task-schema: seal needs --out", file=sys.stderr)
            return 2
        seal = dict(summary, bank_sha256=hashlib.sha256(raw).hexdigest(), ids=sorted(t["id"] for t in bank))
        fd = os.open(a.out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(seal, f, indent=1, sort_keys=True)
        os.chmod(a.out, 0o600)
    print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
