#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2181 # compact status assertions
# Suite for scripts/hooks/permission-allow-gate-shapes.sh: the
# PermissionRequest hook allows ONLY an exact data-listed gate shape, ONLY in a
# registered linked worktree under .claude/worktrees/, and passes everything
# else through (no output). Builds a throwaway repo + linked worktree.
# env: HOOK overrides the hook under test (RED run against a tree without it).
#
# bash 3.2-safe. PLATFORM GUARD: Linux-only console-kit surface, no .ps1 twin.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/permission-allow-gate-shapes.sh}"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/gate-shapes.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT
git init -q "$T/repo" && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || exit 1
mkdir -p "$T/repo/.claude/worktrees" "$T/plain"
git -C "$T/repo" worktree add -q "$T/repo/.claude/worktrees/leg" -b leg 2>/dev/null || exit 1
git -C "$T/repo" worktree add -q "$T/outside-wt" -b outside 2>/dev/null || exit 1
WT="$T/repo/.claude/worktrees/leg"
# The hook only trusts worktrees of the repository it lives in, so run a copy placed inside the throwaway repo.
mkdir -p "$T/repo/scripts/hooks/data" "$T/repo/scripts/lib"
cp "$HOOK" "$T/repo/scripts/hooks/permission-allow-gate-shapes.sh" || exit 1
cp "$(dirname "$HOOK")/data/gate-shapes.tsv" "$T/repo/scripts/hooks/data/" || exit 1
cp "$(dirname "$HOOK")/../lib/git-clean.sh" "$T/repo/scripts/lib/" || exit 1
HOOK="$T/repo/scripts/hooks/permission-allow-gate-shapes.sh"
git init -q "$T/other" && git -C "$T/other" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || exit 1
mkdir -p "$T/other/.claude/worktrees"
git -C "$T/other" worktree add -q "$T/other/.claude/worktrees/leg" -b leg 2>/dev/null || exit 1
SHA="$(printf 'a%.0s' $(seq 1 40))"
DOC="/home/u/handovers/x/HIMMEL-1-N1-foo.md"

# run <cwd> <tool> <command> -> hook stdout
run() {
    jq -n --arg cwd "$1" --arg tool "$2" --arg cmd "$3" \
        '{hook_event_name:"PermissionRequest",cwd:$cwd,tool_name:$tool,tool_input:{command:$cmd}}' \
        | bash "$HOOK" 2>/dev/null
}
# expect <label> <allow|pass> <cwd> <tool> <command>
expect() {
    local label="$1" want="$2" out got
    out="$(run "$3" "$4" "$5")"
    if printf '%s' "$out" | jq -e '.hookSpecificOutput.decision.behavior == "allow"' >/dev/null 2>&1; then got=allow
    elif [ -z "$out" ]; then got=pass; else got="?($out)"; fi
    if [ "$got" = "$want" ]; then ok "$label"; else bad "$label (want $want, got $got)"; fi
}

expect "append-results relative in worktree" allow "$WT" Bash "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE — step done\""
expect "append-results absolute-worktree unquoted" allow "$WT" Bash "bash $WT/scripts/handover/console-kit/append-results.sh $DOC \"LIVE — x\""
expect "impacted-suites --check --from-file" allow "$WT" Bash "bash scripts/cr/impacted-suites.sh --check $SHA..$SHA --from-file .tmp/v.txt"
expect "review-round promote" allow "$WT" Bash "bash scripts/cr/review-round.sh promote --branch 'feat/himmel-1-x' --head $SHA"
expect "write-verdicts aggregate" allow "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch feat/himmel-1-x --from-file .tmp/v.txt"
expect "check-ci" allow "$WT" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "SKIP=no-history-comments commit" allow "$WT" Bash "SKIP=no-history-comments git commit -F .tmp/msg.txt"

expect "primary checkout passes through" pass "$T/repo" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "non-registered dir passes through" pass "$T/plain" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "linked worktree outside .claude/worktrees passes through" pass "$T/outside-wt" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
mkdir -p "$WT/sub"
expect "worktree subdirectory passes through" pass "$WT/sub" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "worktree of a different repository passes through" pass "$T/other/.claude/worktrees/leg" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "non-Bash tool passes through" pass "$WT" Edit "bash scripts/check-ci.sh 123 --max-wait 600"
expect "unlisted SKIP hook passes through" pass "$WT" Bash "SKIP=check-commit-msg git commit -F .tmp/msg.txt"
expect "chained command passes through" pass "$WT" Bash "bash scripts/check-ci.sh 123 --max-wait 600; rm -rf /"
expect "command substitution in doc text passes through" pass "$WT" Bash "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE \$(id)\""
expect "extra argument passes through" pass "$WT" Bash "bash scripts/check-ci.sh 123 --max-wait 600 --force"
expect "newline-joined command passes through" pass "$WT" Bash "$(printf 'bash scripts/check-ci.sh 123 --max-wait 600\nrm -rf x')"
expect "quiet-run suite outside the worktree passes through" pass "$WT" Bash "bash scripts/quiet-run.sh suite -- bash /tmp/test-evil.sh"
expect "quiet-run suite with dot-dot passes through" pass "$WT" Bash "bash scripts/quiet-run.sh suite -- bash ../../../tmp/test-evil.sh"
expect "other worktree's absolute path passes through" pass "$WT" Bash "bash /elsewhere/scripts/check-ci.sh 123 --max-wait 600"

# A tracked-only row: the suite file must be in the git index.
mkdir -p "$WT/scripts/hooks"
printf '#!/bin/sh\n' > "$WT/scripts/quiet-run.sh"; printf '#!/bin/sh\n' > "$WT/scripts/hooks/test-foo.sh"
git -C "$WT" add scripts/quiet-run.sh scripts/hooks/test-foo.sh
printf '#!/bin/sh\n' > "$WT/scripts/hooks/test-untracked.sh"
expect "quiet-run suite of a tracked file" allow "$WT" Bash "bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-foo.sh"
expect "quiet-run suite of an untracked file passes through" pass "$WT" Bash "bash scripts/quiet-run.sh suite -- bash scripts/hooks/test-untracked.sh"

# A worktree root with a shell metacharacter never gets an absolute spelling.
git -C "$T/repo" worktree add -q "$T/repo/.claude/worktrees/le;g" -b unsafe 2>/dev/null || exit 1
UW="$T/repo/.claude/worktrees/le;g"
expect "unsafe worktree root: absolute spelling passes through" pass "$UW" Bash "bash $UW/scripts/check-ci.sh 123 --max-wait 600"
expect "unsafe worktree root: relative spelling still allowed" allow "$UW" Bash "bash scripts/check-ci.sh 123 --max-wait 600"

# Data-driven: a shape absent from the file is not allowed, even if the code knows nothing of it.
printf 'only\t^bash scripts/hello\\.sh$\tnone\n' > "$T/shapes.tsv"
out="$(jq -n --arg cwd "$WT" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash scripts/check-ci.sh 1 --max-wait 2"}}' | HIMMEL_GATE_SHAPES_FILE="$T/shapes.tsv" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && ok "shape not in the data file passes through" || bad "shape not in the data file passes through"
out="$(jq -n --arg cwd "$WT" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"bash scripts/hello.sh"}}' | HIMMEL_GATE_SHAPES_FILE="$T/shapes.tsv" bash "$HOOK" 2>/dev/null)"
[ -n "$out" ] && ok "shape added to the data file is allowed" || bad "shape added to the data file is allowed"

printf '%s' 'not json' | bash "$HOOK" >/dev/null 2>&1; [ $? -eq 0 ] && ok "malformed stdin exits 0" || bad "malformed stdin exits 0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
