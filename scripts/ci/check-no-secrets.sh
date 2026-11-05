#!/usr/bin/env bash
# scripts/ci/check-no-secrets.sh — assert no GitHub Actions secret interpolation
# leaks into workflow files.
#
# Greps .github/workflows/ (or $1) for ${{ secrets.* }} patterns.
# If any match is found, prints the offending lines and exits 1.
# Two lines are allowed: `SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}` in the file named
# snyk-weekly.yml (the scheduled Snyk scan) and `SOCKET_DEV_API_KEY: ${{ secrets.SOCKET_DEV_API_KEY }}`
# in socket-scan.yml (the Socket dependency scan). Every other match still fails.
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

# The allowed interpolations, one line text per file: the SNYK_TOKEN line of snyk-weekly.yml
# and the SOCKET_DEV_API_KEY line of socket-scan.yml. Any other secret in those files, or
# either line in any other file, still fails.
# shellcheck disable=SC2016  # single quotes intentional: a literal interpolation
allowed=(
  'snyk-weekly.yml|SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}'
  'socket-scan.yml|SOCKET_DEV_API_KEY: ${{ secrets.SOCKET_DEV_API_KEY }}'
)
kept=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  ok=0
  for pair in "${allowed[@]}"; do
    allowed_file="${pair%%|*}"
    allowed_text="${pair#*|}"
    case "$m" in
      "${scan%/}/$allowed_file:"*)
        rest="${m#"${scan%/}/$allowed_file:"}"
        if [[ "$rest" =~ ^[0-9]+:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]] \
          && [ "${BASH_REMATCH[1]}" = "$allowed_text" ]; then
          ok=1
        fi
        ;;
    esac
  done
  [ "$ok" -eq 1 ] && continue
  kept+="$m"$'\n'
done <<< "$matches"
matches="${kept%$'\n'}"

if [ -n "$matches" ]; then
  printf 'ERROR: secret interpolation found in workflow files:\n'
  printf '%s\n' "$matches"
  exit 1
fi

exit 0
