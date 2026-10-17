#!/usr/bin/env bash
# qmd-burst-proof.sh — time a burst of parallel vec queries against the qmd daemon.
#
# Run it:   bash qmd-burst-proof.sh
#   Fires QMD_BURST_N (default 10) vec queries at once (rerank off, limit 1,
#   default scope) at the daemon's MCP endpoint, times each, prints a table and
#   one verdict line:
#     BURST-PASS  every call got a result or a Busy reply within QMD_BURST_BUSY_MAX
#                 seconds (2), and no result took over QMD_BURST_LIMIT seconds (60)
#     BURST-FAIL  otherwise; the line names the first offending call
#   exit 0 pass, 1 fail, 2 no daemon, an unreadable or refused reply, or a bearer
#   token with a non-loopback URL (no verdict line).
#
# Env: QMD_MCP_URL (default http://localhost:8181/mcp), QMD_BURST_N, QMD_BURST_LIMIT,
# QMD_BURST_BUSY_MAX, QMD_BURST_CURL_CAP (per-call curl -m, default LIMIT + 30),
# QMD_HTTP_AUTH_FILE (bearer-token file, as qmd-auth-headers.sh reads it).
#
# The bearer token goes to curl as a config on stdin, never argv, and only to a
# loopback host. Replies are classified, never printed, so the token cannot reach
# the output. Milliseconds come from `date +%s%N` and bash arithmetic.
#
# Platform guard (gitbash-only): POSIX bash 3.2+ with GNU date (%N); curl and jq required.

set -u
{ set +x; } 2>/dev/null
LC_ALL=C

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTH_HELPER="$LIB_DIR/../../../marketplace/plugins/qmd/scripts/qmd-auth-headers.sh"

url="${QMD_MCP_URL:-http://localhost:8181/mcp}"

# num <value> <default>: a positive whole number or the default
num() {
  case "$1" in '' | *[!0-9]*) printf '%s' "$2" ;; *) [ "$((10#$1))" -gt 0 ] && printf '%s' "$((10#$1))" || printf '%s' "$2" ;; esac
}
n="$(num "${QMD_BURST_N:-}" 10)"
limit="$(num "${QMD_BURST_LIMIT:-}" 60)"
busy_max="$(num "${QMD_BURST_BUSY_MAX:-}" 2)"
cap="$(num "${QMD_BURST_CURL_CAP:-}" "$((limit + 30))")"

fail() { echo "qmd-burst-proof: $2" >&2; exit "$1"; }

command -v curl >/dev/null 2>&1 || fail 2 "curl not found"
command -v jq >/dev/null 2>&1 || fail 2 "jq not found"

token="$(bash "$AUTH_HELPER" --token 2>/dev/null)" || token=""
auth=()
if [ -n "$token" ]; then
  case "$url" in
    http://* | https://*) ;;
    *) fail 2 "refusing to send the bearer token: QMD_MCP_URL must start with http:// or https://" ;;
  esac
  hostport="${url#*://}"
  hostport="${hostport%%[/?#]*}"
  host="${hostport##*@}"
  case "$host" in
    '['*) host="${host%%]*}]" ;;
    *) host="${host%%:*}" ;;
  esac
  case "$host" in
    localhost | '[::1]') ;;
    127.*)
      oct="${host#127.}"
      dots="${oct//[!.]/}"
      case "$oct" in *[!0-9.]* | .* | *. | *..*) host="" ;; esac
      [ "${#dots}" -eq 2 ] || host=""
      if [ -n "$host" ]; then
        IFS=. read -r o1 o2 o3 <<<"$oct"
        for x in "$o1" "$o2" "$o3"; do
          case "$x" in 0?*) host="" ;; esac
          if [ "${#x}" -gt 3 ] || [ "$x" -gt 255 ]; then host=""; fi
        done
      fi
      ;;
    *) host="" ;;
  esac
  [ -n "$host" ] || fail 2 "refusing to send the bearer token to a non-loopback host in QMD_MCP_URL; point it at localhost or unset QMD_HTTP_AUTH_FILE"
  # shellcheck disable=SC1003  # '\' is a literal backslash, not an escaped quote
  case "$token" in
    *'"'* | *'\'* | *[[:cntrl:]]*) fail 2 "the bearer token in QMD_HTTP_AUTH_FILE has a quote, backslash or control character; use a plain token" ;;
  esac
  auth=(-K -)
fi

dir="$(mktemp -d "${TMPDIR:-/tmp}/qmd-burst-proof.XXXXXX")" || fail 2 "could not create a temp dir"
trap 'rm -rf "$dir"' EXIT

# one_call <i>: writes "<ms> <class>" to $dir/<i>; class is ok | busy | noreply |
# down | refused | bad
one_call() {
  local i="$1" payload start end reply rc code body sse cls
  payload='{"jsonrpc":"2.0","id":'"$i"',"method":"tools/call","params":{"name":"query","arguments":{"searches":[{"type":"vec","query":"qmd burst proof '"$i"'"}],"limit":1,"rerank":false}}}'
  start="$(date +%s%N)"
  # -q skips ~/.curlrc and --noproxy '*' ignores proxy variables: either could carry the bearer elsewhere.
  reply="$(printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -q --noproxy '*' ${auth[@]+"${auth[@]}"} -s -m "$cap" -w '\n%{http_code}' -X POST \
      -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
      -d "$payload" -- "$url" 2>/dev/null)"
  rc=$?
  end="$(date +%s%N)"
  cls=""
  case "$rc" in
    0) ;;
    28) cls=noreply ;;
    7) cls=down ;;
    *) cls=bad ;;
  esac
  if [ -z "$cls" ]; then
    code="${reply##*$'\n'}"
    body="${reply%$'\n'*}"
    sse="$(printf '%s\n' "$body" | sed -n 's/^data:[[:space:]]*//p')"
    [ -n "$sse" ] && body="$sse"
    cls="$(printf '%s\n' "$body" | jq -rs '[.[] | select(type == "object" and (has("result") or has("error")))] | last // null
      | if . == null then "bad"
      elif (.error | type) == "object" then "bad"
      elif (.result.content | type) != "array" then "bad"
      elif .result.isError == true then
        (if ([.result.content[]? | .text? | strings] | first // "" | startswith("Busy:")) then "busy" else "bad" end)
      else "ok" end' 2>/dev/null)" || cls=bad
    case "$code" in
      401 | 403) cls=refused ;;
      200) ;;
      *) cls=bad ;;
    esac
  fi
  printf '%s %s\n' "$(((end - start) / 1000000))" "$cls" >"$dir/$i"
}

i=1
while [ "$i" -le "$n" ]; do
  one_call "$i" &
  i=$((i + 1))
done
wait

printf 'qmd-burst-proof: %s parallel vec queries at %s (limit %s s, busy within %s s)\n' "$n" "$url" "$limit" "$busy_max"
printf '%-5s %-8s %s\n' call class seconds
verdict=""
hard=""
i=1
while [ "$i" -le "$n" ]; do
  read -r ms cls <"$dir/$i" || { ms=0; cls=bad; }
  printf '%-5s %-8s %s.%03d\n' "$i" "$cls" "$((ms / 1000))" "$((ms % 1000))"
  case "$cls" in
    down | bad | refused) [ -n "$hard" ] || hard="$cls" ;;
    noreply) [ -n "$verdict" ] || verdict="call $i: no reply within the ${cap} s curl cap" ;;
    busy) [ "$ms" -le "$((busy_max * 1000))" ] || { [ -n "$verdict" ] || verdict="call $i: Busy reply took $((ms / 1000)) s, over the ${busy_max} s busy window"; } ;;
    ok) [ "$ms" -le "$((limit * 1000))" ] || { [ -n "$verdict" ] || verdict="call $i: result took $((ms / 1000)) s, over the ${limit} s limit"; } ;;
  esac
  i=$((i + 1))
done

case "$hard" in
  down) fail 2 "nothing listening on $url" ;;
  refused) fail 2 "the qmd server refused the bearer token - set QMD_HTTP_AUTH_FILE to its token file" ;;
  bad) fail 2 "unreadable reply from $url" ;;
esac
if [ -n "$verdict" ]; then
  echo "BURST-FAIL $verdict"
  exit 1
fi
echo "BURST-PASS"
exit 0
