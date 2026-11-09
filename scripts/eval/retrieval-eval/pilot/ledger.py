#!/usr/bin/env python3
"""ledger.py -- the RAG pilot's capped $25 R8 ledger (design section 6, plan B4).

One append-only, fsynced JSONL event log per run; the in-memory state is always a replay of
it, so a crash or kill resumes from exactly what was durably booked. Money is in USD.

  committed = spent + in-flight bookings + unsettled exposure + live reserves  <=  cap

* H = .90 + 44b is reserved before the first triple: fifteen judge bookings (.06), the four
  remaining S P3 probes (b) and the forty S fixed lists (b).
* Each triple is admitted atomically with Btriple = 3 x .35 + 12b, or not at all.
* A paid operation transfers its own reserved amount into an in-flight booking (fsynced before
  the caller launches anything), then into spent when it settles: never counted twice.
* A subscription call that settles above its booking, or a settled S interval whose cash delta
  exceeds the sum of that interval's S bookings, is an overrun: HARD_STOP.
* A killed call stays booked; it settles only from trusted, complete usage evidence, otherwise
  it becomes unsettled exposure that blocks every further paid call. Nothing is replayed.
* Repricing: b = max(b, .004, 1.5 x interval cash / admitted S invocations); the remaining H
  and the next Btriple follow the new b. A prospective rise never cures an actual overrun.
* One persisted usage-pause deadline per run: the first usage refusal + 7 days, never reset.

The stop classifier lives here too (D1): HARD_STOP dominates FINALIZE_ONLY; nothing in this
file reads an answer score.
"""
import json, math, os, time

CAP_PILOT = 25.0
CAP_R5 = 0.50
B_MIN = 0.004
BOOK = {"answer": 0.35, "check": 0.15, "judge": 0.06}
CLI_CAP = {"answer": 0.25, "check": 0.10, "judge": 0.05}
JUDGE_SLOTS, S_PROBES_AFTER_FIRST, S_LISTS, MAX_S_QUERIES = 15, 4, 40, 12
PAUSE_DAYS, PAUSE_CHECK_S = 7, 1800
EPS = 1e-9
# The design's historical-rate proxy table (section 6), per item, at b = .004.
PROXY = {"p1p2": 0.210, "p1s": 0.004, "answers": 7.804, "s_adaptive": 0.480, "s_probes": 0.020, "judge": 0.450, "s_lists": 0.160}
HARD_REASONS = {"pre_g6", "g5_failed", "g6_failed", "first_four_failure", "lock_changed", "forbidden_read", "egress",
                "secret_output", "overrun", "unsettled", "unknown_spend", "integrity", "skip_ceiling",
                "insufficient_common_cohort", "unclassified", "security_probe_failure"}
FINALIZE_REASONS = {"capacity_refused", "usage_expired", "benign_probe_failure", "auth_refused", "readiness_refused"}


def H(b):
    return 0.90 + 44 * b


def btriple(b):
    return 3 * BOOK["answer"] + MAX_S_QUERIES * b


def scenario(mult=1.0):
    """The section 6 planning arithmetic (P16): totals, the G6 projection and the minimum cap."""
    b = B_MIN * mult
    total = round(sum(PROXY.values()) * mult, 3)
    A = round((PROXY["p1p2"] + PROXY["p1s"] + PROXY["s_probes"] / 5) * mult, 3)
    p = round((PROXY["answers"] + PROXY["s_adaptive"]) / 40 * mult, 4)
    projection = round(A + 40 * p + H(b), 3)
    return {"b": b, "H": round(H(b), 3), "Btriple": round(btriple(b), 3), "A": A, "p": p, "total": total,
            "projection": projection, "min_cap": round(projection + btriple(b), 3),
            "headroom_25": round(CAP_PILOT - btriple(b) - projection, 3)}


def g6_ok(spent, p, remaining_h, b, cap=CAP_PILOT):
    return spent + 36 * p + remaining_h <= cap - btriple(b) + EPS


class Refused(Exception):
    pass


class Ledger:
    def __init__(self, path, cap=CAP_PILOT, b=B_MIN):
        self.path, self.cap = path, cap
        self.spent, self.b = 0.0, b
        self.inflight, self.unsettled, self.reserves = {}, {}, {}
        self.s_interval = {}           # attempt -> booking, S queries admitted since the last settle
        self.usage_pause_deadline = None
        self.stop = None               # {"kind": HARD_STOP|FINALIZE_ONLY, "reason": ...}
        self.events = []
        self.triples = {}              # task -> {"arms": {arm: status}, "state": admitted|done}
        if os.path.exists(path):
            with open(path) as f:
                for line in f:
                    if line.strip():
                        self._apply(json.loads(line))

    def _log(self, ev):
        ev = dict(ev, seq=len(self.events))
        fd = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        try:
            os.write(fd, (json.dumps(ev, sort_keys=True) + "\n").encode())
            os.fsync(fd)
        finally:
            os.close(fd)
        self._apply(ev)
        return ev

    def _apply(self, ev):
        self.events.append(ev)
        k = ev["ev"]
        if k == "admit_triple":     # one durable event: both reservations and the admission, or nothing
            t = ev["task"]
            for name, amount in (("triple:%s:answers" % t, ev["answers"]), ("triple:%s:search" % t, ev["search"])):
                self.reserves[name] = self.reserves.get(name, 0.0) + amount
            self.triples.setdefault(t, {"arms": {}, "state": "admitted"})
        elif k == "reserve":
            self.reserves[ev["name"]] = self.reserves.get(ev["name"], 0.0) + ev["amount"]
        elif k == "release":
            self.reserves[ev["name"]] = max(0.0, self.reserves.get(ev["name"], 0.0) - ev["amount"])
            if self.reserves[ev["name"]] <= EPS:
                self.reserves.pop(ev["name"])
        elif k == "book":
            if ev.get("from"):
                self.reserves[ev["from"]] = max(0.0, self.reserves.get(ev["from"], 0.0) - ev["amount"])
                if self.reserves[ev["from"]] <= EPS:
                    self.reserves.pop(ev["from"])
            if ev["kind"] == "s_query":
                self.s_interval[ev["attempt"]] = ev["amount"]
            else:
                self.inflight[ev["attempt"]] = {"kind": ev["kind"], "amount": ev["amount"]}
        elif k == "settle":
            self.inflight.pop(ev["attempt"], None)
            self.unsettled.pop(ev["attempt"], None)
            self.spent += ev["actual"]
        elif k == "unsettled":
            item = self.inflight.pop(ev["attempt"], None)
            self.unsettled[ev["attempt"]] = item["amount"] if item else ev.get("amount", 0.0)
        elif k == "s_settle":
            for a in ev["attempts"]:
                self.s_interval.pop(a, None)
            self.spent += ev["delta"]
        elif k == "reprice":
            self.b = ev["b"]
        elif k == "pause_deadline":
            self.usage_pause_deadline = ev["deadline"]
        elif k == "stop":
            if self.stop is None or (self.stop["kind"] == "FINALIZE_ONLY" and ev["kind"] == "HARD_STOP"):
                self.stop = {"kind": ev["kind"], "reason": ev["reason"]}
        elif k == "triple":
            t = self.triples.setdefault(ev["task"], {"arms": {}, "state": "admitted"})
            if "arm" in ev:
                t["arms"][ev["arm"]] = ev["status"]
            if ev.get("state"):
                t["state"] = ev["state"]

    def committed(self):
        return (self.spent + sum(i["amount"] for i in self.inflight.values()) + sum(self.unsettled.values())
                + sum(self.s_interval.values()) + sum(self.reserves.values()))

    def can_fit(self, amount):
        return self.committed() + amount <= self.cap + EPS

    def blocked(self):
        return bool(self.unsettled) or (self.stop is not None and self.stop["kind"] == "HARD_STOP")

    def reserve(self, name, amount):
        if not self.can_fit(amount):
            raise Refused("capacity: %s needs %.4f, %.4f committed of %.2f" % (name, amount, self.committed(), self.cap))
        self._log({"ev": "reserve", "name": name, "amount": amount})

    def reserve_h(self):
        self.reserve("judge", JUDGE_SLOTS * BOOK["judge"])
        self.reserve("probes", S_PROBES_AFTER_FIRST * self.b)
        self.reserve("lists", S_LISTS * self.b)

    def remaining_h(self):
        return sum(self.reserves.get(n, 0.0) for n in ("judge", "probes", "lists"))

    def admit_triple(self, task):
        """Atomic: the whole Btriple fits beside everything committed, or nothing is reserved."""
        if self.blocked():
            return False
        need = btriple(self.b)
        if not self.can_fit(need):
            return False
        self._log({"ev": "admit_triple", "task": task, "answers": 3 * BOOK["answer"], "search": MAX_S_QUERIES * self.b})
        return True

    def book(self, attempt, kind, amount, from_reserve=None, incurred=False):
        """Durably book a paid operation BEFORE it launches. Draws on its own reservation.
        incurred=True records work that already ran (the S queries of a finished session): it is
        booked even after a stop, because the exposure exists whatever the stop state."""
        if self.blocked() and not incurred:
            raise Refused("paid work is blocked: %s" % (self.stop or "unsettled exposure"))
        have = self.reserves.get(from_reserve, 0.0) if from_reserve else 0.0
        if have + EPS < amount and not incurred and not self.can_fit(amount - have):
            raise Refused("capacity: %s %s needs %.4f" % (kind, attempt, amount))
        return self._log({"ev": "book", "attempt": attempt, "kind": kind, "amount": amount,
                          "from": from_reserve if have > EPS else None})

    def settle(self, attempt, actual):
        item = self.inflight.get(attempt) or ({"amount": self.unsettled[attempt]} if attempt in self.unsettled else None)
        if item is None:
            raise Refused("settle of an unknown attempt %s" % attempt)
        if not isinstance(actual, (int, float)) or isinstance(actual, bool) or not math.isfinite(actual) or actual < 0:
            if attempt in self.inflight:
                self._log({"ev": "unsettled", "attempt": attempt, "why": "invalid cost evidence"})
            self.halt("HARD_STOP", "unsettled")
            return False
        self._log({"ev": "settle", "attempt": attempt, "actual": actual})
        if actual > item["amount"] + EPS:
            self.halt("HARD_STOP", "overrun")
            return False
        return True

    def killed(self, attempt, usage_cost=None, usage_complete=False):
        """A killed/crashed in-flight call: settles only from complete trusted usage, never replayed."""
        if usage_complete and usage_cost is not None:
            return self.settle(attempt, usage_cost)
        self._log({"ev": "unsettled", "attempt": attempt})
        self.halt("HARD_STOP", "unsettled")
        return False

    def release(self, name, amount=None):
        have = self.reserves.get(name, 0.0)
        amt = have if amount is None else min(amount, have)
        if amt > EPS:
            self._log({"ev": "release", "name": name, "amount": amt})

    def book_s_queries(self, attempt_prefix, n, from_reserve):
        for i in range(n):
            self.book("%s-q%02d" % (attempt_prefix, i + 1), "s_query", self.b, from_reserve, incurred=True)

    def last_meter(self):
        """The key meter reading of the last settled interval (durable across a restart)."""
        for e in reversed(self.events):
            if e["ev"] == "s_settle" and e.get("meter") is not None:
                return e["meter"]
        return None

    def settle_s_interval(self, delta, invocations, meter=None):
        """Settle the dedicated key's cash delta for the admitted S invocations of the interval,
        then reprice. Returns False on a HARD_STOP (overrun or unexplained usage)."""
        if not isinstance(delta, (int, float)) or not math.isfinite(delta) or delta < 0:
            self.halt("HARD_STOP", "unknown_spend")   # a negative delta is a meter reset, never a refund
            return False
        attempts = sorted(self.s_interval)
        booked = sum(self.s_interval.values())
        self._log({"ev": "s_settle", "attempts": attempts, "delta": delta, "invocations": invocations, "booked": booked, "meter": meter})
        if invocations == 0:
            if delta > EPS:
                self.halt("HARD_STOP", "unknown_spend")
                return False
            return True
        if delta > booked + EPS:
            self.halt("HARD_STOP", "overrun")
            return False
        self.reprice(max(self.b, B_MIN, 1.5 * delta / invocations))
        return True

    def reprice(self, new_b):
        if new_b <= self.b + EPS:
            return
        old = self.b
        self._log({"ev": "reprice", "b": new_b, "old": old})
        for name in ("probes", "lists"):
            have = self.reserves.get(name, 0.0)
            if have > EPS:
                left = round(have / old)
                extra = left * (new_b - old)
                if self.can_fit(extra):
                    self._log({"ev": "reserve", "name": name, "amount": extra})
                elif name == "lists":
                    self.release("lists")
                    self._log({"ev": "lists_cancelled", "reason": "unaffordable after repricing"})
                else:
                    self.release(name)
                    self._log({"ev": "probes_cancelled", "reason": "unaffordable after repricing"})

    def lists_cancelled(self):
        return any(e["ev"] == "lists_cancelled" for e in self.events)

    def usage_refused(self, now):
        if self.usage_pause_deadline is None:
            self._log({"ev": "pause_deadline", "deadline": now + PAUSE_DAYS * 86400})
        return self.usage_pause_deadline

    def halt(self, kind, reason):
        if kind == "HARD_STOP" and reason not in HARD_REASONS:
            reason = "unclassified"
        if kind == "FINALIZE_ONLY" and reason not in FINALIZE_REASONS:
            kind, reason = "HARD_STOP", "unclassified"
        self._log({"ev": "stop", "kind": kind, "reason": reason})

    def triple_event(self, task, **kw):
        self._log(dict({"ev": "triple", "task": task}, **kw))


class ListBooking:
    """The matched-lists S-mode adapter over the run ledger: each fixed S query books b from
    the reserved list capacity; a refusal (or cancelled lists) stops the list."""

    def __init__(self, ledger):
        self.ledger = ledger
        self.n = 0

    def reserve(self, task_id):
        if self.ledger.lists_cancelled() or self.ledger.reserves.get("lists", 0.0) + EPS < self.ledger.b:
            return None
        self.n += 1
        attempt = "list-%s" % task_id
        try:
            self.ledger.book(attempt, "s_query", self.ledger.b, "lists")
        except Refused:
            return None
        return attempt

    def local(self, task_id):
        return "local-%s" % task_id

    def settle(self, booking, status):
        pass   # S query cash settles per interval (settle_s_interval), never per query


def now():
    return time.time()
