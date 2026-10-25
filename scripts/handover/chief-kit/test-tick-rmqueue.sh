#!/usr/bin/env bash
# test-tick-rmqueue.sh — tick.sh rm-queue=<n>,<oldest age>m and the automatic `jira release rm-run`:
# an open placement request older than TICK_RMRUN_MIN minutes (default 30) makes the tick launch ONE
# detached rm-run for the console doc's `release:` release, never while the lease is held and never
# twice inside TICK_RMRUN_MIN_SECS. The state read and the rm-run are stubbed; nothing touches Jira.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - tick.sh is Linux-only by design (tick.sh:11-12); HIMMEL-7641"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-rmqueue-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/console-work/chain"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) printf '%s\n' free; exit 0 ;;
esac
exit 2
STUB
printf '#!/usr/bin/env bash\nprintf "%%s\\n" 28\n' > "$W/repo/scripts/context-fill.sh"
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/pgrep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/bin/atq"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/gh"
printf '#!/usr/bin/env bash\ncat "$PS_FIXTURE"\n' > "$W/bin/ps"
printf '#!/usr/bin/env bash\nexit 1\n' > "$W/bin/bun"
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"
cat > "$W/repo/scripts/lib/usage-preflight.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' >&2
printf '%s\n' PROCEED
STUB
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/usage-preflight.sh" "$W/bin/"*
printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"

export PATH="$W/bin:$PATH"
export HOME="$W/home"
export HANDOVER_DIR="$W/handover" REPO="$W/repo" TICK_TMPDIR="$W" PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json" TICK_STATE_DIR="$W/state" CLAUDE_SESSIONS_PROC="$W/proc"
export TICK_LAUNCH_DIR="$W/console-work" TICK_PROJECTS_DIR="$W/projects"
export TOKEN=t LEGS=''

# the state read: `release state <R> --json`, its body is $W/state.json; the rm-run logs its argv and stops.
printf '#!/bin/sh\necho "$@" >> "%s/state-asked"\ncat "%s/state.json"\n' "$W" "$W" > "$W/rmq-probe.sh"
printf '#!/bin/sh\necho "$@" >> "%s/rmrun-ran"\n' "$W" > "$W/rmrun-probe.sh"
export TICK_RMQ_PROBE="$W/rmq-probe.sh" TICK_RMRUN_PROBE="$W/rmrun-probe.sh" TICK_RMRUN_LAUNCHER=env

ago() { /bin/date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
# state <open ids as a JSON list> <oldest open ts|null> <lease JSON>
state() { printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":%s,"requests":{"open":%s,"claimed":[],"oldest_open":%s}}\n' "$3" "$1" "$2" > "$W/state.json"; }
mkdoc() { printf '# console\nrelease: %s\n' "$1" > "$W/handover/console.md"; }
reset() { rm -f "$W/rmrun-ran" "$W/state-asked"; rm -rf "$W/state"; }
tick() { bash "$SUT" --doc "$W/handover/console.md" 2>/dev/null; }
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
ran() { # wait up to 5 s for the detached stub to log, then print how many lines it logged
    local i=0
    while [ ! -s "$W/rmrun-ran" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    [ -s "$W/rmrun-ran" ] && wc -l < "$W/rmrun-ran" | tr -d ' ' || echo 0
}

mkdoc R1
reset; state '["Q-1","Q-2"]' "\"$(ago 45)\"" null
out="$(tick)"
check 'two open requests, the oldest 45 min old, read rm-queue=2,45m' '2,45m,run' "$(field rm-queue "$out")"
check 'and the tick launches ONE rm-run for the console doc release' '1' "$(ran)"
check 'the rm-run is called with the release name' 'release rm-run R1' "$(sed -n 1p "$W/rmrun-ran" | sed 's/^.*\(release rm-run R1\).*$/\1/')"
check 'the state read is asked for the same release' 'R1 --json' "$(sed -n 1p "$W/state-asked")"

rm -f "$W/rmrun-ran" "$W/state-asked"
out="$(tick)"
sleep 1
check 'a second tick inside the minimum interval shows the queue but launches no second rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
check 'and still reads the queue' '2,45m' "$(field rm-queue "$out")"

reset; state '["Q-1"]' "\"$(ago 10)\"" null
out="$(tick)"
sleep 1
check 'a request younger than the threshold shows rm-queue and runs nothing' '1,10m' "$(field rm-queue "$out")"
check 'and no rm-run ran' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

reset; state '["Q-1"]' "\"$(ago 45)\"" '{"holder":"rm-run-1","epoch":3}'
out="$(tick)"
sleep 1
check 'a held lease still shows the queue' '1,45m' "$(field rm-queue "$out")"
check 'and no rm-run is launched while the lease is held' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

reset; state '[]' null null
out="$(tick)"
sleep 1
check 'an empty queue shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

printf '# console\n' > "$W/handover/console.md"
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(tick)"
sleep 1
check 'a console doc with no release: line shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and asks no state and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"

mkdoc R1
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(TICK_RMRUN_MIN=60 tick)"
sleep 1
check 'TICK_RMRUN_MIN=60 moves the threshold past a 45 min request' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
