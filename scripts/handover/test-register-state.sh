#!/usr/bin/env bash
# test-register-state.sh — register-state.sh, the single writer of
# registry.json. Hermetic: every path under a mktemp dir, registry via --registry.
set -euo pipefail

fail() { echo "FAIL: $1" >&2; exit 1; }
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/register-state.sh"
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
reg="$tmp/reg/registry.json"
state="$tmp/state"; mkdir -p "$state"
mkrepo() { mkdir -p "$tmp/$1"; git init -q "$tmp/$1"; }
mkrepo alpha; mkrepo beta; mkdir -p "$tmp/x"; mkrepo x/alpha

run() { set +e; out=$(bash "$script" "$@" 2>&1); rc=$?; set -e; }
nrepos() { node -e 'process.stdout.write(String(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).repos).length))' "$reg"; }

run --check --repo-path "$tmp/alpha" --registry "$reg"
[ "$rc" -eq 3 ] || fail "check on missing registry should be rc 3 (got $rc: $out)"

run --repo-path "$tmp/alpha" --state-host "$state" --user tester --registry "$reg" --init
[ "$rc" -eq 0 ] || fail "init+register rc=$rc: $out"
[ -f "$state/tester/counter.md" ] && [ -f "$state/tester/status.md" ] && [ -d "$state/tester/_templates" ] \
  || fail "init did not bootstrap the state dir"
[ "$(nrepos)" = "1" ] || fail "expected 1 entry"
run --check --repo-path "$tmp/alpha" --registry "$reg"
[ "$rc" -eq 0 ] || fail "check after register should be rc 0 (got $rc)"
echo "ok: init registers and bootstraps"

run --repo-path "$tmp/alpha" --state-host "$state" --user tester --registry "$reg" --init
[ "$rc" -eq 0 ] && [ "$(nrepos)" = "1" ] || fail "re-run must be an idempotent no-op (rc=$rc: $out)"
echo "ok: idempotent"

run --repo-path "$tmp/x/alpha" --state-host "$state" --user tester --registry "$reg" --name alpha
[ "$rc" -eq 2 ] || fail "name collision for a different path must be rc 2 (got $rc: $out)"
run --repo-path "$tmp/x/alpha" --state-host "$state" --user tester --registry "$reg" --name alpha-two
[ "$rc" -eq 2 ] || fail "bucket collision must be rc 2 (got $rc: $out)"
case "$out" in *bucket_name*) ;; *) fail "bucket collision message should name bucket_name: $out" ;; esac
[ "$(nrepos)" = "1" ] || fail "a refused write must leave the registry untouched"
echo "ok: collisions refused, registry untouched"

state2="$tmp/state2"; mkdir -p "$state2/tester"; echo "# x" > "$state2/tester/item.md"
run --repo-path "$tmp/beta" --state-host "$state2" --user tester --registry "$reg" --init
[ "$rc" -eq 2 ] || fail "--init over existing .md state must be refused (got $rc: $out)"
run --repo-path "$tmp/beta" --state-host "$state2" --user tester --registry "$reg" --init-if-empty
[ "$rc" -eq 0 ] && [ ! -e "$state2/tester/counter.md" ] || fail "--init-if-empty must register without bootstrapping non-empty state (rc=$rc: $out)"
echo "ok: --init refuses non-empty state; --init-if-empty registers it as-is"

echo "PASS"
