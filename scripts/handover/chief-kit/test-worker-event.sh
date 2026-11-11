#!/usr/bin/env bash
# scripts/handover/chief-kit/test-worker-event.sh - suite for worker-event.sh, the
# marker router that sends a worker's MERGED / WRAPPED message to wrap-merged.sh
# and escalates everything else. Hermetic: wrap-merged.sh and the manifest
# listing are stubs (the LE_WRAP / LE_LIST seams).
#
# Cases:
#   1. usage: missing --doc / --fleet / message              -> rc 2
#   2. MERGED #<pr> N<k>: wrap-merged gets --doc --fleet <worker doc> --pr <pr> -> HANDLED, rc 0
#   3. WRAPPED N<k> with no PR: no --pr passed               -> HANDLED, rc 0
#   4. READY / FINDING / unknown marker                      -> ESCALATE, rc 10, wrap-merged not run
#   5. no worker label in the message                           -> ESCALATE, rc 10
#   6. label not in the manifest                             -> ESCALATE, rc 10
#   7. wrap-merged fails (rc 3)                              -> ESCALATE naming rc=3, rc 10
#   8. message on stdin ("-") and a leading "- " bullet marker
#   12. a WRAPPED message that mentions deferred / follow-up / residual with no key -> ESCALATE
#   13. a WRAPPED worker whose doc has no PR: close-wrapped-worker.sh runs, HANDLED close-wrapped; a refused close -> ESCALATE
#   14. a label already closed (wrap-merged's `<label> WRAPPED, window closed.` bullet in the chief doc) -> HANDLED noop
#   15. READY with the auto_go flag on: auto-go.sh runs live; a sent GO -> HANDLED auto-go and an AUTO-GO bullet,
#       an auto-go refusal -> passed on and an AUTO-GO-REFUSED bullet, GO written but not sent -> rc 11
#
# Platform guard: Linux bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/worker-event.sh"

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
if [ "${LE_WRAP_PRINT:-}" = 1 ]; then printf '%s\n' "wrap-merged: closing" "pr=999" "wrap-merged: merged pr=123 sha=abcdef12"; fi
exit "${LE_WRAP_RC:-0}"
EOF
cat > "$W/list" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' /h/HIMMEL-1-N2078-foo-2026-10-14.md /h/HIMMEL-2-N2088-bar-2026-10-14.md /h/HIMMEL-3-qux-2026-10-14.md
EOF
cat > "$W/live" <<'EOF2'
#!/usr/bin/env bash
echo "live $*" >> "$LE_LIVE_CALLS"
[ -z "${LE_LIVE_ERR:-}" ] || echo "$LE_LIVE_ERR" >&2
exit "${LE_LIVE_RC:-0}"
EOF2
chmod +x "$W/wrap" "$W/list" "$W/live"
export LE_STATION_LOG="$W/station.log" LE_WRAP="$W/wrap" LE_LIST="$W/list" LE_STATION="$W/station" LE_CALLS="$W/calls" LE_LIVE="$W/live" LE_LIVE_CALLS="$W/live-calls"
: > "$W/doc"
run() { : > "$LE_CALLS"; : > "$LE_LIVE_CALLS"; printf '%s\n' "$1" > "$W/msg"; out="$(bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" "$W/msg" 2>/dev/null)"; rc=$?; calls="$(cat "$LE_CALLS")"; }

bash "$SCRIPT" >/dev/null 2>&1; check "1 no args rc" "$?" 2
bash "$SCRIPT" --doc "$W/doc" "$W/msg" >/dev/null 2>&1; check "1 no fleet rc" "$?" 2

run "MERGED #2566 → abcdef01 (N2088)"
check "2 rc" "$rc" 0
contains "2 stdout" "$out" "HANDLED wrap-merged N2088"
contains "2 wrap args" "$calls" "wrap --doc $W/doc --fleet $W/fleet.json /h/HIMMEL-2-N2088-bar-2026-10-14.md --pr 2566"

run "WRAPPED N2078. Lock released."
check "3 rc" "$rc" 0
contains "3 worker doc" "$calls" "/h/HIMMEL-1-N2078-foo-2026-10-14.md"
lacks "3 no --pr" "$calls" "--pr"

# a worker message that leads with its label and ticket key still routes
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

# a MERGED/WRAPPED from N4304 finds the resumed manifest entry N4304b
cat > "$W/list-resume" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "${1##*/}" = fleet.json ] || exit 1
echo ok >> "$0.ran"
printf '%s\n' /h/HIMMEL-1-N2078-foo-2026-10-14.md /h/HIMMEL-8-N4304b-resumed-2026-10-31-RESUME.md
EOF
chmod +x "$W/list-resume"
LE_LIST="$W/list-resume" run "MERGED #4400 → abcdef01 (N4304)"
check "6d 8424 N4304 message, N4304b manifest entry: rc" "$rc" 0
contains "6d 8424 HANDLED" "$out" "HANDLED wrap-merged N4304"
contains "6d 8424 wrap gets the resumed entry" "$calls" "/h/HIMMEL-8-N4304b-resumed-2026-10-31-RESUME.md --pr 4400"
cat > "$W/list-resume2" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "${1##*/}" = fleet.json ] || exit 1
echo ok >> "$0.ran"
printf '%s\n' /h/HIMMEL-8-N4304b-resumed-2026-10-31-RESUME.md /h/HIMMEL-8-N4304c-resumed-2026-11-01-RESUME.md
EOF
chmod +x "$W/list-resume2"
LE_LIST="$W/list-resume2" run "MERGED #4400 → abcdef01 (N4304)"
check "6d2 8424 two resumed entries for one label: rc" "$rc" 10
contains "6d2 8424 reason" "$out" "ESCALATE ambiguous-label"
check "6d2 8424 wrap not run" "$calls" ""
# a replay of a label already recorded closed cannot tell the closed worker from its successor
printf '%s\n' '- 10:00 N4304 WRAPPED, window closed.' > "$W/doc"
LE_LIST="$W/list-resume" run "MERGED #4400 → abcdef01 (N4304)"
check "6d3 8424 closed label with a successor entry: rc" "$rc" 10
contains "6d3 8424 reason" "$out" "ESCALATE ambiguous-label"
check "6d3 8424 wrap not run" "$calls" ""
: > "$W/doc"
# the label must match the doc's file name, not a directory or slug that mentions it
cat > "$W/list-slug" <<'EOF'
#!/usr/bin/env bash
[ "$#" -eq 1 ] && [ "${1##*/}" = fleet.json ] || exit 1
echo ok >> "$0.ran"
printf '%s\n' /h/N4304b-dir/HIMMEL-8-N9000-check-status.md /h/HIMMEL-8-N9000-see-N4304b-note.md
EOF
chmod +x "$W/list-slug"
# a list stub that failed would read as an empty manifest and make the not-in-manifest rows pass: prove it listed
rm -f "$W/list-slug.ran" "$W/list-resume.ran"
LE_LIST="$W/list-slug" run "WRAPPED N4304"
check "6d4 8424 a directory or slug naming N4304b is not the worker: rc" "$rc" 10
contains "6d4 8424 reason" "$out" "not-in-manifest N4304"
check "6d4 8424 wrap not run" "$calls" ""
check "6d4 8424 the list stub ran and listed" "$(cat "$W/list-slug.ran" 2>/dev/null)" "ok"
LE_LIST="$W/list-resume" run "WRAPPED N43"
check "6e 8424 a shorter label never matches N4304b: rc" "$rc" 10
contains "6e 8424 reason" "$out" "not-in-manifest N43"
check "6e 8424 the list stub ran and listed" "$(cat "$W/list-resume.ran" 2>/dev/null)" "ok"
rm -f "$W/list-resume.ran"
LE_LIST="$W/list-resume" run "WRAPPED N4399"
check "6f 8424 an unrelated label still escalates: rc" "$rc" 10
contains "6f 8424 reason" "$out" "not-in-manifest N4399"
check "6f 8424 wrap not run" "$calls" ""
check "6f 8424 the list stub ran and listed" "$(cat "$W/list-resume.ran" 2>/dev/null)" "ok"

LE_WRAP_RC=3 LE_WRAP_ERR="wrap-merged: step pr-state failed: PR #2566 is 'OPEN'" run "MERGED #2566 N2088"
check "7 rc" "$rc" 10
contains "7 escalate rc" "$out" "ESCALATE wrap-merged-failed rc=3"
contains "7 step surfaced" "$out" "step pr-state failed"

printf -- '- MERGED #2566 N2088\n' | bash "$SCRIPT" --doc "$W/doc" --fleet "$W/fleet.json" - >"$W/o" 2>&1; rc=$?
check "8 stdin bullet rc" "$rc" 0
contains "8 handled" "$(cat "$W/o")" "HANDLED wrap-merged N2088"

# 12. the station sync after a MERGED
cat > "$W/station" <<'EOF'
#!/usr/bin/env bash
echo "station $*" >> "$LE_CALLS"
echo "STEP marketplace rc=0"
echo "STATION=${LE_STATION_VAL:-OK}"
exit "${LE_STATION_RC:-0}"
EOF
chmod +x "$W/station"

# The sync runs detached (its --versions fetches and rebuilds are unbounded): the
# line comes back at once with station=pending, the sync's output lands in the log
# and its verdict in the state file tick.sh reads.
export LE_STATION_LOG="$W/station.log"
await() { local i=0; while [ "$i" -lt 50 ]; do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

: > "$LE_STATION_LOG"
run "MERGED #2566 → abcdef01 (N2088)"
await "$LE_CALLS" "station --pr 2566"; check "12 station sync gets the PR" "$?" 0
contains "12 line says pending and names the log" "$out" "HANDLED wrap-merged N2088 station=pending log=$LE_STATION_LOG"
await "$LE_STATION_LOG" "STATION=OK"; check "12 sync output lands in the log" "$?" 0

cat > "$W/station-ld" <<'EOF'
#!/usr/bin/env bash
echo "LOCAL-DIFF luna_template scripts/foo.sh: echo local-patch"
echo "STATION=BEHIND:luna_template"
EOF
chmod +x "$W/station-ld"
: > "$LE_STATION_LOG"
LE_STATION="$W/station-ld" run "MERGED #2566 N2088"
await "$LE_STATION_LOG" "LOCAL-DIFF luna_template scripts/foo.sh: echo local-patch"; check "12 local-diff hunk reaches the log" "$?" 0

cat > "$W/station-hang" <<'EOF'
#!/usr/bin/env bash
sleep 6
EOF
chmod +x "$W/station-hang"
t0=$SECONDS
LE_STATION="$W/station-hang" run "MERGED #2566 N2088"
check "12 a hanging sync does not delay the handling" "$(( SECONDS - t0 < 4 ))" 1
check "12 hanging sync handled rc" "$rc" 0
contains "12 hanging sync still prints HANDLED" "$out" "HANDLED wrap-merged N2088 station=pending"
pkill -f "$W/station-hang" 2>/dev/null || true

run "WRAPPED N2078"
lacks "12 WRAPPED runs no station sync" "$calls" "station"

# 12e. a WRAPPED wrap starts the sync for the PR wrap-merged proved, not a bullet or other output
printf '%s\n' '# worker' '- PR 111 opened' '- READY 222 abcdef0123456789abcdef0123456789abcdef01 GREEN' '- WRAPPED — done' > "$W/HIMMEL-5-N5050-real-2026-11-04.md"
cat > "$W/list-real" <<'EOF3'
#!/usr/bin/env bash
printf '%s\n' "$LE_REAL_DOC"
EOF3
chmod +x "$W/list-real"
: > "$LE_STATION_LOG"
LE_REAL_DOC="$W/HIMMEL-5-N5050-real-2026-11-04.md" LE_LIST="$W/list-real" LE_WRAP_PRINT=1 run "WRAPPED N5050 done"
await "$LE_CALLS" "station --pr 123"; check "12e WRAPPED wrap starts station-sync with the PR wrap-merged proved" "$?" 0
contains "12e WRAPPED line says pending" "$out" "station=pending"
lacks "12e no --pr 111" "$(cat "$LE_CALLS")" "station --pr 111"
lacks "12e no --pr 222" "$(cat "$LE_CALLS")" "station --pr 222"
lacks "12e no --pr 999" "$(cat "$LE_CALLS")" "station --pr 999"
LE_WRAP_PRINT=1 run "MERGED #456 N2088"
await "$LE_CALLS" "station --pr 456"; check "12e a MERGED line keeps its own PR" "$?" 0
lacks "12e MERGED does not take the printed PR" "$(cat "$LE_CALLS")" "station --pr 123"

LE_WRAP_RC=3 run "MERGED #2566 N2088"
lacks "12 failed wrap runs no station sync" "$calls" "station"

# 9. the worker named only by its session name (the worker doc's stem) routes
run "WRAPPED HIMMEL-2-N2088-bar-2026-10-14 lock released"
check "9 session-name rc" "$rc" 0
contains "9 session-name worker doc" "$calls" "/h/HIMMEL-2-N2088-bar-2026-10-14.md"
run "WRAPPED HIMMEL-1-N2078-foo-2026-10-14 and HIMMEL-2-N2088-bar-2026-10-14"
check "9b two sessions rc" "$rc" 10
run "WRAPPED HIMMEL-3-qux-2026-10-14 lock released"
check "9d label-less session rc" "$rc" 0
contains "9d label-less session worker doc" "$calls" "/h/HIMMEL-3-qux-2026-10-14.md"
run "WRAPPED HIMMEL-3-qux-2026-10-14-retry lock released"
contains "9e longer unlisted session does not match a listed stem" "$out" "ESCALATE no-label"
run "WRAPPED HIMMEL-9-nobody-2026-10-14"
contains "9c unknown session still no-label" "$out" "ESCALATE no-label"

# 10. a handled event re-renders the workers line; an escalated one does not
run "WRAPPED N2078"
contains "10 live-state ran" "$(cat "$LE_LIVE_CALLS")" "live $W/doc"
run "READY 1 abc N2078"
check "10b no live-state on escalate" "$(cat "$LE_LIVE_CALLS")" ""
LE_WRAP_RC=3 run "WRAPPED N2078"
check "10c no live-state when wrap failed" "$(cat "$LE_LIVE_CALLS")" ""
LE_LIVE_RC=1 LE_LIVE_ERR="live-state: boom" run "WRAPPED N2078"
check "10d live-state failure rc" "$rc" 0
contains "10d live-state failure surfaced" "$out" "live-state=failed"

# 11. end to end with the real live-state.sh: the wrapped worker leaves the workers line
cat > "$W/c.md" <<'EOF2'
# chief

## Live state
legs: `N2078:nonce1:tok:11`
tick: x
EOF2
printf '{"legs":[]}\n' > "$W/c.fleet.json"
printf 'WRAPPED N2078\n' > "$W/msg"
out="$(LE_LIVE='' bash "$SCRIPT" --doc "$W/c.md" --fleet "$W/c.fleet.json" "$W/msg" 2>/dev/null)"; rc=$?
check "11 rc" "$rc" 0
lacks "11 workers line drops the wrapped worker" "$(cat "$W/c.md")" "N2078:"
contains "11 workers line is none" "$(cat "$W/c.md")" "workers: none"

# 12. a WRAPPED message that mentions deferred / follow-up / residual must name a ticket
run "WRAPPED N2078. Deferred: the retry path."
check "12a unkeyed deferred rc" "$rc" 10
contains "12a escalate reason" "$out" "ESCALATE unfiled-residual"
contains "12a names the line" "$out" "Deferred: the retry path."
check "12a wrap not run" "$calls" ""
run "$(printf 'WRAPPED N2078\n- follow-up: tighten the regex\n')"
check "12b unkeyed follow-up on a later line rc" "$rc" 10
run "WRAPPED N2078. Residual risk left for later."
check "12c unkeyed residual rc" "$rc" 10
run "WRAPPED N2078. Follow-up filed as HIMMEL-6200."
check "12d keyed follow-up rc" "$rc" 0
run "WRAPPED N2078. Deferred the retry path, no-ticket: operator accepted."
check "12e no-ticket reason rc" "$rc" 0
run "WRAPPED N2078. Deferred the retry path, no-ticket:"
check "12f empty no-ticket reason rc" "$rc" 10
run "WRAPPED N2078. No residuals, nothing deferred."
check "12g a negated mention rc" "$rc" 0
run "WRAPPED N2078. No residuals; follow-up: fix the retry path"
check "12g2 a negated mention does not hide an affirmative one on the same line rc" "$rc" 10
run "WRAPPED N2078. No residuals or follow-ups."
check "12g3 a coordinated negation rc" "$rc" 0
run "WRAPPED N2078 without fixing residuals"
check "12g4 an intervening non-modifier word is not a negation rc" "$rc" 10
run "WRAPPED N2078. No further follow-ups."
check "12g5 a modifier between the negator and the mention rc" "$rc" 0
run "WRAPPED N2078. Lock released."
check "12h a plain wrap rc" "$rc" 0
run "MERGED #2566 → abcdef01 N2088. Follow-up: x"
check "12i MERGED is not checked here rc" "$rc" 0

# 13. a WRAPPED worker whose doc names no PR (a research worker) is closed directly, not sent to wrap-merged
cat > "$W/close" <<'EOF3'
#!/usr/bin/env bash
echo "close $*" >> "$LE_CALLS"
[ -z "${LE_CLOSE_ERR:-}" ] || echo "$LE_CLOSE_ERR" >&2
exit "${LE_CLOSE_RC:-0}"
EOF3
chmod +x "$W/close"
export LE_CLOSE="$W/close"
printf '%s\n' '## Results' '- 10:00 LIVE - start' '- 10:30 WRAPPED research done' > "$W/HIMMEL-4-N3001-research-2026-10-14.md"
printf '%s\n' '## Results' '- 10:00 READY 2553 abc' > "$W/HIMMEL-5-N3002-shipped-2026-10-14.md"
cat > "$W/list13" <<EOF3
#!/usr/bin/env bash
printf '%s\n' $W/HIMMEL-4-N3001-research-2026-10-14.md $W/HIMMEL-5-N3002-shipped-2026-10-14.md
EOF3
chmod +x "$W/list13"

LE_LIST="$W/list13" run "WRAPPED N3001. Research only."
check "13 no-PR rc" "$rc" 0
contains "13 no-PR prints HANDLED" "$out" "HANDLED close-wrapped N3001"
contains "13 close gets the fleet and the worker doc" "$calls" "close --fleet $W/fleet.json $W/HIMMEL-4-N3001-research-2026-10-14.md"
lacks "13 wrap-merged not run" "$calls" "wrap --doc"
# read-sink-ok: LE_LIVE_CALLS is the suite's own scratch file under $W
contains "13 live-state ran" "$(cat "$LE_LIVE_CALLS")" "live $W/doc"

LE_LIST="$W/list13" run "WRAPPED N3002."
contains "13 a doc with a PR still goes to wrap-merged" "$calls" "wrap --doc"
lacks "13 a doc with a PR does not close directly" "$calls" "close"

LE_CLOSE_RC=3 LE_CLOSE_ERR="close-wrapped-worker: refusing - queue lock held" LE_LIST="$W/list13" run "WRAPPED N3001."
check "13 refused close rc" "$rc" 10
contains "13 refused close escalates" "$out" "ESCALATE close-wrapped-failed rc=3"
contains "13 refusal surfaced" "$out" "queue lock held"
# read-sink-ok: LE_LIVE_CALLS is the suite's own scratch file under $W
check "13 refused close runs no live-state" "$(cat "$LE_LIVE_CALLS")" ""

OPEN_ERR="wrap-merged: step pr-state failed: PR #2553 is 'OPEN', not MERGED"
LE_WRAP_RC=3 LE_WRAP_ERR="$OPEN_ERR" LE_LIST="$W/list13" run "WRAPPED N3002. PR 2553 open."
check "13e open-PR wrap rc" "$rc" 0
contains "13e open-PR wrap prints HANDLED close-wrapped" "$out" "HANDLED close-wrapped N3002"
contains "13e wrap-merged ran first" "$calls" "wrap --doc"
contains "13e close gets the fleet and the worker doc" "$calls" "close --fleet $W/fleet.json $W/HIMMEL-5-N3002-shipped-2026-10-14.md"
lacks "13e open-PR wrap starts no station sync" "$out" "station=pending"
# read-sink-ok: LE_LIVE_CALLS is the suite's own scratch file under $W
contains "13e live-state ran" "$(cat "$LE_LIVE_CALLS")" "live $W/doc"
LE_WRAP_RC=3 LE_WRAP_ERR="$OPEN_ERR" LE_CLOSE_RC=4 LE_CLOSE_ERR="close-wrapped-worker: refusing - not WRAPPED" LE_LIST="$W/list13" run "WRAPPED N3002."
check "13e refused close rc" "$rc" 10
contains "13e refused close escalates" "$out" "ESCALATE close-wrapped-failed rc=4"
contains "13e refusal surfaced" "$out" "not WRAPPED"
LE_WRAP_RC=3 LE_WRAP_ERR="wrap-merged: step pr-state failed: gh pr view 2553: could not resolve" LE_LIST="$W/list13" run "WRAPPED N3002."
check "13e unreadable PR rc" "$rc" 10
contains "13e unreadable PR escalates wrap-merged-failed" "$out" "ESCALATE wrap-merged-failed rc=3"
lacks "13e unreadable PR: close not run" "$calls" "close"
LE_WRAP_RC=3 LE_WRAP_ERR="$OPEN_ERR" LE_LIST="$W/list13" run "MERGED #2553 N3002"
check "13e MERGED on an OPEN PR rc" "$rc" 10
contains "13e MERGED on an OPEN PR escalates" "$out" "ESCALATE wrap-merged-failed rc=3"
lacks "13e MERGED on an OPEN PR: close not run" "$calls" "close"

# 13b. a WRAPPED that resolves to a successor doc with no PR of its own, while the original sibling names one,
# takes wrap-merged's merge verification, never the direct close
printf '%s\n' '## Results' '- 10:00 READY 2553 abc' '- 10:30 WRAPPED hand-off' > "$W/HIMMEL-6-N5001-orig-2026-10-14.md"
printf '%s\n' '## Results' '- 11:00 WRAPPED done' > "$W/HIMMEL-6-N5001b-orig-2026-10-14-RESUME.md"
printf '%s\n' '## Results' '- 10:30 WRAPPED hand-off' > "$W/HIMMEL-7-N5002-plain-2026-10-14.md"
printf '%s\n' '## Results' '- 11:00 WRAPPED done' > "$W/HIMMEL-7-N5002b-plain-2026-10-14-RESUME.md"
cat > "$W/list13b" <<EOF3
#!/usr/bin/env bash
printf '%s\n' $W/HIMMEL-6-N5001b-orig-2026-10-14-RESUME.md $W/HIMMEL-7-N5002b-plain-2026-10-14-RESUME.md
EOF3
chmod +x "$W/list13b"
LE_LIST="$W/list13b" run "WRAPPED N5001."
check "13b successor with a PR-marked original: rc" "$rc" 0
contains "13b successor with a PR-marked original goes to wrap-merged" "$calls" "wrap --doc $W/doc --fleet $W/fleet.json $W/HIMMEL-6-N5001b-orig-2026-10-14-RESUME.md"
lacks "13b successor with a PR-marked original is not closed directly" "$calls" "close"
LE_LIST="$W/list13b" run "WRAPPED N5002."
contains "13b successor and original both without a PR: direct close" "$calls" "close --fleet $W/fleet.json $W/HIMMEL-7-N5002b-plain-2026-10-14-RESUME.md"
lacks "13b no PR anywhere: wrap-merged not run" "$calls" "wrap --doc"
# a legacy-named original (-leg<k>-) and a multi-letter successor (N5004bc) are still siblings of one worker
printf '%s\n' '## Results' '- 10:00 READY 2554 abc' '- 10:30 WRAPPED hand-off' > "$W/HIMMEL-8-legN5004-orig-2026-10-14.md"
printf '%s\n' '## Results' '- 11:00 WRAPPED done' > "$W/HIMMEL-8-N5004bc-orig-2026-10-14-RESUME.md"
cat > "$W/list13c" <<EOF3
#!/usr/bin/env bash
printf '%s\n' $W/HIMMEL-8-N5004bc-orig-2026-10-14-RESUME.md
EOF3
chmod +x "$W/list13c"
LE_LIST="$W/list13c" run "WRAPPED N5004."
contains "13b legacy-named original with a PR goes to wrap-merged" "$calls" "wrap --doc $W/doc --fleet $W/fleet.json $W/HIMMEL-8-N5004bc-orig-2026-10-14-RESUME.md"
lacks "13b legacy-named original with a PR is not closed directly" "$calls" "close"
# 13d. unrelated docs in the directory cost no worker_base call each (the live handovers dir holds thousands;
# worker_base forks sed, so a sed shim counts the calls): the count with 40 extra unrelated docs equals the count without
D13="$W/d13d"; mkdir -p "$D13" "$W/shim"
cat > "$W/shim/sed" <<EOF5
#!/usr/bin/env bash
echo x >> "$W/sedcalls"
exec $(command -v sed) "\$@"
EOF5
chmod +x "$W/shim/sed"
printf '%s\n' '## Results' '- 10:30 WRAPPED done' > "$D13/HIMMEL-12-N5010-plain-2026-10-14.md"
cat > "$W/list13d" <<EOF6
#!/usr/bin/env bash
printf '%s\n' $D13/HIMMEL-12-N5010-plain-2026-10-14.md
EOF6
chmod +x "$W/list13d"
: > "$W/sedcalls"
PATH="$W/shim:$PATH" LE_LIST="$W/list13d" run "WRAPPED N5010."
contains "13d sole doc: direct close" "$calls" "close --fleet $W/fleet.json $D13/HIMMEL-12-N5010-plain-2026-10-14.md"
# read-sink-ok: sedcalls is the suite's own scratch file under $W
sed_alone="$(wc -l < "$W/sedcalls" | tr -d ' ')"
for i in $(seq 1 40); do printf '%s\n' '## Results' '- 10:00 READY 9999 abc' > "$D13/HIMMEL-$((100 + i))-N$((7000 + i))-other-2026-10-14.md"; done
: > "$W/sedcalls"
PATH="$W/shim:$PATH" LE_LIST="$W/list13d" run "WRAPPED N5010."
contains "13d with unrelated PR-naming docs present: still a direct close" "$calls" "close --fleet $W/fleet.json $D13/HIMMEL-12-N5010-plain-2026-10-14.md"
# read-sink-ok: sedcalls is the suite's own scratch file under $W
check "13d unrelated docs add no worker_base calls" "$(wc -l < "$W/sedcalls" | tr -d ' ')" "$sed_alone"

LE_LIST="$W/list13" run "MERGED #2566 N3001"
contains "13 MERGED never takes the close path" "$calls" "wrap --doc"

# a worker already closed has left the manifest; wrap-merged's chief-doc bullet proves it
printf '%s\n' '- 10:00 MERGED #2566 → abcdef01 (N9999, HIMMEL-9 Done). N9999 WRAPPED, window closed.' > "$W/doc"
run "WRAPPED N9999"
check "14 re-run on a closed worker rc" "$rc" 0
check "14 re-run on a closed worker prints HANDLED noop" "$out" "HANDLED noop N9999"
check "14 nothing runs" "$calls" ""
run "MERGED #2566 N9999"
check "14 a MERGED re-run is a noop too" "$out" "HANDLED noop N9999"
run "WRAPPED N999"
contains "14 a label that is only a prefix of the closed one still escalates" "$out" "ESCALATE not-in-manifest N999"
: > "$W/doc"

# 15. READY: with the auto_go flag on it goes to auto-go.sh (a stub through LE_AUTOGO), live; the chief doc gets an AUTO-GO bullet
H40=0780b95dcad44fe293c7798066626cd52bb2dce0
wait_for_autogo_call() { local i=0; while [ ! -s "$LE_CALLS" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done; calls="$(cat "$LE_CALLS")"; }
pause_then_read_calls() { sleep 1; calls="$(cat "$LE_CALLS")"; }
cat > "$W/autogo" <<'EOF3'
#!/usr/bin/env bash
echo "autogo $*" >> "$LE_CALLS"
[ -z "${LE_AUTOGO_ERR:-}" ] || echo "$LE_AUTOGO_ERR" >&2
[ -z "${LE_AUTOGO_OUT:-}" ] || echo "$LE_AUTOGO_OUT"
exit "${LE_AUTOGO_RC:-0}"
EOF3
chmod +x "$W/autogo"
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\nstacked_series\toff\tfeature\tHIMMEL-8349\tHIMMEL-8349\t2099-01-01\tfixture\n' > "$W/flags.tsv"
export HIMMEL_FLAGS_TSV="$W/flags.tsv" HIMMEL_CONFIG_DIR="$W/no-conf" LE_AUTOGO="$W/autogo"
unset HIMMEL_FLAG_AUTO_GO

run "READY 2553 $H40 GREEN N2088"; wait_for_autogo_call
check "15a flag off: rc" "$rc" 10
check "15a flag off: ESCALATE marker-READY, as before" "$out" "ESCALATE marker-READY"
check "15a flag off: auto-go runs once, dry" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/fleet.json --worker N2088 2553 $H40"

LE_AUTOGO_RC=3 LE_AUTOGO_OUT="auto-go: refusing - chief relay" run "READY 2553 $H40 GREEN N2088"; wait_for_autogo_call
check "15a1 a failed dry run: rc unchanged" "$rc" 10
check "15a1 a failed dry run: ESCALATE marker-READY unchanged" "$out" "ESCALATE marker-READY"
LE_AUTOGO_RC=0 LE_AUTOGO_OUT="WOULD-GO 2553 $H40" run "READY 2553 $H40 GREEN N2088"; wait_for_autogo_call
check "15a2 a WOULD-GO dry run: still ESCALATE marker-READY" "$out" "ESCALATE marker-READY"
run "N2088 READY 2553 $H40 GREEN"; wait_for_autogo_call
check "15a3 a label-first READY dry-runs the same" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/fleet.json --worker N2088 2553 $H40"
run "READY 2553 abc N2088"; pause_then_read_calls
check "15a4 no full head: no dry run" "$calls" ""
run "READY 2553 $H40 GREEN"; pause_then_read_calls
check "15a5 no worker label: no dry run" "$calls" ""
check "15a5 no worker label: ESCALATE marker-READY unchanged" "$out" "ESCALATE marker-READY"
run "READY 2553 $H40 N2078 N2088"; pause_then_read_calls
check "15a6 two labels: no dry run" "$calls" ""

export HIMMEL_FLAG_AUTO_GO=1
printf '# chief\n\n## Results\n' > "$W/doc"
lastb() { tail -n 1 "$W/doc" | sed 's/^- [0-9][0-9]:[0-9][0-9] //'; }
LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N2088 bus=#7 qid=q1" run "READY 2553 $H40 GREEN N2088"
check "15b a sent GO is handled: rc" "$rc" 0
check "15b a sent GO is handled" "$out" "HANDLED auto-go N2088"
check "15b auto-go runs live (no --dry-run) for the worker" "$calls" "autogo --doc $W/doc --fleet $W/fleet.json --worker N2088 2553 $H40"
check "15b the chief doc carries the AUTO-GO bullet" "$(lastb)" "AUTO-GO #2553 0780b95d qid=q1 to N2088"

LE_AUTOGO_RC=10 LE_AUTOGO_OUT="ESCALATE auto-go 3 ready-go did not print READY-GO PASS" run "READY 2553 $H40 GREEN N2088"
check "15c an auto-go escalation is passed on: rc" "$rc" 10
check "15c an auto-go escalation is passed on" "$out" "ESCALATE auto-go 3 ready-go did not print READY-GO PASS"
check "15c the chief doc carries the AUTO-GO-REFUSED bullet" "$(lastb)" "AUTO-GO-REFUSED #2553 3"

LE_AUTOGO_RC=3 LE_AUTOGO_OUT="auto-go: refusing - chief relay" run "READY 2553 $H40 GREEN N2088"
check "15d another auto-go exit: rc" "$rc" 10
contains "15d another auto-go exit is an error, never a retryable -failed" "$out" "ESCALATE auto-go-error rc=3 auto-go: refusing"

LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N2088 bus=#7 qid=none" run "N2088 READY 2553 $H40 GREEN"
check "15e a label-first READY routes the same" "$out" "HANDLED auto-go N2088"
check "15e qid none in the bullet" "$(lastb)" "AUTO-GO #2553 0780b95d qid=none to N2088"

LE_AUTOGO_RC=11 LE_AUTOGO_OUT="GO-WRITTEN 2553 $H40 qid=q1 bus-failed: no live session
SENDMESSAGE to=HIMMEL-2-N2088-bar-2026-10-14 :: GO 2553 $H40 - merge with: bash m.sh --go f" run "READY 2553 $H40 GREEN N2088"
check "15g GO written, bus not delivered: rc 11" "$rc" 11
contains "15g the message for the chief to send is passed on" "$out" "SENDMESSAGE to=HIMMEL-2-N2088-bar-2026-10-14 :: GO 2553"
check "15g the chief doc carries the AUTO-GO bullet, bus failed" "$(lastb)" "AUTO-GO #2553 0780b95d qid=q1 to N2088 bus-failed"

LE_AUTOGO_OUT="WOULD-GO 2553 $H40" run "READY 2553 $H40 GREEN N2088"
contains "15h a WOULD-GO from a live run is an error" "$out" "ESCALATE auto-go-error rc=0 WOULD-GO"
LE_AUTOGO_OUT="GO-SENT 2554 $H40 to N2088 bus=#7 qid=q1" run "READY 2553 $H40 GREEN N2088"
contains "15h a GO-SENT for another PR is an error" "$out" "ESCALATE auto-go-error rc=0 GO-SENT 2554"

# a warning auto-go.sh prints on stderr before its answer does not hide the answer
WARN="auto-go: warning - the audit row could not be written to /x"
LE_AUTOGO_ERR="$WARN" LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N2088 bus=#7 qid=q1" run "READY 2553 $H40 GREEN N2088"
check "15j a sent GO behind a stderr warning is handled" "$out" "HANDLED auto-go N2088"
LE_AUTOGO_ERR="$WARN" LE_AUTOGO_RC=11 LE_AUTOGO_OUT="GO-WRITTEN 2553 $H40 qid=q1 bus-failed: no live session
SENDMESSAGE to=HIMMEL-2-N2088-bar-2026-10-14 :: GO 2553" run "READY 2553 $H40 GREEN N2088"
check "15j a GO-WRITTEN behind a stderr warning: rc 11" "$rc" 11
check "15j a GO-WRITTEN behind a stderr warning: its answer line comes first" "$(printf '%s\n' "$out" | head -n 1)" "GO-WRITTEN 2553 $H40 qid=q1 bus-failed: no live session"
contains "15j a GO-WRITTEN behind a stderr warning: the warning is still passed on" "$out" "$WARN"
LE_AUTOGO_ERR="$WARN" LE_AUTOGO_RC=10 LE_AUTOGO_OUT="ESCALATE auto-go 3 not ready" run "READY 2553 $H40 GREEN N2088"
check "15j a refusal behind a stderr warning is passed on" "$out" "ESCALATE auto-go 3 not ready"

printf '# chief\n' > "$W/doc"
LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N2088 bus=#7 qid=q1" run "READY 2553 $H40 GREEN N2088"
check "15i a bullet that cannot be written leaves the GO handled: rc" "$rc" 0
contains "15i a bullet that cannot be written is reported" "$out" "HANDLED auto-go N2088 doc-bullet=failed"
: > "$W/doc"

run "READY 2553 abc N2088"
contains "15f a READY with no full head" "$out" "ESCALATE ready-unparsed"
check "15f auto-go not run" "$calls" ""
unset HIMMEL_FLAG_AUTO_GO HIMMEL_FLAGS_TSV HIMMEL_CONFIG_DIR LE_AUTOGO

# 16. series routing (stacked_series): the REAL series-ledger.py find on a real ledger and manifest file, never a stub.
# N8 passed the series to N9 (the ledger writer); each doc names a PR, so at base a WRAPPED from either runs wrap-merged.
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\nstacked_series\toff\tfeature\tHIMMEL-8349\tHIMMEL-8349\t2099-01-01\tfixture\n' > "$W/flags16.tsv"
export HIMMEL_FLAGS_TSV="$W/flags16.tsv" HIMMEL_CONFIG_DIR="$W/no-conf" LE_AUTOGO="$W/autogo" HIMMEL_FLAG_AUTO_GO=1 HIMMEL_FLAG_STACKED_SERIES=1
SD="$W/ser-docs"; mkdir -p "$SD"
SA="$SD/HIMMEL-5-N8-ser-2026-11-05.md"; SW="$SD/HIMMEL-5-N9-ser-2026-11-05-RESUME.md"
printf '%s\n' '## Results' '- 10:00 READY 2553 abc' '- 10:30 WRAPPED hand-off' > "$SA"
printf '%s\n' '## Results' '- 10:00 READY 2553 abc' > "$SW"
cat > "$W/list16" <<EOF16
#!/usr/bin/env bash
printf '%s\n' $SA $SW /h/HIMMEL-1-N2078-foo-2026-10-14.md
EOF16
chmod +x "$W/list16"
# mkser <dir> <manifest workers json>: a bucket whose ledger s16 has writer N9 after N8 passed the series on
mkser() {
    mkdir -p "$1/series"
    python3 -I "$HERE/series-ledger.py" create --ledger "$1/series/s16.json" --sid s16 --completes-ticket no --writer "$SA" >/dev/null 2>&1
    python3 -I "$HERE/series-ledger.py" pass --ledger "$1/series/s16.json" --from "$SA" --to "$SW" >/dev/null 2>&1
    printf '{"schema":1,"workers":[%s]}\n' "$2" > "$1/fleet.json"
}
runf() { : > "$LE_CALLS"; : > "$LE_LIVE_CALLS"; printf '%s\n' "$2" > "$W/msg"; out="$(LE_LIST="$W/list16" bash "$SCRIPT" --doc "$W/doc" --fleet "$1" "$W/msg" 2>/dev/null)"; rc=$?; calls="$(cat "$LE_CALLS")"; }
ROW8="{\"doc\":\"$SA\",\"label\":\"N8\"}"; ROW9="{\"doc\":\"$SW\",\"label\":\"N9\"}"
mkser "$W/s-ok" "$ROW8,$ROW9"
printf '# chief\n\n## Results\n' > "$W/doc"

runf "$W/s-ok/fleet.json" "WRAPPED N8. Lock released."
check "16.1 a WRAPPED from a passes-from doc: rc" "$rc" 0
check "16.1 it is closed, not wrap-merged" "$out" "HANDLED close-wrapped N8"
contains "16.1 close-wrapped-worker runs on the doc" "$calls" "close --fleet $W/s-ok/fleet.json $SA"
lacks "16.1 wrap-merged does not run" "$calls" "wrap --doc"

HIMMEL_FLAG_STACKED_SERIES=0 runf "$W/s-ok/fleet.json" "WRAPPED N8. Lock released."
contains "16.1b stacked_series off: the same WRAPPED still reaches wrap-merged" "$calls" "wrap --doc $W/doc --fleet $W/s-ok/fleet.json $SA"
check "16.1b it finishes: rc" "$rc" 0
check "16.1b it finishes: HANDLED" "$out" "HANDLED wrap-merged N8"

runf "$W/s-ok/fleet.json" "WRAPPED N9. Lock released."
contains "16.1c a WRAPPED from the current writer still reaches wrap-merged" "$calls" "wrap --doc $W/doc --fleet $W/s-ok/fleet.json $SW"
check "16.1c it finishes: rc" "$rc" 0
check "16.1c it finishes: HANDLED" "$out" "HANDLED wrap-merged N9"

runf "$W/s-ok/fleet.json" "WRAPPED N2078. Lock released."
contains "16.4 a non-series WRAPPED still reaches wrap-merged" "$calls" "wrap --doc $W/doc --fleet $W/s-ok/fleet.json /h/HIMMEL-1-N2078-foo-2026-10-14.md"
check "16.4 it finishes: rc" "$rc" 0
check "16.4 it finishes: HANDLED" "$out" "HANDLED wrap-merged N2078"

LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N9 bus=#7 qid=q1" runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"
check "16.2 a READY from the passes-from doc N8: rc" "$rc" 0
check "16.2 the GO addressee is the writer" "$out" "HANDLED auto-go N9"
check "16.2 auto-go is called with the writer's label" "$calls" "autogo --doc $W/doc --fleet $W/s-ok/fleet.json --worker N9 2553 $H40"
LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N9 bus=#7 qid=q1" runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N9"
check "16.2b a READY from the writer itself keeps its own label" "$calls" "autogo --doc $W/doc --fleet $W/s-ok/fleet.json --worker N9 2553 $H40"

mkser "$W/s-zero" "$ROW8"
runf "$W/s-zero/fleet.json" "READY 2553 $H40 GREEN N8"
check "16.3 writer doc in no manifest entry: rc" "$rc" 10
check "16.3 writer doc in no manifest entry escalates" "$out" "ESCALATE series-writer-unlisted"
check "16.3 no auto-go call" "$calls" ""
mkser "$W/s-two" "$ROW8,$ROW9,{\"doc\":\"$SW\",\"label\":\"N9b\"}"
runf "$W/s-two/fleet.json" "READY 2553 $H40 GREEN N8"
check "16.3 writer doc in two manifest entries: rc" "$rc" 10
check "16.3 writer doc in two manifest entries escalates" "$out" "ESCALATE series-writer-unlisted"
check "16.3 no auto-go call (two entries)" "$calls" ""

mkser "$W/s sp" "$ROW8,$ROW9"
LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N9 bus=#7 qid=q1" runf "$W/s sp/fleet.json" "READY 2553 $H40 GREEN N8"
contains "16.2c a space in the bucket path does not shift the role and label fields" "$calls" "--worker N9 2553 $H40"
LE_CLOSE_RC=0 runf "$W/s sp/fleet.json" "WRAPPED N8. Lock released."
check "16.1d a space in the bucket path: a passes-from WRAPPED is still closed" "$out" "HANDLED close-wrapped N8"

HIMMEL_FLAG_STACKED_SERIES=0 LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N8 bus=#7 qid=q1" runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"
contains "16.5 stacked_series off: a READY keeps its own label" "$calls" "--worker N8 2553"

HIMMEL_FLAG_STACKED_SERIES=bogus LE_AUTOGO_OUT="GO-SENT 2553 $H40 to N8 bus=#7 qid=q1" runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"
check "16.7 a stacked_series flag that cannot be read: rc" "$rc" 10
contains "16.7 it escalates, never reads as off" "$out" "ESCALATE series-flag-unreadable rc=2"
check "16.7 no auto-go call" "$calls" ""

mkser "$W/s-bad" "$ROW8,$ROW9"; printf '{not json' > "$W/s-bad/series/zz.json"
runf "$W/s-bad/fleet.json" "WRAPPED N8. Lock released."
contains "16.6 an unreadable ledger escalates instead of guessing a route" "$out" "ESCALATE series-find-failed rc=1"
check "16.6 nothing ran" "$calls" ""

cat > "$W/autogo-sleep" <<'EOF17'
#!/usr/bin/env bash
echo $$ > "$LE_SLEEP_PID"
sleep 20
EOF17
chmod +x "$W/autogo-sleep"
export LE_SLEEP_PID="$W/sleep.pid"
t0=$SECONDS
HIMMEL_FLAG_AUTO_GO=0 LE_AUTOGO="$W/autogo-sleep" LE_DRYRUN_BOUND=2 runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N2078"
el=$((SECONDS - t0))
check "17.1 a hung dry run: rc" "$rc" 10
check "17.1 a hung dry run: ESCALATE marker-READY" "$out" "ESCALATE marker-READY"
check "17.1 a hung dry run: the escalation returns within the bound (elapsed under 6s)" "$([ "$el" -lt 6 ] && echo yes || echo "no ${el}s")" yes
if timeout --version >/dev/null 2>&1; then
    i=0; while [ "$i" -lt 50 ] && [ ! -s "$LE_SLEEP_PID" ]; do sleep 0.1; i=$((i+1)); done
    check "17.1b the sleeping dry run started" "$([ -s "$LE_SLEEP_PID" ] && echo yes || echo no)" yes
    i=0; while [ "$i" -lt 100 ] && [ -s "$LE_SLEEP_PID" ] && kill -0 "$(cat "$LE_SLEEP_PID")" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    check "17.1b the bounded dry run is gone once its bound passed" "$(kill -0 "$(cat "$LE_SLEEP_PID" 2>/dev/null)" 2>/dev/null && echo alive || echo gone)" gone
else
    echo "ok - 17.1b skipped: no GNU timeout on this host"
fi
[ ! -s "$LE_SLEEP_PID" ] || kill "$(cat "$LE_SLEEP_PID")" 2>/dev/null
pkill -f "$W/autogo-sleep" 2>/dev/null
unset LE_SLEEP_PID

HIMMEL_FLAG_AUTO_GO=0 runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"; wait_for_autogo_call
check "17.2 a series READY: ESCALATE marker-READY unchanged" "$out" "ESCALATE marker-READY"
check "17.2 a series READY dry-runs under the ledger's writer label, not the message's" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/s-ok/fleet.json --worker N9 2553 $H40"
HIMMEL_FLAG_AUTO_GO=0 runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N2078"; wait_for_autogo_call
check "17.3 a non-series READY dry-runs under the message's label" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/s-ok/fleet.json --worker N2078 2553 $H40"
HIMMEL_FLAG_AUTO_GO=0 HIMMEL_FLAG_STACKED_SERIES=0 runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"; wait_for_autogo_call
check "17.4 stacked_series off: the dry run keeps the message's label" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/s-ok/fleet.json --worker N8 2553 $H40"
HIMMEL_FLAG_AUTO_GO=0 runf "$W/s-zero/fleet.json" "READY 2553 $H40 GREEN N8"; wait_for_autogo_call
check "17.5 the writer is in no manifest entry: the dry run keeps the message's label" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/s-zero/fleet.json --worker N8 2553 $H40"
HIMMEL_FLAG_AUTO_GO=0 runf "$W/s-bad/fleet.json" "READY 2553 $H40 GREEN N8"; wait_for_autogo_call
check "17.6 an unreadable ledger: the dry run keeps the message's label" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/s-bad/fleet.json --worker N8 2553 $H40"
check "17.6 an unreadable ledger: ESCALATE marker-READY, never series-find-failed" "$out" "ESCALATE marker-READY"
HIMMEL_FLAG_AUTO_GO=0 LE_AUTOGO_RC=3 LE_AUTOGO_OUT="auto-go: refusing" runf "$W/s-ok/fleet.json" "READY 2553 $H40 GREEN N8"; wait_for_autogo_call
check "17.7 a failing, printing dry run changes nothing: rc" "$rc" 10
check "17.7 a failing, printing dry run changes nothing: out" "$out" "ESCALATE marker-READY"
unset HIMMEL_FLAG_AUTO_GO HIMMEL_FLAG_STACKED_SERIES HIMMEL_FLAGS_TSV HIMMEL_CONFIG_DIR LE_AUTOGO

cat > "$W/list18" <<'EOF18'
#!/usr/bin/env bash
printf '%s\n' /h/HIMMEL-9564-N5765f-resumed-2026-11-10-RESUME.md /h/HIMMEL-9500-N5653b-other-2026-11-09-RESUME.md
EOF18
chmod +x "$W/list18"
export HIMMEL_FLAGS_TSV="$W/flags.tsv" HIMMEL_CONFIG_DIR="$W/no-conf" LE_AUTOGO="$W/autogo" HIMMEL_FLAG_AUTO_GO=1
GOOUT="GO-SENT 2553 $H40 to N5653b bus=#7 qid=q1"
LE_LIST="$W/list18" LE_AUTOGO_OUT="$GOOUT" run "READY 2553 $H40 GREEN N5653b"
check "18a a READY naming N5653b: HANDLED under that label" "$out" "HANDLED auto-go N5653b"
check "18a a READY naming N5653b: auto-go gets the suffixed label" "$calls" "autogo --doc $W/doc --fleet $W/fleet.json --worker N5653b 2553 $H40"
LE_LIST="$W/list18" LE_AUTOGO_OUT="$GOOUT" run "READY 2553 $H40 GREEN HIMMEL-9564-N5765f-resumed-2026-11-10-RESUME"
check "18b a READY naming only the session name: auto-go gets the stem's label N5765f" "$calls" "autogo --doc $W/doc --fleet $W/fleet.json --worker N5765f 2553 $H40"
LE_LIST="$W/list18" LE_AUTOGO_OUT="$GOOUT" run "READY 2553 $H40 GREEN N5653"
check "18c a READY naming the bare label of a resumed worker: auto-go gets the manifest's N5653b" "$calls" "autogo --doc $W/doc --fleet $W/fleet.json --worker N5653b 2553 $H40"
LE_LIST="$W/list18" LE_AUTOGO_OUT="$GOOUT" run "N5653b READY 2553 $H40 GREEN"
check "18d a label-first READY from a suffixed worker: auto-go gets N5653b" "$calls" "autogo --doc $W/doc --fleet $W/fleet.json --worker N5653b 2553 $H40"
HIMMEL_FLAG_AUTO_GO=0 LE_LIST="$W/list18" run "READY 2553 $H40 GREEN N5653b"; wait_for_autogo_call
check "18e flag off: the dry run gets the suffixed label" "$calls" "autogo --dry-run --doc $W/doc --fleet $W/fleet.json --worker N5653b 2553 $H40"
unset HIMMEL_FLAG_AUTO_GO HIMMEL_FLAGS_TSV HIMMEL_CONFIG_DIR LE_AUTOGO

unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME
AG="$W/ag"; mkdir -p "$AG/scripts/handover/chief-kit" "$AG/scripts/guardrails"
ln -s "$HERE/../../lib" "$AG/scripts/lib"; ln -s "$HERE/../../cr" "$AG/scripts/cr"
cp "$HERE/auto-go.sh" "$AG/scripts/handover/chief-kit/auto-go.sh"
printf '[]\n' > "$AG/scripts/guardrails/himmel-adapters.json"; printf '[]\n' > "$AG/scripts/guardrails/himmel-adopted.json"
printf '#!/usr/bin/env bash\nprintf "TRUST: hit scripts/ci/x.sh\\nREADY-GO PASS\\n"\n' > "$AG/scripts/handover/chief-kit/ready-go.sh"
git init -q "$AG"
cat > "$W/gh19" <<'EOF19'
#!/usr/bin/env bash
case "$*" in
    "repo view --json nameWithOwner"*) echo o/r ;;
    "repo view --json defaultBranchRef"*) echo main ;;
    "pr view "*"--json state,headRefOid,baseRefName"*) printf '{"state":"OPEN","headRefOid":"%s","baseRefName":"main"}\n' "$LE_HEAD19" ;;
    "pr view "*"--json title"*) echo "fix(x): [HIMMEL-1] t (#1)" ;;
    "api repos/"*"/files"*) printf 'scripts/ci/x.sh\t\n' ;;
    *) exit 1 ;;
esac
EOF19
printf '#!/usr/bin/env bash\nprintf "HIMMEL-1\\tTask\\tIn Review\\tsummary\\n"\n' > "$W/jira19"
chmod +x "$W/gh19" "$W/jira19" "$AG/scripts/handover/chief-kit/auto-go.sh"
D19="$W/d19"; mkdir -p "$D19" "$W/root19"
BRIEF19="$D19/HIMMEL-9564-N5765f-resumed-2026-11-10-RESUME.md"
printf '> **Completes ticket:** no\n' > "$BRIEF19"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N5765f","lane":"native"}]}\n' "$BRIEF19" > "$D19/fleet.json"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s\n' "$BRIEF19" > "$W/list19"; chmod +x "$W/list19"
printf '# chief\n\n## Live state\nlegs: none\n\n## Results\n' > "$W/doc19"
export HIMMEL_FLAGS_TSV="$W/flags.tsv" HIMMEL_CONFIG_DIR="$W/no-conf" HIMMEL_FLAG_AUTO_GO=1
export HANDOVER_DIR="$W/root19" USER_SLUG=u AUTO_GO_ANCHOR="$AG" GH_CMD="$W/gh19" JIRA_CMD="$W/jira19" LE_HEAD19="$H40"
for msg19 in "READY 2553 $H40 GREEN N5765f" "READY 2553 $H40 GREEN HIMMEL-9564-N5765f-resumed-2026-11-10-RESUME"; do
    out="$(LE_LIST="$W/list19" LE_AUTOGO="$AG/scripts/handover/chief-kit/auto-go.sh" bash "$SCRIPT" --doc "$W/doc19" --fleet "$D19/fleet.json" <(printf '%s\n' "$msg19") 2>&1)"; rc=$?
    check "19 [$msg19] a suffixed worker's READY on a trust-path hit: rc" "$rc" 10
    contains "19 [$msg19] it escalates at check 5" "$out" "ESCALATE auto-go 5 "
    contains "19 [$msg19] the refusal names the trust-path hit" "$out" "trust-path hit"
done
row19="$(tail -n 1 "$W/root19/u/"*/auto-go.jsonl 2>/dev/null)"
check "19 the audit row: checks 1-4 pass, 5 fails" "$(printf '%s' "$row19" | jq -r '[.checks[] | "\(.n)=\(.result)"] | join(",")' 2>/dev/null)" "1=pass,2=pass,3=pass,4=pass,5=fail"
check "19 the audit row: outcome escalate for the suffixed worker" "$(printf '%s' "$row19" | jq -r '"\(.worker) \(.outcome)"' 2>/dev/null)" "N5765f escalate"
check "19 no GO file is written" "$(find "$W/root19" -iname '*go*' -not -name 'auto-go.jsonl' -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
unset HIMMEL_FLAG_AUTO_GO HIMMEL_FLAGS_TSV HIMMEL_CONFIG_DIR AUTO_GO_ANCHOR GH_CMD JIRA_CMD LE_HEAD19

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
