#!/usr/bin/env bash
# scripts/ci/live-witness.sh — a decoy station home and a witness that says which
# suite (or CI step) wrote into it.
#
# CI never ran a suite against the station's shape: its HOME held no himmel.conf,
# no settings.json, no handover root, so a writer that edits a live path only when
# it exists never ran that branch, and a write under $HOME/.himmel went to a sandbox
# nobody looked at. The decoy is laid out like the station; after a suite, the
# witness checks it. A write, edit or delete in a watched root fails the suite and
# names the path.
#
# Sourced by scripts/ci/run-shell-tests.sh (per lane) and scripts/ci/home-canary.sh,
# or run as a command:
#   live-witness.sh run --label <name> -- <command...>
# which runs the command with HOME at a fresh decoy and the XDG vars unset, prints
# `[LIVE-STATE] <name> — <msg>` per hit and one `live-witness: on, <name>, <h> hits,
# cmd rc=<n>` line on every exit path, and exits 86 on any hard hit, else the
# command's own rc. SUITE_LIVE_EXEMPT names the exempt file (an empty value: none).
#
# The check is builtins only; a dirty suite pays one find per hit root.
#
# Also owns the account-home watch: the passwd home's himmel roots, which no HOME
# change reaches. live_witness_account_begin / _end stamp and compare them on a
# GitHub-hosted runner.
#
# Platform guard: bash 3.2+, GNU/BSD coreutils (touch -t, find -newer).

LW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/prim.sh
declare -F tmpdir >/dev/null 2>&1 || . "$LW_DIR/../lib/prim.sh"

# Watched roots under the decoy home. The measurement may narrow .config or
# .local/bin to named entries if a CI tool writes one on its own; record the reason
# here, never silently.
LW_ROOTS=".himmel .claude .claude.json .codex .config .local/share/himmel .local/state/himmel .local/bin"
LW_SEED_FILES=".himmel/himmel.conf .himmel/config.json .claude/settings.json .claude.json .codex/config.toml"
LW_SEED_DIRS=".himmel .claude .codex"
LW_ABSENT=".config .local/share/himmel .local/state/himmel .local/bin"
# The account's passwd home: the roots himmel code reaches without $HOME.
LW_ACCOUNT_ROOTS=".himmel .claude .claude.json .local/share/himmel .local/state/himmel"
LW_SEED_MTIME=197001010016.40
LW_STAMP_MTIME=197001010033.20

_lw_age() { TZ=UTC touch -m -t "$LW_SEED_MTIME" "$1"; }

# live_witness_seed <lane-root> <home> <handover-root> [<canary-env>]
live_witness_seed() {
  local _lane="$1" _home="$2" _hroot="$3" _env="${4:-}" _p
  mkdir -p "$_lane" "$_home/.himmel" "$_home/.claude" "$_home/.codex" "$_hroot" || return 1
  printf 'HANDOVER_DIR=%s\n' "$_hroot" > "$_home/.himmel/himmel.conf" || return 1
  printf '{}\n' > "$_home/.himmel/config.json" || return 1
  printf '{}\n' > "$_home/.claude/settings.json" || return 1
  printf '{}\n' > "$_home/.claude.json" || return 1
  printf '# live-witness seed\n' > "$_home/.codex/config.toml" || return 1
  [ -z "$_env" ] || ln -sf "$_env" "$_home/.env" || return 1
  # Files first, then the dirs: a dir's mtime moves when a file is made in it.
  for _p in $LW_SEED_FILES; do _lw_age "$_home/$_p" || return 1; done
  for _p in $LW_SEED_DIRS; do _lw_age "$_home/$_p" || return 1; done
  _lw_age "$_hroot" || return 1
  : > "$_lane/witness.stamp" || return 1
  TZ=UTC touch -m -t "$LW_STAMP_MTIME" "$_lane/witness.stamp" || return 1
}

# live_witness_env <home> — run inside the suite's subshell.
live_witness_env() {
  export HOME="$1"
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME
}

# _lw_names <root-path> <stamp> <strip-prefix> <max> — up to <max> paths under (or
# at) <root-path> newer than the stamp, non-directories first, then the deepest dirs
# (find -depth lists children before their dir; a create-then-delete leaves only
# the dir). Prints them ", "-joined, relative to <strip-prefix>/.
_lw_names() {
  local _all _l _out="" _n=0 _pass
  _all=$(find "$1" -depth -newer "$2" 2>/dev/null) # swallow-ok: a failed find leaves no names and the caller names the root itself
  for _pass in files dirs; do
    while IFS= read -r _l; do
      [ -n "$_l" ] || continue
      [ "$_n" -lt "$4" ] || break
      if [ "$_pass" = files ]; then [ ! -d "$_l" ] || continue; else [ -d "$_l" ] || continue; fi
      _out="${_out:+$_out, }${_l#"$3"/}"
      _n=$((_n + 1))
    done <<LWNAMES
$_all
LWNAMES
  done
  printf '%s' "$_out"
}

# live_witness_check <lane-root> <home> <handover-root> — builtins only; appends one
# message per hit to witness_msgs and returns 1 on any hit.
live_witness_check() {
  local _lane="$1" _home="$2" _hroot="$3" _stamp="$1/witness.stamp" _p _r _hit=0 _marks=" " _hmark=0 _names
  witness_msgs="${witness_msgs:-}"
  for _p in $LW_SEED_FILES; do
    _r="${_p%%/*}"
    if [ ! -f "$_home/$_p" ]; then
      witness_msgs="${witness_msgs}removed $_p from the decoy home (on the station this is ~/$_p)
"
      _hit=1
    elif [ "$_home/$_p" -nt "$_stamp" ]; then
      case "$_marks" in *" $_r "*) ;; *) _marks="$_marks$_r " ;; esac
    fi
  done
  for _p in $LW_SEED_DIRS; do
    if [ ! -d "$_home/$_p" ]; then
      witness_msgs="${witness_msgs}removed $_p from the decoy home (on the station this is ~/$_p)
"
      _hit=1
    elif [ "$_home/$_p" -nt "$_stamp" ]; then
      case "$_marks" in *" $_p "*) ;; *) _marks="$_marks$_p " ;; esac
    fi
  done
  if [ ! -d "$_hroot" ]; then
    witness_msgs="${witness_msgs}removed the decoy handover root (on the station this is the real handover root)
"
    _hit=1
  elif [ "$_hroot" -nt "$_stamp" ]; then
    _hmark=1
  fi
  for _p in $LW_ABSENT; do
    if [ -e "$_home/$_p" ] || [ -L "$_home/$_p" ]; then
      case "$_marks" in *" $_p "*) ;; *) _marks="$_marks$_p " ;; esac
    fi
  done
  for _r in $_marks; do
    _hit=1
    _names=$(_lw_names "$_home/$_r" "$_stamp" "$_home" 3)
    [ -n "$_names" ] || _names="$_r"
    witness_msgs="${witness_msgs}wrote $_names in the decoy home (on the station this is ~/${_names%%,*})
"
  done
  if [ "$_hmark" -eq 1 ]; then
    _hit=1
    _names=$(_lw_names "$_hroot" "$_stamp" "$_hroot" 3)
    witness_msgs="${witness_msgs}wrote ${_names:-the root itself} in the decoy handover root (on the station this is the real handover root)
"
  fi
  [ "$_hit" -eq 0 ]
}

# live_witness_reset <lane-root> <home> <handover-root> [<canary-env>] — remove the
# watched roots and the handover root and re-seed (the runner also uses it for the
# first seed). Refuses (return 2) unless both sit under the lane root.
live_witness_reset() {
  local _lane="$1" _home="$2" _hroot="$3" _env="${4:-}" _p
  case "$_lane" in ''|/) return 2 ;; esac
  case "$_home" in "$_lane"/?*) ;; *) return 2 ;; esac
  case "$_hroot" in "$_lane"/?*) ;; *) return 2 ;; esac
  for _p in $LW_ROOTS; do rm -rf "${_home:?}/$_p" || return 1; done
  rm -rf "${_hroot:?}" || return 1
  live_witness_seed "$_lane" "$_home" "$_hroot" "$_env"
}

# The exempt list: one `<glob> HIMMEL-<n> <reason>` per line; `#` and blank lines are
# ignored. A glob is matched against the target ("/<suite path>" in the runner, the
# label in `run` mode). Return 2 (LW_EXEMPT_ERR names the line) on a line with no
# HIMMEL-<n> key, or whose glob has a glob character in its last `/`-separated part,
# except the exact form `* HIMMEL-<n> measurement`, a measurement push's all-WARN line.
LW_EXEMPT=""
LW_EXEMPT_ERR=""
live_witness_exempt_load() {
  local _f="${1:-}" _line _glob _key _rest _last _keyre='^HIMMEL-[0-9]+$'
  LW_EXEMPT=""
  LW_EXEMPT_ERR=""
  [ -n "$_f" ] || return 0
  if [ ! -r "$_f" ]; then LW_EXEMPT_ERR="cannot read the exempt file $_f"; return 2; fi
  while IFS= read -r _line || [ -n "$_line" ]; do
    _glob="" _key="" _rest=""
    read -r _glob _key _rest <<< "$_line"
    case "$_glob" in ''|'#'*) continue ;; esac
    if ! [[ "$_key" =~ $_keyre ]]; then
      LW_EXEMPT_ERR="exempt line has no HIMMEL-<n> key: $_line"
      return 2
    fi
    _last="${_glob##*/}"
    case "$_last" in
      *[*?[]*)
        if [ "$_glob" != '*' ] || [ "$_rest" != measurement ]; then
          LW_EXEMPT_ERR="exempt glob names a family, not one suite file: $_line"
          return 2
        fi ;;
    esac
    LW_EXEMPT="$LW_EXEMPT$_glob
"
  done < "$_f"
  return 0
}
live_witness_is_exempt() {
  local _g
  while IFS= read -r _g; do
    [ -n "$_g" ] || continue
    # shellcheck disable=SC2254  # the list entries are patterns
    case "$1" in $_g) return 0 ;; esac
  done <<LWEX
$LW_EXEMPT
LWEX
  return 1
}

# The account watch. On when: the test seam (LIVE_WITNESS_ACCOUNT_HOME with
# HIMMEL_TEST_FIXTURE=1); else a GitHub-hosted run (GITHUB_ACTIONS=true,
# RUNNER_ENVIRONMENT=github-hosted, no fixture flag); else off with one NOTE line
# naming why. A suite in a shard has HIMMEL_TEST_FIXTURE=1, so a home-canary or `run`
# a suite starts never stamps the real runner home; a self-hosted route can have
# other writers of these roots.
_lw_passwd_home() {
  local _line _h=""
  # swallow-ok: a failed lookup falls to the next form, and no home at all turns the watch off with a NOTE
  if _line=$(command -p getent passwd "${UID:-$(command -p id -u)}" 2>/dev/null); then # swallow-ok: see above
    IFS=: read -r _ _ _ _ _ _h _ <<< "$_line"
  elif _line=$(command -p dscl . -read "/Users/$(command -p id -un 2>/dev/null)" NFSHomeDirectory 2>/dev/null); then # swallow-ok: see above
    _h=${_line#NFSHomeDirectory:}
    _h=${_h#"${_h%%[![:space:]]*}"}
  fi
  [ -n "$_h" ] || return 1
  printf '%s' "$_h"
}

# live_witness_account_begin <state-dir> [<tag> [<label>]]
live_witness_account_begin() {
  local _sd="$1" _tag="${2:-live-witness}" _label="${3:-}" _home="" _why="" _p
  rm -f "$_sd/acct.home" "$_sd/acct.exist" "$_sd/acct.stamp" "$_sd/acct.hits"
  if [ -n "${LIVE_WITNESS_ACCOUNT_HOME:-}" ] && [ "${HIMMEL_TEST_FIXTURE:-}" = 1 ]; then
    _home="$LIVE_WITNESS_ACCOUNT_HOME"
  elif [ "${GITHUB_ACTIONS:-}" != true ]; then
    _why="not a GitHub Actions run"
  elif [ "${HIMMEL_TEST_FIXTURE:-}" = 1 ]; then
    _why="nested in a test fixture"
  elif [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
    _why="runner environment ${RUNNER_ENVIRONMENT:-unset}"
  elif ! _home=$(_lw_passwd_home); then
    _why="cannot read the account's passwd entry"
  fi
  if [ -z "$_home" ]; then
    printf '%s: NOTE account-home watch off (%s)\n' "$_tag" "$_why"
    return 0
  fi
  mkdir -p "$_sd" || return 1
  printf '%s' "$_home" > "$_sd/acct.home" || return 1
  : > "$_sd/acct.exist"
  for _p in $LW_ACCOUNT_ROOTS; do
    if [ -e "$_home/$_p" ] || [ -L "$_home/$_p" ]; then printf '%s\n' "$_p" >> "$_sd/acct.exist"; fi
  done
  : > "$_sd/acct.stamp" || return 1
  if [ -n "$_label" ]; then
    printf '%s: account-home watch on, %s\n' "$_tag" "$_label"
  else
    printf '%s: account-home watch on (%s)\n' "$_tag" "$_home"
  fi
}

# live_witness_account_end <state-dir> — one line per hit root in <state-dir>/acct.hits
# (up to five paths in all, files first); returns 1 on any hit. A no-op when the
# watch was off.
live_witness_account_end() {
  local _sd="$1" _home _existed _p _names _left=5 _hit=0 _n
  [ -f "$_sd/acct.home" ] || return 0
  _home=$(< "$_sd/acct.home")
  _existed=$(< "$_sd/acct.exist")
  : > "$_sd/acct.hits"
  for _p in $LW_ACCOUNT_ROOTS; do
    if [ -e "$_home/$_p" ] || [ -L "$_home/$_p" ]; then
      [ "$_left" -gt 0 ] || continue
      _names=$(_lw_names "$_home/$_p" "$_sd/acct.stamp" "$_home" "$_left")
      case "$_existed" in *"$_p"*) ;; *) [ -n "$_names" ] || _names="$_p" ;; esac
      [ -n "$_names" ] || continue
      _n=1
      case "$_names" in *,*) _n=$(printf '%s' "$_names" | tr -cd ',' | wc -c); _n=$((_n + 1)) ;; esac
      _left=$((_left - _n))
      printf '%s\n' "$_names" >> "$_sd/acct.hits"
      _hit=1
    else
      case "$_existed" in
        *"$_p"*) printf 'removed %s\n' "$_p" >> "$_sd/acct.hits"; _hit=1 ;;
      esac
    fi
  done
  [ "$_hit" -eq 0 ]
}

# --- CLI ---------------------------------------------------------------------
_lw_cli_summary() {
  [ "${_lw_summary_done:-0}" -eq 0 ] || return 0
  _lw_summary_done=1
  printf 'live-witness: on, %s, %s hits, cmd rc=%s\n' "${_lw_name:-?}" "${_lw_hits:-0}" "${_lw_cmdrc:-n/a}"
}

_lw_cli_run() {
  local _lane _home _hroot _file _rc _ahit=0 _hard=0 _line _tag
  _lw_name="" _lw_hits=0 _lw_cmdrc="" _lw_summary_done=0
  if [ "${1:-}" != --label ] || [ -z "${2:-}" ] || [ "${3:-}" != -- ] || [ -z "${4:-}" ]; then
    echo "usage: live-witness.sh run --label <name> -- <command...>" >&2
    return 2
  fi
  _lw_name="$2"
  shift 3
  _lane=$(tmpdir) || { echo "live-witness: cannot allocate a lane root" >&2; _lw_cli_summary; return 2; }
  # shellcheck disable=SC2064  # the lane path is fixed now
  trap "rm -rf '$_lane'; _lw_cli_summary" EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  _home="$_lane/home"
  _hroot="$_lane/handover-root"
  _file="${SUITE_LIVE_EXEMPT-$LW_DIR/live-write-exempt.txt}"
  if ! live_witness_exempt_load "$_file"; then
    echo "live-witness: $LW_EXEMPT_ERR" >&2
    return 2
  fi
  live_witness_seed "$_lane" "$_home" "$_hroot" || { echo "live-witness: cannot seed the decoy home" >&2; return 2; }
  live_witness_account_begin "$_lane/acct" live-witness "$_lw_name" || return 2
  ( live_witness_env "$_home"; exec "$@" )
  _lw_cmdrc=$?
  witness_msgs=""
  live_witness_check "$_lane" "$_home" "$_hroot"
  _tag=""
  live_witness_is_exempt "$_lw_name" && _tag="WARN "
  while IFS= read -r _line; do
    [ -n "$_line" ] || continue
    _lw_hits=$((_lw_hits + 1))
    printf '[LIVE-STATE] %s%s — %s\n' "$_tag" "$_lw_name" "$_line"
    [ -n "$_tag" ] || _hard=1
  done <<LWMSGS
$witness_msgs
LWMSGS
  if ! live_witness_account_end "$_lane/acct"; then
    _ahit=1
    while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      _lw_hits=$((_lw_hits + 1))
      # shellcheck disable=SC2016  # $HOME is text in the message
      printf '[LIVE-STATE] %s — wrote %s in the account home (the passwd entry, not $HOME); on the station this is the real ~/%s\n' \
        "$_lw_name" "$_line" "${_line%%,*}"
    done < "$_lane/acct/acct.hits"
  fi
  _rc="$_lw_cmdrc"
  if [ "$_hard" -eq 1 ] || [ "$_ahit" -eq 1 ]; then _rc=86; fi
  return "$_rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  case "${1:-}" in
    run) shift; _lw_cli_run "$@"; exit $? ;;
    *) echo "usage: live-witness.sh run --label <name> -- <command...>" >&2; exit 2 ;;
  esac
fi
