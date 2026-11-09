#!/usr/bin/env python3
"""Writes the B3 route-row fixture scenarios into OUT/<name>/: a session transcript
(transcript.jsonl, the Claude session JSONL shape), the host broker's private events
(meta/events.jsonl, the s-qmd serve shape) and the CLI result (result.json).
Usage: build.py OUT
"""
import json, os, sys

OUT = sys.argv[1]
LOCK = "/work/himmel/docs/lock.md"
ZETA = "/work/himmel/docs/zeta.md"


def tu(i, name, **inp):
    return {"type": "assistant", "message": {"content": [{"type": "tool_use", "id": "toolu_%02d" % i, "name": name, "input": inp}]}}


def tr(i, text, err=False):
    return {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_%02d" % i, "content": text, "is_error": err}]}}


def qmd_out(*paths):
    return "s-qmd: %d results\n" % len(paths) + "\n".join("%d. %s:2  T\n   line" % (k, p) for k, p in enumerate(paths, 1))


def admit(i, phase="answer"):
    return {"kind": "admit", "id": "%s-%02d-aaaaaa" % (phase, i), "phase": phase}


def term(i, phase="answer", reasons=(), dropped=0, kept=1, expansion="expanded"):
    return {"kind": "terminal", "id": "%s-%02d-aaaaaa" % (phase, i), "phase": phase, "skip": bool(reasons),
            "skip_reasons": list(reasons), "dropped": dropped, "kept": kept, "expansion": expansion}


def answer(text, cost=0.12, **kw):
    r = {"type": "result", "subtype": "success", "is_error": False, "result": text, "total_cost_usd": cost,
         "usage": {"input_tokens": 100, "output_tokens": 50}}
    r.update(kw)
    return r


def write(name, transcript, events, result, raw_result=None):
    d = os.path.join(OUT, name)
    os.makedirs(os.path.join(d, "meta"), exist_ok=True)
    with open(os.path.join(d, "transcript.jsonl"), "w") as f:
        for e in transcript:
            f.write(json.dumps(e) + "\n")
    with open(os.path.join(d, "meta", "events.jsonl"), "w") as f:
        for e in events:
            f.write(json.dumps(e) + "\n")
    with open(os.path.join(d, "result.json"), "w") as f:
        f.write(raw_result if raw_result is not None else json.dumps(result))


ANS = "ANSWER: one session per handover doc\nFILES:\n" + LOCK

# P5: two s-qmd calls in ONE Bash tool use, the returned file read, then cited
write("two-calls", [
    tu(1, "Bash", command='s-qmd "queue lock" && s-qmd "handover session lock"'),
    tr(1, qmd_out(LOCK) + "\n" + qmd_out(LOCK, ZETA)),
    tu(2, "Read", file_path=LOCK), tr(2, "# Lock\nThe queue lock keeps one session per handover doc."),
], [admit(1), term(1), admit(2), term(2)], answer(ANS))
# P5: no route call at all (a V-style grep session)
write("none", [
    tu(1, "Grep", pattern="queue lock", path="/work/himmel"), tr(1, LOCK),
    tu(2, "Bash", command="grep -rn 'session' /work/himmel/docs | head -5"), tr(2, LOCK + ":2:The queue lock"),
], [], answer(ANS))
# P5 red: the broker admitted three, the transcript shows two s-qmd invocations
write("offbyone", [
    tu(1, "Bash", command='s-qmd "queue lock"'), tr(1, qmd_out(LOCK)),
    tu(2, "Bash", command='s-qmd "lock"'), tr(2, qmd_out(LOCK)),
], [admit(1), term(1), admit(2), term(2), admit(3), term(3)], answer(ANS))
# one answer-phase skip; a probe-phase skip in the same meta never counts toward the answer
write("skip1", [
    tu(1, "Bash", command='s-qmd "queue lock"'), tr(1, qmd_out(LOCK)),
], [admit(1), term(1, reasons=["expansion_failed"]), admit(1, "probe"), term(1, "probe", reasons=["timeout"])], answer(ANS))
# route events that are not skips: an empty result, a 13th-query refusal, dropped hits, a graph error
write("route-events", [
    tu(1, "Bash", command='s-qmd "nothing here"'), tr(1, "s-qmd: no results"),
    tu(2, "Bash", command='s-qmd "lock"'), tr(2, "s-qmd: query limit reached (12 per task)", err=True),
    tu(3, "Bash", command="s-graph relay_batch"), tr(3, "s-graph: graph unavailable", err=True),
    tu(4, "Bash", command="s-graph queue lock"), tr(4, "Queue lock doc  %s:1" % LOCK),
], [admit(1), term(1, kept=0, dropped=2), {"kind": "cap_refused"}], answer(ANS))
# forbidden reads: a blocked credential read versus a private task file whose content came back
write("forbidden", [
    tu(1, "Read", file_path="/session-home/.claude/.credentials.json"), tr(1, "Permission to read this file has been denied.", err=True),
    tu(2, "Bash", command="cat /pilot/private/tasks.jsonl"), tr(2, '{"id": "t01", "q": "secret question"}'),
], [], answer(ANS))
write("blocked-only", [
    tu(1, "Read", file_path="/session-home/.claude/.credentials.json"), tr(1, "Permission to read this file has been denied.", err=True),
    tu(2, "Grep", pattern="key", path="/pilot/private"), tr(2, "Path does not exist: /pilot/private", err=True),
], [], answer(ANS))
# tool and index library reads are allowed runtime reads, never a void
write("runtime-reads", [
    tu(1, "Read", file_path="/run/pilot/tools/s-qmd"), tr(1, "#!/usr/bin/env python3\n..."),
    tu(2, "Bash", command="ls /opt/qmd/dist | head -3"), tr(2, "cli\ncollections.js\ndb.js"),
], [], answer(ANS))
# the agent touching the broker channel is an integrity abort; calling the qmd binary directly bypasses the counter
write("channel", [
    tu(1, "Bash", command="ls -la /run/pilot/broker.sock"), tr(1, "srw-rw-rw- 1 eval eval 0 broker.sock"),
], [], answer(ANS))
write("direct-qmd", [
    tu(1, "Bash", command="/opt/qmd/bin/qmd --index eval query lock"), tr(1, "[]"),
], [], answer(ANS))
# Q: a recorded remote attempt must never pass as zero
write("q-remote", [
    tu(1, "Bash", command='s-qmd "queue lock"'), tr(1, qmd_out(LOCK)),
], [admit(1), term(1, reasons=["q_remote_attempt"])], answer(ANS))
# service failures and scored-false answers
write("no-json", [], [], None, raw_result="claude: crashed before writing a result\n")
write("auth-error", [], [], answer("", is_error=True, subtype="error_during_execution", api_error_status=401,
                                   result="Invalid API key · Please run /login"))
write("budget", [tu(1, "Bash", command="grep -rn lock /work/himmel"), tr(1, LOCK)], [],
      answer("", is_error=True, subtype="error_max_budget_usd"))
write("malformed", [], [], answer("I think it is the lock doc."))
write("skip-and-service", [
    tu(1, "Bash", command='s-qmd "queue lock"'), tr(1, qmd_out(LOCK)),
], [admit(1), term(1, reasons=["timeout"])], None, raw_result="")
