#!/usr/bin/env bash
# shellcheck disable=SC1090  # $LIB is the lib beside this suite, sourced into subshells
# scripts/lib/test-ticket-id-internal.sh — suite for scripts/lib/ticket-id-internal.sh:
# the tri-state ticket_id_author_class (0 external, 1 internal, 2 unknown) and the
# unchanged ticket_id_author_is_external wrapper its CI callers use.
# Platform guard: bash 3.2+.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/ticket-id-internal.sh"
W=$(mktemp -d "${TMPDIR:-/tmp}/ticket-id-internal-test.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then printf 'ok - %s\n' "$1"; else printf 'FAIL - %s: [%s] != [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }
printf '# internal\nyotamleo\n\nOther-Dev # trailing\n' > "$W/list"
: > "$W/empty"
printf '# only comments\n\n' > "$W/comments"
class() { (unset -f ticket_id_author_class; . "$LIB"; TICKET_ID_INTERNAL_AUTHORS_FILE="$2" ticket_id_author_class "$1" 2>/dev/null); echo $?; }
ext() { (. "$LIB"; TICKET_ID_INTERNAL_AUTHORS_FILE="$2" ticket_id_author_is_external "$1" 2>/dev/null); echo $?; }

check 'class: unlisted login is external (0)' "$(class Goomal "$W/list")" 0
check 'class: listed login is internal (1)' "$(class yotamleo "$W/list")" 1
check 'class: listed login matches case-insensitively' "$(class other-dev "$W/list")" 1
check 'class: dependabot is internal (1)' "$(class 'dependabot[bot]' "$W/list")" 1
check 'class: empty login is unknown (2)' "$(class '' "$W/list")" 2
check 'class: unreadable list is unknown (2)' "$(class Goomal "$W/missing")" 2
check 'class: empty list is unknown (2)' "$(class Goomal "$W/empty")" 2
check 'class: a comments-only list is unknown (2)' "$(class Goomal "$W/comments")" 2
# the wrapper keeps its rc for every case: external only on class 0
check 'is_external: unlisted login 0' "$(ext Goomal "$W/list")" 0
check 'is_external: listed login 1' "$(ext yotamleo "$W/list")" 1
check 'is_external: dependabot 1' "$(ext dependabot "$W/list")" 1
check 'is_external: empty login 1' "$(ext '' "$W/list")" 1
check 'is_external: unreadable list 1' "$(ext Goomal "$W/missing")" 1
check 'is_external: empty list 1' "$(ext Goomal "$W/empty")" 1
note=$( (. "$LIB"; TICKET_ID_INTERNAL_AUTHORS_FILE="$W/list" ticket_id_author_is_external Goomal 2>&1 >/dev/null) )
case "$note" in *"NOTE ticket-id: 'Goomal' is not an internal committer"*) r=yes ;; *) r=no ;; esac
check 'is_external: still prints its NOTE on stderr' "$r" yes
# the default list is the tracked file beside the lib
check 'class: default list (tracked) holds yotamleo' "$( (. "$LIB"; unset TICKET_ID_INTERNAL_AUTHORS_FILE; ticket_id_author_class yotamleo); echo $?)" 1
[ "$fails" -eq 0 ] || { printf '%s FAILED\n' "$fails"; exit 1; }
printf 'ALL PASS\n'
