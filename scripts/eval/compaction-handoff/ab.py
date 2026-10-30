#!/usr/bin/env python3
"""scripts/eval/compaction-handoff/ab.py - the phase 2 bounded A/B of the 200k compaction loop
against a 450k ceiling with a succession hand-off.

  ab.py run   --task T --arm a|b|c --rep N --out DIR [--model M] [--effort E] [--max-usd X]
              [--timeout S] [--seed N] [--scale F]       one cell: build, run, check, summarize
  ab.py sweep --out DIR --ceiling COST_EQ [--tasks docs,impl,audit] [--arms a,b,c] [--reps N]
              [--scales docs=1,impl=0.8] [--rerun-invalid] ...   cells in order, resumable, bank-preflighted
  ab.py judge --out DIR --ceiling COST_EQ [--model opus]  a blind judge score per run (judge.json),
                                                          bank-preflighted, counted against the ceiling
  ab.py score --out DIR [--json]                          the table and a recommendation per profile

Arms (all on a scratch copy of a generated workspace, the Agent tool denied):
  a  --autocompact 200000, compaction only (what a worker is launched with today)
  b  --autocompact 450000 plus a hand-off: the driver stops the session once its context passes
     75 % of the ceiling (337500), resumes it to write HANDOFF.md, and starts a fresh session whose
     only prompt is "Load HANDOFF.md and continue" (--context-guard handoff, done from outside)
  c  --autocompact 450000, compaction only

A run is VALID only if it reached its trigger, counted from the stream-json: a needs a
compact_boundary, c needs a compact_boundary, b needs a hand-off with HANDOFF.md written and a
fresh session after it. A run that errored or ended early is INVALID: summarized, priced,
never scored. cost_eq = input + 1.25 x cache-write + 0.1 x cache-read + 5 x output, rows deduped
by message id, plus each compaction estimated as pre_tokens read from cache and a 5000-token summary
(the compaction call is not in the stream).

ponytail: one rep per cell is a noisy sample and the defect classifier is the Phase 1 heuristic;
upgrade path = --reps 3 once the weekly budget allows, and a judge pass over sampled windows.

Env (test seams): AB_CLAUDE (default claude), AB_PREFLIGHT (default scripts/lib/usage-preflight.sh).
Billed: run, sweep and judge make real model calls and need HIMMEL_BILLED_OK=1.
Exit: 0 done; 2 usage; 3 stopped (bank refusal or the ceiling).
"""
import argparse
import glob
import importlib.util
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid

# billed-opt-in: HIMMEL_BILLED_OK
HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.realpath(os.path.join(HERE, "..", "..", ".."))
W_IN, W_CC, W_CR, W_OUT = 1.0, 1.25, 0.1, 5.0
CEIL = {"a": 200000, "b": 450000, "c": 450000}
HANDOFF_SHARE = 0.75
# --autocompact N fires below N: measured on a real arm a run, three autocompacts at 170369, 167937 and 164367
# tokens for N=200000 (0.82-0.85 of N). A compaction counts as the real trigger from 0.75 of N upward.
FIRE_MIN = 0.75
MAX_HANDOFFS = 3
SUMMARY_TOKENS = 5000
USD_PER_EQ = 3e-6   # sonnet input $3 per Mtok: prices a stopped segment, which has no result event to read a cost from
MIN_SEGMENT_USD = 1.0   # a hand-off segment is not launched with less of the run's cap than this
HANDOFF_PROMPT = ("Your context is nearly full and this session ends here. Write HANDOFF.md in the current directory so a fresh "
                  "session can finish the task without this conversation: the task as you were given it, every ruling and token "
                  "verbatim, what is done, what is left, and anything half-finished. Then stop.")
SUCCESSOR_PROMPT = "Load HANDOFF.md and continue the task from it. Finish with one line: DONE."
DENY = ["Agent", "WebFetch", "WebSearch", "Bash(gh:*)", "Bash(curl:*)", "Bash(wget:*)", "Bash(git push:*)"]


def _load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tasks = _load("ab_tasks", "ab_tasks.py")
defects = _load("compaction_defects", "compaction-defects.py")


def die(msg, code=2):
    print("ab.py: " + msg, file=sys.stderr)
    sys.exit(code)


def need_billed():
    if os.environ.get("HIMMEL_BILLED_OK") != "1":
        die("makes real, billed model calls; set HIMMEL_BILLED_OK=1 (on-demand only)")


def claude_bin():
    return os.environ.get("AB_CLAUDE", "claude")


# ------------------------------------------------------------------ stream parsing
def read_events(path):
    out = []
    try:
        with open(path, errors="replace") as fh:
            for line in fh:
                try:
                    out.append(json.loads(line))
                except ValueError:
                    continue
    except OSError:
        pass
    return out


def usage_cost(u):
    return (u.get("input_tokens", 0) * W_IN + u.get("cache_creation_input_tokens", 0) * W_CC
            + u.get("cache_read_input_tokens", 0) * W_CR + u.get("output_tokens", 0) * W_OUT)


def ctx_of(ev):
    """Context size of one assistant event: every input token the call saw."""
    if ev.get("type") != "assistant":
        return None
    u = (ev.get("message") or {}).get("usage") or {}
    return (u.get("input_tokens") or 0) + (u.get("cache_read_input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0)


def boundary_pre(ev):
    if ev.get("type") == "system" and ev.get("subtype") == "compact_boundary":
        m = ev.get("compact_metadata") or ev.get("compactMetadata") or {}
        return m.get("pre_tokens") or m.get("preTokens") or 0
    return None


def summarize_streams(paths, ceiling):
    msgs, order, pres, results, ctxs = {}, [], [], [], []
    for p in paths:
        prev = None
        for ev in read_events(p):
            pre = boundary_pre(ev)
            if pre is not None:
                pres.append(pre)
            c = ctx_of(ev)
            if c is not None:
                mid = (ev.get("message") or {}).get("id") or "row-%d" % len(order)
                if mid not in msgs:
                    order.append(mid)
                msgs[mid] = (ev["message"].get("usage") or {})
                ctxs.append(c)
                prev = c
            if ev.get("type") == "result":
                results.append(ev)
    drops = 0
    for i in range(1, len(ctxs)):
        if ctxs[i] < 0.5 * ctxs[i - 1] and ctxs[i - 1] > 0.5 * ceiling:
            drops += 1
    comp = len(pres)
    cost = sum(usage_cost(u) for u in msgs.values()) + sum(p * W_CR + SUMMARY_TOKENS * W_OUT for p in pres)
    last = results[-1] if results else None
    return {"cost_eq": round(cost), "turns": len(order), "compactions": comp, "compaction_pre": pres,
            "context_drops": drops, "peak_ctx": max(ctxs) if ctxs else 0,
            "cost_usd": round(sum(r.get("total_cost_usd") or 0 for r in results), 4) if results else None,
            "result_ok": bool(last) and not last.get("is_error") and last.get("subtype") in (None, "success"),
            "reply": (last or {}).get("result") or ""}


def defect_counts(paths):
    """Phase 1 classifier over the run: a window after every compaction and after every hand-off."""
    turns, starts = [], []
    for p in paths:
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as tmp:
            for ev in read_events(p):
                pre = boundary_pre(ev)
                if pre is not None:
                    ev = dict(ev, compactMetadata={"trigger": "auto", "preTokens": pre})
                tmp.write(json.dumps(ev) + "\n")
        try:
            _, t, bounds = defects.load(tmp.name)
        finally:
            os.unlink(tmp.name)
        if turns:
            starts.append(len(turns))
        starts += [len(turns) + b["turn"] for b in bounds]
        turns += t
    starts = sorted(set(s for s in starts if 0 < s < len(turns)))
    total = {c: 0 for c in defects.CLASSES}
    for k, lo in enumerate(starts):
        hi = min(lo + 40, starts[k + 1] if k + 1 < len(starts) else len(turns))
        d = defects.score(turns, lo, hi, False)[0]
        for c in total:
            v = d.get(c, 0) if isinstance(d, dict) else 0
            total[c] += len(v) if isinstance(v, list) else (v or 0)
    return total


# ------------------------------------------------------------------ one run
def build_cmd(prompt, model, effort, ceiling, max_usd, session=None, resume=None):
    c = [claude_bin(), "-p", prompt, "--model", model, "--effort", effort, "--autocompact", str(ceiling),
         "--permission-mode", "acceptEdits", "--output-format", "stream-json", "--verbose",
         "--max-budget-usd", str(max_usd), "--setting-sources", "user", "--strict-mcp-config",
         "--allowedTools", "Read", "Edit", "Write", "Bash", "Grep", "Glob", "--disallowedTools"] + DENY
    return c + (["--resume", resume] if resume else ["--session-id", session])


def run_segment(argv, cwd, stream, timeout, stop_at=None, stdin_text=None):
    """Run one claude process, teeing its stream to `stream`. With stop_at, stop it (SIGTERM) the
    moment an assistant message shows a context at or past it. -> (stopped, timed_out, wall_s)."""
    env = dict(os.environ)
    env.pop("CLAUDE_CODE_AUTO_COMPACT_WINDOW", None)   # outranks --autocompact
    t0, stopped, timed = time.time(), False, []
    # eval run in a scratch workspace, explicit permission mode, budget-capped; `sweep` bank-preflights per task, `run` does not
    # launch-profile-ok: the eval measures the 200k and 450k launch ceilings themselves, not a worker profile
    with open(stream, "w") as out, open(stream[:-len(".stream.jsonl")] + ".stderr", "w") as err:
        p = subprocess.Popen(argv, cwd=cwd, stdout=subprocess.PIPE, stderr=err, text=True, env=env,
                             stdin=subprocess.PIPE if stdin_text is not None else None)
        if stdin_text is not None:   # a prompt past ~128 KiB does not fit one argv entry
            p.stdin.write(stdin_text)
            p.stdin.close()
        timer = threading.Timer(timeout, lambda: (timed.append(1), p.kill()))
        timer.start()
        try:
            for line in p.stdout:
                out.write(line)
                out.flush()
                if stop_at:
                    try:
                        c = ctx_of(json.loads(line))
                    except ValueError:
                        c = None
                    if c is not None and c >= stop_at:
                        stopped = True
                        p.terminate()
                        break
        finally:
            timer.cancel()
            try:
                p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                p.kill()
                p.wait()
    return stopped, bool(timed), round(time.time() - t0)


def run_cell(task, arm, rep, out, model="sonnet", effort="high", max_usd=20, timeout=5400, seed=1, scale=1.0):
    rd = os.path.join(out, task, arm, str(rep))
    ws = os.path.join(rd, "ws")
    if os.path.exists(os.path.join(rd, "summary.json")):   # replacing a priced run would drop its spend from the ceiling total
        print("ab.py: %s already holds a priced run - use a new --out, or sweep --rerun-invalid" % rd, file=sys.stderr)
        sys.exit(2)
    shutil.rmtree(rd, ignore_errors=True)
    os.makedirs(rd)
    tasks.gen(task, ws, seed, scale)
    # no git repo here: the user-scope edit-on-main hook refuses every Edit inside a primary checkout
    shutil.copytree(ws, os.path.join(rd, "base"))
    brief = tasks.brief(task, seed, scale)
    with open(os.path.join(rd, "brief.txt"), "w") as fh:
        fh.write(brief)
    ceiling = CEIL[arm]
    stop_at = int(ceiling * HANDOFF_SHARE) if arm == "b" else None
    segs, wall, handoffs, timed_out, reason = [], 0, 0, False, None
    sid = str(uuid.uuid4())

    def seg(argv, stop=None):
        path = os.path.join(rd, "seg%d.stream.jsonl" % (len(segs) + 1))
        segs.append(path)
        return run_segment(argv, ws, path, timeout, stop)

    def left():   # what the run's cap has not yet spent, so every segment shares one max_usd
        return round(max_usd - summarize_streams(segs, ceiling)["cost_eq"] * USD_PER_EQ, 2)

    stopped, timed, w = seg(build_cmd(brief, model, effort, ceiling, max_usd, session=sid), stop_at)
    wall += w
    timed_out |= timed
    handoff_md = os.path.join(ws, "HANDOFF.md")
    while stopped and handoffs < MAX_HANDOFFS and not timed_out:
        if left() < MIN_SEGMENT_USD:
            reason = "budget"
            break
        handoffs += 1
        if os.path.exists(handoff_md):   # a stale file from an earlier hand-off must not pass for this one
            os.remove(handoff_md)
        _, timed, w = seg(build_cmd(HANDOFF_PROMPT, model, effort, ceiling, left(), resume=sid))
        wall += w
        timed_out |= timed
        if not summarize_streams(segs[-1:], ceiling)["result_ok"] and not timed_out:
            reason = "handoff-error"
            break
        if not os.path.exists(handoff_md):
            reason = "handoff-missing"
            break
        shutil.copy(handoff_md, os.path.join(rd, "handoff-%d.md" % handoffs))
        if left() < MIN_SEGMENT_USD:
            reason = "budget"
            break
        sid = str(uuid.uuid4())
        stopped, timed, w = seg(build_cmd(SUCCESSOR_PROMPT, model, effort, ceiling, left(), session=sid), stop_at)
        wall += w
        timed_out |= timed
    s = summarize_streams(segs, ceiling)
    s.update(task=task, arm=arm, rep=rep, model=model, seed=seed, scale=scale, wall_s=wall, handoffs=handoffs,
             segments=len(segs), timed_out=timed_out)
    s["check"] = tasks.check(task, ws, seed, scale)
    dr = subprocess.run(["diff", "-ruN", "-x", "HANDOFF.md", "base", "ws"], cwd=rd, capture_output=True,
                        text=True, errors="replace", env=dict(os.environ, LC_ALL="C"))
    # diff echoes its own command line (-x HANDOFF.md) into every header; the blind judge must not see it
    body = "".join(l for l in dr.stdout.splitlines(True) if not l.startswith("diff "))
    with open(os.path.join(rd, "final.diff"), "w") as fh:
        fh.write(body)   # whole: the judge scores what the worker did after its compactions, so nothing is cut
    s["diff_chars"] = len(body)
    diff_ok = dr.returncode in (0, 1)   # 1 = the trees differ; 2 = diff itself failed
    if not diff_ok:
        s["diff_error"] = dr.stderr[:200]
    try:
        s["defects"] = defect_counts(segs)
    except Exception as e:   # a classifier fault must not lose a priced run
        s["defects"] = None
        s["defects_error"] = str(e)[:200]
    s["error"] = timed_out or not s["result_ok"]
    if s["error"]:
        reason = reason or ("timeout" if timed_out else "error")
    elif not diff_ok:
        reason = reason or "diff-error"
    elif arm == "b" and (handoffs < 1 or stopped):
        reason = reason or ("no-handoff" if handoffs < 1 else "handoff-loop")
    elif arm != "b" and s["compactions"] < 1:
        reason = reason or "no-compaction"
    elif arm != "b" and s["compaction_pre"] and max(s["compaction_pre"]) < FIRE_MIN * ceiling:
        reason = reason or "off-trigger"
    s["valid"] = reason is None
    s["invalid_reason"] = reason
    shutil.rmtree(ws, ignore_errors=True)
    shutil.rmtree(os.path.join(rd, "base"), ignore_errors=True)
    with open(os.path.join(rd, "summary.json"), "w") as fh:
        json.dump(s, fh, indent=1)
    return s


# ------------------------------------------------------------------ sweep
def spent(out):
    total = 0
    for p in glob.glob(os.path.join(out, "*", "*", "*", "summary.json")) + glob.glob(os.path.join(out, "*", "*", "*", "judge.json")):
        try:
            total += json.load(open(p)).get("cost_eq") or 0
        except (OSError, ValueError):
            die("cannot sum the spent cost-eq: %s unreadable" % p, 3)
    return int(total)


def preflight():
    pf = os.environ.get("AB_PREFLIGHT", os.path.join(REPO, "scripts", "lib", "usage-preflight.sh"))
    r = subprocess.run(["bash", pf], capture_output=True, text=True)
    return r.returncode == 0 and "PROCEED" in r.stdout.split(), r.stdout + r.stderr


def parse_scales(spec, default):
    out = {}
    for kv in filter(None, (spec or "").split(",")):
        k, _, v = kv.partition("=")
        if k not in tasks.TASKS or not v:
            die("--scales takes task=factor pairs, not '%s'" % kv)
        out[k] = float(v)
    return lambda t: out.get(t, default)


def cmd_sweep(a):
    need_billed()
    ids = [t for t in a.tasks.split(",") if t]
    arms = [x for x in a.arms.split(",") if x]
    for t in ids:
        if t not in tasks.TASKS:
            die("unknown task: " + t)
    for x in arms:
        if x not in CEIL:
            die("--arms takes a, b, c, not '%s'" % x)
    scale = parse_scales(a.scales, a.scale)
    os.makedirs(a.out, exist_ok=True)
    for t in ids:
        todo = [(x, r) for x in arms for r in range(1, a.reps + 1)
                if not os.path.exists(os.path.join(a.out, t, x, str(r), "summary.json"))]
        redo = [(x, r) for x in arms for r in range(1, a.reps + 1) if (x, r) not in todo and a.rerun_invalid
                and not json.load(open(os.path.join(a.out, t, x, str(r), "summary.json"))).get("valid")]
        if not todo and not redo:
            continue
        for x, r in todo + redo:
            ok, text = preflight()
            if not ok:
                print("ab.py: bank-preflight did not PROCEED before %s/%s/%d - stopped\n%s" % (t, x, r, text), file=sys.stderr)
                return 3
            s = spent(a.out)
            if s >= a.ceiling:
                print("ab.py: spent %d cost-eq, ceiling %d reached before %s/%s/%d - stopped" % (s, a.ceiling, t, x, r), file=sys.stderr)
                return 3
            if (x, r) in redo:   # keep the invalid run's priced summary: it counts against the ceiling
                d = os.path.join(a.out, t, x)
                n = 1
                while os.path.exists(os.path.join(d, "%d.invalid-%d" % (r, n))):
                    n += 1
                os.rename(os.path.join(d, str(r)), os.path.join(d, "%d.invalid-%d" % (r, n)))
            s = run_cell(t, x, r, a.out, a.model, a.effort, a.max_usd, a.timeout, a.seed, scale(t))
            print("ab.py: %s %s %d -> %s cost_eq=%d compactions=%d handoffs=%d peak_ctx=%d check=%d/%d%s" % (
                t, x, r, "valid" if s["valid"] else "INVALID(%s)" % s["invalid_reason"], s["cost_eq"], s["compactions"],
                s["handoffs"], s["peak_ctx"], s["check"]["passed"], s["check"]["total"], ""), flush=True)
    print("ab.py: sweep done, spent %d cost-eq" % spent(a.out))
    return 0


# ------------------------------------------------------------------ judge
def judge_prompt(rd):
    brief = open(os.path.join(rd, "brief.txt")).read()
    diff = open(os.path.join(rd, "final.diff"), errors="replace").read()   # whole; a diff past the judge's window gets no SCORE and stays unscored
    s = json.load(open(os.path.join(rd, "summary.json")))
    reply = "\n".join(l for l in (s.get("reply") or "").splitlines() if not re.search(r"hand-?off", l, re.I))[:600]
    return ("Rate the work. A worker was given the brief below and changed a workspace. Its rulings are part of the brief.\n\n"
            "=== BRIEF ===\n%s\n\n=== FINAL REPLY ===\n%s\n\n=== CHANGE (diff against the starting workspace) ===\n%s\n\n"
            "Score 1 to 10 how completely and correctly the change carries out the brief, every ruling included. "
            "End your reply with one line: SCORE: <n>." % (brief, reply, diff))


def judge_state(rd):
    """-> (score or None, cost_eq already spent judging this run)."""
    try:
        j = json.load(open(os.path.join(rd, "judge.json")))
    except (OSError, ValueError):
        return None, 0
    return j.get("score"), j.get("cost_eq") or 0


def cmd_judge(a):
    need_billed()
    for sp in sorted(glob.glob(os.path.join(a.out, "*", "*", "*", "summary.json"))):
        rd = os.path.dirname(sp)
        prev_score, prev_cost = judge_state(rd)
        if prev_score is not None or not json.load(open(sp)).get("valid"):
            continue
        ok, text = preflight()
        if not ok:
            print("ab.py: bank-preflight did not PROCEED before judging %s - stopped\n%s" % (rd, text), file=sys.stderr)
            return 3
        s = spent(a.out)
        if s >= a.ceiling:
            print("ab.py: spent %d cost-eq, ceiling %d reached before judging %s - stopped" % (s, a.ceiling, rd), file=sys.stderr)
            return 3
        scratch = tempfile.mkdtemp(prefix="ab-judge-")
        try:
            stream = os.path.join(scratch, "judge.stream.jsonl")
            # blind judge replay of a finished run, explicit permission mode, budget-capped
            # launch-profile-ok: scores outcome quality only, not a worker profile
            argv = [claude_bin(), "-p", "--model", a.model, "--effort", "high", "--permission-mode", "dontAsk",
                    "--output-format", "stream-json", "--verbose", "--max-budget-usd", "2", "--setting-sources", "user",
                    "--strict-mcp-config", "--no-session-persistence", "--disallowedTools",
                    "Bash", "Read", "Edit", "Write", "Grep", "Glob", "Agent", "WebFetch", "WebSearch"]
            run_segment(argv, scratch, stream, 900, stdin_text=judge_prompt(rd))
            j = summarize_streams([stream], 200000)
            m = re.findall(r"SCORE:\s*(\d+)", j["reply"])
            if not m:   # a null score is retried by the next `judge`; its cost stays counted
                print("ab.py: judge gave no SCORE for %s" % rd, file=sys.stderr)
            with open(os.path.join(rd, "judge.json"), "w") as fh:
                json.dump({"score": int(m[-1]) if m else None, "cost_eq": prev_cost + j["cost_eq"], "reply": j["reply"][-300:]}, fh, indent=1)
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
    return 0


# ------------------------------------------------------------------ score
def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 3) if xs else None


def load_cells(out):
    cells, invalid = {}, []
    for sp in sorted(glob.glob(os.path.join(out, "*", "*", "*", "summary.json"))):
        s = json.load(open(sp))
        jp = os.path.join(os.path.dirname(sp), "judge.json")
        s["judge"] = json.load(open(jp)).get("score") if os.path.exists(jp) else None
        if s.get("valid"):
            cells.setdefault((s["task"], s["arm"]), []).append(s)
        else:
            invalid.append(s)
    return cells, invalid


def cell_row(task, arm, runs):
    return {"task": task, "arm": arm, "runs": len(runs),
            "check": mean([r["check"]["passed"] / r["check"]["total"] for r in runs if r["check"]["total"]]),
            "judge": mean([r["judge"] for r in runs]), "cost_eq": mean([r["cost_eq"] for r in runs]),
            "wall_s": mean([r["wall_s"] for r in runs]), "turns": mean([r["turns"] for r in runs]),
            "compactions": mean([r["compactions"] for r in runs]), "handoffs": mean([r["handoffs"] for r in runs]),
            "peak_ctx": mean([r["peak_ctx"] for r in runs]),
            "defects": mean([sum((r.get("defects") or {}).values()) if r.get("defects") is not None else None for r in runs])}


def recommend(rows):
    """Best quality wins; arms within 0.05 of the best check share and 1 judge point of the best judge score
    are level on quality, and the cheapest of those wins."""
    if not rows:
        return None
    best_c = max(r["check"] or 0 for r in rows)
    band = [r for r in rows if (r["check"] or 0) >= best_c - 0.05]
    best_j = max(r["judge"] or 0 for r in band)
    level = [r for r in band if (r["judge"] or 0) >= best_j - 1]
    return min(level, key=lambda r: r["cost_eq"] or 0)


def cmd_score(a):
    cells, invalid = load_cells(a.out)
    rows = [cell_row(t, x, runs) for (t, x), runs in sorted(cells.items())]
    recs = {}
    for t, prof in sorted(tasks.PROFILE.items()):
        pick = recommend([r for r in rows if r["task"] == t])
        recs[prof] = {"task": t, "arm": pick["arm"] if pick else None}
    inv = [{"task": s["task"], "arm": s["arm"], "rep": s["rep"], "reason": s["invalid_reason"], "compactions": s["compactions"],
            "handoffs": s["handoffs"], "peak_ctx": s["peak_ctx"], "cost_eq": s["cost_eq"]} for s in invalid]
    if a.json:
        print(json.dumps({"cells": rows, "invalid": inv, "recommend": recs, "spent_cost_eq": spent(a.out)}, indent=1))
        return 0
    cols = ["task", "arm", "runs", "check", "judge", "cost_eq", "wall_s", "turns", "compactions", "handoffs", "peak_ctx", "defects"]
    print("\t".join(cols))
    for r in rows:
        print("\t".join(str(r[c]) for c in cols))
    for s in inv:
        print("INVALID %(task)s %(arm)s rep %(rep)s: %(reason)s (compactions=%(compactions)s handoffs=%(handoffs)s peak_ctx=%(peak_ctx)s cost_eq=%(cost_eq)s), not scored" % s)
    for prof, r in recs.items():
        print("recommend %s: %s" % (prof, "%s (task %s)" % (r["arm"], r["task"]) if r["arm"] else "no runs"))
    print("spent %d cost-eq" % spent(a.out))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, many):
        p.add_argument("--out", required=True)
        p.add_argument("--model", default="sonnet")
        p.add_argument("--effort", default="high")
        p.add_argument("--max-usd", type=float, default=20)
        p.add_argument("--timeout", type=int, default=5400)
        p.add_argument("--seed", type=int, default=1)
        p.add_argument("--scale", type=float, default=1.0)

    r = sub.add_parser("run")
    common(r, False)
    r.add_argument("--task", required=True, choices=sorted(tasks.TASKS))
    r.add_argument("--arm", required=True, choices=sorted(CEIL))
    r.add_argument("--rep", type=int, default=1)
    s = sub.add_parser("sweep")
    common(s, True)
    s.add_argument("--tasks", default="docs,impl,audit")
    s.add_argument("--arms", default="a,b,c")
    s.add_argument("--reps", type=int, default=1)
    s.add_argument("--scales", default="")
    s.add_argument("--ceiling", type=int, required=True)
    s.add_argument("--rerun-invalid", action="store_true")
    j = sub.add_parser("judge")
    j.add_argument("--out", required=True)
    j.add_argument("--model", default="opus")
    j.add_argument("--ceiling", type=int, required=True)
    c = sub.add_parser("score")
    c.add_argument("--out", required=True)
    c.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    if a.cmd in ("run", "sweep", "judge"):
        out = os.path.realpath(a.out)
        if out == REPO or out.startswith(REPO + os.sep):
            die("--out must be outside the checkout: runs go on scratch copies")
    if a.cmd in ("sweep", "judge") and a.ceiling <= 0:
        die("--ceiling must be a positive cost-eq total: the hard stop is not optional")
    if a.cmd == "run":
        need_billed()
        s = run_cell(a.task, a.arm, a.rep, a.out, a.model, a.effort, a.max_usd, a.timeout, a.seed, a.scale)
        print(json.dumps({k: s[k] for k in ("task", "arm", "valid", "invalid_reason", "cost_eq", "compactions", "handoffs", "peak_ctx")}))
        return 0
    return {"sweep": cmd_sweep, "judge": cmd_judge, "score": cmd_score}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
