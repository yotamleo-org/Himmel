#!/usr/bin/env bash
# scripts/lib/initiative-workers.sh — pure worker resolver.
#
# Single source of truth for the harness-autonomy "worker grammar". Maps the
# relevant env values (passed as NAMED ARGUMENTS, never ambient reads, so the
# same function is callable from the SessionStart hook AND from minerva's
# plugin-side transport wrapper) to a normalized, canonical-ordered, deduped
# active worker set.
#
# Profiles:
#   - interactive (default):  var = HIMMEL_INITIATIVE,     all = 4 legacy workers
#   - afk (selector truthy):  var = HIMMEL_INITIATIVE_AFK, all = 6 workers
#
# `plan` is a reserved vocabulary token (recognized, no behavior yet).
#
# Usage: resolve_workers <initiative_val> <afk_val> <afk_selector>
# Echoes the active workers space-separated in canonical order, or empty string.
#
# resolve_workers_env is the one entry that reads the live env: it reads the afk
# names and calls resolve_workers. HIMMEL_AFK is a widening switch (a set falsy
# value keeps the interactive profile); HIMMEL_INITIATIVE_AFK is a value.

# Canonical vocabulary order — every emitted set is filtered through this.
_IL_VOCAB="plan execute prcheck pr ticket merge public handover"
_IL_INTERACTIVE_ALL="prcheck pr ticket handover"
_IL_AFK_ALL="execute prcheck pr ticket merge handover"

# _il_norm <value> → lowercased, whitespace-stripped
_il_norm() { printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'; }

# _il_truthy <value> → rc 0 if truthy (selector test)
_il_truthy() {
  case "$(_il_norm "${1:-}")" in
    ''|0|false|off|no) return 1;;
    *) return 0;;
  esac
}

# _il_filter <wanted=",tok,tok,"> → echo VOCAB ∩ wanted in canonical order
_il_filter() {
  local wanted="$1" out="" t
  for t in $_IL_VOCAB; do
    case "$wanted" in *",$t,"*) out="${out:+$out }$t";; esac
  done
  printf '%s' "$out"
}

# resolve_workers <initiative_val> <afk_val> <afk_selector>
resolve_workers() {
  local init_val="${1:-}" afk_val="${2:-}" selector="${3:-}"
  local base all_set norm
  if _il_truthy "$selector"; then
    base="$afk_val"; all_set="$_IL_AFK_ALL"
  else
    base="$init_val"; all_set="$_IL_INTERACTIVE_ALL"
  fi
  norm="$(_il_norm "$base")"
  case "$norm" in
    ''|0|false|off|no) return 0;;                       # empty set
    1|true|on|yes|all) printf '%s' "$all_set"; return 0;;
  esac
  _il_filter ",$norm,"                                  # comma-subset (canonical, deduped)
}

# il_afk_active → rc 0 when the afk profile is selected (HIMMEL_AFK set and not falsy).
il_afk_active() {
  case "${HIMMEL_AFK:-}" in
    ''|0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 1 ;;
  esac
  return 0
}

# resolve_workers_env → resolve_workers over the live env (see the header).
resolve_workers_env() {
  local sel=""
  if il_afk_active; then sel=1; fi
  resolve_workers "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_AFK:-}" "$sel"
}
