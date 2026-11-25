#!/usr/bin/env bash
# PLATFORM GUARD: The chief kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
# shellcheck disable=SC2154  # fails is set by the sourced tick-test-fixture.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
cpu9342() {  # cpu9342 <stdout-file> <cmd...>: the CPU ms of the children the command reaped
    local out="$1" t; shift
    t="$( { TIMEFORMAT='%U %S'; time "$@" >"$out" 2>/dev/null; } 2>&1 )"
    printf '%s\n' "$t" | tr , . | LC_ALL=C awk 'END { printf "%d", ($1 + $2) * 1000 }'  # a de_DE station prints 2,987
}
# shellcheck disable=SC2016  # the stub's own $vars expand when it runs, not here
spin9342='i=0; while [ $i -lt 2000000 ]; do i=$((i+1)); done'

# --- orphans-wip=: In Progress / In Review tickets with no worker and no open PR.
OW="$W/ow-mirror/HIMMEL"; mkdir -p "$OW"
mk_ow() { # <num> <status> <type>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "%s"\nstatus: "%s"\nstatusCategory: "x"\npriority: "Medium"\nlabels: []\nfixVersions: []\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t%s\n\n## Description\n\nbody\n' \
        "$1" "$3" "$2" "$1" "$1" > "$OW/HIMMEL-$1.md"
}
cat > "$W/ow-gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${OW_GH_FAIL:-}" ] || exit 1
[ "$2" = list ] && case "$*" in *merged*) [ -z "${OW_MERGED_FAIL:-}" ] || exit 1; printf '%b' "${OW_MERGED_ROWS:-}" ;; *headRefName*) printf '%b' "${OW_PR_ROWS:-}" ;; esac
exit 0
STUB
chmod +x "$W/ow-gh"
# The dispatcher answers an IN CI ticket's "merged" from the main ref's commit subjects first: pin it to an empty repo, so a real
# commit on this checkout's origin/main that names a fixture key cannot answer for it and hide the merged-PR read failure row.
{ git init -q -b main "$W/ow-main" && git -C "$W/ow-main" -c user.name=t -c user.email=t@e.x -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q --allow-empty -m init; } \
    || { fail "the ow-main fixture repo could not be created"; exit 1; }
ow_tick() { NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_GIT_DIR="$W/ow-main" NEXT_DISPATCH_MAIN_REF=main bash "$SUT" 2>/dev/null; }
ow_of() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^orphans-wip=//p'; }
mk_ow 901 "In Progress" Task
mk_ow 902 "In Review" Task
mk_ow 903 "In Progress" Epic
mk_ow 904 "To Do" Task
owa="$(ow_of "$(ow_tick)")"
[ "$owa" = "2:HIMMEL-901,HIMMEL-902" ] && pass 'orphans-wip= counts the orphans and names them (Epic and To Do excluded)' || fail "orphans-wip= is '$owa'"
owb_rows='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n'
owb="$(ow_of "$(OW_PR_ROWS="$owb_rows" ow_tick)")"
[ "$owb" = "1:HIMMEL-902" ] && pass 'orphans-wip= drops a ticket an open PR cites' || fail "orphans-wip= with a PR is '$owb'"
owc="$(ow_of "$(OW_GH_FAIL=1 ow_tick)")"
[ "$owc" = "?" ] && pass 'orphans-wip= is ? when the PR read fails, not an all-clear' || fail "orphans-wip= on gh failure is '$owc'"
owd="$(ow_of "$(NEXT_DISPATCH_MIRROR="$W/no-such-mirror" bash "$SUT" 2>/dev/null)")"
[ "$owd" = "skip" ] && pass 'orphans-wip= is skip without a Jira mirror' || fail "orphans-wip= without a mirror is '$owd'"
for n in 905 906 907 908; do mk_ow "$n" "In Progress" Task; done
owe="$(ow_of "$(ow_tick)")"
[ "$owe" = "6" ] && pass 'orphans-wip= names no keys above five' || fail "orphans-wip= with six is '$owe'"
contains '--verbose labels orphans-wip' "$(NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_GIT_DIR="$W/ow-main" NEXT_DISPATCH_MAIN_REF=main bash "$SUT" --verbose 2>/dev/null)" 'orphans-wip: 6'

# IN CI tickets count too: one a merged PR cites (merged-not-closed) and one with no PR at all.
OW_SAVE="$OW"; OW="$W/ow-inci-mirror/HIMMEL"; mkdir -p "$OW"
mk_ow 921 "IN CI" Task
mk_ow 922 "IN CI" Task
OW_MERGED_ROWS='4400\tfix: [HIMMEL-921] x\tfix/himmel-921-x\n'
owi="$(ow_of "$(OW_MERGED_ROWS="$OW_MERGED_ROWS" ow_tick)")"
[ "$owi" = "2:HIMMEL-921,HIMMEL-922" ] && pass 'orphans-wip= counts an IN CI ticket with a merged PR and one with no PR' || fail "orphans-wip= with IN CI tickets is '$owi'"
owj_rows='4401\tfix: [HIMMEL-921] y\tfix/himmel-921-y\n'
owj="$(ow_of "$(OW_MERGED_ROWS="$OW_MERGED_ROWS" OW_PR_ROWS="$owj_rows" ow_tick)")"
[ "$owj" = "1:HIMMEL-922" ] && pass 'orphans-wip= drops an IN CI ticket an open PR cites' || fail "orphans-wip= with an IN CI open PR is '$owj'"
owk="$(ow_of "$(OW_MERGED_FAIL=1 ow_tick)")"
[ "$owk" = "?" ] && pass 'orphans-wip= is ? when the merged-PR read fails, not an all-clear' || fail "orphans-wip= on merged read failure is '$owk'"
OW="$OW_SAVE"

# --- orphans-wip= reads through a cache a detached refresh fills.
cat > "$W/ow-gh-hung" <<'STUB'
#!/usr/bin/env bash
sleep 3
STUB
chmod +x "$W/ow-gh-hung"
# A scan still running would write into the next row's fixture, so each row waits it out.
owc_fresh() { for l in "$W"/owc/tick-resume-*.lock; do [ ! -e "$l" ] || flock "$l" true; done; rm -rf "$W/owc"; mkdir -p "$W/owc"; }
owc_tick() { TICK_POOL_WAIT=0 TICK_STATE_DIR="$W/owc" NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_GIT_DIR="$W/ow-main" NEXT_DISPATCH_MAIN_REF=main bash "$SUT" 2>/dev/null; }
owc_age() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n 's/^orphans-wip-age=//p'; }
if [ -n "$_TIMEOUT_BIN" ]; then
    owc_fresh
    t0="$(date +%s)"
    owh="$(TICK_POOL_WAIT=0 TICK_SECTION_WAIT=1 NEXT_DISPATCH_GH_CMD="$W/ow-gh-hung" TICK_STATE_DIR="$W/owc" NEXT_DISPATCH_MIRROR="$OW" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung resume scan costs the tick only its short wait'; else fail "a hung resume scan held the tick $((t1 - t0))s"; fi
    contains 'a hung resume scan still yields the worker state' "$owh" ' workers=N61:FRESH'
    same 'a hung resume scan with no cache reads ?, never an all-clear' "$(ow_of "$owh")" '?'
    same 'no scan cache means no orphans-wip-age field' "$(owc_age "$owh")" ''
else
    skip 'resume scan timing rows: no timeout binary'
fi
owc_fresh
owf="$(owc_tick)"
same 'a finished scan serves its count' "$(ow_of "$owf")" 6
case "$(owc_age "$owf")" in [0-9]*s) pass 'a served scan carries its age' ;; *) fail "orphans-wip-age is '$(owc_age "$owf")'" ;; esac
owc_rows="$(ls "$W"/owc/tick-resume-*.rows)"
touch -d '5 minutes ago' "$owc_rows"  # gnu-ok: chief kit is Linux-only
owg="$(TICK_ORPHANS_MIN_SECS=3600 OW_GH_FAIL=1 owc_tick)"
same 'a tick inside the cadence serves the cached scan' "$(ow_of "$owg")" 6
case "$(owc_age "$owg")" in 30[0-9]s) pass 'the cached scan reports its true age' ;; *) fail "cached orphans-wip-age is '$(owc_age "$owg")'" ;; esac
# The first ticket in this row is the one the suite's FRESH worker N61 holds.
printf '# tick-resume-scan ok\nRESUME\tHIMMEL-111\tMedium\t-\tt\nRESUME\tHIMMEL-901\tMedium\t-\tt\nRESUME\tHIMMEL-902\tMedium\t-\tt\n' > "$owc_rows"
same 'cached rows name their keys, minus a ticket a worker took since the scan' "$(ow_of "$(TICK_ORPHANS_MIN_SECS=3600 owc_tick)")" '2:HIMMEL-901,HIMMEL-902'
touch -d '2 hours ago' "$owc_rows"  # gnu-ok: chief kit is Linux-only
owl="$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)"
same 'a scan past its TTL reads ?, never an all-clear' "$(ow_of "$owl")" '?'
case "$(owc_age "$owl")" in 72[0-9][0-9]s) pass 'an expired scan still shows how old it is' ;; *) fail "expired orphans-wip-age is '$(owc_age "$owl")'" ;; esac
printf 'RESUME\tHIMMEL-901\n' > "$owc_rows"
owm="$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)"
same 'a corrupt scan cache reads ?, never an all-clear' "$(ow_of "$owm")" '?'
same 'a corrupt scan cache carries no age' "$(owc_age "$owm")" ''
printf '# tick-resume-scan ok\n' > "$owc_rows"
same 'a scan that found nothing reads 0' "$(ow_of "$(TICK_ORPHANS_MIN_SECS=86400 owc_tick)")" 0

# The same read-only interpreter serves the tick field and the waiter's wake.
pd_doc="$W/handover/pool-chief.md"
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-4 question operator decision 268' \
    'pool-disposition: HIMMEL-5 slice HIMMEL-900' \
    'pool-disposition: HIMMEL-6 close PR 3905' \
    'pool-disposition: HIMMEL-7 question' \
    'pool-disposition: HIMMEL-999 question operator decision 268' \
    '' '## Results' 'pool-disposition: HIMMEL-8 question not live state' > "$pd_doc"
printf '%s\n' \
    '# disposition HIMMEL-1 in-flight owned by worker N1' \
    '# disposition HIMMEL-2 collision scripts/a.sh held by PR #20' \
    '# disposition HIMMEL-3 blocker HIMMEL-900 (In Progress, live)' \
    '# disposition HIMMEL-4 label operator-decision' \
    '# disposition HIMMEL-5 classification BLOCKED: broad task' \
    '# disposition HIMMEL-6 listed MERGED-NOT-CLOSED' \
    '# disposition HIMMEL-7 listed LOCAL' \
    '# disposition HIMMEL-8 below --top 7' \
    '# disposition HIMMEL-9 blocker HIMMEL-901 (not in mirror)' \
    '# disposition HIMMEL-10 collision scripts/b.sh held by listed HIMMEL-7' \
    '# disposition HIMMEL-11 blocker HIMMEL-902 (reopened live)' \
    '# disposition HIMMEL-12 blocker-unknown HIMMEL-903' > "$W/pool.rows"
pd_out="$(bash "$SUT" --pool-dispositions --doc "$pd_doc" < "$W/pool.rows" 2>/dev/null)"
contains 'pool counts in-flight as dispositioned, not a disjoint fifth bucket' "$pd_out" '# pool-counts 12/1/8/4'
not_contains 'a reopened-live blocker is not left unresolved' "$pd_out" '# pool-unresolved blocker HIMMEL-11 '
not_contains 'a blocker-unknown row is not left unresolved' "$pd_out" '# pool-unresolved blocker-unknown HIMMEL-12 '
contains 'malformed chief decisions remain named and unresolved' "$pd_out" '# pool-unresolved invalid HIMMEL-7 '
contains 'a non-Live-state decision never dispositions a key' "$pd_out" '# pool-unresolved below HIMMEL-8 '
contains 'an unread blocker is not a named live blocker' "$pd_out" '# pool-unresolved blocker HIMMEL-9 '
contains 'a listed candidate is not a live file holder' "$pd_out" '# pool-unresolved collision HIMMEL-10 '
contains 'unknown chief decision keys stay visible until corrected' "$pd_out" '# pool-unresolved invalid HIMMEL-999 '
same 'standalone pool mode resolves handover-relative document paths' "$(bash "$SUT" --pool-dispositions --doc pool-chief.md < "$W/pool.rows" 2>/dev/null)" "$pd_out"
same 'standalone pool mode resolves extensionless document names' "$(bash "$SUT" --pool-dispositions --doc pool-chief < "$W/pool.rows" 2>/dev/null)" "$pd_out"

po_doc="$W/handover/own-chief.md"
printf '%s\n' '# chief' '' '## Live state' \
    'pool-disposition: HIMMEL-21 question will look at it after the release' \
    'pool-disposition: HIMMEL-22 close PR 3905' \
    'pool-disposition: HIMMEL-23 question operator decision 268' \
    'pool-disposition: HIMMEL-24 slice HIMMEL-900' \
    'pool-disposition: HIMMEL-25 question O-123' \
    'pool-disposition: HIMMEL-26 slice worker N5619 is on it' \
    'pool-disposition: HIMMEL-27 slice HIMMEL-27' \
    'pool-disposition: HIMMEL-28 question SHA-256 pending the release' \
    'pool-disposition: HIMMEL-29 question the ISO-8601 parser, then HIMMEL-900' \
    '' '## Results' > "$po_doc"
for n in 21 22 23 24 25 26 27 28 29; do printf '# disposition HIMMEL-%s listed LOCAL\n' "$n"; done > "$W/own.rows"
printf '# disposition HIMMEL-30 in-flight owned by worker N5619\n' >> "$W/own.rows"
po_rc=0
po_out="$(bash "$SUT" --pool-dispositions --doc "$po_doc" < "$W/own.rows" 2>/dev/null)" || po_rc=$?
same 'a free-text promise with no owner leaves the tick printing (rc 0)' "$po_rc" 0
contains 'only reference-shaped targets and a worker the dispatcher names count as handled' "$po_out" '# pool-counts 10/1/4/6'
contains 'a free-text promise is unresolved as unowned' "$po_out" '# pool-unresolved unowned HIMMEL-21 '
contains 'the unowned line says what it lacks and quotes the line' "$po_out" 'names no owner or observable end: HIMMEL-21 question will look at it after the release'
contains 'a target that names only the ticket itself is unowned' "$po_out" '# pool-unresolved unowned HIMMEL-27 '
not_contains 'a PR target is owned' "$po_out" '# pool-unresolved unowned HIMMEL-22 '
not_contains 'a decision id target is owned' "$po_out" '# pool-unresolved unowned HIMMEL-23 '
not_contains 'a ticket target is owned' "$po_out" '# pool-unresolved unowned HIMMEL-24 '
contains 'an ask-record form with no store is unowned' "$po_out" '# pool-unresolved unowned HIMMEL-25 '
contains 'a fabricated worker number is refused' "$po_out" '# pool-unresolved unowned HIMMEL-26 '
contains 'a hyphenated word that is not a project key is unowned' "$po_out" '# pool-unresolved unowned HIMMEL-28 '
contains 'a project key that is not at the start of the target is unowned' "$po_out" '# pool-unresolved unowned HIMMEL-29 '
not_contains 'a worker the dispatcher names as holding the key needs no decision line' "$po_out" '# pool-unresolved unowned HIMMEL-30 '

printf '%s\n' \
    '# dropped from v1: 2 of 5 To Do (blocker 1, owned 1)' \
    'RESUME	HIMMEL-31	Medium	v1	resume one	files=a.sh	status=In Progress	last=-' \
    'RESUME	HIMMEL-32	Medium	v1	resume two	files=b.sh	status=In Progress	last=-' \
    'DESIGN	HIMMEL-33	NO-SPEC	Medium	v1	design	files=-' \
    'MERGED-NOT-CLOSED	HIMMEL-34	Medium	v1	needs a close	files=-	status=In Review	last=-' \
    'RESUME-HELD	HIMMEL-35	Medium	v1	held	files=-' \
    '# disposition HIMMEL-31 listed RESUME' \
    '# disposition HIMMEL-32 listed RESUME' \
    '# disposition HIMMEL-33 listed DESIGN' \
    '# disposition HIMMEL-34 listed MERGED-NOT-CLOSED' \
    '# disposition HIMMEL-36 blocker HIMMEL-900 (In Progress, live)' > "$W/dispatchable.rows"
dp_out="$(DOC='' bash "$SUT" --pool-dispositions < "$W/dispatchable.rows" 2>/dev/null)"
same 'RESUME and DESIGN rows are dispatchable' "$(printf '%s\n' "$dp_out" | sed -n 's/^# pool-dispatchable //p' | paste -sd,)" 'HIMMEL-31,HIMMEL-32,HIMMEL-33'
contains 'a row that needs a close is left out with its reason' "$dp_out" '# pool-left-out HIMMEL-34 listed MERGED-NOT-CLOSED'
contains 'a blocked ticket is left out with its reason' "$dp_out" '# pool-left-out HIMMEL-36 blocker HIMMEL-900 (In Progress, live)'
not_contains 'a held RESUME row is not dispatchable' "$dp_out" '# pool-dispatchable HIMMEL-35'
not_contains 'a dispatchable row is not left out' "$dp_out" '# pool-left-out HIMMEL-31 '

# the retired --legs / --legs-from flags are unknown options of the script's own parser
for old_flag in --legs --legs-from; do
    old_rc=0
    old_out="$(bash "$SUT" "$old_flag" x 2>&1)" || old_rc=$?
    [ "$old_rc" = 2 ] && pass "$old_flag exits 2" || fail "$old_flag exited $old_rc"
    contains "$old_flag prints the script's usage" "$old_out" 'usage: tick.sh'
    not_contains "$old_flag is not a missing function" "$old_out" 'command not found'
done

PD="$W/pd-mirror/HIMMEL"; mkdir -p "$PD"
for n in 901 902 904; do sed 's/fixVersions: \[\]/fixVersions: ["v1.1.3"]/' "$OW/HIMMEL-$n.md" > "$PD/HIMMEL-$n.md"; done
printf 'v1.1.3\tfalse\t\n' > "$W/pd-mirror/HIMMEL.versions.tsv"
printf '# chief\n\n## Live state\npool-disposition: HIMMEL-904 question operator decision 268\n' > "$pd_doc"
# shellcheck disable=SC2016  # the fixture expands arguments when the classifier runs
printf '#!/bin/sh\nfor k in "$@"; do printf "%%s\\tLOCAL-NATIVE\\tstub\\n" "$k"; done\n' > "$W/pd-classify"
chmod +x "$W/pd-classify"
pd_rows='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n'
pd_tick="$(NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS="$pd_rows" TOKEN='' bash "$SUT" --doc "$pd_doc" 2>/dev/null)"
contains 'a real tick uses the shared pool interpretation with PR ownership and chief decisions' "$pd_tick" ' pool=3/1/2/1 '

# --- (8336) INTAKE=<n> and chains=STALE:<n>/<m>: versionless operator work the pool cannot show, and a
# focus-chains.json that still lists Done steps. Each field is absent when there is nothing to say.
PDI="$W/pdi-mirror/HIMMEL"; mkdir -p "$PDI" "$W/ic-dir"
cp "$PD"/*.md "$PDI"/; cp "$W/pd-mirror/HIMMEL.versions.tsv" "$W/pdi-mirror/HIMMEL.versions.tsv"
ic_doc="$W/ic-dir/HIMMEL-8336-chief.md"; cp "$pd_doc" "$ic_doc"
ic_tick() { NEXT_DISPATCH_MIRROR="$PDI" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_STATE_DIR="$W/ic-state" TOKEN='' bash "$SUT" "$@" --doc "$ic_doc" 2>/dev/null; }
not_contains 'with no versionless operator ticket the tick prints no INTAKE=' "$(ic_tick)" ' INTAKE='
not_contains 'with no focus-chains.json the tick prints no chains=' "$(ic_tick)" ' chains='
sed -e 's/^labels: \[\]/labels: ["operator-directed"]/' -e 's/904/905/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-905.md"
sed -e 's/^statusCategory: "x"/statusCategory: "Done"/' -e 's/904/906/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-906.md"
sed -e 's/^body$/statusCategory: "Done"/' -e 's/904/907/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-907.md"  # open ticket whose description quotes a Done line
rm -rf "$W/ic-state"
contains 'a versionless operator-directed ticket shows as INTAKE=<n> beside pool=' "$(ic_tick)" ' INTAKE=1 '
ia_now="$(date +%s)"; ia_clock="$W/handover/inbox/N61.md.wait.intake"
rm -f "$ia_clock"
not_contains 'INTAKE above 0 with no waiter clock file prints the count and no INTAKE-AGE' "$(ic_tick)" ' INTAKE-AGE='
contains 'INTAKE above 0 with no waiter clock file still prints INTAKE=1' "$(ic_tick)" ' INTAKE=1 '
printf '%s\n0\n' "$((ia_now - 7 * 3600 - 60))" > "$ia_clock"
contains 'INTAKE above 0 with a clock 7 h old prints INTAKE-AGE=7h beside INTAKE=1' "$(ic_tick)" ' INTAKE=1 INTAKE-AGE=7h'
contains 'the plain tick intake: line carries the oldest age' "$(ic_tick --verbose)" 'intake: 1 (oldest 7h)'
printf '%s\n0\n' "$((ia_now - 3 * 3600 - 60))" > "$W/handover/inbox/N65.md.wait.intake"
contains 'the oldest of several waiter clocks wins' "$(ic_tick)" ' INTAKE-AGE=7h'
rm -f "$W/handover/inbox/N65.md.wait.intake"
ic_stderr() { NEXT_DISPATCH_MIRROR="$PDI" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_STATE_DIR="$W/ic-state" TOKEN='' bash "$SUT" --doc "$ic_doc" >/dev/null 2>"$W/ic-err"; cat "$W/ic-err"; }
for ia_bad_clock in 'garbage' '18446744073709551616'; do
    printf '%s\n0\n' "$ia_bad_clock" > "$ia_clock"
    ia_bad="$(ic_tick)"; ia_rc=$?
    same "a clock line '$ia_bad_clock' leaves the tick exiting 0" "$ia_rc" 0
    contains "a clock line '$ia_bad_clock' still prints INTAKE=1" "$ia_bad" ' INTAKE=1 '
    not_contains "a clock line '$ia_bad_clock' prints no INTAKE-AGE" "$ia_bad" ' INTAKE-AGE='
    not_contains "a clock line '$ia_bad_clock' prints no error naming the clock" "$(ic_stderr)" 'wait.intake'
done
printf '%s\n0\n' "$((ia_now - 7 * 3600 - 60))" > "$ia_clock"
rm -f "$PDI/HIMMEL-905.md"; rm -rf "$W/ic-state"
ia_zero="$(ic_tick)"; ia_rc=$?
same 'INTAKE at 0 leaves the tick exiting 0' "$ia_rc" 0
contains 'INTAKE at 0 still prints the pool field of a real tick' "$ia_zero" ' pool='
not_contains 'INTAKE at 0 prints no INTAKE field and no age, whatever the clock file says' "$ia_zero" ' INTAKE'
ia_zero_v="$(ic_tick --verbose)"; ia_rc=$?
same 'INTAKE at 0 leaves the verbose tick exiting 0' "$ia_rc" 0
contains 'INTAKE at 0 reads intake: 0 on the plain line' "$ia_zero_v" 'intake: 0'
not_contains 'INTAKE at 0 prints no oldest age on the plain line' "$ia_zero_v" 'oldest'
sed -e 's/^labels: \[\]/labels: ["operator-directed"]/' -e 's/904/905/g' "$OW/HIMMEL-904.md" > "$PDI/HIMMEL-905.md"
rm -f "$ia_clock"; rm -rf "$W/ic-state"
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-906"},{"key":"HIMMEL-904"},{"key":"HIMMEL-907"}]},{"drain":"x"}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a focus-chains.json that lists a Done step shows chains=STALE:<done>/<steps>; a Done line in a description is not a Done step' "$(ic_tick)" ' chains=STALE:1/4'
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"},{"key":"HIMMEL-907"}]}]\n' > "$W/ic-dir/focus-chains.json"
not_contains 'a focus-chains.json with no Done step prints no chains=, whatever its descriptions quote' "$(ic_tick)" ' chains='
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"},{"key":"HIMMEL-999"}]}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a chain step with no readable mirror file reads chains: skip, not ok' "$(ic_tick --verbose)" 'chains: skip'
printf '[{"name":"c","steps":[{"key":"HIMMEL-901"},{"key":"HIMMEL-904"}]}]\n' > "$W/ic-dir/focus-chains.json"
contains 'a chain whose steps all read and none is Done reads chains: ok' "$(ic_tick --verbose)" 'chains: ok'

# The pool snapshot classifies every version ticket (140 s on a 23-worker fleet),
# so a slow one never holds the tick: it reads ? until the detached snapshot lands, then counts.
# The kit is the real one, file by file, but its next-dispatchable.sh sleeps 8 s on the pool call.
if [ -n "$_TIMEOUT_BIN" ]; then
    real_scripts="$(cd "$HERE/../.." && pwd)"
    sk="$W/slowrepo/scripts"
    mkdir -p "$sk/handover/chief-kit"
    for f in "$real_scripts"/*; do [ "${f##*/}" = handover ] || ln -s "$f" "$sk/${f##*/}"; done
    for f in "$real_scripts"/handover/*; do [ "${f##*/}" = chief-kit ] || ln -s "$f" "$sk/handover/${f##*/}"; done
    for f in "$HERE"/*; do [ "${f##*/}" = next-dispatchable.sh ] || ln -s "$f" "$sk/handover/chief-kit/${f##*/}"; done
    printf '#!/usr/bin/env bash\ncase " $* " in *" --dispositions "*) sleep 8 ;; esac\nexec bash %q "$@"\n' "$HERE/next-dispatchable.sh" > "$sk/handover/chief-kit/next-dispatchable.sh"
    pd_slow() { NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_POOL_WAIT=1 TICK_STATE_DIR="$W/pd-slow-state" TOKEN='' "$_TIMEOUT_BIN" -k 2 6 bash "$sk/handover/chief-kit/tick.sh" --doc "$pd_doc" 2>/dev/null; }
    pd_slow_out="$(pd_slow)"; pd_rc=$?
    [ "$pd_rc" -eq 0 ] && pass 'a slow pool snapshot never holds the tick past its budget' || fail "a slow pool snapshot held the tick past its 6 s budget (rc $pd_rc)"
    contains 'the tick reads pool=? until the slow snapshot lands' "$pd_slow_out" ' pool=? '
    for _ in $(seq 1 40); do [ -z "$(find "$W/pd-slow-state" -name 'tick-pool-*.rows' 2>/dev/null)" ] || break; sleep 0.5; done
    contains 'the next tick counts from the finished snapshot' "$(pd_slow)" ' pool=3/1/2/1 '
    # A snapshot that ends while the tick waits for it adds none of its CPU to the tick: the same
    # wrapper spins about 2 s on the pool call, the control does not.
    # shellcheck disable=SC2016  # the wrapper's own $vars expand when it runs, not here
    printf '#!/usr/bin/env bash\ncase " $* " in *" --dispositions "*) [ -z "${SPIN:-}" ] || { %s; } ;; esac\nexec bash %q "$@"\n' "$spin9342" "$HERE/next-dispatchable.sh" > "$sk/handover/chief-kit/next-dispatchable.sh"
    pd_cpu9342() { rm -rf "$W/pd-cpu-state"; cpu9342 "$W/pd-cpu-line" env SPIN="$1" TOKEN= NEXT_DISPATCH_MIRROR="$PD" NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" OW_PR_ROWS='4001\tfix: [HIMMEL-901] x\tfix/himmel-901-x\n' TICK_POOL_WAIT=30 TICK_STATE_DIR="$W/pd-cpu-state" bash "$sk/handover/chief-kit/tick.sh" --doc "$pd_doc"; }
    pd_base9342="$(pd_cpu9342 '')"
    contains 'the control tick counts from the snapshot it waited for' "$(cat "$W/pd-cpu-line")" ' pool=3/1/2/1 '
    pd_spin9342="$(pd_cpu9342 1)"
    contains 'the spinning snapshot lands in the tick that launched it' "$(cat "$W/pd-cpu-line")" ' pool=3/1/2/1 '
    if [ $((pd_spin9342 - pd_base9342)) -lt 1000 ]; then pass 'a pool snapshot the tick waits out adds none of its CPU to the tick'; else fail "a pool snapshot added $((pd_spin9342 - pd_base9342)) ms of CPU to the tick (spin ${pd_spin9342} ms, control ${pd_base9342} ms)"; fi
else
    skip 'a slow pool snapshot never holds the tick: no timeout'
fi

# --- pool-closed=<closed>/<total>: Done or wont-do keys on the Live state priority: line.
mk_ow 911 "Done" Task
mk_ow 912 "wont do" Task
for n in 911 912; do sed 's/^statusCategory: "x"$/statusCategory: "Done"/' "$OW/HIMMEL-$n.md" > "$OW/HIMMEL-$n.md.new" && mv "$OW/HIMMEL-$n.md.new" "$OW/HIMMEL-$n.md"; done
pc_doc="$W/handover/HIMMEL-6602-chief.md"
printf '%s\n' '# chief' '' '## Live state' 'priority: 911 | 912(K1) 904 | 901(+911) 9999' '' '## Results' > "$pc_doc"
pc_tick() { NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" TOKEN='' bash "$SUT" "$@" 2>/dev/null; }
contains 'closed keys on the priority line show as pool-closed=<closed>/<total>' "$(pc_tick --doc "$pc_doc")" ' pool-closed=2/5'
contains '--verbose labels pool-closed' "$(pc_tick --doc "$pc_doc" --verbose)" 'pool-closed: 2/5'
printf '%s\n' '## Live state' 'priority: 904 901' > "$pc_doc"
not_contains 'a priority line with no closed key hides pool-closed' "$(pc_tick --doc "$pc_doc")" 'pool-closed'
not_contains 'no --doc hides pool-closed' "$(pc_tick)" 'pool-closed'
# --- prio=<open>/<total> and prio-stale=WARN:<...>: the priority line gone dead or off-version.
mk_prio() { # <num> <statusCategory> <fixVersions json>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "x"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: %s\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$1" > "$OW/HIMMEL-$1.md"
}
absent() { # <name> <needle> <tick args...>: the tick must print a TICK line, and that line lacks <needle>
    local n="$1" s="$2" o; shift 2; o="$(pc_tick "$@")"
    case "$o" in *"TICK "*) not_contains "$n" "$o" "$s" ;; *) fail "$n (the tick printed no TICK line)" ;; esac
}
pr_keys=""
for n in $(seq 8101 8180); do mk_prio "$n" Done '["v1.1.3"]'; pr_keys="$pr_keys $n"; done
mk_prio 8190 "To Do" '["v1.1.5"]'
mk_prio 8191 "To Do" '["v1.1.3"]'
pr_doc="$W/handover/HIMMEL-8072-chief.md"
printf '%s\n' '# chief' '' '## Live state' "priority:$pr_keys 8191" 'focus-version: v1.1.3' '' '## Results' > "$pr_doc"
contains 'a line with 1 open key of 81 shows prio=1/81' "$(pc_tick --doc "$pr_doc")" ' prio=1/81 '
contains 'a line with 1 open key of 81 gives WARN prio-stale' "$(pc_tick --doc "$pr_doc")" ' prio-stale=WARN:low'
contains '--verbose labels prio and the prio-stale WARN' "$(pc_tick --doc "$pr_doc" --verbose)" 'prio-stale: WARN:low'
printf '%s\n' '## Live state' 'priority: 8101 8190 8191' 'focus-version: v1.1.3' > "$pr_doc"
contains 'an open v1.1.5 key with focus-version v1.1.3 makes the WARN name the key' "$(pc_tick --doc "$pr_doc")" ' prio-stale=WARN:HIMMEL-8190@v1.1.5'
absent 'the off-version WARN is quiet when the key matches' 'HIMMEL-8191@' --doc "$pr_doc"
printf '%s\n' '## Live state' 'priority: 8191 904' 'focus-version: v1.1.3' > "$pr_doc"
contains 'a live line shows prio=<open>/<total>' "$(pc_tick --doc "$pr_doc")" ' prio=2/2 '
absent 'a live on-version line has no prio-stale' 'prio-stale' --doc "$pr_doc"
printf '%s\n' '## Live state' 'legs: none' > "$pr_doc"
absent 'no priority: line hides prio' ' prio' --doc "$pr_doc"
DOC='' absent 'no --doc and no exported DOC hides prio' ' prio='
# pool-stale=<n>:<KEY>,...: a pool-disposition: line whose named blocker is Done. The
# detailed rows live in test-tick-pool-stale.sh; this pins the tick line and --verbose.
printf '%s\n' '# chief' '' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' '' '## Results' > "$pc_doc"
contains 'a disposition whose blocker is Done shows as pool-stale=<n>:<KEY>' "$(pc_tick --doc "$pc_doc")" ' pool-stale=1:HIMMEL-7120'
contains '--verbose labels pool-stale' "$(pc_tick --doc "$pc_doc" --verbose)" 'pool-stale: 1:HIMMEL-7120'
not_contains 'a nothing-unversioned mirror hides residual-unversioned' "$(pc_tick --doc "$pc_doc")" 'residual-unversioned'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on a doc with an open blocker' || fail 'the tick exits 0 on a doc with an open blocker'
contains 'a disposition whose blocker is still open reads the all-clear pool-stale=0' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
contains 'no --doc falls back to the exported DOC and reads pool-stale=0' "$(DOC="$pc_doc" pc_tick)" ' pool-stale=0'
printf '%s\n' '## Live state' 'priority: 904 901' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on a doc with no disposition line' || fail 'the tick exits 0 on a doc with no disposition line'
contains 'a doc with no disposition line still reads pool-stale=0, so the waiter can clear a marker whose line was removed' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
# The waiter reads the compact tick line, so the all-clear it needs to clear its marker (an
# explicit pool-stale=0 after a disposition was read) must be on that line. These rows feed the
# REAL tick to the REAL waiter: no injected field.
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
pc_tick --doc "$pc_doc" >/dev/null && pass 'the tick exits 0 on the waiter fixture doc' || fail 'the tick exits 0 on the waiter fixture doc'
contains 'a read disposition with no stale blocker prints the all-clear pool-stale=0' "$(pc_tick --doc "$pc_doc")" ' pool-stale=0'
wt_dir="$W/wt-stale"; mkdir -p "$wt_dir/consoles" "$wt_dir/stub"
: > "$wt_dir/consoles/c.md"; wt_inbox="$wt_dir/consoles/c.md"
# the stub logs one line per COMPLETED tick, so a quiet arm can prove it saw whole samples
# shellcheck disable=SC2016  # $? must reach the generated stub literally, not expand here
printf '#!/usr/bin/env bash\nenv NEXT_DISPATCH_MIRROR=%q NEXT_DISPATCH_GH_CMD=%q NEXT_DISPATCH_GIT_DIR=%q NEXT_DISPATCH_MAIN_REF=main TOKEN= bash %q --doc %q\nrc=$?\necho x >> %q\nexit $rc\n' "$OW" "$W/ow-gh" "$W/ow-main" "$SUT" "$pc_doc" "$wt_dir/ticks" > "$wt_dir/stub/tick.sh"
printf '#!/usr/bin/env bash\nprintf "PROCEED\\n"\n' > "$wt_dir/stub/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$wt_dir/stub/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$wt_dir/stub/budget-off.sh"
printf '#!/usr/bin/env bash\nprintf "# pool=0/7,LOW\\nPOOL-EMPTY\\n"\n' > "$wt_dir/stub/dispatch.sh"
chmod +x "$wt_dir/stub/"*.sh
wt_arm() { # <outfile> [seconds]: one foreground waiter arm over the real tick; wt_rc is 124 when nothing woke it
    CHIEF_WAIT_TICK="$wt_dir/stub/tick.sh" CHIEF_WAIT_USAGE="$wt_dir/stub/bank.sh" CHIEF_WAIT_DISPATCH="$wt_dir/stub/dispatch.sh" \
    CHIEF_WAIT_PAGE_CMD="$wt_dir/stub/off.sh" CHIEF_WAIT_BUDGET="$wt_dir/stub/budget-off.sh" WAIT_SWEEP_CMD="$wt_dir/stub/off.sh" WAIT_FOCUS_CMD="$wt_dir/stub/off.sh" \
    CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 HIMMEL_DENIAL_ACK_DIR="$wt_dir/acks" \
        timeout "${2:-40}" bash "$HERE/chief-wait.sh" "$wt_inbox" --workers "N1.md" > "$1" 2>/dev/null  # gnu-ok: Linux-only kit
    wt_rc=$?
}
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
# The fixture's own state (underfilled, unwatched) wakes the waiter first. wt_quiet arms until a
# sample wakes nobody (rc 124) AFTER at least two whole ticks completed in that arm (a timeout
# mid-sample proves nothing; the first completed sample is processed before the second starts);
# wt_stale arms until the pool-stale wake shows up. Both bound the loop.
wt_ticks() { if [ -f "$wt_dir/ticks" ]; then wc -l < "$wt_dir/ticks" | tr -d ' '; else echo 0; fi; }
wt_quiet() { local t0; wt_quiet_ok=no; : > "$1"; for _ in 1 2 3 4 5; do t0="$(wt_ticks)"; wt_arm "$1.arm" 12; cat "$1.arm" >> "$1"; if [ "$wt_rc" -eq 124 ] && [ "$(( $(wt_ticks) - t0 ))" -ge 2 ]; then wt_quiet_ok=yes; break; fi; done; }
wt_stale() { : > "$1"; for _ in 1 2 3 4; do wt_arm "$1.arm" 20; cat "$1.arm" >> "$1"; grep -q '^WAKE pool-stale' "$1.arm" && break; done; }
wt_quiet "$W/wt0.out"
[ "$wt_quiet_ok" = yes ] && pass 'the warm-up drains every non-stale wake' || fail 'the warm-up drains every non-stale wake'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' > "$pc_doc"
wt_stale "$W/wt1.out"
contains 'the real tick makes the waiter wake for a stale disposition' "$(cat "$W/wt1.out")" 'WAKE pool-stale HIMMEL-7120'
grep -q 'HIMMEL-7120' "$wt_inbox.wait.stale" 2>/dev/null && pass 'the waiter marker holds the stale key' || fail 'the waiter marker holds the stale key'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-904 then the rest' > "$pc_doc"
wt_quiet "$W/wt2.out"
[ "$wt_quiet_ok" = yes ] && [ ! -e "$wt_inbox.wait.stale" ] && pass 'a real all-clear from the tick clears the waiter marker' || fail 'a real all-clear from the tick clears the waiter marker'
printf '%s\n' '## Live state' 'pool-disposition: HIMMEL-7120 slice HIMMEL-911 then the rest' > "$pc_doc"
wt_stale "$W/wt3.out"
contains 'a key that went stale again after an all-clear wakes again' "$(cat "$W/wt3.out")" 'WAKE pool-stale HIMMEL-7120'
rm -f "$pc_doc"

# --- ready-mismatch=<flagged>/<ready>,nogo=<k>/<judged>[,ALERT] ---
# A READY claim a judge or the diff contradicts. Fixtures only: the changed-file lists are
# pre-recorded in the ready-files cache and the gh stub fails, so no live gh runs.
RMD="$W/rm"
mkdir -p "$RMD/verdicts" "$W/repo/scripts/ci" "$TICK_STATE_DIR/ready-files"
printf '# trust paths\n^scripts/ci/\n^scripts/lib/\n' > "$W/repo/scripts/ci/ci-trust-paths.txt"
# shellcheck disable=SC2016  # "$*" expands in the generated stub, not here
printf '#!/bin/sh\necho "$*" >> "%s/rm-gh.calls"\nexit 1\n' "$W" > "$W/rm-gh"
chmod +x "$W/rm-gh"
export TICK_GH_CMD="$W/rm-gh"
rm_head() { printf '%040d' "$1"; }
rm_worker() { printf '# T - worker N%s (%s, native)\n\n## Results\n\n- 10:00 READY %s %s GREEN %s\n' "$1" "$2" "$3" "$(rm_head "$3")" "$4" > "$RMD/worker$1.md"; }
rm_files() { local pr="$1"; shift; printf '%s\n' "$@" > "$TICK_STATE_DIR/ready-files/$pr-$(rm_head "$pr")"; }
# shellcheck disable=SC2016  # the backticks are literal verdict text
rm_verdict() { mkdir -p "$RMD/verdicts/j$1"; printf '# VERDICT j%s - judge\n\nwriter-session: x\nwritten-at: t\n\n## Verdict\n\n**%s** for head `%s`.\n\npr: %s\nprior: GO\n\nevidence\nmac: 0\n' "$1" "$2" "$(rm_head "$1")" "$1" > "$RMD/verdicts/j$1/judge.md"; }
rm_worker 1 claude-sonnet-5-5 101 '- trust path: none'
rm_files 101 docs/a.md scripts/ci/x.sh
rm_worker 2 claude-opus-5-5 102 '- CI green, marker cleared'
rm_files 102 scripts/lib/y.sh
rm_worker 3 claude-sonnet-5-5 103 '- no trust path touched'
rm_files 103 docs/a.md
rm_verdict 103 GO
rm_worker 4 claude-sonnet-5-5 104 '- trust path: none'
rm_files 104 docs/b.md
rm_verdict 104 NO-GO
mkdir -p "$RMD/verdicts/jdecoy"
# shellcheck disable=SC2016  # the backticks are literal verdict text
printf '## Verdict\n\n**NO-GO** for head `%s`.\n\npr: 777\n' "$(rm_head 103)" > "$RMD/verdicts/jdecoy/judge.md"
rm_worker 5 claude-opus-5-5 105 '- touches scripts/ci/, trust-reviewed GO needed'
rm_files 105 scripts/ci/z.sh
printf '# chief\n' > "$RMD/chief.md"
rm_of() { TOKEN='' bash "$SUT" --doc "$RMD/chief.md" 2>/dev/null | sed -n -E 's/.* ready-mismatch=([^ ]*).*/\1/p'; }
same 'ready-mismatch= flags a claimed-none and a silent READY, counts the NO-GO-at-head one in nogo only, and skips the GO control and the named-trust one' "$(rm_of)" '2/5,nogo=1/2,ALERT'
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'detail flags the claimed-none READY on a trust-path diff as M1b' "$rm_det" "M1b	101	"
contains 'detail flags the silent READY on a trust-path diff as M1c' "$rm_det" "M1c	102	"
contains 'detail flags the READY whose head a judge NO-GO-ed as M1a' "$rm_det" "M1a	104	"
not_contains 'a clean READY with a GO verdict is not flagged' "$rm_det" "	103	"
not_contains 'a READY that names its trust-path touch is not flagged' "$rm_det" "	105	"
contains 'detail breaks the NO-GO rate out per model' "$rm_det" "MODEL	claude-sonnet-5-5	"
contains 'verbose labels the field' "$(TOKEN='' bash "$SUT" --doc "$RMD/chief.md" --verbose 2>/dev/null)" 'ready-mismatch: 2/5,nogo=1/2,ALERT'
[ -f "$W/rm-gh.calls" ] && ! grep -q 'files' "$W/rm-gh.calls" && pass 'cached file lists mean no file-list gh call' || fail 'a cached PR still read its files from gh'
rm -f "$W/rm-gh.calls"
rm -f "$RMD"/worker[1245].md
same 'ready-mismatch= is absent when every READY is clean' "$(rm_of)" ''
rm -f "$RMD/worker3.md"
for n in $(seq 201 224); do rm_worker "$n" claude-sonnet-5-5 "$n" '- trust path: none'; done
rm_of >/dev/null
[ "$(wc -l < "$W/rm-gh.calls" | tr -d ' ')" -le 20 ] && pass 'at most 20 uncached gh calls per tick' || fail "gh was called $(wc -l < "$W/rm-gh.calls" | tr -d ' ') times"
rm -f "$RMD"/worker2*.md "$W/rm-gh.calls"
rm -rf "$TICK_STATE_DIR/ready-files"
mkdir -p "$TICK_STATE_DIR/ready-files"
# shellcheck disable=SC2016  # $RM_GH_OID expands in the generated stub, not here
printf '#!/bin/sh\npwd >> "%s/rm-gh.pwd"\nprintf "%%s\\nscripts/ci/x.sh\\n" "$RM_GH_OID"\n' "$W" > "$W/rm-gh"
rm_worker 301 claude-sonnet-5-5 301 '- trust path: none'
RM_GH_OID="$(rm_head 999)" rm_of >/dev/null
[ ! -e "$TICK_STATE_DIR/ready-files/301-$(rm_head 301)" ] && pass 'a PR whose current head is not the READY head is not cached or trusted' || fail 'a stale-head file list was cached'
same 'a stale-head read is unchecked, not flagged' "$(RM_GH_OID="$(rm_head 999)" rm_of)" ''
rm_n1="$(wc -l < "$W/rm-gh.pwd" | tr -d ' ')"
RM_GH_OID="$(rm_head 999)" rm_of >/dev/null
[ "$(wc -l < "$W/rm-gh.pwd" | tr -d ' ')" = "$rm_n1" ] && pass 'a failed lookup backs off instead of retrying every tick' || fail 'a failed lookup was retried inside the backoff window'
rm -f "$TICK_STATE_DIR"/ready-files/*.fail
same 'a leading-zero TICK_READY_WINDOW_DAYS is read as decimal' "$(RM_GH_OID="$(rm_head 301)" TICK_READY_WINDOW_DAYS=08 rm_of)" '1/1,nogo=0/0,ALERT'
rm -f "$TICK_STATE_DIR"/ready-files/*.fail "$TICK_STATE_DIR/ready-files/301-$(rm_head 301)"
same 'a matching-head read flags the claimed-none READY' "$(RM_GH_OID="$(rm_head 301)" rm_of)" '1/1,nogo=0/0,ALERT'
[ "$(sort -u "$W/rm-gh.pwd")" = "$W/repo" ] && pass 'gh runs in the --repo checkout' || fail "gh ran in $(sort -u "$W/rm-gh.pwd")"
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
printf '#!/bin/sh\nexec sleep 30\n' > "$W/rm-gh"
for n in 311 312 313; do rm_worker "$n" claude-sonnet-5-5 "$n" '- trust path: none'; done
rm_t0=$SECONDS
rm_det="$(TICK_READY_BUDGET_SEC=2 bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
[ $((SECONDS - rm_t0)) -lt 8 ] && pass 'a hanging gh cannot hold the scan past its wall-clock budget' || fail "the scan took $((SECONDS - rm_t0))s against a 2s budget"
contains 'a spent budget is reported as PARTIAL' "$rm_det" "PARTIAL"
contains 'a spent budget leaves the remaining READYs unchecked' "$rm_det" "COUNT	3	0	0	0	3"
same 'the tick field reads partial when the budget was spent' "$(TICK_READY_BUDGET_SEC=2 rm_of)" '0/3,nogo=0/0,partial'
rm -f "$RMD"/worker*.md
printf '#!/bin/sh\nexit 1\n' > "$W/rm-gh"
rm_worker 321 claude-sonnet-5-5 321 '- trust path: not touched'
rm_worker 322 claude-sonnet-5-5 322 '- this PR does not touch a trust path'
rm_files 321 scripts/ci/a.sh
rm_files 322 scripts/ci/b.sh
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a not-touched claim on a trust-path diff is M1b' "$rm_det" "M1b	321	"
contains 'a does-not-touch claim on a trust-path diff is M1b' "$rm_det" "M1b	322	"
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
rm -rf "$RMD/verdicts"
mkdir -p "$RMD/verdicts"
# shellcheck disable=SC2016  # "$*" expands in the generated stub, not here
printf '#!/bin/sh\ncase "$*" in *state*) echo MERGED ;; *) exit 1 ;; esac\n' > "$W/rm-gh"
rm_worker 331 claude-sonnet-5-5 331 '- trust path: none'
rm_worker 332 claude-sonnet-5-5 332 '- CI green, marker cleared'
rm_files 331 scripts/ci/m.sh
rm_files 332 scripts/lib/n.sh
same 'a trust-path claim mismatch on an already-merged PR is not flagged' "$(rm_of)" ''
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
not_contains 'a merged PR raises no M1b' "$rm_det" "M1b	331	"
not_contains 'a merged PR raises no M1c' "$rm_det" "M1c	332	"
not_contains 'a merged PR raises no trust ALERT' "$rm_det" "ALERT"
[ -e "$TICK_STATE_DIR/ready-files/331-$(rm_head 331).merged" ] && pass 'a merged state is cached' || fail 'a merged PR was not cached'
printf '#!/bin/sh\nexit 1\n' > "$W/rm-gh"
same 'a merged PR stays unflagged from its cache when gh is down' "$(rm_of)" ''
rm -f "$RMD"/worker*.md "$TICK_STATE_DIR"/ready-files/*
rm_worker 341 claude-sonnet-5-5 341 '- trust path: none'
rm_files 341 docs/ok.md
rm_verdict 341 NO-GO
same 'a lone NO-GO at the READY head is counted in nogo, not in ready-mismatch' "$(rm_of)" ''
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a lone NO-GO is still listed as M1a in the detail' "$rm_det" "M1a	341	"
contains 'a lone NO-GO counts zero flagged and one nogo' "$rm_det" "COUNT	1	0	1	1	0"
rm -f "$RMD"/worker*.md
rm -rf "$RMD/verdicts"
mkdir -p "$RMD/verdicts"
rm_det="$(bash "$SUT" --ready-mismatch --ready-dir "$RMD" 2>/dev/null)"
contains 'a window with no READY reports a zero count' "$rm_det" "COUNT	0	0	0	0	0"
unset TICK_GH_CMD
rm -rf "$RMD" "$W/rm-gh.calls" "$W/rm-gh.pwd"

# The chief's own HANDOFF (<doc stem>-HANDOFF.md) over HANDOFF_BUDGET_BYTES, or
# its decisions: line over DECISIONS_BUDGET_BYTES, prints an ACTION line.
# The decisions: text and the HANDOFF note are copied from live chief docs.
d6603="$W/handover/HIMMEL-6603-chief.md"
printf '%s\n' '# console' '' '## Live state' 'decisions: OPERATOR 10-17 afternoon (BINDING, carry verbatim to every successor): (3) Residuals 6102-6108, 6110 deferred (out of v1.1.3). Windows/WSL support work is NEVER dispatched. (4) qmd fork: version with tags + main (bump main too, tag releases). (6) Use more fleet + Claude API + claudex budget; WORKER_SESSION_EFFORT high on claudex legs.' > "$d6603"
printf '%s\n' '> HANDOFF over budget: 46253 bytes (limit 12000); Live state 41637 bytes, wrapped-PR list 198 bytes — tighten the Live state' > "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
hb_small="$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)"
not_contains 'a HANDOFF and decisions: line under their budgets print no ACTION' "$hb_small" 'over-budget'
hb_over="$(HANDOFF_BUDGET_BYTES=100 DECISIONS_BUDGET_BYTES=200 TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)"
contains 'a HANDOFF over HANDOFF_BUDGET_BYTES prints an ACTION line' "$hb_over" 'ACTION handoff-over-budget=127/100: '
contains 'the HANDOFF ACTION names the HANDOFF file' "$hb_over" 'HIMMEL-6603-chief-HANDOFF.md'
contains 'a decisions: line over DECISIONS_BUDGET_BYTES prints an ACTION line' "$hb_over" 'ACTION decisions-over-budget=347/200: '
contains 'the decisions ACTION names the bucket decisions file' "$hb_over" "$W/handover/specs/decisions/chief-decisions-"
case "$(printf '%s\n' "$hb_over" | grep -c '^TICK ')" in 1) pass 'the size ACTION lines add no second TICK line' ;; *) fail 'the size ACTION lines add no second TICK line' ;; esac
head -c 6000 /dev/zero | tr '\0' x > "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
not_contains 'a HANDOFF of exactly 6000 bytes is within the default budget' "$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'handoff-over-budget'
printf 'x' >> "$W/handover/HIMMEL-6603-chief-HANDOFF.md"
contains 'a HANDOFF of 6001 bytes is over the default budget' "$(TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION handoff-over-budget=6001/6000: '
contains 'a non-numeric HANDOFF_BUDGET_BYTES falls back to the default' "$(HANDOFF_BUDGET_BYTES=12k TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION handoff-over-budget=6001/6000: '
printf '%s\n' '# chief' '' 'decisions: a brief note above Live state, not the line' '' '## Live state' 'decisions: (1) short.' > "$d6603"
contains 'only the Live state decisions: line is measured' "$(DECISIONS_BUDGET_BYTES=10 TOKEN='' bash "$SUT" --doc "$d6603" 2>/dev/null)" 'ACTION decisions-over-budget=21/10: '
rm -f "$d6603" "$W/handover/HIMMEL-6603-chief-HANDOFF.md"

# --- effort=MISMATCH:<worker> ----------------------------------------------------
# The asked effort is the WORKER_SESSION_EFFORT line in the launch-<label>.sh the chief
# wrote beside the worker doc; the live effort is the effort= token on the worker's
# newest LIVE bullet. A worker asked for high that reports medium is the 09-23 to
# 10-20 incident this field exists to show.
fm="$W/handover/chief.fleet.json"
ef_doc="$W/handover/HIMMEL-6588-N77-effort.md"
ef_ok="$W/handover/HIMMEL-6588-N78-effort.md"
ef_none="$W/handover/HIMMEL-6588-N79-effort.md"
printf '%s\n' '# worker' '- 09:00 LIVE — started effort=medium model=claude-sonnet-5-5' > "$ef_doc"
printf '%s\n' '# worker' '- 09:00 LIVE — started effort=high model=claude-sonnet-5-5' > "$ef_ok"
printf '%s\n' '# worker' '- 09:00 LIVE — started, no effort token' > "$ef_none"
for ef_l in N77 N78 N79; do printf '%s\n' '#!/usr/bin/env bash' 'export WORKER_SESSION_EFFORT=high' > "$W/handover/launch-$ef_l.sh"; done
printf '{"schema":1,"legs":[{"doc":"%s","label":"N77","lockless":true},{"doc":"%s","label":"N78","lockless":true},{"doc":"%s","label":"N79","lockless":true}]}\n' "$ef_doc" "$ef_ok" "$ef_none" > "$fm"
ef_out="$(WORKERS='' bash "$SUT" --workers-from "$fm")"; ef_rc=$?
if [ "$ef_rc" -eq 0 ]; then pass 'the effort fixture tick exits 0'; else fail "the effort fixture tick exits 0 (rc=$ef_rc)"; fi
contains 'a worker asked for high whose LIVE bullet says medium reads effort=MISMATCH:N77' "$ef_out" ' effort=MISMATCH:N77'
not_contains 'a worker whose LIVE effort matches the asked one is not flagged' "$ef_out" 'MISMATCH:N78'
not_contains 'a LIVE bullet with no effort= token is not flagged' "$ef_out" 'MISMATCH:N79'
printf '%s\n' '- 09:30 LIVE — resumed effort=high model=claude-sonnet-5-5' >> "$ef_doc"
ef_out2="$(WORKERS='' bash "$SUT" --workers-from "$fm")"; ef_rc2=$?
if [ "$ef_rc2" -eq 0 ]; then pass 'the re-run effort fixture tick exits 0'; else fail "the re-run effort fixture tick exits 0 (rc=$ef_rc2)"; fi
contains 'the re-run effort fixture tick prints its TICK line' "$ef_out2" 'TICK '
not_contains 'only the newest LIVE bullet decides the effort' "$ef_out2" 'effort=MISMATCH'
rm -f "$ef_doc" "$ef_ok" "$ef_none" "$W/handover/launch-N77.sh" "$W/handover/launch-N78.sh" "$W/handover/launch-N79.sh" "$fm"

# --- tmp=<pct>[!] -----------------------------------------------------
# A read-only df on TICK_TMP_DIR (default /tmp); stubbed through TICK_DF.
cat > "$W/df-stub.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = -P ] && [ "$2" = "$TICK_TMP_DIR" ] || exit 1
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf 'tmpfs 1000 %s %s %s%% /tmp\n' "$STUB_TMP_PCT" "$((1000 - STUB_TMP_PCT))" "$STUB_TMP_PCT"
STUB
chmod +x "$W/df-stub.sh"
tmp_run() { STUB_TMP_PCT="$1" TICK_TMP_DIR="$W" TICK_DF="$W/df-stub.sh" bash "$SUT" "${@:2}"; }
contains 'tmp= shows the /tmp percentage below the warn level' "$(tmp_run 42)" ' tmp=42'
not_contains 'tmp= has no ! below 80' "$(tmp_run 79)" ' tmp=79!'
contains 'tmp= carries ! at 80' "$(tmp_run 80)" ' tmp=80!'
contains 'tmp= carries ! above 80' "$(tmp_run 97)" ' tmp=97!'
contains 'verbose labels tmp' "$(tmp_run 42 --verbose)" 'tmp: 42'
not_contains 'tmp= is absent when the dir is unreadable' "$(bash "$SUT")" ' tmp='
# The waiter's wake key is the key rows of the table that its loop selects. The loop line must be this
# one exactly, so an edit anywhere in it (a condition inside the awk, a filter after it) leaves the list empty.
IFS= read -r cw_loop <<'LOOP'
for f in $(awk -F'\t' '$0 !~ /^#/ && $5 == "key" && $1 != "usage" { print $1 }' "$HERE/wake-rules.tsv"); do
LOOP
# shellcheck disable=SC2016  # the text searched for is the loop's own, not an expansion
cw_have="$(grep -F -e 'for f in $(awk' "$HERE/chief-wait.sh" | sed -E 's/^[[:space:]]+//')"
cw_keys=""
if [ "$cw_have" = "$cw_loop" ]; then
    # shellcheck disable=SC2016  # $4 is awk's field, not an expansion
    cw_prog="$(printf '%s' "$cw_loop" | awk -F"'" '{ print $4 }')"
    cw_keys=" $(awk -F'\t' "$cw_prog" "$HERE/wake-rules.tsv" | tr '\n' ' ')"
fi
contains "chief-wait's wake key list was found" "$cw_keys" ' vmrun '
not_contains "tmp= is not in chief-wait's wake key" "$cw_keys" ' tmp'
# --- cired= (open ci-red issues): a count, unknown on failure, never a wake.
cired_tick() { STUB_CIRED_OUT="$1" bash "$SUT" 2>/dev/null; }
contains 'cired= prints the open ci-red issue count' "$(cired_tick 3)" ' cired=3 '
contains 'a failed ci-red read prints cired=unknown' "$(STUB_CIRED_RC=1 bash "$SUT" 2>/dev/null)" ' cired=unknown '
contains 'a non-count ci-red read prints cired=unknown' "$(cired_tick 'oops')" ' cired=unknown '
contains 'a ci-red count at the read cap prints cired=1000+' "$(cired_tick 1000)" ' cired=1000+ '
not_contains "cired= is not in chief-wait's wake key" "$cw_keys" ' cired'

# --- dispatch=: in-flight workflow_dispatch runs on worker branches, one runs
# list per tick plus one jobs read per run; late (>= 80 % of the job timeout), idle (no job
# changed state for 30 min) and orphan (its worker WRAPPED) raise ACTION dispatch-stall.
mkdir -p "$W/repo/.github/workflows"
printf '%s\n' 'jobs:' '  shell:' '    timeout-minutes: 120' '  summary:' '    timeout-minutes: 10' > "$W/repo/.github/workflows/macos-cadence.yml"
printf '%s\n' '# worker' '- WRAPPED — done' > "$W/handover/HIMMEL-333-legN333.md"
d_iso() { date -u -d "-$1 seconds" +%Y-%m-%dT%H:%M:%SZ; }
d_wf='.github/workflows/macos-cadence.yml'
d_log="$W/dispatch-calls.txt"
d_tick() { # <runs> <jobs> [workers]
    WORKERS="${3:-HIMMEL-111-legN61 HIMMEL-333-legN333}" STUB_DISPATCH_RUNS="$1" STUB_DISPATCH_JOBS="$2" STUB_DISPATCH_LOG="$d_log" bash "$SUT" 2>/dev/null
}
d_head=1111111111111111111111111111111111111111
d_pr_rows="3768\\tfix/himmel-111-mac\\ttrue\\tme\\tfalse\\t2026-01-01T00:00:00Z\\t0\\t$d_head\\t\\n"

: > "$d_log"
d_late="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4001\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 6150)\\n" "9\\t3\\t$(d_iso 300)\\n")"
contains 'a run at 85 % of its job timeout lists dispatch= with the worker, elapsed/timeout and jobs done' "$d_late" 'dispatch=4001:N61:102/120m:3/9@1111111:late'
contains 'a run at 85 % of its job timeout raises ACTION dispatch-stall' "$d_late" 'ACTION dispatch-stall 4001 N61'
not_contains 'a run on the open PR head is not stale-head' "$d_late" 'stale-head'
d_calls="$(grep -c '^runs ' "$d_log")"
if [ "$d_calls" = 1 ]; then pass 'one tick lists the runs exactly once'; else fail "runs list calls per tick = $d_calls, want 1"; fi
if grep -q '^runs .*per_page=100' "$d_log"; then pass 'the runs list asks for the largest page, so the oldest in-flight runs are in it'; else fail 'runs list is not per_page=100'; fi
d_jobs="$(grep -c '^jobs ' "$d_log")"
if [ "$d_jobs" = 1 ]; then pass 'one tick reads the jobs of each run once'; else fail "jobs reads per tick = $d_jobs, want 1"; fi

d_early="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4002\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 1470)\\n" "9\\t1\\t$(d_iso 120)\\n")"
contains 'a run at 20 % of its job timeout is listed' "$d_early" 'dispatch=4002:N61:24/120m:1/9@1111111'
not_contains 'a run at 20 % of its job timeout is not flagged late' "$d_early" ':late'
not_contains 'a run at 20 % of its job timeout raises no ACTION dispatch-stall' "$d_early" 'ACTION dispatch-stall'

d_idle="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4003\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 2400)\\n" "9\\t1\\t$(d_iso 2100)\\n")"
contains 'a run whose jobs have not changed state for 30 min is flagged idle' "$d_idle" 'dispatch=4003:N61:40/120m:1/9@1111111:idle'
contains 'an idle run raises ACTION dispatch-stall' "$d_idle" 'ACTION dispatch-stall 4003 N61'

d_orph="$(d_tick "4004\\t$d_wf\\tfix/himmel-333-mac\\t$d_head\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
contains 'a run whose worker is WRAPPED is flagged orphan' "$d_orph" 'dispatch=4004:N333:5/120m:1/9@1111111:orphan'
contains 'an orphan run raises ACTION dispatch-stall' "$d_orph" 'ACTION dispatch-stall 4004 N333'

d_stale="$(STUB_PR_ROWS="$d_pr_rows" d_tick "4005\\t$d_wf\\tfix/himmel-111-mac\\t2222222222222222222222222222222222222222\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
contains 'a run whose head is no longer the PR head is flagged stale-head' "$d_stale" 'dispatch=4005:N61:5/120m:1/9@2222222:stale-head'
not_contains 'a stale head alone raises no ACTION dispatch-stall' "$d_stale" 'ACTION dispatch-stall'

d_other="$(d_tick "4006\\t$d_wf\\trelease/other\\t$d_head\\t$(d_iso 300)\\n" "9\\t1\\t$(d_iso 60)\\n")"
not_contains 'a run on a branch no worker or PR owns is not listed' "$d_other" 'dispatch='

d_cap="$(TICK_DISPATCH_MAX=1 STUB_PR_ROWS="$d_pr_rows" d_tick "4010\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 300)\\n4011\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 6150)\\n" "9\\t3\\t$(d_iso 300)\\n")"
contains 'under the per-tick cap the oldest run is read first, so a hung run is never crowded out by newer ones' "$d_cap" 'dispatch=4011:'
not_contains 'under the per-tick cap a newer run does not take the slot of an older one' "$d_cap" '4010:'

d_none="$(d_tick '' '')"
not_contains 'no in-flight run leaves dispatch= out of the compact line' "$d_none" 'dispatch='
d_down="$(STUB_DISPATCH_RC=1 d_tick '' '')"
contains 'an unreadable runs list reads dispatch=?' "$d_down" 'dispatch=?'
d_verbose="$(STUB_PR_ROWS="$d_pr_rows" WORKERS='HIMMEL-111-legN61' STUB_DISPATCH_RUNS="4002\\t$d_wf\\tfix/himmel-111-mac\\t$d_head\\t$(d_iso 1470)\\n" STUB_DISPATCH_JOBS="9\\t1\\t$(d_iso 120)\\n" bash "$SUT" --verbose 2>/dev/null)"
contains 'verbose labels dispatch' "$d_verbose" 'dispatch: 4002:N61:24/120m:1/9@1111111'

# focus= and sdrift= come from the focus-state file beside the chief doc. The gh and jira
# stubs log any call made under focus-refresh.sh, so the two fields provably read no network.
f_dir="$W/focus6829"
f_calls="$W/focus6829-calls.txt"
mkdir -p "$f_dir" "$W/bin-focus6829"
for f_tool in gh jira; do
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # the stub body expands at its own run time
        printf 'p=$PPID; while [ "${p:-0}" -gt 1 ]; do\n'
        # shellcheck disable=SC2016
        printf '  case "$(tr "\\0" " " < /proc/$p/cmdline 2>/dev/null)" in *focus-refresh.sh*) echo "%s $*" >> %q ;; esac\n' "$f_tool" "$f_calls"
        # shellcheck disable=SC2016
        printf '  p=$(sed -n "s/^PPid:[[:space:]]*//p" /proc/$p/status 2>/dev/null)\n'
        printf 'done\n'
        if [ "$f_tool" = gh ]; then printf 'exec %q "$@"\n' "$W/bin/gh"; else printf 'exit 1\n'; fi
    } > "$W/bin-focus6829/$f_tool"
    chmod +x "$W/bin-focus6829/$f_tool"
done
f_doc() { printf '%s\n' '# chief' ${1:+"focus-version: $1"} '' '## Results (newest at the bottom)' > "$f_dir/chief.md"; }
f_state() { printf 'status=%s\nstage=%s\ngen=3\ndirty=\nsha8=0a1b2c3d\nsdrift=%s\n%sts=1\n' "$1" "$2" "$3" "${4:+stale=$4$'\n'}" > "$f_dir/focus-state"; }
f_tick() { PATH="$W/bin-focus6829:$PATH" bash "$SUT" --doc "$f_dir/chief.md" "$@" 2>/dev/null; }
# positive control: a gh call under a script named focus-refresh.sh is logged
: > "$f_calls"
printf '#!/usr/bin/env bash\ngh probe\n' > "$W/bin-focus6829/focus-refresh.sh"
PATH="$W/bin-focus6829:$PATH" bash "$W/bin-focus6829/focus-refresh.sh" >/dev/null 2>&1
f_probe="$(cat "$f_calls")"
: > "$f_calls"
f_doc v1.0.1
f_state FAILED drift 2:abcd1234
f_out="$(f_tick)"
contains 'a FAILED:drift focus state puts focus=FAILED:drift on the compact line' "$f_out" ' focus=FAILED:drift'
contains 'a drift line in the focus state puts sdrift= on the compact line' "$f_out" ' sdrift=2:abcd1234'
f_state ok '' 0:0f0f0f0f
f_out="$(f_tick)"
not_contains 'a healthy focus state leaves focus= off the compact line' "$f_out" ' focus='
not_contains 'a zero drift line leaves sdrift= off the compact line' "$f_out" ' sdrift='
f_out="$(f_tick --verbose)"
contains '--verbose shows a healthy focus state' "$f_out" 'focus: ok'
contains '--verbose shows a zero drift line' "$f_out" 'sdrift: 0:0f0f0f0f'
f_state FAILED drift 2:abcd1234 1:HIMMEL-11
f_out="$(f_tick)"
contains 'a stale line in the focus state puts stale= after sdrift= on the compact line' "$f_out" ' sdrift=2:abcd1234 stale=1:HIMMEL-11'
f_state ok '' 0:0f0f0f0f 0:
f_out="$(f_tick)"
not_contains 'stale=0: leaves stale= off the compact line' "$f_out" ' stale='
f_out="$(f_tick --verbose)"
contains '--verbose shows a zero stale line' "$f_out" $'\nstale: 0:'
f_state ok '' 0:0f0f0f0f partial:2:HIMMEL-11,HIMMEL-12
f_out="$(f_tick)"
contains 'a partial stale line is printed' "$f_out" ' stale=partial:2:HIMMEL-11,HIMMEL-12'
f_state ok '' 0:0f0f0f0f unknown
f_out="$(f_tick)"
contains 'an unknown stale line is printed' "$f_out" ' stale=unknown'
f_state ok '' 0:0f0f0f0f 11:HIMMEL-1,HIMMEL-2,HIMMEL-3,HIMMEL-4,HIMMEL-5,HIMMEL-6,HIMMEL-7,HIMMEL-8,+3
f_out="$(f_tick)"
contains 'eleven keys print as the state wrote them' "$f_out" ' stale=11:HIMMEL-1,HIMMEL-2,HIMMEL-3,HIMMEL-4,HIMMEL-5,HIMMEL-6,HIMMEL-7,HIMMEL-8,+3'
f_state ok '' 0:0f0f0f0f
f_out="$(f_tick)"
not_contains 'a focus state with no stale= line leaves stale= off the compact line' "$f_out" ' stale='
f_out="$(f_tick --verbose)"
not_contains 'and off the verbose lines' "$f_out" $'\nstale:'
f_doc ''
f_state FAILED drift 2:abcd1234 1:HIMMEL-11
f_out="$(f_tick --verbose)"
not_contains 'a doc with no focus-version: line shows no focus' "$f_out" 'focus:'
not_contains 'a doc with no focus-version: line shows no sdrift' "$f_out" 'sdrift:'
not_contains 'a doc with no focus-version: line shows no stale' "$f_out" $'\nstale:'
f_doc v1.0.1
rm -f "$f_dir/focus-state"
f_out="$(f_tick)"
not_contains 'no focus-state file leaves focus= off the line' "$f_out" ' focus='
not_contains 'no focus-state file leaves sdrift= off the line' "$f_out" ' sdrift='
not_contains 'no focus-state file leaves stale= off the line' "$f_out" ' stale='
f_drift() {
    local n
    : > "$f_dir/focus-drift.txt"
    for n in "$@"; do
        printf 'UNOWNED HIMMEL-%s In Progress with no open PR and no live owner; a date never makes it wait: awaiting chief since=2026-11-20 due=2026-12-31 what=x source=hold | writer=chief | fix=dispatch\n' "$n" >> "$f_dir/focus-drift.txt"
    done
    printf 'sdrift=%s:abcd1234\n' "$#" >> "$f_dir/focus-drift.txt"
}
f_age() { touch -d "$2" "$f_dir/$1"; }
f_seven='HIMMEL-901,HIMMEL-902,HIMMEL-903,HIMMEL-904,HIMMEL-905,HIMMEL-906,HIMMEL-907'
f_doc v1.0.1
f_state ok '' 0:0f0f0f0f 0:
f_drift 901 902 903 904 905 906 907
f_age focus-state '10 minutes ago'
f_out="$(f_tick)"
contains 'seven ownerless started tickets with a future due date: stale= names all seven' "$f_out" " stale=7:$f_seven"
f_state ok '' 0:0f0f0f0f 0:
f_age focus-drift.txt '10 minutes ago'
f_age focus-state 'now'
f_out="$(f_tick)"
not_contains 'a drift file older than the state line leaves the state line as it is' "$f_out" ' stale=7:'
f_state ok '' 0:0f0f0f0f 0:
f_drift 901 902 903 904 905 906
printf 'AWAITING HIMMEL-909 a release-manager ruling wait since=2026-11-20 ruling=d1 what=x source=ruling | writer=release-manager | fix=none | wait=release-manager\n' > "$f_dir/drift-extra"
{ sed '$d' "$f_dir/focus-drift.txt"; cat "$f_dir/drift-extra"; printf 'sdrift=7:abcd1234\n'; } > "$f_dir/drift-new" && mv -f "$f_dir/drift-new" "$f_dir/focus-drift.txt"
f_age focus-state '10 minutes ago'
f_out="$(f_tick)"
contains 'a started ticket a live worker holds has no row and is not named' "$f_out" ' stale=6:HIMMEL-901,HIMMEL-902,HIMMEL-903,HIMMEL-904,HIMMEL-905,HIMMEL-906'
not_contains 'a ruling wait is not a stuck started ticket' "$f_out" 'HIMMEL-909'
f_state ok '' 7:abcd1234 7:HIMMEL-901,HIMMEL-902,HIMMEL-903,HIMMEL-904,HIMMEL-905,HIMMEL-906,HIMMEL-907
f_drift
f_age focus-state '10 minutes ago'
f_out="$(f_tick)"
not_contains 'after the dispositions the drift file names none and stale= is gone' "$f_out" ' stale='
f_state ok '' 0:0f0f0f0f 0:
f_drift 901 902 903 904 905 906 907
f_age focus-drift.txt '5 hours ago'
f_age focus-state '6 hours ago'
f_out="$(f_tick)"
contains 'a drift file older than 3 h reads partial' "$f_out" " stale=partial:7:$f_seven"
rm -f "$f_dir/focus-drift.txt" "$f_dir/drift-extra"
f_state ok '' 0:0f0f0f0f 0:
f_out="$(f_tick)"
not_contains 'no drift file leaves stale= off the line' "$f_out" ' stale='
f_state ok '' 0:0f0f0f0f 3:HIMMEL-1,HIMMEL-2,HIMMEL-3
f_out="$(f_tick)"
contains 'no drift file echoes the state line as before' "$f_out" ' stale=3:HIMMEL-1,HIMMEL-2,HIMMEL-3'
if [ ! -r "/proc/$$/status" ]; then skip 'the focus fields make no gh or jira call: no /proc to walk the callers'
elif [ "$f_probe" != 'gh probe' ]; then fail "the call-log stub missed a gh call under focus-refresh.sh (got '$f_probe')"
elif [ -s "$f_calls" ]; then fail "focus-refresh.sh called gh or jira from the tick: $(tr '\n' ';' < "$f_calls")"; else pass 'the focus fields make no gh or jira call'; fi

# --- slotage=: shared suite slots held past the cap -------------
# Reads each live slot's owner record under the semaphore dir; the holder's worker, range and
# suite count come from the detail run-shell-tests.sh records. Advisory: never a wake key.
sa_dir="$W/sem5788"
sa_now="$(date +%s)"
mkdir -p "$sa_dir/slot-1" "$sa_dir/slot-2" "$sa_dir/slot-3" "$sa_dir/slot-4" "$sa_dir/slot-5"
sa_dead="$(sh -c 'echo $$')"
# shellcheck source=../../lib/proc-tree.sh
. "$HERE/../../lib/proc-tree.sh"
sa_id="$(proc_tree_process_identity "$$")"
sa_owner() { # <slot> <pid> <age-seconds> [detail] [identity]
    printf 'pid=%s\nidentity=%s\nlabel=run-shell-tests\nstarted=%s\n%s' "$2" "${5-$sa_id}" "$((sa_now - $3))" "${4:+detail=$4$'\n'}" > "$sa_dir/slot-$1/owner"
}
sa_owner 1 $$ 1500 'worker=N3912 range=aaa1111..bbb2222 suites=3'
sa_owner 2 $$ 60 'worker=N3913 range=ccc..ddd suites=9'
sa_owner 3 "$sa_dead" 9000 'worker=N3914 range=eee..fff suites=5'
sa_owner 4 $$ 1300
sa_owner 5 $$ 9000 'worker=N3915 range=ggg..hhh suites=7' 'reused-pid-other-process'
sa_tick() { HIMMEL_SUITE_SEMAPHORE_DIR="$sa_dir" bash "$SUT" "$@" 2>/dev/null; }
sa_out="$(sa_tick)"
contains 'a live slot held past the cap prints its worker, range, suite count and age' "$sa_out" ' slotage=N3912:aaa1111..bbb2222:3suites:25m'
not_contains 'a slot younger than the cap is not listed' "$sa_out" 'N3913'
not_contains 'a slot whose owner is dead is not listed' "$sa_out" 'N3914'
not_contains 'a slot whose pid now names another process is not listed' "$sa_out" 'N3915'
contains 'a slot past the cap with no detail reads ? for each part' "$sa_out" ',?:?:?suites:21m'
contains 'verbose labels slotage' "$(sa_tick --verbose)" 'slot age: N3912:aaa1111..bbb2222:3suites:25m'
contains 'HIMMEL_SUITE_SLOT_CAP lowers the cap' "$(HIMMEL_SUITE_SLOT_CAP=30 sa_tick)" 'N3913:ccc..ddd:9suites:1m'
not_contains 'a raised cap lists nothing' "$(HIMMEL_SUITE_SLOT_CAP=99999 sa_tick)" 'slotage='
not_contains 'no semaphore dir leaves slotage= off the line' "$(HIMMEL_SUITE_SEMAPHORE_DIR="$W/no-sem5788" bash "$SUT" 2>/dev/null)" 'slotage='
not_contains "slotage= is not in chief-wait's wake key" "$cw_keys" 'slotage'
sd_uid=''
sd_default=''
for _ in 1 2 3 4 5 6 7 8 9 10; do
    sd_uid=$((900000 + RANDOM))
    if mkdir "/tmp/himmel-suite-semaphore-$sd_uid.d" 2>/dev/null; then sd_default="/tmp/himmel-suite-semaphore-$sd_uid.d"; break; fi
done
sd_old="$W/sd-tmp/himmel-suite-semaphore.d"
if [ -z "$sd_default" ]; then fail 'no unclaimed fake-uid semaphore dir under /tmp after 10 tries'; exit 1; fi
trap 'rm -rf "$W" "$sd_default"' EXIT
mkdir -p "$W/sd-bin" "$sd_default/slot-1" "$sd_old/slot-1"
# shellcheck disable=SC2016  # the stub's own $1 and $@ expand when it runs, not here
printf '#!/bin/sh\nif [ "${1-}" = "-u" ]; then echo %s; else exec /usr/bin/id "$@"; fi\n' "$sd_uid" > "$W/sd-bin/id"
chmod +x "$W/sd-bin/id"
printf 'pid=%s\nidentity=%s\nlabel=run-shell-tests\nstarted=%s\ndetail=%s\n' "$$" "$sa_id" "$((sa_now - 1500))" 'worker=N10209 range=ddd..eee suites=4' > "$sd_default/slot-1/owner"
printf 'pid=%s\nidentity=%s\nlabel=run-shell-tests\nstarted=%s\ndetail=%s\n' "$$" "$sa_id" "$((sa_now - 1500))" 'worker=NOLDDIR range=old..old suites=1' > "$sd_old/slot-1/owner"
sd_out="$(env -u HIMMEL_SUITE_SEMAPHORE_DIR PATH="$W/sd-bin:$PATH" TICK_TMPDIR="$W/sd-tmp" bash "$SUT" 2>/dev/null)"
contains 'a slot past the cap in the default dir shows in slotage= whatever TMPDIR the tick runs under' "$sd_out" ' slotage=N10209:ddd..eee:4suites:25m'
not_contains 'the old TMPDIR-keyed dir is no longer read by default' "$sd_out" 'NOLDDIR'
sd_seam="$(HIMMEL_SUITE_SEMAPHORE_DIR="$sa_dir" PATH="$W/sd-bin:$PATH" TICK_TMPDIR="$W/sd-tmp" bash "$SUT" 2>/dev/null)"
contains 'HIMMEL_SUITE_SEMAPHORE_DIR set still picks that dir' "$sd_seam" ' slotage=N3912:aaa1111..bbb2222:3suites:25m'
not_contains 'HIMMEL_SUITE_SEMAPHORE_DIR set ignores the default dir' "$sd_seam" 'N10209'
not_contains 'HIMMEL_SUITE_SEMAPHORE_DIR set ignores the old TMPDIR-keyed dir' "$sd_seam" 'NOLDDIR'
rm -rf "$sd_default"
rm -rf "$sa_dir"

# --- cadence=<name>:<state>:<age>:<run id>[:RED|:SKIP|:MISSED],...: the last SCHEDULED
# run of every workflow with a schedule: trigger, read through ci-cadence.sh at most once per
# CI_CADENCE_INTERVAL_SEC and served from the cache between. cg9247 stands in for gh: it counts each
# call and answers `run list --workflow <file>` from <dir>/<file>.row (status, conclusion, createdAt, id),
# so no suite reaches GitHub. RED control (tick.sh before this change): the line never carries cadence=.
cg9247="$W/cadence9247"
mkdir -p "$cg9247"
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '%s\n' '#!/bin/sh' 'echo "$*" >> "$CG_DIR/calls"' '[ -n "$CG_FAIL" ] && exit 1' \
    'case "$1 $2" in' \
    '"run list") wf=; while [ $# -gt 0 ]; do [ "$1" = --workflow ] && wf=$2; shift; done; [ -f "$CG_DIR/$wf.row" ] && cat "$CG_DIR/$wf.row"; exit 0 ;;' \
    '"run view") printf "https://github.com/x/y/actions/runs/%s\tbuild / Run tests\n" "$3"; exit 0 ;;' \
    'esac' 'exit 0' > "$cg9247/gh"
chmod +x "$cg9247/gh"
cg_row() { # <workflow file> <status> <conclusion> <age> <id>
    printf '%s\t%s\t%s\t%s\n' "$2" "$3" "$(date -u -d "$4 ago" +%Y-%m-%dT%H:%M:%SZ)" "$5" > "$cg9247/$1.row"  # gnu-ok: Linux-only kit
}
cg_seed() {
    rm -f "$cg9247"/*.row "$cg9247/calls" "$cg9247/cache"
    cg_row ci.yml completed success '3 hours' 101
    cg_row ledger-drift.yml completed success '20 hours' 102
    cg_row fork-drift.yml completed success '5 hours' 103
    cg_row pages.yml completed success '9 hours' 104
    cg_row ci-image.yml completed success '3 days' 105
    cg_row macos-cadence.yml completed failure '2 days' 106
    cg_row snyk-weekly.yml completed failure '3 days' 107
}
cg_tick() { CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" "$@" 2>/dev/null; }
cadence_of() { sed -nE 's/.* cadence=([^ ]*).*/\1/p'; }
cg_seed
cg_line="$(cg_tick | cadence_of)"
for cg_name in ci ledger-drift fork-drift pages ci-image macos-cadence snyk-weekly; do
    contains "cadence= carries $cg_name" "$cg_line" "$cg_name:"
done
contains 'a failure run reads RED with its run id' "$cg_line" 'macos-cadence:failure:2d:106:RED'
contains 'a green run carries no flag' "$cg_line" 'ci:success:3h:101,'
contains 'verbose labels the field' "$(cg_tick --verbose)" 'ci cadence: ci:success'
# (d) a second tick inside the interval makes no gh call
cg_n="$(wc -l < "$cg9247/calls" | tr -d ' ')"
cg_tick >/dev/null
same 'a second tick inside the interval makes no gh call' "$(wc -l < "$cg9247/calls" | tr -d ' ')" "$cg_n"
same 'the first read made one call per workflow' "$cg_n" '7'
# a run older than the interval is read again
CI_CADENCE_INTERVAL_SEC=0 CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" >/dev/null 2>&1
same 'interval 0 reads again' "$(wc -l < "$cg9247/calls" | tr -d ' ')" '14'
# (c) a skipped run is flagged; a run that gated itself on purpose concludes success and is not
cg_seed; cg_row pages.yml completed skipped '4 hours' 204
contains 'a skipped scheduled run reads SKIP' "$(cg_tick | cadence_of)" 'pages:skipped:4h:204:SKIP'
cg_seed; cg_row snyk-weekly.yml completed success '3 days' 205
not_contains 'a gated run that concluded success is not flagged' "$(cg_tick | cadence_of)" 'snyk-weekly:success:3d:205:'
# no scheduled run inside 1.5 times the period reads MISSED; a running run flags nothing
cg_seed; cg_row fork-drift.yml completed success '40 hours' 206
contains 'a scheduled run older than 1.5 periods reads MISSED' "$(cg_tick | cadence_of)" 'fork-drift:success:40h:206:MISSED'
cg_seed; cg_row ci.yml in_progress - '50 hours' 207
not_contains 'a run still in progress is not flagged' "$(cg_tick | cadence_of)" '207:MISSED'
# (e) gh unreadable: cadence=?, the tick still answers
cg_seed
cg_bad="$(CG_FAIL=1 cg_tick)"
same 'an unreadable gh reads cadence=?' "$(printf '%s\n' "$cg_bad" | cadence_of)" '?'
contains 'a tick with gh unreadable still prints its line' "$cg_bad" 'TICK '
printf '%s\n' '#!/bin/sh' 'echo "not a run row"' > "$cg9247/gh-junk"
chmod +x "$cg9247/gh-junk"
rm -f "$cg9247/cache"
not_contains 'a gh answer that is no run row leaves cadence= off the line' "$(CG_DIR="$cg9247" CI_CADENCE_GH="$cg9247/gh-junk" CI_CADENCE_STATE="$cg9247/cache" bash "$SUT" 2>/dev/null)" 'cadence='
rm -rf "$cg9247"

# --- the station row for ledger-drift: ci-cadence.sh arm / status / run / disarm on a stub
# crontab, a stub ledger check and a stub alert sink, in a temp HOME. The crontab is written only through
# crontab_locked_rmw: two cadences armed at once on a SLOW crontab (its read sleeps) both land. RED
# control (before ci-cadence.sh has the verbs): the first arm prints a usage line and installs nothing.
sr="$W/station9247"
mkdir -p "$sr/home"
# shellcheck disable=SC2016  # the stubs' own $-expressions must stay literal
printf '#!/usr/bin/env bash\nif [ "${1:-}" = "-l" ]; then cat "$SR_TAB"; [ -z "${SR_SLOW:-}" ] || sleep 1; else cat > "$SR_TAB"; fi\n' > "$sr/crontab"  # read-sink-ok: a stub crontab written into the test sandbox, the suite names the file
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '#!/usr/bin/env bash\necho "ledger-drift ran" ; exit "${SR_RC:-0}"\n' > "$sr/ledger.sh"
# shellcheck disable=SC2016  # the stub's own $-expressions must stay literal
printf '#!/usr/bin/env bash\necho "$*" >> "$SR_ALERTS"\n' > "$sr/alert.sh"
chmod +x "$sr/crontab"
printf '0 1 * * * /other/job # HIMMEL-Other\n' > "$sr/tab"
sr_cad() { HOME="$sr/home" HIMMEL_CRONTAB_LOCK="$sr/lock" SR_TAB="$sr/tab" SR_ALERTS="$sr/alerts" CICADENCE_CRONTAB="$sr/crontab" CICADENCE_RUNNER_DIR="$sr/runner" CICADENCE_LEDGER_SCRIPT="$sr/ledger.sh" CICADENCE_ALERT="$sr/alert.sh" bash "$HERE/ci-cadence.sh" "$@"; }
sr_n() { grep -c "# $1" "$sr/tab" || true; }  # swallow-ok: grep -c prints 0 and exits 1 on no match
sr_cad arm --dry-run >/dev/null 2>&1
same 'arm --dry-run installs nothing' "$(sr_n HIMMEL-LedgerDrift)" '0'
sr_cad arm >/dev/null 2>&1
same 'arm installs one HIMMEL-LedgerDrift row' "$(sr_n HIMMEL-LedgerDrift)" '1'
same 'arm keeps the other cron line' "$(sr_n HIMMEL-Other)" '1'
contains 'the default time is 09:20' "$(cat "$sr/tab")" '20 09 * * * '
sr_cad arm >/dev/null 2>&1
same 'a second arm refuses with rc 3' "$?" '3'
contains 'status says ARMED' "$(sr_cad status 2>&1)" 'ARMED      HIMMEL-LedgerDrift'
sr_cad run >/dev/null 2>&1
same 'run on a balanced ledger exits 0' "$?" '0'
contains 'a clean run clears the alert' "$(cat "$sr/alerts")" 'clear ledger-drift'
SR_RC=1 sr_cad run >/dev/null 2>&1
same 'run on a drifted ledger exits 1' "$?" '1'
contains 'a failed run reports through cadence-alert fail' "$(cat "$sr/alerts")" 'fail ledger-drift the shard ledger check exited 1'
sr_cad disarm >/dev/null 2>&1
same 'disarm removes the row' "$(sr_n HIMMEL-LedgerDrift)" '0'
same 'disarm keeps the other cron line' "$(sr_n HIMMEL-Other)" '1'
# two cadences armed at once on a slow crontab both land (the cadence lock)
printf '#!/usr/bin/env bash\necho gen\n' > "$sr/gen.sh"
mr_env() { HOME="$sr/home" HANDOVER_DIR="$sr/ho" HIMMEL_CRONTAB_LOCK="$sr/lock" SR_TAB="$sr/tab" SR_SLOW=1 MORNINGREPORT_CRONTAB="$sr/crontab" MORNINGREPORT_RUNNER_DIR="$sr/mr-runner" MORNINGREPORT_GENERATOR="$sr/gen.sh" "$@"; }
mkdir -p "$sr/ho"
mr_env bash "$HERE/../morning-report-cadence.sh" arm >/dev/null 2>&1 &
sr_p1=$!
SR_SLOW=1 sr_cad arm >/dev/null 2>&1 &
sr_p2=$!
wait "$sr_p1" "$sr_p2"
same 'two cadences armed at once on a slow crontab both land' "$(sr_n HIMMEL-LedgerDrift)$(sr_n HIMMEL-MorningReport)$(sr_n HIMMEL-Other)" '111'
rm -rf "$sr"

# --- review=<date>:<age>:<failures>:<new>:<new 5+>:<filed>[:STALE] (decision 593): the daily failure
# review as one more scheduled row, a local read of the newest failure-review-<date>.md and its .json sidecar
# in HIMMEL_FAILURE_REVIEW_DIR. RED control (tick.sh before this change): the line never carries review=.
rv="$W/review593"
mkdir -p "$rv"
review_of() { sed -nE 's/.* review=([^ ]*).*/\1/p'; }
rv_tick() { HIMMEL_FAILURE_REVIEW_DIR="$rv" bash "$SUT" "$@" 2>/dev/null; }
rv_write() { # <date> <age as touch -d reads it> <sidecar json>
    printf '## Failure review\n' > "$rv/failure-review-$1.md"
    printf '%s\n' "$3" > "$rv/failure-review-$1.json"
    touch -d "$2 ago" "$rv/failure-review-$1.md"  # gnu-ok: Linux-only kit
}
rv_json_filed='{"totals":{"rows":100,"classes":4,"workers":9},"classes":[{"class":"denied/a","rows":7,"recurring":false},{"class":"error/b","rows":1,"recurring":false},{"class":"error/c","rows":50,"recurring":true},{"class":"traj/x","rows":9,"recurring":false}],"routing":[{"decision":"filed","class":"denied/a","ticket":"HIMMEL-9256"},{"decision":"filed","class":"error/c","ticket":"HIMMEL-9257"},{"decision":"commented","class":"x","ticket":"HIMMEL-1"},{"decision":"capped","class":"y"}]}'
rv_json_quiet='{"totals":{"rows":100,"classes":2,"workers":9},"classes":[{"class":"error/b","rows":1,"recurring":false},{"class":"error/c","rows":50,"recurring":true}],"routing":[{"decision":"commented","class":"x","ticket":"HIMMEL-1"}]}'
rv_write 2026-11-05 '2 hours' "$rv_json_filed"
same 'a fresh review reads its age, failures, new classes, big new classes and filed keys, and a sidecar with a capped routing row adds no CAPPED flag (decision 593, decision 941)' "$(rv_tick | review_of)" '2026-11-05:2h:100:2:1:HIMMEL-9256+HIMMEL-9257'
contains 'verbose labels the failure review (decision 593)' "$(rv_tick --verbose)" 'failure review: 2026-11-05:2h:100:2:1:'
rv_write 2026-11-05 '30 hours' "$rv_json_filed"
same 'a review older than 26 h reads STALE (decision 593)' "$(rv_tick | review_of)" '2026-11-05:30h:100:2:1:HIMMEL-9256+HIMMEL-9257:STALE'
rv_write 2026-11-05 '3 hours' "$rv_json_quiet"
same 'a 1-count new class files nothing and flags nothing (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:100:1:0:-'
rm -f "$rv/failure-review-2026-11-05.json"
same 'a review with no sidecar reads ? for the counts (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:?:?:?:-'
rm -f "$rv"/*
not_contains 'no review file leaves review= off the line (decision 593)' "$(rv_tick)" 'review='
rm -rf "$rv"

S2="$W/s2"; SM="$S2/mirror/HIMMEL"; mkdir -p "$SM" "$S2/quota" "$W/handover"
mk_s2() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: ["v1.1.3"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# HIMMEL-%s: t\n\n## Description\n\nbody\n' \
        "$1" "$2" "$3" "$1" > "$SM/HIMMEL-$1.md"
}
mk_s2 901 Done Done
mk_s2 902 "In Progress" "In Progress"
printf 'v1.1.3\tfalse\t\n' > "$S2/mirror/HIMMEL.versions.tsv"
cat > "$S2/ps-gh" <<'STUB'
#!/usr/bin/env bash
[ -z "${PS_GH_FAIL:-}" ] || exit 1
case "$*" in *"api graphql"*) ;; *) exit 1 ;; esac
out=""
for n in $(printf '%s\n' "$*" | grep -oE 'issueOrPullRequest\(number:[0-9]+\)' | grep -oE '[0-9]+'); do
    case "$n" in
        999001) v='{"__typename":"PullRequest","state":"CLOSED"}' ;;
        999002) v='{"__typename":"PullRequest","state":"MERGED"}' ;;
        *) v=null ;;
    esac
    out="${out:+$out,}\"p$n\":$v"
done
printf '{"data":{"repository":{%s}}}\n' "$out"
STUB
chmod +x "$S2/ps-gh"
S2ST="$S2/st-none"
s2() { env TICK_STATE_DIR="$S2ST" NEXT_DISPATCH_MIRROR="$SM" HIMMEL_QUOTA_DIR="$S2/quota" TICK_GH_CMD="$S2/ps-gh" GH_READ_OFF=1 TOKEN='' "$@"; }
s2_doc() {
    { printf '# chief\n\n## Live state\n'; cat; printf '\n## Results\n'; } > "$W/handover/$1.md"
    printf '%s' "$W/handover/$1.md"
}
s2_lines() {
    printf '%s\n' \
        'pool-disposition: HIMMEL-141 question after PR #999001 the doctor edit' \
        'pool-disposition: HIMMEL-142 question after HIMMEL-901 drafted in ZA-1' \
        'pool-disposition: HIMMEL-143 question after HIMMEL-902 the rest' \
        'pool-disposition: HIMMEL-144 question after PR #999002 shipped'
}
printf '%s\n' '# disposition HIMMEL-141 listed LOCAL' '# disposition HIMMEL-142 listed LOCAL' '# disposition HIMMEL-143 listed LOCAL' \
    '# disposition HIMMEL-144 in-flight owned by worker N1' > "$S2/rows"
s2_produce() {
    local doc="$1" out sf; shift
    s2 env "$@" bash "$SUT" --pool-holds --doc "$doc" > /dev/null 2>&1
    out="$(s2 env "$@" bash "$SUT" --pool-stale --doc "$doc" --prior "$S2ST/none.out" 2>/dev/null)"
    sf="$(printf '%s\n' "$out" | sed -n 's/^# stale-file=//p')"
    [ -n "$sf" ] || return 1
    mkdir -p "$(dirname "$sf")"
    printf '%s\n' "$out" > "$sf"
    printf '%s' "$sf"
}
s2_pd() { s2 bash "$SUT" --pool-dispositions --doc "$1" < "$S2/rows" 2>/dev/null; }
s2_tick() {
    local doc="$1" l rc; shift
    s2 env NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" TICK_POOL_WAIT=0 "$@" bash "$SUT" --doc "$doc" > /dev/null 2>&1
    rc=$?
    for l in "$S2ST"/tick-pool-*.lock; do [ ! -e "$l" ] || flock "$l" true; done
    [ "$rc" -eq 0 ] || fail "s2_tick $doc: the tick exited $rc"
    return "$rc"
}
# shellcheck disable=SC2012  # the names are the cksum producer's digits, never odd characters
s2_file() { ls "$S2ST"/tick-pool-stale-*.out 2>/dev/null | head -n 1; }
n141() { grep -c "^STALE-DISPOSITION HIMMEL-141 line=[0-9a-f]\{12\} PR#999001=CLOSED$1\$" "$2"; }

S2ST="$S2/st-r20"
s2_a="$(s2_lines | s2_doc r20-a)"
s2_produce "$s2_a" > /dev/null
r20="$(s2_pd "$s2_a")"
contains 'R20 a stale key moves from disposed to unresolved and nothing else' "$r20" '# pool-counts 4/1/2/2'
contains 'R20 the unresolved line names the class, the key and the gone targets' "$r20" '# pool-unresolved stale HIMMEL-141 its pool-disposition target is gone: PR#999001=CLOSED; re-decide or rewrite the line'
contains 'R20 a Done ticket target is stale too' "$r20" '# pool-unresolved stale HIMMEL-142 its pool-disposition target is gone: HIMMEL-901=Done; re-decide or rewrite the line'
p143='HIMMEL-143 '
same 'R21 the open-target line stays disposed' "$(printf '%s\n' "$r20" | grep '^# pool-unresolved' | grep -c "$p143")" 0
not_contains 'R21b an owned key with a stale line stays disposed' "$r20" '# pool-unresolved stale HIMMEL-144 '
same 'R21b its stale line is still in the file' "$(grep -c '^STALE-DISPOSITION HIMMEL-144 ' "$(s2_file)")" 1
same 'every saved file opens with its mirror and its own path' "$(head -n 2 "$(s2_file)")" "# mirror=$(realpath -m "$SM")
# stale-file=$(s2_file)"

S2ST="$S2/st-ctl"
same 'no stale file counts as today' "$(s2_pd "$s2_a" | sed -n 's/^# pool-counts //p')" '4/1/4/0'
S2ST="$S2/st-r20"
s2_x="$(s2_lines | sed 's/$/ again/' | s2_doc ctl-x)"
same "another doc's stale file counts as today" "$(s2_pd "$s2_x" | sed -n 's/^# pool-counts //p')" '4/1/4/0'

s2_lines | s2_doc r8 > /dev/null; S2ST="$S2/st-r8"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_tick "$W/handover/r8.md"
f8="$(s2_file)"
same 'R8 the main tick writes the stale file' "$(head -n 1 "$f8" 2>/dev/null)" "# mirror=$SM"
p8='^STALE-DISPOSITION HIMMEL-14[124] '
same 'R8 it holds the stale keys of the doc, not the owned one skipped' "$(grep -c "$p8" "$f8" 2>/dev/null)" 3
cp "$f8" "$S2/r8.good"

S2ST="$S2/st-r8"
PS_GH_FAIL=1 s2_tick "$W/handover/r8.md"
same 'R8b a failed read after a good one carries the stale line' "$(n141 ' carried' "$f8")" 1
contains 'R8b and the key stays unresolved' "$(s2_pd "$W/handover/r8.md")" '# pool-unresolved stale HIMMEL-141 its pool-disposition target is gone: PR#999001=CLOSED; re-decide or rewrite the line'
cp "$S2/r8.good" "$f8"
PS_GH_FAIL=1 s2_tick "$W/handover/r8.md"
p141='^STALE-DISPOSITION HIMMEL-141 '
same 'R8b the carried line differs from the read one only by its marker' "$(sed 's/ carried$//' "$f8" | grep "$p141")" "$(grep "$p141" "$S2/r8.good")"

s2_lines | s2_doc r8c > /dev/null; S2ST="$S2/st-r8c"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_tick "$W/handover/r8c.md"
s2_lines | sed 's/^\(pool-disposition: HIMMEL-141 question\) .*/\1 operator decision 268/' | s2_doc r8c > /dev/null
PS_GH_FAIL=1 s2_tick "$W/handover/r8c.md"
same 'R8c a rewritten line is not carried' "$(grep -c '^STALE-DISPOSITION HIMMEL-141 ' "$(s2_file)")" 0
not_contains 'R8c the rewritten key counts as disposed' "$(s2_pd "$W/handover/r8c.md")" '# pool-unresolved stale HIMMEL-141 '

s2_lines | sed 's/HIMMEL-901 drafted/HIMMEL-901 and PR #999001 drafted/' | s2_doc r8d > /dev/null; S2ST="$S2/st-r8d"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_tick "$W/handover/r8d.md"
same 'R8d 142 is stale with a key and a PR target before the failed read' "$(grep -c '^STALE-DISPOSITION HIMMEL-142 line=[0-9a-f]\{12\} HIMMEL-901=Done PR#999001=CLOSED$' "$(s2_file)")" 1
mk_s2 901 "In Progress" "In Progress"
PS_GH_FAIL=1 s2_tick "$W/handover/r8d.md"
same 'R8d a key target read open is not carried' "$(grep -c '^STALE-DISPOSITION HIMMEL-142 ' "$(s2_file)")" 0
not_contains 'R8d the key counts as disposed' "$(s2_pd "$W/handover/r8d.md")" '# pool-unresolved stale HIMMEL-142 '
mk_s2 901 Done Done

s2_lines | s2_doc r8e > /dev/null; S2ST="$S2/st-r8e"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_tick "$W/handover/r8e.md"
s2_lines | sed 's/^\(pool-disposition: HIMMEL-141 .*\)$/\1 and PR #999002/' | s2_doc r8e > /dev/null
PS_GH_FAIL=1 s2_tick "$W/handover/r8e.md"
same 'R8e an extended line is not carried' "$(grep -c '^STALE-DISPOSITION HIMMEL-141 ' "$(s2_file)")" 0

S2ST="$S2/st-r8"
cp "$S2/r8.good" "$f8"
touch -d '-6 hours' "$f8"  # gnu-ok: chief kit is Linux-only
contains 'R8f an aged file still demotes an unchanged line' "$(s2_pd "$W/handover/r8.md")" '# pool-unresolved stale HIMMEL-141 '
s2_lines | sed 's/^\(pool-disposition: HIMMEL-141 .*\)$/\1 and more/' | s2_doc r8g > /dev/null
not_contains 'R8g an aged file releases a changed line' "$(s2_pd "$W/handover/r8g.md")" '# pool-unresolved stale HIMMEL-141 '

S2ST="$S2/st-r8h"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_lines | s2_doc r8h-a > /dev/null
s2_tick "$W/handover/r8h-a.md"
s2_lines | s2_doc r8h-b > /dev/null
PS_GH_FAIL=1 s2_tick "$W/handover/r8h-b.md"
# shellcheck disable=SC2012  # the names are the cksum producer's digits, never odd characters
fb="$(ls -t "$S2ST"/tick-pool-stale-*.out | head -n 1)"
same 'R8h the successor writes a file of its own that holds the carried 141 line' "$(n141 ' carried' "${fb:-/dev/null}")" 1
contains 'R8h and its consumer counts 141 unresolved' "$(s2_pd "$W/handover/r8h-b.md")" '# pool-unresolved stale HIMMEL-141 '
s2_lines | s2_doc r8h-b2 > /dev/null
contains 'R8h cut producer: the consumer falls back to the newest same-mirror file' "$(s2_pd "$W/handover/r8h-b2.md")" '# pool-unresolved stale HIMMEL-141 '
s2_lines | s2_doc r8h-b3 > /dev/null
printf 'main\tgraphql\t10\t5000\t%s\t%s\tok\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$S2/quota/quota.tsv"
s2_pu="$(s2 bash "$SUT" --pool-stale --doc "$W/handover/r8h-b3.md" --prior "$S2ST/none.out" 2>/dev/null)"
rm -f "$S2/quota/quota.tsv"
p141c='^STALE-DISPOSITION HIMMEL-141 .* carried$'
same 'R8h quota gate: under --prior the carried 141 line survives the gate refusing' "$(printf '%s\n' "$s2_pu" | grep -c "$p141c")" 1
same 'R8h quota gate: its field still names the key and reads ?' "$(printf '%s\n' "$s2_pu" | sed -n 's/^pool-stale=//p')" '3:HIMMEL-141,HIMMEL-142,HIMMEL-144,?'
s2_lines | sed 's/^\(pool-disposition: HIMMEL-141 .*\)$/\1!/' | s2_doc r8h-c > /dev/null
PS_GH_FAIL=1 s2_tick "$W/handover/r8h-c.md"
not_contains 'R8h control: a 141 line that differs by one character carries nothing' "$(s2_pd "$W/handover/r8h-c.md")" '# pool-unresolved stale HIMMEL-141 '

G15="$S2/g15"; git init -q "$G15"; mkdir -p "$S2/notrepo"
g15() { GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" git -C "$G15" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2" && git -C "$G15" rev-parse --short HEAD; }
g15 2026-11-08T10:00:00Z 'base' > /dev/null
sub15a='[HIMMEL-902] B1 the first slice'; sub15b='[HIMMEL-902] B2 the second slice'
c15a="$(g15 2026-11-09T12:00:00Z "$sub15a")"
c15b="$(g15 2026-11-09T15:00:00Z "$sub15b")"
s3_produce() {
    local out sf
    s2 bash "$SUT" --pool-holds --doc "$1" --repo "$2" > /dev/null 2>&1
    out="$(s2 bash "$SUT" --pool-stale --doc "$1" --repo "$2" --prior "$3" 2>/dev/null)"
    sf="$(printf '%s\n' "$out" | sed -n 's/^# stale-file=//p')"
    [ -n "$sf" ] || return 1
    mkdir -p "$(dirname "$sf")"
    printf '%s\n' "$out" > "$sf"
    printf '%s' "$sf"
}
s3_lines() { s2_lines | sed 's/^\(pool-disposition: HIMMEL-143 .*\)$/\1 (ZZ 11-08)/'; }
S2ST="$S2/st-r15"; rm -rf "$S2ST"; mkdir -p "$S2ST"
d15="$(s3_lines | s2_doc HIMMEL-nextleg-2026-11-10ZZ-r15)"
f15="$(s3_produce "$d15" "$G15" "$S2ST/none.out")"
r15="$(s2_pd "$d15")"
u15="# pool-unresolved changed HIMMEL-143 HIMMEL-902 merged $c15a since the line was written: re-read and stamp (<LL> <MM-DD> <HH:MM>Z)"
contains 'R15 a changed key counts as unresolved, beside the two stale ones' "$r15" '# pool-counts 4/1/1/3'
contains 'R15 the unresolved text names the oldest merge since the anchor and the literal stamp to add' "$r15" "$u15"
p15="^CHANGED-DISPOSITION HIMMEL-143 .* via HIMMEL-902 $c15b "
same 'R15 the detail line names the newest merge' "$(grep -c "$p15" "${f15:-/dev/null}")" 1
s3_produce "$d15" "$G15" "$f15" > /dev/null
same 'R15 a second run prints the same unresolved text' "$(s2_pd "$d15" | grep '^# pool-unresolved changed ')" "$u15"
s3_produce "$d15" "$S2/notrepo" "$f15" > /dev/null
p19='^CHANGED-DISPOSITION HIMMEL-143 .* carried$'
same 'R19 a failed git read carries the changed line' "$(grep -c "$p19" "${f15:-/dev/null}")" 1
contains 'R19 and the key stays unresolved changed' "$(s2_pd "$d15")" "$u15"

S2ST="$S2/st-r15t"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s3_tick() {
    local l out
    out="$(s2 env NEXT_DISPATCH_GH_CMD="$W/ow-gh" NEXT_DISPATCH_CLASSIFY_CMD="$W/pd-classify" TICK_POOL_WAIT=0 bash "$SUT" --doc "$1" 2>/dev/null)"
    for l in "$S2ST"/tick-pool-*.lock; do [ ! -e "$l" ] || flock "$l" true; done
    printf '%s\n' "$out"
}
# shellcheck disable=SC2016  # the backticks are the doc's literal project-line markup, not a command
{ printf 'The project this console is FOR is **`%s`**.\n' "$G15"; s3_lines; } | s2_doc HIMMEL-nextleg-2026-11-10ZZ-r15t > /dev/null
contains 'R15 the compact line shows a non-zero pool-changed=' "$(s3_tick "$W/handover/HIMMEL-nextleg-2026-11-10ZZ-r15t.md")" ' pool-changed=1:HIMMEL-143'
# shellcheck disable=SC2016  # the backticks are the doc's literal project-line markup, not a command
{ printf 'The project this console is FOR is **`%s`**.\n' "$G15"; s2_lines; } | s2_doc HIMMEL-nextleg-2026-11-10ZZ-r15z > /dev/null
not_contains 'R15 the compact line hides pool-changed=0' "$(s3_tick "$W/handover/HIMMEL-nextleg-2026-11-10ZZ-r15z.md")" 'pool-changed='

cat > "$S2/ps-gh-race" <<'STUB'
#!/usr/bin/env bash
[ -z "${PS_GH_STARTED:-}" ] || : > "$PS_GH_STARTED"
sleep "${PS_GH_SLEEP:-0}"
case "$*" in *"api graphql"*) ;; *) exit 1 ;; esac
printf '{"data":{"repository":{"p999001":{"__typename":"PullRequest","state":"%s"},"p999002":{"__typename":"PullRequest","state":"MERGED"}}}}\n' "${PS_GH_STATE:-CLOSED}"
STUB
chmod +x "$S2/ps-gh-race"
S2ST="$S2/st-race"; rm -rf "$S2ST"; mkdir -p "$S2ST"
s2_lines | s2_doc race > /dev/null
s2_tick "$W/handover/race.md" TICK_GH_CMD="$S2/ps-gh-race" PS_GH_SLEEP=12 PS_GH_STATE=CLOSED PS_GH_STARTED="$S2/race-started" &
s2_race_pid=$!
for _ in $(seq 1 100); do [ ! -e "$S2/race-started" ] || break; sleep 0.2; done
same 'R22 the slow first read started before the second tick runs' "$([ -e "$S2/race-started" ] && echo yes || echo no)" yes
s2_tick "$W/handover/race.md" TICK_GH_CMD="$S2/ps-gh-race" PS_GH_STATE=OPEN
same 'R22 the later tick exits 0' "$?" 0
wait "$s2_race_pid"
same 'R22 the slower older tick exits 0' "$?" 0
same 'R22 the later run clears the verdict and the slower older run does not put it back' "$(grep -c "$p141" "$(s2_file)")" 0

PH="$W/ph"; mkdir -p "$PH/rel/v1.1.3" "$PH/state" "$PH/handover"
printf '{}\n' > "$PH/rel/v1.1.3/release.json"
PH_STEM=HIMMEL-nextleg-2026-11-15PH-roadmap-chief
ph_doc="$PH/handover/$PH_STEM.md"
ph_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ph_state() {
    jq -n --argjson w "$1" --argjson a "$2" --arg s "${3:-OK}" --arg t "${4:-$(ph_now)}" \
        '{ts: $t, status: $s, words_records: $w, asks_operator_keys: $a}' > "$PH/state/release-state-$PH_STEM.json"
}
ph_words='[{"id":"O-v1.1.3-0001","decision":"9","keys":["HIMMEL-46","HIMMEL-47","HIMMEL-48","HIMMEL-49","HIMMEL-50","HIMMEL-51","HIMMEL-53"],"op":"none","verbatim":"Approved one more round"}]'
ph_mk() { printf '%s\n' '# chief' '' '## Live state' "$@" '' '## Results' > "$ph_doc"; }
ph_env() { HIMMEL_RELEASE_STATE_DIR="$PH/rel" TICK_STATE_DIR="$PH/state" "$@"; }
ph_holds() { ph_env bash "$SUT" --pool-holds --doc "$ph_doc" 2>/dev/null; }
ph_pd() { ph_env bash "$SUT" --pool-dispositions --doc "$ph_doc" < "$PH/rows" 2>/dev/null; }
ph_file="$PH/state/pool-holds-$PH_STEM.json"
ph_class() { jq -r --arg k "HIMMEL-$1" '.rows[] | select(.key == $k) | .class' "$ph_file" 2>/dev/null; }
ph_unres() { printf '%s\n' "$1" | grep "^# pool-unresolved [a-z-]* HIMMEL-$2 "; }
for n in 4 41 42 43 44 45 46 47 48 49 50 51 52 53 54 8 55; do printf '# disposition HIMMEL-%s listed LOCAL\n' "$n"; done > "$PH/rows"
ph_mk 'release: v1.1.3' \
    'pool-disposition: HIMMEL-4 question operator decision 268' \
    'pool-disposition: HIMMEL-41 close the ticket is obsolete' \
    'pool-disposition: HIMMEL-42 hold until the release' \
    'pool-disposition: HIMMEL-43 park for now' \
    'pool-disposition: HIMMEL-44 question ask the operator' \
    'pool-disposition: HIMMEL-45 slice later' \
    'pool-disposition: HIMMEL-46 close obsolete authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-47 hold until the release authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-48 park for now authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-50 slice later authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-51 question the operator said so authority=decision-9' \
    'pool-disposition: HIMMEL-52 question operator decision 268 authority=decision-268' \
    'pool-disposition: HIMMEL-53 question a legacy row authority=O-v1.1.3-0002' \
    'pool-disposition: HIMMEL-54 slice HIMMEL-900' \
    'pool-disposition: HIMMEL-8 slice HIMMEL-900' \
    'pool-disposition: HIMMEL-77 park the operator asked for it' \
    'pool-disposition: HIMMEL-78 park not asked'
ph_state "$ph_words" '["HIMMEL-77"]'
mkdir -p "$PH/decisions"; printf 'keep it, HIMMEL-52\n' > "$PH/decisions/verbatim-decision-268.txt"
ph_out="$(ph_holds)"; ph_rc=$?
same 'the pool-holds step exits 0' "$ph_rc" 0
contains 'the pool-holds step names the unhandled lines' "$ph_out" 'pool-holds='
ph_pdo="$(ph_pd)"
contains 'a bare question line counts as unhandled' "$ph_pdo" '# pool-unresolved no-authority HIMMEL-4 '
for n in 41 42 43 44 45; do
    contains "every give-up verb needs a form: bare HIMMEL-$n is no-authority" "$ph_pdo" "# pool-unresolved no-authority HIMMEL-$n "
done
for n in 46 47 48 49 50; do
    same "every give-up verb needs a form: HIMMEL-$n with a valid authority= is handled" "$(ph_unres "$ph_pdo" "$n")" ""
done
same 'a words O- record naming the key is handled, and the holds row carries the words' \
    "$(jq -r '.rows[] | select(.key == "HIMMEL-49") | "\(.class)|\(.words)"' "$ph_file" 2>/dev/null)" 'authority|Approved one more round'
same 'decision-<n> resolves through words_records only: decision-9 names the key' "$(ph_class 51)" authority
same 'decision-<n> resolves through words_records only: a decision file on disk does not help' "$(ph_class 52)" invalid
contains 'and the invalid line is unresolved with its reason' "$ph_pdo" '# pool-unresolved invalid HIMMEL-52 authority=decision-268 names no record of the operator'"'"'s words for HIMMEL-52'
same 'a legacy O- row is not authority' "$(ph_class 53)" invalid
same 'a slice naming a key keeps today'"'"'s rule' "$(ph_unres "$ph_pdo" 54)" ''
contains 'a free-text slice needs a form' "$ph_pdo" '# pool-unresolved no-authority HIMMEL-45 '
contains 'an off-pool operator key is checked' "$ph_pdo" '# pool-unresolved no-authority HIMMEL-77 '
contains 'an off-pool key the operator did not ask for stays invalid as today' "$ph_pdo" '# pool-unresolved invalid HIMMEL-78 malformed, duplicate or unknown'
same 'chief-wait'"'"'s call reads the same file (same classes)' \
    "$(printf '%s\n' "$(cat "$PH/rows")" | ph_env env DOC='' bash "$SUT" --pool-dispositions --doc "$ph_doc" 2>/dev/null)" "$ph_pdo"
ph_series="HIMMEL-4,HIMMEL-41"
contains 'the no-doc call still prints pool-keys' \
    "$(printf 'SERIES\tser-1\t%s\n' "$ph_series" | ph_env env DOC='' bash "$SUT" --pool-dispositions 2>/dev/null)" "# pool-keys 1 SERIES $ph_series"

rm -f "$PH/state/release-state-$PH_STEM.json"; ph_holds > /dev/null
same 'missing inputs: no state file reads an authority= line unchecked' "$(ph_class 49)" unchecked
contains 'and names the missing input' "$(jq -r '.rows[] | select(.key == "HIMMEL-49") | .reason' "$ph_file")" 'no release state file'
ph_state "$ph_words" '[]' OK "$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"; ph_holds > /dev/null  # gnu-ok: chief kit is Linux-only
same 'missing inputs: a state file older than the holds window reads unchecked' "$(ph_class 49)" unchecked
ph_state "$ph_words" '[]' UNKNOWN; ph_holds > /dev/null
same 'missing inputs: a state that is not OK reads unchecked' "$(ph_class 49)" unchecked
printf '{"ts": ' > "$PH/state/release-state-$PH_STEM.json"
ph_rc=0; ph_holds > /dev/null || ph_rc=$?
same 'a corrupt state file never fails the step' "$ph_rc" 0
same 'a corrupt state file reads an authority= line unchecked' "$(ph_class 49)" unchecked

ph_state "$ph_words" '["HIMMEL-77"]'; ph_holds > /dev/null
rm -f "$ph_file"
ph_pdo="$(ph_pd)"
contains 'a missing holds file reads every give-up line unchecked' "$ph_pdo" '# pool-unresolved unchecked HIMMEL-49 no holds file'
contains 'and a bare one too, never an all-clear' "$ph_pdo" '# pool-unresolved unchecked HIMMEL-4 '
same 'a slice naming a key is not a give-up line' "$(ph_unres "$ph_pdo" 54)" ''
ph_holds > /dev/null; touch -d '31 minutes ago' "$ph_file"  # gnu-ok: chief kit is Linux-only
contains 'an old holds file reads every give-up line unchecked' "$(ph_pd)" '# pool-unresolved unchecked HIMMEL-49 the holds file is 31 min old'
ph_holds > /dev/null
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001' 'pool-disposition: HIMMEL-4 question operator decision 268 and more'
contains 'a line changed since the holds run reads unchecked' "$(ph_pd)" '# pool-unresolved unchecked HIMMEL-4 the line changed since the holds run'
ph_mk 'release: v1.1.4' 'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001' 'pool-disposition: HIMMEL-4 question operator decision 268 and more'
contains 'a holds file written for another release reads unchecked' "$(ph_pd)" '# pool-unresolved unchecked HIMMEL-49 the holds file was written for release v1.1.3'
jq '.release = "v1.1.2"' "$PH/state/release-state-$PH_STEM.json" > "$PH/state/rs.tmp" && mv "$PH/state/rs.tmp" "$PH/state/release-state-$PH_STEM.json"
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001'
ph_holds > /dev/null
same 'a release state of another release reads authority unchecked' "$(ph_class 49)" unchecked
ph_mk 'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001' 'pool-disposition: HIMMEL-4 question operator decision 268 and more'
ph_holds > /dev/null
same 'a doc with no release line in a declaring bucket reads unchecked' "$(ph_class 49)" unchecked
contains 'and says why' "$(jq -r '.rows[] | select(.key == "HIMMEL-49") | .reason' "$ph_file")" 'the doc has no release: line'
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-4 question operator decision 268'
ph_nl="$(TICK_STATE_DIR="$PH/state" bash "$SUT" --pool-holds --doc "$ph_doc" 2>/dev/null)"
same 'a bucket with no declaration keeps today'"'"'s rule: the step says so' "$ph_nl" 'pool-holds=off:no-ledger'
ph_nlo="$(TICK_STATE_DIR="$PH/state" bash "$SUT" --pool-dispositions --doc "$ph_doc" < "$PH/rows" 2>/dev/null)"
same 'a bucket with no declaration keeps today'"'"'s rule: a bare question is dispositioned' "$(ph_unres "$ph_nlo" 4)" ''
rm -f "$ph_file"
same 'with no declaration a missing holds file changes nothing' "$(ph_unres "$(TICK_STATE_DIR="$PH/state" bash "$SUT" --pool-dispositions --doc "$ph_doc" < "$PH/rows" 2>/dev/null)" 4)" ''

PHM="$PH/mirror/HIMMEL"; mkdir -p "$PHM"
printf '#!/usr/bin/env bash\nprintf "not json"\n' > "$PH/rmq-probe"; chmod +x "$PH/rmq-probe"
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-49 question one more round authority=O-v1.1.3-0001' 'pool-disposition: HIMMEL-52 question x authority=the-boss'
printf '{"ts": ' > "$PH/state/release-state-$PH_STEM.json"; rm -f "$ph_file"
ph_rc=0
ph_tick="$(ph_env env NEXT_DISPATCH_MIRROR="$PHM" TICK_RMQ_PROBE="$PH/rmq-probe" TOKEN='' bash "$SUT" --doc "$ph_doc" 2>/dev/null)" || ph_rc=$?
same 'a corrupt state file never fails the tick (rc 0)' "$ph_rc" 0
contains 'the tick still prints with invalid lines' "$ph_tick" 'TICK '
same 'the tick ran the pool-holds step: the authority= line reads unchecked' "$(ph_class 49)" unchecked
same 'and the invalid line is invalid' "$(ph_class 52)" invalid

ph_field() { jq -r --arg k "HIMMEL-$1" --arg f "$2" '.rows[] | select(.key == $k) | .[$f] | tostring' "$ph_file" 2>/dev/null; }
mk_ph() {
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "Task"\nstatus: "%s"\nstatusCategory: "%s"\npriority: "Medium"\nlabels: []\nfixVersions: %s\nparent: null\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$4" "$1" > "$PHM/HIMMEL-$1.md"
}
mk_ph 901 "To Do" "To Do" '[]'
mk_ph 902 Done Done '[]'
mk_ph 903 "To Do" "To Do" '["v1.1.3"]'
mk_ph 904 "To Do" "To Do" '[]'
printf 'v1.1.3\tfalse\t\n' > "$PH/mirror/HIMMEL.versions.tsv"
printf '4999\tfeat/other\tfalse\tme\tfalse\n5001\tfeat/himmel-904-x\tfalse\tme\tfalse\n4761\tupstream/fix\tfalse\tbob\ttrue\n' > "$PH/open-prs.tsv"
cat > "$PH/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PH_GH_LOG"
[ -z "${PH_GH_FAIL:-}" ] || exit 1
case "$*" in *"api graphql"*) ;; *) exit 1 ;; esac
out=""
for n in $(printf '%s\n' "$*" | grep -o 'issueOrPullRequest(number:[0-9]*)' | grep -o '[0-9][0-9]*'); do
    s="$(printf '%s\n' "${PH_GH_STATES:-}" | tr ',' '\n' | sed -n "s/^$n://p")"
    if [ -n "$s" ]; then out="$out${out:+,}\"p$n\":{\"__typename\":\"PullRequest\",\"state\":\"$s\"}"; else out="$out${out:+,}\"p$n\":null"; fi
done
printf '{"data":{"repository":{%s}}}\n' "$out"
STUB
chmod +x "$PH/gh"
ph_day() { date -u -d "$1" +%Y-%m-%d; }  # gnu-ok: chief kit is Linux-only
ph_wake() { ph_env env NEXT_DISPATCH_MIRROR="$PHM" TICK_GH_CMD="$PH/gh" PH_GH_LOG="$PH/gh.log" PH_GH_STATES="${PH_GH_STATES:-4999:OPEN,5001:OPEN,4761:OPEN,3905:MERGED}" \
    bash "$SUT" --pool-holds --doc "$ph_doc" --repo "$PH" "$@" 2>/dev/null; }
ph_state "$ph_words" '[]'
ph_mk 'release: v1.1.3' \
    "pool-disposition: HIMMEL-60 park until then wake=date:$(ph_day '+3 days')" \
    "pool-disposition: HIMMEL-61 park until then wake=date:$(ph_day yesterday)" \
    "pool-disposition: HIMMEL-62 park until then wake=date:$(ph_day '+30 days')" \
    'pool-disposition: HIMMEL-63 hold after it wake=done:HIMMEL-901' \
    'pool-disposition: HIMMEL-64 hold after it wake=done:HIMMEL-904' \
    'pool-disposition: HIMMEL-65 hold after it wake=done:HIMMEL-902' \
    'pool-disposition: HIMMEL-66 hold after it wake=done:HIMMEL-903' \
    'pool-disposition: HIMMEL-67 hold for a file wake=file:relative/x' \
    'pool-disposition: HIMMEL-68 hold for a file wake=file:/etc/x' \
    "pool-disposition: HIMMEL-69 hold for a file wake=file:$PH/state/../x" \
    "pool-disposition: HIMMEL-70 hold for a file wake=file:$PH/state/flag-not-yet" \
    'pool-disposition: HIMMEL-71 hold on the merge wake=pr-4999-merge' \
    'pool-disposition: HIMMEL-72 hold on the merge wake=pr:777' \
    "pool-disposition: HIMMEL-46 close obsolete authority=O-v1.1.3-0001 wake=date:$(ph_day '+30 days')" \
    "pool-disposition: HIMMEL-73 park for now authority=bogus wake=date:$(ph_day '+3 days')" \
    'pool-disposition: HIMMEL-74 hold waits on PR 4761 wake=pr:4761' \
    'pool-disposition: HIMMEL-75 park soon wake=sometime'
: > "$PH/gh.log"
ph_wake --open-prs "$PH/open-prs.tsv" > /dev/null
same 'a valid unfired dated wake is handled' "$(ph_class 60)" wake
same 'a fired wake does not hold' "$(ph_class 61)|$(ph_field 61 fired)" 'no-authority|true'
same 'a wake more than 7 days out is a park' "$(ph_class 62)" invalid
contains 'and says so' "$(ph_field 62 reason)" 'more than 7 days'
same 'done: on a backlog To Do key with no PR and no worker is invalid' "$(ph_class 63)" invalid
same 'done: on a key an open PR'"'"'s head branch names is handled' "$(ph_class 64)" wake
same 'done: on a Done key is fired, never invalid' "$(ph_class 65)|$(ph_field 65 fired)" 'no-authority|true'
same 'done: on a key in the current version is handled' "$(ph_class 66)" wake
same 'file: with a relative path is invalid' "$(ph_class 67)" invalid
same 'file: outside the handover root and the state dir is invalid' "$(ph_class 68)" invalid
same 'file: with a .. segment is invalid' "$(ph_class 69)" invalid
same 'file: under the state dir that does not exist yet is handled' "$(ph_class 70)" wake
same 'wake=pr-<n>-merge on an open PR is handled' "$(ph_class 71)" wake
same 'wake=pr:<n> GitHub cannot resolve on a successful read is invalid' "$(ph_class 72)|$(ph_field 72 reason)" 'invalid|PR 777 not found'
same 'an invalid part wins: a valid authority beside an invalid wake' "$(ph_class 46)" invalid
same 'an invalid part wins: an invalid authority beside a valid wake' "$(ph_class 73)" invalid
same 'an unknown wake form is invalid' "$(ph_class 75)" invalid
same 'the PR read names exactly the cited PRs in one call' "$(grep -c 'api graphql' "$PH/gh.log")" 1
same 'the holds file carries the PR state map' "$(jq -r '.prs | to_entries | map("\(.key)=\(.value)") | join(",")' "$ph_file")" '4761=OPEN,4999=OPEN'
same 'outside from the real read: a cross-repository PR with no manifest reads null' "$(ph_field 74 outside)" null
printf '{"schema":1,"workers":[]}\n' > "$PH/manifest.json"
ph_wake --open-prs "$PH/open-prs.tsv" --workers-from "$PH/manifest.json" > /dev/null
same 'outside from the real read: a cross-repository PR with no watch row is outside' "$(ph_field 74 outside)" true
printf '{"schema":1,"workers":[],"watch":[{"pr":4761,"repo":""}]}\n' > "$PH/manifest.json"
ph_wake --open-prs "$PH/open-prs.tsv" --workers-from "$PH/manifest.json" > /dev/null
same 'outside from the real read: a watch row makes it a live wake' "$(ph_field 74 outside)" false
ph_wake --open-prs "$PH/open-prs.tsv" --workers 'HIMMEL-901-N1-x-2026-11-15.md' > /dev/null
same 'done: on a key a --workers worker holds is handled' "$(ph_class 63)" wake
printf '{"schema":1,"workers":[{"doc":"HIMMEL-901-N1-x-2026-11-15.md"}]}\n' > "$PH/manifest.json"
ph_wake --open-prs "$PH/open-prs.tsv" --workers-from "$PH/manifest.json" > /dev/null
same 'done: on a key a worker holds is handled' "$(ph_class 63)" wake
ph_rc=0; PH_GH_FAIL=1 ph_wake --open-prs "$PH/open-prs.tsv" > /dev/null || ph_rc=$?
same 'a failed PR read never fails the step' "$ph_rc" 0
same 'a failed PR read is unchecked, neither invalid nor fired' "$(ph_class 71)|$(ph_field 71 fired)" 'unchecked|false'
same 'and a not-found PR is unchecked too' "$(ph_class 72)" unchecked
ph_wake > /dev/null
same 'an unread open-PR list leaves done: worked test unchecked' "$(ph_class 63)" unchecked
same 'but done: in the current version still holds' "$(ph_class 66)" wake
ph_mk 'release: v1.1.3' "pool-disposition: HIMMEL-60 park until then wake=date:$(ph_day '+3 days')" 'pool-disposition: HIMMEL-63 hold after it wake=done:HIMMEL-903'
: > "$PH/gh.log"
ph_wake --open-prs "$PH/open-prs.tsv" > /dev/null
same 'no PR target, no gh call' "$(wc -l < "$PH/gh.log" | tr -d ' ')" 0
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-71 hold on the merge wake=pr-4999-merge'
printf '#!/usr/bin/env bash\nexit 1\n' > "$PH/gh-fail"; chmod +x "$PH/gh-fail"
ph_state "$ph_words" '[]'; rm -f "$ph_file"
ph_rc=0
ph_tick="$(ph_env env NEXT_DISPATCH_MIRROR="$PHM" TICK_GH_CMD="$PH/gh-fail" GH_READ_BIN="$PH/gh-fail" TOKEN='' bash "$SUT" --doc "$ph_doc" 2>/dev/null)" || ph_rc=$?
same 'a failing gh never fails the tick (rc 0)' "$ph_rc" 0
contains 'and the tick still prints' "$ph_tick" 'TICK '
same 'and the PR-dependent line reads unchecked' "$(ph_class 71)" unchecked
mk_ph 90 "To Do" "To Do" '[]'
ph_mk 'release: v1.1.3' 'pool-disposition: HIMMEL-76 hold after it wake=done:HIMMEL-90'
ph_wake --open-prs "$PH/open-prs.tsv" > /dev/null
same 'done: never matches a longer key in a head branch' "$(ph_class 76)" invalid
ph_state "$ph_words" '[]'
: > "$PH/state/flag-present"
ph_mk 'release: v1.1.3' \
    'pool-disposition: HIMMEL-79 question not in the record authority=O-v1.1.3-0001' \
    'pool-disposition: HIMMEL-83 question not in the record authority=decision-9' \
    'pool-disposition: HIMMEL-56 hold on the merge wake=pr:3905' \
    'pool-disposition: HIMMEL-57 hold on the close wake=pr:3906' \
    "pool-disposition: HIMMEL-58 hold for a file wake=file:$PH/state/flag-present"
PH_GH_STATES=3905:MERGED,3906:CLOSED ph_wake --open-prs "$PH/open-prs.tsv" > /dev/null
same 'a real O- record that does not name the key is not authority' "$(ph_class 79)" invalid
same 'a real decision-<n> record that does not name the key is not authority' "$(ph_class 83)" invalid
same 'a wake on a merged PR fired and holds nothing' "$(ph_class 56)|$(ph_field 56 fired)" 'no-authority|true'
same 'a wake on a closed PR fired and holds nothing' "$(ph_class 57)|$(ph_field 57 fired)" 'no-authority|true'
same 'a file: wake on a file that exists fired and holds nothing' "$(ph_class 58)|$(ph_field 58 fired)" 'no-authority|true'
rm -f "$PH/state/pool-lines.tsv"; mkdir "$PH/state/pool-lines.tsv"
ph_rc=0
ph_env env NEXT_DISPATCH_MIRROR="$PHM" TICK_GH_CMD="$PH/gh-fail" TOKEN='' bash "$SUT" --doc "$ph_doc" > /dev/null 2>&1 || ph_rc=$?
same 'a failed pool-holds step still leaves the tick at rc 0' "$ph_rc" 0
same 'and removes the previous holds file, so the lines read unchecked' "$([ -e "$ph_file" ] && echo kept || echo gone)" gone
rmdir "$PH/state/pool-lines.tsv"

PA="$PH/age"; mkdir -p "$PA/docs"
pa_line='pool-disposition: HIMMEL-80 park for now'
pa_doc() {
    local s="$1"; shift
    printf '%s\n' '# chief' '' 'release: v1.1.3' '' '## Live state' "$@" 'pool-disposition: HIMMEL-81 park the other one' '' '## Results' > "$PA/docs/$s.md"
    printf '%s' "$PA/docs/$s.md"
}
pa_run() {
    local st="$1" now="$2" s="$3"; shift 3
    HIMMEL_RELEASE_STATE_DIR="$PH/rel" TICK_STATE_DIR="$st" TICK_NOW="$now" bash "$SUT" --pool-holds --doc "$(pa_doc "$s" "$@")" > /dev/null 2>&1
}
pa_age() { jq -r --arg f "$3" '.rows[] | select(.key == "HIMMEL-80") | .[$f] | tostring' "$1/pool-holds-$2.json" 2>/dev/null; }
pa_n=HIMMEL-nextleg-2026-11-0
st="$PA/s-seed"; mkdir -p "$st"
for s in 1SA 2SB 3SC; do pa_doc "${pa_n}${s}-roadmap-chief" "$pa_line" > /dev/null; done
printf '%s\n' "$PA/docs/${pa_n}1SA-roadmap-chief.md" "$PA/docs/${pa_n}2SB-roadmap-chief.md" "$PA/docs/${pa_n}3SC-roadmap-chief.md" > "$PA/seed.list"
TICK_STATE_DIR="$st" TICK_NOW=2026-11-05T12:00:00Z bash "$SUT" --pool-holds --seed-age "$PA/seed.list" > /dev/null 2>&1
same 'the seed mode appends one row per doc and writes no holds file' "$(wc -l < "$st/pool-lines.tsv" | tr -d ' '):$(find "$st" -name 'pool-holds-*.json' | wc -l | tr -d ' ')" '3:0'
same 'a seeded row is stamped with the doc'"'"'s filename date' "$(head -n 1 "$st/pool-lines.tsv" | cut -f1)" '2026-11-01T00:00:00Z'
pa_run "$st" 2026-11-05T12:00:00Z "${pa_n}3SC-roadmap-chief" "$pa_line"
same 'seeding three stems in order gives age_gen 3' "$(pa_age "$st" "${pa_n}3SC-roadmap-chief" age_gen)" 3
same 'and age_days follows the filename dates' "$(pa_age "$st" "${pa_n}3SC-roadmap-chief" age_days)" 4
same 'and first_seen is the first stem'"'"'s date' "$(pa_age "$st" "${pa_n}3SC-roadmap-chief" first_seen)" '2026-11-01T00:00:00Z'
st="$PA/s-seq"; mkdir -p "$st"
pa_run "$st" 2026-11-05T10:00:00Z "${pa_n}1AA-roadmap-chief" "$pa_line"
same 'a first generation is age_gen 1' "$(pa_age "$st" "${pa_n}1AA-roadmap-chief" age_gen)" 1
pa_run "$st" 2026-11-05T11:00:00Z "${pa_n}1AB-roadmap-chief" "$pa_line"
same 'the next stem of the lineage with the same line gives age_gen 2' "$(pa_age "$st" "${pa_n}1AB-roadmap-chief" age_gen)" 2
pa_run "$st" 2026-11-05T11:30:00Z "${pa_n}1AB-roadmap-chief" "$pa_line"
same 'the same stem again stays at 2' "$(pa_age "$st" "${pa_n}1AB-roadmap-chief" age_gen)" 2
same 'an unchanged line set appends no row' "$(grep -c "${pa_n}1AB" "$st/pool-lines.tsv")" 1
pa_run "$st" 2026-11-05T12:00:00Z "${pa_n}1ZZ-chief"
pa_run "$st" 2026-11-05T12:30:00Z "${pa_n}1AC-roadmap-chief" "$pa_line"
same 'a stem of another lineage without the line never resets' "$(pa_age "$st" "${pa_n}1AC-roadmap-chief" age_gen)" 3
pa_run "$st" 2026-11-05T13:00:00Z "${pa_n}1AD-roadmap-chief"
pa_run "$st" 2026-11-05T14:00:00Z "${pa_n}1AE-roadmap-chief" "$pa_line"
same 'a stem of the lineage without the line resets the age to 1' "$(pa_age "$st" "${pa_n}1AE-roadmap-chief" age_gen)" 1
st="$PA/s-days"; mkdir -p "$st"
pa_doc HIMMEL-nextleg-2026-10-28CA-roadmap-chief "$pa_line" > /dev/null
pa_doc HIMMEL-nextleg-2026-10-01OLD-roadmap-chief "$pa_line" > /dev/null
printf '%s\n' "$PA/docs/HIMMEL-nextleg-2026-10-01OLD-roadmap-chief.md" "$PA/docs/HIMMEL-nextleg-2026-10-28CA-roadmap-chief.md" > "$PA/seed2.list"
TICK_STATE_DIR="$st" TICK_NOW=2026-11-05T00:00:00Z bash "$SUT" --pool-holds --seed-age "$PA/seed2.list" > /dev/null 2>&1
pa_run "$st" 2026-11-05T00:00:00Z HIMMEL-nextleg-2026-11-05CB-roadmap-chief "$pa_line"
same 'age_days from a seeded first-seen 8 days back is 8' "$(pa_age "$st" HIMMEL-nextleg-2026-11-05CB-roadmap-chief age_days)" 8
same 'a stem unseen for 14 days is pruned' "$(grep -c 'OLD-roadmap-chief' "$st/pool-lines.tsv")" 0
st="$PA/s-long"; mkdir -p "$st"
pa_run "$st" 2026-11-01T00:00:00Z "${pa_n}1LA-roadmap-chief" "$pa_line"
pa_run "$st" 2026-11-10T00:00:00Z "${pa_n}1LA-roadmap-chief" "$pa_line"
pa_run "$st" 2026-11-20T00:00:00Z "${pa_n}1LB-roadmap-chief" "$pa_line"
same 'a stem seen unchanged for over 14 days is never pruned while it is read' "$(pa_age "$st" "${pa_n}1LB-roadmap-chief" age_gen)" 2

GD="$PA/golden"; mkdir -p "$GD/state" "$GD/docs"
gd_l1='pool-disposition: HIMMEL-1 question one more round authority=O-v1.1.3-0001'
gd_l2='pool-disposition: HIMMEL-2 park operator words: hold it'
gd_l3='pool-disposition: HIMMEL-3 hold on the merge wake=pr:4999'
gd_l4='pool-disposition: HIMMEL-4 hold on the other merge wake=pr:4998'
gd_l5='pool-disposition: HIMMEL-5 park until then wake=date:2026-11-18'
gd_doc() { printf '%s\n' '# chief' '' 'release: v1.1.3' '' '## Live state' "${@:2}" '' '## Results' > "$GD/docs/HIMMEL-nextleg-$1-roadmap-chief.md"; }
gd_doc 2026-11-08GA "$gd_l2" "$gd_l3"
gd_doc 2026-11-09GB "$gd_l2" "$gd_l3" "$gd_l4"
gd_doc 2026-11-15GD "$gd_l1" "$gd_l2" "$gd_l3" "$gd_l4" "$gd_l5"
printf '%s\n' "$GD/docs/HIMMEL-nextleg-2026-11-08GA-roadmap-chief.md" "$GD/docs/HIMMEL-nextleg-2026-11-09GB-roadmap-chief.md" > "$GD/seed.list"
TICK_STATE_DIR="$GD/state" TICK_NOW=2026-11-15T12:00:00Z bash "$SUT" --pool-holds --seed-age "$GD/seed.list" > /dev/null 2>&1
jq -n '{ts: "2026-11-15T12:00:00Z", status: "OK", words_records: [{id: "O-v1.1.3-0001", decision: "9", keys: ["HIMMEL-1"], op: "none", verbatim: "Approved one more round"}], asks_operator_keys: []}' \
    > "$GD/state/release-state-HIMMEL-nextleg-2026-11-15GD-roadmap-chief.json"
printf '4999\tfeat/a\tfalse\tme\tfalse\n4998\tfeat/b\tfalse\tme\tfalse\n' > "$GD/open.tsv"
HIMMEL_RELEASE_STATE_DIR="$PH/rel" TICK_STATE_DIR="$GD/state" TICK_NOW=2026-11-15T12:00:00Z NEXT_DISPATCH_MIRROR="$PHM" TICK_GH_CMD="$PH/gh" PH_GH_LOG="$PH/gh.log" \
    PH_GH_STATES=4999:OPEN,4998:OPEN bash "$SUT" --pool-holds --doc "$GD/docs/HIMMEL-nextleg-2026-11-15GD-roadmap-chief.md" --open-prs "$GD/open.tsv" > /dev/null 2>&1
same 'golden holds file: the producer output equals fixtures/pool-holds-golden.json' \
    "$(jq -S 'del(.doc)' "$GD/state/pool-holds-HIMMEL-nextleg-2026-11-15GD-roadmap-chief.json" 2>/dev/null)" "$(jq -S 'del(.doc)' "$HERE/fixtures/pool-holds-golden.json" 2>/dev/null)"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-fields-late.sh'
    exit 0
fi
printf 'FAIL - test-tick-fields-late.sh (%s failure(s))\n' "$fails"
exit 1
