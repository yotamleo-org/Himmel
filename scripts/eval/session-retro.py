#!/usr/bin/env python3
"""scripts/eval/session-retro.py - top recurring leg stall classes over a window (HIMMEL-5514 POC).

Read-only, deterministic, no model call. Counts the leg-failures ledger that
scripts/handover/console-kit/leg-digest-step.sh feeds (writer: leg_ledger.py;
path: $HIMMEL_LEG_FAILURES_LEDGER, else ~/.himmel/leg-failures.jsonl).

  session-retro.py [--ledger P] [--days 7] [--now ISO8601] [--top 5] [--include-traj]

A class ranks by the number of distinct sessions it hit, then by total
occurrences (the row's count), then by name. Rows are windowed on their `ts`.
traj/* rows are trajectory metrics, not stalls, so they are left out unless
--include-traj is given.

Output: one header line, then `rank sessions count class legs`, where legs are
up to three example legs (most occurrences first; the session prefix stands in
for a row with no leg label).

Exit: 0 ok, 2 usage error (argparse) or unreadable ledger (the message says which).
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone

LEDGER_ENV = "HIMMEL_LEG_FAILURES_LEDGER"
EXAMPLES = 3


def parse_ts(s):
    d = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger")
    ap.add_argument("--days", type=int, default=7)
    ap.add_argument("--now")
    ap.add_argument("--top", type=int, default=5)
    ap.add_argument("--include-traj", action="store_true")
    a = ap.parse_args(argv)

    path = a.ledger or os.environ.get(LEDGER_ENV) or os.path.expanduser("~/.himmel/leg-failures.jsonl")
    now = parse_ts(a.now) if a.now else datetime.now(timezone.utc)
    cutoff = now - timedelta(days=a.days)

    try:
        fh = open(path, encoding="utf-8")
    except OSError as e:
        print("session-retro: cannot read %s: %s" % (path, e), file=sys.stderr)
        return 2

    classes = {}
    rows = skipped = 0
    with fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
                ts = parse_ts(r["ts"])
                cls, sess, n = r["class"], r["session"], int(r["count"])
                if not isinstance(cls, str) or not isinstance(sess, str):
                    raise ValueError("class and session must be strings")
            except (ValueError, KeyError, TypeError, AttributeError):
                skipped += 1
                continue
            if ts < cutoff or ts > now:
                continue
            if r.get("failure") == "traj" and not a.include_traj:
                continue
            rows += 1
            c = classes.setdefault(cls, {"sessions": {}, "count": 0})
            c["count"] += n
            s = c["sessions"].setdefault(sess, [r.get("leg") or sess[:8], 0])
            s[1] += n

    ranked = sorted(classes.items(), key=lambda kv: (-len(kv[1]["sessions"]), -kv[1]["count"], kv[0]))
    print("session-retro: %s .. %s  rows=%d classes=%d skipped=%d  ledger=%s"
          % (cutoff.strftime("%Y-%m-%dT%H:%MZ"), now.strftime("%Y-%m-%dT%H:%MZ"), rows, len(classes), skipped, path))
    for i, (cls, c) in enumerate(ranked[: a.top], 1):
        legs = [w for w, _ in sorted(c["sessions"].values(), key=lambda s: (-s[1], s[0]))[:EXAMPLES]]
        print("%d\t%d\t%d\t%s\t%s" % (i, len(c["sessions"]), c["count"], cls, ",".join(legs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
