#!/usr/bin/env bash
# check-added-unwired.sh — fail when a file a PR ADDS is a hook, script, skill or
# suite that nothing reaches. Ready-check item 11 feeds it the
# diff's status-A files; existing debt is never judged.
#
# Everything is read from <ref>'s tree (the PR head), so wiring the PR adds in
# the same diff counts. "Wired" per kind:
#   hook   scripts/hooks/<name>.sh|js|mjs (not test-*, lib-*, *.test.*, runner tooling):
#          its basename appears in a file of the WIRING list parsed out of
#          scripts/testing/check-unwired-hooks.sh (the one notion of wired), or it
#          is on scripts/testing/unwired-hooks-allowlist.txt.
#   suite  test-*.sh: scripts/ci/run-shell-tests.sh finds it (scan roots scripts,
#          templates, marketplace, packaging) and suite-coverage.sh does not call it
#          SKIP_LIST. *.test.*: another WIRED file names it (a wrapper suite runs
#          it), a .github/workflows job runs bun test / node --test / vitest / jest
#          on a directory above it, or a package.json above it has a "test" script
#          whose runner's discovery reaches it (path args narrow; node --test
#          reaches only JS unless the script loads a TS transform).
#   hooklib scripts/hooks/<subdir>/*: a wired hook, or another live library under
#          scripts/hooks/, names its basename (sourced). Judged read-only.
#   skill  SKILL.md under <plugin>/skills/<name>/ where <plugin> has
#          .claude-plugin/plugin.json (a marketplace/plugins/<p> must also be named in
#          marketplace/.claude-plugin/marketplace.json), or under .claude/skills/ or
#          .agents/skills/ (discovered by directory).
#   script a .sh/.mjs/.js/.ts/.py file under scripts/, or any scripts/ file with the
#          executable bit: some OTHER non-test, non-doc file at <ref> names its
#          basename (settings, runner, CI job, doctor check, caller, a sourcing
#          script, or a runbook/cadence doc: operator-run tools are wired by the doc
#          that says when to run them; a suite or handovers/ file never counts).
#          A referencer that is itself an unwired added file does not count.
#          A test helper (under a tests?/ or *-cases/ dir, or named testlib-*) is also
#          wired by a suite that names it; an added suite still unwired does not count.
# Standalone by design (no reference needed): fixtures/testdata paths, ALLOW_PATH_RE.
#
# Usage: check-added-unwired.sh <ref> <added-file>...   (run inside the repo)
# Exit: 0 clean, 1 unwired file(s), 2 usage / unreadable ref.
# Platform guard (gitbash-only): POSIX bash 3.2+, no mapfile.
set -uo pipefail

ALLOW_PATH_RE='(^|/)(fixtures|testdata|node_modules)/'
TEST_HELPER_RE='(^|/)(tests?|[^/]*-cases)/|(^|/)testlib-[^/]*$'

if [ "$#" -lt 2 ]; then
  echo "usage: check-added-unwired.sh <ref> <added-file>..." >&2
  exit 2
fi
ref="$1"; shift
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
top=$(git rev-parse --show-toplevel) || exit 2

tmp=$(mktemp -d "${TMPDIR:-/tmp}/added-unwired.XXXXXX") || exit 2
trap 'rm -rf "$tmp"' EXIT

show() { git show "$ref:$1" 2>/dev/null; }
exists() { git cat-file -e "$ref:$1" 2>/dev/null; }
# whole-basename match: not-foo.sh must not reference foo.sh
bn_re() { printf '(^|[^A-Za-z0-9._-])%s([^A-Za-z0-9._-]|$)' "${1//./\\.}"; }

# pkg_runs <pkg dir, "" = root> <file> — the package.json test script runs a known
# runner whose discovery reaches <file> (path args narrow it; bare = whole package)
pkg_runs() {
  local pd="$1" f="$2" ts rel tok prev="" pre have=0 hit=0 pj="package.json"
  [ -z "$pd" ] || pj="$pd/package.json"
  ts=$(show "$pj" | jq -r '.scripts.test // empty' 2>/dev/null)
  case "$ts" in *"bun test"*|*"node --test"*|*vitest*|*jest*) ;; *) return 1 ;; esac
  case "$ts" in  # node --test globs only reach JS unless the script loads a TS transform
    *"bun test"*|*vitest*|*jest*) ;;
    *) case "${f##*/}" in *.js|*.mjs|*.cjs) ;; *) case "$ts" in *strip-types*|*tsx*|*--import*|*--loader*) ;; *) return 1 ;; esac ;; esac ;;
  esac
  rel="$f"; [ -z "$pd" ] || rel="${f#"$pd"/}"
  # only the words after the runner, up to the next command, can narrow discovery
  ts=$(printf '%s' "$ts" | sed -E 's/.*(bun test|node --test|vitest( run)?|jest)//; s/(&&|;|\|).*//')
  set -f
  for tok in $ts; do
    tok="${tok//[\"\']/}"; tok="${tok#./}"
    case "$tok" in -*|'&&'|';'|'|'|'||'|'') prev="$tok"; continue ;; esac
    # a bare word is a path when it exists, or when it is not an option's value (--reporter dot)
    case "$tok" in *[/*?\{[]*) ;; *) exists "${pd:+$pd/}$tok" || case "$prev" in -*) prev="$tok"; continue ;; esac ;; esac
    prev="$tok"
    have=1; pre="${tok%%[*?{[]*}"; pre="${pre%/}"
    case "$rel" in "$pre"|"$pre"/*) hit=1 ;; esac
    [ -n "$pre" ] || hit=1
  done
  set +f
  [ "$have" -eq 0 ] || [ "$hit" -eq 1 ]
}

# kind_of <path> — hook|hooklib|suite|skill|script|none
kind_of() {
  local p="$1" b="${1##*/}"
  case "$p" in *SKILL.md) printf skill; return ;; esac
  case "$b" in test-*.sh|*.test.*) printf suite; return ;; esac
  case "$p" in
    scripts/hooks/*/*) printf hooklib; return ;;
    scripts/hooks/*)
      case "$b" in lib-*|run-hook-with-bash.js|wire-hook-bash.mjs|wire-plugin-hook-bash.mjs|bench-hook-stack.mjs) printf none; return ;; esac
      case "$b" in *.sh|*.js|*.mjs) printf hook; return ;; esac ;;
    scripts/*)
      case "$b" in *.sh|*.mjs|*.js|*.ts|*.py) printf script; return ;; esac
      git ls-tree "$ref" -- "$p" | grep -q '^100755' && { printf script; return; } ;;
  esac
  printf none
}

wiring_text=""
if exists scripts/testing/check-unwired-hooks.sh; then
  wl=$(show scripts/testing/check-unwired-hooks.sh | sed -n '/^WIRING=(/,/^)/p' | grep -E '^[[:space:]]+[A-Za-z.]' | tr -d ' ')
  while IFS= read -r w; do
    [ -n "$w" ] && exists "$w" && wiring_text="$wiring_text$(show "$w")"$'\n'
  done <<EOF
$wl
EOF
fi
hook_allow=$(show scripts/testing/unwired-hooks-allowlist.txt | awk -F'|' '$1 !~ /^#/ && $2 != "" {print $1}')

runner="$tmp/run-shell-tests.sh"
show scripts/ci/run-shell-tests.sh > "$runner"

judge() {  # <path> <kind> -> prints a reason when unwired
  local p="$1" k="$2" b="${1##*/}" d plug
  case "$k" in
    hook)
      printf '%s\n' "$wiring_text" | grep -qE -- "$(bn_re "$b")" && return 0
      printf '%s\n' "$hook_allow" | grep -qxF -- "$b" && return 0
      echo "no hook wiring file names it and it is not on unwired-hooks-allowlist.txt" ;;
    suite)
      case "$b" in
        test-*.sh)
          case "$p" in scripts/*|templates/*|marketplace/*|packaging/*) ;; *) echo "outside the runner's scan roots, so run-shell-tests.sh never finds it"; return 0 ;; esac
          [ -s "$runner" ] || { echo "cannot read scripts/ci/run-shell-tests.sh at $ref"; return 0; }
          cov=$(bash "$HERE/../handover/suite-coverage.sh" --runner "$runner" --root "$top" "$p" 2>&1)
          printf '%s\n' "$cov" | grep -qE 'runs in PR CI|nightly only|superseded by' \
            || echo "run-shell-tests.sh skips it (SKIP_LIST) or cannot classify it" ;;
        *)
          # a node/bun test file is run by a wrapper that names it, when that wrapper is itself wired
          git grep -lIE -e "$(bn_re "$b")" "$ref" -- . ':(exclude)handovers' 2>/dev/null | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
          while IFS= read -r r; do
            [ -n "$r" ] || continue
            grep -q "|$r\$" "$tmp/pending" || return 0
          done < "$tmp/refs"
          # a CI job that runs the test command on a directory above it
          d="${p%/*}"
          while :; do
            dre=$(printf '%s' "$d" | sed 's/[.+]/\\&/g')
            git grep -qIE -e "(bun test|node --test|vitest|jest)[^#]*[ '\"]${dre}(/?|/[^ /'\"]*\\*[^ '\"]*)( |\$|'|\")" -e "cd ${dre}/?[ ;&'\"][^#]*(bun|node|vitest|jest)" "$ref" -- .github/workflows 2>/dev/null && return 0
            [ "$d" = "${d%/*}" ] && break
            d="${d%/*}"
          done
          d="${p%/*}"
          while :; do
            exists "$d/package.json" && pkg_runs "$d" "$p" && return 0
            [ "$d" = "${d%/*}" ] && break
            d="${d%/*}"
          done
          exists package.json && pkg_runs "" "$p" && return 0
          echo "no wired file names it and no package.json test script above it runs a runner that discovers it" ;;
      esac ;;
    hooklib)
      # a library under scripts/hooks/<subdir>/ is sourced by a wired hook (or another live library)
      pat="$(bn_re "$b")"
      git grep -lIE -e "$pat" "$ref" -- scripts/hooks 2>/dev/null | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        rb="${r##*/}"
        case "$(kind_of "$r")" in
          hook) printf '%s\n' "$wiring_text" | grep -qE -- "$(bn_re "$rb")" && return 0
                printf '%s\n' "$hook_allow" | grep -qxF -- "$rb" && return 0 ;;
          suite) printf '%s\n' "$p" | grep -qE "$TEST_HELPER_RE" && { grep -q "|$r\$" "$tmp/pending" || return 0; } ;;
          *) grep -q "|$r\$" "$tmp/pending" || return 0 ;;
        esac
      done < "$tmp/refs"
      echo "no wired hook (or live hook library) in scripts/hooks names it" ;;
    skill)
      case "$p" in .claude/skills/*|.agents/skills/*) return 0 ;; esac
      plug="${p%%/skills/*}"
      if [ "$plug" = "$p" ] || ! exists "$plug/.claude-plugin/plugin.json"; then
        echo "not under .claude/skills, .agents/skills or a plugin with .claude-plugin/plugin.json"
      else
        case "$plug" in marketplace/plugins/*)
          show marketplace/.claude-plugin/marketplace.json | grep -qF "\"./plugins/${plug##*/}\"" \
            || echo "plugin ${plug##*/} is not listed in marketplace/.claude-plugin/marketplace.json" ;;
        esac
      fi ;;
    script)
      pat="$(bn_re "$b")"
      case "$b" in  # TS/JS import without the extension: from './sector.js', require('./sector')
        *.ts|*.tsx|*.js|*.mjs) pat="$pat|/${b%.*}(\\.[jt]sx?|\\.mjs)?['\"]" ;;
      esac
      if printf '%s\n' "$p" | grep -qE "$TEST_HELPER_RE"; then
        # a test helper is reached by the suite that uses it
        git grep -lIE -e "$pat" "$ref" -- . ':(exclude)handovers' 2>/dev/null
      else
        git grep -lIE -e "$pat" "$ref" -- . ':(exclude)handovers' ':(exclude,glob)**/test-*' ':(exclude,glob)**/*.test.*' 2>/dev/null
      fi | sed "s#^$ref:##" | grep -vxF "$p" > "$tmp/refs" || true
      # an added referencer still unwired itself does not count
      while IFS= read -r r; do
        [ -n "$r" ] || continue
        grep -q "|$r\$" "$tmp/pending" || return 0
      done < "$tmp/refs"
      echo "no wiring, runner, CI job or wired script names it" ;;
  esac
}

git cat-file -e "$ref^{commit}" 2>/dev/null || { echo "check-added-unwired: cannot read $ref" >&2; exit 2; }

: > "$tmp/added"; : > "$tmp/wired"; : > "$tmp/pending"
for f in "$@"; do
  printf '%s\n' "$f" >> "$tmp/added"
done
for f in "$@"; do
  k=$(kind_of "$f")
  [ "$k" = none ] && continue
  printf '%s\n' "$f" | grep -qE "$ALLOW_PATH_RE" && continue
  printf '%s|%s\n' "$k" "$f" >> "$tmp/pending"
done

# Fixpoint: an added library counts once a wired added script sources it.
report=""
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0; : > "$tmp/next"; report=""
  while IFS='|' read -r k f; do
    [ -n "$f" ] || continue
    why=$(judge "$f" "$k")
    if [ -z "$why" ]; then
      printf '%s\n' "$f" >> "$tmp/wired"; changed=1
    else
      printf '%s|%s\n' "$k" "$f" >> "$tmp/next"
      report="$report$(printf 'UNWIRED %s (%s): %s' "$f" "$k" "$why")"$'\n'
    fi
  done < "$tmp/pending"
  mv "$tmp/next" "$tmp/pending"
done
if [ -s "$tmp/pending" ]; then
  printf '%s' "$report"
  exit 1
fi
echo "ADDED-UNWIRED OK"
exit 0
