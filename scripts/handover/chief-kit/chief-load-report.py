#!/usr/bin/env python3
"""chief-load-report.py - read the chief load record and print what one chief costs per worker.

  chief-load-report.py <bucket dir | chief-load.jsonl> [--last N] [--workers N]

Reads the rows chief-load-row.sh appends at each chief handover; writes nothing.

Prints one line per shift of the last N (default 7): workers mean, hours, start-up context (at the
first waiter arm), end context, the shift's tokens per live worker-hour and the handover reason.
Then, over the rows that carry hours, workers and both contexts:
  g      tokens per live worker-hour = sum(ctx_end - ctx_start) / sum(workers_mean x hours)
  C_boot start-up context, the median ctx_start
  T(N)   hours a chief lasts with N live workers = (E - C_boot) / (g x N), where E is the mean
         ctx_end of the rows (each shift's peak context); N defaults to the rows' mean workers,
         sum(workers_mean x hours) / sum(hours). With no growth (g = 0) T(N) is undefined.

Exit: 0 printed; 2 usage or an unreadable record; 3 no row carries the fields the figures need.
"""

import argparse
import json
import math
import os
import statistics
import sys


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("record")
    ap.add_argument("--last", type=int, default=7)
    ap.add_argument("--workers", type=float)
    a = ap.parse_args(argv)
    if a.workers is not None and not (math.isfinite(a.workers) and a.workers > 0):
        ap.error("--workers must be a finite number above 0")
    path = os.path.join(a.record, "chief-load.jsonl") if os.path.isdir(a.record) else a.record
    rows = []
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    r = json.loads(line)
                except ValueError:
                    continue
                if isinstance(r, dict):
                    rows.append(r)
    except OSError as e:
        print("chief-load-report: cannot read %s: %s" % (path, e.strerror), file=sys.stderr)
        return 2
    rows = rows[-a.last:] if a.last > 0 else rows
    num = lambda v: isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    full = [r for r in rows if all(num(r.get(k)) for k in ("hours", "workers_mean", "ctx_start", "ctx_end"))
            and r["hours"] > 0 and r["workers_mean"] > 0]
    fmt = lambda v, f="%d": f % v if num(v) else "-"
    for r in rows:
        per = None
        if r in full:
            per = (r["ctx_end"] - r["ctx_start"]) / (r["workers_mean"] * r["hours"])
        print("shift %s workers %s hours %s start %s end %s per-worker-hour %s reason %s" % (
            r.get("shift", "-"), fmt(r.get("workers_mean"), "%.1f"), fmt(r.get("hours"), "%.2f"),
            fmt(r.get("ctx_start")), fmt(r.get("ctx_end")), fmt(per), r.get("reason") or "-"))
    if not full:
        print("chief-load-report: no row of the last %d carries hours, workers and both contexts" % len(rows), file=sys.stderr)
        return 3
    hours = sum(r["hours"] for r in full)
    worker_hours = sum(r["workers_mean"] * r["hours"] for r in full)
    g = sum(r["ctx_end"] - r["ctx_start"] for r in full) / worker_hours
    boot = statistics.median(r["ctx_start"] for r in full)
    end = statistics.mean(r["ctx_end"] for r in full)
    n = a.workers if a.workers is not None else worker_hours / hours
    print("shifts %d of %d, chief-hours %.2f, worker-hours %.1f" % (len(full), len(rows), hours, worker_hours))
    print("tokens per live worker-hour: %s" % format(round(g), ","))
    print("start-up context (median at the first waiter arm): %s" % format(round(boot), ","))
    if g <= 0:
        print("T(%.1f) undefined: no context growth in these shifts" % n)
    else:
        print("T(%.1f) = %.2f h, handing over at the mean peak context %s" % (n, (end - boot) / (g * n), format(round(end), ",")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
