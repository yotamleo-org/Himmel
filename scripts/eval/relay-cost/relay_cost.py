#!/usr/bin/env python3
# billed-exempt: prices a recorded stream and mentions claude -p only in text; run.sh holds the opt-in
"""scripts/eval/relay-cost/relay_cost.py - cost per relayed message and delivery correctness.

Stdlib only; no subcommand makes a model call (run.sh does, and hands this file the streams).

  relay_cost.py gen --out FILE
      Write the synthetic fixture set: three kinds (`succession` relay, `go`, `ruling`), three sizes each,
      sized around the medians of a survey of real chief traffic (aggregate counts only; no transcript
      text is read, copied or committed). A succession fixture expects the text relay-batch.sh prints.
  relay_cost.py check --fixtures FILE --id ID --delivery JSON-FILE [--path-file FILE]
      Exit 0 iff the delivery went to the right session with the right message. A delivery is
      {"to": ..., "message": ...}. `message` must equal the fixture's `expected` byte for byte
      (trailing newlines ignored). With --path-file (the path arm) `message` must instead name that
      file and the file's bytes must equal `expected`.
  relay_cost.py price STREAM.jsonl
      Sum a `claude -p --output-format stream-json` stream's last result usage into one JSON row.
  relay_cost.py report --runs DIR --fixtures FILE
      Table of options: pass rate, cost per message (cost-eq, USD), each as a percent of the Sonnet arm.
  relay_cost.py turn-price [--dir D] [--sessions 40]
      Median cache_read tokens of a worker turn: what the path option's extra Read turn costs the receiver.

Price table (input-equivalent tokens, the weights of scripts/eval/handover-cost.py and
scripts/lanes/lib/burn-weights.sh): input 1, cache_read 0.1, cache_creation 1.25, output 5.

ponytail: warm cost-eq prices the whole prefix as a cache read (a long-lived relay), upgrade path =
measure a --resume chain of messages instead.
"""

import argparse
import glob
import json
import os
import re
import sys

W_IN = float(os.environ.get("WORKER_SESSION_BURN_W_INPUT", "1"))
W_CR = float(os.environ.get("WORKER_SESSION_BURN_W_CACHE_READ", "0.1"))
W_CC = float(os.environ.get("WORKER_SESSION_BURN_W_CACHE_CREATE", "1.25"))
W_OUT = float(os.environ.get("WORKER_SESSION_BURN_W_OUTPUT", "5"))
DEFAULT_DIR = "~/.claude/projects/-home-overlord-Documents-github-himmel"
KINDS = ("succession", "go", "ruling")
# Message sizes from a survey of 38,972 chief SendMessage calls in 600 chief sessions
# (counts only, no text kept): succession relays 21% (median 462 chars), GO 8% (median 365), rulings 5% (median 580).
# The fixtures are synthetic: invented sessions, tokens and prose, sized around those medians.
FILLER = [
    "Start on the first item now and do not wait for the second.",
    "Keep the change inside your Writes line and name any file you add in your Results.",
    "Show the suite RED before the fix and GREEN after it, with the counts in the PR body.",
    "If the merge refuses for a stale base, send me the exact refusal and the head you tried.",
    "The earlier head had a failing shard, so a new head needs a fresh delta check.",
    "Do not touch the settings files; ask first if the ticket seems to need them.",
    "Record the decision on the ticket as a plain fact, with the commit sha.",
    "Option B is not granted, and the cap stays where it is.",
]


def succession_text(sender, successor, token):
    """The text relay-batch.sh's relay_text prints for a native worker with a held token."""
    return ("SUCCESSION relay from %s: your chief is now %s. Your current token `%s`. This is an S1 relay: "
            "accept it and keep working your sealed scope. Write your quote-back in your very next tool batch, "
            "with no ListAgents, also while wrapping. Your quote-back (no reply needed) is a Results bullet "
            "containing exactly the following, with nothing after it on that line: "
            "SUCCESSION accepted: %s replaces %s" % (sender, successor, token, successor, sender))


def pad(head, target):
    """Append FILLER sentences, cycling, until the text reaches target chars (never cut mid-sentence)."""
    text, i = head, 0
    while len(text) < target:
        text += " " + FILLER[i % len(FILLER)]
        i += 1
    return text


def gen_fixtures():
    fixtures = []
    succ = [("DEMO-nextleg-2026-01-01A-chief", "DEMO-nextleg-2026-01-01B-chief", "DEMO-1101-N9001-short-slug", "AA-N9001-0a1b2c3d"),
            ("DEMO-nextleg-2026-02-03C-chief", "DEMO-nextleg-2026-02-03D-chief", "DEMO-2203-N9002-a-longer-worker-doc-stem-2026-02-03", "BB-N9002-1b2c3d4e"),
            ("DEMO-nextleg-2026-03-05E-chief", "DEMO-nextleg-2026-03-05F-chief", "DEMO-3305-N9003-legN2b-a-resume-doc-with-a-very-long-stem-RESUME", "CC-N9003-2c3d4e5f")]
    for n, (sender, successor, worker, token) in enumerate(succ, 1):
        exp = succession_text(sender, successor, token)
        fixtures.append({"id": "succession-%d" % n, "kind": "succession", "to": worker,
                         "input": "SUCCESSION-RELAY sender=%s successor=%s worker=%s nonce=%s" % (sender, successor, worker, token),
                         "expected": exp, "chars": len(exp)})
    go = [("DEMO-4001-N9011-small-fix", 250), ("DEMO-4002-N9012-median-fix", 365), ("DEMO-4003-N9013-large-fix", 800)]
    for n, (worker, size) in enumerate(go, 1):
        sha = ("%040x" % (0x9abcdef0123456789 * (n + 7)))[-40:]
        head = ("GO %d %s (DD-N901%d-3d4e5f60), from chief DEMO-A. GO file: /home/USER/handovers/.locks/go/%d.%s. "
                "Merge bare: bash scripts/handover/merge-on-green.sh --go <that file>, then send MERGED #%d to <sha>, WRAPPED."
                % (5000 + n, sha, n, 5000 + n, sha, 5000 + n))
        exp = pad(head, size)
        fixtures.append({"id": "go-%d" % n, "kind": "go", "to": worker, "input": exp, "expected": exp, "chars": len(exp)})
    rul = [("DEMO-4101-N9021-small-ruling", 300), ("DEMO-4102-N9022-median-ruling", 580), ("DEMO-4103-N9023-large-ruling", 1100)]
    for n, (worker, size) in enumerate(rul, 1):
        head = ("RULING N902%d (EE-N902%d-4e5f6071): option C, then A. Scope grant: scripts/demo/%s.sh only. "
                "Why: the contract says a no-op is never a judged head.\nAdd a row for the refusal." % (n, n, worker.lower()))
        exp = pad(head, size)
        fixtures.append({"id": "ruling-%d" % n, "kind": "ruling", "to": worker, "input": exp, "expected": exp, "chars": len(exp)})
    return fixtures


def cmd_gen(a):
    fixtures = gen_fixtures()
    with open(a.out, "w") as fh:
        json.dump({"synthetic": True, "fixtures": fixtures}, fh, indent=1)
        fh.write("\n")
    print("generated %d synthetic fixtures -> %s" % (len(fixtures), a.out))
    return 0


def load_fixture(path, fid):
    with open(path) as fh:
        for f in json.load(fh)["fixtures"]:
            if f["id"] == fid:
                return f
    sys.exit("relay_cost: no fixture %s" % fid)


def verdict(fix, delivery, path_file=None):
    """(ok, reason)."""
    if not isinstance(delivery, dict) or not isinstance(delivery.get("to"), str) or not isinstance(delivery.get("message"), str):
        return False, "malformed delivery"
    if delivery["to"] != fix["to"]:
        return False, "wrong target %r" % delivery["to"]
    want = fix["expected"].rstrip("\n")
    if path_file is None:
        return (delivery["message"].rstrip("\n") == want), "message differs"
    if path_file not in delivery["message"]:
        return False, "message does not name the file"
    try:
        with open(path_file) as fh:
            body = fh.read()
    except OSError:
        return False, "file unreadable"
    return (body.rstrip("\n") == want), "file bytes differ"


def cmd_check(a):
    fix = load_fixture(a.fixtures, a.id)
    try:
        with open(a.delivery) as fh:
            delivery = json.load(fh)
    except (OSError, ValueError):
        delivery = None
    ok, why = verdict(fix, delivery, a.path_file)
    print("PASS %s" % a.id if ok else "FAIL %s (%s)" % (a.id, why))
    return 0 if ok else 1


def usage_row(stream):
    result = None
    with open(stream, errors="replace") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if rec.get("type") == "result":
                result = rec
    if result is None:
        return {"error": True, "reason": "no result event"}
    u = result.get("usage") or {}
    inp, cr, cc, out = (int(u.get(k, 0) or 0) for k in
                        ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"))
    return {"error": bool(result.get("is_error")), "input": inp, "cache_read": cr, "cache_creation": cc, "output": out,
            "cost_eq_cold": round(inp * W_IN + cr * W_CR + cc * W_CC + out * W_OUT, 1),
            "cost_eq_warm": round(inp * W_IN + (cr + cc) * W_CR + out * W_OUT, 1),
            "cost_usd": result.get("total_cost_usd"), "reply": result.get("result") or ""}


def cmd_price(a):
    print(json.dumps(usage_row(a.stream)))
    return 0


def pct(x, base):
    return "n/a" if not base or x is None else "%d%%" % round(100.0 * x / base)


def cmd_report(a):
    with open(a.fixtures) as fh:
        fixtures = json.load(fh)["fixtures"]
    fx = {f["id"]: f for f in fixtures}
    arms = {}
    for p in sorted(glob.glob(os.path.join(a.runs, "*", "*.result.json"))):
        arm = os.path.basename(os.path.dirname(p))
        with open(p) as fh:
            r = json.load(fh)
        if r["id"] in fx:
            arms.setdefault(arm, []).append(r)
    if not arms:
        sys.exit("relay_cost: no results under %s" % a.runs)
    order = [x for x in ("sonnet", "haiku", "script", "path") if x in arms] + sorted(k for k in arms if k not in ("sonnet", "haiku", "script", "path"))
    stat = {}
    for arm in order:
        rows = arms[arm]
        n = len(rows)
        passed = sum(1 for r in rows if r["pass"])
        # a row with no cost (a stream without a result event) is unknown, not free: average the priced rows only
        priced = [r for r in rows if r.get("cost_eq_cold") is not None and r.get("cost_eq_warm") is not None and r.get("cost_usd") is not None]
        k = len(priced)
        stat[arm] = {"n": n, "pass": 100.0 * passed / n, "unpriced": n - k,
                     "cold": sum(r["cost_eq_cold"] for r in priced) / k if k else None,
                     "warm": sum(r["cost_eq_warm"] for r in priced) / k if k else None,
                     "usd": sum(r["cost_usd"] for r in priced) / k if k else None}
    base = stat.get("sonnet", {})
    print("| option | messages | pass rate | cost-eq cold/msg | cost-eq warm/msg | USD/msg | warm vs sonnet | USD vs sonnet |")
    print("|---|---|---|---|---|---|---|---|")
    for arm in order:
        s = stat[arm]
        mark = "*" if s["unpriced"] and s["cold"] is not None else ""
        cold, warm, usd = (("%.0f" % s["cold"] + mark, "%.0f" % s["warm"] + mark, "%.5f" % s["usd"] + mark)
                           if s["cold"] is not None else ("n/a", "n/a", "n/a"))
        print("| %s | %d | %d%% | %s | %s | %s | %s | %s |" % (
            arm, s["n"], round(s["pass"]), cold, warm, usd,
            pct(s["warm"], base.get("warm")), pct(s["usd"], base.get("usd"))))
    for arm in order:
        s = stat[arm]
        if s["unpriced"]:
            print()
            print("* %d of %d %s rows had no cost (no result event); %s" % (
                s["unpriced"], s["n"], arm,
                "the figures average the %d priced rows." % (s["n"] - s["unpriced"]) if s["cold"] is not None else "no figure."))
    print()
    print("| kind | " + " | ".join("%s pass" % x for x in order) + " |")
    print("|---|" + "---|" * len(order))
    for k in KINDS:
        cells = []
        for arm in order:
            rows = [r for r in arms[arm] if fx[r["id"]]["kind"] == k]
            cells.append("%d%%" % round(100.0 * sum(1 for r in rows if r["pass"]) / len(rows)) if rows else "-")
        print("| %s | %s |" % (k, " | ".join(cells)))
    return 0


def cmd_turn_price(a):
    files = sorted(glob.glob(os.path.join(os.path.expanduser(a.dir) + "--claude-worktrees-*", "*.jsonl")),
                   key=os.path.getmtime, reverse=True)[: a.sessions]
    reads = []
    for f in files:
        seen = set()
        with open(f, errors="replace") as fh:
            for line in fh:
                if '"cache_read_input_tokens"' not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                m = rec.get("message")
                if not isinstance(m, dict) or m.get("role") != "assistant" or m.get("id") in seen:
                    continue
                seen.add(m.get("id"))
                cr = (m.get("usage") or {}).get("cache_read_input_tokens")
                if cr:
                    reads.append(cr)
    if not reads:
        sys.exit("relay_cost: no worker turns found")
    reads.sort()
    med = reads[len(reads) // 2]
    print(json.dumps({"turns": len(reads), "sessions": len(files), "median_cache_read": med,
                      "median_turn_cost_eq": round(med * W_CR, 1)}))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    e = sp.add_parser("gen")
    e.add_argument("--out", required=True)
    c = sp.add_parser("check")
    c.add_argument("--fixtures", required=True)
    c.add_argument("--id", required=True)
    c.add_argument("--delivery", required=True)
    c.add_argument("--path-file")
    p = sp.add_parser("price")
    p.add_argument("stream")
    r = sp.add_parser("report")
    r.add_argument("--runs", required=True)
    r.add_argument("--fixtures", required=True)
    t = sp.add_parser("turn-price")
    t.add_argument("--dir", default=DEFAULT_DIR)
    t.add_argument("--sessions", type=int, default=40)
    a = ap.parse_args()
    return {"gen": lambda: cmd_gen(a), "check": lambda: cmd_check(a), "price": lambda: cmd_price(a),
            "report": lambda: cmd_report(a), "turn-price": lambda: cmd_turn_price(a)}[a.cmd]()


if __name__ == "__main__":
    sys.exit(main())
