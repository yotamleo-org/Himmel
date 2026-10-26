#!/usr/bin/env bash
# render-settings.sh — POC. Print one-line srt settings JSON for a
# worker. Profiles (operator rulings):
#   impl      base allow list only (github, npm, PyPI, model gateway)
#   research  base list + a curated docs/reference list; writes still confined to the same roots
# Writable roots are always the worker worktree, its scratchpad and the handover
# bucket. Extra domains (a chief-approved request) are appended to the list.
#
#   [SRT_SCRATCH_HOME=<dir>] render-settings.sh <impl|research> <worktree> <scratch> <handover> [extra-domain...]
set -eu

profile="$1" worktree="$2" scratch="$3" handover="$4"
shift 4

case "$profile" in
    impl) domains='"github.com","api.github.com","codeload.github.com","registry.npmjs.org","pypi.org","files.pythonhosted.org","api.anthropic.com"' ;;
    # srt 0.0.79 rejects "*" and "*.com" as overly broad, so "broad web" is a
    # curated docs/reference list that extends the base list (a measured POC finding)
    research) domains='"github.com","api.github.com","codeload.github.com","registry.npmjs.org","pypi.org","files.pythonhosted.org","api.anthropic.com","example.com","*.wikipedia.org","docs.python.org","developer.mozilla.org","stackoverflow.com","arxiv.org","*.readthedocs.io"' ;;
    *) echo "render-settings: unknown profile: $profile" >&2; exit 2 ;;
esac
home="${HOME:?}"
# the JSON is printf-built, so refuse any argument that would need escaping
scratch_home="${SRT_SCRATCH_HOME:-}"
for v in "$worktree" "$scratch" "$handover" "$home" "$scratch_home" "$@"; do
    case "$v" in
        *\"* | *\\* | *[[:cntrl:]]*) echo "render-settings: refusing a quote, backslash or control character in an argument" >&2; exit 2 ;;
    esac
done
for d in "$@"; do
    domains="$domains,\"$d\""
done

printf '{"network":{"allowedDomains":[%s],"deniedDomains":[]},' "$domains"
printf '"filesystem":{"denyRead":["%s/.ssh","%s/.config/gh","%s/.git-credentials","%s/.netrc"],' "$home" "$home" "$home" "$home"
printf '"allowWrite":["%s","%s","%s"' "$worktree" "$scratch" "$handover"
# srt takes no globs in allowWrite on Linux: a launcher that needs
# a writable HOME passes one scratch dir here, the only root beyond the three
[ -z "$scratch_home" ] || printf ',"%s"' "$scratch_home"
printf '],"denyWrite":[]}}\n'
