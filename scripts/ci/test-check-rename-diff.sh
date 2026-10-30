#!/usr/bin/env bash
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+.
#
# Test for scripts/ci/check-rename-diff.sh.
#
# Fixture terms are fabricated (ZZOLD_*, retiredword ...) so this file never
# spells a real retired name; the one real-registry case builds its name from
# two halves.
#
# Usage: bash scripts/ci/test-check-rename-diff.sh
# shellcheck disable=SC2016  # fixture lines are literal text, nothing should expand
set -uo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/check-rename-diff.sh"

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h8302.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

# A tab-separated mini registry in the real column order.
reg="$tmp/registry.tsv"
{
    printf '# fixture registry\n'
    printf 'old\tnew\tkind\tdirection\tslice\tremove-at\n'
    printf 'ZZOLD_ONE\tZZNEW_ONE\tenv\tvalue\tW\tX\n'
    printf 'ZZOLD_\tZZNEW_\tenv-prefix\tvalue\tW\tX\n'
    printf 'ZZOLD_KEEP\tZZOLD_KEEP\tidentifier\tkeep\tnone\tnever\n'
    printf 'ZZOLD_PENDING\tpending-N2892\tidentifier\told-to-new\tpending-N2892\tpending-N2892\n'
    printf 'ZZ-OLD-MARK\tZZ-NEW-MARK\tmarker\told-to-new\tV1\tnever\n'
    printf 'retiredword\tfreshword\tprose\tfail\tV5\tnever\n'
    printf 'old wave\tnew wave\tprose\tfail\tR2\tnever\n'
    printf 'softword\tfirmword\tprose\twarn\tD\tnever\n'
    printf 'zz-old-dir\tzz-new-dir\tpath\tfail\tM\tnever\n'
} > "$reg"

repo="$tmp/repo"
mkdir -p "$repo/scripts/lib"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
printf 'ZZOLD_ONE=1 # base already carries the old name\nplain line\n' > "$repo/base.sh"
cp "$reg" "$repo/scripts/lib/rename-aliases.tsv"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: base commit failed"; exit 1; }
base=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: base HEAD lookup failed"; exit 1; }

# run_case <name> <want rc> <path> <content> [gate args...]: commit <content>
# at <path> on a fresh branch off base, run the gate from the repo cwd.
run_case() {
    local name="$1" want="$2" path="$3" content="$4" rc out head
    shift 4
    git -C "$repo" checkout -q -B case "$base" || { fail "$name: setup checkout failed"; return; }
    mkdir -p "$repo/$(dirname "$path")" || { fail "$name: setup mkdir failed"; return; }
    printf '%s\n' "$content" >> "$repo/$path" || { fail "$name: setup write failed"; return; }
    git -C "$repo" add -A || { fail "$name: setup add failed"; return; }
    git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "case $name" || { fail "$name: setup commit failed"; return; }
    head=$(git -C "$repo" rev-parse HEAD) || { fail "$name: setup HEAD lookup failed"; return; }
    [ "$head" != "$base" ] || { fail "$name: setup produced no commit"; return; }
    out=$(cd "$repo" && bash "$GATE" --registry "$reg" "$@" "$base" 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}

echo "== RED: an added retired name is refused =="
run_case "added old env name" 1 scripts/run.sh 'export ZZOLD_ONE=1'
case "$LAST_OUT" in *scripts/run.sh:*ZZOLD_ONE*ZZNEW_ONE*) pass "finding names file, old and new" ;; *) fail "finding names file, old and new: $LAST_OUT" ;; esac
run_case "added old prefix member" 1 scripts/run.sh 'echo "$ZZOLD_ANYTHING"'
run_case "added old identifier with no ruled new name" 1 scripts/run.sh 'x=ZZOLD_PENDING'
run_case "added old marker" 1 docs/a.md 'status is ZZ-OLD-MARK today'
run_case "added retired prose word, any case" 1 docs/a.md 'The Retiredword is back'
run_case "added retired prose word, plural" 1 docs/a.md 'two retiredwords here'
run_case "added multi-word prose" 1 docs/a.md 'an old wave of work'
run_case "added old path" 1 docs/a.md 'see docs/zz-old-dir/x.md'

echo "== GREEN: the new name, markers and keep rows pass =="
run_case "new name" 0 scripts/run.sh 'export ZZNEW_ONE=1'
run_case "old-term-ok marker" 0 scripts/run.sh 'export ZZOLD_ONE=1 # old-term-ok: reads the old spelling'
run_case "old-term-ok html marker" 0 docs/a.md 'ZZ-OLD-MARK <!-- old-term-ok: inventory -->'
run_case "keep row exact" 0 scripts/run.sh 'x=$ZZOLD_KEEP'
run_case "prose inside its own new phrase" 0 docs/a.md 'a new wave of work'
run_case "prose property access is code" 0 docs/a.md 'call retiredword.log() here'
run_case "warn-direction prose row is not scanned" 0 docs/a.md 'a softword'
run_case "left boundary: longer identifier" 0 scripts/run.sh 'XZZOLD_ONE=1'
run_case "right boundary: longer marker" 0 docs/a.md 'ZZ-OLD-MARKER is another word'
run_case "prefix row still catches a longer name" 1 scripts/run.sh 'ZZOLD_ONEX=1'
run_case "registry file may carry old names" 0 scripts/lib/rename-aliases.tsv 'ZZOLD_ONE	ZZNEW_ONE	env	value	W	X'

echo "== only added lines count =="
run_case "unrelated added line next to an old name" 0 base.sh 'another plain line'
git -C "$repo" checkout -q -B case "$base"
grep -v 'ZZOLD_ONE' "$repo/base.sh" > "$tmp/base.new" && cp "$tmp/base.new" "$repo/base.sh"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "delete the old name"
out=$(cd "$repo" && bash "$GATE" --registry "$reg" "$base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "deleting an old name is clean (rc=0)"; else fail "deleting an old name: rc=$rc $out"; fi

echo "== --warn reports and exits 0 =="
run_case "warn mode still prints the hit" 0 scripts/run.sh 'export ZZOLD_ONE=1' --warn
case "$LAST_OUT" in *ZZOLD_ONE*) pass "warn output carries the hit" ;; *) fail "warn output carries the hit: $LAST_OUT" ;; esac

echo "== usage errors exit 2 =="
out=$(cd "$repo" && bash "$GATE" --registry "$tmp/absent.tsv" "$base" 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "missing registry (rc=2)"; else fail "missing registry: rc=$rc $out"; fi
out=$(cd "$repo" && bash "$GATE" --registry "$reg" no-such-ref 2>&1); rc=$?
if [ "$rc" -eq 2 ]; then pass "unknown base (rc=2)"; else fail "unknown base: rc=$rc $out"; fi

echo "== --report <dir> lists hits across the whole tree =="
git -C "$repo" checkout -q -B case "$base"
printf 'export ZZOLD_ONE=1\nexport ZZOLD_TWO=2\n' > "$repo/two.sh"
printf 'a retiredword\n' > "$repo/note.md"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "report fixtures"
rdir="$tmp/report"
out=$(cd "$repo" && bash "$GATE" --registry "$reg" --report "$rdir" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "report exits 0 on hits (rc=0)"; else fail "report exit: rc=$rc $out"; fi
if [ -r "$rdir/by-file.tsv" ] && [ -r "$rdir/hits.txt" ]; then pass "report writes by-file.tsv and hits.txt"; else fail "report files missing: $(ls "$rdir" 2>&1)"; fi
if grep -qE '^2[[:space:]]+two\.sh$' "$rdir/by-file.tsv" 2>/dev/null; then pass "by-file.tsv counts two.sh at 2"; else fail "by-file.tsv: $(cat "$rdir/by-file.tsv" 2>&1)"; fi
if grep -qE '^1[[:space:]]+note\.md$' "$rdir/by-file.tsv" 2>/dev/null; then pass "by-file.tsv counts note.md at 1"; else fail "by-file.tsv note.md: $(cat "$rdir/by-file.tsv" 2>&1)"; fi
if grep -q 'scripts/lib/rename-aliases.tsv' "$rdir/hits.txt" 2>/dev/null; then fail "report lists the registry itself"; else pass "report skips the registry itself"; fi

echo "== the real registry is the default =="
real_old="HIMMEL_LE""G_PROFILE"
git -C "$repo" checkout -q -B case "$base"
cp "$(dirname "$GATE")/../lib/rename-aliases.tsv" "$repo/scripts/lib/rename-aliases.tsv"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "real registry"
real_base=$(git -C "$repo" rev-parse HEAD)
printf 'export %s=x\n' "$real_old" > "$repo/real.sh"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "real old name"
out=$(cd "$repo" && bash "$GATE" "$real_base" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "real registry refuses a real retired env name (rc=1)"; else fail "real registry: rc=$rc $out"; fi
printf 'export HIMMEL_WORKER_SESSION_PROFILE=x\n' > "$repo/real.sh"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "real new name"
out=$(cd "$repo" && bash "$GATE" "$real_base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "real registry passes the new name (rc=0)"; else fail "real registry new name: rc=$rc $out"; fi
# the registry's own console prose row (V5): the word is covered, code is not
printf 'Ask the %s about it\n' "conso""le" > "$repo/real.md"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "real prose"
out=$(cd "$repo" && bash "$GATE" "$real_base" 2>&1); rc=$?
if [ "$rc" -eq 1 ]; then pass "real registry refuses the retired prose word (rc=1)"; else fail "real registry prose: rc=$rc $out"; fi
printf 'JS code calls %s.log(1)\n' "conso""le" > "$repo/real.md"
git -C "$repo" rm -q --cached real.sh >/dev/null && rm -f "$repo/real.sh"
git -C "$repo" add -A && git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "real code"
out=$(cd "$repo" && bash "$GATE" "$real_base" 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "real registry leaves a property access alone (rc=0)"; else fail "real registry property access: rc=$rc $out"; fi

echo
if [ "$failures" -eq 0 ]; then echo "check-rename-diff: all cases passed"; else echo "check-rename-diff: $failures case(s) FAILED"; fi
[ "$failures" -eq 0 ]
