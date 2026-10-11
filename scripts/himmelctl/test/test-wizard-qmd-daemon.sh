#!/usr/bin/env bash
# test-wizard-qmd-daemon.sh — hermetic tests for the himmelctl `qmd-daemon`
# status item (HIMMEL-4432): the qmd daemon's initialize round-trip, judged in
# himmelctl status (one owner per fact, HIMMEL-755) instead of doctor C40.
# The probe runs against a stubbed curl through the doctor's own seams
# (HIMMEL_DOCTOR_QMD_CURL / _URL / _INIT_TIMEOUT), read from ctx.env.
#
# Covers: ok (present), slow-but-alive (present, detail says slow), wedged
# (curl rc 28 -> degraded), foreign listener (degraded), refused (absent),
# not wanted (qmd items desired=false under profile core), and manifest-lint.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"
probes_lib="$repo_root/scripts/himmelctl/lib/probes.js"
manifest_path="$repo_root/scripts/install/manifest.json"
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 1; }
node_bin=$(command -v node)
fail() { echo "FAIL: $*" >&2; exit 1; }

work=$(mktemp -d "${TMPDIR:-/tmp}/qmd-daemon-test.XXXXXX") || exit 1
trap 'rm -rf "$work"' EXIT

# Stub curl: answers by QD_MODE, mirrors the real `-w %{http_code}` framing.
cat > "$work/curl" <<'STUB'
#!/usr/bin/env bash
w=""; cfg=""
while [ $# -gt 0 ]; do case "$1" in -w) w="$2"; shift ;; -K) cfg=$(cat) ;; esac; shift; done
finish() { [ -n "$w" ] && printf '%s' "$1"; exit "${2:-0}"; }
case "${QD_MODE:-ok}" in
  down) finish 000 7 ;;
  hang) finish 000 28 ;;
  foreign) printf 'event: message\ndata: %s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"other-server"}}}'; finish 200 ;;
  slow) sleep 4 ;;
  # HIMMEL-5227: the real HIMMEL-5002 daemon (reply copied from the live :8181
  # listener, 2026-10-11): 401 + {"error":"Unauthorized"} without the bearer
  # token, which arrives as a curl config on stdin (-K -), never argv.
  auth) case "$cfg" in *"Authorization: Bearer "*) ;; *) printf '{"error":"Unauthorized"}'; finish 401 ;; esac ;;
esac
printf 'event: message\ndata: %s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"qmd","version":"2.8.3"},"instructions":"QMD"}}'
finish 200
STUB
chmod +x "$work/curl"

probe() { # <mode> -> JSON verdict of the real manifest's qmd-daemon item
  QD_MODE="$1" "$node_bin" -e "
const { runProbe } = require('$(winpath "$probes_lib")');
const manifest = JSON.parse(require('fs').readFileSync('$(winpath "$manifest_path")', 'utf8'));
const item = manifest.items.find((i) => i.id === 'qmd-daemon');
if (!item) { console.log(JSON.stringify({ actual: 'NO-ITEM' })); process.exit(0); }
const env = { ...process.env, QD_MODE: '$1', HIMMEL_DOCTOR_QMD_CURL: '$(winpath "$work/curl")', HIMMEL_DOCTOR_QMD_URL: 'http://localhost:1/mcp' };
console.log(JSON.stringify(runProbe(item, { repoRoot: '$(winpath "$repo_root")', targetPath: '$(winpath "$repo_root")', scope: 'user', env })));
"
}

out=$(probe ok);      echo "$out" | jq -e '.actual == "present"' >/dev/null || fail "ok -> present (got: $out)"
out=$(probe slow);    echo "$out" | jq -e '.actual == "present" and (.detail | test("slow"))' >/dev/null || fail "slow-but-alive -> present, detail says slow (got: $out)"
out=$(probe hang);    echo "$out" | jq -e '.actual == "degraded" and (.detail | test("did not answer"))' >/dev/null || fail "wedged (rc 28) -> degraded (got: $out)"
out=$(probe foreign); echo "$out" | jq -e '.actual == "degraded" and (.detail | test("NOT qmd"))' >/dev/null || fail "foreign listener -> degraded (got: $out)"
out=$(probe down);    echo "$out" | jq -e '.actual == "absent"' >/dev/null || fail "refused (rc 7) -> absent (got: $out)"
echo "ok: qmd-daemon present / slow / wedged / foreign / not-running"

# HIMMEL-5227: a daemon that requires the bearer token (HIMMEL-5002) must not
# read as "NOT qmd". With the token file the probe authenticates (present);
# without it the 401 is named as a missing token, not a foreign listener.
printf 'tok-for-the-test-only\n' > "$work/http-token"; chmod 600 "$work/http-token"
probe_auth() { # <mode> <token-file> [ss-stub] -> JSON verdict
  QMD_HTTP_AUTH_FILE="$2" HIMMEL_DOCTOR_QMD_SS="${3:-ss-absent}" probe "$1"
}
out=$(probe_auth auth "$work/http-token")
echo "$out" | jq -e '.actual == "present"' >/dev/null || fail "token file + daemon that 401s without it -> present (got: $out)"
out=$(probe_auth auth "$work/no-such-token")
echo "$out" | jq -e '.actual == "degraded" and (.detail | test("401")) and (.detail | test("token")) and (.detail | test("NOT qmd") | not)' >/dev/null || fail "401 with no token -> degraded, names the token, not NOT-qmd (got: $out)"
echo "ok: qmd-daemon authenticates with the bearer token; a 401 names the token"

# A non-qmd listener is named by pid and command, from ss + /proc (read only).
cat > "$work/ss" <<'SSSTUB'
#!/usr/bin/env bash
printf 'LISTEN 0 512 [::1]:1 [::]:* users:(("fake-listener",pid=%s,fd=3))\n' "$FAKE_LISTENER_PID"
SSSTUB
chmod +x "$work/ss"
sleep 30 & fake_pid=$!
out=$(FAKE_LISTENER_PID="$fake_pid" probe_auth foreign "$work/http-token" "$(winpath "$work/ss")")
kill "$fake_pid" 2>/dev/null || true
echo "$out" | jq -e --arg p "pid $fake_pid" '.actual == "degraded" and (.detail | test("NOT qmd")) and (.detail | contains($p)) and (.detail | contains("sleep 30"))' >/dev/null || fail "foreign listener is named by pid and command (got: $out)"
echo "ok: a non-qmd listener is named by pid and command"

# not wanted: desired follows the qmd items' profiles (luna, all) — core wants none of them.
want=$("$node_bin" -e "
const m = JSON.parse(require('fs').readFileSync('$(winpath "$manifest_path")', 'utf8'));
for (const id of ['qmd-binary', 'qmd-index', 'qmd-daemon']) {
  const it = m.items.find((i) => i.id === id);
  console.log(id, it ? JSON.stringify(it.profiles) : 'MISSING');
}")
grep -q '^qmd-daemon \["luna","all"\]$' <<< "$want" || fail "qmd-daemon profiles must equal qmd-index's [luna,all] so desired=false under core (got: $want)"
echo "ok: qmd-daemon not wanted outside luna/all"

node "$repo_root/scripts/install/manifest-lint.mjs" "$manifest_path" >/dev/null || fail "manifest-lint rejects the manifest"
echo "ok: manifest-lint passes"
echo "PASS test-wizard-qmd-daemon.sh"
