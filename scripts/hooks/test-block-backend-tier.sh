#!/usr/bin/env bash
# Smoke test for scripts/hooks/block-backend-tier.sh.
#
# Covers:
#   - All original Jira test cases (1:1 migration from test-block-mcp-when-plugin-exists.sh)
#   - chain-reorder via fixture registry lifts the block
#   - enabled:false lifts the block
#   - MCP_ALL_OK=1 lifts all blocks
#   - Malformed / absent BACKENDS_REGISTRY → code defaults still block Jira
#   - Non-jira MCP prefix passes through (no prefix registered)
#   - Refusal message contains the api-preference advisory when chain has api tier
#
# Usage: bash scripts/hooks/test-block-backend-tier.sh
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$SCRIPT_DIR/block-backend-tier.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"
[ -x "$HOOK" ] || chmod +x "$HOOK"

# --- Stub CLI factory -------------------------------------------------------
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST" "${EQ_ROOT:-$TMPDIR_TEST}"' EXIT

# Isolate the section-4 fixture repos from the machine's real git config: the
# operator's global core.hooksPath would otherwise fire himmel's own commit
# gates inside a throwaway repo and fail for a reason no case is about (same
# pattern as test-check-hookspath.sh).
GIT_ISOLATE_DIR="$TMPDIR_TEST/gitconfig-isolate"
mkdir -p "$GIT_ISOLATE_DIR"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$GIT_ISOLATE_DIR/.gitconfig"
: > "$GIT_CONFIG_GLOBAL"

# make_stub <path> <verb>... — emits each verb on --list-commands; any other
# argv exits 1.
make_stub() {
    local path="$1"; shift
    {
        echo '#!/usr/bin/env node'
        echo 'if (process.argv.includes("--list-commands")) {'
        for verb in "$@"; do
            echo "  console.log(\"$verb\");"
        done
        echo '  process.exit(0);'
        echo '}'
        echo 'process.exit(1);'
    } > "$path"
}

# Full verb set (mirrors the real Jira CLI today).
STUB_FULL="$TMPDIR_TEST/cli-full.js"
make_stub "$STUB_FULL" get create list transition transitions comment \
    attach edit move projects project-create link

# Reduced: 'link' and 'create' removed.
STUB_REDUCED="$TMPDIR_TEST/cli-reduced.js"
make_stub "$STUB_REDUCED" get list transition comment edit projects

# Errors on --list-commands → introspection failure → fail open.
STUB_ERR="$TMPDIR_TEST/cli-err.js"
{
    echo '#!/usr/bin/env node'
    echo 'process.exit(3);'
} > "$STUB_ERR"

# Emits nothing on --list-commands but exits 0 → empty → fail open.
STUB_EMPTY="$TMPDIR_TEST/cli-empty.js"
{
    echo '#!/usr/bin/env node'
    echo 'process.exit(0);'
} > "$STUB_EMPTY"

# Only 'transitions' (NOT 'transition') → substring guard fixture.
STUB_TRANS_ONLY="$TMPDIR_TEST/cli-transitions-only.js"
make_stub "$STUB_TRANS_ONLY" get transitions

# Confluence CLI stub. Page verbs are MULTI-WORD ("page get") and
# MUST be passed quoted so make_stub emits them as single lines — this is what
# exercises the introspection strip fix (CR/LF/TAB stripped, internal space kept).
STUB_CONF="$TMPDIR_TEST/cli-confluence.js"
make_stub "$STUB_CONF" "page get" "page create" "page update" "page delete" \
    search spaces comments comment attachments attach download

# Reduced confluence stub: no 'page get', no 'search' → those routes fail open.
STUB_CONF_REDUCED="$TMPDIR_TEST/cli-confluence-reduced.js"
make_stub "$STUB_CONF_REDUCED" spaces comments

# --- Registry fixture helpers -----------------------------------------------
# write_registry <path> <json> — write a fixture backends.json.
write_registry() {
    local path="$1" content="$2"
    printf '%s' "$content" > "$path"
}

# Registry with chain [mcp,cli,api] → mcp ranked above cli → no hard block.
REG_MCP_FIRST="$TMPDIR_TEST/reg-mcp-first.json"
write_registry "$REG_MCP_FIRST" "$(cat <<'ENDJSON'
{
  "jira": {
    "enabled": true,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "__STUB__",
    "chain": ["mcp", "cli", "api"]
  }
}
ENDJSON
)"

# Registry with jira disabled → allow.
REG_DISABLED="$TMPDIR_TEST/reg-disabled.json"
write_registry "$REG_DISABLED" "$(cat <<'ENDJSON'
{
  "jira": {
    "enabled": false,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "__STUB__",
    "chain": ["cli", "api", "mcp"]
  }
}
ENDJSON
)"

# Registry with cli:api:mcp (same as default) using STUB_FULL path.
REG_NORMAL="$TMPDIR_TEST/reg-normal.json"
write_registry "$REG_NORMAL" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  }
}"

# Malformed JSON.
REG_BAD="$TMPDIR_TEST/reg-bad.json"
printf 'not valid json at all' > "$REG_BAD"

# Non-existent path.
REG_MISSING="$TMPDIR_TEST/does-not-exist.json"

# --- Test harness ------------------------------------------------------------
FAILED=0

run_case() {
    local input="$1"
    local cli="${2:-$STUB_FULL}"
    local extra_env="${3:-}"
    local conf="${4:-$STUB_CONF}"
    # Build env: set both CLI seams so routing is deterministic regardless of
    # whether a built dist/confluence.js exists at the resolved repo root.
    if [ -n "$extra_env" ]; then
        printf '%s' "$input" | env "JIRA_CLI=$cli" "CONFLUENCE_CLI=$conf" "$extra_env" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env "JIRA_CLI=$cli" "CONFLUENCE_CLI=$conf" bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

# run_case_reg: use BACKENDS_REGISTRY instead of JIRA_CLI seam.
run_case_reg() {
    local input="$1" registry="$2" extra_env="${3:-}"
    if [ -n "$extra_env" ]; then
        printf '%s' "$input" | env "BACKENDS_REGISTRY=$registry" "$extra_env" bash "$HOOK" >/dev/null 2>&1
    else
        printf '%s' "$input" | env "BACKENDS_REGISTRY=$registry" bash "$HOOK" >/dev/null 2>&1
    fi
    echo "$?"
}

assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_stderr_contains() {
    local label="$1" input="$2" needle="$3" cli="${4:-$STUB_FULL}" conf="${5:-$STUB_CONF}"
    local out
    out=$(printf '%s' "$input" | env "JIRA_CLI=$cli" "CONFLUENCE_CLI=$conf" bash "$HOOK" 2>&1 >/dev/null || true)
    case "$out" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — stderr missing: $needle"
            echo "--- got ---"
            echo "$out"
            echo "-----------"
            FAILED=$((FAILED + 1))
            ;;
    esac
}

# ============================================================================
# 1. ORIGINAL JIRA TEST CASES (1:1 migration)
# ============================================================================

echo "=== Original Jira test cases ==="

# --- Blocked tools (mapped verb present in FULL introspected set) ---
for tool in getJiraIssue searchJiraIssuesUsingJql createJiraIssue \
            editJiraIssue addCommentToJiraIssue getTransitionsForJiraIssue \
            transitionJiraIssue getVisibleJiraProjects createIssueLink; do
    rc=$(run_case "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "block $tool (verb present)" 2 "$rc"
done

# --- Both Jira connector prefixes route writes but preserve unsupported reads ---
# Missing live-prefix registration must fail the write and replacement-hint rows.
for prefix in mcp__plugin_atlassian_atlassian__ mcp__claude_ai_Atlassian_MCP__; do
    input="{\"tool_name\":\"${prefix}createJiraIssue\",\"tool_input\":{}}"
    rc=$(run_case "$input")
    assert_rc "block ${prefix}createJiraIssue" 2 "$rc"
    assert_stderr_contains "${prefix} write names CLI replacement" "$input" \
        'jira/dist/index.js create'
    assert_stderr_contains "${prefix} create hint points at --desc-file" "$input" \
        '--desc-file'
    out=$(printf '%s' "$input" | env "JIRA_CLI=$STUB_FULL" "CONFLUENCE_CLI=$STUB_CONF" bash "$HOOK" 2>&1 >/dev/null || true)
    case "$out" in
        *'--desc "'*) echo "FAIL ${prefix} create hint still shows inline --desc"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS ${prefix} create hint has no inline --desc" ;;
    esac
    rc=$(run_case "{\"tool_name\":\"${prefix}lookupJiraAccountId\",\"tool_input\":{}}")
    assert_rc "block ${prefix}lookupJiraAccountId (Jira is CLI-only; no CLI verb = unsupported)" 2 "$rc"
    rc=$(run_case "$input" "$STUB_REDUCED")
    assert_rc "block ${prefix}createJiraIssue when CLI lacks create (unsupported, never an MCP fallback)" 2 "$rc"
    rc=$(run_case "$input" "$STUB_FULL" 'MCP_JIRA_OK=1')
    assert_rc "bypass ${prefix}createJiraIssue with MCP_JIRA_OK" 0 "$rc"
done

# --- Autogeneration property: REMOVE verbs from the fixture ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createIssueLink","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block createIssueLink when 'link' verb absent (unsupported)" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__createJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block createJiraIssue when 'create' verb absent (unsupported)" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block getJiraIssue when 'get' verb still present" 2 "$rc"

# --- transition verb maps from TWO MCP methods ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block transitionJiraIssue (transition present)" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getTransitionsForJiraIssue","tool_input":{}}' "$STUB_REDUCED")
assert_rc "block getTransitionsForJiraIssue (transition present)" 2 "$rc"

# --- Substring guard: 'transitions' must NOT trigger 'transition' match ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' "$STUB_TRANS_ONLY")
assert_rc "block transitionJiraIssue when only 'transitions' present (no substring match: unsupported)" 2 "$rc"
assert_stderr_contains "transitionJiraIssue with only 'transitions' is unsupported, not a transition replacement" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' \
    'unsupported, extend the CLI' "$STUB_TRANS_ONLY"

# --- Stderr quality: each refusal must include the plugin verb ---
assert_stderr_contains "stderr names 'get' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    'jira/dist/index.js get'
assert_stderr_contains "stderr names 'transition' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__transitionJiraIssue","tool_input":{}}' \
    'jira/dist/index.js transition'
assert_stderr_contains "stderr names 'list' verb for JQL" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__searchJiraIssuesUsingJql","tool_input":{}}' \
    'jira/dist/index.js list'
assert_stderr_contains "stderr names 'link' verb" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__createIssueLink","tool_input":{}}' \
    'jira/dist/index.js link'
# An edit (commentId present) names the --edit form with that id.
assert_stderr_contains "addOrEditJiraIssueComment with commentId names comment --edit <id>" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__addOrEditJiraIssueComment","tool_input":{"issueIdOrKey":"HIMMEL-9","commentId":"10042"}}' \
    'jira/dist/index.js comment HIMMEL-9 --edit 10042'
assert_stderr_contains "addOrEditJiraIssueComment without commentId keeps the add hint" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__addOrEditJiraIssueComment","tool_input":{}}' \
    'jira/dist/index.js comment HIMMEL-N "<text>"'

# --- Allowed Atlassian tools (no verb in EITHER map → no plugin equivalent) ---
# NOTE: the Confluence page/search/spaces/comment methods are NO LONGER here —
# they now route to the confluence CLI (see the Confluence section below).
for tool in getIssueLinkTypes atlassianUserInfo \
            getAccessibleAtlassianResources fetch search \
            getConfluencePageInlineComments createConfluenceInlineComment; do
    rc=$(run_case "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "allow $tool" 0 "$rc"
done

# --- Jira is CLI-only: every Jira-named method is denied, so a
# CLI that cannot be introspected or is not built FAILS CLOSED (it used to fail open).
for tool in lookupJiraAccountId getJiraIssueTypeMetaWithFields \
            getJiraProjectIssueTypesMetadata addWorklogToJiraIssue \
            getJiraIssueRemoteIssueLinks; do
    rc=$(run_case "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "block $tool (Jira-named, no CLI verb: unsupported)" 2 "$rc"
done
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_ERR")
assert_rc "fail-closed: introspection error denies getJiraIssue" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_EMPTY")
assert_rc "fail-closed: empty introspection denies getJiraIssue" 2 "$rc"
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$TMPDIR_TEST/does-not-exist.js")
assert_rc "fail-closed: missing CLI file denies getJiraIssue" 2 "$rc"

# --- Non-Atlassian MCP tools — pass through ---
for tool in mcp__obsidian-vault__obsidian_get_file_contents \
            mcp__plugin_qmd_qmd__query \
            mcp__plugin_context7_context7__query-docs \
            mcp__plugin_playwright_playwright__browser_click; do
    rc=$(run_case "{\"tool_name\":\"${tool}\",\"tool_input\":{}}")
    assert_rc "passthrough $tool" 0 "$rc"
done

# --- Non-MCP tools (Bash, Edit, Read, etc.) — pass through ---
for tool in Bash Edit Write Read Grep PowerShell; do
    rc=$(run_case "{\"tool_name\":\"${tool}\",\"tool_input\":{}}")
    assert_rc "passthrough $tool" 0 "$rc"
done

# --- Bypass env var (backward compat MCP_JIRA_OK=1) ---
rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$STUB_FULL" 'MCP_JIRA_OK=1')
assert_rc "bypass MCP_JIRA_OK=1" 0 "$rc"

# Bypass must produce ZERO stderr.
stderr_bytes=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_JIRA_OK=1 bash "$HOOK" 2>&1 >/dev/null | wc -c | tr -d ' ')
assert_rc "bypass silent stderr" 0 "$stderr_bytes"

# --- Edge cases ---
rc=$(run_case '{"tool_input":{}}')
assert_rc "missing tool_name" 0 "$rc"

rc=$(run_case '')
assert_rc "empty input" 0 "$rc"

rc=$(run_case 'not json at all')
assert_rc "garbage JSON fail-closed" 2 "$rc"

rc=$(run_case "$(printf '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue\\r","tool_input":{}}')")
assert_rc "trailing CR in tool_name still blocks" 2 "$rc"

rc=$(run_case '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue ","tool_input":{}}')
assert_rc "trailing space in tool_name still blocks" 2 "$rc"

rc=$(run_case '{"tool_name":42,"tool_input":{}}')
assert_rc "non-string tool_name allows" 0 "$rc"

# ============================================================================
# 2. NEW CASES — registry-driven behaviour
# ============================================================================

echo ""
echo "=== Registry-driven cases ==="

# --- chain [mcp,cli,api] in registry → mcp ranked first → no hard block ---
# We need JIRA_CLI to still point at STUB_FULL for introspection but chain
# says mcp wins → allow.
# Build a registry that has the correct CLI path:
REG_MCP_FIRST_WITH_CLI="$TMPDIR_TEST/reg-mcp-first-with-cli.json"
write_registry "$REG_MCP_FIRST_WITH_CLI" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"mcp\", \"cli\", \"api\"]
  }
}"
rc=$(run_case_reg '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$REG_MCP_FIRST_WITH_CLI")
assert_rc "chain [mcp,cli,api]: allow getJiraIssue (mcp ranked above cli)" 0 "$rc"

# --- enabled:false in registry → allow ---
REG_DISABLED_WITH_CLI="$TMPDIR_TEST/reg-disabled-with-cli.json"
write_registry "$REG_DISABLED_WITH_CLI" "{
  \"jira\": {
    \"enabled\": false,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  }
}"
rc=$(run_case_reg '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' "$REG_DISABLED_WITH_CLI")
assert_rc "enabled:false in registry: allow getJiraIssue" 0 "$rc"

# --- MCP_ALL_OK=1 bypasses all services ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_ALL_OK=1 bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "MCP_ALL_OK=1 bypasses all" 0 "$rc"

# --- Malformed registry → code defaults still block Jira ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_BAD" "JIRA_CLI=$STUB_FULL" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "malformed registry falls back to code defaults: block getJiraIssue" 2 "$rc"

# --- Absent BACKENDS_REGISTRY path → code defaults still block Jira ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_MISSING" "JIRA_CLI=$STUB_FULL" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "absent registry path falls back to code defaults: block getJiraIssue" 2 "$rc"

# --- Service with no mcp_prefix (bitbucket/github in defaults) — passthrough ---
# Bitbucket doesn't have a registered mcp_prefix in defaults, so any
# mcp__plugin_bitbucket__* style call should pass through (no prefix match).
rc=$(run_case '{"tool_name":"mcp__plugin_bitbucket__getSomething","tool_input":{}}')
assert_rc "no-prefix service: mcp__plugin_bitbucket__ passes through" 0 "$rc"

# --- Refusal message contains api advisory when chain includes api tier ---
# Confluence keeps cli:api:mcp, so its refusal carries the api advisory; Jira
# (CLI-only) never does.
assert_stderr_contains "confluence refusal includes api advisory" \
    '{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{}}' \
    'raw REST (curl/WebFetch)'

# --- MCP_<SERVICE_UPPER>_OK=1 per-service bypass ---
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "JIRA_CLI=$STUB_FULL" MCP_JIRA_OK=1 bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "MCP_JIRA_OK=1 per-service bypass" 0 "$rc"

# --- Registry with [cli,mcp] (no api) → api advisory absent from message ---
REG_NO_API="$TMPDIR_TEST/reg-no-api.json"
write_registry "$REG_NO_API" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"mcp\"]
  }
}"
out_no_api=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_NO_API" bash "$HOOK" 2>&1 >/dev/null || true)
case "$out_no_api" in
    *"raw REST"*)
        echo "FAIL chain without api tier: api advisory unexpectedly present in stderr"
        FAILED=$((FAILED + 1))
        ;;
    *)
        echo "PASS chain without api tier: api advisory absent from stderr"
        ;;
esac

# ============================================================================
# 3. CONFLUENCE ROUTING — two services share the Atlassian prefix
# ============================================================================

echo ""
echo "=== Confluence routing (HIMMEL-437) ==="

# The confluence SERVICE must be in the active registry for it to be evaluated.
# A repo backends.json (resolved via CLAUDE_PROJECT_DIR) may predate this change,
# so force the CODE DEFAULTS path (which includes confluence) via a missing
# BACKENDS_REGISTRY — identical to the "absent registry" jira case above — and
# point both CLI seams at the stubs.
# run a confluence case through forced code-defaults; $1=input, $2=confluence stub.
run_case_conf() {
    local input="$1" conf="${2:-$STUB_CONF}"
    printf '%s' "$input" \
        | env "BACKENDS_REGISTRY=$REG_MISSING" "JIRA_CLI=$STUB_FULL" "CONFLUENCE_CLI=$conf" bash "$HOOK" >/dev/null 2>&1
    echo "$?"
}

# Registry FILE that includes BOTH atlassian services (mirrors the real
# scripts/backends.json). Exercises the registry-file path —
# the one that actually runs in production — not just the code-defaults path.
REG_ATLASSIAN_BOTH="$TMPDIR_TEST/reg-atlassian-both.json"
write_registry "$REG_ATLASSIAN_BOTH" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  },
  \"confluence\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_CONF}\",
    \"chain\": [\"cli\", \"api\", \"mcp\"]
  }
}"

# Block each Confluence MCP method whose mapped verb the confluence CLI has.
# getConfluencePage → "page get" exercises the multi-word strip fix (Step 5).
for tool in getConfluencePage createConfluencePage updateConfluencePage \
            searchConfluenceUsingCql getConfluenceSpaces \
            getConfluencePageFooterComments createConfluenceFooterComment; do
    rc=$(run_case_conf "{\"tool_name\":\"mcp__plugin_atlassian_atlassian__${tool}\",\"tool_input\":{}}")
    assert_rc "block $tool (confluence verb present)" 2 "$rc"
done

# Multi-word verb survives whitespace strip: getConfluencePage → "page get".
out=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_MISSING" "JIRA_CLI=$STUB_FULL" "CONFLUENCE_CLI=$STUB_CONF" bash "$HOOK" 2>&1 >/dev/null || true)
case "$out" in
    *"confluence.js page get"*) echo "PASS stderr names confluence 'page get' verb" ;;
    *) echo "FAIL stderr names confluence 'page get' verb"; echo "--- got ---"; echo "$out"; echo "-----------"; FAILED=$((FAILED + 1)) ;;
esac

# Allow when the confluence CLI lacks the mapped verb (reduced stub: no 'page get').
rc=$(run_case_conf '{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{}}' "$STUB_CONF_REDUCED")
assert_rc "allow getConfluencePage when confluence CLI lacks 'page get'" 0 "$rc"

# Jira call is still routed to the jira CLI and NOT shadowed by the confluence arm.
out=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_MISSING" "JIRA_CLI=$STUB_FULL" "CONFLUENCE_CLI=$STUB_CONF" bash "$HOOK" 2>&1 >/dev/null || true)
case "$out" in
    *"jira/dist/index.js get"*) echo "PASS jira call names jira CLI (not confluence)" ;;
    *) echo "FAIL jira call names jira CLI (not confluence)"; echo "--- got ---"; echo "$out"; echo "-----------"; FAILED=$((FAILED + 1)) ;;
esac

# Per-service bypass for confluence (generic MCP_<SERVICE>_OK eval path).
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_MISSING" "CONFLUENCE_CLI=$STUB_CONF" MCP_CONFLUENCE_OK=1 bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "MCP_CONFLUENCE_OK=1 per-service bypass" 0 "$rc"

# REGISTRY-FILE path (production): drive a Confluence call through a registry
# that includes the confluence service — this is the path that runs when
# scripts/backends.json exists. Guards against the backends.json entry being
# dropped (the code-defaults cases above would still pass without it).
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getConfluencePage","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_ATLASSIAN_BOTH" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "registry-file path: block getConfluencePage (confluence service in registry)" 2 "$rc"

# The jira service in the SAME shared-prefix registry still blocks (loop covers both).
rc=$(printf '%s' '{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}' \
    | env "BACKENDS_REGISTRY=$REG_ATLASSIAN_BOTH" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "registry-file path: block getJiraIssue (jira not shadowed by confluence)" 2 "$rc"

# ============================================================================
# 3b. LIVE ATLASSIAN CONNECTOR GAPS
# ============================================================================

echo ""
echo "=== Live Atlassian connector gaps ==="

LIVE=mcp__claude_ai_Atlassian_MCP__

# Gap 1 — the code defaults carry the live prefix: a missing/malformed
# registry must still block live createJiraIssue and live Confluence.
rc=$(run_case_conf "{\"tool_name\":\"${LIVE}createJiraIssue\",\"tool_input\":{}}")
assert_rc "code defaults: block live createJiraIssue" 2 "$rc"
rc=$(run_case_conf "{\"tool_name\":\"${LIVE}getConfluenceContent\",\"tool_input\":{}}")
assert_rc "code defaults: block live getConfluenceContent" 2 "$rc"
rc=$(printf '%s' "{\"tool_name\":\"${LIVE}createJiraIssue\",\"tool_input\":{}}" \
    | env "BACKENDS_REGISTRY=$REG_BAD" "JIRA_CLI=$STUB_FULL" bash "$HOOK" >/dev/null 2>&1; echo "$?")
assert_rc "malformed registry: block live createJiraIssue" 2 "$rc"

# Gap 2 — live comment + live Confluence tools route to the CLI, through the
# shipped scripts/backends.json (the registry-file path production runs).
rc=$(run_case "{\"tool_name\":\"${LIVE}addOrEditJiraIssueComment\",\"tool_input\":{}}")
assert_rc "block live addOrEditJiraIssueComment" 2 "$rc"
assert_stderr_contains "live comment names the jira comment replacement" \
    "{\"tool_name\":\"${LIVE}addOrEditJiraIssueComment\",\"tool_input\":{}}" \
    'jira/dist/index.js comment'
for tool in getConfluenceContent createConfluenceContent updateConfluenceContent searchConfluence; do
    rc=$(run_case "{\"tool_name\":\"${LIVE}${tool}\",\"tool_input\":{}}")
    assert_rc "block live $tool" 2 "$rc"
done
rc=$(run_case "{\"tool_name\":\"${LIVE}getConfluenceContent\",\"tool_input\":{}}" "$STUB_FULL" '' "$STUB_CONF_REDUCED")
assert_rc "allow live getConfluenceContent when confluence CLI lacks 'page get'" 0 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}getConfluenceContent\",\"tool_input\":{}}" "$STUB_FULL" 'MCP_CONFLUENCE_OK=1')
assert_rc "bypass live getConfluenceContent with MCP_CONFLUENCE_OK" 0 "$rc"

# Gap 3 — executeWrite/executeRead/executeDestructive route on the tool name
# they carry, not on the wrapper name.
for wrapper in executeWrite executeRead executeDestructive; do
    rc=$(run_case "{\"tool_name\":\"${LIVE}${wrapper}\",\"tool_input\":{\"name\":\"createJiraIssue\",\"inputs\":{}}}")
    assert_rc "block ${wrapper}{name:createJiraIssue}" 2 "$rc"
done
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":\"addOrEditJiraIssueComment\"}}")
assert_rc "block executeWrite{name:addOrEditJiraIssueComment}" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"getConfluenceContent\"}}")
assert_rc "block executeRead{name:getConfluenceContent}" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":\"lookupJiraAccountId\"}}")
assert_rc "block executeWrite{name:lookupJiraAccountId} (Jira is CLI-only: unsupported)" 2 "$rc"
# A wrapper call whose real tool name cannot be read fails CLOSED.
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{}}")
assert_rc "block executeWrite with no name" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":42}}")
assert_rc "block executeWrite with number name" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":{\"x\":1}}}")
assert_rc "block executeWrite with object name" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":\"createJiraIssue\"}")
assert_rc "block executeWrite with non-object tool_input" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\"}")
assert_rc "block executeWrite with no tool_input" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":\"CreateJiraIssue\"}}")
assert_rc "block executeWrite{name:CreateJiraIssue} (case variant of a mapped name)" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":\"deleteEverything\"}}")
assert_rc "block executeWrite{name:deleteEverything} (unknown name)" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"lookupJiraAccountId\"}}")
assert_rc "block executeRead{name:lookupJiraAccountId} (Jira reads are denied too)" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{}}" "$STUB_FULL" 'MCP_ALL_OK=1')
assert_rc "bypass MCP_ALL_OK=1 on executeWrite with no name" 0 "$rc"
assert_stderr_contains "no-name deny names the CLI route" \
    "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{}}" 'scripts/jira/dist/index.js'
rc=$(run_case "{\"tool_name\":\"${LIVE}executeWrite\",\"tool_input\":{\"name\":\"createJiraIssue\"}}" "$STUB_REDUCED")
assert_rc "block executeWrite{name:createJiraIssue} when CLI lacks create (unsupported)" 2 "$rc"

# ============================================================================
# 3c. JIRA IS CLI-ONLY
# ============================================================================
#
# Himmel-owned Jira work goes through the Jira CLI. Every Atlassian MCP method
# whose name contains "Jira" (and an execute* wrapper around one) is denied,
# READS INCLUDED. A chain of ["cli"] alone cannot do this (the chain loop blocks
# only when mcp follows cli), so an explicit branch in the hook enforces it.

echo ""
echo "=== Jira CLI-only ==="

ATL=mcp__plugin_atlassian_atlassian__
PRIMARY_ROOT=$(git -C "$SCRIPT_DIR" worktree list --porcelain | sed -n 's/^worktree //p;1q')

# stderr_of <input> [jira-cli] [env-assignment...] — hook stderr for one payload.
stderr_of() {
    local input="$1" cli="${2:-$STUB_FULL}"
    shift; [ "$#" -gt 0 ] && shift
    printf '%s' "$input" | { env "JIRA_CLI=$cli" "CONFLUENCE_CLI=$STUB_CONF" "$@" bash "$HOOK" >/dev/null; } 2>&1 || true  # swallow-ok: a deny exits 2 and only its stderr is wanted
}

assert_stderr_lacks() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*)
            echo "FAIL $label — stderr unexpectedly contains: $needle"
            echo "--- got ---"; echo "$haystack"; echo "-----------"
            FAILED=$((FAILED + 1))
            ;;
        *) echo "PASS $label" ;;
    esac
}

# The shipped registry: Jira CLI-only, Confluence/GitHub/Bitbucket unchanged.
REPO_ROOT_UNDER_TEST=$(cd "$SCRIPT_DIR/../.." && pwd)
if [ "$(jq -c '.jira.chain' "$REPO_ROOT_UNDER_TEST/scripts/backends.json")" = '["cli"]' ]; then
    echo "PASS shipped backends.json: jira chain is CLI-only"
else
    echo "FAIL shipped backends.json: jira chain is not [\"cli\"]"
    FAILED=$((FAILED + 1))
fi
for svc in confluence bitbucket github; do
    if [ "$(jq -c ".${svc}.chain" "$REPO_ROOT_UNDER_TEST/scripts/backends.json")" = '["cli","api","mcp"]' ]; then
        echo "PASS shipped backends.json: $svc chain unchanged"
    else
        echo "FAIL shipped backends.json: $svc chain changed"
        FAILED=$((FAILED + 1))
    fi
done

# A Jira READ is denied and names the CLI replacement (absolute, primary checkout).
READ_IN="{\"tool_name\":\"${ATL}getJiraIssue\",\"tool_input\":{\"issueIdOrKey\":\"HIMMEL-1\"}}"
rc=$(run_case "$READ_IN")
assert_rc "Jira read getJiraIssue is denied" 2 "$rc"
out=$(stderr_of "$READ_IN")
assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *)
            echo "FAIL $label — missing: $needle"
            echo "--- got ---"; echo "$haystack"; echo "-----------"
            FAILED=$((FAILED + 1))
            ;;
    esac
}
assert_contains "Jira read names the absolute CLI replacement" "$out" "node ${PRIMARY_ROOT}/scripts/jira/dist/index.js get"
assert_stderr_lacks "Jira refusal drops the api advisory" "$out" 'raw REST'

# A Jira WRITE is denied with the CLI replacement.
WRITE_IN="{\"tool_name\":\"${ATL}editJiraIssue\",\"tool_input\":{}}"
rc=$(run_case "$WRITE_IN")
assert_rc "Jira write editJiraIssue is denied" 2 "$rc"
assert_contains "Jira write names the CLI edit replacement" "$(stderr_of "$WRITE_IN")" "node ${PRIMARY_ROOT}/scripts/jira/dist/index.js edit"

# An unmapped Jira method (no CLI verb) is "unsupported", never an api/MCP fallback.
UNMAPPED_IN="{\"tool_name\":\"${ATL}getJiraIssueTypeMetaWithFields\",\"tool_input\":{}}"
rc=$(run_case "$UNMAPPED_IN")
assert_rc "unmapped Jira method is denied" 2 "$rc"
out=$(stderr_of "$UNMAPPED_IN")
assert_contains "unmapped Jira method prints unsupported, extend the CLI" "$out" 'unsupported, extend the CLI'
assert_stderr_lacks "unmapped Jira method suggests no REST fallback" "$out" 'raw REST'
assert_stderr_lacks "unmapped Jira method names no replacement command" "$out" 'plugin has an equivalent'

# A mapped verb the CLI lacks is also unsupported.
assert_contains "mapped verb the CLI lacks prints unsupported" "$(stderr_of "{\"tool_name\":\"${ATL}createIssueLink\",\"tool_input\":{}}" "$STUB_REDUCED")" 'unsupported, extend the CLI'

# Wrappers around a Jira method are denied (read wrapper included).
rc=$(run_case "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"getJiraIssue\"}}")
assert_rc "executeRead{name:getJiraIssue} is denied" 2 "$rc"
assert_contains "executeRead{name:getJiraIssue} names the get replacement" \
    "$(stderr_of "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"getJiraIssue\"}}")" 'jira/dist/index.js get'
rc=$(run_case "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"someNewJiraThing\"}}")
assert_rc "executeRead{name:someNewJiraThing} (unknown Jira name) is denied" 2 "$rc"
assert_contains "wrapped unknown Jira name prints unsupported" \
    "$(stderr_of "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"someNewJiraThing\"}}")" 'unsupported, extend the CLI'

# Case-insensitive on the Jira marker.
rc=$(run_case "{\"tool_name\":\"${ATL}getjiraissue\",\"tool_input\":{}}")
assert_rc "lower-cased getjiraissue is denied" 2 "$rc"

# MCP_JIRA_OK=1 stays the documented bypass, silent.
rc=$(run_case "$UNMAPPED_IN" "$STUB_FULL" 'MCP_JIRA_OK=1')
assert_rc "MCP_JIRA_OK=1 allows an unmapped Jira method" 0 "$rc"
rc=$(run_case "$READ_IN" "$TMPDIR_TEST/does-not-exist.js" 'MCP_JIRA_OK=1')
assert_rc "MCP_JIRA_OK=1 allows a Jira read with the CLI unbuilt" 0 "$rc"
assert_rc "MCP_JIRA_OK=1 bypass is silent" 0 "$(stderr_of "$UNMAPPED_IN" "$STUB_FULL" MCP_JIRA_OK=1 | wc -c | tr -d ' ')"
rc=$(run_case "$READ_IN" "$STUB_FULL" 'MCP_CONFLUENCE_OK=1')
assert_rc "MCP_CONFLUENCE_OK=1 does not bypass Jira" 2 "$rc"

# A registry whose jira chain is exactly ["cli"] enforces the branch (the chain loop alone would not).
REG_CLI_ONLY="$TMPDIR_TEST/reg-cli-only.json"
write_registry "$REG_CLI_ONLY" "{
  \"jira\": {
    \"enabled\": true,
    \"mcp_prefix\": \"mcp__plugin_atlassian_atlassian__\",
    \"cli\": \"${STUB_FULL}\",
    \"chain\": [\"cli\"]
  }
}"
rc=$(run_case_reg "$READ_IN" "$REG_CLI_ONLY")
assert_rc "registry chain [cli]: Jira read is denied" 2 "$rc"
rc=$(run_case_reg "$UNMAPPED_IN" "$REG_CLI_ONLY")
assert_rc "registry chain [cli]: unmapped Jira method is denied" 2 "$rc"
rc=$(run_case_reg "$UNMAPPED_IN" "$REG_CLI_ONLY" 'MCP_JIRA_OK=1')
assert_rc "registry chain [cli]: MCP_JIRA_OK=1 bypasses" 0 "$rc"

# Confluence (same Atlassian prefix) keeps its cli:api:mcp behaviour on the shipped registry.
rc=$(run_case "{\"tool_name\":\"${ATL}getConfluencePage\",\"tool_input\":{}}")
assert_rc "Confluence getConfluencePage still denied when its CLI has the verb" 2 "$rc"
rc=$(run_case "{\"tool_name\":\"${ATL}getConfluencePage\",\"tool_input\":{}}" "$STUB_FULL" '' "$STUB_CONF_REDUCED")
assert_rc "Confluence getConfluencePage still allowed when its CLI lacks the verb" 0 "$rc"
rc=$(run_case "{\"tool_name\":\"${ATL}getConfluencePage\",\"tool_input\":{}}" "$STUB_FULL" '' "$TMPDIR_TEST/no-confluence.js")
assert_rc "Confluence getConfluencePage still falls open when its CLI is not built" 0 "$rc"
rc=$(run_case "{\"tool_name\":\"${ATL}createConfluenceInlineComment\",\"tool_input\":{}}")
assert_rc "Confluence unmapped method still allowed" 0 "$rc"
rc=$(run_case "{\"tool_name\":\"${LIVE}executeRead\",\"tool_input\":{\"name\":\"deleteEverything\"}}")
assert_rc "executeRead{name:deleteEverything} (unknown, non-Jira) is still denied" 2 "$rc"

# The create hint names the seven sections and every placement/home flag, and
# is a command the CLI accepts as written (placeholders are the only open slots).
out=$(stderr_of "{\"tool_name\":\"${ATL}createJiraIssue\",\"tool_input\":{}}")
for needle in 'Impact, What, Why, Plan, DoD, Proof, Agent detail' \
              '--proposed-version <v>' '--backlog --proposed-version backlog --why <line>' \
              '--fix-version <v>' '--gate <reason>' '--parent <EPIC-KEY>' '--labels standalone' \
              '--desc-file' '--sector'; do
    assert_contains "create hint names: $needle" "$out" "$needle"
done
assert_stderr_lacks "create hint names no inline --desc" "$out" '--desc "'

# ============================================================================
# 4. VERDICT EQUALITY ACROSS CHECKOUTS
# ============================================================================
#
# The property that was missing: for the SAME payload, this hook must return
# the SAME verdict whether it is invoked from the primary checkout or from a
# linked worktree. It did not — every backend CLI is a path under an untracked
# dist/ build artifact that exists only in the primary, the probe resolved it
# against the INVOKING checkout, and so the guard fell open (rc=0) in every
# worktree while refusing (rc=2) from the primary, on identical input.
#
# The fixture reproduces that world exactly: a throwaway repo whose registry
# points at a relative CLI path that is .gitignored — so it is present in the
# primary and ABSENT from the linked worktree, the same way scripts/jira/dist/
# is. The hook itself is COPIED into the fixture (it resolves the primary from
# its own location), so both checkouts run the real script under test.
#
# These cases are deliberately NOT stubbed via JIRA_CLI/CONFLUENCE_CLI — those
# seams bypass path resolution entirely, which is exactly why every section
# above could not have caught this.

echo ""
echo "=== Verdict equality across checkouts (HIMMEL-2237) ==="

EQ_ROOT=$(fixture_mktemp_dir) || exit 1
EQ_PRIMARY="$EQ_ROOT/primary"
EQ_WORKTREE="$EQ_ROOT/wt"
EQ_CLI="$EQ_PRIMARY/scripts/fakecli/index.js"
mkdir -p "$EQ_PRIMARY"

eq_setup_rc=0
(
    fixture_enter_git_init_dir "$EQ_PRIMARY" || exit 1
    git init -q -b main || exit 1
    git config user.email himmel-fixture@example.invalid
    git config user.name "himmel fixture"
    mkdir -p scripts/hooks scripts/fakecli
    cp "$HOOK" scripts/hooks/block-backend-tier.sh || exit 1
    # scripts/fakecli/ stands in for scripts/jira/dist/: a build artifact git
    # never carries into a linked worktree.
    printf '%s\n' 'scripts/fakecli/' > .gitignore
    cat > scripts/backends.json <<'ENDJSON'
{
  "jira": {
    "enabled": true,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "scripts/fakecli/index.js",
    "chain": ["cli", "api", "mcp"]
  }
}
ENDJSON
    git add .gitignore scripts/hooks/block-backend-tier.sh scripts/backends.json || exit 1
    git -c commit.gpgsign=false commit -q --no-verify -m "fixture" || exit 1
    git worktree add -q "$EQ_WORKTREE" -b probe >/dev/null 2>&1 || exit 1
) || eq_setup_rc=$?

if [ "$eq_setup_rc" -ne 0 ]; then
    echo "FAIL verdict-equality fixture setup (rc=$eq_setup_rc)"
    FAILED=$((FAILED + 1))
else
    # Created AFTER the commit, so it is untracked: present in the primary,
    # absent from the worktree — exactly the dist/ situation.
    make_stub "$EQ_CLI" get list transition

    # Invoke the fixture's OWN copy of the hook from inside <checkout>, with
    # CLAUDE_PROJECT_DIR pointing there — the shape a real session has. No
    # JIRA_CLI/CONFLUENCE_CLI/BACKENDS_REGISTRY seams: path resolution IS the
    # thing under test, and `env -u` clears any inherited value.
    eq_rc_at() {
        local checkout="$1" input="$2"
        printf '%s' "$input" | (
            cd "$checkout" || exit 99
            env -u JIRA_CLI -u CONFLUENCE_CLI -u BACKENDS_REGISTRY \
                "CLAUDE_PROJECT_DIR=$checkout" \
                bash "$checkout/scripts/hooks/block-backend-tier.sh" >/dev/null 2>&1
        )
        echo "$?"
    }

    eq_stderr_at() {
        local checkout="$1" input="$2"
        printf '%s' "$input" | (
            cd "$checkout" || exit 99
            # Capture ONLY stderr: stdout is discarded inside the group, then the
            # group's stderr becomes this subshell's stdout. Brace-group form
            # clarifies the intent for SC2069.
            { env -u JIRA_CLI -u CONFLUENCE_CLI -u BACKENDS_REGISTRY \
                "CLAUDE_PROJECT_DIR=$checkout" \
                bash "$checkout/scripts/hooks/block-backend-tier.sh" >/dev/null; } 2>&1
        ) || true
    }

    # assert_equal_verdicts <label> <expected-rc> <primary-rc> <worktree-rc>
    assert_equal_verdicts() {
        local label="$1" expected="$2" prc="$3" wrc="$4"
        if [ "$prc" = "$wrc" ] && [ "$prc" = "$expected" ]; then
            echo "PASS $label (primary=$prc worktree=$wrc)"
        else
            echo "FAIL $label — expected BOTH rc=$expected, got primary=$prc worktree=$wrc"
            FAILED=$((FAILED + 1))
        fi
    }

    assert_contains() {
        local label="$1" haystack="$2" needle="$3"
        case "$haystack" in
            *"$needle"*) echo "PASS $label" ;;
            *)
                echo "FAIL $label — missing: $needle"
                echo "--- got ---"; echo "$haystack"; echo "-----------"
                FAILED=$((FAILED + 1))
                ;;
        esac
    }

    EQ_MAPPED='{"tool_name":"mcp__plugin_atlassian_atlassian__getJiraIssue","tool_input":{}}'
    EQ_UNMAPPED='{"tool_name":"mcp__plugin_atlassian_atlassian__lookupJiraAccountId","tool_input":{}}'

    # Direction 1 — MCP call WITH a plugin equivalent ('get' is in the primary
    # CLI's verb list): REFUSED from BOTH checkouts. This is the regression —
    # the worktree returned 0 here before the fix.
    eq_p=$(eq_rc_at "$EQ_PRIMARY" "$EQ_MAPPED")
    eq_w=$(eq_rc_at "$EQ_WORKTREE" "$EQ_MAPPED")
    assert_equal_verdicts "verdict equality: mapped method REFUSED from primary and worktree" 2 "$eq_p" "$eq_w"

    # The worktree refusal must be the real refusal, not an incidental rc=2.
    assert_contains "worktree refusal names the plugin replacement" \
        "$(eq_stderr_at "$EQ_WORKTREE" "$EQ_MAPPED")" 'plugin has an equivalent'

    # Direction 2 — MCP call WITHOUT a plugin equivalent (unmapped method):
    # ALLOWED from BOTH. Guards against "arm it by blocking everything".
    eq_p=$(eq_rc_at "$EQ_PRIMARY" "$EQ_UNMAPPED")
    eq_w=$(eq_rc_at "$EQ_WORKTREE" "$EQ_UNMAPPED")
    assert_equal_verdicts "verdict equality: unmapped method ALLOWED from primary and worktree" 0 "$eq_p" "$eq_w"

    # Carve-out control — and the anti-vacuous control for direction 1. Delete
    # the PRIMARY's CLI (a fresh clone that never built) and both checkouts
    # must fall open WITH the advisory. That the worktree verdict flips 2 -> 0
    # purely because the PRIMARY's CLI vanished proves the worktree case above
    # genuinely introspected the primary's CLI rather than passing by luck.
    rm -f "$EQ_CLI"
    eq_p=$(eq_rc_at "$EQ_PRIMARY" "$EQ_MAPPED")
    eq_w=$(eq_rc_at "$EQ_WORKTREE" "$EQ_MAPPED")
    assert_equal_verdicts "carve-out: primary CLI absent → ALLOWED from primary and worktree" 0 "$eq_p" "$eq_w"

    assert_contains "carve-out advisory on stderr (primary)" \
        "$(eq_stderr_at "$EQ_PRIMARY" "$EQ_MAPPED")" 'falling OPEN'
    assert_contains "carve-out advisory on stderr (worktree)" \
        "$(eq_stderr_at "$EQ_WORKTREE" "$EQ_MAPPED")" 'falling OPEN'

    # Jira CLI-only: the same fixtures with a ["cli"]-only Jira
    # chain. The CLI is NOT built (removed above), and now that DENIES with a
    # build hint from BOTH checkouts instead of falling open.
    for eq_checkout in "$EQ_PRIMARY" "$EQ_WORKTREE"; do
        cat > "$eq_checkout/scripts/backends.json" <<'ENDJSON'
{
  "jira": {
    "enabled": true,
    "mcp_prefix": "mcp__plugin_atlassian_atlassian__",
    "cli": "scripts/fakecli/index.js",
    "chain": ["cli"]
  }
}
ENDJSON
    done
    eq_p=$(eq_rc_at "$EQ_PRIMARY" "$EQ_MAPPED")
    eq_w=$(eq_rc_at "$EQ_WORKTREE" "$EQ_MAPPED")
    assert_equal_verdicts "CLI-only, CLI not built: DENIED from primary and worktree" 2 "$eq_p" "$eq_w"
    eq_p=$(eq_rc_at "$EQ_PRIMARY" "$EQ_UNMAPPED")
    eq_w=$(eq_rc_at "$EQ_WORKTREE" "$EQ_UNMAPPED")
    assert_equal_verdicts "CLI-only, CLI not built: unmapped Jira method DENIED from primary and worktree" 2 "$eq_p" "$eq_w"
    for eq_checkout in "$EQ_PRIMARY" "$EQ_WORKTREE"; do
        eq_out=$(eq_stderr_at "$eq_checkout" "$EQ_MAPPED")
        assert_contains "CLI not built: deny names the build command ($(basename "$eq_checkout"))" \
            "$eq_out" "npm --prefix $EQ_PRIMARY/scripts/jira run build"
        assert_contains "CLI not built: deny says the CLI is not built ($(basename "$eq_checkout"))" \
            "$eq_out" 'not built'
        case "$eq_out" in
            *'falling OPEN'*) echo "FAIL CLI not built still falls open ($(basename "$eq_checkout"))"; FAILED=$((FAILED + 1)) ;;
            *) echo "PASS CLI not built no longer falls open ($(basename "$eq_checkout"))" ;;
        esac
    done
    rc=$(printf '%s' "$EQ_MAPPED" | (
        cd "$EQ_WORKTREE" || exit 99
        env -u JIRA_CLI -u CONFLUENCE_CLI -u BACKENDS_REGISTRY MCP_JIRA_OK=1 \
            "CLAUDE_PROJECT_DIR=$EQ_WORKTREE" \
            bash "$EQ_WORKTREE/scripts/hooks/block-backend-tier.sh" >/dev/null 2>&1
        echo "$?"
    ))
    assert_rc "CLI not built: MCP_JIRA_OK=1 bypass allows" 0 "$rc"

    # Control: once the CLI is built the same call is routed, not denied as unbuilt.
    make_stub "$EQ_CLI" get list transition
    assert_contains "CLI built: the deny names the CLI replacement" \
        "$(eq_stderr_at "$EQ_WORKTREE" "$EQ_MAPPED")" "node $EQ_PRIMARY/scripts/fakecli/index.js get"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
