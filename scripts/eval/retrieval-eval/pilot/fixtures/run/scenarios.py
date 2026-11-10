#!/usr/bin/env python3
"""B4 fixture scenarios: run-pilot.py's state machine against MOCK Claude, usage, quota,
readiness, probes and clock. Nothing launches a session or reaches a network.
Usage: scenarios.py <scenario> <workdir>  -> prints one JSON result line.
"""
import importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
PILOT = os.path.normpath(os.path.join(HERE, "..", ".."))


def load(name):
    s = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(PILOT, name + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


RP = load("run-pilot")
L = RP.L
TASKS = [{"id": "t%02d" % i, "question": "fixture question %d" % i} for i in range(1, 41)]
SCORE_KEYS = ("supported", "score", "correct", "answer")


class ScoreBomb(dict):
    """A row whose score fields explode when read: a gate that peeks at correctness fails loudly."""

    def __getitem__(self, k):
        if k in SCORE_KEYS:
            raise AssertionError("a gate read the score field %s" % k)
        return dict.__getitem__(self, k)

    def get(self, k, d=None):
        if k in SCORE_KEYS:
            raise AssertionError("a gate read the score field %s" % k)
        return dict.get(self, k, d)


def row(arm, cost=0.06, **kw):
    r = ScoreBomb(service=[], skips=0, skip_reasons=[], hard_abort=False, survivors=0, cost_usd=cost,
                  qmd_calls=2 if arm in "SQ" else 0, graph_calls=0, profile_clean=True, supported=True)
    for k, v in kw.items():
        dict.__setitem__(r, k, v)
    return r


def triple_no(n):
    return (n - 1) // 3 + 1


class Launcher:
    def __init__(self, rule=None, recovered=(0.05, True)):
        self.rule, self.calls, self.recovered = rule, [], recovered

    def recover(self, attempt):
        return self.recovered

    def launch(self, task, arm, attempt, phase):
        self.calls.append(attempt)
        n = sum(1 for c in self.calls if c.startswith("answer-"))
        if self.rule:
            r = self.rule(task, arm, phase, n)
            if r is not None:
                return r
        if phase == "p1":
            return row(arm, 0.03, qmd_calls=1 if arm in "SQ" else 0, marker_detected=arm == "control")
        if phase == "p2":
            return row(arm, 0.03, qmd_calls=0, p2={"result": "pass"})
        return row(arm)


class Usage:
    def __init__(self, per_query=0.002):
        self.per_query, self.ledger = per_query, None

    def baseline(self):
        return 0.0

    def cumulative(self):
        return self.per_query * sum(1 for e in self.ledger.events if e["ev"] == "book" and e["kind"] == "s_query")


class Quota:
    def __init__(self, refuse_from=None, clears_after=None):
        self.refuse_from, self.clears_after, self.refusals, self.first_t, self.pilot = refuse_from, clears_after, 0, None, None

    def ok(self):
        if self.refuse_from is None or len(self.pilot.status) < self.refuse_from:
            return True
        if self.clears_after is not None and self.refusals >= self.clears_after:
            return True
        self.refusals += 1
        if self.first_t is None:
            self.first_t = self.pilot.clock.now()
        return False


class Readiness:
    def __init__(self, g0=True, refuse_at=None, why="auth"):
        self.g0_ok, self.refuse_at, self.why, self.pilot = g0, refuse_at, why, None

    def g0(self):
        return self.g0_ok

    def recheck(self):
        return self.why if self.refuse_at is not None and len(self.pilot.status) >= self.refuse_at else None


class Prober:
    def __init__(self, fail=None):
        self.fail, self.calls = fail or {}, []

    def probe(self, arm, checkpoint):
        self.calls.append((arm, checkpoint))
        return dict(self.fail.get((arm, checkpoint), {"skips": 0, "integrity": False, "expanded": True}))


class Clock:
    def __init__(self):
        self.t, self.sleeps = 1_000_000.0, []

    def now(self):
        return self.t

    def sleep(self, s):
        self.sleeps.append(s)
        self.t += s


def build(work, cap=25.0, rule=None, usage=None, quota=None, readiness=None, prober=None, finalize=True, name="ledger", recovered=(0.05, True)):
    os.makedirs(work, exist_ok=True)
    led = L.Ledger(os.path.join(work, name + ".jsonl"), cap=cap)
    calls = []
    fin = (lambda p, c: calls.append(len(c)) or {"judged": len(c)}) if finalize else None
    usage = usage or Usage()
    usage.ledger = led
    quota, readiness = quota or Quota(), readiness or Readiness()
    p = RP.Pilot(TASKS, led, Launcher(rule, recovered), usage, quota, readiness, prober or Prober(), Clock(), seed=7, finalize=fin)
    quota.pilot = readiness.pilot = p
    return p, calls


def committed_at(work, triples, usage=None):
    """The committed amount right after `triples` triples (after G6 when triples == 4) on an
    unbounded run: sizes a cap so that exactly the next admission no longer fits."""
    p, _ = build(work, cap=1e9, usage=usage, name="size")
    seen = {}
    orig = p.triple

    def spy(task, perm):
        r = orig(task, perm)
        if len(p.status) == triples and "c" not in seen:
            seen["c"] = p.ledger.committed()
        return r
    p.triple = spy
    if triples == 4:
        og6 = p.g6

        def g6(first4):
            r = og6(first4)
            seen["c"] = p.ledger.committed()
            return r
        p.g6 = g6
    p.run()
    return seen["c"]


def summary(p, fin, rep):
    return {"stop": [rep["stop_kind"], rep["reason"]], "finalization": rep["finalization_status"], "common": rep["common_scored"],
            "attempted": rep["attempted"], "finalize_calls": fin, "answers": sum(1 for c in p.launcher.calls if c.startswith("answer-")),
            "first_stop": next((e["reason"] for e in p.ledger.events if e["ev"] == "stop"), None), "excluded": rep["excluded"],
            "skip_union": rep["skip_union"], "b": round(rep["b"], 6), "lists_cancelled": rep["lists_cancelled"],
            "judge_reserve": round(p.ledger.reserves.get("judge", 0.0), 4), "unsettled": len(p.ledger.unsettled)}


def run(name, work):
    kw, cap = {}, 25.0
    if name == "clean":
        p, fin = build(work)
        rep = p.run()
        ev = p.ledger.events
        out = summary(p, fin, rep)
        out.update(launches=rep["launches"], p1s_booking=[e["amount"] for e in ev if e["ev"] == "book" and e["attempt"] == "p1-S-q01"],
                   checks_booked=sum(1 for e in ev if e["ev"] == "book" and e["kind"] == "check"),
                   h=sorted([e["name"], round(e["amount"], 4)] for e in ev if e["ev"] == "reserve" and e["name"] in ("judge", "probes", "lists")),
                   probes=len(p.prober.calls))
        return out
    if name == "g0":
        p, _ = build(work, readiness=Readiness(g0=False))
        rep = p.run()
        return {"refused": rep.get("refused"), "launches": rep["launches"], "events": len(p.ledger.events)}
    if name.startswith("g5-"):
        kind = name[3:]
        rule = prober = None
        if kind == "p1-skip":
            rule = lambda t, a, ph, n: row(a, .03, skips=1, qmd_calls=1) if ph == "p1" and a == "S" else None
        elif kind == "p2-missing":
            rule = lambda t, a, ph, n: row(a, .03, qmd_calls=0) if ph == "p2" and a == "Q" else None
        elif kind == "control":
            rule = lambda t, a, ph, n: row(a, .03, qmd_calls=0) if ph == "p1" and a == "control" else None
        elif kind == "q-unavailable":
            prober = Prober({("Q", "initial"): {"skips": 1, "integrity": False}})
        elif kind == "fallback-shape":
            prober = Prober({("S", "initial"): {"skips": 0, "integrity": False, "expanded": False}})
        p, fin = build(work, rule=rule, prober=prober)
        return summary(p, fin, p.run())
    if name == "first-four":
        kw["rule"] = lambda t, a, ph, n: row(a, service=["no_cli_json"]) if ph == "answer" and n == 5 else None
    elif name == "g6-route-use":
        kw["rule"] = lambda t, a, ph, n: row(a, qmd_calls=0) if ph == "answer" and a == "Q" and triple_no(n) <= 2 else None
    elif name == "g6-projection":
        kw["rule"] = lambda t, a, ph, n: row(a, 0.25) if ph == "answer" else None
        cap = 12.0
    elif name in ("capacity-at-38", "capacity-at-35"):
        k = 37 if name == "capacity-at-38" else 34
        cap = committed_at(os.path.join(work, "size"), k) + L.btriple(L.B_MIN) - 0.05
    elif name == "overrun-after-37":
        kw["rule"] = lambda t, a, ph, n: row(a, 0.40) if ph == "answer" and n == 112 else None
    elif name == "probe-benign-20":
        kw["prober"] = Prober({("S", "20"): {"skips": 1, "integrity": False}})
    elif name == "probe-security":
        kw["prober"] = Prober({("Q", "10"): {"skips": 0, "integrity": True}})
    elif name == "quota-expiry-37":
        kw["quota"] = Quota(refuse_from=37)
    elif name == "quota-clears":
        kw["quota"] = Quota(refuse_from=20, clears_after=3)
    elif name == "auth-after-g6":
        kw["readiness"] = Readiness(refuse_at=37)
    elif name == "unclassified":
        def boom(t, a, ph, n):
            if ph == "answer" and n == 30:
                raise RuntimeError("unexpected")
        kw["rule"] = boom
    elif name == "reachable-35":
        kw["rule"] = lambda t, a, ph, n: row(a, service=["provider_or_auth_error"]) if ph == "answer" and a == "V" and 5 <= triple_no(n) <= 10 else None
    elif name in ("skips-two", "skips-three", "skips-same-task"):
        bad = {"skips-two": {("S", 7), ("Q", 14)}, "skips-three": {("S", 7), ("Q", 14), ("S", 20)},
               "skips-same-task": {("S", 7), ("Q", 7)}}[name]
        kw["rule"] = lambda t, a, ph, n: row(a, skips=1, skip_reasons=["timeout"]) if ph == "answer" and (a, triple_no(n)) in bad else None
    elif name.startswith("kill-"):
        pos, complete = int(name.split("-")[1]), name.endswith("-usage")

        def kill(t, a, ph, n):
            if ph == "answer" and n == 18 + pos:
                raise RP.Killed(0.05 if complete else None, complete)
        kw["rule"] = kill
    elif name == "no-cost-evidence":
        kw["rule"] = lambda t, a, ph, n: row(a, cost_usd=None) if ph == "answer" and n == 20 else None
    elif name == "background":
        kw["rule"] = lambda t, a, ph, n: row(a, survivors=1) if ph == "answer" and n == 20 else None
    elif name == "raw-only":
        kw["rule"] = lambda t, a, ph, n: row(a, raw_query_only=1) if ph == "answer" and a == "S" else None
    elif name == "reprice-no-capacity":
        kw["usage"] = Usage(per_query=0.004)
        cap = committed_at(os.path.join(work, "size"), 4, usage=Usage(per_query=0.004)) + L.btriple(0.006) - 0.01
    elif name in ("crash-resume", "crash-resume-nousage"):
        state = {"armed": True}

        def crash(t, a, ph, n):
            if ph == "answer" and n == 20 and state["armed"]:
                state["armed"] = False
                raise RP.Crash()
        p, fin = build(work, rule=crash)
        try:
            p.run()
        except RP.Crash:
            pass
        crashed_task = [c for c in p.launcher.calls if c.startswith("answer-")][-1].split("-")[1]
        p2, fin2 = build(work, rule=crash, recovered=(0.05, True) if name == "crash-resume" else (None, False))
        rep = p2.run()
        out = summary(p2, fin2, rep)
        out["replayed"] = sum(1 for c in p2.launcher.calls if c.split("-")[1:2] == [crashed_task] and c.startswith("answer-"))
        out["crashed_task_status"] = p2.status.get(crashed_task)
        out["unsettled_after_resume"] = sorted(p2.ledger.unsettled)
        out["preflight_rerun"] = sum(1 for c in p2.launcher.calls if not c.startswith("answer-"))
        return out
    elif name == "pause-deadline-persists":
        q = Quota(refuse_from=20, clears_after=2)
        p, fin = build(work, quota=q)
        orig = p.triple

        def stop_at_25(task, perm):
            if len(p.status) == 25:
                raise RP.Crash()
            return orig(task, perm)
        p.triple = stop_at_25
        try:
            p.run()
        except RP.Crash:
            pass
        d1 = p.ledger.usage_pause_deadline
        q2 = Quota(refuse_from=30, clears_after=2)
        p2, _ = build(work, quota=q2)
        rep = p2.run()
        return {"deadline_same": p2.ledger.usage_pause_deadline == d1, "deadline_events": sum(1 for e in p2.ledger.events if e["ev"] == "pause_deadline"),
                "stop": [rep["stop_kind"], rep["reason"]], "sleeps": sorted(set(p.clock.sleeps) | set(p2.clock.sleeps))}
    p, fin = build(work, cap=cap, **kw)
    rep = p.run()
    out = summary(p, fin, rep)
    if name == "quota-expiry-37":
        out["sleeps"] = sorted(set(p.clock.sleeps))
        out["deadline_days"] = round((p.ledger.usage_pause_deadline - kw["quota"].first_t) / 86400, 3)
    if name.startswith("kill-"):
        out["killed_settled"] = round(sum(e["actual"] for e in p.ledger.events if e["ev"] == "settle" and e["attempt"].startswith("answer-") and "-" in e["attempt"]), 6) > 0
    return out


if __name__ == "__main__":
    print(json.dumps(run(sys.argv[1], sys.argv[2]), sort_keys=True))
