#!/usr/bin/env bash
# Pre-push hook: security-review attestation gate.
#
# Friction this prevents: code changes ship without an explicit security
# review pass. Existing CR-before-push (multi-agent code review) catches
# correctness and code-quality issues but does not specifically prompt for
# the security-focused lens that anthropics/claude-code-security-review
# was designed around (input handling, authn/authz, secrets exposure,
# command injection, SSRF, deserialization, etc.).
#
# Gate: if the diff vs main touches any non-docs code path, require either
#   1. a `Security reviewed: <token>` line in at least one non-merge commit
#      body of the branch (scripts/lib/attest-trailers.sh, the one reader
#      CI commit-lint and ready-check item 5 call too), OR
#   2. an explicit push-time bypass.
# A trailer carried only by a merge commit, or written in the PR body,
# counts at no gate.
#
# The line is a self-attestation — the gate does NOT run the review
# itself. No new headless-claude
# invocations are introduced; the operator runs the security review
# in-session (via /security-review slash command vendored from
# anthropics/claude-code-security-review, OR via any other mechanism the
# operator prefers) and attests the result in the commit message.
#
# This pattern matches the existing `platforms-tested` gate
# (`check-platforms-tested.sh`) — self-attestation with a recognised
# token vocabulary. The operator decides WHEN and HOW; the gate enforces
# that the decision was made consciously, before push.
#
# Recognised tokens (one must appear IMMEDIATELY after the colon, followed
# by whitespace / end-of-line / one of [.,;] — see TOKEN_RE below for
# the anchored form that prevents `manualish` and friends from matching):
#   manual                — operator did a focused security read of the diff
#   claude-code-security-review — anthropics/claude-code-security-review
#                                 was run (locally or via Action)
#   pr-review-toolkit     — /pr-check or /pr-review-toolkit:review-pr was
#                           run on this branch (a reviewer flagged
#                           security-class issues OR confirmed none)
#   ad-hoc                — informal review (e.g. the diff is small + low-
#                           risk; operator-judged adequate)
#
# `n/a` was considered as a recognised token but rejected — the literal
# string `n/a` appears naturally inside file paths (e.g. `path/n/a.txt`
# typos or comment text), which would gamify the gate. Operators who
# believe the diff has no security surface should use the docs-only
# fast-path below, the `ad-hoc` token, or the `[skip security-review]`
# marker, all of which leave a clearer audit trail.
#
# Skip if changed-file set is docs-only (same `.md` / `.txt` / `docs/` /
# `handovers/` filter the CR-before-push hook uses) — security review
# does not apply.
#
# Bypass (these clear the PUSH only; CI commit-lint and ready-check ignore them):
#   SKIP_SECURITY_REVIEW=1 git push ...    (env-var skip; logs WARNING)
#   `[skip security-review]` in any commit msg being pushed
#   git push --no-verify ...               (skip all pre-push hooks)
#
# Exit codes:
#   0 — pass (docs-only diff, attestation present, or bypass)
#   1 — block (code changed + no attestation + no bypass)
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
    echo "→ security-review: cannot source guardrails/lib.sh — refusing the push (rc=2 = cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi
# The one reader of the trailer rule (regexes, file classes, which commits count).
# shellcheck source=../lib/attest-trailers.sh
# shellcheck disable=SC1091
if ! { [ -r "$SCRIPT_DIR/../lib/attest-trailers.sh" ] && . "$SCRIPT_DIR/../lib/attest-trailers.sh"; } 2>/dev/null; then
    echo "→ security-review: cannot source scripts/lib/attest-trailers.sh — refusing the push (rc=2 = cannot evaluate; bypass with git push --no-verify)" >&2
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
    echo "→ security-review: cannot resolve current branch (lib.sh::_branch rc=2) — refusing the push (cannot evaluate; bypass with git push --no-verify)" >&2
    exit 2
fi

# Detached HEAD (empty branch, rc=1) or a protected default (main/master): skip.
# no-push-to-main covers main/master; detached HEAD has no sensible diff base.
if [ -z "$branch" ] || is_on_main; then
    exit 0
fi

if [ "${SKIP_SECURITY_REVIEW:-0}" = "1" ]; then
    echo "→ security-review: SKIP_SECURITY_REVIEW=1 — skipping (WARNING: confirm security review ran out-of-band before merge)" >&2
    exit 0
fi

# Resolve diff base. Mirror check-platforms-tested.sh — prefer origin/<default>
# over local <default> so linked worktrees do not re-flag work already on the
# push target. <default> = main OR master.
db=$(default_branch)
if [ "${SECURITY_REVIEW_NO_FETCH:-0}" != "1" ]; then
    git fetch -q origin "$db" 2>/dev/null || true
fi

diff_base=""
if git rev-parse --verify --quiet "origin/$db" >/dev/null; then
    diff_base="origin/$db"
elif git rev-parse --verify --quiet "$db" >/dev/null; then
    diff_base="$db"
elif [ "${SECURITY_REVIEW_NO_FETCH:-0}" = "1" ]; then
    # No resolvable base AND the operator opted into offline mode (NO_FETCH):
    # a shallow/offline clone legitimately may not carry the default ref. We
    # cannot evaluate the gate, but blocking here would break the documented
    # offline workflow — skip with a LOUD warning.
    echo "→ security-review: no 'origin/$db' or local '$db' ref and SECURITY_REVIEW_NO_FETCH=1 — cannot compute diff; SKIPPING the gate (WARNING: security surface NOT checked — confirm review ran before merge)" >&2
    exit 0
else
    # Online path: we attempted `git fetch origin $db` and STILL cannot resolve
    # any base. That is a genuinely broken state (default renamed and origin/HEAD
    # not pointing at it, corrupt refs) — not a normal clone, which always has
    # origin/<default>. Fail CLOSED: refusing the push beats silently
    # skipping the gate on an unattested code change.
    echo "→ security-review: no 'origin/$db' or local '$db' ref after fetch — refusing the push (rc=2 = cannot evaluate the gate). Set SECURITY_REVIEW_NO_FETCH=1 for a known-offline/shallow clone, or bypass with SKIP_SECURITY_REVIEW=1 / git push --no-verify." >&2
    exit 2
fi

# Fail CLOSED if the diff itself can't be computed. The 3-dot
# range needs a merge base; an orphan/unrelated-history branch makes `git diff`
# exit non-zero. The old `|| true` swallowed that to an empty list, which the
# `[ -z ]` line below then treated as "no changes" → a silent PASS on a branch
# we never actually inspected. An empty diff (genuinely no changes) still exits
# 0 via rev-parse'd success + the `[ -z ]` skip.
if ! changed=$(git diff --name-only "${diff_base}...HEAD" 2>/dev/null); then
    echo "→ security-review: cannot compute diff vs ${diff_base} (no merge base / git error) — refusing the push (rc=2 = cannot evaluate; bypass with SKIP_SECURITY_REVIEW=1 or git push --no-verify)" >&2
    exit 2
fi
[ -z "$changed" ] && exit 0

# Docs-only skip — the file class lives in scripts/lib/attest-trailers.sh:
# *.md, *.txt, docs/**, handovers/** do NOT require security review.
if ! non_docs=$(attest_files security <<<"$changed"); then
    echo "→ security-review: cannot classify the changed files — refusing the push (rc=2 = cannot evaluate; bypass with SKIP_SECURITY_REVIEW=1 or git push --no-verify)" >&2
    exit 2
fi
if [ -z "$non_docs" ]; then
    echo "→ security-review: docs-only change — skipping" >&2
    exit 0
fi

# The skip marker is a push-time bypass: it keeps its own scan of every message in the
# push range (merges included, as before). CI and ready-check ignore it.
# `[[:space:]]`, not `\s`: `\s` is GNU-only and BSD grep (macOS) reads it as a literal 's',
# so an INDENTED marker would silently fail to match. A here-string, not
# `printf ... | grep -q` (grep -q's early exit SIGPIPEs the writer once the
# range exceeds the pipe buffer, which pipefail turns into a false "not found").
commit_msgs=$(git log --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)
if grep -qiE '^[[:space:]]*\[skip security-review\]' <<<"$commit_msgs"; then
    echo "→ security-review: [skip security-review] in commit msg — skipping (WARNING: confirm security review ran out-of-band before merge)" >&2
    exit 0
fi

att_rc=0
att_out=$(bash "$SCRIPT_DIR/../lib/attest-trailers.sh" range "$diff_base" HEAD --only security 2>/dev/null) || att_rc=$?  # swallow-ok: the helper exit code is mapped just below, rc 1 is a missing trailer and any other rc refuses the push
case "$att_rc" in
    0)
        line=$(printf '%s\n' "$att_out" | sed -n 's/^ATTEST security needed found: //p' | head -n 1)
        echo "→ security-review: ${line}" >&2
        exit 0 ;;
    1) ;;
    *)
        echo "→ security-review: cannot evaluate the trailers (the helper exited ${att_rc}) — refusing the push (rc=2 = cannot evaluate; bypass with SKIP_SECURITY_REVIEW=1 or git push --no-verify)" >&2
        exit 2 ;;
esac


merge_only=0
merge_msgs=$(git log --merges --format='%B' "${diff_base}..HEAD" 2>/dev/null || true)  # swallow-ok: an unreadable merge list only drops the case (c) note, the refusal below is already decided
if grep -qiE "$ATTEST_SECURITY_RE" <<<"$merge_msgs"; then
    merge_only=1
fi

# Truncate a pathologically long trailer line so the gate refusal stays
# readable. bash 3.2-safe substring expansion; ASCII "..." marker (no
# multibyte ellipsis, which risks encoding ambiguity in a gate message).
truncate_attestation_line() {
    local text="$1" max="${2:-160}"
    if [ "${#text}" -gt "$max" ]; then
        printf '%s...' "${text:0:$max}"
    else
        printf '%s' "$text"
    fi
}

offenders_block=""
near_miss=0
while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    cbody=$(git log -1 --format='%B' "$sha" 2>/dev/null || true)
    tl_lines=$(printf '%s\n' "$cbody" | grep -iE "$ATTEST_SEC_TRAILER_RE" || true)
    [ -z "$tl_lines" ] && continue
    short=$(git rev-parse --short "$sha" 2>/dev/null || printf '%s' "$sha")
    while IFS= read -r tl; do
        [ -n "$tl" ] || continue
        trunc=$(truncate_attestation_line "$tl" 160 || true)
        offenders_block="${offenders_block}     ${short}  ${trunc}
"
        val_lc=$(printf '%s' "$tl" | tr '[:upper:]' '[:lower:]' | sed 's/.*security reviewed://' | sed 's/^[[:space:]]*//' || true)
        if attest_sec_near_miss "$val_lc"; then
            near_miss=1
        fi
    done <<<"$tl_lines"
done < <(git log --no-merges --format='%H' "${diff_base}..HEAD" 2>/dev/null || true)

if [ "$merge_only" = "1" ]; then
    case_intro="⛔ security-review: this push touches non-docs code and a conforming
   'Security reviewed:' trailer is present only in a merge commit;
   merges never attest — add one ordinary commit carrying it."
    offenders_part=""
    near_part=""
elif [ -n "$offenders_block" ]; then
    case_intro="⛔ security-review: this push touches non-docs code and carries
   'Security reviewed:' trailer(s) in commit messages, but NONE matched an
   accepted method token — the trailer is present but its value did not
   conform."
    offenders_part="   Offending trailer line(s) — none matched an accepted token:
${offenders_block}
"
    if [ "$near_miss" = "1" ]; then
        near_part="   Hint: a value that STARTS with an accepted token but fails the
   end-anchor is the most likely cause — e.g. 'manually' is NOT 'manual'.
   The token must be followed by whitespace, end-of-line, or one of .,;
"
    else
        near_part=""
    fi
else
    case_intro="⛔ security-review: this push touches non-docs code but no
   'Security reviewed:' attestation was found in any non-merge commit on
   the branch."
    offenders_part=""
    near_part=""
fi

# Block.
cat >&2 <<EOF
${case_intro}

${offenders_part}   Non-docs files changed vs ${diff_base}:
$(printf '%s\n' "$non_docs" | sed 's/^/     /')

   Accepted shape — token first, prose after:
       Security reviewed: manual — <what you actually did>
   where the token is one of:
       manual, claude-code-security-review, pr-review-toolkit, ad-hoc
   The token must be followed by whitespace, end-of-line, or one of .,;
${near_part}
   Fix:
   Run a security review (one of):
        - operator manual read of the diff for security-class issues
        - anthropics/claude-code-security-review (slash command or
          GitHub Action)
        - /pr-check or /pr-review-toolkit:review-pr (a reviewer in the
          fanout covers the security lens)
   Add one more ordinary (non-merge) commit whose body carries
   \`Security reviewed: <token> — <what you checked>\`, then push again
   (for example \`git commit --allow-empty\`). Never \`git commit --amend\`.

   Why: code changes can carry security-class issues (input handling,
   authn/authz, secrets exposure, command injection, SSRF, etc.) that
   the existing code-review-before-push gate is not specifically tuned
   to catch. This gate forces the security lens to be acknowledged
   before push — the gate does NOT run the review itself, so the
   no-new-headless-claude rule is respected.

   See \`docs/security-review.md\` for the suggested review playbook.
EOF
exit 1
