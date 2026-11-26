#!/usr/bin/env bash
# scripts/luna/cadence-alert.sh: a qmd-reindex rc-5 alert quotes the remaining
# hash count and the last provider error from the runner's reindex-state file
# ; an explicit cause wins; any other worker or reason keeps the default.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINK="$ROOT/scripts/luna/cadence-alert.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_has() { case "$3" in *"$2"*) pass "$1" ;; *) fail "$1" "wanted '$2' in '$3'" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) fail "$1" "did not want '$2' in '$3'" ;; *) pass "$1" ;; esac; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/cadence-alert.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >"$TMP/sent.msg"
EOF
chmod +x "$TMP/sender.sh"
# The state file a stubbed incomplete embed leaves (qmd-reindex.sh write_reindex_state).
printf 'ts=2026-10-31T01:05:00Z\nrc=5\nremaining=370\nlast_error=embed: request failed status=503 provider=DeepInfra\nsummary=370 unique hashes still need vectors; last provider error: embed: request failed status=503 provider=DeepInfra\n' >"$TMP/reindex-state"

# fail <worker> <reason> [<cause>]: the message the sender was handed
alert() {
    local arc=0
    rm -f "$TMP/sent.msg"; rm -rf "$TMP/sent"
    CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/sent" CADENCE_ALERT_SEND_CMD="${SENDER:-$TMP/sender.sh}" \
        CADENCE_ALERT_SEND_FAILED_MARK="$TMP/send-failed" CADENCE_ALERT_QMD_STATE="$TMP/${STATE_FILE:-reindex-state}" \
        CADENCE_ALERT_EXIT_ON_SEND_FAIL=1 bash "$SINK" fail "$@" >/dev/null 2>&1 || arc=$?
    # A sink that did not deliver must fail the assertions below, not hide behind a written message.
    [ "$arc" -eq 0 ] || printf 'ALERT-EXIT-%s ' "$arc"
    cat "$TMP/sent.msg" 2>/dev/null || true
}

msg=$(alert qmd-reindex rc-5 /tmp/q.log)
assert_has "A1 rc-5 quotes the remaining hash count" "Cause: 370 unique hashes still need vectors" "$msg"
assert_has "A1b rc-5 quotes the last provider error" "last provider error: embed: request failed status=503 provider=DeepInfra" "$msg"

msg=$(alert qmd-reindex rc-5 /tmp/q.log "my own cause")
assert_has "A2 an explicit cause wins" "Cause: my own cause" "$msg"
assert_lacks "A2b the state file is not quoted over it" "370 unique hashes" "$msg"

msg=$(alert qmd-reindex rc-3 /tmp/q.log)
assert_has "A3 another rc keeps the default cause" "Cause: unknown, see log" "$msg"

msg=$(alert graphmap-luna rc-5 /tmp/g.log)
assert_has "A4 another worker keeps the default cause" "Cause: unknown, see log" "$msg"

printf 'ts=2026-10-31T01:05:00Z\nrc=0\nremaining=0\nlast_error=none\nsummary=0 unique hashes still need vectors\n' >"$TMP/clean-state"
msg=$(STATE_FILE=clean-state alert qmd-reindex rc-5 /tmp/q.log)
assert_has "A6 a clean run's state is not quoted for an rc-5 alert" "Cause: unknown, see log" "$msg"

msg=$(alert qmd-reindex rc-5)
assert_has "A7 rc-5 with no log argument still quotes the state under nounset" "Cause: 370 unique hashes still need vectors" "$msg"

cat >"$TMP/bad-sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >"$TMP/sent.msg"
exit 1
EOF
chmod +x "$TMP/bad-sender.sh"
msg=$(SENDER="$TMP/bad-sender.sh" alert qmd-reindex rc-5 /tmp/q.log)
assert_has "A8 a sender that writes the message then fails is reported as a failed alert" "ALERT-EXIT-1" "$msg"

msg=$(STATE_FILE=absent alert qmd-reindex rc-5 /tmp/q.log)
assert_has "A5 no state file keeps the default cause" "Cause: unknown, see log" "$msg"

# A sender exiting 77 was refused by the test guard: neither delivered nor failed.
printf '#!/usr/bin/env bash\nexit 77\n' >"$TMP/refused-sender.sh"
chmod +x "$TMP/refused-sender.sh"
sent_files() { find "$TMP/sent" -type f 2>/dev/null | wc -l | tr -d ' '; }
rm -f "$TMP/send-failed"
msg=$(SENDER="$TMP/refused-sender.sh" alert worker-a rc-1 /tmp/q.log)
assert_has "A9 a refused send still reads as not delivered to a caller that must retry" "ALERT-EXIT-1" "$msg"
assert_has "A9b a refused send leaves no dedupe sentinel" "sentinels=0" "sentinels=$(sent_files)"
assert_has "A9c a refused send writes no send-failed marker" "mark=no" "mark=$([ -e "$TMP/send-failed" ] && echo yes || echo no)"
SENDER="$TMP/bad-sender.sh" alert worker-a rc-1 /tmp/q.log >/dev/null
SENDER="$TMP/refused-sender.sh" alert worker-a rc-1 /tmp/q.log >/dev/null
assert_has "A9d a refused send does not clear a real failure's marker" "mark=yes" "mark=$([ -e "$TMP/send-failed" ] && echo yes || echo no)"
refused_err=$(CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/sent-err" CADENCE_ALERT_SEND_CMD="$TMP/refused-sender.sh" \
    CADENCE_ALERT_SEND_FAILED_MARK="$TMP/send-failed" bash "$SINK" fail worker-a rc-1 /tmp/q.log 2>&1)
assert_has "A9e it says refused" "refused by the test guard" "$refused_err"
assert_lacks "A9f it does not say the send failed" "send failed" "$refused_err"
alert worker-a rc-1 /tmp/q.log >/dev/null
assert_has "A9g control: a delivered send writes the sentinel" "sentinels=1" "sentinels=$(sent_files)"
assert_has "A9h control: a delivered send clears the marker" "mark=no" "mark=$([ -e "$TMP/send-failed" ] && echo yes || echo no)"

cat >"$TMP/kind-sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s|%s\n' "\$#" "\${HIMMEL_ALERT_KIND-unset}" "\$1" >"$TMP/sent.msg"
EOF
chmod +x "$TMP/kind-sender.sh"
msg=$(SENDER="$TMP/kind-sender.sh" alert qmd-reindex rc-3 /tmp/q.log)
assert_has "K1 the sender gets HIMMEL_ALERT_KIND=cadence:<worker> and the message as its only argument" "1|cadence:qmd-reindex|qmd-reindex: rc-3." "$msg"
msg=$(SENDER="$TMP/kind-sender.sh" alert 'odd worker.x' rc-3 /tmp/q.log)
assert_has "K2 the kind carries the worker's sentinel slug" "|cadence:odd_worker_x|" "$msg"

if command -v bun >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    cat >"$TMP/route-sender.sh" <<'EOF'
#!/usr/bin/env bash
if [ -n "${3-}" ]; then exec bun "$ROUTE_TS" reply --kind "$3" "$1" "$2"; fi
exec bun "$ROUTE_TS" reply "$1" "$2"
EOF
    chmod +x "$TMP/route-sender.sh"
    printf '{"allowFrom":["4242"]}\n' >"$TMP/access.json"
    chain() { # <case> <worker>: one cadence failure through the default sender into <case>/bridge
        mkdir -p "$TMP/$1/home" "$TMP/$1/mirror"
        env -u TELEGRAM_MONITOR_CHAT_ID -u TELEGRAM_MONITOR_BOT_TOKEN -u CADENCE_ALERT_SEND_CMD -u HIMMEL_ALERT_KIND \
            ROUTE_TS="$ROOT/scripts/telegram/chief-route.ts" BRIDGE_ROOT="$TMP/$1/bridge" HOME="$TMP/$1/home" HIMMEL_TEST_FIXTURE=1 \
            HIMMEL_JIRA_MIRROR="$TMP/$1/mirror" TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/route-sender.sh" \
            CADENCE_ALERT_FILE="$TMP/$1/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/$1/sent" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/$1/send-failed" \
            CADENCE_ALERT_QMD_STATE="$TMP/absent" bash "$SINK" fail "$2" rc-3 /tmp/q.log >/dev/null 2>&1
    }
    lines() { local n; n="$(grep -c . "$1" 2>/dev/null)"; echo "${n:-0}"; }
    chain r1 qmd-reindex
    assert_has "K3 a monitor-class cadence kind lands in the monitor outbox, kept on the station with the monitoring chat unset" \
        "monitor=1" "monitor=$(lines "$TMP/r1/bridge/monitor/outbox.jsonl")"
    assert_has "K3b its line names the kind" '"kind":"cadence:qmd-reindex"' "$(cat "$TMP/r1/bridge/monitor/outbox.jsonl" 2>/dev/null)"
    assert_has "K3c and it stays off the operator outbox" "operator=0" "operator=$(lines "$TMP/r1/bridge/sessions/__chat__/outbox.jsonl")"
    chain r2 zz-nowhere
    assert_has "K4 control: a cadence kind with no table row still reaches the operator outbox" "operator=1" "operator=$(lines "$TMP/r2/bridge/sessions/__chat__/outbox.jsonl")"
    assert_has "K4b and nothing goes to the monitor outbox" "monitor=0" "monitor=$(lines "$TMP/r2/bridge/monitor/outbox.jsonl")"
else
    echo "SKIP K3-K4: the chain rows need bun and jq"
fi


if command -v jq >/dev/null 2>&1; then
    RC="$TMP/recover"; mkdir -p "$RC"
    printf '{"allowFrom":["4242"]}\n' >"$RC/access.json"
    cat >"$RC/sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$2" >>"$RC/sent.log"
EOF
    printf '#!/usr/bin/env bash\nexit 0\n' >"$RC/sweep.sh"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$RC/inbox-send.sh"
    chmod +x "$RC/sender.sh" "$RC/sweep.sh" "$RC/inbox-send.sh"
    recover_run() {
        FAILURE_ROUTE_SWEEP_CMD="$RC/sweep.sh" FAILURE_ROUTE_INBOX_SEND="$RC/inbox-send.sh" \
            TELEGRAM_ACCESS_PATH="$RC/access.json" MERGE_BLOCK_ALERT_CMD="$RC/sender.sh" VAULT_STALL_ALERT_STATE="$RC/last" \
            CADENCE_ALERT_SEND_CMD="$ROOT/scripts/luna/vault-stall-alert.sh" CADENCE_ALERT_FILE="$RC/alerts.log" \
            CADENCE_ALERT_DEDUPE_DIR="$RC/sent" CADENCE_ALERT_SEND_FAILED_MARK="$RC/send-failed" bash "$SINK" "$@" >/dev/null 2>&1
    }
    sends() { local n; n="$(grep -c . "$RC/sent.log" 2>/dev/null)"; echo "${n:-0}"; }
    recover_run fail vault-stall "unremediable: gitleaks generic-api-key notes/a.md:9" /tmp/v.log
    recover_run fail vault-stall "unremediable: gitleaks generic-api-key notes/a.md:9" /tmp/v.log
    assert_has "R1 a stall is alerted once while it lasts" "sends=1" "sends=$(sends)"
    recover_run clear vault-stall
    recover_run fail vault-stall "unremediable: gitleaks generic-api-key notes/a.md:9" /tmp/v.log
    assert_has "R2 the same finding after a recovery is alerted again" "sends=2" "sends=$(sends)"
    recover_run clear some-other-worker
    assert_has "R3 another worker's recovery leaves the vault-stall record" "record=yes" "record=$([ -s "$RC/last" ] && echo yes || echo no)"
    recover_run clear vault-stall
    assert_has "R3b the vault-stall recovery removes it" "record=no" "record=$([ -e "$RC/last" ] && echo yes || echo no)"
    if command -v flock >/dev/null 2>&1; then
        exec 8>"$RC/last.lock"
        flock 8
        recover_run clear vault-stall 8>&- &
        clearer=$!
        printf 'in-flight\n' >"$RC/last"
        exec 8>&-
        wait "$clearer"
        assert_has "R4 a recovery waits for a delivery in flight and then removes its record" "record=no" "record=$([ -e "$RC/last" ] && echo yes || echo no)"
    fi
    mkdir -p "$RC/bare/scripts/luna"
    cp "$SINK" "$RC/bare/scripts/luna/"
    printf 'kept\n' >"$RC/last"
    VAULT_STALL_ALERT_STATE="$RC/last" CADENCE_ALERT_DEDUPE_DIR="$RC/sent" bash "$RC/bare/scripts/luna/cadence-alert.sh" clear vault-stall >/dev/null 2>&1
    assert_has "R5 a copy with no lib/prim.sh never removes the record without the lock" "record=yes" "record=$([ -s "$RC/last" ] && echo yes || echo no)"
else
    echo "SKIP R1-R3: the recovery rows need jq"
fi

[ "$FAILED" -eq 0 ] || { echo "$FAILED FAILURE(S)"; exit 1; }
echo "all passed"
