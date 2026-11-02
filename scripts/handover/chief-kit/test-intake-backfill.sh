#!/usr/bin/env bash
# test-intake-backfill.sh: intake-backfill.sh proposes a version for every open ticket with no fixVersion, from its
# labels, priority, status and sector, and files nothing. Fixture: a small mirror and its versions file.
#
# Run: bash scripts/handover/chief-kit/test-intake-backfill.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/intake-backfill.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }
has() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in: $2)" ;; esac; }
lacks() { case "$2" in *"$3"*) fail "$1 (found '$3' in: $2)" ;; *) pass "$1" ;; esac; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/intake-backfill-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
M="$WORK/mirror/HIMMEL"; mkdir -p "$M"
mk() { # <num> <type> <status category> <priority> <labels json> <fixVersions json> <sector>
    printf -- '---\nkey: "HIMMEL-%s"\ntype: "%s"\nstatus: "x"\nstatusCategory: "%s"\npriority: "%s"\nlabels: %s\nfixVersions: %s\nparent: null\nsector: "%s"\n---\n\n# HIMMEL-%s: t\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$1" > "$M/HIMMEL-$1.md"
}
printf 'v0.9\ttrue\t2026-01-01\tfalse\nv1.0.1\tfalse\t\tfalse\nv1.2.0\tfalse\t\tfalse\nv1.3.0\tfalse\t\ttrue\nzz-throwaway\tfalse\t\tfalse\n' > "$WORK/mirror/HIMMEL.versions.tsv"
mk 701 Task "To Do" Medium '["operator-directed"]' '[]' "Ship loop"
mk 702 Bug "To Do" High '[]' '[]' "Ship loop"
mk 703 Task "To Do" Low '["scope-v1.2.0","backlog"]' '[]' "Billing"
mk 704 Task "In Progress" Low '[]' '[]' "Billing"
mk 705 Task "To Do" Medium '["backlog","residual-depth-1"]' '[]' "Ship loop"
mk 706 Task "To Do" High '["standalone"]' '[]' "Active sector"
mk 707 Task "To Do" Medium '[]' '["v1.0.1"]' "Active sector"
mk 715 Task "To Do" Medium '["standalone"]' '[]' "Active sector"
mk 708 Task "To Do" Medium '["standalone"]' '[]' "Quiet sector"
mk 709 Task "To Do" Medium '["operator-directed","proposed-v1.0.1"]' '[]' "Ship loop"
mk 710 Task "Done" Medium '["operator-directed"]' '[]' "Ship loop"
mk 711 Sub-task "To Do" Medium '["operator-directed"]' '[]' "Ship loop"
mk 712 Task "To Do" Medium '["operator-directed"]' '["v1.2.0"]' "Ship loop"
mk 713 Task "To Do" Medium '["operator-directed","scope-v0.9"]' '[]' "Ship loop"
mk 714 Task "To Do" Medium '["scope-v1.3.0"]' '[]' "Quiet sector"
before="$(cat "$M"/*.md | cksum)"  # cksum is POSIX; md5sum is absent on stock macOS
[ -n "$before" ] || fail "the mirror digest could not be taken"

out="$(bash "$SUT" --mirror "$M" 2>&1)"; rc=$?
check "the dry run exits 0" "0" "$rc"
has "an operator-directed ticket is proposed to the current version" "$out" "$(printf 'HIMMEL-701\tv1.0.1\toperator-directed')"
has "a High Bug is proposed to the current version" "$out" "$(printf 'HIMMEL-702\tv1.0.1\thigh-bug')"
has "a scope-<open version> label wins, even over the backlog label" "$out" "$(printf 'HIMMEL-703\tv1.2.0\tscope-label')"
has "an In Progress ticket is proposed to the current version" "$out" "$(printf 'HIMMEL-704\tv1.0.1\tin-progress')"
has "a residual-depth backlog ticket is proposed to the backlog" "$out" "$(printf 'HIMMEL-705\tbacklog\tlow-label')"
has "a High ticket in a sector with work in the current version is proposed to it" "$out" "$(printf 'HIMMEL-706\tv1.0.1\tsector-active')"
has "a Medium ticket in an active sector has no signal and is proposed to the backlog" "$out" "$(printf 'HIMMEL-715\tbacklog\tno-signal')"
has "a plain ticket in a quiet sector is proposed to the backlog" "$out" "$(printf 'HIMMEL-708\tbacklog\tno-signal')"
has "a scope label for a released version does not place the ticket there" "$out" "$(printf 'HIMMEL-713\tv1.0.1\toperator-directed')"
has "a scope label for an archived version does not place the ticket there" "$out" "$(printf 'HIMMEL-714\tbacklog\tno-signal')"
has "a proposed label is not proof that an INTAKE was queued" "$out" "$(printf 'HIMMEL-709\tv1.0.1\tproposed-label')"
lacks "a Done ticket is skipped" "$out" "HIMMEL-710"
lacks "a Sub-task is skipped" "$out" "HIMMEL-711"
lacks "a ticket already in a version is skipped" "$(printf '%s\n' "$out" | grep -v '^#')" "HIMMEL-712"
has "the total and the skipped proposals are counted" "$out" "# counts total=11 already-proposed-skipped=0 current=v1.0.1"
has "the counts by proposed version" "$out" "# counts by proposed: backlog=4 v1.0.1=6 v1.2.0=1"
has "the counts by basis" "$out" "# counts by basis: high-bug=1 in-progress=1 low-label=1 no-signal=3 operator-directed=2 proposed-label=1 scope-label=1 sector-active=1"
lacks "without --commands no command is printed" "$out" "jira release request"
check "the dry run writes nothing to the mirror" "$before" "$(cat "$M"/*.md | cksum)"

rc=0; cmds="$(bash "$SUT" --mirror "$M" --commands --release R-fixture 2>&1)" || rc=$?
check "--commands exits 0" "0" "$rc"
has "--commands prints the label command" "$cmds" "jira edit HIMMEL-701 --add-labels proposed-v1.0.1"
has "--commands prints the INTAKE request for the proposed version" "$cmds" 'jira release request R-fixture --verb INTAKE --key HIMMEL-703 --to v1.2.0 --why "backfill: scope-label"'
has "--commands prints a backlog proposal too" "$cmds" "jira edit HIMMEL-708 --add-labels proposed-backlog"

rc=0; bash "$SUT" --bogus >/dev/null 2>&1 || rc=$?
check "an unknown flag exits 2" "2" "$rc"
rc=0; bash "$SUT" --mirror "$WORK/none" >/dev/null 2>&1 || rc=$?
check "a missing mirror exits 1" "1" "$rc"
empty="$WORK/empty/HIMMEL"; mkdir -p "$empty"
rc=0; nover="$(bash "$SUT" --mirror "$empty" 2>&1)" || rc=$?
check "a mirror with no versions file exits 1 rather than proposing everything to the backlog" "1" "$rc"
has "and says the versions file could not be read" "$nover" "intake-backfill: cannot read"
: > "$WORK/empty/HIMMEL.versions.tsv"
has "an empty mirror with a versions file counts zero" "$(bash "$SUT" --mirror "$empty" 2>&1)" "# counts total=0 already-proposed-skipped=0 current=none"

# a version name with a space is shell-quoted in the commands
sp="$WORK/sp/HIMMEL"; mkdir -p "$sp"; M_SAVE="$M"; M="$sp"
mk 801 Task "To Do" Medium '["operator-directed"]' '[]' "Ship loop"
M="$M_SAVE"
printf 'v1.2 beta\tfalse\t\tfalse\n' > "$WORK/sp/HIMMEL.versions.tsv"
spc="$(bash "$SUT" --mirror "$sp" --commands --release R-fixture 2>&1)"
has "a version name with a space is quoted in the label command" "$spc" "jira edit HIMMEL-801 --add-labels 'proposed-v1.2 beta'"
has "a version name with a space is quoted in the INTAKE request" "$spc" "jira release request R-fixture --verb INTAKE --key HIMMEL-801 --to 'v1.2 beta'"

# a ticket file that cannot be read fails the run instead of dropping out of the plan
ur="$WORK/ur/HIMMEL"; mkdir -p "$ur"; cp "$sp"/*.md "$ur"/; cp "$WORK/sp/HIMMEL.versions.tsv" "$WORK/ur/HIMMEL.versions.tsv"
ln -s "$WORK/ur/gone" "$ur/HIMMEL-802.md"
rc=0; urout="$(bash "$SUT" --mirror "$ur" 2>&1)" || rc=$?
check "an unreadable ticket file exits 1 rather than yielding a short plan" "1" "$rc"
has "and names the file" "$urout" "intake-backfill: cannot read"

# a ticket whose labels cannot be parsed fails the run too
printf -- '---\nkey: "HIMMEL-803"\ntype: "Task"\nstatusCategory: "To Do"\nlabels: [broken\nfixVersions: []\n---\n' > "$ur/HIMMEL-803.md"
rm -f "$ur/HIMMEL-802.md"
rc=0; bash "$SUT" --mirror "$ur" >/dev/null 2>&1 || rc=$?
check "a ticket with unparseable labels exits 1 rather than dropping out of the plan" "1" "$rc"

# with no open version there is no release to file into, so --commands refuses instead of printing a placeholder
nov="$WORK/nov/HIMMEL"; mkdir -p "$nov"; cp "$sp"/*.md "$nov"/
printf 'v0.9\ttrue\t2026-01-01\tfalse\n' > "$WORK/nov/HIMMEL.versions.tsv"
rc=0; novout="$(bash "$SUT" --mirror "$nov" --commands --release R-fixture 2>&1)" || rc=$?
check "--commands with no open version exits 1" "1" "$rc"
lacks "and prints no <release> placeholder command" "$novout" "<release>"
check "the plan alone still works with no open version" "0" "$(bash "$SUT" --mirror "$nov" >/dev/null 2>&1; echo $?)"

# a versions row with a missing or non-boolean released/archived column fails the run instead of reading as open
bad="$WORK/bad/HIMMEL"; mkdir -p "$bad"; cp "$sp"/*.md "$bad"/
printf 'v1.0.1\tgarbage\t\tfalse\n' > "$WORK/bad/HIMMEL.versions.tsv"
rc=0; badout="$(bash "$SUT" --mirror "$bad" --commands --release R-fixture 2>&1)" || rc=$?
check "a versions row with a non-boolean released column exits 1" "1" "$rc"
has "and names the malformed row" "$badout" "malformed"
printf 'v1.0.1\tfalse\t\tmaybe\n' > "$WORK/bad/HIMMEL.versions.tsv"
rc=0; bash "$SUT" --mirror "$bad" >/dev/null 2>&1 || rc=$?
check "a versions row with a non-boolean archived column exits 1" "1" "$rc"
printf 'v1.0.1\n' > "$WORK/bad/HIMMEL.versions.tsv"
rc=0; bash "$SUT" --mirror "$bad" >/dev/null 2>&1 || rc=$?
check "a versions row with too few columns exits 1" "1" "$rc"

# Never guess that the first open version is the declared release identifier.
rc=0; missing_release="$(bash "$SUT" --mirror "$M" --commands 2>&1)" || rc=$?
check "commands require the chief's explicit declared release" "1" "$rc"
lacks "no requests are printed without a release" "$missing_release" "jira release request"
# 41 proposed INTAKE candidates plus 61 residuals: all get a reason, at most 20 per command batch.
bulk="$WORK/bulk/HIMMEL"; mkdir -p "$bulk"; M="$bulk"
printf 'v1.0.1\tfalse\t\tfalse\n' > "$WORK/bulk/HIMMEL.versions.tsv"
for n in $(seq 1 102); do
    if [ "$n" -le 41 ]; then labels='["proposed-v1.0.1"]'; else labels='["residual-depth-1"]'; fi
    mk "$((900 + n))" Task "To Do" Medium "$labels" '[]' "Ship loop"
done
all="$(bash "$SUT" --mirror "$bulk")"
has "all 102 unplaced keys remain candidates" "$all" '# counts total=102'
b1="$(bash "$SUT" --mirror "$bulk" --commands --release R-fixture --batch 1)"
b6="$(bash "$SUT" --mirror "$bulk" --commands --release R-fixture --batch 6)"
check "first batch prints only 20 requests" "20" "$(printf '%s\n' "$b1" | grep -c '^jira release request ')"
check "last batch prints the remaining two" "2" "$(printf '%s\n' "$b6" | grep -c '^jira release request ')"
has "proposed-only key gets a reasoned request" "$b1" 'HIMMEL-901 --to v1.0.1 --why "backfill: proposed-label"'
has "residual gets a reasoned backlog request" "$b6" 'HIMMEL-1002 --to backlog --why "backfill: low-label"'
lacks "batches never bypass RM admission" "$b1$b6" '--chief-override'

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
