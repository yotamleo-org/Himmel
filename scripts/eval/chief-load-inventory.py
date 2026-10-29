#!/usr/bin/env python3
"""scripts/eval/chief-load-inventory.py - which chief jobs recur, and what they cost.

Read-only, deterministic, no model call. Parses chief (supervisor-session)
transcripts and attributes every API request to a trigger class (the last
non-tool-result user turn: a worker message, a task notification, the operator)
and an action class (what its tool calls did), then costs it.

  chief-load-inventory.py [--projects DIR] [--suffix -roadmap-chief,-roadmap-console]
                            [--match REGEX] [--last N] [--json]

Cost per API request (deduped by message id; assistant entries are split per
content block with the same usage) = input + cache_creation + 0.1 * cache_read
tokens ("input-token equivalent"). Raw cache_read is printed beside it. A
request with no tool call is think-only.

Sessions are the transcripts whose custom-title ends in --suffix. --match
narrows by title regex, --last keeps the N newest by title.

Also reports, per script in SCRIPTS, how many chief Bash calls ran it, and
how many wraps were done by hand (close-wrapped-worker.sh without wrap-merged.sh).

Exit: 0 ok, 2 no matching sessions.
"""

import argparse
import collections
import glob
import json
import os
import re
import sys

SCRIPTS = [
    "wrap-merged.sh", "verdict-go.sh", "relay-batch.sh", "succession-tracker.sh",
    "close-wrapped-leg.sh", "close-wrapped-worker.sh", "live-state.sh", "write-verdict.sh", "go.sh", # old-term-ok
    "fleet-manifest.sh", "append-results.sh", "board.mjs", "chief-wait.sh",
    "tick.sh", "headed-arm-leg.sh", "headed-arm-worker.sh", "ready-check.sh", "merge-on-green.sh", # old-term-ok
]

TRIGGERS = [
    ("succession-quoteback", r"accepts succession|SUCCESSION accepted|^\w+ \(token `[^`]+`\):|^Token `"),
    ("worker-READY", r"^READY\b"),
    ("worker-MERGED", r"^MERGED\b"),
    ("worker-WRAPPED", r"^WRAPPED\b"),
    ("worker-FINDING", r"^FINDING\b|\bFINDING\b.*token|^\w+ FINDING"),
    ("worker-BLOCKED-MAINRED", r"^BLOCKED\b|MAIN-RED"),
    ("worker-PUSHED-CHUNK-DONE", r"^(PUSHED|CHUNK|DONE)\b|checkpoint after|\bFINAL\b"),
    ("chief-to-chief", r"^\w+ (LIVE|to \w+):|^\w+ to \w+:|\bLIVE\.\s"),
    ("operator-directed-session", r"^Operator"),
]

ACTIONS = [
    ("verdict-persist", r"write-verdict\.sh|verdict-go\.sh|\bgo\.sh\b"),
    ("wrap-close", r"close-wrapped-(?:leg|worker)\.sh|wrap-merged\.sh|fleet-manifest\.sh\s+\S*\s*(remove|rm)"),
    ("merge-ready-gate", r"ready-check\.sh|merge-on-green\.sh|check-ci\.sh|gh pr (view|checks)"),
    ("succession-bookkeeping", r"succession-tracker\.sh|live-state\.sh"),
    ("board-render", r"board\.mjs|fleet\.mjs"),
    ("jira-defer", r"jira/dist/index\.js"),
    ("ci-rerun", r"gh run (rerun|list|view)"),
    ("dispatch-worker", r"headed-arm-(?:leg|worker)\.sh|gen-briefs|brief-lint"),
    ("tick-wait", r"chief-wait\.sh|tick\.sh"),
    ("results-only", r"append-results\.sh"),
]


EPISODES = collections.Counter()  # trigger class -> number of triggers seen


def title_of(path):
    with open(path) as fh:
        for i, line in enumerate(fh):
            if i > 12:
                return None
            if line.startswith('{"type":"custom-title"'):
                return json.loads(line)["customTitle"]
    return None


def user_text(msg):
    c = msg["content"]
    if isinstance(c, str):
        return c
    if all(x.get("type") == "tool_result" for x in c):
        return None
    return " ".join(x.get("text", "") for x in c if x.get("type") == "text")


def classify_trigger(txt):
    if txt is None:
        return None
    if "<task-notification>" in txt:
        return "task-notification"
    if "[Subagent hand-back]" in txt or "<agent-message" in txt:
        return "subagent-hand-back"
    if txt.startswith(("<local-command", "<bash-", "<command-name>")):
        return "local-command"
    if "cross-session-message" in txt:
        body = re.sub(r"^.*?from-mode=\"[^\"]*\">\s*", "", txt, flags=re.S).strip()
        for name, rx in TRIGGERS:
            if re.search(rx, body, re.M):
                return name
        return "worker-other"
    if txt.startswith("load ") and "continue" in txt:
        return "session-load"
    return "operator"


def classify_action(cmds):
    blob = "\n".join(cmds)
    for name, rx in ACTIONS:
        if re.search(rx, blob):
            return name
    if "SendMessage" in cmds:
        return "reply-only"
    if not cmds:
        return "think-only"
    first = cmds[0].split()
    return "other:" + (" ".join(first[:2]) if first else "?")[:30]


def parse(path):
    """Return (requests, script_calls, hand_wraps)."""
    reqs, order = {}, []
    trig = "session-start"
    script_calls = collections.Counter()
    hand_wraps = 0
    for line in open(path):
        d = json.loads(line)
        t = d.get("type")
        if t == "user":
            tr = classify_trigger(user_text(d["message"]))
            if tr:
                trig = tr
                EPISODES[tr] += 1
        elif t == "assistant":
            m = d["message"]
            mid = m.get("id") or d.get("uuid")
            r = reqs.get(mid)
            if r is None:
                u = m.get("usage", {})
                r = reqs[mid] = {
                    "trigger": trig, "cmds": [],
                    "eq": u.get("input_tokens", 0) + u.get("cache_creation_input_tokens", 0) + 0.1 * u.get("cache_read_input_tokens", 0),
                    "read": u.get("cache_read_input_tokens", 0),
                }
                order.append(mid)
            for x in m["content"]:
                if x.get("type") != "tool_use":
                    continue
                if x["name"] == "Bash":
                    cmd = x["input"].get("command", "")
                    r["cmds"].append(cmd)
                    for s in SCRIPTS:
                        if re.search(r"(?<![\w-])" + re.escape(s), cmd):
                            script_calls[s] += 1
                    if ("close-wrapped-leg.sh" in cmd or "close-wrapped-worker.sh" in cmd) and "wrap-merged.sh" not in cmd: # old-term-ok
                        hand_wraps += 1
                elif x["name"] == "SendMessage":
                    r["cmds"].append("SendMessage")
                elif x["name"] == "Artifact":
                    r["cmds"].append("board.mjs Artifact")
                else:
                    r["cmds"].append(x["name"])
    out = []
    for mid in order:
        r = reqs[mid]
        r["action"] = classify_action(r["cmds"])
        out.append(r)
    return out, script_calls, hand_wraps


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects/-home-overlord-Documents-github-himmel"))
    ap.add_argument("--suffix", default="-roadmap-chief,-roadmap-console")
    ap.add_argument("--match", default="")
    ap.add_argument("--last", type=int, default=0)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    sessions = []
    for f in glob.glob(os.path.join(a.projects, "*.jsonl")):
        t = title_of(f)
        if t and t.endswith(tuple(a.suffix.split(","))) and re.search(a.match, t):
            sessions.append((t, f))
    sessions.sort()
    if a.last:
        sessions = sessions[-a.last:]
    if not sessions:
        print("no matching chief sessions", file=sys.stderr)
        return 2

    by_action = collections.defaultdict(lambda: [0, 0.0, 0])
    by_trigger = collections.defaultdict(lambda: [0, 0.0, 0])
    by_pair = collections.defaultdict(lambda: [0, 0.0, 0])
    scripts = collections.Counter()
    hand_wraps = 0
    for _, f in sessions:
        rq, sc, hw = parse(f)
        scripts.update(sc)
        hand_wraps += hw
        for e in rq:
            for tbl, k in ((by_action, e["action"]), (by_trigger, e["trigger"]), (by_pair, (e["trigger"], e["action"]))):
                r = tbl[k]
                r[0] += 1
                r[1] += e["eq"]
                r[2] += e["read"]

    if a.json:
        print(json.dumps({
            "sessions": [t for t, _ in sessions],
            "by_action": by_action,
            "by_trigger": by_trigger,
            "by_pair": {"%s|%s" % k: v for k, v in by_pair.items()},
            "script_calls": dict(scripts),
            "hand_wraps": hand_wraps,
        }, indent=1))
        return 0

    def show(title, tbl, n=99):
        tot = sum(v[1] for v in tbl.values()) or 1
        print("\n%s  (api-requests, input-eq M, share, raw cache_read M)" % title)
        for k, v in sorted(tbl.items(), key=lambda kv: -kv[1][1])[:n]:
            k = k if isinstance(k, str) else " / ".join(k)
            print("%-46s %6d %8.1f %5.1f%% %8.0f" % (k, v[0], v[1] / 1e6, 100 * v[1] / tot, v[2] / 1e6))

    print("sessions: %d (%s .. %s)" % (len(sessions), sessions[0][0], sessions[-1][0]))
    show("BY ACTION", {k: v for k, v in by_action.items() if not k.startswith("other:")})
    other = {k: v for k, v in by_action.items() if k.startswith("other:")}
    show("OTHER TOOLS (first Bash words, or tool name)", other, 15)
    show("BY TRIGGER", by_trigger)
    show("TOP trigger/action pairs", by_pair, 15)
    print("\nA/B BASELINE: chief requests per worker-message episode (before worker-event.sh)")
    for k in ("worker-MERGED", "worker-WRAPPED"):
        v = by_trigger.get(k)
        if v and EPISODES[k]:
            print("%-24s %4d episodes %5d requests %5.1f req/episode %6.2fM eq/episode" % (k, EPISODES[k], v[0], v[0] / EPISODES[k], v[1] / EPISODES[k] / 1e6))
    print("\nSCRIPT USE (chief Bash calls)")
    for s in SCRIPTS:
        print("%-24s %5d" % (s, scripts[s]))
    print("hand wraps (close-wrapped-worker.sh run without wrap-merged.sh): %d" % hand_wraps)
    return 0


if __name__ == "__main__":
    sys.exit(main())
