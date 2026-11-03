#!/usr/bin/env bash
# Guard test for the repo-root vitest.config.ts: a vitest run from the repo
# root must not touch the operator's real HOME, release state, admissions ledger or keyring.
#
# Usage: bash scripts/ci/test-root-vitest-sandbox.sh
#
# Safe if the sandbox ever breaks: HOME is pointed at a fresh mktemp dir before any vitest call.
# The runtime cases need scripts/jira/node_modules/.bin/vitest (npm ci in scripts/jira). They
# never use npx (that would fetch from the network). Without it they print SKIP and exit 0,
# unless HIMMEL_REQUIRE_JIRA_VITEST=1, which turns that SKIP into a FAIL. The node-suites (jira)
# job in ci.yml sets it. The shell-unit shards have no jira install, so there only the static
# cases run: the node-suites (jira) job is where the runtime cases are enforced.
#
# Cases:
#   1 static: the root config names the sandbox file, which sets all four overrides, and does
#     not import 'vitest/config' (the root has no node_modules; see vitest.config.ts)
#   2 RED control: a project with NO config, a probe that removes $HOME/.himmel/config.json
#     -> the canary is DELETED (the failure the root config exists to stop)
#   3 the repo's real root config (copied with the real setup file) -> the canary SURVIVES
#     and the release-state, ledger and keyring overrides are in force
#   4 scripts/jira/src/commands/sector.test.ts run from the repo root with a config that has
#     NO setup file -> the canary SURVIVES (the test sandboxes its own HOME)
#
# Exit codes: 0 — all cases passed (or the runtime cases SKIPped); 1 — at least one failed
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/h8974.XXXXXX")" || exit 1
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
mkdir -p "$HOME"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

cfg="$HOME/.himmel/config.json"
seed() { mkdir -p "$HOME/.himmel"; printf '{"seed":1}\n' > "$cfg"; }
canary() { if [ -f "$cfg" ] && grep -q '"seed":1' "$cfg"; then echo SURVIVED; else echo DELETED; fi; }

# ---- case 1: static
root_cfg="$REPO_ROOT/vitest.config.ts"
setup="$REPO_ROOT/scripts/jira/vitest.setup.ts"
if [ -f "$root_cfg" ] && grep -q "setupFiles: \['./scripts/jira/vitest.setup.ts'\]" "$root_cfg" && [ -f "$setup" ]; then
  pass "root vitest.config.ts applies scripts/jira/vitest.setup.ts"
else
  fail "root vitest.config.ts missing or does not apply scripts/jira/vitest.setup.ts"
fi
for v in HOME HIMMEL_RELEASE_STATE_DIR HIMMEL_ADMISSIONS_LEDGER HIMMEL_SECRETS_KEYRING; do
  if grep -q "process.env.$v = " "$setup"; then pass "sandbox file sets $v"; else fail "sandbox file does not set $v"; fi
done
if grep -Eq "^[[:space:]]*(import|const|let|var)[^/]*(from[[:space:]]*|require\()['\"]vitest/config['\"]" "$root_cfg"; then
  fail "root vitest.config.ts imports 'vitest/config' (unresolvable from the root: a plain-object config is required)"
else
  pass "root vitest.config.ts is a plain object (no 'vitest/config' import)"
fi

# ---- runtime cases need the jira vitest install
vitest="$REPO_ROOT/scripts/jira/node_modules/.bin/vitest"
if [ ! -x "$vitest" ]; then
  if [ "${HIMMEL_REQUIRE_JIRA_VITEST:-}" = 1 ]; then
    fail "runtime cases 2-4 cannot run: $vitest is missing and HIMMEL_REQUIRE_JIRA_VITEST=1"
  else
    echo "  SKIP  runtime cases 2-4: scripts/jira/node_modules is not installed"
  fi
  [ "$failures" -eq 0 ]
  exit
fi

proj="$tmp/proj"
mkdir -p "$proj/scripts/jira"
ln -s "$REPO_ROOT/scripts/jira/node_modules" "$proj/node_modules"
cat > "$proj/delete.test.ts" <<'EOF'
import { test } from 'vitest';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
test('removes the config under HOME', () => {
  rmSync(join(process.env.HOME!, '.himmel', 'config.json'), { force: true });
});
EOF
cat > "$proj/env.test.ts" <<'EOF'
import { test, expect } from 'vitest';
import { tmpdir } from 'node:os';
test('release state, ledger and keyring overrides are in force', () => {
  const t = tmpdir();
  expect(process.env.HIMMEL_RELEASE_STATE_DIR?.startsWith(t)).toBe(true);
  expect(process.env.HIMMEL_ADMISSIONS_LEDGER?.startsWith(t)).toBe(true);
  expect(process.env.HIMMEL_SECRETS_KEYRING).toBe('off');
});
EOF

# ---- case 2: RED control, no config
seed
(cd "$proj" && "$vitest" run delete.test.ts >"$tmp/case2.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = DELETED ]; then pass "RED control: with no sandbox config the canary is DELETED"; else fail "RED control: rc=$rc canary $(canary) (log $tmp/case2.log)"; sed -n 1,20p "$tmp/case2.log"; fi

# ---- case 3: the real root config + real setup file
cp "$root_cfg" "$proj/vitest.config.ts"
cp "$setup" "$proj/scripts/jira/vitest.setup.ts"
seed
(cd "$proj" && "$vitest" run delete.test.ts env.test.ts >"$tmp/case3.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "root config: canary SURVIVED and the overrides are in force"; else fail "root config: rc=$rc canary $(canary) (log $tmp/case3.log)"; sed -n 1,30p "$tmp/case3.log"; fi

# ---- case 4: sector.test.ts from the repo root with a config that has no setup file
printf 'export default { test: { environment: "node" } };\n' > "$tmp/nosetup.config.mjs"
seed
(cd "$REPO_ROOT" && "$vitest" run --config "$tmp/nosetup.config.mjs" scripts/jira/src/commands/sector.test.ts >"$tmp/case4.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "sector.test.ts with no setup file: canary SURVIVED"; else fail "sector.test.ts with no setup file: rc=$rc canary $(canary) (log $tmp/case4.log)"; sed -n 1,30p "$tmp/case4.log"; fi

[ "$failures" -eq 0 ]
