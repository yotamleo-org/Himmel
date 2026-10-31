#!/usr/bin/env bash
# scripts/handover/chief-kit/auto-go.sh - the scripted GO: the GO checks a chief repeats by hand at
# every READY and, when every one passes, the GO itself (slice A1b; slice A1a was the dry run). It
# writes one auto-go.jsonl row per answer.
#
# Usage: auto-go.sh --doc <chief doc> --fleet <manifest> --worker <label> [--graph <file>]
#                   [--dry-run] <pr-number> <full-40-hex-head-sha>
#   --worker  the N<k> label of the worker that sent the READY (a leg of the fleet manifest)
#   --graph   the chief's current chain graph (chain-graph.py --json); it feeds check 7 only
#   --dry-run answer "would a script give this PR its GO?" and act on nothing: no GO file, no
#             verdict record, no message. Without it, a pass of every check ACTS (see below).
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
#   5. the judge requirement. A judge is required for a trust-path hit (ready-go's `TRUST: hit`), for
#      a brief that asks for one (the gen-briefs judge line, "the chief runs an opus judge before
#      GO") and for a docs PR (every changed file under docs/ or a *.md file; decision 286).
#      Then one verdict qid under verdicts/ must rule `**GO** for head <head>` for this PR
#      (go-gate.sh's go_trust_verdict: signed, this PR, no NO-GO at the head), or a GO at an
#      earlier head of this PR must carry: delta-class.sh <judged> <head> prints `none` (which means
#      no trust path and no prior finding line was touched, not that the change is trivial), and no
#      qid may hold a NO-GO for this PR at that judged head or at a head after it. Every
#      qid that names this PR or head is read; a NO-GO at the head, or a verdict that is unsigned,
#      unparsed or names another PR, refuses. Anything else needs no verdict (an ordinary GO)
#   6. cr-disposition.sh check is clean
#   7. the chain plan: with --graph that lists the PR, chain-plan-core.sh --go-check <pr> must print
#      GO-CHECK OK; no --graph records `no-graph` and a graph without the PR records `not-in-plan`,
#      both passing; an unreadable graph or a refused go-check escalates
#   8. not a fix-for-red and not a release cut: no commit carries a `Fixes-main-red:` line and the PR
#      does not change the root VERSION file
# A read that fails (gh, Jira, a file) is a refusal at its check, never a pass.
#
# The GO act (no --dry-run, every check passed), in this order:
#   a. a GO that carries from an earlier head: write-verdict.sh --delta-noop <judged> records the
#      new head under the carried qid
#   b. go.sh [--trust-reviewed <qid>] <pr> <head> --model auto-go --effort script. go.sh re-runs
#      ready-check and every gate of its own; its signed record names model auto-go and effort
#      script, so a scripted GO is told apart from a chief's. Any refusal is `ESCALATE auto-go 9`
#   c. the bus GO to the worker's live session, exactly as verdict-go.sh words it
#      (`GO <pr> <head> - merge with: bash <merge-on-green.sh> [--jira-transition] --go <GO file>`,
#      the flag only for a brief that says `Completes ticket: yes`), then `Your token `<nonce>``
#      read from the chief doc's `## Live state`. The bus proves the sender is the chief
#
# Output, one line on stdout (the bus-failed form is two):
#   WOULD-GO <pr> <head>                              exit 0  (--dry-run, every check passed)
#   GO-SENT <pr> <head> to <label> bus=<#n>           exit 0  (the GO file is written and sent)
#   GO-WRITTEN <pr> <head> bus-failed: <why>          exit 11 (the GO file stands; the bus send
#   SENDMESSAGE to=<session> :: <message>                      failed or had no live session or
#                                                              token: the chief sends the message)
#   ESCALATE auto-go <check#> <reason>                exit 10 (check 9 = the GO act refused)
# Exit: 0 would-go or sent; 1 a shared library cannot be loaded (git-clean.sh, go-gate.sh,
# handover-path.sh, the seam guard) or the git environment cannot be scrubbed, the audit trail
# cannot be resolved at the start or is not a regular file, or the WOULD-GO row cannot be written
# (no answer is given, nothing is acted on); 2 usage; 3 a chief-spawned worker
# (HIMMEL_CONSOLE_LEG) or a relay (HIMMEL_CONSOLE_RELAY) - checked first, before anything is read;
# 10 escalate; 11 GO written, bus not delivered; 96 a chokepoint seam differs from the session's
# launch environment. An ESCALATE whose audit row cannot be written is still answered (a refusal
# is safe): exit 10, with a warning on stderr.
#
# Audit trail: <handover root>/<user>/<bucket>/auto-go.jsonl, append-only, one row per run:
#   {ts, pr, head, worker, checks:[{n, result[, reason]}], qid, delta, go_file, bus,
#    outcome:"would-go"|"escalate"|"go"}
# qid is the judge qid the GO rests on (null for an ordinary GO), delta "none" when a GO at an
# earlier head carried, go_file the GO file written, bus the bus record ("#7"; null when the send
# failed). result is pass | fail | no-graph | not-in-plan (check 7 without a graph or the PR in it).
# The target must be absent or a regular file: a symlink or a directory refuses at the start.
#
# This file reads no flag (check-flags.sh enforces it: it is on ci-trust-paths.txt).
# Seams (tests): AUTO_GO_ANCHOR replaces the harness anchor the libraries and allowlists are read
# from; GH_CMD and JIRA_CMD replace the CLIs, as in ready-go.sh; AUTO_GO_BUS replaces the himmel-bus
# CLI and AUTO_GO_CENSUS the process census (a script printing claude_sessions rows). All are
# registered chokepoint seams (scripts/chokepoints.json): a relative-entry copy hands off to the
# anchor's own copy and the seam guard refuses a seam that differs from the session's launch env.
#
# ponytail: the adapter allowlists are read from the anchor's checkout, not the default branch, so
# an edit there moves check 1 either way (a removed row passes where the default branch's would
# escalate); upgrade path is go_adapter_entry's API read.
# ponytail: a series child based on its parent's branch escalates at check 2; HIMMEL-8349 D1 (local
# stack, published at merge) means no PR is stacked, so no wait-parent answer exists.
# ponytail: the audit target is checked just before the append, not held open, so a symlink planted
# in that gap is still followed once; upgrade path is an O_NOFOLLOW append (a node or python writer).
# ponytail: the chief doc's `AUTO-GO` / `AUTO-GO-REFUSED` bullet and the digest line of design 2.5
# are not written here; they belong to the worker-event caller (slice A2).
#
# Platform guard: POSIX bash 3.2+, jq, gh, GNU date.
set -u

# a relative-entry copy that is not the anchor's hands off to it, then a chokepoint seam that differs
# from the session's launch env is refused; both run before any seam is read. Parameter expansion, not
# dirname: a PATH-shadowed dirname must not pick what is sourced before the guard.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "auto-go: cannot load $_csg_lib - refusing" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/chief-kit/auto-go.sh || exit 96

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" 2>/dev/null || { echo "auto-go: cannot load scripts/lib/git-clean.sh - refusing (the git environment must be scrubbed first)" >&2; exit 1; }
declare -F git_env_scrub >/dev/null 2>&1 || { echo "auto-go: scripts/lib/git-clean.sh defines no git_env_scrub - refusing" >&2; exit 1; }
git_env_scrub || { echo "auto-go: cannot scrub the git environment - refusing" >&2; exit 1; }
# the fleet manifest worker array is `workers`; a manifest not yet rewritten holds the pre-rename
# `legs`, read only while legacy names are on (off: that manifest is unreadable, check 1 escalates)
# shellcheck source=../../lib/legacy-names.sh
. "$HERE/../../lib/legacy-names.sh" 2>/dev/null || { echo "auto-go: cannot load scripts/lib/legacy-names.sh - refusing" >&2; exit 1; }
if legacy_names_on; then JQ_W='def W: (.workers // .legs);'; else JQ_W='def W: .workers;'; fi
ANCHOR="${AUTO_GO_ANCHOR:-$(cd "$HERE/../../.." && pwd)}"
GH_BIN="${GH_CMD:-gh}"

# a function inherited from the environment must not stand in for the shared go-gate helpers
unset -f chief_worker go_resolve_root go_verdict_scope go_trust_verdict 2>/dev/null || true
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F chief_worker >/dev/null 2>&1 \
        || ! declare -F go_resolve_root >/dev/null 2>&1 || ! declare -F go_verdict_scope >/dev/null 2>&1 \
        || ! declare -F go_trust_verdict >/dev/null 2>&1; then
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
# the target is absent or a regular file: `>>` follows a symlink planted there (to a file the caller can
# write, or a dangling one it would create) and fails on a directory
audit_target_ok() {
    if [ -L "$AUDIT" ]; then return 1; fi
    if [ -e "$AUDIT" ] && [ ! -f "$AUDIT" ]; then return 1; fi
    return 0
}
if ! audit_target_ok; then
    echo "auto-go: the audit trail $AUDIT is a symlink or not a regular file - no answer given, nothing acted on" >&2
    exit 1
fi

CHECKS='[]'
A_QID=""; A_DELTA=""; A_GOFILE=""; A_BUS=""
add_check() { # <n> <result> [<reason>]
    CHECKS=$(jq -c --argjson n "$1" --arg r "$2" --arg why "${3:-}" \
        '. + [{n: $n, result: $r} + (if $why == "" then {} else {reason: $why} end)]' <<< "$CHECKS") || return 1
}
write_audit() { # <would-go|escalate|go>
    local row
    row=$(jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson pr "$PR" --arg head "$SHA" --arg worker "$WORKER" \
        --argjson checks "$CHECKS" --arg outcome "$1" --arg qid "$A_QID" --arg delta "$A_DELTA" --arg gofile "$A_GOFILE" --arg bus "$A_BUS" \
        'def nn: if . == "" then null else . end;
         {ts: $ts, pr: $pr, head: $head, worker: $worker, checks: $checks, qid: ($qid | nn), delta: ($delta | nn), go_file: ($gofile | nn), bus: ($bus | nn), outcome: $outcome}') || return 1
    audit_target_ok || return 1
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
LEG=$(jq -r --arg w "$WORKER" "$JQ_W"'[W[]? | select(.label == $w)] | if length == 1 then "\(.[0].lane // "unknown")\t\(.[0].doc)" else "missing" end' "$FLEET" 2>/dev/null) || fail 1 "cannot read the fleet manifest $FLEET"  # swallow-ok: an unreadable manifest escalates at check 1
[ -n "$LEG" ] || fail 1 "cannot read the fleet manifest $FLEET"
[ "$LEG" != missing ] || fail 1 "worker $WORKER is not exactly once in the fleet manifest"
LANE="${LEG%%$'\t'*}"; WORKER_DOC="${LEG#*$'\t'}"
[ "$LANE" = native ] || fail 1 "worker $WORKER is lane $LANE, not native: the chief merges for it"
NWO=$("$GH_BIN" repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) || NWO=""  # swallow-ok: an empty name escalates at check 1 on the next line
[ -n "$NWO" ] || fail 1 "cannot read this repo's name (gh repo view failed)"
for list in himmel-adapters.json himmel-adopted.json; do
    [ -f "$ANCHOR/scripts/guardrails/$list" ] || fail 1 "scripts/guardrails/$list is missing: whether $NWO is an adapter or adopted repo cannot be shown"
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
[ -f "$DOC" ] || fail 4 "the chief doc $DOC is not a regular file"
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
[ -f "$WORKER_DOC" ] || fail 4 "the worker's brief $WORKER_DOC is not a regular file"
[ -r "$WORKER_DOC" ] || fail 4 "cannot read the worker's brief $WORKER_DOC"
BRIEF_RC=0
grep -qE '^> \*\*Merge:\*\* chief([^A-Za-z0-9_-]|$)' "$WORKER_DOC" || BRIEF_RC=$?
case "$BRIEF_RC" in
    0) fail 4 "the worker's brief says Merge: chief (the chief GOes this dispatch by hand)" ;;
    1) ;;
    *) fail 4 "cannot read the worker's brief $WORKER_DOC (grep exit $BRIEF_RC)" ;;
esac
add_check 4 pass

# --- 5. the judge requirement ---------------------------------------------------------------------------------
# NEED names why a judge is required; empty is an ordinary GO
NEED=""; GO_QID=""; CARRY_FROM=""
TRUST_LINE=$(printf '%s\n' "$RG" | grep -m1 '^TRUST: ') || TRUST_LINE=""
case "$TRUST_LINE" in
    "TRUST: hit "*) NEED="trust-path hit (${TRUST_LINE#TRUST: hit })" ;;
    "TRUST: none"*|"TRUST: not-adopted"*) ;;
    *) fail 5 "ready-go.sh printed no usable TRUST line" ;;
esac
# the changed files (also check 8's): a read that fails is held until a verdict is needed on it
FILES_ERR=0
FILES=$("$GH_BIN" api "repos/$NWO/pulls/$PR/files" --paginate --jq '.[] | .filename, (.previous_filename // empty)' 2>/dev/null) || FILES_ERR=1  # swallow-ok: an unreadable listing escalates at check 5 (docs PR) or 8 below
[ -n "$FILES" ] || FILES_ERR=1
# the brief asks for a judge (gen-briefs' judge line), though the diff hits no trust path
JUDGE_RC=0
grep -qF 'the chief runs an opus judge before GO' "$WORKER_DOC" || JUDGE_RC=$?
case "$JUDGE_RC" in
    0) [ -n "$NEED" ] || NEED="the brief asks for a judge (judge: true)" ;;
    1) ;;
    *) fail 5 "cannot read the worker's brief $WORKER_DOC (grep exit $JUDGE_RC)" ;;
esac
# a docs PR (decision 286): every changed file is under docs/ or is a *.md file
if [ -z "$NEED" ]; then
    [ "$FILES_ERR" -eq 0 ] || fail 5 "cannot list PR $PR's changed files, so whether it is a docs PR (needing the docs judge) is unknown"
    NONDOCS_RC=0
    printf '%s\n' "$FILES" | tr '\t' '\n' | awk 'NF' | grep -qvE '^(docs/|.*\.md$)' || NONDOCS_RC=$?
    case "$NONDOCS_RC" in
        0) ;;
        1) NEED="docs PR (decision 286)" ;;
        *) fail 5 "cannot classify PR $PR's changed files (grep exit $NONDOCS_RC)" ;;
    esac
fi
if [ -z "$NEED" ]; then
    add_check 5 pass "no judge required"
else
    VERDICTS="$ROOT/$SCOPE/verdicts"
    LAST_DC=""
    # every qid whose verdict names this PR or this head
    QIDS=""
    if [ -d "$VERDICTS" ]; then
        CAND=$(grep -rlE --include='*.md' -e "^pr: ${PR}\$|for head \`${SHA}\`" "$VERDICTS" 2>/dev/null); CAND_RC=$?  # swallow-ok: rc 1 is no verdict; rc 2 escalates on the next line
        [ "$CAND_RC" -le 1 ] || fail 5 "cannot read the verdict directory $VERDICTS"
        while IFS= read -r vpath; do
            [ -n "$vpath" ] || continue
            rel="${vpath#"$VERDICTS"/}"
            case "$rel" in */*/*) continue ;; esac
            q="${rel%%/*}"
            case "$q" in go-pr-*) continue ;; esac  # a persisted chief GO, never a judge's verdict
            QIDS="$QIDS$q"$'\n'
        done <<< "$CAND"
        QIDS=$(printf '%s' "$QIDS" | sort -u)
    fi
    # a GO at the head: any qid failing for another reason than "no GO at this head" (a NO-GO, an
    # unsigned or unparsed record, another PR) refuses outright
    # no GO carries while ANY qid holds a NO-GO for this PR at the judged head of the GO or at a head
    # after it (an unresolvable head counts as after: a read that fails refuses)
    nogo_after() { # <judged head>: refuses (fail 5) on a NO-GO for this PR at it or at a descendant of it
        local nq nf nh nrc
        while IFS= read -r nq; do
            [ -n "$nq" ] || continue
            while IFS= read -r nf; do
                [ -n "$nf" ] || continue
                # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
                while IFS= read -r nh; do
                    [ -n "$nh" ] || continue
                    if [ "$nh" = "$1" ]; then nrc=0; else nrc=0; git merge-base --is-ancestor "$1" "$nh" 2>/dev/null || nrc=$?; fi  # swallow-ok: rc 1 is not-after; any other rc refuses below
                    case "$nrc" in 1) ;; *) fail 5 "verdict $nq holds a NO-GO for head ${nh:0:8} of PR $PR, at or after the judged head ${1:0:8}: a GO does not carry past it" ;; esac
                done < <(sed -nE 's/^\*\*NO-GO\*\* for head `([0-9a-f]{40})`\.?$/\1/p' "$nf" 2>/dev/null)
            done < <(grep -lx -e "pr: ${PR}" "$VERDICTS/$nq"/*.md 2>/dev/null)
        done <<< "$QIDS"
    }
    GOQIDS=""
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        case "$q" in [A-Za-z0-9]*) ;; *) fail 5 "the verdict directory '$q' is not a usable judge qid" ;; esac
        case "$q" in *[!A-Za-z0-9._-]*) fail 5 "the verdict directory '$q' is not a usable judge qid" ;; esac
        if VOUT=$(go_trust_verdict "$ROOT" "$q" "$SHA" "$ANCHOR" "$PR"); then
            # a GO at the head that is a delta no-op record (a failed attempt left it) is a carried GO too
            NOOPJ=$(sed -nE 's/^delta-judged: ([0-9a-f]{40})$/\1/p' "$VERDICTS/$q/delta-noop-$SHA.md" 2>/dev/null | head -n 1)  # swallow-ok: no such record means a plain GO at the head
            [ -z "$NOOPJ" ] || nogo_after "$NOOPJ"
            GOQIDS="$GOQIDS$q"$'\n'
        else
            case "$VOUT" in
                "no verdict under "*) ;;
                *) fail 5 "verdict $q refuses: $VOUT" ;;
            esac
        fi
    done <<< "$QIDS"
    GO_QID=$(printf '%s' "$GOQIDS" | head -n 1)
    # no GO at the head: a GO at an earlier head of this PR carries when the delta classifies none
    if [ -z "$GO_QID" ]; then
        while IFS= read -r q; do
            [ -n "$q" ] || continue
            # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
            JHEADS=$(sed -nE 's/^\*\*GO\*\* for head `([0-9a-f]{40})`\.?$/\1/p' "$VERDICTS/$q"/*.md 2>/dev/null | sort -u)  # swallow-ok: no readable GO line means nothing carries, and check 5 escalates below
            while IFS= read -r jh; do
                [ -n "$jh" ] && [ "$jh" != "$SHA" ] || continue
                go_trust_verdict "$ROOT" "$q" "$jh" "$ANCHOR" "$PR" >/dev/null || continue
                nogo_after "$jh"
                DC=$(bash "$HERE/delta-class.sh" --qid "$q" "$jh" "$SHA" 2>/dev/null) || DC=trust  # swallow-ok: a failed classifier reads trust, which refuses, below
                LAST_DC="$DC"
                if [ "$DC" = none ]; then GO_QID="$q"; CARRY_FROM="$jh"; break 2; fi
            done <<< "$JHEADS"
        done <<< "$QIDS"
    fi
    [ -n "$GO_QID" ] || fail 5 "$NEED: no judge verdict rules GO for head $SHA of PR $PR${LAST_DC:+ (an earlier GO exists but the delta classifies $LAST_DC, not none)}"
    A_QID="$GO_QID"
    if [ -n "$CARRY_FROM" ]; then
        A_DELTA=none
        add_check 5 pass "$NEED: GO of $GO_QID at ${CARRY_FROM:0:8} carries (delta none)"
    else
        add_check 5 pass "$NEED: GO of $GO_QID at the head"
    fi
fi

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
[ "$FILES_ERR" -eq 0 ] || fail 8 "cannot list PR $PR's changed files (or the listing is empty)"
if printf '%s\n' "$FILES" | tr '\t' '\n' | grep -qx 'VERSION'; then
    fail 8 "PR $PR changes the root VERSION file: a release cut is chief-only"
fi
MSGS=$("$GH_BIN" api "repos/$NWO/pulls/$PR/commits" --paginate --jq '.[] | .commit.message' 2>/dev/null) || fail 8 "cannot read PR $PR's commits"  # swallow-ok: an unreadable commit list escalates at check 8
[ -n "$MSGS" ] || fail 8 "PR $PR's commit list is empty"
if printf '%s\n' "$MSGS" | tr -d '\r' | grep -q '^Fixes-main-red:'; then
    fail 8 "a commit of PR $PR declares Fixes-main-red: a fix-for-red takes the chief's FIX-GO"
fi
add_check 8 pass

if [ "$DRY" -eq 1 ]; then
    write_audit would-go || { echo "auto-go: cannot write the audit row to $AUDIT - no answer given" >&2; exit 1; }
    printf 'WOULD-GO %s %s\n' "$PR" "$SHA"
    exit 0
fi

# --- the GO act ---------------------------------------------------------------------------------------------------
first_line() { printf '%s\n' "$1" | awk 'NF { print; exit }'; }
# a. a GO carried from an earlier head is recorded for this head before go.sh reads it
if [ -n "$CARRY_FROM" ]; then
    SCRATCH="/tmp/claude-$(id -u)"
    EVD=""
    { [ -d "$SCRATCH" ] || mkdir -m 700 "$SCRATCH" 2>/dev/null; } && EVD=$(mktemp -d "$SCRATCH/auto-go.XXXXXX") # prim-ok: write-verdict.sh takes evidence only from /tmp/claude-<uid>
    [ -n "$EVD" ] || fail 9 "cannot stage the no-op evidence under $SCRATCH"
    printf 'auto-go: delta-class.sh classifies %s..%s as none, so the GO of %s on %s carries to this head.\n' "$CARRY_FROM" "$SHA" "$GO_QID" "$CARRY_FROM" > "$EVD/evidence.md" \
        || { rm -rf "$EVD"; fail 9 "cannot write the no-op evidence"; }
    WV_RC=0
    WV=$(bash "$HERE/write-verdict.sh" "$GO_QID" GO "$SHA" --pr "$PR" --delta-noop "$CARRY_FROM" --evidence-file "$EVD/evidence.md" --model auto-go --effort script 2>&1) || WV_RC=$?
    rm -rf "$EVD"
    [ "$WV_RC" -eq 0 ] || fail 9 "write-verdict.sh --delta-noop exit $WV_RC: $(first_line "$WV")"
fi
# b. the GO file: go.sh re-runs ready-check and every gate of its own
GO_RC=0
GO_OUT=$(bash "$HERE/go.sh" --model auto-go --effort script ${GO_QID:+--trust-reviewed "$GO_QID"} "$PR" "$SHA" 2>&1) || GO_RC=$?
if [ "$GO_RC" -ne 0 ]; then
    GO_WHY=$(printf '%s\n' "$GO_OUT" | grep -m1 -E '^go: ') || GO_WHY=$(first_line "$GO_OUT")  # swallow-ok: no go: line falls back to the first output line
    fail 9 "go.sh exit $GO_RC: $GO_WHY${CARRY_FROM:+ (the delta no-op record for $GO_QID at ${SHA:0:8}, written before go.sh ran, stays under verdicts/$GO_QID)}"
fi
GO_FILE="${GO_OUT##*$'\n'}"
case "$GO_FILE" in
    */.locks/go/"$PR.$SHA") ;;
    *)  # go.sh succeeded, so a GO file may stand: name it in the answer and the audit row
        GO_SEEN=$(printf '%s\n' "$GO_OUT" | grep -m1 -E "/\.locks/go/${PR}\.${SHA}\$") || GO_SEEN=".locks/go/$PR.$SHA"  # swallow-ok: no such line falls back to the relative path
        A_GOFILE="$GO_SEEN"
        fail 9 "go.sh exited 0 but its last line is not the GO file path for PR $PR at $SHA; a GO file may exist at .locks/go/$PR.$SHA ($GO_SEEN)" ;;
esac
[ -f "$GO_FILE" ] || fail 9 "go.sh printed $GO_FILE but no such file exists"
A_GOFILE="$GO_FILE"

# c. the bus GO to the worker's session, exactly as verdict-go.sh words it, with the worker's token
# shellcheck disable=SC2016  # the backticks are the Live state entry's literal markers
live_token() { # <key>: the RETASK token of $WORKER from the chief doc's ## Live state <key>: block, only when listed once
    awk -v k="$1" '
        $0 == "## Live state" { s = 1; next }
        s && /^## / { exit }
        s && index($0, k ":") == 1 { b = 1; print; next }
        b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
        b { print }
    ' "$DOC" | grep -oE '`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`' | tr -d '`' \
        | awk -F: -v l="$WORKER" '$1 == l { print $2; n++ } END { exit n != 1 }'
}
TOKEN=$(live_token workers) || TOKEN=""  # swallow-ok: no token is reported as a failed bus send below, the GO file stands
if [ -z "$TOKEN" ] && legacy_names_on; then TOKEN=$(live_token legs) || TOKEN=""; fi  # swallow-ok: as above
JT=""
BRIEF_YES_RC=0
grep -qE '^> \*\*Completes ticket:\*\* yes([^A-Za-z0-9_-]|$)' "$WORKER_DOC" || BRIEF_YES_RC=$?
[ "$BRIEF_YES_RC" -ne 0 ] || JT=" --jira-transition"  # anything else (no, no line, a read error) leaves the ticket open
MSG=$(printf 'GO %s %s - merge with: bash %q%s --go %q' "$PR" "$SHA" "$ANCHOR/scripts/handover/merge-on-green.sh" "$JT" "$GO_FILE")
[ -z "$TOKEN" ] || MSG="$MSG"$'\n'"Your token \`$TOKEN\`."
# shellcheck source=scripts/lib/worker-identity.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/worker-identity.sh" 2>/dev/null || true  # swallow-ok: an unloadable lib leaves no session candidates, reported as a failed bus send below
SESSION=""; BUS_ERR=""; BUS_REF=""
if [ -z "$TOKEN" ]; then
    BUS_ERR="no token for $WORKER in the chief doc's ## Live state"
elif ! declare -F worker_identity >/dev/null 2>&1; then
    BUS_ERR="cannot load scripts/lib/worker-identity.sh"
else
    IDENT=$(worker_identity "$WORKER_DOC"); CANDS=",${IDENT#*$'\t'},"
    CANDS="$CANDS$(basename "$WORKER_DOC" .md),"
    if [ -n "${AUTO_GO_CENSUS:-}" ]; then
        CENSUS=$(bash "$AUTO_GO_CENSUS" 2>/dev/null) || CENSUS="" # swallow-ok: an empty census reads as no live session, reported below
    else
        # shellcheck source=scripts/lanes/lib/claude-sessions.sh
        # shellcheck disable=SC1091
        . "$HERE/../../lanes/lib/claude-sessions.sh" 2>/dev/null || true  # swallow-ok: an unloadable census leaves no live session, reported below
        CENSUS=""; declare -F claude_sessions >/dev/null 2>&1 && { CENSUS=$(claude_sessions 2>/dev/null) || true; }  # swallow-ok: as above
    fi
    HITS=0
    while IFS=$'\t' read -r _cpid cname _crest; do
        [ -n "$cname" ] || continue
        case "$CANDS" in *",$cname,"*) HITS=$((HITS + 1)); SESSION="$cname" ;; esac
    done <<< "$CENSUS"
    if [ "$HITS" -ne 1 ]; then
        BUS_ERR="$HITS live session(s) match the worker (candidates ${CANDS#,})"; SESSION=""
    else
        BUS_BIN="${AUTO_GO_BUS:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}"
        MSGDIR=$(mktemp -d "${TMPDIR:-/tmp}/auto-go-bus.XXXXXX") || MSGDIR=""  # prim-ok: holds one message file and is removed right after the send
        if [ -z "$MSGDIR" ]; then
            BUS_ERR="mktemp failed"
        elif ! printf '%s\n' "$MSG" > "$MSGDIR/msg"; then
            rm -rf "$MSGDIR"
            BUS_ERR="cannot write the bus message file"
        else
            WAIT=""; command -v timeout >/dev/null 2>&1 && WAIT="timeout 15"
            BUS_RC=0
            # shellcheck disable=SC2086  # WAIT is empty or the two words `timeout 15`
            BUS_OUT=$($WAIT "$BUS_BIN" send "$SESSION" "$MSGDIR/msg" 2>&1) || BUS_RC=$?
            rm -rf "$MSGDIR"
            BUS_REF=$(printf '%s\n' "$BUS_OUT" | sed -nE 's/^sent (#[0-9]+) to .*/\1/p' | head -n 1)
            if [ "$BUS_RC" -ne 0 ]; then BUS_ERR="bus send exit $BUS_RC: $(first_line "$BUS_OUT")"
            elif [ -z "$BUS_REF" ]; then BUS_ERR="bus send printed no record number: $(first_line "$BUS_OUT")"; fi
        fi
    fi
fi
if [ -z "$BUS_ERR" ]; then
    A_BUS="$BUS_REF"
    add_check 9 pass
    write_audit go || echo "auto-go: warning - the GO is written and sent but the audit row could not be written to $AUDIT" >&2
    printf 'GO-SENT %s %s to %s bus=%s\n' "$PR" "$SHA" "$WORKER" "$BUS_REF"
    exit 0
fi
add_check 9 pass "GO written; bus: $(printf '%s' "$BUS_ERR" | tr '\r\n\t' '   ' | cut -c1-200)"
write_audit go || echo "auto-go: warning - the GO is written but the audit row could not be written to $AUDIT" >&2
printf 'GO-WRITTEN %s %s bus-failed: %s\n' "$PR" "$SHA" "$(printf '%s' "$BUS_ERR" | tr '\r\n\t' '   ')"
printf 'SENDMESSAGE to=%s :: %s\n' "${SESSION:-$(basename "$WORKER_DOC" .md)}" "$(printf '%s' "$MSG" | tr '\n' ' ')"
exit 11
