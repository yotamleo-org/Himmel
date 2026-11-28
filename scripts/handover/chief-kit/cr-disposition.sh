#!/usr/bin/env bash
# scripts/handover/chief-kit/cr-disposition.sh - the disposition record for a
# deferred Critical or Important CR finding, and the check go.sh runs on it.
# A Critical or Important finding is never dropped: it ends fixed, disproved,
# or deferred with a disposition a judge (or the chief) recorded:
#   fix-here            the fix lands in this PR (a deferral it covers stays open)
#   follow-up:<KEY>     the PR merges and <KEY> carries the fix; needs all three
#                       risk attests: ci-green, no-data-loss, no-weakened-guard
# A worker writing `deferred -> KEY` itself no longer clears the finding.
#
# Usage:
#   cr-disposition.sh record <pr> <head-sha> <finding_id>@<finding_head> \
#       fix-here|follow-up:<KEY> --source judge:<qid>|chief \
#       [--attest ci-green,no-data-loss,no-weakened-guard]
#   cr-disposition.sh check <pr> <head-sha> [--trust-path yes|no] [--repo <owner/repo>]
#
# record appends one ledger row (through ledger-append.sh disposition) to
# <git-common-dir>/cr-critic-scores.jsonl:
#   {"kind":"amend",...,"target_head","finding_id","set":{"disposition":...},
#    "source":"judge:<qid>"|"console:<name>","attest":[...],"pr","head","mac"}
# The mac is go_msg_mac himmel-disposition-v1 over pr|head|branch|finding_id|
# target_head|disposition|source|attest (the GO key), so an edited row fails.
# It refuses a chief-spawned worker or relay (exit 3), as go.sh does.
#
# check reads every finding on the PR's head branch, at any head, with amends
# applied. A crit/imp whose verdict is deferred (or that carries deferred_to and
# is not fixed or disproved) is open unless its LATEST disposition row for this
# PR at <head-sha> has a valid mac, is follow-up:<KEY> with all three attests,
# names a KEY the jira CLI finds, and comes from a judge when the finding is a
# Critical or the PR is a trust path. A judge source counts only when that qid's
# signed verdict rules GO on <head-sha> for this PR (go_trust_verdict).
# A finding the rows leave open, whose latest row is neither fix-here nor
# unsigned, and that carries a deferred_to (a diff finding, perspective off), is
# also cleared by a judge's own signed GO: a record of any qid go_trust_verdict
# accepts at <head-sha>, not a delta no-op, whose ## Verdict block holds the line
#   <fid>@<finding head> follow-up:<KEY> attest:ci-green,no-data-loss,no-weakened-guard
# with <KEY> equal to the finding's deferred_to and known to Jira. A NO-GO for the
# PR at or after <head-sha> (go_nogo_after) vetoes every such ruling, and a root,
# scope, directory or record that route cannot read whole is exit 2.
# --repo <owner/repo> reads the judge verdicts from that adopted repo's bucket (where
# write-verdict.sh --repo writes them); without it, today's harness bucket.
# The head-branch read rides the read token through scripts/lib/gh-read.sh, main when none is set.
# JIRA_CMD and GH_CMD replace the CLIs (tests).
#
# Exit codes: 0 recorded / PASS, 1 check refused, 2 usage or cannot evaluate (a head-branch
#             read GitHub refused or that stalled past CR_DISPOSITION_GH_TIMEOUT also prints the
#             one QUOTA-PAUSE / GH-STALL line and, on a check, leaves a quota marker),
#             3 record from a chief worker or relay.
#
# Platform guard: POSIX bash 3.2+.
set -u

usage() {
    echo "usage: cr-disposition.sh record <pr> <head-sha> <finding_id>@<finding_head> fix-here|follow-up:<KEY> --source judge:<qid>|chief [--attest ci-green,no-data-loss,no-weakened-guard]" >&2
    echo "       cr-disposition.sh check <pr> <head-sha> [--trust-path yes|no] [--repo <owner/repo>]" >&2
}
ATTEST_ALL="ci-green,no-data-loss,no-weakened-guard"

VERB="${1:-}"; shift 2>/dev/null || true
case "$VERB" in record|check) ;; *) usage; exit 2 ;; esac
PR="${1:-}"; SHA="${2:-}"; shift 2 2>/dev/null || { usage; exit 2; }
case "$PR" in ''|0*|*[!0123456789]*) usage; exit 2 ;; esac
case "$SHA" in *[!0123456789abcdef]*) usage; exit 2 ;; esac
[ "${#SHA}" -eq 40 ] || { usage; exit 2; }

HERE="$(cd "$(dirname "$0")" && pwd)"
ANCHOR="$(cd "$HERE/../../.." && pwd)"
GH="${GH_CMD:-gh}"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$HERE/../../lib/go-gate.sh" 2>/dev/null || ! declare -F go_msg_mac >/dev/null 2>&1 \
        || ! declare -F chief_worker >/dev/null 2>&1 || ! declare -F go_trust_verdict >/dev/null 2>&1; then
    echo "cr-disposition: cannot load scripts/lib/go-gate.sh" >&2
    exit 2
fi
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" 2>/dev/null && git_env_scrub
# shellcheck source=scripts/lib/gate-repo-resolver.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/gate-repo-resolver.sh" || { echo "cr-disposition: cannot load scripts/lib/gate-repo-resolver.sh" >&2; exit 2; }
GATE_DIR=$(gate_repo_dir cr-disposition "" "") || exit 2
common=$(git -C "$GATE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""  # swallow-ok: empty fails closed on the next line
[ -n "$common" ] || { echo "cr-disposition: not in a git repo, so there is no CR ledger" >&2; exit 2; }
LEDGER="$common/cr-critic-scores.jsonl"
GH_ERRF=$(mktemp "${TMPDIR:-/tmp}/cr-disposition-gh.XXXXXX" 2>/dev/null) || GH_ERRF=/dev/null  # swallow-ok: no stderr capture only loses the rate-limit wording
CRD_T="${CR_DISPOSITION_GH_TIMEOUT:-60}"
case "$CRD_T" in ''|*[!0-9]*) CRD_T=60 ;; esac
_TIMEOUT_BIN=""
# shellcheck source=scripts/lib/timeout-bin.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/timeout-bin.sh" 2>/dev/null || _TIMEOUT_BIN=""  # swallow-ok: an empty _TIMEOUT_BIN reads without the bound, as go.sh does
CRD_TOK=main
if [ -z "${GH_CMD:-}" ] && [ -f "$HERE/../../lib/gh-read.sh" ]; then
    # shellcheck source=scripts/lib/gh-read.sh
    # shellcheck disable=SC1091
    . "$HERE/../../lib/gh-read.sh"
    _ghr_load
    if [ -n "$_GHR_TOK" ]; then CRD_TOK="read"; else export GH_READ_QUIET=1; fi
    GH="$HERE/../../lib/gh-read.sh"
    [ "$GH_ERRF" = /dev/null ] || export GH_READ_REFUSED_FILE="$GH_ERRF.refused"
fi
BRANCH_RC=0
if [ "$CRD_T" -gt 0 ] && [ -n "$_TIMEOUT_BIN" ]; then
    BRANCH=$(cd "$GATE_DIR" && "$_TIMEOUT_BIN" -k 5 "$CRD_T" "$GH" pr view "$PR" --json headRefName -q .headRefName 2>"$GH_ERRF") || BRANCH_RC=$?
else
    BRANCH=$(cd "$GATE_DIR" && "$GH" pr view "$PR" --json headRefName -q .headRefName 2>"$GH_ERRF") || BRANCH_RC=$?
fi
[ "$BRANCH_RC" -eq 0 ] || BRANCH=""
CRD_REFUSED_TOK=""
[ ! -s "${GH_READ_REFUSED_FILE:-}" ] || read -r CRD_REFUSED_TOK _ < "$GH_READ_REFUSED_FILE" || true  # read-sink-ok: our own mktemp buffer; swallow-ok: an unread row names the token the read set out on
if [ -z "$BRANCH" ]; then
    crd_report() {
        (
            # shellcheck source=scripts/lib/gh-quota.sh
            # shellcheck disable=SC1091
            . "$HERE/../../lib/gh-quota.sh" 2>/dev/null || exit 0
            ghq_line "${CRD_REFUSED_TOK:-$CRD_TOK}" graphql cr-disposition.sh "$1" "$CRD_T" >&2
            [ "$VERB" = check ] && ghq_mark_blocked "$PR" "$SHA" cr-disposition.sh graphql "$1"
            exit 0
        ) || true
    }
    if [ "$BRANCH_RC" -eq 124 ] || [ "$BRANCH_RC" -eq 137 ]; then
        [ "$GH_ERRF" = /dev/null ] || rm -f "$GH_ERRF" "$GH_ERRF.refused"
        crd_report stall
        echo "cr-disposition: reading PR #$PR's head branch timed out after ${CRD_T}s; nothing was judged" >&2
        exit 2
    fi
    if ( . "$HERE/../../lib/gh-quota.sh" 2>/dev/null && ghq_is_rate_limited "$(cat "$GH_ERRF" 2>/dev/null)" ); then  # read-sink-ok: our own mktemp buffer; swallow-ok: an unreadable buffer or lib reads as not a rate limit, which falls to the plain unreadable-branch exit 2 below
        [ "$GH_ERRF" = /dev/null ] || rm -f "$GH_ERRF" "$GH_ERRF.refused"
        crd_report rate-limit
        echo "cr-disposition: GitHub rate limit hit reading PR #$PR's head branch; retry after the quota returns" >&2
        exit 2
    fi
    [ "$GH_ERRF" = /dev/null ] || rm -f "$GH_ERRF" "$GH_ERRF.refused"
    echo "cr-disposition: cannot read PR #$PR's head branch" >&2
    exit 2
fi
[ "$GH_ERRF" = /dev/null ] || rm -f "$GH_ERRF" "$GH_ERRF.refused"


disp_mac() {  # <finding_id> <target_head> <disposition> <source> <attest>
    go_msg_mac himmel-disposition-v1 "$PR|$SHA|$BRANCH|$1|$2|$3|$4|$5"
}

if [ "$VERB" = record ]; then
    FKEY="${1:-}"; DISP="${2:-}"; shift 2 2>/dev/null || { usage; exit 2; }
    SRC="" ATTEST=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --source) SRC="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
            --attest) ATTEST="${ATTEST:+$ATTEST,}${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
            *) usage; exit 2 ;;
        esac
    done
    if chief_worker; then
        echo "cr-disposition: refusing - this is a chief-spawned worker; a judge or the chief records a disposition" >&2
        exit 3
    fi
    case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) ;;
        *) echo "cr-disposition: refusing - this is a chief relay; only the chief records a disposition" >&2; exit 3 ;;
    esac
    FID="${FKEY%@*}"; FHEAD="${FKEY##*@}"
    case "$FKEY" in *@*) ;; *) usage; exit 2 ;; esac
    [ -n "$FID" ] && [ "${#FHEAD}" -eq 40 ] || { usage; exit 2; }
    case "$DISP" in
        fix-here) ATTEST="" ;;
        follow-up:*)
            FKEY=${DISP#follow-up:}
            printf '%s' "$FKEY" | grep -qE '^[A-Z][A-Z0-9]*-[0-9]+$' \
                || { echo "cr-disposition: follow-up needs a Jira key like PROJ-1 (got '$DISP')" >&2; exit 2; }
            ATTEST=$(printf '%s' "$ATTEST" | tr ',' '\n' | sort -u | paste -sd, -)
            [ "$ATTEST" = "$ATTEST_ALL" ] || {
                echo "cr-disposition: follow-up needs --attest $ATTEST_ALL, all three (got '$ATTEST')" >&2; exit 2; } ;;
        *) usage; exit 2 ;;
    esac
    case "$SRC" in
        chief|console)
            SRC="console:$(printf '%s' "${CHIEF_SESSION_NAME:-${USER:-unknown}@$(hostname 2>/dev/null || uname -n)}" | tr -c 'A-Za-z0-9._@-' '_')" ;;  # swallow-ok: hostname is only a label fallback
        judge:*) go_trust_id_ok "${SRC#judge:}" || { usage; exit 2; } ;;
        *) usage; exit 2 ;;
    esac
    MAC=$(disp_mac "$FID" "$FHEAD" "$DISP" "$SRC" "$ATTEST") || {
        echo "cr-disposition: cannot sign the row (GO key at $(go_key_file) unreadable)" >&2; exit 2; }
    CR_LEDGER="$LEDGER" bash "$ANCHOR/scripts/cr/ledger-append.sh" disposition --branch "$BRANCH" --head "$SHA" \
        --id "$FID" --target-head "$FHEAD" --disposition "$DISP" --source "$SRC" --attest "$ATTEST" \
        --pr "$PR" --mac "$MAC" || exit 2
    echo "cr-disposition: recorded $DISP for $FID@$FHEAD on PR #$PR at $SHA ($SRC)"
    exit 0
fi

TRUST=no VREPO=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --trust-path) TRUST="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
        --repo) VREPO="${2:-}"; [ -n "$VREPO" ] || { usage; exit 2; }; shift 2 ;;
        *) usage; exit 2 ;;
    esac
done
case "$TRUST" in yes|no) ;; *) usage; exit 2 ;; esac
[ -f "$LEDGER" ] || { echo "cr-disposition: no CR ledger at $LEDGER" >&2; exit 2; }

jira_get() {
    if [ -n "${JIRA_CMD:-}" ]; then
        "$JIRA_CMD" get "$1" 2>&1
    else
        # shellcheck disable=SC2031  # common is set at top level above; the lib subshells never assign it
        node "$(dirname "$common")/scripts/jira/dist/index.js" get "$1" 2>&1
    fi
}

judge_ruled() {
    local scope f snap text line name keys=""
    scope=$(go_verdict_scope "$ANCHOR" "$VREPO") || return 1
    for f in "$ROOT/$scope/verdicts/$1"/*.md; do
        [ -f "$f" ] || continue
        go_verdict_snapshot "$f" || continue
        snap=$GO_VERDICT_SNAP
        line=$(printf '%s' "$snap" | go_verdict_line /dev/stdin) || continue
        case "$line" in "**GO** for head \`$SHA\`"|"**GO** for head \`$SHA\`.") ;; *) continue ;; esac
        name=${f##*/}; name=${name%.md}
        go_verdict_mac_ok_text "$snap" "$scope" "$1" "$name" || continue
        text=$(printf '%s' "$snap" | tr -d '\r')
        [ "$(printf '%s\n' "$text" | awk '/^## Verdict[[:space:]]*$/ { p = 1; next } p && NF && !n { n = NR + 2; next } n && NR == n { print; exit }')" = "pr: $PR" ] || continue
        if [ "${3:-}" != d1 ]; then
            printf '%s\n' "$text" | awk '/^## / { if (!seen && /^## Verdict[[:space:]]*$/) { p = 1; seen = 1; next } p = 0 } p' | grep -qxF -e "$2" -e "- $2" && return 0
            continue
        fi
        ! printf '%s\n' "$text" | grep -qx 'delta: no-op' || continue
        keys="$keys$(printf '%s\n' "$text" | D1_PRE="$2 follow-up:" D1_SUF=" attest:$ATTEST_ALL" awk '
            /^## / { if (!seen && /^## Verdict[[:space:]]*$/) { p = 1; seen = 1; next } p = 0 }
            !p { next }
            {
                l = $0; pre = ENVIRON["D1_PRE"]; suf = ENVIRON["D1_SUF"]
                if (substr(l, 1, 2) == "- ") l = substr(l, 3)
                if (length(l) <= length(pre) + length(suf)) next
                if (substr(l, 1, length(pre)) != pre || substr(l, length(l) - length(suf) + 1) != suf) next
                k = substr(l, length(pre) + 1, length(l) - length(pre) - length(suf))
                if (k ~ /^[A-Z][A-Z0-9]*-[0-9]+$/) print k
            }')"$'\n'
    done
    [ "${3:-}" = d1 ] || return 1
    keys=$(printf '%s' "$keys" | awk 'NF && !seen[$0]++')
    [ -n "$keys" ] || return 1
    printf '%s\n' "$keys"
}

ROWS=$(LEDGER="$LEDGER" BRANCH="$BRANCH" PR="$PR" SHA="$SHA" AMEND_AUTH="$ANCHOR/scripts/cr/ledger-amend-auth.js" node -e '
const fs=require("fs"),e=process.env,SEP=String.fromCharCode(31);
const rows=[];
for(const l of fs.readFileSync(e.LEDGER,"utf8").split("\n")){ try{rows.push(JSON.parse(l))}catch{} }
const key=(b,h,id,a,p)=>[b||"",h,id,a||"diff",p||"off"].join(SEP);
const amends=new Map(), disp=new Map();
// Past the cutover only a signed lowering amend counts (ledger-amend-auth.js).
for(const a of require(e.AMEND_AUTH).filterRows(rows)){
  if(a.kind!=="amend"||!a.set||typeof a.set!=="object") continue;
  const k=key(a.branch,a.target_head,a.finding_id,a.artifact,a.perspective);
  if("disposition" in a.set){ if(a.pr===Number(e.PR)&&a.head===e.SHA) disp.set(k,a); continue; }
  if(!amends.has(k)) amends.set(k,[]);
  amends.get(k).push(a);
}
const SEV={crit:"crit",critical:"crit",imp:"imp",important:"imp"};
const findings=new Map();
for(const r of rows){
  if(r.kind!=="finding"||r.branch!==e.BRANCH) continue;
  const k=key(r.branch,r.head,r.finding_id,r.artifact,r.perspective);
  const o=Object.assign({},r);
  const mine=(amends.get(key("",r.head,r.finding_id,r.artifact,r.perspective))||[]).concat(amends.get(k)||[]);
  for(const a of mine.sort((x,y)=>rows.indexOf(x)-rows.indexOf(y))) Object.assign(o,a.set);
  findings.set(k,o);
}
for(const [k,o] of findings){
  const sev=SEV[String(o.severity||"").toLowerCase()], v=String(o.verdict||"").toLowerCase();
  if(!sev||v==="fixed"||v==="disproved") continue;
  if(v!=="deferred"&&!o.deferred_to) continue;
  const d=disp.get(k);
  const f=[o.finding_id,k.split(SEP)[1],sev];
  if(d) f.push(d.set.disposition,d.source,(d.attest||[]).join(","),d.mac);
  else f.push("-","-","-","-");
  f.push(o.deferred_to||"-",k.split(SEP)[3],k.split(SEP)[4]);
  // read collapses empty tab fields, so an empty one travels as "-".
  console.log(f.map(x=>String(x||"-").replace(/[\t\n]/g," ")).join("\t"));
}
') || { echo "cr-disposition: cannot read the CR ledger at $LEDGER" >&2; exit 2; }

# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
ROOT="" ROOT_WHY=""
if . "$HERE/../../lib/handover-path.sh" 2>/dev/null; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || { ROOT_WHY=$(go_resolve_root "$ANCHOR" 2>&1 >/dev/null); ROOT=""; }  # swallow-ok: empty ROOT fails every judge source closed
fi
VC_BUILT=0 VC_ERR="" VC_VETO=""
VC_QIDS=()
verdict_context() {
    local scope vdir q f r qids
    [ "$VC_BUILT" -eq 0 ] || { [ -z "$VC_ERR" ]; return; }
    VC_BUILT=1
    if [ -z "$ROOT" ]; then
        VC_ERR="cannot resolve the handover root (${ROOT_WHY:-go_resolve_root printed no reason}) to read the judge verdicts at this head"
        return 1
    fi
    if ! scope=$(go_verdict_scope "$ANCHOR" "$VREPO"); then
        VC_ERR="cannot resolve the <user>/<bucket> verdict scope for repo '${VREPO:-this harness}' under $ROOT"
        return 1
    fi
    vdir="$ROOT/$scope/verdicts"
    r=0; VC_VETO=$(go_nogo_after "$vdir" "$PR" "$GATE_DIR" "$SHA") || r=$?
    case "$r" in
        0) VC_VETO="" ;;
        1) q=$(printf '%s\n' "$VC_VETO" | sed -n 's/^verdict \([^ ]*\) holds a NO-GO .*/\1/p')
           VC_VETO="judge ${q:-?} holds a NO-GO for PR $PR at or after $SHA" ;;
        *) VC_ERR="$VC_VETO"; return 1 ;;
    esac
    r=0; qids=$(go_pr_qids "$vdir" "$PR" "$SHA") || r=$?
    [ "$r" -eq 0 ] || { VC_ERR="$qids"; return 1; }
    while IFS= read -r q; do
        [ -n "$q" ] || continue
        for f in "$vdir/$q"/*.md; do
            [ -e "$f" ] || continue
            go_verdict_snapshot "$f" || {
                VC_ERR="the verdict record $f cannot be read whole (unreadable, empty or holds a NUL byte), so it may be a NO-GO"
                return 1; }
        done
        go_trust_verdict "$ROOT" "$q" "$SHA" "$ANCHOR" "$PR" "$VREPO" >/dev/null && VC_QIDS+=("$q")
    done <<EOF
$qids
EOF
    return 0
}

bad=0 n=0 OUT=""
TAB=$(printf '\t')
while IFS="$TAB" read -r fid fhead sev disp src attest mac dto art persp; do
    [ -n "$fid" ] || continue
    [ "$attest" != "-" ] || attest=""
    n=$((n + 1))
    why="" block=0
    if [ "$disp" = "-" ]; then
        why="deferred with no judge or chief disposition at this head (cr-disposition.sh record)"
    elif ! want=$(disp_mac "$fid" "$fhead" "$disp" "$src" "$attest") || [ "$want" != "$mac" ]; then
        why="its disposition row carries no valid mac" block=1
    elif [ "$disp" = fix-here ]; then
        why="the ruling is fix-here: fix it in this PR and amend the finding fixed" block=1
    elif [ "$attest" != "$ATTEST_ALL" ]; then
        why="follow-up without all three attests ($ATTEST_ALL)"
    else
        case "$src" in
            judge:*)
                if [ -z "$ROOT" ]; then
                    why="cannot resolve the handover root to read judge ${src#judge:}'s verdict"
                elif ! r=$(go_trust_verdict "$ROOT" "${src#judge:}" "$SHA" "$ANCHOR" "$PR" "$VREPO"); then
                    why="judge ${src#judge:} has no GO verdict for this head: $r"
                elif ! judge_ruled "${src#judge:}" "$fid@$fhead $disp"; then
                    why="judge ${src#judge:}'s GO verdict for this head does not rule '$fid@$fhead $disp'"
                fi ;;
            console:*)
                if [ "$sev" = crit ]; then
                    why="a Critical follow-up needs a judge, not the chief"
                elif [ "$TRUST" = yes ]; then
                    why="an Important on a trust path PR needs the trust judge, not the chief"
                fi ;;
            *) why="unknown source '$src'" ;;
        esac
        key="${disp#follow-up:}"
        if [ -z "$why" ]; then
            out=$(jira_get "$key") || out=""
            [ "$(printf '%s\n' "$out" | head -n 1 | cut -f1)" = "$key" ] || why="follow-up ticket $key does not exist"
        fi
    fi
    if [ -n "$why" ] && [ "$block" -eq 0 ] && [ "$dto" != "-" ] && [ "$art" = diff ] && [ "$persp" = off ]; then
        [ "$disp" != "-" ] || why="no disposition row at this head"
        if ! verdict_context; then
            echo "cr-disposition: $VC_ERR (not a GitHub wait: repair the path or re-persist the record)" >&2
            exit 2
        fi
        dkey=$(printf '%s' "$dto" | tr '[:lower:]' '[:upper:]')
        vwhy="no judge GO at this head carries $fid@$fhead follow-up:$dkey attest:$ATTEST_ALL (brief the judge with the deferred key)"
        hit="" other=""
        if [ -n "$VC_VETO" ]; then
            vwhy="$VC_VETO"
        else
            for q in ${VC_QIDS[@]+"${VC_QIDS[@]}"}; do
                keys=$(judge_ruled "$q" "$fid@$fhead" d1) || continue
                if printf '%s\n' "$keys" | grep -qxF -e "$dkey"; then hit=$q; break; fi
                [ -n "$other" ] || other="judge $q rules follow-up:$(printf '%s\n' "$keys" | head -n 1) but the finding is deferred to $dkey"
            done
            if [ -n "$hit" ]; then
                out=$(jira_get "$dkey") || out=""
                if [ "$(printf '%s\n' "$out" | head -n 1 | cut -f1)" = "$dkey" ]; then
                    OUT="${OUT}[OK] $sev $fid@$fhead: follow-up:$dkey (verdict:$hit)"$'\n'
                    continue
                fi
                vwhy="follow-up ticket $dkey does not exist"
            elif [ -n "$other" ]; then
                vwhy="$other"
            fi
        fi
        why="$why; $vwhy"
    fi
    if [ -n "$why" ]; then
        OUT="${OUT}[OPEN] $sev $fid@$fhead: $why"$'\n'
        bad=$((bad + 1))
    else
        OUT="${OUT}[OK] $sev $fid@$fhead: $disp ($src)"$'\n'
    fi
done <<EOF
$ROWS
EOF
printf '%s' "$OUT"
if [ "$bad" -gt 0 ]; then
    echo "DISPOSITION FAIL ($bad of $n open Critical/Important finding(s) on $BRANCH)"
    exit 1
fi
echo "DISPOSITION PASS ($n deferred Critical/Important finding(s) on $BRANCH dispositioned)"
