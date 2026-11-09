#!/usr/bin/env python3
# billed-opt-in: HIMMEL_BILLED_OK
"""rerun-hybrid.py -- R5: the separately capped old-75 S hybrid rerun (design §6, plan B7).

  rerun-hybrid.py run --questions OLD75.jsonl --ctx CTX.json --state STATE.jsonl --gates GATES.json --out ROWS.jsonl
                      [--usage-cmd CMD] [--settle-seconds 60]
  rerun-hybrid.py final --state STATE.jsonl        the settled final b for the R6 card; refuses without it
  rerun-hybrid.py losses --results SAVED.jsonl     the free saved-list fusion-loss account (no query)

One shaped hybrid query per old task (scripts/qmd/vocab-expand.py, imported unchanged), at most
75, each on a FRESH disposable copy of the sealed S master, through the same S wrapper path
(locked config preflight, target checks, allowlisted environment, key injected only into the
qmd child, the shared skip classifier, the pin filter), returning the top 20 with the first 5
scored. Every query is booked durably BEFORE it runs at b; the dedicated key's usage is read
through the unchanged fetchOpenRouterKey after a 60-second settle before the first query, after
query 5 and at the end; b = max(.004, 1.5 x measured cash per query). A query is admitted only
while settled cash + unsettled bookings + b <= $0.50 and it is query 75 or earlier; a larger b
may admit fewer than 75 and the report says how many ran. No retry, no answer session. A failed
or skipped query keeps its row with its raw evidence. A usage-reading failure stops the rerun.
Requires HIMMEL_BILLED_OK=1, G0 READY, G1 (the free fixes merged), a G3 PASS and the distinct R5
go: any missing gate runs zero queries. Exit 0 ok, 2 refused opt-in/usage, 3 refusal or stop.
"""
import argparse, hashlib, importlib.machinery, importlib.util, json, os, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))
CAP, B_MIN, MAX_Q, REPRICE_AT, N = 0.50, 0.004, 75, 5, 20


def load(path, name):
    loader = importlib.machinery.SourceFileLoader(name, path)
    spec = importlib.util.spec_from_loader(name, loader)
    m = importlib.util.module_from_spec(spec)
    loader.exec_module(m)
    return m


class State:
    """The rerun's own fsynced event log: bookings, settles (meter readings), the final b."""

    def __init__(self, path):
        self.path, self.events = path, []
        if os.path.exists(path):
            self.events = [json.loads(l) for l in open(path) if l.strip()]

    def log(self, ev):
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(ev, sort_keys=True) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        self.events.append(ev)

    def b(self):
        return max([B_MIN] + [e["b"] for e in self.events if e["ev"] == "reprice"])

    def cash(self):
        s = [e for e in self.events if e["ev"] == "settle"]
        return (s[-1]["meter"] - s[0]["meter"]) if s else 0.0

    def unsettled(self):
        last = max([i for i, e in enumerate(self.events) if e["ev"] == "settle"] or [-1])
        return sum(e["amount"] for e in self.events[last + 1:] if e["ev"] == "book")

    def queries(self):
        return sum(1 for e in self.events if e["ev"] == "book")


def gates_ok(gates_path):
    bad = []
    try:
        g = json.load(open(gates_path))
    except (OSError, ValueError):
        return ["no gates record"]
    if g.get("g0") != "READY":
        bad.append("G0 auth readiness is not READY")
    if g.get("g1") is not True or not g.get("g1_evidence"):
        bad.append("G1: the free fixes are not recorded merged")
    try:
        if json.load(open(g.get("g3_report", ""))).get("g3") != "PASS":
            bad.append("G3 is not PASS")
    except (OSError, ValueError):
        bad.append("no G3 report")
    if not g.get("r5_go") or not os.path.isfile(g["r5_go"]):
        bad.append("no distinct R5 go")
    return bad


def read_usage(cmd, key_file):
    if cmd:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        if p.returncode != 0:
            return None
        try:
            return float(json.loads(p.stdout)["usage"])
        except (ValueError, KeyError, TypeError):
            return None
    mjs = os.path.join(REPO, "scripts", "api-lane", "shift-spend.mjs")
    js = ("import {fetchOpenRouterKey} from %s; const k = (await import('node:fs')).readFileSync(process.argv[1], 'utf8').trim();"
          "const b = await fetchOpenRouterKey(k); console.log(JSON.stringify((b && b.data) || {}));" % json.dumps("file://" + mjs))
    p = subprocess.run(["node", "--input-type=module", "-e", js, key_file], capture_output=True, text=True, timeout=60)
    try:
        u = json.loads(p.stdout).get("usage")
    except ValueError:
        return None
    return float(u) if isinstance(u, (int, float)) else None


def settle(st, a, ctx, at):
    time.sleep(a.settle_seconds)
    meter = read_usage(a.usage_cmd, ctx["binding"].get("key_file"))
    if meter is None:
        st.log({"ev": "stop", "reason": "usage_unreadable", "at": at})
        return False
    prev = [e for e in st.events if e["ev"] == "settle"]
    if prev and meter < prev[-1]["meter"]:
        st.log({"ev": "stop", "reason": "usage_reset", "at": at})
        return False
    st.log({"ev": "settle", "meter": meter, "at": at})
    if prev:
        n = sum(1 for e in st.events[st.events.index(prev[-1]) + 1:] if e["ev"] == "book")
        if n:
            nb = round(max(st.b(), B_MIN, 1.5 * (meter - prev[-1]["meter"]) / n), 6)
            if nb > st.b():
                st.log({"ev": "reprice", "b": nb, "measured": (meter - prev[-1]["meter"]) / n})
        elif meter - prev[-1]["meter"] > 1e-9:
            st.log({"ev": "stop", "reason": "unexplained_usage", "at": at})
            return False
    return True


def one(ctx, sq, task, query, work):
    """One S query on a fresh disposable copy through the wrapper's own path, top 20."""
    pins = load(os.path.join(HERE, "pins.py"), "pins")
    copy = os.path.join(work, "copy.sqlite")
    pins.disposable(ctx["master"], copy, ctx["seal"])
    b = dict(ctx["binding"], index=copy)
    home = os.path.join(work, "home")
    cache = os.path.join(home, "cache")
    os.makedirs(os.path.join(cache, "qmd"))
    env = sq.child_env(b, home, cache)
    bp = os.path.join(work, "binding.json")
    with open(bp, "w") as f:
        json.dump(b, f)
    os.environ["PILOT_BINDING"] = bp
    reason = sq.check_arm(b, env)
    if not reason:
        ok, why = sq.preflight(b, env)
        reason = None if ok else "config:" + why
    reason = reason or sq.check_target(b)
    if reason:
        return {"status": "refused", "reason": reason}
    env["QMD_OPENAI_API_KEY"] = open(b["key_file"]).read().strip()
    ev = sq.run_qmd(b, env, query, N)
    try:
        hits = json.loads(ev["stdout"]) if ev["rc"] == 0 and not ev["timed_out"] else None
        hits = hits if isinstance(hits, list) else None
    except ValueError:
        hits = None
    ev["hits_raw"] = hits
    reasons = sq.classify(ev, "S")
    kept, dropped = sq.pin_filter(b, hits or [])
    rel = []
    for full, _h in kept:
        for repo, root in b["collections"].items():
            if full.startswith(root.rstrip("/") + "/"):
                rel.append(full[len(root.rstrip("/")) + 1:])
    try:
        pins.verify(copy, ctx["seal"])
        drift = False
    except pins.Refuse:
        drift = True
    key = env["QMD_OPENAI_API_KEY"]
    return {"status": "error" if hits is None else ("skip" if reasons else "ok"), "skip_reasons": reasons, "rc": ev["rc"],
            "timed_out": ev["timed_out"], "ms": ev["ms"], "top5": rel[:5], "top20": rel[:N], "dropped": dropped,
            "deep_complete": hits is not None and not reasons, "corpus_drift": drift,
            "stderr": ev["stderr"].replace(key, "[key]")[-2000:] if hits is None or reasons else ""}


def run(a):
    bad = gates_ok(a.gates)
    if bad:
        for b in bad:
            print("rerun-hybrid: refused: " + b, file=sys.stderr)
        return 3
    ctx = json.load(open(a.ctx))
    vocab = load(os.path.join(REPO, "scripts", "qmd", "vocab-expand.py"), "vocab_expand")
    sq = load(os.path.join(HERE, "tools", "s-qmd"), "s_qmd")
    st = State(a.state)
    qs = [json.loads(l) for l in open(a.questions) if l.strip()]
    if not any(e["ev"] == "settle" for e in st.events) and not settle(st, a, ctx, "before"):
        print("rerun-hybrid: stopped: the key usage could not be read", file=sys.stderr)
        return 3
    rows, refused = [], 0
    done = {e["task"] for e in st.events if e["ev"] == "book"}
    for q in qs:
        if q["id"] in done:
            continue          # never replayed: its booking stands
        if st.queries() >= MAX_Q:
            refused += 1
            continue
        if st.cash() + st.unsettled() + st.b() > CAP + 1e-9:
            refused += 1
            continue
        query = vocab.document("query", q["q"])
        st.log({"ev": "book", "task": q["id"], "amount": st.b(), "query_sha256": hashlib.sha256(query.encode()).hexdigest()})
        work = tempfile.mkdtemp(prefix="rerun.", dir=ctx.get("work"))
        try:
            r = one(ctx, sq, q["id"], query, work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        gold = set(q.get("gold") or [])
        r.update(id=q["id"], hit5=bool(gold & set(r.get("top5") or [])) if gold else None,
                 hit20=bool(gold & set(r.get("top20") or [])) if gold else None)
        rows.append(r)
        if st.queries() == REPRICE_AT and not settle(st, a, ctx, "after-%d" % REPRICE_AT):
            break
    stopped = next((e for e in st.events if e["ev"] == "stop"), None)
    if not stopped and settle(st, a, ctx, "end"):
        st.log({"ev": "final", "b": st.b(), "queries": st.queries(), "cash": round(st.cash(), 6)})
    with open(a.out, "w") as f:
        for r in rows:
            f.write(json.dumps(r, sort_keys=True) + "\n")
    os.chmod(a.out, 0o600)
    stopped = next((e for e in st.events if e["ev"] == "stop"), None)
    print(json.dumps({"queries": st.queries(), "refused": refused, "b": st.b(), "cash": round(st.cash(), 6),
                      "failed_rows": sum(1 for r in rows if r["status"] != "ok"), "stopped": stopped and stopped["reason"],
                      "hit5": sum(1 for r in rows if r.get("hit5")), "hit20": sum(1 for r in rows if r.get("hit20"))}, sort_keys=True))
    return 3 if stopped else 0


def final(a):
    st = State(a.state)
    f = [e for e in st.events if e["ev"] == "final"]
    if not f:
        print("rerun-hybrid: refused: no settled final booking rate; the pilot card cannot be built", file=sys.stderr)
        return 3
    print(json.dumps(f[-1], sort_keys=True))
    return 0


def losses(a):
    """Free replay over a saved run: union-hit questions the fused list lost, by count."""
    by = {}
    for l in open(a.results):
        if l.strip():
            r = json.loads(l)
            by.setdefault(r["id"], {})[r["arm"]] = bool(r.get("hit"))
    union = [q for q, arms in by.items() if any(v for k, v in arms.items() if k != "combined")]
    fused = [q for q in union if by[q].get("combined")]
    lost = sorted(set(union) - set(fused))
    print(json.dumps({"questions": len(by), "union_hits": len(union), "fused_hits": len(fused), "fusion_losses": len(lost)}, sort_keys=True))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="rerun-hybrid.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    for k in ("questions", "ctx", "state", "gates", "out"):
        r.add_argument("--" + k, required=True)
    r.add_argument("--usage-cmd"); r.add_argument("--settle-seconds", type=float, default=60.0)
    f = sub.add_parser("final"); f.add_argument("--state", required=True)
    s = sub.add_parser("losses"); s.add_argument("--results", required=True)
    a = ap.parse_args(argv)
    if a.cmd == "final":
        return final(a)
    if a.cmd == "losses":
        return losses(a)
    if os.environ.get("HIMMEL_BILLED_OK") != "1":
        print("rerun-hybrid: refused: R5 spends OpenRouter cash; it runs only with HIMMEL_BILLED_OK=1 under the R5 go", file=sys.stderr)
        return 2
    return run(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
