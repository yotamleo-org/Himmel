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
cat > "$W/autogo" <<'EOF3'
#!/usr/bin/env bash
echo "autogo $*" >> "$LE_CALLS"
[ -z "${LE_AUTOGO_ERR:-}" ] || echo "$LE_AUTOGO_ERR" >&2
[ -z "${LE_AUTOGO_OUT:-}" ] || echo "$LE_AUTOGO_OUT"
exit "${LE_AUTOGO_RC:-0}"
EOF3
chmod +x "$W/autogo"
printf 'auto_go\toff\tfeature\tHIMMEL-8349\tHIMMEL-8404\t2099-01-01\tfixture\n' > "$W/flags.tsv"
export HIMMEL_FLAGS_TSV="$W/flags.tsv" HIMMEL_CONFIG_DIR="$W/no-conf" LE_AUTOGO="$W/autogo"
unset HIMMEL_FLAG_AUTO_GO

run "READY 2553 $H40 GREEN N2088"
check "15a flag off: rc" "$rc" 10
check "15a flag off: ESCALATE marker-READY, as before" "$out" "ESCALATE marker-READY"
check "15a flag off: auto-go not run" "$calls" ""

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

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
