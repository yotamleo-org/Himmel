#!/usr/bin/env bash
# scripts/handover/console-kit/cr-disposition.sh - the disposition record for a
# deferred Critical or Important CR finding, and the check go.sh runs on it.
# A Critical or Important finding is never dropped: it ends fixed, disproved,
# or deferred with a disposition a judge (or the console) recorded:
#   fix-here            the fix lands in this PR (a deferral it covers stays open)
#   follow-up:<KEY>     the PR merges and <KEY> carries the fix; needs all three
#                       risk attests: ci-green, no-data-loss, no-weakened-guard
# A leg writing `deferred -> KEY` itself no longer clears the finding.
#
# Usage:
#   cr-disposition.sh record <pr> <head-sha> <finding_id>@<finding_head> \
#       fix-here|follow-up:<KEY> --source judge:<qid>|console \
#       [--attest ci-green,no-data-loss,no-weakened-guard]
#   cr-disposition.sh check <pr> <head-sha> [--trust-path yes|no]
#
# record appends one ledger row to <git-common-dir>/cr-critic-scores.jsonl:
#   {"kind":"amend",...,"target_head","finding_id","set":{"disposition":...},
#    "source":"judge:<qid>"|"console:<name>","attest":[...],"pr","head","mac"}
# The mac is go_msg_mac himmel-disposition-v1 over pr|head|branch|finding_id|
# target_head|disposition|source|attest (the GO key), so an edited row fails.
# It refuses a console-spawned leg or relay (exit 3), as go.sh does.
#
# check reads every finding on the PR's head branch, at any head, with amends
# applied. A crit/imp whose verdict is deferred (or that carries deferred_to and
# is not fixed or disproved) is open unless its LATEST disposition row for this
# PR at <head-sha> has a valid mac, is follow-up:<KEY> with all three attests,
# names a KEY the jira CLI finds, and comes from a judge when the finding is a
# Critical or the PR is a trust path. A judge source counts only when that qid's
# signed verdict rules GO on <head-sha> for this PR (go_trust_verdict).
# JIRA_CMD and GH_CMD replace the CLIs (tests).
#
# Exit codes: 0 recorded / PASS, 1 check refused, 2 usage or cannot evaluate,
#             3 record from a console leg or relay.
#
# Platform guard (gitbash-only): POSIX bash 3.2+.
set -u

usage() {
    echo "usage: cr-disposition.sh record <pr> <head-sha> <finding_id>@<finding_head> fix-here|follow-up:<KEY> --source judge:<qid>|console [--attest ci-green,no-data-loss,no-weakened-guard]" >&2
    echo "       cr-disposition.sh check <pr> <head-sha> [--trust-path yes|no]" >&2
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
        || ! declare -F console_leg >/dev/null 2>&1 || ! declare -F go_trust_verdict >/dev/null 2>&1; then
    echo "cr-disposition: cannot load scripts/lib/go-gate.sh" >&2
    exit 2
fi
# shellcheck source=scripts/lib/git-clean.sh
# shellcheck disable=SC1091
. "$HERE/../../lib/git-clean.sh" 2>/dev/null && git_env_scrub
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=""  # swallow-ok: empty fails closed on the next line
[ -n "$common" ] || { echo "cr-disposition: not in a git repo, so there is no CR ledger" >&2; exit 2; }
LEDGER="$common/cr-critic-scores.jsonl"
BRANCH=$("$GH" pr view "$PR" --json headRefName -q .headRefName 2>/dev/null) || BRANCH=""  # swallow-ok: empty fails closed on the next line
[ -n "$BRANCH" ] || { echo "cr-disposition: cannot read PR #$PR's head branch" >&2; exit 2; }

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
    if console_leg; then
        echo "cr-disposition: refusing - this is a console-spawned leg; a judge or the console records a disposition" >&2
        exit 3
    fi
    case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
        ''|0|false|off|no) ;;
        *) echo "cr-disposition: refusing - this is a console relay; only the console records a disposition" >&2; exit 3 ;;
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
        console)
            SRC="console:$(printf '%s' "${CONSOLE_SESSION_NAME:-${USER:-unknown}@$(hostname 2>/dev/null || uname -n)}" | tr -c 'A-Za-z0-9._@-' '_')" ;;  # swallow-ok: hostname is only a label fallback
        judge:*) go_trust_id_ok "${SRC#judge:}" || { usage; exit 2; } ;;
        *) usage; exit 2 ;;
    esac
    MAC=$(disp_mac "$FID" "$FHEAD" "$DISP" "$SRC" "$ATTEST") || {
        echo "cr-disposition: cannot sign the row (GO key at $(go_key_file) unreadable)" >&2; exit 2; }
    LEDGER="$LEDGER" BRANCH="$BRANCH" FID="$FID" FHEAD="$FHEAD" DISP="$DISP" SRC="$SRC" ATTEST="$ATTEST" \
    PR="$PR" SHA="$SHA" MAC="$MAC" node -e '
const fs=require("fs"),e=process.env;
let f=null;
for(const l of fs.readFileSync(e.LEDGER,"utf8").split("\n")){
  let o; try{o=JSON.parse(l)}catch{continue}
  if(o.kind==="finding"&&o.branch===e.BRANCH&&o.finding_id===e.FID&&o.head===e.FHEAD) f=o;
}
if(!f){process.stderr.write("cr-disposition: no finding "+e.FID+"@"+e.FHEAD+" on "+e.BRANCH+" in the CR ledger\n");process.exit(2)}
const rec={kind:"amend",ts:new Date().toISOString().replace(/\.\d+Z$/,"Z"),branch:e.BRANCH,target_head:e.FHEAD,
  finding_id:e.FID,artifact:f.artifact||"diff",perspective:f.perspective||"off",set:{disposition:e.DISP},
  reason:"disposition recorded by "+e.SRC,source:e.SRC,attest:e.ATTEST?e.ATTEST.split(","):[],
  pr:Number(e.PR),head:e.SHA,mac:e.MAC};
fs.appendFileSync(e.LEDGER,JSON.stringify(rec)+"\n");
' || exit 2
    echo "cr-disposition: recorded $DISP for $FID@$FHEAD on PR #$PR at $SHA ($SRC)"
    exit 0
fi

TRUST=no
while [ "$#" -gt 0 ]; do
    case "$1" in
        --trust-path) TRUST="${2:-}"; shift 2 2>/dev/null || shift "$#" ;;
        *) usage; exit 2 ;;
    esac
done
case "$TRUST" in yes|no) ;; *) usage; exit 2 ;; esac
[ -f "$LEDGER" ] || { echo "cr-disposition: no CR ledger at $LEDGER" >&2; exit 2; }

jira_get() {
    if [ -n "${JIRA_CMD:-}" ]; then
        "$JIRA_CMD" get "$1" 2>&1
    else
        node "$(dirname "$common")/scripts/jira/dist/index.js" get "$1" 2>&1
    fi
}

# judge_ruled <qid> <"fid@fhead disposition"> - a GO verdict for $SHA under the
# judge's directory names this finding and this disposition on a line of its
# own. Only GO-at-$SHA files count: go_trust_verdict has checked their macs.
judge_ruled() {
    local scope f
    scope=$(go_verdict_scope "$ANCHOR") || return 1
    for f in "$ROOT/$scope/verdicts/$1"/*.md; do
        [ -f "$f" ] || continue
        grep -qxF "**GO** for head \`$SHA\`." "$f" || grep -qxF "**GO** for head \`$SHA\`" "$f" || continue
        tr -d '\r' < "$f" | grep -qxF -e "$2" -e "- $2" && return 0
    done
    return 1
}

# One TSV line per open crit/imp: id, finding head, sev, then the latest
# disposition row for this PR at SHA (disposition, source, attest, mac) or "-".
ROWS=$(LEDGER="$LEDGER" BRANCH="$BRANCH" PR="$PR" SHA="$SHA" node -e '
const fs=require("fs"),e=process.env,SEP=String.fromCharCode(31);
const rows=[];
for(const l of fs.readFileSync(e.LEDGER,"utf8").split("\n")){ try{rows.push(JSON.parse(l))}catch{} }
const key=(b,h,id,a,p)=>[b||"",h,id,a||"diff",p||"off"].join(SEP);
const amends=new Map(), disp=new Map();
for(const a of rows){
  if(a.kind!=="amend"||!a.set||typeof a.set!=="object") continue;
  const k=key(a.branch,a.target_head,a.finding_id,a.artifact,a.perspective);
  if("disposition" in a.set){ if(a.pr===Number(e.PR)&&a.head===e.SHA) disp.set(k,a); continue; }
  amends.set(k,Object.assign({},amends.get(k)||{},a.set));
}
const SEV={crit:"crit",critical:"crit",imp:"imp",important:"imp"};
const findings=new Map();
for(const r of rows){
  if(r.kind!=="finding"||r.branch!==e.BRANCH) continue;
  const k=key(r.branch,r.head,r.finding_id,r.artifact,r.perspective);
  const o=Object.assign({},r,amends.get(key("",r.head,r.finding_id,r.artifact,r.perspective))||{},amends.get(k)||{});
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
  // read collapses empty tab fields, so an empty one travels as "-".
  console.log(f.map(x=>String(x||"-").replace(/[\t\n]/g," ")).join("\t"));
}
') || { echo "cr-disposition: cannot read the CR ledger at $LEDGER" >&2; exit 2; }

# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
ROOT=""
if . "$HERE/../../lib/handover-path.sh" 2>/dev/null; then
    ROOT=$(go_resolve_root "$ANCHOR" 2>/dev/null) || ROOT=""  # swallow-ok: empty ROOT fails every judge source closed
fi
bad=0 n=0
TAB=$(printf '\t')
while IFS="$TAB" read -r fid fhead sev disp src attest mac; do
    [ -n "$fid" ] || continue
    [ "$attest" != "-" ] || attest=""
    n=$((n + 1))
    why=""
    if [ "$disp" = "-" ]; then
        why="deferred with no judge or console disposition at this head (cr-disposition.sh record)"
    elif ! want=$(disp_mac "$fid" "$fhead" "$disp" "$src" "$attest") || [ "$want" != "$mac" ]; then
        why="its disposition row carries no valid mac"
    elif [ "$disp" = fix-here ]; then
        why="the ruling is fix-here: fix it in this PR and amend the finding fixed"
    elif [ "$attest" != "$ATTEST_ALL" ]; then
        why="follow-up without all three attests ($ATTEST_ALL)"
    else
        case "$src" in
            judge:*)
                if [ -z "$ROOT" ]; then
                    why="cannot resolve the handover root to read judge ${src#judge:}'s verdict"
                elif ! r=$(go_trust_verdict "$ROOT" "${src#judge:}" "$SHA" "$ANCHOR" "$PR"); then
                    why="judge ${src#judge:} has no GO verdict for this head: $r"
                elif ! judge_ruled "${src#judge:}" "$fid@$fhead $disp"; then
                    why="judge ${src#judge:}'s GO verdict for this head does not rule '$fid@$fhead $disp'"
                fi ;;
            console:*)
                if [ "$sev" = crit ]; then
                    why="a Critical follow-up needs a judge, not the console"
                elif [ "$TRUST" = yes ]; then
                    why="an Important on a trust path PR needs the trust judge, not the console"
                fi ;;
            *) why="unknown source '$src'" ;;
        esac
        key="${disp#follow-up:}"
        if [ -z "$why" ]; then
            out=$(jira_get "$key") || out=""
            [ "$(printf '%s\n' "$out" | head -n 1 | cut -f1)" = "$key" ] || why="follow-up ticket $key does not exist"
        fi
    fi
    if [ -n "$why" ]; then
        echo "[OPEN] $sev $fid@$fhead: $why"
        bad=$((bad + 1))
    else
        echo "[OK] $sev $fid@$fhead: $disp ($src)"
    fi
done <<EOF
$ROWS
EOF
if [ "$bad" -gt 0 ]; then
    echo "DISPOSITION FAIL ($bad of $n open Critical/Important finding(s) on $BRANCH)"
    exit 1
fi
echo "DISPOSITION PASS ($n deferred Critical/Important finding(s) on $BRANCH dispositioned)"
