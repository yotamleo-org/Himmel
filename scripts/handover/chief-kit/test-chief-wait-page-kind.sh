#!/usr/bin/env bash
# test-chief-wait-page-kind.sh — A worker-silent alert from chief-wait.sh goes out with the
# worker-silent route kind, so chief-route.ts applies the silent rule and the operator's phone
# stays quiet; the WAKE line and the console bullet stay, and the bullet says the chief was woken.
#
# RED control (chief-wait.sh before this change): the page carries no kind, so the page seam sees
# an empty kind and the real route lands the page in the operator outbox.
#
# The page seam (CHIEF_WAIT_PAGE_CMD) is called as `$CMD <text> [kind]`; the kind is a second
# argument only when the page has one. The end-to-end rows go through the real page_send path and
# the real chief-route.ts under a scratch BRIDGE_ROOT/HOME (never a real Telegram send).
#
# Linux-only: chief-wait.sh is (PLATFORM GUARD) and this suite uses GNU timeout and stat -c.
#
# Run: bash scripts/handover/chief-kit/test-chief-wait-page-kind.sh
set -u
[ "$(uname -s)" = Linux ] || { echo "SKIP: chief-wait.sh is Linux-only"; exit 0; }
HERE="$(cd "$(dirname "$0")" && pwd)"
WAIT="${CHIEF_WAIT:-$HERE/chief-wait.sh}"
ROUTE="$HERE/../../telegram/chief-route.ts"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/chief-wait-page-kind-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
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
printf 'PROCEED\n' > "$STUB/bank"
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/off.sh"
printf '#!/usr/bin/env bash\nexit 2\n' > "$STUB/budget-off.sh"
# The page seam logs "<kind>|<text>": an empty kind means the page carried none.
cat > "$STUB/page.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "${2-}" "$1" >> "$STUB/pages"
exit 0
EOF
chmod +x "$STUB/page.sh" "$STUB/off.sh"
export STUB
export CHIEF_WAIT_TICK="$STUB/tick.sh" CHIEF_WAIT_USAGE="$STUB/bank.sh" CHIEF_WAIT_BUDGET="$STUB/budget-off.sh"
export CHIEF_WAIT_INTERVAL=1 CHIEF_WAIT_POLL_SEC=0.2 CHIEF_WAIT_FAIL_WAKE=1000 CHIEF_WAIT_PAGE_TIMEOUT=10
export WAIT_SWEEP_CMD="$STUB/off.sh" WAIT_FOCUS_CMD="$STUB/off.sh"
export HIMMEL_DENIAL_ACK_DIR="$WORK/acks"

tick_line() { # <workers> <board>
    printf 'TICK 03:00 hb=1m workers=%s livestate=ok procs=2 models=x ceiling=ok atq=0 suites=0alive/0dead prs=#10 bank=5h8/wk15/codex=? fill=40 tails=N1:LIVE inbox=none tick=UNKNOWN fleet=3/15 capacity=ok gql=4000/04:00 orphans=none nonces=ok legset=ok board=%s denials=none or=skip fails=none\n' "$1" "$2" > "$STUB/tick.line"
}
wait_exit() { # <pid>: sets rc to the waiter's exit code or "running"
    local n=0
    while [ "$n" -lt 80 ]; do
        if ! kill -0 "$1" 2>/dev/null; then wait "$1"; rc=$?; return; fi
        sleep 0.1; n=$((n + 1))
    done
    rc=running
}
start() { # <inbox> <outfile> [waiter args...]
    local inbox="$1" out="$2"; shift 2
    bash "$WAIT" "$inbox" "$@" > "$out" 2>"$out.err" &
    WPID=$!
}
# fleet <case>: sets I (inbox), WD (chief doc), WL (worker doc, aged), WM (manifest)
fleet() {
    mkdir -p "$WORK/$1/consoles"; I="$WORK/$1/consoles/c.md"; : > "$I"
    WD="$WORK/$1/chief.md"; printf '# chief\n\n## Results\n' > "$WD"
    WL="$WORK/$1/HIMMEL-1-N1-a.md"; printf '# worker\n\n## Results\n- 09:00 LIVE — started\n' > "$WL"
    touch -d "2 hours ago" "$WL"  # gnu-ok: Linux-only kit
    WM="$WORK/$1/chief.fleet.json"; printf '{"schema":1,"workers":[{"doc":"%s","label":"N1"}]}\n' "$WL" > "$WM"
    rm -f "$STUB/pages"
}
capped_tick() { tick_line "N1:FRESH" ok; sed -i 's/ denials=none/ busedge=MISSING:N1 wakerstate=N1:capped denials=none/' "$STUB/tick.line"; }  # gnu-ok: Linux-only kit
outbox_n() { local n; n="$(grep -c . "$BR/sessions/__chat__/outbox.jsonl" 2>/dev/null)"; echo "${n:-0}"; }
page_kinds() { cut -d'|' -f1 "$STUB/pages" 2>/dev/null | tr '\n' ','; }

# --- (k1) a capped-waker worker-silent page carries the worker-silent kind ---
fleet k1; capped_tick
CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_WORKER_SILENT_MIN=30 start "$I" "$WORK/k1.out" --doc "$WD" --workers-from "$WM"
wait_exit "$WPID"
check "(k1) the wait ends on the worker-silent wake" "WAKE worker-silent N1 signal=capped-waker" "$(head -n1 "$WORK/k1.out" | cut -d' ' -f1-4)"
check "(k1) one page went out" "1" "$(grep -c . "$STUB/pages" 2>/dev/null || true)"  # pipefail-ok: none set
check "(k1) the page carries kind worker-silent" "worker-silent," "$(page_kinds)"
check "(k1) the page text names the worker and the signal" "1" "$(grep -c '|WORKER-SILENT N1 signal=capped-waker' "$STUB/pages" 2>/dev/null || true)"  # pipefail-ok: none set
check "(k1) the console bullet says the chief was woken" "1" "$(grep -c '^- [0-9:]* WORKER-SILENT N1 signal=capped-waker.*the chief was woken' "$WD" || true)"  # pipefail-ok: none set
check "(k1) and no longer says the operator was alerted" "0" "$(grep -c 'the operator was alerted' "$WD" || true)"  # pipefail-ok: none set
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi

# --- (k2) a succession-partial worker-silent page carries the kind too ---
fleet k2; tick_line "N1:FRESH" ok
: > "$STUB/sp-held"; printf '%s\n' "$WL" > "$STUB/sp-held"
# shellcheck disable=SC2016  # the stub bodies expand when the stubs run
printf '#!/usr/bin/env bash\ngrep -qxF -- "$2" "$STUB/sp-held" && exit 11\nexit 0\n' > "$STUB/sp-lock.sh"
printf 'INCOMPLETE 11/18 (waiting on: N1)\n' > "$STUB/sp-succ.out"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\ncat "$STUB/sp-succ.out"\n' > "$STUB/sp-tracker.sh"
CHIEF_WAIT_PAGE_CMD="$STUB/page.sh" CHIEF_WAIT_TRACKER="$STUB/sp-tracker.sh" CHIEF_WAIT_LOCK_STATUS="$STUB/sp-lock.sh" CHIEF_WAIT_SUCCESSION_SEC=1 \
    start "$I" "$WORK/k2.out" --doc "$WD" --succession S2 --silent-min 0 --workers-from "$WM"
wait_exit "$WPID"
if [ "$rc" = running ]; then kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; fi
check "(k2) the partial prints one worker-silent wake line" "1" "$(grep -c '^WAKE worker-silent N1 signal=succession-partial' "$WORK/k2.out" || true)"  # pipefail-ok: none set
check "(k2) the page carries kind worker-silent" "worker-silent," "$(page_kinds)"
check "(k2) the console bullet is written" "1" "$(grep -c '^- [0-9:]* WORKER-SILENT N1 signal=succession-partial' "$WD" || true)"  # pipefail-ok: none set

# --- (k3) end to end: the real page_send and the real chief-route.ts apply the silent rule ---
# The page goes down chief-wait.sh's own bridge path; its sender seam hands the kind to the real
# router under a scratch BRIDGE_ROOT, so the operator outbox is what the phone would have been sent.
if command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    BR="$WORK/bridge"; HM="$WORK/home"; MIR="$WORK/mirror"; mkdir -p "$BR" "$HM" "$MIR"
    printf '{"allowFrom":["7"]}\n' > "$WORK/access.json"
    cat > "$STUB/route-sender.sh" <<'EOF'
#!/usr/bin/env bash
# MERGE_BLOCK_ALERT_CMD seam: <chat> <text> [kind] — the real router, scratch root.
if [ -n "${3-}" ]; then exec bun "$ROUTE" reply --kind "$3" "$1" "$2"; fi
exec bun "$ROUTE" reply "$1" "$2"
EOF
    chmod +x "$STUB/route-sender.sh"
    fleet k4; capped_tick
    ROUTE="$ROUTE" BRIDGE_ROOT="$BR" HOME="$HM" HIMMEL_TEST_FIXTURE=1 HIMMEL_JIRA_MIRROR="$MIR" TELEGRAM_ACCESS_PATH="$WORK/access.json" \
        MERGE_BLOCK_ALERT_CMD="$STUB/route-sender.sh" MERGE_BLOCK_ALERT_TIMEOUT_SECS=30 CHIEF_WAIT_WORKER_SILENT_MIN=30 CHIEF_WAIT_PAGE_TIMEOUT=40 \
        start "$I" "$WORK/k4.out" --doc "$WD" --workers-from "$WM"
    n=0; while [ "$n" -lt 400 ]; do kill -0 "$WPID" 2>/dev/null || break; sleep 0.1; n=$((n + 1)); done
    wait "$WPID" 2>/dev/null
    check "(k3) the wake line is printed" "1" "$(grep -c '^WAKE worker-silent N1 signal=capped-waker' "$WORK/k4.out" || true)"  # pipefail-ok: none set
    check "(k3) the console bullet is written" "1" "$(grep -c '^- [0-9:]* WORKER-SILENT N1 signal=capped-waker' "$WD" || true)"  # pipefail-ok: none set
    check "(k3) the operator outbox gets no line" "0" "$(outbox_n)"
    check "(k3) the router logged the page as silent" "1" "$(grep -c silent "$BR/route.log" 2>/dev/null | head -n1)"
    # control: the same sender with no kind (what the page was before) DOES reach the operator outbox
    ROUTE="$ROUTE" BRIDGE_ROOT="$BR" HOME="$HM" HIMMEL_TEST_FIXTURE=1 HIMMEL_JIRA_MIRROR="$MIR" "$STUB/route-sender.sh" 7 "WORKER-SILENT N1 signal=capped-waker - the chief relaunches it" >/dev/null 2>&1
    check "(k3c) control: a page with no kind lands in the operator outbox" "1" "$(outbox_n)"
else
    echo "SKIP: (k3) needs bun and jq"
fi

echo
echo "chief-wait-page-kind: $fails failed"
[ "$fails" -eq 0 ]
