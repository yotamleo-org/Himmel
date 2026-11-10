#!/usr/bin/env python3
"""How far behind main the published graph (the graph-data branch) was, hour by hour.

Replays the lag at every hour of a window from two local inputs: the
graph-cadence ledger's published-channel rows (each names the build commit
that publish carried) and `git log` on main. It needs no network and no tick,
and it writes nothing.

The published graph at an hour is the latest published-channel row at or before
it. Any other row (failed, skipped, refreshed) leaves it where it was, so a run
of failed fires shows as a gap that grows. The lag at an hour is the number of
commits on main made by then that the published build commit does not contain.

It prints p50, p90 and max over the window's hours, the hours over the limit
adopters' `himmel-update` enforces (GRAPH_MAX_BEHIND, read from himmel-update.sh),
and the hours over 40 and over 100: the target is p90 at most 40 and max at
most 100. Hours before the first published-channel row have no baseline, and
hours after a publish whose build commit the repo cannot read are unknown; both
are counted apart, never as zero and never as an older graph's lag.

Exit codes: 0 report printed; 2 bad input (no ledger, no repo, no limit).
"""
import argparse
import bisect
import json
import math
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone

HOUR = 3600
TARGET_P90 = 40
TARGET_MAX = 100
DEFAULT_UPDATE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "himmel-update.sh")


def die(msg):
    print("graph-lag-report: ERR %s" % msg, file=sys.stderr)
    sys.exit(2)


def parse_ts(text):
    """An ISO UTC timestamp (…Z) or a bare epoch, as seconds; None if neither."""
    if isinstance(text, (int, float)):
        return int(text)
    if not isinstance(text, str):
        return None
    if re.fullmatch(r"\d+", text):
        return int(text)
    try:
        return int(datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp())
    except ValueError:
        return None


def read_limit(path):
    try:
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^GRAPH_MAX_BEHIND=([0-9]+)\s*$", line)
                if m:
                    return int(m.group(1))
    except OSError as exc:
        die("cannot read %s: %s" % (path, exc))
    die("no GRAPH_MAX_BEHIND=<n> line in %s" % path)


def git(repo, *args):
    return subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True)


def resolve_ref(repo, ref):
    if ref:
        return ref
    for cand in ("origin/main", "main"):
        if git(repo, "rev-parse", "--verify", "--quiet", cand + "^{commit}").returncode == 0:
            return cand
    die("neither origin/main nor main resolves in %s" % repo)


def read_published(ledger):
    """Sorted [(epoch, graph_head)] of the published-channel rows."""
    rows = []
    try:
        with open(ledger, encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get("action") != "published-channel":
                    continue
                ts, gh = parse_ts(row.get("ts")), row.get("graph_head")
                if ts is not None and isinstance(gh, str) and gh:
                    rows.append((ts, gh))
    except OSError as exc:
        die("cannot read the ledger %s: %s" % (ledger, exc))
    rows.sort(key=lambda r: r[0])
    return rows


def commit_times_ahead(repo, ref, graph_head):
    """Sorted commit times of the commits on ref that graph_head does not contain; None if unreadable."""
    res = git(repo, "log", "--format=%ct", "%s..%s" % (graph_head, ref))
    if res.returncode != 0:
        return None
    return sorted(int(t) for t in res.stdout.split() if t.isdigit())


def percentile(sorted_vals, pct):
    """Nearest rank."""
    return sorted_vals[max(1, math.ceil(pct / 100.0 * len(sorted_vals))) - 1]


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--ledger", required=True, help="graph-cadence ledger.jsonl")
    ap.add_argument("--repo", required=True, help="a checkout of main")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--ref", default="", help="the branch to measure against (default origin/main, else main)")
    ap.add_argument("--now", default="", help="end of the window, ISO UTC or epoch (default: now)")
    ap.add_argument("--update-script", default=DEFAULT_UPDATE, help="himmel-update.sh, the owner of GRAPH_MAX_BEHIND")
    args = ap.parse_args()

    if args.days < 1:
        die("--days must be at least 1")
    if not os.path.isfile(args.ledger):
        die("no ledger at %s" % args.ledger)
    if not os.path.isdir(args.repo):
        die("no repo at %s" % args.repo)
    limit = read_limit(args.update_script)
    now = parse_ts(args.now) if args.now else int(time.time())
    if now is None:
        die("cannot read --now %s" % args.now)
    ref = resolve_ref(args.repo, args.ref)

    # A publish whose build commit this repo cannot read still replaced the graph adopters fetch,
    # so it stays a baseline and its hours are unknown, never the older graph's lag.
    ahead = {}
    published = read_published(args.ledger)
    for _, gh in published:
        if gh not in ahead:
            ahead[gh] = commit_times_ahead(args.repo, ref, gh)
    stamps = [p[0] for p in published]

    lags, no_baseline, unknown = [], 0, 0
    end = now - now % HOUR
    for i in range(args.days * 24):
        h = end - i * HOUR
        k = bisect.bisect_right(stamps, h) - 1
        if k < 0:
            no_baseline += 1
        elif ahead[published[k][1]] is None:
            unknown += 1
        else:
            lags.append(bisect.bisect_right(ahead[published[k][1]], h))

    print("graph-lag-report: days=%d hours=%d no-baseline-hours=%d unknown-hours=%d published-rows=%d ref=%s"
          % (args.days, args.days * 24, no_baseline, unknown, len(published), ref))
    if not lags:
        print("lag-commits: none (no published-channel row at or before any hour of the window)")
        print("target: UNKNOWN")
        return
    lags.sort()
    p90, mx = percentile(lags, 90), lags[-1]
    print("lag-commits: p50=%d p90=%d max=%d" % (percentile(lags, 50), p90, mx))
    print("hours-over-limit: %d (limit %d, GRAPH_MAX_BEHIND in %s)"
          % (sum(1 for v in lags if v > limit), limit, os.path.basename(args.update_script)))
    print("breaches: over-%d=%d over-%d=%d" % (TARGET_P90, sum(1 for v in lags if v > TARGET_P90),
                                              TARGET_MAX, sum(1 for v in lags if v > TARGET_MAX)))
    print("target: %s (p90 at most %d and max at most %d)"
          % ("HOLDS" if p90 <= TARGET_P90 and mx <= TARGET_MAX else "BREACHED", TARGET_P90, TARGET_MAX))


if __name__ == "__main__":
    main()
