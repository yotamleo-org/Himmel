#!/usr/bin/env bash
# scripts/luna/vault-stall-alert.sh must hand the message to the
# operator's chat through the shared sender seam, and fail (non-zero) when it
# cannot deliver, so vault-autosync.sh retries instead of marking the stall
# episode alerted.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SINK="$ROOT/scripts/luna/vault-stall-alert.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1 — $2"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$2', got '$3'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "SKIP all — jq not on PATH"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/vault-stall-alert.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export VAULT_STALL_ALERT_STATE="$TMP/last-finding"
printf '{"allowFrom":["4242"]}\n' >"$TMP/access.json"
printf '{"allowFrom":[]}\n' >"$TMP/empty-access.json"
cat >"$TMP/sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >>"$TMP/sent.log"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/bad-sender.sh"
chmod +x "$TMP/sender.sh" "$TMP/bad-sender.sh"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" "vault stall: hook x refused file y"
assert_eq "V1 delivered: exit 0" "0" "$?"
assert_eq "V1b sent to the operator chat with the message" \
    "4242|vault stall: hook x refused file y" "$(cat "$TMP/sent.log" 2>/dev/null)"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/bad-sender.sh" \
    bash "$SINK" "msg" 2>/dev/null
assert_eq "V2 sender failure: non-zero (autosync must retry)" "1" "$?"

: >"$TMP/sent.log"
TELEGRAM_ACCESS_PATH="$TMP/empty-access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" "msg" 2>/dev/null
assert_eq "V3 no operator id: non-zero" "1" "$?"
assert_eq "V3b nothing sent without an operator id" "" "$(cat "$TMP/sent.log")"

TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/sender.sh" \
    bash "$SINK" 2>/dev/null
assert_eq "V4 empty message: rejected (2)" "2" "$?"

cat >"$TMP/kind-sender.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$#" "\${3-}" >"$TMP/kind.log"
EOF
chmod +x "$TMP/kind-sender.sh"
kind_of() { # [<HIMMEL_ALERT_KIND>]: the argc and kind the seam received
    local rc=0
    rm -f "$TMP/kind.log" "$VAULT_STALL_ALERT_STATE"
    if [ "$#" -gt 0 ]; then
        HIMMEL_ALERT_KIND="$1" TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/kind-sender.sh" bash "$SINK" "msg" 2>/dev/null || rc=$?
    else
        env -u HIMMEL_ALERT_KIND TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/kind-sender.sh" bash "$SINK" "msg" 2>/dev/null || rc=$?
    fi
    [ "$rc" -eq 0 ] || echo "sink exit $rc"
    cat "$TMP/kind.log" 2>/dev/null
}
assert_eq "V7 a cadence kind from cadence-alert.sh reaches the seam" "3|cadence:qmd-reindex" "$(kind_of cadence:qmd-reindex)"
assert_eq "V8 no kind given: cadence:vault-stall" "3|cadence:vault-stall" "$(kind_of)"
assert_eq "V9 a kind outside the cadence family is not taken: cadence:vault-stall" "3|cadence:vault-stall" "$(kind_of worker-silent)"
assert_eq "V9b the failure-review sender's own kind reaches the seam" "3|failure-review" "$(kind_of failure-review)"
assert_eq "V9c the cache-health sender's own kind reaches the seam" "3|cache-health" "$(kind_of cache-health)"

stall() {
    printf 'vault-autosync STALL: commit refused (hook: gitleaks, file: %s) for %s min in /vault - pending changes are not being committed.' "$1" "$2"
}
send_with() {
    local s="$1"; shift
    TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_CMD="$TMP/$s" bash "$SINK" "$@" 2>/dev/null
}
sent_count() { if [ -f "$TMP/sent.log" ]; then grep -c . "$TMP/sent.log"; else echo 0; fi; }
rm -f "$TMP/sent.log" "$VAULT_STALL_ALERT_STATE"
send_with sender.sh "$(stall a/one.md 31)"; r1=$?
send_with sender.sh "$(stall a/one.md 62)"; r2=$?
send_with sender.sh "$(stall a/one.md 93)"; r3=$?
assert_eq "V10 the same finding on later passes is sent once, and every pass exits 0" "0 0 0 1" "$r1 $r2 $r3 $(sent_count)"
send_with sender.sh "$(stall b/two.md 31)"
assert_eq "V11 a changed finding is sent" "2" "$(sent_count)"
send_with sender.sh "$(stall a/one.md 40)"
assert_eq "V11b the earlier finding is sent again once another came between" "3" "$(sent_count)"
rm -f "$TMP/sent.log" "$VAULT_STALL_ALERT_STATE"
send_with bad-sender.sh "$(stall a/one.md 31)"; r1=$?
send_with sender.sh "$(stall a/one.md 62)"; r2=$?
assert_eq "V12 a send that failed is not recorded, so the next pass sends" "1 0 1" "$r1 $r2 $(sent_count)"
rm -f "$TMP/sent.log" "$VAULT_STALL_ALERT_STATE"
env -u MERGE_BLOCK_ALERT_CMD HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT='' TELEGRAM_ACCESS_PATH="$TMP/access.json" bash "$SINK" "$(stall a/one.md 31)" 2>/dev/null
r1=$?
send_with sender.sh "$(stall a/one.md 62)"
assert_eq "V13 a send the test guard refused is not recorded either" "77 1" "$r1 $(sent_count)"
rm -f "$TMP/sent.log" "$VAULT_STALL_ALERT_STATE"
HIMMEL_ALERT_KIND=cadence:qmd-reindex send_with sender.sh "same line"
HIMMEL_ALERT_KIND=cadence:qmd-reindex send_with sender.sh "same line"
assert_eq "V14 another sender's repeated line is left to that sender: both are sent" "2" "$(sent_count)"

# The fixture refusal runs everywhere; the guard's own refusal needs Linux, where the guard runs.
rc=0
env -u MERGE_BLOCK_ALERT_CMD HIMMEL_TEST_FIXTURE=1 BRIDGE_ROOT='' TELEGRAM_ACCESS_PATH="$TMP/access.json" \
    bash "$SINK" "from a test" 2>/dev/null || rc=$?
assert_eq "V5 a fixture's refused send exits 77, not delivered" "77" "$rc"
if [ "$(uname -s)" = Linux ]; then
    mkdir -p "$TMP/stub-bin"
    printf '#!/usr/bin/env bash\necho "$*" >>"%s"\n' "$TMP/bun.log" >"$TMP/stub-bin/bun"
    chmod +x "$TMP/stub-bin/bun"
    rc=0
    env -u MERGE_BLOCK_ALERT_CMD -u HIMMEL_TEST_FIXTURE PATH="$TMP/stub-bin:$PATH" HIMMEL_REAL_STATE_ASSUME_STATION=1 \
        HIMMEL_REAL_STATE_EXTRA_TOOL_DIRS="$TMP/stub-bin" TELEGRAM_ACCESS_PATH="$TMP/access.json" \
        bash "$SINK" "from a test" 2>/dev/null || rc=$?
    assert_eq "V6 the guard's refused send exits 77" "77" "$rc"
    assert_eq "V6b and bun never ran" "no" "$([ -e "$TMP/bun.log" ] && echo yes || echo no)"
fi

echo "----"
if [ "$FAILED" -eq 0 ]; then echo "PASS: vault-stall-alert ($0)"; else echo "FAIL: vault-stall-alert — $FAILED failed ($0)" >&2; exit 1; fi
