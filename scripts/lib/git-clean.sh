#!/usr/bin/env bash
# scripts/lib/git-clean.sh — shared env-scrub helper for trust-path git calls
#
# WHY: a git subprocess on a trust path inherits the CALLER's repository-
# redirecting GIT_* variables. An attacker-set value for any of them steers
# which repo/worktree/index/object store the call actually answers about
# (the full list below) — PR 1212 (anchor-handoff.sh, `ls-files --error-unmatch` under a
# poisoned GIT_DIR) and PR 1217 (plugin-profiles.mjs `primaryCheckout`, the
# same class via `git rev-parse --git-common-dir`) are both this bug.
#
# The scrubbed set is git's own list of repository-local variables, as printed
# by `git rev-parse --local-env-vars` (git help environment): GIT_DIR,
# GIT_WORK_TREE, GIT_COMMON_DIR, GIT_INDEX_FILE, GIT_OBJECT_DIRECTORY,
# GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_PREFIX, GIT_IMPLICIT_WORK_TREE,
# GIT_GRAFT_FILE, GIT_REPLACE_REF_BASE, GIT_SHALLOW_FILE, GIT_CONFIG,
# GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT. Deliberately NOT scrubbed:
# GIT_NO_REPLACE_OBJECTS, which is in that list but redirects nothing — it is
# a hardening switch callers set on purpose (clear-cr-marker.sh),
# and clearing it would re-enable replace refs. scripts/lanes/git-clean.mjs
# carries the identical set.
#
# CAUTION — git hooks: `GIT_INDEX_FILE` is NOT always attacker-controlled
# noise to scrub. A running git hook (e.g. `pre-commit` under `commit -a`)
# can set it legitimately to the lock file it is committing through, and a
# hook-invoked trust-path script that calls `git_env_scrub` unconditionally
# near the top would unset that real value, so a later `git diff --cached`
# in the SAME script then reads the wrong (default) index instead of the
# hook's. A trust-path script that may run AS a git hook must not scrub
# GIT_INDEX_FILE file-wide — either scrub only around the specific
# non-index trust-path call (`git_clean -C ... rev-parse ...`, never a bare
# `git_env_scrub`), or scrub the other three and leave GIT_INDEX_FILE alone
#
# Source this file and use either form on any trust-path script
# (scripts/handover/**, scripts/lanes/**, scripts/hooks/**, scripts/cr/**,
# scripts/lib/go-gate.sh):
#
#   Per-call:            git_clean -C "$repo_root" rev-parse --git-common-dir
#   Once, near the top:  git_env_scrub   # then bare `git` calls are safe
#
# `check-git-env-scrub.sh` (the pre-commit/CI gate) treats a `git_clean` call
# as already-scrubbed per-call, and a `git_env_scrub` call before a script's
# first bare `git` invocation as scrubbing the whole file.
#
# git-env-ok: this file IS the scrub mechanism — git_clean's own `env -u`
# prefix on its `git "$@"` call is the scrub, not a bare invocation needing one.
git_clean() {
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_PREFIX \
        -u GIT_IMPLICIT_WORK_TREE -u GIT_GRAFT_FILE \
        -u GIT_REPLACE_REF_BASE -u GIT_SHALLOW_FILE -u GIT_CONFIG \
        -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT git "$@"
}

git_env_scrub() {
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
        GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE \
        GIT_REPLACE_REF_BASE GIT_SHALLOW_FILE GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
}
