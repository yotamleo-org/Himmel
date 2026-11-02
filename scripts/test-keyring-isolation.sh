#!/usr/bin/env bash
# test-keyring-isolation.sh — a test run never reaches the operator's real keyring.
#
# WHY: setup-secret.test.ts POSTs a fixture JIRA_API_TOKEN to an in-process server; the store's
# keyring child used to inherit the test process's environment, so a bare `bun test` wrote the
# fixture into the real user-scope keyring item. Every row runs under the stub keyring
# (scripts/lib/fixtures/keyring-stub.sh: stub secret-tool and busctl first on PATH, a dead bus),
# so it cannot touch a real keyring, and counts the stub's recorded `store` calls.
set -uo pipefail

root="$(git rev-parse --show-toplevel)"
TMP="$(mktemp -d -t keyring-isolation.XXXXXX)" || exit 1
probe="$root/scripts/config-ui/tests/zz-keyring-guard-probe.test.ts"
trap 'rm -rf "$TMP" "$probe"' EXIT
fails=0
pass() { echo "PASS - $1"; }
fail() { echo "FAIL - $1"; fails=$((fails + 1)); }
# want <got> <want-count> <label>: the recorded store-call count is the one expected.
want() { if [ "$1" = "$2" ]; then pass "$3"; else fail "$3 (got $1 store call(s), want $2)"; fi; }

# shellcheck source=scripts/lib/fixtures/keyring-stub.sh
. "$root/scripts/lib/fixtures/keyring-stub.sh"
# Suite guard: abort unless both tools resolve to the stub, so nothing below can reach a real keyring.
for tool in secret-tool busctl; do
  [ "$(command -v "$tool")" = "$KBIN/$tool" ] || { echo "FAIL - suite guard: $tool does not resolve to the stub"; exit 1; }
done

stores() { grep -c '^secret-tool store' "$KSTUB_LOG" || true; }

# A: a bare `bun test` of the setup-secret test, the pin unset (the stub unsets it).
kreset
(cd "$root/scripts/config-ui" && bun test tests/setup-secret.test.ts) >"$TMP/a.out" 2>&1
n="$(stores)"
want "$n" 0 "A bare bun test of setup-secret.test.ts records zero keyring stores"

# B: a new test file that boots the server with an env map and never mentions the pin.
cat >"$probe" <<'TS'
import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
test("probe: a file with no pin posts a secret", async () => {
  const dir = mkdtempSync(join(tmpdir(), "keyring-probe-"));
  const home = join(dir, "home"), r = join(dir, "root"), project = join(dir, "project");
  for (const d of [home, r, project]) mkdirSync(d);
  const token = "t".repeat(64);
  const s = startServer({ port: 0, token, root: r, projectRoot: project, env: { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-himmelctl.js"), CONFIG_UI_IDLE_MS: "60000" } });
  const res = await fetch(`http://127.0.0.1:${s.port}/api/setup/secret`, {
    method: "POST", headers: { "content-type": "application/json", origin: `http://127.0.0.1:${s.port}`, "x-himmel-token": token },
    body: JSON.stringify({ name: "JIRA_API_TOKEN", value: "e2e-canary-probe", op: "set" }),
  });
  s.stop();
  expect(res.status).toBe(200);
});
TS
kreset
(cd "$root/scripts/config-ui" && bun test tests/zz-keyring-guard-probe.test.ts) >"$TMP/b.out" 2>&1
n="$(stores)"
want "$n" 0 "B a new bun test file that omits the pin records zero keyring stores"
rm -f "$probe"

# C: the wizard secrets suite run directly (no suite label), the pin unset.
kreset
bash "$root/scripts/himmelctl/test/test-wizard-secrets-step.sh" >"$TMP/c.out" 2>&1
n="$(stores)"
want "$n" 0 "C test-wizard-secrets-step.sh run directly records zero keyring stores"

# D: production still works: a store call whose env map leaves the keyring on reaches the keyring (the stub);
#    one whose env map pins it off does not.
d_stores() {
  kreset
  mkdir -p "$TMP/d/home" "$TMP/d/himmel"
  KR_ROOT="$root" KR_DIR="$TMP/d" KR_ENV="$1" node - <<'NODE' >/dev/null 2>&1
const store = require(process.env.KR_ROOT + '/scripts/himmelctl/lib/secret-store.js');
const d = process.env.KR_DIR;
store.write('JIRA_API_TOKEN', 'e2e-canary-d', { home: d + '/home', himmelRoot: d + '/himmel', projectRoot: d + '/himmel', env: JSON.parse(process.env.KR_ENV), gitCheckIgnore: () => true });
NODE
  stores
}
n="$(d_stores '{"PATH":"'"$PATH"'"}')"
want "$n" 1 "D1 a store whose env map leaves the keyring on reaches the keyring"
n="$(d_stores '{"PATH":"'"$PATH"'","HIMMEL_SECRETS_KEYRING":"off"}')"
want "$n" 0 "D2 a store whose env map pins the keyring off records zero stores"

echo
if [ "$fails" = 0 ]; then echo "ALL PASS"; else echo "$fails FAILED"; exit 1; fi
