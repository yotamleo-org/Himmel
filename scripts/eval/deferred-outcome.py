#!/usr/bin/env python3
"""scripts/eval/deferred-outcome.py - what became of the review findings that were deferred (HIMMEL-7517).

A CR-ledger finding whose effective verdict is `deferred` names a follow-up ticket (`deferred_to`). This
joins each one to that ticket's current state in the local Jira mirror and splits the deferrals:

  fixed_later  the ticket is done with resolution Done
  still_open   the ticket is not done
  disproved    the ticket was closed without a fix (Won't Do)
  unknown      the ticket is not in the mirror
  no_ticket    the deferral names no ticket

overall and per critic (the panel slug plus the model that answered, as cr_ledger_eval.py labels it).
The shares are over the rulable outcomes, fixed_later + still_open + disproved.

  deferred-outcome.py [--cr-ledger P] [--mirror DIR] [--until TS] [--record] [--ledger P]

Without --record the eval-runs row is printed, not appended. CR ledger: $CR_LEDGER, else the git common
dir's cr-critic-scores.jsonl; mirror: ~/.himmel/state/jira-mirror/HIMMEL; ledger: $HIMMEL_EVAL_RUNS_LEDGER,
else ~/.himmel/eval-runs.jsonl. Exit 0 done; 2 refused input. Stdlib only; no network, no model call.
"""
import argparse
import collections
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "lib"))
sys.path.insert(0, os.path.join(HERE, "cr-ledger"))
sys.path.insert(0, os.path.join(HERE, "judge-accuracy"))
import cr_ledger_eval  # noqa: E402
import eval_runs  # noqa: E402
import judge_accuracy  # noqa: E402

EVAL_ID = "deferred-outcome"
SOURCE = "scripts/eval/deferred-outcome.py"
OUTCOMES = ("fixed_later", "still_open", "disproved", "unknown", "no_ticket")
TICKET = re.compile(r"\b([A-Z][A-Z0-9]+-\d+)\b")


def deferrals(rows):
    """(critic, deferred_to) per finding whose effective verdict is deferred."""
    amends = {}
    for r in rows:
        if r.get("kind") == "amend" and isinstance(r.get("set"), dict):
            k = cr_ledger_eval.key(r.get("target_head"), r.get("finding_id"), r.get("artifact"), r.get("perspective"))
            amends.setdefault(k, {}).update(r["set"])
    raw = [r for r in rows if r.get("kind") == "finding"]
    out = []
    # fold() keeps ledger order, one entry per finding row, so it pairs with raw.
    for f, r in zip(cr_ledger_eval.fold(rows), raw):
        if f["bucket"] != "deferred":
            continue
        k = cr_ledger_eval.key(r.get("head"), r.get("finding_id"), r.get("artifact"), r.get("perspective"))
        out.append((f["critic"], amends.get(k, {}).get("deferred_to") or r.get("deferred_to") or ""))
    return out


def ticket_state(mirror, key):
    path = os.path.join(mirror, key + ".md")
    if not os.path.isfile(path):
        return None
    text = open(path, encoding="utf-8", errors="replace").read()
    return {k: (judge_accuracy.header(text, k) or "").strip('"').lower()
            for k in ("status", "statusCategory", "resolution")}


def outcome(mirror, deferred_to, cache):
    m = TICKET.search(str(deferred_to))
    if not m:
        return "no_ticket"
    key = m.group(1)
    if key not in cache:
        cache[key] = ticket_state(mirror, key)
    st = cache[key]
    if st is None:
        return "unknown"
    if st["statusCategory"] != "done":
        return "still_open"
    if st["resolution"] == "won't do" or st["status"] in ("wont do", "wont fix"):
        return "disproved"
    return "fixed_later"


def put(m, prefix, counts):
    for o in OUTCOMES:
        m[prefix + o] = counts[o]
    rulable = counts["fixed_later"] + counts["still_open"] + counts["disproved"]
    for o in ("fixed_later", "still_open", "disproved"):
        m[prefix + o + "_share"] = round(counts[o] / rulable, 4) if rulable else None


def build(rows, mirror, until):
    cache = {}
    total, by = collections.Counter(), collections.defaultdict(collections.Counter)
    for critic, dt in deferrals(rows):
        o = outcome(mirror, dt, cache)
        total[o] += 1
        by[critic][o] += 1
    m = {"deferred": sum(total.values())}
    put(m, "", total)
    for critic in sorted(by):
        put(m, critic + ".", by[critic])
    return eval_runs.make_row(EVAL_ID, SOURCE, {"deferred_outcome_v": 1, "until": until}, m, n=m["deferred"],
                              meta={"mirror": mirror, "tickets": len(cache)})


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--cr-ledger")
    ap.add_argument("--mirror", default=judge_accuracy.MIRROR)
    ap.add_argument("--until")
    ap.add_argument("--record", action="store_true")
    ap.add_argument("--ledger")
    a = ap.parse_args(argv)
    if not os.path.isdir(a.mirror):
        print("deferred-outcome: refused: no Jira mirror: %s" % a.mirror, file=sys.stderr)
        return 2
    rows, _ = cr_ledger_eval.load(a.cr_ledger or cr_ledger_eval.default_ledger(), a.until)
    row = build(rows, a.mirror, a.until)
    if a.record:
        eval_runs.append_safe(row, a.ledger, who=EVAL_ID)
    else:
        print(json.dumps(row, indent=1, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
