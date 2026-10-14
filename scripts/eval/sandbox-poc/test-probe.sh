#!/usr/bin/env bash
# scripts/eval/sandbox-poc/test-probe.sh - suite for probe.sh.
# Rows: a RED control (expect=blocked against an UNSANDBOXED run must fail on
# every escape row), the open control (expect=open unsandboxed all PASS), and,
# when bubblewrap can make a user namespace here, the same escape rows under a
# real bwrap bind layout (the kernel mechanism the Claude Code sandbox uses).
set -u
# CI's git has no template dir, so a fresh repo has no .git/hooks: keep that case covered
export GIT_TEMPLATE_DIR=/nonexistent

HERE="$(cd "$(dirname "$0")" && pwd)"
PROBE="$HERE/probe.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/sandbox-poc-test.XXXXXX")" || { echo "test-probe: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) pass "$1";; *) fail "$1: '$3' not in '$2'";; esac; }

# 1. setup builds the fixture and prints its root
ROOT="$TMP/root"
bash "$PROBE" setup "$ROOT" >/dev/null 2>&1
eq "setup: token fixture" "$(cat "$ROOT/home/.config/himmel/token" 2>/dev/null)" "SECRET"
eq "setup: verdicts fixture" "$(cat "$ROOT/handovers/u/verdicts/a.txt" 2>/dev/null)" "v1"

# 2. RED control: nothing is sandboxed, so expect=blocked must FAIL each escape row
out=$(bash "$PROBE" run "$ROOT" --expect blocked 2>&1); rc=$?
eq "red control: rc nonzero" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
for r in R1-read-cfg R2-write-verdicts R3-script-file R4-option-write R5-write-outside R6-anchor-script; do
  has "red control: $r FAIL" "$out" "ROW $r FAIL"
done

# 3. open control: unsandboxed expect=open passes everything
bash "$PROBE" setup "$ROOT" >/dev/null 2>&1
out=$(bash "$PROBE" run "$ROOT" --expect open --expect-sock open 2>&1); rc=$?
eq "open control: rc 0" "$rc" "0"
for r in R1-read-cfg R2-write-verdicts R3-script-file R4-option-write R5-write-outside R6-anchor-script C1-git-commit C2-git-worktree-push C3-gh-reach C4-node C5-bun U1-unix-socket; do
  case "$out" in *"ROW $r PASS"*|*"ROW $r SKIP"*) pass "open control: $r";; *) fail "open control: $r in: $out";; esac
done

# 4. real kernel isolation (skipped when bwrap cannot create a userns)
if command -v bwrap >/dev/null 2>&1 && bwrap --ro-bind / / true >/dev/null 2>&1; then
  bash "$PROBE" setup "$ROOT" >/dev/null 2>&1
  out=$(bwrap --dev-bind / / \
    --ro-bind "$ROOT/handovers/u/verdicts" "$ROOT/handovers/u/verdicts" \
    --ro-bind "$ROOT/anchor" "$ROOT/anchor" \
    --ro-bind "$ROOT/home" "$ROOT/home" \
    --tmpfs "$ROOT/home/.config/himmel" \
    bash "$PROBE" run "$ROOT" --expect blocked --expect-sock open 2>&1); rc=$?
  has "bwrap: R1 blocked" "$out" "ROW R1-read-cfg PASS"
  has "bwrap: R2 blocked" "$out" "ROW R2-write-verdicts PASS"
  has "bwrap: R3 script-file blocked" "$out" "ROW R3-script-file PASS"
  has "bwrap: R4 option-write blocked" "$out" "ROW R4-option-write PASS"
  has "bwrap: R5 outside blocked" "$out" "ROW R5-write-outside PASS"
  has "bwrap: R6 anchor script blocked" "$out" "ROW R6-anchor-script PASS"
  has "bwrap: C1 git still works" "$out" "ROW C1-git-commit PASS"
  eq "bwrap: rc 0" "$rc" "0"
else
  echo "SKIP bwrap rows (no user namespace)"
fi

echo "---"; echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
