#!/usr/bin/env python3
# Stub `claude` for test-compaction-ab.sh: emits stream-json shaped like a headless run,
# no model call. Every invocation appends {"args": [...], "cwd": ...} to $AB_STUB_LOG.
#   AB_STUB_TASK/SEED/SCALE  the task it "solves" in its cwd (ab_tasks.py solve)
#   AB_STUB_MSGS, AB_STUB_STEP  assistant messages per run, context growth per message
#   AB_STUB_HANG=1  sleep once the context passes 337500, so the driver must stop it
#   AB_STUB_SKIP_SOLVE=1  leave the workspace unsolved
#   AB_STUB_PRE  pre_tokens to report on a compaction (default: the context that crossed the line)
#   AB_STUB_NOBOUNDARY=1  drop the context without a compact_boundary event
#   AB_STUB_RESUME_FAIL=1 / AB_STUB_NOWRITE=1  the --resume segment errors / writes no HANDOFF.md
#   AB_STUB_STALE=1  the first segment leaves a HANDOFF.md behind
#   AB_STUB_NOSCORE=1  the judge replies without a SCORE line
# A compaction fires when the next context would pass 85 % of --autocompact; the
# context then restarts at 20000. --resume writes HANDOFF.md; a prompt starting
# "Load HANDOFF.md" is the successor; "Rate the work" is the judge.
import json
import os
import subprocess
import sys
import time

a = sys.argv[1:]
prompt = a[a.index("-p") + 1]
ceil = int(a[a.index("--autocompact") + 1]) if "--autocompact" in a else 200000
step = int(os.environ.get("AB_STUB_STEP", "60000"))
n = int(os.environ.get("AB_STUB_MSGS", "8"))
with open(os.environ["AB_STUB_LOG"], "a") as fh:
    in_git = subprocess.run(["git", "rev-parse", "--git-dir"], capture_output=True).returncode == 0
    fh.write(json.dumps({"args": a, "cwd": os.getcwd(), "in_git": in_git}) + "\n")


def emit(o):
    print(json.dumps(o), flush=True)


def msg(i, ctx, text=""):
    emit({"type": "assistant", "message": {"id": "m-%d-%d" % (os.getpid(), i), "role": "assistant",
          "content": [{"type": "text", "text": text}],
          "usage": {"input_tokens": 0, "cache_read_input_tokens": ctx - 1000,
                    "cache_creation_input_tokens": 1000, "output_tokens": 100}}})


def result(text="DONE"):
    emit({"type": "result", "subtype": "success", "is_error": False, "result": text,
          "total_cost_usd": 0.5, "duration_ms": 1000, "num_turns": n, "usage": {}})


def solve():
    if os.environ.get("AB_STUB_SKIP_SOLVE") != "1":
        here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        subprocess.run([sys.executable, os.path.join(here, "ab_tasks.py"), "solve", os.environ["AB_STUB_TASK"], ".",
                        "--seed", os.environ.get("AB_STUB_SEED", "1"), "--scale", os.environ.get("AB_STUB_SCALE", "1")],
                       check=True)


if "Rate the work" in prompt:
    msg(1, 5000)
    result("The work is mostly right." if os.environ.get("AB_STUB_NOSCORE") == "1" else "The work is mostly right.\nSCORE: 8")
elif "--resume" in a:
    if os.environ.get("AB_STUB_RESUME_FAIL") == "1":
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "failed"})
        sys.exit(1)
    if os.environ.get("AB_STUB_NOWRITE") != "1":
        open("HANDOFF.md", "w").write("# hand-off\nrulings and token go here\n")
    msg(1, step)
    result("hand-off written")
elif prompt.startswith("Load HANDOFF.md"):
    if not os.path.exists("HANDOFF.md"):
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": "no HANDOFF.md"})
        sys.exit(1)
    solve()
    msg(1, step)
    result()
else:
    ctx = 0
    if os.environ.get("AB_STUB_STALE") == "1":
        open("HANDOFF.md", "w").write("# stale\n")
    for i in range(1, n + 1):
        if ctx + step > ceil * 0.85:
            if os.environ.get("AB_STUB_NOBOUNDARY") != "1":
                emit({"type": "system", "subtype": "compact_boundary",
                      "compact_metadata": {"trigger": "auto", "pre_tokens": int(os.environ.get("AB_STUB_PRE", ctx + step))}})
            ctx = 20000
        else:
            ctx += step
        msg(i, ctx)
        if os.environ.get("AB_STUB_HANG") == "1" and ctx >= 337500:
            time.sleep(60)
    solve()
    result()
