#!/usr/bin/env bash
# scripts/ci/check-ci-install-locks.sh — assert every package install the CI
# runs is locked to artifacts we reviewed, not to whatever a registry serves
# that day.
#
#   1. pip     every `pip install` in .github/workflows/*.yml and the CI image
#              Dockerfile is `--require-hashes -r <file>`, and every entry of
#              that file carries a --hash=sha256: (the whole closure, not just
#              the top-level pins).
#   2. npm/bun every `npm ci`, `npm install` and `bun install` carries
#              --ignore-scripts, unless that line (or the comment line right
#              above it) holds `install-scripts-ok: <reason>`.
#   3. claude  the claude CLI is never `npm install`ed by name: it comes from
#              .github/claude-cli/package-lock.json (sha512 integrity), whose
#              version equals ci.yml's CLAUDE_CLI_VERSION.
#   4. shellcheck-py   the version in requirements-shellcheck.txt equals the
#              rev the pre-commit hook pins in .pre-commit-config.yaml.
#   5. dependabot      every package-ecosystem has a cooldown of at least
#              3 days, and a pip entry exists while requirements files do.
#
# Line-based, like check-actions-pinned.sh: backslash continuations are joined,
# full-line comments dropped, and each `&&` / `||` / `;` / `|` segment is checked
# alone, so `cd x && bun install` cannot hide an unguarded second install.
#
# Usage:
#   check-ci-install-locks.sh [repo-root]    # default: the checkout this lives in
#
# Exit codes:
#   0 — every install is locked
#   1 — at least one violation (each is printed as `ERROR: file:line: ...`)
#   2 — the scan itself failed (no .github/ under the root)
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
GH="$ROOT/.github"
IMG="$GH/ci-image"
[ -d "$GH" ] || { printf 'ERROR: no .github/ under %s\n' "$ROOT" >&2; exit 2; }

MIN_COOLDOWN_DAYS=3
failures=0
err() { printf 'ERROR: %s\n' "$*"; failures=$((failures + 1)); }

# Emits one record per command segment: file<TAB>line<TAB>marker<TAB>segment.
# marker=1 when the segment's logical line, or the raw line above it, holds
# `install-scripts-ok:`.
segments() {
  awk '
    function flush(   n, i, parts, seg) {
      if (acc == "") return
      line = acc; sub(/[ \t]#.*$/, "", line)
      n = split(line, parts, /&&|\|\||;|\|/)
      for (i = 1; i <= n; i++) {
        seg = parts[i]; gsub(/^[ \t]+|[ \t]+$/, "", seg)
        if (seg != "") printf "%s\t%d\t%d\t%s\n", FILENAME, start, mark, seg
      }
      acc = ""
    }
    FNR == 1 { flush(); prev = "" }
    {
      raw = $0
      if (acc == "") {
        if (raw ~ /^[ \t]*#/) { prev = raw; next }
        start = FNR
        mark = (raw ~ /install-scripts-ok:/ || prev ~ /install-scripts-ok:/) ? 1 : 0
      } else if (raw ~ /install-scripts-ok:/) mark = 1
      if (raw ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", raw); acc = acc raw " "; next }
      acc = acc raw
      flush()
      prev = $0
    }
    END { flush() }
  ' "$@"
}

# A requirements file named by `-r X`: relative to the root, else by basename
# under the CI image directory (the Dockerfile COPYs it from there).
resolve_req() {
  local want="$1"
  want="${want%\"}"; want="${want#\"}"
  if [ -f "$ROOT/$want" ]; then printf '%s\n' "$ROOT/$want"
  elif [ -f "$IMG/${want##*/}" ]; then printf '%s\n' "$IMG/${want##*/}"
  fi
}

# Every requirement in the file is hashed (an unhashed transitive dependency
# is the hole --require-hashes exists to close).
check_req_file() {
  local f="$1" rel="${1#"$ROOT"/}" out
  out=$(awk '
    { sub(/[ \t]+#.*$/, "") }
    /^[ \t]*$/ || /^[ \t]*#/ { next }
    { if ($0 ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, ""); acc = acc $0 " "; next }
      line = acc $0; acc = ""
      if (line ~ /^[ \t]*-/) next
      n++
      if (!match(line, /--hash=sha256:[0-9a-f]+/) || RLENGTH != 78) printf "entry without a sha256 hash: %s\n", line
    }
    END { if (n == 0) print "no requirements listed" }
  ' "$f")
  [ -n "$out" ] && while IFS= read -r l; do err "$rel: $l"; done <<< "$out"
}

files=()
for f in "$GH"/workflows/*.yml "$GH"/workflows/*.yaml "$IMG/Dockerfile"; do
  [ -f "$f" ] && files+=("$f")
done

if [ "${#files[@]}" -gt 0 ]; then
  recs=$(segments "${files[@]}")
else
  recs=""
fi

checked_reqs=""
pip_re='(^|[^[:alnum:]_.-])pip3?[[:space:]]+install([[:space:]]|$)'
npm_re='(^|[^[:alnum:]_.-])(npm[[:space:]]+(ci|install)|bun[[:space:]]+install)([[:space:]]|$)'
claude_re='npm[[:space:]]+(i|install|add)[[:space:]].*@anthropic-ai/claude-code'
while IFS=$'\t' read -r file line mark seg; do
  [ -n "$seg" ] || continue
  rel="${file#"$ROOT"/}:$line"
  if [[ "$seg" =~ $pip_re ]]; then
    if [[ "$seg" != *--require-hashes* ]]; then
      err "$rel: pip install without --require-hashes: $seg"
    fi
    reqs=()
    rest="$seg"
    while [[ "$rest" =~ (^|[[:space:]])(-r|--requirement)(=|[[:space:]]+)([^[:space:]]+)(.*)$ ]]; do
      reqs+=("${BASH_REMATCH[4]}")
      rest="${BASH_REMATCH[5]}"
    done
    if [ "${#reqs[@]}" -eq 0 ]; then
      err "$rel: pip install names no hashed requirements file (-r <file>): $seg"
    fi
    for req in "${reqs[@]+"${reqs[@]}"}"; do
      path=$(resolve_req "$req")
      if [ -z "$path" ]; then
        err "$rel: requirements file not found: $req"
      else
        case " $checked_reqs " in *" $path "*) ;; *) checked_reqs="$checked_reqs $path"; check_req_file "$path" ;; esac
      fi
    done
  fi
  if [[ "$seg" =~ $claude_re ]]; then
    err "$rel: claude-code installed by name; install it from the lockfile in .github/claude-cli/: $seg"
  elif [[ "$seg" =~ $npm_re ]] && [[ "$seg" != *--ignore-scripts* ]] && [ "$mark" != 1 ]; then
    err "$rel: install scripts enabled (add --ignore-scripts, or an install-scripts-ok: <reason> comment): $seg"
  fi
done <<< "$recs"

# claude CLI lock: the lockfile pins the version and its sha512, and ci.yml's
# CLAUDE_CLI_VERSION (read by the claude-startup suites) names the same one.
cli_pin=$(sed -n "s/^ *CLAUDE_CLI_VERSION: '\([0-9][0-9.]*\)'.*/\1/p" "$GH/workflows/ci.yml" | sed -n 1p)
if [ -n "$cli_pin" ]; then
  lock="$GH/claude-cli/package-lock.json"
  if [ ! -f "$lock" ]; then
    err ".github/claude-cli/package-lock.json missing (the claude CLI would install unlocked)"
  else
    lock_ver=$(awk '/"node_modules\/@anthropic-ai\/claude-code": *\{/ {f=1; next} f && /"version":/ {gsub(/[",]/, ""); print $2; exit}' "$lock")
    lock_int=$(awk '/"node_modules\/@anthropic-ai\/claude-code": *\{/ {f=1; next} f && /"integrity": *"sha512-/ {print "ok"; exit}' "$lock")
    [ "$lock_ver" = "$cli_pin" ] || err ".github/claude-cli/package-lock.json locks claude-code '${lock_ver:-none}' but ci.yml CLAUDE_CLI_VERSION is '$cli_pin' (bump both)"
    [ "$lock_int" = ok ] || err ".github/claude-cli/package-lock.json: claude-code has no sha512 integrity"
  fi
fi

# The shellcheck-py wheel: one rev, two files.
req_sc="$IMG/requirements-shellcheck.txt"
if [ -f "$req_sc" ]; then
  want=$(awk '/repo:.*shellcheck-py/ {f=1; next} f && /rev:/ {sub(/^.*rev:[ ]*v?/, ""); print; exit}' "$ROOT/.pre-commit-config.yaml")
  have=$(sed -n 's/^shellcheck-py==\([0-9.]*\).*/\1/p' "$req_sc" | sed -n 1p)
  [ -n "$want" ] && [ "$want" = "$have" ] || err ".github/ci-image/requirements-shellcheck.txt pins shellcheck-py '${have:-none}' but .pre-commit-config.yaml pins '${want:-none}'"
fi

# dependabot: a cooldown on every ecosystem.
dep="$GH/dependabot.yml"
if [ -f "$dep" ]; then
  out=$(awk -v min="$MIN_COOLDOWN_DAYS" '
    function close_block() {
      if (eco == "") return
      if (days == "") printf "dependabot %s: no cooldown.default-days\n", eco
      else if (days + 0 < min) printf "dependabot %s: cooldown %s days is below %d\n", eco, days, min
      if (eco == "pip") pip = 1
    }
    /^[ \t]*-[ \t]*package-ecosystem:/ {
      close_block(); eco = $0; sub(/^.*package-ecosystem:[ \t]*/, "", eco); gsub(/["\047 \t]/, "", eco); days = ""; next
    }
    /^[ \t]+default-days:/ && eco != "" { d = $0; sub(/^.*default-days:[ \t]*/, "", d); sub(/[ \t#].*$/, "", d); days = d }
    END { close_block(); if (!pip) print "dependabot: no pip ecosystem entry" }
  ' "$dep")
  if [ -n "$out" ]; then
    while IFS= read -r l; do
      case "$l" in
        "dependabot: no pip ecosystem entry")
          ls "$IMG"/requirements*.txt >/dev/null 2>&1 && err ".github/dependabot.yml: no pip ecosystem entry for the requirements files in .github/ci-image/" ;;
        *) err ".github/dependabot.yml: ${l#dependabot }" ;;
      esac
    done <<< "$out"
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '%d install-lock violation(s). See scripts/ci/check-ci-install-locks.sh for the rules.\n' "$failures"
  exit 1
fi
exit 0
