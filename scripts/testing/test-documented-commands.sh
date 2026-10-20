#!/usr/bin/env bash
# Documented commands pass the real wired hook chain.
#
# Why: the guards each test their own allow rows alone, so a command the
# harness's own docs tell a leg to run can be denied by a guard that sits
# beside the one that granted it, and no suite notices. 18 bugs in 30 days
# had that shape (guard-pr-check-literal on pr-check.md's own fence, the
# impacted-suites heredoc, a read-only grep on block-read-secrets).
#
# What it does: builds a himmel-shaped fixture (origin, a primary clone that
# is the HIMMEL_REPO anchor, a linked worktree), reads the Bash PreToolUse
# chain members from .claude/settings.json, and feeds every row of
# documented-commands.tsv through `run-hook-with-bash.js --chain <members>`
# from the fixture worktree, as a console-spawned leg. A row passes when the
# chain does not deny it: ALLOW means a hook granted it, ask means no hook
# objected (the permission flow decides). A DENY is never an expected
# verdict; a row the docs document but the chain denies is recorded as
# `xfail:<TICKET>` against a finding ticket and stays red-by-design until the
# guard or the doc changes (an xfail that stops denying fails, so it is
# removed with the fix).
#
# A lint then walks the shell fences of the documented-command docs and fails
# on a fence with no row, and on a row whose fence no longer exists.
#
# Manifest columns (tab-separated, no empty field, `-` for none, `#` comments):
#   id  doc  cwd  verdict  key  command
#   cwd      wt (worktree root) | anchor (primary checkout) | sub (a worktree subdirectory)
#   verdict  ALLOW | ask | xfail:<TICKET> | skip:<reason> (fence rows only)
#   key      first non-comment line of the fence in <doc>, whitespace-collapsed
#            (`-` for a command quoted inline rather than in a fence)
#   command  the runnable text; `⏎` stands for a newline and the tokens
#            @ANCHOR@ @WT@ @HEAD@ @BRANCH@ @SCRATCH@ @SB@ are fixture values.
#            A fence row runs the fence's commands with its comment lines
#            dropped, on the himmel lane (cwd-relative `scripts/cr/` literals,
#            pr-check-env.sh as documented).
#
# Env: DOCCMD_SRC_ROOT   tree to read hooks, settings and docs from (default: this checkout)
#      DOCCMD_MANIFEST   manifest to run (default: documented-commands.tsv beside this file)
#      DOCCMD_ONLY       run only the row ids matching this ERE (the lint is skipped)
#
# Usage: bash scripts/testing/test-documented-commands.sh
# Exit codes: 0 all rows and the lint passed, 1 at least one failed
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd -P)"
SRC="$(cd "${DOCCMD_SRC_ROOT:-$ROOT}" && pwd -P)"
MANIFEST="${DOCCMD_MANIFEST:-$HERE/documented-commands.tsv}"
ONLY="${DOCCMD_ONLY:-}"
SETTINGS="$SRC/.claude/settings.json"
LAUNCHER="$SRC/scripts/hooks/run-hook-with-bash.js"
# One row costs one node launch plus the chain; a hung member must fail the row.
ROW_TIMEOUT="${DOCCMD_ROW_TIMEOUT:-120}"

# A suite run from inside a git hook inherits GIT_DIR/GIT_INDEX_FILE, which
# would point every fixture git call at the outer repo.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY

# shellcheck source=../lib/timeout-bin.sh
. "$ROOT/scripts/lib/timeout-bin.sh"

FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }

command -v jq >/dev/null 2>&1 || { echo "FAIL fixture: jq not found"; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL fixture: node not found"; exit 1; }
[ -f "$LAUNCHER" ] || { echo "FAIL fixture: no launcher at $LAUNCHER"; exit 1; }
[ "${1:-}" = "--keys" ] || [ -f "$MANIFEST" ] || { echo "FAIL fixture: no manifest at $MANIFEST"; exit 1; }

# ---- the docs whose fenced shell the lint covers, and the --keys authoring mode ---
LINT_DOCS=(
    docs/handover/leg-preface.md
    docs/handover/leg-preface-claudex.md
    docs/handover/leg-preface-openrouter.md
    .claude/commands/pr-check.md
    docs/handover/console-template.md
    docs/internals/enforcement.md
)
while IFS= read -r f; do LINT_DOCS+=("${f#"$SRC/"}"); done < <(ls "$SRC"/scripts/cr/pr-check-ref/*.md 2>/dev/null)

# fence_keys <file> -- one line per ```bash/sh/shell/zsh fence: the first
# command line (comments skipped, whitespace-collapsed, a trailing backslash
# dropped), a space, `#` and the cksum of the whole fence with its comment and
# blank lines removed. The checksum is what makes a changed fence demand a
# fresh look at its row. Bare fences are command OUTPUT, never steps.
fence_keys() {
    awk '
        /^[ \t]*```/ {
            if (inf) { inf = 0; if (shell && first != "") print first "\t" body; next }
            info = $0; sub(/^[ \t]*```[ \t]*/, "", info); inf = 1; first = ""; body = ""
            shell = (info == "bash" || info == "sh" || info == "shell" || info == "zsh")
            next
        }
        inf && shell {
            line = $0
            if (line ~ /^[ \t]*(#|$)/) next
            gsub(/^[ \t]+|[ \t]+$/, "", line); gsub(/[ \t]+/, " ", line)
            body = body line "\001"
            if (first == "") { first = line; sub(/ ?\\$/, "", first) }
        }
    ' "$1" | while IFS=$'\t' read -r first body; do
        printf '%s #%s\n' "$first" "$(printf '%s' "${body//$'\001'/$'\n'}" | cksum | cut -d' ' -f1)"
    done
}

# --keys prints `doc<TAB>key` for every fence, for authoring manifest rows.
if [ "${1:-}" = "--keys" ]; then
    for doc in "${LINT_DOCS[@]}"; do
        [ -f "$SRC/$doc" ] || continue
        fence_keys "$SRC/$doc" | while IFS= read -r k; do printf '%s\t%s\n' "$doc" "$k"; done
    done
    exit 0
fi


# ---- chain members, read from settings so a new member is covered unasked ----
# Every PreToolUse entry on the Bash matcher that launches a --chain; the
# `if run-node.sh … else node …` command carries the member list twice, so only
# the first branch is read.
MEMBERS=()
while IFS= read -r m; do
    [ -n "$m" ] && MEMBERS+=("$m")
done < <(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("--chain"))' "$SETTINGS" \
    | sed 's/; else .*//' | grep -o -E 'scripts/hooks/[A-Za-z0-9_-]+\.sh' | grep -v 'run-hook-with-bash' | awk '!seen[$0]++')
[ "${#MEMBERS[@]}" -gt 0 ] || { echo "FAIL fixture: no Bash --chain members in $SETTINGS"; exit 1; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/doccmd.XXXXXX")" || { echo "FAIL fixture: mktemp"; exit 1; }
trap 'rm -rf "$SB"' EXIT
SB="$(cd "$SB" && pwd -P)"

# ---- fixture: origin, primary clone (the anchor), linked worktree ------------
g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main -c commit.gpgsign=false "$@"; }
ORIGIN="$SB/fx/origin"
ANCHOR="$SB/fx/himmel"
WT="$SB/fx/wt"
mkdir -p "$ORIGIN" "$SB/home" "$SB/run"
g init -q "$ORIGIN" || { echo "FAIL fixture: git init"; exit 1; }
if g -C "$SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [ "$(g -C "$SRC" rev-parse --show-toplevel)" = "$SRC" ]; then
    ( cd "$SRC" && g ls-files -z -- scripts .claude | tar --null -T - -cf - ) | tar -xf - -C "$ORIGIN" \
        || { echo "FAIL fixture: copying the tracked tree"; exit 1; }
else
    ( cd "$SRC" && tar -cf - scripts .claude ) | tar -xf - -C "$ORIGIN" \
        || { echo "FAIL fixture: copying the tree"; exit 1; }
fi
g -C "$ORIGIN" add -A
g -C "$ORIGIN" commit -qm base || { echo "FAIL fixture: commit"; exit 1; }
g clone -q "$ORIGIN" "$ANCHOR" || { echo "FAIL fixture: clone"; exit 1; }
g -C "$ANCHOR" worktree add -q -b feat/x "$WT" refs/remotes/origin/main || { echo "FAIL fixture: worktree add"; exit 1; }
HEAD_SHA="$(g -C "$WT" rev-parse HEAD)"
BRANCH=feat/x
SCRATCH="$SB/scratch.txt"
printf 'VERDICT [codex-1] = disproved\n' > "$SCRATCH"
mkdir -p "$WT/scripts/cr"

# ---- the chain, one row at a time ---------------------------------------------
# Echoes DENY, ask or ALLOW on stdout and the deny reason on $SB/reason.
chain_verdict() { # chain_verdict <cwd> <command>
    local cwd=$1 cmd=$2 args=() m rc dec
    for m in "${MEMBERS[@]}"; do args+=("$WT/$m"); done
    jq -n --arg c "$cmd" --arg cwd "$cwd" \
        '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}, cwd: $cwd, session_id: "documented-commands"}' > "$SB/payload.json"
    ( cd "$cwd" && env -i PATH="$PATH" HOME="$SB/home" TMPDIR="$SB" XDG_RUNTIME_DIR="$SB/run" \
        LANG=C.UTF-8 LC_ALL=C.UTF-8 CLAUDE_PROJECT_DIR="$WT" HIMMEL_REPO="$ANCHOR" HIMMEL_CONSOLE_LEG=1 \
        ${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" "$ROW_TIMEOUT"} node "$LAUNCHER" --chain "${args[@]}" \
        < "$SB/payload.json" > "$SB/out" 2> "$SB/err" )
    rc=$?
    dec=""
    if [ -s "$SB/out" ] && ! dec=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$SB/out" 2>/dev/null); then
        dec="?"
    fi
    case $dec in '' | allow | deny | ask) ;; *) rc=99 ;; esac
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        printf 'launcher rc=%s or unreadable decision: %s' "$rc" "$(head -c 500 "$SB/err")" > "$SB/reason"
        echo ERROR
    elif [ "$rc" -eq 2 ] || [ "$dec" = deny ]; then
        { head -c 1000 "$SB/err"; jq -r '.hookSpecificOutput.permissionDecisionReason // empty' "$SB/out" 2>/dev/null; } | head -c 1000 > "$SB/reason"
        echo DENY
    elif [ "$dec" = allow ]; then
        echo ALLOW
    else
        echo ask
    fi
}

cwd_for() { # cwd_for <kind>
    case $1 in
        wt) echo "$WT" ;;
        anchor) echo "$ANCHOR" ;;
        sub) mkdir -p "$WT/scripts/hooks"; echo "$WT/scripts/hooks" ;;
        *) return 1 ;;
    esac
}

subst() { # subst <text> -- fixture tokens and the newline marker
    local t=$1
    t=${t//@ANCHOR@/$ANCHOR}
    t=${t//@WT@/$WT}
    t=${t//@HEAD@/$HEAD_SHA}
    t=${t//@BRANCH@/$BRANCH}
    t=${t//@SCRATCH@/$SCRATCH}
    t=${t//@SB@/$SB}
    printf '%s' "${t//⏎/$'\n'}"
}

ROWS=0
RAN=0
declare -a ROW_IDS=()
while IFS=$'\t' read -r id doc cwdk verdict key cmd; do
    case $id in '' | '#'*) continue ;; esac
    ROW_IDS+=("$id")
    ROWS=$((ROWS + 1))
    if [ -z "$cmd" ] || [ -z "$key" ]; then fail "$id: malformed manifest row (6 non-empty tab-separated fields)"; continue; fi
    case $verdict in
        skip:*) continue ;;
        ALLOW | ask | xfail:*) ;;
        *) fail "$id: unknown verdict '$verdict'"; continue ;;
    esac
    [ -n "$ONLY" ] && ! [[ $id =~ $ONLY ]] && continue
    cwd=$(cwd_for "$cwdk") || { fail "$id: unknown cwd kind '$cwdk'"; continue; }
    got=$(chain_verdict "$cwd" "$(subst "$cmd")")
    RAN=$((RAN + 1))
    if [ "$got" = ERROR ]; then
        fail "$id: the chain did not run to a verdict: $(tr '\n' ' ' < "$SB/reason")"
        continue
    fi
    case $verdict in
        xfail:*)
            if [ "$got" = DENY ]; then
                pass "$id: denied as recorded (${verdict#xfail:}) [$doc]"
            else
                fail "$id: ${verdict#xfail:} is recorded as denied but the chain now returns $got; drop the xfail"
            fi ;;
        *)
            if [ "$got" = DENY ]; then
                fail "$id: documented in $doc, expected $verdict, chain DENIED: $(tr '\n' ' ' < "$SB/reason")"
            elif [ "$verdict" = ALLOW ] && [ "$got" != ALLOW ]; then
                fail "$id: documented in $doc, expected ALLOW, chain returned $got"
            else
                pass "$id: $got [$doc]"
            fi ;;
    esac
done < "$MANIFEST"
[ "$ROWS" -gt 0 ] || fail "manifest has no rows"
[ -z "$ONLY" ] || [ "$RAN" -gt 0 ] || fail "DOCCMD_ONLY=$ONLY matched no row that runs"

# ---- lint: every shell fence in the documented-command docs has a row ---------
if [ -n "$ONLY" ]; then
    [ "$FAILED" -eq 0 ] && { echo "OK documented commands: rows matching $ONLY pass (lint skipped)"; exit 0; }
    echo "FAILED: $FAILED"
    exit 1
fi
KEYS_FILE="$SB/keys.tsv"
: > "$KEYS_FILE"
while IFS=$'\t' read -r id doc cwdk verdict key cmd; do
    case $id in '' | '#'*) continue ;; esac
    [ "$key" = "-" ] && continue
    printf '%s\t%s\n' "$doc" "$key" >> "$KEYS_FILE"
done < "$MANIFEST"

FENCES=0
for doc in "${LINT_DOCS[@]}"; do
    [ -f "$SRC/$doc" ] || continue
    while IFS= read -r k; do
        [ -n "$k" ] || continue
        FENCES=$((FENCES + 1))
        if ! grep -F -x -q -- "$(printf '%s\t%s' "$doc" "$k")" "$KEYS_FILE"; then
            fail "lint: a fenced step in $doc has no row: $k"
        fi
    done < <(fence_keys "$SRC/$doc")
done
pass "lint: $FENCES fenced shell steps checked against $ROWS rows"

# every manifest key still names a fence in its doc (a stale row hides a drift)
while IFS=$'\t' read -r doc key; do
    [ -f "$SRC/$doc" ] || { fail "lint: a row names $doc, which does not exist"; continue; }
    doc_keys=$(fence_keys "$SRC/$doc")
    grep -F -x -q -- "$key" <<< "$doc_keys" || fail "lint: a row's fence is gone from $doc: $key"
done < "$KEYS_FILE"

if [ "$FAILED" -eq 0 ]; then
    echo "OK documented commands: $ROWS rows, every row passes the chain"
    exit 0
fi
echo "FAILED: $FAILED"
exit 1
