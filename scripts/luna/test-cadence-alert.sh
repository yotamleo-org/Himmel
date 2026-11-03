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

[ "$FAILED" -eq 0 ] || { echo "$FAILED FAILURE(S)"; exit 1; }
echo "all passed"
