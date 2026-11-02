#!/usr/bin/env bash
# test-real-state-guard.sh — a test on the station cannot write real station state.
#
# WHY: an earlier keyring guard's own probes touched real state, so nothing here can. Every tool a
# door reaches is a recorder first on PATH, HOME and every state root sit under one temp dir, the
# session bus is dead, and the suite aborts unless each tool resolves to its recorder. The guard's
# add-only seams make a temp dir and the recorders count as real: a door that fails to refuse reaches
# a recorder or a temp file, which is what the row counts, and never the real thing.
#
# Rows run from this file, so this suite is itself the ancestor test signal. A row that needs a real
# session runs under $CLAUDE_STUB, a shebang script whose process name is claude: the walk stops there.
set -uo pipefail

[ "$(uname -s)" = Linux ] || { echo "SKIP - the guard does not run off Linux"; exit 0; }

root="$(git rev-parse --show-toplevel)"
GUARD="$root/scripts/lib/test-run-guard"
# Pinned to /tmp, not $TMPDIR: a TMPDIR under the home would make every hermetic target here count as real.
TMP="$(mktemp -d /tmp/real-state-guard.XXXXXX)" || exit 1
TMP="$(realpath "$TMP")"
trap '[ -z "${SRV:-}" ] || kill "$SRV" 2>/dev/null; rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
fails=0
pass() { echo "PASS - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
# read-sink-ok: the path is this suite's own output file under its temp dir, never outside input
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (no '$3' in: $(head -c 400 "$2"))"; fi; }

REAL_BUN="$(command -v bun || true)"

BIN="$TMP/bin"
mkdir -p "$BIN"
export REC="$TMP/calls.log"
for t in bun qmd node; do
  # shellcheck disable=SC2016
  printf '#!/usr/bin/env bash\nprintf "%s %%s\\n" "$*" >>"$REC"\nexit 0\n' "$t" >"$BIN/$t"
done
cat >"$BIN/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$REC"
if [ "$1" = store ]; then cat >/dev/null; exit 0; fi
exit 1
STUB
cat >"$BIN/busctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *" Locked") echo "b false" ;; esac
STUB
chmod +x "$BIN"/*
export PATH="$BIN:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dead-bus"
export HOME="$TMP/home"
mkdir -p "$HOME"
FAKE_REAL="$TMP/real"
mkdir -p "$FAKE_REAL/handovers" "$TMP/hermetic-handovers"
export HANDOVER_DIR="$FAKE_REAL/handovers" USER_SLUG=tester JIRA_PROJECT_KEY=HIMMEL
export HIMMEL_RELEASE_STATE_DIR="$FAKE_REAL/queue" HIMMEL_RELEASE_KEY_DIR="$TMP/keys"
export BRIDGE_ROOT=""
export CADENCE_ALERT_FILE="$TMP/alerts.log" CADENCE_ALERT_DEDUPE_DIR="$TMP/alert-sent" \
  CADENCE_ALERT_SEND_CMD="$BIN/qmd" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/alert-failed"
export TELEGRAM_ACCESS_PATH="$TMP/no-access.json"
unset HIMMEL_CONSOLE_LEG HIMMEL_RELEASE_MANAGER HIMMEL_TEST_FIXTURE NODE_ENV HIMMEL_SECRETS_KEYRING CREDENTIALS_DIRECTORY KSTUB_STORE KSTUB_LOG \
  FAILURE_ROUTE_INBOX_SEND FAILURE_ROUTE_JIRA FAILURE_ROUTE_SWEEP_CMD ROADMAP_QMD_BIN

for tool in secret-tool busctl bun qmd node; do
  [ "$(command -v "$tool")" = "$BIN/$tool" ] || { echo "FAIL - suite guard: $tool does not resolve to the recorder"; exit 1; }
done

export HIMMEL_REAL_STATE_ASSUME_STATION=1 HIMMEL_REAL_STATE_EXTRA_ROOTS="$FAKE_REAL" HIMMEL_REAL_STATE_EXTRA_TOOL_DIRS="$BIN"

CLAUDE_STUB="$TMP/boundary/claude"
mkdir -p "$TMP/boundary"
printf '#!/bin/bash\n"$@"\n' >"$CLAUDE_STUB"
chmod +x "$CLAUDE_STUB"
# as_session <cmd...>: run it the way a real session does, below a process named claude.
as_session() { "$CLAUDE_STUB" "$@"; }

reset() { : >"$REC"; }
calls() { grep -c "^$1 " "$REC" || true; }
check() { bash "$GUARD" check "$@" >"$TMP/g.out" 2>&1; echo $?; }
session_check() { as_session bash "$GUARD" check "$@" >"$TMP/g.out" 2>&1; echo $?; }

# ---- the detector ----
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
echo "== detector"
eq "G1 a test ancestor plus a real target is refused" "$(check g1 "$FAKE_REAL/x")" 77
has "G1 the refusal names the exact VM command for this suite" "$TMP/g.out" "bash scripts/vm/guest-exec.sh himmel-ar-1 -- bash"
has "G1 the refusal names this suite" "$TMP/g.out" "test-real-state-guard.sh"
has "G1 the refusal names the after-report command" "$TMP/g.out" "bash scripts/vm/after-report.sh "
eq "G2 a test ancestor with a temp target is allowed: hermetic stays local" "$(check g2 "$TMP/scratch/x")" 0
eq "G3 a path under the passwd home is real although HOME is a fixture" "$(check g3 "$real_home/.himmel/state/x")" 77
eq "G4 a path in a worktree under the home is a fixture" "$(check g4 "$real_home/repo/.claude/worktrees/w/x")" 0
eq "G5 .. out of a temp dir into a real root is real" "$(check g5 "$TMP/scratch/../real/x")" 77
ln -s "$FAKE_REAL" "$TMP/link"
eq "G6 a symlink from a temp dir into a real root is real" "$(check g6 "$TMP/link/x")" 77
eq "G7 a tool not found has nothing to reach" "$(check --tool no-such-tool-8752 g7)" 0
mkdir -p "$TMP/stubs"
cp "$BIN/secret-tool" "$TMP/stubs/stubbed-tool"
eq "G8 a tool outside the system and home dirs is a stub" "$(PATH="$TMP/stubs:$PATH" check --tool stubbed-tool g8)" 0
ln -s "$(command -v bash)" "$TMP/stubs/linked-bash"
eq "G9 a symlink to a system tool is the system tool" "$(PATH="$TMP/stubs:$PATH" check --tool linked-bash g9)" 77
eq "G10 a bad call is a usage error, never a refusal" "$(check)" 2

echo "== real work is not refused"
eq "S1 a real session descended from this test shell may write" "$(session_check s1 "$FAKE_REAL/x")" 0
eq "S2 a real session may use the real tool" "$(session_check --tool secret-tool s2)" 0
eq "S3 --real from a real session passes" "$(session_check --real s3)" 0
eq "S4 the release queue target from a chief's session passes" "$(session_check 'jira release pull' "$HIMMEL_RELEASE_STATE_DIR")" 0
cat >"$TMP/tick.sh" <<EOF
#!/usr/bin/env bash
bash "$GUARD" check tick "$FAKE_REAL/x"
EOF
eq "S5 a real tick script from a real session passes" "$(as_session bash "$TMP/tick.sh" >/dev/null 2>&1; echo $?)" 0

echo "== a mention is not a signal"
cat >"$TMP/real-tool.sh" <<EOF
#!/usr/bin/env bash
bash "$GUARD" check mention "$FAKE_REAL/x"
EOF
eq "N1 test-x.sh named inside a -c body" "$(as_session bash -c "bash '$GUARD' check n1 '$FAKE_REAL/x'; : test-x.sh" >/dev/null 2>&1; echo $?)" 0
eq "N2 a -lc body starting with a test path" "$(as_session bash -lc "bash '$GUARD' check n2 '$FAKE_REAL/x' #" scripts/test-x.sh >/dev/null 2>&1; echo $?)" 0
eq "N3 test-x.sh as a later argument" "$(as_session bash "$TMP/real-tool.sh" test-x.sh >/dev/null 2>&1; echo $?)" 0
mkdir -p "$TMP/fix+test-worktree-name"
cp "$TMP/real-tool.sh" "$TMP/fix+test-worktree-name/tool.sh"
eq "N4 test in a directory name" "$(as_session bash "$TMP/fix+test-worktree-name/tool.sh" >/dev/null 2>&1; echo $?)" 0
eq "N5 test in a session name on the claude line" "$(as_session bash "$TMP/real-tool.sh" -n HIMMEL-1-test-real-state >/dev/null 2>&1; echo $?)" 0

echo "== a test below a session is still a test"
cp "$TMP/real-tool.sh" "$TMP/test-inner.sh"
eq "T1 a test-*.sh started by a session is refused" "$(as_session bash "$TMP/test-inner.sh" >/dev/null 2>&1; echo $?)" 77
eq "T2 HIMMEL_TEST_FIXTURE=1 is inherited across the session" "$(HIMMEL_TEST_FIXTURE=1 session_check t2 "$FAKE_REAL/x")" 77
eq "T3 NODE_ENV=test is inherited across the session" "$(NODE_ENV="test" session_check t3 "$FAKE_REAL/x")" 77
cp "$TMP/real-tool.sh" "$TMP/foo.test.ts"
cp "$TMP/real-tool.sh" "$TMP/test"
eq "T4 bun test is a runner" "$(cd "$TMP" && as_session bash -c 'exec -a bun bash test' >/dev/null 2>&1; echo $?)" 77
eq "T5 a *.test.* file in script position" "$(as_session bash "$TMP/foo.test.ts" >/dev/null 2>&1; echo $?)" 77
eq "T6 a bash option before the test file does not hide it" "$(as_session bash -e "$TMP/test-inner.sh" >/dev/null 2>&1; echo $?)" 77
eq "T7 -o takes an argument, so the test file is still found" "$(as_session bash -o pipefail "$TMP/test-inner.sh" >/dev/null 2>&1; echo $?)" 77

echo "== the temp-source rule"
eq "P1 a temp source with a real target is refused with no test signal" "$(session_check --temp-source "$TMP/plan" p1 "$FAKE_REAL/out")" 77
eq "P2 a temp source with a temp target passes" "$(session_check --temp-source "$TMP/plan" p2 "$TMP/out")" 0
eq "P3 a non-temp source with a real target passes" "$(session_check --temp-source /usr/share p3 "$FAKE_REAL/out")" 0
eq "P4 a source under a custom TMPDIR is a temp source" "$(TMPDIR=/custom-tmp session_check --temp-source /custom-tmp/plan p4 "$FAKE_REAL/out")" 77
passwd_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
eq "P5 a TMPDIR holding the home does not make a real plan a temp one" "$(TMPDIR="$passwd_home" session_check --temp-source "$passwd_home/plan" p5 "$FAKE_REAL/out")" 0

echo "== failure directions"
NOBIN="$TMP/nobin"
mkdir -p "$NOBIN"
BASH_BIN="$(command -v bash)"
# Nothing on PATH: uname, id, getent, cut and realpath all fail, so home and every path are unresolved.
eq "F1 failed reads beside a test signal fail closed" "$(PATH="$NOBIN" "$BASH_BIN" "$GUARD" check f1 "$TMP/scratch/x" >/dev/null 2>&1; echo $?)" 77
eq "F2 failed reads in a real session do not refuse" "$(PATH="$NOBIN" "$CLAUDE_STUB" "$BASH_BIN" "$GUARD" check f2 "$TMP/scratch/x" >/dev/null 2>&1; echo $?)" 0
( setsid bash -c "bash '$GUARD' check orphan '$FAKE_REAL/x'; echo \$? >'$TMP/orphan.rc'" >/dev/null 2>&1 & )
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/orphan.rc" ] && break; sleep 0.2; done
eq "F3 an orphan with no markers and no ancestor is allowed: the pinned residual" "$(cat "$TMP/orphan.rc" 2>/dev/null)" 0

echo "== the VM check"
(
  unset HIMMEL_REAL_STATE_ASSUME_STATION
  on_vm=0
  if [ -x /usr/bin/systemd-detect-virt ] && { /usr/bin/systemd-detect-virt --quiet --vm || /usr/bin/systemd-detect-virt --quiet --container; }; then on_vm=1; fi
  if [ -e /.dockerenv ] || [ -e /run/.containerenv ]; then on_vm=1; fi
  rc="$(check v1 "$FAKE_REAL/x")"
  if [ "$on_vm" = 1 ]; then eq "V1 on a VM the same write is allowed" "$rc" 0
  else eq "V1 on the station the same write is refused" "$rc" 77; fi
  [ "$rc" = "$([ "$on_vm" = 1 ] && echo 0 || echo 77)" ]
) || fails=$((fails + 1))

# ---- the doors ----
echo "== keyring door"
HS="$root/scripts/lib/himmel-secrets"
reset
rc=0; printf 'value' | bash "$HS" put --stdin K8752 >"$TMP/k.out" 2>&1 || rc=$?
eq "K1 put from a test reaches no store" "$(calls 'secret-tool store')" 0
eq "K1 put from a test exits 77" "$rc" 77
has "K1 the refusal names the VM command" "$TMP/k.out" "scripts/vm/"
reset
printf 'value' | HIMMEL_REAL_STATE_EXTRA_TOOL_DIRS="" bash "$HS" put --stdin K8752 >/dev/null 2>&1
eq "K2 a stub keyring keeps working for a hermetic test" "$(calls 'secret-tool store')" 1
reset
printf 'value' | as_session bash "$HS" put --stdin K8752 >/dev/null 2>&1
eq "K3 a real session's put reaches the store" "$(calls 'secret-tool store')" 1
reset
bash "$HS" get K8752 >/dev/null 2>&1
if grep -q '^secret-tool lookup' "$REC"; then pass "K4 a read is not refused"; else fail "K4 a read is not refused (no lookup in: $(cat "$REC"))"; fi

echo "== inbox door"
SEND="$root/scripts/handover/chief-kit/inbox-send.sh"
INBOX="$HANDOVER_DIR/inbox/HIMMEL-1-chief.md"
rc=0; bash "$SEND" HIMMEL-1-chief "from a test" >"$TMP/i.out" 2>&1 || rc=$?
eq "I1 a test's send to a real inbox exits 77" "$rc" 77
if [ -e "$INBOX" ]; then fail "I1 a test's send wrote the real inbox"; else pass "I1 a test's send wrote nothing"; fi
has "I1 the refusal names the VM command" "$TMP/i.out" "scripts/vm/"
as_session bash "$SEND" HIMMEL-1-chief "from a session" >/dev/null 2>&1
if grep -q 'from a session' "$INBOX" 2>/dev/null; then pass "I2 a real session's send arrives"; else fail "I2 a real session's send arrives"; fi
HANDOVER_DIR="$TMP/hermetic-handovers" bash "$SEND" HIMMEL-1-chief "hermetic" >/dev/null 2>&1
if grep -q hermetic "$TMP/hermetic-handovers/inbox/HIMMEL-1-chief.md" 2>/dev/null; then pass "I3 a send to a temp root stays local"; else fail "I3 a send to a temp root stays local"; fi

echo "== notifier door"
NOTIFY="$root/scripts/eval/worker-digest/failure-route-notify.sh"
SWEEP="$TMP/sweep"
printf '#!/usr/bin/env bash\nprintf "slug=HIMMEL-2-chief age=5s status=OK\\n"\n' >"$SWEEP"
chmod +x "$SWEEP"
INBOX2="$HANDOVER_DIR/inbox/HIMMEL-2-chief.md"
reset
rc=0; FAILURE_ROUTE_SWEEP_CMD="$SWEEP" bash "$NOTIFY" chief "from a test" >"$TMP/n.out" 2>&1 || rc=$?
eq "R1 the notifier's chief line from a test exits 77" "$rc" 77
if [ -e "$INBOX2" ]; then fail "R1 the notifier wrote a real inbox"; else pass "R1 the notifier wrote nothing"; fi
eq "R1 the refusal raises no alert" "$(calls qmd)" 0
reset
rc=0; bash "$NOTIFY" intake K-1 "from a test" >"$TMP/n.out" 2>&1 || rc=$?
eq "R2 the notifier's intake from a test exits 77" "$rc" 77
eq "R2 the intake reaches no Jira CLI" "$(calls node)" 0
reset
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "seam %%s\\n" "$*" >>"$REC"\n' >"$TMP/send-stub"
chmod +x "$TMP/send-stub"
FAILURE_ROUTE_SWEEP_CMD="$SWEEP" FAILURE_ROUTE_INBOX_SEND="$TMP/send-stub" bash "$NOTIFY" chief "seam" >/dev/null 2>&1
eq "R3 a stubbed send keeps working for a hermetic test" "$(calls seam)" 1
reset
FAILURE_ROUTE_JIRA="$BIN/node" bash "$NOTIFY" intake K-1 "seam" >/dev/null 2>&1
if [ "$(calls node)" -ge 1 ]; then pass "R4 a stubbed Jira keeps working for a hermetic test"; else fail "R4 a stubbed Jira keeps working for a hermetic test"; fi

echo "== plan-index door"
PI="$root/scripts/roadmap/plan-index.sh"
plan="$TMP/plan"
mkdir -p "$plan/stage1" "$plan/stage3"
printf 'key\ttheme\tepic\tgoals\timpact\timpact_evidence\talignment\tdeps\tdup_of\tclose_flag\tclose_evidence\tnotes\nHIMMEL-111\tKnowledge substrate\tHIMMEL-100\tG7;G3\t2\te\t0.5\t\t\tnone\t\tn\n' >"$plan/stage1/C01.tsv"
printf 'key\tuser_impact\tissue_plain\nHIMMEL-111\tinternal\tA plain sentence.\n' >"$plan/stage1/C01.explain.tsv"
printf 'key\troi\tconfidence\teffort_mid\trank\tversion\tcommit\tslice_effort\tlayer\treason\nHIMMEL-111\t1\t1\t1\t1\tv1.0.1\tcommitted\t\tbugs\twhy-one\n' >"$plan/stage3/placement.tsv"
printf '{"stage":3}\n' >"$plan/stage3/meta.json"
reset
rc=0; bash "$PI" --refresh --plan-dir "$plan" --out "$FAKE_REAL/plan-out" >"$TMP/p.out" 2>&1 || rc=$?
eq "Q1 a test's refresh of a real out exits 77" "$rc" 77
eq "Q1 the qmd index is never called" "$(calls qmd)" 0
if [ -e "$FAKE_REAL/plan-out/.fp" ]; then fail "Q1 the real out was written"; else pass "Q1 the real out was not written"; fi
has "Q1 the refusal names the VM command" "$TMP/p.out" "scripts/vm/"
reset
rc=0; as_session bash "$PI" --refresh --plan-dir "$plan" --out "$FAKE_REAL/plan-out" >"$TMP/p.out" 2>&1 || rc=$?
eq "Q2 a temp plan over a real out is refused with no test signal: the detached-launch case" "$rc" 77
eq "Q2 the qmd index is never called" "$(calls qmd)" 0
reset
rc=0; bash "$PI" --refresh --plan-dir "$plan" --out "$TMP/plan-temp-out" >"$TMP/p.out" 2>&1 || rc=$?
eq "Q3 temp out with the real qmd is refused: qmd is the index" "$rc" 77
eq "Q3 the qmd index is never called" "$(calls qmd)" 0
reset
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "stubqmd %%s\\n" "$*" >>"$REC"\n' >"$TMP/stubs/stubqmd"
chmod +x "$TMP/stubs/stubqmd"
rc=0; ROADMAP_QMD_BIN="$TMP/stubs/stubqmd" bash "$PI" --refresh --plan-dir "$plan" --out "$TMP/plan-temp-out" >"$TMP/p.out" 2>&1 || rc=$?
eq "Q4 a stub qmd with a temp out stays local" "$rc" 0
if [ "$(calls stubqmd)" -ge 1 ]; then pass "Q4 the stub qmd ran"; else fail "Q4 the stub qmd ran"; fi
reset
rc=0; bash "$PI" --check --plan-dir "$plan" --out "$FAKE_REAL/plan-out" >/dev/null 2>&1 || rc=$?
eq "Q5 --check reads only, so it is not refused (stale)" "$rc" 1

echo "== jira release door"
if [ -n "$REAL_BUN" ] && [ -d "$root/scripts/jira/node_modules/commander" ]; then
  J="$root/scripts/jira/src/index.ts"
  printf 'R = v1\n' >"$TMP/verbatim.txt"
  DECLARE=("$REAL_BUN" "$J" release operator declare R8752 --versions v1 --decision 1 --verbatim-file "$TMP/verbatim.txt")
  rc=0; "${DECLARE[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if [ -e "$HIMMEL_RELEASE_STATE_DIR/R8752" ]; then fail "J1 a test's release write reached the queue"; else pass "J1 a test's release write reached nothing"; fi
  has "J1 the refusal names the VM command" "$TMP/j.out" "scripts/vm/"
  if [ "$rc" != 0 ]; then pass "J1 the write failed"; else fail "J1 the write failed"; fi
  rc=0; "$REAL_BUN" "$J" release state R8752 --mirror-root "$TMP/no-mirror" >"$TMP/j.out" 2>&1 || rc=$?
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J2 a read-only verb was refused"; else pass "J2 a read-only verb is not refused"; fi
  as_session "${DECLARE[@]}" >"$TMP/j.out" 2>&1
  if [ -e "$HIMMEL_RELEASE_STATE_DIR/R8752/release.json" ]; then pass "J3 a real jira release run by a chief writes"; else fail "J3 a real jira release run by a chief writes ($(head -c 300 "$TMP/j.out"))"; fi
  # leaks --comment posts a real comment. Jira here is a local recorder, so a door that lets a run through shows as a request.
  HTTPLOG="$TMP/http.log"
  : >"$HTTPLOG"
  cat >"$TMP/rec-server.py" <<'PY'
import http.server, sys
log, portfile = sys.argv[1], sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def _r(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        open(log, 'a').write(self.command + ' ' + self.path + '\n')
        self.send_response(500)
        self.end_headers()
    do_GET = do_POST = do_PUT = do_DELETE = _r
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(s.server_address[1]))
s.serve_forever()
PY
  python3 -I "$TMP/rec-server.py" "$HTTPLOG" "$TMP/port" >/dev/null 2>&1 &
  SRV=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$TMP/port" ] && break; sleep 0.2; done
  JIRA_ENV=(env JIRA_BASE_URL="http://127.0.0.1:$(cat "$TMP/port" 2>/dev/null)" JIRA_EMAIL=t@example.invalid JIRA_API_TOKEN=not-a-token)
  LEAKS=("${JIRA_ENV[@]}" "$REAL_BUN" "$J" release leaks v1.1.3 --mirror-root "$TMP/no-mirror")
  rc=0; "${LEAKS[@]}" --comment >"$TMP/j.out" 2>&1 || rc=$?
  has "J4 a test's leaks --comment is refused" "$TMP/j.out" "REFUSED"
  eq "J4 a test's leaks --comment reaches no Jira" "$(wc -l <"$HTTPLOG" | tr -d ' ')" 0
  rc=0; "${LEAKS[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J5 leaks without --comment was refused"; else pass "J5 leaks without --comment is not refused"; fi
  if grep -q '^GET ' "$HTTPLOG" && ! grep -qv '^GET ' "$HTTPLOG"; then pass "J5 leaks without --comment reaches the recorder with reads only"; else fail "J5 leaks without --comment reaches the recorder with reads only ($(head -c 200 "$HTTPLOG"))"; fi
  : >"$HTTPLOG"
  as_session "${LEAKS[@]}" --comment >"$TMP/j.out" 2>&1
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J6 a real session's leaks --comment was refused"; else pass "J6 a real session's leaks --comment is not refused"; fi
else
  echo "SKIP - J rows: no bun or no scripts/jira/node_modules here; release.test.ts holds the door row and S4 the chief's guard call"
fi

echo "== merge alert door"
MBA="$root/scripts/lib/merge-block-alert.sh"
printf '{"allowFrom":["555"]}\n' >"$TMP/access.json"
cat >"$TMP/alert-run.sh" <<'EOF'
#!/usr/bin/env bash
. "$1"
merge_block_alert o/r 1 abc123def "a rule"
EOF
cat >"$TMP/watch-run.sh" <<'EOF'
#!/usr/bin/env bash
. "$1"
merge_watch_alert o/r 2 fed456abc "a rule"
EOF
n=0
# alert_env <cmd...>: the alert's own env under a fresh sentinel dir, so no row is deduped by another.
alert_env() { n=$((n + 1)); env TELEGRAM_ACCESS_PATH="$TMP/access.json" MERGE_BLOCK_ALERT_DIR="$TMP/sent-$n" "$@" >/dev/null 2>&1; }
reset
alert_env bash "$TMP/alert-run.sh" "$MBA"
eq "M1 a test's alert never reaches the real sender" "$(calls bun)" 0
reset
alert_env "$CLAUDE_STUB" bash "$TMP/alert-run.sh" "$MBA"
eq "M2 a real alert reaches the sender" "$(calls bun)" 1
has "M2 the sender is told the operator and the alert" "$REC" "reply 555 MERGE-BLOCKED o/r#1"
reset
alert_env MERGE_BLOCK_ALERT_CMD="$TMP/send-stub" bash "$TMP/alert-run.sh" "$MBA"
eq "M3 a stub sender keeps working for a hermetic test" "$(calls seam)" 1
mkdir -p "$TMP/mba-noguard" "$TMP/mba-crash"
cp "$MBA" "$TMP/mba-noguard/merge-block-alert.sh"
cp "$MBA" "$TMP/mba-crash/merge-block-alert.sh"
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/mba-crash/test-run-guard"
reset
alert_env bash "$TMP/alert-run.sh" "$TMP/mba-noguard/merge-block-alert.sh"
eq "M4 a real alert still goes with the guard missing" "$(calls bun)" 1
reset
alert_env bash "$TMP/alert-run.sh" "$TMP/mba-crash/merge-block-alert.sh"
eq "M5 a real alert still goes with the guard crashing" "$(calls bun)" 1
# merge-on-green's own two lines (the source and block_alert), taken from the file, not copied.
# shellcheck disable=SC2016
grep -E '^\. "\$himmel_repo/scripts/lib/merge-block-alert\.sh"|^block_alert\(\)' "$root/scripts/handover/merge-on-green.sh" >"$TMP/mog-alert.lib"
eq "MOG0 merge-on-green still sources the alert and defines block_alert" "$(wc -l <"$TMP/mog-alert.lib" | tr -d ' ')" 2
cat >"$TMP/mog-run.sh" <<'EOF'
#!/usr/bin/env bash
himmel_repo="$1"; nwo=o/r; pr_num=3; sha=cafe0123456789
. "$2"
block_alert "GitHub refused the merge: a rule"
EOF
reset
alert_env "$CLAUDE_STUB" bash "$TMP/mog-run.sh" "$root" "$TMP/mog-alert.lib"
eq "MOG1 merge-on-green's block alert in a real session still sends" "$(calls bun)" 1
has "MOG1 the sender is told the operator and the merge" "$REC" "reply 555 MERGE-BLOCKED o/r#3"
reset
alert_env bash "$TMP/mog-run.sh" "$root" "$TMP/mog-alert.lib"
eq "MOG2 the same alert from a test sends nothing" "$(calls bun)" 0
BR="$FAKE_REAL/bridge"
mkdir -p "$BR/consoles"
CHIEF_INBOX="$BR/consoles/chiefx.md"
# The inbox append needs a real node, so these rows leave the recorder bin off PATH.
NODEPATH="${PATH#"$BIN":}"
watch_env() { alert_env HIMMEL_CONSOLE_LEG=1 HIMMEL_CONSOLE_NAME=chiefx MERGE_WATCH_POST_GO=1 MERGE_WATCH_ALERT_BRIDGE_ROOT="$BR" PATH="$NODEPATH" "$@"; }
: >"$CHIEF_INBOX"
watch_env bash "$TMP/watch-run.sh" "$MBA"
eq "M6 a test's route to a real bridge appends nothing" "$(wc -c <"$CHIEF_INBOX" | tr -d ' ')" 0
watch_env "$CLAUDE_STUB" bash "$TMP/watch-run.sh" "$MBA"
has "M7 a real route to the bridge appends" "$CHIEF_INBOX" "[merge-watch o/r#2]"

echo "== cadence inbox doors"
CH="$root/scripts/eval/cache-health-cadence.sh"
CH_INBOX="$BR/consoles/chiefc.md"
: >"$CH_INBOX"
ch_env() { env CACHE_HEALTH_CHIEF=chiefc CACHE_HEALTH_REPO="$TMP" CACHE_HEALTH_TELEGRAM_CMD="$BIN/qmd" BRIDGE_ROOT="$BR" PATH="$NODEPATH" "$@" >/dev/null 2>&1; }
ch_env bash "$CH" notify "from a test"
eq "C1 a test's cache-health notice appends nothing to a real bridge inbox" "$(wc -c <"$CH_INBOX" | tr -d ' ')" 0
ch_env "$CLAUDE_STUB" bash "$CH" notify "from a session"
has "C2 a real tick's cache-health notice appends" "$CH_INBOX" "[cache-health] from a session"
SC="$root/scripts/cleanup/steering-cull-cadence.sh"
SC_INBOX="$BR/consoles/chiefs.md"
: >"$SC_INBOX"
mkdir -p "$TMP/sc-repo"
printf 'rule\n' >"$TMP/sc-repo/CLAUDE.md"
cat >"$TMP/sc-claude" <<'EOF'
#!/usr/bin/env bash
echo '{"is_error":false,"result":"- [LOW] a.md:1 - x"}'
EOF
printf '#!/usr/bin/env bash\necho PROCEED\n' >"$TMP/sc-pre"
chmod +x "$TMP/sc-claude" "$TMP/sc-pre"
sc_env() { env STEERING_CULL_CLAUDE="$TMP/sc-claude" STEERING_CULL_PREFLIGHT_CMD="$TMP/sc-pre" STEERING_CULL_BACKEND=claude-cli \
  STEERING_CULL_STATE_DIR="$TMP/sc-state" STEERING_CULL_DATE=2026-01-01 BRIDGE_ROOT="$BR" PATH="$NODEPATH" "$@" >/dev/null 2>&1; }
sc_env bash "$SC" run --repo "$TMP/sc-repo" --proposal-dir "$TMP/sc-prop" --chief chiefs
eq "C3 a test's steering-cull proposal appends nothing to a real bridge inbox" "$(wc -c <"$SC_INBOX" | tr -d ' ')" 0
sc_env "$CLAUDE_STUB" bash "$SC" run --repo "$TMP/sc-repo" --proposal-dir "$TMP/sc-prop" --chief chiefs
has "C4 a real tick's steering-cull proposal appends" "$SC_INBOX" "[steering-cull] proposal"

echo "== doc mirror door"
DOC="$FAKE_REAL/handovers/doc-d1.md"
printf '# doc\n\n## Chief Rulings (newest at the bottom)\n' >"$DOC"
rc=0; HIMMEL_CONSOLE_RUNDIR="$TMP/rundir" HANDOVER_DIR="$TMP/hermetic-handovers" bash "$SEND" HIMMEL-1-chief "mirror from a test" --doc "$DOC" >"$TMP/d.out" 2>&1 || rc=$?
eq "D1 a test's send with a real doc mirror exits 77" "$rc" 77
if grep -q 'mirror from a test' "$DOC"; then fail "D1 a test wrote the real doc mirror"; else pass "D1 a test wrote nothing to the real doc"; fi
HIMMEL_CONSOLE_RUNDIR="$TMP/rundir" HANDOVER_DIR="$TMP/hermetic-handovers" as_session bash "$SEND" HIMMEL-1-chief "mirror from a session" --doc "$DOC" >/dev/null 2>&1
has "D2 a real session's doc mirror is written" "$DOC" "mirror from a session"
TDOC="$TMP/hermetic-handovers/doc-d3.md"
printf '# doc\n\n## Chief Rulings (newest at the bottom)\n' >"$TDOC"
HIMMEL_CONSOLE_RUNDIR="$TMP/rundir" HANDOVER_DIR="$TMP/hermetic-handovers" bash "$SEND" HIMMEL-1-chief "mirror hermetic" --doc "$TDOC" >/dev/null 2>&1
has "D3 a send with a temp doc stays local" "$TDOC" "mirror hermetic"

echo
if [ "$fails" -eq 0 ]; then echo "PASS - test-real-state-guard: all rows"; exit 0; fi
echo "FAIL - test-real-state-guard: $fails row(s)"
exit 1
