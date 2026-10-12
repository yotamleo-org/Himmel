#!/usr/bin/env bash
# HIMMEL-5384 — keep a one-line AGENTS.md pointer next to every non-root
# CLAUDE.md (or _CLAUDE.md, the luna template's manual), so CLAUDE.md stays the
# one source per directory and agents that read only AGENTS.md are sent to it.
# The ROOT pair is not handled here: scripts/agents-md/generate.mjs owns it.
#
# Modes:  --write  create/refresh the pointers  |  --check  fail on a missing,
#         stale or hand-edited pointer
# Exit:   0 fresh/written · 1 stale or missing
# Env:    POINTERS_ROOT  repo to scan (default: this repo's root)
#
# Excluded: vendored upstream trees, where an added file would be himmel delta
# on every re-vendor (marketplace/plugins/claude-hud, HIMMEL-4578).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${POINTERS_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
MODE="${1:---check}"
EXCLUDE='^marketplace/plugins/claude-hud/'

case "$MODE" in --write|--check) ;; *) echo "usage: pointers.sh --write|--check" >&2; exit 2;; esac

want() { # $1 = source file name in the directory
  printf '%s\n' \
    "<!-- Pointer only. $1 is the one source of rules for this directory; edit that file, not this one. -->" \
    "" \
    "The rules for this directory live in [\`$1\`]($1). Read it first."
}

rc=0
dirs=$(git -C "$ROOT" ls-files | grep -E '(^|/)_?CLAUDE\.md$' | grep -vE "$EXCLUDE" | grep -v '^CLAUDE\.md$' \
  | sed 's|/\{0,1\}[^/]*$||' | sort -u)
for d in $dirs; do
  dir="$ROOT/$d"; [ -n "$d" ] || dir="$ROOT"
  if [ -f "$dir/CLAUDE.md" ]; then src=CLAUDE.md; else src=_CLAUDE.md; fi
  tgt="$dir/AGENTS.md"
  if [ "$MODE" = "--write" ]; then
    want "$src" > "$tgt"
  elif [ ! -f "$tgt" ] || [ "$(want "$src")" != "$(tr -d '\r' < "$tgt")" ]; then
    echo "pointers: ${d:-.}/AGENTS.md is missing or stale (source ${src})" >&2; rc=1
  fi
done
[ "$rc" -eq 0 ] || echo "pointers: fix with: bash scripts/agents-md/pointers.sh --write" >&2
exit "$rc"
