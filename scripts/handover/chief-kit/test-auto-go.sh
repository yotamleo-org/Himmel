#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-ready-go.sh
# scripts/handover/chief-kit/test-auto-go.sh - suite for auto-go.sh, slice A1a of
# the scripted GO: the GO checks a chief repeats at a READY, run as a dry run. One row
# per promise:
#   1. usage: bad pr / sha / missing --doc --fleet --worker / no --dry-run / --repo -> exit 2.
#   2. a chief-spawned worker or a relay -> exit 3 before anything is read or written.
#   3. a clean READY: `WOULD-GO <pr> <head>`, one auto-go.jsonl row, no GO file.
#   4. one negative row per check 1-4 and 6-8: `ESCALATE auto-go <n>` exit 10, an
#      escalate audit row naming the check, no GO file. Check 5 (the judge) is slice
#      A1b: here a trust-path hit already escalates at 5, so a dry run never predicts a
#      GO the chief would not give.
#   5. check 7 runs chain-plan-core.sh --go-check only when --graph lists the PR.
#   6. the first failing check is the refusal; the audit trail appends one row per run.
#   7. auto-go.sh reads no flag, is a trust path, and never writes a GO file.
#
# Platform guard: POSIX bash 3.2+, jq.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${AUTO_GO_UNDER_TEST:-$HERE/auto-go.sh}"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME GH_CMD 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/auto-go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export HANDOVER_DIR="$tmp/root"; mkdir -p "$HANDOVER_DIR"
export USER_SLUG=u

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { printf '%s' "$2" | grep -qF -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
lacks()    { printf '%s' "$2" | grep -qF -e "$3"; case $? in
                1) echo "ok - $1" ;;
                0) echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)) ;;
                *) echo "FAIL - $1: grep errored"; fails=$((fails+1)) ;;
            esac; }

# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"

# A fixture anchor: a git repo whose origin is a local bare repo at the same commit,
# carrying the real go-gate.sh and the two allowlists check 1 reads.
ANCHOR="$tmp/anchor"
git init -q --bare "$tmp/origin.git"
git init -q "$ANCHOR"
mkdir -p "$ANCHOR/scripts/lib" "$ANCHOR/scripts/guardrails"
cp "$HERE/../../lib/go-gate.sh" "$ANCHOR/scripts/lib/go-gate.sh"
printf '[]\n' > "$ANCHOR/scripts/guardrails/himmel-adapters.json"
printf '[]\n' > "$ANCHOR/scripts/guardrails/himmel-adopted.json"
git -C "$ANCHOR" add -A
git -C "$ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ANCHOR" remote add origin "$tmp/origin.git"
git -C "$ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
export READY_GO_ANCHOR="$ANCHOR" READY_CHECK_ANCHOR="$ANCHOR" AUTO_GO_ANCHOR="$ANCHOR"
AUDIT="$HANDOVER_DIR/u/anchor/auto-go.jsonl"

# gh in front of the ready-pass one: the queries auto-go.sh and ready-go.sh add. Everything
# else falls through to the ready-pass stub, so ready-check still sees a green PR.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "repo view --json nameWithOwner"*) [ "${STUB_NWO_FAIL:-0}" = 1 ] && exit 1; printf '%s\n' "${STUB_NWO:-o/r}"; exit 0 ;;
    "repo view --json defaultBranchRef"*) printf 'main\n'; exit 0 ;;
    "pr view "*"--json state,headRefOid,baseRefName"*)
        [ "${STUB_VIEW_FAIL:-0}" = 1 ] && exit 1
        printf '{"state":"%s","headRefOid":"%s","baseRefName":"%s"}\n' \
            "${STUB_PR_STATE:-OPEN}" "${STUB_PR_HEAD:-$READY_STUB_HEAD}" "${STUB_PR_BASE:-main}"; exit 0 ;;
    "pr view "*"--json headRefOid,state"*) cat "$STUB_GC/head-$3.json" 2>/dev/null || exit 1; exit 0 ;;  # read-sink-ok: the stub reads its own fixture dir
    "pr view "*"--json title"*) printf '%s\n' "${STUB_TITLE:-fix(x): [HIMMEL-1] t (#1)}"; exit 0 ;;
    *"contents/scripts/ci/ci-trust-paths.txt"*) printf '^scripts/ci/\n'; exit 0 ;;
    "api repos/"*"/pulls/"*"/commits"*)
        [ "${STUB_COMMITS_FAIL:-0}" = 1 ] && exit 1
        printf '%s\n' "${STUB_COMMIT_MSG:-fix(x): [HIMMEL-1] t}"; exit 0 ;;
    "api repos/"*"/pulls/"*"/files --paginate"*) printf '%s\t\n' "${STUB_FILE:-scripts/x.sh}"; exit 0 ;;
    *"pulls/"*"changed_files"*) printf '%s|1\n' "$READY_STUB_HEAD"; exit 0 ;;
esac
self=$(cd "$(dirname "$0")" && pwd)
IFS=:
for d in $PATH; do
    [ "$d" = "$self" ] && continue
    [ -x "$d/gh" ] && exec "$d/gh" "$@"
done
exit 1
STUB
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$tmp/ready-bin:$PATH"

# a jira stub: `get <key>` prints the CLI's first line, then the Labels: line when STUB_LABELS_<KEY> is set
cat > "$tmp/jira" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_JIRA_FAIL:-0}" = 1 ] && exit 1
[ "$1" = get ] || exit 2
printf '%s\tTask\t%s\tsummary\n' "$2" "${STUB_JIRA_STATUS:-In Review}"
v="STUB_LABELS_${2//-/_}"
[ -z "${!v:-}" ] || printf 'Labels: %s\n' "${!v}"
exit 0
STUB
chmod +x "$tmp/jira"
export JIRA_CMD="$tmp/jira"

# chain-plan-core.sh --go-check reads its own seams: a jira stub (links/get), a push check, gh from PATH
mkdir -p "$tmp/gc"
cat > "$tmp/cpjira" <<'STUB'
#!/usr/bin/env bash
f="$STUB_GC/$1-$2.txt"
[ -f "$f" ] || exit 1
cat "$f"  # read-sink-ok: the stub reads its own fixture dir
exit 0
STUB
chmod +x "$tmp/cpjira"
export STUB_GC="$tmp/gc" CHAIN_PLAN_JIRA_CMD="$tmp/cpjira"

READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }
LEDGER="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"

SHA=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
export READY_STUB_HEAD="$SHA" READY_STUB_BRANCH=b
ready_pass_ledger "$READY_REPO" "$SHA" "$SHA2"
cp "$LEDGER" "$tmp/ledger.base"

CHIEF="$tmp/chief.md"
WORKER="$tmp/HIMMEL-1-N1-feature-2026-10-31.md"
FLEET="$tmp/chief.fleet.json"
# write_fixtures <lane> [<merge-hold line under ## Live state>] [<extra worker doc line>]
write_fixtures() {
    {
        printf '# chief\n\n## Live state\n\nlegs: N1:tok:lock:1\n'
        [ -z "${2:-}" ] || printf '%s\n' "$2"
        printf 'queue: none\n\n## Results\n'
    } > "$CHIEF"
    printf '# worker\n\n> **Completes ticket:** no\n%s\n' "${3:-}" > "$WORKER"
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"%s","added":"2026-10-31T00:00:00Z"}]}\n' "$WORKER" "${1:-native}" > "$FLEET"
}
reset() {
    unset STUB_NWO STUB_NWO_FAIL STUB_VIEW_FAIL STUB_PR_STATE STUB_PR_HEAD STUB_PR_BASE STUB_TITLE STUB_FILE STUB_COMMIT_MSG \
          STUB_COMMITS_FAIL STUB_JIRA_FAIL STUB_LABELS_HIMMEL_1 STUB_LABELS_HIMMEL_2 2>/dev/null || true
    export READY_STUB_HEAD="$SHA"
    cp "$tmp/ledger.base" "$LEDGER"
    printf '[]\n' > "$ANCHOR/scripts/guardrails/himmel-adapters.json"
    printf '[]\n' > "$ANCHOR/scripts/guardrails/himmel-adopted.json"
    write_fixtures native
}
reset

run()    { OUT=$(bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 "$@" 2>&1); RC=$?; }
rawrun() { OUT=$(bash "$SCRIPT" "$@" 2>&1); RC=$?; }
audit_rows() { if [ -f "$AUDIT" ]; then wc -l < "$AUDIT" | tr -d ' '; else echo 0; fi; }
last_row()   { tail -n 1 "$AUDIT" 2>/dev/null; }
nogo()       { check "$1: no GO file written" "$(find "$HANDOVER_DIR" -path '*/.locks*' -type f 2>/dev/null | wc -l | tr -d ' ')" "0"; }
# esc <label> <check#> - exit 10, the ESCALATE line, an escalate audit row naming the check, no GO file
esc() {
    check    "$1: exit 10" "$RC" "10"
    contains "$1: ESCALATE auto-go $2" "$OUT" "ESCALATE auto-go $2 "
    lacks    "$1: no WOULD-GO" "$OUT" "WOULD-GO"
    check    "$1: audit outcome escalate" "$(last_row | jq -r .outcome)" "escalate"
    check    "$1: audit names the failed check" "$(last_row | jq -r '[.checks[] | select(.result == "fail")][0].n')" "$2"
    nogo     "$1"
}

# --- 1. usage ------------------------------------------------------------------------
for args in "" "--dry-run 77" "--dry-run x1 $SHA" "--dry-run 077 $SHA" "--dry-run 77 ${SHA%?}" "--dry-run 77 ${SHA}0" \
            "--dry-run 77 0123456789ABCDEF0123456789abcdef01234567" "--dry-run --repo o/r 77 $SHA" "--bogus --dry-run 77 $SHA"; do
    # shellcheck disable=SC2086  # word-splitting the args string IS the point
    rawrun --doc "$CHIEF" --fleet "$FLEET" --worker N1 $args
    check "usage: [$args] -> exit 2" "$RC" "2"
done
rawrun --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA";  check "usage: no --doc -> exit 2" "$RC" "2"
rawrun --doc "$CHIEF" --worker N1 --dry-run 77 "$SHA";    check "usage: no --fleet -> exit 2" "$RC" "2"
rawrun --doc "$CHIEF" --fleet "$FLEET" --dry-run 77 "$SHA"; check "usage: no --worker -> exit 2" "$RC" "2"
run 77 "$SHA"
check    "usage: no --dry-run -> exit 2 (the real GO is slice A1b)" "$RC" "2"
contains "usage: no --dry-run says why" "$OUT" "--dry-run"
check    "usage errors write no audit row" "$(audit_rows)" "0"

# --- 2. a worker or a relay never reaches the checks ---------------------------------------
HIMMEL_CONSOLE_RELAY=1 run --dry-run 77 "$SHA"
check "relay: exit 3" "$RC" "3"
HIMMEL_CONSOLE_LEG=1 run --dry-run 77 "$SHA"
check "chief-spawned worker: exit 3" "$RC" "3"
check "exit 3 writes no audit row" "$(audit_rows)" "0"
nogo  "exit 3"

# --- 2b. a shared library that cannot be loaded is exit 1, never a run without it ---------
# a copy of auto-go.sh beside go-gate.sh and handover-path.sh but no git-clean.sh: the env
# scrub is missing, and a run on without it would read the caller's GIT_DIR
LIBTREE="$tmp/nolib"
mkdir -p "$LIBTREE/scripts/handover/chief-kit" "$LIBTREE/scripts/lib"
cp "$SCRIPT" "$LIBTREE/scripts/handover/chief-kit/auto-go.sh"
cp "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$LIBTREE/scripts/lib/"
OUT=$(bash "$LIBTREE/scripts/handover/chief-kit/auto-go.sh" --doc "$CHIEF" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA" 2>&1); RC=$?
check    "no git-clean.sh: exit 1" "$RC" "1"
contains "no git-clean.sh: names the library" "$OUT" "scripts/lib/git-clean.sh"
lacks    "no git-clean.sh: no answer given" "$OUT" "WOULD-GO"
check    "no git-clean.sh: writes no audit row" "$(audit_rows)" "0"

# --- 3. a clean READY -------------------------------------------------------------------
run --dry-run 77 "$SHA"
check    "clean: exit 0" "$RC" "0"
check    "clean: exactly WOULD-GO <pr> <head>" "$OUT" "WOULD-GO 77 $SHA"
check    "clean: one audit row" "$(audit_rows)" "1"
check    "clean: row pr/head/worker" "$(last_row | jq -r '[.pr, .head, .worker] | join(" ")')" "77 $SHA N1"
check    "clean: row outcome would-go" "$(last_row | jq -r .outcome)" "would-go"
check    "clean: checks 1-4 and 6-8 pass, in order" "$(last_row | jq -r '[.checks[] | select(.result != "not-built" and .result != "no-graph") | .n] | join(",")')" "1,2,3,4,6,8"
check    "clean: check 5 is recorded as not built" "$(last_row | jq -r '.checks[] | select(.n == 5) | .result')" "not-built"
check    "clean: no --graph is check7=no-graph" "$(last_row | jq -r '.checks[] | select(.n == 7) | .result')" "no-graph"
check    "clean: no GO written, so no qid, delta, go_file or bus" "$(last_row | jq -r '[.qid, .delta, .go_file, .bus] | map(tostring) | join(",")')" "null,null,null,null"
nogo     "clean"
run --dry-run 77 "$SHA"
check    "a second run appends a second row" "$(audit_rows)" "2"

# --- 4/1. check 1: a lane the chief merges for -----------------------------------------
write_fixtures claudex;  run --dry-run 77 "$SHA";  esc "check 1 claudex worker" 1
write_fixtures unknown;  run --dry-run 77 "$SHA";  esc "check 1 lane unknown (never guessed native)" 1
write_fixtures native;   rawrun --doc "$CHIEF" --fleet "$FLEET" --worker N9 --dry-run 77 "$SHA"
check "check 1 worker not in the manifest: exit 10" "$RC" "10"
contains "check 1 worker not in the manifest: ESCALATE auto-go 1" "$OUT" "ESCALATE auto-go 1 "
reset
printf '[{"nwo":"o/r","merge_allowed":true,"himmel_branch":"x"}]\n' > "$ANCHOR/scripts/guardrails/himmel-adapters.json"
run --dry-run 77 "$SHA";  esc "check 1 adapter repo" 1
reset
printf '[{"nwo":"O/R","merge_allowed":false}]\n' > "$ANCHOR/scripts/guardrails/himmel-adopted.json"
run --dry-run 77 "$SHA";  esc "check 1 adopted repo (case-insensitive, merge_allowed irrelevant)" 1
reset
printf 'not json\n' > "$ANCHOR/scripts/guardrails/himmel-adopted.json"
run --dry-run 77 "$SHA";  esc "check 1 unreadable allowlist" 1
reset
rm -f "$ANCHOR/scripts/guardrails/himmel-adapters.json"
run --dry-run 77 "$SHA";  esc "check 1 a missing allowlist file (eligibility cannot be shown)" 1
reset
rm -f "$ANCHOR/scripts/guardrails/himmel-adopted.json"
run --dry-run 77 "$SHA";  esc "check 1 a missing adopted allowlist file" 1
reset
STUB_NWO=other/repo run --dry-run 77 "$SHA"
check "check 1 a repo outside the allowlists passes" "$RC" "0"
reset; STUB_NWO_FAIL=1 run --dry-run 77 "$SHA";  esc "check 1 gh cannot name the repo" 1
mkdir -p "$tmp/briefdir"
reset; rawrun --doc "$CHIEF" --fleet "$tmp/briefdir" --worker N1 --dry-run 77 "$SHA";  esc "check 1 a fleet manifest that is a directory" 1
reset

# --- 4/2. check 2: the live head ---------------------------------------------------------------
STUB_PR_STATE=CLOSED run --dry-run 77 "$SHA";  esc "check 2 PR not open" 2
reset; STUB_PR_HEAD=$SHA2 run --dry-run 77 "$SHA";  esc "check 2 head moved" 2
reset; STUB_PR_BASE=feat/parent run --dry-run 77 "$SHA";  esc "check 2 base is not the default branch" 2
reset; STUB_VIEW_FAIL=1 run --dry-run 77 "$SHA";  esc "check 2 unreadable gh" 2
reset

# --- 4/3. check 3: ready-check through ready-go ---------------------------------------------------
# no CR-ledger row at the head: ready-check FAILs, so ready-go exits 4
git -C "$READY_REPO" rev-parse --git-common-dir >/dev/null
THIRD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STUB_PR_HEAD=$THIRD READY_STUB_HEAD=$THIRD run --dry-run 77 "$THIRD";  esc "check 3 ready-check FAIL (no CR-ledger row)" 3
contains "check 3 names the failing line" "$OUT" "[FAIL] 4."
reset

# --- 4/4. check 4: holds ---------------------------------------------------------------------------
STUB_LABELS_HIMMEL_1="ui, held" run --dry-run 77 "$SHA";  esc "check 4 held label" 4
for lab in operator-gated operator-decision operator operator-present; do
    reset; STUB_LABELS_HIMMEL_1="$lab" run --dry-run 77 "$SHA";  esc "check 4 label $lab" 4
done
reset; STUB_TITLE='fix(x): [HIMMEL-1][HIMMEL-2] t (#1)' STUB_LABELS_HIMMEL_2=held run --dry-run 77 "$SHA";  esc "check 4 a second key in the title is held" 4
reset; STUB_LABELS_HIMMEL_1="ui, needs-docs" run --dry-run 77 "$SHA"
check "check 4 an unrelated label passes" "$RC" "0"
reset; STUB_JIRA_FAIL=1 run --dry-run 77 "$SHA";  esc "check 4 unreadable Jira (never a pass)" 4
reset; STUB_TITLE='fix(x): no key here' run --dry-run 77 "$SHA";  esc "check 4 a title with no ticket key is unreadable" 4
for hold in 'merge-hold: #77' 'merge-hold: 77' 'merge-hold: HIMMEL-1' 'merge-hold: all' 'merge-hold: #12, #77'; do
    reset; write_fixtures native "$hold"; run --dry-run 77 "$SHA";  esc "check 4 [$hold]" 4
done
reset; write_fixtures native 'merge-hold: #99 HIMMEL-9'; run --dry-run 77 "$SHA"
check "check 4 a merge-hold naming another PR and key passes" "$RC" "0"
reset; write_fixtures native 'merge-hold: none'; run --dry-run 77 "$SHA"
check "check 4 merge-hold: none passes" "$RC" "0"
reset; printf 'merge-hold: all\n' >> "$CHIEF"; run --dry-run 77 "$SHA"
check "check 4 a merge-hold line outside ## Live state is not read" "$RC" "0"
reset; write_fixtures native "" '> **Merge:** chief'; run --dry-run 77 "$SHA";  esc "check 4 brief says Merge: chief" 4
# a brief that is readable by test -r but that grep cannot read (a directory) is a read error, not "no hold"
reset; mkdir -p "$tmp/briefdir"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"native","added":"2026-10-31T00:00:00Z"}]}\n' "$tmp/briefdir" > "$FLEET"
run --dry-run 77 "$SHA";  esc "check 4 a brief that grep cannot read" 4
# the chief doc is read by awk, and GNU awk skips a directory operand with rc 0: test -r alone read that as "no merge-hold"
reset; rawrun --doc "$tmp/briefdir" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA";  esc "check 4 a chief doc that is a directory" 4
reset; rawrun --doc "$tmp/no-such-chief.md" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA";  esc "check 4 a missing chief doc" 4
reset

# --- 4/5. check 5 is slice A1b; a trust-path hit already escalates here -----------------------------------
STUB_FILE=scripts/ci/x.sh run --dry-run 77 "$SHA";  esc "check 5 trust-path hit (judge check is slice A1b)" 5
contains "check 5 names the path" "$OUT" "scripts/ci/x.sh"
reset

# --- 4/6. check 6: residual dispositions ---------------------------------------------------------------
LA="$HERE/../../cr/ledger-append.sh"
FHEAD=1080d424a81d7cb754e1abd312fa3d87467863b7
dout=$(CR_LEDGER="$LEDGER" bash "$LA" finding --branch b --head "$FHEAD" --model gpt-6.1-sol --id census-reset-1 \
    --severity imp --file scripts/x.sh --line 23 --verdict deferred \
    --reason "Pre-existing defect outside the approved scope; a follow-up is linked but not dispositioned" \
    --deferred-to HIMMEL-6352 --fu-class hardening --fu-why no-check --text "an Important finding the worker deferred itself" 2>&1) \
    || { echo "FAIL: fixture finding was not written: $dout" >&2; exit 1; }
run --dry-run 77 "$SHA";  esc "check 6 deferred Important with no disposition" 6
reset

# --- 4/8. check 8: not a fix-for-red, not a release cut ------------------------------------------------------
STUB_FILE=VERSION run --dry-run 77 "$SHA";  esc "check 8 changes the root VERSION file" 8
reset; STUB_FILE=plugins/x/VERSION run --dry-run 77 "$SHA"
check "check 8 a nested VERSION file is not a release cut" "$RC" "0"
reset; STUB_COMMIT_MSG=$'fix(x): [HIMMEL-1] t\n\nFixes-main-red: run=123' run --dry-run 77 "$SHA";  esc "check 8 declared fix for a red main" 8
reset; STUB_COMMITS_FAIL=1 run --dry-run 77 "$SHA";  esc "check 8 unreadable commit list" 8
# the first failing check is the refusal
reset; STUB_FILE=VERSION STUB_LABELS_HIMMEL_1=held run --dry-run 77 "$SHA";  esc "order: held label and VERSION escalate at 4, not 8" 4
reset

# --- 5. check 7: the chain plan ---------------------------------------------------------------------------------
NOW() { date -u +%Y-%m-%dT%H:%M:%SZ; }
graph_with()    { printf '{"generated_at":"%s","jira_links":"ok","nodes":[{"id":"#77","pr":77,"key":"HIMMEL-1","head":"%s"}],"edges":[]}\n' "$(NOW)" "$SHA" > "$tmp/graph.json"; }
graph_without() { printf '{"generated_at":"%s","jira_links":"ok","nodes":[{"id":"#12","pr":12,"key":"HIMMEL-3","head":"x"}],"edges":[]}\n' "$(NOW)" > "$tmp/graph.json"; }
printf '{"headRefOid":"%s","state":"OPEN"}\n' "$SHA" > "$tmp/gc/head-77.json"
: > "$tmp/gc/links-HIMMEL-1.txt"
graph_with
run --graph "$tmp/graph.json" --dry-run 77 "$SHA"
check    "check 7 a graph listing the PR, go-check OK: exit 0" "$RC" "0"
check    "check 7 go-check OK is a pass" "$(last_row | jq -r '.checks[] | select(.n == 7) | .result')" "pass"
graph_without
run --graph "$tmp/graph.json" --dry-run 77 "$SHA"
check    "check 7 a graph that does not list the PR: exit 0" "$RC" "0"
check    "check 7 not listed is check7=not-in-plan" "$(last_row | jq -r '.checks[] | select(.n == 7) | .result')" "not-in-plan"
printf 'not json\n' > "$tmp/graph.json"
run --graph "$tmp/graph.json" --dry-run 77 "$SHA";  esc "check 7 unreadable graph" 7
run --graph "$tmp/no-such-graph.json" --dry-run 77 "$SHA";  esc "check 7 missing graph file" 7
run --graph "$tmp/briefdir" --dry-run 77 "$SHA";  esc "check 7 a chain graph that is a directory" 7
graph_with
printf '{"headRefOid":"%s","state":"OPEN"}\n' "$SHA2" > "$tmp/gc/head-77.json"
run --graph "$tmp/graph.json" --dry-run 77 "$SHA";  esc "check 7 go-check REFUSE (the graph is stale against the live head)" 7
printf '{"headRefOid":"%s","state":"OPEN"}\n' "$SHA" > "$tmp/gc/head-77.json"
printf '{"generated_at":"%s","jira_links":"unreadable","nodes":[{"id":"#77","pr":77,"key":"HIMMEL-1","head":"%s"}],"edges":[]}\n' "$(NOW)" "$SHA" > "$tmp/graph.json"
run --graph "$tmp/graph.json" --dry-run 77 "$SHA";  esc "check 7 go-check REFUSE (jira_links unreadable)" 7
reset

# --- 6/7. nothing wrote a GO, and the script reads no flag ----------------------------------------------------------
check "no run wrote anything under .locks" "$([ -e "$HANDOVER_DIR/.locks" ] && echo present || echo absent)" "absent"
check "audit rows are JSON lines" "$(jq -e . "$AUDIT" >/dev/null 2>&1 && echo yes || echo no)" "yes"
check "auto-go.sh reads no flag" "$(grep -cE 'himmel_flag|himmelFlag|HIMMEL_FLAG_|lib/flags' "$HERE/auto-go.sh" 2>/dev/null)" "0"
grep -vE '^[[:space:]]*(#|$)' "$HERE/../../ci/ci-trust-paths.txt" > "$tmp/trust.re"
check "auto-go.sh is a trust path" "$(printf 'scripts/handover/chief-kit/auto-go.sh\n' | grep -cEf "$tmp/trust.re")" "1"

if [ "$fails" -eq 0 ]; then echo "test-auto-go.sh: all rows passed"; exit 0; fi
echo "test-auto-go.sh: $fails row(s) failed" >&2
exit 1
