#!/usr/bin/env bash
# test-tick-holds.sh — tick.sh holds=: a leg whose newest Results marker is BLOCKED (or a
# FINDING that awaits a console ruling) and whose doc has sat untouched for TICK_HOLD_MIN
# minutes (default 20) reads `<leg>:<age>m`; the field is absent when no leg holds.
# Hermetic: stubs for every external probe, scratch HOME / handover / projects.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

# Platform guard: tick.sh is Linux-only (tick.sh:11-12) and this suite ages docs with GNU `touch -d` / `date -d`.
if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - tick.sh is Linux-only by design (tick.sh:11-12); HIMMEL-7117"
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-holds-test.XXXXXX")" || exit 1
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
export DOC="$W/handover/console.md" TOKEN=t LEGS=''

# mkleg <id-slug> <minutes-old> [bullet...]: a leg doc last written that many minutes ago.
mkleg() {
    local f="$W/handover/HIMMEL-9$1.md" age="$2"; shift 2
    printf '# leg\n' > "$f"
    local b
    for b in "$@"; do printf '%s\n' "$b" >> "$f"; done
    touch -d "$age minutes ago" "$f"
    printf '%s' "$f"
}
# manifest <doc>...: a fleet manifest of those legs, added 60 minutes ago.
manifest() {
    local m="$W/handover/console.fleet.json" legs="" d t
    t="$(/bin/date -u -d "60 minutes ago" +%Y-%m-%dT%H:%M:%SZ)"
    for d in "$@"; do legs="$legs${legs:+,}{\"doc\":\"$d\",\"label\":\"x\",\"added\":\"$t\"}"; done
    printf '{"schema":1,"legs":[%s]}\n' "$legs" > "$m"
    printf '%s' "$m"
}
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
run_from() { bash "$SUT" --legs-from "$1" 2>/dev/null; }

old="$(mkleg 921-N921-old 35 '- 10:00 LIVE — x' '- 10:10 BLOCKED — need a ruling')"
young="$(mkleg 922-N922-young 5 '- 10:00 BLOCKED — need a ruling')"
live="$(mkleg 923-N923-live 90 '- 10:00 BLOCKED — q' '- 10:40 RESOLVED — ruling received' '- 10:41 LIVE — working')"
find_wait="$(mkleg 924-N924-findwait 30 '- 10:00 FINDING — awaiting the console ruling on the base')"
find_info="$(mkleg 925-N925-findinfo 30 '- 10:00 FINDING — the suite has a stale row, noted')"
find_ci="$(mkleg 927-N927-findci 30 '- 10:00 FINDING — waiting for CI, holding the push, no ruling owed')"
wrapped="$(mkleg 926-N926-wrapped 90 '- 10:00 BLOCKED — q' '- 10:50 WRAPPED — done')"

out="$(run_from "$(manifest "$old" "$young" "$live" "$find_wait" "$find_info" "$find_ci" "$wrapped")")"
check 'a BLOCKED leg past 20 min and an awaiting FINDING read holds=' 'N921:35m,N924:30m' "$(field holds "$out")"

m="$(manifest "$young" "$live" "$find_info" "$find_ci" "$wrapped")"
out="$(run_from "$m")"
run_from "$m" > /dev/null; rc=$?
check 'tick ran clean for the no-holds fleet' '0' "$rc"
check 'under the threshold, later LIVE, informational FINDINGs (incl. waiting-on-CI), WRAPPED: no holds= field' '' "$(field holds "$out")"

out="$(TICK_HOLD_MIN=3 run_from "$(manifest "$young")")"
check 'TICK_HOLD_MIN=3 moves the threshold (5 min reads as a hold)' 'N922:5m' "$(field holds "$out")"
out="$(TICK_HOLD_MIN=bad run_from "$(manifest "$young" "$old")")"
check 'a non-numeric TICK_HOLD_MIN falls back to 20' 'N921:35m' "$(field holds "$out")"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
