#!/usr/bin/env python3
"""scripts/eval/retrieval-eval/answer-ab.py - tokens per file hit, end to end.

retrieval-eval.py scores what a retrieval arm returns. This asks what it costs a
small answerer to name a gold file with it: the question goes to a haiku
session with the arm's output pasted in, and the session's total tokens are
counted. The realistic arms (below) ask the same of a real worker session.

  run  --questions Q --out DIR [--repo R] [--arms A,B] [--pool 20] [--n 15]
       [--k 5] [--model claude-haiku-5-5] [--max-usd 3] [--timeout 180]
       [--retrieval-timeout 60] [--collection himmel] [--no-ledger]
       [--prime] [--warm-session K]   (realistic arms only)
  route-server --kind K --repo R [--trace FILE]   (internal: the one-tool MCP server a realistic arm's session calls)

Steps:
  1. screen   pool questions (an even sample of the file) go to the answerer with no
              retrieval; the ones it gets wrong, at most n, are the eval set
              (screened.txt). A question it answers closed-book proves nothing.
              Only the one-turn arms below use it.
  2. arms     each screened question is answered once per arm:
                none       no retrieval (re-asked, so the baseline is measured, not assumed)
                grep       retrieval-eval's grep arm
                grep-rtk   retrieval-eval's grep-rtk arm: the same files as a session reads
                           them through rtk; skipped, with the reason printed, when rtk is
                           not on PATH
                pathident  the path arm and the ident-grep arm, both outputs
                graphify   graphify query
                fused      grep + qmd-hybrid + graphify outputs, as the combined arm reads them
              The default --arms are these six. The four realistic arms are opt-in (--arms):
                vanilla       a worker session: the himmel worker preface, the repo CLAUDE.md and
                              hooks (cwd = --repo), tools Read, Grep, Glob only, an empty MCP config
                fused-cached  the same session plus ONE tool, route, that returns grep + qmd
                              hybrid (reranked) + graphify, rank-fused, as a tool RESULT. The session
                              flags (preface, CLAUDE.md, hooks, model, permission mode) are vanilla's,
                              but the extra tool changes the tool block at the front of the cache
                              prefix, so each arm keeps its OWN prefix cache: written on its first
                              call, read by its later ones. The route output is unique per question,
                              so it is written to the cache once per question and read by that
                              session's later turns
                bm25-rerank   the same session, route = qmd keyword (BM25) search, reranked
                vec-rerank    the same session, route = qmd vector search, reranked
              They take the question sample (--pool, --n; --pool 75 --n 75 for the whole file)
              with no closed-book screen, and are priced from the session usage.
              A route call returns the top 5 files with at most 400 characters of excerpt each.
              --prime asks one throwaway question per arm first (its cold prefix write); the
              headline cost leaves it out and <arm>.prime_cost_usd, .cost_usd_with_prime and
              .cost_per_file_hit_with_prime report it. --warm-session K asks K questions in ONE
              persisted session per arm (claude --session-id, then --resume), question j of every
              arm before question j+1; <arm>.pos1.* and <arm>.pos2k.* (n, cost_mean,
              cache_read_mean, cache_creation_mean, cached_share) and warm.tsv compare question 1
              with questions 2..k. The run deletes the session transcripts it created.
  3. score    FILE-HIT: one of the at most three named paths is a gold file of the
              question, the rule hit@k uses. It does not grade the answer text.
              Each row keeps result (the reply, at most 4000 characters), route_calls
              and tool_trace (query, files, failure for each route call, in order).
              Built-in Read/Grep/Glob calls are not visible in --output-format json;
              the trace records only the route tool's calls.

Tokens are the answerer session's usage: input + cache creation + cache read + output.
tokens_per_file_hit is the arm's total over its file hits: an arm that reads a lot
and rarely names a gold file pays for it here, which a per-call size budget does not show.
priced_usd prices each call's usage split (input, output, cache read, cache creation) through
scripts/lanes/model-price.mjs; a model with no price row is reported unpriced, never guessed.
The one-turn arms keep their cost_usd column (the reported total_cost_usd); the realistic arms'
cost_usd is the priced figure.

A realistic session cannot Read, Grep or Glob the question bank (it holds the gold files). It runs in a
scratch export of --repo's HEAD (git archive, so no ignored or untracked file) from which the bank is
removed: questions.jsonl, questions-v2.jsonl, a --questions file inside --repo, and any tracked copy of
their bytes. Glob lists gitignored files too, so the export is the barrier; the session also carries
--disallowedTools Read rules for the bank paths as a second layer. The scorer still reads the bank in
this process. The routed arms' retrieval (route server, grep, qmd, graphify) still runs on --repo.

Billing: bank-preflight before every call (a refusal stops the run), --output-format
json, an explicit --permission-mode, no tools (realistic arms: Read, Grep, Glob and the route
tool), a per-run cap and a --max-usd cap. The one-turn answerer runs in an empty scratch
directory so no project file steers it; a realistic session runs in a bank-free export of --repo, as a worker does.

Output in DIR: results.jsonl (a row per question x arm, plus the screen rows),
screened.txt, table.tsv (also printed), STOPPED when a cap or a refusal cut the run.
One eval-runs row (eval = answer-ab) with per-arm metrics (<arm>.file_hit, .cost_usd,
.cost_per_file_hit, .tokens_per_file_hit, the token mix, .cached_share, .ms_median, .turns_mean,
and the <arm>.insample.* / <arm>.heldout.* split) and per-question cases goes to
$HIMMEL_EVAL_RUNS_LEDGER (default ~/.himmel/eval-runs.jsonl); --no-ledger writes none.
Exit: 0 complete, 1 stopped or a call errored, 64 usage error.
Seams: CLAUDE_BIN, BANK_PREFLIGHT, HIMMEL_EVAL_RUNS_LEDGER, and retrieval-eval's
RETRIEVAL_EVAL_QMD_CMD and RETRIEVAL_EVAL_GRAPH_CMD.
Stdlib only (node for the price table).
"""
# billed-opt-in: HIMMEL_BILLED_OK
import argparse
import atexit
import hashlib
import glob
import importlib.util
import json
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "lib"))
from burn_weights import cache_read_weight, result_model  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
OLD_ARMS = ["none", "grep", "grep-rtk", "pathident", "graphify", "fused"]
REAL_ARMS = ["vanilla", "fused-cached", "bm25-rerank", "vec-rerank"]
ARMS = OLD_ARMS + REAL_ARMS
SPLITS = ("insample", "heldout")
PER_RUN_USD = 1.0
MAX_NAMED = 3
ROUTE_FILES = 5      # a route call lists this many files
ROUTE_EXCERPT = 400   # and at most this many characters of excerpt each
PRIME_Q = "which file describes how a handover queue lock is held"
SYSTEM = ("You answer questions about a software repository. Reply briefly. "
          "Finish with exactly one line: ANSWER: [\"path1\", ...] -- a JSON array of at most 3 "
          "repo-relative file paths that answer the question, no other text on that line.")
PREFACE = os.path.join(REPO, "docs", "handover", "worker-preface.md")
SESSION_TOOLS = "Read,Grep,Glob"
ROUTE_TOOL = "mcp__route__route"
ROUTE_DESC = {
    "fused-cached": "Search the repository with grep, qmd (keyword + vector, reranked) and the code graph, "
                    "rank-fused. Returns ranked file paths and the supporting excerpts.",
    "bm25-rerank": "Search the repository's indexed docs with qmd keyword (BM25) search, reranked. "
                   "Returns ranked file paths and excerpts.",
    "vec-rerank": "Search the repository's indexed docs with qmd semantic (vector) search, reranked. "
                  "Returns ranked file paths and excerpts.",
}
ROUTE_ENV = ("PATH", "HOME", "QMD_URL", "RETRIEVAL_EVAL_QMD_CMD", "RETRIEVAL_EVAL_GRAPH_CMD")
PRICE_MJS = os.path.join(REPO, "scripts", "lanes", "model-price.mjs")
PRICE_JS = ("import {loadPrices, priceCall} from %s;"
            "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{"
            "const r=priceCall(JSON.parse(s),loadPrices());"
            "console.log(JSON.stringify({priced:r.priced,usd:r.usd}))});" % json.dumps("file://" + PRICE_MJS))


BANK_FILES = ("questions.jsonl", "questions-v2.jsonl")
BANK_DIR = os.path.join("scripts", "eval", "retrieval-eval")


def bank_rels(repo, questions):
    """Repo-relative paths of the question bank: the two committed banks, plus the --questions file when
    it lies inside the repo. `repo` is a realpath."""
    rels = [os.path.join(BANK_DIR, f) for f in BANK_FILES]
    q = os.path.realpath(questions)
    if q.startswith(repo.rstrip(os.sep) + os.sep) and os.path.relpath(q, repo) not in rels:
        rels.append(os.path.relpath(q, repo))
    return rels


def bank_deny(repo, questions):
    """Read deny rules, the second layer behind the scratch export: the bank paths of this repo, and any
    copy of the committed banks anywhere on the filesystem (sibling worktrees). Claude Code applies Read
    rules to Grep and Glob as well (best effort); `//` anchors the rule at the filesystem root."""
    rules = ["Read(/%s)" % os.path.join(repo, r) for r in bank_rels(repo, questions)]
    return rules + ["Read(//**/%s/questions*.jsonl)" % BANK_DIR.replace(os.sep, "/")]


def file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def export_without_bank(repo, questions, dest):
    """A scratch export of the repo's HEAD (git archive, so no ignored or untracked file comes along) with
    the question bank removed: by path, and by content wherever else a copy of it is tracked. Glob in a
    session lists gitignored files too, so denying the bank's paths is not enough; a tree that holds no
    bank bytes is. Raises Usage when the archive cannot be taken."""
    p = subprocess.Popen(["git", "-C", repo, "archive", "--format=tar", "HEAD"], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL)
    try:
        with tarfile.open(fileobj=p.stdout, mode="r|") as tf:
            try:
                tf.extractall(dest, filter="data")
            except TypeError:  # python before the extraction filters
                tf.extractall(dest)
    except (tarfile.TarError, OSError) as e:
        p.kill()
        raise Usage("cannot export %s for a session: %s" % (repo, e))
    if p.wait() != 0:
        raise Usage("cannot export %s for a session: git archive HEAD failed" % repo)
    rels = bank_rels(repo, questions)
    sums, sizes = set(), set()
    for root in (repo, dest):
        for r in rels:
            f = os.path.join(root, r)
            if os.path.isfile(f) and not os.path.islink(f):
                sums.add(file_digest(f))
                sizes.add(os.path.getsize(f))
    for r in rels:
        f = os.path.join(dest, r)
        if os.path.lexists(f):
            os.remove(f)
    for d, _, names in os.walk(dest):
        for n in names:
            f = os.path.join(d, n)
            if not os.path.islink(f) and os.path.getsize(f) in sizes and file_digest(f) in sums:
                os.remove(f)


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


def build_session_prompt(q):
    """The same prompt for every realistic arm: the route output is a tool result, never in here."""
    return ("Question about the himmel repository: %s\n\nName the file(s) that answer it. "
            "Finish with exactly one line: ANSWER: [\"path1\", ...] -- a JSON array of at most %d "
            "repo-relative file paths that answer the question, no other text on that line." % (q, MAX_NAMED))


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


def usage_split(u):
    """(input, output, cache_read, cache_creation) of a usage object."""
    return tuple(int(u.get(k) or 0) for k in
                 ("input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))


def weighted(u, model=None):
    return (u.get("input_tokens", 0) + 1.25 * u.get("cache_creation_input_tokens", 0)
            + cache_read_weight(model) * u.get("cache_read_input_tokens", 0) + 5 * u.get("output_tokens", 0))


def price_usage(d, model):
    """(usd, True) for a print-mode JSON result priced from its usage split by model-price.mjs;
    (None, False) when a model has no price row or the price script cannot run. Several models
    in modelUsage (a hook's helper call) are priced each at its own row."""
    mu = d.get("modelUsage")
    if isinstance(mu, dict) and len(mu) > 1:
        # modelUsage has no 5m / 1h write split: share the aggregate's split out by each model's write size
        split = (d.get("usage") or {}).get("cache_creation") or {}
        w5, w1 = split.get("ephemeral_5m_input_tokens") or 0, split.get("ephemeral_1h_input_tokens") or 0
        share1h = w1 / (w5 + w1) if w5 + w1 > 0 else None
        calls = []
        for m, x in mu.items():
            if not isinstance(x, dict):
                continue
            u = {"input_tokens": x.get("inputTokens", 0), "output_tokens": x.get("outputTokens", 0),
                 "cache_read_input_tokens": x.get("cacheReadInputTokens", 0),
                 "cache_creation_input_tokens": x.get("cacheCreationInputTokens", 0)}
            if share1h is not None:
                w = u["cache_creation_input_tokens"]
                u["cache_creation"] = {"ephemeral_5m_input_tokens": w * (1 - share1h), "ephemeral_1h_input_tokens": w * share1h}
            calls.append({"model": m, "usage": u})
    else:
        calls = [{"model": result_model(d) or model, "usage": d.get("usage") or {}}]
    total = 0.0
    for c in calls:
        try:
            r = subprocess.run(["node", "--input-type=module", "-e", PRICE_JS], input=json.dumps(c),
                               capture_output=True, text=True, timeout=30)
            p = json.loads(r.stdout)
        except (OSError, ValueError, subprocess.TimeoutExpired):
            return None, False
        if not p.get("priced") or not isinstance(p.get("usd"), (int, float)):
            return None, False
        total += p["usd"]
    return total, True


def read_complete_calls(path):
    calls = []
    with open(path) as fh:
        for line in fh:
            try:
                calls.append(json.loads(line))
            except ValueError:
                continue
    return calls


class Sweep:
    def __init__(self, a, ev):
        self.a, self.ev = a, ev
        self.spent = 0.0
        self.stopped = ""
        self.errors = 0
        self.rows = []
        self.claude = os.environ.get("CLAUDE_BIN", "claude")
        self.preflight = os.environ.get("BANK_PREFLIGHT", os.path.join(REPO, "scripts", "lib", "usage-preflight.sh"))
        self.scratch = tempfile.mkdtemp(prefix="answer-ab-")
        self.repo = os.path.realpath(a.repo)
        self.deny = bank_deny(self.repo, a.questions)
        self.export = None
        self.mcp = {}
        self.traces = {}
        self.sink = None

    def session_cwd(self):
        """The directory a realistic session runs in: a scratch export of the repo without the question bank,
        built on first use and removed when the process exits."""
        if self.export is None:
            self.export = os.path.join(self.scratch, "export")
            os.mkdir(self.export)
            atexit.register(shutil.rmtree, self.export, True)
            export_without_bank(self.repo, self.a.questions, self.export)
        return self.export

    def bank_ok(self):
        r = subprocess.run(["bash", self.preflight], capture_output=True, text=True)
        return r.returncode == 0 and "PROCEED" in r.stdout.splitlines()

    def mcp_config(self, arm):
        """The --mcp-config file of a realistic arm: empty for vanilla, else the one route server."""
        if arm not in self.mcp:
            servers = {}
            if arm != "vanilla":
                env = {k: os.environ[k] for k in ROUTE_ENV if k in os.environ}
                self.traces[arm] = os.path.join(self.scratch, "trace-%s.jsonl" % arm)
                servers["route"] = {"command": sys.executable, "env": env,
                                    "args": [os.path.abspath(__file__), "route-server", "--kind", arm, "--repo", self.repo,
                                             "--k", str(self.a.k), "--collection", self.a.collection,
                                             "--retrieval-timeout", str(self.a.retrieval_timeout),
                                             "--trace", self.traces[arm]]}
            path = os.path.join(self.scratch, "mcp-%s.json" % arm)
            with open(path, "w") as fh:
                json.dump({"mcpServers": servers}, fh)
            self.mcp[arm] = path
        return self.mcp[arm]

    def session_argv(self, arm, cap, sess=None):
        """A realistic session: everything but --mcp-config and --allowedTools is the same for every arm.
        A warm session (`sess`) persists: its first call opens the id, the later ones resume it."""
        allowed = SESSION_TOOLS if arm == "vanilla" else "%s,%s" % (SESSION_TOOLS, ROUTE_TOOL)
        keep = ["--no-session-persistence"] if sess is None else ["--resume" if sess["n"] else "--session-id", sess["id"]]
        return [self.claude, "-p", "--model", self.a.model, "--permission-mode", "dontAsk",
                "--output-format", "json", "--max-budget-usd", "%.4f" % cap, "--tools", SESSION_TOOLS,
                "--allowedTools", allowed, "--disallowedTools"] + self.deny + ["--strict-mcp-config", "--mcp-config", self.mcp_config(arm)] + keep + [
                "--append-system-prompt-file", PREFACE]

    def ask(self, q, arm, text, tag=None, sess=None, prime=False):
        """One answerer call -> a result row (labelled `tag` when given), or None when the sweep must stop.
        `sess` is a warm session {id, n}: n counts its good calls and the row's pos is n + 1, so a question
        that had to open a fresh session after a failed call counts as question 1 of it, not a warm one."""
        cap = min(PER_RUN_USD, self.a.max_usd - self.spent)
        if cap <= 0:
            self.stopped = "max-usd %s reached before %s/%s" % (self.a.max_usd, q["id"], arm)
            return None
        if not self.bank_ok():
            self.stopped = "bank-preflight refused before %s/%s" % (q["id"], arm)
            return None
        real = arm in REAL_ARMS
        if real:
            argv, prompt, cwd = self.session_argv(arm, cap, sess), build_session_prompt(q["q"]), self.session_cwd()
        else:
            argv = [self.claude, "-p", "--model", self.a.model, "--permission-mode", "dontAsk",
                    "--output-format", "json", "--max-budget-usd", "%.4f" % cap, "--tools", "",
                    "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
                    "--system-prompt", SYSTEM]
            prompt, cwd = build_prompt(q["q"], arm, text), self.scratch
        trace = self.traces.get(arm)
        if trace:
            open(trace, "w").close()
        row = dict(id=q["id"], arm=tag or arm, split=q.get("split", "insample"), file_hit=False, named=[], tokens=0, weighted=0,
                   cost_usd=0.0, priced_usd=0.0, priced=True, input=0, output=0, cache_read=0, cache_creation=0,
                   turns=0, retr_tokens=self.ev.tok(text), error=None, pos=sess["n"] + 1 if sess is not None else 1, prime=prime,
                   result="", route_calls=0, tool_trace=[])
        t0 = time.time()
        try:
            # eval answerer: bank-preflighted above, explicit permission mode (never bypassPermissions)
            # launch-profile-ok: the A/B pins its own --tools and system prompt; a worker profile would change the measured condition
            r = subprocess.run(argv, input=prompt, capture_output=True, text=True,
                               cwd=cwd, timeout=self.a.timeout)
            d = json.loads(r.stdout)
            if not isinstance(d, dict) or r.returncode != 0 or d.get("is_error"):
                raise ValueError("claude rc=%s is_error=%s" % (r.returncode, isinstance(d, dict) and d.get("is_error")))
            u = d.get("usage") or {}
            usd, priced = price_usage(d, self.a.model)
            row.update(named=parse_answer(d.get("result")), tokens=session_tokens(u), weighted=weighted(u, result_model(d) or self.a.model),
                       cost_usd=float(d.get("total_cost_usd") or 0.0), turns=int(d.get("num_turns") or 1),
                       priced=priced, priced_usd=usd if priced else 0.0)
            row.update(zip(("input", "output", "cache_read", "cache_creation"), usage_split(u)))
            if real:  # priced from the usage split, never the flat total_cost_usd; unpriced assumes the full cap
                row["cost_usd"] = usd if priced else cap
            row["file_hit"] = self.ev.is_hit(row["named"], q["gold"])
            row["result"] = (d.get("result") or "")[:4000]
            if sess is not None:
                sess["n"] += 1
        except (ValueError, OSError, subprocess.TimeoutExpired, TypeError) as e:
            row["error"] = str(e)[:120]
            row["cost_usd"] = cap  # a billed call we cannot read: the spend guard assumes the full cap; the arm cost leaves it out
            self.errors += 1
            if sess is not None and not sess["n"]:
                sess.setdefault("old", []).append(sess["id"])
                sess["id"] = str(uuid.uuid4())  # the failed call may have taken the id: nothing to resume
        if trace:
            calls = read_complete_calls(trace)
            row["tool_trace"] = calls
            row["route_calls"] = len(calls)
        row["ms"] = int((time.time() - t0) * 1000)
        self.spent += row["cost_usd"]
        self.rows.append(row)
        if self.sink:  # a paid run killed halfway keeps every row it already paid for
            self.sink.write(json.dumps(row) + "\n")
            self.sink.flush()
        return row


def qmd_search(ev, q, types, rerank, timeout, k, collection):
    """One qmd query with only the given search types (arm_qmd cannot send lex-only or vec-only
    plus rerank) -> (files, text, failure or None). Same seam and parsing as arm_qmd."""
    args = {"searches": [{"type": t, "query": q} for t in types], "collections": [collection],
            "limit": k, "intent": q, "rerank": rerank}
    cmd = os.environ.get("RETRIEVAL_EVAL_QMD_CMD")
    if cmd:
        out, to, rc = ev.run_cmd(shlex.split(cmd), timeout, stdin=json.dumps(args))
        if to:
            return [], "", "qmd timed out"
        if rc != 0:
            return [], "", "qmd failed (rc %s)" % rc
        try:
            rows = json.loads(out or "[]")
        except ValueError:
            return [], "", "qmd returned unreadable output"
    else:
        try:
            rows = ev.qmd_server(args, timeout)
        except Exception as e:  # a dead server is a failed route call, not a crash
            return [], "", "qmd error: %s" % str(e)[:100]
    files, text = [], []
    for r in rows:
        f = re.sub(r"^(?:qmd://[^/]+|%s)/" % re.escape(collection), "", str(r.get("file", "")))
        if f and f not in files:
            files.append(f)
        text.append("%s %s %s" % (r.get("file", ""), r.get("title", ""), r.get("snippet", "")))
    return files[:k], "\n".join(text), None


def retrieve(ev, a, q, repo, need):
    """arm name -> output text, for the arms in need (each retrieval run once per question).
    'fused-files' is the rank-fused file list of the fused route."""
    k, to = a.k, a.retrieval_timeout
    out = {}
    if {"grep", "fused"} & need:
        g = ev.arm_grep(q["q"], repo, to, k)
        out["grep"] = g[1]
    if "grep-rtk" in need:
        out["grep-rtk"] = ev.arm_grep_rtk(q["q"], repo, to, k)[1]
    if "pathident" in need:
        out["pathident"] = "%s\n%s" % (ev.arm_path(q["q"], repo, to, k)[1], ev.arm_ident_grep(q["q"], repo, to, k)[1])
    if {"graphify", "fused"} & need:
        gr = ev.arm_graphify(q["q"], repo, to, k)
        out["graphify"] = gr[1]
    if "fused" in need:
        qm = ev.arm_qmd(q["q"], True, to, k, a.collection)
        out["fused"] = "\n".join([out["grep"], qm[1], out["graphify"]])
        out["fused-files"] = ev.fuse([g[0], qm[0], gr[0]], k)
        out["fused-failure"] = next((failure for failure in (
            "grep timed out" if g[2] else "grep failed" if g[3] else None,
            qm[4], "graphify timed out" if gr[2] else "graphify failed" if gr[3] else None) if failure), None)
    return out


def trim_route(label, files, text, n=ROUTE_FILES, cap=ROUTE_EXCERPT):
    """The route answer: the top n files, each with at most cap characters of the retrieval text that
    names it (from its first mention), whitespace collapsed. The raw dumps were about 8k tokens a call."""
    low, out = text.lower(), []
    for f in files[:n]:
        i = low.find(f.lower())
        ex = " ".join(text[i:i + 4 * cap].split())[:cap] if i >= 0 else ""
        out.append("- %s: %s" % (f, ex) if ex else "- %s" % f)
    return "RANKED FILES (%s), top %d:\n%s" % (label, n, "\n".join(out))


def route_text(ev, a, kind, repo, query):
    if kind == "fused-cached":
        got = retrieve(ev, a, {"q": query}, repo, {"fused"})
        files = got["fused-files"][:ROUTE_FILES]
        return (trim_route("grep + qmd hybrid rerank + graphify, rank-fused", files, got["fused"]),
                files, got["fused-failure"])
    types, label = (("lex",), "qmd keyword (BM25) + rerank") if kind == "bm25-rerank" else (("vec",), "qmd vector + rerank")
    files, text, fail = qmd_search(ev, query, types, True, a.retrieval_timeout, a.k, a.collection)
    if fail:
        return "%s: %s" % (label, fail), files[:ROUTE_FILES], fail
    return trim_route(label, files, text), files[:ROUTE_FILES], None


def cmd_route_server(a):
    """MCP stdio server with one tool, route: lines of JSON-RPC in, lines out."""
    ev = load_eval()
    repo = os.path.abspath(a.repo)
    kind = a.kind

    def reply(mid, result=None, error=None):
        msg = {"jsonrpc": "2.0", "id": mid}
        msg["error" if error else "result"] = error or result
        sys.stdout.write(json.dumps(msg) + "\n")
        sys.stdout.flush()

    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if not isinstance(msg, dict) or msg.get("id") is None or not msg.get("method"):
            continue  # a notification or a response: nothing to answer
        mid, method, params = msg["id"], msg["method"], msg.get("params") or {}
        if method == "initialize":
            reply(mid, {"protocolVersion": params.get("protocolVersion", "2025-06-18"),
                        "capabilities": {"tools": {}}, "serverInfo": {"name": "route", "version": "1"}})
        elif method == "ping":
            reply(mid, {})
        elif method == "tools/list":
            reply(mid, {"tools": [{"name": "route", "description": ROUTE_DESC[kind],
                                   "inputSchema": {"type": "object", "properties": {"query": {"type": "string", "description": "what to look for"}},
                                                   "required": ["query"]}}]})
        elif method == "tools/call":
            query = str((params.get("arguments") or {}).get("query") or "")
            is_error = False
            try:
                text, files, failure = route_text(ev, a, kind, repo, query)
            except Exception as e:  # a route failure is the tool's error result, the session carries on
                failure, files, is_error = str(e)[:200], [], True
                text = "route failed: %s" % failure
            if a.trace:
                with open(a.trace, "a") as fh:
                    fh.write(json.dumps(dict(query=query, files=files, failure=failure)) + "\n")
            reply(mid, {"content": [{"type": "text", "text": text}], "isError": is_error})
        else:
            reply(mid, error={"code": -32601, "message": "method not found: %s" % method})
    return 0


def sample(qs, pool):
    if len(qs) <= pool:
        return list(qs)
    return [qs[i * len(qs) // pool] for i in range(pool)]


def arm_stats(rs):
    """Run-level numbers of one arm's rows. Costs are None when a call is unpriced; an errored call
    has no usage to price, so it is counted in errors and left out of the cost, turns and time."""
    ok = sum(r["file_hit"] for r in rs)
    tot = sum(r["tokens"] for r in rs)
    good = [r for r in rs if not r["error"]]
    priced = all(r["priced"] for r in good)
    cost = sum(r["priced_usd"] for r in good) if priced else None
    inp, out, cr, cc = (sum(r[k] for r in rs) for k in ("input", "output", "cache_read", "cache_creation"))
    denom = inp + cr + cc
    return dict(n=len(rs), file_hit=ok, errors=sum(1 for r in rs if r["error"]), tokens=tot,
                tokens_per_file_hit=tot / ok if ok else None, cost_usd=cost,
                cost_per_file_hit=cost / ok if ok and cost is not None else None,
                input=inp, output=out, cache_read=cr, cache_creation=cc,
                cached_share=cr / denom if denom else None,
                ms_median=statistics.median(r["ms"] for r in good) if good else None,
                turns_mean=statistics.mean(r["turns"] for r in good) if good else None)


def with_prime(rs, ps):
    """(prime_usd, cost_usd_with_prime, cost_per_file_hit_with_prime) of an arm: its measured calls `rs` plus the
    cold priming calls `ps`. All None when no prime call ran or any call is unpriced."""
    s = arm_stats(rs)
    good = [r for r in ps if not r["error"]]
    if not good or s["cost_usd"] is None or not all(r["priced"] for r in good):
        return None, None, None
    p = sum(r["priced_usd"] for r in good)
    return p, s["cost_usd"] + p, (s["cost_usd"] + p) / s["file_hit"] if s["file_hit"] else None


POS_GROUPS = (("1", "pos1", lambda n: n == 1), ("2-k", "pos2k", lambda n: n > 1))


def pos_stats(rs):
    """Mean per-call cost and cache mix of the priced, good calls in `rs`; None when there are none."""
    good = [r for r in rs if not r["error"] and r["priced"]]
    if not good:
        return None
    n = len(good)
    inp, cr, cc = (sum(r[k] for r in good) for k in ("input", "cache_read", "cache_creation"))
    return dict(n=n, cost_mean=sum(r["priced_usd"] for r in good) / n, cache_read_mean=cr / n,
                cache_creation_mean=cc / n, cached_share=cr / (inp + cr + cc) if inp + cr + cc else None)


def warm_table(rows, arms):
    """Question 1 of a session against questions 2..k, per arm."""
    lines = ["\t".join(["arm", "position", "n", "cost_mean", "cache_read_mean", "cache_creation_mean", "cached_share"])]
    for arm in arms:
        rs = [r for r in rows if r["arm"] == arm and not r["prime"]]
        for label, _, pick in POS_GROUPS:
            ps = pos_stats([r for r in rs if pick(r["pos"])])
            if ps:
                lines.append("\t".join([arm, label, str(ps["n"]), "%.4f" % ps["cost_mean"], "%.0f" % ps["cache_read_mean"],
                                        "%.0f" % ps["cache_creation_mean"],
                                        "-" if ps["cached_share"] is None else "%.3f" % ps["cached_share"]]))
    return lines


def table(rows, arms):
    cols = ["arm", "n", "file_hit", "tokens_total", "tokens_per_file_hit", "weighted_total", "cost_usd",
            "retr_tokens_mean", "errors", "priced_usd", "cost_per_file_hit", "input", "output", "cache_read",
            "cache_creation", "cached_share", "ms_median", "turns_mean", "prime_usd", "cost_with_prime",
            "cost_per_file_hit_with_prime"]
    lines = ["\t".join(cols)]
    dash = lambda v, f: "-" if v is None else f % v  # noqa: E731
    for arm in arms:
        rs = [r for r in rows if r["arm"] == arm and not r["prime"]]
        if not rs:
            continue
        s = arm_stats(rs)
        pm = with_prime(rs, [r for r in rows if r["arm"] == arm and r["prime"]])
        ok, tot = s["file_hit"], s["tokens"]
        lines.append("\t".join([arm, str(len(rs)), str(ok), str(tot), "%.1f" % (tot / ok) if ok else "-",
                                "%d" % sum(r["weighted"] for r in rs), "%.4f" % sum(r["cost_usd"] for r in rs),
                                "%d" % (sum(r["retr_tokens"] for r in rs) / len(rs)),
                                str(s["errors"]),
                                "unpriced" if s["cost_usd"] is None else "%.4f" % s["cost_usd"],
                                dash(s["cost_per_file_hit"], "%.4f"), str(s["input"]), str(s["output"]),
                                str(s["cache_read"]), str(s["cache_creation"]), dash(s["cached_share"], "%.3f"),
                                dash(s["ms_median"], "%d"), dash(s["turns_mean"], "%.1f"),
                                dash(pm[0], "%.4f"), dash(pm[1], "%.4f"), dash(pm[2], "%.4f")]))
    return lines


def ledger_row(ev, a, sw, arms, repo):
    """The eval-runs row: per-arm metrics, the insample / heldout split, per-question cases."""
    metrics, cases = {}, {}
    rows = [r for r in sw.rows if r["arm"] in arms and not r["prime"]]
    for arm in arms:
        rs = [r for r in rows if r["arm"] == arm]
        if not rs:
            continue
        s = arm_stats(rs)
        metrics.update({"%s.%s" % (arm, k): s[k] for k in
                        ("n", "file_hit", "errors", "cost_usd", "cost_per_file_hit", "tokens_per_file_hit", "input", "output",
                         "cache_read", "cache_creation", "cached_share", "ms_median", "turns_mean")})
        metrics[arm + ".unpriced"] = sum(1 for r in rs if not r["priced"])
        if a.prime:  # the cold priming call, reported apart: the headline cost_usd leaves it out
            pm = with_prime(rs, [r for r in sw.rows if r["arm"] == arm and r["prime"]])
            metrics.update(zip(("%s.prime_cost_usd" % arm, "%s.cost_usd_with_prime" % arm,
                                "%s.cost_per_file_hit_with_prime" % arm), pm))
        if a.warm_session:  # question 1 of a session against questions 2..k
            for _, key, pick in POS_GROUPS:
                ps = pos_stats([r for r in rs if pick(r["pos"])]) or {}
                metrics.update({"%s.%s.%s" % (arm, key, m): ps.get(m) for m in
                                ("n", "cost_mean", "cache_read_mean", "cache_creation_mean", "cached_share")})
        for sl in SPLITS:
            ss = arm_stats([r for r in rs if r["split"] == sl]) if any(r["split"] == sl for r in rs) else None
            pre = "%s.%s." % (arm, sl)
            metrics.update({pre + "n": ss["n"] if ss else 0, pre + "file_hit": ss["file_hit"] if ss else None,
                            pre + "cost_usd": ss["cost_usd"] if ss else None,
                            pre + "cost_per_file_hit": ss["cost_per_file_hit"] if ss else None})
        for r in rs:
            c = cases.setdefault(r["id"], {})
            c[arm + ".file_hit"] = r["file_hit"]
            c[arm + ".cost_usd"] = r["priced_usd"] if r["priced"] and not r["error"] else None
            c["heldout"] = r["split"] == "heldout"
    if not metrics:
        return None
    with open(a.questions, "rb") as fh:
        qhash = hashlib.sha256(fh.read()).hexdigest()[:16]
    with open(PREFACE, "rb") as fh:
        phash = hashlib.sha256(fh.read()).hexdigest()[:16]
    config = dict(arms=[x for x in arms if any(r["arm"] == x for r in rows)], model=a.model, k=a.k, collection=a.collection,
                  questions=qhash, pool=a.pool, n=a.n, permission_mode="dontAsk", max_usd=a.max_usd, preface=phash,
                  prime=a.prime, warm_session=a.warm_session, route_files=ROUTE_FILES, route_excerpt=ROUTE_EXCERPT,
                  scorer="file-hit")
    meta = dict(questions_path=os.path.abspath(a.questions), spent_usd=round(sw.spent, 4), stopped=sw.stopped or None,
                n_heldout=len({r["id"] for r in rows if r["split"] == "heldout"}))
    status = "partial" if sw.stopped or sw.errors else "ok"
    return ev.eval_runs.make_row("answer-ab", "scripts/eval/retrieval-eval/answer-ab.py", config, metrics, n=len(cases),
                                 model=a.model, cases=cases, artifact=os.path.abspath(a.out), meta=meta, status=status, repo=repo)


def drop_session(sid):
    """A warm session persists its transcript under the claude config dir; remove what this run created."""
    base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    for f in glob.glob(os.path.join(glob.escape(base), "projects", "*", sid + "*")):
        if os.path.isdir(f):
            shutil.rmtree(f, ignore_errors=True)
        else:
            try:
                os.remove(f)
            except OSError:
                pass


def run_warm(sw, a, real, qsel):
    """a.warm_session questions in ONE session per arm. Question j of every arm is asked before question j+1,
    so each arm's cached prefix is touched about once a minute and stays inside the 5-minute cache window."""
    k = a.warm_session
    for g, i in enumerate(range(0, len(qsel), k)):
        sessions = {arm: {"id": str(uuid.uuid4()), "n": 0} for arm in real}
        try:
            for j, q in enumerate(qsel[i:i + k]):
                if sw.stopped:
                    break
                r0 = (g + j) % len(real)
                for arm in real[r0:] + real[:r0]:
                    if sw.ask(q, arm, "", sess=sessions[arm]) is None:
                        break
                print("%s %s" % (q["id"], " ".join("%s.file_hit=%d" % (r["arm"], r["file_hit"]) for r in sw.rows if r["id"] == q["id"] and r["arm"] in real)),
                      file=sys.stderr)
        finally:
            for s in sessions.values():
                for sid in [s["id"]] + s.get("old", []):
                    drop_session(sid)
        if sw.stopped:
            break


def cmd_run(a):
    arms = [x for x in a.arms.split(",") if x]
    if not arms:
        raise Usage("--arms names no arm (known: %s)" % ",".join(ARMS))
    if a.warm_session < 0:
        raise Usage("--warm-session is the questions per session, 0 or more")
    for x in arms:
        if x not in ARMS:
            raise Usage("unknown arm '%s' (known: %s)" % (x, ",".join(ARMS)))
    ev = load_eval()
    skipped = ev.skip_rtk(arms)
    for x, why in skipped.items():
        print("answer-ab: skipping %s: %s" % (x, why), file=sys.stderr)
    arms = [x for x in arms if x not in skipped]
    if not arms:
        raise Usage("no arm left to run")
    old = [x for x in arms if x in OLD_ARMS]
    real = [x for x in arms if x in REAL_ARMS]
    qs = [q for q in ev.load_questions(a.questions) if q.get("gold")]
    if not qs:
        raise Usage("no question with a gold file in %s" % a.questions)
    repo = os.path.abspath(a.repo)
    os.makedirs(a.out, exist_ok=True)
    if os.path.exists(os.path.join(a.out, "STOPPED")):
        os.remove(os.path.join(a.out, "STOPPED"))
    sw = Sweep(a, ev)
    sw.sink = open(os.path.join(a.out, "results.jsonl"), "w")

    kept = []
    if old:
        for q in sample(qs, a.pool):
            row = sw.ask(q, "none", "", tag="screen")
            if row is None:
                break
            if not row["file_hit"] and not row["error"] and len(kept) < a.n:
                kept.append(q)
    with open(os.path.join(a.out, "screened.txt"), "w") as fh:
        fh.write("".join(q["id"] + "\n" for q in kept))

    need = set(old) - {"none"}
    for i, q in enumerate(kept):
        if sw.stopped:
            break
        ctx = retrieve(ev, a, q, repo, need) if need else {}
        order = old[i % len(old):] + old[:i % len(old)]  # rotate: load drift is not an arm effect
        for arm in order:
            if sw.ask(q, arm, ctx.get(arm, "")) is None:
                break
        print("%s %s" % (q["id"], " ".join("%s.file_hit=%d" % (r["arm"], r["file_hit"]) for r in sw.rows if r["id"] == q["id"] and r["arm"] in old)),
              file=sys.stderr)

    if real:  # the realistic arms take the question sample whole: no closed-book screen
        if a.prime:  # one throwaway call per arm writes its prefix cold, so no measured call pays for it
            for arm in real:
                if sw.ask({"id": "prime", "q": PRIME_Q, "gold": [], "split": "prime"}, arm, "", prime=True) is None:
                    break
        qsel = sample(qs, a.pool)[:a.n]
        if a.warm_session:
            run_warm(sw, a, real, qsel)
        else:
            for i, q in enumerate(qsel):
                if sw.stopped:
                    break
                for arm in real[i % len(real):] + real[:i % len(real)]:
                    if sw.ask(q, arm, "") is None:
                        break
                print("%s %s" % (q["id"], " ".join("%s.file_hit=%d" % (r["arm"], r["file_hit"]) for r in sw.rows if r["id"] == q["id"] and r["arm"] in real)),
                      file=sys.stderr)

    sw.sink.close()
    lines = table(sw.rows, arms)
    with open(os.path.join(a.out, "table.tsv"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    if a.warm_session and real:
        wl = warm_table(sw.rows, real)
        with open(os.path.join(a.out, "warm.tsv"), "w") as fh:
            fh.write("\n".join(wl) + "\n")
        print("\n".join(wl))
    if old:
        print("screened %d of %d sampled (the answerer failed them closed-book); spent_usd=%.4f" %
              (len(kept), min(a.pool, len(qs)), sw.spent))
    else:
        print("spent_usd=%.4f" % sw.spent)
    if sw.stopped:
        with open(os.path.join(a.out, "STOPPED"), "w") as fh:
            fh.write("STOPPED: %s\n" % sw.stopped)
        print("STOPPED: %s" % sw.stopped, file=sys.stderr)
    if not a.no_ledger:
        row = ledger_row(ev, a, sw, arms, repo)
        if row:
            ev.eval_runs.append_safe(row, who="answer-ab")
        else:
            print("answer-ab: no arm row to record: no eval-runs row written", file=sys.stderr)
    return 1 if sw.stopped or sw.errors else 0


def main(argv=None):
    p = Parser(prog="answer-ab.py")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("run")
    r.add_argument("--questions", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--repo", default=".")
    r.add_argument("--arms", default=",".join(OLD_ARMS))
    r.add_argument("--pool", type=int, default=20)
    r.add_argument("--n", type=int, default=15)
    r.add_argument("--k", type=int, default=5)
    r.add_argument("--model", default="claude-haiku-5-5")
    r.add_argument("--max-usd", type=float, default=3.0)
    r.add_argument("--timeout", type=int, default=180)
    r.add_argument("--retrieval-timeout", type=int, default=60)
    r.add_argument("--collection", default="himmel")
    r.add_argument("--no-ledger", action="store_true")
    r.add_argument("--prime", action="store_true")
    r.add_argument("--warm-session", type=int, default=0)
    r.error = p.error
    s = sub.add_parser("route-server")
    s.add_argument("--kind", required=True, choices=sorted(ROUTE_DESC))
    s.add_argument("--repo", required=True)
    s.add_argument("--k", type=int, default=5)
    s.add_argument("--retrieval-timeout", type=int, default=60)
    s.add_argument("--collection", default="himmel")
    s.add_argument("--trace")
    s.error = p.error
    try:
        a = p.parse_args(argv)
        if a.cmd == "run":
            if os.environ.get("HIMMEL_BILLED_OK") != "1":
                raise Usage("run makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)")
            return cmd_run(a)
        if a.cmd == "route-server":
            return cmd_route_server(a)
        raise Usage("name a subcommand: run")
    except Usage as e:
        print("answer-ab: %s" % e, file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
