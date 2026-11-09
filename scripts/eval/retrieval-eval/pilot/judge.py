#!/usr/bin/env python3
# billed-opt-in: HIMMEL_BILLED_OK
"""judge.py -- the RAG pilot's blinded judge rounds (design section 5, D3; plan B5).

At most fifteen judge calls, five reserved per arm, each a one-turn tool-less Sonnet 5.5 call
capped at .05 and booked at .06 inside the $25 ledger. After the common cohort is frozen:

  * each arm's candidates are the first five eligible disputes in its sealed priority order
    (a seeded order over task/fact keys, fixed before any answer); excluded triples never
    consume a slot and no slot moves between arms;
  * at most five rounds; round r holds candidate r of V, S and Q in a seed-derived arm order;
    a missing candidate is a not_needed slot (no call, no quota); never arm-sequential;
  * only the consecutive prefix of COMPLETE rounds changes scores; verdicts of a partial round
    stay staged, and are discarded (their candidates unjudged, their cost kept) if judging ends;
  * schedule, bindings, next slot, staged verdict ids and round markers live in the private
    ledger, so a restart resumes the exact next unstarted slot and never replays a paid call;
  * only a PRE-launch usage refusal pauses, under the run's one persisted deadline (checked no
    more often than every 30 minutes, never reset); deadline expiry, a non-integrity
    auth/readiness refusal, a failed/invalid paid verdict or a usage refusal returned by a
    launched call ends judging with the complete-round rule; a blocked ledger (HARD_STOP)
    ends it too. The scheduler reads slot completion and gates, never verdict content.
"""
import itertools, json, os, random, subprocess, sys

ARMS = ("V", "S", "Q")
PER_ARM, TOTAL, ROUNDS = 5, 15, 5
BOOK, CAP = 0.06, 0.05
HERE = os.path.dirname(os.path.abspath(__file__))


class UsageRefusedInCall(Exception):
    """A launched judge call that came back with a usage refusal: a failed slot."""

    def __init__(self, cost=0.0):
        super().__init__("usage refused in call")
        self.cost = cost


def priority(seed, arm, task_ids, facts_per_task=3):
    keys = ["%s#%d" % (t, f) for t in sorted(task_ids) for f in range(facts_per_task)]
    random.Random("%s:judge-priority:%s" % (seed, arm)).shuffle(keys)
    return keys


def candidates(seed, disputes, cohort, all_task_ids):
    """disputes: {arm: set of 'task#fact'}; the first five eligible per arm in its sealed order."""
    cohort = set(cohort)
    return {arm: [k for k in priority(seed, arm, all_task_ids) if k in disputes.get(arm, ()) and k.split("#")[0] in cohort][:PER_ARM]
            for arm in ARMS}


def seal_schedule(seed, cands):
    rng = random.Random("%s:judge-rounds" % seed)
    perms = ["".join(p) for p in itertools.permutations(ARMS)]
    slots = []
    for r in range(ROUNDS):
        for arm in rng.choice(perms):
            c = cands[arm][r] if r < len(cands[arm]) else None
            slots.append({"round": r, "arm": arm, "candidate": c})
    validate_schedule(slots)
    return slots


def validate_schedule(slots):
    """Refuse anything but interleaved rounds: three slots per round, one per arm, rounds in order,
    at most five per arm and fifteen in total."""
    if len(slots) > TOTAL:
        raise ValueError("more than %d judge slots" % TOTAL)
    per_arm = {a: sum(1 for s in slots if s["arm"] == a) for a in ARMS}
    if any(v > PER_ARM for v in per_arm.values()):
        raise ValueError("an arm holds more than %d judge slots" % PER_ARM)
    for i in range(0, len(slots), 3):
        rnd = slots[i:i + 3]
        if sorted(s["arm"] for s in rnd) != sorted(ARMS) or len({s["round"] for s in rnd}) != 1 or rnd[0]["round"] != i // 3:
            raise ValueError("the schedule is not interleaved complete rounds (arm-sequential order refused)")


class Judging:
    def __init__(self, ledger, call, quota, readiness, clock):
        self.ledger, self.call, self.quota, self.readiness, self.clock = ledger, call, quota, readiness, clock

    def _ev(self, kind):
        return [e for e in self.ledger.events if e["ev"] == kind]

    def schedule(self):
        s = self._ev("judge_sealed")
        return s[-1]["slots"] if s else None

    def seal(self, slots):
        if self.schedule() is None:
            validate_schedule(slots)
            self.ledger._log({"ev": "judge_sealed", "slots": slots})

    def ended(self):
        e = self._ev("judge_end")
        return e[-1]["reason"] if e else None

    def end(self, reason):
        if not self.ended():
            self.ledger._log({"ev": "judge_end", "reason": reason})
        return reason

    def next_slot(self):
        done = {e["slot"] for e in self.ledger.events if e["ev"] in ("judge_verdict", "judge_not_needed", "judge_failed")}
        for i in range(len(self.schedule() or [])):
            if i not in done:
                return i
        return None

    def run(self):
        """Run (or resume) the sealed schedule until it completes or judging ends."""
        slots = self.schedule()
        if slots is None:
            raise ValueError("no sealed judge schedule")
        if self.ended():
            return self.ended()
        for r in sorted({s["round"] for s in slots}):
            self._commit(slots, r)
        for e in self._ev("book"):
            if e["kind"] == "judge" and e["attempt"] in self.ledger.inflight:
                self.ledger.killed(e["attempt"], None, False)
                self.ledger._log({"ev": "judge_failed", "slot": int(e["attempt"].split("-")[1]), "why": "killed"})
                return self.end("failed_slot")
        while True:
            i = self.next_slot()
            if i is None:
                return self.end("complete")
            s = slots[i]
            calls = [e for e in self._ev("book") if e["kind"] == "judge"]
            if s["candidate"] is None:
                self.ledger._log({"ev": "judge_not_needed", "slot": i})
                self._commit(slots, s["round"])
                continue
            if len(calls) >= TOTAL or sum(1 for e in calls if slots[int(e["attempt"].split("-")[1])]["arm"] == s["arm"]) >= PER_ARM:
                return self.end("quota_exhausted")
            while not self.quota.ok():
                deadline = self.ledger.usage_refused(self.clock.now())
                if self.clock.now() >= deadline:
                    return self.end("usage_expired")
                self.clock.sleep(1800)
            if self.readiness.recheck():
                return self.end("auth_or_readiness_refused")
            if self.ledger.blocked():
                return self.end("hard_stop")
            attempt = "judge-%02d" % i
            self.ledger.book(attempt, "judge", BOOK, "judge")
            try:
                v = self.call(s["candidate"], s["arm"], attempt)
            except UsageRefusedInCall as u:
                self.ledger.settle(attempt, u.cost)
                self.ledger._log({"ev": "judge_failed", "slot": i, "why": "usage_refused_in_call"})
                return self.end("failed_slot")
            except Exception as e:     # no replay of a paid call, whatever went wrong
                self.ledger.killed(attempt, None, False)
                self.ledger._log({"ev": "judge_failed", "slot": i, "why": type(e).__name__})
                return self.end("failed_slot")
            if v.get("cost") is None:   # no usage evidence is never free: the booking stays unsettled
                self.ledger.killed(attempt, None, False)
                self.ledger._log({"ev": "judge_failed", "slot": i, "why": "no_usage_evidence"})
                return self.end("unknown_spend")
            if not self.ledger.settle(attempt, v.get("cost")):
                return self.end("hard_stop")
            if not v.get("valid"):
                self.ledger._log({"ev": "judge_failed", "slot": i, "why": "invalid_verdict"})
                return self.end("invalid_verdict")
            self.ledger._log({"ev": "judge_verdict", "slot": i, "verdict_id": v.get("id"), "verdict": v.get("verdict")})
            self._commit(slots, s["round"])

    def _commit(self, slots, r):
        resolved = {e["slot"] for e in self.ledger.events if e["ev"] in ("judge_verdict", "judge_not_needed")}
        if all(i in resolved for i, s in enumerate(slots) if s["round"] == r) and r not in {e["round"] for e in self._ev("judge_round")}:
            self.ledger._log({"ev": "judge_round", "round": r})

    def result(self):
        """Applied verdicts (complete-round prefix only) and the counts the report prints."""
        slots = self.schedule() or []
        complete = sorted(e["round"] for e in self._ev("judge_round"))
        prefix = 0
        while prefix in complete:
            prefix += 1
        verdicts = {e["slot"]: e["verdict"] for e in self._ev("judge_verdict")}
        applied, discarded = {}, 0
        for i, v in verdicts.items():
            s = slots[i]
            if s["round"] < prefix:
                applied.setdefault(s["arm"], {})[s["candidate"]] = v == "SUPPORTED"
            else:
                discarded += 1
        unjudged = {a: sum(1 for s in slots if s["arm"] == a and s["candidate"] and s["candidate"] not in applied.get(a, {})) for a in ARMS}
        return {"completed_rounds": prefix, "discarded_verdicts": discarded, "unjudged": unjudged, "applied": applied,
                "calls": sum(1 for e in self._ev("book") if e["kind"] == "judge"), "ended": self.ended()}


class RealJudge:
    """One blinded, tool-less, one-turn judge call. Never exercised by build tests."""

    def __init__(self, cfg, items):
        if os.environ.get("HIMMEL_BILLED_OK") != "1":
            raise SystemExit("judge: refused: judge calls need HIMMEL_BILLED_OK=1")
        self.cfg, self.items = cfg, items      # items: {candidate: {question, fact, answer, path, file}}
        self.prompt = open(os.path.join(HERE, "judge-prompt.md")).read()

    def __call__(self, candidate, arm, attempt):
        it = self.items[(arm, candidate)]
        text = self.prompt
        for k, v in (("QUESTION", it["question"]), ("FACT", it["fact"]), ("ANSWER", it["answer"]), ("PATH", it["path"]), ("FILE", it["file"])):
            text = text.replace("{{%s}}" % k, v)
        env = {"PATH": "/usr/bin:/bin", "HOME": self.cfg["judge_home"], "CLAUDE_CODE_OAUTH_TOKEN": open(self.cfg["eval_token_file"]).read().strip(),
               "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1"}
        argv = [self.cfg["claude"], "-p", "--safe-mode", "--strict-mcp-config", "--setting-sources", "", "--tools", "",
                "--model", "claude-sonnet-5-5", "--max-budget-usd", str(CAP), "--output-format", "json", "--no-session-persistence"]
        p = subprocess.run(argv, input=text, capture_output=True, text=True, env=env, timeout=600)
        try:
            r = json.loads(p.stdout)
        except ValueError:
            raise RuntimeError("no parseable judge result")
        if "usage" in str(r.get("result", "")).lower() and r.get("is_error"):
            raise UsageRefusedInCall(float(r.get("total_cost_usd") or 0))
        line = str(r.get("result", "")).strip()
        verdict = {"VERDICT: SUPPORTED": "SUPPORTED", "VERDICT: NOT SUPPORTED": "NOT SUPPORTED"}.get(line)
        cost = r.get("total_cost_usd")
        return {"valid": verdict is not None and not r.get("is_error"), "verdict": verdict, "id": r.get("session_id"),
                "cost": float(cost) if isinstance(cost, (int, float)) and not isinstance(cost, bool) else None}


def contained_read(path, roots):
    """The text of an answer-named /work path, read only INSIDE its export copy: a path that
    resolves outside (.., symlinks) is treated as absent, so no host file reaches the judge.
    None = absent or outside, False = present but unreadable, else the text."""
    for pre, root in roots.items():
        if path.startswith(pre):
            base = os.path.realpath(root)
            full = os.path.realpath(os.path.join(base, path[len(pre):]))
            if os.path.commonpath([base, full]) != base or not os.path.isfile(full):
                return None
            try:
                with open(full, encoding="utf-8") as f:
                    return f.read()
            except (OSError, UnicodeDecodeError):
                return False
    return None


class LocalOnly:
    """The Q fixed lists book nothing: local compute, recorded only in the list rows."""

    def local(self, task_id):
        return "local-%s" % task_id

    def settle(self, booking, status):
        pass


def finalize(pilot, cohort, cfg):
    """run-pilot's finalization hook: score the frozen cohort, judge it, then the matched lists."""
    import importlib.util

    def load(name):
        s = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
        m = importlib.util.module_from_spec(s)
        s.loader.exec_module(m)
        return m
    sc, ml, L = load("score"), load("matched-lists"), load("ledger")
    bank = {t["id"]: t for t in pilot.tasks}
    roots = {"/work/himmel/": cfg["exports"]["himmel"], "/work/luna/": cfg["exports"]["luna"]}
    read = lambda p: contained_read(p, roots)   # noqa: E731
    rows, disputes, items = {}, {a: set() for a in ARMS}, {}
    for t in cohort:
        for a in ARMS:
            res = json.load(open(os.path.join(cfg["run_root"], "private", "results", "answer-%s-%s.json" % (t, a))))
            text = str(res.get("result", ""))
            r = sc.score(bank[t], text, read)
            rows[(t, a)] = r
            answer, files = sc.parse(text)
            for d in r["disputes"]:
                key = "%s#%d" % (t, d["fact"])
                disputes[a].add(key)
                path = next((f for f in files[:3] if read(f) is not None), files[0] if files else "")
                body = read(path)
                items[(a, key)] = {"question": bank[t]["question"], "fact": bank[t]["facts"][d["fact"]]["text"], "answer": answer or "",
                                   "path": path, "file": body if isinstance(body, str) else "(the script could not read this file)"}
    j = Judging(pilot.ledger, RealJudge(cfg, items), pilot.quota, pilot.readiness, pilot.clock)
    j.seal(seal_schedule(cfg["seed"], candidates(cfg["seed"], disputes, cohort, list(bank))))
    j.run()
    res = j.result()
    scores = {t: {a: sc.apply_verdicts(rows[(t, a)], {int(k.split("#")[1]): v for k, v in res["applied"].get(a, {}).items() if k.split("#")[0] == t})
                  for a in ARMS} for t in cohort}
    out = {"judge": res, "scores": scores}
    if not pilot.ledger.blocked() and not pilot.ledger.lists_cancelled():
        lists = {}
        for mode in ("S", "Q"):
            booking = L.ListBooking(pilot.ledger) if mode == "S" else LocalOnly()
            lists[mode] = ml.run_lists(pilot.tasks, mode, json.load(open(cfg["list_ctx"][mode])), booking,
                                       os.path.join(cfg["run_root"], "private", "lists-%s.jsonl" % mode))
        out["lists_complete"] = all(r["status"] == "ok" for rs in lists.values() for r in rs)
    else:
        out["lists_complete"] = False
    pilot.settle_usage()
    return out


if __name__ == "__main__":
    print("judge.py is a library: run-pilot.py calls finalize() under the R8 go", file=sys.stderr)
    sys.exit(2)
