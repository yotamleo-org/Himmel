# shellcheck shell=bash
# scripts/lib/outside-contributors.sh — sourced by ready-check item 16.
#
# outside_contributor_allowed <login> <node-id>
#   rc 0 only when $HOME/.himmel/outside-contributors.json is a JSON array
#   holding one object whose "login" AND "id" both equal the arguments (other
#   keys are ignored). A missing, malformed or empty list, or an empty argument,
#   is rc 1: missing data never lists anyone.
#
# outside_audit_passed <pr> <head> <branch>
#   rc 0 only when the CR ledger (under `git rev-parse --git-common-dir`) holds
#   no `security-audit` row with verdict fail for <pr> at <head> (any branch),
#   and the newest status-ok row for <pr>, <head> and <branch> has verdict pass
#   or flagged, a perspective_sha256 equal to the sha256 of the anchor's
#   scripts/cr/perspectives/outside-security.md, and a report file whose sha256
#   equals its report_sha256. Every unreadable input is rc 1.
#
# The anchor is the repo root two directories above this file. No environment
# variable overrides the list, the ledger or the anchor.

_oc_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi 2>/dev/null | cut -d' ' -f1
}

outside_contributor_allowed() {
  local login="${1:-}" id="${2:-}" list="$HOME/.himmel/outside-contributors.json"
  [ -n "$login" ] && [ -n "$id" ] && [ -r "$list" ] || return 1
  jq -e --arg l "$login" --arg i "$id" \
    'type == "array" and any(.[]; type == "object" and .login == $l and .id == $i)' "$list" >/dev/null 2>&1 || return 1
}

outside_audit_passed() {
  local pr="${1:-}" head="${2:-}" branch="${3:-}" anchor persp psha gcd ledger row report rsha
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "$branch" ] || return 1
  anchor=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  persp="$anchor/scripts/cr/perspectives/outside-security.md"
  [ -f "$persp" ] && [ -r "$persp" ] || return 1
  psha=$(_oc_sha256 "$persp")
  [[ "$psha" =~ ^[0-9a-f]{64}$ ]] || return 1
  gcd=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  ledger="$gcd/cr-critic-scores.jsonl"
  [ -r "$ledger" ] || return 1
  row=$(jq -nRr --argjson pr "$pr" --arg h "$head" --arg b "$branch" --arg ps "$psha" '
      [inputs | fromjson? | select(type == "object" and .kind == "security-audit")] as $r
      | if any($r[]; .pr == $pr and .head == $h and .verdict == "fail") then empty
        else ([$r[] | select(.pr == $pr and .head == $h and .branch == $b and .status == "ok")] | last)
          | select(. != null and .perspective_sha256 == $ps and (.verdict == "pass" or .verdict == "flagged")
                   and (.report | type == "string") and (.report_sha256 | type == "string"))
          | [.report, .report_sha256] | @tsv
        end' "$ledger" 2>/dev/null) || return 1
  [ -n "$row" ] || return 1
  report="${row%%$'\t'*}"; rsha="${row#*$'\t'}"
  [ -f "$report" ] && [ -r "$report" ] || return 1
  [ "$(_oc_sha256 "$report")" = "$rsha" ]
}

# outside_pr_authorize <pr> <head> <full-rounds-used>
#   rc 0 and prints `allowlist` or `approval:<message_id>` when an outside PR may
#   be reviewed from its diff at <head>; else rc 1 and prints nothing. The author
#   login, node id, head branch and head sha are read here, from ONE bounded
#   `timeout -k 5 20 gh pr view`; the caller cannot name any of them. A timeout, a
#   non-zero exit, junk output, a missing id or a forge head that differs from
#   <head> is rc 1. Allowed when the author is listed and used < 3, or when
#   $HOME/.himmel/outside-pr-approvals.jsonl holds a row naming <pr> and exactly
#   <head> with stage "review" and, for an unlisted author, an audit pass at <head>.
# outside_pr_merge_base <pr> <baseRefName>
#   fetches origin's base branch and prints its merge base with
#   refs/himmel/outside/<pr>; any failure is rc 1 and prints nothing.

outside_pr_authorize() {
  local pr="${1:-}" head="${2:-}" used="${3:-}" anchor f login id branch oid mid ap="$HOME/.himmel/outside-pr-approvals.jsonl"
  local -a ghc
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] && [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [[ "$used" =~ ^[0-9]+$ ]] || return 1
  anchor=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  # shellcheck source=timeout-bin.sh
  . "$anchor/scripts/lib/timeout-bin.sh" 2>/dev/null || return 1
  [ -n "${_TIMEOUT_BIN:-}" ] || return 1
  if [ -f "$anchor/scripts/lib/gh-read.sh" ]; then ghc=(bash "$anchor/scripts/lib/gh-read.sh"); else ghc=(gh); fi
  f=$("$_TIMEOUT_BIN" -k 5 20 "${ghc[@]}" pr view "$pr" --json author,headRefName,headRefOid 2>/dev/null \
    | jq -er 'select(type == "object") | [.author.login, .author.id, .headRefName, .headRefOid]
        | select(all(.[]; type == "string" and length > 0 and (test("[\t\n]") | not))) | @tsv' 2>/dev/null) || return 1
  IFS=$'\t' read -r login id branch oid <<< "$f"
  [ -n "$login" ] && [ -n "$id" ] && [ -n "$branch" ] && [ "$oid" = "$head" ] || return 1
  if [ "$used" -lt 3 ] && outside_contributor_allowed "$login" "$id"; then
    echo allowlist
    return 0
  fi
  [ -r "$ap" ] || return 1
  mid=$(jq -nRr --argjson pr "$pr" --arg h "$head" '
      [inputs | fromjson? | select(type == "object" and .pr == $pr and .head == $h and .stage == "review")]
      | last | select(. != null) | (.message_id | tostring)' "$ap" 2>/dev/null) || return 1
  [ -n "$mid" ] || return 1
  outside_contributor_allowed "$login" "$id" || outside_audit_passed "$pr" "$head" "$branch" || return 1
  echo "approval:$mid"
}

outside_pr_merge_base() {
  local pr="${1:-}" base="${2:-}" mb anchor
  [[ "$pr" =~ ^[1-9][0-9]*$ ]] && [ -n "$base" ] && git check-ref-format "refs/heads/$base" >/dev/null 2>&1 || return 1
  case "$base" in -*|*..*) return 1 ;; esac
  anchor=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  # shellcheck source=timeout-bin.sh
  . "$anchor/scripts/lib/timeout-bin.sh" 2>/dev/null || return 1
  [ -n "${_TIMEOUT_BIN:-}" ] || return 1
  "$_TIMEOUT_BIN" -k 5 60 git fetch -q origin "+refs/heads/$base:refs/remotes/origin/$base" >/dev/null 2>&1 || return 1
  mb=$(git merge-base "refs/remotes/origin/$base" "refs/himmel/outside/$pr" 2>/dev/null) || return 1
  [[ "$mb" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$mb"
}

# author_class and outside_pr_of: the item 16 predicate, shared by ready-check.sh and
# scripts/cr/pr-check-outside.sh. Both need ticket-id-internal.sh beside this file.

# author_class <login>: prints ticket_id_author_class's rc (0 external, 1 internal,
# 2 unknown) against this checkout's own list; the TICKET_ID_INTERNAL_AUTHORS_FILE
# override is never honoured, and a missing lib reads 2.
author_class() {
    (
        unset TICKET_ID_INTERNAL_AUTHORS_FILE
        # shellcheck source=ticket-id-internal.sh
        . "$(dirname "${BASH_SOURCE[0]}")/ticket-id-internal.sh" 2>/dev/null || exit 2
        ticket_id_author_class "$1"
    ) >/dev/null 2>&1
    echo "$?"
}

# outside_pr_of <snapshot>: prints yes for a fork, a deleted author, or a non-Bot
# author whose class is not internal; no for a same-repo Bot (by type, never by
# login text) or an internal author. rc 2 when the snapshot cannot say. Reads no
# body, title, branch name or label.
outside_pr_of() {
    local f fork bot login
    f=$(printf '%s' "$1" | jq -er '.[0] | select((.isCrossRepository | type) == "boolean" and (.authorIsBot | type) == "boolean")
        | "\(.isCrossRepository) \(.authorIsBot) \(.author // "")"' 2>/dev/null) || return 2
    read -r fork bot login <<< "$f"
    if [ "$fork" = true ] || [ -z "$login" ]; then echo yes
    elif [ "$bot" = true ]; then echo no
    elif printf '%s' "$login" | grep -qixE 'dependabot(\[bot\])?'; then echo yes
    elif [ "$(author_class "$login")" = 1 ]; then echo no
    else echo yes
    fi
}
