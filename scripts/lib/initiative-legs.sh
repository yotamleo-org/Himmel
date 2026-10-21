#!/usr/bin/env bash
# scripts/lib/initiative-legs.sh — pure leg resolver.
#
# Single source of truth for the harness-autonomy "leg grammar". Maps the
# relevant env values (passed as NAMED ARGUMENTS, never ambient reads, so the
# same function is callable from the SessionStart hook AND from minerva's
# plugin-side transport wrapper) to a normalized, canonical-ordered, deduped
# active leg set.
#
# Profiles:
#   - interactive (default):  var = HIMMEL_INITIATIVE,     all = 4 legacy legs
#   - afk (selector truthy):  var = HIMMEL_INITIATIVE_AFK, all = 6 legs
#
# `plan` is a reserved vocabulary token (recognized, no behavior yet).
#
# Usage: resolve_legs <initiative_val> <afk_val> <afk_selector>
# Echoes the active legs space-separated in canonical order, or empty string.
#
# resolve_legs_env is the one entry that reads the live env: it resolves the
# afk names against their old overnight names (scripts/lib/env-alias.sh) and
# calls resolve_legs. HIMMEL_AFK / HIMMEL_OVERNIGHT is a widening switch
# (env_alias_permit: a set falsy name keeps the interactive profile);
# HIMMEL_INITIATIVE_AFK / HIMMEL_INITIATIVE_OVERNIGHT is a value (alias_env).

# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/env-alias.sh"

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

# resolve_legs <initiative_val> <afk_val> <afk_selector>
resolve_legs() {
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

# il_afk_active → rc 0 when the afk profile is selected (HIMMEL_AFK, read-both).
il_afk_active() { env_alias_permit HIMMEL_AFK HIMMEL_OVERNIGHT; }

# resolve_legs_env → resolve_legs over the live env (see the header).
resolve_legs_env() {
  local sel=""
  alias_env HIMMEL_INITIATIVE_AFK HIMMEL_INITIATIVE_OVERNIGHT
  if il_afk_active; then sel=1; fi
  resolve_legs "${HIMMEL_INITIATIVE:-}" "${HIMMEL_INITIATIVE_AFK:-}" "$sel"
}
