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
#                    [--budget-seconds <n>] [--max-windows <n>] [--print]
#
# It also appends `phase-cost` rows (one per day, session and phase, see
# docs/internals/usage-records.md); those ignore --since and the ticket selectors.
#
# The build runs in windows: the sessions (a top-level transcript with its
# subagents) whose files changed since the last run, grouped by the local day of
# their newest file, newest day first. Each window appends its phase-cost rows and
# moves <store>/build-checkpoint.json in one commit; the ticket records follow
# when no window is left, so a reader never sees a ticket's partial total. A run
# starts no new window once --budget-seconds (default 240, 0 = no bound) have
# passed or --max-windows windows are done, and a run that is stopped or killed
# resumes at the first window it did not commit. --print and --repo run one
# window over everything that changed (--repo keeps its all-or-nothing join).
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
BUDGET=240
MAXWIN=0

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
    --budget-seconds) need_val "$@"; BUDGET="$2"; shift 2 ;;
    --max-windows)    need_val "$@"; MAXWIN="$2"; shift 2 ;;
    --print)    PRINT=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$BUDGET" =~ ^[0-9]+$ ]] || die "--budget-seconds must be a whole number of seconds (0 = no bound): $BUDGET"
[[ "$MAXWIN" =~ ^[0-9]+$ ]] || die "--max-windows must be a whole number (0 = no limit): $MAXWIN"

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
PROJECTS="$(cd "$PROJECTS" && pwd)" || die "cannot enter $PROJECTS"

# Serialize the whole compute-then-append (mkdir is atomic), so an older
# snapshot can never publish after a newer one. --print touches no store.
if [ "$PRINT" != 1 ]; then
  mkdir -p "$STORE"
  LOCK="$STORE/.lock"; n=0
  # USAGE_COMPUTE_TEST_LOCK_TRIES is a TEST SEAM: fewer half-second tries, so a suite row reads the refusal without waiting 300 s
  tries="${USAGE_COMPUTE_TEST_LOCK_TRIES:-600}"
  # prim-ok: readers share this directory lock; preserve the 300-second writer deadline instead of with_lock's blocking file protocol.
  until mkdir "$LOCK" 2>/dev/null; do
    n=$((n + 1))
    if [ "$n" -ge "$tries" ]; then
      owner="owner unknown"; op="$(cat "$LOCK/pid" 2>/dev/null || true)"
      if [[ "$op" =~ ^[0-9]+$ ]]; then
        if ps -p "$op" >/dev/null 2>&1; then owner="owner pid $op, running"; else owner="owner pid $op, not running"; fi
      fi
      die "store locked: $LOCK ($owner; remove it with rm -r if no run is active)"
    fi
    sleep 0.5
  done
  echo "$$" > "$LOCK/pid"
  trap 'rm -f "$LOCK/pid"; rmdir "$LOCK" 2>/dev/null; rm -rf "$WORK"' EXIT
fi
# a signal exits through the EXIT trap, so the lock never outlives the run
trap 'exit 130' INT TERM HUP

# TEST SEAM: inert unless USAGE_COMPUTE_TEST_PAUSE_AT names this point (window:<k> after the k-th window is committed,
# file:<n> after the n-th transcript's phase state is saved) and USAGE_COMPUTE_TEST_PAUSE_FILE is set: it creates
# <file>.reached and waits (about 30 s at most) while <file> exists, so a suite row can kill the run at that point.
test_pause() {
  [ "${USAGE_COMPUTE_TEST_PAUSE_AT:-}" = "$1" ] || return 0
  local f="${USAGE_COMPUTE_TEST_PAUSE_FILE:-}" i=0
  [ -n "$f" ] || return 0
  : > "$f.reached"
  while [ -e "$f" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
  return 0
}

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
build_tickets() {
  jq -r '[.units[].rows[]] | join("\n")' "$1" > "$WORK/bank.md"
  jq -n -S --rawfile table "$WORK/bank.md" --slurpfile ledger "$WORK/ledger.jsonl" --argjson sel "$SEL" \
    "$BASE_PROGRAM" > "$WORK/base.json"
  if [ -n "$TICKETS" ] && [ "$(jq '[.[] | select(.ticket | startswith("_") | not)] | length' "$WORK/base.json")" = 0 ]; then die "--tickets matched no session or CR row: $TICKETS"; fi
  jq -cS '.[]' "$WORK/base.json" > "$WORK/recs.jsonl"
  : > "$WORK/recs2.jsonl"; : > "$WORK/digests"
  local t rec
  while IFS= read -r rec <&4; do
    if [ -n "$REPO" ]; then
      t="$(jq -r .ticket <<<"$rec")"
      if [ "${t#_}" = "$t" ]; then
        join_ticket "$t"
        rec="$(printf '%s' "$rec" | jq -cS --argjson pr "$PRJ" --argjson ci "$CIJ" '. + {pr: $pr, ci: $ci}')"
      fi
    fi
    printf '%s\n' "$rec" >> "$WORK/recs2.jsonl"
    if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$rec" | sha256sum | cut -d' ' -f1 >> "$WORK/digests"
    else printf '%s' "$rec" | shasum -a 256 | cut -d' ' -f1 >> "$WORK/digests"; fi
  done 4< "$WORK/recs.jsonl"
  # shellcheck disable=SC2016  # jq's own $vars
  jq -cS -n --rawfile d "$WORK/digests" '($d | split("\n")) as $ds | foreach inputs as $r (-1; . + 1; $r + {digest: $ds[.]})' \
    "$WORK/recs2.jsonl" > "$WORK/records.jsonl" || die "cannot attach the record digests"
}

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
def add($key; $c):
  .agg[$key] = (reduce ("calls", "i", "o", "cr", "c5", "c1", "nano", "unp") as $f
      (.agg[$key] // { calls: 0, i: 0, o: 0, cr: 0, c5: 0, c1: 0, nano: 0, unp: 0, models: {} }; .[$f] += $c[$f]))
  | .agg[$key].models = (reduce ($c.models | to_entries[]) as $e (.agg[$key].models; .[$e.key] = ((.[$e.key] // 0) + $e.value)));
def tclass($t): if ($t | test("chief|console"; "i")) then "chief" elif ($t | test("-N[0-9]+|^HIMMEL-[0-9]+")) then "worker" else "other" end;
# a message id seen anywhere earlier in the file is the same call (its rows repeat the usage): counted once, first row wins
def step($r):
  ($r.message.id // $r.requestId) as $id
  | if $id != null and .seen[$id] != null then .
    else ((try day($r.timestamp // "") catch "unknown") + "|" + .last) as $key
      | contrib($r.message.model; $r.message.usage) as $c
      | add($key; $c) | (if $id != null then .seen[$id] = 1 else . end)
    end
  | (lasttool($r.message.content)) as $lt | if $lt != null then .last = $lt else . end;
( $st[0] // { off: 0, last: "boot", seen: {}, agg: {}, tc: null, ac: null, fp: null } ) as $st0
| reduce (inputs | fromjson? | select(type == "object")) as $r ($st0;
    if $r.type == "assistant" and ($r.message | type) == "object" and $r.message.usage
       and (($r.message.model // "") | startswith("<") | not) then step($r)
    elif ($r.type == "system" and $r.subtype == "compact_boundary") or $r.isCompactSummary == true then .last = "compaction"
    elif $r.type == "custom-title" and ($r.customTitle | type) == "string" then .tc = tclass($r.customTitle)
    elif $r.type == "ai-title" and ($r.aiTitle | type) == "string" then .ac = tclass($r.aiTitle)
    else . end)
| .off = $off | .meta = $meta | .fp = (if .fp == null and $fp != "" then $fp else .fp end)'

# shellcheck disable=SC2016  # jq's own $vars
PHASE_EMIT_JQ='
def toplevel_class($s):
  if $s.fp == "critic" then "critic" elif $s.fp == "release-mgr" then "release-mgr" else ($s.tc // $s.ac // "other") end;
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

if [ "$PRINT" = 1 ]; then CK="$WORK/ck"; PSTATE="$WORK/phase-state"; else CK="$STORE"; PSTATE="$STORE/phase-cost-state"; fi
EMDIR="$PSTATE/emitted"
CHECKPOINT="$CK/build-checkpoint.json"
FILE="$STORE/records.jsonl"
mkdir -p "$CK" "$EMDIR"
PHASE_FILTER='"type":"(assistant|custom-title|ai-title)"|"subtype":"compact_boundary"|"isCompactSummary":true'

put() {
  if ! cp "$1" "${2%/*}/.${2##*/}.new" || ! mv "${2%/*}/.${2##*/}.new" "$2"; then die "cannot save $2"; fi
}

apply_commit() {
  local c="$STORE/.commit" base cur len p
  base="$(cat "$c/base")"; [ -f "$FILE" ] || : > "$FILE"
  cur="$(wc -c < "$FILE" | tr -d ' ')"; len="$(wc -c < "$c/append.jsonl" | tr -d ' ')"
  if [ "$cur" -lt "$base" ] || [ "$cur" -gt $((base + len)) ]; then
    die "$FILE is $cur bytes, outside the pending commit's $base + $len; refusing to apply $c"
  fi
  [ "$cur" -eq $((base + len)) ] || tail -c +$((cur - base + 1)) "$c/append.jsonl" >> "$FILE" || die "cannot append to $FILE"
  for p in "$c"/emitted/*.json; do [ ! -f "$p" ] || put "$p" "$EMDIR/${p##*/}"; done
  put "$c/checkpoint.json" "$CHECKPOINT"
  mv "$c" "$STORE/.commit.done" || die "cannot retire the applied commit $c"
  rm -rf "$STORE/.commit.done"
}
commit() {
  local s="$STORE/.commit.new" p
  if [ "$PRINT" = 1 ]; then
    cat "$WORK/append.jsonl" >> "$WORK/print.jsonl"
    for p in "$WORK/wem"/*.json; do [ ! -f "$p" ] || cp "$p" "$EMDIR/"; done
    cp "$WORK/ck-new.json" "$CHECKPOINT"; return 0
  fi
  rm -rf "$s"; mkdir -p "$s/emitted"
  cp "$WORK/append.jsonl" "$s/append.jsonl"; cp "$WORK/ck-new.json" "$s/checkpoint.json"
  for p in "$WORK/wem"/*.json; do [ ! -f "$p" ] || cp "$p" "$s/emitted/"; done
  if [ -f "$FILE" ]; then wc -c < "$FILE" | tr -d ' ' > "$s/base"; else echo 0 > "$s/base"; fi
  mv "$s" "$STORE/.commit" || die "cannot stage the window commit"
  apply_commit
}
if [ "$PRINT" != 1 ]; then
  rm -rf "$STORE/.commit.new" "$STORE/.commit.done"
  if [ -d "$STORE/.commit" ]; then apply_commit; echo "usage-compute: note: applied the commit a stopped run left" >&2; fi
fi

if [ -f "$CHECKPOINT" ]; then cp "$CHECKPOINT" "$WORK/ck-in.json"; else echo '{"schema":1,"since":"","units":{}}' > "$WORK/ck-in.json"; fi
jq -c --arg s "$SINCE" 'if .since != $s then {schema: 1, since: $s, units: {}} else . end' "$WORK/ck-in.json" > "$WORK/ck-tmp.json" \
  || die "cannot read the checkpoint $CHECKPOINT"
mv "$WORK/ck-tmp.json" "$WORK/ck-in.json"

shopt -s nullglob
TFILES=("$PROJECTS"/*/*.jsonl "$PROJECTS"/*/*/subagents/*.jsonl)
shopt -u nullglob
: > "$WORK/inv.txt"
if [ "${#TFILES[@]}" -gt 0 ]; then
  if stat -L -c '%s' / >/dev/null 2>&1; then SFMT=(-L -c '%s %Y %n'); else SFMT=(-L -f '%z %m %N'); fi
  printf '%s\0' "${TFILES[@]}" | xargs -0 stat "${SFMT[@]}" > "$WORK/inv.txt" || die "cannot read the transcripts' sizes"
fi
# shellcheck disable=SC2016  # jq's own $vars
jq -nRc --slurpfile ck "$WORK/ck-in.json" --arg root "$PROJECTS" --argjson single "$([ "$PRINT" = 1 ] || [ -n "$REPO" ] && echo true || echo false)" '
def ukey: if test("^[A-Za-z0-9.-][A-Za-z0-9._-]{0,99}$") then . else null end;
[ inputs | capture("^(?<s>[0-9]+) (?<m>[0-9]+) (?<p>.*)$")
  | (.p | ltrimstr($root + "/")) as $rel | ($rel | split("/")) as $c
  | { rel: $rel, size: (.s | tonumber), m: (.m | tonumber), slug: $c[0],
      sub: (($c | length) == 4), unit: (if ($c | length) == 4 then $c[1] else ($c[1] | sub("\\.jsonl$"; "")) end) } ]
| group_by(.unit)
| map( . as $fs | ($fs | map(.slug) | unique) as $slugs
    | { unit: $fs[0].unit, ukey: ($fs[0].unit | ukey), fp: "\($fs | length):\($fs | map(.size) | add)",
        day: ($fs | map(.m) | max | localtime | strftime("%Y-%m-%d")),
        files: ($fs | sort_by(.rel) | map(. as $f | { rel, sub, j: ($slugs | index($f.slug)) })) } ) as $units
| ($ck[0].units) as $done
| [ $units[] | select($done[.unit].fp != .fp) ] as $dirty
| (($done | keys) - ($units | map(.unit))) as $gone
| ( if $single then [ { day: "all", units: ($dirty | sort_by(.unit)) } | select((.units | length) > 0) ]
    else ($dirty | group_by(.day) | reverse | map({ day: .[0].day, units: sort_by(.unit) })) end ) as $wins
| ( if ($wins | length) == 0 and ($gone | length) > 0 then [ { day: "removed", units: [] } ] else $wins end )
| to_entries[] | .value + { gone: (if .key == 0 then $gone else [] end) }' "$WORK/inv.txt" > "$WORK/windows.jsonl" \
  || die "cannot plan the windows"

added=0; kept=0; phase_added=0; nfile=0
: > "$WORK/print.jsonl"
build_window() {
  local win="$1" last="$2" day nu nread=0 rel f ck tl key st off size consumed stem par atype meta fp k j nrows
  day="$(jq -r .day <<<"$win")"; nu="$(jq '.units | length' <<<"$win")"
  jq -c '.units' <<<"$win" > "$WORK/wunits.json"; jq -c '.gone' <<<"$win" > "$WORK/wgone.json"
  if jq -e 'any(.[]; .ukey == null)' "$WORK/wunits.json" >/dev/null; then
    : > "$WORK/ukeys.tsv"
    while IFS= read -r k; do
      tl="${k//[^A-Za-z0-9._-]/_}"
      printf '%s\t_%s_%s\n' "$k" "$(printf '%s' "$k" | cksum | tr ' ' _)" "${tl: -60}" >> "$WORK/ukeys.tsv"
    done < <(jq -r '.[] | select(.ukey == null) | .unit' "$WORK/wunits.json")
    # shellcheck disable=SC2016  # jq's own $vars
    jq -c --rawfile m "$WORK/ukeys.tsv" '($m | split("\n") | map(select(length > 0) | split("\t") | { key: .[0], value: .[1] }) | from_entries) as $k
      | map(if .ukey == null then .ukey = $k[.unit] else . end)' "$WORK/wunits.json" > "$WORK/wunits.tmp" || die "cannot key the sessions in window $day"
    mv "$WORK/wunits.tmp" "$WORK/wunits.json"
  fi

  rm -rf "$WORK/shim"; mkdir -p "$WORK/shim"; : > "$WORK/wtable.md"
  if [ "$nu" -gt 0 ]; then
    jq -r 'to_entries[] | .key as $i | .value.unit as $u | .value.files[]
      | (.rel | split("/") | last) as $b
      | "u\($i)-\(.j)/\(if .sub then "\($u)/subagents/" else "" end)\($b)\t\(.rel)"' "$WORK/wunits.json" > "$WORK/shimlist"
    while IFS=$'\t' read -r k rel; do
      mkdir -p "$WORK/shim/${k%/*}"; ln -s "$PROJECTS/$rel" "$WORK/shim/$k"
    done < "$WORK/shimlist"
    BA_ARGS=("$WORK/shim")
    [ -z "$SINCE" ] || BA_ARGS+=(--since "$SINCE")
    bash "$BANK" "${BA_ARGS[@]}" > "$WORK/wtable.md" || die "bank-attribution failed in window $day (incomplete totals refused)"
  fi
  # shellcheck disable=SC2016  # jq's own $vars
  jq -n --rawfile table "$WORK/wtable.md" --slurpfile ck "$WORK/ck-in.json" --slurpfile wu "$WORK/wunits.json" \
    --slurpfile gone "$WORK/wgone.json" --arg day "$day" '
    $wu[0] as $units
    | ( [ $table | split("\n")[] | select(startswith("| ") and (startswith("| session |") | not) and (startswith("| **total") | not))
          | . as $l | (.[2:-2] | split(" | ")[1] | capture("^u(?<i>[0-9]+)-").i | tonumber) as $i | { u: $units[$i].unit, l: $l } ]
        | group_by(.u) | map({ key: .[0].u, value: map(.l) }) | from_entries ) as $rows
    | $ck[0]
    | .units = ((.units | delpaths([ $gone[0][] | [.] ])) + ($units | map({ key: .unit, value: { fp: .fp, rows: ($rows[.unit] // []) } }) | from_entries))
    | if $day == "none" then . else .last_window = $day end' > "$WORK/ck-new.json" || die "cannot update the checkpoint in window $day"

  : > "$WORK/wkeys"
  while IFS= read -r rel; do
    f="$PROJECTS/$rel"
    [ -f "$f" ] || continue
    # the state file name is a checksum of the whole path plus a readable tail, so a long path cannot exceed a file-name limit
    ck="$(printf '%s' "$rel" | cksum | tr ' ' _)"; tl="${rel//[^A-Za-z0-9._-]/_}"; key="${ck}_${tl: -60}"
    echo "$key" >> "$WORK/wkeys"
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
    printf '%s' "$st" > "$WORK/st.json"
    if [ "$(jq -r '.fp // ""' "$WORK/st.json")" = "" ]; then
      fp="$(grep -a -m1 '"type":"user"' "$f" | jq -r 'select(.type == "user") | (.message.content | if type == "string" then . else ([.[]? | select(.type == "text") | .text] | first // "") end) as $t
        | if ($t | startswith("Read ./review-prompt.md")) then "critic" elif ($t | startswith("You are the release manager")) then "release-mgr" else "none" end' 2>/dev/null || true)"
    fi
    { head -c "$consumed" "$WORK/chunk" | { grep -a -E "$PHASE_FILTER" || true; } \
        | jq -nRc --slurpfile st "$WORK/st.json" --argjson prices "$PRICES" --argjson meta "$meta" --arg fp "$fp" --argjson off "$((off + consumed))" "$PHASE_FILE_JQ"; } \
      > "$WORK/pnew.json" || die "phase-cost pass failed on $f"
    put "$WORK/pnew.json" "$PSTATE/$key.json"
    nread=$((nread + 1)); nfile=$((nfile + 1))
    test_pause "file:$nfile"
  done < <(jq -r '.[].files[].rel' "$WORK/wunits.json")
  rm -f "$WORK/chunk"

  : > "$WORK/pall.jsonl"
  while IFS= read -r key; do [ ! -f "$PSTATE/$key.json" ] || { cat "$PSTATE/$key.json"; echo; } >> "$WORK/pall.jsonl"; done < "$WORK/wkeys"
  : > "$WORK/em-parts"
  while IFS= read -r k; do [ ! -f "$EMDIR/$k.json" ] || cat "$EMDIR/$k.json" >> "$WORK/em-parts"; done < <(jq -r '.[].ukey' "$WORK/wunits.json")
  jq -sc 'add // {}' "$WORK/em-parts" > "$WORK/em.json" || die "cannot read the emitted maps in window $day"
  jq -nc --slurpfile em "$WORK/em.json" "$PHASE_EMIT_JQ" "$WORK/pall.jsonl" > "$WORK/phase-out.json" \
    || die "cannot build the phase-cost rows in window $day"
  jq -c '.rows[]' "$WORK/phase-out.json" > "$WORK/wrows.jsonl"
  rm -rf "$WORK/wem"; mkdir "$WORK/wem"
  # shellcheck disable=SC2016  # jq's own $vars
  jq -r --slurpfile wu "$WORK/wunits.json" '($wu[0] | map({ key: .unit, value: .ukey }) | from_entries) as $uk
    | .emitted | to_entries | group_by(.value | fromjson | (.parent // .session))[]
    | (.[0].value | fromjson | (.parent // .session)) as $u
    | if $uk[$u] == null then error("an emitted row outside the window: \($u)") else "\($uk[$u])\t\(from_entries | tojson)" end' \
    "$WORK/phase-out.json" > "$WORK/wem.tsv" || die "cannot split the emitted map in window $day"
  while IFS=$'\t' read -r k j; do printf '%s\n' "$j" > "$WORK/wem/$k.json"; done < "$WORK/wem.tsv"

  : > "$WORK/tappend.jsonl"
  if [ "$last" = 1 ]; then
    build_tickets "$WORK/ck-new.json"
    if [ "$PRINT" = 1 ]; then
      cp "$WORK/records.jsonl" "$WORK/tappend.jsonl"
    else
      if [ -f "$FILE" ]; then
        jq -n 'reduce (inputs | select(.ticket != null and .digest != null)) as $r ({}; .[$r.ticket] = $r.digest)' "$FILE" > "$WORK/last.json" \
          || die "cannot read the stored digests in $FILE"
      else echo '{}' > "$WORK/last.json"; fi
      jq -c --slurpfile last "$WORK/last.json" 'select($last[0][.ticket] != .digest)' "$WORK/records.jsonl" > "$WORK/tappend.jsonl"
      j="$(wc -l < "$WORK/tappend.jsonl" | tr -d ' ')"
      added=$((added + j)); kept=$((kept + $(wc -l < "$WORK/records.jsonl" | tr -d ' ') - j))
    fi
  fi
  cat "$WORK/tappend.jsonl" "$WORK/wrows.jsonl" > "$WORK/append.jsonl"
  commit
  cp "$WORK/ck-new.json" "$WORK/ck-in.json"
  nrows="$(wc -l < "$WORK/wrows.jsonl" | tr -d ' ')"; phase_added=$((phase_added + nrows))
  [ "$day" = none ] || echo "usage-compute: window $day done: $nu sessions, $nread transcripts read, $nrows phase rows" >&2
}

W="$(wc -l < "$WORK/windows.jsonl" | tr -d ' ')"
echo "usage-compute: $W window(s) to build" >&2
k=0; stop=""
while IFS= read -r win <&3; do
  if [ "$k" -gt 0 ]; then
    if [ "$MAXWIN" -gt 0 ] && [ "$k" -ge "$MAXWIN" ]; then stop="window limit"; break; fi
    if [ "$BUDGET" -gt 0 ] && [ "$SECONDS" -ge "$BUDGET" ]; then stop="budget of ${BUDGET}s"; break; fi
  fi
  k=$((k + 1))
  build_window "$win" "$([ "$k" -eq "$W" ] && echo 1 || echo 0)"
  test_pause "window:$k"
done 3< "$WORK/windows.jsonl"
[ "$W" != 0 ] || build_window '{"day":"none","units":[],"gone":[]}' 1

if [ "$PRINT" = 1 ]; then
  cat "$WORK/print.jsonl"
  exit 0
fi
[ -z "$stop" ] || echo "usage-compute: stopped by the $stop after $k window(s), $((W - k)) window(s) remain; rerun to continue" >&2
echo "usage-compute: appended $added, unchanged $kept, phase-cost rows $phase_added ($FILE)"
