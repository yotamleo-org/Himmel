#!/usr/bin/env bash
# qmd-auth-headers.sh - MCP `headersHelper` for the qmd HTTP daemon.
#
# The daemon requires `Authorization: Bearer <token>`; the token lives in a
# 0600 file the daemon generates on first start. This prints the headers JSON
# Claude Code merges into each request, reading the file at call time so the
# secret never enters .mcp.json, the repo, or a process env.
#
#   qmd-auth-headers.sh           -> {"Authorization":"Bearer <token>"}  (or {} when no token yet)
#   qmd-auth-headers.sh --token   -> the bare token (empty when absent)
#   qmd-auth-headers.sh --token-for <url>
#                                 -> the bare token, but only when <url> is http(s) on a
#                                    loopback host (localhost, 127.x.x.x, [::1]) and the
#                                    token is safe inside a curl config value; else empty
#
# Token path: $QMD_HTTP_AUTH_FILE (Claude Code strips env vars named *TOKEN* from a
# headersHelper, so a custom daemon QMD_HTTP_TOKEN_FILE needs the same path here
# under this name), else $QMD_HTTP_TOKEN_FILE, else ${XDG_CONFIG_HOME:-$HOME/.config}/qmd/http-token
# - the same resolution the daemon uses. A group/world-readable file is not
# trusted (the daemon refuses it too): print no token, never the secret.
set -u

token_file="${QMD_HTTP_AUTH_FILE:-${QMD_HTTP_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd/http-token}}"
token=""
if [ -f "$token_file" ]; then
  mode="$(stat -c '%a' "$token_file" 2>/dev/null || stat -f '%Lp' "$token_file" 2>/dev/null || echo 777)" # gnu-ok: BSD stat -f fallback on the same line
  case "$mode" in
    600|400) token="$(tr -d '[:space:]' <"$token_file")" ;;
  esac
fi

# Same host rule as scripts/lib/qmd-key-probe.sh: a bearer token never goes to a remote host.
loopback_url() {
  local url="$1" hostport host oct dots n o1 o2 o3
  case "$url" in http://* | https://*) ;; *) return 1 ;; esac
  hostport="${url#*://}"
  hostport="${hostport%%[/?#]*}"
  host="${hostport##*@}"
  case "$host" in
    '['*) host="${host%%]*}]" ;;
    *) host="${host%%:*}" ;;
  esac
  case "$host" in
    localhost | '[::1]') return 0 ;;
    127.*)
      oct="${host#127.}"
      dots="${oct//[!.]/}"
      case "$oct" in *[!0-9.]* | .* | *. | *..*) return 1 ;; esac
      [ "${#dots}" -eq 2 ] || return 1
      IFS=. read -r o1 o2 o3 <<<"$oct"
      for n in "$o1" "$o2" "$o3"; do
        case "$n" in 0?*) return 1 ;; esac
        if [ "${#n}" -gt 3 ] || [ "$n" -gt 255 ]; then return 1; fi
      done
      return 0 ;;
  esac
  return 1
}

if [ "${1:-}" = "--token-for" ]; then
  # shellcheck disable=SC1003  # '\' is a literal backslash, not an escaped quote
  case "$token" in *'"'* | *'\'* | *[[:cntrl:]]*) token="" ;; esac
  if loopback_url "${2:-}"; then printf '%s' "$token"; fi
  exit 0
fi
if [ "${1:-}" = "--token" ]; then
  printf '%s' "$token"
  exit 0
fi
if [ -n "$token" ]; then
  printf '{"Authorization":"Bearer %s"}\n' "$token"
else
  printf '{}\n'
fi
