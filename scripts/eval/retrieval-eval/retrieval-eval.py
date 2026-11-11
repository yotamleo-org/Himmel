#!/usr/bin/env python3
"""scripts/eval/retrieval-eval/retrieval-eval.py - retrieval eval + usage census (HIMMEL-6143).

Asks the same questions of nine retrieval arms and scores each against a gold
file set, then counts how sessions really use qmd and graphify.

  run     --questions Q --out DIR [--repo R] [--arms A,B] [--k 5] [--timeout 60]
          [--collection himmel] [--label L]
  check   --questions Q [--repo R]           validate a question set, print its size
  census  --out FILE [--projects DIR] [--days 7]
  replay  --results FILE [--questions Q] [--arms grep,qmd-hybrid,graphify]
          [--rrf-k 60] [--k 5] [--add path,ident-grep]
          Re-fuse saved files offline; compare with saved combined hits. Questions
          default to questions.jsonl beside this script. Only dev IDs are printed;
          held-out results are counts only. No subprocesses, retrieval or network.
  mine-luna --out FILE --vault V [--days 30] [--repo R] [--projects DIR]
          Lists luna notes sessions used, by source: qmd (surfaced by a luna query) and
          direct (opened by path, whether found by grep or a wikilink, with no earlier qmd
          call surfacing it); the third source, written, is by hand. FILE holds the paths
          and stays outside every checkout; stdout holds counts and a hash.
  run --corpus luna --graph-out SCRATCH ...   the luna arms qmd-hybrid, qmd-lex, graphify-ast
          and fused-no-grep (hybrid + AST, no grep) over a bank of {id, q, gold, source}.
          qmd-hybrid, alone or inside fused-no-grep, is paid and refuses without
          HIMMEL_BILLED_OK=1; qmd-lex needs QMD_URL on a scratch daemon. A hybrid row whose
          query failed is `degraded` and cannot enter a ruling. --out and --graph-out stay
          outside every checkout.
  vault-report DIR [--token-ceiling 7161]   per source numbers of a luna run, then the
          ruling row (exact McNemar against qmd-hybrid, Holm over AST and fused at .05).
          DIR stays outside every checkout.

Arms (all read-only):
  grep        git grep over the repo's tracked files for the question's words,
              files ranked by distinct words matched; shows <=8 lines per file
  grep-rtk    the grep arm's files, read as a session reads them: the grep command goes
              through `rtk rewrite`, as the hook does, and the rewritten command runs, so
              the filter's truncation counts; files, tokens and reason come from rtk's
              output, <=8 lines per file. Skipped, with the reason printed and recorded in
              the ledger config, when rtk is not on PATH. The score a session gets from grep
  path        the tracked file paths, ranked by distinct question words in the path
              (a filename-only baseline)
  ident-grep  git grep -w for the question's identifier-shaped tokens (snake_case,
              kebab-case, camelCase, file.ext); files holding a definition line
              rank first
  ident-grep-rtk  the ident-grep arm's files read through rtk, as grep-rtk reads grep's
  qmd-lex    qmd BM25 (lex search), rerank off
  qmd-hybrid  qmd lex + vec with rerank true, sent explicitly (the server default is off)
  qmd-hybrid-norerank  the same lex + vec searches with rerank off; opt-in via
              --arms, not in the default seven and not fused into combined
  graphify    scripts/graphify/worker-graph.sh query (the primary checkout's graph, or with
              --pair the pair's scratch graph through WORKER_GRAPH_OUT)
  combined    reciprocal-rank fusion of grep, qmd-hybrid and graphify (not the
              path and ident-grep baselines); its tokens and time are the sum
              of the three
Metrics per arm: hit@5 (a gold file is among the first k distinct files),
hit_any@5 (a gold or gold1 file is), precision@5 (graded files among the first
k, over k: a short list is penalised), mrr (mean reciprocal rank of the first
gold file in the first k, 0 for a miss), gold_share (gold files over files
returned, pooled over the questions: off-target noise shows as a low share),
ndcg@5 (graded: gold = 2, gold1 = 1, each file counted once, the ideal list
holds every graded file), reason_carried (every reason phrase appears in the
arm's output; only questions with a reason count), tokens (output chars / 4:
what the caller has to read), tokens_per_hit (tokens over hits, pooled; "-" for
an arm with no hit), ms (wall time).

A question row is {id, kind, q, gold: [paths], reason: [phrases]} plus the
optional gold1: [paths] (plausible docs, grade 1; gold files are grade 2: the
file defines or decides the answer) and split: "insample" (the default) or
"heldout". A held-out question is frozen: it is never used to tune an arm, a
query or a seed, and nothing outside this directory may quote it. Every run
reports the two slices separately: scores-by-slice.tsv, the printed slice table
and, per arm, <arm>.insample.* and <arm>.heldout.* ledger metrics (n, hit@k,
hit_any@k, ndcg@k, reason_carried; null where the slice has no question to
score). The unsliced columns pool both slices: read them only as a continuity
series.

qmd is reached the way agents reach it: the MCP server (QMD_URL, default
http://localhost:8181/mcp, bearer token from the qmd plugin's helper). The
CLI is not used for the vec arm because it runs without the server's API key.
Seams: RETRIEVAL_EVAL_QMD_CMD (stdin: the query arguments as JSON; stdout: a
JSON list of {file, snippet}) and RETRIEVAL_EVAL_GRAPH_CMD (called with
`query <q>`, prints graphify's NODE lines).

Output in DIR: results.jsonl (one row per question x arm), scores.tsv (also
printed), and one eval-runs ledger row (eval "retrieval-eval", see
scripts/eval/README.md). Rows keep files_top20, from a second query at max(k, 20), as
evidence only; files and scoring come from the limit-k query. qmd_error keeps failure details; skipped is false for real rows
(skipped arms have no rows, and their reasons stay in the ledger config).
Exit: 0 scored, 1 check found problems or a graph arm's stamp is unavailable,
64 usage error. A missing graph stamp still writes all run outputs.
Stdlib only.
"""
import argparse
import datetime
import functools
import glob
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import signal
import statistics
import subprocess
import sys
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402
import wilson  # noqa: E402
import importlib.util  # noqa: E402

_vx_spec = importlib.util.spec_from_file_location("vocab_expand", os.path.join(HERE, "..", "..", "qmd", "vocab-expand.py"))
vocab_expand = importlib.util.module_from_spec(_vx_spec)
_vx_spec.loader.exec_module(vocab_expand)

SPLITS = ("insample", "heldout")
STRATA = ("code", "doc")
ARMS =["grep", "grep-rtk", "path", "ident-grep", "ident-grep-rtk", "qmd-lex", "qmd-hybrid", "graphify", "combined"]
RTK_ARMS = ["grep-rtk", "ident-grep-rtk"]
FUSED = ["grep", "qmd-hybrid", "graphify"]
OPT_IN = ["qmd-hybrid-norerank"]
LUNA_ARMS = ["qmd-hybrid", "qmd-lex", "graphify-ast", "fused-no-grep"]
FUSED_LUNA = ["qmd-hybrid", "graphify-ast"]
FUSED_OF = {"combined": FUSED, "fused-no-grep": FUSED_LUNA}
TOKEN_CEILING = 7161
# The question set holds every question and reason phrase verbatim; vendored
# plugin bundles and minified files fill a top 5 with one-line noise.
GREP_SCOPE = [".", ":(exclude)scripts/eval/retrieval-eval/", ":(exclude,glob)templates/**/.obsidian/plugins/**",
              ":(exclude)*.min.js", ":(exclude)*.min.css"]
STOP = set("""a an and are as at be by can do does for from has have how i in is it its
of on or that the this to was what when where which who whom why will with without
while into than then them there their not no my me we our you your does do did
should would could any every each one only same""".split())


class Usage(Exception):
    pass


class Refuse(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def words(q):
    out = []
    for w in re.findall(r"[A-Za-z0-9_][A-Za-z0-9_.\-]*", q):
        w = w.strip(".-").lower()
        if len(w) >= 3 and w not in STOP and w not in out:
            out.append(w)
    return out


def tok(text):
    return len(text) // 4


def run_cmd(argv, timeout, cwd=None, stdin=None):
    """(stdout, timed_out, rc). A timeout kills the command's whole process group."""
    p = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True, start_new_session=True)
    try:
        out, _ = p.communicate(stdin, timeout=timeout)
        return out, False, p.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        out, _ = p.communicate()
        return out or "", True, None


def arm_grep(q, repo, timeout, k):
    kws = words(q)
    score = {}
    t0 = time.time()
    for w in kws:
        remaining = timeout - (time.time() - t0)
        if remaining <= 0:
            return [], "", True, False
        out, to, rc = run_cmd(["git", "-C", repo, "grep", "-I", "-i", "-c", "-F", "-e", w, "--"] + GREP_SCOPE,
                              remaining)
        if to:
            return [], "", True, False
        if rc not in (0, 1):
            return [], "", False, True
        for line in out.splitlines():
            f, _, n = line.rpartition(":")
            d, c = score.get(f, (0, 0))
            score[f] = (d + 1, c + int(n or 0))
    files = sorted(score, key=lambda f: (-score[f][0], -score[f][1], f))[:k]
    text, to, err = [], False, False
    for f in files:
        argv = ["git", "-C", repo, "grep", "-n", "-I", "-i", "-F"]
        for w in kws:
            argv += ["-e", w]
        remaining = timeout - (time.time() - t0)
        if remaining <= 0:
            return files, "\n".join(text), True, err
        out, t, rc = run_cmd(argv + ["--", f], remaining)
        to, err = to or t, err or (not t and rc not in (0, 1))
        text += out.splitlines()[:8]
    return files, "\n".join(text), to, err


def arm_path(q, repo, timeout, k):
    kws = []
    for w in words(q):  # worker_tail_status names worker-tail-status.sh: match its parts
        for p in re.split(r"[_.\-]", w):
            if len(p) >= 3 and p not in STOP and p not in kws:
                kws.append(p)
    out, to, rc = run_cmd(["git", "-C", repo, "ls-files", "--"] + GREP_SCOPE, timeout)
    if to:
        return [], "", True, False
    if rc != 0:
        return [], "", False, True
    score = {}
    for f in out.splitlines():
        low = f.lower()
        base = low.rsplit("/", 1)[-1]
        hit = [w for w in kws if w in low]
        if hit:
            score[f] = (len(hit), sum(w in base for w in hit), -len(f))
    files = sorted(score, key=lambda f: (score[f], f), reverse=True)[:k]
    return files, "\n".join(files), False, False


IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:[-.][A-Za-z0-9_]+)*")


def idents(q):
    """Identifier-shaped tokens of a question: snake_case, kebab-case, camelCase or file.ext."""
    out = []
    for w in IDENT.findall(q):
        if len(w) >= 3 and w.lower() not in STOP and w not in out and (
                re.search(r"[_.\-]", w) or re.search(r"[a-z][A-Z]", w)):
            out.append(w)
    return out


def definition(ident):
    """A line that defines ident: a function, class or variable, in shell, python or js."""
    i = re.escape(ident)
    return re.compile(r"^\s*(?:(?:export\s+)?(?:async\s+)?(?:def|class|function|const|let|var|func|fn)\s+%s\b"
                      r"|%s\s*\(\s*\)\s*\{|(?:export\s+)?%s\s*(?::[^=]+)?=(?!=))" % (i, i, i))


def arm_ident_grep(q, repo, timeout, k):
    t0 = time.time()
    score, lines = {}, {}
    for ident in idents(q):
        remaining = timeout - (time.time() - t0)
        if remaining <= 0:
            return [], "", True, False
        out, to, rc = run_cmd(["git", "-C", repo, "grep", "-n", "-I", "-w", "-F", "-e", ident, "--"] + GREP_SCOPE,
                              remaining)
        if to:
            return [], "", True, False
        if rc not in (0, 1):
            return [], "", False, True
        dre = definition(ident)
        seen = set()
        for line in out.splitlines():
            f, _, rest = line.partition(":")
            body = rest.partition(":")[2]
            d, n, c = score.get(f, (0, 0, 0))
            if f not in seen:
                seen.add(f)
                n += 1
            score[f] = (d or int(bool(dre.search(body))), n, c + 1)
            lines.setdefault(f, []).append(line)
    files = sorted(score, key=lambda f: (-score[f][0], -score[f][1], -score[f][2], f))[:k]
    text = [ln for f in files for ln in lines[f][:8]]
    return files, "\n".join(text), False, False


RTK_LINE = re.compile(r"(.+?):\d+:")


def rtk_view(flags, terms, files, repo, timeout):
    """(files, text, timed_out, error) of what a session reads when it greps `files` for `terms`: the
    command is handed to `rtk rewrite`, as the hook does, and the rewritten command is run. A file's lines
    are capped at 8, as in the raw arms, so the difference is the filter alone."""
    if not files:
        return [], "", False, False
    t0 = time.time()
    cmd = ["grep", "-n", "-I", "-H"] + flags
    for t in terms:
        cmd += ["-e", t]
    out, to, rc = run_cmd(["rtk", "rewrite", shlex.join(cmd + ["--"] + files)], timeout, cwd=repo)
    if to:
        return [], "", True, False
    if rc != 0 or not out.startswith("rtk "):
        return [], "", False, True
    remaining = timeout - (time.time() - t0)
    if remaining <= 0:
        return [], "", True, False
    out, to, rc = run_cmd(shlex.split(out), remaining, cwd=repo)
    if to:
        return [], "", True, False
    if rc not in (0, 1):
        return [], "", False, True
    seen, count, text = [], {}, []
    for line in out.splitlines():
        m = RTK_LINE.match(line)
        f = m.group(1) if m and m.group(1) in files else None
        if f is None:
            text.append(line)
            continue
        if f not in seen:
            seen.append(f)
        count[f] = count.get(f, 0) + 1
        if count[f] <= 8:
            text.append(line)
    return seen, "\n".join(text), False, False


def arm_grep_rtk(q, repo, timeout, k):
    t0 = time.time()
    files, _, to, err = arm_grep(q, repo, timeout, k)
    if to or err:
        return files, "", to, err
    return rtk_view(["-i", "-F"], words(q), files, repo, timeout - (time.time() - t0))


def arm_ident_grep_rtk(q, repo, timeout, k):
    t0 = time.time()
    files, _, to, err = arm_ident_grep(q, repo, timeout, k)
    if to or err:
        return files, "", to, err
    return rtk_view(["-w", "-F"], idents(q), files, repo, timeout - (time.time() - t0))


@functools.lru_cache(maxsize=None)
def qmd_token():
    """The qmd bearer token, read once per run."""
    helper = os.path.join(HERE, "..", "..", "..", "marketplace", "plugins", "qmd", "scripts", "qmd-auth-headers.sh")
    try:
        return subprocess.run(["bash", helper, "--token"], capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return ""


def _mcp_post(url, body, headers, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers=dict(headers, **{"Content-Type": "application/json",
                                                          "Accept": "application/json, text/event-stream"}))
    loopback = (urllib.parse.urlsplit(url).hostname or "").lower() in LOOPBACK
    open_url = urllib.request.build_opener(urllib.request.ProxyHandler({})).open if loopback else urllib.request.urlopen
    with open_url(req, timeout=timeout) as r:
        raw = r.read().decode(errors="replace")
        sid = r.headers.get("mcp-session-id")
    if raw.lstrip().startswith("{"):
        return json.loads(raw), sid
    msg = None
    for line in raw.splitlines():
        if line.startswith("data:"):
            try:
                msg = json.loads(line[5:].strip())
            except ValueError:
                pass
    return msg, sid


def mcp_tool_call(name, args, timeout):
    end = time.time() + timeout
    left = lambda: max(0.1, end - time.time())  # noqa: E731
    url = os.environ.get("QMD_URL", "http://localhost:8181/mcp")
    h = {}
    t = qmd_token()
    if t:
        h["Authorization"] = "Bearer " + t
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                       "clientInfo": {"name": "retrieval-eval", "version": "1"}}}
    _, sid = _mcp_post(url, init, h, left())
    if sid:
        h["mcp-session-id"] = sid
    try:
        _mcp_post(url, {"jsonrpc": "2.0", "method": "notifications/initialized"}, h, left())
    except Exception:
        pass
    msg, _ = _mcp_post(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                             "params": {"name": name, "arguments": args}}, h, left())
    return msg


def qmd_server(args, timeout):
    return mcp_rows(mcp_tool_call("query", args, timeout))


def mcp_rows(msg):
    """The rows of a tools/call reply; an error reply raises RuntimeError."""
    if not isinstance(msg, dict) or msg.get("error"):
        raise RuntimeError("qmd error reply: %s" % (msg or {}).get("error"))
    res = msg.get("result") or {}
    if res.get("isError"):
        raise RuntimeError("qmd tool error")
    sc = res.get("structuredContent") or {}
    rows = sc.get("results") if isinstance(sc, dict) else None
    if rows is None:
        txt = " ".join(c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
        try:
            rows = json.loads(txt)
        except ValueError:
            rows = [{"file": m, "snippet": ""} for m in re.findall(r"qmd://\S+", txt)]
    return rows if isinstance(rows, list) else []


def arm_qmd(q, hybrid, timeout, k, collection, rerank=True):
    vec = vocab_expand.shape_vec(q) if hybrid else ""
    args = {"searches": [{"type": "lex", "query": vocab_expand.shape_lex(q, quote_flags=True)}] + ([{"type": "vec", "query": vec}] if vec else []),
            "collections": [collection], "limit": k, "intent": q}
    args["rerank"] = hybrid and rerank
    cmd = os.environ.get("RETRIEVAL_EVAL_QMD_CMD")
    if cmd:
        out, to, rc = run_cmd(shlex.split(cmd), timeout, stdin=json.dumps(args))
        if to:
            return [], "", True, False, "timed out"
        if rc != 0:
            return [], "", False, True, "qmd failed (rc %s)" % rc
        try:
            rows = json.loads(out or "[]")
        except ValueError:
            return [], "", False, True, "qmd returned unreadable output"
    else:
        try:
            rows = qmd_server(args, timeout)
        except Exception as e:  # a timeout or a dead server is a scored miss, not a crash
            to = "timed out" in str(e).lower() or isinstance(e, TimeoutError)
            return [], "", to, not to, str(e)[:100]
    if not isinstance(rows, list) or any(not isinstance(r, dict) for r in rows):
        return [], "", False, True, "qmd returned unreadable output"
    files, text = [], []
    for r in rows:
        f = re.sub(r"^(?:qmd://[^/]+|%s)/" % re.escape(collection), "", str(r.get("file", "")))
        if f and f not in files:
            files.append(f)
        text.append("%s %s %s" % (r.get("file", ""), r.get("title", ""), r.get("snippet", "")))
    return files[:k], "\n".join(text), False, False, ""


def arm_graphify(q, repo, timeout, k):
    cmd = os.environ.get("RETRIEVAL_EVAL_GRAPH_CMD")
    argv = shlex.split(cmd) if cmd else ["bash", os.path.join(repo, "scripts", "graphify", "worker-graph.sh")]
    out, to, rc = run_cmd(argv + ["query", q], timeout, cwd=repo)
    files = []
    for f in re.findall(r"\[src=([^\s\]]+)", out):
        if f not in files:
            files.append(f)
    return files[:k], out, to, not to and rc != 0


def fuse(lists, k, rrf_k=60):
    """Reciprocal-rank fusion; qmd lowercases its paths, so the key is the lowercased path."""
    s, name = {}, {}
    for lst in lists:
        for i, f in enumerate(lst):
            key = f.lower()
            name.setdefault(key, f)
            s[key] = s.get(key, 0.0) + 1.0 / (rrf_k + i + 1)
    return [name[x] for x in sorted(s, key=lambda x: (-s[x], x))[:k]]


def is_hit(files, gold):
    """qmd lowercases its paths, so compare case-insensitively."""
    fl, gl = [f.lower() for f in files], [g.lower() for g in gold]
    return any(f == g or f.endswith("/" + g) for f in fl for g in gl)


def stratum(q):
    return "doc" if any(g.lower().endswith(".md") for g in q["gold"]) else "code"


def is_hit_any(files, q):
    return is_hit(files, q["gold"] + q.get("gold1", []))


def ndcg(files, q, k):
    """nDCG@k with gain 2 for a gold file and 1 for a gold1 file; a graded file is counted once."""
    graded = {g.lower(): 1 for g in q.get("gold1", [])}
    graded.update({g.lower(): 2 for g in q["gold"]})
    left = list(graded.items())
    ideal = sum(g / math.log2(i + 2) for i, g in enumerate(sorted((g for _, g in left), reverse=True)[:k]))
    dcg = 0.0
    for i, f in enumerate(files[:k]):
        fl = f.lower()
        m = [e for e in left if fl == e[0] or fl.endswith("/" + e[0])]
        if m:
            e = max(m, key=lambda e: e[1])
            left.remove(e)
            dcg += e[1] / math.log2(i + 2)
    return dcg / ideal if ideal else 0.0


def _named(f, names):
    fl = f.lower()
    return any(fl == n.lower() or fl.endswith("/" + n.lower()) for n in names)


def _top(files, k):
    out, seen = [], set()
    for f in files:
        if f.lower() not in seen:
            seen.add(f.lower())
            out.append(f)
    return out[:k]


def _count(files, names, k):
    """Files among the first k distinct ones that name a path in names, each path used once."""
    left = [n.lower() for n in names]
    c = 0
    for f in _top(files, k):
        fl = f.lower()
        m = next((n for n in left if fl == n or fl.endswith("/" + n)), None)
        if m:
            left.remove(m)
            c += 1
    return c


def precision(files, q, k):
    """Graded (gold or gold1) files among the first k distinct files, over k; each graded path counts once."""
    return _count(files, q["gold"] + q.get("gold1", []), k) / k


def reciprocal_rank(files, q, k):
    for i, f in enumerate(_top(files, k)):
        if _named(f, q["gold"]):
            return 1.0 / (i + 1)
    return 0.0


def gold_found(files, q, k):
    """(gold files, files returned) among the first k distinct files."""
    top = _top(files, k)
    return _count(files, q["gold"], k), len(top)


def gold_share(files, q, k):
    g, n = gold_found(files, q, k)
    return g / n if n else None


def carried(text, reason):
    if not reason:
        return None
    low = text.lower()
    return all(r.lower() in low for r in reason)


def load_questions(path):
    if not os.path.isfile(path):
        raise Usage("no question file at '%s'" % path)
    rows = []
    with open(path) as fh:
        for i, line in enumerate(fh, 1):
            if line.strip():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    raise Usage("%s:%d is not JSON" % (path, i))
    return rows


def cmd_check(a):
    rows = load_questions(a.questions)
    bad = []
    seen = set()
    for r in rows:
        for key in ("id", "q", "gold", "reason"):
            if key not in r:
                bad.append("%s: missing %s" % (r.get("id"), key))
        if r.get("id") in seen:
            bad.append("%s: duplicate id" % r.get("id"))
        seen.add(r.get("id"))
        if r.get("split", "insample") not in SPLITS:
            bad.append("%s: split '%s' is not one of %s" % (r.get("id"), r.get("split"), "/".join(SPLITS)))
        for g in r.get("gold1", []):
            if not os.path.isfile(os.path.join(a.repo, g)):
                bad.append("%s: gold1 file %s does not exist" % (r.get("id"), g))
            if g in r.get("gold", []):
                bad.append("%s: %s is graded both 2 and 1" % (r.get("id"), g))
        texts = []
        for g in r.get("gold", []):
            p = os.path.join(a.repo, g)
            if not os.path.isfile(p):
                bad.append("%s: gold file %s does not exist" % (r.get("id"), g))
            else:
                with open(p, errors="replace") as fh:
                    texts.append(fh.read().lower())
        for t in r.get("reason", []):
            if not any(t.lower() in x for x in texts):
                bad.append("%s: reason '%s' is in no gold file" % (r.get("id"), t))
    for b in bad:
        print("check: " + b, file=sys.stderr)
    print(len(rows))
    return 1 if bad else 0


def skip_rtk(arms):
    """arm -> reason, for the RTK arms asked for when rtk is not installed."""
    if shutil.which("rtk"):
        return {}
    return {x: "rtk is not on PATH" for x in arms if x in RTK_ARMS}


def run_arm(arm, q, repo, a, k):
    if arm == "grep":
        return arm_grep(q, repo, a.timeout, k) + ("",)
    if arm == "grep-rtk":
        return arm_grep_rtk(q, repo, a.timeout, k) + ("",)
    if arm == "path":
        return arm_path(q, repo, a.timeout, k) + ("",)
    if arm == "ident-grep":
        return arm_ident_grep(q, repo, a.timeout, k) + ("",)
    if arm == "ident-grep-rtk":
        return arm_ident_grep_rtk(q, repo, a.timeout, k) + ("",)
    if arm in ("graphify", "graphify-ast"):
        return arm_graphify(q, repo, a.timeout, k) + ("",)
    return arm_qmd(q, arm != "qmd-lex", a.timeout, k, a.collection, arm != "qmd-hybrid-norerank")


LIVE_QMD_PORT = 8181
LOOPBACK = ("localhost", "127.0.0.1", "::1", "0.0.0.0")


def url_key(url):
    u = urllib.parse.urlsplit(url)
    return (u.scheme, (u.hostname or "").lower(), u.port, u.path.rstrip("/"))


def load_pair(path):
    try:
        with open(path) as fh:
            pair = json.load(fh)
    except (OSError, ValueError) as e:
        raise Usage("cannot read pair.json '%s': %s" % (path, e)) from e
    if not isinstance(pair, dict):
        raise Usage("pair.json '%s' is not an object" % path)
    return pair


def refuse_live(u):
    k = url_key(u)
    if k[1] in LOOPBACK and k[2] == LIVE_QMD_PORT:
        raise Refuse("%s is the live qmd server's port, not a scratch pair" % u)


def checkout_roots(repo):
    """Every checkout git knows for repo. A git failure refuses: a guard that cannot list the checkouts must not pass."""
    def git(*args):
        try:
            r = subprocess.run(["git", "-C", repo] + list(args), capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise Refuse("cannot list the checkouts of %s: %s" % (repo, e)) from e
        if r.returncode != 0:
            raise Refuse("cannot list the checkouts of %s: git %s failed: %s" % (repo, args[0], r.stderr.strip()[:100]))
        return r.stdout.strip()
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir")
    roots = {os.path.realpath(repo), os.path.realpath(git("rev-parse", "--show-toplevel")),
             os.path.realpath(os.path.dirname(common))}
    roots.update(os.path.realpath(x[len("worktree "):]) for x in git("worktree", "list", "--porcelain").splitlines()
                 if x.startswith("worktree "))
    return roots


def refuse_repo_path(path, repo, what):
    """I9: a luna question, gold path or note text never lands in a checkout, through a symlink or not."""
    real = os.path.realpath(path)
    for root in sorted(checkout_roots(repo)):
        if real == root or real.startswith(root + os.sep):
            raise Refuse("%s %s is inside the checkout %s: luna content stays outside every checkout" % (what, path, root))


def luna_setup(a, arms):
    if a.pair or a.index_state:
        raise Usage("--pair and --index-state belong to the himmel corpus")
    refuse_repo_path(a.out, a.repo, "--out")
    if a.graph_out:
        refuse_repo_path(a.graph_out, a.repo, "--graph-out")
    need = set(arms) | (set(FUSED_LUNA) if "fused-no-grep" in arms else set())
    if "qmd-hybrid" in need and os.environ.get("HIMMEL_BILLED_OK") != "1":
        raise Refuse("a luna run of qmd-hybrid is paid (embedding and rerank): it needs HIMMEL_BILLED_OK=1 after a sized OK; "
                     "the free arms are qmd-lex and graphify-ast")
    if "qmd-lex" in arms:
        url = os.environ.get("QMD_URL")
        if not url:
            raise Refuse("QMD_URL is not set, so the live server would answer: set it to a scratch daemon's URL")
        refuse_live(url)
    if "graphify-ast" in need:
        if not a.graph_out:
            raise Usage("graphify-ast needs --graph-out <scratch graphify-out dir>")
        if not os.path.isfile(os.path.join(a.graph_out, "graph.json")):
            raise Usage("no graph.json in %s" % a.graph_out)
        os.environ["WORKER_GRAPH_OUT"] = os.path.abspath(a.graph_out)


def check_served_url(pair):
    url = os.environ.get("QMD_URL")
    if not url:
        raise Refuse("QMD_URL is not set, so the default live server would answer: set it to the pair's served URL")
    served = pair.get("served_url")
    if not served:
        raise Refuse("pair.json names no served URL: serve the pair first (staleness-fixture.sh serve)")
    for u in (url, served):
        refuse_live(u)
    if url_key(url) != url_key(served):
        raise Refuse("QMD_URL %s is not the pair's served URL %s" % (url, served))


def served_count(timeout):
    cmd = os.environ.get("RETRIEVAL_EVAL_QMD_STATUS_CMD")
    if cmd:
        out, to, rc = run_cmd(shlex.split(cmd), timeout)
        text = out if rc == 0 and not to else ""
    else:
        try:
            msg = mcp_tool_call("status", {}, timeout)
        except Exception as e:
            raise Refuse("the served server's status call failed: %s" % str(e)[:100]) from e
        res = (msg or {}).get("result") or {}
        sc = res.get("structuredContent")
        text = json.dumps(sc) if isinstance(sc, dict) else " ".join(
            c.get("text", "") for c in res.get("content", []) if isinstance(c, dict))
    m = re.search(r'"?totalDocuments"?\s*[:=]\s*(\d+)', text)
    if not m:
        raise Refuse("the served server's status reports no totalDocuments")
    return int(m.group(1))


def pair_commits(pair, qs):
    if pair.get("first") and pair.get("second"):
        return pair["first"], pair["second"]
    named = {(q["pair"]["first"], q["pair"]["second"]) for q in qs if isinstance(q.get("pair"), dict)}
    if len(named) != 1:
        raise Usage("pair.json names no commits and the questions do not agree on one pair")
    return named.pop()


def pair_graph_out(pair, qs, state, repo):
    if state not in ("s", "l"):
        raise Usage("a graph arm reads state s (built at the first commit) or l (the second), not %s" % state)
    commit = pair_commits(pair, qs)[0 if state == "s" else 1]
    arc = (pair.get("graph_built_at") or {}).get(commit)
    if not arc:
        raise Usage("pair.json has no graph built at %s: run staleness-fixture.sh graph" % commit[:12])
    out = os.path.join(arc, "graphify-out")
    common = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, timeout=10).stdout.strip()
    live = [os.path.join(repo, "graphify-out")]
    if common:
        live.append(os.path.join(os.path.dirname(common), "graphify-out"))
    real = os.path.realpath(out)
    for g in live:
        g = os.path.realpath(g)
        if real == g or real.startswith(g + os.sep):
            raise Refuse("%s is a checkout's graphify-out, not a scratch graph" % out)
    if not os.path.isfile(os.path.join(out, "graph.json")):
        raise Usage("no graph.json in %s" % out)
    try:
        stamp = stamp_of(os.path.join(out, "graph.json"))
    except RuntimeError:
        stamp = None
    if stamp and not (commit.startswith(stamp) or stamp.startswith(commit)):
        raise Refuse("the graph in %s was built at %s, not at the pair commit %s" % (out, stamp[:12], commit[:12]))
    return out, commit


def pair_setup(a, arms, qs, repo):
    if bool(a.pair) != bool(a.index_state):
        raise Usage("--pair and --index-state go together")
    if not a.pair:
        return {}
    graph_commit = None
    if a.index_state not in ("s", "l", "c"):
        raise Usage("--index-state is s, l or c")
    pair = load_pair(a.pair)
    if any(x.startswith("qmd") or x == "combined" for x in arms):
        check_served_url(pair)
        if pair.get("state") != a.index_state:
            raise Refuse("--index-state %s, but the served index was built as state %s" % (a.index_state, pair.get("state")))
        n = served_count(a.timeout)
        if n != pair.get("doc_count"):
            raise Refuse("the served server holds %d documents; pair.json says %s" % (n, pair.get("doc_count")))
    if "graphify" in arms or "combined" in arms:
        os.environ["WORKER_GRAPH_OUT"], graph_commit = pair_graph_out(pair, qs, a.index_state, repo)
    first, second = pair_commits(pair, qs)
    cfg = dict(index_state=a.index_state, first=first, second=second, index=pair.get("index"),
               doc_count=pair.get("doc_count"))
    if graph_commit:
        cfg["graph_commit"] = graph_commit
    return cfg


def cmd_run(a):
    luna = a.corpus == "luna"
    known = LUNA_ARMS if luna else ARMS + OPT_IN
    arms = [x for x in (a.arms or ",".join(LUNA_ARMS if luna else ARMS)).split(",") if x]
    for x in arms:
        if x not in known:
            raise Usage("unknown arm '%s' (known: %s)" % (x, ",".join(known)))
    if luna:
        luna_setup(a, arms)
    elif a.graph_out:
        raise Usage("--graph-out belongs to --corpus luna")
    if a.collection is None:
        a.collection = "luna" if luna else "himmel"
    skipped = skip_rtk(arms)
    for x, why in skipped.items():
        print("retrieval-eval: skipping %s: %s" % (x, why), file=sys.stderr)
    arms = [x for x in arms if x not in skipped]
    if not arms:
        raise Usage("no arm left to run")
    qs = load_questions(a.questions)
    for q in qs:
        if q.get("split", "insample") not in SPLITS:
            raise Usage("question %s has split '%s' (known: %s)" % (q.get("id"), q.get("split"), ",".join(SPLITS)))
    repo = os.path.abspath(a.repo)
    pair_cfg = pair_setup(a, arms, qs, repo)
    os.makedirs(a.out, exist_ok=True)
    need = list(arms)
    fusing = "fused-no-grep" if luna else "combined"
    if fusing in arms:
        need = [x for x in known if x in arms or x in FUSED_OF[fusing]]
    evidence_depth = max(a.k, 20)
    rows = []
    for q in qs:
        got = {}
        for arm in need:
            if arm in FUSED_OF:
                parts = [got[x] for x in FUSED_OF[arm]]
                files = fuse([p["files"] for p in parts], a.k)
                text = "\n".join(p["_text"] for p in parts)
                got[arm] = dict(files=files, _text=text, ms=sum(p["ms"] for p in parts),
                                timeout=any(p["timeout"] for p in parts), error=any(p["error"] for p in parts),
                                files_top20=fuse([p["files_top20"] for p in parts], 20),
                                qmd_error=next((p["qmd_error"] for p in parts if p["qmd_error"]), ""),
                                deep_failed=any(p["deep_failed"] for p in parts))
            else:
                t0 = time.time()
                files, text, to, err, qmd_error = run_arm(arm, q["q"], repo, a, a.k)
                ms = int((time.time() - t0) * 1000)
                top20, deep_failed = files, False
                if evidence_depth > a.k and not (to or err):
                    deep = run_arm(arm, q["q"], repo, a, evidence_depth)
                    if not (deep[2] or deep[3]):
                        top20 = deep[0][:evidence_depth]
                    else:
                        deep_failed = True
                got[arm] = dict(files=files, files_top20=top20, _text=text, ms=ms, timeout=bool(to), error=bool(err),
                                qmd_error=qmd_error, deep_failed=deep_failed)
        for arm in arms:
            g = got[arm]
            row = dict(id=q["id"], kind=q.get("kind"), src=q.get("src"), split=q.get("split", "insample"),
                       index_state=a.index_state or None, stale_stratum=q.get("stale_stratum"), stratum=stratum(q), arm=arm, files=g["files"], hit=is_hit(g["files"], q["gold"]),
                       hit_any=is_hit_any(g["files"], q), ndcg=ndcg(g["files"], q, a.k),
                       precision=precision(g["files"], q, a.k), rr=reciprocal_rank(g["files"], q, a.k),
                       gold_n=gold_found(g["files"], q, a.k)[0], ret_n=gold_found(g["files"], q, a.k)[1],
                       reason=carried(g["_text"], q.get("reason", [])),
                       tokens=tok(g["_text"]), ms=g["ms"], timeout=g["timeout"], error=g["error"],
                       files_top20=g["files_top20"], qmd_error=g["qmd_error"], deep_failed=g["deep_failed"], skipped=False)
            if luna:
                v = got["qmd-hybrid"] if arm == "fused-no-grep" else g
                row.update(corpus="luna", source=q.get("source"),
                           degraded=arm in ("qmd-hybrid", "fused-no-grep") and bool(v["error"] or v["timeout"] or v["qmd_error"]))
            rows.append(row)
        print("%s %s" % (q["id"], " ".join("%s=%s" % (r["arm"], int(r["hit"])) for r in rows[-len(arms):])),
              file=sys.stderr)
    with open(os.path.join(a.out, "results.jsonl"), "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    rk = "hit@%d" % a.k
    pk = "precision@%d" % a.k
    cols = ["arm", "n", rk, pk, "mrr", "gold_share", "reason_carried", "reason_n", "tokens_mean", "tokens_per_hit",
            "ms_median", "ms_total", "timeouts", "errors"]
    lines = ["\t".join(cols)]
    slice_cols = ["arm", "slice", "n", rk, "hit_any@%d" % a.k, "ndcg@%d" % a.k, "reason_carried", "reason_n"]
    slice_lines = ["\t".join(slice_cols)]
    mean = lambda xs: sum(xs) / len(xs) if xs else None  # noqa: E731
    metrics, cases = {}, {}
    for arm in arms:
        rs = [r for r in rows if r["arm"] == arm]
        rr = [r for r in rs if r["reason"] is not None]
        rec = sum(r["hit"] for r in rs) / len(rs) if rs else 0.0
        rea = sum(r["reason"] for r in rr) / len(rr) if rr else 0.0
        tk = statistics.mean(r["tokens"] for r in rs) if rs else 0
        prec = mean([r["precision"] for r in rs])
        mrr = mean([r["rr"] for r in rs])
        gs = sum(r["gold_n"] for r in rs) / sum(r["ret_n"] for r in rs) if sum(r["ret_n"] for r in rs) else None
        tph = sum(r["tokens"] for r in rs) / sum(r["hit"] for r in rs) if sum(r["hit"] for r in rs) else None
        dash = lambda v, f="%.2f": "-" if v is None else f % v  # noqa: E731
        msm = statistics.median(r["ms"] for r in rs) if rs else 0
        mst = sum(r["ms"] for r in rs)
        to = sum(r["timeout"] for r in rs)
        er = sum(r["error"] for r in rs)
        lines.append("\t".join([arm, str(len(rs)), "%.2f" % rec, dash(prec), dash(mrr), dash(gs), "%.2f" % rea,
                                str(len(rr)), "%d" % tk, dash(tph, "%.1f"), "%d" % msm, "%d" % mst, str(to), str(er)]))
        metrics.update({arm + "." + rk: rec, arm + "." + pk: prec, arm + ".mrr": mrr, arm + ".gold_share": gs,
                        arm + ".reason_carried": rea, arm + ".tokens_mean": tk, arm + ".tokens_per_hit": tph,
                        arm + ".ms_median": msm, arm + ".timeouts": to, arm + ".errors": er,
                        arm + ".deep_failures": sum(1 for r in rs if r.get("deep_failed"))})
        if luna:
            metrics[arm + ".degraded"] = sum(1 for r in rs if r["degraded"])
        slices = [(sl, lambda r, sl=sl: r["split"] == sl) for sl in SPLITS]
        slices += [(st, lambda r, st=st: r["stratum"] == st) for st in STRATA]
        slices += [("%s.%s" % (sl, st), lambda r, sl=sl, st=st: r["split"] == sl and r["stratum"] == st)
                   for sl in SPLITS for st in STRATA]
        for sl, pick in slices:
            sr = [r for r in rs if pick(r)]
            srr = [r for r in sr if r["reason"] is not None]
            vals = [mean([r["hit"] for r in sr]), mean([r["hit_any"] for r in sr]),
                    mean([r["ndcg"] for r in sr]), mean([r["reason"] for r in srr])]
            slice_lines.append("\t".join([arm, sl, str(len(sr))] + ["-" if v is None else "%.2f" % v for v in vals]
                                         + [str(len(srr))]))
            pre = "%s.%s." % (arm, sl)
            metrics.update({pre + "n": len(sr), pre + rk: vals[0], pre + "hit_any@%d" % a.k: vals[1],
                            pre + "ndcg@%d" % a.k: vals[2], pre + "reason_carried": vals[3]})
        for r in rs:
            cases.setdefault(r["id"], {})[arm + ".hit"] = r["hit"]
            cases[r["id"]]["heldout"] = r["split"] == "heldout"
    with open(os.path.join(a.out, "scores.tsv"), "w") as fh:
        fh.write("\n".join(lines) + "\n")
    with open(os.path.join(a.out, "scores-by-slice.tsv"), "w") as fh:
        fh.write("\n".join(slice_lines) + "\n")
    print("\n".join(lines))
    print()
    print("\n".join(slice_lines))
    with open(a.questions, "rb") as fh:
        qhash = hashlib.sha256(fh.read()).hexdigest()[:16]
    ident = forward_identity(a.questions, os.path.abspath(__file__))
    config = dict(arms=arms, k=a.k, evidence_depth=evidence_depth, timeout=a.timeout, collection=a.collection,
                  questions=qhash, identity_hash=ident["config_hash"])
    config.update(pair_cfg)
    if luna:
        config["corpus"] = "luna"
        n_deg = sum(1 for r in rows if r["degraded"])
        if n_deg:
            print("retrieval-eval: %d degraded rows (a vector leg failed): they cannot enter a ruling, re-run" % n_deg,
                  file=sys.stderr)
    if skipped:
        config["skipped"] = skipped
    held = sorted((q for q in qs if q.get("split") == "heldout"), key=lambda q: str(q["id"]))
    meta = dict(label=a.label, questions_path=os.path.abspath(a.questions), graph_built_at=None,
                n_heldout=len(held), identity=ident["identity"],
                heldout_sha256=hashlib.sha256(json.dumps(held, sort_keys=True).encode()).hexdigest()[:16])
    if luna and "graphify-ast" in need:
        try:
            meta["graph_built_at"] = stamp_of(os.path.join(a.graph_out, "graph.json"))
        except RuntimeError:
            pass
    elif "graphify" in arms or "combined" in arms:
        try:
            try:
                meta["graph_built_at"] = graph_built(repo)
                meta["graph_stamp_source"] = "graph"
            except NoStamp:
                if not pair_cfg.get("graph_commit"):
                    raise
                meta["graph_built_at"] = pair_cfg["graph_commit"]
                meta["graph_stamp_source"] = "pair.json"
        except (RuntimeError, OSError) as e:
            meta["graph_built_error"] = str(e)
            print("retrieval-eval: ERROR graph stamp: %s" % e, file=sys.stderr)
    row = eval_runs.make_row("retrieval-eval", "scripts/eval/retrieval-eval/retrieval-eval.py", config, metrics,
                             n=len(qs), cases=cases, artifact=os.path.abspath(a.out), meta=meta, repo=repo)
    retain_and_append(row, {"results": os.path.join(a.out, "results.jsonl"), "scores": os.path.join(a.out, "scores.tsv"),
                            "slices": os.path.join(a.out, "scores-by-slice.tsv"), "bank": a.questions}, who="retrieval-eval")
    return 1 if "graph_built_error" in meta else 0


def _pilot_tool(name):
    s = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HERE, "pilot", name + ".py"))
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


def forward_identity(questions, evaluator, root=None, shapers=None):
    """The canonical nonsecret run identity: bank, evaluator and pre-expansion shaper bytes, the
    harness commit and the dirty-content digest, so an uncommitted edit changes the hash at the
    same commit. No historical backfill: older rows simply lack it (comparability unknown)."""
    root = root or os.path.normpath(os.path.join(HERE, "..", "..", ".."))
    if shapers is None:
        shapers = [p for p in (os.path.join(root, "scripts", "qmd", "vocab-expand.py"),
                               os.path.join(root, "scripts", "lib", "rename-aliases.tsv")) if os.path.isfile(p)]
    return _pilot_tool("experiment-identity").build({"bank_sha256": questions, "evaluator_sha256": evaluator},
                                                    {"protocol": os.path.basename(evaluator)}, repo=root, shapers=shapers)


def retain_and_append(row, files, who):
    """Retain the run's artifacts content-addressed beside the ledger, then append the row; a
    retention failure writes no row (evidence first, public ledger second)."""
    root = os.path.join(os.path.dirname(os.path.abspath(eval_runs.ledger_path())), "eval-retained")
    try:
        m = _pilot_tool("retain-run").retain(root, row["run_id"], {k: p for k, p in files.items() if p and os.path.isfile(p)})
    except (OSError, ValueError) as e:
        print("%s: WARNING artifacts not retained (%s): no eval-runs row written" % (who, e), file=sys.stderr)
        return None
    row["meta"]["retained_manifest"] = m["run_id"]
    row["meta"]["retained_manifest_sha256"] = m["manifest_sha256"]
    return eval_runs.append_safe(row, who=who)


def graph_built(repo):
    seam = os.environ.get("WORKER_GRAPH_OUT")
    if seam:
        return stamp_of(os.path.join(seam, "graph.json"))
    try:
        r = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError("cannot resolve git common dir: %s" % e) from e
    common = r.stdout.strip()
    if r.returncode != 0 or not common:
        raise RuntimeError("cannot resolve git common dir for %s: %s" % (repo, r.stderr.strip()))
    return stamp_of(os.path.join(os.path.dirname(common), "graphify-out", "graph.json"))


class NoStamp(RuntimeError):
    pass


def stamp_of(path):
    stamp = re.compile(rb'"built_at_commit"\s*:\s*"([0-9a-fA-F]+)"')
    try:
        with open(path, "rb") as fh:
            boundary_tail = b""
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                data = boundary_tail + chunk
                m = stamp.search(data)
                if m:
                    return m.group(1).decode("ascii")
                boundary_tail = data[-256:]
    except OSError as e:
        raise RuntimeError("cannot read graph.json at %s: %s" % (path, e)) from e
    raise NoStamp("no built_at_commit stamp in %s" % path)


def cmd_replay(a):
    arms = list(dict.fromkeys(x.strip() for x in (a.arms + "," + a.add).split(",") if x.strip()))
    if not arms:
        raise Usage("--arms names no arm")
    if a.k < 1 or a.rrf_k < 0:
        raise Usage("--k must be positive and --rrf-k must be nonnegative")
    questions = {q["id"]: q for q in load_questions(a.questions)}
    try:
        with open(a.results) as fh:
            rows = [json.loads(line) for line in fh if line.strip()]
    except (OSError, ValueError) as e:
        raise Usage("cannot read saved results: %s" % e) from e
    by_id = {}
    for r in rows:
        by_id.setdefault(r["id"], {})[r["arm"]] = r
    scored = []
    for qid, saved in by_id.items():
        if qid not in questions:
            raise Usage("saved question is missing from the questions file")
        q = questions[qid]
        split = q.get("split", "insample")
        if split not in SPLITS:
            raise Usage("question has unknown split '%s'" % split)
        for arm in arms + ["combined"]:
            if arm not in saved:
                raise Usage("missing arm '%s' for a saved question" % arm)
        files = fuse([saved[arm]["files"] for arm in arms], a.k, a.rrf_k)
        scored.append((qid, split, bool(saved["combined"]["hit"]), is_hit(files, q["gold"]), stratum(q)))

    def counts(index, by_stratum=False):
        parts = []
        for name in STRATA if by_stratum else SPLITS + ("all",):
            rs = [r for r in scored if name == "all" or r[4 if by_stratum else 1] == name]
            parts.append("%s %d/%d" % (name, sum(r[index] for r in rs), len(rs)))
        return " ".join(parts)

    print("replay arms=%s rrf_k=%d k=%d" % (",".join(arms), a.rrf_k, a.k))
    print("saved combined: " + counts(2))
    print("replay combined: " + counts(3))
    print("saved combined by stratum: " + counts(2, True))
    print("replay combined by stratum: " + counts(3, True))
    same = arms == FUSED and a.rrf_k == 60 and sum(r[2] for r in scored) == sum(r[3] for r in scored)
    print("reproduces saved combined: %s" % ("yes" if same else "no"))

    def dev_ids(was_hit, now_hit):
        return [r[0] for r in scored if r[1] == "insample" and r[2] == was_hit and r[3] == now_hit]

    print("rescued (dev): " + (" ".join(dev_ids(False, True)) or "none"))
    print("regressed (dev): " + (" ".join(dev_ids(True, False)) or "none"))
    return 0


# ---- census -------------------------------------------------------------------

SWEEP = re.compile(r"(?:^|[;&|(\n]\s*)(?:git\s+grep\b|grep\s+-\w*[rR]|rg\s|find\s)")
QMD_BASH = re.compile(r"(?:qmd-bounded\.sh|(?:^|[;&|(\n]\s*)qmd)\s+(?:query|search|vsearch)\b")
GRAPH_BASH = re.compile(r"(?:(?:^|[;&|(\n]\s*)graphify|(?:leg|worker)-graph\.sh)\s+(?:query|explain)\b")
PATHS = re.compile(r"src=([^\s\]]+)|qmd://[^/\s]+/([^\"\s\]]+)|([\w./-]+\.(?:md|sh|py|js|mjs|ts|json))")
RESOURCE = re.compile(r"\[Resource from [^\]]*?qmd://[^/\s\]]+/([^\s\]]+)\]")
QMD_TOOL =re.compile(r"^mcp__(?:plugin_qmd_)?qmd__(?:query|get|multi_get)$")
FEATURE = re.compile(r"qmd|graphify|retrieval|graph-|semantic", re.I)


def role_of(title, path, side):
    t = (title or "").lower()
    if "judge" in t:
        return "judge"
    if "console" in t or "chief" in t:
        return "console"
    if "/subagents/" in path or side:
        return "subagent"
    if re.search(r"-n\d+\b|himmel-\d+", t):
        return "worker"
    return "interactive"


def session_calls(path):
    title, side, calls, res = None, False, [], {}
    with open(path, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            t = d.get("type")
            if t == "custom-title":
                title = d.get("customTitle")
            elif t == "agent-name" and not title:
                title = d.get("agentName")
            if d.get("isSidechain"):
                side = True
            m = d.get("message")
            c = m.get("content") if isinstance(m, dict) else None
            if not isinstance(c, list):
                continue
            for b in c:
                if not isinstance(b, dict):
                    continue
                if t == "assistant" and b.get("type") == "tool_use":
                    calls.append(dict(id=b.get("id"), name=b.get("name", ""), input=b.get("input") or {},
                                      ts=d.get("timestamp")))
                elif t == "user" and b.get("type") == "tool_result":
                    r = b.get("content")
                    if isinstance(r, list):
                        r = " ".join(x.get("text", "") for x in r if isinstance(x, dict))
                    res[b.get("tool_use_id")] = (str(r or ""), bool(b.get("is_error")))
    for cl in calls:
        cl["result"], cl["error"] = res.get(cl["id"], ("", False))
    return title, side, calls


def kind_of(cl):
    n, inp = cl["name"], cl["input"]
    if QMD_TOOL.match(n):
        return "qmd"
    if n in ("Grep", "Glob"):
        return "sweep"
    if n == "Bash":
        cmd = inp.get("command", "")
        if GRAPH_BASH.search(cmd):
            return "graphify"
        if QMD_BASH.search(cmd):
            return "qmd"
        if SWEEP.search(cmd):
            return "sweep"
    return None


def failed(cl):
    r = cl["result"].strip()
    if cl["error"] or not r:
        return True
    try:
        d = json.loads(r)
    except ValueError:
        return False
    return d in ([], {}) or (isinstance(d, dict) and d.get("results") == [])


def result_paths(cl):
    """Paths a retrieval call surfaced; a qmd path also counts without its leading collection name."""
    qmd = cl["name"].startswith("mcp__")
    if qmd and not cl["name"].endswith("__query"):
        # get/multi_get echo the document body, which names unrelated paths: the input and the
        # per-document "[Resource from ...]" headers (a glob pattern expands there) name the documents.
        inp = cl["input"]
        found = [x.strip() for x in str(inp.get("file") or inp.get("pattern") or "").split(",")]
        found += RESOURCE.findall(cl["result"])
    else:
        found = [next(g for g in m.groups() if g) for m in PATHS.finditer(cl["result"])]
    paths = set(found)
    if qmd:
        paths |= {p.partition("/")[2] for p in found}
    # ponytail: a path with no directory is dropped, so a root-level file never counts as used; keep it if a sample shows root files missed.
    return {p for p in paths if "/" in p.strip("/")}


def used(cl, later):
    paths = result_paths(cl)
    for nx in later:
        blob = json.dumps(nx["input"])
        if any(re.search(r"(?<![\w.-])" + re.escape(p) + r"(?![\w-])", blob) for p in paths):
            return True
    return False


def call_time(cl):
    """Epoch seconds of the call's timestamp, or None when it has none."""
    try:
        return datetime.datetime.fromisoformat(cl["ts"].replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def cmd_census(a):
    cut = time.time() - a.days * 86400 if a.days > 0 else 0
    files = glob.glob(os.path.join(a.projects, "*", "*.jsonl")) + \
        glob.glob(os.path.join(a.projects, "*", "*", "subagents", "*.jsonl"))
    keys = ["sessions", "sessions_with_retrieval", "qmd_calls", "qmd_failed", "qmd_used", "graphify_calls",
            "graphify_failed", "graphify_used", "sweeps", "fallback_after_miss"]
    roles, organic = {}, {}
    for f in files:
        try:
            if os.path.getmtime(f) < cut:
                continue
        except OSError:
            continue
        title, side, calls = session_calls(f)
        # The mtime check only skips whole files; a long session also holds older calls.
        calls = [cl for cl in calls if (call_time(cl) or cut) >= cut]
        role = role_of(title, f, side)
        for book, include in ((roles, True), (organic, not FEATURE.search(title or ""))):
            if not include:
                continue
            s = book.setdefault(role, dict.fromkeys(keys, 0))
            s["sessions"] += 1
            any_r = False
            for i, cl in enumerate(calls):
                k = kind_of(cl)
                if k == "sweep":
                    s["sweeps"] += 1
                elif k in ("qmd", "graphify"):
                    any_r = True
                    s[k + "_calls"] += 1
                    if failed(cl):
                        s[k + "_failed"] += 1
                        if any(kind_of(x) == "sweep" for x in calls[i + 1:i + 4]):
                            s["fallback_after_miss"] += 1
                    elif used(cl, calls[i + 1:i + 6]):
                        s[k + "_used"] += 1
            s["sessions_with_retrieval"] += int(any_r)
    out = dict(window_days=a.days, sessions_scanned=sum(v["sessions"] for v in roles.values()),
               roles=roles, organic=organic)
    with open(a.out, "w") as fh:
        json.dump(out, fh, indent=1)
    for name, book in (("all", roles), ("organic (titles without qmd/graphify/retrieval)", organic)):
        print("## " + name)
        print("\t".join(["role"] + keys))
        for r in sorted(book):
            print("\t".join([r] + [str(book[r][k]) for k in keys]))
    return 0


STALE_ORDER = ("added", "kept", "new", "control", "changed")
CONTRASTS = (("L-S", "s", "l"), ("C-L", "l", "c"))
DECIDES = {
    "C1 not run": "the keyword half stays off; the graph half is not affected; the free arm's number still meets the ticket's DoD",
    "Harm shown": "the keyword half stays off, or is disarmed, until D1 is re-ruled on slice 3 and log 2; daytime bare updates do the same harm",
    "L is already normal": "the keyword half arms: it adds a bound and little new harm",
    "The hole would be new": "the keyword half stays off until D1 is re-ruled on slice 3 and log 2",
    "Not shown": "the keyword half stays off; the baseline interval is printed above",
}


def mcnemar_p(b, c):
    return _pilot_tool("score").mcnemar(b, c)


def paired(rows, arm, stratum_name, base, other):
    by = {}
    for r in rows:
        if r["arm"] == arm and r.get("stale_stratum") == stratum_name:
            st = by.setdefault(r["id"], {})
            if r.get("index_state") in st:
                raise Usage("question %s has two %s rows for arm %s under '%s': a rerun's rows must not share a report directory"
                            % (r["id"], r.get("index_state"), arm, stratum_name))
            st[r.get("index_state")] = bool(r["hit"])
    diffs, bh, oh = [], 0, 0
    for st in by.values():
        if base in st and other in st:
            diffs.append(int(st[other]) - int(st[base]))
            bh += int(st[base])
            oh += int(st[other])
    return sorted(diffs), bh, oh


def baseline_interval():
    cmd = os.environ.get("RETRIEVAL_EVAL_LAG_CMD")
    argv = shlex.split(cmd) if cmd else ["python3", "-I", os.path.join(HERE, "..", "..", "luna", "keyword-lag.py"),
                                         "--report", "--days", "7"]
    out, to, rc = run_cmd(argv, 60)
    m = re.search(r"^headline: .*wilson95 ([0-9.]+) to ([0-9.]+)\s*$", out or "", re.M)
    if to or rc != 0 or not m:
        return None
    return float(m.group(1)), float(m.group(2)), "%s to %s" % (m.group(1), m.group(2))


def cmd_stale_report(a):
    files = sorted(glob.glob(os.path.join(a.dir, "**", "results.jsonl"), recursive=True))
    rows = []
    for f in files:
        with open(f) as fh:
            rows += [json.loads(line) for line in fh if line.strip()]
    rows = [r for r in rows if r.get("index_state")]
    if not rows:
        raise Usage("no results rows with an index_state under '%s'" % a.dir)
    arms = list(dict.fromkeys(r["arm"] for r in rows))
    names = {r.get("stale_stratum") for r in rows} - {None}
    strata = [x for x in STALE_ORDER if x in names] + sorted(names - set(STALE_ORDER))
    print("\t".join(["arm", "contrast", "stratum", "n", "base_hits", "other_hits", "diff_pts", "mcnemar_p",
                     "ci_lo_pts", "ci_hi_pts"]))
    cell = {}
    for arm in arms:
        for name, base, other in CONTRASTS:
            for sname in strata:
                diffs, bh, oh = paired(rows, arm, sname, base, other)
                if not diffs:
                    continue
                n, b, c = len(diffs), diffs.count(1), diffs.count(-1)
                p = mcnemar_p(b, c)
                ci = eval_runs.bootstrap_ci(diffs, b=10000, seed=9517)
                cell[(arm, name, sname)] = (n, (b - c) * 100.0 / n, p)
                print("\t".join([arm, name, sname, str(n), str(bh), str(oh), "%.1f" % ((b - c) * 100.0 / n), "%.4f" % p,
                                 "%.1f" % (ci["lo"] * 100) if ci else "n/a", "%.1f" % (ci["hi"] * 100) if ci else "n/a"]))
    c_run = any(r["arm"] == "qmd-hybrid" and r["index_state"] == "c" for r in rows)
    verdict = None
    if not c_run:
        verdict = "C1 not run"
    else:
        if ("qmd-hybrid", "L-S", "kept") not in cell:
            raise Usage("qmd-hybrid has no Kept comparison of states s and l: the decision needs both")
        if not any(k[0] == "qmd-hybrid" and k[1] == "C-L" for k in cell):
            raise Usage("qmd-hybrid has c-state rows but no C-L comparison of states l and c: the decision needs it")
        _, diff, p = cell[("qmd-hybrid", "L-S", "kept")]
        if diff < 0 and p < 0.05:
            verdict = "Harm shown"
        else:
            base = baseline_interval()
            if base is None:
                print("baseline pending")
            else:
                print("baseline: headline share, wilson95 %s" % base[2])
                verdict = "L is already normal" if base[0] >= 0.5 else "The hole would be new" if base[1] < 0.5 else "Not shown"
    if verdict:
        print("decides: %s | %s" % (verdict, DECIDES[verdict]))
    print("scope: this bank only" + ("; the graph arm measures the AST layer" if "graphify" in arms else ""))
    return 0


def repo_path(root, p):
    p = os.path.realpath(p)
    wt = os.path.join(root, ".claude", "worktrees") + os.sep
    if p.startswith(wt):
        return p[len(wt):].split(os.sep, 1)[1] if os.sep in p[len(wt):] else None
    if p.startswith(root + os.sep):
        return p[len(root) + 1:]
    return None


def cmd_exposure(a):
    root = os.path.realpath(subprocess.run(["git", "-C", a.repo, "rev-parse", "--show-toplevel"],
                                           capture_output=True, text=True, timeout=10).stdout.strip() or a.repo)
    common = subprocess.run(["git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                            capture_output=True, text=True, timeout=10).stdout.strip()
    primary = os.path.realpath(os.path.dirname(common)) if common else root
    now = time.time()
    cut = now - a.days * 86400
    log = subprocess.run(["git", "-C", root, "log", "--first-parent", "-m", "--name-only", "--format=%x01%ct",
                          "--since=%d" % (cut - 86400), a.ref], capture_output=True, text=True, timeout=120)
    if log.returncode != 0:
        raise Usage("git log %s failed in %s: %s" % (a.ref, root, log.stderr.strip()))
    merged, when = {}, None
    for line in log.stdout.splitlines():
        if line.startswith("\x01"):
            when = int(line[1:])
        elif line.strip() and when is not None:
            merged.setdefault(line.strip(), []).append(when)
    files = glob.glob(os.path.join(a.projects, "*", "*.jsonl")) + \
        glob.glob(os.path.join(a.projects, "*", "*", "subagents", "*.jsonl"))
    n = day = hour = 0
    for f in files:
        try:
            if os.path.getmtime(f) < cut:
                continue
        except OSError:
            continue
        for cl in session_calls(f)[2]:
            t = call_time(cl)
            fp = cl["input"].get("file_path") if cl["name"] == "Read" else None
            if t is None or t < cut or not fp:
                continue
            rel = repo_path(root, fp) or (repo_path(primary, fp) if primary != root else None)
            if rel is None:
                continue
            n += 1
            times = merged.get(rel, [])
            day += any(t - 86400 <= x <= t for x in times)
            hour += any(t - 3600 <= x <= t for x in times)
    print("reads: %d in the repo (%d d window, ref %s); reads outside it are not counted" % (n, a.days, a.ref))
    for label, k in (("24 h", day), ("1 h", hour)):
        w = wilson.wilson(k, n)
        print("prior %s: %d/%d = %s; wilson95 %s" % (label, k, n, "%.4f" % (k / n) if n else "n/a",
                                                    "%.4f to %.4f" % (w["lo"], w["hi"]) if w else "n/a"))
    return 0


LUNA_NOTE = re.compile(r"qmd://luna/([^\"\n\\\]]+?\.md)(?=[\"\s:#\]\\)]|$)")
SOURCES = ("qmd", "direct", "written")


def luna_reached(cl):
    """Vault-relative notes a qmd call surfaced from the luna collection."""
    if cl["name"].startswith("mcp__") and not cl["name"].endswith("__query"):
        # get and multi_get echo the document body, which can quote other paths: only the input names notes.
        text = " ".join(str(cl["input"].get(k) or "") for k in ("file", "pattern"))
    else:
        text = cl["result"]
    return set(LUNA_NOTE.findall(text))


def vault_note(vault, path):
    real, root = os.path.realpath(path), os.path.realpath(vault)
    if real.startswith(root + os.sep) and real.endswith(".md"):
        return real[len(root) + 1:]
    return None


def cmd_mine_luna(a):
    refuse_repo_path(a.out, a.repo, "--out")
    cut = time.time() - a.days * 86400
    files = glob.glob(os.path.join(a.projects, "*", "*.jsonl")) + \
        glob.glob(os.path.join(a.projects, "*", "*", "subagents", "*.jsonl"))
    found = {"qmd": {}, "direct": {}}
    for f in sorted(files):
        try:
            if os.path.getmtime(f) < cut:
                continue
        except OSError:
            continue
        here = {"qmd": set(), "direct": set()}
        reached = set()
        for cl in session_calls(f)[2]:
            if (call_time(cl) or cut) < cut:
                continue
            if kind_of(cl) == "qmd":
                if not failed(cl):
                    for p in luna_reached(cl):
                        reached.add(p.lower())
                        here["qmd"].add(p)
            elif cl["name"] == "Read" and not failed(cl):
                rel = vault_note(a.vault, cl["input"].get("file_path") or "")
                # An open by path ends every direct route (a grep hit, a wikilink): it counts unless a qmd call surfaced it first.
                if rel and rel.lower() not in reached:
                    here["direct"].add(rel)
        for src, paths in here.items():
            for p in paths:
                found[src][p] = found[src].get(p, 0) + 1
    data = "".join(json.dumps(dict(source=s, path=p, sessions=n), ensure_ascii=False) + "\n"
                   for s in ("qmd", "direct") for p, n in sorted(found[s].items()))
    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    with open(a.out, "w") as fh:
        fh.write(data)
    print("qmd: %d" % len(found["qmd"]))
    print("direct: %d" % len(found["direct"]))
    print("written: 0 (a worker writes these by hand and checks every row)")
    print("sha256: %s" % hashlib.sha256(data.encode()).hexdigest()[:16])
    return 0


RULINGS = {
    "Both": "both (qmd + rerank fused with the AST route, no grep) is the route proposed, and the luna AST job is re-armed",
    "AST": "the AST route on, per decision 449's graph-beats-qmd bar; AST is preferred to both unless both is clearly better",
    "qmd + rerank only": "qmd + rerank only; luna AST stays off, and it costs nothing",
}


def cmd_vault_report(a):
    refuse_repo_path(a.dir, a.repo, "vault-report directory")
    rows = []
    for f in sorted(glob.glob(os.path.join(a.dir, "**", "results.jsonl"), recursive=True)):
        with open(f) as fh:
            rows += [json.loads(line) for line in fh if line.strip()]
    rows = [r for r in rows if r.get("corpus") == "luna"]
    if not rows:
        raise Usage("no luna results rows under '%s'" % a.dir)
    by = {}
    for r in rows:
        if r["id"] in by.setdefault(r["arm"], {}):
            raise Usage("question %s has two rows for arm %s: a rerun's rows must not share a report directory" % (r["id"], r["arm"]))
        by[r["arm"]][r["id"]] = r
    mean = lambda xs: sum(xs) / len(xs) if xs else 0.0  # noqa: E731
    print("\t".join(["source", "arm", "n", "hit", "mrr", "ms_median", "tokens_mean"]))
    names = {r.get("source") or "-" for r in rows}
    for src in [s for s in SOURCES if s in names] + sorted(names - set(SOURCES)):
        for arm in by:
            rs = [r for r in by[arm].values() if (r.get("source") or "-") == src]
            if rs:
                print("\t".join([src, arm, str(len(rs)), "%.2f" % mean([int(r["hit"]) for r in rs]),
                                 "%.2f" % mean([r["rr"] for r in rs]), "%d" % statistics.median(r["ms"] for r in rs),
                                 "%d" % mean([r["tokens"] for r in rs])]))
    deg = sum(1 for r in rows if r.get("degraded"))
    if deg:
        print("ruling: not eligible | %d degraded row%s: a run with skipped vectors does not count, re-run"
              % (deg, "" if deg == 1 else "s"))
        return 0
    missing = [x for x in ("qmd-hybrid", "graphify-ast", "fused-no-grep") if x not in by]
    if missing:
        print("ruling: not eligible | no rows for %s" % ", ".join(missing))
        return 0
    if len({frozenset(by[x]) for x in ("qmd-hybrid", "graphify-ast", "fused-no-grep")}) != 1:
        print("ruling: not eligible | the three arms did not answer the same questions: re-run")
        return 0
    base, cands = by["qmd-hybrid"], {}
    for name in ("graphify-ast", "fused-no-grep"):
        ids = sorted(set(base) & set(by[name]))
        b = sum(1 for i in ids if by[name][i]["hit"] and not base[i]["hit"])
        c = sum(1 for i in ids if base[i]["hit"] and not by[name][i]["hit"])
        cands[name] = dict(gain=(b - c) * 100.0 / len(ids) if ids else 0.0, p=mcnemar_p(b, c),
                           tokens=mean([r["tokens"] for r in by[name].values()]))
        print("%s vs qmd-hybrid: n=%d flips +%d/-%d gain %.1f pts mcnemar_p %.4f tokens_mean %d (ceiling %d)"
              % (name, len(ids), b, c, cands[name]["gain"], cands[name]["p"], cands[name]["tokens"], a.token_ceiling))
    alive, passes = True, {}
    for step, name in enumerate(sorted(cands, key=lambda k: cands[k]["p"])):
        alive = alive and cands[name]["p"] <= 0.05 / (2 - step)
        passes[name] = alive and cands[name]["gain"] > 0 and cands[name]["tokens"] <= a.token_ceiling
    ast, both = cands["graphify-ast"], cands["fused-no-grep"]
    if passes["fused-no-grep"] and both["gain"] >= 10 and both["gain"] - ast["gain"] >= 10:
        verdict = "Both"
    elif passes["graphify-ast"] and ast["gain"] >= 10:
        verdict = "AST"
    else:
        verdict = "qmd + rerank only"
    print("ruling: %s | %s" % (verdict, RULINGS[verdict]))
    print("scope: this bank only; the operator rules")
    return 0


def main(argv=None):
    p = Parser(prog="retrieval-eval.py")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("run")
    r.add_argument("--questions", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--repo", default=".")
    r.add_argument("--arms", default=None)
    r.add_argument("--k", type=int, default=5)
    r.add_argument("--timeout", type=float, default=60)
    r.add_argument("--collection", default=None)
    r.add_argument("--label", default="")
    r.add_argument("--index-state", default="")
    r.add_argument("--pair", default="")
    r.add_argument("--corpus", choices=("himmel", "luna"), default="himmel")
    r.add_argument("--graph-out", default="")
    ml = sub.add_parser("mine-luna")
    ml.add_argument("--out", required=True)
    ml.add_argument("--vault", required=True)
    ml.add_argument("--days", type=int, default=30)
    ml.add_argument("--repo", default=".")
    ml.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    vr = sub.add_parser("vault-report")
    vr.add_argument("dir")
    vr.add_argument("--repo", default=".")
    vr.add_argument("--token-ceiling", type=int, default=TOKEN_CEILING)
    sr = sub.add_parser("stale-report")
    sr.add_argument("dir")
    ex = sub.add_parser("exposure")
    ex.add_argument("--days", type=int, default=14)
    ex.add_argument("--repo", default=".")
    ex.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    ex.add_argument("--ref", default="main")
    c = sub.add_parser("check")
    c.add_argument("--questions", required=True)
    c.add_argument("--repo", default=".")
    s = sub.add_parser("census")
    s.add_argument("--out", required=True)
    s.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    s.add_argument("--days", type=int, default=7)
    rp = sub.add_parser("replay")
    rp.add_argument("--results", required=True)
    rp.add_argument("--questions", default=os.path.join(HERE, "questions.jsonl"))
    rp.add_argument("--arms", default=",".join(FUSED))
    rp.add_argument("--rrf-k", type=int, default=60)
    rp.add_argument("--k", type=int, default=5)
    rp.add_argument("--add", default="")
    for sp in (r, sr, ex, c, s, rp, ml, vr):
        sp.error = p.error
    try:
        a = p.parse_args(argv)
        if a.cmd == "run":
            return cmd_run(a)
        if a.cmd == "stale-report":
            return cmd_stale_report(a)
        if a.cmd == "exposure":
            return cmd_exposure(a)
        if a.cmd == "mine-luna":
            return cmd_mine_luna(a)
        if a.cmd == "vault-report":
            return cmd_vault_report(a)
        if a.cmd == "check":
            return cmd_check(a)
        if a.cmd == "census":
            return cmd_census(a)
        if a.cmd == "replay":
            return cmd_replay(a)
        raise Usage("name a subcommand: run, check, census, replay, stale-report, exposure, mine-luna or vault-report")
    except Refuse as e:
        print("retrieval-eval: refused: %s" % e, file=sys.stderr)
        return 2
    except Usage as e:
        print("retrieval-eval: %s" % e, file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
