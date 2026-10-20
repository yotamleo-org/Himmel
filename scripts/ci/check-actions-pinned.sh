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
# `- uses:`). A YAML flow mapping (`- {uses: ...}`) is not parsed, so a
# `uses:`, `container:` or `image:` key inside one is refused.
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

# Container images: a `container: <ref>` or `image: <ref>` line (job container,
# services:) must carry `@sha256:<64 hex>`. A `${{ ... }}` value passes when it
# names at least one non-empty single-quoted literal outside a vars.* / github.*
# == / != comparison, every such literal is digest-pinned, and its only other
# operands are vars.*: the vars.CI_IMAGE override itself is a repo setting, not
# file content.
# `container:` with no value (the mapping form) is checked on its `image:` line.
found=$(grep -rnHE --null --include='*.yml' --include='*.yaml' \
  "^[[:space:]]*-?[[:space:]]*[\"']?(container|image)[\"']?[[:space:]]*:[[:space:]]*[^[:space:]#]" "${existing[@]}" | tr '\0' "$sep")
rc=$?
if [ "$rc" -gt 1 ]; then
  printf 'ERROR: scanning for container image lines failed (grep rc=%s)\n' "$rc" >&2
  exit 2
fi

digest_re='^[^[:space:]@]+@sha256:[0-9a-f]{64}$'
ref_re='(vars|github)\.[A-Za-z0-9_.]+'
key_re="^[[:space:]]*-?[[:space:]]*[\"']?[A-Za-z0-9_.-]+[\"']?[[:space:]]*:([[:space:]]|\$)"
unpinned=()
while IFS= read -r line; do
  [ -n "$line" ] || continue
  value=$(printf '%s\n' "${line#*"$sep"}" | sed -E "s/^[0-9]+:[[:space:]]*-?[[:space:]]*[\"']?(container|image)[\"']?[[:space:]]*:[[:space:]]*//; s/[[:space:]]+#.*\$//")
  if [[ "$value" == \"*\" ]]; then value=${value#\"}; value=${value%\"}; fi
  if [[ "$value" == \'\$\{\{*\' ]]; then value=${value#\'}; value=${value%\'}; value=${value//\'\'/\'}; fi
  if [[ "$value" == \$\{\{* ]]; then
    # A vars.* / github.* == / != comparison is a condition, not an image; '' means
    # no container. What is left may hold only vars.*, literals and && || ! ( ):
    # any other operand (matrix.*, needs.*, a bare github.*) can yield an image.
    cond=$(sed -E "s/^\\$\\{\\{//; s/\\}\\}\$//; s/${ref_re}[[:space:]]*(==|!=)[[:space:]]*('[^']*'|${ref_re})//g; s/'[^']*'[[:space:]]*(==|!=)[[:space:]]*${ref_re}//g" <<< "$value")
    literals=$(grep -oE "'[^']*'" <<< "$cond" | tr -d "'")
    ok=1
    # A plain scalar continued on the next line folds more operands in unread.
    [[ "$value" == *\}\} ]] || ok=0
    [ -n "$literals" ] || ok=0
    [ -z "$(sed -E "s/'[^']*'//g; s/vars\.[A-Za-z0-9_]+//g; s/&&|\|\||[!()[:space:]]//g" <<< "$cond")" ] || ok=0
    while IFS= read -r lit; do
      [ -n "$lit" ] && ! [[ "$lit" =~ $digest_re ]] && ok=0
    done <<< "$literals"
  else
    value=${value#\'}; value=${value%\'}
    ok=0
    [[ "$value" =~ $digest_re ]] && ok=1
  fi
  # YAML folds a deeper-indented next line (past blank lines) into the scalar
  # unless it is itself a `key:` line, so such a line is refused unread.
  rest=${line#*"$sep"}
  key_prefix=$(sed -E 's/^([[:space:]]*-?[[:space:]]*).*/\1/' <<< "${rest#*:}")
  folded=$(awk -v n="${rest%%:*}" -v kc="${#key_prefix}" -v kre="$key_re" '
    NR <= n || /^[[:space:]]*$/ { next }
    { match($0, /^[ \t]*/); if (RLENGTH > kc && $0 !~ kre) print "y"; exit }' "${line%%"$sep"*}")
  [ -z "$folded" ] || ok=0
  [ "$ok" -eq 1 ] || unpinned+=("$line")
done <<< "$found"

if [ "${#unpinned[@]}" -gt 0 ]; then
  printf 'ERROR: container image not pinned by @sha256: digest:\n'
  printf '%s\n' "${unpinned[@]}" | tr "$sep" ':'
  printf 'Pin as: image: registry/name@sha256:<64-hex>  (docker buildx imagetools inspect <ref>)\n'
  exit 1
fi

# The scan above is line-based, so a flow mapping (`db: {image: ...}`) is refused
# outright rather than passed unread. `${{` is an expression, not a mapping.
flow=$(grep -rnHE --include='*.yml' --include='*.yaml' \
  '(^|[^{$])\{[[:space:]]*([^}]*,[[:space:]]*)?(uses|container|image)[[:space:]]*:' "${existing[@]}")
rc=$?
if [ "$rc" -gt 1 ]; then
  printf 'ERROR: scanning for flow-mapping keys failed (grep rc=%s)\n' "$rc" >&2
  exit 2
fi
if [ -n "$flow" ]; then
  printf 'ERROR: uses/container/image key in a YAML flow mapping (not scanned; write it in block form):\n%s\n' "$flow"
  exit 1
fi

exit 0
