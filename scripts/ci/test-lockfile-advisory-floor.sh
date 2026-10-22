#!/usr/bin/env bash
# Test that the docs-site lockfile resolves postcss-selector-parser at or above the
# release that fixes GHSA-rj75-hqrm-r3gf.
#
# The fixture under test-lockfile-advisory-floor-fixtures/ is the verbatim pre-fix
# node_modules entries of site/package-lock.json (as of b5e4ac4a2), so the floor
# check is proven against what the real lockfile held, not a hand-written look-alike.
#
# Usage: bash scripts/ci/test-lockfile-advisory-floor.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIX="$HERE/test-lockfile-advisory-floor-fixtures"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# lock_version <lockfile> <package>: the resolved version of node_modules/<package>.
lock_version() {
  node -e 'const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const p = l.packages["node_modules/" + process.argv[2]]; process.stdout.write(p ? p.version : "")' "$1" "$2"
}

# meets_floor <lockfile> <package> <floor>: 0 when the resolved version is >= floor.
meets_floor() {
  local have
  have=$(lock_version "$1" "$2")
  [ -n "$have" ] || return 1
  [ "$(printf '%s\n%s\n' "$3" "$have" | sort -V | head -n 1)" = "$3" ]
}

if meets_floor "$FIX/site-package-lock.pre-fix.json" postcss-selector-parser 7.1.6; then
  fail "pre-fix fixture (postcss-selector-parser $(lock_version "$FIX/site-package-lock.pre-fix.json" postcss-selector-parser)) is flagged below the 7.1.6 floor"
else
  pass "pre-fix fixture is flagged below the 7.1.6 floor"
fi

if meets_floor "$REPO_ROOT/site/package-lock.json" postcss-selector-parser 7.1.6; then
  pass "site/package-lock.json resolves postcss-selector-parser >= 7.1.6 (GHSA-rj75-hqrm-r3gf)"
else
  fail "site/package-lock.json resolves postcss-selector-parser $(lock_version "$REPO_ROOT/site/package-lock.json" postcss-selector-parser), below 7.1.6 (GHSA-rj75-hqrm-r3gf)"
fi

if [ "$failures" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$failures case(s) failed"
exit 1
