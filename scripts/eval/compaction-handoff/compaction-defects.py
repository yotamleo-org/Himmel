#!/usr/bin/env python3
# scripts/eval/compaction-handoff/compaction-defects.py - what a compaction
# costs a worker: the defects in the turns after each compact_boundary, against a
# control window of the same length before it, plus the per-turn cost-eq and
# context size on both sides. Local-only: reads Claude Code session JSONL, runs
# no inference, sends nothing anywhere.
#
#   compaction-defects.py [--projects <dir>] [--since-days N] [--window N]
#                         [--json] [--evidence] [--simulate CEILING]...
#
# A worker transcript is one whose customTitle is a worker doc stem
# (TICKET-N<k>[x]-...). A turn is one assistant API call (rows deduped by
# message id). The post window is the N turns after a boundary, clipped at the
# next one. The control window is the N turns before it, scored against the
# history before IT; it is used only when it holds no boundary and N turns of
# history precede it. Defect classes, each counted per window:
#   reread         a Read, or a cat/sed -n/head Bash read, of a path read
#                  before the window and not written since (Edit/Write, or any
#                  Bash call naming the path; a git pull/merge/rebase/checkout/
#                  reset/switch clears every read); once per path, and never a
#                  task output or log, which grows on its own
#   denied_repeat  a call identical to one denied earlier (hook or permission
#                  denial), denied again
#   nonce          a RETASK-shaped token (ABC-N123-<hex>) the worker writes that no
#                  user row or tool result has shown it, or a SendMessage asking
#                  for a token or ruling again (resend / remind / re-confirm)
#   verdict        a judge dispatch (Agent whose type or description names a
#                  judge) whose prompt repeats an earlier judge prompt
#   redo           a state-changing call (commit, push, PR write, Jira write,
#                  ledger or Results append, SendMessage, Write) identical to an
#                  earlier one that succeeded; one without its own payload
#                  (git push, clear-cr-marker, write-verdicts --from-file)
#                  counts only when no file write or commit came between
# Cost: cost-eq per turn uses the weights of scripts/eval/autocompact-ab.py
# (cache_read x0.1). A compaction call is not in the transcript; its cost is
# estimated as preTokens read from cache plus the summary (chars / 4) as output.
# --simulate C replays each worker at a ceiling C: the context it would have held
# (actual context plus the tokens every earlier compaction dropped), with a
# succession hand-off (arm b: restart at the worker's first-turn context plus
# --resume-tokens) or a compaction (arm c: back to the median post-compaction
# context) whenever it reaches C. A cache-miss turn (cache_create above half
# the context) re-creates the simulated context; the rest of the context is
# priced as cache_read.
#
import argparse, datetime, glob, importlib.util, json, os, re, statistics, sys, time

_ab_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "autocompact-ab.py")
_spec = importlib.util.spec_from_file_location("autocompact_ab", _ab_path)
ab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ab)

CLASSES = ("reread", "denied_repeat", "nonce", "verdict", "redo")
WORKER_TITLE = re.compile(r"^[A-Z][A-Z0-9]*-\d+-[NP]\d+[a-z]*-")
TOKEN = re.compile(r"\b[A-Z][A-Z0-9]{0,8}-N\d+[a-z]?-[0-9a-f]{6,10}\b")
DENIED = re.compile(r"PreToolUse:\S+ hook error|Permission for this action was denied|"
                    r"doesn't want to proceed|permission to use \S+ has been denied", re.I)
# the worker asking for its own token or ruling; asking the chief to re-send a GO
# that did not quote the token is the chief's miss, not the worker's
ASK = re.compile(r"\b(remind me (of|what)|what (is|was) my (token|nonce|ruling)|"
                 r"(lost|forgot|cannot find|can't find) (the|my) (token|nonce|ruling)|"
                 r"repeat (the|your) ruling)\b", re.I)
READ_CMD = {"cat", "head", "sed", "nl", "less", "bat"}
# a background task's output or a log grows on its own: reading it again is polling
GROWING = re.compile(r"\.(output|log)$|/tasks/|/quiet-run-")
# a Bash call that writes a file: a redirect to a path (not an fd dup or
# /dev/null), sed -i, tee, mv/cp, or an interpreter fed a heredoc
BASH_WRITE = re.compile(r"(?<![0-9&])>>?\s*(?!&|/dev/null)[^\s|;&]|\bsed\s+(-[a-zA-Z]*\s+)*-i|\btee\b|"
                        r"(?:^|[;&|]\s*)(?:mv|cp)\s|\b(?:python3?|perl|node)\b[^|;&]*<<")
GIT_RESET = re.compile(r"\bgit\s+(pull|merge|rebase|checkout|reset|switch|am|cherry-pick|restore)\b")
# invoked at a command position, never a name inside a grep or pgrep pattern
MUTATE = re.compile(
    r"(?:^|[;&|(]\s*)(?:git(?:\s+-C\s+\S+)?\s+(?:commit|push|tag)\b|"
    r"gh\s+(?:pr\s+(?:create|comment|edit|merge|ready|close)|issue\s+(?:create|comment))\b|"
    r"(?:bash\s+)?\S*(?:append-results\.sh|queue-lock\.sh\s+(?:acquire|release)|write-verdicts\.sh\s+\w|"
    r"ledger-append\.sh|merge-on-green\.sh|(?:worker|leg)-pr-open\.sh|clear-review-marker\.sh|clear-cr-marker\.sh)|"
    r"node\s+\S*jira/dist/index\.js\s+(?:create|comment|transition|update|edit|link))", re.M)
# a call that ran past its timeout went to the background: not known to be done
BACKGROUNDED = re.compile(r"^Command (?:did not complete|running in background)|moved to the background")
# a call that carries its own payload repeats work whenever it repeats; any other
# state-changing call (push, clear-cr-marker, write-verdicts --from-file) acts on
# current state, so it is a redo only when no file write or commit came between
PAYLOAD = re.compile(r"\bgit\s+commit\b.*\s-m\s|append-results\.sh\s+\S+\s+\S|\s--body\s|\s--comment\s")
DROP_KEYS = ("description", "timeout", "run_in_background", "dangerouslyDisableSandbox")


def call_key(name, inp):
    if isinstance(inp, dict):
        inp = {k: v for k, v in inp.items() if k not in DROP_KEYS}
    return name + "\x00" + json.dumps(inp, sort_keys=True)


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(text_of(b.get("text") if b.get("type") == "text" else b.get("content"))
                        for b in content if isinstance(b, dict))
    return ""


def words(s):
    return set(re.findall(r"[a-z0-9]{3,}", s.lower()))


def jaccard(a, b):
    return len(a & b) / len(a | b) if a and b else 0.0


def bash_read_paths(cmd, cwd):
    """(path, span) per file a cat/sed -n/head reads; span is "all" for a whole
    file, else the line range asked for (another range is not a re-read)."""
    out = []
    for seg in re.split(r"\|\||&&|[|;\n]", cmd):
        toks = seg.split()
        if not toks or os.path.basename(toks[0]) not in READ_CMD:
            continue
        args = [t.strip("'\"") for t in toks[1:]]
        span = "all"
        if toks[0] == "sed":
            if "-n" not in args or any(a.startswith("-i") for a in args):
                continue
            rest = [a for a in args if not a.startswith("-")]
            span, args = (rest[0] if rest else "all"), rest[1:]
        elif toks[0] == "head":
            span = "head:" + "".join(a for a in args if a.isdigit() or re.match(r"^-\d+$", a))
        for a in args:
            if a.startswith("-") or a.isdigit() or not re.search(r"[/.]", a) or re.search(r"[*?$`<>{}]", a):
                continue
            out.append((norm(a, cwd), span))
    return out


def read_spans(name, inp, cwd):
    if name == "Read" and inp.get("file_path"):
        span = "all" if not (inp.get("offset") or inp.get("limit")) else "%s:%s" % (inp.get("offset"), inp.get("limit"))
        return [(norm(inp["file_path"], cwd), span)]
    if name == "Bash":
        return bash_read_paths(inp.get("command") or "", cwd)
    return []


def norm(p, cwd):
    p = os.path.expanduser(p)
    if not os.path.isabs(p) and cwd:
        p = os.path.join(cwd, p)
    return os.path.normpath(p)


def load(path):
    """Ordered turns and boundaries of one transcript. A turn: usage, tool calls
    (with their result), the tokens it wrote, and the text it was shown."""
    turns, bounds, by_id, by_tool, title = [], [], {}, {}, None
    pending_seen = []
    for line in open(path, errors="replace"):
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if row.get("customTitle"):
            title = row["customTitle"]
        if row.get("isSidechain"):
            continue
        typ = row.get("type")
        if typ != "assistant":
            # a chief message can arrive as a hook attachment or a queued
            # command, not only as a user row: every token shown counts as seen
            pending_seen.append(" ".join(TOKEN.findall(line)))
        if typ == "system" and row.get("subtype") == "compact_boundary":
            meta = row.get("compactMetadata") or {}
            bounds.append({"turn": len(turns), "uuid": row.get("uuid") or "%s:%s" % (path, len(bounds)),
                           "trigger": meta.get("trigger"), "pre": meta.get("preTokens") or 0,
                           "post": meta.get("postTokens"), "summary_chars": 0})
            continue
        msg = row.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if typ == "user":
            if row.get("isCompactSummary") and bounds:
                bounds[-1]["summary_chars"] += len(text_of(content))
            if isinstance(content, list):
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "tool_result":
                        call = by_tool.get(b.get("tool_use_id"))
                        txt = text_of(b.get("content")) if not isinstance(b.get("content"), str) else b["content"]
                        if call is not None:
                            call["error"] = bool(b.get("is_error"))
                            call["denied"] = bool(b.get("is_error")) and bool(DENIED.search(txt or ""))
                            call["result"] = (txt or "")[:200]
                        pending_seen.append(txt or "")
                    elif isinstance(b, dict) and b.get("type") == "text":
                        pending_seen.append(b.get("text") or "")
            else:
                pending_seen.append(text_of(content))
            continue
        if typ != "assistant":
            continue
        mid = msg.get("id") or "row-%d" % len(turns)
        t = by_id.get(mid)
        if t is None:
            t = {"id": mid, "cwd": row.get("cwd"), "model": msg.get("model"), "calls": [], "wrote": [],
                 "seen": pending_seen}
            pending_seen = []
            by_id[mid] = t
            turns.append(t)
        # one row per content block: the last row's usage is the message's
        u = msg.get("usage")
        if isinstance(u, dict):
            t.update({"in": u.get("input_tokens") or 0, "cr": u.get("cache_read_input_tokens") or 0,
                      "cc": u.get("cache_creation_input_tokens") or 0, "out": u.get("output_tokens") or 0,
                      "cc1h": (u.get("cache_creation") or {}).get("ephemeral_1h_input_tokens") or 0})
        for b in content if isinstance(content, list) else []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                t["wrote"].append(b.get("text") or "")
            elif b.get("type") == "tool_use":
                c = {"name": b.get("name"), "id": b.get("id"), "input": b.get("input") or {}, "error": False, "denied": False}
                t["calls"].append(c)
                # what the worker says: messages and Results bullets, never file
                # content (a test fixture carries made-up tokens)
                cmd = c["input"].get("command") or "" if isinstance(c["input"], dict) else ""
                if c["name"] == "SendMessage" or "append-results.sh" in cmd:
                    t["wrote"].append(json.dumps(c["input"], ensure_ascii=False))
                by_tool[b.get("id")] = c
    for t in turns:
        for k in ("in", "cr", "cc", "out", "cc1h"):
            t.setdefault(k, 0)
        t["ctx"] = t["in"] + t["cr"] + t["cc"]
        t["cost"] = t["in"] * ab.W_IN + t["cr"] * ab.W_CR + t["cc"] * ab.W_CC + t["out"] * ab.W_OUT
    return title, turns, bounds


def score(turns, lo, hi, evidence):
    """Defects in turns[lo:hi], judged against turns[:lo]."""
    reads = {}            # path -> {span: "pre" | "win"} while that read is current
    denied, done, judge_prompts, seen_tokens = set(), {}, [], set()
    since_write = 0       # file writes so far (for payload-free redo)
    hits = {k: 0 for k in CLASSES}
    ev = []

    def hit(cls, i, what):
        hits[cls] += 1
        if evidence:
            ev.append({"class": cls, "turn": i - lo, "what": what[:200]})

    for i, t in enumerate(turns[:hi]):
        live = i >= lo
        for s in t["seen"]:
            seen_tokens.update(TOKEN.findall(s))
        if live:
            for w in t["wrote"]:
                for tok in set(TOKEN.findall(w)) - seen_tokens:
                    # a cut-off quote (a summary ending in an ellipsis) is not a misquote
                    if not any(s.startswith(tok) for s in seen_tokens):
                        hit("nonce", i, "unseen token " + tok)
                    seen_tokens.add(tok)
        else:
            for w in t["wrote"]:
                seen_tokens.update(TOKEN.findall(w))
        for c in t["calls"]:
            name, inp = c["name"], c["input"] if isinstance(c["input"], dict) else {}
            key = call_key(name, inp)
            cmd = inp.get("command") or "" if name == "Bash" else ""
            # reads
            rpaths = read_spans(name, inp, t["cwd"])
            # done = a result came back and it was not an error
            ok = c.get("result") is not None and not c["error"]
            # writes invalidate reads, before this call's own reads count
            if name in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
                p = inp.get("file_path") or inp.get("notebook_path")
                if p:
                    reads[norm(p, t["cwd"])] = {}
                since_write += 1
            elif name == "Bash":
                if GIT_RESET.search(cmd):
                    reads = {}
                else:
                    own = {p for p, _ in rpaths}
                    for p in list(reads):
                        if p not in own and os.path.basename(p) in cmd:
                            reads[p] = {}
            for p, span in rpaths if ok else []:
                if GROWING.search(p):
                    continue
                got = reads.setdefault(p, {})
                # once per path, and only the same span (or the whole file)
                # read before the window
                if live and "pre" in (got.get(span), got.get("all")):
                    hit("reread", i, p)
                    for s in got:
                        got[s] = "win"
                got[span] = "win" if live else "pre"
            # denied repeats
            if c["denied"]:
                if live and key in denied:
                    hit("denied_repeat", i, key.replace("\x00", " "))
                denied.add(key)
            # redo of a state-changing call
            mut = (name == "Bash" and MUTATE.search(cmd)) or name in ("SendMessage", "Write")
            if mut:
                prev = done.get(key)
                carries = name in ("SendMessage", "Write") or PAYLOAD.search(cmd)
                if live and prev is not None and (carries or prev == since_write):
                    hit("redo", i, key.replace("\x00", " "))
                if ok and not BACKGROUNDED.search(c["result"]):
                    done[key] = since_write
            if name == "Bash" and (BASH_WRITE.search(cmd) or (MUTATE.search(cmd) and re.search(r"\bgit\s+commit\b", cmd))):
                since_write += 1
            # asks for a token or ruling again
            if name == "SendMessage" and live and ASK.search(str(inp.get("message") or "")):
                hit("nonce", i, "ask: " + str(inp.get("message"))[:160])
            # judge re-dispatch
            if name == "Agent":
                desc = "%s %s" % (inp.get("subagent_type") or "", inp.get("description") or "")
                if "judge" in desc.lower():
                    # eval batches share one prompt template: only the same
                    # description with a near-identical prompt is a re-ask
                    w, d = words(str(inp.get("prompt") or "")), desc.strip().lower()
                    if live and any(pd == d and jaccard(w, p) >= 0.8 for pd, p in judge_prompts):
                        hit("verdict", i, "judge re-asked: " + (inp.get("description") or ""))
                    judge_prompts.append((d, w))
    return hits, ev


def window_cost(turns):
    if not turns:
        return None, None
    return (round(statistics.mean(t["cost"] for t in turns)),
            round(statistics.mean(t["ctx"] for t in turns)))


def profile_of(title):
    slug = title.lower()
    if re.search(r"eval|audit|measure|bench|probe|research|baseline|poc", slug):
        return "eval"
    if re.search(r"docs?\b|docs-|readme|prose|glossary|wording", slug):
        return "docs"
    return "impl"


def model_of(turns):
    return next((t["model"] for t in turns if t.get("model")), None)


def simulate(turns, bounds, ceiling, resume_tokens, post_median, priced=None):
    """cost-eq of one transcript replayed at `ceiling`, arms b and c. Every turn
    drives the replayed context (boundary indices are into `turns`); only the
    turns whose id is in `priced` (default all) are charged, so a resumed
    transcript does not charge its parent's turns twice."""
    if not turns:
        return None
    priced = priced if priced is not None else {t["id"] for t in turns}
    first = {b["turn"] for b in bounds}
    dropped, drop_at = 0, {}
    for b in bounds:
        if b["turn"] < len(turns):
            drop_at[b["turn"]] = max(0, b["pre"] - turns[b["turn"]]["ctx"])
    growth = [max(0, turns[i]["ctx"] - turns[i - 1]["ctx"]) for i in range(1, len(turns)) if i not in first]
    g_med = statistics.median(growth) if growth else 0
    s0 = turns[0]["ctx"] + resume_tokens
    # a simulated compaction writes a summary the size of this transcript's own
    summaries = [b["summary_chars"] / 4.0 for b in bounds if b["summary_chars"]]
    summary_tokens = statistics.median(summaries) if summaries else 2500
    res = {}
    for arm in ("b", "c"):
        off, events, cost, peak = 0, 0, 0.0, 0
        restart = s0 if arm == "b" else post_median
        trigger = ceiling if arm == "b" else ceiling - 33000
        dropped = 0
        for i, t in enumerate(turns):
            dropped += drop_at.get(i, 0)
            x = t["ctx"] + dropped - off
            charge = t["id"] in priced
            restarted = x >= trigger
            if restarted:
                off += x - restart
                x = restart
                if charge:
                    events += 1
                    if arm == "b":
                        cost += resume_tokens * ab.W_OUT + restart * ab.W_CC
                    else:
                        cost += trigger * ab.W_CR + summary_tokens * ab.W_OUT + restart * ab.W_CC
            peak = max(peak, x)
            if not charge:
                continue
            # the restart already paid to create its context: never twice
            miss = t["cc"] > 0.5 * t["ctx"] and i not in first and not restarted
            cc = x if miss else min(g_med if i in first or restarted else t["cc"], x)
            cost += t["in"] * ab.W_IN + t["out"] * ab.W_OUT + cc * ab.W_CC + max(0, x - cc - t["in"]) * ab.W_CR
        res[arm] = {"cost_eq": round(cost), "events": events, "peak": peak}
    return res


HERE = os.path.dirname(os.path.abspath(__file__))


def _import(name, *path):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, *path))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PUSH_CMD = re.compile(r"(?:^|[;&|(]\s*)git(?:\s+-C\s+\S+)?\s+push\b", re.M)
COMMIT_CMD = re.compile(r"\bgit(?:\s+-C\s+\S+)?\s+commit\b")
MARKER = re.compile(r"append-results\.sh\s+\S+\s+[\"']?(?:-\s*\d\d:\d\d\s+)?([A-Z][A-Z-]+)")
STOP_MARKERS = {"READY", "BLOCKED", "HALTED", "WRAPPED", "FINDING", "PARKED-BANK", "PARKED-USAGE"}
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")


def _flat_calls(turns):
    """The tool calls of the main chain in order: {k (from 1), turn, call}."""
    out = []
    for i, t in enumerate(turns):
        for c in t["calls"]:
            out.append({"k": len(out) + 1, "turn": i, "call": c})
    return out


def _cmd(c):
    return (c["input"].get("command") or "") if c["name"] == "Bash" and isinstance(c["input"], dict) else ""


def _changes_state(c):
    cmd = _cmd(c)
    return c["name"] in EDIT_TOOLS or bool(cmd and (BASH_WRITE.search(cmd) or COMMIT_CMD.search(cmd)))


def proxy_points(calls, turns, floor):
    """{call k: {push index}}: a call is a stable point when it is one of the first three calls after a successful
    `git push` call whose own command holds no `git commit`, made at or above the floor, with no state change
    since the push and the last append-results marker none of the stop markers. The call's own command counts as
    well (the guard does not see it; counting it makes the proxy hop less)."""
    marker_after, last = [], None
    for f in calls:
        m = MARKER.search(_cmd(f["call"]))
        last = m.group(1) if m else last
        marker_after.append(last)
    pts = {}
    for p, f in enumerate(calls):
        c = f["call"]
        cmd = _cmd(c)
        if not PUSH_CMD.search(cmd) or COMMIT_CMD.search(cmd) or c.get("result") is None or c["error"] \
                or turns[f["turn"]]["ctx"] < floor:
            continue
        for q in range(p + 1, min(p + 4, len(calls))):
            if _changes_state(calls[q]["call"]) or marker_after[q] in STOP_MARKERS:
                break
            pts.setdefault(calls[q]["k"], set()).add(p)
    return pts


def log_points(calls, path):
    """{call k: {window}}: the calls a shadow log names, by tool-use id when the line has one, else by call count.
    Lines read: `tool_use=<id>`, `calls=<n>` and `head=<sha>` (one window per head)."""
    by_id = {f["call"].get("id"): f["k"] for f in calls if f["call"].get("id")}
    pts = {}
    try:
        lines = open(path, errors="replace").read().splitlines()
    except OSError:
        return pts
    for n, line in enumerate(lines):
        kv = dict(t.split("=", 1) for t in line.split() if "=" in t)
        k = by_id.get(kv.get("tool_use")) if kv.get("tool_use") else None
        if k is None and kv.get("calls", "").isdigit():
            k = int(kv["calls"])
        if k is not None and 1 <= k <= len(calls):
            pts.setdefault(k, set()).add(kv.get("head") or "line%d" % n)
    return pts


def replay_rule(turns, calls, points, predictor, base, relaunch, model, hr, bw):
    """Input-side cost-eq of one session, as recorded and with the rule deciding at `points`; the rule is
    evaluated again at every point on the simulated context and the call count of the simulated session."""
    r, w = bw.cache_read_weight(model), bw.cache_create_1h_weight()
    w_cc, w_in = ab.W_CC, ab.W_IN

    def price(t, reads):
        return t["in"] * w_in + reads * r + (t["cc"] - t["cc1h"]) * w_cc + t["cc1h"] * w
    recorded = sum(price(t, max(0, t["ctx"] - t["in"] - t["cc"])) for t in turns)
    x, prev, start, cost, hops, spent = 0, 0, 0, 0.0, [], set()
    total = len(calls)
    by_turn = {}
    for f in calls:
        by_turn.setdefault(f["turn"], []).append(f["k"])
    for i, t in enumerate(turns):
        delta = t["ctx"] - prev
        x = t["ctx"] if i == 0 else x + (delta if delta >= 0 else t["in"] + t["cc"])
        x = max(x, t["in"] + t["cc"])
        prev = t["ctx"]
        cost += price(t, max(0, x - t["in"] - t["cc"]))
        for k in by_turn.get(i, []):
            if k not in points or points[k] <= spent:
                continue
            n = total - k if predictor == "oracle" else k - start
            if hr.should_hop(x, n, model, base, relaunch):
                cost += relaunch + w * base + hr.H * r * x
                x, start = base, k
                spent |= points[k]
                hops.append(k)
                break
    return recorded, cost, hops


def simulate_rule(a):
    """--simulate-rule: the hop rule replayed over the sessions the launch records name, priced in cost-eq.
    Calls are tool-call blocks of the main chain; a hop costs the relaunch, the one-hour write of the base and
    the old session's h calls at full context."""
    hr = _import("hop_rule", "..", "..", "lib", "hop_rule.py")
    bw = hr.burn_weights
    po = _import("profile_openings", "..", "profile-openings.py")
    td = _import("transcript_deliveries", "..", "..", "lib", "transcript_deliveries.py")
    spec = dict(kv.split("=", 1) for kv in a.simulate_rule.split(",") if "=" in kv)
    pred, pts_arg = spec.get("predictor"), spec.get("points", "")
    if pred not in ("oracle", "same-again") or not (pts_arg == "proxy" or pts_arg.startswith("log:")):
        sys.stderr.write("compaction-defects: --simulate-rule predictor=<oracle|same-again>,points=<proxy|log:DIR>"
                         "[,base=<n>][,relaunch=<n>]\n")
        return 2
    base, relaunch = int(spec.get("base", hr.B)), int(spec.get("relaunch", hr.K))
    cut = time.time() - a.since_days * 86400 if a.since_days > 0 else 0
    since = datetime.datetime.fromtimestamp(cut, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    until = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    launches = po.parse_launches(a.launch_logs, since, until, "native")
    _, by_sid = po.index_transcripts(a.projects, cut)
    skipped = {"no_session_id": 0, "no_transcript": 0, "unknown_model": 0}
    workers, claimed = [], set()
    for name, rec in sorted(launches.items()):
        if not rec["sids"]:
            skipped["no_session_id"] += 1
            continue
        found = [(s, by_sid[s]) for s in sorted(rec["sids"]) if s in by_sid and by_sid[s] not in claimed]
        if not found:
            skipped["no_transcript"] += 1
            continue
        for sid, path in found:
            claimed.add(path)
            _, turns, _ = load(path)
            model = model_of(turns)
            if not turns or not hr.burn_weights.is_known(model):
                skipped["unknown_model"] += 1
                continue
            calls = _flat_calls(turns)
            pts = (proxy_points(calls, turns, hr.FLOOR) if pts_arg == "proxy"
                   else log_points(calls, os.path.join(pts_arg[4:], sid + ".log")))
            rec_in, rule_in, hops = replay_rule(turns, calls, pts, pred, base, relaunch, model, hr, bw)
            workers.append({"worker": name, "profile": rec["profile"], "model": model, "calls": len(calls),
                            "eligible_rows": sum(1 for _, el, _ in td.classify(td.read_rows(path), td.ANY_CHIEF) if el),
                            "recorded": {"input": round(rec_in), "output": round(sum(t["out"] for t in turns) * ab.W_OUT),
                                         "writes_5m": sum(t["cc"] - t["cc1h"] for t in turns),
                                         "writes_1h": sum(t["cc1h"] for t in turns)},
                            "rule": {"input": round(rule_in), "output": round(sum(t["out"] for t in turns) * ab.W_OUT),
                                     "hops": len(hops), "hop_calls": hops}})
    roll = {}
    for wk in workers:
        for kind, key in (("by_model", wk["model"]), ("by_profile", wk["profile"])):
            g = roll.setdefault(kind, {}).setdefault(key, {"sessions": 0, "hops": 0, "recorded_input": 0,
                                                            "rule_input": 0, "output": 0, "writes_5m": 0, "writes_1h": 0})
            g["sessions"] += 1
            g["hops"] += wk["rule"]["hops"]
            g["recorded_input"] += wk["recorded"]["input"]
            g["rule_input"] += wk["rule"]["input"]
            g["output"] += wk["recorded"]["output"]
            g["writes_5m"] += wk["recorded"]["writes_5m"]
            g["writes_1h"] += wk["recorded"]["writes_1h"]
    for kind in roll.values():
        for g in kind.values():
            g["input_change_pct"] = round(100.0 * (g["rule_input"] - g["recorded_input"]) / g["recorded_input"], 2) \
                if g["recorded_input"] else None
    out = {"simulate_rule": {"predictor": pred, "points": pts_arg if pts_arg == "proxy" else "log", "base": base,
                             "relaunch": relaunch, "sessions": len(workers), "skipped": skipped, "workers": workers,
                             "by_model": roll.get("by_model", {}), "by_profile": roll.get("by_profile", {})}}
    if a.json:
        print(json.dumps(out, indent=2))
        return 0
    s = out["simulate_rule"]
    print("rule replay: predictor %s, points %s, base %d, relaunch %d; sessions %d, skipped %s" % (
        pred, s["points"], base, relaunch, s["sessions"], json.dumps(skipped)))
    for kind in ("by_model", "by_profile"):
        for key, g in sorted(s[kind].items()):
            print("%-10s %-24s sessions %4d hops %4d input recorded %12d rule %12d (%s%%) output %12d writes 5m %d 1h %d" % (
                kind[3:], key, g["sessions"], g["hops"], g["recorded_input"], g["rule_input"], g["input_change_pct"],
                g["output"], g["writes_5m"], g["writes_1h"]))
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--projects", default=os.path.join(
        os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"),
        "projects", "-home-overlord-Documents-github-himmel"))
    ap.add_argument("--since-days", type=float, default=14, help="0 = every transcript")
    ap.add_argument("--window", type=int, default=40)
    ap.add_argument("--simulate", type=int, action="append", default=[])
    ap.add_argument("--simulate-rule", help="predictor=<oracle|same-again>,points=<proxy|log:DIR>[,base=N][,relaunch=N]: replay the hop rule over the sessions --launch-logs names")
    ap.add_argument("--launch-logs", help="the launch-logs dir for --simulate-rule")
    ap.add_argument("--resume-tokens", type=int, default=6000)
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--evidence", action="store_true", help="carry a <=200 char excerpt per defect (private: never commit)")
    a = ap.parse_args()
    if a.simulate_rule:
        if not a.launch_logs:
            ap.error("--simulate-rule needs --launch-logs")
        return simulate_rule(a)

    cut = time.time() - a.since_days * 86400 if a.since_days > 0 else 0
    paths = sorted((p for p in glob.glob(os.path.join(a.projects, "**", "*.jsonl"), recursive=True)
                    if os.path.getmtime(p) >= cut), key=os.path.getmtime)
    N = a.window
    comps, workers, seen_b, seen_turn, sims = {}, {}, set(), set(), []
    for path in paths:
        title, turns, bounds = load(path)
        if not title or not WORKER_TITLE.match(title):
            continue
        prof = profile_of(title)
        model = model_of(turns)
        workers.setdefault(title, {"profile": prof, "model": model, "transcripts": 0})
        workers[title]["transcripts"] += 1
        # a resumed transcript repeats its parent's turns: price each turn once
        fresh = [t for t in turns if t["id"] not in seen_turn]
        seen_turn.update(t["id"] for t in turns)
        if a.simulate and fresh:
            new_b = [b for b in bounds if b["uuid"] not in seen_b]
            actual = sum(t["cost"] for t in fresh) + sum(
                b["pre"] * ab.W_CR + b["summary_chars"] / 4.0 * ab.W_OUT for b in new_b)
            sims.append({"worker": title, "profile": prof, "model": model, "turns": len(fresh),
                         "bounds": bounds, "turns_list": turns, "priced": {t["id"] for t in fresh},
                         "actual": round(actual), "actual_compactions": len(new_b)})
        starts = [b["turn"] for b in bounds]
        for k, b in enumerate(bounds):
            lo = b["turn"]
            hi = min(lo + N, starts[k + 1] if k + 1 < len(starts) else len(turns))
            # a resumed transcript repeats a boundary its parent holds and may
            # run further past it: score the copy with the longest post window
            prev = comps.get(b["uuid"])
            if hi <= lo or (prev is not None and prev["post_turns"] >= hi - lo):
                continue
            d, ev = score(turns, lo, hi, a.evidence)
            clo = lo - N
            ctrl_ok = clo >= N and not any(clo - N <= s < lo for s in starts[:k])
            c = score(turns, clo, lo, False)[0] if ctrl_ok else None
            pc, px = window_cost(turns[max(0, lo - N):lo])
            qc, qx = window_cost(turns[lo:hi])
            rec = {"worker": title, "transcript": os.path.basename(path), "profile": prof, "model": model,
                   "uuid": b["uuid"], "trigger": b["trigger"], "pre_tokens": b["pre"], "post_tokens": b["post"],
                   "turn": lo, "post_turns": hi - lo, "control_turns": N if ctrl_ok else 0,
                   "defects": d, "control": c,
                   "cost": {"pre_turn": pc, "post_turn": qc, "pre_ctx": px, "post_ctx": qx,
                            "reprime_cache_create": turns[lo]["cc"],
                            "compaction_est": round(b["pre"] * ab.W_CR + b["summary_chars"] / 4.0 * ab.W_OUT),
                            "compaction_est_uncached": round(b["pre"] * ab.W_IN + b["summary_chars"] / 4.0 * ab.W_OUT)}}
            if a.evidence:
                rec["evidence"] = ev
            comps[b["uuid"]] = rec
        seen_b.update(b["uuid"] for b in bounds)

    comps = list(comps.values())
    summary = summarize(comps, workers, N)
    out = {"window": N, "workers": len(workers), "transcripts": sum(l["transcripts"] for l in workers.values()),
           "compactions": comps, "summary": summary}
    if a.simulate:
        posts = [c["cost"]["post_ctx"] for c in comps if c["cost"]["post_ctx"]]
        post_med = statistics.median([t["turns_list"][b["turn"]]["ctx"] for t in sims for b in t["bounds"]
                                      if b["turn"] < len(t["turns_list"])] or posts or [40000])
        out["simulate"] = []
        for C in a.simulate:
            per = []
            for s in sims:
                r = simulate(s["turns_list"], s["bounds"], C, a.resume_tokens, post_med, s["priced"])
                if r:
                    per.append({"worker": s["worker"], "profile": s["profile"], "model": s["model"], "turns": s["turns"],
                                "actual": s["actual"], "actual_compactions": s["actual_compactions"],
                                "b": r["b"], "c": r["c"]})
            out["simulate"].append({"ceiling": C, "post_ctx_median": post_med, "workers": per,
                                    "by_profile": sim_rollup(per)})
    if a.json:
        print(json.dumps(out, indent=2))
        return 0
    print_text(out)
    return 0


def summarize(comps, workers, N):
    groups = {}
    for c in comps:
        for g in ("all", "profile:" + c["profile"], "model:" + (c["model"] or "?")):
            groups.setdefault(g, []).append(c)
    out = {}
    for g, cs in sorted(groups.items()):
        paired = [c for c in cs if c["control"] is not None]
        row = {"compactions": len(cs), "paired": len(paired),
               "post_per_compaction": {k: round(sum(c["defects"][k] for c in cs) / len(cs), 3) for k in CLASSES},
               "with_any_defect": sum(1 for c in cs if any(c["defects"].values())),
               "paired_post": {k: sum(c["defects"][k] for c in paired) for k in CLASSES},
               "paired_control": {k: sum(c["control"][k] for c in paired) for k in CLASSES}}
        # a post window can be clipped short of N: compare rates, not counts
        pt = sum(c["post_turns"] for c in paired)
        ct = sum(c["control_turns"] for c in paired)
        row["paired_post_turns"], row["paired_control_turns"] = pt, ct
        row["paired_post_per100"] = {k: round(100.0 * row["paired_post"][k] / pt, 3) if pt else None for k in CLASSES}
        row["paired_control_per100"] = {k: round(100.0 * row["paired_control"][k] / ct, 3) if ct else None
                                        for k in CLASSES}
        costs = [c["cost"] for c in cs if c["cost"]["pre_turn"] is not None and c["cost"]["post_turn"] is not None]
        if costs:
            row["cost"] = {k: round(statistics.mean(x[k] for x in costs)) for k in
                           ("pre_turn", "post_turn", "pre_ctx", "post_ctx", "reprime_cache_create",
                            "compaction_est", "compaction_est_uncached")}
        out[g] = row
    return out


def sim_rollup(per):
    out = {}
    for p in per:
        for g in ("all", "profile:" + p["profile"]):
            r = out.setdefault(g, {"workers": 0, "actual": 0, "b": 0, "c": 0, "b_events": 0, "c_events": 0,
                                   "a_compactions": 0, "workers_with_hop_b": 0})
            r["workers"] += 1
            r["actual"] += p["actual"]
            r["b"] += p["b"]["cost_eq"]
            r["c"] += p["c"]["cost_eq"]
            r["b_events"] += p["b"]["events"]
            r["c_events"] += p["c"]["events"]
            r["a_compactions"] += p["actual_compactions"]
            r["workers_with_hop_b"] += 1 if p["b"]["events"] else 0
    return out


def print_text(out):
    N = out["window"]
    print("workers %d, transcripts %d, compactions %d, window %d turns" % (
        out["workers"], out["transcripts"], len(out["compactions"]), N))
    print("\nper 100 turns, post window / control window, over the paired compactions")
    print("%-22s %5s %6s %7s  %s" % ("group", "comp", "paired", "any-def", "  ".join(
        "%s post/ctl" % k for k in CLASSES)))

    def rate(v):
        return "-" if v is None else "%.2f" % v
    for g, r in out["summary"].items():
        print("%-22s %5d %6d %7d  %s" % (g, r["compactions"], r["paired"], r["with_any_defect"], "  ".join(
            "%*s" % (len(k) + 9, "%s/%s" % (rate(r["paired_post_per100"][k]), rate(r["paired_control_per100"][k])))
            for k in CLASSES)))
    print("\n%-22s %10s %10s %9s %9s %9s %10s" % ("group", "turn-pre", "turn-post", "ctx-pre", "ctx-post",
                                                 "reprime", "compact-est"))
    for g, r in out["summary"].items():
        c = r.get("cost")
        if c:
            print("%-22s %10s %10s %9s %9s %9s %10s" % (
                g, ab.fmt_tok(c["pre_turn"]), ab.fmt_tok(c["post_turn"]), ab.fmt_tok(c["pre_ctx"]),
                ab.fmt_tok(c["post_ctx"]), ab.fmt_tok(c["reprime_cache_create"]), ab.fmt_tok(c["compaction_est"])))
    for s in out.get("simulate", []):
        print("\nsimulated at ceiling %s (post-compaction ctx median %s)" % (ab.fmt_tok(s["ceiling"]),
                                                                          ab.fmt_tok(s["post_ctx_median"])))
        print("%-14s %7s %11s %11s %11s %7s %7s %7s" % ("group", "workers", "a-actual", "b-handoff", "c-compact",
                                                     "a-comp", "b-hops", "c-comp"))
        for g, r in sorted(s["by_profile"].items()):
            print("%-14s %7d %11s %11s %11s %7d %7d %7d" % (
                g, r["workers"], ab.fmt_tok(r["actual"]), ab.fmt_tok(r["b"]), ab.fmt_tok(r["c"]),
                r["a_compactions"], r["b_events"], r["c_events"]))


if __name__ == "__main__":
    sys.exit(main())
