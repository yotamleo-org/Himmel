#!/usr/bin/env bash
# Platform guard: Linux bash 3.2+ (depends on /proc via claude-sessions.sh).
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/orphan-scan.sh"

W="$(mktemp -d "${TMPDIR:-/tmp}/orphan-scan-test.XXXXXX")" || { echo "FAIL: mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$W"' EXIT
fails=0
check()    { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
contains() { if grep -q -F -e "$3" <<< "$2"; then echo "ok - $1"; else echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); fi; }
not_contains() { if grep -q -F -e "$3" <<< "$2"; then echo "FAIL - $1: output unexpectedly contains [$3]"; fails=$((fails+1)); else echo "ok - $1"; fi; }

mkdir -p "$W/proc" "$W/bin" "$W/docs"
mkcmdline() { local pid="$1"; shift; mkdir -p "$W/proc/$pid"; printf '%s\0' "$@" > "$W/proc/$pid/cmdline"; }
pgrep_x_stub() {
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016
        printf 'if [ "$1" = "-x" ]; then printf "%%s\\n" %s; exit 0; fi\n' "$*"
        printf 'exit 1\n'
    } > "$W/bin/pgrep"
    chmod +x "$W/bin/pgrep"
}

LISTED="HIMMEL-1-N1-alpha-2026-01-01"
UNLISTED="HIMMEL-2-N2-beta-2026-01-01"
DOC="$W/docs/$LISTED.md"
FLEET="$W/chief.fleet.json"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$DOC" > "$FLEET"

mkdoc() {
    local last="$1"; shift
    { echo "# HIMMEL-1 N1 alpha"; echo; echo "## Results (newest at the bottom)"; echo; echo "- 09:00 LIVE - starting"
      for b in "$@"; do echo "$b"; done; echo "$last"; } > "$DOC"
}
mkdoc "- 09:30 LIVE - building"

cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$OS_CALLS"
case "$*" in
    "pr list "*) [ "${OS_LIST_FAIL:-0}" = 1 ] && { echo "gh-stub: list failed" >&2; exit 1; }; cat "$OS_PRS"; exit 0 ;;
    "pr view "*) cat "$OS_VIEW"; exit 0 ;;
esac
echo "gh-stub: unhandled: $*" >&2; exit 1
STUB
chmod +x "$W/bin/gh"
export OS_CALLS="$W/calls.log" OS_PRS="$W/prs.json" OS_VIEW="$W/view.json"
: > "$OS_CALLS"
SHA=0123456789abcdef0123456789abcdef01234567
printf '{"state":"OPEN","mergeCommit":null}\n' > "$OS_VIEW"
printf '[{"number":11,"headRefName":"feat/himmel-1-alpha","isCrossRepository":false,"author":{"login":"yotamleo"}},{"number":12,"headRefName":"feat/himmel-3-gamma","isCrossRepository":false,"author":{"login":"yotamleo"}}]\n' > "$OS_PRS"

mkcmdline 301 claude -n "$LISTED" work
mkcmdline 302 claude -n "$UNLISTED" work
mkcmdline 303 claude -n "luna-94" work
pgrep_x_stub 301 302 303

run() {
    PATH="$W/bin:$PATH" CLAUDE_SESSIONS_PROC="$W/proc" ORPHAN_SCAN_GH="$W/bin/gh" bash "$SCRIPT" "$@"
}

rc=0; out=$(run --fleet "$FLEET" 2>&1) || rc=$?
check "fixture: rc 0" "$rc" "0"
check "fixture: exactly two orphan lines" "$(grep -c '^# orphan ' <<< "$out")" "2"
contains "fixture: names the unlisted session" "$out" "# orphan session $UNLISTED "
contains "fixture: names the unlisted PR" "$out" "# orphan pr 12 "
not_contains "fixture: the listed worker is not an orphan" "$out" "orphan session $LISTED"
not_contains "fixture: a session outside the prefix is ignored" "$out" "luna-94"
not_contains "fixture: the listed worker's PR is not an orphan" "$out" "orphan pr 11"

mkdoc "- 10:00 READY 11 $SHA GREEN"
printf '{"state":"MERGED","mergeCommit":{"oid":"%s"}}\n' "$SHA" > "$OS_VIEW"
out=$(run --fleet "$FLEET" 2>&1)
contains "finished: a live worker with a merged PR and no WRAPPED" "$out" "# orphan finished $LISTED pr=11 merged=$SHA"

mkdoc "- 10:00 WRAPPED - done" "- 09:50 READY 11 $SHA GREEN"
out=$(run --fleet "$FLEET" 2>&1)
not_contains "wrapped doc: no finished line" "$out" "orphan finished"
mkdoc "- 10:00 READY 11 $SHA GREEN"
printf '{"state":"OPEN","mergeCommit":null}\n' > "$OS_VIEW"
out=$(run --fleet "$FLEET" 2>&1)
not_contains "open PR: no finished line" "$out" "orphan finished"
mkdoc "- 09:30 LIVE - building"
out=$(run --fleet "$FLEET" 2>&1)
not_contains "no PR in the doc: no finished line" "$out" "orphan finished"

printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}],"watch":[{"pr":12}]}\n' "$DOC" > "$FLEET"
out=$(run --fleet "$FLEET" 2>&1)
not_contains "watch row: its PR is tracked" "$out" "orphan pr 12"
printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$DOC" > "$FLEET"
printf '[{"number":13,"headRefName":"dependabot/npm/x","isCrossRepository":false,"author":{"login":"app/dependabot"}},{"number":14,"headRefName":"feat/himmel-4-f","isCrossRepository":true,"author":{"login":"someone"}}]\n' > "$OS_PRS"
out=$(run --fleet "$FLEET" 2>&1)
not_contains "dependabot PR left out" "$out" "orphan pr 13"
not_contains "fork PR left out" "$out" "orphan pr 14"
printf '[{"number":15,"headRefName":"chore/no-ticket-here","isCrossRepository":false,"author":{"login":"yotamleo"}}]\n' > "$OS_PRS"
out=$(run --fleet "$FLEET" 2>&1)
contains "a branch naming no ticket is an orphan" "$out" "# orphan pr 15 "

rm -rf "$W/proc/301" "$W/proc/302"
mkcmdline 304 claude -n "$LISTED-r2" work
mkcmdline 305 claude -n "$LISTED-RESUME" work
mkcmdline 306 claude -n "HIMMEL-chief-x" work
pgrep_x_stub 304 305 306
out=$(run --fleet "$FLEET" 2>&1)
not_contains "a -r<N> relaunch is listed" "$out" "orphan session $LISTED-r2"
not_contains "a -RESUME session is listed" "$out" "orphan session $LISTED-RESUME"
contains "an unknown session is an orphan" "$out" "# orphan session HIMMEL-chief-x "
rm -rf "$W/proc/305"
pgrep_x_stub 304 306
mkdoc "- 10:00 READY 11 $SHA GREEN"
printf '{"state":"MERGED","mergeCommit":{"oid":"%s"}}\n' "$SHA" > "$OS_VIEW"
out=$(run --fleet "$FLEET" 2>&1)
contains "a worker live only as -r<N> is finished under that name" "$out" "# orphan finished $LISTED-r2 pr=11 merged=$SHA"
mkdoc "- 09:30 LIVE - building"
pgrep_x_stub 304 305 306
mkcmdline 305 claude -n "$LISTED-RESUME" work
out=$(run --fleet "$FLEET" --self HIMMEL-chief-x 2>&1)
not_contains "--self is never an orphan" "$out" "orphan session"

pgrep_x_stub 304 306
rc=0; out=$(OS_LIST_FAIL=1 run --fleet "$FLEET" 2>&1) || rc=$?
check "list failure: rc 3" "$rc" "3"
contains "list failure: session lines still print" "$out" "# orphan session HIMMEL-chief-x "
contains "list failure: says why" "$out" "unavailable"

rc=0; run >/dev/null 2>&1 || rc=$?
check "usage: no --fleet -> rc 2" "$rc" "2"
rc=0; run --fleet "$W/none.json" >/dev/null 2>&1 || rc=$?
check "usage: unreadable manifest -> rc 2" "$rc" "2"

if [ "$fails" -eq 0 ]; then echo "ALL OK"; exit 0; else echo "FAILURES: $fails"; exit 1; fi
