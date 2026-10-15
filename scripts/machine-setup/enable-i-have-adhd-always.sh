#!/usr/bin/env bash
# enable-i-have-adhd-always.sh — create the i-have-adhd always-on flag file
# The plugin's SessionStart hook injects the skill body only when
# ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.i-have-adhd-always exists (~1.75k tokens
# once per session). The installer and the updater call this so a machine that
# has the plugin installed gets it on without a manual `touch`.
#
#   enable-i-have-adhd-always.sh [--check]
#
#   --check   report what would happen; write nothing (updater --check).
#
# Opt-out: HIMMEL_NO_ADHD_ALWAYS=1 (1/true/yes). When set the flag is never
# created, so a flag the operator deleted stays deleted. Without the opt-out the
# step is idempotent: flag present = silent no-op, absent = created again.
# Best-effort: always exits 0 (never fails an install or an update).
set -u

check=0
[ "${1:-}" = "--check" ] && check=1

cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
flag="$cfg/.i-have-adhd-always"
installed="$cfg/plugins/installed_plugins.json"

case "${HIMMEL_NO_ADHD_ALWAYS:-}" in
    1|true|yes) exit 0 ;;
esac

[ -f "$flag" ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
[ -f "$installed" ] || exit 0
jq -e '.plugins | has("i-have-adhd@himmel")' "$installed" >/dev/null 2>&1 || exit 0

if [ "$check" -eq 1 ]; then
    echo "    i-have-adhd always-on: would create $flag (opt out: HIMMEL_NO_ADHD_ALWAYS=1)"
    exit 0
fi
if mkdir -p "$cfg" 2>/dev/null && : > "$flag" 2>/dev/null; then
    echo "    i-have-adhd always-on enabled: created $flag (opt out: HIMMEL_NO_ADHD_ALWAYS=1, then delete the file)"
else
    echo "    warn: could not create $flag (non-fatal)." >&2
fi
exit 0
