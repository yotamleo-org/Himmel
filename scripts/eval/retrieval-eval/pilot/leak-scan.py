#!/usr/bin/env python3
"""leak-scan.py -- P12: no private task question, id or private path in the copies or indexes.

  leak-scan.py --bank B.jsonl [--export NAME=DIR]... [--index DB]... [--private PATH]...
               [--config QMD_YML --run-root DIR]... [--private-out F]

Reads the export copies and the index text tables LOCALLY with plain file and SQLite reads:
it never runs qmd, graphify or any search. Every task question (whitespace/case-normalized),
task id (as a whole word) and private path (the bank file itself, the run root's private/ and
retained/ when --run-root is given, and every --private path) must appear ZERO times. A
requested export root or index that does not exist, or a scan that read nothing, refuses: an
empty scan is never a clean verdict. Required facts are expected in their sources: their occurrence counts go
to the checker, never a failure. A qmd collection whose path covers the run root fails. Output is
counts only (never the leaked text); which task leaked goes to --private-out (mode 600).
Exit 0 clean, 3 leak or coverage failure.
"""
import argparse, json, os, re, sqlite3, sys

SKIP_TABLES = re.compile(r"^(llm_cache|vectors_by_collection.*|documents_fts_(data|idx|docsize|config)|sqlite_.*)$")


def norm(s):
    return " ".join(str(s).lower().split())


def texts_from_exports(exports):
    for name, root in exports.items():
        for dp, _, fns in os.walk(root):
            for n in fns:
                p = os.path.join(dp, n)
                if os.path.islink(p):
                    continue
                try:
                    with open(p, "rb") as f:
                        data = f.read()
                except OSError:
                    continue
                if b"\0" in data[:4096]:
                    continue
                yield "export", "%s/%s" % (name, os.path.relpath(p, root)), data.decode("utf-8", "replace")


def texts_from_index(db):
    c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    try:
        for (t,) in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall():
            if SKIP_TABLES.match(t):
                continue
            try:
                cur = c.execute('SELECT * FROM "%s"' % t)
            except sqlite3.Error:
                continue
            for row in cur:
                vals = [v for v in row if isinstance(v, str)]
                if vals:
                    yield "index", "%s:%s" % (os.path.basename(db), t), "\n".join(vals)
    finally:
        c.close()


def covers(config_text, run_root):
    root = os.path.realpath(run_root)
    bad = []
    for m in re.finditer(r"^\s+path:\s*(\S+)\s*$", config_text, re.M):
        p = os.path.realpath(m.group(1).strip("\"'"))
        if root == p or root.startswith(p.rstrip("/") + "/"):
            bad.append(p)
    return bad


def scan(bank, exports, indexes, private_paths):
    qs = {t["id"]: norm(t["question"]) for t in bank if t.get("question")}
    ids = {t["id"]: re.compile(r"(?<![\w-])%s(?![\w-])" % re.escape(t["id"])) for t in bank}
    facts = {"%s#%d" % (t["id"], i): [norm(f["text"])] + [norm(v) for v in f.get("variants") or []]
             for t in bank for i, f in enumerate(t.get("facts") or [])}
    found = {"questions": [], "ids": [], "paths": []}
    seen = {k: 0 for k in facts}
    where = {"export": 0, "index": 0}
    sources = list(texts_from_exports(exports))
    for db in indexes:
        sources += list(texts_from_index(db))
    for kind, loc, text in sources:
        n = norm(text)
        hit = False
        for tid, q in qs.items():
            if len(q) >= 12 and q in n:
                found["questions"].append((tid, loc)); hit = True
        for tid, rx in ids.items():
            if rx.search(text):
                found["ids"].append((tid, loc)); hit = True
        for p in private_paths:
            if p and p in text:
                found["paths"].append((p, loc)); hit = True
        for k, vs in facts.items():
            if any(v and v in n for v in vs):
                seen[k] += 1
        where[kind] += int(hit)
    return found, seen, where, len(sources)


def main(argv):
    ap = argparse.ArgumentParser(prog="leak-scan.py")
    ap.add_argument("--bank", required=True)
    ap.add_argument("--export", action="append", default=[]); ap.add_argument("--index", action="append", default=[])
    ap.add_argument("--private", action="append", default=[])
    ap.add_argument("--config", action="append", default=[]); ap.add_argument("--run-root")
    ap.add_argument("--private-out")
    a = ap.parse_args(argv)
    bank = [json.loads(l) for l in open(a.bank) if l.strip()]
    exports = dict(e.split("=", 1) for e in a.export)
    missing = [r for r in exports.values() if not os.path.isdir(r)] + [i for i in a.index if not os.path.isfile(i)]
    if missing:
        print("leak-scan: refused: %d requested export root(s) or index(es) do not exist: no clean verdict without them" % len(missing), file=sys.stderr)
        return 3
    privs = list(a.private) + [os.path.abspath(a.bank)]
    if a.run_root:
        privs += [os.path.join(os.path.abspath(a.run_root), d) for d in ("private", "retained")]
    found, seen, where, n = scan(bank, exports, a.index, privs)
    if n == 0:
        print("leak-scan: refused: nothing was scanned (no export or index text): no clean verdict", file=sys.stderr)
        return 3
    cover = []
    if a.run_root:
        for cfg in a.config:
            cover += covers(open(cfg).read(), a.run_root)
    out = {"sources_scanned": n, "question_leaks": len(found["questions"]), "id_leaks": len(found["ids"]),
           "private_path_leaks": len(found["paths"]), "sources_with_leaks": where, "collection_covers_run_root": len(cover),
           "facts_for_checker": {"facts": len(seen), "seen_in_sources": sum(1 for v in seen.values() if v), "never_seen": sum(1 for v in seen.values() if not v)}}
    if a.private_out:
        fd = os.open(a.private_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump({"found": found, "fact_counts": seen, "covering_collections": cover}, f, indent=1)
    print(json.dumps(out, sort_keys=True))
    bad = out["question_leaks"] or out["id_leaks"] or out["private_path_leaks"] or out["collection_covers_run_root"]
    return 3 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
