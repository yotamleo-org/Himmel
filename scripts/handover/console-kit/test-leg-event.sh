#!/usr/bin/env bash
# scripts/handover/console-kit/test-leg-event.sh - suite for leg-event.sh, the
# marker router that sends a leg's MERGED / WRAPPED message to wrap-merged.sh
# and escalates everything else. Hermetic: wrap-merged.sh and the manifest
# listing are stubs (the LE_WRAP / LE_LIST seams).
#
# Cases:
#   1. usage: missing --doc / --fleet / message              -> rc 2
#   2. MERGED #<pr> N<k>: wrap-merged gets --doc --fleet <leg doc> --pr <pr> -> HANDLED, rc 0
#   3. WRAPPED N<k> with no PR: no --pr passed               -> HANDLED, rc 0
#   4. READY / FINDING / unknown marker                      -> ESCALATE, rc 10, wrap-merged not run
#   5. no leg label in the message                           -> ESCALATE, rc 10
#   6. label not in the manifest                             -> ESCALATE, rc 10
#   7. wrap-merged fails (rc 3)                              -> ESCALATE naming rc=3, rc 10
#   8. message on stdin ("-") and a leading "- " bullet marker
#
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/leg-event.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/le-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { case "$2" in *"$3"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$2] does not contain [$3]"; fails=$((fails+1)) ;; esac; }
lacks()    { case "$2" in *"$3"*) echo "FAIL - $1: [$2] contains [$3]"; fails=$((fails+1)) ;; *) echo "ok - $1" ;; esac; }

cat > "$W/wrap" <<'EOF'
#!/usr/bin/env bash
echo "wrap $*" >> "$LE_CALLS"
[ -z "${LE_WRAP_ERR:-}" ] || echo "$LE_WRAP_ERR" >&2
exit "${LE_WRAP_RC:-0}"
EOF
cat > "$W/list" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' /h/HIMMEL-1-N2078-foo-2026-10-14.md /h/HIMMEL-2-N2088-bar-2026-10-14.md
EOF
chmod +x "$W/wrap" "$W/list"
export LE_WRAP="$W/wrap" LE_LIST="$W/list" LE_CALLS="$W/calls"
: > "$W/doc"
run() { : > "$LE_CALLS"; printf '%s\n' "$1" > "$W/msg"; out="$(bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" "$W/msg" 2>/dev/null)"; rc=$?; calls="$(cat "$LE_CALLS")"; }

bash "$SCRIPT" >/dev/null 2>&1; check "1 no args rc" "$?" 2
bash "$SCRIPT" --doc "$W/doc" "$W/msg" >/dev/null 2>&1; check "1 no fleet rc" "$?" 2

run "MERGED #2566 → abcdef01 (N2088)"
check "2 rc" "$rc" 0
contains "2 stdout" "$out" "HANDLED wrap-merged N2088"
contains "2 wrap args" "$calls" "wrap --doc $W/doc --fleet $W/fleet.json /h/HIMMEL-2-N2088-bar-2026-10-14.md --pr 2566"

run "WRAPPED N2078. Lock released."
check "3 rc" "$rc" 0
contains "3 leg doc" "$calls" "/h/HIMMEL-1-N2078-foo-2026-10-14.md"
lacks "3 no --pr" "$calls" "--pr"

# a leg message that leads with its label and ticket key still routes
run "N2088 HIMMEL-2 MERGED #2566 → abcdef01 WRAPPED: lock released"
check "3b label-first rc" "$rc" 0
contains "3b label-first args" "$calls" "--pr 2566"

for m in "READY 2553 0780b95dcad44fe293c7798066626cd52bb2dce N2088" "FINDING N2088 (token x): q" "PUSHED abc N2088"; do
    run "$m"
    check "4 rc [$m]" "$rc" 10
    contains "4 escalate [$m]" "$out" "ESCALATE"
    check "4 wrap not run [$m]" "$calls" ""
done

run "WRAPPED. All done."
check "5 rc" "$rc" 10
contains "5 reason" "$out" "no-label"

run "WRAPPED N9999"
check "6 rc" "$rc" 10
contains "6 reason" "$out" "not-in-manifest"
check "6 wrap not run" "$calls" ""

run "WRAPPED N2078 after N2088 merged"
check "6b two labels rc" "$rc" 10
contains "6b reason" "$out" "ambiguous-label"
check "6b wrap not run" "$calls" ""

run "WRAPPED N2078 (N2078 again)"
check "6c same label twice rc" "$rc" 0

LE_WRAP_RC=3 LE_WRAP_ERR="wrap-merged: step pr-state failed: PR #2566 is 'OPEN'" run "MERGED #2566 N2088"
check "7 rc" "$rc" 10
contains "7 escalate rc" "$out" "ESCALATE wrap-merged-failed rc=3"
contains "7 step surfaced" "$out" "step pr-state failed"

printf -- '- MERGED #2566 N2088\n' | bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" - >"$W/o" 2>&1; rc=$?
check "8 stdin bullet rc" "$rc" 0
contains "8 handled" "$(cat "$W/o")" "HANDLED wrap-merged N2088"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
