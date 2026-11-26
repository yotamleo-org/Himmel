#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_REAL="$(cd "$HERE/../../.." && pwd)"
W="$HERE/chief-load-row.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/chief-load-row.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
check() { if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); fi; }
unset CLAUDE_CODE_SESSION_ID

sid=11266bbb-0000-4000-8000-000000000002
cfg="$tmp/cfg"; mkdir -p "$cfg/projects/p"
transcript() {
    printf '{"type":"custom-title","customTitle":"%s","sessionId":"%s"}\n' "$1" "$sid"
    printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m0","usage":{"input_tokens":90000},"content":[{"type":"tool_use","id":"t0","name":"Bash","input":{"command":"grep -n wake scripts/handover/chief-kit/chief-wait.sh"}}]}}\n'
    printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m00","usage":{"input_tokens":95000},"content":[{"type":"tool_use","id":"t00","name":"Bash","input":{"command":"echo '"'"';'"'"' bash chief-wait.sh '"'"'a; bash chief-wait.sh'"'"'"}}]}}\n'
    printf '{"type":"assistant","timestamp":"2026-01-01T00:00:00Z","message":{"id":"m1","usage":{"input_tokens":100000},"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"  cd /opt/kit \\u0026\\u0026 bash \\"./chief-wait.sh\\" --doc x"}}]}}\n'
    printf '{"type":"user","timestamp":"2026-01-01T00:05:00Z","message":{"role":"user","content":"<task-notification>w</task-notification>"}}\n'
    printf '{"type":"assistant","timestamp":"2026-01-01T00:05:10Z","isSidechain":true,"message":{"id":"s1","usage":{"input_tokens":900000},"content":[]}}\n'
    printf '{"type":"assistant","timestamp":"2026-01-01T00:30:00Z","message":{"id":"m2","usage":{"input_tokens":%s},"content":[]}}\n' "$2"
}
B="$tmp/bucket"; mkdir -p "$B"; rec="$B/chief-load.jsonl"
transcript S-A 460000 > "$cfg/projects/p/$sid.jsonl"
write() { CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID="$sid" bash "$W" --bucket "$B" "$@"; }

rc=0; write --shift S-A --next-shift S-B --workers-end 12 --rulings 2 --spans-unknown 3 >/dev/null 2>&1 || rc=$?
check "a row is appended (exit 0)" "$rc" "0"
check "one row in the record" "$(wc -l < "$rec" | tr -d ' ')" "1"
check "the transcript is read" "$(jq -r '.transcript' "$rec")" "read"
check "a sidechain call is not the shift's context, a command that only names or quotes chief-wait.sh is not the arm, a chained quoted run is" "$(jq -r '"\(.ctx_start) \(.ctx_end)"' "$rec")" "100000 460000"
check "the arguments land in the row" "$(jq -r '"\(.workers_end) \(.rulings) \(.spans_unknown)"' "$rec")" "12 2 3"
check "the first row of a chain has no workers_start; mean and peak are the end" "$(jq -r '"\(.workers_start) \(.workers_mean == 12) \(.workers_peak)"' "$rec")" "null true 12"
check "an end context at the 45 % fill gives reason fill" "$(jq -r '.reason' "$rec")" "fill"
check "the row's keys come in the fixed order" "$(jq -r 'keys_unsorted | .[0:3] | join(",")' "$rec")" "schema,shift,next_shift"

transcript S-B 300000 > "$cfg/projects/p/$sid.jsonl"
printf '[]\nnull\n{"partial' >> "$rec"
rc=0; write --shift S-B --next-shift S-C --workers-end 20 --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "the second shift's row is appended (exit 0)" "$rc" "0"
check "a line that is JSON but no object, or a partial last line, does not stop the next append or join it" "$(tail -n 1 "$rec" | jq -r '.shift')" "S-B"
check "workers_start is the previous shift's workers_end" "$(tail -n 1 "$rec" | jq -r '"\(.workers_start) \(.workers_mean == 16) \(.workers_peak)"')" "12 true 20"
check "an end context under the fill gives reason unstated" "$(tail -n 1 "$rec" | jq -r '.reason')" "unstated"

rc=0; write --shift S-OTHER --next-shift S-D --workers-end 1 --rulings 0 --spans-unknown 0 --reason operator-asked >/dev/null 2>&1 || rc=$?
check "a row with an unreadable transcript is still appended (exit 0)" "$rc" "0"
check "a transcript titled for another session is not read" "$(tail -n 1 "$rec" | jq -r '"\(.transcript) \(.ctx_end) \(.hours)"')" "unavailable null null"
check "--reason is recorded as given" "$(tail -n 1 "$rec" | jq -r '.reason')" "operator-asked"

rc=0; bash "$W" --bucket "$B" --shift S-E --next-shift S-F --workers-end 1 --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "a row with no session id is appended (exit 0)" "$rc" "0"
check "no session id still writes a row, transcript unavailable" "$(tail -n 1 "$rec" | jq -r '.shift + " " + .transcript')" "S-E unavailable"
check "four rows after four handovers" "$(grep -c '"schema"' "$rec")" "4"
rc=0; bash "$W" --bucket "$B" --shift S-E --next-shift S-G --workers-end 1 --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "a second row for the same shift is skipped (exit 0, still four rows)" "$rc $(grep -c '"schema"' "$rec")" "0 4"
B3="$tmp/bucket3"; mkdir -p "$B3"; mkfifo "$B3/chief-load.jsonl"
rc=0; bash "$W" --bucket "$B3" --shift S-A --next-shift S-B --workers-end 1 --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "a FIFO in the record's place is refused with exit 3, without blocking" "$rc" "3"

B2="$tmp/bucket2"; mkdir -p "$B2"; : > "$tmp/elsewhere"; ln -s "$tmp/elsewhere" "$B2/chief-load.jsonl"
rc=0; bash "$W" --bucket "$B2" --shift S-A --next-shift S-B --workers-end 1 --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "a symlinked record is refused with exit 3" "$rc" "3"
check "the symlink's target is not written" "$(wc -c < "$tmp/elsewhere" | tr -d ' ')" "0"

rc=0; bash "$W" --bucket "$B" --shift S-A >/dev/null 2>&1 || rc=$?
check "a missing argument is a usage error" "$rc" "2"
rc=0; bash "$W" --bucket "$B" --shift S-A --next-shift S-B --workers-end x --rulings 0 --spans-unknown 0 >/dev/null 2>&1 || rc=$?
check "a non-numeric count is a usage error" "$rc" "2"

writers="$(git -C "$REPO_REAL" grep -l -F 'chief-load.jsonl' -- scripts marketplace ':!*.md' ':!*/test-*.sh' | sort | tr '\n' ' ')"
check "no script but the writer and its reader names the record (one writer)" "$writers" \
    "scripts/handover/chief-kit/chief-load-report.py scripts/handover/chief-kit/chief-load-row.sh "
check "the reader opens the record read-only" "$(grep -cE "open\([^)]*['\"][aw+]" "$HERE/chief-load-report.py")" "0"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
