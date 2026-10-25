#!/usr/bin/env bash
# test-console-wait-pool.sh — The underfilled wake of console-wait.sh re-wakes
# when the dispatchable pool changes during one idle streak:
# a pool that grows from empty, or whose key set changes, wakes once per change
# on a bounded re-probe cadence; an unchanged pool, an emptied pool or a failed probe never wakes.
# Also pins that the wake block carries next-dispatchable.sh's output verbatim,
# drop summary included. tick.sh, the bank verdict and the dispatch command are
# stubbed (CHIEF_WAIT_TICK / CHIEF_WAIT_USAGE / CHIEF_WAIT_DISPATCH). bash 3.2-safe.
#
# CHIEF_WAIT (old name CONSOLE_WAIT) overrides the script under test (the RED
# control: the pre-change once-per-streak waiter fails the re-wake rows).
#
# Linux-only: console-wait.sh has no .ps1 twin by design; this suite uses GNU
# timeout and stat -c.
#
# Run: bash scripts/handover/console-kit/test-console-wait-pool.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-${CONSOLE_WAIT:-$HERE/console-wait.sh}}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/console-wait-pool-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$WORK"' EXIT

STUB="$WORK/stub"
mkdir -p "$STUB"
cat > "$STUB/tick.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/tick.line"
EOF
cat > "$STUB/bank.sh" <<'EOF'
#!/usr/bin/env bash
cat "$STUB/bank"
EOF
printf 'TICK 03:00 hb=1m legs=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=UNDERFILLED:7 gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$STUB/tick.line"
printf 'PROCEED\n' > "$STUB/bank"
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000
# the re-probe cadence is seconds here; the default is 30 minutes
export CHIEF_WAIT_UNDERFILL_REPOOL_SEC=1
# a re-probe is cut after a second here; the default is two minutes
export CHIEF_WAIT_REPOOL_TIMEOUT=1
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
export CHIEF_WAIT_PAGE_CMD="$STUB/off.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

# The pool stub: each priority-pool call is counted; pool.rows is the pool, absent means
# empty, pool.fail makes the call fail with no output.
cat > "$STUB/dispatch.sh" <<'EOF'
#!/usr/bin/env bash
case " $* " in
    *" --priority-pool-only "*)
        echo x >> "$STUB/calls"
        [ -f "$STUB/pool.fail" ] && exit 1
        [ -f "$STUB/pool.slow" ] && exec sleep 30
        [ -f "$STUB/pool.partial" ] && { printf 'LOCAL\tHIMMEL-9099\tMedium\tv1\tcut short\tfiles=z.sh\n'; exit 124; }
        if [ -f "$STUB/pool.rows" ]; then cat "$STUB/pool.rows"; printf '# pool=%s/7,LOW\n' "$(wc -l < "$STUB/pool.rows" | tr -d ' ')"
        else printf '# pool=0/7,LOW\nPOOL-EMPTY\n'; fi ;;
esac
EOF
export CHIEF_WAIT_DISPATCH="$STUB/dispatch.sh"
calls() { if [ -f "$STUB/calls" ]; then wc -l < "$STUB/calls" | tr -d ' '; else echo 0; fi; }
wakes() { grep -c '^WAKE underfilled' "$1" 2>/dev/null; }

new_inbox() { mkdir -p "$WORK/$1/consoles"; : > "$WORK/$1/consoles/c.md"; printf '%s' "$WORK/$1/consoles/c.md"; }
# arm <inbox> <outfile> <seconds>: one foreground arm that exits on a wake or after <seconds> (rc 124)
arm() { timeout "$3" bash "$WAIT" "$1" --legs "N1.md" > "$2" 2>/dev/null; rc=$?; }  # gnu-ok: Linux-only kit; pipefail-ok: none set

# --- (rp) the pool grows from empty during one streak ------------------------------------
I="$(new_inbox rp)"
arm "$I" "$WORK/rp1.out" 6
check "(rp) the streak's first sample wakes with the empty pool" "0" "$rc"
check "(rp) the first wake prints POOL-EMPTY" "1" "$(grep -c '^POOL-EMPTY' "$WORK/rp1.out")"

c0="$(calls)"
arm "$I" "$WORK/rp2.out" 4
check "(rp) an unchanged empty pool does not wake again (rc 124)" "124" "$rc"
check "(rp) and the pool was re-probed while waiting" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9002\tMedium\tv1\tsecond\tfiles=b.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp3.out" 6
check "(rp) a pool that grows from empty wakes (rc 0)" "0" "$rc"
check "(rp) the re-wake is an underfilled wake" "1" "$(wakes "$WORK/rp3.out")"
check "(rp) and it lists the new pool rows" "2" "$(grep -c '^LOCAL.HIMMEL-900[12]' "$WORK/rp3.out")"

arm "$I" "$WORK/rp4.out" 4
check "(rp) the same pool on the next arm is one wake per change (rc 124)" "124" "$rc"

printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\nLOCAL\tHIMMEL-9003\tMedium\tv1\tthird\tfiles=c.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp5.out" 6
check "(rp) a changed key set wakes (rc 0)" "0" "$rc"
check "(rp) the changed pool lists the new key" "1" "$(grep -c '^LOCAL.HIMMEL-9003' "$WORK/rp5.out")"

: > "$STUB/pool.fail"
c0="$(calls)"
arm "$I" "$WORK/rp6.out" 4
check "(rp) a failed probe never wakes (rc 124)" "124" "$rc"
check "(rp) and the failed probe did run" "yes" "$([ "$(calls)" -gt "$c0" ] && echo yes)"
rm -f "$STUB/pool.fail"
: > "$STUB/pool.partial"
arm "$I" "$WORK/rp6b.out" 4
check "(rp) a timed-out probe's partial rows never wake (rc 124)" "124" "$rc"
rm -f "$STUB/pool.partial"
: > "$STUB/pool.slow"
c0="$(calls)"
arm "$I" "$WORK/rp6c.out" 10
check "(rp) a stalled probe never wakes (rc 124)" "124" "$rc"
check "(rp) a stalled probe is cut at CHIEF_WAIT_REPOOL_TIMEOUT, so the next probe still starts" "yes" "$([ "$(( $(calls) - c0 ))" -ge 2 ] && echo yes)"
rm -f "$STUB/pool.slow"
arm "$I" "$WORK/rp7.out" 4
check "(rp) a failed probe leaves the saved pool alone: the same pool stays quiet (rc 124)" "124" "$rc"

rm -f "$STUB/pool.rows"
arm "$I" "$WORK/rp8.out" 4
check "(rp) a pool that empties does not wake (rc 124)" "124" "$rc"
printf 'LOCAL\tHIMMEL-9001\tMedium\tv1\tfirst\tfiles=a.sh\n' > "$STUB/pool.rows"
arm "$I" "$WORK/rp9.out" 6
check "(rp) and regrowing from that empty pool wakes again (rc 0)" "0" "$rc"

# --- (rp-cad) the re-probe cadence: a young marker is not probed, a due probe restarts the clock ----
I="$(new_inbox rpcad)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 arm "$I" "$WORK/rpcad1.out" 6
check "(rp-cad) the streak's first sample wakes at once (rc 0)" "0" "$rc"
printf 'LOCAL\tHIMMEL-9004\tMedium\tv1\tfourth\tfiles=d.sh\n' > "$STUB/pool.rows"
c0="$(calls)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=3600 arm "$I" "$WORK/rpcad2.out" 6
check "(rp-cad) a changed pool under a young marker does not wake (rc 124)" "124" "$rc"
check "(rp-cad) and the pool was not probed before the cadence is due" "0" "$(( $(calls) - c0 ))"
arm "$I" "$WORK/rpcad3.out" 6
check "(rp-cad) the same change wakes once the marker is due (rc 0)" "0" "$rc"

I="$(new_inbox rptouch)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=4 arm "$I" "$WORK/rptouch1.out" 6
c0="$(calls)"
CHIEF_WAIT_UNDERFILL_REPOOL_SEC=4 arm "$I" "$WORK/rptouch2.out" 9
n="$(( $(calls) - c0 ))"
check "(rp-cad) an unchanged pool never wakes (rc 124)" "124" "$rc"
check "(rp-cad) a due probe with no change restarts the clock: probed at least once" "yes" "$([ "$n" -ge 1 ] && echo yes)"
check "(rp-cad) and not on every tick of the next 9 s (at most 3 probes, got $n)" "yes" "$([ "$n" -le 3 ] && echo yes)"

# --- (rp-ok) capacity back to ok ends the streak: the next streak wakes at once --------------
sed 's/ capacity=[^ ]*/ capacity=ok/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
arm "$I" "$WORK/rpok1.out" 3
sed 's/ capacity=[^ ]*/ capacity=UNDERFILLED:7/' "$STUB/tick.line" > "$STUB/tick.line.tmp" && mv "$STUB/tick.line.tmp" "$STUB/tick.line"
arm "$I" "$WORK/rpok2.out" 6
check "(rp-ok) a new streak after capacity=ok wakes at once (rc 0)" "0" "$rc"

# --- (rp-real) the waiter's pool output is the hand run's, drop summary included -----------
M="$WORK/mirror/HIMMEL"; mkdir -p "$M"
mk() { # <key> <labels json> <title> <body>
    printf -- '---\nkey: "%s"\ntype: "Task"\nstatus: "To Do"\nstatusCategory: "x"\npriority: "Medium"\nlabels: %s\nfixVersions: ["v1.0.1"]\nparent: null\nlinks:\n  blocks: []\n  blocked_by: []\n  relates: []\n---\n\n# %s: %s\n\n## Description\n\n%s\n' \
        "$1" "$2" "$1" "$3" "$4" > "$M/$1.md"
}
mk HIMMEL-1 '["ps3-blocker"]' "pool head" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-2 '[]' "outside the pool" "Edit scripts/lib/beta.sh only."
printf 'v1.0.1\tfalse\t\n' > "$WORK/mirror/HIMMEL.versions.tsv"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/gh"
# shellcheck disable=SC2016  # the stub body is literal text, expanded when the stub runs
printf '#!/usr/bin/env bash\nfor k in "$@"; do printf "%%s\\tLOCAL-NATIVE\\tstub\\n" "$k"; done\n' > "$WORK/classify"
chmod +x "$WORK/gh" "$WORK/classify"
printf '{"schema":1,"legs":[]}\n' > "$WORK/fleet.json"
printf '# console\n\n## Live state\n\n- priority: \n' > "$WORK/console.md"
export NEXT_DISPATCH_MIRROR="$M" NEXT_DISPATCH_GH_CMD="$WORK/gh" NEXT_DISPATCH_CLASSIFY_CMD="$WORK/classify"
export TICKET_STATUS_STATE_DIR="$WORK/ts-none" HIMMEL_ADMISSIONS_LEDGER="$WORK/ledger-none.jsonl"
export CHIEF_WAIT_DISPATCH="$HERE/next-dispatchable.sh"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/console.md" --legs-from "$WORK/fleet.json" </dev/null 2>/dev/null)"
I="$(new_inbox rpreal)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/console.md" --legs-from "$WORK/fleet.json" > "$WORK/rpreal.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rp-real) the real dispatcher's pool wakes the waiter (rc 0)" "0" "$rc"
check "(rp-real) the pool in the wake block equals a hand run with the same flags" "$hand" "$(sed '1,2d;/^# version backlog/,$d' "$WORK/rpreal.out")"
check "(rp-real) the hand run lists the pool head" "1" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-1	')"
check "(rp-real) the wake block carries the drop summary" "1" "$(grep -c '^# dropped from v1.0.1: 1 of 2 To Do (tier 1)' "$WORK/rpreal.out")"

# --- (rp-legs) a live leg's ticket stays out of the pool: --legs-from reaches the dispatcher ---
mk HIMMEL-3 '["ps3-blocker"]' "second pool head" "Edit scripts/lib/gamma.sh only."
printf '# leg\n' > "$WORK/HIMMEL-1-held-leg.md"
printf '{"schema":1,"legs":[{"label":"held","doc":"%s"}]}\n' "$WORK/HIMMEL-1-held-leg.md" > "$WORK/fleet-held.json"
hand="$(bash "$HERE/next-dispatchable.sh" --priority-pool-only --top 7 --doc "$WORK/console.md" --legs-from "$WORK/fleet-held.json" </dev/null 2>/dev/null)"
I="$(new_inbox rplegs)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/console.md" --legs-from "$WORK/fleet-held.json" > "$WORK/rplegs.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(rp-legs) the hand run keeps the held leg's ticket out of the pool" "0" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-1	')"
check "(rp-legs) and lists the other pool head" "1" "$(printf '%s\n' "$hand" | grep -c 'HIMMEL-3	')"
check "(rp-legs) the pool in the wake block equals that hand run" "$hand" "$(sed '1,2d;/^# version backlog/,$d' "$WORK/rplegs.out")"

# --- (lp) a LOW pool (2 of 7) still lists the plain current-version rows under their own heading ----
M="$WORK/mirror-lp/HIMMEL"; mkdir -p "$M"
mk HIMMEL-1 '["ps3-blocker"]' "pool head one" "Edit scripts/lib/alpha.sh only."
mk HIMMEL-3 '["ps3-blocker"]' "pool head two" "Edit scripts/lib/gamma.sh only."
for n in 10 11 12 13 14; do mk "HIMMEL-$n" '[]' "plain task $n" "Edit scripts/lib/plain$n.sh only."; done
printf 'v1.0.1\tfalse\t\n' > "$WORK/mirror-lp/HIMMEL.versions.tsv"
export NEXT_DISPATCH_MIRROR="$M"
I="$(new_inbox lp)"
timeout 20 bash "$WAIT" "$I" --doc "$WORK/console.md" --legs-from "$WORK/fleet.json" > "$WORK/lp.out" 2>/dev/null; rc=$?  # gnu-ok: Linux-only kit; pipefail-ok: none set
check "(lp) the LOW pool wakes the waiter (rc 0)" "0" "$rc"
check "(lp) the pool rows are listed" "2" "$(grep -c '^LOCAL.HIMMEL-[13]	' "$WORK/lp.out")"
check "(lp) every plain current-version To Do row is listed" "5" "$(grep -c '^LOCAL.HIMMEL-1[0-4]	' "$WORK/lp.out")"
check "(lp) a pool row is not listed twice" "1" "$(grep -c '^LOCAL.HIMMEL-1	' "$WORK/lp.out")"
check "(lp) the plain rows sit under their own heading" "1" "$(grep -c '^# version backlog' "$WORK/lp.out")"
check "(lp) the wake line carries the one count of dispatchable rows" "WAKE underfilled capacity=UNDERFILLED:7 dispatchable=7" "$(head -n1 "$WORK/lp.out")"

printf '\n%d failure(s)\n' "$fails"
[ "$fails" -eq 0 ]
