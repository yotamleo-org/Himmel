#!/usr/bin/env bash
# socket-scan.sh — run ONE Socket dependency scan over the manifest and lock files in a change
# set, and nothing when the change set holds none.
#
#   socket-scan.sh --files <list> [--root <dir>] [--repo <name>] [--branch <name>]
#
# <list> holds one changed path per line (relative to --root, default the cwd). A path counts
# when its file name is a dependency manifest or lock file, it sits outside the directories the
# Snyk scan also leaves out (node_modules, fixtures, worktrees, graphify-out, .venv), and the
# file still exists (a deleted lock file adds nothing to scan). Those paths are the targets of a
# single `socket scan create --report` call (1 quota unit; the free plan is a small quota, so a
# change set never fans out into one scan per file).
#
# Exit: 0 scan passed or skipped, 1 socket exited 1 (a policy violation: always red, the report
# is printed, never a skip), 2 usage or scan error (socket exited with any other code and no quota reply).
# A skip is always exit 0 with a named reason on stdout and in $GITHUB_STEP_SUMMARY:
#   SKIP no-manifest  the change set holds no manifest or lock file; nothing runs, no key is read
#   SKIP no-key       SOCKET_DEV_API_KEY is not set and the secrets resolver serves none
#   SKIP quota        socket exited with a code other than 0 or 1 and answered with a quota or
#                     rate-limit reply (HTTP 429, "Insufficient quota for API route"); that is the
#                     plan running out, not a finding. The reply text is read only for an rc other
#                     than 0/1, because an rc 1 report can name a path or package that looks like
#                     one. Cost: if Socket exits 1 on a 429 the check goes red, the safe direction
#                     on a non-required check.
#
# The key: SOCKET_DEV_API_KEY from the environment (the repo secret in CI), else the himmel
# secrets resolver without its .env fallback (.env feeds only jira). It reaches socket as
# SOCKET_CLI_API_TOKEN in the child's environment only, never as an argument, and any copy of it
# in socket's own output is replaced before the output is printed.
#
# Seams (tests): SOCKET_BIN (the socket CLI), SOCKET_SCAN_SECRETS_BIN (the secrets resolver).
# Platform: Linux or macOS runner, bash.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOCKET="${SOCKET_BIN:-socket}"
SECRETS="${SOCKET_SCAN_SECRETS_BIN:-$SCRIPT_DIR/../lib/himmel-secrets}"
# ecosystems Socket reads: npm, bun, PyPI (requirements, pyproject, uv, poetry, pipenv), Go, Ruby
MANIFEST_RE='(^|/)(package\.json|package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|bun\.lockb?|uv\.lock|requirements[^/]*\.txt|pyproject\.toml|poetry\.lock|Pipfile|Pipfile\.lock|go\.mod|go\.sum|Gemfile|Gemfile\.lock)$'
EXCL_RE='(^|/)(node_modules|fixtures|worktrees|graphify-out|\.venv)/'
# only the API's own quota reply, each form anchored by a word boundary and a mandatory
# separator: an "HTTP 429" or "HTTP/1.1 429" status, "status: 429" or "status code = 429", the
# phrase "Too Many Requests", the documented body "Insufficient quota for API route". The
# phrases hold spaces, so a package name (http429, @http/429, status429, too-many-requests,
# insufficient-quota-check) in a policy report never matches: that is a finding, not a skip.
QUOTA_RE='(^|[[:space:],;({"])(HTTP(/[0-9.]+)?[[:space:]]+429|status( code)?[[:space:]]*[:=][[:space:]]*429)([^0-9]|$)|(^|[^[:alnum:]_/@.-])(too many requests|insufficient quota)'

err() { printf 'ERR socket-scan: %s\n' "$*" >&2; }
say() { # a result line, on stdout and in the job summary
    printf 'socket-scan: %s\n' "$*"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf 'socket-scan: %s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
    return 0
}

files="" root="$PWD" repo="" branch=""
while [ $# -gt 0 ]; do
    case "$1" in
        --files|--root|--repo|--branch)
            [ $# -ge 2 ] || { err "$1 needs a value"; exit 2; }
            case "$1" in --files) files="$2" ;; --root) root="$2" ;; --repo) repo="$2" ;; --branch) branch="$2" ;; esac
            shift 2 ;;
        *) err "unknown arg: $1"; exit 2 ;;
    esac
done
[ -n "$files" ] || { err "--files <list> is required"; exit 2; }
[ -r "$files" ] || { err "cannot read the change list $files"; exit 2; }
root="$(cd "$root" 2>/dev/null && pwd)" || { err "--root does not exist"; exit 2; }
[ -n "$repo" ] || repo="${GITHUB_REPOSITORY:-}"
repo="${repo##*/}"
[ -n "$repo" ] || repo="$(basename "$root")"
[ -n "$branch" ] || branch="${GITHUB_HEAD_REF:-}"
[ -n "$branch" ] || branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# --- the gate: manifest and lock files that still exist -------------------------
targets=()
while IFS= read -r f; do
    [ -n "$f" ] || continue
    [[ $f =~ $MANIFEST_RE ]] || continue
    [[ $f =~ $EXCL_RE ]] && continue
    [ -f "$root/$f" ] || continue
    targets+=("$f")
done < "$files"
if [ "${#targets[@]}" -eq 0 ]; then
    say "SKIP no-manifest — no dependency manifest or lock file in the change set, no scan started"
    exit 0
fi

# --- the key --------------------------------------------------------------------
key="${SOCKET_DEV_API_KEY:-}"
if [ -z "$key" ]; then
    line="$("$SECRETS" get --no-dotenv SOCKET_DEV_API_KEY 2>/dev/null | grep -m1 '^SOCKET_DEV_API_KEY=')" || line=""
    key="${line#SOCKET_DEV_API_KEY=}"
fi
if [ -z "$key" ]; then
    say "SKIP no-key — SOCKET_DEV_API_KEY is not set; the operator adds it with: gh secret set SOCKET_DEV_API_KEY${GITHUB_REPOSITORY:+ --repo $GITHUB_REPOSITORY}"
    exit 0
fi
command -v "$SOCKET" >/dev/null 2>&1 || [ -x "$SOCKET" ] || { err "socket CLI not found ($SOCKET); install it with: npm install -g --ignore-scripts socket"; exit 2; }

# --- one scan ---------------------------------------------------------------------
# shellcheck source=../lib/prim.sh
. "$SCRIPT_DIR/../lib/prim.sh" 2>/dev/null || { err "cannot source prim.sh"; exit 2; }
tmp="$(tmpdir)" || { err "mktemp failed"; exit 2; }
trap 'rm -rf "$tmp"' EXIT
( cd "$root" && export SOCKET_CLI_API_TOKEN="$key" && exec "$SOCKET" scan create --report --repo "$repo" --branch "$branch" "${targets[@]}" ) \
    > "$tmp/out" 2>&1 < /dev/null
rc=$?
out="$(tail -c 4000 "$tmp/out")"
out="${out//"$key"/***}"

if [ "$rc" -eq 0 ]; then
    say "OK — ${#targets[@]} manifest or lock file(s) scanned in one scan, the report passes the policy"
    exit 0
fi
# rc 1 is the policy exit: report and fail, never a skip, whatever the report text says (a path or
# package name in it can look like a quota reply). The quota reply is read only for another rc.
if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out"
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$out" >> "$GITHUB_STEP_SUMMARY"
    say "FAIL — the Socket report does not pass the policy (socket exit 1), see the output above"
    exit 1
fi
if grep -Eiq "$QUOTA_RE" <<< "$out"; then
    reason="$(grep -Ei -m1 "$QUOTA_RE" <<< "$out" | head -c 300)"
    say "SKIP quota — Socket's quota or rate limit is reached, not a finding: $reason"
    exit 0
fi
printf '%s\n' "$out"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || printf '%s\n' "$out" >> "$GITHUB_STEP_SUMMARY"
say "ERR — the Socket scan did not complete (socket exit $rc)"
exit 2
