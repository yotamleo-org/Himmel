#!/usr/bin/env bash
# billed-exempt: reads a local ledger file, starts no claude session
# scripts/vm/vm-cost.sh - what the VM test runs have cost, per ticket and per account.
#
# Usage: vm-cost.sh [--path]
#   (none)  print one tab-separated line per ticket and per account from the ledger:
#           kind (ticket|account), key, runs, seconds, usd, usd_unknown
#           usd sums the rows that carry a number; usd_unknown counts the rows whose
#           cost could not be read (null usd), so a total is never silently low.
#   --path  print the ledger path and exit (launch-guest.sh writes there).
# Ledger: <handover root>/.ledger/vm-cost.jsonl (override: LAUNCH_GUEST_COST_LEDGER),
#   one row per launched VM test run, written by launch-guest.sh:
#   {ticket, vm, account, seconds, usd, usd_source, ts}. The account is a label, never a token.
# Unparseable ledger lines are skipped. Exit: 0 report, 1 no ledger or no jq, 2 usage.
# Platform: POSIX bash 3.2+ and jq.
set -u
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

if [ "$#" -gt 0 ]; then
    [ "$#" -eq 1 ] && [ "$1" = --path ] || { echo "usage: vm-cost.sh [--path]" >&2; exit 2; }
    ledger_path; exit $?
fi
command -v jq >/dev/null 2>&1 || { echo "vm-cost: jq is required" >&2; exit 1; }
LEDGER="$(ledger_path)" || exit 1
[ -r "$LEDGER" ] || { echo "vm-cost: no ledger at $LEDGER" >&2; exit 1; }

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
