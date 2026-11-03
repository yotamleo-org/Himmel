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

echo "== R runner classification =="
# shellcheck disable=SC2016 # literal runner source lines
# mkrunnerrepo <dir> <header> — a runner whose case header is <header>, then a branch adding scripts/foo/test-y.sh
mkrunnerrepo() {
  local R="$1" hdr="$2"
  mkdir -p "$R/scripts/testing" "$R/scripts/handover" "$R/scripts/ci"
  cp "$CHECK" "$R/scripts/testing/check-added-unwired.sh"
  cp "$HERE/../handover/suite-coverage.sh" "$R/scripts/handover/suite-coverage.sh"
  {
    echo 'SUITE_TIMEOUT=$(_suite_num SUITE_TIMEOUT "${SUITE_TIMEOUT:-600}" 600)'
    echo '_suite_timeout_for() {'; echo '  case "${1#./}" in'
    printf '%s\n' "$hdr"; echo "      printf '1' ;;"
    echo '    *)'; echo "      printf '%s' \"\$SUITE_TIMEOUT\" ;;"; echo '  esac'; echo '}'
    echo 'SKIP_LIST="'; echo 'scripts/zzz/test-z.sh  # x'; echo '"'
    echo 'SUITE_TIER_DEFAULT="'; echo 'scripts/zzz/test-z.sh  extended  # x'; echo '"'
  } > "$R/scripts/ci/run-shell-tests.sh"
  git init -q -b main "$R" || exit 1
  git -C "$R" config user.email t@t || exit 1
  git -C "$R" config user.name t || exit 1
  git -C "$R" add -A && git -C "$R" commit -q -m "chore: base" || exit 1
  git -C "$R" checkout -q -b feat/x || exit 1
  mkdir -p "$R/scripts/foo" && printf '#!/usr/bin/env bash\n' > "$R/scripts/foo/test-y.sh" || exit 1
  git -C "$R" add -A && git -C "$R" commit -q -m "feat: add suite" || exit 1
}
R="$T/runner-ok"; mkrunnerrepo "$R" '    scripts/foo/test-y.sh)'
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD scripts/foo/test-y.sh 2>&1) || rc=$?
{ [ "$rc" -eq 0 ] && grep -qx 'ADDED-UNWIRED OK' <<<"$out"; } \
  && ok "R1 a suite the runner classifies is wired" || no "R1 (rc=$rc): $out"

R="$T/runner-bad"; mkrunnerrepo "$R" '    scripts/foo/test-y.sh)  # nightly only'
rc=0; out=$(cd "$R" && bash scripts/testing/check-added-unwired.sh HEAD scripts/foo/test-y.sh 2>&1) || rc=$?
{ [ "$rc" -eq 1 ] && grep -q 'UNWIRED scripts/foo/test-y.sh (suite)' <<<"$out" && grep -q 'rc=2: .*unrecognised line' <<<"$out"; } \
  && ok "R2 a helper error that says 'nightly only' is not read as wired, and its line is shown" || no "R2 (rc=$rc): $out"

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
