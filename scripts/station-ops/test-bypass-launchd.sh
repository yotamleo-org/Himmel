#!/usr/bin/env bash
# Tests for scripts/station-ops/bypass-launchd.sh, the go-code launch route for allowlisted HIMMEL_*_OK flags.
# Usage: bash scripts/station-ops/test-bypass-launchd.sh
# Hermetic: each row runs the daemon on a temp bucket and queue with a stub sender (records each Telegram text),
# a stub launcher (records its environment), a temp access.json and inbound journal. No Telegram, no worker.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SUT="$REPO_ROOT/scripts/station-ops/bypass-launchd.sh"
OPERATOR=4242
PASS=0
FAIL=0
pass() { printf '  PASS  %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        got: %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_contains() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "$3" ;; esac; }
assert_absent() { case "$3" in *"$2"*) fail "$1" "$3" ;; *) pass "$1" ;; esac; }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "$3"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v flock >/dev/null 2>&1 || { echo "SKIP: flock not on PATH"; exit 0; }

tmp="$(mktemp -d "${TMPDIR:-/tmp}/bypass-launchd-test.XXXXXX")" || { echo "FAIL: mktemp"; exit 1; }
DPID=""
cleanup() { [ -n "$DPID" ] && kill "$DPID" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

cat > "$tmp/send" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$BYPASSD_TEST_DIR/sent"
STUB
cat > "$tmp/launcher" <<'STUB'
#!/usr/bin/env bash
env | grep -E '^(HIMMEL_BILLED_OK|HIMMEL_HOOK_INTEGRITY_BYPASS_OK|WORKER_SESSION_EFFORT)=' | sort > "$BYPASSD_TEST_DIR/launch.env"
printf '%s\n' "$@" > "$BYPASSD_TEST_DIR/launch.args"
exit "${BYPASSD_TEST_RC:-0}"
STUB
chmod +x "$tmp/send" "$tmp/launcher"
UNTIL="$(date -u -d '+3 days' +%F)"

# setup <name>: a fresh bucket with a queue, a brief, access.json and an empty inbound journal; sets D, B, Q, BRIEF.
setup() {
    D="$tmp/$1"; B="$D/bucket"; Q="$B/bypass-queue"
    mkdir -p "$Q" "$D/bridge" "$D/run"
    BRIEF="$B/HIMMEL-1-N1-sweep-pr1.md"
    printf -- '---\ndescription: "a stub sweep brief"\n---\n# brief\n' > "$BRIEF"
    printf '{"allowFrom": ["%s"]}\n' "$OPERATOR" > "$D/access.json"
    : > "$D/bridge/inbound.jsonl"
}
# start [env...]: run the daemon in the background on the current row's bucket.
start() {
    env -u CLAUDECODE -u HIMMEL_BILLED_OK -u HIMMEL_HOOK_INTEGRITY_BYPASS_OK BYPASSD_TEST_DIR="$D" \
        BYPASSD_SEND="$tmp/send" BYPASSD_LAUNCHER="$tmp/launcher" BYPASSD_POLL=0.1 BYPASSD_SETTLE=0.5 \
        BRIDGE_ROOT="$D/bridge" TELEGRAM_ACCESS_PATH="$D/access.json" XDG_RUNTIME_DIR="$D/run" \
        "$@" bash "$SUT" --bucket "$B" --until "$UNTIL" > "$D/daemon.out" 2>&1 &
    DPID=$!
}
stop() { touch "$Q/stop"; wait "$DPID" 2>/dev/null; DPID=""; }
# wait_for <file> <text>: up to 10 s for the text to appear in the file.
wait_for() { local _; for _ in $(seq 100); do grep -qF -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1; }
# ask <name> <lines...>: drop a request and wait for its Telegram ask; sets CODE.
ask() {
    local n=$1; shift
    printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief "$@" > "$Q/$n.req"
    wait_for "$D/sent" "Reply: go " || { CODE=""; return 1; }
    CODE="$(sed -n 's/.*Reply: go \([A-Z2-9]\{6\}\) to launch.*/\1/p' "$D/sent" | tail -n 1)"
}
reply() { printf '{"from": %s, "chat_id": %s, "text": "%s", "forwarded": %s}\n' "$1" "$2" "$3" "${4:-false}" >> "$D/bridge/inbound.jsonl"; }

echo "== a billed request launches only on the operator's go code =="
setup billed-go
start
ask r flags=HIMMEL_BILLED_OK decision=921 effort=high
assert_contains "the ask names the paid run and its decision" "PAID RUN (decision 921)" "$(cat "$D/sent" 2>/dev/null)"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_contains "RED 9922: the go code launches with the billed flag set (GRANT log line)" \
    "GRANT HIMMEL-1-N1-sweep-pr1 env=HIMMEL_BILLED_OK=1 WORKER_SESSION_EFFORT=high decision=921 go=$CODE" "$(cat "$Q/daemon.log")"
assert_eq "the launcher runs with exactly the granted flag and effort" \
    "HIMMEL_BILLED_OK=1"$'\n'"WORKER_SESSION_EFFORT=high" "$(cat "$D/launch.env" 2>/dev/null)"
assert_contains "the request records the grant: go code and decision" "go=$CODE" "$(cat "$Q/r.req.done" 2>/dev/null)"
assert_contains "the launcher gets the brief and model" "claude-sonnet-5-5" "$(cat "$D/launch.args" 2>/dev/null)"
stop

echo "== a request with no go code launches nothing =="
setup no-go
start
ask r flags=HIMMEL_BILLED_OK decision=921
reply 9999 9999 "go $CODE"
reply "$OPERATOR" "$OPERATOR" "go $CODE" true
reply "$OPERATOR" "$OPERATOR" "no $CODE"
wait_for "$Q/daemon.log" "no HIMMEL-1-N1-sweep-pr1"
assert_eq "a no code, another sender's go and a forwarded go launch nothing" "no-launch r.req.no" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
assert_absent "no GRANT line without a go code" "GRANT" "$(cat "$Q/daemon.log")"
stop

echo "== refusals before any ask =="
setup refusals
start
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK,SKIP_CR > "$Q/a.req"
wait_for "$Q/daemon.log" "REFUSED flag SKIP_CR not allowlisted"
assert_eq "an unlisted flag is refused" "a.req.refused" "$(cd "$Q" && ls a.req.* 2>/dev/null)"
printf '%s\n' "brief=$BRIEF" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief flags=HIMMEL_BILLED_OK > "$Q/b.req"
wait_for "$Q/daemon.log" "REFUSED HIMMEL_BILLED_OK needs decision"
assert_eq "a billed request with no decision is refused" "b.req.refused" "$(cd "$Q" && ls b.req.* 2>/dev/null)"
printf '%s\n' "brief=/etc/passwd" model=claude-sonnet-5-5 chief=HIMMEL-nextleg-2026-11-13A-roadmap-chief > "$Q/c.req"
wait_for "$Q/daemon.log" "REFUSED malformed"
assert_eq "a brief outside the bucket is refused" "c.req.refused" "$(cd "$Q" && ls c.req.* 2>/dev/null)"
assert_absent "no refusal sends an ask" "Reply: go" "$(cat "$D/sent" 2>/dev/null)"
stop

echo "== nothing else sets the flag =="
setup inherited
start HIMMEL_BILLED_OK=1 WORKER_SESSION_EFFORT=xhigh
ask r
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCHED HIMMEL-1-N1-sweep-pr1"
assert_eq "a billed flag in the daemon's own environment does not reach a non-billed launch" \
    "HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1" "$(cat "$D/launch.env" 2>/dev/null)"
stop

echo "== a brief edited after the ask is refused after the go =="
setup changed
start
ask r flags=HIMMEL_BILLED_OK decision=921
printf 'more\n' >> "$BRIEF"
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "REFUSED after go"
assert_eq "the changed brief launches nothing" "no-launch r.req.refused" \
    "$([ -e "$D/launch.env" ] && echo launched || echo no-launch) $(cd "$Q" && ls r.req.*)"
stop

echo "== a launcher that fails is reported as failed =="
setup failed
start BYPASSD_TEST_RC=3
ask r
reply "$OPERATOR" "$OPERATOR" "go $CODE"
wait_for "$Q/daemon.log" "LAUNCH-FAILED"
assert_contains "LAUNCH-FAILED names the launcher's rc" "LAUNCH-FAILED HIMMEL-1-N1-sweep-pr1 rc=3" "$(cat "$Q/daemon.log")"
stop

echo "== start refusals =="
setup start
out=$(CLAUDECODE=1 bash "$SUT" --bucket "$B" --until "$UNTIL" 2>&1); rc=$?
assert_eq "it refuses to start inside a Claude session" "2" "$rc"
assert_contains "the refusal says why" "inside a Claude session" "$out"
out=$(env -u CLAUDECODE TELEGRAM_ACCESS_PATH="$D/access.json" bash "$SUT" --bucket "$B" --until "$(date -u -d '+30 days' +%F)" 2>&1); rc=$?
assert_eq "an --until more than 7 days ahead is refused" "2 at most 7 days ahead" "$rc ${out##*and }"
printf '{"allowFrom": []}\n' > "$D/access.json"
out=$(env -u CLAUDECODE TELEGRAM_ACCESS_PATH="$D/access.json" bash "$SUT" --bucket "$B" --until "$UNTIL" 2>&1); rc=$?
assert_eq "no operator id in access.json refuses to start" "2" "$rc"
assert_absent "a refused start writes no log" "start pid" "$(cat "$Q/daemon.log" 2>/dev/null)"

echo
echo "bypass-launchd: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
