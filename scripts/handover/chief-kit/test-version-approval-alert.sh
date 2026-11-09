#!/usr/bin/env bash
# Run: bash scripts/handover/chief-kit/test-version-approval-alert.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${VERSION_APPROVAL_ALERT:-$HERE/version-approval-alert.sh}"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { # <name> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/version-approval-alert-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/sender.sh" <<'EOF'
#!/usr/bin/env bash
n=$(( $(find "$SENT_DIR" -type f | wc -l) + 1 ))
printf '%s' "$2" > "$SENT_DIR/$n"
EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$WORK/fail.sh"
chmod +x "$WORK/sender.sh" "$WORK/fail.sh"
printf '{"allowFrom":["4242"]}\n' > "$WORK/access.json"
printf '{"allowFrom":[]}\n' > "$WORK/no-chat.json"
export TELEGRAM_ACCESS_PATH="$WORK/access.json"
export MERGE_BLOCK_ALERT_CMD="$WORK/sender.sh"
export SENT_DIR="$WORK/sent"
mkdir -p "$SENT_DIR"
sent() { find "$SENT_DIR" -type f | wc -l | tr -d ' '; }
last() { cat "$SENT_DIR/$(sent)"; }
has() { case "$2" in *"$1"*) echo yes ;; *) echo no ;; esac; }

KEY=ABC-7
printf '9001 signed' > "$WORK/words.txt"
alert() { bash "$SUT" "$KEY" v1.1.4 699 3 "$@" >/dev/null 2>&1; }

alert "$WORK/words.txt"; rc=$?
check "(a) a good send exits 0" "0" "$rc"
check "(a) one line sent" "1" "$(sent)"
text="$(last)"
check "(a) the line names the key" "yes" "$(has "$KEY" "$text")"
check "(a) the line names the version" "yes" "$(has 'in v1.1.4' "$text")"
check "(a) the line names the decision" "yes" "$(has 'decision 699' "$text")"
check "(a) the line names the open count" "yes" "$(has '3 approvals open' "$text")"
check "(a) the line leads with the words" "yes" "$(case "$text" in '"9001 signed"'*) echo yes ;; *) echo no ;; esac)"

TELEGRAM_ACCESS_PATH="$WORK/no-chat.json" alert "$WORK/words.txt"; rc=$?
check "(b) no chat id exits 1" "1" "$rc"
TELEGRAM_ACCESS_PATH="$WORK/absent.json" alert "$WORK/words.txt"; rc=$?
check "(b) no access file exits 1" "1" "$rc"
check "(b) and no sender ran" "1" "$(sent)"

MERGE_BLOCK_ALERT_CMD="$WORK/fail.sh" alert "$WORK/words.txt"; rc=$?
check "(c) a failing sender exits 1" "1" "$rc"

env -u MERGE_BLOCK_ALERT_CMD -u BRIDGE_ROOT HIMMEL_TEST_FIXTURE=1 bash "$SUT" "$KEY" v1.1.4 699 3 "$WORK/words.txt" >/dev/null 2>&1; rc=$?
check "(d) HIMMEL_TEST_FIXTURE=1 with no BRIDGE_ROOT and no seam exits 77" "77" "$rc"
check "(d) and nothing reached the seam" "1" "$(sent)"

# shellcheck disable=SC2016  # the backticks and $(...) are the literal words under test
odd='he said "go" and `rm -rf /` $(whoami) \n done'
printf '%s' "$odd" > "$WORK/odd.txt"
alert "$WORK/odd.txt"; rc=$?
check "(e) a words file with quotes and backticks exits 0" "0" "$rc"
check "(e) the words arrive unchanged" "yes" "$(has "\"$odd\"" "$(last)")"

long="$(printf 'a%.0s' $(seq 1 500))Z"
printf '%s' "$long" > "$WORK/long.txt"
alert "$WORK/long.txt"; rc=$?
text="$(last)"
check "(f) a long send exits 0" "0" "$rc"
check "(f) the 501st character is cut" "no" "$(has Z "$text")"
check "(f) the first 500 are kept" "yes" "$(has "\"${long:0:500} [" "$text")"
check "(f) the count left out is named" "yes" "$(has '501 characters, 1 left out' "$text")"
printf '%s' "${long:0:500}" > "$WORK/exact.txt"
alert "$WORK/exact.txt"
check "(f) exactly 500 characters are not cut" "no" "$(has 'left out' "$(last)")"

before="$(sent)"
alert "$WORK/absent.txt"; rc=$?
check "(g) an unreadable words file exits 1" "1" "$rc"
bash "$SUT" "$KEY" v1.1.4 699 >/dev/null 2>&1; rc=$?
check "(g) too few arguments exit 2" "2" "$rc"
check "(g) and neither sent" "$before" "$(sent)"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
