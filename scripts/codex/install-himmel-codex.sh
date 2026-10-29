#!/usr/bin/env bash
# install-himmel-codex.sh
#
# Provision himmel under the Codex CLI by managing user-global plugin state in
# ~/.codex/config.toml the SAME way scripts/hermes/install-himmel-profile.sh
# provisions the hermes side. This is the codex-CLI half of the split:
#   hermes side : scripts/hermes/install-himmel-profile.{sh,ps1}  (CR/model profile)
#   codex side  : scripts/codex/install-himmel-codex.{sh,ps1}     (this file)
#
# It drives the `codex` CLI (codex plugin marketplace add / codex plugin add) —
# never hand-edits config.toml — so Codex owns all config writes (trust hashes,
# MCP secrets, long-path marketplace sources). NON-DESTRUCTIVE + idempotent: it
# only registers the himmel marketplace when absent and enables the himmel plugin
# set; it never removes or disables a himmel plugin, and re-runs are no-ops. The one
# removal is upstream's qmd@qmd plugin + marketplace, replaced by an MCP entry for
# the shared qmd daemon (token via $QMD_HTTP_TOKEN, never in config).
#
#   install-himmel-codex.sh                 # register marketplace + enable default set
#   install-himmel-codex.sh --all           # also enable luna-correlate
#   install-himmel-codex.sh --plugins=himmel-ops,handover
#   install-himmel-codex.sh --dry-run       # report intended changes, mutate nothing
#
# Default plugin set (all @himmel): himmel-ops handover obsidian-triage telegram-himmel
# — defined in himmel-plugin-set.conf (also what startup-health requires to stay registered).
# Env overrides: CODEX_BIN (codex CLI path).
set -euo pipefail

DRY_RUN=0
ALL=0
PLUGINS_OVERRIDE=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)        DRY_RUN=1 ;;
    --all)            ALL=1 ;;
    --plugins=*)      PLUGINS_OVERRIDE="${arg#*=}" ;;
    -h|--help)        sed -n '2,/^set /p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "ERR: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MARKET_PATH="$REPO_ROOT/marketplace"

# The marketplace name + plugin sets live in ONE data file, shared with
# startup-health (which asserts they are still registered).
PLUGIN_SET_FILE="$SCRIPT_DIR/himmel-plugin-set.conf"
plugin_set_field() { tr -d '\r' < "$PLUGIN_SET_FILE" | awk -F': *' -v k="$1" '$1==k{print $2; exit}'; }
[ -r "$PLUGIN_SET_FILE" ] || { echo "ERR: plugin set file not found at $PLUGIN_SET_FILE" >&2; exit 1; }
MARKET="$(plugin_set_field marketplace)"   # the himmel marketplace name (per marketplace/.claude-plugin/marketplace.json)
[ -n "$MARKET" ] || { echo "ERR: no 'marketplace:' in $PLUGIN_SET_FILE" >&2; exit 1; }

# --- resolve the codex CLI ---------------------------------------------------
resolve_codex() {
  if [ -n "${CODEX_BIN:-}" ]; then
    [ -x "$CODEX_BIN" ] && { echo "$CODEX_BIN"; return 0; }
    return 1   # explicitly overridden but unusable -> hard error (no silent PATH fallback)
  fi
  command -v codex 2>/dev/null && return 0
  return 1
}
CODEX="$(resolve_codex)" || { echo "ERR: codex CLI not found (set CODEX_BIN, or install Codex)" >&2; exit 1; }

[ -d "$MARKET_PATH" ] || { echo "ERR: himmel marketplace dir not found at $MARKET_PATH" >&2; exit 1; }

# --- resolve the plugin set --------------------------------------------------
if [ -n "$PLUGINS_OVERRIDE" ]; then
  PLUGINS="$(printf '%s' "$PLUGINS_OVERRIDE" | tr ',' ' ')"
else
  PLUGINS="$(plugin_set_field default)"
  [ -n "$PLUGINS" ] || { echo "ERR: no 'default:' plugin set in $PLUGIN_SET_FILE" >&2; exit 1; }
  [ "$ALL" = "1" ] && PLUGINS="$PLUGINS $(plugin_set_field all-extra)"
fi

echo "codex CLI   : $CODEX"
echo "marketplace : $MARKET ($MARKET_PATH)"
[ "$DRY_RUN" = "1" ] && echo "mode        : DRY-RUN (no changes will be made)"

changed=0

# --- 1. register the himmel marketplace if absent ----------------------------
if "$CODEX" plugin marketplace list 2>/dev/null | awk -v n="$MARKET" '$1==n{f=1} END{exit f?0:1}'; then
  echo "UNCHANGED   : marketplace '$MARKET' already registered"
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD ADD   : marketplace '$MARKET' -> $MARKET_PATH"
  else
    "$CODEX" plugin marketplace add "$MARKET_PATH" >/dev/null
    echo "CHANGED     : registered marketplace '$MARKET' -> $MARKET_PATH"
  fi
  changed=$((changed + 1))
fi

# --- 2. enable each plugin in the set if not already installed+enabled --------
# `codex plugin list` groups rows per-marketplace; each plugin row's first column
# is the FULL selector `name@marketplace` (verified live: `himmel-ops@himmel`),
# and the status column reads "installed, enabled". Match the exact selector
# (so a same-named plugin in another marketplace can't false-match) AND enabled.
plugin_list="$("$CODEX" plugin list 2>/dev/null || true)"
for p in $PLUGINS; do
  sel="$p@$MARKET"
  if printf '%s\n' "$plugin_list" | awk -v s="$sel" '$1==s && index($0,"installed, enabled"){f=1} END{exit f?0:1}'; then
    echo "UNCHANGED   : $sel (installed, enabled)"
  else
    if [ "$DRY_RUN" = "1" ]; then
      echo "WOULD ADD   : $sel"
    else
      "$CODEX" plugin add "$sel" >/dev/null
      echo "CHANGED     : enabled $sel"
    fi
    changed=$((changed + 1))
  fi
done

# --- 3. qmd: the shared daemon, never upstream's per-thread stdio qmd --------
# Upstream's qmd@qmd plugin declares a stdio `qmd mcp` server, so every Codex
# thread starts a private runtime that skips the daemon's bearer token, egress
# gate and post-bump restart. Drop that plugin + its marketplace
# and point Codex at the daemon. Codex reads a bearer only from an env var NAME
# (no headers helper), so the token is never written to config.toml: the
# launching environment must export $QMD_TOKEN_ENV.
QMD_URL="${QMD_MCP_URL:-http://localhost:8181/mcp}"   # same override the daemon scripts read
QMD_TOKEN_ENV="QMD_HTTP_TOKEN"
QMD_PLUGIN="qmd@qmd"
QMD_MARKET="qmd"
if printf '%s\n' "$plugin_list" | awk -v s="$QMD_PLUGIN" '$1==s{f=1} END{exit f?0:1}'; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD REMOVE: plugin $QMD_PLUGIN (upstream stdio qmd)"
  else
    "$CODEX" plugin remove "$QMD_PLUGIN" >/dev/null
    echo "CHANGED     : removed plugin $QMD_PLUGIN (upstream stdio qmd)"
  fi
  changed=$((changed + 1))
fi
if "$CODEX" plugin marketplace list 2>/dev/null | awk -v n="$QMD_MARKET" '$1==n{f=1} END{exit f?0:1}'; then
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD REMOVE: marketplace '$QMD_MARKET' (upstream tobi/qmd)"
  else
    "$CODEX" plugin marketplace remove "$QMD_MARKET" >/dev/null
    echo "CHANGED     : removed marketplace '$QMD_MARKET' (upstream tobi/qmd)"
  fi
  changed=$((changed + 1))
fi
# Under --dry-run the plugin is still present, and it is what makes `mcp get qmd`
# answer, so the dry run reports the add on its own.
if [ "$DRY_RUN" != "1" ] && qmd_cfg="$("$CODEX" mcp get qmd 2>/dev/null)" && grep -qxF "  enabled: true" <<< "$qmd_cfg" && grep -qxF "  url: $QMD_URL" <<< "$qmd_cfg" && grep -qxF "  bearer_token_env_var: $QMD_TOKEN_ENV" <<< "$qmd_cfg"; then
  echo "UNCHANGED   : mcp server qmd -> $QMD_URL"
else
  if [ "$DRY_RUN" = "1" ]; then
    echo "WOULD ADD   : mcp server qmd -> $QMD_URL (bearer from \$$QMD_TOKEN_ENV)"
  else
    [ -n "${qmd_cfg:-}" ] && "$CODEX" mcp remove qmd >/dev/null   # a stale stdio/other-URL qmd entry
    "$CODEX" mcp add qmd --url "$QMD_URL" --bearer-token-env-var "$QMD_TOKEN_ENV" >/dev/null
    echo "CHANGED     : mcp server qmd -> $QMD_URL (bearer from \$$QMD_TOKEN_ENV)"
  fi
  changed=$((changed + 1))
fi

# Without the export Codex's qmd server answers 401 and qmd silently vanishes
# from Codex: warn with the exact launch-env line (path only, never the value).
if [ -z "${QMD_HTTP_TOKEN:-}" ]; then
  QMD_TOKEN_FILE="${QMD_HTTP_AUTH_FILE:-${QMD_HTTP_TOKEN_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/qmd/http-token}}"   # same resolution as qmd-auth-headers.sh
  echo "WARN        : $QMD_TOKEN_ENV is not set in this environment; Codex's qmd server needs it at launch or qmd answers 401."
  echo "              Add to the environment that launches Codex: export $QMD_TOKEN_ENV=\"\$(cat $(printf '%q' "$QMD_TOKEN_FILE"))\""
fi

# (No phase for third-party plugin hooks.json: codex < rust-v0.143.0 rejects a
# top-level `description` in them; installs pinned that low run
# scripts/codex/sanitize-plugin-hooks.sh by hand.)

echo ""
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY-RUN: $changed change(s) would be made. Re-run without --dry-run to apply."
elif [ "$changed" -eq 0 ]; then
  echo "OK: himmel already provisioned under Codex (nothing to do)."
else
  echo "OK: himmel provisioned under Codex ($changed change(s))."
  echo "    Restart Codex so the newly-enabled plugins load; new project hooks are"
  echo "    trust-hashed on first use (interactive Codex prompts once)."
fi
