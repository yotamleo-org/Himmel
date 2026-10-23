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

# lock_versions <lockfile> <package>: every resolved version of <package>, hoisted or
# nested, one per line. Exits non-zero when the lockfile cannot be read or parsed, or
# when a matching entry carries no version (a link entry), so it cannot be checked.
lock_versions() {
  node -e 'const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const n = "node_modules/" + process.argv[2]; for (const [k, v] of Object.entries(l.packages)) if (k === n || k.endsWith("/" + n)) { if (!v.version) process.exit(1); console.log(v.version) }' "$1" "$2"
}

# version_ge <have> <want>: 0 when the dotted numeric <have> is >= <want> (bash 3.2, no sort -V).
version_ge() {
  local IFS=. i a b
  local -a have want
  read -r -a have <<< "$1"
  read -r -a want <<< "$2"
  for i in 0 1 2; do
    a="${have[i]:-0}"
    b="${want[i]:-0}"
    case "$a$b" in *[!0-9]*) return 1 ;; esac
    [ "$a" -gt "$b" ] && return 0
    [ "$a" -lt "$b" ] && return 1
  done
  return 0
}

# meets_floor <lockfile> <package> <floor>: 0 when every resolved copy is >= floor,
# 1 when one is below it, 2 when the lookup failed or found no copy at all.
meets_floor() {
  local versions v
  versions=$(lock_versions "$1" "$2" 2>/dev/null) || return 2
  [ -n "$versions" ] || return 2
  while IFS= read -r v; do
    v="${v%%+*}"
    version_ge "${v%%-*}" "$3" || return 1
    # a prerelease of the floor itself ranks below it under SemVer
    [ "$v" = "${v%%-*}" ] || [ "${v%%-*}" != "$3" ] || return 1
  done <<< "$versions"
  return 0
}

meets_floor "$FIX/site-package-lock.pre-fix.json" postcss-selector-parser 7.1.6
case $? in
  1) pass "pre-fix fixture is flagged below the 7.1.6 floor" ;;
  0) fail "pre-fix fixture is not flagged: it resolves postcss-selector-parser at or above 7.1.6" ;;
  *) fail "pre-fix fixture lookup failed: missing, malformed or no postcss-selector-parser entry" ;;
esac

meets_floor "$REPO_ROOT/site/package-lock.json" postcss-selector-parser 7.1.6
case $? in
  0) pass "site/package-lock.json resolves postcss-selector-parser >= 7.1.6 (GHSA-rj75-hqrm-r3gf)" ;;
  1) fail "site/package-lock.json resolves postcss-selector-parser $(lock_versions "$REPO_ROOT/site/package-lock.json" postcss-selector-parser | tr '\n' ' ')below 7.1.6 (GHSA-rj75-hqrm-r3gf)" ;;
  *) fail "site/package-lock.json lookup failed: unreadable or no postcss-selector-parser entry" ;;
esac

# every LGPL package the site lockfile pulls must be recorded in the license audit
lgpl_pkgs=$(node -e 'const l = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); for (const [k, v] of Object.entries(l.packages)) if (/LGPL/.test(v.license || "")) console.log(k.replace(/^.*node_modules\//, ""))' "$REPO_ROOT/site/package-lock.json" | sed -E 's#^(@img/sharp(-libvips)?)-.*#\1#' | sort -u)
missing=""
for p in $lgpl_pkgs; do
  grep -qF "\`$p" "$REPO_ROOT/docs/third-party-licenses.md" || missing="$missing $p"
done
if [ -z "$lgpl_pkgs" ]; then
  pass "site/package-lock.json carries no LGPL package"
elif [ -z "$missing" ]; then
  pass "every LGPL family in site/package-lock.json is recorded in docs/third-party-licenses.md"
else
  fail "LGPL packages in site/package-lock.json missing from docs/third-party-licenses.md:$missing"
fi

if [ "$failures" -eq 0 ]; then
  echo "all cases passed"
  exit 0
fi
echo "$failures case(s) failed"
exit 1
