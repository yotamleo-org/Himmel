#!/usr/bin/env bash
# test-enable-remote-control.sh - enable-remote-control.sh turns Remote
# Control on for a named native worker by relaunching it with the flag. Scratch
# proc tree, launch record, kill and launcher stubs only: nothing real is killed
# or launched. bash 3.2-safe.
#
# Run: bash scripts/handover/chief-kit/test-enable-remote-control.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ERC="${ENABLE_REMOTE_CONTROL:-$HERE/enable-remote-control.sh}"

fails=0
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else echo "FAIL: $1 (want '$2' got '$3')"; fails=$((fails + 1)); fi
}
has() { # <name> <haystack> <needle>
    case "$2" in *"$3"*) echo "PASS: $1" ;; *) echo "FAIL: $1 (no '$3' in '$2')"; fails=$((fails + 1)) ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/enable-rc-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT
PROC="$WORK/proc"; CACHE="$WORK/cache"; mkdir -p "$PROC" "$CACHE/launch-logs"
KILLED="$WORK/killed"; LAUNCHED="$WORK/launched"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "'"$KILLED"'"' > "$WORK/kill-stub"
printf '%s\n' '#!/usr/bin/env bash' 'printf "[%s]" "$@" >> "'"$LAUNCHED"'"; echo >> "'"$LAUNCHED"'"' > "$WORK/launcher-stub"
chmod 755 "$WORK/kill-stub" "$WORK/launcher-stub"

# session <pid> <argv...>: a fake /proc/<pid>/cmdline, NUL-separated.
session() { local pid="$1"; shift; mkdir -p "$PROC/$pid"; printf '%s\0' "$@" > "$PROC/$pid/cmdline"; }
record() { # <name> <profile> <lane>
    printf 'headed-arm-worker: profile=%s lane=%s model=claude-sonnet-5-5 role=worker session=%s launched=2026-10-31T10:00:00Z\n' "$2" "$3" "$1" >> "$CACHE/launch-logs/$1.log"
}
run() { # <args...> -> sets out, rc
    rc=0
    out="$(ENABLE_RC_PROC="$PROC" HIMMELCTL_CACHE_DIR="$CACHE" ENABLE_RC_KILL_CMD="$WORK/kill-stub" ENABLE_RC_LAUNCHER="$WORK/launcher-stub" \
        bash "$ERC" "$@" 2>&1)" || rc=$?
}
reset() { rm -f "$KILLED" "$LAUNCHED"; }

DOC="/h/HIMMEL-1-w.md"
# --- (a) usage ---------------------------------------------------------------
run
check "a: no args exits 2" "2" "$rc"

# --- (b) no live session by that name ------------------------------------------
reset; run --relaunch HIMMEL-1-w /s 99999999999 /l
check "b: no live session exits 3" "3" "$rc"
check "b: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (c) already on ------------------------------------------------------------
session 1001 claude --remote-control HIMMEL-1-w --model claude-sonnet-5-5 --autocompact 450000 -n HIMMEL-1-w "load $DOC and continue"
reset; run --relaunch HIMMEL-1-w /s 99999999999 /l
check "c: already enabled exits 0" "0" "$rc"
has "c: says already" "$out" "already"
check "c: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
rm -rf "$PROC/1001"

# --- (d) off, no --relaunch: report the plan, destroy nothing --------------------
session 1002 claude --model claude-sonnet-5-5 --autocompact 450000 -n HIMMEL-2-w "load /h/HIMMEL-2-w.md and continue"
record HIMMEL-2-w worker-impl native
reset; run HIMMEL-2-w /s 99999999999 /l
check "d: off without --relaunch exits 5" "5" "$rc"
has "d: names the relaunch" "$out" "--relaunch"
check "d: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (e) off, --relaunch, native: kill the pid, relaunch with the same args ------
reset; run --relaunch HIMMEL-2-w /s 99999999999 /l
check "e: relaunch exits 0" "0" "$rc"
check "e: the old pid is the only one killed" "1002" "$(cat "$KILLED" 2>/dev/null)"
check "e: relaunched through the worker launcher with profile, native lane, doc and model" \
    "[--profile][worker-impl][--lane][native][HIMMEL-2-w][/h/HIMMEL-2-w.md][/s][99999999999][/l][claude-sonnet-5-5]" \
    "$(cat "$LAUNCHED" 2>/dev/null)"

# --- (f) a claudex worker is ineligible, nothing destroyed -----------------------
session 1003 claude --model gpt-6.1-sol -n HIMMEL-3-w "load /h/HIMMEL-3-w.md and continue"
record HIMMEL-3-w worker-impl claudex
reset; run --relaunch HIMMEL-3-w /s 99999999999 /l
check "f: claudex exits 4" "4" "$rc"
check "f: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (g) no launch record / no profile: no Remote Control seam, nothing destroyed -
session 1004 claude --model claude-sonnet-5-5 -n HIMMEL-4-w "load /h/HIMMEL-4-w.md and continue"
reset; run --relaunch HIMMEL-4-w /s 99999999999 /l
check "g: no launch record exits 4" "4" "$rc"
record HIMMEL-4-w none native
reset; run --relaunch HIMMEL-4-w /s 99999999999 /l
check "g: an unprofiled launch exits 4" "4" "$rc"
check "g: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (h) a prompt that merely names the worker is not the session ----------------
session 1005 claude --model claude-sonnet-5-5 -n HIMMEL-5-other "load /h/x.md; -n HIMMEL-6-w"
reset; run --relaunch HIMMEL-6-w /s 99999999999 /l
check "h: only an exact -n element matches" "3" "$rc"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-enable-remote-control.sh"; exit 0; fi
echo "FAIL - test-enable-remote-control.sh ($fails failure(s))"; exit 1
