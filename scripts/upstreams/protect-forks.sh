#!/usr/bin/env bash
# scripts/upstreams/protect-forks.sh — protect the default and himmel branch of
# every live fork we own.
#
# Usage: protect-forks.sh [--apply] [--only <owner/repo>]
#   --only limits the run to one registered fork (apply one fork first, then the rest).
#
# Default mode is a DRY-RUN: it reads (GET only) each fork's repo settings and
# rulesets, then prints per fork the exact write calls it would make
# (`CALL <METHOD> <endpoint> <json>`) and the read-back it would run
# (`READBACK GET <endpoint>`). It never writes.
#
# --apply performs those calls, then re-reads and verifies. It refuses (rc 3,
# before any gh call) unless HIMMEL_FORK_PROTECT_RULING is set to the chief's
# ruling reference (8+ characters of [A-Za-z0-9._:-]; the chief names it when it
# rules on applying the plan). Nobody else sets it.
#
# What it applies, per live fork, one repository ruleset `himmel-fork-protect`:
#   - target: the fork's default branch and the registry's himmel_branch
#   - rules: deletion, non_fast_forward, pull_request (0 required approvals,
#     review threads resolved, squash only)
#   - bypass: the repository admin role, mode always. The actor is the operator
#     account (yotamleo, the only org admin), which runs resync-fork.sh --sync
#     (`git push --force-with-lease` to the himmel branch, `gh repo sync` of the
#     default branch) and merge-fork-pr.sh. Approvals stay at 0 because
#     go_fork_ready needs mergeStateStatus CLEAN and the one account cannot
#     approve its own PR; the chief GO and the trust judge are the review.
# plus the repository setting pull_request_creation_policy=collaborators_only.
#
# Idempotent: a fork whose ruleset already carries the wanted rules and whose
# policy is already collaborators_only gets no CALL lines. Skipped: archived
# forks (GitHub already makes them read-only) and any registry row that is not
# a fork (himmel-voice). An org fork with no registry row is named UNREGISTERED.
#
# Seams: GH (gh binary), PROTECT_FORKS_ADAPTERS (registry path),
# PROTECT_FORKS_ORG (default yotamleo-org).
#
# Exit codes: 0 done | 1 a read, write or verification failed, the org fork list
# could not be read, or --only named no registry row | 2 usage, jq missing, or the
# registry unreadable, empty or not an array | 3 --apply refused (before any gh call)
set -uo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ADAPTERS="${PROTECT_FORKS_ADAPTERS:-$SELF_DIR/../guardrails/himmel-adapters.json}"
ORG="${PROTECT_FORKS_ORG:-yotamleo-org}"
GH="${GH:-gh}"
RULESET_NAME="himmel-fork-protect"

APPLY=0
ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --only) [ "$#" -ge 2 ] || { echo "usage: protect-forks.sh [--apply] [--only <owner/repo>]" >&2; exit 2; }
            ONLY=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]'); shift 2 ;;
    *) echo "usage: protect-forks.sh [--apply] [--only <owner/repo>]" >&2; exit 2 ;;
  esac
done

if [ "$APPLY" = 1 ]; then
  case "${HIMMEL_FORK_PROTECT_RULING:-}" in
    *[!A-Za-z0-9._:-]*|"") proof_ok=0 ;;
    *) if [ "${#HIMMEL_FORK_PROTECT_RULING}" -ge 8 ]; then proof_ok=1; else proof_ok=0; fi ;;
  esac
  if [ "$proof_ok" != 1 ]; then
    echo "protect-forks: --apply refused - HIMMEL_FORK_PROTECT_RULING must carry the chief's ruling reference. Nothing called." >&2
    exit 3
  fi
fi
command -v jq >/dev/null 2>&1 || { echo "protect-forks: jq is required" >&2; exit 2; }
[ -r "$ADAPTERS" ] || { echo "protect-forks: cannot read $ADAPTERS" >&2; exit 2; }

rc=0
POLICY_PAYLOAD='{"pull_request_creation_policy":"collaborators_only"}'

# ruleset_payload <default-branch> <himmel-branch>
ruleset_payload() {
  jq -cn --arg name "$RULESET_NAME" --arg d "$1" --arg h "$2" '
    (if $d == $h then [$d] else [$d, $h] end | map("refs/heads/" + .)) as $refs
    | {name: $name, target: "branch", enforcement: "active",
       bypass_actors: [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}],
       conditions: {ref_name: {include: $refs, exclude: []}},
       rules: [{type: "deletion"}, {type: "non_fast_forward"},
               {type: "pull_request", parameters: {
                  required_approving_review_count: 0, dismiss_stale_reviews_on_push: false,
                  require_code_owner_review: false, require_last_push_approval: false,
                  required_review_thread_resolution: true, allowed_merge_methods: ["squash"]}}]}'
}

# write <METHOD> <endpoint> <json>: the one place a write is made
write() {
  printf '%s' "$3" | "$GH" api -X "$1" "$2" --input - >/dev/null
}

# state <nwo> <payload>: sets RS_ID ("" when absent), RS_SAME (1 when the live ruleset carries the payload), POLICY_SAME
state() {
  local nwo="$1" payload="$2" list detail repo
  RS_ID=""; RS_SAME=0; POLICY_SAME=0
  list=$("$GH" api "repos/$nwo/rulesets") || return 1
  RS_ID=$(printf '%s' "$list" | jq -r --arg n "$RULESET_NAME" '[.[] | select(.name == $n) | .id][0] // empty') || return 1
  if [ -n "$RS_ID" ]; then
    detail=$("$GH" api "repos/$nwo/rulesets/$RS_ID") || return 1
    # structural compare (jq contains() matches strings by substring): the same refs, bypass actors and
    # rule types, and every pull_request parameter we set carries our value (GitHub adds its own defaults)
    if printf '%s' "$detail" | jq -e --argjson w "$payload" '
         def norm: {enforcement, target,
                    include: (.conditions.ref_name.include | sort),
                    exclude: ((.conditions.ref_name.exclude // []) | sort),
                    bypass: ([.bypass_actors[]? | {actor_id, actor_type, bypass_mode}] | sort_by(.actor_id)),
                    types: ([.rules[].type] | sort)};
         def prp: ([.rules[] | select(.type == "pull_request") | .parameters // {}][0] // {})
                  | if has("allowed_merge_methods") then .allowed_merge_methods |= sort else . end;
         (norm == ($w | norm))
         and ((prp) as $ep | ($w | prp) as $wp | ($wp | keys | all(. as $k | $ep[$k] == $wp[$k])))' >/dev/null; then RS_SAME=1; fi
  fi
  repo=$("$GH" api "repos/$nwo") || return 1
  [ "$(printf '%s' "$repo" | jq -r '.pull_request_creation_policy // ""')" = collaborators_only ] && POLICY_SAME=1
  return 0
}

rows=$(jq -r 'if (type == "array" and length > 0) then .[] | [.nwo, .himmel_branch] | @tsv else error("empty or not an array") end' "$ADAPTERS") \
  || { echo "protect-forks: $ADAPTERS is not a usable registry" >&2; exit 2; }
registered=""
matched=0
while IFS=$'\t' read -r nwo himmel; do
  [ -n "$nwo" ] || continue
  registered="$registered $(printf '%s' "$nwo" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$ONLY" ] && [ "$(printf '%s' "$nwo" | tr '[:upper:]' '[:lower:]')" != "$ONLY" ]; then continue; fi
  matched=1
  if ! repo=$("$GH" api "repos/$nwo"); then echo "ERROR $nwo cannot read the repo"; rc=1; continue; fi
  if [ "$(printf '%s' "$repo" | jq -r '.fork')" != true ]; then echo "SKIP $nwo not-a-fork"; continue; fi
  if [ "$(printf '%s' "$repo" | jq -r '.archived')" = true ]; then echo "SKIP $nwo archived (read-only: no push, force push or new PR is possible)"; continue; fi
  def=$(printf '%s' "$repo" | jq -r '.default_branch')
  payload=$(ruleset_payload "$def" "$himmel")
  if ! state "$nwo" "$payload"; then echo "ERROR $nwo cannot read rulesets"; rc=1; continue; fi
  echo "== $nwo (default $def, himmel $himmel)"
  if [ "$RS_SAME" = 1 ] && [ "$POLICY_SAME" = 1 ]; then echo "OK $nwo already protected"; continue; fi
  if [ "$RS_SAME" = 0 ]; then
    if [ -z "$RS_ID" ]; then method=POST; ep="repos/$nwo/rulesets"; else method=PUT; ep="repos/$nwo/rulesets/$RS_ID"; fi
    echo "CALL $method $ep $payload"
    if [ "$APPLY" = 1 ] && ! write "$method" "$ep" "$payload"; then echo "ERROR $nwo $method failed"; rc=1; continue; fi
  fi
  if [ "$POLICY_SAME" = 0 ]; then
    echo "CALL PATCH repos/$nwo $POLICY_PAYLOAD"
    if [ "$APPLY" = 1 ] && ! write PATCH "repos/$nwo" "$POLICY_PAYLOAD"; then echo "ERROR $nwo PATCH failed"; rc=1; continue; fi
  fi
  echo "READBACK GET repos/$nwo/rulesets (expect $RULESET_NAME active: deletion, non_fast_forward, pull_request; bypass admin always)"
  echo "READBACK GET repos/$nwo (expect pull_request_creation_policy=collaborators_only)"
  for b in $(printf '%s' "$payload" | jq -r '.conditions.ref_name.include[] | sub("^refs/heads/"; "")'); do
    echo "READBACK GET repos/$nwo/rules/branches/$b (expect deletion, non_fast_forward, pull_request: a direct push, a force push and a delete are refused)"
  done
  if [ "$APPLY" = 1 ]; then
    if state "$nwo" "$payload" && [ "$RS_SAME" = 1 ] && [ "$POLICY_SAME" = 1 ]; then echo "VERIFIED $nwo"; else echo "ERROR $nwo read-back does not match"; rc=1; fi
  fi
done <<EOF
$rows
EOF

if [ -n "$ONLY" ]; then
  [ "$matched" = 1 ] || { echo "ERROR --only $ONLY matches no registry row"; exit 1; }
  exit "$rc"
fi
orgforks=$("$GH" api "orgs/$ORG/repos?type=forks&per_page=100" --paginate) || { echo "ERROR cannot list $ORG forks"; exit 1; }
for f in $(printf '%s' "$orgforks" | jq -r '.[].full_name'); do
  case " $registered " in
    *" $(printf '%s' "$f" | tr '[:upper:]' '[:lower:]') "*) ;;
    *) echo "UNREGISTERED $f (an org fork with no row in himmel-adapters.json: no plan made)" ;;
  esac
done
exit "$rc"
