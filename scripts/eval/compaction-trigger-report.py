#!/usr/bin/env python3
"""compaction-trigger-report.py: where do workers on one autocompact ceiling
compact, and does the context guard deny first? Reads transcripts only, no
model call.

Every token figure is marked: `cli` is compact_boundary.compactMetadata.preTokens,
the CLI's own estimate; `api` is input + cache read + cache create on an
assistant call's usage. The two are never subtracted from each other.

Each compaction gets a shape:
  idle    the last call before it is >= --idle-s old (the ~54-minute trigger);
  batch   the tool results since that call carry >= --batch-tokens (chars / 4,
          an estimate): one large batch jumped the context, so the guard,
          which checks between calls, had no call to deny;
  steady  neither: ordinary growth, the only shape that locates the trigger.
  manual  a /compact the worker asked for; it says nothing about the trigger.

Input: transcript paths, or --launch-logs <dir> (headed-arm-worker logs, a line
`... model=<opus model> (autocompact=<n>)` per launch) joined to the
transcripts under --projects by session title.

Usage:
  compaction-trigger-report.py [--json] <transcript.jsonl>...
  compaction-trigger-report.py --launch-logs <dir> [--projects <dir>] [--since <iso>] [--json]
"""
import argparse
import glob
import json
import math
import os
import re
import sys
from datetime import datetime

DENY = re.compile(r"^PreToolUse:\w+ hook error: worker context (?:hand-off|checkpoint) \(mode (\w+)\): "
                  r"this session is at (\d+) % context fill")
DENY_CEILING = re.compile(r"of the (\d+)-token autocompact")
LAUNCH = re.compile(r"^(\d{4}-\d\d-\d\d_\d\d:\d\d:\d\d) .*model=(\S+) \(autocompact=(\d+)\)")
REFUSED_COMPACT = "refusing auto-compaction: no CHECKPOINT or RESUME yet"


def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, AttributeError):
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(b.get("text", "") for b in content if isinstance(b, dict))
    return ""


def parse(path, batch_tokens, idle_s):
    title, calls, comps, denies, refused = None, [], [], [], 0
    seen_ids = {}
    since_call_chars = 0
    ceiling_seen = None
    for line in open(path, errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("customTitle"):
            title = row["customTitle"]
        if row.get("isSidechain"):
            continue
        t = ts(row.get("timestamp"))
        kind = row.get("type")
        if kind == "system" and row.get("subtype") == "compact_boundary":
            meta = row.get("compactMetadata") or {}
            last = calls[-1] if calls else None
            gap = round(t - last["t"]) if (last and t is not None and last["t"] is not None) else None
            est = since_call_chars // 4
            shape = ("manual" if meta.get("trigger") == "manual"
                     else "idle" if gap is not None and gap >= idle_s
                     else "batch" if est >= batch_tokens else "steady")
            comps.append({"t": t, "trigger": meta.get("trigger"), "cli_pre": meta.get("preTokens"),
                          "api_before": last["api"] if last else None, "api_after": None,
                          "gap_s": gap, "batch_est": est, "shape": shape})
            continue
        if kind in ("system", "attachment") and REFUSED_COMPACT in line:
            refused += 1
        msg = row.get("message") or {}
        if kind == "assistant" and isinstance(msg, dict) and isinstance(msg.get("usage"), dict):
            u = msg["usage"]
            api = (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) \
                + (u.get("cache_creation_input_tokens") or 0)
            mid = msg.get("id")
            if mid and mid in seen_ids:
                seen_ids[mid]["api"] = api
                continue
            call = {"t": t, "api": api, "model": msg.get("model")}
            if mid:
                seen_ids[mid] = call
            calls.append(call)
            since_call_chars = 0
            if comps and comps[-1]["api_after"] is None:
                comps[-1]["api_after"] = api
            continue
        if kind == "user" and isinstance(msg, dict) and isinstance(msg.get("content"), list):
            for b in msg["content"]:
                if not isinstance(b, dict) or b.get("type") != "tool_result":
                    continue
                body = text_of(b.get("content"))
                since_call_chars += len(body)
                m = DENY.match(body) if b.get("is_error") else None
                if m:
                    c = DENY_CEILING.search(body)
                    if c:
                        ceiling_seen = int(c.group(1))
                    denies.append({"t": t, "mode": m.group(1), "fill_pct": int(m.group(2)),
                                   "api_before": calls[-1]["api"] if calls else None})
    models = {}
    for c in calls:
        models[c["model"]] = models.get(c["model"], 0) + 1
    first_c = comps[0]["t"] if comps else None
    first_d = denies[0]["t"] if denies else None
    if first_d is not None and (first_c is None or first_d < first_c):
        order = "deny-first" if first_c is not None else "deny-only"
    elif first_c is not None:
        order = "compact-first" if first_d is not None else "compact-only"
    else:
        order = "neither"
    return {"path": path, "session": title or os.path.basename(path),
            "model": max(models, key=models.get) if models else None,
            "calls": len(calls), "api_peak": max((c["api"] for c in calls), default=0),
            "compactions": comps, "denies": len(denies),
            "first_deny": denies[0] if denies else None, "refused_compactions": refused,
            "deny_ceiling": ceiling_seen, "order": order}


def launches(log_dir, ceiling, since):
    names = {}
    for p in sorted(glob.glob(os.path.join(log_dir, "*.log"))):
        name = os.path.basename(p)[:-4]
        for line in open(p, errors="replace"):
            m = LAUNCH.match(line)
            if not m or "opus" not in m.group(2) or int(m.group(3)) != ceiling:
                continue
            at = datetime.strptime(m.group(1), "%Y-%m-%d_%H:%M:%S").timestamp()
            if since is None or at >= since:
                names[name] = m.group(2)
    return names


def find(projects, names, since):
    found = []
    for p in glob.glob(os.path.join(projects, "**", "*.jsonl"), recursive=True):
        if "/subagents/" in p:
            continue
        try:
            if since is not None and os.path.getmtime(p) < since:
                continue
            with open(p, errors="replace") as fh:
                for line in fh:
                    m = re.search(r'"customTitle"\s*:\s*"([^"]+)"', line)
                    if m and m.group(1) in names:
                        found.append(p)
                        break
        except OSError:
            continue
    return sorted(found)


def guard_threshold_api(share, ceiling, window):
    whole_pct_of_window = math.ceil(share * ceiling / window)
    return whole_pct_of_window * window // 100


def fmt(v):
    return "-" if v is None else str(v)


def report(rows, args, threshold):
    comps = [(r["session"], c) for r in rows for c in r["compactions"]]
    shapes = {s: sum(1 for _, c in comps if c["shape"] == s) for s in ("steady", "batch", "idle", "manual")}
    orders = {o: sum(1 for r in rows if r["order"] == o)
              for o in ("deny-first", "deny-only", "compact-first", "compact-only", "neither")}
    steady = [c for _, c in comps if c["shape"] == "steady"]
    n = len(rows)
    if not steady:
        answer = ("sample too small: 0 steady-growth compactions at %d across %d workers at or above "
                  "%d api; the guard denied before any compaction in %d, a compaction came first in %d"
                  % (args.ceiling, n, args.min_peak, orders["deny-first"] + orders["deny-only"],
                     orders["compact-first"] + orders["compact-only"]))
    else:
        cli = [c["cli_pre"] for c in steady if c["cli_pre"] is not None]
        api = [c["api_before"] for c in steady if c["api_before"] is not None]
        answer = ("%d steady-growth compactions at %d across %d workers: cli %s to %s, api before %s to %s; "
                  "the guard denied before any compaction in %d, a compaction came first in %d"
                  % (len(steady), args.ceiling, n, fmt(min(cli, default=None)), fmt(max(cli, default=None)),
                     fmt(min(api, default=None)), fmt(max(api, default=None)),
                     orders["deny-first"] + orders["deny-only"],
                     orders["compact-first"] + orders["compact-only"]))
    return {"ceiling": args.ceiling, "threshold_api": threshold, "workers": n,
            "compactions": len(comps), "shapes": shapes, "orders": orders, "answer": answer}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("transcripts", nargs="*")
    ap.add_argument("--launch-logs")
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--since", help="ISO time; launches and transcripts older than it are skipped")
    ap.add_argument("--ceiling", type=int, default=800000)
    ap.add_argument("--share", type=int, default=87)
    ap.add_argument("--window", type=int, default=1000000)
    ap.add_argument("--min-peak", type=int, default=600000, help="api peak a worker must reach")
    ap.add_argument("--batch-tokens", type=int, default=50000)
    ap.add_argument("--idle-s", type=int, default=3000)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()
    since = ts(args.since) if args.since else None
    if args.since and since is None:
        ap.error("--since is not an ISO time: %s" % args.since)
    paths = list(args.transcripts)
    if args.launch_logs:
        paths += find(args.projects, launches(args.launch_logs, args.ceiling, since), since)
    paths = sorted(set(paths))
    if not paths:
        print("compaction-trigger-report: no transcripts (give paths or --launch-logs)", file=sys.stderr)
        return 1
    threshold = guard_threshold_api(args.share, args.ceiling, args.window)
    rows = [r for r in (parse(p, args.batch_tokens, args.idle_s) for p in paths)
            if r["api_peak"] >= args.min_peak]
    summary = report(rows, args, threshold)
    if args.json:
        print(json.dumps({"summary": summary, "workers": rows}, indent=1))
        return 0
    print("| worker | model | api peak | compactions | denies | first deny fill % (api before) | order |")
    print("|---|---|---:|---:|---:|---|---|")
    for r in rows:
        d = r["first_deny"]
        print("| %s | %s | %d | %d | %d | %s | %s |" % (
            r["session"], r["model"], r["api_peak"], len(r["compactions"]), r["denies"],
            "%d (%s)" % (d["fill_pct"], fmt(d["api_before"])) if d else "-", r["order"]))
    print()
    print("| worker | # | trigger | cli preTokens | api before | api after | gap s | batch est. tokens | shape |")
    print("|---|---:|---|---:|---:|---:|---:|---:|---|")
    for r in rows:
        for i, c in enumerate(r["compactions"], 1):
            print("| %s | %d | %s | %s | %s | %s | %s | %d | %s |" % (
                r["session"], i, fmt(c["trigger"]), fmt(c["cli_pre"]), fmt(c["api_before"]),
                fmt(c["api_after"]), fmt(c["gap_s"]), c["batch_est"], c["shape"]))
    print()
    s = summary
    print("ceiling %d, guard threshold %d api; workers %d; compactions %d (steady %d, batch %d, idle %d, manual %d)" % (
        s["ceiling"], s["threshold_api"], s["workers"], s["compactions"],
        s["shapes"]["steady"], s["shapes"]["batch"], s["shapes"]["idle"], s["shapes"]["manual"]))
    print("order: " + ", ".join("%s %d" % kv for kv in s["orders"].items()))
    print("ANSWER: " + s["answer"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
