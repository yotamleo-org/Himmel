#!/usr/bin/env bash
# Hermetic Python contracts, collected by the ordinary shell-suite runner.
# The real Jira CLI loopback suite additionally needs npm run build in scripts/jira
# and is run explicitly by the completion unit; these cases need no built client.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test-proof-validate.py" || exit "$?"
python3 "$HERE/test-proof-decision.py" || exit "$?"
python3 "$HERE/test-owed-events.py" || exit "$?"
python3 "$HERE/test-t2-remainder-gates.py" || exit "$?"
python3 "$HERE/../../lib/test-pr-remainder.py" || exit "$?"
