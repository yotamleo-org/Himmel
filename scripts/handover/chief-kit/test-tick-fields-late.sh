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
contains '--verbose labels orphans-wip' "$(NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" bash "$SUT" --verbose 2>/dev/null)" 'orphans-wip: 6'

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
owc_tick() { TICK_POOL_WAIT=0 TICK_STATE_DIR="$W/owc" NEXT_DISPATCH_MIRROR="$OW" NEXT_DISPATCH_GH_CMD="$W/ow-gh" bash "$SUT" 2>/dev/null; }
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
printf '#!/usr/bin/env bash\nenv NEXT_DISPATCH_MIRROR=%q NEXT_DISPATCH_GH_CMD=%q TOKEN= bash %q --doc %q\nrc=$?\necho x >> %q\nexit $rc\n' "$OW" "$W/ow-gh" "$SUT" "$pc_doc" "$wt_dir/ticks" > "$wt_dir/stub/tick.sh"
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
cw_keys="$(grep -m1 'for f in workers livestate' "$HERE/chief-wait.sh")"
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
f_state() { printf 'status=%s\nstage=%s\ngen=3\ndirty=\nsha8=0a1b2c3d\nsdrift=%s\nts=1\n' "$1" "$2" "$3" > "$f_dir/focus-state"; }
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
f_doc ''
f_state FAILED drift 2:abcd1234
f_out="$(f_tick --verbose)"
not_contains 'a doc with no focus-version: line shows no focus' "$f_out" 'focus:'
not_contains 'a doc with no focus-version: line shows no sdrift' "$f_out" 'sdrift:'
f_doc v1.0.1
rm -f "$f_dir/focus-state"
f_out="$(f_tick)"
not_contains 'no focus-state file leaves focus= off the line' "$f_out" ' focus='
not_contains 'no focus-state file leaves sdrift= off the line' "$f_out" ' sdrift='
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

# --- review=<date>:<age>:<failures>:<new>:<new 5+>:<filed>[:CAPPED][:STALE] (decision 593): the daily failure
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
same 'a fresh review reads its age, failures, new classes, big new classes, filed keys and the cap (decision 593)' "$(rv_tick | review_of)" '2026-11-05:2h:100:2:1:HIMMEL-9256+HIMMEL-9257:CAPPED'
contains 'verbose labels the failure review (decision 593)' "$(rv_tick --verbose)" 'failure review: 2026-11-05:2h:100:2:1:'
rv_write 2026-11-05 '30 hours' "$rv_json_filed"
same 'a review older than 26 h reads STALE (decision 593)' "$(rv_tick | review_of)" '2026-11-05:30h:100:2:1:HIMMEL-9256+HIMMEL-9257:CAPPED:STALE'
rv_write 2026-11-05 '3 hours' "$rv_json_quiet"
same 'a 1-count new class files nothing and flags nothing (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:100:1:0:-'
rm -f "$rv/failure-review-2026-11-05.json"
same 'a review with no sidecar reads ? for the counts (decision 593)' "$(rv_tick | review_of)" '2026-11-05:3h:?:?:?:-'
rm -f "$rv"/*
not_contains 'no review file leaves review= off the line (decision 593)' "$(rv_tick)" 'review='
rm -rf "$rv"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick-fields-late.sh'
    exit 0
fi
printf 'FAIL - test-tick-fields-late.sh (%s failure(s))\n' "$fails"
exit 1
