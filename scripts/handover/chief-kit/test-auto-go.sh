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

fails=0; failrows=""
check()   { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); failrows="$failrows$1 | "; }; }
contains() { printf '%s' "$2" | grep -qF -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); failrows="$failrows$1 | "; }; }
lacks()    { printf '%s' "$2" | grep -qF -e "$3"; case $? in
                1) echo "ok - $1" ;;
                0) echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); failrows="$failrows$1 | " ;;
                *) echo "FAIL - $1: grep errored"; fails=$((fails+1)); failrows="$failrows$1 | " ;;
            esac; }

# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"

# A fixture anchor: a git repo whose origin is a local bare repo at the same commit,
# carrying the real go-gate.sh and the two allowlists check 1 reads. The real go.sh,
# write-verdict.sh and delta-class.sh (slice A1b) resolve their verdict scope from the
# checkout this file lives in, so the fixture anchor takes that checkout's primary-checkout
# basename: both then name the same <user>/<bucket>.
VBUCKET="$(basename "$(dirname "$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir)")")"
ANCHOR="$tmp/anchors/$VBUCKET"
VBUCKET="$(printf '%s' "$VBUCKET" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
mkdir -p "$tmp/anchors"
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
AUDIT="$HANDOVER_DIR/u/$VBUCKET/auto-go.jsonl"
VDIR="$HANDOVER_DIR/u/$VBUCKET/verdicts"

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

# slice A1b seams: the bus CLI and the process census. The bus stub keeps what it was sent; the census stub
# prints one claude_sessions row named STUB_SESSION (default: the worker doc's stem).
cat > "$tmp/bus" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_BUS_FAIL:-0}" = 1 ] && { echo "bus: no such peer" >&2; exit 1; }
[ "$1" = send ] || exit 2
printf '%s\n' "$2" > "$STUB_BUS_DIR/to"
cp "$3" "$STUB_BUS_DIR/body"
echo "sent #7 to $2"
STUB
cat > "$tmp/census" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_SESSION-x}" ] || printf '4242\t%s\tclaude-sonnet-5-5\t\n' "${STUB_SESSION:-HIMMEL-1-N1-feature-2026-10-31}"
STUB
chmod +x "$tmp/bus" "$tmp/census"
mkdir -p "$tmp/busdir"
export AUTO_GO_BUS="$tmp/bus" AUTO_GO_CENSUS="$tmp/census" STUB_BUS_DIR="$tmp/busdir"

# a judge's signed verdict, as test-go.sh builds one: the mac comes from go-gate.sh's go_verdict_mac under the GO key
VSCOPE="u/$VBUCKET"
mkdir -p "$HOME/.config/himmel"
printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef > "$HOME/.config/himmel/go-hmac.key"
# verdict <qid> <verdict line> [<pr, default 77>] [<file name>] [<signed 1|0>]
verdict() {
    local vf="$VDIR/$1/${4:-judge-$1}.md" vmac
    mkdir -p "$VDIR/$1"
    printf '# VERDICT %s - judge\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n' "$1" "$2" "${3:-77}" > "$vf"
    [ "${5:-1}" = 1 ] || return 0
    # shellcheck disable=SC2094  # the mac is computed from $vf's body before it is appended to
    # read-sink-ok: $vf is a verdict file this test just wrote under its own temp dir
    vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$1" "$(basename "$vf" .md)" < "$vf")" || { echo "FAIL: cannot sign $vf" >&2; return 1; }
    printf 'mac: %s\n' "$vmac" >> "$vf"
}

READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }
LEDGER="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"

SHA=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
export READY_STUB_HEAD="$SHA" READY_STUB_BRANCH=b
# Real commits for the carried-judge rows (delta-class.sh reads them): J is the judged head, a docs-only
# push after it classifies none, a push that touches a trust path classifies trust.
rgit() { git -C "$READY_REPO" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
mkdir -p "$READY_REPO/scripts/ci" "$READY_REPO/docs"
printf '^scripts/ci/\n' > "$READY_REPO/scripts/ci/ci-trust-paths.txt"
printf 'x\n' > "$READY_REPO/scripts/ci/x.sh"
printf 'c\n' > "$READY_REPO/docs/c.md"
rgit add -A && rgit commit -qm base
JUDGED=$(rgit rev-parse HEAD)
rgit update-ref refs/remotes/origin/main "$JUDGED"
printf 'more\n' >> "$READY_REPO/docs/c.md"; rgit add -A && rgit commit -qm docs
NDOC=$(rgit rev-parse HEAD)
rgit checkout -q -b trust "$JUDGED"
printf 'y\n' >> "$READY_REPO/scripts/ci/x.sh"; rgit add -A && rgit commit -qm trust
NTRUST=$(rgit rev-parse HEAD)
rgit checkout -q -
# a second docs-only push after NDOC, on its own branch: NDOC is then an intermediate head between JUDGED and NDOC2
rgit checkout -q -b docs2 "$NDOC"
printf 'again\n' >> "$READY_REPO/docs/c.md"; rgit add -A && rgit commit -qm docs2
NDOC2=$(rgit rev-parse HEAD)
rgit checkout -q -
ready_pass_ledger "$READY_REPO" "$SHA" "$SHA2" "$JUDGED" "$NDOC" "$NTRUST" "$NDOC2"
cp "$LEDGER" "$tmp/ledger.base"

CHIEF="$tmp/chief.md"
WORKER="$tmp/HIMMEL-1-N1-feature-2026-10-31.md"
FLEET="$tmp/chief.fleet.json"
# write_fixtures <lane> [<merge-hold line under ## Live state>] [<extra worker doc line>]
write_fixtures() {
    {
        # shellcheck disable=SC2016  # the backticks are the Live state entry's literal markers
        printf '# chief\n\n## Live state\n\nlegs: `N1:tok1:lock:1`\n'
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
check    "usage errors write no audit row" "$(audit_rows)" "0"

# --- 2. a worker or a relay never reaches the checks ---------------------------------------
HIMMEL_CONSOLE_RELAY=1 run --dry-run 77 "$SHA"
check "relay: exit 3" "$RC" "3"
# no seam is set on this row: with no claude ancestor (CI) the seam guard denies a marker plus a seam with exit 96 before the worker check
OUT=$(HIMMEL_CONSOLE_LEG=1 env -u AUTO_GO_ANCHOR -u AUTO_GO_BUS -u AUTO_GO_CENSUS -u GH_CMD -u JIRA_CMD -u HIMMEL_LEGACY_NAMES bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA" 2>&1); RC=$?
check "chief-spawned worker: exit 3" "$RC" "3"
check "exit 3 writes no audit row" "$(audit_rows)" "0"
nogo  "exit 3"

# --- 2b. a shared library that cannot be loaded is exit 1, never a run without it ---------
# a copy of auto-go.sh beside go-gate.sh and handover-path.sh but no git-clean.sh: the env
# scrub is missing, and a run on without it would read the caller's GIT_DIR
LIBTREE="$tmp/nolib"
mkdir -p "$LIBTREE/scripts/handover/chief-kit" "$LIBTREE/scripts/lib"
mkdir -p "$LIBTREE/scripts/cr"
cp "$SCRIPT" "$LIBTREE/scripts/handover/chief-kit/auto-go.sh"
cp "$HERE/../../lib/go-gate.sh" "$HERE/../../lib/handover-path.sh" "$HERE/../../lib/chokepoint-seam-guard.sh" "$LIBTREE/scripts/lib/"
cp "$HERE/../../cr/anchor-handoff.sh" "$LIBTREE/scripts/cr/"
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
check    "clean: checks 1-6 and 8 pass, in order" "$(last_row | jq -r '[.checks[] | select(.result != "no-graph") | .n] | join(",")')" "1,2,3,4,5,6,8"
check    "clean: check 5 (no judge needed) passes" "$(last_row | jq -r '.checks[] | select(.n == 5) | .result')" "pass"
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

# --- 4/1b. M1a: the manifest array is `workers`; the pre-rename `legs` array still reads ---
# (write_fixtures still writes the old `legs` array: the first row is an old manifest resolving a worker)
run --dry-run 77 "$SHA"
check    "check 1 an old legs manifest still resolves the worker (exit 0)" "$RC" "0"
contains "check 1 an old legs manifest: WOULD-GO" "$OUT" "WOULD-GO 77 $SHA"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1","lane":"native","added":"2026-10-31T00:00:00Z"}]}\n' "$WORKER" > "$FLEET"
run --dry-run 77 "$SHA"
check    "check 1 a workers manifest resolves the worker (exit 0)" "$RC" "0"
contains "check 1 a workers manifest: WOULD-GO" "$OUT" "WOULD-GO 77 $SHA"
HIMMEL_LEGACY_NAMES=0 run --dry-run 77 "$SHA"
check    "check 1 a workers manifest with HIMMEL_LEGACY_NAMES=0 still resolves (exit 0)" "$RC" "0"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"claudex","added":"2026-10-31T00:00:00Z"}],"workers":[{"doc":"%s","label":"N1","lane":"native","added":"2026-10-31T00:00:00Z"}]}\n' "$WORKER" "$WORKER" > "$FLEET"
run --dry-run 77 "$SHA"
check    "check 1 with both arrays the workers one wins (native passes, exit 0)" "$RC" "0"
reset; HIMMEL_LEGACY_NAMES=0 run --dry-run 77 "$SHA";  esc "check 1 an old legs manifest with HIMMEL_LEGACY_NAMES=0 is refused" 1
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

# --- 4/5. check 5: a trust-path hit with no judge verdict at the head escalates ---------------------------
STUB_FILE=scripts/ci/x.sh run --dry-run 77 "$SHA";  esc "check 5 trust-path hit with no judge verdict" 5
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

# --- 8. slice A1b: check 5 (the judge) and the GO act -------------------------------------------------------------
GOF="$HANDOVER_DIR/.locks/go/77.$SHA"
JLINE='This touches a guard/gate, so the chief runs an opus judge before GO.'
# gofresh: fresh fixtures, no GO files, verdicts, audit rows or bus traffic
gofresh() { rm -rf "$HANDOVER_DIR/.locks" "$VDIR"; rm -f "$AUDIT" "$tmp/busdir/to" "$tmp/busdir/body"; reset; }
gofile() { [ -f "${1:-$GOF}" ] && echo yes || echo no; }
bust()   { cat "$tmp/busdir/to" 2>/dev/null || echo none; }
q() { last_row | jq -r "$1"; }
dry_nothing() { # <label>: nothing was written, sent or recorded as a GO
    check "$1: no GO file" "$(gofile)" "no"
    check "$1: nothing sent on the bus" "$(bust)" "none"
}

# 8a. an ordinary PR (no trust hit, no judge brief, not docs): no verdict needed, the GO is written and sent
gofresh; run 77 "$SHA"
check    "A1b ordinary: exit 0" "$RC" "0"
check    "A1b ordinary: GO-SENT <pr> <head> to <label> bus=<#n>" "$OUT" "GO-SENT 77 $SHA to N1 bus=#7"
check    "A1b ordinary: the GO file exists" "$(gofile)" "yes"
contains "A1b ordinary: the GO file binds the head" "$(cat "$GOF" 2>/dev/null)" "head=$SHA"
contains "A1b ordinary: the GO file is signed" "$(cat "$GOF" 2>/dev/null)" "mac="
lacks    "A1b ordinary: a plain GO carries no trust-reviewed line" "$(cat "$GOF" 2>/dev/null)" "trust-reviewed="
check    "A1b ordinary: bus message goes to the worker's live session" "$(bust)" "HIMMEL-1-N1-feature-2026-10-31"
BODY=$(cat "$tmp/busdir/body" 2>/dev/null)
contains "A1b ordinary: bus message is GO <pr> <head> - merge with: bash" "$BODY" "GO 77 $SHA - merge with: bash "
contains "A1b ordinary: bus message names the GO file" "$BODY" "--go $GOF"
contains "A1b ordinary: bus message quotes the worker's token" "$BODY" "\`tok1\`"
lacks    "A1b ordinary: completes-ticket no leaves the Jira transition off" "$BODY" "--jira-transition"
check    "A1b ordinary: audit outcome go" "$(q .outcome)" "go"
check    "A1b ordinary: audit go_file" "$(q .go_file)" "$GOF"
check    "A1b ordinary: audit bus" "$(q .bus)" "#7"
check    "A1b ordinary: audit qid and delta are null" "$(q '[.qid, .delta] | map(tostring) | join(",")')" "null,null"
check    "A1b ordinary: audit checks 1-6 and 8 pass" "$(q '[.checks[] | select(.result != "no-graph" and .result != "pass") | .n] | length')" "0"
check    "A1b ordinary: the signed GO record names auto-go and script" "$(grep -l -x 'model: auto-go' "$VDIR"/go-pr-77/*.md 2>/dev/null | xargs grep -l -x 'effort: script' 2>/dev/null | wc -l | tr -d ' ')" "1"
gofresh; write_fixtures native "" '> **Completes ticket:** yes'; run 77 "$SHA"
contains "A1b completes-ticket yes adds --jira-transition" "$(cat "$tmp/busdir/body" 2>/dev/null)" "--jira-transition --go $GOF"

# 8b. --dry-run still answers and still writes nothing
gofresh; verdict q1 "**GO** for head \`$SHA\`."
STUB_FILE=scripts/ci/x.sh run --dry-run 77 "$SHA"
check    "A1b dry-run with a judge GO: WOULD-GO" "$OUT" "WOULD-GO 77 $SHA"
check    "A1b dry-run: check 5 passes" "$(q '.checks[] | select(.n == 5) | .result')" "pass"
dry_nothing "A1b dry-run"

# 8c. a trust-path hit: one signed GO verdict at the head for this PR
gofresh; verdict q1 "**GO** for head \`$SHA\`."
STUB_FILE=scripts/ci/x.sh run 77 "$SHA"
check    "A1b trust hit + judge GO: exit 0" "$RC" "0"
check    "A1b trust hit + judge GO: GO-SENT" "$OUT" "GO-SENT 77 $SHA to N1 bus=#7"
contains "A1b trust hit + judge GO: the GO file is trust-reviewed by the judge's qid" "$(cat "$GOF" 2>/dev/null)" "trust-reviewed=q1"
check    "A1b trust hit + judge GO: audit qid" "$(q .qid)" "q1"
check    "A1b trust hit + judge GO: audit delta stays null (a GO at the head itself)" "$(q .delta)" "null"
gofresh; verdict q1 "**GO** for head \`$SHA\`."; verdict q2 "**GO** for head \`$SHA\`."
STUB_FILE=scripts/ci/x.sh run 77 "$SHA"
check    "A1b two qids with GO at the head: exit 0" "$RC" "0"
gofresh; verdict q1 "**GO** for head \`$SHA\`."; verdict q2 "**NO-GO** for head \`$SHA\`."
STUB_FILE=scripts/ci/x.sh run 77 "$SHA";  esc "A1b a GO and a NO-GO at the head" 5
gofresh; verdict q1 "**GO** for head \`$SHA\`." 78
STUB_FILE=scripts/ci/x.sh run 77 "$SHA";  esc "A1b a GO that names another PR" 5
gofresh; verdict q1 "**GO** for head \`$SHA\`." 77 judge-q1 0
STUB_FILE=scripts/ci/x.sh run 77 "$SHA";  esc "A1b an unsigned GO" 5
gofresh; verdict q1 "**GO** for head \`$SHA\`."; verdict q3 "no verdict line here"
STUB_FILE=scripts/ci/x.sh run 77 "$SHA";  esc "A1b a GO beside an unparsed verdict of the PR" 5
gofresh; verdict q1 "**GO** for head \`$SHA2\`."
STUB_FILE=scripts/ci/x.sh run 77 "$SHA";  esc "A1b a GO at another head that no delta carries" 5

# 8d. a brief that asks for a judge (judge: true), though the diff hits no trust path
gofresh; write_fixtures native "" "> $JLINE"; run 77 "$SHA";  esc "A1b judge brief with no verdict" 5
gofresh; write_fixtures native "" "> $JLINE"; verdict q1 "**GO** for head \`$SHA\`."; run 77 "$SHA"
check    "A1b judge brief + judge GO: exit 0" "$RC" "0"
contains "A1b judge brief + judge GO: the GO is trust-reviewed" "$(cat "$GOF" 2>/dev/null)" "trust-reviewed=q1"

# 8e. a docs PR (decision 286): the docs judge's GO at the head
gofresh; STUB_FILE=docs/x.md run 77 "$SHA";  esc "A1b docs PR with no verdict" 5
gofresh; STUB_FILE=README.md run 77 "$SHA";  esc "A1b a *.md file anywhere is a docs PR" 5
gofresh; verdict q1 "**GO** for head \`$SHA\`."; STUB_FILE=docs/x.md run 77 "$SHA"
check    "A1b docs PR + docs judge GO: exit 0" "$RC" "0"
gofresh; run 77 "$SHA"
check    "A1b a non-docs PR needs no verdict (ordinary GO)" "$RC" "0"

# 8f. a GO at an earlier head carries when delta-class.sh says none (design 1.6)
gofresh; verdict qj "**GO** for head \`$JUDGED\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run --dry-run 77 "$NDOC"
check    "A1b carried judge, dry-run: WOULD-GO" "$OUT" "WOULD-GO 77 $NDOC"
check    "A1b carried judge, dry-run: no no-op record" "$([ -e "$VDIR/qj/delta-noop-$NDOC.md" ] && echo yes || echo no)" "no"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run 77 "$NDOC"
check    "A1b carried judge: exit 0" "$RC" "0"
check    "A1b carried judge: a delta no-op record is written for the new head" "$([ -e "$VDIR/qj/delta-noop-$NDOC.md" ] && echo yes || echo no)" "yes"
check    "A1b carried judge: audit qid" "$(q .qid)" "qj"
check    "A1b carried judge: audit delta none" "$(q .delta)" "none"
contains "A1b carried judge: the GO file is trust-reviewed by the carried qid" "$(cat "$HANDOVER_DIR/.locks/go/77.$NDOC" 2>/dev/null)" "trust-reviewed=qj"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NTRUST READY_STUB_HEAD=$NTRUST run 77 "$NTRUST";  esc "A1b a trust-path delta is not carried" 5
check    "A1b a trust-path delta writes no no-op record" "$([ -e "$VDIR/qj/delta-noop-$NTRUST.md" ] && echo yes || echo no)" "no"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$NDOC\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run 77 "$NDOC";  esc "A1b a NO-GO at the head beats a carried GO" 5
# a NO-GO by another qid at the judged head, or at a head between the judged head and this one, also refuses the carry
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$JUDGED\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run 77 "$NDOC";  esc "A1b a NO-GO by another qid at the judged head refuses the carry" 5
check    "A1b a NO-GO at the judged head: no no-op record" "$([ -e "$VDIR/qj/delta-noop-$NDOC.md" ] && echo yes || echo no)" "no"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$NDOC\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2";  esc "A1b a NO-GO by another qid at an intermediate head refuses the carry" 5
check    "A1b a NO-GO at an intermediate head: no no-op record" "$([ -e "$VDIR/qj/delta-noop-$NDOC2.md" ] && echo yes || echo no)" "no"

# 8g. the act can fail after the checks: go.sh refuses, or the bus does not deliver
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; mkdir -p "$HANDOVER_DIR"; printf 'x\n' > "$HANDOVER_DIR/.locks"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2"
contains "A1b go.sh refuses after a carry: the answer names the no-op record it left" "$OUT" "delta no-op record for qj"
# a retry that finds the no-op record the failed attempt left still honours a NO-GO recorded since
rm -rf "$HANDOVER_DIR/.locks"
verdict qn "**NO-GO** for head \`$NDOC\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2"
contains "A1b retry over a left no-op record: ESCALATE auto-go 5" "$OUT" "ESCALATE auto-go 5 "
gofresh; mkdir -p "$HANDOVER_DIR"; printf 'x\n' > "$HANDOVER_DIR/.locks"; run 77 "$SHA"
check    "A1b go.sh refuses: exit 10" "$RC" "10"
contains "A1b go.sh refuses: ESCALATE auto-go 9" "$OUT" "ESCALATE auto-go 9 "
check    "A1b go.sh refuses: audit names check 9" "$(q '[.checks[] | select(.result == "fail")][0].n')" "9"
check    "A1b go.sh refuses: nothing sent" "$(bust)" "none"
gofresh; STUB_BUS_FAIL=1 run 77 "$SHA"
check    "A1b bus fails: exit 11, the GO stands" "$RC" "11"
contains "A1b bus fails: GO-WRITTEN" "$OUT" "GO-WRITTEN 77 $SHA"
contains "A1b bus fails: the message for the chief to send" "$OUT" "SENDMESSAGE to=HIMMEL-1-N1-feature-2026-10-31 :: GO 77 $SHA - merge with: bash "
check    "A1b bus fails: the GO file stands" "$(gofile)" "yes"
check    "A1b bus fails: audit outcome go, no bus record" "$(q '[.outcome, .bus] | map(tostring) | join(",")')" "go,null"
gofresh; STUB_SESSION='' run 77 "$SHA"
check    "A1b no live session: exit 11" "$RC" "11"
contains "A1b no live session: GO-WRITTEN" "$OUT" "GO-WRITTEN 77 $SHA"
check    "A1b no live session: nothing sent" "$(bust)" "none"
gofresh; printf '# chief\n\n## Live state\n\nqueue: none\n\n## Results\n' > "$CHIEF"; run 77 "$SHA"
check    "A1b no token in Live state: exit 11" "$RC" "11"
contains "A1b no token in Live state: says so" "$OUT" "no token"
check    "A1b no token in Live state: nothing sent" "$(bust)" "none"

# 8h. LK-j4368-1 item 2: the audit append never follows a symlink, or writes a non-regular file
gofresh; mkdir -p "$(dirname "$AUDIT")"; printf 'keep\n' > "$tmp/victim.jsonl"; ln -s "$tmp/victim.jsonl" "$AUDIT"
run --dry-run 77 "$SHA"
check    "A1b symlinked audit target (dry-run): exit 1" "$RC" "1"
check    "A1b symlinked audit target: the target is untouched" "$(cat "$tmp/victim.jsonl")" "keep"
lacks    "A1b symlinked audit target: no answer given" "$OUT" "WOULD-GO"
run 77 "$SHA"
check    "A1b symlinked audit target (real run): exit 1" "$RC" "1"
dry_nothing "A1b symlinked audit target (real run)"
rm -f "$AUDIT" "$tmp/victim.jsonl"; ln -s "$tmp/no-such-victim.jsonl" "$AUDIT"; run --dry-run 77 "$SHA"
check    "A1b dangling symlink as audit target: exit 1" "$RC" "1"
check    "A1b dangling symlink as audit target: the target is not created" "$([ -e "$tmp/no-such-victim.jsonl" ] && echo yes || echo no)" "no"
rm -f "$AUDIT"; mkdir -p "$AUDIT"; run --dry-run 77 "$SHA"
check    "A1b directory as audit target: exit 1" "$RC" "1"
rmdir "$AUDIT"

# 8i. LK-j4368-1 item 1: the seams are closed the way go.sh closes them (anchor hand-off + chokepoint seam guard)
AG="$HERE/auto-go.sh"
check    "A1b auto-go.sh calls the chokepoint seam guard with its registry key" "$(grep -cx 'chokepoint_seam_guard scripts/handover/chief-kit/auto-go.sh || exit 96' "$AG")" "1"
check    "A1b auto-go.sh hands a relative entry off to the anchor" "$(grep -cE '^\. .*anchor-handoff\.sh' "$AG")" "1"
check    "A1b the registry names every seam auto-go.sh reads" "$(jq -r '."scripts/handover/chief-kit/auto-go.sh".seam_env_vars // [] | sort | join(",")' "$HERE/../../chokepoints.json")" "AUTO_GO_ANCHOR,AUTO_GO_BUS,AUTO_GO_CENSUS,GH_CMD,HIMMEL_LEGACY_NAMES,JIRA_CMD"

if [ "$fails" -eq 0 ]; then echo "test-auto-go.sh: all rows passed"; exit 0; fi
echo "test-auto-go.sh: $fails row(s) failed: $failrows" >&2
exit 1
