#!/usr/bin/env bash
# test-tick.sh — Hermetic public-CLI tests for the batched chief
# tick: exact one-line output, verbose human output, stale fill, and a missing
# worker document. No live queue, process, scheduler, GitHub, or bank operations.
#
# Split in two: this suite ran 490 s against the runner's 600 s cap. The rows from the
# fails= section on live in test-tick-fields.sh; both source tick-test-fixture.sh for the stubs.
#
# the primary-path scenarios below drive claude_sessions() via a
# fake /proc root (CLAUDE_SESSIONS_PROC) with real NUL-separated
# <pid>/cmdline files, not a flattened `pgrep -af` line. The "lossy fallback"
# scenario below is the dedicated regression test for the no-/proc degraded
# path; #1335 reshaped its stubs to the real BSD binaries (`pgrep -x`
# bare pids + `ps -o pid=,args=`), since the old GNU-only `pgrep -af` stub
# masked the macOS bug it was supposed to catch.
#
# PLATFORM GUARD: The chief kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
# shellcheck disable=SC2015  # `[ cond ] && pass || fail`: pass() cannot fail, so A && B || C is if-then-else here
# shellcheck disable=SC2153  # REPO is exported by the sourced tick-test-fixture.sh
set -uo pipefail


HERE="$(cd "$(dirname "$0")" && pwd)"
leak_home="$(mktemp -d "${TMPDIR:-/tmp}/tick-leak-home.XXXXXX")" || exit 1
mkdir -p "$leak_home/.himmel/state/holds"
printf '2026-01-01T00:00:00Z\tdeny\tseed\tHIMMEL-1\tHIMMEL-2\n' > "$leak_home/.himmel/state/holds/events.log"
cp "$leak_home/.himmel/state/holds/events.log" "$leak_home/events.before"
export HOME="$leak_home"
# Fail closed: a missing or broken fixture must fail the suite, never run it with zero rows.
if ! { [ -r "$HERE/tick-test-fixture.sh" ] && . "$HERE/tick-test-fixture.sh"; } 2>/dev/null; then
    printf 'FAIL - %s (tick-test-fixture.sh missing, unreadable or failing to load)\n' "$(basename "$0")"
    exit 1
fi
mkdir -p "$W/leak-mirror/HIMMEL"
printf '%s\n' '# chief' > "$W/handover/leak-chief.md"
NEXT_DISPATCH_MIRROR="$W/leak-mirror/HIMMEL" TOKEN='' bash "$SUT" --doc "$W/handover/leak-chief.md" > /dev/null 2>&1
if cmp -s "$leak_home/events.before" "$leak_home/.himmel/state/holds/events.log" && [ "$(find "$leak_home/.himmel" -type f | wc -l)" -eq 1 ]; then
    pass '(9565) a tick run over the stub forge leaves the real holds log and register untouched'
else
    fail '(9565) a tick run over the stub forge wrote into the real holds log or register'
fi
rm -rf "$leak_home"
# A fresh heartbeat is not proof of worker activity. These rows catch removing
# the idle override, treating an unfinished foreground suite as idle, or making
# its label age-dependent (which would repeatedly wake the real waiter).
idle_held_cases() (
    local stamp out fresh idle1 idle2 idle3 rc wakes
    export WORKERS=HIMMEL-111-legN61
    export STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/1'
    export HIMMEL_CLASSIFIER_DENIALS_LOG="$W/idle-denials.jsonl"
    mk_pgrep_x "$W/bin" 101
    stamp="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"custom-title","customTitle":"HIMMEL-111-legN61"}\n{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp" > "$TICK_PROJECTS_DIR/p/idle.jsonl"
    fresh="$(bash "$SUT")"
    contains 'recent activity keeps a held lock FRESH' "$fresh" 'workers=N61:FRESH'
    stamp="$(date -u -d '46 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    idle1="$(bash "$SUT")"
    contains 'held lock with no activity past 45 minutes reports IDLE-HELD' "$idle1" 'workers=N61:IDLE-HELD'
    # shellcheck disable=SC2016  # backticks delimit literal Live-state entries
    printf '%s\n' '# chief' '## Live state' 'legs: `N61:TEST-N61-ab:lock:101`' > "$W/handover/idle-chief.md"
    out="$(DOC="$W/handover/idle-chief.md" bash "$SUT")"
    contains 'IDLE-HELD still counts as held in the chief live state' "$out" 'livestate=ok'
    contains 'IDLE-HELD still counts its live worker process' "$out" 'procs=1'
    rm -f "$W/handover/idle-chief.md"
    printf 'idle proof: %s\n' "$idle1"
    out="$(TICK_IDLE_MIN=60 bash "$SUT")"
    contains 'idle threshold override preserves a younger worker' "$out" 'workers=N61:FRESH'
    out="$(TICK_IDLE_MIN=invalid bash "$SUT")"
    contains 'invalid idle threshold uses the default' "$out" 'workers=N61:IDLE-HELD'
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"suite-1","name":"Bash","input":{"command":"bash scripts/quiet-run.sh suite -- bash test-long.sh"}}]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'a long foreground suite keeps its held lock FRESH' "$out" 'workers=N61:FRESH'
    printf 'foreground proof: %s\n' "$out"
    printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"suite-1","content":"exit 0"}]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    idle2="$(bash "$SUT")"
    contains 'a completed suite no longer hides an idle held worker' "$idle2" 'workers=N61:IDLE-HELD'
    stamp="$(date -u -d '49 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    idle3="$(bash "$SUT")"
    contains 'growing inactivity keeps the same IDLE-HELD state' "$idle3" 'workers=N61:IDLE-HELD'
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"agent-1","name":"Agent","input":{"prompt":"run independent work"}}]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'an unfinished foreground Agent keeps its held lock FRESH' "$out" 'workers=N61:FRESH'
    printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"agent-1","content":"done"}]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'a completed Agent no longer hides an idle held worker' "$out" 'workers=N61:IDLE-HELD'
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"taskId":"monitor-1"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'an armed Monitor keeps a held worker FRESH' "$out" 'workers=N61:FRESH'
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"task_id":"monitor-1"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'a stopped Monitor no longer hides an idle worker' "$out" 'workers=N61:IDLE-HELD'
    stamp="$(date -u -d '55 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"suite-2","name":"Bash","input":{"command":"bash test-long.sh"}}]}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'an old foreground suite preserves the existing cachettl advisory' "$out" ' cachettl=N61'
    contains 'an old foreground suite still keeps its held lock FRESH' "$out" 'workers=N61:FRESH'
    {
        printf '{"type":"user","timestamp":"%s","message":{"content":[{"type":"tool_result","tool_use_id":"suite-2","content":"exit 0"}]}}\n' "$stamp"
        printf '%s\n' '{malformed activity row'
        printf '{"type":"user","timestamp":"%s","message":{"content":[]}}\n' "$stamp"
    } >> "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'malformed middle activity evidence leaves a held lock FRESH' "$out" 'workers=N61:FRESH'
    contains 'malformed middle rows preserve the existing cachettl advisory' "$out" ' cachettl=N61'
    printf '{"type":"custom-title","customTitle":"HIMMEL-111-legN61"}\n{"type":"assistant","timestamp":"%s","message":{"content":["text",null,7,{"type":"text","text":"done"}]}}\n{"type":"user","timestamp":"%s","message":{"content":["text",null,7]}}\n' "$stamp" "$stamp" > "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'non-object content elements do not hide an idle held worker' "$out" 'workers=N61:IDLE-HELD'
    contains 'non-object content elements preserve the existing cachettl advisory' "$out" ' cachettl=N61'
    rm -f "$TICK_PROJECTS_DIR/p/idle.jsonl"
    out="$(bash "$SUT")"
    contains 'missing session activity evidence leaves a held lock FRESH' "$out" 'workers=N61:FRESH'

    # Replay a healthy baseline and the three real idle ticks through the real
    # waiter, including its debounce and persisted re-arm key. All other probes
    # are off; neither a live chief nor an external service is touched.
    mkdir -p "$W/idle-wake/consoles"
    printf '%s\n' "$fresh" "$idle1" "$idle2" "$idle3" > "$W/idle-wake/samples"
    printf '0\n' > "$W/idle-wake/count"
    cat > "$W/idle-wake/tick.sh" <<'STUB'
#!/usr/bin/env bash
n="$(cat "$IDLE_WAKE/count")"
[ "$n" -lt 4 ] || exit 1
n=$((n + 1))
printf '%s\n' "$n" > "$IDLE_WAKE/count"
sed -n "${n}p" "$IDLE_WAKE/samples"
STUB
    printf '#!/bin/sh\nprintf "PROCEED\\n"\n' > "$W/idle-wake/bank.sh"
    printf '#!/bin/sh\nexit 0\n' > "$W/idle-wake/off.sh"
    export IDLE_WAKE="$W/idle-wake"
    export CHIEF_WAIT_TICK="$IDLE_WAKE/tick.sh" CHIEF_WAIT_USAGE="$IDLE_WAKE/bank.sh"
    export CHIEF_WAIT_INTERVAL=0 CHIEF_WAIT_POLL_SEC=0.1 CHIEF_WAIT_FAIL_WAKE=1000
    export CHIEF_WAIT_DISPATCH="$IDLE_WAKE/missing" CHIEF_WAIT_BUDGET="$IDLE_WAKE/off.sh"
    export WAIT_SWEEP_CMD="$IDLE_WAKE/off.sh" WAIT_FOCUS_CMD="$IDLE_WAKE/off.sh"
    export HOUSEKEEPING_DIGEST_SECS=0
    timeout -k 1 10 bash "$HERE/chief-wait.sh" "$IDLE_WAKE/consoles/chief.md" --workers N61.md > "$IDLE_WAKE/wake" 2> "$IDLE_WAKE/err"
    rc=$?
    [ "$rc" -eq 0 ] && pass 'idle transition wakes the waiter' || fail "idle transition did not wake the waiter (rc $rc)"
    contains 'the wake names the worker state change' "$(cat "$IDLE_WAKE/wake")" 'WAKE tick changed=workers usage=PROCEED'
    timeout -k 1 2 bash "$HERE/chief-wait.sh" "$IDLE_WAKE/consoles/chief.md" --workers N61.md >> "$IDLE_WAKE/wake" 2>> "$IDLE_WAKE/err"
    rc=$?
    [ "$rc" -eq 124 ] && pass 'unchanged idle state keeps the re-armed waiter silent' || fail "idle re-arm unexpectedly exited (rc $rc)"
    wakes="$(grep -c '^WAKE ' "$IDLE_WAKE/wake")"
    [ "$wakes" = 1 ] && [ "$(cat "$IDLE_WAKE/count")" = 4 ] && pass 'one wake over three idle ticks' || fail "expected one wake over three idle ticks, got $wakes wakes"
    rm -f "$TICK_PROJECTS_DIR/p/idle.jsonl"
    mk_pgrep_x "$W/bin" 101 102 103
    [ "$fails" -eq 0 ]
)
if [ "${1:-}" = --idle-held-only ]; then
    if ! idle_held_cases; then fails=$((fails + 1)); fi
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi
if [ "${1:-}" != --ciq-sampled ] && [ "${1:-}" != --cachettl-only ]; then
    if ! idle_held_cases; then fails=$((fails + 1)); fi
fi

cachettl_cases() (
    local stamp out verbose_out scans
    stamp="$(date -u -d '55 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"custom-title","customTitle":"HIMMEL-111-legN61"}\n{"type":"assistant","timestamp":"%s"}\n' "$stamp" > "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    contains 'an idle 55-minute worker is listed in cachettl' "$out" ' cachettl=N61'
    verbose_out="$(bash "$SUT" --verbose)"
    contains 'verbose output names the cachettl worker' "$verbose_out" 'cachettl: N61'
    stamp="$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"assistant","timestamp":"%s"}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    not_contains 'an idle 30-minute worker is not listed' "$out" ' cachettl='
    stamp="$(date -u -d '55 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"taskId":"wait-1"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    not_contains 'an old worker with an armed Monitor is not listed' "$out" ' cachettl='
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"task_id":"wait-1"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    contains 'a stopped Monitor no longer hides an old idle worker' "$out" ' cachettl=N61'
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"backgroundTaskId":"bash-1"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    not_contains 'an old worker with background Bash is not listed' "$out" ' cachettl='
    printf '{"type":"queue-operation","timestamp":"%s","content":"<task-notification><task-id>bash-1</task-id><status>completed</status></task-notification>"}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    contains 'a terminal task notification restores the idle warning' "$out" ' cachettl=N61'
    printf '{"type":"user","timestamp":"%s","toolUseResult":{"taskId":"wait-2"}}\n{"type":"attachment","timestamp":"%s","attachment":{"prompt":"<task-notification><task-id>wait-2</task-id>still running</task-notification>"}}\n' "$stamp" "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    not_contains 'a nonterminal notification leaves its wait armed' "$out" ' cachettl='
    printf '{"type":"user","timestamp":"%s","message":{"content":"<task-notification><task-id>wait-2</task-id><status>failed</status></task-notification>"}}\n' "$stamp" >> "$TICK_PROJECTS_DIR/p/cache.jsonl"
    printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/HIMMEL-6532-N1-other.md"
    printf '{"type":"custom-title","customTitle":"HIMMEL-6532-N1-other"}\n{"type":"assistant","timestamp":"%s"}\n' "$stamp" > "$TICK_PROJECTS_DIR/p/other.jsonl"
    out="$(WORKERS='HIMMEL-111-legN61 HIMMEL-6532-N1-other' bash "$SUT")"
    contains 'multiple idle workers are comma joined after terminal notifications' "$out" ' cachettl=N61,N1'
    # one transcript pass per tick, however many workers and candidate names
    mkdir -p "$W/grepshim"
    # shellcheck disable=SC2016  # the shim script expands its own $* and "$@"
    printf '#!/bin/sh\ncase "$*" in *customTitle*) echo x >> "$GREP_COUNT_FILE" ;; esac\nexec "%s" "$@"\n' "$(command -v grep)" > "$W/grepshim/grep"
    chmod +x "$W/grepshim/grep"
    : > "$W/grepshim/count"
    two_workers='HIMMEL-111-legN61 HIMMEL-6532-N1-other'
    out="$(WORKERS="$two_workers" PATH="$W/grepshim:$PATH" GREP_COUNT_FILE="$W/grepshim/count" bash "$SUT")"
    contains 'the shared transcript index still lists both idle workers' "$out" ' cachettl=N61,N1'
    scans="$(wc -l < "$W/grepshim/count" | tr -d ' ')"
    [ "$scans" -eq 1 ] && pass "two workers cost one transcript scan ($scans)" || fail "two workers cost $scans transcript scans, expected 1"
    touch -d '25 hours ago' "$TICK_PROJECTS_DIR/p/cache.jsonl"
    out="$(bash "$SUT")"
    not_contains 'a matching transcript older than the search window is ignored' "$out" ' cachettl='
    rm -f "$TICK_PROJECTS_DIR/p/cache.jsonl" "$TICK_PROJECTS_DIR/p/other.jsonl" "$W/handover/HIMMEL-6532-N1-other.md"
    out="$(bash "$SUT")"
    not_contains 'a missing transcript never invents an idle worker' "$out" ' cachettl='
    [ "$fails" -eq 0 ]
)
if [ "${1:-}" != --ciq-sampled ]; then
    if ! cachettl_cases; then fails=$((fails + 1)); fi
fi
if [ "${1:-}" = --cachettl-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

# Partial counts below the cap cannot become an exact, healthy tick sample.
mkdir -p "$W/repo/scripts/ci"
cat > "$W/repo/scripts/ci/queue-latency.sh" <<'STUB'
#!/bin/sh
printf '%s\n' "$STUB_CIQ_OUT"
STUB
sampled_out='ci-queue: jobs_in_progress=44/60 macos=0/5 queued=29 oldest_wait=10m sampled=true'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'a below-cap sampled probe stays unknown' "$sampled_tick" 'ciq=unknown'
not_contains 'a below-cap sampled probe is not an exact count' "$sampled_tick" 'ciq=44/60'
not_contains 'a below-cap sampled probe cannot claim saturation' "$sampled_tick" 'SATURATED'
# Proven saturation keeps a parser-compatible count and a separate sample label.
sampled_out=$'ci-queue: jobs_in_progress=64/60 macos=0/5 queued=32 oldest_wait=10m\nci-queue: sampled=true'
rm -rf "$W/state"
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
not_contains 'one proven sampled breach does not raise SATURATED' "$sampled_tick" 'SATURATED'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'two proven sampled breaches still raise SATURATED' "$sampled_tick" 'ciq=64/60,mac=0/5,q=32,wait=10m,SATURATED'

# Running jobs alone never establish waiting, even above the reporting cap.
rm -rf "$W/state"
sampled_out='ci-queue: jobs_in_progress=136/60 macos=0/5 queued=0 oldest_wait=0m'
STUB_CIQ_OUT="$sampled_out" bash "$SUT" >/dev/null 2>&1
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'running jobs preserve the reported count above the cap' "$sampled_tick" 'ciq=136/60,mac=0/5,q=0,wait=0m'
not_contains 'two above-cap ticks without waiting never saturate' "$sampled_tick" 'SATURATED'

# Waiting is sufficient below the cap, including a labelled partial sample.
rm -rf "$W/state"
sampled_out=$'ci-queue: jobs_in_progress=13/500 macos=0/5 queued=1 oldest_wait=0m\nci-queue: sampled=true'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
not_contains 'one below-cap waiting tick is not yet saturated' "$sampled_tick" 'SATURATED'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'two below-cap waiting ticks saturate' "$sampled_tick" 'ciq=13/500,mac=0/5,q=1,wait=0m,SATURATED'

sampled_out='ci-queue: jobs_in_progress=500/500 macos=0/5 queued=1 oldest_wait=0m'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'waiting at the cap still saturates' "$sampled_tick" 'ciq=500/500,mac=0/5,q=1,wait=0m,SATURATED'

sampled_out='ci-queue: jobs_in_progress=136/500 macos=0/5 queued=0 oldest_wait=0m'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
not_contains 'cleared waiting resets saturation despite running jobs' "$sampled_tick" 'SATURATED'
sampled_out='ci-queue: jobs_in_progress=13/500 macos=0/5 queued=1 oldest_wait=0m'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
not_contains 'waiting after a clear starts a new streak' "$sampled_tick" 'SATURATED'
sampled_out='ci-queue: unknown'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'unknown retains the waiting streak without certifying counts' "$sampled_tick" 'ciq=unknown'
sampled_out='ci-queue: jobs_in_progress=13/500 macos=0/5 queued=1 oldest_wait=0m'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'unknown does not clear a below-cap waiting streak' "$sampled_tick" 'ciq=13/500,mac=0/5,q=1,wait=0m,SATURATED'

rm -rf "$W/state"
sampled_out='ci-queue: jobs_in_progress=0/500 macos=0/5 queued=0 oldest_wait=2m'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
not_contains 'one oldest-wait-only tick is not yet saturated' "$sampled_tick" 'SATURATED'
sampled_tick="$(STUB_CIQ_OUT="$sampled_out" bash "$SUT" 2>/dev/null)"
contains 'oldest wait alone establishes persistent waiting' "$sampled_tick" 'ciq=0/500,mac=0/5,q=0,wait=2m,SATURATED'
rm -f "$W/repo/scripts/ci/queue-latency.sh"
rm -rf "$W/state"
if [ "${1:-}" = --ciq-sampled ]; then
    if [ "$fails" -eq 0 ]; then printf 'PASSED\n'; exit 0; else printf 'FAILED=%s\n' "$fails"; exit 1; fi
fi

# Missing cadence, a fresh marker, and an overlapping tick must not be confused.
worktree_prune_cases() (
    local repo="$W/prune-repo" bin="$W/prune-bin" state="$W/prune-state" stamp out
    mkdir -p "$repo/scripts" "$bin" "$state" || exit 1
    git init -q -b main "$repo" || exit 1
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name test
    printf 'base\n' > "$repo/README"
    git -C "$repo" add README
    git -C "$repo" commit -qm base || exit 1
    git init -q --bare "$W/prune-origin.git" || exit 1
    git -C "$repo" remote add origin "$W/prune-origin.git"
    printf '#!/usr/bin/env bash\nexec bash %q "$@"\n' "$HERE/../../worktree.sh" > "$repo/scripts/worktree.sh"
    cat > "$bin/gh" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *'auth status'*) exit 0 ;;
    *'repo view'*) echo owner/repo; exit 0 ;;
    *'api --paginate repos/owner/repo/pulls'*)
        case "$*" in *state=open*) exit 0 ;; esac
        git for-each-ref --format='owner/repo%x09%(refname:short)%x09merged%x09%(objectname)' refs/heads/feat | sed 's/%x09/\t/g'
        exit 0 ;;
esac
printf 'unexpected gh command: %s\n' "$*" >&2
exit 1
STUB
    chmod +x "$bin/gh"
    if "$bin/gh" auth satus >/dev/null 2>&1; then fail 'forge stub accepts an invalid command'; else pass 'forge stub rejects unexpected commands'; fi
    printf 'CEILING 72/100 worktrees (alarm at 70)\n' > "$state/tick-wt-orphans-$(printf '%s' "$repo" | cksum | cut -d' ' -f1)"
    git -C "$repo" worktree add -qb feat/clean "$W/prune-clean" || exit 1
    git -C "$repo" worktree add -qb feat/dirty "$W/prune-dirty" || exit 1
    printf 'user work\n' >> "$W/prune-dirty/README"
    # Age both fixture reflogs so the real prune's activity gate is satisfied.
    touch -d '2 hours ago' "$repo/.git/worktrees/prune-clean/logs/HEAD" "$repo/.git/worktrees/prune-dirty/logs/HEAD"
    prune_tick() {
        PATH="$bin:$PATH" REPO="$repo" TICK_STATE_DIR="$state" TOKEN='' WORKERS='' DOC='' \
            FORGE=github WORKTREE_ORPHAN_HOURS=0 bash "$SUT" 2>/dev/null
    }
    out="$(prune_tick)"
    [ ! -d "$W/prune-clean" ] && pass 'cadence reclaims an old merged clean worktree without manual clean' || fail 'cadence did not reclaim an old merged clean worktree'
    [ -d "$W/prune-dirty" ] && grep -qx 'user work' "$W/prune-dirty/README" && pass 'cadence preserves a dirty worktree and its edits' || fail 'cadence lost dirty user work'
    contains 'cadence keeps the tick output available' "$out" 'TICK '
    not_contains 'a successful sweep invalidates the stale ceiling census' "$out" ' wt-ceiling=72/100'
    stamp="$state/tick-wt-prune-$(printf '%s' "$repo/.git" | cksum | cut -d' ' -f1)"
    git -C "$repo" worktree add -qb feat/later "$W/prune-later" || exit 1
    out="$(prune_tick)"
    [ -d "$W/prune-later" ] && pass 'a second tick inside the hour does not sweep again' || fail 'cadence swept twice inside an hour'
    touch -d '61 minutes ago' "$stamp"
    exec 7>>"$stamp.lock"
    flock -n 7 || exit 1  # gnu-ok: chief kit is Linux-only
    out="$(prune_tick 7>&-)"
    [ -d "$W/prune-later" ] && pass 'a concurrent sweep lock suppresses a due tick' || fail 'cadence ignored a held sweep lock'
    exec 7>&-
    out="$(prune_tick)"
    [ ! -d "$W/prune-later" ] && pass 'the next due tick reclaims clean worktrees after the hour' || fail 'cadence did not sweep after the hour'
    [ -d "$W/prune-dirty" ] && pass 'later sweeps still preserve the dirty worktree' || fail 'later cadence removed the dirty worktree'
    # Simulate a sweep consuming its full minute without making the suite sleep.
    cat > "$bin/date" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = +%s ] && [ -f "$PRUNE_CLOCK" ]; then cat "$PRUNE_CLOCK"; else /bin/date "$@"; fi
STUB
    cat > "$bin/timeout" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    *"$PRUNE_WRAPPER prune --orphans") printf '%s\n' "$3" > "$PRUNE_BUDGET"; exit 0 ;;
    *"$PRUNE_WRAPPER prune") printf '%s\n' "$(( $(cat "$PRUNE_CLOCK") + 60 ))" > "$PRUNE_CLOCK"; exit 0 ;;
esac
exec /usr/bin/timeout "$@"
STUB
    chmod +x "$bin/date" "$bin/timeout"
    export PRUNE_CLOCK="$W/prune-clock"
    export PRUNE_BUDGET="$W/prune-budget"
    export PRUNE_WRAPPER="$repo/scripts/worktree.sh"
    /bin/date +%s > "$PRUNE_CLOCK"
    touch -d '61 minutes ago' "$stamp"
    rm -f "$state/tick-wt-orphans-$(printf '%s' "$repo" | cksum | cut -d' ' -f1)"
    out="$(prune_tick)"
    if [ -f "$PRUNE_BUDGET" ] && [ "$(cat "$PRUNE_BUDGET")" -le 30 ]; then pass 'the census shares the sweep deadline'; else fail 'the census exceeded the combined maintenance budget'; fi
    [ "$fails" -eq 0 ]
)
if ! worktree_prune_cases; then fails=$((fails + 1)); fi
if [ "${1:-}" = --worktree-prune-only ]; then
    printf '\n%d failure(s)\n' "$fails"
    [ "$fails" -eq 0 ]; exit $?
fi

# The default stub reset epoch, rendered the way tick.sh renders it (local HH:MM).
gql_hm="$(date -d @1790000000 +%H:%M 2>/dev/null || date -r 1790000000 +%H:%M)"
out="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$W/denials-default-missing.jsonl" bash "$SUT")"; rc=$?
expected='TICK 12:34 workers=N61:FRESH,N65:FREE livestate=skip procs=1,unwatched=N9 models=sonnet:1 atq=2 suites=1alive/0dead prs=#2247,#2250 unowned-prs=none usage=5h30/wk28/codex=5h12/wk34 fill=28 tails=N61:LIVE,N65:READY acts=N65:READY#1 inbox=N61:10/4 fleet=1/8 capacity=UNDERFILLED:7 gql=4321/'"$gql_hm"' workerset=skip board=skip tracker=skip vault=skip cloud=skip orphans-wip=skip pool=skip denials=none ciq=unknown ciguard=unknown cired=unknown vmrun=off'
lines="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ "$lines" = 1 ] && [ "$out" = "$expected" ]; then
    pass 'default run emits exactly the expected one batched line'
else
    fail "default run exact line (rc=$rc lines=$lines out='$out')"
fi

# Removing required/default reader fields would break a successful sample or
# leave persisted underfill/unowned markers uncleared. Values stay literal.
for kv in workers=N61:FRESH,N65:FREE livestate=skip prs=#2247,#2250 tails=N61:LIVE,N65:READY \
    workerset=skip board=skip tracker=skip vault=skip cloud=skip orphans-wip=skip \
    denials=none vmrun=off unowned-prs=none usage=5h30/wk28/codex=5h12/wk34; do
    contains "reader field stays byte-identical: $kv" " $out " " $kv "
done
compact_full="$(STUB_FLEET_LINE='bank-preflight: FLEET native=8 claudex=0 openrouter=0 reserved=0 total=8/8' bash "$SUT")"
contains 'capacity=ok stays present to clear the underfill streak' "$compact_full" ' capacity=ok '
for kv in hb=ok ceiling=ok ext-prs=none tick=UNKNOWN orphans=none nonces=skip plan-index=skip or=skip fails=skip; do
    not_contains "compact line omits unconsumed default $kv" " $out " " $kv "
done

# A consumed, empty or partial-only inbox has no unread complete line. Native
# followers use <inbox>.cursor; hook delivery uses .cursor/<session> instead.
printf '10\n' > "$W/handover/inbox/.cursor/N61"
printf 'partial' > "$W/handover/inbox/N66.md"
: > "$W/handover/inbox/N67.md"
not_contains 'all consumed or partial inboxes omit inbox= entirely' "$(bash "$SUT")" ' inbox='
printf 'new\n' > "$W/handover/inbox/N66.md"
contains 'a new inbox with no cursor surfaces its unread line' "$(bash "$SUT")" ' inbox=N66:4/0 '
printf '4\n' > "$W/handover/inbox/N66.md.cursor"
not_contains 'native follower cursor hides a consumed inbox' "$(bash "$SUT")" ' inbox='
printf 'broken\n' > "$W/handover/inbox/N66.md.cursor"
contains 'a corrupt native cursor means the line is unread' "$(bash "$SUT")" ' inbox=N66:4/0 '
printf '0\n' > "$W/handover/inbox/.cursor/N66"
printf '4\n' > "$W/handover/inbox/N66.md.cursor"
contains 'hook delivery cursor wins over a follower wake cursor' "$(bash "$SUT")" ' inbox=N66:4/0 '
printf '04\n' > "$W/handover/inbox/.cursor/N66"
not_contains 'a leading-zero hook cursor is compared in decimal' "$(bash "$SUT")" ' inbox='
printf '4\n' > "$W/handover/inbox/.cursor/N61"
rm -f "$W/handover/inbox/N66.md" "$W/handover/inbox/N66.md.cursor" "$W/handover/inbox/.cursor/N66" "$W/handover/inbox/N67.md"

weekly_only="$(STUB_BANK_ROW='claudex funded measured weekly used=6% free=94% resets=2026-10-20T05:00:09.000Z' HIMMEL_CLASSIFIER_DENIALS_LOG="$W/denials-default-missing.jsonl" bash "$SUT")"
case "$weekly_only" in
    *' usage=5h30/wk28/codex=5hnone/wk6 '*) pass 'a weekly-only codex row reads as no 5h limit' ;;
    *) fail "weekly-only codex row (out='$weekly_only')" ;;
esac

verbose="$(bash "$SUT" --verbose)"; rc=$?
verbose_lines="$(printf '%s\n' "$verbose" | wc -l | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ "$verbose_lines" -gt 1 ]; then
    pass '--verbose emits a multi-line human form'
else
    fail "--verbose emits multiple lines (rc=$rc lines=$verbose_lines)"
fi
contains '--verbose labels worker locks' "$verbose" 'worker-session locks: N61:FRESH,N65:FREE'
contains '--verbose prints the description next to the label of a no-PR worker (HIMMEL-4749)' "$verbose" 'worker-session descriptions: N61  Add a login form'
not_contains 'the compact tick line carries no descriptions (HIMMEL-4749)' "$(bash "$SUT")" 'Add a login form'
contains '--verbose labels context fill' "$verbose" 'fill: 28'
contains '--verbose labels worker models (HIMMEL-2976, HIMMEL-3145)' "$verbose" 'worker-session models: sonnet:1'

# --- a chief FOR another checkout lists that checkout's PRs, not himmel's.
# chief.sh records the project on the doc's project line; the gh stub answers
# only from GH_STUB_CWD, so prs= is populated only when gh ran in that checkout.
mkdir -p "$W/project"
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '> the repo you ship from is **`x`**. The project this console is FOR is **`'"$W/project"'`** — you' \
    > "$W/handover/chief-project.md"
proj_out="$(TOKEN='' GH_STUB_CWD="$W/project" bash "$SUT" --doc "$W/handover/chief-project.md")"
contains 'a foreign chief lists its project PRs (gh runs in the project)' "$proj_out" ' prs=#2247,#2250 '
proj_out="$(TOKEN='' bash "$SUT" --doc "$W/handover/chief-project.md")"
contains 'a foreign chief never lists the himmel REPO PRs' "$proj_out" ' prs=? '
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '> The project this console is FOR is **`none — this console runs in the himmel checkout itself`** — you' \
    > "$W/handover/chief-himmel.md"
proj_out="$(TOKEN='' bash "$SUT" --doc "$W/handover/chief-himmel.md")"
contains 'a himmel chief (project line reads none) lists the REPO PRs' "$proj_out" ' prs=#2247,#2250 '

# --- unowned-prs= / ext-prs=: an open PR whose head branch no held worker,
# live manifest row or cloud session owns is flagged with its age; drafts, fork PRs
# and PRs inside the grace period are not. Owner = the ticket key in the branch name
# matching a worker doc the tick reads whose lock is held (FRESH/STALE) or lockless.
iso_ago() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ; }
rows_5542="$(printf '%s\t%s\t%s\t%s\t%s\t%s\\n' \
    3001 feat/himmel-111-owned false me false "$(iso_ago 300)" \
    3002 feat/himmel-999-orphan false me false "$(iso_ago 125)" \
    3003 feat/himmel-998-draft true me false "$(iso_ago 300)" \
    3004 feat/himmel-997-young false me false "$(iso_ago 3)" \
    3005 fix/ext-thing false stranger true "$(iso_ago 300)" \
    3006 feat/himmel-222-ready-worker false me false "$(iso_ago 300)")"
own_out="$(STUB_PR_ROWS="$rows_5542" bash "$SUT")"
contains 'an open PR with no lock or worker appears in unowned-prs with its age' "$own_out" 'unowned-prs=#3002:125m'
not_contains 'a PR owned by a held lock is not unowned' "$own_out" '#3001:'
not_contains 'a draft PR is not unowned' "$own_out" '#3003:'
not_contains 'a PR inside the grace period is not unowned' "$own_out" '#3004:'
not_contains 'a fork PR is not unowned' "$own_out" '#3005:'
contains 'a fork PR is listed in ext-prs' "$own_out" 'ext-prs=#3005'
contains 'a worker whose lock is free still owns nothing, so its PR is flagged' "$own_out" '#3006:300m'
contains 'prs= still lists every open PR' "$own_out" 'prs=#3001,#3002,#3003,#3004,#3005,#3006 '
contains 'a failed gh read is unowned-prs=?, not an all-clear' "$(STUB_PR_FAIL=1 bash "$SUT")" 'unowned-prs=? ext-prs=?'
contains 'a failed gh read is prs=?, not an all-clear (HIMMEL-8735)' "$(STUB_PR_FAIL=1 bash "$SUT")" ' prs=? '
if [ -n "$_TIMEOUT_BIN" ]; then
    # The deadline cuts the list to its 1 s floor. Without that bound the stub answers after 5 s with its rows.
    printf '#!/usr/bin/env bash\ntouch "%s"\necho STALL 42 no-ci\n' "$W/pr-hung-stall.ran" > "$W/pr-hung-stall"
    rm -f "$W/pr-hung-stall.ran" "$W/pr-hung-stall.cache"
    pr_hung="$(STUB_PR_SLEEP=5 TICK_DEADLINE_SEC=1 TICK_STALL_PROBE="$W/pr-hung-stall" TICK_STALL_CACHE="$W/pr-hung-stall.cache" bash "$SUT" 2>/dev/null)"
    contains 'a hung gh list reads prs=?, not an all-clear (HIMMEL-8735)' "$pr_hung" ' prs=? '
    contains 'a hung gh list still yields the worker state (HIMMEL-8735)' "$pr_hung" ' workers=N61:FRESH'
    contains 'past the deadline the stall probe is skipped and stall= reads ? with no cache' "$pr_hung" ' stall=?'
    [ ! -e "$W/pr-hung-stall.ran" ] && pass 'past the deadline the stall probe never ran' || fail 'the stall probe ran past the deadline'
else
    skip 'hung gh list rows: no timeout binary'
fi
contains '--verbose names unowned PRs' "$(STUB_PR_ROWS="$rows_5542" bash "$SUT" --verbose)" 'unowned-prs: #3002:125m'
# --- an orphan PR with a failed check is dispatch-owed: red CI has no other owner.
# The 7th gh row field is the failed-check count; a pending/green orphan, an owned
# red PR and a red draft keep today's output.
rows_6358="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\\n' \
    3011 feat/himmel-991-red-orphan false me false "$(iso_ago 125)" 1 \
    3012 feat/himmel-992-pending-orphan false me false "$(iso_ago 125)" 0 \
    3013 feat/himmel-111-red-owned false me false "$(iso_ago 125)" 2 \
    3014 feat/himmel-993-red-draft true me false "$(iso_ago 125)" 1)"
red_out="$(STUB_PR_ROWS="$rows_6358" bash "$SUT")"
contains 'an orphan PR with a failed check is dispatch-owed (HIMMEL-6358)' "$red_out" '#3011:125m:dispatch-owed'
contains 'a pending or green orphan stays a plain unowned PR' "$red_out" '#3012:125m '
not_contains 'a pending or green orphan is not dispatch-owed' "$red_out" '#3012:125m:dispatch-owed'
not_contains 'a red PR owned by a held lock is not flagged' "$red_out" '#3013:'
not_contains 'a red draft is not flagged' "$red_out" '#3014:'
contains '--verbose names the dispatch-owed PR' "$(STUB_PR_ROWS="$rows_6358" bash "$SUT" --verbose)" 'unowned-prs: #3011:125m:dispatch-owed'
mkdir -p "$W/cloudbucket"
printf '%s\n' '# chief' > "$W/cloudbucket/chief.md"
printf '%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S)" HIMMEL-999 session_x 'claude --teleport session_x' > "$W/cloudbucket/cloud-sessions.tsv"
cloud_own_out="$(STUB_PR_ROWS="$rows_5542" bash "$SUT" --doc "$W/cloudbucket/chief.md")"
not_contains 'a PR whose ticket has a live cloud session is not unowned' "$cloud_own_out" '#3002:'

# --- a comma-separated --workers is equivalent to space-separated -
# `for worker in $WORKERS` word-splits on IFS whitespace only, so a comma-joined
# value used to be one iteration over one nonexistent path -- the label was
# derived from the tail of the whole blob, and every worker but the last vanished
# from workers=/tails= while being reported as a single false MISSING. RED
# control (pre-fix tick.sh, this same two-worker fixture): the comma form printed
# 'workers=N61.md,N65:MISSING' (one collapsed entry) while the space form printed
# the correct 'workers=N61:FRESH,N65:FREE' -- confirmed manually against
# scripts/handover/chief-kit/tick.sh@8fa186e5 before this fix.
comma_out="$(bash "$SUT" --workers 'HIMMEL-111-legN61,HIMMEL-222-legN65')"; comma_rc=$?
space_out="$(bash "$SUT" --workers 'HIMMEL-111-legN61 HIMMEL-222-legN65')"; space_rc=$?
if [ "$comma_rc" -eq 0 ] && [ "$space_rc" -eq 0 ] && [ "$comma_out" = "$space_out" ]; then
    pass 'a comma-separated --workers produces byte-identical output to space-separated (HIMMEL-3130)'
else
    fail "comma vs space --workers mismatch (comma='$comma_out' space='$space_out')"
fi
contains 'the comma-separated form resolves every worker, not just the last (HIMMEL-3130)' "$comma_out" 'workers=N61:FRESH,N65:FREE'

# workers= must never silently disagree with how
# many docs --workers named -- the original bug's contradiction was workers= naming
# ONE worker while procs= (a separately-scanned live table) reported more
# processes alive, with nothing reconciling the two. Assert the worker-entry
# count against the docs actually passed, independent of the process table.
workers_field="$(printf '%s\n' "$comma_out" | grep -oE 'workers=[^ ]+' | cut -d= -f2)"
workers_count="$(printf '%s\n' "$workers_field" | awk -F',' '{print NF}')"
if [ "$workers_count" = 2 ]; then
    pass 'workers= names exactly as many entries as --workers docs were passed (HIMMEL-3130)'
else
    fail "workers= entry count mismatch (workers_field='$workers_field' count=$workers_count, expected 2)"
fi

# --- --workers-from <fleet manifest> ------------------------------
# The chief's worker set lives in one JSON file (fleet-manifest.sh writes it);
# tick reads it on every run, so a dispatch or wrap edits the file and the
# waiter needs no restart. RED control (tick.sh before this change): every
# --workers-from run below exited 2 with the usage text (unknown option).
fm="$W/handover/chief.fleet.json"
fm_n61="$W/handover/HIMMEL-111-legN61.md"
fm_n65="$W/handover/HIMMEL-222-legN65.md"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61"},{"doc":"%s","label":"N65"}]}\n' "$fm_n61" "$fm_n65" > "$fm"
from_out="$(WORKERS='' bash "$SUT" --workers-from "$fm")"; from_rc=$?
argv_out="$(WORKERS='' bash "$SUT" --workers "$fm_n61 $fm_n65")"; argv_rc=$?
if [ "$from_rc" -eq 0 ] && [ "$argv_rc" -eq 0 ] && [ "$from_out" = "$argv_out" ]; then
    pass '--workers-from a manifest produces byte-identical output to the equivalent --workers (HIMMEL-3748)'
else
    fail "--workers-from vs --workers mismatch (rc=$from_rc/$argv_rc from='$from_out' argv='$argv_out')"
fi
contains '--workers-from resolves every manifest worker (HIMMEL-3748)' "$from_out" ' workers=N61:FRESH,N65:FREE '
# The manifest is re-read on every run: editing it between two samples changes
# the judged worker set with the same argv -- no waiter restart.
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61"}]}\n' "$fm_n61" > "$fm"
contains 'a manifest edit between two runs changes workers= with the same argv (HIMMEL-3748)' \
    "$(WORKERS='' bash "$SUT" --workers-from "$fm")" ' workers=N61:FRESH '
# A worker on both --workers and the manifest is judged once, not twice.
contains '--workers and --workers-from union without duplicates (HIMMEL-3748)' \
    "$(WORKERS='' bash "$SUT" --workers "$fm_n61 $fm_n65" --workers-from "$fm")" ' workers=N61:FRESH,N65:FREE '
# The same doc spelled relative on --workers and absolute in the manifest is one worker.
contains 'a relative --workers spelling and its absolute manifest entry are judged once (HIMMEL-3748)' \
    "$(WORKERS='' bash "$SUT" --workers HIMMEL-111-legN61 --workers-from "$fm")" ' workers=N61:FRESH '
# An unreadable or invalid manifest is a failed tick (no TICK line, rc != 0),
# never an empty fleet that reads as every worker gone.
printf 'not json\n' > "$fm"
bad_out="$(WORKERS='' bash "$SUT" --workers-from "$fm" 2>/dev/null)"; bad_rc=$?
if [ "$bad_rc" -ne 0 ] && [ -z "$bad_out" ]; then
    pass 'an invalid manifest fails the tick instead of reading as no workers (HIMMEL-3748)'
else
    fail "invalid manifest (rc=$bad_rc out='$bad_out')"
fi
miss_out="$(WORKERS='' bash "$SUT" --workers-from "$W/handover/no-such.fleet.json" 2>/dev/null)"; miss_rc=$?
if [ "$miss_rc" -ne 0 ] && [ -z "$miss_out" ]; then
    pass 'a missing manifest fails the tick (HIMMEL-3748)'
else
    fail "missing manifest (rc=$miss_rc out='$miss_out')"
fi
rm -f "$fm"

# --- a lockless (eval/pilot) manifest row reads NOLOCK, not FREE,
# and is judged by its tail marker alone. RED control (tick.sh before this
# change): the lockless row below read workers=...P01:FREE, and an unstamped
# `- WRAPPED —` bullet moved nothing in workers=. (The parser already read the
# unstamped marker; tails= is pinned here so it cannot regress.)
lk_doc="$W/handover/HIMMEL-4869-N90-pilot.md"
printf '%s\n' '# pilot row' '- LIVE — working' > "$lk_doc"
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61","lane":"native"},{"doc":"%s","label":"N90","lane":"deepseek","lockless":true}]}\n' "$fm_n61" "$lk_doc" > "$fm"
lk_out="$(WORKERS='' bash "$SUT" --workers-from "$fm")"
contains 'a lockless row reads NOLOCK, never FREE (HIMMEL-5074)' "$lk_out" ' workers=N61:FRESH,N90:NOLOCK '
contains 'a lockless row is judged by its tail marker (HIMMEL-5074)' "$lk_out" ' tails=N61:LIVE,N90:LIVE '
printf '%s\n' '- WRAPPED — done, no stamp' >> "$lk_doc"
lk_out2="$(WORKERS='' bash "$SUT" --workers-from "$fm")"
contains 'an unstamped WRAPPED on a lockless row changes tails= (HIMMEL-5074)' "$lk_out2" ' tails=N61:LIVE,N90:WRAPPED '
contains 'a wrapped lockless row stays NOLOCK, not FREE or WRAPPED-lock (HIMMEL-5074)' "$lk_out2" ' workers=N61:FRESH,N90:NOLOCK '
# A manifest row with no lockless key keeps its FREE verdict.
printf '{"schema":1,"legs":[{"doc":"%s","label":"N61"},{"doc":"%s","label":"N90","lane":"deepseek"}]}\n' "$fm_n61" "$lk_doc" > "$fm"
contains 'a row without the lockless key is still judged by its lock (HIMMEL-5074)' "$(WORKERS='' bash "$SUT" --workers-from "$fm")" ' workers=N61:FRESH,N90:WRAPPED '
rm -f "$fm" "$lk_doc"

# --- livestate= drift field --------------------------------
# workers=N61:FRESH,N65:FREE above -- only N61 is actually held (the stub
# queue-lock only reports FRESH for a doc path containing "N61"). Each
# sub-case below rewrites $W/handover/chief.md's `## Live state` section
# and re-runs the same --workers pair, so only the doc content changes between
# assertions.
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N61:nonce-ok:tok-ok:111`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
ok_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=ok run exits 0'; else fail "livestate=ok run exits 0 (rc=$rc)"; fi
contains 'Live state agreeing with held locks reports ok' "$ok_out" 'livestate=ok'

# Naming ONLY N65 here also makes N61 (the actually held lock) go unnamed --
# both directions of the mismatch fire at once, so the drift list is BOTH
# workers, sorted, not N65 alone.
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N65:nonce-stale:tok-stale:222`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
named_not_held_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=DRIFT (named, not held) run exits 0'; else fail "livestate=DRIFT (named, not held) run exits 0 (rc=$rc)"; fi
contains 'Live state naming a worker with no held lock is DRIFT' "$named_not_held_out" 'livestate=DRIFT:N61,N65'

printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: none' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
held_not_named_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=DRIFT (held, not named) run exits 0'; else fail "livestate=DRIFT (held, not named) run exits 0 (rc=$rc)"; fi
contains 'a held lock absent from Live state is DRIFT' "$held_not_named_out" 'livestate=DRIFT:N61'

printf '%s\n' '# chief' '' 'no Live state section in this doc at all' > "$W/handover/chief.md"
no_section_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=unknown run exits 0'; else fail "livestate=unknown run exits 0 (rc=$rc)"; fi
contains 'a doc with no Live state section reports unknown, not ok' "$no_section_out" 'livestate=unknown'

# --- nonces=<ok|RELAYED|UNCONFIRMED> -----------------------------
# A HELD worker whose Live-state nonce still carries a PREVIOUS chief's letter
# prefix (nonce shape `<LETTER>-<worker>-<hex>`; the letter is the chief doc's
# own, parsed from `<prefix>-nextleg-<date><LETTER>-<name>.md`) is not rotated.
# That is a VALID state -- a relay may keep the worker's token -- so the worker's own
# handover doc decides: a `SUCCESSION accepted:` Results bullet naming this
# chief = RELAYED, none = UNCONFIRMED. Only N61 is held (stub above).
kdoc="$W/handover/HIMMEL-nextleg-2026-09-20K-chief.md"
n61doc="$W/handover/HIMMEL-111-legN61.md"
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:J-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
unconfirmed_out="$(DOC="$kdoc" bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'nonces=UNCONFIRMED run exits 0'; else fail "nonces=UNCONFIRMED run exits 0 (rc=$rc)"; fi
contains 'a held worker on the predecessor J prefix with no acceptance bullet is UNCONFIRMED under chief K' "$unconfirmed_out" 'nonces=UNCONFIRMED:N61'
contains '--verbose labels the nonce census' "$(DOC="$kdoc" bash "$SUT" --verbose)" 'nonces: UNCONFIRMED:N61'
case "$unconfirmed_out" in
    *STRANDED*) fail 'the field never asserts STRANDED: it cannot observe that' ;;
    *) pass 'the field never asserts STRANDED: it cannot observe that' ;;
esac

# The state that occurs in practice: the outgoing chief relayed the worker
# WITHOUT rotating its token, and the worker accepted and wrote its bullet. The
# Live-state nonce still carries J, and that is correct -- not an incident.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '- LIVE — working' '## Results (newest at the bottom)' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' > "$n61doc"
relayed_out="$(DOC="$kdoc" bash "$SUT")"
contains 'an unrotated worker that accepted this chief reads nonces=RELAYED (relay without rotation is valid)' "$relayed_out" 'nonces=RELAYED:N61'
case "$relayed_out" in
    *UNCONFIRMED*|*STRANDED*) fail 'an unrotated worker that accepted this chief must not read as an incident' ;;
    *) pass 'an unrotated worker that accepted this chief must not read as an incident' ;;
esac
contains 'the tails census is unchanged by the acceptance bullet' "$relayed_out" 'tails=N61:LIVE'

# A bullet that names ANOTHER chief does not confirm THIS one.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '- LIVE — working' '## Results' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-19J-chief` replaces `HIMMEL-nextleg-2026-09-18I-chief`' > "$n61doc"
contains 'an acceptance bullet naming a different chief does not confirm this one' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# Only the INCOMING session counts: a worker that accepted a LATER chief L (which
# replaces K) names K after `replaces`, and that must not confirm K.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '- LIVE — working' '## Results' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20L-chief` replaces `HIMMEL-nextleg-2026-09-20K-chief`' > "$n61doc"
contains 'a stem after the word replaces is the OUTGOING chief and confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# The LATEST acceptance wins: accepted K, then moved on to L -> not K's worker.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '- LIVE — working' '## Results' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' \
    '- 05:02 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20L-chief` replaces `HIMMEL-nextleg-2026-09-20K-chief`' > "$n61doc"
contains 'a later acceptance of another chief supersedes an earlier one' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# A handover root whose path contains a space keeps its worker doc whole.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '- LIVE — working' '## Results' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' > "$n61doc"
ln -s "$W/handover" "$W/hand over"
contains 'a worker doc path containing a space is read whole (RELAYED, not UNCONFIRMED)' "$(HANDOVER_DIR="$W/hand over" DOC="$kdoc" bash "$SUT")" 'nonces=RELAYED:N61'
rm -f "$W/hand over"

# Prose that merely mentions the phrase (not a Results bullet) confirms nothing.
printf '%s\n' '# worker' '- LIVE — working' '## Results' \
    'note: SUCCESSION accepted: HIMMEL-nextleg-2026-09-20K-chief replaces J (prose, not a bullet)' > "$n61doc"
contains 'a non-bullet line mentioning SUCCESSION accepted confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'
# only the worker doc's `## Results` section is read. An
# acceptance-shaped bullet quoted ABOVE Results (e.g. an example in a brief)
# naming this chief must not upgrade UNCONFIRMED to RELAYED, and neither
# must one under a later `## ` section.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '## Brief' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' \
    '## Results (newest at the bottom)' '- LIVE — working' > "$n61doc"
contains 'an acceptance bullet above ## Results confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '## Results' '- LIVE — working' '## Notes' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' > "$n61doc"
contains 'an acceptance bullet under a section after ## Results confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# worker' '## ResultsArchive' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-chief` replaces `HIMMEL-nextleg-2026-09-19J-chief`' > "$n61doc"
contains 'a heading that merely starts with Results is not the Results section' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'
printf '%s\n' '# worker' '- LIVE — working' > "$n61doc"

# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:K-N61-9f8e7d:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
rotated_out="$(DOC="$kdoc" bash "$SUT")"
not_contains 'a held worker rotated onto the K prefix omits healthy nonces=' "$rotated_out" 'nonces='
case "$rotated_out" in
    *UNCONFIRMED*|*RELAYED*|*STRANDED*) fail 'a rotated worker reports neither UNCONFIRMED nor RELAYED' ;;
    *) pass 'a rotated worker reports neither UNCONFIRMED nor RELAYED' ;;
esac

# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:K-N61-9f8e7d:tok-61:111`, `N65:J-N65-aa11bb:tok-65:222`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
not_contains 'a wrapped (FREE-lock) worker on an old prefix is not flagged -- nothing to rotate' "$(DOC="$kdoc" bash "$SUT")" 'nonces='

# `AA` must not read as a prefix of `A`: the boundary is the dash.
aadoc="$W/handover/HIMMEL-nextleg-2026-09-20AA-chief.md"
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# AA' '' '## Live state' '' \
    'legs: `N61:A-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$aadoc"
contains 'letter A is not letter AA (prefix boundary is the dash)' "$(DOC="$aadoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# A doc whose name carries no chief letter cannot be judged: unknown, never a guess.
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N61:J-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$W/handover/chief.md"
contains 'a chief doc name with no parseable letter reads nonces=unknown' "$(bash "$SUT")" 'nonces=unknown'

rm -f "$W/handover/chief.md" "$kdoc" "$aadoc"

# #1335: /proc absent (CLAUDE_SESSIONS_PROC pointing nowhere) falls
# back to `pgrep -x claude` (bare pids) + `ps -o pid=,args= -p <pids>` (full
# argv), the BSD-safe replacement for the old GNU-only `pgrep -af` scan. The
# stubs are shaped like the REAL binaries -- pgrep prints only bare pids for
# `-x claude` (BSD pgrep's `-a` means "include ancestors", not "print args",
# so a stub (or a real macOS box) that still expected `-af` to hand back full
# argv lines would silently produce zero rows here, exactly the reported
# bug). A `(lossy)` suffix still flags the degraded read on models=.
mkdir -p "$W/bin-lossy"
mk_pgrep_x "$W/bin-lossy" 101 102 103
cat > "$W/bin-lossy/ps" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-ww -o pid=,args= -p "*)
    printf '%s\n' \
      '101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61 work' \
      '102 claude --model claude-opus-5 --autocompact 200000 -n LUNA-222-legN9 work' \
      '103 claude --model claude-sonnet-5 -n HIMMEL-next-chief work'
    ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$W/bin-lossy/ps"
lossy_out="$(CLAUDE_SESSIONS_PROC="$W/no-such-proc" PATH="$W/bin-lossy:$PATH" bash "$SUT")"
contains 'the /proc-absent fallback still counts the dispatched worker (HIMMEL-3145)' "$lossy_out" 'procs=1'
contains 'the /proc-absent fallback flags the degraded read' "$lossy_out" 'models=sonnet:1(lossy)'
not_contains 'the /proc-absent fallback omits healthy ceiling=' "$lossy_out" 'ceiling='

# #1335 (ticket cause a): a chief managing a DIFFERENT repo exports
# REPO as that repo's checkout -- tick.sh must still resolve
# claude-sessions.sh from its OWN directory, not $REPO, or the source fails
# (claude_sessions: command not found) and the census silently reads as a
# scan failure on every repo but himmel's own. This fixture deliberately has
# no scripts/lanes/lib/ at all.
mkdir -p "$W/foreign-repo/scripts/handover" "$W/foreign-repo/scripts/lib" "$W/foreign-repo/scripts/lanes"
cp "$W/repo/scripts/handover/queue-lock.sh" "$W/foreign-repo/scripts/handover/queue-lock.sh"
cp "$W/repo/scripts/context-fill.sh" "$W/foreign-repo/scripts/context-fill.sh"
cp "$W/repo/scripts/lanes/worker-burn.sh" "$W/foreign-repo/scripts/lanes/worker-burn.sh"
cp "$W/repo/scripts/lib/usage-preflight.sh" "$W/foreign-repo/scripts/lib/usage-preflight.sh"
# every chokepoint fails closed without its seam-guard lib.
cp "$W/repo/scripts/lib/chokepoint-seam-guard.sh" "$W/foreign-repo/scripts/lib/chokepoint-seam-guard.sh"
foreign_out="$(REPO="$W/foreign-repo" PATH="$W/bin:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61')"
contains 'a foreign REPO (no scripts/lanes/lib/) still counts a live worker (#1335)' "$foreign_out" 'procs=1'
contains 'a foreign REPO still buckets its model' "$foreign_out" 'models=sonnet:1'
case "$foreign_out" in
    *procs=unknown*) fail 'a foreign REPO does not fall back to procs=unknown' ;;
    *) pass 'a foreign REPO does not fall back to procs=unknown' ;;
esac

# #1335 (ticket cause c): with no --workers armed at all, a census that
# cannot run (pgrep itself broken, not merely lossy) must not render the
# same workers=none a genuinely healthy empty fleet gets -- there is no way to
# back up "no workers" when the instrument that would have caught an unarmed
# live worker cannot run in the first place.
mkdir -p "$W/bin-nopgrep"
cat > "$W/bin-nopgrep/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$W/bin-nopgrep/pgrep"
unsupported_out="$(CLAUDE_SESSIONS_PROC="$W/no-such-proc" PATH="$W/bin-nopgrep:$PATH" bash "$SUT" --workers '')"
contains 'no working census + no --workers reads workers=unsupported, not workers=none (#1335)' "$unsupported_out" 'workers=unsupported'
case "$unsupported_out" in
    *' workers=none '*) fail 'workers=none is not reused for an unsupported census' ;;
    *) pass 'workers=none is not reused for an unsupported census' ;;
esac

# The healthy empty-fleet workers=none meaning is unchanged: no --workers, and the
# census runs fine (finds nothing to contradict it).
healthy_empty_out="$(bash "$SUT" --workers '')"
contains 'a healthy, census-confirmed empty fleet still reads workers=none' "$healthy_empty_out" 'workers=none'

# a worker process matched by the worker filter
# but with no --model token at all must still show up (an "unknown" bucket),
# never silently fall out of every bucket while still counted in procs=.
mkcmdline 104 claude -n HIMMEL-444-legN70 work
mk_pgrep_x "$W/bin-nomodel" 101 104
nomodel_out="$(PATH="$W/bin-nomodel:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61 HIMMEL-444-legN70')"
contains 'a worker with no --model token buckets as unknown, not dropped' "$nomodel_out" 'models=sonnet:1,unknown:1'

# a --profile worker's argv carries `--settings
# /run/user/1000/himmel-chief/<slug>/<name>.leg-settings.json` — the path
# segment "himmel-chief" contains the substring "-chief", which the old
# `!/-chief/` exclusion matched against the WHOLE line rather than just the
# chief's own `-n <name>` token, silently dropping every --profile worker from
# both procs= and models=. Real argv boundaries make this a non-issue by
# construction: NAME comes only from the token immediately after "-n".
mkcmdline 105 claude --settings /run/user/1000/himmel-chief/x/y.leg-settings.json \
    --append-system-prompt-file /run/user/1000/himmel-chief/x/worker-preface.md \
    --model claude-sonnet-5 -n HIMMEL-333-foo-legN7-2026-01-01 work
mk_pgrep_x "$W/bin-profile" 103 105
profile_out="$(PATH="$W/bin-profile:$PATH" bash "$SUT" --workers 'HIMMEL-333-foo-legN7-2026-01-01')"
contains 'a --profile worker is counted in procs= (HIMMEL-2998)' "$profile_out" 'procs=1'
contains 'a --profile worker is bucketed in models= (HIMMEL-2998)' "$profile_out" 'models=sonnet:1'

# a worker whose --autocompact drifted from 200000 surfaces in
# ceiling= without disturbing procs=/models=.
mkcmdline 106 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-111-legN61 work
mk_pgrep_x "$W/bin-drift" 106
drift_out="$(PATH="$W/bin-drift:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61')"
contains 'a drifted worker surfaces in ceiling= (HIMMEL-2974)' "$drift_out" 'ceiling=DRIFT:HIMMEL-111-legN61'

# A single real chief session whose
# free-text -p value contains an embedded newline plus the literal word
# "claude" and a fake "-n HIMMEL-999-fake-legN1-2026-01-01" must NOT be
# counted. Pre-fix, `pgrep -af` prints this one process's argv across two
# text lines (the embedded newline survives byte-for-byte); awk then
# evaluates the four procs= conditions per LINE, so the fake fragment lands
# in a second "record" that independently satisfies all four -- the real
# session's own "-n ...-chief" flag, sitting in the FIRST record, never
# gets a chance to veto it. Real argv has no such record boundary: the whole
# -p value is one NUL-delimited element, so "-n" from the free text is never
# an isolated token equal to the literal flag.
mkcmdline 107 claude --model claude-sonnet-5 --autocompact auto \
    -n HIMMEL-nextleg-2026-09-13Z-chief \
    -p "$(printf 'spoof\nclaude -n HIMMEL-999-fake-legN1-2026-01-01 more work')"
mk_pgrep_x "$W/bin-spoof" 107
spoof_out="$(PATH="$W/bin-spoof:$PATH" bash "$SUT" --workers 'HIMMEL-999-fake-legN1-2026-01-01')"
not_contains 'a spoofed -n inside free-text argv is not counted (HIMMEL-2999)' "$spoof_out" 'procs='
not_contains 'a spoofed -n inside free-text argv does not bucket a model (HIMMEL-2999)' "$spoof_out" 'models='

# a pid pgrep reports that has already vanished by the time
# claude_sessions() reads it (no /proc/<pid> dir at all) is "not a tracked
# session" -- no row, no effect on procs=/ceiling= -- pinning the pre-fix
# behaviour for a genuinely gone process.
mk_pgrep_x "$W/bin-vanished" 101 999
vanished_out="$(PATH="$W/bin-vanished:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61')"
contains 'a vanished pid (no /proc dir) does not affect procs=' "$vanished_out" 'procs=1'
case "$vanished_out" in
    *unreadable*) fail 'a vanished pid does not report unreadable=' ;;
    *) pass 'a vanished pid does not report unreadable=' ;;
esac

# an alive pid whose /proc/<pid> dir exists but whose cmdline is
# unreadable (a permission boundary, e.g. hidepid) must not be silently
# treated as vanished -- tick.sh surfaces it as unreadable=<n> appended to
# procs= so the chief sees the scan is degraded, not a clean complete count.
if [ "$(id -u)" = "0" ]; then
    printf 'SKIP - unreadable-cmdline case cannot be simulated as root (chmod 000 is still readable to root)\n'
else
    mkcmdline 199 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-888-legN102 work
    chmod 000 "$W/proc/199/cmdline"
    if [ -r "$W/proc/199/cmdline" ]; then
        printf 'SKIP - unreadable-cmdline case: chmod 000 did not remove read access here\n'
        chmod 700 "$W/proc/199/cmdline"
    else
        mk_pgrep_x "$W/bin-unreadable" 101 199
        unreadable_out="$(PATH="$W/bin-unreadable:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61')"
        contains 'an unreadable cmdline is surfaced as unreadable= in procs= (HIMMEL-3002)' "$unreadable_out" 'procs=1,unreadable=1'
        chmod 700 "$W/proc/199/cmdline"
    fi
fi

rm -f "$W/handover/HIMMEL-222-legN65.md"
out="$(FILL_STALE=1 bash "$SUT" --workers 'HIMMEL-111-legN61 HIMMEL-333-legN66' 2>"$W/notfound-stderr.txt")"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass 'missing worker document is tolerated'
else
    fail "missing worker document is tolerated (rc=$rc)"
fi
# an unresolvable --workers entry is NOTFOUND, never MISSING --
# MISSING is reserved for a lock that is genuinely gone, which a chief
# reads as "reclaim this worker's lock". RED control (pre-fix tick.sh, same
# fixture): stdout printed 'workers=N61:FRESH,N66:MISSING' with an EMPTY stderr
# -- a bare, unwarned MISSING for a typo'd/unresolvable doc.
contains 'unresolvable worker has NOTFOUND, not MISSING, as its lock status' "$out" 'workers=N61:FRESH,N66:NOTFOUND'
contains 'unresolvable worker has an explicit tail status' "$out" 'tails=N61:LIVE,N66:?'
contains 'an unresolvable worker doc emits a named warning on stderr' "$(cat "$W/notfound-stderr.txt")" 'tick: no such leg doc:'
case "$out" in *MISSING*) fail 'an unresolvable worker doc never prints bare MISSING' ;; *) pass 'an unresolvable worker doc never prints bare MISSING' ;; esac
contains 'context-fill rc=3 becomes unknown' "$out" 'fill=?'
case "$out" in *FILL_RC*) fail 'context-fill failure does not print FILL_RC chatter' ;; *) pass 'context-fill failure does not print FILL_RC chatter' ;; esac
missing_lines="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
if [ "$missing_lines" = 1 ]; then pass 'degraded run still emits one line'; else fail "degraded run emitted $missing_lines lines"; fi

# --- --burn is opt-in and additive --------------------------
# The whole point of the flag is that chiefs which already parse the tick
# line keep parsing it, so the no-flag case above is the real assertion and
# these three only pin what --burn adds.
burn_out="$(bash "$SUT" --burn --workers 'HIMMEL-111-legN61 HIMMEL-333-legN66')"; rc=$?
if [ "$rc" -eq 0 ]; then pass '--burn exits 0'; else fail "--burn exits 0 (rc=$rc)"; fi
contains '--burn appends first-turn/avg-ctx per worker' "$burn_out" 'burn=N61:74.3k/128.1k,N66:?'
burn_lines="$(printf '%s\n' "$burn_out" | wc -l | tr -d '[:space:]')"
if [ "$burn_lines" = 1 ]; then pass '--burn still emits one line'; else fail "--burn emitted $burn_lines lines"; fi

# A worker with no transcript must degrade to "?", never abort the tick: an armed
# worker that has not spoken yet is the normal case on the first tick after arming.
case "$burn_out" in *'no transcript found'*) fail '--burn leaks worker-burn stderr into the tick line' ;; *) pass '--burn keeps worker-burn stderr out of the line' ;; esac

# And without the flag the field is absent entirely, not empty.
noburn_out="$(bash "$SUT" --workers 'HIMMEL-111-legN61')"
case "$noburn_out" in *burn=*) fail 'burn= appears without --burn' ;; *) pass 'burn= is absent without --burn' ;; esac

# A worker past its cost budget carries !SOFT / !HARD on its burn token; one under it,
# or whose worker-burn line has no cost-eq, keeps the plain token.
budget_out="$(bash "$SUT" --burn --workers 'HIMMEL-111-legN61 HIMMEL-777-legN77 HIMMEL-888-legN88')"
contains '--burn marks a worker past the soft cost budget' "$budget_out" 'N77:32.3k/100.0k!SOFT'
contains '--burn marks a worker past the hard cost budget' "$budget_out" 'N88:32.3k/106.0k!HARD'
contains '--burn leaves a worker with no cost-eq unmarked' "$budget_out" 'N61:74.3k/128.1k,'
case "$noburn_out" in *'!SOFT'*|*'!HARD'*) fail 'a budget mark appears without --burn' ;; *) pass 'no budget mark without --burn' ;; esac
contains '--verbose --burn labels the burn line' "$(bash "$SUT" --verbose --burn --workers 'HIMMEL-111-legN61')" 'worker-session burn (first-turn/avg-ctx): N61:74.3k/128.1k'

# --- current-convention worker names (<TICKET>-N<k>-<slug>, no
# "-worker" substring at all -- docs/handover/chief-template.md:104 is the
# contract every chief writes) must resolve/count/compare
# identically to the legacy -legN<k> spelling. This fixture is the ticket's
# own RED control: two live
# workers named this way used to report procs=0 models=none and an
# unconditional livestate=DRIFT naming every worker twice -- confirmed against
# scripts/handover/chief-kit/tick.sh@6ac483e4 before this fix.
mkcmdline 110 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3144-N1-chief-idle-guard work
mkcmdline 111 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3143-N2-merge-jira-optin work
mk_pgrep_x "$W/bin-conv" 110 111
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/HIMMEL-3144-N1-chief-idle-guard.md"
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/HIMMEL-3143-N2-merge-jira-optin.md"
# shellcheck disable=SC2016  # backtick worker span, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N1:nonce1:tok1:110`, `N2:nonce2:tok2:111`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
conv_out="$(PATH="$W/bin-conv:$PATH" bash "$SUT" --workers 'HIMMEL-3144-N1-chief-idle-guard HIMMEL-3143-N2-merge-jira-optin')"
contains 'a current-convention worker label resolves to N<k> (HIMMEL-3145)' "$conv_out" 'workers=N1:FRESH,N2:FRESH'
contains 'current-convention workers are counted in procs= (HIMMEL-3145)' "$conv_out" 'procs=2'
contains 'current-convention workers are bucketed in models= (HIMMEL-3145)' "$conv_out" 'models=sonnet:2'
contains 'current-convention workers compare like-with-like in livestate= (HIMMEL-3145)' "$conv_out" 'livestate=ok'
case "$conv_out" in
    *DRIFT*) fail 'a current-convention worker must not report livestate=DRIFT (HIMMEL-3145)' ;;
    *) pass 'a current-convention worker must not report livestate=DRIFT (HIMMEL-3145)' ;;
esac

# Legacy regression (ticket acceptance): an archived chief doc named in the
# OLD -legN<k>- spelling still resolves to N<k> -- worker_label() must recognise
# both spellings in the same namespace, not just the new one.
legacy_out="$(bash "$SUT" --workers 'HIMMEL-3064-legN12-old-chief-format' 2>/dev/null)"
contains 'a legacy -legN<k>- doc still resolves to N<k> (HIMMEL-3145 regression)' "$legacy_out" 'workers=N12:NOTFOUND'

# --- (ticket root cause 3 / acceptance): a field that cannot be
# computed must say so. A fatal census scan (pgrep itself failing, rc>1 and
# not the degraded-scan rc=3) discards the whole session table --
# procs=/models= must report "unknown", never a clean "0"/"none" that reads
# as "no workers are running" when the truth is "the scan itself broke".
mkdir -p "$W/bin-census-fail"
cat > "$W/bin-census-fail/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$W/bin-census-fail/pgrep"
census_fail_out="$(PATH="$W/bin-census-fail:$PATH" bash "$SUT" --workers 'HIMMEL-111-legN61')"
contains 'a fatal census scan reports procs=unknown, not a false procs=0 (HIMMEL-3145)' "$census_fail_out" 'procs=unknown'
contains 'a fatal census scan reports models=unknown, not a false models=none (HIMMEL-3145)' "$census_fail_out" 'models=unknown'
case "$census_fail_out" in
    *'procs=0'*) fail 'a fatal census scan must not render procs=0' ;;
    *) pass 'a fatal census scan must not render procs=0' ;;
esac

# ---: the same "cannot be computed
# must say so" rule applies to an EMPTY dispatch set, not just a broken
# census scan. --workers is optional (usage block, :23) -- with it absent,
# worker_names stays empty and worker_names_wrapped is ",,", so a matched-nothing
# filter would print a clean "0" (index(",,", ","name",") is always 0,
# since the needle is longer than the haystack) even while the default
# fixture's two workers are live in the session table. procs=0 is only true
# when there IS a dispatch set and it is empty of matches, never when there
# is no dispatch set to check against.
no_workers_out="$(WORKERS='' bash "$SUT")"
contains 'no --workers reports procs=unknown, not a false procs=0 (HIMMEL-3145)' "$no_workers_out" 'procs=unknown'
contains 'no --workers reports models=unknown, not a false models=none (HIMMEL-3145)' "$no_workers_out" 'models=unknown'
case "$no_workers_out" in
    *'procs=0'*) fail 'no --workers must not render procs=0' ;;
    *) pass 'no --workers must not render procs=0' ;;
esac

# --- fleet=<live>/<cap> + capacity= ------------------------------
# fleet= is usage-preflight.sh's own census (its FLEET total=n/cap line), never a
# second count. capacity=UNDERFILLED:<slack> fires when live < cap AND no worker has
# launched for TICK_UNDERFILL_MIN (default 10) minutes, judged by the newest
# <name>.launch.log mtime under the chief work dir.
launch_log="$W/chief-work/chain/HIMMEL-9-N1-x.launch.log"
: > "$launch_log"; touch -d '2 hours ago' "$launch_log"
old_out="$(bash "$SUT")"
contains 'fleet=<live>/<cap> comes from the bank-preflight census (HIMMEL-3167)' "$old_out" 'fleet=1/8'
contains 'live < cap and an old last dispatch is UNDERFILLED:<slack> (HIMMEL-3167)' "$old_out" 'capacity=UNDERFILLED:7'
: > "$launch_log"
fresh_out="$(bash "$SUT")"
contains 'a fresh dispatch reads capacity=ok (HIMMEL-3167 control)' "$fresh_out" 'fleet=1/8 capacity=ok'
touch -d '2 hours ago' "$launch_log"
tuned_out="$(TICK_UNDERFILL_MIN=180 bash "$SUT")"
contains 'TICK_UNDERFILL_MIN moves the threshold (HIMMEL-3167)' "$tuned_out" 'capacity=ok'
bad_min_out="$(TICK_UNDERFILL_MIN=abc bash "$SUT")"
contains 'a non-numeric TICK_UNDERFILL_MIN falls back to 10 (HIMMEL-3167)' "$bad_min_out" 'capacity=UNDERFILLED:7'
full_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=8 claudex=0 reserved=0 total=8/8' bash "$SUT")"
contains 'live == cap is never underfilled (HIMMEL-3167)' "$full_out" 'fleet=8/8 capacity=ok'
res_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=6 claudex=1 reserved=1 total=8/8' bash "$SUT")"
contains 'native+claudex+reserved arrive as bank-preflight total (HIMMEL-3167)' "$res_out" 'fleet=8/8'
cap4_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 reserved=0 total=1/4' bash "$SUT")"
contains 'the cap is bank-preflight cap, not a tick constant (HIMMEL-3167)' "$cap4_out" 'fleet=1/4 capacity=UNDERFILLED:3'
fail_out="$(STUB_FLEET_LINE='bank-preflight: FLEET ?/8' bash "$SUT")"
contains 'a failed fleet census reports fleet=? (HIMMEL-3167)' "$fail_out" 'fleet=? capacity=unknown'
case "$fail_out" in
    *'capacity=ok'*|*UNDERFILLED*) fail 'a failed fleet census must not claim ok/UNDERFILLED (HIMMEL-3167)' ;;
    *) pass 'a failed fleet census must not claim ok/UNDERFILLED (HIMMEL-3167)' ;;
esac
mv "$W/repo/scripts/lib/usage-preflight.sh" "$W/usage-preflight.sh.away"
gone_out="$(bash "$SUT")"
contains 'a missing usage-preflight.sh reports fleet=? (HIMMEL-3167)' "$gone_out" 'fleet=? capacity=unknown'
mv "$W/usage-preflight.sh.away" "$W/repo/scripts/lib/usage-preflight.sh"
STUB_PF_SEEN="$W/pf-seen" bash "$SUT" >/dev/null
contains 'tick asks bank-preflight for no ledger row and no launch refusal (HIMMEL-3167)' "$(cat "$W/pf-seen" 2>/dev/null)" 'ledger=/dev/null launch=unset'
rm -f "$launch_log"
none_out="$(bash "$SUT")"
contains 'no launch log at all counts as no recent dispatch (HIMMEL-3167)' "$none_out" 'capacity=UNDERFILLED:7'
mkdir -p "$W/xdg/himmel-chief/chain"
: > "$W/xdg/himmel-chief/chain/HIMMEL-9-N1-x.launch.log"
xdg_out="$(env -u TICK_LAUNCH_DIR XDG_RUNTIME_DIR="$W/xdg" bash "$SUT")"
contains 'the default launch dir is XDG_RUNTIME_DIR/himmel-chief (HIMMEL-3167)' "$xdg_out" 'capacity=ok'
verbose_cap="$(bash "$SUT" --verbose)"
contains '--verbose labels fleet (HIMMEL-3167)' "$verbose_cap" 'fleet: 1/8'
contains '--verbose labels capacity (HIMMEL-3167)' "$verbose_cap" 'capacity: UNDERFILLED:7'
burn_cap="$(bash "$SUT" --burn --workers 'HIMMEL-111-legN61')"
case "$burn_cap" in
    *' burn=N61:'*' fleet=1/8 capacity=UNDERFILLED:7 gql='*) pass 'fleet=/capacity= append after every existing field incl. burn= (HIMMEL-3167)' ;;
    *) fail "fleet=/capacity= not appended last under --burn (out='$burn_cap')" ;;
esac

# --- (3): procs=0 for a live headed worker. headed-arm-worker.sh names the
# session <TICKET>-N<k>-<slug> with NO date, while the worker DOC is
# <TICKET>-N<k>-<slug>-<YYYY-MM-DD>[-RESUME].md; the census filter matched the
# doc stem verbatim, so a live worker read procs=0 (reproduced on N41 itself).
mkcmdline 108 claude --settings /run/user/1000/himmel-chief/x/HIMMEL-555-N41-thing.leg-settings.json \
    --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-555-N41-thing work
mk_pgrep_x "$W/bin-dated" 108
dated_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --workers 'HIMMEL-555-N41-thing-2026-09-18')"
contains 'a date-suffixed worker doc still counts its live session in procs= (HIMMEL-3167)' "$dated_out" 'procs=1'
contains 'a date-suffixed worker doc still buckets its model (HIMMEL-3167)' "$dated_out" 'models=sonnet:1'
dated_resume_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --workers 'HIMMEL-555-N41-thing-2026-09-18-RESUME')"
contains 'a date-suffixed -RESUME doc still counts its live session (HIMMEL-3167)' "$dated_resume_out" 'procs=1'
dated_burn_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --burn --workers 'HIMMEL-555-N41-thing-2026-09-18')"
contains 'a date-suffixed worker doc still resolves its --burn transcript (HIMMEL-3167)' "$dated_burn_out" 'burn=N41:60.0k/90.0k'

# --- gql=<remaining>/<reset HH:MM> ----------------------------------
qd() { rm -rf "$W/q-$1"; mkdir -p "$W/q-$1"; printf '%s' "$W/q-$1"; }
mkdir -p "$W/noenv"
: > "$W/gh-api.log"
gql_qd="$(qd probe)"
HIMMEL_QUOTA_DIR="$gql_qd" GH_READ_ENV_ROOT="$W/noenv" STUB_GH_API_LOG="$W/gh-api.log" bash "$SUT" >/dev/null
api_calls="$(wc -l < "$W/gh-api.log" | tr -d '[:space:]')"
if [ "$api_calls" = 2 ]; then
    pass 'a tick with no quota.tsv costs one graphql probe and one core probe'
else
    fail "a tick with no quota.tsv must cost two probes (calls=$api_calls)"
fi
contains 'the gql= probe is a real graphql call, not rate_limit (HIMMEL-3197)' "$(cat "$W/gh-api.log")" 'graphql'
not_contains 'no probe is gh api rate_limit' "$(cat "$W/gh-api.log")" 'rate_limit'
: > "$W/gh-api.log"
HIMMEL_QUOTA_DIR="$gql_qd" GH_READ_ENV_ROOT="$W/noenv" STUB_GH_API_LOG="$W/gh-api.log" bash "$SUT" >/dev/null
api_calls="$(wc -l < "$W/gh-api.log" | tr -d '[:space:]')"
if [ "$api_calls" = 0 ]; then
    pass 'a tick under 170 s after the last reading costs no budget call'
else
    fail "a fresh quota.tsv must cost the tick no budget call (calls=$api_calls)"
fi
gql_ex_out="$(HIMMEL_QUOTA_DIR="$(qd ex)" GH_READ_ENV_ROOT="$W/noenv" STUB_GQL_OUT='HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 1790000000\r\n\r\n' STUB_GQL_RC=1 bash "$SUT")"; gql_ex_rc=$?
if [ "$gql_ex_rc" -eq 0 ]; then
    contains 'an exhausted budget (gh exits 1, headers still printed) reads gql=0/<reset> (HIMMEL-3197)' "$gql_ex_out" "gql=0/$gql_hm"
else
    fail "an exhausted budget must not fail the tick (rc=$gql_ex_rc)"
fi
gql_bad_out="$(HIMMEL_QUOTA_DIR="$(qd bad)" GH_READ_ENV_ROOT="$W/noenv" STUB_GQL_OUT='gh: connection refused\n' STUB_GQL_RC=1 bash "$SUT")"; gql_bad_rc=$?
if [ "$gql_bad_rc" -eq 0 ]; then
    contains 'unreadable headers read gql=? and never fail the tick (HIMMEL-3197)' "$gql_bad_out" ' capacity=UNDERFILLED:7 gql=?'
else
    fail "unreadable gql headers must not fail the tick (rc=$gql_bad_rc)"
fi
gql_nores_out="$(HIMMEL_QUOTA_DIR="$(qd nores)" GH_READ_ENV_ROOT="$W/noenv" STUB_GQL_OUT='HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4321\r\n\r\n' bash "$SUT")"
contains 'a missing reset header reads gql=<remaining>/? (HIMMEL-3197)' "$gql_nores_out" 'gql=4321/?'
gql_verbose="$(bash "$SUT" --verbose)"
contains '--verbose labels the graphql budget (HIMMEL-3197)' "$gql_verbose" "gql: 4321/$gql_hm"
gql_burn="$(bash "$SUT" --burn --workers 'HIMMEL-111-legN61')"
case "$gql_burn" in
    *' burn=N61:'*" capacity=UNDERFILLED:7 gql=4321/$gql_hm "*) pass 'gql= keeps its slot under --burn with healthy orphan fields omitted' ;;
    *) fail "gql=/orphans= order under --burn (out='$gql_burn')" ;;
esac

# --- rest-main= / rest-read= ---------------------
mkdir -p "$W/readroot"
printf 'himmel_github_token_vm2=ghp_TICKTEST0123456789\n' > "$W/readroot/.env"  # gitleaks:allow fixture token
seed_rest() {
    local d="$1" main_rem="$2" read_rem="$3" now
    now="$(date +%s)"
    mkdir -p "$d"
    printf 'main\tgraphql\t4321\t5000\t1790000000\t%s\tok\nmain\tcore\t%s\t5000\t1790000000\t%s\tok\nread\tgraphql\t4321\t5000\t1790000000\t%s\tok\nread\tcore\t%s\t5000\t1790000000\t%s\tok\n' \
        "$now" "$main_rem" "$now" "$now" "$read_rem" "$now" > "$d/quota.tsv"
}
seed_rest "$W/q-rest" 4200 450
rest_out="$(HIMMEL_QUOTA_DIR="$W/q-rest" GH_READ_ENV_ROOT="$W/readroot" bash "$SUT")"
contains 'the tick shows the main token budget (HIMMEL-6837)' "$rest_out" " rest-main=4200/5000@$gql_hm"
contains 'a read token at 9 % is flagged LOW (HIMMEL-6837)' "$rest_out" " rest-read=450/5000@$gql_hm!LOW"
rest_v="$(HIMMEL_QUOTA_DIR="$W/q-rest" GH_READ_ENV_ROOT="$W/readroot" bash "$SUT" --verbose)"
contains '--verbose has one line per token, main (HIMMEL-6837)' "$rest_v" "rest main: 4200/5000 reset $gql_hm"
contains '--verbose has one line per token, read with LOW (HIMMEL-6837)' "$rest_v" "rest read: 450/5000 reset $gql_hm LOW"
seed_rest "$W/q-rest-ok" 4200 4000
rest_ok="$(HIMMEL_QUOTA_DIR="$W/q-rest-ok" GH_READ_ENV_ROOT="$W/readroot" bash "$SUT")"
case "$rest_ok" in *LOW*) fail "healthy budgets must not be flagged LOW (out='$rest_ok')" ;; *) pass 'healthy budgets carry no LOW flag (HIMMEL-6837)' ;; esac

# --- orphans=<owner>:<count>/<oldest>m ---------------------------
# A wrapper shell older than the floor under a live session is surfaced at the
# next tick, joined to that session's name (orphan-loops.sh; its own suite pins
# the walk/threshold rules). Appended last, after gql=, so no field moves.
cat > "$W/ps-orphan.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-legN61 work
  201   101    02:10:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'until false; do sleep 10; done'
FIX
orph_out="$(PS_FIXTURE="$W/ps-orphan.txt" bash "$SUT")"; orph_rc=$?
if [ "$orph_rc" -eq 0 ]; then
    contains 'a stale wrapper under a live session surfaces as orphans=<name>:<n>/<m>m, last on the line (HIMMEL-2761)' "$orph_out" " gql=4321/$gql_hm orphans=HIMMEL-111-legN61:1/130m"
else
    fail "an orphan inventory must not fail the tick (rc=$orph_rc)"
fi
contains '--verbose labels the orphan inventory (HIMMEL-2761)' "$(PS_FIXTURE="$W/ps-orphan.txt" bash "$SUT" --verbose)" 'orphans: HIMMEL-111-legN61:1/130m'
: > "$W/ps-empty.txt"
contains 'an unreadable process table reads orphans=? and never fails the tick (HIMMEL-2761)' "$(PS_FIXTURE="$W/ps-empty.txt" bash "$SUT")" ' orphans=?'

# --- one worker identity, used by every tick consumer ---------------
# Names here are the ones the harness really produces, not ones invented to fit
# the parser. Doc = docs/handover/worker-brief-template.md's stated pattern; session
# = the <TICKET>-N<k>-<slug> the chief passes headed-arm-worker.sh (this shift's
# own pair: HIMMEL-3269-N191-scorecard-discovery, HIMMEL-3273-N192-stop-queue-race).
# RED control (pre-fix tick.sh, this fixture): the old-template doc read
# workers=<full stem>:FRESH, procs=0 and livestate=DRIFT with two live, held workers.
l191='HIMMEL-3269-N191-scorecard-discovery-2026-09-20-RESUME'
l192='HIMMEL-3273-stop-queue-race-leg192-2026-09-20-RESUME'
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/$l191.md"
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/$l192.md"
mkcmdline 120 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3269-N191-scorecard-discovery work
mkcmdline 121 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3273-N192-stop-queue-race work
mk_pgrep_x "$W/bin-3277" 120 121
t3277() { PATH="$W/bin-3277:$PATH" bash "$SUT" --workers "$1"; }

# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
o3277="$(t3277 "$l191 $l192")"
contains 'a template-pattern doc and a canonical doc both resolve to N<k> (HIMMEL-3277)' "$o3277" 'workers=N191:FRESH,N192:FRESH'
contains 'both live workers are counted in procs= (HIMMEL-3277)' "$o3277" 'procs=2'
contains 'both live workers are bucketed in models= (HIMMEL-3277)' "$o3277" 'models=sonnet:2'
contains 'a legs: line written per chief-template.md reports no drift (HIMMEL-3277)' "$o3277" 'livestate=ok'
case "$o3277" in
    *DRIFT*|*'procs=0'*) fail 'the shift-N pair must read neither DRIFT nor procs=0 (HIMMEL-3277)' ;;
    *) pass 'the shift-N pair must read neither DRIFT nor procs=0 (HIMMEL-3277)' ;;
esac
contains 'each doc counts only its own session (HIMMEL-3277)' "$(t3277 "$l192")" 'procs=1'

# The chief's disproved workaround: hyphenated full-stem labels plus a trailing
# parenthetical of its own backticked tokens. The parser's label class used to
# stop at the first hyphen, so no such span ever parsed and DRIFT named the stems.
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/HIMMEL-9-odd-name-2026-09-20-RESUME.md"
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `HIMMEL-9-odd-name-2026-09-20-RESUME:n:t:1` (odd doc, see `HIMMEL-9-odd-name`)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
contains 'a hyphenated label span parses, trailing backticked prose and all (HIMMEL-3277)' "$(t3277 'HIMMEL-9-odd-name-2026-09-20-RESUME')" 'livestate=ok'

# A genuinely stale Live state still fires: N192 is held but unnamed (DRIFT). N199
# is named but the arm does not cover it, so it reads workerset=unarmed,
# not DRIFT -- the tick has no lock for it. The fix must not make the check unable to fire.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
contains 'a genuinely stale Live state still reports DRIFT (HIMMEL-3277)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192 '
contains 'a Live-state worker the arm omits reads workerset=unarmed, not DRIFT (HIMMEL-3293)' "$(t3277 "$l191 $l192")" 'workerset=STALE:unarmed=N199'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `HIMMEL-9-odd-name-2026-09-20-RESUME:n:t:1`, `HIMMEL-8-gone-2026-09-20-RESUME:n:t:2`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
# The stale worker is ARMED here: a
# doc with no lock, so its lock is gone while Live state still names it.
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/HIMMEL-8-gone-2026-09-20-RESUME.md"
contains 'a stale hyphenated label is still DRIFT, not silently dropped (HIMMEL-3277)' "$(t3277 'HIMMEL-9-odd-name-2026-09-20-RESUME HIMMEL-8-gone-2026-09-20-RESUME')" 'livestate=DRIFT:HIMMEL-8-gone-2026-09-20-RESUME'

# --- the legs: line is read for ENTRIES, not for every backtick span.
# The chief's own explanatory parenthetical named the token `legs:` in
# backticks; the span pattern only asked for "label chars, a colon, anything",
# so it matched and read as a phantom worker named "legs" (RED control, pre-fix
# tick.sh, first fixture below: livestate=DRIFT:workers on two real, held workers).
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (each entry is `<worker>:<nonce>:<lock-token>:<pid>`; the `legs:` key, see `HIMMEL-9`, and `see: this` are prose)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
o3280="$(t3277 "$l191 $l192")"
contains 'a backticked non-entry token on the legs: line is not a phantom worker (HIMMEL-3280)' "$o3280" 'livestate=ok'
case "$o3280" in
    *DRIFT*|*MALFORMED*) fail "prose tokens on the legs: line must read neither DRIFT nor MALFORMED (HIMMEL-3280) ($o3280)" ;;
    *) pass 'prose tokens on the legs: line must read neither DRIFT nor MALFORMED (HIMMEL-3280)' ;;
esac

# Chiefs quote tick fields and worker names in notes on this line all the time:
# a colon-then-text span whose first field is NOT a worker label (`procs:2`,
# `livestate=DRIFT:N192`, `bank:5h30`) is prose, and so is a bare `N191`
# mention with no colon. Pre-fix, `procs:2` read as a phantom worker "procs".
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (last tick `procs:2`, `bank:5h30`, was `livestate=DRIFT:N192`; `N191` reported LIVE)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
q3280="$(t3277 "$l191 $l192")"
contains 'quoted tick fields on the legs: line are prose, not entries (HIMMEL-3280)' "$q3280" 'livestate=ok'
case "$q3280" in
    *DRIFT*|*MALFORMED*) fail "a non-label colon span must read neither DRIFT nor MALFORMED (HIMMEL-3280) ($q3280)" ;;
    *) pass 'a non-label colon span must read neither DRIFT nor MALFORMED (HIMMEL-3280)' ;;
esac

# A genuinely stale Live state still fires with the same prose on the line, and
# the drift names the stale workers only -- no `legs` phantom among them.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N199:J-N199-aaaaaa:tok-199:1` (the `legs:` key)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
contains 'a stale Live state with prose on the line is DRIFT naming only real workers (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192 '
contains 'the unarmed worker is named, with no phantom worker beside it (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'workerset=STALE:unarmed=N199'

# A malformed-but-entry-shaped span must be REPORTED, never dropped: dropping it
# trades a phantom for a disappearance (the mirror-image failure facing the other
# way). Reported by label only -- the span carries a nonce and a lock token.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191`, `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
m3280="$(t3277 "$l191 $l192")"
contains 'a 3-field span reads MALFORMED naming its worker (HIMMEL-3280)' "$m3280" 'livestate=MALFORMED:N191 '
case "$m3280" in
    *'livestate=ok'*|*DRIFT*) fail "a malformed span must read neither ok nor DRIFT (HIMMEL-3280) ($m3280)" ;;
    *) pass 'a malformed span must read neither ok nor DRIFT (HIMMEL-3280)' ;;
esac
case "$m3280" in
    *J-N191-0a1b2c*|*tok-191*) fail 'MALFORMED must not print the span, which carries a nonce and lock token (HIMMEL-3280)' ;;
    *) pass 'MALFORMED must not print the span, which carries a nonce and lock token (HIMMEL-3280)' ;;
esac
# Every other wrong arity / empty field is the same signal.
for bad in 'N191:' 'N191:J-N191-0a1b2c' 'N191:J-N191-0a1b2c:tok-191:120:extra' 'N191::tok-191:120' 'N191:J-N191-0a1b2c::120' 'N191:J-N191-0a1b2c:tok-191:'; do
    printf '%s\n' '# chief' '' '## Live state' '' \
        "legs: \`$bad\`, \`N192:J-N192-3d4e5f:tok-192:121\`" 'queue: none' 'last GO: none' 'acked: none' \
        > "$W/handover/chief.md"
    contains "malformed span '$bad' reads MALFORMED, not ok (HIMMEL-3280)" "$(t3277 "$l191 $l192")" 'livestate=MALFORMED:N191 '
done
# Malformed AND stale both surface; the malformed worker is named, so it is not
# double-reported as a held-but-unnamed DRIFT.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191`, `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
contains 'a malformed span and a stale worker both surface (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=MALFORMED:N191;DRIFT:N192 '

# --- the legs: BLOCK is read, not just its first line ------------
# The block is the legs: line(s) plus lines wrapped directly under them, up to
# the first blank line or the next `field:` line. RED control (pre-fix tick.sh,
# first fixture below): both workers' locks held (workers=N191:FRESH,N192:FRESH, same
# output line) and livestate=DRIFT:N192 -- the second line was never parsed.
# The precondition is asserted on every fixture: a "DRIFT" from a lock that was
# never held would be a vacuous control.
wrap_case() {  # wrap_case <desc> <expected livestate=...> <chief doc line>...
    local desc="$1" want="$2" out
    shift 2
    printf '%s\n' '# chief' '' '## Live state' '' "$@" > "$W/handover/chief.md"
    out="$(t3277 "$l191 $l192")"
    contains "$desc: both locks are held (precondition)" "$out" 'workers=N191:FRESH,N192:FRESH'
    contains "$desc (HIMMEL-3281)" "$out" "$want"
}
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a second legs: line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    'legs: `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'an indented continuation line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'an unindented continuation line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`,' \
    '`N192:J-N192-3d4e5f:tok-192:121` (wrapped by hand)' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a wrapped block ended by a blank line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192:121`' '' 'queue: none' 'last GO: none' 'acked: none'
# A wrapped span is judged like any other: malformed reads MALFORMED (by label),
# a worker named but not held reads DRIFT.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a malformed span on a continuation line reads MALFORMED' 'livestate=MALFORMED:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a worker on a continuation line the arm omits reads workerset=unarmed' 'workerset=STALE:unarmed=N199' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' \
    '  `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none'
# The block has an END, and that end reads loudly, not silently: a held worker whose
# span sits past the blank line (a per-worker detail bullet) or on another field's
# line is not named BY the block, so it is DRIFT -- the chief's own record was
# never in the workers block.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a span after the blank line is not an entry (detail bullets may quote one)' 'livestate=DRIFT:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' '' \
    '- N192 detail: `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a span on the next field: line is not an entry' 'livestate=DRIFT:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    'queue: HIMMEL-1 (`N192:J-N192-3d4e5f:tok-192:121`)' 'last GO: none' 'acked: none'
# A bullet written IMMEDIATELY under the legs: line (no blank between) ends the
# block at the list marker, so its backtick spans never reach the classifier.
# Realistic detail-bullet spans -- a file:line cite, a worktree path, a bare sha,
# a tick.sh:line cite -- must not become entries or MALFORMED labels. This pins
# the block terminator, not the classifier (the same cite on the legs: line
# itself is pinned in the cases below).
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'prose bullets directly under legs: (no blank line) are not entries or MALFORMED' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' \
    '- **N192** BLOCKED — see `stuck-playbook.md:408`, `tick.sh:234`, worktree `.claude/worktrees/fix+himmel-3273-stop-queue-race`, head `798a4bda26487e04140d0b7aee715be51c7e7247`' \
    'queue: none' 'last GO: none' 'acked: none'
# A successor stub as `chief.sh next` seeds it: the two-line preamble (its
# format span sits on a `>` line), the predecessor's legs: line verbatim and a
# decisions: pointer to the bucket file. None of it is a malformed entry.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a seeded stub with a decisions: pointer reads no MALFORMED (HIMMEL-6498)' 'livestate=ok ' \
    '> **Authority-bearing state, not a summary.** One `<worker>:<nonce>:<lock-token>:<pid>` span per worker.' \
    '> Format and optional fields: `chief-sections/live-state.md`.' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120` `N192:J-N192-3d4e5f:tok-192:121`' \
    'queue: none' 'last GO: none' 'acked: none' 'board: none yet' 'tracker: none' \
    'decisions: specs/decisions/chief-decisions-2026-10-20.md (latest #91)'
# --- a `<name>.md:<line>` cite ON the legs: line is prose. RED
# control (pre-fix tick.sh, first fixture below): both locks held
# (workers=N191:FRESH,N192:FRESH, asserted by wrap_case) and
# livestate=MALFORMED:stuck-playbook.md -- worker_label reduces the doc stem
# `stuck-playbook.md` to `stuck-playbook`, so the cite read as a label-shaped
# first field with a colon, an invented worker. The four shapes N199 pinned; only
# the .md cite leaked.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a .md:line cite on the legs: line is prose, not a malformed worker' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `stuck-playbook.md:408`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a .sh:line cite on the legs: line is prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `tick.sh:234`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a worktree path and a bare sha on the legs: line are prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (worktree `.claude/worktrees/fix+himmel-3273-stop-queue-race`, head `798a4bda26487e04140d0b7aee715be51c7e7247`)' \
    'queue: none' 'last GO: none' 'acked: none'
# A worker doc cited by its file name is the same shape (a stem that reduces to N<k>).
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a worker-doc .md:line cite on the legs: line is prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `HIMMEL-3273-N192-stop-queue-race-2026-09-20-RESUME.md:12`)' \
    'queue: none' 'last GO: none' 'acked: none'
# All four cite shapes together, one line -- a chief's real explanatory note.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'all four cite shapes together on the legs: line are prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (`stuck-playbook.md:408`, `tick.sh:234`, `.claude/worktrees/fix+himmel-3273-stop-queue-race`, `798a4bda26487e04140d0b7aee715be51c7e7247`)' \
    'queue: none' 'last GO: none' 'acked: none'
# NEGATIVE CONTROL, and the point of the ticket: the real signal survives. A
# truncated entry (three fields) under a real worker label still reads MALFORMED by
# label -- with the cites on the same line, and without them. Quieting the false
# positive by quieting the label test would read this `ok` (a worker that vanishes).
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a truncated entry under a real label still reads MALFORMED beside a .md cite' 'livestate=MALFORMED:N199 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N199:O-N199-9a03e6f1:120` (see `stuck-playbook.md:408`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a truncated entry under a real label reads MALFORMED with no cite on the line' 'livestate=MALFORMED:N199 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N199:O-N199-9a03e6f1:120`' \
    'queue: none' 'last GO: none' 'acked: none'
# Every worker-label spelling that reads MALFORMED today still does, .md in the line or not.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a truncated entry under a lettered successor label still reads MALFORMED' 'livestate=MALFORMED:N38b ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N38b:O-N38b-9a03e6f1:120` (see `chief-template.md:105`)' \
    'queue: none' 'last GO: none' 'acked: none'
# Every list-marker spelling ends the block: a worker span in the bullet is not an
# entry, so the held worker it names reads DRIFT (loud), never absent-and-quiet.
for marker in '- ' '* ' '+ ' '1. ' '  - ' '> ' '# '; do
    # shellcheck disable=SC2016  # backtick worker spans, literal fixture text
    wrap_case "a '$marker' line ends the block" 'livestate=DRIFT:N192 ' \
        'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
        "${marker}N192 detail: \`N192:J-N192-3d4e5f:tok-192:121\`" 'queue: none' 'last GO: none' 'acked: none'
done
# One-line behaviour is untouched: prose, MALFORMED and DRIFT read as they did before.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
wrap_case 'a one-line block with prose still reads ok' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (the `legs:` key)' 'queue: none' 'last GO: none' 'acked: none'

# procs=/models= guard: a HELD worker that matches no census row cannot be told
# apart from a filter that cannot match, so it must read unknown, never 0/none.
mk_pgrep_x "$W/bin-3277-none" 103
g3277="$(PATH="$W/bin-3277-none:$PATH" bash "$SUT" --workers "$l191 $l192")"
contains 'held workers matching no census row read procs=unknown (HIMMEL-3277)' "$g3277" 'procs=unknown'
contains 'held workers matching no census row read models=unknown (HIMMEL-3277)' "$g3277" 'models=unknown'
case "$g3277" in
    *'procs=0'*|*'models=none'*) fail 'a matched-nothing filter must not render procs=0 / models=none (HIMMEL-3277)' ;;
    *) pass 'a matched-nothing filter must not render procs=0 / models=none (HIMMEL-3277)' ;;
esac
# Population-level, not per-worker (chief ruling): when SOME held workers match, the
# derivation demonstrably works, so the ones that do not are genuinely not
# running -- count the live ones and NAME the unmatched. One dead worker must never
# blank the field for the live ones.
mk_pgrep_x "$W/bin-3277-half" 120
half3277="$(PATH="$W/bin-3277-half:$PATH" bash "$SUT" --workers "$l191 $l192")"
contains 'one live + one dead held worker reads a count plus the named unmatched worker (HIMMEL-3277)' "$half3277" 'procs=1,unmatched=N192 '
contains 'one live + one dead held worker still buckets the live model (HIMMEL-3277)' "$half3277" 'models=sonnet:1 '
# The legacy -legN<k>- spelling, with a slug that itself contains "-worker-" (N194's own doc).
l194='HIMMEL-3277-tick-worker-identity-legN194-2026-09-20-RESUME'
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/$l194.md"
mkcmdline 123 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3277-N194-tick-worker-identity work
mk_pgrep_x "$W/bin-3277-194" 123
o194="$(PATH="$W/bin-3277-194:$PATH" bash "$SUT" --workers "$l194")"
contains 'a -legN<k>- doc with -worker- in its slug resolves to N<k> and its session is counted (HIMMEL-3277)' "$o194" 'workers=N194:FRESH'
contains 'a -legN<k>- doc is counted in procs= against the <TICKET>-N<k>-<slug> session (HIMMEL-3277)' "$o194" 'procs=1 '
# A worker whose session is live under a name no derivation yields is the same case.
mkcmdline 122 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3269-worker-of-scorecard work
mk_pgrep_x "$W/bin-3277-odd" 122
contains 'a live session under an underivable name reads procs=unknown (HIMMEL-3277)' "$(PATH="$W/bin-3277-odd:$PATH" bash "$SUT" --workers "$l191")" 'procs=unknown'
# ...but a worker that is NOT held (wrapped) expects no process: 0 is a real count.
not_contains 'a wrapped (FREE) worker with no session omits the zero procs count' "$(PATH="$W/bin-3277-none:$PATH" bash "$SUT" --workers 'HIMMEL-7-N77-wrapped-2026-09-20-RESUME' 2>/dev/null)" 'procs='

# --- the chief template's own legs: placeholder must not parse.
# The doc under test is the REAL docs/handover/chief-template.md, not a fixture
# copy of its line: the template shipped `legs: <none dispatched yet, or
# `N1:<nonce>:<lock-token>:<pid>`, `N2:…`>`, whose two backtick spans are exactly
# the entry shape the parser was taught to read. RED control
# (pre-fix template, this fixture, a chief that has dispatched nothing):
#   livestate=MALFORMED:N2;DRIFT:N1
tpl3287="$HERE/../../../docs/handover/chief-template.md"
awk '/^## Live state$/ { keep = 1 } /^## Compact instructions$/ { keep = 0 } keep' "$tpl3287" > "$W/handover/chief.md"
contains 'the template Live state section was extracted (HIMMEL-3287 precondition)' "$(cat "$W/handover/chief.md")" 'workers: '
o3287="$(bash "$SUT" --workers '')"
contains 'the chief template'"'"'s own legs: placeholder reads livestate=ok on a chief with no workers (HIMMEL-3287)' "$o3287" 'livestate=ok '
case "$o3287" in
    *MALFORMED*|*DRIFT*) fail "the template placeholder must read neither MALFORMED nor DRIFT (HIMMEL-3287) ($o3287)" ;;
    *) pass 'the template placeholder must read neither MALFORMED nor DRIFT (HIMMEL-3287)' ;;
esac
# The template's other three defects, pinned against its own text. (b) the
# tick no longer runs as a 30-min Monitor re-arm loop (a test pinned the
# cap; chief-wait.sh replaced the loop with an event waiter);
# (c) a bare --workers name resolves against the handover ROOT and reads
# NOTFOUND; (d) an unquoted --model {{MODEL}} is a zsh glob (claude-opus-5[1m]).
tick3287="$(grep -F '| tick |' "$tpl3287")"
step3287="$(awk '/^10\. \*\*Start the event waiter now/ { keep = 1 } /^## Live state$/ { keep = 0 } keep' "$tpl3287")"
contains 'the tick row runs inside the step-10 waiter (HIMMEL-3509)' "$tick3287" 'Runs inside the step-10 waiter'
case "$tick3287" in
    *'re-arms on each expiry notice'*) fail 'the tick row no longer arms a Monitor re-arm loop (HIMMEL-3509)' ;;
    *) pass 'the tick row no longer arms a Monitor re-arm loop (HIMMEL-3509)' ;;
esac
contains 'ACTION ZERO step 10 starts chief-wait.sh (HIMMEL-3509)' "$step3287" 'chief-wait.sh'
contains 'ACTION ZERO step 10 uses run_in_background, not a Monitor (HIMMEL-3509)' "$step3287" 'run_in_background: true'
contains 'ACTION ZERO step 10 says how to verify the waiter is live (HIMMEL-3509)' "$step3287" '<inbox>.wait'
case "$tick3287$step3287" in
    *'60 min'*) fail 'neither the tick row nor step 10 may still say 60 min (HIMMEL-3287)' ;;
    *) pass 'neither the tick row nor step 10 may still say 60 min (HIMMEL-3287)' ;;
esac
contains 'the --workers example uses absolute paths (HIMMEL-3287)' "$tick3287" '--workers "{{STATE_DIR}}/<leg1>.md {{STATE_DIR}}/<leg2>.md"'
contains 'the row says why bare worker doc names fail (HIMMEL-3287)' "$tick3287" 'resolves against the handover ROOT'
# A worker doc lives in the chief's bucket, one level under the handover root:
# the absolute path resolves, the bare name the template used to show does not.
mkdir -p "$W/handover/bucket3287"
l3287='HIMMEL-3287-N287-bucketed-2026-09-20-RESUME.md'
printf '%s\n' '# worker' '- LIVE — working' > "$W/handover/bucket3287/$l3287"
contains 'an absolute --workers path to a bucketed worker doc resolves, not NOTFOUND (HIMMEL-3287)' "$(bash "$SUT" --workers "$W/handover/bucket3287/$l3287")" 'workers=N287:FREE'
contains 'a bare --workers name of a bucketed worker doc reads NOTFOUND (HIMMEL-3287)' "$(bash "$SUT" --workers "$l3287" 2>/dev/null)" 'workers=N287:NOTFOUND'
next3287="$(grep -F '/chief next --arm' "$tpl3287")"
contains "the /chief next line quotes --model (HIMMEL-3287)" "$next3287" "--model '{{MODEL}}'"
case "$next3287" in
    *'--model {{MODEL}}'*) fail 'the /chief next line must not carry an unquoted --model {{MODEL}} (HIMMEL-3287)' ;;
    *) pass 'the /chief next line must not carry an unquoted --model {{MODEL}} (HIMMEL-3287)' ;;
esac

# --- one worker set -- a stale --workers arm is an INPUT problem, never
# worker drift. The ticket's own fixture: a Live state naming THREE workers, a --workers
# naming TWO, one of them wrapped. N301 is held and armed; N302 and N303 are held
# and live but were dispatched after the arm (not in --workers); N300 is wrapped (its
# lock released, its last bullet WRAPPED) and is armed but already gone from Live
# state. RED control (pre-fix tick.sh, this fixture) read:
#   workers=N300:FREE,N301:FRESH livestate=DRIFT:N302,N303 procs=1 models=sonnet:1
# -- a false DRIFT on two healthy workers, procs=1 beside three live workers, N302/N303
# absent from workers=, and the wrapped worker indistinguishable from a lost lock.
w3293="HIMMEL-3300-N300-wrapped-2026-09-20-RESUME"
a3293="HIMMEL-3301-N301-alpha-2026-09-20-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3293.md"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$a3293.md"
mkcmdline 130 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3301-N301-alpha work
mkcmdline 131 claude --model claude-opus-5 --autocompact 200000 -n HIMMEL-3302-N302-beta work
mkcmdline 132 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3303-N303-gamma work
mkcmdline 133 claude --model claude-opus-5 -n HIMMEL-nextleg-2026-09-20R-chief work
mk_pgrep_x "$W/bin-3293" 130 131 132 133
t3293() { PATH="$W/bin-3293:$PATH" bash "$SUT" --workers "$1"; }
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`, `N302:J-N302-3d4e5f:tok-302:131`, `N303:J-N303-6a7b8c:tok-303:132`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
o3293="$(t3293 "$W/handover/$w3293.md $W/handover/$a3293.md")"
contains 'a worker dispatched after the arm is not livestate=DRIFT (HIMMEL-3293)' "$o3293" 'livestate=ok '
case "$o3293" in
    *DRIFT*) fail "a stale arm must not read as worker DRIFT (HIMMEL-3293) ($o3293)" ;;
    *) pass 'a stale arm must not read as worker DRIFT (HIMMEL-3293)' ;;
esac
contains 'the disagreement is reported as an input problem, both directions (HIMMEL-3293)' "$o3293" 'workerset=STALE:unarmed=N302+N303;unlisted=N300'
contains 'live workers outside the arm are surfaced in procs=, not dropped (HIMMEL-3293)' "$o3293" 'procs=1,unwatched=N302+N303 '
contains 'a wrapped worker reads WRAPPED, distinct from a lost lock (HIMMEL-3293)' "$o3293" 'workers=N300:WRAPPED,N301:FRESH '
p3293="$(printf '%s\n' "$o3293" | sed -E 's/.* procs=([^ ]*) .*/\1/')"
case "$p3293" in
    *N301*|*N300*|*nextleg*|*chief*) fail "the armed worker and the chief must not read unwatched (HIMMEL-3293) ($p3293)" ;;
    *) pass 'the armed worker and the chief session are not unwatched (HIMMEL-3293)' ;;
esac
# The check must still fire on real drift: an ARMED worker whose lock is gone but
# that Live state still names (N300, wrapped), and a HELD worker Live state omits.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N300:J-N300-aaaaaa:tok-300:1`, `N302:J-N302-3d4e5f:tok-302:131`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
d3293="$(t3293 "$W/handover/$w3293.md $W/handover/$a3293.md")"
contains 'an armed wrapped worker Live state still names is DRIFT (HIMMEL-3293)' "$d3293" 'livestate=DRIFT:N300,N301 '
contains 'a Live-state worker outside the arm is unarmed, not drift, beside real drift (HIMMEL-3293)' "$d3293" 'workerset=STALE:unarmed=N302'
# A tick armed with no --workers at all (the Monitors row's own example) can see no
# lock: every Live-state worker is unarmed, none is drift, and every live worker surfaces.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`, `N302:J-N302-3d4e5f:tok-302:131`, `N303:J-N303-6a7b8c:tok-303:132`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
n3293="$(PATH="$W/bin-3293:$PATH" bash "$SUT" --workers '')"
contains 'no --workers: every Live-state worker is unarmed, none is DRIFT (HIMMEL-3293)' "$n3293" 'livestate=ok '
contains 'no --workers: legset names all three as unarmed (HIMMEL-3293)' "$n3293" 'workerset=STALE:unarmed=N301+N302+N303'
contains 'no --workers: procs=unknown still surfaces the live workers (HIMMEL-3293)' "$n3293" 'procs=unknown,unwatched=N301+N302+N303 '
# An arm that agrees with Live state reports workerset=ok; no Live state section is unknown.
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
printf '%s\n' '# chief' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/chief.md"
contains 'an arm that agrees with Live state reads workerset=ok (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'workerset=ok'
contains 'an agreeing arm still surfaces the live workers outside it (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'procs=1,unwatched=N302+N303 '
printf '%s\n' '# chief' '' 'no Live state section in this doc at all' > "$W/handover/chief.md"
contains 'a chief doc with no Live state section reads workerset=unknown (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'workerset=unknown'

# --- a live -RESUME session is the watched process of its worker ----
# The resumed worker's doc is N4304b-...-RESUME; its window runs under the original label
# (N4304) with -RESUME kept, or under the full doc stem. Either joins to the worker, never unwatched.
r8424="HIMMEL-8304-N4304b-resumed-2026-10-31-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$r8424.md"
printf '%s\n' '# chief' '' 'no Live state section in this doc at all' > "$W/handover/chief.md"
mkcmdline 140 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8304-N4304-resumed-2026-10-31-RESUME work
mk_pgrep_x "$W/bin-8424" 140
o8424="$(PATH="$W/bin-8424:$PATH" bash "$SUT" --workers "$W/handover/$r8424.md")"
contains '8424: a live <orig label>-RESUME session counts as the worker process (procs=1)' "$o8424" ' procs=1 '
contains '8424: the resumed worker reads FRESH' "$o8424" 'workers=N4304b:FRESH '
rm -rf "$W/proc/140"
mkcmdline 141 claude --model claude-sonnet-5 --autocompact 200000 -n "$r8424" work
mk_pgrep_x "$W/bin-8424" 141
o8424="$(PATH="$W/bin-8424:$PATH" bash "$SUT" --workers "$W/handover/$r8424.md")"
contains '8424: a live full-doc-stem session counts as the worker process (procs=1)' "$o8424" ' procs=1 '
rm -rf "$W/proc/141"
# negative control: an unrelated -RESUME session is still unwatched
mkcmdline 142 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8304-N4399-other-2026-10-31-RESUME work
mk_pgrep_x "$W/bin-8424" 142
o8424="$(PATH="$W/bin-8424:$PATH" bash "$SUT" --workers "$W/handover/$r8424.md")"
contains '8424: an unrelated -RESUME session stays unwatched' "$o8424" 'unwatched=N4399'
rm -rf "$W/proc/142"

# --- unwatched= is scoped to THIS chief. The worker's environ carries
# HIMMEL_CONSOLE_NAME (its launching chief); the chief's name is its doc stem. N302 belongs
# to another LIVE chief (dropped), N303 to this one (kept), N301 is armed.
mkcmdline 134 claude --model claude-opus-5 -n other-chief work
mk_pgrep_x "$W/bin-7811" 130 131 132 133 134
printf 'HOME=/x\0HIMMEL_CONSOLE_NAME=other-chief\0' > "$W/proc/131/environ"
printf 'HOME=/x\0HIMMEL_CONSOLE_NAME=chief\0' > "$W/proc/132/environ"
o7811="$(PATH="$W/bin-7811:$PATH" bash "$SUT" --doc "$W/handover/chief.md" --workers "$W/handover/$a3293.md")"
contains "(7811) another live chief's worker is not unwatched, this chief's is" "$o7811" 'procs=1,unwatched=N303 '
# This chief is itself a live session (stem "chief"): a worker it owns is still unwatched.
mkcmdline 135 claude --model claude-opus-5 -n chief work
mk_pgrep_x "$W/bin-7811b" 130 131 132 133 134 135
o7811="$(PATH="$W/bin-7811b:$PATH" bash "$SUT" --doc "$W/handover/chief.md" --workers "$W/handover/$a3293.md")"
contains "(7811) this chief's own worker stays unwatched while this chief is a live session" "$o7811" 'unwatched=N303 '
rm -f "$W/proc/135/cmdline"
# A named chief that is no longer a live session (a succession): the worker is inherited.
printf 'HOME=/x\0HIMMEL_CONSOLE_NAME=gone-chief\0' > "$W/proc/131/environ"
o7811="$(PATH="$W/bin-7811:$PATH" bash "$SUT" --doc "$W/handover/chief.md" --workers "$W/handover/$a3293.md")"
contains '(7811) a worker whose named chief is gone stays unwatched (inherited)' "$o7811" 'procs=1,unwatched=N302+N303 '
rm -f "$W/proc/131/environ" "$W/proc/132/environ" "$W/proc/134/cmdline"
o7811="$(PATH="$W/bin-3293:$PATH" bash "$SUT" --doc "$W/handover/chief.md" --workers "$W/handover/$a3293.md")"
contains '(7811) a worker with no readable owner stays unwatched (fail open)' "$o7811" 'procs=1,unwatched=N302+N303 '

# --- a resolved FINDING must read differently from an open one.
# The ticket's case (worker N219, 2026-09-20): a worker raised a FINDING, the chief
# accepted it the same minute, and tails= kept reading FINDING for the 23 minutes
# the worker spent doing the authorised work. The vocabulary had no word to retire a
# finding with, and the derivation took the FIRST marker on the last marker-bearing
# line, so word order decided the status. RED control (pre-fix tick.sh, the
# `resolved` case below): tails=N305:FINDING -- for a bullet that says the finding
# is settled. Fix: RESOLVED joins the vocabulary and the bullet's status is its
# highest-precedence marker (WRAPPED > READY > RESOLVED > BLOCKED > HALTED >
# FINDING > LIVE), matched as a whole word. (the leading-marker rule superseded the precedence
# half: the status is the bullet's leading marker; see the block below.)
d3305="$W/handover/HIMMEL-3305-N305-resolved-2026-09-20-RESUME.md"
tail3305() {  # tail3305 <bullet>... -- the tails= entry of a worker doc holding these bullets
    printf '%s\n' '# worker' '- 19:40 LIVE — working' "$@" > "$d3305"
    bash "$SUT" --workers "$d3305" 2>/dev/null | sed -E 's/.* tails=([^ ]*) .*/\1/'
}
open3305='- 19:51 FINDING premises refuted (the chief has not answered yet)'
res3305='- 19:52 RESOLVED — FINDING accepted by the chief, back to work'
contains 'an open FINDING still reads FINDING (HIMMEL-3305)' "$(tail3305 "$open3305")" 'N305:FINDING'
contains 'a resolved FINDING reads RESOLVED, not FINDING (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305")" 'N305:RESOLVED'
# The newest marker-bearing bullet still wins: work after the ruling reads as work,
# and a new finding after a resolved one reads as open again.
contains 'a LIVE bullet after the resolution reads LIVE (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305" '- 20:05 LIVE — PR open, CI running')" 'N305:LIVE'
contains 'a second FINDING after a resolved one reads FINDING (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305" '- 20:20 FINDING the base moved under the diff')" 'N305:FINDING'
# Word order must not decide the status: the LEADING marker does (it
# replaced the highest-precedence-anywhere rule). RESOLVED first reads RESOLVED
# however many other markers the sentence names; LIVE first reads LIVE.
contains 'RESOLVED before FINDING and LIVE reads RESOLVED (HIMMEL-3305)' "$(tail3305 '- 20:10 RESOLVED FINDING, back to LIVE')" 'N305:RESOLVED'
contains 'LIVE before FINDING and RESOLVED reads LIVE, the leading marker (HIMMEL-3393)' "$(tail3305 '- 20:10 LIVE again, FINDING RESOLVED')" 'N305:LIVE'
contains 'READY first reads READY though the text names BLOCKED (HIMMEL-3305)' "$(tail3305 '- 20:30 READY 999 abc GREEN (was BLOCKED)')" 'N305:READY'
contains 'BLOCKED first reads BLOCKED though the text names READY (HIMMEL-3393)' "$(tail3305 '- 20:30 BLOCKED cleared, now READY 999 abc GREEN')" 'N305:BLOCKED'
contains 'WRAPPED first reads WRAPPED though the text names READY (HIMMEL-3305)' "$(tail3305 '- 21:00 WRAPPED — merged after READY and GO')" 'N305:WRAPPED'
# A marker is a whole word: UNRESOLVED (a routine CR-thread count) is not RESOLVED.
contains 'UNRESOLVED is not the RESOLVED marker (HIMMEL-3305)' "$(tail3305 '- 20:00 LIVE — 2 UNRESOLVED threads')" 'N305:LIVE'
# SHIPPED and MERGED stay OUT of the vocabulary: a bullet carrying only a coined
# word has no marker, so the tick reads the last real one. worker-preface.md tells a
# worker between GREEN and READY to report LIVE for exactly this reason.
contains 'a coined SHIPPED bullet is invisible to the tick (HIMMEL-3305)' "$(tail3305 "$open3305" '- 20:05 SHIPPED to PR 999')" 'N305:FINDING'
contains 'a LIVE bullet is how a worker between GREEN and READY reports (HIMMEL-3305)' "$(tail3305 "$open3305" '- 20:05 LIVE — SHIPPED to PR 999, watching CI')" 'N305:LIVE'
# The tick's regex and the documented vocabulary change TOGETHER: a marker workers
# are not told to write is not a fix, and one the tick does not parse is worse.
repo3305="$(cd "$HERE/../../.." && pwd)"
for pref3305 in worker-preface.md worker-preface-claudex.md; do
    # shellcheck disable=SC2016  # backtick-quoted marker, literal doc text
    contains "$pref3305 tells a worker to report RESOLVED (HIMMEL-3305)" "$(cat "$repo3305/docs/handover/$pref3305")" '`RESOLVED`'
done
# shellcheck disable=SC2016  # backtick-quoted markers, literal doc text
contains 'worker-preface.md says SHIPPED and MERGED are not markers (HIMMEL-3305)' "$(cat "$repo3305/docs/handover/worker-preface.md")" '`SHIPPED` and `MERGED` are deliberately not in the'

# --- a bullet's status is its LEADING token, never a word in its text.
# The ticket's case (worker N293, 2026-09-21): the newest bullet was
# `- 23:47 LIVE — … Judgment call, not a FINDING: …`; the derivation took the
# highest-precedence marker anywhere in the bullet, so tails= read FINDING and the
# board listed the worker under "Needs the chief". RED control (pre-fix tick.sh, the
# `not a FINDING` case below): tails=N393:FINDING. Fix: the status is the marker the
# bullet STARTS with (`- [HH:MM] <MARKER>`); a bullet that does not start with one
# is invisible, like a coined SHIPPED.
d3393="$W/handover/HIMMEL-3393-N393-leading-token-2026-09-21-RESUME.md"
tail3393() {  # tail3393 <bullet>... -- the tails= entry of a worker doc holding these bullets
    printf '%s\n' '# worker' '- 23:00 LIVE — working' "$@" > "$d3393"
    bash "$SUT" --workers "$d3393" 2>/dev/null | sed -E 's/.* tails=([^ ]*) .*/\1/'
}
contains 'a LIVE bullet saying "not a FINDING" reads LIVE (HIMMEL-3393)' "$(tail3393 '- 23:47 LIVE — PR 1 open. Judgment call, not a FINDING: the ticket says so')" 'N393:LIVE'
contains 'a LIVE bullet that mentions READY reads LIVE (HIMMEL-3393)' "$(tail3393 '- 23:47 LIVE — send READY at green')" 'N393:LIVE'
contains 'a LIVE bullet that mentions BLOCKED and WRAPPED reads LIVE (HIMMEL-3393)' "$(tail3393 '- 23:47 LIVE — was BLOCKED, then WRAPPED nothing')" 'N393:LIVE'
contains 'a leading PARKED-BANK reads PARKED-BANK, not the earlier LIVE (HIMMEL-4570)' "$(tail3393 '- 23:47 PARKED-BANK — committed, waiting for RESUME')" 'N393:PARKED-BANK'
contains 'a leading PARKED-USAGE reads PARKED-USAGE, not the earlier LIVE' "$(tail3393 '- 23:47 PARKED-USAGE — committed, waiting for RESUME')" 'N393:PARKED-USAGE'
contains 'a leading FINDING still reads FINDING (HIMMEL-3393)' "$(tail3393 '- 23:47 FINDING — needs a ruling')" 'N393:FINDING'
contains 'a FINDING retired by a leading RESOLVED reads RESOLVED (HIMMEL-3393)' "$(tail3393 '- 23:47 FINDING — needs a ruling' '- 23:50 RESOLVED — ruled, back to work')" 'N393:RESOLVED'
contains 'a leading RESOLVED that names FINDING and LIVE reads RESOLVED (HIMMEL-3393)' "$(tail3393 '- 23:50 RESOLVED — FINDING accepted, back to LIVE')" 'N393:RESOLVED'
contains 'a bullet without a time still reads its leading marker (HIMMEL-3393)' "$(tail3393 '- FINDING — no time stamp')" 'N393:FINDING'
contains 'a bold leading marker reads as that marker (HIMMEL-3393)' "$(tail3393 '- **WRAPPED.** merged, lock released')" 'N393:WRAPPED'
# A bullet that leads with prose carries no status: the tick reads the last real one.
contains 'a bullet leading with prose is invisible to the tick (HIMMEL-3393)' "$(tail3393 '- 23:47 FINDING — needs a ruling' '- 23:48 Sent the FINDING to the chief, will report READY once it rules')" 'N393:FINDING'
contains 'a marker glued to a longer word is not a marker (HIMMEL-3393)' "$(tail3393 '- 23:47 FINDINGS pending, no marker here')" 'N393:LIVE'

# --- a worker holding at READY behind a LIVE-led bullet must read READY (only LIVE-led
# bullets are promoted; any other leading marker keeps its own word).
# N2524 (10-17) held READY on PR 3002 behind `LIVE — holding at READY for GO`; a
# claudex worker cannot SendMessage, so the doc bullet is its only channel, and tails=
# read LIVE for ~40 minutes. RED control (pre-fix tick.sh): tails=N393:LIVE.
sha6154=0123456789abcdef0123456789abcdef01234567
contains 'a LIVE bullet "holding at READY" reads READY (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — holding at READY for GO')" 'N393:READY'
contains 'a LIVE bullet naming READY <pr> <full head> reads READY (HIMMEL-6154)' "$(tail3393 "- 23:47 LIVE — sent READY 3002 $sha6154 GREEN, waiting")" 'N393:READY'
contains 'a plain LIVE fix-pushed bullet stays LIVE (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — fix pushed')" 'N393:LIVE'
contains 'a WRAPPED bullet naming READY <pr> <head> stays WRAPPED (HIMMEL-6154)' "$(tail3393 "- 23:47 WRAPPED — merged after READY 3002 $sha6154")" 'N393:WRAPPED'
contains 'a LIVE bullet "no longer holding at READY" stays LIVE (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — no longer holding at READY; fixing review findings')" 'N393:LIVE'
contains 'a LIVE bullet "not currently holding at READY" stays LIVE (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — not currently holding at READY; fixing findings')" 'N393:LIVE'
contains 'a LIVE bullet "no longer READY <pr> <head>" stays LIVE (HIMMEL-6154)' "$(tail3393 "- 23:47 LIVE — no longer READY 3002 $sha6154; fixing findings")" 'N393:LIVE'
contains 'a LIVE bullet "nothing blocking, holding at READY" reads READY (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — nothing blocking, holding at READY for GO')" 'N393:READY'
contains 'a LIVE bullet "cannot send READY <pr> <head> yet" stays LIVE (HIMMEL-6154)' "$(tail3393 "- 23:47 LIVE — cannot send READY 3002 $sha6154 yet: CI red")" 'N393:LIVE'
contains 'a LIVE bullet "Holding at READY" (capitalised) reads READY (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — Holding at READY for GO')" 'N393:READY'
contains 'a LIVE bullet "never READY <pr> <head>" stays LIVE (HIMMEL-6154)' "$(tail3393 "- 23:47 LIVE — never READY 3002 $sha6154 on this head")" 'N393:LIVE'
contains 'a LIVE bullet "without READY" stays LIVE (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — without holding at READY, fixing')" 'N393:LIVE'
contains 'a LIVE bullet "isn'"'"'t holding at READY" stays LIVE (HIMMEL-6154)' "$(tail3393 "- 23:47 LIVE — isn't holding at READY, fixing")" 'N393:LIVE'
contains 'a newer prose-leading bullet naming holding at READY does not promote the earlier LIVE (HIMMEL-6154)' "$(tail3393 '- 23:48 Still holding at READY, waiting on the chief')" 'N393:LIVE'
contains 'READY held then a newer plain LIVE bullet reads LIVE (HIMMEL-6154)' "$(tail3393 '- 23:47 LIVE — holding at READY for GO' '- 23:50 LIVE — fixing a review finding')" 'N393:LIVE'

# --- a lock queue-lock can neither attribute to this doc nor rule
# out (status `held -- UNVERIFIED`, rc 11) reads UNVERIFIED -- never FREE, which
# the chief reads as "reclaim it", and never folded into WRAPPED by the worker's
# own tail. RED control (pre-fix tick.sh): workers=N380:UNKNOWN.
u3290="HIMMEL-3380-N380-unverified-2026-09-22-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$u3290.md"
contains 'an unattributable lock reads UNVERIFIED, not FREE/WRAPPED/UNKNOWN (HIMMEL-3290)' "$(bash "$SUT" --workers "$W/handover/$u3290.md" 2>/dev/null)" 'workers=N380:UNVERIFIED '

# --- a past-TTL lock whose owner is provably dead (status
# `STALE-DEAD`, rc 12) reads STALE-DEAD and is NOT a held leg: it must not
# fold into the FRESH/STALE held set. RED control (pre-fix tick.sh):
# workers=N390:STALE.
d5541="HIMMEL-5541-N390-stale-dead-2026-10-01-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$d5541.md"
out5541="$(bash "$SUT" --workers "$W/handover/$d5541.md" 2>/dev/null)"
contains 'a past-TTL dead-owner lock reads STALE-DEAD (HIMMEL-5541)' "$out5541" 'workers=N390:STALE-DEAD '
not_contains 'a STALE-DEAD lock is not folded into STALE (HIMMEL-5541)' "$out5541" 'workers=N390:STALE '

# --- board=<ok|STALE:<age>|MISSING|skip> -- the chief's progress
# board (<doc stem>.board.json, written by board.mjs next to the chief doc) must be
# structurally checked, not remembered. RED control (pre-fix tick.sh): the line
# carries no board= field at all, so a chief that never rendered one, or whose
# board is days old, is invisible to its own tick. The freshness reference is a
# fingerprint of the state a board shows (workers, tails, open PRs, queue, last GO),
# stored in the board JSON by board.mjs and recomputed here -- not the doc's mtime,
# which every Results bullet bumps and would read STALE all day.
b3361="HIMMEL-3361-N361-board-2026-09-21-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' > "$W/handover/$b3361.md"
mkcmdline 361 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3361-N361-board work
mk_pgrep_x "$W/bin-3361" 361
board3361="$W/handover/chief.board.json"
rm -f "$board3361"
# shellcheck disable=SC2016  # backtick worker spans, literal fixture text
write_console3361() {  # write_console3361 <last GO value> [extra Results bullet]
    printf '%s\n' '# chief' '' '## Live state' '' \
        'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' "last GO: $1" 'acked: none' ${3:+"$3"} '' \
        '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' ${2:+"$2"} \
        > "$W/handover/chief.md"
}
t3361() { PATH="$W/bin-3361:$PATH" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"; }
write_console3361 none
contains 'a chief with no board file reads board=MISSING (HIMMEL-3361)' "$(t3361)" ' board=MISSING'
# The default fixture has no chief doc at all: nothing to check, like workerset=skip.
contains 'no chief doc reads board=skip (HIMMEL-3361)' "$out" ' board=skip'
contains '--verbose labels the board (HIMMEL-3361)' "$(t3361 --verbose)" 'board: MISSING'
# --emit-fp is the seam board.mjs reads: the tick line, then the fingerprint.
fp3361="$(t3361 --emit-fp | sed -n '2p')"
case "$fp3361" in
    board-fp=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass '--emit-fp prints the fingerprint on line 2 (HIMMEL-3361)' ;;
    *) fail "--emit-fp line 2 is not board-fp=<16 hex> ('$fp3361')" ;;
esac
# A board whose fingerprint is not the current one is STALE, aged by its mtime.
printf '%s\n' '{' ' "freshness": {' '  "board_fp": "0000000000000000"' ' }' '}' > "$board3361"
touch -d '3 hours ago' "$board3361"  # gnu-ok: chief kit is Linux-only
contains 'a board with another fingerprint reads board=STALE:<age> (HIMMEL-3361)' "$(t3361)" ' board=STALE:3h'
touch -d '12 minutes ago' "$board3361"  # gnu-ok: chief kit is Linux-only
contains 'a young stale board ages in minutes (HIMMEL-3361)' "$(t3361)" ' board=STALE:12m'
# The real generator's output is fresh under the real tick: one derivation. The
# stubs on PATH answer gh/bank/atq for both, so the two runs see the same state.
if command -v node >/dev/null 2>&1; then
    bpath3361="$(PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/chief.md" --workers "$W/handover/$b3361.md" --repo "$REPO" 2>&1)"
    if [ "$bpath3361" = "$board3361" ] && [ -f "$board3361" ]; then
        pass 'board.mjs writes the board JSON next to the chief doc'
    else
        fail "board.mjs did not write the board ($bpath3361)"
    fi
    contains 'a board rendered from the current state reads board=ok (HIMMEL-3361)' "$(t3361)" ' board=ok'
    # The freshness is read from board.json, so a board with no static page on disk is not a stale board.
    if compgen -G "$W/handover/*.html" >/dev/null; then fail 'board.mjs left an html page in the bucket'; fi
    contains 'a board with no static page on disk still reads board=ok' "$(t3361)" ' board=ok'
    # A Results bullet is not a state change: the board stays ok.
    write_console3361 none '- 12:05 RULING nothing about state'
    contains 'a Results bullet does not stale the board (HIMMEL-3361)' "$(t3361)" ' board=ok'
    # A GO is: republish.
    # shellcheck disable=SC2016  # backtick span, literal fixture text
    write_console3361 '`1023:abc`'
    contains 'a new last GO stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    # The epics: and decisions: lines are rendered panels: editing them is a republish.
    write_console3361 none '' 'epics: HIMMEL-3332=5'
    contains 'a new epics: line stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    write_console3361 none '' 'decisions: widen the fleet cap?'
    contains 'a new decisions: line stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    write_console3361 none
    # A worker tail change (READY) is a phase change: republish.
    printf '%s\n' '- 12:30 READY 1023 abc GREEN' >> "$W/handover/$b3361.md"
    contains 'a worker phase change stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    # --- one Live-state block, read by tick.sh and by board.mjs, names
    # the same workers. RED control (pre-fix board.mjs): its own parser accepted a
    # three-field span (N4), an empty-field span (N5), a span in a `>` line (N8) and
    # a detail bullet (N6), and rejected a label with _ . - (N3_x.y-z). The tick
    # reads no --workers here, so every Live-state entry is `unarmed=` and the board,
    # given no worker docs, lists exactly its Live-state labels.
    # shellcheck disable=SC2016  # backtick worker spans, literal fixture text
    printf '%s\n' '# chief' '' '## Live state' '' \
        'legs: `N1:J-N1-0a1b2c9d:cachyos-x8664-pid1001:1001` a note `procs:2` `N2b:J-N2b-0a1b2c9d:cachyos-x8664-pid1002:1002`' \
        '  `N3_x.y-z:J-N3-0a1b2c9d:cachyos-x8664-pid1003:1003` `N4:J-N4-0a1b2c9d:cachyos-x8664-pid1004` `N5::J-N5-0a1b2c9d:1005`' \
        '> quoted `N8:J-N8-0a1b2c9d:cachyos-x8664-pid1008:1008` after a > terminator' \
        'legs: `N7:J-N7-0a1b2c9d:cachyos-x8664-pid1007:1007`' \
        '- detail `N6:J-N6-0a1b2c9d:cachyos-x8664-pid1006:1006` under the block' \
        'queue: none' 'last GO: none' 'acked: none' '' '## Results' '- 12:00 DISPATCH' \
        > "$W/handover/chief.md"
    tickset3366="$(PATH="$W/bin-3361:$PATH" bash "$SUT" --doc "$W/handover/chief.md" | sed -n 's/.* workerset=STALE:unarmed=\([^ ;]*\).*/\1/p' | tr '+' '\n' | sort)"
    PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/chief.md" --repo "$REPO" --out "$W/handover/board-3366.html" >/dev/null 2>&1
    boardset3366="$(grep -o 'data-label="[^"]*"' "$W/handover/board-3366.html" | sed 's/^data-label="//; s/"$//' | sort)"
    contains 'the tick reads a label with _ . - as a worker (HIMMEL-3366)' "$tickset3366" 'N3_x.y-z'
    if [ -n "$tickset3366" ] && [ "$tickset3366" = "$boardset3366" ]; then
        pass 'tick.sh and board.mjs read one Live-state block as the same worker set (HIMMEL-3366)'
    else
        fail "tick.sh and board.mjs read different worker sets (tick: $(printf '%s' "$tickset3366" | tr '\n' ' ') board: $(printf '%s' "$boardset3366" | tr '\n' ' '))"
    fi
else
    printf 'SKIP - board round-trip (node not installed)\n'
fi

# --- a WRAPPED worker (lock free, tail says WRAPPED) whose own
# session process is STILL alive in the census reads CLOSABLE, not WRAPPED --
# the window is sitting there finished but not yet closed, and this is the
# signal a chief should wake on and go close it.
w3747a="HIMMEL-3747-N640-closable-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747a.md"
mkcmdline 140 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3747-N640-closable-2026-09-27 work
mk_pgrep_x "$W/bin-3747a" 140
o3747a="$(PATH="$W/bin-3747a:$PATH" bash "$SUT" --workers "$W/handover/$w3747a.md")"
contains 'a WRAPPED worker whose session process is still alive reads CLOSABLE (HIMMEL-3747 Ask 1)' "$o3747a" 'workers=N640:CLOSABLE'

# Control: the same WRAPPED doc, but no live session anywhere in the census --
# the normal end of a worker once its window is actually gone. Must stay WRAPPED.
w3747b="HIMMEL-3747-N641-gone-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747b.md"
mk_pgrep_x "$W/bin-3747b"
o3747b="$(PATH="$W/bin-3747b:$PATH" bash "$SUT" --workers "$W/handover/$w3747b.md")"
contains 'a WRAPPED worker whose session process is gone stays WRAPPED, not CLOSABLE (HIMMEL-3747 Ask 1)' "$o3747b" 'workers=N641:WRAPPED'

# Control: a fatal census (pgrep itself failing) must never claim CLOSABLE --
# fail closed to WRAPPED, since "session process alive" cannot be proven.
w3747c="HIMMEL-3747-N642-unproven-2026-09-27-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3747c.md"
mkcmdline 141 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3747-N642-unproven-2026-09-27 work
mkdir -p "$W/bin-3747c"
cat > "$W/bin-3747c/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$W/bin-3747c/pgrep"
o3747c="$(PATH="$W/bin-3747c:$PATH" bash "$SUT" --workers "$W/handover/$w3747c.md")"
contains 'a fatal census must not promote a live-looking worker to CLOSABLE (HIMMEL-3747 Ask 1)' "$o3747c" 'workers=N642:WRAPPED'

# --- a relaunched worker (-r<N> session suffix) reads CLOSABLE too, and
# closable=<n> counts CLOSABLE workers whose doc has sat untouched past TICK_CLOSABLE_MIN
# minutes (default 5): the windows a chief missed, not the one it is closing now.
w5923a="HIMMEL-5923-N650-relaunch-2026-10-16-RESUME"
printf '%s\n' '# worker' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w5923a.md"
mkcmdline 142 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-5923-N650-relaunch-2026-10-16-r1 work
mk_pgrep_x "$W/bin-5923a" 142
touch -d '20 minutes ago' "$W/handover/$w5923a.md"
o5923a="$(PATH="$W/bin-5923a:$PATH" bash "$SUT" --workers "$W/handover/$w5923a.md")"
contains 'a WRAPPED worker running as <name>-r1 reads CLOSABLE (HIMMEL-5923)' "$o5923a" 'workers=N650:CLOSABLE'
contains 'an old CLOSABLE worker is counted in closable=1 (HIMMEL-5923)' "$o5923a" ' closable=1'
touch "$W/handover/$w5923a.md"
o5923b="$(PATH="$W/bin-5923a:$PATH" bash "$SUT" --workers "$W/handover/$w5923a.md")"
contains 'a freshly WRAPPED CLOSABLE worker is still CLOSABLE (HIMMEL-5923)' "$o5923b" 'workers=N650:CLOSABLE'
case "$o5923b" in *' closable='*) fail 'a fresh CLOSABLE worker must not be counted in closable= (HIMMEL-5923)' ;; *) pass 'a fresh CLOSABLE worker is not counted in closable= (HIMMEL-5923)' ;; esac
o5923c="$(PATH="$W/bin-3747b:$PATH" bash "$SUT" --workers "$W/handover/$w3747b.md")"
case "$o5923c" in *' closable='*) fail 'no CLOSABLE leg: closable= must be absent (HIMMEL-5923)' ;; *) pass 'no CLOSABLE leg: closable= is absent (HIMMEL-5923)' ;; esac

# --- a BLOCKED hand-off naming its launched successor, with the worker's own lock free, is a
# closable named hand-off: CLOSABLE and counted in closable=. A held lock, or a later ordinary
# BLOCKED after the hand-off, is a working worker. (closable=0 prints as an absent field.)
w8949a="HIMMEL-8949-N660-handoff-2026-11-04"
s8949="$W/handover/HIMMEL-8949-N660b-handoff-2026-11-04-RESUME.md"
printf '%s\n' '# successor' '' '## Results' '' '- 13:05 LIVE — resumed' > "$s8949"
printf '%s\n' '# worker' '' '## Results' '' '- 12:00 LIVE — working' "- 13:00 BLOCKED — context 80 %, RESUME written: $s8949" > "$W/handover/$w8949a.md"
mkcmdline 143 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8949-N660-handoff-2026-11-04 work
mk_pgrep_x "$W/bin-8949" 143
touch -d '20 minutes ago' "$W/handover/$w8949a.md"
o8949a="$(PATH="$W/bin-8949:$PATH" bash "$SUT" --workers "$W/handover/$w8949a.md")"
contains 'a BLOCKED hand-off naming its successor with its lock free reads CLOSABLE' "$o8949a" 'workers=N660:CLOSABLE'
contains 'a BLOCKED hand-off naming its successor with its lock free is counted in closable=1' "$o8949a" ' closable=1'
# the fixture queue-lock stub reports any *odd-name* doc as held
w8949b="HIMMEL-8949-N661-odd-name-2026-11-04"
s8949b="$W/handover/HIMMEL-8949-N661b-odd-name-2026-11-04-RESUME.md"
printf '%s\n' '# successor' '' '## Results' '' '- 13:05 LIVE — resumed' > "$s8949b"
printf '%s\n' '# worker' '' '## Results' '' '- 12:00 LIVE — working' "- 13:00 BLOCKED — context 80 %, RESUME written: $s8949b" > "$W/handover/$w8949b.md"
mkcmdline 144 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-8949-N661-odd-name-2026-11-04 work
mk_pgrep_x "$W/bin-8949b" 144
touch -d '20 minutes ago' "$W/handover/$w8949b.md"
o8949b="$(PATH="$W/bin-8949b:$PATH" bash "$SUT" --workers "$W/handover/$w8949b.md")"
case "$o8949b" in *'N661:CLOSABLE'*|*' closable='*) fail 'a BLOCKED hand-off with its lock held must not be closable' ;; *) pass 'a BLOCKED hand-off with its lock held is not closable (closable=0)' ;; esac
printf '%s\n' '- 13:30 LIVE — working again' '- 14:00 BLOCKED — waiting on CI' >> "$W/handover/$w8949a.md"
touch -d '20 minutes ago' "$W/handover/$w8949a.md"
o8949c="$(PATH="$W/bin-8949:$PATH" bash "$SUT" --workers "$W/handover/$w8949a.md")"
case "$o8949c" in *'N660:CLOSABLE'*|*' closable='*) fail 'a later ordinary BLOCKED after the hand-off must not be closable' ;; *) pass 'a later ordinary BLOCKED after the hand-off is not closable (closable=0)' ;; esac

# --- denials= (classifier-denial jsonl -> tick line, SHIP-STEP /
# REPEAT / PAUSE-RISK / none / skip). mkdenial writes one row at an offset
# (minutes before "now") so tests control window inclusion without a stale
# fixture; row shape matches scripts/hooks/log-classifier-denial.sh's fields.
mkdenial() {  # mkdenial <log> <mins-ago> <session_title> <input_head>
    ts="$(date -u -d "-${2} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","session_title":"%s","input_head":"%s"}\n' "$ts" "$3" "$4" >> "$1"
}

d3724a="$W/denials-3724a.jsonl"
: > "$d3724a"
mkdenial "$d3724a" 5 worker-a 'git push origin main'
o3724a="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724a" bash "$SUT" 2>/dev/null)"
contains 'a denied ship-step command reads SHIP-STEP (HIMMEL-3724)' "$o3724a" 'denials=worker-a:1:SHIP-STEP'

d3724b="$W/denials-3724b.jsonl"
: > "$d3724b"
mkdenial "$d3724b" 5 worker-a 'ls -la'
mkdenial "$d3724b" 3 worker-a 'cat foo'
o3724b="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724b" bash "$SUT" 2>/dev/null)"
contains '2 non-ship denials in the window read REPEAT (HIMMEL-3724)' "$o3724b" 'denials=worker-a:2:REPEAT'

d3724c="$W/denials-3724c.jsonl"
: > "$d3724c"
mkdenial "$d3724c" 5 worker-a 'ls -la'
mkdenial "$d3724c" 4 worker-a 'cat foo'
mkdenial "$d3724c" 3 worker-a 'pwd'
o3724c="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724c" bash "$SUT" 2>/dev/null)"
contains '3+ non-ship denials in the window read PAUSE-RISK (HIMMEL-3724)' "$o3724c" 'denials=worker-a:3:PAUSE-RISK'

d3724d="$W/denials-3724d.jsonl"
: > "$d3724d"
i=0
while [ "$i" -lt 17 ]; do
    mkdenial "$d3724d" 90 worker-a 'ls -la'
    i=$((i + 1))
done
mkdenial "$d3724d" 5 worker-a 'pwd'
o3724d="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724d" bash "$SUT" 2>/dev/null)"
contains 'an all-time total approaching 20 reads PAUSE-RISK even with 1 in-window (HIMMEL-3724)' "$o3724d" 'denials=worker-a:1:PAUSE-RISK'

d3724e="$W/denials-3724e.jsonl"
: > "$d3724e"
mkdenial "$d3724e" 90 worker-a 'ls -la'
o3724e="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724e" bash "$SUT" 2>/dev/null)"
contains 'a denial older than the window is excluded, reading none (HIMMEL-3724)' "$o3724e" 'denials=none'

d3724f="$W/denials-3724f.jsonl"
: > "$d3724f"
o3724f="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724f" bash "$SUT" 2>/dev/null)"
contains 'an empty log reads none (HIMMEL-3724)' "$o3724f" 'denials=none'

o3724g="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$W/denials-3724-missing.jsonl" bash "$SUT" 2>/dev/null)"
contains 'a missing log reads none, not skip: no log means no denials (HIMMEL-3724)' "$o3724g" 'denials=none'

# Non-worktree sessions group by session id (not the cwd basename), so a
# re-dispatched slug in the same directory does not inherit an old session's
# count -> no false PAUSE-RISK. Worktree rows keep the slug as their label.
mksess() {  # mksess <log> <mins-ago> <session_title> <session_id> <cwd> <input_head>
    ts="$(date -u -d "-${2} minutes" +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"ts":"%s","session_title":"%s","session_id":"%s","cwd":"%s","input_head":"%s"}\n' "$ts" "$3" "$4" "$5" "$6" >> "$1"
}
d3724s="$W/denials-3724s.jsonl"
: > "$d3724s"
mksess "$d3724s" 6 repo aaaaaaaa11111111 /home/u/repo 'ls'
mksess "$d3724s" 5 repo aaaaaaaa11111111 /home/u/repo 'cat x'
mksess "$d3724s" 4 repo bbbbbbbb22222222 /home/u/repo 'pwd'
o3724s="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724s" bash "$SUT" 2>/dev/null)"
contains 'two sessions in one non-worktree cwd get separate labels (HIMMEL-3724)' "$o3724s" 'denials=repo#aaaaaaaa:2:REPEAT,repo#bbbbbbbb:1'
not_contains 'and the second session does not inherit the first one count (HIMMEL-3724)' "$o3724s" 'PAUSE-RISK'
d3724w="$W/denials-3724w.jsonl"
: > "$d3724w"
mksess "$d3724w" 5 feat+foo cccccccc33333333 /r/.claude/worktrees/feat+foo 'ls'
o3724w="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724w" bash "$SUT" 2>/dev/null)"
contains 'a worktree row keeps the bare slug as its label (HIMMEL-3724)' "$o3724w" 'denials=feat+foo:1 '

# A window straddling a hook rotation: the earlier denial sits in <log>.1, the
# later one in the live log. Both must count (REPEAT), not just the live one.
d3724x="$W/denials-3724x.jsonl"
: > "$d3724x"
mksess "$d3724x.1" 6 repo dddddddd44444444 /home/u/repo 'ls'
mksess "$d3724x" 4 repo dddddddd44444444 /home/u/repo 'cat x'
o3724x="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724x" bash "$SUT" 2>/dev/null)"
contains 'a denial rotated into <log>.1 still counts inside the window (HIMMEL-3724)' "$o3724x" 'denials=repo#dddddddd:2:REPEAT'

# HARD RULE: input_head and reason_tag never leave the host --
# they classify locally and must not be echoed into the tick line.
d3724r="$W/denials-3724r.jsonl"
: > "$d3724r"
ts="$(date -u -d '-3 minutes' +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ts":"%s","session_title":"worker-r","input_head":"UNIQUE-HEAD-7f3a git push","reason_tag":"[UNIQUE-TAG-9c1e]"}\n' "$ts" >> "$d3724r"
o3724r="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724r" bash "$SUT" 2>/dev/null)"
contains 'a ship-step row still classifies SHIP-STEP (HIMMEL-3724)' "$o3724r" 'denials=worker-r:1:SHIP-STEP'
not_contains 'the tick line never echoes input_head (HIMMEL-3724)' "$o3724r" 'UNIQUE-HEAD-7f3a'
not_contains 'the tick line never echoes reason_tag (HIMMEL-3724)' "$o3724r" 'UNIQUE-TAG-9c1e'

# Valid non-object JSON lines (a scalar, an array) survive `fromjson?`; they
# must be dropped, not abort the slurp and hide every real denial.
d3724h="$W/denials-3724h.jsonl"
: > "$d3724h"
mkdenial "$d3724h" 5 worker-a 'git push origin main'
printf '%s\n' '5' '[1]' >> "$d3724h"
o3724h="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724h" bash "$SUT" 2>/dev/null)"
contains 'scalar and array lines in the log keep denials= populated (HIMMEL-3724)' "$o3724h" 'denials=worker-a:1:SHIP-STEP'

# A valid object whose input_head is not a string must be skipped, not make
# test() fail and turn the whole column into skip.
d3724i="$W/denials-3724i.jsonl"
: > "$d3724i"
mkdenial "$d3724i" 5 worker-a 'git push origin main'
printf '%s\n' '{"ts":"2099-01-01T00:00:00Z","session_title":"worker-b","input_head":5}' >> "$d3724i"
o3724i="$(HIMMEL_CLASSIFIER_DENIALS_LOG="$d3724i" bash "$SUT" 2>/dev/null)"
contains 'a non-string input_head row is skipped, denials= stays populated (HIMMEL-3724)' "$o3724i" 'denials=worker-a:1:SHIP-STEP'

# --- ciq= (queue-latency.sh -> compact field + SATURATED on two
# consecutive full ticks). The stub prints $STUB_CIQ_OUT verbatim, after
# STUB_CIQ_SLEEP seconds, and appends one line per call to $STUB_CIQ_CALLS.
mkdir -p "$W/repo/scripts/ci"
cat > "$W/repo/scripts/ci/queue-latency.sh" <<'STUB'
#!/usr/bin/env bash
printf 'x\n' >> "${STUB_CIQ_CALLS:-/dev/null}"
[ -z "${STUB_CIQ_SLEEP:-}" ] || sleep "$STUB_CIQ_SLEEP"
printf '%s\n' "$STUB_CIQ_OUT"
STUB
chmod +x "$W/repo/scripts/ci/queue-latency.sh"
ciq_full='ci-queue: jobs_in_progress=20/20 macos=3/5 queued=4 oldest_wait=62m'
ciq_idle='ci-queue: jobs_in_progress=0/20 macos=0/5 queued=0 oldest_wait=0m'
ciq_calls="$W/ciq-calls.txt"
ciq_tick() { STUB_CIQ_OUT="$1" STUB_CIQ_CALLS="$ciq_calls" bash "$SUT" 2>/dev/null; }

rm -rf "$W/state"; : > "$ciq_calls"
o3840a="$(ciq_tick "$ciq_idle")"
contains 'an idle queue prints the compact ciq= field (HIMMEL-3840)' "$o3840a" 'ciq=0/20,mac=0/5,q=0,wait=0m'
not_contains 'an idle queue is not flagged SATURATED (HIMMEL-3840)' "$o3840a" 'SATURATED'
calls="$(wc -l < "$ciq_calls" | tr -d '[:space:]')"
if [ "$calls" = 1 ]; then pass 'one tick runs the probe exactly once (HIMMEL-3840)'; else fail "probe calls per tick = $calls, want 1"; fi

rm -rf "$W/state"
o3840b="$(ciq_tick "$ciq_full")"
contains 'one full tick prints the field (HIMMEL-3840)' "$o3840b" 'ciq=20/20,mac=3/5,q=4,wait=62m'
not_contains 'one full tick is not yet SATURATED (HIMMEL-3840)' "$o3840b" 'SATURATED'
o3840c="$(ciq_tick "$ciq_full")"
contains 'two consecutive full ticks read SATURATED (HIMMEL-3840)' "$o3840c" 'ciq=20/20,mac=3/5,q=4,wait=62m,SATURATED'
ciq_tick "$ciq_idle" >/dev/null
o3840e="$(ciq_tick "$ciq_full")"
not_contains 'a non-full tick between two full ones resets the streak (HIMMEL-3840)' "$o3840e" 'SATURATED'

# unknown: neither sets nor clears. full, unknown, full -> SATURATED (state
# survived); idle, unknown, full -> not saturated (unknown did not set it).
rm -rf "$W/state"
ciq_tick "$ciq_full" >/dev/null
o3840f="$(ciq_tick 'ci-queue: unknown')"
contains 'a failed probe prints ciq=unknown (HIMMEL-3840)' "$o3840f" 'ciq=unknown'
o3840g="$(ciq_tick "$ciq_full")"
contains 'unknown does not clear the saturation state (HIMMEL-3840)' "$o3840g" 'SATURATED'
rm -rf "$W/state"
ciq_tick "$ciq_full" >/dev/null
ciq_tick "$ciq_idle" >/dev/null
ciq_tick 'ci-queue: unknown' >/dev/null
o3840h="$(ciq_tick "$ciq_full")"
not_contains 'unknown does not set the saturation state (HIMMEL-3840)' "$o3840h" 'SATURATED'

# a line with an empty numeric field is malformed: unknown, not a partial summary.
o3840k="$(ciq_tick 'ci-queue: jobs_in_progress=/20 macos=0/5 queued=0 oldest_wait=0m')"
contains 'an empty numeric field reads ciq=unknown (HIMMEL-3840)' "$o3840k" 'ciq=unknown'

# probe timeout: a hung probe reads unknown inside the bound and leaves state alone.
if [ -n "$_TIMEOUT_BIN" ]; then
    rm -rf "$W/state"
    ciq_tick "$ciq_full" >/dev/null
    t0="$(date +%s)"
    o3840i="$(STUB_CIQ_SLEEP=30 TICK_CIQ_TIMEOUT=1 STUB_CIQ_OUT="$ciq_full" bash "$SUT" 2>/dev/null)"
    t1="$(date +%s)"
    contains 'a hung probe reads ciq=unknown (HIMMEL-3840)' "$o3840i" 'ciq=unknown'
    if [ $((t1 - t0)) -lt 15 ]; then pass 'a hung probe is cut off inside the bound (HIMMEL-3840)'; else fail "hung probe took $((t1 - t0))s"; fi
    o3840j="$(ciq_tick "$ciq_full")"
    contains 'a timed-out probe leaves the saturation state untouched (HIMMEL-3840)' "$o3840j" 'SATURATED'
else
    skip 'probe timeout rows: no timeout binary'
fi

# --- tracker=<ok|STALE:<age>|MISSING|skip> -- the roadmap tracker page
# (roadmap-tracker.html, rendered by tracker.py next to the chief doc) is checked
# against the Jira mirror's newest updated time plus the plan files, like board=.
# RED control (pre-change tick.sh): no tracker= field, so a tracker that drifted from
# Jira is invisible. The plan dir rides on an optional `tracker-plan:` Live state line.
if command -v python3 >/dev/null 2>&1; then
    t3933_dir="$W/tracker3933"
    t3933_plan="$t3933_dir/plan"
    t3933_mir="$t3933_dir/mirror"
    t3933_out="$W/handover/roadmap-tracker.html"
    mkdir -p "$t3933_plan/stage1" "$t3933_plan/stage3" "$t3933_mir"
    printf '%s\n' '{"main_sha_at_build":"abcdef123456"}' > "$t3933_plan/stage3/meta.json"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' version load_bugs load_enhancements load_features load_misc load_audit load_total est_legs \
        v1.0.1 0.1 0 0 0 0 0.1 1 > "$t3933_plan/stage3/versions.tsv"
    printf '%s\t%s\t%s\t%s\n' key version layer effort_mid HIMMEL-1 v1.0.1 bugs 1 > "$t3933_plan/stage3/placement.tsv"
    printf '%s\t%s\t%s\n' key close_flag close_evidence > "$t3933_plan/stage3/closures.tsv"
    printf '%s\t%s\n' key reason > "$t3933_plan/stage3/unplaced.tsv"
    printf '%s\t%s\n' key theme HIMMEL-1 tooling > "$t3933_plan/stage1/C01.tsv"
    write_mirror3933() {  # write_mirror3933 <updated> <statusCategory>
        printf '%s\n' '---' 'key: "HIMMEL-1"' "updated: \"$1\"" "statusCategory: \"$2\"" 'fixVersions: ["v1.0.1"]' 'type: "Bug"' '---' '# HIMMEL-1: a planned bug' \
            > "$t3933_mir/HIMMEL-1.md"
    }
    # shellcheck disable=SC2016  # backtick worker span, literal fixture text
    write_console3933() {  # write_console3933 [tracker: value, omitted = no line]
        printf '%s\n' '# chief' '' '## Live state' '' \
            'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' 'last GO: none' 'acked: none' \
            ${1:+"tracker: $1"} "tracker-plan: $t3933_plan" '' \
            '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' > "$W/handover/chief.md"
    }
    # TRACKER_HANDOVERS_DIR: tick's --emit-fp reads live workers from the same fake bucket the render did.
    t3933() { PATH="$W/bin-3361:$PATH" TICK_TRACKER_MIRROR_DIR="$t3933_mir" TRACKER_HANDOVERS_DIR="$W/tracker3933/luna/handovers/tester/himmel" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"; }
    t3933_render() { python3 "$HERE/tracker.py" --plan-dir "$t3933_plan" --out "$t3933_out" --luna-map "$W/tracker3933/luna-map.json" --mirror-dir "$t3933_mir" --luna-root "$W/tracker3933/luna" --handovers "$W/tracker3933/luna/handovers/tester/himmel" >/dev/null; }
    rm -f "$t3933_out" "$t3933_out.fp"
    write_mirror3933 2026-09-30T10:00:00.000+0000 'To Do'
    write_console3933
    contains 'a chief with no tracker: line reads tracker=skip (HIMMEL-3933)' "$(t3933)" ' tracker=skip'
    write_console3933 none
    contains 'tracker: none reads tracker=skip (HIMMEL-3933)' "$(t3933)" ' tracker=skip'
    write_console3933 'https://claude.ai/artifact/x'
    contains 'a tracker: line with no rendered page reads tracker=MISSING (HIMMEL-3933)' "$(t3933)" ' tracker=MISSING'
    contains '--verbose labels the tracker (HIMMEL-3933)' "$(t3933 --verbose)" 'tracker: MISSING'
    t3933_render
    contains 'a freshly rendered tracker reads tracker=ok (HIMMEL-3933)' "$(t3933)" ' tracker=ok'
    # A ticket in a planned version changes status in Jira: the mirror's updated moves.
    write_mirror3933 2026-09-30T11:30:00.000+0000 Done
    touch -d '3 hours ago' "$t3933_out"  # gnu-ok: chief kit is Linux-only
    contains 'a mirror that moved past the render reads tracker=STALE:<age> (HIMMEL-3933)' "$(t3933)" ' tracker=STALE:3h'
    t3933_render
    contains 're-rendering after the change reads tracker=ok again (HIMMEL-3933)' "$(t3933)" ' tracker=ok'
    # A plan file edit is a staleness too, not only the mirror.
    printf '%s\t%s\t%s\t%s\n' HIMMEL-2 v1.0.1 bugs 1 >> "$t3933_plan/stage3/placement.tsv"
    contains 'a plan file change reads tracker=STALE (HIMMEL-3933)' "$(t3933)" ' tracker=STALE:'
    # a rendered page the chief has not republished reads REPUBLISH; a publish stamp newer than the page reads ok.
    head -n -1 "$t3933_plan/stage3/placement.tsv" > "$t3933_plan/stage3/placement.tmp" && mv "$t3933_plan/stage3/placement.tmp" "$t3933_plan/stage3/placement.tsv"
    t3933_render
    touch -d '5 hours ago' "$t3933_out.published" || exit 1  # gnu-ok: chief kit is Linux-only
    touch -d '2 hours ago' "$t3933_out" || exit 1  # gnu-ok: chief kit is Linux-only
    contains 'a page newer than its publish stamp reads tracker=REPUBLISH:<age> (HIMMEL-6483)' "$(t3933)" ' tracker=REPUBLISH:2h'
    touch "$t3933_out.published" || exit 1
    contains 'a publish stamp newer than the page reads tracker=ok (HIMMEL-6483)' "$(t3933)" ' tracker=ok'
    touch -d '1 hour' "$t3933_out" || exit 1  # gnu-ok: chief kit is Linux-only
    rm -f "$t3933_out.published"
    contains 'no publish stamp keeps reading tracker=ok (HIMMEL-6483)' "$(t3933)" ' tracker=ok'
    # a focus-owned page is written by focus-refresh.sh, which records its own fingerprint (.vfp, and sha8 in
    # focus-state) and never the all-versions .fp: the tick compares that one for such a doc.
    t7508_state() { printf 'status=ok\nstage=\ngen=3\ndirty=\nsha8=%s\nsdrift=0:0\nver=%s\nts=1\n' "$1" "${2:-}" > "$W/handover/focus-state"; }
    t7508_doc() { write_console3933 'https://claude.ai/artifact/x'; sed -i "/^tracker-plan:/a $1" "$W/handover/chief.md"; }  # gnu-ok: chief kit is Linux-only
    t3933_render || exit 1
    printf '%s\n' stale-all-versions-fp > "$t3933_out.fp"
    printf '%s\n' 0a1b2c3d4e5f6071 > "$t3933_out.vfp"
    t7508_state 0a1b2c3d
    t7508_doc 'focus-version: v1.0.1'
    contains 'a focus-owned doc whose .vfp matches the focus state reads tracker=ok (HIMMEL-7508)' "$(t3933)" ' tracker=ok'
    t7508_doc 'release: v1.0'
    contains 'a doc with a release: line and no focus-version: line is focus-owned too (HIMMEL-7508)' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d v1.0.1
    t7508_doc 'focus-version: v1.0.1'
    contains 'a focus state recording the pinned version reads tracker=ok (HIMMEL-7508)' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d v1.0.0
    contains 'a focus-version switched since the last refresh reads tracker=STALE (HIMMEL-7508)' "$(t3933)" ' tracker=STALE:'
    t7508_doc 'focus-version: auto'
    contains 'focus-version: auto keeps the recorded version out of the compare (HIMMEL-7508)' "$(t3933)" ' tracker=ok'
    t7508_doc 'release: v1.0'
    contains 'a release-only doc keeps the recorded version out of the compare (HIMMEL-7508)' "$(t3933)" ' tracker=ok'
    t7508_state 0a1b2c3d
    printf '%s\n' ffffffff00000000 > "$t3933_out.vfp"
    contains 'a focus-owned page whose .vfp differs from the focus state reads tracker=STALE (HIMMEL-7508)' "$(t3933)" ' tracker=STALE:'
    printf '%s\n' 0a1b2c3d4e5f6071 > "$t3933_out.vfp"
    t7508_doc 'focus-version: none'
    contains 'a doc the focus refresh does not own keeps the .fp comparison (HIMMEL-7508)' "$(t3933)" ' tracker=STALE:'
    t7508_doc 'focus-version: v1.0.1'
    rm -f "$W/handover/focus-state"
    contains 'no focus state falls back to the .fp comparison (HIMMEL-7508)' "$(t3933)" ' tracker=STALE:'
    rm -f "$t3933_out.vfp"
else
    skip 'tracker= rows: no python3'
fi

# --- plan-index=<ok|ok:pending|REFRESHING|FAIL:<why>|skip> -- the tick keeps the
# roadmap-plan qmd index fresh without ever waiting on it: only `plan-index.sh --check` (a
# fingerprint) runs inline; a stale index launches --refresh DETACHED. A stub qmd only, an
# --out under $W (never ~/.himmel/state). RED control (pre-change tick.sh): no plan-index= field.
if command -v python3 >/dev/null 2>&1; then
    p4051="$W/pi4051"; p4051_plan="$p4051/plan"; p4051_mir="$p4051/mirror"; p4051_out="$p4051/out"; p4051_calls="$p4051/qmd-calls"
    mkdir -p "$p4051_plan/stage1" "$p4051_plan/stage3" "$p4051_mir"
    printf 'key\ttheme\tepic\tgoals\timpact\timpact_evidence\talignment\tdeps\tdup_of\tclose_flag\tclose_evidence\tnotes\nHIMMEL-111\tKnowledge substrate\tHIMMEL-100\tG7\t2\te\t0.5\t\t\tnone\t\tn\n' > "$p4051_plan/stage1/C01.tsv"
    printf 'key\tuser_impact\tissue_plain\nHIMMEL-111\tinternal\tA plain sentence.\n' > "$p4051_plan/stage1/C01.explain.tsv"
    printf 'key\troi\tconfidence\teffort_mid\trank\tversion\tcommit\tslice_effort\tlayer\treason\nHIMMEL-111\t1\t1\t1\t1\tv1.0.1\tcommitted\t\tbugs\twhy-one\n' > "$p4051_plan/stage3/placement.tsv"
    printf '{"stage":3}\n' > "$p4051_plan/stage3/meta.json"
    echo one > "$p4051_mir/HIMMEL-111.md"
    cat > "$p4051/qmd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$QMD_CALLS"
reg="$QMD_CALLS.registered"
case "$1 ${2:-}" in
    "collection list") [ -f "$reg" ] && echo "roadmap-plan (3 files)"; exit 0 ;;
    "collection add") printf '%s\n' "$3" > "$reg"; exit 0 ;;
    "collection show") [ -f "$reg" ] && echo "Path: $(cat "$reg")"; exit 0 ;;
esac
[ -n "${QMD_SLEEP:-}" ] && [ "$1" = embed ] && sleep "$QMD_SLEEP"
if [ "${QMD_FAIL:-0}" = 1 ] && [ "$1" = embed ]; then exit 3; fi
exit 0
STUB
    chmod +x "$p4051/qmd"
    # shellcheck disable=SC2016  # backtick worker span, literal fixture text
    write_console4051() {  # write_console4051 [plan dir, omitted = no tracker-plan: line]
        printf '%s\n' '# chief' '' '## Live state' '' \
            'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' 'last GO: none' 'acked: none' \
            ${1:+"tracker-plan: $1"} '' \
            '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' > "$W/handover/chief.md"
    }
    t4051() {
        PATH="$W/bin-3361:$PATH" QMD_CALLS="$p4051_calls" ROADMAP_QMD_BIN="$p4051/qmd" TICK_PLAN_INDEX_OUT="$p4051_out" \
            TICK_TRACKER_MIRROR_DIR="$p4051_mir" bash "$SUT" --workers "$W/handover/$b3361.md" "$@"
    }
    wait4051() {  # the detached refresh writes OUT/.last-run, then its EXIT trap drops .launch (HIMMEL-4734)
        local i=0
        while { [ ! -f "$p4051_out/.last-run" ] || [ -d "$p4051_out/.launch" ]; } && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i + 1)); done
    }
    write_console4051
    not_contains 'no plan dir configured omits plan-index=' "$(t4051)" ' plan-index='
    [ ! -e "$p4051_out" ] && pass 'skip touches no state (HIMMEL-4051)' || fail 'skip created the out dir (HIMMEL-4051)'
    write_console4051 "$p4051/missing"
    not_contains 'a configured but absent plan dir omits plan-index=' "$(t4051)" ' plan-index='

    write_console4051 "$p4051_plan"
    contains 'a never-built index reads plan-index=REFRESHING (HIMMEL-4051)' "$(t4051)" ' plan-index=REFRESHING'
    wait4051
    contains 'the detached refresh embedded the collection (HIMMEL-4051)' "$(cat "$p4051_calls" 2>/dev/null)" 'embed -c roadmap-plan'
    not_contains 'after the refresh the tick omits healthy plan-index=' "$(t4051)" ' plan-index='
    contains '--verbose labels the plan index (HIMMEL-4051)' "$(t4051 --verbose)" 'plan-index: ok'
    n4051="$(wc -l < "$p4051_calls")"
    t4051 >/dev/null
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'an unchanged index never relaunches qmd (HIMMEL-4051)' || fail 'ok tick called qmd (HIMMEL-4051)'

    # a mirror change inside the minimum interval: stale but not yet due
    echo two >> "$p4051_mir/HIMMEL-111.md"
    contains 'stale but inside the minimum interval reads plan-index=ok:pending (HIMMEL-4051)' "$(t4051)" ' plan-index=ok:pending'
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'ok:pending launches no refresh (HIMMEL-4051)' || fail 'pending tick called qmd (HIMMEL-4051)'
    rm -f "$p4051_out/.last-run"
    contains 'stale and due (interval 0) reads plan-index=REFRESHING (HIMMEL-4051)' "$(TICK_PLAN_INDEX_MIN_SECS=0 t4051)" ' plan-index=REFRESHING'
    wait4051
    not_contains 'the due refresh made the index healthy again' "$(t4051)" ' plan-index='

    # a failing qmd: FAIL:<why>, and the backoff stops a relaunch every tick
    echo three >> "$p4051_mir/HIMMEL-111.md"
    rm -f "$p4051_out/.last-run"
    TICK_PLAN_INDEX_MIN_SECS=0 QMD_FAIL=1 t4051 >/dev/null
    wait4051
    contains 'a failed refresh reads plan-index=FAIL: (HIMMEL-4051)' "$(t4051)" ' plan-index=FAIL:'
    n4051="$(wc -l < "$p4051_calls")"
    t4051 >/dev/null; sleep 0.3
    [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'a recent failure is not relaunched (HIMMEL-4051)' || fail 'failure relaunched inside the backoff (HIMMEL-4051)'

    # a slow qmd never holds the tick: it returns while the refresh is still running
    echo four >> "$p4051_mir/HIMMEL-111.md"
    rm -f "$p4051_out/.last-fail" "$p4051_out/.last-run"
    s4051=$SECONDS
    o4051="$(TICK_PLAN_INDEX_MIN_SECS=0 QMD_SLEEP=4 t4051)"
    e4051=$((SECONDS - s4051))
    contains 'a slow qmd still reads plan-index=REFRESHING (HIMMEL-4051)' "$o4051" ' plan-index=REFRESHING'
    [ "$e4051" -le 2 ] && pass "the tick does not wait on the refresh (${e4051}s, HIMMEL-4051)" || fail "tick waited ${e4051}s on a 4s qmd (HIMMEL-4051)"
    contains 'while the refresh holds the lock the tick reads REFRESHING (HIMMEL-4051)' "$(t4051)" ' plan-index=REFRESHING'
    wait4051

    # an overlapping launch (OUT/.launch held) reads REFRESHING and a duplicate wrapper exits
    # without touching the live refresh's bookkeeping
    echo five >> "$p4051_mir/HIMMEL-111.md"
    mkdir "$p4051_out/.launch"; echo 77 > "$p4051_out/.last-run"
    n4051="$(wc -l < "$p4051_calls")"
    contains 'a held launch lock reads plan-index=REFRESHING (HIMMEL-4051)' "$(TICK_PLAN_INDEX_MIN_SECS=0 t4051)" ' plan-index=REFRESHING'
    # drive the PRODUCTION wrapper (not a hand copy); RED control: pre-change the
    # wrapper was inline in tick.sh, so plan-index-launch.sh is absent and the first check fails
    wrap4059="$(dirname "$SUT")/plan-index-launch.sh"
    [ -f "$wrap4059" ] && pass 'the launch wrapper is its own script (HIMMEL-4059)' || fail 'plan-index-launch.sh is missing (HIMMEL-4059)'
    bash "$wrap4059" "$p4051_out" bash -c 'echo clobbered > "$1/.last-run"' _ "$p4051_out"
    [ -f "$wrap4059" ] && [ "$(cat "$p4051_out/.last-run")" = 77 ] && [ "$(wc -l < "$p4051_calls")" -eq "$n4051" ] && pass 'a held launch lock blocks a duplicate refresh (HIMMEL-4051)' || fail 'duplicate refresh ran past .launch (HIMMEL-4051)'
    rmdir "$p4051_out/.launch"
    # a free .launch: the wrapper runs the command, records rc, and releases the lock
    bash "$wrap4059" "$p4051_out" bash -c 'exit 5'
    [ "$(cat "$p4051_out/.last-run" 2>/dev/null)" = 5 ] && [ ! -d "$p4051_out/.launch" ] && pass 'the wrapper records rc and releases .launch (HIMMEL-4059)' || fail 'wrapper did not record rc / release .launch (HIMMEL-4059)'
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"

    # a run the test guard refused (exit 77) is not a failed refresh; any other non-zero is
    echo refused >> "$p4051_mir/HIMMEL-111.md"
    # shellcheck disable=SC2016  # $1 expands in the child bash
    bash "$wrap4059" "$p4051_out" bash -c 'echo "$1"; exit 1' _ 'a real failure line'
    [ "$(cat "$p4051_out/.last-fail" 2>/dev/null)" = 'a real failure line' ] && pass 'exit 1 still writes .last-fail (HIMMEL-8820)' || fail 'exit 1 wrote no .last-fail (HIMMEL-8820)'
    contains 'exit 1 still reads plan-index=FAIL: (HIMMEL-8820)' "$(t4051)" ' plan-index=FAIL:'
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"
    # shellcheck disable=SC2016  # $1 expands in the child bash
    bash "$wrap4059" "$p4051_out" bash -c 'echo "$1"; exit 77' _ 'plan-index: refused by the test guard'
    [ ! -e "$p4051_out/.last-fail" ] && [ "$(cat "$p4051_out/.last-run" 2>/dev/null)" = 77 ] && pass 'exit 77 records rc and writes no .last-fail (HIMMEL-8820)' || fail 'exit 77 wrote .last-fail or lost rc (HIMMEL-8820)'
    not_contains 'exit 77 never reads plan-index=FAIL: (HIMMEL-8820)' "$(t4051)" ' plan-index=FAIL:'
    wait4051
    rm -f "$p4051_out/.last-run" "$p4051_out/.last-fail"

    # an --out path with a quote and a command substitution must neither run
    # text nor leave .launch behind (the old double-quoted trap re-parsed $o when it fired)
    p4051_out_save="$p4051_out"
    # shellcheck disable=SC2016  # the $( is a literal hostile path component
    p4051_out="$p4051/o\"x\$(touch $p4051/PWNED)"
    t4051 >/dev/null; wait4051
    [ ! -e "$p4051/PWNED" ] && [ -f "$p4051_out/.last-run" ] && [ ! -d "$p4051_out/.launch" ] && pass 'a hostile --out path is cleaned up without running text (HIMMEL-4059)' || fail 'hostile --out path left .launch or ran text (HIMMEL-4059)'
    p4051_out="$p4051_out_save"

    # the wrapper writes .last-run BEFORE its EXIT trap removes .launch, so a wait
    # on .last-run alone can assert inside that gap under load. RED control: a wrapper copy with
    # a sleep injected into the trap widens the gap; a .last-run-only wait4051 fails this check
    p4051_out="$p4051/o4734"; mkdir -p "$p4051_out"
    sed "s/^trap '/trap 'sleep 1; /" "$wrap4059" > "$p4051/launch4734.sh"
    bash "$p4051/launch4734.sh" "$p4051_out" true &
    wait4051
    [ -f "$p4051_out/.last-run" ] && [ ! -d "$p4051_out/.launch" ] && pass 'wait4051 waits out the .last-run-to-.launch-release gap (HIMMEL-4734)' || fail 'wait4051 returned while .launch was still held (HIMMEL-4734)'
    wait
    p4051_out="$p4051_out_save"

    # a launcher that is not installed reads FAIL:no-launcher and writes .last-fail
    p4051_out="$p4051/out-nolauncher"
    contains 'a missing launcher reads plan-index=FAIL:no-launcher (HIMMEL-4059)' "$(TICK_PLAN_INDEX_LAUNCHER=no-such-launcher-4059 t4051)" ' plan-index=FAIL:no-launcher'
    [ -s "$p4051_out/.last-fail" ] && pass 'a missing launcher writes .last-fail (HIMMEL-4059)' || fail 'no .last-fail for a missing launcher (HIMMEL-4059)'
    # one installed word must not mask a missing one
    rm -rf "$p4051_out"
    contains 'a half-installed launcher reads plan-index=FAIL:no-launcher (HIMMEL-4059)' "$(TICK_PLAN_INDEX_LAUNCHER='env no-such-launcher-4059' t4051)" ' plan-index=FAIL:no-launcher'
    rm -rf "$p4051_out"
    contains 'a blank launcher reads plan-index=FAIL:no-launcher (HIMMEL-4059)' "$(TICK_PLAN_INDEX_LAUNCHER=' ' t4051)" ' plan-index=FAIL:no-launcher'
    p4051_out="$p4051_out_save"
else
    skip 'plan-index= rows: no python3'
fi

# removing the fleet-based skip would read a metered account
# without a live OpenRouter worker; missing the field hides its effective floor.
cat > "$W/repo/scripts/lanes/openrouter-cost.sh" <<'STUB'
#!/usr/bin/env bash
printf 'read\n' >> "$OR_READS"
printf '%s\n' "${OR_READING-balance=7.50:key-limit_remaining spend=?}"
STUB
export OR_READS="$W/or-reads"
not_contains 'no live OpenRouter worker omits or=' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=0 reserved=0 total=1/8' bash "$SUT")" ' or='
[ ! -e "$OR_READS" ] && pass 'no OpenRouter worker skips all cost reads' || fail 'cost helper read without OpenRouter worker'
contains 'live OpenRouter worker surfaces smaller key cap and label' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 openrouter=1 reserved=0 total=2/8' bash "$SUT")" ' or=7.50:key-limit_remaining'
[ -f "$OR_READS" ] && pass 'live OpenRouter worker reads cost helper' || fail 'no balance read for OpenRouter worker'
contains 'unknown balance is honest' \
  "$(OR_READING='balance=? spend=?' STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT")" ' or=?'
contains 'verbose labels metered balance' \
  "$(STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT" --verbose)" 'OpenRouter: 7.50:key-limit_remaining'

contains 'OpenRouter tick bank is the lane verdict, not subscription usage' \
  "$(CADENCE_USAGE_LANE=openrouter STUB_PF_VERDICT=SKIPPED-BANK bash "$SUT")" ' usage=openrouter:SKIPPED-BANK '
case "$(CADENCE_BANK_LANE=openrouter STUB_PF_VERDICT=SKIPPED-BANK bash "$SUT")" in # old-term-ok
  *' usage=openrouter:'*) fail 'the retired CADENCE_BANK_LANE selected the OpenRouter lane' ;; # old-term-ok
  *) pass 'the retired CADENCE_BANK_LANE selects no lane' ;; # old-term-ok
esac
contains 'OpenRouter worker marker selects lane verdict' \
  "$(CADENCE_USAGE_LANE='' WORKER_SESSION_LANE=openrouter STUB_PF_VERDICT=BANK-UNKNOWN bash "$SUT")" ' usage=openrouter:BANK-UNKNOWN '
contains 'OpenRouter funded verdict surfaces without changing raw balance' \
  "$(CADENCE_USAGE_LANE=openrouter STUB_FLEET_LINE='bank-preflight: FLEET native=0 claudex=0 openrouter=1 reserved=0 total=1/8' bash "$SUT")" ' usage=openrouter:PROCEED '

# --- spare=<pct>@<h>h ---------------------------------------------
# tick reads usage-monitor.sh --spare; this stub prints STUB_SPARE verbatim (the
# projection maths is test-bank-monitor.sh's), so only tick's gating is pinned.
cat > "$W/repo/scripts/lib/usage-monitor.sh" <<'STUB'
#!/usr/bin/env bash
[ "${1:-}" = "--spare" ] || exit 2
printf '%s\n' "${STUB_SPARE-seven_day_reset_in=?  unspent_at_reset=?}"
STUB
spare_has() { case "$2" in *' spare='*) fail "$1 (out='$2')" ;; *) pass "$1" ;; esac; }
spare_out="$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=33.7' bash "$SUT")"
contains 'spare= shows when spare >= 10 and reset <= 24h (HIMMEL-4421)' "$spare_out" ' fails=? vmrun=off spare=33@6h'
spare_has 'spare= is absent below the spare threshold (HIMMEL-4421)' "$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=9.9' bash "$SUT")"
spare_has 'spare= is absent when the reset is more than 24h out (HIMMEL-4421)' "$(STUB_SPARE='seven_day_reset_in=24.5h unspent_at_reset=60.0' bash "$SUT")"
spare_has 'spare= is absent when the monitor reads ? (HIMMEL-4421)' "$(STUB_SPARE='seven_day_reset_in=? unspent_at_reset=?' bash "$SUT")"
contains 'TICK_SPARE_MIN moves the spare threshold (HIMMEL-4421)' \
  "$(TICK_SPARE_MIN=5 STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=9.9' bash "$SUT")" ' spare=9@6h'
contains 'TICK_SPARE_HOURS moves the reset window (HIMMEL-4421)' \
  "$(TICK_SPARE_HOURS=48 STUB_SPARE='seven_day_reset_in=30.0h unspent_at_reset=60.0' bash "$SUT")" ' spare=60@30h'
contains 'verbose labels spare (HIMMEL-4421)' \
  "$(STUB_SPARE='seven_day_reset_in=6.4h unspent_at_reset=33.7' bash "$SUT" --verbose)" 'spare: 33@6h'
rm -f "$W/repo/scripts/lib/usage-monitor.sh"
spare_has 'a missing usage-monitor.sh leaves spare= absent and the tick intact (HIMMEL-4421)' "$(bash "$SUT")"

# --- a READY with no GO file for 30 minutes is a wake. tails= is in the
# chief-wait action key, so the entry moving READY -> READY!stale wakes it once.
# RED control (pre-fix tick.sh): the old READY worker reads tails=N568:READY.
d4568="$W/handover/HIMMEL-4568-N568-stale-ready-2026-10-06.md"
head4568=0123456789abcdef0123456789abcdef01234567
printf '%s\n' '# worker' '- 10:00 LIVE — working' "- 10:40 READY 4568 $head4568 GREEN" > "$d4568"
tail4568() { bash "$SUT" --workers "$d4568" 2>/dev/null | sed -E 's/.* tails=([^ ]*) .*/\1/'; }
contains 'a fresh READY with no GO reads plain READY (HIMMEL-4568)' "$(tail4568)" 'N568:READY'
case "$(tail4568)" in *'!stale'*) fails=$((fails+1)); printf 'FAIL - a fresh READY must not be stale\n' ;; *) printf 'ok - a fresh READY is not stale (HIMMEL-4568)\n' ;; esac
touch -d '31 minutes ago' "$d4568"
contains 'a READY older than 30 minutes with no GO file reads READY!stale (HIMMEL-4568)' "$(tail4568)" 'N568:READY!stale'
mkdir -p "$W/handover/.locks/go"
printf 'pr=4568\nhead=%s\n' "$head4568" > "$W/handover/.locks/go/4568.$head4568"
[ "$(tail4568)" = N568:READY ] && printf 'ok - a READY with its GO file present is plain READY however old (HIMMEL-4568)\n' || { fails=$((fails+1)); printf 'FAIL - GO-present READY went stale\n'; }
rm -f "$W/handover/.locks/go/4568.$head4568"
printf '%s\n' '# worker' "- 10:40 READY 4568 $head4568 GREEN" '- 10:41 LIVE — fixing a review finding' > "$d4568"
touch -d '31 minutes ago' "$d4568"
[ "$(tail4568)" = N568:LIVE ] && printf 'ok - an old LIVE tail is never marked stale (HIMMEL-4568)\n' || { fails=$((fails+1)); printf 'FAIL - old LIVE went stale\n'; }

# --- acts= is the worker's newest actionable bullet (READY, BLOCKED, FINDING, MERGED)
# plus a count, so a READY a later LIVE/RESOLVED/SUCCESSION bullet buries, and a second
# BLOCKED after a first, still move the wake key. RED control (pre-fix tick.sh): no acts= field.
same() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
d6292="$W/handover/HIMMEL-6292-N6292-acts-2026-10-19.md"
head6292=0123456789abcdef0123456789abcdef01234567
acts6292() { bash "$SUT" --workers "$d6292" 2>/dev/null | sed -n -E 's/.* acts=([^ ]*).*/\1/p'; }
printf '%s\n' '# worker' '- 10:00 LIVE — working' "- 10:40 READY 6292 $head6292 GREEN" > "$d6292"
same 'acts= names a READY bullet (HIMMEL-6292)' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' "- 10:40 READY 6292 $head6292 GREEN" '- 10:41 LIVE — fixing a review finding' > "$d6292"
same 'acts= keeps a READY a later LIVE bullet buries (HIMMEL-6292)' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' "- 10:40 READY 6292 $head6292 GREEN" '- 10:41 SUCCESSION accepted — relay from the old chief' > "$d6292"
same 'acts= keeps a READY a later SUCCESSION bullet buries (HIMMEL-6292)' "$(acts6292)" 'N6292:READY#1'
printf '%s\n' '# worker' '- 10:00 BLOCKED — q1' '- 10:05 RESOLVED — ruling received' '- 10:20 BLOCKED — q2' > "$d6292"
same 'acts= counts a second BLOCKED so it wakes again (HIMMEL-6292)' "$(acts6292)" 'N6292:BLOCKED#2'
printf '%s\n' '# worker' '- 10:00 LIVE — working' > "$d6292"
same 'acts= is absent for a worker with no actionable bullet (HIMMEL-6292)' "$(acts6292)" ''

# --- (8349 P-A) --pool-dispositions reads stacked-series rows: a stackable ticket and a ticket held by a series
# are dispositioned (never pool-unresolved), and each key-carrying series row prints one `# pool-keys <line> <first> <keys>`.
# RED control (pre-change tick.sh): both tickets print `# pool-unresolved`, and no `# pool-keys` line exists.
pk_rows="$W/pool-series.rows"
printf 'SERIES\tLOCAL\tHIMMEL-801,HIMMEL-802\tHigh\tv1\tfiles=a.sh\n%s\n%s\n%s\n%s\n%s\n' \
    'STACKABLE HIMMEL-803 scripts/lib/a.sh' \
    '# disposition HIMMEL-801 listed SERIES HIMMEL-801' \
    '# disposition HIMMEL-803 stackable on N9 (2/4)' \
    '# disposition HIMMEL-804 collision a.sh held by series s1' \
    'LOCAL	HIMMEL-805	High	v1	plain row' > "$pk_rows"
pk_out="$(bash "$SUT" --pool-dispositions < "$pk_rows" 2>/dev/null)"
not_contains '(8349) a stackable-on ticket is not pool-unresolved' "$pk_out" 'pool-unresolved stackable HIMMEL-803 '
not_contains '(8349) a ticket held by a series is not pool-unresolved' "$pk_out" 'pool-unresolved collision HIMMEL-804 '
contains '(8349) a SERIES row prints its keys' "$pk_out" '# pool-keys 1 SERIES HIMMEL-801,HIMMEL-802'
contains '(8349) a STACKABLE row prints its key' "$pk_out" '# pool-keys 2 STACKABLE HIMMEL-803'
contains '(8349) a held-by-series disposition prints its key' "$pk_out" '# pool-keys 5 # HIMMEL-804'
same '(8349) a plain row and a listed disposition print no pool-keys line' "$(printf '%s\n' "$pk_out" | grep -c '^# pool-keys ')" '3'

dc_rel1='specs/decisions/chief-direction-2026-11-07-p1.md'
dc_rel2='specs/decisions/chief-direction-2026-11-07-p2.md'
dc_doc="$W/handover/chief-dc9502.md"
printf '%s\n' '# DC — CHIEF' '' '## Current direction' '' "Full original text of every ruling below, byte for byte, is in 2 files under the bucket ($dc_rel1 $dc_rel2). READ ALL OF THEM in your first turn." 'OPERATOR 11-05 AB, decision 5: reading.' '' '## Results' > "$dc_doc"
dc_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
dc_read() { printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"dc-%s","name":"Read","input":{"file_path":"%s/%s"}}]}}\n' "$dc_stamp" "$1" "$W/handover" "$2"; }
dc_tick() { TOKEN='' bash "$SUT" --doc "$dc_doc" 2>/dev/null; }
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"tool_use","id":"dc-0","name":"Read","input":{"file_path":"%s/chief-dc9502.md"}}]}}\n' "$dc_stamp" "$W/handover" > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) a chief transcript that never Reads the companions is flagged with the count' "$dc_out" 'ACTION direction-companions-unread=2/2'
contains '(9502) the flag names each unread companion' "$dc_out" "$dc_rel2"
dc_read 1 "$dc_rel1" >> "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) one companion Read of two leaves one flagged' "$dc_out" 'ACTION direction-companions-unread=1/2'
not_contains '(9502) the companion that was Read is not named' "$dc_out" "$dc_rel1"
dc_read 2 "$dc_rel2" >> "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
not_contains '(9502) a chief that Read every companion is not flagged' "$(dc_tick)" 'direction-companions-unread'
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"next I read %s"},{"type":"tool_use","id":"dc-9","name":"Read","input":{"file_path":"%s/%s"}}]}}\n' "$dc_stamp" "$dc_rel2" "$W/handover" "$dc_rel1" > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
dc_out="$(dc_tick)"
contains '(9502) a companion named only in message text, beside a Read of the other, is still flagged' "$dc_out" 'ACTION direction-companions-unread=1/2'
not_contains '(9502) the companion that was Read in that message is not named' "$dc_out" "$dc_rel1"
printf '{"type":"custom-title","customTitle":"someone-else"}\n' > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
not_contains '(9502) no transcript with the chief title: no guess, no flag' "$(dc_tick)" 'direction-companions-unread'
printf '{"type":"custom-title","customTitle":"chief-dc9502"}\n' > "$TICK_PROJECTS_DIR/p/dc9502.jsonl"
printf '%s\n' '# DC — CHIEF' '' '## Current direction' '' 'In work: the fixture.' '' '## Results' > "$dc_doc"
not_contains '(9502) a doc with no Full original text line is not flagged' "$(dc_tick)" 'direction-companions-unread'
rm -f "$TICK_PROJECTS_DIR/p/dc9502.jsonl" "$dc_doc"

uw_m="$W/uw-mirror/HIMMEL"; mkdir -p "$uw_m" "$W/uw-tmp" "$W/uw-dir"
uw_doc="$W/uw-dir/uw-chief.md"
uw_mirror() {
    printf '%s\n' '---' "key: \"$1\"" "statusCategory: \"$2\"" 'links:' "  blocks: ${4:-[]}" "  blocked_by: $3" '  relates: []' '---' '' "# $1" > "$uw_m/$1.md"
}
uw_live() { printf '%s\n' '# UW — CHIEF' '' '## Live state' '' "$@" '' '## Results' > "$uw_doc"; }
uw_tick() { NEXT_DISPATCH_MIRROR="$uw_m" TMPDIR="$W/uw-tmp" TOKEN='' bash "$SUT" "$@" --doc "$uw_doc" 2>/dev/null; }
uw_chains() { uw_tick --verbose | sed -n 's/^chains: //p'; }
uw_mirror HIMMEL-1 'In Progress' '[]'
uw_mirror HIMMEL-2 'To Do' '[]'
uw_live 'pool-disposition: HIMMEL-2 question after HIMMEL-1 merges'
contains '(9860) an after disposition with no blocked-by link in the mirror prints chains=UNWIRED:1' "$(uw_tick)" ' chains=UNWIRED:1'
contains '(9860) the verbose tick names the same unwired count' "$(uw_tick --verbose)" 'chains: UNWIRED:1'
uw_mirror HIMMEL-2 'To Do' '["HIMMEL-1"]'
not_contains '(9860) the wired twin (HIMMEL-2 blocked by HIMMEL-1 in the mirror) prints no UNWIRED value' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-2 'To Do' '[]'
uw_mirror HIMMEL-1 'In Progress' '[]' '["HIMMEL-2"]'
not_contains '(9860) a link read from the blocking side (HIMMEL-1 blocks HIMMEL-2) is wired too' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-1 'Done' '[]'
not_contains '(9860) a closed key does not count' "$(uw_tick)" 'UNWIRED'
uw_mirror HIMMEL-1 'In Progress' '[]'
uw_live 'pool-disposition: HIMMEL-2 slice after HIMMEL-1 lands'
contains '(9860) a slice disposition counts like a question disposition' "$(uw_tick)" ' chains=UNWIRED:1'
uw_live 'pool-disposition: HIMMEL-2 question when HIMMEL-1 merges'
not_contains '(9860) a disposition with no after clause counts nothing' "$(uw_tick)" 'UNWIRED'
uw_live 'pool-disposition: HIMMEL-2 question after HIMMEL-1 merges'
chmod 000 "$uw_m/HIMMEL-2.md"
if [ -r "$uw_m/HIMMEL-2.md" ]; then
    rm -f "$uw_m/HIMMEL-2.md"
fi
not_contains '(9860) an unreadable mirror file counts nothing' "$(uw_tick)" 'UNWIRED'
rm -f "$uw_m/HIMMEL-2.md"; uw_mirror HIMMEL-2 'To Do' '[]'
mkdir -p "$W/uw-tmp/himmel-chain-links-$UID"
printf '%s\n' 'HIMMEL-1 blocks HIMMEL-2' > "$W/uw-tmp/himmel-chain-links-$UID/$(realpath -- "$uw_doc" | sha256sum | cut -d' ' -f1)"
not_contains '(9860) a pair live-state.sh recorded as final counts nothing' "$(uw_tick)" 'UNWIRED'
rm -rf "$W/uw-tmp"
uw_mirror HIMMEL-5 'Done' '[]'
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-5"}]}]' > "$W/uw-dir/focus-chains.json"
contains '(9860) a stale focus chain and an unwired pair print chains=STALE:<n>/<m>,UNWIRED:<k>' "$(uw_tick)" ' chains=STALE:1/2,UNWIRED:1'
uw_mirror HIMMEL-2 'To Do' '["HIMMEL-1"]'
uw_stale="$(uw_chains)"
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-2"}]}]' > "$W/uw-dir/focus-chains.json"
uw_ok="$(uw_chains)"
printf '%s\n' '[{"name":"c","steps":[{"key":"HIMMEL-1"},{"key":"HIMMEL-99"}]}]' > "$W/uw-dir/focus-chains.json"
uw_skip="$(uw_chains)"
[ "$uw_stale|$uw_ok|$uw_skip" = 'STALE:1/2|ok|skip' ] && pass '(9860) with only a wired pair the STALE, ok and skip values stay byte-identical' || fail "(9860) with only a wired pair chains read $uw_stale|$uw_ok|$uw_skip, not STALE:1/2|ok|skip"
rm -rf "$W/uw-tmp" "$W/uw-mirror" "$W/uw-dir"

# (9823) the --help text describes each field without a ticket key or a decision number, and still documents the fields.
help_out="$(bash "$SUT" --help 2>&1)"
if printf '%s\n' "$help_out" | grep -qE 'HIMMEL-[0-9]|decision [0-9]'; then
    fail "(9823) tick.sh --help cites a ticket key or decision number: $(printf '%s\n' "$help_out" | grep -oE 'HIMMEL-[0-9]+|decision [0-9]+' | sort -u | tr '\n' ' ')"
else
    pass '(9823) tick.sh --help cites no ticket key and no decision number'
fi
contains '(9823) tick.sh --help still prints the usage line' "$help_out" 'usage: tick.sh [--verbose]'
for help_field in 'fleet=<live>/<cap>' 'flakes=<rows>/<suites>' 'parked=<leg>' 'holds=<leg>' 'hreg=<n>/<n>/<n>' 'chains=UNWIRED:<k>' 'review=<date>' 'cadence=<name>' 'pool-stale=<n>' 'wt-orphans=<n|unknown>'; do
    contains "(9823) tick.sh --help still documents $help_field" "$help_out" "$help_field"
done

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick.sh'
    exit 0
fi
printf 'FAIL - test-tick.sh (%s failure(s))\n' "$fails"
exit 1
