#!/usr/bin/env bash
# scripts/cr/test-panel-first-pass.sh -- smoke test for panel-first-pass.sh
# Bash 3.2 safe.
#
# Hermetic: builds a throwaway git repo under mktemp plus a throwaway
# "scripts" tree that mirrors the real scripts/cr, scripts/guardrails,
# scripts/lib layout -- a COPY of panel-first-pass.sh under test, REAL
# (unmodified) copies of guardrails/lib.sh and lib/load-dotenv.sh (this
# suite does not re-test default_branch/load_dotenv), and a STUBBED
# critic-panel.sh so no run ever reaches the real one, which spends the
# operator's paid OpenAI bank. The stub is a PATH-side fixture, not a
# test-only env seam added to panel-first-pass.sh itself: the script under
# test always resolves critic-panel.sh from its own HIMMEL_ROOT, so pointing
# HIMMEL_ROOT at the fixture tree is enough to intercept the call.
#
# No network: the panel is stubbed and the real `rtk` binary (if installed
# on this operator's machine) is excluded from PATH below, so the rc=1
# fail-open case never nondeterministically takes the rtk-retry branch.
# No writes outside the fixture: asserted at the end by checking the script's
# own mktemp scratch files (cr-panel-avail.*) never survive in the shared
# system temp dir. (A whole-repo `git status --porcelain` diff was tried
# first and dropped: this worktree has other workers committing
# unrelated scripts/cr/* files concurrently, so that diff is contaminated by
# noise that has nothing to do with this script.)
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$HERE/../lib/fixture-tempdir.sh"
tmp="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$tmp"' EXIT
fail=0

ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

# assert_has <haystack> <needle> <label>
assert_has() {
    case "$1" in
        *"$2"*) ok "$3" ;;
        *) bad "$3 (missing '$2'; got: $1)" ;;
    esac
}
# assert_lacks <haystack> <needle> <label>
assert_lacks() {
    case "$1" in
        *"$2"*) bad "$3 (unexpectedly contains '$2'; got: $1)" ;;
        *) ok "$3" ;;
    esac
}

# _list_panel_avail_tmp -- portable (Git Bash / BSD / GNU) replacement for
# `find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cr-panel-avail.*'` (and the
# cr-pfp-ctx.* context file): -maxdepth is
# GNU-only. A subshell-scoped nullglob keeps the glob from leaking the
# literal pattern when nothing matches, without touching the caller's shopts.
_list_panel_avail_tmp() {
    (
        shopt -s nullglob
        for f in "${TMPDIR:-/tmp}"/cr-panel-avail.* "${TMPDIR:-/tmp}"/cr-pfp-ctx.*; do
            printf '%s\n' "$f"
        done
    ) | sort
}

# --- keep the suite hermetic: drop a real rtk off PATH if present -----------
_rtk_bin="$(command -v rtk 2>/dev/null || true)"
if [ -n "$_rtk_bin" ]; then
    _rtk_dir="$(dirname "$_rtk_bin")"
    _newpath=""
    _old_ifs="$IFS"; IFS=':'
    for _p in $PATH; do
        if [ "$_p" != "$_rtk_dir" ]; then
            _newpath="${_newpath:+$_newpath:}$_p"
        fi
    done
    IFS="$_old_ifs"
    PATH="$_newpath"; export PATH
fi

# Native rows below expect a real fetch: a suite run from inside a claudex
# session must not inherit that lane (T22-T24 set it themselves).
unset HIMMEL_SESSION_LANE

# --- fixture "scripts" tree --------------------------------------------------
fx="$tmp/fx"
mkdir -p "$fx/scripts/cr" "$fx/scripts/guardrails" "$fx/scripts/lib"
cp "$HERE/panel-first-pass.sh" "$fx/scripts/cr/panel-first-pass.sh"
cp "$HERE/anchor-handoff.sh" "$fx/scripts/cr/anchor-handoff.sh"
cp "$HERE/base-resolver.sh" "$fx/scripts/cr/base-resolver.sh"
cp "$HERE/review-round.sh" "$fx/scripts/cr/review-round.sh"
cp "$HERE/ledger-amend-auth.js" "$fx/scripts/cr/ledger-amend-auth.js"
cp "$HERE/known-findings.sh" "$HERE/known-findings.json" "$HERE/ledger-append.sh" "$HERE/critic-pre-existing-tag.py" "$fx/scripts/cr/"
cp "$HERE/../guardrails/lib.sh" "$fx/scripts/guardrails/lib.sh"
cp "$HERE/../lib/load-dotenv.sh" "$fx/scripts/lib/load-dotenv.sh"
cp "$HERE/../lib/shared-branch-lock.sh" "$fx/scripts/lib/shared-branch-lock.sh"
chmod +x "$fx/scripts/cr/panel-first-pass.sh"
mkdir -p "$fx/scripts/ledger"
cp "$HERE/../ledger/ceiling-lookup.sh" "$HERE/../ledger/ledger-lib.sh" "$fx/scripts/ledger/"
cp "$HERE/../lib/session-lane.sh" "$fx/scripts/lib/session-lane.sh"
export HIMMEL_REPO="$fx" HIMMEL_CEILINGS_LEDGER="$tmp/no-ceilings-ledger.tsv"
case "$HIMMEL_CEILINGS_LEDGER" in "$tmp"/*) ok "the ceilings ledger is pinned inside the fixture" ;; *) bad "the ceilings ledger escapes the fixture"; exit 1 ;; esac
assert_no_ceilings() { assert_lacks "$1" "CEILINGS:" "$2 prints no CEILINGS header"; }
ceilings_count() { printf '%s\n' "$1" | grep -c '^CEILINGS:' | tr -d ' '; }

CALL_LOG="$tmp/panel-calls.log"
export CALL_LOG
# ARGS_LOG records the stub's argv so a test can assert WHICH base literal the
# panel actually received (capture-once, T12).
ARGS_LOG="$tmp/panel-args.log"
export ARGS_LOG
cat > "$fx/scripts/cr/critic-panel.sh" <<'STUBEOF'
#!/usr/bin/env bash
case " $* " in *" --pin-ref refs/himmel/outside/0..0 "*) echo "critic-panel.sh: REFUSING --pin-ref refs/himmel/outside/0..0 — not a commit (stub of the real refusal)" >&2; exit 7 ;; esac
printf 'called\n' >> "$CALL_LOG"
printf '%s\n' "$*" >> "$ARGS_LOG"
# STDIN_LOG keeps the diff the panel was handed; CTX_COPY keeps the context
# file it was handed (the script under test removes its own copy on exit).
if [ -n "${STDIN_LOG:-}" ]; then cat > "$STDIN_LOG"; else cat >/dev/null; fi
if [ -n "${CTX_COPY:-}" ]; then
    _prev=""
    for _a in "$@"; do
        if [ "$_prev" = "--context-file" ] && [ -n "$_a" ] && [ -f "$_a" ]; then cp "$_a" "$CTX_COPY"; fi
        _prev="$_a"
    done
fi
if [ -n "${PROBE_LEDGER:-}" ]; then
    if grep -qF '"kind":"preflight"' "$PROBE_LEDGER" 2>/dev/null; then echo yes; else echo no; fi > "$PROBE_OUT"
fi
[ -n "${FAKE_OUT:-}" ] && printf '%s\n' "$FAKE_OUT"
[ -n "${FAKE_ERR:-}" ] && printf '%s\n' "$FAKE_ERR" >&2
if [ -n "${FAKE_RC_RETRY:-}" ] && [ "$(wc -l < "$CALL_LOG")" -gt 1 ]; then exit "$FAKE_RC_RETRY"; fi
exit "${FAKE_RC:-0}"
STUBEOF
chmod +x "$fx/scripts/cr/critic-panel.sh"
SCRIPT="$fx/scripts/cr/panel-first-pass.sh"

# review-round.sh verifies --base-sha against the remote through
# `gh api repos/<o>/<r>/compare/<sha>...<branch>`. This fixture has no GitHub
# remote, so a PATH-side gh stub answers that one call (review-round.sh keeps
# calling the real gh from PATH; there is no env seam that skips the check).
mkdir -p "$tmp/ghbin"
cat > "$tmp/ghbin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
    case "${2:-}" in
        repos/*/compare/*)
            [ "${GH_COMPARE_RC:-0}" = 0 ] || exit "$GH_COMPARE_RC"
            _br="${2##*...}"
            if [ "$_br" = "${GH_REMOTE_DEFAULT:-main}" ]; then
                printf '%s\n' "${GH_COMPARE_STATUS:-ahead}"
            else
                printf 'identical\n'
            fi
            exit 0 ;;
        'repos/{owner}/{repo}')
            printf '%s\n' "${GH_REMOTE_DEFAULT:-main}"
            exit 0 ;;
    esac
fi
printf 'unexpected gh invocation\n' >&2
exit 1
GHEOF
chmod +x "$tmp/ghbin/gh"
PATH="$tmp/ghbin:$PATH"; export PATH

# --- fixture git repo: main + a real-diff branch + a no-diff branch --------
repo="$tmp/repo"
mkdir -p "$repo"
(
    fixture_enter_git_init_dir "$repo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m init
    git checkout -q -b feature
    echo change >> f.txt
    git commit -q -am change
    git branch feature-empty main
) || { echo "FAIL: fixture repo setup failed" >&2; exit 1; }

main_sha="$(git -C "$repo" rev-parse main)"
feature_sha="$(git -C "$repo" rev-parse feature)"
empty_sha="$(git -C "$repo" rev-parse feature-empty)"

# Snapshot the shared system temp dir's cr-panel-avail.* files BEFORE running
# anything -- other processes on this machine (including concurrent
# workers running the real critic-panel.sh) may already have some sitting
# there, so "no leaked scratch files" must be a pre/post DIFF, not a bare
# absence check.
_pre_tmp="$(_list_panel_avail_tmp)"

# =============================================================================
# T1: missing --head -> exit 2, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && bash "$SCRIPT" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 2 ]; then ok "T1 missing --head exits 2"; else bad "T1 missing --head exit (got $rc)"; fi
assert_has "$err" "--head is required" "T1 diagnostic on stderr"
assert_no_ceilings "$err" "T1 exit 2"
if [ -f "$CALL_LOG" ]; then bad "T1 panel invoked on a usage error"; else ok "T1 panel never invoked"; fi

# T2: missing --branch -> exit 2, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && bash "$SCRIPT" --head "$feature_sha") 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 2 ]; then ok "T2 missing --branch exits 2"; else bad "T2 missing --branch exit (got $rc)"; fi
assert_has "$err" "--branch is required" "T2 diagnostic on stderr"
if [ -f "$CALL_LOG" ]; then bad "T2 panel invoked on a usage error"; else ok "T2 panel never invoked"; fi

# T3: CR_PROFILE=none -> skip, exit 0, no panel call.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && CR_PROFILE=none bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T3 CR_PROFILE=none exits 0"; else bad "T3 CR_PROFILE=none exit (got $rc)"; fi
assert_has "$out" "claude-only review (CR_PROFILE=none)" "T3 skip note on stdout"
assert_has "$out" "captured diff base: main ($main_sha)" "T3 captured-base line"
if [ -f "$CALL_LOG" ]; then bad "T3 panel invoked despite CR_PROFILE=none"; else ok "T3 panel never invoked"; fi

# T4: empty diff -> skip, exit 0, no panel call (feature-empty == main).
rm -f "$CALL_LOG" "$tmp/err"
# panel-first-pass only runs for the branch checked out in cwd.
git -C "$repo" worktree add -q "$tmp/wt-empty" feature-empty
out="$( (cd "$tmp/wt-empty" && bash "$SCRIPT" --head "$empty_sha" --branch feature-empty) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T4 empty diff exits 0"; else bad "T4 empty diff exit (got $rc)"; fi
assert_has "$out" "empty diff - critic panel skipped" "T4 skip note on stdout"
assert_has "$out" "captured diff base: main ($main_sha)" "T4 captured-base line"
if [ -f "$CALL_LOG" ]; then bad "T4 panel invoked on an empty diff"; else ok "T4 panel never invoked"; fi
# The elapsed tell is scoped to an INVOKED panel: a skip path legitimately
# returns instantly and must not be labelled as a suspicious empty round.
err="$(cat "$tmp/err")"
assert_lacks "$err" "panel-elapsed:" "T4 no elapsed tell on a skip path (panel never invoked)"

# T5: stubbed panel exit 7 -> ABORT, propagates as exit 7, no fallback.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=7 FAKE_OUT='SENTINEL-EXIT7-FINDINGS' \
    FAKE_ERR='panel-availability: codex unavailable (rc=7)' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T5 panel exit 7 propagates as exit 7"; else bad "T5 panel exit 7 (got $rc)"; fi
assert_has "$err" "critic-panel.sh exit 7" "T5 ABORT text on stderr"
assert_has "$err" "Re-run /pr-check from step 1." "T5 ABORT re-run instruction"
assert_lacks "$out" "SENTINEL-EXIT7-FINDINGS" "T5 no findings fallback on stdout"
if [ -f "$CALL_LOG" ] && [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = "1" ]; then
    ok "T5 panel called exactly once (no rtk-retry on exit 7)"
else
    bad "T5 unexpected panel call count"
fi

# T6: stubbed panel exit 1 -> fail-open, loud message, empty findings.
# T1.64: a claude-only fallback (panel rc 1, 2 or 6) writes no round-scope row.
t164_count() { grep -cF '"kind":"round-scope"' "$repo/.git/cr-critic-scores.jsonl" 2>/dev/null | tr -d ' '; }
t164_before="$(t164_count)"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=1 FAKE_OUT='PHANTOM-FINDING-MUST-NOT-SURVIVE' \
    FAKE_ERR='panel-availability: codex unavailable (rc=1)' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T6 panel exit 1 degrades to exit 0"; else bad "T6 panel exit 1 exit (got $rc)"; fi
assert_has "$err" "critic panel unavailable (all critics failed) - claude-only review" "T6 fail-open message on stderr"
assert_has "$err" "panel-availability: codex unavailable (rc=1)" "T6 availability line surfaced on stderr"
assert_lacks "$out" "PHANTOM-FINDING-MUST-NOT-SURVIVE" "T6 findings reset to empty on fail-open"
# elapsed tell: the panel WAS invoked and came back with nothing,
# which is exactly when a reader needs to see how long that took.
assert_has "$err" "panel-elapsed:" "T6 elapsed tell printed for an invoked panel with an empty findings block"
if [ -f "$CALL_LOG" ] && [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = "1" ]; then
    ok "T6 panel called exactly once (rtk excluded from PATH)"
else
    bad "T6 unexpected panel call count"
fi

# T6b: stubbed panel exit 6 (refused to certify) -> still fails
# open to claude-only, but the note says REFUSED, never "all critics failed".
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=6 FAKE_OUT='PHANTOM-FINDING-MUST-NOT-SURVIVE' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T6b panel exit 6 degrades to exit 0"; else bad "T6b panel exit 6 exit (got $rc)"; fi
assert_has "$err" "critic panel REFUSED to certify this run (exit 6" "T6b refusal note on stderr"
assert_lacks "$err" "all critics failed" "T6b exit 6 is not described as all critics failed"
assert_lacks "$out" "PHANTOM-FINDING-MUST-NOT-SURVIVE" "T6b findings reset to empty"
# T6e: panel exit 2 from a mktemp failure names it, never "all critics
# failed"; a usage-error exit 2 does not claim mktemp.
rm -rf "$repo/.git/cr-review-rounds"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=2 FAKE_ERR='critic-panel: mktemp failed' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T6e panel exit 2 degrades to exit 0"; else bad "T6e panel exit 2 exit (got $rc)"; fi
assert_has "$err" "critic panel unavailable (exit 2: critic-panel: mktemp failed - check free space in TMPDIR) - claude-only review" "T6e mktemp cause named on stderr"
assert_lacks "$err" "all critics failed" "T6e exit 2 is not described as all critics failed"
rm -rf "$repo/.git/cr-review-rounds"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=2 FAKE_ERR='usage: critic-panel.sh [--worktree <path>]' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
assert_has "$err" "critic panel unavailable (exit 2: usage error: usage: critic-panel.sh [--worktree <path>]) - claude-only review" "T6e usage cause named on stderr"
assert_lacks "$err" "mktemp" "T6e usage-error exit 2 does not claim mktemp"
if [ "$(t164_count)" = "$t164_before" ]; then ok "T1.64 panel rc 1, 6 and 2 write no round-scope row"; else bad "T1.64 a claude-only fallback wrote a round-scope row ($t164_before before, $(t164_count) after)"; fi
# Every panel run advances the branch's 3-round counter; T6b is an extra run
# the later cases were not budgeted for, so give them a fresh counter.
rm -rf "$repo/.git/cr-review-rounds"

# T6c: exit 6 whose ledger row could NOT be written leaves nothing
# for clear-review-marker.sh to hold, so the fence must ABORT (exit 7), not degrade.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=6 FAKE_ERR='critic-panel.sh: could not record certify-refused on the CR ledger' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T6c unrecorded refusal aborts at exit 7"; else bad "T6c unrecorded refusal exit (got $rc, want 7)"; fi
assert_has "$err" "could not be recorded" "T6c abort names the unrecorded refusal"
if [ "$(cat "$repo/.git/cr-review-rounds/feature.round" 2>/dev/null)" = "0" ]; then ok "T6c the unrecorded refusal gives the round back"; else bad "T6c round after the unrecorded refusal (got $(cat "$repo/.git/cr-review-rounds/feature.round" 2>/dev/null), want 0)"; fi
if [ ! -e "$repo/.git/cr-review-rounds/feature.head" ]; then ok "T6c the unrecorded refusal leaves no unreviewed .head"; else bad "T6c .head after the unrecorded refusal still names $(cat "$repo/.git/cr-review-rounds/feature.head")"; fi
rm -rf "$repo/.git/cr-review-rounds"

# T6d: an exit-6 refusal is never retried through rtk;
# a retry that returned 1 would overwrite rc and fail open past the exit-7 abort.
mkdir -p "$tmp/rtkbin"
printf '#!/usr/bin/env bash\necho "diff --git a/f.txt b/f.txt"\n' > "$tmp/rtkbin/rtk"
chmod +x "$tmp/rtkbin/rtk"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && PATH="$tmp/rtkbin:$PATH" FAKE_RC=6 FAKE_RC_RETRY=1 \
    FAKE_ERR='critic-panel.sh: could not record certify-refused on the CR ledger' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 7 ]; then ok "T6d exit 6 with rtk on PATH still aborts at exit 7"; else bad "T6d exit 6 with rtk (got $rc, want 7)"; fi
if [ "$(wc -l < "$CALL_LOG")" -eq 1 ]; then ok "T6d exit 6 is not retried"; else bad "T6d panel calls (want 1)"; fi
rm -rf "$repo/.git/cr-review-rounds"

# T7: stubbed panel exit 0 -> findings on stdout, availability on stderr,
# streams never merged; captured diff base line present.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 critical bug here' \
    FAKE_ERR='panel-availability: codex ok' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T7 panel exit 0 exits 0"; else bad "T7 panel exit 0 exit (got $rc)"; fi
assert_has "$out" "[codex-1] f.txt:1 critical bug here" "T7 findings on stdout"
assert_has "$err" "panel-availability: codex ok" "T7 availability on stderr"
assert_lacks "$out" "panel-availability: codex ok" "T7 availability NOT leaked onto stdout"
assert_lacks "$err" "[codex-1] f.txt:1 critical bug here" "T7 findings NOT leaked onto stderr"
assert_has "$out" "captured diff base: main ($main_sha)" "T7 captured-base line"
assert_lacks "$err" "panel-elapsed:" "T7 no elapsed tell when the panel returned findings"

# =============================================================================
# T8: a --head that names NO commit in this repo is an input-pin
# failure, not a critic outage. Pre-fix this exited 0 with "critic panel
# unavailable - claude-only review (git diff failed rc=128)" in under a second,
# so a caller that trusted rc=0 recorded a claude-only round and cleared the
# marker having reviewed nothing. It must ABORT at exit 7, name the ARGUMENT,
# and never invoke the panel.
BOGUS_SHA="0000000000000000000000000000000000000000"   # well-formed, resolves to nothing
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='MUST-NOT-REVIEW' \
    bash "$SCRIPT" --head "$BOGUS_SHA" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T8 unresolvable --head exits 7"; else bad "T8 unresolvable --head exit (got $rc, want 7)"; fi
assert_has "$err" "--head $BOGUS_SHA does not resolve to a commit in this repo" "T8 ABORT names the argument, not the panel"
assert_lacks "$err" "critic panel unavailable" "T8 must NOT report a critic outage for a caller error"
assert_no_ceilings "$err" "T8 a pre-round exit 7"
assert_lacks "$out" "MUST-NOT-REVIEW" "T8 no findings from a run that never reviewed"
if [ -f "$CALL_LOG" ]; then bad "T8 panel invoked on an unresolvable pin"; else ok "T8 panel never invoked"; fi

# T9: NEGATIVE CONTROL for T8. A mutant with the
# T8 guard deleted must RUN, PRODUCE a value, and produce the SPECIFIC wrong
# value the ticket reported - rc=0 plus the "critic panel unavailable" line.
# A mutant that merely "differs" (e.g. crashed on a syntax error) proves
# nothing, so each of those three properties is asserted with its own message.
# The mutant lives INSIDE the fixture tree: panel-first-pass.sh resolves
# critic-panel.sh from its own SCRIPT_DIR/../.., so a mutant written anywhere
# else would resolve HIMMEL_ROOT outside the fixture and could reach the REAL,
# paid critic panel.
mutant="$fx/scripts/cr/panel-first-pass.mutant.sh"
awk '
    index($0, "git rev-parse --verify --quiet") && index($0, "HEAD_SHA") { drop = 1 }
    drop && $0 == "fi" { drop = 0; next }
    !drop { print }
' "$SCRIPT" > "$mutant"
if cmp -s "$SCRIPT" "$mutant"; then
    bad "T9 control is VACUOUS: the guard-deleting mutation matched nothing, so the mutant is the fixed script"
else
    ok "T9 mutation applied (guard block removed)"
    if grep -q 'does not resolve to a commit in this repo' "$mutant"; then
        bad "T9 control is VACUOUS: the mutant still carries the guard's ABORT message"
    else
        ok "T9 mutant no longer carries the guard"
    fi
    rm -f "$CALL_LOG" "$tmp/err"
    out="$( (cd "$repo" && bash "$mutant" --head "$BOGUS_SHA" --branch feature) 2>"$tmp/err" )"; rc=$?
    err="$(cat "$tmp/err")"
    # (a) it RAN and produced a value: the captured-base line is printed after
    # arg parsing and before the diff, so its presence means execution reached
    # the code the guard was removed from.
    assert_has "$out" "captured diff base: main ($main_sha)" "T9 control RAN (produced the captured-base line)"
    # (b) the SPECIFIC wrong value, not merely "different from 7".
    if [ "$rc" -eq 0 ]; then ok "T9 control reproduces the exact defect (exit 0 on an unresolvable pin)"; else bad "T9 control did not reproduce the defect: exit $rc, want the pre-fix 0"; fi
    assert_has "$err" "critic panel unavailable" "T9 control reproduces the misleading outage message"
fi

# =============================================================================
# T10: a SECOND fixture with a
# bare upstream + repo2 whose LOCAL main has been rewound one commit behind
# origin/main -- exactly the "unpulled primary checkout" state that made
# panel-first-pass.sh review other people's already-merged commits as if they
# were this branch's own (cost a paid critic call + a misattributed finding
# in an earlier review). The diff base must resolve refs/remotes/origin/main,
# never the stale local ref.
up="$tmp/upstream.git"
mkdir -p "$up"
git init -q --bare "$up"
repo2="$tmp/repo2"
mkdir -p "$repo2"
(
    fixture_enter_git_init_dir "$repo2" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo A > f.txt
    git add f.txt
    git commit -q -m A
    echo B >> f.txt
    git commit -q -am B
    git remote add origin "$up"
    git push -q origin main
    git remote set-head origin -a >/dev/null 2>&1 || true
    git checkout -q -b feature
    echo C >> f.txt
    git commit -q -am C
    stale_main="$(git rev-parse main~1)"
    git update-ref refs/heads/main "$stale_main"                 # local main -> A
    git update-ref refs/remotes/origin/main "$stale_main"       # cached origin/main -> A; upstream stays at B
) || { echo "FAIL: T10 fixture setup failed" >&2; exit 1; }

r2_local_main="$(git -C "$repo2" rev-parse refs/heads/main)"
r2_stale_origin_main="$(git -C "$repo2" rev-parse refs/remotes/origin/main)"
r2_upstream_main="$(git --git-dir="$up" rev-parse refs/heads/main)"
r2_feature="$(git -C "$repo2" rev-parse feature)"

# The row proves a real fetch, not merely remote-ref preference: BOTH cached
# refs start stale, while the bare upstream already carries the newer base.
if [ "$r2_local_main" = "$r2_stale_origin_main" ] && [ "$r2_stale_origin_main" != "$r2_upstream_main" ]; then
    ok "T10 fixture starts stale: local/main and cached origin/main are $r2_local_main; upstream main is $r2_upstream_main"
else
    bad "T10 fixture is VACUOUS: expected both cached refs stale behind upstream"
fi

rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
out="$( (cd "$repo2" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$r2_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T10 exits 0"; else bad "T10 exit (got $rc)"; fi
r2_fetched_origin_main="$(git -C "$repo2" rev-parse refs/remotes/origin/main)"
assert_has "$out" "captured diff base: main ($r2_upstream_main)" "T10 fetches and captures current origin/main, not stale cached refs"
assert_lacks "$out" "main ($r2_local_main)" "T10 diff base does NOT carry stale local/cached main"
if [ "$r2_fetched_origin_main" = "$r2_upstream_main" ]; then
    ok "T10 fetch refreshed refs/remotes/origin/main"
else
    bad "T10 fetch did not refresh origin/main (got $r2_fetched_origin_main, want $r2_upstream_main)"
fi

# T12: CONTROL, capture-once. Reads $ARGS_LOG from the T10 run
# above -- checked here, BEFORE T11 below invokes the panel again and would
# append a second line to it, so "exactly one --base-sha handoff" stays a
# clean read of T10's run alone. The panel must receive the SAME base literal
# stdout printed -- never re-derive it live in a later step -- so the two
# review lanes (stdout ledger + panel argv) can never re-resolve it minutes
# apart and disagree.
if [ -f "$ARGS_LOG" ]; then
    args="$(cat "$ARGS_LOG")"
    assert_has "$args" "--base-sha $r2_upstream_main" "T12 panel received the fetched origin base sha"
    assert_lacks "$args" "--base-sha $r2_local_main" "T12 panel did NOT receive the stale local/cached base sha"
    _base_sha_count="$(grep -o -- '--base-sha' "$ARGS_LOG" | wc -l | tr -d ' ')"
    if [ "$_base_sha_count" = "1" ]; then
        ok "T12 exactly one --base-sha handoff (capture-once holds)"
    else
        bad "T12 expected exactly one --base-sha handoff, got $_base_sha_count"
    fi
else
    bad "T12 ARGS_LOG missing from the T10 run"
fi

# T11: CONTROL, no remote -> resolves the LOCAL branch. Reuses the EXISTING
# $repo fixture (it has no origin remote). T3/T4/T7 already exercise this
# line incidentally; this row names it explicitly as the documented
# fallback control (no origin/$db to prefer, so $db itself must still work).
# Runs AFTER the T12 read above so its panel invocation can't add a second
# line to $ARGS_LOG before T12 counts it.
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
assert_has "$out" "captured diff base: main ($main_sha)" "T11 no-remote control resolves the local branch"

# T13: RED CONTROL by REVERTING THE REAL FIX (never a stub), following T9's
# mutant contract exactly. The mutant lives INSIDE the fixture tree ($fx/...)
# so it can never resolve HIMMEL_ROOT outside the fixture and reach the real,
# paid critic panel.
mutant2="$fx/scripts/cr/panel-first-pass.mutant2.sh"
# shellcheck disable=SC2016  # single-quoted sed programs match literal shell syntax in $SCRIPT
sed -e 's|! cr_fetch_base "$review_root" "$db"|! true|' \
    -e 's|^base_ref=.*|base_ref="$db"|' "$SCRIPT" > "$mutant2"
if cmp -s "$SCRIPT" "$mutant2"; then
    bad "T13 control is VACUOUS: the mutation matched nothing, so the mutant is the fixed script"
else
    ok "T13 mutation applied (fetch + origin-first resolution bypassed)"
    # shellcheck disable=SC2016  # literal source needle, not shell expansion
    if grep -q 'base_ref="$(cr_resolve_base_ref' "$mutant2"; then
        bad "T13 control is VACUOUS: the mutant still calls the origin-first resolver"
    else
        ok "T13 mutant now resolves the bare local \$db"
    fi
    chmod +x "$mutant2"
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
    out="$( (cd "$repo2" && FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
        bash "$mutant2" --head "$r2_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
    if [ "$rc" -eq 0 ]; then ok "T13 control RAN to completion (exit 0)"; else bad "T13 control did not run to completion: exit $rc"; fi
    assert_has "$out" "captured diff base: main ($r2_local_main)" "T13 control reproduces the SPECIFIC wrong value (stale local main)"
    assert_lacks "$out" "main ($r2_upstream_main)" "T13 control does not carry the correct fetched origin sha"
fi

# T14: a repo whose refs/heads carries
# a branch literally named "origin/main" that SHADOWS refs/remotes/origin/main
# in git's ambiguous-ref precedence (refs/heads/<name> is checked before
# refs/remotes/<name>). cr_resolve_base_ref must return the fully-qualified
# refs/remotes/origin/main, not the short "origin/main" that a bare
# `git rev-parse` would resolve to the shadowing branch instead.
repo3="$tmp/repo3"
mkdir -p "$repo3"
(
    fixture_enter_git_init_dir "$repo3" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo A > f.txt
    git add f.txt
    git commit -q -m A
    up3="$tmp/upstream3.git"
    git init -q --bare "$up3"
    git remote add origin "$up3"
    git push -q origin main
    # Shadow branch: refs/heads/origin/main, pointing at a DIFFERENT commit
    # than the real refs/remotes/origin/main.
    echo SHADOW > shadow.txt
    git add shadow.txt
    git commit -q -m shadow
    git update-ref refs/heads/origin/main HEAD
    git checkout -q main
) || { echo "FAIL: T14 fixture setup failed" >&2; exit 1; }
r3_tracking_main="$(git -C "$repo3" rev-parse refs/remotes/origin/main)"
r3_shadow_main="$(git -C "$repo3" rev-parse refs/heads/origin/main)"
if [ "$r3_tracking_main" = "$r3_shadow_main" ]; then
    bad "T14 fixture is VACUOUS: shadow branch and tracking ref point at the same commit"
else
    ok "T14 fixture has a real shadow: refs/heads/origin/main ($r3_shadow_main) != refs/remotes/origin/main ($r3_tracking_main)"
fi
r3_resolved="$( (
    . "$HERE/base-resolver.sh"
    cr_resolve_base_ref "$repo3" main
) )"
assert_has "$r3_resolved" "refs/remotes/origin/main" "T14 cr_resolve_base_ref returns the fully-qualified tracking ref"
r3_rev="$(git -C "$repo3" rev-parse --verify --quiet "$r3_resolved^{commit}" 2>/dev/null)" || r3_rev=""
if [ "$r3_rev" = "$r3_tracking_main" ]; then
    ok "T14 resolved ref rev-parses to the tracking commit, not the shadow branch"
else
    bad "T14 resolved ref rev-parsed to $r3_rev, want the tracking commit $r3_tracking_main (got shadow $r3_shadow_main?)"
fi

# T15: the base verification refuses end to end. The stub says the
# captured base is not on the remote default branch, so review-round.sh exits 8
# at intake and the panel is never invoked; the passing rows above prove the
# same fixture reaches the panel when the stub answers "ahead".
rm -rf "$repo/.git/cr-review-rounds"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo" && GH_COMPARE_STATUS=diverged FAKE_RC=0 FAKE_OUT='MUST-NOT-REVIEW' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -ne 0 ]; then ok "T15 a base the remote does not vouch for aborts the run (rc=$rc)"; else bad "T15 diverged base was accepted"; fi
assert_has "$err" "gh compare says 'diverged'" "T15 refusal names the remote verdict"
assert_lacks "$out" "MUST-NOT-REVIEW" "T15 no findings from a refused run"
if [ -f "$CALL_LOG" ]; then bad "T15 panel invoked past a refused base"; else ok "T15 panel never invoked"; fi
rm -rf "$repo/.git/cr-review-rounds"

# T16: a fresh branch with no preflight row reaches the panel. The
# known-findings preflight runs first and records its row before the panel is
# invoked (the stub probes the ledger at call time).
ledger="$repo/.git/cr-critic-scores.jsonl"
probe="$tmp/probe-out"
rm -f "$ledger" "$probe" "$CALL_LOG" "$tmp/err"
rm -rf "$repo/.git/cr-review-rounds"
out="$( (cd "$repo" && PROBE_LEDGER="$ledger" PROBE_OUT="$probe" FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T16 clean diff runs the preflight and reaches round 1"; else bad "T16 exit (got $rc; err: $err)"; fi
assert_has "$(cat "$probe" 2>/dev/null)" "yes" "T16 preflight row on the ledger BEFORE the panel ran"
assert_has "$(cat "$ledger" 2>/dev/null)" "\"kind\":\"preflight\"" "T16 ledger holds a preflight row"
assert_has "$(cat "$ledger" 2>/dev/null)" "\"branch\":\"feature\"" "T16 preflight row stamped with the branch"
assert_has "$(cat "$ledger" 2>/dev/null)" "$feature_sha" "T16 preflight row stamped with the head"
assert_has "$out" "[codex-1] f.txt:1 finding" "T16 panel findings still reach stdout"
assert_has "$err" "preflight:" "T16 preflight summary line shown"

# T17: a branch that already has a preflight row is not re-run (no second row).
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo/.git/cr-review-rounds"
out="$( (cd "$repo" && FAKE_RC=0 bash "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T17 second run exits 0"; else bad "T17 second run exit (got $rc)"; fi
n_pre="$(grep -cF '"kind":"preflight"' "$ledger" 2>/dev/null)"
if [ "$n_pre" = 1 ]; then ok "T17 an existing preflight row is not duplicated"; else bad "T17 preflight rows after a second run (got $n_pre, want 1)"; fi

# T18: a diff that hits a known class leaves hits open: exit 3, the panel never
# runs, no preflight row is written, and the message names both commands.
git -C "$repo" worktree add -q -b feature-hit "$tmp/wt-hit" main
(
    cd "$tmp/wt-hit" || exit 1
    mkdir -p scripts
    printf '#!/usr/bin/env bash\nrm -f /tmp/zz\n' > scripts/x.sh
    git add scripts/x.sh
    git -c user.email=t@t.test -c user.name=tester -c commit.gpgsign=false commit -q -m hit
) || bad "T18 fixture commit failed"
hit_sha="$(git -C "$tmp/wt-hit" rev-parse HEAD)"
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo/.git/cr-review-rounds"
out="$( (cd "$tmp/wt-hit" && FAKE_RC=0 bash "$SCRIPT" --head "$hit_sha" --branch feature-hit) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 3 ]; then ok "T18 open preflight hits exit 3"; else bad "T18 open hits exit (got $rc; err: $err)"; fi
assert_no_ceilings "$err" "T18 exit 3"
if [ -f "$CALL_LOG" ]; then bad "T18 panel invoked past open preflight hits"; else ok "T18 panel never invoked"; fi
assert_has "$err" "known-findings.sh" "T18 message names known-findings.sh"
assert_has "$err" "ledger-append.sh" "T18 message names ledger-append.sh preflight"
hit_rows="$(grep -F '"kind":"preflight"' "$ledger" | grep -F '"branch":"feature-hit"')"
if [ -n "$hit_rows" ]; then bad "T18 a preflight row was written for a branch with open hits"; else ok "T18 no preflight row for open hits"; fi
if compgen -G "$repo/.git/cr-review-rounds/*" >/dev/null; then bad "T18 a review round was started"; else ok "T18 no review round started"; fi
git -C "$repo" worktree remove --force "$tmp/wt-hit" 2>/dev/null
rm -rf "$repo/.git/cr-review-rounds"

# T19: a known-findings.sh that cannot run (corrupt catalog) is not a clean
# pass: exit 9, no preflight row, the panel never invoked, no review round.
kf_json="$fx/scripts/cr/known-findings.json"
cp "$kf_json" "$tmp/known-findings.json.orig"
printf '{ not json' > "$kf_json"
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo/.git/cr-review-rounds"
git -C "$repo" worktree add -q -b feature-kfcrash "$tmp/wt-kfcrash" main
(
    cd "$tmp/wt-kfcrash" || exit 1
    printf 'clean\n' > kfcrash.txt
    git add kfcrash.txt
    git -c user.email=t@t.test -c user.name=tester -c commit.gpgsign=false commit -q -m clean
) || bad "T19 fixture commit failed"
kfc_sha="$(git -C "$tmp/wt-kfcrash" rev-parse HEAD)"
out="$( (cd "$tmp/wt-kfcrash" && FAKE_RC=0 bash "$SCRIPT" --head "$kfc_sha" --branch feature-kfcrash) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
cp "$tmp/known-findings.json.orig" "$kf_json"
git -C "$repo" worktree remove --force "$tmp/wt-kfcrash" 2>/dev/null
if [ "$rc" -eq 9 ]; then ok "T19 a crashed known-findings.sh exits 9"; else bad "T19 crashed preflight exit (got $rc; err: $err)"; fi
assert_no_ceilings "$err" "T19 exit 9"
if [ -f "$CALL_LOG" ]; then bad "T19 panel invoked past a crashed preflight"; else ok "T19 panel never invoked"; fi
crash_rows="$(grep -F '"kind":"preflight"' "$ledger" | grep -F '"branch":"feature-kfcrash"')"
if [ -n "$crash_rows" ]; then bad "T19 a preflight row was written for a crashed preflight"; else ok "T19 no preflight row for a crashed preflight"; fi
if compgen -G "$repo/.git/cr-review-rounds/*" >/dev/null; then bad "T19 a review round was started"; else ok "T19 no review round started"; fi
assert_has "$err" "known-findings.sh" "T19 message names known-findings.sh"
rm -rf "$repo/.git/cr-review-rounds"

# T20: a ledger-append.sh that refuses to record the pass is not a clean pass
# either: the same four properties.
la="$fx/scripts/cr/ledger-append.sh"
cp "$la" "$tmp/ledger-append.sh.orig"
printf '#!/usr/bin/env bash\necho "ledger-append: refused" >&2\nexit 1\n' > "$la"
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo/.git/cr-review-rounds"
git -C "$repo" worktree add -q -b feature-lafail "$tmp/wt-lafail" main
(
    cd "$tmp/wt-lafail" || exit 1
    printf 'clean\n' > lafail.txt
    git add lafail.txt
    git -c user.email=t@t.test -c user.name=tester -c commit.gpgsign=false commit -q -m clean
) || bad "T20 fixture commit failed"
laf_sha="$(git -C "$tmp/wt-lafail" rev-parse HEAD)"
out="$( (cd "$tmp/wt-lafail" && FAKE_RC=0 bash "$SCRIPT" --head "$laf_sha" --branch feature-lafail) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
cp "$tmp/ledger-append.sh.orig" "$la"
git -C "$repo" worktree remove --force "$tmp/wt-lafail" 2>/dev/null
if [ "$rc" -eq 9 ]; then ok "T20 a refused ledger-append exits 9"; else bad "T20 unrecorded preflight exit (got $rc; err: $err)"; fi
if [ -f "$CALL_LOG" ]; then bad "T20 panel invoked past an unrecorded preflight"; else ok "T20 panel never invoked"; fi
la_rows="$(grep -F '"kind":"preflight"' "$ledger" | grep -F '"branch":"feature-lafail"')"
if [ -n "$la_rows" ]; then bad "T20 a preflight row exists for an unrecorded preflight"; else ok "T20 no preflight row"; fi
if compgen -G "$repo/.git/cr-review-rounds/*" >/dev/null; then bad "T20 a review round was started"; else ok "T20 no review round started"; fi
assert_has "$err" "ledger-append.sh" "T20 message names ledger-append.sh"
rm -rf "$repo/.git/cr-review-rounds"

# T21: an ambient CR_LEDGER cannot split the preflight lookup from its write:
# the row lands on the git-common ledger the marker gate reads.
amb="$tmp/ambient-ledger.jsonl"
kf_sh="$fx/scripts/cr/known-findings.sh"
cp "$kf_sh" "$tmp/known-findings.sh.orig"
# shellcheck disable=SC2016 # the stub body expands in the stub, not here
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${CR_LEDGER:-unset}" > "%s"\nexit 0\n' "$tmp/kf-ledger-seen" > "$kf_sh"
rm -f "$amb" "$CALL_LOG" "$tmp/err" "$tmp/kf-ledger-seen"
git -C "$repo" worktree add -q -b feature-ambient "$tmp/wt-ambient" main
(
    cd "$tmp/wt-ambient" || exit 1
    printf 'clean\n' > ambient.txt
    git add ambient.txt
    git -c user.email=t@t.test -c user.name=tester -c commit.gpgsign=false commit -q -m clean
) || bad "T21 fixture commit failed"
amb_sha="$(git -C "$tmp/wt-ambient" rev-parse HEAD)"
out="$( (cd "$tmp/wt-ambient" && CR_LEDGER="$amb" FAKE_RC=0 bash "$SCRIPT" --head "$amb_sha" --branch feature-ambient) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
cp "$tmp/known-findings.sh.orig" "$kf_sh"
git -C "$repo" worktree remove --force "$tmp/wt-ambient" 2>/dev/null
kf_seen="$(cat "$tmp/kf-ledger-seen" 2>/dev/null)"
if [ "$kf_seen" = "$ledger" ]; then ok "T21 known-findings.sh reads the git-common ledger"; else bad "T21 known-findings.sh saw CR_LEDGER=$kf_seen (want $ledger)"; fi
if [ "$rc" -eq 0 ]; then ok "T21 run with an ambient CR_LEDGER exits 0"; else bad "T21 exit (got $rc; err: $err)"; fi
amb_rows="$(grep -F '"kind":"preflight"' "$ledger" | grep -F '"branch":"feature-ambient"')"
if [ -n "$amb_rows" ]; then ok "T21 preflight row recorded on the git-common ledger"; else bad "T21 no preflight row on the git-common ledger"; fi
if [ -e "$amb" ]; then bad "T21 the ambient CR_LEDGER file was written"; else ok "T21 the ambient CR_LEDGER file is untouched"; fi
rm -rf "$repo/.git/cr-review-rounds"

# T22-T24: the claudex lane cannot fetch (no network, and the sandbox cannot
# write the shared ref store), so a first pass that always fetched aborted exit 7
# and no fresh review round could run once the branch fell behind main. repo4
# has an origin that no longer answers and a cached origin/main.
up4="$tmp/upstream4.git"
git init -q --bare "$up4"
repo4="$tmp/repo4"
mkdir -p "$repo4"
(
    fixture_enter_git_init_dir "$repo4" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo A > f.txt
    git add f.txt
    git commit -q -m A
    git remote add origin "$up4"
    git push -q origin main
    git checkout -q -b feature
    echo C >> f.txt
    git commit -q -am C
    git remote set-url origin "$tmp/no-such-remote.git"
) || { echo "FAIL: T22 fixture setup failed" >&2; exit 1; }
r4_cached_origin_main="$(git -C "$repo4" rev-parse refs/remotes/origin/main)"
r4_feature="$(git -C "$repo4" rev-parse feature)"

# T22: with the fetch refused, the claudex first pass completes against the
# local origin base ref, says so, and leaves the cached ref alone.
rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
rm -rf "$repo4/.git/cr-review-rounds"
out="$( (cd "$repo4" && HIMMEL_SESSION_LANE=claudex FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$r4_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ]; then ok "T22 claudex first pass completes without a fetch"; else bad "T22 claudex first pass exit (got $rc; err: $err)"; fi
assert_has "$out" "captured diff base: main ($r4_cached_origin_main)" "T22 base is the local origin ref"
assert_has "$err" "claudex lane cannot fetch" "T22 says the fetch was skipped"
if [ -f "$CALL_LOG" ]; then ok "T22 panel ran"; else bad "T22 panel never ran"; fi
assert_has "$(git -C "$repo4" rev-parse refs/remotes/origin/main)" "$r4_cached_origin_main" "T22 cached origin ref untouched"

# T23: CONTROL. The same fixture on the native lane still insists on the fetch.
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo4/.git/cr-review-rounds"
out="$( (cd "$repo4" && FAKE_RC=0 FAKE_OUT='MUST-NOT-REVIEW' \
    bash "$SCRIPT" --head "$r4_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 7 ]; then ok "T23 native lane with a dead origin aborts exit 7"; else bad "T23 native lane exit (got $rc, want 7)"; fi
assert_has "$err" "could not fetch origin/main" "T23 names the failed fetch"
assert_lacks "$out" "MUST-NOT-REVIEW" "T23 no findings from a run that never reviewed"
if [ -f "$CALL_LOG" ]; then bad "T23 panel invoked past a failed fetch"; else ok "T23 panel never invoked"; fi

# T24: CONTROL. A claudex lane with no local origin base ref has nothing to
# pin: it aborts exit 7 instead of certifying a local branch.
git -C "$repo4" update-ref -d refs/remotes/origin/main
rm -f "$CALL_LOG" "$tmp/err"
rm -rf "$repo4/.git/cr-review-rounds"
out="$( (cd "$repo4" && HIMMEL_SESSION_LANE=claudex FAKE_RC=0 FAKE_OUT='MUST-NOT-REVIEW' \
    bash "$SCRIPT" --head "$r4_feature" --branch feature) 2>"$tmp/err" )"; rc=$?
err="$(cat "$tmp/err")"
git -C "$repo4" update-ref refs/remotes/origin/main "$r4_cached_origin_main"
if [ "$rc" -eq 7 ]; then ok "T24 claudex lane with no origin base ref aborts exit 7"; else bad "T24 claudex no-ref exit (got $rc, want 7)"; fi
assert_has "$err" "no local refs/remotes/origin/main" "T24 names the missing ref"
assert_lacks "$out" "MUST-NOT-REVIEW" "T24 no findings from a run that never reviewed"
if [ -f "$CALL_LOG" ]; then bad "T24 panel invoked without a base ref"; else ok "T24 panel never invoked"; fi
rm -rf "$repo4/.git/cr-review-rounds"

# T25: --context-file reaches the panel; an unreadable one exits 2
# before the panel runs.
printf '{"range":["f.txt",1,1]}\n\nA\n' > "$tmp/ctx.txt"
rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/err"
out="$( (cd "$repo4" && HIMMEL_SESSION_LANE=claudex FAKE_RC=0 FAKE_OUT='[codex-1] f.txt:1 finding' \
    bash "$SCRIPT" --head "$r4_feature" --branch feature --context-file "$tmp/ctx.txt") 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 0 ]; then ok "T25 a context file run exits 0"; else bad "T25 exit (got $rc; err: $(cat "$tmp/err"))"; fi
assert_has "$(cat "$ARGS_LOG" 2>/dev/null)" "--context-file $tmp/ctx.txt" "T25 the panel receives the context file"
rm -rf "$repo4/.git/cr-review-rounds"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo4" && HIMMEL_SESSION_LANE=claudex FAKE_RC=0 \
    bash "$SCRIPT" --head "$r4_feature" --branch feature --context-file "$tmp/no-such-ctx") 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T25 an unreadable context file exits 2"; else bad "T25 unreadable exit (got $rc, want 2)"; fi
if [ -f "$CALL_LOG" ]; then bad "T25 panel invoked with an unreadable context file"; else ok "T25 panel never invoked"; fi
rm -rf "$repo4/.git/cr-review-rounds"
# A directory is readable but not a file: it exits 2 before a round is spent.
mkdir -p "$tmp/ctx-dir"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$repo4" && HIMMEL_SESSION_LANE=claudex FAKE_RC=0 \
    bash "$SCRIPT" --head "$r4_feature" --branch feature --context-file "$tmp/ctx-dir") 2>"$tmp/err" )"; rc=$?
if [ "$rc" -eq 2 ]; then ok "T25 a directory context file exits 2"; else bad "T25 directory exit (got $rc, want 2)"; fi
if [ -f "$CALL_LOG" ]; then bad "T25 panel invoked with a directory context file"; else ok "T25 panel never invoked for a directory"; fi
if [ -e "$repo4/.git/cr-review-rounds/feature.round" ]; then bad "T25 a directory context file spent a round"; else ok "T25 a directory context file spends no round"; fi
rm -rf "$repo4/.git/cr-review-rounds"

# T26: rounds 2 and 3 review only what changed since the last round
# with the whole PR as context; any doubt about the start point
# reviews the full diff, as before. r5_new makes main + feature (H1 = one
# change to f.txt); r5_round runs one first pass and keeps what the panel got.
r5_new() {
    mkdir -p "$1"
    (
        fixture_enter_git_init_dir "$1" || exit 1
        git -c init.defaultBranch=main init -q
        git config user.email t@t.test
        git config user.name tester
        git config commit.gpgsign false
        echo base > f.txt
        git add f.txt
        git commit -q -m init
        git checkout -q -b feature
        echo change >> f.txt
        git commit -q -am change
    ) || { echo "FAIL: T26 fixture repo setup failed" >&2; exit 1; }
}
r5_commit() { ( cd "$1" && echo "$3" >> "$2" && git add "$2" && git commit -q -m "edit $2" && git rev-parse HEAD ); }
r5_avail() { ( cd "$1" && CR_LEDGER="$1/.git/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" avail --branch feature --head "$2" --model codex --status ok >/dev/null ); }
r5_from() { ( cd "$1" && bash "$fx/scripts/cr/review-round.sh" from --branch feature ); }
r5_round() {
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/stdin-log" "$tmp/ctx-copy" "$tmp/err"
    r5_out="$( (cd "$1" && STDIN_LOG="$tmp/stdin-log" CTX_COPY="$tmp/ctx-copy" FAKE_RC=0 FAKE_OUT="${R5_FAKE_OUT:-}" \
        bash "$SCRIPT" --head "$2" --branch feature "${@:3}") 2>"$tmp/err" )"; r5_rc=$?
    r5_err="$(cat "$tmp/err")"
    r5_stdin="$(cat "$tmp/stdin-log" 2>/dev/null)"
    r5_args="$(cat "$ARGS_LOG" 2>/dev/null)"
    r5_ctx="$(cat "$tmp/ctx-copy" 2>/dev/null)"
}

# A: the first round reviews the whole branch; the second reviews H1..H2 with the PR as context.
r5a="$tmp/repo5a"; r5_new "$r5a"
r5a_h1="$(git -C "$r5a" rev-parse HEAD)"
r5_round "$r5a" "$r5a_h1"
if [ "$r5_rc" -eq 0 ]; then ok "T26 round 1 exits 0"; else bad "T26 round 1 exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_out" "round 1 of 3" "T26 round 1 is round 1"
assert_has "$r5_stdin" "+change" "T26 round 1 reviews the full branch diff"
assert_lacks "$r5_args" "--context-file /" "T26 round 1 passes no context file"
r5_avail "$r5a" "$r5a_h1"
r5a_h2="$(r5_commit "$r5a" g.txt second)"
r5_round "$r5a" "$r5a_h2"
if [ "$r5_rc" -eq 0 ]; then ok "T26 round 2 exits 0"; else bad "T26 round 2 exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_out" "round 2 of 3" "T26 round 2 is round 2"
if [ "$(r5_from "$r5a")" = "$r5a_h1" ]; then ok "T26 round 2 'from' prints the last reviewed head"; else bad "T26 round 2 'from' (got '$(r5_from "$r5a")', want $r5a_h1)"; fi
assert_has "$r5_stdin" "+second" "T26 round 2 reviews the change since the last round"
assert_lacks "$r5_stdin" "+change" "T26 round 2 does not re-review the earlier round's diff"
assert_has "$r5_args" "--context-file /" "T26 round 2 passes the whole PR as context"
assert_has "$r5_ctx" '{"range":["f.txt",2,2]}' "T26 context ranges cover the earlier round's hunk"
assert_has "$r5_ctx" '{"range":["g.txt",1,1]}' "T26 context ranges cover the delta's hunk"
assert_has "$r5_ctx" "+change" "T26 context text holds the whole PR"
assert_has "$r5_err" "round 2 reviews" "T26 round 2 says which range it reviewed"

# B: no reviewed head before the second round (no avail row at H1): nothing to start from.
r5b="$tmp/repo5b"; r5_new "$r5b"
r5b_h1="$(git -C "$r5b" rev-parse HEAD)"
r5_round "$r5b" "$r5b_h1"
r5b_h2="$(r5_commit "$r5b" g.txt second)"
r5_round "$r5b" "$r5b_h2"
assert_has "$r5_out" "round 2 of 3" "T26 fallback B: round 2 ran"
assert_has "$r5_stdin" "+change" "T26 fallback B: an empty start point reviews the full diff"
assert_lacks "$r5_args" "--context-file /" "T26 fallback B: no context file with the full diff"

# C: the start point equals HEAD (an empty delta is never reviewed as clean).
r5c="$tmp/repo5c"; r5_new "$r5c"
r5c_h1="$(git -C "$r5c" rev-parse HEAD)"
r5_round "$r5c" "$r5c_h1"
r5_avail "$r5c" "$r5c_h1"
r5c_h2="$(r5_commit "$r5c" g.txt second)"
r5_round "$r5c" "$r5c_h2"
printf '%s\n' "$r5c_h2" > "$r5c/.git/cr-review-rounds/feature.from"
r5_round "$r5c" "$r5c_h2"
assert_has "$r5_out" "round 2 of 3" "T26 fallback C: round 2 re-entered"
assert_has "$r5_stdin" "+change" "T26 fallback C: a start point equal to HEAD reviews the full diff"
assert_lacks "$r5_args" "--context-file /" "T26 fallback C: no context file with the full diff"

# D: HEAD does not descend from the start point.
r5d="$tmp/repo5d"; r5_new "$r5d"
r5d_h1="$(git -C "$r5d" rev-parse HEAD)"
r5_round "$r5d" "$r5d_h1"
r5_avail "$r5d" "$r5d_h1"
r5d_h2="$(r5_commit "$r5d" g.txt second)"
r5_round "$r5d" "$r5d_h2"
r5d_side="$(cd "$r5d" && git checkout -q -b side main && echo side > s.txt && git add s.txt && git commit -q -m side && git rev-parse HEAD && git checkout -q feature)"
printf '%s\n' "$r5d_side" > "$r5d/.git/cr-review-rounds/feature.from"
r5_round "$r5d" "$r5d_h2"
assert_has "$r5_stdin" "+change" "T26 fallback D: a start point HEAD does not descend from reviews the full diff"
assert_lacks "$r5_args" "--context-file /" "T26 fallback D: no context file with the full diff"

# E: a merge of the default branch sits in the range.
r5e="$tmp/repo5e"; r5_new "$r5e"
r5e_h1="$(git -C "$r5e" rev-parse HEAD)"
r5_round "$r5e" "$r5e_h1"
r5_avail "$r5e" "$r5e_h1"
r5e_h2="$(r5_commit "$r5e" g.txt second)"
r5_round "$r5e" "$r5e_h2"
r5_avail "$r5e" "$r5e_h2"
(cd "$r5e" && git checkout -q main && echo upstream > u.txt && git add u.txt && git commit -q -m upstream && git checkout -q feature && git merge -q --no-edit main) \
    || { echo "FAIL: T26 merge fixture failed" >&2; exit 1; }
r5e_h3="$(git -C "$r5e" rev-parse HEAD)"
r5_round "$r5e" "$r5e_h3"
assert_has "$r5_out" "round 3 of 3" "T26 fallback E: round 3 ran"
assert_has "$r5_stdin" "+change" "T26 fallback E: a merge of the default branch in range reviews the full diff"
assert_lacks "$r5_args" "--context-file /" "T26 fallback E: no context file with the full diff"

# T27: rounds 2 and 3 tag an Important finding on code older than the PR and
# set the ledger field `review-round.sh defer` reads; the first round tags nothing.
r6="$tmp/repo5g"; r5_new "$r6"
r6_h1="$(git -C "$r6" rev-parse HEAD)"
R5_FAKE_OUT='## Important Issues (1 found)
- [codex-1]: the old line is wrong [f.txt:1]'
r5_round "$r6" "$r6_h1"
assert_has "$r5_out" "- [codex-1]: the old line is wrong [f.txt:1]" "T27 round 1 leaves the finding untagged"
assert_lacks "$r5_out" "[pre-existing]" "T27 round 1 tags nothing"
r5_avail "$r6" "$r6_h1"
r6_h2="$(r5_commit "$r6" g.txt second)"
# The panel writes its own finding rows before the tagger runs; stand in for it.
( cd "$r6" && CR_LEDGER="$r6/.git/cr-critic-scores.jsonl" bash "$fx/scripts/cr/ledger-append.sh" finding \
    --branch feature --head "$r6_h2" --model codex --id codex-1 --severity imp --file f.txt --line 1 --verdict "" >/dev/null 2>&1 ) \
    || bad "T27 fixture finding row"
r5_round "$r6" "$r6_h2"
assert_has "$r5_out" "- [codex-1]: the old line is wrong [pre-existing] [f.txt:1]" "T27 round 2 tags an Important on code older than the PR"
assert_has "$(cat "$r6/.git/cr-critic-scores.jsonl")" '"pre_existing":true' "T27 round 2 sets the pre_existing ledger field"
R5_FAKE_OUT=""

# T1.30-T1.38: one round-scope row per run whose panel ran, its scope read from
# the final diff range; --full skips the since-last-round scoping and refuses past the cap.
rs_rows() { grep -F '"kind":"round-scope"' "$1/.git/cr-critic-scores.jsonl" 2>/dev/null; }
rs_last() { rs_rows "$1" | tail -n 1; }
rs_count() { rs_rows "$1" | grep -c . | tr -d ' '; }

# T1.30: the first run writes full.
rs1="$tmp/repo-rs1"; r5_new "$rs1"
rs1_main="$(git -C "$rs1" rev-parse main)"; rs1_h1="$(git -C "$rs1" rev-parse HEAD)"
r5_round "$rs1" "$rs1_h1"
row="$(rs_last "$rs1")"
assert_has "$row" '"scope":"full"' "T1.30 round 1 writes a full row"
assert_has "$row" "\"head\":\"$rs1_h1\"" "T1.30 the row carries the head"
assert_has "$row" "\"base_sha\":\"$rs1_main\"" "T1.30 the row carries the captured base"
assert_has "$row" '"from":null' "T1.30 a full row has no from"
assert_has "$row" '"round":1' "T1.30 the row carries round 1"
assert_has "$row" '"source":"panel-first-pass"' "T1.30 the row names its source"
assert_has "$row" '"pr":null' "T1.30 the checkout route has no pr"
assert_has "$row" '"branch":"feature"' "T1.30 the row carries the branch"
if [ "$(rs_count "$rs1")" = 1 ]; then ok "T1.30 exactly one row"; else bad "T1.30 row count (got $(rs_count "$rs1"))"; fi

# T1.31: a round-2 scoped run writes delta with from.
r5_avail "$rs1" "$rs1_h1"
rs1_h2="$(r5_commit "$rs1" g.txt second)"
r5_round "$rs1" "$rs1_h2"
row="$(rs_last "$rs1")"
assert_has "$r5_err" "round 2 reviews $rs1_h1..$rs1_h2" "T1.31 round 2 is scoped"
assert_has "$row" '"scope":"delta"' "T1.31 a scoped round 2 writes delta"
assert_has "$row" "\"from\":\"$rs1_h1\"" "T1.31 from is the range's left side"
assert_has "$row" '"round":2' "T1.31 the row carries round 2"

# T1.33: the doubt fallbacks write full (B: empty from, C: from = HEAD, D: non-ancestor from).
assert_has "$(rs_last "$r5b")" '"scope":"full"' "T1.33 an empty start point writes full"
assert_has "$(rs_last "$r5c")" '"scope":"full"' "T1.33 a start point equal to HEAD writes full"
assert_has "$(rs_last "$r5d")" '"scope":"full"' "T1.33 a non-ancestor start point writes full"
assert_has "$(rs_last "$r5d")" '"round":2' "T1.33 the fallback row keeps its round"

# T1.34: --full on the second run writes full and reviews the whole branch.
rs2="$tmp/repo-rs2"; r5_new "$rs2"
rs2_h1="$(git -C "$rs2" rev-parse HEAD)"
r5_round "$rs2" "$rs2_h1" --full
r5_avail "$rs2" "$rs2_h1"
rs2_h2="$(r5_commit "$rs2" g.txt second)"
r5_round "$rs2" "$rs2_h2" --full
row="$(rs_last "$rs2")"
if [ "$r5_rc" -eq 0 ]; then ok "T1.34 --full round 2 exits 0"; else bad "T1.34 exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_out" "round 2 of 3" "T1.34 --full still counts round 2"
assert_has "$r5_stdin" "+change" "T1.34 --full round 2 reviews the whole branch"
assert_lacks "$r5_err" "round 2 reviews" "T1.34 --full skips the since-last-round scoping"
assert_has "$row" '"scope":"full"' "T1.34 --full round 2 writes full"
assert_has "$row" '"round":2' "T1.34 the row carries round 2"

# T1.32 / T1.35: a fixture tree whose review-round.sh hands back the post-cap
# delta round (or the cap refusal) the real one returns after three full rounds.
fx2="$tmp/fx2"; cp -R "$fx" "$fx2"
cat > "$fx2/scripts/cr/review-round.sh" <<'RREOF'
#!/usr/bin/env bash
case "${1:-}" in
    start)
        if [ -n "${RR_START_RC:-}" ]; then echo "review-round: cap reached" >&2; exit "$RR_START_RC"; fi
        printf '4 delta %s\n' "$RR_FROM" ;;
    abort) printf 'given back\n'; printf 'abort\n' >> "$RR_LOG" ;;
    from) printf '%s\n' "$RR_FROM" ;;
esac
exit 0
RREOF
SCRIPT2="$fx2/scripts/cr/panel-first-pass.sh"
RR_LOG="$tmp/rr.log"; export RR_LOG
rs3="$tmp/repo-rs3"; r5_new "$rs3"
rs3_h1="$(git -C "$rs3" rev-parse HEAD)"
rs3_h2="$(r5_commit "$rs3" g.txt second)"
rs3_run() {
    rm -f "$CALL_LOG" "$RR_LOG" "$tmp/err"
    r5_out="$( (cd "$rs3" && RR_FROM="$rs3_h1" FAKE_RC=0 bash "$SCRIPT2" --head "$rs3_h2" --branch feature "$@") 2>"$tmp/err" )"; r5_rc=$?
    r5_err="$(cat "$tmp/err")"
}
# T1.32: the post-cap "<n> delta <from>" round writes delta.
rs3_run
row="$(rs_last "$rs3")"
assert_has "$r5_out" "delta round 4" "T1.32 the post-cap delta round ran"
assert_has "$row" '"scope":"delta"' "T1.32 the post-cap delta round writes delta"
assert_has "$row" "\"from\":\"$rs3_h1\"" "T1.32 from is the delta start"
assert_has "$row" '"round":4' "T1.32 the row carries the post-cap round"
# T1.35: --full past the cap refuses with the takeover line.
n_before="$(rs_count "$rs3")"
rs3_run --full
if [ "$r5_rc" -eq 8 ]; then ok "T1.35 --full on the post-cap delta round exits 8"; else bad "T1.35 delta exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_err" "outside PR past its three full rounds: hand it to a maintainer takeover (HIMMEL-9019)" "T1.35 the takeover line on the delta round"
assert_no_ceilings "$r5_err" "T1.35 the FULL-delta takeover exit 8"
if [ -f "$CALL_LOG" ]; then bad "T1.35 panel invoked past the cap"; else ok "T1.35 panel never invoked on the delta round"; fi
assert_has "$(cat "$RR_LOG" 2>/dev/null)" "abort" "T1.35 the refused delta round is given back"
rm -f "$CALL_LOG" "$tmp/err"
r5_out="$( (cd "$rs3" && RR_START_RC=8 RR_FROM="$rs3_h1" FAKE_RC=0 bash "$SCRIPT2" --head "$rs3_h2" --branch feature --full) 2>"$tmp/err" )"; r5_rc=$?
r5_err="$(cat "$tmp/err")"
if [ "$r5_rc" -eq 8 ]; then ok "T1.35 --full on a cap refusal exits 8"; else bad "T1.35 cap exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_err" "outside PR past its three full rounds: hand it to a maintainer takeover (HIMMEL-9019)" "T1.35 the takeover line on a cap refusal"
assert_no_ceilings "$r5_err" "T1.35 the cap refusal exit 8"
rs3_run_bad() {
    rm -f "$CALL_LOG" "$RR_LOG" "$tmp/err"
    r5_out="$( (cd "$rs3" && RR_FROM=0000000000000000000000000000000000000000 FAKE_RC=0 bash "$SCRIPT2" --head "$rs3_h2" --branch feature) 2>"$tmp/err" )"; r5_rc=$?
    r5_err="$(cat "$tmp/err")"
}
rs3_run_bad
if [ "$r5_rc" -eq 5 ]; then ok "an unreadable delta diff exits 5"; else bad "unreadable delta exit (got $r5_rc; err: $r5_err)"; fi
assert_has "$r5_err" "could not read the delta diff" "the unreadable delta names itself"
assert_no_ceilings "$r5_err" "an unreadable delta exit 5"
if [ "$(rs_count "$rs3")" = "$n_before" ]; then ok "T1.35 a refused --full run writes no row"; else bad "T1.35 row count moved ($n_before to $(rs_count "$rs3"))"; fi

# T1.36: the rtk retry writes one row.
mkdir -p "$tmp/rtkbin"
cat > "$tmp/rtkbin/rtk" <<'RTKEOF'
#!/usr/bin/env bash
[ "$1" = proxy ] && shift
exec "$@"
RTKEOF
chmod +x "$tmp/rtkbin/rtk"
rs4="$tmp/repo-rs4"; r5_new "$rs4"
rs4_h1="$(git -C "$rs4" rev-parse HEAD)"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$rs4" && PATH="$tmp/rtkbin:$PATH" FAKE_RC=1 FAKE_RC_RETRY=0 bash "$SCRIPT" --head "$rs4_h1" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$(wc -l < "$CALL_LOG" | tr -d ' ')" = 2 ]; then ok "T1.36 the panel was retried through rtk"; else bad "T1.36 panel calls (got $(wc -l < "$CALL_LOG"))"; fi
if [ "$(rs_count "$rs4")" = 1 ]; then ok "T1.36 the rtk retry writes one row"; else bad "T1.36 row count (got $(rs_count "$rs4"); err: $(cat "$tmp/err"))"; fi

# T1.37: one critic ok and one failed writes the row; all critics failed (a claude-only fallback) writes none.
rs5="$tmp/repo-rs5"; r5_new "$rs5"
rs5_h1="$(git -C "$rs5" rev-parse HEAD)"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$rs5" && FAKE_RC=0 FAKE_ERR='panel-availability: codex ok
panel-availability: gemini unavailable (rc=1)' bash "$SCRIPT" --head "$rs5_h1" --branch feature) 2>"$tmp/err" )"; rc=$?
if [ "$(rs_count "$rs5")" = 1 ]; then ok "T1.37 one ok and one failed critic writes the row"; else bad "T1.37 mixed row count (got $(rs_count "$rs5"))"; fi
rs6="$tmp/repo-rs6"; r5_new "$rs6"
rs6_h1="$(git -C "$rs6" rev-parse HEAD)"
rm -f "$CALL_LOG" "$tmp/err"
out="$( (cd "$rs6" && FAKE_RC=1 FAKE_ERR='panel-availability: codex unavailable (rc=1)' bash "$SCRIPT" --head "$rs6_h1" --branch feature) 2>"$tmp/err" )"; rc=$?
assert_has "$(cat "$tmp/err")" "all critics failed" "T1.37 the all-failed run degraded"
if [ "$(rs_count "$rs6")" = 0 ]; then ok "T1.37 all critics failed writes no row"; else bad "T1.37 all-failed row count (got $(rs_count "$rs6"))"; fi

# T1.38: a run whose panel did not run writes nothing.
rs7="$tmp/repo-rs7"; r5_new "$rs7"
rs7_h1="$(git -C "$rs7" rev-parse HEAD)"
out="$( (cd "$rs7" && CR_PROFILE=none bash "$SCRIPT" --head "$rs7_h1" --branch feature --full) 2>/dev/null )"
if [ "$(rs_count "$rs7")" = 0 ]; then ok "T1.38 CR_PROFILE=none writes no row"; else bad "T1.38 CR_PROFILE=none wrote a row"; fi
out="$( (cd "$tmp/wt-empty" && bash "$SCRIPT" --head "$empty_sha" --branch feature-empty --full) 2>/dev/null )"
rs_empty="$(rs_rows "$repo" | grep -F '"branch":"feature-empty"')"
if [ -n "$rs_empty" ]; then bad "T1.38 an empty diff wrote a row"; else ok "T1.38 an empty diff writes no row"; fi
out="$( (cd "$rs7" && bash "$SCRIPT" --head 0000000000000000000000000000000000000000 --branch feature --full) 2>/dev/null )"
if [ "$(rs_count "$rs7")" = 0 ]; then ok "T1.38 an early refusal writes no row"; else bad "T1.38 an early refusal wrote a row"; fi

# --- --pr <n>: an outside PR reviewed from its fetched ref, its branch never checked out ---------------
# The fixture repo sits on another branch; refs/himmel/outside/7 holds the PR commit, whose tree plants
# a canary that would fire if anything ran a file from it. The gh stub serves the PR, the allowlist
# lives in a temp HOME.
cp "$HERE/../lib/outside-contributors.sh" "$HERE/../lib/timeout-bin.sh" "$fx/scripts/lib/"
pr_home="$tmp/pr-home"; mkdir -p "$pr_home/.himmel"
printf '[{"login":"Goomal","id":"U_goomal"}]\n' > "$pr_home/.himmel/outside-contributors.json"
pr_canary="$tmp/pr-canary"
mkdir -p "$tmp/prbin"
cat > "$tmp/prbin/gh" <<'GHEOF'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
    _json="$(printf '{"author":{"login":"%s","id":"%s"},"headRefName":"%s","headRefOid":"%s","baseRefName":"%s","state":"OPEN"}' \
        "${PR_LOGIN:-Goomal}" "${PR_ID:-U_goomal}" "${PR_BRANCH:-feat/outside-thing}" "$PR_OID" "${PR_BASE-main}")"
    _q=""
    for _a in "$@"; do [ "$_prev" = "--jq" ] && _q="$_a"; _prev="$_a"; done
    if [ -n "$_q" ]; then printf '%s' "$_json" | jq -r "$_q"; else printf '%s\n' "$_json"; fi
    exit 0
fi
exec "$GH_FALLBACK" "$@"
GHEOF
chmod +x "$tmp/prbin/gh"
pr_origin="$tmp/pr-origin.git"; prrepo="$tmp/prrepo"
git init -q --bare -b main "$pr_origin"
mkdir -p "$prrepo"
(
    fixture_enter_git_init_dir "$prrepo" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@t.test
    git config user.name tester
    git config commit.gpgsign false
    echo base > f.txt
    git add f.txt
    git commit -q -m base
    git remote add origin "$pr_origin"
    git push -q origin main
    git checkout -q -b prside
    echo change >> f.txt
    printf 'touch "%s"\n' "$pr_canary" > evil-test.sh
    git add -A
    git commit -q -m pr-change
    git update-ref refs/himmel/outside/7 HEAD
    # a second PR whose diff is over the 204800-byte cap the critics read
    head -c 300000 /dev/zero | tr '\0' 'a' > big.txt
    git add big.txt
    git commit -q -m pr-big
    git update-ref refs/himmel/outside/8 HEAD
    git reset -q --hard refs/himmel/outside/7
    git checkout -q main
    git branch -q -D prside
    # two PRs whose diff is exactly the cap (9) and one byte over it (10): a one-line new file off main,
    # measured as the critics count it (git's diff output, one trailing newline), the line length adjusted by the gap
    for pad_spec in "9 204800" "10 204801"; do
        pad_ref="${pad_spec%% *}"; pad_want="${pad_spec##* }"
        pad_n=1000
        for _pass in 1 2; do
            git checkout -q -B padside main
            head -c "$pad_n" /dev/zero | tr '\0' 'a' > pad.txt
            echo >> pad.txt
            git add pad.txt
            git commit -q -m "pr-pad-$pad_ref"
            pad_sz="$(git diff main...HEAD | wc -c | tr -d ' ')"
            [ "$_pass" = 1 ] && pad_n=$((pad_n + pad_want - pad_sz))
        done
        [ "$pad_sz" = "$pad_want" ] || { echo "FAIL: pad fixture $pad_ref is $pad_sz bytes, want $pad_want" >&2; exit 1; }
        git update-ref "refs/himmel/outside/$pad_ref" HEAD
        git checkout -q main
    done
    git branch -q -D padside
    git checkout -q -b elsewhere
) || { echo "FAIL: --pr fixture repo setup failed" >&2; exit 1; }
pr_oid="$(git -C "$prrepo" rev-parse refs/himmel/outside/7)"
pr_base="$(git -C "$prrepo" rev-parse main)"
pr_before="$(git -C "$prrepo" status --porcelain; git -C "$prrepo" rev-parse HEAD; git -C "$prrepo" config --list | cksum)"
pr_run() { # args...: sets pr_out, pr_err, pr_rc
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/stdin-log" "$tmp/err"
    pr_out="$( (cd "$prrepo" && HOME="$pr_home" GH_FALLBACK="$tmp/ghbin/gh" PR_OID="$pr_oid" STDIN_LOG="$tmp/stdin-log" FAKE_RC=0 \
        PATH="$tmp/prbin:$PATH" bash "$SCRIPT" "$@") 2>"$tmp/err" )"; pr_rc=$?
    pr_err="$(cat "$tmp/err")"
}
pr_rounds() { local f n=0; for f in "$prrepo"/.git/cr-review-rounds/*; do [ -e "$f" ] && n=$((n + 1)); done; echo "$n"; }
cp "$fx/scripts/cr/critic-panel.sh" "$tmp/critic-panel.stub"
# shellcheck disable=SC2016  # the fake panel's own text, expanded when it runs
printf '#!/usr/bin/env bash\necho "critic-panel.sh: unknown option $1" >&2\nexit 2\n' > "$fx/scripts/cr/critic-panel.sh"
pr_probe_refused() {
    if [ "$pr_rc" -eq 7 ]; then ok "$1 is refused (exit 7)"; else bad "$1 exit (got $pr_rc)"; fi
    assert_has "$pr_err" "--pin-ref" "$1: the refusal names --pin-ref"
    if [ -f "$CALL_LOG" ]; then bad "$1: the unpinned panel ran"; else ok "$1: the unpinned panel never ran"; fi
    if [ "$(pr_rounds)" = 0 ] && [ "$(rs_count "$prrepo")" = 0 ]; then ok "$1: no round spent, no round-scope row"; else bad "$1: state or a row was written"; fi
}
pr_run --pr 7 --head "$pr_oid" --branch feat/outside-thing
pr_probe_refused "T2.17 control: a panel without --pin-ref"
printf '# accepts: --pin-ref) pins the review to a ref instead of the live checkout\n' >> "$fx/scripts/cr/critic-panel.sh"
pr_run --pr 7 --head "$pr_oid" --branch feat/outside-thing
pr_probe_refused "T2.17 a comment that names --pin-ref alone"
printf '#!/usr/bin/env bash\ncat >/dev/null\nexit 0\n' > "$fx/scripts/cr/critic-panel.sh"
pr_run --pr 7 --head "$pr_oid" --branch feat/outside-thing
pr_probe_refused "T2.17 a panel that accepts any --pin-ref"
cp "$tmp/critic-panel.stub" "$fx/scripts/cr/critic-panel.sh"
pr_run --pr 7 --head "$pr_oid" --branch feat/outside-thing
if [ "$pr_rc" -eq 0 ]; then ok "T2.17 --pr from a checkout on another branch exits 0"; else bad "T2.17 --pr exit (got $pr_rc; err: $pr_err)"; fi
assert_has "$pr_out" "captured diff base: main ($pr_base)" "T2.17 the base is the merge base with the PR's base branch"
args="$(cat "$ARGS_LOG" 2>/dev/null)"
assert_has "$args" "--head $pr_oid" "T2.17 the panel is pinned to the PR head"
assert_has "$args" "--branch feat/outside-thing" "T2.17 the panel is pinned to headRefName"
assert_has "$args" "--pin-ref refs/himmel/outside/7" "T2.17 the panel is pinned to the PR ref"
assert_has "$(cat "$tmp/stdin-log" 2>/dev/null)" "evil-test.sh" "T2.17 the panel received the PR diff on stdin"
pr_row="$(rs_rows "$prrepo" | tail -n 1)"
assert_has "$pr_row" '"branch":"feat/outside-thing"' "T2.2 the round-scope row carries headRefName"
assert_has "$pr_row" "\"head\":\"$pr_oid\"" "T2.2 the round-scope row carries the PR head"
assert_has "$pr_row" '"scope":"full"' "T2.2 the round-scope row is a full round"
assert_has "$pr_row" '"source":"pr-diff"' "T2.2 the round-scope row's source is pr-diff"
assert_has "$pr_row" '"pr":7' "T2.2 the round-scope row names the PR"
pr_after="$(git -C "$prrepo" status --porcelain; git -C "$prrepo" rev-parse HEAD; git -C "$prrepo" config --list | cksum)"
if [ "$pr_before" = "$pr_after" ]; then ok "T2.3 status, HEAD and config of the primary fixture are unchanged"; else bad "T2.3 the primary fixture changed"; fi
if [ ! -e "$pr_canary" ]; then ok "T2.3 the PR's canary never ran"; else bad "T2.3 a PR file ran"; fi
if [ "$(git -C "$prrepo" worktree list | wc -l | tr -d ' ')" = 1 ]; then ok "T2.3 no new worktree"; else bad "T2.3 a worktree was added"; fi
# R5: the step 2.8 preflight of a --pr call is looked up under the PR's branch and head, not the checkout's
kf_pr="$fx/scripts/cr/known-findings.sh"; cp "$kf_pr" "$tmp/kf-pr.orig"
# shellcheck disable=SC2016 # the stub body expands in the stub, not here
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "%s"\nexit 0\n' "$tmp/kf-pr-args" > "$kf_pr"
mv "$prrepo/.git/cr-critic-scores.jsonl" "$tmp/pr-ledger.keep" 2>/dev/null
rm -f "$tmp/kf-pr-args"
pr_run --pr 7 --head "$pr_oid" --branch feat/outside-thing
mv "$tmp/pr-ledger.keep" "$prrepo/.git/cr-critic-scores.jsonl" 2>/dev/null
cp "$tmp/kf-pr.orig" "$kf_pr"
assert_has "$(cat "$tmp/kf-pr-args" 2>/dev/null)" "--area --branch feat/outside-thing --head $pr_oid" "R5 --pr passes the PR's branch and head to known-findings.sh --area"
pr_run_x() {
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/stdin-log" "$tmp/err"
    pr_out="$( (cd "$prrepo" && env HOME="$pr_home" GH_FALLBACK="$tmp/ghbin/gh" PR_OID="$pr_oid" STDIN_LOG="$tmp/stdin-log" FAKE_RC=0 \
        PATH="$tmp/prbin:$PATH" "${envs[@]}" bash "$SCRIPT" "$@") 2>"$tmp/err" )"; pr_rc=$?
    pr_err="$(cat "$tmp/err")"
}
git -C "$prrepo" update-ref refs/himmel/outside/11 "$pr_oid"
cp "$HERE/critic-panel.sh" "$HERE/failure-classify.sh" "$HERE/finding-reraise.js" "$HERE/triviality-gate.sh" "$fx/scripts/cr/"
cp "$HERE/../lib/prim.sh" "$HERE/../lib/canon-path.sh" "$fx/scripts/lib/"
REAL_MEMBER="$tmp/real-member.sh"
cat > "$REAL_MEMBER" <<'EOS'
#!/usr/bin/env bash
cat > "$REAL_DIFF_DUMP"
printf 'head=%s branch=%s pr=%s triv=%s\n' "${CR_TARGET_HEAD:-}" "${CR_TARGET_BRANCH:-}" "${CR_TARGET_PR:-}" "${CR_TRIVIALITY_OVERRIDE:-}" > "$REAL_ENV_DUMP"
printf '# real First-Pass Review\n\n## Critical Issues (0 found)\n\n## Important Issues (0 found)\n\n## Suggestions (0 found)\n'
EOS
chmod +x "$REAL_MEMBER"
printf '%s' '{"panel":[{"slug":"real","model":"real-model","provider":"nvidia","tier":"free"}]}' > "$tmp/real-critics.json"
REAL_DIFF_DUMP="$tmp/real-diff.txt"; REAL_ENV_DUMP="$tmp/real-env.txt"; rm -f "$REAL_DIFF_DUMP" "$REAL_ENV_DUMP"
cp "$HERE/critic-panel.sh" "$fx/scripts/cr/critic-panel.sh"
pr_run_x CRITICS_JSON="$tmp/real-critics.json" CRITIC_FIRST_PASS="$REAL_MEMBER" CR_PROFILE=free \
    REAL_DIFF_DUMP="$REAL_DIFF_DUMP" REAL_ENV_DUMP="$REAL_ENV_DUMP" -- --pr 11 --head "$pr_oid" --branch feat/outside-thing
if [ "$pr_rc" -eq 0 ]; then ok "T2.17 the real panel, --pr from a checkout on another branch: exit 0"; else bad "T2.17 real panel exit (got $pr_rc; err: $pr_err)"; fi
assert_has "$(cat "$REAL_DIFF_DUMP" 2>/dev/null)" "evil-test.sh" "T2.17 the real panel's member read the PR ref's diff, not the checkout's"
assert_lacks "$(cat "$REAL_DIFF_DUMP" 2>/dev/null)" "live.txt" "T2.17 the real panel's member never saw the checkout"
assert_has "$(cat "$REAL_ENV_DUMP" 2>/dev/null)" "head=$pr_oid branch=feat/outside-thing pr=11" "T2.17 the member sees the PR head, headRefName and PR number"
assert_has "$(cat "$REAL_ENV_DUMP" 2>/dev/null)" "triv=full" "R7 --pr sets CR_TRIVIALITY_OVERRIDE=full for the panel it runs"
pr_avail="$(grep -F '"kind":"avail"' "$prrepo/.git/cr-critic-scores.jsonl" | grep -F "\"head\":\"$pr_oid\"")"
assert_has "$pr_avail" '"branch":"feat/outside-thing"' "T2.17 the panel's own rows carry headRefName from a checkout on another branch"
if [ -n "$pr_avail" ]; then ok "T2.17 the panel wrote rows for the PR head"; else bad "T2.17 the panel wrote no row for the PR head"; fi
assert_lacks "$pr_avail" "$(git -C "$prrepo" rev-parse HEAD)" "T2.17 no panel row carries the checkout's head"
pr_row="$(rs_rows "$prrepo" | tail -n 1)"
assert_has "$pr_row" '"branch":"feat/outside-thing"' "T2.17 the round-scope row carries headRefName (real panel)"
assert_has "$pr_row" "\"head\":\"$pr_oid\"" "T2.17 the round-scope row carries the PR head (real panel)"
assert_has "$pr_row" '"pr":11' "T2.17 the round-scope row names the PR (real panel)"
cp "$tmp/critic-panel.stub" "$fx/scripts/cr/critic-panel.sh"
cap_lit() { grep -o 'CRITIC_FIRST_PASS_CAP_BYTES:-[0-9]*' "$1" | sed -n '1s/.*-//p'; }
cap_pfp="$(cap_lit "$HERE/panel-first-pass.sh")"; cap_cfp="$(cap_lit "$HERE/critic-first-pass.sh")"
if [ -n "$cap_pfp" ] && [ "$cap_pfp" = "$cap_cfp" ]; then ok "R2 the cap defaults in panel-first-pass.sh and critic-first-pass.sh are equal ($cap_pfp)"; else bad "R2 cap defaults differ (panel-first-pass.sh '$cap_pfp', critic-first-pass.sh '$cap_cfp')"; fi
sed 's/CRITIC_FIRST_PASS_CAP_BYTES:-204800/CRITIC_FIRST_PASS_CAP_BYTES:-204801/' "$HERE/panel-first-pass.sh" > "$tmp/pfp-cap-mutant.sh"
if [ "$(cap_lit "$tmp/pfp-cap-mutant.sh")" != "$cap_cfp" ]; then ok "R2 control: a drifted cap literal is told apart"; else bad "R2 control: the cap reader did not see a drifted literal"; fi
# T2.43: a direct call for an unlisted author with a hand-fetched ref is refused by start --pr
n_before="$(pr_rounds)"; rs_before="$(rs_rows "$prrepo" | wc -l | tr -d ' ')"
rm -f "$CALL_LOG"
pr_out="$( (cd "$prrepo" && HOME="$pr_home" GH_FALLBACK="$tmp/ghbin/gh" PR_OID="$pr_oid" PR_LOGIN=Stranger PR_ID=U_stranger FAKE_RC=0 \
    PATH="$tmp/prbin:$PATH" bash "$SCRIPT" --pr 7 --head "$pr_oid" --branch feat/outside-thing) 2>"$tmp/err" )"; pr_rc=$?
if [ "$pr_rc" -eq 5 ]; then ok "T2.43 a direct --pr call for an unlisted author exits 5"; else bad "T2.43 exit (got $pr_rc)"; fi
if [ ! -f "$CALL_LOG" ]; then ok "T2.43 the panel never ran"; else bad "T2.43 the panel ran for an unlisted author"; fi
if [ "$(pr_rounds)" = "$n_before" ] && [ "$(rs_rows "$prrepo" | wc -l | tr -d ' ')" = "$rs_before" ]; then ok "T2.43 no review-round state and no round-scope row"; else bad "T2.43 state or a row was written"; fi
# --pr input refusals
pr_run --pr 7 --head "${pr_oid:0:7}" --branch feat/outside-thing
if [ "$pr_rc" -eq 2 ]; then ok "--pr with a short head exits 2"; else bad "--pr short head exit (got $pr_rc)"; fi
pr_run --pr 7 --head "$pr_base" --branch feat/outside-thing
if [ "$pr_rc" -eq 7 ]; then ok "--pr with a head that is not the PR ref exits 7"; else bad "--pr head mismatch exit (got $pr_rc)"; fi
pr_run --pr x --head "$pr_oid" --branch feat/outside-thing
if [ "$pr_rc" -eq 2 ]; then ok "--pr with a non-numeric PR exits 2"; else bad "--pr non-numeric exit (got $pr_rc)"; fi
n_before="$(pr_rounds)"; rs_before="$(rs_rows "$prrepo" | wc -l | tr -d ' ')"
pr_run --pr 7 --head "$pr_oid" --branch some/other-branch
if [ "$pr_rc" -eq 7 ]; then ok "--pr with a --branch that is not the PR's headRefName exits 7"; else bad "--pr wrong branch exit (got $pr_rc)"; fi
assert_has "$pr_err" "headRefName" "--pr wrong branch: the refusal names headRefName"
if [ ! -f "$CALL_LOG" ] && [ "$(pr_rounds)" = "$n_before" ] && [ "$(rs_rows "$prrepo" | wc -l | tr -d ' ')" = "$rs_before" ]; then ok "--pr wrong branch: no panel, no round, no row"; else bad "--pr wrong branch: the panel ran or state was written"; fi
pr_ledger="$prrepo/.git/cr-critic-scores.jsonl"
# a hostile --branch is refused before anything is echoed or recorded
n_before="$(pr_rounds)"
pr_run_x X=1 -- --pr 7 --head "$pr_oid" --branch 'feat/x;touch-evil'
if [ "$pr_rc" -eq 2 ]; then ok "--pr with a branch outside the safe alphabet exits 2"; else bad "--pr hostile branch exit (got $pr_rc)"; fi
assert_lacks "$pr_err" "touch-evil" "--pr hostile branch: the raw name is never echoed"
if [ ! -f "$CALL_LOG" ] && [ "$(pr_rounds)" = "$n_before" ]; then ok "--pr hostile branch: no panel, no round"; else bad "--pr hostile branch: the panel ran or state was written"; fi
for pr_base_try in 'main;touch-evil' '-main' 'ma in'; do
    n_before="$(pr_rounds)"
    pr_run_x PR_BASE="$pr_base_try" -- --pr 7 --head "$pr_oid" --branch feat/outside-thing
    if [ "$pr_rc" -eq 7 ]; then ok "R1 --pr with base '$pr_base_try' exits 7"; else bad "R1 --pr base '$pr_base_try' exit (got $pr_rc)"; fi
    assert_has "$pr_err" "base branch name as the forge names it is outside the safe alphabet" "R1 base '$pr_base_try': the refusal names the base alphabet check"
    assert_lacks "$pr_out$pr_err" "touch-evil" "R1 base '$pr_base_try': the raw name is never echoed"
    if [ ! -f "$CALL_LOG" ] && [ "$(pr_rounds)" = "$n_before" ]; then ok "R1 base '$pr_base_try': no panel, no round"; else bad "R1 base '$pr_base_try': the panel ran or state was written"; fi
done
# an unreadable or unknown base never lets the diff read the station HEAD
for pr_base_try in nosuchbranch ""; do
    n_before="$(pr_rounds)"
    pr_run_x PR_BASE="$pr_base_try" -- --pr 7 --head "$pr_oid" --branch feat/outside-thing
    if [ "$pr_rc" -eq 7 ]; then ok "--pr with base '${pr_base_try:-<empty>}' exits 7"; else bad "--pr base '${pr_base_try:-<empty>}' exit (got $pr_rc)"; fi
    if [ ! -f "$CALL_LOG" ] && [ "$(pr_rounds)" = "$n_before" ]; then ok "--pr base '${pr_base_try:-<empty>}': no panel, no round"; else bad "--pr base '${pr_base_try:-<empty>}': the panel ran or state was written"; fi
done
# a diff over the byte cap the critics read is refused before a round starts
pr_oid8="$(git -C "$prrepo" rev-parse refs/himmel/outside/8)"
n_before="$(pr_rounds)"; rs_before="$(rs_rows "$prrepo" | wc -l | tr -d ' ')"
pr_run_x PR_OID="$pr_oid8" -- --pr 8 --head "$pr_oid8" --branch feat/outside-thing
if [ "$pr_rc" -eq 7 ]; then ok "--pr with a diff over the cap exits 7"; else bad "--pr over-cap exit (got $pr_rc)"; fi
assert_has "$pr_err" "204800" "--pr over-cap: the refusal names the cap"
if [ ! -f "$CALL_LOG" ] && [ "$(pr_rounds)" = "$n_before" ] && [ "$(rs_rows "$prrepo" | wc -l | tr -d ' ')" = "$rs_before" ]; then ok "--pr over-cap: no panel, no round, no row"; else bad "--pr over-cap: the panel ran or state was written"; fi
# the cap is measured as the critics count it: a diff of exactly the cap passes, one byte more is refused
pr_oid9="$(git -C "$prrepo" rev-parse refs/himmel/outside/9)"
pr_oid10="$(git -C "$prrepo" rev-parse refs/himmel/outside/10)"
if [ "$(git -C "$prrepo" diff "$pr_base...$pr_oid9" | wc -c | tr -d ' ')" = 204800 ] && [ "$(git -C "$prrepo" diff "$pr_base...$pr_oid10" | wc -c | tr -d ' ')" = 204801 ]; then ok "cap fixtures: refs 9 and 10 diff to 204800 and 204801 bytes"; else bad "cap fixtures have the wrong size"; fi
pr_run_x PR_OID="$pr_oid9" PR_BRANCH=feat/outside-pad9 -- --pr 9 --head "$pr_oid9" --branch feat/outside-pad9
if [ "$pr_rc" -eq 0 ]; then ok "--pr with a diff of exactly the cap passes (exit 0)"; else bad "--pr at-cap exit (got $pr_rc; err: $pr_err)"; fi
pr_run_x PR_OID="$pr_oid10" PR_BRANCH=feat/outside-pad10 -- --pr 10 --head "$pr_oid10" --branch feat/outside-pad10
if [ "$pr_rc" -eq 7 ]; then ok "--pr with a diff one byte over the cap exits 7"; else bad "--pr cap+1 exit (got $pr_rc)"; fi
if [ ! -f "$CALL_LOG" ]; then ok "--pr cap+1: the panel never ran"; else bad "--pr cap+1: the panel ran"; fi
# the rtk retry is measured the same way: an over-cap retry diff exits 7 and sends nothing to the panel
mkdir -p "$tmp/rtkbig"
cat > "$tmp/rtkbig/rtk" <<'RTKBIGEOF'
#!/usr/bin/env bash
head -c 300000 /dev/zero | tr '\0' 'b'
RTKBIGEOF
chmod +x "$tmp/rtkbig/rtk"
pr_run_x PR_BRANCH=feat/outside-retry FAKE_RC=1 PATH="$tmp/rtkbig:$tmp/prbin:$PATH" -- --pr 7 --head "$pr_oid" --branch feat/outside-retry
if [ "$pr_rc" -eq 7 ]; then ok "--pr: an over-cap rtk retry diff exits 7"; else bad "--pr over-cap retry exit (got $pr_rc)"; fi
assert_has "$pr_err" "204800" "--pr over-cap retry: the refusal names the cap"
if [ "$(wc -l < "$CALL_LOG" 2>/dev/null | tr -d ' ')" = 1 ]; then ok "--pr over-cap retry: the panel ran once, never on the retry diff"; else bad "--pr over-cap retry: panel calls (got $(wc -l < "$CALL_LOG" 2>/dev/null))"; fi
# authorization comes before the preflight: a refused author leaves no preflight row
pr_run_x PR_LOGIN=Stranger PR_ID=U_stranger PR_BRANCH=feat/other-thing -- --pr 7 --head "$pr_oid" --branch feat/other-thing
if [ "$pr_rc" -eq 5 ]; then ok "--pr for an unlisted author exits 5 before the preflight"; else bad "--pr unlisted author exit (got $pr_rc)"; fi
assert_no_ceilings "$pr_err" "--pr authorization refusal exit 5"
if [ "$(grep -F 'feat/other-thing' "$pr_ledger" 2>/dev/null | grep -c '"kind":"preflight"')" = 0 ]; then ok "--pr for an unlisted author writes no preflight row"; else bad "--pr for an unlisted author wrote a preflight row"; fi

ceil_secret="the f.txt reader never handles a CRLF line"
ceil_ledger="$tmp/ceilings.tsv"
printf 'id\tfile\tanchor\tceiling\ttrigger\tticket\tstate\tdate\tpr\tnote\nC-0001\tf.txt\tbase\t%s\ta CRLF bug report\t\topen\t2026-11-08\t\t\n' "$ceil_secret" > "$ceil_ledger"
mkdir -p "$tmp/cbin"
cp "$(command -v bash)" "$tmp/cbin/claude"
ceil_env=(env -u ANTHROPIC_BASE_URL -u ANTHROPIC_MODEL -u HERMES_ENGINE -u CODEX_ADAPTER -u CODEX_THREAD_ID -u CLAUDE_PID -u CODEX_PROXY_BASE_URL)
ceil_run() {
    local led=$1
    shift
    rm -rf "$repo/.git/cr-review-rounds"
    rm -f "$CALL_LOG" "$ARGS_LOG" "$tmp/ceil-stdin" "$tmp/err"
    # shellcheck disable=SC2016  # the single-quoted script runs in the stub shell
    out="$( (cd "$repo" && "${ceil_env[@]}" CLAUDECODE=1 HIMMEL_CEILINGS_LEDGER="$led" STDIN_LOG="$tmp/ceil-stdin" FAKE_RC="${CEIL_RC:-0}" \
        FAKE_OUT='[codex-1] f.txt:1 finding' "$@" "$tmp/cbin/claude" -c 'bash "$0" "$@"; rc=$?; exit $rc' "$SCRIPT" --head "$feature_sha" --branch feature) 2>"$tmp/err" )"; rc=$?
    err="$(cat "$tmp/err")"
}
ceil_run "$ceil_ledger"
out_rows=$out
if [ "$rc" -eq 0 ]; then ok "ceilings: the native run exits 0"; else bad "ceilings: native exit (got $rc; err: $err)"; fi
assert_has "$err" "C-0001 f.txt [base]" "ceilings: a native Claude run prints the row id on stderr"
eq_count="$(ceilings_count "$err")"
if [ "$eq_count" = 1 ]; then ok "ceilings: exactly one header on a panel run"; else bad "ceilings: headers on a panel run (got $eq_count)"; fi
assert_lacks "$out" "CEILINGS:" "ceilings: nothing on stdout"
assert_lacks "$(cat "$tmp/ceil-stdin" 2>/dev/null)" "$ceil_secret" "ceilings: the panel's stdin carries no row text"
assert_lacks "$(cat "$ARGS_LOG" 2>/dev/null)" "$ceil_secret" "ceilings: the panel's argv carries no row text"
assert_has "$(cat "$tmp/ceil-stdin" 2>/dev/null)" "+change" "ceilings: control, the panel's stdin was logged"
ceil_run "$tmp/no-ceilings-ledger.tsv"
if [ "$out" = "$out_rows" ]; then ok "ceilings: stdout is byte-equal to a run with no ledger"; else bad "ceilings: stdout differs from a run with no ledger"; fi
assert_has "$err" "CEILINGS: not read (no ledger for" "ceilings: a missing ledger reads not read"
ceil_run "$ceil_ledger" ANTHROPIC_BASE_URL=http://127.0.0.1:8317
assert_has "$err" "CEILINGS: withheld (non-Claude session:" "ceilings: a claudex env is withheld"
assert_lacks "$err" "$ceil_secret" "ceilings: the claudex run shows no ceiling"
ceil_run "$ceil_ledger" CLAUDECODE=
assert_has "$err" "CEILINGS: withheld (non-Claude session: CLAUDECODE is not 1)" "ceilings: CLAUDECODE unset is withheld"
CEIL_RC=1 ceil_run "$ceil_ledger"
if [ "$rc" -eq 0 ] && [ "$(ceilings_count "$err")" = 1 ]; then ok "ceilings: the fail-open run prints one header"; else bad "ceilings: fail-open (rc $rc, headers $(ceilings_count "$err"))"; fi
ceil_run "$ceil_ledger" CR_PROFILE=none
if [ "$rc" -eq 0 ] && [ "$(ceilings_count "$err")" = 1 ]; then ok "ceilings: CR_PROFILE=none prints one header"; else bad "ceilings: CR_PROFILE=none (rc $rc, headers $(ceilings_count "$err"))"; fi
assert_has "$err" "C-0001 f.txt" "ceilings: CR_PROFILE=none shows the row"
rm -f "$tmp/err"
(cd "$tmp/wt-empty" && bash "$SCRIPT" --head "$empty_sha" --branch feature-empty) >/dev/null 2>"$tmp/err"; rc=$?
err="$(cat "$tmp/err")"
if [ "$rc" -eq 0 ] && [ "$(ceilings_count "$err")" = 1 ]; then ok "ceilings: an empty diff prints one header"; else bad "ceilings: empty diff (rc $rc, headers $(ceilings_count "$err"))"; fi
real_git="$(command -v git)"
mkdir -p "$tmp/gitfail"
# shellcheck disable=SC2016  # the stub's own text, expanded when it runs
printf '#!/usr/bin/env bash\n[ "${1:-}" = diff ] && { echo "fatal: diff refused" >&2; exit 128; }\nexec "%s" "$@"\n' "$real_git" > "$tmp/gitfail/git"
chmod +x "$tmp/gitfail/git"
ceil_run "$ceil_ledger" PATH="$tmp/gitfail:$PATH"
if [ "$rc" -eq 0 ]; then ok "ceilings: a failed git diff exits 0"; else bad "ceilings: failed git diff exit (got $rc; err: $err)"; fi
assert_has "$err" "git diff failed" "ceilings: control, the git diff failure branch ran"
if [ "$(ceilings_count "$err")" = 1 ]; then ok "ceilings: a failed git diff prints one header"; else bad "ceilings: failed git diff headers (got $(ceilings_count "$err"))"; fi
assert_has "$err" "CEILINGS: not read (bad range)" "ceilings: a failed git diff reads not read"
mkdir -p "$tmp/anchor/scripts/ledger"
printf '#!/usr/bin/env bash\necho "CEILINGS: ANCHOR-COPY-MARKER"\n' > "$tmp/anchor/scripts/ledger/ceiling-lookup.sh"
ceil_run "$ceil_ledger" HIMMEL_REPO="$tmp/anchor" CR_PROFILE=none
assert_has "$err" "CEILINGS: ANCHOR-COPY-MARKER" "ceilings: the HIMMEL_REPO anchor's lookup runs"
assert_lacks "$err" "C-0001" "ceilings: the fixture tree's own lookup does not run"
ceil_run "$ceil_ledger" HIMMEL_REPO= CR_PROFILE=none
assert_has "$err" "CEILINGS: not read (HIMMEL_REPO unset)" "ceilings: HIMMEL_REPO unset reads not read"
rm -rf "$repo/.git/cr-review-rounds"

# --- no writes outside the mktemp fixture -----------------------------------
# panel-first-pass.sh's only persistent writes are mktemp -t cr-panel-avail.*
# scratch files, always rm -f'd before it returns. Any NEW one since the
# pre-run snapshot would mean this suite's own runs leaked a file into the
# shared system temp dir (pre-existing ones from other processes are not
# this suite's concern).
_post_tmp="$(_list_panel_avail_tmp)"
_new_tmp="$(comm -13 <(printf '%s\n' "$_pre_tmp") <(printf '%s\n' "$_post_tmp") 2>/dev/null || true)"
if [ -z "$_new_tmp" ]; then
    ok "no NEW leaked cr-panel-avail or cr-pfp-ctx scratch files outside the fixture"
else
    bad "leaked scratch files outside the fixture: $_new_tmp"
fi

if [ "$fail" -eq 0 ]; then echo "PASS test-panel-first-pass"; else echo "FAILURES in test-panel-first-pass"; exit 1; fi
