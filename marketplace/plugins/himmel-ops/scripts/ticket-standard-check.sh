#!/usr/bin/env bash
# ticket-standard-check.sh — check a ticket draft against the himmel ticket standard.
#
#   ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] --draft FILE
#
# A draft needs Impact, What, Why, Plan, DoD, Proof and Agent detail, each with at
# least one non-placeholder line. Task, Story and Bug that fail are REFUSED: every
# missing name is printed, the draft is copied into the intake queue and the exit is
# 1. Epic and Subtask only warn. A missing Sector (flag or a "Sector:" line in the
# draft) warns for every type. The draft file is never modified or deleted.
#
# Queue: $TICKET_STANDARD_QUEUE_DIR, else <handover root>/<USER_SLUG>/himmel/intake
# (the root must come from HANDOVER_DIR: the inline default sits inside the checkout).
# Exit codes: 0 ok or warn, 1 refused (parked, or NOT PARKED said loudly), 2 usage or
# an unreadable/unparseable draft (awk failed: the draft was NOT checked).
#
# ponytail: heading rules duplicate scripts/jira/src/plain-block.ts (dist is absent in worktrees), call that lint once HIMMEL-5643 is merged
set -u

usage(){ echo "usage: ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] --draft FILE" >&2; exit 2; }

type="" sector="" draft=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) [ $# -ge 2 ] || usage; type="$2"; shift 2;;
    --sector) [ $# -ge 2 ] || usage; sector="$2"; shift 2;;
    --draft) [ $# -ge 2 ] || usage; draft="$2"; shift 2;;
    *) usage;;
  esac
done
case "$type" in Task|Story|Bug|Epic|Subtask) ;; *) echo "ticket-standard-check: unknown --type '$type'" >&2; usage;; esac
[ -n "$draft" ] && [ -f "$draft" ] && [ -r "$draft" ] || { echo "ticket-standard-check: cannot read draft '$draft'" >&2; exit 2; }

# Sections whose heading is present but whose body has no real line; or whose heading is absent.
missing="$(awk '
  function norm(s) { sub(/^[ \t]*(#+|\*\*|__)?[ \t]*/, "", s); sub(/[ \t]+#+[ \t]*$/, "", s); sub(/[ \t]*(\*\*|__)?[ \t]*:?[ \t]*(\*\*|__)?[ \t]*$/, "", s); return tolower(s) }
  function real(s) {
    s = tolower(s); gsub(/\*\*|__/, "", s); sub(/^[ \t]*([-*]|[0-9]+[.)])?[ \t]*/, "", s); sub(/[ \t.]*$/, "", s)
    return !(s == "" || s ~ /^(tbd|tbc|todo|n\/a|na|none|\.\.\.|…|\?+|-+)$/ || s ~ /^<[^>]*>$/)
  }
  BEGIN { n = split("impact|what|why|plan|dod|proof|agent detail", w, "|"); for (i = 1; i <= n; i++) want[w[i]] = ""; split("Impact What Why Plan DoD Proof Agent_detail", disp, " ") }
  match($0, /^( |  |   )?(```+|~~~+)/) {
    run = substr($0, RSTART, RLENGTH); sub(/^ */, "", run)
    if (!fence) { fence = 1; fch = substr(run, 1, 1); flen = length(run); next }
    if (substr(run, 1, 1) == fch && length(run) >= flen && substr($0, RSTART + RLENGTH) ~ /^[ \t]*$/) { fence = 0; next }
  }
  fence || /^(    |\t)/ { if (cur != "" && real($0)) have[cur] = 1; next }
  { k = norm($0); if (k in want) { cur = k; seen[k] = 1; next } if ($0 ~ /^[ \t]*#+[ \t]/ || $0 ~ /^[ \t]*(\*\*|__)[^*_]+(\*\*|__)[ \t]*:?[ \t]*$/) { cur = ""; next } if (cur != "" && real($0)) have[cur] = 1 }
  END { for (i = 1; i <= n; i++) if (!(w[i] in have)) { d = disp[i]; sub(/_/, " ", d); printf "%s%s", (c++ ? ", " : ""), d } }
' "$draft")" || { echo "ticket-standard-check: could not parse '$draft' (awk failed); draft not checked" >&2; exit 2; }

# A CI/guard/stability ticket (by label) must name the scorecard metric it moves: a real "Metric:" line.
if grep -Eiq '^[[:space:]]*Labels:.*(^|[:,[:space:]])(ci|guard|stability|flake)(-[a-z0-9-]+)?([,[:space:]]|$)' "$draft"; then
  metric="$(sed -n 's/^[[:space:]]*[Mm]etric:[[:space:]]*//p' "$draft" | head -n 1 | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:].]*$//')"
  case "$metric" in
    ''|tbd|tbc|todo|n/a|na|none|...|'?'*|-*|'<'*'>') missing="${missing:+$missing, }Metric (name the stability-scorecard metric this ticket moves)" ;;
  esac
fi

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
    [ -n "$root" ] && [ -d "$root" ] || { echo "NOT PARKED: no queue (set HANDOVER_DIR or TICKET_STANDARD_QUEUE_DIR)" >&2; exit 1; }
    q="$root/${USER_SLUG:-${USER:-unknown}}/himmel/intake"
  fi
  dest=""
  if mkdir -p "$q" 2>/dev/null && dest="$(mktemp "$q/$(date -u +%Y%m%dT%H%M%SZ)-$type-XXXXXX.md" 2>/dev/null)" \
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
echo "ok: $type draft meets the ticket standard"
exit 0
