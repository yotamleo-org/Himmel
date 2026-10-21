#!/usr/bin/env python3
"""scripts/eval/lib/eval_feedback.py - the eval feedback step: a result past its threshold drives one
change, and the next run of the same series re-measures it (HIMMEL-6942).

Reads the eval-runs ledger (eval_runs.py) and the rules in scripts/eval/feedback-rules.json; writes the
eval-changes ledger. Per eval named in the rules, over that eval's newest "ok" row:
  1. MEASURE: every open change of the eval whose baseline row is older and has the same confighash gets
     one "measured" record: before, after, delta and improved | regressed | flat.
  2. CHANGE: when that row is not yet the baseline of any change, the first rule (file order) with a
     metric worse than its threshold and no open change of the same confighash raises ONE "open" change
     record for the worst such metric. A "learning" change also appends one candidate line to the failure-loop memory inbox
     (the HIMMEL-4670 loop's own learnings queue) when an inbox is given.

  Path: $HIMMEL_EVAL_CHANGES_LEDGER, else ~/.himmel/eval-changes.jsonl.

RULE  {eval, metric (fnmatch pattern), threshold, better "lower"|"higher", absent (value of a metric the
      row lacks, or null), change "learning"|"routing"|"tool-ruling", target (inbox topic, route or tool)}
CHANGE ROW (v 1): v, ts, host, source, kind "eval-change", id "<baseline run_id>:<metric>", eval, metric,
  status "open" | "measured", then
  open      value, threshold, better, absent, change, target, baseline_run_id, confighash
  measured  before, after, delta, verdict, after_run_id

  eval_feedback.py run [--eval E]... [--ledger P] [--changes P] [--rules P] [--inbox P]
Prints one line per record written. Exit 0, 2 on unreadable rules.
Stdlib only; no network.
"""
import argparse
import fcntl
import fnmatch
import json
import os
import re
import socket
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import eval_runs  # noqa: E402

CHANGES_ENV = "HIMMEL_EVAL_CHANGES_LEDGER"
RULES = os.path.join(HERE, "..", "feedback-rules.json")
SOURCE = "scripts/eval/lib/eval_feedback.py"
KINDS = ("learning", "routing", "tool-ruling")
SAFE = re.compile(r"^[A-Za-z0-9._:/+-]{1,200}$")


def changes_path(path=None):
    return path or os.environ.get(CHANGES_ENV) or os.path.expanduser("~/.himmel/eval-changes.jsonl")


def load_rules(path=None):
    with open(path or RULES, encoding="utf-8") as fh:
        rules = json.load(fh)["rules"]
    for r in rules:
        if r.get("better") not in ("lower", "higher") or r.get("change") not in KINDS \
                or not eval_runs._num(r.get("threshold")):
            raise ValueError("bad rule: %s" % json.dumps(r, sort_keys=True))
    return rules


def read_changes(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return [json.loads(ln) for ln in fh if ln.strip()]
    except FileNotFoundError:
        return []


def append(path, row):
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    line = (json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def envelope(**kw):
    return dict({"v": 1, "ts": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "host": socket.gethostname(), "source": SOURCE, "kind": "eval-change"}, **kw)


def worse(value, threshold, better):
    return value > threshold if better == "lower" else value < threshold


def value_of(row, metric, absent):
    v = row["metrics"].get(metric)
    return v if eval_runs._num(v) else absent


def inbox_line(c):
    if not (SAFE.match(c["eval"]) and SAFE.match(c["metric"]) and re.match(r"^[a-z0-9-]+\.md$", c["target"])):
        return None
    return ("- %s eval/%s %s value=%s threshold=%s topic=%s: candidate line, eval result past its threshold, "
            "re-measured on the next run" % (c["ts"][:10], c["eval"], c["metric"], c["value"], c["threshold"],
                                            c["target"]))


def run(evals=None, ledger=None, changes=None, rules=None, inbox=None):
    """Measure, then change, for each eval; returns the records written."""
    rules = load_rules(rules)
    path = changes_path(changes)
    runs = [r for r in eval_runs.read_rows(ledger) if r["status"] == "ok"]
    pos = {r["run_id"]: i for i, r in enumerate(runs)}
    written = []
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        recs = read_changes(path)
        measured = {c["id"] for c in recs if c.get("status") == "measured"}
        opened = [c for c in recs if c.get("status") == "open"]
        for ev in evals or sorted({r["eval"] for r in rules}):
            series = [r for r in runs if r["eval"] == ev]
            if not series:
                continue
            new = series[-1]
            for c in opened:
                if c["eval"] != ev or c["id"] in measured or c["confighash"] != new["confighash"] \
                        or pos.get(c["baseline_run_id"], len(runs)) >= pos[new["run_id"]]:
                    continue
                after = value_of(new, c["metric"], c["absent"])
                if after is None:
                    continue
                delta = round(after - c["value"], 6)
                # ponytail: a bare sign test, no noise band; eval-compare's bands/CI are the upgrade path.
                verdict = "flat" if delta == 0 else "improved" if worse(c["value"], after, c["better"]) else "regressed"
                m = envelope(id=c["id"], eval=ev, metric=c["metric"], status="measured", before=c["value"],
                             after=after, delta=delta, verdict=verdict, after_run_id=new["run_id"])
                append(path, m)
                measured.add(c["id"])
                written.append(m)
            if any(c["baseline_run_id"] == new["run_id"] for c in opened):
                continue
            still_open = {c["metric"] for c in opened if c["eval"] == ev and c["id"] not in measured
                          and c["confighash"] == new["confighash"]}
            for rule in [r for r in rules if r["eval"] == ev]:
                hits = [(m, v) for m, v in new["metrics"].items() if fnmatch.fnmatchcase(m, rule["metric"])
                        and eval_runs._num(v) and m not in still_open and worse(v, rule["threshold"], rule["better"])]
                if not hits:
                    continue
                metric, value = sorted(hits, key=lambda h: (h[1] if rule["better"] == "higher" else -h[1], h[0]))[0]
                c = envelope(id="%s:%s" % (new["run_id"], metric), eval=ev, metric=metric, status="open",
                             value=value, threshold=rule["threshold"], better=rule["better"],
                             absent=rule.get("absent"), change=rule["change"], target=rule["target"],
                             baseline_run_id=new["run_id"], confighash=new["confighash"])
                append(path, c)
                opened.append(c)
                written.append(c)
                line = inbox_line(c) if inbox and rule["change"] == "learning" else None
                if line:
                    os.makedirs(os.path.dirname(os.path.abspath(inbox)), exist_ok=True)
                    with open(inbox, "a", encoding="utf-8") as fh:
                        fcntl.flock(fh, fcntl.LOCK_EX)
                        fh.write(line + "\n")
                break
    return written


def describe(r):
    if r["status"] == "measured":
        return "measured %s %s before=%s after=%s delta=%s %s" % (r["eval"], r["metric"], r["before"], r["after"],
                                                                   r["delta"], r["verdict"])
    return "change %s %s value=%s threshold=%s %s -> %s" % (r["eval"], r["metric"], r["value"], r["threshold"],
                                                           r["change"], r["target"])


def main(argv=None):
    ap = argparse.ArgumentParser(prog="eval_feedback.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--eval", action="append")
    for f in ("--ledger", "--changes", "--rules", "--inbox"):
        r.add_argument(f)
    a = ap.parse_args(argv)
    try:
        recs = run(a.eval, a.ledger, a.changes, a.rules, a.inbox)
    except (OSError, ValueError, KeyError) as e:
        print("eval-feedback: %s" % e, file=sys.stderr)
        return 2
    for rec in recs:
        print("eval-feedback: %s" % describe(rec))
    return 0


if __name__ == "__main__":
    sys.exit(main())
