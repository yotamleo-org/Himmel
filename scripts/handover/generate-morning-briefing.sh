#!/usr/bin/env bash
# handover/generate-morning-briefing — daily 🌅 Morning Report generator.
#
# Core generator and morning-report schema. Templates live
# git/gh/jira/worktree state into the curated "🌅 Morning Report" schema and
# writes a dated report to the handover root (`$HANDOVER_DIR`, Mode B) or
# `<repo>/handovers/` (Mode A) — at ~zero Claude tokens by default. Sections,
# led by the four answers of v5 frame 16 (a field with no input says so):
#
#   ## ✅ What shipped    — merged PR / commit / Done counts
#   ## ⏳ What waits on you — open PRs + stale worktrees, GOs, worker questions, CI/review state
#   ## 💸 What it spent   — Claude usage of the last 24h + this report's cost
#   ## ▶️ What runs next  — in-flight count, release progress + first suggested step
#   ## TL;DR            — derived counts (heuristic; --llm enriches)
#   ## ✅ Completed       — merged PRs (gh) + commits + Done cross-ref
#   ## 🔴 In-flight WIP   — jira In Progress correlated to worktrees/open-PRs
#   ## 🧹 Stale worktrees — worktrees on MERGED-PR branches
#   ## 📋 Backlog         — flat To-Do list (--llm clusters by theme)
#   ## 📄 Docs drift     — mapped sources changed without their docs
#   ## Suggested order    — heuristic ordering (--llm enriches)
#
# Default run costs ~no Claude tokens. `--llm` enriches TL;DR + Suggested
# order + Backlog theme-clustering via a bounded interactive claude turn
# (the interactive form with stdin closed, NOT the headless -p/--print/--bg
# forms; stays on Max quota, passes the no-headless gate), failing open
# per-block to the deterministic heuristic.
#
# Output path via the single-root resolver:
#   - Mode B (HANDOVER_DIR set) → $HANDOVER_DIR/morning-report-$(date +%F).md
#   - Mode A (inline) → $repo/handovers/morning-report-$(date +%F).md
#
# Exit codes:
#   0  report written (stdout + --out path)
#   1  usage / input error
#   2  required tool missing or env unusable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
# forge_detect: the date-ranged merged-PR query below is a
# GitHub-specific `gh pr list --search` (no forge-seam verb covers a date range),
# so it's gated to a github origin — as are the PR-correlation calls.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/result.sh"
# Which tracker the current project uses (jira | local | none).
# shellcheck source=../lib/project-mode.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/project-mode.sh"

# himmel-only commands are hinted only where they ship (an adopted project has
# neither): cmd_hint NAME prints " (/NAME)" or nothing.
cmd_hint() {
    if [ -f "$SCRIPT_DIR/../../.claude/commands/$1.md" ]; then printf ' (/%s)' "$1"; fi
}

GH_CMD="${GH_CMD:-gh}"
GIT_CMD="${GIT_CMD:-git}"
JIRA_CMD="${JIRA_CMD:-}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
SINCE_SHA=""
since_all=0
SINCE_DATE=""
OUT_FILE=""
DRY_RUN=0
JIRA_LIMIT=200
LLM=0
LLM_MODEL="sonnet"
BACKLOG_LIMIT=40

usage() {
    cat <<'EOF'
Usage: generate-morning-briefing.sh [--since SHA] [--since-date YYYY-MM-DD]
                                    [--out PATH] [--jira-limit N]
                                    [--backlog-limit N] [--llm]
                                    [--llm-model MODEL] [--dry-run]

Generates the dated 🌅 Morning Report by templating live git/gh/jira/worktree
state into the curated schema. Default run costs ~no Claude tokens.

Optional:
  --since SHA              Marker commit. Default: last tag (`git
                           describe --tags --abbrev=0`) or `HEAD~50`.
  --since-date YYYY-MM-DD  Date filter for `gh pr list --search
                           'merged:>=DATE'`. Default: today LOCAL (date +%F),
                           inclusive.
  --out PATH               Output path. Default:
                           $HANDOVER_DIR/morning-report-$(date +%F).md
                           (Mode B) or $repo/handovers/... (Mode A).
  --jira-limit N           Max rows per jira status query. Default 200.
  --backlog-limit N        Max To-Do rows rendered in Backlog. Default 40.
  --llm                    Enrich TL;DR + Suggested order + Backlog clustering
                           via a bounded `claude` turn (default OFF). Also
                           enabled by MORNING_REPORT_LLM=1.
  --llm-model MODEL        Model for --llm. Default `sonnet`.
  --dry-run                Print the report to stdout; touch no files.

Environment overrides:
  GH_CMD / GIT_CMD / JIRA_CMD / CLAUDE_CMD   Test overrides.
  HANDOVER_DIR                               External handover root (Mode B).
  MORNING_REPORT_LLM=1                        Enable --llm.
  SHIFTS_FILE                                The shift record (default $HANDOVER_DIR/shifts.jsonl).
  MORNING_SHIFT_CMD / MORNING_SHIFT_SPEND_CMD  The shift helper (run first) and the spend reader.
  MORNING_TODAY=YYYY-MM-DD                   Test override of the report day.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)         SINCE_SHA="${2:-}"; shift 2 ;;
        --since-date)    SINCE_DATE="${2:-}"; shift 2 ;;
        --out)           OUT_FILE="${2:-}"; shift 2 ;;
        --jira-limit)    JIRA_LIMIT="${2:-200}"; shift 2 ;;
        --backlog-limit) BACKLOG_LIMIT="${2:-40}"; shift 2 ;;
        --llm)           LLM=1; shift ;;
        --llm-model)     LLM_MODEL="${2:-sonnet}"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "ERR briefing: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ "${MORNING_REPORT_LLM:-0}" = "1" ] && LLM=1

if ! command -v "${GIT_CMD%% *}" >/dev/null 2>&1; then
    echo "ERR briefing: required tool 'git' not on PATH" >&2
    exit 2
fi

repo_root=$($GIT_CMD rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    echo "ERR briefing: not inside a git repo" >&2
    exit 2
fi

# Resolve --since SHA when not passed.
if [ -z "$SINCE_SHA" ]; then
    if last_tag=$($GIT_CMD -C "$repo_root" describe --tags --abbrev=0 2>/dev/null); then
        SINCE_SHA="$last_tag"
    elif $GIT_CMD -C "$repo_root" rev-parse --verify -q "HEAD~50" >/dev/null 2>&1; then
        SINCE_SHA="HEAD~50"
    else
        # A project younger than 50 commits has no HEAD~50: list its whole history.
        SINCE_SHA="start of history"
        since_all=1
    fi
fi
# Markdown for the Source markers line: only a real revision is offered as --since.
since_marker="\`--since $SINCE_SHA\`"
[ "$since_all" -eq 1 ] && since_marker="the whole history (fewer than 50 commits)"

# LOCAL day, computed ONCE. Reused for the
# --since-date default, the output filename, and the header so a run spanning
# local midnight can't put one date in the filename and another in the header.
# The report day's zone is the `report_day` setting (local | utc, Configure's "Reports and shifts"):
# a new value applies from the next report on, a report already made keeps the window it was made with.
report_day="local"
report_cfg="${HIMMEL_LUNA_CONFIG_PATH:-${HOME:-}/.himmel/config.json}"
if [ -f "$report_cfg" ] && command -v jq >/dev/null 2>&1; then
    # swallow-ok: an unreadable config leaves the default, local
    _rd=$(jq -r '.reports.report_day // "local"' "$report_cfg" 2>/dev/null) || _rd="local"
    case "$_rd" in utc) report_day="utc" ;; esac
fi
if [ -n "${MORNING_TODAY:-}" ]; then
    today="$MORNING_TODAY"   # test seam: the report day
elif [ "$report_day" = "utc" ]; then
    today=$(TZ=UTC date +%F)
else
    today=$(date +%F)
fi
if [ "$report_day" = "utc" ]; then zone_label="UTC"; else zone_label="local midnight on the station, $(date +%Z)"; fi
# swallow-ok: no next-day form (GNU or BSD date) leaves next_day empty, so the window line reads without its end
next_day=$(date -d "$today + 1 day" +%F 2>/dev/null || date -j -v+1d -f %F "$today" +%F 2>/dev/null || echo "")

# Resolve --since-date when not passed — LOCAL day.
[ -z "$SINCE_DATE" ] && SINCE_DATE="$today"

# Resolve --out when not passed.
if [ -z "$OUT_FILE" ]; then
    # _ensure: this script WRITES the report to OUT_FILE, so we need the Mode A
    # inline dir to exist. Stderr is NOT suppressed: a broken HANDOVER_DIR (Mode
    # B typo) must surface so the operator notices the silent fallback to
    # <repo>/handovers/ that would otherwise write to the wrong root.
    if root=$(handover_root_ensure); then
        OUT_FILE="$root/morning-report-$today.md"
    else
        echo "WARNING: handover_root_ensure failed — falling back to $repo_root/handovers/" >&2
        OUT_FILE="$repo_root/handovers/morning-report-$today.md"
    fi
fi

# The tracker is the current project's: jira only when project-mode says so (a
# JIRA_CMD override means jira). No tracker is a normal state, not an outage.
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/load-dotenv.sh"
no_tracker=0
no_tracker_msg="No Jira tracker configured."
JIRA_ARGV=()
if [ -z "$JIRA_CMD" ]; then
    load_dotenv JIRA_PROJECT_KEY || true
    if run_or_unknown project_mode_tracker && [ "$RESULT_OUT" = "jira" ]; then
        # Resolve jira CLI (best-effort; absence is non-fatal).
        if [ -f "$repo_root/scripts/jira/dist/index.js" ] && command -v node >/dev/null 2>&1; then
            JIRA_ARGV=(node "$repo_root/scripts/jira/dist/index.js")
            JIRA_CMD="${JIRA_ARGV[*]}"
        fi
    else
        no_tracker=1
        # rc 2 is a setting project-mode rejects (TRACKER invalid, jira without a key).
        [ "$RESULT_RC" = "2" ] && no_tracker_msg="The tracker setting is invalid (check TRACKER and JIRA_PROJECT_KEY)."
    fi
fi

# A JIRA_CMD override is a command line; the resolved CLI keeps its path as one word.
if [ ${#JIRA_ARGV[@]} -eq 0 ] && [ -n "$JIRA_CMD" ]; then
    read -r -a JIRA_ARGV <<<"$JIRA_CMD"
fi

briefing_forge=$(forge_detect 2>/dev/null || true)

# Docs drift — advisory; gated by HIMMEL_DOC_FRESHNESS morning worker. A project
# without the doc-freshness lib has no such section.
docs_drift=""
docs_drift_present=0
if [ -f "$SCRIPT_DIR/../lib/doc-freshness.sh" ]; then
    docs_drift_present=1
    # Source the clone's .env so the morning worker activates when himmel turned it on
    # there (mirrors inject-where-are-we.sh; the cadence/skill may not export it).
    if [ -f "$repo_root/.env" ]; then
        load_dotenv --root "$repo_root" HIMMEL_DOC_FRESHNESS || true
    fi
    # shellcheck source=../lib/doc-freshness.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/doc-freshness.sh"
    if [ "$since_all" -eq 0 ] && df_worker_active morning; then
        docs_drift="$(df_detect "${SINCE_SHA}..HEAD" "" "$repo_root" 2>/dev/null || true)"
    fi
fi

# Reachability flags — distinguish "tool returned nothing" from "tool call
# FAILED" so a jira/gh outage doesn't render as a confident all-clear (a 0 must
# read as "unknown", not "none"). jira_ok starts 0 when the CLI isn't even
# resolved; both flip to 0 on a real query failure below. A project with no
# tracker leaves jira_ok 0 too, but says "No Jira tracker configured" instead.
jira_ok=1
[ -z "$JIRA_CMD" ] && jira_ok=0
pr_map_ok=1

# Gather sections (all PARENT-scope; the template heredoc only prints these) ----

# Commits since SINCE_SHA.
commit_range="${SINCE_SHA}..HEAD"
[ "$since_all" -eq 1 ] && commit_range="HEAD"
if commits_raw=$($GIT_CMD -C "$repo_root" log --oneline "$commit_range" 2>/dev/null); then
    :
else
    commits_raw=""
fi
commit_count=$(printf '%s\n' "$commits_raw" | grep -c . || true)

# Extract HIMMEL-N / LUNA-N ticket keys from commit messages.
# bash 3.2-safe (macOS): no mapfile.
ticket_keys=()
while IFS= read -r _line; do ticket_keys+=("$_line"); done < <(printf '%s\n' "$commits_raw" \
    | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' \
    | sort -u)

# Merged PRs via gh (best-effort) — GitHub only (date-ranged `--search`).
pr_table=""
pr_count=0
pr_count_ok=0
if [ "$briefing_forge" = "github" ] && command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    if pr_json=$($GH_CMD pr list --state merged --search "merged:>=$SINCE_DATE" --limit 100 --json number,title,mergedAt 2>/dev/null); then
        pr_count_ok=1
        if command -v jq >/dev/null 2>&1; then
            pr_table=$(printf '%s' "$pr_json" | jq -r '
                .[] | "| #\(.number) | \(.title | capture("(?<key>[A-Z][A-Z0-9]+-[0-9]+)").key // "—") | \(.title | sub("^[a-z]+(\\([^)]+\\))?:[[:space:]]*"; "")) |"' 2>/dev/null || true)
            if run_or_unknown jq -e 'if type == "array" then length else error("not an array") end' <<< "$pr_json" 2>/dev/null; then pr_count="$RESULT_OUT"; else pr_count="unknown"; fi
        else
            pr_table=$(printf '%s' "$pr_json" \
                | grep -oE '"number":[0-9]+' \
                | awk -F':' '{printf "| #%s | — | (jq missing) |\n", $2}')
            pr_count=$(printf '%s\n' "$pr_table" | grep -c . || true)
        fi
    fi
fi

# Done tickets via jira (best-effort) — cross-referenced against commit keys.
done_block=""
if [ -n "$JIRA_CMD" ]; then
    if done_raw=$("${JIRA_ARGV[@]}" list --status Done --limit "$JIRA_LIMIT" 2>/dev/null); then
        if [ ${#ticket_keys[@]} -gt 0 ]; then
            done_block=$(printf '%s\n' "$done_raw" | awk -F'\t' -v keys="$(IFS='|'; echo "${ticket_keys[*]}")" '
                BEGIN { split(keys, k, "|"); for (i in k) want[k[i]]=1 }
                want[$1] { printf "- %s — %s — %s\n", $1, $2, $4 }
            ')
        fi
    else
        jira_ok=0
        echo "WARNING: briefing: jira 'Done' query failed — counts may be incomplete" >&2
    fi
fi

# All-state PR map (single call; github only) — reused by In-flight + Stale.
# Lines: STATE<TAB>headRefName<TAB>number. The 500 cap is a generous safety
# bound on total PRs scanned for branch correlation (a different axis from the
# jira-limit knob).
pr_map=""
if [ "$briefing_forge" = "github" ]; then
    if ! command -v "${GH_CMD%% *}" >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        pr_map_ok=0
    elif all_json=$($GH_CMD pr list --state all --limit 500 --json number,state,headRefName,title 2>/dev/null); then
        pr_map=$(printf '%s' "$all_json" | jq -r '.[] | "\(.state)\t\(.headRefName)\t\(.number)"' 2>/dev/null) ||
            { pr_map=""; pr_map_ok=0; }
    else
        pr_map_ok=0
        echo "WARNING: briefing: gh PR-state query failed — stale + PR correlation skipped" >&2
    fi
fi

# Worktree branches (porcelain → "branch refs/heads/<name>" lines).
wt_porcelain=$($GIT_CMD -C "$repo_root" worktree list --porcelain 2>/dev/null || true)
wt_branches=$(printf '%s\n' "$wt_porcelain" | awk '/^branch /{sub("refs/heads/","",$2); print $2}')

# In-Progress tickets.
inprogress_raw=""
if [ -n "$JIRA_CMD" ]; then
    if ! inprogress_raw=$("${JIRA_ARGV[@]}" list --status 'In Progress' --limit "$JIRA_LIMIT" 2>/dev/null); then
        jira_ok=0; inprogress_raw=""
        echo "WARNING: briefing: jira 'In Progress' query failed — counts may be incomplete" >&2
    fi
fi

# Stale worktrees: branches whose PR is MERGED. Exclude main + current checkout.
# "no PR yet" is active WIP, NOT stale.
cur_branch=$($GIT_CMD -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
stale_rows=""
while IFS= read -r br; do
    [ -z "$br" ] && continue
    [ "$br" = "main" ] && continue
    [ "$br" = "$cur_branch" ] && continue
    merged_pr=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$br" 'tolower($2)==tolower(b) && $1=="MERGED"{print $3; exit}')
    if [ -n "$merged_pr" ]; then
        stale_rows="$stale_rows| \`$br\` | PR #$merged_pr MERGED | prune |"$'\n'
    fi
done <<EOF_WT
$wt_branches
EOF_WT

# Backlog (To-Do) tickets.
backlog_raw=""
if [ -n "$JIRA_CMD" ]; then
    if ! backlog_raw=$("${JIRA_ARGV[@]}" list --status 'To Do' --limit "$JIRA_LIMIT" 2>/dev/null); then
        jira_ok=0; backlog_raw=""
        echo "WARNING: briefing: jira 'To Do' query failed — counts may be incomplete" >&2
    fi
fi
backlog_rows=$(printf '%s\n' "$backlog_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{print}')
backlog_total=$(printf '%s\n' "$backlog_rows" | grep -c . || true)

# Frame 16 inputs -------------------------------------------------------------
# Three lead lines read an input of their own. Each fails open: a source that is
# absent or errors leaves its *_ok flag 0 and the template prints the "not
# available" line, never a zero or a guess. The empty string for a MORNING_* seam
# means "no such input" (tests); unset means the real source.

# Shift spend: the shift_spend record (scripts/api-lane/shift-spend.mjs) over the last 24h.
spend_ok=0; spend_bank=""; spend_bank_reset=""; spend_api=""; spend_api_floor=""
if command -v jq >/dev/null 2>&1; then
    spend_argv=()
    if [ "${MORNING_SHIFT_SPEND_CMD+set}" = set ]; then
        if [ -n "$MORNING_SHIFT_SPEND_CMD" ]; then read -r -a spend_argv <<<"$MORNING_SHIFT_SPEND_CMD"; fi
    elif [ -f "$SCRIPT_DIR/../api-lane/shift-spend.mjs" ] && command -v node >/dev/null 2>&1; then
        spend_argv=(node "$SCRIPT_DIR/../api-lane/shift-spend.mjs")
    fi
    if [ ${#spend_argv[@]} -gt 0 ]; then
        spend_until=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        # swallow-ok: no 24h-ago form (GNU or BSD date) leaves spend_since empty, so spend_ok stays 0 and the line reads not available
        spend_since=$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        # swallow-ok: a failed reader leaves spend_ok 0, so the line reads not available
        if [ -n "$spend_since" ] && spend_json=$("${spend_argv[@]}" --since "$spend_since" --until "$spend_until" 2>/dev/null); then
            # swallow-ok: an unparseable record leaves the row empty, so spend_ok stays 0 and the line reads not available
            spend_row=$(printf '%s' "$spend_json" | jq -r '
                [ (.fields.claude_bank | select(.status == "ok") | ((.seven_day.delta * 10 | round) / 10)) // "",
                  (.fields.claude_bank | select(.status == "ok") | .seven_day.resets | select(. > 0)) // "",
                  (.fields.api_cost | select(.status == "ok") | .value) // "",
                  (.fields.api_cost | select(.status == "ok" and .partial == true) | "yes") // ""
                ] | map(tostring) | join("|")' 2>/dev/null) || spend_row=""
            IFS='|' read -r spend_bank spend_bank_reset spend_api spend_api_floor <<<"$spend_row"
            [ -n "$spend_api" ] && spend_api=$(awk -v v="$spend_api" 'BEGIN { printf "%.2f", v }')
            if [ -n "$spend_bank" ] || [ -n "$spend_api" ]; then spend_ok=1; fi
        fi
    fi
fi

# Waiting on you, workers: the newest marker bullet of each worker handover doc touched in the last 3 days.
# READY awaits a GO; BLOCKED or FINDING is a question. A root with no such doc is no input, not a clean zero.
waiting_dir=""
# swallow-ok: no resolvable root leaves waiting_dir empty, so workers_ok stays 0 and the lines read not available
if [ "${MORNING_WAITING_DIR+set}" = set ]; then waiting_dir="$MORNING_WAITING_DIR"; else waiting_dir=$(handover_root 2>/dev/null || echo ""); fi
workers_ok=0; go_count=0; go_oldest=""; q_count=0; q_oldest=""
if [ -n "$waiting_dir" ] && [ -d "$waiting_dir" ]; then
    while IFS=$'\t' read -r _marker _hhmm; do
        [ -n "$_marker" ] || continue
        workers_ok=1
        case "$_marker" in
            READY)            go_count=$((go_count+1)); if [ -z "$go_oldest" ] || [[ "$_hhmm" < "$go_oldest" ]]; then go_oldest="$_hhmm"; fi ;;
            BLOCKED|FINDING)  q_count=$((q_count+1));  if [ -z "$q_oldest" ] || [[ "$_hhmm" < "$q_oldest" ]]; then q_oldest="$_hhmm"; fi ;;
        esac
    done < <(find "$waiting_dir" -maxdepth 4 -type f -name '*.md' ! -name 'morning-report-*' -mtime -3 2>/dev/null | while IFS= read -r _doc; do # gnu-ok: BSD find has -maxdepth and -mtime
        # The bullet carries a time of day only; the doc's last-modified day dates it (the newest bullet is the last write).
        # swallow-ok: a doc whose mtime cannot be read is skipped, so workers_ok stays 0 unless another doc reads
        _epoch=$(stat -c %Y "$_doc" 2>/dev/null || stat -f %m "$_doc" 2>/dev/null) || continue # gnu-ok: BSD stat -f is the fallback
        # swallow-ok: a doc whose day cannot be formed is skipped, as above
        _day=$(date -d "@$_epoch" +%F 2>/dev/null || date -r "$_epoch" +%F 2>/dev/null) || continue # gnu-ok: BSD date -r is the fallback
        awk -v day="$_day" '/^- [0-9][0-9]:[0-9][0-9] (LIVE|FINDING|RESOLVED|READY|BLOCKED|HALTED|WRAPPED|PARKED-BANK|RESUMED)/ { m = $3; sub(/[^A-Z-].*/, "", m); t = $2 }
             END { if (m != "") printf "%s\t%s %s\n", m, day, t }' "$_doc" 2>/dev/null
    done)
fi

# Waiting on you, CI and review state of the open PRs (github only).
ci_ok=0; ci_approved=0; ci_changes=0; ci_failing=0; ci_seen=0; ci_oldest=""; ci_cap=100
if [ "$briefing_forge" = "github" ] && command -v "${GH_CMD%% *}" >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    # swallow-ok: a failed gh read leaves ci_ok 0, so the line reads not available
    if open_json=$($GH_CMD pr list --state open --limit "$ci_cap" --json number,reviewDecision,statusCheckRollup,createdAt 2>/dev/null) &&
        ci_row=$(printf '%s' "$open_json" | jq -r '
            def failing: any(.statusCheckRollup[]?; ((.conclusion // .state // "") | IN("FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE")));
            [ ([.[] | select(.reviewDecision == "APPROVED")] | length),
              ([.[] | select(.reviewDecision == "CHANGES_REQUESTED")] | length),
              ([.[] | select(failing)] | length),
              length,
              (if length > 0 then (map(.createdAt) | min | .[0:10]) else "" end) ] | @tsv' 2>/dev/null); then
        IFS=$'\t' read -r ci_approved ci_changes ci_failing ci_seen ci_oldest <<<"$ci_row"
        ci_ok=1
    fi
fi

# Release progress: done/total per unreleased version (the first three), from the tracker's fixVersion.
release_parts=""; rel_cap=1000
# swallow-ok: a failed versions read leaves release_parts empty, so the line reads not available
if [ -n "$JIRA_CMD" ] && [ "$jira_ok" -eq 1 ] && vers_raw=$("${JIRA_ARGV[@]}" versions 2>/dev/null); then
    rel_versions=$(printf '%s\n' "$vers_raw" | awk -F'\t' '$2 == "false" && $4 == "false" && $1 != "" && $1 !~ /["\\]/ && n < 3 { print $1; n++ }')
    while IFS= read -r _ver; do
        [ -n "$_ver" ] || continue
        _jql="fixVersion = \"$_ver\""
        [ -n "${JIRA_PROJECT_KEY:-}" ] && _jql="project = $JIRA_PROJECT_KEY AND $_jql"
        # swallow-ok: a failed read skips this version, and no version left reads not available
        _rows=$("${JIRA_ARGV[@]}" list --jql "$_jql" --limit "$rel_cap" 2>/dev/null) || continue
        _counts=$(printf '%s\n' "$_rows" | awk -F'\t' 'NF >= 3 && $1 != "KEY" { t++; if ($3 == "Done" || $3 == "Closed") d++ } END { print d + 0, t + 0 }')
        _done=${_counts% *}; _total=${_counts#* }
        [ "$_total" -gt 0 ] || continue
        [ "$_total" -ge "$rel_cap" ] && _total="$_total+"
        release_parts="${release_parts:+$release_parts · }$_ver **$_done**/$_total done"
    done <<EOF_VER
$rel_versions
EOF_VER
fi

# Shifts ---------------------------------------------------------
# The shift record (shifts.jsonl, the one writer is scripts/config-ui/shift.ts) is read here, never
# written. The helper runs first so a close pending since the last poll is written before the count.
# Each shift id is counted in exactly one report: the first one made after its row is written. A
# ledger beside the record (shifts.reported.tsv, id TAB report day) is that memory, so a re-run of a
# day keeps its shifts and a re-run of an older day takes none that were written since.
# The empty string for SHIFTS_FILE / MORNING_SHIFT_CMD means "no such input" (tests); unset means the real source.
shifts_ok=0; shifts_json="[]"; shifts_n=0; shifts_why=""; ledger_new=""; ledger=""
shifts_file=""
if [ "${SHIFTS_FILE+set}" = set ]; then
    shifts_file="$SHIFTS_FILE"
elif _sroot=$(handover_root 2>/dev/null) && [ -n "$_sroot" ]; then # swallow-ok: no root means no record; the report says "not available (no shift record is configured)"
    shifts_file="$_sroot/shifts.jsonl"
fi
if [ -z "$shifts_file" ]; then
    shifts_why="no shift record is configured"
elif ! command -v jq >/dev/null 2>&1; then
    shifts_why="jq is not installed"
else
    shift_helper=()
    if [ "${MORNING_SHIFT_CMD+set}" = set ]; then
        if [ -n "$MORNING_SHIFT_CMD" ]; then read -r -a shift_helper <<<"$MORNING_SHIFT_CMD"; fi
    elif [ -f "$SCRIPT_DIR/../config-ui/shift-cli.ts" ] && command -v bun >/dev/null 2>&1; then
        shift_helper=(bun "$SCRIPT_DIR/../config-ui/shift-cli.ts")
    fi
    if [ ${#shift_helper[@]} -gt 0 ] && [ "$DRY_RUN" -eq 0 ]; then
        # swallow-ok: a failed helper leaves the record as it is, and the report reads what was already written
        SHIFTS_FILE="$shifts_file" "${shift_helper[@]}" >/dev/null 2>&1 || echo "WARNING: briefing: the shift helper failed — the shift record may be missing the newest shift" >&2
    fi
    if [ ! -f "$shifts_file" ]; then
        shifts_why="no shifts.jsonl yet"
    else
        ledger="${shifts_file%.jsonl}.reported.tsv"
        [ "$ledger" = "$shifts_file" ] && ledger="$shifts_file.reported.tsv"
        # swallow-ok: an unreadable record leaves no ids, and the section reads not available
        all_ids=$(jq -r '.id // empty' "$shifts_file" 2>/dev/null | awk '!seen[$0]++') || all_ids=""
        ledger_latest=""
        ledger_new=""   # claimed here, written to the ledger only after the report is on disk
        [ -f "$ledger" ] && ledger_latest=$(cut -f2 "$ledger" | sort | tail -1)
        counted=""
        [ -f "$ledger" ] && counted=$(awk -F'\t' -v d="$today" '$2 == d { print $1 }' "$ledger")
        # A shift not yet in the ledger belongs to this report, unless a later day's report exists.
        if [ -z "$ledger_latest" ] || ! [[ "$today" < "$ledger_latest" ]]; then
            while IFS= read -r _id; do
                [ -n "$_id" ] || continue
                if [ -f "$ledger" ] && awk -F'\t' -v id="$_id" '$1 == id { f = 1 } END { exit !f }' "$ledger"; then continue; fi
                counted="${counted:+$counted$'\n'}$_id"
                ledger_new="${ledger_new}$_id"$'\t'"$today"$'\n'
            done <<<"$all_ids"
        fi
        ids_json=$(printf '%s\n' "$counted" | jq -R 'select(. != "")' | jq -sc '.')
        # swallow-ok: an unparseable record leaves no shifts, and the section reads not available
        if shifts_json=$(jq -sc --argjson ids "$ids_json" '[ .[] | select(.id as $i | $ids | index($i)) ] | unique_by(.id) | sort_by(.opened)' "$shifts_file" 2>/dev/null); then
            shifts_ok=1
            shifts_n=$(jq 'length' <<<"$shifts_json")
        else
            shifts_json="[]"; shifts_why="shifts.jsonl could not be read"
        fi
    fi
fi

# ISO-8601 with an offset to epoch seconds: shifts store their times so, gh stores UTC.
# shellcheck disable=SC2016 # a jq program: $t, $e and $o are jq variables, not shell ones
jq_ep='def ep: . as $t | ($t[0:19] + "Z" | fromdateiso8601) as $e | ($t[19:]) as $o
    | if ($o == "Z" or $o == "") then $e
      else ((($o[1:3] | sub("^0"; "") | if . == "" then 0 else tonumber end) * 3600) + (($o[4:6] | sub("^0"; "") | if . == "" then 0 else tonumber end) * 60)) as $s
        | if $o[0:1] == "+" then $e - $s else $e + $s end end;'

# Merged PRs for the per-shift column: its own query, from the day before the earliest counted shift opened,
# since a night shift can reach back before the report day.
shift_pr_json=""
if [ "$shifts_n" -gt 0 ] && [ "$briefing_forge" = "github" ] && command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    _min_open=$(jq -r 'map(.opened[0:10]) | min' <<<"$shifts_json")
    # swallow-ok: no previous-day form (GNU or BSD date) searches from the opened day itself, still one day wide of the zone
    _from_day=$(date -d "$_min_open - 1 day" +%F 2>/dev/null || date -j -v-1d -f %F "$_min_open" +%F 2>/dev/null || echo "$_min_open")
    # swallow-ok: a failed gh read leaves the PRs-merged cells at not available
    shift_pr_json=$($GH_CMD pr list --state merged --search "merged:>=$_from_day" --limit 500 --json number,title,mergedAt 2>/dev/null) || shift_pr_json=""
    printf '%s' "$shift_pr_json" | jq -e 'type == "array"' >/dev/null 2>&1 || shift_pr_json=""
fi

# The Chiefs table, one row per chief per counted shift, from the stored span function output.
chiefs_rows=""
if [ "$shifts_n" -gt 0 ]; then
    chiefs_rows=$(jq -r '.[] | .name as $sh | .id as $id | .chiefs[]? |
        "| \(.name) | \(.span.start[11:16]) to \(if .span.end then .span.end[11:16] else "open" end)\(if .span.approx then " (approx)" else "" end) | \(.prs | length) | \($sh) \($id) |"' <<<"$shifts_json")
fi

# The Waiting rows snapshotted at the cut that closed the last counted shift, labelled with that time.
waiting_snap=""; waiting_snap_at=""
if [ "$shifts_n" -gt 0 ]; then
    waiting_snap_at=$(jq -r '[ .[] | select(.waiting != null and .why != "idle") ] | last | .closed // empty' <<<"$shifts_json")
    if [ -n "$waiting_snap_at" ]; then
        waiting_snap=$(jq -r '[ .[] | select(.waiting != null and .why != "idle") ] | last | .waiting[]? |
            "  - \(.kind) \(.ticket // "") \(.title) (\(.chief))"' <<<"$shifts_json")
    fi
fi

# Spend per shift: the spend reader once per counted shift over its own [opened, closed); one cell per
# source, each with its source mark, none a sum of another. A shift whose reader fails reads not available.
na5="not available | not available | not available | not available | not available"
shift_rows=""
if [ "$shifts_n" -gt 0 ]; then
    _i=0
    while [ "$_i" -lt "$shifts_n" ]; do
        _row=$(jq -c ".[$_i]" <<<"$shifts_json"); _i=$((_i+1))
        _meta=$(jq -r --argjson prs "${shift_pr_json:-null}" "$jq_ep"'
            (.opened | ep) as $o | (.closed | ep) as $c
            | [ .id, .name, (.opened[5:10] + " " + .opened[11:16] + " to " + .closed[5:10] + " " + .closed[11:16]),
                (.chiefs | length | tostring),
                (if $prs == null then "not available" else ([ $prs[] | (.mergedAt | fromdateiso8601) | select(. >= $o and . < $c) ] | length | tostring) end),
                ($o | todate), ($c | todate) ] | join("|")' <<<"$_row")
        IFS='|' read -r _sid _sname _sspan _schiefs _sprs _ssince _suntil <<<"$_meta"
        _cells="$na5"
        if [ ${#spend_argv[@]} -gt 0 ]; then
            # swallow-ok: a failed reader leaves the cells at not available
            if _sj=$("${spend_argv[@]}" --since "$_ssince" --until "$_suntil" 2>/dev/null); then
                # swallow-ok: an unparseable record leaves the cells at not available
                _tsv=$(jq -r '
                    def mark: (.source // "unknown source") | split(":")[0];
                    [ (.fields.claude_bank | if .status == "ok" and (.five_hour.peak != null) then "\(.five_hour.peak)% (\(mark))" else "NA" end),
                      (.fields.codex_tokens | if .status == "ok" then "\(.value) tokens (\(mark))" else "NA" end),
                      (.fields.codex_bank | if .status == "ok" then "\(.value) points (\(mark))" else "NA" end),
                      (.fields.api_cost | if .status == "ok" then "$\(.value)~\(mark)" else "NA" end),
                      (.fields.openrouter | if .status == "ok" then "$\(.value)~\(mark)" else "NA" end)
                    ] | @tsv' <<<"$_sj" 2>/dev/null) || _tsv=""
                if [ -n "$_tsv" ]; then
                    _cells=""
                    while IFS= read -r _c; do
                        case "$_c" in
                            NA) _c="not available" ;;
                            '$'*'~'*) _c="$(awk -v v="${_c#\$}" 'BEGIN { sub(/~.*/, "", v); printf "$%.2f", v }') (${_c#*~})" ;;
                        esac
                        _cells="${_cells:+$_cells | }$_c"
                    done < <(tr '\t' '\n' <<<"$_tsv")
                fi
            fi
        fi
        shift_rows="$shift_rows| $_sname $_sid | $_sspan | $_sprs | $_schiefs | $_cells |"$'\n'
    done
fi

# Deterministic judgment strings -----------------------------------------------

inprog_count=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{c++} END{print c+0}')
stale_count=$(printf '%s\n' "$stale_rows" | grep -c . || true)
done_count=$(printf '%s\n' "$done_block" | grep -c . || true)

open_prs=$(printf '%s\n' "$pr_map" | awk -F'\t' '$1=="OPEN"{c++} END{print c+0}')

if [ "$briefing_forge" = "github" ] && [ "$pr_map_ok" -eq 1 ]; then
    open_prs_shown="**${open_prs}** open PRs"
    stale_shown="**${stale_count}** stale worktrees"
else
    open_prs_shown="open PRs unavailable"
    stale_shown="stale worktrees unavailable"
fi
if [ "$no_tracker" -eq 1 ]; then
    tldr_default="${open_prs_shown} · ${stale_shown} · **${commit_count}** commits"
else
    tldr_default="**${inprog_count}** in-flight · ${stale_shown} · **${done_count}** Done (cross-ref'd) · **${backlog_total}** backlog"
fi

order_default=$(
    n=1
    [ "$stale_count" -gt 0 ] && { printf '%d. Prune %s stale worktree(s)%s.\n' "$n" "$stale_count" "$(cmd_hint clean)"; n=$((n+1)); }
    [ "$open_prs" -gt 0 ] && { printf '%d. Review/merge %s open PR(s)%s.\n' "$n" "$open_prs" "$(cmd_hint pr-check)"; n=$((n+1)); }
    [ "$inprog_count" -gt 0 ] && { printf '%d. Advance %s In-Progress ticket(s).\n' "$n" "$inprog_count"; n=$((n+1)); }
    [ "$backlog_total" -gt 0 ] && printf '%d. Pull from the %s-item backlog.\n' "$n" "$backlog_total"
    :   # force final exit 0 — a trailing short-circuit && would propagate rc1 to
        # the assignment and abort under set -e (empty backlog / jira down).
)
if [ -z "$order_default" ]; then
    if [ "$no_tracker" -eq 1 ]; then order_default="_Nothing waiting on you._"; else order_default="_Nothing in flight — pick from the backlog._"; fi
fi

# --llm enrichment (opt-in, fail-open per block) -------------------------------

tldr_final="$tldr_default"
order_final="$order_default"
llm_status=""   # ok | failed | unresolved; empty when --llm did not run
backlog_block_final=""   # empty => template uses the deterministic backlog render

# extract_block RAW NAME → text between <<<NAME_BEGIN>>>/<<<NAME_END>>> (exclusive).
extract_block() {
    printf '%s\n' "$1" | sed -n "/<<<$2_BEGIN>>>/,/<<<$2_END>>>/p" | sed '1d;$d'
}

# under Codex a claude fork is a nested harness; keep the heuristic
# report. CODEX_THREAD_ID is set only inside a real codex runtime.
if [ "$LLM" -eq 1 ] && [ -n "${CODEX_THREAD_ID:-}" ]; then
    echo "NOTE: skipping --llm under Codex (no nested claude fork); using deterministic heuristics" >&2
    LLM=0
fi

if [ "$LLM" -eq 1 ]; then
    llm_prompt="You are enriching a daily engineering Morning Report. Below is the
deterministic report body. Produce ONLY three blocks, each wrapped EXACTLY in
its sentinel lines and nothing else outside them:

<<<TLDR_BEGIN>>>
3-5 bullet TL;DR of the most important state
<<<TLDR_END>>>
<<<ORDER_BEGIN>>>
a numbered suggested order of what to do next
<<<ORDER_END>>>
<<<BACKLOG_BEGIN>>>
the backlog tickets clustered into 3-6 named themes (markdown)
<<<BACKLOG_END>>>

--- REPORT BODY ---
In-flight: ${inprog_count}; stale: ${stale_count}; Done: ${done_count}; backlog: ${backlog_total}
Backlog tickets:
${backlog_rows}
In-Progress:
${inprogress_raw}"
    # a text-in/text-out summary needs no plugins beyond the floor.
    if ! llm_settings=$(bash "$(dirname "${BASH_SOURCE[0]}")/../lanes/profile-settings.sh" bare); then
        llm_status="unresolved"
        echo "WARNING: --llm plugin profile 'bare' did not resolve; using heuristic" >&2
    elif llm_out=$($CLAUDE_CMD --settings "$llm_settings" --model "$LLM_MODEL" "$llm_prompt" </dev/null 2>/dev/null); then
        llm_status="ok"
        t=$(extract_block "$llm_out" TLDR);    if [ -n "$t" ]; then tldr_final="$t"; else echo "WARNING: --llm TLDR block empty; using heuristic" >&2; fi
        o=$(extract_block "$llm_out" ORDER);   if [ -n "$o" ]; then order_final="$o"; else echo "WARNING: --llm ORDER block empty; using heuristic" >&2; fi
        b=$(extract_block "$llm_out" BACKLOG); if [ -n "$b" ]; then backlog_block_final="$b"; fi
    else
        llm_status="failed"
        echo "WARNING: --llm: '$CLAUDE_CMD' failed; using deterministic heuristics" >&2
    fi
fi

# Template ---------------------------------------------------------------------

briefing=$(
    cat <<EOF
# 🌅 Morning Report — $today

> Auto-generated by \`scripts/handover/generate-morning-briefing.sh\`.
> Source markers: $since_marker,
> \`--since-date $SINCE_DATE\`. Point-in-time snapshot — continuity is a session's job.
>
> The tiles, Completed and Chiefs cover $today 00:00 to ${next_day:-the next midnight} 00:00. Spend per shift covers each shift over its own [opened, closed).
> Day starts: $zone_label · change on Configure.

EOF
    # Reachability banner — when a tool call FAILED (not just returned nothing),
    # the counts below are unknown, not zero. Surface it so a 0 isn't read as "none".
    jira_down=0
    [ "$jira_ok" -eq 0 ] && [ "$no_tracker" -eq 0 ] && jira_down=1
    if [ "$jira_down" -eq 1 ] || [ "$pr_map_ok" -eq 0 ]; then
        printf '> ⚠️ '
        [ "$jira_down" -eq 1 ] && printf 'jira unavailable — In-flight / Backlog / Done counts are INCOMPLETE. '
        [ "$pr_map_ok" -eq 0 ] && printf 'gh PR state unavailable — Stale + PR correlation SKIPPED. '
        printf '\n\n'
    fi
    # The four answers a reader back from a shift needs first (v5 frame 16);
    # every older section follows unchanged. A field with no input says so.
    printf '## ✅ What shipped\n\n'
    if [ "$jira_ok" -eq 1 ]; then done_shown="**$done_count**"
    elif [ "$no_tracker" -eq 1 ]; then done_shown="not available (no Jira tracker)"
    else done_shown="not available (jira unavailable)"; fi
    if [ "$pr_count_ok" -eq 1 ] && [ "$pr_count" != "unknown" ]; then pr_shown="**$pr_count**"; else pr_shown="not available"; fi
    printf '%s PRs merged to main · **%s** commits · %s Done (cross-ref'"'"'d). Detail: Completed, below.\n\n' \
        "$pr_shown" "$commit_count" "$done_shown"
    printf '## ⏳ What waits on you\n\n'
    if [ "$briefing_forge" = "github" ] && [ "$pr_map_ok" -eq 1 ]; then
        printf -- '- **%s** open PR(s) to review/merge%s\n' "$open_prs" "$(cmd_hint pr-check)"
        printf -- '- **%s** stale worktree(s) to prune%s\n' "$stale_count" "$(cmd_hint clean)"
    elif [ "$briefing_forge" != "github" ]; then
        printf -- '- Open PRs: not available (no GitHub forge for this project)\n'
        printf -- '- Stale worktrees: not available (no GitHub forge for this project)\n'
    else
        printf -- '- Open PRs: not available (gh PR state unavailable)\n'
        printf -- '- Stale worktrees: not available (gh PR state unavailable)\n'
    fi
    if [ "$workers_ok" -eq 0 ] && [ "$ci_ok" -eq 0 ]; then
        printf -- '- Approvals, CI and review state, worker questions: not available (the generator reads no input for them)\n\n'
    else
        if [ "$workers_ok" -eq 1 ]; then
            printf -- '- **%s** worker(s) awaiting your GO%s\n' "$go_count" "${go_oldest:+ (oldest bullet ${go_oldest#* }, doc last written ${go_oldest% *})}"
            printf -- '- **%s** worker question(s)%s\n' "$q_count" "${q_oldest:+ (oldest bullet ${q_oldest#* }, doc last written ${q_oldest% *})}"
        else
            printf -- '- Worker questions and GOs: not available (no worker handover doc found)\n'
        fi
        if [ "$ci_ok" -eq 1 ]; then
            printf -- '- CI and review state: **%s** approved, **%s** changes requested, **%s** with failing checks%s%s\n' \
                "$ci_approved" "$ci_changes" "$ci_failing" "${ci_oldest:+ (oldest open PR since $ci_oldest)}" \
                "$([ "$ci_seen" -ge "$ci_cap" ] && printf ' (first %s open PRs only)' "$ci_cap")"
        else
            printf -- '- CI and review state: not available (gh open-PR state unavailable)\n'
        fi
        printf '\n'
    fi
    printf '## 💸 What it spent\n\n'
    if [ "$spend_ok" -eq 1 ]; then
        spend_parts=""
        if [ -n "$spend_bank" ]; then
            spend_parts="weekly bank **+$spend_bank** points${spend_bank_reset:+ (a reset inside the shift: an estimate)}"
        fi
        if [ -n "$spend_api" ]; then
            spend_parts="${spend_parts:+$spend_parts · }API lane **${spend_api_floor:+at least }\$$spend_api**"
        fi
        printf -- '- Claude usage of the shift (last 24h): %s\n' "$spend_parts"
    else
        printf -- '- Claude usage of the shift: not available (the generator reads no usage input)\n'
    fi
    case "$llm_status" in
        (ok)         printf -- '- This report: one bounded %s turn (--llm)\n\n' "$LLM_MODEL" ;;
        (failed)     printf -- '- This report: one %s turn (--llm) failed; heuristic used\n\n' "$LLM_MODEL" ;;
        (unresolved) printf -- '- This report: no Claude turn (--llm plugin profile did not resolve)\n\n' ;;
        (*)          printf -- '- This report: no Claude usage (default run)\n\n' ;;
    esac
    printf '## ▶️ What runs next\n\n'
    if [ "$jira_ok" -eq 1 ]; then
        printf -- '- **%s** In-Progress ticket(s) in flight. Detail: In-flight WIP, below\n' "$inprog_count"
    elif [ "$no_tracker" -eq 1 ]; then
        printf -- '- In-Progress tickets: not available (no Jira tracker)\n'
    else
        printf -- '- In-Progress tickets: not available (jira unavailable)\n'
    fi
    if [ -n "$release_parts" ]; then
        printf -- '- Release progress: %s\n' "$release_parts"
    else
        printf -- '- Release progress: not available (the generator reads no release input)\n'
    fi
    printf -- '- Next step: %s\n\n' "$(printf '%s\n' "$order_final" | awk 'NF{print; exit}')"
    printf '## 👥 Chiefs\n\n'
    if [ "$shifts_n" -gt 0 ]; then
        printf '| Chief | Span | PRs merged | Shift |\n|---|---|---|---|\n%s\n\n' "$chiefs_rows"
    elif [ "$shifts_ok" -eq 1 ]; then
        printf '_No shift was counted in this report._\n\n'
    else
        printf -- '- Shifts: not available (%s)\n\n' "$shifts_why"
    fi
    printf '## 💸 Spend per shift\n\n'
    if [ "$shifts_n" -gt 0 ]; then
        printf '| Shift | Span | PRs merged | Chiefs | Claude bank | Codex tokens | Codex bank | API $ | OpenRouter $ |\n|---|---|---|---|---|---|---|---|---|\n%s\n' "$shift_rows"
        printf 'Each cell names its source in brackets and no column is a sum of another. A source that gave no figure reads not available.\n'
        if [ -n "$waiting_snap_at" ]; then
            printf '\nWaiting at the %s cut (the Shift page rows, snapshotted then):\n%s\n' "$waiting_snap_at" "${waiting_snap:-  - nothing}"
        fi
        printf '\n'
    elif [ "$shifts_ok" -eq 1 ]; then
        printf '_No shift was counted in this report._\n\n'
    else
        printf -- '- Shifts: not available (%s)\n\n' "$shifts_why"
    fi
    printf '## TL;DR\n\n%s\n\n' "$tldr_final"
    printf '## ✅ Completed (%s PRs merged to main)\n\n' "$pr_count"
    if [ -n "$pr_table" ]; then
        printf '| PR | Ticket | Summary |\n|---|---|---|\n%s\n' "$pr_table"
    else
        printf '_No merged PRs found via gh since %s. Check gh auth + filter._\n' "$SINCE_DATE"
    fi
    printf '\n### Commits (%s since %s)\n\n' "$commit_count" "$SINCE_SHA"
    if [ -n "$commits_raw" ]; then
        # shellcheck disable=SC2016  # backticks here are markdown literal, not subshell
        printf '```\n%s\n```\n' "$commits_raw"
    else
        printf '_No commits found since %s._\n' "$SINCE_SHA"
    fi
    printf '\n### Tickets transitioned to Done (cross-referenced against commits)\n\n'
    if [ -n "$done_block" ]; then
        printf '%s\n' "$done_block"
    elif [ "$no_tracker" -eq 1 ]; then
        printf '_%s_\n' "$no_tracker_msg"
    elif [ ${#ticket_keys[@]} -eq 0 ]; then
        printf '_No ticket keys detected in commit messages._\n'
    else
        printf '_Ticket keys detected in commits: %s. jira CLI unavailable or no Done matches._\n' "$(IFS=,; echo "${ticket_keys[*]}")"
    fi

    # In-flight WIP -----------------------------------------------------------
    printf '\n## 🔴 In-flight WIP\n\n'
    # annotated_branches MUST be initialized OUTSIDE the if — the catch-all below
    # references it unconditionally; under set -u an unset var aborts this subshell.
    annotated_branches=""
    wip_keys=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{print $1}')
    if [ -n "$wip_keys" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            title=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' -v k="$key" '$1==k{print $4; exit}')
            key_lc=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
            br=$(printf '%s\n' "$wt_branches" | tr '[:upper:]' '[:lower:]' | grep -F "$key_lc" | head -1 || true)
            if [ -n "$br" ]; then
                pr=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$br" 'tolower($2)==b && $1=="OPEN"{print $3; exit}')
                annotated_branches="$annotated_branches$br"$'\n'
                if [ -n "$pr" ]; then
                    printf -- '- **%s** — %s — worktree %s, PR #%s\n' "$key" "$title" "$br" "$pr"
                else
                    printf -- '- **%s** — %s — worktree %s (no PR)\n' "$key" "$title" "$br"
                fi
            else
                printf -- '- **%s** — %s — (uncorrelated: no key-bearing branch)\n' "$key" "$title"
            fi
        done <<EOF_WIP
$wip_keys
EOF_WIP
    elif [ "$no_tracker" -eq 1 ]; then
        printf '_%s_\n' "$no_tracker_msg"
    else
        printf '_No In-Progress tickets._\n'
    fi
    # BSD awk (macOS) rejects a newline inside -v, so hand the
    # branch list over tab-separated (a branch name cannot contain a tab).
    catchall=$(printf '%s\n' "$pr_map" | awk -F'\t' -v seen="$(printf '%s' "$annotated_branches" | tr '\n' '\t')" '
        BEGIN{ n=split(seen,s,"\t"); for(i in s) skip[tolower(s[i])]=1 }
        $1=="OPEN" && !( tolower($2) in skip ){ printf "- PR #%s — %s\n", $3, $2 }')
    if [ -n "$catchall" ]; then
        printf '\n_Other open PRs / worktrees (no In-Progress ticket):_\n%s\n' "$catchall"
    fi

    # Stale worktrees ---------------------------------------------------------
    printf '\n## 🧹 Stale worktrees\n\n'
    if [ -n "$stale_rows" ]; then
        printf '| Worktree branch | State | Action |\n|---|---|---|\n%s' "$stale_rows"
    elif [ "$briefing_forge" != "github" ]; then
        printf '_PR state unavailable on non-github forge — stale detection skipped._\n'
    elif [ "$pr_map_ok" -eq 0 ]; then
        printf '_gh PR-state query failed — stale detection unavailable (NOT a clean garden)._\n'
    else
        printf '_No stale worktrees (no merged-PR branches checked out)._\n'
    fi

    # Backlog -----------------------------------------------------------------
    printf '\n## 📋 Backlog (%s To Do)\n\n' "$backlog_total"
    if [ -n "$backlog_block_final" ]; then
        printf '%s\n' "$backlog_block_final"
    elif [ "$backlog_total" -gt 0 ]; then
        # head may close the pipe early → SIGPIPE/141 → pipefail; guard with || true.
        { printf '%s\n' "$backlog_rows" | head -n "$BACKLOG_LIMIT" \
            | awk -F'\t' '{printf "- %s — %s\n", $1, $4}'; } || true
        if [ "$backlog_total" -gt "$BACKLOG_LIMIT" ]; then
            printf '_…and %s more (raise --backlog-limit to see all)._\n' "$((backlog_total - BACKLOG_LIMIT))"
        fi
    elif [ "$no_tracker" -eq 1 ]; then
        printf '_%s_\n' "$no_tracker_msg"
    else
        printf '_No To-Do tickets (or jira unavailable)._\n'
    fi

    # Docs drift -------------------------------------------------
    if [ "$docs_drift_present" -eq 1 ]; then
        printf '\n## 📄 Docs drift\n\n'
        if ! df_worker_active morning; then
            # shellcheck disable=SC2016  # backticks here are markdown literal, not subshell
            printf '_Doc-freshness off (set HIMMEL_DOC_FRESHNESS to include `morning`)._\n'
        elif [ "$since_all" -eq 1 ]; then
            printf '_Docs drift is not computed for a history shorter than 50 commits._\n'
        elif [ -n "$docs_drift" ]; then
            printf '%s\n' "$docs_drift" | awk -F'\t' 'NF>=2{printf "- %s → update %s\n", $1, $2}'
        else
            printf '_No mapped-source-vs-doc drift since %s._\n' "$SINCE_SHA"
        fi
    fi

    # Failure review --------------------------------------------
    # The digest the daily failure-review cadence wrote today; its headings drop
    # one level so it nests under this section. Only where the cadence ships: the
    # shared state dir may hold another project's digest.
    failure_review="${HIMMEL_FAILURE_REVIEW_DIR:-$HOME/.himmel/state/failure-review}/failure-review-$today.md"
    if [ -f "$SCRIPT_DIR/../eval/worker-digest/failure-review-cadence.sh" ]; then
        printf '\n## 🧯 Failure review\n\n'
        if [ -f "$failure_review" ]; then
            sed -e '/^## Failure review$/d' -e 's/^### /#### /' "$failure_review" | sed '/./,$!d'
        else
            printf '_No failure review digest for %s (scripts/eval/worker-digest/failure-review-cadence.sh)._\n' "$today"
        fi
    fi

    # Prompt cache ------------------------------------------------------------
    # One zero-token line from the cache-health metrics (scripts/eval/cache-health.py).
    # Only where the reader ships.
    if [ -f "$SCRIPT_DIR/cache-health-line.py" ]; then
        printf '\n## 🗄️ Prompt cache\n\n'
        if ! python3 -I "$SCRIPT_DIR/cache-health-line.py" \
            ${CACHE_HEALTH_STATE_DIR:+--state-dir "$CACHE_HEALTH_STATE_DIR"} 2>/dev/null; then
            printf 'cache: unmonitored (reader failed)\n'
        fi
    fi

    # Suggested order ---------------------------------------------------------
    printf '\n## Suggested order\n\n%s\n' "$order_final"
)

# Write / print ----------------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY briefing: would write to $OUT_FILE"
    echo "DRY briefing: body:"
    printf '%s\n' "$briefing"
    exit 0
fi

mkdir -p "$(dirname "$OUT_FILE")"
printf '%s\n' "$briefing" > "$OUT_FILE"
# The shifts this report counted are claimed only now that it is on disk, so a failed write leaves them for the next day.
[ -n "$ledger_new" ] && printf '%s' "$ledger_new" >>"$ledger"
echo "briefing: wrote $OUT_FILE ($pr_count PRs, $commit_count commits, ${#ticket_keys[@]} ticket keys)"
exit 0
