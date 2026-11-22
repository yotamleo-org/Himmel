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
# The vocabulary and the line shape are scripts/lib/worker-tail-status.sh's: an
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

_status_marker_scope() {
  local LC_ALL=C doc="${1-}" line head scope=0 seen=0 fence="" ftype rest
  local hre=$'^## Results([ \t]|$)' fre='^ {0,3}(`{3,}|~{3,})(.*)$' blank=$' \t\r'
  local rre=$'^## (Chief|Console) Rulings([ \t]|$)'  # old-term-ok
  [ -f "$doc" ] && [ -r "$doc" ] || return 3
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line =~ $fre ]]; then
      ftype="${BASH_REMATCH[1]}"
      rest="${BASH_REMATCH[2]}"
      if [ -z "$fence" ]; then fence="$ftype"
      elif [ "${ftype:0:1}" = "${fence:0:1}" ] && [ "${#ftype}" -ge "${#fence}" ] \
        && [ -z "${rest//[$blank]/}" ]; then fence=""; fi
      continue
    fi
    [ -z "$fence" ] || continue
    head="${line%$'\r'}"
    case "$head" in
      '## '*)
        if [[ $head =~ $hre ]]; then scope=1; seen=1
        elif [ "$seen" = 1 ] && [[ $head =~ $rre ]]; then scope=1
        else scope=0; fi ;;
      *)
        if [ "$scope" = 1 ]; then printf '%s\n' "$line"; fi ;;
    esac
  done < "$doc"
  return 0
}

status_marker_newest() {
  local LC_ALL=C scope line marker last=""
  scope=$(_status_marker_scope "${1-}") || return $?
  while IFS= read -r line; do
    case "$line" in
      '- '*) marker=$(status_marker_parse "$line") && last="$marker" ;;
    esac
  done <<< "$scope"
  [ -n "$last" ] || return 1
  printf '%s\n' "$last"
}

status_marker_actionable() {
  local LC_ALL=C scope line last="" n=0
  local re='^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?(READY|BLOCKED|FINDING|MERGED)([^A-Za-z0-9_].*)?$'
  scope=$(_status_marker_scope "${1-}") || return $?
  while IFS= read -r line; do
    if [[ $line =~ $re ]]; then last="${BASH_REMATCH[3]}"; n=$((n + 1)); fi
  done <<< "$scope"
  [ "$n" -gt 0 ] || return 1
  printf '%s#%s\n' "$last" "$n"
}
