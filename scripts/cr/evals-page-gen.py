#!/usr/bin/env python3
"""evals-page-gen.py - the generator behind docs/evals/README.md (HIMMEL-6876).

Two steps, so the page holds no figure of its own:

  data    reads the CR verdict ledger, the eval-runs ledger and the output of `cache-probe.sh first-turn`,
          writes the data file (default docs/evals/evals-data.json): per-critic and pooled precision with a
          Wilson 95% interval, the bootstrap-by-PR interval beside it, the findings-in / findings-out split,
          the proof-first share from the newest pdd-share row, the test-first share from trajectory
          version 2 rows, and the prompt-cache read ratio.
  render  writes the page from that data file. Every figure line ends "as of <date>, n = <n>" and links
          its method page.

  evals-page-gen.py data   [--ledger P] [--eval-runs P] [--until TS] --cache-probe FILE [--cache-scope TEXT]
                           [--as-of YYYY-MM-DD] [--out FILE]
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
import math
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

DATA_DEFAULT = os.path.join(HERE, "..", "..", "docs", "evals", "evals-data.json")
D158 = os.path.join(HERE, "..", "eval", "decision-158-answers.py")
Z95 = 1.959964
BAR = 20
MIN_RULED = 30
CACHE_CMD = ("bash scripts/eval/cache-probe.sh first-turn $(find ~/.claude/projects/<project-dir> -maxdepth 1 "
             "-name '*.jsonl' -newermt <first-day>) > cache-probe.txt")
RENDER_CMD = "python3 scripts/cr/evals-page-gen.py render"
PDD_METHOD = "[proof-first share](../../scripts/eval/README.md)"
TF_METHOD = "[test-first record](../../scripts/eval/README.md)"


def die(msg):
    print("evals-page-gen: " + msg, file=sys.stderr)
    sys.exit(2)


def wilson_pct(k, n):
    """95% Wilson score interval for k of n, in percent to one decimal (unrounded until the end)."""
    if not n:
        return None
    p = k / n
    den = 1 + Z95 * Z95 / n
    mid = (p + Z95 * Z95 / (2 * n)) / den
    half = Z95 * math.sqrt(p * (1 - p) / n + Z95 * Z95 / (4 * n * n)) / den
    return {"lo": round(max(0.0, mid - half) * 100, 1), "hi": round(min(1.0, mid + half) * 100, 1)}


def pct1(x):
    return None if x is None else round(x * 100, 1)


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
    critics = {name: group(fs) for name, fs in by.items()}
    ordered = dict(sorted(critics.items(), key=lambda kv: (-kv[1]["findings"], kv[0])))
    as_of = args.as_of or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    runs = read_runs(eval_runs.ledger_path(args.eval_runs), args.until)
    cache = read_cache(args.cache_probe)
    cache["command"] = CACHE_CMD
    cache["scope"] = args.cache_scope
    cache["as_of"] = as_of
    return {
        "v": 2, "generator": "scripts/cr/evals-page-gen.py",
        "review": {
            "as_of": as_of, "until": args.until or None, "command": review_cmd(args, as_of),
            "pooled": group(findings), "critics": ordered,
        },
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


def render(d):
    r, c = d["review"], d["cache"]
    pf, tf = d.get("proof_first"), d["test_first"]
    p = r["pooled"]
    ruled = stamp(r["as_of"], p["n"], "ruled findings over " + prs(p["prs"]))
    out = [
        "# Evals: how often a review finding is right, how often work is proof-first, and what caching saves", "",
        "> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by "
        "`scripts/cr/evals-page-gen.py`.", "",
        "Three questions a user weighs before trusting the harness: how often is a review finding right, "
        "how often is work proven before it is built, and what does the prompt cache save. Each figure "
        "carries its date and sample size, links the page that explains how it was measured, and names "
        "the command that regenerates it.", "",
        "## How to read these numbers", "",
        "- **Precision** is agreed ÷ (agreed + disproved): of the findings someone ruled true or false, "
        "the share ruled true. The PR author rules (in practice the Claude session that wrote the PR), "
        "and a finding marked `fixed` counts as agreed. It is a precision proxy, not precision, because "
        "the one who rules is also the one who has to fix. Method: [review panel](review-panel.md).",
        "- **The 95 percent Wilson interval** is the range the true share most likely sits in, given how many "
        "findings were ruled. It treats every finding as independent of the others.",
        "- **The bootstrap by PR** is a second range that resamples whole PRs, not single findings. "
        "Findings on one PR share an author, a diff and a review loop, so they are not independent; "
        "counting that makes the range wider, most of all for a reviewer whose findings sit on few PRs. "
        "When the two disagree, trust the wider one.",
        "- **n** is the sample behind a figure: for precision, the ruled findings and the PRs they came "
        "from. A small n is noise: one PR more or less can move the figure by many points, which is why "
        "a reviewer with fewer than %d ruled findings is left out of the ranking." % MIN_RULED,
        "- **As of** is the day the figures were read off their ledgers; anything recorded later is not in them.",
        "- **Left out of precision:** deferred findings (real or plausible, filed as a follow-up instead "
        "of fixed in that PR) and findings nobody ruled on. They sit in neither side of the share and "
        "show only under Findings in, findings out.",
        "- **Proof-first share** is the share of the last merged PRs whose ticket had its DoD and Proof "
        "written before the first commit, and whose PR body names RED and then GREEN. Its range is a "
        "Wilson interval over the PRs read; only the newest measurement counts, because older ones came "
        "from an earlier matcher. Method: %s." % PDD_METHOD,
        "- **Test first** is the share of agent sessions that wrote code in which a test failed before "
        "the first implementation write and passed after it; a session that wrote no code is left out. "
        "Only sessions scored under trajectory version 2 count: version 1 scored a session that wrote no "
        "code as a miss, so the two are never mixed. Version 2 scoring is new, so the figure reads not "
        "measured yet until %d such sessions exist, the same floor as a reviewer's. Method: %s." % (
            MIN_RULED, TF_METHOD),
        "- **The cache figure** is one probe run's share of input tokens read from the cache. It has no "
        "interval: tokens within one session are not independent. Method: [prompt cache](prompt-cache.md).", "",
        "## How often is a review finding right?", "",
        "### All reviewers pooled", "",
    ]

    def precision_line(label, g, stamp_s):
        b = g["bootstrap"]
        boot = "; bootstrap by PR %s to %s" % (b["lo"], b["hi"]) if b else ""
        return ("- %s**%s%%** precision, 95%% Wilson interval %s to %s%s, %s. "
                "Method: [review panel](review-panel.md)." % (
                    label, g["precision_pct"], g["wilson"]["lo"], g["wilson"]["hi"], boot, stamp_s))

    if p["n"]:
        out.append(precision_line("", p, ruled))
    else:
        out.append("- No ruled findings yet, %s." % ruled)
    out += ["", "### Per reviewer", ""]
    shown = [(name, g) for name, g in r["critics"].items() if g["n"] >= MIN_RULED]
    for name, g in shown:
        s = stamp(r["as_of"], g["n"], "ruled findings over " + prs(g["prs"]))
        out.append(precision_line("%s: " % reviewer(name, r["critics"]), g, s))
    hidden = sum(1 for g in r["critics"].values() if g["n"] < MIN_RULED)
    out += [
        "", "A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer. "
        "A row marked (model not recorded) holds the findings whose ledger record names no answering model "
        "for that review; they are kept apart, never folded into a named model, because which model raised "
        "them is unknown. "
        "%s with fewer than %d ruled findings %s left out: too few to rank." % (
            "%d reviewers" % hidden if hidden != 1 else "One reviewer", MIN_RULED, "are" if hidden != 1 else "is"), "",
        "### Findings in, findings out", "",
        "- In: %s findings raised, %s. Method: [review panel](review-panel.md)." % (
            num(p["findings"]), stamp(r["as_of"], p["findings"], "findings")),
    ]
    for key, word in (("agreed", "agreed"), ("disproved", "disproved"), ("deferred", "deferred"),
                      ("unadjudicated", "no verdict")):
        part = p[key] / p["findings"] if p["findings"] else 0.0
        out.append("- Out, %s: %s of %s, %.1f%% `%s`, %s. Method: [review panel](review-panel.md)." % (
            word, num(p[key]), num(p["findings"]), part * 100, bar(part),
            stamp(r["as_of"], p["findings"], "findings")))
    out += ["", "Regenerate: `%s`, then `%s`." % (r["command"], RENDER_CMD), "",
            "## How often is work proof-first?", ""]
    if pf:
        def pdd_line(lead, g):
            return "- %s**%s%%**%s, 95%% Wilson interval %s to %s, %s. Method: %s." % (
                lead[0], g["pct"], lead[1], g["wilson"]["lo"], g["wilson"]["hi"],
                stamp(pf["as_of"], g["n"], "merged PRs"), PDD_METHOD)
        out += [
            pdd_line(("", " of merged PRs were proof-first"), pf["pdd"]),
            pdd_line(("Ticket first alone: ", " had the ticket's DoD and Proof before the first commit"), pf["ticket_first"]),
            pdd_line(("RED then GREEN alone: ", " named RED and then GREEN in the PR body"), pf["red_green"]),
        ]
    else:
        out.append("- Proof-first share: not measured yet, as of %s: the eval-runs ledger holds no pdd-share row." % r["as_of"])
    sessions = stamp(tf["as_of"], tf["n"], "session%s scored under trajectory version 2" % ("" if tf["n"] == 1 else "s"))
    if tf["pct"] is None:
        out.append("- Test first: not measured yet, %s; it needs %d. Method: %s." % (sessions, tf["min_n"], TF_METHOD))
    else:
        out.append("- **%s%%** of agent sessions that wrote code had a test fail before the implementation "
                   "and pass after it, 95%% Wilson interval %s to %s, %s. Method: %s." % (
                       tf["pct"], tf["wilson"]["lo"], tf["wilson"]["hi"], sessions, TF_METHOD))
    sess = " over %s sessions" % num(c["sessions"]) if c.get("sessions") else ""
    scope = " (%s)" % c["scope"] if c.get("scope") else ""
    out += [
        "", "Regenerate: `python3 scripts/eval/leg-digest/pdd_share.py --limit 120 --record` writes a new "
        "proof-first row; the test-first sessions are written as agent sessions end. Then run the "
        "review regenerate above with --until and --as-of moved past the new row.", "",
        "## How much does caching save?", "",
        "- **%s%%** of input tokens were cache reads (served from the prompt cache) rather than uncached input or cache writes, %s. "
        "Method: [prompt cache](prompt-cache.md)." % (
            c["read_ratio_pct"], stamp(c["as_of"], c["tokens"], "tokens" + sess + scope)),
        "", "Regenerate, in order:", "",
        "1. `%s` (the transcripts modified since the sample's first day)" % c["command"],
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
