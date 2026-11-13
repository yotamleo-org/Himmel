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
SRV=""
trap '[ -z "$SRV" ] || kill "$SRV" 2>/dev/null; rm -rf "$TMP"' EXIT
export TMPDIR="$TMP"
fails=0
pass() { echo "PASS - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
# read-sink-ok: the path is this suite's own output file under its temp dir, never outside input
has() { if grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1 (no '$3' in: $(head -c 400 "$2"))"; fi; }

REAL_BUN="$(command -v bun || true)"
TITLE_NODE="$(command -v node || true)"

BIN="$TMP/bin"
mkdir -p "$BIN"
export REC="$TMP/calls.log"
export UNGUARDED_LAUNCH_OK=1
for t in bun qmd node graphify; do
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

for tool in secret-tool busctl bun qmd node graphify; do
  [ "$(command -v "$tool")" = "$BIN/$tool" ] || { echo "FAIL - suite guard: $tool does not resolve to the recorder"; exit 1; }
done

export HIMMEL_REAL_STATE_ASSUME_STATION=1 HIMMEL_REAL_STATE_EXTRA_ROOTS="$FAKE_REAL" HIMMEL_REAL_STATE_EXTRA_TOOL_DIRS="$BIN"

CLAUDE_STUB="$TMP/boundary/claude"
mkdir -p "$TMP/boundary"
printf '#!/bin/bash\n"$@"\n' >"$CLAUDE_STUB"
chmod +x "$CLAUDE_STUB"
# as_session <cmd...>: run it the way a real session does, below a process named claude.
as_session() { "$CLAUDE_STUB" "$@"; }

reset() { : >"$REC"; : >"$REC.atbody"; }
calls() { grep -c "^$1 " "$REC" || true; }
check() { bash "$GUARD" check "$@" >"$TMP/g.out" 2>&1; echo $?; }
session_check() { as_session bash "$GUARD" check "$@" >"$TMP/g.out" 2>&1; echo $?; }

# ---- the detector ----
real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
echo "== detector"
eq "G1 a test ancestor plus a real target is refused" "$(check g1 "$FAKE_REAL/x")" 77
has "G1 the refusal names the exact VM command for this suite" "$TMP/g.out" "bash scripts/vm/guest-exec.sh himmel-ar-1 -- env -C himmel bash"
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
eq "N5 test in a session name on the claude line" "$(as_session bash "$TMP/real-tool.sh" -n fix-1-test-real-state >/dev/null 2>&1; echo $?)" 0

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

echo "== detector gaps"
# A passwd home that is a symlink: the stub getent is the suite's seam, the guard asks getent by name.
GE="$TMP/getent-bin"
mkdir -p "$GE" "$TMP/realhome-target/.himmel"
ln -s "$TMP/realhome-target" "$TMP/homelink"
cat >"$GE/getent" <<EOF
#!/usr/bin/env bash
echo "tester:x:1000:1000::$TMP/homelink:/bin/bash"
EOF
chmod +x "$GE/getent"
eq "H1 a path under a symlinked passwd home is real" "$(PATH="$GE:$PATH" check h1 "$TMP/homelink/.himmel/x")" 77
eq "H2 the resolved path under a symlinked passwd home is real" "$(PATH="$GE:$PATH" check h2 "$TMP/realhome-target/.himmel/x")" 77
eq "H3 negative control: a fixture home outside the symlinked passwd home is allowed" "$(PATH="$GE:$PATH" check h3 "$TMP/scratch/x")" 0

# A runner the list did not name: the process name or argv is the only fact the guard reads.
cp "$TMP/real-tool.sh" "$TMP/pkg.test"
eq "U1 mocha is a runner" "$(as_session bash -c "exec -a mocha bash '$TMP/real-tool.sh'" >/dev/null 2>&1; echo $?)" 77
eq "U2 playwright is a runner" "$(as_session bash -c "exec -a playwright bash '$TMP/real-tool.sh'" >/dev/null 2>&1; echo $?)" 77
eq "U2b a playwright-prefixed tool that is not the runner is not a runner" "$(as_session bash -c "exec -a playwright-crawl-youtube.mjs bash '$TMP/real-tool.sh'" >/dev/null 2>&1; echo $?)" 0
eq "U3 a go test binary named pkg.test is a test" "$(as_session bash "$TMP/pkg.test" >/dev/null 2>&1; echo $?)" 77
eq "U4 go test is a runner" "$(cd "$TMP" && as_session bash -c 'exec -a go bash test' >/dev/null 2>&1; echo $?)" 77
mkdir -p "$TMP/dir with space"
eq "U15 an interpreter path with a space still finds the test file after it" "$(as_session bash -c "exec -a '$TMP/dir with space/bash' bash '$TMP/test-inner.sh'" >/dev/null 2>&1; echo $?)" 77
cp "$TMP/real-tool.sh" "$TMP/dir"
eq "U4b go -C dir test is a runner: the option value is skipped" "$(cd "$TMP" && as_session bash -c 'exec -a go bash -C dir test' >/dev/null 2>&1; echo $?)" 77
eq "U6 negative control: go with a non-test argument is not a runner" "$(as_session bash -c "exec -a go bash '$TMP/real-tool.sh'" >/dev/null 2>&1; echo $?)" 0

# A real package manager retitles itself, so /proc/<pid>/cmdline is ONE string ("npm test"), not an argv.
# titled <title>: a real node process retitled that way, with real-tool.sh running below it.
titled() {
  as_session "$TITLE_NODE" -e "process.title = process.argv[1]; process.exitCode = require('child_process').spawnSync('bash', [process.argv[2]], { stdio: 'ignore' }).status" "$1" "$TMP/real-tool.sh" >/dev/null 2>&1
  echo $?
}
if [ -n "$TITLE_NODE" ] && [ -x "$TITLE_NODE" ]; then
  eq "U5 a retitled npm test is a runner" "$(titled 'npm test')" 77
  eq "U7 a retitled npm run test is a runner" "$(titled 'npm run test')" 77
  eq "U9 a retitled npm run with an option before test is a runner" "$(titled 'npm run --silent test')" 77
  eq "U10 a retitled npm run --workspace web test is a runner: the option value is skipped" "$(titled 'npm run --workspace web test')" 77
  eq "U11 a retitled pnpm run --filter web test is a runner" "$(titled 'pnpm run --filter web test')" 77
  eq "U12 a retitled pnpm -r test is a runner: -r takes no value here" "$(titled 'pnpm -r test')" 77
  eq "U14 a retitled pnpm -w test is a runner: -w is a flag for pnpm, a value option only for npm" "$(titled 'pnpm -w test')" 77
  eq "U16 a retitled pnpm --filter web test is a runner" "$(titled 'pnpm --filter web test')" 77
  eq "U17 a retitled npm -w web test is a runner: -w takes a value for npm" "$(titled 'npm -w web test')" 77
  eq "U18 a retitled pnpm -F web test is a runner" "$(titled 'pnpm -F web test')" 77
  eq "U19 a retitled npm --prefix web test is a runner" "$(titled 'npm --prefix web test')" 77
  eq "U20 a retitled yarn --cwd web test is a runner" "$(titled 'yarn --cwd web test')" 77
  eq "U21 a retitled pnpm --dir web test is a runner" "$(titled 'pnpm --dir web test')" 77
  eq "U22 a retitled npm t is a runner" "$(titled 'npm t')" 77
  eq "U23 a retitled npm tst is a runner" "$(titled 'npm tst')" 77
  eq "U24 a retitled pnpm t is a runner" "$(titled 'pnpm t')" 77
  eq "U25 a retitled npm run-script test is a runner" "$(titled 'npm run-script test')" 77
  eq "U26 a retitled npm rum test is a runner" "$(titled 'npm rum test')" 77
  eq "U27 a retitled npm urn test is a runner" "$(titled 'npm urn test')" 77
  eq "U8 negative control: a retitled npm run build is not a runner" "$(titled 'npm run build')" 0
  eq "U13 negative control: a retitled npm --prefix test run build is not a runner" "$(titled 'npm --prefix test run build')" 0
  eq "U28 negative control: a retitled npm install t is not a runner" "$(titled 'npm install t')" 0
else
  echo "SKIP - U5 to U28: no real node on PATH before the recorder dir"
fi

# The refusal names a command that runs. The guest line is run through guest-exec.sh with a stub SDK that
# joins argv with a space and hands it to bash -c in the fixture guest home, as vmsdk.py's exec does.
cat >"$TMP/vmsdk-stub.py" <<'PY'
import os, subprocess, sys
rest = sys.argv[3:]
cmd = " ".join(rest[rest.index("--") + 1:])
sys.exit(subprocess.run(["bash", "-c", cmd], cwd=os.environ["HOME"]).returncode)
PY
WR="$TMP/wrepo"
mkdir -p "$WR/scripts"
git -C "$WR" init -q
cp "$TMP/real-tool.sh" "$WR/scripts/test-w.sh"
(cd "$WR" && as_session bash scripts/test-w.sh >"$TMP/w.out" 2>&1)
has "W1 a relative suite path is run from the guest checkout" "$TMP/w.out" "-- env -C himmel bash scripts/test-w.sh"
printed="$(grep -F 'guest-exec.sh' "$TMP/w.out" | head -1)"
printed="${printed#*: }"
(cd "$TMP" && as_session bash "$WR/scripts/test-w.sh" >"$TMP/w.out" 2>&1)
has "W1 an absolute suite path is run from the guest checkout" "$TMP/w.out" "-- env -C himmel bash scripts/test-w.sh"
has "W1 the refusal says the VM must be on and the guest holds origin/main" "$TMP/w.out" "vmsdk.py himmel-ar-1 up"
has "W2 the after-report line names its usage exactly" "$TMP/w.out" "bash scripts/vm/after-report.sh <branch> <pr>"
bash "$root/scripts/vm/after-report.sh" >"$TMP/ar.out" 2>&1
has "W2 after-report.sh's own usage reads the same" "$TMP/ar.out" "usage: scripts/vm/after-report.sh <branch> <pr>"
mkdir -p "$HOME/himmel"
cp -R "$WR/scripts" "$HOME/himmel/scripts"
eq "W3 the printed line, run through guest-exec.sh and the argv join, reaches the suite" "$(cd "$root" && HIMMEL_VMSDK="$TMP/vmsdk-stub.py" as_session bash -c "$printed" >/dev/null 2>&1; echo $?)" 77
rc="$(cd "$root" && HIMMEL_VMSDK="$TMP/vmsdk-stub.py" as_session bash -c "bash scripts/vm/guest-exec.sh himmel-ar-1 -- bash -c 'cd ~/himmel && bash scripts/test-w.sh'" >/dev/null 2>&1; echo $?)"
if [ "$rc" != 77 ]; then pass "W3b the bash -c spelling loses its quoting in the argv join and never reaches the suite (rc $rc)"; else fail "W3b the stub does not model the argv join"; fi
cp "$TMP/real-tool.sh" "$WR/scripts/test_w.py"
(cd "$WR" && as_session bash -c "exec -a python3 bash scripts/test_w.py" >"$TMP/w.out" 2>&1)
has "W4 a python suite is still refused" "$TMP/w.out" "REFUSED"
if grep -qF 'guest-exec.sh' "$TMP/w.out"; then fail "W4 a python suite is not printed as a bash command"; else pass "W4 a python suite is not printed as a bash command"; fi
cp "$TMP/real-tool.sh" "$WR/scripts/test-w x.sh"
(cd "$WR" && as_session bash "scripts/test-w x.sh" >"$TMP/w.out" 2>&1)
has "W5 a suite path with a space is still refused" "$TMP/w.out" "REFUSED"
if grep -qF 'guest-exec.sh' "$TMP/w.out"; then fail "W5 a path outside [A-Za-z0-9._/-] is not printed"; else pass "W5 a path outside [A-Za-z0-9._/-] is not printed"; fi
git -C "$WR" -c user.email=t@t -c user.name=t commit -q --allow-empty -m w
git -C "$WR" checkout -q --detach
(cd "$WR" && as_session bash scripts/test-w.sh >"$TMP/w.out" 2>&1)
has "W6 a detached HEAD prints the <branch> placeholder" "$TMP/w.out" "himmel-ar-1 clone <branch>"

# A detached test that is still alive keeps its test ancestor, so it is refused.
( setsid bash -c "bash '$TMP/test-inner.sh' >/dev/null 2>&1; echo \$? >'$TMP/orphan2.rc'" >/dev/null 2>&1 & )
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/orphan2.rc" ] && break; sleep 0.2; done
eq "D1 a detached test with a live test ancestor is refused" "$(cat "$TMP/orphan2.rc" 2>/dev/null)" 77

# Pinned residuals: no door runs for these, so the guard is never asked. Closing them needs a sandbox.
printf x >"$FAKE_REAL/redirect-out"
if [ -s "$FAKE_REAL/redirect-out" ]; then pass "X1 residual: a plain redirect from a test reaches the file, no door runs"; else fail "X1 residual pin"; fi
reset
secret-tool store test-8819 >/dev/null 2>&1 <<<x
eq "X2 residual: a direct keyring tool call reaches the tool, no door runs" "$(calls 'secret-tool store')" 1

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
  # J3, K3 and K4 test this door, not the operator fence: the preload sends the fence's walk down its
  # env-only path (a worker's ancestry carries HIMMEL_CONSOLE_LEG=1; CI has no host-ns). JF proves the fence.
  DECLARE_DOOR=("$REAL_BUN" --preload "$root/scripts/jira/src/release/fixtures/fence-env-only-preload.mjs" "$J" release operator declare R8752 --versions v1 --decision 1 --verbatim-file "$TMP/verbatim.txt")
  rc=0; "${DECLARE[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if [ -e "$HIMMEL_RELEASE_STATE_DIR/R8752" ]; then fail "J1 a test's release write reached the queue"; else pass "J1 a test's release write reached nothing"; fi
  has "J1 the refusal names the VM command" "$TMP/j.out" "scripts/vm/"
  if [ "$rc" != 0 ]; then pass "J1 the write failed"; else fail "J1 the write failed"; fi
  rc=0; "$REAL_BUN" "$J" release state R8752 --mirror-root "$TMP/no-mirror" >"$TMP/j.out" 2>&1 || rc=$?
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J2 a read-only verb was refused"; else pass "J2 a read-only verb is not refused"; fi
  as_session "${DECLARE_DOOR[@]}" >"$TMP/j.out" 2>&1
  if [ -e "$HIMMEL_RELEASE_STATE_DIR/R8752/release.json" ]; then pass "J3 a real jira release run by a chief writes"; else fail "J3 a real jira release run by a chief writes ($(head -c 300 "$TMP/j.out"))"; fi
  # JF: the operator fence. The same verb with no preload, the marker only in a parent's start-up env.
  rc=0; as_session env HIMMEL_CONSOLE_LEG=1 HIMMEL_RELEASE_STATE_DIR="$TMP/fence-state" HIMMEL_RELEASE_KEY_DIR="$TMP/fence-keys" bash -c 'env -u HIMMEL_CONSOLE_LEG "$@"' _ "${DECLARE[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if [ "$rc" != 0 ]; then pass "JF the fence refuses a chief verb under a marked parent"; else fail "JF the fence refuses a chief verb under a marked parent"; fi
  has "JF the refusal names the marked ancestor" "$TMP/j.out" "refused inside a chief-spawned worker: HIMMEL_CONSOLE_LEG=1 in the start-up env of ancestor"
  if [ -e "$TMP/fence-state/R8752/release.json" ]; then fail "JF the refused verb wrote release.json"; else pass "JF the refused verb wrote nothing"; fi
  # The mint has its own door: a temp ledger passes J1's, and homedir() follows a fixture HOME, so the default key path looks temp.
  KEY_HOME="$TMP/key-home"
  mkdir -p "$KEY_HOME"
  rc=0; env -u HIMMEL_RELEASE_KEY_DIR HOME="$KEY_HOME" HIMMEL_RELEASE_STATE_DIR="$TMP/key-state-a" "${DECLARE[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  eq "K1 a test with no key dir mints no key" "$(find "$KEY_HOME" -name '*.key' | wc -l | tr -d ' ')" 0
  has "K1 the refusal names the VM command" "$TMP/j.out" "scripts/vm/"
  if [ "$rc" != 0 ]; then pass "K1 the declare failed"; else fail "K1 the declare failed"; fi
  rc=0; HIMMEL_RELEASE_KEY_DIR="$FAKE_REAL/keys" HIMMEL_RELEASE_STATE_DIR="$TMP/key-state-b" "${DECLARE[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if [ -e "$FAKE_REAL/keys/R8752.key" ]; then fail "K2 a test named a real key dir and minted"; else pass "K2 a test naming a real key dir mints nothing"; fi
  rc=0; HIMMEL_RELEASE_KEY_DIR="$TMP/key-temp" HIMMEL_RELEASE_STATE_DIR="$TMP/key-state-c" "${DECLARE_DOOR[@]}" >"$TMP/j.out" 2>&1 || rc=$?
  if [ -e "$TMP/key-temp/R8752.key" ]; then pass "K3 a test naming a temp key dir still mints there"; else fail "K3 a test naming a temp key dir still mints there ($(head -c 300 "$TMP/j.out"))"; fi
  "$CLAUDE_STUB" env -u HIMMEL_RELEASE_KEY_DIR HOME="$KEY_HOME" HIMMEL_RELEASE_STATE_DIR="$TMP/key-state-d" "${DECLARE_DOOR[@]}" >"$TMP/j.out" 2>&1
  if [ -e "$KEY_HOME/.config/himmel/release/R8752.key" ]; then pass "K4 a real session still mints the default key"; else fail "K4 a real session still mints the default key ($(head -c 300 "$TMP/j.out"))"; fi
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
        path = self.path.split('?')[0]
        if self.command == 'GET' and path.endswith('/versions'):
            body = '[{"name":"v1.1.3","description":"frozen: 2026-10-20\\nfrozen-keys: K-1"}]'
        elif self.command == 'GET' and '/comment' in path:
            body = '{"comments":[],"total":0}'
        elif self.command == 'POST':
            body = '{"id":"c-1"}'
        else:
            body = '{}'
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(body.encode())
    do_GET = do_POST = do_PUT = do_DELETE = _r
    def log_message(self, *a): pass
s = http.server.HTTPServer(('127.0.0.1', 0), H)
open(portfile, 'w').write(str(s.server_address[1]))
s.serve_forever()
PY
  python3 -I "$TMP/rec-server.py" "$HTTPLOG" "$TMP/port" >/dev/null 2>&1 &
  SRV=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$TMP/port" ] && break; sleep 0.2; done
  # A mirror of K-1 alone (no leak) and one with K-2 too (a leak): the recorder answers, so a run that gets through shows as a POST.
  : >"$TMP/ledger.jsonl"
  for m in mirror-none mirror-leak; do
    mkdir -p "$TMP/$m"
    printf '{"lastSync":"2026-10-23T00:00:00Z"}\n' >"$TMP/$m/.cursor.json"
  done
  for k in K-1 K-2; do
    printf -- '---\nkey: "%s"\nstatus: "In Progress"\ntype: "Task"\npriority: "Medium"\nfixVersions: ["v1.1.3"]\n---\n' "$k" >"$TMP/mirror-leak/$k.md"
  done
  cp "$TMP/mirror-leak/K-1.md" "$TMP/mirror-none/K-1.md"
  JIRA_ENV=(env JIRA_BASE_URL="http://127.0.0.1:$(cat "$TMP/port" 2>/dev/null)" JIRA_EMAIL=t@example.invalid JIRA_API_TOKEN=not-a-token HIMMEL_ADMISSIONS_LEDGER="$TMP/ledger.jsonl")
  LEAKS=("${JIRA_ENV[@]}" "$REAL_BUN" "$J" release leaks v1.1.3 --mirror-root "$TMP/mirror-leak")
  rc=0; "${LEAKS[@]}" --comment >"$TMP/j.out" 2>&1 || rc=$?
  has "J4 a test's leaks --comment is refused" "$TMP/j.out" "REFUSED"
  eq "J4 a test's leaks --comment reaches no Jira" "$(wc -l <"$HTTPLOG" | tr -d ' ')" 0
  rc=0; "${JIRA_ENV[@]}" "$REAL_BUN" "$J" release leaks v1.1.3 --mirror-root "$TMP/mirror-none" >"$TMP/j.out" 2>&1 || rc=$?
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J5 leaks without --comment was refused"; else pass "J5 leaks without --comment is not refused"; fi
  if grep -q '^GET ' "$HTTPLOG" && ! grep -qv '^GET ' "$HTTPLOG"; then pass "J5 leaks without --comment reaches the recorder with reads only"; else fail "J5 leaks without --comment reaches the recorder with reads only ($(head -c 200 "$HTTPLOG"))"; fi
  : >"$HTTPLOG"
  as_session "${LEAKS[@]}" --comment >"$TMP/j.out" 2>&1
  if grep -q 'REFUSED' "$TMP/j.out"; then fail "J6 a real session's leaks --comment was refused"; else pass "J6 a real session's leaks --comment is not refused"; fi
  if grep -q '^POST .*/issue/K-2/comment' "$HTTPLOG"; then pass "J6 a real session's leaks --comment posts its comment"; else fail "J6 a real session's leaks --comment posts its comment ($(head -c 300 "$HTTPLOG") $(head -c 300 "$TMP/j.out"))"; fi
  # J7/J8: the door must refuse on the Jira post itself, not only on the release root. A temp root, or no root at all, leaves the root door open.
  : >"$HTTPLOG"
  J7=(env HIMMEL_RELEASE_STATE_DIR="$TMP/j7-queue" JIRA_BASE_URL=http://jira.invalid JIRA_EMAIL=t@example.invalid JIRA_API_TOKEN=not-a-token HIMMEL_ADMISSIONS_LEDGER="$TMP/ledger.jsonl" "$REAL_BUN" "$J" release leaks v1.1.3 --mirror-root "$TMP/mirror-leak" --comment)
  # The guard prints REFUSED before the door acts, so the proof is the door's own message and no host lookup:
  # a run that got past the door fails on DNS for jira.invalid, which never resolves.
  j_post_refused() { # <label> <cmd...>
    local label="$1" jrc=0
    shift
    "$@" >"$TMP/j.out" 2>&1 || jrc=$?
    if [ "$jrc" != 0 ]; then pass "$label exits non-zero"; else fail "$label exits non-zero"; fi
    has "$label is refused on the post itself" "$TMP/j.out" "refused, nothing was posted"
    if grep -q 'ENOTFOUND' "$TMP/j.out"; then fail "$label reached the Jira host lookup"; else pass "$label never looked up the Jira host"; fi
  }
  j_post_refused "J7 a test's leaks --comment with a temp release root" "${J7[@]}"
  J8=(env -u USER_SLUG -u HIMMEL_RELEASE_STATE_DIR JIRA_BASE_URL=http://jira.invalid JIRA_EMAIL=t@example.invalid JIRA_API_TOKEN=not-a-token HIMMEL_ADMISSIONS_LEDGER="$TMP/ledger.jsonl" "$REAL_BUN" "$J" release leaks v1.1.3 --mirror-root "$TMP/mirror-leak" --comment)
  j_post_refused "J8 a test's leaks --comment with no release root at all" "${J8[@]}"
  # J9: the production path. A real session posting to a non-loopback Jira is not refused and reaches the host lookup.
  as_session "${J7[@]}" >"$TMP/j.out" 2>&1
  if grep -q 'nothing was posted' "$TMP/j.out"; then fail "J9 a real session's leaks --comment to a non-loopback Jira was refused"; else pass "J9 a real session's leaks --comment to a non-loopback Jira is not refused"; fi
  has "J9 a real session's leaks --comment reaches the Jira host lookup" "$TMP/j.out" "ENOTFOUND"
else
  echo "SKIP - J rows: no bun or no scripts/jira/node_modules here; release.test.ts holds the door row and S4 the chief's guard call"
fi

echo "== merge alert door"
MBA="$root/scripts/lib/merge-block-alert.sh"
printf '{"allowFrom":["555"]}\n' >"$TMP/access.json"
cat >"$TMP/alert-run.sh" <<'EOF'
#!/usr/bin/env bash
# read-sink-ok: $1 is the lib under test, named by this suite and never outside input
. "$1"
merge_block_alert o/r 1 abc123def "a rule"
EOF
cat >"$TMP/watch-run.sh" <<'EOF'
#!/usr/bin/env bash
# read-sink-ok: $1 is the lib under test, named by this suite and never outside input
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
# read-sink-ok: $2 is the two lines this suite took from merge-on-green, never outside input
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
# M8: a refused send is not a delivered one. The test's refusal leaves no sentinel, so a real alert for the same head still goes.
mkdir -p "$TMP/sent-m8" "$TMP/sent-m8w"
reset
alert_env MERGE_BLOCK_ALERT_DIR="$TMP/sent-m8" bash "$TMP/alert-run.sh" "$MBA"
eq "M8 a test's refused alert leaves no sentinel" "$(find "$TMP/sent-m8" -type f | wc -l | tr -d ' ')" 0
alert_env MERGE_BLOCK_ALERT_DIR="$TMP/sent-m8" "$CLAUDE_STUB" bash "$TMP/alert-run.sh" "$MBA"
eq "M8 a real alert for the same head after a refusal still sends" "$(calls bun)" 1
: >"$CHIEF_INBOX"
watch_env MERGE_BLOCK_ALERT_DIR="$TMP/sent-m8w" bash "$TMP/watch-run.sh" "$MBA"
eq "M8 a test's refused chief route leaves no sentinel" "$(find "$TMP/sent-m8w" -type f | wc -l | tr -d ' ')" 0
watch_env MERGE_BLOCK_ALERT_DIR="$TMP/sent-m8w" "$CLAUDE_STUB" bash "$TMP/watch-run.sh" "$MBA"
has "M8 a real route for the same head after a refusal still appends" "$CHIEF_INBOX" "[merge-watch o/r#2]"
# M9: a refused send crosses the process boundary as exit 77. Through it cadence-alert.sh records neither a
# delivery (the sentinel) nor a failed send (the marker doctor warns on).
reset
rc=0; env TELEGRAM_ACCESS_PATH="$TMP/access.json" bash "$root/scripts/luna/vault-stall-alert.sh" "from a test" >/dev/null 2>&1 || rc=$?
eq "M9 a test's refused vault-stall alert exits 77" "$rc" 77
eq "M9 and it sent nothing" "$(calls bun)" 0
reset
rc=0; env -u CADENCE_ALERT_SEND_CMD TELEGRAM_ACCESS_PATH="$TMP/access.json" CADENCE_ALERT_DEDUPE_DIR="$TMP/m9-sent" CADENCE_ALERT_SEND_FAILED_MARK="$TMP/m9-failed" \
  bash "$root/scripts/luna/cadence-alert.sh" fail m9-worker rc-1 /tmp/m9.log >"$TMP/m9.out" 2>&1 || rc=$?
eq "M9 cadence-alert still exits 0 for its runner" "$rc" 0
eq "M9 a refused cadence alert leaves no dedupe sentinel" "$(find "$TMP/m9-sent" -type f | wc -l | tr -d ' ')" 0
if [ -e "$TMP/m9-failed" ]; then fail "M9 a refused cadence alert wrote the send-failed marker"; else pass "M9 a refused cadence alert writes no send-failed marker"; fi
has "M9 it says the send was refused" "$TMP/m9.out" "refused"
eq "M9 and the cadence alert sent nothing" "$(calls bun)" 0

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

# ---- the scheduler, the second Telegram sender and the Jira post doors ----
# Every tool is a recorder first on PATH (asserted below), so a door that fails to refuse reaches a
# recorder, never the real crontab, atd or Telegram. SCH rows: arm-resume's crontab and at writes.
# CAS rows: the config-audit alert's chief-route sender. JP rows: release apply, release rm-run and jira
# create, each against a Jira host that never resolves, so a run past the door shows as a host lookup.
echo "== scheduler, config-audit sender and Jira post doors"
unset CRON_LIST
cat >"$BIN/sched-recorder" <<'STUB'
#!/usr/bin/env bash
t="${0##*/}"
printf '%s %s\n' "$t" "$*" >>"$REC"
case "$t:${1:-}" in
  crontab:-l) [ -z "${CRON_LIST:-}" ] || { cat "$CRON_LIST"; exit 0; }; echo "no crontab for tester" >&2; exit 1 ;;
  crontab:-) cat >/dev/null ;;
  at:*) cat >>"$REC.atbody" ;;
esac
exit 0
STUB
chmod +x "$BIN/sched-recorder"
for t in crontab at atrm atq; do ln -sf sched-recorder "$BIN/$t"; done
for tool in crontab at atrm atq; do
  [ "$(command -v "$tool")" = "$BIN/$tool" ] || { echo "FAIL - suite guard: $tool does not resolve to the recorder"; exit 1; }
done
calls_exact() { grep -c -x -- "$1" "$REC" || true; }
# at_jobs: at -t submissions with a timestamp, so a changed scheduling call does not count.
at_jobs() { grep -c -E '^at -t [0-9]{8,12}$' "$REC" || true; }

ARM="$root/scripts/handover/arm-resume.sh"
ARMBIN="$TMP/armbin"
mkdir -p "$ARMBIN" "$TMP/arm-dotenv" "$TMP/arm-work" "$TMP/arm-docs/handovers"
git init -q "$TMP/arm-work"
git init -q "$TMP/arm-docs"
# shellcheck disable=SC2016 # the stub's own $1, expanded when it runs
printf '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "2.1.296 (Claude Code)"; exit 0; fi\nexit 0\n' >"$ARMBIN/claude"
chmod +x "$ARMBIN/claude"
# arm-resume resolves its plugin profile with node, so the arm gets the real one; no scheduler tool is behind it.
REAL_NODE="$(PATH="${PATH#"$BIN":}" command -v node || true)"
[ -n "$REAL_NODE" ] && ln -sf "$REAL_NODE" "$ARMBIN/node"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-real-state-guard"}}' >"$TMP/claude-account.json"
ARM_DOC="$TMP/arm-docs/handovers/handover-s1.md"
printf -- '---\nsession_kind: test\nresume_cwd: %s\n---\n# Test handover\n' "$TMP/arm-work" >"$ARM_DOC"
ARM_TIME="$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))')"
ARM_ENV=(env PATH="$ARMBIN:$PATH" FLEET_CAP_OK=1 ARM_WITH_LIVE_WORKERS=1 ARM_TERMINAL_APP=none ARM_TEMP_CWD_OK=1
  ARM_RESUME_DOTENV_ROOT="$TMP/arm-dotenv" ARM_RESUME_LOG_DIR="$TMP/arm-logs" ARM_RUNNER_DIR="$TMP/arm-runners"
  HIMMEL_FLEET_SLOTS="$TMP/fleet-slots" SKILL_TELEMETRY_DIR="$TMP/telemetry" WORKER_BRIDGE_ROOT="$TMP/worker-bridge"
  WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json" HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
  CADENCE_USAGE_CACHE="$TMP/bank-cache.json" CLAUDE_USAGE_CACHE="$TMP/bank-cache.json"
  CLAUDE_ACCOUNT_CONFIG="$TMP/claude-account.json" HANDOVER_DIR="$TMP/arm-docs/handovers")

# SCH1/SCH2: the crontab install (the macOS shape and the Linux fallback), forced with OSTYPE.
reset
rc=0; "${ARM_ENV[@]}" OSTYPE=darwin23 bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH1 a test's crontab arm exits 77" "$rc" 77
eq "SCH1 a test's crontab arm installs nothing" "$(calls_exact 'crontab -')" 0
# A door that refuses late (after the runner dir or the runner script) would pass the row above.
if [ -e "$TMP/arm-runners" ]; then fail "SCH1 a refused arm created the runner dir"; else pass "SCH1 a refused arm left the runner dir uncreated"; fi
reset
as_session "${ARM_ENV[@]}" OSTYPE=darwin23 bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1
eq "SCH2 a real session's crontab arm installs its entry" "$(calls_exact 'crontab -')" 1
# SCH3/SCH4: the at job.
reset
rc=0; "${ARM_ENV[@]}" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH3 a test's at arm exits 77" "$rc" 77
eq "SCH3 a test's at arm schedules no job" "$(at_jobs)" 0
reset
as_session "${ARM_ENV[@]}" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1
eq "SCH4 a real session's at arm schedules its job" "$(at_jobs)" 1
has "SCH4 the job body carries the resume marker" "$REC.atbody" "# HIMMEL-Resume-"

# CAS1/CAS2: the config-audit alert's Telegram sender is the chief-route bun call.
CA_ACCESS="$TMP/ca-access.json"
printf '{"allowFrom":["12345"]}\n' >"$CA_ACCESS"
# shellcheck disable=SC2016 # the inline script's own $1, expanded by the child bash
CA_ALERT=(env TELEGRAM_ACCESS_PATH="$CA_ACCESS" BRIDGE_ROOT="$TMP/ca-bridge" HIMMEL_CONFIG_ALERT_CMD= HIMMEL_CONFIG_AUDIT_DIR="$TMP/ca-state"
  bash -c '. "$1"; _ca_alert "config alert"' _ "$root/scripts/lib/config-audit.sh")
reset
"${CA_ALERT[@]}" >/dev/null 2>&1
eq "CAS1 a test's config alert sends no Telegram message" "$(calls bun)" 0
reset
# The real node comes first so the operator chat id is read from the access file; the recorded call must carry it.
mkdir -p "$TMP/node-only"
ln -sf "$(PATH="${PATH#"$BIN":}" command -v node)" "$TMP/node-only/node"
as_session env PATH="$TMP/node-only:$PATH" "${CA_ALERT[@]}" >/dev/null 2>&1
eq "CAS2 a real session's config alert sends its Telegram message" "$(calls bun)" 1
has "CAS2 the sender is told the operator chat" "$REC" "reply 12345"

# JP rows: release apply, release rm-run and jira create post to Jira.
if [ -n "$REAL_BUN" ] && [ -d "$root/scripts/jira/node_modules/commander" ]; then
  J="$root/scripts/jira/src/index.ts"
  VENV=(env HIMMEL_RELEASE_STATE_DIR="$TMP/v-queue" JIRA_BASE_URL=http://jira.invalid JIRA_EMAIL=t@example.invalid JIRA_API_TOKEN=not-a-token JIRA_PROJECT_KEY=HIMMEL)
  V_BODY="$(printf '## Impact\nx\n\n## What\nx\n\n## Why\nx\n\n## Plan\n- x\n\n## DoD\n- x\n\n## Proof\nx\n\n## Agent detail\nx\n')"
  V_CREATE=("$REAL_BUN" "$J" create --type Task --title "from a test" --desc "$V_BODY" --labels standalone --backlog --proposed-version backlog --why "a test must not file this")
  v_refused() { # <label> <cmd...>
    local label="$1" vrc=0
    shift
    "$@" >"$TMP/v.out" 2>&1 || vrc=$?
    if [ "$vrc" != 0 ]; then pass "$label exits non-zero"; else fail "$label exits non-zero"; fi
    has "$label is refused at the door" "$TMP/v.out" "refused, nothing was posted"
    if grep -q 'ENOTFOUND' "$TMP/v.out"; then fail "$label reached the Jira host lookup"; else pass "$label never looked up the Jira host"; fi
  }
  v_open() { # <label> <downstream text the run must reach> <cmd...>
    local label="$1" want="$2"
    shift 2
    "$@" >"$TMP/v.out" 2>&1
    if grep -q 'nothing was posted' "$TMP/v.out"; then fail "$label was refused"; else pass "$label is not refused"; fi
    has "$label gets past the door to its own work" "$TMP/v.out" "$want"
  }
  v_refused "JP1 a test's release apply" "${VENV[@]}" "$REAL_BUN" "$J" release apply R8818 RU-1
  v_refused "JP2 a test's release rm-run" "${VENV[@]}" "$REAL_BUN" "$J" release rm-run R8818
  v_open "JP3 a real session's release apply" "is UNKNOWN" as_session "${VENV[@]}" "$REAL_BUN" "$J" release apply R8818 RU-1
  v_refused "JP4 a test's jira create" "${VENV[@]}" "${V_CREATE[@]}"
  v_open "JP5 a real session's jira create" "no release is declared" as_session "${VENV[@]}" "${V_CREATE[@]}"
else
  echo "SKIP - JP rows: no bun or no scripts/jira/node_modules here; the node-suites vitest rows in release.test.ts and create.test.ts (post door from a test on the station) gate the same doors"
fi

# SCH5-SCH8, CAS3/CAS4: a missing or crashing guard fails open, as M4/M5 do for the merge alert. The mirror is
# the repo with every entry symlinked except the script under test (copied) and scripts/lib/test-run-guard.
mk_mirror() { # <dir> <missing|crash>
  local d="$1" mode="$2" e
  mkdir -p "$d/scripts/lib" "$d/scripts/handover"
  for e in "$root"/* "$root"/.[!.]*; do [ "${e##*/}" = scripts ] || ln -s "$e" "$d/${e##*/}"; done
  for e in "$root"/scripts/* "$root"/scripts/.[!.]*; do
    case "${e##*/}" in handover | lib) ;; *) ln -s "$e" "$d/scripts/${e##*/}" ;; esac
  done
  for e in "$root"/scripts/lib/*; do case "${e##*/}" in test-run-guard | config-audit.sh) ;; *) ln -s "$e" "$d/scripts/lib/${e##*/}" ;; esac; done
  for e in "$root"/scripts/handover/*; do [ "${e##*/}" = arm-resume.sh ] || ln -s "$e" "$d/scripts/handover/${e##*/}"; done
  cp "$root/scripts/handover/arm-resume.sh" "$d/scripts/handover/arm-resume.sh"
  cp "$root/scripts/lib/config-audit.sh" "$d/scripts/lib/config-audit.sh"
  [ "$mode" = crash ] && printf '#!/usr/bin/env bash\nexit 1\n' >"$d/scripts/lib/test-run-guard"
  return 0
}
mk_mirror "$TMP/mir-missing" missing
mk_mirror "$TMP/mir-crash" crash
# The fail-open rows below mean nothing unless the mirror's guard really is missing or really crashes with 1.
if [ -e "$TMP/mir-missing/scripts/lib/test-run-guard" ]; then fail "MIR the missing-guard mirror holds a guard"; else pass "MIR the missing-guard mirror has no guard"; fi
rc=0; bash "$TMP/mir-crash/scripts/lib/test-run-guard" check mir "$FAKE_REAL/x" >/dev/null 2>&1 || rc=$?
eq "MIR the crash mirror's guard exits 1" "$rc" 1
for mode in missing crash; do
  M="$TMP/mir-$mode"
  [ "$mode" = missing ] && n_at=SCH5 n_cr=SCH6 n_ca=CAS3 || n_at=SCH7 n_cr=SCH8 n_ca=CAS4
  reset
  rc=0; "${ARM_ENV[@]}" bash "$M/scripts/handover/arm-resume.sh" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
  eq "$n_at a test's at arm still schedules with the guard $mode" "$(at_jobs)" 1
  if [ "$rc" = 77 ]; then fail "$n_at the at arm was refused with the guard $mode"; else pass "$n_at the at arm is not refused with the guard $mode"; fi
  reset
  rc=0; "${ARM_ENV[@]}" OSTYPE=darwin23 bash "$M/scripts/handover/arm-resume.sh" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
  eq "$n_cr a test's crontab arm still installs with the guard $mode" "$(calls_exact 'crontab -')" 1
  if [ "$rc" = 77 ]; then fail "$n_cr the crontab arm was refused with the guard $mode"; else pass "$n_cr the crontab arm is not refused with the guard $mode"; fi
  reset
  "${CA_ALERT[@]:0:${#CA_ALERT[@]}-1}" "$M/scripts/lib/config-audit.sh" >/dev/null 2>&1
  eq "$n_ca a test's config alert still sends with the guard $mode" "$(calls bun)" 1
done

# SCH9/SCH10: a stub crontab or at outside the real-tool dirs stays allowed for a test (the door asks --tool, not --real).
mkdir -p "$TMP/stubtools"
cp "$BIN/sched-recorder" "$TMP/stubtools/crontab"
cp "$BIN/sched-recorder" "$TMP/stubtools/at"
STUB_ARM=("${ARM_ENV[@]}" PATH="$TMP/stubtools:$ARMBIN:$PATH")
eq "SCH9 the stub at resolves to the stub dir" "$(PATH="$TMP/stubtools:$PATH" command -v at)" "$TMP/stubtools/at"
reset
rc=0; "${STUB_ARM[@]}" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH9 a test's at arm with a stub at is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
eq "SCH9 the stub at was reached" "$(at_jobs)" 1
reset
rc=0; "${STUB_ARM[@]}" OSTYPE=darwin23 bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH10 a test's crontab arm with a stub crontab is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
eq "SCH10 the stub crontab was reached" "$(calls_exact 'crontab -')" 1

# SCH11/SCH12: a stub crontab does not open the door when the runner dir is a real path: the runner script and
# the log dir are real writes whatever scheduler follows.
reset
rc=0; "${STUB_ARM[@]}" OSTYPE=darwin23 ARM_RUNNER_DIR="$FAKE_REAL/arm-runners-real" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH11 a test's crontab arm with a stub crontab and a real runner dir exits 77" "$rc" 77
if [ -e "$FAKE_REAL/arm-runners-real" ]; then fail "SCH11 the real runner dir was created"; else pass "SCH11 the real runner dir was not created"; fi
eq "SCH11 the stub crontab was not reached" "$(calls_exact 'crontab -')" 0
reset
as_session "${STUB_ARM[@]}" OSTYPE=darwin23 ARM_RUNNER_DIR="$FAKE_REAL/arm-runners-real" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1
eq "SCH12 a real session's arm with a real runner dir installs" "$(calls_exact 'crontab -')" 1
rm -rf "$FAKE_REAL/arm-runners-real"

# ARD rows: the superseded-arm removal. The functions are taken from arm-resume.sh, not copied, and run as the
# script runs them (soft, after the new arm stands). A stub at lets the new arm through while atrm or crontab is real.
awk '/^(_scheduler_remove_door|_crontab_delete|delete_existing)\(\) \{/ { p = 1 } p { print } /^\}/ { p = 0 }' "$ARM" >"$TMP/del.lib"
eq "ARD0 the removal functions were taken from arm-resume.sh" "$(grep -c '^[a-z_]*() {' "$TMP/del.lib")" 3
cat >"$TMP/del-run.sh" <<'EOF'
#!/usr/bin/env bash
SCRIPT_DIR="$1" PLATFORM=linux
# read-sink-ok: $2 is the three functions this suite took from arm-resume.sh, never outside input
. "$2"
delete_existing "$3" "$4"
echo "rc=$?"
EOF
printf '0 7 * * * run.sh # HIMMEL-Resume-ard\n' >"$TMP/cron-ard"
ARD_DIR="$root/scripts/handover"
reset
bash "$TMP/del-run.sh" "$ARD_DIR" "$TMP/del.lib" at-job-7 soft >"$TMP/ard.out" 2>&1
eq "ARD1 a test's soft removal of an at job runs no atrm" "$(calls atrm)" 0
has "ARD1 the soft refusal is a WARN and a non-zero return" "$TMP/ard.out" "rc=1"
has "ARD1 the soft refusal prints a WARN" "$TMP/ard.out" "WARN"
reset
rc=0; bash "$TMP/del-run.sh" "$ARD_DIR" "$TMP/del.lib" at-job-7 hard >"$TMP/ard.out" 2>&1 || rc=$?
eq "ARD2 a test's hard removal of an at job exits 77" "$rc" 77
eq "ARD2 and runs no atrm" "$(calls atrm)" 0
reset
CRON_LIST="$TMP/cron-ard" bash "$TMP/del-run.sh" "$ARD_DIR" "$TMP/del.lib" '0 7 * * * run.sh # HIMMEL-Resume-ard' soft >"$TMP/ard.out" 2>&1
eq "ARD3 a test's removal of a crontab line touches no crontab" "$(calls crontab)" 0
reset
as_session bash "$TMP/del-run.sh" "$ARD_DIR" "$TMP/del.lib" at-job-7 soft >"$TMP/ard.out" 2>&1
eq "ARD4 a real session's removal of an at job runs atrm" "$(calls_exact 'atrm 7')" 1
reset
CRON_LIST="$TMP/cron-ard" as_session bash "$TMP/del-run.sh" "$ARD_DIR" "$TMP/del.lib" '0 7 * * * run.sh # HIMMEL-Resume-ard' soft >"$TMP/ard.out" 2>&1
eq "ARD5 a real session's removal of a crontab line rewrites the crontab" "$(calls_exact 'crontab -')" 1

# ---- the cadence crontab doors ----
# Each cadence script arms and disarms through its own crontab writer. XA: a test's arm installs nothing and writes
# no runner; XB: a real session's arm installs and writes its runner; XC/XD: the same for disarm of a seeded
# entry; XE: a stub crontab with a temp runner dir stays local. The recorder crontab answers `-l` from $CRON_LIST.
echo "== cadence crontab doors"
CADENCE_ROWS=(
  "SC|scripts/cleanup/steering-cull-cadence.sh|STEERING_CULL|HIMMEL-SteeringCull|--proposal-dir $TMP/cad-prop"
  "DC|scripts/doctor-cadence.sh|DOCTORCAD|HIMMEL-Doctor|"
  "JA|scripts/eval/judge-accuracy/judge-accuracy-cadence.sh|JUDGEACC|HIMMEL-JudgeAccuracy|--verdicts $TMP/cad-verdicts"
  "QQ|scripts/eval/qmd-quality/qmd-quality-cadence.sh|QMDQUAL|HIMMEL-Qmd-Quality|--golden $TMP/cad-golden.json --index $TMP/cad-index.sqlite"
  "SS|scripts/eval/stability-scorecard.sh|SCORECARD|HIMMEL-StabilityScorecard|"
  "FR|scripts/eval/worker-digest/failure-review-cadence.sh|FAILREV|HIMMEL-FailureReview|--vault $TMP/cad-vault"
  "VS|scripts/luna/vault-stall-cadence.sh|VAULT_STALL|HIMMEL-VaultStall|--vault $TMP/cad-vault"
)
mkdir -p "$TMP/cad-prop" "$TMP/cad-verdicts"
git init -q "$TMP/cad-vault"
export LUNA_VAULT_PATH="$TMP/cad-vault"
printf '{}\n' >"$TMP/cad-golden.json"
: >"$TMP/cad-index.sqlite"
for row in "${CADENCE_ROWS[@]}"; do
  IFS='|' read -r id script pfx task armargs <<<"$row"
  S="$root/$script"
  RD="$FAKE_REAL/runner-$id"
  printf '0 7 * * 1 %s/old.sh # %s\n' "$RD" "$task" >"$TMP/cron-list-$id"
  # shellcheck disable=SC2086 # armargs is a word list built above
  cad() { local rc=0; env "${pfx}_RUNNER_DIR=$RD" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" "$@" >"$TMP/cad.out" 2>&1 || rc=$?; echo "$rc"; }
  reset
  # shellcheck disable=SC2086
  rc="$(cad bash "$S" arm $armargs)"
  eq "${id}A a test's arm exits 77" "$rc" 77
  eq "${id}A a test's arm installs nothing" "$(calls_exact 'crontab -')" 0
  if [ -e "$RD" ]; then fail "${id}A a test's arm wrote a runner under the real root"; else pass "${id}A a test's arm wrote no runner"; fi
  has "${id}A the refusal names the VM command" "$TMP/cad.out" "scripts/vm/"
  reset
  # shellcheck disable=SC2086
  rc="$(cad "$CLAUDE_STUB" bash "$S" arm $armargs)"
  eq "${id}B a real session's arm exits 0" "$rc" 0
  eq "${id}B a real session's arm installs its entry" "$(calls_exact 'crontab -')" 1
  rm -rf "$RD"
  reset
  rc="$(cad env CRON_LIST="$TMP/cron-list-$id" bash "$S" disarm)"
  eq "${id}C a test's disarm exits 77" "$rc" 77
  eq "${id}C a test's disarm rewrites no crontab" "$(calls_exact 'crontab -')" 0
  reset
  rc="$(cad env CRON_LIST="$TMP/cron-list-$id" "$CLAUDE_STUB" bash "$S" disarm)"
  eq "${id}D a real session's disarm exits 0" "$rc" 0
  eq "${id}D a real session's disarm rewrites the crontab" "$(calls_exact 'crontab -')" 1
  reset
  HD="$TMP/hermetic-runner-$id"
  # shellcheck disable=SC2086
  rc="$(env "${pfx}_CRONTAB=$TMP/stubtools/crontab" "${pfx}_RUNNER_DIR=$HD" "${pfx}_STATE_DIR=$TMP/cad-state-$id" bash "$S" arm $armargs >"$TMP/cad.out" 2>&1; echo $?)"
  eq "${id}E a stub crontab with a temp runner dir is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
  eq "${id}E the stub crontab was reached" "$(calls_exact 'crontab -')" 1
  # XF/XG: each target decides alone. XF a real crontab with a temp runner dir; XG a stub crontab with a real runner dir.
  reset
  HF="$TMP/hermetic-runner-f-$id"
  # shellcheck disable=SC2086
  rc="$(env "${pfx}_RUNNER_DIR=$HF" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" bash "$S" arm $armargs >"$TMP/cad.out" 2>&1; echo $?)"
  eq "${id}F a real crontab with a temp runner dir is refused" "$rc" 77
  eq "${id}F and installs nothing" "$(calls_exact 'crontab -')" 0
  reset
  # shellcheck disable=SC2086
  rc="$(env "${pfx}_CRONTAB=$TMP/stubtools/crontab" "${pfx}_RUNNER_DIR=$RD" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" bash "$S" arm $armargs >"$TMP/cad.out" 2>&1; echo $?)"
  eq "${id}G a stub crontab with a real runner dir is refused" "$rc" 77
  if [ -e "$RD" ]; then fail "${id}G a refused arm wrote the real runner dir"; else pass "${id}G a refused arm wrote no runner dir"; fi
  reset
  rc="$(env "${pfx}_RUNNER_DIR=$HF" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" CRON_LIST="$TMP/cron-list-$id" bash "$S" disarm >"$TMP/cad.out" 2>&1; echo $?)"
  eq "${id}H a real crontab with a temp runner dir is refused on disarm" "$rc" 77
  reset
  rc="$(env "${pfx}_CRONTAB=$TMP/stubtools/crontab" "${pfx}_RUNNER_DIR=$RD" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" CRON_LIST="$TMP/cron-list-$id" bash "$S" disarm >"$TMP/cad.out" 2>&1; echo $?)"
  eq "${id}I a stub crontab with a real runner dir is refused on disarm" "$rc" 77
done
# A multi-word crontab command is judged by its first word: "env crontab" is a system tool, not a stub.
reset
rc="$(env SCORECARD_CRONTAB="env crontab" SCORECARD_RUNNER_DIR="$TMP/hermetic-runner-ssm" SCORECARD_STATE_DIR="$TMP/cad-state-ssm" bash "$root/scripts/eval/stability-scorecard.sh" arm >"$TMP/cad.out" 2>&1; echo $?)"
eq "SSM a multi-word crontab command with a temp runner dir is refused" "$rc" 77
eq "SSM and installs nothing" "$(calls_exact 'crontab -')" 0
reset
rc="$(env SCORECARD_CRONTAB="env crontab" SCORECARD_RUNNER_DIR="$TMP/hermetic-runner-ssm" SCORECARD_STATE_DIR="$TMP/cad-state-ssm" CRON_LIST="$TMP/cron-list-SS" bash "$root/scripts/eval/stability-scorecard.sh" disarm >"$TMP/cad.out" 2>&1; echo $?)"
eq "SSM a multi-word crontab command with a temp runner dir is refused on disarm" "$rc" 77
eq "SSM and rewrites no crontab on disarm" "$(calls_exact 'crontab -')" 0

# ---- the vault, config and index writer doors ----
echo "== vault, config and index writer doors"
# LU rows: luna-upgrade-all apply and restore. The door sits before the vault is classified, so a vault with only
# .obsidian/ is enough: a run past the door stops at "unstamped", and a refused run says nothing of the sort.
LU="$root/scripts/luna-upgrade-all.sh"
mkdir -p "$FAKE_REAL/lu-vault/.obsidian"
rc=0; bash "$LU" apply --vault "$FAKE_REAL/lu-vault" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU1 a test's apply on a real vault exits 77" "$rc" 77
if grep -q 'unstamped' "$TMP/lu.out"; then fail "LU1 a test's apply got past the door"; else pass "LU1 a test's apply stopped at the door"; fi
rc=0; as_session bash "$LU" apply --vault "$FAKE_REAL/lu-vault" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU2 a real session's apply gets past the door" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
has "LU2 a real session's apply reaches the vault classification" "$TMP/lu.out" "unstamped"
rc=0; bash "$LU" restore --vault "$FAKE_REAL/lu-vault" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU3 a test's restore on a real vault exits 77" "$rc" 77
rc=0; bash "$LU" restore --vault "$FAKE_REAL/lu-vault" --list >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU4 a test's restore --list only reads, so it is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
rc=0; as_session bash "$LU" restore --vault "$FAKE_REAL/lu-vault" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU5 a real session's restore gets past the door" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
mkdir -p "$TMP/lu-hermetic/.obsidian"
rc=0; bash "$LU" apply --vault "$TMP/lu-hermetic" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU6 a test's apply on a temp vault stays local" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok

# ME rows: migrate-env-config writes ~/.himmel/himmel.conf and a vault's .himmel.
ME="$root/scripts/setup/migrate-env-config.sh"
printf 'HIMMEL_INITIATIVE=prcheck\n' >"$TMP/me.env"
MHOME="$FAKE_REAL/mhome"
rc=0; env HOME="$MHOME" bash "$ME" --env "$TMP/me.env" >"$TMP/me.out" 2>&1 || rc=$?
eq "ME1 a test's migrate into a real himmel.conf exits 77" "$rc" 77
if [ -e "$MHOME/.himmel/himmel.conf" ]; then fail "ME1 a test wrote the real himmel.conf"; else pass "ME1 a test wrote no himmel.conf"; fi
rc=0; env HOME="$MHOME" "$CLAUDE_STUB" bash "$ME" --env "$TMP/me.env" >"$TMP/me.out" 2>&1 || rc=$?
eq "ME2 a real session's migrate exits 0" "$rc" 0
has "ME2 a real session's migrate writes the key" "$MHOME/.himmel/himmel.conf" "HIMMEL_INITIATIVE"
rc=0; env HOME="$TMP/me-hermetic-home" bash "$ME" --env "$TMP/me.env" >"$TMP/me.out" 2>&1 || rc=$?
eq "ME3 a test's migrate into a temp home stays local" "$rc" 0
has "ME3 and writes the key there" "$TMP/me-hermetic-home/.himmel/himmel.conf" "HIMMEL_INITIATIVE"
rc=0; env HOME="$TMP/me-hermetic-home2" bash "$ME" --env "$TMP/me.env" --vault "$FAKE_REAL/me-vault" >"$TMP/me.out" 2>&1 || rc=$?
eq "ME4 a test's --vault link into a real vault exits 77" "$rc" 77
if [ -e "$FAKE_REAL/me-vault" ]; then fail "ME4 a test created the real vault dir"; else pass "ME4 a test created no vault dir"; fi

# AU rows: ast-update rebuilds <corpus>/graphify-out. graphify is a recorder.
AU="$root/scripts/graphify/ast-update.sh"
mkdir -p "$FAKE_REAL/au-corpus"
reset
rc=0; bash "$AU" "$FAKE_REAL/au-corpus" >"$TMP/au.out" 2>&1 || rc=$?
eq "AU1 a test's ast-update on a real corpus exits 77" "$rc" 77
eq "AU1 graphify never ran" "$(calls 'graphify update')" 0
if [ -e "$FAKE_REAL/au-corpus/graphify-out" ]; then fail "AU1 the real graphify-out was created"; else pass "AU1 the real graphify-out was not created"; fi
reset
as_session bash "$AU" "$FAKE_REAL/au-corpus" >"$TMP/au.out" 2>&1
has "AU2 a real session's ast-update runs graphify" "$REC" "graphify update"
mkdir -p "$TMP/au-hermetic"
reset
bash "$AU" "$TMP/au-hermetic" >"$TMP/au.out" 2>&1
has "AU3 a test's ast-update on a temp corpus stays local" "$REC" "graphify update"

# GC rows: graph-cadence. Every worker script is a recorder and the repo is empty, so a run past the door
# fails at its first git step; the proof is what it wrote before that.
GCS="$root/scripts/graphify/graph-cadence.sh"
git init -q "$FAKE_REAL/gc-himmel"
GC_ENV=(env GRAPH_CADENCE_HIMMEL_ROOT="$FAKE_REAL/gc-himmel" GRAPH_CADENCE_DOTENV_ROOT="$TMP/gc-dotenv" GRAPH_CADENCE_LEDGER_ROOT="$FAKE_REAL/gc-ledger"
  GRAPH_CADENCE_WORKTREE_DIR="$FAKE_REAL/gc-wt" GRAPH_CADENCE_AST_UPDATE="$BIN/qmd" GRAPH_CADENCE_GRAPH_PUBLISH="$BIN/qmd" GRAPH_CADENCE_MERGE_ON_GREEN="$BIN/qmd")
reset
rc=0; "${GC_ENV[@]}" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC1 a test's graph-cadence on a real worktree exits 77" "$rc" 77
if [ -e "$FAKE_REAL/gc-ledger" ] || [ -e "$FAKE_REAL/gc-wt.log" ]; then fail "GC1 a test's graph-cadence wrote its ledger or log"; else pass "GC1 a test's graph-cadence wrote nothing"; fi
rc=0; "${GC_ENV[@]}" "$CLAUDE_STUB" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC2 a real session's graph-cadence is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
if [ -d "$FAKE_REAL/gc-ledger/.graph-cadence" ]; then pass "GC2 a real session's graph-cadence writes its ledger"; else fail "GC2 a real session's graph-cadence writes its ledger ($(head -c 300 "$TMP/gc.out"))"; fi
# GC3/GC4: temp worktree and corpus, so the first door passes; only the ledger root decides.
git init -q "$TMP/gc-himmel-t"
GC_T_ENV=(env GRAPH_CADENCE_HIMMEL_ROOT="$TMP/gc-himmel-t" GRAPH_CADENCE_DOTENV_ROOT="$TMP/gc-dotenv" GRAPH_CADENCE_WORKTREE_DIR="$TMP/gc-wt-t"
  GRAPH_CADENCE_AST_UPDATE="$BIN/qmd" GRAPH_CADENCE_GRAPH_PUBLISH="$BIN/qmd" GRAPH_CADENCE_MERGE_ON_GREEN="$BIN/qmd")
reset
rc=0; "${GC_T_ENV[@]}" GRAPH_CADENCE_LEDGER_ROOT="$FAKE_REAL/gc-ledger3" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC3 a test's graph-cadence with a real ledger root exits 77" "$rc" 77
if [ -e "$FAKE_REAL/gc-ledger3" ]; then fail "GC3 a test's graph-cadence wrote a real ledger root"; else pass "GC3 a test's graph-cadence wrote no real ledger root"; fi
rc=0; "${GC_T_ENV[@]}" GRAPH_CADENCE_LEDGER_ROOT="$TMP/gc-ledger4" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC4 a test's graph-cadence with a temp ledger root is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok

# RG rows: refresh-graph-map. --no-update, so no extraction runs; the proof is the out dir and the lock it takes.
RG="$root/scripts/graphify/refresh-graph-map.sh"
mkdir -p "$FAKE_REAL/rg-corpus"
RG_ARGS=(--name t --corpus-root "$FAKE_REAL/rg-corpus" --maps-dir "$FAKE_REAL/rg-maps" --title T --slug s --no-update)
rc=0; bash "$RG" "${RG_ARGS[@]}" >"$TMP/rg.out" 2>&1 || rc=$?
eq "RG1 a test's refresh of a real corpus exits 77" "$rc" 77
if [ -e "$FAKE_REAL/rg-corpus/graphify-out" ] || [ -e "$FAKE_REAL/rg-maps" ]; then fail "RG1 a test's refresh wrote a real out or maps dir"; else pass "RG1 a test's refresh wrote nothing"; fi
rc=0; as_session bash "$RG" "${RG_ARGS[@]}" >"$TMP/rg.out" 2>&1 || rc=$?
eq "RG2 a real session's refresh is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
mkdir -p "$TMP/rg-hermetic"
rc=0; bash "$RG" --name t --corpus-root "$TMP/rg-hermetic" --maps-dir "$TMP/rg-hermetic-maps" --title T --slug s --no-update >"$TMP/rg.out" 2>&1 || rc=$?
eq "RG3 a test's refresh of a temp corpus stays local" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok

# SE rows: cloud/setup-env.sh. Every earlier step finds its tool present (recorders on PATH) and the root has no
# repo, so the writers left are the graphify rebuild and the qmd index, which is qmd-bounded.sh, a recorder here.
SE="$root/scripts/cloud/setup-env.sh"
SE_ROOT="$FAKE_REAL/cloud-root"
mkdir -p "$TMP/cloudbin" "$TMP/stubq"
cp "$BIN/qmd" "$TMP/stubq/qmd"
mk_se_root() { # <dir>: a cloud root with no guard of its own; the script finds the guard beside itself
  mkdir -p "$1/scripts/lib" "$1/scripts/jira/dist"
  : >"$1/scripts/jira/dist/index.js"
  # shellcheck disable=SC2016 # the recorder's own $* and $REC, expanded when it runs
  printf '#!/usr/bin/env bash\nprintf "qmdb %%s\\n" "$*" >>"$REC"\n' >"$1/scripts/lib/qmd-bounded.sh"
  chmod +x "$1/scripts/lib/qmd-bounded.sh"
}
mk_se_root "$SE_ROOT"
for t in shellcheck pre-commit gitleaks; do printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/cloudbin/$t"; done
chmod +x "$TMP/cloudbin"/*
SE_ENV=(env PATH="$TMP/cloudbin:$PATH" HIMMEL_CLOUD_ROOT="$SE_ROOT")
reset
rc=0; "${SE_ENV[@]}" bash "$SE" >"$TMP/se.out" 2>&1 || rc=$?
eq "SE1 a test's setup-env on the station exits 77" "$rc" 77
eq "SE1 graphify never ran" "$(calls 'graphify update')" 0
eq "SE1 the qmd index was never touched" "$(calls qmdb)" 0
reset
rc=0; "${SE_ENV[@]}" "$CLAUDE_STUB" bash "$SE" >"$TMP/se.out" 2>&1 || rc=$?
eq "SE2 a real session's setup-env exits 0" "$rc" 0
has "SE2 a real session's setup-env rebuilds the graph" "$REC" "graphify update"
has "SE2 a real session's setup-env indexes qmd" "$REC" "qmdb collection add"
reset
"${SE_ENV[@]}" bash "$SE" --dry-run >"$TMP/se.out" 2>&1
eq "SE3 a test's --dry-run changes nothing and is not refused" "$(calls 'graphify update')" 0
has "SE3 the dry run prints its plan" "$TMP/se.out" "step=graphify-graph"
# SE4/SE5/SE6: each of the two targets decides alone (the real qmd tool, the real graph dir).
mk_se_root "$TMP/cloud-root-t"
reset
rc=0; env PATH="$TMP/cloudbin:$PATH" HIMMEL_CLOUD_ROOT="$TMP/cloud-root-t" bash "$SE" >"$TMP/se.out" 2>&1 || rc=$?
eq "SE4 a real qmd with a temp root is refused" "$rc" 77
eq "SE4 the qmd index was never touched" "$(calls qmdb)" 0
reset
rc=0; env PATH="$TMP/stubq:$TMP/cloudbin:$PATH" HIMMEL_CLOUD_ROOT="$SE_ROOT" bash "$SE" >"$TMP/se.out" 2>&1 || rc=$?
eq "SE5 a stub qmd with a real root is refused" "$rc" 77
rc=0; env PATH="$TMP/stubq:$TMP/cloudbin:$PATH" HIMMEL_CLOUD_ROOT="$TMP/cloud-root-t" bash "$SE" >"$TMP/se.out" 2>&1 || rc=$?
eq "SE6 a stub qmd with a temp root is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok

# GC5/GC6, RG4/RG5, LU7/LU8, SCH13: the second target of each two-target door decides alone.
reset
rc=0; "${GC_T_ENV[@]}" GRAPH_CADENCE_WORKTREE_DIR="$FAKE_REAL/gc-wt5" GRAPH_CADENCE_LEDGER_ROOT="$TMP/gc-ledger5" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC5 a real worktree with a temp corpus is refused" "$rc" 77
rc=0; "${GC_T_ENV[@]}" GRAPH_CADENCE_HIMMEL_ROOT="$FAKE_REAL/gc-himmel" GRAPH_CADENCE_LEDGER_ROOT="$TMP/gc-ledger6" bash "$GCS" >"$TMP/gc.out" 2>&1 || rc=$?
eq "GC6 a temp worktree with a real corpus is refused" "$rc" 77
rc=0; bash "$RG" --name t --corpus-root "$TMP/rg-hermetic" --maps-dir "$FAKE_REAL/rg-maps4" --title T --slug s --no-update >"$TMP/rg.out" 2>&1 || rc=$?
eq "RG4 a temp corpus with a real maps dir is refused" "$rc" 77
rc=0; bash "$RG" --name t --corpus-root "$FAKE_REAL/rg-corpus" --maps-dir "$TMP/rg-hermetic-maps5" --title T --slug s --no-update >"$TMP/rg.out" 2>&1 || rc=$?
eq "RG5 a real corpus with a temp maps dir is refused" "$rc" 77
rc=0; env HOME="$FAKE_REAL/lu-home" bash "$LU" apply --vault "$TMP/lu-hermetic" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU7 a temp vault with real backups is refused on apply" "$rc" 77
rc=0; env HOME="$FAKE_REAL/lu-home" bash "$LU" restore --vault "$TMP/lu-hermetic" >"$TMP/lu.out" 2>&1 || rc=$?
eq "LU8 a temp vault with real backups is refused on restore" "$rc" 77
reset
rc=0; "${STUB_ARM[@]}" OSTYPE=darwin23 ARM_RESUME_LOG_DIR="$FAKE_REAL/arm-logs-real" bash "$ARM" --time "$ARM_TIME" --handover "$ARM_DOC" >"$TMP/s.out" 2>&1 || rc=$?
eq "SCH13 a stub crontab with a real log dir is refused" "$rc" 77
if [ -e "$FAKE_REAL/arm-logs-real" ]; then fail "SCH13 the real log dir was created"; else pass "SCH13 the real log dir was not created"; fi

# VR rows: vault-stall run. The vault and its state dir each decide alone.
VSC="$root/scripts/luna/vault-stall-cadence.sh"
git init -q "$FAKE_REAL/vs-vault"
rc=0; env VAULT_STALL_STATE_DIR="$TMP/vs-state1" bash "$VSC" run --vault "$FAKE_REAL/vs-vault" >"$TMP/vs.out" 2>&1 || rc=$?
eq "VR1 a test's run on a real vault exits 77" "$rc" 77
if [ -e "$TMP/vs-state1" ]; then fail "VR1 a refused run created its state dir"; else pass "VR1 a refused run created nothing"; fi
rc=0; env VAULT_STALL_STATE_DIR="$FAKE_REAL/vs-state2" bash "$VSC" run --vault "$TMP/cad-vault" >"$TMP/vs.out" 2>&1 || rc=$?
eq "VR2 a test's run with a real state dir exits 77" "$rc" 77
if [ -e "$FAKE_REAL/vs-state2" ]; then fail "VR2 the real state dir was created"; else pass "VR2 the real state dir was not created"; fi
rc=0; env VAULT_STALL_STATE_DIR="$TMP/vs-state3" bash "$VSC" run --vault "$TMP/cad-vault" >"$TMP/vs.out" 2>&1 || rc=$?
eq "VR3 a test's run on a temp vault stays local" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok
rc=0; env VAULT_STALL_STATE_DIR="$TMP/vs-state4" "$CLAUDE_STUB" bash "$VSC" run --vault "$FAKE_REAL/vs-vault" >"$TMP/vs.out" 2>&1 || rc=$?
eq "VR4 a real session's run on a real vault is not refused" "$([ "$rc" = 77 ] && echo refused || echo ok)" ok

# FO rows: a missing or crashing guard lets every new door through (only exit 77 refuses). The mirror holds a real
# copy of the script under test and no guard, or a guard that exits 1.
shadow() { # <mirror> <repo-relative script>: real directories down to the script, then a copy of it
  local d="$1" rest="$2" cur="" part e
  while [[ "$rest" == */* ]]; do
    part="${rest%%/*}"; rest="${rest#*/}"; cur="${cur:+$cur/}$part"
    if [ -L "$d/$cur" ]; then
      rm "$d/$cur"; mkdir "$d/$cur"
      for e in "$root/$cur"/* "$root/$cur"/.[!.]*; do [ -e "$e" ] && ln -s "$e" "$d/$cur/${e##*/}"; done
    fi
  done
  rm -f "$d/$2"; cp "$root/$2" "$d/$2"
}
FO_SCRIPTS=(scripts/luna/vault-stall-cadence.sh scripts/luna-upgrade-all.sh scripts/setup/migrate-env-config.sh scripts/graphify/ast-update.sh
  scripts/graphify/graph-cadence.sh scripts/graphify/refresh-graph-map.sh scripts/cloud/setup-env.sh)
for mode in missing crash; do
  M="$TMP/fo-$mode"
  mk_mirror "$M" "$mode"
  for s in "${FO_SCRIPTS[@]}"; do shadow "$M" "$s"; done
  for row in "${CADENCE_ROWS[@]}"; do
    IFS='|' read -r id script pfx task armargs <<<"$row"
    shadow "$M" "$script"
    reset
    rc=0
    # shellcheck disable=SC2086
    env "${pfx}_RUNNER_DIR=$FAKE_REAL/fo-runner-$id" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" bash "$M/$script" arm $armargs >"$TMP/fo.out" 2>&1 || rc=$?
    if [ "$rc" = 77 ]; then fail "FO the guard $mode refused ${id} arm"; else pass "FO the guard $mode does not refuse ${id} arm"; fi
    eq "FO the guard $mode lets ${id} arm install its entry" "$(calls_exact 'crontab -')" 1
    reset
    rc=0
    env "${pfx}_RUNNER_DIR=$FAKE_REAL/fo-runner-$id" "${pfx}_STATE_DIR=$TMP/cad-state-$id" HIMMEL_DOCTOR_STATE_DIR="$TMP/cad-state-$id" CRON_LIST="$TMP/cron-list-$id" bash "$M/$script" disarm >"$TMP/fo.out" 2>&1 || rc=$?
    if [ "$rc" = 77 ]; then fail "FO the guard $mode refused ${id} disarm"; else pass "FO the guard $mode does not refuse ${id} disarm"; fi
    eq "FO the guard $mode lets ${id} disarm rewrite the crontab" "$(calls_exact 'crontab -')" 1
  done
  # The arm-resume removal door: the functions run against the mirror dir, so the guard is the missing or crashing one.
  reset
  bash "$TMP/del-run.sh" "$M/scripts/handover" "$TMP/del.lib" at-job-7 soft >"$TMP/fo.out" 2>&1
  eq "FO the guard $mode lets the arm-resume removal door run atrm" "$(calls_exact 'atrm 7')" 1
  for s in "${FO_SCRIPTS[@]}"; do
    rc=0
    case "$s" in
      */vault-stall-cadence.sh) env VAULT_STALL_STATE_DIR="$FAKE_REAL/fo-state" bash "$M/$s" run --vault "$FAKE_REAL/vs-vault" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */luna-upgrade-all.sh) bash "$M/$s" apply --vault "$FAKE_REAL/lu-vault" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */migrate-env-config.sh) env HOME="$FAKE_REAL/fo-home" bash "$M/$s" --env "$TMP/me.env" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */ast-update.sh) bash "$M/$s" "$FAKE_REAL/au-corpus" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */graph-cadence.sh) "${GC_ENV[@]}" bash "$M/$s" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */refresh-graph-map.sh) bash "$M/$s" "${RG_ARGS[@]}" >"$TMP/fo.out" 2>&1 || rc=$? ;;
      */setup-env.sh) env PATH="$TMP/cloudbin:$PATH" HIMMEL_CLOUD_ROOT="$SE_ROOT" bash "$M/$s" >"$TMP/fo.out" 2>&1 || rc=$? ;;
    esac
    if [ "$rc" = 77 ]; then fail "FO the guard $mode refused ${s##*/}"; else pass "FO the guard $mode does not refuse ${s##*/}"; fi
  done
done

echo
if [ "$fails" -eq 0 ]; then echo "PASS - test-real-state-guard: all rows"; exit 0; fi
echo "FAIL - test-real-state-guard: $fails row(s)"
exit 1
