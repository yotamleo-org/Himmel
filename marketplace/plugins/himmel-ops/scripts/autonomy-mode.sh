#!/usr/bin/env bash
# autonomy-mode.sh — print "autonomous" if any autonomy flag is set, else "interactive".
# Signals: initiative mode (HIMMEL_INITIATIVE) and its afk part (HIMMEL_INITIATIVE_AFK,
# else its old name HIMMEL_INITIATIVE_OVERNIGHT). HIMMEL_INITIATIVE is a CHAIN SPEC (e.g. "pr,ticket"),
# not a boolean, so treat any non-empty, non-falsy value as active (blocklist, not allowlist).
set -euo pipefail
active() { case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in ""|0|false|off|no) return 1;; *) return 0;; esac; }
# old names, read only while HIMMEL_LEGACY_NAMES is on; when legacy names are off this inlines the falsy pattern of scripts/lib/legacy-names.sh
afk="${HIMMEL_INITIATIVE_AFK:-}"
case "${HIMMEL_LEGACY_NAMES:-}" in
  0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) ;;
  *) afk="${afk:-${HIMMEL_INITIATIVE_OVERNIGHT:-}}" ;;
esac
if active "${HIMMEL_INITIATIVE:-}" || active "$afk"; then
  echo "autonomous"
else
  echo "interactive"
fi
