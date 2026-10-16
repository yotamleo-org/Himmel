#!/usr/bin/env bash
# scripts/guardrails/test-check-git-env-scrub.sh: exercises
# check-git-env-scrub.sh against tracked fixtures under
# scripts/guardrails/git-env-scrub-cases/ (deliberately NOT named fixtures/ or
# test-fixtures/ — the checker itself excludes paths under those directory
# names, which would make every fixture here invisible to it).
#
# Platform guard: POSIX bash 3.2+, same as the other guardrail tests here —
# no .ps1 twin.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$REPO_ROOT/scripts/guardrails/check-git-env-scrub.sh"
CASES="scripts/guardrails/git-env-scrub-cases"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

EMPTY_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-empty-baseline.XXXXXX")" || exit 2
trap 'rm -f "$EMPTY_BASELINE" "$SCOPED_BASELINE"' EXIT

# run <fixture...> -- scans the named fixture(s) under an EMPTY baseline (so
# no real baseline entry can accidentally mask a test), from the repo root.
OUT=""
run() {
    OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$EMPTY_BASELINE" --tree "$@" 2>&1)"
    return $?
}

expect_red() {
    local label="$1" fixture="$2"
    run "$CASES/$fixture"
    local rc=$?
    if [ "$rc" -eq 1 ] && grep -qF "$fixture" <<<"$OUT"; then
        pass "$label"
    else
        fail "$label (rc=$rc)"
        printf '%s\n' "$OUT" | sed 's/^/    /'
    fi
}

expect_green() {
    local label="$1" fixture="$2"
    run "$CASES/$fixture"
    local rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "$label"
    else
        fail "$label (rc=$rc)"
        printf '%s\n' "$OUT" | sed 's/^/    /'
    fi
}

# ---- RED at base: the two fixtures the brief requires to fail out of the
# gate, with no scrub, no baseline, nothing to save them. ----
expect_red  "T1  unscrubbed shell entry point fails"          unscrubbed-entry.sh
expect_red  "T2  unscrubbed JS execFileSync('git', ...) fails" unscrubbed.mjs

# ---- shell: scrub / helper / exemption / control shapes ----
expect_green "T3  all-four unset on one line passes"           unset-scrubbed.sh
expect_green "T4  all-four unset split across lines passes"    split-unset-scrubbed.sh
expect_green "T5  source git-clean.sh + git_env_scrub passes"  helper-scrubbed.sh
expect_green "T6  file-level exemption with a reason passes"   file-exempt.sh
expect_red   "T7  file-level exemption with NO reason fails"   file-exempt-no-reason.sh
expect_green "T8  case-pattern/string/comment 'git' is not a call" case-pattern-only.sh

# ---- shell: shebang-less entry-point risk (console REDIRECT, 2026-09-24) ----
expect_red   "T9  shebang-less .sh with an unmarked git call fails" sourced-lib-unmarked.sh
expect_green "T10 shebang-less .sh marked '# sourced-lib' passes"   sourced-lib-marked.sh
expect_green "T11 shebang-less .sh with no git call at all passes"  sourced-lib-no-invocation.sh

# ---- JS: scrub / helper / exemption shapes ----
expect_green "T12 scrub keys visible in the call window passes" scrubbed.mjs
expect_green "T13 routes through the shared gitClean() helper"  helper.mjs
expect_green "T14 same-line exemption with a reason passes"     exempt.mjs
expect_red   "T15 same-line exemption with NO reason fails"     exempt-no-reason.mjs

# ---- baseline: a listed shell file and a listed JS call are grandfathered ----
SCOPED_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-scoped-baseline.XXXXXX")" || exit 2
{
    printf 'SHELL:%s/baseline-listed.sh\n' "$CASES"
    line="$(sed -n '6p' "$REPO_ROOT/$CASES/baseline-listed.mjs")"
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if command -v sha256sum >/dev/null 2>&1; then
        hash="$(printf '%s' "$trimmed" | sha256sum | cut -c1-12)"
    else
        hash="$(printf '%s' "$trimmed" | shasum -a 256 | cut -c1-12)"
    fi
    printf 'JS:%s/baseline-listed.mjs:%s\n' "$CASES" "$hash"
} > "$SCOPED_BASELINE"

OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$SCOPED_BASELINE" --tree "$CASES/baseline-listed.sh" "$CASES/baseline-listed.mjs" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T16 baseline-listed shell file and JS call are grandfathered"
else
    fail "T16 baseline-listed shell file and JS call are grandfathered (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# T17 -- same two fixtures, WITHOUT the scoped baseline: both must fail, to
# prove T16 passed because of the baseline and not by accident.
run "$CASES/baseline-listed.sh" "$CASES/baseline-listed.mjs"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "baseline-listed.sh" <<<"$OUT" && grep -qF "baseline-listed.mjs" <<<"$OUT"; then
    pass "T17 same two fixtures fail without the baseline (control)"
else
    fail "T17 same two fixtures fail without the baseline (control) (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# ---- detector gaps: quoted, multi-word, bare-exec, multiline and comment shapes ----
expect_red "T19 git inside a double-quoted \$(...) cmdsub is caught"     quoted-cmdsub-unscrubbed.sh
expect_red "T20 quoted multi-word command string ('git status') is caught" quoted-multiword-unscrubbed.mjs
expect_red "T21 bare exec( ) (no Sync/File) is caught"                   exec-bare-unscrubbed.mjs
expect_red "T22 scrub names in a COMMENT alone don't satisfy the window" comment-fake-scrub-unscrubbed.mjs

# ---- should-fix round (console adversarial review, 2026-09-24) ----

# T23 -- a --tree path that does not exist must fail, not report clean. Before
# the fix, a nonexistent path matches neither `-f` nor `-d` and is silently
# skipped, so the fixture below (deliberately never on disk) would previously
# report zero findings and rc=0.
T23_OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$EMPTY_BASELINE" --tree "$CASES/does-not-exist-xyz.sh" 2>&1)"
T23_RC=$?
if [ "$T23_RC" -ne 0 ] && grep -qF "does not exist" <<<"$T23_OUT"; then
    pass "T23 --tree on a nonexistent path fails, not clean"
else
    fail "T23 --tree on a nonexistent path fails, not clean (rc=$T23_RC)"
    printf '%s\n' "$T23_OUT" | sed 's/^/    /'
fi

# T24 -- bare `--tree` (no PATH args — the real full-scan mode CI runs, see
# T18 below) must fail, not report clean, when it scans zero trust-path
# files. Before the fix, `git ls-files ... 2>/dev/null` inside a process
# substitution silently swallows an empty/errored file list and the checker
# exits 0 "clean" with no floor on how many files it actually looked at.
# Isolated tmp repo: none of the five trust-path pathspecs exist in it, so
# `git ls-files` legitimately returns an empty list.
T24_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-env-scrub-empty-repo.XXXXXX")" || exit 2
(cd "$T24_REPO" && git init -q && git config user.email t@t && git config user.name t) >/dev/null 2>&1
T24_OUT="$(cd "$T24_REPO" && bash "$CHECKER" --baseline "$EMPTY_BASELINE" --tree 2>&1)"
T24_RC=$?
rm -rf "$T24_REPO"
if [ "$T24_RC" -ne 0 ]; then
    pass "T24 default mode with 0 trust-path files scanned fails, not clean"
else
    fail "T24 default mode with 0 trust-path files scanned fails, not clean (rc=$T24_RC)"
    printf '%s\n' "$T24_OUT" | sed 's/^/    /'
fi

# T25 -- --staged must catch a rename INTO a trust path. Before the fix,
# `--diff-filter=ACM` omits `R`, so `git mv scripts/other/x.sh
# scripts/hooks/x.sh` (status R100) never reaches the scanner and pre-commit
# passes an unscrubbed file renamed straight into a guarded directory.
T25_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-env-scrub-staged-repo.XXXXXX")" || exit 2
(
    cd "$T25_REPO" || exit 1
    git init -q
    git config user.email t@t
    git config user.name t
    mkdir -p scripts/other scripts/hooks
    printf '#!/usr/bin/env bash\ngit status\n' > scripts/other/x.sh
    git add scripts/other/x.sh
    git commit -q -m init
    git mv scripts/other/x.sh scripts/hooks/x.sh
) >/dev/null 2>&1
T25_OUT="$(cd "$T25_REPO" && bash "$CHECKER" --baseline "$EMPTY_BASELINE" --staged 2>&1)"
T25_RC=$?
rm -rf "$T25_REPO"
if [ "$T25_RC" -eq 1 ] && grep -qF "scripts/hooks/x.sh" <<<"$T25_OUT"; then
    pass "T25 --staged catches a rename INTO a trust path"
else
    fail "T25 --staged catches a rename INTO a trust path (rc=$T25_RC)"
    printf '%s\n' "$T25_OUT" | sed 's/^/    /'
fi

# ---- multi-line spawn calls ----

# T26/T27 -- an execFileSync( call whose 'git' argument is on the next line.
expect_red   "T26 multi-line execFileSync(\\n 'git' ...) is caught"        multiline-unscrubbed.mjs
expect_green "T27 multi-line call with the scrub keys in its env passes"  multiline-scrubbed.mjs

# T28 -- a baseline entry that no longer corresponds to a hit is STALE and
# must fail the full scan, so the ratchet can shrink. One bogus entry on top
# of the real baseline; the full real-tree scan must now exit 1 naming it.
T28_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-stale-baseline.XXXXXX")" || exit 2
{
    cat "$REPO_ROOT/scripts/guardrails/git-env-baseline.txt"
    printf 'SHELL:scripts/hooks/does-not-exist-xyz.sh\n'
} > "$T28_BASELINE"
T28_OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$T28_BASELINE" --tree 2>&1)"
T28_RC=$?
rm -f "$T28_BASELINE"
if [ "$T28_RC" -eq 1 ] && grep -qF "stale" <<<"$T28_OUT" && grep -qF "does-not-exist-xyz.sh" <<<"$T28_OUT"; then
    pass "T28 a stale baseline entry fails the full scan"
else
    fail "T28 a stale baseline entry fails the full scan (rc=$T28_RC)"
    printf '%s\n' "$T28_OUT" | sed 's/^/    /'
fi

# ---- exemption forgery, exotic shell shapes, JS window, new
# extensions, and the gate's own environment ----

# Item 2 -- exemption forgery.
expect_red   "T29 a marker mid-sentence in a comment is not an exemption"      marker-prose-unscrubbed.sh
expect_red   "T30 helper name / git_env_scrub in a comment or string is no scrub" helper-name-in-comment-unscrubbed.sh
expect_red   "T31 an unset inside a never-called function is no scrub"          unset-in-uncalled-fn-unscrubbed.sh
expect_green "T32 the same function, called before git, is a scrub (control)"   unset-in-called-fn-scrubbed.sh
expect_red   "T33 a bare '# sourced-lib' marker with no reason fails"           sourced-lib-no-reason.sh
expect_red   "T34 a '// git-env-ok:' marker inside a JS string literal fails"   marker-in-string-unscrubbed.mjs

# Item 3 -- exotic shell call shapes.
expect_red   "T35 \\git is a git invocation"                                    backslash-git-unscrubbed.sh
expect_red   "T36 a quoted variable holding git is a git invocation"            var-git-unscrubbed.sh
expect_red   "T37 bash -c 'git ...' is a git invocation"                        bash-c-unscrubbed.sh
expect_red   "T38 eval \"git ...\" is a git invocation"                         eval-unscrubbed.sh
expect_red   "T39 a git payload on a line-continued bash -c is caught"          line-continued-unscrubbed.sh
expect_red   "T40 \$# earlier on the line does not truncate the scan"           hash-truncates-unscrubbed.sh

# Follow-up (b) -- the inline scrub needs the full set, not the original four.
expect_red   "T41 a hand scrub of only the original four vars fails (shell)"    four-unset-unscrubbed.sh
expect_red   "T42 a JS env dropping only the original four keys fails"          four-keys-unscrubbed.mjs
expect_red   "T43 a per-call env -u of only the original four vars fails"       env-u-four-unscrubbed.sh
expect_green "T44 a per-call env -u of every var passes (control)"              env-u-all-scrubbed.sh
expect_green "T45 every key dropped inside the JS call passes (control)"        all-keys-scrubbed.mjs

# Item 1 + wrapper helpers -- the JS window.
expect_red   "T46 a nearby gitClean() call does not mask a raw call"            window-gitclean-masked-unscrubbed.mjs
expect_red   "T47 scrub names only as string literals do not scrub"             window-string-names-unscrubbed.mjs
expect_red   "T48 a local run('git', ...) wrapper call is flagged"              wrapper-run-unscrubbed.mjs
expect_red   "T49 execFileSync(GIT, ...) with GIT = 'git' is flagged"           var-held-unscrubbed.mjs
expect_green "T50 'git' as an argument of a non-spawn callee is not a call"     not-a-spawn-scrubbed.mjs

# Item 4 -- extensions beyond .sh/.mjs/.js.
expect_red   "T51 an unscrubbed .cjs entry point fails"                         unscrubbed.cjs
expect_red   "T52 an unscrubbed .ts entry point fails"                          unscrubbed.ts
expect_red   "T53 an unscrubbed .py entry point fails"                          unscrubbed.py
expect_green "T54 a .py entry point dropping every var passes (control)"        scrubbed.py

# Item 5 -- the gate does not trust its inherited environment.
# T57: a baseline named only by the inherited GIT_ENV_SCRUB_BASELINE must not
# be honoured: the file listed there would grandfather the red fixture.
T57_BASELINE="$(mktemp "${TMPDIR:-/tmp}/git-env-scrub-env-baseline.XXXXXX")" || exit 2
printf 'SHELL:%s/unscrubbed-entry.sh\n' "$CASES" > "$T57_BASELINE"
T57_OUT="$(cd "$REPO_ROOT" && env GIT_ENV_SCRUB_BASELINE="$T57_BASELINE" bash "$CHECKER" --tree "$CASES/unscrubbed-entry.sh" 2>&1)"
T57_RC=$?
rm -f "$T57_BASELINE"
if [ "$T57_RC" -eq 1 ] && grep -qF "unscrubbed-entry.sh" <<<"$T57_OUT"; then
    pass "T57 an inherited GIT_ENV_SCRUB_BASELINE is not honoured"
else
    fail "T57 an inherited GIT_ENV_SCRUB_BASELINE is not honoured (rc=$T57_RC)"
    printf '%s\n' "$T57_OUT" | sed 's/^/    /'
fi

# T58/T59: the checker's own git calls run under a scrubbed environment — a
# poisoned GIT_DIR must neither break its repo discovery nor hide a finding.
T58_OUT="$(cd "$REPO_ROOT" && env GIT_DIR=/nonexistent/poison GIT_WORK_TREE=/nonexistent/poison GIT_COMMON_DIR=/nonexistent/poison GIT_INDEX_FILE=/nonexistent/poison bash "$CHECKER" --baseline "$EMPTY_BASELINE" --tree "$CASES/unscrubbed-entry.sh" 2>&1)"
T58_RC=$?
if [ "$T58_RC" -eq 1 ] && grep -qF "unscrubbed-entry.sh" <<<"$T58_OUT"; then
    pass "T58 poisoned GIT_* in the caller's env does not break the scan"
else
    fail "T58 poisoned GIT_* in the caller's env does not break the scan (rc=$T58_RC)"
    printf '%s\n' "$T58_OUT" | sed 's/^/    /'
fi
T59_OUT="$(cd "$REPO_ROOT" && env GIT_DIR=/nonexistent/poison GIT_WORK_TREE=/nonexistent/poison bash "$CHECKER" --baseline "$EMPTY_BASELINE" --tree "$CASES/unset-scrubbed.sh" 2>&1)"
T59_RC=$?
if [ "$T59_RC" -eq 0 ]; then
    pass "T59 poisoned GIT_* in the caller's env does not fail a clean scan"
else
    fail "T59 poisoned GIT_* in the caller's env does not fail a clean scan (rc=$T59_RC)"
    printf '%s\n' "$T59_OUT" | sed 's/^/    /'
fi

# T60 -- pin: --staged is a pre-commit gate and a hook legitimately runs with
# GIT_INDEX_FILE pointing at the index being committed, so the self-scrub
# must keep it. The file is staged ONLY in the alternate index.
T60_REPO="$(mktemp -d "${TMPDIR:-/tmp}/git-env-scrub-altindex-repo.XXXXXX")" || exit 2
T60_OUT="$(
    cd "$T60_REPO" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    mkdir -p scripts/hooks
    printf '#!/usr/bin/env bash\ngit status\n' > scripts/hooks/alt.sh
    GIT_INDEX_FILE="$T60_REPO/.git/alt-index" git add scripts/hooks/alt.sh
    GIT_INDEX_FILE="$T60_REPO/.git/alt-index" bash "$CHECKER" --baseline "$EMPTY_BASELINE" --staged 2>&1
    echo "rc=$?"
)"
rm -rf "$T60_REPO"
if grep -qF "scripts/hooks/alt.sh" <<<"$T60_OUT" && grep -qx "rc=1" <<<"$T60_OUT"; then
    pass "T60 --staged still reads the index named by GIT_INDEX_FILE"
else
    fail "T60 --staged still reads the index named by GIT_INDEX_FILE"
    printf '%s\n' "$T60_OUT" | sed 's/^/    /'
fi

# T61/T62 -- a `${...}` substitution inside a template literal is code: a git
# spawn there is flagged, and the helper-routed twin is the green control.
expect_red   "T61 git spawn inside a template \${...} substitution is caught" template-subst-unscrubbed.mjs
expect_green "T62 helper-routed call inside a template substitution passes"   template-subst-scrubbed.mjs

# T63/T64 -- two identical unscrubbed calls on one line: one baseline entry
# grandfathers one call, not both; two entries grandfather both.
TWO_LINE="$(sed -n '7p' "$REPO_ROOT/$CASES/two-calls-one-line-unscrubbed.mjs")"
TWO_TRIM="${TWO_LINE#"${TWO_LINE%%[![:space:]]*}"}"
TWO_TRIM="${TWO_TRIM%"${TWO_TRIM##*[![:space:]]}"}"
if command -v sha256sum >/dev/null 2>&1; then
    TWO_HASH="$(printf '%s' "$TWO_TRIM" | sha256sum | cut -c1-12)"
else
    TWO_HASH="$(printf '%s' "$TWO_TRIM" | shasum -a 256 | cut -c1-12)"
fi
printf 'JS:%s/two-calls-one-line-unscrubbed.mjs:%s\n' "$CASES" "$TWO_HASH" > "$SCOPED_BASELINE"
OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$SCOPED_BASELINE" --tree "$CASES/two-calls-one-line-unscrubbed.mjs" 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && grep -qF "two-calls-one-line-unscrubbed.mjs" <<<"$OUT"; then
    pass "T63 one baseline entry does not cover two calls on a line"
else
    fail "T63 one baseline entry does not cover two calls on a line (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi
printf 'JS:%s/two-calls-one-line-unscrubbed.mjs:%s\n' "$CASES" "$TWO_HASH" "$CASES" "$TWO_HASH" > "$SCOPED_BASELINE"
OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --baseline "$SCOPED_BASELINE" --tree "$CASES/two-calls-one-line-unscrubbed.mjs" 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
    pass "T64 two baseline entries cover two calls on a line (control)"
else
    fail "T64 two baseline entries cover two calls on a line (control) (rc=$rc)"
    printf '%s\n' "$OUT" | sed 's/^/    /'
fi

# T65 -- an error constructor whose message starts with "git" is not a spawn
# (cloud-route.mjs carries one; the template fix made it visible to the scan).
expect_green "T65 new Error('git ...') message is not a spawn"                error-message-scrubbed.mjs

# T66/T67 -- `-u NAME` only scrubs behind an `env`
# wrapper; a line comment between `(` and the git argument hides nothing.
expect_red   "T66 '-u NAME' words that are git arguments are not a scrub"      dash-u-not-env-unscrubbed.sh
expect_red   "T67 line comment between '(' and 'git' does not hide the spawn"  comment-before-git-unscrubbed.mjs

# T18 -- sanity: the real trust paths, under the real committed baseline,
# report clean. This is the ratchet's day-one promise.
REAL_OUT="$(cd "$REPO_ROOT" && bash "$CHECKER" --tree 2>&1)"
real_rc=$?
if [ "$real_rc" -eq 0 ] && grep -qF "clean" <<<"$REAL_OUT"; then
    pass "T18 real trust paths are clean under the committed baseline"
else
    fail "T18 real trust paths are clean under the committed baseline (rc=$real_rc)"
    printf '%s\n' "$REAL_OUT" | sed 's/^/    /'
fi

echo
echo "== summary =="
if [ "$failures" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "$failures FAILURE(S)"
    exit 1
fi
