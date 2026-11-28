#!/usr/bin/env bash
# Tests for scripts/memory/check-memory-truth.sh.
# shellcheck disable=SC2016
set -uo pipefail

CHECK="$(cd "$(dirname "$0")" && pwd)/check-memory-truth.sh"

FAILED=0; SB="$(mktemp -d "${TMPDIR:-/tmp}/memtruth.XXXXXX")" || exit 2
[ -d "$SB" ] || exit 2
trap 'chmod -R u+rwx "$SB" 2>/dev/null; rm -rf "$SB"' EXIT
MEM="$SB/mem"; REPO="$SB/repo"; MIRROR="$SB/mirror"

ok() { if "${@:2}"; then echo "PASS $1"; else echo "FAIL $1"; FAILED=1; fi; }
assert_rc() { if [ "$3" = "$2" ]; then echo "PASS $1 (rc=$3)"; else echo "FAIL $1 (want $2, got $3)"; FAILED=1; fi; }
has() { grep -qF -- "$2" <<< "$1"; }
lacks() { ! grep -qF -- "$2" <<< "$1"; }

mkdir -p "$REPO/scripts/handover/chief" "$REPO/docs" "$MIRROR/HIMMEL"
printf 'x\n' > "$REPO/scripts/handover/chief/chief.sh"
printf 'x\n' > "$REPO/docs/guide.md"
printf 'x\n' > "$REPO/README.md"
printf '*.local.json\n' > "$REPO/.gitignore"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null -c commit.gpgsign=false "$@"; }
if ! { g init -q -b main && g add -A && g commit -qm fixture; }; then echo "FAIL fixture repo"; exit 1; fi
printf -- '---\nkey: "HIMMEL-9032"\nstatusCategory: "Done"\n---\n' > "$MIRROR/HIMMEL/HIMMEL-9032.md"
printf -- '---\nkey: "HIMMEL-77"\nstatusCategory: "In Progress"\n---\n' > "$MIRROR/HIMMEL/HIMMEL-77.md"

note() { printf -- '---\nname: %s\n---\n\n%s\n' "${1%.md}" "$2" > "$MEM/$1"; }
fresh() { rm -rf "$MEM"; mkdir -p "$MEM"; printf '# Memory index\n' > "$MEM/MEMORY.md"; }
run() { out="$(MEMDIR="$MEM" MEMORY_TRUTH_REPO="$REPO" MEMORY_TRUTH_REF=main MEMORY_TRUTH_MIRROR="$MIRROR" JIRA_PROJECT_KEY=HIMMEL bash "$CHECK" 2>&1)"; rc=$?; }

echo "== T1 a note naming a path missing on main fails"
fresh; note dead.md 'Run `scripts/handover/console/console.sh next` to hand over.'
run
assert_rc "T1 rc" 1 "$rc"
ok "T1 names the dead path" has "$out" "dead-path dead.md:5 scripts/handover/console/console.sh"

echo "== T2 a note naming a path present on main passes"
fresh; note live.md 'Run `scripts/handover/chief/chief.sh next`; read docs/guide.md first.'
run
assert_rc "T2 rc" 0 "$rc"
ok "T2 no finding" lacks "$out" "dead-path"

echo "== T3 a wait-on ticket the mirror shows Done is reported; an open one is not"
fresh
note waits.md 'CR work and sweeps sync with HIMMEL-9032 design first.
Eval work waits on HIMMEL-77.
A judge waiting on CI burns cache (HIMMEL-9032). "Never wait on time." HIMMEL-9032 sat for days.'
printf -- '- [CR](waits.md) — CR/eval work + sweeps wait on 9032\n' >> "$MEM/MEMORY.md"
run
assert_rc "T3 rc" 1 "$rc"
ok "T3 the Done key is reported" has "$out" "closed-wait waits.md:5 HIMMEL-9032"
ok "T3 a bare number after 'wait on' in the index is reported" has "$out" "closed-wait MEMORY.md:2 HIMMEL-9032"
ok "T3 the open key is not" lacks "$out" "HIMMEL-77"
ok "T3 a key outside the phrase's clause is not" lacks "$out" "waits.md:7"

echo "== T4 an Incident line records history and is not judged"
fresh; note hist.md 'Run `scripts/handover/chief/chief.sh next`.
Incident 2026-09-22: the old console script path failed with No such file; scripts/handover/console/console.sh is gone.'
run
assert_rc "T4 rc" 0 "$rc"

echo "== T5 placeholders, globs, URLs, ignored files, prose and paths outside the repo are not repo paths"
fresh; note shapes.md 'See `scripts/<name>.sh`, scripts/hooks/*.sh, https://example.com/scripts/nope.sh, ~/scripts/nope.sh and /opt/scripts/nope.sh; luna 30-Resources/Tech/x.md.
Local scripts/lanes/lanes.local.json, ANY docs/audit work, README.md/guide/rules, scripts/cr/test- suites.'
run
assert_rc "T5 rc" 0 "$rc"
note gone.md 'The `docs/audit` folder and scripts/handover/console/ are gone.'
run
ok "T5 a backticked two-part dir is judged" has "$out" "dead-path gone.md:5 docs/audit"
ok "T5 a trailing-slash dir is judged" has "$out" "dead-path gone.md:5 scripts/handover/console"

echo "== T6 a topic file whose name marks it sensitive is never opened"
fresh; note github-read-tokens.md 'scripts/handover/console/console.sh'
chmod 000 "$MEM/github-read-tokens.md"
run
chmod 600 "$MEM/github-read-tokens.md"
assert_rc "T6 rc" 0 "$rc"
ok "T6 no read error on the unreadable file" lacks "$out" "Permission denied"
ok "T6 counts it as skipped" has "$out" "1 skipped as sensitive"

echo "== T7 the check only reports: the store is byte-identical after a run with findings"
fresh; note dead.md 'Run `scripts/handover/console/console.sh next`.'
before="$(cd "$MEM" && ls -la && cat ./*.md)"
run
after="$(cd "$MEM" && ls -la && cat ./*.md)"
assert_rc "T7 rc" 1 "$rc"
ok "T7 store unchanged" test "$before" = "$after"

echo "== T8 every wait phrase on a line is judged, not only the first"
fresh; note two.md 'Eval waits on HIMMEL-77; CR syncs with HIMMEL-9032 first.'
run
ok "T8 the second phrase's Done key is reported" has "$out" "closed-wait two.md:5 HIMMEL-9032"

echo "== T9 a note that cannot be read stops the run instead of passing it"
fresh; note locked.md 'Run `scripts/handover/console/console.sh next`.'
chmod 000 "$MEM/locked.md" || { echo "FAIL T9 fixture chmod"; FAILED=1; }
if [ -r "$MEM/locked.md" ]; then
    echo "SKIP T9 this user can read a mode-000 file"
else
    run
    assert_rc "T9 rc" 2 "$rc"
fi
chmod 600 "$MEM/locked.md"

echo "== T10 a symlink is never followed, whatever its name"
fresh; printf 'scripts/handover/console/console.sh\n' > "$SB/outside.md"
ln -s "$SB/outside.md" "$MEM/innocent.md" && [ -L "$MEM/innocent.md" ] || { echo "FAIL T10 fixture symlink"; FAILED=1; }
run
assert_rc "T10 rc" 0 "$rc"

echo "== T11 no mirror while a note waits on a ticket is a setup error, never a pass"
fresh; note waits.md 'Eval work waits on HIMMEL-9032.'
out="$(MEMDIR="$MEM" MEMORY_TRUTH_REPO="$REPO" MEMORY_TRUTH_REF=main MEMORY_TRUTH_MIRROR="$SB/no-mirror" JIRA_PROJECT_KEY=HIMMEL bash "$CHECK" 2>&1)"; rc=$?
assert_rc "T11 rc" 2 "$rc"
ok "T11 names the missing mirror" has "$out" "Jira mirror not found"
note dead.md 'Run `scripts/handover/console/console.sh next`.'
out="$(MEMDIR="$MEM" MEMORY_TRUTH_REPO="$REPO" MEMORY_TRUTH_REF=main MEMORY_TRUTH_MIRROR="$SB/no-mirror" JIRA_PROJECT_KEY=HIMMEL bash "$CHECK" 2>&1)"; rc=$?
assert_rc "T11 a dead path still reports without the mirror" 1 "$rc"
ok "T11 the dead path is listed" has "$out" "dead-path dead.md:5 scripts/handover/console/console.sh"
ok "T11 the unchecked tickets are still named" has "$out" "tickets were not checked"

if [ "$FAILED" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
