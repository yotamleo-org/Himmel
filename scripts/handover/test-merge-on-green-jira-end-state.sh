#!/usr/bin/env bash
# Jira END STATE after a merge: the ticket's final status and
# fixVersion, read from a STATEFUL stub Jira CLI. test-merge-on-green.sh's stub
# only logs argv, so a wrong end state with a "right" call sequence goes unseen.
#
# Four cases:
#   1 full merge (--jira-transition)      -> Done, held version kept        (green control)
#   2 partial merge (completes-ticket: no) -> status/version untouched + Remaining comment
#   3 versionless ticket                   -> Done + the current version
#   4 In Review ticket through check-ci    -> IN CI, then Done at the merge
#
# The fixture, the gh stub and the check-ci gh stub are lifted at runtime from
# test-merge-on-green.sh / test-check-ci.sh, so they cannot drift from those suites.
# Usage: test-merge-on-green-jira-end-state.sh [<checkout>]
# A checkout argument runs the merge script and check-ci.sh of ANOTHER tree
# (the RED replay at a fix's parent); default is this checkout.
set -uo pipefail

unset ARMAUTOMERGE CR_MERGE_GATE_OK HIMMEL_CONSOLE_LEG HIMMEL_LEG_DOC HIMMEL_CONSOLE_DOC HIMMEL_CONSOLE_NAME HIMMEL_REPO LEG_JIRA_CLI
export JIRA_PROJECT_KEY=HIMMEL CHECK_CI_CACHE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPLAY_TREE="${1:-$REPO_ROOT}"
MOG="$REPLAY_TREE/scripts/handover/merge-on-green.sh"
CHECK_CI="$REPLAY_TREE/scripts/check-ci.sh"
MOG_TEST="$SCRIPT_DIR/test-merge-on-green.sh"
CHECK_CI_TEST="$REPO_ROOT/scripts/test-check-ci.sh"
# shellcheck source=scripts/lib/timeout-bin.sh
. "$REPO_ROOT/scripts/lib/timeout-bin.sh"

SUITE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/mog-jira-end.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if [ -z "$SUITE_TMP" ] || [ ! -d "$SUITE_TMP" ]; then echo "FAIL: no suite tmp" >&2; exit 1; fi
trap 'chmod -R u+rwX "$SUITE_TMP"; rm -rf "$SUITE_TMP"' EXIT
export TMPDIR="$SUITE_TMP"
# the console-GO key lives under $HOME/.config/himmel: keep it off the real HOME
export HOME="$SUITE_TMP/home"; mkdir -p "$HOME"

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

for f in "$MOG" "$CHECK_CI" "$MOG_TEST" "$CHECK_CI_TEST"; do
    [ -f "$f" ] || { echo "FAIL: missing $f" >&2; exit 1; }
done

# lift mog_build_fixture (and the green main window it relies on) from the merge suite
eval "$(sed -n '/^mog_build_fixture() {/,/^}/p' "$MOG_TEST")"
declare -F mog_build_fixture >/dev/null || { echo "FAIL: could not lift mog_build_fixture" >&2; exit 1; }
MOG_RUN_GREEN=$(sed -n "s/^MOG_RUN_GREEN='\(.*\)'\$/\1/p" "$MOG_TEST")
[ -n "$MOG_RUN_GREEN" ] || { echo "FAIL: could not lift MOG_RUN_GREEN" >&2; exit 1; }
export STUB_RUN_LIST_JSON_DEFAULT="$MOG_RUN_GREEN"

# the stateful Jira stub: one directory of state files (status, fixversions, comments)
write_jira_stub() {
    local dir="$1" status="$2" versions="$3"
    mkdir -p "$dir/state"
    printf '%s' "$status" > "$dir/state/status"
    printf '%s' "$versions" > "$dir/state/fixversions"
    : > "$dir/state/comments"
    : > "$dir/state/calls"
    cat > "$dir/jira-stub" <<'STUBJIRA'
#!/usr/bin/env bash
s="$JIRA_STATE"
echo "$*" >> "$s/calls"
case "$1" in
    get|comment|transition|edit)
        [ "$2" = "HIMMEL-9001" ] || { echo "jira-stub: unexpected key $2" >&2; exit 1; } ;;
esac
case "$1" in
    get)
        fv=$(awk 'NF { printf "%s{\"name\":\"%s\"}", (n++ ? "," : ""), $0 }' "$s/fixversions")
        printf '{"fields":{"issuetype":{"name":"Task"},"status":{"name":"%s"},"fixVersions":[%s]}}\n' "$(cat "$s/status")" "$fv" ;;
    comment)
        [ "$3" = "--comment-file" ] && [ -f "$4" ] || exit 1
        { cat "$4"; echo; } >> "$s/comments" ;; # read-sink-ok: stub reads the comment file the script under test just wrote
    transition) printf '%s' "$3" > "$s/status" ;;
    versions) printf 'v1.1.2\ttrue\t2026-10-11\nv1.1.4\tfalse\t\nv1.1.3\tfalse\t2026-10-22\n' ;;
    edit)
        case "$3" in
            --fix-version) printf '%s\n' "$4" > "$s/fixversions" ;;
            --add-fix-version) printf '%s\n' "$4" >> "$s/fixversions" ;;
            *) echo "jira-stub: unhandled edit $*" >&2; exit 1 ;;
        esac ;;
    *) echo "jira-stub: unhandled $*" >&2; exit 1 ;;
esac
STUBJIRA
    chmod +x "$dir/jira-stub"
}

# swap the fixture's logging node stub for one that routes the Jira CLI to the stateful stub
install_stateful_node() {
    local tmp="$1" real_node; real_node=$(command -v node)
    cat > "$tmp/bin/node" <<STUBNODE
#!/usr/bin/env bash
case "\$1" in
    */dist/index.js) shift; exec "$tmp/jira-stub" "\$@" ;;
    *) exec "$real_node" "\$@" ;;
esac
STUBNODE
    chmod +x "$tmp/bin/node"
}

# new_case <status> <fixversions, one per line>  -> sets TMP
new_case() {
    TMP=$(mktemp -d "$SUITE_TMP/case.XXXXXX") || { echo "FAIL: mktemp" >&2; exit 1; }
    export STUB_JIRA_BUILD=1
    mog_build_fixture "$TMP"
    write_jira_stub "$TMP" "$1" "$2"
    install_stateful_node "$TMP"
    : > "$TMP/gh.log"; : > "$TMP/jira.log"; : > "$TMP/clear.log"
}

# run_merge <expected-exit> <args...>   (reads STUB_* from the environment)
run_merge() {
    local expected="$1"; shift
    local rc
    ARMAUTOMERGE=1 GH_LOG="$TMP/gh.log" CLEAR_LOG="$TMP/clear.log" MERGE_ON_GREEN_LOG="$TMP/audit.log" JIRA_LOG="$TMP/jira.log" \
        JIRA_STATE="$TMP/state" PATH="$TMP/bin:$PATH" MERGE_ON_GREEN_SLEEP_CMD=: \
        MERGE_BLOCK_ALERT_DIR="$TMP/alerts" MERGE_BLOCK_ALERT_CMD="$TMP/bin/alert-sender" \
        TELEGRAM_ACCESS_PATH="$TMP/access.json" CR_APP="" HIMMEL_REPO="$TMP" \
        bash -c 'cd "$1" || exit 1; shift; exec bash "$@"' _ "$TMP" "$TMP/scripts/handover/merge-on-green.sh" "$@" \
        >/dev/null 2>"$TMP/err"
    rc=$?
    if [ "$rc" -eq "$expected" ]; then pass; else fail "merge exit $expected expected, got $rc (err: $(head -c 400 "$TMP/err"))"; fi
}

state_status() { cat "$TMP/state/status"; }
state_versions() { awk 'NF' "$TMP/state/fixversions" | paste -sd, -; }
state_comments() { cat "$TMP/state/comments"; }

assert_eq() {
    if [ "$2" = "$3" ]; then pass; else fail "$1 (want '$3', got '$2')"; fi
}
assert_comment_has() {
    if grep -qF -- "$2" "$TMP/state/comments"; then pass; else fail "$1 (comments: $(cat "$TMP/state/comments"))"; fi
}

# --- 1 full merge with --jira-transition: Done, the held current version kept -------------
export STUB_PR_TITLE="feat(x): [HIMMEL-9001] a thing"
new_case "In Review" "v1.1.3"
run_merge 0 --jira-transition
assert_eq "1 full merge: final status" "$(state_status)" "Done"
assert_eq "1 full merge: fixVersion" "$(state_versions)" "v1.1.3"
assert_comment_has "1 full merge: evidence comment left on the ticket" "merged @"

# --- 2 partial merge (no --jira-transition): status and version untouched, Remaining comment -
export STUB_PR_BODY="Remaining: slice 2 of 3"
new_case "In Review" "v1.1.3"
run_merge 0
assert_eq "2 partial merge: status left alone" "$(state_status)" "In Review"
assert_eq "2 partial merge: fixVersion left alone" "$(state_versions)" "v1.1.3"
assert_comment_has "2 partial merge: Remaining line on the ticket" "Remaining: slice 2 of 3"

# --- 2b the brief says completes-ticket: no, so --jira-transition is ignored -----------------
export STUB_PR_BODY="Remaining: slice 2 of 3"
new_case "In Review" "v1.1.3"
printf '> **Completes ticket:** no\n\n## Results\n' > "$TMP/leg-doc.md"
run_merge 0 --jira-transition --leg-doc "$TMP/leg-doc.md"
assert_eq "2b brief completes-ticket: no: status left alone" "$(state_status)" "In Review"
assert_eq "2b brief completes-ticket: no: fixVersion left alone" "$(state_versions)" "v1.1.3"
assert_comment_has "2b brief completes-ticket: no: Remaining line on the ticket" "Remaining: slice 2 of 3"
unset STUB_PR_BODY

# --- 3 versionless ticket: closed with the current version stamped -----------------------
new_case "In Review" ""
run_merge 0 --jira-transition
assert_eq "3 versionless: final status" "$(state_status)" "Done"
assert_eq "3 versionless: gets the current version" "$(state_versions)" "v1.1.3"

# --- 4 In Review ticket: check-ci moves it to IN CI, the merge then closes it ------------
if [ -z "${_TIMEOUT_BIN:-}" ]; then
    echo "SKIP: case 4 needs GNU timeout/gtimeout (macOS: brew install coreutils)" >&2
else
new_case "In Review" "v1.1.3"
CC_DIR="$TMP/cc"; mkdir -p "$CC_DIR"
# the check-ci gh stub, lifted from test-check-ci.sh (the heredoc that writes $STUBDIR/gh)
sed -n "/^cat > \"\$STUBDIR\/gh\" <<'EOF'\$/,/^EOF\$/p" "$CHECK_CI_TEST" | sed '1d;$d' > "$CC_DIR/gh"
if [ ! -s "$CC_DIR/gh" ]; then echo "FAIL: could not lift the check-ci gh stub" >&2; exit 1; fi
chmod +x "$CC_DIR/gh"
for f in args count watch api headc statuses reviews freshness-reads comments claims reqrows-count msc; do : > "$CC_DIR/$f"; done
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nexec sleep "$1"\n' > "$CC_DIR/counting-sleep"; chmod +x "$CC_DIR/counting-sleep"
printf '{"allowFrom":["555"]}\n' > "$CC_DIR/access.json"
PATH="$CC_DIR:$PATH" GH_STUB_MODE=cr-completed GH_STUB_ARGS="$CC_DIR/args" GH_STUB_COUNT="$CC_DIR/count" \
    GH_STUB_WATCH="$CC_DIR/watch" GH_STUB_API="$CC_DIR/api" GH_STUB_HEADC="$CC_DIR/headc" \
    GH_STUB_STATUSES="$CC_DIR/statuses" GH_STUB_REVIEWS="$CC_DIR/reviews" GH_STUB_FRESHNESS_READS="$CC_DIR/freshness-reads" \
    GH_STUB_COMMENTS="$CC_DIR/comments" GH_STUB_CLAIMS="$CC_DIR/claims" GH_STUB_MSC="$CC_DIR/msc" \
    GH_STUB_TITLE="feat(x): [HIMMEL-9001] a thing" GH_STUB_MERGE_STATE=CLEAN GH_STUB_MERGE_HEAD=sha1 \
    GH_STUB_THREADS=0 GH_STUB_FRESHNESS=fresh GH_STUB_FILES=README.md GH_STUB_MPR=none GH_STUB_CHECKS=pass:unit-tests \
    GH_STUB_RULES=none GH_STUB_CLASSIC=none GH_STUB_PRODUCERS=none GH_STUB_STATUSCTX=none GH_STUB_HEAD=stable GH_STUB_DECISION=null \
    HIMMEL_CONSOLE_LEG=0 HIMMEL_TEST_FIXTURE=1 CR_APP=1 CR_PROFILE="" CR_BOT_LOGINS="" \
    CHECK_CI_POLL_INTERVAL=0 CHECK_CI_SETTLE=0 CR_ESCALATE_WAIT=0 CR_ESCALATE_POLL=0 CHECK_CI_SLEEP_CMD=: CHECK_CI_PROBE_INTERVAL=1 \
    GH_BUDGET_PREFLIGHT=0 GH_BUDGET_JITTER_MAX=0 \
    MERGE_BLOCK_ALERT_DIR="$CC_DIR/alert-sentinels" MERGE_BLOCK_ALERT_CMD=true TELEGRAM_ACCESS_PATH="$CC_DIR/access.json" \
    MERGE_WATCH_ALERT_BRIDGE_ROOT="$CC_DIR/bridge" \
    LEG_JIRA_STATUS=1 LEG_JIRA_CLI="$TMP/jira-stub" JIRA_STATE="$TMP/state" \
    "$_TIMEOUT_BIN" -k 5 120 bash "$CHECK_CI" --grace 30 >"$CC_DIR/out" 2>"$CC_DIR/err"
cc_rc=$?
if [ "$cc_rc" -eq 0 ]; then pass; else fail "4 check-ci exit 0 expected, got $cc_rc (err: $(head -c 600 "$CC_DIR/err"))"; fi
assert_eq "4 In Review ticket after the CI wait" "$(state_status)" "IN CI"
run_merge 0 --jira-transition
assert_eq "4 IN CI ticket after the merge close" "$(state_status)" "Done"
assert_eq "4 fixVersion after the merge close" "$(state_versions)" "v1.1.3"
fi

echo "test-merge-on-green-jira-end-state: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
