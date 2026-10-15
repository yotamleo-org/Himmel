#!/usr/bin/env bash
# test-arm-resume-bus-rebind.sh —: arm-resume.sh wraps the resumed
# claude so the new pid is rebound to its name on the himmel-bus.
#
# A resumed session gets a NEW claude pid and stays unbound on the bus (bus
# send refused). The emitted at/crontab launch now backgrounds
# arm-resume-bus-rebind.sh next to claude, ONLY when the name already has a bus
# peer file. Stubs only: no real at/crontab job, no real claude, no real bus.
#
#   A. the helper: one rebind with the child pid; no child -> WARN; a refused
#      rebind -> WARN; a hung rebind is killed inside the bound; a decoy argv
#      (prefix name, prompt text) is never rebound.
#   B. emission: at + crontab carry the helper for a registered name and are
#      byte-identical otherwise; the WSL branch is untouched either way.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ARM="$HERE/arm-resume.sh"
HELPER="$HERE/arm-resume-bus-rebind.sh"
FAILED=0

TMP=$(mktemp -d "${TMPDIR:-/tmp}/armrr.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT

ok()   { echo "PASS $1"; }
fail() { echo "FAIL $1${2:+ — $2}"; FAILED=$((FAILED + 1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1" "expected [$2], got [$3]"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) fail "$1" "missing: $2" ;; esac; }
hasnt() { case "$3" in *"$2"*) fail "$1" "unexpected: $2" ;; *) ok "$1" ;; esac; }

# ---- A. helper -------------------------------------------------------------
PROCD="$TMP/proc"
mkproc() { # mkproc <pid> <comm> <argv...>
    local pid="$1" comm="$2"; shift 2
    mkdir -p "$PROCD/$pid"
    printf '%s' "$comm" > "$PROCD/$pid/comm"
    : > "$PROCD/$pid/cmdline"
    local a; for a in "$@"; do printf '%s\0' "$a" >> "$PROCD/$pid/cmdline"; done
    # stat: "<pid> (<comm>) S" + fields 4..21 (zeros) + field 22 start time;
    # PSTART defaults far after this helper's own start, 1 = long before it
    printf '%s (%s) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s\n' "$pid" "$comm" "${PSTART:-99999999999}" > "$PROCD/$pid/stat"
}
mkbus() { # mkbus <mode: ok|refuse|hang>
    cat > "$TMP/bus" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/bus-calls"
case "$1" in
    refuse) echo "bound pid is still live: \$2" >&2; exit 1 ;;
    hang) exec sleep 30 ;;
esac
exit 0
EOF
    chmod +x "$TMP/bus"
}
late() { # late <pid> <comm> <argv...>: the child appears 1s AFTER the helper starts
    ( sleep 1; mkproc "$@" ) &
}
run_helper() { # run_helper <name> <wait> <secs>
    : > "$TMP/bus-calls"; : > "$TMP/log"
    local hrc
    ARM_RESUME_PROC="$PROCD" bash "$HELPER" "$1" "$TMP/bus" "$TMP/log" "$2" "$3"
    hrc=$?
    wait
    return "$hrc"
}

mkdir -p "$PROCD"
late 4242 claude claude -n HIM-1 "load doc"
mkbus ok
run_helper HIM-1 3 5; rc=$?
eq "A1 helper exits 0" 0 "$rc"
eq "A1 exactly one rebind with the child pid" "rebind HIM-1 4242" "$(cat "$TMP/bus-calls")"

rm -rf "$PROCD"; mkproc 77 claude claude -n HIM-1-x "p"; mkproc 78 claude claude "load -n HIM-1 now"; mkproc 79 node node -n HIM-1
run_helper HIM-1 1 5; rc=$?
eq "A2 decoy argv (prefix name, prompt text, non-claude comm) is never rebound" "" "$(cat "$TMP/bus-calls")"
eq "A2 no child: exits 0 (fail-open)" 0 "$rc"
has "A2 no child: WARN in the arm log" "WARN" "$(cat "$TMP/log")"

rm -rf "$PROCD"; mkdir -p "$PROCD"
late 4242 claude claude -n HIM-1 "p"
mkbus refuse
run_helper HIM-1 3 5; rc=$?
eq "A3 refused rebind: one call" "rebind HIM-1 4242" "$(cat "$TMP/bus-calls")"
eq "A3 refused rebind: exits 0" 0 "$rc"
has "A3 refused rebind: WARN carries the bus message" "bound pid is still live" "$(cat "$TMP/log")"

# A5: a matching claude that started BEFORE the helper is the OLD session;
# only the one that started after it is rebound. Both are already present when
# the helper first scans, so the check cannot depend on scan-vs-launch order.
rm -rf "$PROCD"; PSTART=1 mkproc 4242 claude claude -n HIM-1 "old"
mkproc 5555 claude claude -n HIM-1 "new"
mkbus ok
run_helper HIM-1 5 5
eq "A5 older match skipped, newer child rebound" "rebind HIM-1 5555" "$(cat "$TMP/bus-calls")"

rm -rf "$PROCD"; mkdir -p "$PROCD"
late 4242 claude claude -n HIM-1 "p"
mkbus hang
t0=$(date +%s)
run_helper HIM-1 3 2; rc=$?
t1=$(date +%s)
eq "A4 hung rebind: exits 0" 0 "$rc"
if [ $((t1 - t0)) -le 10 ]; then ok "A4 hung rebind killed inside the bound ($((t1 - t0))s)"; else fail "A4 hung rebind not bounded" "$((t1 - t0))s"; fi
has "A4 hung rebind: timeout WARN" "timed out" "$(cat "$TMP/log")"

# ---- B. emission -----------------------------------------------------------
BIN="$TMP/bin"; mkdir -p "$BIN"
for t in at atq crontab claude; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$t"; chmod +x "$BIN/$t"; done
HOD="$TMP/ho"; mkdir -p "$HOD"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n# T\n' "$HERE" > "$HOD/bn.md"
XDG="$TMP/xdg"; mkdir -p "$XDG/himmel/bus/peers"
FUT=$(date -d '+10 min' +%H:%M 2>/dev/null || date -v+10M +%H:%M)
arm() { # arm <env...> -- run a dry-run arm, stdout+stderr
    env ARM_RESUME_UNAME="${ARM_RESUME_UNAME:-Linux}" PATH="$BIN:$PATH" HANDOVER_DIR="$HOD" XDG_STATE_HOME="$XDG" SKILL_TELEMETRY_DISABLE=1 \
        ARM_COLLISION_CANDIDATES="" HIMMEL_HEADROOM_PROXY=0 ARM_BRIDGE_LIVE=0 \
        ARM_RESUME_LOG_DIR="$TMP/arm-logs" ARM_RUNNER_DIR="$TMP/arm-runners" "$@" \
        bash "$ARM" --time "$FUT" --handover "$HOD/bn.md" --force --dry-run 2>&1
}
filter() { grep -v 'arm-resume-bus-rebind' | grep -v 'would at -t'; }

rm -f "$XDG/himmel/bus/peers/bn.json"
at_unreg=$(arm OSTYPE=linux-gnu)
cron_unreg=$(arm OSTYPE=darwin23 ARM_TERMINAL_APP=none)
echo '{"role":"leg"}' > "$XDG/himmel/bus/peers/bn.json"
at_reg=$(arm OSTYPE=linux-gnu)
cron_reg=$(arm OSTYPE=darwin23 ARM_TERMINAL_APP=none)

has "B1 at: registered name backgrounds the rebind helper" "arm-resume-bus-rebind.sh" "$at_reg"
hasnt "B2 at: unregistered name carries no helper" "arm-resume-bus-rebind" "$at_unreg"
eq "B3 at: registered output is the unregistered output plus the helper line only" \
    "$(printf '%s\n' "$at_unreg" | filter)" "$(printf '%s\n' "$at_reg" | filter)"
has "B4 crontab: registered name carries the helper" "arm-resume-bus-rebind.sh" "$cron_reg"
hasnt "B5 crontab: unregistered name carries no helper" "arm-resume-bus-rebind" "$cron_unreg"
eq "B6 crontab: registered output is the unregistered output plus the helper line only" \
    "$(printf '%s\n' "$cron_unreg" | filter)" "$(printf '%s\n' "$cron_reg" | filter)"
cron_mac=$(arm OSTYPE=darwin23 ARM_TERMINAL_APP=none ARM_RESUME_UNAME=Darwin)
hasnt "B8 crontab on macOS: registered name carries no helper (it reads /proc)" "arm-resume-bus-rebind" "$cron_mac"

# WSL branch (Windows host, in-distro relaunch) is out of scope: untouched.
WB="$TMP/winbin"; mkdir -p "$WB"
for t in claude schtasks wsl.exe reg; do printf '#!/usr/bin/env bash\nexit 0\n' > "$WB/$t"; chmod +x "$WB/$t"; done
# shellcheck disable=SC2016 # the stub body is literal script text
printf '#!/usr/bin/env bash\nfor a in "$@"; do case "$a" in -*) ;; *) printf "%%s\\n" "$a" ;; esac; done\n' > "$WB/cygpath"; chmod +x "$WB/cygpath"
wsl_reg=$(env PATH="$WB:$PATH" SCHTASKS_CMD="$WB/schtasks" OSTYPE=msys HANDOVER_DIR="$HOD" XDG_STATE_HOME="$XDG" \
    SKILL_TELEMETRY_DISABLE=1 ARM_COLLISION_CANDIDATES="" HIMMEL_HEADROOM_PROXY=0 ARM_BRIDGE_LIVE=0 \
    bash "$ARM" --time "$FUT" --handover "$HOD/bn.md" --cwd /home/u/r --wsl-distro ubuntu --force --dry-run 2>&1)
has "B7 WSL: still emits its own in-distro launch" "wsl.exe -d ubuntu -e bash -lc" "$wsl_reg"
hasnt "B7 WSL: registered name adds no rebind helper" "arm-resume-bus-rebind" "$wsl_reg"

echo "---"
if [ "$FAILED" -eq 0 ]; then echo "test-arm-resume-bus-rebind: all passed"; exit 0; fi
echo "test-arm-resume-bus-rebind: $FAILED failed"; exit 1
