#!/usr/bin/env bash
# one-shot API-key launcher.
# Runs ONE print-mode call billed to the API credit of HIMMEL_API_ACCOUNT, with
# auth isolation, a roster check, the API bank gate and a reserve/settle ledger entry.
# Deliberately NOT native-auth-pin: this lane is the API-key exception, so it
# removes the other credential sources itself instead of pinning native auth.
#
# Usage: claude-api.sh -p [prompt] --model M --permission-mode default|plan|acceptEdits|dontAsk|auto \
#                      --max-budget-usd N [--output-format json] [--effort E]  (no other flags)
# Env:   HIMMEL_API_LANE=on  HIMMEL_API_ACCOUNT=A|B|auto  [HIMMEL_API_KEY_ID=<roster id>]
#        ANTHROPIC_API_KEY, or else <state_dir>/key-<account>.env (mode 600); never printed, logged,
#        exported or passed on a command line. auto = the earliest-expiring grant with room for the budget.
#        [HIMMEL_API_TOOLS=<comma list>]  opt-in tool grant, a subset of Read,Edit,Write,Glob,Grep,Bash; unset/empty = tool-free (default)
#        [HIMMEL_API_KIND=<label>] run kind for the cache report (eval|judge|bulk|critic|graphify|cull|probe; a caller sets its own, default other)
#        [HIMMEL_API_CACHE_TTL=5m|1h] prompt-cache lifetime of the call (default 5m)
#        [HIMMEL_API_CALL_TIMEOUT_S=<seconds>] the launcher stops a call at this age, and the credit-state sweep releases a reservation older than it plus the five-second kill grace (default 3600)
#        [HIMMEL_API_BRANCH=<branch> HIMMEL_API_HEAD=<sha> HIMMEL_API_PR=<number>] the work the call belongs to; written to
#        the launch record so a cost can be joined to a PR by key (absent = empty / null)
#        [HIMMEL_API_FALLBACK=off] switches the subscription fallback below off for this caller (default on)
#        [HIMMEL_API_ALERT_CMD=<path>] test seam: the alert sender, run with TG_* in its env (default the Telegram
#        notification sender, scripts/telegram/session-status.ts)  [HIMMEL_API_ALERT_DIR=<dir>] rate-limit stamps
# OFF by default. Failure path (docs/internals/api-lane.md): a refusal (exit 2), a rejected account (exit 6)
#        or any other non-zero call exit still happens first, then sends ONE Telegram alert (kind, account, class,
#        exit code, one-line reason, never the key; one per kind and class per hour), then re-runs the same prompt
#        once as a subscription `claude -p`: native auth (every API-key variable removed), the same model,
#        permission mode, tool grant and budget cap, --output-format json. The fallback runs only when the native
#        usage preflight says PROCEED, BANK-STALE or BANK-UNKNOWN; SKIPPED-BANK or SKIPPED-FLEET skips it and the
#        alert says so. A prompt on stdin is kept in a mode-600 scratch file (removed on every exit) that the API call
#        reads and the fallback replays byte for byte; it is never printed, logged or put in an argv. A malformed request
#        never falls back. A call granted
#        Edit, Write or Bash falls back only from a refusal before any request (exit 2), never from a run that started
#        (exit 6 included), which may have half-done its edits. The fallback writes its own launch record row (lane sub-fallback).
# Exit: the call's own code; 2 a refusal before any request; 6 the provider answered "Credit balance is too low" or
#       "Invalid API key" (the account is marked, and a looping caller stops instead of retrying it).
#       When the fallback ran, its own exit code replaces any of these.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_BIN="${HIMMEL_API_CLAUDE_BIN:-claude}"

# --- failure path state: set before any refusal can fire ---
KEY="" STATE_DIR="" WORKER_SESSION_NAME="" OUT="" FB_OUT="" PROMPT_FILE="" NO_FB="" FAILING_OVER=0 STOPPED=0
KIND_SAFE="${HIMMEL_API_KIND:-other}"
case "$KIND_SAFE" in ""|*[!A-Za-z0-9._-]*) KIND_SAFE=other ;; esac
JOB_SAFE="${HIMMEL_API_JOB_ID:-}"
case "$JOB_SAFE" in *[!A-Za-z0-9._:-]*) JOB_SAFE="" ;; esac
# branch is JSON-escaped (control characters dropped) so it still matches the ledger's branch; head must be 7-64 hex or is empty;
# a PR that is not a canonical positive decimal is null.
R_BRANCH="$(printf '%s' "${HIMMEL_API_BRANCH:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
R_HEAD=""
[[ "${HIMMEL_API_HEAD:-}" =~ ^[0-9A-Fa-f]{7,64}$ ]] && R_HEAD="$HIMMEL_API_HEAD"
R_PR=""
[[ "${HIMMEL_API_PR:-}" =~ ^[1-9][0-9]*$ ]] && R_PR="$HIMMEL_API_PR"

# Release the fleet-slot reservation at call end, only when its pid file names this shell.
# shellcheck disable=SC2329 # invoked from the EXIT trap string below and before a fallback
release_slot() {
  [ -n "$WORKER_SESSION_NAME" ] || return 0
  # shellcheck source=scripts/lib/fleet-reservation-key.sh
  . "$REPO/scripts/lib/fleet-reservation-key.sh" 2>/dev/null || return 0
  local slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}" key dir
  for key in "$(fleet_reservation_key "$WORKER_SESSION_NAME")" "$(fleet_hash_key "$WORKER_SESSION_NAME")"; do
    dir="$slots/$key"
    [ "$(cat "$dir/pid" 2>/dev/null)" = "$$" ] && rm -rf "$dir"
  done
  return 0
}
trap 'rm -f "$OUT" "$FB_OUT" "$PROMPT_FILE" ${OUT:+"$OUT.timeout"}; release_slot' EXIT

# one line for the alert: the key (ours or any the caller holds) and anything key-shaped become [key], no control characters
redact() {
  local s="$1" v
  [ -z "$KEY" ] || s="${s//"$KEY"/[key]}"
  for v in ANTHROPIC_API_KEY ANTHROPIC_ORG_A_KEY ANTHROPIC_ORG_B_KEY LQ_API_KEY; do
    [ -z "${!v:-}" ] || s="${s//"${!v}"/[key]}"
  done
  s="$(printf '%s' "$s" | sed -E 's/sk-ant-[A-Za-z0-9_-]+/[key]/g' | tr '\000-\037' ' ')"
  printf '%s' "${s:0:200}"
}

# ONE alert per kind and class per hour, through the existing Telegram notification sender; never blocks the fallback
send_alert() {
  local class="$1" rc="$2" reason="$3" decision="$4" dir stamp account msg repo_name env_root
  dir="${HIMMEL_API_ALERT_DIR:-${HOME:-/tmp}/.himmel/state/api-lane-alerts}"
  stamp="$dir/$KIND_SAFE.$class"
  mkdir -p "$dir" 2>/dev/null || return 0
  if [ -n "$(find "$stamp" -maxdepth 0 -mmin -60 2>/dev/null)" ]; then # gnu-ok: BSD find has -maxdepth/-mmin too
    echo "claude-api: alert: one already sent for $KIND_SAFE $class within the hour" >&2
    return 0
  fi
  case "${HIMMEL_API_ACCOUNT:-}" in A|B|auto) account="$HIMMEL_API_ACCOUNT" ;; *) account="?" ;; esac
  msg="kind $KIND_SAFE, account $account, $class (exit $rc): $(redact "$reason"); fallback: $(redact "$decision")"
  # the caller's repo names the message, so a salus caller gets the sender's content-free line
  repo_name="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")"
  env_root="$(cd "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/.." 2>/dev/null && pwd)"
  (
    for v in $(compgen -e); do
      case "$v" in ANTHROPIC_*|LQ_API_*|CLAUDE_CODE_OAUTH_TOKEN) unset "$v" ;; esac
    done
    export TG_REPO_NAME="$repo_name" TG_NOTIFICATION_TYPE="api-lane $class" TG_MESSAGE="$msg"
    [ -z "${HIMMEL_API_ALERT_CMD:-}" ] || exec "$HIMMEL_API_ALERT_CMD" notification
    # an explicitly empty chat id is a deliberate suppression and never falls back to .env
    if [ "${TELEGRAM_GROUP_CHAT_ID+set}" = set ] && [ -z "$TELEGRAM_GROUP_CHAT_ID" ]; then exit 0; fi
    # shellcheck source=scripts/lib/load-dotenv.sh
    { [ -r "$REPO/scripts/lib/load-dotenv.sh" ] && . "$REPO/scripts/lib/load-dotenv.sh"; } 2>/dev/null &&
      load_dotenv --root "${env_root:-$REPO}" TELEGRAM_GROUP_CHAT_ID 2>/dev/null
    [ -n "${TELEGRAM_GROUP_CHAT_ID:-}" ] || exit 0
    export TELEGRAM_GROUP_CHAT_ID
    command -v bun >/dev/null 2>&1 || exit 0
    if command -v timeout >/dev/null 2>&1; then exec timeout 30 bun run "$REPO/scripts/telegram/session-status.ts" notification; fi
    exec bun run "$REPO/scripts/telegram/session-status.ts" notification
  ) </dev/null >/dev/null 2>&1 && touch "$stamp" 2>/dev/null
  return 0
}

# the native bank decides the fallback: the subscription usage preflight, never the API gate
sub_preflight() {
  env -u ANTHROPIC_API_KEY -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY -u LQ_API_KEY \
    -u CADENCE_USAGE_LAUNCH -u CADENCE_USAGE_CALLER_PID -u WORKER_SESSION_LANE \
    CADENCE_USAGE_LANE=native CADENCE_USAGE_WORKER="sub-fallback:$KIND_SAFE:${JOB_SAFE:-$$}" \
    bash "$REPO/scripts/lib/usage-preflight.sh" </dev/null | tail -n 1
}

# where launches.jsonl lives: the roster's state dir, else beside the configured ledger (as shift-spend reads it)
launch_dir() {
  [ -z "$STATE_DIR" ] || { printf '%s' "$STATE_DIR"; return; }
  node -e 'const fs=require("fs"),p=require("path");try{const l=JSON.parse(fs.readFileSync(process.argv[1],"utf8")).ledger_path;if(typeof l==="string"&&p.isAbsolute(l))process.stdout.write(p.dirname(l))}catch{}' \
    "${HIMMEL_API_CREDIT_CONFIG:-${HOME:-/tmp}/.himmel/state/api-credit/config.json}" 2>/dev/null | grep . ||
    printf '%s' "${HOME:-/tmp}/.himmel/state/api-credit"
}

# the fallback's row: lane sub-fallback, no API cost (cost_usd empty = unpriced), the subscription's own reported cost aside
record_fallback() {
  local class="$1" api_rc="$2" rc="$3" outcome=sub-fallback sub_cost budget="" account="" dir
  [ "$rc" -eq 0 ] || outcome=sub-fallback-failed
  sub_cost="$(node "$REPO/scripts/api-lane/outcome.mjs" "$FB_OUT" 2>/dev/null)"
  [[ "$BUDGET" =~ ^[0-9]+(\.[0-9]+)?$ ]] && budget="$BUDGET"
  case "${HIMMEL_API_ACCOUNT:-}" in A|B|auto) account="$HIMMEL_API_ACCOUNT" ;; esac
  dir="$(launch_dir)"
  mkdir -p "$dir" 2>/dev/null
  printf '{"ts":"%s","job_id":"%s","account":"%s","lane":"sub-fallback","model":"%s","budget_usd":"%s","outcome":"%s","cost_usd":"","sub_cost_usd":"%s","rc":%s,"api_rc":%s,"api_class":"%s","kind":"%s","input_tokens":null,"cache_creation_tokens":null,"cache_read_tokens":null,"branch":"%s","head":"%s","pr":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB_SAFE" "$account" "$MODEL" "$budget" "$outcome" "$sub_cost" "$rc" "$api_rc" \
    "$class" "$KIND_SAFE" "$R_BRANCH" "$R_HEAD" "${R_PR:-null}" \
    >>"$dir/launches.jsonl" 2>/dev/null || echo "claude-api: warning: fallback launch record not written" >&2
}

# the same prompt once more on the subscription: native auth only, nothing of the API lane carried in
run_fallback() {
  local class="$1" api_rc="$2" fb_pid fb_rc
  FB_OUT="$(mktemp "${TMPDIR:-/tmp}/claude-api-fb.XXXXXX")" || { echo "claude-api: fallback: no scratch file" >&2; return 1; }
  fallback_child() {
    # shellcheck source=scripts/lib/native-auth-pin.sh
    { [ -r "$REPO/scripts/lib/native-auth-pin.sh" ] && . "$REPO/scripts/lib/native-auth-pin.sh"; } 2>/dev/null || exit 2
    native_auth_pin_env || exit 2
    local v
    for v in $(compgen -e); do
      case "$v" in
        CLAUDE_CODE_OAUTH_TOKEN) ;;
        CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_CODE_*|HIMMEL_API_*|LQ_API_*|HIMMEL_DOTENV_FILE|HIMMEL_CLAUDE_LANE) unset "$v" ;;
      esac
    done
    # LAUNCH GATE (native-auth-pin.sh header): keyword-only, no API-key name or value survives into the call
    [[ -z "${!ANTHROPIC_*}${!anthropic_*}${!CLAUDE_CODE_USE_*}${!claude_code_use_*}${!LQ_API_*}" ]] || exit 2
    if [ -n "$KEY" ]; then
      for v in $(compgen -e); do [[ "${!v}" != *"$KEY"* ]] || exit 2; done
    fi
    KEY=""
    export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1
    # subscription fallback after an API-lane failure; usage preflight above, explicit --permission-mode
    exec "$CLAUDE_BIN" "${ARGS[@]}" --model "$MODEL" --permission-mode "$MODE" \
      "${TOOL_ARGS[@]}" --max-budget-usd "$BUDGET" --output-format json ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} >"$FB_OUT"
  }
  # a stdin prompt that was buffered replays from the scratch file; a refusal before the buffer has not read stdin, so
  # a piped prompt still reaches the fallback; an argv prompt needs no stdin
  if [ -n "$PROMPT_FILE" ]; then fallback_child <"$PROMPT_FILE" 3<&- &
  elif [ "$class" = refused ]; then fallback_child <&0 3<&- &
  else fallback_child </dev/null 3<&- & fi
  fb_pid=$!
  # a stop during the fallback still leaves its launch record: the subscription run may have drawn usage
  trap 'kill -TERM "$fb_pid" 2>/dev/null; wait "$fb_pid" 2>/dev/null; record_fallback "$class" "$api_rc" 143; exit 143' TERM INT HUP
  wait "$fb_pid"
  fb_rc=$?
  trap '' TERM INT HUP
  record_fallback "$class" "$api_rc" "$fb_rc"
  cat "$FB_OUT"
  exit "$fb_rc"
}

# the failure path: decide, alert once, then fall back (never returns when the fallback ran)
fail_over() {
  local rc="$1" class="$2" reason="$3" decision token="" run=0
  [ "$FAILING_OVER" = 0 ] || return 0
  FAILING_OVER=1
  if [ "${HIMMEL_API_FALLBACK:-on}" = off ]; then
    decision="off (HIMMEL_API_FALLBACK=off)"
  elif [ -n "$NO_FB" ]; then
    decision="not run: $NO_FB"
  elif [ "$class" != refused ] && [[ ",$ALLOWED_TOOLS," =~ ,(Edit|Write|Bash), ]]; then
    # a run that started may have half-done its edits (a rejection can come on a later turn); only a refusal precedes it
    decision="not run: the call could change files ($ALLOWED_TOOLS), so a run that started is never replayed"
  else
    token="$(sub_preflight)"
    case "$token" in
      PROCEED|BANK-STALE|BANK-UNKNOWN) run=1; decision="running on the subscription (preflight $token)" ;;
      *) decision="skipped: the subscription preflight said ${token:-nothing}" ;;
    esac
  fi
  # the preflight and the alert take time: a stop that lands in them still ends the failure path
  # ponytail: the check before the alert has no test seam in the usage preflight, upgrade path: HIMMEL-8657
  [ "$STOPPED" = 0 ] || { echo "claude-api: stopped by its caller during the failure path; no alert, no fallback" >&2; return 0; }
  send_alert "$class" "$rc" "$reason" "$decision"
  echo "claude-api: fallback: $decision" >&2
  [ "$run" = 1 ] || return 0
  [ "$STOPPED" = 0 ] || { echo "claude-api: stopped by its caller; the fallback was not run" >&2; return 0; }
  release_slot
  run_fallback "$class" "$rc"
}

refuse() { echo "claude-api: refused: $*" >&2; fail_over 2 refused "$*"; exit 2; }

# --- argument policy: print mode only, explicit permission mode, model and budget ---
# Parsed before any other check, so the failure path has the request in hand; the first error is refused below,
# in its old place (after the lane and provider checks).
PRINT=0 MODE="" MODEL="" BUDGET="" FORMAT="" PARSE_ERR="" HAS_PROMPT=0
ARGS=()
while [ "$#" -gt 0 ] && [ -z "$PARSE_ERR" ]; do
  a="$1"; shift
  # Allowlist: only -p/--print, --model, --permission-mode, --max-budget-usd, --output-format, --effort and a positional
  # prompt reach claude (the launcher adds its own --tools/--allowedTools). Any other argument starting with a dash is
  # refused whatever its spelling or attached =value, so a flag claude adds later is closed by default. A @file
  # argument is an args file, which could carry any flag.
  case "$a" in @*) PARSE_ERR="an @argsfile argument is not allowed on the api lane"; continue ;; esac
  case "$a" in
    -p|--print) PRINT=1; ARGS+=("$a"); continue ;;
    --) PARSE_ERR="the -- argument terminator would turn the enforced options into positionals"; continue ;;
    --permission-mode|--model|--max-budget-usd|--output-format|--effort)
      [ "$#" -gt 0 ] || { PARSE_ERR="$a needs a value"; continue; }
      val="$1"; shift ;;
    --permission-mode=*|--model=*|--max-budget-usd=*|--output-format=*|--effort=*)
      val="${a#*=}"; a="${a%%=*}" ;;
    -*) PARSE_ERR="flag ${a%%=*} is not allowed on the api lane"; continue ;;
    *) ARGS+=("$a"); HAS_PROMPT=1; continue ;;
  esac
  case "$a" in
    --permission-mode) case "$val" in
                         default|plan|acceptEdits|dontAsk|auto) MODE="$val" ;;
                         *) PARSE_ERR="permission mode is not on the api lane allowlist (default, plan, acceptEdits, dontAsk, auto; bypassPermissions is never allowed)" ;;
                       esac ;;
    --model) case "$val" in ""|-*) PARSE_ERR="--model needs a value not starting with a dash"; continue ;; esac
             MODEL="$val" ;;
    --max-budget-usd) BUDGET="$val" ;;
    --output-format) FORMAT="$val" ;;
    --effort) case "$val" in ""|-*|*[!A-Za-z0-9._-]*) PARSE_ERR="--effort needs a value of [A-Za-z0-9._-] not starting with a dash"; continue ;; esac
              ARGS+=(--effort "$val") ;;
  esac
done
if [ -z "$PARSE_ERR" ]; then
  if [ "$PRINT" != 1 ]; then PARSE_ERR="only -p/--print runs are allowed"
  elif [ -z "$MODE" ]; then PARSE_ERR="--permission-mode is required"
  elif [ -z "$MODEL" ]; then PARSE_ERR="--model is required"
  elif [[ "$MODEL" == *[!A-Za-z0-9._:/@-]* ]]; then PARSE_ERR="--model has characters outside [A-Za-z0-9._:/@-]"
  elif [ -z "$BUDGET" ]; then PARSE_ERR="--max-budget-usd is required"
  else case "$FORMAT" in ""|json) ;; *) PARSE_ERR="--output-format must be json" ;; esac
  fi
fi

# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (what keeps the key out of Bash-tool children) forces
# permission mode "default" whatever --permission-mode a caller passes (the eval passes auto), and in -p that
# denies Edit/Write/Bash unless declared here. The scrub is the bwrap sandbox, so it cannot be dropped; this
# allowance is the fixture-work tool set, the sandbox bounds Bash, and callers cannot add to or replace it.
# --allowedTools only preapproves; --tools is what limits the tools claude may use at all.
# the lane is tool-free by default. GRANT_CEILING is the most a caller can ever name; a caller opts in
# with HIMMEL_API_TOOLS=<comma subset of the ceiling>, and an unset or empty variable is a tool-free call. Anything
# outside the ceiling (a wildcard, Bash(*), an mcp__ tool), or a malformed list, is refused. Hooks are off on this
# lane, so every tool a caller names is one no PreToolUse guardrail can stop: name the fewest.
# Built here, before any refusal, so a fallback carries the same grant; a bad list is refused in its old place below.
GRANT_CEILING="Read,Edit,Write,Glob,Grep,Bash"
ALLOWED_TOOLS="" GRANT_ERR=""
if [ -n "${HIMMEL_API_TOOLS:-}" ]; then
  case "$HIMMEL_API_TOOLS" in ,*|*,|*,,*) GRANT_ERR="HIMMEL_API_TOOLS has an empty entry" ;; esac
  IFS=, read -ra WANT <<< "$HIMMEL_API_TOOLS"
  for t in "${WANT[@]}"; do
    [ -z "$GRANT_ERR" ] || break
    case ",$GRANT_CEILING," in *",$t,"*) ;; *) GRANT_ERR="HIMMEL_API_TOOLS may only name tools from the grant ceiling ($GRANT_CEILING)"; break ;; esac
    ALLOWED_TOOLS="${ALLOWED_TOOLS:+$ALLOWED_TOOLS,}$t"
  done
fi
TOOL_ARGS=(--tools "$ALLOWED_TOOLS")
# cwd, platform, memory paths and git status ride in the first user message instead of the system prompt,
# so every run of a kind shares one system-prompt prefix whatever directory or branch it started in.
# No caller can be granted an mcp__ tool, so no call loads an MCP server: with hooks off, an ambient-allowed MCP
# tool would otherwise run.
EXTRA_ARGS=(--exclude-dynamic-system-prompt-sections --strict-mcp-config)
[ -z "$ALLOWED_TOOLS" ] || TOOL_ARGS+=(--allowedTools "$ALLOWED_TOOLS")

# only the auto route below may relax the credit-reading requirement; a caller's value never does
unset HIMMEL_API_SNAPSHOT_OPTIONAL

# a malformed request is the caller's bug: never re-run on the subscription, whichever refusal comes first;
# each is still refused in its own place below
BAD_REQ="$PARSE_ERR$GRANT_ERR"
case "${HIMMEL_API_KIND:-other}" in *[!A-Za-z0-9._-]*) BAD_REQ=1 ;; esac
case "${HIMMEL_API_CACHE_TTL:-5m}" in 5m|1h) ;; *) BAD_REQ=1 ;; esac
case "${HIMMEL_API_JOB_ID:-x}" in *[!A-Za-z0-9._:-]*) BAD_REQ=1 ;; esac
[ -z "$BAD_REQ" ] || NO_FB="the request itself was refused"

# --- lane opt-in and credentials (presence checks only) ---
[ "${HIMMEL_API_LANE:-}" = "on" ] || refuse "api lane is OFF (set HIMMEL_API_LANE=on)"
case "${HIMMEL_API_ACCOUNT:-}" in A|B|auto) ;; *) refuse "HIMMEL_API_ACCOUNT must be A or B (or auto)" ;; esac
[ "$HIMMEL_API_ACCOUNT" != auto ] || [ -z "${ANTHROPIC_API_KEY:-}" ] ||
  refuse "auto routing reads the per-account key files; a caller ANTHROPIC_API_KEY cannot follow the pick"

# --- conflicting providers outrank the key or bill elsewhere: refuse, never guess ---
for v in CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
  [ -z "${!v:-}" ] || refuse "conflicting provider flag $v"
done
[ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] || refuse "conflicting provider ANTHROPIC_AUTH_TOKEN"
case "${HIMMEL_CLAUDE_LANE:-}" in ""|native) ;; *) refuse "conflicting lane HIMMEL_CLAUDE_LANE=$HIMMEL_CLAUDE_LANE" ;; esac

[ -z "$PARSE_ERR" ] || refuse "$PARSE_ERR"

# the run kind labels the launch record (cache-report.mjs groups by it); the TTL is the main-conversation
# cache lifetime. An API-key call gets 5m unless told otherwise, so the launcher always states the choice itself.
KIND="${HIMMEL_API_KIND:-other}"
case "$KIND" in ""|*[!A-Za-z0-9._-]*) refuse "HIMMEL_API_KIND has characters outside [A-Za-z0-9._-]" ;; esac
CACHE_TTL="${HIMMEL_API_CACHE_TTL:-5m}"
case "$CACHE_TTL" in 5m|1h) ;; *) refuse "HIMMEL_API_CACHE_TTL must be 5m or 1h" ;; esac

# --- auto = the grant that expires first among accounts with room for the whole budget ---
if [ "$HIMMEL_API_ACCOUNT" = auto ]; then
  PICK="$(node "$REPO/scripts/lib/api-credit-state.mjs" pick --usd "$BUDGET")"
  case "$PICK" in *'"verdict":"PROCEED"'*) ;; *) refuse "auto routing: no account has room for the budget ($PICK)" ;; esac
  # an absent or old credit reading never blocks an auto route: the per-call budget bounds each call, our own estimate
  # only orders the accounts, Anthropic's own credit answer decides the rest, and a credit-exhausted answer rotates (see below)
  export HIMMEL_API_SNAPSHOT_OPTIONAL=1
  case "$PICK" in *'"snapshot_stale":true'*)
    echo "claude-api: WARN: no fresh credit reading; routing on our own spend estimate, the per-call budget bounds this call and Anthropic's credit answer decides" >&2 ;;
  esac
  case "$PICK" in *'"over_estimate":true'*)
    echo "claude-api: WARN: our own spend estimate has no room left on either account; the call goes on and the API's credit answer decides" >&2 ;;
  esac
  HIMMEL_API_ACCOUNT="$(printf '%s' "$PICK" | sed -n 's/.*"account":"\([AB]\)".*/\1/p')"
  [ -n "$HIMMEL_API_ACCOUNT" ] || refuse "auto routing returned no account"
fi

# --- roster: the selector must map to the credential's recorded key id ---
ROSTER="$(node "$REPO/scripts/api-lane/roster.mjs")" || refuse "roster: ${ROSTER#reason=}"
ROSTER_KEY="" ROSTER_ORG="" ROSTER_CYCLE=""
while IFS='=' read -r k v; do
  case "$k" in
    key_id) ROSTER_KEY="$v" ;; organization_id) ROSTER_ORG="$v" ;;
    cycle_id) ROSTER_CYCLE="$v" ;; state_dir) STATE_DIR="$v" ;;
  esac
done <<EOF
$ROSTER
EOF
[ -n "$ROSTER_KEY" ] || refuse "roster has no key_id for account $HIMMEL_API_ACCOUNT"

# --- key: a caller key must name its roster id; otherwise the account's own key file beside the ledger ---
# the key is held in a shell variable and handed only to claude's env below, never exported.
KEY="${ANTHROPIC_API_KEY:-}"
if [ -n "$KEY" ]; then
  [ -n "${HIMMEL_API_KEY_ID:-}" ] || refuse "HIMMEL_API_KEY_ID is absent"
else
  KEY_FILE="$STATE_DIR/key-$HIMMEL_API_ACCOUNT.env"
  [ -f "$KEY_FILE" ] || refuse "no ANTHROPIC_API_KEY and no key file for account $HIMMEL_API_ACCOUNT"
  [ -n "$(find "$KEY_FILE" -maxdepth 0 -perm 600 -user "$(id -u)")" ] || # gnu-ok: BSD find has -maxdepth/-perm/-user too
    refuse "key file for account $HIMMEL_API_ACCOUNT must be mode 600 and owned by you"
  KEY="$(sed -n 's/^ANTHROPIC_API_KEY=//p' "$KEY_FILE" | head -n 1)"
  [ -n "$KEY" ] || refuse "key file for account $HIMMEL_API_ACCOUNT has no ANTHROPIC_API_KEY line"
fi
[ -z "${HIMMEL_API_KEY_ID:-}" ] || [ "$HIMMEL_API_KEY_ID" = "$ROSTER_KEY" ] ||
  refuse "key id does not match account $HIMMEL_API_ACCOUNT"

# --- API bank gate: the credit row decides; the native bank is never consulted ---
JOB_ID="${HIMMEL_API_JOB_ID:-api-$(date +%s)-$$}"
case "$JOB_ID" in ""|*[!A-Za-z0-9._:-]*) refuse "job id has characters outside [A-Za-z0-9._:-]" ;; esac
JOB_SAFE="$JOB_ID"
WORKER_SESSION_NAME="claude-api:$JOB_ID"   # never the inherited CADENCE_USAGE_WORKER: it could escape the api cap
# the reservation is owned by THIS shell, which waits on claude below, so it
# lives exactly as long as the call and the cap bounds real concurrency. (The default
# owner, bank-preflight's own $$ in a command substitution, dies at once.)
# The slot is released at exit by the EXIT trap above, and before a fallback runs.
BANK_VERDICT="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY \
  CADENCE_USAGE_LANE=api CADENCE_USAGE_LAUNCH=1 WORKER_SESSION_LANE=api \
  CADENCE_USAGE_WORKER="$WORKER_SESSION_NAME" CADENCE_USAGE_CALLER_PID="$$" \
  bash "$REPO/scripts/lib/usage-preflight.sh")" || BANK_VERDICT=BANK-UNKNOWN
[ "$BANK_VERDICT" = "PROCEED" ] || refuse "api bank gate said $BANK_VERDICT"

[ -z "$GRANT_ERR" ] || refuse "$GRANT_ERR"

# the credit covers a print-mode call only when it is not a Claude Code session (Help Center 17154008).
# A call launched from inside a session inherits its markers (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT=cli, session
# id, messaging token ...), which make the child identify as that session; drop every one of them.
# CLAUDE_JOB_DIR goes too: claude adopts the name in that job's state.json, so the call would show up as the launcher.
SESSION_UNSET=()
for v in $(compgen -e); do
  case "$v" in CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_JOB_DIR|CLAUDE_CODE_*) SESSION_UNSET+=(-u "$v") ;; esac
done

OUT="$(mktemp "${TMPDIR:-/tmp}/claude-api-out.XXXXXX")" || refuse "no scratch file"

# A prompt on stdin is kept in a mode-600 scratch file (removed by the EXIT trap on every exit path) so the call reads
# it from there and the subscription fallback can replay the same bytes. Everything above refuses before stdin is read.
# The read is bounded by a watchdog at the call timeout on every host, as the call's own stdin read was by its watchdog,
# and a terminal is refused (nobody types a prompt into a one-shot launcher).
# ponytail: a SIGKILL or an OOM kill leaves the mode-600 prompt file in TMPDIR (the EXIT trap cannot run), upgrade path: sweep claude-api-prompt.* files older than the call timeout at launch
CALL_TIMEOUT_S="${HIMMEL_API_CALL_TIMEOUT_S:-3600}"
[[ "$CALL_TIMEOUT_S" =~ ^[1-9][0-9]{0,8}$ ]] || CALL_TIMEOUT_S=3600
if [ "$HAS_PROMPT" != 1 ]; then
  [ ! -t 0 ] || { NO_FB="there is no prompt to keep"; refuse "the prompt must be an argument or piped on stdin; stdin is a terminal"; }
  PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/claude-api-prompt.XXXXXX")" || { PROMPT_FILE=""; refuse "no scratch file"; }
  chmod 600 "$PROMPT_FILE"
  # a background job gets /dev/null for stdin, so the read names fd 0; a half-read stdin cannot be replayed whole
  cat <&0 >"$PROMPT_FILE" &
  READ_PID=$!
  ( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
    sleep "$CALL_TIMEOUT_S" & wait $!; kill "$READ_PID" 2>/dev/null ) 3<&- &
  READ_WD=$!
  trap 'kill "$READ_PID" "$READ_WD" 2>/dev/null; exit 143' TERM INT HUP
  wait "$READ_PID" || { kill "$READ_WD" 2>/dev/null; NO_FB="the prompt could not be kept"
    refuse "could not buffer the stdin prompt (read failed or stdin stayed open for ${CALL_TIMEOUT_S}s)"; }
  kill "$READ_WD" 2>/dev/null
  trap - TERM INT HUP
  exec 3<"$PROMPT_FILE" || { NO_FB="the prompt could not be kept"; refuse "could not reopen the stdin prompt"; }
else
  # a closed stdin becomes /dev/null: the call then starts as it would have with an empty stdin (the idiom of scripts/lib/qmd-bounded.sh)
  { exec 3<&0; } 2>/dev/null || exec 3</dev/null
fi

# Runs a command with TERM, INT and HUP ignored. This protects only a non-node wrapper that keeps the inherited
# SIG_IGN; real node resets the disposition at startup, so a tree cancel that lands mid-settle can still cut a node step.
immune() { ( trap '' TERM INT HUP; exec "$@" ); }

# --- reserve the full budget before spending; refusal here means no launch ---
state() { immune node "$REPO/scripts/lib/api-credit-state.mjs" "$@"; }
RESERVED="$(state reserve --id "$JOB_ID" --usd "$BUDGET")"
case "$RESERVED" in *'"verdict":"PROCEED"'*) ;; *) refuse "reservation refused: $RESERVED" ;; esac

# A call that dies settles its reservation (verified cost, else zero) so nothing stays reserved past it.
# The call runs in the background so a signal reaches this shell at once: the handler stops the call before it
# settles, and a watchdog stops it at HIMMEL_API_CALL_TIMEOUT_S, the age at which the credit-state sweep
# releases a reservation. A launcher killed hard leaves its reservation to that sweep.
CALL_PID=""
WATCHDOG_PID=""
DEAD_SETTLED=0
# shellcheck disable=SC2329 # invoked from the signal trap below and from the failed-call branch
settle_dead() {
  [ "$DEAD_SETTLED" = 0 ] || return 0
  DEAD_SETTLED=1
  state settle --id "$JOB_ID" --usd "${1:-0.000000}" --completion verified >/dev/null 2>&1 ||
    state unknown --id "$JOB_ID" >/dev/null 2>&1
}
# every process below a pid, deepest first
# shellcheck disable=SC2329 # invoked from stop_call
descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do descendants "$c"; echo "$c"; done
}
# The call and its subprocesses get TERM first; any that ignore it are KILLed after five seconds
# (the credit-state sweep holds the reservation for that grace), so none outlives its stop.
# shellcheck disable=SC2329 # invoked from the signal trap and the watchdog below
stop_call() {
  local i=0 all p
  [ -n "$CALL_PID" ] || return 0
  all="$(descendants "$CALL_PID") $CALL_PID"
  # shellcheck disable=SC2086 # a list of pids
  kill -TERM $all 2>/dev/null
  while [ "$i" -lt 50 ]; do
    for p in $all; do kill -0 "$p" 2>/dev/null && break; p=""; done
    [ -n "$p" ] || break
    sleep 0.1; i=$((i + 1))
  done
  # shellcheck disable=SC2086
  kill -KILL $all 2>/dev/null
  wait "$CALL_PID" 2>/dev/null
}
# shellcheck disable=SC2329 # invoked from the signal trap below
on_signal() {
  # a second TERM (the bounded wrapper's group kill) must not cut the settle short; the ignore is inherited by it
  trap '' TERM INT HUP
  [ -z "$WATCHDOG_PID" ] || kill "$WATCHDOG_PID" 2>/dev/null
  stop_call; settle_dead; exit 143
}
trap on_signal TERM INT HUP

# --- launch: provider vars removed, endpoint pinned, only the key carried in ---
# The key is a prefix assignment, so it reaches env (and claude) through the environment, never an argv.
# one-shot API-credit launch; bank gate, reservation and explicit --permission-mode above
ANTHROPIC_API_KEY="$KEY" env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_PROFILE -u ANTHROPIC_FEDERATION_RULE_ID \
  -u ANTHROPIC_ORGANIZATION_ID -u ANTHROPIC_AUTH_TOKEN -u HIMMEL_API_LANE -u HIMMEL_API_KEY_ID \
  -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY -u HIMMEL_DOTENV_FILE -u HIMMEL_API_SNAPSHOT_OPTIONAL \
  -u LQ_API_KEY -u LQ_API_ACCOUNT -u LQ_API_KEY_ID -u LQ_API_LANE -u HIMMEL_API_KIND -u HIMMEL_API_CACHE_TTL \
  -u HIMMEL_API_BRANCH -u HIMMEL_API_HEAD -u HIMMEL_API_PR \
  -u HIMMEL_API_FALLBACK -u HIMMEL_API_ALERT_CMD -u HIMMEL_API_ALERT_DIR \
  ${SESSION_UNSET[@]+"${SESSION_UNSET[@]}"} \
  ANTHROPIC_BASE_URL=https://api.anthropic.com CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_PROMPT_CACHE_TTL="$CACHE_TTL" \
  "$CLAUDE_BIN" "${ARGS[@]}" --model "$MODEL" --permission-mode "$MODE" \
  "${TOOL_ARGS[@]}" --max-budget-usd "$BUDGET" --output-format json ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} >"$OUT" <&3 3<&- &
CALL_PID=$!
# the watchdog's own sleep is ended with it, so no timer outlives the call
( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
  sleep "$CALL_TIMEOUT_S" & wait $!; : >"$OUT.timeout"; stop_call ) 3<&- &
WATCHDOG_PID=$!
wait "$CALL_PID"
RC=$?
kill "$WATCHDOG_PID" 2>/dev/null
# a cancel kills the call first and this shell right after: a default TERM here would end it before the settle below
# ponytail: a tree cancel that lands mid-settle can cut a node step, so the reservation goes unknown or to the sweep, upgrade path: HIMMEL-8657
trap 'STOPPED=1' TERM INT HUP

# --- settle on verified cost; a call that exited non-zero is dead and settles too; otherwise unknown ---
COST="$(immune node "$REPO/scripts/api-lane/outcome.mjs" "$OUT")"
if [ "$RC" -eq 0 ] && [ -n "$COST" ]; then
  DEAD_SETTLED=1
  SETTLED="$(state settle --id "$JOB_ID" --usd "$COST" --completion verified)"
  case "$SETTLED" in
    *'"reason":"settled"'*) OUTCOME=settled ;;
    *'"reason":"reservation-overrun"'*) OUTCOME=overrun; echo "claude-api: warning: cost exceeded the reservation; ledger flagged" >&2 ;;
    *) echo "claude-api: warning: settle failed ($SETTLED); keeping the reservation as unknown" >&2
       state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown ;;
  esac
elif [ "$RC" -ne 0 ]; then
  COST="${COST:-0.000000}"
  settle_dead "$COST"; OUTCOME=failed
else
  state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown
fi

# --- a credit-exhausted or key-rejected answer marks the account; later auto picks rotate to the other one ---
# Either answer exits 6 (EXIT_REJECTED), the code a looping caller treats as non-retryable: the same account would answer the same.
EXIT_RC="$RC"
REJECTED=""
if [ "$RC" -ne 0 ]; then
  # only the error envelope's own result text counts: a denial or tool output elsewhere in the JSON may quote the phrase
  REJECTED="$(immune node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const t=r&&r.is_error===true&&typeof r.result==="string"?r.result.toLowerCase():"";if(t.includes("credit balance is too low"))console.log("exhausted");else if(t.includes("invalid api key"))console.log("key_invalid")}catch{}' "$OUT" 2>/dev/null)" || REJECTED=""
fi
WHAT=""
if [ -n "$REJECTED" ]; then
  OUTCOME="$REJECTED"; EXIT_RC=6
  case "$REJECTED" in exhausted) WHAT="credit exhausted" ;; *) WHAT="API key rejected" ;; esac
  if state exhausted >/dev/null 2>&1; then
    echo "claude-api: account $HIMMEL_API_ACCOUNT $WHAT; auto routing rotates to the other account" >&2
  else
    echo "claude-api: account $HIMMEL_API_ACCOUNT $WHAT, but the marker was not saved; the next auto call may pick it again" >&2
  fi
fi

# --- secret-free launch record (no key, no prompt) ---
# the usage split, so cache-report.mjs can read the hit rate back; null when the result has none.
read -r U_IN U_CREATE U_READ < <(immune node "$REPO/scripts/api-lane/usage.mjs" "$OUT") || true
SOURCE="$(printf '%s' "$RESERVED" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')"
{
  printf '{"ts":"%s","job_id":"%s","account":"%s","organization_id":"%s","key_id":"%s","cycle_id":"%s","model":"%s","budget_usd":"%s","source":"%s","outcome":"%s","cost_usd":"%s","rc":%s,"kind":"%s","cache_ttl":"%s","input_tokens":%s,"cache_creation_tokens":%s,"cache_read_tokens":%s,"branch":"%s","head":"%s","pr":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB_ID" "$HIMMEL_API_ACCOUNT" "$ROSTER_ORG" "$ROSTER_KEY" \
    "$ROSTER_CYCLE" "$MODEL" "$BUDGET" "$SOURCE" "$OUTCOME" "$COST" "$RC" "$KIND" "$CACHE_TTL" \
    "${U_IN:-null}" "${U_CREATE:-null}" "${U_READ:-null}" "$R_BRANCH" "$R_HEAD" "${R_PR:-null}"
} >>"$STATE_DIR/launches.jsonl" 2>/dev/null || echo "claude-api: warning: launch record not written" >&2

# --- a failed call: alert, then the subscription fallback (never returns when it ran) ---
# the reason is a class and a subtype only: the call's own result text may quote the prompt
# A TERM, INT or HUP to this launcher is its caller stopping it (a --cancel TERMs the call and the launcher together,
# and the call can end first): that is a stop, not a failure to alert on or replay. The call watchdog's own stop
# signals only the call, so a timeout is still a failed call.
if [ "$EXIT_RC" -ne 0 ] && [ -z "$REJECTED" ] && [ "$STOPPED" = 1 ]; then
  echo "claude-api: stopped by its caller (exit $RC); no alert, no fallback" >&2
elif [ "$EXIT_RC" -ne 0 ]; then
  if [ -n "$REJECTED" ]; then
    fail_over "$EXIT_RC" rejected "account $HIMMEL_API_ACCOUNT $WHAT"
  elif [ -e "$OUT.timeout" ]; then
    echo "claude-api: the call hit the call timeout (${CALL_TIMEOUT_S}s)" >&2
    fail_over "$EXIT_RC" call-failed "the call hit the call timeout (${CALL_TIMEOUT_S}s)"
  else
    SUBTYPE="$(immune node -e 'try{const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));if(r&&typeof r.subtype==="string"&&/^[a-z_]{1,64}$/.test(r.subtype))console.log(r.subtype)}catch{}' "$OUT" 2>/dev/null)"
    fail_over "$EXIT_RC" call-failed "the call exited $RC${SUBTYPE:+ ($SUBTYPE)}"
  fi
fi

cat "$OUT"
exit "$EXIT_RC"
