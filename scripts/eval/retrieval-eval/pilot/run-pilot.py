#!/usr/bin/env python3
# billed-opt-in: HIMMEL_BILLED_OK
"""run-pilot.py -- the RAG pilot's three-arm runner (plan r18 B4, design sections 2, 5, 6, 11).

    run-pilot.py --config RUN.json        (refuses without HIMMEL_BILLED_OK=1, a READY G0,
                                           a clean tools.lock, a current PILOT APPROVED card
                                           review (G4) and a distinct R8 go file)

The state machine (class Pilot) is pure: every paid action goes through an injected launcher,
the capped ledger and injected usage/quota/readiness/probe/clock objects, so the build fixtures
drive it with mocks and no session ever starts. Its order:

  H reserved -> P1 (V/S/Q clean profiles + the planted-marker control; P1-S books one s-qmd
  query at b) -> P2 (one safe access probe per arm) -> initial S/Q P3 probes -> G5 ->
  triples in the sealed balanced schedule, each admitted atomically (Btriple) after the
  boundary checks (unsettled spend, skip ceiling, the 36-reachable count, usage pause with
  its one persisted deadline, auth/readiness) -> after four complete triples, G6 (settled S
  usage, repricing, projection, route use >= 3/4 in S and in Q; no fifth calibration task)
  -> P3 checkpoints after tasks 10/20/30 and at the end -> the common cohort is frozen and
  finalization (judging, lists) is handed to the caller only when the stop state allows it.

HARD_STOP versus FINALIZE_ONLY follows section 6: before G6 every stop is a HARD_STOP; after
it, capacity/usage-expiry/benign-probe/auth/readiness refusals end admission (FINALIZE_ONLY)
while integrity, overrun, unsettled or unclassified failures stop every paid call. A killed
answer is never replayed: its triple is excluded and its cost stays. No gate reads a score.
"""
import argparse, hashlib, importlib.util, itertools, json, os, random, re, shutil, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", "..", ".."))


def _load(name):
    s = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


L = _load("ledger")
PERMS = ["".join(p) for p in itertools.permutations("VSQ")]
CHECKPOINTS = (10, 20, 30)
KEY_METER_SETTLE_SECONDS = 60


class Killed(Exception):
    """A launched call that was killed or crashed; usage_* is the trusted transcript evidence."""

    def __init__(self, usage_cost=None, usage_complete=False):
        super().__init__("killed")
        self.usage_cost, self.usage_complete = usage_cost, usage_complete


class Crash(Exception):
    """The runner itself dies here (fixtures): the ledger is what survives."""


def schedule(task_ids, seed):
    """Seeded task order and balanced arm order: six shuffled blocks of all six permutations,
    then four distinct permutations whose two omitted ones share no arm position."""
    if len(task_ids) != 40 or len(set(task_ids)) != 40:
        raise ValueError("the protocol needs exactly 40 distinct task ids")
    rng = random.Random(seed)
    order = sorted(task_ids)
    rng.shuffle(order)
    blocks = PERMS * 6
    rng.shuffle(blocks)
    pairs = [(a, b) for a, b in itertools.combinations(PERMS, 2) if all(x != y for x, y in zip(a, b))]
    omit = rng.choice(pairs)
    suffix = [p for p in PERMS if p not in omit]
    rng.shuffle(suffix)
    perms = blocks + suffix
    for arm in "VSQ":
        for pos in range(3):
            n = sum(1 for p in perms if p[pos] == arm)
            if n not in (13, 14):
                raise AssertionError("arm %s at position %d: %d" % (arm, pos, n))
    return list(zip(order, perms))


class Pilot:
    def __init__(self, tasks, ledger, launcher, usage, quota, readiness, prober, clock, seed, finalize=None):
        self.tasks, self.ledger, self.launcher = tasks, ledger, launcher
        self.usage, self.quota, self.readiness, self.prober, self.clock = usage, quota, readiness, prober, clock
        self.finalize_cb = finalize
        self.plan = schedule([t["id"] for t in tasks], seed)
        self.rows = {}
        self.status = {}
        self.launches = 0
        self.g6_passed = self._mark("g6_passed")

    def _mark(self, name):
        return any(e["ev"] == "mark" and e["name"] == name for e in self.ledger.events)

    def mark(self, name, **kw):
        self.ledger._log(dict({"ev": "mark", "name": name}, **kw))

    def stop(self, kind, reason):
        if kind == "FINALIZE_ONLY" and not self.g6_passed:
            self.mark("pre_g6_stop", detail=reason)
            kind, reason = "HARD_STOP", "pre_g6"
        self.ledger.halt(kind, reason)
        return False

    def stopped(self):
        return self.ledger.stop is not None

    def call(self, task, arm, phase, kind, from_reserve=None):
        attempt = "%s-%s-%s" % (phase, task, arm)
        self.ledger.book(attempt, kind, L.BOOK[kind], from_reserve)
        self.launches += 1
        try:
            out = self.launcher.launch(task, arm, attempt, phase)
        except Killed as k:
            self.ledger.killed(attempt, k.usage_cost, k.usage_complete)
            return {"killed": True}
        except Crash:
            raise
        except Exception as e:
            self.mark("unclassified", detail=type(e).__name__)
            self.ledger._log({"ev": "unsettled", "attempt": attempt})
            self.stop("HARD_STOP", "unclassified")
            return {"killed": True}
        costs = [c for c in (out.get("cost_usd"), out.get("usage_cost")) if isinstance(c, (int, float)) and not isinstance(c, bool)]
        if not costs:
            self.ledger.killed(attempt, None, False)
            return dict(out, killed=True)
        self.ledger.settle(attempt, max(costs))
        if out.get("hard_abort") or out.get("survivors"):
            self.stop("HARD_STOP", "integrity")
        return out

    def settle_usage(self):
        self.clock.sleep(KEY_METER_SETTLE_SECONDS)
        total = self.usage.cumulative()
        if total is None:
            return self.stop("HARD_STOP", "unknown_spend")
        prev = self.ledger.last_meter()
        if prev is None:
            prev = self.usage.baseline()
        if prev is None:
            return self.stop("HARD_STOP", "unknown_spend")
        return self.ledger.settle_s_interval(total - prev, len(self.ledger.s_interval), meter=total)

    def probe(self, checkpoint, initial=False):
        """S cash probe (initial from capacity, later from the probes reserve) and a local Q probe."""
        out = {}
        for arm in "SQ":
            if arm == "S":
                self.ledger.book("p3-%s-S" % checkpoint, "s_query", self.ledger.b, None if initial else "probes")
            out[arm] = self.prober.probe(arm, checkpoint)
        return out

    @staticmethod
    def probe_ok(p):
        return all(not r.get("integrity") and not r.get("skips") and r.get("expanded", True) for r in p.values())

    def preflight(self):
        res = {}
        for arm in "VSQ":
            if arm == "S":
                self.ledger.book("p1-S-q01", "s_query", self.ledger.b)
            res["P1-" + arm] = self.call("p1", arm, "p1", "check")
            if self.stopped():
                return False
        res["P1-control"] = self.call("p1", "control", "p1", "check")
        for arm in "VSQ":
            res["P2-" + arm] = self.call("p2", arm, "p2", "check")
            if self.stopped():
                return False
        probes = self.probe("initial", initial=True)
        ok = all(not r.get("killed") and r.get("profile_clean") and not r.get("skips") and not r.get("service")
                 and r.get("qmd_calls", 0) == (1 if a in ("P1-S", "P1-Q") else 0)
                 for a, r in res.items() if a in ("P1-V", "P1-S", "P1-Q"))
        ok = ok and res["P1-control"].get("marker_detected") is True
        ok = ok and all((res["P2-" + a].get("p2") or {}).get("result") == "pass" for a in "VSQ")
        if any(r.get("integrity") for r in probes.values()):
            return self.stop("HARD_STOP", "security_probe_failure")
        ok = ok and self.probe_ok(probes)
        if not ok:
            return self.stop("HARD_STOP", "g5_failed")
        self.mark("g5_passed")
        return True

    def common(self):
        return [t for t, s in self.status.items() if s == "complete"]

    def skip_union(self):
        return sum(1 for t, s in self.status.items() if s.startswith("excluded") and "skip" in s.split(":", 1)[1].split(","))

    def boundary(self, remaining):
        if self.ledger.blocked():
            return self.stop("HARD_STOP", "unsettled") if self.ledger.unsettled else False
        if self.skip_union() > 2:
            return self.stop("HARD_STOP", "skip_ceiling")
        if len(self.common()) + remaining < 36:
            return self.stop("HARD_STOP", "insufficient_common_cohort")
        while not self.quota.ok():
            deadline = self.ledger.usage_refused(self.clock.now())
            if self.clock.now() >= deadline:
                return self.stop("FINALIZE_ONLY", "usage_expired")
            self.clock.sleep(L.PAUSE_CHECK_S)
        why = self.readiness.recheck()
        if why:
            return self.stop("FINALIZE_ONLY", "auth_refused" if why == "auth" else "readiness_refused")
        return True

    def triple(self, task, perm):
        if not self.ledger.admit_triple(task):
            return self.stop("FINALIZE_ONLY", "capacity_refused")
        rows = {}
        for arm in perm:
            out = self.call(task, arm, "answer", "answer", "triple:%s:answers" % task)
            rows[arm] = out
            self.ledger.triple_event(task, arm=arm, status="killed" if out.get("killed") else "done")
            if arm == "S" and not out.get("killed"):
                self.ledger.book_s_queries("answer-%s-S" % task, int(out.get("qmd_calls") or 0), "triple:%s:search" % task)
            if out.get("killed") or self.stopped():
                break
        self.rows[task] = rows
        reasons = set()
        if len(rows) < 3 or any(r.get("killed") for r in rows.values()):
            reasons.add("interrupted")
        for arm, r in rows.items():
            reasons |= {"service" for _ in r.get("service") or []}
            if arm in "SQ" and r.get("skips"):
                reasons.add("skip")
        self.status[task] = "complete" if not reasons else "excluded:" + ",".join(sorted(reasons))
        self.ledger.release("triple:%s:answers" % task)
        self.ledger.release("triple:%s:search" % task)
        self.ledger.triple_event(task, state="done", status=self.status[task])
        return not self.stopped()

    def g6(self, first4):
        if any(self.status[t] != "complete" for t in first4):
            return self.stop("HARD_STOP", "first_four_failure")
        if not self.settle_usage():
            return False
        costs = []
        for t in first4:
            c = sum(e["actual"] for e in self.ledger.events if e["ev"] == "settle" and e["attempt"].startswith("answer-%s-" % t))
            c += self.ledger.b * int(self.rows[t]["S"].get("qmd_calls") or 0)
            costs.append(c)
        p = sum(costs) / 4
        use = {a: sum(1 for t in first4 if (self.rows[t][a].get("qmd_calls") or 0) + (self.rows[t][a].get("graph_calls") or 0) > 0) for a in "SQ"}
        ok = L.g6_ok(self.ledger.spent, p, self.ledger.remaining_h(), self.ledger.b) and use["S"] >= 3 and use["Q"] >= 3
        self.mark("g6", p=p, route_use=use, ok=ok)
        if not ok:
            return self.stop("HARD_STOP", "g6_failed")
        self.g6_passed = True
        self.mark("g6_passed")
        return True

    def checkpoint(self, name):
        if self.ledger.reserves.get("probes", 0.0) + L.EPS < self.ledger.b:
            return True
        p = self.probe(name)
        if any(r.get("integrity") for r in p.values()):
            return self.stop("HARD_STOP", "security_probe_failure")
        if not self.settle_usage():
            return False
        if not self.probe_ok(p):
            return self.stop("FINALIZE_ONLY", "benign_probe_failure")
        return True

    def run(self):
        if not self.readiness.g0():
            return {"refused": "G0", "launches": 0}
        for attempt in sorted(self.ledger.inflight):
            cost, complete = self.launcher.recover(attempt)
            self.ledger.killed(attempt, cost, complete)
        if not self._mark("h_reserved"):
            try:
                self.ledger.reserve_h()
            except L.Refused:
                return {"refused": "capacity", "launches": 0}
            self.mark("h_reserved")
        if not self._mark("g5_passed") and not self.stopped():
            self.preflight()
        done = {t: v for t, v in self.ledger.triples.items()}
        for t, v in done.items():
            if v["state"] == "done":
                ev = [e for e in self.ledger.events if e["ev"] == "triple" and e["task"] == t and e.get("state") == "done"][-1]
                self.status[t] = ev.get("status", "complete")
            else:
                self.status[t] = "excluded:interrupted"
                self.ledger.release("triple:%s:answers" % t)
                self.ledger.release("triple:%s:search" % t)
                self.ledger.triple_event(t, state="done", status=self.status[t])
        attempted = [t for t, _ in self.plan if t in self.status]
        for i, (task, perm) in enumerate(self.plan):
            if self.stopped():
                break
            if task in self.status:
                continue
            if not self.boundary(len(self.plan) - i):
                break
            if not self.triple(task, perm):
                break
            attempted.append(task)
            if len(attempted) == 4 and not self.g6_passed and not self.g6(attempted[:4]):
                break
            if len(attempted) in CHECKPOINTS and not self.checkpoint(str(len(attempted))):
                break
        if not self.stopped() and len(attempted) == len(self.plan):
            self.checkpoint("end")
        if self.ledger.stop and self.ledger.stop["kind"] == "FINALIZE_ONLY":
            self.ledger.release("probes")
        return self.finish()

    def finish(self):
        cohort = sorted(self.common())
        stop = self.ledger.stop
        rep = {"launches": self.launches, "attempted": len(self.status), "completed": sum(1 for t in self.rows if len(self.rows[t]) == 3),
               "common_scored": len(cohort), "skip_union": self.skip_union(),
               "excluded": {t: s.split(":", 1)[1] for t, s in self.status.items() if s.startswith("excluded")},
               "spent": round(self.ledger.spent, 6), "committed": round(self.ledger.committed(), 6), "b": self.ledger.b,
               "g6_passed": self.g6_passed, "lists_cancelled": self.ledger.lists_cancelled()}
        if stop and stop["kind"] == "HARD_STOP":
            rep.update(stop_kind="HARD_STOP", reason=stop["reason"], finalization_status="none", cohort=[])
            return rep
        if len(cohort) < 36:
            self.ledger.halt("HARD_STOP", "insufficient_common_cohort")
            rep.update(stop_kind="HARD_STOP", reason="insufficient_common_cohort", finalization_status="none", cohort=[])
            return rep
        rep.update(stop_kind=stop["kind"] if stop else "NONE", reason=stop["reason"] if stop else None,
                   finalization_status="short" if len(cohort) < 40 else "full", cohort=cohort)
        if self.finalize_cb:
            rep["finalization"] = self.finalize_cb(self, cohort)
        return rep


def claude_argv(arms, arm, model=None, budget=None):
    """The pinned CLI argv, identical across V/S/Q except the retrieval commands S/Q may run."""
    allowed = ["Read", "Grep", "Glob"] + ["Bash(%s:*)" % c for c in arms["bash_commands"]]
    if arms["arms"][arm]["retrieval"]:
        allowed += ["Bash(%s:*)" % c for c in arms["retrieval_commands"]]
    return ["--print", "--safe-mode", "--strict-mcp-config", "--mcp-config", '{"mcpServers": {}}',
            "--setting-sources", "", "--settings", "/opt/claude/settings.json",
            "--permission-mode", arms["permission_mode"], "--tools", ",".join(arms["tools"]),
            "--allowedTools", ",".join(allowed), "--output-format", arms["output_format"],
            "--model", model or arms["answer_model"], "--max-budget-usd", str(budget or arms["budget_usd"])]


def render_prompt(question, arm, arms):
    text = open(os.path.join(HERE, "task-prompt.md")).read()
    note = open(os.path.join(HERE, "tools", "s-note.md")).read() if arms["arms"][arm]["retrieval"] else ""
    return text.replace("{{RETRIEVAL_NOTE}}", note).replace("{{QUESTION}}", question)


def start_broker(argv):
    """The s-qmd broker child of one session; on Linux the kernel ends it with this runner."""
    if not sys.platform.startswith("linux"):
        return subprocess.Popen(argv)

    def die_with_parent():
        import ctypes, signal
        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGKILL, 0, 0, 0)  # PR_SET_PDEATHSIG
    return subprocess.Popen(argv, preexec_fn=die_with_parent)


class RealLauncher:
    """Launches one sandboxed subscription session per call. Never exercised by build tests:
    every call is paid, so it exists only behind the opt-in, G0, G4 and the R8 go."""

    def __init__(self, cfg, arms, tasks):
        if os.environ.get("HIMMEL_BILLED_OK") != "1":
            raise SystemExit("run-pilot: refused: real sessions need HIMMEL_BILLED_OK=1")
        self.cfg, self.arms, self.tasks = cfg, arms, {t["id"]: t for t in tasks}

    def launch(self, task, arm, attempt, phase):
        c, root = self.cfg, self.cfg["run_root"]
        home = os.path.join(root, "homes", attempt)
        os.makedirs(os.path.join(home, ".claude"), mode=0o700)
        with open(os.path.join(home, ".claude", "canary.json"), "w") as f:
            json.dump({"canary": "inert-%s" % attempt}, f)
        token = open(c["eval_token_file"]).read().strip()
        envs = ["%s=%s" % kv for kv in sorted(self.arms["env"].items())] + ["CLAUDE_CODE_OAUTH_TOKEN=" + token]
        cmd = ["bash", os.path.join(HERE, "sandbox.sh"), "--arm", arm if arm in "VSQ" else "V", "--home", home,
               "--himmel", c["exports"]["himmel"], "--luna", c["exports"]["luna"], "--claude", c["claude"],
               "--settings", c["settings"]] + sum((["--env", e] for e in envs), [])
        broker = None
        if arm in "SQ":
            s = c["retrieval"][arm]
            idx = os.path.join(root, "sessions", attempt + ".sqlite")
            subprocess.run([sys.executable, "-I", os.path.join(HERE, "pins.py"), "disposable", s["master"], idx, "--seal", s["seal"]], check=True)
            sock, meta = os.path.join(root, "sessions", attempt + ".sock"), os.path.join(root, "private", "broker", attempt)
            broker = start_broker([sys.executable, "-I", os.path.join(HERE, "tools", "s-qmd"), "serve", "--socket", sock,
                                   "--meta", meta, "--phase", "answer" if phase == "answer" else "preflight", "--arm", arm, "--cap", "12"]
                                  + (["--nvml-cmd", c["nvml_cmd"]] if arm == "Q" else []))
            cmd += ["--tools", os.path.join(HERE, "tools"), "--binding", s["binding"], "--socket", sock, "--index", idx,
                    "--qmd-pkg", c["qmd_pkg"], "--qmd-config", s["config_dir"], "--graph", c["graph_dir"], "--manifests", c["manifests_dir"]]
            cmd += ["--key", c["s_key_file"]] if arm == "S" else ["--models", c["q_models"]]
        question = self.tasks[task]["question"] if task in self.tasks else c["probe_questions"][phase]
        cmd += ["--", "/opt/claude/claude"] + claude_argv(self.arms, arm if arm in "VSQ" else "V")
        try:
            p = subprocess.run(cmd, input=render_prompt(question, arm if arm in "VSQ" else "V", self.arms),
                               capture_output=True, text=True, timeout=1800)
        except subprocess.TimeoutExpired:
            raise Killed(None, False)
        finally:
            if broker:
                broker.terminate()
                broker.wait(timeout=10)
        res = os.path.join(root, "private", "results", attempt + ".json")
        os.makedirs(os.path.dirname(res), exist_ok=True)
        with open(res, "w") as f:
            f.write(p.stdout)
        trans = sorted(_glob(os.path.join(home, ".claude", "projects")))
        row = subprocess.run([sys.executable, "-I", os.path.join(HERE, "route-rows.py"), "row", "--arm", arm if arm in "VSQ" else "V",
                              "--transcript", trans[-1] if trans else "/dev/null", "--meta",
                              os.path.join(root, "private", "broker", attempt) if arm in "SQ" else "",
                              "--result", res, "--policy", c["policy"]], capture_output=True, text=True)
        out = json.loads(row.stdout) if row.stdout.strip() else {"service": ["runner_crash"]}
        out["usage_cost"] = price(res)
        return out

    def recover(self, attempt):
        """A call in flight when the runner died: its retained transcript usage, complete only when
        the session wrote its final result; anything less is not proof of zero."""
        res = os.path.join(self.cfg["run_root"], "private", "results", attempt + ".json")
        cost = price(res) if os.path.isfile(res) else None
        return cost, cost is not None


def _glob(d):
    for dp, _, fns in os.walk(d):
        for n in fns:
            if n.endswith(".jsonl"):
                yield os.path.join(dp, n)


def price(result_path):
    """total_cost_usd beside the usage-derived price from the pinned price table; charge the larger."""
    try:
        d = json.load(open(result_path))
    except (OSError, ValueError):
        return None
    mjs = os.path.join(REPO, "scripts", "lanes", "model-price.mjs")
    js = ("import {loadPrices, priceCall} from %s; let s=''; process.stdin.on('data', d => s += d).on('end', () => {"
          "const r = priceCall(JSON.parse(s), loadPrices()); console.log(JSON.stringify({priced: r.priced, usd: r.usd}))});" % json.dumps("file://" + mjs))
    r = subprocess.run(["node", "--input-type=module", "-e", js], input=json.dumps({"model": d.get("model"), "usage": d.get("usage") or {}}),
                       capture_output=True, text=True)
    try:
        p = json.loads(r.stdout)
    except ValueError:
        return None
    return max(float(d.get("total_cost_usd") or 0), float(p.get("usd") or 0)) if p.get("priced") else None


def gates(cfg):
    """G0 (auth-preflight READY), the tools.lock check, G4 (the card review ends PILOT APPROVED
    for the current card hash) and the distinct R8 go file. Returns the list of refusals."""
    bad = []
    card_sha = hashlib.sha256(open(cfg["card"], "rb").read()).hexdigest()
    try:
        with open(cfg["astra_review"], encoding="utf-8") as f:
            review = f.read().rstrip().splitlines()
    except (OSError, UnicodeDecodeError):
        bad.append("G4: the card review %s cannot be read" % cfg["astra_review"])
    else:
        if not review or review[-1].strip() != "PILOT APPROVED" or card_sha not in "\n".join(review):
            bad.append("G4: the card review %s does not end PILOT APPROVED for the current card" % cfg["astra_review"])
    if not os.path.isfile(cfg.get("r8_go", "")):
        bad.append("no distinct R8 go")
    if subprocess.run([sys.executable, "-I", os.path.join(HERE, "tools-lock.py"), "check", cfg["lock"]]).returncode:
        bad.append("tools.lock check failed")
    if subprocess.run([sys.executable, "-I", os.path.join(HERE, "auth-preflight.py"), "--readiness", cfg["auth_readiness"],
                       "--lock", cfg["lock"], "--card-sha256", card_sha]).returncode:
        bad.append("G0: auth readiness is not READY")
    return bad


class KeyUsage:
    """The dedicated OpenRouter key's cumulative usage through the unchanged fetchOpenRouterKey."""

    def __init__(self, key_file):
        self.key_file, self.first = key_file, None

    def read(self):
        mjs = os.path.join(REPO, "scripts", "api-lane", "shift-spend.mjs")
        js = ("import {fetchOpenRouterKey} from %s; const k = (await import('node:fs')).readFileSync(process.argv[1], 'utf8').trim();"
              "const b = await fetchOpenRouterKey(k); console.log(JSON.stringify((b && b.data) || {}));" % json.dumps("file://" + mjs))
        r = subprocess.run(["node", "--input-type=module", "-e", js, self.key_file], capture_output=True, text=True, timeout=60)
        try:
            u = json.loads(r.stdout).get("usage")
        except ValueError:
            return None
        return float(u) if isinstance(u, (int, float)) else None

    def baseline(self):
        if self.first is None:
            self.first = self.read()
        return self.first

    def cumulative(self):
        return self.read()


class Quota:
    def ok(self):
        r = subprocess.run(["bash", os.path.join(REPO, "scripts", "lib", "usage-preflight.sh")], capture_output=True, text=True)
        return r.returncode == 0 and "PROCEED" in r.stdout


class Readiness:
    def __init__(self, cfg):
        self.cfg = cfg

    def g0(self):
        return not gates(self.cfg)

    def recheck(self):
        bad = gates(self.cfg)
        return None if not bad else ("auth" if any(b.startswith("G0") for b in bad) else "readiness")


class Prober:
    """A P3 probe: the locked control query through s-qmd on a fresh disposable copy (phase=probe)."""

    def __init__(self, cfg):
        self.cfg, self.ml = cfg, _load_path(os.path.join(HERE, "matched-lists.py"), "matched_lists")

    def probe(self, arm, checkpoint):
        ctx = self.cfg["probe_ctx"][arm]
        work = tempfile.mkdtemp(prefix="p3.", dir=self.cfg["run_root"])
        try:
            term, integrity, _ = self.ml.one_query(ctx, arm, "p3-%s" % checkpoint, self.cfg["probe_query"], work)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        return {"integrity": bool(integrity), "skips": int(bool(term is None or term.get("skip"))),
                "expanded": bool(term) and term.get("expansion") == "expanded"}


class Clock:
    now = staticmethod(time.time)
    sleep = staticmethod(time.sleep)


def _load_path(path, name):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


def main(argv):
    ap = argparse.ArgumentParser(prog="run-pilot.py")
    ap.add_argument("--config", required=True)
    a = ap.parse_args(argv)
    if os.environ.get("HIMMEL_BILLED_OK") != "1":
        print("run-pilot: refused: the pilot spends subscription quota and OpenRouter cash; it runs only with HIMMEL_BILLED_OK=1 under the R8 go", file=sys.stderr)
        return 2
    cfg = json.load(open(a.config))
    bad = gates(cfg)
    if bad:
        for b in bad:
            print("run-pilot: refused: " + b, file=sys.stderr)
        return 3
    arms = json.load(open(os.path.join(HERE, "arms.json")))
    tasks = [json.loads(l) for l in open(cfg["bank"]) if l.strip()]
    ledger = L.Ledger(os.path.join(cfg["run_root"], "private", "ledger.jsonl"))

    def finalize(pilot, cohort):
        judge = _load_path(os.path.join(HERE, "judge.py"), "judge")
        return judge.finalize(pilot, cohort, cfg)

    pilot = Pilot(tasks, ledger, RealLauncher(cfg, arms, tasks), KeyUsage(cfg["s_key_file"]), Quota(), Readiness(cfg),
                  Prober(cfg), Clock(), cfg["seed"], finalize)
    rep = pilot.run()
    out = os.path.join(cfg["run_root"], "private", "run-report.json")
    with open(out, "w") as f:
        json.dump(rep, f, indent=1, sort_keys=True)
    print(json.dumps({k: rep.get(k) for k in ("stop_kind", "reason", "finalization_status", "attempted", "common_scored", "spent")}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
