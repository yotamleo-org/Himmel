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
KILLED="$WORK/killed"
LAUNCHED="$WORK/launched"
printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "'"$KILLED"'"' > "$WORK/kill-stub"
DRYRUN="$WORK/dryrun"
EFFORT="$WORK/effort"
FAILDRY="$WORK/faildry"
cat > "$WORK/launcher-stub" <<STUB_EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--dry-run" ]; then
    shift
    printf "[%s]" "\$@" >> "$DRYRUN"; echo >> "$DRYRUN"
    [ -e "$FAILDRY" ] && exit 9
    exit 0
fi
printf "[%s]" "\$@" >> "$LAUNCHED"; echo >> "$LAUNCHED"
echo "\${WORKER_SESSION_EFFORT-unset}" >> "$EFFORT"
STUB_EOF
chmod 755 "$WORK/kill-stub" "$WORK/launcher-stub"
VERDICT="$WORK/preflight-verdict"
printf '%s\n' '#!/usr/bin/env bash' 'cat "'"$VERDICT"'" 2>/dev/null || echo PROCEED' > "$WORK/preflight-stub"
chmod 755 "$WORK/preflight-stub"

# session <pid> <argv...>: a fake /proc/<pid>/cmdline, NUL-separated.
session() { local pid="$1"; shift; mkdir -p "$PROC/$pid"; printf '%s\0' "$@" > "$PROC/$pid/cmdline"; printf '%s\0' PATH=/usr/bin HIMMEL_WORKER_SESSION_PROFILE=worker-impl > "$PROC/$pid/environ"; }
record() { # <name> <profile> <lane> [role] [session id] [model] [extra]
    local sid="${5:+ session_id=$5}"
    printf 'headed-arm-worker: profile=%s lane=%s model=%s role=%s session=%s%s launched=2026-10-31T10:00:00Z%s\n' "$2" "$3" "${6:-claude-sonnet-5-5}" "${4:-worker}" "$1" "$sid" "${7:-}" >> "$CACHE/launch-logs/$1.log"
}
environ() { local pid="$1"; shift; mkdir -p "$PROC/$pid"; printf '%s\0' "$@" > "$PROC/$pid/environ"; }
run() { # <args...> -> sets out, rc
    rc=0
    out="$(ENABLE_RC_BEFORE_KILL='' ENABLE_RC_PROC="$PROC" HIMMELCTL_CACHE_DIR="$CACHE" ENABLE_RC_KILL_CMD="$WORK/kill-stub" ENABLE_RC_LAUNCHER="$WORK/launcher-stub" ENABLE_RC_PREFLIGHT="$WORK/preflight-stub" \
        bash "$ERC" "$@" 2>&1)" || rc=$?
}
reset() { rm -f "$KILLED" "$LAUNCHED" "$DRYRUN" "$EFFORT" "$FAILDRY" "$VERDICT"; }

DOC="/h/HIMMEL-1-w.md"
# --- (a) usage ---------------------------------------------------------------
run
check "a: no args exits 2" "2" "$rc"

# --- (b) no live session by that name ------------------------------------------
reset; run --relaunch HIMMEL-1-w /s 99999999999 /l
check "b: no live session exits 3" "3" "$rc"
check "b: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (c) already on ------------------------------------------------------------
session 1001 claude --session-id sid-1001 --remote-control HIMMEL-1-w --model claude-sonnet-5-5 --autocompact 450000 -n HIMMEL-1-w "load $DOC and continue"
reset; run --relaunch HIMMEL-1-w /s 99999999999 /l
check "c: already enabled exits 0" "0" "$rc"
has "c: says already" "$out" "already"
check "c: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
rm -rf "$PROC/1001"

# --- (d) off, no --relaunch: report the plan, destroy nothing --------------------
session 1002 claude --session-id sid-1002 --model claude-sonnet-5-5 --autocompact 450000 -n HIMMEL-2-w "load /h/HIMMEL-2-w.md and continue"
record HIMMEL-2-w worker-impl native worker sid-1002
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
session 1003 claude --session-id sid-1003 --model gpt-6.1-sol -n HIMMEL-3-w "load /h/HIMMEL-3-w.md and continue"
record HIMMEL-3-w worker-impl claudex worker sid-1003 gpt-6.1-sol
reset; run --relaunch HIMMEL-3-w /s 99999999999 /l
check "f: claudex exits 4" "4" "$rc"
check "f: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (g) no launch record / no profile: no Remote Control seam, nothing destroyed -
session 1004 claude --session-id sid-1004 --model claude-sonnet-5-5 -n HIMMEL-4-w "load /h/HIMMEL-4-w.md and continue"
reset; run --relaunch HIMMEL-4-w /s 99999999999 /l
check "g: no launch record exits 4" "4" "$rc"
record HIMMEL-4-w none native worker sid-1004
reset; run --relaunch HIMMEL-4-w /s 99999999999 /l
check "g: an unprofiled launch exits 4" "4" "$rc"
check "g: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (h) a prompt that merely names the worker is not the session ----------------
session 1005 claude --session-id sid-1005 --model claude-sonnet-5-5 -n HIMMEL-5-other "load /h/x.md; -n HIMMEL-6-w"
reset; run --relaunch HIMMEL-6-w /s 99999999999 /l
check "h: only an exact -n element matches" "3" "$rc"

# --- (i) the pid is recycled between the scan and the kill: nothing is signalled ----
session 1006 claude --session-id sid-1006 --model claude-sonnet-5-5 -n HIMMEL-7-w "load /h/HIMMEL-7-w.md and continue"
record HIMMEL-7-w worker-impl native worker sid-1006
# shellcheck disable=SC2016 # the $1/$2 belong to the stub script, not this one
printf '%s\n' '#!/usr/bin/env bash' 'printf "unrelated\0--version\0" > "$2/$1/cmdline"' > "$WORK/recycle-stub"
chmod 755 "$WORK/recycle-stub"
reset; rc=0
out="$(ENABLE_RC_BEFORE_KILL="$WORK/recycle-stub" ENABLE_RC_PROC="$PROC" HIMMELCTL_CACHE_DIR="$CACHE" ENABLE_RC_KILL_CMD="$WORK/kill-stub" ENABLE_RC_LAUNCHER="$WORK/launcher-stub" ENABLE_RC_PREFLIGHT="$WORK/preflight-stub" \
    bash "$ERC" --relaunch HIMMEL-7-w /s 99999999999 /l 2>&1)" || rc=$?
check "i: a recycled pid exits 6" "6" "$rc"
check "i: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (j) a consult, judge or relay is never relaunched as a plain worker -----------
for r in consult judge relay; do
    session 1010 claude --session-id sid-1010 --model claude-opus-5-5 -n HIMMEL-8-$r "load /h/HIMMEL-8-$r.md and continue"
    record HIMMEL-8-$r worker-impl native $r sid-1010 claude-opus-5-5
    reset; run --relaunch HIMMEL-8-$r /s 99999999999 /l
    check "j: role=$r exits 4" "4" "$rc"
    check "j: role=$r nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
done
session 1011 claude --session-id sid-1011 --model claude-sonnet-5-5 -n HIMMEL-9-w "load /h/HIMMEL-9-w.md and continue"
printf 'headed-arm-worker: profile=worker-impl lane=native model=x session=HIMMEL-9-w launched=2026-10-31T10:00:00Z\n' >> "$CACHE/launch-logs/HIMMEL-9-w.log"
reset; run --relaunch HIMMEL-9-w /s 99999999999 /l
check "j: a record with no role exits 4" "4" "$rc"

# --- (k) the profile comes from the record line of THIS session, never the last line --
session 1020 claude --session-id sid-1020-a --model claude-sonnet-5-5 --autocompact 450000 -n HIMMEL-10-w "load /h/HIMMEL-10-w.md and continue"
record HIMMEL-10-w worker-impl native worker sid-1020-a
record HIMMEL-10-w worker-impl,design native worker sid-1020-b
reset; run --relaunch HIMMEL-10-w /s 99999999999 /l
check "k: relaunch exits 0" "0" "$rc"
check "k: the profile is the live session's own, not the later line's" \
    "[--profile][worker-impl][--lane][native][HIMMEL-10-w][/h/HIMMEL-10-w.md][/s][99999999999][/l][claude-sonnet-5-5]" \
    "$(cat "$LAUNCHED" 2>/dev/null)"

# --- (l) no record line for the live session id, a duplicated one, a model mismatch, no id ---
session 1021 claude --session-id sid-1021 --model claude-sonnet-5-5 -n HIMMEL-11-w "load /h/HIMMEL-11-w.md and continue"
record HIMMEL-11-w worker-impl native worker sid-other
reset; run --relaunch HIMMEL-11-w /s 99999999999 /l
check "l: no line for this session id exits 4" "4" "$rc"
check "l: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1022 claude --session-id sid-1022 --model claude-sonnet-5-5 -n HIMMEL-12-w "load /h/HIMMEL-12-w.md and continue"
record HIMMEL-12-w worker-impl native worker sid-1022
record HIMMEL-12-w worker-impl native worker sid-1022
reset; run --relaunch HIMMEL-12-w /s 99999999999 /l
check "l: two lines for one session id (ambiguous) exits 4" "4" "$rc"
check "l: ambiguous: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1023 claude --session-id sid-1023 --model claude-opus-5-5 -n HIMMEL-13-w "load /h/HIMMEL-13-w.md and continue"
record HIMMEL-13-w worker-impl native worker sid-1023 claude-sonnet-5-5
reset; run --relaunch HIMMEL-13-w /s 99999999999 /l
check "l: a record model that differs from the live --model exits 4" "4" "$rc"
check "l: model mismatch: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1024 claude --model claude-sonnet-5-5 -n HIMMEL-14-w "load /h/HIMMEL-14-w.md and continue"
record HIMMEL-14-w worker-impl native worker sid-1024
reset; run --relaunch HIMMEL-14-w /s 99999999999 /l
check "l: a live argv with no --session-id exits 4" "4" "$rc"
check "l: no session id: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (m) the launcher is dry-run BEFORE the kill; a failing dry-run kills nothing -------
session 1025 claude --session-id sid-1025 --model claude-sonnet-5-5 -n HIMMEL-15-w "load /h/HIMMEL-15-w.md and continue"
record HIMMEL-15-w worker-impl native worker sid-1025
reset; : > "$FAILDRY"; run --relaunch HIMMEL-15-w /s 99999999999 /l
check "m: a failing launcher dry-run exits 7" "7" "$rc"
check "m: a failing dry-run kills and launches nothing" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
has "m: the dry-run ran" "$(cat "$DRYRUN" 2>/dev/null)" "[--profile][worker-impl]"
reset; run --relaunch HIMMEL-15-w /s 99999999999 /l
check "m: a passing dry-run relaunches (exit 0)" "0" "$rc"
check "m: the dry-run argv equals the launch argv" "$(cat "$DRYRUN" 2>/dev/null)" "$(cat "$LAUNCHED" 2>/dev/null)"
check "m: the old pid was killed" "1025" "$(cat "$KILLED" 2>/dev/null)"

# --- (n) the owning chief and WORKER_SESSION_EFFORT are carried onto the relaunch -------
session 1026 claude --session-id sid-1026 --model claude-sonnet-5-5 -n HIMMEL-16-w "load /h/HIMMEL-16-w.md and continue"
record HIMMEL-16-w worker-impl native worker sid-1026
environ 1026 PATH=/usr/bin HIMMEL_WORKER_SESSION_PROFILE=worker-impl HIMMEL_CONSOLE_NAME=opsdesk WORKER_SESSION_EFFORT=high
reset; run --relaunch HIMMEL-16-w /s 99999999999 /l
check "n: relaunch exits 0" "0" "$rc"
check "n: --chief <owner> reaches the launch" \
    "[--profile][worker-impl][--lane][native][--chief][opsdesk][HIMMEL-16-w][/h/HIMMEL-16-w.md][/s][99999999999][/l][claude-sonnet-5-5]" \
    "$(cat "$LAUNCHED" 2>/dev/null)"
check "n: the dry-run carries the same chief" "$(cat "$DRYRUN" 2>/dev/null)" "$(cat "$LAUNCHED" 2>/dev/null)"
check "n: WORKER_SESSION_EFFORT reaches the launch env" "high" "$(cat "$EFFORT" 2>/dev/null)"

# --- (o) launch inputs a relaunch cannot restore refuse -------------------------------
session 1027 claude --session-id sid-1027 --model claude-opus-5-5 -n HIMMEL-17-rm "load /h/HIMMEL-17-rm.md and continue"
record HIMMEL-17-rm release-manager native worker sid-1027 claude-opus-5-5
reset; run --relaunch HIMMEL-17-rm /s 99999999999 /l
check "o: profile=release-manager exits 4" "4" "$rc"
check "o: release-manager: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1028 claude --session-id sid-1028 --model claude-sonnet-5-5 -n HIMMEL-18-w "load /h/HIMMEL-18-w.md and continue"
record HIMMEL-18-w worker-impl native worker sid-1028 claude-sonnet-5-5 " ab_arm=200k"
reset; run --relaunch HIMMEL-18-w /s 99999999999 /l
check "o: an A/B arm record exits 4" "4" "$rc"
check "o: A/B arm: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
for envkv in WORKER_SESSION_AUTOCOMPACT_AB=200000 HIMMEL_WORKER_SESSION_CONTEXT_MODE=compact; do
    session 1029 claude --session-id sid-1029 --model claude-sonnet-5-5 -n HIMMEL-19-w "load /h/HIMMEL-19-w.md and continue"
    rm -f "$CACHE/launch-logs/HIMMEL-19-w.log"
    record HIMMEL-19-w worker-impl native worker sid-1029
    environ 1029 PATH=/usr/bin HIMMEL_WORKER_SESSION_PROFILE=worker-impl "$envkv"
    reset; run --relaunch HIMMEL-19-w /s 99999999999 /l
    check "o: environ ${envkv%%=*} exits 4" "4" "$rc"
    check "o: ${envkv%%=*}: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
done

# --- (p) an environment that cannot be read fails closed; an ambient effort is not inherited ---
session 1030 claude --session-id sid-1030 --model claude-sonnet-5-5 -n HIMMEL-20-w "load /h/HIMMEL-20-w.md and continue"
record HIMMEL-20-w worker-impl native worker sid-1030
rm -f "$PROC/1030/environ"
reset; run --relaunch HIMMEL-20-w /s 99999999999 /l
check "p: a missing environ exits 4" "4" "$rc"
check "p: missing environ: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1031 claude --session-id sid-1031 --model claude-sonnet-5-5 -n HIMMEL-21-w "load /h/HIMMEL-21-w.md and continue"
record HIMMEL-21-w worker-impl native worker sid-1031
chmod 000 "$PROC/1031/environ"
if [ -r "$PROC/1031/environ" ]; then
    echo "SKIP: p: chmod 000 still readable here (running as root?)"
else
    reset; run --relaunch HIMMEL-21-w /s 99999999999 /l
    check "p: an unreadable environ exits 4" "4" "$rc"
    check "p: unreadable environ: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
fi
session 1032 claude --session-id sid-1032 --model claude-sonnet-5-5 -n HIMMEL-22-w "load /h/HIMMEL-22-w.md and continue"
record HIMMEL-22-w worker-impl native worker sid-1032
reset; rc=0
out="$(WORKER_SESSION_EFFORT=ambient-leak ENABLE_RC_BEFORE_KILL='' ENABLE_RC_PROC="$PROC" HIMMELCTL_CACHE_DIR="$CACHE" ENABLE_RC_KILL_CMD="$WORK/kill-stub" ENABLE_RC_LAUNCHER="$WORK/launcher-stub" ENABLE_RC_PREFLIGHT="$WORK/preflight-stub" \
    bash "$ERC" --relaunch HIMMEL-22-w /s 99999999999 /l 2>&1)" || rc=$?
check "p: relaunch of a session with no effort exits 0" "0" "$rc"
check "p: the caller's ambient WORKER_SESSION_EFFORT does not reach the relaunch" "unset" "$(cat "$EFFORT" 2>/dev/null)"

# --- (q) the record is same-uid and unfenced: its profile must equal the live process's ---
session 1033 claude --session-id sid-1033 --model claude-sonnet-5-5 -n HIMMEL-23-w "load /h/HIMMEL-23-w.md and continue"
record HIMMEL-23-w worker-impl native worker sid-1033
reset; run --relaunch HIMMEL-23-w /s 99999999999 /l
check "q: control: an untouched record relaunches (exit 0)" "0" "$rc"
rm -f "$CACHE/launch-logs/HIMMEL-23-w.log"
record HIMMEL-23-w operator native worker sid-1033
reset; run --relaunch HIMMEL-23-w /s 99999999999 /l
check "q: a record rewritten in place to a wider profile exits 4" "4" "$rc"
check "q: rewritten record: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
session 1034 claude --session-id sid-1034 --model claude-sonnet-5-5 -n HIMMEL-24-w "load /h/HIMMEL-24-w.md and continue"
record HIMMEL-24-w worker-impl native worker sid-1034
environ 1034 PATH=/usr/bin
reset; run --relaunch HIMMEL-24-w /s 99999999999 /l
check "q: a live session whose environ names no profile exits 4" "4" "$rc"
check "q: no environ profile: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"

# --- (r) the usage preflight runs BEFORE the kill: a refused bank leaves the worker alive ---
session 1035 claude --session-id sid-1035 --model claude-sonnet-5-5 -n HIMMEL-25-w "load /h/HIMMEL-25-w.md and continue"
record HIMMEL-25-w worker-impl native worker sid-1035
for verdict in SKIPPED-BANK SKIPPED-FLEET; do
    reset; printf '%s\n' "$verdict" > "$VERDICT"; run --relaunch HIMMEL-25-w /s 99999999999 /l
    check "r: $verdict exits 8" "8" "$rc"
    check "r: $verdict: nothing killed or launched" "" "$(cat "$KILLED" "$LAUNCHED" 2>/dev/null)"
done
reset; printf '%s\n' PROCEED > "$VERDICT"; run --relaunch HIMMEL-25-w /s 99999999999 /l
check "r: PROCEED relaunches (exit 0)" "0" "$rc"
check "r: PROCEED: the old pid was killed" "1035" "$(cat "$KILLED" 2>/dev/null)"

echo "---"
if [ "$fails" -eq 0 ]; then echo "PASS - test-enable-remote-control.sh"; exit 0; fi
echo "FAIL - test-enable-remote-control.sh ($fails failure(s))"; exit 1
