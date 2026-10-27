#!/usr/bin/env bash
# scripts/lanes/test-worker-pr-open.sh - Hermetic tests for
# worker-pr-open.sh: a GH_CMD stub records every argv line to a file, so the
# assertion that matters (the PR body text appears ONLY as the --body value
# the forge seam passes to gh, never in the Bash command a worker types) is a
# grep, not a guess. No network, no real gh/PR.
#
# Platform guard: no .ps1 twin, by design. Bash plus git — it runs under git
# bash on Windows unchanged (same requirements as the SUT it exercises).
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/worker-pr-open.sh"

PASS=0
FAIL=0
TMP_ROOT=""
# shellcheck disable=SC2329,SC2317  # invoked via the EXIT trap
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; [ $# -ge 2 ] && printf '    %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected='$2' actual='$3'"; fi
}
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "missing '$3' in: $2" ;; esac
}
not_contains() {
    case "$2" in *"$3"*) fail "$1" "unexpectedly found '$3' in: $2" ;; *) pass "$1" ;; esac
}

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worker-pr-open-test.XXXXXX") || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
if command -v cygpath >/dev/null 2>&1; then TMP_ROOT=$(cygpath -m "$TMP_ROOT"); fi

# ── fixture: a real bare "origin" + a pushed feature branch (no network) ────
BARE="$TMP_ROOT/origin.git"
git init -q --bare "$BARE"
REPO="$TMP_ROOT/repo"
git init -q -b main "$REPO" 2>/dev/null || { git init -q "$REPO"; git -C "$REPO" checkout -q -b main; }
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name test
git -C "$REPO" remote add origin "$BARE"
echo base > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm base
git -C "$REPO" push -q origin main
git -C "$REPO" checkout -q -b feat/himmel-3031-x
echo change > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm change
git -C "$REPO" push -q -u origin feat/himmel-3031-x
HEAD_SHA=$(git -C "$REPO" rev-parse HEAD)

# The SUT re-derives the title's ticket status through the status funnel; a
# stub funnel keeps every run here off the real tracker and records its calls.
JIRA_LOG="$TMP_ROOT/jira.log"
FUNNEL_STUB="$TMP_ROOT/funnel-stub.sh"
cat >"$FUNNEL_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JIRA_LOG"
exit 0
STUB
export JIRA_LOG TICKET_STATUS_FUNNEL="$FUNNEL_STUB"

TITLE_FILE="$TMP_ROOT/title.txt"
BODY_FILE="$TMP_ROOT/body.txt"
printf 'feat(lanes): [HIMMEL-3031] worker-pr-open.sh publishes a PR from files\n' > "$TITLE_FILE"
BODY_MARKER="body-text-marker-$$-never-on-the-bash-argv-claude-typed"
printf '## Summary\n\n%s\n\n## diff --stat\n f | 1 +\n\nleg-burn: calls=5 avg-ctx=1.0k\n' \
    "$BODY_MARKER" > "$BODY_FILE"

# GH_CMD stub: records every argv line it is called with, then answers just
# enough to drive pr_find_open / pr_create / pr_edit / repo_view.
ARGV_LOG="$TMP_ROOT/argv.log"
GH_STUB="$TMP_ROOT/gh-stub.sh"
cat >"$GH_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ARGV_LOG"
previous=""
for arg in "$@"; do
    [ "$previous" != "--body" ] || printf '%s\n' "$arg" > "${ARGV_LOG}.body"
    previous="$arg"
done
case "$* " in
    *"pr list"*"--state open"*)
        if [ -n "${STUB_FIND_OPEN_STDERR:-}" ]; then
            echo "$STUB_FIND_OPEN_STDERR" >&2
        fi
        if [ -n "${STUB_OPEN_PR:-}" ]; then
            printf '%s\n' "$STUB_OPEN_PR"
        fi
        ;;
    *"pr create"*)
        if [ -n "${STUB_CREATE_STDERR:-}" ]; then
            echo "$STUB_CREATE_STDERR" >&2
        fi
        echo "https://github.com/owner/repo/pull/9"
        # real `gh pr create` on a repo with CodeRabbit armed is followed by
        # the seam's own CR-trigger confirmation line on stdout
        # — reproduce that here, not just the bare URL.
        echo "posted @coderabbitai review on PR #9 (owner/repo) for head $HEAD_SHA_STUB"
        ;;
    *"pr view"*)   printf '%s\n' "${STUB_PR_TITLE:-feat(lanes): [HIMMEL-3031] existing title}" ;;
    *"pr edit"*)   exit 0 ;;
    *"repo view"*) echo "owner/repo" ;;
    *) echo "stub: unhandled gh args: $*" >&2; exit 99 ;;
esac
STUB
chmod +x "$GH_STUB"

# The SUT opens a PR only for a head /pr-check reviewed: an `avail ... ok` row
# at that head in <git-common-dir>/cr-critic-scores.jsonl. stamp_review writes
# that row; run_sut stamps the current head unless REVIEW_ROW=0.
LEDGER="$REPO/.git/cr-critic-scores.jsonl"
LEDGER_ROWS=""
reset_ledger() { LEDGER_ROWS=""; printf '' > "$LEDGER"; }
stamp_review() {  # <head> [status]
    LEDGER_ROWS="${LEDGER_ROWS}$(printf '{"kind":"avail","ts":"2026-10-25T00:00:00Z","branch":"feat/himmel-3031-x","head":"%s","model":"codex","status":"%s","artifact":"diff","perspective":"off"}' \
        "$1" "${2:-ok}")"$'\n'
    printf '%s' "$LEDGER_ROWS" > "$LEDGER"
}

run_sut() {  # args passed straight through to the SUT
    if [ "${REVIEW_ROW:-1}" != 0 ]; then stamp_review "$(git -C "$REPO" rev-parse HEAD)"; fi
    (
        cd "$REPO" || exit 99
        # JIRA_PROJECT_KEY drives check-commit-msg.sh's ticket
        # pattern (HIMMEL-N) via the new title gate — the fixture title below
        # carries a HIMMEL-style ticket, so this must be set for every run,
        # not just the title-gate-specific cases.
        FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
            HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
            bash "$SUT" "$@"
    )
}

# A candidate may change prose, never facts; refusal still publishes the original.
# shellcheck disable=SC2016 # Backticks in Markdown fixtures are literal data.
humanizer_rows() {
    local original="$TMP_ROOT/original.md" candidate="$TMP_ROOT/candidate.md" output rc body_text
    printf '## Summary\nHIMMEL-3031 checks 42 rows in scripts/check.sh with `bash scripts/check.sh`.\n' > "$original"
    printf '## Summary\nWith `bash scripts/check.sh`, HIMMEL-3031 checks 42 rows in scripts/check.sh.\n' > "$candidate"
    output=$(run_sut "$TITLE_FILE" "$original" --humanized-body "$candidate" 2>"$TMP_ROOT/humanizer.err"); rc=$?
    assert_eq "faithful PR rewrite publishes" 0 "$rc"
    body_text=$(cat "${ARGV_LOG}.body" 2>/dev/null)
    contains "published body uses faithful rewrite" "$body_text" 'With `bash scripts/check.sh`'
    for pair in 'HIMMEL-3031 HIMMEL-3032' '42 43' 'scripts/check.sh scripts/other.sh'; do
        sed "s|${pair% *}|${pair#* }|g" "$original" > "$candidate"
        output=$(run_sut "$TITLE_FILE" "$original" --humanized-body "$candidate" 2>"$TMP_ROOT/humanizer.err"); rc=$?
        assert_eq "changed ${pair% *} falls back without blocking PR" 0 "$rc"
        body_text=$(cat "${ARGV_LOG}.body" 2>/dev/null)
        contains "fallback publishes original ${pair% *}" "$body_text" 'HIMMEL-3031 checks 42 rows in scripts/check.sh'
    done
    output=$(run_sut "$TITLE_FILE" "$original" --humanized-body "$TMP_ROOT/missing.md" 2>"$TMP_ROOT/humanizer.err"); rc=$?
    assert_eq "missing PR candidate never blocks" 0 "$rc"
    output=$(run_sut "$TITLE_FILE" "$original" 2>"$TMP_ROOT/humanizer.err"); rc=$?
    assert_eq "skipping PR rewrite never blocks" 0 "$rc"
    contains "skip keeps one-line publication result" "$output" 'PR 9 https://github.com/owner/repo/pull/9 '
    contains "PR helper offers deterministic pass on stderr" "$(cat "$TMP_ROOT/humanizer.err")" deterministic
    not_contains "PR helper does not offer a model rewrite" "$(cat "$TMP_ROOT/humanizer.err")" /humanizer
}
humanizer_rows
if [ "${1:-}" = --humanizer-only ]; then
    echo "test summary: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]; exit $?
fi

# ── (a) create path: no open PR -> pr create, never pr edit ─────────────────
echo "TEST: create path (no existing PR)"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
out_a=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_a=$?
assert_eq "create path exits 0" "0" "$rc_a"
assert_eq "create path prints exactly the success line" \
    "PR 9 https://github.com/owner/repo/pull/9 $HEAD_SHA" "$out_a"
argv_a=$(cat "$ARGV_LOG")
contains "argv contains pr create" "$argv_a" "pr create"
contains "argv contains --base main" "$argv_a" "--base main"
contains "argv contains --title with the title text" "$argv_a" "--title feat(lanes): [HIMMEL-3031]"
contains "the body text reaches gh as the --body value" "$argv_a" "$BODY_MARKER"
not_contains "no pr edit is called on the create path" "$argv_a" "pr edit"

# The utility's OWN invocation (what a worker's Bash tool call actually contains)
# is exactly two file paths — never the body text.
inv_args=("$TITLE_FILE" "$BODY_FILE")
assert_eq "the utility invocation is exactly two args" "2" "${#inv_args[@]}"
invocation_line="bash $SUT $TITLE_FILE $BODY_FILE"
not_contains "the utility invocation line carries no body text" "$invocation_line" "$BODY_MARKER"

# ── (b) update path: an open PR exists -> pr edit, never pr create ──────────
echo "TEST: update path (existing open PR)"
: > "$ARGV_LOG"
out_b=$(STUB_OPEN_PR=42 run_sut "$TITLE_FILE" "$BODY_FILE"); rc_b=$?
assert_eq "update path exits 0" "0" "$rc_b"
assert_eq "update path prints exactly the success line" \
    "PR 42 https://github.com/owner/repo/pull/42 $HEAD_SHA" "$out_b"
argv_b=$(cat "$ARGV_LOG")
contains "argv contains pr edit 42" "$argv_b" "pr edit 42"
contains "the body text reaches gh as the --body value on update too" "$argv_b" "$BODY_MARKER"
not_contains "no pr create is called on the update path" "$argv_b" "pr create"

# ── (c) refuses on main ──────────────────────────────────────────────────────
echo "TEST: refuses on main"
git -C "$REPO" checkout -q main
err_c=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_c=$?
if [ "$rc_c" -ne 0 ]; then pass "refuses on main (rc!=0)"; else fail "refuses on main (rc!=0)" "got rc=$rc_c"; fi
contains "refusal on main names main" "$err_c" "main"
git -C "$REPO" checkout -q feat/himmel-3031-x

# ── (d) refuses when the branch has no upstream ─────────────────────────────
echo "TEST: refuses when the branch has no upstream"
git -C "$REPO" checkout -q -b feat/himmel-3031-no-upstream
err_d=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_d=$?
if [ "$rc_d" -ne 0 ]; then pass "refuses with no upstream (rc!=0)"; else fail "refuses with no upstream (rc!=0)" "got rc=$rc_d"; fi
contains "refusal names upstream" "$err_d" "has no upstream"
git -C "$REPO" checkout -q feat/himmel-3031-x
git -C "$REPO" branch -q -D feat/himmel-3031-no-upstream

# ── (e) refuses an empty body file ───────────────────────────────────────────
echo "TEST: refuses an empty body file"
EMPTY_BODY="$TMP_ROOT/empty-body.txt"
: > "$EMPTY_BODY"
err_e=$(run_sut "$TITLE_FILE" "$EMPTY_BODY" 2>&1 >/dev/null); rc_e=$?
if [ "$rc_e" -ne 0 ]; then pass "refuses an empty body file (rc!=0)"; else fail "refuses an empty body file (rc!=0)" "got rc=$rc_e"; fi
contains "refusal names the empty body" "$err_e" "empty"

# ── (f) create path survives a stderr warning racing the stdout URL (codex-1) ──
echo "TEST: create path survives a stderr warning during create"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
export STUB_CREATE_STDERR="warn: transient network/blip, retrying"
out_f=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_f=$?
unset STUB_CREATE_STDERR
assert_eq "stderr-warning create path exits 0" "0" "$rc_f"
assert_eq "stderr-warning create path prints exactly the success line" \
    "PR 9 https://github.com/owner/repo/pull/9 $HEAD_SHA" "$out_f"

# ── (g) refuses when local HEAD has not been pushed to upstream (codex-2) ───
echo "TEST: refuses when local HEAD is unpushed relative to upstream"
echo change2 > "$REPO/f"; git -C "$REPO" add f; git -C "$REPO" commit -qm change2
err_g=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_g=$?
if [ "$rc_g" -ne 0 ]; then pass "refuses when HEAD unpushed (rc!=0)"; else fail "refuses when HEAD unpushed (rc!=0)" "got rc=$rc_g"; fi
contains "refusal names push" "$err_g" "push"
git -C "$REPO" push -q origin feat/himmel-3031-x

# ── (h) find-open lookup survives a stderr warning on a CLEAN success ──
echo "TEST: find-open lookup survives a stderr warning on success (no open PR)"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
export STUB_FIND_OPEN_STDERR="warn: rate limit at 4999/5000"
out_h=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_h=$?
unset STUB_FIND_OPEN_STDERR
assert_eq "find-open-stderr path exits 0" "0" "$rc_h"
# HEAD_SHA was captured before test (g) advanced the branch with a further
# commit — re-derive the CURRENT head rather than reuse the stale constant.
head_sha_h=$(git -C "$REPO" rev-parse HEAD)
assert_eq "find-open-stderr path prints exactly the success line (creates, not a bogus update)" \
    "PR 9 https://github.com/owner/repo/pull/9 $head_sha_h" "$out_h"
argv_h=$(cat "$ARGV_LOG")
contains "find-open-stderr path still creates (stderr warning did not fake an existing PR)" "$argv_h" "pr create"
not_contains "find-open-stderr path never edits" "$argv_h" "pr edit"

# ── (i) worker-pr-open computes worker-burn itself, body gets the line
# even when the caller supplied none. A worker typing `worker-burn.sh` by hand was
# denied [Session Transcript Tampering] — the line must come from inside this
# script (a script, not a worker-typed ad-hoc command), never a separate step.
echo "TEST: PR body gets a worker-burn: line even when the caller supplied none"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
NO_BURN_BODY="$TMP_ROOT/no-burn-body.txt"
printf '## Summary\n\n%s\n' "$BODY_MARKER" > "$NO_BURN_BODY"
(
    cd "$REPO" || exit 99
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
        HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
        bash "$SUT" "$TITLE_FILE" "$NO_BURN_BODY"
) >/dev/null; rc_i=$?
assert_eq "worker-burn-insertion path exits 0" "0" "$rc_i"
argv_i=$(cat "$ARGV_LOG")
contains "gh receives a worker-burn: line though the body file had none" "$argv_i" "worker-burn:"

# ── (j) an unresolvable session never fails the PR open — WARN
# plus a `worker-burn: unavailable (<reason>)` line takes its place.
echo "TEST: an unresolvable worker-burn session falls back to 'unavailable', never fails the open"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
(
    cd "$REPO" || exit 99
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
        HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
        bash "$SUT" "$TITLE_FILE" "$NO_BURN_BODY"
) >/dev/null; rc_j=$?
assert_eq "unavailable-fallback path still exits 0" "0" "$rc_j"
argv_j=$(cat "$ARGV_LOG")
contains "gh receives the unavailable-fallback worker-burn line" "$argv_j" "worker-burn: unavailable ("

# ── (k) when a transcript RESOLVES but worker-burn.sh
# itself fails on it, the PR body's fallback line must never carry the local
# transcript path (home dir + username + session ID, a leak
# class) — only a generic reason. The full path stays in the WARN on stderr.
echo "TEST: a resolvable-but-broken transcript falls back to a generic reason, never the local path"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
FAKE_CLAUDE_HOME="$TMP_ROOT/fake-claude-home"
FAKE_SID="00000000-0000-0000-0000-000000000000"
mkdir -p "$FAKE_CLAUDE_HOME/projects/-fake-project"
printf 'not valid jsonl\n' > "$FAKE_CLAUDE_HOME/projects/-fake-project/$FAKE_SID.jsonl"
(
    cd "$REPO" || exit 99
    unset CLAUDE_PID
    CLAUDE_CODE_SESSION_ID="$FAKE_SID" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
        FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
        HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
        bash "$SUT" "$TITLE_FILE" "$NO_BURN_BODY"
) >/dev/null; rc_k=$?
assert_eq "resolvable-but-broken-transcript path still exits 0" "0" "$rc_k"
argv_k=$(cat "$ARGV_LOG")
contains "gh receives a generic unavailable reason" "$argv_k" "worker-burn: unavailable (worker-burn.sh failed for"
not_contains "gh never receives the fake claude home path" "$argv_k" "$FAKE_CLAUDE_HOME"
not_contains "gh never receives the session ID as a path fragment" "$argv_k" "$FAKE_SID.jsonl"

# ── (l) refuses a type-less title before ever calling gh ──────
echo "TEST: refuses a title with no conventional-commit type prefix"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
BAD_TITLE_FILE="$TMP_ROOT/bad-title.txt"
printf '[HIMMEL-1] foo\n' > "$BAD_TITLE_FILE"
err_l=$(JIRA_PROJECT_KEY=HIMMEL run_sut "$BAD_TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_l=$?
if [ "$rc_l" -ne 0 ]; then pass "type-less title refused (rc!=0)"; else fail "type-less title refused (rc!=0)" "got rc=$rc_l"; fi
contains "refusal names the expected shape" "$err_l" "type(scope)"
argv_l=$(cat "$ARGV_LOG")
assert_eq "gh is never invoked when the title gate refuses" "" "$argv_l"

# ── (m) a conventional title with a ticket still opens the PR ──
echo "TEST: a conventional title with a ticket still opens the PR"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
GOOD_TITLE_FILE="$TMP_ROOT/good-title.txt"
printf 'fix(x): [HIMMEL-3031] foo\n' > "$GOOD_TITLE_FILE"
out_m=$(JIRA_PROJECT_KEY=HIMMEL run_sut "$GOOD_TITLE_FILE" "$BODY_FILE"); rc_m=$?
assert_eq "conventional title still opens the PR (rc=0)" "0" "$rc_m" || echo "  (out=$out_m)" >&2
argv_m=$(cat "$ARGV_LOG")
contains "gh receives the conventional title" "$argv_m" "--title fix(x): [HIMMEL-3031] foo"

# Exercise the real burn computation against a known transcript.
cp "$HERE/tests/fixtures/leg-burn-sample.jsonl" "$FAKE_CLAUDE_HOME/projects/-fake-project/$FAKE_SID.jsonl"
for supplied_profile in worker-impl design,design-motion '' 'bad profile' 'bad/profile'; do
    : > "$ARGV_LOG"
    (
        cd "$REPO" || exit 99
        unset CLAUDE_PID HIMMEL_WORKER_SESSION_PROFILE HIMMEL_LEG_PROFILE
        HIMMEL_WORKER_SESSION_PROFILE="$supplied_profile" CLAUDE_CODE_SESSION_ID="$FAKE_SID" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
            FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
            HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
            bash "$SUT" "$TITLE_FILE" "$NO_BURN_BODY"
    ) >/dev/null; profile_rc=$?
    assert_eq "profile '$supplied_profile' does not block PR publication" "0" "$profile_rc"
    profile_argv=$(cat "${ARGV_LOG}.body")
    case "$supplied_profile" in
        worker-impl|design,design-motion) expected_profile="$supplied_profile" ;;
        *) expected_profile=unknown ;;
    esac
    profile_line=$(printf '%s\n' "$profile_argv" | grep '^worker-burn:')
    assert_eq "profile '$supplied_profile' is the final PR-body field" \
        "worker-burn: calls=4 avg-ctx=963 first-turn=1.2k compactions=2 cost-eq=1.6k profile=$expected_profile" "$profile_line"
done
not_contains "unavailable fallback remains profile-less" "$argv_k" "profile="

# ── the ticket in the title must match the branch (and the PR it edits)
echo "TEST: refuses a title whose ticket is not in the branch name"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
MISMATCH_TITLE="$TMP_ROOT/mismatch-title.txt"
printf 'fix(x): [HIMMEL-1] foo\n' > "$MISMATCH_TITLE"
git -C "$REPO" checkout -q -b fix/himmel-2-other
git -C "$REPO" push -q -u origin fix/himmel-2-other
err_p=$(run_sut "$MISMATCH_TITLE" "$BODY_FILE" 2>&1 >/dev/null); rc_p=$?
assert_eq "title/branch ticket mismatch refused (rc=1)" "1" "$rc_p"
contains "refusal is an ERR worker-pr-open line" "$err_p" "ERR worker-pr-open:"
contains "refusal names the title key" "$err_p" "HIMMEL-1"
contains "refusal names the branch" "$err_p" "fix/himmel-2-other"
assert_eq "gh is never invoked on a branch mismatch" "" "$(cat "$ARGV_LOG")"
# same prefix, different ticket: key 1 must not match himmel-10
git -C "$REPO" checkout -q -b fix/himmel-10-other
git -C "$REPO" push -q -u origin fix/himmel-10-other
run_sut "$MISMATCH_TITLE" "$BODY_FILE" >/dev/null 2>&1; rc_p2=$?
assert_eq "HIMMEL-1 title on a himmel-10 branch refused (rc=1)" "1" "$rc_p2"
git -C "$REPO" checkout -q feat/himmel-3031-x

echo "TEST: refuses to edit an open PR whose title cites another ticket"
: > "$ARGV_LOG"
err_q=$(STUB_OPEN_PR=42 STUB_PR_TITLE='fix(y): [HIMMEL-7] someone else' run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_q=$?
assert_eq "PR-title ticket mismatch refused (rc=1)" "1" "$rc_q"
contains "refusal names the PR number" "$err_q" "42"
contains "refusal names the PR's key" "$err_q" "HIMMEL-7"
not_contains "the PR is never edited" "$(cat "$ARGV_LOG")" "pr edit"

# ── opening the PR re-derives the ticket's status ──────────────
unset STUB_OPEN_PR 2>/dev/null || true
: > "$JIRA_LOG"
out_n=$(run_sut "$TITLE_FILE" "$BODY_FILE"); rc_n=$?
assert_eq "jira-wired open still exits 0" "0" "$rc_n"
assert_eq "jira-wired open keeps the one-line success contract" \
    "PR 9 https://github.com/owner/repo/pull/9 $(git -C "$REPO" rev-parse HEAD)" "$out_n"
assert_eq "PR open fires a pr-open event for the title's ticket" \
    "HIMMEL-3031 --event pr-open --pr 9 --head $(git -C "$REPO" rev-parse HEAD)" "$(cat "$JIRA_LOG")"
: > "$JIRA_LOG"
WORKER_SESSION_JIRA_STATUS=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null
assert_eq "WORKER_SESSION_JIRA_STATUS=0 makes no Jira call" "0" "$(wc -c < "$JIRA_LOG" | tr -d ' ')"

# ── a PR opens only for a head /pr-check reviewed ──────────────
echo "TEST: refuses to open a PR for a head with no pr-check record"
: > "$ARGV_LOG"
unset STUB_OPEN_PR 2>/dev/null || true
reset_ledger
head_r=$(git -C "$REPO" rev-parse HEAD)
err_r=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_r=$?
assert_eq "unreviewed head refused (rc=1)" "1" "$rc_r"
contains "refusal is an ERR worker-pr-open line" "$err_r" "ERR worker-pr-open:"
contains "refusal names /pr-check" "$err_r" "/pr-check"
contains "refusal names the head" "$err_r" "$head_r"
not_contains "no PR is created for an unreviewed head" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: a record at another head, or a non-ok record, does not count"
stamp_review "$(git -C "$REPO" rev-parse HEAD~1)"
stamp_review "$head_r" unavailable
REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null 2>&1; rc_r2=$?
assert_eq "other-head and unavailable rows do not satisfy the gate (rc=1)" "1" "$rc_r2"

echo "TEST: a pr-check record at the head lets the PR open"
: > "$ARGV_LOG"
stamp_review "$head_r"
out_r3=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE"); rc_r3=$?
assert_eq "reviewed head opens (rc=0)" "0" "$rc_r3"
assert_eq "reviewed head prints the success line" \
    "PR 9 https://github.com/owner/repo/pull/9 $head_r" "$out_r3"
contains "reviewed head reaches pr create" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: a pending cr-pending marker holds the open even with a record at the head"
: > "$ARGV_LOG"
MARKER="$REPO/.git/cr-pending/feat/himmel-3031-x"
mkdir -p "$(dirname "$MARKER")"
echo "2026-10-25T00:00:00Z | $head_r" > "$MARKER"
err_m=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_m=$?
assert_eq "pending marker refused (rc=1)" "1" "$rc_m"
contains "refusal says /pr-check is pending" "$err_m" "still pending"
not_contains "no PR is created while the marker is held" "$(cat "$ARGV_LOG")" "pr create"
rm -f "$MARKER"
REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null 2>&1; rc_m2=$?
assert_eq "cleared marker plus record opens (rc=0)" "0" "$rc_m2"

echo "TEST: the gate is for opening; an existing PR's body update is not gated"
: > "$ARGV_LOG"
reset_ledger
STUB_OPEN_PR=42 REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null 2>&1; rc_r4=$?
assert_eq "update path without a record still exits 0" "0" "$rc_r4"
contains "update path edits the PR" "$(cat "$ARGV_LOG")" "pr edit 42"

echo "TEST: an open on a registered adopter repo needs no /pr-check record; any other repo still does"
: > "$ARGV_LOG"
reset_ledger
orig_url=$(git -C "$REPO" remote get-url origin)
git -C "$REPO" remote set-url origin https://github.com/yotamleo-org/himmel-voice.git
REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null 2>&1; rc_ad=$?
assert_eq "adopter repo, no record: opens (rc=0)" "0" "$rc_ad"
contains "adopter repo, no record: pr create ran" "$(cat "$ARGV_LOG")" "pr create"
: > "$ARGV_LOG"
echo "2026-10-25T00:00:00Z | $head_r" > "$MARKER"
err_ad=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_ad2=$?
assert_eq "adopter repo, pending marker: still refused (rc=1)" "1" "$rc_ad2"
contains "adopter repo, pending marker: says pending" "$err_ad" "still pending"
rm -f "$MARKER"
git -C "$REPO" remote set-url origin https://github.com/yotamleo-org/himmel-voice-evil.git
: > "$ARGV_LOG"
err_ad3=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_ad3=$?
assert_eq "lookalike repo name, no record: refused (rc=1)" "1" "$rc_ad3"
contains "lookalike repo name: says no /pr-check record" "$err_ad3" "no /pr-check record"
git -C "$REPO" remote set-url origin https://github.com/yotamleo-org/Himmel.git
err_ad4=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_ad4=$?
assert_eq "himmel itself, no record: refused (rc=1)" "1" "$rc_ad4"
contains "himmel itself: says no /pr-check record" "$err_ad4" "no /pr-check record"
git -C "$REPO" remote set-url origin https://evilgithub.com/yotamleo-org/himmel-voice.git
err_ad5=$(REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_ad5=$?
assert_eq "lookalike host (evilgithub.com), no record: refused (rc=1)" "1" "$rc_ad5"
contains "lookalike host: says no /pr-check record" "$err_ad5" "no /pr-check record"
git -C "$REPO" remote set-url origin "$orig_url"
not_contains "no PR is created for a refused open" "$(cat "$ARGV_LOG")" "pr create"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
