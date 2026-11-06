#!/usr/bin/env bash
# scripts/usage/usage-compute.sh -- per-ticket usage records, computed once,
# append-only. Joins two computations that used to live apart:
#   1. per-session tokens   -- scripts/lib/usage-attribution.sh output
#   2. CR rounds / verdicts -- the CR critic ledger (scripts/cr/ledger-append.sh)
# Both read local files and fail closed. A third, opt-in join
# adds PR/CI facts from gh when --repo is given; it fails closed too: any gh
# failure aborts the WHOLE run before anything is appended, and a record never
# stores null for an unknown fact.
# into ONE record per ticket (schema: docs/internals/usage-records.md).
#
# Usage:
#   usage-compute.sh [--projects <dir>] [--ledger <file>] [--store <dir>]
#                    [--range KEY-a..KEY-b | --tickets K1,K2]
#                    [--since <iso>] [--repo OWNER/NAME [--gh <executable>]]
#                    [--print]
#
# It also appends `phase-cost` rows (one per day, session and phase, see
# docs/internals/usage-records.md); those ignore --since and the ticket selectors.
#
# Default appends changed records to <store>/records.jsonl; --print writes the
# records to stdout and touches no store. A record carries ids and numbers
# only -- never message text -- and no compute timestamp, so a rerun on the
# same inputs is byte-identical and an unchanged record is not re-appended.
#
# Platform guard: pure bash 3.2-safe + jq.
set -euo pipefail

die() { echo "usage-compute: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 1
BANK="$HERE/../lib/usage-attribution.sh"

PROJECTS="${HOME}/.claude/projects"
LEDGER=""
STORE="${HIMMEL_USAGE_STORE:-${HOME}/.himmel/state/usage}"
RANGE=""
TICKETS=""
SINCE=""
PRINT=0
PROJECTS_SET=0
REPO=""
GH=""

# one shared check: a value-taking flag must be followed by a non-empty value
need_val() { [ -n "${2:-}" ] || die "$1 needs a non-empty value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --projects) need_val "$@"; PROJECTS="$2"; PROJECTS_SET=1; shift 2 ;;
    --ledger)   need_val "$@"; LEDGER="$2"; shift 2 ;;
    --store)    need_val "$@"; STORE="$2"; shift 2 ;;
    --range)    need_val "$@"; RANGE="$2"; shift 2 ;;
    --tickets)  need_val "$@"; TICKETS="$2"; shift 2 ;;
    --since)    need_val "$@"; SINCE="$2"; shift 2 ;;
    --repo)     need_val "$@"; REPO="$2"; shift 2 ;;
    --gh)       need_val "$@"; GH="$2"; shift 2 ;;
    --print)    PRINT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

# The gh join needs an explicit repo (never inferred from the cwd) and a gh
# that is ONE executable path (a path with a space is fine; arguments are not).
if [ -n "$GH" ] && [ -z "$REPO" ]; then die "--gh needs --repo"; fi
if [ -n "$REPO" ]; then
  [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME: $REPO"
  [ -n "$GH" ] || GH="gh"
  command -v "$GH" >/dev/null 2>&1 || die "gh not found or not executable (one path, no arguments): $GH"
fi

# An explicit input that is missing or unreadable fails closed before anything
# is written; a default may be absent (noted, treated as empty).
if [ "$PROJECTS_SET" = 1 ]; then
  if [ ! -d "$PROJECTS" ] || [ ! -r "$PROJECTS" ]; then die "--projects is not a readable directory: $PROJECTS"; fi
elif [ ! -d "$PROJECTS" ]; then
  echo "usage-compute: note: default projects dir absent ($PROJECTS); no sessions" >&2
  PROJECTS=""
fi
if [ -n "$LEDGER" ]; then
  if [ ! -f "$LEDGER" ] || [ ! -r "$LEDGER" ]; then die "--ledger is not a readable file: $LEDGER"; fi
else
  LEDGER="$(git rev-parse --git-common-dir 2>/dev/null || true)/cr-critic-scores.jsonl"
  [ -f "$LEDGER" ] || echo "usage-compute: note: default CR ledger absent ($LEDGER); no CR data" >&2
fi

# Ticket selector -> {prefix, lo, hi} or {list} or {} (all).
SEL='{}'
if [ -n "$RANGE" ] && [ -n "$TICKETS" ]; then die "--range and --tickets are exclusive"; fi
if [ -n "$RANGE" ]; then
  if ! [[ "$RANGE" =~ ^([A-Z][A-Z0-9]*)-([0-9]+)\.\.([A-Z][A-Z0-9]*)-([0-9]+)$ ]] \
    || [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[3]}" ]; then
    die "--range must be KEY-a..KEY-b with one key prefix: $RANGE"
  fi
  SEL="$(jq -nc --arg p "${BASH_REMATCH[1]}" --argjson lo "${BASH_REMATCH[2]}" --argjson hi "${BASH_REMATCH[4]}" '{prefix:$p,lo:$lo,hi:$hi}')"
elif [ -n "$TICKETS" ]; then
  # every comma-separated entry must be a KEY-n (a trailing comma is an empty entry)
  if ! jq -ne --arg l "$TICKETS" '($l | split(",") | length > 0 and all(.[]; test("^[A-Z][A-Z0-9]*-[0-9]+$")))' >/dev/null; then
    die "--tickets must be comma-separated KEY-n entries: $TICKETS"
  fi
  SEL="$(jq -nc --arg l "$TICKETS" '{list: ($l | split(","))}')"
fi

# The transcript pass can run for minutes on a first run: idle cpu and io priority, never a hard requirement
# (ionice is Linux-only).
renice -n 19 -p $$ >/dev/null 2>&1 || true
if command -v ionice >/dev/null 2>&1; then ionice -c3 -p $$ >/dev/null 2>&1 || true; fi

WORK="$(tmpdir)"
trap 'rm -rf "$WORK"' EXIT
[ -n "$PROJECTS" ] || { PROJECTS="$WORK/noprojects"; mkdir "$PROJECTS"; }

# Serialize the whole compute-then-append (mkdir is atomic), so an older
# snapshot can never publish after a newer one. --print touches no store.
if [ "$PRINT" != 1 ]; then
  mkdir -p "$STORE"
  LOCK="$STORE/.lock"; n=0
  # prim-ok: readers share this directory lock; preserve the 300-second writer deadline instead of with_lock's blocking file protocol.
  until mkdir "$LOCK" 2>/dev/null; do
    n=$((n + 1)); [ "$n" -lt 600 ] || die "store locked: $LOCK (remove it if no run is active)"
    sleep 0.5
  done
  trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$WORK"' EXIT
fi
# a signal exits through the EXIT trap, so the lock never outlives the run
trap 'exit 130' INT TERM HUP

# --- 1. per-session tokens (reuse bank-attribution, do not re-parse JSONL) --
BA_ARGS=("$PROJECTS")
[ -z "$SINCE" ] || BA_ARGS+=(--since "$SINCE")
bash "$BANK" "${BA_ARGS[@]}" > "$WORK/bank.md" || die "bank-attribution failed (incomplete totals refused)"

: > "$WORK/ledger.jsonl"
[ ! -f "$LEDGER" ] || cp "$LEDGER" "$WORK/ledger.jsonl" || die "cannot read ledger: $LEDGER"

# --- 2. join: sessions + CR ledger -> base records ---------------
# shellcheck disable=SC2016  # jq's own $vars
BASE_PROGRAM='
def tk($s): ($s // "" | ascii_upcase | [match("[A-Z][A-Z0-9]*-[0-9]+"; "g").string][0]);
def keyof($s): ([$s | capture("^(?<k>[A-Z][A-Z0-9]*-[0-9]+)").k] | .[0]);
def num($k): ($k | capture("-(?<n>[0-9]+)$").n | tonumber);
def selected($k):
  if $sel.list then ($sel.list | index($k)) != null
  elif $sel.prefix then ($k | startswith($sel.prefix + "-")) and (num($k) >= $sel.lo) and (num($k) <= $sel.hi)
  else true end;
def zero: {turns:0,input:0,cache_read:0,cache_create:0,output:0,sub_turns:0,sub_input:0,sub_cache_read:0,sub_cache_create:0,sub_output:0};
def addz($a; $b): reduce (zero | keys[]) as $f ($a; .[$f] += ($b[$f] // 0));

# sessions: parse the table, merge each "(subagents)" row into its session
( [ $table | split("\n")[]
    | select(startswith("| ") and (startswith("| session |") | not) and (startswith("| **total") | not))
    | .[2:-2] | split(" | ")
    | { name: .[0], n: (.[3]|tonumber), i: (.[4]|tonumber), cr: (.[5]|tonumber), cc: (.[6]|tonumber), o: (.[7]|tonumber) } ]
  | reduce .[] as $r ({};
      ($r.name | endswith(" (subagents)")) as $sub
      | ($r.name | sub(" \\(subagents\\)$"; "")) as $nm
      | .[$nm] = ((.[$nm] // zero)
          | if $sub then (.sub_turns += $r.n | .sub_input += $r.i | .sub_cache_read += $r.cr | .sub_cache_create += $r.cc | .sub_output += $r.o)
            else (.turns += $r.n | .input += $r.i | .cache_read += $r.cr | .cache_create += $r.cc | .output += $r.o) end))
  | to_entries
  | map(. as $e | $e.key as $name
        | (if ($name | test("console|chief"; "i")) then "console" elif ($name | test("judge"; "i")) then "judge" else "leg" end) as $kind
        | (keyof($name)) as $k
        | ({name: $name, kind: $kind, ticket: (if $k != null then $k elif $kind == "console" then "_chief" else "_unattributed" end)} + $e.value))
) as $sessions

# CR ledger: findings (dedup head+id, amends applied), rounds, est tokens
| ( [ $ledger[] ] ) as $L
| ( reduce ($L[] | select(.kind == "finding")) as $f ({};
      ($f.head + "|" + $f.finding_id) as $key
      | if has($key) then . else .[$key] = {ticket: tk($f.branch), verdict: ($f.verdict // "")} end) ) as $f0
| ( reduce ($L[] | select(.kind == "amend")) as $a ($f0;
      ($a.target_head + "|" + $a.finding_id) as $key
      | if has($key) and ($a.set.verdict != null) then .[$key].verdict = $a.set.verdict else . end) ) as $fin
| ( [ $L[] | select(.kind == "finding" or .kind == "avail" or .kind == "score" or .kind == "usage")
      | select(.kind != "avail" or .status == "ok")
      | select(tk(.branch) != null) | {t: tk(.branch), head: .head, est: (if .kind == "usage" then (.est_total_tokens // 0) else 0 end)} ]
    | group_by(.t) | map({key: .[0].t, value: {rounds: ([.[].head] | unique | length), est_tokens: ([.[].est] | add)}}) | from_entries ) as $crt

| ( ([$sessions[] | select(.ticket | startswith("_") | not) | .ticket] + [$crt | keys[]]) | unique | map(select(selected(.))) ) as $tickets
| ( $tickets + ["_chief", "_unattributed"] ) as $all
| [ $all[] as $t
    | ($sessions | map(select(.ticket == $t)) | sort_by(.name)) as $ss
    | select(($ss | length) > 0 or ($crt[$t] != null))
    | def tot($kind): reduce ($ss[] | select(.kind == $kind)) as $s (zero; addz(.; $s));
      ( [ $fin | to_entries[] | select(.value.ticket == $t) | (if .value.verdict == "" then "open" else .value.verdict end) ]
        | group_by(.) | map({key: .[0], value: length}) | from_entries ) as $fc
      | { schema: 1, ticket: $t,
          legs: ($ss | map(del(.ticket))),
          totals: {leg: tot("leg"), console: tot("console"), judge: tot("judge")},
          cr: {rounds: ($crt[$t].rounds // 0), findings: $fc, est_tokens: ($crt[$t].est_tokens // 0)} } ]
'
jq -n -S --rawfile table "$WORK/bank.md" --slurpfile ledger "$WORK/ledger.jsonl" --argjson sel "$SEL" \
  "$BASE_PROGRAM" > "$WORK/base.json"
if [ -n "$TICKETS" ] && [ "$(jq '[.[] | select(.ticket | startswith("_") | not)] | length' "$WORK/base.json")" = 0 ]; then die "--tickets matched no session or CR row: $TICKETS"; fi

# --- 3. PR/CI join (opt-in via --repo) ---------------------------------------
# gh JSON for one call, or die: auth, network, rate limit, a wrong repo and a
# bad --gh all land here, and nothing has been appended yet.
gh_json() {
  local out
  if ! out="$("$GH" "$@" 2>"$WORK/gh.err")"; then
    die "gh $1 $2 failed: $(head -c 200 "$WORK/gh.err" | tr '\n' ' ')"
  fi
  printf '%s' "$out"
}

# Sets PRJ and CIJ for ticket $1. Unknown never becomes a value: any failure or
# unexpected shape dies, so a stored record is either complete or absent.
# shellcheck disable=SC2016  # jq's own $vars
join_ticket() {
  local t="$1" prs mine branches b runs all="[]" n
  prs="$(gh_json pr list -R "$REPO" --search "$t in:title" --state all --json number,state,title,headRefName --limit 100)"
  jq -e 'type == "array" and all(.[]; (.number | type == "number") and (.state | IN("OPEN","CLOSED","MERGED")) and (.title | type == "string") and (.headRefName | type == "string" and length > 0 and (startswith("-") | not)))' <<<"$prs" >/dev/null 2>&1 \
    || die "gh pr list returned an unexpected shape for $t"
  [ "$(jq 'length' <<<"$prs")" -lt 100 ] || die "gh pr list hit its 100-row limit for $t; refusing a truncated join"
  mine="$(jq -c --arg t "$t" '[.[] | select(.title | test("(^|[^A-Z0-9])" + $t + "($|[^A-Z0-9])"; "i"))]' <<<"$prs")"
  if [ "$(jq 'length' <<<"$mine")" = 0 ]; then
    PRJ='{"state":"none"}'; CIJ='{"state":"no-pr"}'; return 0
  fi
  PRJ="$(jq -c '{state: "found", numbers: ([.[].number] | sort), merged: ([.[] | select(.state == "MERGED")] | length), open: ([.[] | select(.state == "OPEN")] | length), closed: ([.[] | select(.state == "CLOSED")] | length)}' <<<"$mine")"
  branches="$(jq -r '[.[].headRefName] | unique | .[]' <<<"$mine")"
  while IFS= read -r b; do
    runs="$(gh_json run list -R "$REPO" --branch "$b" --limit 100 --json databaseId,status,conclusion,createdAt,startedAt,updatedAt)"
    jq -e 'type == "array" and all(.[]; (.databaseId | type == "number") and (.status | IN("queued","in_progress","completed","waiting","requested","pending")) and (.createdAt | type == "string") and (.updatedAt | type == "string") and (.startedAt == null or (.startedAt | type == "string")))' <<<"$runs" >/dev/null 2>&1 \
      || die "gh run list returned an unexpected shape for $t on $b"
    n="$(jq 'length' <<<"$runs")"
    [ "$n" -lt 100 ] || die "gh run list hit its 100-row limit for $t on $b; refusing a truncated join"
    all="$(jq -c --argjson r "$runs" '. + $r' <<<"$all")"
  done <<<"$branches"
  # secs counts completed runs only; startedAt excludes queue wait, createdAt is the
  # recorded fallback when any completed run lacks it (ci.basis says which)
  CIJ="$(jq -c 'unique_by(.databaseId) | [.[] | select(.status == "completed")] as $c
    | (if ($c | length) == 0 then "none" elif all($c[]; .startedAt != null) then "startedAt" else "createdAt" end) as $b
    | [$c[] | (.updatedAt | fromdateiso8601) - ((if $b == "startedAt" then .startedAt else .createdAt end) | fromdateiso8601)] as $d
    | if any($d[]; . < 0) then error("negative ci duration") else . end
    | {state: "found", runs: 0, completed: ($c | length), basis: $b, secs: ($d | add // 0)}' <<<"$all")" || die "cannot compute ci seconds for $t"
  CIJ="$(jq -c --argjson n "$(jq 'unique_by(.databaseId) | length' <<<"$all")" '.runs = $n' <<<"$CIJ")"
}

# --- assemble final records + digest ----------------------------------------
: > "$WORK/records.jsonl"
for t in $(jq -r '.[].ticket' "$WORK/base.json"); do
  rec="$(jq -cS --arg t "$t" '.[] | select(.ticket == $t)' "$WORK/base.json")"
  if [ -n "$REPO" ] && [ "${t#_}" = "$t" ]; then
    join_ticket "$t"
    rec="$(printf '%s' "$rec" | jq -cS --argjson pr "$PRJ" --argjson ci "$CIJ" '. + {pr: $pr, ci: $ci}')"
  fi
  if command -v sha256sum >/dev/null 2>&1; then dg="$(printf '%s' "$rec" | sha256sum | cut -d' ' -f1)"
  else dg="$(printf '%s' "$rec" | shasum -a 256 | cut -d' ' -f1)"; fi
  printf '%s' "$rec" | jq -cS --arg d "$dg" '. + {digest: $d}' >> "$WORK/records.jsonl"
done

# --- 4. phase-cost rows ------------------------------------------------------
# One row per (day, session, phase), priced per call from scripts/lanes/lib/model-prices.tsv
# (a model with no row is usd null / mark unpriced, never another model's rate). Incremental:
# each transcript is read from its saved byte offset, complete lines only, and a message that
# streams over several rows (one message id) counts once, even across two runs. Rows are
# cumulative: a changed (day, session, phase) appends its new total, readers take the latest.
# phase_rule v1 is the cost-page audit: the phase is the last tool before the call [derived];
# a judge, critic, release-mgr or chief session has one whole-session phase [counted].
# ponytail: graph-eval and bots classes need a first-prompt pattern the audit does not give, so
# those sessions are class "other"; upgrade = add the patterns to toplevel_class.
PRICES_TSV="$HERE/../lanes/lib/model-prices.tsv"
[ -r "$PRICES_TSV" ] || die "price table not readable: $PRICES_TSV"
# nano-dollars per token = $/MTok x 1000, so every sum is an integer
PRICES="$(grep -v '^#' "$PRICES_TSV" | jq -Rnc '[inputs | select(length > 0) | split("\t")
  | {p: .[0], i: (.[1]|tonumber*1000|round), o: (.[2]|tonumber*1000|round), cr: (.[3]|tonumber*1000|round),
     c5: (.[4]|tonumber*1000|round), c1: (.[5]|tonumber*1000|round)}]')" || die "cannot read the price table: $PRICES_TSV"

# shellcheck disable=SC2016  # jq's own $vars
PHASE_FILE_JQ='
def cmdphase($c):
  if ($c | test("pr-check|scripts/cr/|review-round|write-verdicts|ledger-append|ready-check|thread-resolve|judge-request|clear-review-marker")) then "review"
  elif ($c | test("check-ci|gh pr checks|gh run|suite-coverage")) then "ci"
  elif ($c | test("jira[\\s\\S]*(create|comment|edit|transition|link|update|move)")) then "ticket-filing"
  elif ($c | test("jira")) then "ticket-read"
  elif ($c | test("git( -C [^ ]+)? (commit|push)|worker-pr-open|merge-on-green|merge-fork-pr|gh pr (create|edit|merge)")) then "ship"
  elif ($c | test("quiet-run|impacted-suites|test-[^ ]*\\.sh|bats|pytest|node --test|shellcheck")) then "tests"
  elif ($c | test("append-results|queue-lock|wrap-subtree|close-wrapped|usage-preflight|(^|[^a-z])bus([^a-z]|$)")) then "comms"
  elif ($c | test("qmd|graphify|worker-graph")) then "retrieval"
  elif ($c | test("scripts/vm/")) then "vm"
  else "build" end;
def toolphase($b):
  ($b.name // "") as $n
  | if $n == "Bash" then cmdphase($b.input.command // "")
    elif $n == "Skill" then (if (($b.input.skill // "") | test("(^|:)pr-check$")) then "review" else "skill" end)
    elif $n | IN("SendMessage", "ListAgents", "ReadNotifications") then "comms"
    elif $n == "ToolSearch" then "tool-load"
    elif $n | IN("Agent", "Task") then "agent"
    else "build" end;
def lasttool($c): ([$c[]? | select(.type == "tool_use")] | last) as $b | if $b == null then null else toolphase($b) end;
def day($ts): $ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | localtime | strftime("%Y-%m-%d");
def contrib($m; $u):
  ($u | { i: (.input_tokens // 0), o: (.output_tokens // 0), cr: (.cache_read_input_tokens // 0),
          c5: (if .cache_creation then (.cache_creation.ephemeral_5m_input_tokens // 0) else (.cache_creation_input_tokens // 0) end),
          c1: (.cache_creation.ephemeral_1h_input_tokens // 0) }) as $t
  | ([$prices[] | . as $row | select(($m // "") | startswith($row.p))] | first // null) as $p
  | $t + { calls: 1, models: { ($m // "unknown"): 1 } }
    + (if $p == null then { nano: 0, unp: 1 }
       else { nano: ($t.i * $p.i + $t.o * $p.o + $t.cr * $p.cr + $t.c5 * $p.c5 + $t.c1 * $p.c1), unp: 0 } end);
def bump($key; $c; $sgn):
  .agg[$key] = (reduce ("calls", "i", "o", "cr", "c5", "c1", "nano", "unp") as $f
      (.agg[$key] // { calls: 0, i: 0, o: 0, cr: 0, c5: 0, c1: 0, nano: 0, unp: 0, models: {} }; .[$f] += $sgn * $c[$f]))
  | .agg[$key].models = (reduce ($c.models | to_entries[]) as $e (.agg[$key].models; .[$e.key] = ((.[$e.key] // 0) + $sgn * $e.value))
      | with_entries(select(.value != 0)))
  | if .agg[$key].calls == 0 then del(.agg[$key]) else . end;
def step($r):
  ($r.message.id // $r.requestId) as $id
  | . as $s
  | if $id != null and $s.cur != null and $s.cur.id == $id then
      bump($s.cur.key; $s.cur.c; -1)
      | contrib($r.message.model; $r.message.usage) as $c
      | bump($s.cur.key; $c; 1) | .cur.c = $c
    else
      ((try day($r.timestamp // "") catch "unknown") + "|" + $s.last) as $key
      | contrib($r.message.model; $r.message.usage) as $c
      | bump($key; $c; 1) | .cur = { id: $id, key: $key, c: $c }
    end
  | (lasttool($r.message.content)) as $lt | if $lt != null then .last = $lt else . end;
( $st // { off: 0, last: "boot", cur: null, agg: {}, title: null, aititle: null, fp: null } ) as $st0
| reduce (inputs | fromjson? | select(type == "object")) as $r ($st0;
    if $r.type == "assistant" and ($r.message | type) == "object" and $r.message.usage
       and (($r.message.model // "") | startswith("<") | not) then step($r)
    elif ($r.type == "system" and $r.subtype == "compact_boundary") or $r.isCompactSummary == true then .last = "compaction"
    elif $r.type == "custom-title" then .title = ($r.customTitle // .title)
    elif $r.type == "ai-title" then .aititle = ($r.aiTitle // .aititle)
    else . end)
| .off = $off | .meta = $meta | .fp = (if .fp == null and $fp != "" then $fp else .fp end)'

# shellcheck disable=SC2016  # jq's own $vars
PHASE_EMIT_JQ='
def toplevel_class($s):
  ($s.title // $s.aititle // "") as $t
  | if $s.fp == "critic" then "critic" elif $s.fp == "release-mgr" then "release-mgr"
    elif ($t | test("chief|console"; "i")) then "chief"
    elif ($t | test("-N[0-9]+|^HIMMEL-[0-9]+")) then "worker" else "other" end;
def zero: { calls: 0, i: 0, o: 0, cr: 0, c5: 0, c1: 0, nano: 0, unp: 0, models: {} };
[inputs] as $all
| ( $all | map(select(.meta.parent == null) | { key: .meta.session, value: toplevel_class(.) }) | from_entries ) as $top
| ( [ $all[] | . as $s | $s.meta.parent as $par
      | ( if $par == null then toplevel_class($s)
          elif ($s.meta.agent_type | IN("judge", "judge-ro")) then "judge"
          elif $s.meta.agent_type == "brief-drafter" then "brief-drafter"
          else "subagent" end ) as $class
      | ( if $class | IN("chief", "brief-drafter") then "chief-turns"
          elif $class == "judge" then "judge"
          elif $class | IN("critic", "release-mgr", "graph-eval", "bots") then $class
          elif $class == "subagent" then (if $top[$par] == "chief" then "chief-turns" else "agent" end)
          else null end ) as $whole
      | $s.agg | to_entries[] | (.key | split("|")) as $kp
      | { day: $kp[0], session: $s.meta.session, parent: $par, class: $class, phase: ($whole // $kp[1]), whole: ($whole != null), v: .value } ]
    | group_by([.day, .session, .phase])
    | map( . as $g | $g[0] as $h
        | ( reduce $g[].v as $v (zero;
              reduce ("calls", "i", "o", "cr", "c5", "c1", "nano", "unp") as $f (.; .[$f] += $v[$f])
              | .models += ($v.models)) ) as $t
        | ( $t.models | keys ) as $ms
        | { kind: "phase-cost", day: $h.day, session: $h.session, parent: $h.parent,
            lane: (if ($ms | all(startswith("claude-"))) then "claude" elif ($ms | all(startswith("gpt-"))) then "codex" else "other" end),
            class: $h.class, model: ($ms | join(",")), phase: $h.phase, phase_rule: "v1",
            calls: $t.calls, in: $t.i, out: $t.o, cache_read: $t.cr, cc_5m: $t.c5, cc_1h: $t.c1,
            usd: (if $t.unp == $t.calls then null else ($t.nano / 1000000000) end),
            mark: (if $t.unp > 0 then "unpriced" elif $h.whole then "counted" else "derived" end) } ) ) as $rows
| ( $rows | map({ key: "\(.day)|\(.session)|\(.phase)", value: . }) | from_entries ) as $now
| $em[0] as $prev
# a key emitted before and gone now (a class change moved it, or a corrected message left it empty) is closed with a zero row
| ( $prev | to_entries | map(select(($now[.key]) == null) | (.value | fromjson) | select(.calls != 0)
      | .calls = 0 | .in = 0 | .out = 0 | .cache_read = 0 | .cc_5m = 0 | .cc_1h = 0 | .usd = (if .usd == null then null else 0 end)) ) as $closed
| ( ($rows + $closed) | map(select(($prev["\(.day)|\(.session)|\(.phase)"]) != tojson)) ) as $changed
| { rows: $changed, emitted: ($prev + ($changed | map({ key: "\(.day)|\(.session)|\(.phase)", value: tojson }) | from_entries)) }'

if [ "$PRINT" = 1 ]; then PSTATE="$WORK/phase-state"; else PSTATE="$STORE/phase-cost-state"; fi
mkdir -p "$PSTATE" "$WORK/pnew"
[ -f "$PSTATE/emitted.json" ] || echo '{}' > "$PSTATE/emitted.json"
PHASE_FILTER='"type":"(assistant|custom-title|ai-title)"|"subtype":"compact_boundary"|"isCompactSummary":true'
for f in "$PROJECTS"/*/*.jsonl "$PROJECTS"/*/*/subagents/*.jsonl; do
  [ -f "$f" ] || continue
  rel="${f#"$PROJECTS"/}"; key="${rel//[^A-Za-z0-9._-]/_}"
  # the byte offset lives inside the state file, so the totals and the offset they cover move together
  st=null; [ ! -f "$PSTATE/$key.json" ] || st="$(<"$PSTATE/$key.json")"
  off=0; [ "$st" = null ] || off="$(jq -r '.off // 0' <<<"$st")"
  size="$(wc -c < "$f" | tr -d ' ')"
  if [ "$size" -lt "$off" ]; then off=0; st=null; fi   # shrunk: the file was replaced, read it again
  [ "$size" -gt "$off" ] || continue
  tail -c +"$((off + 1))" "$f" | head -c "$((size - off))" > "$WORK/chunk"
  consumed=$((size - off))
  # a last line with no newline is still being written: leave it for the next run
  if [ -n "$(tail -c 1 "$WORK/chunk")" ]; then consumed=$((consumed - $(tail -n 1 "$WORK/chunk" | wc -c | tr -d ' '))); fi
  [ "$consumed" -gt 0 ] || continue
  stem="$(basename "$f" .jsonl)"; par=""; atype=""
  if [ "$(basename "$(dirname "$f")")" = subagents ]; then
    par="$(basename "$(dirname "$(dirname "$f")")")"
    [ ! -f "${f%.jsonl}.meta.json" ] || atype="$(jq -r '.agentType // ""' "${f%.jsonl}.meta.json" 2>/dev/null || true)"
  fi
  meta="$(jq -nc --arg s "$stem" --arg p "$par" --arg a "$atype" '{session: $s, parent: (if $p == "" then null else $p end), agent_type: $a}')"
  fp=""
  if [ "$(jq -r '.fp // ""' <<<"$st")" = "" ]; then
    fp="$(grep -a -m1 '"type":"user"' "$f" | jq -r 'select(.type == "user") | (.message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | first // "") end) as $t
      | if ($t | startswith("Read ./review-prompt.md")) then "critic" elif ($t | startswith("You are the release manager")) then "release-mgr" else "none" end' 2>/dev/null || true)"
  fi
  { head -c "$consumed" "$WORK/chunk" | { grep -a -E "$PHASE_FILTER" || true; } \
      | jq -nRc --argjson st "$st" --argjson prices "$PRICES" --argjson meta "$meta" --arg fp "$fp" --argjson off "$((off + consumed))" "$PHASE_FILE_JQ"; } \
    > "$WORK/pnew/$key.json" || die "phase-cost pass failed on $f"
done
rm -f "$WORK/chunk"
# every saved state (the new one where this run made one), then the rows that changed
: > "$WORK/pall.jsonl"
for p in "$WORK/pnew"/*.json; do [ ! -f "$p" ] || { cat "$p"; echo; } >> "$WORK/pall.jsonl"; done
for p in "$PSTATE"/*.json; do
  [ -f "$p" ] || continue
  [ "$(basename "$p")" != emitted.json ] || continue
  [ ! -f "$WORK/pnew/$(basename "$p")" ] || continue
  { cat "$p"; echo; } >> "$WORK/pall.jsonl"
done
jq -nc --slurpfile em "$PSTATE/emitted.json" "$PHASE_EMIT_JQ" "$WORK/pall.jsonl" > "$WORK/phase-out.json" \
  || die "cannot build the phase-cost rows"
jq -c '.rows[]' "$WORK/phase-out.json" > "$WORK/phase-rows.jsonl"
jq -c '.emitted' "$WORK/phase-out.json" > "$WORK/phase-emitted.json"

if [ "$PRINT" = 1 ]; then
  cat "$WORK/records.jsonl" "$WORK/phase-rows.jsonl"
  exit 0
fi

# --- append-only store: add a line only when the ticket's digest changed ----
mkdir -p "$STORE"
FILE="$STORE/records.jsonl"
touch "$FILE"
added=0; kept=0
while IFS= read -r line; do
  t="$(printf '%s' "$line" | jq -r .ticket)"
  d="$(printf '%s' "$line" | jq -r .digest)"
  last="$(jq -r --arg t "$t" 'select(.ticket == $t) | .digest' "$FILE" | tail -n 1)"
  if [ "$last" = "$d" ]; then kept=$((kept + 1)); else printf '%s\n' "$line" >> "$FILE"; added=$((added + 1)); fi
done < "$WORK/records.jsonl"
# phase-cost rows: append, then keep the offsets and the emitted map that produced them (still under the lock)
phase_added="$(wc -l < "$WORK/phase-rows.jsonl" | tr -d ' ')"
cat "$WORK/phase-rows.jsonl" >> "$FILE"
# copy into the store first, then rename within it: a state file is replaced whole or not at all
for p in "$WORK/pnew"/*.json "$WORK/phase-emitted.json"; do
  [ -f "$p" ] || continue
  name="$(basename "$p")"; [ "$name" != phase-emitted.json ] || name=emitted.json
  cp "$p" "$PSTATE/.$name.new" || die "cannot save phase-cost state $name"
  mv "$PSTATE/.$name.new" "$PSTATE/$name" || die "cannot save phase-cost state $name"
done
echo "usage-compute: appended $added, unchanged $kept, phase-cost rows $phase_added ($FILE)"
