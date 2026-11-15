#!/usr/bin/env bash
# Pre-push hook: cross-platform validation gate for shell/script changes.
#
# Friction this prevents: bash and node scripts in `scripts/` can ship with
# platform-specific bugs that only surface on Linux or macOS — e.g.
# `python` vs `python3`, /bin/sh shims, UTF-8 BOM mojibake, or unquoted `#`
# in YAML paths. CR catches some; many slip.
#
# Gate: if the diff vs main touches any cross-platform-sensitive path,
# require either
#   1. a commit body line `Platforms tested: <list>` in at least one
#      non-merge commit of the branch (scripts/lib/attest-trailers.sh, the
#      one reader CI commit-lint and ready-check item 5 call too), OR
#   2. an explicit push-time bypass.
# A trailer carried only by a merge commit, or written in the PR body,
# counts at no gate.
#
# The line itself is a self-attestation — we don't try to verify the
# claim. The point is forcing the operator to acknowledge the cross-
# platform surface before push, which is what catches the bugs early.
#
# Sensitive paths (basename or glob):
#   *.sh, *.bash, *.zsh, *.ps1, *.psm1, *.psd1, *.cmd, *.bat
#   scripts/**, **/bin/*
#
# Skip if changed-file set is empty after filtering.
#
# Bypass (these clear the PUSH only; CI commit-lint and ready-check ignore them):
#   PLATFORMS_TESTED_OK=1 git push ...    (env-var skip; logs WARNING)
#   `[skip platforms-check]` in any commit msg being pushed
#   git push --no-verify ...              (skip all pre-push hooks)
#
# Exit codes:
#   0 — pass (no sensitive files, attestation present, or bypass)
#   1 — block (sensitive files changed + no attestation + no bypass)
#   2 — block (cannot evaluate — fail-closed: can't source guardrails/lib.sh,
#       can't read the current branch, or no diff base resolves on the online
#       path)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# default_branch() resolves the protected default (main OR master)
# used as the diff base below. Fail-closed: a missing guardrail substrate means
# we cannot compute the right base, so refuse the push.
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../guardrails/lib.sh" ] && . "$SCRIPT_DIR/../guardrails/lib.sh"; } 2>/dev/null; then
    echo "→ platforms-check: cannot source guardrails/lib.sh — refusing the push (rc=2 = cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi
# The one reader of the trailer rule (regexes, file classes, which commits count).
# shellcheck source=../lib/attest-trailers.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/attest-trailers.sh" ] && . "$SCRIPT_DIR/../lib/attest-trailers.sh"; } 2>/dev/null; then
    echo "→ platforms-check: cannot source scripts/lib/attest-trailers.sh — refusing the push (rc=2 = cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi

# Resolve THIS worktree's branch via lib.sh::_branch. `git branch
# --show-current` is worktree-correct under a normal pre-push (git points GIT_DIR
# at the worktree's own gitdir) but reads the PRIMARY worktree's HEAD if GIT_DIR
# is aimed at the shared .git; routing through _branch keeps the pre-push gates'
# branch reads on one path. _branch also returns rc=2 on an unreadable HEAD so we fail
# CLOSED with a clear diagnostic instead of letting `set -e` abort opaquely.
rc=0
branch=$(_branch) || rc=$?
if [ "$rc" -eq 2 ]; then
    echo "→ platforms-check: cannot resolve current branch (lib.sh::_branch rc=2) — refusing the push (cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi

# Detached HEAD (empty branch, rc=1) or a protected default (main/master): skip.
# no-push-to-main covers main/master; detached HEAD has no sensible diff base.
if [ -z "$branch" ] || is_on_main; then
    exit 0
fi

if [ "${PLATFORMS_TESTED_OK:-0}" = "1" ]; then
    echo "→ platforms-check: PLATFORMS_TESTED_OK=1 — skipping (WARNING: verify cross-platform behaviour manually before merge)" >&2
    exit 0
fi

# Resolve diff base: prefer origin/<default>, NOT local <default>.
# Rationale: linked git worktrees cannot fast-forward their local default-branch
# ref while the primary worktree owns that checkout. That made
# `git diff <default>...HEAD` re-flag every shell/script file that was
# already on origin/<default> but not yet in the linked worktree's local
# copy.
# origin/<default> is the actual push target; comparing against it is what
# the gate is conceptually about. <default> = main OR master.
#
# Refresh origin/<default> first (silent, single ref, ~1s) so offline / very
# stale clones still get a fair comparison. Failure (no network, no
# remote, etc.) is non-fatal - we fall back to whatever origin/<default> is
# locally.
#
# PLATFORMS_TESTED_NO_FETCH=1 skips the fetch for offline workflows.
db=$(default_branch)
if [ "${PLATFORMS_TESTED_NO_FETCH:-0}" != "1" ]; then
    git fetch -q origin "$db" 2>/dev/null || true
fi

diff_base=""
if git rev-parse --verify --quiet "origin/$db" >/dev/null; then
    diff_base="origin/$db"
elif git rev-parse --verify --quiet "$db" >/dev/null; then
    diff_base="$db"
elif [ "${PLATFORMS_TESTED_NO_FETCH:-0}" = "1" ]; then
    # No resolvable base AND the operator opted into offline mode (NO_FETCH):
    # a shallow/offline clone legitimately may not carry the default ref. We
    # cannot evaluate the gate, but blocking here would break the documented
    # offline workflow — skip with a LOUD warning.
    echo "→ platforms-check: no 'origin/$db' or local '$db' ref and PLATFORMS_TESTED_NO_FETCH=1 — cannot compute diff; SKIPPING the gate (WARNING: cross-platform surface NOT checked — verify manually before merge)" >&2
    exit 0
else
    # Online path: we attempted `git fetch origin $db` and STILL cannot resolve
    # any base. That is a genuinely broken state (default renamed and origin/HEAD
    # not pointing at it, corrupt refs) — not a normal clone, which always has
    # origin/<default>. Fail CLOSED: refusing the push beats silently
    # skipping the gate on an unattested change.
    echo "→ platforms-check: no 'origin/$db' or local '$db' ref after fetch — refusing the push (rc=2 = cannot evaluate the gate). Set PLATFORMS_TESTED_NO_FETCH=1 for a known-offline/shallow clone, or bypass with PLATFORMS_TESTED_OK=1 / git push --no-verify." >&2
    exit 2
fi

# Fail CLOSED if the diff itself can't be computed. The 3-dot
# range needs a merge base; an orphan/unrelated-history branch makes `git diff`
# exit non-zero. The old `|| true` swallowed that to an empty list, which the
# `[ -z ]` line below then treated as "no changes" → a silent PASS on a branch
# we never actually inspected. An empty diff (genuinely no changes) still exits
# 0 via rev-parse'd success + the `[ -z ]` skip.
if ! changed=$(git diff --name-only "${diff_base}...HEAD" 2>/dev/null); then
    echo "→ platforms-check: cannot compute diff vs ${diff_base} (no merge base / git error) — refusing the push (rc=2 = cannot evaluate; bypass with PLATFORMS_TESTED_OK=1 or git push --no-verify)" >&2
    exit 2
fi
[ -z "$changed" ] && exit 0

# Filter sensitive paths. Docs-only Markdown/text is never a script, even under
# scripts/ (the file class lives in scripts/lib/attest-trailers.sh).
if ! sensitive=$(attest_files platforms <<<"$changed"); then
    echo "→ platforms-check: cannot classify the changed files — refusing the push (rc=2 = cannot evaluate; bypass with PLATFORMS_TESTED_OK=1 or git push --no-verify)" >&2
    exit 2
fi
if [ -z "$sensitive" ]; then
    exit 0
fi

# The skip marker is a push-time bypass: it keeps its own scan of every message in the
# push range (merges included, as before). CI and ready-check ignore it.
# `[[:space:]]`, not `\s`: `\s` is a GNU grep extension, and BSD grep (macOS) reads it as
# a LITERAL 's', so an INDENTED marker would silently fail to match. A here-string, not
# `printf ... | grep -q` (grep -q's early exit SIGPIPEs the writer once the
# range exceeds the pipe buffer, which pipefail turns into a false "not found").
commit_msgs=$(git log --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)
if grep -qiE '^[[:space:]]*\[skip platforms-check\]' <<<"$commit_msgs"; then
    echo "→ platforms-check: [skip platforms-check] in commit msg — skipping (WARNING: verify cross-platform behaviour manually)" >&2
    exit 0
fi

att_rc=0
att_out=$(bash "$SCRIPT_DIR/../lib/attest-trailers.sh" range "$diff_base" HEAD --only platforms 2>/dev/null) || att_rc=$?  # swallow-ok: the helper exit code is mapped just below, rc 1 is a missing trailer and any other rc refuses the push
case "$att_rc" in
    0)
        line=$(printf '%s\n' "$att_out" | sed -n 's/^ATTEST platforms needed found: //p' | head -n 1)
        echo "→ platforms-check: ${line}" >&2
        exit 0 ;;
    1) ;;
    *)
        echo "→ platforms-check: cannot evaluate the trailers (the helper exited ${att_rc}) — refusing the push (rc=2 = cannot evaluate; bypass with PLATFORMS_TESTED_OK=1 or git push --no-verify)" >&2
        exit 2 ;;
esac

merge_note=""
merge_msgs=$(git log --merges --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)  # swallow-ok: an unreadable merge list only drops the case (c) note, the refusal below is already decided
if grep -qiE "$ATTEST_PLATFORMS_RE" <<<"$merge_msgs"; then
    merge_note="
   A conforming 'Platforms tested:' trailer is present only in a merge commit;
   merges never attest — add one ordinary commit carrying it.
"
fi

# Block.
cat >&2 <<EOF
⛔ platforms-check: this push touches cross-platform-sensitive files but
   no \`Platforms tested:\` attestation was found in any non-merge commit
   on the branch.
${merge_note}
   Sensitive files changed vs ${diff_base}:
$(printf '%s\n' "$sensitive" | sed 's/^/     /')

   Fix:
   Add one more ordinary (non-merge) commit whose body carries the line,
   then push again (for example \`git commit --allow-empty\` with a body of):
          Platforms tested: linux
   Never \`git commit --amend\`.
   The line must name at least one recognised platform token:
        linux, windows, macos, ubuntu, debian, fedora, arch, mac,
        darwin, wsl, posix, gitbash, git-bash, powershell, pwsh
   An empty value (\`Platforms tested:\`) or an unrecognised value
   (\`Platforms tested: yes\`) does NOT count.

   Why: bash and node scripts in this repo run on Linux and macOS.
   Platform-specific bugs can slip through CR (python vs python3,
   /bin/sh shims). This gate requires acknowledging the platforms tested.
EOF
exit 1
