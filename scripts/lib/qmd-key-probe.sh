#!/usr/bin/env bash
# qmd-key-probe.sh — one real embedding call against the qmd daemon; fails loud
# when the daemon runs without its OpenRouter key.
#
# Run it:   bash qmd-key-probe.sh
#   exit 0  the daemon embedded a probe query (key present)
#   exit 1  the provider answered 401 (daemon launched without QMD_OPENAI_API_KEY)
#   exit 2  anything else: nothing listening, deadline, bearer-token refusal,
#           unreadable reply, no curl/jq
# A bank-preflight style caller runs `bash scripts/lib/qmd-key-probe.sh` and
# treats a non-zero rc as "retrieval is down"; stderr carries the one-line reason.
#
# Env: QMD_MCP_URL (default http://localhost:8181/mcp), QMD_KEY_PROBE_TIMEOUT
# (whole seconds, default 90 — live vec queries took 48-60 s under fleet load on 2026-10-16),
# QMD_HTTP_AUTH_FILE (bearer-token file, as qmd-auth-headers.sh reads it).
#
# The bearer token goes to curl as a config on stdin, never argv. The daemon's
# reply is classified, never printed: every message here is a fixed string, so
# neither the token nor the provider key (which only the daemon holds) can reach
# the output.
#
# Platform guard (gitbash-only): POSIX bash 3.2+; curl and jq required.

set -u

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qmd-bounded.sh
# shellcheck disable=SC1091
. "$LIB_DIR/qmd-bounded.sh"

url="${QMD_MCP_URL:-http://localhost:8181/mcp}"
secs="${QMD_KEY_PROBE_TIMEOUT:-90}"
case "$secs" in '' | *[!0-9]* | 0) secs=90 ;; esac

fail() { echo "qmd-key-probe: $2" >&2; exit "$1"; }

command -v curl >/dev/null 2>&1 || fail 2 "curl not found"
command -v jq >/dev/null 2>&1 || fail 2 "jq not found"

payload='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"searches":[{"type":"vec","query":"qmd key probe"}],"limit":1,"rerank":false}}}'
token="$(bash "$LIB_DIR/../../marketplace/plugins/qmd/scripts/qmd-auth-headers.sh" --token 2>/dev/null)" || token=""
auth=()
[ -n "$token" ] && auth=(-K -)

# curl's own -m sits just inside the whole-tree deadline so the usual timeout
# is a clean curl rc 28; qmd_bounded is the backstop that kills the group.
reply="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
  qmd_bounded "$((secs + 5))" curl ${auth[@]+"${auth[@]}"} -s -m "$secs" -w '\n%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "$payload" "$url" 2>/dev/null)"
rc=$?
[ "$rc" -eq 124 ] || [ "$rc" -eq 28 ] && fail 2 "no embedding reply from $url within ${secs}s"
[ "$rc" -eq 7 ] && fail 2 "nothing listening on $url"
[ "$rc" -ne 0 ] && fail 2 "daemon call failed (curl rc=$rc) on $url"

code="${reply##*$'\n'}"
body="${reply%$'\n'*}"
sse="$(printf '%s\n' "$body" | sed -n 's/^data:[[:space:]]*//p')"
[ -n "$sse" ] && body="$sse"

key_msg="the qmd daemon's embedding provider answered 401 - it was started without QMD_OPENAI_API_KEY; restart it with the key (marketplace/plugins/qmd/README.md, OpenRouter section)"

# The provider's 401 text, wherever the daemon carries it (HTTP status, tool error
# text or JSON-RPC error message).
case "$body" in
  *'No cookie auth credentials found'*) fail 1 "$key_msg" ;;
esac
case "$code" in
  401 | 403) fail 2 "the qmd daemon refused the bearer token (HTTP $code) - set QMD_HTTP_AUTH_FILE to its token file" ;;
esac

err="$(printf '%s' "$body" | jq -r 'if type != "object" then "bad"
  elif (.error | type) == "object" then (.error.message // "" | tostring)
  elif .result.isError == true then ([.result.content[]? | .text? | strings] | first // "unreadable")
  elif (.result.content | type) == "array" then "" else "bad" end' 2>/dev/null)" || err="bad"
case "$err" in
  '') exit 0 ;;
  *401* | *[Uu]nauthorized*) fail 1 "$key_msg" ;;
  bad) fail 2 "unreadable reply from $url (HTTP $code)" ;;
  *) fail 2 "the qmd daemon's embedding query failed (HTTP $code)" ;;
esac
