#!/usr/bin/env bash
# Tests for scripts/eval/qmd-quality/qmd-burst-proof.sh.
# Usage: bash scripts/eval/qmd-quality/test-qmd-burst-proof.sh
# Hermetic: a python3 stub HTTP server on a throwaway loopback port stands in for
# the qmd daemon (it arms its own alarm and is killed by pid on exit); the live
# daemon is never touched. The stub plays a PLAN, one entry per arriving request:
# B = the daemon's Busy refusal at once, BD<secs> = Busy after that delay,
# D<secs> = a result after that delay,
# H = never answers (sleeps past the curl cap).
# Platform guard (gitbash-only): POSIX bash 3.2+; a test fixture needs no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROOF="$HERE/qmd-burst-proof.sh"
TOKEN="sentinel-bearer-$$"

FAILED=0
ok() { echo "PASS $1"; }
bad() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected '$2', got '$3'"; fi; }
assert_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — '$2' not in: $3" ;; esac; }
assert_lacks() { case "$3" in *"$2"*) bad "$1 — '$2' leaked in: $3" ;; *) ok "$1" ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qmd-burst-proof.XXXXXX") || { echo "FAIL could not create temp dir"; exit 1; }
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
import http.server, json, signal, socketserver, sys, threading, time
signal.alarm(120)
plan, portfile = sys.argv[1].split(','), sys.argv[2]
lock = threading.Lock()
n = 0
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        global n
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        with lock:
            step = plan[n % len(plan)]
            n += 1
        open(portfile + '.auth', 'w').write(self.headers.get('Authorization', ''))
        if step == 'H':
            time.sleep(60)
        if step.startswith('BD'):
            time.sleep(float(step[2:]))
        elif step.startswith('D'):
            time.sleep(float(step[1:]))
        if step.startswith('B'):
            res = {"content": [{"type": "text", "text": "Busy: 3 queries are already queued (~30 s each). Retry shortly, or use a lex-only search."}], "isError": True}
        else:
            res = {"content": [{"type": "text", "text": "ok"}]}
        data = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": 2, "result": res}) + "\n\n").encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, *a): pass
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    # HTTPServer.server_bind calls getfqdn(), a reverse lookup that stalls for seconds on a macOS runner.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = '127.0.0.1', self.server_address[1]
s = S(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(s.server_address[1]))
s.serve_forever()
PY

# start_stub <name> <plan> -> sets URL; cleanup kills the server.
start_stub() {
    local pf="$TMP/port.$1" i=0
    rm -f "$pf"
    python3 -I "$TMP/stub.py" "$2" "$pf" >/dev/null 2>&1 &
    SRV_PIDS+=("$!")
    while [ ! -s "$pf" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    URL="http://127.0.0.1:$(cat "$pf")/mcp" # read-sink-ok: $pf is this suite's own mktemp port file
    AUTHFILE="$pf.auth"
}

# run_proof <url> [VAR=val ...] -> OUT (stdout+stderr), RC
run_proof() {
    local url="$1"
    shift
    OUT=$(env QMD_MCP_URL="$url" QMD_HTTP_AUTH_FILE="$TMP/token" "$@" timeout 60 bash "$PROOF" 2>&1)
    RC=$?
}

# (a) 7 Busy at once + 3 admitted after a short delay -> BURST-PASS.
start_stub a "B,B,B,B,B,B,B,D0.5,D0.5,D0.5"
run_proof "$URL" QMD_BURST_N=10
assert_eq "(a) 7 busy + 3 served: exit 0" 0 "$RC"
assert_has "(a) verdict line" "BURST-PASS" "$OUT"
assert_has "(a) table counts the busy replies" "busy" "$OUT"
assert_eq "(a) the daemon saw the bearer token" "Bearer $TOKEN" "$(cat "$AUTHFILE" 2>/dev/null)"
assert_lacks "(a) bearer token not printed" "$TOKEN" "$OUT"

# (b) an admitted call slower than QMD_BURST_LIMIT -> BURST-FAIL naming the call.
start_stub b "B,D3"
run_proof "$URL" QMD_BURST_N=2 QMD_BURST_LIMIT=2
assert_eq "(b) slow admitted call: exit 1" 1 "$RC"
assert_has "(b) verdict line" "BURST-FAIL" "$OUT"
assert_has "(b) names the limit breach" "over the 2 s limit" "$OUT"

# (b2) N=1 passes.
start_stub b2 "D0.1,D3"
run_proof "$URL" QMD_BURST_N=1 QMD_BURST_BUSY_MAX=2
assert_eq "(b2) N=1 plain result passes" 0 "$RC"

# (b3) a Busy reply slower than QMD_BURST_BUSY_MAX is a failure naming the call.
start_stub b3 "B,BD3"
run_proof "$URL" QMD_BURST_N=2 QMD_BURST_BUSY_MAX=2
assert_eq "(b3) slow Busy reply: exit 1" 1 "$RC"
assert_has "(b3) verdict line" "BURST-FAIL" "$OUT"
assert_has "(b3) names the busy window" "busy window" "$OUT"

# (c) a call that never answers is cut at the curl cap: FAIL, not a hang.
start_stub c "D0.2,H"
run_proof "$URL" QMD_BURST_N=2 QMD_BURST_CURL_CAP=2
assert_eq "(c) never-answering call: exit 1" 1 "$RC"
assert_has "(c) verdict line" "BURST-FAIL" "$OUT"
assert_has "(c) names the timeout" "no reply" "$OUT"

# (d) no listener -> exit 2.
run_proof "http://127.0.0.1:1/mcp" QMD_BURST_N=2
assert_eq "(d) no daemon: exit 2" 2 "$RC"
assert_lacks "(d) no verdict line" "BURST-PASS" "$OUT"

# Negative: a non-loopback URL with a token is refused before any request.
run_proof "http://example.invalid:8181/mcp" QMD_BURST_N=2
assert_eq "non-loopback with token: exit 2" 2 "$RC"
assert_has "non-loopback with token: says why" "non-loopback" "$OUT"
assert_lacks "non-loopback with token: token not printed" "$TOKEN" "$OUT"

# Negative: the token never reaches curl's argv (a fake curl records it).
mkdir "$TMP/bin"
cat > "$TMP/bin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/argv.log"
exec $(command -v curl) "\$@"
SH
chmod +x "$TMP/bin/curl"
start_stub argv "D0.1"
run_proof "$URL" QMD_BURST_N=3 PATH="$TMP/bin:$PATH"
assert_eq "argv row: still passes" 0 "$RC"
assert_eq "argv row: curl was called through the fake" 3 "$(wc -l < "$TMP/argv.log" | tr -d ' ')"
assert_lacks "argv row: no token in curl argv" "$TOKEN" "$(cat "$TMP/argv.log")"
assert_lacks "argv row: no token in output" "$TOKEN" "$OUT"

echo
if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "$FAILED FAILED"; exit 1; fi
