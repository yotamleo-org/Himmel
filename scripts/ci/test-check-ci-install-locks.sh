#!/usr/bin/env bash
# Test for scripts/ci/check-ci-install-locks.sh.
#
# The pre-fix fixtures under test-check-ci-install-locks-fixtures/ are the
# verbatim install lines of the CI tree before the hash-pin change (ci.yml and
# friends at 30f9d1237), so the lint is proven against what the real workflows held,
# not against hand-written look-alikes. The mutation rows start from the live
# tree and break one rule at a time.
#
# Usage: bash scripts/ci/test-check-ci-install-locks.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINT="$HERE/check-ci-install-locks.sh"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
FIX="$HERE/test-check-ci-install-locks-fixtures"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h7092.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

expect() { # <label> <want-rc> <root>
  bash "$LINT" "$3" >"$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq "$2" ]; then pass "$1 -> exit $2"; else fail "$1 -> expected $2 got $rc"; sed -n '1,6p' "$tmp/out"; fi
}
says() { # <label> <fixed string the last run must have printed>
  if grep -qF -- "$2" "$tmp/out"; then pass "$1"; else fail "$1 (missing: $2)"; fi
}

# live <name>: a fresh copy of the tree's install-relevant files.
live() {
  local d="$tmp/$1"
  mkdir -p "$d" && cp -R "$REPO_ROOT/.github" "$d/.github" && cp "$REPO_ROOT/.pre-commit-config.yaml" "$d/" || exit 1
  printf '%s\n' "$d"
}

echo "== pre-fix tree (verbatim fixtures) =="
pf="$tmp/prefix"
mkdir -p "$pf/.github/workflows" "$pf/.github/ci-image"
cp "$FIX/ci.yml.txt" "$pf/.github/workflows/ci.yml"
cp "$FIX/other-workflows.yml.txt" "$pf/.github/workflows/other.yml"
cp "$FIX/Dockerfile.txt" "$pf/.github/ci-image/Dockerfile"
cp "$FIX/dependabot.yml.txt" "$pf/.github/dependabot.yml"
expect "pre-fix tree is refused" 1 "$pf"
says "unhashed pip pin in a workflow is named" "ci.yml:16: pip install without --require-hashes"
says "unhashed pip pin in the Dockerfile is named" "Dockerfile:5: pip install without --require-hashes"
says "npm ci without --ignore-scripts is named" "install scripts enabled"
says "bun install without --ignore-scripts is named" "bun install --frozen-lockfile"
says "claude-code installed by name is named" "claude-code installed by name"
says "missing claude lockfile is named" "package-lock.json missing"
says "dependabot without cooldown is named" "dependabot.yml: npm: no cooldown.default-days"

echo "== live tree =="
expect "live tree is locked" 0 "$REPO_ROOT"
expect "no .github is a scan failure" 2 "$tmp/nonexistent"

echo "== pip =="
t=$(live pip-nohash); sed -i.bak 's/--require-hashes//' "$t/.github/workflows/ci.yml"
expect "pip install without --require-hashes" 1 "$t"
t=$(live pip-noreq); sed -i.bak 's/-r \.github\/ci-image\/requirements-ci\.txt//' "$t/.github/workflows/ci.yml"
expect "pip install without -r" 1 "$t"
t=$(live pip-missing); rm -f "$t/.github/ci-image/requirements-ci.txt"
expect "requirements file absent" 1 "$t"
says "absent requirements file is named" "requirements file not found"
t=$(live pip-unhashed-entry); printf 'leftpad==1.0.0\n' >> "$t/.github/ci-image/requirements-ci.txt"
expect "requirements entry without a hash" 1 "$t"
says "unhashed entry is named" "entry without a sha256 hash: leftpad==1.0.0"
t=$(live pip-short-hash); printf 'leftpad==1.0.0 \\\n    --hash=sha256:abc123\n' >> "$t/.github/ci-image/requirements-ci.txt"
expect "requirements entry with a truncated hash" 1 "$t"
t=$(live pip-added); printf '      - run: pip install requests==2.0.0\n' >> "$t/.github/workflows/ci.yml"
expect "a new unhashed pip install line" 1 "$t"
t=$(live pip-chain); printf '      - run: cd x && python -m pip install --require-hashes -r .github/ci-image/requirements-ci.txt && pip install evil\n' >> "$t/.github/workflows/ci.yml"
expect "a second unhashed pip install in one && chain" 1 "$t"
t=$(live pip-comment); printf '      # pip install requests==2.0.0 is documented here only\n' >> "$t/.github/workflows/ci.yml"
expect "a commented-out pip install is ignored" 0 "$t"

echo "== npm / bun =="
t=$(live bun-plain); printf '      - run: cd x && bun install --frozen-lockfile\n' >> "$t/.github/workflows/ci.yml"
expect "bun install without --ignore-scripts" 1 "$t"
t=$(live bun-ok); printf '      - run: cd x && bun install --frozen-lockfile --ignore-scripts\n' >> "$t/.github/workflows/ci.yml"
expect "bun install with --ignore-scripts" 0 "$t"
t=$(live npm-chain); printf '      - run: bun install --ignore-scripts && npm ci\n' >> "$t/.github/workflows/ci.yml"
expect "unguarded npm ci after a guarded bun install" 1 "$t"
t=$(live npm-multiline); printf '        run: |\n          npm ci \\\n            --prefix site\n' >> "$t/.github/workflows/ci.yml"
expect "npm ci continued over lines, unguarded" 1 "$t"
t=$(live npm-multiline-ok); printf '        run: |\n          npm ci \\\n            --ignore-scripts\n' >> "$t/.github/workflows/ci.yml"
expect "npm ci continued over lines, guarded" 0 "$t"
t=$(live npm-exception); printf '        # install-scripts-ok: the postinstall places the native binary\n        run: npm ci\n' >> "$t/.github/workflows/ci.yml"
expect "install-scripts-ok comment above an install" 0 "$t"
t=$(live npm-exception-stale); printf '        # install-scripts-ok: only this step\n        run: npm ci --ignore-scripts\n        run: npm ci\n' >> "$t/.github/workflows/ci.yml"
expect "install-scripts-ok does not cover the next step" 1 "$t"
t=$(live npm-comment); printf '      # run: npm ci would be needed here\n' >> "$t/.github/workflows/ci.yml"
expect "a commented-out npm ci is ignored" 0 "$t"

echo "== claude CLI =="
t=$(live claude-name)
# the ${...} below is workflow text, not shell
# shellcheck disable=SC2016
printf '        run: sudo npm install --global "@anthropic-ai/claude-code@${CLAUDE_CLI_VERSION}"\n' >> "$t/.github/workflows/ci.yml"
expect "claude-code installed by name" 1 "$t"
t=$(live claude-nolock); rm -f "$t/.github/claude-cli/package-lock.json"
expect "claude lockfile absent" 1 "$t"
t=$(live claude-drift); sed -i.bak "s/\(CLAUDE_CLI_VERSION: '\)[0-9.]*'/\19.9.9'/" "$t/.github/workflows/ci.yml"
expect "CLAUDE_CLI_VERSION differs from the lockfile" 1 "$t"
says "version drift is named" "(bump both)"
t=$(live claude-nointegrity); sed -i.bak 's/"integrity": "sha512-/"integrity": "sha1-/' "$t/.github/claude-cli/package-lock.json"
expect "claude lockfile without sha512 integrity" 1 "$t"

echo "== shellcheck-py =="
t=$(live sc-drift); sed -i.bak 's/rev: v0\.11\.0\.1/rev: v0.11.0.2/' "$t/.pre-commit-config.yaml"
expect "pre-commit shellcheck-py rev differs from the requirements file" 1 "$t"

echo "== dependabot =="
t=$(live dep-nocooldown); sed -i.bak '/cooldown:/,/default-days:/d' "$t/.github/dependabot.yml"
expect "cooldown removed from every ecosystem" 1 "$t"
t=$(live dep-short); sed -i.bak 's/default-days: [0-9]*/default-days: 2/' "$t/.github/dependabot.yml"
expect "cooldown of 2 days" 1 "$t"
says "short cooldown is named" "below 3"
t=$(live dep-three); sed -i.bak 's/default-days: [0-9]*/default-days: 3/' "$t/.github/dependabot.yml"
expect "cooldown of exactly 3 days" 0 "$t"
t=$(live dep-nopip); sed -i.bak 's/package-ecosystem: "pip"/package-ecosystem: "docker"/' "$t/.github/dependabot.yml"
expect "no pip ecosystem while requirements files exist" 1 "$t"

if [ "$failures" -gt 0 ]; then printf '\n%d case(s) failed\n' "$failures"; exit 1; fi
printf '\nall cases passed\n'
