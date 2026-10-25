#!/usr/bin/env python3
"""scripts/eval/review-page.py - the readable page over the reviewer evals (HIMMEL-6943).

Reads the eval-runs ledger (lib/eval_runs.py) and the eval-changes ledger (lib/eval_feedback.py) and
writes one Markdown page in plain words: how often the critics catch planted bugs and are right
(review-panel), how often the judges let a bug past a GO (judge-accuracy), the trend since the last
run of the same series, and each change the feedback step made with its re-measured result. The page
carries no metric names: a number with no sentence here is not shown.

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
ponytail: the page is rendered by the weekly judge-accuracy cadence into the file scripts/config-ui's
/api/reviewers serves; it is not live-updating, upgrade path a push from the ledger append.
"""
import argparse
import collections
import os
import re
import statistics
import sys
from datetime import datetime

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
    if "coderabbit" not in who:
        out.append("- CodeRabbit is not measured yet: it needs a scratch pull request.")
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
    changes = [c for c in changes if isinstance(c, dict)]
    opened = [c for c in changes if c.get("status") == "open" and c.get("eval") in ("review-panel", "judge-accuracy")
              and isinstance(c.get("metric"), str)]
    done = {c["id"]: c for c in changes if c.get("status") == "measured" and "id" in c}
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
           "Each critic and judge number comes from the newest run, and a trend compares it with the run "
           "before. Each change's result comes from the run that re-measured it. \"Likely between\" is a range: given how much "
           "a run measured, the true rate is likely inside it.", "",
           "## The critics on planted bugs", ""]
    cur, prev = latest(rows, "review-panel")
    if cur is None:
        out.append("No run yet.")
    else:
        out += ["Run of %s, %d test changes.%s" % (day(cur["ts"]), cur["n"] or 0, level(cur)), ""] + critic_lines(cur, prev)
    out += ["", "## The judges", ""]
    cur, prev = latest(rows, "judge-accuracy")
    out += ["No run yet."] if cur is None else judge_lines(cur, prev)
    out += ["", "## The five open questions", ""]
    cur, _ = latest(rows, "decision-158")
    out += ["No run yet."] if cur is None else answer_lines(cur)
    out += ["", "## What we changed, and whether it helped", ""]
    out += change_lines(changes) or ["No change yet."]
    return "\n".join(out) + "\n"


def claim(text):
    """A finding's claim without its severity tag or trailing [file:line] citation, case and punctuation folded
    (comparison operators kept)."""
    t = re.sub(r"^\s*-\s*\[[^\]]+\]\s*:\s*", "", text or "")
    t = re.sub(r"\s*\[[^\]\r\n]+:\d+(?:-\d+)?\]\s*$", "", t)
    return re.sub(r"[^a-z0-9=!<>]+", " ", t.lower()).strip()


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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--ledger")
    ap.add_argument("--changes")
    ap.add_argument("--out")
    ap.add_argument("--panel", action="store_true")
    ap.add_argument("--cr-ledger")
    ap.add_argument("--until")
    ap.add_argument("--min-findings", type=int, default=SMALL)
    a = ap.parse_args(argv)
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
