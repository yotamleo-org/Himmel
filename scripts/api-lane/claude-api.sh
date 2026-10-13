#!/usr/bin/env bash
# HIMMEL-4985: one-shot API-key launcher (task 2 of the HIMMEL-4904 plan).
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
# OFF by default. No subscription fallback: a refusal is final.
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLAUDE_BIN="${HIMMEL_API_CLAUDE_BIN:-claude}"

refuse() { echo "claude-api: refused: $*" >&2; exit 2; }

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

# --- HIMMEL-5433: auto = the grant that expires first among accounts with room for the whole budget ---
if [ "$HIMMEL_API_ACCOUNT" = auto ]; then
  PICK="$(node "$REPO/scripts/lib/api-credit-state.mjs" pick --usd "$BUDGET")"
  case "$PICK" in *'"verdict":"PROCEED"'*) ;; *) refuse "auto routing: no account has room for the budget ($PICK)" ;; esac
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
# HIMMEL-5433: the key is held in a shell variable and handed only to claude's env below, never exported.
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
BANK_VERDICT="$(env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_API_KEY CADENCE_BANK_LANE=api CADENCE_BANK_LAUNCH=1 LEG_LANE=api \
  CADENCE_BANK_LEG="${CADENCE_BANK_LEG:-claude-api:$JOB_ID}" \
  bash "$REPO/scripts/lib/bank-preflight.sh")" || BANK_VERDICT=BANK-UNKNOWN
[ "$BANK_VERDICT" = "PROCEED" ] || refuse "api bank gate said $BANK_VERDICT"

# HIMMEL-5073: CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (what keeps the key out of Bash-tool children) forces
# permission mode "default" whatever --permission-mode a caller passes (the eval passes auto), and in -p that
# denies Edit/Write/Bash unless declared here. The scrub is the bwrap sandbox, so it cannot be dropped; this
# allowance is the fixture-work tool set, the sandbox bounds Bash, and callers cannot add to or replace it.
# --allowedTools only preapproves; --tools is what limits the tools claude may use at all.
ALLOWED_TOOLS="Read,Edit,Write,Glob,Grep,Bash"

# HIMMEL-5433: the credit covers a print-mode call only when it is not a Claude Code session (Help Center 17154008).
# A call launched from inside a session inherits its markers (CLAUDECODE, CLAUDE_CODE_ENTRYPOINT=cli, session
# id, messaging token ...), which make the child identify as that session; drop every one of them.
SESSION_UNSET=()
for v in $(compgen -e); do
  case "$v" in CLAUDECODE|AI_AGENT|CLAUDE_PID|CLAUDE_EFFORT|CLAUDE_CODE_*) SESSION_UNSET+=(-u "$v") ;; esac
done

OUT="$(mktemp "${TMPDIR:-/tmp}/claude-api-out.XXXXXX")" || refuse "no scratch file"
trap 'rm -f "$OUT"' EXIT

# --- reserve the full budget before spending; refusal here means no launch ---
state() { node "$REPO/scripts/lib/api-credit-state.mjs" "$@"; }
RESERVED="$(state reserve --id "$JOB_ID" --usd "$BUDGET")"
case "$RESERVED" in *'"verdict":"PROCEED"'*) ;; *) refuse "reservation refused: $RESERVED" ;; esac

# --- launch: provider vars removed, endpoint pinned, only the key carried in ---
# The key is a prefix assignment, so it reaches env (and claude) through the environment, never an argv.
# HIMMEL-4985 one-shot API-credit launch; bank gate, reservation and explicit --permission-mode above
ANTHROPIC_API_KEY="$KEY" env -u CLAUDE_CODE_OAUTH_TOKEN -u ANTHROPIC_PROFILE -u ANTHROPIC_FEDERATION_RULE_ID \
  -u ANTHROPIC_ORGANIZATION_ID -u ANTHROPIC_AUTH_TOKEN -u HIMMEL_API_LANE -u HIMMEL_API_KEY_ID \
  -u LQ_API_KEY -u LQ_API_ACCOUNT -u LQ_API_KEY_ID -u LQ_API_LANE ${SESSION_UNSET[@]+"${SESSION_UNSET[@]}"} \
  ANTHROPIC_BASE_URL=https://api.anthropic.com CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 \
  "$CLAUDE_BIN" "${ARGS[@]}" --model "$MODEL" --permission-mode "$MODE" \
  --tools "$ALLOWED_TOOLS" --allowedTools "$ALLOWED_TOOLS" --max-budget-usd "$BUDGET" --output-format json >"$OUT"
RC=$?

# --- settle on verified cost, otherwise keep the reservation as unknown ---
COST="$(node "$REPO/scripts/api-lane/outcome.mjs" "$OUT")"
if [ "$RC" -eq 0 ] && [ -n "$COST" ]; then
  SETTLED="$(state settle --id "$JOB_ID" --usd "$COST" --completion verified)"
  case "$SETTLED" in
    *'"reason":"settled"'*) OUTCOME=settled ;;
    *'"reason":"reservation-overrun"'*) OUTCOME=overrun; echo "claude-api: warning: cost exceeded the reservation; ledger flagged" >&2 ;;
    *) echo "claude-api: warning: settle failed ($SETTLED); keeping the reservation as unknown" >&2
       state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown ;;
  esac
else
  state unknown --id "$JOB_ID" >/dev/null; OUTCOME=unknown
fi

# --- secret-free launch record (no key, no prompt) ---
SOURCE="$(printf '%s' "$RESERVED" | sed -n 's/.*"source":"\([^"]*\)".*/\1/p')"
{
  printf '{"ts":"%s","job_id":"%s","account":"%s","organization_id":"%s","key_id":"%s","cycle_id":"%s","model":"%s","budget_usd":"%s","source":"%s","outcome":"%s","cost_usd":"%s","rc":%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$JOB_ID" "$HIMMEL_API_ACCOUNT" "$ROSTER_ORG" "$ROSTER_KEY" \
    "$ROSTER_CYCLE" "$MODEL" "$BUDGET" "$SOURCE" "$OUTCOME" "$COST" "$RC"
} >>"$STATE_DIR/launches.jsonl" 2>/dev/null || echo "claude-api: warning: launch record not written" >&2

cat "$OUT"
exit "$RC"
