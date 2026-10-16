#!/usr/bin/env bash
# shellcheck disable=SC2015  # A && B || C is intentional in check()/contains(), as in test-go.sh
# scripts/handover/console-kit/test-ready-go.sh - suite for ready-go.sh, the
# console's one-call READY turn. One row per output line:
#   1. usage: bad pr / sha / half a --to,--token pair -> exit 2.
#   2. clean PR: ready-check lines, READY-GO PASS, COVERAGE, TRUST: none, TICKET,
#      NEXT go.sh, and the exact SENDMESSAGE GO line.
#   3. no --to/--token: the GO line is skipped, never guessed.
#   4. no CR-ledger row at the head: ready-check FAILs -> exit 4, no GO line.
#   5. trust-path hit: TRUST: hit <path>, no plain GO line, the --trust-reviewed route.
#   6. trust list unreadable: TRUST: refused, exit 5, no GO line.
#   7. ticket: a Done ticket and an unreadable one print their state, a key-less title prints none.
#   8. --ledger appends one bullet to a console doc; a failing run appends nothing.
#   9. read-only: no GO file is written under the handover root.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${READY_GO_UNDER_TEST:-$HERE/ready-go.sh}"
unset HIMMEL_CONSOLE_LEG CONSOLE_SESSION_NAME 2>/dev/null || true

tmp="$(mktemp -d "${TMPDIR:-/tmp}/ready-go-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$tmp"' EXIT
tmp="$(cd "$tmp" && pwd)"
export HOME="$tmp/home"; mkdir -p "$HOME"
export HANDOVER_DIR="$tmp/root"; mkdir -p "$HANDOVER_DIR"

fails=0
check()    { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains() { printf '%s' "$2" | grep -qF -e "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
lacks()    { printf '%s' "$2" | grep -qF -e "$3" && { echo "FAIL - $1: output contains [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }

# shellcheck source=scripts/handover/console-kit/testlib-ready-pass.sh
# shellcheck disable=SC1091
. "$HERE/testlib-ready-pass.sh"
ready_pass_bin "$tmp/ready-bin"

# A fixture anchor: a git repo whose origin is a local bare repo at the same
# commit, carrying the real go-gate.sh. trust_path_check reads origin's HEAD
# from here, so the suite never touches the network.
ANCHOR="$tmp/anchor"
git init -q --bare "$tmp/origin.git"
git init -q "$ANCHOR"
mkdir -p "$ANCHOR/scripts/lib"
cp "$HERE/../../lib/go-gate.sh" "$ANCHOR/scripts/lib/go-gate.sh"
git -C "$ANCHOR" add -A
git -C "$ANCHOR" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$ANCHOR" remote add origin "$tmp/origin.git"
git -C "$ANCHOR" push -q origin HEAD:refs/heads/main 2>/dev/null
git -C "$tmp/origin.git" symbolic-ref HEAD refs/heads/main
export READY_GO_ANCHOR="$ANCHOR"

# A gh in front of the ready-pass one: the queries ready-go adds (repo name and
# default branch, PR title, trust list and file listing). Everything else falls
# through to the ready-pass stub, so ready-check still sees a green PR.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    "repo view --json nameWithOwner"*) printf 'o/r\n'; exit 0 ;;
    "repo view --json defaultBranchRef"*) printf 'main\n'; exit 0 ;;
    "pr view "*"--json title"*) printf '%s\n' "${STUB_TITLE:-fix(x): [HIMMEL-1] t (#1)}"; exit 0 ;;
    *"contents/scripts/ci/ci-trust-paths.txt"*)
        [ "${STUB_TRUST_LIST_FAIL:-0}" = 1 ] && { echo "boom" >&2; exit 1; }
        printf '^scripts/ci/\n'; exit 0 ;;
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

# a jira stub: `get <key>` prints the CLI's tab-separated first line
cat > "$tmp/jira" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_JIRA_FAIL:-0}" = 1 ] && exit 1
printf '%s\tTask\t%s\tsummary\n' "$2" "${STUB_JIRA_STATUS:-In Review}"
STUB
chmod +x "$tmp/jira"
export JIRA_CMD="$tmp/jira"

READY_REPO="$tmp/ready-repo"
git init -q "$READY_REPO"
cd "$READY_REPO" || { echo "FAIL: cd $READY_REPO" >&2; exit 1; }

SHA=0123456789abcdef0123456789abcdef01234567
SHA2=fedcba9876543210fedcba9876543210fedcba98
export READY_STUB_HEAD="$SHA"
ready_pass_ledger "$READY_REPO" "$SHA"

run() { OUT=$(bash "$SCRIPT" "$@" 2>&1); RC=$?; }

# --- 1. usage --------------------------------------------------------------
for args in "" "77" "x1 $SHA" "077 $SHA" "77 ${SHA%?}" "77 ${SHA}0" "77 0123456789ABCDEF0123456789abcdef01234567" \
            "--to leg 77 $SHA" "--token t 77 $SHA" "--to a/b --token t 77 $SHA"; do
    # shellcheck disable=SC2086  # word-splitting the args string IS the point
    run $args
    check "usage: [$args] -> exit 2" "$RC" "2"
done

# --- 2. clean PR -------------------------------------------------------------
run --to HIMMEL-9-leg --token BE-N1-abc 77 "$SHA"
check "clean: exit 0" "$RC" "0"
contains "clean: ready-check lines pass through" "$OUT" "[PASS] 4. CR ledger"
contains "clean: READY-GO PASS" "$OUT" "READY-GO PASS"
contains "clean: COVERAGE line" "$OUT" "COVERAGE: [PASS] 7."
contains "clean: TRUST none" "$OUT" "TRUST: none"
contains "clean: TICKET key and status" "$OUT" "TICKET: HIMMEL-1 In Review"
contains "clean: NEXT names go.sh" "$OUT" "NEXT: bash $HERE/go.sh 77 $SHA"
contains "clean: exact GO line" "$OUT" "SENDMESSAGE to=HIMMEL-9-leg :: GO 77 $SHA, token BE-N1-abc"

# --- 3. no pair -> no guessed line -------------------------------------------
run 77 "$SHA"
check "no pair: exit 0" "$RC" "0"
lacks "no pair: no SENDMESSAGE to=" "$OUT" "SENDMESSAGE to="
contains "no pair: says it skipped" "$OUT" "SENDMESSAGE skipped"

# --- 4. no CR-ledger row at the head -------------------------------------------
export READY_STUB_HEAD="$SHA2"
run --to leg --token tok 77 "$SHA2"
check "no CR row: exit 4" "$RC" "4"
contains "no CR row: ready-check names check 4" "$OUT" "[FAIL] 4."
contains "no CR row: READY-GO FAIL" "$OUT" "READY-GO FAIL"
lacks "no CR row: no GO line" "$OUT" "SENDMESSAGE"
lacks "no CR row: no NEXT" "$OUT" "NEXT:"
export READY_STUB_HEAD="$SHA"

# --- 5. trust-path hit ---------------------------------------------------------
export STUB_FILE=scripts/ci/ci-trust-paths.txt
run --to leg --token tok 77 "$SHA"
check "trust hit: exit 0" "$RC" "0"
contains "trust hit: TRUST names the path" "$OUT" "TRUST: hit scripts/ci/ci-trust-paths.txt"
lacks "trust hit: no plain GO line" "$OUT" "SENDMESSAGE"
contains "trust hit: routes through the judge" "$OUT" "go.sh --trust-reviewed <judge qid> 77 $SHA"
unset STUB_FILE

# --- 6. trust list unreadable --------------------------------------------------
export STUB_TRUST_LIST_FAIL=1
run --to leg --token tok 77 "$SHA"
check "trust refused: exit 5" "$RC" "5"
contains "trust refused: TRUST: refused" "$OUT" "TRUST: refused list"
lacks "trust refused: no GO line" "$OUT" "SENDMESSAGE"
unset STUB_TRUST_LIST_FAIL

# --- 7. ticket ----------------------------------------------------------------
export STUB_JIRA_STATUS=Done
run --to leg --token tok 77 "$SHA"
contains "ticket: a Done ticket shows Done" "$OUT" "TICKET: HIMMEL-1 Done"
unset STUB_JIRA_STATUS
export STUB_JIRA_FAIL=1
run --to leg --token tok 77 "$SHA"
contains "ticket: unreadable shows UNKNOWN" "$OUT" "TICKET: HIMMEL-1 UNKNOWN"
unset STUB_JIRA_FAIL
export STUB_TITLE="chore: no key here"
run --to leg --token tok 77 "$SHA"
contains "ticket: a key-less title shows none" "$OUT" "TICKET: none"
unset STUB_TITLE

# --- 8. --ledger ---------------------------------------------------------------
DOC="$tmp/x-console.md"
printf '# c\n\n## Results\n- 10:00 LIVE - start\n' > "$DOC"
run --ledger "$DOC" --to leg --token tok 77 "$SHA"
check "ledger: exit 0" "$RC" "0"
contains "ledger: LEDGER line printed" "$OUT" "LEDGER: appended"
contains "ledger: bullet in the doc" "$(cat "$DOC")" "ready-go PR 77 $SHA: ready-check PASS, trust none, ticket HIMMEL-1"
before=$(wc -l < "$DOC")
export READY_STUB_HEAD="$SHA2"
run --ledger "$DOC" --to leg --token tok 77 "$SHA2"
export READY_STUB_HEAD="$SHA"
check "ledger: a failing run appends nothing" "$(wc -l < "$DOC")" "$before"
run --ledger "$tmp/missing.md" 77 "$SHA"
check "ledger: missing doc -> exit 2" "$RC" "2"

# --- 9. read-only --------------------------------------------------------------
check "read-only: no GO file written" "$(ls -A "$HANDOVER_DIR")" ""

echo
[ "$fails" -eq 0 ] && { echo "test-ready-go: all passed"; exit 0; }
echo "test-ready-go: $fails FAILED"
exit 1
