#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# Test for scripts/docs/check-old-terms.sh: fixture commits on a scratch repo,
# the lint run over base...HEAD (and over the index for --staged).
#
# Usage: bash scripts/docs/test-check-old-terms.sh
# shellcheck disable=SC2016  # fixture lines are literal text, nothing should expand
set -uo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/check-old-terms.sh"

unset PRE_COMMIT_TO_REF GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h6631.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
printf '#!/usr/bin/env bash\necho base\n' > "$repo/scripts/base.sh"
printf '# Base\n\nNothing here.\n' > "$repo/docs-base.md"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: base commit failed"; exit 1; }
base=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: base HEAD lookup failed"; exit 1; }

# run_case <name> <expected rc> <path> <content>: commit <content> at <path> on a
# fresh branch off base, run the lint from the repo cwd.
run_case() {
    local name="$1" want="$2" path="$3" content="$4" rc out head
    git -C "$repo" checkout -q -B case "$base" || { fail "$name: setup checkout failed"; return; }
    mkdir -p "$repo/$(dirname "$path")" || { fail "$name: setup mkdir failed"; return; }
    printf '%s\n' "$content" > "$repo/$path" || { fail "$name: setup write failed"; return; }
    git -C "$repo" add -A || { fail "$name: setup add failed"; return; }
    git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "case $name" || { fail "$name: setup commit failed"; return; }
    head=$(git -C "$repo" rev-parse HEAD) || { fail "$name: setup HEAD lookup failed"; return; }
    [ "$head" != "$base" ] || { fail "$name: setup produced no commit"; return; }
    out=$(cd "$repo" && bash "$LINT" "$base" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}

echo "== an unregistered old-term identifier is refused =="
run_case "LEG_TURN_CAP added to a script" 1 scripts/cap.sh 'LEG_TURN_CAP=40'
case "$LAST_OUT" in *scripts/cap.sh*LEG_TURN_CAP*) pass "finding names file and token" ;; *) fail "finding names file and token: $LAST_OUT" ;; esac
run_case "BANK token" 1 scripts/bk.sh 'echo "$NEW_BANK_THING"'
run_case "OVERNIGHT token" 1 scripts/ov.sh 'export OVERNIGHT_FOO=1'
run_case "token with LEG_ in the middle" 1 scripts/mid.sh 'HEADED_ARM_LEG_BRAND_NEW=1'
run_case "identifier in a markdown code span" 1 docs/ids.md 'Set `CONSOLE_NEW_KNOB` to tune it.'
run_case "HIMMEL_WORKER_ not followed by SESSION_" 1 scripts/hw.sh 'HIMMEL_WORKER_CACHE=1'
run_case "SEQUENCE_ identifier" 1 scripts/seq.sh 'PARALLEL_SEQUENCE_X=1'
run_case "_WAVE identifier" 1 scripts/wv2.sh 'FLEET_WAVE_SIZE=3'
run_case "chief-judge name" 1 scripts/cj.sh 'agent=chief-judge'

echo "== an old-term prose line is refused =="
run_case "the console arms a leg" 1 docs/page.md 'the console arms a leg'
case "$LAST_OUT" in *docs/page.md*) pass "finding names the file" ;; *) fail "finding names the file: $LAST_OUT" ;; esac
run_case "bank in prose" 1 docs/bank.md 'The bank resets on Monday.'
run_case "overnight mode in prose" 1 docs/ov.md 'Run overnight mode for the batch.'
run_case "CR marker in prose" 1 docs/cr.md 'Clear the CR marker first.'
run_case "judge call in prose" 1 docs/jc.md 'A judge call answers one question.'
run_case "chain of workers in prose" 1 docs/chain.md 'Each step in the chain of workers waits for the last.'
run_case "chain of legs in prose" 1 docs/chain2.md 'A chain of legs runs in order.'
run_case "wave in prose" 1 docs/wave.md 'The next wave starts at noon.'
run_case "the console arms a leg in the next wave" 1 docs/wave2.md 'the console arms a leg in the next wave'
run_case "class sweep in prose" 1 docs/cs.md 'Run a class sweep over the sites.'
run_case "sibling sweep in prose" 1 docs/ss.md 'Do a sibling sweep before READY.'
run_case "ticket sequence in prose" 1 docs/ts.md 'Run the ticket sequence in order.'
run_case "batch of workers in prose" 1 docs/bw.md 'Launch a batch of workers at noon.'
run_case "batch of worker sessions in prose" 1 docs/bws.md 'Launch a batch of worker sessions at noon.'
run_case "plural legs in prose" 1 docs/legs.md 'Both legs finished.'
run_case "noun wave beside the verb idiom" 1 docs/wave3.md 'The next wave must not wave it through.'
run_case "added line starting with ++ does not hide later lines" 1 docs/plus.md '++ item
the console arms a leg'
run_case "non-ASCII path is read" 1 'docs/é.md' 'the console arms a leg'
run_case "path git quotes cannot be read: refused, not skipped" 2 'docs/a"b.md' 'the console arms a leg'

echo "== the exemption marker passes =="
run_case "identifier with marker" 0 scripts/cap2.sh 'LEG_TURN_CAP=40 # old-term-ok: mirrors the upstream name'
run_case "prose with marker" 0 docs/page2.md 'the console arms a leg old-term-ok: quoting the old text'
run_case "marker without a reason is refused" 1 docs/page3.md 'the console arms a leg old-term-ok:'

echo "== code spans, link targets and fences pass =="
run_case "terms in a code span" 0 docs/span.md 'Run `console` and `leg` through the `bank` script.'
run_case "term in a link target" 0 docs/link.md 'See [the guide](docs/handover/console-guide.md) for more.'
run_case "terms in a fenced block" 0 docs/fence.md '```text
the console arms a leg
the bank resets
```
Plain closing line.'
run_case "prose after a fence still counts" 1 docs/fence2.md '```text
fine
```
the console arms a leg'

echo "== prose rules apply to markdown only =="
run_case "old word in a shell comment" 0 scripts/cmt.sh '# the console arms a leg'

echo "== exempted paths and senses pass =="
run_case "identifier under fixtures" 0 scripts/fixtures/x.sh 'LEG_TURN_CAP=40'
run_case "prose under fixtures" 0 docs/fixtures/p.md 'the console arms a leg'
run_case "glossary alias table" 0 docs/glossary.md '| **worker** | leg | The dispatched session. |'
run_case "the registry itself" 0 scripts/lib/rename-aliases.tsv 'LEG_TURN_CAP	pending-N2892	env	old-to-new	R0	pending-N2892'
run_case "CI-matrix leg in testing.md" 0 docs/internals/testing.md 'Each leg of the matrix runs one shard.'
run_case "CI-matrix leg in ci-image.md" 0 docs/internals/ci-image.md 'Each leg pulls the image.'
run_case "leg in another doc is still refused" 1 docs/internals/other.md 'Each leg pulls the image.'
run_case "dependency chain and parallel wave" 0 docs/new.md 'A dependency chain runs in each parallel wave.'
run_case "console.log and the browser console" 0 docs/js.md 'Call console.log, then open the browser console.'
run_case "kept HIMMEL_CONSOLE_ prefix" 0 scripts/keep.sh 'export HIMMEL_CONSOLE_LEG=1'
run_case "kept HIMMEL_WORKER exact" 0 scripts/keepw.sh 'export HIMMEL_WORKER=1'
run_case "HIMMEL_WORKER_SESSION_ prefix" 0 scripts/keepws.sh 'export HIMMEL_WORKER_SESSION_ID=1'
run_case "wave as a verb: wave it through" 0 docs/verb.md 'A guard must not wave it through.'
run_case "CI chain and merge chain are not the fleet chain" 0 docs/chains.md 'The CI chain and the merge chain share a toolchain.'
run_case "a hook-chain identifier" 0 scripts/hookchain.sh 'echo "$RUN_HOOK_CHAIN_DEBUG"'
run_case "an identifier already in the registry" 0 scripts/reg.sh 'echo "$LEG_LOG"'

echo "== no old term at all passes =="
run_case "clean script" 0 scripts/clean.sh 'echo hello'
run_case "clean doc" 0 docs/clean.md 'The chief dispatches a worker.'

echo "== an empty range passes =="
git -C "$repo" checkout -q -B empty "$base"
out=$(cd "$repo" && bash "$LINT" "$base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "no diff (rc=$rc)"; else fail "no diff: want rc=0 got rc=$rc: $out"; fi

echo "== --staged reads the index =="
git -C "$repo" checkout -q -B staged "$base"
printf 'LEG_TURN_CAP=40\n' > "$repo/scripts/st.sh"
git -C "$repo" add scripts/st.sh
out=$(cd "$repo" && bash "$LINT" --staged 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "staged old-term identifier (rc=$rc)"; else fail "staged old-term identifier: want rc=1 got rc=$rc: $out"; fi
out=$(cd "$repo" && bash "$LINT" --auto 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "--auto without PRE_COMMIT_TO_REF reads the index (rc=$rc)"; else fail "--auto index: want rc=1 got rc=$rc: $out"; fi
git -C "$repo" reset -q
rm -f "$repo/scripts/st.sh"
out=$(cd "$repo" && bash "$LINT" --staged 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "nothing staged (rc=$rc)"; else fail "nothing staged: want rc=0 got rc=$rc: $out"; fi

echo "== --auto with PRE_COMMIT_TO_REF reads the range =="
git -C "$repo" branch -f main "$base"
git -C "$repo" checkout -q -B autorange "$base"
printf 'LEG_TURN_CAP=40\n' > "$repo/scripts/ar.sh"
git -C "$repo" add scripts/ar.sh
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "case autorange"
arhead=$(git -C "$repo" rev-parse HEAD)
out=$(cd "$repo" && PRE_COMMIT_TO_REF="$arhead" bash "$LINT" --auto 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "--auto with PRE_COMMIT_TO_REF runs the range (rc=$rc)"; else fail "--auto range: want rc=1 got rc=$rc: $out"; fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
