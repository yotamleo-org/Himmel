#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# Hermetic test for scripts/cr/impacted-suites.sh. Builds a
# throwaway repo shaped like PR #2261: a changed script (uninstall-plugins.sh)
# whose end-to-end suite (test-uninstall.sh) lives one directory UP and that
# neither a directory sweep nor "the owning suites" prose would have reached.
#
# Platform guard: POSIX bash 3.2+; runs under Git Bash on Windows too.
#
# Usage: bash scripts/cr/test-impacted-suites.sh
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# grepq <text> [grep-args...] — `grep -q` with no pipeline (pipefail SIGPIPE
# trap).
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
IS="$REPO_ROOT/scripts/cr/impacted-suites.sh"
# shellcheck source=scripts/lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/fixture-tempdir.sh"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

if [ ! -f "$IS" ]; then
    fail "impacted-suites.sh not found at $IS"
    echo "FAIL: $failures case(s) failed"
    exit 1
fi

# SHD is first assigned in row 36b but named in the EXIT traps of rows 36/36a; declared
# here so an early exit cannot abort that cleanup on an unbound variable.
SHD=""
FX="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX"' EXIT

# --- fixture repo ---------------------------------------------------------
mkf() { mkdir -p "$FX/$(dirname "$1")"; printf '%s\n' "${2:-# $1}" > "$FX/$1"; }
(
    fixture_enter_git_init_dir "$FX" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkf scripts/machine-setup/uninstall-plugins.sh
mkf scripts/machine-setup/install.sh
mkf scripts/uninstall.sh
mkf scripts/test-uninstall.sh 'bash "$d/machine-setup/uninstall-plugins.sh"; bash "$d/uninstall.sh"'
mkf scripts/test-other.sh 'bash "$d/uninstall.sh"'
mkf scripts/test-wrapper.sh 'bash "$d/test-other.sh"'
mkf scripts/test-installer.sh 'bash "$d/machine-setup/install.sh"'
mkf scripts/lanes/tests/plugins.test.mjs "run('uninstall-plugins.sh');"
mkf .claude/commands/pr-check.md
mkf scripts/test-cmd.sh 'grep -q "/pr-check" x'
mkf scripts/test-clean-cmd.sh 'grep -q "/pr-check_extra" x'
mkf docs/foo/README.md
mkf scripts/test-readme-foo.sh 'grep -q foo/README.md x'
mkf scripts/test-readme-bare.sh 'grep -q README.md x'
mkf package.json '{}'
mkf scripts/test-pkg.sh 'grep -q "$root/package.json" x'
mkf scripts/eval/guard-corpus/diff
mkf scripts/test-diff-word.sh 'diff -u a b'
mkf scripts/test-guard-corpus.sh 'bash "$d/eval/guard-corpus/diff"'
mkf scripts/test-diff-fullpath.sh 'bash scripts/eval/guard-corpus/diff'
mkf scripts/test-diff-var.sh 'DIFF="$HERE/diff"'
mkf scripts/claude-fake
mkf scripts/test-claude-fake.sh "launcher=path.join(scripts,'claude-fake')"
mkf scripts/test-diff-source.sh 'cd eval/guard-corpus && source diff'
mkf scripts/test-diff-dot.sh 'cd eval/guard-corpus && . "diff"'
mkf scripts/test-diff-directive.sh '# shellcheck source=diff'
mkf scripts/test-diff-dashdash.sh 'cd eval/guard-corpus && source -- diff'
mkf scripts/q/'we"ird.sh'
mkf scripts/test-q-dquote.sh 'bash "$d/q/we"ird.sh'
mkf scripts/q/'back\slash.sh'
mkf scripts/test-q-backslash.sh 'bash "$d/q/back\slash.sh"'
mkf scripts/q/$'ta\tb.sh'
mkf scripts/test-q-tab.sh $'bash "$d/q/ta\tb.sh"'
mkf scripts/test-diff-plain.sh 'cd eval/guard-corpus && diff a b'
mkf scripts/test-diff-prose.sh '# the source diff is shown below'
mkf scripts/diff-helper.sh 'cd eval/guard-corpus && source diff'
mkf scripts/test-diff-helper.sh 'bash "$d/diff-helper.sh"'
mkf scripts/hooks/block-foo-guard.sh
mkf scripts/test-stem-ext.sh 'guard_rc block-foo-guard "x"'
mkf scripts/test-stem-longer.sh 'guard_rc block-foo-guard-extra "x"'
mkf scripts/test-stem-dotted.sh 'x=block-foo-guard.bak'
mkf scripts/lib/my_helper.sh
mkf scripts/test-stem-underscore.sh 'use my_helper here'
mkf scripts/hooks/gate.sh
mkf scripts/test-stem-word.sh 'open the gate now'
mkf scripts/test-stem-gate-full.sh 'bash scripts/hooks/gate.sh'
mkf scripts/test-stem-lead.sh 'guard_rc x-block-foo-guard "x"'
mkf scripts/hooks/a+b-c.sh
mkf scripts/test-stem-plus.sh 'guard_rc a+b-c "x"'
mkf scripts/test-stem-plus-wild.sh 'guard_rc aab-c "x"'
mkf scripts/lib/clo-lib.sh
mkf scripts/hooks/block-clo-hook.sh 'source "$d/lib/clo-lib.sh"'
mkf scripts/test-clo-stem.sh 'guard_rc block-clo-hook "x"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: base"

# change <file> — append a line to <file>, commit, set $range to that commit.
change() {
    printf '# changed\n' >> "$FX/$1" || return 1
    git -C "$FX" add -A || return 1
    git -C "$FX" commit -q -m "fix: change $1" || return 1
    range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
}
run_is() { ( cd "$FX" && bash "$IS" "$@" 2>/dev/null ); }

# --- 1. the #2261 shape: the far-away end-to-end suite is listed -----------
change scripts/machine-setup/uninstall-plugins.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "uninstall-plugins.sh -> scripts/test-uninstall.sh (one dir up)"; else fail "test-uninstall.sh not listed: $out"; fi
if grepq "$out" '^scripts/lanes/tests/plugins\.test\.mjs$'; then pass ".test.mjs suite listed"; else fail "mjs suite not listed: $out"; fi
if ! grepq "$out" 'test-other\.sh'; then pass "suite naming only uninstall.sh is not listed"; else fail "test-other.sh listed for an uninstall-plugins.sh change: $out"; fi
out="$(run_is "$range" --shell)"
if ! grepq "$out" '\.mjs$' && grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "--shell keeps only test-*.sh"; else fail "--shell output wrong: $out"; fi

# --- 2. word boundary: install.sh must not match uninstall.sh ---------------
change scripts/machine-setup/install.sh
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "install.sh change lists only its own suite (not uninstall.sh mentions)"; else fail "install.sh boundary: $out"; fi

# --- 3. command form: /pr-check, and /pr-check_extra is a different word -----
change .claude/commands/pr-check.md
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-cmd\.sh$'; then pass "commands/pr-check.md -> suite naming /pr-check"; else fail "/pr-check suite not listed: $out"; fi
if ! grepq "$out" 'test-clean-cmd\.sh'; then pass "/pr-check_extra is not /pr-check"; else fail "boundary broke on /pr-check_extra: $out"; fi

# --- 4. generic basename (README.md) needs its parent dir --------------------
change docs/foo/README.md
out="$(run_is "$range")"
if [ "$out" = "scripts/test-readme-foo.sh" ]; then pass "README.md matched via foo/README.md, bare README.md mention ignored"; else fail "generic basename: $out"; fi

# --- 5. a changed suite lists itself ----------------------------------------
change scripts/test-other.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-other\.sh$'; then pass "a changed suite is impacted by itself"; else fail "changed suite not listed: $out"; fi
if grepq "$out" '^scripts/test-wrapper\.sh$'; then pass "a suite that invokes the changed suite is impacted too"; else fail "caller of the changed suite not listed: $out"; fi

# --- 6. a deleted file still lists the suites that reference it --------------
git -C "$FX" rm -q scripts/machine-setup/install.sh
git -C "$FX" commit -q -m "chore: drop install.sh"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$(run_is "$range")"
if [ "$out" = "scripts/test-installer.sh" ]; then pass "deleted install.sh still lists test-installer.sh"; else fail "deleted file: $out"; fi

# --- 7. fail-closed on a range that does not resolve ------------------------
out="$( cd "$FX" && bash "$IS" 'nope..alsonope' 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "unresolvable range -> rc2, empty stdout"; else fail "bad range rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" 'HEAD' >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "range without .. -> rc2"; else fail "no-dots range rc=$rc"; fi

# --- 8. --check: RED control for the ticket ----------------------------------
# The #2261 PR: uninstall-plugins.sh touched, test-uninstall.sh never run.
change scripts/machine-setup/uninstall-plugins.sh
( cd "$FX" && printf '' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "RED control: impacted suites with NO verdict -> row NOT clean (rc1)"; else fail "no-verdict fixture PR passed the row: rc=$rc"; fi
err="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 >/dev/null )"
if grepq "$err" 'scripts/test-uninstall\.sh'; then pass "the missing verdict names test-uninstall.sh"; else fail "missing suite not named: $err"; fi

V1='SUITE scripts/test-uninstall.sh = PASS'
V2='SUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host'
( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "PASS + SKIP-with-reason for every impacted suite -> clean (rc0)"; else fail "full verdict set refused: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "SKIP without a reason is not a verdict (rc1)"; else fail "reasonless SKIP accepted: rc=$rc"; fi

err="$( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 3 ] && grepq "$err" 'BLOCKED scripts/lanes/tests/plugins\.test\.mjs'; then pass "BLOCKED-with-denial is accounted for but NOT clean (rc3, names the suite)"; else fail "BLOCKED suite: rc=$rc err=$err"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/lanes/tests/plugins.test.mjs = BLOCKED denied: bun not permitted' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a missing verdict (rc1) still outranks BLOCKED (rc3)"; else fail "missing+blocked ordering: rc=$rc"; fi

( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = MAYBE' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "an unknown verdict word is not a verdict (rc1)"; else fail "unknown verdict accepted: rc=$rc"; fi

( cd "$FX" && printf '%s\n' 'SUITE scripts/test-uninstall.sh = PASS' 'SUITE scripts/test-elsewhere.sh = PASS' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a verdict for a suite that is not impacted does not cover the one that is (rc1)"; else fail "stray verdict covered a missing suite: rc=$rc"; fi

# --- T1.41. --check --record appends one impacted row; without it nothing changes.
REC_LEDGER="$(git -C "$FX" rev-parse --path-format=absolute --git-common-dir)/cr-critic-scores.jsonl"
rec_head="${range##*..}"
git -C "$FX" update-ref refs/remotes/origin/main "${range%%..*}"
rm -rf "$REC_LEDGER"
plain_out="$( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" 2>&1 )"; plain_rc=$?
rec_out="$( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" --record --branch feat/x --head "$rec_head" 2>&1 )"; rec_rc=$?
rows="$(grep -F '"kind":"impacted"' "$REC_LEDGER" 2>/dev/null)"
if [ "$rec_rc" -eq "$plain_rc" ] && [ "$rec_out" = "$plain_out" ]; then pass "T1.41 --record keeps --check's output and rc"; else fail "T1.41 --record changed the output or rc ($plain_rc to $rec_rc): $rec_out"; fi
if [ "$(printf '%s\n' "$rows" | grep -c .)" -eq 1 ] && grepq "$rows" -F '"impacted_n":2' && grepq "$rows" -F '"unverdicted_n":0' \
    && grepq "$rows" -F '"skip_n":1' && grepq "$rows" -F '"rc":0' && grepq "$rows" -F "\"head\":\"$rec_head\"" && grepq "$rows" -F '"branch":"feat/x"'; then
    pass "T1.41 one impacted row with its counts and skip_n"
else
    fail "T1.41 impacted row: $rows"
fi
rm -rf "$REC_LEDGER"
( cd "$FX" && printf '%s\n' "$V1" | bash "$IS" --check "$range" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
rows="$(grep -F '"kind":"impacted"' "$REC_LEDGER" 2>/dev/null)"
if [ "$rc" -eq 1 ] && grepq "$rows" -F '"unverdicted_n":1' && grepq "$rows" -F '"rc":1'; then pass "T1.41 a missing verdict is recorded with rc 1"; else fail "T1.41 missing-verdict row: rc=$rc $rows"; fi
rm -rf "$REC_LEDGER"
( cd "$FX" && printf '' | bash "$IS" --check "$range" >/dev/null 2>&1 )
if [ ! -e "$REC_LEDGER" ]; then pass "T1.41 --check without --record writes no row"; else fail "T1.41 --check without --record wrote the ledger"; fi
mkdir -p "$REC_LEDGER"
( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
rmdir "$REC_LEDGER"
if [ "$rc" -eq 4 ]; then pass "T1.41 a failed append exits 4"; else fail "T1.41 failed append rc=$rc (want 4)"; fi
( cd "$FX" && printf '' | bash "$IS" "$range" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "T1.41 --record without --check refuses (rc2)"; else fail "T1.41 --record without --check rc=$rc"; fi
( cd "$FX" && printf '' | bash "$IS" --check "$range" --record --branch feat/x >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "T1.41 --record without --head refuses (rc2)"; else fail "T1.41 --record without --head rc=$rc"; fi
rm -rf "$REC_LEDGER"
other_head="${range%%..*}"
( cd "$FX" && printf '%s\n%s\n' "$V1" "$V2" | bash "$IS" --check "$range" --record --branch feat/x --head "$other_head" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REC_LEDGER" ]; then pass "T1.41 --record refuses a --head the range does not end at (rc2, no row)"; else fail "T1.41 head mismatch: rc=$rc"; fi
( cd "$FX" && printf '' | bash "$IS" --check "$rec_head..$rec_head" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ] && [ ! -e "$REC_LEDGER" ]; then pass "T1.41 --record refuses a range not from the default branch's merge-base (rc2, no row)"; else fail "T1.41 partial range: rc=$rc"; fi
# T5: the row also lists the PASS paths (local_pass) and the chief-ruled SKIP paths (ruled_skip); both count in skip_n only as SKIPs.
rm -rf "$REC_LEDGER"
( cd "$FX" && printf '%s\n%s\n' "$V1" 'SUITE scripts/lanes/tests/plugins.test.mjs = SKIP ruled HIMMEL-x-roadmap-chief no bun on this host' | bash "$IS" --check "$range" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
rows="$(grep -F '"kind":"impacted"' "$REC_LEDGER" 2>/dev/null)"
if [ "$rc" -eq 0 ] && grepq "$rows" -F '"local_pass":["scripts/test-uninstall.sh"]' && grepq "$rows" -F '"ruled_skip":["scripts/lanes/tests/plugins.test.mjs"]' && grepq "$rows" -F '"skip_n":1'; then
    pass "T5 the row lists local_pass and ruled_skip"
else
    fail "T5 local_pass / ruled_skip: rc=$rc $rows"
fi
# T5d: a ruled SKIP needs a session token naming a chief and a reason; anything else is a bare SKIP
for bare in 'SKIP ruled out by flake' 'SKIP ruled' 'SKIP ruled worker-1 flaky' 'SKIP ruled x-chief'; do
    rm -rf "$REC_LEDGER"
    ( cd "$FX" && printf '%s\n%s\n' "$V1" "SUITE scripts/lanes/tests/plugins.test.mjs = $bare" | bash "$IS" --check "$range" --record --branch feat/x --head "$rec_head" >/dev/null 2>&1 ); rc=$?
    rows="$(grep -F '"kind":"impacted"' "$REC_LEDGER" 2>/dev/null)"
    if [ "$rc" -eq 0 ] && grepq "$rows" -F '"ruled_skip":[]' && grepq "$rows" -F '"skip_n":1'; then
        pass "T5d '$bare' is not a ruled SKIP"
    else
        fail "T5d '$bare': rc=$rc $rows"
    fi
done
rm -rf "$REC_LEDGER"
git -C "$FX" update-ref -d refs/remotes/origin/main

# --- 9. --check with nothing impacted is clean, and says so -----------------
change docs/foo/other.md
out="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "no impacted suites -> rc0 '0 impacted'"; else fail "empty impacted set: rc=$rc out=$out"; fi

# --- 10. a search that fails is an error, never an empty impacted set --------
# A `git` shim that fails only `grep` (fatal, rc 128); every other subcommand
# reaches the real git so the range still resolves and needles are built.
SHIM="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM"' EXIT
printf '#!/usr/bin/env bash\nfor a in "$@"; do if [ "$a" = grep ]; then echo "fatal: injected" >&2; exit 128; fi; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing git grep -> rc2, empty stdout (not an empty impacted set)"; else fail "git grep failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM:$PATH" bash "$IS" "$range" 2>&1 >/dev/null )"
if grepq "$err" 'git grep failed'; then pass "the failed search is named on stderr"; else fail "git grep failure not named: $err"; fi

# --- 11. a root-level generic file has no parent to qualify it ---------------
# package.json / CLAUDE.md at the repo root: the bare name is the only needle.
change package.json
out="$(run_is "$range")"
if [ "$out" = "scripts/test-pkg.sh" ]; then pass "root-level package.json -> suite naming package.json"; else fail "root-level generic file reached nothing: $out"; fi

# --- 11a. an extensionless reference to a changed script -------
# A suite that names a hook by its stem (`guard_rc block-foo-guard`) exercises it
# as surely as one naming `block-foo-guard.sh`. Only a stem holding `-` or `_`
# counts (a one-word stem is a common word), and a longer name or a dotted
# variant that merely starts with the stem is a different word.
change scripts/hooks/block-foo-guard.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-ext\.sh$'; then pass "changed hook -> suite naming it without .sh"; else fail "extensionless stem reference not listed: $out"; fi
if ! grepq "$out" 'test-stem-longer\.sh'; then pass "stem needle does not match a longer name (block-foo-guard-extra)"; else fail "stem matched a longer name: $out"; fi
if ! grepq "$out" 'test-stem-dotted\.sh'; then pass "stem needle does not match block-foo-guard.bak"; else fail "stem matched a dotted variant: $out"; fi
change scripts/lib/my_helper.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-underscore\.sh$'; then pass "underscore stem named without .sh is listed"; else fail "underscore stem not listed: $out"; fi
change scripts/hooks/gate.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-gate-full\.sh$' && ! grepq "$out" 'test-stem-word\.sh'; then pass "one-word stem (gate) is not matched extensionless"; else fail "one-word stem over-listed or control missing: $out"; fi
# The leading boundary and the escaping of
# the stem needle are each pinned by a row that goes RED when that piece is removed.
change scripts/hooks/block-foo-guard.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-ext\.sh$' && ! grepq "$out" 'test-stem-lead\.sh'; then pass "stem needle has a leading boundary: x-block-foo-guard is another word"; else fail "stem matched x-block-foo-guard (no leading boundary) or control missing: $out"; fi
change scripts/hooks/a+b-c.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-stem-plus\.sh$'; then pass "stem with a regex metacharacter (a+b-c) matches its own literal"; else fail "escaped stem a+b-c did not select its own suite: $out"; fi
if ! grepq "$out" 'test-stem-plus-wild\.sh'; then pass "stem a+b-c is a literal, not the pattern a+b-c (aab-c unlisted)"; else fail "stem metacharacter acted as a pattern: $out"; fi
# The closure sourcer is named by its own stem
# in a suite (`guard_rc block-clo-hook`), never with .sh, so it needs its stem needle.
change scripts/lib/clo-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-clo-stem\.sh$'; then pass "a changed lib -> its sourcing hook named by stem only in a suite"; else fail "closure sourcer's stem reference not listed: $out"; fi

# --- 11b. an extensionless basename takes the path rule ---------
# `diff` is a common word: a suite that merely says `diff -u` must not be listed,
# one that names guard-corpus/diff (or the full path) must.
change scripts/eval/guard-corpus/diff
out="$(run_is "$range")"
if ! grepq "$out" 'test-diff-word\.sh'; then pass "extensionless diff: a bare common-word mention is not listed"; else fail "bare 'diff' suite over-listed: $out"; fi
if grepq "$out" '^scripts/test-guard-corpus\.sh$' && grepq "$out" '^scripts/test-diff-fullpath\.sh$'; then pass "extensionless diff: suites naming guard-corpus/diff or the full path stay listed"; else fail "path-naming suite under-listed: $out"; fi
# A distinctive extensionless name (a `-` in it) keeps the bare match: a quoted
# 'claude-fake' has no `/` before it, and dropping it was an under-list (J1939 B1).
change scripts/claude-fake
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-claude-fake\.sh$'; then pass "extensionless distinctive name: a quoted bare reference stays listed"; else fail "claude-fake suite under-listed: $out"; fi
change scripts/eval/guard-corpus/diff
out="$(run_is "$range")"
# A suite-local variable ($HERE/diff) still ends in /diff, so it stays listed.
if grepq "$out" '^scripts/test-diff-var\.sh$'; then pass "extensionless diff: a variable-built \$HERE/diff reference stays listed"; else fail "\$HERE/diff suite under-listed: $out"; fi

# --- 11c. a bare source / . / shellcheck source= of a single-word file ---
# After a `cd`, the operand is the bare name with no `/` before it. Only a line
# that sources it counts: a plain `diff a b` command and prose stay unlisted.
if grepq "$out" '^scripts/test-diff-source\.sh$'; then pass "bare 'source diff' after a cd is listed"; else fail "source diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-dot\.sh$'; then pass "bare '. \"diff\"' after a cd is listed"; else fail ". diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-directive\.sh$'; then pass "'# shellcheck source=diff' is listed"; else fail "shellcheck source=diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-dashdash\.sh$'; then pass "'source -- diff' is listed (HIMMEL-4978)"; else fail "source -- diff suite under-listed: $out"; fi
if grepq "$out" '^scripts/test-diff-helper\.sh$'; then pass "a suite reaching diff through a sourcing helper is listed"; else fail "source-closure bare-name suite under-listed: $out"; fi
if ! grepq "$out" 'test-diff-plain\.sh' && ! grepq "$out" 'test-diff-prose\.sh' && ! grepq "$out" 'test-diff-word\.sh'; then pass "a plain 'diff a b' command and comment prose stay unlisted"; else fail "plain diff over-listed: $out"; fi

# --- 11d. a changed path git would C-quote ---------------------
# `git diff --name-only` quotes a name holding a double quote, backslash or tab,
# so no needle matched and the selector listed nothing and exited 0.
change 'scripts/q/we"ird.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-dquote\.sh$'; then pass "changed path with a double quote selects its suite"; else fail "double-quote path selected nothing: $out"; fi
change 'scripts/q/back\slash.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-backslash\.sh$'; then pass "changed path with a backslash selects its suite"; else fail "backslash path selected nothing: $out"; fi
change $'scripts/q/ta\tb.sh'
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-q-tab\.sh$'; then pass "changed path with a tab selects its suite"; else fail "tab path selected nothing: $out"; fi

# --- 12. the answer does not depend on the cwd it is run from ----------------
# git ls-tree / git grep are cwd-scoped; from a subdirectory the suites one
# level up would silently drop out and --check would pass on a partial set.
change scripts/machine-setup/uninstall-plugins.sh
out="$( cd "$FX/scripts/machine-setup" && bash "$IS" "$range" 2>/dev/null )"
if grepq "$out" '^scripts/test-uninstall\.sh$'; then pass "run from a subdirectory: repo-relative list still reaches test-uninstall.sh"; else fail "subdirectory run dropped suites: $out"; fi

# --- 13. a non-ASCII suite path comes back as itself, not quoted -------------
# git grep -l quotes such a path ("scripts/test-caf\303\251.sh") unless
# core.quotepath is off; the runner would then filter it out as "not a suite".
mkf scripts/uniq-widget.sh
mkf 'scripts/test-café.sh' 'bash "$d/uniq-widget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add widget + café suite"
change scripts/uniq-widget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "scripts/test-café.sh" ]; then pass "non-ASCII suite path is emitted verbatim"; else fail "non-ASCII suite path mangled: $out"; fi

# --- 13b. a SUITE path git grep -l would C-quote ----------------
# A suite file name holding a double quote, backslash or tab came back quoted
# ("scripts/test-q\"x.sh") and the runner filtered it out as "not a suite".
mkf scripts/uniq-quoter.sh
mkf 'scripts/test-qg"x.sh' 'bash "$d/uniq-quoter.sh"'
mkf 'scripts/test-qg\y.sh' 'bash "$d/uniq-quoter.sh"'
mkf $'scripts/test-qg\tz.sh' 'bash "$d/uniq-quoter.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add quoter + quoted suites"
change scripts/uniq-quoter.sh
out="$(run_is "$range" --shell)"
want=$'scripts/test-qg\tz.sh\nscripts/test-qg"x.sh\nscripts/test-qg\\y.sh'
if [ "$(printf '%s\n' "$out" | LC_ALL=C sort)" = "$(printf '%s\n' "$want" | LC_ALL=C sort)" ]; then pass "suite paths with a double quote, backslash and tab are emitted verbatim"; else fail "quoted suite paths mangled: $out"; fi

# --- 14. a step that builds the list and fails is an error, not a short list --
# A `sort` shim that fails: the shell-only filter used to end in `|| true`, so
# an empty impacted set (rc 0) was the result of a pipeline that never ran.
SHIM2="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2"' EXIT
printf '#!/usr/bin/env bash\necho "sort: injected" >&2\nexit 2\n' > "$SHIM2/sort"
chmod +x "$SHIM2/sort"
out="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && [ -z "$out" ]; then pass "a failing sort -> rc2, empty stdout (not an empty impacted set)"; else fail "sort failure: rc=$rc out=$out"; fi
err="$( cd "$FX" && PATH="$SHIM2:$PATH" bash "$IS" "$range" --shell 2>&1 >/dev/null )"
if grepq "$err" 'sorting the impacted list failed'; then pass "the failed step is named on stderr"; else fail "sort failure not named: $err"; fi

# --- 15. a suite path containing spaces can receive a verdict --
# The verdict path is everything between "SUITE " and the FIRST " = ", so a
# spaced path is accepted; a " = " inside the reason must not move the split.
mkf scripts/uniq-gadget.sh
mkf 'scripts/test-with space.sh' 'bash "$d/uniq-gadget.sh"'
mkf 'scripts/test-a=b.sh' 'bash "$d/uniq-gadget.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add gadget + spaced suites"
change scripts/uniq-gadget.sh
out="$(run_is "$range" --shell)"
if [ "$out" = "$(printf 'scripts/test-a=b.sh\nscripts/test-with space.sh')" ]; then pass "spaced suite paths are listed verbatim"; else fail "spaced suite paths not listed: $out"; fi
SP1='SUITE scripts/test-with space.sh = PASS'
SP2='SUITE scripts/test-a=b.sh = SKIP no gadget = here'
( cd "$FX" && printf '%s\n%s\n' "$SP1" "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 0 ]; then pass "verdicts for spaced/'='-bearing suite paths -> clean (rc0)"; else fail "spaced-path verdicts refused: rc=$rc"; fi
( cd "$FX" && printf '%s\n' "$SP2" | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a spaced suite without its own verdict stays missing (rc1)"; else fail "missing spaced verdict passed: rc=$rc"; fi
( cd "$FX" && printf '%s\n%s\n' "$SP1" 'SUITE scripts/test-a=b.sh = SKIP' | bash "$IS" --check "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 1 ]; then pass "a reasonless SKIP on a spaced-path row is still no verdict (rc1)"; else fail "reasonless SKIP accepted on spaced path: rc=$rc"; fi

# --- 16. --runner-check: direct vitest steps + runner drift ---
# Fixture workflow files in a scratch dir under $FX, never the real
# .github/workflows (case (c) below reads the real one as a control).
mkdir -p "$FX/.github/workflows"
run_rc() { ( cd "$FX" && bash "$IS" --runner-check 2>&1 ); }

# (a) a direct `npx vitest run` step for an unmapped directory is invisible
# to the old grep (it only looked for node --test/bun test/npm test/
# check-hook-lib-suites.sh) and passed silently; it must now fail, naming it.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  new-suite:
    runs-on: ubuntu-latest
    steps:
      - run: npx vitest run scripts/newthing/foo.test.ts
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'newthing'; then pass "unmapped direct vitest step fails --runner-check, naming it"; else fail "unmapped vitest step: rc=$rc out=$out"; fi

# (b) a mapped suite whose invocation drifted from node --test to bun test:
# the old marker matched by path substring alone (still present after the
# swap), so drift went undetected. --runner still emits `node --test` for
# this path.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  lanes-and-trust-suites:
    runs-on: ubuntu-latest
    steps:
      - run: bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'lanes'; then pass "runner drift (node --test -> bun test) fails --runner-check, naming the suite"; else fail "runner drift: rc=$rc out=$out"; fi

# Wrapped Bun invocations must be checked, including unknown paths and drift.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  wrapped:
    steps:
      - run: bash scripts/ci/run-bun-tests.sh scripts/newthing scripts/newthing/foo.test.ts
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'newthing'; then pass "unmapped wrapped Bun step fails runner-check"; else fail "unmapped wrapped Bun step: rc=$rc out=$out"; fi
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  wrapped:
    steps:
      - run: bash scripts/ci/run-bun-tests.sh scripts/lanes "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'runner drift'; then pass "wrapped Bun cannot evade node runner drift guard"; else fail "wrapped Bun drift: rc=$rc out=$out"; fi
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  wrapped:
    steps:
      - run: bash scripts/ci/run-bun-tests.sh scripts/telegram scripts/telegram --dots
      - run: bun test scripts/telegram --dots
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "known wrapped and inline Bun invocations both pass"; else fail "known Bun invocation: rc=$rc out=$out"; fi
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  wrapped:
    steps:
      - run: node --test "scripts/lanes/tests/**/*.test.mjs" && bash scripts/ci/run-bun-tests.sh scripts/telegram scripts/telegram --dots
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'ambiguous'; then pass "wrapped Bun plus node fails closed as ambiguous"; else fail "wrapped Bun ambiguity: rc=$rc out=$out"; fi

# (c) control: today's real .github/workflows/ci.yml still passes.
out="$( cd "$REPO_ROOT" && bash "$IS" --runner-check 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "control: today's real ci.yml still passes --runner-check"; else fail "real ci.yml regressed: rc=$rc out=$out"; fi

# (d) an ambiguous line — two runner families on one `run:` line — cannot be
# attributed to a single runner; fail closed and name it, never guess.
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  weird:
    runs-on: ubuntu-latest
    steps:
      - run: node --test "scripts/lanes/tests/**/*.test.mjs" && bun test "scripts/lanes/tests/**/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'ambiguous'; then pass "a line naming two runner families fails closed as ambiguous"; else fail "ambiguous line: rc=$rc out=$out"; fi

# --- 16b. CI guards per-directory test presence and globs the
# observability node tests. The guard prefixes are extracted from the REAL
# ci.yml and executed in a scratch tree, so the row tracks the live step text.
CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
bun_guard="$(sed -nE 's/^[ -]*run:(.*) && bash scripts\/ci\/run-bun-tests\.sh scripts\/observability .*/\1/p' "$CI_YML")"
node_guard="$(sed -n 's/^[ -]*run:\(.*\) && \(bash "\$GITHUB_WORKSPACE\/scripts\/ci\/live-witness\.sh" run --label [^ ]* -- \)\{0,1\}node --test .*scripts\/observability\/\*\.test\.mjs.*/\1/p' "$CI_YML")"
if [ -n "$bun_guard" ]; then pass "bun step's presence guard extracted from real ci.yml"; else fail "bun step guard not found in ci.yml"; fi
if [ -n "$node_guard" ]; then pass "node step globs scripts/observability/*.test.mjs in real ci.yml"; else fail "node step does not glob scripts/observability/*.test.mjs"; fi
GT="$FX/guard-tree"
guard_rc() { ( cd "$GT" && bash -c "$1" >/dev/null 2>&1 ); }
rm -rf "$GT"; mkdir -p "$GT/scripts/observability"
: > "$GT/scripts/observability/.gitkeep"
guard_rc "$bun_guard"; rc=$?
if [ "$rc" -ne 0 ]; then pass "bun guard fails when observability has no test files"; else fail "bun guard passed with an empty observability dir"; fi
: > "$GT/scripts/observability/a.test.ts"
guard_rc "$bun_guard"; rc=$?
if [ "$rc" -eq 0 ]; then pass "bun guard passes when observability has tests"; else fail "bun guard failed with observability populated: rc=$rc"; fi
rm -f "$GT"/scripts/observability/*.test.*
: > "$GT/scripts/op-env-parity.test.mjs"
guard_rc "$node_guard"; rc=$?
if [ "$rc" -ne 0 ]; then pass "node guard fails when no observability .test.mjs exists"; else fail "node guard passed with no observability .test.mjs"; fi
: > "$GT/scripts/observability/new-thing.test.mjs"
guard_rc "$node_guard"; rc=$?
if [ "$rc" -eq 0 ]; then pass "node guard passes with a new observability .test.mjs"; else fail "node guard failed with a new .test.mjs: rc=$rc"; fi
# the glob step must also be a known --runner-check marker (kind node-test).
cat > "$FX/.github/workflows/ci.yml" <<'YAML'
name: ci
on: push
jobs:
  obs:
    runs-on: ubuntu-latest
    steps:
      - run: ls scripts/observability/*.test.mjs && node --test "scripts/observability/*.test.mjs"
YAML
out="$(run_rc)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "observability node glob step is a known --runner-check marker"; else fail "glob step unmapped: rc=$rc out=$out"; fi
out="$(bash "$IS" --runner scripts/observability/new-thing.test.mjs 2>&1)"
if grepq "$out" 'node --test'; then pass "--runner maps a new observability .test.mjs to node --test"; else fail "--runner observability mjs: $out"; fi

# --- 17. --run: a fresh worktree's missing npm deps install before the
# suite runs (worktrees are created with --no-install, so a worker
# running an impacted suite raw sees a false SKIP/FAIL it mislabels
# "pre-existing" — N441/N440/N446 in one shift). -----------------------------
mkdir -p "$FX/pkg-npm"
cat > "$FX/pkg-npm/package.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-npm/package-lock.json" <<'JSON'
{
  "name": "fixture-npm",
  "version": "1.0.0",
  "lockfileVersion": 3,
  "requires": true,
  "packages": {
    "": { "name": "fixture-npm", "version": "1.0.0", "dependencies": { "picocolors": "1.1.1" } },
    "node_modules/picocolors": {
      "version": "1.1.1",
      "resolved": "https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz",
      "integrity": "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==",
      "license": "ISC"
    }
  }
}
JSON
cat > "$FX/pkg-npm/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok'));
JS
cat > "$FX/pkg-npm/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
node "$dir/script.mjs"
SH
chmod +x "$FX/pkg-npm/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add npm fixture package"

# RED control: today (no --run), the suite run raw with no node_modules
# fails MODULE_NOT_FOUND — the base bug, not something --check can rescue.
if (cd "$FX" && bash pkg-npm/test-uses-dep.sh >/dev/null 2>&1); then
    fail "RED control: raw suite should fail without node_modules installed"
else
    pass "RED control: raw suite fails without node_modules (base bug reproduced)"
fi
if [ ! -d "$FX/pkg-npm/node_modules" ]; then pass "RED control: node_modules absent before --run"; else fail "node_modules unexpectedly present before --run"; fi

out="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok$'; then pass "--run installs missing npm deps then runs the suite (GREEN)"; else fail "--run npm install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-npm/node_modules/picocolors" ]; then pass "--run left node_modules installed from the lockfile"; else fail "--run did not install node_modules"; fi
if grepq "$out" 'installing deps for pkg-npm'; then pass "--run names the package dir it is installing"; else fail "--run install message missing: $out"; fi

# idempotent second run: node_modules already present -> no reinstall.
out2="$( cd "$FX" && bash "$IS" --run pkg-npm/test-uses-dep.sh 2>&1 )"; rc2=$?
if [ "$rc2" -eq 0 ] && ! grepq "$out2" 'installing deps'; then pass "--run is idempotent: no reinstall once node_modules exists"; else fail "--run second run: rc=$rc2 out=$out2"; fi

# --- 18. --run: a bun.lock package installs via bun, --ignore-scripts ------
mkdir -p "$FX/pkg-bun"
cat > "$FX/pkg-bun/package.json" <<'JSON'
{
  "name": "fixture-bun",
  "version": "1.0.0",
  "dependencies": { "picocolors": "1.1.1" }
}
JSON
cat > "$FX/pkg-bun/bun.lock" <<'LOCK'
{
  "lockfileVersion": 2,
  "configVersion": 1,
  "workspaces": {
    "": {
      "name": "fixture-bun",
      "dependencies": {
        "picocolors": "1.1.1",
      },
    },
  },
  "packages": {
    "picocolors": ["picocolors@1.1.1", "", {}, "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA=="],
  }
}
LOCK
cat > "$FX/pkg-bun/script.mjs" <<'JS'
import pc from 'picocolors';
console.log(pc.red('ok-bun'));
JS
cat > "$FX/pkg-bun/test-uses-dep.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dir="$(cd "$(dirname "$0")" && pwd)"
bun "$dir/script.mjs"
SH
chmod +x "$FX/pkg-bun/test-uses-dep.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add bun fixture package"

out="$( cd "$FX" && bash "$IS" --run pkg-bun/test-uses-dep.sh 2>&1 )"; rc=$?
out_plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
if [ "$rc" -eq 0 ] && grepq "$out_plain" '^ok-bun$'; then pass "--run installs a bun.lock package via bun then runs the suite"; else fail "--run bun install+run: rc=$rc out=$out"; fi
if [ -d "$FX/pkg-bun/node_modules/picocolors" ]; then pass "--run left node_modules installed from bun.lock"; else fail "--run did not install bun node_modules"; fi
if grepq "$out" 'bun install --frozen-lockfile --ignore-scripts'; then pass "--run picks the frozen, script-ignoring bun install command"; else fail "--run bun install command not named: $out"; fi

# --- 19. --run: a missing lockfile is a hard FAIL naming the package dir and
# the suite never runs — never a SKIP, never a bare FAIL. ------
mkdir -p "$FX/pkg-nolock"
cat > "$FX/pkg-nolock/package.json" <<'JSON'
{ "name": "fixture-nolock", "version": "1.0.0", "dependencies": { "left-pad": "1.0.0" } }
JSON
cat > "$FX/pkg-nolock/test-nolock.sh" <<'SH'
#!/usr/bin/env bash
echo should-not-run
SH
chmod +x "$FX/pkg-nolock/test-nolock.sh"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add nolock fixture package"
out="$( cd "$FX" && bash "$IS" --run pkg-nolock/test-nolock.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$out" 'no lockfile' && grepq "$out" 'pkg-nolock'; then pass "--run: missing lockfile is a hard FAIL naming the package dir (rc2), never a SKIP"; else fail "--run missing-lockfile: rc=$rc out=$out"; fi
if ! grepq "$out" 'should-not-run'; then pass "--run: the suite itself never ran after a failed install"; else fail "suite ran despite a missing lockfile: $out"; fi

# --- 20. --run: a suite with no package.json ancestor runs unchanged -------
# (fixture step 9 left a root-level package.json in $FX for a naming test;
# drop it here so this suite genuinely has no package.json ancestor.)
rm -f "$FX/package.json"
mkf scripts/test-no-deps.sh 'echo unaffected'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: add no-deps suite, drop root package.json"
out="$( cd "$FX" && bash "$IS" --run scripts/test-no-deps.sh 2>&1 )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" 'unaffected'; then pass "--run: a suite with no package.json ancestor runs unchanged"; else fail "--run no-deps suite: rc=$rc out=$out"; fi

# --- 21. --check --from-file reads verdict lines from a
# path instead of stdin. -------------------------------------------------
change scripts/machine-setup/uninstall-plugins.sh
FF="$FX/from-file-21.txt"
printf 'SUITE scripts/test-uninstall.sh = PASS\nSUITE scripts/lanes/tests/plugins.test.mjs = SKIP no node on this host\n' > "$FF"
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FF" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 0 ]; then pass "--check --from-file with the impacted suite's verdict -> clean (rc0)"; else fail "--from-file full verdict set refused: rc=$rc err=$err"; fi

# --- 22. --from-file without --check refuses (rc2). -------------------------
( cd "$FX" && bash "$IS" "$range" --from-file "$FF" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--from-file without --check refuses (rc2)"; else fail "--from-file sans --check: rc=$rc"; fi

# --- 23. --from-file naming a missing path refuses (rc2), fails closed. -----
err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/nope-23.txt" 2>&1 >/dev/null )"; rc=$?
if [ "$rc" -eq 2 ] && grepq "$err" 'does not exist'; then pass "--from-file missing path -> rc2, names the reason"; else fail "--from-file missing path: rc=$rc err=$err"; fi

# --- 24. --from-file naming a symlink refuses (rc2) without reading through
# it. `ln -s` silently falls back to a plain copy without admin/Developer-Mode
# privilege on Windows — skip the assertion there (same probe idiom as T4e in
# test-write-verdicts.sh). --------------------------------------------------
printf 'SUITE scripts/test-uninstall.sh = PASS\n' > "$FX/real-24.txt"
ln -s "$FX/real-24.txt" "$FX/link-24.txt" 2>/dev/null
if [ -L "$FX/link-24.txt" ]; then
    err="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/link-24.txt" 2>&1 >/dev/null )"; rc=$?
    if [ "$rc" -eq 2 ] && grepq "$err" 'symlink'; then pass "--from-file symlinked path -> rc2, names the reason"; else fail "--from-file symlink: rc=$rc err=$err"; fi
else
    echo "SKIP 24: platform cannot create symlinks without elevated privilege"
fi

# --- 25. --from-file naming a genuinely empty regular
# file is ALLOWED (same "no candidates" semantics as empty stdin, test 9) —
# but --check's own n_impacted/n_missing reconciliation, computed independently
# from the diff rather than from this file, still catches it as a missing
# verdict (rc1) when the impacted set from `change scripts/machine-setup/
# uninstall-plugins.sh` (test 21) is non-empty: this is the downstream catch
# for a wrongly-empty --from-file when real candidates exist. -----------------
: > "$FX/empty-25.txt"
out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" 'without a verdict'; then pass "--from-file empty path with a non-empty impacted set -> rc1, names the gap"; else fail "--from-file empty path against impacted suites: rc=$rc out=$out"; fi

# --- 26. --from-file naming a genuinely empty file against a genuinely empty
# impacted set is clean (rc0) — the case the runbook's own zero-candidate
# instruction relies on. ------------------------------------------------------
mkdir -p "$FX/docs/bar"
if change docs/bar/other-26.md; then
    out="$( cd "$FX" && bash "$IS" --check "$range" --from-file "$FX/empty-25.txt" 2>&1 )"; rc=$?
    if [ "$rc" -eq 0 ] && grepq "$out" '0 impacted'; then pass "--from-file empty path with an empty impacted set -> rc0 '0 impacted'"; else fail "--from-file empty path against no impacted suites: rc=$rc out=$out"; fi
else
    fail "fixture setup failed for section 26 (docs/bar/other-26.md)"
fi

# --- 27. Source closure. A suite that names only mid.sh must be
# listed when far.sh (two source hops behind mid.sh) changes. -----------------
mkf scripts/lib/far.sh
mkf scripts/lib/deep.sh '. "$here/far.sh"'
mkf scripts/lib/mid.sh 'source "$here/deep.sh"'
mkf scripts/test-top.sh 'bash "$d/lib/mid.sh"'
mkf scripts/lib/noise.sh 'echo "see far.sh and deep.sh"'
mkf scripts/test-noise.sh 'bash "$d/lib/noise.sh"'
mkf scripts/lib/cyc-a.sh '. "$here/cyc-b.sh"'
mkf scripts/lib/cyc-b.sh '. "$here/cyc-a.sh"'
mkf scripts/test-cyc.sh 'bash "$d/lib/cyc-a.sh"'
gv_a=HIMMEL_UNINSTALL_   # name split across two variables so this file never matches the callers scan itself
gv_b=REAL_HOME
mkf scripts/guard-setter.sh "${gv_a}${gv_b}=1 bash x"
mkf scripts/guard-plain.sh 'echo nothing'
mkf scripts/test-uninstall-real-home-callers.sh 'grep -r "$V" scripts'
mkf scripts/lib/sp-a.sh
mkf scripts/lib/sp-b.sh 'source sp-a.sh'
mkf scripts/lib/sp-c.sh '. sp-b.sh'
mkf scripts/test-sp.sh 'bash "$d/lib/sp-c.sh"'
mkf scripts/lib/vs-lib.sh
mkf scripts/vs-user.sh $'_VS_LIB="$d/lib/vs-lib.sh"\nfor _l in "$_VS_LIB"; do\n  . "$_l"\ndone'
mkf scripts/test-vs.sh 'bash "$d/vs-user.sh"'
mkf scripts/lib/dr-lib.sh
mkf scripts/dr-user.sh $'# shellcheck source=lib/dr-lib.sh\n. "$(pick_lib)"'
mkf scripts/test-dr.sh 'bash "$d/dr-user.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: closure fixtures"
change scripts/lib/far.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-top\.sh$'; then pass "far.sh (2 source hops behind mid.sh) -> test-top.sh"; else fail "closure miss: $out"; fi
if ! grepq "$out" 'test-noise\.sh'; then pass "a non-source mention of far.sh/deep.sh does not widen"; else fail "non-source line widened the closure: $out"; fi
change scripts/lib/cyc-b.sh
change scripts/lib/sp-a.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-sp\.sh$'; then pass "single-space 'source x' / '. x' forms are followed (2 hops)"; else fail "single-space source form missed: $out"; fi
change scripts/lib/vs-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-vs\.sh$'; then pass "variable sourcing (_LIB=...; . \"\$_l\") is followed (backfill-sessions idiom)"; else fail "variable-sourcing miss: $out"; fi
change scripts/lib/dr-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-dr\.sh$'; then pass "a '# shellcheck source=<path>' directive is followed"; else fail "shellcheck-directive miss: $out"; fi
change scripts/lib/cyc-b.sh
# gnu-ok: timeout is guarded by command -v and falls back to an unbounded run
if command -v timeout >/dev/null 2>&1; then out="$( cd "$FX" && timeout 20 bash "$IS" "$range" 2>/dev/null )"; rc=$?; else out="$(run_is "$range")"; rc=0; fi
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-cyc\.sh$'; then pass "source cycle terminates and still lists test-cyc.sh"; else fail "cycle rc=$rc out=$out"; fi

# --- 28. A file that sets the fence-lifting variable pulls in the
# path-scanning callers suite, which never names it. -------------------------
change scripts/guard-setter.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-uninstall-real-home-callers\.sh$'; then pass "fence-lifting setter -> callers scan listed"; else fail "3868 miss: $out"; fi
change scripts/guard-plain.sh
out="$(run_is "$range")"
if ! grepq "$out" 'real-home-callers'; then pass "a file without the variable does not pull the callers scan"; else fail "callers scan over-selected: $out"; fi

# --- 28b. A file spelling a ~/.himmel ledger path pulls in the
# ledger registry lint, which scans every script and names none of them. ------
lg_dir=.himmel   # split so this file never spells a ledger path itself
mkf scripts/observability/test-ledgers-registry.sh 'git ls-files scripts'
mkf scripts/new-jsonl-writer.sh "echo x"
mkf scripts/new-log-writer.sh "echo x"
mkf scripts/no-ledger.sh 'echo nothing'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: ledger fixtures"
printf '%s\n' "out=\"\$HOME/${lg_dir}/failure-routes.jsonl\"" >> "$FX/scripts/new-jsonl-writer.sh"
change scripts/new-jsonl-writer.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/observability/test-ledgers-registry\.sh$'; then pass "added .jsonl ledger literal -> ledger registry lint listed"; else fail "4789 jsonl miss: $out"; fi
printf '%s\n' "log=~/${lg_dir}/sub/run.log" >> "$FX/scripts/new-log-writer.sh"
change scripts/new-log-writer.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/observability/test-ledgers-registry\.sh$'; then pass "added .log ledger literal -> ledger registry lint listed"; else fail "4789 log miss: $out"; fi
change scripts/no-ledger.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-ledgers-registry'; then pass "a file without a ledger literal does not pull the registry lint"; else fail "registry lint over-selected: $out"; fi

# --- 29. selector-miss: a red suite the PR's selection skipped is recorded. --
change scripts/lib/far.sh
printf 'scripts/test-other.sh\nscripts/test-top.sh\n' > "$FX/red-29.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" '^selector-miss: scripts/test-other\.sh scripts/lib/far\.sh$' && ! grepq "$out" 'test-top'; then pass "selector-miss row for the skipped red suite only (rc1)"; else fail "selector-miss rc=$rc out=$out"; fi
printf 'scripts/test-top.sh\n' > "$FX/red-29b.txt"
out="$( cd "$FX" && bash "$IS" --selector-miss "$range" --red-file "$FX/red-29b.txt" 2>/dev/null )"; rc=$?
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then pass "every red suite was selected -> no rows (rc0)"; else fail "selector-miss clean case rc=$rc out=$out"; fi
( cd "$FX" && bash "$IS" --selector-miss "$range" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "--selector-miss without --red-file -> rc2"; else fail "selector-miss usage rc=$rc"; fi

# --- 30. The word "source" in a full-line COMMENT is prose, not a
# source edge. A comment naming the changed helper must not join the closure
# (usage-preflight.sh:1084 "# Same source and spelling as tick.sh's ..." pulled
# ~136 suites in for a tracker.py change); a real source line, however it is
# indented or chained, still must. ------------------------------------------
mkf scripts/lib/cm-lib.sh
mkf scripts/lib/cm-prose.sh $'# Same source and spelling as cm-lib.sh\'s field\n  # source cm-lib.sh is the real one\necho prose'
mkf scripts/test-cm-prose.sh 'bash "$d/lib/cm-prose.sh"'
mkf scripts/lib/cm-asg.sh $'_CM="$d/cm-lib.sh"\n# the source $_CM line lives elsewhere\necho asg'
mkf scripts/test-cm-asg.sh 'bash "$d/lib/cm-asg.sh"'
mkf scripts/lib/cm-real.sh $'if x; then\n    source "$here/cm-lib.sh"   # trailing comment\nfi'
mkf scripts/test-cm-real.sh 'bash "$d/lib/cm-real.sh"'
mkf scripts/lib/cm-chain.sh 'true; . cm-lib.sh'
mkf scripts/test-cm-chain.sh 'bash "$d/lib/cm-chain.sh"'
mkf scripts/lib/cm-var.sh $'_CM="$d/cm-lib.sh"\n    . "$_CM"'
mkf scripts/test-cm-var.sh 'bash "$d/lib/cm-var.sh"'
mkf scripts/lib/cm-sub.sh $'(source cm-lib.sh)\n(. "$_CM")'
mkf scripts/test-cm-sub.sh 'bash "$d/lib/cm-sub.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: comment-prose closure fixtures"
change scripts/lib/cm-lib.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-cm-prose\.sh'; then pass "a comment that says 'source ... cm-lib.sh' does not widen"; else fail "comment prose widened the closure: $out"; fi
if ! grepq "$out" 'test-cm-asg\.sh'; then pass "a comment 'source \$var' does not make an assigning file a variable sourcer"; else fail "comment var-source widened the closure: $out"; fi
if grepq "$out" '^scripts/test-cm-real\.sh$'; then pass "an indented real source line with a trailing comment is still followed"; else fail "indented source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-chain\.sh$'; then pass "a chained '; . x' source is still followed"; else fail "chained source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-var\.sh$'; then pass "an indented variable-sourcing file is still followed"; else fail "indented var-source missed: $out"; fi
if grepq "$out" '^scripts/test-cm-sub\.sh$'; then pass "a subshell '(source x)' is still followed"; else fail "subshell source missed: $out"; fi

# --- 30b. A suite that names the changed file only on a whole-line comment
# ('#' in a shell suite, '//' in a JS/TS suite) drops off the proof lists
# (--plan, --check). A '#' line inside a string or a here-document body, a
# trailing comment after code, a `# shellcheck source=` directive and a
# `# selector: names` line still list. The plain and --shell listings, the one
# CI selects from, stay as wide as before. ---
mkf scripts/lib/cmo-lib.sh
mkf scripts/test-cmo-hash.sh $'#!/usr/bin/env bash\n# drives cmo-lib.sh end to end\necho x'
mkf scripts/test-cmo-indent.sh $'if true; then\n    # see scripts/lib/cmo-lib.sh\n    :\nfi'
mkf scripts/test-cmo-stemcmt.sh $'# guard_rc cmo-lib "x"\necho x'
mkf scripts/test-cmo-after-hd.sh $'cat <<EOF > f\nx\nEOF\n# cmo-lib.sh\necho "it\'s"'
mkf scripts/test-cmo-after-str.sh $'s=\'\nline\n\'\n# cmo-lib.sh'
mkf scripts/lib/cmo.test.mjs $'// drives cmo-lib.sh\nconsole.log(1);'
mkf scripts/lib/cmo-indent.test.ts $'function f() {\n    // cmo-lib.sh\n}'
mkf scripts/test-cmo-exec.sh 'bash "$d/lib/cmo-lib.sh"'
mkf scripts/test-cmo-source.sh '. "$d/lib/cmo-lib.sh"'
mkf scripts/test-cmo-arg.sh 'run_gate --lib "$d/lib/cmo-lib.sh"'
mkf scripts/test-cmo-cmdpos.sh 'cmo-lib.sh --help'
mkf scripts/test-cmo-stem.sh 'guard_rc cmo-lib "x"'
mkf scripts/test-cmo-string.sh 'msg="see cmo-lib.sh"'
mkf scripts/test-cmo-sqmulti.sh $'s=\'\n# cmo-lib.sh\n\''
mkf scripts/test-cmo-dqmulti.sh $'s="a\n  # cmo-lib.sh\n"'
mkf scripts/test-cmo-heredoc.sh $'cat <<\'EOF\' > f\n# cmo-lib.sh\nEOF'
mkf scripts/test-cmo-heredoc-dash.sh $'\tcat <<-END > f\n\t# cmo-lib.sh\n\tEND'
mkf scripts/test-cmo-trail.sh 'true # cmo-lib.sh'
mkf scripts/test-cmo-expand.sh $'p=${q#*/} # x\n${#a} cmo-lib.sh'
mkf scripts/test-cmo-directive.sh $'# shellcheck source=scripts/lib/cmo-lib.sh\n. "$d/lib/$n"'
mkf scripts/test-cmo-names.sh $'# selector: names cmo-lib.sh other.sh\necho x'
mkf scripts/lib/cmo-exec.test.mjs "execFileSync('bash', ['cmo-lib.sh']);"
mkf scripts/lib/cmo-tpl.test.mjs $'const s = `\n// cmo-lib.sh\n`;'
mkf scripts/lib/cmo-trail.test.js 'run(); // cmo-lib.sh'
mkf scripts/lib/cmo-names.test.mjs $'// selector: names cmo-lib.sh\ntest();'
mkf scripts/lib/cmo-cont.test.mjs $'const s = \'a\\\n// cmo-lib.sh\';'
mkf scripts/lib/cmo-after-cont.test.mjs $'const s = \'a\\\nb\';\n// cmo-lib.sh'
mkf scripts/lib/cmo-nested.test.mjs $'const s = `${c ? `a` : `b`}\n// cmo-lib.sh\n`;'
mkf scripts/lib/cmo-return.test.mjs $'function f(x) { return /`/.test(x); }\n// cmo-lib.sh'
mkf scripts/test-cmo-shcont.sh $'x=a\\\n#cmo-lib.sh'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: comment-only mention fixtures"
change scripts/lib/cmo-lib.sh
plan_out="$( cd "$FX" && HIMMEL_SUITES_LOCAL=1 bash "$IS" --plan "$range" 2>&1 )"
out="$(awk '$1 == "LOCAL" { print $2 }' <<< "$plan_out")"
cmo_cmt="test-cmo-hash.sh test-cmo-indent.sh test-cmo-stemcmt.sh test-cmo-after-hd.sh test-cmo-after-str.sh lib/cmo.test.mjs lib/cmo-indent.test.ts lib/cmo-after-cont.test.mjs lib/cmo-return.test.mjs"
for s in $cmo_cmt; do
    if ! grepq "$out" -Fx "scripts/$s"; then pass "30b --plan: a whole-line comment mention does not list scripts/$s"; else fail "30b --plan listed comment-only scripts/$s: $out"; fi
done
for s in test-cmo-exec.sh test-cmo-source.sh test-cmo-arg.sh test-cmo-cmdpos.sh test-cmo-stem.sh test-cmo-string.sh test-cmo-sqmulti.sh test-cmo-dqmulti.sh test-cmo-heredoc.sh test-cmo-heredoc-dash.sh test-cmo-trail.sh test-cmo-expand.sh test-cmo-directive.sh test-cmo-names.sh lib/cmo-exec.test.mjs lib/cmo-tpl.test.mjs lib/cmo-trail.test.js lib/cmo-names.test.mjs lib/cmo-cont.test.mjs lib/cmo-nested.test.mjs test-cmo-shcont.sh; do
    if grepq "$out" -Fx "scripts/$s"; then pass "30b --plan CONTROL scripts/$s is still listed"; else fail "30b --plan CONTROL scripts/$s dropped: $out"; fi
done
if grepq "$plan_out" -Fx 'impacted-suites: dropped-comment-only=9'; then pass "30b --plan prints the narrowing: dropped-comment-only=9"; else fail "30b --plan dropped-comment-only line missing or wrong: $plan_out"; fi
err="$( cd "$FX" && printf '' | bash "$IS" --check "$range" 2>&1 >/dev/null )"
if grepq "$err" -F 'scripts/test-cmo-exec.sh' && ! grepq "$err" -F 'scripts/test-cmo-hash.sh' && grepq "$err" -Fx 'impacted-suites: dropped-comment-only=9'; then pass "30b --check owes no verdict for a comment-only suite and owes one for a control"; else fail "30b --check verdict set: $err"; fi
out="$(run_is "$range")"
err="$( cd "$FX" && bash "$IS" "$range" 2>&1 >/dev/null )"
all_listed=1
for s in $cmo_cmt; do grepq "$out" -Fx "scripts/$s" || all_listed=0; done
if [ "$all_listed" -eq 1 ] && [ -z "$err" ]; then pass "30b the plain listing still names every comment-only suite and prints nothing to stderr"; else fail "30b plain listing narrowed: err=$err out=$out"; fi
out="$(run_is "$range" --shell)"
if grepq "$out" -Fx 'scripts/test-cmo-hash.sh' && grepq "$out" -Fx 'scripts/test-cmo-after-hd.sh' && ! grepq "$out" -F '.test.'; then pass "30b --shell (what CI selects from) still lists a comment-only suite --check drops"; else fail "30b --shell narrowed: $out"; fi
# The same proof list when a content-rewriting .gitattributes sends every candidate
# down the per-file path, which reads each blob from git under its own name.
printf 'x.none filter=none\n' > "$FX/.gitattributes"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: an attribute that rewrites content"
printf '# changed\n' >> "$FX/scripts/lib/cmo-lib.sh"
git -C "$FX" commit -q -am "fix: change cmo-lib.sh under the attribute"
arange="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$( cd "$FX" && HIMMEL_SUITES_LOCAL=1 bash "$IS" --plan "$arange" 2>/dev/null | awk '$1 == "LOCAL" { print $2 }' )"
if ! grepq "$out" -Fx 'scripts/test-cmo-hash.sh' && ! grepq "$out" -Fx 'scripts/lib/cmo.test.mjs' && grepq "$out" -Fx 'scripts/test-cmo-heredoc.sh' && grepq "$out" -Fx 'scripts/lib/cmo-tpl.test.mjs'; then pass "30b the per-file path (.gitattributes filter) drops the same comment-only suites"; else fail "30b per-file path proof list: $out"; fi
git -C "$FX" rm -q .gitattributes
git -C "$FX" commit -q -m "chore: drop the attribute"

# --- 30c. The suites that widen their own text name each basename on a
# `# selector: names` line, so an edit to one still puts them on the --plan
# proof list, which reads no other comment line (the real suite text, copied). ---
mkdir -p "$FX/scripts/docs" "$FX/scripts/hooks/lib" "$FX/scripts/handover/chief-kit"
for s in scripts/docs/test-dev-graph.sh scripts/hooks/test-escape-class-corpus.sh scripts/docs/test-workflow-page-drift.sh scripts/docs/test-how-a-change-ships.sh; do
    cp "$REPO_ROOT/$s" "$FX/$s"
done
mkf scripts/handover/chief-kit/grant-round.sh
mkf scripts/hooks/lib/headless-spawn-join.sh
mkf docs/plan-charter.md
mkf scripts/handover/chief-kit/relay-batch.sh
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: real widening suites"
for pair in scripts/handover/chief-kit/grant-round.sh:scripts/docs/test-dev-graph.sh \
            scripts/hooks/lib/headless-spawn-join.sh:scripts/hooks/test-escape-class-corpus.sh \
            docs/plan-charter.md:scripts/docs/test-workflow-page-drift.sh \
            scripts/handover/chief-kit/relay-batch.sh:scripts/docs/test-how-a-change-ships.sh; do
    named="${pair%%:*}"; suite="${pair#*:}"
    change "$named"
    out="$( cd "$FX" && HIMMEL_SUITES_LOCAL=1 bash "$IS" --plan "$range" 2>/dev/null | awk '$1 == "LOCAL" { print $2 }' )"
    if grepq "$out" -Fx "$suite"; then pass "30c an edit to ${named##*/} still puts $suite on the --plan list"; else fail "30c $suite not on the --plan list for ${named##*/}: $out"; fi
done
git -C "$FX" rm -q scripts/docs/test-dev-graph.sh scripts/hooks/test-escape-class-corpus.sh scripts/docs/test-workflow-page-drift.sh scripts/docs/test-how-a-change-ships.sh
git -C "$FX" commit -q -m "chore: drop the real widening suites"

# --- 31. The PR-1734 shape. A NEW file under a tree that a suite
# walks (lint-fail-open scans scripts/lanes/) lists that suite, though no suite
# names the file; a new file outside every declared tree does not. -----------
mkf scripts/guardrails/test-lint-fail-open.sh 'bash "$d/lint-fail-open.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: scan-roots fixtures"
mkdir -p "$FX/scripts/lanes/lib" "$FX/docs/scan-31"
change scripts/lanes/lib/worker-cost-row.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/guardrails/test-lint-fail-open\.sh$'; then pass "a new file under scripts/lanes/ -> test-lint-fail-open.sh (scan root)"; else fail "scan-root miss on the PR-1734 shape: $out"; fi
change docs/scan-31/new.sh
out="$(run_is "$range")"
if ! grepq "$out" 'test-lint-fail-open'; then pass "a new file outside every scan root does not list the scanning suite"; else fail "scan root over-selected: $out"; fi

# --- 31b. The wired-hook resolution sweep reads every hook script,
# its libs and the two wiring files without naming any of them, so a change to
# any of those lists it. ------------------------------------------------------
mkf scripts/hooks/test-wired-hooks-integrity-resolution.sh 'echo sweep'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: wired-hook sweep fixture"
mkdir -p "$FX/.claude" "$FX/.codex"
mkdir -p "$FX/scripts/guardrails" "$FX/scripts/handover"
for f in scripts/hooks/some-guard.sh scripts/lib/some-lib.sh scripts/guardrails/lib.sh scripts/handover/queue-lock.sh .claude/settings.json .codex/hooks.json; do
  change "$f"
  out="$(run_is "$range")"
  if grepq "$out" '^scripts/hooks/test-wired-hooks-integrity-resolution\.sh$'; then pass "$f -> test-wired-hooks-integrity-resolution.sh (scan root)"; else fail "wired-hook sweep not selected for $f: $out"; fi
done

# --- 31c. check-unwired-hooks walks scripts/hooks/ and reads the
# wiring files without naming any hook, so a hook file ADDED (or renamed) there,
# or a wiring file edited, lists test-unwired-hooks.sh (PR 2401 merged an unwired
# hook green; main went red on A1). RED on main: no row, suite never listed. ---
mkf scripts/testing/test-unwired-hooks.sh 'echo unwired'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: unwired-hooks fixture"
mkdir -p "$FX/scripts/hooks" "$FX/marketplace/plugins/p/hooks" "$FX/docs/setup"
UWH='^scripts/testing/test-unwired-hooks\.sh$'
for f in scripts/hooks/brand-new-guard.sh scripts/hooks/new-guard.mjs .claude/settings.json .codex/hooks.json marketplace/plugins/p/hooks/hooks.json .pre-commit-config.yaml .pre-commit-hooks.yaml docs/setup/settings-template.json; do
  change "$f"
  out="$(run_is "$range")"
  if grepq "$out" "$UWH"; then pass "$f -> test-unwired-hooks.sh (scan root)"; else fail "unwired-hooks suite not selected for $f: $out"; fi
done
# Parity: every entry of check-unwired-hooks.sh's WIRING array must list the suite,
# so a root added there without a scan_roots row fails here, not on main.
wiring_entries="$(awk '/^WIRING=\(/{on=1;next} on&&/^\)/{exit} on{gsub(/^[ \t]+|[ \t]+$/,"");print}' "$REPO_ROOT/scripts/testing/check-unwired-hooks.sh")"
if [ -z "$wiring_entries" ]; then fail "could not read WIRING from check-unwired-hooks.sh"; fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$FX/$(dirname "$f")"
  change "$f"
  out="$(run_is "$range")"
  if grepq "$out" "$UWH"; then pass "WIRING entry $f -> test-unwired-hooks.sh (parity)"; else fail "WIRING entry $f has no scan_roots row for test-unwired-hooks.sh: $out"; fi
done <<< "$wiring_entries"
git -C "$FX" mv scripts/hooks/brand-new-guard.sh scripts/hooks/renamed-guard.sh
git -C "$FX" commit -q -m "chore: rename hook"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$(run_is "$range")"
if grepq "$out" "$UWH"; then pass "a renamed hook file -> test-unwired-hooks.sh"; else fail "rename of a hook not selected: $out"; fi
change docs/setup/unrelated.md
out="$(run_is "$range")"
if ! grepq "$out" "$UWH"; then pass "a file outside hooks and wiring does not list test-unwired-hooks.sh"; else fail "unwired-hooks over-selected: $out"; fi

# --- 32. npm-licenses row (RED control) and the veto rows. -----
NPM=scripts/hooks/test-check-npm-licenses\\.sh
PCR=scripts/cr/test-pr-check-run\\.sh
LSP=scripts/lanes/test-launch-site-profiles\\.sh
mkf scripts/hooks/test-check-npm-licenses.sh 'echo npm'
mkf scripts/cr/test-pr-check-run.sh 'echo pcr'
mkf scripts/lanes/test-launch-site-profiles.sh 'echo lsp'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: veto fixtures"
mkdir -p "$FX/tools/new" "$FX/tools/node_modules/dep" "$FX/scripts/lanes/bench/fixtures/x" "$FX/scripts/handover" "$FX/scripts/lanes/dist" "$FX/scripts/a"
change tools/new/package.json
out="$(run_is "$range")"
if grepq "$out" "^${NPM}\$"; then pass "a new package.json -> test-check-npm-licenses.sh"; else fail "npm-licenses row missed: $out"; fi
change tools/node_modules/dep/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a node_modules package.json does not select npm-licenses"; else fail "npm-licenses veto (node_modules) missed: $out"; fi
change scripts/lanes/bench/fixtures/x/package.json
out="$(run_is "$range")"
if ! grepq "$out" "^${NPM}\$"; then pass "a bench-fixtures package.json does not select npm-licenses"; else fail "npm-licenses veto (fixtures) missed: $out"; fi
change scripts/a/tool.sh
out="$(run_is "$range")"
if grepq "$out" "^${PCR}\$" && grepq "$out" "^${LSP}\$"; then pass "a scripts/a/tool.sh selects pr-check-run and launch-site-profiles"; else fail "scripts/*.sh rows lost: $out"; fi
change scripts/a/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "scripts/a/test-foo.sh does not select launch-site-profiles"; else fail "launch-site veto (test-*) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "scripts/a/test-foo.sh still selects pr-check-run (its walk reads it)"; else fail "pr-check-run over-vetoed scripts/a/test-foo.sh: $out"; fi
change scripts/cr/test-foo.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${PCR}\$"; then pass "scripts/cr/test-foo.sh does not select pr-check-run"; else fail "pr-check-run veto (scripts/cr/test-*) missed: $out"; fi
change scripts/lanes/dist/gen.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${LSP}\$"; then pass "a dist/ file does not select launch-site-profiles"; else fail "launch-site veto (dist) missed: $out"; fi
if grepq "$out" "^${PCR}\$"; then pass "a dist/ file still selects pr-check-run"; else fail "pr-check-run lost dist/ file: $out"; fi

# --- 33b. WS5 T13(b) scans every shipped (non-test) shell or JS source the diff
# adds and names none of them: a one-file change to a scanned source selects it
# (RED control: PR 2217 changed scripts/telegram/break-glass.sh and the suite
# never ran), and the files its own scan skips do not. -------------------------
WS5=scripts/parity/test-ws5-invariants\\.sh
mkf scripts/parity/test-ws5-invariants.sh 'echo ws5'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: ws5 fixture"
mkdir -p "$FX/scripts/telegram" "$FX/tools/ws5"
for ws5_src in scripts/telegram/break-glass.sh tools/ws5/a.mjs tools/ws5/b.ts tools/ws5/c.js tools/ws5/d.cjs tools/ws5/e.bash tools/ws5/j.JS tools/ws5/k.SH; do
  change "$ws5_src" || { fail "fixture setup failed for $ws5_src"; continue; }
  out="$(run_is "$range")"
  if grepq "$out" "^${WS5}\$"; then pass "a one-file change to $ws5_src selects test-ws5-invariants.sh"; else fail "WS5 not selected for $ws5_src: $out"; fi
done
for ws5_skip in scripts/telegram/test-break-glass.sh tools/ws5/data.tsv tools/ws5/f.test.ts tools/ws5/g.test.mjs tools/ws5/h.test.js tools/ws5/i.test.cjs; do
  change "$ws5_skip" || { fail "fixture setup failed for $ws5_skip"; continue; }
  out="$(run_is "$range")"
  if ! grepq "$out" "^${WS5}\$"; then pass "$ws5_skip (skipped by WS5's own scan) does not select test-ws5-invariants.sh"; else fail "WS5 over-selected for $ws5_skip: $out"; fi
done
# the !test-* veto must not stop WS5 selecting itself when its own file changes
if change scripts/parity/test-ws5-invariants.sh; then
  out="$(run_is "$range")"
  if grepq "$out" "^${WS5}\$"; then pass "a change to test-ws5-invariants.sh itself selects it (the test-* veto does not hide it)"; else fail "WS5 self-change not selected: $out"; fi
else
  fail "fixture setup failed for the WS5 self-change"
fi

# --- 34. A change to the CR guarded closure selects
# test-cr-guarded-closure.sh (#1851: worker-jira-status.sh, reached from the
# guarded scripts/lanes/worker-pr-open.sh, was added without selecting it). --------
GC=scripts/cr/test-cr-guarded-closure\\.sh
mkf scripts/cr/test-cr-guarded-closure.sh 'echo gc'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/worker-pr-open.sh"'
mkf scripts/lanes/worker-pr-open.sh 'bash "$d/../handover/chief-kit/worker-jira-status.sh"'
mkf scripts/lanes/unrelated.sh 'echo unrelated'
mkf scripts/handover/chief-kit/worker-jira-status.sh 'echo jira'
mkf scripts/handover/chief-kit/tracker.py 'print(1)'
mkf scripts/cr/test-names-tracker.sh 'grep -q tracker.py x'
mkf .agents/skills/pr-check/SKILL.md 'runbook'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: guarded-closure fixtures"
change scripts/lanes/worker-pr-open.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a guarded file (worker-pr-open.sh) -> test-cr-guarded-closure.sh"; else fail "guarded file missed: $out"; fi
change scripts/handover/chief-kit/worker-jira-status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the #1851 shape: an unguarded file a guarded file names -> test-cr-guarded-closure.sh"; else fail "#1851 shape missed: $out"; fi
change .agents/skills/pr-check/SKILL.md
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "the runbook twin -> test-cr-guarded-closure.sh"; else fail "runbook seed missed: $out"; fi
change scripts/handover/chief-kit/tracker.py
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "tracker.py (named only by a guarded test, reached by no guarded file) does not select the closure suite"; else fail "closure row over-selected tracker.py: $out"; fi
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if ! grepq "$out" "^${GC}\$"; then pass "an unreferenced scripts/lanes file does not select the closure suite"; else fail "closure row over-selected scripts/lanes: $out"; fi

# --- 35. Closure arms. -------------------------------
# 4534: arm 1 alone. brand-new.sh sits under the guarded scripts/lib dir, no
# guarded file names it (arm 2 cannot fire) and no scan_roots row maps
# scripts/lib/* to the closure suite (scripts/cr/* does, so it cannot be used).
mkf scripts/lib/brand-new.sh 'echo new'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: arm-1 fixture"
change scripts/lib/brand-new.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 1 alone: a file inside a guarded dir that nothing names -> closure suite"; else fail "arm 1 alone missed: $out"; fi
# 4533: arm 2 is not limited to handover/lanes/lib: a guarded file naming
# scripts/telegram/status.sh makes a change to it select the closure suite.
mkf scripts/lanes/names-tg.sh 'bash "$d/../telegram/status.sh"'
mkf scripts/telegram/status.sh 'echo status'
mkf scripts/cr/pr-check-context.sh 'cr_guarded="scripts/cr scripts/lib
scripts/lanes/worker-pr-open.sh scripts/lanes/names-tg.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: telegram fixtures"
change scripts/telegram/status.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "arm 2 beyond handover/lanes/lib: scripts/telegram/status.sh -> closure suite"; else fail "telegram edge missed: $out"; fi
# 4535: a head without pr-check-context.sh must not silently skip the suite.
git -C "$FX" rm -q scripts/cr/pr-check-context.sh
git -C "$FX" commit -q -m "chore: drop pr-check-context.sh"
change scripts/lanes/unrelated.sh
out="$(run_is "$range")"
if grepq "$out" "^${GC}\$"; then pass "a head with no pr-check-context.sh still selects the closure suite"; else fail "closure suite skipped on an unreadable guarded set: $out"; fi

# --- 36. A temp write that fails is an error, never a short list ---
# A full /tmp (2026-10-10, PR 2301: 56 suites against 60) made a bash here-string
# fail with "cannot create temp file for here-document"; its rc was read as "no
# suites" and the selector exited 0 with a partial list. RLIMIT_FSIZE (ulimit -f,
# SIGXFSZ ignored so the write returns EFBIG) is the user-space stand-in for
# ENOSPC: the same failing write(2), no root and no real disk filled. The fixture
# tree is sized like the real one (about 200 KB of path names, over a pipe's
# capacity, so a here-string must go through a temp file on every bash).
BIG="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG"' EXIT
(
    fixture_enter_git_init_dir "$BIG" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
    mkdir -p scripts/bulk
    pad="$(printf 'p%.0s' $(seq 1 100))"
    i=0
    while [ "$i" -lt 1500 ]; do
        : > "scripts/bulk/filler-${i}-${pad}.txt"
        i=$((i + 1))
    done
    printf '# big-target\n' > scripts/big-target.sh
    printf 'bash scripts/big-target.sh\n' > scripts/test-big.sh
    printf 'echo self\n' > scripts/test-self.sh
    git add -A
    git commit -q -m "chore: big base"
    printf '# changed\n' >> scripts/big-target.sh
    printf '# changed\n' >> scripts/test-self.sh
    git add -A
    git commit -q -m "fix: change big-target and a suite"
)
big_range="$(git -C "$BIG" rev-parse HEAD~1)..$(git -C "$BIG" rev-parse HEAD)"
# Probe: does a file-size limit bite here (Git Bash on Windows may not enforce it)?
probe="$BIG/.fsize-probe"
( ulimit -f 1; trap '' XFSZ; head -c 4096 /dev/zero > "$probe" ) 2>/dev/null
if [ "$(wc -c < "$probe" 2>/dev/null | tr -d ' ')" -ge 4096 ] 2>/dev/null; then
    echo "SKIP 36: this platform does not enforce ulimit -f"
else
    out="$( cd "$BIG" && bash "$IS" "$big_range" 2>/dev/null )"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "$(printf 'scripts/test-big.sh\nscripts/test-self.sh')" ]; then pass "big fixture, room to write: the suite naming big-target.sh and the changed suite are listed (control)"; else fail "big fixture control: rc=$rc out=$out"; fi
    out="$( cd "$BIG" && ulimit -f 40 && trap '' XFSZ && bash "$IS" "$big_range" 2>/dev/null )"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then pass "a temp write that fails -> non-zero rc and no list (not a short list at rc0)"; else fail "failing temp write: rc=$rc out=$out"; fi
    err="$( cd "$BIG" && ulimit -f 40 && trap '' XFSZ && bash "$IS" "$big_range" 2>&1 >/dev/null )"
    if grepq "$err" 'cannot trust the impacted list'; then pass "the failed temp write is named on stderr"; else fail "failing temp write not named: $err"; fi
fi

# --- 36a. every checked create fails closed ---
# Row 36 pins only the first temp write. Here a mktemp shim makes the work dir
# with a DIRECTORY already sitting at one scratch file's name, so that file's
# create cannot open: each name below must end the run at rc 2 with no list. A
# create that read its failure as rc 1 ("no match") would exit 0 with a short list.
SHIM3="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3"' EXIT
printf '#!/usr/bin/env bash\nd="$(%s "$@")" || exit $?\nif [ -n "${PRECREATE_DIR:-}" ]; then mkdir "$d/$PRECREATE_DIR" || exit 1; fi\nif [ -n "${PRECREATE_FULL:-}" ]; then ln -s /dev/full "$d/$PRECREATE_FULL" || exit 1; fi\nprintf "%%s\\n" "$d"\n' "$(command -v mktemp)" > "$SHIM3/mktemp"
chmod +x "$SHIM3/mktemp"
change scripts/lib/clo-lib.sh
out="$( cd "$FX" && PRECREATE_DIR=unused PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
if [ "$rc" -eq 0 ] && [ -n "$out" ] && [ ! -s "$SHIM3/err" ]; then pass "unused scratch directory: shim permits rc 0 and a non-empty list (36a control)"; else fail "36a control: rc=$rc out=$out err=$(cat "$SHIM3/err")"; fi
# For grep.out and *.raw, rc 2/no list alone pins only the fail-closed outcome:
# a later read also fails after a removed create check. The diagnostic below
# additionally pins the expected first failing step, not just that outcome.
while IFS='|' read -r name step; do
    out="$( cd "$FX" && PRECREATE_DIR="$name" PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
    err="$(cat "$SHIM3/err")"
    if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F "impacted-suites: $step failed — cannot trust the impacted list"; then pass "scratch '$name' cannot open -> rc 2, no list, named step"; else fail "scratch '$name': rc=$rc out=$out err=$err (wanted $step)"; fi
done <<'EOF'
tree|writing the tree listing
changed|writing the changed-file list
suites|creating the suite list
patterns|writing a needle
found|recording a scan-root suite
seen|seeding the source closure
front|seeding the source closure
srcpats|writing a source-edge pattern
asgpats|writing an assignment pattern
dirpats|writing a directive pattern
hit.src|creating the walking the source closure hit list
hit.dir|creating the reading shellcheck source directives hit list
hit.asg|creating the reading variable assignments hit list
narrow.cand|creating the walking the source closure candidate list
narrow.hits|creating the walking the source closure result file
narrow.rel|reading the walking the source closure candidates
narrow.reg|creating the walking the source closure candidate list
narrow.irr|creating the walking the source closure candidate list
narrow.lines|creating the walking the source closure candidate list
narrow.tagged|reading the walking the source closure candidates
narrow.dirs.txt|listing the walking the source closure scratch directories
narrow.dirs|converting the walking the source closure scratch directory list
importers|creating the importer list
import-edges|creating the import index
import.lines|reading the importer lines
tree.modes|listing the tree modes
attr.nonreg|finding the non-regular attribute files
src.out|merging source-closure hits
next|growing the source closure
varsrc.raw|creating the variable-sourcer list
varsrc|listing variable-sourcing files
content-rules|writing the content rules
grep.out|creating the searching the suites for the changed files hit list
EOF
out="$( cd "$FX" && PRECREATE_DIR=shell PATH="$SHIM3:$PATH" bash "$IS" "$range" --shell 2>"$SHIM3/err" )"; rc=$?
err="$(cat "$SHIM3/err")"
if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F 'impacted-suites: creating the shell-suite list failed'; then pass "--shell: filter file cannot open -> rc 2, no list, named step"; else fail "--shell filter file: rc=$rc out=$out err=$err"; fi
out="$( cd "$FX" && PRECREATE_DIR=impacted PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
err="$(cat "$SHIM3/err")"
if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F 'impacted-suites: sorting the impacted list failed'; then pass "impacted-list file cannot open -> rc 2, no list, named step"; else fail "impacted-list file: rc=$rc out=$out err=$err"; fi

# --- 36b. Final stdout write must fail closed ------------------
# /dev/full rejects writes, but can be opened: the failure must reach the final
# cat, not the shell redirect. Dropping cat's || io_fail returns rc 0 instead.
if [ -c /dev/full ]; then
    ( cd "$FX" && bash "$IS" "$range" >/dev/full 2>"$SHIM3/err" ); rc=$?
    err="$(cat "$SHIM3/err")"
    if [ "$rc" -eq 2 ] && grepq "$err" -F 'impacted-suites: listing the impacted suites failed'; then pass "final stdout write fails -> rc 2, named listing step"; else fail "final stdout write: rc=$rc err=$err"; fi
else
    echo "SKIP 36b: /dev/full is unavailable on this platform"
fi

# --- no range argument defaults to merge-base(default)..HEAD ----
# The default branch is resolved by scripts/lib/review-default-base.sh (origin/HEAD,
# else origin/main).
run_is_err() { ( cd "$FX" && { bash "$IS" "$@" >/dev/null; } 2>&1 ); }
# (a) no origin ref at all: refuse non-zero, name the filled fetch command.
err="$(run_is_err)"
if ( cd "$FX" && bash "$IS" >/dev/null 2>&1 ); then
    fail "no-arg run with no default ref exited 0"
else
    pass "no-arg run with no default ref exits non-zero"
fi
if grepq "$err" -F 'git fetch origin'; then pass "no default ref: error names the filled fetch command"; else fail "no default ref: no fetch command in: $err"; fi
# (b) origin/main behind HEAD: the default is merge-base..HEAD, printed to stderr.
mb_sha="$(git -C "$FX" rev-parse HEAD)"
git -C "$FX" update-ref refs/remotes/origin/main "$mb_sha"
change scripts/machine-setup/uninstall-plugins.sh
want="$(run_is "${mb_sha}..HEAD")"
got="$(run_is)"
if [ -n "$want" ] && [ "$got" = "$want" ]; then pass "no-arg run lists the same suites as merge-base..HEAD"; else fail "no-arg output differs: want [$want] got [$got]"; fi
err="$(run_is_err)"
if grepq "$err" -F "${mb_sha}..HEAD"; then pass "no-arg run prints the chosen range to stderr"; else fail "chosen range not on stderr: $err"; fi
err="$(run_is_err "${mb_sha}..HEAD")"
if [ -z "$err" ]; then pass "explicit range: stderr unchanged (empty)"; else fail "explicit range wrote to stderr: $err"; fi
# (c) origin/HEAD names another branch: it wins over origin/main.
git -C "$FX" update-ref refs/remotes/origin/trunk "$(git -C "$FX" rev-parse HEAD~3)"
git -C "$FX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
trunk_mb="$(git -C "$FX" rev-parse HEAD~3)"
err="$(run_is_err)"
if grepq "$err" -F "${trunk_mb}..HEAD"; then pass "origin/HEAD's target is the default branch"; else fail "origin/HEAD ignored: $err"; fi
git -C "$FX" symbolic-ref -d refs/remotes/origin/HEAD
# (d) default ref shares no history with HEAD: refuse with a filled command.
orphan="$(git -C "$FX" commit-tree -m orphan "$(git -C "$FX" mktree </dev/null)")"
git -C "$FX" update-ref refs/remotes/origin/main "$orphan"
err="$(run_is_err)"
if ( cd "$FX" && bash "$IS" >/dev/null 2>&1 ); then
    fail "no-arg run with no merge-base exited 0"
else
    pass "no-arg run with no merge-base exits non-zero"
fi
if grepq "$err" -F 'pass an explicit range' && ! grepq "$err" -F 'unshallow'; then pass "unrelated history: error asks for an explicit range, not --unshallow"; else fail "unrelated history: wrong remedy in: $err"; fi
# (e) the same in a shallow clone: --unshallow is the remedy.
SHD="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3"' EXIT
# This replacement must retain the earlier fixture cleanup.
# Source-level assertion; CI also runs the actual EXIT trap.
exit_trap="$(trap -p EXIT)"
if grepq "$exit_trap" -F '"$BIG"' && grepq "$exit_trap" -F '"$SHIM3"'; then pass "active EXIT trap retains BIG and SHIM3 cleanup"; else fail "active EXIT trap drops earlier fixtures: $exit_trap"; fi
SH="$SHD/c"
git clone -q --depth 1 "file://$FX" "$SH"
git -C "$SH" symbolic-ref -d refs/remotes/origin/HEAD
git -C "$SH" update-ref refs/remotes/origin/main "$(git -C "$SH" -c user.name=t -c user.email=t@e commit-tree -m orphan "$(git -C "$SH" mktree </dev/null)")"
err="$( ( cd "$SH" && { bash "$IS" >/dev/null; } 2>&1 ) )"
if grepq "$err" -F 'git fetch --unshallow origin'; then pass "shallow clone: error names git fetch --unshallow origin"; else fail "shallow clone: no unshallow command in: $err"; fi
git -C "$FX" update-ref -d refs/remotes/origin/main

# --- 37. A large diff must not run the full ERE over every file --
# `git grep -E -f` with ~1k patterns over ~1.7k .sh files was 3184 CPU-seconds on
# PR 2430's 321-file diff. The ERE may now run only over the pre-narrowed tree
# (--no-index); this shim logs every git grep so a full-tree ERE pass is a FAIL.
SHIM4="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3" "$SHIM4"' EXIT
REAL_GIT="$(command -v git)"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = grep ]; then printf "%%s\\n" "$*" >> "%s/calls"; fi\nexec "%s" "$@"\n' "$SHIM4" "$REAL_GIT" > "$SHIM4/git"
chmod +x "$SHIM4/git"
# a suite whose referencing line holds a byte that is not valid UTF-8
printf 'bash "$d/lib/clo-lib.sh" \377\n' > "$FX/scripts/test-nonutf8.sh"
change scripts/lib/clo-lib.sh
ctl="$(run_is "$range")"
: > "$SHIM4/calls"
out="$( cd "$FX" && PATH="$SHIM4:$PATH" bash "$IS" "$range" 2>"$SHIM4/stderr" )"
if [ "$out" = "$ctl" ] && grepq "$out" '^scripts/test-clo-stem\.sh$'; then pass "git shim: same list, closure suite listed (37 control)"; else fail "37 control: $out [stderr: $(head -c 600 "$SHIM4/stderr")]"; fi
# The control above compares the new selector with itself; this one compares it
# with the selector as it was before the batching change (a full `git grep -E -f` per
# round), read from the immutable base commit when this clone holds it.
OLD_IS_SHA=dd22dd9f51730a1cac08ab7593f0e639160829a1
mkdir -p "$SHIM4/oldcr"
if ! git -C "$(dirname "$IS")" cat-file -e "$OLD_IS_SHA^{commit}" 2>/dev/null; then
    pass "old-selector control not run: $OLD_IS_SHA is not in this clone (shallow)"
elif ! cp "$(dirname "$IS")/anchor-handoff.sh" "$SHIM4/oldcr/anchor-handoff.sh"; then
    fail "old-selector control setup: cannot copy anchor-handoff.sh"
elif ! git -C "$(dirname "$IS")" show "$OLD_IS_SHA:scripts/cr/impacted-suites.sh" > "$SHIM4/oldcr/impacted-suites.sh"; then
    fail "old-selector control setup: $OLD_IS_SHA is present but its selector could not be read"
else
    # LC_ALL=C: that selector predates the byte-safe sed and BSD sed rejects the fixture's non-UTF-8 byte.
    old_out="$( cd "$FX" && LC_ALL=C bash "$SHIM4/oldcr/impacted-suites.sh" "$range" 2>/dev/null )"
    # The WS5 scan_roots rows postdate that selector, so its row is not compared.
    cmp_out="$(grep -vxF scripts/parity/test-ws5-invariants.sh <<< "$out")"
    if [ "$old_out" = "$cmp_out" ] && [ -n "$old_out" ]; then pass "same list as the pre-HIMMEL-5363 selector (old-selector control)"; else fail "old selector differs: old=[$old_out] new=[$out]"; fi
fi
if grepq "$out" '^scripts/test-nonutf8\.sh$'; then pass "a suite line with a non-UTF-8 byte is still matched"; else fail "non-UTF-8 suite not listed: $out"; fi
PREV_IS_SHA=093218b3d9ed4eadb8d6eff8d67949d72aabb031
mkdir -p "$SHIM4/prevcr"
if ! git -C "$(dirname "$IS")" cat-file -e "$PREV_IS_SHA^{commit}" 2>/dev/null; then
    pass "git-grep-read control not run: $PREV_IS_SHA is not in this clone (shallow)"
elif ! cp "$(dirname "$IS")/anchor-handoff.sh" "$SHIM4/prevcr/anchor-handoff.sh" || ! git -C "$(dirname "$IS")" show "$PREV_IS_SHA:scripts/cr/impacted-suites.sh" > "$SHIM4/prevcr/impacted-suites.sh"; then
    fail "git-grep-read control setup: cannot read $PREV_IS_SHA"
else
    SM="$(fixture_mktemp_dir)" || exit 1
    trap 'rm -rf "$FX" "$SHIM" "$SHIM2" "$SHD" "$BIG" "$SHIM3" "$SHIM4" "$SM"' EXIT
    (
        fixture_enter_git_init_dir "$SM" || exit 1
        git init -q
        git config user.email t@e
        git config user.name t
    )
    mkdir -p "$SM/scripts/lib" "$SM/scripts/deep/er"
    for n in 1 2 3; do printf '# lib\n' > "$SM/scripts/lib/smlib-$n.sh"; done
    for s in 1 2 3 4 5 6; do printf 'x="$d/lib/smlib-%s.sh"\n' $(( s % 3 + 1 )) > "$SM/scripts/test-sm-$s.sh"; done
    printf 'x="$d/lib/smlib-1.sh"\n' > "$SM/scripts/deep/er/test-sm-deep.sh"
    git -C "$SM" add -A
    git -C "$SM" commit -q -m "chore: base"
    for n in 1 2 3; do printf '# changed\n' >> "$SM/scripts/lib/smlib-$n.sh"; done
    git -C "$SM" add -A
    git -C "$SM" commit -q -m "fix: libs"
    smrange="$(git -C "$SM" rev-parse HEAD~1)..$(git -C "$SM" rev-parse HEAD)"
    prev_out="$( cd "$SM" && bash "$SHIM4/prevcr/impacted-suites.sh" "$smrange" 2>/dev/null )"
    sm_out="$( cd "$SM" && bash "$IS" "$smrange" 2>/dev/null )"
    if [ "$prev_out" = "$sm_out" ] && [ "$(grep -c . <<< "$sm_out")" -eq 7 ]; then pass "the grep -E -f read lists the same suites as the git grep -E -f read it replaced"; else fail "grep -E -f read differs from the git grep read: prev=[$prev_out] new=[$sm_out]"; fi
fi
# One inline-pattern -E over the tree (the variable-sourcer scan) is a single
# regex and cheap; the cost was the -f pattern FILE, so that is what must not
# run against the head tree.
full_pass="$(grep -F -e ' -E ' "$SHIM4/calls" | grep -F -e ' -f ' | grep -v -F -e '--no-index')"
if [ -s "$SHIM4/calls" ] && [ -z "$full_pass" ]; then pass "no full-tree git grep -E -f: every pattern-file pass is --no-index over the narrowed tree"; else fail "full-tree ERE -f pass: $(cat "$SHIM4/calls")"; fi

# --- 37a. a PR-2430-shaped diff (300+ changed files, many suites) stays in budget
# The budget is the loaded figure x2.
LARGE_N=320
for i in $(seq 1 "$LARGE_N"); do mkf "vendor/big/src/f$i.js" "// v$i"; done
for i in $(seq 1 120); do mkf "scripts/test-bulk-$i.sh" "bash \"\$d/lib/clo-lib.sh\"; echo f$i.js"; done
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: bulk base"
for i in $(seq 1 "$LARGE_N"); do printf '// changed\n' >> "$FX/vendor/big/src/f$i.js"; done
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: bulk vendored change"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
t0=$SECONDS
out="$(run_is "$range")"; rc=$?
elapsed=$((SECONDS - t0))
if [ "$rc" -eq 0 ] && [ "$elapsed" -le 90 ] && grepq "$out" '^scripts/test-bulk-1\.sh$' && grepq "$out" '^scripts/test-bulk-120\.sh$'; then pass "a $LARGE_N-file diff finishes in ${elapsed}s (budget 90s) and lists its impacted suites"; else fail "large diff: rc=$rc elapsed=${elapsed}s lines=$(printf '%s\n' "$out" | wc -l)"; fi

# --- 37a2. the read spawns a bounded number of `git show` processes -----------
# ready-check item 19 gives the read 30 s, so its time must not grow with one process
# per narrowing candidate or per importer file. Here 120 candidate suites and 40
# importer files sit around ONE changed file: the count of `git show` calls must not
# follow them.
for i in $(seq 1 40); do mkf "vendor/imp/m$i.js" "import x from './clo-lib'; // m$i"; done
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: importer files"
change scripts/lib/clo-lib.sh
SC="$SHIM4/showcount"
mkdir -p "$SC"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = show ]; then echo x >> "%s/shows"; fi\nexec "%s" "$@"\n' "$SC" "$REAL_GIT" > "$SC/git"
chmod +x "$SC/git"
ctl="$(run_is "$range")"
: > "$SC/shows"
out="$( cd "$FX" && PATH="$SC:$PATH" bash "$IS" "$range" 2>"$SC/stderr" )"
n_show="$(wc -l < "$SC/shows" | tr -d ' ')"
if [ "$out" = "$ctl" ] && grepq "$out" '^scripts/test-bulk-120\.sh$'; then pass "git show shim: same list, a bulk suite listed (37a2 control)"; else fail "37a2 control: $out [stderr: $(head -c 600 "$SC/stderr")]"; fi
if [ "$n_show" -le 12 ]; then pass "160 candidates and importers cost $n_show git show calls (bound 12)"; else fail "git show calls follow the candidate count: $n_show (bound 12)"; fi

# A suite that `git archive` leaves out (export-ignore) is not in the unpacked copy,
# so it takes the per-file path: its text still names the changed file, so it is
# still listed.
mkf scripts/test-export-ignored.sh 'bash "$d/lib/clo-lib.sh"'
printf 'scripts/test-export-ignored.sh export-ignore\n' > "$FX/.gitattributes"
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: export-ignored suite"
change scripts/lib/clo-lib.sh
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-export-ignored\.sh$' && grepq "$out" '^scripts/test-bulk-120\.sh$'; then pass "a suite git archive leaves out is listed beside the unpacked ones"; else fail "export-ignored suite not listed: $out"; fi

# The import index reads the lines `git grep` prints, so a user's grep.* output settings
# must not reach it. A Python and a JS importer of a changed module, each reached by a
# suite that names only the importer, run once plain and once with a git shim that
# turns grep.lineNumber and grep.column on (a mutation that drops the
# overrides, or the importer parse, loses the suites).
mkf scripts/lib/pymod.py 'X = 1'
mkf scripts/pyuser.py 'import pymod'
mkf scripts/test-pyuser.sh 'python3 "$d/pyuser.py"'
mkf scripts/lib/jsmod.mjs 'export const X = 1;'
mkf scripts/jsuser.mjs "import { X } from './lib/jsmod.mjs';"
mkf scripts/test-jsuser.sh 'node "$d/jsuser.mjs"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: python and js importers"
GRL="$SHIM4/grepcfg"
mkdir -p "$GRL"
printf '#!/usr/bin/env bash\nexec "%s" -c grep.lineNumber=true -c grep.column=true "$@"\n' "$REAL_GIT" > "$GRL/git"
chmod +x "$GRL/git"
for chg in scripts/lib/pymod.py:test-pyuser scripts/lib/jsmod.mjs:test-jsuser; do
    change "${chg%%:*}"
    out="$(run_is "$range")"
    if grepq "$out" "^scripts/${chg##*:}\\.sh\$"; then pass "${chg%%:*}: the suite naming only its importer is listed"; else fail "import closure of ${chg%%:*}: $out"; fi
    out="$( cd "$FX" && PATH="$GRL:$PATH" bash "$IS" "$range" 2>/dev/null )"
    if grepq "$out" "^scripts/${chg##*:}\\.sh\$"; then pass "${chg%%:*}: still listed with grep.lineNumber and grep.column set"; else fail "import closure of ${chg%%:*} under grep.* settings: $out"; fi
done

# A root-level file whose name starts with `-` is a candidate like any other: the
# batched grep must not read it as an option (a grep may exit 1, "no match", on that
# usage error, which would drop the candidate without a word). It sources the changed
# file, so a suite naming only it must be listed.
mkf -dash-lib.sh 'source "$d/lib/clo-lib.sh"'
mkf scripts/test-names-dash.sh 'bash "$d/../-dash-lib.sh"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: dash-named sourcer"
change scripts/lib/clo-lib.sh
out="$( cd "$FX" && bash "$IS" "$range" 2>"$SC/dash.err" )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-names-dash\.sh$'; then pass "a sourcer named -dash-lib.sh is not read as an option: the suite naming it is listed"; else fail "dash-named candidate: rc=$rc err=$(head -c 400 "$SC/dash.err")"; fi

# The import index reads a file git calls binary (a NUL byte) as text: `git grep`
# without -a prints "Binary file matches" for it and its edge would vanish at exit 0.
printf 'import pymod\n\000\n' > "$FX/scripts/binuser.py"
mkf scripts/test-binuser.sh 'python3 "$d/binuser.py"'
git -C "$FX" add -A
git -C "$FX" commit -q -m "chore: python importer holding a NUL byte"
change scripts/lib/pymod.py
out="$(run_is "$range")"
if grepq "$out" '^scripts/test-binuser\.sh$'; then pass "an importer git calls binary still indexes its import lines"; else fail "binary importer dropped: $out"; fi

# The candidate split writes two lists. A write that fails (a full disk) must stop the
# run: dropping the candidate would drop its suite at exit 0. narrow.reg holds the
# candidates the unpack has as regular files, narrow.irr the export-ignored one; the
# mktemp shim makes the scratch file a symlink to /dev/full, which opens and rejects writes.
if [ -c /dev/full ]; then
    change scripts/lib/clo-lib.sh
    for name in narrow.reg narrow.irr; do
        out="$( cd "$FX" && PRECREATE_FULL="$name" PATH="$SHIM3:$PATH" bash "$IS" "$range" 2>"$SHIM3/err" )"; rc=$?
        err="$(cat "$SHIM3/err")"
        if [ "$rc" -eq 2 ] && [ -z "$out" ] && grepq "$err" -F 'impacted-suites: recording a walking the source closure candidate failed'; then pass "$name rejects the write -> rc 2, no list, named step"; else fail "$name on /dev/full: rc=$rc out=$out err=$err"; fi
    done
else
    echo "SKIP split writes: /dev/full is unavailable on this platform"
fi

# --- 37b. a candidate whose scratch copy cannot be created fails closed ------
# The narrowing writes each candidate's matching lines to a scratch file; a
# failed open of that file is rc 1, the code `grep` uses for "no match", so
# without a checked create the suite was silently dropped at exit 0. A suite
# whose name component is longer than NAME_MAX (committed through the index, so
# the worktree never has to hold it) cannot be created under the scratch tree.
LONGNAME="scripts/test-$(printf 'x%.0s' $(seq 1 300)).sh"
long_blob="$(printf 'bash "$d/lib/clo-lib.sh"\n' | git -C "$FX" hash-object -w --stdin)"
git -C "$FX" update-index --add --cacheinfo "100644,$long_blob,$LONGNAME"
git -C "$FX" commit -q -m "chore: suite with an over-long name"
change scripts/lib/clo-lib.sh
out="$( cd "$FX" && bash "$IS" "$range" 2>"$SHIM4/long.err" )"; rc=$?
if [ "$rc" -ne 0 ] && grepq "$(cat "$SHIM4/long.err")" -F 'scratch copy of'; then pass "uncreatable scratch copy: exits $rc naming the file, not a short list at 0"; else fail "uncreatable scratch copy: rc=$rc err=$(cat "$SHIM4/long.err") out=$out"; fi

# --- 37c. an attribute committed in the head cannot narrow its own list ---------
# `git archive` applies the attributes of the tree it archives, and that tree is the
# PR's own head: working-tree-encoding=UTF-16LE on a suite would hand the narrowing
# a UTF-16 copy that holds no literal, and the suite would drop out of the list at
# exit 0. The suite's blob is committed first, the attribute in the same commit as
# the change, so the head holds both. The index is written directly: the worktree
# never has to hold a file git would convert.
enc_blob="$(printf 'bash "$d/lib/clo-lib.sh"\n' | git -C "$FX" hash-object -w --stdin)"
git -C "$FX" update-index --add --cacheinfo "100644,$enc_blob,scripts/test-enc.sh"
git -C "$FX" commit -q -m "chore: suite naming clo-lib.sh"
attr_blob="$(printf 'scripts/test-enc.sh working-tree-encoding=UTF-16LE\n' | git -C "$FX" hash-object -w --stdin)"
lib_blob="$( { git -C "$FX" show HEAD:scripts/lib/clo-lib.sh; printf '# changed\n'; } | git -C "$FX" hash-object -w --stdin)"
git -C "$FX" update-index --add --cacheinfo "100644,$attr_blob,.gitattributes"
git -C "$FX" update-index --cacheinfo "100644,$lib_blob,scripts/lib/clo-lib.sh"
git -C "$FX" update-index --force-remove -- "$LONGNAME"   # row 37b's file cannot be unpacked
git -C "$FX" commit -q -m "fix: change clo-lib.sh and set an encoding attribute on the suite"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$( cd "$FX" && bash "$IS" "$range" 2>"$SC/enc.err" )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-enc\.sh$'; then pass "a suite the head marks working-tree-encoding=UTF-16LE is still listed"; else fail "encoding attribute narrowed the list: rc=$rc out=$out err=$(head -c 400 "$SC/enc.err")"; fi

# The same attribute, in a .gitattributes committed as a symlink (mode 120000) whose
# target text is the attribute line: `git grep` over a tree skips a symlink blob, but
# git archive may still read it as attribute text.
sym_blob="$(printf 'scripts/test-enc.sh working-tree-encoding=UTF-16LE' | git -C "$FX" hash-object -w --stdin)"
lib_blob="$( { git -C "$FX" show HEAD:scripts/lib/clo-lib.sh; printf '# changed again\n'; } | git -C "$FX" hash-object -w --stdin)"
git -C "$FX" update-index --cacheinfo "120000,$sym_blob,.gitattributes"
git -C "$FX" update-index --cacheinfo "100644,$lib_blob,scripts/lib/clo-lib.sh"
git -C "$FX" commit -q -m "fix: change clo-lib.sh again, the attribute file now a symlink"
range="$(git -C "$FX" rev-parse HEAD~1)..$(git -C "$FX" rev-parse HEAD)"
out="$( cd "$FX" && bash "$IS" "$range" 2>"$SC/enc.err" )"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" '^scripts/test-enc\.sh$'; then pass "a suite a symlinked .gitattributes marks working-tree-encoding=UTF-16LE is still listed"; else fail "symlinked attribute file narrowed the list: rc=$rc out=$out err=$(head -c 400 "$SC/enc.err")"; fi

# --- 38. `SUITE <p> = CI` hands an untouched PR-CI suite on to CI -------------
# A fresh repo with real copies of run-shell-tests.sh (its SKIP_LIST gains one
# fixture suite) and suite-coverage.sh, so the pre-filter reads real tables.
CX="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$CX"' EXIT
(
    fixture_enter_git_init_dir "$CX" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkdir -p "$CX/scripts/ci" "$CX/scripts/handover" "$CX/scripts/lib"
awk '{print} $0 == "SKIP_LIST=\"" {print "scripts/test-cx-vm.sh  # fixture: drives a VM"}' \
    "$REPO_ROOT/scripts/ci/run-shell-tests.sh" > "$CX/scripts/ci/run-shell-tests.sh"
cp "$REPO_ROOT/scripts/handover/suite-coverage.sh" "$CX/scripts/handover/suite-coverage.sh"
printf '# lib\n' > "$CX/scripts/lib/cx-lib.sh"
for s in test-cx-a test-cx-b test-cx-c test-cx-vm; do printf 'bash "$d/lib/cx-lib.sh"\n' > "$CX/scripts/$s.sh"; done
printf "run('cx-lib.sh');\n" > "$CX/scripts/lib/cx.test.mjs"
git -C "$CX" add -A
git -C "$CX" commit -q -m "chore: base"
printf '# changed\n' >> "$CX/scripts/lib/cx-lib.sh"
printf '# changed\n' >> "$CX/scripts/test-cx-b.sh"
git -C "$CX" add -A
git -C "$CX" commit -q -m "fix: lib and one suite"
crange="$(git -C "$CX" rev-parse HEAD~1)..$(git -C "$CX" rev-parse HEAD)"
cx_check() { ( cd "$CX" && printf '%s\n' "$V_C" "$@" | bash "$IS" --check "$crange" 2>&1 ); }
V_A='SUITE scripts/test-cx-a.sh = CI'
V_B='SUITE scripts/test-cx-b.sh = PASS'
V_VM='SUITE scripts/test-cx-vm.sh = PASS'
V_JS='SUITE scripts/lib/cx.test.mjs = PASS'
V_C='SUITE scripts/test-cx-c.sh = PASS'
# T1: an untouched PR-CI test-*.sh given = CI is accepted and counted
out="$(cx_check "$V_A" "$V_B" "$V_VM" "$V_JS")"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -F 'impacted-suites: 5 impacted, 0 without a verdict, 1 to CI'; then pass "T1 = CI accepted for an untouched PR-CI suite (1 to CI)"; else fail "T1 = CI: rc=$rc out=$out"; fi
# T2: a SKIP_LIST suite given = CI is refused (DoD-2)
out="$(cx_check "$V_A" "$V_B" 'SUITE scripts/test-cx-vm.sh = CI' "$V_JS")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/test-cx-vm.sh (not run in CI (SKIP_LIST)'; then pass "T2 a SKIP_LIST suite given = CI is refused"; else fail "T2 SKIP_LIST = CI: rc=$rc out=$out"; fi
# T2b: a suite the PR changed given = CI is refused (DoD-2)
out="$(cx_check "$V_A" 'SUITE scripts/test-cx-b.sh = CI' "$V_VM" "$V_JS")"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/test-cx-b.sh (the PR changed it'; then pass "T2b a changed suite given = CI is refused"; else fail "T2b changed = CI: rc=$rc out=$out"; fi
# T3: a JS/TS suite given = CI is refused
out="$(cx_check "$V_A" "$V_B" "$V_VM" 'SUITE scripts/lib/cx.test.mjs = CI')"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/lib/cx.test.mjs (not a test-*.sh'; then pass "T3 a *.test.mjs given = CI is refused"; else fail "T3 mjs = CI: rc=$rc out=$out"; fi
# T4: HIMMEL_SUITES_LOCAL=1 turns = CI off (DoD-3)
out="$( cd "$CX" && printf '%s\n' "$V_A" "$V_B" "$V_C" "$V_VM" "$V_JS" | HIMMEL_SUITES_LOCAL=1 bash "$IS" --check "$crange" 2>&1 )"; rc=$?
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/test-cx-a.sh (HIMMEL_SUITES_LOCAL=1'; then pass "T4 HIMMEL_SUITES_LOCAL=1 refuses every = CI"; else fail "T4 local flag: rc=$rc out=$out"; fi
# T2c: a path suite-coverage.sh calls unknown (rc 3) is refused as unknown
mv "$CX/scripts/test-cx-a.sh" "$CX/test-cx-a.sh.off"
out="$(cx_check "$V_A" "$V_B" "$V_VM" "$V_JS")"; rc=$?
mv "$CX/test-cx-a.sh.off" "$CX/scripts/test-cx-a.sh"
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/test-cx-a.sh (unknown'; then pass "T2c a suite suite-coverage.sh calls unknown is refused"; else fail "T2c unknown: rc=$rc out=$out"; fi
# T2d: a truncated suite-coverage.sh answer (one line for two = CI paths) fails closed
cp "$CX/scripts/handover/suite-coverage.sh" "$CX/sc.real"
printf '#!/usr/bin/env bash\necho "scripts/test-cx-a.sh: runs in PR CI (cap 60s)"\n' > "$CX/scripts/handover/suite-coverage.sh"
out="$(cx_check "$V_A" "$V_B" "$V_VM" "$V_JS" 'SUITE scripts/test-cx-c.sh = CI')"; rc=$?
cp "$CX/sc.real" "$CX/scripts/handover/suite-coverage.sh"
if [ "$rc" -eq 1 ] && grepq "$out" -F 'impacted-suites: CI NOT ACCEPTED scripts/test-cx-c.sh (unknown' && ! grepq "$out" -F 'NOT ACCEPTED scripts/test-cx-a.sh'; then pass "T2d a path with no coverage line is refused as unknown"; else fail "T2d truncated coverage: rc=$rc out=$out"; fi

# --- --plan: the local/CI split is computed, not prose -------------
# A worker runs locally only the suite its PR changed (with the failing-first proof) and a
# suite CI cannot run (named reason); every other impacted suite is left to CI.
plan_cx() { ( cd "$CX" && bash "$IS" --plan "$crange" 2>&1 ); }
# P1: the suite the PR changed stays local and the plan says the failing-first proof is required
out="$(plan_cx)"; rc=$?
if [ "$rc" -eq 0 ] && grepq "$out" -F 'LOCAL scripts/test-cx-b.sh (changed: failing-first proof required)'; then pass "P1 a changed suite is planned LOCAL with the failing-first proof required"; else fail "P1 changed suite plan: rc=$rc out=$out"; fi
# P3: a suite CI cannot run stays local with a NAMED reason, a JS/TS suite too
if grepq "$out" -F 'LOCAL scripts/test-cx-vm.sh (not run in CI (SKIP_LIST)' && grepq "$out" -F 'LOCAL scripts/lib/cx.test.mjs (not a test-*.sh'; then pass "P3 a suite CI cannot run is planned LOCAL with its named reason"; else fail "P3 named reasons: out=$out"; fi
# P1b: untouched PR-CI suites go to CI, and the summary counts both sides
if grepq "$out" -F 'CI scripts/test-cx-a.sh' && grepq "$out" -F 'CI scripts/test-cx-c.sh' && grepq "$out" -F 'impacted-suites: plan 5 impacted, 3 local, 2 to CI'; then pass "P1b untouched PR-CI suites are planned CI (3 local, 2 to CI)"; else fail "P1b plan summary: out=$out"; fi
# P4: HIMMEL_SUITES_LOCAL=1 plans every suite local
out="$( cd "$CX" && HIMMEL_SUITES_LOCAL=1 bash "$IS" --plan "$crange" 2>&1 )"
if grepq "$out" -F 'impacted-suites: plan 5 impacted, 5 local, 0 to CI'; then pass "P4 HIMMEL_SUITES_LOCAL=1 plans every suite local"; else fail "P4 local flag plan: out=$out"; fi
# P2: a PR with many impacted suites (a changed shared lib, 14 callers, 1 changed suite) plans 5 or fewer local
CY="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$CX" "$CY"' EXIT
(
    fixture_enter_git_init_dir "$CY" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkdir -p "$CY/scripts/ci" "$CY/scripts/handover" "$CY/scripts/lib"
cp "$REPO_ROOT/scripts/ci/run-shell-tests.sh" "$CY/scripts/ci/run-shell-tests.sh"
cp "$REPO_ROOT/scripts/handover/suite-coverage.sh" "$CY/scripts/handover/suite-coverage.sh"
printf '# lib\n' > "$CY/scripts/lib/cy-lib.sh"
for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do printf 'bash "$d/lib/cy-lib.sh"\n' > "$CY/scripts/test-cy-$n.sh"; done
git -C "$CY" add -A
git -C "$CY" commit -q -m "chore: base"
printf '# changed\n' >> "$CY/scripts/lib/cy-lib.sh"
printf '# changed\n' >> "$CY/scripts/test-cy-1.sh"
git -C "$CY" add -A
git -C "$CY" commit -q -m "fix: lib and one suite"
yrange="$(git -C "$CY" rev-parse HEAD~1)..$(git -C "$CY" rev-parse HEAD)"
out="$( cd "$CY" && bash "$IS" --plan "$yrange" 2>&1 )"; rc=$?
n_local=$(grep -c '^LOCAL ' <<< "$out")
if [ "$rc" -eq 0 ] && [ "$n_local" -le 5 ] && [ "$n_local" -ge 1 ] && grepq "$out" -F 'impacted-suites: plan 14 impacted, 1 local, 13 to CI'; then pass "P2 a PR with 14 impacted suites plans 1 local and 13 to CI"; else fail "P2 many impacted: rc=$rc local=$n_local out=$out"; fi
# P5: --plan is a read mode: it refuses --check and a missing range
( cd "$CY" && bash "$IS" --plan --check "$yrange" >/dev/null 2>&1 ); rc=$?
if [ "$rc" -eq 2 ]; then pass "P5 --plan with --check is a usage error (rc 2)"; else fail "P5 --plan --check: rc=$rc"; fi

CL="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$FX" "$CX" "$CY" "$CL"' EXIT
(
    fixture_enter_git_init_dir "$CL" || exit 1
    git init -q
    git config user.email t@e
    git config user.name t
)
mkdir -p "$CL/scripts/lib"
for n in $(seq 1 400); do printf '# lib\n' > "$CL/scripts/lib/biglib-$n.sh"; done
for s in $(seq 1 900); do
    for l in $(seq 1 20); do printf 'x="$d/lib/biglib-%s.sh" # line %s of suite %s\n' $(( (s * 7 + l * 13) % 400 + 1 )) "$l" "$s"; done > "$CL/scripts/test-big-$s.sh"
done
git -C "$CL" add -A
git -C "$CL" commit -q -m "chore: base"
for n in $(seq 1 400); do printf '# changed\n' >> "$CL/scripts/lib/biglib-$n.sh"; done
git -C "$CL" add -A
git -C "$CL" commit -q -m "fix: every lib"
lrange="$(git -C "$CL" rev-parse HEAD~1)..$(git -C "$CL" rev-parse HEAD)"
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/timeout-bin.sh"
if [ -z "$_TIMEOUT_BIN" ]; then
    pass "L1 SKIP: no timeout binary to bound the read"
else
    l_start=$SECONDS
    l_bound=30
    [ "$(uname -s)" = Linux ] || l_bound=300
    out="$( cd "$CL" && "$_TIMEOUT_BIN" "$l_bound" bash "$IS" "$lrange" 2>/dev/null )"; rc=$?
    l_wall=$((SECONDS - l_start))
    l_want="$(for s in $(seq 1 900); do printf 'scripts/test-big-%s.sh\n' "$s"; done | LC_ALL=C sort)"
    l_got="$(LC_ALL=C sort <<< "$out")"
    if [ "$rc" -eq 0 ] && [ "$l_got" = "$l_want" ]; then pass "L1 a 900-suite range is read in ${l_wall}s inside the ${l_bound} s bound, with exactly the 900 suite names"; else fail "L1 large range: rc=$rc suites=$(grep -c . <<< "$out") wall=${l_wall}s (rc 124 = over the ${l_bound} s bound; first line: $(head -n 1 <<< "$out"))"; fi
fi

echo
if [ "$failures" -eq 0 ]; then echo "OK: all cases passed"; exit 0; fi
echo "FAIL: $failures case(s) failed"
exit 1
