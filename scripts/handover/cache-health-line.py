#!/usr/bin/env python3
"""cache-health-line.py - the one-line prompt-cache summary for /morning-report (HIMMEL-668).

Zero-token and local: reads the files scripts/eval/cache-health.py writes under
~/.himmel/state/cache-health/ and prints exactly one line.

  metrics.json   freshness gate (generated_at); missing, unreadable or older than
                 26h prints "cache: unmonitored (metrics missing|invalid|stale)",
                 never a vacuous pass.
  history.jsonl  one {"ts","overall","roles":{role: hit_pct}} row per hourly run,
                 each hit_pct = cache_read / (cache_read + cache_creation + input)
                 over that run's trailing 24h window.

7d read ratio   mean of the hit_pct values of the runs in the last 7 days (rows
                carry no token counts, so it is an unweighted mean of the 24h
                windows, not a token-weighted ratio). Per kind = per session role.
Baseline        median of the per-day means (UTC days) over the 14 days before
                today, needing at least 7 sampled days; otherwise "no baseline yet".
                It is our own trailing history - the 76.5% / 40% figures quoted
                online are NOT a baseline.
Trend flag      a series is flagged when each of the last 3 calendar days (today
                included) has a value below its own baseline.

Usage: cache-health-line.py [--state-dir D] [--now EPOCH]
"""
import argparse, json, os, statistics, sys, time
from collections import defaultdict

STALE_S = 26 * 3600
DAY = 86400
BASELINE_DAYS = 14
BASELINE_MIN_DAYS = 7
FLAG_DAYS = 3
KINDS = ["console", "leg", "subagent", "bridge", "other"]


def load_json(path):
    with open(path) as f:
        return json.load(f)


def load_history(path):
    rows = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict) and isinstance(r.get("ts"), (int, float)):
                    rows.append(r)
    except OSError:
        pass
    return rows


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def series_values(r):
    """-> {series: hit_pct} for one history row; null values dropped."""
    out = {}
    if num(r.get("overall")) is not None:
        out["overall"] = r["overall"]
    roles = r.get("roles") if isinstance(r.get("roles"), dict) else {}
    for k in KINDS:
        if num(roles.get(k)) is not None:
            out[k] = roles[k]
    return out


def build(rows, now):
    """-> (7d mean per series, per-day means per series)."""
    recent = defaultdict(list)
    days = defaultdict(lambda: defaultdict(list))
    for r in rows:
        for s, v in series_values(r).items():
            if r["ts"] > now - 7 * DAY:
                recent[s].append(v)
            days[s][int(r["ts"] // DAY)].append(v)
    mean7 = {s: sum(v) / len(v) for s, v in recent.items()}
    daily = {s: {d: sum(v) / len(v) for d, v in dd.items()} for s, dd in days.items()}
    return mean7, daily


def baseline(daily_s, today):
    vals = [v for d, v in daily_s.items() if today - BASELINE_DAYS <= d < today]
    return statistics.median(vals) if len(vals) >= BASELINE_MIN_DAYS else None


def below_3d(daily_s, today, base):
    if base is None:
        return False
    last = [daily_s.get(today - i) for i in range(FLAG_DAYS)]
    return all(v is not None and v < base for v in last)


def fmt(v):
    return "%.1f%%" % v


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--state-dir", default=os.path.expanduser("~/.himmel/state/cache-health"))
    p.add_argument("--now", type=float, default=None)
    a = p.parse_args()
    now = a.now if a.now is not None else time.time()

    try:
        metrics = load_json(os.path.join(a.state_dir, "metrics.json"))
    except FileNotFoundError:
        print("cache: unmonitored (metrics missing)")
        return 0
    except (OSError, ValueError):
        print("cache: unmonitored (metrics invalid)")
        return 0
    gen = num(metrics.get("generated_at")) if isinstance(metrics, dict) else None
    if gen is None:
        print("cache: unmonitored (metrics invalid)")
        return 0
    if now - gen > STALE_S:
        print("cache: unmonitored (metrics stale)")
        return 0

    mean7, daily = build(load_history(os.path.join(a.state_dir, "history.jsonl")), now)
    today = int(now // DAY)
    if "overall" not in mean7:
        # no history rows in the window: fall back to the single 24h figure
        o = num(((metrics.get("overall") or {}).get("hit_pct")))
        if o is None:
            print("cache: unmonitored (no samples)")
            return 0
        print("cache: 24h read ratio %s (no 7d history yet) · no baseline yet" % fmt(o))
        return 0

    kinds = ", ".join("%s %s" % (k, fmt(mean7[k])) for k in KINDS if k in mean7)
    head = "cache: 7d read ratio %s" % fmt(mean7["overall"])
    if kinds:
        head += " (%s)" % kinds
    base = baseline(daily.get("overall", {}), today)
    parts = [head, "baseline %s (14d median)" % fmt(base) if base is not None else "no baseline yet"]
    flagged = [s for s in ["overall"] + KINDS
               if s in daily and below_3d(daily[s], today, baseline(daily[s], today))]
    if flagged:
        parts.append("WARN below baseline %dd (%s)" % (FLAG_DAYS, ", ".join(flagged)))
    print(" · ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
