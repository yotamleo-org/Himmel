#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset LUNA_VAULT LUNA_VAULT_PATH HANDOVER_DIR
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh" || { echo "graphify-classify: cannot load load-dotenv.sh (fail-closed)" >&2; exit 2; }
load_dotenv LUNA_VAULT_PATH HANDOVER_DIR 2>/dev/null
exec bash "$SCRIPT_DIR/graphify-fence.sh" --classify "$@"
