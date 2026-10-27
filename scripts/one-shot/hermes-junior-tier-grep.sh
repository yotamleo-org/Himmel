#!/usr/bin/env bash
# hermes-junior-tier-grep.sh -- one-shot proof that the hermes junior tier (the
# read-only free-tier profile and its write fence) is gone: no tracked file
# outside docs/archive names free_junior, junior-tier, luna_vault_guard or
# free-tier.SOUL. Run once by hand; never a suite (docs/internals/testing.md).
# Run with: bash scripts/one-shot/hermes-junior-tier-grep.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF="scripts/one-shot/hermes-junior-tier-grep.sh"

hits="$(git -C "$ROOT" grep -n -E 'free_junior|junior-tier|luna_vault_guard|free-tier\.SOUL' \
    -- ':!docs/archive' ":!$SELF")"
if [ -z "$hits" ]; then
    echo "PASS: no tracked file outside docs/archive names the hermes junior tier"
    exit 0
fi
printf '%s\n' "$hits" >&2
echo "FAIL: the hermes junior tier is still named in $(printf '%s\n' "$hits" | cut -d: -f1 | sort -u | wc -l | tr -d ' ') file(s)" >&2
exit 1
