#!/usr/bin/env bash
# test-qmd-auth-headers.sh - the qmd HTTP daemon requires a bearer
# token; the himmel client side reads it from a 0600 file.
#
# Covers: (a) qmd-auth-headers.sh prints the Authorization header from a 0600
# token file; (b) a group/world-readable file is NOT trusted (no token, no
# leak); (c) no token file -> {} (first start, before the daemon creates it);
# (d) ensure-qmd-daemon.sh's probe sends the token (via curl config on stdin,
# never argv) and still short-circuits on a qmd-shaped reply; (e) .mcp.json
# wires the helper as headersHelper and carries no secret.
# Hermetic: HOME and the token path point into a temp dir; curl is a mock.
set -u

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
plugin="$repo_root/marketplace/plugins/qmd"
helper="$plugin/scripts/qmd-auth-headers.sh"
ensure="$plugin/scripts/ensure-qmd-daemon.sh" # t13b-ok: path of the existing ensure script, not a service start
fail() { echo "FAIL: $1" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/qmd-auth-headers.XXXXXX")" || exit 1
trap 'rm -rf "$work"' EXIT
home="$work/home"; mkdir -p "$home"
tok="$work/http-token"
SECRET="s3cr3t-token-0123456789abcdef0123456789abcdef"

# (c) no file yet
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{}" ] || fail "(c) absent token file: expected {}, got [$out]"

# (a) 0600 file
printf '%s\n' "$SECRET" >"$tok"; chmod 600 "$tok"
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{\"Authorization\":\"Bearer $SECRET\"}" ] || fail "(a) header json wrong: [$out]"
[ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token)" = "$SECRET" ] || fail "(a) --token wrong"

# (d) Claude Code strips *TOKEN* env vars from a headersHelper: QMD_HTTP_AUTH_FILE carries the custom path
chmod 600 "$tok"
out="$(HOME="$home" QMD_HTTP_AUTH_FILE="$tok" bash "$helper")"
[ "$out" = "{\"Authorization\":\"Bearer $SECRET\"}" ] || fail "(d) QMD_HTTP_AUTH_FILE not honoured: [$out]"

# (b) world-readable file is refused
chmod 644 "$tok"
out="$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper")"
[ "$out" = "{}" ] || fail "(b) 0644 token file must not be used, got [$out]"
case "$out" in *"$SECRET"*) fail "(b) leaked the secret from a 0644 file" ;; esac
chmod 600 "$tok"

# (d) the probe sends the token on curl's stdin config, not argv
mockbin="$work/bin"; mkdir -p "$mockbin"
cat >"$mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$MOCK_DIR/argv"
if [ -p /dev/stdin ] || [ ! -t 0 ]; then cat >"$MOCK_DIR/stdin"; fi
printf '{"result":{"serverInfo":{"name":"qmd","version":"1"}}}'
MOCK
chmod +x "$mockbin/curl"
mkdir -p "$work/mock"
out="$(HOME="$home" MOCK_DIR="$work/mock" QMD_CURL="$mockbin/curl" QMD_HTTP_TOKEN_FILE="$tok" \
  QMD_MCP_URL="http://127.0.0.1:1/mcp" PATH="$mockbin:/usr/bin:/bin" bash "$ensure" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(d) ensure rc $rc: $out"
grep -q "Authorization: Bearer $SECRET" "$work/mock/stdin" || fail "(d) token not sent on curl stdin"
grep -q "$SECRET" "$work/mock/argv"; [ $? -eq 1 ] || fail "(d) token leaked into curl argv (or argv capture unreadable)"
case "$out" in *"$SECRET"*) fail "(d) token leaked into ensure output" ;; esac
grep -q -e '--noproxy [*]' "$work/mock/argv" || fail "(d) token-bearing probe lacks --noproxy '*'"

rm -f "$work/mock/stdin" "$work/mock/argv"
brace_url='http://{a@localhost:8181/,evil.example/}/mcp'
out="$(HOME="$home" MOCK_DIR="$work/mock" QMD_CURL="$mockbin/curl" QMD_HTTP_TOKEN_FILE="$tok" \
  QMD_MCP_URL="$brace_url" PATH="$mockbin:/usr/bin:/bin" bash "$ensure" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(d1) ensure rc $rc: $out"
grep -q "Authorization: Bearer $SECRET" "$work/mock/stdin" || fail "(d1) the brace URL did not reach the token-bearing probe"
grep -q -e '^-q ' "$work/mock/argv" || fail "(d1) token-bearing probe lacks -q as its first argument"
grep -q -e ' -g ' "$work/mock/argv" || fail "(d1) token-bearing probe lacks -g, so a brace in the URL would be expanded"
grep -q -F "$brace_url" "$work/mock/argv" || fail "(d1) the brace URL was not passed whole"
rm -f "$work/mock/stdin" "$work/mock/argv"
out="$(HOME="$home" MOCK_DIR="$work/mock" QMD_CURL="$mockbin/curl" QMD_HTTP_TOKEN_FILE="$tok" \
  QMD_MCP_URL="http://127.0.0.1:1/mcp" PATH="$mockbin:/usr/bin:/bin" bash "$ensure" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(d1 control) ensure rc $rc: $out"
grep -q -F 'http://127.0.0.1:1/mcp' "$work/mock/argv" || fail "(d1 control) an ordinary URL was changed"

# (d2) a non-loopback URL gets no Authorization header at all
rm -f "$work/mock/stdin" "$work/mock/argv"
out="$(HOME="$home" MOCK_DIR="$work/mock" QMD_CURL="$mockbin/curl" QMD_HTTP_TOKEN_FILE="$tok" \
  QMD_MCP_URL="http://qmd.example.invalid:8181/mcp" PATH="$mockbin:/usr/bin:/bin" bash "$ensure" 2>&1 </dev/null)"; rc=$?
[ "$rc" -eq 0 ] || fail "(d2) ensure rc $rc: $out"
[ -f "$work/mock/argv" ] || fail "(d2) the probe never reached curl"
grep -q "Authorization" "$work/mock/stdin" 2>/dev/null && fail "(d2) token sent to a non-loopback host"
grep -q "$SECRET" "$work/mock/argv" && fail "(d2) token leaked into curl argv for a non-loopback host"
[ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token-for "http://qmd.example.invalid:8181/mcp")" = "" ] || fail "(d2) --token-for printed a token for a remote host"
[ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token-for "http://127.0.0.1.evil.example/mcp")" = "" ] || fail "(d2) --token-for accepted a 127.x lookalike host"
[ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token-for "http://localhost@evil.example/mcp")" = "" ] || fail "(d2) --token-for accepted a userinfo lookalike"
for u in http://localhost:8181/mcp http://127.0.0.1:8181/mcp "http://[::1]:8181/mcp"; do
  [ "$(HOME="$home" QMD_HTTP_TOKEN_FILE="$tok" bash "$helper" --token-for "$u")" = "$SECRET" ] || fail "(d2) --token-for withheld the token from loopback $u"
done

# (e) .mcp.json wires the helper and holds no secret
grep -q '"headersHelper"' "$plugin/.mcp.json" || fail "(e) .mcp.json has no headersHelper"
grep -q 'qmd-auth-headers.sh' "$plugin/.mcp.json" || fail "(e) headersHelper does not run the helper"

echo "PASS: all qmd-auth-headers cases"
