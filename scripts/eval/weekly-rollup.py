#!/usr/bin/env python3
"""weekly-rollup.py - one row per ISO week and per stable version of velocity,
cost and health (HIMMEL-6969 slice a).

  weekly-rollup.py write  [--repo DIR] [--ref REV] [--weeks N] [--end YYYY-MM-DD]
                          [--versions N] [--out FILE] [--self-review SCRIPT]
  weekly-rollup.py review --version vX.Y.Z [--file FILE]

`write` recomputes the newest N weeks and the newest N stable tags and upserts
them by (kind, key) into the roll-up file (default
~/.himmel/state/rollup/weekly.jsonl, env WEEKLY_ROLLUP_FILE), so older rows
survive a short re-run and a re-run is idempotent. Each row carries `delta`:
the change of every series against the previous row of the same kind.

Row (v1): kind week|version, key (2026-W37 | v1.1.0), since, until (UTC),
partial, days, merges, tickets, fix_share_pct, red_main, cost_eq,
cost_eq_per_ticket (cost_eq over the tickets that carry a leg-burn line), legs, cache_hit_pct, flake_rows, delta, sources, no_source. A series with no
data is null, never 0.

Sources, none of them a new pipeline:
  merges, fix share, red main  scripts/insights/self-review.sh (HIMMEL-6865), one
                               call per window; SELF_REVIEW_SCRIPT overrides the
                               path; absent or failing -> those columns are null
  tickets, cost_eq             first-parent merge subjects and the `leg-burn:`
                               PR-body lines (`cost-eq=` summed, `k` = x1000)
  cache_hit_pct                mean `overall` of the cache-health rolling history
                               (CACHE_HEALTH_HISTORY, default
                               ~/.himmel/state/cache-health/history.jsonl)
  flake_rows                   scripts/observability/suite-flake-summary.sh over
                               the run-shell-tests.sh FLAKE ledger (rows in the
                               window = rows since start minus rows since end);
                               slice c adds the per-suite series
  failure_rate_pct, denial_rate_pct, ship_stage_median_min: no source yet, listed
                               in `no_source` and null.

`review` prints the velocity, cost and health lines of one version against the
previous version, or `no data yet` for each when the row or file is missing.
WEEKLY_ROLLUP_NOW fixes the clock (tests).
"""
import argparse
import datetime as dt
import fcntl
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SERIES = ("merges", "tickets", "fix_share_pct", "cost_eq_per_ticket",
          "red_main", "cache_hit_pct", "flake_rows")
NO_SOURCE = ["failure_rate_pct", "denial_rate_pct", "ship_stage_median_min"]
STABLE_TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
TICKET = re.compile(r"\[([A-Z][A-Z0-9]*-\d+)\]")
COST_EQ = re.compile(r"^leg-burn\b(?:(?![^\n]*cost-eq=)[^\n]*\n)?[^\n]*?\bcost-eq=([0-9]+(?:\.[0-9]+)?)(k?)", re.M)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent


def now_utc():
    raw = os.environ.get("WEEKLY_ROLLUP_NOW")
    if raw:
        return dt.datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    return dt.datetime.now(dt.timezone.utc)


def stamp(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+0000")


def num(x):
    if x is None:
        return None
    x = round(x, 2)
    return int(x) if x == int(x) else x


def git(repo, *args):
    p = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("git %s: %s" % (" ".join(args), p.stderr.strip()))
    return p.stdout


def default_ref(repo):
    p = subprocess.run(["git", "-C", repo, "rev-parse", "-q", "--verify", "origin/main"],
                       capture_output=True, text=True)
    return "origin/main" if p.returncode == 0 else "main"


def self_review(script, repo, ref, since, until):
    if not script or not Path(script).is_file():
        return None, "absent"
    p = subprocess.run(["bash", script, "--repo", repo, "--ref", ref, "--since", since, "--until", until],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None, "failed"
    out = {}
    for line in p.stdout.splitlines():
        m = re.match(r"merges: (\d+)$", line)
        if m:
            out["merges"] = int(m.group(1))
        m = re.match(r"fix-share: fix=(\d+) ", line)
        if m:
            out["fix"] = int(m.group(1))
        m = re.match(r"red-main: (\d+)$", line)
        if m:
            out["red_main"] = int(m.group(1))
    if not {"merges", "fix", "red_main"} <= out.keys():
        return None, "failed"
    return out, "ok"


def merge_bodies(repo, ref, since, until):
    raw = git(repo, "log", ref, "--first-parent", "--since=" + since, "--until=" + until,
              "--format=%x1e%s%n%b")
    for rec in raw.split("\x1e"):
        if not rec.strip():
            continue
        subject = rec.split("\n", 1)[0]
        if re.search(r"\(#\d+\)$", subject):
            yield subject, rec


def cache_hit(path, t0, t1):
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return None, "absent"
    vals = []
    for line in lines:
        try:
            row = json.loads(line)
            if t0 <= row["ts"] <= t1:
                vals.append(float(row["overall"]))
        except (ValueError, KeyError, TypeError):
            continue
    return (num(sum(vals) / len(vals)) if vals else None), "ok"


def flake_total(script, epoch):
    p = subprocess.run(["bash", script, "--since", str(epoch), "--format", "counts"],
                       capture_output=True, text=True)
    if p.returncode != 0:
        return None
    total = 0
    for line in p.stdout.splitlines():
        if line.strip() == "?":
            return None
        head = line.split("\t", 1)[0]
        if not head.isdigit():
            return None
        total += int(head)
    return total


def flake_rows(script, t0, t1):
    if not Path(script).is_file():
        return None, "absent"
    a, b = flake_total(script, int(t0.timestamp())), flake_total(script, int(t1.timestamp()) + 1)
    if a is None or b is None:
        return None, "unreadable"
    return a - b, "ok"


def build_row(kind, key, t0, t1, a):
    since, until = stamp(t0), stamp(t1)
    sr, sr_state = self_review(a.self_review, a.repo, a.ref, since, until)
    tickets, costed, cost, ticket_cost, legs = set(), set(), 0.0, 0.0, 0
    for subject, rec in merge_bodies(a.repo, a.ref, since, until):
        m = TICKET.search(subject)
        if m:
            tickets.add(m.group(1))
        for v, k in COST_EQ.findall(rec):
            cost += float(v) * (1000 if k else 1)
            legs += 1
            if m:
                costed.add(m.group(1))
                ticket_cost += float(v) * (1000 if k else 1)
    cache, cache_state = cache_hit(a.cache_history, t0.timestamp(), t1.timestamp())
    flakes, flake_state = flake_rows(a.flake_script, t0, t1)
    n_t = len(costed)
    merges = sr["merges"] if sr else None
    return {
        "v": 1, "kind": kind, "key": key, "since": since, "until": until,
        "partial": a.now <= t1,
        "merges": merges,
        "tickets": len(tickets),
        "days": num((t1 - t0).total_seconds() / 86400) if t0.year > 2000 else None,
        "fix_share_pct": (num(100.0 * sr["fix"] / sr["merges"]) if sr["merges"] else 0) if sr else None,
        "red_main": sr["red_main"] if sr else None,
        "cost_eq": num(cost) if legs else None,
        "cost_eq_per_ticket": num(ticket_cost / n_t) if n_t else None,
        "legs": legs,
        "cache_hit_pct": cache,
        "flake_rows": flakes,
        "failure_rate_pct": None, "denial_rate_pct": None, "ship_stage_median_min": None,
        "no_source": NO_SOURCE,
        "sources": {"self_review": sr_state, "cost": "ok" if legs else "no-burn-lines",
                    "cache": cache_state, "flake": flake_state},
    }


def week_windows(end, n):
    monday = end - dt.timedelta(days=end.weekday())
    for i in range(n - 1, -1, -1):
        m = monday - dt.timedelta(weeks=i)
        t0 = dt.datetime(m.year, m.month, m.day, tzinfo=dt.timezone.utc)
        iso = m.isocalendar()
        yield "%d-W%02d" % (iso[0], iso[1]), t0, t0 + dt.timedelta(days=7) - dt.timedelta(seconds=1)


def version_windows(repo, ref, n):
    tags = []
    for t in git(repo, "tag", "--merged", ref, "--list").split():
        m = STABLE_TAG.match(t)
        if m:
            tags.append((tuple(int(x) for x in m.groups()), t))
    tags.sort()
    dates = {}
    for _, t in tags:
        dates[t] = dt.datetime.fromisoformat(git(repo, "log", "-1", "--format=%cI", t).strip()).astimezone(dt.timezone.utc)
    for i in range(max(0, len(tags) - n), len(tags)):
        t = tags[i][1]
        prev = dates[tags[i - 1][1]] + dt.timedelta(seconds=1) if i else dt.datetime(1970, 1, 2, tzinfo=dt.timezone.utc)
        yield t, prev, dates[t]


def load(path):
    rows = {}
    try:
        for line in Path(path).read_text().splitlines():
            try:
                r = json.loads(line)
                rows[(r["kind"], r["key"])] = r
            except (ValueError, KeyError, TypeError):
                continue
    except OSError:
        pass
    return rows


def with_deltas(rows):
    out, prev = [], {}
    for r in sorted(rows.values(), key=lambda r: (r["kind"], r["since"])):
        p = prev.get(r["kind"])
        r["delta"] = {s: (num(r[s] - p[s]) if p and r.get(s) is not None and p.get(s) is not None else None)
                      for s in SERIES}
        prev[r["kind"]] = r
        out.append(r)
    return out


def cmd_write(a):
    a.now = now_utc()
    a.repo = os.path.abspath(a.repo)
    a.ref = a.ref or default_ref(a.repo)
    a.self_review = a.self_review or os.environ.get("SELF_REVIEW_SCRIPT") or str(ROOT / "scripts/insights/self-review.sh")
    a.cache_history = os.environ.get("CACHE_HEALTH_HISTORY") or str(Path.home() / ".himmel/state/cache-health/history.jsonl")
    a.flake_script = os.environ.get("FLAKE_SUMMARY_SCRIPT") or str(ROOT / "scripts/observability/suite-flake-summary.sh")
    end = dt.date.fromisoformat(a.end) if a.end else a.now.date()
    out = Path(a.out or os.environ.get("WEEKLY_ROLLUP_FILE") or Path.home() / ".himmel/state/rollup/weekly.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    lock = open(out.with_name(out.name + ".lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    rows = load(out)
    try:
        for key, t0, t1 in (week_windows(end, a.weeks) if a.weeks else ()):
            rows[("week", key)] = build_row("week", key, t0, t1, a)
        for key, t0, t1 in (version_windows(a.repo, a.ref, a.versions) if a.versions else ()):
            rows[("version", key)] = build_row("version", key, t0, t1, a)
    except RuntimeError as e:
        print("weekly-rollup: %s" % e, file=sys.stderr)
        return 2
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    tmp.write_text("".join(json.dumps(r, separators=(",", ":")) + "\n" for r in with_deltas(rows)))
    os.replace(tmp, out)
    print("weekly-rollup: %d rows in %s" % (len(rows), out))
    return 0


def kfmt(x):
    if x is None:
        return "n/a"
    return ("%gk" % round(x / 1000, 1)) if abs(x) >= 1000 else "%g" % x


def sfmt(x, unit=""):
    return "n/a" if x is None else "%g%s" % (x, unit)


def dfmt(x, f):
    if x is None:
        return "n/a"
    return ("+" if x >= 0 else "-") + f(abs(x)).lstrip("+")


def cmd_review(a):
    out = Path(a.file or os.environ.get("WEEKLY_ROLLUP_FILE") or Path.home() / ".himmel/state/rollup/weekly.jsonl")
    rows = [r for r in with_deltas(load(out)) if r["kind"] == "version"]
    keys = [r["key"] for r in rows]
    if a.version not in keys:
        for name in ("velocity", "cost", "health"):
            print("%s: no data yet" % name)
        return 0
    i = keys.index(a.version)
    r = rows[i]
    vs = " vs %s" % rows[i - 1]["key"] if i else " (no previous version)"
    d = r["delta"]
    plain = lambda x: "%g" % x
    print("velocity: merges=%s (%s%s) tickets=%s (%s) fix-share=%s (%s) window=%s" % (
        sfmt(r["merges"]), dfmt(d["merges"], plain), vs, sfmt(r["tickets"]), dfmt(d["tickets"], plain),
        sfmt(r["fix_share_pct"], "%"), dfmt(d["fix_share_pct"], plain), sfmt(r["days"], "d")))
    print("cost: cost-eq=%s legs=%s per-ticket=%s (%s%s)" % (
        kfmt(r["cost_eq"]), r["legs"], kfmt(r["cost_eq_per_ticket"]), dfmt(d["cost_eq_per_ticket"], kfmt), vs))
    print("health: red-main=%s (%s) cache-hit=%s (%s) flakes=%s (%s); failure and denial rates: no source yet" % (
        sfmt(r["red_main"]), dfmt(d["red_main"], plain), sfmt(r["cache_hit_pct"], "%"), dfmt(d["cache_hit_pct"], plain),
        sfmt(r["flake_rows"]), dfmt(d["flake_rows"], plain)))
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("--repo", default=".")
    w.add_argument("--ref")
    w.add_argument("--weeks", type=int, default=12)
    w.add_argument("--end")
    w.add_argument("--versions", type=int, default=0)
    w.add_argument("--out")
    w.add_argument("--self-review")
    r = sub.add_parser("review")
    r.add_argument("--version", required=True)
    r.add_argument("--file")
    a = ap.parse_args(argv)
    return cmd_write(a) if a.cmd == "write" else cmd_review(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
