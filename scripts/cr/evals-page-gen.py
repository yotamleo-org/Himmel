#!/usr/bin/env python3
"""evals-page-gen.py - the generator behind docs/evals/README.md (HIMMEL-6876).

Two steps, so the page holds no figure of its own:

  data    reads the CR verdict ledger and the output of `cache-probe.sh first-turn`, writes the data file
          (default docs/evals/evals-data.json): per-critic and pooled precision with a Wilson 95%
          interval, the bootstrap-by-PR interval beside it, the findings-in / findings-out split, and
          the prompt-cache read ratio.
  render  writes the page from that data file. Every figure line ends "as of <date>, n = <n>" and links
          its method page.

  evals-page-gen.py data   [--ledger P] [--until TS] --cache-probe FILE [--cache-scope TEXT] [--as-of YYYY-MM-DD] [--out FILE]
  evals-page-gen.py render [--data FILE] [--out FILE]

The ledger tally is scripts/eval/cr-ledger/cr_ledger_eval.py's load/fold (the amend fold cr-scores.sh
does, "fixed" counted as agreed), imported, not copied; the suite pins the counts to cr-scores.sh.
Precision is agreed / (agreed + disproved), the definition on docs/evals/review-panel.md.
Exit 0 written; 2 refused input. Stdlib only; no network, no model call.
ponytail: the cache figure is one cache-probe run's read ratio over tokens, with no interval (tokens
within a session are not independent), upgrade path a per-session ratio and a bootstrap by session.
"""
import argparse
import datetime
import json
import math
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "eval", "cr-ledger"))
import cr_ledger_eval  # noqa: E402

DATA_DEFAULT = os.path.join(HERE, "..", "..", "docs", "evals", "evals-data.json")
Z95 = 1.959964
BAR = 20
MIN_RULED = 30
REVIEW_CMD = "python3 scripts/cr/evals-page-gen.py data --cache-probe cache-probe.txt --as-of <date>"
CACHE_CMD = "bash scripts/eval/cache-probe.sh first-turn ~/.claude/projects/<project-dir>/*.jsonl > cache-probe.txt"
RENDER_CMD = "python3 scripts/cr/evals-page-gen.py render"


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
    m = re.search(r"^read-ratio: ([0-9.]+)% over ([0-9]+) tokens$", text, re.M)
    if not m:
        die("no 'read-ratio: <pct>% over <n> tokens' line in " + path)
    w = re.search(r"^verdict: \S+ warm=([0-9]+) cold=([0-9]+)", text, re.M)
    return {
        "read_ratio_pct": float(m.group(1)), "tokens": int(m.group(2)),
        "sessions": int(w.group(1)) + int(w.group(2)) if w else None,
        "warm": int(w.group(1)) if w else None, "cold": int(w.group(2)) if w else None,
    }


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
    cache = read_cache(args.cache_probe)
    cache["command"] = CACHE_CMD
    cache["scope"] = args.cache_scope
    cache["as_of"] = as_of
    return {
        "v": 1, "generator": "scripts/cr/evals-page-gen.py",
        "review": {
            "as_of": as_of, "until": args.until or None, "command": REVIEW_CMD,
            "pooled": group(findings), "critics": ordered,
        },
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


def render(d):
    r, c = d["review"], d["cache"]
    p = r["pooled"]
    ruled = stamp(r["as_of"], p["n"], "ruled findings over " + prs(p["prs"]))
    out = [
        "---", "draft: true", "---", "",
        "# Evals: how often a review finding is right, and what caching saves", "",
        "> Generated page, do not edit. Every figure comes from `docs/evals/evals-data.json`, written by "
        "`scripts/cr/evals-page-gen.py`. Draft: not on the site. Publishing it is adding it to "
        "`site/allowlist.txt` and the Reference nav entry, an operator call.", "",
        "Two questions a user weighs before trusting the review step: how often is a finding right, "
        "and what does the prompt cache save. Each figure carries its date and sample size, links the "
        "page that explains how it was measured, and names the command that regenerates it.", "",
        "## How often is a review finding right?", "",
        "Precision here is agreed ÷ (agreed + disproved): of the findings the author ruled true or false, "
        "the share ruled true. It is a proxy, because the author who rules is also the one who fixes. "
        "Deferred and unadjudicated findings are in neither side. The interval is a Wilson interval at "
        "the 95 percent level on the ruled findings; the bootstrap interval, resampled by PR, sits beside it.", "",
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
        out.append(precision_line("`%s`: " % name, g, s))
    hidden = sum(1 for g in r["critics"].values() if g["n"] < MIN_RULED)
    out += [
        "", "A reviewer is the panel slug plus the model that answered, so a model re-pin is a new reviewer. "
        "%s with fewer than %d ruled findings %s left out: too few to rank." % (
            "%d reviewers" % hidden if hidden != 1 else "One reviewer", MIN_RULED, "are" if hidden != 1 else "is"), "",
        "### Findings in, findings out", "",
        "- In: %s findings raised, %s." % (num(p["findings"]), stamp(r["as_of"], p["findings"], "findings")),
    ]
    for key, word in (("agreed", "agreed"), ("disproved", "disproved"), ("deferred", "deferred"),
                      ("unadjudicated", "no verdict")):
        share = p[key] / p["findings"] if p["findings"] else 0.0
        out.append("- Out, %s: %s of %s, %.1f%% `%s`, %s. Method: [review panel](review-panel.md)." % (
            word, num(p[key]), num(p["findings"]), share * 100, bar(share),
            stamp(r["as_of"], p["findings"], "findings")))
    sess = " over %s sessions" % num(c["sessions"]) if c.get("sessions") else ""
    scope = " (%s)" % c["scope"] if c.get("scope") else ""
    out += [
        "", "Regenerate: `%s`, then `%s`." % (r["command"], RENDER_CMD), "",
        "## How much does caching save?", "",
        "- **%s%%** of input tokens were cache reads (served from the prompt cache) rather than uncached input or cache writes, %s. "
        "Method: [prompt cache](prompt-cache.md)." % (
            c["read_ratio_pct"], stamp(c["as_of"], c["tokens"], "tokens" + sess + scope)),
        "", "Regenerate, in order:", "",
        "1. `%s`" % c["command"], "2. `%s`" % r["command"], "3. `%s`" % RENDER_CMD, "",
    ]
    return "\n".join(out)


def write(path, text):
    try:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
    except OSError as e:
        die("cannot write %s: %s" % (path, e))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="evals-page-gen.py", description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("data")
    d.add_argument("--ledger")
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
