#!/usr/bin/env bash
# scripts/cloud/parity-probe.sh — local-versus-cloud parity probe.
# Run the same script on the station and in a cloud session; diff the two
# outputs. Prints one `<item><TAB><value>` row per fact, grouped by section.
#
# READ-ONLY by construction: it reads settings, versions and the tree, pipes
# synthetic hook inputs into the guard scripts (a guard only evaluates and
# answers, it never runs the command it is shown), and sends bounded HEAD
# requests. It writes nothing, installs nothing and never calls Jira.
#
# Deny probes: each PreToolUse guard is fed one input it MUST refuse. The row
# is `guard:<name><TAB>DENY` when it refused (rc 2), `ALLOW` when it did not
# (a gap, or a bypass variable set in this shell), `ERR rc=<n>` otherwise. This
# proves the guard SCRIPT behaves in this environment; whether the harness
# fires it on a real tool call is the `hooks-wired` row plus a session's own
# refused call. Leg-only guards are probed with HIMMEL_CONSOLE_LEG=1.
#
# Usage: parity-probe.sh [--no-net]   (--no-net skips the egress probes)
# Test seam: HIMMEL_CLOUD_ROOT is the tree to probe (default: this script's repo).
set -uo pipefail

NET=1
case "${1:-}" in
  --no-net) NET=0 ;;
  -h|--help) sed -n '2,/^set -uo/p' "$0" | sed '$d'; exit 0 ;;
  "") ;;
  *) echo "parity-probe: unknown argument '$1' (try --help)" >&2; exit 2 ;;
esac

ROOT="${HIMMEL_CLOUD_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
TMO=""; command -v timeout >/dev/null 2>&1 && TMO=timeout
bounded() { if [ -n "$TMO" ]; then "$TMO" "$@"; else shift; "$@"; fi; }
have() { command -v "$1" >/dev/null 2>&1; }
row() { printf '%s\t%s\n' "$1" "$2"; }
section() { printf '\n## %s\n' "$1"; }
first_line() { head -n 1 | tr -d '\r'; }

# ---------------------------------------------------------------- environment
section environment
row where "$([ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && echo cloud || echo local)"
row CLAUDE_CODE_REMOTE "${CLAUDE_CODE_REMOTE:-<unset>}"
row os "$(uname -sr 2>/dev/null | first_line)"
row user "$(id -un 2>/dev/null)"
if have claude; then row claude-version "$(bounded 20 claude --version 2>&1 | first_line)"; else row claude-version "<absent>"; fi
row BASH_DEFAULT_TIMEOUT_MS "${BASH_DEFAULT_TIMEOUT_MS:-<unset>}"
row BASH_MAX_TIMEOUT_MS "${BASH_MAX_TIMEOUT_MS:-<unset>}"
row JIRA_PROJECT_KEY "${JIRA_PROJECT_KEY:-<unset>}"
row GH_TOKEN-set "$([ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] && echo yes || echo no)"
bypass=""
for v in EDIT_ON_MAIN_OK GIT_STASH_OK QMD_UNBOUNDED_OK HIMMEL_HOOK_INTEGRITY_BYPASS_OK; do
  [ -n "${!v:-}" ] && bypass="$bypass $v"
done
row bypass-env-set "${bypass:- none}"
if [ -f "$ROOT/scripts/cloud/check-env.sh" ]; then
  row check-env "$(bash "$ROOT/scripts/cloud/check-env.sh" 2>&1 | tr '\n' ';' | cut -c1-300)"
fi

# ------------------------------------------------------------------- settings
section settings
SET="$ROOT/.claude/settings.json"
if [ -f "$SET" ] && have jq; then
  row repo-settings "present"
  row hook-events "$(jq -r '.hooks // {} | to_entries | map("\(.key)=\(.value | length)") | join(",")' "$SET")"
  row hook-commands "$(jq -r '[.hooks // {} | .[] | .[] | .hooks[]?] | length' "$SET")"
  row permissions-allow "$(jq -r '.permissions.allow // [] | length' "$SET")"
  row permissions-deny "$(jq -r '.permissions.deny // [] | length' "$SET")"
  row permissions-ask "$(jq -r '.permissions.ask // [] | length' "$SET")"
  row deny-sha "$(jq -c '.permissions.deny // []' "$SET" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-12)"
  # every hook command that names a repo script must resolve to a file in this tree
  missing=""
  while IFS= read -r s; do
    [ -f "$ROOT/$s" ] || missing="$missing $s"
  done < <(jq -r '[.hooks // {} | .[] | .[] | .hooks[]?.command] | .[]' "$SET" | grep -oE 'scripts/[A-Za-z0-9_./-]+\.(sh|mjs|js|ts)' | sort -u)
  row hooks-wired "$([ -z "$missing" ] && echo "all-scripts-present" || echo "MISSING:$missing")"
else
  row repo-settings "<absent or jq missing>"
fi
USET="${HOME:-/nonexistent}/.claude/settings.json"
if [ -f "$USET" ] && have jq; then
  row user-settings "present hooks=$(jq -r '.hooks // {} | keys | join(",")' "$USET") deny=$(jq -r '.permissions.deny // [] | length' "$USET")"
else
  row user-settings "<none>"
fi
row project-CLAUDE.md "$([ -f "$ROOT/CLAUDE.md" ] && echo present || echo absent)"
row user-CLAUDE.md "$([ -f "${HOME:-/nonexistent}/.claude/CLAUDE.md" ] && echo present || echo absent)"

# -------------------------------------------------------------------- plugins
section plugins
PD="${HOME:-/nonexistent}/.claude/plugins"
if [ -d "$PD" ]; then
  row plugin-dir "present"
  if [ -f "$PD/installed_plugins.json" ] && have jq; then
    row plugins-installed "$(jq -r '.plugins // . | keys | join(",")' "$PD/installed_plugins.json" 2>/dev/null | cut -c1-300)"
  else
    row plugins-installed "$(find "$PD" -maxdepth 1 -mindepth 1 -exec basename {} \; 2>/dev/null | tr '\n' ',' | cut -c1-300)"  # gnu-ok: BSD find has -maxdepth/-mindepth/-exec
  fi
  row plugin-hook-files "$(find "$PD" -name hooks.json 2>/dev/null | wc -l | tr -d ' ')"
  if [ -f "$PD/installed_plugins.json" ] && have jq; then
    row plugins-installed-count "$(jq -r '.plugins // . | keys | length' "$PD/installed_plugins.json" 2>/dev/null)"
  else
    row plugins-installed-count "$(find "$PD" -maxdepth 1 -mindepth 1 | wc -l | tr -d ' ')"  # gnu-ok: BSD find has -maxdepth/-mindepth
  fi
else
  row plugin-dir "<absent>"
fi
row marketplace-plugins "$(find "$ROOT/marketplace/plugins" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"  # gnu-ok: BSD find has -maxdepth/-mindepth

# --------------------------------------------------------------- guard probes
section guards
H="$ROOT/scripts/hooks"
probe() { # probe <guard-script> <json> [VAR=1 ...]: DENY / ALLOW / ERR on rc
  local g="$1" json="$2"; shift 2
  [ -f "$H/$g" ] || { row "guard:${g%.sh}" "MISSING"; return; }
  local rc=0
  printf '%s' "$json" | env "$@" ${TMO:+"$TMO" 20} bash "$H/$g" >/dev/null 2>&1 || rc=$?
  case "$rc" in 2) row "guard:${g%.sh}" DENY ;; 0) row "guard:${g%.sh}" ALLOW ;; *) row "guard:${g%.sh}" "ERR rc=$rc" ;; esac
}
bash_in() { printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }
probe block-git-stash.sh "$(bash_in 'git stash')" -u GIT_STASH_OK
probe block-destructive-commands.sh "$(bash_in 'rm -rf /')"
probe block-read-secrets.sh "$(bash_in 'cat ~/.ssh/id_rsa')"
probe block-rogue-claude-schedule.sh "$(bash_in 'schtasks /create /tn X /tr claude.exe /sc ONCE')"
probe block-bare-qmd-query.sh "$(bash_in 'qmd '"query"' foo')" -u QMD_UNBOUNDED_OK
probe block-edit-live-settings.sh "{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"${HOME:-/root}/.claude/settings.json\",\"content\":\"{}\"}}"
probe block-leg-askuserquestion.sh '{"tool_name":"AskUserQuestion","tool_input":{}}' HIMMEL_CONSOLE_LEG=1
probe guard-leg-wakeup.sh '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":60}}' HIMMEL_CONSOLE_LEG=1
probe redirect-webfetch-walled-hosts.sh '{"tool_name":"WebFetch","tool_input":{"url":"https://x.com/a/status/1"}}'

# ----------------------------------------------- pre-commit + attestation gates
section gates
if have pre-commit; then row pre-commit "$(pre-commit --version 2>&1 | first_line)"; else row pre-commit "<absent>"; fi
HOOKDIR="$(git -C "$ROOT" rev-parse --git-path hooks 2>/dev/null)"
case "$HOOKDIR" in /*) ;; *) HOOKDIR="$ROOT/$HOOKDIR" ;; esac
hp="$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)"
row core.hooksPath "${hp:-<unset>}"
for stage in pre-commit commit-msg pre-push; do
  if [ -x "$HOOKDIR/$stage" ]; then
    # an executable hook that never mentions pre-commit is another owner's, not our gate
    if grep -q 'pre-commit' "$HOOKDIR/$stage" 2>/dev/null; then row "git-hook:$stage" "installed"; else row "git-hook:$stage" "other-owner (does not invoke pre-commit)"; fi
  else row "git-hook:$stage" "NOT-INSTALLED"; fi
done
row pre-commit-config "$([ -f "$ROOT/.pre-commit-config.yaml" ] && echo "present hooks=$(grep -c '^ *- id:' "$ROOT/.pre-commit-config.yaml")" || echo absent)"
for g in check-commit-msg.sh check-platforms-tested.sh; do
  row "attest:$g" "$([ -f "$H/$g" ] && echo present || echo MISSING)"
done
# does the commit-msg gate refuse a message with no ticket ID? (reads the file, writes nothing)
if [ -f "$H/check-commit-msg.sh" ]; then
  mf="$(mktemp "${TMPDIR:-/tmp}/parity-msg.XXXXXX")" || mf=""
  if [ -n "$mf" ]; then
    printf 'feat: no ticket id here\n' > "$mf"
    rc=0; bounded 20 bash "$H/check-commit-msg.sh" "$mf" >/dev/null 2>&1 || rc=$?
    # the gate refuses with exactly rc 1; any other nonzero (timeout 124, not
    # runnable 126/127, killed 137/143, crash 139 ...) means it never decided
    case "$rc" in
      0) verdict=ALLOW ;;
      1) verdict=DENY ;;
      *) verdict=ERR ;;
    esac
    row "attest:commit-msg-refuses-no-ticket" "$verdict rc=$rc"
    rm -f "$mf"
  else
    row "attest:commit-msg-refuses-no-ticket" "ERR mktemp failed"
  fi
fi
row cr-ledger-scripts "$([ -f "$ROOT/scripts/cr/clear-review-marker.sh" ] && echo present || echo MISSING)"
row pr-check-skill "$([ -e "$ROOT/.claude/skills/pr-check" ] || [ -e "$ROOT/.claude/commands/pr-check.md" ] || [ -e "$ROOT/marketplace/plugins/himmel-ops/skills/pr-check" ] && echo present || echo not-found)"

# --------------------------------------------------------------------- tools
section tools
ver() { # ver <label> <cmd> [args...]
  local label="$1" c="$2"; shift 2
  if have "$c"; then row "tool:$label" "$(bounded 20 "$c" "$@" 2>&1 | first_line | cut -c1-80)"; else row "tool:$label" "<absent>"; fi
}
ver bun bun --version
ver node node --version
ver npm npm --version
ver python3 python3 --version
ver jq jq --version
ver gh gh --version
ver git git --version
ver shellcheck shellcheck --version
ver at at -V
ver graphify graphify --version
# qmd installed by qmd-bin.sh may have no shim on PATH: resolve it
# the way setup-env.sh does, through qmd-bounded.sh, before calling it absent.
QMD_OK=0
if have qmd; then
  ver qmd qmd --version; QMD_OK=1
elif [ -f "$ROOT/scripts/lib/qmd-bounded.sh" ] && QV="$(QMD_TIMEOUT_SECS=30 bounded 40 bash "$ROOT/scripts/lib/qmd-bounded.sh" --version 2>/dev/null | first_line | cut -c1-60)" && [ -n "$QV" ]; then
  row tool:qmd "$QV (not on PATH, via qmd-bounded.sh)"; QMD_OK=1
else
  row tool:qmd "<absent>"
fi
GPIN=""
[ -f "$ROOT/scripts/lib/graphify-bin.sh" ] && GPIN="$(grep -oE 'GRAPHIFY_VERSION:-[0-9][0-9A-Za-z.+-]*[0-9A-Za-z]' "$ROOT/scripts/lib/graphify-bin.sh" | head -n 1 | sed 's/.*:-//')"
row graphify-pin "${GPIN:-<none>}"
GCUR="$(bounded 20 graphify --version 2>/dev/null | first_line | grep -oE '[0-9]+(\.[0-9]+)+(\+himmel\.[0-9]+)?' | head -n 1)"
if [ -z "$GCUR" ] || [ -z "$GPIN" ]; then row graphify-at-pin "n/a"; elif [ "$GCUR" = "$GPIN" ]; then row graphify-at-pin "yes"; else row graphify-at-pin "NO installed=$GCUR pin=$GPIN"; fi
row graphify-graph "$([ -f "$ROOT/graphify-out/graph.json" ] && echo present || echo absent)"
if [ "$QMD_OK" -eq 1 ] && [ -f "$ROOT/scripts/lib/qmd-bounded.sh" ]; then
  row qmd-collections "$(QMD_TIMEOUT_SECS=30 bash "$ROOT/scripts/lib/qmd-bounded.sh" collection list 2>/dev/null | sed -n 's/^\([A-Za-z0-9_-]*\) (qmd:.*/\1/p' | tr '\n' ',' | cut -c1-200)"
else
  row qmd-collections "<n/a>"
fi
row jira-dist "$([ -f "$ROOT/scripts/jira/dist/index.js" ] && echo built || echo absent)"
row obsidian-deps "$([ -d "$ROOT/marketplace/plugins/obsidian-triage/tools/node_modules" ] && echo present || echo absent)"

# ---------------------------------------------------------------- jira access
section jira
row jira-token-set "$([ -n "${JIRA_API_TOKEN:-}${JIRA_TOKEN:-}" ] && echo yes || echo no)"
row jira-base-url-set "$([ -n "${JIRA_BASE_URL:-}" ] && echo yes || echo no)"
row jira-cli "$([ -f "$ROOT/scripts/jira/dist/index.js" ] && echo built || echo absent)"
row atlassian-mcp-guard "$([ -f "$H/block-backend-tier.sh" ] && echo present || echo MISSING)"
row jira-path "$([ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && echo "Atlassian MCP connector (no token in the VM)" || echo "jira CLI (primary checkout dist)")"

# --------------------------------------------------------------------- egress
section egress
EM="$ROOT/scripts/guardrails/egress-matrix.json"
row egress-matrix "$([ -f "$EM" ] && { sha256sum "$EM" 2>/dev/null || shasum -a 256 "$EM"; } | cut -c1-12 || echo MISSING)"
if [ "$NET" -eq 1 ] && have curl; then
  for u in https://github.com https://pypi.org https://registry.npmjs.org https://archive.ubuntu.com https://example.com; do
    # GET, not HEAD: the cloud GitHub proxy answers a HEAD on github.com with 400
    code="$(bounded 10 curl -s -o /dev/null -m 8 -w '%{http_code}' "$u" 2>/dev/null)"
    row "net:${u#https://}" "${code:-000}"
  done
else
  row net "skipped"
fi
