#!/usr/bin/env bash
set -uo pipefail

unset CR_MERGE_GATE_OK CI_MERGE_GATE_OK CR_PROFILE CR_APP GH_ADMIN_MERGE_OK FORGE GH_CMD

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_MERGE="$SCRIPT_DIR/pr-merge.sh"

BASE="$(mktemp -d "${TMPDIR:-/tmp}/pr-merge-bb.XXXXXX")" || exit 1
trap 'rm -rf "$BASE"' EXIT
export HOME="$BASE/home"; mkdir -p "$HOME"
export HIMMEL_CONFIG_DIR="$BASE/himmelcfg"; mkdir -p "$HIMMEL_CONFIG_DIR"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1" >&2; [ $# -ge 2 ] && printf '       %s\n' "$2" >&2; }

STUB="$BASE/bb-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${BB_LOG:?}"
case "$1 $2" in
    "pr list") echo '[{"id":7,"title":"t","state":"OPEN","source_branch":"handover/x","url":"u"}]' ;;
    "pr get")
        [ "${STUB_GET_FAIL:-0}" = "1" ] && { echo "bb: 500" >&2; exit 1; }
        n=$(cat "$BB_LOG.get" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$BB_LOG.get"
        head="${STUB_HEAD:-aaaa1111}"
        [ "$n" -ge 2 ] && [ -n "${STUB_HEAD_AFTER:-}" ] && head="$STUB_HEAD_AFTER"
        [ "${STUB_HEAD_EMPTY:-0}" = "1" ] && head=""
        printf '{"id":7,"title":"feat: x","state":"OPEN","source_branch":"handover/x","destination_branch":"main","head_commit":"%s"}\n' "$head" ;;
    "pr statuses")
        [ "${STUB_STATUSES_FAIL:-0}" = "1" ] && { echo "bb: 500" >&2; exit 1; }
        if [ -n "${STUB_STATUSES:-}" ]; then echo "$STUB_STATUSES"
        else echo '{"statuses":[{"key":"pipeline","name":"Pipeline","state":"SUCCESSFUL"}],"truncated":false,"pages":1}'; fi ;;
    "pr comments")
        [ "${STUB_COMMENTS_FAIL:-0}" = "1" ] && { echo "bb: 500" >&2; exit 1; }
        if [ -n "${STUB_THREADS:-}" ]; then echo "$STUB_THREADS"
        else echo '{"threads":[],"truncated":false,"pages":1}'; fi ;;
    "pr merge") echo '{"id":7,"state":"MERGED"}' ;;
    *) echo "bb-stub: unrecorded call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUB"

REPO="$BASE/repo"
git init -q -b handover/x "$REPO"
git -C "$REPO" remote add origin https://bitbucket.org/ws/repo.git
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init

merged() { grep -q '^pr merge 7' "$BB_LOG" 2>/dev/null; }

run_case() {
    local name="$1" want="$2" wantmerge="$3" wantmsg="${4:-}" rc=0
    export BB_LOG="$BASE/bb-$name.log"; : > "$BB_LOG"; rm -f "$BB_LOG.get"
    ( cd "$REPO" && BITBUCKET_CMD="$STUB" bash "$PR_MERGE" ) >"$BASE/out-$name" 2>"$BASE/err-$name" || rc=$?
    local ok=1 why=""
    [ "$rc" = "$want" ] || { ok=0; why="rc=$rc want=$want"; }
    if [ "$wantmerge" = "merged" ]; then merged || { ok=0; why="$why; merge call missing"; }
    else merged && { ok=0; why="$why; merge call was made"; }; fi
    if [ -n "$wantmsg" ] && ! grep -qF -- "$wantmsg" "$BASE/err-$name"; then ok=0; why="$why; stderr lacks '$wantmsg'"; fi
    if [ "$ok" = 1 ]; then pass "$name"; else fail "$name" "$why"; sed 's/^/       err: /' "$BASE/err-$name" >&2; fi
}

echo "TEST: a green Bitbucket PR merges, pinned to the vetted head"
run_case clean-green 0 merged

echo "TEST: CI gate"
STUB_STATUSES='{"statuses":[{"key":"p","name":"Pipeline","state":"FAILED"}],"truncated":false,"pages":1}' \
    run_case red-ci 6 not-merged "failing"
STUB_STATUSES='{"statuses":[{"key":"p","name":"Pipeline","state":"STOPPED"}],"truncated":false,"pages":1}' \
    run_case stopped-ci 6 not-merged
STUB_STATUSES='{"statuses":[{"key":"p","name":"Pipeline","state":"INPROGRESS"}],"truncated":false,"pages":1}' \
    run_case pending-ci 6 not-merged "still running"
STUB_STATUSES='{"statuses":[{"key":"p","name":"Pipeline","state":"SOMETHING_NEW"}],"truncated":false,"pages":1}' \
    run_case unknown-state-ci 6 not-merged
STUB_STATUSES='{"statuses":[{"key":"p","name":"Pipeline","state":"SUCCESSFUL"}],"truncated":true,"pages":20}' \
    run_case truncated-statuses 6 not-merged "cannot certify"
STUB_STATUSES_FAIL=1 run_case statuses-unreadable 6 not-merged "failing closed"
STUB_STATUSES='not json' run_case statuses-garbled 6 not-merged
STUB_STATUSES='{"statuses":[],"truncated":false,"pages":1}' run_case checkless-allowed 0 merged
CI_MERGE_GATE_OK=1 STUB_STATUSES='{"statuses":[{"key":"p","name":"P","state":"FAILED"}],"truncated":false,"pages":1}' \
    run_case ci-bypass 0 merged

echo "TEST: reviewer gate"
STUB_THREADS='{"threads":[{"id":1,"path":"a","line":1,"isResolved":false,"author":"r","body":"fix"}],"truncated":false,"pages":1}' \
    run_case unresolved-thread 5 not-merged "unresolved"
STUB_THREADS='{"threads":[{"id":1,"path":"a","line":1,"isResolved":true,"author":"r","body":"fix"}],"truncated":false,"pages":1}' \
    run_case resolved-thread 0 merged
STUB_THREADS='{"threads":[],"truncated":true,"pages":20}' run_case truncated-threads 5 not-merged "cannot certify"
STUB_COMMENTS_FAIL=1 run_case threads-unreadable 5 not-merged "failing closed"
CR_MERGE_GATE_OK=1 STUB_THREADS='{"threads":[{"id":1,"path":"a","line":1,"isResolved":false,"author":"r","body":"x"}],"truncated":false,"pages":1}' \
    run_case cr-bypass 0 merged
CR_PROFILE=none STUB_THREADS='{"threads":[{"id":1,"path":"a","line":1,"isResolved":false,"author":"r","body":"x"}],"truncated":false,"pages":1}' \
    run_case cr-profile-none 0 merged

echo "TEST: head pin"
STUB_HEAD_AFTER=bbbb2222 run_case head-drift 4 not-merged "moved"
STUB_HEAD_EMPTY=1 run_case head-unreadable 7 not-merged "unbound"
STUB_GET_FAIL=1 run_case pr-get-fails 7 not-merged "unbound"

echo "TEST: a gate blocks before any merge call, and the CLI is asked for the head"
export BB_LOG="$BASE/bb-order.log"; : > "$BB_LOG"; rm -f "$BB_LOG.get"
( cd "$REPO" && BITBUCKET_CMD="$STUB" bash "$PR_MERGE" ) >/dev/null 2>&1
if grep -q '^pr get 7' "$BB_LOG" && grep -q '^pr statuses 7' "$BB_LOG" && grep -q '^pr comments 7' "$BB_LOG"; then
    pass "merge path read head, statuses and threads"
else
    fail "merge path read head, statuses and threads" "log: $(tr '\n' '|' < "$BB_LOG")"
fi

echo "  pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS"
exit 0
