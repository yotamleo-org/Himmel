#!/usr/bin/env bash
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
#
# check-hardcoded-env-values.sh [<base> | --staged | --tree] — refuse NEW
# hardcoded environment values (repo/owner slugs, Pages URLs, GHCR owner paths,
# absolute home paths, Atlassian hosts, Jira field ids) in the lines added by
# <base>...HEAD (default origin/main, else main; tip is PRE_COMMIT_TO_REF, else
# HEAD). --staged scans the index instead (the pre-commit hook). --tree scans
# every tracked file at the tip for every class except repo-slug, whose existing
# hits are the inventory in docs/internals/hardcoded-env-values.md.
#
# Skipped: paths matching an ERE in hardcoded-env-values-allow.txt (tests,
# fixtures, docs, templates), comment-only lines, and a line carrying
# `env-literal-ok: <reason>` (a marker with no reason does not count).
# Values belong in ~/.himmel/config.json via scripts/lib/env-value.sh, or in
# discovery (git origin, gh).
#
# Exit: 0 clean; 1 at least one new literal; 2 usage / git failure.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
allow="$here/hardcoded-env-values-allow.txt"
tip="${PRE_COMMIT_TO_REF:-HEAD}"
mode=range
base=""
for arg in "$@"; do
    case "$arg" in
        --staged) mode=staged ;;
        --tree) mode=tree ;;
        *) base="$arg" ;;
    esac
done

[ -f "$allow" ] || { echo "check-hardcoded-env-values: allowlist missing: $allow" >&2; exit 2; }

diff_args=(-U0 --no-color --no-ext-diff --no-textconv --src-prefix=a/ --dst-prefix=b/ --diff-filter=AMR)
case "$mode" in
    staged) diff_cmd=(git diff --cached "${diff_args[@]}") ;;
    tree)
        empty_tree=$(git hash-object -t tree /dev/null) || { echo "check-hardcoded-env-values: cannot name the empty tree" >&2; exit 2; }
        diff_cmd=(git diff "${diff_args[@]}" "$empty_tree" "$tip")
        ;;
    *)
        if [ -z "$base" ]; then
            for candidate in origin/main main; do
                if git rev-parse --verify -q "$candidate^{commit}" >/dev/null; then base="$candidate"; break; fi
            done
        fi
        [ -n "$base" ] || { echo "check-hardcoded-env-values: no usable base ref" >&2; exit 2; }
        git rev-parse --verify -q "$base^{commit}" >/dev/null || { echo "check-hardcoded-env-values: unknown base '$base'" >&2; exit 2; }
        diff_cmd=(git diff "${diff_args[@]}" "$base...$tip")
        ;;
esac

tree=0
[ "$mode" = tree ] && tree=1

# Streamed, not captured: the whole-tree diff is tens of megabytes. Under pipefail a
# failing git outranks a clean awk (rc 2); awk's own rc 1 is the finding.
rc=0
"${diff_cmd[@]}" | awk -v allowfile="$allow" -v tree="$tree" '
BEGIN {
    n = 0
    while ((getline line < allowfile) > 0) {
        if (line ~ /^[[:space:]]*(#|$)/) continue
        allow[n++] = line
    }
    close(allowfile)
    k = 0
    # The audited value is the owner, not the host: a GHCR path whose owner is
    # an expression (`ghcr.io/${{ ... }}`) is derived. /home/runner is the fixed CI
    # runner user (stripped before matching); a path variable ending in `home`
    # (`$ROOT/home/x`) is not an absolute home.
    cls[k] = "repo-slug";     re[k++] = "yotamleo(-org)?/[A-Za-z0-9._-]+"
    cls[k] = "pages-url";     re[k++] = "[A-Za-z0-9-]+\\.github\\.io"
    cls[k] = "ghcr-image";    re[k++] = "ghcr\\.io/[A-Za-z0-9]"
    cls[k] = "home-path";     re[k++] = "(^|[^A-Za-z0-9_.}-])/home/[a-z][a-z0-9_-]*"
    cls[k] = "jira-host";     re[k++] = "[A-Za-z0-9}-]\\.atlassian\\.net"
    cls[k] = "jira-field-id"; re[k++] = "customfield_[0-9]+"
    nclass = k
}
# A file header only sits between its `diff --git` line and its first hunk; an
# added source line that reads `++ b/x` shows as `+++ b/x` and is content.
/^diff --git / { inhdr = 1; next }
inhdr && /^\+\+\+ / {
    file = $0; sub(/^\+\+\+ b\//, "", file)
    skip = 0
    for (i = 0; i < n; i++) if (file ~ allow[i]) { skip = 1; break }
    next
}
/^@@ / { inhdr = 0; lineno = $0; sub(/^@@ -[0-9,]+ \+/, "", lineno); sub(/[, ].*/, "", lineno); lineno += 0; next }
/^\+/ {
    body = substr($0, 2)
    cur = lineno++
    if (skip) next
    if (body ~ /^[[:space:]]*(#|\/\/)/) next
    if (body ~ /env-literal-ok:[[:space:]]*[^[:space:]]/) next
    for (c = 0; c < nclass; c++) {
        if (tree && cls[c] == "repo-slug") continue
        scan = body
        if (cls[c] == "home-path") gsub(/\/home\/runner([^a-z0-9_-]|$)/, " ", scan)
        if (scan ~ re[c]) {
            printf "%s:%d: %s: %s\n", file, cur, cls[c], body
            bad++
            break
        }
    }
}
END {
    if (bad) {
        printf "check-hardcoded-env-values: %d new hardcoded value(s). Read it from config (scripts/lib/env-value.sh) or discover it; if it is an intentional identity, add `env-literal-ok: <reason>` on the line.\n", bad > "/dev/stderr"
        exit 1
    }
}' || rc=$?

case "$rc" in
    0) exit 0 ;;
    1) exit 1 ;;
    *) echo "check-hardcoded-env-values: git diff failed" >&2; exit 2 ;;
esac
