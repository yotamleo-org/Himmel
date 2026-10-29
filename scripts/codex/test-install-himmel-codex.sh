#!/usr/bin/env bash
# Hermetic tests for install-himmel-codex.sh.
# No real Codex install needed: a stub `codex` CLI simulates
# `plugin marketplace list/add` and `plugin list/add`, driven by test-controlled
# state files, and records every mutating call to a log. Asserts the installer is
# idempotent (no re-add when already installed+enabled), registers the himmel
# marketplace when absent, adds only the missing plugins, honours --dry-run, and
# is non-destructive (never removes/disables anything).
set -euo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$SCRIPT_DIR/install-himmel-codex.sh"

fails=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; fails=$((fails + 1)); }
# `-e "$2"` so a pattern beginning with '-' (e.g. "--disable") is not parsed as a grep option.
assert_log_has()  { if grep -qF -e "$2" "$1"; then pass "$3"; else fail "$3 (missing '$2' in call-log)"; fi; }
assert_log_lacks(){ if grep -qF -e "$2" "$1"; then fail "$3 (unexpected '$2' in call-log)"; else pass "$3"; fi; }
assert_count()    { local n; n="$(grep -cF -e "$2" "$1" || true)"; if [ "$n" = "$3" ]; then pass "$4"; else fail "$4 (count '$2' = $n, want $3)"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stub `codex` CLI --------------------------------------------------------
# State dir ($CODEX_STUB_STATE):
#   marketplaces.txt : one marketplace NAME per line (drives `marketplace list`)
#   plugins.txt      : "name@marketplace<TAB>STATUS" per line (drives `plugin list`)
#   calls.log        : every mutating invocation, appended by the stub
STUB="$TMP/codex-stub.sh"
cat > "$STUB" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
S="${CODEX_STUB_STATE:?CODEX_STUB_STATE unset}"
log() { echo "$*" >> "$S/calls.log"; }
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "list" ]; then
  echo "MARKETPLACE                  ROOT"
  if [ -f "$S/marketplaces.txt" ]; then
    while IFS= read -r m; do [ -n "$m" ] && printf '%-28s %s\n' "$m" "/fake/$m"; done < "$S/marketplaces.txt"
  fi
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "add" ]; then
  log "marketplace add ${4:-}"; exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "list" ]; then
  echo "PLUGIN                                   STATUS              VERSION  PATH"
  if [ -f "$S/plugins.txt" ]; then
    while IFS="$(printf '\t')" read -r sel status; do
      [ -n "$sel" ] && printf '%-40s %-19s local     /fake/%s\n' "$sel" "$status" "$sel"
    done < "$S/plugins.txt"
  fi
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "add" ]; then
  log "plugin add ${3:-}"; exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "remove" ]; then
  log "plugin remove ${3:-}"
  [ -f "$S/plugins.txt" ] && { grep -vF "${3:-}" "$S/plugins.txt" > "$S/plugins.new" || true; mv "$S/plugins.new" "$S/plugins.txt"; }
  exit 0
fi
if [ "${1:-}" = "plugin" ] && [ "${2:-}" = "marketplace" ] && [ "${3:-}" = "remove" ]; then
  log "marketplace remove ${4:-}"
  [ -f "$S/marketplaces.txt" ] && { grep -vxF "${4:-}" "$S/marketplaces.txt" > "$S/mk.new" || true; mv "$S/mk.new" "$S/marketplaces.txt"; }
  exit 0
fi
# mcp.txt: "name<TAB>url" per user-configured server ("-" url = stdio). The
# qmd@qmd plugin surfaces a stdio server also named "qmd" (real `codex mcp get
# qmd` output, codex-cli 0.165.0).
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "get" ]; then
  n="${3:-}"
  if [ "$n" = "qmd" ] && [ -f "$S/plugins.txt" ] && grep -qF 'qmd@qmd' "$S/plugins.txt"; then
    printf 'qmd\n  enabled: true\n  transport: stdio\n  command: qmd\n  args: mcp\n  cwd: -\n  env: -\n  remove: codex mcp remove qmd\n'; exit 0
  fi
  if [ -f "$S/mcp.txt" ]; then
    while IFS="$(printf '\t')" read -r name url flag; do
      [ "$name" = "$n" ] || continue
      if [ "$url" = "-" ]; then printf '%s\n  enabled: true\n  transport: stdio\n  command: qmd\n  args: mcp\n' "$n"
      elif [ "${flag:-}" = "disabled" ]; then printf '%s\n  enabled: false\n  transport: streamable_http\n  url: %s\n  bearer_token_env_var: QMD_HTTP_TOKEN\n' "$n" "$url"
      elif [ "${flag:-}" = "nobearer" ]; then printf '%s\n  enabled: true\n  transport: streamable_http\n  url: %s\n  bearer_token_env_var: -\n' "$n" "$url"
      else printf '%s\n  enabled: true\n  transport: streamable_http\n  url: %s\n  bearer_token_env_var: QMD_HTTP_TOKEN\n' "$n" "$url"; fi
      exit 0
    done < "$S/mcp.txt"
  fi
  echo "Error: No MCP server named '$n' found." >&2; exit 1
fi
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "add" ]; then
  log "mcp add $*"
  url=""; for a in "$@"; do [ "${prev:-}" = "--url" ] && url="$a"; prev="$a"; done
  printf '%s\t%s\n' "$3" "$url" >> "$S/mcp.txt"; exit 0
fi
if [ "${1:-}" = "mcp" ] && [ "${2:-}" = "remove" ]; then
  log "mcp remove ${3:-}"
  [ -f "$S/mcp.txt" ] && { grep -v "^${3:-}$(printf '\t')" "$S/mcp.txt" > "$S/mcp.new" || true; mv "$S/mcp.new" "$S/mcp.txt"; }
  exit 0
fi
exit 0
STUB_EOF
chmod +x "$STUB"

mk_state() {  # $1 = state dir; seeds empty marketplaces + plugins + calls
  local s="$1"; rm -rf "$s"; mkdir -p "$s"
  : > "$s/marketplaces.txt"; : > "$s/plugins.txt"; : > "$s/calls.log"; : > "$s/mcp.txt"
}

run() {  # state-dir, then installer args
  local s="$1"; shift
  # CODEX_HOME -> a temp dir so the test never touches the real ~/.codex cache.
  CODEX_BIN="$STUB" CODEX_STUB_STATE="$s" CODEX_HOME="$TMP/codex-home" bash "$INSTALLER" "$@"
}

DEFAULT_SET="himmel-ops handover obsidian-triage telegram-himmel"

echo "== scenario A: fresh machine (no himmel marketplace, no plugins) =="
S="$TMP/A"; mk_state "$S"
# only foreign marketplaces/plugins present
printf 'openai-bundled\n' > "$S/marketplaces.txt"
printf 'browser@openai-bundled\tinstalled, enabled\n' > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_has  "$S/calls.log" "marketplace add"           "registers himmel marketplace when absent"
assert_count    "$S/calls.log" "plugin add"              "4" "adds all 4 default plugins"
for p in $DEFAULT_SET; do assert_log_has "$S/calls.log" "plugin add $p@himmel" "adds $p"; done

echo "== scenario B: idempotent (marketplace present, all targets installed+enabled) =="
S="$TMP/B"; mk_state "$S"
printf 'openai-bundled\nhimmel\n' > "$S/marketplaces.txt"
{ for p in $DEFAULT_SET; do printf '%s@himmel\tinstalled, enabled\n' "$p"; done; } > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_lacks "$S/calls.log" "marketplace add" "no re-register when himmel marketplace present"
assert_log_lacks "$S/calls.log" "plugin add"      "no re-add when all targets enabled (idempotent)"

echo "== scenario C: one target not installed (others enabled) =="
S="$TMP/C"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
{ printf 'himmel-ops@himmel\tnot installed\n';
  printf 'handover@himmel\tinstalled, enabled\n';
  printf 'obsidian-triage@himmel\tinstalled, enabled\n';
  printf 'telegram-himmel@himmel\tinstalled, enabled\n'; } > "$S/plugins.txt"
run "$S" >/dev/null
assert_count    "$S/calls.log" "plugin add" "1" "adds exactly the one missing plugin"
assert_log_has  "$S/calls.log" "plugin add himmel-ops@himmel" "adds the not-installed himmel-ops"
assert_log_lacks "$S/calls.log" "plugin add handover@himmel"  "leaves already-enabled handover untouched"

echo "== scenario D: --dry-run reports but does not mutate =="
S="$TMP/D"; mk_state "$S"
printf 'openai-bundled\n' > "$S/marketplaces.txt"; : > "$S/plugins.txt"
out="$(run "$S" --dry-run)"
assert_log_lacks "$S/calls.log" "marketplace add" "--dry-run issues no marketplace add"
assert_log_lacks "$S/calls.log" "plugin add"      "--dry-run issues no plugin add"
if grepq "$out" -iE 'would|dry'; then pass "--dry-run reports intended changes"; else fail "--dry-run gave no change report"; fi

echo "== scenario E: codex CLI missing -> exit 1, no calls =="
S="$TMP/E"; mk_state "$S"
rc=0; CODEX_BIN="$TMP/nope-not-a-codex" CODEX_STUB_STATE="$S" bash "$INSTALLER" >/dev/null 2>&1 || rc=$?
if [ "$rc" = "1" ]; then pass "missing codex CLI exits 1"; else fail "missing codex CLI exit=$rc (want 1)"; fi
assert_log_lacks "$S/calls.log" "add" "no calls when codex CLI missing"

echo "== scenario F: non-destructive (never removes/disables) =="
S="$TMP/F"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'himmel-ops@himmel\tnot installed\n' > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_lacks "$S/calls.log" "remove"    "never calls plugin/marketplace remove"
assert_log_lacks "$S/calls.log" "--disable" "never disables a plugin"

echo "== scenario G: --plugins override =="
S="$TMP/G"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"; : > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_count   "$S/calls.log" "plugin add" "1" "--plugins restricts the set to one"
assert_log_has "$S/calls.log" "plugin add himmel-ops@himmel" "--plugins adds the named plugin"

echo "== scenario H: unknown argument -> exit 2, no calls =="
S="$TMP/H"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"
rc=0; run "$S" --bogus >/dev/null 2>&1 || rc=$?
if [ "$rc" = "2" ]; then pass "unknown arg exits 2"; else fail "unknown arg exit=$rc (want 2)"; fi
assert_log_lacks "$S/calls.log" "add" "no calls on unknown arg"

echo "== scenario I: @marketplace discrimination (same plugin name, different marketplace) =="
S="$TMP/I"; mk_state "$S"
printf 'himmel\nopenai-bundled\n' > "$S/marketplaces.txt"
# himmel-ops is installed+enabled under ANOTHER marketplace; the himmel one is absent.
printf 'himmel-ops@openai-bundled\tinstalled, enabled\n' > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "plugin add himmel-ops@himmel" "still adds himmel-ops@himmel despite same name in another marketplace"

echo "== scenario J: marketplace name exact-match (near-miss must not satisfy) =="
S="$TMP/J"; mk_state "$S"
printf 'himmel-extra\n' > "$S/marketplaces.txt"   # 'himmel' absent; only a substring-y near-miss present
: > "$S/plugins.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "marketplace add" "registers 'himmel' when only 'himmel-extra' present (no substring false-match)"

echo "== scenario L: installer never rewrites external plugin hooks.json (HIMMEL-1114) =="
# Fixture shape = ralph-loop's real cached hooks.json plus the top-level
# `description` that codex < rust-v0.143.0 rejected. Fixed upstream, so the
# installer must leave third-party plugin files untouched.
S="$TMP/L"; mk_state "$S"
printf 'himmel\n' > "$S/marketplaces.txt"; : > "$S/plugins.txt"
HJ="$TMP/codex-home/plugins/cache/claude-plugins-official/ralph-loop/1.0.0/hooks/hooks.json"
mkdir -p "$(dirname "$HJ")"
# shellcheck disable=SC2016  # literal ${CLAUDE_PLUGIN_ROOT} is the fixture content
printf '%s\n' '{"description":"Ralph loop","hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/stop-hook.sh\""}]}]}}' > "$HJ"
before="$(cat "$HJ")"
out="$(run "$S" --plugins=himmel-ops 2>&1)"
if [ "$(cat "$HJ")" = "$before" ]; then pass "external plugin hooks.json left untouched"; else fail "installer rewrote an external plugin hooks.json"; fi
if grepq "$out" -iE '^--- 3\. sanitize|sanitize step'; then fail "installer still runs/announces a sanitize phase"; else pass "no sanitize phase in installer output"; fi
rm -rf "$TMP/codex-home/plugins"

echo "== scenario M: Codex searches through the shared qmd server, not upstream's stdio qmd (HIMMEL-8118) =="
QMD_URL="http://localhost:8181/mcp"
unset QMD_MCP_URL   # the rows assume the default 8181 URL, whatever the host exports
# station shape (real ~/.codex/config.toml): upstream qmd marketplace + enabled qmd@qmd plugin
S="$TMP/M1"; mk_state "$S"
printf 'himmel\nqmd\n' > "$S/marketplaces.txt"
{ for p in $DEFAULT_SET; do printf '%s@himmel\tinstalled, enabled\n' "$p"; done; printf 'qmd@qmd\tinstalled, enabled\n'; } > "$S/plugins.txt"
run "$S" >/dev/null
assert_log_has   "$S/calls.log" "plugin remove qmd@qmd"  "M1 removes the upstream qmd@qmd plugin"
assert_log_has   "$S/calls.log" "marketplace remove qmd" "M1 removes the upstream qmd marketplace"
assert_log_has   "$S/calls.log" "mcp add qmd --url $QMD_URL --bearer-token-env-var QMD_HTTP_TOKEN" "M1 adds the 8181 entry with an env-var bearer"
assert_log_lacks "$S/calls.log" "remove himmel" "M1 never touches the himmel marketplace"
S="$TMP/M2"; mk_state "$S"   # already converged: no upstream plugin, 8181 entry present
printf 'himmel\n' > "$S/marketplaces.txt"
{ for p in $DEFAULT_SET; do printf '%s@himmel\tinstalled, enabled\n' "$p"; done; } > "$S/plugins.txt"
printf 'qmd\t%s\n' "$QMD_URL" > "$S/mcp.txt"
run "$S" >/dev/null
assert_log_lacks "$S/calls.log" "remove"  "M2 re-run removes nothing"
assert_log_lacks "$S/calls.log" "mcp add" "M2 re-run adds nothing (idempotent)"
S="$TMP/M3"; mk_state "$S"   # a stale user-added stdio qmd server, no plugin
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'qmd\t-\n' > "$S/mcp.txt"
run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "mcp remove qmd" "M3 drops a stdio qmd server"
assert_log_has "$S/calls.log" "mcp add qmd --url $QMD_URL" "M3 replaces it with the 8181 entry"
S="$TMP/M4"; mk_state "$S"   # dry-run on the station shape
printf 'himmel\nqmd\n' > "$S/marketplaces.txt"; printf 'qmd@qmd\tinstalled, enabled\n' > "$S/plugins.txt"
out="$(run "$S" --dry-run --plugins=himmel-ops)"
assert_log_lacks "$S/calls.log" "qmd" "M4 --dry-run mutates no qmd state"
if grepq "$out" 'WOULD.*qmd'; then pass "M4 --dry-run reports the qmd changes"; else fail "M4 --dry-run did not report qmd changes"; fi
S="$TMP/M5"; mk_state "$S"   # QMD_MCP_URL override, the variable the qmd launch scripts read
printf 'himmel\n' > "$S/marketplaces.txt"
QMD_MCP_URL="http://localhost:9999/mcp" run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "mcp add qmd --url http://localhost:9999/mcp" "M5 honours QMD_MCP_URL"
S="$TMP/M6"; mk_state "$S"   # token env unset in the installer's env -> visible WARN naming the launch line
printf 'himmel\n' > "$S/marketplaces.txt"
out="$(env -u QMD_HTTP_TOKEN -u QMD_HTTP_AUTH_FILE -u QMD_HTTP_TOKEN_FILE XDG_CONFIG_HOME=/x/cfg CODEX_BIN="$STUB" CODEX_STUB_STATE="$S" CODEX_HOME="$TMP/codex-home" bash "$INSTALLER" --plugins=himmel-ops)"
if grepq "$out" '^WARN .*QMD_HTTP_TOKEN'; then pass "M6 WARNs when QMD_HTTP_TOKEN is unset"; else fail "M6 no WARN when QMD_HTTP_TOKEN is unset"; fi
# shellcheck disable=SC2016  # the literal $(cat ...) is the expected WARN text
if grepq "$out" -F 'export QMD_HTTP_TOKEN="$(cat /x/cfg/qmd/http-token)"'; then pass "M6 WARN names the exact launch-env line with the token file path"; else fail "M6 WARN lacks the export line"; fi
S="$TMP/M7"; mk_state "$S"   # token env set -> no WARN, and the value never reaches output or config calls
printf 'himmel\n' > "$S/marketplaces.txt"
out="$(QMD_HTTP_TOKEN=s3cr3t-canary CODEX_BIN="$STUB" CODEX_STUB_STATE="$S" CODEX_HOME="$TMP/codex-home" bash "$INSTALLER" --plugins=himmel-ops)"
if grepq "$out" '^WARN'; then fail "M7 WARNs although QMD_HTTP_TOKEN is set"; else pass "M7 no WARN when QMD_HTTP_TOKEN is set"; fi
if grepq "$out" -F 's3cr3t-canary' || grep -qF 's3cr3t-canary' "$S/calls.log"; then fail "M7 token value leaked"; else pass "M7 token value never printed or passed to codex"; fi
S="$TMP/M8"; mk_state "$S"   # right URL but no bearer env var: not converged, must be replaced
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'qmd\t%s\tnobearer\n' "$QMD_URL" > "$S/mcp.txt"
QMD_HTTP_TOKEN=x run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "mcp remove qmd" "M8 removes a qmd entry that has the URL but no bearer"
assert_log_has "$S/calls.log" "mcp add qmd --url $QMD_URL --bearer-token-env-var QMD_HTTP_TOKEN" "M8 re-adds it with the env-var bearer"
S="$TMP/M8b"; mk_state "$S"   # a longer URL that merely starts with the 8181 URL is a different endpoint
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'qmd\t%s-old\n' "$QMD_URL" > "$S/mcp.txt"
QMD_HTTP_TOKEN=x run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "mcp add qmd --url $QMD_URL --bearer-token-env-var QMD_HTTP_TOKEN" "M8b replaces a qmd entry whose URL only starts with the 8181 URL"
S="$TMP/M8c"; mk_state "$S"   # right URL and bearer but disabled: not converged
printf 'himmel\n' > "$S/marketplaces.txt"
printf 'qmd\t%s\tdisabled\n' "$QMD_URL" > "$S/mcp.txt"
QMD_HTTP_TOKEN=x run "$S" --plugins=himmel-ops >/dev/null
assert_log_has "$S/calls.log" "mcp add qmd --url $QMD_URL --bearer-token-env-var QMD_HTTP_TOKEN" "M8c replaces a disabled qmd entry"
S="$TMP/M9"; mk_state "$S"   # token path with a space stays one word in the printed export line
printf 'himmel\n' > "$S/marketplaces.txt"
out="$(env -u QMD_HTTP_TOKEN -u QMD_HTTP_AUTH_FILE -u QMD_HTTP_TOKEN_FILE XDG_CONFIG_HOME="/x/my cfg" CODEX_BIN="$STUB" CODEX_STUB_STATE="$S" CODEX_HOME="$TMP/codex-home" bash "$INSTALLER" --plugins=himmel-ops)"
# shellcheck disable=SC2016  # the literal $(cat ...) is the expected WARN text
if grepq "$out" -F 'export QMD_HTTP_TOKEN="$(cat /x/my\ cfg/qmd/http-token)"'; then pass "M9 export line shell-quotes the token path"; else fail "M9 export line leaves the token path unquoted"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "$fails FAILED" >&2; exit 1; fi
