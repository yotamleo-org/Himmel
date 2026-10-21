#!/usr/bin/env bash
# Fixture tests for the capped batch runners in scripts/cleanup/:
# cleanup-batch.sh (20 files), worktree-batch.sh (10 worktrees), jira-batch.sh (20 tickets).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
passes=0
fails=0
out=""

ok() { echo "ok - $1"; passes=$((passes + 1)); }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
grepq() { local text="$1"; shift; grep -q "$@" <<< "$text"; }
check() { # <name> <cmd...>
  local name="$1"; shift
  if "$@"; then ok "$name"; else bad "$name: $out"; fi
}
lines() { if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; } # read-sink-ok: counts lines of fixture logs this test writes under $TMP

TMP="$(mktemp -d -t test-batch-runners.XXXXXX)" || { echo "FAIL - mktemp -d failed (rc=$?)" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/fix"
mkdir -p "$FIX/scripts/cleanup" "$FIX/scripts/jira/dist" "$FIX/wt"
for s in cleanup-batch.sh worktree-batch.sh jira-batch.sh; do
  cp "$ROOT/scripts/cleanup/$s" "$FIX/scripts/cleanup/$s" 2>/dev/null
done
git init -q -b main "$FIX"
git -C "$FIX" config user.email t@example.com
git -C "$FIX" config user.name t
git -C "$FIX" config commit.gpgsign false

# --- cleanup-batch.sh ------------------------------------------------------
CB="$FIX/scripts/cleanup/cleanup-batch.sh"
{
  for i in $(seq 1 23); do echo "scripts/hooks/h$i.sh"; done
  echo "docs/a.md"
  echo "README.md"
} > "$TMP/paths.txt"
out="$(bash "$CB" plan "$TMP/paths.txt" 2>&1)"
check "plan splits a family over the cap into batches of 20" grepq "$out" -x 'batch 1 family=scripts/hooks files=20'
check "plan puts the overflow in its own batch" grepq "$out" -x 'batch 2 family=scripts/hooks files=3'
check "plan keeps each directory family apart" grepq "$out" -x 'batch 4 family=docs files=1'
check "plan names the next batch" grepq "$out" -x 'next: batch 1 family=scripts/hooks files=20'
check "plan counts the queue" grepq "$out" -x 'batches: 4'

git -C "$FIX" commit -q --allow-empty -m base
git -C "$FIX" branch base
mkdir -p "$FIX/scripts/hooks"
for i in $(seq 1 20); do echo x > "$FIX/scripts/hooks/h$i.sh"; done
git -C "$FIX" add -A scripts/hooks && git -C "$FIX" commit -q -m twenty
out="$(cd "$FIX" && bash "$CB" check base 2>&1)"; rc=$?
check "check passes a 20-file one-family diff" [ "$rc" -eq 0 ]
echo x > "$FIX/scripts/hooks/h21.sh"
git -C "$FIX" add -A scripts/hooks && git -C "$FIX" commit -q -m twentyone
out="$(cd "$FIX" && bash "$CB" check base 2>&1)"; rc=$?
check "check refuses a 21-file diff" [ "$rc" -eq 1 ]
check "the refusal names the cap" grepq "$out" 'over the cap of 20'
git -C "$FIX" checkout -q base -b two-families
mkdir -p "$FIX/docs" "$FIX/scripts/hooks"
echo x > "$FIX/scripts/hooks/a.sh"; echo x > "$FIX/docs/a.md"
git -C "$FIX" add -A scripts/hooks docs && git -C "$FIX" commit -q -m two
out="$(cd "$FIX" && bash "$CB" check base 2>&1)"; rc=$?
check "check refuses a diff spanning two families" [ "$rc" -eq 1 ]

# --- worktree-batch.sh -----------------------------------------------------
WB="$FIX/scripts/cleanup/worktree-batch.sh"
cat > "$FIX/scripts/worktree.sh" <<'EOF'
#!/usr/bin/env bash
log="$(dirname "$0")/../worktree.log"
case " $* " in
  *" --dry-run "*)
    [ -z "${WT_DRY_FAIL:-}" ] || { echo "ERR clean-garden: boom" >&2; exit 1; }
    echo "KEEP clean-garden: branch=main verdict=ACTIVE"
    echo "DRY clean-garden: would prune fix/b1 ($WT_ROOT/1), discarding untracked strays: a.log"
    for i in $(seq 2 12); do echo "DRY clean-garden: would prune fix/b$i ($WT_ROOT/$i)"; done
    echo "clean-garden: prune summary — 12 pruned" ;;
  *" --only "*)
    echo "$*" >> "$log"
    p="${!#}"
    [ "$p" = "$WT_ROOT/2" ] && exit 1
    rmdir "$p" ;;
esac
EOF
export WT_ROOT="$FIX/wt"
for i in $(seq 1 12); do mkdir -p "$WT_ROOT/$i"; done
out="$(bash "$WB" plan 2>&1)"; rc=$?
printf '%s\n' "$out" > "$TMP/wt-plan.txt"
check "worktree plan exits 0" [ "$rc" -eq 0 ]
check "worktree plan lists at most 10" [ "$(grep -vc '^#' "$TMP/wt-plan.txt")" -eq 10 ]
check "worktree plan names what waits for the next run" grepq "$out" -x '# candidates=12 batch=10 next-run=2'
check "worktree plan keeps a candidate with untracked strays" grepq "$out" -x "$WT_ROOT/1"
check "worktree plan removes nothing" [ "$(lines "$FIX/worktree.log")" -eq 0 ]
for i in $(seq 1 11); do echo "$WT_ROOT/$i"; done > "$TMP/wt-11.txt"
out="$(bash "$WB" apply "$TMP/wt-11.txt" 2>&1)"; rc=$?
check "worktree apply refuses 11" [ "$rc" -eq 1 ]
check "the worktree refusal names the cap" grepq "$out" 'over the cap of 10'
check "a refused worktree batch removes nothing" [ "$(lines "$FIX/worktree.log")" -eq 0 ]
out="$(bash "$WB" apply "$TMP/wt-plan.txt" 2>&1)"; rc=$?
check "worktree apply runs prune --only per path" [ "$(lines "$FIX/worktree.log")" -eq 10 ]
check "worktree apply reports removed and kept" grepq "$out" -x 'worktree-batch: removed=9 kept=1 absent=0'
check "a gate-kept worktree is still there" [ -d "$WT_ROOT/2" ]
printf '%s\n' "$WT_ROOT/gone" "$WT_ROOT/11" > "$TMP/wt-absent.txt"
out="$(bash "$WB" apply "$TMP/wt-absent.txt" 2>&1)"; rc=$?
check "an already-absent worktree is not counted as removed" grepq "$out" -x 'worktree-batch: removed=1 kept=0 absent=1'
check "an already-absent worktree is not pruned" [ "$(lines "$FIX/worktree.log")" -eq 11 ]
out="$(bash "$WB" apply "$TMP/no-such-file" 2>&1)"; rc=$?
check "worktree apply refuses an unreadable file" [ "$rc" -eq 2 ]
out="$(bash "$WB" apply "$TMP" 2>&1)"; rc=$?
check "worktree apply refuses a list it cannot read through" [ "$rc" -eq 2 ]
check "a failed list read prunes nothing" [ "$(lines "$FIX/worktree.log")" -eq 11 ]
out="$(WT_DRY_FAIL=1 bash "$WB" plan 2>&1)"; rc=$?
check "worktree plan fails when the dry run fails" [ "$rc" -eq 1 ]
check "a failed dry run shows its diagnostics" grepq "$out" 'ERR clean-garden: boom'

# --- jira-batch.sh ---------------------------------------------------------
JB="$FIX/scripts/cleanup/jira-batch.sh"
cat > "$FIX/scripts/jira/dist/index.js" <<'EOF'
const fs = require('fs');
const path = require('path');
const a = process.argv.slice(2);
fs.appendFileSync(path.join(__dirname, 'calls.log'), a.join(' ') + '\n');
if (a[0] === 'list') for (let i = 1; i <= Number(process.env.LIST_ROWS || 25); i++) console.log(`HIMMEL-${i}\tTask\tTo Do\tTitle ${i}`);
EOF
JLOG="$FIX/scripts/jira/dist/calls.log"
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" plan stale 2>&1)"; rc=$?
printf '%s\n' "$out" > "$TMP/j-plan.txt"
check "jira plan exits 0" [ "$rc" -eq 0 ]
check "jira plan lists at most 20" [ "$(grep -vc '^#' "$TMP/j-plan.txt")" -eq 20 ]
check "jira plan labels each row" grepq "$out" -x "$(printf 'HIMMEL-1\tstale')"
check "jira plan names what waits for the next run" grepq "$out" -x '# candidates=25 batch=20 next-run=5'
check "jira plan only reads" [ "$(grep -c '^edit' "$JLOG")" -eq 0 ]
check "jira plan quotes the label in its JQL" grepq "$(cat "$JLOG")" -F 'labels not in ("stale")'
out="$(LIST_ROWS=500 JIRA_PROJECT_KEY=HIMMEL bash "$JB" plan version 2>&1)"; rc=$?
check "jira plan marks counts cut by the list limit" grepq "$out" -x '# candidates=500+ batch=20 next-run=480+'
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" apply "$TMP/no-such-file" 2>&1)"; rc=$?
check "jira apply refuses an unreadable file" [ "$rc" -eq 2 ]
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" apply "$TMP" 2>&1)"; rc=$?
check "jira apply refuses a list it cannot read through" [ "$rc" -eq 2 ]
for i in $(seq 1 21); do printf 'HIMMEL-%s\tstale\n' "$i"; done > "$TMP/j-21.txt"
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" apply "$TMP/j-21.txt" 2>&1)"; rc=$?
check "jira apply refuses 21" [ "$rc" -eq 1 ]
check "the jira refusal names the cap" grepq "$out" 'over the cap of 20'
check "a refused jira batch writes nothing" [ "$(grep -c '^edit' "$JLOG")" -eq 0 ]
printf 'HIMMEL-1\tstale\nHIMMEL-2\twontfix\n' > "$TMP/j-bad.txt"
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" apply "$TMP/j-bad.txt" 2>&1)"; rc=$?
check "jira apply refuses a label outside the hygiene set" [ "$rc" -eq 1 ]
check "a refused label writes nothing" [ "$(grep -c '^edit' "$JLOG")" -eq 0 ]
out="$(JIRA_PROJECT_KEY=HIMMEL bash "$JB" apply "$TMP/j-plan.txt" 2>&1)"; rc=$?
check "jira apply passes 20" [ "$rc" -eq 0 ]
check "jira apply adds the label through jira edit" grepq "$(cat "$JLOG")" -x 'edit HIMMEL-20 --add-labels stale'
check "jira apply edits 20 tickets" [ "$(grep -c '^edit' "$JLOG")" -eq 20 ]
check "jira apply never touches a title" [ "$(grep -c -- '--title' "$JLOG")" -eq 0 ]
check "jira apply reports its counts" grepq "$out" -x 'jira-batch: labeled=20 failed=0'

echo "passed=$passes failed=$fails"
[ "$fails" -eq 0 ]
