#!/usr/bin/env python3
# billed-opt-in: HIMMEL_BILLED_OK
"""matched-lists.py -- the matched S/Q fixed retrieval lists (B10, design section 2).

  matched-lists.py run --bank BANK --mode S|Q --ctx CTX.json --out ROWS.jsonl [--ledger LEDGER]
  matched-lists.py compare --s S.jsonl --q Q.jsonl --expect N

`run` gives every task exactly ONE fixed query: the task question through the pinned
pre-expansion shaper (scripts/qmd/vocab-expand.py, imported unchanged), k=5, through the
same s-qmd wrapper the answer arms use, on a FRESH disposable copy of the sealed master per
query and a fresh host broker in phase=fixed. Adaptive agent queries are never reused. Each
private row carries the task id, the question/query/shaper hashes, the model/config/corpus
and common source-manifest identities, the pin-filtered top 5, fact-bearing-file@5 (a file
that holds a required fact, never just a gold name; not_there is N/A), legacy gold-file@5,
the source stratum, status and timing. A bank may also be the old 75 (gold names only):
those rows are diagnostics with gold-file@5 alone.

S mode spends OpenRouter cash: it refuses without HIMMEL_BILLED_OK=1, books every query
through the caller's ledger callbacks before it runs, and stops launching (the rest marked
unaffordable, the list incomplete) the moment a booking is refused. Q mode is local
compute: it books nothing. `compare` refuses unequal task sets, question/pre-expansion
query/shaper hashes, collection scope or common source manifests (an extra Q-only document
included); the per-backend corpus digests are recorded separately, never compared.
Exit 0 ok, 2 refused opt-in/usage, 3 refusal.
"""
import argparse, hashlib, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
SHAPER = os.path.join(REPO, "scripts", "qmd", "vocab-expand.py")
K = 5


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


def sha(b):
    return hashlib.sha256(b if isinstance(b, bytes) else b.encode()).hexdigest()


def shaper_identity():
    vocab = load(SHAPER, "vocab_expand")
    reg = getattr(vocab, "REGISTRY", None)
    blob = open(SHAPER, "rb").read() + (open(reg, "rb").read() if reg and os.path.exists(reg) else b"")
    return vocab, sha(blob)


def normalize(task):
    if "q" in task and "question" not in task:   # an old-75 diagnostic row: gold names only
        return {"id": task["id"], "question": task["q"], "kind": task.get("kind", "legacy"), "half": task.get("half"),
                "stratum": task.get("stratum"), "facts": [], "files": [{"repo": "himmel", "path": p} for p in task.get("gold", [])],
                "legacy": True}
    return task


def fact_hit(task, top, collections):
    if task.get("legacy") or task.get("answerability") == "not_there" or not task.get("facts"):
        return None
    needles = [s.lower() for f in task["facts"] for s in [f["text"]] + list(f.get("variants") or [])]
    for repo, path in top:
        try:
            text = open(os.path.join(collections[repo], path), errors="replace").read().lower()
        except OSError:
            continue
        if any(n in text for n in needles):
            return True
    return False


def gold_hit(task, top):
    gold = {(f["repo"], f["path"]) for f in task.get("files") or []}
    return None if not gold else any(t in gold for t in top)


class FixtureBooking:
    """The fixture ledger adapter (B4 supplies the real one at runtime): it allows `allow`
    S bookings and refuses after; Q operations are recorded as local, never booked."""

    def __init__(self, allow=10 ** 9):
        self.allow, self.events = allow, []

    def reserve(self, task_id):
        if sum(1 for e in self.events if e[0] == "reserve") >= self.allow:
            self.events.append(("refused", task_id))
            return None
        self.events.append(("reserve", task_id))
        return "fx-%s" % task_id

    def local(self, task_id):
        self.events.append(("local", task_id))
        return "local-%s" % task_id

    def settle(self, booking, status):
        self.events.append(("settle", booking, status))


def one_query(ctx, mode, task_id, query, workdir):
    pins = load(os.path.join(HERE, "pins.py"), "pins")
    copy = os.path.join(workdir, "copy.sqlite")
    t0 = time.monotonic()
    pins.disposable(ctx["master"], copy, ctx["seal"])
    setup_ms = int((time.monotonic() - t0) * 1000)
    sock, meta = os.path.join(workdir, "b.sock"), os.path.join(workdir, "meta")
    tools = ctx["tools"]
    cmd = [sys.executable, "-I", os.path.join(tools, "s-qmd"), "serve", "--socket", sock, "--meta", meta,
           "--phase", "fixed", "--arm", mode, "--cap", "1"]
    if mode == "Q" and ctx.get("nvml_cmd"):
        cmd += ["--nvml-cmd", ctx["nvml_cmd"]]
    broker = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(200):
            if os.path.exists(sock):
                break
            time.sleep(0.02)
        b = dict(ctx["binding"], index=copy, socket=sock, arm=mode)
        bpath = os.path.join(workdir, "binding.json")
        with open(bpath, "w") as f:
            json.dump(b, f)
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "PILOT_BINDING": bpath}
        subprocess.run([sys.executable, "-I", os.path.join(tools, "s-qmd"), "-n", str(K), query], env=env,
                       capture_output=True, timeout=b.get("deadline_kill_ms", 540000) / 1000.0 + 60)
    finally:
        broker.terminate()
        broker.wait(timeout=10)
    evs = [json.loads(l) for l in open(os.path.join(meta, "events.jsonl")) if l.strip()]
    term = next((e for e in evs if e.get("kind") == "terminal"), None)
    integrity = [e.get("what") for e in evs if e.get("kind") == "integrity"]
    try:
        pins.verify(copy, ctx["seal"])
    except pins.Refuse:
        integrity.append("copy_digest_changed")
    return term, integrity, setup_ms


def run_lists(bank, mode, ctx, booking, out):
    vocab, shaper_sha = shaper_identity()
    squ = load(os.path.join(ctx["tools"], "s-qmd"), "s_qmd")
    rows, stop = [], False
    for raw in bank:
        task = normalize(raw)
        query = vocab.document("query", task["question"])
        row = {"task_id": task["id"], "mode": mode, "k": K, "question_sha256": sha(task["question"]),
               "query_sha256": sha(query), "shaper_sha256": shaper_sha, "collections": sorted(ctx["collections"]),
               "config_hash": ctx["binding"]["config_hash"], "models": ctx["binding"]["models"],
               "corpus_digest": ctx["corpus_digest"], "source_manifest_sha256": ctx["source_manifest_sha256"],
               "kind": task.get("kind"), "half": task.get("half"), "stratum": task.get("stratum"),
               "legacy": bool(task.get("legacy")), "top5": [], "fact_file_hit": None, "gold_file_hit": None,
               "status": "unaffordable", "skip_reasons": [], "ms": None, "setup_ms": None}
        booked = None
        if not stop:
            booked = booking.reserve(task["id"]) if mode == "S" else booking.local(task["id"])
            if booked is None:
                stop = True   # a refused S booking ends the list: nothing after it launches
        if booked is not None:
            work = tempfile.mkdtemp(prefix="matched-list.", dir=ctx.get("work"))
            try:
                term, integrity, setup_ms = one_query(ctx, mode, task["id"], query, work)
            finally:
                shutil.rmtree(work, ignore_errors=True)
            row["setup_ms"] = setup_ms
            if integrity:
                row["status"], row["integrity"] = "integrity", sorted(set(integrity))
            elif term is None:
                row["status"] = "error"
            else:
                kept, _ = squ.pin_filter(ctx["binding"], term.get("hits_raw") or [])
                top = []
                for full, _h in kept[:K]:
                    for repo, root in ctx["collections"].items():
                        if full.startswith(root.rstrip("/") + "/"):
                            top.append((repo, full[len(root.rstrip("/")) + 1:]))
                row["top5"] = ["%s/%s" % t for t in top]
                row["fact_file_hit"] = fact_hit(task, top, ctx["collections"])
                row["gold_file_hit"] = gold_hit(task, top)
                row["skip_reasons"] = term.get("skip_reasons") or []
                row["status"] = "skip" if term.get("skip") else ("ok" if term.get("hits_raw") is not None else "error")
                row["ms"] = term.get("ms")
            booking.settle(booked, row["status"])
        rows.append(row)
    with open(out, "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    os.chmod(out, 0o600)
    return rows


def summarize(rows):
    ans = [r for r in rows if r["fact_file_hit"] is not None]
    by = {}
    for r in ans:
        s = by.setdefault(r.get("stratum") or "unknown", [0, 0])
        s[0] += bool(r["fact_file_hit"])
        s[1] += 1
    return {"n": len(rows), "complete": all(r["status"] == "ok" for r in rows),
            "statuses": {k: sum(1 for r in rows if r["status"] == k) for k in sorted({r["status"] for r in rows})},
            "fact_file_at5": [sum(bool(r["fact_file_hit"]) for r in ans), len(ans)],
            "fact_file_at5_by_stratum": {k: v for k, v in sorted(by.items())},
            "not_applicable": sum(1 for r in rows if r["fact_file_hit"] is None),
            "gold_file_at5": [sum(1 for r in rows if r["gold_file_hit"]), sum(1 for r in rows if r["gold_file_hit"] is not None)]}


def compare(a):
    s = [json.loads(l) for l in open(a.s) if l.strip()]
    q = [json.loads(l) for l in open(a.q) if l.strip()]
    bad = []
    si, qi = {r["task_id"]: r for r in s}, {r["task_id"]: r for r in q}
    if set(si) != set(qi) or len(si) != len(s) or len(qi) != len(q):
        bad.append("S and Q lists cover different task ids")
    if a.expect and (len(si) != a.expect):
        bad.append("%d task ids, expected %d" % (len(si), a.expect))
    for tid in sorted(set(si) & set(qi)):
        for k in ("question_sha256", "query_sha256", "shaper_sha256", "k", "collections", "source_manifest_sha256"):
            if si[tid].get(k) != qi[tid].get(k):
                bad.append("%s: S and Q differ on %s" % (tid, k))
                break
    for tag, rows in (("S", s), ("Q", q)):
        if any(r["mode"] != tag for r in rows):
            bad.append("the %s list holds a row of another mode" % tag)
    if bad:
        for b in sorted(set(bad)):
            print("matched-lists: refused: %s" % b, file=sys.stderr)
        return 3
    out = {"S": summarize(s), "Q": summarize(q),
           "corpus_digests": {"S": sorted({r["corpus_digest"] for r in s}), "Q": sorted({r["corpus_digest"] for r in q})},
           "source_manifest_sha256": s[0]["source_manifest_sha256"] if s else None}
    out["complete"] = out["S"]["complete"] and out["Q"]["complete"]
    print(json.dumps(out, sort_keys=True))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog="matched-lists.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--bank", required=True); r.add_argument("--mode", required=True, choices=["S", "Q"])
    r.add_argument("--ctx", required=True); r.add_argument("--out", required=True); r.add_argument("--ledger")
    c = sub.add_parser("compare")
    c.add_argument("--s", required=True); c.add_argument("--q", required=True); c.add_argument("--expect", type=int, default=0)
    a = p.parse_args(argv)
    if a.cmd == "compare":
        return compare(a)
    if a.mode == "S":
        if os.environ.get("HIMMEL_BILLED_OK") != "1":
            print("matched-lists: refused: S mode spends OpenRouter cash; it runs only with HIMMEL_BILLED_OK=1 under a paid go", file=sys.stderr)
            return 2
        if not a.ledger:
            print("matched-lists: refused: S mode books every query in the pilot ledger (--ledger)", file=sys.stderr)
            return 2
        ledger = load(os.path.join(HERE, "ledger.py"), "ledger")
        booking = ledger.ListBooking(ledger.Ledger(a.ledger))
    else:
        booking = FixtureBooking()
    bank = [json.loads(l) for l in open(a.bank) if l.strip()]
    ctx = json.load(open(a.ctx))
    rows = run_lists(bank, a.mode, ctx, booking, a.out)
    print(json.dumps(summarize(rows), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
