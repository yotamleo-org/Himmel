#!/usr/bin/env bash
# check-hooks-on-pr-range.sh — re-run a pre-push gate over a PR's range in CI,
# so a commit made with --no-verify cannot skip it.
#
# Two modes:
#
#   --attest <platforms|security>   the attestation trailers
#   -- <hook> [args...]             a branch-relative pre-push hook (doc-guard)
#
# --attest: the trailers `Platforms tested:` / `Security reviewed:` must be carried
# by some non-merge commit of the PR's range, read by scripts/lib/attest-trailers.sh
# (`range <base> <tip> --only <kind>`), the one reader the pre-push hooks and
# ready-check item 5 call too. A merge commit never attests; a PR-body line, a
# `[skip …]` marker and the env bypasses count here as they do in ready-check:
# not at all (they clear the author's push only). A bot PR author (dependabot) is
# exempt, as in commit-lint. The helper's exit code is this script's: 0 attested,
# 1 a needed trailer is missing, 2 cannot evaluate (an `ATTEST ERROR` line says why).
#
# Hook mode: the hooks (check-doc-guard.sh --pre-push) are branch-relative: they
# diff origin/<default>...HEAD and read `git log origin/<default>..HEAD`. A CI
# checkout is a detached merge ref, where they all no-op. This mode builds a
# throw-away clone that looks like a feature branch (origin/main = the PR's base
# tip, HEAD = the PR) and runs the UNMODIFIED hook there, so CI and the
# author-time gate share one implementation. `gh` is shimmed to fail (no PR body).
#
# Usage:
#   check-hooks-on-pr-range.sh --attest <platforms|security> [--base <sha>]
#   check-hooks-on-pr-range.sh [--base <sha>] -- <hook> [args...]
#   <hook> is a repo-relative path under scripts/hooks/.
#
# Range: HEAD is a PR merge ref (HEAD^2 exists) -> HEAD^1..HEAD^2, the PR's own
# commits (the same convention as check-commit-range.sh --merge-ref). Otherwise
# <base>..HEAD with --base, or $COMMIT_RANGE_BASE. No base (a cron / dispatch
# run) -> nothing to check, exit 0 — but under GITHUB_EVENT_NAME=pull_request an
# unresolved or empty range, or a shallow checkout, is exit 2: a dropped
# fetch-depth: 0 must fail the gate, never pass it vacuously.
#
# Exit: the helper's / hook's own exit code; 2 = cannot resolve the range.
set -uo pipefail

# A pull_request run that cannot name its range is an error; any other event
# (cron / dispatch / push) has no PR to check.
no_range() { # <message>
  if [ "${GITHUB_EVENT_NAME:-}" = pull_request ]; then
    echo "ERR hooks-on-range: $1 on a pull_request event" >&2; exit 2
  fi
  echo "hooks-on-range: $1 — nothing to check"; exit 0
}

ATTEST=""
BASE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --attest)
      [ $# -ge 2 ] || { echo "ERR hooks-on-range: --attest needs platforms or security" >&2; exit 2; }
      case "$2" in
        platforms|security) ATTEST="$2" ;;
        *) echo "ERR hooks-on-range: --attest takes platforms or security, got '$2'" >&2; exit 2 ;;
      esac
      shift 2 ;;
    --base)
      [ $# -ge 2 ] || { echo "ERR hooks-on-range: --base needs a value" >&2; exit 2; }
      BASE="$2"; shift 2 ;;
    --) shift; break ;;
    *) echo "ERR hooks-on-range: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

# REPO = the checkout holding the PR range (cwd); HOOKS = the checkout this
# script lives in, which supplies the hook and the helper (the same tree in CI).
REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "ERR hooks-on-range: not in a git checkout" >&2; exit 2; }
HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -z "$ATTEST" ]; then
  [ $# -ge 1 ] || { echo "ERR hooks-on-range: no hook given after --" >&2; exit 2; }
  HOOK="$1"; shift
  case "$HOOK" in
    scripts/hooks/check-*.sh) ;;
    *) echo "ERR hooks-on-range: hook must be scripts/hooks/check-*.sh, got '$HOOK'" >&2; exit 2 ;;
  esac
  [ -f "$HOOKS/$HOOK" ] || { echo "ERR hooks-on-range: $HOOK not found" >&2; exit 2; }
else
  author="$(printf '%s' "${TICKET_ID_TRUSTED_AUTHOR:-}" | tr '[:upper:]' '[:lower:]')"
  case "$author" in
    dependabot|'dependabot[bot]')
      echo "hooks-on-range: bot PR author '$author' — attestation skipped"
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

commits="$(git rev-list "$base..$tip")" \
  || { echo "ERR hooks-on-range: rev-list $base..$tip failed" >&2; exit 2; }
if [ -z "$commits" ]; then
  no_range "no commits in $base..$tip"
fi

if [ -n "$ATTEST" ]; then
  cd "$REPO" || exit 2
  exec bash "$HOOKS/scripts/lib/attest-trailers.sh" range "$base" "$tip" --only "$ATTEST"
fi

# shellcheck source=../lib/prim.sh
. "$HOOKS/scripts/lib/prim.sh" || { echo "ERR hooks-on-range: cannot load scripts/lib/prim.sh" >&2; exit 2; }
tmp="$(tmpdir)" || { echo "ERR hooks-on-range: mktemp failed" >&2; exit 2; }
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

git -C "$clone" checkout -q -B ci-pr-range "$head" \
  || { echo "ERR hooks-on-range: cannot check out the range" >&2; exit 2; }
: > "$clone/.himmel-dev"   # the himmel-dev gates (doc-guard) no-op without it

cd "$clone" || exit 2
PATH="$tmp/bin:$PATH" \
  PLATFORMS_TESTED_NO_FETCH=1 SECURITY_REVIEW_NO_FETCH=1 DOC_GUARD_NO_FETCH=1 \
  env -u PLATFORMS_TESTED_OK -u SKIP_SECURITY_REVIEW -u DOC_GUARD_OK \
  bash "$HOOKS/$HOOK" "$@"
