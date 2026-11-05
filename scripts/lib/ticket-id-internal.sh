# shellcheck shell=bash
# scripts/lib/ticket-id-internal.sh — Sourced by the CI ticket-ID
# wrappers (scripts/ci/check-commit-range.sh, scripts/lib/check-pr-title.sh)
# and by ready-check items 6 and 16.
#
# ticket_id_author_class <login>
#   rc 0 = external: <login> is not on the allowlist.
#   rc 1 = internal: a listed login, or a bot the hook already exempts
#          (dependabot keeps its own author-metadata check).
#   rc 2 = unknown: an EMPTY login, an unreadable allowlist or an empty one.
#   A gate that must not mistake missing data for "internal" reads rc 2 as its
#   own case (ready-check item 16 treats it as outside).
#
# ticket_id_author_is_external <login>
#   rc 0 = class 0: skip ONLY the ticket-ID requirement (prints a NOTE on
#          stderr). rc 1 = every other class: require the ticket ID — missing
#          data never exempts anyone.
# The allowlist is scripts/ci/ticket-id-internal-authors.txt (override the path
# with TICKET_ID_INTERNAL_AUTHORS_FILE, for tests).

ticket_id_author_class() {
  local login="${1:-}" here file line lc
  [ -n "$login" ] || return 2
  lc="$(printf '%s' "$login" | tr '[:upper:]' '[:lower:]')"
  case "$lc" in dependabot|'dependabot[bot]') return 1 ;; esac
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  file="${TICKET_ID_INTERNAL_AUTHORS_FILE:-$here/../ci/ticket-id-internal-authors.txt}"
  [ -r "$file" ] || return 2
  local listed=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
    [ -n "$line" ] || continue
    listed=1
    [ "$line" = "$lc" ] && return 1
  done < "$file"
  [ "$listed" -eq 1 ] || return 2
  return 0
}

ticket_id_author_is_external() {
  local rc=0
  ticket_id_author_class "${1:-}" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  echo "NOTE ticket-id: '${1}' is not an internal committer — ticket-ID requirement skipped (conventional shape still enforced)" >&2
  return 0
}
