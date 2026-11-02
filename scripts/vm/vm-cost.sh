#!/usr/bin/env bash
# billed-exempt: reads a local ledger file, starts no claude session
# scripts/vm/vm-cost.sh - what the VM test runs have cost, per ticket and per account.
#
# Usage: vm-cost.sh [--path|--today]
#   (none)  print one tab-separated line per ticket and per account from the ledger:
#           kind (ticket|account), key, runs, seconds, usd, usd_unknown
#           usd sums the rows that carry a number; usd_unknown counts the rows whose
#           cost could not be read (null usd), so a total is never silently low.
#   --path  print the ledger path and exit (launch-guest.sh writes there).
#   --today print ONE space-free line of today's (UTC) spend per account, for the chief tick and
#           the Telegram station-status: <account>:<usd>usd[?]/<n>runs joined by commas, the ?
#           marking a total that leaves out a null-cost row. No output when no row is from today.
# Ledger: <handover root>/.ledger/vm-cost.jsonl (override: LAUNCH_GUEST_COST_LEDGER),
#   one row per launched VM test run, written by launch-guest.sh:
#   {ticket, vm, account, seconds, usd, usd_source, ts}. The account is a label, never a token.
# Unparseable ledger lines are skipped. Exit: 0 report, 1 no ledger or no jq, 2 usage.
# Platform: POSIX bash 3.2+ and jq.
set -u -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

ledger_path() {
    if [ -n "${LAUNCH_GUEST_COST_LEDGER:-}" ]; then printf '%s\n' "$LAUNCH_GUEST_COST_LEDGER"; return 0; fi
    # handover_root reads only the live env; feed it the .env HANDOVER_DIR first
    # shellcheck disable=SC1091
    if . "$HERE/../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
    # shellcheck source=scripts/lib/handover-path.sh
    . "$HERE/../lib/handover-path.sh" || return 1
    local root
    root="$(handover_root)" || return 1
    printf '%s/.ledger/vm-cost.jsonl\n' "$root"
}

MODE=report
if [ "$#" -gt 0 ]; then
    case "${1:-}:$#" in
        --path:1) ledger_path; exit $? ;;
        --today:1) MODE=today ;;
        *) echo "usage: vm-cost.sh [--path|--today]" >&2; exit 2 ;;
    esac
fi
command -v jq >/dev/null 2>&1 || { echo "vm-cost: jq is required" >&2; exit 1; }
LEDGER="$(ledger_path)" || exit 1
[ -r "$LEDGER" ] || { echo "vm-cost: no ledger at $LEDGER" >&2; exit 1; }

if [ "$MODE" = today ]; then
    # one space-free line, one entry per account: <account>:<usd>usd[?]/<n>runs, the ? marking a
    # total that leaves out a row whose cost could not be read; no output when no row is from today (UTC)
    jq -R 'fromjson? | select(type == "object")' "$LEDGER" \
        | jq -rs --arg today "$(date -u +%Y-%m-%d)" '
            def usd2: (. * 100 | round) as $c
                | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
            [.[] | select((.ts | type) == "string" and (.ts | startswith($today)))]
            | if length == 0 then empty else
                group_by(.account // "unknown")
                | map("\(.[0].account // "unknown"):\(map(if (.usd | type) == "number" then .usd else 0 end) | add | usd2)usd\(if any(.[]; (.usd | type) != "number") then "?" else "" end)/\(length)runs")
                | join(",")
              end'
    exit $?
fi

jq -R 'fromjson? | select(type == "object")' "$LEDGER" \
    | jq -rs '
        def sum(by; kind):
            group_by(.[by])[]
            | [kind, (.[0][by] // "unknown"), length,
               (map(.seconds // 0) | add),
               ((map(if (.usd | type) == "number" then .usd else 0 end) | add) * 100 | round / 100),
               (map(select((.usd | type) != "number")) | length)]
            | @tsv;
        sum("ticket"; "ticket"), sum("account"; "account")'
