#!/usr/bin/env bash
# test-tick-busedge.sh — tick.sh reports busedge=MISSING:<label>[,...] for a held
# fleet leg whose himmel-bus peer record is missing or names another console; the field is absent when
# every held leg has a record, when the bus has no peers dir, or for a free leg.
# Hermetic: stubs for every external probe, scratch HOME / handover / projects.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-busedge-test.XXXXXX")" || exit 1
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$W"' EXIT
fails=0
pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <want> <got>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/console-work/chain" "$W/peers"

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status) case "$2" in *-N810-*|*-N811-*|*-N812-*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
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
export TICK_BUS_PEERS_DIR="$W/peers"

mkleg() { # <id-slug>
    local f="$W/handover/HIMMEL-9$1.md"
    printf '# leg\n' > "$f"
    printf '%s' "$f"
}
field() { # <field> <tick output>
    printf '%s\n' "$2" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -n 1
}
run() { bash "$SUT" --legs "$1" 2>/dev/null; }
# peer <name> [<console>]: a bus peer record in the shape `bus register` writes; its
# console defaults to this tick's own (the console doc's stem).
peer() { printf '{"n":"%s","role":"leg","launched":"2026-10-19T00:00:00.000Z","console":"%s"}\n' "$1" "${2:-console}" > "$W/peers/$1.json"; }

held="$(mkleg 810-N810-held)"
held2="$(mkleg 811-N811-other)"
free="$(mkleg 801-N801-free)"

out="$(run "$held")"
check 'a held leg with no peer record reads busedge=MISSING:<label>' 'MISSING:N810' "$(field busedge "$out")"

out="$(run "$held,$held2")"
check 'several legs without a record share one MISSING: prefix' 'MISSING:N810,N811' "$(field busedge "$out")"

peer HIMMEL-9810-N810-held
check 'a held leg with a peer record has no busedge field' '' "$(field busedge "$(run "$held")")"

out="$(run "$held,$held2")"
check 'only the leg without a record is listed' 'MISSING:N811' "$(field busedge "$out")"

check 'a free leg is never busedge-missing' '' "$(field busedge "$(run "$free")")"

peer HIMMEL-9811-N811-other console-before
check 'a held leg whose record names another console (never adopted) is listed' 'MISSING:N811' "$(field busedge "$(run "$held,$held2")")"
peer HIMMEL-9811-N811-other console.x
check 'a console name is matched whole, never as a pattern' 'MISSING:N811' "$(field busedge "$(run "$held2")")"
peer HIMMEL-9811-N811-other
check 'once it adopts this console the leg drops out' '' "$(field busedge "$(run "$held,$held2")")"

rm -rf "$W/peers"
check 'no bus peers dir (bus not in use): busedge is absent' '' "$(field busedge "$(run "$held")")"

export TICK_BUS_WAKER_DIR="$W/wstate"
mkdir -p "$W/wstate"
check 'no waker state file: wakerstate is absent' '' "$(field wakerstate "$(run "$held")")"

printf 'rc4\n' > "$W/wstate/HIMMEL-9810-N810-held"
check 'a held leg whose waker ended rc4 reads wakerstate=<label>:rc4' 'N810:rc4' "$(field wakerstate "$(run "$held")")"

printf 'rc3\n' > "$W/wstate/HIMMEL-9811-N811-other"
check 'several legs list rc3 and rc4 side by side' 'N810:rc4,N811:rc3' "$(field wakerstate "$(run "$held,$held2")")"

printf 'rc3\n' > "$W/wstate/HIMMEL-9801-N801-free"
check 'a free leg is never wakerstate-flagged' '' "$(field wakerstate "$(run "$free")")"

printf 'junk\n' > "$W/wstate/HIMMEL-9810-N810-held"
check 'an unknown state value is not reported' '' "$(field wakerstate "$(run "$held")")"

dated="$(mkleg 812-N812-dated-2026-10-20)"
printf 'junk\n' > "$W/wstate/HIMMEL-9812-N812-dated-2026-10-20"
printf 'rc4\n' > "$W/wstate/HIMMEL-9812-N812-dated"
check 'an unknown state under the first name does not hide a later name rc4' 'N812:rc4' "$(field wakerstate "$(run "$dated")")"

rm -rf "$W/wstate"
check 'no waker state dir: wakerstate is absent' '' "$(field wakerstate "$(run "$held")")"

[ "$fails" -eq 0 ] && printf 'all passed\n' || { printf '%s failed\n' "$fails"; exit 1; }
