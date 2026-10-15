#!/usr/bin/env bash
# permission-allow-gate-shapes.sh — PermissionRequest hook: allow a data-listed
# set of himmel gate command shapes, inside a registered leg worktree only.
#
# WHY: the auto-mode classifier reads ordinary himmel gate commands as CI
# bypasses and parks a headed leg on a dialog only the operator can clear. The
# guardrails already fence each underlying action; this stops the classifier
# re-litigating a shape they own. It never widens a fence.
#
# Allows ONLY when ALL hold: tool is Bash; the command has no control
# character; cwd is a LINKED git worktree under .claude/worktrees/ that
# `git worktree list` registers (never the primary checkout); the WHOLE command
# matches an ERE row of data/gate-shapes.tsv. Anything else: no output, exit 0
# (pass-through, the dialog opens as before). Fails open to pass-through on
# every error; it can only ever allow, never deny.
#
# Input: PermissionRequest JSON on stdin. Output on allow:
#   {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
# env: HIMMEL_GATE_SHAPES_FILE overrides the data file (tests).
#
# PLATFORM GUARD: no .ps1 twin, by design — Linux-only console-kit leg surface.
# Bash 3.2-compatible.
set -uo pipefail
trap 'exit 0' EXIT

command -v jq >/dev/null 2>&1 || exit 0
# A caller-set GIT_DIR/GIT_WORK_TREE would steer which repo the worktree checks answer about.
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
{ [ -r "$here/../lib/git-clean.sh" ] && . "$here/../lib/git-clean.sh"; } 2>/dev/null || exit 0
git_env_scrub
input=""
IFS= read -r -d '' input 2>/dev/null || true
[ -n "$input" ] || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)" || exit 0
[ -n "$cmd" ] && [ -n "$cwd" ] && [ -d "$cwd" ] || exit 0

# No control character (newline, tab, ESC...) anywhere in the command.
case "$cmd" in *[[:cntrl:]]*) exit 0 ;; esac

top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
gitdir="$(git -C "$cwd" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || exit 0
common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ "$gitdir" != "$common" ] || exit 0
# Only worktrees of the repository this hook ships in: another repo's scripts are not ours to approve.
own_common="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ "$common" = "$own_common" ] || exit 0
case "$top" in */.claude/worktrees/*) ;; *) exit 0 ;; esac
# A relative script path resolves against cwd, so only the worktree root is allowed.
[ "$(cd "$cwd" && pwd -P)" = "$(cd "$top" && pwd -P)" ] || exit 0
git -C "$cwd" worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $top" || exit 0

shapes="${HIMMEL_GATE_SHAPES_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/data/gate-shapes.tsv}"
[ -r "$shapes" ] || exit 0

# shellcheck disable=SC2016 # sed program is a literal bracket class, nothing to expand
esc_top="$(printf '%s' "$top" | sed 's/[][\.*^$(){}?+|/]/\\&/g')"
tab="$(printf '\t')"
# The absolute-worktree spelling is unquoted in the command, so a root holding a
# shell metacharacter gets only the relative spelling.
wt_re=""
case "$top" in *[!A-Za-z0-9_./+-]*) ;; *) wt_re="(${esc_top}/)?" ;; esac
while IFS="$tab" read -r id re _fence needs; do
    case "$id" in ''|'#'*) continue ;; esac
    [ -n "$re" ] || continue
    re="${re//\{WT\}/$wt_re}"
    if [[ "$cmd" =~ $re ]]; then
        if [ "$needs" = "tracked-sh" ]; then
            # Every .sh the command names must be a file in the worktree's git index.
            set -f
            for w in $cmd; do
                case "$w" in *.sh) git -C "$top" ls-files --error-unmatch -- "${w#"$top"/}" >/dev/null 2>&1 || { set +f; exit 0; } ;; esac
            done
            set +f
        fi
        printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
        exit 0
    fi
done < "$shapes"
exit 0
