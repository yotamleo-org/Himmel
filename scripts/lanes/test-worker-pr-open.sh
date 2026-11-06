#!/usr/bin/env bash
# scripts/lanes/test-worker-pr-open.sh - Hermetic tests for
# worker-pr-open.sh: a GH_CMD stub records every argv line to a file, so the
# assertion that matters (the PR body text appears ONLY as the --body value
# the forge seam passes to gh, never in the Bash command a worker types) is a
# grep, not a guess. No network, no real gh/PR.
#
# Platform guard: Bash plus git (same requirements as the SUT it exercises).
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

# The PR claim writes rows under ~/.himmel/state/holds and judges holders through queue-lock.sh: HOME, the handover root
# and the lock runtime dirs are pinned to the temp dir, and a worker's own hold variables are dropped, so no row of this
# run lands in the real register (a row at the end proves it) and a leg running this suite does not feed its key in.
REAL_HOME="$HOME"
export HOME="$TMP_ROOT/home" HANDOVER_DIR="$TMP_ROOT/h" XDG_RUNTIME_DIR="$TMP_ROOT/xdg" HIMMELCTL_CACHE_DIR="$TMP_ROOT/cache" HIMMEL_CONFIG_DIR="$TMP_ROOT/cfg"
mkdir -p "$HOME" "$HANDOVER_DIR/u/r" "$XDG_RUNTIME_DIR" "$HIMMELCTL_CACHE_DIR" "$HIMMEL_CONFIG_DIR" "$TMP_ROOT/bin"
chmod 700 "$XDG_RUNTIME_DIR"
: > "$HIMMELCTL_CACHE_DIR/.env"
unset HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_DOC HIMMEL_HOLD_KEY HIMMEL_HOLD_DOC HIMMEL_HOLD_LABEL WRITE_HOLD_OK HOLDS_QUEUE_LOCK HOLDS_GH QUEUE_LOCK_TTL_SECONDS

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
        unset CLAUDE_PID HIMMEL_WORKER_SESSION_PROFILE
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
        "worker-burn: calls=4 avg-ctx=963 first-turn=1.2k compactions=2 cost-eq=1.6k unknown-model-calls=4 profile=$expected_profile" "$profile_line"
done
not_contains "unavailable fallback remains profile-less" "$argv_k" "profile="

# A KNOWN-model transcript: calls= must be the call count, not the unknown-model-calls= tail of the raw line.
printf '%s\n' \
    '{"type":"assistant","message":{"id":"k1","model":"claude-opus-5-5-20261001","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":1}}}' \
    '{"type":"assistant","message":{"id":"k2","model":"claude-opus-5-5-20261001","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":1,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0,"output_tokens":1}}}' \
    > "$FAKE_CLAUDE_HOME/projects/-fake-project/$FAKE_SID.jsonl"
: > "$ARGV_LOG"
(
    cd "$REPO" || exit 99
    unset CLAUDE_PID HIMMEL_WORKER_SESSION_PROFILE
    CLAUDE_CODE_SESSION_ID="$FAKE_SID" CLAUDE_CONFIG_DIR="$FAKE_CLAUDE_HOME" \
        FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" \
        HEAD_SHA_STUB="$HEAD_SHA" JIRA_PROJECT_KEY=HIMMEL \
        bash "$SUT" "$TITLE_FILE" "$NO_BURN_BODY"
) >/dev/null
known_line=$(grep '^worker-burn:' "${ARGV_LOG}.body")
contains "known-model transcript: calls= is the call count" "$known_line" "worker-burn: calls=2 "
not_contains "known-model transcript: no unknown-model note" "$known_line" "unknown-model-calls="

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

echo "TEST: a sync PR on a registered fork is refused in-script (the Bash hook never sees the seam's gh call)"
# The fork check calls `gh api` from PATH: 100 commits in the PR, ITS_OURS of
# them ours (ahead of upstream v8 at the head, none at the merge-base mb0).
mkdir -p "$TMP_ROOT/hookbin"
cat > "$TMP_ROOT/hookbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "api repos/Graphify-Labs/graphify --jq .default_branch") echo v8 ;;
  "api repos/yotamleo-org/graphify/compare/Graphify-Labs:v8...mb0 "*) echo 0 ;;
  "api repos/yotamleo-org/graphify/compare/Graphify-Labs:v8..."*) echo "$ITS_OURS" ;;
  "api repos/yotamleo-org/graphify/compare/"*) printf '100\tmb0\n' ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$TMP_ROOT/hookbin/gh"
git -C "$REPO" remote set-url origin https://github.com/yotamleo-org/graphify.git
: > "$ARGV_LOG"
err_fs=$(PATH="$TMP_ROOT/hookbin:$PATH" ITS_OURS=1 REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_fs=$?
assert_eq "fork sync PR: refused (rc=1)" "1" "$rc_fs"
contains "fork sync PR: names the resync replacement" "$err_fs" "resync-fork.sh --sync yotamleo-org/graphify"
not_contains "fork sync PR: no PR is created" "$(cat "$ARGV_LOG")" "pr create"
PATH="$TMP_ROOT/hookbin:$PATH" ITS_OURS=60 REVIEW_ROW=0 run_sut "$TITLE_FILE" "$BODY_FILE" >/dev/null 2>&1; rc_fo=$?
assert_eq "fork PR of our own delta: opens (rc=0)" "0" "$rc_fo"
contains "fork PR of our own delta: pr create ran" "$(cat "$ARGV_LOG")" "pr create"
git -C "$REPO" remote set-url origin "$orig_url"

# ── PR size bands: warn past the soft max, refuse past CodeRabbit's 300-file cap ──
size_branch() {  # <name> <file-count> <lines-per-file>: a pushed branch cut from origin/main
    git -C "$REPO" checkout -q -b "$1" origin/main
    local d="$REPO/sz-$1" i
    mkdir -p "$d"
    for ((i = 1; i <= $2; i++)); do seq "$3" > "$d/f$i"; done
    git -C "$REPO" add "sz-$1"
    git -C "$REPO" commit -qm "size fixture $1"
    git -C "$REPO" push -q -u origin "$1"
}

echo "TEST: a branch of 301 changed files is refused with SIZE-REFUSE and no pr create"
reset_ledger
size_branch feat/himmel-3031-files301 301 1
: > "$ARGV_LOG"
err_s1=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_s1=$?
assert_eq "301 files: refused (rc=1)" "1" "$rc_s1"
contains "301 files: names the count and the cap" "$err_s1" "SIZE-REFUSE files=301 cap=300"
not_contains "301 files: no pr create call" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: exactly 300 files opens (the cap is over 300)"
size_branch feat/himmel-3031-files300 300 1
: > "$ARGV_LOG"
err_s2=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_s2=$?
assert_eq "300 files: opens (rc=0)" "0" "$rc_s2"
not_contains "300 files: no SIZE-REFUSE" "$err_s2" "SIZE-REFUSE"
contains "300 files: warns on the file count" "$err_s2" "SIZE-WARN lines=300 files=300"
contains "300 files: pr create ran" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: a 900-line branch warns and still opens"
size_branch feat/himmel-3031-lines900 1 900
: > "$ARGV_LOG"
out_s3=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>"$TMP_ROOT/size.err"); rc_s3=$?
assert_eq "900 lines: opens (rc=0)" "0" "$rc_s3"
contains "900 lines: SIZE-WARN names lines and files" "$(cat "$TMP_ROOT/size.err")" "SIZE-WARN lines=900 files=1"
contains "900 lines: stdout stays the one PR line" "$out_s3" "PR 9 "
contains "900 lines: pr create ran" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: a branch inside the target band prints no size line"
size_branch feat/himmel-3031-lines800 1 800
: > "$ARGV_LOG"
err_s4=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_s4=$?
assert_eq "800 lines: opens (rc=0)" "0" "$rc_s4"
not_contains "800 lines: no SIZE- line" "$err_s4" "SIZE-"

echo "TEST: a diff that cannot be measured is refused, never read as zero files"
git -C "$REPO" checkout -q --orphan feat/himmel-3031-nomergebase
git -C "$REPO" rm -rfq --cached . >/dev/null
echo orphan > "$REPO/orphan-file"
git -C "$REPO" add orphan-file
git -C "$REPO" commit -qm "no merge base with origin/main"
git -C "$REPO" push -q -u origin feat/himmel-3031-nomergebase
: > "$ARGV_LOG"
err_s5=$(run_sut "$TITLE_FILE" "$BODY_FILE" 2>&1 >/dev/null); rc_s5=$?
assert_eq "no merge base: refused (rc=1)" "1" "$rc_s5"
contains "no merge base: says the size could not be measured" "$err_s5" "could not measure"
not_contains "no merge base: no pr create call" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: a base ref that is not fetched is refused, never read as within the bands"
: > "$ARGV_LOG"
err_s6=$(run_sut "$TITLE_FILE" "$BODY_FILE" --base no-such-base 2>&1 >/dev/null); rc_s6=$?
assert_eq "unfetched base: refused (rc=1)" "1" "$rc_s6"
contains "unfetched base: says the size could not be measured" "$err_s6" "could not measure"
not_contains "unfetched base: no pr create call" "$(cat "$ARGV_LOG")" "pr create"

# ── a PR claims its files and names those outside Writes (holds.py narrow) ───────────────────────────────────────
# A separate fixture repo, HOME pinned above. Locks are real queue-lock.sh locks under the temp handover root; gh is a stub.
HOLDS_PY="$HERE/../handover/chief-kit/holds.py"
QL="$HERE/../handover/queue-lock.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/bin/gh-fail"
chmod +x "$TMP_ROOT/bin/gh-fail"
H_BARE="$TMP_ROOT/h-origin.git"
H_REPO="$TMP_ROOT/h-repo"
git init -q --bare "$H_BARE"
git init -q -b main "$H_REPO" 2>/dev/null || { git init -q "$H_REPO"; git -C "$H_REPO" checkout -q -b main; }
git -C "$H_REPO" config user.email t@t.t
git -C "$H_REPO" config user.name test
git -C "$H_REPO" remote add origin "$H_BARE"
mkdir -p "$H_REPO/scripts/dir"
for f in a b c; do echo base > "$H_REPO/scripts/$f.sh"; done
echo base > "$H_REPO/scripts/dir/seed.sh"
git -C "$H_REPO" add -A
git -C "$H_REPO" commit -qm base
git -C "$H_REPO" push -q origin main
H_COMMON=$(git -C "$H_REPO" rev-parse --path-format=absolute --git-common-dir)
H_PRIMARY="${H_COMMON%/.git}"
H_LEDGER="$H_COMMON/cr-critic-scores.jsonl"
H_DIR="$H_REPO"
H_REG="$HOME/.himmel/state/holds"

hesc() { local s="${1//%/%25}"; printf '%s' "${s//\//%2F}"; }
hfile() { printf '%s/%s/%s' "$H_REG" "$(hesc "$H_PRIMARY")" "$(hesc "$1")"; }
hrow() { cat "$(hfile "$1")" 2>/dev/null; }
trow() { printf '%s\t%s\t%s\t%s\t%s' "$@"; }
hreset() { rm -rf "$H_REG"; : > "$ARGV_LOG"; }
age_file() { python3 -I -c 'import os, sys, time; t = time.time() - 7200; os.utime(sys.argv[1], (t, t))' "$1"; }
put_hrow() {  # <path> <key> <label> <doc> <source> <pr>: a row written by hand, aged past the arm grace
    local f
    f=$(hfile "$1")
    mkdir -p "$(dirname "$f")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$4" "$5" "$6" > "$f"
    age_file "$f"
}
hdoc() {  # <name> <writes text> [extra line]: a worker doc under the temp handover bucket; prints its path
    local f="$HANDOVER_DIR/u/r/$1"
    { printf '# worker doc\n\n> **Writes:** %s\n' "$2"; [ -z "${3:-}" ] || printf '\n%s\n' "$3"; } > "$f"
    printf '%s' "$f"
}
hbranch() {  # <branch> <file>...: a pushed branch cut from origin/main that changes each file; left checked out in H_REPO
    local br="$1" f
    shift
    git -C "$H_REPO" checkout -q -b "$br" origin/main
    for f in "$@"; do mkdir -p "$(dirname "$H_REPO/$f")"; echo "change $br" >> "$H_REPO/$f"; done
    git -C "$H_REPO" add -A
    git -C "$H_REPO" commit -qm "fixture $br"
    git -C "$H_REPO" push -q -u origin "$br"
}
run_h() {  # the SUT from H_DIR at its current head; the body is H_BODY or the shared one
    local head
    head=$(git -C "$H_DIR" rev-parse HEAD)
    printf '{"kind":"avail","ts":"2026-10-25T00:00:00Z","branch":"b","head":"%s","model":"codex","status":"ok","artifact":"diff","perspective":"off"}\n' "$head" >> "$H_LEDGER"
    (
        cd "$H_DIR" || exit 99
        FORGE=github CR_APP=0 GH_CMD="$GH_STUB" ARGV_LOG="$ARGV_LOG" HEAD_SHA_STUB="$head" JIRA_PROJECT_KEY=HIMMEL \
            HOLDS_GH="$TMP_ROOT/bin/gh-fail" bash "$SUT" "$TITLE_FILE" "${H_BODY:-$BODY_FILE}"
    )
}
ow_line() { grep '^outside-writes:' "${ARGV_LOG}.body" || true; }

H_KEY=HIMMEL-8801
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh")
export HIMMEL_HOLD_KEY="$H_KEY" HIMMEL_HOLD_DOC="$D1" HIMMEL_HOLD_LABEL=N1
DR=$(hdoc HIMMEL-9999-r.md "scripts/a.sh")
bash "$QL" acquire "$DR" sess-rival >/dev/null 2>&1
H_RIVAL=HIMMEL-9999
put_rival() {  # <path>: a live rival's row (aged past the grace, its lock held)
    put_hrow "$1" "$H_RIVAL" rival "$DR" brief ""
}

echo "TEST: PR claim — a claim outside Writes is named and stays claim (I6); a PR file with no row gets one"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh")
put_hrow scripts/b.sh "$H_KEY" N1 "$D1" claim ""
hbranch feat/himmel-3031-h1 scripts/a.sh scripts/b.sh
out_h1=$(run_h 2>"$TMP_ROOT/h.err"); rc_h1=$?
assert_eq "claim: the open exits 0" "0" "$rc_h1"
assert_eq "claim: stdout stays the one PR line" "PR 9 https://github.com/owner/repo/pull/9 $(git -C "$H_REPO" rev-parse HEAD)" "$out_h1"
assert_eq "claim: the body names the file outside Writes" "outside-writes: scripts/b.sh" "$(ow_line)"
assert_eq "claim: the claim row stays claim and takes the PR" "$(trow "$H_KEY" N1 "$D1" claim 9)" "$(hrow scripts/b.sh)"
assert_eq "claim: a file with no earlier row gets a pr row with the doc and label" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"

echo "TEST: PR claim — a file inside a tree in Writes is not on the line"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/dir/ scripts/a.sh")
hbranch feat/himmel-3031-h2 scripts/dir/new.sh scripts/a.sh
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h2=$?
assert_eq "tree: the open exits 0" "0" "$rc_h2"
assert_eq "tree: nothing is outside Writes" "outside-writes: none" "$(ow_line)"

echo "TEST: PR claim — a seeded file unchanged in the PR is freed (I12: the new row carries its doc)"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh")
put_hrow scripts/a.sh "$H_KEY" N1 "$D1" brief ""
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
hbranch feat/himmel-3031-h3 scripts/a.sh
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h3=$?
assert_eq "freed: the open exits 0" "0" "$rc_h3"
assert_eq "freed: the unchanged seeded file has no row" "" "$(hrow scripts/c.sh)"
assert_eq "freed: the changed seeded file becomes the PR's row" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"
bash "$QL" acquire "$D1" sess-self >/dev/null 2>&1
age_file "$(hfile scripts/a.sh)"
alive_h3=$(HOLDS_GH="$TMP_ROOT/bin/gh-fail" python3 -I "$HOLDS_PY" alive --repo "$H_PRIMARY" scripts/a.sh 2>/dev/null)
assert_eq "I12: the row aged past the grace, its holder's lock held, reads alive" "alive" "$alive_h3"
D2=$(hdoc HIMMEL-8802-w.md "scripts/c.sh")
hbranch feat/himmel-3031-h3b scripts/c.sh
HIMMEL_HOLD_KEY=HIMMEL-8802 HIMMEL_HOLD_DOC="$D2" run_h >/dev/null 2>"$TMP_ROOT/h.err"
age_file "$(hfile scripts/c.sh)"
alive_h3b=$(HOLDS_GH="$TMP_ROOT/bin/gh-fail" python3 -I "$HOLDS_PY" alive --repo "$H_PRIMARY" scripts/c.sh 2>/dev/null)
if [ "$alive_h3b" = alive ]; then fail "I12: a row whose holder's lock is not held does not read alive" "got $alive_h3b"; else pass "I12: a row whose holder's lock is not held does not read alive"; fi

echo "TEST: PR claim — no hold doc opens the PR with 'unavailable (no hold key)' and publishes no row"
hreset
hbranch feat/himmel-3031-h5 scripts/a.sh
HIMMEL_HOLD_DOC='' run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h5=$?
assert_eq "no doc: the open exits 0" "0" "$rc_h5"
assert_eq "no doc: the body says why" "outside-writes: unavailable (no hold key)" "$(ow_line)"
assert_eq "no doc: no row is published" "" "$(hrow scripts/a.sh)"

echo "TEST: PR claim — a PR file a live rival holds refuses the open and names it; a grant opens it"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh")
put_rival scripts/a.sh
hbranch feat/himmel-3031-h6 scripts/a.sh
err_h6=$(run_h 2>&1 >/dev/null); rc_h6=$?
assert_eq "rival: the open is refused (rc=1)" "1" "$rc_h6"
contains "rival: stderr is a holds: line naming the holder" "$err_h6" "holds: scripts/a.sh is held by HIMMEL-9999"
not_contains "rival: no PR is created" "$(cat "$ARGV_LOG")" "pr create"
assert_eq "rival: the rival's row is untouched" "$(trow "$H_RIVAL" rival "$DR" brief '')" "$(hrow scripts/a.sh)"
printf 'granted\t2026-11-06T00:00:00Z\tchief\tsess\n' > "$(hfile scripts/a.sh).grant.$H_KEY"
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h6g=$?
assert_eq "rival: a granted file opens (rc=0)" "0" "$rc_h6g"
contains "rival: a granted open reaches pr create" "$(cat "$ARGV_LOG")" "pr create"

echo "TEST: PR claim — a size refusal leaves the rows unchanged"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh")
put_hrow scripts/a.sh "$H_KEY" N1 "$D1" brief ""
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
before_h7="$(hrow scripts/a.sh)|$(hrow scripts/c.sh)"
many=()
for ((i = 1; i <= 301; i++)); do many+=("scripts/many/f$i"); done
many+=(scripts/a.sh)
hbranch feat/himmel-3031-h7 "${many[@]}"
err_h7=$(run_h 2>&1 >/dev/null); rc_h7=$?
assert_eq "size: refused (rc=1)" "1" "$rc_h7"
contains "size: SIZE-REFUSE" "$err_h7" "SIZE-REFUSE"
assert_eq "size: both rows are unchanged" "$before_h7" "$(hrow scripts/a.sh)|$(hrow scripts/c.sh)"

echo "TEST: PR claim — a merge-forward with a third party's file in main's delta claims nothing"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/own.sh")
git -C "$H_REPO" checkout -q -b feat/himmel-3031-h8 origin/main
echo own > "$H_REPO/scripts/own.sh"
git -C "$H_REPO" add -A
git -C "$H_REPO" commit -qm "own file"
git -C "$H_REPO" push -q -u origin feat/himmel-3031-h8
git -C "$H_REPO" checkout -q main
echo third > "$H_REPO/scripts/third.sh"
git -C "$H_REPO" add -A
git -C "$H_REPO" commit -qm "third party"
git -C "$H_REPO" push -q origin main
git -C "$H_REPO" checkout -q feat/himmel-3031-h8
git -C "$H_REPO" merge -q --no-edit main >/dev/null 2>&1
git -C "$H_REPO" push -q origin feat/himmel-3031-h8
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h8=$?
assert_eq "merge-forward: the open exits 0" "0" "$rc_h8"
assert_eq "merge-forward: only the worker's file is claimed" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/own.sh)"
assert_eq "merge-forward: the third party's file has no row" "" "$(hrow scripts/third.sh)"
assert_eq "merge-forward: the line does not name it" "outside-writes: none" "$(ow_line)"

echo "TEST: PR claim — an update of an open PR prints the line once, and a rival's later row refuses nothing"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh")
OW_BODY="$TMP_ROOT/ow-body.txt"
{ cat "$BODY_FILE"; echo "outside-writes: stale"; } > "$OW_BODY"
hbranch feat/himmel-3031-h9 scripts/a.sh scripts/b.sh
put_rival scripts/b.sh
for _ in 1 2; do
    : > "$ARGV_LOG"
    H_BODY="$OW_BODY" STUB_OPEN_PR=42 run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h9=$?
    assert_eq "update: the body update exits 0 with a rival holding a PR file" "0" "$rc_h9"
    assert_eq "update: exactly one outside-writes line, the fresh one" "outside-writes: scripts/b.sh" "$(ow_line)"
done
contains "update: the PR is edited, not created" "$(cat "$ARGV_LOG")" "pr edit 42"
not_contains "update: no pr create" "$(cat "$ARGV_LOG")" "pr create"
assert_eq "update: the rival's row is untouched" "$(trow "$H_RIVAL" rival "$DR" brief '')" "$(hrow scripts/b.sh)"
assert_eq "update: the worker's row takes the PR number" "$(trow "$H_KEY" N1 "$D1" pr 42)" "$(hrow scripts/a.sh)"

echo "TEST: PR claim — a second PR on one key keeps the first PR's rows"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh")
hbranch feat/himmel-3031-h10a scripts/a.sh
run_h >/dev/null 2>"$TMP_ROOT/h.err"
hbranch feat/himmel-3031-h10b scripts/c.sh
STUB_OPEN_PR=10 run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h10=$?
assert_eq "second PR: exits 0" "0" "$rc_h10"
assert_eq "second PR: the first PR's row stays" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"
assert_eq "second PR: its own file is its row" "$(trow "$H_KEY" N1 "$D1" pr 10)" "$(hrow scripts/c.sh)"

echo "TEST: PR claim — a PR file that cannot be registered leaves the unchanged rows in place"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh")
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
long_name="scripts/$(printf '%0250d' 0).sh"
hbranch feat/himmel-3031-h16 scripts/a.sh "$long_name"
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h16=$?
assert_eq "unregistrable file: the open exits 0" "0" "$rc_h16"
assert_eq "unregistrable file: the registrable file is the PR's row" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"
assert_eq "unregistrable file: the unchanged seeded row is not freed" "$(trow "$H_KEY" N1 "$D1" brief '')" "$(hrow scripts/c.sh)"
contains "unregistrable file: the line still names it" "$(ow_line)" "$long_name"

echo "TEST: PR claim — a doc with a Series line frees nothing"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh" "> **Series:** s1 $TMP_ROOT/ledger.md - read it")
put_hrow scripts/a.sh "$H_KEY" N1 "$D1" brief ""
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
hbranch feat/himmel-3031-h11 scripts/a.sh
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h11=$?
assert_eq "series: exits 0" "0" "$rc_h11"
assert_eq "series: the unchanged seeded file keeps its row" "$(trow "$H_KEY" N1 "$D1" brief '')" "$(hrow scripts/c.sh)"
assert_eq "series: the changed file is still claimed for the PR" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"

echo "TEST: PR claim — from a linked worktree the diff is the worker's, and the rows are the primary's"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh scripts/c.sh")
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
git -C "$H_REPO" checkout -q main
git -C "$H_REPO" worktree add -q -b feat/himmel-3031-h12 "$TMP_ROOT/h-wt" origin/main
echo wt >> "$TMP_ROOT/h-wt/scripts/a.sh"
git -C "$TMP_ROOT/h-wt" add -A
git -C "$TMP_ROOT/h-wt" commit -qm "worktree change"
git -C "$TMP_ROOT/h-wt" push -q -u origin feat/himmel-3031-h12
H_DIR="$TMP_ROOT/h-wt" run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h12=$?
assert_eq "worktree: exits 0" "0" "$rc_h12"
assert_eq "worktree: the worker's file is the PR's row" "$(trow "$H_KEY" N1 "$D1" pr 9)" "$(hrow scripts/a.sh)"
assert_eq "worktree: the unchanged seeded file is freed" "" "$(hrow scripts/c.sh)"
assert_eq "worktree: nothing outside Writes" "outside-writes: none" "$(ow_line)"

echo "TEST: PR claim — an empty diff frees nothing and prints unavailable"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/c.sh")
put_hrow scripts/c.sh "$H_KEY" N1 "$D1" brief ""
git -C "$H_REPO" checkout -q -b feat/himmel-3031-h13 origin/main
git -C "$H_REPO" push -q -u origin feat/himmel-3031-h13
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h13=$?
assert_eq "empty diff: exits 0" "0" "$rc_h13"
contains "empty diff: the line is unavailable" "$(ow_line)" "outside-writes: unavailable ("
assert_eq "empty diff: the seeded row stays" "$(trow "$H_KEY" N1 "$D1" brief '')" "$(hrow scripts/c.sh)"

echo "TEST: PR claim — OFF, WRITE_HOLD_OK=1 and the marker each open the PR with a rival's file; the line is still printed"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/c.sh")
put_rival scripts/a.sh
hbranch feat/himmel-3031-h14 scripts/a.sh scripts/c.sh
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h14=$?
assert_eq "bypass control: without a bypass the rival refuses (rc=1)" "1" "$rc_h14"
mkdir -p "$H_REG"
: > "$H_REG/OFF"
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h14a=$?
rm -f "$H_REG/OFF"
assert_eq "OFF: opens (rc=0)" "0" "$rc_h14a"
assert_eq "OFF: the line is still printed" "outside-writes: scripts/a.sh" "$(ow_line)"
WRITE_HOLD_OK=1 run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h14b=$?
assert_eq "WRITE_HOLD_OK=1: opens (rc=0)" "0" "$rc_h14b"
: > "$H_PRIMARY/.single-writer"
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h14c=$?
rm -f "$H_PRIMARY/.single-writer"
assert_eq "the .single-writer marker: opens (rc=0)" "0" "$rc_h14c"

echo "TEST: PR claim — an unreadable register still opens the PR, unavailable"
hreset
D1=$(hdoc HIMMEL-8801-w.md "scripts/a.sh")
hbranch feat/himmel-3031-h15 scripts/a.sh
mkdir -p "$HOME/.himmel/state"
rm -rf "$H_REG"
: > "$H_REG"
run_h >/dev/null 2>"$TMP_ROOT/h.err"; rc_h15=$?
rm -f "$H_REG"
assert_eq "unreadable register: the PR opens (rc=0)" "0" "$rc_h15"
contains "unreadable register: the line is unavailable" "$(ow_line)" "outside-writes: unavailable ("

echo "TEST: PR claim — no row of this run reached the real register"
real_hits=$(grep -rl -- "$TMP_ROOT" "$REAL_HOME/.himmel/state/holds" 2>/dev/null || true)
assert_eq "the real register holds nothing of this run" "" "$real_hits"

echo
echo "===================================="
echo "test summary: $PASS passed, $FAIL failed"
echo "===================================="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
