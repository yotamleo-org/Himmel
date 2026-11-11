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
# An inherited config or handover root would point a case at the station's own files.
unset HIMMEL_CONFIG_DIR HANDOVER_DIR

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
# The quoted specifier on any non-comment line: catches a multiline import, a bare or dynamic
# import, require() and `export ... from`, which a one-line import regex misses.
names_vitest_config() {
  local hit
  # A small scanner over the whole file: it keeps string literals (so a glob such as '**/*.ts' opens
  # no comment) and drops /* ... */ blocks across lines and // line comments; a stray star line goes last.
  hit="$(awk 'BEGIN{RS="\001"} {s=$0;n=length(s);o="";q="";i=1
    while(i<=n){c=substr(s,i,1);d=substr(s,i,2)
      if(q!=""){o=o c;if(c=="\\"){o=o substr(s,i+1,1);i+=2;continue};if(c==q)q="";i++;continue}
      if(d=="//"){while(i<=n&&substr(s,i,1)!="\n")i++;continue}
      if(d=="/*"){j=index(substr(s,i+2),"*/");if(!j){break};i+=j+3;o=o " ";continue}
      if(c=="\""||c=="\047"||c=="`")q=c
      o=o c;i++}
    printf "%s",o}' "$1" | sed -E '/^[[:space:]]*\*/d' | grep -E "['\"]vitest/config['\"]")"
  [ -n "$hit" ]
}
if names_vitest_config "$root_cfg"; then
  fail "root vitest.config.ts names 'vitest/config' (unresolvable from the root: a plain-object config is required)"
else
  pass "root vitest.config.ts is a plain object (no 'vitest/config' import)"
fi
# RED controls for the static refusal: each fixture must be refused; a commented mention must not.
sfx="$tmp/static"; mkdir -p "$sfx"
printf "import {\n  defineConfig,\n} from\n  'vitest/config';\nexport default defineConfig({});\n" > "$sfx/multiline.ts"
printf "import 'vitest/config';\nexport default {};\n" > "$sfx/bare.ts"
printf "const m = await import(\"vitest/config\");\nexport default {};\n" > "$sfx/dynamic.ts"
printf "export {\n  defineConfig,\n} from 'vitest/config';\n" > "$sfx/reexport.ts"
printf "// import { defineConfig } from 'vitest/config'\n/* 'vitest/config' */\n * 'vitest/config'\nexport default {};\n" > "$sfx/commented.ts"
# Interior line of a multiline block comment, no leading asterisk.
printf "/*\n  import { defineConfig } from 'vitest/config'\n  more prose\n*/\nexport default {};\n" > "$sfx/blockcomment.ts"
# Comment marks inside string literals (a glob) must not open a comment that swallows the import.
printf "const include = ['**/*.test.ts'];\nimport { defineConfig } from 'vitest/config';\nconst skip = ['**/node_modules/**'];\nexport default defineConfig({});\n" > "$sfx/globs.ts"
for f in multiline bare dynamic reexport globs; do
  if names_vitest_config "$sfx/$f.ts"; then pass "static check refuses a $f vitest/config import"; else fail "static check misses a $f vitest/config import"; fi
done
if names_vitest_config "$sfx/commented.ts"; then fail "static check refuses a commented-out vitest/config mention"; else pass "static check ignores a commented-out vitest/config mention"; fi
if names_vitest_config "$sfx/blockcomment.ts"; then fail "static check refuses a vitest/config mention inside a multiline block comment"; else pass "static check ignores a vitest/config mention inside a multiline block comment"; fi

# ---- bun test: bun ignores vitest.config.ts; the root bunfig.toml preload sandboxes it.
# The guard must not rest on NODE_ENV (bun sets it to test only when unset), so one row exports
# NODE_ENV=production. SKIP when bun is absent unless HIMMEL_REQUIRE_BUN_TEST=1.
if command -v bun >/dev/null 2>&1; then
  bproj="$tmp/bunproj"; mkdir -p "$bproj/scripts/jira"
  cat > "$bproj/delete.test.ts" <<'EOF'
import { test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
test('removes the config under HOME', () => {
  rmSync(join(process.env.HOME!, '.himmel', 'config.json'), { force: true });
});
EOF
  # Other ways a bun test reaches the home: os.homedir(), os.userInfo().homedir (named, namespace
  # and default imports), and a Bun.spawn / Bun.spawnSync child with no explicit env. Each probe
  # deletes the canary through that route; the canary is the only file the probes can reach.
  cat > "$bproj/homedir.test.ts" <<'EOF'
import { test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import * as osNs from 'os';
import osDefault from 'node:os';
test('removes the config under os.homedir()', () => {
  for (const h of [homedir(), osNs.homedir(), osDefault.homedir(), require('node:os').homedir()]) rmSync(join(h, '.himmel', 'config.json'), { force: true });
});
EOF
  cat > "$bproj/userinfo.test.ts" <<'EOF'
import { test } from 'bun:test';
import { rmSync } from 'node:fs';
import { join } from 'node:path';
import { userInfo } from 'node:os';
test('removes the config under os.userInfo().homedir', () => {
  rmSync(join(userInfo().homedir, '.himmel', 'config.json'), { force: true });
});
EOF
  cat > "$bproj/spawn.test.ts" <<'EOF'
import { test } from 'bun:test';
test('a default-env Bun.spawnSync and Bun.spawn child remove the config under their HOME', async () => {
  Bun.spawnSync(['sh', '-c', 'rm -f "$HOME/.himmel/config.json"']);
  await Bun.spawn(['sh', '-c', 'rm -f "$HOME/.himmel/config.json"']).exited;
});
EOF
  rm -f "$bproj/bunfig.toml"
  seed
  (cd "$bproj" && bun test >"$tmp/bun-red.log" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(canary)" = DELETED ]; then pass "RED control: bun test with no bunfig.toml DELETES the canary"; else fail "RED control: bun rc=$rc canary $(canary) (log $tmp/bun-red.log)"; fi
  if [ -f "$REPO_ROOT/bunfig.toml" ]; then cp "$REPO_ROOT/bunfig.toml" "$bproj/bunfig.toml"; fi
  cp "$setup" "$bproj/scripts/jira/vitest.setup.ts"
  mkdir -p "$bproj/scripts/jira/live" && cp "$REPO_ROOT/scripts/jira/live/project-guard.ts" "$bproj/scripts/jira/live/project-guard.ts"
  if [ -f "$REPO_ROOT/scripts/jira/bun-test-preload.ts" ]; then cp "$REPO_ROOT/scripts/jira/bun-test-preload.ts" "$bproj/scripts/jira/bun-test-preload.ts"; fi
  for probe in homedir userinfo spawn; do
    seed
    (cd "$bproj" && bun test "$probe.test.ts" >"$tmp/bun-$probe.log" 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "bun test $probe probe: canary SURVIVED"; else fail "bun test $probe probe: rc=$rc canary $(canary) (log $tmp/bun-$probe.log)"; fi
  done
  seed
  (cd "$bproj" && bun test >"$tmp/bun-a.log" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "bun test with the root bunfig.toml: canary SURVIVED"; else fail "bun test with the root bunfig.toml: rc=$rc canary $(canary) (log $tmp/bun-a.log)"; fi
  seed
  (cd "$bproj" && NODE_ENV=production bun test >"$tmp/bun-b.log" 2>&1); rc=$?
  if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "bun test with NODE_ENV=production: canary SURVIVED"; else fail "bun test with NODE_ENV=production: rc=$rc canary $(canary) (log $tmp/bun-b.log)"; fi
elif [ "${HIMMEL_REQUIRE_BUN_TEST:-}" = 1 ]; then
  fail "bun test cases cannot run: bun is missing and HIMMEL_REQUIRE_BUN_TEST=1"
else
  echo "  SKIP  bun test cases: bun is not installed"
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
mkdir -p "$proj/scripts/jira/live" && cp "$REPO_ROOT/scripts/jira/live/project-guard.ts" "$proj/scripts/jira/live/project-guard.ts"
seed
(cd "$proj" && "$vitest" run delete.test.ts env.test.ts >"$tmp/case3.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "root config: canary SURVIVED and the overrides are in force"; else fail "root config: rc=$rc canary $(canary) (log $tmp/case3.log)"; sed -n 1,30p "$tmp/case3.log"; fi

# ---- case 4: sector.test.ts from the repo root with a config that has no setup file
printf 'export default { test: { environment: "node" } };\n' > "$tmp/nosetup.config.mjs"
seed
(cd "$REPO_ROOT" && "$vitest" run --config "$tmp/nosetup.config.mjs" scripts/jira/src/commands/sector.test.ts >"$tmp/case4.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "sector.test.ts with no setup file: canary SURVIVED"; else fail "sector.test.ts with no setup file: rc=$rc canary $(canary) (log $tmp/case4.log)"; sed -n 1,30p "$tmp/case4.log"; fi

# ---- case 5: importing client.ts and calling an accessor with NO setup file reads nothing. This is
# also the any-directory row: the copy runs from a throwaway project dir with no config of its own.
# A copy of the Jira sources lives in a throwaway project, so the .env lookup anchors there and
# no real file is read; HOME holds a seeded himmel.conf with a marker value. The keyring is not
# probed: scripts/lib/resolve-secrets.mjs already fails closed under NODE_ENV=test.
marker="https://marker-8977.invalid"
mkdir -p "$HOME/.himmel"
printf 'JIRA_BASE_URL=%s\n' "$marker" > "$HOME/.himmel/himmel.conf"
mkdir -p "$proj/scripts/jira" "$proj/scripts/lib"
cp -r "$REPO_ROOT/scripts/jira/src" "$proj/scripts/jira/src"
cp "$REPO_ROOT/scripts/lib/resolve-secrets.mjs" "$proj/scripts/lib/"
printf '{"type":"module"}\n' > "$proj/package.json"
printf 'export default { test: { environment: "node" } };\n' > "$proj/nosetup.config.mjs"
cat > "$proj/import.test.ts" <<'EOF'
import { test, expect } from 'vitest';
test('importing client.ts and using an accessor reads no himmel.conf', async () => {
  delete process.env.JIRA_BASE_URL;
  const client = await import('./scripts/jira/src/client.ts');
  expect(process.env.JIRA_BASE_URL).toBeUndefined();
  expect(() => client.baseUrl()).toThrow(/not set/);
  expect(process.env.JIRA_BASE_URL).toBeUndefined();
});
EOF
(cd "$proj" && "$vitest" run --config nosetup.config.mjs import.test.ts >"$tmp/case5.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "client.ts import with no setup file reads nothing from himmel.conf"; else fail "client.ts import with no setup file read the seeded himmel.conf (rc=$rc, log $tmp/case5.log)"; sed -n 1,30p "$tmp/case5.log"; fi

# ---- case 6: an inherited HIMMEL_CONFIG_DIR / HANDOVER_DIR is not what a test sees (root config + setup).
mkdir -p "$tmp/inh-conf" "$tmp/inh-hd"
printf 'JIRA_BASE_URL=%s\n' "$marker" > "$tmp/inh-conf/himmel.conf"
cat > "$proj/inherit.test.ts" <<'EOF'
import { test, expect } from 'vitest';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
test('inherited config and handover roots are replaced', () => {
  const c = process.env.HIMMEL_CONFIG_DIR ?? '';
  expect(existsSync(join(c, 'himmel.conf'))).toBe(false);
  expect(process.env.HANDOVER_DIR).not.toBe(process.env.SEEDED_HD);
});
EOF
(cd "$proj" && HIMMEL_CONFIG_DIR="$tmp/inh-conf" HANDOVER_DIR="$tmp/inh-hd" SEEDED_HD="$tmp/inh-hd" "$vitest" run inherit.test.ts >"$tmp/case6.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "inherited HIMMEL_CONFIG_DIR and HANDOVER_DIR are not seen by a test"; else fail "an inherited HIMMEL_CONFIG_DIR or HANDOVER_DIR reached a test (rc=$rc, log $tmp/case6.log)"; sed -n 1,30p "$tmp/case6.log"; fi

# ---- case 7 (control, GREEN on base too, since sector.test.ts sandboxes its own HOME): a run from
# another directory pointed at the Jira package with --root loads that package's own config.
other="$tmp/elsewhere"; mkdir -p "$other"
seed
(cd "$other" && "$vitest" run --root "$REPO_ROOT/scripts/jira" src/commands/sector.test.ts >"$tmp/case7.log" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ "$(canary)" = SURVIVED ]; then pass "run from another directory with --root: canary SURVIVED"; else fail "run from another directory: rc=$rc canary $(canary) (log $tmp/case7.log)"; sed -n 1,30p "$tmp/case7.log"; fi

# ---- case 8: why the wizard handover cases saw the station's HANDOVER_DIR (test-wizard-probes.sh).
# load_dotenv reads himmel.conf from HIMMEL_CONFIG_DIR or $HOME/.himmel: with neither redirected
# the seeded HANDOVER_DIR is served; a throwaway HIMMEL_CONFIG_DIR hides it.
hd_clean="$tmp/hd-clean"; mkdir -p "$hd_clean"; git -C "$hd_clean" init -q -b main
printf 'HANDOVER_DIR=%s\n' "$tmp/inh-hd" > "$HOME/.himmel/himmel.conf"
hd_load() { (cd "$hd_clean" && unset HANDOVER_DIR; . "$REPO_ROOT/scripts/lib/load-dotenv.sh" && load_dotenv HANDOVER_DIR; printf '%s' "${HANDOVER_DIR-}"); }
mkdir -p "$tmp/empty-conf"
got="$(HIMMEL_CONFIG_DIR="$tmp/empty-conf" hd_load 2>/dev/null)"
if [ -z "$got" ]; then pass "load_dotenv with a throwaway HIMMEL_CONFIG_DIR serves no HANDOVER_DIR"; else fail "load_dotenv with a throwaway HIMMEL_CONFIG_DIR still served HANDOVER_DIR=$got"; fi
if [ "$(hd_load 2>/dev/null)" = "$tmp/inh-hd" ]; then pass "control: with no HIMMEL_CONFIG_DIR load_dotenv serves HANDOVER_DIR from \$HOME/.himmel/himmel.conf"; else fail "control: load_dotenv did not serve the seeded HANDOVER_DIR from \$HOME/.himmel"; fi

[ "$failures" -eq 0 ]
