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

# The API account letters. This is the bash owner of the account set; scripts/lib/api-credit-state.mjs
# ACCOUNTS is the other, and test-llm-backend.sh pins the two equal. Every form below derives from it.
# shellcheck disable=SC2034  # read by the scripts that source this file
LLM_API_ACCOUNTS="A B C D"
# shellcheck disable=SC2034
LLM_API_ACCOUNT_CLASS="[${LLM_API_ACCOUNTS// /}]"
_llm_l="${LLM_API_ACCOUNTS% *}"
# shellcheck disable=SC2034
LLM_API_ACCOUNTS_TEXT="${_llm_l// /, } or ${LLM_API_ACCOUNTS##* }"
LLM_API_ORG_KEYS=""
LLM_API_ORG_KEY_UNSET=()
for _llm_l in $LLM_API_ACCOUNTS; do
    LLM_API_ORG_KEYS="${LLM_API_ORG_KEYS:+$LLM_API_ORG_KEYS }ANTHROPIC_ORG_${_llm_l}_KEY"
    LLM_API_ORG_KEY_UNSET+=(-u "ANTHROPIC_ORG_${_llm_l}_KEY")
done
unset _llm_l

# llm_backend_api_account_ok <acct> -> rc 0 for a named API account, rc 1 otherwise. `auto` is not one.
llm_backend_api_account_ok() {
    case "${1:-}" in ""|*[!A-Z]*) return 1 ;; esac
    case " $LLM_API_ACCOUNTS " in *" $1 "*) return 0 ;; esac
    return 1
}

# llm_backend_api_account_list_ok <list> -> rc 0 for a comma-joined list of account letters (a graph walk).
llm_backend_api_account_list_ok() {
    local re="^${LLM_API_ACCOUNT_CLASS}(,${LLM_API_ACCOUNT_CLASS})*\$"
    [[ "${1:-}" =~ $re ]]
}

# llm_backend_pick_account: stdin is an api-credit-state.mjs pick answer; prints its account letter, or nothing.
llm_backend_pick_account() {
    sed -n "s/.*\"account\":\"\\(${LLM_API_ACCOUNT_CLASS}\\)\".*/\\1/p"
}

# llm_backend_key_tail <key> -> "key ...<last 4 characters>", or "key: none" for an empty key. Never more of it.
llm_backend_key_tail() {
    if [ -n "${1:-}" ]; then printf 'key ...%s' "${1: -4}"; else printf 'key: none'; fi
}

# llm_backend_api_ready -> rc 0 when the API lane is on and HIMMEL_API_ACCOUNT names an
# account. Never `auto`: operator decision 525 limits auto routing to the himmel
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
