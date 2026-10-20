#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-escape-classes.sh — escape-classes.sh: tally deferred-escape tickets by class-<id> label,
# name the top class, report unlabelled tickets as unclassified. Hermetic: the jira CLI is a seam
# command serving fixture rows; real Jira is never touched.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/escape-classes.sh"
td="$(mktemp -d "${TMPDIR:-/tmp}/escape-classes.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: [$2] lacks [$3]" ;; esac; }
lacks(){ case "$2" in *"$3"*) bad "$1: [$2] has [$3]" ;; *) ok "$1" ;; esac; }

[ -f "$tool" ] || { bad "escape-classes.sh exists"; echo "$fails failed"; exit 1; }

# Row shape of `jira list --labels`: key, type, status, summary, labels (tab separated).
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >"$ESC_FIX/args"' 'cat "$ESC_FIX/rows"' >"$td/jira.sh"
export ESC_FIX="$td" ESCAPE_CLASSES_JIRA_CMD="bash $td/jira.sh"

printf 'HIMMEL-1\tBug\tDone\ta\tdeferred-escape,class-fail-open\nHIMMEL-5\tBug\tDone\tb\tclass-fail-open,deferred-escape\nHIMMEL-7\tBug\tDone\tc\tdeferred-escape,class-quoting\nHIMMEL-6\tBug\tDone\td\tdeferred-escape\n' >"$td/rows"
out="$(bash "$tool" 2>&1)"; rc=$?
[ "$rc" = 0 ] && ok "exits 0" || bad "exits 0: rc=$rc"
contains "names the top class with its count and tickets" "$out" "top escape class: class-fail-open (2: HIMMEL-1, HIMMEL-5)"
contains "tallies the other class" "$out" "class-quoting 1"
contains "reports the unlabelled ticket as unclassified" "$out" "unclassified: 1 (HIMMEL-6)"
lacks "never assigns the unlabelled ticket a class" "$out" "class-fail-open (3"
contains "queries the deferred-escape label with --labels" "$(cat "$td/args")" "labels = deferred-escape"

printf 'HIMMEL-2\tBug\tDone\ta\tdeferred-escape\n' >"$td/rows"
out="$(bash "$tool" 2>&1)"
contains "only unclassified tickets: no top class" "$out" "top escape class: none"
contains "only unclassified tickets: still reported" "$out" "unclassified: 1 (HIMMEL-2)"

printf 'HIMMEL-3\tBug\tDone\ta\tdeferred-escape,class-a\nHIMMEL-4\tBug\tDone\tb\tdeferred-escape,class-b\n' >"$td/rows"
out="$(bash "$tool" 2>&1)"
contains "a tie is named" "$out" "tied with class-b"

: >"$td/rows"
out="$(bash "$tool" 2>&1)"
contains "no tickets: says so" "$out" "no deferred-escape tickets"

printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$td/jira.sh"
bash "$tool" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && ok "jira failure exits 1, not an empty tally" || bad "jira failure exits 1: rc=$rc"

[ "$fails" = 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
