#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal payloads in the stub server source
# Tests for scripts/lib/qmd-key-probe.sh.
# Usage: bash scripts/lib/test-qmd-key-probe.sh
# Hermetic: a python3 stub HTTP server on a throwaway port stands in for the qmd
# daemon. The 401 body is the real OpenRouter reply to a keyless embeddings call
# (curl -X POST https://openrouter.ai/api/v1/embeddings, no Authorization,
# 2026-10-16: HTTP 401). Every server and probe runs under a deadline.
# Platform guard (gitbash-only): POSIX bash 3.2+; a test fixture needs no .ps1
# twin (WS5 T15 convention).
set -uo pipefail

LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="$LIB_DIR/qmd-key-probe.sh"
REAL_401='{"error":{"message":"No cookie auth credentials found","code":401}}'
TOKEN="sentinel-bearer-$$"
KEY="sentinel-provider-key-$$"

FAILED=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in: $3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1 — '$2' leaked in: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qmd-key-probe.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
SRV_PIDS=()
cleanup() {
    local p
    for p in ${SRV_PIDS[@]+"${SRV_PIDS[@]}"}; do kill -KILL "$p" 2>/dev/null; done
    rm -rf "$TMP"
}
trap cleanup EXIT

printf '%s\n' "$TOKEN" > "$TMP/token"
chmod 600 "$TMP/token"

cat > "$TMP/stub.py" <<'PY'
import http.server, json, sys, time
mode, portfile, body401 = sys.argv[1], sys.argv[2], sys.argv[3]
n = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global n
        n += 1
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        auth = self.headers.get('Authorization', '')
        if mode == 'hang':
            time.sleep(60)
        bad = mode == 'then-ok' and n == 1
        if mode == 'http401':
            code, out = 401, body401
        elif bad:
            code, out = 200, json.dumps({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": body401}], "isError": True}, "echo": auth})
        else:
            code, out = 200, json.dumps({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "ok"}]}, "echo": auth})
        data = ("event: message\ndata: " + out + "\n\n").encode() if code == 200 else out.encode()
        self.send_response(code)
        self.send_header('Content-Type', 'text/event-stream' if code == 200 else 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(s.server_address[1]))
s.serve_forever()
PY

# start_stub <mode> -> sets URL; cleanup kills the server.
start_stub() {
    local mode="$1" pf="$TMP/port.$1" i=0
    rm -f "$pf"
    timeout 120 python3 -I "$TMP/stub.py" "$mode" "$pf" "$REAL_401" >/dev/null 2>&1 &
    SRV_PIDS+=("$!")
    while [ ! -s "$pf" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    URL="http://127.0.0.1:$(cat "$pf")/mcp"
}

# run_probe <url> [timeout] -> OUT (stdout+stderr), RC
run_probe() {
    OUT=$(QMD_MCP_URL="$1" QMD_HTTP_AUTH_FILE="$TMP/token" QMD_OPENAI_API_KEY="$KEY" QMD_KEY_PROBE_TIMEOUT="${2:-10}" timeout 40 bash "$PROBE" 2>&1)
    RC=$?
}

# 1: daemon without the key answers the real 401 -> non-zero, names the key.
start_stub then-ok
run_probe "$URL"
assert_eq "401 row: probe exits 1 on the daemon's 401" 1 "$RC"
assert_has "401 row: message names QMD_OPENAI_API_KEY" "QMD_OPENAI_API_KEY" "$OUT"
assert_lacks "401 row: bearer token not echoed" "$TOKEN" "$OUT"
assert_lacks "401 row: provider key not echoed" "$KEY" "$OUT"
assert_lacks "401 row: Authorization header not echoed" "Authorization" "$OUT"

# 2: same daemon, now serving (key present) -> exit 0.
run_probe "$URL"
assert_eq "200 row: probe exits 0 once the daemon embeds" 0 "$RC"
assert_lacks "200 row: bearer token not echoed" "$TOKEN" "$OUT"
assert_lacks "200 row: provider key not echoed" "$KEY" "$OUT"

# 3: HTTP-level 401 carrying the provider body is the same defect.
start_stub http401
run_probe "$URL"
assert_eq "http401 row: exits 1" 1 "$RC"
assert_has "http401 row: names the key" "QMD_OPENAI_API_KEY" "$OUT"

# 4: a daemon that hangs is bounded and fails non-zero without naming the key.
start_stub hang
run_probe "$URL" 2
assert_eq "hang row: bounded exit 2" 2 "$RC"
assert_lacks "hang row: does not blame the key" "QMD_OPENAI_API_KEY" "$OUT"

# 5: nothing listening -> exit 2.
run_probe "http://127.0.0.1:1/mcp" 5
assert_eq "refused row: exit 2" 2 "$RC"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
