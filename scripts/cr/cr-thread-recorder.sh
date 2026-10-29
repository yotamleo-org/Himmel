#!/usr/bin/env bash
# scripts/cr/cr-thread-recorder.sh — record CodeRabbit's review threads in the CR ledger.
# Usage: cr-thread-recorder.sh <pr>... | --since <YYYY-MM-DD> [--until <YYYY-MM-DD>] [--repo <owner/name>]
#
# WHY: CodeRabbit's findings arrive only as PR review threads (inline) or inside
# the review body (outside the diff), and nothing wrote them down, so cr-scores
# showed it at 0 findings while it reviewed nearly every PR. For each MERGED PR
# this reads the review threads whose first comment is CodeRabbit's (GraphQL) and
# appends one `finding` row per thread to the ledger, carrying pr + thread_id:
#   resolved after a later commit on the branch  -> verdict fixed
#   resolved with no later commit (dismissed)    -> verdict disproved
#   still open at merge                          -> verdict unaddressed
# Outside-diff findings parsed from the review body (the check-ci reader) become
# model coderabbit-outside rows, verdict unaddressed (the body carries no outcome;
# a disposition a worker already recorded for that head+id wins).
#
# --since/--until list the merged PRs in a date range (GitHub search caps a list at
# 1000, so a longer span is run in chunks; a warning says when the cap was hit).
#
# Idempotent: a thread is skipped when its thread_id is in the ledger, an outside
# finding when its (head, id) is. A hand-written coderabbit row on the same branch
# that matches a thread (same head+file+line, or the same file and a similar
# title) counts as that thread and is neither duplicated nor rewritten.
#
# Rate limits: each GraphQL answer carries rateLimit{remaining,resetAt}. Under
# CR_RECORDER_FLOOR (default 200) a token is parked until its reset and the next
# one is used; with none left the run sleeps to the earliest reset, or exits 3 when
# that is beyond CR_RECORDER_MAX_WAIT (default 3900 s). A re-run resumes cleanly.
#
# Env: CR_LEDGER (ledger path), GH_CMD (gh seam), CR_RECORDER_REPO (owner/name),
#      CR_RECORDER_GH_TOKENS (extra read-only GitHub tokens, comma/space separated,
#      tried after the ambient gh auth; never printed), CR_RECORDER_FLOOR,
#      CR_RECORDER_MAX_WAIT, CR_RECORDER_LIST_CAP (search cap, default 1000, a test seam),
#      CR_RECORDER_SLEEP_CMD (test seam, default sleep).
# Exit: 0 done, 1 usage, 2 cannot run, 3 stopped early (budget, or a PR unreadable).
#
# ponytail: fixed/disproved is read from commit dates, not from the reply text, and
# a hand-written row is matched by head+file+line or title words, so an odd
# duplicate can survive; upgrade path = a finding id the panel stamps on its rows.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 2
# shellcheck source=scripts/lib/coderabbit-body-findings.sh
. "$HERE/../lib/coderabbit-body-findings.sh" || exit 2

CAP="${CR_RECORDER_LIST_CAP:-1000}"; PRS=""; SINCE=""; UNTIL=""; REPO="${CR_RECORDER_REPO:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) [ $# -ge 2 ] || { echo "cr-thread-recorder: --since needs a date" >&2; exit 1; }; SINCE="$2"; shift 2 ;;
    --until) [ $# -ge 2 ] || { echo "cr-thread-recorder: --until needs a date" >&2; exit 1; }; UNTIL="$2"; shift 2 ;;
    --repo)  [ $# -ge 2 ] || { echo "cr-thread-recorder: --repo needs owner/name" >&2; exit 1; }; REPO="$2"; shift 2 ;;
    ''|*[!0-9]*) echo "cr-thread-recorder: unknown argument '$1'" >&2; exit 1 ;;
    *) PRS="$PRS $1"; shift ;;
  esac
done
[ -n "$PRS" ] || [ -n "$SINCE" ] || { echo "usage: cr-thread-recorder.sh <pr>... | --since <YYYY-MM-DD> [--until <YYYY-MM-DD>] [--repo owner/name]" >&2; exit 1; }
for _t in jq node; do command -v "$_t" >/dev/null 2>&1 || { echo "cr-thread-recorder: $_t not found" >&2; exit 2; }; done

GH="${GH_CMD:-gh}"
FLOOR="${CR_RECORDER_FLOOR:-200}"; MAX_WAIT="${CR_RECORDER_MAX_WAIT:-3900}"
SLEEP_CMD="${CR_RECORDER_SLEEP_CMD:-sleep}"
# git-env-ok: a read-only rev-parse of the caller's own repo to find the ledger
if [ -n "${CR_LEDGER:-}" ]; then LEDGER="$CR_LEDGER"; else
  _gcd=$(git rev-parse --path-format=absolute --git-common-dir) || { echo "cr-thread-recorder: cannot resolve the ledger (set CR_LEDGER)" >&2; exit 2; }
  LEDGER="$_gcd/cr-critic-scores.jsonl"
fi
touch "$LEDGER" || { echo "cr-thread-recorder: cannot write $LEDGER" >&2; exit 2; }
WORK="$(mktemp -d -t cr-recorder.XXXXXX)" || exit 2 # prim-ok: standalone script, the template form is portable
trap 'rm -rf "$WORK"' EXIT

# slot 0 is the ambient gh auth; every further slot is one token from the env list.
TOKS=(""); LOW=(0)
set -f
for _tok in $(printf '%s' "${CR_RECORDER_GH_TOKENS:-}" | tr ',' ' '); do TOKS+=("$_tok"); LOW+=(0); done
set +f
NSLOT=${#TOKS[@]}; CUR=0

_gh() {
  if [ -n "${TOKS[$CUR]}" ]; then GH_TOKEN="${TOKS[$CUR]}" "$GH" "$@"; else "$GH" "$@"; fi
}

# _pick_slot — leave CUR on a slot that is not parked; sleep to the earliest reset
# when every slot is. rc 1 = that reset is beyond MAX_WAIT.
_pick_slot() {
  local now i best wait_s
  while :; do
    now=$(date +%s)
    for ((i = 0; i < NSLOT; i++)); do
      ci=$(( (CUR + i) % NSLOT ))
      if [ "${LOW[$ci]}" -le "$now" ]; then CUR=$ci; return 0; fi
    done
    best=0
    for ((i = 1; i < NSLOT; i++)); do [ "${LOW[$i]}" -lt "${LOW[$best]}" ] && best=$i; done
    wait_s=$(( LOW[best] - now + 2 ))
    [ "$wait_s" -le "$MAX_WAIT" ] || { echo "cr-thread-recorder: every token is below the GraphQL floor and the reset is ${wait_s}s away (beyond ${MAX_WAIT}s) — stopping; re-run after the reset" >&2; return 1; }
    echo "cr-thread-recorder: every token is below the GraphQL floor; waiting ${wait_s}s for the reset" >&2
    $SLEEP_CMD "$wait_s"
    LOW[best]=0; CUR=$best
  done
}

# _park <reset-epoch> — park the current slot until then (60 s when unknown).
_park() {
  local until_="${1:-}"
  case "$until_" in ''|*[!0-9]*) until_=$(( $(date +%s) + 60 )) ;; esac
  LOW[CUR]=$until_
  echo "cr-thread-recorder: token slot $CUR is below the GraphQL floor; parked until reset" >&2
}

# shellcheck disable=SC2016  # GraphQL document, not shell
QUERY='query($owner:String!,$name:String!,$num:Int!,$after:String){
 rateLimit{cost remaining resetAt}
 repository(owner:$owner,name:$name){ pullRequest(number:$num){
  number state mergedAt headRefName headRefOid
  commits(last:100){nodes{commit{committedDate}}}
  reviewThreads(first:100,after:$after){ pageInfo{hasNextPage endCursor}
   nodes{ id isResolved isOutdated path line originalLine resolvedBy{login}
    comments(first:1){nodes{author{login} body createdAt originalCommit{oid}}} } } } } }'

# shellcheck disable=SC2016  # jq program, not shell
SHAPE='.data.repository.pullRequest as $p
 | {number:$p.number,state:$p.state,mergedAt:$p.mergedAt,branch:$p.headRefName,headOid:$p.headRefOid,
    lastCommit:([$p.commits.nodes[].commit.committedDate]|max),
    threads:[$p.reviewThreads.nodes[] | select((.comments.nodes|length)>0)
      | {id,isResolved,path,line:(.line//.originalLine),resolvedBy:(.resolvedBy.login),
         author:.comments.nodes[0].author.login,createdAt:.comments.nodes[0].createdAt,
         oid:.comments.nodes[0].originalCommit.oid,body:.comments.nodes[0].body}]}'

# _fetch_pr <num> <out-file> — the PR with ALL its threads as one JSON document.
_fetch_pr() {
  local num="$1" out="$2" after="" resp err page more tries rem rst
  : > "$out"
  while :; do
    tries=0
    while :; do
      _pick_slot || return 3
      err="$WORK/err"
      if [ -n "$after" ]; then
        resp=$(_gh api graphql -f query="$QUERY" -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F num="$num" -f after="$after" 2>"$err")
      else
        resp=$(_gh api graphql -f query="$QUERY" -f owner="${REPO%%/*}" -f name="${REPO##*/}" -F num="$num" 2>"$err")
      fi && break
      tries=$((tries + 1))
      if grep -qiE 'rate limit|RATE_LIMITED|abuse|secondary' "$err" && [ "$tries" -le $((NSLOT + 1)) ]; then _park ""; continue; fi
      echo "cr-thread-recorder: PR #$num: GraphQL read failed: $(head -c 200 "$err")" >&2
      return 1
    done
    page=$(printf '%s' "$resp" | jq -c "$SHAPE") && [ -n "$page" ] && [ "$(printf '%s' "$page" | jq -r '.number // empty')" != "" ] || {
      echo "cr-thread-recorder: PR #$num: unreadable GraphQL answer" >&2; return 1; }
    if [ ! -s "$out" ]; then printf '%s\n' "$page" > "$out"
    else more=$(printf '%s' "$page" | jq -c '.threads'); jq -c --argjson m "$more" '.threads += $m' "$out" > "$out.n" && mv "$out.n" "$out"; fi
    rem=$(printf '%s' "$resp" | jq -r '.data.rateLimit.remaining // empty')
    rst=$(printf '%s' "$resp" | jq -r '.data.rateLimit.resetAt // empty | fromdateiso8601? // empty')
    case "$rem" in ''|*[!0-9]*) ;; *) [ "$rem" -ge "$FLOOR" ] || _park "$rst" ;; esac
    [ "$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')" = "true" ] || return 0
    after=$(printf '%s' "$resp" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')
  done
}

# _outside <num> <final-head> <out-tsv> — head<TAB>id<TAB>sev<TAB>file<TAB>line<TAB>title for the
# outside-diff findings of every head whose review carries them. rc 1 = a read failed.
# shellcheck disable=SC2030,SC2031  # GH_TOKEN is set in a subshell on purpose: it must not leak to later calls
_outside() {
  local num="$1" fhead="$2" out="$3" heads h rows rc bad=0
  : > "$out"
  heads=$( ( [ -z "${TOKS[$CUR]}" ] || export GH_TOKEN="${TOKS[$CUR]}"
             cr_body_prior_outside_heads "${REPO%%/*}" "${REPO##*/}" "$num" "$fhead" ) ) || bad=1
  for h in $fhead $heads; do
    rows=$( ( [ -z "${TOKS[$CUR]}" ] || export GH_TOKEN="${TOKS[$CUR]}"
              cr_body_outside_findings "${REPO%%/*}" "${REPO##*/}" "$num" "$h" ) ); rc=$?
    case "$rc" in
      0) [ -z "$rows" ] || printf '%s\n' "$rows" | awk -F'\t' -v h="$h" 'BEGIN{OFS="\t"}{print h,$0}' >> "$out" ;;
      2) echo "cr-thread-recorder: PR #$num: outside-diff list at ${h:0:12} is unparseable (format drift) — skipped" >&2 ;;
      *) bad=1 ;;
    esac
  done
  return "$bad"
}

_cr_rows() { grep -c '"kind":"finding".*"model":"coderabbit' "$LEDGER" | tr -d ' '; }

if [ -z "$REPO" ]; then
  REPO=$("$GH" repo view --json nameWithOwner --jq .nameWithOwner) || REPO=""
fi
case "$REPO" in */*) ;; *) echo "cr-thread-recorder: cannot resolve the repo (pass --repo owner/name)" >&2; exit 2 ;; esac

if [ -n "$SINCE" ]; then
  range=">=$SINCE"; [ -n "$UNTIL" ] && range="$SINCE..$UNTIL"
  listed=$(_gh pr list --repo "$REPO" --state merged --search "merged:$range" --limit "$CAP" --json number --jq '.[].number') || {
    echo "cr-thread-recorder: could not list the merged PRs since $SINCE" >&2; exit 2; }
  [ "$(printf '%s\n' "$listed" | grep -c .)" -ge "$CAP" ] &&
    echo "cr-thread-recorder: WARNING the search returned $CAP PRs (its cap); narrow the range with --until and run again" >&2
  PRS="$PRS $(printf '%s\n' "$listed" | sort -n | tr '\n' ' ')"
fi

before=$(_cr_rows); n_pr=0; n_skip=0; n_fail=0; rc_all=0
for num in $PRS; do
  pj="$WORK/pr-$num.json"; ot="$WORK/out-$num.tsv"
  _fetch_pr "$num" "$pj"; rc=$?
  if [ "$rc" -eq 3 ]; then rc_all=3; break; fi
  if [ "$rc" -ne 0 ]; then n_fail=$((n_fail + 1)); rc_all=3; continue; fi
  if [ "$(jq -r '.state' "$pj")" != "MERGED" ]; then
    echo "cr-thread-recorder: PR #$num is not merged — skipped"; n_skip=$((n_skip + 1)); continue
  fi
  if ! _outside "$num" "$(jq -r '.headOid' "$pj")" "$ot"; then
    echo "cr-thread-recorder: PR #$num: could not read the review bodies; outside-diff findings may be missing — re-run to retry" >&2
    rc_all=3
  fi
  # shellcheck disable=SC2016  # JS program, not shell
  # The ledger read and the append share one lock, so two recorder runs cannot both miss a row and both add it.
  with_lock "$LEDGER.lock" env PRFILE="$pj" OUTFILE="$ot" LEDGER="$LEDGER" node -e '
const fs = require("fs"), crypto = require("crypto"), e = process.env;
const pr = JSON.parse(fs.readFileSync(e.PRFILE, "utf8"));
const outside = fs.existsSync(e.OUTFILE) ? fs.readFileSync(e.OUTFILE, "utf8").split("\n").filter(Boolean).map(l => {
  const [head, id, sev, file, line, ...t] = l.split("\t"); return { head, id, sev, file, line, title: t.join("\t") }; }) : [];
const seenThread = new Set(), seenKey = new Set(), hand = [];
for (const l of fs.readFileSync(e.LEDGER, "utf8").split("\n")) {
  if (!l.includes("\"model\":\"coderabbit")) continue;
  let r; try { r = JSON.parse(l); } catch (_) { continue; }
  if (r.kind !== "finding" || !/^coderabbit/.test(r.model || "")) continue;
  if (r.thread_id) seenThread.add(r.thread_id);
  seenKey.add(r.head + "\x1f" + r.finding_id);
  if (!r.thread_id && r.model === "coderabbit" && r.branch === pr.branch) hand.push({ r, used: false });
}
const scrub = s => s
  .replace(/[0-9]{8,10}[ \t\v\f]*:[ \t\v\f]*[A-Za-z0-9_-]{35}/g, "[REDACTED]")
  .replace(/(Bearer|bearer)[ \t\v\f]+[A-Za-z0-9._-]{16,}/g, "$1 [REDACTED]")
  .replace(/sk-[A-Za-z0-9][A-Za-z0-9_-]{15,}/g, "[REDACTED]")
  .replace(/AKIA[0-9A-Z]{16}/g, "[REDACTED]")
  .replace(/([Aa][Pp][Ii][_-]?[Kk]ey|[Tt]oken|[Ss]ecret)[ \t]*[:=][ \t]*[A-Za-z0-9._-]{12,}/g, "$1=[REDACTED]");
const clean = s => scrub(String(s || "").replace(/\s+/g, " ").trim()).slice(0, 300);
const words = s => new Set(String(s || "").toLowerCase().match(/[a-z0-9]{3,}/g) || []);
const overlap = (a, b) => { a = words(a); b = words(b); if (!a.size || !b.size) return 0;
  let n = 0; for (const w of a) if (b.has(w)) n++; return n / Math.min(a.size, b.size); };
const sevOf = b => { const m = String(b).slice(0, 300).match(/Critical|Major|Minor|Trivial/);
  return !m ? "imp" : m[0] === "Critical" ? "crit" : m[0] === "Major" ? "imp" : "sug"; };
const titleOf = b => { const m = String(b).match(/\*\*([^*\n][^\n]*?)\*\*/);
  if (m) return m[1]; return (String(b).split("\n").find(l => l.trim() && !l.trim().startsWith("_")) || "").replace(/[*`]/g, ""); };
const rows = []; let matched = 0, dup = 0, inline = 0, out = 0;
for (const t of pr.threads) {
  if (!/^coderabbitai/.test(t.author || "")) continue;
  inline++;
  if (seenThread.has(t.id)) { dup++; continue; }
  const title = titleOf(t.body), head = t.oid || pr.headOid;
  const h = hand.find(c => !c.used && (
    (c.r.head === head && ((c.r.file === t.path && (String(c.r.line) === String(t.line) || overlap(c.r.text, title) >= 0.5)) || overlap(c.r.text, title) >= 0.8)) ||
    (c.r.file === t.path && overlap(c.r.text, title) >= 0.6)));
  if (h) { h.used = true; matched++; continue; }
  let verdict, reason;
  if (!t.isResolved) { verdict = "unaddressed"; reason = "thread still open at merge"; }
  else if (pr.lastCommit && pr.lastCommit > t.createdAt) { verdict = "fixed"; reason = "thread resolved after a later commit on the branch"; }
  else { verdict = "disproved"; reason = "thread resolved by " + (t.resolvedBy || "unknown") + " with no later commit"; }
  rows.push({ kind: "finding", ts: t.createdAt, branch: pr.branch, head, model: "coderabbit",
    finding_id: "cr-thread-" + crypto.createHash("sha256").update(t.id).digest("hex").slice(0, 12),
    severity: sevOf(t.body), file: t.path, line: t.line || 0, verdict, artifact: "diff", perspective: "off",
    reason, text: clean(title), pr: pr.number, thread_id: t.id, source: "cr-thread-recorder" });
}
for (const o of outside) {
  out++;
  if (seenKey.has(o.head + "\x1f" + o.id)) { dup++; continue; }
  rows.push({ kind: "finding", ts: pr.mergedAt, branch: pr.branch, head: o.head, model: "coderabbit-outside",
    finding_id: o.id, severity: o.sev, file: o.file, line: Number(o.line) || o.line, verdict: "unaddressed",
    artifact: "diff", perspective: "off", reason: "no disposition recorded for this outside-diff finding",
    text: clean(o.title), pr: pr.number, source: "cr-thread-recorder" });
}
if (rows.length) fs.appendFileSync(e.LEDGER, rows.map(r => JSON.stringify(r)).join("\n") + "\n");
console.log("+" + rows.length + " row(s) (" + inline + " thread(s), " + out + " outside, " + matched + " matched a hand-written row, " + dup + " already recorded)");
' | sed "s/^/cr-thread-recorder: PR #$num: /" || {
    echo "cr-thread-recorder: PR #$num: could not read or append the ledger — re-run to retry" >&2
    n_fail=$((n_fail + 1)); rc_all=3; continue; }
  n_pr=$((n_pr + 1))
done
echo "cr-thread-recorder: $n_pr PR(s) read, $n_skip skipped, $n_fail unreadable; coderabbit ledger rows before=$before after=$(_cr_rows)"
exit "$rc_all"
