#!/usr/bin/env python3
"""scripts/eval/retrieval-eval/answer-ab.py - tokens to a correct answer, end to end.

retrieval-eval.py scores what a retrieval arm returns. This asks what it costs a
small answerer to reach a correct answer with it: the question goes to a haiku
session with the arm's output pasted in, and the session's total tokens are
counted.

  run  --questions Q --out DIR [--repo R] [--arms A,B] [--pool 20] [--n 15]
       [--k 5] [--model claude-haiku-5-5] [--max-usd 3] [--timeout 180]
       [--retrieval-timeout 60] [--collection himmel]

Steps:
  1. screen   pool questions (an even sample of the file) go to the answerer with no
              retrieval; the ones it gets wrong, at most n, are the eval set
              (screened.txt). A question it answers closed-book proves nothing.
  2. arms     each screened question is answered once per arm:
                none       no retrieval (re-asked, so the baseline is measured, not assumed)
                grep       retrieval-eval's grep arm
                pathident  the path arm and the ident-grep arm, both outputs
                graphify   graphify query
                fused      grep + qmd-hybrid + graphify outputs, as the combined arm reads them
  3. score    the answer is correct when one of its (at most three) named paths is a
              gold file of the question, the rule hit@k uses. A name list, not prose,
              keeps the grader a set test.

Tokens are the answerer session's usage: input + cache creation + cache read + output.
tokens_per_correct is the arm's total over its correct answers: an arm that reads a lot
and is right rarely pays for it here, which a per-call size budget does not show.

Billing: bank-preflight before every call (a refusal stops the run), --output-format
json, an explicit --permission-mode, no tools, a per-run cap and a --max-usd cap. The
answerer runs in an empty scratch directory so no project file steers it.

Output in DIR: results.jsonl (a row per question x arm, plus the screen rows),
screened.txt, table.tsv (also printed), STOPPED when a cap or a refusal cut the run.
Exit: 0 complete, 1 stopped or a call errored, 64 usage error.
Seams: CLAUDE_BIN, BANK_PREFLIGHT, and retrieval-eval's RETRIEVAL_EVAL_QMD_CMD and
RETRIEVAL_EVAL_GRAPH_CMD.
Stdlib only.
"""
import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
ARMS = ["none", "grep", "pathident", "graphify", "fused"]
PER_RUN_USD = 1.0
MAX_NAMED = 3
SYSTEM = ("You answer questions about a software repository. Reply briefly. "
          "Finish with exactly one line: ANSWER: [\"path1\", ...] -- a JSON array of at most 3 "
          "repo-relative file paths that answer the question, no other text on that line.")


class Usage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def load_eval():
    spec = importlib.util.spec_from_file_location("retrieval_eval", os.path.join(HERE, "retrieval-eval.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules["retrieval_eval"] = mod
    spec.loader.exec_module(mod)
    return mod


def build_prompt(q, arm, text):
    p = "Question about the himmel repository: %s\n\nName the file(s) that answer it." % q
    if arm == "none":
        return p + " No retrieval is available: answer from what you know."
    return p + "\n\nRETRIEVED CONTEXT (%s):\n%s\n" % (arm, text)


def parse_answer(result):
    """The paths of the last ANSWER: line, at most MAX_NAMED; [] when there is none."""
    found = re.findall(r"ANSWER:\s*(\[.*\])\s*$", result or "", re.M)
    if not found:
        return []
    try:
        names = json.loads(found[-1])
    except ValueError:
        return []
    return [re.sub(r"^\./", "", n) for n in names if isinstance(n, str)][:MAX_NAMED]


def session_tokens(u):
    return sum(int(u.get(k) or 0) for k in
               ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))


def weighted(u):
    return (u.get("input_tokens", 0) + 1.25 * u.get("cache_creation_input_tokens", 0)
            + 0.1 * u.get("cache_read_input_tokens", 0) + 5 * u.get("output_tokens", 0))


class Sweep:
    def __init__(self, a, ev):
        self.a, self.ev = a, ev
        self.spent = 0.0
        self.stopped = ""
        self.errors = 0
        self.rows = []
        self.claude = os.environ.get("CLAUDE_BIN", "claude")
        self.preflight = os.environ.get("BANK_PREFLIGHT", os.path.join(REPO, "scripts", "lib", "bank-preflight.sh"))
        self.scratch = tempfile.mkdtemp(prefix="answer-ab-")

    def bank_ok(self):
        r = subprocess.run(["bash", self.preflight], capture_output=True, text=True)
        return r.returncode == 0 and "PROCEED" in r.stdout.splitlines()

    def ask(self, q, arm, text):
        """One answerer call -> a result row, or None when the sweep must stop."""
        cap = min(PER_RUN_USD, self.a.max_usd - self.spent)
        if cap <= 0:
            self.stopped = "max-usd %s reached before %s/%s" % (self.a.max_usd, q["id"], arm)
            return None
        if not self.bank_ok():
            self.stopped = "bank-preflight refused before %s/%s" % (q["id"], arm)
            return None
        argv = [self.claude, "-p", "--model", self.a.model, "--permission-mode", "dontAsk",
                "--output-format", "json", "--max-budget-usd", "%.4f" % cap, "--tools", "",
                "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                "--system-prompt", SYSTEM]
        row = dict(id=q["id"], arm=arm, correct=False, named=[], tokens=0, weighted=0, cost_usd=0.0,
                   retr_tokens=self.ev.tok(text), error=None)
        t0 = time.time()
        try:
            # eval answerer: bank-preflighted above, explicit permission mode, no tools, empty cwd
            # launch-profile-ok: the A/B pins its own --tools and --system-prompt; a leg profile would change the measured condition
            r = subprocess.run(argv, input=build_prompt(q["q"], arm, text), capture_output=True, text=True,
                               cwd=self.scratch, timeout=self.a.timeout)
            d = json.loads(r.stdout)
            if not isinstance(d, dict) or r.returncode != 0 or d.get("is_error"):
                raise ValueError("claude rc=%s is_error=%s" % (r.returncode, isinstance(d, dict) and d.get("is_error")))
            u = d.get("usage") or {}
            row.update(named=parse_answer(d.get("result")), tokens=session_tokens(u), weighted=weighted(u),
                       cost_usd=float(d.get("total_cost_usd") or 0.0))
            row["correct"] = self.ev.is_hit(row["named"], q["gold"])
        except (ValueError, OSError, subprocess.TimeoutExpired, TypeError) as e:
            row["error"] = str(e)[:120]
            row["cost_usd"] = cap  # a billed call we cannot read: assume the full cap
            self.errors += 1
        row["ms"] = int((time.time() - t0) * 1000)
        self.spent += row["cost_usd"]
        self.rows.append(row)
        return row


def retrieve(ev, a, q, repo, need):
    """arm name -> output text, for the arms in need (each retrieval run once per question)."""
    k, to = a.k, a.retrieval_timeout
    out = {}
    if {"grep", "fused"} & need:
        out["grep"] = ev.arm_grep(q["q"], repo, to, k)[1]
    if "pathident" in need:
        out["pathident"] = "%s\n%s" % (ev.arm_path(q["q"], repo, to, k)[1], ev.arm_ident_grep(q["q"], repo, to, k)[1])
    if {"graphify", "fused"} & need:
        out["graphify"] = ev.arm_graphify(q["q"], repo, to, k)[1]
    if "fused" in need:
        out["fused"] = "\n".join([out["grep"], ev.arm_qmd(q["q"], True, to, k, a.collection)[1], out["graphify"]])
    return out


def sample(qs, pool):
    if len(qs) <= pool:
        return list(qs)
    return [qs[i * len(qs) // pool] for i in range(pool)]


def table(rows, arms):
    cols = ["arm", "n", "correct", "tokens_total", "tokens_per_correct", "weighted_total", "cost_usd",
            "retr_tokens_mean", "errors"]
    lines = ["\t".join(cols)]
    for arm in arms:
        rs = [r for r in rows if r["arm"] == arm]
        if not rs:
            continue
        ok = sum(r["correct"] for r in rs)
        tot = sum(r["tokens"] for r in rs)
        lines.append("\t".join([arm, str(len(rs)), str(ok), str(tot), "%.1f" % (tot / ok) if ok else "-",
                                "%d" % sum(r["weighted"] for r in rs), "%.4f" % sum(r["cost_usd"] for r in rs),
                                "%d" % (sum(r["retr_tokens"] for r in rs) / len(rs)),
                                str(sum(1 for r in rs if r["error"]))]))
    return lines


def cmd_run(a):
    arms = [x for x in a.arms.split(",") if x]
    for x in arms:
        if x not in ARMS:
            raise Usage("unknown arm '%s' (known: %s)" % (x, ",".join(ARMS)))
    ev = load_eval()
    qs = [q for q in ev.load_questions(a.questions) if q.get("gold")]
    if not qs:
        raise Usage("no question with a gold file in %s" % a.questions)
    repo = os.path.abspath(a.repo)
    os.makedirs(a.out, exist_ok=True)
    sw = Sweep(a, ev)

    kept = []
    for q in sample(qs, a.pool):
        row = sw.ask(q, "none", "")
        if row is None:
            break
        row["arm"] = "screen"
        if not row["correct"] and not row["error"] and len(kept) < a.n:
            kept.append(q)
    with open(os.path.join(a.out, "screened.txt"), "w") as fh:
        fh.write("".join(q["id"] + "\n" for q in kept))

    need = set(arms) - {"none"}
    for i, q in enumerate(kept):
        if sw.stopped:
            break
        ctx = retrieve(ev, a, q, repo, need) if need else {}
        order = arms[i % len(arms):] + arms[:i % len(arms)]  # rotate: load drift is not an arm effect
        for arm in order:
            if sw.ask(q, arm, ctx.get(arm, "")) is None:
                break
        print("%s %s" % (q["id"], " ".join("%s=%d" % (r["arm"], r["correct"]) for r in sw.rows if r["id"] == q["id"] and r["arm"] != "screen")),
              file=sys.stderr)

    with open(os.path.join(a.out, "results.jsonl"), "w") as fh:
        for r in sw.rows:
            fh.write(json.dumps(r) + "\n")
    lines = table(sw.rows, arms)
    with open(os.path.join(a.out, "table.tsv"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    print("screened %d of %d sampled (the answerer failed them closed-book); spent_usd=%.4f" %
          (len(kept), min(a.pool, len(qs)), sw.spent))
    if sw.stopped:
        with open(os.path.join(a.out, "STOPPED"), "w") as fh:
            fh.write("STOPPED: %s\n" % sw.stopped)
        print("STOPPED: %s" % sw.stopped, file=sys.stderr)
    return 1 if sw.stopped or sw.errors else 0


def main(argv=None):
    p = Parser(prog="answer-ab.py")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("run")
    r.add_argument("--questions", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--repo", default=".")
    r.add_argument("--arms", default=",".join(ARMS))
    r.add_argument("--pool", type=int, default=20)
    r.add_argument("--n", type=int, default=15)
    r.add_argument("--k", type=int, default=5)
    r.add_argument("--model", default="claude-haiku-5-5")
    r.add_argument("--max-usd", type=float, default=3.0)
    r.add_argument("--timeout", type=int, default=180)
    r.add_argument("--retrieval-timeout", type=int, default=60)
    r.add_argument("--collection", default="himmel")
    r.error = p.error
    try:
        a = p.parse_args(argv)
        if a.cmd == "run":
            return cmd_run(a)
        raise Usage("name a subcommand: run")
    except Usage as e:
        print("answer-ab: %s" % e, file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
