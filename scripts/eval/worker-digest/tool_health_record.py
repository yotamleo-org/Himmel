#!/usr/bin/env python3
"""scripts/eval/worker-digest/tool_health_record.py - appends the daily tool-health eval-runs row.

The counts come from tool-health-record.mjs (the Tool health page's own roll-up over one UTC day). This writer wraps
that body in the validated eval-runs envelope (eval_runs.make_row) and appends it once per day. Record first, audit
read-only: no rule in scripts/eval/feedback-rules.json names this eval, so eval_feedback.py changes nothing because of it.

  tool_health_record.py write --body FILE|- [--ledger P]

BODY (JSON): {day, status, n, config, metrics, cases, meta}; any other key is refused.

SERIES AND REVISIONS, all under one flock beside the ledger:
  series       (eval, host, confighash). The config names what a count means, never the day, so one series has one
               row per day. eval_feedback.py reads the newest ok row per eval in file order, so a row that is not the
               newest day must not be ok.
  idempotence  a day that already has an ok row appends nothing; a day that already has a row of the same non-ok
               status appends nothing; an ok body over a non-ok row of that day is the finalized revision and appends.
  backfill     an ok body for a day older than the newest ok day of its series is written as partial
               (meta.revision "backfill"), so the late row can never become the series' latest ok row.
Exit: 0 written or already recorded, 2 refused input.
Stdlib only; no network.
"""
import argparse
import fcntl
import json
import os
import re
import socket
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

SOURCE = "scripts/eval/worker-digest/tool_health_record.py"
EVAL_ID = "tool-health"
DAY = re.compile(r"^\d{4}-\d{2}-\d{2}$")
KEYS = {"day", "status", "n", "config", "metrics", "cases", "meta"}
BACKFILL_NOTE = "older than the newest recorded day of this series; kept out of the newest-ok-row choice of eval_feedback"


def write(body, ledger=None):
    """Append the day's row if the series rules allow it; returns (outcome, run_id) with outcome "written" or "exists"."""
    if not isinstance(body, dict) or set(body) - KEYS:
        raise ValueError("body must be an object with only: %s" % ", ".join(sorted(KEYS)))
    day, status, config = body.get("day"), body.get("status"), body.get("config")
    if not isinstance(day, str) or not DAY.match(day):
        raise ValueError("day must be YYYY-MM-DD")
    if status not in eval_runs.STATUSES:
        raise ValueError("status must be one of %s" % ", ".join(eval_runs.STATUSES))
    if not isinstance(config, dict):
        raise ValueError("config must be an object")
    meta = dict(body.get("meta") or {}, day=day)
    confighash = eval_runs.config_hash(config)
    host = socket.gethostname()
    path = eval_runs.ledger_path(ledger)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".tool-health.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rows = [r for r in eval_runs.read_rows(path) if r["eval"] == EVAL_ID]
        series = [r for r in rows if r["host"] == host and r["confighash"] == confighash]
        # eval_feedback takes the newest ok row of the whole eval, so a later day under any host or wiring makes this one a backfill.
        if status == "ok" and any(r["status"] == "ok" and r["meta"].get("day", "") > day for r in rows):
            status = "partial"
            meta.update(revision="backfill", partial_reason=BACKFILL_NOTE)
        same = [r for r in series if r["meta"].get("day") == day]
        if any(r["status"] == "ok" for r in same) or any(r["status"] == status for r in same):
            return "exists", same[0]["run_id"]
        run_id = "tool-health:%s:%s:%s" % (host, day, confighash[:8])
        if same:
            run_id += ".r%d" % (len(same) + 1)
        row = eval_runs.make_row(EVAL_ID, SOURCE, config, body.get("metrics"), n=body.get("n"), status=status,
                                 run_id=run_id, cases=body.get("cases"), meta=meta)
        eval_runs.append_row(row, path)
    return "written", run_id


def main(argv=None):
    ap = argparse.ArgumentParser(prog="tool_health_record.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("--body", required=True)
    w.add_argument("--ledger")
    a = ap.parse_args(argv)
    try:
        text = sys.stdin.read() if a.body == "-" else open(a.body, encoding="utf-8").read()
        outcome, run_id = write(json.loads(text), a.ledger)
    except (OSError, ValueError) as e:
        print("tool-health-record: %s" % e, file=sys.stderr)
        return 2
    print("tool-health-record: %s %s" % (outcome, run_id))
    return 0


if __name__ == "__main__":
    sys.exit(main())
