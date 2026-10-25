#!/usr/bin/env bash
# Platform guard (posix-bash): POSIX bash 3.2+.
#
# Test for scripts/docs/check-old-terms.sh --tree: the whole tracked tree, file
# names included, against scripts/docs/old-terms-baseline.txt.
#   1. an unlisted console-*.sh fails; a registry keep row, or a baseline line, passes it
#   2. a rename row does not exempt (only keep and live alias rows do)
#   3. tokens and flags: LEGS_SPLIT and --legs-from fail, LEGACY and --legacy are not hits,
#      a kept prefix and an exact env alias row pass, the old-term-ok marker passes
#   4. a baseline line the tree no longer has fails (the line goes with the rename)
#   5. a baseline line that the base branch's baseline lacks fails (the baseline only shrinks)
#   6. the real tree against the committed baseline passes
#
# Usage: bash scripts/docs/test-check-old-terms-tree.sh
# shellcheck disable=SC2016  # fixture lines are literal text, nothing should expand
set -uo pipefail

LINT="$(cd "$(dirname "$0")" && pwd)/check-old-terms.sh"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

unset PRE_COMMIT_TO_REF GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY OLD_TERMS_REGISTRY

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/h7620.XXXXXX") || { echo "setup: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo/scripts/lib" "$repo/scripts/docs" "$repo/scripts/hooks"
git init -q "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
reg_head='old	new	kind	direction	slice	remove-at'
printf '%s\nHIMMEL_CONSOLE_	HIMMEL_CONSOLE_	do-not-rename	keep	none	never\nCONSOLE_FG_OK	CHIEF_FG_OK	env	permit	V5	X\nLEG_	WORKER_SESSION_	env-prefix	value	V4a	X\n' "$reg_head" > "$repo/scripts/lib/rename-aliases.tsv"
printf '# baseline\n' > "$repo/scripts/docs/old-terms-baseline.txt"
printf '#!/usr/bin/env bash\necho base\n' > "$repo/scripts/base.sh"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m base || { echo "FAIL: base commit failed"; exit 1; }
git -C "$repo" branch -M main
base=$(git -C "$repo" rev-parse HEAD) || { echo "FAIL: base HEAD lookup failed"; exit 1; }

LAST_OUT=""
# tree_case <name> <expected rc>: run --tree from the fixture repo root.
tree_case() {
    local name="$1" want="$2" rc out
    out=$(cd "$repo" && bash "$LINT" --tree 2>&1); rc=$?
    if [ "$rc" -eq "$want" ]; then pass "$name (rc=$rc)"; else fail "$name: want rc=$want got rc=$rc: $out"; fi
    LAST_OUT="$out"
}
# put <path> <content>: write and stage one file on the case branch.
put() {
    mkdir -p "$repo/$(dirname "$1")" && printf '%s\n' "$2" > "$repo/$1" && git -C "$repo" add -A
}
fresh() {
    if ! { git -C "$repo" checkout -q -f -B case "$base" && git -C "$repo" clean -qfd; }; then
        echo "setup: fixture reset failed" >&2; exit 2
    fi
}

echo "== a clean tree passes =="
fresh
tree_case "clean tree, empty baseline" 0

echo "== an unlisted console-*.sh fails, a keep row or a baseline line passes it =="
fresh
put scripts/hooks/console-probe.sh 'echo probe'
tree_case "unlisted console-probe.sh" 1
case "$LAST_OUT" in *'path `scripts/hooks/console-probe.sh`'*) pass "finding names the path" ;; *) fail "finding names the path: $LAST_OUT" ;; esac
printf 'console-probe.sh\tchief-probe.sh\tidentifier\told-to-new\tV5\tX\n' >> "$repo/scripts/lib/rename-aliases.tsv"
tree_case "a rename row does not exempt the path" 1
printf 'console-probe.sh\tconsole-probe.sh\tidentifier\tkeep\tnone\tnever\n' > "$tmp/keep.tsv"
{ printf '%s\n' "$reg_head"; cat "$tmp/keep.tsv"; } > "$repo/scripts/lib/rename-aliases.tsv"
tree_case "a keep row exempts the path" 0
out=$(cd "$repo/scripts" && OLD_TERMS_REGISTRY=lib/rename-aliases.tsv bash "$LINT" --tree 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "a relative registry override is read from the caller's cwd (rc=$rc)"; else fail "relative registry override: want rc=0 got rc=$rc: $out"; fi
git -C "$repo" checkout -q -- scripts/lib/rename-aliases.tsv
printf 'path\tscripts/hooks/console-probe.sh\n' >> "$repo/scripts/docs/old-terms-baseline.txt"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "listed path" || fail "setup: listed path commit failed"
git -C "$repo" branch -f main HEAD
tree_case "a baseline line passes the path" 0
put scripts/hooks/guard-leg-probe.sh 'echo probe'
tree_case "a second unlisted path still fails" 1
case "$LAST_OUT" in *guard-leg-probe.sh*) pass "the new path is named" ;; *) fail "the new path is named: $LAST_OUT" ;; esac
case "$LAST_OUT" in *console-probe.sh*) fail "the listed path is not reported: $LAST_OUT" ;; *) pass "the listed path is not reported" ;; esac
git -C "$repo" checkout -q -f -B case "$base"
git -C "$repo" branch -f main "$base"

echo "== look-alike paths and fixtures pass =="
fresh
put scripts/legacy-tool.sh 'echo x'
put scripts/consoles.md 'x'
put scripts/fixtures/console-old.sh 'echo frozen'
tree_case "legacy-, consoles. and fixtures/ paths" 0
fresh
put scripts/hooks/console-gone.sh 'echo gone'
rm -f "$repo/scripts/hooks/console-gone.sh"
tree_case "a tracked file deleted from the working tree is not a hit" 0

echo "== tokens and flags =="
fresh
put scripts/a.sh 'LEGS_SPLIT=2'
tree_case "LEGS_SPLIT fails" 1
case "$LAST_OUT" in *'token `LEGS_SPLIT`'*scripts/a.sh:1*) pass "finding names token and first site" ;; *) fail "finding names token and first site: $LAST_OUT" ;; esac
fresh
put 'scripts/a:b.sh' 'LEGS_SPLIT=2'
tree_case "a token in a file name with a colon fails" 1
fresh
put "$(printf 'scripts/new\nscripts/docs/check-old-terms.sh')" 'CONSOLE_UNREGISTERED=1'
tree_case "a tracked path with a newline is a setup error" 2
fresh
put scripts/b.sh 'export CACHE_HEALTH_CONSOLE=1'
tree_case "a trailing _CONSOLE fails" 1
fresh
put scripts/c.sh 'run --legs-from list.txt'
tree_case "--legs-from fails" 1
case "$LAST_OUT" in *'flag `--legs-from`'*) pass "finding names the flag" ;; *) fail "finding names the flag: $LAST_OUT" ;; esac
fresh
put docs/d.md 'Pass `--console <session>` to it.'
tree_case "--console in a doc fails" 1
fresh
put scripts/e.sh 'LEGACY_MODE=1 PRIVILEGED=1 run --legacy --consoled; console.log'
tree_case "LEGACY, PRIVILEGED, --legacy, --consoled are not hits" 0
fresh
put scripts/f.sh 'echo "$HIMMEL_CONSOLE_DOC" "$CONSOLE_FG_OK"'
tree_case "a kept prefix and an exact env alias row pass" 0
fresh
put scripts/g.sh 'echo "$LEG_LOG"'  # an old name on purpose
tree_case "an env-prefix alias row does not exempt LEG_LOG" 1  # an old name on purpose
fresh
put scripts/h.sh 'LEGS_SPLIT=2 # old-term-ok: mirrors the upstream name'
tree_case "a marked line passes" 0
fresh
put scripts/fixtures/i.sh 'LEGS_SPLIT=2'
tree_case "a token under fixtures/ passes" 0

echo "== a stale baseline line fails =="
fresh
printf 'token\tLEGS_GONE\n' >> "$repo/scripts/docs/old-terms-baseline.txt"
tree_case "a baseline line with no hit in the tree" 1
case "$LAST_OUT" in *'stale'*LEGS_GONE*) pass "the stale line is named" ;; *) fail "the stale line is named: $LAST_OUT" ;; esac

echo "== the baseline only shrinks =="
git -C "$repo" checkout -q -f main
put scripts/j.sh 'LEGS_SPLIT=2 LEGS_TIMEOUT_MS=1'
printf 'token\tLEGS_SPLIT\ntoken\tLEGS_TIMEOUT_MS\n' >> "$repo/scripts/docs/old-terms-baseline.txt"
git -C "$repo" add -A
git -C "$repo" -c core.hooksPath=/dev/null commit -q -m "main baseline" || fail "setup: main baseline commit failed"
mainb=$(git -C "$repo" rev-parse HEAD)
tree_case "main against its own baseline" 0
git -C "$repo" checkout -q -B shrink "$mainb"
put scripts/j.sh 'LEGS_SPLIT=2'
grep -v LEGS_TIMEOUT_MS "$repo/scripts/docs/old-terms-baseline.txt" > "$tmp/b" && cp "$tmp/b" "$repo/scripts/docs/old-terms-baseline.txt"
git -C "$repo" add -A
tree_case "a branch that drops a line passes" 0
git -C "$repo" checkout -q -f -B grow "$mainb"
put scripts/k.sh 'LEGS_NEW_KNOB=1'
printf 'token\tLEGS_NEW_KNOB\n' >> "$repo/scripts/docs/old-terms-baseline.txt"
git -C "$repo" add -A
tree_case "a branch that adds a baseline line fails" 1
case "$LAST_OUT" in *LEGS_NEW_KNOB*'only shrinks'*|*'only shrinks'*LEGS_NEW_KNOB*) pass "the grown line is named" ;; *) fail "the grown line is named: $LAST_OUT" ;; esac
git -C "$repo" branch -m main nomain
tree_case "no origin/main or main to compare against is a setup error" 2
git -C "$repo" branch -m nomain main

echo "== the real tree against the committed baseline =="
out=$(cd "$REPO" && bash "$LINT" --tree 2>&1); rc=$?
if [ "$rc" -eq 0 ]; then pass "real tree (rc=$rc)"; else fail "real tree: want rc=0 got rc=$rc: $(printf '%s\n' "$out" | head -40)"; fi

if [ "$failures" -ne 0 ]; then
    printf '\n%d case(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall cases passed\n'
