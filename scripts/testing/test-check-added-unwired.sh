#!/usr/bin/env bash
# Tests for check-added-unwired.sh's test-*.sh branch: a suite outside himmel's scan
# roots counts as wired when a .github/workflows run step names its repo path (an
# adopter repo runs its suites from CI, not from scripts/ci/run-shell-tests.sh).
#
# Usage: bash scripts/testing/test-check-added-unwired.sh
# shellcheck disable=SC2015  # ok/no never fail, so A && ok || no is a safe if/else here
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$HERE/check-added-unwired.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/check-added-unwired.XXXXXX")" || exit 1
[ -d "$T" ] || exit 1
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { echo "  PASS  $1"; pass=$((pass+1)); }
no() { echo "  FAIL  $1"; fail=$((fail+1)); }

WF_RUN='name: ci
on: push
jobs:
  wyoming:
    runs-on: ubuntu-latest
    steps:
      - run: bash wyoming/test-x.sh'
WF_OTHER='name: ci
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hello'
WF_ENV='name: ci
on: push
jobs:
  wyoming:
    runs-on: ubuntu-latest
    steps:
      - name: x
        env:
          run: bash wyoming/test-x.sh'

# mkrepo <dir> <workflow-or-empty> — a base commit, then a branch adding wyoming/test-x.sh
# (outside the scan roots, no scripts/ci/run-shell-tests.sh) and the workflow when given
mkrepo() {
  local R="$1" wf="$2" sub="${3:-}"
  mkdir -p "$R/scripts/testing" "$R/wyoming"
  cp "$CHECK" "$R/scripts/testing/check-added-unwired.sh"
  git init -q -b main "$R" || exit 1
  git -C "$R" config user.email t@t || exit 1
  git -C "$R" config user.name t || exit 1
  git -C "$R" add -A && git -C "$R" commit -q -m "chore: base" || exit 1
  git -C "$R" checkout -q -b feat/x || exit 1
  printf '#!/usr/bin/env bash\n' > "$R/wyoming/test-x.sh" || exit 1
  if [ -n "$wf" ]; then
    mkdir -p "$R/.github/workflows/$sub" || exit 1
    printf '%s\n' "$wf" > "$R/.github/workflows/$sub/ci.yml" || exit 1
  fi
  git -C "$R" add -A && git -C "$R" commit -q -m "feat: add wyoming suite" || exit 1
}

echo "== W workflow run-step wiring =="
R="$T/wired"; mkrepo "$R" "$WF_RUN"
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD wyoming/test-x.sh 2>&1) || rc=$?
{ [ "$rc" -eq 0 ] && grep -qx 'ADDED-UNWIRED OK' <<<"$out"; } \
  && ok "W1 a suite a workflow run step names is wired" || no "W1 not wired (rc=$rc): $out"

R="$T/unwired"; mkrepo "$R" "$WF_OTHER"
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD wyoming/test-x.sh 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED wyoming/test-x.sh (suite)' <<<"$out"; } \
  && ok "W2 a suite no workflow names is still UNWIRED" || no "W2 (rc=$rc): $out"

R="$T/env-key"; mkrepo "$R" "$WF_ENV"
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD wyoming/test-x.sh 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED wyoming/test-x.sh (suite)' <<<"$out"; } \
  && ok "W3 a run key under env: is not a run step" || no "W3 (rc=$rc): $out"

R="$T/examples"; mkrepo "$R" "$WF_RUN" examples
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD wyoming/test-x.sh 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED wyoming/test-x.sh (suite)' <<<"$out"; } \
  && ok "W4 a workflow under .github/workflows/examples/ never runs" || no "W4 (rc=$rc): $out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
