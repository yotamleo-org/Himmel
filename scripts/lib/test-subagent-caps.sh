#!/usr/bin/env bash
# Tests for scripts/lib/subagent-caps.sh and the launch paths that use it:
# every claude session himmel launches starts with
# CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2 and CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=20,
# and a Haiku session starts with the Agent tool disallowed.
#
#   1. HELPER   the values, the Haiku match, the --disallowedTools args.
#   2. WORKER   worker-claude-launcher.sh (the exec point of every
#               headed-arm-worker.sh native and claudex worker) hands both
#               values to the binary it execs; a Haiku --model adds
#               --disallowedTools Agent in front, any other model adds nothing.
#   3. HEADED   headed-arm.sh: the dry-run env line and the konsole tab both
#               carry the values; the tab's session receives them (a konsole
#               stub runs what follows -e, as a real tab would, and a launcher
#               stub records its env).
#   3b. CHIEF   chief.sh's printed chief launch line carries both values in
#               the env prefix of each of its two claude commands
#               (fixture: chief/test-chief.sh's shape, scripts/handover and
#               scripts/lib copied, the rest linked, an always-OK bus).
#   3c. ARM     arm-resume.sh's relaunch entry exports both values, and a
#               Haiku --model gets --disallowedTools Agent (fixture: the
#               cron backend of test-arm-resume.sh case 2545b, HOME pinned).
#   4. CHAIN    headed-arm-worker.sh launches through headed-arm.sh with
#               worker-claude-launcher.sh as the launcher.
#   5. SITES    every launch env line (one that sets
#               CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1) in a launch site
#               names the helper's caps on that line or the next to it, and
#               the site sources the helper. A fixture launch site without the
#               helper FAILS the check; the same fixture with it passes.
#   6. NEW      every non-test file under scripts/ with such a line is a
#               known launch site or a listed hint-only file (one that prints
#               a relaunch command for the operator and launches nothing), so a
#               new launch site without the caps fails here.
#
# Usage: bash scripts/lib/test-subagent-caps.sh
# Platform guard: any POSIX bash 3.2+; the HEADED cases stub konsole and
# pgrep, so they run on Linux and macOS alike (HEADED_ARM_UNAME=Linux).
# shellcheck disable=SC2016  # single-quoted fixture scripts and source text, expanded later or never
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
LIB="$HERE/subagent-caps.sh"
LAUNCHER="$ROOT/scripts/lanes/worker-claude-launcher.sh"
HEADED_ARM="$ROOT/scripts/handover/headed-arm.sh"
HAW="$ROOT/scripts/handover/chief-kit/headed-arm-worker.sh"

. "$HERE/fixture-tempdir.sh" || exit 1
TMP=$(fixture_mktemp_dir) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 300)" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

DEPTH="CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2"
CONC="CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=20"

echo "=== 1. helper ==="
# shellcheck source=subagent-caps.sh
. "$LIB"
check "helper: SUBAGENT_CAPS_ENV holds exactly the two pairs" "${SUBAGENT_CAPS_ENV[*]}" "$DEPTH $CONC"
got=$(env -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS \
    bash -c '. "$1"; subagent_caps_export; printf "%s %s" "$CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH" "$CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"' _ "$LIB")
check "helper: subagent_caps_export exports 2 and 20" "$got" "2 20"
for m in haiku claude-haiku-5-5 Haiku 'haiku[1m]'; do
    if subagent_caps_is_haiku "$m"; then ok "helper: $m is Haiku"; else bad "helper: $m is Haiku"; fi
done
for m in sonnet opus claude-opus-5-5 fable '' haikus; do
    if subagent_caps_is_haiku "$m"; then bad "helper: '$m' is not Haiku"; else ok "helper: '$m' is not Haiku"; fi
done
subagent_caps_haiku_args --model haiku -n x "load doc"
check "helper: --model haiku -> --disallowedTools Agent" "${SUBAGENT_CAPS_HAIKU_ARGS[*]-}" "--disallowedTools Agent"
subagent_caps_haiku_args --model=claude-haiku-5-5 "load doc"
check "helper: --model=claude-haiku-5-5 -> --disallowedTools Agent" "${SUBAGENT_CAPS_HAIKU_ARGS[*]-}" "--disallowedTools Agent"
subagent_caps_haiku_args --model sonnet -n x "haiku"
check "helper: --model sonnet (prompt says haiku) -> nothing" "${SUBAGENT_CAPS_HAIKU_ARGS[*]-}" ""
subagent_caps_haiku_args -n x "load doc"
check "helper: no --model -> nothing" "${SUBAGENT_CAPS_HAIKU_ARGS[*]-}" ""

echo ""
echo "=== 2. worker-claude-launcher.sh ==="
STUB="$TMP/claude-stub"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
env | grep '^CLAUDE_CODE_MAX_' > "$STUB_OUT.env"
printf '%s\n' "$@" > "$STUB_OUT.argv"
EOF
chmod 755 "$STUB"
run_launcher() {
    local out="$1"; shift
    env -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS \
        -u WORKER_SESSION_PROFILE_SETTINGS -u WORKER_SESSION_PROFILE_PREFACE -u WORKER_SESSION_PROFILE_MCP_CONFIG \
        -u WORKER_SESSION_PROFILE_NO_SETTING_SOURCES -u WORKER_SESSION_PROFILE_READINESS -u WORKER_SESSION_RENDER_ARGV \
        -u WORKER_SESSION_ID -u WORKER_SESSION_REMOTE_CONTROL \
        WORKER_SESSION_CLAUDE_BIN="$STUB" STUB_OUT="$out" bash "$LAUNCHER" "$@"
}
run_launcher "$TMP/w1" --model claude-sonnet-5-5 --autocompact auto -n W1 "load doc and continue"
w1env="$(cat "$TMP/w1.env" 2>/dev/null)"
has "worker: the session gets the spawn depth" "$w1env" "$DEPTH"
has "worker: the session gets the concurrency cap" "$w1env" "$CONC"
check "worker: a Sonnet argv reaches claude unchanged" "$(tr '\n' ' ' < "$TMP/w1.argv")" "--model claude-sonnet-5-5 --autocompact auto -n W1 load doc and continue "
run_launcher "$TMP/w2" --model haiku --autocompact auto -n W2 "load doc and continue"
check "worker: a Haiku session starts with the Agent tool disallowed, in front of the caller's argv" \
    "$(tr '\n' ' ' < "$TMP/w2.argv")" "--disallowedTools Agent --model haiku --autocompact auto -n W2 load doc and continue "
has "worker: the Haiku session gets the caps too" "$(cat "$TMP/w2.env" 2>/dev/null)" "$DEPTH"
run_launcher "$TMP/w3" --model claude-haiku-5-5 -n W3 "load doc and continue"
has "worker: the full Haiku id disallows the Agent tool" "$(tr '\n' ' ' < "$TMP/w3.argv")" "--disallowedTools Agent --model claude-haiku-5-5"

echo ""
echo "=== 3. headed-arm.sh ==="
HA_STUBS="$TMP/ha"; mkdir -p "$HA_STUBS/proc/9001" "$HA_STUBS/locks"
printf '#!/bin/sh\necho "2.1.296 (Claude Code)"\n' > "$HA_STUBS/claude-cli"; chmod 755 "$HA_STUBS/claude-cli"
echo claude > "$HA_STUBS/proc/9001/comm"
printf 'claude\0--model\0claude-opus-5-5\0-n\0%s\0load doc and continue\0' "HIMMEL-caps-worker" > "$HA_STUBS/proc/9001/cmdline"
cat > "$HA_STUBS/konsole" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$(dirname "$0")/record"
while [ $# -gt 0 ] && [ "$1" != "-e" ]; do shift; done
shift
"$@" > /dev/null 2>&1
: > "$(dirname "$0")/confirmable"
sleep 2
EOF
chmod 755 "$HA_STUBS/konsole"
cat > "$HA_STUBS/pgrep" <<'EOF'
#!/usr/bin/env bash
if [ -e "$(dirname "$0")/confirmable" ]; then echo 9001; exit 0; fi
exit 1
EOF
chmod 755 "$HA_STUBS/pgrep"
cat > "$HA_STUBS/launcher" <<'EOF'
#!/usr/bin/env bash
env | grep '^CLAUDE_CODE_MAX_' > "$(dirname "$0")/session.env"
EOF
chmod 755 "$HA_STUBS/launcher"
REPO_FX="$TMP/repo"; mkdir -p "$REPO_FX" "$TMP/home"
HA_LAUNCHER_ENV=""
HA_MODEL=""
PAST=$(( $(date +%s) - 100 ))
run_headed_arm() {
    env -u CHIEF_CONTEXT -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS \
        -u HEADED_ARM_LAUNCHER_ENV -u HEADED_ARM_LAUNCHER_ENV_LINES -u HEADED_ARM_RECORDER \
        -u HEADED_ARM_ALLOW_TICKET_DUP -u HIMMEL_LAUNCH_GUARD_WARNED \
        UNGUARDED_LAUNCH_OK=1 HOME="$TMP/home" HIMMELCTL_CACHE_DIR="$TMP/himmelctl-cache" \
        HEADED_ARM_UNAME=Linux HEADED_ARM_CLAUDE_CLI="$HA_STUBS/claude-cli" HEADED_ARM_LAUNCHER="$HA_STUBS/launcher" \
        KONSOLE_CMD="$HA_STUBS/konsole" PGREP_CMD="$HA_STUBS/pgrep" HEADED_ARM_REPO="$REPO_FX" \
        HEADED_ARM_LOCK_DIR="$HA_STUBS/locks" HEADED_ARM_PROC="$HA_STUBS/proc" \
        ${HA_LAUNCHER_ENV:+HEADED_ARM_LAUNCHER_ENV="$HA_LAUNCHER_ENV"} \
        bash "$HEADED_ARM" "$@" "HIMMEL-caps-worker" "some/handover-doc.md" "$HA_STUBS/signal-never" "$PAST" "$HA_STUBS/log" ${HA_MODEL:+"$HA_MODEL"}
}
dry="$(run_headed_arm --dry-run 2>&1)"
has "headed: the dry-run env line carries the spawn depth" "$dry" "$DEPTH"
has "headed: the dry-run env line carries the concurrency cap" "$dry" "$CONC"
run_headed_arm > "$TMP/ha.out" 2>&1; harc=$?
check "headed: the konsole launch exits 0" "$harc" "0"
n=0; while [ ! -s "$HA_STUBS/session.env" ] && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n + 1)); done
has "headed: the konsole tab argv carries the spawn depth" "$(cat "$HA_STUBS/record" 2>/dev/null)" "$DEPTH"
sess="$(cat "$HA_STUBS/session.env" 2>/dev/null)"
has "headed: the tab's session receives the spawn depth" "$sess" "$DEPTH"
has "headed: the tab's session receives the concurrency cap" "$sess" "$CONC"
rm -rf "$HA_STUBS/record" "$HA_STUBS/confirmable" "$HA_STUBS/session.env" "$HA_STUBS/locks"
HA_LAUNCHER_ENV="CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=9" run_headed_arm > "$TMP/ha2.out" 2>&1
n=0; while [ ! -s "$HA_STUBS/session.env" ] && [ "$n" -lt 40 ]; do sleep 0.05; n=$((n + 1)); done
check "headed: a launcher-env duplicate cannot override the spawn depth" \
    "$(grep '^CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=' "$HA_STUBS/session.env" 2>/dev/null)" "$DEPTH"
hdry="$(HA_MODEL=haiku run_headed_arm --dry-run 2>&1)"
has "headed: a direct Haiku launch starts with the Agent tool disallowed" "$hdry" "--disallowedTools Agent --model haiku"
lacks "headed: a non-Haiku launch keeps the Agent tool" "$dry" "--disallowedTools"

echo ""
echo "=== 3b. chief.sh's printed chief launch line ==="
CFX="$TMP/chief-repo"; mkdir -p "$CFX/scripts" "$CFX/docs" "$TMP/chief-root" "$TMP/chief-work"
git init -q "$CFX"
for _e in "$ROOT"/scripts/* "$ROOT"/docs/*; do
    case "$_e" in
        "$ROOT/scripts/handover"|"$ROOT/scripts/lib") cp -R "$_e" "$CFX/scripts/" ;;
        "$ROOT/docs/handover") cp -R "$_e" "$CFX/docs/" ;;
        "$ROOT"/scripts/*) ln -s "$_e" "$CFX/scripts/${_e##*/}" ;;
        *) ln -s "$_e" "$CFX/docs/${_e##*/}" ;;
    esac
done
mkdir -p "$CFX/marketplace/plugins/himmel-bus/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CFX/marketplace/plugins/himmel-bus/bin/bus"
chmod +x "$CFX/marketplace/plugins/himmel-bus/bin/bus"
cline="$( cd "$CFX" && env -u CHIEF_CONTEXT HANDOVER_DIR="$TMP/chief-root" USER_SLUG=tester JIRA_PROJECT_KEY=DEMO \
    CHIEF_WORK_DIR="$TMP/chief-work" bash "$CFX/scripts/handover/chief/chief.sh" new --bucket capsrepo --dry-run 2>&1 | grep -E '^(would-)?launch: ' )"
has "chief: the printed launch line exports the spawn depth" "$cline" "$DEPTH"
has "chief: the printed launch line exports the concurrency cap" "$cline" "$CONC"
check "chief: both claude commands (bus-exec and direct) carry the caps in their env prefix" \
    "$(printf '%s\n' "$cline" | grep -oE -- "-u NO_COLOR $DEPTH $CONC CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude " | wc -l | tr -d ' ')" "2"

echo ""
echo "=== 3c. arm-resume.sh's relaunch entry (cron backend, dry run) ==="
AFX="$TMP/arm"; mkdir -p "$AFX/bin" "$AFX/home" "$AFX/ho" "$AFX/repo"
git init -q "$AFX/repo"
printf '#!/bin/sh\nexit 0\n' > "$AFX/bin/claude"; chmod +x "$AFX/bin/claude"
printf '#!/bin/sh\ncase "$1" in -l) cat "%s/store" 2>/dev/null ;; -) cat > "%s/store" ;; esac\nexit 0\n' "$AFX" "$AFX" > "$AFX/bin/crontab"
chmod +x "$AFX/bin/crontab"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n# t\n' "$AFX/repo" > "$AFX/ho/h.md"
soon=$(python3 -I -c 'import datetime; print((datetime.datetime.now() + datetime.timedelta(minutes=20)).strftime("%H:%M"))')
arm_dry() {
    env -u CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH -u CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS \
        HOME="$AFX/home" HANDOVER_DIR="$AFX/ho" PATH="$AFX/bin:$PATH" OSTYPE=darwin23 \
        bash "$ROOT/scripts/handover/arm-resume.sh" --time "$soon" --handover "$AFX/ho/h.md" --dry-run "$@" 2>&1
}
aout="$(arm_dry)"
has "arm-resume: the relaunch entry exports both caps" "$aout" "export $DEPTH $CONC && export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"
lacks "arm-resume: an Opus relaunch keeps the Agent tool" "$aout" "--disallowedTools"
aout="$(arm_dry --model haiku)"
has "arm-resume: a Haiku relaunch starts with the Agent tool disallowed" "$aout" "--model haiku --disallowedTools Agent --autocompact"

echo ""
echo "=== 4. headed-arm-worker.sh launches through the two wired exec points ==="
hawsrc="$(cat "$HAW")"
has "chain: headed-arm-worker.sh sets worker-claude-launcher.sh as the launcher" "$hawsrc" 'HEADED_ARM_LAUNCHER="${HEADED_ARM_WORKER_SHIM:-$HERE/../../lanes/worker-claude-launcher.sh}"'
has "chain: headed-arm-worker.sh execs headed-arm.sh" "$hawsrc" '../headed-arm.sh'

echo ""
echo "=== 5. every launch env line in a launch site carries the caps ==="
site_check() {
    grep -q 'lib/subagent-caps\.sh' "$1" || { echo "no source of lib/subagent-caps.sh"; return 1; }
    awk '
        { line[NR] = $0 }
        END {
            caps = "SUBAGENT_CAPS|subagent_caps"
            for (i = 1; i <= NR; i++) {
                if (line[i] ~ /^[[:space:]]*#/ || line[i] !~ /CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1/) continue
                if (line[i] ~ caps || line[i - 1] ~ caps || line[i + 1] ~ caps) continue
                print "line " i " sets the launch env without the caps"; bad = 1
            }
            exit bad
        }
    ' "$1"
}
SITES="scripts/handover/headed-arm.sh scripts/handover/arm-resume.sh scripts/handover/chief/chief.sh"
for s in $SITES; do
    why="$(site_check "$ROOT/$s")"; src=$?
    check "sites: $s sets the caps on every launch env line${why:+ ($why)}" "$src" "0"
done
lw="$(cat "$LAUNCHER")"
has "sites: worker-claude-launcher.sh sources the helper" "$lw" 'subagent-caps.sh'
hasrc="$(cat "$HEADED_ARM")"
has "sites: headed-arm.sh headless path writes the caps into the worker settings env" "$hasrc" '_hl_set "${_cap%%=*}" "${_cap#*=}"'
FX="$TMP/fixture-site.sh"
printf '#!/usr/bin/env bash\nenv -u CLAUDE_PID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude -n x "load doc"\n' > "$FX"
site_check "$FX" > /dev/null; check "sites: a fixture launch site without the helper FAILS the check" "$?" "1"
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/../lib/subagent-caps.sh"\nenv -u CLAUDE_PID CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 "${SUBAGENT_CAPS_ENV[@]}" claude -n x "load doc"\n' > "$FX"
site_check "$FX" > /dev/null; check "sites: the same fixture with the helper passes (control)" "$?" "0"

echo ""
echo "=== 6. no launch site outside the known list ==="
HINT_ONLY="scripts/context-fill.sh scripts/himmel-doctor.sh"
found="$(git -C "$ROOT" grep -l 'CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1' -- scripts ':!**/test-*' ':!**/*.test.*' ':!**/fixtures/**' 2>/dev/null)"
[ -n "$found" ] || bad "new: git grep found no launch env line at all (the scan itself is broken)"
for f in $found; do
    case " $SITES $HINT_ONLY " in
        *" $f "*) ok "new: $f is a known launch site or hint-only" ;;
        *) bad "new: $f sets the launch env but is not a known launch site; wire scripts/lib/subagent-caps.sh into it and add it to SITES" ;;
    esac
done

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
