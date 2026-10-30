#!/usr/bin/env python3
"""scripts/eval/compaction-handoff/ab_tasks.py - the three long tasks of the phase 2 A/B.

Each task generates its workspace from a seed (nothing large is committed), states a few
rulings and a token in its brief only, and has a hidden deterministic check. A ruling the
worker loses to a compaction or a hand-off shows up as a failed check, not as an opinion.

  docs   a docs truth wave: ~100 pages rewritten under 4 rulings            (profile docs)
  impl   ~60 modules implemented from specs, a late ruling overrides a spec  (profile impl)
  audit  ~80 report/source pairs compared, discrepancies filed by severity   (profile eval)

  ab_tasks.py gen|solve|check <task> <dir> [--seed N] [--scale F]
  ab_tasks.py brief <task> [--seed N] [--scale F]
  ab_tasks.py profile <task>

--scale shrinks the page/module/pair count (the suite runs at 0.05). `solve` writes the
correct answer into a workspace: the suite uses it as the stub model, and it proves each
check can be satisfied. Stdlib only; no network, no model call.
"""
import argparse
import hashlib
import importlib.util
import json
import os
import random
import re
import shutil
import signal
import sys
import tempfile

EXEC_SECS = 2   # one worker-written module may run this long inside the checker
PROFILE = {"docs": "docs", "impl": "impl", "audit": "eval"}
BASE = {"docs": 100, "impl": 60, "audit": 80}
ADJ = ["quiet", "steady", "narrow", "broad", "careful", "early", "late", "plain", "stable", "shared",
       "local", "remote", "frozen", "open", "small", "large", "slow", "quick", "bounded", "typed"]
NOUN = ["ticket", "queue", "ledger", "branch", "report", "session", "window", "record", "worker", "chief",
        "script", "suite", "hook", "gate", "lock", "token", "marker", "digest", "budget", "cache",
        "page", "table", "module", "config", "profile", "review", "verdict", "shard", "index", "bundle"]
VERB = ["reads", "writes", "checks", "holds", "moves", "records", "skips", "merges", "counts", "marks",
        "lists", "opens", "closes", "pins", "sorts", "ships", "clears", "builds", "fetches", "stores"]
PREP = ["before", "after", "beside", "under", "within", "against", "through", "across"]
UNITS = ["ms", "kb", "runs", "pages", "turns", "calls", "files", "rows"]
for _w in ADJ + NOUN + VERB + PREP + UNITS:
    assert "leg" not in _w and "FIG" not in _w, _w   # the docs check hunts the standalone word "leg"


def nsize(task, scale):
    return max(4, round(BASE[task] * float(scale)))


def token(task, seed):
    return "EV-N7-" + hashlib.sha256(("%s:%s" % (task, seed)).encode()).hexdigest()[:8]


def sentence(rng):
    return "The %s %s %s the %s %s %s the %s." % (
        rng.choice(ADJ), rng.choice(NOUN), rng.choice(VERB),
        rng.choice(ADJ), rng.choice(NOUN), rng.choice(PREP), rng.choice(NOUN))


def para(rng, n=5):
    return " ".join(sentence(rng) for _ in range(n))


def paras(rng, n):
    return [para(rng) for _ in range(n)]


def write(root, rel, text):
    p = os.path.join(root, rel)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as fh:
        fh.write(text)


def read(root, rel):
    try:
        with open(os.path.join(root, rel), errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


# ---------------------------------------------------------------- docs
def docs_frozen(nn):
    return nn % 4 == 0


def docs_path(nn):
    return "docs/%spage-%03d.md" % ("frozen/" if docs_frozen(nn) else "", nn)


LEG_SENTENCES = ["In this flow the leg reads the ticket before it acts.", "Each leg keeps its own lock.",
                 "Leg state lives in the handover document.", "A leg that stalls is closed by its chief."]
KEEP_SENTENCES = ["The legacy mapping stays as it is.", "See the legend below the table."]


def docs_gen(ws, seed, scale):
    rng = random.Random(seed * 1000 + 1)
    for nn in range(1, nsize("docs", scale) + 1):
        body = paras(rng, 28)
        for s in rng.sample(LEG_SENTENCES, rng.randint(2, 3)) + rng.sample(KEEP_SENTENCES, 1):
            body[rng.randrange(len(body))] += " " + s
        head = "<!-- FROZEN: do not edit -->\n" if docs_frozen(nn) else ""
        write(ws, docs_path(nn), "%s# Page %03d\n\n%s\n\nref: pending\n" % (head, nn, "\n\n".join(body)))


def docs_brief(seed, scale):
    t = token("docs", seed)
    return (
        "You are leg EV-N7, running a docs truth wave in the current directory (the pages are under docs/).\n"
        "These rulings come from your chief; they are in no file, so keep them.\n"
        "R1  Replace the standalone word \"leg\" with \"worker\" on every page (\"Leg\" becomes \"Worker\"). Leave words that\n"
        "    merely contain it (legacy, legend) alone.\n"
        "R2  The last line of every page you edit must be exactly `ref: %s-NNN`, NNN the 3-digit page number.\n"
        "R3  Pages under docs/frozen/ are frozen. Do not edit them, not even for R1 or R2.\n"
        "R4  When the pages are done, write REPORT.md: line 1 `token: %s`, line 2 `edited: K`, K the number of pages you edited.\n"
        "Method: take the pages in numeric order, open each with the Read tool in full before you edit it, and edit with the\n"
        "Edit tool. No scripts and no bulk sed over the pages. Finish with one line: DONE." % (t, t))


def docs_check(ws, seed, scale):
    ref = tempfile.mkdtemp(prefix="ab-ref-")
    try:
        docs_gen(ref, seed, scale)
        t, res, passed, total = token("docs", seed), [], 0, 0
        edited = 0
        for nn in range(1, nsize("docs", scale) + 1):
            got, want = read(ws, docs_path(nn)), read(ref, docs_path(nn))
            if docs_frozen(nn):
                ok = got == want
                res.append(("frozen-%03d" % nn, ok))
                continue
            edited += 1
            lines = (got or "").rstrip("\n").split("\n")
            res.append(("leg-%03d" % nn, got is not None and not re.search(r"\b[Ll]eg\b", got)
                        and got.count("legacy") == want.count("legacy") and got.count("legend") == want.count("legend")))
            res.append(("ref-%03d" % nn, lines[-1] == "ref: %s-%03d" % (t, nn)))
        rep = (read(ws, "REPORT.md") or "").split("\n")
        res.append(("report-token", rep[0].strip() == "token: " + t))
        res.append(("report-count", len(rep) > 1 and rep[1].strip() == "edited: %d" % edited))
        return pack(res)
    finally:
        shutil.rmtree(ref, ignore_errors=True)


def docs_solve(ws, seed, scale):
    t = token("docs", seed)
    n = nsize("docs", scale)
    edited = 0
    for nn in range(1, n + 1):
        if docs_frozen(nn):
            continue
        edited += 1
        txt = read(ws, docs_path(nn))
        txt = re.sub(r"\bLeg\b", "Worker", re.sub(r"\bleg\b", "worker", txt))
        txt = txt.replace("ref: pending", "ref: %s-%03d" % (t, nn))
        write(ws, docs_path(nn), txt)
    write(ws, "REPORT.md", "token: %s\nedited: %d\n" % (t, edited))


# ---------------------------------------------------------------- impl
def impl_params(rng):
    m = rng.randint(97, 997)
    return {"K": rng.randint(2, 9), "C": rng.randint(1, m - 1), "M": m, "K0": rng.randint(2, 9), "C0": rng.randint(1, m - 1)}


def impl_late(n):
    return max(3, int(n * 2 / 3) + 1)


def impl_one(rng, nn):
    """(params, module text, spec text) of module nn; one place draws from rng."""
    p = impl_params(rng)
    mod = ('"""Module %03d.\n\n%s\n"""\n\n\ndef f_%03d(x):\n    # TODO: implement per specs/spec_%03d.txt\n    return x\n'
           % (nn, "\n\n".join(paras(rng, 12)), nn, nn))
    body = paras(rng, 16)
    body.insert(rng.randrange(len(body)), "SUPERSEDED: f_%03d(x) returned (x * %d + %d) %% %d." % (nn, p["K0"], p["C0"], p["M"]))
    body.insert(rng.randrange(len(body)), "RULE: f_%03d(x) returns (x * %d + %d) %% %d." % (nn, p["K"], p["C"], p["M"]))
    return p, mod, "\n\n".join(body) + "\n"


def impl_gen(ws, seed, scale):
    rng = random.Random(seed * 1000 + 2)
    write(ws, "config/consts.json", json.dumps({"scale": rng.randint(10, 19)}) + "\n")
    for nn in range(1, nsize("impl", scale) + 1):
        _, mod, spec = impl_one(rng, nn)
        write(ws, "pkg/mod_%03d.py" % nn, mod)
        write(ws, "specs/spec_%03d.txt" % nn, spec)


def impl_expected(seed, scale):
    """{nn: (K, C, M)} with the late ruling applied."""
    rng = random.Random(seed * 1000 + 2)
    n = nsize("impl", scale)
    scale_k = rng.randint(10, 19)
    out = {}
    for nn in range(1, n + 1):
        p = impl_one(rng, nn)[0]
        out[nn] = (scale_k if nn >= impl_late(n) else p["K"], p["C"], p["M"])
    return out


def impl_brief(seed, scale):
    t = token("impl", seed)
    n = nsize("impl", scale)
    return (
        "You are leg EV-N7, implementing modules in the current directory: pkg/mod_NNN.py each holds a stub f_NNN(x), and\n"
        "specs/spec_NNN.txt holds its rule. These rulings come from your chief; they are in no file, so keep them.\n"
        "R1  Implement every f_NNN as its spec's RULE line says. A line marked SUPERSEDED is dead; ignore it.\n"
        "R2  For modules %03d and above, ignore the spec's K: use the `scale` value in config/consts.json as K (C and M stay\n"
        "    the spec's).\n"
        "R3  Do not edit specs/ or config/.\n"
        "R4  When the modules are done, write NOTES.md with `token: %s` as its first line.\n"
        "Method: take the modules in numeric order, open the spec and the module with the Read tool in full before you edit the\n"
        "module, and edit with the Edit tool. No scripts that write the modules in bulk. Finish with one line: DONE."
        % (impl_late(n), t))


def _timed_out(signum, frame):
    raise TimeoutError("worker module ran past %ds" % EXEC_SECS)


def impl_check(ws, seed, scale):
    res = []
    old = signal.signal(signal.SIGALRM, _timed_out)
    try:
        for nn, (k, c, m) in impl_expected(seed, scale).items():
            ok = False
            src = read(ws, "pkg/mod_%03d.py" % nn)
            if src:
                ns = {}
                signal.alarm(EXEC_SECS)
                try:   # worker-written code: a raise, an exit or a loop fails its row, never the driver
                    exec(compile(src, "mod_%03d" % nn, "exec"), ns)
                    ok = all(ns["f_%03d" % nn](x) == (x * k + c) % m for x in range(6))
                except (Exception, SystemExit):
                    ok = False
                finally:
                    signal.alarm(0)
            res.append(("mod-%03d" % nn, ok))
    finally:
        signal.signal(signal.SIGALRM, old)
    notes = (read(ws, "NOTES.md") or "").split("\n")
    res.append(("notes-token", notes[0].strip() == "token: " + token("impl", seed)))
    ref = tempfile.mkdtemp(prefix="ab-impl-ref-")
    try:
        impl_gen(ref, seed, scale)
        n = nsize("impl", scale)
        same = read(ws, "config/consts.json") == read(ref, "config/consts.json") and all(
            read(ws, "specs/spec_%03d.txt" % nn) == read(ref, "specs/spec_%03d.txt" % nn) for nn in range(1, n + 1))
        res.append(("specs-config-untouched", same))
    finally:
        shutil.rmtree(ref, ignore_errors=True)
    return pack(res)


def impl_solve(ws, seed, scale):
    for nn, (k, c, m) in impl_expected(seed, scale).items():
        write(ws, "pkg/mod_%03d.py" % nn, "def f_%03d(x):\n    return (x * %d + %d) %% %d\n" % (nn, k, c, m))
    write(ws, "NOTES.md", "token: %s\n" % token("impl", seed))


# ---------------------------------------------------------------- audit
def audit_withdrawn(nn):
    return nn % 5 == 2


def audit_build(seed, scale):
    """(sources, reports, expected) with expected {(nn, fig): severity}."""
    rng = random.Random(seed * 1000 + 3)
    src, rep, exp = {}, {}, {}
    for nn in range(1, nsize("audit", scale) + 1):
        figs = [("FIG-%03d-%d" % (nn, k), rng.randint(100, 9999), rng.choice(UNITS)) for k in range(1, 9)]
        body = paras(rng, 10)
        lines = ["%s: %d %s" % f for f in figs]
        for ln in lines:
            body.insert(rng.randrange(len(body) + 1), ln)
        src["source/doc-%03d.txt" % nn] = "\n\n".join(body) + "\n"
        bad = {f[0]: rng.choice([8, 12, 15, 35, 45, 60]) for f in rng.sample(figs, 2)}
        out = []
        for name, val, unit in figs:
            if name in bad:
                new = round(val * (1 + bad[name] / 100.0))
                out.append("%s: %d %s" % (name, new, unit))
                if not audit_withdrawn(nn):
                    exp[(nn, name)] = "high" if bad[name] >= 20 else "low"
            else:
                out.append("%s: %d %s" % (name, val, unit))
        rep["report/rep-%03d.txt" % nn] = "\n\n".join(paras(rng, 5)) + "\n\nFigures\n" + "\n".join(out) + "\n"
    return src, rep, exp


def audit_gen(ws, seed, scale):
    src, rep, _ = audit_build(seed, scale)
    for rel, txt in list(src.items()) + list(rep.items()):
        write(ws, rel, txt)


def audit_brief(seed, scale):
    t = token("audit", seed)
    w = ", ".join(str(n) for n in range(1, nsize("audit", scale) + 1) if audit_withdrawn(n))
    return (
        "You are leg EV-N7, auditing report/rep-NNN.txt against source/doc-NNN.txt in the current directory. Each report\n"
        "restates 8 figures (FIG-NNN-k) from its source; some restated values differ. These rulings come from your chief; they\n"
        "are in no file, so keep them.\n"
        "R1  File one finding per figure whose report value differs from its source value. Severity is `high` when the report\n"
        "    value is 20 %% or more away from the source value, otherwise `low`.\n"
        "R2  Pairs %s are withdrawn: audit nothing there, file nothing for them.\n"
        "R3  Write findings.jsonl: line 1 `# token: %s`, then one JSON object per finding, {\"pair\": N, \"fig\": \"FIG-NNN-k\",\n"
        "    \"severity\": \"high\" or \"low\"}.\n"
        "Method: take the pairs in numeric order, open both files with the Read tool in full, compare by reading. No scripts that\n"
        "diff the pairs in bulk. Finish with one line: DONE." % (w, t))


def audit_check(ws, seed, scale):
    _, _, exp = audit_build(seed, scale)
    lines = (read(ws, "findings.jsonl") or "").split("\n")
    got, bad_lines = {}, 0
    for ln in lines[1:]:
        if not ln.strip():
            continue
        try:
            d = json.loads(ln)
            got[(int(d["pair"]), d["fig"])] = d.get("severity")
        except (ValueError, KeyError, TypeError):
            bad_lines += 1
    res = []
    for key, sev in sorted(exp.items()):
        res.append(("found-%s" % key[1], key in got))
        res.append(("severity-%s" % key[1], got.get(key) == sev))
    for nn in range(1, nsize("audit", scale) + 1):
        if audit_withdrawn(nn):
            res.append(("withdrawn-%03d" % nn, not any(k[0] == nn for k in got)))
    res.append(("token", lines[0].strip() == "# token: " + token("audit", seed)))
    extra = [k for k in got if k not in exp and not audit_withdrawn(k[0])]
    res += [("false-positive-%s" % k[1], False) for k in extra]
    return pack(res + [("malformed-line", False)] * bad_lines)


def audit_solve(ws, seed, scale):
    _, _, exp = audit_build(seed, scale)
    out = ["# token: " + token("audit", seed)]
    out += [json.dumps({"pair": k[0], "fig": k[1], "severity": s}) for k, s in sorted(exp.items())]
    write(ws, "findings.jsonl", "\n".join(out) + "\n")


# ---------------------------------------------------------------- shared
def pack(res):
    return {"passed": sum(1 for _, ok in res if ok), "total": len(res), "failed": [n for n, ok in res if not ok][:20]}


TASKS = {"docs": (docs_gen, docs_brief, docs_check, docs_solve),
         "impl": (impl_gen, impl_brief, impl_check, impl_solve),
         "audit": (audit_gen, audit_brief, audit_check, audit_solve)}


def gen(task, ws, seed=1, scale=1.0):
    os.makedirs(ws, exist_ok=True)
    TASKS[task][0](ws, int(seed), scale)


def brief(task, seed=1, scale=1.0):
    return TASKS[task][1](int(seed), scale)


def check(task, ws, seed=1, scale=1.0):
    return TASKS[task][2](ws, int(seed), scale)


def solve(task, ws, seed=1, scale=1.0):
    TASKS[task][3](ws, int(seed), scale)


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["gen", "solve", "check", "brief", "profile"])
    ap.add_argument("task", choices=sorted(TASKS))
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--scale", type=float, default=1.0)
    a = ap.parse_args(argv)
    if a.cmd == "profile":
        print(PROFILE[a.task])
    elif a.cmd == "brief":
        print(brief(a.task, a.seed, a.scale))
    else:
        if not a.dir:
            ap.error("%s needs a directory" % a.cmd)
        if a.cmd == "check":
            print(json.dumps(check(a.task, a.dir, a.seed, a.scale)))
        else:
            {"gen": gen, "solve": solve}[a.cmd](a.task, a.dir, a.seed, a.scale)
    return 0


if __name__ == "__main__":
    sys.exit(main())
