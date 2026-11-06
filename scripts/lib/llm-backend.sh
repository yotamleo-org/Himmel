# shellcheck shell=bash
# scripts/lib/llm-backend.sh
#
# The one api|cli backend resolver for himmel's LLM cadences.
# A cadence reads its backend setting, runs it through llm_backend_resolve and
# gets back a canonical name, so no script keeps its own copy of the list.
#
#   claude-cli  subscription `claude -p`; draws the 5h/weekly bank, so the
#               caller still runs scripts/lib/usage-preflight.sh (cli path only)
#   claude-api  API credit through scripts/api-lane/claude-api.sh; needs
#               HIMMEL_API_LANE=on and HIMMEL_API_ACCOUNT, and the lane checks
#               its own credit (no bank-preflight on this path)
#   ollama      local model, no egress, no bank draw
#
# Aliases: `cli` -> claude-cli, `api` -> claude-api. Anything else fails closed.
#
# Usage: . "$REPO_ROOT/scripts/lib/llm-backend.sh"
#        backend="$(llm_backend_resolve "$value")" || exit 1

# llm_backend_resolve <value> -> canonical name on stdout; rc 1 on an unknown value.
llm_backend_resolve() {
    case "${1:-}" in
        claude-cli|cli) printf 'claude-cli\n' ;;
        claude-api|api) printf 'claude-api\n' ;;
        ollama)         printf 'ollama\n' ;;
        *) return 1 ;;
    esac
}

# llm_backend_api_account_ok <acct> -> rc 0 for a named API account (A, B or C), rc 1 otherwise.
# This is the bash owner of the account set; scripts/lib/api-credit-state.mjs ACCOUNTS is the
# other, and test-llm-backend.sh pins the two equal. `auto` is not a named account.
llm_backend_api_account_ok() {
    case "${1:-}" in
        A|B|C) return 0 ;;
        *) return 1 ;;
    esac
}

# llm_backend_api_ready -> rc 0 when the API lane is on and HIMMEL_API_ACCOUNT names an
# account (A, B or C). Never `auto`: operator decision 525 limits auto routing to the himmel
# graph pass, which asks llm_backend_api_ready_graph instead.
llm_backend_api_ready() {
    [ "${HIMMEL_API_LANE:-}" = "on" ] && llm_backend_api_account_ok "${HIMMEL_API_ACCOUNT:-}"
}

# llm_backend_api_ready_graph -> as llm_backend_api_ready, but `auto` is accepted. Only the
# himmel graph semantic pass (scripts/graphify/graph-cadence.sh) may call this.
llm_backend_api_ready_graph() {
    [ "${HIMMEL_API_LANE:-}" = "on" ] \
        && { llm_backend_api_account_ok "${HIMMEL_API_ACCOUNT:-}" || [ "${HIMMEL_API_ACCOUNT:-}" = "auto" ]; }
}
