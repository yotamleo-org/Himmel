#!/usr/bin/env python3
"""scripts/eval/lib/eval_feedback.py - the eval feedback step: a result past its threshold drives one
change, and the next run of the same series re-measures it (HIMMEL-6942).

Reads the eval-runs ledger (eval_runs.py) and the rules in scripts/eval/feedback-rules.json; writes the
eval-changes ledger. Per eval named in the rules, over that eval's newest "ok" row:
  1. MEASURE: every open change of the eval whose baseline row is older and has the same confighash gets
     one "measured" record: before, after, delta and improved | regressed | flat. On a split row the
     verdict is keep | revert instead, by the train/test keep rule below.
     A review-panel change is measured only through its application receipt (apply-review, below): the newest
     execution must run the receipt's after cbs_hash (computed from Git at its code_under_test_sha) and its
     execution must post-date applied_at (the ts of its earliest row, so a later rescore keeps its execution's
     time; a revision whose source row is absent has no known time). That execution is then compared with the
     proposal's baseline execution: it must run the receipt's before cbs_hash and pass review_incompat, and both
     must be split rows; otherwise the verdict is inconclusive, with the reason. Without a receipt the change stays
     proposed. A rescore of an execution from before the application is never a treatment result.
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
  status "open" | "applied" | "measured" | "inbox", then
  open      value, threshold, better, absent, change, target, baseline_run_id, confighash, critic (null: none),
            per, min_gain (null: none)
  applied   (review-panel only) applied_at (the receipt's own ts), before_cbs_hash, after_cbs_hash, commit,
            target_paths (the critic behaviour paths the commit changed), diff_sha256 (over those paths' raw
            diff-tree records), all derived from Git
  measured  before, after, delta, verdict, after_run_id; on a split row also test_before, test_after,
            test_delta, noise, min_gain and reason, with verdict keep | revert; a review-panel record also
            applied_commit and after_cbs_hash, with verdict keep | revert | inconclusive
  inbox     inbox_written (true: the line is in the inbox; false: the write failed and is due again)

APPLY-REVIEW: apply_review() writes one review-panel change's applied receipt for ONE application commit with one
  parent. The parent's and the commit's cbs_hash (score.py, cbs.txt) and the target paths come from Git, never from
  the caller. Refused: no open change of that id, a change of another eval, one already applied or measured, a
  commit that is not in the repo, a root or merge commit, a target outside the measured behaviour set (a CodeRabbit
  config treatment needs a later protocol), identical before and after cbs_hash, a commit that does not change the
  proposal's target. It runs no git operation that writes, and neither do keep and revert: they are
  recommendations.

MERGE GATE (HIMMEL-8426): gate_verdict() grades a critic change from the tracked review-panel results rows;
  it is separate from the keep rule, writes nothing and is called by score.py gate.

  eval_feedback.py run [--eval E]... [--ledger P] [--changes P] [--rules P] [--inbox P] [--repo DIR]
  eval_feedback.py apply-review --id ID --commit SHA --changes P [--repo DIR]
--repo is the git checkout the commits are read from, else this script's own. Prints one line per record
written. Exit 0, 2 on unreadable rules or a refused application.
Stdlib only; no network.
"""
import argparse
import fcntl
import fnmatch
import hashlib
import json
import math
import os
import re
import socket
import subprocess
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
GATE_STATUS = ("ok",)  # a partial sweep scores fewer cases, so like an inconclusive one it never counts
HEX64 = re.compile(r"^[0-9a-f]{64}$")


def row_field(r, name):
    """A review-panel row's field, whether the row is a results.jsonl row (flat) or an eval-runs row (meta)."""
    if name in r:
        return r[name]
    meta = r.get("meta")
    return meta.get(name) if isinstance(meta, dict) else None


def known_scorer(r):
    """The row's scorer_sha256 when it is a valid 64-hex digest, else None."""
    s = row_field(r, "scorer_sha256")
    return s if isinstance(s, str) and HEX64.match(s) else None


def select_review_runs(rows, scorer=None, eligible_only=False):
    """(selected, diagnostics): the one review-panel row selector that gate, eval-compare, the review page, the
    feedback step and the public page read. Rows are results rows or eval-runs rows of one eval, in file order;
    the selection is in execution order (a rescore sits at its source execution's place, not where it was appended).

    Rows of one execution (the same execution_id, the same legacy raw-output hash outputs_sha256, or the same
    run_id) are ONE model execution, however many scoring revisions it has: only a revision chain's head is
    selected, so a rescore is never a repeat, a baseline or a previous run. A revision names its predecessor in
    supersedes_run_id. An execution is selected only when its chain is unambiguous: a cycle, a successor of an
    unknown run beside other rows of the execution, or two heads (a fork) selects nothing of it and is named in
    the diagnostics (a lone row whose predecessor is not in rows, one promoted without its source, stands). Rows with no
    link at all keep the legacy rule: the first row of the execution counts, the rest are repeats of it.
    scorer (a 64-hex digest): of the selected heads only those scored by it stay, so a missing or older scorer
    never matches. eligible_only drops a head whose decision_eligible is false, naming its reasons; a row that
    carries no decision_eligible keeps its legacy standing. Each diagnostic is {run_id, reason, ...}; a row
    that lost to another carries `by`, the selected run_id."""
    rows = [r for r in rows if isinstance(r, dict)]
    parent = list(range(len(rows)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    def sid(v):
        return v if isinstance(v, str) and v else None  # a non-string id (a list, a number) names nothing
    rid = lambda i: sid(rows[i].get("run_id")) or "\0row%d" % i  # noqa: E731
    seen = {}
    for i, r in enumerate(rows):
        for key in (("x", sid(row_field(r, "execution_id"))), ("b", sid(r.get("outputs_sha256"))),
                    ("r", sid(r.get("run_id"))), ("r", sid(row_field(r, "supersedes_run_id")))):
            if key[1] is None:
                continue
            j = seen.setdefault(key, i)
            parent[find(i)] = find(j)
    groups = {}
    for i in range(len(rows)):
        groups.setdefault(find(i), []).append(i)
    diag, heads = [], []
    for members in groups.values():
        first = {}
        for i in members:
            first.setdefault(rid(i), i)
        dup = [i for i in members if first[rid(i)] != i]
        uniq = [i for i in members if i not in dup]
        by_id = {rid(i): i for i in uniq}
        links = {i: sid(row_field(rows[i], "supersedes_run_id")) for i in uniq}
        linked = [i for i in uniq if links[i] is not None]
        who = rid
        if len(uniq) == 1 or not linked:
            mine = [i for i in members if scorer is not None and known_scorer(rows[i]) == scorer]
            head = (mine or uniq)[0]
            diag.extend({"run_id": rows[i].get("run_id"), "reason": "repeat-of-execution",
                         "by": rows[head].get("run_id")} for i in members if i != head)
            heads.append((min(members), head))
            continue
        bad = [i for i in linked if links[i] not in by_id or links[i] == who(i)]
        targets = [links[i] for i in linked if i not in bad]
        successors = {}
        for i in linked:
            successors.setdefault(links[i], []).append(i)
        fork = sorted(t for t, s in successors.items() if len(s) > 1)
        tops = [i for i in uniq if who(i) not in targets]
        why = None
        if bad:
            why = "supersedes-unknown-run"
        elif fork:
            why = "two-successors-ambiguous"
        elif len(tops) != 1:
            why = "supersession-cycle" if not tops else "several-heads-ambiguous"
        else:
            walk, cur = set(), who(tops[0])
            while cur is not None and why is None:
                if cur in walk:
                    why = "supersession-cycle"
                walk.add(cur)
                cur = links[by_id[cur]]
            if why is None and len(walk) != len(uniq):
                why = "several-heads-ambiguous"
        if why:
            diag.extend({"run_id": rows[i].get("run_id"), "reason": why} for i in members)
            continue
        head = tops[0]
        diag.extend({"run_id": rows[i].get("run_id"), "reason": "superseded", "by": rows[head].get("run_id")}
                    for i in members if i != head)
        heads.append((min(members), head))
    out = []
    for _, i in sorted(heads):
        r = rows[i]
        if scorer is not None and known_scorer(r) != scorer:
            diag.append({"run_id": r.get("run_id"),
                         "reason": "other-scorer" if row_field(r, "scorer_sha256") else "without-scorer-sha256"})
        elif eligible_only and row_field(r, "decision_eligible") is False:
            diag.append({"run_id": r.get("run_id"), "reason": "not-decision-eligible",
                         "detail": row_field(r, "ineligibility_reasons") or []})
        else:
            out.append(r)
    return out, diag


def review_incompat(a, b):
    """Why two review-panel eval-runs rows cannot be compared, or None: another corpus/protocol/roster (the
    confighash), a scorer that is not the same known digest, or unequal or unrecorded participation."""
    if a.get("confighash") != b.get("confighash"):
        return "confighash %s vs %s: another corpus, protocol or roster" % (a.get("confighash"), b.get("confighash"))
    sa, sb = known_scorer(a), known_scorer(b)
    if sa is None or sa != sb:
        return "scorer_sha256 %s vs %s: not the same known scorer" % ((sa or "unknown")[:12], (sb or "unknown")[:12])
    ca, cb = row_field(a, "coverage"), row_field(b, "coverage")
    if not isinstance(ca, dict) or not isinstance(cb, dict):
        return "participation unrecorded on one side"
    if ca != cb:
        return "participation differs: the critics did not answer the same cases"
    return None


def review_series(rows, **kw):
    """rows with its review-panel rows replaced by select_review_runs' selection, in execution order, and the
    diagnostics; rows of any other eval pass through unchanged."""
    sel, diag = select_review_runs([r for r in rows if r.get("eval") == "review-panel"], **kw)
    keep, order, out = {id(r) for r in sel}, iter(sel), []
    for r in rows:
        if r.get("eval") != "review-panel":
            out.append(r)
        elif id(r) in keep:
            out.append(next(order))
    return out, diag


REVIEW = "review-panel"
SHA = re.compile(r"^[0-9a-f]{7,64}$")


def _score():
    d = os.path.join(HERE, "..", "review-panel")
    if d not in sys.path:
        sys.path.insert(0, d)
    import score
    return score


def commit_of(repo, rev):
    """The full sha of commit rev in repo, or None; rev must be hex, so it is never an option or a ref name."""
    if not isinstance(rev, str) or not SHA.match(rev):
        return None
    r = subprocess.run(["git", "-C", repo, "rev-parse", "--verify", "--quiet", rev + "^{commit}"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def changed_paths(repo, parent, commit):
    """{path: its raw diff-tree record (modes, blob ids, status)} for each file commit changes against parent."""
    raw = _score()._git(repo, "diff-tree", "-r", "-z", "--no-renames", "--no-abbrev", parent, commit)
    parts = raw.decode("utf-8", "surrogateescape").split("\0")
    return {path: meta.lstrip(":") for meta, path in zip(parts[0::2], parts[1::2])}


def apply_review(cid, commit, changes, repo=None):
    """Append the applied receipt of review-panel change cid for one application commit and return it; ValueError
    when refused (APPLY-REVIEW above). repo: the checkout the commit is read from, else this script's own."""
    if not changes:
        raise ValueError("refused: name the changes ledger explicitly")
    score = _score()
    repo = repo or score.toplevel()
    os.makedirs(os.path.dirname(os.path.abspath(changes)), exist_ok=True)
    with open(changes + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        recs = [c for c in read_changes(changes) if isinstance(c, dict)]
        prop = next((c for c in recs if c.get("status") == "open" and c.get("id") == cid), None)
        if prop is None:
            raise ValueError("refused: no open change %s in %s" % (cid, changes))
        if prop.get("eval") != REVIEW:
            raise ValueError("unsupported: an application receipt binds a review-panel change only; %s is a %s change"
                             % (cid, prop.get("eval")))
        if any(c.get("id") == cid and c.get("status") in ("applied", "measured") for c in recs):
            raise ValueError("refused: %s is already applied or measured" % cid)
        sha = commit_of(repo, commit)
        if sha is None:
            raise ValueError("refused: %s is not a commit in %s" % (commit, repo))
        parents = score._git(repo, "rev-list", "--parents", "-n", "1", sha).decode().split()[1:]
        if len(parents) != 1:
            raise ValueError("unsupported: commit %s has %s; a receipt binds one application commit with one parent"
                             % (sha[:12], "%d parents" % len(parents) if parents else "no parent"))
        parent = parents[0]
        behaviour = set(score.cbs_paths(repo, parent)) | set(score.cbs_paths(repo, sha))
        target = prop.get("target")
        if target not in behaviour:
            raise ValueError("unsupported: the target %s is outside the measured behaviour set (cbs.txt)" % target)
        before, after = score.cbs_hash(repo, parent), score.cbs_hash(repo, sha)
        if before == after:
            raise ValueError("refused: no effective change: commit %s leaves cbs_hash %s as it was"
                             % (sha[:12], before[:12]))
        diff = changed_paths(repo, parent, sha)
        if target not in diff:
            raise ValueError("refused: commit %s does not change the proposal's target %s" % (sha[:12], target))
        paths = sorted(p for p in diff if p in behaviour)
        canon = "".join("%s\t%s\n" % (diff[p], p) for p in paths).encode("utf-8", "surrogateescape")
        rec = envelope(id=cid, eval=REVIEW, metric=prop.get("metric"), status="applied")
        rec.update(applied_at=rec["ts"], before_cbs_hash=before, after_cbs_hash=after, commit=sha, target_paths=paths,
                   diff_sha256=hashlib.sha256(canon).hexdigest())
        append(changes, rec)
    return rec


def measure_review(c, receipt, series, base, new, when, cbs_of):
    """The measured record of review-panel change c on its newest execution new, or None while c stays proposed (no
    receipt) or awaits a measurement (new does not run the applied version, or did not run after applied_at).
    when: new's execution time; cbs_of(row): the cbs_hash of the row's code_under_test_sha, None when unknown."""
    after_hash, at = (receipt or {}).get("after_cbs_hash"), (receipt or {}).get("applied_at")
    if not isinstance(after_hash, str) or not isinstance(at, str) or cbs_of(new) != after_hash \
            or when is None or when <= at:
        return None
    bound = {"applied_commit": receipt.get("commit"), "after_cbs_hash": after_hash}
    if cbs_of(base) != receipt.get("before_cbs_hash"):
        why = "the baseline execution is not at the receipt's parent cbs_hash"
    else:
        why = review_incompat(base, new)
    if why is None and not (is_split(base) and is_split(new)):
        why = "no train/test split on both runs: the keep rule cannot run"
    before = after = None
    if why is None:
        before = value_of(tuning_metrics(base), c["metric"], None, c.get("per"))
        after = value_of(tuning_metrics(new), c["metric"], None, c.get("per"))
        if before is None or after is None:
            why = "the metric is unmeasured on the baseline or the applied run"
    if why:
        return envelope(id=c["id"], eval=REVIEW, metric=c["metric"], status="measured", before=before, after=after,
                        delta=None, verdict="inconclusive", after_run_id=new["run_id"], reason=why, **bound)
    verdict, extra = keep_rule(dict(c, value=before), series, base, new, after)
    delta = after - before
    return envelope(id=c["id"], eval=REVIEW, metric=c["metric"], status="measured", before=before, after=after,
                    delta=round(delta, 6) if math.isfinite(delta) else None, verdict=verdict,
                    after_run_id=new["run_id"], **dict(extra, **bound))


def _hashable(v):
    """v as a set member: a list or object from a hand-edited row becomes its JSON text, never a TypeError."""
    return v if v is None or isinstance(v, (str, int, float, bool)) else json.dumps(v, sort_keys=True)


def gate_side(rows, h, confighash, skip_ids=(), skip_bundles=()):
    """The rows the gate counts for cbs_hash h: that confighash, a counted status and the two gate metrics, the
    first row of a run_id or raw-output bundle. Returns (rows, run_ids, bundles)."""
    out, ids, bundles = [], set(skip_ids), set(skip_bundles)
    for r in rows:
        m = r.get("metrics") if isinstance(r, dict) else None
        if r.get("cbs_hash") != h or r.get("confighash") != confighash or not isinstance(m, dict) \
                or r.get("status") not in GATE_STATUS \
                or not (eval_runs._num(m.get(GATE_RECALL)) and eval_runs._num(m.get(GATE_FP))):
            continue
        rk, bk = _hashable(r.get("run_id")), _hashable(r.get("outputs_sha256"))
        if rk in ids or bk in bundles:
            continue
        ids.add(rk)
        bundles.add(bk)
        out.append(r)
    return out, ids, bundles


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
    base, base_ids, base_bundles = gate_side(rows, base_hash, confighash)
    head = base if head_hash == base_hash else gate_side(rows, head_hash, confighash, base_ids, base_bundles)[0]
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


def run(evals=None, ledger=None, changes=None, rules=None, inbox=None, repo=None):
    """Measure, then change, for each eval; returns the records written. repo: the checkout a review-panel
    execution's code_under_test_sha is read from, else this script's own (read only when a receipt exists)."""
    rules = load_rules(rules)
    path = changes_path(changes)
    all_rows = eval_runs.read_rows(ledger)
    chosen, diag = review_series(all_rows)
    runs = [r for r in chosen if r["status"] == "ok"]
    alias = {d["run_id"]: d["by"] for d in diag if d.get("by")}
    first_ts = {}
    for r in all_rows:
        rid, t = r.get("run_id"), r.get("ts")
        if r.get("eval") == REVIEW and isinstance(rid, str) and isinstance(t, str):
            first_ts[rid] = min(t, first_ts.get(rid, t))
    members = {}
    for rid, by in alias.items():
        if isinstance(rid, str):
            members.setdefault(by, set()).add(rid)

    def started(r):
        if row_field(r, "supersedes_run_id") and not members.get(r["run_id"]):
            return None
        known = [first_ts[i] for i in members.get(r["run_id"], set()) | {r["run_id"]} if i in first_ts]
        return min(known) if known else None
    cbs_cache = {}

    def cbs_of(r):
        code = row_field(r, "code_under_test_sha") or r.get("tree")
        if not isinstance(code, str):
            return None
        if code not in cbs_cache:
            score = _score()
            where = repo or score.toplevel()
            sha = commit_of(where, code)
            cbs_cache[code] = score.cbs_hash(where, sha) if sha else None
        return cbs_cache[code]
    pos = {r["run_id"]: i for i, r in enumerate(runs)}
    by_id = {r["run_id"]: r for r in runs}
    pos.update({rid: pos[by] for rid, by in alias.items() if by in pos})
    by_id.update({rid: by_id[by] for rid, by in alias.items() if by in by_id})
    written = []
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        recs = read_changes(path)
        measured = {c["id"] for c in recs if c.get("status") == "measured"}
        opened = [c for c in recs if c.get("status") == "open"]
        applied = {}
        for c in recs:
            if c.get("status") == "applied" and isinstance(c.get("id"), str):
                applied.setdefault(c["id"], c)
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
                if c["eval"] != ev or c["id"] in measured \
                        or (ev != REVIEW and c["confighash"] != new["confighash"]) \
                        or pos.get(c["baseline_run_id"], len(runs)) >= pos[new["run_id"]]:
                    continue
                if ev == REVIEW:
                    m = measure_review(c, applied.get(c["id"]), series, by_id[c["baseline_run_id"]], new,
                                       started(new), cbs_of)
                    if m is not None:
                        append(path, m)
                        measured.add(c["id"])
                        written.append(m)
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
                if any(alias.get(c["baseline_run_id"], c["baseline_run_id"]) == new["run_id"]
                       and c.get("critic") == critic for c in opened):
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
    if r["status"] == "applied":
        return "applied %s %s commit %s cbs_hash %s -> %s paths %s" % (
            r["eval"], r["metric"], r["commit"][:12], r["before_cbs_hash"][:12], r["after_cbs_hash"][:12],
            ",".join(r["target_paths"]))
    if r["status"] == "measured":
        s = "measured %s %s before=%s after=%s delta=%s %s" % (r["eval"], r["metric"], r["before"], r["after"],
                                                                r["delta"], r["verdict"])
        if "test_before" in r:
            s += " (test %s -> %s, noise %s, min gain %s: %s)" % (r["test_before"], r["test_after"], r["noise"],
                                                                  r["min_gain"], r["reason"])
        elif "reason" in r:
            s += " (%s)" % r["reason"]
        return s
    return "change %s %s value=%s threshold=%s %s -> %s" % (r["eval"], r["metric"], r["value"], r["threshold"],
                                                           r["change"], r["target"])


def main(argv=None):
    ap = argparse.ArgumentParser(prog="eval_feedback.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--eval", action="append")
    for f in ("--ledger", "--changes", "--rules", "--inbox", "--repo"):
        r.add_argument(f)
    ar = sub.add_parser("apply-review")
    for f in ("--id", "--commit", "--changes"):
        ar.add_argument(f, required=True)
    ar.add_argument("--repo")
    a = ap.parse_args(argv)
    try:
        if a.cmd == "apply-review":
            recs = [apply_review(a.id, a.commit, a.changes, a.repo)]
        else:
            recs = run(a.eval, a.ledger, a.changes, a.rules, a.inbox, a.repo)
    except (OSError, ValueError, KeyError) as e:
        print("eval-feedback: %s" % e, file=sys.stderr)
        return 2
    for rec in recs:
        print("eval-feedback: %s" % describe(rec))
    return 0


if __name__ == "__main__":
    sys.exit(main())
