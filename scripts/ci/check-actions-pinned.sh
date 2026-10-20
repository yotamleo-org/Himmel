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
# `docker://...@sha256:<64 hex>` refs (pinned by digest, not a git SHA);
# a `docker://` ref without a digest is flagged.
#
# Line-based: a `uses:` is recognised at the start of a line (`uses:` or
# `- uses:`). YAML flow mappings (`- {uses: ...}`) are not scanned; this repo
# does not use them.
#
# Usage:
#   check-actions-pinned.sh [scan-path ...]   # default: .github
#
# Exit codes:
#   0 — every non-local `uses:` is SHA-pinned (or no scan path exists)
#   1 — at least one unpinned `uses:` found
#   2 — the scan itself failed (e.g. an unreadable file)
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

# grep exits 0 on a match, 1 on none, 2+ on a scan error: only 2+ is a failure
# here, and it must not read as "nothing unpinned".
# --null (GNU and BSD alike; BSD's -Z means decompress) ends the file name with
# NUL instead of ':', and tr turns that NUL into \001 (a shell variable cannot
# hold NUL), so a ':' in a path cannot be mistaken for the file:line: separator.
# pipefail keeps grep's rc.
sep=$'\001'
found=$(grep -rnHE --null --include='*.yml' --include='*.yaml' \
  '^[[:space:]]*-?[[:space:]]*uses:' "${existing[@]}" | tr '\0' "$sep")
rc=$?
if [ "$rc" -gt 1 ]; then
  printf 'ERROR: scanning for uses: lines failed (grep rc=%s)\n' "$rc" >&2
  exit 2
fi

# Every pattern is anchored to the start of the line's content (after the
# grep file:line: prefix), so a `uses:` inside a trailing comment cannot match.
head_re="^[^${sep}]*${sep}[0-9]+:[[:space:]]*-?[[:space:]]*uses:[[:space:]]*[\"']?"
matches=$(printf '%s\n' "$found" \
  | grep -vE "${head_re}(\./|docker://[^[:space:]]*@sha256:[0-9a-f]{64}[\"']?([[:space:]]|\$))" \
  | grep -vE "${head_re}[^[:space:]\"'@#]+@[0-9a-f]{40}[\"']?([[:space:]]|\$)" \
  | grep -E "${head_re}" || true)

if [ -n "$matches" ]; then
  printf 'ERROR: GitHub Action not pinned to a full 40-hex commit SHA:\n'
  printf '%s\n' "$matches" | tr "$sep" ':'
  printf 'Pin as: uses: owner/repo@<40-hex-sha> # vX.Y.Z  (gh api repos/owner/repo/commits/<tag> --jq .sha)\n'
  exit 1
fi

exit 0
