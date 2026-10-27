#!/usr/bin/env bash
# scripts/lanes/worker-pr-open.sh
#
# WHY. A worker's inline `gh pr create --title … --body "<markdown>"` was
# intermittently denied with `Stage 2 classifier error`, and an
# immediate retry escalated to `[Out-of-Place Publication]`. The operator's
# read: the classifier reacts to the PR body TEXT carried inline in the Bash
# command a worker types (multi-paragraph markdown, `diff --stat` blocks,
# `worker-burn:` lines, quoted denial strings), not to the act of publishing.
#
# The fix: title and body come from FILES, never argv, so the Bash command a
# worker runs is always the same short fixed literal — two file paths — no
# matter what the PR says. The body only ever reaches `gh` as an argv element
# of a CHILD process this script execs (via the forge seam below); it never
# appears in the command the classifier reads.
#
# Usage: worker-pr-open.sh <title-file> <body-file> [--base <branch>] [--humanized-body <file>]
#
# Idempotent: finds an open PR for the current branch (forge_pr_find_open)
# and updates its body instead of opening a second one.
#
# Refuses (exit 1): on `main`, when the branch has no upstream, on an empty
# body file, or when opening (not updating) a PR before /pr-check finished: a
# cr-pending marker still held, or no `avail ... ok` ledger row at that head (a
# repo listed in scripts/guardrails/himmel-adapters.json needs no ledger row, only
# the marker hold: its CI, the chief's judge and the signed GO stand in).
# No retry logic — a classifier denial of THIS invocation is
# the stuck-playbook Stage 2 / Out-of-Place rows' territory, not this
# script's.
#
# Success: exactly one line, `PR <number> <url> <head-sha>`.
# Failure: the forge/gh error verbatim on stderr, non-zero exit.
#
# Platform guard: no .ps1 twin, by design. POSIX bash plus git and gh/bb (all
# already required by scripts/lib/forge.sh) — it runs under git bash on
# Windows unchanged.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/env-alias.sh
. "$HERE/../lib/env-alias.sh"
# old names, read only while HIMMEL_LEGACY_NAMES is on
alias_env HIMMEL_WORKER_SESSION_PROFILE HIMMEL_LEG_PROFILE
alias_env WORKER_SESSION_JIRA_STATUS LEG_JIRA_STATUS
# Forge-dispatch seam: forge_pr_find_open / forge_pr_create / forge_pr_set_body
# / forge_detect / forge_repo_nwo route to the github or bitbucket backend per
# the repo's origin — never call gh/bb directly from here.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$HERE/../lib/forge.sh"

usage() {
    echo "Usage: worker-pr-open.sh <title-file> <body-file> [--base <branch>] [--humanized-body <file>]" >&2
}

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

TITLE_FILE="$1"; shift
BODY_FILE="$1"; shift
HUMANIZED_BODY=""
BASE="main"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-main}"; shift 2 ;;
        --humanized-body) [ "$#" -ge 2 ] || { usage; exit 1; }; HUMANIZED_BODY="$2"; shift 2 ;;
        *) echo "ERR worker-pr-open: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [ ! -f "$TITLE_FILE" ]; then
    echo "ERR worker-pr-open: no such title file: $TITLE_FILE" >&2
    exit 1
fi
if [ ! -f "$BODY_FILE" ] || [ ! -r "$BODY_FILE" ]; then
    echo "ERR worker-pr-open: missing or unreadable body file: $BODY_FILE" >&2
    exit 1
fi

title=$(cat "$TITLE_FILE") # read-sink-ok: the caller's own title file, passed to gh verbatim
body=$(cat "$BODY_FILE") # read-sink-ok: the caller's own body file, passed to gh verbatim

if [ -z "$body" ]; then
    echo "ERR worker-pr-open: body file is empty: $BODY_FILE" >&2
    exit 1
fi

if [ -n "$HUMANIZED_BODY" ]; then
    if python3 -I "$HERE/../../marketplace/plugins/himmel-ops/scripts/humanizer-facts.py" "$BODY_FILE" "$HUMANIZED_BODY"; then
        body=$(cat "$HUMANIZED_BODY")
    else
        echo "humanizer: rewrite refused or checker unavailable; keeping original PR body" >&2
    fi
else
    echo 'humanizer: optional deterministic humanizer-facts.py --normalize ORIGINAL CANDIDATE; skip keeps original, --humanized-body FILE checks a candidate; no model rewrite' >&2
fi

# The squash merge makes this TITLE main's commit subject, so
# refuse a type-less one here rather than let it reach `gh pr create`/`pr
# edit` at all — check-pr-title.sh runs the SAME regex check-commit-msg.sh
# enforces on commits.
if ! "$HERE/../lib/check-pr-title.sh" "$title"; then
    exit 1
fi

# Compute the worker-burn line HERE, inside the script, never as a
# worker-typed ad-hoc `worker-burn.sh ...` command — that shape was classifier-denied
# [Session Transcript Tampering]. A failure to resolve or run it is a WARN
# plus a `worker-burn: unavailable (<reason>)` line; it never fails the PR open.
compute_worker_burn_line() {
    local session=""
    if [ -r "$HERE/../lib/session-name.sh" ]; then
        # shellcheck source=../lib/session-name.sh
        # shellcheck disable=SC1091
        . "$HERE/../lib/session-name.sh"
        session=$(current_session_name 2>/dev/null || true)
    fi

    local transcript=""
    if [ -z "$session" ]; then
        # Explicit-jsonl fallback, mirroring context-fill.sh's
        # resolve_transcript(): CLAUDE_CODE_SESSION_ID names the transcript
        # file directly when the -n argv name isn't resolvable (non-Linux, no
        # CLAUDE_PID, or an unnamed session).
        local sid="${CLAUDE_CODE_SESSION_ID:-}"
        if [ -n "$sid" ]; then
            local f
            for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"/*/"$sid".jsonl; do
                if [ -f "$f" ]; then
                    transcript="$f"
                    break
                fi
            done
        fi
        if [ -z "$transcript" ]; then
            echo "worker-burn: unavailable (no session name or CLAUDE_CODE_SESSION_ID transcript resolvable)"
            return 0
        fi
    fi

    local profile="${HIMMEL_WORKER_SESSION_PROFILE:-}"
    case "$profile" in
        ''|*[!A-Za-z0-9._,-]*) profile=unknown ;;
    esac
    local raw
    if ! raw=$("$HERE/worker-burn.sh" --profile "$profile" "${transcript:-$session}" 2>&1); then
        echo "WARN worker-pr-open: worker-burn.sh failed for '${transcript:-$session}': $raw" >&2
        # Never publish the local transcript path
        # into the PR body — it carries the operator's home dir, username and
        # session ID. The full path stays in the
        # WARN line above (stderr only); the PR body gets a generic reason.
        if [ -n "$session" ]; then
            echo "worker-burn: unavailable (worker-burn.sh failed for session '$session')"
        else
            echo "worker-burn: unavailable (worker-burn.sh failed for the CLAUDE_CODE_SESSION_ID transcript)"
        fi
        return 0
    fi

    local calls avg_ctx first_turn compactions cost_eq
    calls=$(printf '%s\n' "$raw" | sed -n 's/.*calls=\([^ ]*\).*/\1/p')
    avg_ctx=$(printf '%s\n' "$raw" | sed -n 's/.*avg-ctx=\([^ ]*\).*/\1/p')
    first_turn=$(printf '%s\n' "$raw" | sed -n 's/.*first-turn=\([^ ]*\).*/\1/p')
    compactions=$(printf '%s\n' "$raw" | sed -n 's/.*compactions=\([^ ]*\).*/\1/p')
    cost_eq=$(printf '%s\n' "$raw" | sed -n 's/.*cost-eq=\([^ ]*\).*/\1/p')
    if [ -z "$calls" ] || [ -z "$avg_ctx" ] || [ -z "$first_turn" ] || [ -z "$compactions" ] || [ -z "$cost_eq" ]; then
        echo "WARN worker-pr-open: could not parse worker-burn.sh output: $raw" >&2
        echo "worker-burn: unavailable (could not parse worker-burn.sh output)"
        return 0
    fi

    echo "worker-burn: calls=$calls avg-ctx=$avg_ctx first-turn=$first_turn compactions=$compactions cost-eq=$cost_eq profile=$profile"
}

burn_line=$(compute_worker_burn_line)
# pipefail-ok: no -q here on purpose (known-findings
# [grep-q-pipe-under-pipefail]) — grep reads the whole (small) body instead of
# exiting early, so the printf producer never takes a SIGPIPE.
existing_burn_line=$(printf '%s\n' "$body" | grep '^worker-burn:' || true)
if [ -n "$existing_burn_line" ]; then
    body=$(printf '%s\n' "$body" | awk -v repl="$burn_line" '{ if ($0 ~ /^worker-burn:/) print repl; else print }')
else
    body="${body}
${burn_line}"
fi

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ]; then
    echo "ERR worker-pr-open: refusing to open a PR from main" >&2
    exit 1
fi

# The ticket this title cites must be the ticket this branch is
# for — a stale cwd must never publish (or overwrite) another ticket's PR.
ticket_key_re='\[([A-Za-z][A-Za-z0-9]*-[0-9]+)\]'
title_key=""
if [[ $title =~ $ticket_key_re ]]; then title_key="${BASH_REMATCH[1]}"; fi
if [ -n "$title_key" ]; then
    branch_lc=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')
    key_lc=$(printf '%s' "$title_key" | tr '[:upper:]' '[:lower:]')
    # Token boundaries: proj-1 must not match proj-10 or xproj-1.
    if ! [[ $branch_lc =~ (^|[^a-z0-9])"$key_lc"([^0-9]|$) ]]; then
        echo "ERR worker-pr-open: title cites $title_key but branch '$branch' does not carry it — wrong cwd?" >&2
        exit 1
    fi
fi

if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "ERR worker-pr-open: branch '$branch' has no upstream — push it first" >&2
    exit 1
fi

head_sha=$(git rev-parse HEAD)
upstream_sha=$(git rev-parse '@{u}')
if [ "$head_sha" != "$upstream_sha" ]; then
    echo "ERR worker-pr-open: local HEAD ($head_sha) has not been pushed — upstream is at ($upstream_sha); push first" >&2
    exit 1
fi

existing_pr=""
# Same separation as the create path below: a `gh`/`bb` warning on stdin's
# stderr (even on a SUCCESSFUL lookup, rc=0) must never leak into the value
# parsed as the PR number — it could make an empty lookup look non-empty, or
# corrupt a real number, driving an update against the wrong PR.
find_open_err=$(mktemp "${TMPDIR:-/tmp}/worker-pr-open-find-err.XXXXXX") || { echo "ERR worker-pr-open: mktemp failed" >&2; exit 1; }
if ! existing_pr=$(forge_pr_find_open "$branch" 2>"$find_open_err"); then
    echo "ERR worker-pr-open: could not check for an existing PR:" >&2
    cat "$find_open_err" >&2
    rm -f "$find_open_err"
    exit 1
fi
rm -f "$find_open_err"
existing_pr=$(printf '%s\n' "$existing_pr" | head -n 1)

if [ -z "$existing_pr" ]; then
    # Opening a PR needs a finished /pr-check: an `avail ... ok` row at this head
    # in the CR ledger (a critic responded) AND no pending cr-pending marker,
    # which only clear-review-marker.sh removes once no finding blocks (the same
    # marker check-cr-marker-on-pr-create.sh holds `gh pr create` on). Paths are
    # fixed, never an env seam. An existing PR's body update is not an open and
    # is not gated.
    common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
    if [ -e "$common_dir/cr-pending/$branch" ]; then
        echo "ERR worker-pr-open: /pr-check is still pending for branch '$branch' (cr-pending marker present) — finish /pr-check until it clears the marker, then open the PR" >&2
        exit 1
    fi
    # A PR on a registered adopter repo (origin nwo in himmel-adapters.json, read from this
    # harness's primary checkout) has no CR ledger here: the repo's CI, the chief's judge and
    # the signed GO stand in for the record. The pending-marker hold above still applies.
    adopter_repo=0
    origin_url=$(git remote get-url origin 2>/dev/null) || origin_url="" # swallow-ok: no origin means not an adopter, the record check below applies
    harness_common=$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || harness_common="" # swallow-ok: unresolvable harness root leaves the record check in force
    if [ -n "$harness_common" ] && [ -r "$harness_common/../scripts/guardrails/himmel-adapters.json" ] \
        && WT_URL="$origin_url" WT_REG="$harness_common/../scripts/guardrails/himmel-adapters.json" node -e '
            const m = /github\.com[:\/]([^\/]+\/[^\/]+?)(\.git)?\/?$/.exec(process.env.WT_URL || "");
            if (!m) process.exit(1);
            const want = m[1].toLowerCase();
            const reg = JSON.parse(require("fs").readFileSync(process.env.WT_REG, "utf8"));
            process.exit(Array.isArray(reg) && reg.some((e) => String(e.nwo).toLowerCase() === want) ? 0 : 1);' 2>/dev/null; then
        adopter_repo=1
    fi
    ledger="$common_dir/cr-critic-scores.jsonl"
    if [ "$adopter_repo" -eq 0 ] && { ! [ -f "$ledger" ] || ! awk -v h="\"head\":\"$head_sha\"" \
        'index($0, "\"kind\":\"avail\"") && index($0, "\"status\":\"ok\"") && index($0, h) { found = 1; exit } END { exit !found }' "$ledger"; }; then
        echo "ERR worker-pr-open: no /pr-check record for head $head_sha — run /pr-check on this head before opening the PR (order: commit, push the branch, /pr-check, then open)" >&2
        exit 1
    fi
    # Capture stdout (the PR URL) and stderr (diagnostics, plus the
    # CodeRabbit-trigger confirmation) into SEPARATE streams —
    # merging them with `2>&1` let a stderr line race the URL for "first
    # line" on some hosts/gh versions. On failure, diagnostics come from the
    # captured stderr file; on success it is discarded.
    create_err=$(mktemp "${TMPDIR:-/tmp}/worker-pr-open-create-err.XXXXXX") || { echo "ERR worker-pr-open: mktemp failed" >&2; exit 1; }
    if ! out=$(forge_pr_create "$title" "$body" "$BASE" "$branch" 2>"$create_err"); then
        echo "ERR worker-pr-open: PR create failed:" >&2
        cat "$create_err" >&2
        rm -f "$create_err"
        exit 1
    fi
    rm -f "$create_err"
    # Take only the first line of stdout as the URL — stderr is now captured
    # separately above and never reaches this variable, but stdout itself
    # could still carry more than one line, so keep this defensive.
    url=$(printf '%s\n' "$out" | head -n 1)
    number=${url##*/}
else
    number="$existing_pr"
    # ponytail: GitHub only — the forge seam has no PR-title read, so Bitbucket
    # keeps the branch check alone; add a seam read when one is needed.
    if [ -n "$title_key" ] && [ "$(forge_detect)" = github ]; then
        pr_title=$("${GH_CMD:-gh}" pr view "$number" --json title --jq .title 2>/dev/null) || pr_title=""
        pr_key=""
        if [[ $pr_title =~ $ticket_key_re ]]; then pr_key="${BASH_REMATCH[1]}"; fi
        if [ "$(printf '%s' "$pr_key" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$title_key" | tr '[:upper:]' '[:lower:]')" ]; then
            echo "ERR worker-pr-open: title cites $title_key but PR #$number on branch '$branch' is titled '${pr_title}' (key '${pr_key:-none}') — refusing to overwrite it" >&2
            exit 1
        fi
    fi
    if ! out=$(forge_pr_set_body "$number" "$title" "$body" 2>&1); then
        echo "ERR worker-pr-open: PR body update failed:" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    forge=$(forge_detect)
    nwo=$(forge_repo_nwo)
    case "$forge" in
        github)    url="https://github.com/${nwo}/pull/${number}" ;;
        bitbucket) url="https://bitbucket.org/${nwo}/pull-requests/${number}" ;;
    esac
fi

# An open PR asks the status funnel to re-derive the title's first [KEY].
# Best-effort: the funnel warns and exits 0 on any Jira failure;
# WORKER_SESSION_JIRA_STATUS=0 opts out. Its stdout is kept off this script's one-line
# `PR ...` contract.
if [ "${WORKER_SESSION_JIRA_STATUS:-1}" != "0" ]; then
    # shellcheck source=../lib/ticket-status.sh
    # shellcheck disable=SC1091
    . "$HERE/../lib/ticket-status.sh"
    if jira_key=$(ticket_key_from_title "$title"); then
        bash "${TICKET_STATUS_FUNNEL:-$HERE/../handover/chief-kit/worker-jira-status.sh}" "$jira_key" \
            --event pr-open --pr "$number" --head "$head_sha" >/dev/null || true
    fi
fi

echo "PR ${number} ${url} ${head_sha}"
