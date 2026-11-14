#!/usr/bin/env bash
# selector: tree-scan
# shellcheck disable=SC2016  # single-quoted needles are literal ci.yml text
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRITER="$ROOT/scripts/ci/js-suite-manifest.mjs"
REPORTER="$ROOT/scripts/ci/node-suite-reporter.mjs"
CAPTURE="$ROOT/scripts/ci/fixtures/js-suite-manifest/vitest-5.1.0-report.json"
CI_YML="${CI_YML:-$ROOT/.github/workflows/ci.yml}"
fails=0
ok()   { echo "ok - $1"; }
bad()  { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
skip() { echo "SKIP - $1"; }

unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_CONFIG_PARAMETERS

T=$(mktemp -d "${TMPDIR:-/tmp}/js-suite-manifest.XXXXXX") || { echo "cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
REPO="$T/repo"
if ! { mkdir -p "$REPO" && git -C "$REPO" init -q && git -C "$REPO" config user.email t@t && git -C "$REPO" config user.name t; }; then
  echo "cannot create the fixture repo" >&2; exit 1
fi

put() { mkdir -p "$REPO/$(dirname "$1")" && printf '%s\n' "$2" > "$REPO/$1"; }
commit_all() { git -C "$REPO" add -A && git -C "$REPO" commit -qm fixtures; }

write_manifest() {
  local out="$1"; shift
  wrc=0
  (cd "$REPO" && node "$WRITER" --out "$out" "$@") > "$out.stdout" 2>&1 || wrc=$?
}

same_lines() {
  local name="$1" file="$2"; shift 2
  local want got
  want=$(printf '%s\n' "$@" | sed '/^$/d' | LC_ALL=C sort)
  got=$( { [ -f "$file" ] && cat "$file"; } | sed '/^$/d' | LC_ALL=C sort)
  if [ "$want" = "$got" ]; then ok "$name"
  else bad "$name: want [$(printf '%s' "$want" | tr '\n' ';')] got [$(printf '%s' "$got" | tr '\n' ';')]"; fi
}

one_notice() {
  local n
  n=$(grep -c '^::notice title=js-suite-mixed::' "$2" 2>/dev/null) || n=0
  if [ "$n" = 1 ] && grep -qxF "::notice title=js-suite-mixed::$3" "$2"; then ok "$1"
  else bad "$1: want one js-suite-mixed notice for $3, got $n"; fi
}

suite_re=$(sed -n "s/^suite_re='\(.*\)'$/\1/p" "$ROOT/scripts/cr/impacted-suites.sh")
if [ -z "$suite_re" ]; then
  bad "M0: cannot read suite_re from scripts/cr/impacted-suites.sh"
else
  hits=$(git -C "$ROOT" ls-files scripts/ci/fixtures | grep -E "$suite_re")
  if [ -z "$hits" ]; then ok "M0: no tracked file under scripts/ci/fixtures matches suite_re"
  else bad "M0: tracked fixture matches suite_re: $hits"; fi
fi

put node/pass.test.mjs "import test from 'node:test'; test('a', () => {});"
put node/fail.test.mjs "import test from 'node:test'; test('a', () => { throw new Error('x'); });"
put node/allskip.test.mjs "import test from 'node:test'; test.skip('a', () => {}); test('b', { skip: true }, () => {});"
put node/crash.test.mjs "throw new Error('boom at load');"
put node/empty.test.mjs "// no tests"
put node/describe-skip.test.mjs "import { describe, it } from 'node:test'; describe('d', () => { it.skip('x', () => {}); it('y', { skip: true }, () => {}); });"
put node/todo.test.mjs "import test from 'node:test'; test.todo('a'); test('b', { todo: true }, () => { throw new Error('x'); });"
put node/parent.test.mjs "import test from 'node:test'; test('p', async (t) => { await t.test('c', { skip: true }, () => {}); });"
put node/mixed.test.mjs "import test from 'node:test'; test('a', () => {}); test.skip('b', () => {});"
put bun/pass.test.ts "import { test, expect } from 'bun:test'; test('a', () => { expect(1).toBe(1); });"
put bun/fail.test.ts "import { test, expect, describe } from 'bun:test'; test('ok', () => {}); describe('d', () => { test('bad', () => { expect(1).toBe(2); }); });"
put bun/allskip.test.ts "import { test } from 'bun:test'; test.skip('a', () => {}); test.skip('b', () => {});"
put bun/crash.test.ts "throw new Error('boom at load');"
put bun/empty.test.ts "export {};"
put bun/describe-skip.test.ts "import { describe, test } from 'bun:test'; describe('o', () => { describe('i', () => { test.skip('a', () => {}); }); });"
put bun/todo.test.ts "import { test } from 'bun:test'; test.todo('a');"
put bun/mixed.test.ts "import { describe, test } from 'bun:test'; describe('o', () => { describe('i', () => { test('a', () => {}); test.skip('b', () => {}); }); });"
put bunflaky/flaky.test.ts "import { test } from 'bun:test'; import { existsSync, writeFileSync } from 'node:fs'; test('flaky', () => { const m = process.env.FLAKY_MARKER as string; if (!existsSync(m)) { writeFileSync(m, '1'); throw new Error('first attempt'); } });"
put bunflaky/always.test.ts "import { test, expect } from 'bun:test'; test('always', () => { expect(1).toBe(2); });"
for f in passed failed skipped crash mixed skipif-todo; do put "vitest-capture/$f.test.ts" "// fixture named by the captured report"; done
commit_all || bad "fixture repo commit failed"

node_major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null) || node_major=0
if [ "${node_major:-0}" -lt 22 ]; then
  bad "M1: node ${node_major} is below 22, the lowest version CI runs the reporter on"
else
  (cd "$REPO" && node --test --test-reporter="$REPORTER" --test-reporter-destination="$T/node.jsonl" \
     --test-reporter=spec --test-reporter-destination=stdout "node/*.test.mjs") > "$T/node.log" 2>&1
  if grep -q '"name":"node/empty.test.mjs"\|"name":"empty.test.mjs"' "$T/node.jsonl" 2>/dev/null; then
    ok "M1: the empty file's event carries name equal to its file"
  else bad "M1: no event names the empty file by its file name"; fi
  write_manifest "$T/m1.txt" --report node "$T/node.jsonl" .
  if [ "$wrc" = 0 ]; then ok "M1: writer exit 0"; else bad "M1: writer exit $wrc: $(head -3 "$T/m1.txt.stdout")"; fi
  same_lines "M1: node pass/fail/all-skipped/crash/empty, describe-all-skipped, todo-only, all-skipped parent, mixed" "$T/m1.txt" \
    "ran 0 node/pass.test.mjs" "ran 1 node/fail.test.mjs" "skip node/allskip.test.mjs" "ran 1 node/crash.test.mjs" \
    "skip node/describe-skip.test.mjs" "skip node/todo.test.mjs" "skip node/parent.test.mjs" "ran 0 node/mixed.test.mjs"
  one_notice "M9 (node): mixed file reads ran 0 with one js-suite-mixed notice" "$T/m1.txt.stdout" node/mixed.test.mjs
fi

if command -v bun >/dev/null 2>&1; then
  (cd "$REPO/bun" && bun test --reporter=junit --reporter-outfile="$T/bun.xml" .) > "$T/bun.log" 2>&1
  write_manifest "$T/m2.txt" --report bun "$T/bun.xml" bun
  if [ "$wrc" = 0 ]; then ok "M2: writer exit 0"; else bad "M2: writer exit $wrc"; fi
  same_lines "M2: bun pass/fail/all-skipped, nested describe, crash and empty give no line, describe-all-skipped, todo-only, mixed" "$T/m2.txt" \
    "ran 0 bun/pass.test.ts" "ran 1 bun/fail.test.ts" "skip bun/allskip.test.ts" \
    "skip bun/describe-skip.test.ts" "skip bun/todo.test.ts" "ran 0 bun/mixed.test.ts"
  one_notice "M9 (bun): mixed file reads ran 0 with one js-suite-mixed notice" "$T/m2.txt.stdout" bun/mixed.test.ts
elif [ "${HIMMEL_REQUIRE_BUN_TEST:-}" = 1 ]; then
  bad "M2: bun is missing and HIMMEL_REQUIRE_BUN_TEST=1"
else
  skip "M2: bun not installed"
fi

if [ -r "$CAPTURE" ]; then
  sed "s|/CAPTURE_ROOT/vitest-capture|$REPO/vitest-capture|g" "$CAPTURE" > "$T/vitest.json"
  write_manifest "$T/m3.txt" --report vitest "$T/vitest.json" vitest-capture
  if [ "$wrc" = 0 ]; then ok "M3: writer exit 0"; else bad "M3: writer exit $wrc"; fi
  same_lines "M3: vitest passed/failed/all-skipped/load-crash, skipIf+todo, mixed" "$T/m3.txt" \
    "ran 0 vitest-capture/passed.test.ts" "ran 1 vitest-capture/failed.test.ts" "skip vitest-capture/skipped.test.ts" \
    "ran 1 vitest-capture/crash.test.ts" "skip vitest-capture/skipif-todo.test.ts" "ran 0 vitest-capture/mixed.test.ts"
  one_notice "M9 (vitest): mixed file reads ran 0 with one js-suite-mixed notice" "$T/m3.txt.stdout" vitest-capture/mixed.test.ts
  write_manifest "$T/m3b.txt" --report vitest "$CAPTURE" vitest-capture
  same_lines "M3: the placeholder report names no tracked path, so no line" "$T/m3b.txt"
  if bash "$ROOT/scripts/guardrails/leak-classes.sh" --files scripts/ci/fixtures/js-suite-manifest/vitest-5.1.0-report.json > "$T/leak.log" 2>&1; then
    ok "M3: leak-classes.sh passes on the tracked capture"
  else bad "M3: leak-classes.sh refuses the capture: $(head -3 "$T/leak.log")"; fi
else
  bad "M3: the vitest capture is missing: $CAPTURE"
fi

cat > "$T/m4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="bun test" tests="3" failures="0" skipped="0">
  <testsuite name="pass.test.ts" file="pass.test.ts" tests="1" failures="0" skipped="0" />
  <testsuite name="untracked.test.ts" file="untracked.test.ts" tests="1" failures="0" skipped="0" />
  <testsuite name="outside.test.ts" file="../../outside.test.ts" tests="1" failures="0" skipped="0" />
</testsuites>
EOF
printf '{"testResults":[{"name":"%s","status":"passed","assertionResults":[{"status":"passed"}]},{"name":"%s","status":"passed","assertionResults":[{"status":"passed"}]}]}\n' \
  "$REPO/vitest-capture/passed.test.ts" "$REPO/vitest-capture/not-tracked.test.ts" > "$T/m4.json"
write_manifest "$T/m4.txt" --report bun "$T/m4.xml" bun --report vitest "$T/m4.json" .
same_lines "M4: a relative path under its cwd and an absolute path become repo-relative; untracked and outside paths drop" "$T/m4.txt" \
  "ran 0 bun/pass.test.ts" "ran 0 vitest-capture/passed.test.ts"

write_manifest "$T/m5.txt" --report node "$T/no-such-report.jsonl" .
if [ "$wrc" = 0 ] && grep -q '^::warning' "$T/m5.txt.stdout"; then ok "M5: a missing report exits 0 with a ::warning"
else bad "M5: missing report gave rc=$wrc, output: $(head -2 "$T/m5.txt.stdout")"; fi
same_lines "M5: a missing report gives no lines" "$T/m5.txt"

printf '{"file":"%s","name":"a","nesting":0,"fail":false,"kind":"test"}\n' "$REPO/node/pass.test.mjs" > "$T/m6a.jsonl"
printf '{"file":"%s","name":"a","nesting":0,"fail":true,"kind":"test"}\n' "$REPO/node/pass.test.mjs" > "$T/m6b.jsonl"
write_manifest "$T/m6.txt" --report node "$T/m6a.jsonl" . --report node "$T/m6b.jsonl" .
same_lines "M6: two reports naming one file, one failing, read ran 1" "$T/m6.txt" "ran 1 node/pass.test.mjs"

if command -v bun >/dev/null 2>&1; then
  m7() {
    (cd "$REPO" && env -u GITHUB_ACTIONS -u GITHUB_STEP_SUMMARY \
      SUITE_FLAKE_LEDGER="$T/flake-ledger.jsonl" SUITE_FLAKE_REPO_ID=js-suite-manifest-fixture FLAKY_MARKER="$T/flaky.marker" \
      bash "$ROOT/scripts/ci/run-bun-tests.sh" "$1" "$1" --reporter=junit --reporter-outfile="$2") > "$T/m7.log" 2>&1
  }
  rc=0; m7 bunflaky/flaky.test.ts "$T/m7a.xml" || rc=$?
  if [ "$rc" = 0 ]; then ok "M7: a file that fails then passes on the retry: wrapper exits 0"; else bad "M7: flaky wrapper exit $rc: $(tail -3 "$T/m7.log")"; fi
  write_manifest "$T/m7a.txt" --report bun "$T/m7a.xml" .
  same_lines "M7: the retry's report replaces the first, so the flaky file reads ran 0" "$T/m7a.txt" "ran 0 bunflaky/flaky.test.ts"
  rc=0; m7 bunflaky/always.test.ts "$T/m7b.xml" || rc=$?
  if [ "$rc" != 0 ]; then ok "M7: an always-failing file: wrapper exits nonzero"; else bad "M7: always-failing wrapper exit 0"; fi
  write_manifest "$T/m7b.txt" --report bun "$T/m7b.xml" .
  same_lines "M7: an always-failing file reads ran 1" "$T/m7b.txt" "ran 1 bunflaky/always.test.ts"
elif [ "${HIMMEL_REQUIRE_BUN_TEST:-}" = 1 ]; then
  bad "M7: bun is missing and HIMMEL_REQUIRE_BUN_TEST=1"
else
  skip "M7: bun not installed"
fi

cat > "$T/m8.mjs" <<EOF
import reporter from '$REPORTER';
async function* source() {
  yield { type: 'test:pass', data: null };
  yield { type: 'test:unknown-kind', data: {} };
  yield 'not an event';
  yield { type: 'test:fail', get data() { throw new Error('unreadable'); } };
  yield { type: 'test:pass', data: { file: '/x/a.test.mjs', name: 't', nesting: 0, details: { type: 'test' } } };
}
let out = '';
for await (const chunk of reporter(source())) out += chunk;
process.stdout.write(out);
EOF
rc=0; node "$T/m8.mjs" > "$T/m8.out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && [ "$(grep -c . "$T/m8.out")" = 1 ] && grep -q '"file":"/x/a.test.mjs"' "$T/m8.out"; then
  ok "M8: malformed and unknown events write nothing, never throw, and the readable event keeps its line"
else bad "M8: rc=$rc output: $(head -3 "$T/m8.out")"; fi

stripped="$(sed -e '/^[[:space:]]*#/d' -e 's/[[:space:]][[:space:]]*#.*$//' "$CI_YML")"
job_block() { awk -v j="$1" '$0 == "  " j ":" {f=1; next} f && /^  [a-zA-Z_-]+:/ {f=0} f' <<< "$stripped"; }
step_of() {
  job_block "$1" | awk -v s="$2" '
    /^      - / { if (hit) exit; buf = "" }
    { buf = buf $0 "\n"; if (index($0, s)) hit = 1 }
    END { if (hit) printf "%s", buf }'
}
unquote() { sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//"; }
nodecond="!(needs.plan.result == 'success' && needs.plan.outputs.run_node_suites == 'false')"
for job in lanes-and-trust-suites bun-suites node-suites; do
  blk=$(job_block "$job")
  if grep -qF 'mkdir -p "$RUNNER_TEMP/js-suite-report"' <<< "$blk"; then ok "W1 $job: has the report-dir mkdir step"
  else bad "W1 $job: no mkdir -p \"\$RUNNER_TEMP/js-suite-report\" step"; fi
  wstep=$(step_of "$job" 'scripts/ci/js-suite-manifest.mjs')
  if grep -qF '|| echo "::warning title=js-suite-manifest::' <<< "$wstep" && grep -qF '!cancelled()' <<< "$wstep"; then
    ok "W1 $job: writer step runs if !cancelled() and ends in || echo ::warning"
  else bad "W1 $job: writer step missing, or lacks !cancelled() / || echo ::warning"; fi
  ustep=$(step_of "$job" 'name: js-suite-manifest-')
  if grep -q 'actions/upload-artifact@' <<< "$ustep" && grep -qE '^[[:space:]]+overwrite: true$' <<< "$ustep" && grep -qF '!cancelled()' <<< "$ustep"; then
    ok "W1 $job: upload step with overwrite: true, if !cancelled()"
  else bad "W1 $job: no js-suite-manifest upload with overwrite: true and !cancelled()"; fi
  grep -q 'continue-on-error' <<< "$wstep$ustep" && bad "W1 $job: a manifest step carries continue-on-error"
  dests=$(grep -oE -- '(--test-reporter-destination=|--reporter-outfile=|--outputFile\.json=)("[^"]*"|[^ ]+)' <<< "$blk" | sed -E 's/^[^=]*=//' | unquote)
  hookdir=$(grep -oE 'HOOK_LIB_TEST_REPORT_DIR=("[^"]*"|[^ ]+)' <<< "$blk" | head -1 | sed 's/^[^=]*=//' | unquote)
  if [ -n "$hookdir" ]; then dests=$(printf '%s\n%s/hooks.jsonl\n%s/lib.jsonl\n' "$dests" "$hookdir" "$hookdir"); fi
  reports=$(grep -oE -- '--report [a-z]+ ("[^"]*"|[^ ]+)' <<< "$wstep" | awk '{ $1 = ""; $2 = ""; sub(/^  /, ""); print }' | unquote)
  if [ -z "$reports" ]; then bad "W1 $job: the writer names no --report"; fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    if grep -qxF -- "$r" <<< "$dests"; then ok "W1 $job: --report $r is written by a test step"
    else bad "W1 $job: --report $r is not a destination of any test step in the job"; fi
  done <<< "$reports"
done
ldests=$(job_block lanes-and-trust-suites | grep -oE -- '--test-reporter-destination=("[^"]*"|[^ ]+)' | sed 's/^[^=]*=//' | unquote | grep -vx stdout)
if [ -n "$ldests" ] && [ -z "$(sort <<< "$ldests" | uniq -d)" ]; then ok "W1 lanes-and-trust-suites: node --test destinations are pairwise distinct"
else bad "W1 lanes-and-trust-suites: node --test destinations missing or shared: $(sort <<< "$ldests" | uniq -d | tr '\n' ' ')"; fi
for s in 'mkdir -p "$RUNNER_TEMP/js-suite-report"' 'scripts/ci/js-suite-manifest.mjs' 'name: js-suite-manifest-'; do
  st=$(step_of node-suites "$s")
  if grep -qF "matrix.pkg != 'himmel-bus'" <<< "$st" && grep -qF "$nodecond" <<< "$st"; then
    ok "W1 node-suites: the step holding '$s' carries the himmel-bus and run_node_suites conditions"
  else bad "W1 node-suites: the step holding '$s' lacks matrix.pkg != 'himmel-bus' or the run_node_suites condition"; fi
done
tstep=$(step_of node-suites 'outputFile.json=')
if grep -qF "matrix.pkg != 'himmel-bus'" <<< "$tstep" && grep -qF 'npm test -- ' <<< "$tstep"; then ok "W1 node-suites: the reporting npm test step excludes himmel-bus"
else bad "W1 node-suites: no npm test step with --outputFile.json= gated on matrix.pkg != 'himmel-bus'"; fi
shard=$(job_block shell-unit-shard)
if grep -qF 'echo "HIMMEL_REQUIRE_BUN_TEST=1" >> "$GITHUB_ENV"' <<< "$shard"; then ok "W1 shell-unit-shard: exports HIMMEL_REQUIRE_BUN_TEST=1 through GITHUB_ENV"
else bad "W1 shell-unit-shard: does not export HIMMEL_REQUIRE_BUN_TEST=1 through GITHUB_ENV"; fi
nstep=$(step_of shell-unit-shard 'actions/setup-node@')
ncond=$(sed -n 's/^[[:space:]]*if:[[:space:]]*//p' <<< "$nstep")
if grep -qE "node-version: '22\.23\.4'" <<< "$nstep" && [ "$ncond" = '${{ !job.container.id }}' ]; then
  ok "W1 shell-unit-shard: setup-node 22.23.4 whose only condition is !job.container.id"
else bad "W1 shell-unit-shard: no setup-node 22.23.4 step gated only on !job.container.id (if: '$ncond')"; fi

trust_re=$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/scripts/ci/ci-trust-paths.txt")
if grep -qE -f <(printf '%s\n' "$trust_re") <<< "scripts/hooks/check-hook-lib-suites.sh"; then
  ok "W3: scripts/hooks/check-hook-lib-suites.sh matches scripts/ci/ci-trust-paths.txt"
else bad "W3: scripts/hooks/check-hook-lib-suites.sh matches no pattern of scripts/ci/ci-trust-paths.txt"; fi

if [ "$fails" -eq 0 ]; then echo "test-js-suite-manifest: all rows passed"; exit 0; fi
echo "test-js-suite-manifest: $fails row(s) FAILED" >&2
exit 1
