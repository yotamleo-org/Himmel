#!/usr/bin/env python3
"""Measure how long a merge takes to reach qmd's keyword index, per merge.

  keyword-lag.py tick --index <index.sqlite> --state <dir>
  keyword-lag.py --report --days N [--half graph] [--state <dir>]

`tick` keeps a cursor over first-parent merges on main that touch a file the
himmel collection indexes. On each call it opens the index read-only and, for
every unconfirmed merge, compares each of the merge's files with the
`documents` table, reading rows with active = 1 only:

  * a file is in when an active row for its path holds the sha256 of its blob
    at the merge or at any later commit that touched it;
  * a file absent at main is in when no active row exists for its path
    (`qmd update` deactivates a vanished file's row, it does not delete it).

When every file is in, one final row goes to keyword-lag.jsonl: merge,
merged_at, first_in_at (the sample's wall time). A merge still unconfirmed 24 h
after merged_at gets a final row with first_in_at null and is not sampled
again. With no cursor the first call seeds it at main and writes no row. Rows
older than 30 days (by merged_at) are trimmed.

`--report` reads a window that ends 24 h before it runs and prints the
denominator, the headline share within the bound with no exclusions, the second
share after dropping the merges whose bound overlaps a period the bound does not
cover, and each share's Wilson 95% interval. `--half graph` prints the same for
the graph half from the post-merge-graph flow rows' from..to range.

Seams: PMR_PRIMARY (the checkout), PMR_NOW (epoch seconds, or a file holding
them), QMD_CONFIG_DIR / XDG_CONFIG_HOME (qmd's index.yml),
HIMMEL_KEYWORD_LAG_LEDGER (the rows file), HIMMEL_FLOW_RUNS_LEDGER (flow rows).
Default rows file: ~/.himmel/state/post-merge-refresh/keyword-lag.jsonl.
Exit: 0 handled, 1 the sampler cannot work, 2 usage.
"""

import calendar
import hashlib
import importlib.util
import json
import os
import socket
import sqlite3
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECTION = "himmel"
LEDGER_NAME = "keyword-lag.jsonl"
KEYWORD_BOUND_SECS = 39 * 60
GRAPH_BOUND_SECS = 45 * 60
UNCONFIRMED_SECS = 24 * 3600
TRIM_SECS = 30 * 86400
GRAPH_SLOW_SECS = 300
GRAPH_FLOOR_SECS = 3600
ZERO_OID = "0" * 40
BLOB_SHA256 = {}


class Refused(Exception):
    pass


def load_module(name, rel):
    path = os.path.join(HERE, rel)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None or not os.path.isfile(path):
        raise Refused("cannot load %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def now_secs():
    raw = os.environ.get("PMR_NOW", "")
    if raw.isdigit():
        return int(raw)
    if raw:
        try:
            with open(raw, encoding="utf-8") as fh:
                return int(fh.read().strip())
        except (OSError, ValueError):
            pass
    return int(time.time())


def iso(secs):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(secs))


def parse_iso(text):
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))


def git(repo, *args, raw=False):
    proc = subprocess.run(["git", "-c", "core.quotepath=off", "-C", repo, *args], capture_output=True)
    if proc.returncode != 0:
        raise Refused("git %s failed: %s" % (" ".join(args[:2]), proc.stderr.decode(errors="replace").strip()))
    return proc.stdout if raw else proc.stdout.decode(errors="replace")


def repo_path():
    env = os.environ.get("PMR_PRIMARY", "")
    if env:
        return env
    common = subprocess.run(["git", "-C", HERE, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True)
    path = common.stdout.strip()
    if common.returncode != 0 or not path:
        raise Refused("no PMR_PRIMARY and no git checkout around %s" % HERE)
    return path[:-5] if path.endswith("/.git") else path


def config_index():
    base = os.environ.get("QMD_CONFIG_DIR") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.path.expanduser("~"), ".config"), "qmd")
    return os.path.join(base, "index.yml")


def collection_filter():
    helper = load_module("qmd_collection_files", os.path.join("..", "lib", "qmd-collection-files.py"))
    try:
        pattern, ignore = helper.read_rules(config_index(), COLLECTION)
        include = helper.glob_regex(pattern)
        excludes = [helper.glob_regex(glob) for glob in ignore]
    except helper.Refused as err:
        raise Refused(str(err))

    def is_indexed(path):
        try:
            return helper.indexed(path, include, excludes)
        except helper.Refused as err:
            raise Refused(str(err))

    return is_indexed


def ledger_path(state):
    return os.environ.get("HIMMEL_KEYWORD_LAG_LEDGER") or os.path.join(state, LEDGER_NAME)


def read_text(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def parse_log(text):
    commits = []
    for line in text.split("\n"):
        if line.startswith("@"):
            sha, _, stamp = line[1:].partition(" ")
            commits.append((sha, int(stamp), []))
        elif line.startswith(":") and commits:
            head, _, path = line.partition("\t")
            fields = head[1:].split()
            if len(fields) == 5 and path:
                commits[-1][2].append((fields[4][0], fields[3], path))
    return commits


def blob_sha256(repo, oid):
    if oid not in BLOB_SHA256:
        BLOB_SHA256[oid] = hashlib.sha256(git(repo, "cat-file", "blob", oid, raw=True)).hexdigest()
    return BLOB_SHA256[oid]


def fold_commits_into_pending(pending, repo, cursor, main, is_indexed):
    commits = parse_log(git(repo, "log", "--first-parent", "-m", "--no-renames", "--raw", "--no-abbrev",
                            "--format=@%H %ct", "%s..%s" % (cursor, main)))
    commits.reverse()
    by_path = {}
    for entry in pending:
        for path in entry["files"]:
            by_path.setdefault(path, []).append(entry)
    folded = {entry["merge"] for entry in pending}
    for sha, stamp, changes in commits:
        if sha in folded:
            continue
        files = {}
        for status, oid, path in changes:
            if not is_indexed(path):
                continue
            present = status != "D"
            for entry in by_path.get(path, []):
                state = entry["files"][path]
                state["present"] = present
                if present:
                    state["oids"].append(oid)
            files[path] = {"present": present, "oids": [oid] if present else []}
        if files:
            entry = {"merge": sha, "merged_at": stamp, "files": files}
            pending.append(entry)
            for path in files:
                by_path.setdefault(path, []).append(entry)


def merge_is_in(entry, active_hash, repo):
    for path, state in entry["files"].items():
        held = active_hash(path)
        if not state["present"]:
            if held is not None:
                return False
        elif held is None or held not in {blob_sha256(repo, oid) for oid in state["oids"]}:
            return False
    return True


def ledger_merges(path):
    merges = set()
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return merges
    for line in lines:
        try:
            merges.add(json.loads(line)["merge"])
        except (ValueError, KeyError, TypeError):
            continue
    return merges


def append_rows(path, rows):
    if not rows:
        return
    known = ledger_merges(path)
    rows = [row for row in rows if row["merge"] not in known]
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, separators=(",", ":")) + "\n")


def trim_rows(path, now):
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return
    lines = [line for line in lines if line]
    if not lines:
        return
    cutoff = now - TRIM_SECS

    def fresh(line):
        try:
            return parse_iso(json.loads(line)["merged_at"]) >= cutoff
        except (ValueError, KeyError, TypeError):
            return True

    if fresh(lines[0]):
        return
    write_atomic(path, "".join(line + "\n" for line in lines if fresh(line)))


def tick(index, state, repo, now):
    os.makedirs(state, exist_ok=True)
    cursor_file = os.path.join(state, "lag.cursor")
    pending_file = os.path.join(state, "lag.pending")
    main = git(repo, "rev-parse", "--verify", "-q", "refs/heads/main").strip()
    cursor = read_text(cursor_file)
    rows_path = ledger_path(state)
    if not cursor:
        write_atomic(cursor_file, main + "\n")
        print("keyword-lag: seeded cursor at main=%s, no row written" % main[:12])
        trim_rows(rows_path, now)
        return 0
    try:
        with open(pending_file, encoding="utf-8") as fh:
            pending = json.load(fh)
    except FileNotFoundError:
        pending = []
    except (OSError, ValueError) as err:
        raise Refused("cannot read %s: %s" % (pending_file, err))
    new = 0
    if cursor != main:
        ancestor = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", cursor, main], capture_output=True)
        if ancestor.returncode == 0:
            before = len(pending)
            fold_commits_into_pending(pending, repo, cursor, main, collection_filter())
            new = len(pending) - before
        else:
            print("keyword-lag: cursor %s is not an ancestor of main, reseeded at main=%s" % (cursor[:12], main[:12]))
        write_atomic(pending_file, json.dumps(pending, separators=(",", ":")) + "\n")
        write_atomic(cursor_file, main + "\n")
    done = []
    keep = []
    expired = [e for e in pending if now - e["merged_at"] >= UNCONFIRMED_SECS]
    live = [e for e in pending if now - e["merged_at"] < UNCONFIRMED_SECS]
    for entry in expired:
        done.append((entry, None))
    if live:
        try:
            con = sqlite3.connect("file:%s?mode=ro" % index, uri=True, timeout=5)
            try:
                def active_hash(path):
                    row = con.execute("SELECT hash FROM documents WHERE collection = ? AND path = ? AND active = 1",
                                      (COLLECTION, path)).fetchone()
                    return row[0] if row else None

                for entry in live:
                    if merge_is_in(entry, active_hash, repo):
                        done.append((entry, now))
                    else:
                        keep.append(entry)
            finally:
                con.close()
        except sqlite3.Error as err:
            raise Refused("cannot read %s: %s" % (index, err))
    host = socket.gethostname()
    rows = [{"v": 1, "ts": iso(now), "host": host, "source": "keyword-lag", "kind": "merge", "merge": e["merge"],
             "merged_at": iso(e["merged_at"]), "first_in_at": iso(at) if at is not None else None} for e, at in done]
    append_rows(rows_path, rows)
    if done:
        write_atomic(pending_file, json.dumps(keep, separators=(",", ":")) + "\n")
    trim_rows(rows_path, now)
    print("keyword-lag: tick cursor=%s new=%d rows=%d pending=%d" % (main[:12], new, len(rows), len(keep)))
    return 0


def read_flow(now):
    path = os.environ.get("HIMMEL_FLOW_RUNS_LEDGER") or os.path.join(os.path.expanduser("~"), ".himmel", "flow-runs.jsonl")
    starts, runs = {}, []
    try:
        with open(path, encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        return runs
    for line in lines:
        try:
            row = json.loads(line)
            if row["ev"] == "start":
                starts[row["run_id"]] = (row["flow"], parse_iso(row["fired_at"]))
            elif row["ev"] == "end" and row["run_id"] in starts:
                flow, began = starts.pop(row["run_id"])
                runs.append({"flow": flow, "start": began, "end": parse_iso(row["ended_at"]),
                             "ok": row["exit_code"] == 0, "note": row.get("note")})
        except (ValueError, KeyError, TypeError):
            continue
    for flow, began in starts.values():
        runs.append({"flow": flow, "start": began, "end": now, "ok": None, "note": None})
    runs.sort(key=lambda r: r["end"])
    return runs


def failure_streaks(runs, flow, now):
    streaks, opened = [], None
    for run in runs:
        if run["flow"] != flow or run["ok"] is None:
            continue
        if not run["ok"] and opened is None:
            opened = run["end"]
        elif run["ok"] and opened is not None:
            streaks.append((opened, run["end"]))
            opened = None
    if opened is not None:
        streaks.append((opened, now))
    return streaks


def overlaps(span, merged_at, bound):
    return span[0] <= merged_at + bound and span[1] >= merged_at


def print_lines(title, bound_mins, merges, drop_rules, days, end):
    wilson = load_module("wilson", os.path.join("..", "eval", "lib", "wilson.py")).wilson
    bound = bound_mins * 60

    def share(items):
        hit = sum(1 for _, lag in items if lag is not None and lag <= bound)
        return hit, len(items)

    def render(hit, total):
        if not total:
            return "0/0 = n/a", "n/a"
        interval = wilson(hit, total)
        return "%d/%d = %.4f" % (hit, total, hit / total), "%.4f to %.4f" % (interval["lo"], interval["hi"])

    dropped = {name: 0 for name, _ in drop_rules}
    kept = []
    for merged_at, lag in merges:
        for name, test in drop_rules:
            if test(merged_at, bound):
                dropped[name] += 1
                break
        else:
            kept.append((merged_at, lag))
    print("%s: window %dd, ending %s (24 h before now)" % (title, days, iso(end)))
    print("denominator: %d" % len(merges))
    text, interval = render(*share(merges))
    print("headline: %s within %d min (no exclusions); wilson95 %s" % (text, bound_mins, interval))
    text, interval = render(*share(kept))
    print("second: %s within %d min after drops; wilson95 %s" % (text, bound_mins, interval))
    print("dropped: " + " ".join("%s=%d" % (name, count) for name, count in dropped.items()))


def report(days, half, state, now):
    end = now - UNCONFIRMED_SECS
    start = end - days * 86400
    runs = read_flow(now)

    def spans(flow):
        return [(r["start"], r["end"]) for r in runs if r["flow"] == flow]

    reindex = spans("qmd-reindex")
    if half == "graph":
        repo = repo_path()
        merges = {}
        for line in git(repo, "log", "--first-parent", "--format=%H %ct", "--since=@%d" % (start - 86400), "refs/heads/main").split("\n"):
            if line:
                sha, _, stamp = line.partition(" ")
                if start <= int(stamp) <= end:
                    merges[sha] = [int(stamp), None]
        for run in runs:
            if run["flow"] != "post-merge-graph" or not run["ok"] or not run["note"] or ".." not in run["note"]:
                continue
            lo, _, hi = run["note"].partition("..")
            try:
                covered = git(repo, "rev-list", "--first-parent", "%s..%s" % (lo, hi)).split()
            except Refused:
                continue
            for sha in covered:
                if sha in merges:
                    lag = run["end"] - merges[sha][0]
                    if merges[sha][1] is None or lag < merges[sha][1]:
                        merges[sha][1] = lag
        floors = [(r["start"], r["start"] + GRAPH_FLOOR_SECS) for r in runs
                  if r["flow"] == "post-merge-graph" and r["ok"] and r["end"] - r["start"] > GRAPH_SLOW_SECS]
        rules = [("reindex", lambda at, b: any(overlaps(s, at, b) for s in reindex)),
                 ("failure_streak", lambda at, b: any(overlaps(s, at, b) for s in failure_streaks(runs, "post-merge-graph", now))),
                 ("slow_floor", lambda at, b: any(overlaps(s, at, b) for s in floors))]
        print_lines("graph-lag report", GRAPH_BOUND_SECS // 60, sorted((v[0], v[1]) for v in merges.values()), rules, days, end)
        return 0
    merges = []
    try:
        with open(ledger_path(state), encoding="utf-8") as fh:
            lines = fh.read().split("\n")
    except OSError:
        lines = []
    for line in lines:
        try:
            row = json.loads(line)
            merged_at = parse_iso(row["merged_at"])
            first = row["first_in_at"]
            lag = parse_iso(first) - merged_at if first else None
        except (ValueError, KeyError, TypeError):
            continue
        if start <= merged_at <= end:
            merges.append((merged_at, lag))
    final = ledger_merges(ledger_path(state))
    try:
        with open(os.path.join(state, "lag.pending"), encoding="utf-8") as fh:
            pending = json.load(fh)
    except (OSError, ValueError):
        pending = []
    for entry in pending:
        if entry["merge"] not in final and start <= entry["merged_at"] <= end:
            merges.append((entry["merged_at"], None))
    merges.sort()
    streaks = failure_streaks(runs, "post-merge-keyword", now)
    rules = [("reindex", lambda at, b: any(overlaps(s, at, b) for s in reindex)),
             ("failure_streak", lambda at, b: any(overlaps(s, at, b) for s in streaks))]
    print_lines("keyword-lag report", KEYWORD_BOUND_SECS // 60, merges, rules, days, end)
    return 0


def usage():
    print("usage: keyword-lag.py tick --index <index.sqlite> --state <dir>\n"
          "       keyword-lag.py --report --days N [--half graph] [--state <dir>]", file=sys.stderr)
    return 2


def flag_values(args, names):
    values, rest = {}, list(args)
    while rest:
        flag = rest.pop(0)
        if flag == "--report" and "--report" in names:
            values[flag] = True
        elif flag in names and rest:
            values[flag] = rest.pop(0)
        else:
            return None
    return values


def main(argv):
    if argv and argv[0] == "tick":
        opts = flag_values(argv[1:], {"--index", "--state"})
        if not opts or "--index" not in opts or "--state" not in opts:
            return usage()
        try:
            return tick(opts["--index"], opts["--state"], repo_path(), now_secs())
        except Refused as err:
            print("keyword-lag: ERR %s" % err, file=sys.stderr)
            return 1
    opts = flag_values(argv, {"--report", "--days", "--half", "--state"})
    if not opts or "--report" not in opts or not opts.get("--days", "").isdigit() or int(opts["--days"]) < 1:
        return usage()
    if opts.get("--half", "graph") != "graph":
        return usage()
    state = opts.get("--state") or os.path.join(os.path.expanduser("~"), ".himmel", "state", "post-merge-refresh")
    try:
        return report(int(opts["--days"]), opts.get("--half"), state, now_secs())
    except Refused as err:
        print("keyword-lag: ERR %s" % err, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
