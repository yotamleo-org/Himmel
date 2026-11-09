#!/usr/bin/env bash
# ticket-standard-check.sh — check a ticket draft against the himmel ticket standard.
#
#   ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] [--labels a,b] --draft FILE [--rewrite FILE]
#
# A draft needs Impact, What, Why, Plan, DoD, Proof and Agent detail as "## " headings,
# each with a non-placeholder line; Plan and DoD each need a real bullet or numbered
# line. A ci/guard/guardrail/stability/flake label needs a "Metric:" line; a Plan naming
# two or more ticket keys needs an "Edges:" line (or "Edges: none"). The rules are
# ticket-policy.mjs, the same policy jira create, edit, move and the MCP bridge apply.
# --labels names the labels the ticket will carry; a draft's "Labels:" line is only the
# offline fallback, and the two disagreeing is a finding.
# Task, Story and Bug that fail are REFUSED: every finding is printed, the draft is
# copied into the intake queue and the exit is 1. Epic and Subtask only warn. A
# missing Sector (flag or a "Sector:" line in the draft) warns for every type. The
# draft file is never modified or deleted. A pass checks the BODY only: home,
# placement and the final labels are checked by jira create.
#
# Queue: $TICKET_STANDARD_QUEUE_DIR, else <handover root>/<USER_SLUG>/himmel/intake
# (the root must come from HANDOVER_DIR: the inline default sits inside the checkout).
# Exit codes: 0 ok or warn, 1 refused (parked, or NOT PARKED said loudly), 2 usage or
# an unreadable draft, or the policy could not run (the draft was NOT checked).
set -u

usage(){ echo "usage: ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] [--labels a,b] --draft FILE [--rewrite FILE]" >&2; exit 2; }

type="" sector="" labels="" draft="" rewrite=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) [ $# -ge 2 ] || usage; type="$2"; shift 2;;
    --sector) [ $# -ge 2 ] || usage; sector="$2"; shift 2;;
    --labels) [ $# -ge 2 ] || usage; labels="$2"; shift 2;;
    --draft) [ $# -ge 2 ] || usage; draft="$2"; shift 2;;
    --rewrite) [ $# -ge 2 ] || usage; rewrite="$2"; shift 2;;
    *) usage;;
  esac
done
case "$type" in Task|Story|Bug|Epic|Subtask) ;; *) echo "ticket-standard-check: unknown --type '$type'" >&2; usage;; esac
if ! { [ -n "$draft" ] && [ -f "$draft" ] && [ -r "$draft" ]; }; then echo "ticket-standard-check: cannot read draft '$draft'" >&2; exit 2; fi

if [ -n "$rewrite" ]; then
  here="$(cd "$(dirname "$0")" && pwd)"
  if python3 -I "$here/humanizer-facts.py" "$draft" "$rewrite"; then
    draft="$rewrite"
  else
    echo "humanizer: rewrite refused or checker unavailable; checking original" >&2
  fi
else
  echo 'humanizer: optional deterministic humanizer-facts.py --normalize ORIGINAL CANDIDATE; skip keeps original, --rewrite FILE checks a candidate; no model rewrite' >&2
fi

# The rules live in ticket-policy.mjs, shared with jira create, edit, move and the MCP bridge;
# this script owns arguments, the Sector warning and parking. No fallback: when node
# or the policy cannot run, the draft is NOT checked and the exit is 2.
here="$(cd "$(dirname "$0")" && pwd)"
parsefail(){ echo "ticket-standard-check: could not check '$draft' (the ticket policy did not run); draft not checked" >&2; exit 2; }
command -v node >/dev/null 2>&1 || parsefail
policy_args=(--type "$type" --draft "$draft")
[ -n "$labels" ] && policy_args+=(--labels "$labels")
missing="$(node "$here/ticket-policy-cli.mjs" "${policy_args[@]}")" || parsefail

warns=()
grep -Eiq '^[[:space:]]*Sector:[[:space:]]*[^[:space:]]' "$draft" && sector="${sector:-from-draft}"
[ -n "$sector" ] || warns+=("Sector is missing (pass --sector or add a 'Sector: <name>' line)")

if [ -n "$missing" ]; then
  case "$type" in
    Epic|Subtask)
      echo "warn: $type draft is missing or has an empty: $missing"
      for w in "${warns[@]+"${warns[@]}"}"; do echo "warn: $w"; done
      exit 0;;
  esac
  echo "REFUSED $type draft: missing or empty: $missing"
  for w in "${warns[@]+"${warns[@]}"}"; do echo "warn: $w"; done
  q="${TICKET_STANDARD_QUEUE_DIR:-}"
  if [ -z "$q" ]; then
    lib="$(cd "$(dirname "$0")/../../../.." 2>/dev/null && pwd)/scripts/lib/handover-path.sh"
    if [ -n "${HANDOVER_DIR:-}" ] && [ -f "$lib" ]; then
      # shellcheck disable=SC1090
      . "$lib"; root="$(handover_root)" || root=""
    else root="${HANDOVER_DIR:-}"; fi
    if ! { [ -n "$root" ] && [ -d "$root" ]; }; then echo "NOT PARKED: no queue (set HANDOVER_DIR or TICKET_STANDARD_QUEUE_DIR)" >&2; exit 1; fi
    q="$root/${USER_SLUG:-${USER:-unknown}}/himmel/intake"
  fi
  dest=""
  # BSD mktemp substitutes only trailing X's, so the .md suffix is added after.
  if mkdir -p "$q" 2>/dev/null && dest="$(mktemp "$q/$(date -u +%Y%m%dT%H%M%SZ)-$type-XXXXXX" 2>/dev/null)" \
     && mv "$dest" "$dest.md" && dest="$dest.md" \
     && cp "$draft" "$dest" 2>/dev/null && cmp -s "$draft" "$dest"; then
    echo "parked in intake queue: $dest"
    echo "complete it, then re-run: ticket-standard-check.sh --type $type --draft $dest"
    exit 1
  fi
  [ -n "$dest" ] && rm -f "$dest"
  echo "NOT PARKED: could not write the draft into '$q'" >&2
  exit 1
fi

for w in "${warns[@]+"${warns[@]}"}"; do echo "warn: $w"; done
echo "ok: $type draft body check passed (body only: home, placement and the final labels are checked by jira create)"
exit 0
