#!/usr/bin/env bash
# ticket-standard-check.sh — check a ticket draft against the himmel ticket standard.
#
#   ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] --draft FILE [--rewrite FILE]
#
# A draft needs Impact, What, Why, Plan, DoD, Proof and Agent detail, each with at
# least one non-placeholder line. Task, Story and Bug that fail are REFUSED: every
# missing name is printed, the draft is copied into the intake queue and the exit is
# 1. Epic and Subtask only warn. A missing Sector (flag or a "Sector:" line in the
# draft) warns for every type. The draft file is never modified or deleted.
# A Plan naming two or more ticket keys also needs an "Edges:" line (or "Edges: none").
#
# Queue: $TICKET_STANDARD_QUEUE_DIR, else <handover root>/<USER_SLUG>/himmel/intake
# (the root must come from HANDOVER_DIR: the inline default sits inside the checkout).
# Exit codes: 0 ok or warn, 1 refused (parked, or NOT PARKED said loudly), 2 usage or
# an unreadable/unparseable draft (awk failed: the draft was NOT checked).
#
# ponytail: heading rules duplicate scripts/jira/src/plain-block.ts (dist is absent in worktrees), call that lint once HIMMEL-5643 is merged
set -u

usage(){ echo "usage: ticket-standard-check.sh --type Task|Story|Bug|Epic|Subtask [--sector NAME] --draft FILE [--rewrite FILE]" >&2; exit 2; }

type="" sector="" draft="" rewrite=""
while [ $# -gt 0 ]; do
  case "$1" in
    --type) [ $# -ge 2 ] || usage; type="$2"; shift 2;;
    --sector) [ $# -ge 2 ] || usage; sector="$2"; shift 2;;
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

# One awk program, three modes: default lists the sections whose heading is absent or whose body has no
# real line; -v mode=keys prints how many distinct ticket keys the Plan section names; -v mode=edges
# prints the value of the first "Edges:" line outside any code (the same fence rules as the sections).
# shellcheck disable=SC2016 # the awk program is literal text, nothing here should expand
prog='
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
  function addkeys(s) { while (match(s, /[A-Z][A-Z0-9]+-[0-9]+/)) { key[substr(s, RSTART, RLENGTH)] = 1; s = substr(s, RSTART + RLENGTH) } }
  function lvl(s) { sub(/^[ \t]*/, "", s); return match(s, /^#+/) ? RLENGTH : 0 }
  fence || /^(    |\t)/ { if (cur != "" && real($0)) have[cur] = 1; if (cur == "plan") addkeys($0); next }
  {
    if (!edgeset && match($0, /^[ \t]*([-*+][ \t]+)?(\*\*|__)?[Ee][Dd][Gg][Ee][Ss](\*\*|__)?:(\*\*|__)?[ \t]*/)) { edgeset = 1; ev = tolower(substr($0, RLENGTH + 1)); sub(/[ \t.]*$/, "", ev) }
    k = norm($0)
    if (k in want) { cur = k; seen[k] = 1; plvl = lvl($0); next }
    if ($0 ~ /^[ \t]*#+[ \t]/ || $0 ~ /^[ \t]*(\*\*|__)[^*_]+(\*\*|__)[ \t]*:?[ \t]*$/) { if (!(cur == "plan" && plvl > 0 && lvl($0) > plvl)) cur = ""; next }
    if (cur != "" && real($0)) have[cur] = 1
    if (cur == "plan") addkeys($0)
  }
  END {
    if (mode == "keys") { for (x in key) nk++; print nk + 0; exit }
    if (mode == "edges") { print ev; exit }
    for (i = 1; i <= n; i++) if (!(w[i] in have)) { d = disp[i]; sub(/_/, " ", d); printf "%s%s", (c++ ? ", " : ""), d }
  }
'
parsefail(){ echo "ticket-standard-check: could not parse '$draft' (awk failed); draft not checked" >&2; exit 2; }
# Sections whose heading is present but whose body has no real line; or whose heading is absent.
missing="$(awk "$prog" "$draft")" || parsefail

# A CI/guard/guardrail/stability ticket (by label) must name the scorecard metric it moves: a real "Metric:" line (bare, bulleted, bold, any case).
if grep -Eiq '^[[:space:]]*Labels:.*(^|[:,[:space:]])(ci|guard|guardrail|stability|flake)(-[a-z0-9-]+)?([,[:space:]]|$)' "$draft"; then
  metric="$(sed -nE 's/^[[:space:]]*([-*+][[:space:]]+)?(\*\*|__)?[Mm][Ee][Tt][Rr][Ii][Cc](\*\*|__)?:(\*\*|__)?[[:space:]]*//p' "$draft" | head -n 1 | tr '[:upper:]' '[:lower:]' | sed 's/[[:space:].]*$//')"
  case "$metric" in
    ''|tbd|tbc|todo|n/a|na|none|...|'?'*|-*|'<'*'>') missing="${missing:+$missing, }Metric (name the stability-scorecard metric this ticket moves)" ;;
  esac
fi

# A Plan that names two or more ticket keys needs an "Edges:" line (which ticket blocks which, hard or soft), or "Edges: none".
# ponytail: any [A-Z][A-Z0-9]+-[0-9]+ counts as a key (UTF-8 and SHA-256 together would too), answer with "Edges: none"
plankeys="$(awk -v mode=keys "$prog" "$draft")" || parsefail
if [ "$plankeys" -ge 2 ] 2>/dev/null; then
  edges="$(awk -v mode=edges "$prog" "$draft")" || parsefail
  case "$edges" in
    ''|tbd|tbc|todo|n/a|na|...|'?'*|-*|'<'*'>') missing="${missing:+$missing, }Edges: (the Plan names $plankeys ticket keys: add an 'Edges: <A> blocks <B> (hard|soft)' line, or 'Edges: none')" ;;
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
echo "ok: $type draft meets the ticket standard"
exit 0
