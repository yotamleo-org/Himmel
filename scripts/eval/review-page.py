#!/usr/bin/env python3
"""scripts/eval/review-page.py - the readable page over the reviewer evals (HIMMEL-6943).

Reads the eval-runs ledger (lib/eval_runs.py) and the eval-changes ledger (lib/eval_feedback.py) and
writes one Markdown page in plain words, its bottom line first (each eval's headline with its run day):
how often the critics' findings key-match labelled target defects and how often they block labelled-clean
changes (review-panel, automated proxies, not verified accuracy), how often the judges let a bug past a GO
(judge-accuracy), the proof-first share (self-reported) of merged PRs (pdd-share), the trend since the last
run of the same series, and each change the feedback step proposed: a reviewer change carries its lifecycle label
(proposed, applied awaiting measurement, measured keep or revert, inconclusive, or a historical delta whose
application is unverified), a judge change its re-measured result. Keep and revert are recommendations; the page
runs no git operation. The page
carries no metric names: a number with no sentence here is not shown. A review-panel trend compares two rows
only when both name one known scorer_sha256: a repaired scorer is a new series.

  review-page.py [--ledger P] [--changes P] [--out FILE]
  review-page.py --panel [--cr-ledger P] [--until TS] [--min-findings N] [--out FILE]

Ledgers: $HIMMEL_EVAL_RUNS_LEDGER / $HIMMEL_EVAL_CHANGES_LEDGER, else ~/.himmel/. Prints the page, or
writes it to --out. Exit 0. Stdlib only; no network, no model call.

--panel renders the headline of docs/evals/review-panel.md from the CR ledger ($CR_LEDGER, else the git
common dir's cr-critic-scores.jsonl) instead: each finding counted once, keyed on (PR, file, line, claim)
across rounds and critics, with per-PR numbers and the as-of date. A merged finding takes the verdict of
its earliest raise that has one; a finding with no recorded text is never merged. A critic with fewer
than --min-findings distinct findings (default 10) shares one "other" row. With --out it replaces
the block between the two `review-page.py --panel` marker comments of FILE, and refuses (exit 2) a FILE
that has no such block.

  review-page.py --reviewers-json --ledger FILE --changes FILE --cr-ledger FILE [--now ISO]
  review-page.py --reviewers-only --ledger FILE --changes FILE --cr-ledger FILE [--now ISO]

--reviewers-json prints report v1 over the code reviewers only (no judge eval), read at --now (default: the
current time); scripts/config-ui's GET /api/reviewers runs it on every request. Pure read: each source is
named by basename with its state (ok, absent when the file is missing, error with the errno name when it cannot be
read), and the report is ok, partial (a source error beside a readable one), absent or error. The benchmark is the
newest usable review-panel run with the newest attempt beside it, old once observed more than 7 days before --now,
with a trend only against a comparable previous run (review_incompat). Production findings are the CR ledger's
reviewer_summary over the trailing 14 days, by verdict source; capture coverage is unknown, since no per-PR
capture receipt exists. Every metric is a typed k of n whose value is null when n is 0. No review text, full path
or exception message is printed. --reviewers-only prints the same report in plain words.
"""
import argparse
import collections
import errno
import json
import os
import re
import statistics
import sys
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
sys.path.insert(0, os.path.join(HERE, "cr-ledger"))
import cr_ledger_eval  # noqa: E402
import eval_feedback  # noqa: E402
import eval_runs  # noqa: E402

PANEL_START = "<!-- review-page.py --panel: start -->"
PANEL_END = "<!-- review-page.py --panel: end -->"
SMALL = 10

CRITICS = {"codex": "The codex critic", "coderabbit": "CodeRabbit", "claude": "The Claude critic",
           "panel": "The whole panel"}
OWNER = {"codex": "the codex critic's", "coderabbit": "CodeRabbit's", "claude": "the Claude critic's",
         "judge": "the judges'"}
BUG_CLASSES = {
    "logic": "logic slips (a wrong condition or an off-by-one)",
    "quoting": "quoting slips (a value split on spaces)",
    "fail-open": "fail-open guards (a check that lets an error through)",
    "toctou": "races (a file that changes between the check and the use)",
    "test-cannot-fail": "tests that cannot fail",
    "scope-creep": "unannounced changes outside the task",
}
CHANGES = {"prompt": "%s prompt", "cr-config": "%s settings", "learning": "%s notes",
           "routing": "%s routing", "tool-ruling": "%s tool rules",
           "impacted-suites": "the rule that picks which tests CI runs"}
ANSWERS = [("q1", "Do agents write the failing test before the code?", "sessions"),
           ("q2", "How many hook and gate refusals are left unsorted?", "refusals"),
           ("q3", "Does the judge model and effort matter?", "merged PRs"),
           ("q4", "Is CodeRabbit right often enough to keep?", "findings"),
           ("q5", "Is the Claude critic worth a third review?", "findings")]
VERDICTS = {"improved": "it helped", "regressed": "it made things worse", "flat": "no real change"}


def pct(x):
    return int(x * 100 + 0.5)


def day(ts):
    try:
        d = datetime.strptime(ts[:10], "%Y-%m-%d")
        return "%d %s" % (d.day, d.strftime("%b %Y"))
    except (TypeError, ValueError):
        return "an unknown day"


def level(row):
    lv = row.get("ci_level")
    return " Ranges are %d %% ranges." % pct(lv) if eval_runs._num(lv) else ""


def plain(name):
    return name.replace("-", " ").replace("_", " ").replace(".", " ")


def known_scorer(row):
    s = (row.get("meta") or {}).get("scorer_sha256")
    return s if isinstance(s, str) and re.match(r"^[0-9a-f]{64}$", s) else None


def latest(rows, eval_id):
    """(newest usable row, the newest earlier row of the same series) for one eval."""
    mine = [r for r in rows if r["eval"] == eval_id]
    if eval_id == "review-panel":
        mine = eval_feedback.select_review_runs(mine)[0]
    mine = [r for r in mine if r["status"] in ("ok", "partial")]
    if not mine:
        return None, None
    cur = mine[-1]
    prev = [r for r in mine[:-1] if r["confighash"] == cur["confighash"]]
    if eval_id == "review-panel":
        prev = [r for r in prev if known_scorer(cur) is not None and known_scorer(r) == known_scorer(cur)]
    return cur, (prev[-1] if prev else None)


def rate(cur, prev, key, lower_better=False):
    """': 60 % (likely between 30 % and 90 %), up 20 points since the last run (40 %)'."""
    x = cur["metrics"].get(key)
    if not eval_runs._num(x):
        return None
    s = ": %d %%" % pct(x)
    b = cur["ci"].get(key)
    if b:
        s += " (likely between %d %% and %d %%)" % (pct(b["lo"]), pct(b["hi"]))
    p = prev["metrics"].get(key) if prev else None
    if eval_runs._num(p):
        d = pct(x) - pct(p)
        if d == 0:
            s += ", no change since the last run"
        else:
            s += ", %s %d points since the last run (%d %%)" % ("up" if d > 0 else "down", abs(d), pct(p))
            if lower_better:
                s += ", %s" % ("better" if d < 0 else "worse")
    return s


def count(m, key):
    v = m.get(key)
    return int(v) if eval_runs._num(v) else 0


def proxy_key(m, w, new, old):
    return "%s.%s" % (w, new) if ("%s.%s" % (w, new)) in m else "%s.%s" % (w, old)


def critic_lines(cur, prev):
    m = cur["metrics"]
    who = list((cur.get("config") or {}).get("critics") or []) + ["panel"]
    out = []
    for w in who:
        name = CRITICS.get(w, "The %s critic" % plain(w))
        classes = {k[len(w) + 7:-7]: m[k] for k in m
                   if k.startswith(w + ".class.") and k.endswith(".recall") and eval_runs._num(m[k])}
        n = sum(count(m, "%s.class.%s.n" % (w, c)) for c in classes)
        said = []
        key = proxy_key(m, w, "key_match_recall", "recall")
        s = rate(cur, prev, key)
        if s and n:
            said.append("%s key-matched %d of %d labelled target defects%s." % (name, round(m[key] * n), n, s))
        f = count(m, w + ".findings")
        key = proxy_key(m, w, "key_match_precision", "precision")
        s = rate(cur, prev, key)
        if s and f:
            said.append("%s: %d of %d findings key-matched a labelled defect%s." % (name, round(m[key] * f), f, s))
        c = count(m, w + ".clean_scored")
        key = proxy_key(m, w, "labelled_clean_block_rate", "fp_rate")
        s = rate(cur, prev, key, lower_better=True)
        if s and c:
            said.append("%s: labelled-clean blocking on %d of %d labelled-clean changes%s." %
                        (name, round(m[key] * c), c, s))
        if classes:
            cls = min(sorted(classes), key=lambda c: classes[c])
            cn = count(m, "%s.class.%s.n" % (w, cls))
            said.append("%s's weakest kind of labelled defect: %s, key-matched %d of %d." %
                        (name, BUG_CLASSES.get(cls, plain(cls)), round(classes[cls] * cn), cn))
        out += ["- " + x for x in said]
    if "coderabbit" not in who:
        out.append("- CodeRabbit history is reported separately; controlled recall is not measured here.")
    return out


def answer_lines(cur):
    """One line per decision-158 question: percentage, range, sample, and the move since the earlier cut."""
    m, ci, notes = cur["metrics"], cur["ci"], (cur.get("meta") or {}).get("notes") or {}
    out = []
    for q, text, unit in ANSWERS:
        x = m.get(q + ".pct")
        if not eval_runs._num(x):
            out.append("- %s Not measured yet." % text)
            continue
        line = "- %s %d %%" % (text, pct(x))
        b = ci.get(q + ".pct")
        if b:
            line += " (likely between %d %% and %d %%)" % (pct(b["lo"]), pct(b["hi"]))
        line += " of %d %s" % (count(m, q + ".n"), unit)
        old = m.get(q + ".before.pct")
        if eval_runs._num(old):
            d = pct(x) - pct(old)
            line += ", was %d %% before, %s" % (pct(old), "no change" if d == 0 else "%s %d points" % ("up" if d > 0 else "down", abs(d)))
        else:
            line += ", no earlier figure yet"
        line += "."
        if notes.get(q):
            line += " (%s.)" % notes[q].rstrip(".")
        out.append(line)
    return out


def judge_lines(cur, prev):
    m = cur["metrics"]
    meta = cur.get("meta") or {}
    out = ["Verdicts written from %s to %s.%s" % (day(meta.get("since")), day(meta.get("until")), level(cur)), ""]
    s = rate(cur, prev, "flip_rate", lower_better=True)
    if s and count(m, "flip_n"):
        out.append("- The judges changed their first answer %d times in %d%s." %
                   (count(m, "flips"), count(m, "flip_n"), s))
    s = rate(cur, prev, "escape_rate", lower_better=True)
    if s and count(m, "go_merged"):
        line = "- A bug got past a GO on %d of %d merged PRs%s." % (count(m, "escapes"), count(m, "go_merged"), s)
        if count(m, "escapes_plausible") > count(m, "escapes"):
            line += " Counting the likely ones too: %d of %d." % (count(m, "escapes_plausible"),
                                                                  count(m, "go_merged"))
        if count(m, "cause.ci-selection.escapes"):
            line += " %d of them got past because CI did not run the test that would have caught it." % \
                count(m, "cause.ci-selection.escapes")
        out.append(line)
    if count(m, "nogo_n"):
        out.append("- A NO-GO was wrong %d time%s in %d: %d %%." %
                   (count(m, "false_nogo"), "" if count(m, "false_nogo") == 1 else "s", count(m, "nogo_n"),
                    pct(count(m, "false_nogo") / count(m, "nogo_n"))))
    if count(m, "overridden"):
        out.append("- %d NO-GO PRs were merged over by the chief; they count as overruled, not as wrong." %
                   count(m, "overridden"))
    worse = sorted((k[6:-14] for k in m if k.startswith("class.") and k.endswith(".escape_excess")
                    and eval_runs._num(m[k]) and m[k] > 0), key=lambda c: -m["class.%s.escape_excess" % c])
    for c in worse:
        n = count(m, "class.%s.n" % c)
        out.append("- Worse than the average, on %s changes: a bug got past %d of %d (%d %%)." %
                   (plain(c), count(m, "class.%s.escapes" % c), n, pct(count(m, "class.%s.escapes" % c) / n)))
    if cur["status"] == "partial" or count(m, "pending"):
        out.append("- %d possible bugs still wait for a ruling, so these numbers may still move." %
                   count(m, "pending"))
    return out


def proof_lines(cur, prev):
    m = cur["metrics"]
    out = ["A merged PR counts as proof-first when two things hold: its ticket had a Definition of Done and a "
           "Proof before the PR's first commit, and the PR body names RED (the new test failing) and then GREEN "
           "(the same test passing). It matters because a check written down before the work, and seen failing "
           "before the fix, is what shows the change does what the ticket asked: a test never seen failing may "
           "test nothing. Self-reported: RED and GREEN are words the PR author wrote, not a test run this eval "
           "checked.", "",
           "Run of %s, the last %d merged PRs whose ticket and commits could be read.%s" % (
               day(cur["ts"]), cur["n"] or 0, level(cur)), ""]
    for key, text, unit in (("pdd", "Proof-first share (self-reported)", " merged PRs"),
                            ("ticket_first", "The ticket was written first", ""),
                            ("red_green", "RED then GREEN named in the PR body", "")):
        s = rate(cur, prev, key + ".pct")
        if s and count(m, key + ".n"):
            out.append("- %s: %d of %d%s%s." % (text, count(m, key + ".k"), count(m, key + ".n"), unit, s))
    return out


def review_move(mz):
    if mz is None or not (eval_runs._num(mz.get("before")) and eval_runs._num(mz.get("after"))):
        return ""
    d = pct(mz["after"]) - pct(mz["before"])
    return "from %d %% to %d %%, %s" % (pct(mz["before"]), pct(mz["after"]),
                                      "no change" if d == 0 else "%s %d points" % ("up" if d > 0 else "down", abs(d)))


def review_state(applied, mz):
    bound = applied is not None and isinstance(applied.get("commit"), str)
    if mz is not None and not (bound and mz.get("applied_commit") == applied["commit"]):
        return "historical-unverified"
    if not bound:
        return "proposed"
    if mz is None:
        return "applied-awaiting-measurement"
    if mz.get("verdict") in ("keep", "revert") and review_move(mz):
        return "measured-" + mz["verdict"]
    return "inconclusive"


def review_line(c, what, why, applied, mz):
    did = "a change to %s after the run of %s, because %s" % (what, day(c.get("ts")), why)
    move = review_move(mz)
    state = review_state(applied, mz)
    if state == "historical-unverified":
        return "- Historical delta; application unverified: %s. A later run moved %s, but no application receipt " \
               "binds that run to the change." % (did, move or "by an unrecorded amount")
    if state == "proposed":
        return "- Proposed, not applied: %s. No application receipt yet, so no later run is credited to it." % did
    did += ", applied in commit %s on %s" % (applied["commit"][:12], day(applied.get("applied_at")))
    if state == "applied-awaiting-measurement":
        return "- Applied, awaiting measurement: %s. A later run at the applied version measures it." % did
    if state == "measured-keep":
        return "- Measured, keep: %s. The measured run at the applied version: %s. Keep is a recommendation: " \
               "nothing was merged, deployed or reverted by it." % (did, move)
    reason = mz.get("reason") if isinstance(mz.get("reason"), str) and mz.get("reason") else "no reason recorded"
    if state == "measured-revert":
        return "- Measured, revert: %s. The measured run at the applied version: %s (%s). Revert is a " \
               "recommendation: nothing was reverted by it." % (did, move, reason)
    return "- Inconclusive: %s. The measured run at the applied version settles nothing: %s." % (did, reason)


def change_reason(c):
    owner = OWNER.get(c.get("critic"), "the %s eval's" % plain(c.get("eval", "")))
    tmpl = CHANGES.get(c.get("change"), "%s setup")
    what = tmpl % owner if "%s" in tmpl else tmpl
    metric = c.get("metric", "")
    parts = metric.split(".")
    is_rate = metric.endswith(("recall", "rate", "precision"))
    if len(parts) == 4 and parts[1] == "class" and parts[3] == "recall":
        why = "it caught too few %s" % BUG_CLASSES.get(parts[2], plain(parts[2]))
    elif metric.startswith("cause.ci-selection."):
        why = "too many bugs got past because CI did not run the right test"
    elif len(parts) == 3 and parts[0] == "class" and parts[2] == "escape_excess":
        why = "too many bugs got past on %s changes" % plain(parts[1])
    else:
        why = "one of its numbers was past its limit"
    if is_rate and eval_runs._num(c.get("value")) and eval_runs._num(c.get("threshold")):
        why += ": %d %%, the bar is %d %%" % (pct(c["value"]), pct(c["threshold"]))
    return what, why, is_rate


def change_index(changes):
    changes = [c for c in changes if isinstance(c, dict)]
    opened = [c for c in changes if c.get("status") == "open" and c.get("eval") in ("review-panel", "judge-accuracy")
              and isinstance(c.get("metric"), str)]
    done = {c["id"]: c for c in changes if c.get("status") == "measured" and "id" in c}
    applied = {}
    for c in changes:
        if c.get("status") == "applied" and isinstance(c.get("id"), str):
            applied.setdefault(c["id"], c)
    return opened, done, applied


def change_lines(changes):
    opened, done, applied = change_index(changes)
    out = []
    for c in opened:
        what, why, is_rate = change_reason(c)
        if c.get("eval") == "review-panel":
            out.append(review_line(c, what, why, applied.get(c.get("id")), done.get(c.get("id"))))
            continue
        line = "- Changed %s after the run of %s, because %s." % (what, day(c.get("ts")), why)
        mz = done.get(c.get("id"))
        if mz is None:
            line += " Not measured yet: the next run shows whether it helped."
        else:
            res = VERDICTS.get(mz.get("verdict"), "no verdict")
            if is_rate and eval_runs._num(mz.get("before")) and eval_runs._num(mz.get("after")):
                d = pct(mz["after"]) - pct(mz["before"])
                move = "no change" if d == 0 else "%s %d points" % ("up" if d > 0 else "down", abs(d))
                line += " Measured on the next run: from %d %% to %d %%, %s: %s." % (
                    pct(mz["before"]), pct(mz["after"]), move, res)
            else:
                line += " Measured on the next run: %s." % res
        out.append(line)
    return out


def bottom_lines(rows):
    """Each eval's headline line with its run day: the whole panel's catch when it was scored (else the first
    critic's), bugs past a GO, the proof-first share. A run that scored nothing says so."""
    out = []
    for eval_id, build, mark, name in (("review-panel", critic_lines, " labelled target defects: ",
                                        "Labelled target defects (key match)"),
                                       ("judge-accuracy", judge_lines, "- A bug got past a GO", "Bugs past a GO"),
                                       ("pdd-share", proof_lines, "- Proof-first share (self-reported): ",
                                        "Proof-first share (self-reported)")):
        cur, prev = latest(rows, eval_id)
        if cur is None:
            continue
        hits = [x for x in build(cur, prev) if mark in x]
        whole = [x for x in hits if x.startswith("- " + CRITICS["panel"])]
        line = (whole or hits)[0] if hits else "- %s: no score in this run." % name
        out.append("%s Run of %s." % (line, day(cur["ts"])))
    return out


def page(rows, changes):
    out = ["# How good are our reviewers?", "",
           "Each critic and judge number comes from the newest run, and a trend compares it with the run "
           "before. Each change's result comes from the run that re-measured it. \"Likely between\" is a range: given how much "
           "a run measured, the true rate is likely inside it. What each number means, with its ledger key: "
           "scripts/eval/README.md.", "",
           "## Bottom line", ""]
    out += bottom_lines(rows) or ["No run yet."]
    out += ["", "## The critics on labelled test changes", ""]
    cur, prev = latest(rows, "review-panel")
    if cur is None:
        out.append("No run yet.")
    else:
        out += ["Run of %s, %d test changes.%s" % (day(cur["ts"]), cur["n"] or 0, level(cur)), "",
                "These are automated key-match proxies, not verified accuracy: a finding counts when it sits at a "
                "labelled defect's place and its words match the defect's kind, and a labelled-clean change counts "
                "as blocked on any blocking finding, whether or not that finding is right.", ""] + critic_lines(cur, prev)
    out += ["", "## The judges", ""]
    cur, prev = latest(rows, "judge-accuracy")
    out += ["No run yet."] if cur is None else judge_lines(cur, prev)
    out += ["", "## The five open questions", ""]
    cur, _ = latest(rows, "decision-158")
    out += ["No run yet."] if cur is None else answer_lines(cur)
    out += ["", "## Proof-first share (self-reported)", ""]
    cur, prev = latest(rows, "pdd-share")
    out += ["No run yet."] if cur is None else proof_lines(cur, prev)
    out += ["", "## What we changed, and whether it helped", ""]
    out += change_lines(changes) or ["No change yet."]
    return "\n".join(out) + "\n"


def claim(text):
    """A finding's claim without its severity tag or trailing [file:line] citation, case and punctuation folded
    (comparison, arithmetic, logical and bitwise operators kept)."""
    t = re.sub(r"^\s*-\s*\[[^\]]+\]\s*:\s*", "", text or "")
    t = re.sub(r"\s*\[[^\]\r\n]+:\d+(?:-\d+)?\]\s*$", "", t)
    return re.sub(r"[^a-z0-9=!<>+*/%&|^~-]+", " ", t.lower()).strip()


def distinct(rows):
    """One record per (PR, file, line, claim): its critics, and the bucket of its earliest ruled raise."""
    raw = [r for r in rows if r.get("kind") == "finding"]
    groups = {}
    # fold() keeps ledger order, one entry per finding row, so it pairs with raw.
    for f, r in zip(cr_ledger_eval.fold(rows), raw):
        c = claim(r.get("text"))
        anchor = re.sub(r"^\./", "", re.sub(r":l?\d+(?:-\d+)?$", "", str(r.get("file") or "").strip().replace("\\", "/")))
        k = (f["branch"], anchor, str(r.get("line") or ""), c) if c else ("no-text", f["id"])
        groups.setdefault(k, []).append(f)
    out = []
    for fs in groups.values():
        fs.sort(key=lambda f: f["ts"])
        ruled = [f for f in fs if f["bucket"] != "unadjudicated"]
        first = ruled[0] if ruled else fs[0]
        out.append(dict(first, severity=fs[0]["severity"], ts=fs[0]["ts"], critics={f["critic"] for f in fs}))
    return out


def num(n):
    return "{:,}".format(n)


def share(k, n):
    return "%.1f%%" % (100 * k / n) if n else "n/a"


def precision_cells(fs):
    s = cr_ledger_eval.split(fs)
    p = "—" if s["precision"] is None else "%.1f%%" % (100 * s["precision"])
    ci = s["precision_ci"]
    return s, p, "—" if not ci else "%.1f–%.1f" % (100 * ci["lo"], 100 * ci["hi"])


def panel(rows, until, small_n=SMALL):
    finding_rows = [r for r in rows if r.get("kind") == "finding"]
    groups = distinct(rows)
    cut = until or max((r.get("ts") or "" for r in rows), default="")
    reviewed = {r.get("branch") or "" for r in rows if r.get("kind") == "avail" and r.get("status") == "ok"}
    per_pr = collections.Counter(g["branch"] for g in groups)
    reviewed |= set(per_pr)
    allc = cr_ledger_eval.split(groups)
    out = ["## Headline numbers", "",
           "As of %s (CR ledger cut `%s`): %s distinct findings across %s PRs, %s to %s." % (
               day(cut), cut, num(len(groups)), num(len(per_pr)), allc["first"][:10], allc["last"][:10]), "",
           "The ledger holds %s finding rows. %s of them repeat a finding already counted here: the same claim "
           "on the same file and line of the same PR, raised again in a later round or by another critic. A "
           "merged finding takes the verdict of its earliest raise that has one. A finding with no recorded "
           "text is never merged." % (num(len(finding_rows)), num(len(finding_rows) - len(groups))), ""]
    if per_pr:
        counts = sorted(per_pr.values())
        out += ["Per PR: %s PRs reviewed, %s with at least one finding; median %g and mean %g distinct findings "
                "per PR with findings, at most %s on one PR." % (
                    num(len(reviewed)), num(len(per_pr)), round(statistics.median(counts), 1),
                    round(statistics.fmean(counts), 1), num(counts[-1])), ""]
    out += ["| Critic | Findings | PRs | Agreed | Disproved | Deferred | Unadjudicated | Precision | 95% CI |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---|"]
    by = collections.defaultdict(list)
    for g in groups:
        for c in g["critics"]:
            by[c].append(g)
    small = sorted(c for c in by if len(by[c]) < small_n)
    rows_out = [("`%s`" % c, by[c]) for c in sorted(by, key=lambda c: (min(g["ts"] for g in by[c]), c)) if c not in small]
    if small:
        other = {id(g): g for c in small for g in by[c]}
        rows_out.append(("other (%d slugs under %d findings each)" % (len(small), small_n), list(other.values())))
    for label, fs in rows_out:
        s, p, ci = precision_cells(fs)
        out.append("| %s | %s | %s | %s | %s | %s | %s | %s | %s |" % (
            label, num(s["n"]), num(s["prs"]), num(s["agreed"]), num(s["disproved"]), num(s["deferred"]),
            num(s["unadjudicated"]), p, ci))
    s, p, ci = precision_cells(groups)
    out += ["| **All** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** | **%s** | %s |" % (
        num(s["n"]), num(s["prs"]), num(s["agreed"]), num(s["disproved"]), num(s["deferred"]),
        num(s["unadjudicated"]), p, ci), "",
        "A finding raised by two critics counts once in each critic's row and once in **All**. Precision is "
        "agreed / (agreed + disproved); the interval resamples whole PRs.", ""]
    n = len(groups)
    out.append("- Of the %s distinct findings, %s were agreed, %s disproved, %s deferred and %s never ruled on." % (
        num(n), share(s["agreed"], n), share(s["disproved"], n), share(s["deferred"], n), share(s["unadjudicated"], n)))
    sev = collections.defaultdict(list)
    for g in groups:
        sev[g["severity"]].append(g)
    parts = []
    for name in ("critical", "important", "suggestion"):
        if sev.get(name):
            ss, p, ci = precision_cells(sev[name])
            parts.append("%s %s (%s findings%s)" % (name.capitalize(), p, num(ss["n"]), ", CI " + ci if ci != "—" else ""))
    if parts:
        out.append("- Precision by severity: %s." % "; ".join(parts))
    cls = collections.Counter(g["fu_class"] for g in groups if g["bucket"] == "deferred" and g["fu_class"])
    if cls:
        out.append("- %s of the %s deferred findings carry a follow-up class: %s." % (
            num(sum(cls.values())), num(s["deferred"]), ", ".join("%s `%s`" % (num(v), k) for k, v in cls.most_common())))
    out += ["", "Regenerate this section from a himmel checkout (the cut makes it re-run exactly):", "", "```bash",
            "python3 scripts/eval/review-page.py --panel --until %s%s --out docs/evals/review-panel.md" % (
                cut, "" if small_n == SMALL else " --min-findings %d" % small_n), "```"]
    return "\n".join(out) + "\n"


def write_panel(path, text):
    """Replace the marked block of path; 2 when path exists without one."""
    block = "%s\n%s%s" % (PANEL_START, text, PANEL_END)
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            doc = fh.read()
        i, j = doc.find(PANEL_START), doc.find(PANEL_END)
        if i < 0 or j < i:
            print("review-page: refused: %s has no %s ... %s block" % (path, PANEL_START, PANEL_END), file=sys.stderr)
            return 2
        block = doc[:i] + block + doc[j + len(PANEL_END):]
    else:
        block += "\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(block)
    return 0


REPORT_V = 1
OLD_DAYS = 7
CAPTURE_REASON = "no per-PR capture receipts and no expected-PR snapshot"
BENCH = (("key_match_recall", "recall", "key-matched labelled target defects", "labelled target defects", False),
         ("key_match_precision", "precision", "findings that key-matched a labelled defect", "findings", False),
         ("labelled_clean_block_rate", "fp_rate", "labelled-clean changes blocked", "labelled-clean changes", True))
VERIFIED = (("adjudicated_precision", "findings adjudicated correct", "decided findings", False),
            ("verified_false_block_rate", "labelled-clean changes falsely blocked (verified)", "labelled-clean changes", True))
PROD = {cr_ledger_eval.RECORDED: "agreed by the PR author, of the decided findings (recorded disposition)",
        cr_ledger_eval.INFERRED: "resolved after a change (thread state, inferred)",
        cr_ledger_eval.UNKNOWN_SOURCE: "verdict source unknown: counted, no ratio"}


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def newest_ts(rows):
    ts = [(cr_ledger_eval.parse_ts(r.get("ts")), r.get("ts")) for r in rows if isinstance(r, dict)]
    ts = [x for x in ts if x[0] is not None]
    return max(ts)[1] if ts else None


def read_jsonl(path):
    rows, bad = [], 0
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            try:
                r = json.loads(line)
            except ValueError:
                bad += 1
                continue
            if isinstance(r, dict):
                rows.append(r)
            else:
                bad += 1
    return rows, bad


def read_source(sid, path):
    src = {"id": sid, "name": os.path.basename(path or ""), "state": "absent", "reason": None, "records": 0,
           "malformed": 0, "observed_through": None}
    if not path:
        src["reason"] = "no-path"
        return src, None
    try:
        if sid == "eval-runs":
            with open(path, encoding="utf-8"):
                pass
            rows, _, bad = eval_runs.scan_rows(path)
            bad = len(bad)
        else:
            rows, bad = read_jsonl(path)
    except FileNotFoundError:
        src["reason"] = "ENOENT"
        return src, None
    except OSError as e:
        src.update(state="error", reason=errno.errorcode.get(e.errno, "EIO"))
        return src, None
    except ValueError:
        src.update(state="error", reason="undecodable")
        return src, None
    src.update(state="ok", records=len(rows), malformed=bad, observed_through=newest_ts(rows))
    return src, rows


def report_state(sources):
    states = {s["state"] for s in sources}
    if "error" in states:
        return "partial" if "ok" in states else "error"
    return "ok" if "ok" in states else "absent"


def ratio_of(k, n):
    return round(k / n, 4) if n and k is not None else None


def metric(mid, family, reviewer, label, kind, k, n, unit, **kw):
    m = {"id": mid, "family": family, "reviewer": reviewer, "label": label, "kind": kind, "k": k, "n": n,
         "value": ratio_of(k, n), "interval": None, "sample_unit": unit, "window": None, "cohort": None, "model": None,
         "execution_id": None, "run_id": None, "scorer_sha256": None, "verdict_source": None, "coverage": None,
         "freshness": None, "limitations": [], "trend": None, "lower_better": False}
    m.update(kw)
    return m


def execution_start(rows, diag):
    first, members = {}, {}
    for r in rows:
        rid, ts = r.get("run_id"), r.get("ts")
        if isinstance(rid, str) and isinstance(ts, str):
            first[rid] = min(ts, first.get(rid, ts))
    for d in diag:
        if isinstance(d.get("run_id"), str) and d.get("by"):
            members.setdefault(d["by"], set()).add(d["run_id"])

    def start(r):
        rid = r.get("run_id")
        if eval_feedback.row_field(r, "supersedes_run_id") and not members.get(rid):
            return None
        known = [first[i] for i in members.get(rid, set()) | {rid} if i in first]
        return min(known) if known else None
    return start


def bench_metrics(cur, prev, fresh, observed):
    m, ci, meta = cur["metrics"], cur.get("ci") or {}, cur.get("meta") or {}
    unscored = meta.get("unscored")
    common = {"window": {"observed_at": observed}, "cohort": cur.get("confighash"),
              "model": cur.get("model") or (cur.get("config") or {}).get("critic_model"),
              "execution_id": eval_feedback.row_field(cur, "execution_id"), "run_id": cur.get("run_id"),
              "scorer_sha256": known_scorer(cur), "freshness": fresh,
              "coverage": {"cases": cur.get("n"), "unscored": len(unscored) if isinstance(unscored, list) else unscored}}
    lim = ["automated key-match proxy, not verified accuracy"] + ([] if known_scorer(cur) else ["scorer not recorded"])
    out = []
    for w in list((cur.get("config") or {}).get("critics") or []) + ["panel"]:
        for name, old, label, unit, lower in BENCH:
            key = proxy_key(m, w, name, old)
            if name == "key_match_recall":
                n = sum(count(m, k[:-len("recall")] + "n") for k in m if k.startswith(w + ".class.")
                        and k.endswith(".recall") and eval_runs._num(m[k]))
            else:
                n = count(m, w + (".findings" if name == "key_match_precision" else ".clean_scored"))
            if key not in m and not n:
                continue
            v = m.get(key)
            k = int(round(v * n)) if eval_runs._num(v) and n else None
            pv = prev["metrics"].get(proxy_key(prev["metrics"], w, name, old)) if prev else None
            trend = {"previous_value": pv, "previous_run_id": prev.get("run_id")} if eval_runs._num(pv) else None
            out.append(metric("benchmark.%s.%s" % (w, name), "benchmark", w, label, "proxy", k, n, unit,
                              interval=ci.get(key) or None, trend=trend, lower_better=lower, limitations=list(lim),
                              **common))
        ver = meta.get("verified") if isinstance(meta.get("verified"), dict) else {}
        counts = ver.get("counts") or {}
        for name, label, unit, lower in VERIFIED:
            c = counts.get("%s.%s" % (w, name))
            if not isinstance(c, dict):
                continue
            k, n = c.get("k"), c.get("n")
            k, n = (int(k), int(n)) if eval_runs._num(k) and eval_runs._num(n) else (None, 0)
            out.append(metric("benchmark.%s.%s" % (w, name), "benchmark", w, label, "adjudicated", k if n else None,
                              n, unit, lower_better=lower,
                              limitations=["not a decision until the cohort is validated"] +
                              [str(x) for x in ver.get("reasons") or []], **common))
    return out


def prod_metrics(cr_rows, since, until, roster, fresh):
    out, excluded = [], {"findings": 0, "slugs": 0}
    slugs = set()
    for r in cr_ledger_eval.reviewer_summary(cr_rows, since, until, False, roster):
        if not r["reviewer"]:
            excluded["findings"] += r["total"]
            slugs.add(r["slug"])
            continue
        src = r["verdict_source"]
        if src == cr_ledger_eval.RECORDED:
            k, n, ci = r["agreed"], r["decided"], r["author_agreement_ci"]
        elif src == cr_ledger_eval.INFERRED:
            k, n, ci = r["thread_state"]["resolved_after_change"], r["total"], None
        else:
            k, n, ci = None, r["total"], None
        cov = {x: r[x] for x in ("total", "agreed", "disproved", "deferred", "unresolved", "prs")}
        cov.update(adjudication_coverage=r["adjudication_coverage"], capture="unknown")
        out.append(metric("production.%s.%s.%s.%s" % (r["slug"], r["responding_model"], r["scope"], src), "production",
                          r["slug"], PROD[src], "proxy", k if n else None, n,
                          "decided findings" if src == cr_ledger_eval.RECORDED else "findings",
                          interval=ci, model=r["responding_model"], verdict_source=src, coverage=cov,
                          window={"since": since, "until": until}, cohort=r["scope"], freshness=fresh,
                          limitations=["the PR author rules, so agreement is a proxy, not verified correctness"]
                          if src == cr_ledger_eval.RECORDED else ["inferred from thread state, never author agreement"]
                          if src == cr_ledger_eval.INFERRED else ["no ratio without a known verdict source"],
                          value=None if src == cr_ledger_eval.UNKNOWN_SOURCE else ratio_of(k, n)))
    excluded["slugs"] = len(slugs)
    return out, excluded


def build_reviewers_report(eval_rows, changes, cr_rows, now, sources=None, roster=None):
    """Report v1 over the code reviewers. Each input is its rows, or None when its source is unusable; sources
    (default: derived from which inputs are None) names each source's state. No judge eval is read."""
    t = cr_ledger_eval.parse_ts(now) if isinstance(now, str) else now
    now_iso = iso(t)
    if sources is None:
        sources = [{"id": i, "name": i, "state": "absent" if x is None else "ok", "reason": None,
                    "records": len(x or []), "malformed": 0, "observed_through": newest_ts(x or [])}
                   for i, x in (("eval-runs", eval_rows), ("eval-changes", changes), ("cr-ledger", cr_rows))]
    rp = [r for r in eval_rows or [] if r.get("eval") == "review-panel"
          and (cr_ledger_eval.parse_ts(r.get("ts")) or t) <= t]
    sel, diag = eval_feedback.select_review_runs(rp)
    usable = [r for r in sel if r["status"] in ("ok", "partial")]
    cur = usable[-1] if usable else None
    observed = execution_start(rp, diag)(cur) if cur is not None else None
    prior = usable[-2] if len(usable) > 1 else None
    tries = sorted((x for x in ((cr_ledger_eval.parse_ts(r.get("ts")), i, r) for i, r in enumerate(rp)) if x[0]),
                   key=lambda x: (x[0], x[1]))
    attempt = tries[-1][2] if tries else None
    fresh = None
    if cur is not None:
        seen = cr_ledger_eval.parse_ts(observed) if observed else None
        age = t - seen if seen else None
        fresh = {"observed_at": observed, "age_days": None if age is None else age.days, "old_after_days": OLD_DAYS,
                 "state": "unknown" if age is None else "old" if age.total_seconds() > OLD_DAYS * 86400 else "current"}
    if cur is None:
        elig = {"eligible": False, "reasons": ["no usable benchmark run"]}
    elif prior is None:
        elig = {"eligible": False, "reasons": ["no earlier usable run"]}
    else:
        why = eval_feedback.review_incompat(cur, prior)
        elig = {"eligible": why is None, "reasons": [why] if why else []}
    metrics = bench_metrics(cur, prior if elig["eligible"] else None, fresh, observed) if cur is not None else []
    since = cr_ledger_eval.default_window_start(now_iso)
    in_cut = [r for r in cr_rows or [] if (cr_ledger_eval.parse_ts(r.get("ts")) or t) <= t]
    last = newest_ts(in_cut)
    window_findings = cr_ledger_eval.in_window(cr_ledger_eval.fold(in_cut), since, False)
    prod = {"window": {"since": since, "until": now_iso, "days": cr_ledger_eval.DEFAULT_DAYS},
            "last_record_at": last, "records_in_window": len(window_findings),
            "capture_coverage": "unknown", "capture_reason": CAPTURE_REASON,
            "roster": "unreadable" if roster is None else "ok", "not_reviewers": None}
    if cr_rows is not None:
        pm, prod["not_reviewers"] = prod_metrics(in_cut, since, now_iso, roster or set(),
                                                 {"last_record_at": last, "capture_coverage": "unknown"})
        metrics += pm
    reviewers = {}
    for m in metrics:
        x = reviewers.setdefault(m["reviewer"], {"id": m["reviewer"], "models": set(), "families": set(),
                                                 "in_roster": None if roster is None else m["reviewer"] in roster})
        x["families"].add(m["family"])
        if m["model"]:
            x["models"].add(m["model"])
    opened, done, applied = change_index([c for c in changes or [] if isinstance(c, dict)
                                          and (cr_ledger_eval.parse_ts(c.get("ts")) or t) <= t])
    proposals = []
    for c in opened:
        if c.get("eval") != "review-panel":
            continue
        what, why, _ = change_reason(c)
        a, mz = applied.get(c.get("id")), done.get(c.get("id"))
        proposals.append({"id": c.get("id"), "reviewer": c.get("critic"), "change": c.get("change"),
                          "metric": c.get("metric"), "opened_at": c.get("ts"), "lifecycle": review_state(a, mz),
                          "applied_commit": a["commit"][:12] if a and isinstance(a.get("commit"), str) else None,
                          "label": review_line(c, what, why, a, mz)[2:]})
    return {
        "v": REPORT_V, "report": "code-reviewers", "generated_at": now_iso, "state": report_state(sources),
        "sources": sources,
        "latest_attempt": None if attempt is None else {
            "run_id": attempt.get("run_id"), "at": attempt.get("ts"), "status": attempt.get("status"),
            "usable": any(attempt is u for u in usable)},
        "latest_usable": None if cur is None else {
            "run_id": cur.get("run_id"), "at": observed, "status": cur.get("status"),
            "execution_id": eval_feedback.row_field(cur, "execution_id"), "scorer_sha256": known_scorer(cur),
            "cohort": cur.get("confighash")},
        "comparison_eligibility": elig,
        "benchmark": {"freshness": fresh},
        "production": prod,
        "reviewers": [dict(x, models=sorted(x["models"]), families=sorted(x["families"]))
                      for _, x in sorted(reviewers.items())],
        "metrics": metrics,
        "proposals": proposals,
    }


def cell(m):
    if m["value"] is None:
        return "%s %s: —" % (num(m["n"]), m["sample_unit"]) if not m["k"] else "%d of %d %s: —" % (
            m["k"], m["n"], m["sample_unit"])
    return "%d of %d %s: %d %%" % (m["k"], m["n"], m["sample_unit"], pct(m["value"]))


def reviewers_prose(rep):
    out = ["# Code reviewers", "", "Report of %s (%s)." % (day(rep["generated_at"]), rep["state"]), ""]
    for s in rep["sources"]:
        out.append("- %s (%s): %s" % (s["id"], s["name"] or "no file", "read, %d records through %s" % (
            s["records"], day(s["observed_through"])) if s["state"] == "ok" else
            "absent" if s["state"] == "absent" else "could not be read (%s)" % s["reason"]))
    out += ["", "## Planted-bug benchmark", ""]
    cur, att, f = rep["latest_usable"], rep["latest_attempt"], rep["benchmark"]["freshness"]
    if cur is None:
        out.append("No usable run.")
    else:
        out.append("Run of %s (%s, %s)." % (day(cur["at"]), cur["run_id"], cur["status"]))
        if f and f["state"] == "old":
            out.append("Old: observed %d days before this report." % f["age_days"])
    if att and not att["usable"]:
        out.append("Latest attempt %s (%s): %s, not usable." % (day(att["at"]), att["run_id"], att["status"]))
    el = rep["comparison_eligibility"]
    out.append("Trend: %s." % ("against the previous run" if el["eligible"] else "none, " + "; ".join(el["reasons"])))
    bench = [m for m in rep["metrics"] if m["family"] == "benchmark"]
    out += [""] if bench else []
    for m in bench:
        name = CRITICS.get(m["reviewer"], "The %s critic" % plain(m["reviewer"]))
        if m["id"].endswith(".key_match_recall"):
            line = "%s key-matched %s" % (name, cell(m))
        else:
            line = "%s, %s (%s): %s" % (name, m["label"], m["kind"], cell(m))
        out.append("- " + line + ".")
    p = rep["production"]
    out += ["", "## Review findings on merged work, %s to %s" % (day(p["window"]["since"]), day(p["window"]["until"])), ""]
    if p["last_record_at"] is None:
        out.append("No records; capture coverage unknown.")
    elif not p["records_in_window"]:
        out.append("No new records since %s; capture coverage unknown." % day(p["last_record_at"]))
    else:
        out.append("Last record %s; capture coverage unknown (%s)." % (day(p["last_record_at"]), p["capture_reason"]))
    nr = p.get("not_reviewers") or {}
    if p.get("roster") != "ok":
        out.append("The reviewer roster (scripts/cr/critics.json) could not be read, so no slug counts as a reviewer.")
    if nr.get("findings"):
        out.append("Counted out: %s findings from %d slugs that are not code reviewers." % (num(nr["findings"]), nr["slugs"]))
    for m in rep["metrics"]:
        if m["family"] == "production":
            out.append("- %s (%s, %s): %s, %s." % (m["reviewer"], m["model"], m["cohort"], m["label"], cell(m)))
    out += ["", "## Reviewer changes", ""]
    out += ["- " + x["label"] for x in rep["proposals"]] or ["No change yet."]
    return "\n".join(out) + "\n"


def reviewers_cli(a):
    now = cr_ledger_eval.parse_ts(a.now) if a.now else datetime.now(timezone.utc)
    if now is None:
        print("review-page: refused: --now is not an ISO-8601 timestamp", file=sys.stderr)
        return 2
    srcs, data = [], []
    for sid, path in (("eval-runs", a.ledger), ("eval-changes", a.changes), ("cr-ledger", a.cr_ledger)):
        s, rows = read_source(sid, path)
        srcs.append(s)
        data.append(rows)
    rep = build_reviewers_report(data[0], data[1], data[2], now, sources=srcs,
                                 roster=cr_ledger_eval.roster_slugs(os.path.join(HERE, "..", "cr", "critics.json")))
    sys.stdout.write(json.dumps(rep, sort_keys=True) + "\n" if a.reviewers_json else reviewers_prose(rep))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ledger")
    ap.add_argument("--changes")
    ap.add_argument("--out")
    ap.add_argument("--panel", action="store_true")
    ap.add_argument("--cr-ledger")
    ap.add_argument("--until")
    ap.add_argument("--min-findings", type=int, default=SMALL)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--reviewers-json", action="store_true")
    mode.add_argument("--reviewers-only", action="store_true")
    ap.add_argument("--now")
    a = ap.parse_args(argv)
    if a.reviewers_json or a.reviewers_only:
        if a.ledger is None or a.changes is None or a.cr_ledger is None:
            ap.error("--reviewers-json and --reviewers-only need --ledger, --changes and --cr-ledger")
        return reviewers_cli(a)
    if a.panel:
        rows, _ = cr_ledger_eval.load(a.cr_ledger or cr_ledger_eval.default_ledger(), a.until)
        text = panel(rows, a.until, a.min_findings)
        if a.out:
            return write_panel(a.out, text)
        sys.stdout.write(text)
        return 0
    path = eval_runs.ledger_path(a.ledger)
    rows = eval_runs.read_rows(path) if os.path.exists(path) else []
    text = page(rows, eval_feedback.read_changes(eval_feedback.changes_path(a.changes)))
    if a.out:
        with open(a.out, "w", encoding="utf-8") as fh:
            fh.write(text)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
