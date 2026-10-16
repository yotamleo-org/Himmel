#!/usr/bin/env bash
# bump-codex-sessionend-timeout.sh
#
# The openai-codex marketplace plugin ships a SessionEnd hook
# (session-lifecycle-hook.mjs SessionEnd) with `timeout: 5`. Its broker
# teardown regularly takes longer, so Claude Code cancels it and every session
# end prints "SessionEnd hook ... failed: Hook cancelled". Raise that one
# timeout to MIN_TIMEOUT seconds in the installed plugin cache.
#
# Only the SessionEnd lifecycle-hook timeout is touched, and only upward: a
# larger existing value is kept. Idempotent. Exits 1 (and does not print a final
# OK) when any hooks.json was skipped (unparseable, temp-file or write failure).
#
# ponytail: re-applies only when run (himmel-update.sh after the marketplace re-sync, or by hand); Claude Code background plugin auto-update is not hooked, HIMMEL-5965 follow-up.
#
#   bump-codex-sessionend-timeout.sh            # patch in place, report
#   bump-codex-sessionend-timeout.sh --dry-run  # report what WOULD change
#
# Env overrides: CLAUDE_CONFIG_DIR (default ~/.claude), MIN_TIMEOUT (default 30).
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "ERR: jq required" >&2; exit 1; }

MIN_TIMEOUT="${MIN_TIMEOUT-30}"
case "$MIN_TIMEOUT" in
  ''|*[!0-9]*|0|0[0-9]*) echo "ERR: MIN_TIMEOUT must be a positive integer (got '$MIN_TIMEOUT')" >&2; exit 2 ;;
esac
CACHE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache/openai-codex"
if [ ! -d "$CACHE" ]; then
  echo "OK: no openai-codex plugin cache at $CACHE (nothing to bump)."
  exit 0
fi

# True when a SessionEnd lifecycle-hook entry sits below MIN_TIMEOUT.
# shellcheck disable=SC2016 # $min is a jq variable, not a shell expansion
NEEDS='[.hooks.SessionEnd[]?.hooks[]? | select((.command // "") | contains("session-lifecycle-hook.mjs")) | select((.timeout // 0) < $min)] | length > 0'
# shellcheck disable=SC2016 # $min is a jq variable, not a shell expansion
PATCH='.hooks.SessionEnd |= map(if has("hooks") then .hooks |= map(if ((.command // "") | contains("session-lifecycle-hook.mjs")) and ((.timeout // 0) < $min) then .timeout = $min else . end) else . end)'

hooks_files="$(find "$CACHE" -name hooks.json)" || { echo "ERR: cannot scan $CACHE" >&2; exit 1; }

scanned=0
bumped=0
skipped=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  scanned=$((scanned + 1))
  if ! jq empty "$f" >/dev/null 2>&1; then
    echo "SKIP (unparseable): $f" >&2
    skipped=$((skipped + 1))
    continue
  fi
  jq -e --argjson min "$MIN_TIMEOUT" "$NEEDS" "$f" >/dev/null 2>&1 || continue
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD BUMP  : $f"
  else
    tmp="$(mktemp "$(dirname "$f")/.hooks.json.XXXXXX")" || { echo "SKIP (mktemp failed): $f" >&2; skipped=$((skipped + 1)); continue; }
    # Write THROUGH the path (cat >) rather than mv: keeps the original mode and
    # a symlinked hooks.json a symlink. jq finishes into $tmp first, so a jq
    # failure never truncates the real file.
    if jq --argjson min "$MIN_TIMEOUT" "$PATCH" "$f" > "$tmp" && cat "$tmp" > "$f"; then
      rm -f "$tmp"
      echo "BUMPED      : $f"
    else
      rm -f "$tmp"
      echo "SKIP (write failed): $f" >&2
      skipped=$((skipped + 1))
      continue
    fi
  fi
  bumped=$((bumped + 1))
done <<< "$hooks_files"

echo ""
if [ "$skipped" -gt 0 ]; then
  echo "ERR: skipped $skipped of $scanned hooks.json (see SKIP lines); bumped $bumped." >&2
  exit 1
elif [ "$DRY_RUN" = "1" ]; then
  echo "DRY-RUN: $bumped of $scanned hooks.json would be bumped."
elif [ "$bumped" -eq 0 ]; then
  echo "OK: nothing to bump ($scanned hooks.json already >= ${MIN_TIMEOUT}s or without the hook)."
else
  echo "OK: raised SessionEnd timeout to ${MIN_TIMEOUT}s in $bumped of $scanned hooks.json."
fi
