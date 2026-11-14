#!/usr/bin/env bash
# test-tick-rmqueue.sh — tick.sh rm-queue=<n>,<oldest age>m and the automatic `jira release rm-run`:
# an open placement request older than TICK_RMRUN_MIN minutes (default 30) makes the tick launch ONE
# detached rm-run for the chief doc's `release:` release, never while the lease is held and never
# twice inside TICK_RMRUN_MIN_SECS. The state read and the rm-run are stubbed; nothing touches Jira.
#
# PLATFORM GUARD: The chief kit is Linux-only.
# shellcheck disable=SC2015,SC2016  # `[ cond ] && pass || fail`: pass() cannot fail; single-quoted stub bodies expand at run time
set -uo pipefail

if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - tick.sh is Linux-only by design (tick.sh:11-12); ABC-7641"
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

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/home" "$W/projects/p" "$W/chief-work/chain"

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
export TICK_LAUNCH_DIR="$W/chief-work" TICK_PROJECTS_DIR="$W/projects"
export TOKEN=t WORKERS=''
export HIMMEL_RELEASE_STATE_DIR="$W/releases" USER_SLUG=tester
mkdir -p "$HIMMEL_RELEASE_STATE_DIR"

# the state read: `release state <R> --json`, its body is $W/state.json; the rm-run logs its argv and stops.
printf '#!/bin/sh\necho "$@" >> "%s/state-asked"\ncat "%s/state.json"\nexit "${TICK_RMQ_EXIT:-0}"\n' "$W" "$W" > "$W/rmq-probe.sh"
printf '#!/bin/sh\necho "$@" >> "%s/rmrun-ran"\n' "$W" > "$W/rmrun-probe.sh"
export TICK_RMQ_PROBE="$W/rmq-probe.sh" TICK_RMRUN_PROBE="$W/rmrun-probe.sh" TICK_RMRUN_LAUNCHER=env

ago() { /bin/date -u -d "$1 minutes ago" +%Y-%m-%dT%H:%M:%SZ; }
# state <open ids as a JSON list> <oldest open ts|null> <lease JSON>
state() { printf '{"status":"OK","versions":["v1.1.3","v1.1.4"],"lease":%s,"requests":{"open":%s,"claimed":[],"oldest_open":%s}}\n' "$3" "$1" "$2" > "$W/state.json"; }
mkdoc() { printf '# chief\nrelease: %s\n' "$1" > "$W/handover/chief.md"; }
reset() { rm -f "$W/rmrun-ran" "$W/state-asked"; rm -rf "$W/state"; }
tick() { bash "$SUT" --doc "$W/handover/chief.md" 2>/dev/null; }
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
check 'and the tick launches ONE rm-run for the chief doc release' '1' "$(ran)"
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

reset; state '["Q-1"]' "\"$(ago 45)\"" '{"epoch":3,"owner_doc":null,"released":true}'
out="$(tick)"
sleep 1
check 'a released lease is free: the tick launches the rm-run' '1' "$(ran)"

reset; state '[]' null null
out="$(tick)"
sleep 1
check 'an empty queue shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

printf '# chief\n' > "$W/handover/chief.md"
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(tick)"
sleep 1
check 'a chief doc with no release: line shows no rm-queue field' '' "$(field rm-queue "$out")"
check 'and asks no state and runs no rm-run' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"

# A real declaration with no usable chief line is broken wiring, not an empty queue.
mkdir -p "$HIMMEL_RELEASE_STATE_DIR/R1"
printf '{}\n' > "$HIMMEL_RELEASE_STATE_DIR/R1/release.json"
reset
out="$(tick)"
check 'declared release without a line reports off' 'off' "$(field rm-queue "$out")"
check 'off never reads state or launches a run' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"
mkdoc 'bad/name'
out="$(tick)"
check 'declared release with an invalid line reports off' 'off' "$(field rm-queue "$out")"
mkdoc none
rc=0; out="$(tick)" || rc=$?
check 'explicit none tick succeeds' 0 "$rc"
check 'explicit none still elides the field despite a declaration' '' "$(field rm-queue "$out")"
mkdoc none-test
reset; state '["Q-none"]' "\"$(ago 45)\"" null
rc=0; out="$(tick)" || rc=$?
check 'none-prefixed release tick succeeds' 0 "$rc"
check 'a valid none-prefixed release wakes normally' '1,45m,run' "$(field rm-queue "$out")"
check 'none-prefixed release is probed verbatim' 'none-test --json' "$(sed -n 1p "$W/state-asked" 2>/dev/null)"
mkdoc R1
printf 'broken\n' > "$W/state.json"
out="$(tick)"
check 'an unreadable state reports off instead of silently disabling the RM' 'off' "$(field rm-queue "$out")"
for status in UNKNOWN STALE; do
    reset
    printf '{"status":"%s","requests":{"open":[],"claimed":[]}}\n' "$status" > "$W/state.json"
    out="$(TICK_RMQ_EXIT=3 tick)"
    check "$status state is off even with an empty request list" off "$(field rm-queue "$out")"
    check "$status never launches an RM" '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
done
reset
printf '{"status":"OK","requests":{"open":[],"claimed":["Q-held"]}}\n' > "$W/state.json"
out="$(tick)"
sleep 1
check 'claimed-only requests remain visible' '0,0m,claimed=1' "$(field rm-queue "$out")"
check 'claimed-only requests never re-bill the held request' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"
reset
printf '{"status":"OK","requests":{"open":["Q-new"],"claimed":["Q-held"],"oldest_open":"%s"}}\n' "$(ago 45)" > "$W/state.json"
out="$(tick)"
check 'open requests still wake while claimed work is visible' '1,45m,claimed=1,run' "$(field rm-queue "$out")"
check 'mixed queue launches just one run' 1 "$(ran)"

# No override: the declaration belongs to the primary checkout, not the chief bucket.
unset HIMMEL_RELEASE_STATE_DIR
checkout="$(git rev-parse --path-format=absolute --git-common-dir)"
checkout="${checkout%/.git}"
mkdir -p "$HANDOVER_DIR/$USER_SLUG/${checkout##*/}/release/Rcanonical"
printf '{}\n' > "$HANDOVER_DIR/$USER_SLUG/${checkout##*/}/release/Rcanonical/release.json"
printf '# chief\n' > "$W/handover/chief.md"
reset
out="$(tick)"
check 'canonical declaration with override unset reports missing wiring' off "$(field rm-queue "$out")"
check 'canonical missing wiring never probes or runs' '' "$([ -e "$W/rmrun-ran" ] || [ -e "$W/state-asked" ] && echo ran)"
printf '> The project this console is FOR is **`%s`**.\n' "$W/projects/p" >> "$W/handover/chief.md"
out="$(tick)"
check 'foreign project never inherits the primary declaration warning' '' "$(field rm-queue "$out")"
rm -f "$W/handover/chief.md"
rc=0; out="$(tick)" || rc=$?
check 'missing chief doc tick succeeds' 0 "$rc"
check 'a missing chief doc still elides the field' '' "$(field rm-queue "$out")"

# Inline handovers belong to the script's primary checkout, not the observed --repo.
inline="$W/anchor"
mkdir -p "$inline/scripts/handover/chief-kit" "$inline/scripts/lanes" "$inline/handovers/tester/anchor/release/Rinline"
cp "$SUT" "$inline/scripts/handover/chief-kit/tick.sh"
cp -R "$HERE/../../lib" "$inline/scripts/lib"
cp -R "$HERE/../../lanes/lib" "$inline/scripts/lanes/lib"
git init -q "$inline"
printf '{}\n' > "$inline/handovers/tester/anchor/release/Rinline/release.json"
printf '# chief\n' > "$W/handover/chief.md"
reset
rc=0
out="$(unset HANDOVER_DIR HIMMEL_REPO; cd "$inline" && bash scripts/handover/chief-kit/tick.sh --repo "$W/repo" --doc "$W/handover/chief.md" 2>/dev/null)" || rc=$?
check 'inline primary-root tick succeeds with another observed repo' 0 "$rc"
check 'inline declaration reports off from the primary checkout' off "$(field rm-queue "$out")"

mkdoc R1
reset; state '["Q-1"]' "\"$(ago 45)\"" null
out="$(TICK_RMRUN_MIN=60 tick)"
sleep 1
check 'TICK_RMRUN_MIN=60 moves the threshold past a 45 min request' '' "$([ -e "$W/rmrun-ran" ] && echo ran)"

# ABC-9853: the refused asks of the same state read. The golden is the engine's own state() output
# (engine.test.ts writes it), so the tick reads what the producer prints.
GOLDEN="$HERE/fixtures/state-golden.json"
mkdoc R1
reset; cp "$GOLDEN" "$W/state.json"
out="$(tick)"
check 'rm-refused= counts every refused ask and lists the operator-asked one' '3:ABC-2@R-R1-0001' "$(field rm-refused "$out")"
check 'the tsv holds one row per refused ask: key, ruling, reason, asks_operator' \
    "$(printf 'ABC-2\tR-R1-0001\tname the operator'"'"'s words for ABC-2\t1\nABC-3\tR-R1-0002\tname the operator'"'"'s words for ABC-3\t0\nABC-4\tR-R1-0003\tname the operator'"'"'s words for ABC-4\t0')" \
    "$(cat "$W/state/rm-refused-chief.tsv" 2>/dev/null)"
check 'release-state-<stem>.json carries status OK and the golden words_records and asks_operator_keys' 'OK|1|O-R1-0003|ABC-2' \
    "$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print("%s|%d|%s|%s" % (d["status"], len(d["words_records"]), d["words_records"][0]["id"], ",".join(d["asks_operator_keys"])) + ("" if d.get("ts") else "|no-ts"))' "$W/state/release-state-chief.json" 2>/dev/null)"

# the tick's real tsv feeds chief-wait: the operator-asked pair wakes once, the other two arrive as the digest
mkdir -p "$W/cw/consoles"
: > "$W/cw/consoles/c.md"
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none rm-refused=%s\n' \
    "$(field rm-refused "$out")" > "$W/cw.line"
printf '#!/usr/bin/env bash\ncat "%s/cw.line"\n' "$W" > "$W/cw-tick.sh"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$W/cw-bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$W/cw-off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$W/cw-budget.sh"
cw_out="$(CHIEF_WAIT_TICK="$W/cw-tick.sh" CHIEF_WAIT_USAGE="$W/cw-bank.sh" CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 \
    CHIEF_WAIT_PAGE_CMD="$W/cw-off.sh" CHIEF_WAIT_BUDGET="$W/cw-budget.sh" CHIEF_WAIT_ORPHAN="$W/cw-off.sh" CHIEF_WAIT_DISPATCH="$W/cw-off.sh" \
    WAIT_SWEEP_CMD="$W/cw-off.sh" WAIT_FOCUS_CMD="$W/cw-off.sh" HIMMEL_DENIAL_ACK_DIR="$W/acks" \
    timeout 20 bash "$HERE/chief-wait.sh" "$W/cw/consoles/c.md" --doc "$W/handover/chief.md" --workers N1.md 2>/dev/null)"  # gnu-ok: Linux-only kit
check "the tick's real tsv feeds chief-wait: one operator wake naming key, ruling and fix, then the digest" \
    "WAKE rm-refused ABC-2@R-R1-0001 — fix: name the operator's words for ABC-2|WAKE rm-refused-digest 2 new: ABC-3@R-R1-0002,ABC-4@R-R1-0003" \
    "$(printf '%s\n' "$cw_out" | grep '^WAKE ' | paste -sd'|' -)"

state '[]' null null
out="$(tick)"
check 'no refused ask shows no rm-refused field' '' "$(field rm-refused "$out")"
check 'and leaves an empty tsv' '' "$(cat "$W/state/rm-refused-chief.tsv" 2>/dev/null)"
cp "$GOLDEN" "$W/state.json"
tick > /dev/null
printf '{"status":"UNKNOWN","requests":{"open":[],"claimed":[]},"refused_asks":[{"key":"ABC-2","ruling":"R-R1-0001","req":"Q-R1-0001","reason":"x","asks_operator":true}]}\n' > "$W/state.json"
out="$(TICK_RMQ_EXIT=3 tick)"
check 'a state that is not OK shows no rm-refused field' '' "$(field rm-refused "$out")"
check 'and deletes release-state-<stem>.json and the tsv' 'gone' "$([ -e "$W/state/release-state-chief.json" ] || [ -e "$W/state/rm-refused-chief.tsv" ] || echo gone)"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
