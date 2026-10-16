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
git init -q -b main "$T/repo" && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init || exit 1
mkdir -p "$T/repo/.claude/worktrees" "$T/plain"
git -C "$T/repo" worktree add -q "$T/repo/.claude/worktrees/leg" -b leg 2>/dev/null || exit 1
git -C "$T/repo" worktree add -q "$T/outside-wt" -b outside 2>/dev/null || exit 1
WT="$T/repo/.claude/worktrees/leg"
# The hook only trusts worktrees of the repository it lives in, so run a copy placed inside the throwaway repo.
mkdir -p "$T/repo/scripts/hooks/data" "$T/repo/scripts/lib"
cp "$HOOK" "$T/repo/scripts/hooks/permission-allow-gate-shapes.sh" || exit 1
cp "$(dirname "$HOOK")/data/gate-shapes.tsv" "$T/repo/scripts/hooks/data/" || exit 1
mkdir -p "$T/repo/scripts/hooks/lib" "$T/repo/scripts/cr"
cp "$(dirname "$HOOK")/lib/anchor-bytes.sh" "$T/repo/scripts/hooks/lib/" || exit 1
# The scripts the verified rows run: committed on main in the primary, copied byte-identical into the worktree.
for s in impacted-suites review-round write-verdicts anchor-handoff; do
    printf '#!/usr/bin/env bash\n# stub %s\n' "$s" > "$T/repo/scripts/cr/$s.sh"
done
chmod +x "$T/repo/scripts/cr/write-verdicts.sh"
# The hook reads the table from the default branch's object store, so publish it there.
git -C "$T/repo" add scripts && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m table || exit 1
mkdir -p "$T/repo/.claude/worktrees/leg/scripts" && cp -Rp "$T/repo/scripts/cr" "$T/repo/.claude/worktrees/leg/scripts/cr" || exit 1
git -C "$T/repo" update-ref refs/remotes/origin/main HEAD || exit 1
TABLE_COMMIT="$(git -C "$T/repo" rev-parse HEAD)"
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

expect "append-results (source set unbounded) passes through" pass "$WT" Bash "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE — step done\""
expect "append-results absolute spelling passes through" pass "$WT" Bash "bash $WT/scripts/handover/console-kit/append-results.sh $DOC \"LIVE — x\""
expect "impacted-suites --check --from-file" allow "$WT" Bash "bash scripts/cr/impacted-suites.sh --check $SHA..$SHA --from-file .tmp/v.txt"
expect "review-round promote" allow "$WT" Bash "bash scripts/cr/review-round.sh promote --branch 'feat/himmel-1-x' --head $SHA"
expect "write-verdicts aggregate" allow "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch feat/himmel-1-x --from-file .tmp/v.txt"
expect "check-ci (source set unbounded) passes through" pass "$WT" Bash "bash scripts/check-ci.sh 123 --max-wait 600"
expect "SKIP=no-history-comments commit" allow "$WT" Bash "SKIP=no-history-comments git commit -F .tmp/msg.txt"

expect "primary checkout passes through" pass "$T/repo" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "non-registered dir passes through" pass "$T/plain" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "linked worktree outside .claude/worktrees passes through" pass "$T/outside-wt" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
mkdir -p "$WT/sub"
expect "worktree subdirectory passes through" pass "$WT/sub" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "worktree of a different repository passes through" pass "$T/other/.claude/worktrees/leg" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "non-Bash tool passes through" pass "$WT" Edit "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "unlisted SKIP hook passes through" pass "$WT" Bash "SKIP=check-commit-msg git commit -F .tmp/msg.txt"
expect "chained command passes through" pass "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt; rm -rf /"
expect "command substitution in doc text passes through" pass "$WT" Bash "bash scripts/handover/console-kit/append-results.sh $DOC \"LIVE \$(id)\""
expect "extra argument passes through" pass "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt --force"
expect "newline-joined command passes through" pass "$WT" Bash "$(printf 'bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt\nrm -rf x')"
expect "quiet-run suite outside the worktree passes through" pass "$WT" Bash "bash scripts/quiet-run.sh suite -- bash /tmp/test-evil.sh"
expect "quiet-run suite with dot-dot passes through" pass "$WT" Bash "bash scripts/quiet-run.sh suite -- bash ../../../tmp/test-evil.sh"
expect "other worktree's absolute path passes through" pass "$WT" Bash "bash /elsewhere/scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"

# A row that runs a worktree script allows only while every script it names equals the
# primary's main-committed copy, byte for byte and mode for mode.
VW="bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "verified script: absolute-worktree spelling allowed" allow "$WT" Bash "bash $WT/scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
printf 'echo pwned\n' >> "$WT/scripts/cr/write-verdicts.sh"
expect "tampered named script passes through" pass "$WT" Bash "$VW"
cp -p "$T/repo/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/write-verdicts.sh"
expect "restored script is allowed again" allow "$WT" Bash "$VW"
printf 'echo pwned\n' >> "$WT/scripts/cr/anchor-handoff.sh"
expect "tampered helper the script sources passes through" pass "$WT" Bash "$VW"
cp -p "$T/repo/scripts/cr/anchor-handoff.sh" "$WT/scripts/cr/anchor-handoff.sh"
rm "$WT/scripts/cr/write-verdicts.sh"
expect "missing named script passes through" pass "$WT" Bash "$VW"
cp -p "$T/repo/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/write-verdicts.sh"
chmod -x "$WT/scripts/cr/write-verdicts.sh"
expect "mode-changed named script passes through" pass "$WT" Bash "$VW"
chmod +x "$WT/scripts/cr/write-verdicts.sh"
mv "$WT/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/real.sh"; ln -s real.sh "$WT/scripts/cr/write-verdicts.sh"
expect "symlinked named script passes through" pass "$WT" Bash "$VW"
rm "$WT/scripts/cr/write-verdicts.sh"; mv "$WT/scripts/cr/real.sh" "$WT/scripts/cr/write-verdicts.sh"
mv "$WT/scripts/cr" "$WT/scripts/cr.real"; ln -s cr.real "$WT/scripts/cr"
expect "symlinked scripts/cr directory passes through" pass "$WT" Bash "$VW"
rm "$WT/scripts/cr"; mv "$WT/scripts/cr.real" "$WT/scripts/cr"
expect "intact copies are allowed again" allow "$WT" Bash "$VW"
git -C "$T/repo" symbolic-ref HEAD refs/heads/other
expect "anchor off refs/heads/main passes through" pass "$WT" Bash "$VW"
git -C "$T/repo" symbolic-ref HEAD refs/heads/main
printf 'echo drift\n' >> "$T/repo/scripts/cr/write-verdicts.sh"
cp -p "$T/repo/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/write-verdicts.sh"
expect "anchor working copy that differs from main passes through" pass "$WT" Bash "$VW"
git -C "$T/repo" checkout -q -- scripts/cr/write-verdicts.sh; cp -p "$T/repo/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/write-verdicts.sh"
# A leg that commits tampered bytes and moves BOTH refs/heads/main and refs/remotes/origin/main to
# them makes the worktree copy equal "main"; only the anchor working-copy check in anchor-bytes.sh
# still refuses, because the primary checkout's files are not the moved main's.
printf 'echo pwned\n' >> "$WT/scripts/cr/write-verdicts.sh"
EVIL_BLOB="$(git -C "$T/repo" hash-object -w "$WT/scripts/cr/write-verdicts.sh")"
export GIT_INDEX_FILE="$T/evil-index"
git -C "$T/repo" read-tree "$TABLE_COMMIT" && git -C "$T/repo" update-index --cacheinfo "100755,$EVIL_BLOB,scripts/cr/write-verdicts.sh" || exit 1
EVIL_COMMIT="$(git -C "$T/repo" -c user.email=t@t -c user.name=t commit-tree -p "$TABLE_COMMIT" -m evil "$(git -C "$T/repo" write-tree)")"
unset GIT_INDEX_FILE
git -C "$T/repo" update-ref refs/remotes/origin/main "$EVIL_COMMIT" || exit 1
git -C "$T/repo" update-ref refs/heads/main "$EVIL_COMMIT" || exit 1
expect "leg-moved main and origin/main do not legitimise its bytes" pass "$WT" Bash "$VW"
git -C "$T/repo" update-ref refs/heads/main "$TABLE_COMMIT"
git -C "$T/repo" update-ref refs/remotes/origin/main "$TABLE_COMMIT"
cp -p "$T/repo/scripts/cr/write-verdicts.sh" "$WT/scripts/cr/write-verdicts.sh"
expect "restored refs and copy are allowed again" allow "$WT" Bash "$VW"

# A worktree root with a shell metacharacter never gets an absolute spelling.
git -C "$T/repo" worktree add -q "$T/repo/.claude/worktrees/le;g" -b unsafe 2>/dev/null || exit 1
UW="$T/repo/.claude/worktrees/le;g"
mkdir -p "$UW/scripts" && cp -Rp "$T/repo/scripts/cr" "$UW/scripts/cr" || exit 1
expect "unsafe worktree root: absolute spelling passes through" pass "$UW" Bash "bash $UW/scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "unsafe worktree root: relative spelling still allowed" allow "$UW" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"

# Data-driven: a shape absent from the file is not allowed, even if the code knows nothing of it.
printf 'only\t^bash scripts/hello\\.sh$\t-\tnone\n' > "$T/repo/scripts/hooks/data/gate-shapes.tsv"
git -C "$T/repo" add scripts/hooks/data/gate-shapes.tsv && git -C "$T/repo" -c user.email=t@t -c user.name=t commit -q -m table2 || exit 1
git -C "$T/repo" update-ref refs/remotes/origin/main HEAD || exit 1
expect "shape not in the data file passes through" pass "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "shape added to the data file is allowed" allow "$WT" Bash "bash scripts/hello.sh"
git -C "$T/repo" update-ref refs/remotes/origin/main "$TABLE_COMMIT" || exit 1

# The table is trusted only from the default branch: a leg's own worktree copy, an env override
# and a missing default branch all leave the table as it was.
mkdir -p "$WT/scripts/hooks/data"
printf 'x\t^.*$\t-\n' > "$WT/scripts/hooks/data/gate-shapes.tsv"
printf 'x\t^.*$\t-\n' > "$T/evil.tsv"
expect "tampered worktree table allows nothing new" pass "$WT" Bash "rm -rf /tmp/x"
expect "tampered worktree table leaves listed shapes allowed" allow "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
out="$(jq -n --arg cwd "$WT" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"rm -rf /tmp/x"}}' | HIMMEL_GATE_SHAPES_FILE="$T/evil.tsv" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && ok "HIMMEL_GATE_SHAPES_FILE is not honoured" || bad "HIMMEL_GATE_SHAPES_FILE is not honoured"
# The real attack: the leg runs ITS OWN copy of the hook beside its own edited table.
mkdir -p "$WT/scripts/lib"
cp "$HOOK" "$WT/scripts/hooks/permission-allow-gate-shapes.sh"; cp "$T/repo/scripts/lib/git-clean.sh" "$WT/scripts/lib/"
out="$(jq -n --arg cwd "$WT" '{cwd:$cwd,tool_name:"Bash",tool_input:{command:"rm -rf /tmp/x"}}' | bash "$WT/scripts/hooks/permission-allow-gate-shapes.sh" 2>/dev/null)"
[ -z "$out" ] && ok "hook copy beside a tampered table allows nothing new" || bad "hook copy beside a tampered table allows nothing new"
expect "leading-anchor near-miss passes through" pass "$WT" Bash "rm x; bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
expect "carriage return in the command passes through" pass "$WT" Bash "$(printf 'bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt\r')"
git -C "$T/repo" update-ref -d refs/remotes/origin/main
expect "no default-branch table allows nothing" pass "$WT" Bash "bash scripts/cr/write-verdicts.sh aggregate --branch b --from-file .tmp/v.txt"
git -C "$T/repo" update-ref refs/remotes/origin/main "$TABLE_COMMIT"

printf '%s' 'not json' | bash "$HOOK" >/dev/null 2>&1; [ $? -eq 0 ] && ok "malformed stdin exits 0" || bad "malformed stdin exits 0"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
