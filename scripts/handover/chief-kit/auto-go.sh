#!/usr/bin/env bash
# scripts/handover/chief-kit/auto-go.sh - slice A1a of the scripted GO: the GO checks a chief repeats
# by hand at every READY, run as a DRY RUN. It answers "would a script give this PR its GO?" and
# writes one auto-go.jsonl row per answer. It never writes a GO file, never calls go.sh and never
# sends a message: the real GO act is slice A1b, and the chief keeps deciding by hand until ten
# dry-run rows match the chief's own actions.
#
# Usage: auto-go.sh --doc <chief doc> --fleet <manifest> --worker <label> [--graph <file>]
#                   --dry-run <pr-number> <full-40-hex-head-sha>
#   --worker  the N<k> label of the worker that sent the READY (a leg of the fleet manifest)
#   --graph   the chief's current chain graph (chain-graph.py --json); it feeds check 7 only
#   --dry-run required in this slice; without it the script exits 2 (the GO act is slice A1b)
#
# The checks run in this order and the FIRST failure is the refusal:
#   1. a lane the chief does not merge for: the worker is a native leg of the manifest (a claudex,
#      unknown-lane or unlisted worker escalates) and this repo is not a registered adapter or
#      adopted repo (scripts/guardrails/himmel-{adapters,adopted}.json; both files must be readable)
#   2. live head: the PR is OPEN, headRefOid == <head>, and its base is the default branch
#   3. ready-go.sh <pr> <head> prints READY-GO PASS (ready-check: head, CI, threads, CR-ledger ok row,
#      trailers, ticket ids, coverage)
#   4. no hold: no key in the PR title carries held, operator-gated, operator-decision, operator or
#      operator-present (read live from Jira); the chief doc's `## Live state` has no `merge-hold:`
#      line naming the PR, a title key or `all`; the worker's brief has no `> **Merge:** chief`
#   5. the judge requirement is slice A1b. Here a trust-path hit (ready-go's `TRUST: hit`) escalates
#      at 5, so a dry run never predicts a GO the chief would not give; anything else records
#      `not-built`
#   6. cr-disposition.sh check is clean
#   7. the chain plan: with --graph that lists the PR, chain-plan-core.sh --go-check <pr> must print
#      GO-CHECK OK; no --graph records `no-graph` and a graph without the PR records `not-in-plan`,
#      both passing; an unreadable graph or a refused go-check escalates
#   8. not a fix-for-red and not a release cut: no commit carries a `Fixes-main-red:` line and the PR
#      does not change the root VERSION file
# A read that fails (gh, Jira, a file) is a refusal at its check, never a pass.
#
# Output, one line on stdout:
#   WOULD-GO <pr> <head>                  exit 0
#   ESCALATE auto-go <check#> <reason>    exit 10
# Exit: 0 would-go; 1 a shared library cannot be loaded (git-clean.sh, go-gate.sh, handover-path.sh)
# or the git environment cannot be scrubbed, the audit trail cannot be resolved at the
# start, or the WOULD-GO row cannot be written (no answer is given); 2 usage;
# 3 a chief-spawned worker (HIMMEL_CONSOLE_LEG) or a relay (HIMMEL_CONSOLE_RELAY) - checked first,
# before anything is read; 10 escalate. An ESCALATE whose audit row cannot be written is still
# answered (a refusal is safe): exit 10, with a warning on stderr.
#
# Audit trail: <handover root>/<user>/<bucket>/auto-go.jsonl, append-only, one row per run:
#   {ts, pr, head, worker, checks:[{n, result[, reason]}], qid:null, delta:null, go_file:null,
#    bus:null, outcome:"would-go"|"escalate"}
# result is pass | fail | not-built (check 5) | no-graph | not-in-plan | pass (check 7 with a graph).
#
# This file reads no flag (check-flags.sh enforces it: it is on ci-trust-paths.txt).
# Seams (tests): AUTO_GO_ANCHOR replaces the harness anchor the libraries and allowlists are read
# from; GH_CMD and JIRA_CMD replace the CLIs, as in ready-go.sh.
#
# ponytail: the adapter allowlists are read from the anchor's checkout, not the default branch, so
# an edit there moves check 1 either way (a removed row passes where the default branch's would
# escalate); a dry run writes no GO, so the cost is one wrong audit row; upgrade path is
# go_adapter_entry's API read once A1b writes a GO.
# ponytail: a series child based on its parent's branch escalates at check 2; HIMMEL-8349 D1 (local
# stack, published at merge) means no PR is stacked, so no wait-parent answer exists.
#
# Platform guard: POSIX bash 3.2+, jq, gh, GNU date.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" 2>/dev/null || { echo "auto-go: cannot load scripts/lib/git-clean.sh - refusing (the git environment must be scrubbed first)" >&2; exit 1; }
declare -F git_env_scrub >/dev/null 2>&1 || { echo "auto-go: scripts/lib/git-clean.sh defines no git_env_scrub - refusing" >&2; exit 1; }
git_env_scrub || { echo "auto-go: cannot scrub the git environment - refusing" >&2; exit 1; }
ANCHOR="${AUTO_GO_ANCHOR:-$(cd "$HERE/../../.." && pwd)}"
GH_BIN="${GH_CMD:-gh}"

# a function inherited from the environment must not stand in for the shared go-gate helpers
unset -f chief_worker go_resolve_root go_verdict_scope 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F chief_worker >/dev/null 2>&1 \
        || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_verdict_scope >/dev/null 2>&1; then
    echo "auto-go: cannot load scripts/lib/go-gate.sh - refusing (the chief-worker check must fail closed)" >&2
    exit 1
fi
# only the chief's own process tree may run this: the same two refusals go.sh gives, before any read
if chief_worker; then
    echo "auto-go: refusing - this is a chief-spawned worker (HIMMEL_CONSOLE_LEG is set); only the chief decides a GO." >&2
    exit 3
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *) echo "auto-go: refusing - this is a chief relay (HIMMEL_CONSOLE_RELAY is set); only the chief decides a GO." >&2; exit 3 ;;
esac

usage() { echo "usage: auto-go.sh --doc <chief doc> --fleet <manifest> --worker <label> [--graph <file>] --dry-run <pr-number> <full-40-hex-head-sha>" >&2; exit 2; }

DOC=""; FLEET=""; WORKER=""; GRAPH=""; GRAPH_SET=0; DRY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        --fleet) [ "$#" -ge 2 ] || usage; FLEET="$2"; shift 2 ;;
        --worker) [ "$#" -ge 2 ] || usage; WORKER="$2"; shift 2 ;;
        --graph) [ "$#" -ge 2 ] || usage; GRAPH="$2"; GRAPH_SET=1; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        -*) usage ;;
        *) break ;;
    esac
done
[ "$#" -eq 2 ] || usage
PR="$1"; SHA="$2"
case "$PR" in ''|0*|*[!0123456789]*) usage ;; esac
case "$SHA" in *[!0123456789abcdef]*) usage ;; esac
[ "${#SHA}" -eq 40 ] || usage
[ -n "$DOC" ] && [ -n "$FLEET" ] && [ -n "$WORKER" ] || usage
case "$WORKER" in *[!A-Za-z0-9._-]*) usage ;; esac
if [ "$DRY" -ne 1 ]; then
    echo "auto-go: only --dry-run exists in this slice - the GO act is slice A1b" >&2
    exit 2
fi

# the audit trail first: with nowhere to record the answer, none is given
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/handover-path.sh"; then
    echo "auto-go: cannot load scripts/lib/handover-path.sh" >&2
    exit 1
fi
if ! ROOT=$(go_resolve_root "$ANCHOR") || ! SCOPE=$(go_verdict_scope "$ANCHOR"); then
    echo "auto-go: cannot resolve the handover root or the <user>/<bucket> scope for the audit trail - no answer given" >&2
    exit 1
fi
AUDIT="$ROOT/$SCOPE/auto-go.jsonl"

CHECKS='[]'
add_check() { # <n> <result> [<reason>]
    CHECKS=$(jq -c --argjson n "$1" --arg r "$2" --arg why "${3:-}" \
        '. + [{n: $n, result: $r} + (if $why == "" then {} else {reason: $why} end)]' <<< "$CHECKS") || return 1
}
write_audit() { # <would-go|escalate>
    local row
    row=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pr "$PR" --arg head "$SHA" --arg worker "$WORKER" \
        --argjson checks "$CHECKS" --arg outcome "$1" \
        '{ts: $ts, pr: $pr, head: $head, worker: $worker, checks: $checks, qid: null, delta: null, go_file: null, bus: null, outcome: $outcome}') || return 1
    mkdir -p "$(dirname "$AUDIT")" || return 1
    printf '%s\n' "$row" >> "$AUDIT"
}
# fail <check#> <reason>: record the failed check, answer ESCALATE; a row that cannot be written
# still escalates (a refusal is safe), with a warning
fail() {
    local why
    why=$(printf '%s' "$2" | tr '\r\n\t' '   ' | cut -c1-300)
    add_check "$1" fail "$why"
    write_audit escalate || echo "auto-go: warning - the audit row could not be written to $AUDIT" >&2
    printf 'ESCALATE auto-go %s %s\n' "$1" "$why"
    exit 10
}

jira_get() { # <key>: the CLI's `get` output, as ready-go.sh reads it
    local common
    if [ -n "${JIRA_CMD:-}" ]; then
        "$JIRA_CMD" get "$1" 2>/dev/null
    else
        # dist/ is an untracked build in the primary checkout, absent from a worktree
        common=$(git -C "$ANCHOR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1  # swallow-ok: no repo means no Jira CLI, and the caller escalates check 4
        JIRA_PROJECT_KEY="${JIRA_PROJECT_KEY:-HIMMEL}" node "$(dirname "$common")/scripts/jira/dist/index.js" get "$1" 2>/dev/null
    fi
}

# --- 1. a lane the chief does not merge for ------------------------------------------------------
LEG=$(jq -r --arg w "$WORKER" '[.legs[]? | select(.label == $w)] | if length == 1 then "\(.[0].lane // "unknown")\t\(.[0].doc)" else "missing" end' "$FLEET" 2>/dev/null) || fail 1 "cannot read the fleet manifest $FLEET"  # swallow-ok: an unreadable manifest escalates at check 1
[ -n "$LEG" ] || fail 1 "cannot read the fleet manifest $FLEET"
[ "$LEG" != missing ] || fail 1 "worker $WORKER is not exactly once in the fleet manifest"
LANE="${LEG%%$'\t'*}"; WORKER_DOC="${LEG#*$'\t'}"
[ "$LANE" = native ] || fail 1 "worker $WORKER is lane $LANE, not native: the chief merges for it"
NWO=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || NWO=""  # swallow-ok: an empty name escalates at check 1 on the next line
[ -n "$NWO" ] || fail 1 "cannot read this repo's name (gh repo view failed)"
for list in himmel-adapters.json himmel-adopted.json; do
    [ -e "$ANCHOR/scripts/guardrails/$list" ] || fail 1 "scripts/guardrails/$list is missing: whether $NWO is an adapter or adopted repo cannot be shown"
    listed=$(jq -r --arg n "$NWO" 'if type == "array" then ([.[] | select(type == "object" and ((.nwo // "") | ascii_downcase) == ($n | ascii_downcase))] | length | tostring) else "bad" end' \
        "$ANCHOR/scripts/guardrails/$list" 2>/dev/null) || listed=bad
    case "$listed" in
        0) ;;
        bad|'') fail 1 "cannot read scripts/guardrails/$list: whether $NWO is an adapter or adopted repo is unknown" ;;
        *) fail 1 "$NWO is listed in scripts/guardrails/$list: an adapter or adopted repo merges through the chief" ;;
    esac
done
add_check 1 pass

# --- 2. live head ------------------------------------------------------------------------------------
DEFAULT_BRANCH=$("$GH_BIN" repo view --json defaultBranchRef --jq '.defaultBranchRef.name // ""' 2>/dev/null) || DEFAULT_BRANCH=""  # swallow-ok: an empty value escalates at check 2 below
VIEW=$("$GH_BIN" pr view "$PR" --json state,headRefOid,baseRefName 2>/dev/null) || VIEW=""  # swallow-ok: an empty value escalates at check 2 below
FIELDS=$(jq -r '[.state, .headRefOid, .baseRefName] | @tsv' <<< "$VIEW" 2>/dev/null) || FIELDS=""  # swallow-ok: an empty value escalates at check 2 below
IFS=$'\t' read -r PR_STATE PR_HEAD PR_BASE <<< "$FIELDS"
if [ -z "$DEFAULT_BRANCH" ] || [ -z "${PR_STATE:-}" ] || [ -z "${PR_HEAD:-}" ] || [ -z "${PR_BASE:-}" ]; then
    fail 2 "cannot read the PR or the default branch (gh)"
fi
[ "$PR_STATE" = OPEN ] || fail 2 "PR $PR is $PR_STATE, not OPEN"
[ "$PR_HEAD" = "$SHA" ] || fail 2 "PR $PR's head is now $PR_HEAD, not $SHA"
[ "$PR_BASE" = "$DEFAULT_BRANCH" ] || fail 2 "PR $PR is based on $PR_BASE, not the default branch $DEFAULT_BRANCH"
add_check 2 pass

# --- 3. ready-go.sh: the output the chief reads by hand ------------------------------------------------
RG_RC=0
RG=$(bash "$HERE/ready-go.sh" "$PR" "$SHA" 2>&1) || RG_RC=$?
if [ "$RG_RC" -ne 0 ] || ! printf '%s\n' "$RG" | grep -qx 'READY-GO PASS'; then
    RG_WHY=$(printf '%s\n' "$RG" | grep -m1 -E '^\[FAIL\]|^TRUST: refused') || RG_WHY=""
    [ -n "$RG_WHY" ] || RG_WHY=$(printf '%s\n' "$RG" | tail -n 1)
    fail 3 "ready-go.sh exit $RG_RC: $RG_WHY"
fi
add_check 3 pass

# --- 4. no hold -----------------------------------------------------------------------------------------
TITLE=$("$GH_BIN" pr view "$PR" --json title --jq .title 2>/dev/null) || TITLE=""  # swallow-ok: a title with no key escalates at check 4 on the next lines
KEYS=$(printf '%s' "$TITLE" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | sort -u)
[ -n "$KEYS" ] || fail 4 "PR $PR's title carries no ticket key, so its labels cannot be read"
for key in $KEYS; do
    JOUT=$(jira_get "$key") || fail 4 "cannot read $key from Jira"
    printf '%s\n' "$JOUT" | head -n 1 | grep -q "^$key"$'\t' || fail 4 "Jira's answer for $key is not a ticket line"
    LABELS=$(printf '%s\n' "$JOUT" | sed -n 's/^Labels: //p' | head -n 1 | tr ',' ' ')
    for label in $LABELS; do
        case "$label" in
            held|operator-gated|operator-decision|operator|operator-present) fail 4 "$key carries the label $label" ;;
        esac
    done
done
[ -r "$DOC" ] || fail 4 "cannot read the chief doc $DOC"
HOLDS=$(awk '$0 == "## Live state" { s = 1; next } s && /^## / { s = 0 }
             s && /^[[:space:]]*([-*+][[:space:]]+)?merge-hold:/ { sub(/^[^:]*:[[:space:]]*/, ""); print }' "$DOC") \
    || fail 4 "cannot read the chief doc $DOC"
for tok in $(printf '%s\n' "$HOLDS" | tr -d '`' | tr ',;' '  '); do
    tok="${tok#\#}"
    [ "$tok" = all ] && fail 4 "the chief doc's Live state holds all merges (merge-hold: all)"
    [ "$tok" = "$PR" ] && fail 4 "the chief doc's Live state holds PR $PR (merge-hold:)"
    for key in $KEYS; do
        [ "$tok" = "$key" ] && fail 4 "the chief doc's Live state holds $key (merge-hold:)"
    done
done
[ -r "$WORKER_DOC" ] || fail 4 "cannot read the worker's brief $WORKER_DOC"
BRIEF_RC=0
grep -qE '^> \*\*Merge:\*\* chief([^A-Za-z0-9_-]|$)' "$WORKER_DOC" || BRIEF_RC=$?
case "$BRIEF_RC" in
    0) fail 4 "the worker's brief says Merge: chief (the chief GOes this dispatch by hand)" ;;
    1) ;;
    *) fail 4 "cannot read the worker's brief $WORKER_DOC (grep exit $BRIEF_RC)" ;;
esac
add_check 4 pass

# --- 5. the judge requirement is slice A1b; a trust-path hit is not a predicted GO ---------------------------
TRUST_LINE=$(printf '%s\n' "$RG" | grep -m1 '^TRUST: ') || TRUST_LINE=""
case "$TRUST_LINE" in
    "TRUST: hit "*) fail 5 "trust-path hit (${TRUST_LINE#TRUST: hit }): a trust path needs a judge verdict, and that check is slice A1b" ;;
    "TRUST: none"*|"TRUST: not-adopted"*) ;;
    *) fail 5 "ready-go.sh printed no usable TRUST line" ;;
esac
add_check 5 not-built

# --- 6. residual dispositions ---------------------------------------------------------------------------------
DISP_TRUST=no
printf '%s\n' "$RG" | grep -qx 'TRUST-PATH: yes' && DISP_TRUST=yes
if ! DISP=$(bash "$HERE/cr-disposition.sh" check "$PR" "$SHA" --trust-path "$DISP_TRUST" 2>&1); then
    fail 6 "cr-disposition.sh check refused: $(printf '%s\n' "$DISP" | head -n 1)"
fi
add_check 6 pass

# --- 7. the chain plan ------------------------------------------------------------------------------------------
if [ "$GRAPH_SET" -eq 0 ]; then
    add_check 7 no-graph
else
    LISTED=$(jq -r --arg id "#$PR" 'if (.nodes | type) == "array" then ([.nodes[] | select(.id == $id)] | length | tostring) else error("no nodes array") end' "$GRAPH" 2>/dev/null) || fail 7 "cannot read the chain graph $GRAPH"  # swallow-ok: an unreadable graph escalates at check 7
    case "$LISTED" in ''|*[!0123456789]*) fail 7 "cannot read the chain graph $GRAPH" ;; esac
    if [ "$LISTED" -eq 0 ]; then
        add_check 7 not-in-plan
    else
        GC_OUT=$(bash "$HERE/chain-plan-core.sh" --go-check "$PR" --graph "$GRAPH" 2>&1) || fail 7 "chain-plan-core.sh --go-check refused: $GC_OUT"
        grep -q '^GO-CHECK OK ' <<< "$GC_OUT" || fail 7 "chain-plan-core.sh --go-check exited 0 but printed no GO-CHECK OK line"
        add_check 7 pass
    fi
fi

# --- 8. not a fix-for-red, not a release cut ------------------------------------------------------------------------
FILES=$("$GH_BIN" api "repos/$NWO/pulls/$PR/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) || fail 8 "cannot list PR $PR's changed files"  # swallow-ok: an unreadable listing escalates at check 8
[ -n "$FILES" ] || fail 8 "PR $PR's changed-file listing is empty"
if printf '%s\n' "$FILES" | tr '\t' '\n' | grep -qx 'VERSION'; then
    fail 8 "PR $PR changes the root VERSION file: a release cut is chief-only"
fi
MSGS=$("$GH_BIN" api "repos/$NWO/pulls/$PR/commits" --paginate --jq '.[] | .commit.message' 2>/dev/null) || fail 8 "cannot read PR $PR's commits"  # swallow-ok: an unreadable commit list escalates at check 8
[ -n "$MSGS" ] || fail 8 "PR $PR's commit list is empty"
if printf '%s\n' "$MSGS" | tr -d '\r' | grep -q '^Fixes-main-red:'; then
    fail 8 "a commit of PR $PR declares Fixes-main-red: a fix-for-red takes the chief's FIX-GO"
fi
add_check 8 pass

write_audit would-go || { echo "auto-go: cannot write the audit row to $AUDIT - no answer given" >&2; exit 1; }
printf 'WOULD-GO %s %s\n' "$PR" "$SHA"
