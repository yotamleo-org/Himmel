#!/usr/bin/env bash
# Run: bash scripts/handover/chief-kit/test-spec-signer-alert.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/spec-signer-alert.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-signer-alert-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/sender.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(find "$SENT_DIR" -type f | wc -l) + 1 ))
printf '%s' "$2" > "$SENT_DIR/$n"
printf '%s' "${3:-}" > "$KIND_DIR/$n"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fail.sh"
chmod +x "$WORK/sender.sh" "$WORK/fail.sh"
printf '{"allowFrom":["4242"]}\n' > "$WORK/access.json"
printf '{"allowFrom":[]}\n' > "$WORK/no-chat.json"
export TELEGRAM_ACCESS_PATH="$WORK/access.json"
export MERGE_BLOCK_ALERT_CMD="$WORK/sender.sh"
export SENT_DIR="$WORK/sent"
export KIND_DIR="$WORK/kinds"
mkdir -p "$SENT_DIR" "$KIND_DIR"
sent() { find "$SENT_DIR" -type f | wc -l | tr -d ' '; }
last() { cat "$SENT_DIR/$(sent)"; }

printf 'V-1 is the operator'"'"'s to sign, slices and all' > "$WORK/mark.txt"
printf 'the operator signs V-1 himself' > "$WORK/sig.txt"

bash "$SUT" record V-1 operator 1170 "$WORK/mark.txt" "V-1 mark voids O-R1-0002 for V-1, K-1, K-2; V-1 mark voids O-R1-0003 for K-3" >/dev/null 2>&1; rc=$?
check "(a) a record send exits 0" "0" "$rc"
check "(a) the sender gets the spec-signer kind" "spec-signer" "$(cat "$KIND_DIR/1")"
check "(a) the record line, with its voids note" \
    "\"V-1 is the operator's to sign, slices and all\" — spec signer: V-1 now signed by operator, decision 1170; V-1 mark voids O-R1-0002 for V-1, K-1, K-2; V-1 mark voids O-R1-0003 for K-3" "$(last)"

bash "$SUT" record "the station default" chief 1201 "$WORK/mark.txt" >/dev/null 2>&1
check "(b) a record line with no note ends at the decision" \
    "\"V-1 is the operator's to sign, slices and all\" — spec signer: the station default now signed by chief, decision 1201" "$(last)"

bash "$SUT" signature V-1 operator 1180 "$WORK/sig.txt" "K-1, K-2" >/dev/null 2>&1; rc=$?
check "(c) a signature send exits 0" "0" "$rc"
check "(c) the signature line names the chief-signed keys" \
    "\"the operator signs V-1 himself\" — operator signature recorded for V-1, decision 1180; chief-signed in this row: K-1, K-2" "$(last)"
bash "$SUT" signature V-1 operator 1180 "$WORK/sig.txt" >/dev/null 2>&1
check "(c) a signature line with no chief keys ends at the decision" \
    "\"the operator signs V-1 himself\" — operator signature recorded for V-1, decision 1180" "$(last)"

before="$(sent)"
TELEGRAM_ACCESS_PATH="$WORK/no-chat.json" bash "$SUT" record V-1 operator 1170 "$WORK/mark.txt" >/dev/null 2>&1; rc=$?
check "(d) no chat id exits 1" "1" "$rc"
MERGE_BLOCK_ALERT_CMD="$WORK/fail.sh" bash "$SUT" record V-1 operator 1170 "$WORK/mark.txt" >/dev/null 2>&1; rc=$?
check "(d) a failing sender exits 1" "1" "$rc"
bash "$SUT" record V-1 operator 1170 "$WORK/absent.txt" >/dev/null 2>&1; rc=$?
check "(d) an unreadable words file exits 1" "1" "$rc"

env -u MERGE_BLOCK_ALERT_CMD -u BRIDGE_ROOT HIMMEL_TEST_FIXTURE=1 bash "$SUT" record V-1 operator 1170 "$WORK/mark.txt" >/dev/null 2>&1; rc=$?
check "(e) a refused send exits 77" "77" "$rc"

bash "$SUT" record V-1 operator 1170 >/dev/null 2>&1; rc=$?
check "(f) too few arguments exit 2" "2" "$rc"
bash "$SUT" mark V-1 operator 1170 "$WORK/mark.txt" >/dev/null 2>&1; rc=$?
check "(f) an unknown kind exits 2" "2" "$rc"
check "(f) and nothing failed or refused was sent" "$before" "$(sent)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
