#!/usr/bin/env bash
# multi-accounts-e2e.sh -- VM e2e for the config UI's Multi accounts section (GET/POST /api/api-roles).
#
# Host mode (default): runs the guest half on a test VM through guest-exec.sh.
#   bash scripts/vm/multi-accounts-e2e.sh <vm>
# The guest must already hold this checkout (vmsdk.py <vm> clone <ref>, run from the primary checkout).
#
# Guest mode (--guest): starts the real config-ui server six times, once per role-map state, each on a
# throwaway HOME and credit config, and asserts what the route answers, what auto routing reads
# (api-roles.mjs accounts) and what the served page carries. Fourteen assertions in all, including the mode 600 check.
# It never touches the guest's real ~/.himmel.
#
# Exit: 0 all passed; 1 an assertion failed; 2 bad inputs.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd -- "$HERE/../.." && pwd)"

if [ "${1:-}" != "--guest" ]; then
  [ "$#" -eq 1 ] || { echo "usage: multi-accounts-e2e.sh <vm> | --guest" >&2; exit 2; }
  exec bash "$REPO/scripts/vm/guest-exec.sh" "$1" --timeout 300 -- "cd ~/himmel && bash scripts/vm/multi-accounts-e2e.sh --guest"
fi

command -v bun >/dev/null 2>&1 || export PATH="$HOME/.bun/bin:$PATH"
for tool in bun node curl; do command -v "$tool" >/dev/null 2>&1 || { echo "multi-accounts-e2e: $tool missing on this host" >&2; exit 2; }; done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/multi-accounts-e2e.XXXXXX")" || exit 2 # prim-ok: runs only on the Linux test VM
SERVER_PID=""
stop_server() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; }
trap 'stop_server; rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
check() { # check <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS + 1)); echo "PASS $1"; else FAIL=$((FAIL + 1)); echo "FAIL $1 (expected '$2', got '$3')"; fi
}
field() { node -e 'const j=JSON.parse(require("fs").readFileSync(0,"utf8"));const v=process.argv[1].split(".").reduce((o,k)=>o==null?o:o[k],j);console.log(typeof v==="object"?JSON.stringify(v):String(v))' "$1"; }

# state_up <name> <config-json|ok>: a fresh HOME and credit dir, the server up; sets BASE TOKEN CREDIT ENVV
state_up() {
  local dir="$WORK/$1"; mkdir -p "$dir/home" "$dir/credit" "$dir/project"
  CREDIT="$dir/credit"
  if [ "$2" = ok ]; then
    printf '{"version":1,"ledger_path":"%s/ledger.json","accounts":{"A":{"organization_id":"org-A","cycle_id":"cycle-A","cap_usd":"40.00"},"B":{"organization_id":"org-B","cycle_id":"cycle-B","cap_usd":"40.00"}}}' "$CREDIT" > "$CREDIT/config.json"
  else
    printf '%s' "$2" > "$CREDIT/config.json"
  fi
  export HOME="$dir/home" HIMMEL_API_CREDIT_CONFIG="$CREDIT/config.json" HIMMEL_API_CREDIT_SNAPSHOT="$CREDIT/snapshot.json" HIMMEL_SECRETS_KEYRING=off
  ( cd "$REPO/scripts/config-ui" && exec bun server.ts --port 0 ) > "$dir/server.log" 2>&1 &
  SERVER_PID=$!
  local url=""
  for _ in $(seq 1 60); do url="$(grep -o 'http://127.0.0.1:[0-9]*/[^ ]*#t=[0-9a-f]*' "$dir/server.log" | head -1)"; [ -n "$url" ] && break; sleep 0.5; done
  [ -n "$url" ] || { echo "multi-accounts-e2e: server for state '$1' did not start" >&2; cat "$dir/server.log" >&2; exit 1; }
  BASE="${url%%/#t=*}"; BASE="${BASE%%/agui*}"; TOKEN="${url##*#t=}"
}
api_get() { curl -s -H "x-himmel-token: $TOKEN" "$BASE/api/api-roles"; }
routed() { # a failed CLI prints cli-failed, so an empty answer is only ever a real empty answer
  local out
  out="$(node "$REPO/scripts/lib/api-roles.mjs" accounts "$1" 2>/dev/null)" || { printf 'cli-failed'; return 0; }
  printf '%s' "$out"
}

# 1. absent: no roles.json
state_up absent ok
check "absent: role map state" absent "$(api_get | field roleMap.state)"
check "absent: judge routing is the 525 default (no accounts)" "" "$(routed judge)"
PAGE="$(curl -s -H "x-himmel-token: $TOKEN" "$BASE/setup.js")"
check "absent: the served page carries the Multi accounts section" yes "$(grep -q '<h3>Multi accounts</h3>' <<<"$PAGE" && echo yes || echo no)"
stop_server

# 2. valid after a UI save
state_up valid ok
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "x-himmel-token: $TOKEN" -H 'content-type: application/json' -H "origin: $BASE" -d '{"judge":["B"],"graphify":["A","B"]}' "$BASE/api/api-roles")"
check "valid: the save answers 200" 200 "$code"
check "valid: the route reads the saved judge role" '["B"]' "$(api_get | field roleMap.roles.judge)"
check "valid: auto routing reads the saved graphify accounts" "A,B" "$(routed graphify)"
check "valid: roles.json is mode 600" 600 "$(stat -c %a "$CREDIT/roles.json")" # gnu-ok: runs only on the Linux test VM
stop_server

# 3. partial: a hand-written map with one unknown account
state_up partial ok
printf '{"version":1,"roles":{"judge":["D"],"graphify":["A"]}}' > "$CREDIT/roles.json"
check "partial: role map state" partial "$(api_get | field roleMap.state)"
check "partial: auto routing still reads the valid entry" "A" "$(routed graphify)"
stop_server

# 4. invalid: a truncated file
state_up invalid ok
printf '{"version":1,"roles":{"judge"' > "$CREDIT/roles.json"
check "invalid: role map state" invalid "$(api_get | field roleMap.state)"
check "invalid: the whole file is ignored" "" "$(routed judge)"
stop_server

# 5. graphify mapped to C, which has no configured account
state_up c-only ok
printf '{"version":1,"roles":{"graphify":["C"]}}' > "$CREDIT/roles.json"
check "no C row: the route warns no-configured-account:graphify" '["no-configured-account:graphify"]' "$(api_get | field warnings)"
check "no C row: account C reads not configured" "not configured" "$(api_get | field rows.2.tag)"
stop_server

# 6. broken account config
state_up broken-config '{"version":1,"accounts":'
check "broken config.json: the route reports the account config unreadable" unreadable "$(api_get | field accounts)"
stop_server

echo "multi-accounts-e2e: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
