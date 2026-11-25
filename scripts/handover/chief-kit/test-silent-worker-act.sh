#!/usr/bin/env bash
# test-silent-worker-act.sh — silent-worker-act.sh nudges a silent worker once on the bus past
# bound one, relaunches it from its RESUME doc past bound two, owes a row on any failed step,
# acts the same under a succession signal, and leaves a worker with a fresh doc write alone.
# The bus, the process census, the launcher, the launch confirmation and the kill are stubbed
# (SILENT_ACT_BUS / _CENSUS / _LAUNCHER / _CONFIRM / _KILL); owe.sh and append-results.sh are real,
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
trap 'rm -rf "$WORK"' EXIT

NOW="$(date +%s)"
old() { touch -d "@$((NOW - $2 * 60))" "$1"; }

BUCKET="$WORK/bucket"; mkdir -p "$BUCKET"
CHIEF_DOC="$BUCKET/DEMO-chief-2026-11-25.md"
printf '# chief\n\n## Results\n\n- 10:00 LIVE - x\n' > "$CHIEF_DOC"
W1="$BUCKET/DEMO-1-N1-silent-2026-11-25.md"
W2="$BUCKET/DEMO-2-N2-fresh-2026-11-25.md"
W3="$BUCKET/DEMO-3-N3-succ-2026-11-25.md"
W4="$BUCKET/DEMO-4-N4-noresume-2026-11-25.md"
W5="$BUCKET/DEMO-5-N5-hasresume-2026-11-25.md"
W6="$BUCKET/DEMO-6-N6-nonudge-2026-11-25.md"
W7="$BUCKET/DEMO-7-N7-stuck-2026-11-25.md"
W8="$BUCKET/DEMO-8-N8-busy-2026-11-25.md"
for f in "$W1" "$W2" "$W3" "$W4" "$W5" "$W6" "$W7" "$W8"; do printf '# worker\n\n## Results\n\n- 10:00 LIVE - x\n' > "$f"; done
for f in "$W1" "$W3" "$W4" "$W5" "$W6" "$W7" "$W8"; do old "$f" 161; done
for n in 1 3 5 7; do
    d="$(ls "$BUCKET"/DEMO-$n-N*-2026-11-25.md)"
    printf '# resume\n\n## Results\n\n- 10:00 LIVE - x\n' > "${d%.md}-RESUME.md"
done
MANIFEST="$BUCKET/DEMO-chief-2026-11-25.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1","lane":"native"},{"doc":"%s","label":"N2","lane":"native"},{"doc":"%s","label":"N3","lane":"native"},{"doc":"%s","label":"N4","lane":"native"},{"doc":"%s","label":"N5","lane":"native"},{"doc":"%s","label":"N6","lane":"native"},{"doc":"%s","label":"N7","lane":"native"},{"doc":"%s","label":"N8","lane":"native"}]}\n' \
    "$W1" "$W2" "$W3" "$W4" "$W5" "$W6" "$W7" "$W8" > "$MANIFEST"

printf '#!/usr/bin/env bash\ncat "%s/census.txt"\n' "$WORK" > "$WORK/census.sh"
: > "$WORK/census.txt"
for n in DEMO-1-N1-silent-2026-11-25:101 DEMO-2-N2-fresh-2026-11-25:102 DEMO-3-N3-succ-2026-11-25:103 DEMO-5-N5-hasresume-2026-11-25:105 DEMO-5-N5-hasresume-2026-11-25-RESUME:205 DEMO-7-N7-stuck-2026-11-25:107 DEMO-8-N8-busy-2026-11-25:108; do
    printf '%s\t%s\topus\t200000\n' "${n##*:}" "${n%:*}" >> "$WORK/census.txt"
done
cat > "$WORK/bus.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = send ] || exit 9
[ -z "${BUS_FAIL:-}" ] || { echo "bus: refused" >&2; exit 1; }
printf '%s %s\n' "$2" "$(tr '\n' ' ' < "$3")" >> "$WORK/bus.log"
echo "sent #42 to $2"
EOF
cat > "$WORK/launcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/launch.log"
EOF
cat > "$WORK/confirm.sh" <<'EOF'
#!/usr/bin/env bash
# the launcher runs detached: wait for its record before confirming
n=0; while [ "$n" -lt 50 ] && [ "$(wc -l 2>/dev/null < "$WORK/launch.log" || echo 0)" -le "$(wc -l 2>/dev/null < "$WORK/confirm.log" || echo 0)" ]; do sleep 0.1; n=$((n + 1)); done
printf '%s\n' "$*" >> "$WORK/confirm.log"
[ -z "${CONFIRM_FAIL:-}" ] || { echo "LAUNCH-UNCONFIRMED x no start" >&2; exit 1; }
echo "LAUNCH-CONFIRMED x pid=1"
EOF
cat > "$WORK/kill.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORK/kill.log"
EOF
cat > "$WORK/alive.sh" <<'EOF'
#!/usr/bin/env bash
[ -n "${ALIVE:-}" ]
EOF
chmod +x "$WORK"/*.sh
export WORK SILENT_ACT_ALIVE="$WORK/alive.sh" SILENT_ACT_KILL_TRIES=1
export SILENT_ACT_BUS="$WORK/bus.sh" SILENT_ACT_CENSUS="$WORK/census.sh" SILENT_ACT_LAUNCHER="$WORK/launcher.sh"
export SILENT_ACT_CONFIRM="$WORK/confirm.sh" SILENT_ACT_KILL="$WORK/kill.sh"
export HIMMEL_BUS_NAME="DEMO-chief-2026-11-25"
unset CHIEF_WAIT_WORKER_SILENT_MIN

run() { bash "$ACT" --doc "$CHIEF_DOC" --fleet "$MANIFEST" --bucket "$BUCKET" --chief DEMO-chief-2026-11-25 "$@" 2>&1; }
count() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

out="$(run N1 161)"
check "1a. silent 161m: nudged and relaunched" "SILENT-ACT N1 nudged relaunched" "$out"
check "1b. one bus nudge, to the stale session" "1" "$(count "$WORK/bus.log")"
check "1c. the nudge names the stale session" "DEMO-1-N1-silent-2026-11-25" "$(cut -d' ' -f1 "$WORK/bus.log")"
check "1d. the stale window is ended once (pid 101)" "101" "$(cat "$WORK/kill.log" 2>/dev/null)"
check "1e. one launch, on the RESUME doc, under its own session name" "1" "$(count "$WORK/launch.log")"
case "$(cat "$WORK/launch.log" 2>/dev/null)" in
    *"--fleet $MANIFEST DEMO-1-N1-silent-2026-11-25-RESUME $BUCKET/DEMO-1-N1-silent-2026-11-25-RESUME.md "*) check "1f. launcher argv" ok ok ;;
    *) check "1f. launcher argv" ok "$(cat "$WORK/launch.log" 2>/dev/null)" ;;
esac
check "1g. the launch was confirmed" "1" "$(count "$WORK/confirm.log")"
if tail -n1 "$CHIEF_DOC" | grep -q 'SILENT-ACT N1 nudged bus=#42 relaunched DEMO-1-N1-silent-2026-11-25-RESUME silent=161m'; then
    check "1h. the chief doc logs the action and the worker" ok ok
else
    check "1h. the chief doc logs the action and the worker" ok "$(tail -n1 "$CHIEF_DOC")"
fi
check "1i. no owed row" "0" "$(bash "$HERE/owe.sh" list --bucket "$BUCKET" | wc -l | tr -d ' ')"

out="$(run N1 170)"
check "2a. the repeat acts on nothing" "SILENT-ACT N1 done" "$out"
check "2b. still one nudge, one launch" "1 1" "$(count "$WORK/bus.log") $(count "$WORK/launch.log")"

out="$(run N2 161)"
check "3a. fresh doc write: untouched" "SILENT-ACT N2 fresh" "$out"
check "3b. no new bus record or launch" "1 1" "$(count "$WORK/bus.log") $(count "$WORK/launch.log")"

out="$(run N3 44)"
check "4a. 44 minutes: nothing" "SILENT-ACT N3 none" "$out"

out="$(run --signal succession-partial N3 161)"
check "5a. succession: nudged and relaunched" "SILENT-ACT N3 nudged relaunched" "$out"
check "5b. two nudges, two launches in all" "2 2" "$(count "$WORK/bus.log") $(count "$WORK/launch.log")"

out="$(run N4 161)"
check "6a. no RESUME doc: the relaunch fails and owes" "SILENT-ACT N4 nudge=no-window relaunch=failed owed=o1" "$out"
check "6b. one open owed row, kind step, naming the worker" "1" "$(bash "$HERE/owe.sh" list --bucket "$BUCKET" | awk -F'\t' '$2 == "step" && $6 ~ /N4/' | wc -l | tr -d ' ')"

out="$(run N5 161)"
check "7a. RESUME window live: nudged, relaunch skipped" "SILENT-ACT N5 nudged live-window" "$out"
check "7b. launches unchanged" "2" "$(count "$WORK/launch.log")"

out="$(BUS_FAIL=1 run N1 60)"
check "8a. an unchanged doc write is done even when the bus would fail" "SILENT-ACT N1 done" "$out"
touch "$W1"; old "$W1" 60
out="$(BUS_FAIL=1 run N1 60)"
check "8b. a bus refusal owes a row" "SILENT-ACT N1 nudge=failed owed=o2" "$out"
out="$(run N6 60)"
check "8c. past bound one, no window: owed, no relaunch" "SILENT-ACT N6 nudge=no-window owed=o3" "$out"

touch "$W3"; old "$W3" 170
out="$(CONFIRM_FAIL=1 run N3 170)"
check "9a. unconfirmed launch owes" "SILENT-ACT N3 nudged relaunch=failed owed=o4" "$out"

touch "$W5"; old "$W5" 180
out="$(CHIEF_WAIT_WORKER_SILENT_MIN=100 run N5 161)"
check "10a. bound 100: 161 minutes is past one, not past two" "SILENT-ACT N5 nudged" "$out"

bash "$ACT" --doc "$CHIEF_DOC" >/dev/null 2>&1; check "11a. missing arguments exit 2" "2" "$?"

launches_before="$(count "$WORK/launch.log")"
out="$(ALIVE=1 run N7 161)"
check "12a. a stale window that does not end is never launched over, and owes" "SILENT-ACT N7 nudged relaunch=failed owed=o5" "$out"
check "12b. no launch ran" "$launches_before" "$(count "$WORK/launch.log")"

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
