#!/usr/bin/env bash
# scripts/eval/test-handover-cost.sh - hermetic suite for handover-cost.py.
# Fixture: scripts/eval/fixtures/handover-cost/ (two consoles P -> S, a new and an old leg),
# every turn costs 250 (100 input + 1000 cache_read x 0.1 + 10 output x 5). No model call, no bank.
#  1. the P -> S pair prints a known turn count and cost per piece (prep, relay, action zero, leg);
#  2. net counts only the turns that touch the handover scripts, gross counts them all;
#  3. --legs-after drops legs launched before the cutoff (F-L9);
#  4. a repeated message id is one turn; an empty or missing dir exits 2.
#
# check() evals its condition, so the single quotes are deliberate.
# shellcheck disable=SC2016,SC2034
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HC="$HERE/handover-cost.py"
FX="$HERE/fixtures/handover-cost"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/handover-cost-test.XXXXXX")" || { echo "test-handover-cost: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
hc() { WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$HC" --dir "$FX" "$@"; }
row() { grep -E "^HANDOVER " "$1" | head -1; }

echo "1. per-piece counts, legs launched after 09:30"
hc --legs-after 2026-10-19T09:30:00Z >"$TMP/a.out" 2>"$TMP/a.err"; rc=$?
check "exits 0" '[ "$rc" = 0 ]'
check "names the pair" 'row "$TMP/a.out" | grep -q "HIMMEL-nextleg-2026-10-19A-roadmap-console->HIMMEL-nextleg-2026-10-19B-roadmap-console"'
check "prep is 2 turns, 500" 'row "$TMP/a.out" | grep -q " prep=2/500 "'
check "relay+wrap is 3 turns, 750 (the repeated message id counts once)" 'row "$TMP/a.out" | grep -q " relay=3/750 "'
check "action zero is 4 turns, 1000 (the turn after the predecessor wrapped is out)" 'row "$TMP/a.out" | grep -q " az=4/1000 "'
check "leg relay is 2 turns, 500 from the one leg" 'row "$TMP/a.out" | grep -q " leg=2/500 legs=1 "'
check "gross is 2750" 'row "$TMP/a.out" | grep -q " gross=2750 "'

echo "2. net"
check "net is 2000 (only the handover-script turns)" 'row "$TMP/a.out" | grep -q " net=2000$"'
check "the MEAN line repeats the single pair" 'grep -qE "^MEAN n=1 .* gross=2750 net=2000$" "$TMP/a.out"'

echo "3. leg cutoff"
hc >"$TMP/b.out" 2>&1
check "control: with no cutoff the old leg counts too (5 turns, 2 legs)" 'row "$TMP/b.out" | grep -q " leg=5/1250 legs=2 "'
check "with the cutoff the old leg is reported skipped" 'grep -q "legs_skipped_before_cutoff=1" "$TMP/a.out"'

echo "3b. one message id over several records, and a delivery naming another console"
if ! { mkdir "$TMP/x" && cp "$FX"/*.jsonl "$TMP/x/"; }; then echo "test-handover-cost: fixture copy failed" >&2; exit 1; fi
if ! python3 - "$TMP/x" <<'PYEOF'
import json, sys
d = sys.argv[1]
rows = [json.loads(l) for l in open(d + "/console-p.jsonl")]
extra = []
for r in rows:
    if r.get("message", {}).get("id") == "mp3":
        t = json.loads(json.dumps(r))
        t["message"]["content"] = [{"type": "text", "text": "done"}]
        extra.append(t)
open(d + "/console-p.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in rows + extra))
open(d + "/leg-other.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in [
    {"type": "agent-name", "agentName": "HIMMEL-3-N3-leg-other", "timestamp": "2026-10-19T10:06:00Z"},
    {"type": "user", "timestamp": "2026-10-19T10:14:32Z", "message": {"content": "SUCCESSION from HIMMEL-nextleg-2026-10-19Q-roadmap-console"}},
    {"type": "assistant", "timestamp": "2026-10-19T10:14:42Z", "message": {"id": "mx1", "usage": {"input_tokens": 100, "cache_read_input_tokens": 1000, "output_tokens": 10}, "content": [{"type": "text", "text": "SUCCESSION accepted"}]}},
]))
PYEOF
then echo "test-handover-cost: fixture modification failed" >&2; exit 1; fi
hc2() { WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$HC" --dir "$TMP/x" "$@"; }
hc2 --legs-after 2026-10-19T09:30:00Z >"$TMP/c.out" 2>&1
check "a later text-only record of the same id does not erase the console.sh next flag (prep stays 2/500)" 'row "$TMP/c.out" | grep -q " prep=2/500 "'
check "a leg whose delivery names another console is not charged (still 1 leg)" 'row "$TMP/c.out" | grep -q " legs=1 "'

echo "3c. a relay delivered as a queued_command attachment after the predecessor's last turn"
if ! { mkdir "$TMP/q" && cp "$FX"/*.jsonl "$TMP/q/"; }; then echo "test-handover-cost: fixture copy failed" >&2; exit 1; fi
if ! python3 - "$TMP/q" <<'PYEOF'
import json, sys
open(sys.argv[1] + "/leg-late.jsonl", "w").write("".join(json.dumps(r) + "\n" for r in [
    {"type": "agent-name", "agentName": "HIMMEL-4-N4-leg-late", "timestamp": "2026-10-19T10:05:00Z"},
    {"type": "attachment", "timestamp": "2026-10-19T10:18:00Z", "attachment": {"type": "queued_command", "prompt": "SUCCESSION from HIMMEL-nextleg-2026-10-19A-roadmap-console"}},
    {"type": "assistant", "timestamp": "2026-10-19T10:18:10Z", "message": {"id": "mq1", "usage": {"input_tokens": 100, "cache_read_input_tokens": 1000, "output_tokens": 10}, "content": [{"type": "text", "text": "SUCCESSION accepted"}]}},
]))
PYEOF
then echo "test-handover-cost: fixture modification failed" >&2; exit 1; fi
WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$HC" --dir "$TMP/q" --legs-after 2026-10-19T09:30:00Z >"$TMP/q.out" 2>&1; qrc=$?
check "the late attachment run exits 0" '[ "$qrc" = 0 ]'
check "the late attachment relay is a leg (legs=2, leg=3/750)" 'row "$TMP/q.out" | grep -q " leg=3/750 legs=2 "'

echo "3d. mechanical columns"
if ! { mkdir "$TMP/m" && cp "$FX"/*.jsonl "$TMP/m/" && sed -e 's/bash action-zero.sh --acquire/bash append-results.sh d x/' -e 's/ListAgents check/will run append-results.sh later/' "$FX/console-s.jsonl" >"$TMP/m/console-s.jsonl"; }; then echo "test-handover-cost: fixture copy failed" >&2; exit 1; fi
WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$HC" --dir "$TMP/m" >"$TMP/m2.out" 2>&1; mrc2=$?
check "the marker run exits 0" '[ "$mrc2" = 0 ]'
check "P calls after S first call is 3 (the relay piece)" 'row "$TMP/a.out" | grep -q " p_after_s=3 "'
check "S calls to its first marker bullet is - when S wrote none" 'row "$TMP/a.out" | grep -q " s_to_marker=- "'
check "S calls to its first marker bullet counts the call, not an earlier text mention of append-results.sh" 'row "$TMP/m2.out" | grep -q " s_to_marker=2 "'

echo "4. errors"
mkdir "$TMP/empty"
python3 "$HC" --dir "$TMP/empty" >"$TMP/e.out" 2>&1; erc=$?
check "a dir with no console exits 2 with a message" '[ "$erc" = 2 ] && grep -q "fewer than two consoles" "$TMP/e.out"'
python3 "$HC" --dir "$TMP/none" >"$TMP/m.out" 2>&1; mrc=$?
check "a missing dir exits 2" '[ "$mrc" = 2 ]'
python3 "$HC" --dir "$FX" --legs-after not-a-date >"$TMP/d.out" 2>&1; drc=$?
check "an invalid --legs-after is a usage error (exit 2)" '[ "$drc" = 2 ]'
python3 "$HC" --dir "$FX" --name-re '(' >"$TMP/r.out" 2>&1; rrc=$?
check "an invalid --name-re is a usage error (exit 2), not a traceback" '[ "$rrc" = 2 ] && grep -q "^usage:" "$TMP/r.out" && grep -q "argument --name-re" "$TMP/r.out" && ! grep -q Traceback "$TMP/r.out"'
if ! { mkdir "$TMP/n" && cp "$FX"/*.jsonl "$TMP/n/" && sed -e 's/console\.sh next/console.sh nope/' "$FX/console-p.jsonl" >"$TMP/n/console-p.jsonl"; }; then echo "test-handover-cost: fixture copy failed" >&2; exit 1; fi
python3 "$HC" --dir "$TMP/n" >"$TMP/n.out" 2>&1; nrc=$?
check "two consoles with no measurable handover exit 2 with a message, no silent 0" '[ "$nrc" = 2 ] && grep -q "no measurable handover" "$TMP/n.out" && ! grep -q "^HANDOVER " "$TMP/n.out" && ! grep -q "^MEAN " "$TMP/n.out"'
if ! { mkdir "$TMP/ch" && cp "$FX"/*.jsonl "$TMP/ch/" && sed -e 's/console\.sh next/chief.sh next/' "$FX/console-p.jsonl" >"$TMP/ch/console-p.jsonl"; }; then echo "test-handover-cost: fixture copy failed" >&2; exit 1; fi
python3 "$HC" --dir "$TMP/ch" >"$TMP/ch.out" 2>&1; chrc=$?
check "a chief.sh next call marks the handover the same as console.sh next" '[ "$chrc" = 0 ] && grep -q "^HANDOVER " "$TMP/ch.out"'

echo "5. a quoted script path"
if ! { mkdir "$TMP/qt" && cp "$FX"/*.jsonl "$TMP/qt/" && python3 - "$TMP/qt" <<'PYEOF'
import sys
p = sys.argv[1] + "/console-p.jsonl"
src = open(p).read()
# the JSONL carries the quote as an escaped \" between the script and "next"
open(p, "w").write(src.replace("console.sh next", 'console.sh\\" next'))
PYEOF
}; then echo "test-handover-cost: fixture modification failed" >&2; exit 1; fi
WORKER_SESSION_BURN_W_INPUT=1 WORKER_SESSION_BURN_W_CACHE_READ=0.1 WORKER_SESSION_BURN_W_CACHE_CREATE=1.25 WORKER_SESSION_BURN_W_OUTPUT=5 python3 "$HC" --dir "$TMP/qt" >"$TMP/qt.out" 2>&1; qtrc=$?
check "a console.sh next run through a quoted path marks the handover" '[ "$qtrc" = 0 ] && grep -q "^HANDOVER " "$TMP/qt.out"'

echo "handover-cost: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
