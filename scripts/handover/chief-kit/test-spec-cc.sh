#!/usr/bin/env bash
# Run: bash scripts/handover/chief-kit/test-spec-cc.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/spec-cc.sh"

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2' got '$3')"; fi
}
contains() {
    case "$3" in *"$2"*) pass "$1" ;; *) fail "$1 (want '$2' in '$3')" ;; esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spec-cc-test.XXXXXX")" || { echo "mktemp -d failed" >&2; exit 1; }
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
export HIMMEL_TEST_FIXTURE=1
export BRIDGE_ROOT="$WORK/bridge"
export SENT_DIR="$WORK/sent"
export KIND_DIR="$WORK/kinds"
mkdir -p "$SENT_DIR" "$KIND_DIR" "$BRIDGE_ROOT"
sent() { find "$SENT_DIR" -type f | wc -l | tr -d ' '; }
last() { cat "$SENT_DIR/$(sent)"; }
queued_lines() { grep -rh document_path "$BRIDGE_ROOT" 2>/dev/null | wc -l | tr -d ' '; }

SPEC="$WORK/spec.md"
printf '# a spec\n' > "$SPEC"
SHA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
PAGE="$WORK/page.html"
printf '<!doctype html><title>spec</title>\n' > "$PAGE"

bash "$SUT" O-v1-0001 K-1 "$SPEC" "$SHA" "$PAGE" >/dev/null 2>&1; rc=$?
check "(a) a page send-file accepts exits 0" "0" "$rc"
check "(a) one document_path line is queued" "1" "$(queued_lines)"
check "(a) and no text line is sent" "0" "$(sent)"

bash "$SUT" O-v1-0002 K-1 "$SPEC" "$SHA" "$WORK/absent.html" >/dev/null 2>&1; rc=$?
check "(b) a refused page exits 0 through the text line" "0" "$rc"
check "(b) one text line is sent" "1" "$(sent)"
contains "(b) the line names the spec path" "spec $SPEC" "$(last)"
contains "(b) the line names the hash prefix" "sha256 ${SHA:0:12}" "$(last)"
contains "(b) the line names why" "no page sent: " "$(last)"
contains "(b) the line says no action is needed" "Copy, no action needed" "$(last)"
check "(b) the refused page queued nothing more" "1" "$(queued_lines)"

bash "$SUT" O-v1-0003 K-1 "$SPEC" "$SHA" - >/dev/null 2>&1; rc=$?
check "(c) no page exits 0 through the text line" "0" "$rc"
check "(c) a second text line is sent" "2" "$(sent)"
contains "(c) the line names the key and the record" "K-1 (O-v1-0003)" "$(last)"
check "(c) nothing was queued as a document" "1" "$(queued_lines)"

before="$(sent)"
MERGE_BLOCK_ALERT_CMD="$WORK/fail.sh" bash "$SUT" O-v1-0004 K-1 "$SPEC" "$SHA" - >/dev/null 2>&1; rc=$?
check "(d) a failing sender with no page exits 1" "1" "$rc"

out="$(TELEGRAM_ACCESS_PATH="$WORK/no-chat.json" bash "$SUT" O-v1-0005 K-1 "$SPEC" "$SHA" "$PAGE" 2>&1)"; rc=$?
check "(e) no operator chat id exits 1" "1" "$rc"
contains "(e) and names the chat id" "no operator chat id" "$out"
check "(e) nothing was queued or sent" "$before:1" "$(sent):$(queued_lines)"

mkdir -p "$WORK/specs/designs"
UNSEALED="$WORK/specs/designs/HIMMEL-9-unsealed.html"
printf '<!doctype html><html><head><title>spec</title></head><body>\n<p>spec</p>\n</body></html>\n' > "$UNSEALED"
before_sent="$(sent)"; before_queued="$(queued_lines)"
bash "$SUT" O-v1-0007 K-1 "$SPEC" "$SHA" "$UNSEALED" >/dev/null 2>&1; rc=$?
check "(g) an unsealed spec page is a signing send: it is refused, not sent marked DRAFT, and the text line goes" "0:$((before_sent + 1)):$before_queued" "$rc:$(sent):$(queued_lines)"

bash "$SUT" O-v1-0006 K-1 "$SPEC" >/dev/null 2>&1; rc=$?
check "(f) too few arguments exit 2" "2" "$rc"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "$fails FAILED"; exit 1
