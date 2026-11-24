#!/usr/bin/env python3
"""hop_rule.py - when a context hop pays, as one function.

At a stable point with context C at or above FLOOR, hop when

    r x (C - base) x n  >=  M x (w x base + relaunch + H x r x C)

r is cache_read_weight(model) and w the one-hour write weight, both read from their owners
(burn_weights.py). n is the predictor: the tool calls the session has made so far. A model that
burn_weights.is_known rejects has no weight, so the function raises; no default weight is used.

  hop_rule.py --context <n> --calls <n> --model <id> [--base <n>] [--relaunch <n>]

Prints the r it used and the answer. Exit 0 hop, 1 no hop, 3 `unknown model` (no answer).
No runtime path reads this file yet.

B and K are PROVISIONAL: they come from the one hop S1b measured and serve S2's pre-check only. B is the
fresh session's fixed opening, 29730 tokens, plus 0 re-read tokens. K is the chief's 5 calls at about
100000 context, read at 0.05: 25000.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import burn_weights  # noqa: E402

M = 2
H = 3
FLOOR = 200000
B = 29730
K = 25000


def should_hop(context_tokens, calls_so_far, model, base=B, relaunch=K):
    if not burn_weights.is_known(model):
        raise ValueError("unknown model: %s" % model)
    if context_tokens < FLOOR:
        return False
    r = burn_weights.cache_read_weight(model)
    w = burn_weights.cache_create_1h_weight()
    return r * (context_tokens - base) * calls_so_far >= M * (w * base + relaunch + H * r * context_tokens)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--context", type=int, required=True)
    ap.add_argument("--calls", type=int, required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--base", type=int, default=B)
    ap.add_argument("--relaunch", type=int, default=K)
    a = ap.parse_args(argv)
    if not burn_weights.is_known(a.model):
        sys.stderr.write("hop_rule: unknown model: %s\n" % a.model)
        return 3
    hop = should_hop(a.context, a.calls, a.model, a.base, a.relaunch)
    print("r=%s %s" % (burn_weights.cache_read_weight(a.model), "hop" if hop else "no-hop"))
    return 0 if hop else 1


if __name__ == "__main__":
    sys.exit(main())
