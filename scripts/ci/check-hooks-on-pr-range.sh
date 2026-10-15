#!/usr/bin/env bash
# check-hooks-on-pr-range.sh — re-run a pre-push hook over a PR's range in CI,
# so a commit made with --no-verify cannot skip it.
#
# The hooks (check-platforms-tested.sh, check-security-reviewed.sh,
# check-doc-guard.sh --pre-push) are branch-relative: they diff
# origin/<default>...HEAD and read `git log origin/<default>..HEAD`. A CI
# checkout is a detached merge ref, where they all no-op. This wrapper builds a
# throw-away clone that looks like a feature branch (origin/main = the PR's
# base tip, HEAD = the PR) and runs the UNMODIFIED hook there, so CI and the
# author-time gate share one implementation.
#
# Usage:
#   check-hooks-on-pr-range.sh [--first-commit] [--base <sha>] -- <hook> [args...]
#   <hook> is a repo-relative path under scripts/hooks/.
#
# Range: HEAD is a PR merge ref (HEAD^2 exists) -> HEAD^1..HEAD^2, the PR's own
# commits (the same convention as check-commit-range.sh --merge-ref). Otherwise
# <base>..HEAD with --base, or $COMMIT_RANGE_BASE. No base (a cron / dispatch
# run) -> nothing to check, exit 0 — but under GITHUB_EVENT_NAME=pull_request an
# unresolved or empty range, or a shallow checkout, is exit 2: a dropped
# fetch-depth: 0 must fail the gate, never pass it vacuously.
#
# --first-commit: the attestation trailers must be in the PR's FIRST commit
# (CLAUDE.md; ready-check.sh item 5), and the hooks accept a trailer from ANY
# commit in the range. So the hook runs against a one-commit range: the PR's
# whole diff, carrying only the first commit's message. A PR-body attestation
# (the hooks' `gh pr view` fallback) is shut off with a failing gh shim.
# A bot PR author (dependabot) is exempt, as in commit-lint.
#
# Exit: the hook's own exit code; 2 = cannot resolve the range.
set -uo pipefail

# A pull_request run that cannot name its range is an error; any other event
# (cron / dispatch / push) has no PR to check.
no_range() { # <message>
  if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
    echo "ERR hooks-on-range: $1 on a pull_request event" >&2; exit 2
  fi
  echo "hooks-on-range: $1 — nothing to check"; exit 0
}

FIRST=0
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --first-commit) FIRST=1; shift ;;
    --base)
      [ $# -ge 2 ] || { echo "ERR hooks-on-range: --base needs a value" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "ERR hooks-on-range: unknown arg '$1'" >&2; exit 2 ;;
  esac
done
[ $# -ge 1 ] || { echo "ERR hooks-on-range: no hook given after --" >&2; exit 2; }
HOOK="$1"; shift
case "$HOOK" in
  scripts/hooks/check-*.sh) ;;
  *) echo "ERR hooks-on-range: hook must be scripts/hooks/check-*.sh, got '$HOOK'" >&2; exit 2 ;;
esac

# REPO = the checkout holding the PR range (cwd); HOOKS = the checkout this
# script lives in, which supplies the hook (the same tree in CI).
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERR hooks-on-range: not in a git checkout" >&2; exit 2; }
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$HOOKS/$HOOK" ] || { echo "ERR hooks-on-range: $HOOK not found" >&2; exit 2; }

if [ "$FIRST" -eq 1 ]; then
  author="$(printf '%s' "${TICKET_ID_TRUSTED_AUTHOR:-}" | tr '[:upper:]' '[:lower:]')"
  case "$author" in
    dependabot|'dependabot[bot]')
      echo "hooks-on-range: bot PR author '$author' — first-commit attestation skipped"
      exit 0 ;;
  esac
fi

if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] \
  && [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != false ]; then
  echo "ERR hooks-on-range: shallow checkout on a pull_request event (needs fetch-depth: 0)" >&2; exit 2
fi

if git rev-parse --verify --quiet 'HEAD^2' >/dev/null 2>&1; then
  base="$(git rev-parse 'HEAD^1')"
  tip="$(git rev-parse 'HEAD^2')"
else
  want="${BASE:-${COMMIT_RANGE_BASE:-}}"
  if [ -z "$want" ]; then
    no_range "no PR range (not a merge ref, no --base)"
  fi
  base="$(git rev-parse --verify --quiet "$want^{commit}" 2>/dev/null)" \
    || { echo "ERR hooks-on-range: base '$want' does not resolve to a commit" >&2; exit 2; }
  tip="$(git rev-parse HEAD)"
fi
head="$(git rev-parse HEAD)"

# The oldest commit of the range, merges included — the same "first commit" the
# PR's commit list gives ready-check.sh item 5; an unattested merge cannot hide
# behind a later ordinary commit that carries the trailers. --topo-order, not
# commit date: a backdated GIT_COMMITTER_DATE must not pick the first commit.
commits="$(git rev-list --reverse --topo-order "$base..$tip")" \
  || { echo "ERR hooks-on-range: rev-list $base..$tip failed" >&2; exit 2; }
first="${commits%%$'\n'*}"
if [ -z "$first" ]; then
  no_range "no commits in $base..$tip"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/hooks-on-range.XXXXXX")" ||{ echo "ERR hooks-on-range: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" || exit 2
printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"

clone="$tmp/clone"
git clone -q --shared --no-checkout "$REPO" "$clone" 2>/dev/null \
  || { echo "ERR hooks-on-range: cannot clone $REPO" >&2; exit 2; }
if ! git -C "$clone" update-ref refs/remotes/origin/main "$base" \
  || ! git -C "$clone" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main; then
  echo "ERR hooks-on-range: cannot set base ref" >&2; exit 2
fi

if [ "$FIRST" -eq 1 ]; then
  git -C "$REPO" log -1 --format='%B' "$first" > "$tmp/msg"
  # The PR's diff vs its base (merge-ref tree), the first commit's message.
  syn="$(GIT_AUTHOR_NAME=ci GIT_AUTHOR_EMAIL=ci@invalid GIT_COMMITTER_NAME=ci GIT_COMMITTER_EMAIL=ci@invalid \
        git -C "$clone" commit-tree "$head^{tree}" -p "$base" -F "$tmp/msg")" \
    || { echo "ERR hooks-on-range: cannot synthesize the first-commit range" >&2; exit 2; }
  target="$syn"
  echo "hooks-on-range: first commit ${first} checked as the sole commit of ${base}..${tip}"
else
  target="$head"
fi
git -C "$clone" checkout -q -B ci-pr-range "$target" \
  || { echo "ERR hooks-on-range: cannot check out the range" >&2; exit 2; }
: > "$clone/.himmel-dev"   # the himmel-dev gates (doc-guard) no-op without it

cd "$clone" || exit 2
PATH="$tmp/bin:$PATH" \
  PLATFORMS_TESTED_NO_FETCH=1 SECURITY_REVIEW_NO_FETCH=1 DOC_GUARD_NO_FETCH=1 \
  env -u PLATFORMS_TESTED_OK -u SKIP_SECURITY_REVIEW -u DOC_GUARD_OK \
  bash "$HOOKS/$HOOK" "$@"
