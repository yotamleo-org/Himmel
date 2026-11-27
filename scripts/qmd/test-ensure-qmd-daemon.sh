#!/usr/bin/env bash
# test-ensure-qmd-daemon.sh - hermetic smoke test for the qmd plugin's
# ensure-qmd-daemon.sh (marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh).
#
# Never touches the real qmd daemon on 8181: HOME is pointed at an empty temp
# dir (so the bun-bin fallback finds nothing), a MOCK qmd + MOCK curl stand in
# on PATH / via QMD_CURL, and PATH is reduced to coreutil dirs plus the mock
# bin so no real qmd leaks in.
#
# Covers: (a) alive short-circuit (qmd NOT invoked); (b) dead -> start daemon ->
# comes alive (qmd invoked with `mcp --http --daemon`); (c) qmd missing ->
# nonzero + install hint; (d) foreign listener -> nonzero + port-taken message;
# (e) hung daemon start -> bounded by QMD_START_TIMEOUT, nonzero + clear message;
# (f) start "succeeds" but probe never comes alive -> wait loop exhausts,
# nonzero + "nothing came alive" + mcp.log + start-output passthrough;
# (g) timeout(1) absent -> degrade branch still starts the daemon and exits 0;
# (h) bun-global bin is preferred over a PATH qmd (resolution order);
# (i) bun + the bun-global dist/cli/qmd.js is preferred over the bun bin shim
#     AND a PATH qmd (the daemon child must inherit bun, never a
#     node-shebang shim's node execPath).
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
script="$repo_root/marketplace/plugins/qmd/scripts/ensure-qmd-daemon.sh"
[ -f "$script" ] || { echo "FAIL: $script not found" >&2; exit 1; }
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d)"
# Every fake-daemon.sh stub PID this run starts is tracked here
# and reaped on EXIT/INT/TERM (not only on the happy path), so a forced early
# exit (an assertion failure, a kill partway through) never leaks a stub.
declare -a STUB_PIDS=()
reap_stubs() {
  local pid
  for pid in "${STUB_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in "${STUB_PIDS[@]:-}"; do
    [ -n "$pid" ] || continue
    wait "$pid" 2>/dev/null || true
  done
}
trap 'reap_stubs; rm -rf "$work"' EXIT
# A trap without an explicit exit does not terminate the script on INT/TERM -
# it runs the handler, then execution continues from where the signal landed
# (now inside a removed $work). Exit explicitly so an interrupt actually stops
# the suite instead of running on against a deleted work directory.
trap 'reap_stubs; rm -rf "$work"; exit 130' INT
trap 'reap_stubs; rm -rf "$work"; exit 143' TERM
# Test-only hooks for the leak regression test (test-ensure-qmd-daemon-leak.sh):
# QMD_TEST_WORK_MARKER, if set, receives this run's unique $work path so the
# leak test can pgrep -f its fake-daemon.sh by a marker no other run shares.
# QMD_TEST_FORCE_FAIL_AFTER=start_fake_daemon forces an early exit right after
# a stub starts, modeling a kill/assertion-failure partway through.
: "${QMD_TEST_WORK_MARKER:=}"
[ -z "$QMD_TEST_WORK_MARKER" ] || printf '%s\n' "$work" > "$QMD_TEST_WORK_MARKER"
: "${QMD_TEST_FORCE_FAIL_AFTER:=}"

home="$work/home"
mkdir -p "$home"
state="$work/state"
mkdir -p "$state"
bin="$work/bin"
mkdir -p "$bin"

# ---- timeout stub for hosts without GNU timeout (stock macOS) -----------------
# The script under test degrades to an UNBOUNDED daemon start when timeout(1)
# is absent, so (e) could never pass there. Provide a minimal
# GNU-shaped stub in $bin: `timeout [-k N] SECS cmd...`, rc 124 on a kill.
if ! command -v timeout >/dev/null 2>&1; then
  cat > "$bin/timeout" <<'TOEOF'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then echo "timeout (test stub)"; exit 0; fi
if [ "$1" = "-k" ]; then shift 2; fi
secs="$1"; shift
flag="${TMPDIR:-/tmp}/timeout-stub.$$"
rm -f "$flag"
"$@" &
cpid=$!
( sleep "$secs"; touch "$flag"; kill -TERM "$cpid" 2>/dev/null ) >/dev/null 2>&1 &
wpid=$!
wait "$cpid"; rc=$?
kill "$wpid" 2>/dev/null
if [ -f "$flag" ]; then rm -f "$flag"; exit 124; fi
exit "$rc"
TOEOF
  chmod +x "$bin/timeout"
fi

# ---- SAFE_PATH: coreutil dirs only, captured before we scrub PATH ----------
safe=""
for t in sleep grep sed cat mkdir touch rm dirname env bash timeout date; do
  p="$(command -v "$t")" || continue
  d="$(dirname "$p")"
  case ":$safe:" in *":$d:"*) ;; *) safe="$safe:$d" ;; esac
done
safe="${safe#:}"

# ---- Mock curl: mode-driven via QMD_MOCK_CURL_MODE -------------------------
#   alive    -> qmd-shaped initialize reply (faithful to real qmd 2.5.2 shape)
#   foreign  -> non-qmd JSON
#   sneaky   -> foreign serverInfo but a name:qmd pair OUTSIDE serverInfo
#   dead     -> nothing, connection-refused rc
#   sentinel -> qmd-shaped reply iff $QMD_MOCK_STATE/alive exists, else dead
#   auth401  -> an authenticated daemon the probe holds no token for: the MCP
#               route answers 401 with an empty body, /health answers
#               $QMD_MOCK_HEALTH (default 200; 000 = connection refused)
# Dead exits rc 7 (connect refused); the rc 7 vs rc 28 (timeout) distinction
# is intentionally collapsed - production branches on empty body only.
mock_curl="$bin/curl"
cat > "$mock_curl" <<'EOF'
#!/usr/bin/env bash
qmd_reply='{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"qmd","version":"2.5.2"},"instructions":"QMD is your local search engine."}}'
mode="${QMD_MOCK_CURL_MODE:-dead}"
[ "$mode" = sentinel ] && [ "${QMD_MOCK_SENTINEL_AUTH:-0}" = 1 ] && [ -f "$QMD_MOCK_STATE/alive" ] && mode=auth401
case "$mode" in
  alive)   printf '%s' "$qmd_reply"; exit 0 ;;
  foreign) printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"other-server"}}}'; exit 0 ;;
  sneaky)  printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"tools":[{"name":"qmd"}]},"serverInfo":{"name":"other-server","version":"1.0"}}}'; exit 0 ;;
  sentinel)
    if [ -f "$QMD_MOCK_STATE/alive" ]; then printf '%s' "$qmd_reply"; exit 0; fi
    exit 7 ;;
  auth401)
    route=mcp; wcode=0
    for a in "$@"; do
      case "$a" in */health) route=health ;; '%{http_code}') wcode=1 ;; esac
    done
    code=401
    if [ "$route" = health ]; then code="${QMD_MOCK_HEALTH:-200}"; fi
    [ "$code" = 000 ] && exit 7
    if [ "$wcode" = 1 ]; then printf '%s' "$code"; elif [ "$route" = health ]; then hb='{"status":"ok","uptime":3}'; printf '%s' "${QMD_MOCK_HEALTH_BODY-$hb}"; fi
    exit 0 ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$mock_curl"

# ---- Mock qmd: records argv; simulates daemon start via a sentinel file -----
# QMD_MOCK_HANG=1 -> the daemon start hangs. `exec sleep`, NOT a child sleep:
# a grandchild sleep would keep holding the $() pipe open after timeout(1)
# kills the mock - the known Git-Bash timeout reaping trap.
mock_qmd="$bin/qmd"
cat > "$mock_qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-argv.log"
if [ "$*" = "mcp --http --daemon" ]; then
  pwd -P >> "$QMD_MOCK_STATE/qmd-cwd.log"
  cat "$HOME/.cache/qmd/starting" > "$QMD_MOCK_STATE/marker-at-start" 2>/dev/null || echo none > "$QMD_MOCK_STATE/marker-at-start"
  if [ "${QMD_MOCK_HANG:-0}" = "1" ]; then
    exec sleep 60
  fi
  if [ -n "${QMD_MOCK_LOCK_DIR:-}" ]; then
    if [ -d "$QMD_MOCK_LOCK_DIR" ]; then echo held >> "$QMD_MOCK_STATE/lock-at-start"; else echo free >> "$QMD_MOCK_STATE/lock-at-start"; fi
  fi
  if [ -n "${QMD_MOCK_SLOW:-}" ]; then sleep "$QMD_MOCK_SLOW"; fi
  touch "$QMD_MOCK_STATE/alive"
  echo "Started qmd HTTP daemon (PID 4242)."
fi
exit 0
EOF
chmod +x "$mock_qmd"

# A fixed, verified-free test port for QMD_MCP_URL: the fix under test adds a
# raw TCP connect probe (distinct from the mocked curl probe below), which
# makes REAL localhost connections - it must never point at the real qmd
# daemon's port (8181, commonly live on this machine) or every existing case
# here would race a live process instead of the dead port they assume.
test_port="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
bash -c "(exec 3<>/dev/tcp/127.0.0.1/$test_port) 2>/dev/null" && \
  fail "precondition: chosen test port $test_port is unexpectedly held"
test_url="http://127.0.0.1:$test_port/mcp"

# run_ensure <curl-mode> <path> -> sets global rc/out.
# QMD_MOCK_HANG / QMD_START_TIMEOUT / QMD_MCP_URL pass through from the
# caller's scope (QMD_MCP_URL defaults to the hermetic test_port above).
run_ensure() {
  rm -f "$state/qmd-argv.log"
  set +e
  out="$(QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE="$1" QMD_MOCK_STATE="$state" \
    QMD_MOCK_HANG="${QMD_MOCK_HANG:-0}" QMD_START_TIMEOUT="${QMD_START_TIMEOUT:-20}" \
    QMD_MOCK_HEALTH="${QMD_MOCK_HEALTH:-200}" \
    QMD_MCP_URL="${QMD_MCP_URL:-$test_url}" \
    HOME="$home" PATH="$2" \
    bash "$script" 2>&1)"
  rc=$?
  set -e
}
set -e

# ---- (a) alive short-circuit: qmd never invoked ----------------------------
run_ensure alive "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(a) alive: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(a) alive: qmd was invoked but should have been skipped"
echo "ok (a): alive endpoint short-circuits, qmd not invoked"

# ---- (b) dead -> start daemon -> comes alive -------------------------------
rm -f "$state/alive"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(b) dead->alive: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-argv.log" ] || fail "(b) dead->alive: qmd was never invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(b) dead->alive: qmd not called with 'mcp --http --daemon' (got: $(cat "$state/qmd-argv.log"))"
echo "ok (b): dead endpoint starts daemon (qmd mcp --http --daemon) then goes alive"

rm -f "$state/alive" "$state/marker-at-start"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(b3) start marker: expected rc 0, got $rc ($out)"
marker_at="$(cat "$state/marker-at-start" 2>/dev/null)"
case "$marker_at" in ''|none|*[!0-9]*) fail "(b3) start marker: no epoch marker existed when qmd launched (got '$marker_at')" ;; esac
[ $(( $(date +%s) - marker_at )) -lt 60 ] || fail "(b3) start marker: marker epoch $marker_at is not current"
[ ! -e "$home/.cache/qmd/starting" ] || fail "(b3) start marker: marker still present after the daemon came alive"
echo "ok (b3): start marker written before the launch, removed once alive"

# ---- (b2) daemon cwd is $HOME, never the caller's cwd ----------
# The daemon outlives the session that started it; inheriting a worktree cwd
# pinned that worktree ("in use") long after its PR merged.
rm -f "$state/alive" "$state/qmd-cwd.log"
mkdir -p "$work/caller-wt"
pushd "$work/caller-wt" >/dev/null
run_ensure sentinel "$bin:$safe"
popd >/dev/null
[ "$rc" -eq 0 ] || fail "(b2) daemon cwd: expected rc 0, got $rc ($out)"
want_cwd="$(cd "$home" && pwd -P)"
[ "$(cat "$state/qmd-cwd.log" 2>/dev/null)" = "$want_cwd" ] || \
  fail "(b2) daemon cwd: expected $want_cwd, got '$(cat "$state/qmd-cwd.log" 2>/dev/null)'"
echo "ok (b2): daemon starts with cwd \$HOME, not the caller's cwd"

# ---- (c) qmd missing entirely ----------------------------------------------
# PATH without the mock bin dir -> PATH lookup and the bun-bin fallback
# (empty temp HOME) both fail -> not-installed error.
rm -f "$state/alive"
run_ensure dead "$safe"
[ "$rc" -ne 0 ] || fail "(c) qmd-missing: expected nonzero rc"
printf '%s' "$out" | grep -q "not installed" || \
  fail "(c) qmd-missing: missing 'not installed' remediation (got: $out)"
echo "ok (c): qmd missing -> nonzero with install hint"

# ---- (d) foreign listener on the port --------------------------------------
run_ensure foreign "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(d) foreign: expected nonzero rc"
printf '%s' "$out" | grep -qi "not qmd" || \
  fail "(d) foreign: missing 'not qmd' port-taken message (got: $out)"
echo "ok (d): foreign listener -> nonzero with port-taken message"

# ---- (d2) sneaky foreign listener: name:qmd OUTSIDE serverInfo ---------------
# Reply contains a "name":"qmd" pair inside a tools array but a DIFFERENT
# serverInfo name -> must still classify as foreign (serverInfo-scoped match).
run_ensure sneaky "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(d2) sneaky: expected nonzero rc"
printf '%s' "$out" | grep -qi "not qmd" || \
  fail "(d2) sneaky: missing 'not qmd' port-taken message (got: $out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(d2) sneaky: qmd was invoked but should not have been"
echo "ok (d2): name:qmd outside serverInfo still classified foreign"

# ---- (e) hung daemon start is bounded ---------------------------------------
rm -f "$state/alive"
t0="$(date +%s)"
QMD_MOCK_HANG=1 QMD_START_TIMEOUT=2 run_ensure dead "$bin:$safe"
t1="$(date +%s)"
dur=$((t1 - t0))
[ "$rc" -ne 0 ] || fail "(e) hang: expected nonzero rc"
[ "$dur" -lt 15 ] || fail "(e) hang: not bounded - took ${dur}s with QMD_START_TIMEOUT=2"
printf '%s' "$out" | grep -q "timed out" || \
  fail "(e) hang: missing 'timed out' message (got: $out)"
printf '%s' "$out" | grep -q "mcp.log" || \
  fail "(e) hang: missing 'mcp.log' pointer (got: $out)"
[ ! -e "$home/.cache/qmd/starting" ] || fail "(e) hang: the killed start left its start marker behind"
echo "ok (e): hung daemon start bounded (${dur}s) with clear timeout message, start marker removed"

# ---- (f) start "succeeds" but the probe never comes alive --------------------
# curl stays dead the whole time; the fast mock qmd exits 0 as if it started.
# The wait loop exhausts its 5 probes (~4s of sleeps) and fails loudly,
# echoing the captured qmd start output back (the start_out passthrough).
rm -f "$state/alive"
run_ensure dead "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(f) never-alive: expected nonzero rc"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(f) never-alive: qmd start was never attempted"
printf '%s' "$out" | grep -q "nothing came alive" || \
  fail "(f) never-alive: missing 'nothing came alive' message (got: $out)"
printf '%s' "$out" | grep -q "mcp.log" || \
  fail "(f) never-alive: missing 'mcp.log' pointer (got: $out)"
printf '%s' "$out" | grep -q "Started qmd HTTP daemon (PID 4242)." || \
  fail "(f) never-alive: qmd start output not passed through (got: $out)"
echo "ok (f): start-ok-but-never-alive exhausts the wait loop with start output passed through"

# ---- (g) timeout(1) absent: degrade branch still starts the daemon ----------
# In Git Bash, timeout(1) shares /usr/bin with every other coreutil, so a PATH
# that "omits timeout's dir" would also lose grep/sed/bash. Instead build a
# restricted bin of absolute-shebang wrapper scripts for ONLY the tools the
# ensure script and the mocks need (timeout deliberately absent), and assert
# the precondition that `command -v timeout` really fails on that PATH.
rbin="$work/rbin"
mkdir -p "$rbin"
real_bash="$(command -v bash)"
for t in bash grep sed sleep touch mkdir cat rm find rmdir; do
  real="$(command -v "$t")"
  printf '#!%s\nexec "%s" "$@"\n' "$real_bash" "$real" > "$rbin/$t"
  chmod +x "$rbin/$t"
done
cp "$mock_qmd" "$rbin/qmd"
chmod +x "$rbin/qmd"
if PATH="$rbin" "$real_bash" -c 'command -v timeout' >/dev/null 2>&1; then
  fail "(g) precondition: timeout still resolvable on the restricted PATH"
fi
rm -f "$state/alive"
run_ensure sentinel "$rbin"
[ "$rc" -eq 0 ] || fail "(g) no-timeout: expected rc 0, got $rc ($out)"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(g) no-timeout: degrade branch did not invoke qmd with 'mcp --http --daemon'"
echo "ok (g): timeout(1) absent -> unbounded degrade branch still starts the daemon"

# ---- (h) bun-global bin preferred over a PATH qmd ----------------------------
# Populate $HOME/.bun/bin/qmd (records that the bun copy ran, brings the
# daemon alive) and put a DECOY qmd on PATH that would fail loudly if invoked.
mkdir -p "$home/.bun/bin"
cat > "$home/.bun/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-bun.log"
if [ "$*" = "mcp --http --daemon" ]; then
  touch "$QMD_MOCK_STATE/alive"
fi
exit 0
EOF
chmod +x "$home/.bun/bin/qmd"
decoy_bin="$work/decoy-bin"
mkdir -p "$decoy_bin"
cat > "$decoy_bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-decoy.log"
echo "DECOY qmd invoked - bun-first resolution is broken" >&2
exit 1
EOF
chmod +x "$decoy_bin/qmd"
rm -f "$state/alive" "$state/qmd-bun.log" "$state/qmd-decoy.log"
run_ensure sentinel "$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(h) bun-first: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-bun.log" ] || fail "(h) bun-first: bun copy was not invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-bun.log" || \
  fail "(h) bun-first: bun copy not called with 'mcp --http --daemon'"
[ ! -f "$state/qmd-decoy.log" ] || fail "(h) bun-first: PATH decoy qmd was invoked"
echo "ok (h): bun-global qmd preferred over the PATH decoy"

# ---- (i) bun + global qmd.js preferred over the bun bin shim -----------------
# Create the bun-global dist/cli/qmd.js and a mock `bun`; the (h)
# bun-bin shim and the PATH decoy stay in place - the `bun <qmd.js>` invocation
# must win them both, so the daemon child inherits bun's execPath (the bin
# shim honors the CLI's node shebang and would hand the daemon to node, where
# the bun-ABI better-sqlite3 prebuild refuses to load).
mkdir -p "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli"
touch "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
cat > "$bin/bun" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-bunjs.log"
case "$*" in
  */dist/cli/qmd.js\ mcp\ --http\ --daemon) touch "$QMD_MOCK_STATE/alive" ;;
esac
exit 0
EOF
chmod +x "$bin/bun"
rm -f "$state/alive" "$state/qmd-bun.log" "$state/qmd-decoy.log" "$state/qmd-bunjs.log"
run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i) bun-js-first: expected rc 0, got $rc ($out)"
[ -f "$state/qmd-bunjs.log" ] || fail "(i) bun-js-first: bun + qmd.js was not invoked"
grep -q 'dist/cli/qmd.js mcp --http --daemon' "$state/qmd-bunjs.log" || \
  fail "(i) bun-js-first: bun not called with '<qmd.js> mcp --http --daemon' (got: $(cat "$state/qmd-bunjs.log"))"
[ ! -f "$state/qmd-bun.log" ] || fail "(i) bun-js-first: bun bin shim was invoked but the js path should win"
[ ! -f "$state/qmd-decoy.log" ] || fail "(i) bun-js-first: PATH decoy qmd was invoked"
echo "ok (i): bun + global qmd.js preferred over the bun bin shim and PATH"

# ---- (i2) BUN_INSTALL override is honored for the bun-js resolution ----------
# Parity with qmd-bin.sh's own BUN_INSTALL test: the two resolvers are
# documented mirrors, so both must honor a relocated bun root. The DEFAULT
# $HOME/.bun global qmd.js stays in place - the override must win over it.
mkdir -p "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli"
touch "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log"
BUN_INSTALL="$work/custom-bun" run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i2) BUN_INSTALL: expected rc 0, got $rc ($out)"
grep -q 'custom-bun' "$state/qmd-bunjs.log" || \
  fail "(i2) BUN_INSTALL: override path not used (got: $(cat "$state/qmd-bunjs.log" 2>/dev/null))"
echo "ok (i2): BUN_INSTALL override honored for the bun-js resolution"

# ---- (i3) bun present but global qmd.js ABSENT -> falls back to bun bin shim -
# Pins the [ -f qmd.js ] && command -v bun conjunction: bun alone must NOT
# select the js invocation; the (h) bun-bin shim mock takes over instead.
rm -f "$home/.bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log"
run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i3) js-absent fallback: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-bunjs.log" ] || fail "(i3) js-absent fallback: bun-js invoked despite missing qmd.js"
[ -f "$state/qmd-bun.log" ] || fail "(i3) js-absent fallback: bun bin shim was not invoked"
grep -qx 'mcp --http --daemon' "$state/qmd-bun.log" || \
  fail "(i3) js-absent fallback: shim not called with 'mcp --http --daemon'"
echo "ok (i3): bun present without global qmd.js falls back to the bun bin shim"

# ---- (i4) BUN_INSTALL override + missing qmd.js -> shim under the SAME root -
# (i2) covered override+js-present and (i3) covered
# default-root+js-missing, but never the combination - which is exactly where
# a $HOME-hardcoded shim fallback breaks under a relocated bun root. The shim
# must resolve from $BUN_INSTALL/bin, not $HOME/.bun/bin.
rm -f "$work/custom-bun/install/global/node_modules/@tobilu/qmd/dist/cli/qmd.js"
mkdir -p "$work/custom-bun/bin"
cat > "$work/custom-bun/bin/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-custom-shim.log"
if [ "$*" = "mcp --http --daemon" ]; then
  touch "$QMD_MOCK_STATE/alive"
fi
exit 0
EOF
chmod +x "$work/custom-bun/bin/qmd"
rm -f "$state/alive" "$state/qmd-bunjs.log" "$state/qmd-bun.log" "$state/qmd-decoy.log" "$state/qmd-custom-shim.log"
BUN_INSTALL="$work/custom-bun" run_ensure sentinel "$bin:$decoy_bin:$safe"
[ "$rc" -eq 0 ] || fail "(i4) override+js-absent: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-bunjs.log" ] || fail "(i4) override+js-absent: bun-js invoked despite missing qmd.js"
[ -f "$state/qmd-custom-shim.log" ] || fail "(i4) override+js-absent: BUN_INSTALL/bin shim was not used"
grep -qx 'mcp --http --daemon' "$state/qmd-custom-shim.log" || \
  fail "(i4) override+js-absent: custom shim not called with 'mcp --http --daemon'"
[ ! -f "$state/qmd-bun.log" ] || fail "(i4) override+js-absent: default \$HOME shim used instead of the BUN_INSTALL root"
echo "ok (i4): BUN_INSTALL override + missing qmd.js falls back to the override root's shim"

# ---- (j) port held by a dying process delays the start --------
# A fixture binds+listens on a REAL localhost port (no MCP handshake - a raw
# TCP connect should still see it as held) for hold_secs seconds, then
# releases it - simulating the ~15s bun-thread unwind window after SIGTERM on
# a killed daemon. The mocked MCP probe ("sentinel" mode) reports dead the
# whole time, until the mock qmd sets the alive sentinel after it is invoked.
# Assert: qmd start is NOT attempted while the fixture still holds the port,
# and it IS attempted (and succeeds) once the fixture releases it.
# Reset the bun-shim artifacts left by cases (h)-(i4) so resolve_qmd falls
# through to the plain PATH mock at $bin/qmd (the one this case asserts on).
rm -rf "$home/.bun"
rm -f "$state/alive" "$state/qmd-argv.log"
hold_port="$(python3 - <<'PY'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
hold_secs=3
python3 - "$hold_port" "$hold_secs" <<'PY' &
import socket, sys, time
port = int(sys.argv[1])
hold = float(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(128)
# Drain the accept queue for the whole hold: BSD/macOS refuses further connects
# once a never-accepting listener's backlog is full, which would read as "port
# free" to the script under test.
s.settimeout(0.2)
end = time.time() + hold
while time.time() < end:
    try:
        s.accept()[0].close()
    except socket.timeout:
        pass
s.close()
PY
fixture_pid=$!
# Give the fixture a moment to actually bind before the script starts probing.
sleep 0.5
bash -c "(exec 3<>/dev/tcp/127.0.0.1/$hold_port) 2>/dev/null" || \
  fail "(j) precondition: fixture on port $hold_port is not actually held"

(
  QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
    QMD_MCP_URL="http://127.0.0.1:$hold_port/mcp" \
    HOME="$home" PATH="$bin:$safe" \
    bash "$script" > "$work/j-out.log" 2>&1
) &
ensure_pid=$!

sleep 2
[ ! -f "$state/qmd-argv.log" ] || \
  fail "(j) port-held: qmd was invoked while the fixture still held the port (raced a dying process)"

wait "$fixture_pid" 2>/dev/null
wait "$ensure_pid"
rc=$?
[ "$rc" -eq 0 ] || fail "(j) port-held: expected rc 0 once the port freed, got $rc ($(cat "$work/j-out.log"))"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || \
  fail "(j) port-held: qmd was never invoked after the port freed"
echo "ok (j): dying process holding the port delays the daemon start until it releases"

# ---- (k)-(n) memory ceiling + detached self-recycle -----------
# A fake "daemon" (a real process, so kill/kill -0 are real) is named by a
# pidfile under a scratch XDG_CACHE_HOME; a mock ps reports its RSS. The fake
# models the ~15s bun unwind: on SIGTERM it takes UNWIND seconds to exit, then
# drops the alive sentinel (the MCP probe goes dead) the way a real exit would.
xdg="$work/xdg"
mkdir -p "$xdg/qmd"
mock_ps="$bin/ps"
cat > "$mock_ps" <<'EOF'
#!/usr/bin/env bash
# Mimics `ps -o rss= -o etime= -o args= -p <pid>`: prints nothing and exits 1
# for a dead pid, like real ps.
pid="${!#}"
kill -0 "$pid" 2>/dev/null || exit 1
echo "$*" >> "$QMD_MOCK_STATE/ps-argv.log"
printf '%s 04:31:07 bun /x/dist/cli/qmd.js mcp --http --port 8181\n' "$QMD_MOCK_RSS_KB"
EOF
chmod +x "$mock_ps"
fake_daemon="$work/fake-daemon.sh"
cat > "$fake_daemon" <<'EOF'
#!/usr/bin/env bash
trap 'sleep "${UNWIND:-0}"; rm -f "$QMD_MOCK_STATE/alive"; exit 0' TERM
touch "$QMD_MOCK_STATE/alive"
while :; do sleep 1; done
EOF
chmod +x "$fake_daemon"

start_fake_daemon() { # <unwind secs> -> sets fake_pid, writes the pidfile
  UNWIND="$1" QMD_MOCK_STATE="$state" bash "$fake_daemon" &
  fake_pid=$!
  STUB_PIDS+=("$fake_pid")
  echo "$fake_pid" > "$xdg/qmd/mcp.pid"
  local i=0
  while [ ! -f "$state/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
  [ -f "$state/alive" ] || fail "precondition: fake daemon never came alive"
  [ "$QMD_TEST_FORCE_FAIL_AFTER" != "start_fake_daemon" ] || \
    fail "forced failure after start_fake_daemon (leak-test hook)"
}

# run_ceiling <rss_kb> [<ceiling_mb>] -> sets rc/out/dur; the hook's own wall time
run_ceiling() {
  rm -f "$state/qmd-argv.log"
  local t0 t1
  t0="$(date +%s)"
  set +e
  out="$(QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
    QMD_MOCK_RSS_KB="$1" QMD_PS="$mock_ps" XDG_CACHE_HOME="$xdg" \
    QMD_RSS_CEILING_MB="${2:-4096}" QMD_MCP_URL="$test_url" \
    HOME="$home" PATH="$bin:$safe" \
    bash "$script" 2>&1)"
  rc=$?
  set -e
  t1="$(date +%s)"
  dur=$((t1 - t0))
}

# Wait (bounded) for the detached recycler to finish: it restarted qmd and
# logged its restart rc (the lock is released right after that line).
wait_restarted() {
  local i=0
  while [ "$i" -lt 40 ]; do
    grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" 2>/dev/null &&
      grep -q 'recycle: restart rc=' "$xdg/qmd/recycle.log" 2>/dev/null &&
      [ ! -d "$xdg/qmd/recycle.lock" ] && return 0
    i=$((i + 1))
    sleep 0.5
  done
  return 1
}

# ---- (k) under the ceiling: no recycle, daemon untouched --------------------
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp"
start_fake_daemon 0
run_ceiling 1048576   # 1 GB
[ "$rc" -eq 0 ] || fail "(k) under-ceiling: expected rc 0, got $rc ($out)"
[ -f "$state/ps-argv.log" ] || fail "(k) under-ceiling: RSS was never read (ps not called) ($out)"
sleep 1
kill -0 "$fake_pid" 2>/dev/null || fail "(k) under-ceiling: daemon was killed below the ceiling"
[ ! -f "$state/qmd-argv.log" ] || fail "(k) under-ceiling: qmd was restarted below the ceiling"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null
echo "ok (k): RSS under the ceiling leaves the daemon alone"

# ---- (l) over the ceiling: hook returns promptly, recycle runs DETACHED -----
# The fake takes 4s to unwind; the hook must not wait for it (SessionStart
# budget) - it returns at once and the recycler finishes later.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
start_fake_daemon 4
run_ceiling 7340032   # 7 GB
[ "$rc" -eq 0 ] || fail "(l) over-ceiling: expected rc 0, got $rc ($out)"
[ "$dur" -lt 3 ] || fail "(l) over-ceiling: hook blocked ${dur}s on the recycle (must run detached)"
grep -q "recycling" <<< "$out" || \
  fail "(l) over-ceiling: no loud 'recycling' line (got: $out)"
kill -0 "$fake_pid" 2>/dev/null || true
wait_restarted || fail "(l) over-ceiling: detached recycler never restarted qmd ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill -0 "$fake_pid" 2>/dev/null && fail "(l) over-ceiling: old daemon still alive after the recycle"
[ -f "$xdg/qmd/recycle.stamp" ] || fail "(l) over-ceiling: no recycle stamp written"
grep -q 'recycle: restart rc=0' "$xdg/qmd/recycle.log" || \
  fail "(l) over-ceiling: restart did not succeed ($(cat "$xdg/qmd/recycle.log"))"
echo "ok (l): over the ceiling -> hook returned in ${dur}s, detached recycler stopped + restarted qmd"

# ---- (m) cooldown: a fresh stamp blocks a second recycle --------------------
rm -f "$state/alive" "$state/ps-argv.log"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(m) cooldown: expected rc 0, got $rc ($out)"
sleep 1
kill -0 "$fake_pid" 2>/dev/null || fail "(m) cooldown: daemon recycled again inside the cooldown"
grep -q "cooldown" <<< "$out" || fail "(m) cooldown: skip not reported (got: $out)"
kill "$fake_pid" 2>/dev/null; wait "$fake_pid" 2>/dev/null
echo "ok (m): a recycle inside the cooldown window is skipped"

# ---- (n) stampede: concurrent sessions start ONE recycle ---------------------
rm -f "$state/alive" "$state/ps-argv.log" "$state/qmd-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
start_fake_daemon 3
for s in 1 2 3 4 5; do
  ( QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
      QMD_MOCK_RSS_KB=7340032 QMD_PS="$mock_ps" XDG_CACHE_HOME="$xdg" \
      QMD_RSS_CEILING_MB=4096 QMD_MCP_URL="$test_url" \
      HOME="$home" PATH="$bin:$safe" \
      bash "$script" > "$work/n-$s.log" 2>&1 ) &
done
wait_restarted || fail "(n) stampede: no recycle happened"
sleep 2
starts="$(grep -c 'SIGTERM' "$xdg/qmd/recycle.log" 2>/dev/null || true)"
[ "$starts" = 1 ] || fail "(n) stampede: expected exactly 1 recycle, got ${starts:-0} ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill "$fake_pid" 2>/dev/null || true
wait 2>/dev/null || true
echo "ok (n): five concurrent sessions over the ceiling ran exactly one recycle"

# ---- (o) leading-zero knobs are decimal, never octal -------------------------
# `08` is not a valid octal literal: Bash arithmetic on it aborts the hook.
# `00` is zero, so it disables the ceiling exactly like `0`.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.log"
date +%s > "$xdg/qmd/recycle.stamp"
start_fake_daemon 0
run_ceiling 7340032 08
[ "$rc" -eq 0 ] || fail "(o) ceiling 08: expected rc 0, got $rc ($out)"
grep -q "ceiling 8 MB" <<< "$out" || fail "(o) ceiling 08: not read as 8 MB (got: $out)"
run_ceiling 7340032 00
[ "$rc" -eq 0 ] || fail "(o) ceiling 00: expected rc 0, got $rc ($out)"
grep -q "ceiling" <<< "$out" && fail "(o) ceiling 00: must disable the ceiling (got: $out)"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (o): ceiling 08 reads as 8 MB, 00 disables it"

# ---- (p) a lock whose owner has not yet written its 'at' is not stale --------
# A winner is between its mkdir and its 'at' write: a second session must judge
# the lock by the directory's own age, not reclaim it as ancient.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
mkdir "$xdg/qmd/recycle.lock"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(p) fresh lock: expected rc 0, got $rc ($out)"
grep -q "recycling" <<< "$out" && fail "(p) fresh lock without 'at' was reclaimed (got: $out)"
[ -d "$xdg/qmd/recycle.lock" ] || fail "(p) fresh lock without 'at' was removed"
kill -0 "$fake_pid" 2>/dev/null || fail "(p) daemon recycled while another session held the lock"
rm -rf "$xdg/qmd/recycle.lock"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (p): a fresh lock with no 'at' file is left to its owner"

# ---- (q) a stale lock is cleared, never taken over in the same run -----------
# Two sessions that both judged one lock stale could each remove the other's
# fresh lock and both recycle; so the reclaimer only clears it, and the next
# session start takes the lock through a plain mkdir.
rm -f "$state/alive" "$state/ps-argv.log" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
mkdir "$xdg/qmd/recycle.lock"
echo $(( $(date +%s) - 300 )) > "$xdg/qmd/recycle.lock/at"
start_fake_daemon 0
run_ceiling 7340032
[ "$rc" -eq 0 ] || fail "(q) stale lock: expected rc 0, got $rc ($out)"
grep -q "recycling" <<< "$out" && fail "(q) stale lock: the reclaiming run also recycled (got: $out)"
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(q) stale lock: not cleared"
run_ceiling 7340032
grep -q "recycling" <<< "$out" || fail "(q) stale lock: the next session did not recycle (got: $out)"
wait_restarted || fail "(q) stale lock: recycle after the clear never finished ($(cat "$xdg/qmd/recycle.log" 2>/dev/null))"
kill "$fake_pid" 2>/dev/null || true
wait "$fake_pid" 2>/dev/null || true
echo "ok (q): a stale lock is cleared, and the next session recycles"

# ---- (r) an embed-model swap in progress: the daemon is NOT started --
# qmd-embed-model.sh swap holds <cache>/qmd/embed-swap.lock (holder pid inside)
# from its liveness check to its commit/rollback. A daemon relaunched in that
# window served gemma query embeddings against qwen vectors. Every start path
# refuses while the holder is alive; a dead holder's lock is stale and cleared.
swap_lock="$home/.cache/qmd/embed-swap.lock"
rm -f "$state/alive"
mkdir -p "$swap_lock"
sleep 30 &
holder_pid=$!
echo "$holder_pid" > "$swap_lock/pid"
echo swap > "$swap_lock/role"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(r) swap held: expected a refusal, got rc 0 ($out)"
grep -q "swap" <<< "$out" || fail "(r) swap held: refusal does not name the swap (got: $out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(r) swap held: qmd was invoked ($(cat "$state/qmd-argv.log"))"
[ -d "$swap_lock" ] || fail "(r) swap held: a LIVE holder's lock was removed"
echo "ok (r): a live swap lock refuses the daemon start, qmd not invoked, lock kept"

# ---- (s) the swap's holder died: stale lock cleared, daemon starts -----------
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -f "$state/alive"
# another contender is mid-reclaim (its guard is fresh): do not clear under it,
# or both could win the lock
mkdir "$swap_lock.reclaim"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(s) reclaim in flight: expected a refusal, got rc 0 ($out)"
[ -d "$swap_lock" ] || fail "(s) reclaim in flight: the stale lock was cleared under another reclaimer"
[ ! -f "$state/qmd-argv.log" ] || fail "(s) reclaim in flight: qmd was invoked"
rmdir "$swap_lock.reclaim"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(s) stale swap lock: expected rc 0, got $rc ($out)"
[ ! -d "$swap_lock" ] || fail "(s) stale swap lock: not cleared"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || fail "(s) stale swap lock: the daemon was not started"
echo "ok (s): a swap lock whose holder is dead is cleared and the daemon starts"

# ---- (t) the start itself holds the lock, so a swap cannot slip in --
# Checking the lock and then starting leaves a window: a swap could take the lock
# between the two and pass its own liveness checks. The start path takes the same
# lock around the start, so a swap started meanwhile is refused, and releases it.
rm -f "$state/alive" "$state/lock-at-start"
export QMD_MOCK_LOCK_DIR="$swap_lock"
run_ensure sentinel "$bin:$safe"
unset QMD_MOCK_LOCK_DIR
[ "$rc" -eq 0 ] || fail "(t) start: expected rc 0, got $rc ($out)"
grep -qx held "$state/lock-at-start" 2>/dev/null || fail "(t) start: the swap lock was not held while the daemon started ($(cat "$state/lock-at-start" 2>/dev/null))"
[ ! -d "$swap_lock" ] || fail "(t) start: the lock was not released after the start"
echo "ok (t): the daemon start holds the swap lock and releases it"

# ---- (u) two sessions start together: neither is told a swap is running -------
# The chief launches several workers within a second, so two SessionStart hooks
# race for the lock. The loser sees an ENSURE holder, not a swap: it exits 0
# quietly (the other start is already on it), never "swap in progress".
rm -f "$state/alive" "$state/qmd-argv.log"
export QMD_MOCK_SLOW=2
u_pids=""
for n in 1 2; do
  (
    set +e
    QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
      QMD_START_TIMEOUT=20 QMD_MCP_URL="$test_url" HOME="$home" PATH="$bin:$safe" \
      bash "$script" > "$state/u$n.out" 2>&1
    echo "$?" > "$state/u$n.rc"
  ) &
  u_pids="$u_pids $!"
  sleep 0.3
done
# shellcheck disable=SC2086 # word-split the pid list on purpose
wait $u_pids
unset QMD_MOCK_SLOW
for n in 1 2; do
  [ "$(cat "$state/u$n.rc")" = "0" ] || fail "(u) concurrent start $n: expected rc 0, got $(cat "$state/u$n.rc") ($(cat "$state/u$n.out"))"
  if grep -q "swap" "$state/u$n.out"; then fail "(u) concurrent start $n: told a swap is in progress ($(cat "$state/u$n.out"))"; fi
done
[ "$(grep -c '^mcp --http --daemon$' "$state/qmd-argv.log")" = "1" ] || fail "(u) concurrent starts: expected exactly one daemon start ($(cat "$state/qmd-argv.log"))"
[ ! -d "$swap_lock" ] || fail "(u) concurrent starts: the lock was not released"
echo "ok (u): two concurrent starts both exit 0, no swap message, one daemon start"

# ---- (v) a live holder with no role yet is treated as a swap (conservative) ---
rm -f "$state/alive"
mkdir -p "$swap_lock"
sleep 30 &
holder_pid=$!
echo "$holder_pid" > "$swap_lock/pid"
run_ensure sentinel "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(v) role-less live holder: expected a refusal, got rc 0 ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(v) role-less live holder: qmd was invoked"
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true
rm -rf "$swap_lock"
echo "ok (v): a live holder with no role is refused like a swap"

# ---- (w) operator opt-out: flag file / env => never launch ------
off_flag="$home/.himmel/state/qmd-daemon.off"
mkdir -p "$(dirname "$off_flag")"
: > "$off_flag"
rm -f "$state/alive"
run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(w) flag present: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(w) flag present: qmd was invoked"
[ ! -f "$state/alive" ] || fail "(w) flag present: daemon was started"
case "$out" in *"qmd is OFF"*qmd-daemon-switch.sh*on*) : ;; *) fail "(w) flag present: no INFO line naming how to turn it on ($out)" ;; esac
[ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] || fail "(w) flag present: expected exactly one line ($out)"
rm -f "$off_flag"
run_ensure sentinel "$bin:$safe"
{ [ "$rc" -eq 0 ] && [ -f "$state/alive" ]; } || fail "(w) flag removed: today's launch behaviour not restored ($out)"
echo "ok (w): flag file present => exit 0, one INFO line, never launches; absent => launches"

rm -f "$state/alive"
QMD_DAEMON_DISABLED=1 run_ensure sentinel "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(w2) env: expected rc 0, got $rc ($out)"
{ [ ! -f "$state/qmd-argv.log" ] && [ ! -f "$state/alive" ]; } || fail "(w2) QMD_DAEMON_DISABLED=1: daemon launched"
case "$out" in *"qmd is OFF"*) : ;; *) fail "(w2) env: no INFO line ($out)" ;; esac
echo "ok (w2): QMD_DAEMON_DISABLED=1 => never launches"

# ---- (x) qmd-daemon-switch.sh off / on ----------------------------------------
switch="$(dirname "$script")/qmd-daemon-switch.sh"
[ -f "$switch" ] || fail "(x) $switch not found"
export XDG_CACHE_HOME="$work/cache"
mkdir -p "$XDG_CACHE_HOME/qmd"
real_ps="$(command -v ps)"
# Stale pid: a live process that is NOT a qmd mcp one must be left alone, and pid 0 refused.
sleep 60 &
stale_pid=$!
STUB_PIDS+=("$stale_pid")
echo "$stale_pid" > "$XDG_CACHE_HOME/qmd/mcp.pid"
set +e
out="$(HOME="$home" PATH="$bin:$safe" QMD_PS="$real_ps" bash "$switch" off 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(x) stale pid: rc $rc ($out)"
sleep 0.5
kill -0 "$stale_pid" 2>/dev/null || fail "(x) stale pid: a non-qmd process was killed"
case "$out" in *"not a qmd mcp process"*) : ;; *) fail "(x) stale pid: no left-alone message ($out)" ;; esac
kill "$stale_pid" 2>/dev/null || true
wait "$stale_pid" 2>/dev/null || true
echo 0 > "$XDG_CACHE_HOME/qmd/mcp.pid"
set +e
out="$(HOME="$home" PATH="$bin:$safe" QMD_PS="$real_ps" bash "$switch" off 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(x) pid 0: rc $rc ($out)"
case "$out" in *"no running daemon found"*) : ;; *) fail "(x) pid 0: not refused ($out)" ;; esac
rm -f "$off_flag"
# A real qmd mcp-looking daemon (args contain "qmd" then "mcp") is stopped.
fake_script="$work/qmd-mcp-fake.sh"
printf '%s\n' "trap 'exit 0' TERM" 'while :; do sleep 1; done' > "$fake_script"
bash "$fake_script" &
fake_daemon=$!
STUB_PIDS+=("$fake_daemon")
echo "$fake_daemon" > "$XDG_CACHE_HOME/qmd/mcp.pid"
set +e
out="$(HOME="$home" PATH="$bin:$safe" QMD_PS="$real_ps" bash "$switch" off 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(x) off: rc $rc ($out)"
[ -f "$off_flag" ] || fail "(x) off: flag not created"
sleep 2
if kill -0 "$fake_daemon" 2>/dev/null; then fail "(x) off: daemon pid $fake_daemon still alive"; fi
rm -f "$state/alive" "$state/qmd-argv.log"
set +e
out="$(HOME="$home" PATH="$bin:$safe" QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" QMD_MCP_URL="$test_url" bash "$switch" on 2>&1)"; rc=$?
set -e
[ "$rc" -eq 0 ] || fail "(x) on: rc $rc ($out)"
[ ! -f "$off_flag" ] || fail "(x) on: flag still present"
[ -f "$state/alive" ] || fail "(x) on: ensure script did not start the daemon ($out)"
set +e
out="$(HOME="$home" bash "$switch" bogus 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "(x) bogus arg: expected nonzero"
unset XDG_CACHE_HOME
echo "ok (x): switch off creates flag + stops daemon; on removes flag + runs ensure"

# ---- (x2) `off` landing after ensure's opt-out check must still win -----------
# The first probe stalls (pause curl) AFTER the early flag check; `off` runs in
# that window; the daemon must not launch. Control: no `off`, ensure launches.
pause_curl="$bin/pause-curl"
cat > "$pause_curl" <<'EOF'
#!/usr/bin/env bash
if [ ! -f "$QMD_MOCK_STATE/probed" ]; then
  touch "$QMD_MOCK_STATE/probed" "$QMD_MOCK_STATE/in-probe"
  w=0
  while [ ! -f "$QMD_MOCK_STATE/release" ] && [ "$w" -lt 100 ]; do sleep 0.1; w=$((w + 1)); done
fi
exec "$QMD_MOCK_REAL_CURL" "$@"
EOF
chmod +x "$pause_curl"
race_ensure() {  # race_ensure <do-off:0|1> -> launched iff $state/alive exists
  rm -f "$off_flag" "$state/alive" "$state/qmd-argv.log" "$state/probed" "$state/in-probe" "$state/release"
  HOME="$home" PATH="$bin:$safe" QMD_CURL="$pause_curl" QMD_MOCK_REAL_CURL="$mock_curl" \
    QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" QMD_MCP_URL="$test_url" \
    bash "$script" >/dev/null 2>&1 &
  race_pid=$!
  STUB_PIDS+=("$race_pid")
  race_i=0
  while [ ! -f "$state/in-probe" ] && [ "$race_i" -lt 100 ]; do sleep 0.1; race_i=$((race_i + 1)); done
  [ -f "$state/in-probe" ] || fail "(x2) ensure never reached its first probe"
  if [ "$1" = 1 ]; then
    HOME="$home" PATH="$bin:$safe" timeout 20 bash "$switch" off >/dev/null 2>&1 || fail "(x2) off failed or hung"
  fi
  touch "$state/release"
  set +e
  wait "$race_pid" 2>/dev/null
  race_rc=$?
  set -e
  [ "$race_rc" -eq 0 ] || fail "(x2) ensure exited $race_rc"
}
race_ensure 0
[ -f "$state/alive" ] || fail "(x2) control: no opt-out, ensure should launch"
race_ensure 1
[ ! -f "$state/alive" ] || fail "(x2) off during the probe window: daemon still launched"
[ -f "$off_flag" ] || fail "(x2) off did not set the flag"
rm -f "$off_flag"
echo "ok (x2): off between ensure's early check and the launch stops the launch; control launches"

# ---- (x3) off waits for a launch holding the lock, then stops the daemon it made
swap_lock="$home/.cache/qmd/embed-swap.lock"
rm -rf "$swap_lock"; rm -f "$off_flag"
mkdir -p "$swap_lock"
echo ensure > "$swap_lock/role"
sleep 30 &
holder_pid=$!
STUB_PIDS+=("$holder_pid")
echo "$holder_pid" > "$swap_lock/pid"
bash "$fake_script" &
late_daemon=$!
STUB_PIDS+=("$late_daemon")
( sleep 2; echo "$late_daemon" > "$home/.cache/qmd/mcp.pid"; rm -rf "$swap_lock" ) &
STUB_PIDS+=("$!")
HOME="$home" PATH="$bin:$safe" QMD_PS="$real_ps" timeout 20 bash "$switch" off >/dev/null 2>&1 || fail "(x3) off failed or hung"
sleep 1
if kill -0 "$late_daemon" 2>/dev/null; then fail "(x3) off did not wait for the lock holder and missed its daemon"; fi
[ ! -d "$swap_lock" ] || fail "(x3) off left the lock behind"
rm -f "$off_flag"
echo "ok (x3): off waits for a launch holding the lock, then stops the daemon it started"

# ---- (y) authenticated daemon: MCP route 401, /health 200 -> alive ----------
# The probe holds no (or a stale) bearer token, so the MCP route answers 401
# while the daemon is healthy. That is "alive, auth required", never dead.
rm -f "$state/alive"
run_ensure auth401 "$bin:$safe"
[ "$rc" -eq 0 ] || fail "(y) auth401: expected rc 0, got $rc ($out)"
[ ! -f "$state/qmd-argv.log" ] || fail "(y) auth401: qmd was invoked but the daemon was already alive"
echo "ok (y): MCP route 401 + /health 200 -> reported alive, qmd not invoked"

# ---- (y2) control: MCP route 401 but /health dead -> not alive ---------------
rm -f "$state/alive"
QMD_MOCK_HEALTH=000 run_ensure auth401 "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(y2) auth401+dead health: expected nonzero rc"
printf '%s' "$out" | grep -q "nothing came alive" || \
  fail "(y2) auth401+dead health: missing 'nothing came alive' message (got: $out)"
echo "ok (y2): MCP route 401 with /health dead -> still reported not alive"

# ---- (y3) control: 401 + a 200 /health that is not qmd's -> not alive --------
# A foreign auth-gated service on the port must still hit the not-qmd path.
rm -f "$state/alive"
QMD_MOCK_HEALTH_BODY='OK' run_ensure auth401 "$bin:$safe"
[ "$rc" -ne 0 ] || fail "(y3) auth401+foreign health: expected nonzero rc"
echo "ok (y3): MCP route 401 with a non-qmd /health body -> not reported alive"

fake_daemon="$work/fake-daemon.sh"
bin2="$work/bin2"
mkdir -p "$bin2"
cp "$bin/timeout" "$bin2/timeout" 2>/dev/null || true
cat > "$bin2/ps" <<'EOF'
#!/usr/bin/env bash
pid="${!#}"
kill -0 "$pid" 2>/dev/null || exit 1
args="${QMD_MOCK_PS_ARGS:-bun /x/dist/cli/qmd.js mcp --http --port 8181}"
[ "$(cat "$QMD_MOCK_STATE/ps-flip" 2>/dev/null)" != "$pid" ] || args="vim notes.txt"
printf ' %s %s\n' "${QMD_MOCK_PS_ETIME:-10:00:00}" "$args"
EOF
chmod +x "$bin2/ps"
cat > "$bin2/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-argv.log"
sd() { if command -v setsid >/dev/null 2>&1; then exec setsid "$@"; else exec python3 -c 'import os,sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' "$@"; fi; }
[ "${QMD_MOCK_STEAL_LOCK:-0}" != 1 ] || echo 999999 > "$XDG_CACHE_HOME/qmd/recycle.lock/owner"
if [ "$*" = "mcp --http --daemon" ] && [ "${QMD_MOCK_NOSTART:-0}" != 1 ]; then
  if [ "${QMD_MOCK_NOANSWER:-0}" = 1 ]; then
    sd sleep 300 </dev/null >/dev/null 2>&1 &
  else
    UNWIND=0 QMD_MOCK_STATE="$QMD_MOCK_STATE" sd bash "$QMD_MOCK_FAKE" </dev/null >/dev/null 2>&1 &
  fi
  echo $! > "$XDG_CACHE_HOME/qmd/mcp.pid"
  disown
  i=0
  while [ ! -f "$QMD_MOCK_STATE/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
fi
exit 0
EOF
chmod +x "$bin2/qmd"

epoch_fmt() { date -d "@$1" +%Y%m%d%H%M.%S 2>/dev/null || date -r "$1" +%Y%m%d%H%M.%S; }
touch_ago() { touch -t "$(epoch_fmt $(( $(date +%s) - $2 )))" "$1"; }
stale_stamp="$work/build-stamp"
stale_pf="$xdg/qmd/mcp.pid"

stale_case() {
  rm -f "$state/alive" "$state/qmd-argv.log" "$state/ps-flip" "$xdg/qmd/recycle.stamp" "$xdg/qmd/recycle.log"
  rm -rf "$xdg/qmd/recycle.lock"
  start_fake_daemon "$1"
  old_pid="$fake_pid"
  : > "$stale_stamp"
  touch_ago "$stale_pf" 18000
  touch_ago "$stale_stamp" 3600
}
run_stale() {
  set +e
  out="$(env QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_STATE="$state" \
    QMD_MOCK_FAKE="$fake_daemon" QMD_PS="$bin2/ps" XDG_CACHE_HOME="$xdg" \
    QMD_MCP_URL="$test_url" HOME="$home" PATH="$bin2:$safe" "$@" \
    bash "$script" --recycle-if-stale "$stale_stamp" 2>&1)"
  rc=$?
  set -e
}
reap_new() {
  local p
  p="$(cat "$stale_pf" 2>/dev/null)" || p=
  case "$p" in ''|*[!0-9]*) ;; *) STUB_PIDS+=("$p"); kill "$p" 2>/dev/null || true ;; esac
  kill -KILL "$old_pid" 2>/dev/null || true
  wait "$old_pid" 2>/dev/null || true
  return 0
}

stale_case 0
run_stale
[ "$rc" -eq 0 ] || fail "(z1) stale: expected rc 0, got $rc ($out)"
kill -0 "$old_pid" 2>/dev/null && fail "(z1) stale: the old server is still alive"
grep -qx 'mcp --http --daemon' "$state/qmd-argv.log" || fail "(z1) stale: no restart ($(cat "$state/qmd-argv.log" 2>/dev/null))"
[ "$stale_pf" -nt "$stale_stamp" ] || fail "(z1) stale: the new pidfile is not newer than the stamp"
[ "$(cat "$stale_pf")" != "$old_pid" ] || fail "(z1) stale: the pidfile still names the old pid"
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(z1) stale: the recycle lock was left behind"
reap_new
echo "ok (z1): a server older than the build is recycled in the foreground; the new pidfile is newer"

stale_case 0
touch_ago "$stale_pf" 60
run_stale
[ "$rc" -eq 0 ] || fail "(z2) fresh: expected rc 0, got $rc ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z2) fresh: a current server was stopped"
[ ! -f "$state/qmd-argv.log" ] || fail "(z2) fresh: qmd was invoked"
reap_new
stale_case 0
touch_ago "$stale_pf" 60
run_stale QMD_MOCK_PS_ARGS="vim notes.txt"
[ "$rc" -ne 0 ] || fail "(z2) fresh pidfile, foreign pid: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z2) fresh pidfile, foreign pid: a process was stopped"
reap_new
echo "ok (z2): a server newer than the build is left alone; a fresh pidfile naming another program is 'cannot verify'"

stale_case 0
run_stale QMD_MOCK_PS_ARGS="bun /x/dist/cli/qmd.js mcp"
[ "$rc" -ne 0 ] || fail "(z3) stdio argv: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z3) stdio argv: a per-session stdio server was stopped"
reap_new
stale_case 0
run_stale QMD_MOCK_PS_ARGS="vim notes.txt"
[ "$rc" -ne 0 ] || fail "(z3) foreign argv: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z3) foreign argv: a foreign program was stopped"
reap_new
echo "ok (z3): a stdio-shaped or foreign pid is never signalled, and the rc is non-zero"

stale_case 0
run_stale QMD_MOCK_PS_ETIME="00:05"
[ "$rc" -ne 0 ] || fail "(z4) reused pid: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z4) reused pid: a process younger than the pidfile was stopped"
reap_new
echo "ok (z4): a pid reused after the pidfile was written is never signalled"

stale_case 0
rm -f "$stale_pf"
run_stale
[ "$rc" -ne 0 ] || fail "(z5) no pidfile: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z5) no pidfile: a process was stopped without a pidfile"
[ ! -f "$state/qmd-argv.log" ] || fail "(z5) no pidfile: qmd was invoked"
echo "banana" > "$stale_pf"; touch_ago "$stale_pf" 18000
run_stale
[ "$rc" -ne 0 ] || fail "(z5) garbage pidfile: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z5) garbage pidfile: a process was stopped"
rm -f "$stale_pf"; reap_new
echo "ok (z5): a missing or garbage pidfile is 'cannot verify': non-zero, nothing signalled, no process-list scan"

stale_case 0
mkdir "$xdg/qmd/recycle.lock"
date +%s > "$xdg/qmd/recycle.lock/at"
run_stale QMD_STALE_LOCK_WAIT=2
[ "$rc" -ne 0 ] || fail "(z6) lock held: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z6) lock held: the server was stopped under another recycler"
[ -d "$xdg/qmd/recycle.lock" ] || fail "(z6) lock held: another recycler's lock was removed"
rm -rf "$xdg/qmd/recycle.lock"; reap_new
echo "ok (z6): a lock held by a live recycler -> no action within the bound, non-zero"

stale_case 0
mkdir "$xdg/qmd/recycle.lock"
echo $(( $(date +%s) - 300 )) > "$xdg/qmd/recycle.lock/at"
run_stale QMD_STALE_LOCK_WAIT=5
[ "$rc" -ne 0 ] || fail "(z7) stale lock: expected a non-zero rc, got 0 ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z7) stale lock: the server was stopped after clearing a stale lock"
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(z7) stale lock: left behind"
[ ! -f "$state/qmd-argv.log" ] || fail "(z7) stale lock: qmd was invoked"
case "$out" in *"cleared a stale recycle lock"*) ;; *) fail "(z7) stale lock: no cleared-lock message ($out)" ;; esac
reap_new
echo "ok (z7): a stale recycle lock is cleared and the run stops non-zero without signalling"

stale_case 0
run_stale QMD_MOCK_STEAL_LOCK=1
[ -d "$xdg/qmd/recycle.lock" ] || fail "(z7b) foreign owner: our trap removed a lock another pid owns ($out)"
[ "$(cat "$xdg/qmd/recycle.lock/owner" 2>/dev/null)" = 999999 ] || fail "(z7b) foreign owner: the owner file changed"
rm -rf "$xdg/qmd/recycle.lock"; reap_new
echo "ok (z7b): the exit trap removes the lock only while it still names our pid"

stale_case 0
date +%s > "$xdg/qmd/recycle.stamp"
run_stale
[ "$rc" -eq 0 ] || fail "(z8) cooldown active: expected rc 0, got $rc ($out)"
kill -0 "$old_pid" 2>/dev/null && fail "(z8) cooldown active: the stale server was not recycled"
reap_new
echo "ok (z8): a fresh RSS-recycle stamp does not block a staleness recycle"

stale_case 0
run_stale QMD_MOCK_NOSTART=1
[ "$rc" -ne 0 ] || fail "(z9) failed restart: expected a non-zero rc, got 0 ($out)"
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(z9) failed restart: the lock was left behind"
reap_new
echo "ok (z9): a restart that brings nothing up exits non-zero and frees the lock"

stale_case 0
run_stale QMD_MOCK_NOANSWER=1
[ "$rc" -ne 0 ] || fail "(z9b) live but silent replacement: expected a non-zero rc, got 0 ($out)"
case "$out" in *"no qmd server newer than"*) ;; *) fail "(z9b) live but silent replacement: no not-serving message ($out)" ;; esac
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(z9b) live but silent replacement: the lock was left behind"
reap_new
echo "ok (z9b): a replacement that is alive with a fresh pidfile but answers no MCP initialize is not reported as serving"

stale_case 0
rm -f "$state/alive"
touch_ago "$stale_pf" 60
run_stale
[ "$rc" -ne 0 ] || fail "(z9c) fresh pidfile, silent server: expected a non-zero rc, got 0 ($out)"
case "$out" in *"answers no MCP initialize"*) ;; *) fail "(z9c) fresh pidfile, silent server: no silent-server reason ($out)" ;; esac
kill -0 "$old_pid" 2>/dev/null || fail "(z9c) fresh pidfile, silent server: a process was stopped"
reap_new
echo "ok (z9c): a fresh pidfile naming a live but silent server is not reported as serving"

stale_case 0
touch_ago "$stale_pf" 60
run_stale QMD_MOCK_SENTINEL_AUTH=1
[ "$rc" -ne 0 ] || fail "(z9d) fresh pidfile, 401 server: expected a non-zero rc, got 0 ($out)"
case "$out" in *"rejected the MCP token"*) ;; *) fail "(z9d) fresh pidfile, 401 server: no rejected-token reason ($out)" ;; esac
reap_new
echo "ok (z9d): a fresh pidfile whose server answers 401 is not reported as serving"

stale_case 0
run_stale QMD_MOCK_SENTINEL_AUTH=1
[ "$rc" -ne 0 ] || fail "(z9e) replacement answers 401: expected a non-zero rc, got 0 ($out)"
case "$out" in *"rejected the MCP token"*) ;; *) fail "(z9e) replacement answers 401: no rejected-token reason ($out)" ;; esac
[ ! -d "$xdg/qmd/recycle.lock" ] || fail "(z9e) replacement answers 401: the lock was left behind"
reap_new
echo "ok (z9e): a replacement that answers 401 is not reported as serving the new build"

stale_case 0
run_stale
[ "$rc" -eq 0 ] || fail "(z9f) replacement answers 200: expected rc 0, got $rc ($out)"
case "$out" in *"rejected the MCP token"*|*"answers no MCP initialize"*) fail "(z9f) replacement answers 200: a failure reason was printed ($out)" ;; esac
reap_new
echo "ok (z9f): a replacement that accepts the MCP initialize is reported as serving"

stale_case 0
cat > "$work/stubborn.sh" <<'EOF'
#!/usr/bin/env bash
trap '[ ! -e "$QMD_MOCK_STATE/term-seen" ] || exit 0; touch "$QMD_MOCK_STATE/term-seen"; rm -f "$QMD_MOCK_STATE/alive"' TERM
touch "$QMD_MOCK_STATE/alive"
while :; do sleep 1; done
EOF
kill "$old_pid" 2>/dev/null || true; wait "$old_pid" 2>/dev/null || true
rm -f "$state/term-seen" "$state/alive"
QMD_MOCK_STATE="$state" bash "$work/stubborn.sh" &
old_pid=$!
STUB_PIDS+=("$old_pid")
echo "$old_pid" > "$stale_pf"; touch_ago "$stale_pf" 18000
i=0; while [ ! -f "$state/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
run_stale QMD_STALE_TERM_WAIT=2
[ "$rc" -eq 0 ] || fail "(z10) stubborn: expected rc 0, got $rc ($out)"
[ -f "$state/term-seen" ] || fail "(z10) stubborn: SIGTERM was never sent first"
kill -0 "$old_pid" 2>/dev/null && fail "(z10) stubborn: a server that ignores SIGTERM survived"
reap_new
rm -f "$state/term-seen" "$state/alive" "$state/ps-flip" "$state/qmd-argv.log"
cat > "$work/handoff.sh" <<'EOF'
#!/usr/bin/env bash
trap '[ ! -e "$QMD_MOCK_STATE/ps-flip" ] || exit 0; echo $$ > "$QMD_MOCK_STATE/ps-flip"; rm -f "$QMD_MOCK_STATE/alive"' TERM
touch "$QMD_MOCK_STATE/alive"
while :; do sleep 1; done
EOF
QMD_MOCK_STATE="$state" bash "$work/handoff.sh" &
old_pid=$!
STUB_PIDS+=("$old_pid")
echo "$old_pid" > "$stale_pf"; touch_ago "$stale_pf" 18000
i=0; while [ ! -f "$state/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
run_stale QMD_STALE_TERM_WAIT=2
kill -0 "$old_pid" 2>/dev/null || fail "(z10) handed-off pid: SIGKILL went to a pid that no longer passes the identity check"
[ "$rc" -eq 0 ] || fail "(z10) handed-off pid: expected the restart to succeed, got rc $rc ($out)"
[ "$(cat "$stale_pf")" != "$old_pid" ] || fail "(z10) handed-off pid: the pidfile still names the old pid"
reap_new
echo "ok (z10): SIGTERM first, SIGKILL only while the pid still passes the identity check"

stale_case 0
run_stale QMD_DAEMON_DISABLED=1
[ "$rc" -eq 10 ] || fail "(z11) opted out: expected rc 10, got $rc ($out)"
kill -0 "$old_pid" 2>/dev/null || fail "(z11) opted out: the server was signalled"
reap_new
echo "ok (z11): an opted-out --recycle-if-stale exits 10 and recycles nothing"

units="$work/units"
cat > "$bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/systemctl.log"
if [ "${1:-}" = --user ] && [ "${2:-}" = show ]; then
  f="$QMD_MOCK_STATE/show-${4:-}-${6:-}"
  [ -f "$f" ] && cat "$f"  # read-sink-ok: the stub reads only its own fixture directory
  exit 0
fi
exit 0
EOF
chmod +x "$bin/systemctl"
run_boot() {
  set +e
  out="$(QMD_SYSTEMCTL="$bin/systemctl" QMD_UNIT_DIR="$units" QMD_MOCK_STATE="$state" \
    HOME="$home" PATH="$bin:$safe" bash "$script" "$@" 2>&1)"
  rc=$?
  set -e
}
set_show() { printf '%s\n' "$3" > "$state/show-$1-$2"; }

rm -f "$state/systemctl.log"
run_boot --install-boot-unit
[ "$rc" -eq 0 ] || fail "(z12) install: expected rc 0, got $rc ($out)"
unit="$units/qmd-daemon.service"
[ -f "$unit" ] || fail "(z12) install: $unit was not written ($out)"
grep -qxF 'Before=himmel-recover.service' "$unit" || fail "(z12) install: the unit does not order before the chief launcher: $(cat "$unit")"
grep -qxF 'WantedBy=default.target' "$unit" || fail "(z12) install: the unit is not wanted at boot: $(cat "$unit")"
grep -qxF 'Type=oneshot' "$unit" || fail "(z12) install: the unit is not a oneshot: $(cat "$unit")"
grep -qxF "ExecStart=/usr/bin/env bash \"$script\"" "$unit" || fail "(z12) install: the unit does not run the ensure script: $(cat "$unit")"
grep -qxF 'Environment=PATH=%h/.bun/bin:/usr/local/bin:/usr/bin:/bin' "$unit" || fail "(z12) install: the unit PATH does not reach bun: $(cat "$unit")"
grep -qxF -- '--user daemon-reload' "$state/systemctl.log" || fail "(z12) install: no daemon-reload ($(cat "$state/systemctl.log"))"
grep -qxF -- '--user enable qmd-daemon.service' "$state/systemctl.log" || fail "(z12) install: unit not enabled ($(cat "$state/systemctl.log"))"
first="$(cat "$unit")"
run_boot --install-boot-unit
[ "$rc" -eq 0 ] && [ "$(cat "$unit")" = "$first" ] || fail "(z12) install: a second run changed the unit or failed (rc $rc)"
echo "ok (z12): --install-boot-unit writes an enabled oneshot unit ordered before the chief launcher"

U=qmd-daemon.service; C=himmel-recover.service
set_show Before "$U" "$C"
set_show ActiveEnterTimestampMonotonic "$U" 5000000
set_show ExecMainStartTimestampMonotonic "$C" 9000000
run_boot --boot-order-check
[ "$rc" -eq 0 ] || fail "(z13a) qmd first: expected rc 0, got $rc ($out)"
case "$out" in *"$U started before $C"*) ;; *) fail "(z13a) qmd first: no ordering line ($out)" ;; esac

set_show ActiveEnterTimestampMonotonic "$U" 9000000
set_show ExecMainStartTimestampMonotonic "$C" 5000000
run_boot --boot-order-check
[ "$rc" -eq 1 ] || fail "(z13b) qmd after the chief: expected rc 1, got $rc ($out)"
case "$out" in *"$U started AFTER $C"*) ;; *) fail "(z13b) qmd after the chief: no AFTER line ($out)" ;; esac

set_show ActiveEnterTimestampMonotonic "$U" 0
run_boot --boot-order-check
[ "$rc" -eq 1 ] || fail "(z13c) qmd never started: expected rc 1, got $rc ($out)"
case "$out" in *"$U did not start this boot"*) ;; *) fail "(z13c) qmd never started: no did-not-start line ($out)" ;; esac

set_show ActiveEnterTimestampMonotonic "$U" 5000000
set_show ExecMainStartTimestampMonotonic "$C" 0
run_boot --boot-order-check
[ "$rc" -eq 0 ] || fail "(z13d) chief launcher idle: expected rc 0, got $rc ($out)"
case "$out" in *"$C did not start this boot"*) ;; *) fail "(z13d) chief launcher idle: no idle line ($out)" ;; esac

set_show Before "$U" ""
set_show ExecMainStartTimestampMonotonic "$C" 9000000
run_boot --boot-order-check
[ "$rc" -eq 1 ] || fail "(z13e) order not declared: expected rc 1, got $rc ($out)"
case "$out" in *"does not order before $C"*) ;; *) fail "(z13e) order not declared: no refusal line ($out)" ;; esac
set_show Before "$U" "$C"
set_show ActiveEnterTimestampMonotonic "$U" 5000000
rm -f "$state/show-ExecMainStartTimestampMonotonic-$C"
run_boot --boot-order-check
[ "$rc" -eq 1 ] || fail "(z13f) unreadable chief start time: expected rc 1, got $rc ($out)"
case "$out" in *"cannot read the start time of $C"*) ;; *) fail "(z13f) unreadable chief start time: no refusal line ($out)" ;; esac

set_show ActiveEnterTimestampMonotonic "$U" 9000000
set_show ActiveEnterTimestampMonotonic "$C" 0
set_show ExecMainStartTimestampMonotonic "$C" 5000000
run_boot --boot-order-check
[ "$rc" -eq 1 ] || fail "(z13g) a oneshot chief launcher has ActiveEnter 0 but ran first: expected rc 1, got $rc ($out)"
case "$out" in *"$U started AFTER $C"*) ;; *) fail "(z13g) a oneshot chief launcher has ActiveEnter 0 but ran first: no AFTER line ($out)" ;; esac
echo "ok (z13): --boot-order-check proves qmd started before the chief launcher, and fails on the other orders"

ps3="$work/ps3"
mkdir -p "$ps3"
cat > "$ps3/ps" <<'EOF'
#!/usr/bin/env bash
pid="${!#}"
kill -0 "$pid" 2>/dev/null || exit 1
echo "$pid" >> "$QMD_MOCK_STATE/ps3-pids.log"
case "$*" in *rss=*) printf '%s ' "$(cat "$QMD_MOCK_STATE/ps3-rss-$pid")" ;; esac
printf '%s %s\n' "${QMD_PS3_ETIME:-10:00:00}" "$(cat "$QMD_MOCK_STATE/ps3-args-$pid")"
EOF
chmod +x "$ps3/ps"
xdg3="$work/xdg3"
mkdir -p "$xdg3/qmd"
default_argv="bun /x/dist/cli/qmd.js mcp --http --port 8181"
gmail_argv="bun /x/dist/cli/qmd.js --index gmail --port $test_port mcp --http --daemon"
set_proc() { echo "$2" > "$state/ps3-rss-$1"; echo "$3" > "$state/ps3-args-$1"; }
two_procs() {
  rm -f "$xdg3/qmd/"* "$state/ps3-pids.log"
  sleep 300 & dflt_pid=$!
  sleep 300 & gm_pid=$!
  STUB_PIDS+=("$dflt_pid" "$gm_pid")
  echo "$dflt_pid" > "$xdg3/qmd/mcp.pid"
  echo "$gm_pid" > "$xdg3/qmd/mcp-gmail.pid"
  set_proc "$dflt_pid" "$2" "$1"
  set_proc "$gm_pid" "$4" "$3"
}
run_idx() {
  local -a envs=() margs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  margs=("$@")
  set +e
  out="$(env QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=alive QMD_MOCK_STATE="$state" QMD_PS="$ps3/ps" \
    XDG_CACHE_HOME="$xdg3" QMD_RSS_CEILING_MB=4096 QMD_MCP_URL="$test_url" HOME="$home" PATH="$bin:$safe" ${envs[@]+"${envs[@]}"} \
    bash "$script" ${margs[@]+"${margs[@]}"} 2>&1)"
  rc=$?
  set -e
}
reap_two() { kill "$dflt_pid" "$gm_pid" 2>/dev/null || true; wait "$dflt_pid" "$gm_pid" 2>/dev/null || true; }

two_procs "$default_argv" 7340032 "$gmail_argv" 1048576
run_idx QMD_INDEX_NAME=gmail
[ "$rc" -eq 0 ] || fail "(z14) named healthy: expected rc 0, got $rc ($out)"
grep -qx "$gm_pid" "$state/ps3-pids.log" || fail "(z14) named healthy: mcp-gmail.pid was never read"
grep -qx "$dflt_pid" "$state/ps3-pids.log" && fail "(z14) named healthy: the default index's mcp.pid was read"
case "$out" in *recycling*) fail "(z14) named healthy: a recycle started ($out)" ;; esac
for f in "$xdg3/qmd"/recycle*; do [ ! -e "$f" ] || fail "(z14) named healthy: recycle state was written ($f)"; done
kill -0 "$dflt_pid" 2>/dev/null || fail "(z14) named healthy: the default index's server was stopped"
reap_two
echo "ok (z14): a healthy named index reads its own pidfile and leaves the default index's over-ceiling server alone"

two_procs "$default_argv" 1048576 "$gmail_argv" 1048576
kill -KILL "$gm_pid" 2>/dev/null; wait "$gm_pid" 2>/dev/null || true
rm -f "$state/alive" "$state/qmd-argv.log"
UNWIND=0 QMD_MOCK_STATE="$state" bash "$fake_daemon" &
gm_pid=$!
STUB_PIDS+=("$gm_pid")
echo "$gm_pid" > "$xdg3/qmd/mcp-gmail.pid"
set_proc "$gm_pid" 7340032 "$gmail_argv"
i=0; while [ ! -f "$state/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done
mkdir -p "$ps3/bin5"
cat > "$ps3/bin5/qmd" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$QMD_MOCK_STATE/qmd-argv.log"
case " $* " in
  *" --index gmail "*)
    UNWIND=0 QMD_MOCK_STATE="$QMD_MOCK_STATE" bash "$QMD_MOCK_FAKE" </dev/null >/dev/null 2>&1 &
    p=$!
    echo "$p" > "$XDG_CACHE_HOME/qmd/mcp-gmail.pid"
    echo 1048576 > "$QMD_MOCK_STATE/ps3-rss-$p"
    echo "bun /x/dist/cli/qmd.js $*" > "$QMD_MOCK_STATE/ps3-args-$p"
    disown
    i=0; while [ ! -f "$QMD_MOCK_STATE/alive" ] && [ "$i" -lt 50 ]; do i=$((i + 1)); sleep 0.1; done ;;
esac
exit 0
EOF
chmod +x "$ps3/bin5/qmd"
run_idx QMD_INDEX_NAME=gmail QMD_MOCK_CURL_MODE=sentinel QMD_MOCK_FAKE="$fake_daemon" PATH="$ps3/bin5:$bin:$safe"
[ "$rc" -eq 0 ] || fail "(z14b) named over ceiling: expected rc 0, got $rc ($out)"
case "$out" in *"log: $xdg3/qmd/recycle-gmail.log"*) ;; *) fail "(z14b) named over ceiling: no recycle-gmail.log line ($out)" ;; esac
[ -f "$xdg3/qmd/recycle-gmail.stamp" ] || fail "(z14b) named over ceiling: no recycle-gmail.stamp"
[ ! -e "$xdg3/qmd/recycle.stamp" ] || fail "(z14b) named over ceiling: the default recycle stamp was written"
i=0
while [ "$i" -lt 60 ] && ! grep -q 'recycle: restart rc=' "$xdg3/qmd/recycle-gmail.log" 2>/dev/null; do i=$((i + 1)); sleep 0.5; done
grep -q 'recycle: restart rc=0' "$xdg3/qmd/recycle-gmail.log" 2>/dev/null || fail "(z14b) named over ceiling: the detached restart did not succeed ($(cat "$xdg3/qmd/recycle-gmail.log" 2>/dev/null))"
grep -qx -- "--index gmail --port $test_port mcp --http --daemon" "$state/qmd-argv.log" || fail "(z14b) named over ceiling: the restart did not start the gmail index ($(cat "$state/qmd-argv.log" 2>/dev/null))"
kill -0 "$gm_pid" 2>/dev/null && fail "(z14b) named over ceiling: its own server was not stopped"
kill -0 "$dflt_pid" 2>/dev/null || fail "(z14b) named over ceiling: the default index's server was stopped"
kill "$(cat "$xdg3/qmd/mcp-gmail.pid")" 2>/dev/null || true
reap_two
echo "ok (z14b): a named recycle uses its own lock, stamp and log, stops only its own server, and restarts it"

two_procs "$gmail_argv" 7340032 "$default_argv" 7340032
run_idx QMD_INDEX_NAME=gmail
[ "$rc" -eq 1 ] || fail "(z15) named run, default argv: expected rc 1, got $rc ($out)"
grep -qx "$gm_pid" "$state/ps3-pids.log" || fail "(z15) named run, default argv: mcp-gmail.pid's pid was never inspected"
case "$out" in *recycling*) fail "(z15) named run, default argv: a recycle started on a pid that is not the gmail server ($out)" ;; esac
kill -0 "$gm_pid" 2>/dev/null || fail "(z15) named run, default argv: a process was stopped"
rm -f "$state/ps3-pids.log"
run_idx
[ "$rc" -eq 0 ] || fail "(z15) default run, gmail argv: expected rc 0, got $rc ($out)"
grep -qx "$dflt_pid" "$state/ps3-pids.log" || fail "(z15) default run, gmail argv: mcp.pid's pid was never inspected"
case "$out" in *recycling*) fail "(z15) default run, gmail argv: a recycle started on a pid that is not the default server ($out)" ;; esac
kill -0 "$dflt_pid" 2>/dev/null || fail "(z15) default run, gmail argv: a process was stopped"
reap_two
echo "ok (z15): a pid whose argv names the other index is never recycled, in either direction"

idx_stamp="$work/build-stamp-idx"
: > "$idx_stamp"
touch_ago "$idx_stamp" 3600
two_procs "$default_argv" 1048576 "$default_argv" 1048576
touch_ago "$xdg3/qmd/mcp-gmail.pid" 60
run_idx QMD_INDEX_NAME=gmail -- --recycle-if-stale "$idx_stamp"
[ "$rc" -eq 1 ] || fail "(z16) named stale check on a default-argv pid: expected rc 1, got $rc ($out)"
case "$out" in *"not the qmd HTTP server that wrote it"*) ;; *) fail "(z16) named stale check on a default-argv pid: no identity refusal ($out)" ;; esac
grep -qx "$gm_pid" "$state/ps3-pids.log" || fail "(z16) named stale check on a default-argv pid: its own pid was never inspected"
kill -0 "$gm_pid" 2>/dev/null || fail "(z16) named stale check on a default-argv pid: it was stopped"
reap_two
two_procs "$gmail_argv" 1048576 "$gmail_argv" 1048576
touch_ago "$xdg3/qmd/mcp.pid" 60
run_idx -- --recycle-if-stale "$idx_stamp"
[ "$rc" -eq 1 ] || fail "(z16) default stale check on a gmail-argv pid: expected rc 1, got $rc ($out)"
case "$out" in *"not the qmd HTTP server that wrote it"*) ;; *) fail "(z16) default stale check on a gmail-argv pid: no identity refusal ($out)" ;; esac
grep -qx "$dflt_pid" "$state/ps3-pids.log" || fail "(z16) default stale check on a gmail-argv pid: its own pid was never inspected"
kill -0 "$dflt_pid" 2>/dev/null || fail "(z16) default stale check on a gmail-argv pid: it was stopped"
reap_two
two_procs "$default_argv" 1048576 "$gmail_argv" 1048576
touch_ago "$xdg3/qmd/mcp-gmail.pid" 60
run_idx QMD_INDEX_NAME=gmail -- --recycle-if-stale "$idx_stamp"
[ "$rc" -eq 0 ] || fail "(z16) named stale check on its own server: expected rc 0, got $rc ($out)"
reap_two
two_procs "$default_argv" 1048576 "$gmail_argv" 1048576
touch_ago "$xdg3/qmd/mcp-gmail.pid" 60
run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL=http://localhost:9/mcp -- --recycle-if-stale "$idx_stamp"
[ "$rc" -ne 0 ] || fail "(z16b) a named stale check whose URL is answered on another port than the pidfile's must not succeed ($out)"
kill -0 "$gm_pid" 2>/dev/null || fail "(z16b) the gmail server was stopped"
reap_two
echo "ok (z16): --recycle-if-stale names the pidfile and the argv of its own index"

run_idx QMD_INDEX_NAME=../x
[ "$rc" -eq 1 ] || fail "(z17) bad index name on a healthy server: expected rc 1, got $rc ($out)"
case "$out" in *"QMD_INDEX_NAME must match"*) ;; *) fail "(z17) bad index name: no refusal line ($out)" ;; esac
echo "ok (z17): the index name is validated before any state path is built, even when the server is healthy"

cat > "$bin/curl-count" <<'EOF'
#!/usr/bin/env bash
case "$*" in *'%{http_code}'*) exit 7 ;; esac
n=$(( $(cat "$QMD_MOCK_STATE/probe-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$QMD_MOCK_STATE/probe-count"
if [ "$n" -ge "${QMD_PROBE_ANSWER_AT:-1}" ]; then
  printf '%s' '{"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"qmd","version":"2.5.2"}}}'
  exit 0
fi
exit 7
EOF
chmod +x "$bin/curl-count"
wait_run() {
  local answer_at="$1" lock_idx="${WAIT_LOCK_INDEX:-}" lock="$home/.cache/qmd/embed-swap.lock" holder="" releaser=""
  shift
  rm -f "$state/qmd-argv.log" "$state/probe-count"
  export XDG_CACHE_HOME="$home/.cache"
  mkdir -p "$home/.cache/qmd"
  rm -rf "$lock"
  sleep 300 & wait_srv=$!
  STUB_PIDS+=("$wait_srv")
  set_proc "$wait_srv" 1048576 "$gmail_argv"
  echo "$wait_srv" > "$home/.cache/qmd/mcp-gmail.pid"
  if [ -n "$lock_idx" ]; then
    sleep 300 & holder=$!
    STUB_PIDS+=("$holder")
    mkdir "$lock"
    echo "$lock_idx" > "$lock/index"
    echo ensure > "$lock/role"
    echo "$holder" > "$lock/pid"
    if [ -z "${WAIT_LOCK_KEEP:-}" ]; then ( sleep 2; rm -rf "$lock" ) & releaser=$!; fi
  fi
  set +e
  out="$(env QMD_CURL="$bin/curl-count" QMD_PROBE_ANSWER_AT="$answer_at" QMD_MOCK_STATE="$state" QMD_MCP_URL="$test_url" \
    QMD_INDEX_NAME=gmail QMD_PS="$ps3/ps" HOME="$home" PATH="$bin:$safe" "$@" bash "$script" 2>&1)"
  rc=$?
  set -e
  [ -z "$releaser" ] || wait "$releaser"
  kill "$wait_srv" ${holder:+"$holder"} 2>/dev/null || true
  rm -rf "$lock"
  unset XDG_CACHE_HOME
}
wait_run 7 QMD_WAIT_TRIES=abc
[ "$rc" -eq 1 ] || fail "(z18) a non-numeric QMD_WAIT_TRIES must fall back to 5 probes: expected rc 1, got $rc ($out)"
case "$out" in *"nothing came alive"*) ;; *) fail "(z18) no 'nothing came alive' line ($out)" ;; esac
case "$out" in *"mcp-gmail.log"*) ;; *) fail "(z18) the failure does not point at mcp-gmail.log ($out)" ;; esac
grep -qx -- "--index gmail --port $test_port mcp --http --daemon" "$state/qmd-argv.log" || fail "(z18) the named start did not run qmd --index gmail on the URL's port ($(cat "$state/qmd-argv.log"))"
[ -f "$home/.cache/qmd/starting-gmail" ] || fail "(z18) the named start marker is not starting-gmail"
wait_run 6 QMD_WAIT_TRIES=abc
[ "$rc" -eq 0 ] || fail "(z18) the default is exactly 5 probes after the start: a server answering on the 5th must be seen, got rc $rc ($out)"
wait_run 7 QMD_WAIT_TRIES=12
[ "$rc" -eq 0 ] || fail "(z18) QMD_WAIT_TRIES=12 must wait for the late server: expected rc 0, got $rc ($out)"
[ ! -e "$home/.cache/qmd/starting-gmail" ] || fail "(z18) the start marker was left behind after a successful start"
echo "ok (z18): QMD_WAIT_TRIES is honoured (digits only, default 5) and a named start logs to its own mcp-<name>.log"

WAIT_LOCK_INDEX=index wait_run 2
[ "$rc" -eq 0 ] || fail "(z23) a gmail start behind a default-index start must wait and then run: got rc $rc ($out)"
grep -qx -- "--index gmail --port $test_port mcp --http --daemon" "$state/qmd-argv.log" || fail "(z23) the gmail start exited without starting gmail ($(cat "$state/qmd-argv.log" 2>/dev/null))"
WAIT_LOCK_INDEX=gmail wait_run 2
[ "$rc" -eq 0 ] || fail "(z23) a concurrent start of the same index must exit 0: got rc $rc ($out)"
[ ! -e "$state/qmd-argv.log" ] || fail "(z23) a concurrent start of the same index started a second server"
WAIT_LOCK_INDEX=index WAIT_LOCK_KEEP=1 wait_run 2 QMD_SWAP_WAIT=2
[ "$rc" -eq 1 ] || fail "(z23) a lock that never frees must end in an error, not a silent exit 0: got rc $rc ($out)"
case "$out" in *"another index"*) ;; *) fail "(z23) no refusal line naming the other index's start ($out)" ;; esac
[ ! -e "$state/qmd-argv.log" ] || fail "(z23) qmd was started without the lock"
echo "ok (z23): a start for another index waits for the shared lock and runs; the same index's concurrent start exits quietly; a stuck lock is an error"

run_unit() {
  set +e
  out="$(env QMD_SYSTEMCTL="$bin/systemctl" QMD_UNIT_DIR="$units" QMD_MOCK_STATE="$state" HOME="$home" PATH="$bin:$safe" "$@" \
    bash "$script" --install-boot-unit 2>&1)"
  rc=$?
  set -e
}
rm -f "$state/systemctl.log" "$units/qmd-daemon-gmail.service"
before_default="$(cat "$units/qmd-daemon.service")"
run_unit QMD_INDEX_NAME=gmail QMD_MCP_URL=http://localhost:8183/mcp QMD_HTTP_TOKEN_FILE=/tok/http-token-gmail \
  QMD_HTTP_AUTH_FILE=/tok/http-token-gmail QMD_WAIT_TRIES=40
[ "$rc" -eq 0 ] || fail "(z19) named install: expected rc 0, got $rc ($out)"
gunit="$units/qmd-daemon-gmail.service"
[ -f "$gunit" ] || fail "(z19) named install: $gunit was not written ($out)"
for line in 'Environment="QMD_INDEX_NAME=gmail"' 'Environment="QMD_MCP_URL=http://localhost:8183/mcp"' \
  'Environment="QMD_HTTP_TOKEN_FILE=/tok/http-token-gmail"' 'Environment="QMD_HTTP_AUTH_FILE=/tok/http-token-gmail"' \
  'Environment="QMD_WAIT_TRIES=40"' 'WantedBy=default.target' 'Type=oneshot'; do
  grep -qxF -- "$line" "$gunit" || fail "(z19) named install: missing $line in $(cat "$gunit")"
done
grep -q '^Before=' "$gunit" && fail "(z19) named install: a named unit needs no ordering ($(cat "$gunit"))"
grep -qxF -- '--user enable qmd-daemon-gmail.service' "$state/systemctl.log" || fail "(z19) named install: the named unit was not enabled ($(cat "$state/systemctl.log"))"
[ "$(cat "$units/qmd-daemon.service")" = "$before_default" ] || fail "(z19) named install: the default unit was changed"
run_unit
[ "$(cat "$units/qmd-daemon.service")" = "$before_default" ] || fail "(z19) the default unit changed with no environment set"
grep -q '^Environment="' "$units/qmd-daemon.service" && fail "(z19) the default unit gained Environment lines with nothing set"
run_unit QMD_INDEX_NAME=gmail QMD_MCP_URL=http://localhost:8183/mcp QMD_HTTP_TOKEN_FILE=/tok/50%/tok
grep -qxF -- 'Environment="QMD_HTTP_TOKEN_FILE=/tok/50%%/tok"' "$gunit" || fail "(z19) a % in a value was not escaped: $(cat "$gunit")"
rm -f "$gunit"
for bad in "QMD_HTTP_TOKEN_FILE=relative/tok" "QMD_WAIT_TRIES=4x" "QMD_MCP_URL=$(printf 'http://x\nExecStart=/bin/evil')" "QMD_INDEX_NAME=a/b"; do
  run_unit QMD_INDEX_NAME=gmail QMD_MCP_URL=http://localhost:8183/mcp "$bad"
  [ "$rc" -ne 0 ] || fail "(z19) a bad value was baked into the unit: $bad ($out)"
  [ ! -e "$gunit" ] || fail "(z19) a unit was written for a bad value: $bad"
done
echo "ok (z19): a named --install-boot-unit writes qmd-daemon-<name>.service with the settings baked in, escaped, and refuses bad values"

set +e
out="$(env -u QMD_MCP_URL QMD_CURL="$mock_curl" QMD_MOCK_CURL_MODE=alive QMD_MOCK_STATE="$state" QMD_INDEX_NAME=gmail \
  HOME="$home" PATH="$bin:$safe" bash "$script" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "(z20) a named index with no QMD_MCP_URL must be refused, not reported healthy through the shared server: got rc $rc ($out)"
case "$out" in *"needs its own QMD_MCP_URL"*) ;; *) fail "(z20) no refusal line naming QMD_MCP_URL ($out)" ;; esac
rm -f "$units/qmd-daemon-gmail.service"
set +e
out="$(env -u QMD_MCP_URL QMD_SYSTEMCTL="$bin/systemctl" QMD_UNIT_DIR="$units" QMD_MOCK_STATE="$state" QMD_INDEX_NAME=gmail \
  HOME="$home" PATH="$bin:$safe" bash "$script" --install-boot-unit 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "(z20) --install-boot-unit for a named index with no QMD_MCP_URL must be refused: got rc $rc ($out)"
[ ! -e "$units/qmd-daemon-gmail.service" ] || fail "(z20) a unit was written without the index's own URL"
echo "ok (z20): a named index without its own QMD_MCP_URL is refused on start and on install"

for url in http://localhost:9/mcp "http://localhost:9?probe=1" "http://localhost:0009/mcp"; do
  for shape in none default gmail; do
    two_procs "$default_argv" 1048576 "$default_argv" 1048576
    [ "$shape" != none ] || rm -f "$xdg3/qmd/mcp-gmail.pid"
    [ "$shape" != gmail ] || set_proc "$gm_pid" 1048576 "$gmail_argv"
    rm -f "$state/qmd-argv.log"
    run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL="$url"
    [ "$rc" -eq 1 ] || fail "(z21) $url, pidfile $shape: a probe answered on another port must exit 1, got $rc ($out)"
    case "$out" in *"not the 'gmail' index's server"*) ;; *) fail "(z21) $url, pidfile $shape: no refusal line ($out)" ;; esac
    [ ! -e "$state/qmd-argv.log" ] || fail "(z21) $url, pidfile $shape: qmd was started"
    reap_two
  done
done
two_procs "$default_argv" 1048576 "$gmail_argv" 1048576
run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL="$test_url?probe=1"
[ "$rc" -eq 0 ] || fail "(z21) a pidfile naming --index gmail --port $test_port is healthy on that port: got rc $rc ($out)"
run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL="http://localhost:$(printf '%08d' "$test_port")/mcp"
[ "$rc" -eq 0 ] || fail "(z21) a zero-padded spelling of the matching port is the same port: got rc $rc ($out)"
reap_two
echo "ok (z21): a named index counts as served only when its own pidfile names a live --index <name> --port <the URL's port> server"

for url in http://localhost:8181/mcp http://localhost:0000008181/mcp "http://localhost:8181?probe=1" http://localhost:08181/mcp "http://user@localhost:8181#x" "http://[::1]:8181/mcp"; do
  run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL="$url"
  [ "$rc" -eq 1 ] || fail "(z22) a named index on the shared port must be refused ($url): got rc $rc ($out)"
  case "$out" in *"cannot use port 8181"*) ;; *) fail "(z22) $url: no shared-port refusal ($out)" ;; esac
  rm -f "$units/qmd-daemon-gmail.service"
  set +e
  out="$(env QMD_SYSTEMCTL="$bin/systemctl" QMD_UNIT_DIR="$units" QMD_MOCK_STATE="$state" QMD_INDEX_NAME=gmail QMD_MCP_URL="$url" \
    HOME="$home" PATH="$bin:$safe" bash "$script" --install-boot-unit 2>&1)"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "(z22) --install-boot-unit on the shared port must be refused ($url): got rc $rc ($out)"
  [ ! -e "$units/qmd-daemon-gmail.service" ] || fail "(z22) a unit was written for the shared port ($url)"
done
for url in http://localhost/mcp http://localhost:abc/mcp http://localhost:0/mcp http://localhost:65536/mcp "http://localhost:8183x/mcp"; do
  run_idx QMD_INDEX_NAME=gmail QMD_MCP_URL="$url"
  [ "$rc" -eq 1 ] || fail "(z22) a named index needs a numeric port 1-65535 ($url): got rc $rc ($out)"
  case "$out" in *"numeric port"*) ;; *) fail "(z22) $url: no numeric-port refusal ($out)" ;; esac
done
echo "ok (z22): a named index is refused on the shared port, in any spelling, and without a numeric port"

echo "PASS: all ensure-qmd-daemon cases"
