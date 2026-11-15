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
* The first key-meter reading (meter_start) is durable and taken before the first S booking.
* Noise allowance (design r20, shared-credentials only): the run's first event names a pre-run
  meter baseline (rate, USD/s). For an interval of t seconds, A(t) = 3 x rate x t + .001; an
  excess over the interval's bookings up to A(t) is absorbed from the reserved `noise` cap
  ($.50 in R8, $.05 in R5) instead of stopping. The full delta is always spent; b is repriced
  net of the expected noise E(t) = min(delta, rate x t). Without a baseline the allowance is 0.

The stop classifier lives here too (D1): HARD_STOP dominates FINALIZE_ONLY; nothing in this
file reads an answer score.
"""
import collections, hashlib, json, math, os, time

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
NOISE_CAP_R8, NOISE_CAP_R5 = 0.50, 0.05
NOISE_FACTOR, NOISE_FLOOR = 3.0, 0.001
BASELINE_WINDOW = (600, 1800)
BASELINE_MAX_AGE = 7200
BASELINE_READ_SLACK = 60
BASELINE_KEYS = ("start_meter", "end_meter", "start_ts", "end_ts", "window_s", "key_fingerprint", "rate")


def allowance(rate, t):
    return NOISE_FACTOR * rate * t + NOISE_FLOOR


Absorbed = collections.namedtuple("Absorbed", "allowance expected_noise absorbed")


def absorb(delta, booked, rate, t, left):
    a = allowance(rate, t)
    return Absorbed(a, min(delta, rate * t), max(0.0, min(max(0.0, delta - booked), a, left)))


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def baseline_problems(b, cap):
    if not isinstance(b, dict) or not all(k in b for k in BASELINE_KEYS) or not all(_num(b[k]) for k in BASELINE_KEYS if k != "key_fingerprint"):
        return ["the noise baseline is unreadable or malformed"]
    bad = []
    if not BASELINE_WINDOW[0] <= b["window_s"] <= BASELINE_WINDOW[1]:
        bad.append("the noise baseline window %s s is outside %d to %d s" % (b["window_s"], BASELINE_WINDOW[0], BASELINE_WINDOW[1]))
    if b["rate"] < 0 or b["end_meter"] < b["start_meter"]:
        bad.append("the noise baseline has a negative delta")
    elif (abs(b["rate"] * b["window_s"] - (b["end_meter"] - b["start_meter"])) > 1e-9
          or not 0 <= (b["end_ts"] - b["start_ts"]) - b["window_s"] <= BASELINE_READ_SLACK):
        bad.append("the noise baseline is inconsistent: its rate or timestamps do not describe its window")
    dur = b.get("expected_duration_s")
    if not _num(dur) or dur <= 0:
        bad.append("no expected run duration is stated")
    elif NOISE_FACTOR * b["rate"] * dur > cap + EPS:
        bad.append("the fleet is too noisy for this run: 3 x rate x %ss exceeds the $%.2f noise cap; lower it and take a new baseline" % (dur, cap))
    return bad


def baseline_age_problems(b, now):
    if now - b["end_ts"] > BASELINE_MAX_AGE:
        return ["the noise baseline ended more than 2 hours before the run's start"]
    if b["end_ts"] > now:
        return ["the noise baseline ends after the run's start"]
    return []


def load_baseline(stance, path, key_fingerprint, expected_duration, cap):
    if stance != "shared-credentials":
        return None, (["noise: a noise baseline is given under the legacy stance %s" % stance] if path else [])
    if not path:
        return None, ["noise: shared-credentials needs a noise baseline"]
    try:
        with open(path, "rb") as f:
            raw = f.read()
        b = json.loads(raw)
    except (OSError, ValueError):
        return None, ["noise: the noise baseline is unreadable or malformed"]
    bad = ["noise: " + x for x in baseline_problems(dict(b, expected_duration_s=expected_duration) if isinstance(b, dict) else b, cap)]
    if not bad and b["key_fingerprint"] != key_fingerprint:
        bad.append("noise: the noise baseline was taken on another key")
    if bad:
        return None, bad
    return dict(b, path=path, sha256=hashlib.sha256(raw).hexdigest(), expected_duration_s=expected_duration), []


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
        self.s_interval = {}
        self.usage_pause_deadline = None
        self.noise_rate, self.noise_absorbed, self.noise_expected = None, 0.0, 0.0
        self.reading = None
        self.stop = None
        self.events = []
        self.triples = {}
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
        if k == "admit_triple":
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
            if ev.get("absorbed"):
                self.reserves["noise"] = max(0.0, self.reserves.get("noise", 0.0) - ev["absorbed"])
                if self.reserves["noise"] <= EPS:
                    self.reserves.pop("noise")
                self.noise_absorbed += ev["absorbed"]
            self.noise_expected += ev.get("expected_noise") or 0.0
            if ev.get("meter") is not None:
                self.reading = (ev["meter"], ev.get("ts"))
        elif k == "meter_start":
            self.reading = (ev["meter"], ev["ts"])
        elif k == "noise_baseline":
            self.noise_rate = ev["rate"]
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

    def noise_start(self, path, sha256, rate, ts):
        self._log({"ev": "noise_baseline", "path": path, "sha256": sha256, "rate": rate, "ts": ts})

    def noise_baseline_event(self):
        return next((e for e in self.events if e["ev"] == "noise_baseline"), None)

    def meter_start(self, meter, ts):
        self._log({"ev": "meter_start", "meter": meter, "ts": ts})

    def last_meter(self):
        return self.reading[0] if self.reading else None

    def settle_s_interval(self, delta, invocations, meter=None, ts=None):
        """Settle the key's cash delta for the admitted S invocations of the interval, absorbing
        fleet noise within the allowance when the run has a noise baseline, then reprice. Returns
        False on a HARD_STOP (overrun or unexplained usage)."""
        if not isinstance(delta, (int, float)) or not math.isfinite(delta) or delta < 0:
            self.halt("HARD_STOP", "unknown_spend")
            return False
        attempts = sorted(self.s_interval)
        booked = sum(self.s_interval.values())
        ev = {"ev": "s_settle", "attempts": attempts, "delta": delta, "invocations": invocations, "booked": booked, "meter": meter}
        absorbed = expected = 0.0
        if ts is not None:
            ev["ts"] = ts
        if self.noise_rate is not None and ts is not None and self.reading and self.reading[1] is not None:
            t = max(0.0, ts - self.reading[1])
            a, expected, absorbed = absorb(delta, booked, self.noise_rate, t, self.reserves.get("noise", 0.0))
            ev.update(t=t, allowance=a, expected_noise=expected, absorbed=absorbed, absorbed_total=self.noise_absorbed + absorbed)
        self._log(ev)
        if invocations == 0:
            if delta - absorbed > EPS:
                self.halt("HARD_STOP", "unknown_spend")
                return False
            return True
        if delta - absorbed > booked + EPS:
            self.halt("HARD_STOP", "overrun")
            return False
        self.reprice(max(self.b, B_MIN, 1.5 * (delta - expected) / invocations))
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
        pass


def now():
    return time.time()
