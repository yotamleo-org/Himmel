#!/usr/bin/env bash
# billed-exempt: launcher into a test VM; the operator or chief arming it is the billed act
# scripts/vm/launch-guest.sh - start ONE claude session on a himmel test VM.
#
# The sanctioned guest launch for the worker-vm profile: the profile's
# only extra allow rule names this script, so a worker never types ssh or a claude
# launch itself. The guest session runs on the guest's own claude login with an
# explicit --permission-mode acceptEdits and a fixed --allowedTools list, never a
# skip-permissions flag (docs/internals/enforcement.md, Claude invocation billing).
#
# Usage: launch-guest.sh [--dry-run] [--lane native|claudex] [--classifier-model <m>] [--debug-file <guest path>] <vm> <prompt-file>
#   <vm>          a key of scripts/lib/vms.json that is an ubuntu guest with an
#                 ssh_port and a user, and not kind=station. Anything else exits 2
#                 before any connection.
#   <prompt-file> a host file sent to the guest claude on stdin; it must resolve
#                 under the cwd's git worktree or the session scratchpad and not
#                 have a secret-shaped name (.env*, *.pem, *.key, id_*, credentials*).
#   --dry-run     print the ssh command instead of running it (no preflight).
#   --lane        native (default): the guest's own claude, acceptEdits. claudex: only
#                 himmel-claudex; runs scripts/claude-codex with an explicit
#                 --permission-mode auto (never a skip-permissions flag) after the
#                 guest `claude-codex --preflight-only` and the Codex bank preflight.
#                 Requires --classifier-model (a model word, or gateway) and --debug-file
#                 (an absolute or ~/ guest path); both are spliced into the guest
#                 shell, so each is validated to a closed shape. The Claude bank is
#                 also preflighted when the classifier model is not gateway.
#   Every lane pins ssh to the per-VM known_hosts ~/.himmel/vm/known_hosts/<vm>.
# stdout: the guest session's --output-format json result. rc: the guest's, or 2
#   on a refused argument.
# Env: LAUNCH_GUEST_VMS_JSON (registry path; default scripts/lib/vms.json),
#      LAUNCH_GUEST_PREFLIGHT (bank preflight script; default scripts/lib/usage-preflight.sh),
#      LAUNCH_GUEST_TIMEOUT (seconds above 0, default 1800),
#      LAUNCH_GUEST_TICKET (cost ledger ticket; default the HIMMEL-n of the branch, else unknown),
#      LAUNCH_GUEST_ACCOUNT (cost ledger account label, never a token; default the VM name),
#      LAUNCH_GUEST_COST_LEDGER (ledger path; default <handover root>/.ledger/vm-cost.jsonl),
#      LAUNCH_GUEST_WARN_PCT (guest account share of its limit, a number, default 80, from which a
#        launch prints one WARN line; an account at 100 or more is refused),
#      LAUNCH_GUEST_USAGE (guest usage command run as `<cmd> <vm> usage`; default scripts/lib/vmsdk.py).
# Guest account: a native launch also asks the guest for its OWN account's usage percentage (the
#   station bank above cannot see it). 100 or more: exit 2 naming the account label, nothing sent,
#   no row. From the warn share: one WARN line with the percent on stderr. The guest login exposing
#   no figure ("unknown"): one WARN line naming the account, and the launch goes on, as the station
#   preflight does for a stale or unknown bank.
# Cost: every launched run (not a dry-run, not a refusal) appends one row to the ledger
#   with the guest result's total_cost_usd, or a null usd when it cannot be read, and the model
#   that cost the most plus the input, output and cache token counts (each null when absent);
#   scripts/vm/vm-cost.sh sums the ledger per ticket and per account.
# Platform: POSIX bash 3.2+, node, ssh with key auth to the guest.
# launch-profile-ok-file: the claude runs on the guest's own login and config, where no host profile applies
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
VMS_JSON="${LAUNCH_GUEST_VMS_JSON:-$HERE/../lib/vms.json}"
# shellcheck disable=SC2088  # the guest shell, not this one, expands the tilde
GUEST_REPO='~/Documents/github/himmel'
ALLOWED_TOOLS='Read,Grep,Glob,Edit,Write,Bash(git:*),Bash(bash scripts/*:*)'
DRY=0; LANE=native; CMODEL=""; DEBUG=""
USAGE="usage: launch-guest.sh [--dry-run] [--lane native|claudex] [--classifier-model <m>] [--debug-file <guest path>] <vm> <prompt-file>"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY=1; shift ;;
        --lane|--classifier-model|--debug-file)
            [ "$#" -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
            case "$1" in --lane) LANE="$2" ;; --classifier-model) CMODEL="$2" ;; *) DEBUG="$2" ;; esac
            shift 2 ;;
        *) break ;;
    esac
done
if [ "$#" -ne 2 ]; then
    echo "$USAGE" >&2
    exit 2
fi
VM="$1"; PROMPT="$2"
TIMEOUT="${LAUNCH_GUEST_TIMEOUT:-1800}"
case "$LANE" in native|claudex) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
if [ "$LANE" = claudex ]; then
    [ "$VM" = himmel-claudex ] || { echo "launch-guest: --lane claudex runs only on himmel-claudex" >&2; exit 2; }
    [ -n "$CMODEL" ] && [ -n "$DEBUG" ] || { echo "launch-guest: --lane claudex requires --classifier-model and --debug-file" >&2; exit 2; }
    # both values are spliced into the guest's bash -lc, so each is a closed word shape
    case "$CMODEL" in [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo "launch-guest: --classifier-model must match [A-Za-z0-9][A-Za-z0-9._-]*" >&2; exit 2 ;; esac
    # shellcheck disable=SC2088  # a literal ~/ prefix of a guest path, not a host expansion
    case "$DEBUG" in
        */../*|*/..|*[!A-Za-z0-9._/~-]*) echo "launch-guest: --debug-file must be an absolute or ~/ guest path of [A-Za-z0-9._/-], no .." >&2; exit 2 ;;
        '~/'*|/*) ;;
        *) echo "launch-guest: --debug-file must be an absolute or ~/ guest path of [A-Za-z0-9._/-], no .." >&2; exit 2 ;;
    esac
elif [ -n "$CMODEL$DEBUG" ]; then
    echo "launch-guest: --classifier-model and --debug-file belong to --lane claudex" >&2; exit 2
fi
case "$VM" in ''|*[!A-Za-z0-9_-]*) echo "launch-guest: '$VM' is not a registered test VM name" >&2; exit 2 ;; esac
case "$TIMEOUT" in ''|*[!0-9]*|0*) echo "launch-guest: LAUNCH_GUEST_TIMEOUT must be whole seconds above 0, no leading zero" >&2; exit 2 ;; esac
# the cost ledger row carries labels only: the account is a label for the guest's login, never a token
ACCOUNT="${LAUNCH_GUEST_ACCOUNT:-$VM}"
case "$ACCOUNT" in ''|*[!A-Za-z0-9._-]*|[Ss][Kk]-*) echo "launch-guest: LAUNCH_GUEST_ACCOUNT must match [A-Za-z0-9._-]+ and not start with sk- (a label, never a token)" >&2; exit 2 ;; esac
TICKET="${LAUNCH_GUEST_TICKET:-}"
if [ -z "$TICKET" ]; then
    TICKET="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | grep -io 'himmel-[0-9][0-9]*' | head -n 1 | tr '[:lower:]' '[:upper:]')" || TICKET=""
fi
[ -n "$TICKET" ] || TICKET=unknown
case "$TICKET" in *[!A-Za-z0-9-]*) echo "launch-guest: LAUNCH_GUEST_TICKET must match [A-Za-z0-9-]+" >&2; exit 2 ;; esac
WARN_PCT="${LAUNCH_GUEST_WARN_PCT:-80}"
case "$WARN_PCT" in ''|*[!0-9.]*|*.*.*|.|*.) echo "launch-guest: LAUNCH_GUEST_WARN_PCT must be a number" >&2; exit 2 ;; esac
[ -f "$PROMPT" ] || { echo "launch-guest: prompt file '$PROMPT' not found" >&2; exit 2; }
# the prompt is read on the host and its answer comes back, so it is confined to
# the cwd's git worktree or the session scratchpad, after resolving symlinks and
# dotdot, and a secret-shaped name is refused anywhere.
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# shellcheck disable=SC2016  # the dollar signs are javascript regex syntax
if ! RESOLVED="$(node -e '
const fs = require("fs"), path = require("path");
const [p, top, tmp] = process.argv.slice(1);
const real = (x) => { try { return fs.realpathSync(x); } catch { return ""; } };
const r = real(p), t = real(top), s = real(tmp);
const secret = /^\.env|\.pem$|\.key$|^id_|^credentials/i;
if (!r || secret.test(path.basename(p)) || secret.test(path.basename(r))) process.exit(1);
const scratch = s && new RegExp("^" + s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "/claude-" + process.getuid() + "/[^/]+/[^/]+/scratchpad/");
if ((t && r.startsWith(t + path.sep)) || (scratch && scratch.test(r))) console.log(r); else process.exit(1);
' "$PROMPT" "$TOP" "${TMPDIR:-/tmp}" 2>/dev/null)" || [ -z "$RESOLVED" ]; then
    echo "launch-guest: prompt file '$PROMPT' must live under the worktree or the session scratchpad and not be a secret-shaped file" >&2
    exit 2
fi
PROMPT="$RESOLVED"
# port and user come from the registry; a VM that is not an ubuntu guest, is a
# station, or lacks either field prints nothing and is refused.
if ! ROW="$(node -e '
const [file, vm] = process.argv.slice(1);
const e = JSON.parse(require("fs").readFileSync(file, "utf8"))[vm];
if (e && e.os === "ubuntu" && e.kind !== "station" && Number.isInteger(e.ssh_port) && /^[a-z_][a-z0-9_-]*$/.test(e.user ?? "")) console.log(e.ssh_port + " " + e.user);
' "$VMS_JSON" "$VM" 2>/dev/null)" || [ -z "$ROW" ]; then
    echo "launch-guest: '$VM' is not a registered test VM (an ubuntu guest in $VMS_JSON with ssh_port and user, not a station)" >&2
    exit 2
fi
PORT="${ROW%% *}"; GUSER="${ROW#* }"
if [ "$LANE" = claudex ]; then
    # shellcheck disable=SC2088  # the guest shell, not this one, expands the tilde
    INNER="cd $GUEST_REPO && timeout --signal=KILL $TIMEOUT bash scripts/claude-codex --classifier-model $CMODEL -p --permission-mode auto --settings ~/.config/himmel/worker-settings.json --debug-file $DEBUG --output-format json"
else
    INNER="cd $GUEST_REPO && timeout --signal=KILL $TIMEOUT claude -p --permission-mode acceptEdits --allowedTools '$ALLOWED_TOOLS' --output-format json"
fi
# every lane pins the per-VM known_hosts file vmsdk owns (ssh expands the tilde itself)
# shellcheck disable=SC2088
SSHO=(-o BatchMode=yes -o ConnectTimeout=15 -o "UserKnownHostsFile=~/.himmel/vm/known_hosts/$VM" -o StrictHostKeyChecking=accept-new)
CMD=(ssh -p "$PORT" "${SSHO[@]}" "$GUSER@127.0.0.1" "bash -lc \"$INNER\"")
if [ "$DRY" -eq 1 ]; then
    echo "ssh -p $PORT ${SSHO[*]} $GUSER@127.0.0.1 bash -lc \"$INNER\" < $PROMPT"
    exit 0
fi
if [ "$LANE" = claudex ]; then
    # the guest must have a live Codex proxy before a session starts (exit 20/21 = not ready);
    # the guest-side timeout bounds a preflight that hangs after ssh has connected
    GP=(ssh -p "$PORT" "${SSHO[@]}" "$GUSER@127.0.0.1" "bash -lc \"cd $GUEST_REPO && timeout --signal=KILL 120 bash scripts/claude-codex --preflight-only\"")
    GRC=0; "${GP[@]}" >&2 < /dev/null || GRC=$?
    [ "$GRC" -eq 0 ] || { echo "launch-guest: guest claude-codex --preflight-only exited $GRC - not launching a guest session" >&2; exit 2; }
fi
# an unattended claude session draws the same subscription budget as any other:
# preflight the bank and refuse on an exhausted verdict (unknown/stale fail open).
PREFLIGHT="${LAUNCH_GUEST_PREFLIGHT:-$HERE/../lib/usage-preflight.sh}"
if [ "$LANE" = claudex ]; then
    # the Codex bank always; the Claude bank too when a Claude model classifies
    VERDICT="$(CADENCE_USAGE_LANE=claudex bash "$PREFLIGHT" 2>/dev/null | tail -n 1)"
    case "$VERDICT" in
        SKIPPED-*) echo "launch-guest: codex bank preflight said $VERDICT - not launching a guest session" >&2; exit 2 ;;
    esac
    if [ "$CMODEL" != gateway ]; then
        VERDICT="$(CADENCE_USAGE_LANE=native bash "$PREFLIGHT" 2>/dev/null | tail -n 1)"
        case "$VERDICT" in
            SKIPPED-*) echo "launch-guest: claude bank preflight said $VERDICT - not launching a guest session" >&2; exit 2 ;;
        esac
    fi
else
    VERDICT="$(bash "$PREFLIGHT" 2>/dev/null | tail -n 1)"
    case "$VERDICT" in
        SKIPPED-*) echo "launch-guest: bank preflight said $VERDICT - not launching a guest session" >&2; exit 2 ;;
    esac
    # the native guest session spends the GUEST's own account, which the station bank above cannot
    # see: ask the guest for its usage percentage (a number, or "unknown" when its login exposes
    # none) and refuse an exhausted account by name. Unknown fails open, with a warning.
    if [ -n "${LAUNCH_GUEST_USAGE:-}" ]; then USAGE_CMD=("$LAUNCH_GUEST_USAGE")
    elif command -v uv >/dev/null 2>&1; then USAGE_CMD=(uv run --quiet "$HERE/../lib/vmsdk.py")
    else USAGE_CMD=(python3 "$HERE/../lib/vmsdk.py"); fi
    PCT="$("${USAGE_CMD[@]}" "$VM" usage 2>/dev/null < /dev/null | tail -n 1)"
    case "$PCT" in ''|*[!0-9.]*|*.*.*|.|*.) PCT=unknown ;; esac
    if [ "$PCT" = unknown ]; then
        echo "launch-guest: WARN guest account '$ACCOUNT' usage is unknown (the guest login exposes none) - launching anyway" >&2
    elif awk -v p="$PCT" 'BEGIN { exit !(p >= 100) }'; then
        echo "launch-guest: guest account '$ACCOUNT' is exhausted (${PCT}% of its limit) - not launching a guest session" >&2
        exit 2
    elif awk -v p="$PCT" -v w="$WARN_PCT" 'BEGIN { exit !(p >= w) }'; then
        echo "launch-guest: WARN guest account '$ACCOUNT' is at ${PCT}% of its limit (warns from ${WARN_PCT}%)" >&2
    fi
fi
# the run is launched: record one cost ledger row. The guest's
# --output-format json result carries total_cost_usd; anything else records a null usd.
# The row is best-effort and never changes the run's stdout or exit code.
OUT="$(mktemp "${TMPDIR:-/tmp}/launch-guest-out.XXXXXX")" || exit 1
trap 'rm -f "$OUT"' EXIT
T0="$(date +%s)"
# the launcher is the ssh's parent now (it was exec), so a signal to it ends the child and is
# waited out, and the row still records the run that was cut short. A background child of a
# non-interactive bash starts with SIGINT and SIGQUIT ignored and ssh keeps that, so those two
# are sent on as TERM; HUP is forwarded as itself.
"${CMD[@]}" < "$PROMPT" > "$OUT" &
CPID=$!
trap 'kill -TERM "$CPID" 2>/dev/null' TERM INT QUIT
trap 'kill -HUP "$CPID" 2>/dev/null' HUP
RC=0
wait "$CPID" || RC=$?
while kill -0 "$CPID" 2>/dev/null; do wait "$CPID" || RC=$?; done
T1="$(date +%s)"
cat "$OUT"
if LEDGER="$(bash "$HERE/vm-cost.sh" --path 2>/dev/null)" && command -v jq >/dev/null 2>&1; then
    USD="$(jq -r 'if type == "object" and (.total_cost_usd | type) == "number" then .total_cost_usd else "" end' "$OUT" 2>/dev/null | tail -n 1)"
    SRC=guest-json; [ -n "$USD" ] || { USD=null; SRC=unknown; }
    # the model that cost the most and the token counts (cache = creation + read), each null when the
    # guest result does not carry it; numbers and a model name only
    DETAIL="$(jq -c 'if type == "object" then {
            model: ((.modelUsage // {}) | if type == "object" then to_entries | map(select(.key | type == "string")) | sort_by(-((.value.costUSD // 0) | if type == "number" then . else 0 end)) | (.[0].key // null) else null end),
            tokens_in: (.usage.input_tokens | if type == "number" then . else null end),
            tokens_out: (.usage.output_tokens | if type == "number" then . else null end),
            tokens_cache: ([.usage.cache_creation_input_tokens, .usage.cache_read_input_tokens] | map(select(type == "number")) | if length > 0 then add else null end)
        } else empty end' "$OUT" 2>/dev/null | tail -n 1)"
    [ -n "$DETAIL" ] || DETAIL='{"model":null,"tokens_in":null,"tokens_out":null,"tokens_cache":null}'
    mkdir -p "$(dirname "$LEDGER")" 2>/dev/null \
        && jq -nc --arg ticket "$TICKET" --arg vm "$VM" --arg account "$ACCOUNT" --argjson seconds "$((T1 - T0))" \
            --argjson usd "$USD" --arg src "$SRC" --argjson detail "$DETAIL" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{ticket: $ticket, vm: $vm, account: $account, seconds: $seconds, usd: $usd, usd_source: $src} + $detail + {ts: $ts}' >> "$LEDGER" 2>/dev/null \
        || echo "launch-guest: could not write the cost ledger row" >&2
else
    echo "launch-guest: cost ledger unavailable (no handover root or no jq) - no row written" >&2
fi
exit "$RC"
