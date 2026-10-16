#!/usr/bin/env bash
# judge-ladder.sh — convene a judge at the cheapest tier that can rule.
#
#   next-tier <sonnet|opus|fable>   the tier a judge escalates to when it returns above-my-tier
#   convene <seat> <tier>           spend one convening from the seat's per-window budget
#   breakglass <finding-class>      route a substrate-lying finding class straight to the operator
#
# Exit: 0 ok · 2 bad usage or an ordinary class · 3 budget exhausted (refusing is fail-safe).
# State: one "<epoch> <seat> <tier>" line per convening in $JUDGE_LADDER_STATE (default
# <handover_root>/.judge-ladder). Knobs: JUDGE_LADDER_{SONNET,OPUS,FABLE}_CAP per seat per
# JUDGE_LADDER_WINDOW seconds; JUDGE_LADDER_NOW pins the clock for tests. bash 3.2-safe.
#
# ponytail: a flat per-seat count with no refill curve; HIMMEL-1864 slices 2+ (cross-model check per layer) revisit it.
set -u

SONNET_CAP="${JUDGE_LADDER_SONNET_CAP:-20}"
OPUS_CAP="${JUDGE_LADDER_OPUS_CAP:-10}"
FABLE_CAP="${JUDGE_LADDER_FABLE_CAP:-2}"
WINDOW="${JUDGE_LADDER_WINDOW:-3600}"
NOW="${JUDGE_LADDER_NOW:-$(date +%s)}"

for v in "$SONNET_CAP" "$OPUS_CAP" "$FABLE_CAP" "$WINDOW" "$NOW"; do
  case "$v" in '' | *[!0-9]*) echo "judge-ladder: non-numeric cap, window or clock '$v'" >&2; exit 2 ;; esac
done
[ "$WINDOW" -gt 0 ] || { echo "judge-ladder: JUDGE_LADDER_WINDOW must be positive" >&2; exit 2; }

state_file() {
  if [ -n "${JUDGE_LADDER_STATE:-}" ]; then printf '%s\n' "$JUDGE_LADDER_STATE"; return 0; fi
  # shellcheck source=/dev/null
  . "$(cd "$(dirname "$0")/../../lib" && pwd)/handover-path.sh" || return 2
  local root
  root="$(handover_root)" || return 2
  printf '%s/.judge-ladder\n' "$root"
}

cap_for() {
  case "$1" in
    sonnet) echo "$SONNET_CAP" ;;
    opus) echo "$OPUS_CAP" ;;
    fable) echo "$FABLE_CAP" ;;
    *) return 1 ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  next-tier)
    case "${2:-}" in
      sonnet) echo opus ;;
      opus) echo fable ;;
      fable) echo operator ;;
      *) echo "judge-ladder: unknown tier '${2:-}' (sonnet|opus|fable)" >&2; exit 2 ;;
    esac
    ;;
  convene)
    seat="${2:-}"; tier="${3:-}"
    case "$seat" in '' | *[[:space:]]*) echo "judge-ladder: convene needs a seat without whitespace" >&2; exit 2 ;; esac
    cap="$(cap_for "$tier")" || { echo "judge-ladder: unknown tier '$tier'" >&2; exit 2; }
    state="$(state_file)" || { echo "judge-ladder: no state dir" >&2; exit 2; }
    mkdir -p "$(dirname "$state")" || exit 2
    # mkdir is atomic: one convening at a time reads, checks and appends.
    lock="$state.lock"
    tries=0
    until mkdir "$lock" 2>/dev/null; do
      tries=$((tries + 1))
      [ "$tries" -lt 100 ] || { echo "judge-ladder: state lock busy; refusing" >&2; exit 3; }
      sleep 0.1
    done
    trap 'rmdir "$lock" 2>/dev/null' EXIT
    used=0
    if [ -f "$state" ]; then
      used="$(awk -v now="$NOW" -v win="$WINDOW" -v s="$seat" -v t="$tier" \
        '$2 == s && $3 == t && now - $1 < win { n++ } END { print n + 0 }' "$state")" \
        || { echo "judge-ladder: cannot count the budget; refusing" >&2; exit 3; }
    fi
    if [ "$used" -ge "$cap" ]; then
      echo "judge-ladder: convening budget exhausted for seat $seat at $tier ($used/$cap in ${WINDOW}s); refusing" >&2
      exit 3
    fi
    printf '%s %s %s\n' "$NOW" "$seat" "$tier" >> "$state" || exit 2
    echo "convened $tier for seat $seat ($((used + 1))/$cap)"
    ;;
  breakglass)
    case "${2:-}" in
      guard-no-fire | invariant-regression)
        echo "operator: finding class '$2' means the enforcement substrate is lying; no tier rules on it, no budget applies"
        ;;
      *) echo "judge-ladder: '${2:-}' does not break glass (guard-no-fire|invariant-regression)" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "usage: judge-ladder.sh next-tier <tier> | convene <seat> <tier> | breakglass <class>" >&2
    exit 2
    ;;
esac
