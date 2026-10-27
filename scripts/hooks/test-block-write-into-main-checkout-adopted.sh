#!/usr/bin/env bash
# Unit test for scripts/hooks/block-write-into-main-checkout.sh — an adopted
# primary's worker worktree: a chief may run `git -C <adopted primary> worktree add -b <new> <primary>/.claude/worktrees/<leaf> [<sha>]`
# when the primary is a registered himmel adapter (origin nwo in
# scripts/guardrails/himmel-adapters.json AND realpath in the handover registry).
# Every other write aimed at that primary, and the same shape aimed at an
# unregistered repo, a non-adapter repo, or himmel's own primary, stays refused.
# Platform guard: Git Bash on Windows / any POSIX bash 3.2+ (same as the
# guard; no .ps1 twin). A sibling of test-block-write-into-main-checkout.sh,
# split out so the parent suite stays under the CI per-suite cap; the harness
# below is a trimmed copy of the -wrappers sibling's (same fixtures, same FIXTURE RULE).
#
# Every row runs BOTH entry modes via `check_both`: direct-exec
# (`bash block-write-into-main-checkout.sh` with the JSON payload on stdin)
# and sourced (`bash block-terminal-write-fence.sh`, the codex adapter).
#
# FIXTURE RULE (load-bearing): fixtures are rooted under a non-temp home
# (lib-fixture-root.sh), NOT a bare `mktemp -d`: `/tmp` paths are exempted by
# is_temp_or_devnull, so a DENY row rooted there would pass as ALLOW for the wrong reason.
set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
DIRECT="$HOOKS/block-write-into-main-checkout.sh"
FENCE="$HOOKS/block-terminal-write-fence.sh"
[ -f "$DIRECT" ] || { echo "guard not found: $DIRECT" >&2; exit 1; }
[ -f "$FENCE" ]  || { echo "guard not found: $FENCE" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not on PATH"; exit 0; }
command -v jq  >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

# shellcheck source=lib-fixture-root.sh
. "$HOOKS/lib-fixture-root.sh"
_FROOT=$(fixture_root) || exit 1
FIX=$(mktemp -d "$_FROOT/.himmel-7847-adoptedfix-XXXXXX") || exit 1
trap 'rm -rf "$FIX"' EXIT

# himmel's own primary checkout, resolved the way the hook's helper resolves it.
HARNESS_COMMON="$(git -C "$HOOKS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || HARNESS_COMMON=""
HARNESS="$(cd -P "$HARNESS_COMMON/.." 2>/dev/null && pwd -P)" || HARNESS=""
[ -n "$HARNESS" ] || { echo "cannot resolve the harness primary checkout" >&2; exit 1; }

export HOME="$FIX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
git config --global user.email t@example.invalid
git config --global user.name t
unset CODEX_EXTERNAL_WRITES_OK 2>/dev/null || true
unset EDIT_ON_MAIN_OK 2>/dev/null || true

mkrepo_committed() {  # mkrepo_committed <dir> <branch> [<origin url>]
    git init -q -b "$2" "$1" >/dev/null 2>&1
    mkdir -p "$1/scripts/hooks" "$1/handovers"
    : > "$1/README.md"
    git -C "$1" add README.md >/dev/null 2>&1
    git -C "$1" commit -q -m init >/dev/null 2>&1
    [ -z "${3:-}" ] || git -C "$1" remote add origin "$3"
}

# $FIX/primary - a plain repo on main with a linked worktree $FIX/wt (the chief's cwd).
mkrepo_committed "$FIX/primary" main
git -C "$FIX/primary" worktree add -q -b feat/x "$FIX/wt" >/dev/null 2>&1

VOICE="https://github.com/yotamleo-org/himmel-voice.git"
mkrepo_committed "$FIX/adopter"       main "$VOICE"                                         # registered + adapter
mkrepo_committed "$FIX/adopter-unreg" main "$VOICE"                                         # adapter origin, NOT registered
mkrepo_committed "$FIX/notadapter"    main "https://github.com/yotamleo-org/not-an-adapter.git"  # registered, origin not an adapter
mkrepo_committed "$FIX/adopter-link"  main "$VOICE"                                         # registered; .claude/worktrees is a symlink to <primary>/src
mkdir -p "$FIX/adopter-link/.claude" "$FIX/adopter-link/src"
ln -s "$FIX/adopter-link/src" "$FIX/adopter-link/.claude/worktrees"
AD="$FIX/adopter"; UN="$FIX/adopter-unreg"; NA="$FIX/notadapter"; LK="$FIX/adopter-link"
SHA="$(git -C "$AD" rev-parse HEAD)"

# The hook reads the registry from its own environment (HANDOVER_REGISTRY), never from the command.
REG="$FIX/registry.json"
printf '{"repos":{"voice":{"path":"%s"},"na":{"path":"%s"},"lk":{"path":"%s"},"himmel":{"path":"%s"}}}\n' \
    "$AD" "$NA" "$LK" "$HARNESS" > "$REG"
export HANDOVER_REGISTRY="$REG"

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

_run() {
    local script="$1" json="$2" hookpwd="${3:-}" rc got
    if [ -n "$hookpwd" ]; then
        ( cd "$hookpwd" && printf '%s' "$json" | bash "$script" >/dev/null 2>&1 )
        rc=$?
    else
        printf '%s' "$json" | bash "$script" >/dev/null 2>&1
        rc=$?
    fi
    case "$rc" in
        0) got=allow ;;
        2) got=block ;;
        *) got="?(rc=$rc)" ;;
    esac
    printf '%s' "$got"
}

check_both() {
    local label="$1" expect="$2" json="$3" got
    got=$(_run "$DIRECT" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (direct-exec)"; else bad "$label (direct-exec) - expected $expect got $got"; fi
    got=$(_run "$FENCE" "$json")
    if [ "$got" = "$expect" ]; then ok "$label (sourced/codex)"; else bad "$label (sourced/codex) - expected $expect got $got"; fi
}

_row() { # label verdict command [cwd]
    local j
    j="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":$(printf '%s' "$3" | jq -Rs .),\"cwd\":\"${4:-$FIX/wt}\"}}"
    check_both "$1" "$2" "$j"
}

W="$AD/.claude/worktrees"

echo "== HIMMEL-7847 a chief creates a worker worktree in a registered adopted primary =="
_row "1 add -b <new> <primary>/.claude/worktrees/<leaf> <sha> (ALLOW)"       allow "git -C $AD worktree add -b feat/x-1 $W/feat+x-1 $SHA"
_row "1b same, no commit-ish (ALLOW)"                                         allow "git -C $AD worktree add -b feat/x-2 $W/feat+x-2"
_row "1c same, -q (ALLOW)"                                                    allow "git -C $AD worktree add -q -b feat/x-3 $W/feat+x-3 HEAD"
_row "1d same, chief cwd is another primary (ALLOW)"                          allow "git -C $AD worktree add -b feat/x-4 $W/feat+x-4 HEAD" "$FIX/primary"
_row "1e same, cwd /tmp (ALLOW)"                                              allow "git -C $AD worktree add -b feat/x-5 $W/feat+x-5 HEAD" /tmp
_row "1f same, cd <adopted primary> instead of -C (ALLOW)"                    allow "cd $AD && git worktree add -b feat/x-6 $W/feat+x-6 HEAD"

echo "== refusals: the repo is not a registered adapter =="
_row "2a adapter origin but not in the registry"                              block "git -C $UN worktree add -b feat/x $UN/.claude/worktrees/feat+x HEAD"
_row "2b registered but origin not in himmel-adapters.json"                   block "git -C $NA worktree add -b feat/x $NA/.claude/worktrees/feat+x HEAD"
_row "2c a plain primary"                                                     block "git -C $FIX/primary worktree add -b feat/x $FIX/primary/.claude/worktrees/feat+x HEAD"
# himmel's own primary ignores .claude/worktrees, so the hook already allows the add there;
# what must hold is that the adopted-primary helper never matches it, even when registered.
rc=0; bash "$HOOKS/../handover/chief-kit/adopted-primary.sh" "$HARNESS" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 1 ]; then ok "2d helper: himmel's own primary, registered, is not an adopted primary"; else bad "2d helper: himmel's own primary matched (rc=$rc)"; fi
rc=0; bash "$HOOKS/../handover/chief-kit/adopted-primary.sh" "$AD" >/dev/null 2>&1 || rc=$?
if [ "$rc" = 0 ]; then ok "2e helper: the registered adapter primary matches"; else bad "2e helper: the registered adapter primary did not match (rc=$rc)"; fi

echo "== refusals: the target =="
_row "3a target outside .claude/worktrees (in the primary)"                   block "git -C $AD worktree add -b feat/x $AD/feat+x HEAD"
_row "3c target climbs out with .."                                           block "git -C $AD worktree add -b feat/x $W/../feat+x HEAD"
_row "3d target nested below the leaf"                                        block "git -C $AD worktree add -b feat/x $W/a/b HEAD"
_row "3e target is .claude/worktrees itself"                                  block "git -C $AD worktree add -b feat/x $W HEAD"
_row "3f target with a trailing slash"                                        block "git -C $AD worktree add -b feat/x $W/feat+x/ HEAD"
_row "3g .claude/worktrees is a symlink to a dir inside the primary"          block "git -C $LK worktree add -b feat/x $LK/.claude/worktrees/feat+x HEAD"
_row "3h relative target"                                                     block "git -C $AD worktree add -b feat/x .claude/worktrees/feat+x HEAD"

echo "== refusals: the branch and flags =="
_row "4a no -b (detached or an existing branch)"                              block "git -C $AD worktree add $W/feat+x HEAD"
_row "4b -b main"                                                             block "git -C $AD worktree add -b main $W/feat+x HEAD"
_row "4c -b master"                                                           block "git -C $AD worktree add -b master $W/feat+x HEAD"
_row "4d -B resets an existing branch"                                        block "git -C $AD worktree add -B feat/x $W/feat+x HEAD"
_row "4e --detach"                                                            block "git -C $AD worktree add --detach $W/feat+x HEAD"
_row "4f -f"                                                                  block "git -C $AD worktree add -f -b feat/x $W/feat+x HEAD"
_row "4g --lock"                                                              block "git -C $AD worktree add --lock -b feat/x $W/feat+x HEAD"
_row "4h two -b"                                                              block "git -C $AD worktree add -b feat/x -b feat/y $W/feat+x HEAD"
_row "4i -b with a dotdot name"                                               block "git -C $AD worktree add -b feat/../x $W/feat+x HEAD"
_row "4j extra positional"                                                    block "git -C $AD worktree add -b feat/x $W/feat+x HEAD extra"
_row "4k --lock after the target"                                             block "git -C $AD worktree add $W/x HEAD --lock"
_row "4l --detach after the target"                                           block "git -C $AD worktree add $W/x HEAD --detach"
_row "4m --lock after the target, with -b"                                    block "git -C $AD worktree add -b feat/x $W/feat+x --lock HEAD"
_row "4n --detach after the commit-ish, with -b"                              block "git -C $AD worktree add -b feat/x $W/feat+x HEAD --detach"
_row "4o leaf is not the branch with slashes as plus"                         block "git -C $AD worktree add -b feat/x $W/other+worker HEAD"
_row "4p GIT_COMMON_DIR prefix redirects the worktree metadata"               block "GIT_COMMON_DIR=$UN/.git git -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "4q GIT_COMMON_DIR exported first"                                       block "export GIT_COMMON_DIR=$UN/.git && git -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "4r GIT_COMMON_DIR through env"                                          block "env GIT_COMMON_DIR=$UN/.git git -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "4s GIT_TRACE prefix names a file git writes"                            block "GIT_TRACE=$AD/trace git -C $AD worktree add -b feat/x $W/feat+x HEAD"

echo "== refusals: every other write into the adopted primary =="
_row "5a commit"                                                              block "git -C $AD commit -m x"
_row "5b checkout -b"                                                         block "git -C $AD checkout -b feat/y"
_row "5d worktree move"                                                       block "git -C $AD worktree move $W/feat+x $W/feat+y"
_row "5f touch a file in the primary"                                         block "touch $AD/f"
_row "5g allowed add, then a checkout in the same command"                    block "git -C $AD worktree add -b feat/x $W/feat+x HEAD && git -C $AD checkout -b feat/y"
_row "5h allowed add, then a touch in the same command"                       block "git -C $AD worktree add -b feat/x $W/feat+x HEAD; touch $AD/f"
_row "5i -c override on the add"                                              block "git -c core.hooksPath=/x -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "5j GIT_DIR in front of the add"                                         block "GIT_DIR=$AD/.git git -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "5k a config override env in front of the add"                           block "GIT_CONFIG_COUNT=1 git -C $AD worktree add -b feat/x $W/feat+x HEAD"
_row "5l add behind xargs"                                                    block "echo x | xargs git -C $AD worktree add -b feat/x $W/feat+x HEAD"

echo
printf 'adopted-worktree-add rows: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
