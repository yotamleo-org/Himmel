#!/usr/bin/env bash
# scripts/handover/chief-kit/go-batch.sh - the chief's one-step GO for every green judged PR.
# It decides per open PR whether a GO can be written now, fast-forwards the primary checkout once,
# runs go.sh for every GO-able PR in parallel and sends each worker its GO with that worker's token.
# It never writes a GO file itself: go.sh does, and go.sh re-runs ready-check.sh and every gate of
# its own, so this script only chooses which PRs to try and with which contract and judge qid.
#
# Usage: go-batch.sh --doc <chief doc> --fleet <fleet manifest> [--dry-run] [--jobs <n>]
#   --doc      the chief's handover doc: its `## Live state` workers: span holds each worker's token,
#              and a merge-hold: line there holds a PR, a ticket key or all
#   --fleet    the chief's fleet manifest (<chief doc stem>.fleet.json): each worker's label and doc
#   --dry-run  print the rows and write nothing (no fast-forward, no go.sh, no message)
#   --jobs     at most this many go.sh runs at once (default 4, 1 to 16)
#
# One gh read lists the open PRs. A PR is GO-able when all of these hold, the first failure is its
# HOLD reason:
#   1. not a draft, and a native worker's newest READY <pr> <head> GREEN bullet names it (the
#      worker's doc, as close-facts.sh reads it); a claudex or unknown lane is the chief's by hand
#   2. that READY head is the PR's head now (a push since is a stale head)
#   3. no merge-hold: line in the chief doc names the PR, one of its title keys or all, and the
#      brief does not say `Merge: chief`
#   4. the contract: the brief's last `> **Completes ticket:** yes|no` line (none reads no, as
#      auto-go.sh does) must equal the PR body's `completes-ticket:` line when the body
#      has one; a disagreement is a hold, never a guess. A brief that says yes while the PR
#      body leaves a remainder (a `Remaining:` or `owed ->` line; scripts/lib/pr_remainder.py,
#      read for the ticket key of the title's [KEY]) is a hold too, and so is an unreadable
#      remainder (no [KEY] in the title, no answer from the reader). A brief with no line and a
#      body with none is contract no with contract-why=no-contract-on-record, and the worker's
#      message says why. go.sh gets the contract as --contract
#   5. a judge verdict where one is required (the brief asks for a judge, every changed file is
#      under docs/ or a *.md file, or any judge NO-GO is on record for the PR, which go.sh reads
#      only under --trust-reviewed): the newest verdict under <root>/<user>/<bucket>/verdicts/ that
#      rules GO for this PR at this head, a delta no-op record included. Its qid goes to go.sh as
#      --trust-reviewed. A PR that needs none runs go.sh plain; go.sh's exit 8 (the diff hits a CI
#      trust path) retries once with the newest verdict's qid, and no verdict holds the PR
#   6. the worker has a usable token: the one in the chief doc's workers: span, else the first
#      backticked value of the last `> **RETASK:**` line of its brief above `## Results`. A
#      usable token has dash-joined parts (CJ-N1-b07851f7) and is not NONCE-UNKNOWN; with none
#      the row is NO-TOKEN and no GO is written, so no GO exists that its worker is never told
#      about and no message ever quotes a placeholder
#
# The primary checkout (GO_BATCH_ANCHOR, else this script's primary checkout) is fast-forwarded
# once, before any go.sh runs; one that cannot fast-forward is exit 1 and no GO is written, because
# go.sh and the merge gate read their libraries from it.
#
# Output, one row per PR, then a summary:
#   GO-SENT <pr> <head8> to <label> bus=<#n> contract=<yes|no>[ contract-why=<slug>] qid=<qid|none>
#   GO-WRITTEN <pr> <head8> contract=<c> qid=<q>[ contract-why=<slug>] bus-failed: <why>      (then SENDMESSAGE to=<session> :: <msg>)
#   WOULD-GO <pr> <head8> to <label> contract=<c>[ contract-why=<slug>] qid=<q>               (--dry-run)
#   HOLD <pr> <head8> <reason>
#   NO-TOKEN <pr> <label>
#   go-batch: <n> GO, <m> held
# Exit: 0 done; 1 setup failed (a library, the gh read or its 200-PR limit, the chief doc, the fast-forward); 2 usage;
# 3 run from a chief-spawned worker or a relay, only the chief writes a GO; 11 a GO is written but a
# worker message was not delivered: send each SENDMESSAGE row by hand.
#
# Run it as the chief by absolute path from the primary checkout. Seams (tests): GO_BATCH_ANCHOR,
# GO_BATCH_GH, GO_BATCH_GO, GO_BATCH_BUS, GO_BATCH_CENSUS replace the primary checkout, gh, go.sh,
# the himmel-bus CLI and the process census.
#
# Platform guard: bash 3.2+, jq, git, GNU date.
# git-env-ok: every git call goes through git_clean or cf_git (scripts/lib/git-clean.sh, loaded by close-facts.sh), which scrub GIT_* first
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() {
    echo "usage: go-batch.sh --doc <chief doc> --fleet <fleet manifest> [--dry-run] [--jobs <n>]" >&2
    exit 2
}
DOC=""; FLEET=""; DRY=0; JOBS=4
while [ "$#" -gt 0 ]; do
    case "$1" in
        --doc) [ "$#" -ge 2 ] || usage; DOC="$2"; shift 2 ;;
        --fleet) [ "$#" -ge 2 ] || usage; FLEET="$2"; shift 2 ;;
        --jobs) [ "$#" -ge 2 ] || usage; JOBS="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        *) usage ;;
    esac
done
[ -n "$DOC" ] && [ -n "$FLEET" ] || usage
case "$JOBS" in ''|*[!0-9]*|0|0?*) usage ;; esac
[ "$JOBS" -le 16 ] || usage

# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/go-gate.sh" 2>/dev/null || { echo "go-batch: cannot load scripts/lib/go-gate.sh - refusing" >&2; exit 1; }
declare -F chief_worker >/dev/null 2>&1 || { echo "go-batch: scripts/lib/go-gate.sh defines no chief_worker - refusing" >&2; exit 1; }
if chief_worker; then
    echo "go-batch: refusing - this is a chief-spawned worker (HIMMEL_CONSOLE_LEG is set); only the chief writes a GO." >&2
    exit 3
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *) echo "go-batch: refusing - this is a chief relay (HIMMEL_CONSOLE_RELAY is set); only the chief writes a GO." >&2; exit 3 ;;
esac
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/handover-path.sh" || { echo "go-batch: cannot load scripts/lib/handover-path.sh" >&2; exit 1; }
# shellcheck source=scripts/handover/chief-kit/close-facts.sh
# shellcheck disable=SC1091
. "$HERE/close-facts.sh" || { echo "go-batch: cannot load close-facts.sh" >&2; exit 1; }
for f in "$DOC" "$FLEET"; do
    [ -f "$f" ] && [ -r "$f" ] || { echo "go-batch: $f is not a readable file" >&2; exit 1; }
done

ANCHOR="${GO_BATCH_ANCHOR:-}"
if [ -z "$ANCHOR" ]; then
    ANCHOR="$(git_clean -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || ANCHOR=""  # swallow-ok: an empty anchor falls to the checkout two levels above, next line
    ANCHOR="${ANCHOR%/.git}"
    [ -n "$ANCHOR" ] || ANCHOR="$(cd "$HERE/../../.." && pwd)"
fi
GO_BIN="${GO_BATCH_GO:-$HERE/go.sh}"
GH_BIN="${GO_BATCH_GH:-}"
[ -n "$GH_BIN" ] || { GH_BIN="$HERE/../../lib/gh-read.sh"; [ -f "$GH_BIN" ] || GH_BIN=gh; }
ROOT=$(go_resolve_root "$ANCHOR") || { echo "go-batch: cannot resolve the handover root - nothing was judged" >&2; exit 1; }
SCOPE=$(go_verdict_scope "$ANCHOR") || { echo "go-batch: cannot resolve the verdict scope (user slug or the primary checkout) - nothing was judged" >&2; exit 1; }
VERD="$ROOT/$SCOPE/verdicts"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/go-batch.XXXXXX") || { echo "go-batch: mktemp failed" >&2; exit 1; }  # prim-ok: one scratch dir for this run, removed by the EXIT trap below
trap 'rm -rf "$WORK"' EXIT

GH_OK=0
( cd "$ANCHOR" && "$GH_BIN" pr list --state open --limit 200 --json number,title,headRefOid,baseRefName,isDraft,body,files ) > "$WORK/prs.json" 2>"$WORK/gh.err" || GH_OK=1
[ "$GH_OK" -ne 0 ] || jq -e 'type == "array"' "$WORK/prs.json" >/dev/null 2>&1 || GH_OK=1
[ "$GH_OK" -eq 0 ] || { echo "go-batch: cannot read the open PR list (gh: $(head -n 1 "$WORK/gh.err" | cut -c1-200)) - nothing was judged" >&2; exit 1; }
[ "$(jq length "$WORK/prs.json")" -lt 200 ] || { echo "go-batch: the open PR list reached the 200 limit, so PRs beyond it were not read - nothing was judged" >&2; exit 1; }
: > "$WORK/map"
jq -r '(.workers // .legs // [])[]? | [.label, .doc, (.lane // "unknown")] | @tsv' "$FLEET" > "$WORK/fleet.tsv" 2>/dev/null \
    || { echo "go-batch: cannot read the fleet manifest $FLEET" >&2; exit 1; }
while IFS=$'\t' read -r label wdoc lane; do
    [ -n "$label" ] && [ -f "$wdoc" ] || continue
    wpr=$(doc_pr "$wdoc"); [ -n "$wpr" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$wpr" "$label" "$wdoc" "$lane" "$(doc_ready_head "$wdoc" "$wpr")" >> "$WORK/map"
done < "$WORK/fleet.tsv"

# shellcheck disable=SC2016  # the backticks are the Live state entry's literal markers
live_token() {
    awk '
        $0 == "## Live state" { s = 1; next }
        s && /^## / { exit }
        s && index($0, "workers:") == 1 { b = 1; print; next }
        b && (/^[[:space:]]*$/ || /^[0-9]+\. / || /^[A-Za-z][A-Za-z ]*:/ || /^[-*+>#]/) { b = 0 }
        b { print }
    ' "$DOC" | grep -oE '`[A-Za-z0-9_.-]+:[^`:[:space:]]+:[^`:[:space:]]+:[^`:[:space:]]+`' | tr -d '`' \
        | awk -F: -v l="$1" '$1 == l { print $2; n++ } END { exit n != 1 }'
}
token_usable() { [[ "$1" =~ ^[A-Za-z0-9]+(-[A-Za-z0-9._]+)+$ ]] && [ "$1" != NONCE-UNKNOWN ]; }
# shellcheck disable=SC2016  # the backticks are the RETASK line's literal markers
brief_token() {
    awk '/^## Results/ { exit } /^> \*\*RETASK:\*\*/ { l = $0 } END { print l }' "$1" | grep -oE '`[^`]*`' | head -n 1 | tr -d '`'
}
worker_token() {
    local t
    t=$(live_token "$1") || t=""  # swallow-ok: no live token falls to the brief's below
    token_usable "$t" || t=$(brief_token "$2") || t=""  # swallow-ok: no brief token is NO-TOKEN at the caller
    token_usable "$t" || return 1
    printf '%s\n' "$t"
}
remainder_answer() {
    local key ans rc=0
    key=$( . "$HERE/../../lib/ticket-status.sh" >/dev/null 2>&1 || exit 3; ticket_key_from_title "$1" ) || { printf 'no [KEY] in the title\n'; return 1; }
    [ -f "$ANCHOR/scripts/lib/pr_remainder.py" ] || { printf 'the anchor has no scripts/lib/pr_remainder.py\n'; return 1; }
    ans=$(printf '%s' "${2//$'\r'/}" | python3 -I "$ANCHOR/scripts/lib/pr_remainder.py" "$key" 2>/dev/null) || rc=$?  # swallow-ok: a non-zero rc is reported below
    case "${ans%%$'\t'*}" in
        none|remaining|handed-off|owed) [ "$rc" -eq 0 ] || { printf 'pr_remainder.py exit %s\n' "$rc"; return 1; }; printf '%s\n' "${ans%%$'\t'*}" ;;
        *) printf 'pr_remainder.py gave no answer\n'; return 1 ;;
    esac
}
cwhy_field() { [ "$1" = - ] || printf ' contract-why=%s' "$1"; }
newest_qid() {
    local qs q f line want best="" bt="" t
    qs=$(go_pr_qids "$VERD" "$1" "$2") || return 0  # swallow-ok: an unreadable verdict directory reads as no verdict, and a hold is the safe answer
    want="**GO** for head \`$2\`"
    for q in $qs; do
        for f in "$VERD/$q"/*.md; do
            [ -f "$f" ] || continue
            line=$(go_verdict_line "$f") || continue  # swallow-ok: an unreadable verdict is not a GO, go.sh reads it again
            [ "$line" = "$want" ] || [ "$line" = "$want." ] || continue
            grep -qxE "pr: $1"$'\r'"?" "$f" 2>/dev/null || continue
            t=$(sed -n 's/^written-at: //p' "$f" | head -n 1)
            if [ -z "$best" ] || [[ $t > $bt ]]; then best="$q"; bt="$t"; fi
        done
    done
    [ -z "$best" ] || printf '%s\n' "$best"
}
nogo_recorded() {
    local qs q f line h
    qs=$(go_pr_qids "$VERD" "$1" "$2") || { printf 'the verdict directory is unreadable\n'; return 0; }
    for q in $qs; do
        for f in "$VERD/$q"/*.md; do
            [ -f "$f" ] || continue
            grep -qxE "pr: $1"$'\r'"?" "$f" 2>/dev/null || continue
            line=$(go_verdict_line "$f") || { printf '%s@unreadable\n' "$q"; return 0; }
            case "$line" in
                '**NO-GO** for head `'*) h="${line#*\`}"; printf '%s@%s\n' "$q" "${h:0:8}"; return 0 ;;
            esac
        done
    done
}

HELD=0; WRITTEN=0; UNDELIVERED=0
: > "$WORK/golist"
HOLDS=$(awk '$0 == "## Live state" { s = 1; next } s && /^## / { s = 0 }
             s && /^[[:space:]]*([-*+][[:space:]]+)?merge-hold:/ { sub(/^[^:]*:[[:space:]]*/, ""); print }' "$DOC") \
    || { echo "go-batch: cannot read the chief doc $DOC" >&2; exit 1; }

jq -r '.[] | [.number, .headRefOid, .baseRefName, .isDraft] | @tsv' "$WORK/prs.json" > "$WORK/pr.tsv"
while IFS=$'\t' read -r PR HEADSHA _base DRAFT <&3; do
    H8="${HEADSHA:0:8}"
    hold() { printf 'HOLD %s %s %s\n' "$PR" "$H8" "$1"; HELD=$((HELD + 1)); }
    if [ "$DRAFT" = true ]; then hold "a draft"; continue; fi
    ROW=$(awk -F'\t' -v p="$PR" '$1 == p { r = $0 } END { print r }' "$WORK/map")
    if [ -z "$ROW" ]; then hold "no worker's newest READY or MERGED bullet names this PR"; continue; fi
    IFS=$'\t' read -r _p LABEL WDOC LANE RHEAD <<< "$ROW"
    if [ "$LANE" != native ]; then hold "worker $LABEL is lane $LANE: the chief merges for it by hand"; continue; fi
    if [ -z "$RHEAD" ]; then hold "worker $LABEL has no READY GREEN bullet for it"; continue; fi
    if [ "$RHEAD" != "$HEADSHA" ]; then hold "stale head: the worker's READY names ${RHEAD:0:8}, the PR head is now $H8"; continue; fi
    TITLE=$(jq -r --argjson n "$PR" '.[] | select(.number == $n) | .title // ""' "$WORK/prs.json")
    KEYS=$(printf '%s' "$TITLE" | grep -oE '[A-Z][A-Z0-9]*-[0-9]+' | sort -u)
    BLOCK=""
    for tok in $(printf '%s\n' "$HOLDS" | tr -d '`' | tr ',;' '  '); do
        tok="${tok#\#}"
        [ "$tok" = all ] && BLOCK="merge-hold: all"
        [ "$tok" = "$PR" ] && BLOCK="merge-hold: $PR"
        for key in $KEYS; do [ "$tok" = "$key" ] && BLOCK="merge-hold: $key"; done
    done
    if [ -n "$BLOCK" ]; then hold "the chief doc's Live state says $BLOCK"; continue; fi
    if grep -qE '^> \*\*Merge:\*\* chief([^A-Za-z0-9_-]|$)' "$WDOC" 2>/dev/null; then hold "the brief says Merge: chief"; continue; fi
    CONTRACT=$(grep -oE '^> \*\*Completes ticket:\*\* (yes|no)([^A-Za-z0-9_-]|$)' "$WDOC" | tail -n 1 | sed -E 's/^> \*\*Completes ticket:\*\* (yes|no).*/\1/')
    BRIEF_LINE="$CONTRACT"
    [ -n "$CONTRACT" ] || CONTRACT=no
    PR_BODY=$(jq -r --argjson n "$PR" '.[] | select(.number == $n) | .body // ""' "$WORK/prs.json") || { hold "contract: remainder unreadable (the PR body cannot be read)"; continue; }
    BODY_VALS=$(printf '%s\n' "$PR_BODY" | tr -d '\r' | awk '
        /^[ \t]{0,3}(```|~~~)/ { fence = !fence; next }
        !fence && /^completes-ticket:[ \t]*(yes|no)[ \t]*$/ { v = $0; sub(/^completes-ticket:[ \t]*/, "", v); sub(/[ \t]*$/, "", v); seen[v] = 1 }
        END { for (v in seen) print v }' | sort -u | tr '\n' ' ')
    case "$BODY_VALS" in "yes ") BODY_VAL=yes ;; "no ") BODY_VAL=no ;; "") BODY_VAL="" ;; *) BODY_VAL=both ;; esac
    [ "$BODY_VAL" != both ] || { hold "contract: the PR body names both yes and no"; continue; }
    REM_KIND=$(remainder_answer "$TITLE" "$PR_BODY") || { hold "contract: remainder unreadable ($REM_KIND)"; continue; }
    case "$REM_KIND" in remaining|owed) REM_YES=1 ;; *) REM_YES=0 ;; esac
    [ "$REM_YES" -eq 0 ] || [ "$CONTRACT" != yes ] || { hold "contract: the brief says yes, the PR body leaves a remainder ($REM_KIND)"; continue; }
    [ -z "$BODY_VAL" ] || [ "$BODY_VAL" = "$CONTRACT" ] || { hold "contract: the brief says $CONTRACT, the PR body says $BODY_VAL"; continue; }
    CWHY="-"; [ -n "$BRIEF_LINE" ] || [ -n "$BODY_VAL" ] || CWHY="no-contract-on-record"
    WHY=""
    if grep -qF 'the chief runs an opus judge before GO' "$WDOC" 2>/dev/null; then
        WHY="the brief asks for a judge"
    elif ! jq -r --argjson n "$PR" '.[] | select(.number == $n) | .files[]?.path' "$WORK/prs.json" | awk 'NF' | grep -qvE '^(docs/|.*\.md$)'; then
        WHY="a docs PR"
    fi
    NOGO=$(nogo_recorded "$PR" "$HEADSHA")
    [ -z "$NOGO" ] || [ -n "$WHY" ] || WHY="a judge NO-GO is on record: $NOGO"
    QID=""
    if [ -n "$WHY" ]; then
        QID=$(newest_qid "$PR" "$HEADSHA")
        if [ -z "$QID" ]; then hold "no judge verdict at head ($WHY)"; continue; fi
    fi
    TOKEN=$(worker_token "$LABEL" "$WDOC") || {
        printf 'NO-TOKEN %s %s\n' "$PR" "$LABEL"; HELD=$((HELD + 1)); continue
    }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$PR" "$HEADSHA" "$LABEL" "$WDOC" "$CONTRACT" "$TOKEN" "$CWHY" "$QID" >> "$WORK/golist"
done 3< "$WORK/pr.tsv"

if [ "$DRY" -eq 1 ]; then
    while IFS=$'\t' read -r pr head label _doc contract _tok cwhy qid; do
        printf 'WOULD-GO %s %s to %s contract=%s%s qid=%s\n' "$pr" "${head:0:8}" "$label" "$contract" "$(cwhy_field "$cwhy")" "${qid:-none}"
        WRITTEN=$((WRITTEN + 1))
    done < "$WORK/golist"
    printf 'go-batch: %s GO, %s held\n' "$WRITTEN" "$HELD"
    exit 0
fi
if [ ! -s "$WORK/golist" ]; then
    printf 'go-batch: 0 GO, %s held\n' "$HELD"
    exit 0
fi

if ! PULL=$(cf_git "$ANCHOR" pull --ff-only 2>&1); then
    echo "go-batch: the primary checkout $ANCHOR did not fast-forward ($(printf '%s\n' "$PULL" | tail -n 1 | cut -c1-200)); no GO written. Fix it by hand, then re-run." >&2
    exit 1
fi
run_one() {
    local pr="$1" head="$2" c="$3" q="$4" out rc=0
    out=$(bash "$GO_BIN" --model go-batch --effort script --contract "$c" ${q:+--trust-reviewed "$q"} "$pr" "$head" 2>&1 < /dev/null) || rc=$?
    if [ "$rc" -eq 8 ] && [ -z "$q" ]; then
        q=$(newest_qid "$pr" "$head")
        if [ -z "$q" ]; then
            rc=88; out="trust path: no judge verdict at head"
        else
            rc=0
            out=$(bash "$GO_BIN" --model go-batch --effort script --contract "$c" --trust-reviewed "$q" "$pr" "$head" 2>&1 < /dev/null) || rc=$?
        fi
    fi
    { printf '%s\n%s\n' "$rc" "${q:-none}"; printf '%s\n' "$out"; } > "$WORK/res.$pr"
}
N=0
while IFS=$'\t' read -r pr head _label _doc contract _tok _cwhy qid; do
    run_one "$pr" "$head" "$contract" "$qid" &
    N=$((N + 1))
    [ $((N % JOBS)) -ne 0 ] || wait
done < "$WORK/golist"
wait

# shellcheck source=scripts/lanes/lib/claude-sessions.sh
# shellcheck disable=SC1091
[ -n "${GO_BATCH_CENSUS:-}" ] || . "$HERE/../../lanes/lib/claude-sessions.sh" 2>/dev/null || true  # swallow-ok: an unloadable census leaves no live session, reported per row as bus-failed
send_bus() {
    local ident cands census hits=0 cname _cpid _crest msgdir bus_rc=0 bus_out wait_cmd=""
    SESSION=""; BUS_REF=""; BUS_ERR=""
    ident=$(worker_identity "$2"); cands=",${ident#*$'\t'},$(basename "$2" .md),"
    if [ -n "${GO_BATCH_CENSUS:-}" ]; then
        census=$(bash "$GO_BATCH_CENSUS" 2>/dev/null) || census=""  # swallow-ok: an empty census reads as no live session, reported below
    else
        census=""; declare -F claude_sessions >/dev/null 2>&1 && { census=$(claude_sessions 2>/dev/null) || true; }  # swallow-ok: as above
    fi
    while IFS=$'\t' read -r _cpid cname _crest; do
        [ -n "$cname" ] || continue
        case "$cands" in *",$cname,"*) hits=$((hits + 1)); SESSION="$cname" ;; esac
    done <<< "$census"
    if [ "$hits" -ne 1 ]; then BUS_ERR="$hits live session(s) match the worker"; SESSION=""; return 0; fi
    msgdir=$(mktemp -d "${TMPDIR:-/tmp}/go-batch-bus.XXXXXX") || { BUS_ERR="mktemp failed"; return 0; }  # prim-ok: holds one message file and is removed right after the send
    printf '%s\n' "$3" > "$msgdir/msg" || { rm -rf "$msgdir"; BUS_ERR="cannot write the bus message file"; return 0; }
    command -v timeout >/dev/null 2>&1 && wait_cmd="timeout 15"
    # shellcheck disable=SC2086  # wait_cmd is empty or the two words `timeout 15`
    bus_out=$($wait_cmd "${GO_BATCH_BUS:-$HERE/../../../marketplace/plugins/himmel-bus/bin/bus}" send "$SESSION" "$msgdir/msg" 2>&1) || bus_rc=$?
    rm -rf "$msgdir"
    BUS_REF=$(printf '%s\n' "$bus_out" | sed -nE 's/^sent (#[0-9]+) to .*/\1/p' | head -n 1)
    if [ "$bus_rc" -ne 0 ]; then BUS_ERR="bus send exit $bus_rc: $(printf '%s\n' "$bus_out" | head -n 1 | cut -c1-150)"
    elif [ -z "$BUS_REF" ]; then BUS_ERR="bus send printed no record number"; fi
}
while IFS=$'\t' read -r pr head label wdoc contract tok cwhy _qid; do
    { read -r rc; read -r qid; GOOUT=$(cat); } < "$WORK/res.$pr"
    h8="${head:0:8}"
    if [ "$rc" -ne 0 ]; then
        why=$(printf '%s\n' "$GOOUT" | grep -m1 -E '^go: ') || why=$(printf '%s\n' "$GOOUT" | tail -n 1)  # swallow-ok: no go: line falls back to the last output line
        printf 'HOLD %s %s go.sh exit %s: %s\n' "$pr" "$h8" "$rc" "$(printf '%s' "$why" | cut -c1-240)"
        HELD=$((HELD + 1)); continue
    fi
    GOFILE="${GOOUT##*$'\n'}"
    case "$GOFILE" in
        */.locks/go/"$pr.$head") [ -f "$GOFILE" ] || GOFILE="" ;;
        *) GOFILE="" ;;
    esac
    if [ -z "$GOFILE" ]; then
        printf 'HOLD %s %s go.sh exit 0 but printed no GO file path for this PR and head\n' "$pr" "$h8"
        HELD=$((HELD + 1)); continue
    fi
    WRITTEN=$((WRITTEN + 1))
    JT=" --jira-transition"; [ "$contract" = yes ] || JT=""
    MSG=$(printf 'GO %s %s - merge with: bash %q%s --go %q' "$pr" "$head" "$ANCHOR/scripts/handover/merge-on-green.sh" "$JT" "$GOFILE")
    [ "$cwhy" = - ] || MSG="$MSG"$'\n'"contract no: ${cwhy//-/ }; merge without --jira-transition"
    MSG="$MSG"$'\n'"Your token \`$tok\`."
    send_bus "$label" "$wdoc" "$MSG"
    if [ -z "$BUS_ERR" ]; then
        printf 'GO-SENT %s %s to %s bus=%s contract=%s%s qid=%s\n' "$pr" "$h8" "$label" "$BUS_REF" "$contract" "$(cwhy_field "$cwhy")" "$qid"
    else
        UNDELIVERED=$((UNDELIVERED + 1))
        printf 'GO-WRITTEN %s %s contract=%s qid=%s%s bus-failed: %s\n' "$pr" "$h8" "$contract" "$qid" "$(cwhy_field "$cwhy")" "$BUS_ERR"
        printf 'SENDMESSAGE to=%s :: %s\n' "${SESSION:-$(basename "$wdoc" .md)}" "$(printf '%s' "$MSG" | tr '\n' ' ')"
    fi
done < "$WORK/golist"
printf 'go-batch: %s GO, %s held\n' "$WRITTEN" "$HELD"
[ "$UNDELIVERED" -eq 0 ] || exit 11
exit 0
