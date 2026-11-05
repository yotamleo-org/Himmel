#!/usr/bin/env bash
# test-llm-backend.sh — Hermetic: pins the shared api|cli backend resolver (scripts/lib/llm-backend.sh).
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/scripts/lib/llm-backend.sh"
PASS=0; FAIL=0
check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }

[ -r "$LIB" ] || { echo "FAIL - $LIB missing"; echo "pass=0 fail=1"; exit 1; }
# shellcheck source=llm-backend.sh
# shellcheck disable=SC1091
. "$LIB"

res() { local out rc=0; out="$(llm_backend_resolve "$1" 2>/dev/null)" || rc=$?; echo "$rc|$out"; }
check "claude-cli passes through" "0|claude-cli" "$(res claude-cli)"
check "claude-api passes through" "0|claude-api" "$(res claude-api)"
check "ollama passes through" "0|ollama" "$(res ollama)"
check "cli alias" "0|claude-cli" "$(res cli)"
check "api alias" "0|claude-api" "$(res api)"
check "unknown refuses" "1|" "$(res bogus)"
check "empty refuses" "1|" "$(res "")"
check "case matters (API refuses)" "1|" "$(res API)"

ready() { ( HIMMEL_API_LANE="$1"; HIMMEL_API_ACCOUNT="$2"; export HIMMEL_API_LANE HIMMEL_API_ACCOUNT; llm_backend_api_ready >/dev/null 2>&1; echo $? ); }
check "api ready: lane on + account" "0" "$(ready on A)"
check "api not ready: lane off" "1" "$(ready off A)"
check "api not ready: no account" "1" "$(ready on "")"
check "api not ready: account auto (decision 525)" "1" "$(ready on auto)"
check "api ready: account C" "0" "$(ready on C)"
check "api not ready: account D" "1" "$(ready on D)"

ready_graph() { ( HIMMEL_API_LANE="$1"; HIMMEL_API_ACCOUNT="$2"; export HIMMEL_API_LANE HIMMEL_API_ACCOUNT; llm_backend_api_ready_graph >/dev/null 2>&1; echo $? ); }
check "graph ready: account auto" "0" "$(ready_graph on auto)"
check "graph ready: account B" "0" "$(ready_graph on B)"
check "graph not ready: lane off" "1" "$(ready_graph off auto)"
check "graph not ready: no account" "1" "$(ready_graph on "")"
check "graph not ready: account D" "1" "$(ready_graph on D)"

# the bash account set equals the real ACCOUNTS of scripts/lib/api-credit-state.mjs
mjs_accounts="$(node -e "import('$REPO/scripts/lib/api-credit-state.mjs').then((m) => console.log([...m.ACCOUNTS].sort().join(',')))" 2>/dev/null)"
bash_accounts=""
for a in A B C D E auto a "" ; do
    if llm_backend_api_account_ok "$a" 2>/dev/null; then bash_accounts="${bash_accounts:+$bash_accounts,}$a"; fi
done
check "account set equals ACCOUNTS of api-credit-state.mjs" "$mjs_accounts" "$bash_accounts"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
