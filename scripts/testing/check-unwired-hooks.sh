#!/usr/bin/env bash
# check-unwired-hooks.sh — fail when a hook-named script under scripts/hooks is
# referenced by NO wiring file and is not on the explicit allowlist.
#
# A hook that ships but is never registered fails OPEN and silently: the bus
# delivery hooks sat unwired for exactly this reason. CI proves
# each hook script in isolation, not that anything calls it.
#
# "Hook-named" = a top-level scripts/hooks/*.sh, *.js or *.mjs that is not a
# test (test-*, *.test.*), a library (lib-*) or the runner/wirer tooling.
# "Wired" = its basename appears in one of the wiring files below.
# Allowlist: scripts/testing/unwired-hooks-allowlist.txt, one `<basename>|<reason>`
# per line; a reason is mandatory, `#` lines are comments. An allowlist entry that
# is now wired, or names no script, is itself a failure (the list cannot rot).
#
# Usage: bash scripts/testing/check-unwired-hooks.sh [<repo-root>]
# Exit: 0 clean, 1 unwired script or stale allowlist entry, 2 repo root has no scripts/hooks.
set -uo pipefail

REPO="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
ALLOW="$REPO/scripts/testing/unwired-hooks-allowlist.txt"
WIRING=(
  .claude/settings.json
  marketplace/plugins/himmel-ops/hooks/hooks.json
  marketplace/plugins/lean-skills/hooks/hooks.json
  marketplace/plugins/qmd/hooks/hooks.json
  .codex/hooks.json
  .pre-commit-config.yaml
  .pre-commit-hooks.yaml
  docs/setup/settings-template.json
)

[ -d "$REPO/scripts/hooks" ] || { echo "no scripts/hooks under $REPO" >&2; exit 2; }

wiring_text=""
for w in "${WIRING[@]}"; do
  [ -f "$REPO/$w" ] && wiring_text+="$(cat "$REPO/$w")"$'\n'
done

# Whole-basename match: not-orphan-hook.sh must not register orphan-hook.sh.
is_wired() { grep -qE -- "(^|[^A-Za-z0-9._-])${1//./\\.}([^A-Za-z0-9._-]|\$)" <<<"$wiring_text"; }
allow_reason() { awk -F'|' -v b="$1" '$1==b {print $2; exit}' "$ALLOW" 2>/dev/null; }

fail=0
seen=""
for f in "$REPO"/scripts/hooks/*.sh "$REPO"/scripts/hooks/*.js "$REPO"/scripts/hooks/*.mjs; do
  [ -f "$f" ] || continue
  b="${f##*/}"
  case "$b" in
    test-*|lib-*|*.test.*|run-hook-with-bash.js|wire-hook-bash.mjs|wire-plugin-hook-bash.mjs|bench-hook-stack.mjs) continue ;;
  esac
  seen+="$b"$'\n'
  if is_wired "$b"; then
    if [ -n "$(allow_reason "$b")" ]; then
      echo "STALE   $b is wired but still on the allowlist; remove the entry"
      fail=1
    fi
    continue
  fi
  reason="$(allow_reason "$b")"
  if [ -z "$reason" ]; then
    echo "UNWIRED $b is referenced by no wiring file and is not allowlisted"
    fail=1
  fi
done

if [ -f "$ALLOW" ]; then
  while IFS='|' read -r name reason; do
    case "$name" in ''|'#'*) continue ;; esac
    if [ -z "$reason" ]; then
      echo "NOREASON $name has no reason on the allowlist"
      fail=1
    fi
    grep -qxF -- "$name" <<<"$seen" || { echo "STALE   allowlist names $name, which is not a hook-named script"; fail=1; }
  done < "$ALLOW"
fi

[ "$fail" -eq 0 ] && echo "UNWIRED-HOOKS OK"
exit "$fail"
