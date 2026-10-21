#!/usr/bin/env python3
"""scripts/eval/retrieval-eval/retrieval-eval.py - retrieval eval + usage census (HIMMEL-6143).

Asks the same questions of seven retrieval arms and scores each against a gold
file set, then counts how sessions really use qmd and graphify.

  run     --questions Q --out DIR [--repo R] [--arms A,B] [--k 5] [--timeout 60]
          [--collection himmel] [--label L]
  check   --questions Q [--repo R]           validate a question set, print its size
  census  --out FILE [--projects DIR] [--days 7]

Arms (all read-only):
  grep        git grep over the repo's tracked files for the question's words,
              files ranked by distinct words matched; shows <=8 lines per file
  path        the tracked file paths, ranked by distinct question words in the path
              (a filename-only baseline)
  ident-grep  git grep -w for the question's identifier-shaped tokens (snake_case,
              kebab-case, camelCase, file.ext); files holding a definition line
              rank first
  qmd-lex     qmd BM25 (lex search), rerank off
  qmd-hybrid  qmd lex + vec with rerank true, sent explicitly (the server default is off)
  qmd-hybrid-norerank  the same lex + vec searches with rerank off; opt-in via
              --arms, not in the default seven and not fused into combined
  graphify    scripts/graphify/leg-graph.sh query (the primary checkout's graph)
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
scripts/eval/README.md). Exit: 0 scored, 1 check found problems, 64 usage error.
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
import signal
import statistics
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

SPLITS = ("insample", "heldout")
ARMS = ["grep", "path", "ident-grep", "qmd-lex", "qmd-hybrid", "graphify", "combined"]
FUSED = ["grep", "qmd-hybrid", "graphify"]
OPT_IN = ["qmd-hybrid-norerank"]
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
    for w in words(q):  # leg_tail_status names leg-tail-status.sh: match its parts
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
    with urllib.request.urlopen(req, timeout=timeout) as r:
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


def qmd_server(args, timeout):
    """One MCP query against the qmd server -> list of {file, snippet}. The whole exchange shares one deadline."""
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
                             "params": {"name": "query", "arguments": args}}, h, left())
    return mcp_rows(msg)


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
    args = {"searches": [{"type": "lex", "query": q}] + ([{"type": "vec", "query": q}] if hybrid else []),
            "collections": [collection], "limit": k, "intent": q}
    args["rerank"] = hybrid and rerank
    cmd = os.environ.get("RETRIEVAL_EVAL_QMD_CMD")
    if cmd:
        out, to, rc = run_cmd(shlex.split(cmd), timeout, stdin=json.dumps(args))
        if to:
            return [], "", True, False
        if rc != 0:
            return [], "", False, True
        try:
            rows = json.loads(out or "[]")
        except ValueError:
            return [], "", False, True
    else:
        try:
            rows = qmd_server(args, timeout)
        except Exception as e:  # a timeout or a dead server is a scored miss, not a crash
            to = "timed out" in str(e).lower() or isinstance(e, TimeoutError)
            return [], "", to, not to
    files, text = [], []
    for r in rows:
        f = re.sub(r"^(?:qmd://[^/]+|%s)/" % re.escape(collection), "", str(r.get("file", "")))
        if f and f not in files:
            files.append(f)
        text.append("%s %s %s" % (r.get("file", ""), r.get("title", ""), r.get("snippet", "")))
    return files[:k], "\n".join(text), False, False


def arm_graphify(q, repo, timeout, k):
    cmd = os.environ.get("RETRIEVAL_EVAL_GRAPH_CMD")
    argv = shlex.split(cmd) if cmd else ["bash", os.path.join(repo, "scripts", "graphify", "leg-graph.sh")]
    out, to, rc = run_cmd(argv + ["query", q], timeout, cwd=repo)
    files = []
    for f in re.findall(r"\[src=([^\s\]]+)", out):
        if f not in files:
            files.append(f)
    return files[:k], out, to, not to and rc != 0


def fuse(lists, k):
    """Reciprocal-rank fusion; qmd lowercases its paths, so the key is the lowercased path."""
    s, name = {}, {}
    for lst in lists:
        for i, f in enumerate(lst):
            key = f.lower()
            name.setdefault(key, f)
            s[key] = s.get(key, 0.0) + 1.0 / (60 + i + 1)
    return [name[x] for x in sorted(s, key=lambda x: (-s[x], x))[:k]]


def is_hit(files, gold):
    """qmd lowercases its paths, so compare case-insensitively."""
    fl, gl = [f.lower() for f in files], [g.lower() for g in gold]
    return any(f == g or f.endswith("/" + g) for f in fl for g in gl)


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


def cmd_run(a):
    arms = [x for x in a.arms.split(",") if x]
    for x in arms:
        if x not in ARMS + OPT_IN:
            raise Usage("unknown arm '%s' (known: %s)" % (x, ",".join(ARMS + OPT_IN)))
    qs = load_questions(a.questions)
    for q in qs:
        if q.get("split", "insample") not in SPLITS:
            raise Usage("question %s has split '%s' (known: %s)" % (q.get("id"), q.get("split"), ",".join(SPLITS)))
    repo = os.path.abspath(a.repo)
    os.makedirs(a.out, exist_ok=True)
    need = list(arms)
    if "combined" in arms:
        need = [x for x in ARMS + OPT_IN if x in arms or x in FUSED]
    rows = []
    for q in qs:
        got = {}
        for arm in need:
            if arm == "combined":
                parts = [got[x] for x in FUSED]
                files = fuse([p["files"] for p in parts], a.k)
                text = "\n".join(p["_text"] for p in parts)
                got[arm] = dict(files=files, _text=text, ms=sum(p["ms"] for p in parts),
                                timeout=any(p["timeout"] for p in parts), error=any(p["error"] for p in parts))
            else:
                t0 = time.time()
                if arm == "grep":
                    files, text, to, err = arm_grep(q["q"], repo, a.timeout, a.k)
                elif arm == "path":
                    files, text, to, err = arm_path(q["q"], repo, a.timeout, a.k)
                elif arm == "ident-grep":
                    files, text, to, err = arm_ident_grep(q["q"], repo, a.timeout, a.k)
                elif arm == "graphify":
                    files, text, to, err = arm_graphify(q["q"], repo, a.timeout, a.k)
                else:
                    files, text, to, err = arm_qmd(q["q"], arm != "qmd-lex", a.timeout, a.k, a.collection,
                                                   arm != "qmd-hybrid-norerank")
                got[arm] = dict(files=files, _text=text, ms=int((time.time() - t0) * 1000), timeout=bool(to),
                                error=bool(err))
        for arm in arms:
            g = got[arm]
            row = dict(id=q["id"], kind=q.get("kind"), src=q.get("src"), split=q.get("split", "insample"),
                       arm=arm, files=g["files"], hit=is_hit(g["files"], q["gold"]),
                       hit_any=is_hit_any(g["files"], q), ndcg=ndcg(g["files"], q, a.k),
                       precision=precision(g["files"], q, a.k), rr=reciprocal_rank(g["files"], q, a.k),
                       gold_n=gold_found(g["files"], q, a.k)[0], ret_n=gold_found(g["files"], q, a.k)[1],
                       reason=carried(g["_text"], q.get("reason", [])),
                       tokens=tok(g["_text"]), ms=g["ms"], timeout=g["timeout"], error=g["error"])
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
                        arm + ".ms_median": msm, arm + ".timeouts": to, arm + ".errors": er})
        for sl in SPLITS:
            sr = [r for r in rs if r["split"] == sl]
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
    config = dict(arms=arms, k=a.k, timeout=a.timeout, collection=a.collection, questions=qhash)
    held = sorted((q for q in qs if q.get("split") == "heldout"), key=lambda q: str(q["id"]))
    meta = dict(label=a.label, questions_path=os.path.abspath(a.questions), graph_built_at=graph_built(repo),
                n_heldout=len(held),
                heldout_sha256=hashlib.sha256(json.dumps(held, sort_keys=True).encode()).hexdigest()[:16])
    row = eval_runs.make_row("retrieval-eval", "scripts/eval/retrieval-eval/retrieval-eval.py", config, metrics,
                             n=len(qs), cases=cases, artifact=os.path.abspath(a.out), meta=meta, repo=repo)
    eval_runs.append_safe(row, who="retrieval-eval")
    return 0


def graph_built(repo):
    try:
        common = subprocess.run(["git", "-C", repo, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=10).stdout.strip()
        with open(os.path.join(os.path.dirname(common), "graphify-out", "graph.json")) as fh:
            m = re.search(r'"built_at_commit":\s*"([0-9a-f]*)"', fh.read(4096))
        return m.group(1) if m else None
    except (OSError, subprocess.TimeoutExpired):
        return None


# ---- census -------------------------------------------------------------------

SWEEP = re.compile(r"(?:^|[;&|(\n]\s*)(?:git\s+grep\b|grep\s+-\w*[rR]|rg\s|find\s)")
QMD_BASH = re.compile(r"(?:qmd-bounded\.sh|(?:^|[;&|(\n]\s*)qmd)\s+(?:query|search|vsearch)\b")
GRAPH_BASH = re.compile(r"(?:(?:^|[;&|(\n]\s*)graphify|leg-graph\.sh)\s+(?:query|explain)\b")
PATHS = re.compile(r"src=([^\s\]]+)|qmd://[^/\s]+/([^\"\s\]]+)|([\w./-]+\.(?:md|sh|py|js|mjs|ts|json))")
QMD_TOOL = re.compile(r"^mcp__(?:plugin_qmd_)?qmd__(?:query|get|multi_get)$")
FEATURE = re.compile(r"qmd|graphify|retrieval|graph-|semantic", re.I)


def role_of(title, path, side):
    t = (title or "").lower()
    if "judge" in t:
        return "judge"
    if "console" in t:
        return "console"
    if "/subagents/" in path or side:
        return "subagent"
    if re.search(r"-n\d+\b|himmel-\d+", t):
        return "leg"
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
    return cl["error"] or not r or r in ("[]", "{}", '{"results":[]}')


def result_paths(cl):
    """Paths a retrieval call surfaced; a qmd path also counts without its leading collection name."""
    qmd = cl["name"].startswith("mcp__")
    if qmd and not cl["name"].endswith("__query"):
        # get/multi_get echo the document body, which names unrelated paths: the input names the documents.
        inp = cl["input"]
        found = [x.strip() for x in str(inp.get("file") or inp.get("pattern") or "").split(",")]
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


def main(argv=None):
    p = Parser(prog="retrieval-eval.py")
    sub = p.add_subparsers(dest="cmd")
    r = sub.add_parser("run")
    r.add_argument("--questions", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--repo", default=".")
    r.add_argument("--arms", default=",".join(ARMS))
    r.add_argument("--k", type=int, default=5)
    r.add_argument("--timeout", type=float, default=60)
    r.add_argument("--collection", default="himmel")
    r.add_argument("--label", default="")
    c = sub.add_parser("check")
    c.add_argument("--questions", required=True)
    c.add_argument("--repo", default=".")
    s = sub.add_parser("census")
    s.add_argument("--out", required=True)
    s.add_argument("--projects", default=os.path.join(os.path.expanduser("~"), ".claude", "projects"))
    s.add_argument("--days", type=int, default=7)
    for sp in (r, c, s):
        sp.error = p.error
    try:
        a = p.parse_args(argv)
        if a.cmd == "run":
            return cmd_run(a)
        if a.cmd == "check":
            return cmd_check(a)
        if a.cmd == "census":
            return cmd_census(a)
        raise Usage("name a subcommand: run, check or census")
    except Usage as e:
        print("retrieval-eval: %s" % e, file=sys.stderr)
        return 64


if __name__ == "__main__":
    sys.exit(main())
