#!/usr/bin/env bash
# scripts/ci/claude-startup-row.sh -- the claude-startup rows of ci-quick.
#
#   claude-startup-row.sh <suite-path>
#       Record mode. Runs one scripts/testing suite and appends `ran <rc> <path>`
#       to the file named by CLAUDE_STARTUP_MANIFEST. The variable is read once
#       and unset, so the suite never sees it. It refuses with rc 2, running
#       nothing and writing nothing, when the variable is empty, the path is not
#       scripts/testing/test-<name>.sh, the path is not a regular file, or the
#       manifest cannot be created for append. It exits the suite's rc once the
#       row is written; when the append fails it exits 2 if the rc was 0.
#   claude-startup-row.sh --expected
#       Prints the scripts/testing/ entries of the SKIP_LIST in the
#       run-shell-tests.sh beside this script, one per line. Exits 2 when either
#       anchor is missing or the list is empty.
#   claude-startup-row.sh --verify <raw> <out>
#       Exits 0 and writes <out> only when <raw> holds exactly one well-formed
#       row per --expected path and no other line. <out>'s directory is removed
#       first, whatever happens, and is left absent on a refusal.
#
# Exit codes: record -- the suite's rc, or 2 on a refusal; --expected -- 0 ok,
# 2 a refusal; --verify -- 0 ok, 1 a bad raw file, 2 a refusal.
set -u

here="$(cd "$(dirname "$0")" && pwd)"

expected_set() {
  awk '
    $0 == "SKIP_LIST=\"" { open = 1; next }
    open && $0 == "\"" { closed = 1; exit }
    open {
      sub(/#.*/, "")
      if (NF > 0 && $1 ~ /^scripts\/testing\//) { print $1; n++ }
    }
    END { if (!open || !closed || n == 0) exit 2 }
  ' "$here/run-shell-tests.sh"
}

field3() {
  local f
  read -r _ _ f _ <<< "$1"
  printf '%s' "$f"
}

verify() {
  local raw="${1-}" out="${2-}" od rd set_ line p bad="" paths=""
  od="$(dirname "$out")"
  rd="$(dirname "$raw")"
  case "$od" in
    . | .. | */*)
      echo "claude-startup-row: refusing <out> directory '$od': it must be one relative component" >&2
      return 2
      ;;
  esac
  if [ "$od" = "$rd" ]; then
    echo "claude-startup-row: refusing <out> directory '$od': it is the raw file's directory" >&2
    return 2
  fi
  rm -rf "$od" || {
    echo "claude-startup-row: cannot remove '$od'" >&2
    return 2
  }
  set_="$(expected_set)" || {
    echo "claude-startup-row: cannot read the expected set" >&2
    return 2
  }

  if [ -r "$raw" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$line" | grep -qE '^ran (0|[1-9][0-9]{0,2}) (scripts/testing/test-[A-Za-z0-9._-]+\.sh)$' || bad="$bad$line
"
      paths="$paths$(field3 "$line")
"
    done <"$raw" # read-sink-ok: the raw rows file ci-quick uploaded, read only to validate its rows
  fi
  if [ -n "$bad" ]; then
    printf 'claude-startup-row: malformed row(s):\n%s' "$bad" >&2
    return 1
  fi

  if [ -r "$raw" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      printf '%s\n' "$set_" | grep -qxF -- "$(field3 "$line")" || bad="$bad$line
"
    done <"$raw" # read-sink-ok: the raw rows file ci-quick uploaded, read only to validate its rows
  fi
  if [ -n "$bad" ]; then
    printf 'claude-startup-row: row(s) for a path outside the expected set:\n%s' "$bad" >&2
    return 1
  fi

  if [ -r "$raw" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$(printf '%s' "$paths" | grep -cxF -- "$(field3 "$line")")" -le 1 ] || bad="$bad$line
"
    done <"$raw" # read-sink-ok: the raw rows file ci-quick uploaded, read only to validate its rows
  fi
  if [ -n "$bad" ]; then
    printf 'claude-startup-row: duplicated row(s):\n%s' "$bad" >&2
    return 1
  fi

  while IFS= read -r p; do
    printf '%s' "$paths" | grep -qxF -- "$p" || bad="$bad$p
"
  done <<EOF
$set_
EOF
  if [ -n "$bad" ]; then
    printf 'claude-startup-row: no row for expected suite(s):\n%s' "$bad" >&2
    return 1
  fi

  mkdir -p "$od" || return 2
  while IFS= read -r p; do
    while IFS= read -r line || [ -n "$line" ]; do
      [ "$(field3 "$line")" = "$p" ] || continue
      printf '%s\n' "$line" >>"$out" || {
        rm -rf "$od"
        return 2
      }
    done <"$raw" # read-sink-ok: the raw rows file ci-quick uploaded, read only to validate its rows
  done <<EOF
$set_
EOF
  return 0
}

record() {
  local suite="${1-}" m rc
  m="${CLAUDE_STARTUP_MANIFEST-}"
  unset CLAUDE_STARTUP_MANIFEST
  [ -n "$m" ] || {
    echo "claude-startup-row: CLAUDE_STARTUP_MANIFEST is empty" >&2
    return 2
  }
  printf '%s\n' "$suite" | grep -qE '^scripts/testing/test-[A-Za-z0-9._-]+\.sh$' || {
    echo "claude-startup-row: refusing '$suite'" >&2
    return 2
  }
  [ -f "$suite" ] || {
    echo "claude-startup-row: '$suite' is not a regular file" >&2
    return 2
  }
  mkdir -p "$(dirname "$m")" || return 2
  : >>"$m" || return 2
  bash "$suite"
  rc=$?
  if printf 'ran %s %s\n' "$rc" "$suite" >>"$m"; then
    return "$rc"
  fi
  [ "$rc" -eq 0 ] && return 2
  return "$rc"
}

case "${1-}" in
  --expected)
    expected_set
    exit $?
    ;;
  --verify)
    verify "${2-}" "${3-}"
    exit $?
    ;;
  *)
    record "$@"
    exit $?
    ;;
esac
