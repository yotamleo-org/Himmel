#!/usr/bin/env python3
"""B5 D3 judge-round fixtures: judge.py's scheduler on the real ledger with mock judge calls,
quota, readiness and clock. No judge call is made. Usage: d3.py <scenario> <workdir>."""
import importlib.util, json, os, sys

PILOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def load(name):
    s = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(PILOT, name + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


J, L = load("judge"), load("ledger")
TASKS = ["t%02d" % i for i in range(1, 41)]


class Verdict(dict):
    def get(self, k, d=None):
        if k in ("supported", "score"):
            raise AssertionError("the scheduler read verdict content")
        return dict.get(self, k, d)


class Call:
    def __init__(self, fail_at=None, how=None):
        self.calls, self.fail_at, self.how = [], fail_at, how

    def __call__(self, cand, arm, attempt):
        self.calls.append((arm, cand))
        if self.fail_at == len(self.calls):
            if self.how == "usage":
                raise J.UsageRefusedInCall(0.01)
            if self.how == "invalid":
                return Verdict(valid=False, verdict=None, id="v%d" % len(self.calls), cost=0.02)
        return Verdict(valid=True, verdict="SUPPORTED", id="v%d" % len(self.calls), cost=0.02)


class Quota:
    def __init__(self, refuse_after=None, clears=None, crash_after=None):
        self.refuse_after, self.clears, self.crash_after, self.call, self.refusals = refuse_after, clears, crash_after, None, 0

    def ok(self):
        n = len(self.call.calls)
        if self.crash_after is not None and n == self.crash_after:
            raise RuntimeError("runner died between calls")
        if self.refuse_after is not None and n == self.refuse_after:
            if self.clears is not None and self.refusals >= self.clears:
                return True
            self.refusals += 1
            return False
        return True


class Ready:
    def __init__(self, refuse_after=None):
        self.refuse_after, self.call = refuse_after, None

    def recheck(self):
        return "auth" if self.refuse_after is not None and len(self.call.calls) >= self.refuse_after else None


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def now(self):
        return self.t

    def sleep(self, s):
        self.t += s


def setup(work, per_arm=5, call=None, quota=None, ready=None, clock=None, prior_deadline=None):
    os.makedirs(work, exist_ok=True)
    led = L.Ledger(os.path.join(work, "ledger.jsonl"))
    if "judge" not in led.reserves:
        led.reserve_h()
    if prior_deadline is not None and led.usage_pause_deadline is None:
        led.usage_refused(prior_deadline)
    disputes = {a: {"%s#0" % t for t in TASKS} for a in J.ARMS}
    if per_arm < 5:
        disputes["Q"] = {"%s#0" % t for t in TASKS[:per_arm]}
    cands = J.candidates(7, disputes, TASKS if per_arm == 5 else TASKS, TASKS)
    if per_arm < 5:
        cands["Q"] = cands["Q"][:per_arm]
    call, quota, ready, clock = call or Call(), quota or Quota(), ready or Ready(), clock or Clock()
    quota.call = ready.call = call
    j = J.Judging(led, call, quota, ready, clock)
    j.seal(J.seal_schedule(7, cands))
    return j, led, call, clock


def summary(j, led, call):
    r = j.result()
    return {"rounds": r["completed_rounds"], "discarded": r["discarded_verdicts"], "unjudged": r["unjudged"],
            "applied": {a: len(v) for a, v in r["applied"].items()}, "calls": len(call.calls), "ended": r["ended"],
            "spent": round(led.spent, 4), "judge_bookings": r["calls"],
            "distinct": len(set(call.calls)) == len(call.calls)}


def run(name, work):
    if name == "full":
        j, led, call, _ = setup(work); j.run(); return summary(j, led, call)
    if name == "quota-expire-after-7":
        j, led, call, clock = setup(work, quota=Quota(refuse_after=7)); j.run()
        out = summary(j, led, call); out["deadline_days"] = round((led.usage_pause_deadline - 1_000_000.0) / 86400, 3); return out
    if name == "quota-clears-after-7":
        j, led, call, _ = setup(work, quota=Quota(refuse_after=7, clears=2)); j.run(); return summary(j, led, call)
    if name == "in-call-usage":
        j, led, call, _ = setup(work, call=Call(fail_at=5, how="usage")); j.run(); return summary(j, led, call)
    if name == "invalid":
        j, led, call, _ = setup(work, call=Call(fail_at=5, how="invalid")); j.run(); return summary(j, led, call)
    if name == "auth-mid-round":
        j, led, call, _ = setup(work, ready=Ready(refuse_after=8)); j.run(); return summary(j, led, call)
    if name == "absent-candidate":
        j, led, call, _ = setup(work, per_arm=3); j.run()
        out = summary(j, led, call)
        out["not_needed"] = sum(1 for e in led.events if e["ev"] == "judge_not_needed"); return out
    if name == "restart-after-7":
        j, led, call, _ = setup(work, quota=Quota(crash_after=7))
        try:
            j.run()
        except RuntimeError:
            pass
        first = list(call.calls)
        j2, led2, call2, _ = setup(work)        # a fresh process on the same ledger
        j2.run()
        out = summary(j2, led2, call2)
        out["first_calls"] = len(first)
        out["replayed"] = len(set(first) & set(call2.calls))
        return out
    if name == "deadline-persists":
        clock = Clock(t=1_000_000.0 + 3 * 86400)   # judging starts three days after an admission pause
        j, led, call, _ = setup(work, quota=Quota(refuse_after=7), clock=clock, prior_deadline=1_000_000.0)
        j.run()
        out = summary(j, led, call)
        out["deadline_days_from_first_refusal"] = round((led.usage_pause_deadline - 1_000_000.0) / 86400, 3)
        out["deadlines"] = sum(1 for e in led.events if e["ev"] == "pause_deadline")
        return out
    if name == "lost-round-marker":
        j, led, call, _ = setup(work); j.run()
        path = os.path.join(work, "ledger.jsonl")
        lines = open(path).read().splitlines()
        last = max(i for i, l in enumerate(lines) if '"judge_round"' in l)
        ends = [i for i, l in enumerate(lines) if '"judge_end"' in l]
        open(path, "w").write("\n".join(l for i, l in enumerate(lines) if i != last and i not in ends) + "\n")
        j2, led2, call2, _ = setup(work)
        before = J.Judging(led2, call2, None, None, None).result()["completed_rounds"]
        j2.run()
        out = summary(j2, led2, call2)
        out["before_resume"] = before
        return out
    if name == "settled-no-verdict":
        j, led, call, _ = setup(work); j.run()
        path = os.path.join(work, "ledger.jsonl")
        lines = open(path).read().splitlines()
        fourth = [i for i, l in enumerate(lines) if '"judge_verdict"' in l][3]
        open(path, "w").write("\n".join(lines[:fourth]) + "\n")
        j2, led2, call2, _ = setup(work)
        j2.run()
        out = summary(j2, led2, call2)
        out["failed"] = [e.get("why") for e in led2.events if e["ev"] == "judge_failed"]
        return out
    if name == "dispute-files":
        root = os.path.join(work, "export"); os.makedirs(os.path.join(root, "docs"), exist_ok=True)
        open(os.path.join(root, "docs", "a.md"), "w").write("an unrelated page")
        open(os.path.join(root, "docs", "b.md"), "w").write("one holder per handover document")
        read = lambda p: J.contained_read(p, {"/work/himmel/": root})   # noqa: E731
        task = {"question": "q?", "facts": [{"text": "one session per handover doc"}]}
        it = J.dispute_item(task, 0, "one session per handover doc", ["/work/himmel/docs/a.md", "/work/himmel/docs/b.md"], read)
        return {"second_file_shown": "one holder per handover document" in it["file"], "first_file_shown": "an unrelated page" in it["file"],
                "path": it["path"]}
    if name == "cost-missing":
        class NoCost(Call):
            def __call__(self, cand, arm, attempt):
                v = super().__call__(cand, arm, attempt)
                if len(self.calls) == 4:
                    dict.__setitem__(v, "cost", None)
                return v
        j, led, call, _ = setup(work, call=NoCost()); j.run()
        out = summary(j, led, call)
        out["unsettled"] = sorted(led.unsettled)
        out["stop"] = led.stop
        return out
    if name == "contained-read":
        root = os.path.join(work, "export"); os.makedirs(os.path.join(root, "docs"), exist_ok=True)
        open(os.path.join(root, "docs", "a.md"), "w").write("inside")
        open(os.path.join(work, "secret.txt"), "w").write("host secret")
        os.symlink(os.path.join(work, "secret.txt"), os.path.join(root, "docs", "link.md"))
        roots = {"/work/himmel/": root}
        return {"inside": J.contained_read("/work/himmel/docs/a.md", roots),
                "traversal": J.contained_read("/work/himmel/../secret.txt", roots),
                "deep_traversal": J.contained_read("/work/himmel/docs/../../secret.txt", roots),
                "symlink_out": J.contained_read("/work/himmel/docs/link.md", roots),
                "other_root": J.contained_read("/etc/hostname", roots)}
    if name == "validate":
        res = {}
        slots = J.seal_schedule(7, {a: ["%s#0" % t for t in TASKS[:5]] for a in J.ARMS})
        seq = sorted(slots, key=lambda s: J.ARMS.index(s["arm"]))
        for label, bad in (("arm_sequential", seq), ("sixth_in_an_arm", slots[:-1] + [dict(slots[0])]),
                           ("sixteenth_total", slots + [dict(slots[0], round=5)])):
            try:
                J.validate_schedule(bad); res[label] = "accepted"
            except ValueError:
                res[label] = "refused"
        return res
    raise SystemExit("unknown scenario " + name)


if __name__ == "__main__":
    print(json.dumps(run(sys.argv[1], sys.argv[2]), sort_keys=True))
