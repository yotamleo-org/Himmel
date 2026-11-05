#!/usr/bin/env bash
# release-judge-reconcile.sh [--launches <launches.jsonl>] [--launch-logs <dir>] [--projects <dir>]
#                            [--since <UTC ISO>] [--until <UTC ISO>] [--tolerance <pct>]
#
# Read-only. Matches each headless release-judge transcript to its launch row and prints
# the counts and the class totals, so the cost page's release spend can be trusted or the gap named.
#   transcripts: <projects>/*rm-run-judge*/<session id>.jsonl (the empty temp cwd every release judge run
#                uses); a transcript's cost is its last cost-state totalCostUSD.
#   launch rows: kind=judge rows of launches.jsonl; a row's cost is sub_cost_usd, else cost_usd.
# A row matches a transcript by its session_id; a row without one (the API launcher's sub-fallback row) matches
# the unused transcript with the same cost (to 1e-6) whose run ended within [-120s, +5s] of the row's ts.
# A zero-cost row (a refused API-route attempt) matches a zero-cost transcript the same way; a zero-cost
# transcript left over spent nothing, so it is counted apart and is never "unmatched".
# A transcript that cannot be read is skipped with a WARN and counted: the report then says INCOMPLETE instead
# of a tolerance verdict, and the exit is 1. Exit 2 = bad argument or unreadable launches file.
# --since/--until bound both sides by the row ts and the transcript's last record. --tolerance <pct> adds
# a verdict line on |ledger - transcripts| / transcripts. Defaults: the real paths of this station.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 1

# The default ledger is where the writers put it: beside HIMMEL_API_CREDIT_STATE, else beside the credit config's ledger_path.
CREDIT_DIR="$HOME/.himmel/state/api-credit"
LAUNCHES="$CREDIT_DIR/launches.jsonl"
if [ -n "${HIMMEL_API_CREDIT_STATE:-}" ]; then
    LAUNCHES="$(dirname "$HIMMEL_API_CREDIT_STATE")/launches.jsonl"
else
    lp="$(jq -r '.ledger_path // empty' "${HIMMEL_API_CREDIT_CONFIG:-$CREDIT_DIR/config.json}" 2>/dev/null)" || lp=""
    [ "${lp#/}" = "$lp" ] || LAUNCHES="$(dirname "$lp")/launches.jsonl"
fi
LOGS="${HIMMELCTL_CACHE_DIR:-$HOME/.claude/himmel}/launch-logs"
PROJECTS="$HOME/.claude/projects"
SINCE="" UNTIL="" TOL=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --launches) LAUNCHES="${2:?--launches needs a path}"; shift 2 ;;
        --launch-logs) LOGS="${2:?--launch-logs needs a path}"; shift 2 ;;
        --projects) PROJECTS="${2:?--projects needs a path}"; shift 2 ;;
        --since) SINCE="${2:?--since needs a UTC timestamp}"; shift 2 ;;
        --until) UNTIL="${2:?--until needs a UTC timestamp}"; shift 2 ;;
        --tolerance) TOL="${2:?--tolerance needs a percentage}"; shift 2 ;;
        *) echo "release-judge-reconcile: unknown argument: $1" >&2; exit 2 ;;
    esac
done
command -v jq >/dev/null 2>&1 || { echo "release-judge-reconcile: jq is required" >&2; exit 2; }
[ -r "$LAUNCHES" ] || { echo "release-judge-reconcile: cannot read launches file: $LAUNCHES" >&2; exit 2; }

T="$(tmpdir)" || exit 1
trap 'rm -rf "$T"' EXIT

# one TSV line per transcript: session id, first timestamp, last timestamp, cost
shopt -s nullglob
: > "$T/tr.tsv"
SKIPPED=0
for f in "$PROJECTS"/*rm-run-judge*/*.jsonl; do
    sid="$(basename "$f" .jsonl)"
    if ! jq -rn --arg sid "$sid" 'reduce inputs as $r ({c:0,s:"",e:""};
          (if $r.type == "cost-state" then .c = ($r.totalCostUSD // 0) else . end)
          | (($r.timestamp? // "") as $t | if ($t | type) == "string" and $t != "" then (if .s == "" then .s = $t else . end) | .e = $t else . end))
        | [$sid, .s, .e, .c] | @tsv' "$f" >> "$T/tr.tsv" 2>/dev/null; then
        echo "release-judge-reconcile: WARN transcript $sid unreadable, skipped" >&2
        SKIPPED=$((SKIPPED + 1))
    fi
done
jq -c 'select(type == "object" and .kind == "judge")' "$LAUNCHES" > "$T/rows.jsonl" || { echo "release-judge-reconcile: launches file is not JSON lines: $LAUNCHES" >&2; exit 2; }
: > "$T/logids.txt"
for f in "$LOGS"/*.log; do
    grep -h 'role=release-manager' "$f" 2>/dev/null | sed -n 's/.* session_id=\([0-9a-f-]*\).*/\1/p' >> "$T/logids.txt" || true
done

jq -rn --slurpfile rows "$T/rows.jsonl" --rawfile tr "$T/tr.tsv" --rawfile logs "$T/logids.txt" \
    --arg since "$SINCE" --arg until "$UNTIL" --arg tol "$TOL" --argjson skipped "$SKIPPED" '
  def ep: if . == "" or . == null then null else sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 end;
  def ok($mode; $r; $t):
    if $mode == 1 then ($r.session_id // "") == $t.sid
    else ($r.session_id // "") == "" and $r.cost != null
         and (($r.cost - $t.cost) | fabs) <= 0.000001
         and $r.ep >= ($t.end - 5) and $r.ep <= ($t.end + 120) end;
  def assign($mode; $R; $T): . as $st | reduce range(0; $R | length) as $i ($st;
      . as $s
      | if ($s.m | has($i | tostring)) then .
        else ([range(0; $T | length) as $j | select(($s.used | has($j | tostring)) | not)
               | select(ok($mode; $R[$i]; $T[$j])) | $j] | .[0]) as $j
             | if $j == null then . else .used[$j | tostring] = $i | .m[$i | tostring] = $j end
        end);
  ($since | ep) as $lo | ($until | ep) as $hi
  | ($rows | map(. + {ep: (.ts | ep),
        cost: (if (.sub_cost_usd // "") != "" then (.sub_cost_usd | tonumber) elif (.cost_usd // "") != "" then (.cost_usd | tonumber) else null end)})
     | map(select(.ep != null and ($lo == null or .ep >= $lo) and ($hi == null or .ep < $hi)))) as $R
  | ($tr | split("\n") | map(select(. != "") | split("\t")
        | {sid: .[0], start: (.[1] | ep), end: (.[2] | ep), cost: (.[3] | tonumber)})
     | map(select(.end != null and ($lo == null or .end >= $lo) and ($hi == null or .end < $hi)))) as $T
  | ($logs | split("\n") | map(select(. != ""))) as $logids
  | ({used: {}, m: {}} | assign(1; $R; $T) | assign(2; $R; $T)) as $res
  | ($res.used | length) as $matched
  | ([$res.m | to_entries[] | select(($R[.key | tonumber].session_id // "") != "")] | length) as $bySid
  | ([range(0; $T | length) as $j | select(($res.used | has($j | tostring)) | not) | $T[$j]]) as $left
  | ($left | map(select(.cost > 0))) as $unmatched
  | ($left | map(select(.cost <= 0)) | length) as $zero
  | ($R | map(.cost // 0) | add // 0) as $lt
  | ($T | map(.cost) | add // 0) as $tt
  | def usd: . * 100 | round / 100;
    "launch rows (kind=judge): \($R | length)  total $\($lt | usd)",
    "transcripts: \($T | length)  total $\($tt | usd)",
    "matched: \($matched)  (by session id \($bySid), by cost and time \($matched - $bySid))",
    "transcripts with no launch row: \($unmatched | length)  total $\($unmatched | map(.cost) | add // 0 | usd)  (with a launch-log line: \([$unmatched[] | select(.sid as $s | $logids | index($s))] | length))",
    "zero-cost transcripts (no spend, not counted as unmatched): \($zero)",
    "launch rows with no transcript: \($R | length - $matched)",
    "class totals: ledger $\($lt | usd), transcripts $\($tt | usd), difference \(if $tt == 0 then "n/a" else (($lt - $tt) / $tt * 10000 | round / 100 | tostring) + "%" end)",
    (if $skipped > 0 then "unreadable transcripts skipped: \($skipped)  (not in any count or total above)" else empty end),
    (if $tol == "" then empty
     elif $skipped > 0 then "INCOMPLETE: \($skipped) transcript(s) could not be read, so the totals are not the class totals and no tolerance verdict is given"
     elif $tt == 0 then "tolerance \($tol)%: n/a, no transcript cost"
     else (if ((($lt - $tt) | fabs) / $tt * 100) <= ($tol | tonumber) then "WITHIN TOLERANCE \($tol)%" else "OUTSIDE TOLERANCE \($tol)%" end) end)
'
[ "$SKIPPED" -eq 0 ] || exit 1
