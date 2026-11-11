#!/usr/bin/env python3
"""scripts/eval/worker-digest/worker_ledger.py - the worker ledgers writer (HIMMEL-4670 P2).

Turns one P1 digest (worker-digest.ts) into two ledger writes, then a marker:
  1. one worker-failures row per digest failures row (registered in
     scripts/observability/ledgers.json as `worker-failures`);
  2. one eval-runs row with eval "leg-trajectory" and meta.observational
     true (spec 3.1: a series, never a regression verdict);
  3. the digest itself at <state-dir>/<session>.json, LAST, as the commit marker.

  Path: $HIMMEL_WORKER_SESSION_FAILURES_LEDGER, else ~/.himmel/leg-failures.jsonl.

WORKER-FAILURES ROW (v 1) -- closed-list categories, plus on a denied row one redacted refusal line:
  v, ts, host, source, kind "leg-failure"       registry envelope
  session     the worker's session uuid
  worker, chief, ticket, pr                      who the row belongs to, or null
  agent       {id, role, kind, model} from the digest
  class       "<failure>/<sub>", the digest's closed-list class
  failure     denied | suite | blocked | error | run_error | traj
  count, identical_retry, recovered, first_ts, last_ts
  tool_call_ids  at most five tool-call ids
  final_red   suite rows only
  refusal_line  denied rows only, optional: the guard's already-redacted first refusal line from the
              hook-chain log (the first refused call that has one), at most 240 code points on one line,
              or null when none was recorded; older rows lack the key
  meta        optional, refreshed rows only: {digest_id, refreshed_at} -- the generation that wrote the row and when
              the refresh ran; ts stays the original record time
Unknown keys are refused, but refusal_line is free text: it is redacted for secrets only and can still echo
command or path text. It stays on this host (the ledger, the marker and the leg-digest state file are never sent);
the egress guard is the failure router's named-field pick and its check_body alphabet check, which never take it.
A salus-rooted session records no refusal_line (its chain log is not the himmel one); a session whose cwd is a
himmel checkout but that names a salus path stays local, in the ledger and the marker, and is never sent.

IDEMPOTENCE (spec 5.3), all under a per-session flock at <state-dir>/<session>.lock:
  marker present with status ok          -> append nothing
  marker non-ok, new digest non-ok       -> append nothing
  an ok digest over a non-ok marker replaces the session's worker-failures rows (a partial
  digest's stale classes and counts go, other sessions' rows stay; HIMMEL-4701);
  otherwise append only the worker-failures rows missing by (session, agent.id, class)
  and the eval-runs row unless an ok one, or one of a non-ok status beside a
  non-ok digest, is already there; then rewrite the marker.

  worker_ledger.py record --digest F [--worker N --ticket K --chief C --pr N --doc D --lane L]
                       [--digest-error timeout|crash|no-journal|bad-json|too-big]
                       [--failures-ledger P] [--eval-ledger P] [--state-dir D]
  worker_ledger.py backfill --since YYYY-MM-DD [--projects D] [--denials-ledger P] [--live-minutes N]
                       [--refresh] [--failures-ledger P] [--eval-ledger P] [--state-dir D]
  worker_ledger.py validate <worker-failures ledger>

backfill digests every main journal under --projects (default ~/.claude/projects only; a lane
config dir such as ~/.claude-codex/projects is not scanned) whose first timestamp is on or after
--since, worker-titled or not, through `bun worker-digest.ts`. The state dir defaults to
$WORKER_SESSION_DIGEST_STATE_DIR, else ~/.himmel/state/leg-digest. It reads the
journals only, and refuses one whose cwd sits under a salus root (spec 6.1).
It skips a journal whose last timestamp is under --live-minutes (default 30) old:
an ok digest of a still-live session would write the final marker and freeze the
worker before its remaining failures land (HIMMEL-4699).

PAIRED SNAPSHOT. Every eval-runs row carries meta.digest_id (a hash of the measurement: the digest's counts,
classes, meaning versions and stamped attribution; never a write time or the recorder's checkout) and
meta.tool_failures (the session's failure rows without refusal text). Tool health reads that pair, so the
failures it shows always belong to the eval row it counts; a row without the field falls back to the ledger.

REFRESH (backfill --refresh) re-digests sessions already recorded ok, so a corrected classifier reaches old
sessions without moving them in time. It never runs on its own: no cadence calls it. Per session:
  - a digest that is not ok leaves the previous measurement untouched;
  - the marker already carrying the same digest_id is a no-op;
  - no ok eval row to anchor on: refused with a diagnostic, nothing written (refresh time is never
    substituted for a missing original time);
  - else, in this order: (1) the eval row, with the ORIGINAL ok row's ts, meta.refreshed_at = now and the
    new digest_id, skipped when the ledger already holds that run_id + digest_id; (2) the session's failure
    rows replaced, each keeping its own original ts (a new class takes the session's earliest failure time,
    else the eval anchor) and meta {digest_id, refreshed_at}; (3) the marker, carrying the digest_id.
    A crash after any step leaves a complete old or complete new snapshot for Tool health, and the
    next refresh finishes the remaining steps without a duplicate. The two JSONL files are not one atomic
    commit. Live sessions are skipped as in backfill.
  The refreshed rows keep the attribution of the session's current ok eval row (leg, ticket, pr, console, doc,
  profile, lane; the journal title fills only a field that row lacks) and its meta.cli_version and meta.effort,
  never the refreshing shell's. A run reads the eval ledger once and indexes the first and current ok row per session.
  Before a production refresh, preview the router with --dry-run against scratch copies; a refresh never
  changes the cadence mode.
"""

import argparse
import fcntl
import glob
import hashlib
import json
import os
import re
import socket
import subprocess
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

SOURCE = "scripts/eval/worker-digest/worker_ledger.py"
LEDGER_ENV = "HIMMEL_WORKER_SESSION_FAILURES_LEDGER"
EVAL_ID = "leg-trajectory"
METRICS = ("tool_calls", "subagents", "turns", "fail_denied", "fail_suite", "fail_blocked", "fail_error",
           "run_errors", "interrupts", "red_before_green", "denial_recovery", "identical_denied_retries",
           "verify_before_claim")
FAILURES = ("denied", "suite", "blocked", "error", "run_error", "traj")
KEYS = ("v", "ts", "host", "source", "kind", "session", "leg", "console", "ticket", "pr", "agent", "class",
        "failure", "count", "identical_retry", "recovered", "first_ts", "last_ts", "tool_call_ids")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SUB = re.compile(r"^[A-Za-z0-9._:+-]{1,80}$")
NAME = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
WORKER = re.compile(r"^N\d+[a-z]?$")
TICKET = re.compile(r"^[A-Z][A-Z0-9]+-\d+$")
CHIEF = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
MODEL = re.compile(r"^(claude|gpt|gemini|glm|codex|o\d)[a-z0-9.\-\[\]]{0,60}$", re.I)
TITLE = re.compile(r"^([A-Z][A-Z0-9]+-\d+)-(N\d+[a-z]?)-")
LINE_MAX = 240
NOT_PRINTABLE = re.compile("[\x00-\x1f\x7f-\x9f  ]")
DIGEST_TIMEOUT = 60
LIVE_MINUTES = 30
DIGEST_ERRORS = ("timeout", "crash", "no-journal", "bad-json", "too-big")
UTC_TS = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
DIGEST_ID = re.compile(r"^[0-9a-f]{32}$")
# Test seam only: stop a refresh after its eval or failures write, to replay the crash fixtures.
REFRESH_STOP_ENV = "HIMMEL_LEDGER_REFRESH_STOP_AFTER"



def ledger_path(path=None):
    return (path or os.environ.get(LEDGER_ENV)
            or os.path.expanduser("~/.himmel/leg-failures.jsonl"))


def default_state_dir():
    return os.environ.get("WORKER_SESSION_DIGEST_STATE_DIR") or os.path.expanduser("~/.himmel/state/leg-digest")


def _int(x, lo):
    return isinstance(x, int) and not isinstance(x, bool) and x >= lo


def _opt(x, rx):
    return x is None or (isinstance(x, str) and bool(rx.match(x)))


def validate(row):
    """List of problems; empty = a valid v1 worker-failures row."""
    if not isinstance(row, dict):
        return ["row is not an object"]
    extra = sorted(set(row) - set(KEYS) - {"final_red", "refusal_line", "meta"})
    p = ["unknown key %s" % k for k in extra] + ["missing %s" % k for k in KEYS if k not in row]
    if p:
        return p
    if row["v"] != 1:
        p.append("v must be 1")
    if row["kind"] != "leg-failure":
        p.append("kind must be leg-failure")
    for k in ("ts", "host", "source"):
        if not isinstance(row[k], str) or not row[k]:
            p.append("%s must be a non-empty string" % k)
    if not isinstance(row["session"], str) or not UUID.match(row["session"]):
        p.append("session must be a uuid")
    if not _opt(row["leg"], WORKER):
        p.append("worker must be N<digits> or null")
    if not _opt(row["ticket"], TICKET):
        p.append("ticket must be a ticket key or null")
    if not _opt(row["console"], CHIEF):
        p.append("chief must be a session name or null")
    if row["pr"] is not None and not _int(row["pr"], 1):
        p.append("pr must be a positive integer or null")
    a = row["agent"]
    if not isinstance(a, dict) or sorted(a) != ["id", "kind", "model", "role"]:
        p.append("agent must be exactly {id, role, kind, model}")
    elif not (_opt(a["id"], NAME) and a["id"] and _opt(a["role"], NAME) and a["role"]
              and _opt(a["kind"], NAME) and _opt(a["model"], MODEL)):
        p.append("agent fields must be closed-list names")
    if row["failure"] not in FAILURES:
        p.append("failure must be one of %s" % ", ".join(FAILURES))
    c = row["class"]
    if not isinstance(c, str) or "/" not in c:
        p.append("class must be <failure>/<sub>")
    else:
        head, _, sub = c.partition("/")
        if head != row["failure"]:
            p.append("class prefix must equal failure")
        if not SUB.match(sub):
            p.append("class sub must be a closed-list name")
    if not _int(row["count"], 1):
        p.append("count must be a positive integer")
    if row["identical_retry"] is not None and not _int(row["identical_retry"], 0):
        p.append("identical_retry must be a non-negative integer or null")
    if row["recovered"] is not None and not isinstance(row["recovered"], bool):
        p.append("recovered must be a boolean or null")
    for k in ("first_ts", "last_ts"):
        if row[k] is not None and not _int(row[k], 0):
            p.append("%s must be epoch milliseconds or null" % k)
    ids = row["tool_call_ids"]
    if not isinstance(ids, list) or len(ids) > 5 or not all(isinstance(i, str) and NAME.match(i) for i in ids):
        p.append("tool_call_ids must be at most five ids")
    if "final_red" in row and (row["failure"] != "suite" or not isinstance(row["final_red"], bool)):
        p.append("final_red is a boolean on suite rows only")
    if "refusal_line" in row:
        line = row["refusal_line"]
        if row["failure"] != "denied" or not (line is None or (
                isinstance(line, str) and 1 <= len(line) <= LINE_MAX and not NOT_PRINTABLE.search(line))):
            p.append("refusal_line is null or one line of 1 to %d code points, on denied rows only" % LINE_MAX)
    if "meta" in row:
        m = row["meta"]
        if (not isinstance(m, dict) or sorted(m) != ["digest_id", "refreshed_at"] or not isinstance(m["digest_id"], str)
                or not DIGEST_ID.match(m["digest_id"]) or not isinstance(m["refreshed_at"], str) or not UTC_TS.match(m["refreshed_at"])):
            p.append("meta is exactly {digest_id: 32 hex, refreshed_at: YYYY-MM-DDTHH:MM:SSZ}")
    return p


def validate_file(path):
    bad = 0
    try:
        fh = open(path, encoding="utf-8")
    except OSError as e:
        print("worker-failures: cannot read %s: %s" % (path, e), file=sys.stderr)
        return 1
    with fh:
        for nr, line in enumerate(fh, 1):
            if not line.strip():
                continue
            try:
                problems = validate(json.loads(line))
            except json.JSONDecodeError:
                problems = ["not JSON"]
            if problems:
                bad += 1
                print("%s:%d: %s" % (path, nr, "; ".join(problems)), file=sys.stderr)
    print("worker-failures: %s %s" % (path, "valid" if not bad else "%d bad row(s)" % bad))
    return 1 if bad else 0


def _ledger_lock(path, mode):
    """Held by every writer of the ledger: appends share it, a rewrite owns it, so a rewrite
    never drops a row another session appended meanwhile."""
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    lk = open(path + ".lock", "w")
    fcntl.flock(lk, mode)
    return lk


def _dump(r):
    return (json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _append(path, rows):
    if not rows:
        return
    with _ledger_lock(path, fcntl.LOCK_SH):
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            for r in rows:
                line = _dump(r)
                # One O_APPEND write per row, so concurrent writers never interleave a line.
                if os.write(fd, line) != len(line):
                    raise OSError("short write to %s; the last row may be torn" % path)
        finally:
            os.close(fd)


def _replace_session(path, session, rows):
    """Drop every row of this session from the ledger, then add rows, atomically."""
    with _ledger_lock(path, fcntl.LOCK_EX):
        tmp = path + ".tmp"
        with open(tmp, "wb") as out:
            try:
                fh = open(path, "rb")
            except FileNotFoundError:
                fh = None
            if fh:
                with fh:
                    for line in fh:
                        if session.encode() in line:
                            try:
                                r = json.loads(line)
                            except ValueError:
                                r = None
                            if isinstance(r, dict) and r.get("session") == session:
                                continue
                        out.write(line)
            for r in rows:
                out.write(_dump(r))
        os.replace(tmp, path)


def failure_keys(path, session):
    """(agent.id, class) of the rows this session already has."""
    keys = set()
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        return keys
    with fh:
        for line in fh:
            if session not in line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(r, dict) and r.get("session") == session and isinstance(r.get("agent"), dict):
                keys.add((r["agent"].get("id"), r.get("class")))
    return keys


def eval_statuses(path, session):
    rows, _, _ = eval_runs.scan_rows(path)
    return [r["status"] for r in rows if r["eval"] == EVAL_ID and r["run_id"] == session]


def _metrics(digest):
    m = digest.get("metrics") if isinstance(digest.get("metrics"), dict) else {}
    out = {}
    for k in METRICS:
        v = m.get(k)
        out[k] = (1 if v else 0) if isinstance(v, bool) else v if eval_runs._num(v) else None
    return out


def launch_lane(digest, who):
    """Only explicit launch provenance, never the model or the recorder's lane."""
    lanes = ("native", "claudex", "openrouter", "cloud", "unknown")
    raw = who.get("lane") or record_lane(who)
    doc = who.get("doc")
    if not raw and doc:
        path = doc if os.path.isabs(doc) else os.path.join(os.environ.get("HANDOVER_DIR", ""), doc)
        try:
            with open(path, encoding="utf-8") as fh:
                text = fh.read(65536)
            worker = who.get("leg")
            titles = [line for line in text.splitlines() if line.startswith("# ")
                      and (not worker or re.search(r"\b" + re.escape(worker) + r"\b", line))]
            text = titles[0] if titles else ""
            hit = re.search(r"\bWORKER_SESSION_LANE[=:]\s*(native|claudex|codex|openrouter|cloud)\b", text)
            hit = hit or re.search(r"\blane:\s*(native|claudex|codex|openrouter|cloud)\b", text)
            hit = hit or re.search(r"\b(native|claudex|codex|openrouter|cloud)\s+lane\b", text)
            hit = hit or re.search(r",\s*(native|claudex|codex|openrouter|cloud)\)", text)
            if hit:
                raw = hit.group(1)
        except OSError:
            pass
    raw = raw or digest.get("lane")
    if raw == "codex":
        raw = "claudex"
    return raw if raw in lanes else "unknown"


PROFILE = re.compile(r"^[a-z0-9][a-z0-9-]{0,40}$")
LAUNCH_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$")
LAUNCH_LINE = re.compile(r"^headed-arm-(?:worker|leg): profile=(\S+) ")
# a chief's launch line carries a role, no profile: the role is the profile
CHIEF_LINE = re.compile(r"^headed-arm: role=(chief|console) ")
LINE_LANE = re.compile(r"\blane=(native|claudex|codex|openrouter|cloud)\b")


LINE_SID = re.compile(r"\bsession_id=([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\b")
_SID_INDEX = {}


def _launch_dir():
    cache = os.environ.get("HIMMELCTL_CACHE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "himmel")
    return os.path.join(cache, "launch-logs")


def _sid_log(session):
    """The launch log whose line names this session id (the id the launcher passes to claude), else None.
    Read once per process and logs directory: a backfill asks for every session."""
    d = _launch_dir()
    if d not in _SID_INDEX:
        index = {}
        for p in sorted(glob.glob(os.path.join(d, "*.log"))):
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        m = LAUNCH_LINE.match(line) or CHIEF_LINE.match(line)
                        sid = m and LINE_SID.search(line)
                        if sid:
                            index.setdefault(sid.group(1), p)
            except OSError:
                continue
        _SID_INDEX.clear()
        _SID_INDEX[d] = index
    return _SID_INDEX[d].get(session)


def _read_launch_log(path):
    profiles, lanes = set(), set()
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            m = LAUNCH_LINE.match(line) or CHIEF_LINE.match(line)
            if not m:
                continue
            profiles.add(m.group(1))
            lane = LINE_LANE.search(line)
            if lane:
                lanes.add(lane.group(1))
    return profiles, lanes


def _launch_lines(who):
    """The launcher's per-session launch record as (profiles, lanes) seen across its lines, else None.
    The record is filed under the session name; a -RESUME doc's name is that name plus the suffix.
    Found by the launch name, else by the session id the launcher wrote, else by the doc's stem."""
    name = who.get("launch_name")
    if name and not LAUNCH_NAME.match(name):
        raise ValueError("launch name %r is not a session name" % name)
    d = _launch_dir()
    paths = []
    if name:
        paths += [os.path.join(d, stem + ".log") for stem in dict.fromkeys((name, re.sub(r"-RESUME$", "", name)))]

    def by_sid():
        # Scans every launch log once per process, so it runs only when the named paths found nothing.
        sid = _sid_log(who["session"]) if who.get("session") else None
        return [sid] if sid else []

    def by_doc():
        doc = who.get("doc")
        stem = re.sub(r"-RESUME$", "", re.sub(r"\.md$", "", os.path.basename(doc))) if doc else ""
        return [os.path.join(d, stem + ".log")] if LAUNCH_NAME.match(stem) else []

    for step in (lambda: paths, by_sid, by_doc):
        for p in step():
            try:
                return _read_launch_log(p)
            except OSError:
                continue
    return None


def launch_profile(who):
    """The profile a session was launched under, from the launcher's per-session launch record, else None.
    Never the recorder's own env: that describes the recorder, not the digested session.
    Launch lines that disagree (a refused duplicate of a live name) leave the session unattributed."""
    seen = (_launch_lines(who) or (set(), set()))[0]
    # the launcher writes profile=none when no profile was set: that is no attribution
    return next(iter(seen)) if len(seen) == 1 and PROFILE.match(next(iter(seen))) and next(iter(seen)) != "none" else None


def record_lane(who):
    """The lane the launch record names, else None; lines that disagree name none."""
    seen = (_launch_lines(who) or (set(), set()))[1]
    return next(iter(seen)) if len(seen) == 1 else None


def build_rows(digest, who):
    """(worker-failures rows, eval-runs row) for one digest; raises ValueError."""
    session = digest.get("session")
    if not isinstance(session, str) or not UUID.match(session):
        raise ValueError("digest session is not a uuid: the journal must be named <uuid>.jsonl")
    status = digest.get("status")
    if status not in eval_runs.STATUSES:
        raise ValueError("digest status %r is not one of %s" % (status, ", ".join(eval_runs.STATUSES)))
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    host = socket.gethostname()
    frows = []
    for f in digest.get("failures") or []:
        r = {"v": 1, "ts": now, "host": host, "source": SOURCE, "kind": "leg-failure", "session": session,
             "leg": who["leg"], "console": who["console"], "ticket": who["ticket"], "pr": who["pr"],
             "agent": f.get("agent"), "class": f.get("class"), "failure": f.get("failure"),
             "count": f.get("count"), "identical_retry": f.get("identical_retry"),
             "recovered": f.get("recovered"), "first_ts": f.get("first_ts"), "last_ts": f.get("last_ts"),
             "tool_call_ids": f.get("tool_call_ids")}
        if "final_red" in f:
            r["final_red"] = f["final_red"]
        if "refusal_line" in f:
            r["refusal_line"] = f["refusal_line"]
        problems = validate(r)
        if problems:
            raise ValueError("worker-failures row %s: %s" % (f.get("class"), "; ".join(problems)))
        frows.append(r)
    model = digest.get("model") if isinstance(digest.get("model"), str) else None
    config = {"digest_v": digest.get("digest_v"), "mapper_v": digest.get("mapper_v"),
              "trajectory_v": digest.get("trajectory_v"), "lane": who["lane"], "model": model}
    meta = {"leg": who["leg"], "doc": who["doc"], "ticket": who["ticket"], "pr": who["pr"],
            "console": who["console"], "observational": True}
    if who.get("backfill"):
        meta["backfill"] = True
    if who.get("digest_error"):
        meta["digest_error"] = who["digest_error"]
    # Launch metadata is authoritative; model names never determine the lane.
    who = dict(who, session=session)
    lane = launch_lane(digest, who)
    config["lane"] = lane
    # The launch record is authoritative for the profile, as it is for the lane.
    profile = who.get("profile") or launch_profile(who)
    if profile:
        meta["profile"] = profile
    # A session no launch record or doc names stays unknown, and says what kind of session it was.
    gap = None if profile or lane != "unknown" else who.get("kind") or "no-launch-record"
    if gap:
        meta["launch_gap"] = gap
    health = digest.get("tool_health")
    if isinstance(health, list):
        stamp = {"lane": lane, **({"profile": profile} if profile else {}), **({"launch_gap": gap} if gap else {})}
        meta["tool_health"] = [dict(r, **stamp) for r in health if isinstance(r, dict)]
        meta["started_ts"] = digest.get("started_ts")
    meta["digest_id"] = digest_id(digest, lane, meta)
    meta["tool_failures"] = [{k: r[k] for k in ("agent", "class", "failure", "count", "identical_retry", "recovered",
                                                "first_ts", "last_ts", "tool_call_ids", "final_red") if k in r} for r in frows]
    m = _metrics(digest)
    erow = eval_runs.make_row(EVAL_ID, SOURCE, config, m, n=m["turns"] if _int(m["turns"], 0) else None,
                              model=model, lane=lane, status=status, run_id=session,
                              artifact=os.path.join(who["state_dir"], session + ".json"), meta=meta,
                              repo=HERE)
    problems = eval_runs.validate(erow)
    if problems:
        raise ValueError("eval-runs row: %s" % "; ".join(problems))
    return frows, erow


def digest_id(digest, lane, meta):
    """The measurement's identity: counts, classes, meaning versions and stamped attribution. No write or
    refresh time and no recorder checkout, so the same measurement re-recorded keeps its id."""
    keep = ("digest_v", "mapper_v", "trajectory_v", "session", "status", "model", "metrics", "failures", "by_design")
    content = {k: digest.get(k) for k in keep}
    content["tool_health"] = meta.get("tool_health")
    content["attribution"] = {"lane": lane, "profile": meta.get("profile"), "launch_gap": meta.get("launch_gap")}
    text = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:32]


def _original_ok_ts(eval_ledger, session):
    rows, _, _ = eval_runs.scan_rows(eval_ledger)
    ok = [r for r in rows if r["eval"] == EVAL_ID and r["run_id"] == session and r["status"] == "ok"]
    ts = ok[0].get("ts") if ok else None
    return ts if isinstance(ts, str) and UTC_TS.match(ts) else None


class _OkIndex:
    """session -> (first ok row, current ok row) from ONE scan of the eval ledger; the current row is the newest ok one,
    as Tool health selects it. A refresh run builds this once instead of rereading the file for every session, and
    catch_up() reads only the bytes other writers appended since, so a session's row is never stale under its lock."""

    def __init__(self, eval_ledger):
        self.path = eval_runs.ledger_path(eval_ledger)
        # Sized before the scan: a row that lands during it is read twice, which changes nothing.
        self.size = os.path.getsize(self.path) if os.path.exists(self.path) else 0
        self.rows = {}
        self._take(eval_runs.scan_rows(self.path)[0])

    def _take(self, rows):
        for r in rows:
            if r["eval"] == EVAL_ID and r["status"] == "ok":
                self.rows[r["run_id"]] = (self.rows.get(r["run_id"], (r,))[0], r)

    def get(self, session):
        return self.rows.get(session, (None, None))

    def catch_up(self):
        try:
            with open(self.path, "rb") as fh:
                fh.seek(self.size)
                tail = fh.read()
        except FileNotFoundError:
            return
        # Whole lines only: a row another writer is still appending is read on the next call.
        tail = tail[:tail.rfind(b"\n") + 1]
        self.size += len(tail)
        for line in tail.splitlines():
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not eval_runs.validate(r):
                self._take([r])


def _anchored_who(who, current):
    """who with the session's current ok eval row's attribution laid over the title-derived one: the title is a
    fallback only for a field the row has no value for. An unknown lane is no value (a launch record may name it now)."""
    if current is None:
        return who
    meta = current.get("meta") or {}
    kept = {k: meta[k] for k in ("leg", "ticket", "pr", "console", "doc") if meta.get(k) is not None}
    if isinstance(meta.get("profile"), str) and PROFILE.match(meta["profile"]):
        kept["profile"] = meta["profile"]
    if current.get("lane") not in (None, "unknown"):
        kept["lane"] = current["lane"]
    return dict(who, **kept)


def _write_marker(marker, digest, erow):
    tmp = marker + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        saved = dict(digest, lane=erow["lane"], digest_id=erow["meta"].get("digest_id"))
        if "tool_health" in erow["meta"]:
            saved["tool_health"] = erow["meta"]["tool_health"]
        json.dump(saved, fh, ensure_ascii=False, separators=(",", ":"))
    os.replace(tmp, marker)


def _launch_gained(eval_ledger, erow):
    """True when the session's newest ok row has an unknown lane (or no profile) that this row now names."""
    rows, _, _ = eval_runs.scan_rows(eval_ledger)
    old = [r for r in rows if r["eval"] == EVAL_ID and r["run_id"] == erow["run_id"] and r["status"] == "ok"]
    if not old:
        return False
    old = old[-1]
    return ((old.get("lane") == "unknown" and erow["lane"] != "unknown")
            or (not (old.get("meta") or {}).get("profile") and bool(erow["meta"].get("profile"))))


def record(digest, who, failures_ledger, eval_ledger):
    """Write one digest under its session lock; returns (failures added, eval rows added)."""
    frows, erow = build_rows(digest, who)
    session, status, state = erow["run_id"], erow["status"], who["state_dir"]
    os.makedirs(state, exist_ok=True)
    marker = os.path.join(state, session + ".json")
    with open(os.path.join(state, session + ".lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        try:
            with open(marker, encoding="utf-8") as fh:
                prev = json.load(fh).get("status")
        except (OSError, ValueError, AttributeError):
            prev = None
        if prev == "ok" and status == "ok" and _launch_gained(eval_ledger, erow):
            # The launch record arrived after the first record: the same digest, now with its lane and profile.
            # The restamped row keeps the original record time, so it never moves the session in time.
            erow["ts"] = _original_ok_ts(eval_ledger, session) or erow["ts"]
            eval_runs.append_row(erow, eval_ledger)
            _write_marker(marker, digest, erow)
            return 0, 1
        if prev == "ok" or (prev is not None and status != "ok"):
            return 0, 0
        if status == "ok" and prev is not None:
            # A non-ok digest left rows the ok one may no longer have, or with other counts:
            # replace the session's rows so readers see only the final digest.
            add = frows
            _replace_session(failures_ledger, session, add)
        else:
            have = failure_keys(failures_ledger, session)
            add = [r for r in frows if (r["agent"]["id"], r["class"]) not in have]
            _append(failures_ledger, add)
        seen = eval_statuses(eval_ledger, session)
        e = 0
        if not ("ok" in seen or (seen and status != "ok")):
            eval_runs.append_row(erow, eval_ledger)
            e = 1
        _write_marker(marker, digest, erow)
        return len(add), e


def _stop_after(step):
    if os.environ.get(REFRESH_STOP_ENV) == step:
        raise SystemExit(75)


def _old_failure_ts(path, session):
    by, first = {}, None
    try:
        fh = open(path, encoding="utf-8")
    except FileNotFoundError:
        return by, first
    with fh:
        for line in fh:
            if session not in line:
                continue
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if not (isinstance(r, dict) and r.get("session") == session and isinstance(r.get("agent"), dict)):
                continue
            ts = r.get("ts")
            if isinstance(ts, str) and UTC_TS.match(ts):
                by.setdefault((r["agent"].get("id"), r.get("class")), ts)
                first = ts if first is None or ts < first else first
    return by, first


def refresh(digest, who, failures_ledger, eval_ledger, index=None):
    """index: _OkIndex(eval_ledger), built once per backfill run; None scans the ledger for this one call."""
    if digest.get("status") != "ok":
        return "inconclusive"
    if index is None:
        index = _OkIndex(eval_ledger)
    current = index.get(digest.get("session"))[1]
    frows, erow = build_rows(digest, _anchored_who(who, current))
    session, did, state = erow["run_id"], erow["meta"]["digest_id"], who["state_dir"]
    marker = os.path.join(state, session + ".json")
    with open(os.path.join(state, session + ".lock"), "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        index.catch_up()
        if index.get(session)[1] != current:
            # Another writer appended this session's row while this one waited: its attribution is the current one.
            current = index.get(session)[1]
            frows, erow = build_rows(digest, _anchored_who(who, current))
            did = erow["meta"]["digest_id"]
        first = index.get(session)[0]
        try:
            with open(marker, encoding="utf-8") as fh:
                if json.load(fh).get("digest_id") == did:
                    return "unchanged"
        except (OSError, ValueError, AttributeError):
            pass
        anchor = first.get("ts") if first else None
        if not (isinstance(anchor, str) and UTC_TS.match(anchor)):
            print("refresh: %s refused: no original ok eval row to keep its time" % session, file=sys.stderr)
            return "refused"
        # Only the session's CURRENT row counts (the newest ok one, as Tool health selects it): a generation that came
        # back after another (A, B, A) must be appended again, or the selected row would stay B.
        same = [current] if (current.get("meta") or {}).get("digest_id") == did else []
        # The version and effort are the original run's, not the refreshing shell's, whatever make_row stamped.
        erow["meta"]["cli_version"] = (current.get("meta") or {}).get("cli_version")
        erow["meta"]["effort"] = (current.get("meta") or {}).get("effort")
        # A replay after a crash reuses the generation's own refresh time, so the rows it rewrites come out identical.
        was = (same[-1].get("meta") or {}).get("refreshed_at") if same else None
        now = was if isinstance(was, str) and UTC_TS.match(was) else datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        erow["ts"] = anchor
        erow["meta"]["refreshed_at"] = now
        problems = eval_runs.validate(erow)
        if problems:
            raise ValueError("eval-runs row: %s" % "; ".join(problems))
        if not same:
            eval_runs.append_row(erow, eval_ledger)
        _stop_after("eval")
        old, first = _old_failure_ts(failures_ledger, session)
        for r in frows:
            r["ts"] = old.get((r["agent"]["id"], r["class"]), first or anchor)
            r["meta"] = {"digest_id": did, "refreshed_at": now}
            problems = validate(r)
            if problems:
                raise ValueError("worker-failures row %s: %s" % (r["class"], "; ".join(problems)))
        _replace_session(failures_ledger, session, frows)
        _stop_after("failures")
        _write_marker(marker, digest, erow)
        return "refreshed"


# --- backfill ------------------------------------------------------------------

def _roots(name):
    try:
        with open(os.path.expanduser("~/.config/claude-glm/" + name), encoding="utf-8") as fh:
            return [os.path.realpath(os.path.expanduser(l.strip())) for l in fh
                    if l.strip() and not l.lstrip().startswith("#")]
    except FileNotFoundError:
        return []  # absent = no listed roots; any other read error raises (fail closed)


def salus_rooted(cwd, roots):
    """True when cwd has a .salus marker on any ancestor or lies under a listed PHI root,
    or when there is no cwd to test (fail closed).
    ponytail: a minimal re-implementation of graphify-fence.sh's salus test (a hook, not
    sourceable), upgrade path: share one primitive when a second reader needs it."""
    if not cwd:
        return True
    p = os.path.realpath(cwd)
    for r in roots:
        if p == r or p.startswith(r.rstrip("/") + "/"):
            return True
    while True:
        if os.path.exists(os.path.join(p, ".salus")):
            return True
        up = os.path.dirname(p)
        if up == p:
            return False
        p = up


def journal_head(path, limit=40):
    """(title, first timestamp, cwd): the LAST title in the whole journal (a rename lands late),
    the first timestamp and cwd from its first lines. Streams; never holds the file."""
    title = ts = cwd = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for i, line in enumerate(fh):
            if i >= limit and "customTitle" not in line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(r, dict):
                continue
            if isinstance(r.get("customTitle"), str):
                title = r["customTitle"]
            if i < limit and ts is None and isinstance(r.get("timestamp"), str):
                ts = r["timestamp"]
            if i < limit and cwd is None and isinstance(r.get("cwd"), str):
                cwd = r["cwd"]
    return title, ts, cwd


def journal_last_ts(path, tail=65536):
    """Epoch seconds of the journal's last timestamped entry, else its mtime."""
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        fh.seek(max(0, fh.tell() - tail))
        lines = fh.read().decode("utf-8", errors="replace").splitlines()
    for line in reversed(lines):
        try:
            ts = json.loads(line)["timestamp"]
            return datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
        except (ValueError, TypeError, KeyError):
            continue
    return os.path.getmtime(path)


def run_digest(journal, session, denials):
    cmd = ["bun", os.path.join(HERE, "worker-digest.ts"), "--transcript", journal]
    if denials:
        cmd += ["--denials-ledger", denials]
    try:
        # Backfill's launcher is not the historical worker's launcher.
        r = subprocess.run(cmd, capture_output=True, timeout=DIGEST_TIMEOUT, check=False,
                           env=dict(os.environ, WORKER_SESSION_LANE="unknown"))
        if r.returncode == 0:
            return json.loads(r.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return {"digest_v": 1, "mapper_v": 1, "trajectory_v": None, "session": session, "status": "inconclusive",
            "model": None, "metrics": {}, "failures": []}


def session_kind(title):
    """What kind of session a backfilled journal was, from its title: the title's leading words, else a worker
    title reads worker. Names the share no launch record covers; never decides a lane."""
    if TITLE.match(title or ""):
        return "worker"
    m = re.match(r"[A-Za-z]+(?:-[A-Za-z]+)*", title or "")
    kind = m.group(0).lower()[:40].strip("-") if m else ""
    return kind if PROFILE.match(kind) else "untitled"


def backfill(a):
    since = datetime.strptime(a.since, "%Y-%m-%d").replace(tzinfo=timezone.utc)
    roots = _roots("phi-roots") + _roots("egress-denylist")
    live_cut = datetime.now(timezone.utc).timestamp() - a.live_minutes * 60
    n = workers = others = salus = done = live = fa = ea = restamped = 0
    words = {"refreshed": 0, "unchanged": 0, "refused": 0, "inconclusive": 0}
    index = _OkIndex(a.eval_ledger) if getattr(a, "refresh", False) else None
    for j in sorted(glob.glob(os.path.join(a.projects, "*", "*.jsonl"))):
        session = os.path.basename(j)[:-len(".jsonl")]
        if not UUID.match(session) or os.path.getmtime(j) < since.timestamp():
            continue
        title, ts, cwd = journal_head(j)
        try:
            when = datetime.strptime(ts[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except (TypeError, ValueError):
            continue
        if when < since:
            continue
        n += 1
        m = TITLE.match(title or "")
        if salus_rooted(cwd, roots):
            salus += 1
            continue
        # A chief, judge or interactive session has no worker title but its tool calls count too.
        if m:
            workers += 1
        else:
            others += 1
        saved = None
        try:
            with open(os.path.join(a.state_dir, session + ".json"), encoding="utf-8") as fh:
                saved = json.load(fh)
        except (OSError, ValueError):
            pass
        done_ok = isinstance(saved, dict) and saved.get("status") == "ok"
        # A session recorded ok with its lane or profile unknown is asked again: its launch record may exist now.
        health = saved.get("tool_health") if done_ok else None
        no_profile = isinstance(health, list) and bool(health) and not any(isinstance(r, dict) and r.get("profile") not in (None, "unknown") for r in health)
        if done_ok and getattr(a, "refresh", False):
            if journal_last_ts(j) > live_cut:
                live += 1
                continue
            who = {"leg": m.group(2) if m else None, "ticket": m.group(1) if m else None, "console": None, "pr": None,
                   "doc": None, "lane": None, "state_dir": a.state_dir, "backfill": True,
                   "launch_name": title if title and LAUNCH_NAME.match(title) else None, "kind": session_kind(title)}
            try:
                words[refresh(run_digest(j, session, a.denials_ledger), who, a.failures_ledger, a.eval_ledger, index)] += 1
            except ValueError as err:
                print("refresh: %s skipped: %s" % (session, err), file=sys.stderr)
            continue
        if done_ok and saved.get("lane") != "unknown" and not no_profile:
            done += 1
            continue
        # ponytail: recency stands in for "still running" (a worker idle past the window
        # still freezes), upgrade path: an end-of-session signal in the journal.
        if not done_ok and journal_last_ts(j) > live_cut:
            live += 1
            continue
        who = {"leg": m.group(2) if m else None, "ticket": m.group(1) if m else None, "console": None, "pr": None,
               "doc": None, "lane": None, "state_dir": a.state_dir, "backfill": True,
               "launch_name": title if title and LAUNCH_NAME.match(title) else None, "kind": session_kind(title)}
        try:
            digest = saved if done_ok else run_digest(j, session, a.denials_ledger)
            f, e = record(digest, who, a.failures_ledger, a.eval_ledger)
        except ValueError as err:
            print("backfill: %s skipped: %s" % (session, err), file=sys.stderr)
            continue
        if done_ok:
            done += 1
            restamped += e
            continue
        fa += f
        ea += e
    print("backfill: journals=%d workers=%d others=%d salus=%d already=%d failures+=%d eval+=%d live=%d restamped=%d"
          % (n, workers, others, salus, done, fa, ea, live, restamped)
          + ("" if not getattr(a, "refresh", False) else " refreshed=%d unchanged=%d refused=%d inconclusive=%d"
             % (words["refreshed"], words["unchanged"], words["refused"], words["inconclusive"])))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="worker_ledger.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("record", "backfill"):
        s = sub.add_parser(name)
        s.add_argument("--failures-ledger")
        s.add_argument("--eval-ledger")
        s.add_argument("--state-dir", default=default_state_dir())
    r = sub.choices["record"]
    r.add_argument("--digest", required=True)
    r.add_argument("--worker", dest="worker")
    r.add_argument("--chief", dest="console")
    for k in ("ticket", "doc", "lane", "launch-name", "kind"):
        r.add_argument("--" + k)
    r.add_argument("--pr", type=int)
    r.add_argument("--digest-error", choices=DIGEST_ERRORS)
    b = sub.choices["backfill"]
    b.add_argument("--since", required=True)
    b.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    b.add_argument("--denials-ledger")
    b.add_argument("--live-minutes", type=int, default=LIVE_MINUTES)
    b.add_argument("--refresh", action="store_true",
                   help="re-digest sessions already recorded ok, keeping their original times (see REFRESH)")
    v = sub.add_parser("validate")
    v.add_argument("ledger")
    a = ap.parse_args(argv)
    if a.cmd == "validate":
        return validate_file(a.ledger)
    a.failures_ledger = ledger_path(a.failures_ledger)
    a.state_dir = os.path.abspath(a.state_dir)
    if a.cmd == "backfill":
        try:
            datetime.strptime(a.since, "%Y-%m-%d")
        except ValueError:
            ap.error("--since must be YYYY-MM-DD")
        return backfill(a)
    try:
        with open(a.digest, encoding="utf-8") as fh:
            digest = json.load(fh)
        who = {"leg": a.worker, "ticket": a.ticket, "console": a.console, "pr": a.pr, "doc": a.doc,
               "lane": a.lane, "state_dir": a.state_dir, "digest_error": a.digest_error,
               "launch_name": a.launch_name, "kind": a.kind if a.kind and PROFILE.match(a.kind) else None}
        f, e = record(digest, who, a.failures_ledger, a.eval_ledger)
    except (OSError, ValueError) as err:
        print("worker-ledger: %s" % err, file=sys.stderr)
        return 1
    print("worker-ledger: %s failures+=%d eval+=%d" % (digest.get("session"), f, e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
