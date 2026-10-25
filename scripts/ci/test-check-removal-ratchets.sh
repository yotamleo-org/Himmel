#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-check-removal-ratchets.sh — suite for check-removal-ratchets.sh.
#
# Lints the real tree, then runs each fixture row against a throwaway git repo
# holding a one-shot helper, a suite-tiers file, a pre-commit config and a
# workflow.
#
# Exit codes: 0 — all cases passed; 1 — at least one failed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/ci/check-removal-ratchets.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/removal-ratchets.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

echo "== repo: the real tree lints clean"
if bash "$GATE" > "$tmp/repo.out" 2>&1; then
  pass "no removal ratchet is a suite or wired into CI"
else
  fail "the real tree does not lint clean"
  head -20 "$tmp/repo.out"
fi

# mkrepo: one helper under scripts/one-shot/, wired nowhere. Each row then
# changes one thing and commits, because the gate reads tracked files only.
R="$tmp/r"
HELPER=scripts/one-shot/check-no-oldterm.sh
mkrepo() {
  rm -rf "$R"; mkdir -p "$R/scripts/ci" "$R/scripts/one-shot" "$R/scripts/lint" "$R/.github/workflows"
  git -C "$R" init -q
  printf '#!/usr/bin/env bash\ngit grep -q oldterm && exit 1\n' > "$R/$HELPER"
  printf '# tiers\nscripts/lint/test-other.sh\tpr\tstatic-gate\n' > "$R/scripts/ci/suite-tiers.tsv"
  printf '#!/usr/bin/env bash\n' > "$R/scripts/lint/test-other.sh"
  printf 'repos:\n  - repo: local\n    hooks:\n      - id: other\n        entry: bash scripts/lint/other.sh\n' > "$R/.pre-commit-config.yaml"
  printf 'jobs:\n  lint:\n    steps:\n      - run: bash scripts/lint/other.sh\n' > "$R/.github/workflows/ci.yml"
}
commit() {
  if ! { git -C "$R" add -A && git -C "$R" -c user.name=t -c user.email=t@t commit -qm fixture; }; then
    echo "FAIL: fixture commit failed" >&2; exit 1
  fi
}

# row <label> <want-rc> <want-text>
row() {
  bash "$GATE" --root "$R" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -ne "$2" ]; then fail "$1 -> expected exit $2 got $rc: $(head -3 "$tmp/out")"; return; fi
  if [ -n "$3" ] && ! grep -qF -- "$3" "$tmp/out"; then fail "$1 -> output lacks '$3': $(head -3 "$tmp/out")"; return; fi
  pass "$1 -> exit $2"
}

echo "== fixture rows"
mkrepo; commit
row "GREEN: a one-shot helper wired nowhere" 0 ""

mkrepo; printf '%s\tpr\tstatic-gate\n' "$HELPER" >> "$R/scripts/ci/suite-tiers.tsv"; commit
row "RED: a one-shot helper registered at tier pr" 1 "one-shot helper has a suite-tiers row (tier pr): $HELPER"

mkrepo; printf '%s\tlocal\tone-shot\n' "$HELPER" >> "$R/scripts/ci/suite-tiers.tsv"; commit
row "RED: a one-shot helper registered at tier local" 1 "one-shot helper has a suite-tiers row (tier local): $HELPER"

mkrepo; printf '#!/usr/bin/env bash\n' > "$R/scripts/lint/test-no-oldterm.sh"; commit
row "RED: a test-no-*.sh suite with no tier row" 1 "removal ratchet named as a suite (test-no-*.sh): scripts/lint/test-no-oldterm.sh"

mkrepo; git -C "$R" config core.quotePath true; printf '#!/usr/bin/env bash\n' > "$R/scripts/lint/test-no-café.sh"; commit
row "RED: a test-no-*.sh with a non-ASCII name (git quotes it by default)" 1 "removal ratchet named as a suite (test-no-*.sh): scripts/lint/test-no-café.sh"

mkrepo; printf '#!/usr/bin/env bash\n' > "$R/scripts/lint/test-no-oldterm.sh"
printf 'scripts/lint/test-no-oldterm.sh\tlocal\tone-shot\n' >> "$R/scripts/ci/suite-tiers.tsv"; commit
row "RED: a test-no-*.sh suite at tier local" 1 "removal ratchet named as a suite (test-no-*.sh): scripts/lint/test-no-oldterm.sh"

mkrepo; printf '#!/usr/bin/env bash\n' > "$R/scripts/one-shot/test-oldterm.sh"; commit
row "RED: a test-*.sh under the helpers dir (the runner discovers it)" 1 "test-*.sh under scripts/one-shot/ is a suite the runner discovers: scripts/one-shot/test-oldterm.sh"

mkrepo; printf '#!/usr/bin/env bash\n# selector: tree-scan\ngit grep -q oldterm && exit 1\n' > "$R/$HELPER"; commit
row "RED: a one-shot helper with the tree-scan selector" 1 "one-shot helper carries '# selector: tree-scan': $HELPER"

mkrepo; printf '      - id: ratchet\n        entry: bash %s\n' "$HELPER" >> "$R/.pre-commit-config.yaml"; commit
row "RED: a one-shot helper in a pre-commit hook" 1 "one-shot helper wired in .pre-commit-config.yaml: $HELPER"

mkrepo; printf '      - run: cd scripts/one-shot && bash check-no-oldterm.sh\n' >> "$R/.github/workflows/ci.yml"; commit
row "RED: a one-shot helper in a workflow step (by basename)" 1 "one-shot helper wired in .github/workflows/ci.yml: $HELPER"

mkrepo; commit; rm "$R/.github/workflows/ci.yml"
row "RED: a tracked workflow the gate cannot read fails closed" 1 "cannot read $R/.github/workflows/ci.yml"

mkrepo; rm "$R/scripts/ci/suite-tiers.tsv"; commit
row "RED: a missing suite-tiers.tsv fails closed" 1 "cannot read $R/scripts/ci/suite-tiers.tsv"

mkrepo; printf '#!/usr/bin/env bash\n' > "$R/scripts/lint/test-no-other.sh"
row "GREEN: an untracked test-no-*.sh is not the tree's yet" 0 ""

mkrepo; rm -rf "$R/scripts/one-shot"; commit
row "GREEN: no helpers dir at all" 0 ""

bash "$GATE" --root > "$tmp/out" 2>&1; rc=$?
if [ "$rc" -eq 2 ] && grep -qF -- usage "$tmp/out"; then pass "RED: --root with no value -> usage, exit 2"; else fail "--root with no value -> rc=$rc, expected usage and exit 2"; fi

echo "== $failures failure(s)"
[ "$failures" -eq 0 ]
