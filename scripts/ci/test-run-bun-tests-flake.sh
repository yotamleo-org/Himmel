#!/usr/bin/env bash
# A lost retry, false-green double failure, or missing case/cost metadata breaks these rows.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/bun-flake.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" || exit 1
export HOME="$tmp/home"
export SUITE_FLAKE_REPO_ID=fixture-repo GITHUB_RUN_ID=424242 GITHUB_ACTIONS=true
export SUITE_FLAKE_LEDGER="$tmp/ledger.jsonl" GITHUB_STEP_SUMMARY="$tmp/summary"
export BUN_FLAKE_COUNT="$tmp/count"
cat > "$tmp/service-mode.test.ts" <<'TS'
import { test, expect } from "bun:test";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
const path = process.env.BUN_FLAKE_COUNT!;
const count = existsSync(path) ? Number(readFileSync(path, "utf8")) + 1 : 1;
writeFileSync(path, String(count));
test("service mode starts", () => expect(count).toBeGreaterThan(Number(process.env.FAIL_RUNS)));
TS
run_case() {
  rm -f "$tmp/count" "$tmp/ledger.jsonl" "$tmp/summary"
  export FAIL_RUNS="$1"
  rc=0
  if [ -f "$ROOT/scripts/ci/run-bun-tests.sh" ]; then
    bash "$ROOT/scripts/ci/run-bun-tests.sh" scripts/config-ui "$tmp/service-mode.test.ts" > "$tmp/output" 2>&1 || rc=$?
  else
    bun test "$tmp/service-mode.test.ts" > "$tmp/output" 2>&1 || rc=$?
  fi
}
run_case 1
if [ "$rc" -ne 0 ] || [ "$(<"$tmp/count")" != 2 ] || [ ! -s "$tmp/ledger.jsonl" ]; then
  printf 'FAIL: bun fail-then-pass must retry once and record FLAKE (rc=%s)\n' "$rc"
  exit 1
fi
jq -e 'select(.v == 1 and .kind == "flake" and .source == "run-bun-tests" and .suite == "scripts/config-ui" and .repo == "fixture-repo" and .run == "424242" and .rc == 1 and (.host | length > 0) and (.sha | length == 40) and (.ts > 0) and (.retry_elapsed_ms >= 0) and (.case | contains("service-mode.test.ts")))' "$tmp/ledger.jsonl" > /dev/null || exit 1
grep -q '\[FLAKE\]' "$tmp/output" || exit 1
grep -q '::warning title=FLAKE::' "$tmp/output" || exit 1
grep -q 'scripts/config-ui' "$tmp/summary" || exit 1
printf 'PASS: bun retry records shared envelope, service-mode case, cost, warning and summary\n'
run_case 2
[ "$rc" -ne 0 ] && [ "$(<"$tmp/count")" = 2 ] && [ ! -s "$tmp/ledger.jsonl" ] || exit 1
grep -q '\[FAIL\]' "$tmp/output" || exit 1
printf 'PASS: double failure stays FAIL with no flake row\n'
run_case 0
[ "$rc" -eq 0 ] && [ "$(<"$tmp/count")" = 1 ] && [ ! -s "$tmp/ledger.jsonl" ] || exit 1
printf 'PASS: first-pass success runs once without a flake row\n'
printf '3 passed, 0 failed\n'
