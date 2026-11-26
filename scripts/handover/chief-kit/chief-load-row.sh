#!/usr/bin/env bash
# chief-load-row.sh - the one writer of <bucket>/chief-load.jsonl, one row per chief shift.
#
#   chief-load-row.sh --bucket <dir> --shift <session> --next-shift <session>
#                     --workers-end <n> --rulings <n> --spans-unknown <n>
#                     [--reason <text>] [--fill-percent <p>] [--window <tokens>]
#
# The file is append-only JSON lines, one flat object per shift with a fixed key order, so it
# imports as a table.
#
# Read from the outgoing chief's main-loop transcript, found by CLAUDE_CODE_SESSION_ID under
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects and used only when its custom title is --shift.
# Only counts, timestamps, token usage and tool names are kept, never text.
#   hours            first to last timestamp of the transcript
#   ctx_start        context (input + cache read + cache creation) at the first Bash call running chief-wait.sh
#   ctx_end          the largest context of the shift
#   wakes_*          user turns that are not tool results: waiter (task-notification), worker
#                    (cross-session message), subagent (hand-back), other (session load, local
#                    command); an operator turn is counted in operator_lines, and the model calls
#                    it triggers in operator_turns
#   judge_requests   worker wakes carrying JUDGE-REQUEST; judge_dispatches the Agent calls of a
#                    judge or judge-ro subagent; judge_wait_min the median minutes from a request
#                    to the dispatch that follows it (first in, first out)
#   hook_timeouts    tool results that report a hook timing out
# From the arguments: workers_end (the live workers carried to the successor), rulings (operator
# rulings quoted verbatim in the outgoing Results), spans_unknown (NONCE-UNKNOWN spans carried).
# workers_start is the workers_end of the row whose next_shift is this shift; workers_mean is the
# mean of the two, workers_peak the larger. host_load is the one-minute load average at handover.
# reason is --reason, else `fill` when ctx_end reached --fill-percent of --window, else `unstated`.
# A field that cannot be read is null; the row is still written.
#
# Exit: 0 row appended; 1 the row was not written whole; 2 usage; 3 the record is not a regular
# file (a symlink, FIFO or other), refused.
set -uo pipefail

usage() { sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

bucket="" shift_name="" next_shift="" workers_end="" rulings="" spans_unknown="" reason="" fill_percent=45 window=1000000
while [ "$#" -gt 0 ]; do
    [ "$#" -ge 2 ] || usage
    case "$1" in
        --bucket) bucket="$2" ;;
        --shift) shift_name="$2" ;;
        --next-shift) next_shift="$2" ;;
        --workers-end) workers_end="$2" ;;
        --rulings) rulings="$2" ;;
        --spans-unknown) spans_unknown="$2" ;;
        --reason) reason="$2" ;;
        --fill-percent) fill_percent="$2" ;;
        --window) window="$2" ;;
        *) usage ;;
    esac
    shift 2
done
[ -n "$bucket" ] && [ -n "$shift_name" ] && [ -n "$next_shift" ] || usage
for n in "$workers_end" "$rulings" "$spans_unknown" "$fill_percent" "$window"; do
    case "$n" in ''|*[!0-9]*) usage ;; esac
done
[ -d "$bucket" ] || { echo "chief-load-row: no bucket directory $bucket" >&2; exit 2; }

transcript=""
sid="${CLAUDE_CODE_SESSION_ID:-}"
if [[ "$sid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
    for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$sid".jsonl; do
        [ -f "$f" ] && grep -q -F "\"customTitle\":\"$shift_name\"" "$f" && { transcript="$f"; break; }
    done
fi

exec python3 -I - "$bucket/chief-load.jsonl" "$transcript" "$shift_name" "$next_shift" \
    "$workers_end" "$rulings" "$spans_unknown" "$reason" "$fill_percent" "$window" <<'PY'
import datetime, errno, json, os, re, shlex, stat, statistics, sys

path, transcript, shift, next_shift = sys.argv[1:5]
workers_end, rulings, spans_unknown = (int(x) for x in sys.argv[5:8])
reason, fill_percent, window = sys.argv[8], int(sys.argv[9]), int(sys.argv[10])
SEPARATOR_CHARS = ";&|(){}"


def is_separator(tok):
    return tok != "" and set(tok) <= set(SEPARATOR_CHARS)


def runs_waiter(cmd):
    try:
        lexer = shlex.shlex(cmd, posix=False, punctuation_chars=SEPARATOR_CHARS)
        lexer.whitespace_split = True
        lexer.commenters = ""
        toks = list(lexer)
    except ValueError:
        return False
    return any(t == "bash" and (i == 0 or is_separator(toks[i - 1])) and i + 1 < len(toks)
               and toks[i + 1].strip("\"'").endswith("chief-wait.sh") for i, t in enumerate(toks))


HOOK_TIMEOUT = re.compile(r"hook[^\n]{0,80}timed out|timed out[^\n]{0,40}\bhook", re.I)


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def user_text(content):
    if isinstance(content, str):
        return content
    if all(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
        return None
    return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")


def wake_kind(txt):
    if "<task-notification>" in txt:
        return "waiter"
    if "cross-session-message" in txt or "<teammate-message" in txt:
        return "worker"
    if "[Subagent hand-back]" in txt or "<agent-message" in txt:
        return "subagent"
    if txt.startswith(("<local-command", "<bash-", "<command-name>")) or (txt.startswith("load ") and "continue" in txt):
        return "other"
    return "operator"


def result_texts(content):
    if not isinstance(content, list):
        return
    for b in content:
        if isinstance(b, dict) and b.get("type") == "tool_result":
            c = b.get("content")
            if isinstance(c, str):
                yield c
            elif isinstance(c, list):
                for x in c:
                    if isinstance(x, dict) and isinstance(x.get("text"), str):
                        yield x["text"]


def measure(file):
    records, title = [], None
    with open(file, errors="replace") as fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") == "custom-title":
                title = d.get("customTitle")
            elif not d.get("isSidechain") and d.get("timestamp"):
                records.append(d)
    if title != shift:
        return None
    ctx, arm, stamps, requests, waits = {}, None, [], [], []
    m = dict(waiter=0, worker=0, subagent=0, other=0, operator=0, operator_turns=0,
             judge_requests=0, judge_dispatches=0, hook_timeouts=0)
    trigger = None
    for d in records:
        t = ts(d["timestamp"])
        stamps.append(t)
        msg = d.get("message") or {}
        if d.get("type") == "user":
            content = msg.get("content") or ""
            m["hook_timeouts"] += sum(1 for x in result_texts(content) if HOOK_TIMEOUT.search(x))
            txt = user_text(content)
            if txt is None:
                continue
            trigger = wake_kind(txt)
            m[trigger] += 1
            if trigger == "worker" and "JUDGE-REQUEST" in txt:
                m["judge_requests"] += 1
                requests.append(t)
        elif d.get("type") == "assistant":
            mid = msg.get("id") or d.get("uuid")
            u = msg.get("usage") or {}
            size = sum(u.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
            if mid not in ctx and trigger == "operator":
                m["operator_turns"] += 1
            ctx[mid] = max(ctx.get(mid, 0), size)
            for b in msg.get("content") or []:
                if not isinstance(b, dict) or b.get("type") != "tool_use":
                    continue
                inp = b.get("input") or {}
                if arm is None and b.get("name") == "Bash" and runs_waiter(str(inp.get("command") or "")):
                    arm = mid
                if b.get("name") in ("Agent", "Task") and inp.get("subagent_type") in ("judge", "judge-ro"):
                    m["judge_dispatches"] += 1
                    if requests:
                        waits.append((t - requests.pop(0)).total_seconds() / 60)
    if not stamps:
        return None
    m["hours"] = round((max(stamps) - min(stamps)).total_seconds() / 3600, 3)
    m["started_at"] = min(stamps).isoformat().replace("+00:00", "Z")
    m["ctx_start"] = ctx[arm] if arm is not None else None
    m["ctx_end"] = max(ctx.values()) if ctx else None
    m["judge_wait_min"] = round(statistics.median(waits), 1) if waits else None
    return m


def refuse():
    print("chief-load-row: refusing %s, it is not a regular file" % path, file=sys.stderr)
    sys.exit(3)


try:
    fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
except OSError as e:
    if e.errno in (errno.ELOOP, errno.ENXIO, errno.EISDIR):
        refuse()
    raise
if not stat.S_ISREG(os.fstat(fd).st_mode):
    refuse()
chunks = []
while True:
    chunk = os.read(fd, 65536)
    if not chunk:
        break
    chunks.append(chunk)
content = b"".join(chunks)
previous = content.decode("utf-8", "replace").splitlines()

m = None
if transcript:
    try:
        m = measure(transcript)
    except (OSError, ValueError, KeyError, TypeError):
        m = None
m = m or {}

workers_start = None
for line in previous:
    try:
        r = json.loads(line)
    except ValueError:
        continue
    if isinstance(r, dict) and r.get("next_shift") == shift and isinstance(r.get("workers_end"), int):
        workers_start = r["workers_end"]
ends = [x for x in (workers_start, workers_end) if x is not None]
ctx_end = m.get("ctx_end")
if not reason:
    reason = "fill" if ctx_end is not None and ctx_end * 100 >= fill_percent * window else "unstated"
try:
    load = round(os.getloadavg()[0], 2)
except OSError:
    load = None

row = {
    "schema": 1,
    "shift": shift,
    "next_shift": next_shift,
    "started_at": m.get("started_at"),
    "ended_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "hours": m.get("hours"),
    "workers_start": workers_start,
    "workers_end": workers_end,
    "workers_mean": sum(ends) / len(ends),
    "workers_peak": max(ends),
    "ctx_window": window,
    "ctx_start": m.get("ctx_start"),
    "ctx_end": ctx_end,
    "wakes_waiter": m.get("waiter"),
    "wakes_worker": m.get("worker"),
    "wakes_subagent": m.get("subagent"),
    "wakes_other": m.get("other"),
    "operator_lines": m.get("operator"),
    "operator_turns": m.get("operator_turns"),
    "judge_requests": m.get("judge_requests"),
    "judge_dispatches": m.get("judge_dispatches"),
    "judge_wait_min": m.get("judge_wait_min"),
    "rulings": rulings,
    "spans_unknown": spans_unknown,
    "hook_timeouts": m.get("hook_timeouts"),
    "host_load": load,
    "reason": reason,
    "transcript": "read" if m else "unavailable",
}
data = (json.dumps(row, separators=(",", ":")) + "\n").encode()
if content and not content.endswith(b"\n"):
    data = b"\n" + data
written = os.write(fd, data)
os.close(fd)
if written != len(data):
    print("chief-load-row: wrote %d of %d bytes of the row to %s" % (written, len(data), path), file=sys.stderr)
    sys.exit(1)
print("chief-load: %s" % path)
PY
