#!/usr/bin/env bash
# Test for scripts/ci/check-manifest-coverage.sh.
#
# The pre-fix row runs the lint on dependabot.yml as it stood at 2082a0923
# (test-check-manifest-coverage-fixtures/dependabot.pre-7173.yml, copied verbatim
# from git), against the live manifests, so it is proven against what the real
# config missed, not a hand-written look-alike. The mutation rows start from a
# copy of the live tree and break one rule at a time.
#
# Usage: bash scripts/ci/test-check-manifest-coverage.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/check-manifest-coverage.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIX="$HERE/test-check-manifest-coverage-fixtures"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h7173.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

expect() { # <label> <want-rc> <root>
  bash "$LINT" "$3" >"$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq "$2" ]; then pass "$1 -> exit $2"; else fail "$1 -> expected $2 got $rc"; sed -n '1,6p' "$tmp/out"; fi
}
says() { # <label> <fixed string the last run must have printed>
  if grep -qF -- "$2" "$tmp/out"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

subst() { sed "$1" "$2" > "$2.new" && mv "$2.new" "$2"; } # <sed script> <file>: edit a file in place

# live <name>: a fresh copy of every manifest and buffer file the lint reads.
live() {
  local d="$tmp/$1"
  mkdir -p "$d" || exit 1
  (cd "$REPO_ROOT" && git ls-files | grep -E '(^|/)(package\.json|requirements[^/]*\.txt|Dockerfile|bun\.lockb?|package-lock\.json|bunfig\.toml|\.npmrc|uv\.toml|dependabot\.yml)$' \
    | xargs -I{} cp --parents {} "$d") || exit 1
  printf '%s\n' "$d"
}

echo "== pre-fix dependabot.yml (verbatim fixture) =="
pf=$(live prefix)
cp "$FIX/dependabot.pre-7173.yml" "$pf/.github/dependabot.yml"
expect "pre-fix config is refused" 1 "$pf"
says "himmel-bus is named" "marketplace/plugins/himmel-bus/package.json: no npm entry"
says "ci-orchestrator is named" "scripts/ci-orchestrator/package.json: no npm entry"
says "agui-web is named" "scripts/config-ui/agui-web/package.json: no npm entry"
says "e2e is named" "scripts/config-ui/tests/e2e/package.json: no npm entry"
says "site is named" "site/package.json: no npm entry"
says "obsidian-triage pip requirements are named" "requirements-whisper.txt: no pip entry"
if grep -q 'claude-hud' "$tmp/out"; then fail "vendored claude-hud must stay exempt"; else pass "vendored claude-hud stays exempt"; fi

echo "== live tree =="
lv=$(live ok)
expect "live tree is covered and buffered" 0 "$lv"
says "summary line is printed" "0 violation(s)"

echo "== mutations =="
m=$(live nobun)
subst '/minimumReleaseAge/d' "$m/scripts/luna-vitals/bunfig.toml"
expect "bunfig without minimumReleaseAge is refused" 1 "$m"
says "the bunfig is named" "scripts/luna-vitals/bunfig.toml: no [install] minimumReleaseAge"

m=$(live shortbun)
subst 's/259200/86400/' "$m/marketplace/plugins/telegram-himmel/bunfig.toml"
expect "a 1-day minimumReleaseAge is refused" 1 "$m"
says "the short bun buffer is named" "minimumReleaseAge 86400 is below 259200"

m=$(live nonpmrc)
rm "$m/scripts/jira/.npmrc"
expect "a package-lock.json without .npmrc is refused" 1 "$m"
says "the .npmrc is named" "scripts/jira/.npmrc: no min-release-age"

m=$(live shortnpm)
subst 's/min-release-age=3/min-release-age=1/' "$m/site/.npmrc"
expect "a 1-day min-release-age is refused" 1 "$m"
says "the short npm buffer is named" "site/.npmrc: min-release-age 1 is below 3 days"

m=$(live nouv)
rm "$m/.github/ci-image/uv.toml"
expect "pip requirements without uv.toml are refused" 1 "$m"
says "the uv.toml is named" ".github/ci-image/uv.toml: no exclude-newer"

m=$(live dropdir)
subst '/"\/site"/d' "$m/.github/dependabot.yml"
expect "a dropped npm directory is refused" 1 "$m"
says "the dropped directory is named" "site/package.json: no npm entry for /site"

m=$(live newmanifest)
mkdir -p "$m/tools/newpkg" && printf '{}\n' > "$m/tools/newpkg/package.json"
expect "a new unlisted manifest is refused" 1 "$m"
says "the new manifest is named" "tools/newpkg/package.json: no npm entry for /tools/newpkg"

echo "== no dependabot.yml =="
mkdir -p "$tmp/empty"
expect "a root without dependabot.yml is a scan failure" 2 "$tmp/empty"

if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$failures FAILED"
exit 1
