#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal payloads in the stub server source
# Tests for scripts/lib/qmd-key-probe.sh.
# Usage: bash scripts/lib/test-qmd-key-probe.sh
# Hermetic: a python3 stub HTTP server on a throwaway port stands in for the qmd
# daemon (it arms its own 120 s alarm and is killed directly by pid on exit). The 401 body is the real OpenRouter reply to a keyless embeddings call
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
import http.server, json, signal, sys, time
signal.alarm(120)
mode, portfile, body401, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
n = 0
class H(http.server.BaseHTTPRequestHandler):
    def reply(self, code, data, ctype):
        self.send_response(code)
        self.send_header('Content-Type', ctype)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_POST(self):
        global n
        n += 1
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        auth = self.headers.get('Authorization', '')
        open(portfile + '.auth', 'w').write(auth)
        if mode == 'needauth' and auth != 'Bearer ' + want:
            return self.reply(403, b'{"error":"forbidden"}', 'application/json')
        if mode == 'hang':
            time.sleep(60)
        if mode == 'multi':
            note = json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"data": "working"}})
            res = json.dumps({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "ok"}]}})
            return self.reply(200, ("event: message\ndata: " + note + "\n\nevent: message\ndata: " + res + "\n\n").encode(), 'text/event-stream')
        if mode == 'rpc401':
            return self.reply(200, ("data: " + json.dumps({"jsonrpc": "2.0", "id": 2, "error": {"code": -32000, "message": "401 Unauthorized"}}) + "\n\n").encode(), 'text/event-stream')
        if mode == 'text401':
            return self.reply(200, ("data: " + json.dumps({"jsonrpc": "2.0", "id": 2, "result": {"content": [{"type": "text", "text": "Error: 401 Unauthorized"}]}}) + "\n\n").encode(), 'text/event-stream')
        bad = mode == 'then-ok' and n == 1
        if mode == 'empty':
            self.send_response(200)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
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
    python3 -I "$TMP/stub.py" "$mode" "$pf" "$REAL_401" "$TOKEN" >/dev/null 2>&1 &
    SRV_PIDS+=("$!")
    while [ ! -s "$pf" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    URL="http://127.0.0.1:$(cat "$pf")/mcp"
}

# run_probe <url> [timeout] -> OUT (stdout+stderr), RC
run_probe() {
    OUT=$(QMD_MCP_URL="$1" QMD_HTTP_AUTH_FILE="${AUTH:-$TMP/token}" QMD_OPENAI_API_KEY="$KEY" QMD_KEY_PROBE_TIMEOUT="${2:-10}" timeout 40 bash "$PROBE" 2>&1)
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

# 4b: an empty 200 reply embedded nothing -> exit 2, never success.
start_stub empty
run_probe "$URL"
assert_eq "empty row: exit 2" 2 "$RC"

# 4c: a zero-padded deadline is decimal, not an octal arithmetic error.
start_stub then-ok
run_probe "$URL" >/dev/null
run_probe "$URL" 08
assert_eq "leading-zero timeout row: exit 0" 0 "$RC"

# 5: nothing listening -> exit 2.
run_probe "http://127.0.0.1:1/mcp" 5
assert_eq "refused row: exit 2" 2 "$RC"

# 6: the bearer arrives, and a wrong one is refused with its own message.
start_stub needauth
run_probe "$URL"
assert_eq "needauth row: right token exits 0" 0 "$RC"
assert_eq "needauth row: Authorization header arrived" "Bearer $TOKEN" "$(cat "$TMP/port.needauth.auth")"
printf 'wrong-token\n' > "$TMP/wrong"
chmod 600 "$TMP/wrong"
AUTH="$TMP/wrong" run_probe "$URL"
assert_eq "bearer-refusal row: exit 2" 2 "$RC"
assert_has "bearer-refusal row: names the token file" "QMD_HTTP_AUTH_FILE" "$OUT"
assert_lacks "bearer-refusal row: does not blame the key" "QMD_OPENAI_API_KEY" "$OUT"
assert_lacks "bearer-refusal row: wrong token not echoed" "wrong-token" "$OUT"

# 7: a URL that starts with a dash is a URL, not a curl option.
AUTH="$TMP/absent" run_probe "--version" 5
assert_eq "dash-url row: exit 2" 2 "$RC"
assert_has "dash-url row: curl treated it as a host" "curl rc=6" "$OUT"

# 8: the bearer goes to loopback hosts only.
run_probe "http://192.0.2.1:9/mcp" 2
assert_eq "non-loopback row: exit 2" 2 "$RC"
assert_has "non-loopback row: says loopback" "loopback" "$OUT"
run_probe "http://127.0.0.1@192.0.2.1:9/mcp" 2
assert_has "userinfo row: host is the part after @" "loopback" "$OUT"
run_probe "http://127.0.0.1.example.invalid:9/mcp" 2
assert_has "lookalike row: 127.0.0.1.example is not loopback" "loopback" "$OUT"
run_probe "http://localhost:1/mcp" 2
assert_lacks "localhost row: accepted" "loopback" "$OUT"
run_probe "http://[::1]:1/mcp" 2
assert_lacks "ipv6 loopback row: accepted" "loopback" "$OUT"
AUTH="$TMP/absent" run_probe "http://192.0.2.1:9/mcp" 2
assert_lacks "no-token row: no bearer, no refusal" "loopback" "$OUT"

# 9: xtrace inherited from the environment must not print the bearer.
start_stub then-ok
run_probe "$URL" >/dev/null
OUT=$(env SHELLOPTS=xtrace QMD_MCP_URL="$URL" QMD_HTTP_AUTH_FILE="$TMP/token" QMD_KEY_PROBE_TIMEOUT=10 timeout 40 bash "$PROBE" 2>&1)
assert_lacks "xtrace row: bearer token not traced" "$TOKEN" "$OUT"

# 10: a multi-event SSE reply (notification, then the result) is a live server.
start_stub multi
run_probe "$URL"
assert_eq "multi-event row: exit 0" 0 "$RC"

# 11: a JSON-RPC error carrying the 401 text, no provider body (the jq branch alone).
start_stub rpc401
run_probe "$URL"
assert_eq "rpc401 row: exit 1" 1 "$RC"
assert_has "rpc401 row: names the key" "QMD_OPENAI_API_KEY" "$OUT"

# 12: search content that mentions 401 in an unflagged result is a working embed.
start_stub text401
run_probe "$URL"
assert_eq "text401 row: unflagged result text is content, exit 0" 0 "$RC"

# 13: the bearer must not reach a proxy named by the environment or ~/.curlrc.
start_stub multi
TARGET="$URL"
start_stub capture
CAP="$TMP/port.capture"
CAPURL="http://127.0.0.1:$(cat "$CAP")"
rm -f "$CAP.auth"
OUT=$(no_proxy='' NO_PROXY='' http_proxy="$CAPURL" HTTP_PROXY="$CAPURL" ALL_PROXY="$CAPURL" all_proxy="$CAPURL" QMD_MCP_URL="$TARGET" QMD_HTTP_AUTH_FILE="$TMP/token" QMD_KEY_PROBE_TIMEOUT=10 timeout 40 bash "$PROBE" 2>&1)
RC=$?
assert_eq "proxy-env row: probe still reaches the target (exit 0)" 0 "$RC"
assert_eq "proxy-env row: no request reached the proxy" "absent" "$([ -e "$CAP.auth" ] && echo present || echo absent)"
mkdir -p "$TMP/home"
# connect-to is a curlrc setting that --noproxy does not override: only -q keeps it out.
printf 'connect-to = "::127.0.0.1:%s"\n' "${CAPURL##*:}" > "$TMP/home/.curlrc"
rm -f "$CAP.auth"
OUT=$(env -u CURL_HOME -u XDG_CONFIG_HOME no_proxy='' NO_PROXY='' HOME="$TMP/home" QMD_MCP_URL="$TARGET" QMD_HTTP_AUTH_FILE="$TMP/token" QMD_KEY_PROBE_TIMEOUT=10 timeout 40 bash "$PROBE" 2>&1)
RC=$?
assert_eq "curlrc row: probe still reaches the target (exit 0)" 0 "$RC"
assert_eq "curlrc row: no request was redirected to the capture stub" "absent" "$([ -e "$CAP.auth" ] && echo present || echo absent)"

# 14: 127.x must be exactly four dotted octets; a trailing dot or extra labels are not loopback.
run_probe "http://127.0.0.1.0.0:9/mcp" 2
assert_has "five-label row: 127.0.0.1.0.0 is not loopback" "loopback" "$OUT"
run_probe "http://127.0.0.1.:9/mcp" 2
assert_has "trailing-dot row: 127.0.0.1. is not loopback" "loopback" "$OUT"
run_probe "http://127.0.0:9/mcp" 2
assert_has "three-octet row: 127.0.0 is not loopback" "loopback" "$OUT"
run_probe "http://127.0.0.999:9/mcp" 2
assert_has "octet-range row: 127.0.0.999 is not loopback" "loopback" "$OUT"
run_probe "http://127.0.0.0001:9/mcp" 2
assert_has "octet-width row: a four-digit octet is not loopback" "loopback" "$OUT"
run_probe "http://127.0.0.08:9/mcp" 2
assert_has "leading-zero row: 127.0.0.08 is not loopback" "loopback" "$OUT"

# 15: a token that cannot sit inside a quoted curl config value is refused, unechoed.
printf 'bad"token\n' > "$TMP/quote"
chmod 600 "$TMP/quote"
AUTH="$TMP/quote" run_probe "$URL"
assert_eq "quote-token row: exit 2" 2 "$RC"
assert_has "quote-token row: names the token file" "QMD_HTTP_AUTH_FILE" "$OUT"
assert_lacks "quote-token row: token not echoed" 'bad"token' "$OUT"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
