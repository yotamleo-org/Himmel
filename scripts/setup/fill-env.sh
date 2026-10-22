#!/usr/bin/env bash
# fill-env.sh -- interactive fill of the must-set values.
# Prompts for each UNCOMMENTED `KEY=` line in .env.example (the must-set vars;
# commented lines are opt-in -- uncomment first) and writes the answer into .env,
# except a behaviour-config key (USER_SLUG, HANDOVER_DIR, ...: scripts/lib/
# load-dotenv.sh _himmel_key_class), which goes to ~/.himmel/himmel.conf.
# Press Enter at any prompt to SKIP that var (keep its current value).
# Non-interactive stdin -> no-op with a notice.
#
# Opt-in: only runs when setup.sh/adopt.sh are passed --fill-env / -FillEnv.
# bash-only (the PS installers shell out to it) so there is ONE implementation
# operating on a plain-text file.
#
# Source-safe: defines functions on `source`, runs fill_env only on direct
# invocation. NO top-level `set -e` (it would alter a sourcing caller's shell).
#   bash fill-env.sh <env-file> [example-file]

# Strip trailing CR + surrounding whitespace (CRLF-safe; mirrors
# scripts/lib/load-dotenv.sh::_load_dotenv_trim). Pure (stdout only).
_fe_trim() {
  local s="$1"
  s="${s%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"   # ltrim
  s="${s%"${s##*[![:space:]]}"}"   # rtrim
  printf '%s' "$s"
}

# dotenv_get <file> <key> -- value of the first uncommented `KEY=` line, trimmed
# (CR-stripped); empty if absent.
dotenv_get() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in "$key="*) _fe_trim "${line#*=}"; return 0 ;; esac
  done < "$file"
}

# shellcheck source=../lib/prim.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/prim.sh" || return 1

# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../lib/load-dotenv.sh" || return 1

# dotenv_set <file> <key> <value> -- replace the FIRST uncommented `KEY=` line in
# place (CRLF on that line tolerated); append `KEY=value` if absent. Idempotent.
dotenv_set() {
  local file="$1" key="$2" val="$3" out
  if [ -f "$file" ] && grep -qE "^${key}=" "$file"; then
    # Pass key/value via ENVIRON, NOT `awk -v` -- `-v` escape-processes the value
    # (a backslash or \n in a Windows path would silently corrupt the .env).
    # ENVIRON[] values are taken literally. Replace the FIRST `KEY=` line.
    out="$(FE_K="$key" FE_V="$val" awk '
      !done && index($0, ENVIRON["FE_K"] "=") == 1 { print ENVIRON["FE_K"] "=" ENVIRON["FE_V"]; done=1; next }
      { print }
    ' "$file" && printf x)" && printf '%s' "${out%x}" | atomic_write "$file"
  else
    # Ensure the file ends in a newline before appending -- a final line with no
    # trailing \n would otherwise fuse with the new KEY=value.
    if [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ]; then printf '\n' >> "$file"; fi
    printf '%s=%s\n' "$key" "$val" >> "$file"
  fi
}

# _fe_inline_comment <line> -- text of a trailing ` # comment` on a `KEY=` line
# (the first whitespace-preceded '#'), trimmed; empty if none. A '#' NOT preceded
# by whitespace (e.g. inside a URL fragment) is left as part of the value.
_fe_inline_comment() {
  local line="$1" rest
  line="${line%$'\r'}"
  case "$line" in
    *[[:space:]]"#"*) rest="${line#*[[:space:]]#}" ;;
    *) return 0 ;;
  esac
  _fe_trim "$rest"
}

# dotenv_help <example-file> <key> -- the per-var help blurb for KEY: the
# contiguous `#` comment block immediately ABOVE the first `KEY=` line, followed
# by KEY's inline trailing comment, one cleaned line each. Empty if none.
# Contiguity is broken by a blank line, any non-comment line, OR a commented-out
# `# OTHERKEY=...` assignment (it delimits the *previous* variable's doc block,
# so it is not this key's help). A section/group-header comment directly above a
# key (e.g. `# --- Jira ... ---`) IS included as the first help line, by design.
# CR-tolerant. Keeps .env.example the single source of truth -- the script holds
# no duplicate map. Reads ONLY the example file, never the live .env.
dotenv_help() {
  local file="$1" key="$2" line trimmed txt keyhead block="" inline=""
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    trimmed="$(_fe_trim "$line")"
    case "$trimmed" in
      "$key="*)
        inline="$(_fe_inline_comment "$line")"
        printf '%s' "$block"
        [ -n "$inline" ] && printf '%s\n' "$inline"
        return 0
        ;;
      "#"*)
        txt="${trimmed#\#}"; txt="${txt# }"    # strip one leading '#' then space
        keyhead="${txt%%=*}"
        case "$txt" in
          # A commented-out `IDENT=...` assignment (clean identifier before '=',
          # not prose that merely contains '=') is a doc-block boundary -> reset.
          [A-Za-z_]*=*)
            case "$keyhead" in
              *[!A-Za-z0-9_]*) block="${block}${txt}"$'\n' ;;   # space etc. -> prose
              *) block="" ;;                                     # real KEY= -> boundary
            esac
            ;;
          *) block="${block}${txt}"$'\n' ;;
        esac
        ;;
      "")
        block=""                               # blank line breaks contiguity
        ;;
      *)
        block=""                               # any other line breaks contiguity
        ;;
    esac
  done < "$file"
}

# _fe_format_help <help-text> -- render a help blurb for the interactive prompt:
# a leading blank line then each line indented four spaces. Empty input emits
# nothing (the prompt then shows bare). Pure (stdout only).
_fe_format_help() {
  local help="$1" hl
  [ -n "$help" ] || return 0
  echo ""
  printf '%s\n' "$help" | while IFS= read -r hl; do printf '    %s\n' "$hl"; done
}

# fillable_keys <example-file> -- names of every UNCOMMENTED `KEY=` line, in file
# order (whole file; no section logic). CR-tolerant.
fillable_keys() {
  local file="$1" line
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      [A-Za-z_]*=*) printf '%s\n' "${line%%=*}" ;;
    esac
  done < "$file"
}

# _fe_store <key> <env-file> -- the file KEY's answer is written to: the tracked
# config file for a behaviour-config key, the env file for everything else.
_fe_store() {
  local conf
  if [ "$(_himmel_key_class "$1")" = config ]; then
    conf="$(_himmel_config_dir)/himmel.conf"
    # A himmel.conf.local value outranks himmel.conf, so the answer goes there.
    if [ -f "$conf.local" ] && [ -n "$(dotenv_get "$conf.local" "$1")" ]; then
      printf '%s' "$conf.local"
    else
      printf '%s' "$conf"
    fi
  else
    printf '%s' "$2"
  fi
}

# _fe_current <key> <env-file> -- the value the prompt shows: the key's store,
# then himmel.conf (a config key's local override is its store when it has one),
# then (config keys not yet migrated) the legacy value still in the env file.
_fe_current() {
  local v conf
  v="$(dotenv_get "$(_fe_store "$1" "$2")" "$1")"
  if [ -z "$v" ] && [ "$(_himmel_key_class "$1")" = config ]; then
    conf="$(_himmel_config_dir)/himmel.conf"
    v="$(dotenv_get "$conf" "$1")"
  fi
  [ -n "$v" ] || v="$(dotenv_get "$2" "$1")"
  printf '%s' "$v"
}

# _fe_save <key> <env-file> <value> -- write the answer to the key's store.
_fe_save() {
  local f
  f="$(_fe_store "$1" "$2")"
  mkdir -p "$(dirname "$f")" && dotenv_set "$f" "$1" "$3"
}

# fill_env <env-file> [example-file] -- interactive prompt loop.
fill_env() {
  local envfile="$1" example="${2:-}" key cur ans
  [ -n "$envfile" ] || { echo "fill-env: usage: fill_env <env-file> [example-file]" >&2; return 2; }
  [ -f "$envfile" ] || { echo "fill-env: $envfile not found" >&2; return 1; }
  [ -n "$example" ] || example="$(dirname "$envfile")/.env.example"
  [ -f "$example" ] || { echo "fill-env: $example not found" >&2; return 1; }
  if [ ! -t 0 ]; then
    echo "fill-env: non-interactive shell -- skipping (.env left as-is)." >&2
    return 0
  fi
  echo "Fill .env values (press Enter to skip / keep current):"
  while IFS= read -r key; do
    cur="$(_fe_current "$key" "$envfile")"
    # Per-var help blurb from the .env.example comments, indented above the prompt.
    _fe_format_help "$(dotenv_help "$example" "$key")"
    printf '  %s [%s]: ' "$key" "$cur"
    IFS= read -r ans || ans=""
    if [ -n "$ans" ]; then
      _fe_save "$key" "$envfile" "$ans" || echo "  WARNING: could not write $key" >&2
    fi
  done < <(fillable_keys "$example")
  echo "  done."
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fill_env "$@"
fi
