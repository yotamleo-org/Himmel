#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # A && B || C is intentional in check()/contains(), as in test-ready-go.sh; the backticks in the Live state and RETASK fixtures are literal
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
export HIMMEL_CEILINGS_LEDGER="$tmp/no-ceilings-ledger.tsv"
case "$HIMMEL_CEILINGS_LEDGER" in "$tmp"/*) ;; *) echo "FAIL: the ceilings ledger escapes the temp dir"; exit 1 ;; esac
unset HIMMEL_BUCKET_DIR

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
# ready-check's check 19 runs the anchor's impacted-suites.sh
mkdir -p "$ANCHOR/scripts/cr"
cp "$HERE/../../cr/impacted-suites.sh" "$HERE/../../cr/anchor-handoff.sh" "$ANCHOR/scripts/cr/"
cp "$HERE/../../lib/review-default-base.sh" "$ANCHOR/scripts/lib/"
cp "$HERE/../../lib/pr_remainder.py" "$ANCHOR/scripts/lib/pr_remainder.py"
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
stub_cwd_nwo() {
    if [ "$(pwd -P)" = "$(cd "$AUTO_GO_ANCHOR" && pwd -P)" ]; then printf 'o/r\n'
    elif git rev-parse --git-dir >/dev/null 2>&1; then printf 'some/other\n'
    else echo "failed to run git: fatal: not a git repository (or any parent up to mount point /)" >&2; exit 1; fi
}
if [ "${STUB_CWD_GH:-0}" = 1 ]; then
    case "$*" in
        "repo view --json nameWithOwner"*|"repo view --json defaultBranchRef"*) stub_cwd_nwo >/dev/null ;;
        "repo view o/r --json defaultBranchRef"*) ;;
        "pr view 77 -R o/r "*) ;;
        "pr view "*"--json state,headRefOid,baseRefName"*)
            echo "GraphQL: Could not resolve to a PullRequest with the number of 77. (repository.pullRequest)" >&2; exit 1 ;;
    esac
    case "$*" in "repo view --json nameWithOwner"*) stub_cwd_nwo; exit 0 ;; esac
fi
case "$*" in
    "repo view --json nameWithOwner"*) [ "${STUB_NWO_FAIL:-0}" = 1 ] && { printf '%s\n' "${STUB_GH_ERR:-}" >&2; exit 1; }; printf '%s\n' "${STUB_NWO:-o/r}"; exit 0 ;;
    "repo view "*"--json defaultBranchRef"*) printf 'main\n'; exit 0 ;;
    "pr view "*"--json state,headRefOid,baseRefName"*)
        [ "${STUB_VIEW_FAIL:-0}" = 1 ] && { printf '%s\n' "${STUB_GH_ERR:-}" >&2; exit 1; }
        jq -n --arg s "${STUB_PR_STATE:-OPEN}" --arg h "${STUB_PR_HEAD:-$READY_STUB_HEAD}" --arg b "${STUB_PR_BASE:-main}" \
            --arg body "$(printf '%b' "${READY_STUB_BODY-}")" --arg title "${STUB_VIEW_TITLE-fix(x): [HIMMEL-1] t (#1)}" \
            '{state: $s, headRefOid: $h, baseRefName: $b, body: $body, title: $title}'; exit 0 ;;
    "pr view "*"--json headRefOid,state"*) cat "$STUB_GC/head-$3.json" 2>/dev/null || exit 1; exit 0 ;;  # read-sink-ok: the stub reads its own fixture dir
    "pr view "*"--json title"*)
        [ "${STUB_TITLE_NEEDS_R:-0}" = 1 ] && case "$*" in "pr view 77 -R o/r --json title"*) ;; *) echo "no git remotes found" >&2; exit 1 ;; esac
        printf '%s\n' "${STUB_TITLE:-fix(x): [HIMMEL-1] t (#1)}"; exit 0 ;;
    # a keyed title makes ready-check read the head and author; neither stub answers them otherwise and the two bounce the call forever
    "pr view "*"--json headRefOid --jq"*) printf '%s\n' "$READY_STUB_HEAD"; exit 0 ;;
    "pr view "*"--json author"*) printf 'someone\n'; exit 0 ;;
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
if [ "${STUB_BUS_TOKFAIL:-0}" = 1 ]; then
    echo send >> "$STUB_BUS_DIR/sends"
    case "$3" in "${TMPDIR:-/tmp}"/*) ;; *) exit 2 ;; esac
    printf 'bus: rejected token %s: %s\n' "$(sed -n 's/^Your token `\(.*\)`\.$/\1/p' "$3")" "$(tr '\n' ' ' < "$3")" >&2; exit 1
fi
printf '%s\n' "$2" > "$STUB_BUS_DIR/to"
cp "$3" "$STUB_BUS_DIR/body"
echo send >> "$STUB_BUS_DIR/sends"
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
export HIMMEL_REPO="$READY_REPO"
LEDGER="$(git rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"

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
# check 19 fetches origin/main and reads origin/main..<head>: real heads on JUDGED
ready_pass_origin "$READY_REPO" "$JUDGED"
SHA=$(ready_pass_repo "$READY_REPO") || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
SHA2=$(ready_pass_repo "$READY_REPO" 2) || { echo "FAIL: ready_pass_repo" >&2; exit 1; }
export READY_STUB_HEAD="$SHA" READY_STUB_BRANCH=b
check "ready-check's owner-review line over the ready-pass fixture" "$(ready_pass_owner_review)" "$READY_PASS_OWNER_LINE"
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
# a run of further docs-only pushes after NDOC2 (CH[0] is the third push): the heads of a chain of no-op records
CH=()
for chi in 3 4 5 6 7 8 9 10; do
    printf 'c%s\n' "$chi" >> "$READY_REPO/docs/c.md"; rgit add -A && rgit commit -qm "docs$chi"
    CH+=("$(rgit rev-parse HEAD)")
done
rgit checkout -q -
RB=$(rgit symbolic-ref --short HEAD)
# PSIB: a docs push on JUDGED beside NDOC, PX a docs push on it (a no-op chain hop off the line)
rgit checkout -q -b psib "$JUDGED"
printf 's\n' >> "$READY_REPO/docs/s.md"; rgit add -A && rgit commit -qm psib; PSIB=$(rgit rev-parse HEAD)
printf 'x\n' >> "$READY_REPO/docs/s.md"; rgit add -A && rgit commit -qm px; PX=$(rgit rev-parse HEAD)
# J3: a docs push after NDOC whose sha sorts after JUDGED's (so the carry meets JUDGED first), J3C a docs push on it
j3n=0
while :; do
    rgit checkout -q -B jh3 "$NDOC"
    printf 'j3 %s\n' "$j3n" > "$READY_REPO/docs/j3.md"; rgit add -A && rgit commit -qm "j3 $j3n"; J3=$(rgit rev-parse HEAD)
    [[ "$J3" > "$JUDGED" ]] && break
    j3n=$((j3n + 1))
done
printf 'c\n' >> "$READY_REPO/docs/j3.md"; rgit add -A && rgit commit -qm j3c; J3C=$(rgit rev-parse HEAD)
# HB: a docs push on JUDGED whose sha sorts BEFORE JUDGED's (so the carry meets a no-op record resting on JUDGED first), HBN a docs push on it
hbn=0
while :; do
    rgit checkout -q -B hbh "$JUDGED"
    printf 'hb %s\n' "$hbn" > "$READY_REPO/docs/hb.md"; rgit add -A && rgit commit -qm "hb $hbn"; HB=$(rgit rev-parse HEAD)
    [[ "$HB" < "$JUDGED" ]] && break
    hbn=$((hbn + 1))
done
printf 'c\n' >> "$READY_REPO/docs/hb.md"; rgit add -A && rgit commit -qm hbn; HBN=$(rgit rev-parse HEAD)
rgit checkout -q "$RB"
# ASIB (on NDOC) and ASIDE (on NDOC2): docs pushes only the anchor checkout holds, never the cwd
SIDE="$tmp/side"
git clone -q "$READY_REPO" "$SIDE"
sgit() { git -C "$SIDE" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"; }
sgit checkout -q -b asib "$NDOC"; printf 'a\n' > "$SIDE/docs/a.md"; sgit add -A && sgit commit -qm asib; ASIB=$(sgit rev-parse HEAD)
sgit checkout -q -b aside "$NDOC2"; printf 'b\n' > "$SIDE/docs/b.md"; sgit add -A && sgit commit -qm aside; ASIDE=$(sgit rev-parse HEAD)
git -C "$ANCHOR" fetch -q "$READY_REPO" '+refs/heads/*:refs/ready/*'
git -C "$ANCHOR" fetch -q "$SIDE" '+refs/heads/*:refs/side/*'
git -C "$ANCHOR" update-ref refs/remotes/origin/main "$JUDGED"
ln -s "$LEDGER" "$(git -C "$ANCHOR" rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"
ready_pass_ledger "$READY_REPO" "$SHA" "$SHA2" "$JUDGED" "$NDOC" "$NTRUST" "$NDOC2" "${CH[@]}" "$PSIB" "$PX" "$J3" "$J3C" "$HB" "$HBN" "$ASIB" "$ASIDE"
cp "$LEDGER" "$tmp/ledger.base"

CHIEF="$tmp/chief.md"
WORKER="$tmp/HIMMEL-1-N1-feature-2026-10-31.md"
FLEET="$tmp/chief.fleet.json"
# write_fixtures <lane> [<merge-hold line under ## Live state>] [<extra worker doc line>]
write_fixtures() {
    {
        # shellcheck disable=SC2016  # the backticks are the Live state entry's literal markers
        printf '# chief\n\n## Live state\n\nlegs: `N1:CS-N1-tok1:lock:1`\n'
        [ -z "${2:-}" ] || printf '%s\n' "$2"
        printf 'queue: none\n\n## Results\n'
    } > "$CHIEF"
    printf '# worker\n\n> **Completes ticket:** no\n%s\n' "${3:-}" > "$WORKER"
    printf '{"schema":1,"legs":[{"doc":"%s","label":"N1","lane":"%s","added":"2026-10-31T00:00:00Z"}]}\n' "$WORKER" "${1:-native}" > "$FLEET"
}
reset() {
    unset STUB_NWO STUB_NWO_FAIL STUB_VIEW_FAIL STUB_PR_STATE STUB_PR_HEAD STUB_PR_BASE STUB_TITLE STUB_FILE STUB_COMMIT_MSG \
          STUB_COMMITS_FAIL STUB_JIRA_FAIL STUB_VIEW_TITLE STUB_LABELS_HIMMEL_1 STUB_LABELS_HIMMEL_2 2>/dev/null || true
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
OUT=$(env -u HIMMEL_CONSOLE_LEG -u AUTO_GO_ANCHOR -u AUTO_GO_BUS -u AUTO_GO_CENSUS -u GH_CMD -u JIRA_CMD -u HIMMEL_LEGACY_NAMES HIMMEL_CONSOLE_JUDGE_NOVERDICT=1 bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check    "desk (LEG unset, marker set): exit 3" "$RC" "3"
contains "desk (LEG unset, marker set): the chief-worker refusal" "$OUT" "chief-spawned worker"
check    "desk (LEG unset, marker set): no audit row" "$(audit_rows)" "0"
nogo     "desk (LEG unset, marker set)"
OUT=$(env -u HIMMEL_CONSOLE_LEG -u HIMMEL_CONSOLE_JUDGE_NOVERDICT -u AUTO_GO_ANCHOR -u AUTO_GO_BUS -u AUTO_GO_CENSUS -u GH_CMD -u JIRA_CMD -u HIMMEL_LEGACY_NAMES HIMMEL_CONSOLE_JUDGE=1 bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check    "judge (LEG and marker unset, JUDGE=1): exit 3" "$RC" "3"
contains "judge (LEG and marker unset, JUDGE=1): the chief-worker refusal" "$OUT" "chief-spawned worker"
check    "judge (LEG and marker unset, JUDGE=1): no audit row" "$(audit_rows)" "0"
nogo     "judge (LEG and marker unset, JUDGE=1)"

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

# --- 3b. the completion contract: the brief's `Completes ticket:` line, read before any record or GO is written ---
# A keyed PR under contract no with no recorded remainder is the merge's exit 26; ready-go refuses it at check 3,
# so no delta no-op record and no GO file exist. The same PR with `Completes ticket: yes` passes.
export READY_STUB_TITLE='fix(x): [HIMMEL-1] a partial change'
run --dry-run 77 "$SHA"
esc      "contract no, no remainder" 3
contains "contract no, no remainder: the escalation names item 17" "$OUT" "17."
check    "contract no, no remainder: no verdict record written" "$(find "$VDIR" -type f 2>/dev/null | wc -l | tr -d ' ')" "0"
export READY_STUB_BODY=$'## Ticket coverage\n- ask: done\n\nRemaining: the docs follow\n\nRED then GREEN: the new row failed before the change\n'
run --dry-run 77 "$SHA"
check    "contract no, with a Remaining line: exit 0" "$RC" "0"
check    "contract no, with a Remaining line: WOULD-GO" "$OUT" "WOULD-GO 77 $SHA"
unset READY_STUB_BODY
write_fixtures native "" "" ; printf '# worker\n\n> **Completes ticket:** yes\n' > "$WORKER"
run --dry-run 77 "$SHA"
check    "contract yes, no remainder: exit 0" "$RC" "0"
check    "contract yes, no remainder: WOULD-GO" "$OUT" "WOULD-GO 77 $SHA"
unset READY_STUB_TITLE
reset

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
printf '# chief\n\n## Live state\n\nworkers: `N1:CS-N1-tok1:lock:1`\nqueue: none\n\n## Results\n' > "$CHIEF"
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

mkdir -p "$tmp/nogit" "$tmp/otherclone"; git init -q "$tmp/otherclone"
cd "$tmp/nogit" || exit 1
STUB_CWD_GH=1 run --dry-run 77 "$SHA"
check    "10828 a non-git cwd: checks 1 and 2 pass" "$(last_row | jq -r '[.checks[] | select(.n <= 2) | "\(.n)=\(.result)"] | join(",")')" "1=pass,2=pass"
cd "$tmp/otherclone" || exit 1
STUB_CWD_GH=1 run --dry-run 77 "$SHA"
check    "10828 a cwd in another repo's clone: checks 1 and 2 pass" "$(last_row | jq -r '[.checks[] | select(.n <= 2) | "\(.n)=\(.result)"] | join(",")')" "1=pass,2=pass"
cd "$READY_REPO" || exit 1
reset; STUB_VIEW_FAIL=1 STUB_GH_ERR="GraphQL: Could not resolve to a PullRequest with the number of 77. (repository.pullRequest)" run --dry-run 77 "$SHA"
esc      "10828 a failed PR read" 2
contains "10828 a failed PR read: the ESCALATE line carries gh's error" "$OUT" "ESCALATE auto-go 2 cannot read the PR or the default branch of o/r (gh: GraphQL: Could not resolve to a PullRequest with the number of 77."
reset; STUB_VIEW_FAIL=1 STUB_GH_ERR="HTTP 403: API rate limit exceeded (https://api.github.com/graphql?access_token=ghp_SECRET0123456789abcdef)" run --dry-run 77 "$SHA"
contains "10828 a failed PR read: the 403 reason is kept" "$OUT" "HTTP 403: API rate limit exceeded (https://api.github.com/graphql"
lacks    "10828 a failed PR read: no URL query is kept" "$OUT" "access_token"
lacks    "10828 a failed PR read: no token is kept" "$OUT" "ghp_SECRET"
reset; STUB_NWO_FAIL=1 STUB_GH_ERR="failed to run git: fatal: not a git repository" run --dry-run 77 "$SHA"
esc      "10828 a failed repo-name read" 1
contains "10828 a failed repo-name read: the ESCALATE line carries gh's error" "$OUT" "(gh: failed to run git: fatal: not a git repository)"
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
reset; STUB_TITLE_NEEDS_R=1 run --dry-run 77 "$SHA"
check "10828 check 4 reads the title with the repo named (a gh that needs -R still passes)" "$RC" "0"
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
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1","lane":"native","added":"2026-10-31T00:00:00Z"}]}\n' "$tmp/briefdir" > "$FLEET"
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
check    "A1b ordinary: GO-SENT <pr> <head> to <label> bus=<#n> qid=none" "$OUT" "GO-SENT 77 $SHA to N1 bus=#7 qid=none"
check    "A1b ordinary: the GO file exists" "$(gofile)" "yes"
contains "A1b ordinary: the GO file binds the head" "$(cat "$GOF" 2>/dev/null)" "head=$SHA"
contains "A1b ordinary: the GO file is signed" "$(cat "$GOF" 2>/dev/null)" "mac="
duplicate_sends=$(wc -l < "$tmp/busdir/sends")
run 77 "$SHA"
check "duplicate exact-head READY: exit 0 from recorded GO" "$RC" "0"
check "duplicate exact-head READY: no second bus send" "$(wc -l < "$tmp/busdir/sends")" "$duplicate_sends"
lacks    "A1b ordinary: a plain GO carries no trust-reviewed line" "$(cat "$GOF" 2>/dev/null)" "trust-reviewed="
check    "A1b ordinary: bus message goes to the worker's live session" "$(bust)" "HIMMEL-1-N1-feature-2026-10-31"
BODY=$(cat "$tmp/busdir/body" 2>/dev/null)
contains "A1b ordinary: bus message is GO <pr> <head> - merge with: bash" "$BODY" "GO 77 $SHA - merge with: bash "
contains "A1b ordinary: bus message names the GO file" "$BODY" "--go $GOF"
contains "A1b ordinary: bus message quotes the worker's token" "$BODY" "\`CS-N1-tok1\`"
lacks    "A1b ordinary: completes-ticket no leaves the Jira transition off" "$BODY" "--jira-transition"
check    "A1b ordinary: audit outcome go" "$(q .outcome)" "go"
check    "A1b ordinary: audit go_file" "$(q .go_file)" "$GOF"
check    "A1b ordinary: audit bus" "$(q .bus)" "#7"
check    "A1b ordinary: audit qid and delta are null" "$(q '[.qid, .delta] | map(tostring) | join(",")')" "null,null"
check    "A1b ordinary: audit checks 1-6 and 8 pass" "$(q '[.checks[] | select(.result != "no-graph" and .result != "pass") | .n] | length')" "0"
check    "A1b ordinary: the signed GO record names auto-go and script" "$(grep -l -x 'model: auto-go' "$VDIR"/go-pr-77/*.md 2>/dev/null | xargs grep -l -x 'effort: script' 2>/dev/null | wc -l | tr -d ' ')" "1"
gofresh; write_fixtures native "" '> **Completes ticket:** yes'; run 77 "$SHA"
contains "A1b completes-ticket yes adds --jira-transition" "$(cat "$tmp/busdir/body" 2>/dev/null)" "--jira-transition --go $GOF"

export READY_STUB_TITLE='fix(x): [HIMMEL-1] a partial change'
BODY_REST=$'## Ticket coverage\n- ask: done\n\nRemaining: the docs follow\n\nRED then GREEN: the new row failed before the change\n'
BODY_CLEAN=$'## Ticket coverage\n- ask: done\n\nRED then GREEN: the new row failed before the change\n'
BODY_OWED=$'## Ticket coverage\n- ask: done\n\n11061 live proof: owed \xe2\x86\x92 proof by 2026-12-05\n\nRED then GREEN: the new row failed before the change\n'
BRIEF_YES='> **Completes ticket:** yes'
mline() { head -n 1 "$tmp/busdir/body" 2>/dev/null; }
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="completes-ticket: no"$'\n'"$BODY_REST" run 77 "$SHA"
check    "C1 body no over brief yes: exit 0" "$RC" "0"
lacks    "C1 body no over brief yes: the GO message has no --jira-transition" "$(mline)" "--jira-transition"
contains "C1 body no over brief yes: the GO message names why" "$(cat "$tmp/busdir/body" 2>/dev/null)" "contract no: contract no from the PR body, brief says yes; merge without --jira-transition"
contains "C1 body no over brief yes: the GO message names the GO file" "$(cat "$tmp/busdir/body" 2>/dev/null)" "--go $GOF"
check    "C6 body no over brief yes: check 3 audit reason" "$(q '.checks[] | select(.n == 3) | .reason')" "contract no from the PR body, brief says yes"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY=$'completes-ticket: no\n## Ticket coverage\n- ask: done\n\nRED then GREEN: the new row failed before the change\n' run --dry-run 77 "$SHA"
esc      "C8 body no over brief yes, no Remaining line: ready-go runs under contract no" 3
contains "C8 body no over brief yes, no Remaining line: the escalation names item 17" "$OUT" "17."
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="completes-ticket: yes"$'\n'"$BODY_CLEAN" run 77 "$SHA"
contains "C2 body yes, brief yes, no remainder: the GO message carries --jira-transition" "$(cat "$tmp/busdir/body" 2>/dev/null)" "--jira-transition --go $GOF"
check    "C2 body yes, brief yes: no check 3 reason" "$(q '.checks[] | select(.n == 3) | .reason // "none"')" "none"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY=$'completes-ticket: yes\ncompletes-ticket: no\n'"$BODY_CLEAN" run --dry-run 77 "$SHA"
esc      "A8 body names yes and no, brief yes" 3
contains "A8 body names yes and no: says so" "$OUT" "the PR body names both completes-ticket: yes and no"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="$BODY_REST" run 77 "$SHA"
check    "A2 no body line, a Remaining line, brief yes: exit 0" "$RC" "0"
lacks    "A2 a Remaining line, brief yes: the merge line has no --jira-transition" "$(mline)" "--jira-transition"
contains "A2 a Remaining line, brief yes: the message says why" "$(cat "$tmp/busdir/body" 2>/dev/null)" "contract no: the PR body leaves a remainder (remaining); merge without --jira-transition"
check    "A2 a Remaining line, brief yes: check 3 audit reason" "$(q '.checks[] | select(.n == 3) | .reason')" "the PR body leaves a remainder (remaining)"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="$BODY_OWED" run 77 "$SHA"
check    "A1 the PR 5894 shape (an owed line, no completes-ticket line), brief yes: exit 0" "$RC" "0"
lacks    "A1 the PR 5894 shape: the merge line has no --jira-transition" "$(mline)" "--jira-transition"
contains "A1 the PR 5894 shape: the message says why" "$(cat "$tmp/busdir/body" 2>/dev/null)" "contract no: the PR body leaves a remainder (remaining); merge without --jira-transition"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="$BODY_CLEAN" run 77 "$SHA"
contains "A3 brief yes, a clean body: the flag stays" "$(mline)" "--jira-transition --go $GOF"
check    "A3 brief yes, a clean body: no check 3 reason" "$(q '.checks[] | select(.n == 3) | .reason // "none"')" "none"
gofresh; printf '# worker\n\n## Results\n' > "$WORKER"; READY_STUB_BODY="$BODY_REST" run 77 "$SHA"
check    "A5 no brief line, no body line, a Remaining line: exit 0" "$RC" "0"
lacks    "A5 no contract on record: the merge line has no --jira-transition" "$(mline)" "--jira-transition"
contains "A5 no contract on record: the message says so" "$(cat "$tmp/busdir/body" 2>/dev/null)" "contract no: no contract on record; merge without --jira-transition"
check    "A5 no contract on record: check 3 audit reason" "$(q '.checks[] | select(.n == 3) | .reason')" "no contract on record"
gofresh; printf '# worker\n\n## Results\n' > "$WORKER"; READY_STUB_BODY="$BODY_CLEAN" run --dry-run 77 "$SHA"
esc      "A5 no contract on record, a clean body: ready-go runs under contract no" 3
contains "A5 no contract on record, a clean body: the escalation names why" "$OUT" "no contract on record"
gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="completes-ticket: yes"$'\n'"$BODY_REST" run --dry-run 77 "$SHA"
esc      "A6 body yes plus a Remaining line, brief yes" 3
contains "A6 body yes plus a Remaining line: says so" "$OUT" "the PR body says completes-ticket: yes but leaves a remainder (remaining)"
gofresh; write_fixtures native "" "$BRIEF_YES"; STUB_VIEW_TITLE='fix(x): no ticket key here' READY_STUB_BODY="$BODY_CLEAN" run --dry-run 77 "$SHA"
esc      "A7 no [KEY] in the title" 3
contains "A7 no [KEY] in the title: says the remainder is unreadable" "$OUT" "remainder unreadable"
gofresh; write_fixtures native "" "$BRIEF_YES"; cp "$ANCHOR/scripts/lib/pr_remainder.py" "$tmp/pr_remainder.keep"
printf 'import sys\nsys.exit(2)\n' > "$ANCHOR/scripts/lib/pr_remainder.py"; READY_STUB_BODY="$BODY_CLEAN" run --dry-run 77 "$SHA"
cp "$tmp/pr_remainder.keep" "$ANCHOR/scripts/lib/pr_remainder.py"
esc      "A7 the reader exits 2" 3
contains "A7 the reader exits 2: says the remainder is unreadable" "$OUT" "remainder unreadable"
for variant in 'completes-ticket: maybe' '  completes-ticket: no' $'```\ncompletes-ticket: no\n```' $'~~~\ncompletes-ticket: no\n~~~' $'```\nunclosed\ncompletes-ticket: no' $'```\n~~~\ncompletes-ticket: no\n~~~\n```' $'````\n```\ncompletes-ticket: no\n```\n````'; do
    gofresh; write_fixtures native "" "$BRIEF_YES"; READY_STUB_BODY="$variant"$'\n'"$BODY_CLEAN" run 77 "$SHA"
    contains "C5 ignored body line [$(printf '%s' "$variant" | tr '\n' '|')], brief yes: the brief's yes stands" "$(cat "$tmp/busdir/body" 2>/dev/null)" "--jira-transition --go $GOF"
done
gofresh; write_fixtures native ""; READY_STUB_BODY="completes-ticket: yes"$'\n'"$BODY_REST" run --dry-run 77 "$SHA"
esc      "C7 body yes over brief no" 3
contains "C7 body yes over brief no: names the body's yes" "$OUT" "the PR body says completes-ticket: yes"
contains "C7 body yes over brief no: names the brief's no" "$OUT" "the brief says no"
lacks    "C7 body yes over brief no: ready-go did not run" "$OUT" "[FAIL] 17"
unset READY_STUB_TITLE
gofresh

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
check    "A1b trust hit + judge GO: GO-SENT names the qid" "$OUT" "GO-SENT 77 $SHA to N1 bus=#7 qid=q1"
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
DOCS_NEED="every changed file is under docs/ or is a .md file"
gofresh; STUB_FILE=docs/x.md run 77 "$SHA";  esc "A1b docs PR with no verdict" 5
contains "A1b docs PR with no verdict: says what it needs" "$OUT" "$DOCS_NEED"
lacks    "A1b docs PR with no verdict: no decision number" "$OUT" "decision 286"
gofresh; STUB_FILE=README.md run 77 "$SHA";  esc "A1b a *.md file anywhere is a docs PR" 5
contains "A1b a *.md file anywhere: says what it needs" "$OUT" "$DOCS_NEED"
lacks    "A1b a *.md file anywhere: no decision number" "$OUT" "decision 286"
gofresh; verdict q1 "**GO** for head \`$SHA\`."; STUB_FILE=docs/x.md run 77 "$SHA"
check    "A1b docs PR + docs judge GO: exit 0" "$RC" "0"
C5WHY=$(last_row | jq -r '.checks[] | select(.n == 5) | .reason')
contains "A1b docs PR + docs judge GO: says what it needs" "$C5WHY" "$DOCS_NEED"
lacks    "A1b docs PR + docs judge GO: no decision number" "$C5WHY" "decision 286"
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
# a carry that starts from a delta no-op record resolves it to the judged head it rests on (a NO-GO at that head still refuses)
# the no-op record for NDOC beside the judge's own GO at JUDGED, then a NO-GO at JUDGED, then a later docs-only head NDOC2
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; mkdir -p "$HANDOVER_DIR"; printf 'x\n' > "$HANDOVER_DIR/.locks"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run 77 "$NDOC"   # go.sh fails after the carry and leaves the no-op record for NDOC
rm -rf "$HANDOVER_DIR/.locks"; verdict qn "**NO-GO** for head \`$JUDGED\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2";  esc "A1b a NO-GO at the judged head refuses a carry that can start from a no-op record" 5
contains "A1b a carry that can start from a no-op record: the refusal names the NO-GO" "$OUT" "holds a NO-GO"
# the same with only the no-op record left (the judge's own GO file gone): no hex-order luck decides the result
rm -f "$VDIR/qj/judge-qj.md"; rm -f "$AUDIT"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2";  esc "A1b a NO-GO at the judged head refuses a carry whose only record is the no-op" 5
contains "A1b a carry whose only record is the no-op: the refusal names the NO-GO" "$OUT" "holds a NO-GO"
# a chain of no-op records: a record's judged head may itself rest on a no-op record, and the NO-GO check follows the chain to the root
# (write-verdict.sh refuses to chain by its own check: --delta-noop names a head that is itself a no-op record, rc 2. The rows
# write signed records by hand, since go_trust_verdict itself would accept one.)
noop() { # <head> <judged head>: a signed no-op record in write-verdict.sh's layout
    local nvf="$VDIR/qj/delta-noop-$1.md" nmac
    mkdir -p "$VDIR/qj"
    # shellcheck disable=SC2016  # the backticks are literal text in the verdict file
    printf '# VERDICT qj - delta-noop-%s\n\n## Verdict\n\n**GO** for head `%s`.\n\npr: 77\nmodel: auto-go\neffort: script\ndelta: no-op\ndelta-judged: %s\ndelta-class: none\n\nevidence\n' "$1" "$1" "$2" > "$nvf"
    # shellcheck disable=SC2094  # the mac is computed from $nvf's body before it is appended to
    # read-sink-ok: $nvf is a verdict file this test just wrote under its own temp dir
    nmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" qj "delta-noop-$1" < "$nvf")" || return 1
    printf 'mac: %s\n' "$nmac" >> "$nvf"
}
gofresh; verdict qj "**GO** for head \`$JUDGED\`."
noop "$NDOC" "$JUDGED"; noop "$NDOC2" "$NDOC"
check    "A1b chain: the two no-op records exist" "$(set -- "$VDIR"/qj/delta-noop-*; echo $#)" "2"
verdict qn "**NO-GO** for head \`$JUDGED\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2";  esc "A1b a no-op chain of two: a NO-GO at the root refuses (head with the record)" 5
contains "A1b a no-op chain of two (head with the record): the refusal names the NO-GO" "$OUT" "holds a NO-GO"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=${CH[0]} READY_STUB_HEAD=${CH[0]} run 77 "${CH[0]}";  esc "A1b a no-op chain of two: a NO-GO at the root refuses (carry loop)" 5
# a chain past the hop cap (8) refuses
gofresh; verdict qj "**GO** for head \`$JUDGED\`."
noop "$NDOC" "$JUDGED"; noop "$NDOC2" "$NDOC"; noop "${CH[0]}" "$NDOC2"; noop "${CH[1]}" "${CH[0]}"; noop "${CH[2]}" "${CH[1]}"
noop "${CH[3]}" "${CH[2]}"; noop "${CH[4]}" "${CH[3]}"; noop "${CH[5]}" "${CH[4]}"; noop "${CH[6]}" "${CH[5]}"
check    "A1b chain: nine no-op records exist" "$(set -- "$VDIR"/qj/delta-noop-*; echo $#)" "9"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=${CH[6]} READY_STUB_HEAD=${CH[6]} run 77 "${CH[6]}";  esc "A1b a no-op chain past the hop cap refuses" 5
contains "A1b a no-op chain past the hop cap: the refusal says so" "$OUT" "hops"
# an unreadable verdict file of another qid refuses (a directory named like a verdict stands in; it fails for root too)
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**GO** for head \`$JUDGED\`."; mkdir -p "$VDIR/qn/bad.md"
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC READY_STUB_HEAD=$NDOC run 77 "$NDOC";  esc "A1b an unreadable verdict file refuses the carry" 5
# a retry that finds the no-op record the failed attempt left still honours a NO-GO recorded since
rm -rf "$HANDOVER_DIR/.locks"
verdict qn "**NO-GO** for head \`$NDOC\`."
STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$NDOC2 READY_STUB_HEAD=$NDOC2 run 77 "$NDOC2"
contains "A1b retry over a left no-op record: ESCALATE auto-go 5" "$OUT" "ESCALATE auto-go 5 "
# check 5: anchor-bound git, fail-closed reads and the no-op chain
# hrun <head>: a trust-hit run at <head> (the judge requirement applies)
hrun() { STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$1 READY_STUB_HEAD=$1 run 77 "$1"; }
sent() { # <label> <head> <qid>
    check "$1: exit 0" "$RC" "0"
    check "$1: GO-SENT" "$OUT" "GO-SENT 77 $2 to N1 bus=#7 qid=$3"
}
# the dry run, for rows go.sh would refuse on grounds of its own (it reads a no-op's delta from the cwd, and
# a chain of hand-written no-op records is not one write-verdict.sh produces): check 5 is what these rows prove
drun() { STUB_FILE=scripts/ci/x.sh STUB_PR_HEAD=$1 READY_STUB_HEAD=$1 run --dry-run 77 "$1"; }
would() { # <label> <head>
    check "$1: exit 0" "$RC" "0"
    check "$1: WOULD-GO" "$OUT" "WOULD-GO 77 $2"
}
# delta-class.sh and the NO-GO order check read the anchor checkout's git, not the cwd's.
# Check 5 alone, with ready-go.sh stubbed (a symlinked tree copy whose ready-go.sh prints a pass):
# the real ready-go's check 19 fetches the PR head into the cwd, so only here does the cwd never hold it.
RGK="$tmp/rgk"; mkdir -p "$RGK/scripts/handover/chief-kit"
for rgkd in "$HERE/../.."/*; do [ "$(basename "$rgkd")" = handover ] || ln -s "$rgkd" "$RGK/scripts/$(basename "$rgkd")"; done
for rgkf in "$HERE/.."/*; do [ "$(basename "$rgkf")" = chief-kit ] || ln -s "$rgkf" "$RGK/scripts/handover/$(basename "$rgkf")"; done
for rgkf in "$HERE"/*; do case "$(basename "$rgkf")" in ready-go.sh|delta-class.sh) ;; *) ln -s "$rgkf" "$RGK/scripts/handover/chief-kit/$(basename "$rgkf")" ;; esac; done
# delta-class.sh resolves the verdict scope from its own tree: run the real one, from the real tree
# shellcheck disable=SC2016  # the wrapper's own $@ stays literal
printf '#!/usr/bin/env bash\nexec bash "%s/delta-class.sh" "$@"\n' "$HERE" > "$RGK/scripts/handover/chief-kit/delta-class.sh"
printf '#!/usr/bin/env bash\nprintf "TRUST: hit scripts/ci/x.sh\\nREADY-GO PASS\\n"\n' > "$RGK/scripts/handover/chief-kit/ready-go.sh"
check "8478 check 5 alone: the cwd does not hold the head" "$(git -C "$READY_REPO" cat-file -e "$ASIDE^{commit}" 2>/dev/null && echo yes || echo no)" "no"
gofresh; verdict qj "**GO** for head \`$NDOC2\`."
rgk_keep="$SCRIPT"; SCRIPT="$RGK/scripts/handover/chief-kit/auto-go.sh"
drun "$ASIDE"; would "8478 check 5 alone classifies the delta in the anchor checkout (the cwd never holds the head)" "$ASIDE"
SCRIPT="$rgk_keep"
# the two rows below run the real ready-go: its check 19 fetches the head as GitHub serves it, refs/pull/77/head
git -C "$SIDE" push -q "$READY_REPO/.git/ready-pass-origin.git" "$ASIDE:refs/pull/77/head"
gofresh; verdict qj "**GO** for head \`$NDOC2\`."
drun "$ASIDE"; would "8478 the delta is classified in the anchor checkout (a head only it holds)" "$ASIDE"
gofresh; verdict qj "**GO** for head \`$NDOC2\`."; verdict qn "**NO-GO** for head \`$ASIB\`."
drun "$ASIDE"; would "8478 the NO-GO order is read in the anchor checkout (a NO-GO beside the judged head)" "$ASIDE"
# a git error ordering a NO-GO head refuses, naming the git exit
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`dead00000000000000000000000000000000beef\`."
hrun "$NDOC"; esc "8478 git rc 128 ordering a NO-GO head" 5
contains "8478 git rc 128: the refusal names the git exit" "$OUT" "git exit 128"
# a NO-GO at an ancestor of the judged head does not stop the carry
gofresh; verdict qj "**GO** for head \`$NDOC\`."; verdict qn "**NO-GO** for head \`$JUDGED\`."
hrun "$NDOC2"; sent "8478 a NO-GO at an ancestor of the judged head" "$NDOC2" qj
# a retry that finds the no-op record at the head: audit delta none
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; noop "$NDOC" "$JUDGED"
hrun "$NDOC"; sent "8478 a GO at the head resting on a no-op record" "$NDOC" qj
check    "8478 a GO at the head resting on a no-op record: audit delta none" "$(q .delta)" "none"
# a chain of exactly 8 hops passes
gofresh; verdict qj "**GO** for head \`$JUDGED\`."
noop "$NDOC" "$JUDGED"; noop "$NDOC2" "$NDOC"; noop "${CH[0]}" "$NDOC2"; noop "${CH[1]}" "${CH[0]}"; noop "${CH[2]}" "${CH[1]}"
noop "${CH[3]}" "${CH[2]}"; noop "${CH[4]}" "${CH[3]}"; noop "${CH[5]}" "${CH[4]}"
drun "${CH[5]}"; would "8478 a no-op chain of exactly 8 hops" "${CH[5]}"
# a cycle in the delta-judged: records refuses
gofresh; noop "$NDOC" "$NDOC2"; noop "$NDOC2" "$NDOC"
hrun "$NDOC2"; esc "8478 a cycle of no-op records" 5
contains "8478 a cycle of no-op records: the refusal says so" "$OUT" "cycle"
# an unreadable no-op record on the chain refuses, naming it (not the later NO-GO scan)
# (the judge's file sorts before the record, so the GO line is read before sed meets the directory)
gofresh; verdict qj "**GO** for head \`$JUDGED\`." 77 a-judge-qj; mkdir -p "$VDIR/qj/delta-noop-$JUDGED.md"
hrun "$NDOC"; esc "8478 an unreadable no-op record" 5
contains "8478 an unreadable no-op record: the refusal names it" "$OUT" "cannot read the delta no-op record"
# a NO-GO for one judged head does not refuse a carry another judged head allows
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qj "**GO** for head \`$J3\`." 77 judge-qj-j3; verdict qn "**NO-GO** for head \`$NDOC\`."
hrun "$J3C"; sent "8478 a NO-GO after one judged head, another judged head carries" "$J3C" qj
# a NO-GO at or after any hop of the chain refuses, not only at the root
gofresh; verdict qj "**GO** for head \`$NDOC\`."; noop "$PSIB" "$NDOC"; noop "$PX" "$PSIB"; verdict qn "**NO-GO** for head \`$PSIB\`."
hrun "$PX"; esc "8478 a NO-GO at a middle hop of the chain" 5
contains "8478 a NO-GO at a middle hop: the refusal names the NO-GO" "$OUT" "holds a NO-GO"
# a real GO at the head is not vetoed through a stale no-op record
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; noop "$NDOC" "$JUDGED"; verdict qn "**NO-GO** for head \`$JUDGED\`."
verdict qj "**GO** for head \`$NDOC\`." 77 judge-qj-ndoc
hrun "$NDOC"; sent "8478 a real GO at the head beside a stale no-op record" "$NDOC" qj
check    "8478 a real GO at the head: audit delta null" "$(q .delta)" "null"
# the root of a no-op chain must hold a real, signed GO of that qid
gofresh; noop "$NDOC" "$JUDGED"; noop "$JUDGED" ""
hrun "$NDOC"; esc "8478 a no-op chain whose root holds only a no-op record" 5
contains "8478 a root with no real GO: the refusal says so" "$OUT" "no real"
gofresh; verdict qj "**GO** for head \`$JUDGED\`." 77 judge-qj 0; noop "$NDOC" "$JUDGED"
hrun "$NDOC"; esc "8478 a no-op chain whose root GO is unsigned" 5
# a carry never starts from a no-op record: HB sorts before JUDGED and rests on it, a later push HBN carries from the real GO,
# in the dry run and in the real run alike
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; noop "$HB" "$JUDGED"
drun "$HBN"; would "8717 a no-op head that sorts before the real GO head does not take the carry (dry run)" "$HBN"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; noop "$HB" "$JUDGED"
hrun "$HBN"; sent "8717 a no-op head that sorts before the real GO head does not take the carry (real run)" "$HBN" qj
# usage names --dry-run as optional
rawrun; contains "8478 usage shows [--dry-run]" "$OUT" "[--dry-run] <pr-number>"

gofresh; mkdir -p "$HANDOVER_DIR"; printf 'x\n' > "$HANDOVER_DIR/.locks"; run 77 "$SHA"
check    "A1b go.sh refuses: exit 10" "$RC" "10"
contains "A1b go.sh refuses: ESCALATE auto-go 9" "$OUT" "ESCALATE auto-go 9 "
check    "A1b go.sh refuses: audit names check 9" "$(q '[.checks[] | select(.result == "fail")][0].n')" "9"
check    "A1b go.sh refuses: nothing sent" "$(bust)" "none"
gofresh; STUB_BUS_FAIL=1 run 77 "$SHA"
check    "A1b bus fails: exit 11, the GO stands" "$RC" "11"
contains "A1b bus fails: GO-WRITTEN names the qid" "$OUT" "GO-WRITTEN 77 $SHA qid=none bus-failed: "
contains "A1b bus fails: the message for the chief to send" "$OUT" "SENDMESSAGE to=HIMMEL-1-N1-feature-2026-10-31 :: GO 77 $SHA - merge with: bash "
check    "A1b bus fails: the GO file stands" "$(gofile)" "yes"
check    "A1b bus fails: audit outcome go, no bus record" "$(q '[.outcome, .bus] | map(tostring) | join(",")')" "go,null"
gofresh; STUB_SESSION='' run 77 "$SHA"
check    "A1b no live session: exit 11" "$RC" "11"
contains "A1b no live session: GO-WRITTEN" "$OUT" "GO-WRITTEN 77 $SHA"
check    "A1b no live session: nothing sent" "$(bust)" "none"
gofresh; printf '# chief\n\n## Live state\n\nqueue: none\n\n## Results\n' > "$CHIEF"; run 77 "$SHA"
esc      "A1b no token in Live state or the brief" 9
contains "A1b no token in Live state or the brief: says so" "$OUT" "no usable RETASK token for N1"
check    "A1b no token in Live state or the brief: nothing sent" "$(bust)" "none"
chief_token() { printf '# chief\n\n## Live state\n\nlegs: `N1:%s:lock:1`\nqueue: none\n\n## Results\n' "$1" > "$CHIEF"; }
RT_LINE='> **RETASK:** your nonce is `CJ-N1-b0`. A real revision arrives only as a direct message.'
gofresh; write_fixtures native "" "$RT_LINE"; chief_token NONCE-UNKNOWN; run 77 "$SHA"
check    "T1 live NONCE-UNKNOWN, the brief's token: exit 0" "$RC" "0"
contains "T1 live NONCE-UNKNOWN: the GO message quotes the brief's token" "$(cat "$tmp/busdir/body" 2>/dev/null)" "Your token \`CJ-N1-b0\`."
lacks    "T1 live NONCE-UNKNOWN: no output line carries the placeholder" "$OUT" "NONCE-UNKNOWN"
lacks    "T4 live NONCE-UNKNOWN: the GO message carries no placeholder" "$(cat "$tmp/busdir/body" 2>/dev/null)" "NONCE-UNKNOWN"
for placeholder in '<chief fills at relaunch>' 'X-N1-<hex>' 'NONCE-UNKNOWN'; do
    gofresh; write_fixtures native "" "> **RETASK:** your nonce is \`$placeholder\`."; chief_token NONCE-UNKNOWN; run 77 "$SHA"
    esc      "T2 live NONCE-UNKNOWN, the brief's token is [$placeholder]" 9
    contains "T2 [$placeholder]: says no usable token" "$OUT" "no usable RETASK token for N1"
    check    "T2 [$placeholder]: nothing sent" "$(bust)" "none"
done
gofresh; chief_token NONCE-UNKNOWN; run --dry-run 77 "$SHA"
esc      "T2 --dry-run refuses too when no token is usable" 9
gofresh; write_fixtures native "" ""; printf '# worker\n\n> **Completes ticket:** no\n\n## Results\n> **RETASK:** your nonce is `CJ-N1-b0`.\n' > "$WORKER"; chief_token NONCE-UNKNOWN; run 77 "$SHA"
esc      "T3 a token only below ## Results counts as none" 9

# 8g2. go.sh exits 0 but its last line is not the GO path: ESCALATE 9, naming the path a GO file may stand at, and the audit row records it
# a symlinked copy of the tree whose go.sh runs the real one and then prints one more line
FK="$tmp/fk"; mkdir -p "$FK/scripts/handover/chief-kit"
for fkd in "$HERE/../.."/*; do [ "$(basename "$fkd")" = handover ] || ln -s "$fkd" "$FK/scripts/$(basename "$fkd")"; done
for fkf in "$HERE/.."/*; do [ "$(basename "$fkf")" = chief-kit ] || ln -s "$fkf" "$FK/scripts/handover/$(basename "$fkf")"; done
for fkf in "$HERE"/*; do [ "$(basename "$fkf")" = go.sh ] || ln -s "$fkf" "$FK/scripts/handover/chief-kit/$(basename "$fkf")"; done
# shellcheck disable=SC2016  # the stub's own $@ and $? must stay literal
printf '#!/usr/bin/env bash\nbash "%s/go.sh" "$@"; rc=$?; echo "go: trailing note"; exit $rc\n' "$HERE" > "$FK/scripts/handover/chief-kit/go.sh"
gofresh
OUT=$(bash "$FK/scripts/handover/chief-kit/auto-go.sh" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check    "A1b go.sh exit 0, GO path not last: exit 10" "$RC" "10"
contains "A1b go.sh exit 0, GO path not last: ESCALATE auto-go 9" "$OUT" "ESCALATE auto-go 9 "
contains "A1b go.sh exit 0, GO path not last: names where a GO file may stand" "$OUT" ".locks/go/77.$SHA"
check    "A1b go.sh exit 0, GO path not last: the GO file stands" "$(gofile)" "yes"
contains "A1b go.sh exit 0, GO path not last: the audit row records the path" "$(q '.go_file')" ".locks/go/77.$SHA"

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

reset
TTREAD=ghp_READTOKEN0123456789
mkdir -p "$tmp/ttroot" "$tmp/emptyroot" "$tmp/tt" "$tmp/himmelcfg"
printf 'himmel_github_token_vm2=%s\n' "$TTREAD" > "$tmp/ttroot/.env"
: > "$tmp/emptyroot/.env"
ln -s "$HERE/fixtures/gh-two-token-stub.sh" "$tmp/tt/gh"
# shellcheck disable=SC2016  # the delegate's own ${PATH#...} and "$@" must stay literal
printf '#!/usr/bin/env bash\nPATH="${PATH#%s:}" exec "%s/bin/gh" "$@"\n' "$tmp/tt" "$tmp" > "$tmp/ttdelegate"
chmod +x "$tmp/ttdelegate"
unset GH_TOKEN GITHUB_TOKEN himmel_github_token_vm2 CREDENTIALS_DIRECTORY
TTLOG="$tmp/tt.log"
ttn() { grep -c -E -- "$1" "$TTLOG"; }
ttseen() { [ "$(ttn "$1")" -ge 1 ] && echo yes || echo no; }
ttrun() {
    local root="$1"; shift
    : > "$TTLOG"
    OUT=$(env "$@" GH_READ_ENV_ROOT="$root" HIMMEL_SECRETS_KEYRING=off HIMMEL_CONFIG_DIR="$tmp/himmelcfg" PATH="$tmp/tt:$PATH" \
        GH_STUB_DELEGATE="$tmp/ttdelegate" GH_STUB_READ_TOKEN="$TTREAD" GHLOG="$TTLOG" \
        bash "${AG_SCRIPT:-$SCRIPT}" --doc "$CHIEF" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA" 2>&1); RC=$?
}
tt_main_reads_besides_the_crd_branch_read() { grep '^tok=main ' "$TTLOG" | grep -vc -e 'argv=pr view 77 --json headRefName -q .headRefName' -e 'argv=api repos/{owner}/{repo}/branches/main/protection/required_status_checks'; }
ttrun "$tmp/ttroot" GH_STUB_MAINFAIL=rate GH_STUB_MAINFAIL_BUCKET=core
check    "8691 main REST core spent: exit 0" "$RC" "0"
check    "8691 main REST core spent: exactly WOULD-GO <pr> <head>" "$OUT" "WOULD-GO 77 $SHA"
check    "8691 main REST core spent: no read rides the main token but cr-disposition's branch read, its ready-go child's reads included" "$(tt_main_reads_besides_the_crd_branch_read)" "0"
check    "8691 main REST core spent: the repo name read logs tok=read" "$(ttseen '^tok=read argv=repo view --json nameWithOwner')" "yes"
check    "8691 main REST core spent: the PR state read logs tok=read" "$(ttseen '^tok=read argv=pr view 77 -R o/r --json state,headRefOid,baseRefName')" "yes"
check    "10828 the default-branch read names the repo and logs tok=read" "$(ttseen '^tok=read argv=repo view o/r --json defaultBranchRef')" "yes"
check    "8691 main REST core spent: the title read logs tok=read" "$(ttseen '^tok=read argv=pr view 77 -R o/r --json title')" "yes"
check    "8691 main REST core spent: the file listing read logs tok=read" "$(ttseen '^tok=read argv=api repos/o/r/pulls/77/files')" "yes"
check    "8691 main REST core spent: the commit list read logs tok=read" "$(ttseen '^tok=read argv=api repos/o/r/pulls/77/commits')" "yes"
ttrun "$tmp/ttroot" GH_STUB_MAINFAIL=rate
check    "8691 main spent in every bucket, read token alive: exit 0" "$RC" "0"
check    "8691 main spent in every bucket, read token alive: exactly WOULD-GO <pr> <head>" "$OUT" "WOULD-GO 77 $SHA"
check    "8691 main spent in every bucket: the classic-protection read is the one main call, once" "$(grep -cF 'tok=main argv=api repos/{owner}/{repo}/branches/main/protection/required_status_checks' "$TTLOG")" "1"
check    "8691 main spent in every bucket: cr-disposition's branch read logs tok=read" "$(ttseen '^tok=read argv=pr view 77 --json headRefName -q .headRefName')" "yes"
check    "8691 main spent in every bucket: no read rides the main token" "$(grep '^tok=main ' "$TTLOG" | grep -vc 'argv=api repos/{owner}/{repo}/branches/main/protection/required_status_checks')" "0"
ttrun "$tmp/emptyroot"
check    "8691 control, no read token: exit 0" "$RC" "0"
check    "8691 control, no read token: exactly WOULD-GO <pr> <head>" "$OUT" "WOULD-GO 77 $SHA"
check    "8691 control, no read token: no call logs tok=read" "$(ttn '^tok=read ')" "0"
check    "8691 control, no read token: the commit list read logs tok=main" "$(ttseen '^tok=main argv=api repos/o/r/pulls/77/commits')" "yes"

ttrun "$tmp/ttroot" GH_READ_QUIET=1 GH_READ_OFF=1 GH_READ_NO_MAIN_FALLBACK=1
check    "8691 GH_READ_QUIET, GH_READ_OFF and GH_READ_NO_MAIN_FALLBACK inherited: exit 0, not 96" "$RC" "0"
check    "8691 GH_READ_* inherited: exactly WOULD-GO <pr> <head>" "$OUT" "WOULD-GO 77 $SHA"
check    "8691 GH_READ_* inherited: the reads still ride the read token" "$(ttseen '^tok=read argv=api repos/o/r/pulls/77/commits')" "yes"
CA="$tmp/ctlag"; mkdir -p "$CA/scripts/handover/chief-kit"
for cad in "$HERE/../.."/*; do [ "$(basename "$cad")" = handover ] || ln -s "$cad" "$CA/scripts/$(basename "$cad")"; done
for caf in "$HERE/.."/*; do [ "$(basename "$caf")" = chief-kit ] || ln -s "$caf" "$CA/scripts/handover/$(basename "$caf")"; done
for caf in "$HERE"/*; do [ "$(basename "$caf")" = auto-go.sh ] || ln -s "$caf" "$CA/scripts/handover/chief-kit/$(basename "$caf")"; done
grep -v '^unset _GHR_LOAD_DOTENV ' "$SCRIPT" > "$CA/scripts/handover/chief-kit/auto-go.sh"
AG_SCRIPT="$CA/scripts/handover/chief-kit/auto-go.sh" ttrun "$tmp/ttroot" GH_READ_OFF=1
check    "8691 control without the unset line: GH_READ_OFF fails the reads (not WOULD-GO)" "$([ "$OUT" = "WOULD-GO 77 $SHA" ] && echo would-go || echo refused)" "refused"
check    "8691 control without the unset line: the refusal is ESCALATE auto-go 3 (ready-go failed)" "$(printf '%s' "$OUT" | grep -c 'ESCALATE auto-go [0-9]')" "1"
unset AG_SCRIPT
reset

orun() { STUB_PR_HEAD=$1 READY_STUB_HEAD=$1 run "${@:2}" 77 "$1"; }
AROOT=$(git -C "$ANCHOR" rev-list --max-parents=0 HEAD)
MISS=$(printf 'deadbeef%.0s' 1 2 3 4 5)
vat() {
    local vf="$VDIR/$1/judge-$1.md" vmac
    mkdir -p "$VDIR/$1"
    printf '# VERDICT %s - judge\nwritten-at: %s\n\n## Reason (scope asked)\n\nq\n\n## Verdict\n\n%s\n\npr: %s\n\nreason\n\n## Evidence checked\n\ne\n%s\n' "$1" "$3" "$2" "${4:-77}" "${5:-}" > "$vf"
    # read-sink-ok: $vf is a verdict file this test just wrote under its own temp dir
    vmac="$(bash -c '. "$1"; go_verdict_mac "$2" "$3" "$4"' _ "$HERE/../../lib/go-gate.sh" "$VSCOPE" "$1" "judge-$1" < "$vf")" || { echo "FAIL: cannot sign $vf" >&2; return 1; }
    printf 'mac: %s\n' "$vmac" >> "$vf"
}
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."
orun "$NDOC"
esc      "11022 an earlier NO-GO, a new head, no new verdict" 5
contains "11022 the refusal names the NO-GO qid" "$OUT" "verdict qn ruled NO-GO"
contains "11022 the refusal names the head the NO-GO was ruled at" "$OUT" "${JUDGED:0:8}"
gofresh; verdict qn "**NO-GO** for head \`$NDOC\`."
orun "$NDOC"
esc      "11022 a NO-GO at the current head" 5
contains "11022 a NO-GO at the current head: the refusal names the qid" "$OUT" "qn"
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."; verdict qg "**GO** for head \`$NDOC\`."
orun "$JUDGED"
esc      "11022 a force-push back to the NO-GO head" 5
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."; verdict qg "**GO** for head \`$NDOC\`."
orun "$PSIB"
esc      "11022 a head that descends the NO-GO head but not the GO head" 5
contains "11022 a head off the GO line: the refusal names the qid" "$OUT" "verdict qn ruled NO-GO"
gofresh; verdict qn "no verdict line here"
orun "$NDOC"
esc      "11022 an unparsed verdict of the PR refuses an ordinary PR" 5
gofresh; mkdir -p "$VDIR/ql"
# shellcheck disable=SC2016  # the backticks are literal text in the verdict file
printf '# VERDICT ql - judge\n\n## Verdict\n\n**NO-GO** for head `%s`.\n\nreason\n' "$NDOC" > "$VDIR/ql/judge-ql.md"
orun "$NDOC"
esc      "11022 a legacy NO-GO at the head with no pr: line" 5
contains "11022 a legacy NO-GO: the refusal names the qid" "$OUT" "verdict ql refuses"
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`." 78
orun "$NDOC"
sent     "11022 a NO-GO of another PR: the ordinary GO" "$NDOC" none
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."; verdict qg "**GO** for head \`$NDOC\`."
orun "$NDOC2"
sent     "11022 a later real GO clears the NO-GO, a newer head has no verdict" "$NDOC2" none
lacks    "11022 cleared: a plain GO carries no trust-reviewed line" "$(cat "$HANDOVER_DIR/.locks/go/77.$NDOC2" 2>/dev/null)" "trust-reviewed="
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."; verdict qg "**GO** for head \`$NDOC\`." 77 judge-qg 0
orun "$NDOC2"
esc      "11022 an unsigned GO does not clear a NO-GO" 5
contains "11022 an unsigned GO does not clear a NO-GO: the refusal names the NO-GO" "$OUT" "verdict qn ruled NO-GO"
gofresh; verdict qn "**NO-GO** for head \`$JUDGED\`."; vat qg "**GO** for head \`$NDOC\`." 2026-11-24T10:00:00Z 78 "pr: 77"
orun "$NDOC2"
esc      "11022 a GO naming another PR that quotes pr: 77 does not clear a NO-GO" 5
contains "11022 a GO naming another PR does not clear a NO-GO: the refusal names the NO-GO" "$OUT" "verdict qn ruled NO-GO"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$NDOC\`."
noop "$NDOC2" "$JUDGED"
orun "$NDOC2"
esc      "11022 a no-op GO does not clear a NO-GO between the judged head and its own" 5
gofresh; verdict qn "**NO-GO** for head \`$MISS\`."
orun "$NDOC"
esc      "11022 a NO-GO on a missing commit, no GO" 5
contains "11022 a NO-GO on a missing commit: the refusal names the qid" "$OUT" "verdict qn ruled NO-GO"
gofresh; verdict qn "**NO-GO** for head \`$MISS\`."; verdict qg "**GO** for head \`$NDOC\`."
orun "$NDOC" --dry-run
would    "11022 a NO-GO on a missing commit and a real GO at the head" "$NDOC"
check    "11022 a NO-GO on a missing commit and a real GO at the head: audit qid" "$(q .qid)" "qg"
gofresh; verdict qn "**NO-GO** for head \`$PSIB\`."; verdict qg "**GO** for head \`$NDOC\`."
orun "$NDOC"
sent     "11022 a standing NO-GO and a GO at the head" "$NDOC" qg
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$NDOC\`."
orun "$NDOC2"
esc      "11022 a NO-GO after the judged head refuses" 5
contains "11022 a NO-GO after the judged head: the refusal names the qid" "$OUT" "verdict qn ruled NO-GO"
contains "11022 a NO-GO after the judged head: the refusal names its head" "$OUT" "${NDOC:0:8}"
gofresh; verdict qj "**GO** for head \`$JUDGED\`."; verdict qn "**NO-GO** for head \`$AROOT\`."
orun "$NDOC" --dry-run
would    "11022 a standing NO-GO off the judged line, a GO that carries" "$NDOC"
check    "11022 the carry: audit qid" "$(q .qid)" "qj"
check    "11022 the carry: audit delta none" "$(q .delta)" "none"
gofresh; verdict q1 "**NO-GO** for head \`$PSIB\`."; verdict q2 "**NO-GO** for head \`$PX\`."
orun "$NDOC"
esc      "11022 two standing NO-GOs" 5
contains "11022 two standing NO-GOs: the refusal names the newest" "$OUT" "verdict q2 ruled NO-GO"
lacks    "11022 two standing NO-GOs: not the older" "$OUT" "verdict q1 ruled NO-GO"
gofresh; verdict q1 "**NO-GO** for head \`$JUDGED\`."; verdict qg "**GO** for head \`$NDOC\`."; verdict q2 "**NO-GO** for head \`$ASIB\`."
orun "$NDOC2"
esc      "11022 one NO-GO cleared and one standing" 5
contains "11022 one cleared and one standing: the refusal names the standing one" "$OUT" "verdict q2 ruled NO-GO"
lacks    "11022 one cleared and one standing: not the cleared one" "$OUT" "verdict q1 ruled NO-GO"
gofresh; vat qa "**NO-GO** for head \`$JUDGED\`." 2026-11-24T10:00:00Z; vat qb "**GO** for head \`$JUDGED\`." 2026-11-24T11:00:00Z
orun "$NDOC"
sent     "11022 a same-head re-judge: the later GO carries" "$NDOC" qb
gofresh; vat qa "**NO-GO** for head \`$JUDGED\`." 2026-11-24T12:00:00Z; vat qb "**GO** for head \`$JUDGED\`." 2026-11-24T11:00:00Z
orun "$NDOC"
esc      "11022 a same-head re-judge: a NO-GO written after the GO refuses" 5
gofresh

REALTREE="$(cd "$HERE/../../.." && pwd)"; AGT="$tmp/agtree"
mkdir -p "$AGT/scripts/handover/chief-kit"
for e in "$REALTREE"/scripts/*; do [ "${e##*/}" = handover ] || ln -s "$e" "$AGT/scripts/${e##*/}"; done
for e in "$REALTREE"/scripts/handover/*; do [ "${e##*/}" = chief-kit ] || ln -s "$e" "$AGT/scripts/handover/${e##*/}"; done
for e in "$REALTREE"/scripts/handover/chief-kit/*; do [ "${e##*/}" = go.sh ] || ln -s "$e" "$AGT/scripts/handover/chief-kit/${e##*/}"; done
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\nexec bash "%s" "$@"\n' "$tmp/ag-argv.log" "$REALTREE/scripts/handover/chief-kit/go.sh" > "$AGT/scripts/handover/chief-kit/go.sh"
gofresh; rm -f "$tmp/ag-argv.log"
OUT=$(bash "$AGT/scripts/handover/chief-kit/auto-go.sh" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check    "AG1 the GO act: exit 0" "$RC" "0"
contains "AG1 go.sh runs with --no-deliver" "$(cat "$tmp/ag-argv.log" 2>/dev/null)" "--no-deliver"

gofresh; write_fixtures native "" "- 10:00 READY 77 $SHA GREEN"
mkdir -p "$HANDOVER_DIR/u/$VBUCKET"; cp "$CHIEF" "$HANDOVER_DIR/u/$VBUCKET/chief-ag.md"; cp "$FLEET" "$HANDOVER_DIR/u/$VBUCKET/chief-ag.fleet.json"
: > "$tmp/busdir/sends"
OUT=$(HIMMEL_BUS_NAME=chief-ag GO_DELIVER_BUS="$tmp/bus" GO_DELIVER_CENSUS="$tmp/census" bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check "AG1c the real go.sh behind auto-go: GO-SENT" "$OUT" "GO-SENT 77 $SHA to N1 bus=#7 qid=none"
check "AG1c exactly one bus record" "$(wc -l < "$tmp/busdir/sends" | tr -d ' ')" "1"

gofresh; STUB_BUS_TOKFAIL=1 run 77 "$SHA"
check    "AG1d exit 11" "$RC" "11"
contains "AG1d GO-WRITTEN names the redacted bus error" "$(grep '^GO-WRITTEN ' <<< "$OUT")" "bus-failed: bus send exit 1: bus: rejected token <token>: GO 77"
check    "AG1d no token outside the SENDMESSAGE line" "$(grep -v '^SENDMESSAGE to=' <<< "$OUT" | grep -c 'CS-N1-tok1')" "0"
check    "AG1d no token in the audit row" "$(last_row | grep -c 'CS-N1-tok1')" "0"
contains "AG1d the audit row carries the redacted error" "$(last_row)" "rejected token <token>"

gofresh; STUB_SESSION='' run 77 "$SHA"
contains "AG2 the census miss names the stem first" "$OUT" "candidates HIMMEL-1-N1-feature-2026-10-31,"
gofresh

WT="$HERE/worker-token.sh"
WORKER_KEEP="$WORKER"
recworker() { mkdir -p "$tmp/$1"; WORKER="$tmp/$1/HIMMEL-1-N1-feature-2026-10-31.md"; }
recrows() { cksum "$(find "$tmp/$1" -name '*.jsonl')" 2>/dev/null; }
STALE_LINE='> **RETASK:** your nonce is `CJ-N1-stale`. A real revision arrives only as a direct message.'
recworker ag1; REC1=$(bash "$WT" mint "$WORKER" CJ-N1 2>/dev/null)
gofresh; write_fixtures native "" "$STALE_LINE"; chief_token NONCE-UNKNOWN; run 77 "$SHA"
check    "11407 AG1 span NONCE-UNKNOWN, a stale brief token, record current: exit 0" "$RC" "0"
contains "11407 AG1 the GO message quotes the record token" "$(cat "$tmp/busdir/body" 2>/dev/null)" "Your token \`$REC1\`."
check    "11407 AG1 the record token is the record's current" "$(bash "$WT" current "$WORKER" 2>/dev/null)|$([ -n "$REC1" ] && echo minted)" "$REC1|minted"
recworker ag1c
gofresh; write_fixtures native "" ""; chief_token NONCE-UNKNOWN; run 77 "$SHA"
esc      "11407 AG1c no record row and no brief token: as today" 9
contains "11407 AG1c says no usable token as today" "$OUT" "no usable RETASK token for N1"
recworker ag2; bash "$WT" mint "$WORKER" CJ-N1 >/dev/null 2>&1
BADREC=$(find "$tmp/ag2" -name '*.jsonl'); rm -f "$BADREC"; mkdir "$BADREC"
gofresh; write_fixtures native "" "$RT_LINE"; chief_token NONCE-UNKNOWN; run 77 "$SHA"
esc      "11407 AG2 an unreadable record" 9
contains "11407 AG2 check 9 names the record" "$OUT" "the token record for N1 is unreadable"
check    "11407 AG2 nothing sent" "$(bust)" "none"
recworker ag3; bash "$WT" mint "$WORKER" CJ-N1 >/dev/null 2>&1; REC3=$(recrows ag3)
gofresh; write_fixtures native "" "$STALE_LINE"; chief_token NONCE-UNKNOWN
OUT=$(HIMMEL_CONSOLE_LEG=1 env -u AUTO_GO_ANCHOR -u AUTO_GO_BUS -u AUTO_GO_CENSUS -u GH_CMD -u JIRA_CMD -u HIMMEL_LEGACY_NAMES bash "$SCRIPT" --doc "$CHIEF" --fleet "$FLEET" --worker N1 77 "$SHA" 2>&1); RC=$?
check    "11407 AG3 HIMMEL_CONSOLE_LEG=1 with a record: exit 3 as today, the record untouched" "$RC $(recrows ag3)|$([ -n "$REC3" ] && echo minted)" "3 $REC3|minted"
WORKER="$WORKER_KEEP"
gofresh
SPY="$tmp/spy"; mkdir -p "$SPY/scripts/handover/chief-kit"
for fkd in "$HERE/../.."/*; do [ "$(basename "$fkd")" = handover ] || ln -s "$fkd" "$SPY/scripts/$(basename "$fkd")"; done
for fkf in "$HERE/.."/*; do [ "$(basename "$fkf")" = chief-kit ] || ln -s "$fkf" "$SPY/scripts/handover/$(basename "$fkf")"; done
for fkf in "$HERE"/*; do [ "$(basename "$fkf")" = go-deliver.sh ] || ln -s "$fkf" "$SPY/scripts/handover/chief-kit/$(basename "$fkf")"; done
printf '. %q || return 1\ngd_worker_token() { printf "%%s\\n" "${4:-<none>}" >> %q; return 1; }\n' "$HERE/go-deliver.sh" "$tmp/spy-root.log" > "$SPY/scripts/handover/chief-kit/go-deliver.sh"
OUT=$(bash "$SPY/scripts/handover/chief-kit/auto-go.sh" --doc "$CHIEF" --fleet "$FLEET" --worker N1 --dry-run 77 "$SHA" 2>&1); RC=$?
EXPROOT=$( . "$HERE/../../lib/handover-path.sh" && . "$HERE/../../lib/go-gate.sh" && go_resolve_root "$ANCHOR" )
check    "11407 AG4 auto-go.sh hands gd_worker_token its own resolved GO root" "$(sort -u "$tmp/spy-root.log" 2>/dev/null)|$([ -n "$EXPROOT" ] && echo resolved)" "$EXPROOT|resolved"
gofresh

if [ "$fails" -eq 0 ]; then echo "test-auto-go.sh: all rows passed"; exit 0; fi
echo "test-auto-go.sh: $fails row(s) failed: $failrows" >&2
exit 1
