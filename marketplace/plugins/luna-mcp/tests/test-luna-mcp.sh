#!/usr/bin/env bash
# luna-mcp static hygiene suite. It needs no node_modules, so the shell-unit shards run it.
# It pins the dependency policy (v2 SDK only, exact pins), the public-mirror rule (no
# absolute home paths, no real tailnet names or addresses), the systemd hardening
# lines, and the security primitives the behaviour suite relies on being present.
# Every detector has a planted-violation control so a lint that stops matching fails.
#
# Usage: bash marketplace/plugins/luna-mcp/tests/test-luna-mcp.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/luna-mcp-lint.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

HOME_RE='/(home|Users)/[A-Za-z0-9_.-]+'
TAILNET_RE='[A-Za-z0-9_-]+\.ts\.net'
CGNAT_RE='(^|[^0-9.])100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+'
NET_IMPORT_RE='(from|require\()[[:space:]]*.(express|hono|fastify|koa|@modelcontextprotocol/(sdk|node))'
RANGE_RE=':[[:space:]]*"[\^~]'

scan() { grep -rnE --exclude=test-luna-mcp.sh --exclude-dir=node_modules --exclude-dir=dist "$@"; }

expect_hit() {
  if grep -qE "$3" "$2"; then pass "control: $1 is detected"; else fail "control: $1 was not detected"; fi
}

planted="$tmp/planted"
mkdir -p "$planted"
printf 'const root = "%s/someone/vault";\n' "/ho""me" > "$planted/home.ts"
printf 'const url = "https://real-node.real-tail.ts%s/luna/mcp";\n' ".net" > "$planted/tailnet.ts"
printf 'const ip = "100.100.1.2";\n' > "$planted/cgnat.ts"
printf 'import express from "express";\n' > "$planted/net.ts"
printf '{ "dependencies": { "zod": "^4.6.7" } }\n' > "$planted/range.json"
expect_hit "an absolute home path" "$planted/home.ts" "$HOME_RE"
expect_hit "a real tailnet host" "$planted/tailnet.ts" "$TAILNET_RE"
expect_hit "a tailnet address" "$planted/cgnat.ts" "$CGNAT_RE"
expect_hit "a web framework import" "$planted/net.ts" "$NET_IMPORT_RE"
expect_hit "a caret range" "$planted/range.json" "$RANGE_RE"

check_none() {
  local label="$1" re="$2"; shift 2
  local out rc
  out=$(scan "$re" "$@" 2>/dev/null); rc=$?
  case "$rc" in
    0) fail "$label:"; printf '%s\n' "$out" | head -5 ;;
    1) pass "$label" ;;
    *) fail "$label (scan failed rc=$rc)" ;;
  esac
}

for f in .claude-plugin/plugin.json package.json package-lock.json .npmrc README.md tsconfig.json systemd/luna-mcp.service; do
  if [ -f "$HERE/$f" ]; then pass "$f exists"; else fail "$f is missing"; fi
done
for d in src tests systemd; do
  if [ -n "$(find "$HERE/$d" -type f -print -quit 2>/dev/null)" ]; then pass "$d/ has files to scan"; else fail "$d/ is empty"; fi
done

SUITES="audit.test.ts auth.test.ts cli.test.ts egress.test.ts paths.test.ts qmd-proxy.test.ts server.test.ts vault-fs.test.ts"

ts_files() { (cd "$1" && for f in *.ts; do [ -e "$f" ] && [ "$f" != helpers.ts ] && printf '%s\n' "$f"; done | sort); }
suites_match() { [ "$(ts_files "$1")" = "$(printf '%s\n' "$SUITES" | tr ' ' '\n' | sort)" ]; }

mkdir -p "$tmp/stray"
for f in $SUITES; do : > "$tmp/stray/$f"; done
: > "$tmp/stray/helpers.ts"
if suites_match "$tmp/stray"; then pass "control: a complete suite directory matches the list"; else fail "control: a complete suite directory did not match"; fi
: > "$tmp/stray/stray.spec.ts"
if suites_match "$tmp/stray"; then fail "control: a stray test file outside the glob was not detected"; else pass "control: a stray test file outside the glob is detected"; fi
if suites_match "$HERE/tests"; then pass "tests/ holds exactly the listed suites, so dist/tests/*.test.js runs all of them"; else fail "tests/ and the suite list differ"; fi

plugin_version=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$HERE/.claude-plugin/plugin.json" | head -1 | cut -d'"' -f4)
package_version=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' "$HERE/package.json" | head -1 | cut -d'"' -f4)
if [ -n "$plugin_version" ] && [ "$plugin_version" = "$package_version" ]; then pass "plugin.json and package.json share version $plugin_version"; else fail "versions differ: plugin '$plugin_version' package '$package_version'"; fi
if grep -qE '"name"[[:space:]]*:[[:space:]]*"luna-mcp"' "$HERE/.claude-plugin/plugin.json"; then pass "plugin.json names luna-mcp"; else fail "plugin.json does not name luna-mcp"; fi

pin() { grep -qE "\"$1\"[[:space:]]*:[[:space:]]*\"$2\"" "$HERE/package.json"; }
if pin '@modelcontextprotocol/server' '2\.4\.0'; then pass "the v2 server SDK is pinned exactly"; else fail "@modelcontextprotocol/server is not pinned to 2.4.0"; fi
if pin zod '4\.6\.7'; then pass "zod is pinned exactly"; else fail "zod is not pinned to 4.6.7"; fi
if pin typescript '7\.0\.2'; then pass "typescript is pinned exactly"; else fail "typescript is not pinned to 7.0.2"; fi
if pin yaml '2\.9\.1'; then pass "yaml is pinned exactly"; else fail "yaml is not pinned to 2.9.1"; fi
if grep -q '"node_modules/yaml"' "$HERE/package-lock.json"; then pass "the lockfile resolves yaml"; else fail "the lockfile lacks yaml"; fi
if grep -q 'parseDocument' "$HERE/src/paths.ts"; then pass "frontmatter is read with the yaml parser"; else fail "paths.ts does not use the yaml parser"; fi
if grep -q '/proc/self/fd' "$HERE/src/paths.ts"; then pass "paths.ts verifies through the opened handle"; else fail "paths.ts does not use /proc/self/fd"; fi
if grep -qi 'linux only' "$HERE/README.md"; then pass "README says the service is Linux only"; else fail "README does not say the service is Linux only"; fi
if grep -qE 'reclaim|staleMs|rename\(lock' "$HERE/src/cli/keys.ts"; then fail "keys.ts reclaims locks automatically"; else pass "keys.ts never reclaims a lock"; fi
check_none "package.json has no caret or tilde range" "$RANGE_RE" "$HERE/package.json"
check_none "package.json names no v1 SDK, node adapter or web framework" '"(@modelcontextprotocol/(sdk|node)|hono|express|fastify|koa)"' "$HERE/package.json"
check_none "the lockfile carries no v1 SDK, node adapter or hono" '"node_modules/(@modelcontextprotocol/(sdk|node)|hono)"' "$HERE/package-lock.json"
if grep -q '"node_modules/@modelcontextprotocol/server"' "$HERE/package-lock.json"; then pass "the lockfile resolves the v2 server SDK"; else fail "the lockfile lacks the v2 server SDK"; fi
if grep -qE '"node"[[:space:]]*:[[:space:]]*">=24"' "$HERE/package.json"; then pass "engines.node is >=24"; else fail "engines.node is not >=24"; fi
if grep -qF '"pretest": "npm run build"' "$HERE/package.json" && grep -qF '"test": "node --test dist/tests/*.test.js && bash tests/test-luna-mcp.sh"' "$HERE/package.json"; then pass "package.json builds before it tests and runs both suites"; else fail "package.json scripts drifted"; fi
if grep -q '^min-release-age=3$' "$HERE/.npmrc"; then pass ".npmrc sets min-release-age=3"; else fail ".npmrc does not set min-release-age=3"; fi

check_none "src imports no web framework, v1 SDK or node adapter" "$NET_IMPORT_RE" "$HERE/src" "$HERE/tests"
if grep -rqE "from \"@modelcontextprotocol/server\"" "$HERE/src/server.ts" && grep -q 'createMcpHandler' "$HERE/src/server.ts" && grep -q 'requireBearerAuth' "$HERE/src/auth.ts"; then pass "src uses createMcpHandler and requireBearerAuth from the v2 server package"; else fail "src does not use the v2 createMcpHandler and requireBearerAuth"; fi

check_none "no absolute home path in src, tests, README, systemd or package.json" "$HOME_RE" "$HERE/src" "$HERE/tests" "$HERE/README.md" "$HERE/systemd" "$HERE/package.json"
tailnet_hits=$(scan "$TAILNET_RE" "$HERE/src" "$HERE/tests" "$HERE/README.md" "$HERE/systemd" 2>/dev/null | grep -vE 'example-tailnet\.ts\.net')
if [ -z "$tailnet_hits" ]; then pass "every tailnet host is the example placeholder"; else fail "a tailnet host is not a placeholder:"; printf '%s\n' "$tailnet_hits" | head -5; fi
check_none "no tailnet address in src, tests, README or systemd" "$CGNAT_RE" "$HERE/src" "$HERE/tests" "$HERE/README.md" "$HERE/systemd"

unit="$HERE/systemd/luna-mcp.service"
for line in 'ProtectHome=read-only' 'ReadWritePaths=%h/.local/state/himmel' 'NoNewPrivileges=yes' 'WantedBy=default.target'; do
  if grep -qxF "$line" "$unit"; then pass "unit sets $line"; else fail "unit lacks $line"; fi
done
if grep -qE '^ExecStart=.*%h/' "$unit"; then pass "unit starts the service from a %h path"; else fail "unit ExecStart does not use %h"; fi
if grep -qE '^EnvironmentFile=-?%h/' "$unit"; then pass "unit reads its settings from a %h environment file"; else fail "unit has no %h EnvironmentFile"; fi
check_none "unit binds no wildcard address" '0\.0\.0\.0|\[::\]' "$unit"
printf '[Service]\nExecStart=/usr/bin/env node server.js\n' > "$planted/bad.service"
if grep -qxF 'ProtectHome=read-only' "$planted/bad.service"; then fail "control: a unit without ProtectHome passed"; else pass "control: a unit without ProtectHome is detected"; fi

for needle in 'timingSafeEqual:src/auth.ts' 'expectedResource:src/auth.ts' 'O_NOFOLLOW:src/paths.ts' 'realpath:src/paths.ts' 'createHash("sha256"):src/auth.ts' '127.0.0.1:src/server.ts' 'toWebRequest:src/server.ts'; do
  word=${needle%%:*}; file=${needle#*:}
  if grep -qF "$word" "$HERE/$file"; then pass "$file uses $word"; else fail "$file does not use $word"; fi
done
if grep -qiE 'headers?\.(set|append)\([^)]*origin' "$HERE/src/qmd-proxy.ts" || grep -qiE '"origin"[[:space:]]*:' "$HERE/src/qmd-proxy.ts"; then fail "qmd-proxy sets an Origin header"; else pass "qmd-proxy sets no Origin header"; fi

for doc in 'luna-mcp-keys' 'luna-mcp-audit' 'systemctl --user' '/luna/health' 'LUNA_MCP_PUBLIC_URL' 'HIMMEL_REPO' 'QMD_HTTP_TOKEN_FILE' 'LUNA_MCP_KEYS_FILE' 'LUNA_MCP_AUDIT_FILE' 'QMD_CONFIG_FILE'; do
  if grep -qF -- "$doc" "$HERE/README.md"; then pass "README documents $doc"; else fail "README does not document $doc"; fi
done

[ "$failures" -eq 0 ] || { echo "FAILED: $failures"; exit 1; }
echo "all passed"
