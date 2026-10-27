#!/usr/bin/env python3
"""evals-page-gen.py - the generator behind docs/evals/README.md (HIMMEL-6876).

Two steps, so the page holds no figure of its own:

  data    reads the CR verdict ledger, the eval-runs ledger, the reviewer panel (critics.json) and the
          output of `cache-probe.sh first-turn`, writes the data file (default docs/evals/evals-data.json):
          per-critic and pooled precision with a Wilson 95% interval, the bootstrap-by-PR interval beside
          it, each critic marked with the panel reviewer it belongs to (none: history), the findings-in /
          findings-out split, the planted-bug catch from the newest review-panel row, the proof-first share
          from the newest pdd-share row, the test-first share from trajectory version 2 rows, and the
          prompt-cache read ratio.
  render  writes the page from that data file: the bottom line, the current setup, the history, then the
          reading guide. Every figure line carries "as of <date>, n = <n>".

  evals-page-gen.py data   [--ledger P] [--eval-runs P] [--critics P] [--until TS] --cache-probe FILE
                           [--cache-scope TEXT] [--as-of YYYY-MM-DD] [--out FILE]
  evals-page-gen.py render [--data FILE] [--out FILE]

The ledger tally is scripts/eval/cr-ledger/cr_ledger_eval.py's load/fold (the amend fold cr-scores.sh
does, "fixed" counted as agreed), imported, not copied; the suite pins the counts to cr-scores.sh.
The test-first tally is scripts/eval/decision-158-answers.py's q1, imported, not copied.
Precision is agreed / (agreed + disproved), the definition on docs/evals/review-panel.md.
--until cuts the CR ledger and the eval-runs ledger alike, so a cut regenerates the same figures.
Exit 0 written; 2 refused input. Stdlib only; no network, no model call.
ponytail: the cache figure is one cache-probe run's read ratio over tokens, with no interval (tokens
within a session are not independent), upgrade path a per-session ratio and a bootstrap by session.
"""
import argparse
import datetime
import importlib.util
import json
import os
import re
import shlex
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "eval", "cr-ledger"))
sys.path.insert(0, os.path.join(HERE, "..", "eval", "lib"))
import cr_ledger_eval  # noqa: E402
import eval_runs  # noqa: E402
from wilson import wilson  # noqa: E402

DATA_DEFAULT = os.path.join(HERE, "..", "..", "docs", "evals", "evals-data.json")
CRITICS_DEFAULT = os.path.join(HERE, "critics.json")
D158 = os.path.join(HERE, "..", "eval", "decision-158-answers.py")
BAR = 20
MIN_RULED = 30
CACHE_CMD = ("bash scripts/eval/cache-probe.sh first-turn $(find ~/.claude/projects/<project-dir> -maxdepth 1 "
             "-name '*.jsonl' -newermt <first-day> ! -newermt <day-after-last-day>) > cache-probe.txt")
RENDER_CMD = "python3 scripts/cr/evals-page-gen.py render"
PDD_METHOD = "[proof-first share](../../scripts/eval/README.md)"
TF_METHOD = "[test-first record](../../scripts/eval/README.md)"
PLANTED_METHOD = "[planted-bug eval](../../scripts/eval/review-panel/README.md)"
REVIEW_METHOD = "[review panel](review-panel.md)"
OPTIONS = "[Review by a second model](../configuration.md#review-by-a-second-model)"
TAG_NOTE = {"outside": "findings on lines outside the diff"}


def die(msg):
    print("evals-page-gen: " + msg, file=sys.stderr)
    sys.exit(2)


def pct1(x):
    return None if x is None else round(x * 100, 1)


def wilson_pct(k, n):
    """95% Wilson score interval for k of n, in percent to one decimal."""
    c = wilson(k, n, digits=None)
    return None if c is None else {"lo": pct1(c["lo"]), "hi": pct1(c["hi"])}


def group(findings):
    """One critic's (or the pool's) figures from its folded findings."""
    s = cr_ledger_eval.split(findings)
    ruled = s["agreed"] + s["disproved"]
    ci = s["precision_ci"]
    return {
        "findings": s["n"], "prs": s["prs"],
        "agreed": s["agreed"], "disproved": s["disproved"],
        "deferred": s["deferred"], "unadjudicated": s["unadjudicated"],
        "n": ruled,
        "precision_pct": pct1(s["agreed"] / ruled) if ruled else None,
        "wilson": wilson_pct(s["agreed"], ruled),
        "bootstrap": None if ci is None else {"lo": pct1(ci["lo"]), "hi": pct1(ci["hi"])},
        "first": s["first"][:10], "last": s["last"][:10],
    }


def read_cache(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        die("cannot read the cache-probe output: %s" % e)
    if not re.search(r"^cache-probe first-turn$", text, re.M):
        die("not `cache-probe.sh first-turn` output: " + path)
    m = re.search(r"^read-ratio: ([0-9]+(?:\.[0-9]+)?)% over ([0-9]+) tokens$", text, re.M)
    if not m:
        die("no 'read-ratio: <pct>% over <n> tokens' line in " + path)
    ratio = float(m.group(1))
    if ratio > 100:
        die("the read ratio %s%% in %s is above 100" % (m.group(1), path))
    if int(m.group(2)) == 0:
        die("the cache probe measured 0 tokens in " + path + ": no measurement to report")
    w = re.search(r"^verdict: \S+ warm=([0-9]+) cold=([0-9]+)$", text, re.M)
    if not w:
        die("no 'verdict: <word> warm=<n> cold=<n>' line in " + path)
    warm, cold = int(w.group(1)), int(w.group(2))
    return {"read_ratio_pct": ratio, "tokens": int(m.group(2)), "sessions": warm + cold, "warm": warm, "cold": cold}


def share(k, n):
    return {"pct": pct1(k / n) if n else None, "k": k, "n": n}


def read_runs(path, until):
    if not os.path.isfile(path):
        die("eval-runs ledger not found: " + path)
    rows = eval_runs.read_rows(path)
    if until:
        cut = cr_ledger_eval.parse_ts(until)
        rows = [r for r in rows if (cr_ledger_eval.parse_ts(r.get("ts", "")) or cut) <= cut]
    return rows


def proof_first(rows):
    """The newest pdd-share row: older rows came from earlier matchers, so they are never pooled."""
    ok = [r for r in rows if r.get("eval") == "pdd-share" and r.get("status") == "ok"]
    if not ok:
        return None
    r = ok[-1]
    m, ci = r.get("metrics") or {}, r.get("ci") or {}
    out = {"as_of": r["ts"][:10]}
    for key in ("pdd", "ticket_first", "red_green"):
        g = share(m.get(key + ".k", 0), m.get(key + ".n", 0))
        c = ci.get(key + ".pct")
        g["wilson"] = {"lo": pct1(c["lo"]), "hi": pct1(c["hi"])} if c else None
        out[key] = g
    return out


def planted(rows):
    """The newest review-panel row: the share of planted bugs the panel caught, against a hidden key."""
    ok = [r for r in rows if r.get("eval") == "review-panel" and r.get("status") == "ok"]
    if not ok:
        return None
    r = ok[-1]
    m, ci = r.get("metrics") or {}, r.get("ci") or {}
    n, recall, c = m.get("defects", 0), m.get("panel.recall"), ci.get("panel.recall")
    return {
        "as_of": r["ts"][:10], "critics": (r.get("config") or {}).get("critics") or [],
        "k": int(round(recall * n)) if n and recall is not None else 0, "n": n, "cases": m.get("cases", 0),
        "pct": pct1(recall) if n else None,
        "wilson": {"lo": pct1(c["lo"]), "hi": pct1(c["hi"])} if c else None,
    }


def read_panel(path):
    """The reviewers critics.json runs today: name (slug, or slug:model when it pins one), mode, required."""
    try:
        with open(path, encoding="utf-8") as fh:
            rows = json.load(fh).get("panel")
    except (OSError, ValueError, AttributeError) as e:
        die("cannot read the critics file: %s" % e)
    if not isinstance(rows, list) or not all(isinstance(p, dict) and p.get("slug") for p in rows):
        die("no panel of slugged reviewers in " + path)
    out = []
    for p in rows:
        mode = p.get("mode") or ("best-effort" if p.get("provider") == "github-app" else "hard")
        name = p["slug"] + (":" + p["model"] if p.get("model") else "")
        out.append({"name": name, "mode": mode, "required": bool(p.get("required"))})
    return out


def owner(name, panel):
    """The panel reviewer a ledger reviewer belongs to: its own name, or a tag of a reviewer that pins no model."""
    for p in panel:
        if name == p["name"] or (":" not in p["name"] and name.startswith(p["name"] + "-")):
            return p["name"]
    return None


def test_first(rows, as_of):
    """decision-158's q1 tally; no share is reported under the MIN_RULED floor."""
    spec = importlib.util.spec_from_file_location("decision_158_answers", D158)
    d158 = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(d158)
    m = {}
    d158.q1(rows, d158.CUT, m, {}, {})
    k, n = m.get("q1.k", 0), m.get("q1.n", 0)
    out = share(k, n)
    out["wilson"] = wilson_pct(k, n)
    if n < MIN_RULED:
        out["pct"], out["wilson"] = None, None
    out["as_of"] = as_of
    out["min_n"] = MIN_RULED
    return out


def review_cmd(args, as_of):
    """The data step exactly as it ran, so the page's figures can be regenerated byte for byte."""
    cmd = ["python3", "scripts/cr/evals-page-gen.py", "data", "--cache-probe", "cache-probe.txt"]
    if args.critics:
        cmd += ["--critics", args.critics]
    if args.cache_scope:
        cmd += ["--cache-scope", args.cache_scope]
    if args.until:
        cmd += ["--until", args.until]
    return " ".join(shlex.quote(c) for c in cmd + ["--as-of", as_of])


def build(args):
    path = args.ledger or cr_ledger_eval.default_ledger()
    rows, _ = cr_ledger_eval.load(path, args.until)
    findings = cr_ledger_eval.fold(rows)
    by = {}
    for f in findings:
        by.setdefault(f["critic"], []).append(f)
    panel = read_panel(args.critics or CRITICS_DEFAULT)
    critics = {name: dict(group(fs), panel=owner(name, panel)) for name, fs in by.items()}
    ordered = dict(sorted(critics.items(), key=lambda kv: (-kv[1]["findings"], kv[0])))
    as_of = args.as_of or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    runs = read_runs(eval_runs.ledger_path(args.eval_runs), args.until)
    cache = read_cache(args.cache_probe)
    cache["command"] = CACHE_CMD
    cache["scope"] = args.cache_scope
    cache["as_of"] = as_of
    return {
        "v": 3, "generator": "scripts/cr/evals-page-gen.py",
        "review": {
            "as_of": as_of, "until": args.until or None, "command": review_cmd(args, as_of),
            "panel": panel, "pooled": group(findings), "critics": ordered,
        },
        "planted": planted(runs),
        "proof_first": proof_first(runs),
        "test_first": test_first(runs, as_of),
        "cache": cache,
    }


def num(n):
    return "{:,}".format(n)


def bar(share):
    k = int(round(share * BAR))
    return "█" * k + "░" * (BAR - k)


def prs(n):
    return "%s PR%s" % (num(n), "" if n == 1 else "s")


def stamp(as_of, n, what):
    return "as of %s, n = %s %s" % (as_of, num(n), what)


def reviewer(name, critics):
    """A bare slug whose other findings name a model is labelled, so it never reads as a model of its own."""
    if ":" not in name and any(other.startswith(name + ":") for other in critics):
        return "`%s` (model not recorded)" % name
    return "`%s`" % name


def rng(w):
    return "%s to %s" % (w["lo"], w["hi"]) if w else "none"


def role(p):
    """What a panel reviewer must do before a merge, in plain words (docs/configuration.md, Reviewer modes)."""
    if p["mode"] == "best-effort":
        return "best effort: holds a merge only on a posted finding"
    if p["required"]:
        return "required: must pass before every merge"
    return "must pass where it runs; skipped on a machine without it"


def render(d):
    r, c = d["review"], d["cache"]
    pl, pf, tf = d.get("planted"), d.get("proof_first"), d["test_first"]
    p, crit, panel = r["pooled"], r["critics"], r["panel"]

    def ruled(g):
        return stamp(r["as_of"], g["n"], "ruled findings over " + prs(g["prs"]))

    def prec_cells(g):
        return "**%s%%** | %s | %s" % (g["precision_pct"], rng(g["wilson"]), rng(g["bootstrap"]))

    out = [
        "# Evals: what the review panel catches, how often it is right, and what caching saves", "",
        "> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by "
        "`scripts/cr/evals-page-gen.py`.", "",
        "## Bottom line", "",
        "| Question | Answer | Likely range | Sample |",
        "|---|---|---|---|",
    ]
    if pl and pl["pct"] is not None:
        who = ", ".join("`%s`" % s for s in pl["critics"]) or "the panel"
        out.append("| Does the review panel catch bugs? | **%s%%**: %s caught %d of %d planted bugs | %s | %s |" % (
            pl["pct"], who, pl["k"], pl["n"], rng(pl["wilson"]),
            stamp(pl["as_of"], pl["n"], "planted bugs in %s test changes" % num(pl["cases"]))))
    else:
        out.append("| Does the review panel catch bugs? | not measured yet: no planted-bug run | | as of %s |" % r["as_of"])
    heads = [(q["name"], crit[q["name"]]) for q in panel
             if q["required"] and q["name"] in crit and crit[q["name"]]["n"] >= MIN_RULED]
    for name, g in heads:
        out.append("| When the required reviewer flags something, is it right? | **%s%%** of %s findings ruled right "
                   "| Wilson %s; by PR %s | %s |" % (
                       g["precision_pct"], reviewer(name, crit), rng(g["wilson"]), rng(g["bootstrap"]), ruled(g)))
    if not heads:
        out.append("| When the required reviewer flags something, is it right? | not measured yet: fewer than %d "
                   "ruled findings | | as of %s |" % (MIN_RULED, r["as_of"]))
    if pf:
        out.append("| Is work proven before it is built? | **%s%%** of merged PRs were proof-first | %s | %s |" % (
            pf["pdd"]["pct"], rng(pf["pdd"]["wilson"]), stamp(pf["as_of"], pf["pdd"]["n"], "merged PRs")))
    sess = " over %s sessions" % num(c["sessions"]) if c.get("sessions") else ""
    scope = " (%s)" % c["scope"] if c.get("scope") else ""
    out += [
        "| What does the prompt cache save? | **%s%%** of input tokens were cache reads, not uncached input "
        "or cache writes | no interval | %s |" % (
            c["read_ratio_pct"], stamp(c["as_of"], c["tokens"], "tokens" + sess + scope)), "",
        "The precision headline is the required reviewer's own, not the all-reviewers pooled figure under History: "
        "the pool mixes in models the panel no longer runs. Likely range is the 95 percent interval; every term is "
        "defined under How to read these numbers.", "",
        "## Current setup", "",
        "The reviewers `scripts/cr/critics.json` runs on every PR today. To change the set (a cheaper tier, a "
        "required non-Claude reviewer, a reviewer added or dropped on one machine), see %s." % OPTIONS, "",
        "| Reviewer | What it must do | Precision | Wilson range | Range by PR | Sample |",
        "|---|---|---|---|---|---|",
    ]
    for q in panel:
        tags = [q["name"]] + [n for n, g in crit.items() if g.get("panel") == q["name"] and n != q["name"]]
        for name in tags:
            g = crit.get(name)
            what = role(q) if name == q["name"] else "part of `%s`: %s" % (
                q["name"], TAG_NOTE.get(name[len(q["name"]) + 1:], "its ledger tag " + name))
            if not g:
                out.append("| %s | %s | no ruled findings yet | | | as of %s |" % (reviewer(name, crit), what, r["as_of"]))
            elif g["n"] < MIN_RULED:
                out.append("| %s | %s | too few to rank | | | %s |" % (reviewer(name, crit), what, ruled(g)))
            else:
                out.append("| %s | %s | %s | %s |" % (reviewer(name, crit), what, prec_cells(g), ruled(g)))
    out += [
        "", "Precision is the share of a reviewer's ruled findings that were right; when the two ranges disagree, "
        "trust the wider one. Method: %s." % REVIEW_METHOD, "",
        "## History and what we learned", "",
        "Every reviewer the ledger holds that the panel no longer runs, oldest first. A reviewer is the panel slug plus the model "
        "that answered, so a model re-pin is a new reviewer.", "",
        "| Reviewer | Ran | Precision | Wilson range | Range by PR | Sample |",
        "|---|---|---|---|---|---|",
    ]
    old = sorted(((n, g) for n, g in crit.items() if not g.get("panel")), key=lambda kv: (kv[1]["first"], kv[0]))
    for name, g in old:
        if g["n"] >= MIN_RULED:
            out.append("| %s | %s to %s | %s | %s |" % (reviewer(name, crit), g["first"], g["last"], prec_cells(g), ruled(g)))
    if p["n"]:
        out.append("| All reviewers pooled | %s to %s | %s | %s |" % (p["first"], p["last"], prec_cells(p), ruled(p)))
    hidden = sum(1 for _, g in old if g["n"] < MIN_RULED)
    out += [
        "", "A row marked (model not recorded) holds the findings whose ledger record names no answering model "
        "for that review; they are kept apart, never folded into a named model, because which model raised them "
        "is unknown. %s with fewer than %d ruled findings %s left out: too few to rank. What the history taught, "
        "with the analysis behind it: %s." % (
            "%d reviewers" % hidden if hidden != 1 else "One reviewer", MIN_RULED,
            "are" if hidden != 1 else "is", REVIEW_METHOD), "",
        "### Findings in, findings out", "",
        "| Outcome | Findings | Share | Sample |",
        "|---|---|---|---|",
        "| Raised | %s | | %s |" % (num(p["findings"]), stamp(r["as_of"], p["findings"], "findings")),
    ]
    for key, word in (("agreed", "Agreed"), ("disproved", "Disproved"), ("deferred", "Deferred"),
                      ("unadjudicated", "No verdict")):
        part = p[key] / p["findings"] if p["findings"] else 0.0
        out.append("| %s | %s of %s | %.1f%% `%s` | %s |" % (
            word, num(p[key]), num(p["findings"]), part * 100, bar(part), stamp(r["as_of"], p["findings"], "findings")))
    out += [
        "", "Every reviewer, current and past. Only agreed and disproved count toward precision; deferred and "
        "no-verdict findings sit outside it. Method: %s." % REVIEW_METHOD, "",
        "## Proof first and test first", "",
        "| Measure | Share | Likely range | Sample |",
        "|---|---|---|---|",
    ]
    if pf:
        for key, what in (("pdd", "Proof-first: both halves below"),
                          ("ticket_first", "The ticket's DoD and Proof written before the first commit"),
                          ("red_green", "RED and then GREEN named in the PR body")):
            g = pf[key]
            out.append("| %s | **%s%%** | %s | %s |" % (what, g["pct"], rng(g["wilson"]), stamp(pf["as_of"], g["n"], "merged PRs")))
    else:
        out.append("| Proof-first | not measured yet: the eval-runs ledger holds no pdd-share row | | as of %s |" % r["as_of"])
    sessions = stamp(tf["as_of"], tf["n"], "session%s scored under trajectory version 2" % ("" if tf["n"] == 1 else "s"))
    if tf["pct"] is None:
        out.append("| Test first: a test failed before the implementation and passed after | not measured yet; it needs %d "
                   "| | %s |" % (tf["min_n"], sessions))
    else:
        out.append("| Test first: a test failed before the implementation and passed after | **%s%%** | %s | %s |" % (
            tf["pct"], rng(tf["wilson"]), sessions))
    out += [
        "", "A merged PR is proof-first only when it has both halves; each half is shown on its own. "
        "Method: %s and %s." % (PDD_METHOD, TF_METHOD), "",
        "## How to read these numbers", "",
        "| Term | Meaning |",
        "|---|---|",
        "| **Precision** | Agreed ÷ (agreed + disproved): of the findings someone ruled true or false, the share ruled "
        "true. The PR author rules (in practice the Claude session that wrote the PR), and a finding marked `fixed` "
        "counts as agreed. A precision proxy, not precision: the one who rules is also the one who has to fix. "
        "%s |" % REVIEW_METHOD,
        "| **Planted-bug catch** | Bugs planted in test changes with a hidden answer key, and the share the reviewer "
        "found. It measures what real PRs cannot: the bugs nobody flagged. %s |" % PLANTED_METHOD,
        "| **Wilson range** | The 95 percent range the true share most likely sits in, given how many findings were "
        "ruled. It treats every finding as independent of the others. |",
        "| **Range by PR** | A bootstrap that resamples whole PRs, not single findings. Findings on one PR share an "
        "author, a diff and a review loop, so they are not independent; counting that makes the range wider, most "
        "of all for a reviewer whose findings sit on few PRs. |",
        "| **n** | The sample behind a figure: for precision, the ruled findings and the PRs they came from. A small n "
        "is noise: one PR more or less can move the figure by many points, which is why a reviewer with fewer than "
        "%d ruled findings is not ranked. |" % MIN_RULED,
        "| **As of** | The day the figures were read off their ledgers; anything recorded later is not in them. |",
        "| **Left out of precision** | Deferred findings (real or plausible, filed as a follow-up instead of fixed in "
        "that PR) and findings nobody ruled on. They show only under Findings in, findings out. |",
        "| **Proof-first** | The share of the last merged PRs whose ticket had its DoD and Proof written before the "
        "first commit, and whose PR body names RED and then GREEN. Only the newest measurement counts, because older "
        "ones came from an earlier matcher. |",
        "| **Test first** | The share of agent sessions that wrote code in which a test failed before the first "
        "implementation write and passed after it; a session that wrote no code is left out. Only sessions scored "
        "under trajectory version 2 count: version 1 scored a session that wrote no code as a miss, so the two are "
        "never mixed. It reads not measured yet until %d such sessions exist. |" % MIN_RULED,
        "| **Cache reads** | One probe run's share of input tokens read from the cache. No interval: tokens within "
        "one session are not independent. [prompt cache](prompt-cache.md) |", "",
        "## Regenerate", "",
        "A new planted-bug row comes from the %s; a new proof-first row from "
        "`python3 scripts/eval/worker-digest/pdd_share.py --limit 120 --record`; test-first sessions are written as "
        "agent sessions end. Then run steps 2 and 3 with --until and --as-of moved past the new row." % PLANTED_METHOD, "",
        "1. `%s` (the transcripts modified from the sample's first day to its last)" % c["command"],
        "2. `%s`" % r["command"], "3. `%s`" % RENDER_CMD, "",
    ]
    return "\n".join(out)


def write(path, text):
    """Write to a temporary file beside path, then rename it over path: atomic, never through a symlink."""
    try:
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(path)), prefix=".evals-page-gen.")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(text)
        mask = os.umask(0)
        os.umask(mask)
        os.chmod(tmp, 0o666 & ~mask)
        os.replace(tmp, path)
    except OSError as e:
        die("cannot write %s: %s" % (path, e))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="evals-page-gen.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("data")
    d.add_argument("--ledger")
    d.add_argument("--eval-runs", help="the eval-runs ledger (default $HIMMEL_EVAL_RUNS_LEDGER, else ~/.himmel/eval-runs.jsonl)")
    d.add_argument("--until")
    d.add_argument("--critics", help="the reviewer panel (default scripts/cr/critics.json)")
    d.add_argument("--cache-probe", required=True)
    d.add_argument("--cache-scope", default="", help="what the probed transcripts are, printed under the cache figure")
    d.add_argument("--as-of")
    d.add_argument("--out", default=DATA_DEFAULT)
    r = sub.add_parser("render")
    r.add_argument("--data", default=DATA_DEFAULT)
    r.add_argument("--out", default=os.path.join(os.path.dirname(DATA_DEFAULT), "README.md"))
    args = ap.parse_args(argv)
    if args.cmd == "data":
        write(args.out, json.dumps(build(args), indent=2) + "\n")
    else:
        try:
            with open(args.data, encoding="utf-8") as fh:
                data = json.load(fh)
        except (OSError, ValueError) as e:
            die("cannot read the data file: %s" % e)
        write(args.out, render(data))
    return 0


if __name__ == "__main__":
    sys.exit(main())
