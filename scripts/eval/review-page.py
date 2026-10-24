#!/usr/bin/env python3
"""scripts/eval/review-page.py - the readable page over the reviewer evals (HIMMEL-6943).

Reads the eval-runs ledger (lib/eval_runs.py) and the eval-changes ledger (lib/eval_feedback.py) and
writes one Markdown page in plain words: how often the critics catch planted bugs and are right
(review-panel), how often the judges let a bug past a GO (judge-accuracy), the trend since the last
run of the same series, and each change the feedback step made with its re-measured result. The page
carries no metric names: a number with no sentence here is not shown.

  review-page.py [--ledger P] [--changes P] [--out FILE]

Ledgers: $HIMMEL_EVAL_RUNS_LEDGER / $HIMMEL_EVAL_CHANGES_LEDGER, else ~/.himmel/. Prints the page, or
writes it to --out. Exit 0. Stdlib only; no network, no model call.
ponytail: Markdown on stdout only, no config-ui route; serve it from scripts/config-ui when the page
needs to be live.
"""
import argparse
import os
import sys
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
import eval_feedback  # noqa: E402
import eval_runs  # noqa: E402

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
VERDICTS = {"improved": "it helped", "regressed": "it made things worse", "flat": "no real change"}


def pct(x):
    return int(x * 100 + 0.5)


def day(ts):
    try:
        d = datetime.strptime(ts[:10], "%Y-%m-%d")
        return "%d %s" % (d.day, d.strftime("%b %Y"))
    except (TypeError, ValueError):
        return "an unknown day"


def plain(name):
    return name.replace("-", " ").replace("_", " ").replace(".", " ")


def latest(rows, eval_id):
    """(newest usable row, the newest earlier row of the same series) for one eval."""
    mine = [r for r in rows if r["eval"] == eval_id and r["status"] in ("ok", "partial")]
    if not mine:
        return None, None
    cur = mine[-1]
    prev = [r for r in mine[:-1] if r["confighash"] == cur["confighash"]]
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
        s = rate(cur, prev, w + ".recall")
        if s and n:
            said.append("%s caught %d of %d planted bugs%s." % (name, round(m[w + ".recall"] * n), n, s))
        f = count(m, w + ".findings")
        s = rate(cur, prev, w + ".precision")
        if s and f:
            said.append("%s was right %d times in %d findings%s." % (name, round(m[w + ".precision"] * f), f, s))
        c = count(m, w + ".clean_scored")
        s = rate(cur, prev, w + ".fp_rate", lower_better=True)
        if s and c:
            said.append("%s raised a blocking finding on %d of %d clean changes%s." %
                        (name, round(m[w + ".fp_rate"] * c), c, s))
        if classes:
            cls = min(sorted(classes), key=lambda c: classes[c])
            cn = count(m, "%s.class.%s.n" % (w, cls))
            said.append("%s's weakest kind of bug: %s, caught %d of %d." %
                        (name, BUG_CLASSES.get(cls, plain(cls)), round(classes[cls] * cn), cn))
        out += ["- " + x for x in said]
    return out


def judge_lines(cur, prev):
    m = cur["metrics"]
    meta = cur.get("meta") or {}
    out = ["Verdicts written from %s to %s." % (day(meta.get("since")), day(meta.get("until"))), ""]
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
        out.append("- %d NO-GO PRs were merged over by the console; they count as overruled, not as wrong." %
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


def change_lines(changes):
    opened = [c for c in changes if c.get("status") == "open" and c.get("eval") in ("review-panel", "judge-accuracy")]
    done = {c["id"]: c for c in changes if c.get("status") == "measured"}
    out = []
    for c in opened:
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
            why += ": %d %%, the bar is %d %%" %(pct(c["value"]), pct(c["threshold"]))
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


def page(rows, changes):
    out = ["# How good are our reviewers?", "",
           "Each number comes from the newest run. \"Likely between\" is the 95 % range: given how much "
           "a run measured, the true rate is likely inside it.", "",
           "## The critics on planted bugs", ""]
    cur, prev = latest(rows, "review-panel")
    if cur is None:
        out.append("No run yet.")
    else:
        out += ["Run of %s, %d test changes." % (day(cur["ts"]), cur["n"] or 0), ""] + critic_lines(cur, prev)
    out += ["", "## The judges", ""]
    cur, prev = latest(rows, "judge-accuracy")
    out += ["No run yet."] if cur is None else judge_lines(cur, prev)
    out += ["", "## What we changed, and whether it helped", ""]
    out += change_lines(changes) or ["No change yet."]
    return "\n".join(out) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger")
    ap.add_argument("--changes")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
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
