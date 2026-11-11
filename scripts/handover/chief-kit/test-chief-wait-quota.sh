#!/usr/bin/env bash
# shellcheck disable=SC2016  # the single-quoted bodies are scripts written to files, expanded when they run
# test-chief-wait-quota.sh — the waiter across a GitHub quota outage: a gate refused at quota
# out leaves a marker, and the waiter wakes the chief once when quota is back; a READY whose
# checks cannot read stays unspent, and a stalled check still surfaces.
#
# Real go.sh, ready-check.sh, cr-disposition.sh and chief-wait.sh; only gh is a stub (first on
# PATH, its mode read from a file so a row can flip it between samples). The tick is a stub
# that runs the real ghq_refresh, as tick.sh does, then prints a fixed TICK line. Every row
# runs one waiter per sample (CHIEF_WAIT_INTERVAL far away), so a sample is one start.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-quota.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-quota.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
WORK="$(cd "$WORK" && pwd)"
trap 'kill $(jobs -p) 2>/dev/null; pkill -f "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home" "$WORK/tmp" "$WORK/root" "$WORK/acks"

# No ambient token may reach a row: the loader skips a key already set, so a real read token
# would beat the fixture's.
unset himmel_github_token_vm2 GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN \
    HIMMEL_CONSOLE_LEG HIMMEL_CONSOLE_RELAY CHIEF_SESSION_NAME READY_CHECK_DEADLINE GO_DEADLINE

STUBBIN="$WORK/stubbin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/gh" <<'STUB'
#!/usr/bin/env bash
mode="$(cat "$STUB_MODE_FILE" 2>/dev/null)"; mode="${mode:-healthy}"
tok=main
[ "${GH_TOKEN:-}" = "$STUB_READ_TOKEN" ] && tok=read
probe=0
case "$*" in *rateLimit* | "api -i user"*) probe=1 ;; esac
[ "${STUB_PASS:-0}" = 1 ] || printf '%s %s %s\n' "$probe" "$tok" "$*" >> "$STUB_LOG"
bucket=core
case "${1:-}" in
    pr) [ "${2:-}" = diff ] || bucket=graphql ;;
    issue | repo) bucket=graphql ;;
    api) case "$*" in *graphql*) bucket=graphql ;; esac ;;
esac
refused=0
case "$mode" in
    gql-out) [ "$bucket" = graphql ] && refused=1 ;;
    rest-out) [ "$bucket" = core ] && refused=1 ;;
    both-out) refused=1 ;;
    main-only | i6) [ "$tok" = main ] && refused=1 ;;
    checks-out) [ "${1:-} ${2:-}" = "pr checks" ] && refused=1 ;;
    hung-after-probe) [ "$probe" = 1 ] || exec sleep 600 ;;
esac
if [ "$probe" = 1 ]; then
    rem=4000
    [ "$refused" = 0 ] || rem=0
    [ "$mode" != i6 ] || [ "$tok" != read ] || rem=300
    printf 'HTTP/2.0 %s\r\nX-Ratelimit-Remaining: %s\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Reset: %s\r\n\r\n{}\n' \
        "$([ "$rem" = 0 ] && echo '403 Forbidden' || echo '200 OK')" "$rem" "$(( $(date +%s) + 1800 ))"
    [ "$rem" != 0 ] || exit 1
    exit 0
fi
if [ "$refused" = 1 ]; then
    if [ "$bucket" = graphql ]; then
        grep -v '^# ' "$STUB_FIXDIR/55498a23-F1.txt" >&2
    else
        grep -v '^# ' "$STUB_FIXDIR/32a082f4-F2.txt"
        grep -v '^# ' "$STUB_FIXDIR/c5d6911e-F3.txt" >&2
    fi
    exit 1
fi
case "$*" in "pr checks"*) printf 'pass\n'; exit 0 ;; esac
# healthy: the ready-pass gh answers; a gh it hands on re-enters here and goes to the final gh
if [ "${STUB_PASS:-0}" = 1 ]; then exec "$STUB_FINAL_GH" "$@"; fi
export STUB_PASS=1
exec "$STUB_NEXT_GH" "$@"
STUB
chmod +x "$STUBBIN/gh"
FINALBIN="$WORK/finalbin"; mkdir -p "$FINALBIN"
printf '#!/usr/bin/env bash\ncase "$*" in "repo view --json nameWithOwner"*) printf "o/r\\n" ;; esac\nexit 0\n' > "$FINALBIN/gh"
chmod +x "$FINALBIN/gh"
printf 'himmel_github_token_vm2=readtok123\n' > "$WORK/env.root"
mkdir -p "$WORK/envroot"; mv "$WORK/env.root" "$WORK/envroot/.env"

# shellcheck source=scripts/handover/chief-kit/testlib-ready-pass.sh
. "$HERE/testlib-ready-pass.sh"
READY_BIN="$WORK/ready-bin"
ready_pass_bin "$READY_BIN"
GATE_REPO="$WORK/repo"
git init -q "$GATE_REPO" || exit 1
SHA=$(ready_pass_repo "$GATE_REPO") || { echo "fixture: no head" >&2; exit 1; }
SHA2=$(ready_pass_repo "$GATE_REPO" second) || { echo "fixture: no second head" >&2; exit 1; }
ready_pass_ledger "$GATE_REPO" "$SHA" "$SHA2" || { echo "fixture: no ledger rows" >&2; exit 1; }
export READY_STUB_HEAD="$SHA"

Q="$WORK/quota"; mkdir -p "$Q"
STUB_LOG="$WORK/stub.log"; : > "$STUB_LOG"
MODE="$WORK/mode"; printf 'healthy\n' > "$MODE"
printf '#!/usr/bin/env bash\necho PROCEED\n' > "$WORK/bank.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/off.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/none.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$WORK/budget-off.sh"
chmod +x "$WORK/off.sh" "$WORK/none.sh"
printf 'TICK 03:00 hb=1m workers=N1:FRESH livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=ok denials=none or=skip fails=none\n' > "$WORK/tick.line"
# The tick stub: the real quota refresh (tick.sh runs ghq_refresh first), unless a row froze
# quota.tsv; tick.fail makes the sample a failed one after the refresh.
cat > "$WORK/tick.sh" <<EOF
#!/usr/bin/env bash
if [ ! -e "$WORK/tick.norefresh" ]; then
    . "$ROOT/scripts/lib/gh-quota.sh"
    rm -f "$Q/quota.tsv"; ghq_refresh
fi
[ ! -e "$WORK/tick.fail" ] || exit 1
cat "$WORK/tick.line"
EOF

export HOME="$WORK/home" TMPDIR="$WORK/tmp" GH_TOKEN=maintok STUB_READ_TOKEN=readtok123 \
    STUB_FIXDIR="$HERE/testdata/quota" STUB_LOG STUB_MODE_FILE="$MODE" HIMMEL_QUOTA_DIR="$Q" \
    GH_READ_ENV_ROOT="$WORK/envroot" GH_BUDGET_JITTER_MAX=0 STUB_FINAL_GH="$FINALBIN/gh" \
    STUB_NEXT_GH="$READY_BIN/gh" PATH="$STUBBIN:$READY_BIN:$FINALBIN:$PATH" HANDOVER_DIR="$WORK/root" \
    GHQ_REPO=o/r GHQ_PROBE_TIMEOUT=3 GH_READ_TIMEOUT=4 HIMMEL_FLAG_AUTO_GO=off \
    CHIEF_WAIT_TICK="$WORK/tick.sh" CHIEF_WAIT_USAGE="$WORK/bank.sh" CHIEF_WAIT_INTERVAL=3600 CHIEF_WAIT_POLL_SEC=0.2 \
    CHIEF_WAIT_DISPATCH="$WORK/none.sh" CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_PAGE_CMD="$WORK/off.sh" \
    HIMMEL_DENIAL_ACK_DIR="$WORK/acks" CHIEF_WAIT_BUDGET="$WORK/budget-off.sh" WAIT_SWEEP_CMD="$WORK/off.sh" \
    WAIT_FOCUS_CMD="$WORK/off.sh" CHIEF_WAIT_SIZE="$WORK/none.sh" CHIEF_WAIT_ORPHAN="$WORK/off.sh"

mode() { printf '%s\n' "$1" > "$MODE"; }
now() { date +%s; }
# fleet <case> <worker label> <bullet>: a fresh inbox and a one-worker manifest; sets I, D, M
fleet() {
    mkdir -p "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"; : > "$I.announced"
    D="$WORK/$1/worker-$2-x.md"; printf '# worker on branch `docs/x`\n\n## Results\n- 11:00 %s\n' "$3" > "$D"
    M="$WORK/$1/fleet.json"; printf '{"schema":1,"workers":[{"label":"%s","doc":"%s"}]}\n' "$2" "$D" > "$M"
}
# marker <name> <first_epoch> [caller] [buckets] [reason] [back_epoch]: a gate's marker, by hand
marker() {
    mkdir -p "$Q/blocked"
    printf 'repo=o/r\ncaller=%s\nbuckets=%s\nroutes=main,read\nreason=%s\nfirst_epoch=%s\n%s' \
        "${3:-go.sh}" "${4:-graphql}" "${5:-rate-limit}" "$2" "${6:+back_epoch=$6
}" > "$Q/blocked/$1"
}
markers() { local f; for f in "$Q/blocked"/*; do [ -f "$f" ] && printf '%s\n' "${f##*/}"; done | LC_ALL=C sort | paste -sd' ' -; }
logmark() { wc -l < "$STUB_LOG" | tr -d ' '; }
# spent_since <mark>: the gh calls since the mark that were not quota probes
spent_since() { tail -n "+$(( $1 + 1 ))" "$STUB_LOG" | grep -c '^0 ' || true; }
# sample <inbox> <manifest> <out> [VAR=value...]: one waiter, one sample. rc = the waiter's exit
# code on a wake, "running" when the sample ended with no wake.
sample() {
    local i="$1" m="$2" out="$3" n=0; shift 3
    rm -f "$i.wait"
    ( cd "$GATE_REPO" && exec env "$@" bash "$WAIT" "$i" --workers-from "$m" ) > "$out" 2> "$out.err" &
    WPID=$!
    while [ "$n" -lt 1800 ]; do
        if ! kill -0 "$WPID" 2>/dev/null; then wait "$WPID"; rc=$?; return; fi
        if grep -q 'state=waiting' "$i.wait" 2>/dev/null; then
            kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; rc=running; return
        fi
        sleep 0.1; n=$((n + 1))
    done
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; rc=hung
}
backdate_digest() { printf '%s\n' "$(( $(now) - 1000 ))" > "$1.wait.housekeeping.since"; }

# --- (i4) the spec row: a refused go.sh wakes the chief once when quota is back -----------
# RED control (chief-wait.sh before this change): the head stays in readywoke, so the return
# sample wakes nothing and the marker is never read.
fleet i4 N1 "READY 77 $SHA GREEN"
mode healthy
sample "$I" "$M" "$WORK/i4-1.out"
check "(i4) a healthy READY wakes once" "0" "$rc"
check "(i4) with the checked line" "WAKE ready 77 $SHA" "$(head -n 1 "$WORK/i4-1.out" | cut -d' ' -f1-4)"
check "(i4) and records the head" "77 $SHA" "$(cat "$I.wait.readywoke" 2>/dev/null)"
mode gql-out
( cd "$GATE_REPO" && bash "$HERE/go.sh" 77 "$SHA" ) > "$WORK/i4-go.out" 2>&1; grc=$?
check "(i4) go.sh at quota out exits 11" "11" "$grc"
check "(i4) and writes no GO" "no" "$([ -e "$WORK/root/.locks/go/77.$SHA" ] && echo yes || echo no)"
check "(i4) and leaves the marker" "77.$SHA" "$(markers)"
backdate_digest "$I"
sample "$I" "$M" "$WORK/i4-2.out"
check "(i4) while quota is out, no wake (housekeeping window already past 900 s)" "running" "$rc"
check "(i4) and no line" "" "$(grep -E '^WAKE|quota-back' "$WORK/i4-2.out")"
sample "$I" "$M" "$WORK/i4-3.out"
check "(i4) RED control: quota never returning gives no wake" "running" "$rc"
check "(i4) and the marker stands" "77.$SHA" "$(markers)"
mode healthy
sample "$I" "$M" "$WORK/i4-4.out"
check "(i4) quota back: the waiter wakes" "0" "$rc"
check "(i4) exactly one WAKE ready, tailed after-quota=" "1" "$(grep -cE "^WAKE ready 77 $SHA .* after-quota=[a-z.-]+\$" "$WORK/i4-4.out")"
check "(i4) the marker is gone" "" "$(markers)"
check "(i4) no claimed copy is left" "" "$(find "$Q/blocked" -name '.claim*' 2>/dev/null)"
sample "$I" "$M" "$WORK/i4-5.out"
check "(i4) no second wake on the next sample" "running" "$rc"
# every reader of a WAKE ready line still parses the tailed one
WL="$(grep -m 1 '^WAKE ready' "$WORK/i4-4.out")"
check "(i4) waiter.md's shape holds before the tail" "yes" "$(printf '%s\n' "${WL% after-quota=*}" | grep -qE '^WAKE ready [0-9]+ [0-9a-f]{40} ready-check=(PASS|FAIL) ci=(GREEN|RED|PENDING|PAUSED) coverage=(PASS|FAIL) disposition=(ok|open:[0-9?]+) out=[^ ]+$' && echo yes)"
check "(i4) the out= reader gets the file, not the tail" "$I.wait.ready-77" "$(printf '%s\n' "$WL" | sed -n 's/.* out=\([^ ]*\).*/\1/p')"
check "(i4) judge.md's disposition= reader reads one value" "1" "$(printf '%s\n' "$WL" | grep -oE 'disposition=(ok|open:[0-9?]+)' | grep -c .)"

# --- (own) owner first: a marker 3000 s old, quota returns ---------------------------------
fleet own-b N2 "LIVE — working"; IB="$I"; MB="$M"
fleet own-a N1 "READY 77 $SHA GREEN"
printf '77 %s\n' "$SHA" > "$I.wait.readywoke"
rm -rf "$Q/blocked"; marker "77.$SHA" "$(( $(now) - 3000 ))" go.sh
mode healthy
sample "$IB" "$MB" "$WORK/own-b.out" HOUSEKEEPING_DIGEST_SECS=0
check "(own) the non-owner does not take it at return" "running" "$rc"
check "(own) the marker stands for the owner" "77.$SHA" "$(markers)"
check "(own) the first good reading stamps back_epoch" "yes" "$(grep -qE '^back_epoch=[0-9]+$' "$Q/blocked/77.$SHA" 2>/dev/null && echo yes)"
sample "$I" "$M" "$WORK/own-a.out"
check "(own) the owner gets the WAKE ready" "WAKE ready 77 $SHA" "$(head -n 1 "$WORK/own-a.out" | cut -d' ' -f1-4)"
check "(own) naming the gate" "after-quota=go.sh" "$(head -n 1 "$WORK/own-a.out" | grep -oE 'after-quota=[^ ]+$')"
check "(own) the marker is gone" "" "$(markers)"

# --- (unk) a marker with no head (check-ci read the PR, not its head) re-arms the worker's real head
fleet unk N1 "READY 77 $SHA GREEN"
printf '77 %s\n' "$SHA" > "$I.wait.readywoke"
rm -rf "$Q/blocked"; marker "77.unknown" "$(( $(now) - 100 ))" check-ci.sh
mode healthy
sample "$I" "$M" "$WORK/unk.out"
check "(unk) the woken head wakes again after quota" "WAKE ready 77 $SHA" "$(head -n 1 "$WORK/unk.out" | cut -d' ' -f1-4)"
check "(unk) naming the gate" "after-quota=check-ci.sh" "$(head -n 1 "$WORK/unk.out" | grep -oE 'after-quota=[^ ]+$')"

# --- (lock) the claim waits for the writers' lock, so a stamp or a merge cannot resurrect it
fleet lock N2 "LIVE — working"
rm -rf "$Q/blocked"; marker "66.$SHA2" "$(( $(now) - 5000 ))" go.sh graphql rate-limit "$(( $(now) - 1000 ))"
flock "$Q/blocked/.lock" sleep 6 &  # gnu-ok: Linux-only kit (util-linux flock)
lpid=$!
sleep 0.5
rm -f "$I.wait"
( cd "$GATE_REPO" && exec env HOUSEKEEPING_DIGEST_SECS=0 bash "$WAIT" "$I" --workers-from "$M" ) > "$WORK/lock.out" 2>&1 &
WPID=$!
sleep 4
check "(lock) while a writer holds the lock the marker is not claimed" "66.$SHA2" "$(markers)"
wait "$lpid"
n=0; while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(lock) once it is free the claim goes through, once" "WAKE quota-back 66 $SHA2 caller=go.sh" "$(head -n 1 "$WORK/lock.out")"
# a gate that refused again while the waiter waited for the lock: the claim sees the new text and leaves it
rm -rf "$Q/blocked"; marker "66.$SHA2" "$(( $(now) - 5000 ))" go.sh graphql rate-limit "$(( $(now) - 1000 ))"
flock "$Q/blocked/.lock" sleep 6 &  # gnu-ok: Linux-only kit (util-linux flock)
lpid=$!
sleep 0.5
rm -f "$I.wait"
( cd "$GATE_REPO" && exec env HOUSEKEEPING_DIGEST_SECS=0 bash "$WAIT" "$I" --workers-from "$M" ) > "$WORK/lockchg.out" 2>&1 &
WPID=$!
sleep 4
marker "66.$SHA2" "$(( $(now) - 5000 ))" go.sh graphql rate-limit
wait "$lpid"
n=0; while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(lock) a marker rewritten under the lock is not claimed on the old decision" "" "$(grep '^WAKE' "$WORK/lockchg.out")"
check "(lock) and it stands, as the gate wrote it" "66.$SHA2:" "$(markers):$(grep '^back_epoch=' "$Q/blocked/66.$SHA2" 2>/dev/null)"

# --- (nonown) another chief's PR: no wake until 900 s after back_epoch, and one claims -----
rm -rf "$Q/blocked"; marker "66.$SHA2" "$(( $(now) - 5000 ))" go.sh graphql rate-limit "$(( $(now) - 800 ))"
sample "$IB" "$MB" "$WORK/nonown-1.out" HOUSEKEEPING_DIGEST_SECS=0
check "(nonown) 800 s after back_epoch: no wake" "running" "$rc"
check "(nonown) the marker stands" "66.$SHA2" "$(markers)"
marker "66.$SHA2" "$(( $(now) - 5000 ))" go.sh graphql rate-limit "$(( $(now) - 1000 ))"
fleet nonown-c N3 "LIVE — working"
rm -f "$IB.wait" "$I.wait"
( cd "$GATE_REPO" && exec env HOUSEKEEPING_DIGEST_SECS=0 bash "$WAIT" "$IB" --workers-from "$MB" ) > "$WORK/nonown-2.out" 2>&1 &
w1=$!
( cd "$GATE_REPO" && exec env HOUSEKEEPING_DIGEST_SECS=0 bash "$WAIT" "$I" --workers-from "$M" ) > "$WORK/nonown-3.out" 2>&1 &
w2=$!
n=0
while [ "$n" -lt 600 ]; do
    d=0
    for p in "$w1:$IB" "$w2:$I"; do
        if ! kill -0 "${p%%:*}" 2>/dev/null || grep -q 'state=waiting' "${p#*:}.wait" 2>/dev/null; then d=$((d + 1)); fi
    done
    [ "$d" -lt 2 ] || break
    sleep 0.1; n=$((n + 1))
done
kill "$w1" "$w2" 2>/dev/null; wait "$w1" "$w2" 2>/dev/null
check "(nonown) two waiters past 900 s: exactly one quota-back wake" "1" "$(cat "$WORK/nonown-2.out" "$WORK/nonown-3.out" | grep -c "^WAKE quota-back 66 $SHA2 caller=go.sh\$")"
check "(nonown) the marker is gone" "" "$(markers)"

# --- (old) a marker 24 h old is dropped with no line -----------------------------------------
fleet old N3 "LIVE — working"
rm -rf "$Q/blocked"; marker "55.$SHA2" "$(( $(now) - 86401 ))"
mode gql-out
sample "$I" "$M" "$WORK/old.out" HOUSEKEEPING_DIGEST_SECS=0
check "(old) a 24 h marker wakes nothing" "running" "$rc"
check "(old) and is deleted" "" "$(markers)"

# --- (other) a branch marker reaches the waiter whose worker names the branch -------------
fleet other N1 "LIVE — working"
rm -rf "$Q/blocked"; marker "branch-docs%2Fx.unknown" "$(( $(now) - 100 ))" check-ci.sh
mode healthy
backdate_digest "$I"
sample "$I" "$M" "$WORK/other-1.out"
check "(other) quota back: the housekeeping window delivers it" "WAKE housekeeping kinds=quota-back" "$(head -n 1 "$WORK/other-1.out")"
check "(other) one look-only quota-back line" "1" "$(grep -c '^quota-back branch-docs/x unknown caller=check-ci.sh$' "$WORK/other-1.out")"
check "(other) the marker is gone" "" "$(markers)"
marker "branch-docs%2Fx.unknown" "$(( $(now) - 7300 ))" check-ci.sh
mode gql-out
sample "$I" "$M" "$WORK/other-2.out" HOUSEKEEPING_DIGEST_SECS=0
check "(other) the 7200 s backstop fires with no good reading, at once with the digest off" "0" "$rc"
check "(other) as quota=unknown" "WAKE quota-back branch-docs/x unknown caller=check-ci.sh quota=unknown" "$(head -n 1 "$WORK/other-2.out")"
check "(other) and the step ends the sample on it" "1" "$(grep -c '^WAKE' "$WORK/other-2.out")"
check "(other) the marker is gone" "" "$(markers)"

# --- (bkt) a marker clears only on its own buckets, read after it was written -------------
fleet bkt N1 "LIVE — working"
printf '88 %s\n' "$SHA2" > "$I.wait.readywoke"
rm -rf "$Q/blocked"; marker "88.$SHA2" "$(( $(now) - 100 ))" check-ci.sh core
mode rest-out
sample "$I" "$M" "$WORK/bkt-1.out" HOUSEKEEPING_DIGEST_SECS=0
check "(bkt) a rest-out marker does not clear on healthy GraphQL" "running" "$rc"
check "(bkt) the marker stands" "88.$SHA2" "$(markers)"
mode healthy
bash -c '. "$1" && rm -f "$2/quota.tsv" && ghq_refresh' _ "$ROOT/scripts/lib/gh-quota.sh" "$Q"
old=$(( $(now) - 200 ))
awk -F'\t' -v OFS='\t' -v o="$old" '{ $6 = o; print }' "$Q/quota.tsv" > "$Q/quota.tsv.tmp" && mv "$Q/quota.tsv.tmp" "$Q/quota.tsv"
: > "$WORK/tick.norefresh"
sample "$I" "$M" "$WORK/bkt-2.out" HOUSEKEEPING_DIGEST_SECS=0
check "(bkt) nor on a good reading older than first_epoch" "running" "$rc"
check "(bkt) the marker stands" "88.$SHA2" "$(markers)"
rm -f "$WORK/tick.norefresh"
sample "$I" "$M" "$WORK/bkt-3.out" HOUSEKEEPING_DIGEST_SECS=0
check "(bkt) control: a fresh good core reading clears it" "WAKE quota-back 88 $SHA2 caller=check-ci.sh" "$(head -n 1 "$WORK/bkt-3.out")"

# --- (i5) a READY while every GraphQL route is out spends nothing --------------------------
fleet i5 N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode both-out
lm=$(logmark)
sample "$I" "$M" "$WORK/i5-1.out"
check "(i5) a READY during both-out: no wake" "running" "$rc"
check "(i5) and no readywoke row" "" "$(cat "$I.wait.readywoke" 2>/dev/null)"
check "(i5) and no gh call but the tick's probes" "0" "$(spent_since "$lm")"
check "(i5) the waiter marks the head itself" "caller=chief-wait" "$(grep '^caller=' "$Q/blocked/77.$SHA" 2>/dev/null)"
fleet i5m N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode main-only
spent=""
for s in 1 2 3; do
    lm=$(logmark)
    sample "$I" "$M" "$WORK/i5m-$s.out"
    check "(i5m) main at 0, read alive: sample $s wakes nothing" "running" "$rc"
    if [ "$(spent_since "$lm")" -gt 0 ]; then spent="$spent$s"; fi
done
check "(i5m) the checks ran on the first sample only (stub log)" "1" "$spent"
check "(i5m) and the READY stays unspent" "" "$(cat "$I.wait.readywoke" 2>/dev/null)"

# --- (stall) a stalled check: no wake on the first sample, one STALLED wake on the second --
fleet stall N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode hung-after-probe
sample "$I" "$M" "$WORK/stall-1.out" READY_CHECK_DEADLINE=10
check "(stall) a GH-STALL check: no wake on the first sample" "running" "$rc"
check "(stall) a count file for the head" "yes" "$([ -e "$I.wait.stall-77.$SHA" ] && echo yes)"
check "(stall) and no readywoke row" "" "$(cat "$I.wait.readywoke" 2>/dev/null)"
sample "$I" "$M" "$WORK/stall-2.out" READY_CHECK_DEADLINE=10
check "(stall) the second sample wakes STALLED" "WAKE ready 77 $SHA ready-check=STALLED" "$(head -n 1 "$WORK/stall-2.out" | cut -d' ' -f1-5)"
check "(stall) recorded" "77 $SHA" "$(cat "$I.wait.readywoke" 2>/dev/null)"
check "(stall) the count file is gone" "no" "$([ -e "$I.wait.stall-77.$SHA" ] && echo yes || echo no)"
check "(stall) the stall marker is gone" "" "$(markers)"
check "(stall) no quota-back line for it" "" "$(grep -h 'quota-back' "$WORK/stall-1.out" "$WORK/stall-2.out" "$I.wait.housekeeping" 2>/dev/null)"
# a check killed by the waiter's outer timeout (rc 124) is a stall too
printf '#!/usr/bin/env bash\nsleep 60\n' > "$WORK/ready-check-slow.sh"
fleet kill N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode healthy
sample "$I" "$M" "$WORK/kill-1.out" READY_CHECK_DEADLINE=1 CHIEF_WAIT_READY_CHECK="$WORK/ready-check-slow.sh"
check "(kill) a check killed with rc 124: no wake on the first sample" "running" "$rc"
sample "$I" "$M" "$WORK/kill-2.out" READY_CHECK_DEADLINE=1 CHIEF_WAIT_READY_CHECK="$WORK/ready-check-slow.sh"
check "(kill) one STALLED wake on the second" "WAKE ready 77 $SHA ready-check=STALLED" "$(head -n 1 "$WORK/kill-2.out" | cut -d' ' -f1-5)"
check "(kill) the count file is gone" "no" "$([ -e "$I.wait.stall-77.$SHA" ] && echo yes || echo no)"
# at the default READY_CHECK_DEADLINE (150) the outer bound is 15 s above it
REAL_TIMEOUT="$(command -v timeout)"; export REAL_TIMEOUT  # gnu-ok: Linux-only kit
mkdir -p "$WORK/tbin"
printf '#!/usr/bin/env bash\ncase " $* " in *ready-check*) printf "%%s\\n" "$3" >> "%s/timeout-bounds" ;; esac\nexec "$REAL_TIMEOUT" "$@"\n' "$WORK" > "$WORK/tbin/timeout"
chmod +x "$WORK/tbin/timeout"
printf '#!/usr/bin/env bash\necho "[FAIL] 1 stub"; exit 1\n' > "$WORK/ready-check-fail.sh"
fleet bound N1 "READY 77 $SHA GREEN"
sample "$I" "$M" "$WORK/bound.out" PATH="$WORK/tbin:$PATH" CHIEF_WAIT_READY_CHECK="$WORK/ready-check-fail.sh"
check "(bound) the outer timeout is READY_CHECK_DEADLINE + 15" "165" "$(head -n 1 "$WORK/timeout-bounds" 2>/dev/null)"

# --- (i6) a READY with read at 300 (under the scan floor) and main at 0 runs its checks ----
fleet i6 N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode i6
lm=$(logmark)
sample "$I" "$M" "$WORK/i6.out"
check "(i6) the checks ran" "yes" "$([ "$(spent_since "$lm")" -gt 0 ] && echo yes)"

# --- (one) one sample runs at most one head's checks --------------------------------------
mkdir -p "$WORK/one/consoles"; I="$WORK/one/consoles/c.md"; : > "$I"; : > "$I.announced"
printf '# w\n\n## Results\n- 11:00 READY 77 %s GREEN\n' "$SHA" > "$WORK/one/N1.md"
printf '# w\n\n## Results\n- 11:00 READY 78 %s GREEN\n' "$SHA2" > "$WORK/one/N2.md"
M="$WORK/one/fleet.json"
printf '{"schema":1,"workers":[{"label":"N1","doc":"%s"},{"label":"N2","doc":"%s"}]}\n' "$WORK/one/N1.md" "$WORK/one/N2.md" > "$M"
rm -rf "$Q/blocked"
mode main-only
heads=""
for s in 1 2; do
    lm=$(logmark)
    sample "$I" "$M" "$WORK/one-$s.out"
    heads="$heads $(tail -n "+$(( lm + 1 ))" "$STUB_LOG" | grep '^0 ' | grep -oE '\b7[78]\b' | LC_ALL=C sort -u | paste -sd, -)"
done
check "(one) each sample checked one head, the second head on the later sample" " 77 78" "$heads"

# --- (ci) only the CI read refused: ci=PAUSED, recorded ------------------------------------
fleet ci N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"
mode checks-out
sample "$I" "$M" "$WORK/ci.out"
check "(ci) a classified CI refusal reads PAUSED" "ci=PAUSED" "$(head -n 1 "$WORK/ci.out" | grep -oE 'ci=[A-Z]+')"
check "(ci) recorded" "77 $SHA" "$(cat "$I.wait.readywoke" 2>/dev/null)"

# --- (hint) the READY hint survives a failed sample ----------------------------------------
fleet hint N1 "READY 77 $SHA GREEN"
printf '77 %s\n' "$SHA" > "$I.wait.readywoke"
rm -rf "$Q/blocked"; marker "77.$SHA" "$(( $(now) - 100 ))" ready-check.sh
mode healthy
: > "$WORK/tick.fail"
sample "$I" "$M" "$WORK/hint-1.out"
rm -f "$WORK/tick.fail"
check "(hint) a failed sample still takes the marker, and wakes nothing" "running:" "$rc:$(markers)"
check "(hint) the hint stands" "yes" "$([ -s "$I.wait.readyhint" ] && echo yes)"
sample "$I" "$M" "$WORK/hint-2.out"
check "(hint) the next good sample wakes after-quota" "after-quota=ready-check.sh" "$(head -n 1 "$WORK/hint-2.out" | grep -oE 'after-quota=[^ ]+$')"
check "(hint) and spends the hint" "no" "$([ -s "$I.wait.readyhint" ] && echo yes || echo no)"

# --- (tg) a Telegram line wakes within the paused-sample bound -----------------------------
fleet tg N1 "READY 77 $SHA GREEN"
rm -rf "$Q/blocked"; marker "77.$SHA" "$(( $(now) - 100 ))"
mode gql-out
lm=$(logmark)
( cd "$GATE_REPO" && exec env CHIEF_WAIT_INTERVAL=1 bash "$WAIT" "$I" --workers-from "$M" ) > "$WORK/tg.out" 2>&1 &
WPID=$!
n=0; while [ "$n" -lt 300 ] && ! grep -q 'state=waiting' "$I.wait" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
t0=$(now); printf 'status please\n' >> "$I"
n=0; while [ "$n" -lt 300 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
t1=$(now); kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
check "(tg) the Telegram line wakes" "WAKE telegram" "$(head -n 1 "$WORK/tg.out")"
check "(tg) within the paused-sample bound (30 s)" "yes" "$([ $((t1 - t0)) -le 30 ] && echo yes)"
check "(tg) a paused head spent no check" "0" "$(spent_since "$lm")"

check "no row reached the live quota dir" "no" "$([ -d "$WORK/home/.himmel/state/quota" ] && echo yes || echo no)"

if [ "$fails" -eq 0 ]; then echo "test-chief-wait-quota: all passed"; else echo "test-chief-wait-quota: $fails failed"; exit 1; fi
