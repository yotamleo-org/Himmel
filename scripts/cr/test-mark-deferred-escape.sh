#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016
# test-mark-deferred-escape.sh — mark-deferred-escape.sh: Relates link, deferred-escape label,
# residual's class-<id> labels copied; no class label means a warning and none copied.
# Hermetic: the jira CLI is a seam command that logs its argv; real Jira is never touched.
set -u
here="$(cd "$(dirname "$0")" && pwd)"
tool="$here/mark-deferred-escape.sh"
td="$(mktemp -d "${TMPDIR:-/tmp}/mark-deferred-escape.XXXXXX")" || { echo "FAIL - mktemp"; exit 1; }
trap 'rm -rf "$td"' EXIT
fails=0
ok(){ echo "ok - $1"; }
bad(){ echo "FAIL - $1"; fails=$((fails+1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1: [$2]!=[$3]"; }

[ -f "$tool" ] || { bad "mark-deferred-escape.sh exists"; echo "1 failed"; exit 1; }

# Residual fixtures: the first carries two class labels, the second none, the third cannot be read.
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >>"$MARK_FIX/calls"' \
  'case "$*" in "get HIMMEL-20") printf "HIMMEL-20\tTask\tTo Do\tr\n\nLabels: residual, class-fail-open, residual-depth-1, class-quoting\n" ;;' \
  '"get HIMMEL-21") printf "HIMMEL-21\tTask\tTo Do\tr\n\nLabels: residual\n" ;;' \
  '"get HIMMEL-22") exit 1 ;; esac' >"$td/jira.sh"
export MARK_FIX="$td" MARK_ESCAPE_JIRA_CMD="bash \"$td/jira.sh\""

out="$(bash "$tool" HIMMEL-10 HIMMEL-20 2>&1)"; rc=$?
check "classified residual exits 0" "$rc" 0
grep -qx 'link HIMMEL-10 HIMMEL-20 --type Relates' "$td/calls" && ok "fix relates to the residual" || bad "fix relates to the residual"
grep -qx 'edit HIMMEL-10 --add-labels deferred-escape,class-fail-open,class-quoting' "$td/calls" && ok "fix gets deferred-escape and both class labels" || bad "fix gets deferred-escape and both class labels: $(cat "$td/calls")"
printf '%s' "$out" | grep -q 'class-fail-open,class-quoting' && ok "output names the copied classes" || bad "output names the copied classes: $out"

: >"$td/calls"
out="$(bash "$tool" HIMMEL-11 HIMMEL-21 2>&1)"; rc=$?
check "unclassified residual exits 0" "$rc" 0
grep -qx 'edit HIMMEL-11 --add-labels deferred-escape' "$td/calls" && ok "no class label is copied or invented" || bad "no class label is copied or invented: $(cat "$td/calls")"
printf '%s' "$out" | grep -q 'WARN.*no class-' && ok "missing class warns" || bad "missing class warns: $out"

: >"$td/calls"
bash "$tool" HIMMEL-12 HIMMEL-22 >/dev/null 2>&1; rc=$?
check "unreadable residual exits 1" "$rc" 1
grep -q -e '^link' -e '^edit' "$td/calls" && bad "unreadable residual writes nothing" || ok "unreadable residual writes nothing"

bash "$tool" HIMMEL-10 >/dev/null 2>&1; rc=$?
check "one key is a usage error" "$rc" 64
bash "$tool" HIMMEL-10 'x;y' >/dev/null 2>&1; rc=$?
check "a malformed key is a usage error" "$rc" 64
bash "$tool" HIMMEL-10 HIMMEL-10 >/dev/null 2>&1; rc=$?
check "fix equal to residual is a usage error" "$rc" 64

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
