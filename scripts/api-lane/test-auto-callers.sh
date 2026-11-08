#!/usr/bin/env bash
# The auto-caller grep test: fails when a caller in scripts/ or docs/ defaults to API
# account auto outside the allowlist below, when anything but the himmel graph pass calls
# the graph form of the lane gate, when a docs line says rm-run always takes the API lane,
# or when a pinned docs line moved.
#
# No arguments. Exit 0 when clean, 1 on any hit; each hit prints one line on stdout.
# AUTO_CALLERS_ROOT points the checks at another git tree (the suite's own rows use it);
# unset, the checks run over this repo and the suite's rows then inject one violation
# per check into a temp copy, each of which must print a hit.
#
# Checks (fixed strings only, over scripts/ and docs/; *.test.*, test-*.sh and the luna
# old-auto runner fixture are excluded by path):
#   1  the auto shapes below, outside the allowlist; claude-api.sh and semantic-update.sh,
#      which decide auto, are outside the two A|B|C|auto strings only
#   2  "auto", 'auto' or :-auto on a line naming HIMMEL_API_ACCOUNT, outside the allowlist,
#      claude-api.sh and semantic-update.sh
#   3  llm_backend_api_ready_graph outside llm-backend.sh, graph-cadence.sh and
#      refresh-graph-map.sh
#   4  a docs line holding rm-run, API lane and always
#   5  pinned docs lines, present or absent
#
# ponytail: literal-shape grep over scripts/ and docs/, so a default built by indirection escapes it until its first call, and the launcher trusts a caller that declares graphify or a mapped kind; upgrade path: tie the kind to the calling script in the launcher, and section 6 must replace this test if the limit goes.
# Platform guard: bash 3.2, git and awk on local files; Linux verified.
# The patterns and injected lines are literal text, never expanded; each check appends to one out file.
# shellcheck disable=SC2016,SC2129
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
ROOT="${AUTO_CALLERS_ROOT:-$REPO}"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/test-auto-callers.XXXXXX")" || { echo "test-auto-callers: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT

# The allowlist: one row is a file line, then the whole line it exempts, compared exactly.
# Each row exempts one occurrence; a second identical line in that file fails.
# The two headed-arm-worker.sh rows (the header comment and the seam) stay until the
# API-only worker follow-up.
ALLOWLIST="$TMP_ROOT/allowlist"
cat >"$ALLOWLIST" <<'ALLOW'
scripts/luna/graphmap-cadence.sh
    printf 'if [ -e %s ]; then echo "[semantic paused: marker present]"; %s; else echo "[semantic active]"; HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto GRAPH_CADENCE_SEMANTIC_BACKEND=claude-api %s --semantic; fi' "$q_pause" "$base" "$base"
scripts/luna/graphmap-cadence.sh
        backend="claude-api" lane="HIMMEL_API_LANE=on HIMMEL_API_ACCOUNT=auto "
scripts/lib/api-credit-state.mjs
// routing for HIMMEL_API_ACCOUNT=auto. Of the configured accounts whose row has room for the whole
scripts/jira/src/commands/release.ts
    HIMMEL_API_LANE: 'on', HIMMEL_API_ACCOUNT: 'auto', HIMMEL_API_KIND: 'judge', HIMMEL_API_FALLBACK: 'off', HIMMEL_API_TOOLS: '',
scripts/lib/llm-backend.sh
        && { llm_backend_api_account_ok "${HIMMEL_API_ACCOUNT:-}" || [ "${HIMMEL_API_ACCOUNT:-}" = "auto" ]; }
docs/internals/api-lane.md
Auto routing is off for every call except the himmel semantic graph pass. `HIMMEL_API_ACCOUNT=auto` is accepted
docs/internals/api-lane.md
API account (`HIMMEL_API_ACCOUNT=A|B|C|auto`; auto only for the himmel graph pass, or a kind the role map maps) instead of the subscription. It is
docs/internals/graph-cadence.md
When `HIMMEL_API_ACCOUNT=auto`, a credit-exhausted submit moves on to the next account of the pick list, each account
scripts/handover/chief-kit/headed-arm-worker.sh
# and HIMMEL_API_ACCOUNT=auto, so the PR critic runs on API credit. Opt-in,
scripts/handover/chief-kit/headed-arm-worker.sh
    worker_propagate_env HIMMEL_API_ACCOUNT auto
ALLOW

# allowed_line <file> <substring> -> the one allowlist line of <file> holding <substring>
allowed_line() {
    awk -v f="$1" -v s="$2" 'NR % 2 == 1 { file = $0; next } file == f && index($0, s) { print; exit }' "$ALLOWLIST"
}

EXCLUDES=(':(exclude)*.test.*' ':(exclude)*/test-*.sh' ':(exclude)scripts/luna/fixtures/graphmap-semantic-luna-old-auto.txt')
DECIDERS=(':(exclude)scripts/api-lane/claude-api.sh' ':(exclude)scripts/graphify/semantic-update.sh')

# grep_tree <root> <git grep args...> -- <pathspecs...>: file:line:text hits, nothing on no hit
grep_tree() {
    local root="$1"; shift
    git -C "$root" grep -n -F --no-color "$@" 2>/dev/null || true
}

# drop_allowed <check> <hits file>: prints "check<N> file:line: text" for every hit not
# covered by an unused allowlist row; one hit per file:line
drop_allowed() {
    awk -v check="$1" '
        NR == FNR { if (FNR % 2 == 1) file = $0; else allow[file SUBSEP $0]++; next }
        {
            i = index($0, ":"); f = substr($0, 1, i - 1); rest = substr($0, i + 1)
            j = index(rest, ":"); n = substr(rest, 1, j - 1); t = substr(rest, j + 1)
            if ((f SUBSEP n) in seen) next
            seen[f SUBSEP n] = 1
            if (allow[f SUBSEP t] > 0) { allow[f SUBSEP t]--; next }
            print "check" check " " f ":" n ": " t
        }' "$ALLOWLIST" "$2"
}

# run_checks <root>: prints every hit, returns 1 when there is one
run_checks() {
    local root="$1" hits="$TMP_ROOT/hits.$$" out="$TMP_ROOT/out.$$"
    : >"$out"

    # Checks 1 and 2 share the allowlist, so a line both match is judged once.
    {
        grep_tree "$root" -e 'HIMMEL_API_ACCOUNT=auto' -e "HIMMEL_API_ACCOUNT ?? 'auto'" \
            -e 'HIMMEL_API_ACCOUNT auto' -e 'A|B|auto' -e 'A\|B\|auto' -- scripts docs "${EXCLUDES[@]}"
        grep_tree "$root" -e 'A|B|C|auto' -e 'A\|B\|C\|auto' -- scripts docs "${EXCLUDES[@]}" "${DECIDERS[@]}"
        grep_tree "$root" -e 'HIMMEL_API_ACCOUNT' --and '(' -e '"auto"' -e "'auto'" -e ':-auto' ')' \
            -- scripts docs "${EXCLUDES[@]}" "${DECIDERS[@]}"
    } | sort -t: -k1,1 -k2,2n >"$hits"
    drop_allowed 1-2 "$hits" >>"$out"

    grep_tree "$root" -e 'llm_backend_api_ready_graph' -- scripts docs "${EXCLUDES[@]}" \
        ':(exclude)scripts/lib/llm-backend.sh' ':(exclude)scripts/graphify/graph-cadence.sh' \
        ':(exclude)scripts/graphify/refresh-graph-map.sh' | sed 's/^/check3 /' >>"$out"

    grep_tree "$root" -e 'rm-run' --and -e 'API lane' --and -e 'always' -- docs "${EXCLUDES[@]}" \
        | sed 's/^/check4 /' >>"$out"

    local f line
    f="$root/docs/internals/api-lane.md"
    for s in 'Auto routing is off for every call except' 'auto only for the himmel graph pass'; do
        line="$(allowed_line docs/internals/api-lane.md "$s")"
        grep -q -x -F -- "$line" "$f" 2>/dev/null \
            || echo "check5 docs/internals/api-lane.md: the limit line holding '$s' is not present whole" >>"$out"
    done
    f="$root/docs/internals/graph-cadence.md"
    local lsem para
    lsem="$(grep -F -- '--with-luna-semantic' "$f" 2>/dev/null)"
    if [ -z "$lsem" ]; then
        echo "check5 docs/internals/graph-cadence.md: no --with-luna-semantic line" >>"$out"
    elif grep -q -v -F -- '--api-account' <<<"$lsem"; then
        echo "check5 docs/internals/graph-cadence.md: a --with-luna-semantic line names no --api-account" >>"$out"
    fi
    f="$root/docs/internals/enforcement.md"
    para="$(awk '/^\*\*Worker API-lane switch:\*\*/ { on = 1 } on && /^$/ { exit } on' "$f" 2>/dev/null | tr '\n' ' ')"
    grep -q -F 'settled by a later change' <<<"$para" \
        || echo "check5 docs/internals/enforcement.md: the Worker API-lane switch paragraph has no 'settled by a later change' pointer" >>"$out"
    ! grep -q -F 'makes it the standing default' "$f" 2>/dev/null \
        || echo "check5 docs/internals/enforcement.md: still says 'makes it the standing default'" >>"$out"
    ! grep -q -F 'account `auto`' "$root/scripts/eval/docs-review/README.md" 2>/dev/null \
        || echo "check5 scripts/eval/docs-review/README.md: still says account \`auto\`" >>"$out"

    cat "$out"
    [ ! -s "$out" ]
}

if [ -n "${AUTO_CALLERS_ROOT:-}" ]; then
    run_checks "$ROOT"
    exit $?
fi

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL + 1)); }

echo "TEST: this repo has no auto caller outside the allowlist"
rc=0; out="$(run_checks "$REPO")" || rc=$?
[ -n "$out" ] && printf '%s\n' "$out"
if [ "$rc" -eq 0 ]; then pass "no hit in scripts/ or docs/"; else fail "hits in scripts/ or docs/ (listed above)"; fi

# The rows below run the checks over a temp git copy of every file a check reads.
COPIED="scripts/luna/graphmap-cadence.sh scripts/lib/api-credit-state.mjs scripts/jira/src/commands/release.ts
scripts/lib/llm-backend.sh scripts/handover/chief-kit/headed-arm-worker.sh scripts/api-lane/claude-api.sh
scripts/graphify/semantic-update.sh scripts/graphify/graph-cadence.sh scripts/graphify/refresh-graph-map.sh
scripts/eval/docs-review/README.md docs/internals/api-lane.md docs/internals/graph-cadence.md docs/internals/enforcement.md"
BASE="$TMP_ROOT/base"
mkdir -p "$BASE"
git -C "$BASE" init -q
for p in $COPIED; do
    mkdir -p "$BASE/$(dirname "$p")"
    cp "$REPO/$p" "$BASE/$p"
done
git -C "$BASE" add -A

T="$TMP_ROOT/case"
fresh() { rm -rf "$T"; cp -R "$BASE" "$T"; }
# lit_replace <file> <from> <to>: every literal <from> in <file> becomes <to>
lit_replace() {
    FROM="$2" TO="$3" awk '{ s = $0; o = ""; while ((i = index(s, ENVIRON["FROM"])) > 0) { o = o substr(s, 1, i - 1) ENVIRON["TO"]; s = substr(s, i + length(ENVIRON["FROM"])) } print o s }' \
        "$1" >"$1.new" && mv "$1.new" "$1"
}
# expect_hit <label> <expected substring>: the checks over $T exit 1 and print the substring
expect_hit() {
    git -C "$T" add -A
    local rc=0 got
    got="$(AUTO_CALLERS_ROOT="$T" bash "$HERE/test-auto-callers.sh")" || rc=$?
    if [ "$rc" -eq 1 ] && case "$got" in *"$2"*) true ;; *) false ;; esac; then
        pass "$1"
    else
        fail "$1" "rc=$rc out=$got"
    fi
}

echo "TEST: the clean copy prints no hit"
fresh
rc=0; got="$(AUTO_CALLERS_ROOT="$T" bash "$HERE/test-auto-callers.sh")" || rc=$?
if [ "$rc" -eq 0 ] && [ -z "$got" ]; then pass "the copy is clean"; else fail "the copy is clean" "rc=$rc out=$got"; fi

echo "TEST: check 1 and 2 rows"
fresh; allowed_line scripts/lib/api-credit-state.mjs 'routing for HIMMEL_API_ACCOUNT=auto' >>"$T/scripts/lib/api-credit-state.mjs"
expect_hit "a second copy of an allowed line fails" "check1-2 scripts/lib/api-credit-state.mjs:"
fresh; echo 'export HIMMEL_API_ACCOUNT=auto' >>"$T/scripts/luna/graphmap-cadence.sh"
expect_hit "HIMMEL_API_ACCOUNT=auto in an allowed file fails" "check1-2 scripts/luna/graphmap-cadence.sh:"
fresh; echo '# account A|B|C|auto' >>"$T/scripts/lib/llm-backend.sh"
expect_hit "A|B|C|auto in llm-backend.sh fails" "check1-2 scripts/lib/llm-backend.sh:"
fresh; mkdir -p "$T/scripts/new"; echo 'acct="${HIMMEL_API_ACCOUNT:-auto}"' >"$T/scripts/new/caller.sh"
expect_hit ":-auto beside HIMMEL_API_ACCOUNT in a file off the allowlist fails" "check1-2 scripts/new/caller.sh:"

echo "TEST: check 3 row"
fresh; mkdir -p "$T/scripts/new"; echo 'llm_backend_api_ready_graph || exit 1' >"$T/scripts/new/graph-caller.sh"
expect_hit "the graph form outside its three files fails" "check3 scripts/new/graph-caller.sh:"

echo "TEST: check 4 row"
fresh; echo '`jira release rm-run` always takes the API lane.' >>"$T/docs/internals/api-lane.md"
expect_hit "a docs line saying rm-run always takes the API lane fails" "check4 docs/internals/api-lane.md:"

echo "TEST: check 5 rows"
fresh; lit_replace "$T/docs/internals/api-lane.md" 'Auto routing is off for every call except' 'Auto routing is off for most calls except'
expect_hit "the first limit line changed fails" "check5 docs/internals/api-lane.md: the limit line holding 'Auto routing is off"
fresh; lit_replace "$T/docs/internals/api-lane.md" 'auto only for the himmel graph pass' 'auto for the himmel graph pass'
expect_hit "the second limit line changed fails" "check5 docs/internals/api-lane.md: the limit line holding 'auto only"
fresh; lit_replace "$T/docs/internals/graph-cadence.md" '--api-account' '--account'
expect_hit "the --with-luna-semantic sentence without --api-account fails" "check5 docs/internals/graph-cadence.md:"
fresh; lit_replace "$T/docs/internals/enforcement.md" 'settled by a later change' 'settled later'
expect_hit "the seam paragraph without its follow-up pointer fails" "check5 docs/internals/enforcement.md: the Worker API-lane switch"
fresh; echo 'The chief makes it the standing default.' >>"$T/docs/internals/enforcement.md"
expect_hit "the standing-default sentence back fails" "check5 docs/internals/enforcement.md: still says"
fresh; echo 'It runs on account `auto`.' >>"$T/scripts/eval/docs-review/README.md"
expect_hit "account auto in the docs-review README fails" "check5 scripts/eval/docs-review/README.md:"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
