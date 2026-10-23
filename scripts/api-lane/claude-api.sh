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
#        [HIMMEL_API_KIND=<label>] run kind for the cache report (eval|judge|bulk; default other)
#        [HIMMEL_API_CACHE_TTL=5m|1h] prompt-cache lifetime of the call (default 5m)
#        [HIMMEL_API_CALL_TIMEOUT_S=<seconds>] the launcher stops a call at this age, and the credit-state sweep releases a reservation older than it plus the five-second kill grace (default 3600)
#        [HIMMEL_API_BRANCH=<branch> HIMMEL_API_HEAD=<sha> HIMMEL_API_PR=<number>] the work the call belongs to; written to
#        the launch record so a cost can be joined to a PR by key (absent = empty / null)
# OFF by default. No subscription fallback: a refusal is final.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_BIN="${HIMMEL_API_CLAUDE_BIN:-claude}"

refuse() { echo "claude-api: refused: $*" >&2; exit 2; }

# only the auto route below may relax the credit-reading requirement; a caller's value never does
unset HIMMEL_API_SNAPSHOT_OPTIONAL

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

# --- argument policy: print mode only, explicit permission mode, model and budget ---
PRINT=0 MODE="" MODEL="" BUDGET="" FORMAT=""
ARGS=()
while [ "$#" -gt 0 ]; do
  a="$1"; shift
  # Allowlist: only -p/--print, --model, --permission-mode, --max-budget-usd, --output-format, --effort and a positional
  # prompt reach claude (the launcher adds its own --tools/--allowedTools). Any other argument starting with a dash is
  # refused whatever its spelling or attached =value, so a flag claude adds later is closed by default. A @file
  # argument is an args file, which could carry any flag.
  case "$a" in @*) refuse "an @argsfile argument is not allowed on the api lane" ;; esac
  case "$a" in
    -p|--print) PRINT=1; ARGS+=("$a"); continue ;;
    --) refuse "the -- argument terminator would turn the enforced options into positionals" ;;
    --permission-mode|--model|--max-budget-usd|--output-format|--effort)
      [ "$#" -gt 0 ] || refuse "$a needs a value"
      val="$1"; shift ;;
    --permission-mode=*|--model=*|--max-budget-usd=*|--output-format=*|--effort=*)
      val="${a#*=}"; a="${a%%=*}" ;;
    -*) refuse "flag ${a%%=*} is not allowed on the api lane" ;;
    *) ARGS+=("$a"); continue ;;
  esac
  case "$a" in
    --permission-mode) case "$val" in
                         default|plan|acceptEdits|dontAsk|auto) MODE="$val" ;;
                         *) refuse "permission mode is not on the api lane allowlist (default, plan, acceptEdits, dontAsk, auto; bypassPermissions is never allowed)" ;;
                       esac ;;
    --model) case "$val" in ""|-*) refuse "--model needs a value not starting with a dash" ;; esac
             MODEL="$val" ;;
    --max-budget-usd) BUDGET="$val" ;;
    --output-format) FORMAT="$val" ;;
    --effort) case "$val" in ""|-*|*[!A-Za-z0-9._-]*) refuse "--effort needs a value of [A-Za-z0-9._-] not starting with a dash" ;; esac
              ARGS+=(--effort "$val") ;;
  esac
done
[ "$PRINT" = 1 ] || refuse "only -p/--print runs are allowed"
[ -n "$MODE" ] || refuse "--permission-mode is required"
[ -n "$MODEL" ] || refuse "--model is required"
case "$MODEL" in *[!A-Za-z0-9._:/@-]*) refuse "--model has characters outside [A-Za-z0-9._:/@-]" ;; esac
[ -n "$BUDGET" ] || refuse "--max-budget-usd is required"
case "$FORMAT" in ""|json) ;; *) refuse "--output-format must be json" ;; esac

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
ROSTER_KEY="" ROSTER_ORG="" ROSTER_CYCLE="" STATE_DIR=""
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
LEG_NAME="claude-api:$JOB_ID"   # never the inherited CADENCE_USAGE_LEG: it could escape the api cap
# the reservation is owned by THIS shell, which waits on claude below, so it
# lives exactly as long as the call and the cap bounds real concurrency. (The default
# owner, bank-preflight's own $$ in a command substitution, dies at once.)
BANK_VERDICT="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY -u ANTHROPIC_ORG_A_KEY -u ANTHROPIC_ORG_B_KEY \
  CADENCE_USAGE_LANE=api CADENCE_USAGE_LAUNCH=1 LEG_LANE=api \
  CADENCE_USAGE_LEG="$LEG_NAME" CADENCE_USAGE_CALLER_PID="$$" \
  bash "$REPO/scripts/lib/usage-preflight.sh")" || BANK_VERDICT=BANK-UNKNOWN
[ "$BANK_VERDICT" = "PROCEED" ] || refuse "api bank gate said $BANK_VERDICT"

# CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (what keeps the key out of Bash-tool children) forces
# permission mode "default" whatever --permission-mode a caller passes (the eval passes auto), and in -p that
# denies Edit/Write/Bash unless declared here. The scrub is the bwrap sandbox, so it cannot be dropped; this
# allowance is the fixture-work tool set, the sandbox bounds Bash, and callers cannot add to or replace it.
# --allowedTools only preapproves; --tools is what limits the tools claude may use at all.
# the lane is tool-free by default. GRANT_CEILING is the most a caller can ever name; a caller opts in
# with HIMMEL_API_TOOLS=<comma subset of the ceiling>, and an unset or empty variable is a tool-free call. Anything
# outside the ceiling (a wildcard, Bash(*), an mcp__ tool), or a malformed list, is refused. Hooks are off on this
# lane, so every tool a caller names is one no PreToolUse guardrail can stop: name the fewest.
GRANT_CEILING="Read,Edit,Write,Glob,Grep,Bash"
ALLOWED_TOOLS=""
if [ -n "${HIMMEL_API_TOOLS:-}" ]; then
  case "$HIMMEL_API_TOOLS" in ,*|*,|*,,*) refuse "HIMMEL_API_TOOLS has an empty entry" ;; esac
  IFS=, read -ra WANT <<< "$HIMMEL_API_TOOLS"
  for t in "${WANT[@]}"; do
    case ",$GRANT_CEILING," in *",$t,"*) ;; *) refuse "HIMMEL_API_TOOLS may only name tools from the grant ceiling ($GRANT_CEILING)" ;; esac
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

# the credit covers a print-mode call only when it is not a Claude Code session (Help Center 17154008).
# A call launched from inside a session inherits its markers (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT=cli, session
# id, messaging token ...), which make the child identify as that session; drop every one of them.
SESSION_UNSET=()
for v in $(compgen -e); do
  case "$v" in CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_*) SESSION_UNSET+=(-u "$v") ;; esac
done

# Release the fleet-slot reservation at call end, only when its pid file names this shell.
# The trap is installed straight after admission so no later refusal can strand the slot.
# shellcheck disable=SC2329 # invoked from the EXIT trap string below
release_slot() {
  # shellcheck source=scripts/lib/fleet-reservation-key.sh
  . "$REPO/scripts/lib/fleet-reservation-key.sh" 2>/dev/null || return 0
  local slots="${HIMMEL_FLEET_SLOTS:-${XDG_RUNTIME_DIR:-/tmp}/himmel-fleet-$(id -u)}" key dir
  for key in "$(fleet_reservation_key "$LEG_NAME")" "$(fleet_hash_key "$LEG_NAME")"; do
    dir="$slots/$key"
    [ "$(cat "$dir/pid" 2>/dev/null)" = "$$" ] && rm -rf "$dir"
  done
  return 0
}
OUT=""
trap 'rm -f "$OUT"; release_slot' EXIT
OUT="$(mktemp "${TMPDIR:-/tmp}/claude-api-out.XXXXXX")" || refuse "no scratch file"

# --- reserve the full budget before spending; refusal here means no launch ---
state() { node "$REPO/scripts/lib/api-credit-state.mjs" "$@"; }
RESERVED="$(state reserve --id "$JOB_ID" --usd "$BUDGET")"
case "$RESERVED" in *'"verdict":"PROCEED"'*) ;; *) refuse "reservation refused: $RESERVED" ;; esac

# A call that dies settles its reservation (verified cost, else zero) so nothing stays reserved past it.
# The call runs in the background so a signal reaches this shell at once: the handler stops the call before it
# settles, and a watchdog stops it at HIMMEL_API_CALL_TIMEOUT_S, the age at which the credit-state sweep
# releases a reservation. A launcher killed hard leaves its reservation to that sweep.
CALL_TIMEOUT_S="${HIMMEL_API_CALL_TIMEOUT_S:-3600}"
[[ "$CALL_TIMEOUT_S" =~ ^[1-9][0-9]{0,8}$ ]] || CALL_TIMEOUT_S=3600
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
  ${SESSION_UNSET[@]+"${SESSION_UNSET[@]}"} \
  ANTHROPIC_BASE_URL=https://api.anthropic.com CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_PROMPT_CACHE_TTL="$CACHE_TTL" \
  "$CLAUDE_BIN" "${ARGS[@]}" --model "$MODEL" --permission-mode "$MODE" \
  "${TOOL_ARGS[@]}" --max-budget-usd "$BUDGET" --output-format json ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} >"$OUT" <&0 &
CALL_PID=$!
# the watchdog's own sleep is ended with it, so no timer outlives the call
( trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
  sleep "$CALL_TIMEOUT_S" & wait $!; stop_call ) &
WATCHDOG_PID=$!
wait "$CALL_PID"
RC=$?
kill "$WATCHDOG_PID" 2>/dev/null
trap - TERM INT HUP

# --- settle on verified cost; a call that exited non-zero is dead and settles too; otherwise unknown ---
COST="$(node "$REPO/scripts/api-lane/outcome.mjs" "$OUT")"
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

# --- a credit-exhausted answer marks the account; later auto picks rotate to the other one ---
if [ "$RC" -ne 0 ] && grep -qi 'credit balance is too low' "$OUT" 2>/dev/null; then
  if state exhausted >/dev/null 2>&1; then
    echo "claude-api: account $HIMMEL_API_ACCOUNT credit exhausted; auto routing rotates to the other account" >&2
  else
    echo "claude-api: account $HIMMEL_API_ACCOUNT credit exhausted, but the marker was not saved; the next auto call may pick it again" >&2
  fi
fi

# --- secret-free launch record (no key, no prompt) ---
# the usage split, so cache-report.mjs can read the hit rate back; null when the result has none.
read -r U_IN U_CREATE U_READ < <(node "$REPO/scripts/api-lane/usage.mjs" "$OUT") || true
# branch is JSON-escaped (control characters dropped) so it still matches the ledger's branch; head must be 7-64 hex or is empty;
# a PR that is not a canonical positive decimal is null.
R_BRANCH="$(printf '%s' "${HIMMEL_API_BRANCH:-}" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g')"
R_HEAD=""
[[ "${HIMMEL_API_HEAD:-}" =~ ^[0-9A-Fa-f]{7,64}$ ]] && R_HEAD="$HIMMEL_API_HEAD"
R_PR=""
[[ "${HIMMEL_API_PR:-}" =~ ^[1-9][0-9]*$ ]] && R_PR="$HIMMEL_API_PR"
SOURCE="$(printf '%s' "$RESERVED" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')"
{
  printf '{"ts":"%s","job_id":"%s","account":"%s","organization_id":"%s","key_id":"%s","cycle_id":"%s","model":"%s","budget_usd":"%s","source":"%s","outcome":"%s","cost_usd":"%s","rc":%s,"kind":"%s","cache_ttl":"%s","input_tokens":%s,"cache_creation_tokens":%s,"cache_read_tokens":%s,"branch":"%s","head":"%s","pr":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB_ID" "$HIMMEL_API_ACCOUNT" "$ROSTER_ORG" "$ROSTER_KEY" \
    "$ROSTER_CYCLE" "$MODEL" "$BUDGET" "$SOURCE" "$OUTCOME" "$COST" "$RC" "$KIND" "$CACHE_TTL" \
    "${U_IN:-null}" "${U_CREATE:-null}" "${U_READ:-null}" "$R_BRANCH" "$R_HEAD" "${R_PR:-null}"
} >>"$STATE_DIR/launches.jsonl" 2>/dev/null || echo "claude-api: warning: launch record not written" >&2

cat "$OUT"
exit "$RC"
