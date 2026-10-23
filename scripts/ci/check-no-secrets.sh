#!/usr/bin/env bash
# scripts/ci/check-no-secrets.sh — assert no GitHub Actions secret interpolation
# leaks into workflow files.
#
# Greps .github/workflows/ (or $1) for ${{ secrets.* }} patterns.
# If any match is found, prints the offending lines and exits 1.
# One line is allowed: `SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}` in the file named
# snyk-weekly.yml (the scheduled Snyk scan). Every other match still fails.
# If the scan directory does not exist, exits 0 (nothing to leak).
#
# Usage:
#   check-no-secrets.sh [scan-dir]   # default: .github/workflows
#
# Exit codes:
#   0 — no secret interpolation found (or scan dir absent)
#   1 — at least one match found
set -uo pipefail

scan="${1:-.github/workflows}"

if [ ! -d "$scan" ]; then
  exit 0
fi

# Match ${{ secrets.* }} interpolation only.
# -r  recursive
# -n  show line numbers
# -E  extended regex
# --include limits to workflow files
matches=$(grep -rnE '\$\{\{[^}]*secrets\.' \
  --include='*.yml' --include='*.yaml' \
  "$scan" 2>/dev/null || true)

# The one allowed interpolation: the SNYK_TOKEN line of snyk-weekly.yml. Any other
# secret in that file, or that line in any other file, still fails.
allowed_file='snyk-weekly.yml'
# shellcheck disable=SC2016  # single quotes intentional: a literal interpolation
allowed_text='SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}'
kept=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if [[ "$m" =~ ^(.*/)?([^/:]+):[0-9]+:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] \
    && [ "${BASH_REMATCH[2]}" = "$allowed_file" ] \
    && [ "${BASH_REMATCH[3]}" = "$allowed_text" ]; then
    continue
  fi
  kept+="$m"$'\n'
done <<< "$matches"
matches="${kept%$'\n'}"

if [ -n "$matches" ]; then
  printf 'ERROR: secret interpolation found in workflow files:\n'
  printf '%s\n' "$matches"
  exit 1
fi

exit 0
