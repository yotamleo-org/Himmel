#!/usr/bin/env bash
set -uo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$KIT/file-chief-miss.sh"

pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
    else fail=$((fail+1)); printf '  FAIL %s\n       got:  %s\n       want: %s\n' "$1" "$2" "$3"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-file-chief-miss.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/calls.log"

cat > "$TMP/jira-stub.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_LOG"
if [ "${1:-}" = create ]; then
    [ -n "${STUB_CREATE_FAIL:-}" ] && { echo "jira: refused" >&2; exit 1; }
    echo "Created DEMO-9001"
fi
exit 0
STUB
chmod +x "$TMP/jira-stub.sh"

run() { : > "$LOG"; STUB_LOG="$LOG" FILE_CHIEF_MISS_JIRA_CLI="$TMP/jira-stub.sh" bash "$SCRIPT" "$@" 2>&1; }

if [ ! -f "$SCRIPT" ]; then check 'file-chief-miss.sh exists' absent present; printf '%s passed, %s failed\n' "$pass" "$fail"; exit 1; fi

out=$(run --kind wake --type Task --title 'Chief: missed wake' --labels standalone)
rc=$?
check 'wake filing exits 0' "$rc" 0
check 'wake filing prints the created key' "$(printf '%s' "$out" | grep -c 'Created DEMO-9001')" 1
check 'wake filing carries chief-miss beside the caller labels' "$(grep -c '^create .*--labels standalone,chief-miss' "$LOG")" 1
check 'wake filing keeps the caller args' "$(grep -c -- '--type Task --title Chief: missed wake' "$LOG")" 1
check 'wake filing records its kind on the new ticket' "$(grep -c '^comment DEMO-9001 chief-miss kind: wake' "$LOG")" 1

run --kind relay --type Task --title t >/dev/null
check 'no caller labels: chief-miss alone' "$(grep -c '^create .*--labels chief-miss' "$LOG")" 1

for k in wake relay go unowned; do
    run --kind "$k" --type Task --title t >/dev/null
    check "kind $k accepted" "$?" 0
done

out=$(run --type Task --title t)
rc=$?
check 'no kind refused' "$rc" 2
check 'no kind files nothing' "$(wc -c < "$LOG" | tr -d ' ')" 0
check 'no kind names the kinds' "$(printf '%s' "$out" | grep -c 'wake|relay|go|unowned')" 1
out=$(run --kind other --type Task --title t)
rc=$?
check 'unknown kind refused' "$rc" 2
check 'unknown kind files nothing' "$(wc -c < "$LOG" | tr -d ' ')" 0

: > "$LOG"; STUB_LOG="$LOG" "$TMP/jira-stub.sh" create --type Task --title t --labels standalone >/dev/null
check 'control: a plain create carries no chief-miss' "$(grep -c chief-miss "$LOG")" 0

out=$(STUB_CREATE_FAIL=1 run --kind go --type Task --title t)
rc=$?
check 'refused create exits non-zero' "$rc" 1
check 'refused create posts no comment' "$(grep -c '^comment' "$LOG")" 0

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
