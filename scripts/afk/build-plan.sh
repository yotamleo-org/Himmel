#!/usr/bin/env bash
# overnight/build-plan — emit a plan.md for /afk-shift.
#
# Queries jira for tickets matching the operator's filter, then prints a
# dispatch plan to stdout (or `--out` file). The plan is what the
# `/afk-shift` slash command shows the operator before they
# confirm dispatch. The dispatch step itself is handled by Claude
# (subagent Task tool); this script only emits the plan.
#
# Output shape:
#   # Overnight shift plan — <timestamp>
#
#   Filter:
#     project=<KEY> status=<status> limit=<N> priority=<order>
#
#   Tickets (1..N):
#   1. <KEY> — <type> — <status> — <title>
#   2. ...
#
#   Dispatch tree:
#     - one worktree per ticket: <type-slug>/<key>-<title-slug>
#     - one Task subagent per ticket
#     - per-agent guardrails: existing PreToolUse hooks (no extra config)
#
# Exit codes:
#   0  plan written to stdout (or --out path)
#   1  usage / input error
#   2  jira CLI failed
#   3  no tickets matched (warn — operator can still proceed manually)
set -euo pipefail

# old names, read only while HIMMEL_LEGACY_NAMES is on
# shellcheck source=../lib/env-alias.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/env-alias.sh"
for _an in PROJECT STATUS LIMIT PRIORITY; do alias_env "AFK_$_an" "OVERNIGHT_$_an"; done
PROJECT="${AFK_PROJECT:-}"
STATUS="${AFK_STATUS:-To Do,In Progress}"
LIMIT="${AFK_LIMIT:-5}"
PRIORITY="${AFK_PRIORITY:-key-desc}"
OUT_FILE=""
JIRA_CMD="${JIRA_CMD:-}"

usage() {
    cat <<'EOF'
Usage: build-plan.sh [--project KEY] [--status STATUS] [--limit N]
                     [--priority ORDER] [--out PATH]

Builds the dispatch plan for /afk-shift by querying jira.

Optional:
  --project KEY      Jira project key. Default $AFK_PROJECT, else HIMMEL in
                     the himmel clone, else the project's JIRA_PROJECT_KEY
                     (env or its .env); an adopted project without one is
                     refused (exit 1) rather than handed himmel's queue.
  --status STATUS    Comma-separated status filter passed to `jira list`.
                     Default: "To Do,In Progress".
  --limit N          Max tickets in the plan. Default 5.
  --priority ORDER   Documented sort order. v1 supports `key-desc` (default;
                     newest tickets first as a proxy for "most recently
                     filed"). Other values pass through unchanged for
                     forward-compat with a future priority-aware
                     jira CLI extension.
  --out PATH         Write plan to PATH in addition to stdout.

Environment overrides:
  JIRA_CMD           Override the jira plugin command (default:
                     `node $repo/scripts/jira/dist/index.js`, else the himmel
                     clone's at $HIMMEL_REPO in an adopted project). Tests
                     override this to inject canned ticket output.
  AFK_PROJECT        Default project key.
  AFK_STATUS         Default status filter.
  AFK_LIMIT          Default limit.
  AFK_PRIORITY       Default priority order.
                     Each AFK_* falls back to its old OVERNIGHT_* name while HIMMEL_LEGACY_NAMES is on.
  WHERE_ARE_WE_LEDGER  Override the where-are-we ledger path (L3
                     push-side provisioning; default
                     `$repo/.where-are-we/ledger.jsonl`). Tests seed a temp ledger.
  PROVISION_CMD      Override the provision CLI (default
                     `node $repo/scripts/where-are-we/provision.mjs`).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project)  PROJECT="${2:-HIMMEL}"; shift 2 ;;
        --status)   STATUS="${2:-To Do,In Progress}"; shift 2 ;;
        --limit)    LIMIT="${2:-5}"; shift 2 ;;
        --priority) PRIORITY="${2:-key-desc}"; shift 2 ;;
        --out)      OUT_FILE="${2:-}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERR build-plan: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
    echo "ERR build-plan: --limit must be a positive integer (got '$LIMIT')" >&2
    exit 1
fi

# Resolve the repo root unconditionally: the where-are-we
# provisioning seams below need it even when JIRA_CMD is injected (tests do), so
# it must NOT be assigned only inside the `if [ -z "$JIRA_CMD" ]` block — under
# `set -u` an unset $repo_root would abort the script.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root=$(cd "$script_dir/../.." && pwd)

# The queue is the current project's (project-state.sh): HIMMEL in the himmel
# clone, else the project's own JIRA_PROJECT_KEY.
if [ -z "$PROJECT" ]; then
    # shellcheck source=project-state.sh
    . "$script_dir/project-state.sh"
    if afk_legacy_paths; then
        PROJECT=HIMMEL
    else
        # Never load_dotenv here: it reads ~/.himmel/himmel.conf first, which on a
        # himmel station names HIMMEL. The key comes from the process env or the
        # project's own .env (this checkout's, then the primary checkout's).
        PROJECT="${JIRA_PROJECT_KEY:-}"
        env_dirs=$(git rev-parse --show-toplevel 2>/dev/null)
        common=$(afk_git_common_dir 2>/dev/null) && case "$common" in */.git) env_dirs="$env_dirs
${common%/.git}" ;; esac
        while [ -z "$PROJECT" ] && IFS= read -r env_dir; do
            [ -n "$env_dir" ] && [ -f "$env_dir/.env" ] || continue
            PROJECT=$(sed -n -E "s/^(export[[:space:]]+)?JIRA_PROJECT_KEY=[\"']?([A-Za-z0-9_]*).*/\\2/p" "$env_dir/.env" | tail -n 1)
        done <<< "$env_dirs"
        if [ -z "$PROJECT" ]; then
            echo "ERR build-plan: JIRA_PROJECT_KEY is unset for this project — set it (env or the project's .env) or pass --project" >&2
            exit 1
        fi
    fi
fi

# Resolve jira CLI. Default: node $repo/scripts/jira/dist/index.js, run with a
# quoted path so a checkout path with spaces stays one argument.
jira_js=""
if [ -z "$JIRA_CMD" ]; then
    jira_js="$repo_root/scripts/jira/dist/index.js"
    if [ ! -f "$jira_js" ] && [ -n "${HIMMEL_REPO:-}" ]; then jira_js="$HIMMEL_REPO/scripts/jira/dist/index.js"; fi
    if [ ! -f "$jira_js" ] || ! command -v node >/dev/null 2>&1; then
        echo "ERR build-plan: jira CLI not found at $jira_js and JIRA_CMD not set — build it: (cd ${jira_js%/dist/index.js} && npm install && npm run build)" >&2
        exit 2
    fi
fi
jira_run() { if [ -n "$jira_js" ]; then node "$jira_js" "$@"; else $JIRA_CMD "$@"; fi; }

# where-are-we L3 push-side provisioning: each non-epic ticket's
# subagent prompt is pre-loaded with that ticket's prior ledger slice. Both
# seams are overridable for hermetic tests (mirrors JIRA_CMD).
LEDGER="${WHERE_ARE_WE_LEDGER:-$repo_root/.where-are-we/ledger.jsonl}"
PROVISION_CMD="${PROVISION_CMD:-}"
provision_run() { if [ -z "$PROVISION_CMD" ]; then node "$repo_root/scripts/where-are-we/provision.mjs" "$@"; else $PROVISION_CMD "$@"; fi; }

# Query. The jira CLI emits TSV: KEY \t TYPE \t STATUS \t TITLE.
if ! tickets_raw=$(jira_run list --project "$PROJECT" --status "$STATUS" --limit "$LIMIT" 2>/dev/null); then
    echo "ERR build-plan: jira list failed for project=$PROJECT status='$STATUS' limit=$LIMIT" >&2
    exit 2
fi

if [ -z "$tickets_raw" ]; then
    {
        echo "# Overnight shift plan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "_No tickets matched filter: project=$PROJECT status='$STATUS' limit=${LIMIT}_"
        echo
        echo "Operator: tweak filters or dispatch manually."
    } | tee ${OUT_FILE:+"$OUT_FILE"}
    exit 3
fi

# Build plan -----------------------------------------------------------

# Slugify a title (lowercase, non-alnum -> dash, trim, 30-char cap).
slugify() {
    local s
    s=$(printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-30 \
        | sed -E 's/-+$//')
    # Empty / whitespace-only title would yield an empty slug, producing
    # a dangling `feat/HIMMEL-N-` worktree path that clean-garden.sh
    # rejects. Fall back to a literal `ticket` placeholder.
    printf '%s' "${s:-ticket}"
}

# Choose worktree type from ticket type. jira `Task` -> `feat`,
# `Story` -> `feat`, `Bug` -> `fix`, `Epic` is excluded from dispatch
# (epics shouldn't be implemented as a single worktree).
choose_type() {
    case "$1" in
        Bug)              echo "fix" ;;
        Task|Story|*)     echo "feat" ;;
    esac
}

plan=$(
    {
        echo "# Overnight shift plan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## Filter"
        echo
        echo "- project: \`$PROJECT\`"
        echo "- status: \`$STATUS\`"
        echo "- limit: \`$LIMIT\`"
        echo "- priority: \`$PRIORITY\` (v1: key-desc; the jira CLI does not yet"
        echo "  expose the priority field)"
        echo
        echo "## Tickets"
        echo
        i=0
        while IFS=$'\t' read -r key type status title; do
            [ -z "$key" ] && continue
            # Epics: include in the plan as informational rows but mark
            # them as `skip` so the operator can decide.
            i=$((i+1))
            wtype=$(choose_type "$type")
            slug=$(slugify "$title")
            if [ "$type" = "Epic" ]; then
                echo "$i. **$key** — $type — $status — $title"
                echo "   - **SKIP** (epics are not directly dispatched)"
            else
                echo "$i. **$key** — $type — $status — $title"
                echo "   - worktree: \`$wtype/$key-$slug\`"
                echo "   - subagent prompt: \"Read $key spec via jira plugin, implement per ticket, run tests, commit + push + open PR\""
                # L3 push-side provisioning: embed this ticket's prior
                # ledger slice. Fail-open — no node/ledger/item → empty → block
                # skipped → plan unchanged (the `2>/dev/null || true` + empty-test
                # IS the guard; no separate node-presence check needed).
                slice=$(provision_run slice --ledger "$LEDGER" --for "$key" 2>/dev/null || true)
                if [ -n "$slice" ]; then
                    echo "   - prior ledger state:"
                    printf '%s\n' "$slice" | sed 's/^/     /'
                fi
            fi
        done <<< "$tickets_raw"
        echo
        echo "## Dispatch tree"
        echo
        echo "- One worktree per non-epic ticket (created via \`scripts/worktree.sh\`)."
        echo "- One Task subagent per ticket, running in parallel."
        echo "- Per-agent guardrails: existing PreToolUse hooks"
        echo "  (block-edit-on-main, block-read-secrets, block-mcp-when-plugin-exists)."
        echo
        echo "## After all subagents return"
        echo
        echo "- Write the consolidated morning report: one row per"
        echo "  ticket (ticket, branch, PR, status, outcome, decision) piped into"
        echo "  \`scripts/afk/morning-report.sh\` — decisions-needed grouped"
        echo "  at top; output path resolved via \`handover_root\`."
        echo "- Run \`/handover-flush\` to reconcile state across worktrees."
        echo "- Operator reads the ONE report, then drills into PRs"
        echo "  (\`/pr-check\`) + merges — no per-ticket discovery."
    }
)

if [ -n "$OUT_FILE" ]; then
    printf '%s\n' "$plan" > "$OUT_FILE"
fi
printf '%s\n' "$plan"
exit 0
