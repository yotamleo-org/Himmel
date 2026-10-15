#!/usr/bin/env bash
# shellcheck disable=SC2016  # fixture suite bodies are single-quoted on purpose: their $vars must stay literal
# scripts/ci/test-run-shell-tests-impacted.sh — the run-shell-tests.sh
# --impacted <base>..<head> cases: the one-shot runner for the
# list scripts/cr/impacted-suites.sh prints.
#
# The runner cds to its own checkout and shells out to THAT checkout's
# impacted-suites.sh, so each case runs a COPY of the runner inside a throwaway
# git repo shaped like PR #2261: uninstall-plugins.sh changed, and the suite
# that drives it (test-uninstall.sh) is one directory away from it.
#
#   24a  the impacted suite RUNS, the unrelated one is [SKIP]ped "impacted:"
#   24b  a suite outside the scan root is NOTEd, not silently dropped
#   24c  an impacted suite that FAILS makes the run rc 1 (no swallowed verdict)
#   24d  a range that does not resolve is REFUSED rc 2 and runs nothing —
#        never read as "nothing impacted"
#   24e  a docs-only range is a clean rc 0 that says "0 impacted", runs nothing
#   24f  --list plans only the impacted suite and runs nothing
#   24g  --impacted with no value is REFUSED rc 2
#
# Platform guard: bash-only, like every suite in this family, and no .ps1
# twin — it runs under Git Bash on Windows as well as Linux.
#
# Usage: bash scripts/ci/test-run-shell-tests-impacted.sh
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

# shellcheck source=run-shell-tests-fixture.sh
# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/run-shell-tests-fixture.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$RST_FIXTURE_DIR/../lib/fixture-tempdir.sh"

SRC_ROOT="$(cd "$RST_FIXTURE_DIR/../.." && pwd)"
IS_SRC="$SRC_ROOT/scripts/cr/impacted-suites.sh"
if [ ! -f "$IS_SRC" ]; then
  fail "impacted-suites.sh not found at $IS_SRC"
  rst_tally
fi

SB="$(fixture_mktemp_dir)" || exit 1
trap 'rm -rf "$SB" "$SUITE_LOCK_SANDBOX"' EXIT

# --- sandbox repo ---------------------------------------------------------
# The helper requires an EMPTY directory, so the repo is initialised first.
(
  fixture_enter_git_init_dir "$SB" || exit 1
  git init -q
  git config user.email t@e
  git config user.name t
) || exit 1
# The runner's own sourced libraries come along; nothing else of himmel does.
mkdir -p "$SB/scripts/ci" "$SB/scripts/lib" "$SB/scripts/cr" \
         "$SB/scripts/machine-setup" "$SB/tests" "$SB/docs"
cp "$RUNNER" "$SB/scripts/ci/run-shell-tests.sh"
# Every chokepoint fails closed without its seam-guard lib.
cp "$SRC_ROOT/scripts/lib/chokepoint-seam-guard.sh" "$SB/scripts/lib/chokepoint-seam-guard.sh"
cp "$IS_SRC" "$SB/scripts/cr/impacted-suites.sh"
# impacted-suites.sh sources its anchor hand-off first.
cp "$SRC_ROOT/scripts/cr/anchor-handoff.sh" "$SB/scripts/cr/anchor-handoff.sh"
for lib in proc-tree.sh git-test-env.sh override-env.sh runtime-preflight.sh suite-semaphore.sh; do
  cp "$SRC_ROOT/scripts/lib/$lib" "$SB/scripts/lib/$lib"
done

IMP_LOG="$SB/ran.log"
export IMP_LOG
# A suite appends its own name, then exits with $IMP_FAIL when it is the one
# being failed. The names are what the cases read back.
mksuite() {
  printf '#!/usr/bin/env bash\n%s\necho %s >> "$IMP_LOG"\n%s\n' "${3:-:}" "$2" "${4:-exit 0}" > "$SB/$1"
}
printf '# uninstall-plugins\n' > "$SB/scripts/machine-setup/uninstall-plugins.sh"
mksuite scripts/test-uninstall.sh uninstall '# drives machine-setup/uninstall-plugins.sh' \
  '[ "${IMP_FAIL:-0}" = 1 ] && exit 1; exit 0'
mksuite scripts/test-unrelated.sh unrelated '# drives nothing that changed'
mksuite tests/test-outside.sh outside '# also drives uninstall-plugins.sh'
printf '# doc\n' > "$SB/docs/note.md"
git -C "$SB" add -A
git -C "$SB" commit -q -m "chore: base"
BASE=$(git -C "$SB" rev-parse HEAD)
printf 'echo changed\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" commit -q -am "fix: uninstall-plugins"
CODE_RANGE="$BASE..$(git -C "$SB" rev-parse HEAD)"
printf '# changed\n' >> "$SB/docs/note.md"
git -C "$SB" commit -q -am "docs: note"
DOCS_RANGE="$(git -C "$SB" rev-parse HEAD~1)..$(git -C "$SB" rev-parse HEAD)"

IMPRUN="$SB/scripts/ci/run-shell-tests.sh"
: > "$IMP_LOG"

# --- 24a. the far-away suite runs; the unrelated one is skipped ------------
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24a: --impacted runs test-uninstall.sh and nothing else (rc 0)"
else
  fail "24a: rc=$rc ran='$ran' output: $out"
fi
if grepq "$out" '\[SKIP\].*test-unrelated\.sh.*impacted:'; then
  pass "24a: the unrelated suite is [SKIP]ped with an 'impacted:' reason"
else
  fail "24a: no impacted-skip line for test-unrelated.sh: $out"
fi

# --- 24b. a suite outside the scan root is named, not dropped --------------
if grepq "$out" 'NOTE: impacted suite tests/test-outside\.sh is outside scan root'; then
  pass "24b: an impacted suite outside the scan root is NOTEd"
else
  fail "24b: no outside-scan-root NOTE: $out"
fi

# --- 24c. an impacted suite that fails fails the run ------------------------
: > "$IMP_LOG"
out=$(IMP_FAIL=1 bash "$IMPRUN" --scan-repo-of-script --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
expect_ran=$(printf 'uninstall\nuninstall')  # HIMMEL-5116: a failed suite is re-run once
if [ "$rc" -eq 1 ] && [ "$ran" = "$expect_ran" ]; then
  pass "24c: a failing impacted suite RAN (twice: one retry) and fails the run -> rc 1"
else
  fail "24c: rc=$rc ran='$ran' output: $out"
fi

# --- 24d. an unresolvable range is refused, never "nothing impacted" --------
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted nope..alsonope 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 2 ] && [ -z "$ran" ]; then
  pass "24d: unresolvable range -> rc 2, no suite ran"
else
  fail "24d: rc=$rc ran='$ran' output: $out"
fi

# --- 24e. docs-only range: a clean, stated zero ----------------------------
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$DOCS_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" '0 impacted shell suites'; then
  pass "24e: docs-only range -> rc 0, '0 impacted', nothing ran"
else
  fail "24e: rc=$rc ran='$ran' output: $out"
fi

# --- 24f. --list plans only the impacted suite, runs nothing ----------------
out=$(bash "$IMPRUN" --scan-repo-of-script --list --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" 'test-uninstall\.sh' \
   && grepq "$out" '\[SKIP\].*test-unrelated\.sh'; then
  pass "24f: --list --impacted plans the impacted suite and runs nothing"
else
  fail "24f: rc=$rc ran='$ran' output: $out"
fi

# --- 24g. a missing value is refused ---------------------------------------
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "24g: --impacted with no value -> rc 2"; else fail "24g: rc=$rc output: $out"; fi

# --- 24h-24l. --only-list: the macOS POC suite filter ------------------------
printf '# only the unrelated suite\nscripts/test-unrelated.sh  # why\n\n' > "$SB/only-unrelated.txt"
printf 'scripts/test-uninstall.sh\nscripts/test-unrelated.sh\n' > "$SB/only-both.txt"
printf '# nothing but comments\n\n' > "$SB/only-empty.txt"

: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-unrelated.txt" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "unrelated" ] && grepq "$out" '\[SKIP\].*test-uninstall\.sh.*--only-list'; then
  pass "24h: --only-list runs the listed suite only; the rest is [SKIP]ped 'not in --only-list'"
else
  fail "24h: rc=$rc ran='$ran' output: $out"
fi

: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-unrelated.txt" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" '0 impacted suites in --only-list'; then
  pass "24i: impacted suites all outside the list -> rc 0, stated zero, nothing ran"
else
  fail "24i: rc=$rc ran='$ran' output: $out"
fi

: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-both.txt" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24j: --impacted with --only-list runs the intersection only"
else
  fail "24j: rc=$rc ran='$ran' output: $out"
fi

: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/nope.txt" 2>&1); rc=$?
out2=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-empty.txt" 2>&1); rc2=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 2 ] && [ "$rc2" -eq 2 ] && [ -z "$ran" ]; then
  pass "24k: a missing or empty --only-list is refused rc 2, nothing ran"
else
  fail "24k: rc=$rc rc2=$rc2 ran='$ran' output: $out / $out2"
fi

out=$(bash "$IMPRUN" --scan-repo-of-script --only-list 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "24l: --only-list with no value -> rc 2"; else fail "24l: rc=$rc output: $out"; fi

# 24m: a grep that ERRORS (rc 2) in the --only-list intersection is a refusal, never "0 impacted suites".
REAL_GREP=$(command -v grep)
mkdir -p "$SB/fakebin"
printf '#!/bin/sh\ncase "$*" in *-Fxf*) exit 2;; esac\nexec %s "$@"\n' "$REAL_GREP" > "$SB/fakebin/grep"
chmod +x "$SB/fakebin/grep"
: > "$IMP_LOG"
out=$(PATH="$SB/fakebin:$PATH" bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-both.txt" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 2 ] && [ -z "$ran" ] && ! grepq "$out" '0 impacted suites in --only-list'; then
  pass "24m: a failing grep in the intersection -> rc 2, not a vacuous green"
else
  fail "24m: rc=$rc ran='$ran' output: $out"
fi

# 24n: a CRLF list names the same suites as an LF one.
printf 'scripts/test-uninstall.sh\r\nscripts/test-unrelated.sh\r\n' > "$SB/only-crlf.txt"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --only-list "$SB/only-crlf.txt" --impacted "$CODE_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24n: a CRLF --only-list selects the same suite as an LF one"
else
  fail "24n: rc=$rc ran='$ran' output: $out"
fi

# 24o: a merge-forward of main must not widen the range. Main moves on from BASE
# (mainthing.sh + its suite), the PR branch merges it in, and the caller passes
# the merge's first parent as the base: the impacted set must still be the PR's own.
printf '# mainthing\n' > "$SB/scripts/lib/mainthing.sh"
mksuite scripts/test-mainthing.sh mainthing '# drives lib/mainthing.sh'
P0=$(git -C "$SB" rev-parse HEAD)
git -C "$SB" checkout -q -b mainline "$BASE"
git -C "$SB" add -A
git -C "$SB" commit -q -m "feat: mainthing"
git -C "$SB" update-ref refs/remotes/origin/main "$(git -C "$SB" rev-parse HEAD)"
git -C "$SB" checkout -q -b pr "$P0"
git -C "$SB" merge -q --no-edit mainline
FWD_RANGE="$(git -C "$SB" rev-parse HEAD^1)..$(git -C "$SB" rev-parse HEAD)"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$FWD_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24o: a merge-forward range runs the PR's own suites only, not what main merged"
else
  fail "24o: rc=$rc ran='$ran' output: $out"
fi

# 24p: a comment-only edit of a changed script selects no suite and is named;
# a comment edit next to a code edit in the same range still selects.
git -C "$SB" checkout -q "$P0"
git -C "$SB" checkout -q -b cmt
printf '# just a comment\n\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" commit -q -am "docs: comment"
CMT_RANGE="$P0..$(git -C "$SB" rev-parse HEAD)"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$CMT_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ -z "$ran" ] && grepq "$out" 'SKIP comment-only scripts/machine-setup/uninstall-plugins\.sh'; then
  pass "24p: a comment-only edit runs no suite and is named 'SKIP comment-only'"
else
  fail "24p: rc=$rc ran='$ran' output: $out"
fi
printf 'echo code\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" commit -q -am "fix: code"
MIX_RANGE="$P0..$(git -C "$SB" rev-parse HEAD)"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$MIX_RANGE" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24p: a range with a real code edit still runs the driving suite"
else
  fail "24p: rc=$rc ran='$ran' output: $out"
fi

# 24q: a `#` line inside a heredoc is data, and a mode-only change is not a
# comment: neither may hide the driving suite.
git -C "$SB" checkout -q "$P0"
git -C "$SB" checkout -q -b hd
printf 'cat <<EOF\ndata\nEOF\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" commit -q -am "feat: heredoc"
HD0=$(git -C "$SB" rev-parse HEAD)
printf '# inside\n' > "$SB/hd.tmp"
sed '2i # inside' "$SB/scripts/machine-setup/uninstall-plugins.sh" > "$SB/hd.tmp"
cp "$SB/hd.tmp" "$SB/scripts/machine-setup/uninstall-plugins.sh"
rm -f "$SB/hd.tmp"
git -C "$SB" commit -q -am "docs: heredoc-adjacent comment"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$HD0..$(git -C "$SB" rev-parse HEAD)" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24q: a comment edit in a file with a heredoc still selects the suite"
else
  fail "24q: rc=$rc ran='$ran' output: $out"
fi
MD0=$(git -C "$SB" rev-parse HEAD)
git -C "$SB" update-index --chmod=+x scripts/machine-setup/uninstall-plugins.sh
git -C "$SB" commit -q -m "chore: mode"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$MD0..$(git -C "$SB" rev-parse HEAD)" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24q: a mode-only change still selects the suite"
else
  fail "24q: rc=$rc ran='$ran' output: $out"
fi

# 24r: a comment edit PLUS a mode change is not comment-only.
git -C "$SB" checkout -q "$P0"
git -C "$SB" checkout -q -b cm
printf '# only a comment\n' >> "$SB/scripts/machine-setup/uninstall-plugins.sh"
git -C "$SB" update-index --chmod=+x scripts/machine-setup/uninstall-plugins.sh
git -C "$SB" commit -q -am "chore: comment and mode"
: > "$IMP_LOG"
out=$(bash "$IMPRUN" --scan-repo-of-script --impacted "$P0..$(git -C "$SB" rev-parse HEAD)" 2>&1); rc=$?
ran=$(cat "$IMP_LOG")
if [ "$rc" -eq 0 ] && [ "$ran" = "uninstall" ]; then
  pass "24r: a comment edit with a mode change still selects the suite"
else
  fail "24r: rc=$rc ran='$ran' output: $out"
fi

rst_tally
