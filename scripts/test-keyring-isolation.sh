#!/usr/bin/env bash
# test-keyring-isolation.sh — a test run never reaches the operator's real keyring.
#
# WHY: setup-secret.test.ts POSTs a fixture JIRA_API_TOKEN to an in-process server; the store's
# keyring child used to inherit the test process's environment, so a bare `bun test` wrote the
# fixture into the real user-scope keyring item. Every row runs with a recording `secret-tool` and
# `busctl` first on PATH and a dead session bus, so it cannot touch a real keyring, and counts the
# recorded `store` calls. The recorder does NOT set KSTUB_STORE: a process that names a stub keyring
# that way is exempt from the NODE_ENV=test fail-closed in resolve-secrets.mjs, and these rows test
# the processes that name none. Nothing here writes into the repo tree.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d -t keyring-isolation.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT
# Every temp dir a child makes (the probe's, the wizard suite's) lands under the one dir the trap removes.
export TMPDIR="$TMP"
fails=0
pass() { echo "PASS - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
# want <got> <want-count> <label> [child-rc]: the recorded store-call count is the one expected AND the
# child ran to success, so a missing bun or a crashed child cannot pass as "zero stores".
want() {
  if [ "${4:-0}" != 0 ]; then fail "$3 (the child exited $4, so a zero count proves nothing)"
  elif [ "$1" = "$2" ]; then pass "$3"
  else fail "$3 (got $1 store call(s), want $2)"; fi
}

# The recording keyring: a store succeeds and is logged, a lookup finds nothing, the collection is unlocked.
KBIN="$TMP/kbin"
mkdir -p "$KBIN"
export KR_LOG="$TMP/keyring.log"
cat >"$KBIN/secret-tool" <<'STUB'
#!/usr/bin/env bash
printf 'secret-tool %s\n' "$*" >>"$KR_LOG"
if [ "$1" = store ]; then cat >/dev/null; exit 0; fi
exit 1
STUB
cat >"$KBIN/busctl" <<'STUB'
#!/usr/bin/env bash
case "$*" in *" Locked") echo "b false" ;; esac
STUB
chmod +x "$KBIN/secret-tool" "$KBIN/busctl"
export PATH="$KBIN:$PATH"
export DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/dead-bus"
unset CREDENTIALS_DIRECTORY HIMMEL_SECRETS_KEYRING KSTUB_STORE KSTUB_LOG NODE_ENV
# Suite guard: abort unless both tools resolve to the recorder, so nothing below can reach a real keyring.
for tool in secret-tool busctl; do
  [ "$(command -v "$tool")" = "$KBIN/$tool" ] || { echo "FAIL - suite guard: $tool does not resolve to the recorder"; exit 1; }
done
kreset() { : >"$KR_LOG"; }
stores() { grep -c '^secret-tool store' "$KR_LOG" || true; }

# bun_rows <label> <cwd> <test-path>: run one bun test file from <cwd> and expect zero stores.
bun_row() {
  kreset
  local rc=0
  (cd "$2" && bun test "$3") >"$TMP/bun.out" 2>&1 || rc=$?
  want "$(stores)" 0 "$1" "$rc"
}

st="$root/scripts/config-ui/tests/setup-secret.test.ts"
# A: the setup-secret test, bare, from its own suite dir and from the repo root (bun reads the cwd's bunfig only).
bun_row "A1 setup-secret.test.ts from scripts/config-ui records zero keyring stores" "$root/scripts/config-ui" tests/setup-secret.test.ts
bun_row "A2 setup-secret.test.ts from the repo root records zero keyring stores" "$root" scripts/config-ui/tests/setup-secret.test.ts

# M: the same file with its own pin deleted (a mutation), outside the tree, from both cwds.
mutant="$TMP/setup-secret-nopin.test.ts"
sed -e "s#\"\.\./server\"#\"$root/scripts/config-ui/server\"#" -e "s#import\.meta\.dir#\"$root/scripts/config-ui/tests\"#" \
    -e 's#, HIMMEL_SECRETS_KEYRING: "off"##' "$st" >"$mutant"
if grep -q 'HIMMEL_SECRETS_KEYRING' "$mutant"; then
  fail "M the mutation did not remove the pin from setup-secret.test.ts"
else
  bun_row "M1 setup-secret.test.ts with its pin deleted, from scripts/config-ui, records zero keyring stores" "$root/scripts/config-ui" "$mutant"
  bun_row "M2 setup-secret.test.ts with its pin deleted, from the repo root, records zero keyring stores" "$root" "$mutant"
fi

# B: a new test file that boots the server with an env map and never mentions the pin; it lives
#    outside the tree and refuses to run without the recorder.
probe="$TMP/probe.test.ts"
cat >"$probe" <<'TS'
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
test("probe: a file with no pin posts a secret", async () => {
  if (!process.env.KR_LOG) throw new Error("the probe refuses to run without the recording keyring");
  const ui = join(process.env.KR_ROOT!, "scripts/config-ui");
  const { startServer } = await import(join(ui, "server.ts"));
  const dir = mkdtempSync(join(tmpdir(), "keyring-probe-"));
  const home = join(dir, "home"), r = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, r, project]) mkdirSync(d);
  const token = "t".repeat(64);
  const s = startServer({ port: 0, token, root: r, projectRoot: project, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(ui, "tests/stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } });
  const res = await fetch(`http://127.0.0.1:${s.port}/api/setup/secret`, {
    method: "POST", headers: { "content-type": "application/json", origin: `http://127.0.0.1:${s.port}`, "x-himmel-token": token },
    body: JSON.stringify({ name: "JIRA_API_TOKEN", value: "e2e-canary-probe", op: "set" }),
  });
  s.stop();
  expect(res.status).toBe(200);
});
TS
export KR_ROOT="$root"
bun_row "B1 a new bun test file that omits the pin, from scripts/config-ui, records zero keyring stores" "$root/scripts/config-ui" "$probe"
bun_row "B2 a new bun test file that omits the pin, from the repo root, records zero keyring stores" "$root" "$probe"

# E: the UI login door. writeLogin spawns himmel-secrets itself (login.ts, not the resolver module), so it needs
#    its own fail-closed. E1/E2 an env map that names no stub (PATH and HOME only), E3/E4 the default env
#    (as readLogin/migrate and the setup route use it). The map-only case must not even search.
lprobe="$TMP/login-probe.test.ts"
cat >"$lprobe" <<'TS'
import { test, expect } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
test("probe: writeLogin with an unstubbed env never reaches a keyring", async () => {
  if (!process.env.KR_LOG) throw new Error("the probe refuses to run without the recording keyring");
  const { writeLogin } = await import(join(process.env.KR_ROOT!, "scripts/config-ui/login.ts"));
  const dir = mkdtempSync(join(tmpdir(), "login-probe-"));
  const map = process.env.KR_MAP !== "0" ? { ...(process.env.KR_MAP === "2" ? { NODE_ENV: "development" } : {}), PATH: process.env.PATH, HOME: join(dir, "home"), DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS, KR_LOG: process.env.KR_LOG } : undefined;
  let err = "";
  try { writeLogin(join(dir, "login"), "operator", "correct-horse-battery", { createOnly: true, ...(map ? { env: map } : {}) }); } catch (e) { err = (e as Error).message; }
  // the pinned-off keyring refuses the write with its own reason; on macOS an unguarded call reports "unsupported"
  // under the same prefix, so the prefix alone cannot tell the guard from its absence.
  expect(err).toMatch(/^the keyring could not be written: the keyring is off; nothing was changed/);
});
TS
searches() { grep -c '^secret-tool' "$KR_LOG" || true; }
# login_row <label> <cwd> <map 0|1|2> <0 = also expect zero searches> [stub: a KSTUB_STORE value the PROCESS carries, never the map]
login_row() {
  kreset
  local rc=0
  (cd "$2" && env ${5:+KSTUB_STORE="$5"} KR_MAP="$3" bun test "$lprobe") >"$TMP/bun.out" 2>&1 || rc=$?
  want "$(stores)" 0 "$1" "$rc"
  if [ "$4" = 0 ] && [ "$rc" = 0 ] && [ "$(searches)" != 0 ]; then fail "$1 (the keyring was searched $(searches) time(s), want 0)"; fi
}
login_row "E1 writeLogin with an unstubbed env map, from scripts/config-ui, stores and searches nothing" "$root/scripts/config-ui" 1 0
login_row "E2 writeLogin with an unstubbed env map, from the repo root, stores and searches nothing" "$root" 1 0
login_row "E5 writeLogin with a map that sets NODE_ENV=development, from scripts/config-ui, stores and searches nothing" "$root/scripts/config-ui" 2 0
login_row "E6 writeLogin with a map that sets NODE_ENV=development, from the repo root, stores and searches nothing" "$root" 2 0
login_row "E3 writeLogin with the default env, from scripts/config-ui, stores and searches nothing" "$root/scripts/config-ui" 0 0
login_row "E4 writeLogin with the default env, from the repo root, stores and searches nothing" "$root" 0 0
login_row "E7 writeLogin with a map that omits the stub the process names, from the repo root, stores and searches nothing" "$root" 1 0 named
login_row "E8 the same, from scripts/config-ui, stores and searches nothing" "$root/scripts/config-ui" 1 0 named

# C: the wizard secrets suite run directly (no suite label), the pin unset.
kreset
rc=0
bash "$root/scripts/himmelctl/test/test-wizard-secrets-step.sh" >"$TMP/c.out" 2>&1 || rc=$?
want "$(stores)" 0 "C test-wizard-secrets-step.sh run directly records zero keyring stores" "$rc"

# D: the store itself, in a plain node process. D1: an env map that leaves the keyring on reaches the
#    keyring (production). D2: a map that pins it off does not. D3: under NODE_ENV=test with no stub
#    named, a map that leaves it on still does not. D4: under NODE_ENV=test a map that names a stub
#    (KSTUB_STORE) keeps the keyring on, so a stubbed test still exercises it.
d_stores() {
  kreset
  mkdir -p "$TMP/d/home" "$TMP/d/himmel"
  # A node that fails to run prints "node-failed" instead of a count, which matches no D row.
  KR_DIR="$TMP/d" KR_ENV="$1" node - <<'NODE' >/dev/null 2>&1 || { echo node-failed; return; }
const store = require(process.env.KR_ROOT + '/scripts/himmelctl/lib/secret-store.js');
const d = process.env.KR_DIR;
store.write('JIRA_API_TOKEN', 'e2e-canary-d', { home: d + '/home', himmelRoot: d + '/himmel', projectRoot: d + '/himmel', env: JSON.parse(process.env.KR_ENV), gitCheckIgnore: () => true });
NODE
  stores
}
# The resolver skips the keyring on Darwin (himmel-secrets marks it unsupported), so the rows that need a
# served keyring skip there; the zero-store rows hold on every platform.
if [ "$(uname -s)" = Darwin ]; then
  echo "SKIP - D1 and D4: the resolver skips the keyring on Darwin"
else
  want "$(d_stores '{}')" 1 "D1 a store whose env map leaves the keyring on reaches the keyring"
  want "$(d_stores '{"NODE_ENV":"test","KSTUB_STORE":"named"}')" 1 "D4 under NODE_ENV=test a store that names a stub keeps the keyring on"
fi
want "$(d_stores '{"HIMMEL_SECRETS_KEYRING":"off"}')" 0 "D2 a store whose env map pins the keyring off records zero stores"
want "$(d_stores '{"NODE_ENV":"test"}')" 0 "D3 under NODE_ENV=test with no stub named, a store records zero stores"

# F: a bare `bash test-x.sh` with no env marker calling himmel-secrets, a door of its own. The
#    recorder stays the only secret-tool; the guard's add-only seam makes it count as the real one.
if [ "$(uname -s)" = Linux ]; then
  kreset
  rc=0
  printf 'value' | env HIMMEL_REAL_STATE_ASSUME_STATION=1 HIMMEL_REAL_STATE_EXTRA_TOOL_DIRS="$KBIN" \
    bash "$root/scripts/lib/himmel-secrets" put --stdin K8752 >"$TMP/f.out" 2>&1 || rc=$?
  want "$(stores)" 0 "F1 a bare test shell's himmel-secrets put records zero stores"
  if [ "$rc" = 77 ]; then pass "F2 the put is refused, exit 77"; else fail "F2 the put is refused (got rc $rc, want 77)"; fi
fi

echo
if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
