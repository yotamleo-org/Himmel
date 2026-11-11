#!/usr/bin/env bash
# graphify-classify.sh <abs-root> - what graphify-fence.sh --classify says about a
# root, read against the CONFIGURED vault and handover state.
#
# The fence takes its roots from the live environment, and LUNA_VAULT beats
# LUNA_VAULT_PATH there. A caller's shell (a session, a worker, a test) may point
# those anywhere, which would mask the vault this machine is configured with. So
# the caller's LUNA_VAULT, LUNA_VAULT_PATH and HANDOVER_DIR are cleared first and
# the configured values are loaded through load-dotenv.sh (himmel.conf, then .env).
#
# Output and exit code are the fence's: the strongest class at, above or below the
# root or nothing, exit 0; any other exit refuses the root. No ledger is written.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset LUNA_VAULT LUNA_VAULT_PATH HANDOVER_DIR
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh" || { echo "graphify-classify: cannot load load-dotenv.sh (fail-closed)" >&2; exit 2; }
load_dotenv LUNA_VAULT_PATH HANDOVER_DIR 2>/dev/null
exec bash "$SCRIPT_DIR/graphify-fence.sh" --classify "$@"
