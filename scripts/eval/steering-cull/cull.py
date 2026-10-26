#!/usr/bin/env python3
"""scripts/eval/steering-cull/cull.py - the steering-cull eval, everything but the model calls.

  check                         every row's old span occurs exactly once in its baseline file
  build --arm A --dest D        materialise one arm: D/CLAUDE.md (user scope), D/RTK.md and
                                D/repo/CLAUDE.md (repo scope). A is baseline, cut (every row
                                cut) or red-<row> (baseline with that row's span deleted).
  cost [--sessions DIR ...] [--last N] [--memory F] [--no-agents] [--json]
                                bytes and tokens of the always-on steering text, baseline vs
                                cut, per row and per file, priced on session JSONL usage
  summarize RAW --probe P       score one `claude -p --output-format json` reply -> JSON
  rescore --runs OUT            re-score every saved reply after a probe's checks change, no model call
  valid --runs OUT              the probes that pass BASELINE and fail RED (one per line)
  report --runs OUT [cost options] [--ledger] [--json]
                                the per-row table and verdicts; --ledger appends an eval-runs row

Cost: tokens are UTF-8 bytes // 4 per side. ponytail: a bytes/4 estimate, not the tokenizer's
count; upgrade path: the count_tokens API on the baseline and cut files.
A session pays a steering token once as a cache write (1.25) and then once per later turn as a
cache read (0.1), the cost-eq weights of lib/burn-weights.sh. The repo file is counted without
its `## graphify` section, which the graphify installer owns. AGENTS.md is regenerated from both
repo files with scripts/agents-md/generate.mjs (codex reads it, so it is reported apart).

Verdict per row: SHIP when every valid probe passes on CUT at least as often as on BASELINE;
KEEP when any valid probe passes less often; SHIP-UNMEASURED when every probe of the row is
invalid (it fails BASELINE or passes RED, so the rule moves nothing a probe can see); UNPROBED
when the row has no probe (cost only); PENDING while a probe lacks its runs.
A probe passes an arm when more than half of its scored reps pass.
"""
import argparse
import glob
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
import eval_runs  # noqa: E402

EVAL_ID = "steering-cull"
SOURCE = "scripts/eval/steering-cull/cull.py"
W_IN, W_CC, W_CR, W_OUT = 1.0, 1.25, 0.1, 5.0
GRAPHIFY = "\n## graphify\n"
DEFAULT_SESSIONS = os.path.expanduser("~/.claude/projects/-home-overlord-Documents-github-himmel")


def load(name):
    with open(os.path.join(HERE, name), encoding="utf-8") as fh:
        return json.load(fh)


def rows_doc():
    return load("rows.json")


def probes_doc():
    return load("probes.json")


def baseline(scope, doc=None):
    doc = doc or rows_doc()
    with open(os.path.join(HERE, doc["files"][scope]), encoding="utf-8") as fh:
        return fh.read()


def apply(text, rows, mode):
    for r in rows:
        text = text.replace(r["old"], r["cut"] if mode == "cut" else "", 1)
    return text


def arm_texts(arm, doc=None):
    """{scope: text} for repo and user under one arm, or None for an unknown arm."""
    doc = doc or rows_doc()
    rows = doc["rows"]
    if arm == "baseline":
        pick, mode = [], "cut"
    elif arm == "cut":
        pick, mode = rows, "cut"
    elif arm.startswith("red-") and any(r["id"] == arm[4:] for r in rows):
        pick, mode = [r for r in rows if r["id"] == arm[4:]], "red"
    else:
        return None
    return {s: apply(baseline(s, doc), [r for r in pick if r["scope"] == s], mode) for s in ("repo", "user")}


def cmd_check(_a):
    doc = rows_doc()
    bad = []
    for r in doc["rows"]:
        n = baseline(r["scope"], doc).count(r["old"])
        if n != 1:
            bad.append("%s occurs %d times" % (r["id"], n))
    for s in ("repo", "user"):
        # the spans must not overlap: cutting them one by one leaves no old span half-applied
        t = baseline(s, doc)
        for r in [x for x in doc["rows"] if x["scope"] == s]:
            t = t.replace(r["old"], "\0", 1)
        if t.count("\0") != len([x for x in doc["rows"] if x["scope"] == s]):
            bad.append("%s spans overlap" % s)
    print("; ".join(bad) or "ok")
    return 1 if bad else 0


def cmd_build(a):
    texts = arm_texts(a.arm)
    if texts is None:
        print("cull.py: unknown arm %s (baseline, cut or red-<row id>)" % a.arm, file=sys.stderr)
        return 2
    os.makedirs(os.path.join(a.dest, "repo"), exist_ok=True)
    with open(os.path.join(a.dest, "CLAUDE.md"), "w", encoding="utf-8") as fh:
        fh.write(texts["user"])
    with open(os.path.join(a.dest, "repo", "CLAUDE.md"), "w", encoding="utf-8") as fh:
        fh.write(texts["repo"])
    shutil.copyfile(os.path.join(HERE, rows_doc()["files"]["rtk"]), os.path.join(a.dest, "RTK.md"))
    print(a.dest)
    return 0


def tok(text):
    return len(text.encode("utf-8")) // 4


def counted(scope, text):
    return text[:text.index(GRAPHIFY)] if scope == "repo" and GRAPHIFY in text else text


def session_stats(dirs, last):
    files = []
    for d in dirs:
        files += glob.glob(os.path.join(d, "*.jsonl"))
    files = sorted(files, key=os.path.getmtime)[-last:] if last else files
    turns, reads = [], []
    for p in files:
        seen = {}
        with open(p, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                m = e.get("message") if isinstance(e, dict) else None
                if e.get("type") == "assistant" and isinstance(m, dict) and m.get("id") and isinstance(m.get("usage"), dict):
                    seen[m["id"]] = m["usage"]
        if seen:
            turns.append(len(seen))
            reads += [u.get("cache_read_input_tokens", 0) for u in seen.values()]
    return {"sessions": len(turns), "median_turns": statistics.median(turns) if turns else None,
            "median_cache_read_per_turn": statistics.median(reads) if reads else None}


def agents_bytes(repo_text):
    gen = os.path.join(REPO, "scripts", "agents-md", "generate.mjs")
    if not shutil.which("node") or not os.path.exists(gen):
        return None
    with tempfile.TemporaryDirectory() as td:
        src, out = os.path.join(td, "CLAUDE.md"), os.path.join(td, "AGENTS.md")
        with open(src, "w", encoding="utf-8") as fh:
            fh.write(repo_text)
        env = dict(os.environ, AGENTS_MD_SOURCE=src, AGENTS_MD_TARGET=out)
        r = subprocess.run(["node", gen, "--write"], env=env, capture_output=True, text=True)
        if r.returncode != 0 or not os.path.exists(out):
            return None
        return os.path.getsize(out)


def cost(a):
    doc = rows_doc()
    st = session_stats(a.sessions or [DEFAULT_SESSIONS], a.last)
    turns, read = st["median_turns"], st["median_cache_read_per_turn"]
    per_tok = W_CC + W_CR * (turns - 1) if turns else None
    rows = []
    for r in doc["rows"]:
        t = tok(r["old"]) - tok(r["cut"])
        rows.append({"id": r["id"], "num": r["num"], "scope": r["scope"], "lines": r["lines"],
                     "bytes_saved": len(r["old"].encode()) - len(r["cut"].encode()), "tokens_saved": t,
                     "cost_eq_per_session": round(t * per_tok, 1) if per_tok is not None else None,
                     "per_turn_share": round(t / read, 6) if read else None})
    files = []
    base, cut = arm_texts("baseline", doc), arm_texts("cut", doc)
    for s in ("repo", "user"):
        b, c = counted(s, base[s]), counted(s, cut[s])
        files.append({"file": s, "baseline_bytes": len(b.encode()), "cut_bytes": len(c.encode()),
                      "baseline_tokens": tok(b), "cut_tokens": tok(c)})
    rtk = open(os.path.join(HERE, doc["files"]["rtk"]), encoding="utf-8").read()
    files.append({"file": "rtk", "baseline_bytes": len(rtk.encode()), "cut_bytes": len(rtk.encode()),
                  "baseline_tokens": tok(rtk), "cut_tokens": tok(rtk)})
    if a.memory and os.path.exists(a.memory):
        m = open(a.memory, encoding="utf-8").read()
        files.append({"file": "memory-index", "baseline_bytes": len(m.encode()), "cut_bytes": len(m.encode()),
                      "baseline_tokens": tok(m), "cut_tokens": tok(m), "note": "batches 4-5 already applied; not cut here"})
    if not a.no_agents:
        ab, ac = agents_bytes(base["repo"]), agents_bytes(cut["repo"])
        files.append({"file": "AGENTS.md (codex)", "baseline_bytes": ab, "cut_bytes": ac,
                      "baseline_tokens": ab // 4 if ab is not None else None,
                      "cut_tokens": ac // 4 if ac is not None else None})
    claude = [f for f in files if f["file"] in ("repo", "user", "rtk", "memory-index")]
    total = {"baseline_tokens": sum(f["baseline_tokens"] for f in claude), "cut_tokens": sum(f["cut_tokens"] for f in claude)}
    total["tokens_saved"] = total["baseline_tokens"] - total["cut_tokens"]
    total["cost_eq_per_session"] = round(total["tokens_saved"] * per_tok, 1) if per_tok is not None else None
    total["per_turn_share"] = round(total["tokens_saved"] / read, 6) if read else None
    return {"sessions": st, "rows": rows, "files": files, "total": total}


def cmd_cost(a):
    c = cost(a)
    if a.json:
        print(json.dumps(c, indent=1))
        return 0
    print(cost_table(c))
    return 0


def cost_table(c):
    out = ["| file | baseline bytes | cut bytes | baseline tokens | cut tokens |", "|---|---|---|---|---|"]
    for f in c["files"]:
        out.append("| %s | %s | %s | %s | %s |" % (f["file"], f["baseline_bytes"], f["cut_bytes"], f["baseline_tokens"], f["cut_tokens"]))
    t, s = c["total"], c["sessions"]
    out.append("")
    out.append("Claude always-on total: %d to %d tokens (-%d), %s cost-eq per session, %s of a turn's cache read; "
               "priced on %d sessions (median %s turns, median cache read %s per turn)."
               % (t["baseline_tokens"], t["cut_tokens"], t["tokens_saved"], t["cost_eq_per_session"],
                  t["per_turn_share"], s["sessions"], s["median_turns"], s["median_cache_read_per_turn"]))
    return "\n".join(out)


def first_line(text):
    for line in text.splitlines():
        s = re.sub(r"[*_`#>\s]+", " ", line).strip()
        if s:
            return s
    return ""


def code_of(reply):
    """The fenced blocks of a reply, or all of it when it has none."""
    blocks = re.findall(r"^```[^\n]*\n(.*?)^```", reply, re.M | re.S)
    return "\n".join(blocks) if blocks else reply


def score(probe, reply):
    fl = first_line(reply)
    body = code_of(reply) if probe.get("in") == "code" else reply
    ok = all(re.search(rx, fl, re.I) for rx in probe.get("first", []))
    ok = ok and all(re.search(rx, body, re.I | re.M) for rx in probe.get("must", []))
    ok = ok and not any(re.search(rx, body, re.I | re.M) for rx in probe.get("must_not", []))
    return ok


def probe_by_id(pid):
    for p in probes_doc()["probes"]:
        if p["id"] == pid:
            return p
    return None


def usage_cost(d):
    u = d.get("usage") if isinstance(d, dict) else None
    if not isinstance(u, dict):
        return None
    return round(u.get("input_tokens", 0) * W_IN + u.get("cache_creation_input_tokens", 0) * W_CC
                 + u.get("cache_read_input_tokens", 0) * W_CR + u.get("output_tokens", 0) * W_OUT, 1)


def summarize(raw, probe):
    """An errored run still carries the cost-eq of any usage it reports, so run.sh can bill it."""
    d = None
    try:
        with open(raw, encoding="utf-8") as fh:
            d = json.load(fh)
        reply = d["result"]
        if d.get("is_error") or not isinstance(reply, str):
            raise ValueError("error result")
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {"file": raw, "probe": probe["id"], "error": True, "pass": None, "cost_eq": usage_cost(d), "reply": None}
    return {"file": raw, "probe": probe["id"], "error": False, "pass": score(probe, reply),
            "cost_eq": usage_cost(d) or 0.0, "cost_usd": d.get("total_cost_usd"), "reply": reply[:600]}


def cmd_summarize(a):
    p = probe_by_id(a.probe)
    if p is None:
        print("cull.py: unknown probe %s" % a.probe, file=sys.stderr)
        return 2
    print(json.dumps(summarize(a.raw, p), indent=1))
    return 0


def cmd_rescore(a):
    """Re-derive every <probe>/<arm>/<rep>.summary.json from its saved .raw.json, no model call."""
    n = 0
    for raw in sorted(glob.glob(os.path.join(a.runs, "*", "*", "*.raw.json"))):
        p = probe_by_id(os.path.basename(os.path.dirname(os.path.dirname(raw))))
        s = summarize(raw, p) if p else None
        if s is None or s["error"]:
            continue
        with open(raw[:-len(".raw.json")] + ".summary.json", "w") as fh:
            json.dump(s, fh, indent=1)
        n += 1
    print("rescored %d runs" % n)
    return 0


def tallies(runs):
    """{probe: {arm: [passes, scored]}} from <runs>/<probe>/<arm>/<rep>.summary.json."""
    out = {}
    for p in glob.glob(os.path.join(runs, "*", "*", "*.summary.json")):
        arm_dir = os.path.dirname(p)
        probe, arm = os.path.basename(os.path.dirname(arm_dir)), os.path.basename(arm_dir)
        try:
            s = json.load(open(p))
        except (OSError, ValueError):
            continue
        if s.get("error"):
            continue
        t = out.setdefault(probe, {}).setdefault(arm, [0, 0])
        t[0] += 1 if s.get("pass") else 0
        t[1] += 1
    return out


def passes(t):
    return t is not None and t[1] > 0 and t[0] * 2 > t[1]


def run_config(runs):
    path = os.path.join(runs, "run-config.json")
    return json.load(open(path)) if os.path.exists(path) else {}


def want_reps(runs, tl):
    """The reps every arm needs before it counts: run.sh's --reps, else the most any arm has."""
    return run_config(runs).get("reps") or max([x[1] for t in tl.values() for x in t.values()] or [1])


def complete(t, want):
    return bool(t) and t[1] >= want


def probe_state(p, t, want):
    """valid | invalid | pending for the RED-first gate."""
    base, red = t.get("baseline"), t.get("red-" + p["row"])
    if not complete(base, want) or not complete(red, want):
        return "pending"
    return "valid" if passes(base) and not passes(red) else "invalid"


def cmd_valid(a):
    tl = tallies(a.runs)
    want = want_reps(a.runs, tl)
    for p in sorted(probes_doc()["probes"], key=lambda x: x["id"]):
        if probe_state(p, tl.get(p["id"], {}), want) == "valid":
            print(p["id"])
    return 0


def frac(t):
    return "%d/%d" % (t[0], t[1]) if t and t[1] else "-"


def verdicts(runs):
    tl = tallies(runs)
    want = want_reps(runs, tl)
    probes = probes_doc()["probes"]
    out = {}
    for r in rows_doc()["rows"]:
        mine = [p for p in probes if p["row"] == r["id"]]
        detail = []
        states = []
        for p in mine:
            t = tl.get(p["id"], {})
            st = probe_state(p, t, want)
            cut = t.get("cut")
            if st == "valid":
                if not complete(cut, want):
                    st = "pending"
                else:
                    st = "worse" if cut[0] / cut[1] < t["baseline"][0] / t["baseline"][1] else "held"
            states.append(st)
            detail.append({"probe": p["id"], "state": st, "baseline": frac(t.get("baseline")),
                           "red": frac(t.get("red-" + r["id"])), "cut": frac(cut)})
        if not mine:
            v = "UNPROBED"
        elif "pending" in states:
            v = "PENDING"
        elif "worse" in states:
            v = "KEEP"
        elif "held" in states:
            v = "SHIP"
        else:
            v = "SHIP-UNMEASURED"
        out[r["id"]] = {"verdict": v, "probes": detail}
    return out, tl


def cmd_report(a):
    c = cost(a)
    vd, tl = verdicts(a.runs)
    costs = {r["id"]: r for r in c["rows"]}
    lines = ["| row | num | lines | scope | bytes saved | tokens saved | cost-eq per session | per-turn share | probes (BASELINE / RED / CUT) | verdict |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows_doc()["rows"]:
        cr, v = costs[r["id"]], vd[r["id"]]
        pr = "; ".join("%s %s %s / %s / %s" % (d["probe"], d["state"], d["baseline"], d["red"], d["cut"]) for d in v["probes"]) or "-"
        lines.append("| %s | %s | %s | %s | %d | %d | %s | %s | %s | %s |" % (
            r["id"], r["num"], r["lines"], r["scope"], cr["bytes_saved"], cr["tokens_saved"],
            cr["cost_eq_per_session"], cr["per_turn_share"], pr, v["verdict"]))
    text = "\n".join(lines) + "\n\n" + cost_table(c)
    if a.json:
        print(json.dumps({"cost": c, "verdicts": vd}, indent=1))
    else:
        print(text)
    if a.ledger:
        write_ledger(a, c, vd, tl)
    return 0


def write_ledger(a, c, vd, tl):
    counts = {}
    for v in vd.values():
        counts[v["verdict"]] = counts.get(v["verdict"], 0) + 1
    cases = {}
    want = want_reps(a.runs, tl)
    for p in probes_doc()["probes"]:
        t = tl.get(p["id"])
        if not t:
            continue
        cases[p["id"]] = {"baseline": round(t["baseline"][0] / t["baseline"][1], 3) if t.get("baseline", [0, 0])[1] else None,
                          "red": round(t["red-" + p["row"]][0] / t["red-" + p["row"]][1], 3) if t.get("red-" + p["row"], [0, 0])[1] else None,
                          "cut": round(t["cut"][0] / t["cut"][1], 3) if t.get("cut", [0, 0])[1] else None,
                          "valid": probe_state(p, t, want) == "valid"}
    rc = run_config(a.runs)
    reps = max([x[1] for t in tl.values() for x in t.values()] or [0])
    metrics = {"tokens_saved": c["total"]["tokens_saved"], "cost_eq_per_session_saved": c["total"]["cost_eq_per_session"],
               "per_turn_share_saved": c["total"]["per_turn_share"],
               "probes_valid": sum(1 for x in cases.values() if x["valid"]), "probes_run": len(cases)}
    for k in ("SHIP", "KEEP", "SHIP-UNMEASURED", "UNPROBED", "PENDING"):
        metrics["rows_" + k.lower().replace("-", "_")] = counts.get(k, 0)
    config = {"steering_cull_v": 1, "model": rc.get("model"), "effort": rc.get("effort"),
              "rows_sha": eval_runs.config_hash([{k: r[k] for k in ("id", "scope", "old", "cut")} for r in rows_doc()["rows"]]),
              "probes_sha": eval_runs.config_hash([probes_doc()["preamble"]] + [
                  {k: p[k] for k in ("id", "row", "prompt", "first", "must", "must_not", "in") if k in p}
                  for p in probes_doc()["probes"]])}
    row = eval_runs.make_row(EVAL_ID, SOURCE, config, metrics, n=len(cases), model=rc.get("model"), lane="native",
                             status="ok" if counts.get("PENDING", 0) == 0 and cases else "partial",
                             cases=cases, artifact=os.path.abspath(a.runs), reps=reps, repo=REPO)
    eval_runs.append_safe(row, None, who=EVAL_ID)


def main():
    ap = argparse.ArgumentParser(prog="cull.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("check")
    b = sub.add_parser("build")
    b.add_argument("--arm", required=True)
    b.add_argument("--dest", required=True)
    for name in ("cost", "report"):
        c = sub.add_parser(name)
        c.add_argument("--sessions", action="append")
        c.add_argument("--last", type=int, default=50)
        c.add_argument("--memory")
        c.add_argument("--no-agents", action="store_true")
        c.add_argument("--json", action="store_true")
        if name == "report":
            c.add_argument("--runs", required=True)
            c.add_argument("--ledger", action="store_true")
    s = sub.add_parser("summarize")
    s.add_argument("raw")
    s.add_argument("--probe", required=True)
    for name in ("valid", "rescore"):
        sub.add_parser(name).add_argument("--runs", required=True)
    a = ap.parse_args()
    return {"check": cmd_check, "build": cmd_build, "cost": cmd_cost, "summarize": cmd_summarize,
            "valid": cmd_valid, "rescore": cmd_rescore, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
