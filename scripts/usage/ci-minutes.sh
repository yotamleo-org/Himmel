#!/usr/bin/env bash
# scripts/usage/ci-minutes.sh -- CI billed minutes per run, beside wall minutes.
# The one writer of <store>/ci-minutes.jsonl; one JSON row per Actions run,
# the run id is the idempotence key.
#
# Usage:
#   ci-minutes.sh write  --repo OWNER/NAME [--days N] [--until <iso>] [--store <dir>] [--gh <exe>]
#   ci-minutes.sh report --repo OWNER/NAME [--days N] [--until <iso>] [--store <dir>] [--gh <exe>]
#
# Source: GET /repos/{repo}/actions/runs?status=completed&created=<from>..<to>
# for the run list and wall time (run_started_at to updated_at), and
# GET /repos/{repo}/actions/runs/{id}/timing for billing: .billable.<OS>.total_ms,
# summed over every OS and stored as billed_min. A billing answer that is
# absent (HTTP 404/410, or no .billable entry) is stored as the string
# "unknown", never 0; an answer of 0 ms is a real 0. Any other gh failure
# (rate limit, auth, network) aborts the run; rows already written stay.
#
# The API returns at most 1,000 rows for a filtered window however large
# total_count is, so a window whose listing is short of total_count is halved
# until each half is complete; a single second that still holds more than it
# returns fails closed. Nothing is ever silently truncated.
#
# Platform guard: pure bash 3.2-safe + jq.
set -uo pipefail

die() { echo "ci-minutes: $*" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || die "jq is required"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
. "$HERE/../lib/prim.sh" || exit 1

MODE="${1:-}"
case "$MODE" in write|report) shift ;; *) die "usage: ci-minutes.sh write|report --repo OWNER/NAME [--days N] [--until <iso>] [--store <dir>] [--gh <exe>]" ;; esac

REPO=""; DAYS=7; UNTIL=""; GH="gh"
STORE="${HIMMEL_USAGE_STORE:-${HOME}/.himmel/state/usage}"
need_val() { [ -n "${2:-}" ] || die "$1 needs a non-empty value"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  need_val "$@"; REPO="$2"; shift 2 ;;
    --days)  need_val "$@"; DAYS="$2"; shift 2 ;;
    --until) need_val "$@"; UNTIL="$2"; shift 2 ;;
    --store) need_val "$@"; STORE="$2"; shift 2 ;;
    --gh)    need_val "$@"; GH="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] || die "--repo OWNER/NAME is required"
[[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "--repo must be OWNER/NAME: $REPO"
[[ "$DAYS" =~ ^[1-9][0-9]*$ ]] || die "--days must be a positive integer: $DAYS"
[ -n "$UNTIL" ] || UNTIL="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[[ "$UNTIL" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || die "--until must be YYYY-MM-DDTHH:MM:SSZ: $UNTIL"
command -v "$GH" >/dev/null 2>&1 || die "gh not found or not executable (one path, no arguments): $GH"

TO_E="$(jq -nr --arg u "$UNTIL" '$u | fromdateiso8601')" || die "--until is not a date: $UNTIL"
FROM_E=$((TO_E - DAYS * 86400))
iso() { jq -nr --argjson n "$1" '$n | todate'; }
FILE="$STORE/ci-minutes.jsonl"

WORK="$(tmpdir)"
trap 'rm -rf "$WORK"' EXIT

# gh api for one call, or die: auth, network, rate limit and a wrong repo land here
gh_api() {
  local out
  if ! out="$("$GH" api "$@" 2>"$WORK/gh.err")"; then
    die "gh api $1 failed: $(head -c 200 "$WORK/gh.err" | tr '\n' ' ')"
  fi
  printf '%s' "$out"
}

# --- report ------------------------------------------------------------------
if [ "$MODE" = report ]; then
  FROM_ISO="$(iso "$FROM_E")" || die "cannot format the window start"
  SRC="$FILE"; [ -f "$SRC" ] || { SRC="$WORK/empty"; : > "$SRC"; }
  total="unavailable"
  if t="$("$GH" api "repos/$REPO/actions/runs?status=completed&per_page=1&created=$FROM_ISO..$UNTIL" 2>/dev/null | jq -r '.total_count' 2>/dev/null)" && [[ "$t" =~ ^[0-9]+$ ]]; then total="$t"; fi
  jq -s -r --arg f "$FROM_ISO" --arg u "$UNTIL" --arg repo "$REPO" --arg total "$total" '
    [.[] | select(.repo == $repo and .created_at >= $f and .created_at <= $u)] as $r
    | ([$r[] | .billed_min | select(type == "number")] | add // 0) as $b
    | ([$r[].wall_min] | add // 0) as $w
    | "ci-minutes \($repo) \($f)..\($u)",
      "runs: \($r | length)  gh_total_count: \($total)",
      "minutes: billed=\($b) wall=\($w)",
      "billed_unknown_runs: \([$r[] | select(.billed_min == "unknown")] | length)"' "$SRC" || die "cannot read $FILE"
  exit 0
fi

# --- write -------------------------------------------------------------------
# list_window <from_epoch> <to_epoch>: append every run created in the window to
# $WORK/runs.jsonl, halving the window while the API listing is short of total_count
list_window() {
  local f="$1" t="$2" out tot n mid
  out="$(gh_api "repos/$REPO/actions/runs?status=completed&per_page=100&created=$(iso "$f")..$(iso "$t")" --paginate)" || exit 1
  printf '%s' "$out" | jq -es 'length > 0 and all(.[]; (.total_count | type == "number") and (.workflow_runs | type == "array"))' >/dev/null 2>&1 \
    || die "unexpected run listing shape for $(iso "$f")..$(iso "$t")"
  tot="$(printf '%s' "$out" | jq -s '.[0].total_count')"
  n="$(printf '%s' "$out" | jq -s '[.[].workflow_runs[].id] | unique | length')"
  if [ "$n" -lt "$tot" ]; then
    [ "$t" -gt "$f" ] && [ "$tot" -gt 1000 ] \
      || die "run listing is short of total_count ($n of $tot) for $(iso "$f")..$(iso "$t"); refusing a truncated window"
    mid=$(((f + t) / 2))
    list_window "$f" "$mid"
    list_window $((mid + 1)) "$t"
    return 0
  fi
  printf '%s' "$out" | jq -c '.workflow_runs[]
    | ((.updated_at | fromdateiso8601) - ((.run_started_at // .created_at) | fromdateiso8601)) as $w
    | if $w < 0 then error("negative wall time") else . end
    | {id, name, created_at, wall_secs: $w}' >> "$WORK/runs.jsonl" || die "cannot read the run listing"
}

: > "$WORK/runs.jsonl"
list_window "$FROM_E" "$TO_E"

mkdir -p "$STORE" || die "cannot create store $STORE"
LOCK="$STORE/.ci-minutes.lock"; n=0
# prim-ok: one short writer per store; a bounded mkdir wait beats with_lock's blocking file protocol here.
until mkdir "$LOCK" 2>/dev/null; do
  n=$((n + 1)); [ "$n" -lt 600 ] || die "store locked: $LOCK (remove it if no run is active)"
  sleep 0.5
done
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM HUP
touch "$FILE" || die "cannot write $FILE"

# new runs only: the run id is the idempotence key
jq -c -s --slurpfile old "$FILE" '
  ($old | map({key: (.run_id | tostring), value: true}) | from_entries) as $have
  | unique_by(.id) | .[] | select($have[.id | tostring] | not)' "$WORK/runs.jsonl" > "$WORK/new.jsonl" || die "cannot read $FILE"

added=0
while IFS= read -r r; do
  id="$(jq -r .id <<<"$r")" || die "unreadable run row"
  if timing="$("$GH" api "repos/$REPO/actions/runs/$id/timing" 2>"$WORK/gh.err")"; then
    jq -e 'type == "object"' <<<"$timing" >/dev/null 2>&1 || timing='{}'
  elif grep -qE 'HTTP (404|410)' "$WORK/gh.err"; then
    timing='{}'
  else
    die "gh api runs/$id/timing failed: $(head -c 200 "$WORK/gh.err" | tr '\n' ' ')"
  fi
  jq -nc --arg repo "$REPO" --argjson r "$r" --argjson t "$timing" '
    (try ([$t.billable[] | .total_ms] | if length > 0 and all(type == "number") then add else null end) catch null) as $ms
    | {schema: 1, repo: $repo, run_id: $r.id, workflow: $r.name, created_at: $r.created_at,
       wall_min: (($r.wall_secs / 60 * 100 | round) / 100),
       billed_min: (if $ms == null then "unknown" else (($ms / 60000 * 100 | round) / 100) end)}' >> "$FILE" || die "cannot append to $FILE"
  added=$((added + 1))
done < "$WORK/new.jsonl"
echo "ci-minutes: appended $added run(s), $(jq -s 'length' "$WORK/runs.jsonl") listed ($FILE)"
