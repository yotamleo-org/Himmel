#!/usr/bin/env python3
"""scripts/eval/lib/eval_feedback.py - the eval feedback step: a result past its threshold drives one
change, and the next run of the same series re-measures it (HIMMEL-6942).

Reads the eval-runs ledger (eval_runs.py) and the rules in scripts/eval/feedback-rules.json; writes the
eval-changes ledger. Per eval named in the rules, over that eval's newest "ok" row:
  1. MEASURE: every open change of the eval whose baseline row is older and has the same confighash gets
     one "measured" record: before, after, delta and improved | regressed | flat. On a split row the
     verdict is keep | revert instead, by the train/test keep rule below.
  2. CHANGE: per critic (rules without one share the eval's slot), when that row is not yet the baseline
     of a change of that critic, the first rule (file order) with a metric worse than its threshold and no
     open change of the same confighash raises ONE "open" change record for the worst such metric.
     A "learning" change also appends one candidate line to the failure-loop memory inbox
     (the HIMMEL-4670 loop's own learnings queue) when an inbox is given, once per change: each write leaves an
     "inbox" record, and a run given an inbox first delivers every open, unmeasured learning change whose latest
     inbox record is not inbox_written true (one opened without an inbox, or whose write failed).
  A rule reads only a row's tuning metrics. A split row (review-panel seeds, score.py) carries
  open.<metric> and sealed.<metric> beside the whole-set metric; its tuning metrics are the open half,
  unprefixed, so no rule ever sees the sealed half or the whole set that contains it.
  On a split row a metric either half lacks is unmeasured: the rule's absent does not apply.
  Keep rule (split rows): train is the open half, test the sealed half of the baseline and the new row. A
  change is kept only when train and test both gain more than the rule's min_gain and run-to-run noise
  (max - min of the train value over the ok runs of the same confighash up to the baseline, two or more)
  is zero or below min_gain; otherwise it is reverted, and the reason names the first test it failed.

  Path: $HIMMEL_EVAL_CHANGES_LEDGER, else ~/.himmel/eval-changes.jsonl.

RULE  {eval, metric (fnmatch pattern), threshold, better "lower"|"higher", absent (value of a metric the
      row lacks, or null), change "learning"|"routing"|"tool-ruling"|"prompt"|"cr-config"|"impacted-suites",
      target (inbox topic, route, tool or the file the change edits), critic (optional: the measured reviewer),
      per (optional: a metric of the same row; the value judged is metric / per, a rate, so a count that
      grows with volume alone fires nothing), min_gain (optional, default 0: the smallest gain worth keeping)}
CHANGE ROW (v 1): v, ts, host, source, kind "eval-change", id "<baseline run_id>:<metric>", eval, metric,
  status "open" | "measured" | "inbox", then
  open      value, threshold, better, absent, change, target, baseline_run_id, confighash, critic (null: none),
            per, min_gain (null: none)
  measured  before, after, delta, verdict, after_run_id; on a split row also test_before, test_after,
            test_delta, noise, min_gain and reason, with verdict keep | revert
  inbox     inbox_written (true: the line is in the inbox; false: the write failed and is due again)

MERGE GATE (HIMMEL-8426): gate_verdict() grades a critic change from the tracked review-panel results rows;
  it is separate from the keep rule, writes nothing and is called by score.py gate.

  eval_feedback.py run [--eval E]... [--ledger P] [--changes P] [--rules P] [--inbox P]
Prints one line per record written. Exit 0, 2 on unreadable rules.
Stdlib only; no network.
"""
import argparse
import fcntl
import fnmatch
import json
import math
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
KINDS = ("learning", "routing", "tool-ruling", "prompt", "cr-config", "impacted-suites")
SAFE = re.compile(r"^[A-Za-z0-9._:/+-]{1,200}$")


def changes_path(path=None):
    return path or os.environ.get(CHANGES_ENV) or os.path.expanduser("~/.himmel/eval-changes.jsonl")


def load_rules(path=None):
    with open(path or RULES, encoding="utf-8") as fh:
        rules = json.load(fh)["rules"]
    for r in rules:
        if r.get("better") not in ("lower", "higher") or r.get("change") not in KINDS \
                or not eval_runs._num(r.get("threshold")) \
                or ("min_gain" in r and not (eval_runs._num(r["min_gain"]) and r["min_gain"] >= 0)) \
                or ("per" in r and not (isinstance(r["per"], str) and SAFE.match(r["per"]))):
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


def split_view(row, split):
    """One seed half of a split row, unprefixed: open.<m> or sealed.<m> as <m>."""
    pre = split + "."
    return {m[len(pre):]: v for m, v in row["metrics"].items() if m.startswith(pre)}


def is_split(row):
    return any(m.startswith(("open.", "sealed.")) for m in row["metrics"])


def tuning_metrics(row):
    """The metrics a rule may read: the open half of a split row (empty when it ran none), else every metric."""
    return split_view(row, "open") if is_split(row) else row["metrics"]


def rate(metrics, v, per):
    """v, or v / metrics[per] under a rule with per; None when that is not a number above 0."""
    if not per or v is None:
        return v
    d = metrics.get(per)
    return v / d if eval_runs._num(d) and d > 0 else None


def value_of(metrics, metric, absent, per=None):
    v = metrics.get(metric)
    return rate(metrics, v if eval_runs._num(v) else absent, per)


def gain(before, after, better):
    return after - before if better == "higher" else before - after


def keep_rule(c, series, base, new, after):
    """(verdict, fields) of the train/test keep rule for a change measured on split row new."""
    per, min_gain = c.get("per"), c.get("min_gain") or 0
    test_before = value_of(split_view(base, "sealed"), c["metric"], None, per) if base else None
    test_after = value_of(split_view(new, "sealed"), c["metric"], None, per)
    upto = series[:series.index(base) + 1] if base in series else []
    train = [v for v in (value_of(tuning_metrics(r), c["metric"], None, per) for r in upto
                         if r["confighash"] == c["confighash"] and tuning_metrics(r)) if v is not None]
    noise = max(train) - min(train) if len(train) >= 2 else None
    test_delta = None if test_before is None or test_after is None else test_after - test_before
    if test_before is None or test_after is None:
        reason = "test half unmeasured"
    elif gain(c["value"], after, c["better"]) <= min_gain:
        reason = "train not up by more than min gain"
    elif gain(test_before, test_after, c["better"]) <= min_gain:
        reason = "train up, test flat or down"
    elif noise is None:
        reason = "noise unmeasured: under two runs before the change"
    elif not math.isfinite(noise):
        reason = "noise unmeasured: not a finite spread"
    elif noise and noise >= min_gain:
        reason = "noise not below min gain"
    else:
        reason = "train and test up by more than min gain, over the noise"
    finite = lambda x: round(x, 6) if x is not None and math.isfinite(x) else None  # noqa: E731
    return ("keep" if reason.startswith("train and test") else "revert",
            {"test_before": test_before, "test_after": test_after, "test_delta": finite(test_delta),
             "noise": finite(noise), "min_gain": min_gain, "reason": reason})


GATE_RECALL, GATE_FP = "panel.recall_gating", "panel.fp_rate"
GATE_EPS = 1e-9  # float slack: two equal means must compare equal
GATE_STATUS = ("ok", "partial")  # the sweep statuses export-row writes; an inconclusive row never counts


def gate_verdict(rows, base_hash, head_hash, confighash, target_classes=()):
    """(verdict, info) of the merge gate for a critic change (HIMMEL-8426): keep | no-loss | loss | unmeasured.

    Separate from keep_rule, which judges a change record a threshold rule opened; a critic PR has none.
    rows are results.jsonl rows (score.py export-row). The baseline is the rows at base_hash, the head the
    rows at head_hash, both at confighash only: a row of another critic version or another fixture set never
    counts, so it never widens the noise. A side counts one row per sweep: a repeated run_id or outputs
    bundle is dropped, and a head row that repeats a baseline sweep does not count when the hashes differ.
    Under two rows on either side the verdict is unmeasured.
    noise   per metric, max - min over the baseline rows only.
    no-loss head mean recall_gating >= baseline mean - noise, and head mean fp_rate <= baseline mean + noise.
    keep    no-loss, a target class named, and every target class's head mean recall > its baseline max.
    Otherwise loss. Computed at check time, never stored.
    ponytail: the noise is the spread (max - min) of the baseline rows at one hash, which only widens as
    sweeps accrue, upgrade = a dispersion estimate (a standard-error band) once a hash has enough rows (spec P8)."""
    def side(h, skip_ids=(), skip_bundles=()):
        out, ids, bundles = [], set(skip_ids), set(skip_bundles)
        for r in rows:
            m = r.get("metrics") if isinstance(r, dict) else None
            if r.get("cbs_hash") != h or r.get("confighash") != confighash or not isinstance(m, dict) \
                    or r.get("status") not in GATE_STATUS \
                    or not (eval_runs._num(m.get(GATE_RECALL)) and eval_runs._num(m.get(GATE_FP))):
                continue
            if r.get("run_id") in ids or r.get("outputs_sha256") in bundles:
                continue
            ids.add(r.get("run_id"))
            bundles.add(r.get("outputs_sha256"))
            out.append(r)
        return out

    base = side(base_hash)
    head = side(head_hash) if head_hash == base_hash else \
        side(head_hash, {r.get("run_id") for r in base}, {r.get("outputs_sha256") for r in base})
    info = {"baseline_rows": len(base), "head_rows": len(head)}
    if not base or not head:
        where = " and ".join(w for w, rs in (("baseline", base), ("head", head)) if not rs)
        return "unmeasured", dict(info, reason="no eval rows at the %s cbs_hash for confighash %s" % (where, confighash))
    if len(base) < 2 or len(head) < 2:
        return "unmeasured", dict(info, reason="%d baseline and %d head rows: each side needs 2 distinct sweeps"
                                  % (len(base), len(head)))

    def stats(rs, metric):
        vals = [r["metrics"][metric] for r in rs]
        return sum(vals) / len(vals), max(vals) - min(vals)
    (rb, nr), (rh, _) = stats(base, GATE_RECALL), stats(head, GATE_RECALL)
    (fb, nf), (fh, _) = stats(base, GATE_FP), stats(head, GATE_FP)
    info.update({GATE_RECALL: {"baseline": round(rb, 6), "head": round(rh, 6), "noise": round(nr, 6)},
                 GATE_FP: {"baseline": round(fb, 6), "head": round(fh, 6), "noise": round(nf, 6)}})
    lost = [n for n, ok in ((GATE_RECALL, rh >= rb - nr - GATE_EPS), (GATE_FP, fh <= fb + nf + GATE_EPS)) if not ok]
    if lost:
        return "loss", dict(info, reason="worse beyond noise: %s" % ", ".join(lost))
    if not target_classes:
        return "no-loss", dict(info, reason="within noise; no target class named")
    flat = []
    for cls in target_classes:
        hv = [(r.get("class_recall") or {}).get(cls) for r in head]
        bv = [(r.get("class_recall") or {}).get(cls) for r in base]
        if not all(eval_runs._num(v) for v in hv + bv) or not sum(hv) / len(hv) > max(bv) + GATE_EPS:
            flat.append(cls)
    if flat:
        return "no-loss", dict(info, reason="within noise; target class not above the baseline max: %s" % ", ".join(flat))
    return "keep", dict(info, reason="within noise and every target class above the baseline max")


def inbox_line(c):
    if not (SAFE.match(c["eval"]) and SAFE.match(c["metric"]) and re.match(r"^[a-z0-9-]+\.md$", c["target"])):
        return None
    return ("- %s eval/%s %s value=%s threshold=%s topic=%s: candidate line, eval result past its threshold, "
            "re-measured on the next run" % (c["ts"][:10], c["eval"], c["metric"], c["value"], c["threshold"],
                                            c["target"]))


def write_inbox(inbox, line):
    """Append one line to the memory inbox; False when it cannot be written."""
    try:
        os.makedirs(os.path.dirname(os.path.abspath(inbox)), exist_ok=True)
        with open(inbox, "a", encoding="utf-8") as fh:
            fcntl.flock(fh, fcntl.LOCK_EX)
            fh.write(line + "\n")
        return True
    except OSError:
        return False


def run(evals=None, ledger=None, changes=None, rules=None, inbox=None):
    """Measure, then change, for each eval; returns the records written."""
    rules = load_rules(rules)
    path = changes_path(changes)
    runs = [r for r in eval_runs.read_rows(ledger) if r["status"] == "ok"]
    pos = {r["run_id"]: i for i, r in enumerate(runs)}
    by_id = {r["run_id"]: r for r in runs}
    written = []
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        recs = read_changes(path)
        measured = {c["id"] for c in recs if c.get("status") == "measured"}
        opened = [c for c in recs if c.get("status") == "open"]
        if inbox:
            marks = {c["id"]: c["inbox_written"] for c in recs if c.get("status") == "inbox"}
            for c in opened:
                due = c["change"] == "learning" and c["id"] not in measured and marks.get(c["id"]) is not True
                line = inbox_line(c) if due else None
                if line and write_inbox(inbox, line):
                    append(path, envelope(id=c["id"], eval=c["eval"], metric=c["metric"], status="inbox",
                                          inbox_written=True))
        for ev in evals or sorted({r["eval"] for r in rules}):
            series = [r for r in runs if r["eval"] == ev]
            if not series:
                continue
            new = series[-1]
            for c in opened:
                if c["eval"] != ev or c["id"] in measured or c["confighash"] != new["confighash"] \
                        or pos.get(c["baseline_run_id"], len(runs)) >= pos[new["run_id"]]:
                    continue
                tm = tuning_metrics(new)
                after = value_of(tm, c["metric"], None if is_split(new) else c["absent"], c.get("per")) if tm else None
                if after is None:
                    continue
                delta = after - c["value"]
                delta = round(delta, 6) if math.isfinite(delta) else None
                extra = {}
                if is_split(new):
                    verdict, extra = keep_rule(c, series, by_id.get(c["baseline_run_id"]), new, after)
                else:
                    # ponytail: a bare sign test, no noise band; the split rows' keep rule is the upgrade path.
                    verdict = "flat" if delta == 0 else "improved" if worse(c["value"], after, c["better"]) \
                        else "regressed"
                m = envelope(id=c["id"], eval=ev, metric=c["metric"], status="measured", before=c["value"],
                             after=after, delta=delta, verdict=verdict, after_run_id=new["run_id"], **extra)
                append(path, m)
                measured.add(c["id"])
                written.append(m)
            still_open = {c["metric"] for c in opened if c["eval"] == ev and c["id"] not in measured
                          and c["confighash"] == new["confighash"]}
            ev_rules = [r for r in rules if r["eval"] == ev]
            for critic in dict.fromkeys(r.get("critic") for r in ev_rules):
                if any(c["baseline_run_id"] == new["run_id"] and c.get("critic") == critic for c in opened):
                    continue
                tm = tuning_metrics(new)
                for rule in [r for r in ev_rules if r.get("critic") == critic]:
                    vals = [(m, rate(tm, v, rule.get("per"))) for m, v in tm.items()
                            if fnmatch.fnmatchcase(m, rule["metric"]) and eval_runs._num(v) and m not in still_open]
                    hits = [(m, v) for m, v in vals if v is not None and worse(v, rule["threshold"], rule["better"])]
                    if not hits:
                        continue
                    metric, value = sorted(hits, key=lambda h: (h[1] if rule["better"] == "higher" else -h[1],
                                                                h[0]))[0]
                    c = envelope(id="%s:%s" % (new["run_id"], metric), eval=ev, metric=metric, status="open",
                                 value=value, threshold=rule["threshold"], better=rule["better"],
                                 absent=rule.get("absent"), change=rule["change"], target=rule["target"],
                                 baseline_run_id=new["run_id"], confighash=new["confighash"], critic=critic,
                                 per=rule.get("per"), min_gain=rule.get("min_gain"))
                    append(path, c)
                    opened.append(c)
                    written.append(c)
                    line = inbox_line(c) if inbox and rule["change"] == "learning" else None
                    if line:
                        append(path, envelope(id=c["id"], eval=ev, metric=metric, status="inbox",
                                              inbox_written=write_inbox(inbox, line)))
                    break
    return written


def describe(r):
    if r["status"] == "measured":
        s = "measured %s %s before=%s after=%s delta=%s %s" % (r["eval"], r["metric"], r["before"], r["after"],
                                                                r["delta"], r["verdict"])
        if "reason" in r:
            s += " (test %s -> %s, noise %s, min gain %s: %s)" % (r["test_before"], r["test_after"], r["noise"],
                                                                  r["min_gain"], r["reason"])
        return s
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
