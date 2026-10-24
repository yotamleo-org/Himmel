#!/usr/bin/env bash
# selector: tree-scan
# scripts/ci/test-billed-optin.sh — lint + suite for the billed-path opt-in convention.
#
# Anything that can make a real, billed model call (claude -p/--print/--bg, codex exec, the
# Anthropic / OpenRouter message APIs, or a wrapper that reaches them) runs only on demand.
# One convention, fleet-wide: the script itself refuses (exit 2, or a loud SKIP exit 0 for a
# suite) unless it was given `--billed` or `HIMMEL_BILLED_OK=1`, and says so in a header line:
#
#   # billed-opt-in: --billed|HIMMEL_BILLED_OK   the script tests the token(s) it names
#   # billed-opt-in: arming                      an operator-armed cadence: arming is the opt-in
#   # billed-exempt: <reason>                    a wrapper/launcher/text-only mention, no call of its own
#
#   bash scripts/ci/test-billed-optin.sh          lints the repo, then runs the RED rows.
#   bash scripts/ci/test-billed-optin.sh --lint [--root D] [--tracked F]
#                                                 the lint alone: one FAIL line per violation,
#                                                 exit 0 clean / 1 violations / 2 usage.
#
# Rules (a source file is *.sh *.py *.mjs *.js *.ts, minus docs/, fixtures/, dist/, hooks/, *.test.*):
#   - a non-comment line matching the billed-call pattern needs a header;
#   - a suite (test-*.sh) is only linted when its name ends -live (a hermetic suite stubs the
#     binary, so its fixtures would match the pattern); a -live suite always needs a header;
#   - `billed-opt-in:` names only --billed and/or HIMMEL_BILLED_OK, and the file must test each
#     on a non-comment line; `arming` needs a *-cadence.sh script that is, or names, this file;
#   - `billed-exempt:` needs a reason.
# ponytail: the token check is "appears on a non-comment line", not "guards the first call";
# the refusal rows below run each marked script without the opt-in and prove it, upgrade path
# is a per-script row for every new guard.
# shellcheck disable=SC1003,SC2016,SC2094  # fixture bodies are literal text; the list is only read
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

RE='(^|[^A-Za-z0-9_./-])claude[[:space:]]+(-p|--print|--bg)([[:space:]]|$)|(^|[^A-Za-z0-9_./-])claude[[:space:]]+-[^|;&#]*[[:space:]](-p|--print|--bg)([[:space:]]|$)|"?\$\{?[A-Za-z_]*CLAUDE[A-Za-z_]*\}?"?[[:space:]]+(-p|--print|--bg)([[:space:]]|$)|["'"'"']claude["'"'"'],[[:space:]]*["'"'"'](-p|--print|--bg)|(^|[^A-Za-z0-9_./-])codex[[:space:]]+exec([[:space:]]|$)|["'"'"']codex["'"'"'],[[:space:]]*["'"'"']exec|(spawn|spawnSync|execFile|execFileSync)\([[:space:]]*["'"'"']claude["'"'"']|api\.anthropic\.com/v1/messages|openrouter\.ai/api/v1/(chat|completions|responses)|claude-api\.sh|claude-headless\.sh|llm-backend\.sh|claude-lane\.sh'
SKIP_RE='(^|/)(fixtures|node_modules|dist)/|^docs/|^graphify-out/|^scripts/hooks/|claude-hud|\.test\.'
HDR_RE='^[[:space:]]*(#|//)[[:space:]]*billed-(opt-in|exempt):'
NONCOMMENT_RE='^[[:space:]]*(#|//|\*)'

noncomment() { grep -v -E "$NONCOMMENT_RE" "$1"; }

# <n>:<text> per logical line, backslash continuations joined, n = its first physical line
logical() {
  awk '{ if (cur == "") start = NR; line = $0
         if (line ~ /\\$/ && line !~ /^[ \t]*(#|\/\/|\*)/) { sub(/\\$/, " ", line); cur = cur line; next }
         print start ":" cur line; cur = "" }
       END { if (cur != "") print start ":" cur }' "$1"
}

lint() { # <root> <tracked-list>
  local root=$1 list=$2 bad=0 f base hdr hit kind val tok ok c
  [ -r "$list" ] || { echo "FAIL tracked list unreadable: $list"; return 1; }
  while IFS= read -r f; do
    case "$f" in *.sh|*.py|*.mjs|*.js|*.ts) ;; *) continue ;; esac
    printf '%s\n' "$f" | grep -q -E "$SKIP_RE" && continue
    [ -f "$root/$f" ] || continue
    base=${f##*/}
    hdr=$(grep -m1 -E "$HDR_RE" "$root/$f")
    hit=""
    case "$base" in
      test-*-live.sh) hit="1" ;;
      test-*|*.test.*) ;;
      *) hit=$(logical "$root/$f" | grep -E "$RE" | grep -v -E '^[0-9]+:[[:space:]]*(#|//|\*)' | head -1 | cut -d: -f1) ;;
    esac
    if [ -z "$hdr" ]; then
      if [ -n "$hit" ]; then echo "FAIL unmarked billed call: $f:$hit"; bad=1; fi
      continue
    fi
    kind=$(printf '%s' "$hdr" | sed -E 's/^[[:space:]]*(#|\/\/)[[:space:]]*billed-(opt-in|exempt):[[:space:]]*.*$/\2/')
    val=$(printf '%s' "$hdr" | sed -E 's/^[[:space:]]*(#|\/\/)[[:space:]]*billed-(opt-in|exempt):[[:space:]]*(.*)$/\3/')
    if [ "$kind" = exempt ]; then
      [ -n "$val" ] || { echo "FAIL billed-exempt needs a reason: $f"; bad=1; }
      continue
    fi
    if [ "$val" = arming ]; then
      case "$base" in *-cadence.sh) continue ;; esac
      ok=0
      while IFS= read -r c; do
        [ -f "$root/$c" ] && grep -q -F -- "$base" "$root/$c" && { ok=1; break; }
      done <<EOF
$(grep -E '(^|/)[^/]*-cadence\.sh$' "$list" | grep -v -E '(^|/)test-')
EOF
      [ "$ok" = 1 ] || { echo "FAIL billed-opt-in arming but no cadence script runs it: $f"; bad=1; }
      continue
    fi
    for tok in $(printf '%s' "$val" | tr '|' ' '); do
      case "$tok" in
        --billed|HIMMEL_BILLED_OK) ;;
        *) echo "FAIL billed-opt-in names an unknown token ($tok): $f"; bad=1; continue ;;
      esac
      noncomment "$root/$f" | grep -F -- "$tok" >/dev/null || { echo "FAIL billed-opt-in names $tok but the script never tests it: $f"; bad=1; }
    done
    [ -n "$val" ] || { echo "FAIL billed-opt-in names no token: $f"; bad=1; }
  done < "$list"
  return $bad
}

if [ "${1:-}" = "--lint" ]; then
  shift
  root="$REPO_ROOT"; tracked=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root|--tracked)
        [ $# -ge 2 ] || { echo "usage: $0 --lint [--root D] [--tracked F]" >&2; exit 2; }
        if [ "$1" = --root ]; then root="$2"; else tracked="$2"; fi ;;
      *) echo "usage: $0 --lint [--root D] [--tracked F]" >&2; exit 2 ;;
    esac
    shift 2
  done
  if [ -z "$tracked" ]; then
    tracked=$(mktemp "${TMPDIR:-/tmp}/billed-optin-tracked.XXXXXX") || exit 1
    trap 'rm -f "$tracked"' EXIT
    git -C "$root" ls-files > "$tracked" || { echo "FAIL git ls-files failed"; exit 1; }
  fi
  lint "$root" "$tracked"
  exit $?
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/billed-optin.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

echo "== repo: every billed call in the tree is marked"
if bash "$SELF" --lint > "$tmp/repo.out" 2>&1; then
  pass "the repo lints clean"
else
  fail "the repo does not lint clean"
  head -40 "$tmp/repo.out"
fi

# Fixture tree: one file per case; the tracked list names them all.
fx="$tmp/fx"; mkdir -p "$fx/scripts/x" "$fx/scripts/cad"
put() { mkdir -p "$fx/$(dirname "$1")"; printf '%s\n' "${@:2}" > "$fx/$1"; printf '%s\n' "$1" >> "$tmp/tracked"; }
: > "$tmp/tracked"
put scripts/x/clean.sh '#!/usr/bin/env bash' 'echo no model here'
put scripts/x/unmarked.sh '#!/usr/bin/env bash' 'timeout 60 claude -p "hi" --model haiku'
put scripts/x/marked-env.sh '#!/usr/bin/env bash' '# billed-opt-in: HIMMEL_BILLED_OK' '[ "${HIMMEL_BILLED_OK:-}" = 1 ] || exit 2' 'claude -p "hi"'
put scripts/x/marked-flag.sh '#!/usr/bin/env bash' '# billed-opt-in: --billed|HIMMEL_BILLED_OK' 'case "$1" in --billed) ;; *) [ "${HIMMEL_BILLED_OK:-}" = 1 ] || exit 2 ;; esac' 'codex exec "hi"'
put scripts/x/names-untested.sh '#!/usr/bin/env bash' '# billed-opt-in: HIMMEL_BILLED_OK' 'claude -p "hi"'
put scripts/x/names-in-comment-only.sh '#!/usr/bin/env bash' '# billed-opt-in: --billed' '# pass --billed' 'claude --print "hi"'
put scripts/x/unknown-token.sh '#!/usr/bin/env bash' '# billed-opt-in: --yes' 'claude -p "hi"' 'echo --yes'
put scripts/x/exempt.sh '#!/usr/bin/env bash' '# billed-exempt: wrapper, callers carry the marker' 'claude -p "$@"'
put scripts/x/exempt-empty.sh '#!/usr/bin/env bash' '# billed-exempt:' 'claude -p "$@"'
put scripts/x/comment-only.sh '#!/usr/bin/env bash' '# runs claude -p in the real thing' 'echo done'
put scripts/x/opt-before-p.sh '#!/usr/bin/env bash' 'claude --model haiku -p "hi"'
put scripts/x/continued.sh '#!/usr/bin/env bash' 'claude \' '  --model haiku \' '  -p "hi"'
put scripts/x/comment-cont.sh '#!/usr/bin/env bash' '# a comment ending in a backslash \' 'claude -p "hi"'
put scripts/x/py-argv.py '#!/usr/bin/env python3' 'argv = ["claude", "-p", "hi"]'
put scripts/x/js-spawn.mjs 'const r = spawnSync("claude", ["-p"]);'
put scripts/x/api.sh '#!/usr/bin/env bash' 'curl https://api.anthropic.com/v1/messages -d x'
put scripts/x/wrapper-caller.sh '#!/usr/bin/env bash' 'bash scripts/lib/claude-headless.sh --role x'
put scripts/x/test-hermetic.sh '#!/usr/bin/env bash' "printf 'claude -p stub\\n'"
put scripts/x/test-thing-live.sh '#!/usr/bin/env bash' 'echo a live suite with no header'
put scripts/x/test-other-live.sh '#!/usr/bin/env bash' '# billed-opt-in: HIMMEL_BILLED_OK' '[ "${HIMMEL_BILLED_OK:-}" = 1 ] || { echo SKIP; exit 0; }'
put scripts/x/armed.sh '#!/usr/bin/env bash' '# billed-opt-in: arming' 'claude -p "hi"'
put scripts/x/orphan-armed.sh '#!/usr/bin/env bash' '# billed-opt-in: arming' 'claude -p "hi"'
put scripts/cad/run-cadence.sh '#!/usr/bin/env bash' 'bash scripts/x/armed.sh'
put scripts/x/fixtures/skipped.sh 'claude -p "a fixture"'
put docs/skipped.sh 'claude -p "a doc"'

frow() { # <label> <want-rc> <want-text> <fixture-relpath>   (lints a tracked list of just that file, + cadence)
  grep -x -F -e "$4" -e scripts/cad/run-cadence.sh "$tmp/tracked" > "$tmp/one"
  bash "$SELF" --lint --root "$fx" --tracked "$tmp/one" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -ne "$2" ]; then fail "$1 -> expected exit $2 got $rc ($(head -1 "$tmp/out"))"; return; fi
  if [ -n "$3" ] && ! grep -qF -- "$3" "$tmp/out"; then fail "$1 -> output lacks '$3'"; return; fi
  pass "$1 -> exit $2"
}

echo "== fixture rows"
frow "clean file" 0 "" scripts/x/clean.sh
frow "RED: an unmarked claude -p call" 1 "unmarked billed call: scripts/x/unmarked.sh:2" scripts/x/unmarked.sh
frow "marked with the env token that is tested" 0 "" scripts/x/marked-env.sh
frow "marked with both tokens, both tested" 0 "" scripts/x/marked-flag.sh
frow "RED: a marker whose token the script never tests" 1 "never tests it: scripts/x/names-untested.sh" scripts/x/names-untested.sh
frow "RED: a token that appears only in a comment" 1 "never tests it: scripts/x/names-in-comment-only.sh" scripts/x/names-in-comment-only.sh
frow "RED: an unknown token" 1 "unknown token (--yes): scripts/x/unknown-token.sh" scripts/x/unknown-token.sh
frow "billed-exempt with a reason" 0 "" scripts/x/exempt.sh
frow "RED: billed-exempt with no reason" 1 "billed-exempt needs a reason: scripts/x/exempt-empty.sh" scripts/x/exempt-empty.sh
frow "a comment mentioning claude -p is not a call" 0 "" scripts/x/comment-only.sh
frow "RED: options between claude and -p are caught" 1 "unmarked billed call: scripts/x/opt-before-p.sh:2" scripts/x/opt-before-p.sh
frow "RED: a call split over backslash continuations is caught" 1 "unmarked billed call: scripts/x/continued.sh:2" scripts/x/continued.sh
frow "RED: a call after a comment ending in a backslash is caught" 1 "unmarked billed call: scripts/x/comment-cont.sh:3" scripts/x/comment-cont.sh
frow "RED: a python argv call is caught" 1 "unmarked billed call: scripts/x/py-argv.py:2" scripts/x/py-argv.py
frow "RED: a node spawn call is caught" 1 "unmarked billed call: scripts/x/js-spawn.mjs:1" scripts/x/js-spawn.mjs
frow "RED: a direct API url is caught" 1 "unmarked billed call: scripts/x/api.sh:2" scripts/x/api.sh
frow "RED: a caller of the headless wrapper is caught" 1 "unmarked billed call: scripts/x/wrapper-caller.sh:2" scripts/x/wrapper-caller.sh
frow "a hermetic suite's stub fixture is not a call" 0 "" scripts/x/test-hermetic.sh
frow "RED: a -live suite with no header" 1 "unmarked billed call: scripts/x/test-thing-live.sh" scripts/x/test-thing-live.sh
frow "a -live suite that opts in" 0 "" scripts/x/test-other-live.sh
frow "arming accepted when a cadence script runs the file" 0 "" scripts/x/armed.sh
frow "RED: arming with no cadence script behind it" 1 "arming but no cadence script runs it: scripts/x/orphan-armed.sh" scripts/x/orphan-armed.sh
frow "a fixtures/ path is skipped" 0 "" scripts/x/fixtures/skipped.sh
frow "a docs/ path is skipped" 0 "" docs/skipped.sh

for opt in --root --tracked; do
  bash "$SELF" --lint "$opt" > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -eq 2 ] && grep -qF -- usage "$tmp/out"; then pass "RED: $opt with no value -> usage, exit 2"; else fail "$opt with no value -> rc=$rc, expected usage and exit 2"; fi
done

bash "$SELF" --lint --root "$fx" --tracked "$tmp/no-such-list" > "$tmp/out" 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -qF -- "tracked list unreadable" "$tmp/out"; then pass "RED: an unreadable --tracked list fails the lint"; else fail "an unreadable --tracked list -> rc=$rc, expected a failure naming the list"; fi

echo "== refusal rows: a marked script run WITHOUT the opt-in makes no call"
stubs="$tmp/stubs"; mkdir -p "$stubs" "$tmp/home"
for b in claude codex; do
  printf '#!/bin/sh\necho called >> "%s/called"\nexit 1\n' "$tmp" > "$stubs/$b"; chmod +x "$stubs/$b"
done
refuse() { # <path> <runner> <want-rc> <want-text> [args...]
  rm -f "$tmp/called"
  (cd "$tmp" && env -i PATH="$stubs:/usr/bin:/bin" HOME="$tmp/home" TMPDIR="$tmp" "$2" "$REPO_ROOT/$1" "${@:5}") > "$tmp/out" 2>&1; rc=$?
  if [ "$rc" -ne "$3" ]; then fail "$1 without the opt-in -> expected exit $3 got $rc ($(head -1 "$tmp/out"))"; return; fi
  if ! grep -qF -- "$4" "$tmp/out"; then fail "$1 without the opt-in -> output lacks '$4'"; return; fi
  if [ -e "$tmp/called" ]; then fail "$1 without the opt-in -> a model binary was invoked"; return; fi
  pass "$1 refuses without the opt-in"
}
refuse scripts/lib/test-claude-headless-live.sh bash 0 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/01-compact-via-resume.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/01b-compact-via-continue.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/02-dontask-allowlist.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/run-all.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/04-wrapper-shape.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/05-cross-cwd-resume.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/07-dual-shell-allowlist.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/probes/claude-p/07-settings-overlay-hooks.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/eval/lane-quality/run.sh bash 64 "HIMMEL_BILLED_OK" run --lane native --model m
refuse scripts/eval/lane-quality/run.sh bash 64 "HIMMEL_BILLED_OK" run --lane native --model m --judge-model --dry-run
refuse scripts/eval/graphify-ab/run.sh bash 2 "HIMMEL_BILLED_OK" run
refuse scripts/eval/retrieval-eval/answer-ab.py python3 64 "HIMMEL_BILLED_OK" run --questions q.jsonl --out o
refuse scripts/eval/review-panel/run.sh bash 2 "HIMMEL_BILLED_OK" --out "$tmp/rp"
refuse scripts/codex/hook-smoke-demo.sh bash 2 "HIMMEL_BILLED_OK"
refuse scripts/handover/console-kit/smoke-consult-sandbox.sh bash 0 "HIMMEL_BILLED_OK"

echo
if [ "$failures" -eq 0 ]; then echo "test-billed-optin: all passed"; exit 0; fi
echo "test-billed-optin: $failures failed"; exit 1
