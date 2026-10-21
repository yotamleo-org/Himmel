#!/usr/bin/env bash
# scripts/lib/status-marker.sh -- accept-both parse of a results-doc status
# marker, for the PARKED-BANK -> PARKED-USAGE rename.
# Source it; it prints nothing and is safe under `set -euo pipefail`.
#
#   status_marker_parse LINE     print the marker a results bullet leads with,
#                                canonical spelling (PARKED-BANK is printed as
#                                PARKED-USAGE), and return 0; return 1 when the
#                                line carries none.
#   status_marker_is_parked WORD true for PARKED-BANK and PARKED-USAGE.
#
# The vocabulary and the line shape are scripts/lib/leg-tail-status.sh's: an
# optional HH:MM stamp, optional bold, the word, then end of line or a
# character that is not a letter, digit or underscore. fixtures/
# status-marker-rows.tsv pins this, status-marker.mjs and status_marker.py to
# the same answers. Bash 3.2-safe.

status_marker_parse() {
  local LC_ALL=C
  local re='^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE|PARKED-BANK|PARKED-USAGE|RESUMED)([^A-Za-z0-9_].*)?$'
  [[ "${1-}" =~ $re ]] || return 1
  case "${BASH_REMATCH[3]}" in
    PARKED-BANK) printf '%s\n' PARKED-USAGE ;;
    *) printf '%s\n' "${BASH_REMATCH[3]}" ;;
  esac
}

status_marker_is_parked() {
  case "${1-}" in
    PARKED-BANK|PARKED-USAGE) return 0 ;;
  esac
  return 1
}
