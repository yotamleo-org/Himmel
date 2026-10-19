#!/usr/bin/env bash
# scripts/ci/check-actions-pinned.sh — assert every non-local GitHub Action
# `uses:` is pinned to a full 40-hex commit SHA.
#
# A tag (`@v7`) is mutable: whoever controls the action repo can repoint it at
# new code that then runs in our CI. A commit SHA is not. Dependabot's
# github-actions ecosystem bumps SHA pins and their `# vX.Y.Z` comment natively.
#
# Greps .github/ (or the given dirs/files) for `uses:` lines in *.yml / *.yaml
# that do not carry `@<40 hex>`. Exempt: local refs (`uses: ./...`) and
# `docker://` refs (those pin by @sha256: digest, not a git SHA).
#
# Usage:
#   check-actions-pinned.sh [scan-path ...]   # default: .github
#
# Exit codes:
#   0 — every non-local `uses:` is SHA-pinned (or no scan path exists)
#   1 — at least one unpinned `uses:` found
set -uo pipefail

if [ "$#" -gt 0 ]; then
  scan_targets=("$@")
else
  scan_targets=(.github)
fi

existing=()
for t in "${scan_targets[@]}"; do
  [ -e "$t" ] && existing+=("$t")
done
[ "${#existing[@]}" -eq 0 ] && exit 0

q="[\"']?"
matches=$(grep -rnHE --include='*.yml' --include='*.yaml' \
    '^[[:space:]]*-?[[:space:]]*uses:' "${existing[@]}" 2>/dev/null \
  | grep -vE "uses:[[:space:]]*${q}(\./|docker://)" \
  | grep -vE "uses:[[:space:]]*${q}[^[:space:]\"'@#]+@[0-9a-f]{40}${q}([[:space:]]|\$)" || true)

if [ -n "$matches" ]; then
  printf 'ERROR: GitHub Action not pinned to a full 40-hex commit SHA:\n'
  printf '%s\n' "$matches"
  printf 'Pin as: uses: owner/repo@<40-hex-sha> # vX.Y.Z  (gh api repos/owner/repo/commits/<tag> --jq .sha)\n'
  exit 1
fi

exit 0
