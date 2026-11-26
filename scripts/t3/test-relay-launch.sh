#!/usr/bin/env bash
set -u
unset T3_RELAY_MODEL STUB_LIST_FAIL HANDOVER_DIR
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REAL="$(cd "$HERE/../.." && pwd -P)"
RL="$HERE/relay-launch.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/relay-launch-test.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL $1"; }
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (got: $2, want: $3)"; fi; }
expect_in() { if grep -q -- "$2" "$3"; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
expect_out() { grep -q -- "$2" "$3"; case $? in 0) bad "$1 (found: $2)" ;; 1) ok "$1" ;; *) bad "$1 (grep could not read $3)" ;; esac; }
command -v jq >/dev/null 2>&1 || { echo "skip - test-relay-launch.sh: jq is required"; exit 0; }

PROF="$(cd "$REAL" && node scripts/lanes/plugin-profiles.mjs t3-relay 2>"$T/prof.err")"; rc=$?
expect_eq "t3-relay profile resolves" "$rc" 0
FLOOR="$(jq -r '.floor | sort | join(",")' "$REAL/scripts/lanes/plugin-profiles.json")"
GOT="$(printf '%s' "$PROF" | jq -r '[.enabledPlugins | to_entries[] | select(.value == true) | .key] | sort | join(",")' 2>/dev/null)"
expect_eq "t3-relay enables the floor plugins and nothing else" "$GOT" "$FLOOR"
MCP="$(cd "$REAL" && node scripts/lanes/plugin-profiles.mjs t3-relay --mcp-servers 2>/dev/null)"
expect_eq "t3-relay allow-lists the himmel-bus MCP server only" "$MCP" '["himmel-bus"]'
expect_eq "t3-relay allows only the bus send and read tools, no Bash gate rule" \
    "$(printf '%s' "$PROF" | jq -r '[.permissions.allow // [] | .[] | select(test("^mcp__(plugin_himmel-bus_)?himmel-bus__(send|read)$") | not)] | length')" 0

cat > "$T/t3" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
case "$1 $2" in
  "thread list") [ -z "${STUB_LIST_FAIL:-}" ] || exit 1; cat "$STUB_LIST" ;;
esac
STUB
chmod +x "$T/t3"
printf '# T3 relay - brief\n\nYou act only when a message arrives.\n' > "$T/brief.md"
printf '[{"threadId":"t9","title":"Some other thread","status":"idle","settled":false}]\n' > "$T/none.json"
printf '[{"threadId":"t7","title":"T3 relay (slim)","status":"idle","settled":false}]\n' > "$T/live.json"
printf '[{"threadId":"t7","title":"T3 relay (slim)","status":"idle","settled":true}]\n' > "$T/settled.json"
export T3_SEND_BIN="$T/t3" T3_SEND_PROJECT="$T" STUB_LOG="$T/log"

: > "$T/log"; STUB_LIST="$T/none.json" bash "$RL" --brief "$T/brief.md" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "launch block printed, rc 0" "$rc" 0
expect_in "block names the provider instance" "^provider: claudeAgent_t3-relay$" "$T/out"
expect_in "block names a cheap model" "^model: claude-sonnet-5-5$" "$T/out"
expect_in "block names the title" "^title: T3 relay (slim)$" "$T/out"
expect_in "block carries the brief as the first message" "^You act only when a message arrives\.$" "$T/out"
expect_out "the script never starts or sends to a thread" "^thread \(start\|send\)" "$T/log"
expect_in "the script only reads the thread list" "^thread list" "$T/log"

STUB_LIST="$T/live.json" bash "$RL" --brief "$T/brief.md" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "a second live relay is refused, rc 3" "$rc" 3
expect_in "the refusal names the live thread" "t7" "$T/err"
expect_eq "a refused launch prints no block" "$(wc -c < "$T/out" | tr -d ' ')" 0

STUB_LIST="$T/settled.json" bash "$RL" --brief "$T/brief.md" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "a settled relay does not block a new one" "$rc" 0

mkdir -p "$T/h/u/p/specs/status" && cp "$T/brief.md" "$T/h/u/p/specs/status/t3-relay-brief.md"
HANDOVER_DIR="$T/h" STUB_LIST="$T/none.json" bash "$RL" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "the default brief is found under the handover root, rc 0" "$rc" 0
expect_in "the block names the discovered brief" "^brief: $T/h/u/p/specs/status/t3-relay-brief.md$" "$T/out"
mkdir -p "$T/h/u/q/specs/status" && cp "$T/brief.md" "$T/h/u/q/specs/status/t3-relay-brief.md"
HANDOVER_DIR="$T/h" STUB_LIST="$T/none.json" bash "$RL" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "two default briefs refuse and ask for --brief, rc 2" "$rc" 2

STUB_LIST="$T/none.json" STUB_LIST_FAIL=1 bash "$RL" --brief "$T/brief.md" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "an unreadable thread list refuses, rc 4" "$rc" 4

STUB_LIST="$T/none.json" bash "$RL" --brief "$T/missing.md" >"$T/out" 2>"$T/err"; rc=$?
expect_eq "a missing brief refuses, rc 2" "$rc" 2
STUB_LIST="$T/none.json" bash "$RL" --bogus >"$T/out" 2>"$T/err"; rc=$?
expect_eq "a bad flag refuses, rc 2" "$rc" 2

DOC="$REAL/docs/internals/t3-relay.md"
expect_eq "the relay doc exists" "$([ -f "$DOC" ] && echo yes || echo no)" yes
expect_out "the relay doc never tells the relay to run keepalive.sh" "run .*keepalive\.sh" "$DOC"
expect_out "the chief doc no longer has the co-chief arm keepalive" "The co-chief arms keepalive" "$REAL/docs/handover/running-a-chief.md"

echo "relay-launch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
