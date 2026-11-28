#!/usr/bin/env bash
# test-silent-worker-act.sh — silent-worker-act.sh nudges a silent worker once on the bus past
# bound one, relaunches a worker with no live window from its RESUME doc past bound two, never
# ends a live window but quotes its last words from its transcript, owes a row on any failed step, acts the same under a succession signal,
# and leaves a worker with a fresh doc write alone.
# The bus, the process census, the launcher and the launch confirmation are stubbed
# (SILENT_ACT_BUS / _CENSUS / _LAUNCHER / _CONFIRM); owe.sh and append-results.sh are real,
# run on fixtures. bash 3.2-safe.
#
# SILENT_ACT overrides the script under test (the RED control).
#
# Run: bash scripts/handover/chief-kit/test-silent-worker-act.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ACT="${SILENT_ACT:-$HERE/silent-worker-act.sh}"

fails=0
check() {
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/silent-worker-act-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
LIVE_PID=""
trap '[ -z "$LIVE_PID" ] || kill "$LIVE_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

NOW="$(date +%s)"
old() { touch -d "@$((NOW - $2 * 60))" "$1"; }

BUCKET="$WORK/bucket"; mkdir -p "$BUCKET"
CHIEF_DOC="$BUCKET/DEMO-chief-2026-11-25.md"
printf '# chief\n\n## Results\n\n- 10:00 LIVE - x\n' > "$CHIEF_DOC"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    f="$BUCKET/DEMO-$n-N$n-w-2026-11-25.md"
    printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n' > "$f"
    [ "$n" -eq 2 ] || old "$f" 161
done
W() { echo "$BUCKET/DEMO-$1-N$1-w-2026-11-25.md"; }
for n in 1 3 5 7 11 12 13 14; do printf '# resume\n\n## Results\n\n- 10:00 LIVE - x\n' > "$(W $n | sed 's/\.md$/-RESUME.md/')"; done
MANIFEST="$BUCKET/DEMO-chief-2026-11-25.fleet.json"
rows=""
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do rows="$rows${rows:+,}{\"doc\":\"$(W $n)\",\"label\":\"N$n\",\"lane\":\"native\"}"; done
printf '{"schema":1,"workers":[%s]}\n' "$rows" > "$MANIFEST"

mkdir -p "$WORK/cache/launch-logs"
for n in 1 3 4 5 11 12 13 14; do
    printf '2026-11-25T10:00:00Z session_id=sid%s model=claude-sonnet-5-5 profile=worker-impl lane=native role=worker\n' "$n" > "$WORK/cache/launch-logs/DEMO-$n-N$n-w-2026-11-25.log"
done

sleep 600 &
LIVE_PID=$!
cat > "$WORK/census.sh" <<'EOF'
#!/usr/bin/env bash
cat "$WORK/census.txt"  # read-sink-ok: the suite's own census fixture under its mktemp dir
exit "${CENSUS_RC:-0}"
EOF
printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\topus\\t200000\\n" 999 other-session\nexit 2\n' > "$WORK/census-fail.sh"
{
    printf '%s\t%s\topus\t200000\n' "$LIVE_PID" "DEMO-9-N9-w-2026-11-25"
    printf '%s\t%s\topus\t200000\n' 205 "DEMO-5-N5-w-2026-11-25-RESUME"
    printf '%s\t%s\topus\t200000\n' 110 "DEMO-10-N10-w-2026-11-25"
    printf '%s\t%s\topus\t200000\n' 108 "DEMO-8-N8-w-2026-11-25"
} > "$WORK/census.txt"
cat > "$WORK/bus.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = send ] || exit 9
[ -z "${BUS_FAIL:-}" ] || { echo "bus: refused" >&2; exit 1; }
printf '%s %s\n' "$2" "$(tr '\n' ' ' < "$3")" >> "$WORK/bus.log"  # read-sink-ok: $3 is the body file the helper under test mktemps
echo "sent #42 to $2"
EOF
cat > "$WORK/launcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/launch.log"
EOF
cat > "$WORK/confirm.sh" <<'EOF'
#!/usr/bin/env bash
n=0; while [ "$n" -lt 50 ] && [ "$(wc -l 2>/dev/null < "$WORK/launch.log" || echo 0)" -le "$(wc -l 2>/dev/null < "$WORK/confirm.log" || echo 0)" ]; do sleep 0.1; n=$((n + 1)); done
printf '%s\n' "$*" >> "$WORK/confirm.log"
[ -z "${CONFIRM_FAIL:-}" ] || { echo "LAUNCH-UNCONFIRMED x no start" >&2; exit 1; }
echo "LAUNCH-CONFIRMED x pid=1"
EOF
chmod +x "$WORK"/*.sh
PROJ="$WORK/claude/projects/-demo"; mkdir -p "$PROJ"
{
    printf '{"type":"custom-title","customTitle":"DEMO-9-N9-w-2026-11-25","sessionId":"s9"}\n'
    printf '{"type":"agent-name","agentName":"DEMO-9-N9-w-2026-11-25","sessionId":"s9"}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"Running the suite."},{"type":"tool_use","name":"Bash"}]}}\n'
    printf '{"type":"user","message":{"content":"hook refused"}}\n'
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"BLOCKED: every hook refuses every tool call.\\nRun: git -C /w checkout tables.json"}]}}\n'
    printf '{"type":"user","message":{"content":"hook refused"}}\n'
} > "$PROJ/s9.jsonl"
printf '{"type":"custom-title","customTitle":"DEMO-99-N99-w-2026-11-25"}\n{"type":"assistant","message":{"content":[{"type":"text","text":"not N9"}]}}\n' > "$PROJ/s99.jsonl"
export WORK HIMMELCTL_CACHE_DIR="$WORK/cache" SILENT_ACT_NUDGE_GRACE_SECS=0 CLAUDE_CONFIG_DIR="$WORK/claude"
export SILENT_ACT_BUS="$WORK/bus.sh" SILENT_ACT_CENSUS="$WORK/census.sh" SILENT_ACT_LAUNCHER="$WORK/launcher.sh"
export SILENT_ACT_CONFIRM="$WORK/confirm.sh"
export HIMMEL_BUS_NAME="DEMO-chief-2026-11-25"
unset CHIEF_WAIT_WORKER_SILENT_MIN

run() { bash "$ACT" --doc "$CHIEF_DOC" --fleet "$MANIFEST" --bucket "$BUCKET" --chief DEMO-chief-2026-11-25 "$@" 2>&1; }
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }  # read-sink-ok: only the suite's own $WORK logs are counted
owed_count() { bash "$HERE/owe.sh" list --bucket "$BUCKET" | wc -l | tr -d ' '; }

out="$(run N1 161)"
check "1a. silent 161m, no live window: relaunched from its RESUME doc" "SILENT-ACT N1 nudge=no-window relaunched" "$out"
check "1b. one launch, with the worker's recorded profile, lane and model" "1" "$(count "$WORK/launch.log")"
case "$(cat "$WORK/launch.log" 2>/dev/null)" in
    *"--fleet $MANIFEST --profile worker-impl --lane native DEMO-1-N1-w-2026-11-25-RESUME $(W 1 | sed 's/\.md$/-RESUME.md/') "*" claude-sonnet-5-5") check "1c. launcher argv" ok ok ;;
    *) check "1c. launcher argv" ok "$(cat "$WORK/launch.log" 2>/dev/null)" ;;
esac
check "1d. the launch was confirmed" "1" "$(count "$WORK/confirm.log")"
case " $(cat "$WORK/confirm.log" 2>/dev/null) " in
    *" --secs 60 "*) check "1d2 (K1s). the waiter's confirm keeps a 60 s window" ok ok ;;
    *) check "1d2 (K1s). the waiter's confirm keeps a 60 s window" ok "$(cat "$WORK/confirm.log" 2>/dev/null)" ;;
esac
if tail -n1 "$CHIEF_DOC" | grep -q 'SILENT-ACT N1 nudge=no-window relaunched DEMO-1-N1-w-2026-11-25-RESUME silent=161m'; then
    check "1e. the chief doc logs the action and the worker" ok ok
else
    check "1e. the chief doc logs the action and the worker" ok "$(tail -n1 "$CHIEF_DOC")"
fi
check "1f. no owed row" "0" "$(owed_count)"

out="$(run N1 170)"
check "2a. the repeat acts on nothing" "SILENT-ACT N1 done" "$out"
check "2b. still one launch" "1" "$(count "$WORK/launch.log")"

out="$(run N2 161)"
check "3a. fresh doc write: untouched" "SILENT-ACT N2 fresh" "$out"
out="$(run N3 44)"
check "3b. 44 minutes: nothing" "SILENT-ACT N3 none" "$out"

out="$(run --signal succession-partial N3 161)"
check "4a. succession: the same relaunch" "SILENT-ACT N3 nudge=no-window relaunched" "$out"

out="$(run N4 161)"
check "5a. no RESUME doc: the relaunch fails and owes" "SILENT-ACT N4 nudge=no-window relaunch=failed owed=o1" "$out"
check "5b. one open owed row, kind step, naming the worker" "1" "$(bash "$HERE/owe.sh" list --bucket "$BUCKET" | awk -F'\t' '$2 == "step" && $6 ~ /N4/' | wc -l | tr -d ' ')"

out="$(run N5 161)"
check "6a. a RESUME window already runs: never launched twice" "SILENT-ACT N5 nudge=no-window live-window" "$out"
check "6b. launches unchanged" "2" "$(count "$WORK/launch.log")"

out="$(run N6 60)"
check "7a. past bound one only, no window: owed, no relaunch" "SILENT-ACT N6 nudge=no-window owed=o2" "$out"

out="$(run N7 161)"
check "8a. no launch record naming profile, lane and model: the relaunch fails and owes" "SILENT-ACT N7 nudge=no-window relaunch=failed owed=o3" "$out"

launches_before="$(count "$WORK/launch.log")"
out="$(SILENT_ACT_NUDGE_GRACE_SECS=300 run N9 161)"
check "9a. a live window past bound two is nudged first, and nothing else that call" "SILENT-ACT N9 nudged" "$out"
check "9b. its process is alive" "yes" "$(kill -0 "$LIVE_PID" 2>/dev/null && echo yes)"
out="$(SILENT_ACT_NUDGE_GRACE_SECS=300 run N9 161)"
check "9c. inside the nudge grace the next call waits" "SILENT-ACT N9 done" "$out"
out="$(run N9 161)"
check "9d. after the grace a live window is never ended or relaunched: it owes a named blocked step and quotes the worker's last words from its transcript" "SILENT-ACT N9 live-silent owed=o4 last=\"BLOCKED: every hook refuses every tool call. Run: git -C /w checkout tables.json\"" "$out"
case "$(tail -n1 "$CHIEF_DOC")" in *'last="BLOCKED: every hook refuses every tool call.'*) bullet_ok=1 ;; *) bullet_ok=0 ;; esac
if [ "$bullet_ok" -eq 1 ]; then
    check "9h. the chief doc bullet carries the last words" ok ok
else
    check "9h. the chief doc bullet carries the last words" ok "$(tail -n1 "$CHIEF_DOC")"
fi
check "9e. its process is still alive" "yes" "$(kill -0 "$LIVE_PID" 2>/dev/null && echo yes)"
check "9f. no launch ran" "$launches_before" "$(count "$WORK/launch.log")"
check "9g. one nudge went to it" "1" "$(grep -c '^DEMO-9-N9-w-2026-11-25 ' "$WORK/bus.log")"

out="$(CHIEF_WAIT_WORKER_SILENT_MIN=100 run N10 161)"
check "10a. bound 100: 161 minutes is past one, not past two" "SILENT-ACT N10 nudged" "$out"
touch "$(W 10)"; old "$(W 10)" 60
out="$(BUS_FAIL=1 run N10 60)"
check "10b. a bus refusal owes a row" "SILENT-ACT N10 nudge=failed owed=o5" "$out"

touch "$(W 3)"; old "$(W 3)" 170
out="$(CONFIRM_FAIL=1 run N3 170)"
check "11a. an unconfirmed launch owes" "SILENT-ACT N3 nudge=no-window relaunch=failed owed=o6" "$out"

census_launches="$(count "$WORK/launch.log")"
out="$(CENSUS_RC=3 run N11 161)"
check "14a. a partial census (rc 3) that does not show the worker never relaunches: it owes" "SILENT-ACT N11 nudge=no-window census=unknown owed=o7" "$out"
check "14b. and launched nothing" "$census_launches" "$(count "$WORK/launch.log")"
printf '%s\t%s\topus\t200000\n' 301 "DEMO-12-N12-w-2026-11-25" >> "$WORK/census.txt"
out="$(SILENT_ACT_NUDGE_GRACE_SECS=300 CENSUS_RC=3 run N12 161)"
check "14c. a partial census keeps its readable rows: the worker it shows is a live window, nudged first" "SILENT-ACT N12 nudged" "$out"
out="$(CENSUS_RC=3 run N12 161)"
check "14d. and after the grace it owes as a live window, never launched; with no transcript it carries no last words" "SILENT-ACT N12 live-silent owed=o8" "$out"
out="$(SILENT_ACT_CENSUS="$WORK/census-fail.sh" run N13 161)"
check "14e. a census that fails (rc 2) never relaunches: it owes" "SILENT-ACT N13 nudge=no-window census=unknown owed=o9" "$out"
out="$(SILENT_ACT_CENSUS='' SILENT_ACT_CENSUS_LIB="$WORK/no-such-lib.sh" run N14 161)"
check "14f. a census library that cannot be loaded never relaunches: it owes" "SILENT-ACT N14 nudge=no-window census=unknown owed=o10" "$out"
check "14g. none of the four launched" "$census_launches" "$(count "$WORK/launch.log")"

bash "$ACT" --doc "$CHIEF_DOC" >/dev/null 2>&1; check "12a. missing arguments exit 2" "2" "$?"

if command -v flock >/dev/null 2>&1; then
    nudges_before="$(count "$WORK/bus.log")"
    exec 7>>"$BUCKET/silent-act.N8.lock"; flock -n 7
    out="$(run N8 161)"
    exec 7>&-
    check "13a. a second helper on a worker already being acted on is busy" "SILENT-ACT N8 busy" "$out"
    check "13b. and sent no nudge" "$nudges_before" "$(count "$WORK/bus.log")"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
