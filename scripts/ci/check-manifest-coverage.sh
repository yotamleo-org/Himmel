#!/usr/bin/env bash
# scripts/ci/check-manifest-coverage.sh — assert Dependabot watches every
# dependency manifest the repo tracks, and that each watched directory carries a
# release-age buffer.
#
#   1. coverage   every package.json has an npm entry in .github/dependabot.yml
#                 for its directory, every requirements*.txt a pip entry, every
#                 Dockerfile a docker entry — or sits under an EXEMPT prefix below.
#   2. age buffer a watched directory holding a bun lockfile has a bunfig.toml
#                 with [install] minimumReleaseAge >= 3 days (seconds), one with
#                 a package-lock.json has an .npmrc with min-release-age >= 3
#                 (days), one with a pip requirements file has a uv.toml with
#                 exclude-newer = "<N> days", N >= 3.
#
# Buffer caveat: npm reads min-release-age from 11.10 on. CI runs node 22 (npm 10),
# which ignores it, so on CI the guard is check-lockfile-release-age.mjs, not .npmrc.
#
# Usage:
#   check-manifest-coverage.sh [repo-root]    # default: the checkout this lives in
#
# Exit codes:
#   0 — every manifest is covered and buffered
#   1 — at least one violation (each is printed as `ERROR: ...`)
#   2 — the scan itself failed (no .github/dependabot.yml under the root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
DEP="$ROOT/.github/dependabot.yml"
[ -f "$DEP" ] || { printf 'ERROR: no .github/dependabot.yml under %s\n' "$ROOT" >&2; exit 2; }

MIN_DAYS=3
MIN_SECONDS=$((MIN_DAYS * 86400))

# prefix|reason — a manifest under a prefix is deliberately not watched.
EXEMPT=(
  ".github/claude-cli|bumped by hand together with CLAUDE_CLI_VERSION"
  "marketplace/plugins/claude-hud|vendored tree, moves on a re-vendor (its VENDORED.md)"
  "scripts/lanes/bench/fixtures|benchmark fixtures, never installed"
)

failures=0
err() { printf 'ERROR: %s\n' "$*"; failures=$((failures + 1)); }

# eco<TAB>/dir for every watched directory, from `directory:` and `directories:`.
watched=$(sed 's/^[[:space:]]*#.*$//' "$DEP" | awk '
  function clean(s) { sub(/[ \t]+#.*$/, "", s); gsub(/["\047 \t]/, "", s); return s }
  /^[ \t]*-[ \t]*package-ecosystem:/ { eco = $0; sub(/.*package-ecosystem:/, "", eco); eco = clean(eco); indirs = 0; next }
  /^[ \t]*directories:/ { indirs = 1; next }
  /^[ \t]*directory:/ { d = $0; sub(/.*directory:/, "", d); print eco "\t" clean(d); indirs = 0; next }
  indirs && /^[ \t]*-[ \t]*["\047]?\// { d = $0; sub(/^[ \t]*-[ \t]*/, "", d); print eco "\t" clean(d); next }
  indirs && !/^[ \t]*$/ { indirs = 0 }
')

# Tracked files when the root is a git checkout, else every file (test trees).
if [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ]; then # swallow-ok: not a git root means fall back to find
  files=$(git -C "$ROOT" ls-files) || { echo "manifest-coverage: git ls-files failed in $ROOT" >&2; exit 2; }
else
  files=$(cd "$ROOT" && find . -type f -not -path '*/node_modules/*' -not -path './.git/*' | sed 's|^\./||') || { echo "manifest-coverage: file discovery failed in $ROOT" >&2; exit 2; }
fi

exempt_reason() { # <path> -> reason on stdout, rc 0 when exempt
  local e
  for e in "${EXEMPT[@]}"; do
    case "$1" in "${e%%|*}"/*) printf '%s\n' "${e#*|}"; return 0 ;; esac
  done
  return 1
}

has_file() { grep -qxF -- "$1" <<< "$files"; }

# <dir>: the repo-relative directory, "" for the root.
check_buffer() { # <eco> <dir>
  local eco="$1" dir="$2" pre="${2:+$2/}" f v
  case "$eco" in
    npm)
      if has_file "${pre}bun.lock" || has_file "${pre}bun.lockb"; then
        f="$ROOT/${pre}bunfig.toml"
        v=$(awk '/^\[/ { sec = $0 } sec == "[install]" && /^[ \t]*minimumReleaseAge[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t#].*$/, ""); print; exit }' "$f" 2>/dev/null) # swallow-ok: a missing bunfig.toml reads empty and is reported as missing
        if [ -z "$v" ]; then err "${pre}bunfig.toml: no [install] minimumReleaseAge (bun lockfile present)"
        elif ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt "$MIN_SECONDS" ]; then err "${pre}bunfig.toml: minimumReleaseAge $v is below $MIN_SECONDS (3 days)"; fi
      fi
      if has_file "${pre}package-lock.json"; then
        f="$ROOT/${pre}.npmrc"
        v=$(sed -n 's/^[[:space:]]*min-release-age[[:space:]]*=[[:space:]]*\([0-9]*\)[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -1) # swallow-ok: a missing .npmrc reads empty and is reported as missing
        if [ -z "$v" ]; then err "${pre}.npmrc: no min-release-age (package-lock.json present)"
        elif [ "$v" -lt "$MIN_DAYS" ]; then err "${pre}.npmrc: min-release-age $v is below $MIN_DAYS days"; fi
      fi ;;
    pip)
      f="$ROOT/${pre}uv.toml"
      v=$(sed -n 's/^[[:space:]]*exclude-newer[[:space:]]*=[[:space:]]*"\([0-9]*\) days"[[:space:]]*$/\1/p' "$f" 2>/dev/null | head -1) # swallow-ok: a missing uv.toml reads empty and is reported as missing
      if [ -z "$v" ]; then err "${pre}uv.toml: no exclude-newer = \"N days\" (pip requirements present)"
      elif [ "$v" -lt "$MIN_DAYS" ]; then err "${pre}uv.toml: exclude-newer $v days is below $MIN_DAYS"; fi ;;
  esac
}

manifests=0 exempt=0
buffered=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  case "${path##*/}" in
    package.json) eco=npm ;;
    requirements*.txt) eco=pip ;;
    Dockerfile) eco=docker ;;
    *) continue ;;
  esac
  manifests=$((manifests + 1))
  if exempt_reason "$path" >/dev/null; then exempt=$((exempt + 1)); continue; fi
  dir="${path%/*}"; [ "$dir" = "$path" ] && dir=""
  if ! grep -qxF -- "$eco	/$dir" <<< "$watched"; then
    err "$path: no $eco entry for /$dir in .github/dependabot.yml (add one, or exempt it in check-manifest-coverage.sh with a reason)"
    continue
  fi
  case " $buffered " in *" $eco:$dir "*) ;; *) buffered="$buffered $eco:$dir"; check_buffer "$eco" "$dir" ;; esac
done <<< "$files"

printf 'manifest-coverage: %d manifest(s), %d exempt, %d violation(s)\n' "$manifests" "$exempt" "$failures"
[ "$failures" -eq 0 ]
