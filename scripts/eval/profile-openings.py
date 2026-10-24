#!/usr/bin/env python3
"""scripts/eval/profile-openings.py - how big a session's opening is, per launch profile.

Joins the launcher's per-session launch record (headed-arm-leg.sh: <cache>/launch-logs/<session>.log, one
line per launch with profile=, lane=, and session_id= when the launch minted one) to the session
transcript under ~/.claude/projects, and reads that transcript's FIRST assistant request: its opening size
is input + cache-creation + cache-read tokens. It reads local files only: no model call, no network.

  profile-openings.py [--since-days 14] [--lane native] [--min-n 3] [--json] [--record]
                      [--launch-logs D] [--projects D] [--ledger P] [--now ISO]

The join key is session_id= when the line has it, else the session name against the transcript's
custom-title. A name whose launch lines disagree on the profile (a refused duplicate of a live name) is
left out, as are a launch with profile=none and a composed list (a,b: no single budget to set). Per profile it prints n, the median opening, the range, and the
contextBudget the median supports: the median rounded up to 1000 once n reaches --min-n, else "keep".
--record appends one eval-runs row per profile (eval "profile-opening"). Without it nothing is written.
Launch logs: $HIMMELCTL_CACHE_DIR/launch-logs, else ~/.claude/himmel/launch-logs.
Ledger: $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl.
"""
import argparse
import json
import math
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import eval_runs  # noqa: E402

SOURCE = "scripts/eval/profile-openings.py"
LINE = re.compile(r"^headed-arm-leg: (.*)$")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
HEAD_LINES = 12
SCAN_LINES = 2000


def parse_launches(logs_dir, since, lane):
    """{session name: {"profile", "lane", "sids": set, "launched"}} for launches at or after `since`.
    A name whose in-window lines disagree on profile or lane is dropped."""
    out, dropped = {}, set()
    try:
        names = sorted(os.listdir(logs_dir))
    except OSError:
        return out
    for fn in names:
        if not fn.endswith(".log"):
            continue
        name = fn[:-4]
        try:
            with open(os.path.join(logs_dir, fn), encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except OSError:
            continue
        seen = []
        for ln in lines:
            m = LINE.match(ln)
            if not m:
                continue
            kv = dict(t.split("=", 1) for t in m.group(1).split() if "=" in t)
            if kv.get("launched", "") < since:
                continue
            seen.append(kv)
        profiles = {kv.get("profile") for kv in seen}
        lanes = {kv.get("lane") for kv in seen}
        if len(profiles) != 1 or len(lanes) != 1:
            continue
        p, ln_ = next(iter(profiles)), next(iter(lanes))
        if not p or p == "none" or "," in p or (lane != "any" and ln_ != lane):
            continue
        out[name] = {"profile": p, "lane": ln_,
                     "sids": {kv["session_id"] for kv in seen if UUID.match(kv.get("session_id", ""))},
                     "launched": min(kv["launched"] for kv in seen)}
    return out


def index_transcripts(projects, since_epoch):
    """({title: [path]}, {uuid: path}) over top-level <projects>/*/<uuid>.jsonl written since `since_epoch`."""
    by_title, by_sid = {}, {}
    try:
        dirs = [os.path.join(projects, d) for d in sorted(os.listdir(projects))]
    except OSError:
        return by_title, by_sid
    for d in dirs:
        try:
            files = os.listdir(d)
        except OSError:
            continue
        for fn in files:
            if not fn.endswith(".jsonl"):
                continue
            path = os.path.join(d, fn)
            try:
                if os.path.getmtime(path) < since_epoch:
                    continue
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for _, line in zip(range(HEAD_LINES), fh):
                        if line.startswith('{"type":"custom-title"'):
                            title = json.loads(line).get("customTitle")
                            if title:
                                by_title.setdefault(title, []).append(path)
                            break
            except (OSError, ValueError):
                continue
            by_sid[fn[:-6]] = path
    return by_title, by_sid


def opening_size(path):
    """Tokens of the first real assistant request, or None."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            for _, line in zip(range(SCAN_LINES), fh):
                if '"assistant"' not in line or '"usage"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message")
                if o.get("type") != "assistant" or o.get("isSidechain") or not isinstance(m, dict):
                    continue
                u = m.get("usage")
                if not isinstance(u, dict) or m.get("model") == "<synthetic>":
                    continue
                total = sum(u.get(k) or 0 for k in ("input_tokens", "cache_creation_input_tokens",
                                                    "cache_read_input_tokens"))
                if total > 0:
                    return total
    except OSError:
        return None
    return None


def collect(logs_dir, projects, since, lane):
    """{profile: {"sizes": [int], "lane": str}}: one size per distinct transcript."""
    launches = parse_launches(logs_dir, since, lane)
    since_epoch = datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    by_title, by_sid = index_transcripts(projects, since_epoch)
    prof, claimed = {}, set()
    for name, rec in sorted(launches.items()):
        paths = ([by_sid[s] for s in sorted(rec["sids"]) if s in by_sid] if rec["sids"]
                 else by_title.get(name, []))
        for path in paths:
            if path in claimed:
                continue
            size = opening_size(path)
            if size is None:
                continue
            claimed.add(path)
            entry = prof.setdefault(rec["profile"], {"sizes": [], "lane": rec["lane"]})
            entry["sizes"].append(size)
            if entry["lane"] != rec["lane"]:
                entry["lane"] = "mixed"
    return prof


def summarize(prof, min_n):
    rows = []
    for p in sorted(prof):
        s = sorted(prof[p]["sizes"])
        med = statistics.median(s)
        rows.append({"profile": p, "lane": prof[p]["lane"], "n": len(s), "median": int(med),
                     "min": s[0], "max": s[-1],
                     "budget": int(math.ceil(med / 1000.0) * 1000) if len(s) >= min_n else None})
    return rows


def ledger_row(r, since_days, lane):
    return eval_runs.make_row("profile-opening", SOURCE,
                              {"profile": r["profile"], "lane": lane, "since_days": since_days, "opening_v": 1},
                              {"median_tokens": r["median"], "min_tokens": r["min"], "max_tokens": r["max"],
                               "budget_tokens": r["budget"]},
                              n=r["n"], lane=r["lane"], model=None, status="ok" if r["budget"] else "partial",
                              meta={"observational": True, "profile": r["profile"]})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    cache = os.environ.get("HIMMELCTL_CACHE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "himmel")
    ap.add_argument("--launch-logs", default=os.path.join(cache, "launch-logs"))
    ap.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    ap.add_argument("--since-days", type=int, default=14)
    ap.add_argument("--lane", default="native")
    ap.add_argument("--min-n", type=int, default=3)
    ap.add_argument("--now")
    ap.add_argument("--ledger")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--record", action="store_true")
    a = ap.parse_args(argv)
    now = (datetime.strptime(a.now, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc) if a.now
           else datetime.now(timezone.utc))
    since = (now - timedelta(days=a.since_days)).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows = summarize(collect(a.launch_logs, a.projects, since, a.lane), a.min_n)
    if not rows:
        sys.stderr.write("profile-openings: no launch joined to a transcript since %s\n" % since)
        return 1
    if a.json:
        print(json.dumps(rows, indent=1, sort_keys=True))
    else:
        print("%-16s %5s %9s %9s %9s  %s" % ("profile", "n", "median", "min", "max", "budget"))
        for r in rows:
            print("%-16s %5d %9d %9d %9d  %s" % (r["profile"], r["n"], r["median"], r["min"], r["max"],
                                                   r["budget"] if r["budget"] else "keep (n<%d)" % a.min_n))
    if a.record:
        for r in rows:
            eval_runs.append_row(ledger_row(r, a.since_days, a.lane), eval_runs.ledger_path(a.ledger))
    return 0


if __name__ == "__main__":
    sys.exit(main())
